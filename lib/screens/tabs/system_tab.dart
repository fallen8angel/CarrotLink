import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/device_action_service.dart';
import '../../services/sidecar_service.dart';
import '../../services/ssh_service.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/design_components.dart';

class SystemTab extends StatefulWidget {
  const SystemTab({super.key});

  @override
  State<SystemTab> createState() => _SystemTabState();
}

class _SystemTabState extends State<SystemTab> {
  final DeviceActionService _actionService = DeviceActionService();
  final SidecarService _sidecarService = SidecarService();
  bool _sidecarBusy = false;
  String _sidecarProfile = 'p2';

  Future<void> _executeManagedAction(
    BuildContext context, {
    required DeviceActionType action,
    required String title,
    required String message,
    bool isDestructive = false,
  }) async {
    final ssh = Provider.of<SSHService>(context, listen: false);

    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("취소"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDestructive
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
              foregroundColor: isDestructive
                  ? Theme.of(context).colorScheme.onError
                  : Theme.of(context).colorScheme.onPrimary,
            ),
            child: const Text("확인"),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    DeviceActionResult? result;
    Object? error;

    try {
      result = await _actionService.runAction(ssh, action);
    } catch (e) {
      error = e;
    } finally {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    if (!mounted) return;

    if (error != null) {
      CustomToast.show(context, "실행 실패: $error", isError: true);
      return;
    }

    if (result == null) {
      CustomToast.show(context, "실행 결과가 비어 있습니다.", isError: true);
      return;
    }

    final finalResult = result;
    if (finalResult.ok) {
      CustomToast.show(context, "$title 완료");
    } else {
      CustomToast.show(
        context,
        "$title 실패 (code: ${finalResult.exitCode})",
        isError: true,
      );
    }
  }

  Future<void> _runSidecarTask(
    BuildContext context, {
    required String title,
    required Future<String> Function(SSHService ssh) task,
    bool showOutputDialog = true,
  }) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }
    if (_sidecarBusy) return;

    setState(() => _sidecarBusy = true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    String? output;
    Object? error;
    try {
      output = await task(ssh);
    } catch (e) {
      error = e;
    } finally {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) {
        setState(() => _sidecarBusy = false);
      }
    }

