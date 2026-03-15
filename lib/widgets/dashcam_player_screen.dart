import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../features/yolo/yolo.dart';
import '../ui/adaptive/window_class.dart';

class DashcamPlayerScreen extends StatefulWidget {
  final File? videoFile;
  final Uri? videoUri;
  final String title;
  final List<File> previewFrames;
  final Duration previewStep;
  final bool useScaffold;
  final Future<void> Function(int startSec, int endSec)? onShareRange;
  final Future<YoloRuntimeStatusSnapshot> Function(Duration position)?
      onRunYoloDebugAtPosition;
  final String? yoloAvailabilityHint;
  final VoidCallback? onClose;

  const DashcamPlayerScreen({
    super.key,
    this.videoFile,
    this.videoUri,
    required this.title,
    required this.previewFrames,
    required this.previewStep,
    this.useScaffold = true,
    this.onShareRange,
    this.onRunYoloDebugAtPosition,
    this.yoloAvailabilityHint,
    this.onClose,
  }) : assert(videoFile != null || videoUri != null);

  @override
  State<DashcamPlayerScreen> createState() => _DashcamPlayerScreenState();
}

class _YoloVerificationBadgeData {
  const _YoloVerificationBadgeData({
    required this.icon,
    required this.accentColor,
    required this.label,
    this.detail,
  });

  final IconData icon;
  final Color accentColor;
  final String label;
  final String? detail;
}

class _DashcamPlayerScreenState extends State<DashcamPlayerScreen> {
  static const Duration _positionPollInterval = Duration(milliseconds: 180);
  static const Duration _controlsAutoHideDelay = Duration(seconds: 4);

  late final VideoPlayerController _controller;
  Timer? _positionTimer;
  Timer? _controlsTimer;
  Timer? _yoloPlaybackTimer;
  VoidCallback? _controllerListener;

  bool _initialized = false;
  bool _isScrubbing = false;
  bool _wasPlayingBeforeScrub = false;
  bool _showControls = true;
  bool _yoloPlaybackEnabled = false;
  bool _yoloPlaybackBusy = false;
  bool _yoloOverlayExpanded = false;
  int _yoloLastRequestedPositionMs = -1;
  int _yoloPlaybackNextTickAtMs = 0;
  String? _yoloLastResolvedFrameToken;
  String? _yoloLastStatusLogSignature;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _scrubSeconds = 0;
  double _playbackSpeed = 1.0;
  String? _initError;
  YoloRuntimeStatusSnapshot? _lastYoloStatus;

