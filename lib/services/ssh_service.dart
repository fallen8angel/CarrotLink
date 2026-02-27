import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../constants.dart';
import 'diagnostics_service.dart';

class SSHCommandResult {
  final String command;
  final String stdout;
  final String stderr;
  final int exitCode;
  final Duration duration;

  const SSHCommandResult({
    required this.command,
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.duration,
  });

  bool get isSuccess => exitCode == 0;

  String get output {
    if (stdout.isNotEmpty && stderr.isNotEmpty) {
      return '$stdout\n$stderr';
    }
    if (stdout.isNotEmpty) return stdout;
    return stderr;
  }
}

class SSHService extends ChangeNotifier {
  SSHClient? _client;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final DiagnosticsService _diag = DiagnosticsService.instance;
  static const int _defaultSshPort = 22;
  static const int _maxHeartbeatFailures = 5;
  static const Duration _heartbeatInterval = Duration(seconds: 8);
  static const Duration _heartbeatTimeout = Duration(seconds: 4);

  SSHService() {
    _initServiceListener();
  }

  void _initServiceListener() {
    final service = FlutterBackgroundService();

    service.on('connectionState').listen((event) async {
      if (event == null) return;
      final isServiceConnected = event['isConnected'] == true;
      final serviceIp = event['ip']?.toString();
      _serviceConnectedIp =
          (serviceIp != null && _isValidIpv4(serviceIp)) ? serviceIp : null;

      if (!isServiceConnected) {
        if (!isConnected && _connectionStatus != "Disconnected") {
          _handleDisconnect(notifyService: false, reason: "background");
        }
        notifyListeners();
        return;
      }

      if (_manualDisconnectRequested || isConnected || _isConnecting) {
        notifyListeners();
        return;
      }

      if (_serviceConnectedIp != null) {
        await _reconnectFromStorage(preferredIp: _serviceConnectedIp);
      } else {
        await _reconnectFromStorage();
      }
      notifyListeners();
    });

    service.on('candidateIp').listen((event) {
      if (event == null) return;
      final ip = event['ip']?.toString();
      if (ip == null || !_isValidIpv4(ip)) return;
      _serviceCandidateIp = ip;
      final tsRaw = event['ts'];
      if (tsRaw is int && tsRaw > 0) {
        _serviceCandidateSeenAt =
            DateTime.fromMillisecondsSinceEpoch(tsRaw, isUtc: false);
      } else {
        _serviceCandidateSeenAt = DateTime.now();
      }
      _emitDiscoveredIp(ip);
      notifyListeners();
    });

    service.on('discoveryState').listen((event) {
      if (event == null) return;
      _serviceDiscoveryListening = event['listening'] == true;
      final source = event['source']?.toString();
      if (source != null && source.isNotEmpty) {
        _serviceDiscoverySource = source;
      }
      final candidate = event['candidateIp']?.toString();
      if (candidate != null && _isValidIpv4(candidate)) {
        _serviceCandidateIp = candidate;
      }
      final ageRaw = event['candidateAgeMs'];
      if (ageRaw is int && _serviceCandidateIp != null) {
        _serviceCandidateSeenAt = DateTime.now().subtract(
          Duration(milliseconds: ageRaw.clamp(0, 3600000)),
        );
      }
      final connected = event['connectedIp']?.toString();
      _serviceConnectedIp =
          (connected != null && _isValidIpv4(connected)) ? connected : null;
      notifyListeners();
    });

    service.on('status').listen((event) async {
      if (event == null) return;
      _serviceDiscoveryListening = event['listening'] == true;
      final candidate = event['candidateIp']?.toString();
      if (candidate != null && _isValidIpv4(candidate)) {
        _serviceCandidateIp = candidate;
      }
      final tsRaw = event['candidateSeenAt'];
      if (tsRaw is int && tsRaw > 0) {
        _serviceCandidateSeenAt =
            DateTime.fromMillisecondsSinceEpoch(tsRaw, isUtc: false);
      }
      final ip = event['ip']?.toString();
      _serviceConnectedIp = (ip != null && _isValidIpv4(ip)) ? ip : null;

      if (_manualDisconnectRequested) {
        notifyListeners();
        return;
      }
      if (event['isConnected'] == true && !isConnected && !_isConnecting) {
        await _reconnectFromStorage(preferredIp: _serviceConnectedIp);
      }
      notifyListeners();
    });

    unawaited(_syncAutoConnectProfileToService());
    service.invoke('ensureDiscovery');
    service.invoke('getStatus');
  }

