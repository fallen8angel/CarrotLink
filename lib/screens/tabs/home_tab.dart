import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
import '../../services/github_service.dart';
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
    _refreshConnectionPrerequisites();
    if (ssh.isConnected && _branch == "--") {
      _refreshStatus();
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

  Future<void> _refreshStatus() async {
    if (!_realtimeWorkEnabled) return;
    await _refreshConnectionPrerequisites();
    if (!mounted) return;

    final ssh = Provider.of<SSHService>(context, listen: false);
    if (ssh.isConnected) {
      try {
        final results = await Future.wait([
          ssh.getBranch(),
          ssh.getCommitHash(),
          ssh.getDongleId(),
          ssh.getSerial(),
        ]);

        if (mounted) {
          setState(() {
            _branch = results[0];
            _commit = results[1];
            _dongleId = results[2];
            _serial = results[3];
          });
        }
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
    if (ssh.isConnected) return "연결됨";
    if (ssh.connectionStatus.startsWith("Connecting")) return "연결 중...";
    if (ssh.connectionStatus.contains("Error")) return "연결 실패";
    return "연결 대기";
  }

  Color _statusColor(BuildContext context, SSHService ssh) {
    if (!_hasGitHubLogin || !_hasActiveSshKey) return Colors.grey;
    if (ssh.connectionStatus.contains("Error")) return Colors.grey;
    return Theme.of(context).colorScheme.primary;
  }

  String? _currentDeviceHost(SSHService ssh) {
    return NativeOverlayHudService.normalizeHost(
        ssh.connectedIp ?? ssh.targetIp);
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

  Future<void> _openWebRtcView(SSHService ssh) async {
    final host = (ssh.connectedIp ?? ssh.targetIp ?? '').trim();
    if (host.isEmpty) {
      CustomToast.show(context, '연결 IP를 먼저 확인하세요.', isError: true);
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
    return Consumer<SSHService>(
      builder: (context, ssh, child) {
        final media = MediaQuery.of(context);
        final compactStatusStack = window.windowClass == UiWindowClass.compact;
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
            ssh.connectionStatus.startsWith("Connecting") ||
            ssh.targetIp != null;
        final ipFieldText =
            hasIp ? (ssh.connectedIp ?? ssh.targetIp ?? "Unknown") : "연동 필요";
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
        }.toDouble();
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

        return ListView(
          padding: EdgeInsets.all(tokens.screenPadding),
          children: [
            // Header Card
            Center(
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: clampedHomeContentMaxWidth),
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
                                    ssh.connectionStatus
                                        .startsWith("Connecting"))
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
                                            context, "연결이 해제되었습니다.");
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
                                ssh.connectionStatus
                                    .startsWith("Connecting")) ...[
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
                                    CustomToast.show(context, "연결이 해제되었습니다.");
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
                            UiWindowClass.large ||
                            UiWindowClass.extraLarge =>
                              11.0,
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
                                "브랜치", ssh.isConnected ? _branch : "연결 안 됨"),
                            MapEntry(
                                "커밋", ssh.isConnected ? _commit : "연결 안 됨"),
                            MapEntry("Dongle ID",
                                ssh.isConnected ? _dongleId : "연결 안 됨"),
                            MapEntry(
                                "Serial", ssh.isConnected ? _serial : "연결 안 됨"),
                          ];
                          return Wrap(
                            spacing: itemSpacing,
                            runSpacing: itemSpacing,
                            children: itemValues
                                .map(
                                  (entry) => SizedBox(
                                    width: itemWidth,
                                    child:
                                        _buildInfoItem(entry.key, entry.value),
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
            ),
            SizedBox(height: tokens.sectionGap),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: hudPreviewMaxWidth),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openWebRtcView(ssh),
                  child: SizedBox(
                    width: hudPreviewMaxWidth,
                    child: AdaptiveHudHost(
                      enabled: _realtimeWorkEnabled,
                      deviceIp: ssh.connectedIp ?? ssh.targetIp,
                      surface: HudSurfaceVariant.homePreview,
                      matchParentWidth: true,
                      syncNativeOverlay: false,
                    ),
                  ),
                ),
              ),
            ),

            // Quick Actions Grid Removed
            SizedBox(height: tokens.footerSpacer),
          ],
        );
      },
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
