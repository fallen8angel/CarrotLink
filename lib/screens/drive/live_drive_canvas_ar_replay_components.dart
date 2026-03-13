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
    final summary =
        (arScenePayload['summary'] as Map?)?.cast<String, dynamic>();
    final presentation =
        (arScenePayload['presentation'] as Map?)?.cast<String, dynamic>();
    final turnLabel = (summary?['turnLabel'] ?? '').toString().trim();
    final mode = (presentation?['mode'] ?? '-').toString();
    final routeCount = (summary?['routePointCount'] ?? '-').toString();
    final suffix =
        turnLabel.isEmpty ? 'mode=$mode route=$routeCount' : turnLabel;
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

  Future<Map<String, dynamic>?> _fetchNativeArRenderDebugImpl(
      int viewId) async {
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

  String _arReplayTimestampForFileNameImpl(DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}_'
        '${three(now.millisecond)}';
  }

  Future<void> _ensureArReplaySessionPathsImpl({DateTime? now}) async {
    if (_arReplaySessionDirPath != null &&
        _arReplaySessionTimelinePath != null &&
        _arReplaySessionMetaPath != null &&
        _arReplaySessionId != null) {
      return;
    }
    final resolvedNow = now ?? DateTime.now();
    final dir = await _resolveArSceneLogDirImpl();
    final hostTag = _hostIp.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final sessionId = _arReplayTimestampForFileNameImpl(resolvedNow);
    final sessionDir = Directory('${dir.path}/session_${sessionId}_$hostTag');
    if (!await sessionDir.exists()) {
      await sessionDir.create(recursive: true);
    }
    _arReplaySessionId = sessionId;
    _arReplaySessionDirPath = sessionDir.path;
    _arReplaySessionTimelinePath = '${sessionDir.path}/timeline.ndjson';
    _arReplaySessionMetaPath = '${sessionDir.path}/session_meta.json';
  }

  Future<Directory> _resolveArSceneLogDirImpl() async {
    try {
      await StorageLayoutService.instance.ensureBaseFolders();
      final preferred = Directory('${StorageLayoutService.logsPath}/ar_scene');
      if (!await preferred.exists()) {
        await preferred.create(recursive: true);
      }
      return preferred;
    } catch (_) {
      final fallback =
          Directory('${Directory.systemTemp.path}/carrotlink_ar_scene');
      if (!await fallback.exists()) {
        await fallback.create(recursive: true);
      }
      return fallback;
    }
  }

  Map<String, dynamic> _buildArReplayTimelineEntryImpl(
    _DriveArReplayFrame frame, {
    required DateTime now,
    required String reason,
  }) {
    return <String, dynamic>{
      'timestamp': now.toIso8601String(),
      'reason': reason,
      'sessionId': _arReplaySessionId,
      'hostIp': _hostIp,
      'cameraKind': frame.cameraKind,
      'nativeViewId': _nativeCameraViewId,
      'bridgeEnabled': _debugPushNativeArScene,
      'autoCaptureEnabled': _debugArCaptureEnabled,
      'autoPersistEnabled': _debugArAutoPersistEnabled,
      'frame': <String, dynamic>{
        'seq': frame.seq,
        'capturedAt': frame.capturedAt.toIso8601String(),
        'label': frame.label,
        'arScenePayload': frame.arScenePayload,
        'nativeRenderDebug': frame.nativeRenderDebug,
      },
      'cameraSummary': <String, dynamic>{
        'liveCameraKind': _liveCameraKind.name,
        'sourceWidth': _cameraSourceSize.width,
        'sourceHeight': _cameraSourceSize.height,
        'overlayWidth': _nativeOverlaySize.width,
        'overlayHeight': _nativeOverlaySize.height,
        'nativeVisibleViewport': _nativeOverlayVisibleViewportRect.toString(),
      },
      'runtimeSummary': <String, dynamic>{
        'overlayFps': _overlayDebugFps,
        'modelCameraGap': _overlayModelCameraGap,
        'sidecarPhase': _sidecarPhase.name,
        'sidecarConnected': _sidecarConnected,
      },
    };
  }

  Map<String, dynamic> _buildArReplayExportPayloadImpl({
    required DateTime now,
    required String reason,
  }) {
    final localScene = _overlayNotifier.value.buildArScene(
      cameraKind: _liveCameraKind,
    );
    final activeReplay = _activeArReplayFrame;
    return <String, dynamic>{
      'timestamp': now.toIso8601String(),
      'reason': reason,
      'hostIp': _hostIp,
      'cameraKind': _liveCameraKind.name,
      'nativeViewId': _nativeCameraViewId,
      'bridgeEnabled': _debugPushNativeArScene,
      'autoCaptureEnabled': _debugArCaptureEnabled,
      'autoPersistEnabled': _debugArAutoPersistEnabled,
      'replayStatus': _arReplayStatusLabel(),
      'activeReplayLabel': activeReplay?.label,
      'latestExportPath': _lastArReplayExportPath,
      'sessionId': _arReplaySessionId,
      'sessionDirPath': _arReplaySessionDirPath,
      'sessionTimelinePath': _arReplaySessionTimelinePath,
      'sessionMetaPath': _arReplaySessionMetaPath,
      'captureWindowCount': _arReplayFrames.length,
      'totalCapturedCount': _arReplayCaptureSeq,
      'persistedCaptureCount': _lastPersistedArReplaySeq,
      'sceneSummary': <String, dynamic>{
        'mode': localScene.presentation.mode,
        'layoutProfile': localScene.presentation.layoutProfile,
        'renderBudget': localScene.presentation.renderBudget,
        'routePointCount': localScene.routePoints.length,
        'turnInfo': localScene.turnCue?.turnInfo ?? 0,
        'turnDistanceMeters': localScene.turnCue?.distanceMeters,
        'statusText': localScene.statusText,
        'turnLabel': localScene.turnLabel,
        'calibrationOk': localScene.health.calibrationOk,
        'frameGap': localScene.health.frameGap,
        'frameGapOk': localScene.health.frameGapOk,
      },
      'captures': _arReplayFrames
          .map(
            (frame) => <String, dynamic>{
              'seq': frame.seq,
              'capturedAt': frame.capturedAt.toIso8601String(),
              'label': frame.label,
              'cameraKind': frame.cameraKind,
              'arScenePayload': frame.arScenePayload,
              'nativeRenderDebug': frame.nativeRenderDebug,
            },
          )
          .toList(growable: false),
      'history': _sidecarHistory.toList(growable: false),
      'processSnapshot': _sidecarProcessSnapshot,
      'healthSnapshot': _sidecarHealthSnapshot,
      'profileSnapshot': _sidecarProfileSnapshot,
      'cameraQualitySnapshot': _sidecarCameraQualitySnapshot,
    };
  }

  Future<void> _writeArReplayExportImpl({
    required String fileName,
    required String reason,
  }) async {
    final now = DateTime.now();
    final dir = await _resolveArSceneLogDirImpl();
    final file = File('${dir.path}/$fileName');
    final payload = _buildArReplayExportPayloadImpl(
      now: now,
      reason: reason,
    );
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(payload),
      flush: true,
    );
    _lastArReplayExportPath = file.path;
  }

  Future<void> _appendArReplayTimelineImpl({
    required String reason,
    required DateTime now,
  }) async {
    await _ensureArReplaySessionPathsImpl(now: now);
    final timelinePath = _arReplaySessionTimelinePath;
    if (timelinePath == null) return;
    final pending =
        _arReplayFrames.where((frame) => frame.seq > _lastPersistedArReplaySeq);
    if (pending.isEmpty) return;
    final file = File(timelinePath);
    final sink = file.openWrite(mode: FileMode.append);
    try {
      for (final frame in pending) {
        final entry = _buildArReplayTimelineEntryImpl(
          frame,
          now: now,
          reason: reason,
        );
        sink.writeln(jsonEncode(entry));
        _lastPersistedArReplaySeq = frame.seq;
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<void> _writeArReplaySessionMetaImpl({
    required DateTime now,
    required String reason,
  }) async {
    await _ensureArReplaySessionPathsImpl(now: now);
    final metaPath = _arReplaySessionMetaPath;
    if (metaPath == null) return;
    final payload = _buildArReplayExportPayloadImpl(
      now: now,
      reason: reason,
    );
    const encoder = JsonEncoder.withIndent('  ');
    await File(metaPath).writeAsString(
      encoder.convert(payload),
      flush: true,
    );
  }

  Future<void> _persistArReplaySessionIfNeededImpl({
    bool force = false,
    String? reason,
  }) async {
    if (!_debugArAutoPersistEnabled) return;
    if (_arReplayFrames.isEmpty) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    if (!force &&
        (nowUs - _lastArReplayPersistUs) <
            _LiveDriveCanvasScreenState._arReplayPersistIntervalUs) {
      return;
    }
    _lastArReplayPersistUs = nowUs;
    final persistReason = reason ?? (force ? 'manual_persist' : 'auto_persist');
    final now = DateTime.now();
    try {
      await _appendArReplayTimelineImpl(
        reason: persistReason,
        now: now,
      );
      await _writeArReplaySessionMetaImpl(
        now: now,
        reason: persistReason,
      );
      await _writeArReplayExportImpl(
        fileName: 'session_latest.json',
        reason: persistReason,
      );
    } catch (_) {}
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
    if (_arReplayFrames.length >=
        _LiveDriveCanvasScreenState._arReplayMaxFrames) {
      final removed = _arReplayFrames.removeFirst();
      if (identical(_activeArReplayFrame, removed)) {
        _activeArReplayFrame = null;
        _debugArReplayMode = false;
      }
    }
    _arReplayFrames.addLast(frame);
    await _persistArReplaySessionIfNeeded(reason: 'capture_tick');
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
    await _persistArReplaySessionIfNeeded(
      force: true,
      reason: 'manual_capture',
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

  Future<void> _debugActionExportArReplayImpl() async {
    if (_arReplayFrames.isEmpty) {
      _toast('내보낼 AR 캡처가 없습니다.', isError: true);
      return;
    }
    try {
      await _persistArReplaySessionIfNeeded(
        force: true,
        reason: 'manual_export_prepare',
      );
      final name =
          'ar_scene_export_${_arReplayTimestampForFileNameImpl(DateTime.now())}.json';
      await _writeArReplayExportImpl(
        fileName: name,
        reason: 'manual_export',
      );
      _pushSidecarHistory('CHECK', 'export ar_replay');
      _toast('AR 파일 저장 완료');
    } catch (e) {
      _pushSidecarHistory('FAIL', 'export ar_replay: $e');
      _toast('AR 파일 저장 실패: $e', isError: true);
    }
  }
}