    if (!mounted) return;
    if (error != null) {
      CustomToast.show(context, "$title 실패: $error", isError: true);
      return;
    }
    CustomToast.show(context, "$title 완료");
    if (showOutputDialog) {
      final text = (output ?? '').trim();
      if (text.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: SelectableText(text),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text("닫기"),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSection(context, "전원 및 프로세스", Icons.power_settings_new, [
          _buildActionButton(
            context,
            "소프트 재시작 (Soft Restart)",
            Icons.refresh,
            DeviceActionType.softRestart,
            "UI를 재시작하시겠습니까?",
            Colors.orange,
          ),
          _buildActionButton(
            context,
            "기기 재부팅 (Reboot)",
            Icons.restart_alt,
            DeviceActionType.reboot,
            "기기를 재부팅하시겠습니까?",
            Colors.red,
            isDestructive: true,
          ),
        ]),
        const SizedBox(height: 16),
        _buildSection(context, "빌드 및 유지보수", Icons.build_circle_outlined, [
          _buildActionButton(
            context,
            "오픈파일럿 재빌드 (Rebuild)",
            Icons.build,
            DeviceActionType.rebuildOpenpilot,
            "재빌드를 시작하시겠습니까? 시간이 소요될 수 있습니다.",
            Colors.blue,
          ),
        ]),
        const SizedBox(height: 16),
        _buildSection(context, "데이터 관리", Icons.storage, [
          _buildActionButton(
            context,
            "학습 데이터 초기화 (Live Params)",
            Icons.tune,
            DeviceActionType.resetLiveParameters,
            "주행 학습 데이터를 초기화하시겠습니까?",
            Colors.grey,
          ),
          _buildActionButton(
            context,
            "캘리브레이션 초기화 (Calibration)",
            Icons.camera_alt,
            DeviceActionType.resetCalibration,
            "카메라 캘리브레이션을 초기화하고 재부팅하시겠습니까?",
            Colors.grey,
          ),
          _buildActionButton(
            context,
            "녹화 영상 삭제 (Delete Videos)",
            Icons.video_library,
            DeviceActionType.deleteVideos,
            "모든 주행 녹화 영상을 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.",
            Colors.red,
            isDestructive: true,
          ),
          _buildActionButton(
            context,
            "주행 로그 삭제 (Delete Logs)",
            Icons.delete_sweep,
            DeviceActionType.deleteLogs,
            "모든 주행 로그를 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.",
            Colors.red,
            isDestructive: true,
          ),
        ]),
        const SizedBox(height: 16),
        _buildSection(context, "CarrotLink Sidecar", Icons.hub_outlined, [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              "배포 경로: /data/media/0/carrotlink_sidecar\n"
              "세션: tmux carrotlink_sidecar / 포트: 7766",
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          Row(
            children: [
              const Text("프로파일"),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'p0', label: Text('P0')),
                    ButtonSegment(value: 'p1', label: Text('P1')),
                    ButtonSegment(value: 'p2', label: Text('P2')),
                    ButtonSegment(value: 'p3', label: Text('P3')),
                  ],
                  selected: <String>{_sidecarProfile},
                  onSelectionChanged: _sidecarBusy
                      ? null
                      : (selected) {
                          if (selected.isEmpty) return;
                          setState(() => _sidecarProfile = selected.first);
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildSidecarButton(
            context,
            label: "사이드카 배포/업데이트",
            icon: Icons.publish,
            onTap: () => _runSidecarTask(
              context,
              title: "사이드카 배포",
              task: (ssh) => _sidecarService.deploy(ssh),
            ),
          ),
          _buildSidecarButton(
            context,
            label: "사이드카 시작",
            icon: Icons.play_circle_outline,
            onTap: () => _runSidecarTask(
              context,
              title: "사이드카 시작",
              task: (ssh) => _sidecarService.start(
                ssh,
                profile: _sidecarProfile,
              ),
            ),
          ),
          _buildSidecarButton(
            context,
            label: "사이드카 중지",
            icon: Icons.stop_circle_outlined,
            onTap: () => _runSidecarTask(
              context,
              title: "사이드카 중지",
              task: (ssh) => _sidecarService.stop(ssh),
            ),
          ),
          _buildSidecarButton(
            context,
            label: "상태 확인",
            icon: Icons.info_outline,
            onTap: () => _runSidecarTask(
              context,
              title: "사이드카 상태",
              task: (ssh) => _sidecarService.status(ssh),
            ),
          ),
          _buildSidecarButton(
            context,
            label: "로그 확인 (최근 120줄)",
            icon: Icons.article_outlined,
            onTap: () => _runSidecarTask(
              context,
              title: "사이드카 로그",
              task: (ssh) => _sidecarService.tailLog(ssh, lines: 120),
            ),
          ),
        ]),
        const SizedBox(height: 100),
      ],
    );
  }

  Widget _buildSection(
    BuildContext context,
    String title,
    IconData icon,
    List<Widget> children,
  ) {
    return DesignCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DesignSectionHeader(
            icon: icon,
            title: title,
            marginBottom: 8,
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _buildSidecarButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(
        label,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      trailing: _sidecarBusy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
      onTap: _sidecarBusy ? null : onTap,
    );
  }

  Widget _buildActionButton(
    BuildContext context,
    String label,
    IconData icon,
    DeviceActionType action,
    String confirmMessage,
    Color? color, {
    bool isDestructive = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (color ?? Theme.of(context).colorScheme.primary)
                .withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            color: color ?? Theme.of(context).colorScheme.primary,
            size: 20,
          ),
        ),
        title: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
        ),
        trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
        onTap: () => _executeManagedAction(
          context,
          action: action,
          title: label,
          message: confirmMessage,
          isDestructive: isDestructive,
        ),
      ),
    );
  }
}
