import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const String notificationChannelId = 'carrot_link_service';
const int notificationId = 888;
const String actionDisconnect = 'disconnect';

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId,
    'CarrotLink Service',
    description: 'CarrotLink 백그라운드 연결 유지 서비스',
    importance: Importance.low,
    showBadge: false,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/launcher_icon');
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      if (response.actionId == actionDisconnect) {
        service.invoke('disconnect');
      }
    },
  );

  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: 'CarrotLink',
      initialNotificationContent: '서비스 준비 중...',
      foregroundServiceNotificationId: notificationId,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  SSHClient? sshClient;
  Timer? heartbeatTimer;
  Timer? reconnectTimer;
  Timer? discoveryRetryTimer;
  RawDatagramSocket? discoverySocket;

  bool connectInFlight = false;
  bool discoveryListening = false;
  bool stopping = false;
  bool autoReconnectEnabled = true;
  bool appForeground = false;

  String? connectedIp;
  int? connectedPort;
  String? candidateIp;
  DateTime? candidateSeenAt;
  DateTime? lastCandidateBroadcastAt;

  String? profileUsername;
  String? profilePassword;
  String? profilePrivateKey;
  int profilePort = 22;

  bool manualDisconnectRequested = false;
  DateTime? manualDisconnectUntil;
  int reconnectAttempt = 0;
  int noBroadcastWaitAttempt = 0;
  late Future<void> Function(
    String, {
    required String reason,
  }) connectTo;
  late Future<void> Function() startDiscoveryListener;

  String currentTitle = 'CarrotLink';
  String currentContent = '연결 대기 중...';

  bool isValidIpv4(String ip) {
    final parsed = InternetAddress.tryParse(ip);
    return parsed != null && parsed.type == InternetAddressType.IPv4;
  }

  bool hasConnectProfile() {
    final usernameReady =
        profileUsername != null && profileUsername!.isNotEmpty;
    final hasKey = profilePrivateKey != null && profilePrivateKey!.isNotEmpty;
    final hasPassword = profilePassword != null && profilePassword!.isNotEmpty;
    return usernameReady && (hasKey || hasPassword);
  }

  bool canAutoReconnect() {
    if (!autoReconnectEnabled) return false;
    if (!manualDisconnectRequested) return true;
    final until = manualDisconnectUntil;
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return false;
    manualDisconnectRequested = false;
    manualDisconnectUntil = null;
    return true;
  }

  Duration candidateStaleThresholdForProfile() {
    return appForeground
        ? const Duration(seconds: 20)
        : const Duration(seconds: 60);
  }

  Duration heartbeatIntervalForProfile() {
    return appForeground
        ? const Duration(seconds: 2)
        : const Duration(seconds: 10);
  }

  Duration heartbeatTimeoutForProfile() {
    return appForeground
        ? const Duration(seconds: 1)
        : const Duration(seconds: 3);
  }

  Duration candidateBroadcastDedupeWindow() {
    return appForeground
        ? const Duration(milliseconds: 200)
        : const Duration(milliseconds: 500);
  }

  int reconnectBackoffSeconds(int attempt) {
    final seq = appForeground ? const [1, 2, 3, 5] : const [5, 10, 20, 30];
    if (attempt < 0) return seq.first;
    if (attempt >= seq.length) return seq.last;
    return seq[attempt];
  }

  int noBroadcastBackoffSeconds(int attempt) {
    final seq = appForeground ? const [1, 2] : const [20, 30];
    if (attempt < 0) return seq.first;
    if (attempt >= seq.length) return seq.last;
    return seq[attempt];
  }

  String? pickReconnectTarget() {
    final ip = candidateIp;
    final seenAt = candidateSeenAt;
    if (ip == null || seenAt == null) return null;
    if (DateTime.now().difference(seenAt) >
        candidateStaleThresholdForProfile()) {
      return null;
    }
    return ip;
  }

  void emitConnectionState({
    required bool isConnected,
    String? reason,
    String? error,
    String? ip,
    int? port,
  }) {
    service.invoke('connectionState', {
      'isConnected': isConnected,
      'reason': reason ?? '',
      'error': error ?? '',
      'ip': ip ?? connectedIp,
      'port': port ?? connectedPort,
    });
  }

  void emitDiscoveryState({String source = 'service'}) {
    final ageMs = candidateSeenAt == null
        ? null
        : DateTime.now().difference(candidateSeenAt!).inMilliseconds;
    service.invoke('discoveryState', {
      'source': source,
      'listening': discoveryListening,
      'candidateIp': candidateIp,
      'candidateAgeMs': ageMs,
      'autoReconnectEnabled': autoReconnectEnabled,
      'manualDisconnectRequested': manualDisconnectRequested,
      'connectedIp': connectedIp,
      'appForeground': appForeground,
    });
  }

  Future<void> updateNotification({String? title, String? content}) async {
    if (title != null) currentTitle = title;
    if (content != null) currentContent = content;

    if (service is! AndroidServiceInstance) return;
    final androidService = service;

    if (await androidService.isForegroundService()) {
      await androidService.setForegroundNotificationInfo(
        title: currentTitle,
        content: currentContent,
      );
    }
  }

  Future<void> closeClient() async {
    heartbeatTimer?.cancel();
    heartbeatTimer = null;
    try {
      sshClient?.close();
    } catch (_) {}
    sshClient = null;
    connectedIp = null;
    connectedPort = null;
  }

  void clearReconnectTimer() {
    reconnectTimer?.cancel();
    reconnectTimer = null;
  }

  Future<void> handleDisconnected(String reason, {bool manual = false}) async {
    final wasConnected = connectedIp != null;
    await closeClient();
    if (manual) {
      manualDisconnectRequested = true;
      manualDisconnectUntil = DateTime.now().add(const Duration(minutes: 2));
    }
    emitConnectionState(isConnected: false, reason: reason);
    emitDiscoveryState(source: reason);
    if (manual) {
      await updateNotification(title: 'CarrotLink: 연결 해제됨', content: '대기 중...');
      return;
    }
    if (wasConnected) {
      await updateNotification(
          title: 'CarrotLink: 연결 끊김', content: '재연결 대기 중...');
    }
  }

  void scheduleReconnect(String reason) {
    if (stopping || !canAutoReconnect() || !hasConnectProfile()) return;
    if (connectInFlight || (sshClient != null && !sshClient!.isClosed)) return;
    final target = pickReconnectTarget();
    if (target == null || target.isEmpty) {
      if (reconnectTimer?.isActive == true) return;
      final delaySec = noBroadcastBackoffSeconds(noBroadcastWaitAttempt);
      noBroadcastWaitAttempt =
          noBroadcastWaitAttempt < 10 ? noBroadcastWaitAttempt + 1 : 10;
      reconnectTimer = Timer(Duration(seconds: delaySec), () {
        if (stopping) return;
        emitDiscoveryState(source: 'wait_no_broadcast');
        scheduleReconnect('wait_no_broadcast');
      });
      return;
    }
    if (reconnectTimer?.isActive == true) return;

    noBroadcastWaitAttempt = 0;
    final delaySec = reconnectBackoffSeconds(reconnectAttempt);
    reconnectAttempt = reconnectAttempt < 10 ? reconnectAttempt + 1 : 10;
    reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (stopping) return;
      unawaited(connectTo(target, reason: reason));
    });
  }

  void startHeartbeatLoop() {
    heartbeatTimer?.cancel();
    if (sshClient == null || sshClient!.isClosed) return;

    heartbeatTimer =
        Timer.periodic(heartbeatIntervalForProfile(), (timer) async {
      if (sshClient == null || sshClient!.isClosed) {
        timer.cancel();
        await handleDisconnected('heartbeat_closed');
        scheduleReconnect('heartbeat_closed');
        return;
      }
      try {
        await sshClient!.run('true').timeout(heartbeatTimeoutForProfile());
      } catch (e) {
        debugPrint('Background heartbeat failed: $e');
        timer.cancel();
        await handleDisconnected('heartbeat_failed');
        scheduleReconnect('heartbeat_failed');
      }
    });
  }

  Future<void> applyActivityProfile(
    bool foreground, {
    String source = 'event',
  }) async {
    if (appForeground == foreground) {
      return;
    }
    appForeground = foreground;
    reconnectAttempt = 0;
    noBroadcastWaitAttempt = 0;
    clearReconnectTimer();
    startHeartbeatLoop();
    emitDiscoveryState(
      source: foreground
          ? 'profile_foreground_$source'
          : 'profile_background_$source',
    );
    await updateNotification(
      content: foreground ? '연결 감시(빠름)' : '연결 감시(절전)',
    );
  }

  connectTo = (String ip, {required String reason}) async {
    if (stopping || connectInFlight) return;
    if (!isValidIpv4(ip) || !hasConnectProfile()) return;

    connectInFlight = true;
    clearReconnectTimer();
    await closeClient();

    await updateNotification(title: 'CarrotLink: 연결 중...', content: 'IP: $ip');

    try {
      final username = profileUsername!;
      final socket = await SSHSocket.connect(
        ip,
        profilePort,
        timeout: const Duration(seconds: 8),
      );

      if (profilePrivateKey != null && profilePrivateKey!.isNotEmpty) {
        final keys = SSHKeyPair.fromPem(profilePrivateKey!);
        if (keys.isEmpty) {
          throw Exception('No valid keys in private key');
        }
        sshClient = SSHClient(socket, username: username, identities: keys);
      } else {
        sshClient = SSHClient(
          socket,
          username: username,
          onPasswordRequest: () => profilePassword,
        );
      }

      await sshClient!.authenticated.timeout(const Duration(seconds: 10));

      connectedIp = ip;
      connectedPort = profilePort;
      reconnectAttempt = 0;
      noBroadcastWaitAttempt = 0;

      emitConnectionState(
        isConnected: true,
        reason: reason,
        ip: connectedIp,
        port: connectedPort,
      );
      emitDiscoveryState(source: reason);

      await updateNotification(title: 'IP: $ip', content: '백업 확인 준비 중...');
      startHeartbeatLoop();
    } catch (e) {
      await handleDisconnected('connect_failed');
      emitConnectionState(
          isConnected: false,
          reason: 'connect_failed',
          error: e.toString(),
          ip: ip,
          port: profilePort);
      await updateNotification(
          title: 'CarrotLink: 연결 실패', content: '오류: ${e.toString()}');
      scheduleReconnect('connect_failed');
    } finally {
      connectInFlight = false;
    }
  };

  void onCandidateIp(String ip, {String source = 'udp'}) {
    if (!isValidIpv4(ip)) return;
    final now = DateTime.now();
    final changed = candidateIp != ip;
    final connectedChanged = connectedIp != null && connectedIp != ip;
    candidateIp = ip;
    candidateSeenAt = now;
    noBroadcastWaitAttempt = 0;
    emitDiscoveryState(source: source);

    if (changed ||
        lastCandidateBroadcastAt == null ||
        now.difference(lastCandidateBroadcastAt!) >
            candidateBroadcastDedupeWindow()) {
      lastCandidateBroadcastAt = now;
      service.invoke('candidateIp', {
        'ip': ip,
        'source': source,
        'ts': now.millisecondsSinceEpoch,
      });
    }

    if (connectedChanged && canAutoReconnect() && hasConnectProfile()) {
      unawaited(handleDisconnected('candidate_changed'));
      unawaited(connectTo(ip, reason: 'candidate_changed'));
      return;
    }

    if ((sshClient == null || sshClient!.isClosed) &&
        canAutoReconnect() &&
        hasConnectProfile()) {
      unawaited(connectTo(ip, reason: 'candidate_udp'));
    }
  }

  void scheduleDiscoveryRetry() {
    if (stopping) return;
    discoveryRetryTimer?.cancel();
    discoveryRetryTimer = Timer(const Duration(seconds: 3), () {
      if (stopping) return;
      discoverySocket?.close();
      discoverySocket = null;
      unawaited(startDiscoveryListener());
    });
  }

  startDiscoveryListener = () async {
    if (stopping) return;
    if (discoverySocket != null) return;
    try {
      discoverySocket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, 7705);
      discoveryListening = true;
      emitDiscoveryState(source: 'udp_bound');
      discoverySocket!.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            final datagram = discoverySocket!.receive();
            if (datagram == null) return;
            try {
              final message = utf8.decode(datagram.data);
              final decoded = json.decode(message);
              if (decoded is Map<String, dynamic>) {
                final ip = decoded['ip'];
                if (ip is String) {
                  onCandidateIp(ip, source: 'udp_broadcast');
                }
              }
            } catch (_) {}
          } else if (event == RawSocketEvent.closed) {
            discoveryListening = false;
            emitDiscoveryState(source: 'udp_closed');
            discoverySocket = null;
            scheduleDiscoveryRetry();
          }
        },
        onError: (e) {
          debugPrint('Discovery socket error: $e');
          discoveryListening = false;
          emitDiscoveryState(source: 'udp_error');
          discoverySocket = null;
          scheduleDiscoveryRetry();
        },
      );
    } catch (e) {
      debugPrint('Failed to bind UDP discovery socket: $e');
      discoveryListening = false;
      emitDiscoveryState(source: 'udp_bind_failed');
      scheduleDiscoveryRetry();
    }
  };

  await updateNotification(title: 'CarrotLink', content: '연결 대기 중...');
  await startDiscoveryListener();
  emitDiscoveryState(source: 'service_start');

  service.on('connect').listen((event) async {
    if (event == null) return;
    final ip = event['ip']?.toString() ?? '';
    final portRaw = event['port'];
    final port = portRaw is int
        ? portRaw
        : int.tryParse(portRaw?.toString() ?? '') ?? 22;
    profileUsername = event['username']?.toString();
    final pw = event['password'];
    final key = event['privateKey'];
    profilePassword = pw is String && pw.isNotEmpty ? pw : null;
    profilePrivateKey = key is String && key.isNotEmpty ? key : null;
    profilePort = port;
    autoReconnectEnabled = true;
    manualDisconnectRequested = false;
    manualDisconnectUntil = null;
    emitDiscoveryState(source: 'manual_connect');
    if (isValidIpv4(ip)) {
      await connectTo(ip, reason: 'manual_connect');
    }
  });

  service.on('configureAutoConnect').listen((event) async {
    if (event == null) return;
    final username = event['username']?.toString();
    if (username != null && username.isNotEmpty) {
      profileUsername = username;
    }
    final pw = event['password'];
    final key = event['privateKey'];
    profilePassword = pw is String && pw.isNotEmpty ? pw : null;
    profilePrivateKey = key is String && key.isNotEmpty ? key : null;

    final portRaw = event['port'];
    final parsedPort =
        portRaw is int ? portRaw : int.tryParse(portRaw?.toString() ?? '');
    if (parsedPort != null && parsedPort > 0 && parsedPort < 65536) {
      profilePort = parsedPort;
    }

    final auto = event['autoReconnectEnabled'];
    if (auto is bool) {
      autoReconnectEnabled = auto;
    }
    if (event['resumeAutoReconnect'] == true) {
      manualDisconnectRequested = false;
      manualDisconnectUntil = null;
    }

    emitDiscoveryState(source: 'configure');
    if ((sshClient == null || sshClient!.isClosed) &&
        canAutoReconnect() &&
        hasConnectProfile()) {
      final target = pickReconnectTarget();
      if (target != null) {
        unawaited(connectTo(target, reason: 'profile_sync'));
      } else {
        scheduleReconnect('profile_sync_wait_broadcast');
      }
    }
  });

  service.on('resumeAutoReconnect').listen((event) {
    manualDisconnectRequested = false;
    manualDisconnectUntil = null;
    autoReconnectEnabled = true;
    emitDiscoveryState(source: 'resume_auto_reconnect');
    if ((sshClient == null || sshClient!.isClosed) && hasConnectProfile()) {
      final target = pickReconnectTarget();
      if (target != null) {
        unawaited(connectTo(target, reason: 'resume_auto_reconnect'));
      } else {
        scheduleReconnect('resume_wait_broadcast');
      }
    }
  });

  service.on('ensureDiscovery').listen((event) {
    if (discoverySocket == null) {
      unawaited(startDiscoveryListener());
    } else {
      emitDiscoveryState(source: 'ensure_discovery');
    }
  });

  service.on('candidateHint').listen((event) {
    if (event == null) return;
    final ip = event['ip']?.toString() ?? '';
    if (!isValidIpv4(ip)) return;
    final source = event['source']?.toString() ?? 'hint';
    onCandidateIp(ip, source: source);
  });

  service.on('setAppVisibility').listen((event) async {
    if (event == null) return;
    final foreground = event['foreground'] == true;
    final source = event['source']?.toString() ?? 'setAppVisibility';
    await applyActivityProfile(foreground, source: source);
    if ((sshClient == null || sshClient!.isClosed) &&
        canAutoReconnect() &&
        hasConnectProfile()) {
      scheduleReconnect('profile_switch');
    }
  });

  service.on('execute').listen((event) async {
    if (event == null) return;
    final id = event['id'];
    final cmd = event['cmd'];

    if (sshClient == null || sshClient!.isClosed) {
      service.invoke('commandResult', {'id': id, 'error': 'Not connected'});
      return;
    }

    try {
      final result = await sshClient!.run(cmd);
      final output = utf8.decode(result);
      service.invoke('commandResult', {'id': id, 'output': output});
    } catch (e) {
      service.invoke('commandResult', {'id': id, 'error': e.toString()});
    }
  });

  service.on('getStatus').listen((event) {
    service.invoke('status', {
      'isConnected': sshClient != null && !sshClient!.isClosed,
      'ip': connectedIp,
      'port': connectedPort,
      'candidateIp': candidateIp,
      'candidateSeenAt': candidateSeenAt?.millisecondsSinceEpoch,
      'listening': discoveryListening,
      'autoReconnectEnabled': autoReconnectEnabled,
      'manualDisconnectRequested': manualDisconnectRequested,
      'appForeground': appForeground,
    });
    emitDiscoveryState(source: 'status');
  });

  service.on('disconnect').listen((event) async {
    await handleDisconnected('manual_disconnect', manual: true);
    clearReconnectTimer();
  });

  service.on('stopService').listen((event) {
    stopping = true;
    clearReconnectTimer();
    discoveryRetryTimer?.cancel();
    discoveryRetryTimer = null;
    heartbeatTimer?.cancel();
    heartbeatTimer = null;
    try {
      discoverySocket?.close();
    } catch (_) {}
    discoverySocket = null;
    discoveryListening = false;
    unawaited(closeClient());
    service.stopSelf();
  });

  service.on('updateContent').listen((event) async {
    if (event != null) {
      await updateNotification(
        title: event['title'],
        content: event['content'],
      );
    }
  });
}
