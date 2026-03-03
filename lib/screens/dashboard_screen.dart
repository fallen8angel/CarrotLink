import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/ssh_service.dart';
import '../../services/backup_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/update_service.dart';
import '../../services/diagnostics_service.dart';
import '../../services/github_service.dart';
import '../../services/native_overlay_hud_service.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/update_dialog.dart';
import 'tabs/home_tab.dart';
import 'tabs/git_management_tab.dart';
import 'tabs/device_settings_tab.dart';
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
  static const String _lastDashboardTabIndexKey = 'dashboard_last_tab_index';
  static const int _tabCount = 5;
  int _currentIndex = 0;
  Timer? _reconnectTimer;
  StreamSubscription<String>? _discoverySubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _connectivityDebounceTimer;
  static const _baseReconnectDelay = Duration(seconds: 2);
  static const _maxReconnectDelay = Duration(seconds: 45);
  List<ConnectivityResult>? _lastConnectivity;
  DateTime? _nextReconnectAllowedAt;
  int _reconnectFailureCount = 0;
  bool _isAutoConnectRunning = false;
  bool _setupPromptShown = false;
  bool _overlayLifecycleBusy = false;
  String? _lastDiscoveryLogIp;
  DateTime? _lastDiscoveryLogAt;
  final DiagnosticsService _diag = DiagnosticsService.instance;
  final GlobalKey<TerminalTabState> _terminalTabKey =
      GlobalKey<TerminalTabState>();

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _setServiceAppVisibility(bool foreground,
      {String source = 'dashboard'}) {
    FlutterBackgroundService().invoke('setAppVisibility', {
      'foreground': foreground,
      'source': source,
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreLastTabIndex());
    _requestPermissions();
    _setServiceAppVisibility(true, source: 'dashboard_init');
    unawaited(
      _syncOverlayForAppVisibility(
        appForeground: true,
        reason: 'dashboard_init',
      ),
    );
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
      backupService.requestEventSync(
        reason: 'dashboard_start',
        debounce: const Duration(seconds: 2),
      );

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
        builder: (ctx) => const UpdateDialog(),
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
    _setServiceAppVisibility(false, source: 'dashboard_dispose');
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
        final backupService =
            Provider.of<BackupService>(context, listen: false);
        backupService.requestEventSync(
          reason: 'network_reconnected',
          debounce: const Duration(seconds: 6),
        );
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
    _discoverySubscription = ssh.ipDiscoveryStream.listen((discoveredIp) {
      if (!mounted) return;
      if (ssh.discoverySource == 'settings_manual' ||
          ssh.discoverySource == 'settings_auto') {
        return;
      }
      final now = DateTime.now();
      final shouldLog = _lastDiscoveryLogIp != discoveredIp ||
          _lastDiscoveryLogAt == null ||
          now.difference(_lastDiscoveryLogAt!) >= const Duration(seconds: 3);
      if (!shouldLog) return;
      _lastDiscoveryLogIp = discoveredIp;
      _lastDiscoveryLogAt = now;
      _diag.info('discovery', 'Candidate discovered: $discoveredIp');
      debugPrint('[Dashboard] Discovery candidate: $discoveredIp');
    });
  }

  Future<bool> _hasOpenpilotPrerequisites() async {
    const storage = FlutterSecureStorage();
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
    debugPrint('[Dashboard] Starting IP discovery...');
    unawaited(
      ssh.startDiscovery(
        forceRestart: force,
        timeout: const Duration(seconds: 45),
        source: 'dashboard_auto',
        manualSession: false,
      ),
    );
  }

  Future<void> _syncOverlayForAppVisibility({
    required bool appForeground,
    required String reason,
  }) async {
    if (!mounted) return;
    if (!NativeOverlayHudService.isSupported) return;
    if (_overlayLifecycleBusy) return;
    _overlayLifecycleBusy = true;
    try {
      final overlayEnabled = await NativeOverlayHudService.isEnabled();
      if (!overlayEnabled) {
        final running = await NativeOverlayHudService.isRunning();
        if (running) {
          await NativeOverlayHudService.stop();
        }
        _diag.info('overlay', 'Disabled by settings. reason=$reason');
        return;
      }

      if (appForeground) {
        final running = await NativeOverlayHudService.isRunning();
        if (running) {
          await NativeOverlayHudService.stop();
        }
        return;
      }

      final hasPermission = await NativeOverlayHudService.hasPermission();
      if (!hasPermission) return;

      final ssh = Provider.of<SSHService>(context, listen: false);
      final host = NativeOverlayHudService.normalizeHost(
        ssh.connectedIp ?? ssh.targetIp,
      );
      if (host == null) return;

      final running = await NativeOverlayHudService.isRunning();
      if (running) {
        await NativeOverlayHudService.updateEndpoint(host);
      } else {
        await NativeOverlayHudService.start(host);
      }
      _diag.info('overlay',
          'Lifecycle sync: foreground=$appForeground reason=$reason host=$host');
    } catch (e) {
      _diag.warn('overlay', 'Lifecycle sync failed reason=$reason error=$e');
    } finally {
      _overlayLifecycleBusy = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setServiceAppVisibility(true, source: 'lifecycle_resumed');
      unawaited(
        _syncOverlayForAppVisibility(
          appForeground: true,
          reason: 'lifecycle_resumed',
        ),
      );
      _dismissKeyboard();
      // App came to foreground, check connection
      final ssh = Provider.of<SSHService>(context, listen: false);
      final backupService = Provider.of<BackupService>(context, listen: false);
      backupService.requestEventSync(
        reason: 'app_resume',
        debounce: const Duration(seconds: 2),
      );
      if (!ssh.isConnected) {
        print("App resumed: Connection lost, trying to reconnect...");
        _tryAutoConnect(reason: 'resume');
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _setServiceAppVisibility(false, source: 'lifecycle_background');
      unawaited(
        _syncOverlayForAppVisibility(
          appForeground: false,
          reason: 'lifecycle_background',
        ),
      );
      unawaited(_persistLastTabIndex(_currentIndex));
    }
  }

  Future<void> _restoreLastTabIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_lastDashboardTabIndexKey);
    if (saved == null || saved < 0) return;
    // Old layout migration:
    // [홈, 설정, Git, 관리, 콘솔, 로그] -> [홈, 설정, Git관리, 콘솔, 로그]
    var restored = saved;
    if (saved == 3) {
      restored = 2;
    } else if (saved == 4) {
      restored = 3;
    } else if (saved == 5) {
      restored = 4;
    }
    if (restored >= _tabCount) return;
    if (!mounted) return;
    setState(() => _currentIndex = restored);
  }

  List<Widget> _buildTabs() {
    return [
      HomeTab(isActive: _currentIndex == 0),
      const DeviceSettingsTab(),
      const GitManagementTab(),
      TerminalTab(key: _terminalTabKey),
      const LogsTab(),
    ];
  }

  Future<void> _persistLastTabIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastDashboardTabIndexKey, index);
  }

  void _startReconnectLoop() {
    _reconnectTimer?.cancel();
    // Discovery/auto reconnect sync loop (broadcast-first).
    _reconnectTimer =
        Timer.periodic(const Duration(seconds: 10), (timer) async {
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

      // Broadcast-first: do not use persisted IP.
      ssh.resumeAutoReconnect();
      _diag.info('autoconnect',
          'Broadcast sync reason=$reason candidate=${ssh.serviceCandidateIp}');
      _startDiscoveryIfNeeded(force: force);
      _markReconnectSuccess();
    } catch (e) {
      _markReconnectFailure();
      _diag.warn(
          'autoconnect', 'Broadcast sync failed reason=$reason error=$e');
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

  Future<bool> _handleNestedBackStack() async {
    // UX 단순화를 위해 안드로이드 시스템 뒤로가기는
    // 내부 파일탭 탐색 히스토리를 소비하지 않고 앱 종료 확인으로 처리한다.
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (await _handleNestedBackStack()) {
          return false;
        }
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
                _dismissKeyboard();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const SettingsScreen()),
                );
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: _buildTabs(),
              ),
            ),
          ],
        ),
        bottomNavigationBar: Consumer<SSHService>(
          builder: (context, ssh, child) {
            return NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (idx) {
                _dismissKeyboard();
                setState(() => _currentIndex = idx);
                unawaited(_persistLastTabIndex(idx));
              },
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '홈',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '설정',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: ssh.hasGitUpdate,
                    label: const Text("!"),
                    child: const Icon(Icons.tune_outlined),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: ssh.hasGitUpdate,
                    label: const Text("!"),
                    child: const Icon(Icons.tune),
                  ),
                  label: '메뉴',
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
