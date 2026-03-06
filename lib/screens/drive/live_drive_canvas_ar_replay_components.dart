part of 'live_drive_canvas_screen.dart';

class _DriveArReplayFrame {
  final int seq;
  final DateTime capturedAt;
  final String cameraKind;
  final Map<String, dynamic> arScenePayload;
  final Map<String, dynamic>? nativeRenderDebug;

  const _DriveArReplayFrame({
    required this.seq,
    required this.capturedAt,
    required this.cameraKind,
    required this.arScenePayload,
    required this.nativeRenderDebug,
  });

  String get label {
    final summary = (arScenePayload['summary'] as Map?)?.cast<String, dynamic>();
    final presentation =
        (arScenePayload['presentation'] as Map?)?.cast<String, dynamic>();
    final turnLabel = (summary?['turnLabel'] ?? '').toString().trim();
    final mode = (presentation?['mode'] ?? '-').toString();
    final routeCount = (summary?['routePointCount'] ?? '-').toString();
    final suffix = turnLabel.isEmpty ? 'mode=$mode route=$routeCount' : turnLabel;
    return '#$seq ${capturedAt.toIso8601String()} $cameraKind $suffix';
  }
}

extension _LiveDriveCanvasArReplayComponents on _LiveDriveCanvasScreenState {
  _DriveArReplayFrame? get _latestArReplayFrame =>
      _arReplayFrames.isEmpty ? null : _arReplayFrames.last;

  String _arReplayStatusLabelImpl() {
    final active = _activeArReplayFrame;
    if (_debugArReplayMode && active != null) {
      return 'replay:${active.label}';
    }
    return 'captures=${_arReplayFrames.length}';
  }

  Map<String, dynamic>? _currentLiveArScenePayloadImpl() {
    if (_nativeOverlaySize.width <= 1 || _nativeOverlaySize.height <= 1) {
      return null;
    }
    return _DriveOverlayPainter.buildArScenePayload(
      snapshot: _overlayNotifier.value,
      sourceSize: _cameraSourceSize,
      cameraKind: _liveCameraKind,
      canvasSize: _nativeOverlaySize,
      coverViewport: _coverViewport,
      viewportZoom: _viewportPlacementZoom,
      visibleViewportRect: _nativeOverlayVisibleViewportRect,
    );
  }

  Map<String, dynamic>? _deepCloneStringMapImpl(Map<String, dynamic>? value) {
    if (value == null) return null;
    try {
      final cloned = jsonDecode(jsonEncode(value));
      if (cloned is Map) {
        return cloned.map((key, v) => MapEntry(key.toString(), v));
      }
    } catch (_) {}
    return Map<String, dynamic>.from(value);
  }

  Future<Map<String, dynamic>?> _fetchNativeArRenderDebugImpl(int viewId) async {
    try {
      final raw = await _LiveDriveCanvasScreenState._nativeCameraControlChannel
          .invokeMethod<dynamic>(
        'getArRenderDebug',
        <String, dynamic>{'viewId': viewId},
      );
      return _coerceStringMap(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _captureArReplayFrameImpl({
    required Map<String, dynamic> arScenePayload,
    int? viewId,
    Map<String, dynamic>? nativeRenderDebug,
    bool force = false,
  }) async {
    final nowUs = _renderClock.elapsedMicroseconds;
    if (!force &&
        (nowUs - _lastArReplayCaptureUs) <
            _LiveDriveCanvasScreenState._arReplayCaptureIntervalUs) {
      return;
    }
    _lastArReplayCaptureUs = nowUs;
    final clonedPayload = _deepCloneStringMapImpl(arScenePayload);
    if (clonedPayload == null) return;
    final debugPayload = nativeRenderDebug ??
        (viewId != null ? await _fetchNativeArRenderDebug(viewId) : null);
    final frame = _DriveArReplayFrame(
      seq: ++_arReplayCaptureSeq,
      capturedAt: DateTime.now(),
      cameraKind: _liveCameraKind.name,
      arScenePayload: clonedPayload,
      nativeRenderDebug: _deepCloneStringMapImpl(debugPayload),
    );
    if (_arReplayFrames.length >= _LiveDriveCanvasScreenState._arReplayMaxFrames) {
      final removed = _arReplayFrames.removeFirst();
      if (identical(_activeArReplayFrame, removed)) {
        _activeArReplayFrame = null;
        _debugArReplayMode = false;
      }
    }
    _arReplayFrames.addLast(frame);
  }

  void _setArReplayModeImpl(
    bool enabled, {
    _DriveArReplayFrame? frame,
  }) {
    final target = enabled ? (frame ?? _latestArReplayFrame) : null;
    if (enabled && target == null) {
      _toast('재생할 AR 캡처가 없습니다.', isError: true);
      return;
    }
    _safeSetState(() {
      _debugArReplayMode = enabled;
      _activeArReplayFrame = target;
    });
    _applyOverlaySnapshot(
      _overlayNotifier.value,
      forceNativePush: true,
    );
    _toast(enabled ? 'AR 재생 적용: ${target!.label}' : 'AR 재생 종료');
  }

  Future<void> _debugActionCaptureArReplayImpl() async {
    final payload = _currentLiveArScenePayload();
    if (payload == null) {
      _toast('저장할 AR scene 이 없습니다.', isError: true);
      return;
    }
    await _captureArReplayFrame(
      arScenePayload: payload,
      viewId: _nativeCameraViewId,
      force: true,
    );
    _pushSidecarHistory('CHECK', 'capture ar_replay');
    _toast('AR 캡처 저장 완료 (${_arReplayFrames.length})');
  }

  Future<void> _debugActionUseLatestArReplayImpl() async {
    final latest = _latestArReplayFrame;
    if (latest == null) {
      _toast('저장된 AR 캡처가 없습니다.', isError: true);
      return;
    }
    _setArReplayMode(true, frame: latest);
    _pushSidecarHistory('CHECK', 'use latest ar_replay');
  }

  Future<void> _debugActionStopArReplayImpl() async {
    if (!_debugArReplayMode && _activeArReplayFrame == null) {
      _toast('AR 재생이 비활성화되어 있습니다.');
      return;
    }
    _setArReplayMode(false);
    _pushSidecarHistory('CHECK', 'stop ar_replay');
  }
}
