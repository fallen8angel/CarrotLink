import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/sidecar_service.dart';
import '../../services/ssh_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';

class HudSettingsScreen extends StatefulWidget {
  const HudSettingsScreen({super.key});

  @override
  State<HudSettingsScreen> createState() => _HudSettingsScreenState();
}

class _HudSettingsScreenState extends State<HudSettingsScreen> {
  final SidecarService _sidecar = SidecarService();
  bool _busy = false;
  final List<_StepLog> _steps = [];

  SSHService get _ssh => Provider.of<SSHService>(context, listen: false);

  // ═══════════════════════════════════════════════════════════════
  //  완전 초기화 + 재배포
  // ═══════════════════════════════════════════════════════════════
  Future<void> _cleanAll() async {
    if (_busy) return;
    final ssh = _ssh;
    if (!ssh.isConnected) {
      _showSnack('SSH 연결이 되어있지 않습니다.', isError: true);
      return;
    }

    final confirmed = await _confirm(
      title: '사이드카 완전 초기화',
      message:
          '이 작업은 디바이스에서 다음을 수행합니다:\n\n'
          '① 실행 중인 sidecar 프로세스 중지\n'
          '② 레거시 tmux 세션 종료 (carrotlink_camera, carrotlink_diag 등)\n'
          '③ 레거시 파일 삭제 (camera.py, diag.py, 구버전 스크립트)\n'
          '④ process_config.py에서 managed 모듈 제거\n'
          '⑤ 현재 sidecar 파일 + PID/로그 삭제\n'
          '⑥ 최신 sidecar.py/sidecar.sh 재배포\n'
          '⑦ 새 sidecar 시작 + health 검증\n\n'
          '진행하시겠습니까?',
      confirmText: '초기화 + 재배포',
    );
    if (!confirmed) return;

    setState(() {
      _busy = true;
      _steps.clear();
    });

    try {
      // 1. stop
      _addStep('프로세스 중지', status: _StepStatus.running);
      try {
        final stopOut = await _sidecar.stop(ssh);
        _updateLastStep(
          status: _StepStatus.ok,
          detail: _parseKeyLines(stopOut, ['SIDECAR_STOPPED', 'running=']),
        );
      } catch (e) {
        _updateLastStep(
          status: _StepStatus.warn,
          detail: '이미 중지됨 또는 목표 없음',
        );
      }

      // 2. legacy cleanup
      _addStep('레거시 정리', status: _StepStatus.running);
      try {
        final legacyOut =
            await _sidecar.cleanupLegacyInstall(ssh, force: true);
        final summary = _parseLegacyCleanupOutput(legacyOut);
        _updateLastStep(status: _StepStatus.ok, detail: summary);
      } catch (e) {
        _updateLastStep(
          status: _StepStatus.warn,
          detail: '레거시 항목 없음 또는 스킵',
        );
      }

      // 3. reset (현재 파일 삭제)
      _addStep('현재 파일 초기화', status: _StepStatus.running);
      try {
        final resetOut = await _sidecar.resetForTesting(
          ssh,
          removeManagerRegistration: true,
        );
        _updateLastStep(
          status: _StepStatus.ok,
          detail: _parseKeyLines(resetOut, [
            'SIDECAR_RESET_DONE',
            'base=',
          ]),
        );
      } catch (e) {
        _updateLastStep(
          status: _StepStatus.warn,
          detail: '초기화 부분 실패: $e',
        );
      }

      // 4. deploy
      _addStep('최신 버전 배포', status: _StepStatus.running);
      await _sidecar.deploy(ssh);
      final localRev = await _sidecar.localRevision();
      _updateLastStep(
        status: _StepStatus.ok,
        detail:
            'rev: ${_sidecar.shortRevision(localRev, length: 12)}',
      );

      // 5. start
      _addStep('사이드카 시작', status: _StepStatus.running);
      final startOut = await _sidecar.start(ssh);
      _updateLastStep(
        status: _StepStatus.ok,
        detail: _parseKeyLines(
          startOut,
          ['SIDECAR_STARTED', 'SIDECAR_ALREADY_RUNNING', 'sidecar_port_pids='],
        ),
      );

      // 6. health 검증
      _addStep('Health 검증', status: _StepStatus.running);
      final statusOut = await _sidecar.status(ssh);
      final healthResult = _parseStatusVerification(statusOut);
      _updateLastStep(
        status: healthResult.ok ? _StepStatus.ok : _StepStatus.fail,
        detail: healthResult.summary,
      );

      // 7. revision 검증
      _addStep('Revision 검증', status: _StepStatus.running);
      final remoteRev = await _sidecar.remoteRevision(ssh);
      final revMatch = remoteRev != null && remoteRev == localRev;
      _updateLastStep(
        status: revMatch ? _StepStatus.ok : _StepStatus.fail,
        detail: revMatch
            ? 'local=remote=${_sidecar.shortRevision(localRev, length: 8)}'
            : 'local=${_sidecar.shortRevision(localRev, length: 8)} '
                'remote=${_sidecar.shortRevision(remoteRev ?? "-", length: 8)} 불일치!',
      );

      _showSnack('완전 초기화 + 재배포 완료');
    } catch (e) {
      _updateLastStep(status: _StepStatus.fail, detail: '$e');
      _showSnack('초기화 실패: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  재배포 (stop → deploy → start)
  // ═══════════════════════════════════════════════════════════════
  Future<void> _redeploy() async {
    if (_busy) return;
    final ssh = _ssh;
    if (!ssh.isConnected) {
      _showSnack('SSH 연결이 되어있지 않습니다.', isError: true);
      return;
    }

    setState(() {
      _busy = true;
      _steps.clear();
    });

    try {
      // 1. stop
      _addStep('프로세스 중지', status: _StepStatus.running);
      try {
        await _sidecar.stop(ssh);
        _updateLastStep(status: _StepStatus.ok, detail: '중지 완료');
      } catch (_) {
        _updateLastStep(status: _StepStatus.warn, detail: '이미 중지됨');
      }

      // 2. deploy
      _addStep('최신 버전 배포', status: _StepStatus.running);
      await _sidecar.deploy(ssh);
      final localRev = await _sidecar.localRevision();
      _updateLastStep(
        status: _StepStatus.ok,
        detail: 'rev: ${_sidecar.shortRevision(localRev, length: 12)}',
      );

      // 3. start
      _addStep('사이드카 시작', status: _StepStatus.running);
      final startOut = await _sidecar.start(ssh);
      _updateLastStep(
        status: _StepStatus.ok,
        detail: _parseKeyLines(startOut, [
          'SIDECAR_STARTED',
          'SIDECAR_ALREADY_RUNNING',
          'sidecar_port_pids=',
        ]),
      );

      // 4. health 검증
      _addStep('Health 검증', status: _StepStatus.running);
      final statusOut = await _sidecar.status(ssh);
      final healthResult = _parseStatusVerification(statusOut);
      _updateLastStep(
        status: healthResult.ok ? _StepStatus.ok : _StepStatus.fail,
        detail: healthResult.summary,
      );

      _showSnack('재배포 완료');
    } catch (e) {
      _updateLastStep(status: _StepStatus.fail, detail: '$e');
      _showSnack('재배포 실패: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  파싱 유틸
  // ═══════════════════════════════════════════════════════════════
  String _parseKeyLines(String output, List<String> prefixes) {
    final lines = output.split('\n').map((e) => e.trim()).where((e) {
      return e.isNotEmpty &&
          prefixes.any(
            (p) => e.startsWith(p) || e.contains(p),
          );
    });
    return lines.isEmpty ? '(출력 없음)' : lines.join('\n');
  }

  String _parseLegacyCleanupOutput(String output) {
    final lines = output.split('\n').map((e) => e.trim()).toList();
    final parts = <String>[];

    for (final line in lines) {
      if (line.startsWith('LEGACY_CLEANUP_ALREADY_DONE')) {
        return '레거시 항목 없음 (이미 정리됨)';
      }
      if (line.startsWith('cfg_removed=')) {
        final v = line.split('=').last.trim();
        parts.add('config 정리: ${v == "1" ? "삭제됨 ✓" : "해당없음"}');
      }
      if (line.startsWith('legacy_files_removed=')) {
        final v = line.split('=').last.trim();
        parts.add('파일 삭제: ${v == "1" ? "삭제됨 ✓" : "해당없음"}');
      }
      if (line.startsWith('legacy_runtime_killed=')) {
        final v = line.split('=').last.trim();
        parts.add('프로세스 종료: ${v == "1" ? "종료됨 ✓" : "해당없음"}');
      }
    }
    if (parts.isEmpty) return '정리 완료';
    return parts.join(' | ');
  }

  ({bool ok, String summary}) _parseStatusVerification(String output) {
    final lines = output.split('\n').map((e) => e.trim()).toList();
    String running = '?';
    String listening = '?';
    String method = '?';
    String portPids = '';
    String remoteRev = '';

    for (final line in lines) {
      if (line.startsWith('running=')) running = line.split('=').last;
      if (line.startsWith('listening=')) listening = line.split('=').last;
      if (line.startsWith('method=')) method = line.split('=').last;
      if (line.startsWith('port_pids=')) portPids = line.split('=').last;
      if (line.startsWith('remote_revision=')) {
        remoteRev = line.substring('remote_revision='.length);
      }
    }

    final ok = running == '1' && listening == '1';
    final shortRev = remoteRev.length > 8
        ? remoteRev.substring(0, 8)
        : remoteRev.isEmpty
            ? '-'
            : remoteRev;
    final summary =
        'running=$running listen=$listening method=$method pid=$portPids rev=$shortRev';
    return (ok: ok, summary: summary);
  }

  // ═══════════════════════════════════════════════════════════════
  //  UI 유틸
  // ═══════════════════════════════════════════════════════════════
  void _addStep(String label, {_StepStatus status = _StepStatus.pending}) {
    if (!mounted) return;
    setState(() {
      _steps.add(_StepLog(label: label, status: status, detail: null));
    });
  }

  void _updateLastStep({required _StepStatus status, String? detail}) {
    if (!mounted || _steps.isEmpty) return;
    setState(() {
      final last = _steps.last;
      _steps[_steps.length - 1] = _StepLog(
        label: last.label,
        status: status,
        detail: detail,
      );
    });
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor:
            isError ? Theme.of(context).colorScheme.error : null,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: isError ? 5 : 3),
      ),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) {
            final scheme = Theme.of(ctx).colorScheme;
            return AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(
                child: Text(message, style: const TextStyle(height: 1.5)),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('취소'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(confirmText),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  // ═══════════════════════════════════════════════════════════════
  //  build
  // ═══════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('HUD')),
      body: ListView(
        padding: EdgeInsets.only(
          left: tokens.screenPadding.clamp(12.0, 24.0).toDouble(),
          right: tokens.screenPadding.clamp(12.0, 24.0).toDouble(),
          top: 14.0,
          bottom: tokens.footerSpacer,
        ),
        children: [
          // ── 사이드카 모드 (기존) ──
          _sectionHeader(context, Icons.tune, '사이드카 모드'),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline_rounded,
                      size: 20, color: scheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    'Stock (openpilot overlay)',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
            child: Text(
              '그래픽 오버레이 + direct 카메라 모드가 기본 적용됩니다.',
              style: TextStyle(
                fontSize: window.isCompact ? 11.5 : 12.0,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),

          // ── 사이드카 관리 ──
          _sectionHeader(
              context, Icons.build_circle_outlined, '사이드카 관리'),
          const SizedBox(height: 4),

          // 완전 초기화 버튼
          _actionCard(
            context,
            icon: Icons.cleaning_services_rounded,
            iconColor: scheme.error,
            title: '완전 초기화 + 재배포',
            subtitle:
                '레거시 프로세스/파일 전부 삭제 → 현재 파일 초기화 → 재배포',
            onTap: _busy ? null : _cleanAll,
            destructive: true,
          ),
          const SizedBox(height: 8),

          // 재배포 버튼
          _actionCard(
            context,
            icon: Icons.refresh_rounded,
            iconColor: scheme.primary,
            title: '사이드카 재배포',
            subtitle: '현재 프로세스 중지 → 최신 파일 배포 → 재시작',
            onTap: _busy ? null : _redeploy,
            destructive: false,
          ),

          // ── 실행 로그 ──
          if (_steps.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionHeader(context, Icons.terminal_rounded, '실행 로그'),
            const SizedBox(height: 4),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final step in _steps) _buildStepRow(context, step),
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── 단계별 로그 Row ──
  Widget _buildStepRow(BuildContext context, _StepLog step) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final (IconData icon, Color color) = switch (step.status) {
      _StepStatus.pending => (Icons.circle_outlined, scheme.onSurfaceVariant),
      _StepStatus.running => (Icons.sync_rounded, scheme.primary),
      _StepStatus.ok => (Icons.check_circle_rounded, Colors.green),
      _StepStatus.warn => (Icons.warning_amber_rounded, Colors.orange),
      _StepStatus.fail => (Icons.error_rounded, scheme.error),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              step.status == _StepStatus.running
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color,
                      ),
                    )
                  : Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(
                step.label,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
          if (step.detail != null && step.detail!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text(
                step.detail!,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── 섹션 헤더 ──
  Widget _sectionHeader(BuildContext context, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  // ── 액션 카드 ──
  Widget _actionCard(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
    required bool destructive,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: onTap == null
                      ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
                      : iconColor,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: onTap == null
                              ? scheme.onSurface.withValues(alpha: 0.4)
                              : (destructive
                                  ? scheme.error
                                  : scheme.onSurface),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: onTap == null ? 0.4 : 0.8,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant.withValues(
                    alpha: onTap == null ? 0.3 : 0.6,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 실행 로그 데이터 ──

enum _StepStatus { pending, running, ok, warn, fail }

class _StepLog {
  const _StepLog({
    required this.label,
    required this.status,
    this.detail,
  });
  final String label;
  final _StepStatus status;
  final String? detail;
}
