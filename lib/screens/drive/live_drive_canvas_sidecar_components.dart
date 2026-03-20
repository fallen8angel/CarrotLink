part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasSidecarComponents on _LiveDriveCanvasScreenState {
  void _attachSharedOverlayRuntime(SharedRuntimeManager runtime) {
    if (identical(_sharedRuntimeManager, runtime)) {
      return;
    }
    _detachSharedOverlayRuntime();
    _sharedRuntimeManager = runtime;
    runtime.overlayStreamListenable
        .addListener(_handleSharedOverlayRuntimeTick);
    _syncSharedOverlayRuntime(seedBufferedFrames: true);
  }

  void _detachSharedOverlayRuntime() {
    final runtime = _sharedRuntimeManager;
    if (runtime != null) {
      runtime.overlayStreamListenable
          .removeListener(_handleSharedOverlayRuntimeTick);
    }
    _overlayDisconnectDebounce?.cancel();
    _overlayDisconnectDebounce = null;
    _sharedRuntimeManager = null;
  }

  void _handleSharedOverlayRuntimeTick() {
    if (!mounted || _isDisposing) {
      return;
    }
    _syncSharedOverlayRuntime(seedBufferedFrames: false);
  }

  void _syncSharedOverlayRuntime({
    required bool seedBufferedFrames,
  }) {
    if (_isDisposing) {
      return;
    }
    final runtime = _sharedRuntimeManager;
    if (runtime == null) {
      _overlayDisconnectDebounce?.cancel();
      _overlayDisconnectDebounce = null;
      _applySidecarConnectionState(false, allowRecovery: false);
      return;
    }

    final sameHost = runtime.overlayHost == _hostIp;
    final effectiveConnected =
        _openpilotOverlayMode && sameHost && runtime.overlayConnected;

    if (effectiveConnected) {
      // Connected — cancel any pending disconnect debounce immediately.
      _overlayDisconnectDebounce?.cancel();
      _overlayDisconnectDebounce = null;
      _applySidecarConnectionState(
        true,
        allowRecovery: _openpilotOverlayMode,
        provisionalReason: seedBufferedFrames
            ? 'shared_overlay_seed'
            : 'shared_overlay_update',
      );
    } else {
      // Not yet connected — debounce before propagating to avoid flashing
      // "사이드카 연결 대기" for brief WS reconnects (~350 ms).
      // While _sidecarAutoManaging is true (profile switch / runtime ensure
      // in progress), suppress the debounce entirely — the runtime ensure
      // path will reconnect once the switch completes and firing the
      // debounce mid-switch would needlessly reset camera + trigger a
      // recovery cycle.
      if (!_sidecarAutoManaging) {
        _overlayDisconnectDebounce ??= Timer(
          const Duration(milliseconds: 2500),
          () {
            _overlayDisconnectDebounce = null;
            if (!mounted) return;
            // If the runtime ensure started while this timer was pending,
            // skip the disconnect cascade — the ensure path owns the
            // lifecycle now.
            if (_sidecarAutoManaging) return;
            _applySidecarConnectionState(
              false,
              allowRecovery: _openpilotOverlayMode,
              provisionalReason: 'shared_overlay_disconnect_debounced',
            );
          },
        );
      }
    }

    if (!sameHost) {
      return;
    }
    if (seedBufferedFrames) {
      for (final frame in runtime.overlayFrameBuffer) {
        _consumeSharedOverlayFrame(frame);
      }
    }
    _consumeSharedOverlayFrame(runtime.latestOverlayFrame);
  }

  void _consumeSharedOverlayFrame(OverlayStreamFrame? frame) {
    if (frame == null || !_openpilotOverlayMode) {
      return;
    }
    if (frame.host != _hostIp) {
      return;
    }
    if (frame.sequence <= _lastConsumedSharedOverlayFrameSequence) {
      return;
    }
    _lastConsumedSharedOverlayFrameSequence = frame.sequence;
    _handleSidecarPayload(Map<String, dynamic>.from(frame.payload));
  }

  void _startSidecarLoop() {
    final runtime = _sharedRuntimeManager;
    if (runtime == null) {
      _applySidecarConnectionState(false, allowRecovery: false);
      return;
    }
    unawaited(
      runtime.ensureOverlayStream(
        forceRestart: false,
        camera: _liveCameraName,
      ),
    );
    _syncSharedOverlayRuntime(seedBufferedFrames: true);
  }

  void _stopSidecarLoop({bool resetSession = true}) {
    _overlayDisconnectDebounce?.cancel();
    _overlayDisconnectDebounce = null;
    _applySidecarConnectionState(false, allowRecovery: false);
    if (resetSession) {
      _lastConsumedSharedOverlayFrameSequence = 0;
    }
  }

  void _applySidecarConnectionState(
    bool next, {
    required bool allowRecovery,
    String provisionalReason = 'sidecar_ws_connected',
  }) {
    if (_isDisposing) {
      _sidecarConnected = next;
      return;
    }
    final changed = _sidecarConnected != next;
    if (changed) {
      _pushSidecarHistory('WS', next ? 'connected' : 'disconnected');
      if (next && _isSidecarBusy) {
        _sidecarTransitionTimer?.cancel();
      }
    }

    if (mounted) {
      _safeSetState(() {
        _sidecarConnected = next;
        if (next) {
          _suppressCameraErrors = false;
          _cameraError = null;
        } else if (_openpilotOverlayMode) {
          _suppressCameraErrors = true;
          _cameraError = null;
          _cameraLoading = _lastCameraFrameId == null;
        }
      });
    } else {
      _sidecarConnected = next;
      if (next) {
        _suppressCameraErrors = false;
        _cameraError = null;
      } else if (_openpilotOverlayMode) {
        _suppressCameraErrors = true;
        _cameraError = null;
        _cameraLoading = _lastCameraFrameId == null;
      }
    }

    if (next) {
      _clearSidecarRecoverySchedule();
      _beginStartupProvisionalSync(reason: provisionalReason);
      if (_openpilotOverlayMode &&
          _profileRequiresLiveRuntime(_currentSidecarProfile) &&
          !_nativeCameraAttachReady) {
        _setNativeCameraAttachReady(true);
        _startCameraErrorGrace(reason: 'shared_runtime_connected');
      }
      if (!_adaptiveCameraQualitySynced) {
        unawaited(
          _setAdaptiveCameraQualityMode(
            _adaptiveCameraQualityMode,
            reason: 'shared_runtime_reconnected',
            force: true,
          ),
        );
      }
      if (_openpilotOverlayMode &&
          !_cameraSuspendedByLifecycle &&
          _nativeCameraAttachReady &&
          _cameraSourceKey == null) {
        unawaited(_loadCameraSource(force: false));
      }
      return;
    }

    if (_openpilotOverlayMode && !_cameraSuspendedByLifecycle) {
      // During a profile switch or runtime ensure the overlay WS
      // disconnects briefly but the camera stream is unaffected.
      // Preserve the camera view to avoid a visible black-screen flash;
      // only tear it down when we are NOT in the middle of a managed
      // lifecycle transition.
      if (!_sidecarAutoManaging) {
        _setNativeCameraAttachReady(false);
      }
      if (allowRecovery) {
        if (!_isSidecarBusy) {
          _scheduleSidecarRuntimeRecovery(
              reason: 'shared_runtime_disconnected');
        }
      } else {
        _setHardSidecarPhase(_SidecarPhase.idle);
      }
      return;
    }

    if (!_openpilotOverlayMode) {
      _setHardSidecarPhase(_SidecarPhase.idle);
    }
  }

  void _handleSidecarPayload(Map<String, dynamic> payload) {
    if (payload['type'] == 'hello') return;
    if (!_openpilotOverlayMode) return;

    final next = _stabilizeOverlaySnapshot(
      _DriveOverlaySnapshot.fromSidecar(payload),
    );
    _syncLiveCameraKind(next);
    _cacheOverlaySnapshot(next);
    _overlayDiagFrames++;
    final now = DateTime.now();
    final inferredCameraFrame = _cameraFrameIdFromSnapshot(next);
    final hasUsableCameraFrame = inferredCameraFrame != null;
    if (!hasUsableCameraFrame && _isOverlaySnapshotRenderable(next)) {
      _beginStartupProvisionalSync(
        reason: 'sidecar_overlay_without_camera_frame',
        windowUs: _LiveDriveCanvasScreenState._cameraFirstFrameDegradedHoldUs,
      );
    }
    if (hasUsableCameraFrame) {
      if (mounted && (_cameraLoading || (_cameraError?.isNotEmpty ?? false))) {
        _safeSetState(() {
          _cameraLoading = false;
          _cameraError = null;
        });
      } else if (!mounted) {
        _cameraLoading = false;
        _cameraError = null;
      }
    }
    _tickOverlayDebugMetrics(next, now);
    if (now.difference(_overlayDiagLastLogAt).inSeconds >= 2) {
      final frameGap = (next.modelFrameId != null && next.roadFrameId != null)
          ? (next.modelFrameId! - next.roadFrameId!).abs()
          : -1;
      final wideGap =
          (next.modelFrameId != null && next.wideRoadFrameId != null)
              ? (next.modelFrameId! - next.wideRoadFrameId!).abs()
              : -1;
      debugPrint(
        '[DriveCanvas][overlay] fps~${(_overlayDiagFrames / 2.0).toStringAsFixed(1)} '
        'pathPts=${next.path.length} lanes=${next.laneLines.length} '
        'edges=${next.roadEdges.length} frameGap=$frameGap wideGap=$wideGap '
        'pathSrc=${next.usingLateralPath ? 'lateral' : 'model'} '
        'mx=${next.modelPathXMax.toStringAsFixed(1)} '
        'lx=${next.lateralPathXMax.toStringAsFixed(1)} '
        'calib=${next.calibrationRpy.length >= 3 ? 1 : 0} '
        'wideCal=${next.wideFromDeviceEuler.length >= 3 ? 1 : 0} '
        'mode=${next.pathMode} color=${next.pathColor} '
        'modelFrame=${next.modelFrameId} roadFrame=${next.roadFrameId} '
        'wideRoadFrame=${next.wideRoadFrameId} cam=$_liveCameraName '
        'viewport=${_coverViewport ? 'cover' : 'contain'}',
      );
      _overlayDiagFrames = 0;
      _overlayDiagLastLogAt = now;
    }
    if (!mounted) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    final cameraStale = _lastCameraFrameEventUs <= 0 ||
        (nowUs - _lastCameraFrameEventUs) >
            _LiveDriveCanvasScreenState._cameraFrameStaleUs;
    if (inferredCameraFrame != null &&
        (_lastCameraFrameId == null ||
            cameraStale ||
            _startupProvisionalSyncActive)) {
      _lastCameraFrameId = inferredCameraFrame;
      if (cameraStale && (nowUs - _lastCameraFallbackLogUs) >= 2000000) {
        _lastCameraFallbackLogUs = nowUs;
        debugPrint(
          '[DriveCanvas][sync] fallback cameraFrame=$inferredCameraFrame via sidecar (native frame event stale)',
        );
      } else if (_startupProvisionalSyncActive &&
          (nowUs - _lastCameraFallbackLogUs) >= 1200000) {
        _lastCameraFallbackLogUs = nowUs;
        debugPrint(
          '[DriveCanvas][sync] provisional cameraFrame=$inferredCameraFrame via sidecar (startup)',
        );
      }
    }
    _publishOverlaySynced();
  }
}
