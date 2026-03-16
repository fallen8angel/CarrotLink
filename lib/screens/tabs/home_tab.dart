import 'dart:async';
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

class HomeTab extends StatefulWidget {
  final bool isActive;

  const HomeTab({super.key, required this.isActive});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with WidgetsBindingObserver {
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
  String? _overlaySyncedHost;
  DateTime? _overlayLastProbeAt;
  bool _appForeground = true;
  Timer? _prereqTimer;
  Timer? _overlaySyncTimer;

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
    final connectedHost = (ssh.connectedIp ?? '').trim();
    final serviceHost = (ssh.serviceConnectedIp ?? '').trim();
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

  String _statusHeadline(SSHService ssh) {
    if (!_hasGitHubLogin) return "GitHub 연동 필요";
    if (!_hasActiveSshKey) return "SSH 개인키 적용 필요";
    if (ssh.manualDisconnectRequested) return "연결 해제";
    if (ssh.isConnected) return "연결됨";
    if ((ssh.serviceConnectedIp ?? '').trim().isNotEmpty) {
      return "연결 동기화 중";
    }
    if (ssh.connectionStatus.startsWith("Connecting")) return "연결 중...";
    if (ssh.connectionStatus.contains("Error")) return "연결 실패";
    return "재연결 대기";
  }

  Color _statusColor(BuildContext context, SSHService ssh) {
    if (!_hasGitHubLogin || !_hasActiveSshKey) return Colors.grey;
    if (ssh.manualDisconnectRequested) return Colors.grey;
    if (ssh.isConnected || ssh.connectionStatus.startsWith("Connecting")) {
      return Theme.of(context).colorScheme.primary;
    }
    if ((ssh.serviceConnectedIp ?? '').trim().isNotEmpty) {
      return Theme.of(context).colorScheme.primary;
    }
    if (ssh.connectionStatus.contains("Error")) return Colors.grey;
    return Colors.grey;
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
        final hasIp = ssh.isConnected ||
            (ssh.serviceConnectedIp ?? '').trim().isNotEmpty ||
            (ssh.connectionStatus.startsWith("Connecting") &&
                (ssh.targetIp ?? '').trim().isNotEmpty);
        final ipFieldText = hasIp
            ? (ssh.connectedIp ??
                ssh.serviceConnectedIp ??
                ssh.targetIp ??
                "Unknown")
            : (!_hasGitHubLogin || !_hasActiveSshKey
                ? "연동 필요"
                : (ssh.manualDisconnectRequested ? "연결 해제" : "재연결 대기"));
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
                                color: _statusColor(context, ssh),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _statusHeadline(ssh),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.w900,
                                      color: _statusColor(context, ssh),
                                      fontSize: statusFontSize,
                                      height: 1.0,
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (ssh.isConnected ||
                                ssh.connectionStatus.startsWith("Connecting"))
                              SizedBox(
                                width: compactActionSize * 0.88,
                                height: compactActionSize * 0.88,
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  tooltip: '연결 해제',
                                  iconSize: compactActionSize * 0.52,
                                  color: Colors.white70,
                                  onPressed: () {
                                    ssh.disconnect();
                                    CustomToast.show(
                                      context,
                                      "연결이 해제되었습니다.",
                                    );
                                  },
                                  icon: const Icon(Icons.link_off_rounded),
                                ),
                              ),
                          ],
                        ),
                        SizedBox(height: blockGap),
                        _buildIpField(
                          context: context,
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
                            color: _statusColor(context, ssh),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _statusHeadline(ssh),
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  color: _statusColor(context, ssh),
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
                            blockGap: blockGap,
                            ipChipLabelSize: ipChipLabelSize,
                            ipFieldText: ipFieldText,
                            ipFontSize: ipFontSize,
                          ),
                        ),
                        if (ssh.isConnected ||
                            ssh.connectionStatus.startsWith("Connecting")) ...[
                          SizedBox(width: blockGap * 0.6),
                          SizedBox(
                            width: compactActionSize * 0.88,
                            height: compactActionSize * 0.88,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              tooltip: '연결 해제',
                              iconSize: compactActionSize * 0.52,
                              color: Colors.white70,
                              onPressed: () {
                                ssh.disconnect();
                                CustomToast.show(
                                  context,
                                  "연결이 해제되었습니다.",
                                );
                              },
                              icon: const Icon(Icons.link_off_rounded),
                            ),
                          ),
                        ],
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
                          ssh.isConnected ? _branch : "연결 안 됨",
                        ),
                        MapEntry(
                          "커밋",
                          ssh.isConnected ? _commit : "연결 안 됨",
                        ),
                        MapEntry(
                          "Dongle ID",
                          ssh.isConnected ? _dongleId : "연결 안 됨",
                        ),
                        MapEntry(
                          "Serial",
                          ssh.isConnected ? _serial : "연결 안 됨",
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
        ],
      ),
    );
  }
}