  @override
  void initState() {
    super.initState();
    if (widget.videoFile != null) {
      _controller = VideoPlayerController.file(widget.videoFile!);
    } else {
      _controller = VideoPlayerController.networkUrl(widget.videoUri!);
    }
    void listener() => _handleVideoControllerChanged();
    _controllerListener = listener;
    _controller.addListener(listener);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _controlsTimer?.cancel();
    _yoloPlaybackTimer?.cancel();
    final listener = _controllerListener;
    _controllerListener = null;
    if (listener != null) {
      _controller.removeListener(listener);
    }
    if (widget.onRunYoloDebugAtPosition != null) {
      unawaited(_clearYoloPlaybackSession());
    }
    _controller.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      await _controller.setLooping(false);
      if (!mounted) return;
      setState(() {
        _initialized = true;
        _duration = _controller.value.duration;
        _position = _controller.value.position;
      });
      _startPositionTimer();
      _restartControlsAutoHide();
      await _controller.play();
      _syncYoloPlaybackLoop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _initialized = false;
        _initError = '영상을 재생할 수 없습니다.';
      });
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(_positionPollInterval, (_) {
      if (!_initialized || !mounted || _isScrubbing) return;
      final value = _controller.value;
      setState(() {
        _position = value.position;
        _duration = value.duration;
      });
    });
  }

  void _restartControlsAutoHide() {
    _controlsTimer?.cancel();
    if (!_controller.value.isPlaying) return;
    _controlsTimer = Timer(_controlsAutoHideDelay, () {
      if (!mounted || _isScrubbing) return;
      setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _restartControlsAutoHide();
    }
  }

  Future<void> _togglePlayPause() async {
    if (!_initialized) return;
    final wasPlaying = _controller.value.isPlaying;
    if (_controller.value.isPlaying) {
      await _controller.pause();
    } else {
      await _controller.play();
    }
    if (!mounted) return;
    setState(() {
      _position = _controller.value.position;
      _duration = _controller.value.duration;
    });
    _syncYoloPlaybackLoop();
    if (wasPlaying && !_controller.value.isPlaying && _yoloPlaybackEnabled) {
      await _runYoloPlaybackTick(force: true);
    }
    _restartControlsAutoHide();
  }

  Future<void> _seekBySeconds(int delta) async {
    if (!_initialized) return;
    final durationMs = _duration.inMilliseconds;
    final nextMs =
        (_position.inMilliseconds + delta * 1000).clamp(0, durationMs);
    await _controller.seekTo(Duration(milliseconds: nextMs));
    if (!mounted) return;
    setState(() => _position = Duration(milliseconds: nextMs));
    _restartControlsAutoHide();
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    _playbackSpeed = speed;
    await _controller.setPlaybackSpeed(speed);
    if (!mounted) return;
    setState(() {});
    _restartControlsAutoHide();
  }

  void _onScrubStart(double value) {
    if (!_initialized) return;
    _wasPlayingBeforeScrub = _controller.value.isPlaying;
    _isScrubbing = true;
    _scrubSeconds = value;
    unawaited(_controller.pause());
    setState(() {});
  }

  void _onScrubChanged(double value) {
    if (!_initialized) return;
    _scrubSeconds = value;
    setState(() {});
  }

  Future<void> _onScrubEnd(double value) async {
    if (!_initialized) return;
    final target = Duration(milliseconds: (value * 1000).round());
    await _controller.seekTo(target);
    if (_wasPlayingBeforeScrub) {
      await _controller.play();
    }
    if (!mounted) return;
    setState(() {
      _isScrubbing = false;
      _position = target;
    });
    _syncYoloPlaybackLoop();
    if (_yoloPlaybackEnabled) {
      await _runYoloPlaybackTick(force: true);
    }
    _restartControlsAutoHide();
  }

  Future<void> _toggleYoloPlaybackDebug() async {
    if (widget.onRunYoloDebugAtPosition == null) return;
    final nextEnabled = !_yoloPlaybackEnabled;
    setState(() {
      _yoloPlaybackEnabled = nextEnabled;
      if (!nextEnabled) {
        _yoloLastRequestedPositionMs = -1;
        _yoloPlaybackNextTickAtMs = 0;
        _yoloLastResolvedFrameToken = null;
      }
    });
    _syncYoloPlaybackLoop();
    if (nextEnabled) {
      await _runYoloPlaybackTick(force: true);
    } else {
      await _clearYoloPlaybackSession();
    }
  }

  Future<void> _clearYoloPlaybackSession() async {
    try {
      await YoloOfflineDebugRunner.clearVideoPlaybackSession();
    } catch (_) {
      // Best-effort cleanup for developer-only debug playback.
    }
  }

  Duration _yoloPlaybackTickInterval() {
    final snapshot = _lastYoloStatus;
    final value =
        snapshot?.state['samplePeriodMs'] ?? snapshot?.config['samplePeriodMs'];
    final raw = value is num ? value.toInt() : int.tryParse('${value ?? ''}');
    final resolved = (raw ?? 140).clamp(90, 140);
    return Duration(milliseconds: resolved);
  }

  String? _currentPlaybackFrameToken(YoloRuntimeStatusSnapshot? snapshot) {
    final value = snapshot?.state['playbackFrameToken'] ??
        snapshot?.config['playbackFrameToken'];
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty || text == '-') {
      return null;
    }
    return text;
  }

  void _handleVideoControllerChanged() {
    if (!_initialized ||
        !_yoloPlaybackEnabled ||
        widget.onRunYoloDebugAtPosition == null) {
      _yoloPlaybackTimer?.cancel();
      _yoloPlaybackTimer = null;
      return;
    }
    if (_isScrubbing || !_controller.value.isPlaying) {
      _yoloPlaybackTimer?.cancel();
      _yoloPlaybackTimer = null;
      return;
    }
    _scheduleYoloPlaybackTick();
  }

  void _scheduleYoloPlaybackTick({bool force = false}) {
    if (widget.onRunYoloDebugAtPosition == null || !_initialized) return;
    if ((!_yoloPlaybackEnabled || _isScrubbing) && !force) return;
    if (!_controller.value.isPlaying && !force) return;
    if (_yoloPlaybackBusy) return;
    final position = _controller.value.position;
    if (!force && position < const Duration(milliseconds: 550)) {
      return;
    }
    final positionMs = position.inMilliseconds;
    if (!force && _yoloLastRequestedPositionMs == positionMs) {
      return;
    }
    if (_yoloPlaybackTimer != null && !force) {
      return;
    }
    _yoloPlaybackTimer?.cancel();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final delayMs = force ? 0 : math.max(0, _yoloPlaybackNextTickAtMs - nowMs);
    _yoloPlaybackTimer = Timer(Duration(milliseconds: delayMs), () {
      _yoloPlaybackTimer = null;
      unawaited(_runYoloPlaybackTick(force: force));
    });
  }

  void _syncYoloPlaybackLoop() {
    _yoloPlaybackTimer?.cancel();
    _yoloPlaybackTimer = null;
    if (!_yoloPlaybackEnabled || widget.onRunYoloDebugAtPosition == null) {
      return;
    }
    if (!_initialized || !_controller.value.isPlaying || _isScrubbing) {
      return;
    }
    _scheduleYoloPlaybackTick();
  }

  Future<void> _runYoloPlaybackTick({bool force = false}) async {
    if (widget.onRunYoloDebugAtPosition == null || !_initialized) return;
    if (!_yoloPlaybackEnabled && !force) return;
    if (_yoloPlaybackBusy) return;
    if (!_controller.value.isPlaying && !force) return;
    if (_isScrubbing) return;
    final position = _controller.value.position;
    if (!force && position < const Duration(milliseconds: 550)) {
      return;
    }
    final positionMs = position.inMilliseconds;
    if (_yoloLastRequestedPositionMs == positionMs) {
      return;
    }
    _yoloPlaybackBusy = true;
    try {
      final snapshot = await widget.onRunYoloDebugAtPosition!(position);
      _yoloPlaybackNextTickAtMs = DateTime.now().millisecondsSinceEpoch +
          _yoloPlaybackTickInterval().inMilliseconds;
      final frameToken = _currentPlaybackFrameToken(snapshot);
      if (!force &&
          frameToken != null &&
          frameToken == _yoloLastResolvedFrameToken) {
        _yoloLastRequestedPositionMs = positionMs;
        return;
      }
      if (!mounted) {
        _yoloLastRequestedPositionMs = positionMs;
        _yoloLastResolvedFrameToken = frameToken;
        _lastYoloStatus = snapshot;
        _logYoloPlaybackStatus(snapshot, positionMs: positionMs);
        return;
      }
      setState(() {
        _yoloLastRequestedPositionMs = positionMs;
        _yoloLastResolvedFrameToken = frameToken;
        _lastYoloStatus = snapshot;
      });
      _logYoloPlaybackStatus(snapshot, positionMs: positionMs);
    } catch (_) {
      _yoloPlaybackNextTickAtMs = DateTime.now().millisecondsSinceEpoch +
          _yoloPlaybackTickInterval().inMilliseconds;
      if (!mounted) return;
      setState(() {
        _lastYoloStatus = YoloRuntimeStatusSnapshot(
          config: const <String, dynamic>{},
          state: const <String, dynamic>{
            'stage': 'offline_video_frame_debug_failed',
          },
          updatedAt: DateTime.now(),
        );
      });
    } finally {
      _yoloPlaybackBusy = false;
    }
  }

  void _logYoloPlaybackStatus(
    YoloRuntimeStatusSnapshot snapshot, {
    required int positionMs,
  }) {
    final state = snapshot.state;
    final signature = [
      state['stage'],
      state['blocker'],
      state['parsedDetectionCount'],
      state['playbackFrameToken'],
      positionMs,
    ].join('|');
    if (signature == _yoloLastStatusLogSignature) {
      return;
    }
    _yoloLastStatusLogSignature = signature;
    debugPrint(
      '[DashcamPlayer][yolo] '
      'positionMs=$positionMs '
      'stage=${_yoloStatusValue(state, 'stage')} '
      'blocker=${_yoloStatusValue(state, 'blocker')} '
      'detections=${_yoloStatusValue(state, 'parsedDetectionCount')} '
      'token=${_yoloStatusValue(state, 'playbackFrameToken')} '
      'backend=${_yoloStatusValue(state, 'backend')} '
      'model=${_yoloStatusValue(state, 'modelVariant')}',
    );
  }

  String _yoloStatusValue(Map<String, dynamic> state, String key) {
    final value = state[key];
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? '-' : text;
  }

  Future<void> _copyYoloStatusOverlay(
      YoloRuntimeStatusSnapshot? snapshot) async {
    if (snapshot == null) return;
    final payload = <String, dynamic>{
      'config': snapshot.config,
      'state': snapshot.state,
      'updated': snapshot.updatedAt?.toLocal().toIso8601String(),
    };
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(payload)),
    );
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('YOLO 상태를 복사했습니다.')),
    );
  }

  List<YoloDetection> _currentYoloDetections() {
    final snapshot = _lastYoloStatus;
    if (snapshot == null) return const <YoloDetection>[];
    return YoloDetection.listFromPayload(snapshot.state['parsedDetections']);
  }

  int _currentYoloSourceWidth() {
    final snapshot = _lastYoloStatus;
    final value =
        snapshot?.state['sourceWidth'] ?? snapshot?.config['sourceWidth'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  int _currentYoloSourceHeight() {
    final snapshot = _lastYoloStatus;
    final value =
        snapshot?.state['sourceHeight'] ?? snapshot?.config['sourceHeight'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool _currentYoloShowBoxes() {
    final snapshot = _lastYoloStatus;
    final value = snapshot?.state['yoloBoxes'] ?? snapshot?.config['yoloBoxes'];
    return value == true || value?.toString() == 'true';
  }

  bool _currentYoloShowLabels() {
    final snapshot = _lastYoloStatus;
    final value =
        snapshot?.state['yoloLabels'] ?? snapshot?.config['yoloLabels'];
    return value == true || value?.toString() == 'true';
  }

  String _currentYoloMetaValue(
    String stateKey, {
    String? configKey,
  }) {
    final snapshot = _lastYoloStatus;
    final value =
        snapshot?.state[stateKey] ?? snapshot?.config[configKey ?? stateKey];
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? '-' : text;
  }

  bool _currentYoloMetaBool(
    String stateKey, {
    String? configKey,
  }) {
    final snapshot = _lastYoloStatus;
    final value =
        snapshot?.state[stateKey] ?? snapshot?.config[configKey ?? stateKey];
    if (value is bool) return value;
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'true' || text == '1' || text == 'yes';
  }

  int? _currentYoloMetaInt(
    String stateKey, {
    String? configKey,
  }) {
    final snapshot = _lastYoloStatus;
    final value =
        snapshot?.state[stateKey] ?? snapshot?.config[configKey ?? stateKey];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  bool _shouldForceVisiblePlaybackBoxes() {
    final detections = _currentYoloDetections();
    if (detections.isEmpty) return false;
    return !_currentYoloShowBoxes() && !_currentYoloShowLabels();
  }

  String? _yoloBlockerHint(String blocker) {
    final currentModel = YoloModelVariant.fromWireValue(
      _currentYoloMetaValue('modelVariant'),
    );
    final suggestedQnnAsset = _currentYoloMetaValue('suggestedQnnAssetFile');
    switch (blocker) {
      case 'qnn_model_not_lowered':
        final expectedAsset = suggestedQnnAsset != '-'
            ? suggestedQnnAsset
            : currentModel.suggestedQnnVariant?.primaryAssetFileName;
        if (expectedAsset != null && expectedAsset.trim().isNotEmpty) {
          return 'generic 모델이라 route playback QNN 추론을 막은 상태입니다. '
              '$expectedAsset 같은 QNN-lowered 모델이 필요합니다.';
        }
        return 'generic 모델이라 route playback QNN 추론을 막은 상태입니다.';
      case 'unsafe_runtime_disabled':
        return 'unsafe runtime이 꺼져 있어 playback YOLO가 동작하지 않습니다.';
      case 'xnnpack_runtime_not_validated':
        return 'XNNPACK playback runtime은 아직 검증 전이라 막혀 있습니다.';
      case 'model_asset_missing':
        return '선택한 모델 파일을 찾지 못했습니다. 예: ${currentModel.assetFileHint}';
      case 'parser_zero_detections':
        return '이번 프레임에서 검출된 허용 클래스가 없습니다.';
      case 'parser_shape_unsupported':
        return '현재 모델 출력 형식이 parser와 아직 맞지 않습니다.';
      case 'executorch_forward_failed':
        return 'native forward 단계에서 실패했습니다.';
      default:
        return null;
    }
  }

  _YoloVerificationBadgeData? _resolveYoloVerificationBadge() {
    final snapshot = _lastYoloStatus;
    final hasYoloRunner = widget.onRunYoloDebugAtPosition != null;
    final availabilityHint = widget.yoloAvailabilityHint?.trim();
    if (!hasYoloRunner &&
        (availabilityHint == null || availabilityHint.isEmpty)) {
      return null;
    }

    final stage = _currentYoloMetaValue('stage');
    final blocker = _currentYoloMetaValue('blocker');
    final runtimeReady = _currentYoloMetaBool('runtimeReady');
    final pixelPathReady = _currentYoloMetaBool('pixelPathReady');
    final detections = _currentYoloMetaInt('parsedDetectionCount') ?? 0;
    final backendReason = _currentYoloMetaValue('backendReason');
    final lastError = _currentYoloMetaValue('lastError');
    final currentModel =
        YoloModelVariant.fromWireValue(_currentYoloMetaValue('modelVariant'));
    final suggestedQnnAsset = _currentYoloMetaValue('suggestedQnnAssetFile');
    final expectedAsset = suggestedQnnAsset != '-'
        ? suggestedQnnAsset
        : currentModel.primaryAssetFileName;

    if (!hasYoloRunner) {
      return _YoloVerificationBadgeData(
        icon: Icons.block_rounded,
        accentColor: Colors.white70,
        label: 'YOLO playback 불가',
        detail: availabilityHint,
      );
    }

    if (!_yoloPlaybackEnabled && snapshot == null) {
      return _YoloVerificationBadgeData(
        icon: Icons.smart_toy_outlined,
        accentColor: Colors.white70,
        label: 'YOLO 대기',
        detail: availabilityHint?.isNotEmpty == true
            ? availabilityHint
            : '우측 상단 로봇 버튼으로 시작',
      );
    }

    switch (blocker) {
      case 'qnn_model_not_lowered':
        return _YoloVerificationBadgeData(
          icon: Icons.developer_mode_rounded,
          accentColor: Colors.orangeAccent,
          label: 'QNN 변환 필요',
          detail: expectedAsset,
        );
      case 'model_asset_missing':
        return _YoloVerificationBadgeData(
          icon: Icons.folder_off_rounded,
          accentColor: Colors.redAccent,
          label: '모델 파일 없음',
          detail: expectedAsset,
        );
      case 'parser_zero_detections':
        return const _YoloVerificationBadgeData(
          icon: Icons.check_circle_outline_rounded,
          accentColor: Colors.lightGreenAccent,
          label: '실행 확인',
          detail: '추론 완료 · 검출 0개',
        );
      case 'parser_shape_unsupported':
        return _YoloVerificationBadgeData(
          icon: Icons.rule_folder_outlined,
          accentColor: Colors.orangeAccent,
          label: '출력 파서 불일치',
          detail: stage != '-' ? stage : null,
        );
      case 'executorch_forward_failed':
        return _YoloVerificationBadgeData(
          icon: Icons.error_outline_rounded,
          accentColor: Colors.redAccent,
          label: '추론 실패',
          detail: lastError != '-' ? lastError : null,
        );
      case 'executorch_module_load_failed':
        return _YoloVerificationBadgeData(
          icon: Icons.error_outline_rounded,
          accentColor: Colors.redAccent,
          label: '모델 로드 실패',
          detail: lastError != '-' ? lastError : null,
        );
      case 'unsafe_runtime_disabled':
        return const _YoloVerificationBadgeData(
          icon: Icons.pause_circle_outline_rounded,
          accentColor: Colors.orangeAccent,
          label: 'unsafe runtime 꺼짐',
        );
      case 'xnnpack_runtime_not_validated':
        return const _YoloVerificationBadgeData(
          icon: Icons.warning_amber_rounded,
          accentColor: Colors.orangeAccent,
          label: 'XNN 검증 필요',
        );
    }

    if (stage == 'overlay_payload_ready' && runtimeReady && pixelPathReady) {
      return _YoloVerificationBadgeData(
        icon: Icons.verified_rounded,
        accentColor: Colors.greenAccent,
        label: 'QNN 검증 완료',
        detail: 'overlay ready · 검출 $detections개',
      );
    }

    if (stage == 'awaiting_detection_payload' && runtimeReady) {
      return const _YoloVerificationBadgeData(
        icon: Icons.check_circle_outline_rounded,
        accentColor: Colors.lightGreenAccent,
        label: '실행 확인',
        detail: '추론 완료 · 검출 0개',
      );
    }

    if (stage == 'awaiting_model_asset') {
      return _YoloVerificationBadgeData(
        icon: Icons.folder_off_rounded,
        accentColor: Colors.redAccent,
        label: '모델 파일 없음',
        detail: expectedAsset,
      );
    }

    if (stage == 'backend_unavailable' ||
        stage == 'backend_environment_unavailable') {
      return _YoloVerificationBadgeData(
        icon: Icons.memory_rounded,
        accentColor: Colors.redAccent,
        label: 'QNN 런타임 없음',
        detail: backendReason != '-' ? backendReason : null,
      );
    }

    if (stage == 'module_load_failed') {
      return _YoloVerificationBadgeData(
        icon: Icons.error_outline_rounded,
        accentColor: Colors.redAccent,
        label: '모델 로드 실패',
        detail: lastError != '-' ? lastError : null,
      );
    }

    if (stage == 'inference_failed' || stage == 'preprocess_failed') {
      return _YoloVerificationBadgeData(
        icon: Icons.error_outline_rounded,
        accentColor: Colors.redAccent,
        label: '추론 실패',
        detail: lastError != '-' ? lastError : null,
      );
    }

    if (runtimeReady) {
      return _YoloVerificationBadgeData(
        icon: Icons.hourglass_top_rounded,
        accentColor: Colors.lightBlueAccent,
        label: '검증 진행 중',
        detail: stage != '-' ? stage : currentModel.label,
      );
    }

    return _YoloVerificationBadgeData(
      icon: Icons.hourglass_top_rounded,
      accentColor: Colors.orangeAccent,
      label: '상태 확인 중',
      detail: stage != '-' ? stage : '로그 수집 대기',
    );
  }

  Widget _buildYoloVerificationBadge() {
    final badge = _resolveYoloVerificationBadge();
    if (badge == null) {
      return const SizedBox.shrink();
    }
    final tooltip = [
      badge.label,
      if (badge.detail != null && badge.detail!.trim().isNotEmpty)
        badge.detail!,
    ].join('\n');
    return Positioned(
      right: 12,
      top: 56,
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 350),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              setState(() {
                _yoloOverlayExpanded = !_yoloOverlayExpanded;
                _showControls = true;
              });
              _restartControlsAutoHide();
            },
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: badge.accentColor.withValues(alpha: 0.72),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: DefaultTextStyle(
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              badge.icon,
                              size: 14,
                              color: badge.accentColor,
                            ),
                            const SizedBox(width: 6),
                            Flexible(child: Text(badge.label)),
                          ],
                        ),
                        if (badge.detail != null &&
                            badge.detail!.trim().isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            badge.detail!,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildYoloStatusOverlay() {
    final snapshot = _lastYoloStatus;
    final hasYoloRunner = widget.onRunYoloDebugAtPosition != null;
    final availabilityHint = widget.yoloAvailabilityHint?.trim();
    if (!_yoloPlaybackEnabled &&
        snapshot == null &&
        hasYoloRunner &&
        (availabilityHint == null || availabilityHint.isEmpty)) {
      return const SizedBox.shrink();
    }
    final state = snapshot?.state ?? const <String, dynamic>{};
    final stage = _yoloStatusValue(state, 'stage');
    final detections = _yoloStatusValue(state, 'parsedDetectionCount');
    final blocker = _yoloStatusValue(state, 'blocker');
    final frames =
        '${_yoloStatusValue(state, 'framesSeen')} / ${_yoloStatusValue(state, 'framesSampled')} / ${_yoloStatusValue(state, 'framesSkipped')}';
    final runtimeReady = _yoloStatusValue(state, 'runtimeReady');
    final pixelPathReady = _yoloStatusValue(state, 'pixelPathReady');
    final sessionFrame = _yoloStatusValue(state, 'sessionFrameCounter');
    final positionMs = _yoloStatusValue(state, 'positionMs');
    final lastError = _yoloStatusValue(state, 'lastError');
    final backend =
        _currentYoloMetaValue('backend', configKey: 'runtimeBackend');
    final model = _currentYoloMetaValue('modelVariant');
    final syncSource = _currentYoloMetaValue('syncSource');
    final frameToken = _currentYoloMetaValue('playbackFrameToken');
    final overlayFallback = _currentYoloMetaValue('offlineOverlayFallback');
    final suggestedQnnAsset = _currentYoloMetaValue('suggestedQnnAssetFile');
    final expectedAssets = model == '-'
        ? '-'
        : YoloModelVariant.fromWireValue(model).assetFileHint;
    final visuals =
        '${_currentYoloShowBoxes() ? 'box' : '-'} / ${_currentYoloShowLabels() ? 'label' : '-'}';
    final forceVisibleBoxes = _shouldForceVisiblePlaybackBoxes();
    final blockerHint = blocker == '-' ? null : _yoloBlockerHint(blocker);
    final overlayHint = forceVisibleBoxes
        ? '박스/라벨이 둘 다 꺼져 있어 route playback에서는 박스를 임시로 표시합니다.'
        : null;
    final idleHint = !hasYoloRunner
        ? (availabilityHint?.isNotEmpty == true
            ? availabilityHint!
            : '이 재생 세그먼트에서는 YOLO playback을 사용할 수 없습니다.')
        : (!_yoloPlaybackEnabled
            ? '우측 상단 로봇 버튼으로 route YOLO playback을 시작하세요.'
            : null);
    return Positioned(
      left: 12,
      top: 56,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            setState(() {
              _yoloOverlayExpanded = !_yoloOverlayExpanded;
            });
          },
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _yoloPlaybackEnabled
                    ? Colors.orangeAccent.withValues(alpha: 0.65)
                    : Colors.white24,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_yoloPlaybackEnabled
                            ? 'YOLO 재생 테스트'
                            : 'YOLO 최근 상태'),
                        const SizedBox(width: 8),
                        Text(
                          _yoloOverlayExpanded ? '접기' : '펼치기',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (snapshot != null) ...[
                          const SizedBox(width: 8),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () =>
                                unawaited(_copyYoloStatusOverlay(snapshot)),
                            child: const Padding(
                              padding: EdgeInsets.all(2),
                              child: Icon(
                                Icons.copy_all_rounded,
                                size: 14,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('stage: $stage'),
                    Text('detections: $detections'),
                    Text('frames: $frames'),
                    if (idleHint != null && snapshot == null) ...[
                      const SizedBox(height: 2),
                      Text(
                        idleHint,
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ] else if (overlayHint != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        overlayHint,
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ] else if (blockerHint != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        blockerHint,
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    if (_yoloOverlayExpanded) ...[
                      Text('backend: $backend'),
                      Text('model: $model'),
                      Text('sync: $syncSource'),
                      Text('frameToken: $frameToken'),
                      Text('visuals: $visuals'),
                      if (expectedAssets != '-')
                        Text('expectedAssets: $expectedAssets'),
                      if (suggestedQnnAsset != '-')
                        Text('suggestedQnn: $suggestedQnnAsset'),
                      if (overlayFallback != '-')
                        Text('overlayFallback: $overlayFallback'),
                      Text('blocker: $blocker'),
                      Text('runtimeReady: $runtimeReady'),
                      Text('pixelPathReady: $pixelPathReady'),
                      Text('sessionFrame: $sessionFrame'),
                      Text('positionMs: $positionMs'),
                      Text('lastError: $lastError'),
                    ] else if (blocker != '-') ...[
                      Text('blocker: $blocker'),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildYoloVideoOverlay() {
    if (!_yoloPlaybackEnabled) {
      return const SizedBox.shrink();
    }
    final detections = _currentYoloDetections();
    if (detections.isEmpty) {
      return const SizedBox.shrink();
    }
    final sourceWidth = _currentYoloSourceWidth();
    final sourceHeight = _currentYoloSourceHeight();
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return const SizedBox.shrink();
    }
    final showLabels = _currentYoloShowLabels();
    final showBoxes = _currentYoloShowBoxes() ||
        (!showLabels && _shouldForceVisiblePlaybackBoxes());
    return YoloDetectionOverlay(
      key: ValueKey<String>(
        widget.videoFile?.path ?? widget.videoUri.toString(),
      ),
      detections: detections,
      sourceWidth: sourceWidth.toDouble(),
      sourceHeight: sourceHeight.toDouble(),
      showBoxes: showBoxes,
      showLabels: showLabels,
    );
  }

  String _formatDuration(Duration value) {
    final total = value.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  File? _previewFrameForSecond(double second) {
    if (widget.previewFrames.isEmpty) return null;
    final step =
        widget.previewStep.inSeconds <= 0 ? 2 : widget.previewStep.inSeconds;
    final index = (second / step).round();
    final clamped = index.clamp(0, widget.previewFrames.length - 1);
    return widget.previewFrames[clamped];
  }

  List<PopupMenuEntry<double>> _speedMenuItems() {
    const values = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    return values
        .map(
          (speed) => PopupMenuItem<double>(
            value: speed,
            child: Text('${speed.toStringAsFixed(speed == 1.0 ? 0 : 2)}x'),
          ),
        )
        .toList();
  }

  Future<void> _openRangeShareSheet() async {
    if (!_initialized || widget.onShareRange == null) return;
    final totalSeconds = _duration.inSeconds;
    if (totalSeconds <= 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('구간 공유를 위한 재생 길이가 부족합니다.')),
      );
      return;
    }

    var startSec = math.max(0, _position.inSeconds - 10).toDouble();
    var endSec = math.min(totalSeconds.toDouble(), _position.inSeconds + 10.0);
    if (endSec <= startSec + 1) {
      endSec = math.min(totalSeconds.toDouble(), startSec + 1);
      if (endSec <= startSec) {
        startSec = math.max(0, endSec - 1);
      }
    }

    final selected = await showModalBottomSheet<(int, int)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final window = UiWindowInfo.of(context);
        final thumbHeight = switch (window.windowClass) {
          UiWindowClass.compact => 76.0,
          UiWindowClass.medium => 84.0,
          UiWindowClass.expanded => 96.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 108.0,
        };
        final modalPadding = switch (window.windowClass) {
          UiWindowClass.compact => const EdgeInsets.fromLTRB(14, 4, 14, 14),
          UiWindowClass.medium => const EdgeInsets.fromLTRB(16, 6, 16, 16),
          UiWindowClass.expanded => const EdgeInsets.fromLTRB(18, 8, 18, 18),
          UiWindowClass.large ||
          UiWindowClass.extraLarge =>
            const EdgeInsets.fromLTRB(20, 10, 20, 20),
        };
        final labelFont = switch (window.windowClass) {
          UiWindowClass.compact => 12.0,
          UiWindowClass.medium => 12.5,
          UiWindowClass.expanded => 13.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 13.5,
        };
        return StatefulBuilder(
          builder: (context, setModalState) {
            final startFrame = _previewFrameForSecond(startSec);
            final endFrame = _previewFrameForSecond(endSec);

            Widget frameThumb(File? file, String label, double seconds) {
              return Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: TextStyle(fontSize: labelFont)),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        color: Colors.black12,
                        height: thumbHeight,
                        width: double.infinity,
                        child: file == null
                            ? const Center(child: Icon(Icons.movie_outlined))
                            : Image.file(file, fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _formatDuration(
                          Duration(milliseconds: (seconds * 1000).round())),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              );
            }

            return SafeArea(
              child: Padding(
                padding: modalPadding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '구간 공유',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '키프레임처럼 시작/종료를 선택해 공유',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        frameThumb(startFrame, '시작', startSec),
                        const SizedBox(width: 10),
                        frameThumb(endFrame, '종료', endSec),
                      ],
                    ),
                    const SizedBox(height: 10),
                    RangeSlider(
                      min: 0,
                      max: totalSeconds.toDouble(),
                      values: RangeValues(startSec, endSec),
                      labels: RangeLabels(
                        _formatDuration(
                            Duration(milliseconds: (startSec * 1000).round())),
                        _formatDuration(
                            Duration(milliseconds: (endSec * 1000).round())),
                      ),
                      onChanged: (range) {
                        var s = range.start;
                        var e = range.end;
                        if (e <= s + 1) {
                          if (e >= totalSeconds) {
                            s = e - 1;
                          } else {
                            e = s + 1;
                          }
                        }
                        setModalState(() {
                          startSec = s.clamp(0, totalSeconds - 1).toDouble();
                          endSec = e.clamp(1, totalSeconds).toDouble();
                        });
                      },
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('취소'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => Navigator.pop(
                              context,
                              (startSec.round(), endSec.round()),
                            ),
                            icon: const Icon(Icons.share),
                            label: const Text('이 구간 공유'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (selected == null) return;
    await widget.onShareRange!(selected.$1, selected.$2);
  }

  Widget _buildPreviewBubble({
    required double maxWidth,
    required double seconds,
  }) {
    final frame = _previewFrameForSecond(seconds);
    final durationSec = math.max(1, _duration.inSeconds).toDouble();
    final ratio = (seconds / durationSec).clamp(0.0, 1.0);
    const bubbleWidth = 180.0;
    const bubbleHeight = 120.0;
    final left = math.max(0, maxWidth - bubbleWidth) * ratio;

    return Transform.translate(
      offset: Offset(left, 0),
      child: Container(
        width: bubbleWidth,
        height: bubbleHeight,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 10,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
                child: frame == null
                    ? Container(
                        color: Colors.black26,
                        child: const Center(
                          child: Icon(Icons.movie, color: Colors.white54),
                        ),
                      )
                    : Image.file(
                        frame,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatDuration(Duration(milliseconds: (seconds * 1000).round())),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsOverlay() {
    final durationSec = math.max(1, _duration.inMilliseconds / 1000).toDouble();
    final positionSec =
        (_isScrubbing ? _scrubSeconds : (_position.inMilliseconds / 1000))
            .clamp(0.0, durationSec)
            .toDouble();

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: _showControls ? 1 : 0,
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.48),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.7),
              ],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 10,
                right: 10,
                top: 8,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    PopupMenuButton<double>(
                      tooltip: '배속',
                      onSelected: (speed) =>
                          unawaited(_setPlaybackSpeed(speed)),
                      itemBuilder: (_) => _speedMenuItems(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Text(
                          '${_playbackSpeed.toStringAsFixed(_playbackSpeed == 1.0 ? 0 : 2)}x',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    if (widget.onShareRange != null)
                      IconButton(
                        tooltip: '구간 공유',
                        onPressed: () => unawaited(_openRangeShareSheet()),
                        icon: const Icon(Icons.ios_share, color: Colors.white),
                      ),
                    if (widget.onRunYoloDebugAtPosition != null)
                      IconButton(
                        tooltip: _yoloPlaybackEnabled
                            ? 'YOLO 재생 테스트 중지'
                            : 'YOLO 재생 테스트 시작',
                        onPressed: () => unawaited(_toggleYoloPlaybackDebug()),
                        icon: Icon(
                          _yoloPlaybackEnabled
                              ? Icons.smart_toy
                              : Icons.smart_toy_outlined,
                          color: _yoloPlaybackEnabled
                              ? Colors.orangeAccent
                              : Colors.white,
                        ),
                      ),
                    if (widget.onClose != null) ...[
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: '닫기',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close, color: Colors.white),
                      ),
                    ],
                  ],
                ),
              ),
              Align(
                alignment: Alignment.center,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () => unawaited(_seekBySeconds(-10)),
                      iconSize: 42,
                      color: Colors.white,
                      icon: const Icon(Icons.replay_10),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: () => unawaited(_togglePlayPause()),
                      iconSize: 68,
                      color: Colors.white,
                      icon: Icon(
                        _controller.value.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: () => unawaited(_seekBySeconds(10)),
                      iconSize: 42,
                      color: Colors.white,
                      icon: const Icon(Icons.forward_10),
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_isScrubbing)
                            _buildPreviewBubble(
                              maxWidth: constraints.maxWidth,
                              seconds: positionSec,
                            ),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 4,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 7,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14,
                              ),
                            ),
                            child: Slider(
                              min: 0,
                              max: durationSec,
                              value: positionSec,
                              onChangeStart: _onScrubStart,
                              onChanged: _onScrubChanged,
                              onChangeEnd: (value) =>
                                  unawaited(_onScrubEnd(value)),
                            ),
                          ),
                          Row(
                            children: [
                              Text(
                                _formatDuration(Duration(
                                    milliseconds:
                                        (positionSec * 1000).round())),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _formatDuration(_duration),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoBody() {
    if (!_initialized) {
      return Center(
        child: _initError == null
            ? const CircularProgressIndicator()
            : Text(
                _initError!,
                style: const TextStyle(color: Colors.white70),
              ),
      );
    }

    final aspect = _controller.value.aspectRatio <= 0
        ? (16 / 9)
        : _controller.value.aspectRatio;

    return LayoutBuilder(
      builder: (context, constraints) {
        var width = constraints.maxWidth;
        var height = width / aspect;
        if (height > constraints.maxHeight) {
          height = constraints.maxHeight;
          width = height * aspect;
        }

        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  InteractiveViewer(
                    minScale: 1.0,
                    maxScale: 3.5,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: aspect,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            VideoPlayer(_controller),
                            _buildYoloVideoOverlay(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTap: () => unawaited(_seekBySeconds(-10)),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTap: () => unawaited(_seekBySeconds(10)),
                        ),
                      ),
                    ],
                  ),
                  _buildYoloStatusOverlay(),
                  _buildYoloVerificationBadge(),
                  _buildControlsOverlay(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.useScaffold) {
      return ColoredBox(
        color: Colors.black,
        child: _buildVideoBody(),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('세그먼트 재생'),
      ),
      body: _buildVideoBody(),
    );
  }
}