  Future<void> _syncAutoConnectProfileToService(
      {bool resumeAutoReconnect = false}) async {
    final ip = await _storage.read(key: 'ssh_ip');
    final username = await _storage.read(key: 'ssh_username');
    final password = await _storage.read(key: 'ssh_password');
    final portStr = await _storage.read(key: 'ssh_port');
    final privateKey = await _storage.read(key: 'current_private_key');
    final port = int.tryParse(portStr ?? '') ?? _defaultSshPort;

    FlutterBackgroundService().invoke('configureAutoConnect', {
      'ip': ip,
      'username': username ?? 'comma',
      'password': password,
      'privateKey': privateKey,
      'port': port,
      'autoReconnectEnabled': true,
      'resumeAutoReconnect': resumeAutoReconnect,
    });
  }

  Future<void> _reconnectFromStorage({String? preferredIp}) async {
    final ip = await _storage.read(key: 'ssh_ip');
    final username = await _storage.read(key: 'ssh_username');
    final password = await _storage.read(key: 'ssh_password');
    final portStr = await _storage.read(key: 'ssh_port');
    final port = int.tryParse(portStr ?? '') ?? _defaultSshPort;

    // 새로운 키 저장 구조에서 로드
    final privateKey = await _storage.read(key: 'current_private_key');

    final targetIp = preferredIp != null && _isValidIpv4(preferredIp)
        ? preferredIp
        : (ip ?? _serviceCandidateIp);

    print(
        '[SSHService] Reconnect from storage - IP: $targetIp, Username: $username, Port: $port');
    _diag.info(
        'ssh', 'Reconnect from storage target=$targetIp:$port user=$username');

    if (targetIp != null && username != null) {
      // Reconnect using standard flow
      await connect(targetIp, username,
          port: port, password: password, privateKey: privateKey);
    }
  }

  bool get isConnected => _client != null && !_client!.isClosed;
  String _connectionStatus = "Disconnected";
  String get connectionStatus => _connectionStatus;
  String? _connectedIp;
  String? get connectedIp => _connectedIp;
  int? _connectedPort;
  int? get connectedPort => _connectedPort;

  String? _targetIp;
  String? get targetIp => _targetIp;
  int? _targetPort;
  int? get targetPort => _targetPort;

  bool _serviceDiscoveryListening = false;
  bool get serviceDiscoveryListening => _serviceDiscoveryListening;
  String _serviceDiscoverySource = 'none';
  String get serviceDiscoverySource => _serviceDiscoverySource;
  String? _serviceCandidateIp;
  String? get serviceCandidateIp => _serviceCandidateIp;
  DateTime? _serviceCandidateSeenAt;
  DateTime? get serviceCandidateSeenAt => _serviceCandidateSeenAt;
  String? _serviceConnectedIp;
  String? get serviceConnectedIp => _serviceConnectedIp;

  // IP Discovery
  StreamController<String>? _ipDiscoveryController;
  Stream<String> get ipDiscoveryStream {
    _ipDiscoveryController ??= StreamController<String>.broadcast();
    return _ipDiscoveryController!.stream;
  }

  Timer? _discoveryStopTimer;
  Timer? _heartbeatTimer;
  bool _isDiscoveryActive = false;
  bool get isDiscoveryActive => _isDiscoveryActive;
  String _discoverySource = 'none';
  String get discoverySource => _discoverySource;
  bool _discoveryManualSession = false;
  bool get discoveryManualSession => _discoveryManualSession;
  DateTime? _discoverySessionEndsAt;
  DateTime? get discoverySessionEndsAt => _discoverySessionEndsAt;
  int _discoveryGeneration = 0;
  String? _lastDiscoveredIp;
  DateTime? _lastDiscoveredAt;

