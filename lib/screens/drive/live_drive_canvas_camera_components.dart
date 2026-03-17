part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasCameraComponents on _LiveDriveCanvasScreenState {
  bool get _cameraErrorGraceActive =>
      _renderClock.elapsedMicroseconds <= _cameraErrorGraceUntilUs;

  bool get _cameraAttachPendingBeforeFirstFrame =>
      _lastCameraFrameId == null &&
      _cameraAttachPhase != _CameraAttachPhase.idle &&
      _cameraAttachPhase != _CameraAttachPhase.streaming;

  void _setCameraAttachPhase(
    _CameraAttachPhase phase, {
    String? reason,
  }) {
    if (_cameraAttachPhase == phase) return;
    _cameraAttachPhase = phase;
    debugPrint(
      '[DriveCanvas][native] attach-phase=${phase.name}${reason == null ? '' : ' reason=$reason'}',
    );
  }

  String? _cameraAttachNoticeMessage() {
    if (!_cameraAttachPendingBeforeFirstFrame) return null;
    return switch (_cameraAttachPhase) {
      _CameraAttachPhase.surfaceReady => '로드카메라 화면을 준비하는 중입니다.',
      _CameraAttachPhase.socketConnecting => '로드카메라 연결 중입니다.',
      _CameraAttachPhase.socketConnected => '카메라 스트림 연결을 확인하는 중입니다.',
      _CameraAttachPhase.waitingFirstFrame => '로드카메라 첫 프레임 대기 중입니다.',
      _CameraAttachPhase.retrying => '로드카메라 연결 재시도 중입니다.',
      _ => null,
    };
  }

  bool _hasRenderableOverlayFallback() {
    return _openpilotOverlayMode &&
        (_lastPublishedModelFrameId != null ||
            _isOverlaySnapshotRenderable(_latestOverlaySnapshot));
  }

  bool _shouldUseDegradedOverlayFallbackUi() {
    if (!_openpilotOverlayMode) return false;
    if (_lastCameraFrameId != null) return false;
    if (!_sidecarConnected) return false;
    if (!_hasRenderableOverlayFallback()) return false;
    if (_cameraAttachStartedUs <= 0) return false;
    final elapsedUs = _renderClock.elapsedMicroseconds - _cameraAttachStartedUs;
    return elapsedUs >= 2200000;
  }

  bool _shouldShowCameraLoadingOverlay() {
    return _cameraLoading && !_shouldUseDegradedOverlayFallbackUi();
  }

  void _forceRestartNativeCameraAttach({
    required String reason,
  }) {
    if (_isDeveloperPlaybackRequested ||
        _cameraSuspendedByLifecycle ||
        !_useNativeLiveCamera) {
      return;
    }
    debugPrint('[DriveCanvas][native] force reattach reason=$reason');
    _appendDriveDiagEvent(
      'camera_first_frame_recover',
      <String, dynamic>{
        'reason': reason,
        'count': _cameraFirstFrameRecoveryCount + 1,
        'hostIp': _hostIp,
        'lastFrameId': _lastCameraFrameId,
        'attachPhase': _cameraAttachPhase.name,
        'nativeDiagState': _lastNativeCameraDiag?['state'],
      },
    );
    _lastCameraFirstFrameRecoveryUs = _renderClock.elapsedMicroseconds;
    _cameraFirstFrameRecoveryCount += 1;
    _beginCameraAttachSession(reason: reason);
    _setCameraAttachPhase(
      _CameraAttachPhase.retrying,
      reason: reason,
    );
    _beginStartupProvisionalSync(
      reason: reason,
      windowUs: _LiveDriveCanvasScreenState._cameraFirstFrameDegradedHoldUs,
    );
    _startCameraErrorGrace(
      reason: reason,
      windowUs: 3500000,
    );
    if (mounted) {
      _safeSetState(() {
        _nativeCameraViewId = null;
        _cameraSourceKey = null;
        _cameraLoading = true;
        _cameraError = null;
        _nativeCameraAttachEpoch += 1;
      });
    } else {
      _nativeCameraViewId = null;
      _cameraSourceKey = null;
      _cameraLoading = true;
      _cameraError = null;
      _nativeCameraAttachEpoch += 1;
    }
    _lastCameraFrameId = null;
    _lastCameraFrameEventUs = 0;
    _lastPublishedModelFrameId = null;
    unawaited(_clearNativeOverlay());
    unawaited(_loadCameraSource(force: true));
  }

  void _handleNativeCameraDiagRecovery(Map<String, dynamic> payload) {
    if (_isDeveloperPlaybackRequested ||
        _cameraSuspendedByLifecycle ||
        !_openpilotOverlayMode) {
      return;
    }
    final state = payload['state']?.toString() ?? '';
    final decodedWindow = (payload['decodedWindow'] as num?)?.toInt() ?? 0;
    final codecConfigured = payload['codecConfigured'] == true;
    final syncWaitState = state.startsWith('waiting_sync_frame_');
    final firstFramePending =
        _lastCameraFrameId == null &&
        (_cameraAttachPendingBeforeFirstFrame ||
            syncWaitState ||
            (codecConfigured && decodedWindow > 0));
    if (!firstFramePending) {
      return;
    }
    _beginStartupProvisionalSync(
      reason: 'camera_diag:$state',
      windowUs: _LiveDriveCanvasScreenState._cameraFirstFrameDegradedHoldUs,
    );
    if (!_hasRenderableOverlayFallback()) {
      return;
    }
    final nowUs = _renderClock.elapsedMicroseconds;
    if (_cameraAttachStartedUs <= 0) {
      return;
    }
    final attachElapsedUs = nowUs - _cameraAttachStartedUs;
    final cooldownElapsedUs = nowUs - _lastCameraFirstFrameRecoveryUs;
    if (attachElapsedUs <
            _LiveDriveCanvasScreenState._cameraFirstFrameForceReattachUs ||
        cooldownElapsedUs <
            _LiveDriveCanvasScreenState._cameraFirstFrameRecoveryCooldownUs) {
      return;
    }
    _forceRestartNativeCameraAttach(
      reason: syncWaitState ? 'sync_frame_stuck_flutter' : 'first_frame_stuck_flutter',
    );
  }

  void _beginCameraAttachSession({
    required String reason,
  }) {
    _cameraAttachStartedUs = _renderClock.elapsedMicroseconds;
    _cameraStartupSocketFailureCount = 0;
    _setCameraAttachPhase(_CameraAttachPhase.surfaceReady, reason: reason);
    debugPrint('[DriveCanvas][native] attach-session begin reason=$reason');
  }

  void _settleCameraAttachSession({
    required String reason,
  }) {
    _cameraAttachStartedUs = 0;
    _cameraStartupSocketFailureCount = 0;
    _setCameraAttachPhase(_CameraAttachPhase.streaming, reason: reason);
    debugPrint('[DriveCanvas][native] attach-session settled reason=$reason');
  }

  bool _isTransientCameraRuntimeErrorReason(String reason) {
    final normalized = reason.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return normalized.startsWith('socket_failure:') ||
        normalized.startsWith('frame_stall_') ||
        normalized.startsWith('decoder_queue_failed:') ||
        normalized == 'socket_error' ||
        normalized == 'socket_open_failed' ||
        normalized == 'no_frames' ||
        normalized == 'decoder_error';
  }

  bool _cameraRuntimeLooksHealthy({
    int maxFrameAgeUs = _LiveDriveCanvasScreenState._cameraHealthyFrameAgeUs,
  }) {
    if (_cameraSuspendedByLifecycle || _cameraLoading || _overlayStaleActive) {
      return false;
    }
    if (_openpilotOverlayMode &&
        (!_sidecarConnected || !_nativeCameraAttachReady)) {
      return false;
    }
    if (_lastCameraFrameId == null || _lastCameraFrameEventUs <= 0) {
      return false;
    }
    final ageUs = _renderClock.elapsedMicroseconds - _lastCameraFrameEventUs;
    return ageUs >= 0 && ageUs <= maxFrameAgeUs;
  }

  void _clearDeferredTransientCameraError() {
    _cameraTransientErrorTimer?.cancel();
    _cameraTransientErrorTimer = null;
    _cameraTransientErrorSource = null;
    _cameraTransientErrorReason = null;
    _cameraTransientErrorMessage = null;
  }

  bool _shouldSuppressStartupSocketFailure({
    required String source,
    required String reason,
  }) {
    final normalized = reason.trim().toLowerCase();
    if (!normalized.startsWith('socket_failure:')) return false;
    if (_lastCameraFrameId != null || _lastCameraFrameEventUs > 0) return false;
    if (_cameraAttachStartedUs <= 0) return false;
    final elapsedUs = _renderClock.elapsedMicroseconds - _cameraAttachStartedUs;
    if (elapsedUs < 0 ||
        elapsedUs >
            _LiveDriveCanvasScreenState
                ._cameraStartupSocketFailureSuppressWindowUs) {
      return false;
    }
    _cameraStartupSocketFailureCount += 1;
    if (_cameraStartupSocketFailureCount != 1) {
      return false;
    }
    debugPrint(
      '[DriveCanvas][$source] suppressed first startup socket failure: $reason',
    );
    return true;
  }

  void _surfaceCameraRuntimeError({
    required String source,
    required String reason,
    required String message,
    required bool unsupported,
  }) {
    _clearDeferredTransientCameraError();
    debugPrint('[DriveCanvas][$source] error=$reason');
    if (!mounted) return;
    _safeSetState(() {
      _cameraError = message;
      if (unsupported) {
        _nativeCameraUnsupported = true;
      }
    });
    unawaited(
      _captureCameraErrorDiagnostics(
        source: source,
        reason: reason,
      ),
    );
    if (_nativeCameraUnsupported) {
      unawaited(_loadCameraSource(force: true));
    }
  }

  void _deferTransientCameraRuntimeError({
    required String source,
    required String reason,
    required String message,
  }) {
    _cameraTransientErrorTimer?.cancel();
    _cameraTransientErrorSource = source;
    _cameraTransientErrorReason = reason;
    _cameraTransientErrorMessage = message;
    debugPrint(
      '[DriveCanvas][$source] deferred transient error while runtime healthy: $reason',
    );
    _cameraTransientErrorTimer = Timer(
      _LiveDriveCanvasScreenState._cameraTransientErrorEscalationDelay,
      () {
        _cameraTransientErrorTimer = null;
        final pendingSource = _cameraTransientErrorSource;
        final pendingReason = _cameraTransientErrorReason;
        final pendingMessage = _cameraTransientErrorMessage;
        _cameraTransientErrorSource = null;
        _cameraTransientErrorReason = null;
        _cameraTransientErrorMessage = null;
        if (pendingSource == null ||
            pendingReason == null ||
            pendingMessage == null) {
          return;
        }
        if (_cameraSuspendedByLifecycle ||
            _sidecarTransitioning ||
            _suppressCameraErrors ||
            _cameraErrorGraceActive) {
          debugPrint(
            '[DriveCanvas][$pendingSource] dropped deferred transient error: $pendingReason',
          );
          return;
        }
        if (_cameraRuntimeLooksHealthy(
          maxFrameAgeUs:
              _LiveDriveCanvasScreenState._cameraHealthyFrameAgeUs * 2,
        )) {
          debugPrint(
            '[DriveCanvas][$pendingSource] transient error recovered before escalation: $pendingReason',
          );
          return;
        }
        _surfaceCameraRuntimeError(
          source: pendingSource,
          reason: pendingReason,
          message: pendingMessage,
          unsupported: false,
        );
      },
    );
  }

  void _handleCameraRuntimeError({
    required String source,
    required String reason,
    required String message,
  }) {
    final normalized = reason.trim().toLowerCase();
    final startupSocketFailure =
        normalized.startsWith('socket_failure:') &&
        _cameraAttachPendingBeforeFirstFrame;
    if (startupSocketFailure) {
      _setCameraAttachPhase(
        _CameraAttachPhase.retrying,
        reason: 'socket_failure',
      );
      if (mounted) {
        _safeSetState(() {
          _cameraLoading = true;
          _cameraError = null;
        });
      } else {
        _cameraLoading = true;
        _cameraError = null;
      }
      _setSidecarPhase(
        _SidecarPhase.verifying,
        message: '로드카메라 연결 재시도 중입니다.',
      );
      if (_shouldSuppressStartupSocketFailure(source: source, reason: reason)) {
        return;
      }
      return;
    }
    if (_shouldSuppressStartupSocketFailure(source: source, reason: reason)) {
      return;
    }
    final unsupported = reason.contains('invalid_ws_url') ||
        reason.contains('decoder_init_failed');
    final transient = _isTransientCameraRuntimeErrorReason(reason);
    if (!unsupported && transient && _cameraRuntimeLooksHealthy()) {
      _deferTransientCameraRuntimeError(
        source: source,
        reason: reason,
        message: message,
      );
      return;
    }
    _surfaceCameraRuntimeError(
      source: source,
      reason: reason,
      message: message,
      unsupported: unsupported,
    );
  }

  void _startCameraErrorGrace({
    required String reason,
    int windowUs = 2500000,
  }) {
    final nowUs = _renderClock.elapsedMicroseconds;
    _cameraErrorGraceUntilUs =
        math.max(_cameraErrorGraceUntilUs, nowUs + windowUs);
    debugPrint(
      '[DriveCanvas][native] error-grace on reason=$reason window=${(windowUs / 1000).round()}ms',
    );
  }

  _DriveCameraKind _cameraKindFromLabel(
    String? raw,
    _DriveCameraKind fallback,
  ) {
    final v = (raw ?? '').trim().toLowerCase();
    if (v.isEmpty) return fallback;
    if (v == 'wideroad' || v == 'wide_road' || v == 'wide') {
      return _DriveCameraKind.wideRoad;
    }
    return _DriveCameraKind.road;
  }

  void _updateSourceSize(
    Size next, {
    required _DriveCameraKind kind,
  }) {
    if (!next.width.isFinite ||
        !next.height.isFinite ||
        next.width <= 10 ||
        next.height <= 10) {
      return;
    }
    final previous = _sourceSizeByKind[kind];
    _sourceSizeByKind[kind] = next;
    if (kind != _liveCameraKind) {
      return;
    }
    _cameraSourceSize = next;
    if (previous == null ||
        (previous.width - next.width).abs() > 0.5 ||
        (previous.height - next.height).abs() > 0.5) {
      _invalidateNativeOverlayLayout(
        reason: 'source_size',
        clearExisting: true,
      );
    }
  }

  Future<void> _unloadWebCameraSurfaceImpl() async {
    try {
      await _cameraController.loadHtmlString(
        _buildIdleCameraHtml(),
        baseUrl: _cameraBaseUri.toString(),
      );
    } catch (_) {}
  }

  void _handleNativeCameraEventImpl(dynamic event) {
    if (_isDeveloperPlaybackRequested) return;
    if (!_canUseNativeCamera) return;
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);
    final viewIdAny = map['viewId'];
    final viewId = viewIdAny is int
        ? viewIdAny
        : int.tryParse(viewIdAny?.toString() ?? '');
    if (_nativeCameraViewId != null &&
        viewId != null &&
        viewId != _nativeCameraViewId) {
      return;
    }
    final type = map['type']?.toString() ?? '';
    final eventCameraKind = _cameraKindFromLabel(
      map['camera']?.toString(),
      _liveCameraKind,
    );
    if (_cameraSuspendedByLifecycle && type != 'camera_state') return;
    if (type == 'camera_diag') {
      _recordNativeCameraDiag(map);
      _handleNativeCameraDiagRecovery(map);
      return;
    }
    if (type == 'camera_frame') {
      final frameId = _DriveOverlaySnapshot._asInt(map['frameId']);
      if (frameId != null) {
        final firstVisibleFrame =
            _lastCameraFrameId == null || _cameraLoading;
        _handleCameraFrameEvent(
          frameId,
          source: 'native',
          cameraKind: eventCameraKind,
        );
        _clearDeferredTransientCameraError();
        if (mounted &&
            (_cameraLoading || (_cameraError?.isNotEmpty ?? false))) {
          _safeSetState(() {
            _cameraLoading = false;
            _cameraError = null;
          });
        } else {
          _cameraLoading = false;
          _cameraError = null;
        }
        _beginStartupProvisionalSync(reason: 'camera_frame:native');
        if (firstVisibleFrame) {
          _settleCameraAttachSession(reason: 'first_native_camera_frame');
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _lastCameraFrameId == null) return;
            if (_useNativeOverlayRenderer) {
              unawaited(
                _pushNativeOverlay(
                  _overlayNotifier.value,
                  force: true,
                ),
              );
            }
            unawaited(_pushNativeYoloConfig(force: true));
          });
        }
      }
      return;
    }
    if (type == 'camera_meta') {
      final width = _DriveOverlaySnapshot._asDouble(map['width']);
      final height = _DriveOverlaySnapshot._asDouble(map['height']);
      if (width != null &&
          height != null &&
          width.isFinite &&
          height.isFinite &&
          width > 10 &&
          height > 10) {
        final next = Size(width, height);
        final currentSize = _sourceSizeForKind(eventCameraKind);
        if ((next.width - currentSize.width).abs() > 0.5 ||
            (next.height - currentSize.height).abs() > 0.5) {
          debugPrint(
            '[DriveCanvas][native] camera_meta=${next.width.toStringAsFixed(0)}x${next.height.toStringAsFixed(0)}',
          );
          _updateSourceSize(next, kind: eventCameraKind);
        }
      }
      if (!mounted) return;
      _clearDeferredTransientCameraError();
      _safeSetState(() {
        _cameraError = null;
      });
      if (_cameraAttachPendingBeforeFirstFrame) {
        _setCameraAttachPhase(
          _CameraAttachPhase.waitingFirstFrame,
          reason: 'camera_meta',
        );
      }
      _beginStartupProvisionalSync(reason: 'camera_meta');
      return;
    }
    if (type == 'yolo_config') {
      debugPrint(
        '[DriveCanvas][native] yolo enabled=${map['yoloEnabled']} backend=${map['runtimeBackend']} model=${map['modelVariant']} source=${map['sourceWidth']}x${map['sourceHeight']}',
      );
      unawaited(
        YoloRuntimeStatusStore.saveConfig(Map<String, dynamic>.from(map)),
      );
      return;
    }
    if (type == 'yolo_state') {
      final payload = Map<String, dynamic>.from(map);
      unawaited(
        YoloRuntimeStatusStore.saveState(payload),
      );
      final snapshot = YoloRuntimeStatusSnapshot(
        config: _driveYoloRuntimeStatus.config,
        state: payload,
        updatedAt: DateTime.now(),
      );
      unawaited(_maybeAutoFallbackDriveYoloFromRuntimeStatus(snapshot));
      return;
    }
    if (type == 'camera_state') {
      final state = map['state']?.toString() ?? '';
      debugPrint('[DriveCanvas][native] state=$state');
      if (!mounted) return;
      switch (state) {
        case 'surface_created':
          _setCameraAttachPhase(
            _CameraAttachPhase.surfaceReady,
            reason: 'camera_state:$state',
          );
          break;
        case 'connecting':
          _setCameraAttachPhase(
            _CameraAttachPhase.socketConnecting,
            reason: 'camera_state:$state',
          );
          break;
        case 'connected':
          if (_lastCameraFrameId == null) {
            _setCameraAttachPhase(
              _CameraAttachPhase.socketConnected,
              reason: 'camera_state:$state',
            );
          }
          break;
      }
      if (state == 'connected' ||
          state.startsWith('decoder_configured') ||
          state.startsWith('waiting_sync_frame_')) {
        final hadVisibleFrame = _lastCameraFrameId != null;
        _sidecarTransitionTimer?.cancel();
        _clearDeferredTransientCameraError();
        if (!hadVisibleFrame) {
          _setCameraAttachPhase(
            (state.startsWith('decoder_configured') ||
                    state.startsWith('waiting_sync_frame_'))
                ? _CameraAttachPhase.waitingFirstFrame
                : _CameraAttachPhase.socketConnected,
            reason: 'camera_state:$state',
          );
        } else {
          _setCameraAttachPhase(
            _CameraAttachPhase.streaming,
            reason: 'camera_state:$state',
          );
        }
        _safeSetState(() {
          _cameraLoading = !hadVisibleFrame;
          _suppressCameraErrors = false;
          _cameraError = null;
        });
        _beginStartupProvisionalSync(reason: 'camera_state:$state');
        _setSidecarPhase(
          _openpilotOverlayMode
              ? (hadVisibleFrame
                  ? _SidecarPhase.running
                  : _SidecarPhase.verifying)
              : _SidecarPhase.idle,
          message: hadVisibleFrame
              ? '카메라 스트림 연결이 확인되었습니다.'
              : '로드카메라 첫 프레임을 기다리는 중입니다.',
        );
      }
      if (state == 'surface_destroyed' || state.startsWith('closed:')) {
        if (_lastCameraFrameId == null) {
          _setCameraAttachPhase(
            _CameraAttachPhase.retrying,
            reason: 'camera_state:$state',
          );
        }
      }
      return;
    }
    if (type == 'camera_error') {
      final reason = map['reason']?.toString().trim() ?? '';
      if (reason.isEmpty) return;
      if ((_sidecarTransitioning ||
              _suppressCameraErrors ||
              _cameraErrorGraceActive) &&
          !(reason.contains('invalid_ws_url') ||
              reason.contains('decoder_init_failed'))) {
        debugPrint('[DriveCanvas][native] suppressed error=$reason');
        return;
      }
      _handleCameraRuntimeError(
        source: 'native',
        reason: reason,
        message: '네이티브 뷰어 오류: $reason',
      );
    }
  }

  void _handleCameraJsMessageImpl(String raw) {
    if (_isDeveloperPlaybackRequested) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final map = Map<String, dynamic>.from(decoded);
    final type = map['type']?.toString() ?? '';
    final eventCameraKind = _cameraKindFromLabel(
      map['camera']?.toString(),
      _liveCameraKind,
    );
    if (_cameraSuspendedByLifecycle) return;
    if (type == 'camera_frame') {
      final frameId = _DriveOverlaySnapshot._asInt(map['frameId']);
      if (frameId != null) {
        final firstVisibleFrame =
            _lastCameraFrameId == null || _cameraLoading;
        _handleCameraFrameEvent(
          frameId,
          source: 'web',
          cameraKind: eventCameraKind,
        );
        _clearDeferredTransientCameraError();
        if (mounted &&
            (_cameraLoading || (_cameraError?.isNotEmpty ?? false))) {
          _safeSetState(() {
            _cameraLoading = false;
            _cameraError = null;
          });
        } else {
          _cameraLoading = false;
          _cameraError = null;
        }
        if (firstVisibleFrame) {
          _settleCameraAttachSession(reason: 'first_web_camera_frame');
          unawaited(_pushNativeYoloConfig(force: true));
        }
      }
      return;
    }
    if (type == 'camera_meta') {
      final width = _DriveOverlaySnapshot._asDouble(map['width']);
      final height = _DriveOverlaySnapshot._asDouble(map['height']);
      if (width == null || height == null) return;
      if (!width.isFinite || !height.isFinite) return;
      if (width < 10 || height < 10) return;
      final next = Size(width, height);
      final currentSize = _sourceSizeForKind(eventCameraKind);
      if ((next.width - currentSize.width).abs() < 0.5 &&
          (next.height - currentSize.height).abs() < 0.5) {
        return;
      }
      if (!mounted) {
        _updateSourceSize(next, kind: eventCameraKind);
        return;
      }
      debugPrint(
        '[DriveCanvas] camera_meta=${next.width.toStringAsFixed(0)}x${next.height.toStringAsFixed(0)}',
      );
      _clearDeferredTransientCameraError();
      _safeSetState(() {
        _updateSourceSize(next, kind: eventCameraKind);
        _cameraError = null;
      });
      return;
    }
    if (type == 'camera_error') {
      final reason = map['reason']?.toString().trim() ?? '';
      if (_sidecarTransitioning ||
          _suppressCameraErrors ||
          _cameraErrorGraceActive) {
        debugPrint('[DriveCanvas] suppressed camera_error reason=$reason');
        return;
      }
      final displayReason = switch (reason) {
        final r when r.startsWith('startup_keyframe_timeout_') =>
          '로드카메라 첫 프레임 재요청 중입니다.',
        final r when r.startsWith('startup_sync_frame_timeout_') =>
          '로드카메라 첫 프레임 재요청 중입니다.',
        final r when r.startsWith('frame_stall_') && _lastCameraFrameId == null =>
          '로드카메라 첫 프레임 재요청 중입니다.',
        final r when r.startsWith('frame_stall_') => '카메라 스트림 재동기화 중입니다.',
        _ => reason,
      };
      if (displayReason.isEmpty || !mounted) return;
      _clearDeferredTransientCameraError();
      _safeSetState(() {
        _cameraLoading = false;
        _cameraError = displayReason;
      });
      return;
    }
    if (type == 'camera_timeline_ready') {
      return;
    }
  }

  Future<void> _loadCameraSource({bool force = false}) async {
    if (!_hudModeLoaded) return;
    if (_isDeveloperPlaybackRequested) {
      _cameraSourceKey =
          'developer-playback:${_developerPlaybackVideoPath ?? '-'}';
      if (mounted) {
        _safeSetState(() {
          _cameraLoading = _developerPlaybackLoading;
          _cameraError = _developerPlaybackError;
        });
      } else {
        _cameraLoading = _developerPlaybackLoading;
        _cameraError = _developerPlaybackError;
      }
      return;
    }

    if (_useNativeLiveCamera) {
      final preserveVisibleNativeCamera = _nativeCameraViewId != null &&
          _cameraError == null &&
          !_cameraSuspendedByLifecycle;
      _beginStartupProvisionalSync(reason: 'load_camera_source');
      _startCameraErrorGrace(reason: 'native_camera_attach');
      if (!preserveVisibleNativeCamera) {
        _beginCameraAttachSession(reason: 'load_camera_source');
      }
      if (mounted) {
        _safeSetState(() {
          _cameraLoading = !preserveVisibleNativeCamera;
          _cameraError = null;
        });
      } else {
        _cameraLoading = !preserveVisibleNativeCamera;
        _cameraError = null;
      }
      _cameraSourceKey = 'native-live:$_hostIp:$_liveCameraName';
      return;
    }

    if (_openpilotOverlayMode && !_nativeCameraAttachReady) {
      if (mounted) {
        _safeSetState(() {
          _cameraLoading = true;
          _cameraError = null;
        });
      } else {
        _cameraLoading = true;
        _cameraError = null;
      }
      return;
    }
    final key = 'live:$_hostIp:$_liveCameraName';
    if (!force && _cameraSourceKey == key) return;
    _cameraSourceKey = key;

    if (mounted) {
      _safeSetState(() {
        _cameraLoading = true;
        _cameraError = null;
      });
    }

    try {
      final endpoints =
          _streamEndpointCandidates.map((uri) => uri.toString()).join(', ');
      final direct = _liveCameraWsUrl;
      debugPrint(
        '[DriveCanvas] source=live base=${_cameraBaseUri.toString()} direct=$direct fallback=$endpoints camera=$_liveCameraName',
      );
      await _cameraController.loadHtmlString(
        _buildLiveCameraHtml(_liveCameraKind),
        baseUrl: _cameraBaseUri.toString(),
      );
    } catch (e) {
      if (!mounted) return;
      _safeSetState(() {
        _cameraLoading = false;
        _cameraError = '카메라 로드 실패: $e';
      });
    }
  }

  bool _hasWideRoadCapability(_DriveOverlaySnapshot snapshot) {
    if (snapshot.wideRoadFrameId != null) return true;
    return snapshot.wideFromDeviceEuler.length >= 3;
  }

  _DriveCameraKind _selectLiveCameraKind(_DriveOverlaySnapshot snapshot) {
    if (_openpilotOverlayMode) {
      _wideCamRequested = false;
      return _DriveCameraKind.road;
    }
    if (!_hasWideRoadCapability(snapshot)) {
      _wideCamRequested = false;
      return _DriveCameraKind.road;
    }
    // openpilot 기준: vEgo < 10 m/s 이면 wide 요청, vEgo > 15 m/s 이면 road 복귀.
    final speedMps = snapshot.speedMps ?? 0.0;
    if (speedMps < 10.0) {
      _wideCamRequested = true;
    } else if (speedMps > 15.0) {
      _wideCamRequested = false;
    }
    _wideCamRequested = _wideCamRequested && snapshot.carrotExperimentalMode;
    return _wideCamRequested
        ? _DriveCameraKind.wideRoad
        : _DriveCameraKind.road;
  }

  void _syncLiveCameraKind(_DriveOverlaySnapshot snapshot) {
    final nextKind = _selectLiveCameraKind(snapshot);
    if (nextKind == _liveCameraKind) return;
    unawaited(_clearNativeOverlay());
    if (!mounted) {
      _liveCameraKind = nextKind;
      _cameraSourceSize = _sourceSizeForKind(nextKind);
      _lastCameraFrameId = null;
      _lastCameraFrameEventUs = 0;
      return;
    }
    _safeSetState(() {
      _liveCameraKind = nextKind;
      _cameraSourceSize = _sourceSizeForKind(nextKind);
      _nativeCameraViewId = null;
      _cameraLoading = true;
      _cameraError = null;
    });
    _lastCameraFrameId = null;
    _lastCameraFrameEventUs = 0;
    _beginStartupProvisionalSync(reason: 'camera_kind_switch');
    if (_openpilotOverlayMode && !_cameraSuspendedByLifecycle) {
      _startSidecarLoop();
    }
    if (!_cameraSuspendedByLifecycle) {
      unawaited(_loadCameraSource(force: true));
    }
  }
}
