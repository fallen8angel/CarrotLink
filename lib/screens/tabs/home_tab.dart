import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
import '../../services/github_service.dart';
import '../../services/native_overlay_hud_service.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/home_hud_preview_card.dart';
import '../drive/live_drive_canvas_screen.dart';

import 'package:carrot_pilot_manager/widgets/design_components.dart';

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
  Timer? _hudFallbackTimer;
  double? _fallbackCpuTempC;
  double? _fallbackMemPct;
  double? _fallbackDiskPct;

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
    _hudFallbackTimer?.cancel();
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
      _hudFallbackTimer ??= Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_refreshHudFallbackMetrics()),
      );
      if (forceRefresh) {
        unawaited(_refreshConnectionPrerequisites());
        unawaited(_refreshStatus());
        unawaited(_syncOverlayEndpoint(forceProbe: true));
        unawaited(_refreshHudFallbackMetrics());
      }
      return;
    }

    _prereqTimer?.cancel();
    _prereqTimer = null;
    _overlaySyncTimer?.cancel();
    _overlaySyncTimer = null;
    _hudFallbackTimer?.cancel();
    _hudFallbackTimer = null;
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

  Future<void> _refreshHudFallbackMetrics() async {
    if (!_realtimeWorkEnabled) return;
    if (!mounted) return;
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) return;
    final metrics = await ssh.getHudFallbackMetrics();
    if (metrics == null) return;

    if (NativeOverlayHudService.isSupported) {
      final overlayEnabled = await NativeOverlayHudService.isEnabled();
      if (!overlayEnabled) {
        return;
      }
      final overlayRunning = await NativeOverlayHudService.isRunning();
      if (!overlayRunning) {
        return;
      }
      await NativeOverlayHudService.updateFallbackMetrics(
        cpuTempC: metrics.cpuTempC,
        memPct: metrics.memPct,
        diskPct: metrics.diskPct,
      );
    }

    if (!mounted) return;
    final sameCpu = _fallbackCpuTempC == metrics.cpuTempC;
    final sameMem = _fallbackMemPct == metrics.memPct;
    final sameDisk = _fallbackDiskPct == metrics.diskPct;
    if (sameCpu && sameMem && sameDisk) return;
    setState(() {
      _fallbackCpuTempC = metrics.cpuTempC;
      _fallbackMemPct = metrics.memPct;
      _fallbackDiskPct = metrics.diskPct;
    });
  }

  void _openWebRtcView(SSHService ssh) {
    final host = (ssh.connectedIp ?? ssh.targetIp ?? '').trim();
    if (host.isEmpty) {
      CustomToast.show(context, '연결 IP를 먼저 확인하세요.', isError: true);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveDriveCanvasScreen(hostIp: host),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SSHService>(
      builder: (context, ssh, child) {
        return ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // Header Card
            DesignCard(
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: (ssh.isConnected
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey)
                              .withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.directions_car,
                          color: ssh.isConnected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey,
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '상태',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(
                                    color: Colors.grey,
                                  ),
                            ),
                            GestureDetector(
                              onTap: () {
                                if (ssh.isConnected ||
                                    ssh.connectionStatus
                                        .startsWith("Connecting")) {
                                  ssh.disconnect();
                                  CustomToast.show(context, "연결이 해제되었습니다.");
                                }
                              },
                              child: Text(
                                _statusHeadline(ssh),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: _statusColor(context, ssh),
                                    ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              (ssh.isConnected ||
                                      ssh.connectionStatus
                                          .startsWith("Connecting") ||
                                      ssh.targetIp != null)
                                  ? "IP: ${ssh.connectedIp ?? ssh.targetIp ?? "Unknown"}"
                                  : "GitHub 로그인 및 SSH 키 적용 후 연결 가능합니다.",
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Colors.grey,
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 20),
                  // Info Grid
                  Row(
                    children: [
                      Expanded(
                          child: _buildInfoItem(Icons.call_split, "브랜치",
                              ssh.isConnected ? _branch : "연결 안 됨")),
                      Expanded(
                          child: _buildInfoItem(Icons.commit, "커밋",
                              ssh.isConnected ? _commit : "연결 안 됨")),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                          child: _buildInfoItem(Icons.fingerprint, "Dongle ID",
                              ssh.isConnected ? _dongleId : "연결 안 됨")),
                      Expanded(
                          child: _buildInfoItem(Icons.qr_code, "Serial",
                              ssh.isConnected ? _serial : "연결 안 됨")),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openWebRtcView(ssh),
              child: Column(
                children: [
                  HomeHudPreviewCard(
                    enabled: _realtimeWorkEnabled,
                    deviceIp: ssh.connectedIp ?? ssh.targetIp,
                    fallbackCpuTempC: _fallbackCpuTempC,
                    fallbackMemPct: _fallbackMemPct,
                    fallbackDiskPct: _fallbackDiskPct,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '탭해서 새 주행화면 열기',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),

            // Quick Actions Grid Removed
            const SizedBox(height: 120),
          ],
        );
      },
    );
  }

  Widget _buildInfoItem(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey[400]),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(color: Colors.grey[600], fontSize: 12)),
              Text(value,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }
}