  bool _isConnecting = false;
  bool get isConnecting => _isConnecting;
  Future<void> _commandQueue = Future.value();
  int _runningCommandCount = 0;
  bool get isCommandBusy => _runningCommandCount > 0;
  bool _isHandlingDisconnect = false;
  bool _heartbeatInFlight = false;
  int _heartbeatFailureCount = 0;
  bool _manualDisconnectRequested = false;
  DateTime? _manualDisconnectUntil;
  static const Duration _manualDisconnectCooldown = Duration(seconds: 20);
  bool get manualDisconnectRequested {
    if (!_manualDisconnectRequested) return false;
    final until = _manualDisconnectUntil;
    if (until == null) return true;
    if (DateTime.now().isBefore(until)) return true;
    _manualDisconnectRequested = false;
    _manualDisconnectUntil = null;
    return false;
  }

  Future<void> connect(
    String ip,
    String username, {
    int port = _defaultSshPort,
    String? password,
    String? privateKey,
  }) async {
    if (_isConnecting) return;

    _manualDisconnectRequested = false;
    _manualDisconnectUntil = null;
    _isConnecting = true;
    _targetIp = ip; // Set target IP immediately
    _targetPort = port;
    _connectionStatus = "Connecting to $ip:$port...";
    _diag.info('ssh', 'Connecting to $ip:$port as $username');
    // _connectedIp = ip; // Do not set IP until connected to avoid "Ghost IP"

    notifyListeners();

    try {
      final socket = await SSHSocket.connect(ip, port,
          timeout: const Duration(seconds: 5));

      // Check if disconnected while connecting
      if (!_isConnecting) {
        socket.destroy();
        return;
      }

      if (privateKey != null) {
        try {
          print("Debug: Attempting to parse PEM key...");
          print("Debug: Key starts with: ${privateKey.substring(0, 50)}...");

          final keys = SSHKeyPair.fromPem(privateKey);
          print("Debug: Parsed ${keys.length} keys from PEM.");

          if (keys.isEmpty) {
            throw Exception("No valid keys found in the provided PEM.");
          }

          print("Debug: Key type: ${keys.first.type}");

          _client = SSHClient(
            socket,
            username: username,
            identities: keys,
          );
        } catch (e) {
          print("Debug: Key parsing/auth failed: $e");
          rethrow;
        }
      } else {
        _client = SSHClient(
          socket,
          username: username,
          onPasswordRequest: () => password,
        );
      }

      await _client!.authenticated.timeout(const Duration(seconds: 10));

      // Check if disconnected while authenticating
      if (!_isConnecting) {
        _client?.close();
        _client = null;
        return;
      }

      _connectionStatus = "Connected";
      _connectedIp = ip; // Set IP only after successful connection
      _connectedPort = port;
      _diag.info('ssh', 'Connected to $ip:$port');

      // 키 인증 성공 시 key_verified = true 설정
      if (privateKey != null) {
        await _storage.write(key: 'key_verified', value: 'true');
      }

      // Start Background Service Connection
      FlutterBackgroundService().invoke('connect', {
        'ip': ip,
        'port': port,
        'username': username,
        'password': password,
        'privateKey': privateKey,
      });

      // Listen for immediate disconnection events from the socket
      _client!.done.then((_) {
        print("SSH Connection closed by OS/Remote");
        _handleDisconnect(reason: "socket closed");
      }).catchError((e) {
        print("SSH Connection error: $e");
        _handleDisconnect(reason: "socket error");
      });

      _startHeartbeat();
    } catch (e) {
      print("Connection failed: $e");
      _connectionStatus = _mapErrorToMessage(e);
      _diag.warn('ssh', 'Connection failed target=$ip:$port error=$e');
      _client = null;
      _connectedIp = null; // Clear IP on error
      _connectedPort = null;
      _targetIp = null;
      _targetPort = null;
      rethrow;
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }

  String _mapErrorToMessage(dynamic error) {
    final e = error.toString();
    if (e.contains("SocketException") ||
        e.contains("Connection refused") ||
        e.contains("Network is unreachable")) {
      return "연결 실패 (네트워크)";
    } else if (e.contains("TimeoutException")) {
      return "연결 시간 초과";
    } else if (e.contains("Authentication failed") || e.contains("password")) {
      return "인증 실패";
    } else if (e.contains("No valid keys")) {
      return "키 오류";
    }
    return "오류 발생";
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatFailureCount = 0;
    _heartbeatInFlight = false;

    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (timer) async {
      if (_client == null) {
        timer.cancel();
        _handleDisconnect(reason: "heartbeat: no client");
        return;
      }

      if (_client!.isClosed) {
        print("Heartbeat: Client is closed");
        timer.cancel();
        _handleDisconnect(reason: "heartbeat: client closed");
        return;
      }

      if (_heartbeatInFlight) {
        return;
      }
      // Avoid overlapping extra probes while a command pipeline is busy.
      if (_runningCommandCount > 0) {
        return;
      }

      _heartbeatInFlight = true;
      try {
        await _client!.run('true').timeout(_heartbeatTimeout);
        _heartbeatFailureCount = 0;
      } catch (e) {
        _heartbeatFailureCount += 1;
        print(
            "Heartbeat failed (${_heartbeatFailureCount}/$_maxHeartbeatFailures): $e");
        if (_heartbeatFailureCount >= _maxHeartbeatFailures) {
          timer.cancel();
          _handleDisconnect(reason: "heartbeat failures");
        }
      } finally {
        _heartbeatInFlight = false;
      }
    });
  }

