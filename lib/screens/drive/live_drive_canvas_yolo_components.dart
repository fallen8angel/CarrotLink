part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasYoloComponents on _LiveDriveCanvasScreenState {
  Future<void> _loadYoloDebugSettingsImpl() async {
    YoloDebugSettings settings = YoloDebugSettings.empty;
    try {
      settings = await YoloDebugSettingsStore.load();
    } catch (_) {}
    if (mounted) {
      _safeSetState(() {
        _driveYoloDebugSettings = settings;
      });
    } else {
      _driveYoloDebugSettings = settings;
    }
    unawaited(_pushNativeYoloConfig(force: true));
  }

  Future<YoloDebugSettings> _currentYoloDebugSettingsForNativeImpl() async {
    if (_isDeveloperPlaybackRequested || !_canUseNativeCamera) {
      return YoloDebugSettings.empty;
    }
    try {
      return await YoloDebugSettingsStore.load();
    } catch (_) {
      return YoloDebugSettings.empty;
    }
  }

  Future<void> _setDriveYoloDebugSettingsImpl(YoloDebugSettings next) async {
    if (_driveYoloDebugSettings == next) return;
    _safeSetState(() {
      _driveYoloDebugSettings = next;
    });
    await YoloDebugSettingsStore.save(next);
    if (_isDeveloperPlaybackRequested) {
      _syncDeveloperPlaybackLoop();
    } else {
      unawaited(_pushNativeYoloConfig(force: true));
    }
  }

  Future<void> _loadDriveYoloRuntimeStatusImpl() async {
    YoloRuntimeStatusSnapshot snapshot = const YoloRuntimeStatusSnapshot(
      config: <String, dynamic>{},
      state: <String, dynamic>{},
      updatedAt: null,
    );
    try {
      snapshot = await YoloRuntimeStatusStore.load();
    } catch (_) {}
    if (mounted) {
      _safeSetState(() {
        _driveYoloRuntimeStatus = snapshot;
        _developerPlaybackStatusUpdatedAt = snapshot.updatedAt;
      });
    } else {
      _driveYoloRuntimeStatus = snapshot;
      _developerPlaybackStatusUpdatedAt = snapshot.updatedAt;
    }
  }

  String _driveYoloValueImpl(String key) {
    final stateValue = _driveYoloRuntimeStatus.state[key];
    if (stateValue != null && stateValue.toString().trim().isNotEmpty) {
      return stateValue.toString();
    }
    final configValue = _driveYoloRuntimeStatus.config[key];
    if (configValue != null && configValue.toString().trim().isNotEmpty) {
      return configValue.toString();
    }
    return '-';
  }

  String _driveYoloFrameSummaryImpl() {
    final seen = _driveYoloValueImpl('framesSeen');
    final sampled = _driveYoloValueImpl('framesSampled');
    final skipped = _driveYoloValueImpl('framesSkipped');
    return '$seen / $sampled / $skipped';
  }

  String _driveYoloRuntimeStatusJsonImpl() {
    final payload = <String, dynamic>{
      'config': _driveYoloRuntimeStatus.config,
      'state': _driveYoloRuntimeStatus.state,
      'updated': _driveYoloRuntimeStatus.updatedAt?.toLocal().toIso8601String(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<void> _copyDriveYoloRuntimeStatusImpl() async {
    await Clipboard.setData(
      ClipboardData(text: _driveYoloRuntimeStatusJsonImpl()),
    );
    if (!mounted) return;
    _toast('YOLO 상태를 복사했습니다.');
  }

  Future<void> _disableNativeYoloForDeveloperPlaybackImpl() async {
    final viewId = _nativeCameraViewId;
    if (viewId == null) {
      _lastNativeYoloConfigSignature = null;
      return;
    }
    final payload = YoloNativeConfigPayloadBuilder.build(
      settings: YoloDebugSettings.empty,
      camera: _liveCameraName,
      sourceSize: _cameraSourceSize,
    );
    final signature = YoloNativeConfigPayloadBuilder.signature(payload);
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

  Future<void> _pushNativeYoloConfig({bool force = false}) async {
    if (_isDeveloperPlaybackRequested) {
      // Keep the stock live camera path and the developer-only offline
      // playback path mutually exclusive. Running both runtimes at once can
      // crash the process during delegate/module bring-up on device.
      await _disableNativeYoloForDeveloperPlaybackImpl();
      return;
    }
    final viewId = _nativeCameraViewId;
    if (viewId == null) {
      _lastNativeYoloConfigSignature = null;
      return;
    }

    final settings = await _currentYoloDebugSettingsForNativeImpl();
    final payload = YoloNativeConfigPayloadBuilder.build(
      settings: settings,
      camera: _liveCameraName,
      sourceSize: _cameraSourceSize,
    );
    final signature = YoloNativeConfigPayloadBuilder.signature(payload);
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
}
