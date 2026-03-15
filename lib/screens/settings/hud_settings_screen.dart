import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/hud/hud.dart';
import '../../services/device_action_service.dart';
import '../../services/hud_feature_settings_service.dart';
import '../../services/sidecar_service.dart';
import '../../services/ssh_service.dart';
import 'settings_subpage_components.dart';

class HudSettingsScreen extends StatefulWidget {
  const HudSettingsScreen({super.key});

  @override
  State<HudSettingsScreen> createState() => _HudSettingsScreenState();
}

class _HudSettingsScreenState extends State<HudSettingsScreen> {
  final SidecarService _sidecar = SidecarService.shared;
  final DeviceActionService _actionService = DeviceActionService();
  final ScrollController _terminalScrollController = ScrollController();
  static const Duration _installHudBootstrapTimeout = Duration(seconds: 8);
  bool _busy = false;
  final List<_StepLog> _steps = <_StepLog>[];
  final List<String> _terminalLines = <String>[];

  SSHService get _ssh => Provider.of<SSHService>(context, listen: false);
  HudFeatureSettingsService get _featureSettings =>
      Provider.of<HudFeatureSettingsService>(context, listen: false);
  SharedRuntimeManager get _runtime =>
      Provider.of<SharedRuntimeManager>(context, listen: false);

  @override
  void dispose() {
    _terminalScrollController.dispose();
    super.dispose();
  }