  // 연결 해제 즉시 처리
  void _handleDisconnect({
    bool notifyService = true,
    String reason = "unknown",
    bool manual = false,
  }) {
    if (_isHandlingDisconnect) return;
    if (_client == null && _connectionStatus == "Disconnected" && !manual)
      return; // 이미 처리됨
    _isHandlingDisconnect = true;

    try {
      print("Connection lost - updating state immediately (reason: $reason)");
      _diag.warn('ssh', 'Disconnected reason=$reason manual=$manual');
      _manualDisconnectRequested = manual;
      _manualDisconnectUntil =
          manual ? DateTime.now().add(_manualDisconnectCooldown) : null;
      _isConnecting = false;
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _heartbeatInFlight = false;
      _heartbeatFailureCount = 0;
      _sftp?.close();
      _sftp = null;
      _client?.close();
      _client = null;
      _connectionStatus = "Disconnected";
      _connectedIp = null;
      _connectedPort = null;
      _targetIp = null;
      _targetPort = null;

      if (notifyService) {
        FlutterBackgroundService().invoke('disconnect');
      }
      notifyListeners(); // 즉시 UI 업데이트
    } finally {
      _isHandlingDisconnect = false;
    }
  }

  Future<String> executeCommand(String command) async {
    try {
      final result = await executeCommandResult(command);
      return result.output;
    } catch (e) {
      return "Error executing command: $e";
    }
  }

