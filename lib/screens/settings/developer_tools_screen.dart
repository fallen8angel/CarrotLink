import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../features/yolo/yolo.dart';
import '../../services/developer_mode_service.dart';
import '../../services/diagnostics_service.dart';
import '../../services/sidecar_service.dart';
import '../../services/ssh_service.dart';
import '../../widgets/custom_toast.dart';
import 'settings_subpage_components.dart';

class DeveloperToolsScreen extends StatefulWidget {
  const DeveloperToolsScreen({super.key});

  @override
  State<DeveloperToolsScreen> createState() => _DeveloperToolsScreenState();
}

class _DeveloperToolsScreenState extends State<DeveloperToolsScreen> {
  final SidecarService _sidecarService = SidecarService.shared;

  bool _actionRunning = false;
  bool _yoloBusy = false;
  String? _localRevision;
  String? _remoteRevision;
  DateTime? _lastCheckedAt;
  YoloDebugSettings _yoloSettings = YoloDebugSettings.empty;
  YoloRuntimeStatusSnapshot _yoloRuntimeStatus =
      const YoloRuntimeStatusSnapshot(
    config: <String, dynamic>{},
    state: <String, dynamic>{},
    updatedAt: null,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_loadYoloSettings());
    unawaited(_loadYoloRuntimeStatus());
  }

  SSHService get _ssh => context.read<SSHService>();
  DiagnosticsService get _diag => DiagnosticsService.instance;

  void _toast(String message, {bool isError = false}) {
    CustomToast.show(context, message, isError: isError);
  }

  Future<void> _showTextDialog(String title, String content) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              content.trim().isEmpty ? '-' : content.trim(),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
              ),
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmAction({
    required String title,
    required String message,
    String confirmText = '실행',
  }) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _runAction(
    String label,
    Future<void> Function(SSHService ssh) action,
  ) async {
    if (_actionRunning) return;
    if (!_ssh.isConnected) {
      _toast('SSH 연결 안됨', isError: true);
      return;
    }
    setState(() => _actionRunning = true);
    try {
      await action(_ssh);
    } catch (e) {
      _diag.error('developer_tools', '$label failed: $e');
      if (mounted) {
        _toast('$label 실패: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _actionRunning = false);
      }
    }
  }

  Future<void> _refreshRevisionStatus() async {
    await _runAction('리비전 확인', (ssh) async {
      final local = await _sidecarService.localRevision();
      final remote = await _sidecarService.remoteRevision(ssh);
      _diag.info(
        'developer_tools',
        'sidecar revision local=${local.substring(0, 8)} remote=${remote ?? '-'}',
      );
      if (!mounted) return;
      setState(() {
        _localRevision = local;
        _remoteRevision = remote;
        _lastCheckedAt = DateTime.now();
      });
      _toast('리비전 확인 완료');
    });
  }

  Future<void> _showHealthSummary() async {
    await _runAction('헬스 요약', (ssh) async {
      final result = await ssh.executeCommandResult(
        'if command -v curl >/dev/null 2>&1; then '
        'curl -fsS --max-time 1 http://127.0.0.1:${SidecarService.defaultPort}/health 2>/dev/null || true; '
        'fi',
        timeout: const Duration(seconds: 6),
      );
      final raw = result.output.trim();
      String content;
      if (raw.isEmpty) {
        content = 'health 응답이 없습니다.';
      } else {
        try {
          final decoded = jsonDecode(raw);
          content = const JsonEncoder.withIndent('  ').convert(decoded);
        } catch (_) {
          content = raw;
        }
      }
      _diag.info('developer_tools', 'health inspected');
      await _showTextDialog('사이드카 헬스', content);
    });
  }

  Future<void> _showLogTail() async {
    await _runAction('로그 tail', (ssh) async {
      final text = await _sidecarService.tailLog(ssh, lines: 50);
      _diag.info('developer_tools', 'tail log inspected');
      await _showTextDialog('사이드카 로그 tail(50)', text);
    });
  }

  Future<void> _redeploy() async {
    await _runAction('재배포', (ssh) async {
      await _sidecarService.deploy(ssh);
      final local = await _sidecarService.localRevision();
      final remote = await _sidecarService.remoteRevision(ssh);
      _diag.info(
        'developer_tools',
        'redeploy done local=${local.substring(0, 8)} remote=${remote ?? '-'}',
      );
      if (!mounted) return;
      setState(() {
        _localRevision = local;
        _remoteRevision = remote;
        _lastCheckedAt = DateTime.now();
      });
      _toast('재배포 완료');
    });
  }

  Future<void> _legacyMigration() async {
    final confirmed = await _confirmAction(
      title: '레거시 정리 + 재배포',
      message:
          '예전 legacy sidecar/hud 흔적을 정리한 뒤 최신 sidecar를 다시 배포하고 시작합니다.\n계속할까요?',
      confirmText: '정리+재배포',
    );
    if (!confirmed) return;

    await _runAction('레거시 정리+재배포', (ssh) async {
      await _sidecarService.cleanupLegacyInstall(ssh, force: true);
      await _sidecarService.deploy(ssh);
      await _sidecarService.start(ssh);
      final local = await _sidecarService.localRevision();
      final remote = await _sidecarService.remoteRevision(ssh);
      _diag.info(
        'developer_tools',
        'legacy cleanup and redeploy done',
      );
      if (!mounted) return;
      setState(() {
        _localRevision = local;
        _remoteRevision = remote;
        _lastCheckedAt = DateTime.now();
      });
      _toast('레거시 정리 + 재배포 완료');
    });
  }

  Future<void> _restartSidecar() async {
    await _runAction('사이드카 재시작', (ssh) async {
      await _sidecarService.stop(ssh);
      await _sidecarService.start(ssh);
      _diag.info('developer_tools', 'sidecar restarted');
      _toast('사이드카 재시작 완료');
    });
  }

  Future<void> _resetForTesting() async {
    final confirmed = await _confirmAction(
      title: '사이드카 테스트 초기화',
      message: '사이드카 파일/로그를 삭제하고 프로세스 등록도 제거합니다.\n완전 초기 상태 테스트용입니다. 계속할까요?',
      confirmText: '초기화',
    );
    if (!confirmed) return;

    await _runAction('사이드카 초기화', (ssh) async {
      await _sidecarService.resetForTesting(
        ssh,
        removeManagerRegistration: true,
      );
      _diag.warn('developer_tools', 'sidecar reset for testing');
      if (!mounted) return;
      setState(() {
        _remoteRevision = null;
        _lastCheckedAt = DateTime.now();
      });
      _toast('사이드카 초기화 완료');
    });
  }

  Future<void> _loadYoloSettings() async {
    try {
      final settings = await YoloDebugSettingsStore.load();
      if (!mounted) {
        _yoloSettings = settings;
        return;
      }
      setState(() => _yoloSettings = settings);
    } catch (e) {
      _diag.error('developer_tools', 'load yolo settings failed: $e');
    }
  }

  Future<void> _updateYoloSettings(YoloDebugSettings next) async {
    if (_yoloBusy) return;
    final previous = _yoloSettings;
    setState(() {
      _yoloBusy = true;
      _yoloSettings = next;
    });
    try {
      final saved = await YoloDebugSettingsStore.save(next);
      if (mounted) {
        setState(() => _yoloSettings = saved);
      } else {
        _yoloSettings = saved;
      }
      _diag.info(
        'developer_tools',
        'yolo settings updated enabled=${saved.enabled} backend=${saved.runtimeBackend.wireValue} model=${saved.modelVariant.wireValue} boxes=${saved.showBoxes}',
      );
    } catch (e) {
      _diag.error('developer_tools', 'save yolo settings failed: $e');
      if (mounted) {
        setState(() => _yoloSettings = previous);
        _toast('YOLO 설정 저장 실패: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _yoloBusy = false);
      } else {
        _yoloBusy = false;
      }
    }
  }

  Future<void> _selectYoloRuntimeBackend() async {
    if (_yoloBusy) return;
    final selected = await showModalBottomSheet<YoloRuntimeBackend>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final backend in YoloRuntimeBackend.selectableValues)
                ListTile(
                  title: Text(backend.label),
                  trailing: backend == _yoloSettings.runtimeBackend
                      ? Icon(
                          Icons.check_rounded,
                          color: scheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.of(ctx).pop(backend),
                ),
            ],
          ),
        );
      },
    );
    if (selected == null || selected == _yoloSettings.runtimeBackend) {
      return;
    }
    await _updateYoloSettings(
      _yoloSettings.copyWith(runtimeBackend: selected),
    );
  }

  Future<void> _selectYoloModelVariant() async {
    if (_yoloBusy) return;
    final selectorSections = buildYoloModelSelectorSections(
      backend: _yoloSettings.runtimeBackend,
    );
    final selected = await showModalBottomSheet<YoloModelVariant>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final entry in selectorSections.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(
                    entry.key,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                for (final choice in entry.value)
                  Opacity(
                    opacity: choice.enabled ? 1 : 0.5,
                    child: ListTile(
                      enabled: choice.enabled,
                      title: Text(choice.title),
                      subtitle: Text(choice.subtitle),
                      trailing: choice.variant == _yoloSettings.modelVariant
                          ? Icon(
                              Icons.check_rounded,
                              color: scheme.primary,
                            )
                          : null,
                      onTap: !choice.enabled || choice.variant == null
                          ? null
                          : () => Navigator.of(ctx).pop(choice.variant),
                    ),
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (selected == null || selected == _yoloSettings.modelVariant) {
      return;
    }
    await _updateYoloSettings(
      _yoloSettings.copyWith(modelVariant: selected),
    );
  }

  Future<void> _loadYoloRuntimeStatus() async {
    try {
      final snapshot = await YoloRuntimeStatusStore.load();
      if (!mounted) {
        _yoloRuntimeStatus = snapshot;
        return;
      }
      setState(() => _yoloRuntimeStatus = snapshot);
    } catch (e) {
      _diag.error('developer_tools', 'load yolo runtime status failed: $e');
    }
  }

  String _yoloValue(String key) {
    final stateValue = _yoloRuntimeStatus.state[key];
    if (stateValue != null && stateValue.toString().trim().isNotEmpty) {
      return stateValue.toString();
    }
    final configValue = _yoloRuntimeStatus.config[key];
    if (configValue != null && configValue.toString().trim().isNotEmpty) {
      return configValue.toString();
    }
    return '-';
  }

  String _yoloCountSummary() {
    final seen = _yoloValue('framesSeen');
    final sampled = _yoloValue('framesSampled');
    final skipped = _yoloValue('framesSkipped');
    return '$seen / $sampled / $skipped';
  }

  String _yoloCopySummary() {
    final payload = <String, dynamic>{
      'config': _yoloRuntimeStatus.config,
      'state': _yoloRuntimeStatus.state,
      'updated': _yoloRuntimeStatus.updatedAt?.toLocal().toIso8601String(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<void> _copyYoloRuntimeStatus() async {
    await Clipboard.setData(
      ClipboardData(text: _yoloCopySummary()),
    );
    if (!mounted) return;
    _toast('YOLO 상태 복사 완료');
  }

  Future<void> _runYoloImageDebug() async {
    if (_yoloBusy) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: false,
    );
    final path = result?.files.single.path?.trim();
    if (path == null || path.isEmpty) {
      return;
    }

    setState(() => _yoloBusy = true);
    try {
      final snapshot = await YoloOfflineDebugRunner.runImageFile(
        path: path,
        settings: _yoloSettings,
      );
      if (!mounted) {
        _yoloRuntimeStatus = snapshot;
        return;
      }
      setState(() => _yoloRuntimeStatus = snapshot);
      _toast('YOLO 이미지 테스트 완료');
    } catch (e) {
      _diag.error('developer_tools', 'offline yolo image debug failed: $e');
      if (mounted) {
        _toast('YOLO 이미지 테스트 실패: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _yoloBusy = false);
      } else {
        _yoloBusy = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final developerMode = context.watch<DeveloperModeService>();
    final ssh = context.watch<SSHService>();
    final connectedIp = (ssh.connectedIp ?? ssh.targetIp ?? '-').trim();

    if (!developerMode.enabled) {
      return const SettingsSubpageScaffold(
        title: '개발자 도구',
        children: [
          SettingsSection(
            title: '상태',
            showTopDivider: false,
            child: SettingsStatusNote(text: '개발자 모드가 비활성화되어 있습니다.'),
          ),
        ],
      );
    }

    return SettingsSubpageScaffold(
      title: '개발자 도구',
      children: [
        SettingsSection(
          title: '연결 상태',
          showTopDivider: false,
          child: SettingsItemGroup(
            children: [
              SettingsActionRow(
                title: ssh.isConnected ? 'SSH 연결됨' : 'SSH 연결 안됨',
                value: connectedIp.isEmpty ? '-' : connectedIp,
                trailing: _actionRunning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
            ],
          ),
        ),
        SettingsSection(
          title: '상태 점검',
          child: SettingsItemGroup(
            children: [
              SettingsActionRow(
                title: '사이드카 헬스 보기',
                onTap: _actionRunning ? null : _showHealthSummary,
              ),
              SettingsActionRow(
                title: '사이드카 로그 tail 50',
                onTap: _actionRunning ? null : _showLogTail,
              ),
              SettingsActionRow(
                title: '리비전 확인',
                onTap: _actionRunning ? null : _refreshRevisionStatus,
              ),
              SettingsActionRow(title: 'local', value: _localRevision ?? '-'),
              SettingsActionRow(
                title: 'remote',
                value: _remoteRevision ?? '-',
              ),
              SettingsActionRow(
                title: 'checked',
                value: _lastCheckedAt?.toLocal().toString() ?? '-',
              ),
            ],
          ),
        ),
        SettingsSection(
          title: '유지보수',
          child: SettingsItemGroup(
            children: [
              SettingsActionRow(
                title: '사이드카 재배포',
                onTap: _actionRunning ? null : _redeploy,
              ),
              SettingsActionRow(
                title: '레거시 정리 + 재배포',
                onTap: _actionRunning ? null : _legacyMigration,
              ),
              SettingsActionRow(
                title: '사이드카 재시작',
                onTap: _actionRunning ? null : _restartSidecar,
              ),
              SettingsActionRow(
                title: '사이드카 초기화(테스트)',
                onTap: _actionRunning ? null : _resetForTesting,
                destructive: true,
              ),
            ],
          ),
        ),
        SettingsSection(
          title: 'YOLO',
          child: SettingsItemGroup(
            children: [
              SettingsActionRow(
                title: '백엔드',
                value: _yoloSettings.runtimeBackend.label,
                onTap: _selectYoloRuntimeBackend,
              ),
              SettingsActionRow(
                title: '모델',
                value: _yoloSettings.modelVariant.settingsLabel,
                onTap: _selectYoloModelVariant,
              ),
              SettingsSwitchRow(
                title: 'ExecuTorch',
                value: _yoloSettings.unsafeRuntimeEnabled,
                enabled: !_yoloBusy,
                onChanged: (value) {
                  _updateYoloSettings(
                    _yoloSettings.copyWith(unsafeRuntimeEnabled: value),
                  );
                },
              ),
              SettingsSwitchRow(
                title: '활성화',
                value: _yoloSettings.enabled,
                enabled: !_yoloBusy,
                onChanged: (value) {
                  final next = value
                      ? _yoloSettings.enableMaster()
                      : _yoloSettings.disableAll();
                  _updateYoloSettings(
                    next,
                  );
                },
              ),
              SettingsSwitchRow(
                title: '박스',
                value: _yoloSettings.showBoxes,
                enabled: !_yoloBusy && _yoloSettings.enabled,
                onChanged: (value) {
                  _updateYoloSettings(
                    _yoloSettings.copyWith(showBoxes: value),
                  );
                },
              ),
              SettingsSwitchRow(
                title: '라벨',
                value: _yoloSettings.showLabels,
                enabled: !_yoloBusy && _yoloSettings.enabled,
                onChanged: (value) {
                  _updateYoloSettings(
                    _yoloSettings.copyWith(showLabels: value),
                  );
                },
              ),
              SettingsSwitchRow(
                title: '신호등',
                value: _yoloSettings.showTrafficLights,
                enabled: !_yoloBusy && _yoloSettings.enabled,
                onChanged: (value) {
                  _updateYoloSettings(
                    _yoloSettings.copyWith(showTrafficLights: value),
                  );
                },
              ),
              SettingsSwitchRow(
                title: '통계',
                value: _yoloSettings.showStats,
                enabled: !_yoloBusy && _yoloSettings.enabled,
                onChanged: (value) {
                  _updateYoloSettings(
                    _yoloSettings.copyWith(showStats: value),
                  );
                },
              ),
              SettingsActionRow(
                title: '상태 새로고침',
                onTap: _loadYoloRuntimeStatus,
              ),
              SettingsActionRow(
                title: '이미지 파일 테스트',
                onTap: _yoloBusy ? null : _runYoloImageDebug,
              ),
              SettingsActionRow(
                title: '상태 복사',
                onTap: _copyYoloRuntimeStatus,
              ),
              SettingsActionRow(
                title: 'stage',
                value: _yoloValue('stage'),
              ),
              SettingsActionRow(
                title: 'blocker',
                value: _yoloValue('blocker'),
              ),
              SettingsActionRow(
                title: 'runtimeStage',
                value: _yoloValue('runtimeStage'),
              ),
              SettingsActionRow(
                title: 'runtimeBlocker',
                value: _yoloValue('runtimeBlocker'),
              ),
              SettingsActionRow(
                title: 'reason',
                value: _yoloValue('reason'),
              ),
              SettingsActionRow(
                title: 'backend',
                value: _yoloValue('runtimeBackend'),
              ),
              SettingsActionRow(
                title: 'backendAvailable',
                value: _yoloValue('backendAvailable'),
              ),
              SettingsActionRow(
                title: 'backendPackaging',
                value: _yoloValue('backendPackagingMode'),
              ),
              SettingsActionRow(
                title: 'backendReason',
                value: _yoloValue('backendReason'),
              ),
              SettingsActionRow(
                title: 'backendNativeLibDir',
                value: _yoloValue('backendNativeLibDir'),
              ),
              SettingsActionRow(
                title: 'backendNativeLibs',
                value: _yoloValue('backendNativeLibs'),
              ),
              SettingsActionRow(
                title: 'backendAssetFiles',
                value: _yoloValue('backendAssetFiles'),
              ),
              SettingsActionRow(
                title: 'backendRuntimeDir',
                value: _yoloValue('backendRuntimeDir'),
              ),
              SettingsActionRow(
                title: 'backendEnvReady',
                value: _yoloValue('backendEnvReady'),
              ),
              SettingsActionRow(
                title: 'model',
                value: _yoloValue('modelVariant'),
              ),
              SettingsActionRow(
                title: 'camera',
                value: _yoloValue('camera'),
              ),
              SettingsActionRow(
                title: 'source',
                value:
                    '${_yoloValue('sourceWidth')} x ${_yoloValue('sourceHeight')}',
              ),
              SettingsActionRow(
                title: 'sample',
                value:
                    '${_yoloValue('sampleWidth')} x ${_yoloValue('sampleHeight')} / ${_yoloValue('samplePeriodMs')}ms',
              ),
              SettingsActionRow(
                title: 'inputPath',
                value: _yoloValue('inputPath'),
              ),
              SettingsActionRow(
                title: 'runtimeReady',
                value: _yoloValue('runtimeReady'),
              ),
              SettingsActionRow(
                title: 'pixelPathReady',
                value: _yoloValue('pixelPathReady'),
              ),
              SettingsActionRow(
                title: 'frames',
                value: _yoloCountSummary(),
              ),
              SettingsActionRow(
                title: 'lastFrameId',
                value: _yoloValue('lastFrameId'),
              ),
              SettingsActionRow(
                title: 'lastSkipReason',
                value: _yoloValue('lastSkipReason'),
              ),
              SettingsActionRow(
                title: 'copyRequests',
                value: _yoloValue('copyRequests'),
              ),
              SettingsActionRow(
                title: 'copySuccesses',
                value: _yoloValue('copySuccesses'),
              ),
              SettingsActionRow(
                title: 'copyFailures',
                value: _yoloValue('copyFailures'),
              ),
              SettingsActionRow(
                title: 'copySkippedBusy',
                value: _yoloValue('copySkippedBusy'),
              ),
              SettingsActionRow(
                title: 'copyInFlight',
                value: _yoloValue('copyInFlight'),
              ),
              SettingsActionRow(
                title: 'lastCopyResult',
                value: _yoloValue('lastCopyResult'),
              ),
              SettingsActionRow(
                title: 'inferenceRequests',
                value: _yoloValue('inferenceRequests'),
              ),
              SettingsActionRow(
                title: 'detections',
                value: _yoloValue('parsedDetectionCount'),
              ),
              SettingsActionRow(
                title: 'candidates',
                value: _yoloValue('parsedCandidateCount'),
              ),
              SettingsActionRow(
                title: 'parserStrategy',
                value: _yoloValue('parserStrategy'),
              ),
              SettingsActionRow(
                title: 'parserThreshold',
                value: _yoloValue('parserScoreThreshold'),
              ),
              SettingsActionRow(
                title: 'parserAbove',
                value: _yoloValue('parserAboveThresholdCount'),
              ),
              SettingsActionRow(
                title: 'parserMax',
                value: _yoloValue('parserMaxClassScore'),
              ),
              SettingsActionRow(
                title: 'lastError',
                value: _yoloValue('lastError'),
              ),
              SettingsActionRow(
                title: 'updated',
                value:
                    _yoloRuntimeStatus.updatedAt?.toLocal().toString() ?? '-',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
