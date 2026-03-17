import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
import '../../services/github_service.dart';
import '../../services/hud_feature_settings_service.dart';
import '../../services/native_overlay_hud_service.dart';
import '../../widgets/custom_toast.dart';
import '../../features/hud/hud.dart';
import '../drive/live_drive_canvas_screen.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';

enum _HomeConnectionPhase {
  searching,
  connecting,
  connected,
  settling,
  disconnected,
  failure,
}

class HomeTab extends StatefulWidget {
  final bool isActive;

  const HomeTab({super.key, required this.isActive});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with WidgetsBindingObserver {
  static const String _defaultSshUsername = 'comma';
  static const int _defaultSshPort = 22;

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  String _branch = "--";
  String _commit = "--";
  String _dongleId = "--";
  String _serial = "--";
  String? _metadataHost;
  String? _lastObservedConnectedHost;
  String? _lastObservedServiceHost;
  String? _lastObservedMetadataSignature;
  bool _lastObservedIsConnected = false;
  bool _statusRefreshQueued = false;
  bool _hasGitHubLogin = false;
  bool _hasActiveSshKey = false;
  bool _overlayRunning = false;
  bool _manualIpDialogOpen = false;
  String? _overlaySyncedHost;
  DateTime? _overlayLastProbeAt;
  DateTime? _homeDiscoveryUiHoldUntil;
  DateTime? _homeConnectionUiHoldUntil;
  bool _appForeground = true;
  Timer? _prereqTimer;
  Timer? _overlaySyncTimer;
  Timer? _homeDiscoveryUiHoldTimer;
  Timer? _homeConnectionUiHoldTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyRealtimeWorkState(forceRefresh: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ssh = Provider.of<SSHService>(context);
    unawaited(_refreshConnectionPrerequisites());
    _applyConnectionMetadata(ssh, ssh.cachedConnectionMetadata);
    if (ssh.isConnected && _shouldRefreshConnectionMetadata(ssh)) {
      unawaited(_refreshStatus());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _prereqTimer?.cancel();
    _overlaySyncTimer?.cancel();
    _homeDiscoveryUiHoldTimer?.cancel();
    _homeConnectionUiHoldTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HomeTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _applyRealtimeWorkState(forceRefresh: widget.isActive);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nextForeground = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (_appForeground == nextForeground) return;
    _appForeground = nextForeground;
    _applyRealtimeWorkState(forceRefresh: nextForeground && widget.isActive);
  }

  bool get _realtimeWorkEnabled => widget.isActive && _appForeground;
  bool get _hudKeepAliveEnabled => _appForeground;

  void _applyRealtimeWorkState({bool forceRefresh = false}) {
    if (_realtimeWorkEnabled) {
      _prereqTimer ??= Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_refreshConnectionPrerequisites()),
      );
      if (NativeOverlayHudService.isSupported) {
        _overlaySyncTimer ??= Timer.periodic(
          const Duration(seconds: 5),
          (_) => unawaited(_syncOverlayEndpoint()),
        );
      }
      if (forceRefresh) {
        unawaited(_refreshConnectionPrerequisites());
        unawaited(_refreshStatus());
        unawaited(_syncOverlayEndpoint(forceProbe: true));
      }
      return;
    }

    _prereqTimer?.cancel();
    _prereqTimer = null;
    _overlaySyncTimer?.cancel();
    _overlaySyncTimer = null;
  }

  String _normalizeMetadataValue(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? "--" : trimmed;
  }

  String _currentMetadataHost(SSHService ssh) {
    return (ssh.connectedIp ?? ssh.serviceConnectedIp ?? '').trim();
  }

  void _applyConnectionMetadata(
    SSHService ssh,
    DeviceMetadataSnapshot? snapshot,
  ) {
    if (snapshot == null) return;
    final connectedHost = _currentMetadataHost(ssh);
    final snapshotHost = (snapshot.ip ?? '').trim();
    if (connectedHost.isNotEmpty &&
        snapshotHost.isNotEmpty &&
        snapshotHost != connectedHost) {
      return;
    }

    final nextBranch = _normalizeMetadataValue(snapshot.branch);
    final nextCommit = _normalizeMetadataValue(snapshot.commit);
    final nextDongleId = _normalizeMetadataValue(snapshot.dongleId);
    final nextSerial = _normalizeMetadataValue(snapshot.serial);
    final nextHost = snapshotHost.isEmpty ? _metadataHost : snapshotHost;

    if (_branch == nextBranch &&
        _commit == nextCommit &&
        _dongleId == nextDongleId &&
        _serial == nextSerial &&
        _metadataHost == nextHost) {
      return;
    }

    if (!mounted) {
      _branch = nextBranch;
      _commit = nextCommit;
      _dongleId = nextDongleId;
      _serial = nextSerial;
      _metadataHost = nextHost;
      return;
    }

    setState(() {
      _branch = nextBranch;
      _commit = nextCommit;
      _dongleId = nextDongleId;
      _serial = nextSerial;
      _metadataHost = nextHost;
    });
  }