  Future<SSHCommandResult> executeCommandResult(
    String command, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (!isConnected) {
      throw Exception("Not Connected");
    }

    return _enqueueCommand(() async {
      if (!isConnected) {
        throw Exception("Not Connected");
      }

      final startedAt = DateTime.now();
      _runningCommandCount += 1;
      notifyListeners();

      try {
        final session = await _client!.execute(command);
        final stdoutBytes = <int>[];
        final stderrBytes = <int>[];

        final stdoutDone = Completer<void>();
        final stderrDone = Completer<void>();

        late final StreamSubscription<List<int>> stdoutSub;
        late final StreamSubscription<List<int>> stderrSub;

        stdoutSub = session.stdout.listen(
          stdoutBytes.addAll,
          onError: (_) {},
          onDone: () => stdoutDone.complete(),
        );
        stderrSub = session.stderr.listen(
          stderrBytes.addAll,
          onError: (_) {},
          onDone: () => stderrDone.complete(),
        );

        try {
          await session.done.timeout(timeout);
          await Future.wait([stdoutDone.future, stderrDone.future]);
        } on TimeoutException {
          try {
            session.close();
          } catch (_) {}
          throw Exception("Command timeout after ${timeout.inSeconds}s");
        } finally {
          await stdoutSub.cancel();
          await stderrSub.cancel();
        }

        final duration = DateTime.now().difference(startedAt);
        final stdout = utf8.decode(stdoutBytes, allowMalformed: true).trim();
        final stderr = utf8.decode(stderrBytes, allowMalformed: true).trim();
        final exitCode = session.exitCode ?? 255;

        return SSHCommandResult(
          command: command,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          duration: duration,
        );
      } catch (e) {
        print("Command execution failed: $e");
        final errorStr = e.toString();
        if (errorStr.contains("SocketException") ||
            errorStr.contains("Connection closed") ||
            errorStr.contains("Broken pipe") ||
            errorStr.contains("Connection reset") ||
            errorStr.contains("Software caused connection abort")) {
          _handleDisconnect(reason: "command error");
        }
        rethrow;
      } finally {
        _runningCommandCount = (_runningCommandCount - 1).clamp(0, 1 << 30);
        notifyListeners();
      }
    });
  }

  Future<T> _enqueueCommand<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _commandQueue = _commandQueue.catchError((_) {}).then((_) async {
      try {
        final result = await action();
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (e, st) {
        if (!completer.isCompleted) {
          completer.completeError(e, st);
        }
      }
    });
    return completer.future;
  }

  /// Executes a command and streams stdout/stderr.
  /// Returns the exit code.
  Stream<List<int>> executeCommandStream(String command,
      {Function(int)? onExit}) async* {
    if (!isConnected) throw Exception("Not Connected");

    final session = await _client!.execute(command);

    // Merge stdout and stderr
    // Note: This is a simple merge. For strict separation, we'd need a different return type.
    // But for a terminal-like view, merging is usually fine or we can prefix.

    // We can't easily merge two streams into one generator without a controller or complex logic,
    // but dartssh2 sessions expose stdout and stderr streams.

    final controller = StreamController<List<int>>();

    session.stdout.listen((data) {
      controller.add(data);
    }, onError: (e) {
      controller.addError(e);
    });

    session.stderr.listen((data) {
      controller.add(data);
    }, onError: (e) {
      controller.addError(e);
    });

    controller.onCancel = () {
      try {
        session.close();
      } catch (_) {}
    };

    session.done.then((_) {
      if (onExit != null && session.exitCode != null) {
        onExit(session.exitCode!);
      }
      if (!controller.isClosed) {
        controller.close();
      }
    });

    yield* controller.stream;
  }

  Future<SSHSession> startShell({
    int width = 80,
    int height = 24,
  }) async {
    if (!isConnected) throw Exception("Not Connected");
    final ptyWidth = width <= 0 ? 80 : width;
    final ptyHeight = height <= 0 ? 24 : height;
    final session = await _client!.shell(
      pty: SSHPtyConfig(
        width: ptyWidth,
        height: ptyHeight,
      ),
    );
    return session;
  }

  SftpClient? _sftp;

  Future<SftpClient> get sftp async {
    if (_sftp != null) return _sftp!;
    if (_client == null) throw Exception("Not connected");
    _sftp = await _client!.sftp();
    return _sftp!;
  }

  Future<List<SftpName>> listFiles(String path) async {
    final client = await sftp;
    final files = await client.listdir(path);
    // Sort: Directories first, then files
    files.sort((a, b) {
      final aIsDir = a.attr.isDirectory;
      final bIsDir = b.attr.isDirectory;
      if (aIsDir && !bIsDir) return -1;
      if (!aIsDir && bIsDir) return 1;
      return a.filename.compareTo(b.filename);
    });
    return files;
  }

  Future<void> renameFile(String oldPath, String newPath) async {
    final client = await sftp;
    await client.rename(oldPath, newPath);
  }