  Future<void> _setFeatureEnabled(bool enabled) async {
    if (_busy) return;
    final ssh = _ssh;
    setState(() {
      _busy = true;
      _steps.clear();
    });
    _clearTerminal();
    _appendTerminal(
      'FEATURE',
      'HUD/Stock 기능을 ${enabled ? '활성화' : '비활성화'}합니다.',
    );
    try {
      _addStep('설정 저장', status: _StepStatus.running);
      await _featureSettings.setEnabled(enabled);
      _updateLastStep(
        status: _StepStatus.ok,
        detail: 'enabled=${enabled ? 1 : 0}',
      );

      _addStep('앱 런타임 동기화', status: _StepStatus.running);
      await _runtime.resetRuntime(
        clearCachedSnapshots: true,
        releaseHostSession: true,
      );
      if (enabled && ssh.isConnected) {
        unawaited(_runtime.prewarm());
        _updateLastStep(
          status: _StepStatus.ok,
          detail: '활성화됨 · Home HUD는 백그라운드에서 준비됩니다.',
        );
      } else {
        _updateLastStep(
          status: _StepStatus.ok,
          detail: enabled
              ? '활성화됨 · 기기 연결 후 Home HUD가 준비됩니다.'
              : '비활성화됨 · Home HUD/Stock 런타임을 정리했습니다.',
        );
      }

      if (!enabled && ssh.isConnected) {
        _addStep('사이드카 중지', status: _StepStatus.running);
        try {
          final stopOut = await _sidecar.stop(ssh);
          _appendTerminal('STOP', stopOut);
          _updateLastStep(
            status: _StepStatus.ok,
            detail: _summarizeOutput(stopOut),
          );
        } catch (e) {
          _appendTerminal('STOP', '$e');
          _updateLastStep(
            status: _StepStatus.warn,
            detail: '중지 실패 또는 이미 종료됨',
          );
        }
      }

      _showSnack(
        enabled ? 'HUD/Stock 기능을 활성화했습니다.' : 'HUD/Stock 기능을 비활성화했습니다.',
      );
    } catch (e) {
      _appendTerminal('FEATURE_FAIL', '$e');
      _updateLastStep(status: _StepStatus.fail, detail: '$e');
      _showSnack('설정 변경 실패: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _installSidecar() async {
    if (_busy) return;
    final ssh = _ssh;
    if (!ssh.isConnected) {
      _showSnack('SSH 연결이 되어있지 않습니다.', isError: true);
      return;
    }

    final confirmed = await _confirm(
      title: 'Stock 주행모드 설치',
      message: '디바이스에 sidecar를 배포하고 시작한 뒤 상태를 검증합니다.\n\n'
          '설치 완료 후 안정적인 반영을 위해 openpilot 기기 재부팅이 필요합니다.\n'
          '마지막 단계에서 재부팅 여부를 다시 확인합니다.',
      confirmText: '설치',
    );
    if (!confirmed) return;

    setState(() {
      _busy = true;
      _steps.clear();
    });
    _clearTerminal();

    try {
      _appendTerminal('INSTALL', 'Stock 주행모드 설치를 시작합니다.');

      _addStep('기존 상태 확인', status: _StepStatus.running);
      try {
        final before = await _sidecar.status(ssh);
        _appendTerminal('STATUS_BEFORE', before);
        _updateLastStep(
          status: _StepStatus.ok,
          detail: _summarizeOutput(before),
        );
      } catch (e) {
        _appendTerminal('STATUS_BEFORE', '$e');
        _updateLastStep(
          status: _StepStatus.warn,
          detail: '사전 상태 조회 실패',
        );
      }

      _addStep('앱 런타임 정리', status: _StepStatus.running);
      await _runtime.resetRuntime(
        clearCachedSnapshots: true,
        releaseHostSession: true,
      );
      _updateLastStep(
        status: _StepStatus.ok,
        detail: '기존 Home HUD/Stock 세션과 캐시를 정리했습니다.',
      );

      _addStep('기존 사이드카 중지', status: _StepStatus.running);
      try {
        final stopOut = await _sidecar.stop(ssh);
        _appendTerminal('STOP_BEFORE_INSTALL', stopOut);
        _updateLastStep(
          status: _StepStatus.ok,
          detail: _summarizeOutput(stopOut),
        );
      } catch (e) {
        _appendTerminal('STOP_BEFORE_INSTALL', '$e');
        _updateLastStep(
          status: _StepStatus.warn,
          detail: '중지 실패 또는 이미 종료됨',
        );
      }

      _addStep('최신 파일 배포', status: _StepStatus.running);
      final deployOut = await _sidecar.deploy(ssh);
      _appendTerminal('DEPLOY', deployOut);
      _updateLastStep(
        status: _StepStatus.ok,
        detail: deployOut.trim(),
      );

      _addStep('사이드카 시작', status: _StepStatus.running);
      final startOut = await _sidecar.start(
        ssh,
        profile: SidecarService.hudBootstrapProfile,
      );
      _appendTerminal('START', startOut);
      _updateLastStep(
        status: _StepStatus.ok,
        detail: _summarizeOutput(startOut),
      );

      _addStep('상태 검증', status: _StepStatus.running);
      final verify = await Future.wait<String>([
        _sidecar.status(ssh),
        _sidecar.criticalProcStatus(ssh),
      ]);
      _appendTerminal('STATUS_AFTER', verify[0]);
      _appendTerminal('CRITICAL_PROCS', verify[1]);
      _updateLastStep(
        status: _StepStatus.ok,
        detail: _summarizeOutput(verify[0]),
      );

      final shouldPrimeDriveRuntime =
          _featureSettings.enabled && _supportsDriveRuntime(verify[1]);
      if (shouldPrimeDriveRuntime) {
        _addStep('주행 그래픽 예열', status: _StepStatus.running);
        final driveStartOut = await _sidecar.start(
          ssh,
          profile: SidecarService.driveRuntimeProfile,
        );
        _appendTerminal('DRIVE_PREWARM', driveStartOut);
        _updateLastStep(
          status: _StepStatus.ok,
          detail: 'p2 런타임을 미리 준비했습니다.',
        );
      }

      _addStep('새 런타임 재바인드 준비', status: _StepStatus.running);
      await _runtime.resetRuntime(
        clearCachedSnapshots: true,
        releaseHostSession: true,
      );
      _updateLastStep(
        status: _StepStatus.ok,
        detail: '설치된 sidecar 기준으로 새 HUD 세션을 준비합니다.',
      );

      if (_featureSettings.enabled) {
        _addStep('Home HUD 재연결', status: _StepStatus.running);
        await _runtime.prewarm();
        final host = (ssh.connectedIp ?? ssh.targetIp ?? '').trim();
        final snapshot = await _waitForMeaningfulHudSnapshot(
          host: host,
          timeout: _installHudBootstrapTimeout,
        );
        if (snapshot != null) {
          final speedText = snapshot.vehicle.speedClusterKph == null
              ? '--'
              : '${snapshot.vehicle.speedClusterKph!.round()}';
          _appendTerminal(
            'HUD_READY',
            'transport=${snapshot.source.transport} speed=$speedText '
                'cpu=${snapshot.device.cpuTempAvgC?.toStringAsFixed(0) ?? "--"} '
                'mem=${snapshot.device.memUsagePct?.toStringAsFixed(0) ?? "--"} '
                'volt=${snapshot.device.voltV?.toStringAsFixed(1) ?? "--"}',
          );
          _updateLastStep(
            status: _StepStatus.ok,
            detail: '첫 HUD 값이 확인되었습니다.',
          );
        } else {
          _appendTerminal(
            'HUD_READY',
            '첫 HUD 값 확인 지연: ${_installHudBootstrapTimeout.inSeconds}s timeout',
          );
          _updateLastStep(
            status: _StepStatus.warn,
            detail: '설치는 완료됐지만 첫 HUD 값 확인이 지연되고 있습니다.',
          );
        }
      } else {
        _addStep('기능 비활성 상태 유지', status: _StepStatus.running);
        _updateLastStep(
          status: _StepStatus.ok,
          detail: '기능이 꺼져 있어 런타임은 정지 상태로 유지합니다.',
        );
      }

      await _handlePostInstallReboot();
    } catch (e) {
      _appendTerminal('INSTALL_FAIL', '$e');
      _updateLastStep(status: _StepStatus.fail, detail: '$e');
      _showSnack('설치 실패: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _deleteSidecar() async {
    if (_busy) return;
    final ssh = _ssh;
    if (!ssh.isConnected) {
      _showSnack('SSH 연결이 되어있지 않습니다.', isError: true);
      return;
    }

    final confirmed = await _confirm(
      title: 'Stock 주행모드 삭제',
      message: '디바이스에서 sidecar 파일과 현재 실행 흔적을 제거합니다.\n\n'
          'openpilot 전체 재부팅은 수행하지 않습니다.',
      confirmText: '삭제',
    );
    if (!confirmed) return;

    setState(() {
      _busy = true;
      _steps.clear();
    });
    _clearTerminal();

    try {
      _appendTerminal('DELETE', 'Stock 주행모드 삭제를 시작합니다.');

      _addStep('사이드카 중지', status: _StepStatus.running);
      try {
        final stopOut = await _sidecar.stop(ssh);
        _appendTerminal('STOP', stopOut);
        _updateLastStep(
          status: _StepStatus.ok,
          detail: _summarizeOutput(stopOut),
        );
      } catch (e) {
        _appendTerminal('STOP', '$e');
        _updateLastStep(
          status: _StepStatus.warn,
          detail: '중지 실패 또는 이미 종료됨',
        );
      }

      _addStep('파일/흔적 삭제', status: _StepStatus.running);
      final resetOut = await _sidecar.resetForTesting(
        ssh,
        removeManagerRegistration: true,
        skipStop: true,
      );
      _appendTerminal('RESET', resetOut);
      _updateLastStep(
        status: _StepStatus.ok,
        detail: _summarizeOutput(resetOut),
      );

      _addStep('앱 런타임 정리', status: _StepStatus.running);
      await _runtime.resetRuntime(
        clearCachedSnapshots: true,
        releaseHostSession: true,
      );
      _updateLastStep(
        status: _StepStatus.ok,
        detail: 'Home HUD/Stock 캐시를 정리했습니다.',
      );

      if (_featureSettings.enabled) {
        _addStep('기능 상태 안내', status: _StepStatus.running);
        _updateLastStep(
          status: _StepStatus.warn,
          detail: '기능은 켜져 있습니다. 재사용하려면 다시 설치가 필요합니다.',
        );
      }

      _addStep('삭제 후 상태 확인', status: _StepStatus.running);
      try {
        final after = await _sidecar.status(ssh);
        _appendTerminal('STATUS_AFTER_DELETE', after);
        _updateLastStep(
          status: _StepStatus.ok,
          detail: _summarizeOutput(after),
        );
      } catch (e) {
        _appendTerminal('STATUS_AFTER_DELETE', '$e');
        _updateLastStep(
          status: _StepStatus.warn,
          detail: '삭제 후 상태 조회 실패',
        );
      }

      _showSnack('Stock 주행모드를 삭제했습니다.');
    } catch (e) {
      _appendTerminal('DELETE_FAIL', '$e');
      _updateLastStep(status: _StepStatus.fail, detail: '$e');
      _showSnack('삭제 실패: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _clearTerminal() {
    if (!mounted) return;
    setState(() => _terminalLines.clear());
  }

  void _appendTerminal(String section, String output) {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
    final normalized = output.trim().isEmpty ? '(출력 없음)' : output.trim();
    if (!mounted) return;
    setState(() {
      _terminalLines.add('[$stamp] $section');
      _terminalLines.add(normalized);
      _terminalLines.add('');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_terminalScrollController.hasClients) return;
      _terminalScrollController.animateTo(
        _terminalScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  String _summarizeOutput(String output) {
    final lines = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return '(출력 없음)';
    final picked = lines
        .where(
          (line) =>
              line.startsWith('SIDECAR_') ||
              line.startsWith('running=') ||
              line.startsWith('listening=') ||
              line.startsWith('port_') ||
              line.startsWith('base=') ||
              line.startsWith('remote_revision='),
        )
        .toList(growable: false);
    final source =
        picked.isEmpty ? lines.take(3).toList() : picked.take(4).toList();
    return source.join(' | ');
  }

  bool _supportsDriveRuntime(String raw) {
    final pairs = <String, String>{};
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final idx = trimmed.indexOf('=');
      if (idx <= 0) continue;
      pairs[trimmed.substring(0, idx).trim()] =
          trimmed.substring(idx + 1).trim();
    }
    bool up(String name) => (pairs[name] ?? '').trim().startsWith('up:');
    final hasControlCore =
        up('selfdrived') && (up('controlsd') || up('plannerd'));
    final hasVisionCore =
        up('stream_encoderd') && up('modeld') && up('camerad');
    final hasRadarCore = up('radard');
    return hasControlCore && hasVisionCore && hasRadarCore;
  }

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
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: isError ? 5 : 3),
      ),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmText,
    String cancelText = '취소',
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) {
            final scheme = Theme.of(ctx).colorScheme;
            return AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(
                child: Text(message, style: const TextStyle(height: 1.45)),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(cancelText),
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

  Future<void> _handlePostInstallReboot() async {
    _addStep('재부팅 안내', status: _StepStatus.running);
    _appendTerminal(
      'REBOOT_NOTICE',
      '설치가 완료되었습니다. 안정적인 반영을 위해 openpilot 기기 재부팅이 필요합니다.',
    );

    final confirmed = await _confirm(
      title: '재부팅 필요',
      message: 'Stock 주행모드 설치가 완료되었습니다.\n\n'
          '변경사항을 안정적으로 반영하려면 openpilot 기기를 지금 재부팅하는 것을 권장합니다.\n'
          '지금 재부팅하시겠습니까?',
      confirmText: '재부팅',
      cancelText: '나중에',
    );

    if (!confirmed) {
      _appendTerminal(
        'REBOOT_SKIP',
        '사용자가 재부팅을 보류했습니다. 다음 사용 전 openpilot 기기 재부팅이 필요합니다.',
      );
      _updateLastStep(
        status: _StepStatus.warn,
        detail: '설치는 완료됨 · 다음 사용 전 기기 재부팅이 필요합니다.',
      );
      _showSnack('설치는 완료되었습니다. 사용 전 기기 재부팅이 필요합니다.');
      return;
    }

    _updateLastStep(status: _StepStatus.ok, detail: '사용자가 재부팅을 확인했습니다.');
    _addStep('기기 재부팅', status: _StepStatus.running);

    try {
      final result =
          await _actionService.runAction(_ssh, DeviceActionType.reboot);
      final output =
          result.output.trim().isEmpty ? result.command : result.output;
      _appendTerminal('REBOOT', output);
      if (result.ok) {
        _updateLastStep(
          status: _StepStatus.ok,
          detail: '재부팅 명령을 전송했습니다. 기기 연결이 잠시 끊어질 수 있습니다.',
        );
        _showSnack('재부팅 명령을 전송했습니다.');
      } else {
        _updateLastStep(
          status: _StepStatus.fail,
          detail: '재부팅 명령 실패 (code: ${result.exitCode})',
        );
        _showSnack(
          '설치는 완료됐지만 재부팅 명령 전송에 실패했습니다.',
          isError: true,
        );
      }
    } catch (e) {
      _appendTerminal('REBOOT_FAIL', '$e');
      _updateLastStep(
        status: _StepStatus.fail,
        detail: '재부팅 명령 전송 실패: $e',
      );
      _showSnack(
        '설치는 완료됐지만 재부팅 명령 전송에 실패했습니다.',
        isError: true,
      );
    }
  }

  Future<OriginalHudSnapshot?> _waitForMeaningfulHudSnapshot({
    required String host,
    required Duration timeout,
  }) async {
    final normalizedHost = host.trim();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final snapshot = _runtime.state.snapshot;
      if (_isMeaningfulHudSnapshot(snapshot, expectedHost: normalizedHost)) {
        return snapshot;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final lastSnapshot = _runtime.state.snapshot;
    if (_isMeaningfulHudSnapshot(lastSnapshot, expectedHost: normalizedHost)) {
      return lastSnapshot;
    }
    return null;
  }

  bool _isMeaningfulHudSnapshot(
    OriginalHudSnapshot snapshot, {
    required String expectedHost,
  }) {
    if (snapshot.tsMonoMs <= 0 || snapshot.meta.isPreview) {
      return false;
    }
    final snapshotHost = (snapshot.source.deviceHost ?? '').trim();
    if (expectedHost.isNotEmpty &&
        snapshotHost.isNotEmpty &&
        snapshotHost != expectedHost) {
      return false;
    }
    final normalizedTransport = snapshot.source.transport.trim().toLowerCase();
    if (normalizedTransport != 'sidecar_hud' &&
        normalizedTransport != 'carrot_linkhud') {
      return false;
    }

    final vehicle = snapshot.vehicle;
    final device = snapshot.device;
    final hasVehicleCore = vehicle.speedClusterKph != null ||
        vehicle.setSpeedClusterKph != null ||
        !_isUnknownGear(vehicle.gearText);
    final hasDeviceMetrics = device.cpuTempAvgC != null ||
        device.memUsagePct != null ||
        device.diskUsedPct != null ||
        device.voltV != null;
    final hasAssistSignal = snapshot.tempControl.mode != 'hidden' ||
        snapshot.limits.mode != 'hidden' ||
        snapshot.connectivity.badgeMode.trim().isNotEmpty ||
        snapshot.signals.visualState.trim().isNotEmpty;
    return hasVehicleCore || hasDeviceMetrics || hasAssistSignal;
  }

  bool _isUnknownGear(String value) {
    final normalized = value.trim().toUpperCase();
    return normalized.isEmpty || normalized == 'U' || normalized == 'X';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Consumer<HudFeatureSettingsService>(
      builder: (context, featureSettings, _) {
        final enabled = featureSettings.enabled;
        return SettingsSubpageScaffold(
          title: 'HUD',
          children: [
            SettingsSection(
              title: '설정',
              showTopDivider: false,
              bottomSpacing: 20,
              child: SettingsItemGroup(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('활성화'),
                    trailing: Switch.adaptive(
                      value: enabled,
                      onChanged: _busy ? null : _setFeatureEnabled,
                    ),
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: 'Stock 주행모드',
              bottomSpacing: 20,
              child: SettingsItemGroup(
                children: [
                  SettingsActionRow(
                    title: '설치',
                    onTap: _busy ? null : _installSidecar,
                  ),
                  SettingsActionRow(
                    title: '삭제',
                    onTap: _busy ? null : _deleteSidecar,
                    destructive: true,
                  ),
                ],
              ),
            ),
            if (_steps.isNotEmpty)
              SettingsSection(
                title: '작업 요약',
                bottomSpacing: 20,
                child: SettingsItemGroup(
                  children: [
                    for (final step in _steps) _buildStepRow(context, step),
                  ],
                ),
              ),
            if (_terminalLines.isNotEmpty)
              SettingsSection(
                title: '터미널 로그',
                bottomSpacing: 20,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.35),
                    ),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 340),
                    child: Scrollbar(
                      controller: _terminalScrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _terminalScrollController,
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          _terminalLines.join('\n'),
                          style: textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            height: 1.35,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

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

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: step.status == _StepStatus.running
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: color,
              ),
            )
          : Icon(icon, size: 18, color: color),
      title: Text(
        step.label,
        style: textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
      subtitle: step.detail != null && step.detail!.isNotEmpty
          ? Text(
              step.detail!,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            )
          : null,
      minVerticalPadding: 6,
    );
  }
}

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