  bool _shouldRefreshConnectionMetadata(SSHService ssh) {
    final connectedHost = _currentMetadataHost(ssh);
    if (connectedHost.isEmpty) return false;
    if (_metadataHost != connectedHost) return true;
    return _branch == "--" ||
        _commit == "--" ||
        _dongleId == "--" ||
        _serial == "--";
  }

  String? _metadataSignature(DeviceMetadataSnapshot? snapshot) {
    if (snapshot == null) return null;
    return [
      snapshot.ip ?? '',
      snapshot.branch,
      snapshot.commit,
      snapshot.dongleId,
      snapshot.serial,
      snapshot.fetchedAt.toIso8601String(),
    ].join('|');
  }

  void _queueImmediateStatusRefresh(SSHService ssh) {
    if (!_realtimeWorkEnabled || _statusRefreshQueued || !mounted) return;
    _statusRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _statusRefreshQueued = false;
      if (!mounted || !_realtimeWorkEnabled) return;
      _applyConnectionMetadata(ssh, ssh.cachedConnectionMetadata);
      if (_shouldRefreshConnectionMetadata(ssh)) {
        unawaited(_refreshStatus());
      }
    });
  }

  void _handleObservedSshState(SSHService ssh) {
    if (!ssh.isConnected && !ssh.isConnecting && ssh.isDiscoveryActive) {
      _holdHomeDiscoveryUi(const Duration(seconds: 3));
    } else if (ssh.isConnected || ssh.isConnecting) {
      _clearHomeDiscoveryUiHold();
    }

    final connectedHost = (ssh.connectedIp ?? '').trim();
    final serviceHost = (ssh.serviceConnectedIp ?? '').trim();
    final hasActiveConnectionSignal = ssh.isConnected ||
        ssh.isConnecting ||
        connectedHost.isNotEmpty ||
        serviceHost.isNotEmpty ||
        ssh.connectionStatus.startsWith("Connecting") ||
        ssh.connectionStatus.contains("세션 복구");
    if (hasActiveConnectionSignal) {
      _holdHomeConnectionUi(const Duration(seconds: 4));
    } else if (ssh.manualDisconnectRequested) {
      _clearHomeConnectionUiHold();
    }
    final metadataSignature = _metadataSignature(ssh.cachedConnectionMetadata);
    final changed = _lastObservedIsConnected != ssh.isConnected ||
        _lastObservedConnectedHost != connectedHost ||
        _lastObservedServiceHost != serviceHost ||
        _lastObservedMetadataSignature != metadataSignature;
    if (!changed) return;

    _lastObservedIsConnected = ssh.isConnected;
    _lastObservedConnectedHost = connectedHost;
    _lastObservedServiceHost = serviceHost;
    _lastObservedMetadataSignature = metadataSignature;

    if (connectedHost.isNotEmpty ||
        serviceHost.isNotEmpty ||
        ssh.cachedConnectionMetadata != null) {
      _queueImmediateStatusRefresh(ssh);
    }
  }

  void _holdHomeDiscoveryUi(Duration duration) {
    final nextUntil = DateTime.now().add(duration);
    if (_homeDiscoveryUiHoldUntil != null &&
        _homeDiscoveryUiHoldUntil!.isAfter(nextUntil)) {
      return;
    }
    _homeDiscoveryUiHoldUntil = nextUntil;
    _homeDiscoveryUiHoldTimer?.cancel();
    _homeDiscoveryUiHoldTimer = Timer(duration, () {
      if (!mounted) return;
      if (_homeDiscoveryUiHoldUntil != null &&
          DateTime.now().isAfter(_homeDiscoveryUiHoldUntil!)) {
        setState(() {
          _homeDiscoveryUiHoldUntil = null;
        });
      }
    });
  }

  void _clearHomeDiscoveryUiHold() {
    if (_homeDiscoveryUiHoldUntil == null) return;
    _homeDiscoveryUiHoldTimer?.cancel();
    _homeDiscoveryUiHoldTimer = null;
    _homeDiscoveryUiHoldUntil = null;
  }

  void _holdHomeConnectionUi(Duration duration) {
    final nextUntil = DateTime.now().add(duration);
    if (_homeConnectionUiHoldUntil != null &&
        _homeConnectionUiHoldUntil!.isAfter(nextUntil)) {
      return;
    }
    _homeConnectionUiHoldUntil = nextUntil;
    _homeConnectionUiHoldTimer?.cancel();
    _homeConnectionUiHoldTimer = Timer(duration, () {
      if (!mounted) return;
      if (_homeConnectionUiHoldUntil != null &&
          DateTime.now().isAfter(_homeConnectionUiHoldUntil!)) {
        setState(() {
          _homeConnectionUiHoldUntil = null;
        });
      }
    });
  }

  void _clearHomeConnectionUiHold() {
    if (_homeConnectionUiHoldUntil == null) return;
    _homeConnectionUiHoldTimer?.cancel();
    _homeConnectionUiHoldTimer = null;
    _homeConnectionUiHoldUntil = null;
  }

  bool _showHomeDiscoverySearching(SSHService ssh) {
    if (ssh.isConnected || ssh.isConnecting) return false;
    if (ssh.isDiscoveryActive) return true;
    final holdUntil = _homeDiscoveryUiHoldUntil;
    return holdUntil != null && DateTime.now().isBefore(holdUntil);
  }

  bool _showHomeConnectionSettling(SSHService ssh) {
    if (ssh.manualDisconnectRequested || _showHomeDiscoverySearching(ssh)) {
      return false;
    }
    if (ssh.isConnected || ssh.isConnecting) return false;
    if ((ssh.serviceConnectedIp ?? '').trim().isNotEmpty) {
      return true;
    }
    final holdUntil = _homeConnectionUiHoldUntil;
    return holdUntil != null && DateTime.now().isBefore(holdUntil);
  }

  Future<void> _refreshStatus() async {
    if (!_realtimeWorkEnabled) return;
    unawaited(_refreshConnectionPrerequisites());

    final ssh = Provider.of<SSHService>(context, listen: false);
    _applyConnectionMetadata(ssh, ssh.cachedConnectionMetadata);
    if (ssh.isConnected) {
      try {
        final snapshot = await ssh.getConnectionMetadata(
          forceRefresh: _shouldRefreshConnectionMetadata(ssh),
        );
        _applyConnectionMetadata(ssh, snapshot);
        await _syncOverlayEndpoint();
      } catch (e) {
        debugPrint("Status refresh failed: $e");
      }
    }
  }

  Future<void> _refreshConnectionPrerequisites() async {
    if (!_realtimeWorkEnabled) return;
    try {
      final token = await GitHubService().getToken();
      final privateKey =
          await const FlutterSecureStorage().read(key: 'current_private_key');
      final nextHasGitHubLogin = token != null && token.isNotEmpty;
      final nextHasActiveSshKey = privateKey != null && privateKey.isNotEmpty;
      if (!mounted) return;
      if (_hasGitHubLogin == nextHasGitHubLogin &&
          _hasActiveSshKey == nextHasActiveSshKey) {
        return;
      }
      setState(() {
        _hasGitHubLogin = nextHasGitHubLogin;
        _hasActiveSshKey = nextHasActiveSshKey;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasGitHubLogin = false;
        _hasActiveSshKey = false;
      });
    }
  }

  bool _isFailureStatus(SSHService ssh) {
    final status = ssh.connectionStatus.trim();
    if (status.isEmpty ||
        status == "Connected" ||
        status == "Disconnected" ||
        status.startsWith("Connecting") ||
        status.contains("세션 복구") ||
        status.contains("세션 확인")) {
      return false;
    }
    return status.contains("실패") ||
        status.contains("오류") ||
        status.contains("시간 초과") ||
        status.contains("인증") ||
        status.contains("키");
  }

  _HomeConnectionPhase _homeConnectionPhase(SSHService ssh) {
    if (ssh.manualDisconnectRequested) {
      return _HomeConnectionPhase.disconnected;
    }
    if (ssh.isLikelySessionLost || _showHomeConnectionSettling(ssh)) {
      return _HomeConnectionPhase.settling;
    }
    if (ssh.isConnected) {
      return _HomeConnectionPhase.connected;
    }
    if (ssh.isConnecting || ssh.connectionStatus.startsWith("Connecting")) {
      return _HomeConnectionPhase.connecting;
    }
    if (_isFailureStatus(ssh)) {
      return _HomeConnectionPhase.failure;
    }
    return _HomeConnectionPhase.searching;
  }

  bool _showConnectedHomeState(SSHService ssh) {
    return _homeConnectionPhase(ssh) == _HomeConnectionPhase.connected;
  }

  String _statusHeadline(SSHService ssh) {
    if (!_hasGitHubLogin) return "GitHub 연동 필요";
    if (!_hasActiveSshKey) return "SSH 개인키 적용 필요";
    return _showConnectedHomeState(ssh) ? "연결됨" : "연결 안 됨";
  }

  String _detailPlaceholderForPhase(_HomeConnectionPhase phase) {
    return phase == _HomeConnectionPhase.connected ? "연결 안 됨" : "연결 안 됨";
  }

  bool _showConnectedDetails(_HomeConnectionPhase phase) {
    return phase == _HomeConnectionPhase.connected;
  }

  String _ipFieldText(SSHService ssh, _HomeConnectionPhase phase) {
    if (!_hasGitHubLogin || !_hasActiveSshKey) {
      return "연동 필요";
    }
    if (phase == _HomeConnectionPhase.connected) {
      return (ssh.connectedIp ?? ssh.serviceConnectedIp ?? "Unknown").trim();
    }
    return "연결 안 됨";
  }

  bool _disconnectActionEnabled(SSHService ssh) {
    if (!_hasGitHubLogin || !_hasActiveSshKey) return false;
    if (ssh.manualDisconnectRequested) return false;
    return ssh.isConnected ||
        ssh.isConnecting ||
        ssh.isLikelySessionLost ||
        _showHomeConnectionSettling(ssh) ||
        _showHomeDiscoverySearching(ssh);
  }

  Color _statusColor(BuildContext context, SSHService ssh) {
    if (!_hasGitHubLogin || !_hasActiveSshKey) return Colors.grey;
    return _showConnectedHomeState(ssh)
        ? Theme.of(context).colorScheme.primary
        : Colors.grey;
  }

  String? _currentDeviceHost(SSHService ssh) {
    return NativeOverlayHudService.normalizeHost(
      ssh.connectedIp ?? ssh.serviceConnectedIp,
    );
  }

  Future<void> _syncOverlayEndpoint({bool forceProbe = false}) async {
    if (!_realtimeWorkEnabled && !forceProbe) return;
    if (!mounted) return;
    final ssh = Provider.of<SSHService>(context, listen: false);
    final host = _currentDeviceHost(ssh);

    if (_overlayRunning && host != null && host != _overlaySyncedHost) {
      await NativeOverlayHudService.updateEndpoint(host);
      _overlaySyncedHost = host;
    }

    final now = DateTime.now();
    final shouldProbe = forceProbe ||
        _overlayLastProbeAt == null ||
        now.difference(_overlayLastProbeAt!) >= const Duration(seconds: 5);
    if (!shouldProbe) return;

    _overlayLastProbeAt = now;
    final running = await NativeOverlayHudService.isRunning();
    if (!mounted) return;
    if (running != _overlayRunning) {
      setState(() => _overlayRunning = running);
    }
    if (running && host != null && host != _overlaySyncedHost) {
      await NativeOverlayHudService.updateEndpoint(host);
      _overlaySyncedHost = host;
    }
  }

  Future<void> _openDriveView(SSHService ssh) async {
    final featureSettings =
        Provider.of<HudFeatureSettingsService>(context, listen: false);
    if (!featureSettings.enabled) {
      CustomToast.show(context, 'HUD/Stock 기능이 비활성화되어 있습니다.', isError: true);
      return;
    }
    final host = (ssh.connectedIp ?? '').trim();
    if (host.isEmpty) {
      CustomToast.show(context, 'SSH 연결이 완료된 뒤 열 수 있습니다.', isError: true);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveDriveCanvasScreen(hostIp: host),
      ),
    );
  }

  bool _hasFreshDiscoveryCandidate(SSHService ssh) {
    final candidate = (ssh.serviceCandidateIp ?? '').trim();
    final seenAt = ssh.serviceCandidateSeenAt;
    if (candidate.isEmpty || seenAt == null) return false;
    return DateTime.now().difference(seenAt) <= const Duration(minutes: 2);
  }

  String? _preferredHomeIp(SSHService ssh) {
    final connected = (ssh.connectedIp ?? '').trim();
    if (connected.isNotEmpty) return connected;
    final serviceConnected = (ssh.serviceConnectedIp ?? '').trim();
    if (serviceConnected.isNotEmpty) return serviceConnected;
    final target = (ssh.targetIp ?? '').trim();
    if (target.isNotEmpty) return target;
    if (_hasFreshDiscoveryCandidate(ssh)) {
      return ssh.serviceCandidateIp!.trim();
    }
    return null;
  }

  Future<void> _runHomeGuidedDiscovery(SSHService ssh) async {
    if (!_hasActiveSshKey) {
      CustomToast.show(context, 'SSH 개인키를 먼저 준비하세요.', isError: true);
      return;
    }
    if (ssh.isConnected) {
      CustomToast.show(context, '이미 연결되어 있습니다.');
      return;
    }
    _holdHomeDiscoveryUi(const Duration(seconds: 65));
    ssh.resumeAutoReconnect();
    final started = await ssh.startDiscovery(
      forceRestart: true,
      timeout: const Duration(seconds: 60),
      source: 'home_manual',
      manualSession: true,
    );
    if (!mounted) return;
    if (!started) {
      CustomToast.show(context, '이미 검색 중입니다.');
      return;
    }
    CustomToast.show(context, 'IP 자동 검색을 시작합니다.');
  }

  Future<void> _connectManualIp(SSHService ssh, String rawIp) async {
    if (ssh.isConnecting) {
      CustomToast.show(context, '이미 연결 시도 중입니다.');
      return;
    }
    if (ssh.isConnected) {
      CustomToast.show(context, '이미 연결되어 있습니다.');
      return;
    }

    final ip = rawIp.trim();
    if (ip.isEmpty) {
      CustomToast.show(context, 'IP 주소를 입력하세요.', isError: true);
      return;
    }
    final parsedIp = InternetAddress.tryParse(ip);
    if (parsedIp == null || parsedIp.type != InternetAddressType.IPv4) {
      CustomToast.show(context, '올바른 IPv4 주소를 입력하세요.', isError: true);
      return;
    }

    final privateKey = await _storage.read(key: 'current_private_key');
    if (privateKey == null || privateKey.trim().isEmpty) {
      if (!mounted) return;
      CustomToast.show(context, 'SSH 개인키를 먼저 준비하세요.', isError: true);
      return;
    }

    final username =
        (await _storage.read(key: 'ssh_username'))?.trim().isNotEmpty == true
            ? (await _storage.read(key: 'ssh_username'))!.trim()
            : _defaultSshUsername;
    final port =
        int.tryParse((await _storage.read(key: 'ssh_port'))?.trim() ?? '') ??
            _defaultSshPort;

    try {
      _clearHomeDiscoveryUiHold();
      ssh.resumeAutoReconnect();
      await ssh.connect(
        ip,
        username,
        port: port,
        password: null,
        privateKey: privateKey.trim(),
      );
      if (!mounted) return;
      CustomToast.show(context, '연결 성공');
      unawaited(_refreshStatus());
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '연결 실패: $e', isError: true);
    }
  }

  Future<void> _openManualIpDialog(SSHService ssh) async {
    if (_manualIpDialogOpen || !mounted) return;
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final controller = TextEditingController(text: _preferredHomeIp(ssh) ?? '');
    _manualIpDialogOpen = true;
    try {
      final result = await showDialog<String>(
        context: rootNavigator.context,
        useRootNavigator: true,
        builder: (dialogContext) => AlertDialog(
          title: const Text('수동 IP 연결'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'IPv4 주소',
              hintText: '예: 172.30.1.90',
            ),
            onSubmitted: (value) =>
                Navigator.of(dialogContext).pop(value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('연결'),
            ),
          ],
        ),
      );
      if (!mounted || result == null || result.trim().isEmpty) return;
      await _connectManualIp(ssh, result);
    } finally {
      controller.dispose();
      _manualIpDialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = UiLayoutTokens.of(context);
    final window = UiWindowInfo.of(context);
    return Consumer2<SSHService, HudFeatureSettingsService>(
      builder: (context, ssh, featureSettings, child) {
        _handleObservedSshState(ssh);
        final hudFeatureEnabled = featureSettings.enabled;
        final media = MediaQuery.of(context);
        final compactStatusStack =
            !window.isLandscape || window.windowClass == UiWindowClass.compact;
        final statusFontSize = switch (window.windowClass) {
          UiWindowClass.compact => 20.0,
          UiWindowClass.medium => 24.0,
          UiWindowClass.expanded => 25.0,
          UiWindowClass.large => 26.0,
          UiWindowClass.extraLarge => 27.0,
        };
        final ipFontSize = switch (window.windowClass) {
          UiWindowClass.compact => 14.0,
          UiWindowClass.medium => 17.0,
          UiWindowClass.expanded => 18.0,
          UiWindowClass.large => 19.0,
          UiWindowClass.extraLarge => 20.0,
        };
        final blockGap = switch (window.windowClass) {
          UiWindowClass.compact => 8.0,
          UiWindowClass.medium => 9.0,
          UiWindowClass.expanded => 10.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 11.0,
        };
        final compactActionSize = switch (window.windowClass) {
          UiWindowClass.compact => 34.0,
          UiWindowClass.medium => 36.0,
          UiWindowClass.expanded => 38.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 40.0,
        };
        final phase = _homeConnectionPhase(ssh);
        final statusHeadline = _statusHeadline(ssh);
        final statusColor = _statusColor(context, ssh);
        final ipFieldText = _ipFieldText(ssh, phase);
        final canDisconnect = _disconnectActionEnabled(ssh);
        final showDetails = _showConnectedDetails(phase);
        final detailPlaceholder = _detailPlaceholderForPhase(phase);
        final isLandscape = window.isLandscape;
        final homeContentMaxWidth = switch (window.windowClass) {
          UiWindowClass.compact => double.infinity,
          UiWindowClass.medium => isLandscape ? 640.0 : 600.0,
          UiWindowClass.expanded => isLandscape ? 760.0 : 680.0,
          UiWindowClass.large => isLandscape ? 840.0 : 740.0,
          UiWindowClass.extraLarge => isLandscape ? 920.0 : 800.0,
        };
        final clampedHomeContentMaxWidth = homeContentMaxWidth.isFinite
            ? math.min(homeContentMaxWidth, media.size.width - 24.0)
            : homeContentMaxWidth;
        final estimatedHeaderHeight = switch (window.windowClass) {
          UiWindowClass.compact => 242.0,
          UiWindowClass.medium => 256.0,
          UiWindowClass.expanded => 272.0,
          UiWindowClass.large => 286.0,
          UiWindowClass.extraLarge => 300.0,
        };
        final bottomDockGap = math.max(
          16.0,
          math.max(media.padding.bottom, media.viewPadding.bottom) + 12.0,
        );
        final estimatedVerticalChrome =
            (tokens.screenPadding * 2) + tokens.sectionGap + 34.0;
        final viewportAwareHudCap = math
            .max(
              220.0,
              media.size.height -
                  estimatedHeaderHeight -
                  estimatedVerticalChrome -
                  bottomDockGap,
            )
            .clamp(220.0, 520.0)
            .toDouble();
        final homeHudHeightCap = switch (window.windowClass) {
          UiWindowClass.compact => viewportAwareHudCap.clamp(220.0, 360.0),
          UiWindowClass.medium => viewportAwareHudCap.clamp(240.0, 390.0),
          UiWindowClass.expanded => viewportAwareHudCap.clamp(260.0, 420.0),
          UiWindowClass.large => viewportAwareHudCap.clamp(280.0, 450.0),
          UiWindowClass.extraLarge => viewportAwareHudCap.clamp(300.0, 480.0),
        }
            .toDouble();
        final homePreviewProfile = HudLayoutProfile.fromConstraints(
          BoxConstraints(
            maxWidth: clampedHomeContentMaxWidth.isFinite
                ? clampedHomeContentMaxWidth
                : media.size.width - (tokens.screenPadding * 2),
            maxHeight: homeHudHeightCap,
          ),
          surface: HudSurfaceVariant.homePreview,
        );
        final hudPreviewMaxWidth = () {
          final capByHeight =
              homeHudHeightCap * homePreviewProfile.preferredAspectRatio;
          return math.min(clampedHomeContentMaxWidth, capByHeight);
        }();
        final cardPadding = switch (window.windowClass) {
          UiWindowClass.compact => 14.0,
          UiWindowClass.medium => 16.0,
          UiWindowClass.expanded => 18.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 20.0,
        };
        final ipChipLabelSize = switch (window.windowClass) {
          UiWindowClass.compact => 11.0,
          UiWindowClass.medium => 11.5,
          UiWindowClass.expanded => 12.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 12.5,
        };

        final statusCard = Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: clampedHomeContentMaxWidth),
            child: Container(
              padding: EdgeInsets.all(cardPadding),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainer
                    .withValues(alpha: 0.84),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withValues(alpha: 0.36),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (compactStatusStack)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                statusHeadline,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.w900,
                                      color: statusColor,
                                      fontSize: statusFontSize,
                                      height: 1.0,
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            SizedBox(
                              width: compactActionSize * 0.88,
                              height: compactActionSize * 0.88,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                tooltip: '연결 해제',
                                iconSize: compactActionSize * 0.52,
                                onPressed: canDisconnect
                                    ? () {
                                        ssh.disconnect();
                                        CustomToast.show(
                                          context,
                                          "연결이 해제되었습니다.",
                                        );
                                      }
                                    : null,
                                icon: Icon(
                                  Icons.link_off_rounded,
                                  color: canDisconnect
                                      ? Colors.white70
                                      : Colors.white24,
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: blockGap),
                        _buildIpField(
                          context: context,
                          ssh: ssh,
                          blockGap: blockGap,
                          ipChipLabelSize: ipChipLabelSize,
                          ipFieldText: ipFieldText,
                          ipFontSize: ipFontSize,
                        ),
                      ],
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            statusHeadline,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  color: statusColor,
                                  fontSize: statusFontSize,
                                  height: 1.0,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          flex: 5,
                          child: _buildIpField(
                            context: context,
                            ssh: ssh,
                            blockGap: blockGap,
                            ipChipLabelSize: ipChipLabelSize,
                            ipFieldText: ipFieldText,
                            ipFontSize: ipFontSize,
                          ),
                        ),
                        SizedBox(width: blockGap * 0.6),
                        SizedBox(
                          width: compactActionSize * 0.88,
                          height: compactActionSize * 0.88,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: '연결 해제',
                            iconSize: compactActionSize * 0.52,
                            onPressed: canDisconnect
                                ? () {
                                    ssh.disconnect();
                                    CustomToast.show(
                                      context,
                                      "연결이 해제되었습니다.",
                                    );
                                  }
                                : null,
                            icon: Icon(
                              Icons.link_off_rounded,
                              color: canDisconnect
                                  ? Colors.white70
                                  : Colors.white24,
                            ),
                          ),
                        ),
                      ],
                    ),
                  SizedBox(height: blockGap),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  SizedBox(height: blockGap),
                  LayoutBuilder(
                    builder: (context, infoConstraints) {
                      final itemSpacing = switch (window.windowClass) {
                        UiWindowClass.compact => 8.0,
                        UiWindowClass.medium => 9.0,
                        UiWindowClass.expanded => 10.0,
                        UiWindowClass.large || UiWindowClass.extraLarge => 11.0,
                      };
                      final columns = switch (window.windowClass) {
                        UiWindowClass.compact || UiWindowClass.medium => 2,
                        UiWindowClass.expanded => 3,
                        UiWindowClass.large || UiWindowClass.extraLarge => 4,
                      };
                      final itemWidth = (infoConstraints.maxWidth -
                              (itemSpacing * (columns - 1))) /
                          columns;
                      final itemValues = <MapEntry<String, String>>[
                        MapEntry(
                          "브랜치",
                          showDetails ? _branch : detailPlaceholder,
                        ),
                        MapEntry(
                          "커밋",
                          showDetails ? _commit : detailPlaceholder,
                        ),
                        MapEntry(
                          "Dongle ID",
                          showDetails ? _dongleId : detailPlaceholder,
                        ),
                        MapEntry(
                          "Serial",
                          showDetails ? _serial : detailPlaceholder,
                        ),
                      ];
                      return Wrap(
                        spacing: itemSpacing,
                        runSpacing: itemSpacing,
                        children: itemValues
                            .map(
                              (entry) => SizedBox(
                                width: itemWidth,
                                child: _buildInfoItem(entry.key, entry.value),
                              ),
                            )
                            .toList(),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );

        Widget buildScrollableHudPreview() {
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: hudPreviewMaxWidth),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openDriveView(ssh),
                child: _buildHudPreviewSurface(
                  context,
                  width: hudPreviewMaxWidth,
                  enabled: hudFeatureEnabled,
                  child: SizedBox(
                    width: hudPreviewMaxWidth,
                    child: AdaptiveHudHost(
                      enabled: hudFeatureEnabled && _hudKeepAliveEnabled,
                      deviceIp: ssh.connectedIp,
                      surface: HudSurfaceVariant.homePreview,
                      matchParentWidth: true,
                      syncNativeOverlay: false,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        final minPinnedHudHeight = switch (window.windowClass) {
          UiWindowClass.compact => 250.0,
          UiWindowClass.medium => 270.0,
          UiWindowClass.expanded => 290.0,
          UiWindowClass.large => 310.0,
          UiWindowClass.extraLarge => 330.0,
        };

        return LayoutBuilder(
          builder: (context, viewportConstraints) {
            final viewportHeight = viewportConstraints.maxHeight.isFinite
                ? viewportConstraints.maxHeight
                : media.size.height;
            final minPinnedViewportHeight = estimatedHeaderHeight +
                minPinnedHudHeight +
                (tokens.screenPadding * 2) +
                tokens.sectionGap +
                bottomDockGap;
            final canUsePinnedHudLayout =
                viewportHeight >= minPinnedViewportHeight;

            if (canUsePinnedHudLayout) {
              return Padding(
                padding: EdgeInsets.all(tokens.screenPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    statusCard,
                    SizedBox(height: tokens.sectionGap),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: bottomDockGap),
                        child: LayoutBuilder(
                          builder: (context, hudConstraints) {
                            final availableWidth = hudConstraints
                                    .maxWidth.isFinite
                                ? hudConstraints.maxWidth
                                : media.size.width - (tokens.screenPadding * 2);
                            final pinnedWidth =
                                clampedHomeContentMaxWidth.isFinite
                                    ? math.min(
                                        clampedHomeContentMaxWidth,
                                        availableWidth,
                                      )
                                    : availableWidth;
                            final pinnedHeight =
                                hudConstraints.maxHeight.isFinite
                                    ? hudConstraints.maxHeight
                                    : homeHudHeightCap;
                            return Align(
                              alignment: Alignment.bottomCenter,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _openDriveView(ssh),
                                child: _buildHudPreviewSurface(
                                  context,
                                  width: pinnedWidth,
                                  height: math.max(220.0, pinnedHeight),
                                  enabled: hudFeatureEnabled,
                                  child: SizedBox(
                                    width: pinnedWidth,
                                    height: math.max(220.0, pinnedHeight),
                                    child: AdaptiveHudHost(
                                      enabled: hudFeatureEnabled &&
                                          _hudKeepAliveEnabled,
                                      deviceIp: ssh.connectedIp,
                                      surface: HudSurfaceVariant.homePreview,
                                      fillParent: true,
                                      syncNativeOverlay: false,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            return ListView(
              padding: EdgeInsets.all(tokens.screenPadding),
              children: [
                statusCard,
                SizedBox(height: tokens.sectionGap),
                buildScrollableHudPreview(),
                SizedBox(height: bottomDockGap),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildHudPreviewSurface(
    BuildContext context, {
    required Widget child,
    required bool enabled,
    double? width,
    double? height,
  }) {
    if (enabled) {
      return child;
    }
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.44),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            alignment: Alignment.center,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    color: scheme.onSurface,
                    size: 28,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'HUD/Stock 비활성화',
                    textAlign: TextAlign.center,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'HUD 설정에서 기능을 활성화하면 Home HUD와 Stock 주행모드를 사용할 수 있습니다.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoItem(String label, String value) {
    final window = UiWindowInfo.of(context);
    final labelSize = switch (window.windowClass) {
      UiWindowClass.compact => 11.0,
      UiWindowClass.medium => 11.5,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 12.5,
      UiWindowClass.extraLarge => 13.0,
    };
    final valueSize = switch (window.windowClass) {
      UiWindowClass.compact => 15.0,
      UiWindowClass.medium => 15.5,
      UiWindowClass.expanded => 16.0,
      UiWindowClass.large => 16.5,
      UiWindowClass.extraLarge => 17.0,
    };
    final valueMaxLines = window.windowClass == UiWindowClass.compact ? 1 : 2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: labelSize,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: valueMaxLines,
            softWrap: valueMaxLines > 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: valueSize,
              height: valueMaxLines > 1 ? 1.08 : 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIpField({
    required BuildContext context,
    required SSHService ssh,
    required double blockGap,
    required double ipChipLabelSize,
    required String ipFieldText,
    required double ipFontSize,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: blockGap + 3,
        vertical: blockGap - 1,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.10),
        ),
      ),
      child: Row(
        children: [
          Text(
            'IP',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.62),
                  fontWeight: FontWeight.w700,
                  fontSize: ipChipLabelSize,
                ),
          ),
          SizedBox(width: blockGap * 0.7),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(_openManualIpDialog(ssh)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  ipFieldText,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontWeight: FontWeight.w700,
                        fontSize: ipFontSize,
                        height: 1.0,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          SizedBox(width: blockGap * 0.2),
          SizedBox(
            width: 34,
            height: 34,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: 'IP 자동 검색',
              iconSize: ipFontSize + 2,
              color: Colors.white70,
              onPressed: ssh.isConnecting
                  ? null
                  : () => unawaited(_runHomeGuidedDiscovery(ssh)),
              icon: const Icon(Icons.search_rounded),
            ),
          ),
        ],
      ),
    );
  }
}