  Future<void> deleteFile(String path) async {
    final client = await sftp;
    // Check if it's a directory or file
    final stat = await client.stat(path);
    if (stat.isDirectory) {
      await client.rmdir(path);
    } else {
      await client.remove(path);
    }
  }

  Future<String> readTextFile(String path) async {
    final client = await sftp;
    final file = await client.open(path);
    final size = (await file.stat()).size ?? 0;
    final content = file.read(length: size);

    final List<int> bytes = [];
    await for (final chunk in content) {
      bytes.addAll(chunk);
    }

    await file.close();
    return utf8.decode(bytes);
  }

  Future<void> writeTextFile(String path, String content) async {
    final client = await sftp;
    final file = await client.open(path,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate);
    await file.write(Stream.value(utf8.encode(content)));
    await file.close();
  }

  Future<Uint8List> readBinaryFile(String path) async {
    final client = await sftp;
    final file = await client.open(path);
    final stat = await client.stat(path);
    final size = stat.size ?? 0;
    final stream = file.read(length: size);
    final chunks = <int>[];
    await for (final chunk in stream) {
      chunks.addAll(chunk);
    }
    await file.close();
    return Uint8List.fromList(chunks);
  }

  /// Streams a remote file directly to local disk to reduce memory pressure.
  Future<void> downloadBinaryFile(
    String remotePath,
    String localPath, {
    void Function(int received, int total)? onProgress,
    bool Function()? shouldCancel,
    Future<void> Function()? waitIfPaused,
  }) async {
    final client = await sftp;
    final remote = await client.open(remotePath);
    final total = (await remote.stat()).size ?? 0;
    final localFile = File(localPath);
    final localDir = localFile.parent;
    if (!await localDir.exists()) {
      await localDir.create(recursive: true);
    }

    final sink = localFile.openWrite(mode: FileMode.writeOnly);
    var received = 0;

    try {
      final stream = total > 0 ? remote.read(length: total) : remote.read();
      await for (final chunk in stream) {
        await waitIfPaused?.call();
        if (shouldCancel?.call() == true) {
          throw Exception('TRANSFER_CANCELLED');
        }
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
      await remote.close();
    }
  }

  /// Streams a local file to remote path to avoid loading entire file in memory.
  Future<void> uploadBinaryFile(
    String localPath,
    String remotePath, {
    void Function(int sent, int total)? onProgress,
    bool Function()? shouldCancel,
    Future<void> Function()? waitIfPaused,
  }) async {
    final client = await sftp;
    final localFile = File(localPath);
    if (!await localFile.exists()) {
      throw Exception("Local file not found: $localPath");
    }

    final total = await localFile.length();
    var sent = 0;

    // Ensure parent directory exists.
    final sep = remotePath.lastIndexOf('/');
    if (sep > 0) {
      final parent = remotePath.substring(0, sep);
      final quotedParent = "'${parent.replaceAll("'", "'\"'\"'")}'";
      final mkdir = await executeCommandResult("mkdir -p -- $quotedParent");
      if (!mkdir.isSuccess) {
        throw Exception(
            "Failed to create remote directory: ${mkdir.output.trim()}");
      }
    }

    final remote = await client.open(
      remotePath,
      mode: SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );

    Stream<Uint8List> progressStream() async* {
      await for (final chunk in localFile.openRead()) {
        await waitIfPaused?.call();
        if (shouldCancel?.call() == true) {
          throw Exception('TRANSFER_CANCELLED');
        }
        sent += chunk.length;
        onProgress?.call(sent, total);
        yield Uint8List.fromList(chunk);
      }
    }

