import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/ssh_service.dart';
import '../../services/backup_service.dart';
import '../../services/background_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/update_service.dart';
import '../../services/diagnostics_service.dart';
import '../../services/github_service.dart';
import '../../services/hud_feature_settings_service.dart';
import '../../services/native_overlay_hud_service.dart';
import '../../features/hud/hud.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/update_dialog.dart';
import 'tabs/home_tab.dart';
import 'tabs/git_management_tab.dart';
import 'tabs/device_settings_tab.dart';
import 'tabs/terminal_tab.dart';
import 'tabs/logs_tab.dart';
import 'settings_screen.dart';
import '../../ui/adaptive/window_class.dart';

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
  StreamSubscription<String>? _discoverySubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  List<ConnectivityResult>? _lastConnectivity;
  bool _isAutoConnectRunning = false;
  bool _setupPromptShown = false;
  bool _overlayLifecycleBusy = false;
  String? _lastDiscoveryLogIp;
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
    Provider.of<SharedRuntimeManager>(context, listen: false)
        .setAppForeground(true);
    final hudFeatureSettings =
        Provider.of<HudFeatureSettingsService>(context, listen: false);
    if (hudFeatureSettings.enabled) {
      unawaited(
        Provider.of<SharedRuntimeManager>(context, listen: false).prewarm(),
      );
    }
    unawaited(
      _syncOverlayForAppVisibility(
        appForeground: true,
        reason: 'dashboard_init',
      ),
    );
    unawaited(_bootstrapDashboardRuntime());
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

  Future<void> _bootstrapDashboardRuntime() async {
    await _ensureBackgroundServiceReady(
      foreground: true,
      source: 'dashboard_init',
    );
    if (!mounted) return;
    await _tryAutoConnect(
      silent: true,
      force: true,
      reason: 'app_start',
    );
  }

  Future<bool> _hasBackgroundRuntimePermissions() async {
    if (!Platform.isAndroid) return true;
    final notificationGranted = await Permission.notification.status;
    final batteryGranted = await Permission.ignoreBatteryOptimizations.status;
    return notificationGranted.isGranted && batteryGranted.isGranted;
  }

  Future<void> _ensureBackgroundServiceReady({
    required bool foreground,
    required String source,
  }) async {
    if (!Platform.isAndroid) return;
    final ready = await _hasBackgroundRuntimePermissions();
    if (!ready) {
      _diag.info(
        'background',
        'Skipped service start source=$source permissions_missing',
      );
      return;
    }

    await initializeService();
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    service.invoke('updateContent', {
      'title': 'CarrotLink',
      'content': '연결 대기 중...',
    });
    _setServiceAppVisibility(foreground, source: source);
  }

  @override
  void dispose() {
    _setServiceAppVisibility(false, source: 'dashboard_dispose');
    WidgetsBinding.instance.removeObserver(this);
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
        ssh.notifyNetworkChanged(source: 'dashboard_connectivity');
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
      if (_lastDiscoveryLogIp == discoveredIp) return;
      _lastDiscoveryLogIp = discoveredIp;
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

  void _startDiscoveryIfNeeded({
    bool force = false,
    bool aggressive = false,
    Duration timeout = const Duration(seconds: 45),
  }) {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (ssh.manualDisconnectRequested) {
      return;
    }
    debugPrint(
      '[Dashboard] Starting IP discovery... force=$force aggressive=$aggressive timeout=${timeout.inSeconds}s',
    );
    unawaited(
      ssh.startDiscovery(
        forceRestart: force,
        timeout: timeout,
        source: 'dashboard_auto',
        manualSession: aggressive,
      ),
    );
  }

  Future<void> _syncOverlayForAppVisibility({
    required bool appForeground,
    required String reason,
  }) async {
    if (!mounted) return;
    if (_overlayLifecycleBusy) return;
    _overlayLifecycleBusy = true;
    try {
      await NativeOverlayHudService.shutdownLegacyOverlay();
      _diag.info(
        'overlay',
        'Legacy background HUD overlay disabled. '
            'foreground=$appForeground reason=$reason',
      );
    } catch (e) {
      _diag.warn('overlay', 'Lifecycle sync failed reason=$reason error=$e');
    } finally {
      _overlayLifecycleBusy = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_ensureBackgroundServiceReady(
        foreground: true,
        source: 'lifecycle_resumed',
      ));
      Provider.of<SharedRuntimeManager>(context, listen: false)
          .setAppForeground(true);
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
        unawaited(_tryAutoConnect(reason: 'resume'));
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _setServiceAppVisibility(false, source: 'lifecycle_background');
      Provider.of<SharedRuntimeManager>(context, listen: false)
          .setAppForeground(false);
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

  List<NavigationRailDestination> _buildRailDestinations(SSHService ssh) {
    return [
      const NavigationRailDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home),
        label: Text('홈'),
      ),
      const NavigationRailDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: Text('설정'),
      ),
      NavigationRailDestination(
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
        label: const Text('메뉴'),
      ),
      const NavigationRailDestination(
        icon: Icon(Icons.terminal_outlined),
        selectedIcon: Icon(Icons.terminal),
        label: Text('콘솔'),
      ),
      const NavigationRailDestination(
        icon: Icon(Icons.article_outlined),
        selectedIcon: Icon(Icons.article),
        label: Text('로그'),
      ),
    ];
  }

  List<NavigationDestination> _buildBottomDestinations(SSHService ssh) {
    return [
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
    ];
  }

  Future<void> _persistLastTabIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastDashboardTabIndexKey, index);
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

    _isAutoConnectRunning = true;
    try {
      if (!silent && reason != 'app_start') {
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
      unawaited(ssh.tryFastReconnect(source: 'dashboard_$reason'));
      _diag.info(
        'autoconnect',
        'Fast reconnect kicked reason=$reason '
            'candidate=${ssh.serviceCandidateIp} last=${ssh.serviceLastSuccessfulIp}',
      );
      _diag.info('autoconnect',
          'Broadcast sync reason=$reason candidate=${ssh.serviceCandidateIp}');
      final fastStart = reason == 'app_start';
      final aggressive = fastStart ||
          reason == 'connectivity' ||
          reason == 'resume' ||
          reason == 'network_reconnected' ||
          force;
      _startDiscoveryIfNeeded(
        force: force || aggressive,
        aggressive: aggressive,
        timeout: aggressive
            ? const Duration(seconds: 60)
            : const Duration(seconds: 45),
      );
    } catch (e) {
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

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final viewport = MediaQuery.sizeOf(context);
    final forceRailForWideLandscape =
        window.isLandscape && viewport.width >= 700 && viewport.height >= 360;
    final useRail = forceRailForWideLandscape ||
        (window.isExpandedOrAbove && viewport.height >= 560);

    return Scaffold(
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
      body: useRail
          ? Consumer<SSHService>(
              builder: (context, ssh, child) {
                return Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _currentIndex,
                      useIndicator: true,
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: (idx) {
                        _dismissKeyboard();
                        setState(() => _currentIndex = idx);
                        unawaited(_persistLastTabIndex(idx));
                      },
                      destinations: _buildRailDestinations(ssh),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: IndexedStack(
                        index: _currentIndex,
                        children: _buildTabs(),
                      ),
                    ),
                  ],
                );
              },
            )
          : IndexedStack(
              index: _currentIndex,
              children: _buildTabs(),
            ),
      bottomNavigationBar: useRail
          ? null
          : Consumer<SSHService>(
              builder: (context, ssh, child) {
                return NavigationBar(
                  selectedIndex: _currentIndex,
                  onDestinationSelected: (idx) {
                    _dismissKeyboard();
                    setState(() => _currentIndex = idx);
                    unawaited(_persistLastTabIndex(idx));
                  },
                  destinations: _buildBottomDestinations(ssh),
                );
              },
            ),
    );
  }
}
