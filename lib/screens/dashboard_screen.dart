import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../services/ssh_service.dart';
import '../../services/backup_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/update_service.dart';
import '../../services/diagnostics_service.dart';
import '../../services/github_service.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/update_dialog.dart';
import 'tabs/home_tab.dart';
import 'tabs/git_tab.dart';
import 'tabs/system_tab.dart';
import 'tabs/terminal_tab.dart';
import 'tabs/logs_tab.dart';
import 'settings_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  Timer? _reconnectTimer;
  StreamSubscription<String>? _discoverySubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _connectivityDebounceTimer;
  DateTime? _lastDiscoveryTime;
  static const _discoveryCooldown = Duration(minutes: 5);
  static const _defaultSshPort = 22;
  static const _baseReconnectDelay = Duration(seconds: 2);
  static const _maxReconnectDelay = Duration(seconds: 45);
  List<ConnectivityResult>? _lastConnectivity;
  DateTime? _nextReconnectAllowedAt;
  int _reconnectFailureCount = 0;
  bool _isAutoConnectRunning = false;
  bool _setupPromptShown = false;
  String? _lastDiscoveryAttemptIp;
  DateTime? _lastDiscoveryAttemptAt;
  final DiagnosticsService _diag = DiagnosticsService.instance;

  final List<Widget> _tabs = const [
    HomeTab(),
    GitTab(),
    SystemTab(),
    TerminalTab(),
    LogsTab(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _tryAutoConnect();
    _startReconnectLoop();
    _setupDiscoveryListener();
    _setupConnectivityListener();

    // Start global backup monitoring
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ssh = Provider.of<SSHService>(context, listen: false);
      final backupService = Provider.of<BackupService>(context, listen: false);
      final driveService =
          Provider.of<GoogleDriveService>(context, listen: false);

      // Start monitoring immediately. The service handles connection checks internally.
      backupService.startMonitoring(ssh, driveService);

      _checkUpdate();
      unawaited(_showOpenpilotSetupPromptIfNeeded());
    });
  }

  Future<void> _checkUpdate() async {
    final hasUpdate =
        await context.read<UpdateService>().checkForUpdate(silent: true);
    if (hasUpdate && mounted) {
      showDialog(
        context: context,
        builder: (ctx) => UpdateDialog(),
      );
    }
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      // Request Notification Permission (Android 13+)
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }

      final service = FlutterBackgroundService();
      // Ensure service is running
      if (!await service.isRunning()) {
        service.startService();
      }

      // Refresh service notification after permission grant
      service.invoke(
          'updateContent', {'title': 'CarrotLink', 'content': '연결 대기 중...'});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _connectivityDebounceTimer?.cancel();
    _discoverySubscription?.cancel();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  void _setupConnectivityListener() {
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) async {
      // 네트워크가 없다가 생긴 경우 또는 네트워크 종류가 변경된 경우
      final hasNetwork =
          results.isNotEmpty && !results.contains(ConnectivityResult.none);
      final hadNetwork = _lastConnectivity != null &&
          _lastConnectivity!.isNotEmpty &&
          !_lastConnectivity!.contains(ConnectivityResult.none);

      debugPrint(
          '[Dashboard] Connectivity changed: $results (was: $_lastConnectivity)');
      _diag.info('connectivity', 'Changed: $results');

      // 네트워크가 새로 연결되었거나 종류가 변경됨
      if (hasNetwork &&
          (!hadNetwork ||
              !_connectivityListsEqual(_lastConnectivity, results))) {
        final ssh = Provider.of<SSHService>(context, listen: false);

        // 연결이 끊어진 상태면 즉시 재연결 시도
        if (!ssh.isConnected && !ssh.isConnecting) {
          debugPrint('[Dashboard] Network changed - attempting reconnect');

          // 네트워크 변경 이벤트 연속 발생에 대비해 debounce 후 재연결
          _connectivityDebounceTimer?.cancel();
          _connectivityDebounceTimer =
              Timer(const Duration(milliseconds: 800), () {
            unawaited(_tryAutoConnect(force: true, reason: 'connectivity'));
          });
        }
      }

      _lastConnectivity = results;
    });
  }

  void _setupDiscoveryListener() {
    final ssh = Provider.of<SSHService>(context, listen: false);
    _discoverySubscription = ssh.ipDiscoveryStream.listen((discoveredIp) async {
      if (!mounted) return;
      if (ssh.discoverySource != 'dashboard_auto') return;

      if (!await _hasOpenpilotPrerequisites()) {
        return;
      }

      final storage = const FlutterSecureStorage();
      final storedIp = await storage.read(key: 'ssh_ip');
      final portStr = await storage.read(key: 'ssh_port');
      final port = int.tryParse(portStr ?? '') ?? _defaultSshPort;

      if (storedIp != discoveredIp) {
        debugPrint(
            '[Dashboard] Discovery found candidate IP: $discoveredIp (stored: $storedIp)');
        _diag.info('discovery', 'Candidate discovered: $discoveredIp');
      }

      // 동일 IP 연속 시도 방지
      if (_lastDiscoveryAttemptIp == discoveredIp &&
          _lastDiscoveryAttemptAt != null &&
          DateTime.now().difference(_lastDiscoveryAttemptAt!) <
              const Duration(seconds: 15)) {
        return;
      }

      if (ssh.manualDisconnectRequested ||
          ssh.isConnected ||
          ssh.isConnecting) {
        return;
      }

      final username = await storage.read(key: 'ssh_username');
      final key = await storage.read(key: 'current_private_key');
      final password = await storage.read(key: 'ssh_password');
      final authUsername =
          (username == null || username.isEmpty) ? 'comma' : username;

      String? authKey = (key != null && key.isNotEmpty) ? key : null;
      String? authPassword = authKey == null ? password : null;

      _lastDiscoveryAttemptIp = discoveredIp;
      _lastDiscoveryAttemptAt = DateTime.now();

      try {
        await ssh.connect(
          discoveredIp,
          authUsername,
          port: port,
          password: authPassword,
          privateKey: authKey,
        );

        final verified = await _verifyConnectedDevice(ssh);
        if (!verified) {
          _diag.warn(
              'autoconnect', 'Rejected non-openpilot candidate: $discoveredIp');
          await ssh.disconnect();
          _markReconnectFailure();
          return;
        }

        // 성공한 IP만 저장
        await storage.write(key: 'ssh_ip', value: discoveredIp);
        _markReconnectSuccess();
        ssh.stopDiscovery();
      } catch (e) {
        _markReconnectFailure();
        debugPrint('[Dashboard] Auto-connect to discovered IP failed: $e');
        _diag.warn('autoconnect',
            'Discovery connect failed ip=$discoveredIp error=$e');
      }
    });
  }

  Future<bool> _hasOpenpilotPrerequisites() async {
    final storage = const FlutterSecureStorage();
    final token = await GitHubService().getToken();
    final privateKey = await storage.read(key: 'current_private_key');
    return token != null &&
        token.isNotEmpty &&
        privateKey != null &&
        privateKey.isNotEmpty;
  }

  Future<void> _showOpenpilotSetupPromptIfNeeded() async {
    if (!mounted || _setupPromptShown) return;

    final ready = await _hasOpenpilotPrerequisites();
    if (ready) return;
    _setupPromptShown = true;

    final goToSetup = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("연결 준비 필요"),
        content: const Text(
          "자동 연결을 사용하려면 GitHub 로그인과 SSH 키 준비가 필요합니다.\n\n지금 연결 설정으로 이동하시겠습니까?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text("나중에"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text("설정으로 이동"),
          ),
        ],
      ),
    );

    if (!mounted || goToSetup != true) return;

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ConnectionSettingsScreen()),
    );

    if (!mounted) return;
    final nowReady = await _hasOpenpilotPrerequisites();
    if (nowReady) {
      await _tryAutoConnect(force: true, reason: 'post-setup');
    } else {
      CustomToast.show(context, 'GitHub 로그인과 SSH 키 준비 후 자동 연결됩니다.');
    }
  }

  void _startDiscoveryIfNeeded({bool force = false}) {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (ssh.manualDisconnectRequested) {
      return;
    }

    final now = DateTime.now();
    if (!force &&
        _lastDiscoveryTime != null &&
        now.difference(_lastDiscoveryTime!) < _discoveryCooldown) {
      debugPrint('[Dashboard] Discovery skipped - cooldown active');
      return;
    }

    _lastDiscoveryTime = now;
    debugPrint('[Dashboard] Starting IP discovery...');
    unawaited(
      ssh.startDiscovery(
        forceRestart: force,
        timeout: const Duration(seconds: 25),
        source: 'dashboard_auto',
        manualSession: false,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App came to foreground, check connection
      final ssh = Provider.of<SSHService>(context, listen: false);
      if (!ssh.isConnected) {
        print("App resumed: Connection lost, trying to reconnect...");
        _tryAutoConnect(reason: 'resume');
      }
    }
  }

  void _startReconnectLoop() {
    _reconnectTimer?.cancel();
    // Check every 2 seconds
    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final ssh = Provider.of<SSHService>(context, listen: false);
      if (!ssh.isConnected && !ssh.isConnecting) {
        await _tryAutoConnect(silent: true, reason: 'timer');
      }
    });
  }

  void _markReconnectSuccess() {
    _reconnectFailureCount = 0;
    _nextReconnectAllowedAt = null;
  }

  void _markReconnectFailure() {
    _reconnectFailureCount += 1;
    final exponent = math.min(_reconnectFailureCount - 1, 5);
    final backoffSeconds = math.min(
      _maxReconnectDelay.inSeconds,
      _baseReconnectDelay.inSeconds * (1 << exponent),
    );
    _nextReconnectAllowedAt =
        DateTime.now().add(Duration(seconds: backoffSeconds));
  }

  Future<void> _tryAutoConnect({
    bool silent = false,
    bool force = false,
    String reason = 'periodic',
  }) async {
    if (!mounted) return;
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (ssh.manualDisconnectRequested) return;
    if (ssh.isConnected || ssh.isConnecting || _isAutoConnectRunning) return;

    final now = DateTime.now();
    if (!force &&
        _nextReconnectAllowedAt != null &&
        now.isBefore(_nextReconnectAllowedAt!)) {
      return;
    }

    _isAutoConnectRunning = true;
    try {
      if (!silent) {
        // Small delay to allow UI to settle and user to see initial state
        await Future.delayed(const Duration(milliseconds: 500));
      }

      if (ssh.manualDisconnectRequested ||
          ssh.isConnected ||
          ssh.isConnecting) {
        return;
      }

      final ready = await _hasOpenpilotPrerequisites();
      if (!ready) {
        if (!_setupPromptShown) {
          unawaited(_showOpenpilotSetupPromptIfNeeded());
        }
        if (!silent && mounted) {
          CustomToast.show(context, '먼저 GitHub 로그인과 SSH 키 준비를 완료하세요.');
        }
        return;
      }

      final storage = const FlutterSecureStorage();
      final ip = await storage.read(key: 'ssh_ip');
      final username = await storage.read(key: 'ssh_username');
      final portStr = await storage.read(key: 'ssh_port');
      final port = int.tryParse(portStr ?? '') ?? _defaultSshPort;
      final key = await storage.read(key: 'current_private_key');
      final password = await storage.read(key: 'ssh_password');
      final authUsername =
          (username == null || username.isEmpty) ? 'comma' : username;

      String? authKey = (key != null && key.isNotEmpty) ? key : null;
      String? authPassword = authKey == null ? password : null;

      debugPrint(
        '[Dashboard] Auto-connect($reason) - IP: $ip, User: $authUsername, Port: $port, Auth: ${authKey != null ? "key" : "password"}',
      );
      _diag.info('autoconnect',
          'Try reason=$reason target=$ip:$port user=$authUsername');

      if (ip != null && ip.isNotEmpty) {
        // Quick reachability check before full connect attempt
        try {
          final socket = await Socket.connect(
            ip,
            port,
            timeout: const Duration(milliseconds: 1200),
          );
          socket.destroy();
        } catch (e) {
          _markReconnectFailure();
          if (!silent) {
            debugPrint('[Dashboard] IP not reachable ($ip:$port): $e');
          }
          _startDiscoveryIfNeeded(force: force);
          return;
        }

        try {
          await ssh.connect(
            ip,
            authUsername,
            port: port,
            password: authPassword,
            privateKey: authKey,
          );

          final verified = await _verifyConnectedDevice(ssh);
          if (!verified) {
            _diag.warn(
                'autoconnect', 'Connected but not openpilot target=$ip:$port');
            await ssh.disconnect();
            _markReconnectFailure();
            _startDiscoveryIfNeeded(force: force);
            return;
          }

          _markReconnectSuccess();
          if (mounted && !silent) {
            CustomToast.show(context, '자동 연결됨: $ip');
          }
          return;
        } catch (e) {
          _markReconnectFailure();
          _diag.warn('autoconnect', 'Connect failed target=$ip:$port error=$e');
          if (!silent) {
            debugPrint('[Dashboard] Auto-connect failed: $e');
          }
          _startDiscoveryIfNeeded(force: force);
          return;
        }
      }

      // 저장된 엔드포인트가 없으면 discovery로 fallback
      _startDiscoveryIfNeeded(force: force);
    } finally {
      _isAutoConnectRunning = false;
    }
  }

  bool _connectivityListsEqual(
    List<ConnectivityResult>? a,
    List<ConnectivityResult> b,
  ) {
    if (a == null) return false;
    if (a.length != b.length) return false;
    final setA = a.toSet();
    final setB = b.toSet();
    if (setA.length != setB.length) return false;
    for (final item in setA) {
      if (!setB.contains(item)) {
        return false;
      }
    }
    return true;
  }

  Future<bool> _verifyConnectedDevice(SSHService ssh) async {
    try {
      final output = await ssh.executeCommand(
        "if [ -d /data/openpilot ] || [ -d /home/comma/openpilot ]; then echo OP_OK; fi; "
        "if [ -f /data/params/d/GithubSshKeys ] || [ -f /data/params/d/GithubUsername ]; then echo PARAM_OK; fi",
      );
      final normalized = output.trim();
      return normalized.contains('OP_OK') || normalized.contains('PARAM_OK');
    } catch (e) {
      debugPrint('[Dashboard] Device verification failed: $e');
      _diag.warn('autoconnect', 'Device verification error: $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("종료 확인"),
            content: const Text("앱을 종료하시겠습니까?"),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text("취소"),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text("종료"),
              ),
            ],
          ),
        );
        return shouldExit ?? false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('CarrotLink'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const SettingsScreen()),
                );
              },
            ),
          ],
        ),
        body: IndexedStack(
          index: _currentIndex,
          children: _tabs,
        ),
        bottomNavigationBar: Consumer<SSHService>(
          builder: (context, ssh, child) {
            return NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (idx) {
                setState(() => _currentIndex = idx);
                if (idx == 1) ssh.checkGitUpdates();
              },
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '홈',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: ssh.hasGitUpdate,
                    label: const Text("!"),
                    child: const Icon(Icons.source_outlined),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: ssh.hasGitUpdate,
                    label: const Text("!"),
                    child: const Icon(Icons.source),
                  ),
                  label: 'Git',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.settings_system_daydream_outlined),
                  selectedIcon: Icon(Icons.settings_system_daydream),
                  label: '관리',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.terminal_outlined),
                  selectedIcon: Icon(Icons.terminal),
                  label: '콘솔',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.article_outlined),
                  selectedIcon: Icon(Icons.article),
                  label: '로그',
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