    try {
      await remote.write(progressStream());
    } finally {
      await remote.close();
    }
  }

  Future<void> disconnect({bool fromService = false}) async {
    _handleDisconnect(
      notifyService: !fromService,
      reason: fromService ? "service event" : "manual request",
      manual: !fromService,
    );
  }

  void resumeAutoReconnect() {
    _manualDisconnectRequested = false;
    _manualDisconnectUntil = null;
    FlutterBackgroundService().invoke('resumeAutoReconnect');
    unawaited(_syncAutoConnectProfileToService(resumeAutoReconnect: true));
    notifyListeners();
  }

  Future<void> saveConnection(
    String ip,
    String username,
    String? password,
    String? keyPath, {
    int port = _defaultSshPort,
  }) async {
    await _storage.write(key: 'ssh_ip', value: ip);
    await _storage.write(key: 'ssh_username', value: username);
    await _storage.write(key: 'ssh_port', value: port.toString());
    if (password != null)
      await _storage.write(key: 'ssh_password', value: password);
    if (keyPath != null)
      await _storage.write(key: 'ssh_key_path', value: keyPath);
    await _syncAutoConnectProfileToService();
  }

  // Helper methods for Dashboard
  Future<String> getBranch() async {
    return (await executeCommand(CarrotConstants.gitBranchCmd)).trim();
  }

  Future<String> getDongleId() async {
    try {
      return (await executeCommand(CarrotConstants.dongleIdCmd)).trim();
    } catch (e) {
      return "Unknown";
    }
  }

  Future<String> getSerial() async {
    try {
      return (await executeCommand(CarrotConstants.serialCmd)).trim();
    } catch (e) {
      return "Unknown";
    }
  }

  Future<String> getCpuTemp() async {
    // This path might vary depending on the device (C2/C3). Using a generic thermal zone.
    // Often thermal_zone0 is CPU.
    final result =
        await executeCommand("cat /sys/class/thermal/thermal_zone0/temp");
    try {
      final temp = int.parse(result.trim());
      return "${(temp / 1000).toStringAsFixed(1)}°C";
    } catch (e) {
      return "N/A";
    }
  }

  Future<String> getStorageUsage() async {
    final result =
        await executeCommand("df -h /data | awk 'NR==2 {print \$5}'");
    return result.trim();
  }

  Future<String> getCommitHash() async {
    return (await executeCommand(CarrotConstants.gitCommitCmd)).trim();
  }

  Future<String> getCarModel() async {
    // This is tricky, usually stored in params or log.
    // Let's try to read a param if possible, or just return a placeholder.
    // For now, let's return "Unknown" or try to cat a file.
    return "Unknown";
  }

  Future<bool> startDiscovery({
    bool forceRestart = false,
    Duration timeout = const Duration(seconds: 30),
    String source = 'auto',
    bool manualSession = false,
  }) async {
    if (_isDiscoveryActive && !forceRestart) return false; // 중복 실행 방지
    if (_isDiscoveryActive && forceRestart) {
      stopDiscovery();
    }

    _isDiscoveryActive = true;
    _discoverySource = source;
    _discoveryManualSession = manualSession;
    _discoverySessionEndsAt = DateTime.now().add(timeout);
    _diag.info('discovery',
        'Start source=$source manual=$manualSession timeout=${timeout.inSeconds}s');
    _discoveryGeneration += 1;
    final generation = _discoveryGeneration;

    // 컨트롤러 재생성 (닫혀있을 수 있음)
    if (_ipDiscoveryController == null || _ipDiscoveryController!.isClosed) {
      _ipDiscoveryController = StreamController<String>.broadcast();
    }

    // Passive discovery is now owned by background service.
    final service = FlutterBackgroundService();
    service.invoke('ensureDiscovery');
    unawaited(_syncAutoConnectProfileToService());

    _discoveryStopTimer?.cancel();
    _discoveryStopTimer = Timer(timeout, () {
      if (_isDiscoveryActive && generation == _discoveryGeneration) {
        stopDiscovery();
      }
    });

    // 2. Start Active Subnet Scan
    unawaited(_scanSubnet(generation));
    return true;
  }

  Future<void> _scanSubnet(int generation) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        if (!_isDiscoveryActive || generation != _discoveryGeneration) return;
        for (final addr in interface.addresses) {
          if (!_isDiscoveryActive || generation != _discoveryGeneration) return;
          if (addr.isLoopback) continue;

          final ip = addr.address;
          final parts = ip.split('.');
          if (parts.length != 4) continue;

          final prefix = "${parts[0]}.${parts[1]}.${parts[2]}";

          // Scan 1-254 in batches to avoid FD limits
          for (int i = 1; i < 255; i += 20) {
            if (!_isDiscoveryActive || generation != _discoveryGeneration)
              return;
            final futures = <Future>[];
            for (int j = 0; j < 20 && (i + j) < 255; j++) {
              final targetIp = "$prefix.${i + j}";
              if (targetIp == ip) continue; // Skip self
              futures.add(_checkPort(targetIp, _defaultSshPort, generation));
            }
            await Future.wait(futures);
          }
        }
      }
    } catch (e) {
      print("Subnet scan error: $e");
    }
  }

  Future<void> _checkPort(String ip, int port, int generation) async {
    if (!_isDiscoveryActive || generation != _discoveryGeneration) return;
    try {
      final socket = await Socket.connect(ip, port,
          timeout: const Duration(milliseconds: 500));
      socket.destroy();
      if (!_isDiscoveryActive || generation != _discoveryGeneration) return;
      _emitDiscoveredIp(ip);
      print("Found openpilot at $ip");
    } catch (e) {
      // Connection failed or timed out
    }
  }

  void _emitDiscoveredIp(String ip) {
    final now = DateTime.now();
    if (_lastDiscoveredIp == ip &&
        _lastDiscoveredAt != null &&
        now.difference(_lastDiscoveredAt!) < const Duration(seconds: 5)) {
      return;
    }

    _lastDiscoveredIp = ip;
    _lastDiscoveredAt = now;

    if (_ipDiscoveryController != null && !_ipDiscoveryController!.isClosed) {
      _ipDiscoveryController!.add(ip);
    }
  }

  bool _isValidIpv4(String ip) {
    final parsed = InternetAddress.tryParse(ip);
    return parsed != null && parsed.type == InternetAddressType.IPv4;
  }

  void stopDiscovery() {
    final prevSource = _discoverySource;
    _discoveryGeneration += 1;
    _isDiscoveryActive = false;
    _discoverySource = 'none';
    _discoveryManualSession = false;
    _discoverySessionEndsAt = null;
    _discoveryStopTimer?.cancel();
    _discoveryStopTimer = null;
    _diag.info('discovery', 'Stop source=$prevSource');
  }

  // Git Status
  bool _hasGitUpdate = false;
  bool get hasGitUpdate => _hasGitUpdate;

  Future<void> checkGitUpdates() async {
    if (!isConnected) return;
    try {
      final script = '''
REPO="";
for d in /data/openpilot /home/comma/openpilot; do
  if [ -d "\$d/.git" ]; then
    REPO="\$d"
    break
  fi
done
if [ -z "\$REPO" ]; then
  echo OPENPILOT_REPO_NOT_FOUND
  exit 2
fi
git -C "\$REPO" fetch --all --prune >/dev/null 2>&1 || true
BRANCH="\$(git -C "\$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
LOCAL_HASH="\$(git -C "\$REPO" rev-parse HEAD 2>/dev/null || true)"
REMOTE_HASH="\$(git -C "\$REPO" rev-parse "origin/\$BRANCH" 2>/dev/null || true)"
echo "\$LOCAL_HASH|\$REMOTE_HASH"
''';
      final command = "bash -lc '${script.replaceAll("'", "'\"'\"'")}'";
      final result = await executeCommandResult(command);
      final line = result.stdout.trim().split('\n').last.trim();
      final parts = line.split('|');
      if (parts.length == 2) {
        final localHash = parts[0].trim();
        final remoteHash = parts[1].trim();
        _hasGitUpdate = localHash.isNotEmpty &&
            remoteHash.isNotEmpty &&
            localHash != remoteHash;
      } else {
        _hasGitUpdate = false;
      }
      notifyListeners();
    } catch (e) {
      print("Git update check failed: $e");
      _hasGitUpdate = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    stopDiscovery();
    _discoveryStopTimer?.cancel();
    _discoveryStopTimer = null;
    _ipDiscoveryController?.close();
    _ipDiscoveryController = null;
    super.dispose();
  }
}
