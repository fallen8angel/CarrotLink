part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasOverlaySyncComponents on _LiveDriveCanvasScreenState {
  bool get _startupProvisionalSyncActive {
    if (!_startupProvisionalSyncEnabled) return false;
    final nowUs = _renderClock.elapsedMicroseconds;
    if (nowUs <= _startupProvisionalSyncUntilUs) {
      return true;
    }
    _startupProvisionalSyncEnabled = false;
    _startupProvisionalSyncUntilUs = 0;
    _startupNativeFrameSettleCount = 0;
    return false;
  }

  void _beginStartupProvisionalSync({
    required String reason,
    int windowUs = _LiveDriveCanvasScreenState._startupProvisionalSyncWindowUs,
  }) {
    final nowUs = _renderClock.elapsedMicroseconds;
    final wasActive = _startupProvisionalSyncActive;
    _startupProvisionalSyncEnabled = true;
    _startupProvisionalSyncUntilUs =
        math.max(_startupProvisionalSyncUntilUs, nowUs + windowUs);
    _startupNativeFrameSettleCount = 0;
    if (!wasActive || (nowUs - _lastProvisionalSyncLogUs) >= 1500000) {
      _lastProvisionalSyncLogUs = nowUs;
      debugPrint(
        '[DriveCanvas][sync] provisional on reason=$reason window=${(windowUs / 1000).round()}ms',
      );
    }
  }

  void _endStartupProvisionalSync({required String reason}) {
    if (!_startupProvisionalSyncEnabled) return;
    _startupProvisionalSyncEnabled = false;
    _startupProvisionalSyncUntilUs = 0;
    _startupNativeFrameSettleCount = 0;
    final nowUs = _renderClock.elapsedMicroseconds;
    if ((nowUs - _lastProvisionalSyncLogUs) >= 300000) {
      _lastProvisionalSyncLogUs = nowUs;
      debugPrint('[DriveCanvas][sync] provisional off reason=$reason');
    }
  }

  void _markOverlayStale({required String reason}) {
    if (_overlayStaleActive && _overlayStaleReason == reason) {
      return;
    }
    if (mounted) {
      _safeSetState(() {
        _overlayStaleActive = true;
        _overlayStaleReason = reason;
      });
    } else {
      _overlayStaleActive = true;
      _overlayStaleReason = reason;
    }
  }

  void _clearOverlayStaleState() {
    if (!_overlayStaleActive && _overlayStaleReason.isEmpty) {
      return;
    }
    if (mounted) {
      _safeSetState(() {
        _overlayStaleActive = false;
        _overlayStaleReason = '';
      });
    } else {
      _overlayStaleActive = false;
      _overlayStaleReason = '';
    }
  }

  bool _holdLastGoodOverlayWhileStale({
    required int nowUs,
    required String reason,
  }) {
    if (_lastPublishedModelFrameId == null) {
      return false;
    }
    final referenceUs =
        math.max(_lastOverlayPublishUs, _lastSyncHitUs).clamp(0, nowUs);
    if (referenceUs <= 0) {
      return false;
    }
    if ((nowUs - referenceUs) < 0) {
      return false;
    }
    _renderInterpActive = false;
    _markOverlayStale(reason: reason);
    _applyOverlaySnapshot(
      const _DriveOverlaySnapshot.empty(),
      forceNativePush: true,
    );
    _lastPublishedModelFrameId = null;
    _lastOverlayPublishUs = 0;
    if (_openpilotOverlayMode &&
        _sidecarConnected &&
        !_cameraSuspendedByLifecycle &&
        !_startupProvisionalSyncActive) {
      _scheduleSidecarRuntimeRecovery(reason: 'overlay_stalled');
    }
    return false;
  }

  bool _isOverlaySnapshotRenderable(_DriveOverlaySnapshot snapshot) {
    return snapshot.modelFrameId != null ||
        snapshot.path.length >= 2 ||
        snapshot.debugPlot != null;
  }

  bool _tryPublishLatestOverlayDuringStartup(int nowUs) {
    if (!_startupProvisionalSyncActive) return false;
    final latest = _latestOverlaySnapshot;
    if (!_isOverlaySnapshotRenderable(latest)) return false;
    final modelFrameId = latest.modelFrameId;
    if (modelFrameId != null && modelFrameId == _lastPublishedModelFrameId) {
      return true;
    }
    _clearOverlayStaleState();
    _recordDebugPlotSample(latest);
    _setRenderTarget(latest, nowUs: nowUs);
    _lastPublishedModelFrameId = modelFrameId;
    return true;
  }

  bool _isAnimatedPathMode(int mode) => mode >= 1 && mode <= 8;

  _DriveOverlaySnapshot _stabilizeOverlaySnapshotImpl(
    _DriveOverlaySnapshot snapshot,
  ) {
    var next = snapshot;
    final previous = _latestOverlaySnapshot;


    // Enforce classic visual style (no blue 3-strip mode).
    var mode = next.pathMode;
    var color = next.pathColor;
    if (mode >= 13 && mode <= 15) mode = 0;
    if (color == 14 || color == 19) color = 3;
    if (mode != next.pathMode || color != next.pathColor) {
      next = next.copyWith(pathMode: mode, pathColor: color);
    }

    final hasCurrentNavHint = next.navTurnInfo != 0 ||
        (next.navDistToTurn != null && next.navDistToTurn! > 0.0) ||
        next.navMainText.trim().isNotEmpty;
    if (hasCurrentNavHint) {
      var navPathPoints = next.navPathPoints;
      var navTurnInfo = next.navTurnInfo;
      var navDistToTurn = next.navDistToTurn;
      var navMainText = next.navMainText;
      var navChanged = false;

      if (navPathPoints.length < 2 && previous.navPathPoints.length >= 2) {
        navPathPoints = previous.navPathPoints;
        navChanged = true;
      }
      if (navTurnInfo == 0 && previous.navTurnInfo != 0) {
        navTurnInfo = previous.navTurnInfo;
        navChanged = true;
      }
      if ((navDistToTurn == null || navDistToTurn <= 0.0) &&
          previous.navDistToTurn != null &&
          previous.navDistToTurn! > 0.0) {
        navDistToTurn = previous.navDistToTurn;
        navChanged = true;
      }
      if (navMainText.trim().isEmpty &&
          previous.navMainText.trim().isNotEmpty) {
        navMainText = previous.navMainText;
        navChanged = true;
      }

      if (navChanged) {
        next = next.copyWith(
          navPathPoints: navPathPoints,
          navTurnInfo: navTurnInfo,
          navDistToTurn: navDistToTurn,
          navMainText: navMainText,
        );
      }
    }

    return next;
  }

  void _applyHudModeRuntimeImpl() {
    if (_openpilotOverlayMode) {
      _clearSidecarRecoverySchedule();
      _setSidecarPhase(
        _SidecarPhase.verifying,
        message: '사이드카 런타임 상태를 확인합니다.',
      );
      _startAdaptiveCameraQualityLoop();
      _suppressCameraErrors = true;
      _setNativeCameraAttachReady(false);
      _startCameraErrorGrace(reason: 'mode_apply');
      if (mounted) {
        _safeSetState(() {
          _cameraLoading = true;
          _cameraError = null;
          _nativeCameraViewId = null;
        });
      } else {
        _cameraLoading = true;
        _cameraError = null;
        _nativeCameraViewId = null;
      }
      unawaited(_loadCameraSource(force: true));
      unawaited(_ensureSidecarRuntime(reason: 'mode_apply'));
      return;
    }
    _clearSidecarRecoverySchedule();
    _suppressCameraErrors = false;
    _setSidecarPhase(
      _SidecarPhase.idle,
      message: '사이드카 그래픽 모드를 종료했습니다. 잠시 후 유휴 정리합니다.',
    );
    _stopAdaptiveCameraQualityLoop(resetMode: true);
    _stopSidecarLoop();
    _clearOverlayStaleState();
    _scheduleIdleSidecarWarmStop();
    _applyOverlaySnapshot(
      const _DriveOverlaySnapshot.empty(),
      forceNativePush: true,
    );
    unawaited(_pushNativeYoloConfig(force: true));
    unawaited(_clearNativeOverlay());
    unawaited(_loadCameraSource(force: true));
  }

  void _setOverlayVerifyModeImpl(bool enabled) {
    if (!mounted) return;
    if (_overlayVerifyMode == enabled) return;
    _safeSetState(() {
      _overlayVerifyMode = enabled;
      if (!enabled) {
        _overlayVerifyText = '';
      }
    });
    _toast(enabled ? '정합 검증 ON' : '정합 검증 OFF');
    if (enabled && _debugShowVerifyPanel) {
      _refreshOverlayVerify(_overlayNotifier.value, force: true);
    }
  }

  void _setViewportFitModeImpl(bool coverPreferred) {
    _setViewportZoomPresetImpl(
      coverPreferred
          ? _DriveViewportZoomPreset.crop
          : _DriveViewportZoomPreset.fit,
    );
  }

  String _viewportZoomPresetPrefKey(bool isLandscape) {
    return isLandscape
        ? _LiveDriveCanvasScreenState._viewportZoomPresetLandscapePrefKey
        : _LiveDriveCanvasScreenState._viewportZoomPresetPortraitPrefKey;
  }

  _DriveViewportZoomPreset _parseViewportZoomPreset(String? raw) {
    for (final preset in _DriveViewportZoomPreset.values) {
      if (preset.name == raw) {
        return preset;
      }
    }
    return _DriveViewportZoomPreset.crop;
  }

  Future<void> _syncViewportZoomPresetForOrientationImpl() async {
    if (!mounted) return;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (_lastViewportZoomOrientationLandscape == isLandscape) {
      return;
    }
    _lastViewportZoomOrientationLandscape = isLandscape;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_viewportZoomPresetPrefKey(isLandscape));
      final preset = _parseViewportZoomPreset(raw);
      if (!mounted || _lastViewportZoomOrientationLandscape != isLandscape) {
        return;
      }
      if (_viewportZoomPreset == preset) return;
      _safeSetState(() => _viewportZoomPreset = preset);
    } catch (_) {}
  }

  Future<void> _saveViewportZoomPresetForOrientationImpl(
    _DriveViewportZoomPreset preset,
  ) async {
    final isLandscape = mounted
        ? MediaQuery.orientationOf(context) == Orientation.landscape
        : (_lastViewportZoomOrientationLandscape ?? false);
    _lastViewportZoomOrientationLandscape = isLandscape;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _viewportZoomPresetPrefKey(isLandscape), preset.name);
    } catch (_) {}
  }

  void _setViewportZoomPresetImpl(_DriveViewportZoomPreset preset) {
    if (!mounted) return;
    if (_viewportZoomPreset == preset) return;
    _safeSetState(() => _viewportZoomPreset = preset);
    unawaited(_saveViewportZoomPresetForOrientationImpl(preset));
    _toast('${preset.tooltip} 적용');
  }

  void _setDebugGuidesImpl(bool enabled) {
    if (!mounted) return;
    if (_debugShowGuides == enabled) return;
    _safeSetState(() => _debugShowGuides = enabled);
    _toast(enabled ? '디버그 가이드 ON' : '디버그 가이드 OFF');
  }

  void _setDebugVerifyPanelImpl(bool enabled) {
    if (!mounted) return;
    if (_debugShowVerifyPanel == enabled) return;
    _safeSetState(() {
      _debugShowVerifyPanel = enabled;
      if (!enabled) {
        _overlayVerifyText = '';
      }
    });
    _toast(enabled ? '디버그 정보창 ON' : '디버그 정보창 OFF');
    if (_overlayVerifyMode && enabled) {
      _refreshOverlayVerify(_overlayNotifier.value, force: true);
    }
  }

  void _setDebugViewportFrameImpl(bool enabled) {
    if (!mounted) return;
    if (_debugShowViewportFrame == enabled) return;
    _safeSetState(() => _debugShowViewportFrame = enabled);
    _toast(enabled ? '레터박스 프레임 ON' : '레터박스 프레임 OFF');
  }

  Future<void> _loadHudDebugLayerTogglesImpl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const defaults = <String, bool>{
        // Default policy: keep the core AR/lead/radar overlays visible.
        // Native AR transport and YOLO diagnostics stay off until requested.
        'arOverlay': true,
        'nativeArScene': false,
        'arAutoSave': false,
        'pathFill': true,
        'laneLines': true,
        'roadEdge': true,
        'lead1': true,
        'lead2': true,
        'radarBadge': true,
        'radarVector': true,
        'stopDistanceTf': true,
        'stateText': true,
        'yoloEnabled': false,
        'yoloBoxes': false,
        'yoloLabels': false,
        'yoloTrafficLights': false,
        'yoloStats': false,
      };

      bool readBool(Map<String, dynamic> source, String key, bool fallback) {
        final value = source[key];
        if (value is bool) return value;
        if (value is num) return value != 0;
        if (value is String) {
          final norm = value.trim().toLowerCase();
          if (norm == 'true' || norm == '1') return true;
          if (norm == 'false' || norm == '0') return false;
        }
        return fallback;
      }

      void applyMap(Map<String, dynamic> map) {
        if (!mounted) {
          _debugShowArOverlay =
              readBool(map, 'arOverlay', defaults['arOverlay']!);
          _debugPushNativeArScene =
              readBool(map, 'nativeArScene', defaults['nativeArScene']!);
          final autoSave = readBool(map, 'arAutoSave', defaults['arAutoSave']!);
          _debugArCaptureEnabled = autoSave;
          _debugArAutoPersistEnabled = autoSave;
          _debugShowPathFill = readBool(map, 'pathFill', defaults['pathFill']!);
          _debugShowLaneLines =
              readBool(map, 'laneLines', defaults['laneLines']!);
          _debugShowRoadEdge = readBool(map, 'roadEdge', defaults['roadEdge']!);
          _debugShowLead1 = readBool(map, 'lead1', defaults['lead1']!);
          _debugShowLead2 = readBool(map, 'lead2', defaults['lead2']!);
          _debugShowRadarBadge =
              readBool(map, 'radarBadge', defaults['radarBadge']!);
          _debugShowRadarVector =
              readBool(map, 'radarVector', defaults['radarVector']!);
          _debugShowStopDistanceTf =
              readBool(map, 'stopDistanceTf', defaults['stopDistanceTf']!);
          _debugShowStateText =
              readBool(map, 'stateText', defaults['stateText']!);
          _debugYoloEnabled =
              readBool(map, 'yoloEnabled', defaults['yoloEnabled']!);
          _debugYoloBoxes = readBool(map, 'yoloBoxes', defaults['yoloBoxes']!);
          _debugYoloLabels =
              readBool(map, 'yoloLabels', defaults['yoloLabels']!);
          _debugYoloTrafficLights = readBool(
            map,
            'yoloTrafficLights',
            defaults['yoloTrafficLights']!,
          );
          _debugYoloStats = readBool(map, 'yoloStats', defaults['yoloStats']!);
          return;
        }

        _safeSetState(() {
          _debugShowArOverlay =
              readBool(map, 'arOverlay', defaults['arOverlay']!);
          _debugPushNativeArScene =
              readBool(map, 'nativeArScene', defaults['nativeArScene']!);
          final autoSave = readBool(map, 'arAutoSave', defaults['arAutoSave']!);
          _debugArCaptureEnabled = autoSave;
          _debugArAutoPersistEnabled = autoSave;
          _debugShowPathFill = readBool(map, 'pathFill', defaults['pathFill']!);
          _debugShowLaneLines =
              readBool(map, 'laneLines', defaults['laneLines']!);
          _debugShowRoadEdge = readBool(map, 'roadEdge', defaults['roadEdge']!);
          _debugShowLead1 = readBool(map, 'lead1', defaults['lead1']!);
          _debugShowLead2 = readBool(map, 'lead2', defaults['lead2']!);
          _debugShowRadarBadge =
              readBool(map, 'radarBadge', defaults['radarBadge']!);
          _debugShowRadarVector =
              readBool(map, 'radarVector', defaults['radarVector']!);
          _debugShowStopDistanceTf =
              readBool(map, 'stopDistanceTf', defaults['stopDistanceTf']!);
          _debugShowStateText =
              readBool(map, 'stateText', defaults['stateText']!);
          _debugYoloEnabled =
              readBool(map, 'yoloEnabled', defaults['yoloEnabled']!);
          _debugYoloBoxes = readBool(map, 'yoloBoxes', defaults['yoloBoxes']!);
          _debugYoloLabels =
              readBool(map, 'yoloLabels', defaults['yoloLabels']!);
          _debugYoloTrafficLights = readBool(
            map,
            'yoloTrafficLights',
            defaults['yoloTrafficLights']!,
          );
          _debugYoloStats = readBool(map, 'yoloStats', defaults['yoloStats']!);
        });
      }

      final initialized = prefs.getBool(
            _LiveDriveCanvasScreenState._hudDebugLayerTogglesInitPrefKey,
          ) ??
          false;
      if (!initialized) {
        applyMap(Map<String, dynamic>.from(defaults));
        unawaited(_pushNativeYoloConfig(force: true));
        await prefs.setString(
          _LiveDriveCanvasScreenState._hudDebugLayerTogglesPrefKey,
          jsonEncode(defaults),
        );
        await prefs.setBool(
          _LiveDriveCanvasScreenState._hudDebugLayerTogglesInitPrefKey,
          true,
        );
        return;
      }

      final raw = prefs.getString(
        _LiveDriveCanvasScreenState._hudDebugLayerTogglesPrefKey,
      );
      if (raw == null || raw.trim().isEmpty) {
        applyMap(Map<String, dynamic>.from(defaults));
        unawaited(_pushNativeYoloConfig(force: true));
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        applyMap(Map<String, dynamic>.from(defaults));
        unawaited(_pushNativeYoloConfig(force: true));
        return;
      }
      applyMap(Map<String, dynamic>.from(decoded));
      unawaited(_pushNativeYoloConfig(force: true));
    } catch (_) {}
  }

  Future<void> _saveHudDebugLayerTogglesImpl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, bool>{
        'arOverlay': _debugShowArOverlay,
        'nativeArScene': _debugPushNativeArScene,
        'arAutoSave': _debugArCaptureEnabled && _debugArAutoPersistEnabled,
        'pathFill': _debugShowPathFill,
        'laneLines': _debugShowLaneLines,
        'roadEdge': _debugShowRoadEdge,
        'lead1': _debugShowLead1,
        'lead2': _debugShowLead2,
        'radarBadge': _debugShowRadarBadge,
        'radarVector': _debugShowRadarVector,
        'stopDistanceTf': _debugShowStopDistanceTf,
        'stateText': _debugShowStateText,
        'yoloEnabled': _debugYoloEnabled,
        'yoloBoxes': _debugYoloBoxes,
        'yoloLabels': _debugYoloLabels,
        'yoloTrafficLights': _debugYoloTrafficLights,
        'yoloStats': _debugYoloStats,
      };
      await prefs.setString(
        _LiveDriveCanvasScreenState._hudDebugLayerTogglesPrefKey,
        jsonEncode(payload),
      );
      await prefs.setBool(
        _LiveDriveCanvasScreenState._hudDebugLayerTogglesInitPrefKey,
        true,
      );
    } catch (_) {}
  }

  void _onLayerToggleChangedImpl(
    StateSetter setLocalState,
    VoidCallback update,
  ) {
    _safeSetState(update);
    setLocalState(() {});
    unawaited(_saveHudDebugLayerToggles());
    unawaited(_pushNativeYoloConfig(force: true));
  }

  void _cacheOverlaySnapshot(_DriveOverlaySnapshot snapshot) {
    _latestOverlaySnapshot = snapshot;
    final modelFrameId = snapshot.modelFrameId;
    if (modelFrameId == null || modelFrameId < 0) return;
    if (!_overlayByModelFrame.containsKey(modelFrameId)) {
      _overlayFrameOrder.addLast(modelFrameId);
    }
    _overlayByModelFrame[modelFrameId] = snapshot;
    while (_overlayFrameOrder.length >
        _LiveDriveCanvasScreenState._overlayFrameBufferSize) {
      final drop = _overlayFrameOrder.removeFirst();
      _overlayByModelFrame.remove(drop);
    }
  }

  _DriveOverlaySnapshot? _findSyncedSnapshot(
    int cameraFrameId, {
    required int maxDelta,
  }) {
    final exact = _overlayByModelFrame[cameraFrameId];
    if (exact != null) return exact;
    for (var delta = 1; delta <= maxDelta; delta++) {
      final lo = _overlayByModelFrame[cameraFrameId - delta];
      if (lo != null) return lo;
      final hi = _overlayByModelFrame[cameraFrameId + delta];
      if (hi != null) return hi;
    }
    return null;
  }

  void _tickOverlayDebugMetrics(_DriveOverlaySnapshot next, DateTime now) {
    final nowMs = now.millisecondsSinceEpoch;
    if (_overlayDebugWindowStartMs <= 0) {
      _overlayDebugWindowStartMs = nowMs;
      _overlayDebugWindowFrames = 0;
    }
    _overlayDebugWindowFrames += 1;
    final elapsed = nowMs - _overlayDebugWindowStartMs;
    if (elapsed >= 1000) {
      _overlayDebugFps = (_overlayDebugWindowFrames * 1000.0) / elapsed;
      _overlayDebugWindowStartMs = nowMs;
      _overlayDebugWindowFrames = 0;
    }

    final modelFrame = next.modelFrameId;
    if (modelFrame != null) {
      final prev = _overlayPrevModelFrameId;
      if (prev != null && modelFrame > prev + 1) {
        _overlayDropCount += (modelFrame - prev - 1);
      }
      _overlayPrevModelFrameId = modelFrame;
    }

    final camFrame = _cameraFrameIdFromSnapshot(next);
    if (modelFrame != null && camFrame != null) {
      _overlayModelCameraGap = (modelFrame - camFrame).abs();
    }
  }

  int? _cameraFrameIdFromSnapshot(_DriveOverlaySnapshot snapshot) {
    if (_liveCameraKind == _DriveCameraKind.wideRoad) {
      return snapshot.wideRoadFrameId ?? snapshot.roadFrameId;
    }
    return snapshot.roadFrameId;
  }

  void _applyOverlaySnapshot(
    _DriveOverlaySnapshot snapshot, {
    bool forceNativePush = false,
  }) {
    if (snapshot.modelFrameId == null &&
        snapshot.path.length < 2 &&
        snapshot.debugPlot == null) {
      _clearDebugPlotState();
    }
    final decorated = snapshot.copyWith(animationPhase: _pathAnimationPhase);
    _overlayNotifier.value = decorated;
    _refreshOverlayVerify(decorated, force: forceNativePush);
    if (_useNativeOverlayRenderer) {
      unawaited(
        _pushNativeOverlay(decorated, force: forceNativePush),
      );
    }
  }

  Future<void> _clearNativeOverlay() async {
    final viewId = _nativeCameraViewId;
    if (viewId == null) return;
    try {
      await _LiveDriveCanvasScreenState._nativeCameraControlChannel
          .invokeMethod<bool>(
        'clearOverlay',
        <String, dynamic>{'viewId': viewId},
      );
      _lastNativeOverlaySignature = null;
      _lastNativeOverlayHadPayload = false;
      _lastNativeArSceneSignature = null;
      _lastNativeArSceneHadPayload = false;
    } catch (_) {}
  }

  int _buildOverlaySignature(_DriveOverlaySnapshot snapshot) {
    final cameraFrameId = _liveCameraKind == _DriveCameraKind.wideRoad
        ? (snapshot.wideRoadFrameId ?? snapshot.roadFrameId ?? -1)
        : (snapshot.roadFrameId ?? snapshot.wideRoadFrameId ?? -1);
    final animBucket = _isAnimatedPathMode(snapshot.pathMode)
        ? (snapshot.animationPhase * 10.0).round()
        : 0;
    return Object.hashAll(<Object?>[
      snapshot.modelFrameId ?? -1,
      cameraFrameId,
      snapshot.pathMode,
      snapshot.pathColor,
      snapshot.leftLaneLine,
      snapshot.rightLaneLine,
      snapshot.path.length,
      snapshot.laneLines.length,
      snapshot.roadEdges.length,
      snapshot.navPathPoints.length,
      snapshot.navTurnInfo,
      (snapshot.navDistToTurn ?? -1.0).round(),
      snapshot.navMainText,
      animBucket,
      _debugPlotState.version,
      _debugPlotState.mode,
      _nativeOverlaySize.width.round(),
      _nativeOverlaySize.height.round(),
      _nativeOverlayVisibleViewportRect.left.round(),
      _nativeOverlayVisibleViewportRect.top.round(),
      _nativeOverlayVisibleViewportRect.width.round(),
      _nativeOverlayVisibleViewportRect.height.round(),
      _liveCameraKind.index,
      _coverViewport ? 1 : 0,
    ]);
  }

  int? _buildArSceneSignature(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    try {
      return jsonEncode(payload).hashCode;
    } catch (_) {
      return payload.toString().hashCode;
    }
  }

  YoloDebugSettings _currentYoloDebugSettings() {
    return YoloDebugSettings(
      enabled: _debugYoloEnabled,
      showBoxes: _debugYoloBoxes,
      showLabels: _debugYoloLabels,
      showTrafficLights: _debugYoloTrafficLights,
      showStats: _debugYoloStats,
    );
  }

  Map<String, dynamic> _buildNativeYoloConfigPayload({
    required YoloDebugSettings settings,
  }) {
    return <String, dynamic>{
      ...settings.toJson(),
      'runtimeBackend': 'executorch_qnn',
      'modelVariant': 'yolo26n',
      'camera': _liveCameraName,
      'sourceWidth': _cameraSourceSize.width.round(),
      'sourceHeight': _cameraSourceSize.height.round(),
      'inputWidth': 416,
      'inputHeight': 416,
      'samplePeriodMs': 200,
    };
  }

  int _buildYoloConfigSignature(Map<String, dynamic> payload) {
    try {
      return jsonEncode(payload).hashCode;
    } catch (_) {
      return payload.toString().hashCode;
    }
  }

  Future<void> _pushNativeYoloConfig({bool force = false}) async {
    final viewId = _nativeCameraViewId;
    if (viewId == null) {
      _lastNativeYoloConfigSignature = null;
      return;
    }
    final settings = (_openpilotOverlayMode && _useNativeLiveCamera)
        ? _currentYoloDebugSettings()
        : YoloDebugSettings.empty;
    final payload = _buildNativeYoloConfigPayload(settings: settings);
    final signature = _buildYoloConfigSignature(payload);
    if (!force && _lastNativeYoloConfigSignature == signature) {
      return;
    }
    try {
      final ok = await _LiveDriveCanvasScreenState._nativeCameraControlChannel
          .invokeMethod<bool>(
        'updateYoloConfig',
        <String, dynamic>{
          'viewId': viewId,
          'yoloConfig': payload,
        },
      );
      if (ok == true) {
        _lastNativeYoloConfigSignature = signature;
      }
    } catch (_) {}
  }

  void _refreshOverlayVerify(
    _DriveOverlaySnapshot snapshot, {
    bool force = false,
  }) {
    if (!_overlayVerifyMode || !_debugShowVerifyPanel || !mounted) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    if (!force &&
        (nowUs - _lastOverlayVerifyUpdateUs) <
            _LiveDriveCanvasScreenState._overlayVerifyIntervalUs) {
      return;
    }
    _lastOverlayVerifyUpdateUs = nowUs;
    final canvasSize =
        (_nativeOverlaySize.width > 1 && _nativeOverlaySize.height > 1)
            ? _nativeOverlaySize
            : const Size(1928, 1208);
    final text = _DriveOverlayPainter.buildProjectionDebugText(
      snapshot: snapshot,
      sourceSize: _cameraSourceSize,
      cameraKind: _liveCameraKind,
      canvasSize: canvasSize,
      coverViewport: _coverViewport,
      viewportZoom: _viewportPlacementZoom,
      cameraSourceLabel: 'live',
    );
    if (!mounted) return;
    if (_overlayVerifyText != text) {
      _safeSetState(() => _overlayVerifyText = text);
    }
  }

  Future<void> _pushNativeOverlay(
    _DriveOverlaySnapshot snapshot, {
    bool force = false,
  }) async {
    if (!_openpilotOverlayMode) {
      await _clearNativeOverlay();
      _lastNativeOverlaySignature = null;
      _lastNativeOverlayHadPayload = false;
      _lastNativeArSceneSignature = null;
      _lastNativeArSceneHadPayload = false;
      return;
    }
    if (!_debugShowArOverlay) {
      if (_lastNativeOverlayHadPayload) {
        await _clearNativeOverlay();
      }
      _lastNativeOverlaySignature = null;
      _lastNativeOverlayHadPayload = false;
      _lastNativeArSceneSignature = null;
      _lastNativeArSceneHadPayload = false;
      return;
    }
    if (!_useNativeOverlayRenderer) return;
    final viewId = _nativeCameraViewId;
    if (viewId == null) return;
    if (_nativeOverlaySize.width <= 1 || _nativeOverlaySize.height <= 1) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    if (!force &&
        (nowUs - _lastNativeOverlayPushUs) <
            _LiveDriveCanvasScreenState._nativeOverlayPushIntervalUs) {
      return;
    }
    final signature = _buildOverlaySignature(snapshot);
    final shouldBuildLiveArScenePayload =
        _debugPushNativeArScene || _debugArCaptureEnabled || _debugArReplayMode;
    final liveArScenePayload = shouldBuildLiveArScenePayload
        ? _DriveOverlayPainter.buildArScenePayload(
            snapshot: snapshot,
            sourceSize: _cameraSourceSize,
            cameraKind: _liveCameraKind,
            canvasSize: _nativeOverlaySize,
            coverViewport: _coverViewport,
            viewportZoom: _viewportPlacementZoom,
            visibleViewportRect: _nativeOverlayVisibleViewportRect,
          )
        : null;
    final arScenePayload = _debugArReplayMode
        ? (_activeArReplayFrame?.arScenePayload ?? liveArScenePayload)
        : (_debugPushNativeArScene ? liveArScenePayload : null);
    final arSceneSignature = _buildArSceneSignature(arScenePayload);
    final arSceneHadPayload = arScenePayload != null;
    if (!force &&
        !_isAnimatedPathMode(snapshot.pathMode) &&
        _lastNativeOverlaySignature == signature &&
        _lastNativeArSceneSignature == arSceneSignature) {
      return;
    }
    final payload = _DriveOverlayPainter.buildNativeOverlayPayload(
      snapshot: snapshot,
      sourceSize: _cameraSourceSize,
      cameraKind: _liveCameraKind,
      canvasSize: _nativeOverlaySize,
      coverViewport: _coverViewport,
      viewportZoom: _viewportPlacementZoom,
      visibleViewportRect: _nativeOverlayVisibleViewportRect,
      showDebugGuides: _overlayVerifyMode && _debugShowGuides,
      showPathFill: _debugShowPathFill,
      showLaneLines: _debugShowLaneLines,
      showRoadEdge: _debugShowRoadEdge,
      showLead1: _debugShowLead1,
      showLead2: _debugShowLead2,
      showRadarBadge: _debugShowRadarBadge,
      showRadarVector: _debugShowRadarVector,
      showStopDistanceTf: _debugShowStopDistanceTf,
      showStateText: _debugShowStateText,
      debugPlotState: _debugPlotState,
    );
    final overlayHadPayload = payload != null;
    if (!force &&
        _lastNativeOverlaySignature == signature &&
        _lastNativeOverlayHadPayload == overlayHadPayload &&
        _lastNativeArSceneSignature == arSceneSignature &&
        _lastNativeArSceneHadPayload == arSceneHadPayload) {
      return;
    }
    _lastNativeOverlayPushUs = nowUs;
    try {
      if (payload == null) {
        await _LiveDriveCanvasScreenState._nativeCameraControlChannel
            .invokeMethod<bool>(
          'clearOverlay',
          <String, dynamic>{'viewId': viewId},
        );
      } else {
        await _LiveDriveCanvasScreenState._nativeCameraControlChannel
            .invokeMethod<bool>(
          'updateOverlay',
          <String, dynamic>{
            'viewId': viewId,
            'overlay': payload,
            'arScene': arScenePayload,
          },
        );
      }
      _lastNativeOverlaySignature = signature;
      _lastNativeOverlayHadPayload = overlayHadPayload;
      _lastNativeArSceneSignature = arSceneSignature;
      _lastNativeArSceneHadPayload = arSceneHadPayload;
      if (!_debugArReplayMode &&
          _debugArCaptureEnabled &&
          liveArScenePayload != null) {
        await _captureArReplayFrame(
          arScenePayload: liveArScenePayload,
          viewId: viewId,
        );
      }
    } catch (_) {}
  }

  void _publishOverlaySynced() {
    if (!mounted) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    final cameraFrameId = _lastCameraFrameId;
    if (cameraFrameId == null) {
      if (_tryPublishLatestOverlayDuringStartup(nowUs)) {
        return;
      }
      if (_LiveDriveCanvasScreenState._strictFrameLock) {
        if (_lastPublishedModelFrameId != null &&
            (nowUs - math.max(_lastOverlayPublishUs, _lastSyncHitUs)) >
                _LiveDriveCanvasScreenState._strictFrameHoldUs) {
          if (_holdLastGoodOverlayWhileStale(
            nowUs: nowUs,
            reason: '카메라 프레임 동기화 대기 중',
          )) {
            return;
          }
        }
        return;
      }
      _clearOverlayStaleState();
      _recordDebugPlotSample(_latestOverlaySnapshot);
      _setRenderTarget(_latestOverlaySnapshot, nowUs: nowUs);
      _lastPublishedModelFrameId = _latestOverlaySnapshot.modelFrameId;
      return;
    }

    final synced = _findSyncedSnapshot(
      cameraFrameId,
      maxDelta: _overlaySyncMaxDeltaCurrent,
    );
    if (synced == null) {
      if (_tryPublishLatestOverlayDuringStartup(nowUs)) {
        return;
      }
      // If exact sync is temporarily unavailable, keep using the newest model
      // snapshot so path/lane rendering doesn't disappear entirely.
      if (_latestOverlaySnapshot.path.length >= 2 &&
          _latestOverlaySnapshot.modelFrameId != null &&
          _lastPublishedModelFrameId == null) {
        _clearOverlayStaleState();
        _recordDebugPlotSample(_latestOverlaySnapshot);
        _setRenderTarget(_latestOverlaySnapshot, nowUs: nowUs);
        _lastPublishedModelFrameId = _latestOverlaySnapshot.modelFrameId;
        return;
      }
      if (_LiveDriveCanvasScreenState._strictFrameLock &&
          _lastPublishedModelFrameId != null &&
          (nowUs - math.max(_lastOverlayPublishUs, _lastSyncHitUs)) >
              _LiveDriveCanvasScreenState._strictFrameHoldUs) {
        if (_holdLastGoodOverlayWhileStale(
          nowUs: nowUs,
          reason: '모델/카메라 프레임 정합 재시도 중',
        )) {
          return;
        }
      }
      return;
    }
    final modelFrameId = synced.modelFrameId;
    if (_lastPublishedModelFrameId != null &&
        modelFrameId != null &&
        modelFrameId < (_lastPublishedModelFrameId! - 1)) {
      return;
    }
    if (modelFrameId != null && modelFrameId == _lastPublishedModelFrameId) {
      return;
    }
    _lastSyncHitUs = nowUs;
    _clearOverlayStaleState();
    _recordDebugPlotSample(synced);
    _setRenderTarget(synced, nowUs: nowUs);
    _lastPublishedModelFrameId = modelFrameId;
  }

  void _setRenderTarget(_DriveOverlaySnapshot next, {required int nowUs}) {
    final prevArrival = _lastSyncedArrivalUs;
    if (prevArrival > 0) {
      final dt = nowUs - prevArrival;
      if (dt > 5000 && dt < 300000) {
        _smoothedSyncIntervalUs =
            (_smoothedSyncIntervalUs * 0.85) + (dt.toDouble() * 0.15);
      }
    }
    _lastSyncedArrivalUs = nowUs;
    _lastOverlayPublishUs = nowUs;
    _renderFromSnapshot = _overlayNotifier.value;
    _renderToSnapshot = next;
    _renderInterpStartUs = nowUs;
    _renderInterpDurationUs = (_smoothedSyncIntervalUs * 0.8).round().clamp(
        _LiveDriveCanvasScreenState._interpMinUs,
        _LiveDriveCanvasScreenState._interpMaxUs);
    _renderInterpActive = true;
    _renderTicker ??= createTicker(_onRenderTick)..start();
  }

  void _advancePathAnimationTick({
    required int nowUs,
    required _DriveOverlaySnapshot snapshot,
  }) {
    if (!_isAnimatedPathMode(snapshot.pathMode) || snapshot.path.length < 2) {
      _pathAnimationPhase = 0.0;
      _pathAnimationSeq2 = -1;
      _pathAnimationForward = true;
      _lastPathAnimationTickUs = nowUs;
      return;
    }

    final prevTickUs = _lastPathAnimationTickUs;
    _lastPathAnimationTickUs = nowUs;
    var dtUs = 50000.0;
    if (prevTickUs > 0) {
      dtUs = (nowUs - prevTickUs).toDouble();
    }
    dtUs = dtUs.clamp(4000.0, 120000.0);
    final tickScale = dtUs / 50000.0; // openpilot UI(20Hz) 湲곗? ?ㅼ???

    final speedKph = snapshot.speedKph ?? ((snapshot.speedMps ?? 0.0) * 3.6);
    final seq = math.max(0.3, speedKph / 100.0);
    final maxSeq = _estimateAnimatedMaxSeq(snapshot);
    final accel = snapshot.aEgo;
    if (accel < -1.0) {
      _pathAnimationForward = false;
    } else if (accel > -0.5) {
      _pathAnimationForward = true;
    }
    final step = seq * tickScale;
    if (_pathAnimationForward) {
      _pathAnimationPhase += step;
      if (_pathAnimationPhase > maxSeq) {
        _pathAnimationPhase =
            _pathAnimationSeq2 >= 0 ? _pathAnimationSeq2.toDouble() : 0.0;
      }
    } else {
      _pathAnimationPhase -= step;
      if (_pathAnimationPhase < 0.0) {
        _pathAnimationPhase = _pathAnimationSeq2 >= 0
            ? _pathAnimationSeq2.toDouble()
            : maxSeq.toDouble();
      }
    }
    _pathAnimationSeq2 = (maxSeq > 15)
        ? ((_pathAnimationPhase.floor() - (maxSeq ~/ 2) + maxSeq) % maxSeq)
        : -5;
    if (_pathAnimationPhase.abs() > 1000000.0) {
      _pathAnimationPhase = _pathAnimationPhase % maxSeq.toDouble();
    }
  }

  int _estimateAnimatedMaxSeq(_DriveOverlaySnapshot snapshot) {
    final modelMax = snapshot.path.x.isNotEmpty ? snapshot.path.x.last : 0.0;
    final maxDistance = modelMax.clamp(10.0, 100.0);
    var dist = 2.0;
    var count = 0;
    while (true) {
      if (dist >= maxDistance) {
        count++;
        break;
      }
      count++;
      dist += dist * 0.15;
      if (count > 256) break;
    }
    final maxSeq = math.min((count ~/ 2) + 3, 16);
    return math.max(1, maxSeq);
  }

  void _onRenderTick(Duration _) {
    if (!mounted) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    final tickSnapshot =
        _renderInterpActive ? _renderToSnapshot : _overlayNotifier.value;
    _advancePathAnimationTick(nowUs: nowUs, snapshot: tickSnapshot);
    if (!_renderInterpActive) {
      if (_useNativeOverlayRenderer) {
        final current = _overlayNotifier.value;
        if (current.path.length >= 2 && _isAnimatedPathMode(current.pathMode)) {
          _applyOverlaySnapshot(current);
        }
      } else if (_isAnimatedPathMode(_overlayNotifier.value.pathMode)) {
        _applyOverlaySnapshot(_overlayNotifier.value);
      }
      return;
    }
    final elapsedUs = nowUs - _renderInterpStartUs;
    if (elapsedUs >= _renderInterpDurationUs) {
      _applyOverlaySnapshot(_renderToSnapshot);
      _renderInterpActive = false;
      return;
    }
    final t = elapsedUs / _renderInterpDurationUs;
    _applyOverlaySnapshot(
      _DriveOverlaySnapshot.interpolate(
          _renderFromSnapshot, _renderToSnapshot, t),
    );
  }

  void _handleCameraFrameEvent(
    int frameId, {
    required String source,
    _DriveCameraKind? cameraKind,
  }) {
    if (frameId < 0) return;
    if (cameraKind != null && cameraKind != _liveCameraKind) {
      // Drop stale frame events from a camera stream that is no longer active.
      return;
    }
    _lastCameraFrameId = frameId;
    _lastCameraFrameEventUs = _renderClock.elapsedMicroseconds;
    if (mounted && _cameraLoading) {
      _safeSetState(() {
        _cameraLoading = false;
      });
    } else if (!mounted && _cameraLoading) {
      _cameraLoading = false;
    }
    _publishOverlaySynced();
    if (_startupProvisionalSyncActive) {
      _startupNativeFrameSettleCount += 1;
      final synced = _findSyncedSnapshot(
        frameId,
        maxDelta: _overlaySyncMaxDeltaCurrent,
      );
      if (synced != null ||
          _startupNativeFrameSettleCount >=
              _LiveDriveCanvasScreenState._startupProvisionalNativeSettleFrames) {
        _endStartupProvisionalSync(reason: 'native_frame_stable');
      }
    }
    if (frameId % 60 == 0) {
      debugPrint(
        '[DriveCanvas][sync] cameraFrame=$frameId source=$source cam=$_liveCameraName',
      );
    }
  }
}
