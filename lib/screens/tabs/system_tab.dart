import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/device_action_service.dart';
import '../../services/ssh_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/design_components.dart';

class SystemTab extends StatefulWidget {
  const SystemTab({super.key});

  @override
  State<SystemTab> createState() => _SystemTabState();
}

class _SystemTabState extends State<SystemTab> {
  final DeviceActionService _actionService = DeviceActionService();

  Future<void> _executeManagedAction({
    required DeviceActionType action,
    required String title,
    required String message,
    bool isDestructive = false,
  }) async {
    final ctx = context;
    final scheme = Theme.of(ctx).colorScheme;
    final ssh = Provider.of<SSHService>(ctx, listen: false);

    if (!ssh.isConnected) {
      CustomToast.show(ctx, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: ctx,
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
              backgroundColor: isDestructive ? scheme.error : scheme.primary,
              foregroundColor:
                  isDestructive ? scheme.onError : scheme.onPrimary,
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

  @override
  Widget build(BuildContext context) {
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        tokens.screenPadding.clamp(12.0, 24.0).toDouble(),
        16,
        tokens.screenPadding.clamp(12.0, 24.0).toDouble(),
        tokens.footerSpacer,
      ),
      children: [
        _buildSection(context, "전원 및 프로세스", Icons.power_settings_new, [
          _buildActionButton(
            context,
            "소프트 재시작 (Soft Restart)",
            Icons.refresh,
            DeviceActionType.softRestart,
            "UI를 재시작하시겠습니까?",
            scheme.tertiary,
          ),
          _buildActionButton(
            context,
            "기기 재부팅 (Reboot)",
            Icons.restart_alt,
            DeviceActionType.reboot,
            "기기를 재부팅하시겠습니까?",
            scheme.error,
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
            scheme.primary,
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
            scheme.secondary,
          ),
          _buildActionButton(
            context,
            "캘리브레이션 초기화 (Calibration)",
            Icons.camera_alt,
            DeviceActionType.resetCalibration,
            "카메라 캘리브레이션을 초기화하고 재부팅하시겠습니까?",
            scheme.secondary,
          ),
          _buildActionButton(
            context,
            "녹화 영상 삭제 (Delete Videos)",
            Icons.video_library,
            DeviceActionType.deleteVideos,
            "모든 주행 녹화 영상을 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.",
            scheme.error,
            isDestructive: true,
          ),
          _buildActionButton(
            context,
            "주행 로그 삭제 (Delete Logs)",
            Icons.delete_sweep,
            DeviceActionType.deleteLogs,
            "모든 주행 로그를 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.",
            scheme.error,
            isDestructive: true,
          ),
        ]),
        SizedBox(height: tokens.sectionGap + 10),
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

  Widget _buildActionButton(
    BuildContext context,
    String label,
    IconData icon,
    DeviceActionType action,
    String confirmMessage,
    Color? color, {
    bool isDestructive = false,
  }) {
    final window = UiWindowInfo.of(context);
    final scheme = Theme.of(context).colorScheme;
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
          style: TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: switch (window.windowClass) {
              UiWindowClass.compact => 13.5,
              UiWindowClass.medium => 14.0,
              _ => 14.5,
            },
          ),
        ),
        trailing: Icon(
          Icons.chevron_right,
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
        onTap: () => _executeManagedAction(
          action: action,
          title: label,
          message: confirmMessage,
          isDestructive: isDestructive,
        ),
      ),
    );
  }
}
