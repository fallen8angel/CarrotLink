part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasLifecycleComponents on _LiveDriveCanvasScreenState {
  void _suspendForBackground() {
    _cancelLifecycleSuspendTimer();
    if (_cameraSuspendedByLifecycle) return;
    debugPrint('[DriveCanvas][lifecycle] suspend');
    _clearSidecarRecoverySchedule();
    _cameraSuspendedByLifecycle = true;
    _backgroundUiResetDone = false;
    _stopAdaptiveCameraQualityLoop();
    unawaited(
      _setDisplayHighRefreshPreference(false, reason: 'drive_background'),
    );
    _scheduleDelayedSidecarStop();
    _scheduleBackgroundUiReset();
  }

  void _resumeFromBackground() {
    _cancelLifecycleSuspendTimer();
    _cancelDelayedSidecarStop();
    _cancelBackgroundUiResetTimer();
    if (!_cameraSuspendedByLifecycle) return;
    debugPrint('[DriveCanvas][lifecycle] resume');
    _cameraSuspendedByLifecycle = false;
    unawaited(_lockLandscapeOrientations());
    unawaited(
      _setDisplayHighRefreshPreference(true, reason: 'drive_resume'),
    );
    if (!_backgroundUiResetDone) {
      if (_openpilotOverlayMode) {
        _startAdaptiveCameraQualityLoop();
        if (!_sidecarConnected) {
          unawaited(_ensureSidecarRuntime(reason: 'resume_quick'));
        } else {
          _setSidecarPhase(_SidecarPhase.running, message: '사이드카 실행 중');
        }
      } else {
        unawaited(_loadCameraSource(force: false));
      }
      return;
    }
    _applyHudModeRuntime();
  }

  void _scheduleSuspendForBackground() {
    if (_cameraSuspendedByLifecycle) return;
    _cancelLifecycleSuspendTimer();
    _lifecycleSuspendTimer = Timer(_LiveDriveCanvasScreenState._lifecycleSuspendDelay, () {
      _lifecycleSuspendTimer = null;
      if (!mounted) return;
      _suspendForBackground();
    });
  }

  void _cancelLifecycleSuspendTimer() {
    _lifecycleSuspendTimer?.cancel();
    _lifecycleSuspendTimer = null;
  }

  void _cancelDelayedSidecarStop() {
    _sidecarProcessStopTimer?.cancel();
    _sidecarProcessStopTimer = null;
  }

  void _cancelBackgroundUiResetTimer() {
    _backgroundUiResetTimer?.cancel();
    _backgroundUiResetTimer = null;
  }

  void _scheduleBackgroundUiReset() {
    _cancelBackgroundUiResetTimer();
    _backgroundUiResetTimer = Timer(_LiveDriveCanvasScreenState._backgroundUiResetGrace, () {
      _backgroundUiResetTimer = null;
      if (!mounted || !_cameraSuspendedByLifecycle) return;
      _backgroundUiResetDone = true;
      _performBackgroundUiReset();
    });
  }

  void _performBackgroundUiReset() {
    _stopSidecarLoop();
    _lastCameraFrameId = null;
    _lastCameraFrameEventUs = 0;
    _lastPublishedModelFrameId = null;
    _lastSyncHitUs = 0;
    _lastSyncedArrivalUs = 0;
    _latestOverlaySnapshot = const _DriveOverlaySnapshot.empty();
    _overlayByModelFrame.clear();
    _overlayFrameOrder.clear();
    _pathAnimationPhase = 0.0;
    _pathAnimationSeq2 = -1;
    _pathAnimationForward = true;
    _lastPathAnimationTickUs = 0;
    _renderInterpActive = false;
    _applyOverlaySnapshot(
      const _DriveOverlaySnapshot.empty(),
      forceNativePush: true,
    );
    unawaited(_clearNativeOverlay());
    _cameraSourceKey = null;
    _nativeCameraViewId = null;
    unawaited(_unloadWebCameraSurface());
    if (mounted) {
      _safeSetState(() {
        _nativeCameraViewId = null;
        _cameraLoading = false;
        _cameraError = null;
      });
    }
  }

  void _scheduleDelayedSidecarStop() {
    _cancelDelayedSidecarStop();
    if (_LiveDriveCanvasScreenState._residentSidecarManaged) {
      _pushSidecarHistory(
          'BG_KEEPALIVE', 'resident mode: process stop skipped');
      return;
    }
    if (!_openpilotOverlayMode) {
      unawaited(_stopSidecarProcessIfNeeded());
      return;
    }
    _pushSidecarHistory(
      'BG_KEEPALIVE',
      'defer stop ${_LiveDriveCanvasScreenState._backgroundProcessKeepAlive.inSeconds}s',
    );
    _sidecarProcessStopTimer = Timer(_LiveDriveCanvasScreenState._backgroundProcessKeepAlive, () {
      _sidecarProcessStopTimer = null;
      if (!mounted || !_cameraSuspendedByLifecycle) return;
      _setSidecarPhase(
        _SidecarPhase.stopping,
        message: '백그라운드 유지 시간이 지나 사이드카를 중지합니다.',
      );
      _stopSidecarLoop();
      unawaited(_stopSidecarProcessIfNeeded());
    });
  }


  Future<void> _restorePortraitOrientationImpl() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }

  Future<void> _setDisplayHighRefreshPreferenceImpl(
    bool enabled, {
    required String reason,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final response = await _LiveDriveCanvasScreenState._displayTuningChannel
          .invokeMapMethod<String, dynamic>(
        'setHighRefreshPreferred',
        <String, dynamic>{'enabled': enabled},
      );
      final appliedHz = (response?['refreshRate'] as num?)?.toDouble();
      debugPrint(
        '[DriveCanvas][display] high_refresh=$enabled reason=$reason hz=${appliedHz?.toStringAsFixed(1) ?? '-'}',
      );
    } on MissingPluginException {
      // Older builds may not expose display tuning channel yet.
    } catch (e) {
      debugPrint(
        '[DriveCanvas][display] high refresh preference failed: $e',
      );
    }
  }

  Future<void> _enableScreenAwakeImpl() async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  Future<void> _disableScreenAwakeImpl() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }

  Future<void> _loadAndApplyLandscapeOrientationImpl() async {
    await _lockLandscapeOrientations();
  }


  Future<void> _lockLandscapeOrientationsImpl() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _exitScreenImpl() async {
    await _restorePortraitOrientation();
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }
}
