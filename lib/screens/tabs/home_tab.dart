import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
import '../../services/github_service.dart';
import '../../services/native_overlay_hud_service.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/home_hud_preview_card.dart';
import '../../widgets/webrtc_drive_screen.dart';

import 'package:carrot_pilot_manager/widgets/design_components.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

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
  bool _overlayPermissionGranted = false;
  bool _overlayRunning = false;
  bool _overlayBusy = false;
  String? _overlaySyncedHost;
  DateTime? _overlayLastProbeAt;
  Timer? _statusTimer;
  Timer? _prereqTimer;
  Timer? _overlaySyncTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshStatus();
    _statusTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _refreshStatus());
    _prereqTimer = Timer.periodic(
        const Duration(seconds: 2), (_) => _refreshConnectionPrerequisites());
    if (NativeOverlayHudService.isSupported) {
      unawaited(_refreshOverlayState(syncEndpoint: true));
      _overlaySyncTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_syncOverlayEndpoint()),
      );
    }
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
    _statusTimer?.cancel();
    _prereqTimer?.cancel();
    _overlaySyncTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        NativeOverlayHudService.isSupported) {
      unawaited(_refreshOverlayState(syncEndpoint: true));
    }
  }

  Future<void> _refreshStatus() async {
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

  Future<void> _refreshOverlayState({bool syncEndpoint = false}) async {
    final hasPermission = await NativeOverlayHudService.hasPermission();
    final running = await NativeOverlayHudService.isRunning();
    if (!mounted) return;
    setState(() {
      _overlayPermissionGranted = hasPermission;
      _overlayRunning = running;
    });
    if (syncEndpoint) {
      await _syncOverlayEndpoint();
    }
  }

  Future<void> _syncOverlayEndpoint({bool forceProbe = false}) async {
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

  Future<void> _startOverlayHud(SSHService ssh) async {
    if (_overlayBusy) return;
    setState(() => _overlayBusy = true);
    try {
      var hasPermission = await NativeOverlayHudService.hasPermission();
      if (!hasPermission) {
        await NativeOverlayHudService.requestPermission();
        if (mounted) {
          CustomToast.show(context, '시스템 설정에서 오버레이 권한을 허용하세요.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
        hasPermission = await NativeOverlayHudService.hasPermission();
      }
      if (!hasPermission) return;

      final host = _currentDeviceHost(ssh);
      if (host == null) {
        if (mounted) {
          CustomToast.show(context, '연결된 기기 IP가 없어 시작할 수 없습니다.', isError: true);
        }
        return;
      }

      final started = await NativeOverlayHudService.start(host);
      if (!mounted) return;
      if (!started) {
        CustomToast.show(context, 'HUD 오버레이 시작 실패', isError: true);
        return;
      }
      _overlaySyncedHost = host;
      CustomToast.show(context, 'HUD 오버레이 시작됨');
    } finally {
      if (mounted) {
        setState(() => _overlayBusy = false);
      }
      await _refreshOverlayState(syncEndpoint: true);
    }
  }

  Future<void> _stopOverlayHud() async {
    if (_overlayBusy) return;
    setState(() => _overlayBusy = true);
    try {
      await NativeOverlayHudService.stop();
      if (mounted) {
        CustomToast.show(context, 'HUD 오버레이 중지됨');
      }
      _overlaySyncedHost = null;
    } finally {
      if (mounted) {
        setState(() => _overlayBusy = false);
      }
      await _refreshOverlayState(syncEndpoint: false);
    }
  }

  void _openWebRtcView(SSHService ssh) {
    final host = (ssh.connectedIp ?? ssh.targetIp ?? '').trim();
    if (host.isEmpty) {
      CustomToast.show(context, '연결 IP를 먼저 확인하세요.', isError: true);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WebRtcDriveScreen(hostIp: host),
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
                    deviceIp: ssh.connectedIp ?? ssh.targetIp,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '탭해서 WebRTC 주행화면 열기',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            if (NativeOverlayHudService.isSupported) ...[
              const SizedBox(height: 12),
              DesignCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.layers_outlined,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '네이티브 HUD 오버레이',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ),
                        if (_overlayBusy)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _overlayPermissionGranted
                          ? (_overlayRunning ? '상태: 실행 중' : '상태: 중지됨')
                          : '상태: 오버레이 권한 필요',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _currentDeviceHost(ssh) == null
                          ? '대상 IP: 없음'
                          : '대상 IP: ${_currentDeviceHost(ssh)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (!_overlayPermissionGranted)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _overlayBusy
                                  ? null
                                  : () async {
                                      await NativeOverlayHudService
                                          .requestPermission();
                                      if (!context.mounted) return;
                                      CustomToast.show(
                                        context,
                                        '권한 화면에서 "다른 앱 위에 표시"를 허용하세요.',
                                      );
                                      await Future<void>.delayed(
                                          const Duration(milliseconds: 350));
                                      await _refreshOverlayState(
                                          syncEndpoint: true);
                                    },
                              icon: const Icon(Icons.security_outlined),
                              label: const Text('권한 요청'),
                            ),
                          )
                        else
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _overlayBusy
                                  ? null
                                  : _overlayRunning
                                      ? _stopOverlayHud
                                      : () => _startOverlayHud(ssh),
                              icon: Icon(
                                _overlayRunning
                                    ? Icons.stop_circle_outlined
                                    : Icons.play_circle_outline,
                              ),
                              label: Text(_overlayRunning ? '중지' : '시작'),
                            ),
                          ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: (_overlayBusy || !_overlayRunning)
                              ? null
                              : () async {
                                  await NativeOverlayHudService.resetPosition();
                                  await _refreshOverlayState(syncEndpoint: true);
                                  if (context.mounted) {
                                    CustomToast.show(context, 'HUD 위치 초기화됨');
                                  }
                                },
                          icon: const Icon(Icons.my_location),
                          tooltip: 'HUD 위치 초기화',
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: _overlayBusy
                              ? null
                              : () async {
                                  await _refreshOverlayState(
                                      syncEndpoint: true);
                                  if (context.mounted) {
                                    CustomToast.show(context, '오버레이 상태 갱신됨');
                                  }
                                },
                          icon: const Icon(Icons.refresh),
                          tooltip: '오버레이 상태 갱신',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],

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
