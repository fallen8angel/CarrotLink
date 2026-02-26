import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Notification Channel ID
const String notificationChannelId = 'carrot_link_service';
const int notificationId = 888;

// Actions
const String actionDisconnect = 'disconnect';

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  // Android Notification Channel Setup
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId,
    'CarrotLink Service',
    description: 'CarrotLink 백그라운드 연결 유지 서비스',
    importance: Importance.low,
    showBadge: false,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Initialize Notifications with Actions
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings(
          '@mipmap/launcher_icon'); // Ensure icon exists
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
  String currentTitle = 'CarrotLink';
  String currentContent = '연결 대기 중...';

  // Helper to update notification
  Future<void> updateNotification(
      {String? title, String? content, bool isConnected = false}) async {
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

  // Initial Notification Update
  await updateNotification(
    title: 'CarrotLink',
    content: '연결 대기 중...',
    isConnected: false,
  );

  // Connect SSH
  service.on('connect').listen((event) async {
    if (event == null) return;
    final ip = event['ip'];
    final portRaw = event['port'];
    final port = portRaw is int
        ? portRaw
        : int.tryParse(portRaw?.toString() ?? '') ?? 22;
    final username = event['username'];
    final password = event['password'];
    final privateKey = event['privateKey'];

    try {
      heartbeatTimer?.cancel();
      sshClient?.close();
      sshClient = null;

      await updateNotification(
          title: 'CarrotLink: 연결 중...', content: 'IP: $ip');

      final socket = await SSHSocket.connect(ip, port,
          timeout: const Duration(seconds: 10));

      if (privateKey != null) {
        final keys = SSHKeyPair.fromPem(privateKey);
        sshClient = SSHClient(socket, username: username, identities: keys);
      } else {
        sshClient = SSHClient(socket,
            username: username, onPasswordRequest: () => password);
      }

      await sshClient!.authenticated;

      // Set Title to IP as requested
      await updateNotification(
          title: 'IP: $ip', content: '백업 확인 준비 중...', isConnected: true);

      // Notify UI
      service.invoke('connectionState', {'isConnected': true, 'ip': ip});

      // Start Heartbeat
      heartbeatTimer?.cancel();
      // Check every 5 seconds
      heartbeatTimer =
          Timer.periodic(const Duration(seconds: 5), (timer) async {
        if (sshClient == null || sshClient!.isClosed) {
          timer.cancel();
          await updateNotification(
              title: 'CarrotLink: 연결 끊김', content: '재연결 대기 중...');
          service.invoke('connectionState', {'isConnected': false});
          return;
        }
        try {
          // Use a short timeout (2s) to detect dead connections quickly
          await sshClient!.run('true').timeout(const Duration(seconds: 2));
        } catch (e) {
          debugPrint("Background Heartbeat failed: $e");
          sshClient?.close();
          // Force update notification immediately
          await updateNotification(
              title: 'CarrotLink: 연결 끊김', content: '재연결 대기 중...');
          service.invoke('connectionState', {'isConnected': false});
        }
      });
    } catch (e) {
      await updateNotification(
          title: 'CarrotLink: 연결 실패', content: '오류: ${e.toString()}');
      service.invoke(
          'connectionState', {'isConnected': false, 'error': e.toString()});
      sshClient?.close();
      sshClient = null;
    }
  });

  // Execute Command
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

  // Get Status
  service.on('getStatus').listen((event) {
    service.invoke('status', {
      'isConnected': sshClient != null && !sshClient!.isClosed,
    });
  });

  // Disconnect SSH
  service.on('disconnect').listen((event) async {
    heartbeatTimer?.cancel();
    sshClient?.close();
    sshClient = null;
    await updateNotification(title: 'CarrotLink: 연결 해제됨', content: '대기 중...');
  });

  service.on('stopService').listen((event) {
    heartbeatTimer?.cancel();
    sshClient?.close();

    // Stopping the background service should not forcibly close the app UI.
    // This can otherwise look like an unexpected app restart when returning.
    service.stopSelf();
  });

  service.on('updateContent').listen((event) async {
    if (event != null) {
      await updateNotification(
        title: event['title'], // Can be null, will use currentTitle
        content: event['content'], // Can be null, will use currentContent
        isConnected: sshClient != null && !sshClient!.isClosed,
      );
    }
  });
}
