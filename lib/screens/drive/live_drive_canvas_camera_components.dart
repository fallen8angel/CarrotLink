part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasCameraComponents on _LiveDriveCanvasScreenState {
  bool get _cameraErrorGraceActive =>
      _renderClock.elapsedMicroseconds <= _cameraErrorGraceUntilUs;

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
    _sourceSizeByKind[kind] = next;
    if (kind != _liveCameraKind) {
      return;
    }
    _cameraSourceSize = next;
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
      return;
    }
    if (type == 'camera_frame') {
      final frameId = _DriveOverlaySnapshot._asInt(map['frameId']);
      if (frameId != null) {
        _handleCameraFrameEvent(
          frameId,
          source: 'native',
          cameraKind: eventCameraKind,
        );
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
      _safeSetState(() {
        _cameraLoading = false;
        _cameraError = null;
      });
      _beginStartupProvisionalSync(reason: 'camera_meta');
      unawaited(_pushNativeYoloConfig(force: true));
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
      unawaited(
        YoloRuntimeStatusStore.saveState(Map<String, dynamic>.from(map)),
      );
      return;
    }
    if (type == 'camera_state') {
      final state = map['state']?.toString() ?? '';
      debugPrint('[DriveCanvas][native] state=$state');
      if (!mounted) return;
      if (state == 'connected' || state.startsWith('decoder_configured')) {
        _sidecarTransitionTimer?.cancel();
        _safeSetState(() {
          _cameraLoading = false;
          _suppressCameraErrors = false;
          _cameraError = null;
        });
        _beginStartupProvisionalSync(reason: 'camera_state:$state');
        _setSidecarPhase(
          _openpilotOverlayMode ? _SidecarPhase.running : _SidecarPhase.idle,
          message: '카메라 스트림 연결이 확인되었습니다.',
        );
      }
      return;
    }
    if (type == 'camera_error') {
      final reason = map['reason']?.toString().trim() ?? '';
      if (reason.isEmpty) return;
      final unsupported = reason.contains('invalid_ws_url') ||
          reason.contains('decoder_init_failed');
      if ((_sidecarTransitioning ||
              _suppressCameraErrors ||
              _cameraErrorGraceActive) &&
          !unsupported) {
        debugPrint('[DriveCanvas][native] suppressed error=$reason');
        return;
      }
      debugPrint('[DriveCanvas][native] error=$reason');
      if (!mounted) return;
      _safeSetState(() {
        _cameraError = '네이티브 뷰어 오류: $reason';
        if (reason.contains('invalid_ws_url') ||
            reason.contains('decoder_init_failed')) {
          _nativeCameraUnsupported = true;
        }
      });
      unawaited(
        _captureCameraErrorDiagnostics(
          source: 'native',
          reason: reason,
        ),
      );
      if (_nativeCameraUnsupported) {
        unawaited(_loadCameraSource(force: true));
      }
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
        _handleCameraFrameEvent(
          frameId,
          source: 'web',
          cameraKind: eventCameraKind,
        );
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
      _safeSetState(() {
        _updateSourceSize(next, kind: eventCameraKind);
        _cameraLoading = false;
        _cameraError = null;
      });
      return;
    }
    if (type == 'camera_error') {
      final reason = map['reason']?.toString().trim() ?? '';
      if (reason.isEmpty || !mounted) return;
      if (_sidecarTransitioning ||
          _suppressCameraErrors ||
          _cameraErrorGraceActive) {
        debugPrint('[DriveCanvas] suppressed camera_error reason=$reason');
        return;
      }
      debugPrint('[DriveCanvas] camera_error reason=$reason');
      _safeSetState(() => _cameraError = '카메라 뷰어 오류: $reason');
      unawaited(
        _captureCameraErrorDiagnostics(
          source: 'web',
          reason: reason,
        ),
      );
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
