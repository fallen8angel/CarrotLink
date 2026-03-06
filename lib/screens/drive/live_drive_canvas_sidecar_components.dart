part of 'live_drive_canvas_screen.dart';

@pragma('vm:entry-point')
Future<void> _driveSidecarWorkerMain(Map<String, dynamic> config) async {
  final wsUrl = (config['wsUrl']?.toString() ?? '').trim();
  final sendPort = config['sendPort'] as SendPort?;
  if (wsUrl.isEmpty || sendPort == null) return;
  while (true) {
    WebSocket? socket;
    try {
      socket = await WebSocket.connect(wsUrl).timeout(
        const Duration(seconds: 4),
      );
      sendPort.send(<String, dynamic>{'type': 'connected', 'connected': true});
      await for (final event in socket) {
        Map<String, dynamic>? payload;
        if (event is String) {
          try {
            final decoded = jsonDecode(event);
            if (decoded is Map<String, dynamic>) {
              payload = decoded;
            } else if (decoded is Map) {
              payload = Map<String, dynamic>.from(decoded);
            }
          } catch (_) {
            payload = null;
          }
        } else if (event is List<int>) {
          List<int> bytes = event;
          try {
            bytes = zlib.decode(bytes);
          } catch (_) {
            // server may still send plain UTF-8 payloads.
          }
          try {
            final decoded = jsonDecode(utf8.decode(bytes));
            if (decoded is Map<String, dynamic>) {
              payload = decoded;
            } else if (decoded is Map) {
              payload = Map<String, dynamic>.from(decoded);
            }
          } catch (_) {
            payload = null;
          }
        }
        if (payload == null) continue;
        sendPort.send(<String, dynamic>{
          'type': 'frame',
          'payload': payload,
        });
      }
    } catch (_) {
      // reconnect loop
    } finally {
      sendPort.send(<String, dynamic>{'type': 'connected', 'connected': false});
      try {
        await socket?.close();
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }
}

extension _LiveDriveCanvasSidecarComponents on _LiveDriveCanvasScreenState {
  void _startSidecarLoop() {
    _stopSidecarLoop(resetSession: false);
    _sidecarSession++;
    final session = _sidecarSession;
    unawaited(_startSidecarWorker(session));
  }

  void _stopSidecarLoop({bool resetSession = true}) {
    if (resetSession) _sidecarSession++;
    _sidecarWorkerSubscription?.cancel();
    _sidecarWorkerSubscription = null;
    _sidecarWorkerReceivePort?.close();
    _sidecarWorkerReceivePort = null;
    _sidecarWorkerIsolate?.kill(priority: Isolate.immediate);
    _sidecarWorkerIsolate = null;
    if (mounted && _sidecarConnected) {
      _safeSetState(() => _sidecarConnected = false);
    } else {
      _sidecarConnected = false;
    }
  }

  Future<void> _startSidecarWorker(int session) async {
    if (!mounted || session != _sidecarSession) return;
    final receivePort = ReceivePort();
    _sidecarWorkerReceivePort = receivePort;
    _sidecarWorkerSubscription = receivePort.listen((event) {
      if (!mounted || session != _sidecarSession) return;
      _handleSidecarWorkerEvent(event);
    });
    try {
      final isolate = await Isolate.spawn<Map<String, dynamic>>(
        _driveSidecarWorkerMain,
        <String, dynamic>{
          'wsUrl': _sidecarWsUrl,
          'sendPort': receivePort.sendPort,
        },
        debugName: 'drive_sidecar_worker_${widget.hostIp}',
      );
      if (!mounted || session != _sidecarSession) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _sidecarWorkerIsolate = isolate;
    } catch (_) {
      _sidecarWorkerSubscription?.cancel();
      _sidecarWorkerSubscription = null;
      _sidecarWorkerReceivePort?.close();
      _sidecarWorkerReceivePort = null;
      if (_sidecarConnected && mounted) {
        _safeSetState(() => _sidecarConnected = false);
      } else {
        _sidecarConnected = false;
      }
      _setSidecarPhase(
        _SidecarPhase.failed,
        message: '사이드카 워커 시작에 실패했습니다.',
      );
    }
  }

  void _handleSidecarWorkerEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);
    final type = map['type']?.toString() ?? '';
    if (type == 'connected') {
      final next = map['connected'] == true;
      _pushSidecarHistory('WS', next ? 'connected' : 'disconnected');
      if (next && _isSidecarBusy) {
        _sidecarTransitionTimer?.cancel();
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
            _cameraLoading = false;
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
          _cameraLoading = false;
        }
      }
      if (next) {
        _clearSidecarRecoverySchedule();
        _setSidecarPhase(
          _SidecarPhase.running,
          message: '사이드카 연결이 복구되었습니다.',
        );
        if (!_adaptiveCameraQualitySynced) {
          unawaited(
            _setAdaptiveCameraQualityMode(
              _adaptiveCameraQualityMode,
              reason: 'ws_reconnected',
              force: true,
            ),
          );
        }
      } else if (_openpilotOverlayMode && !_cameraSuspendedByLifecycle) {
        _setSidecarPhase(
          _SidecarPhase.verifying,
          message: '사이드카 재연결을 시도합니다.',
        );
      } else if (!_openpilotOverlayMode) {
        _setSidecarPhase(_SidecarPhase.idle);
      }
      if (next && !_cameraSuspendedByLifecycle) {
        unawaited(_loadCameraSource(force: true));
      } else if (!next &&
          _openpilotOverlayMode &&
          !_cameraSuspendedByLifecycle &&
          !_isSidecarBusy) {
        _scheduleSidecarRuntimeRecovery(reason: 'worker_disconnected');
      }
      return;
    }
    if (type != 'frame') return;
    final rawPayload = map['payload'];
    if (rawPayload is! Map) return;
    final payload = Map<String, dynamic>.from(rawPayload);
    _handleSidecarPayload(payload);
  }

  void _handleSidecarPayload(Map<String, dynamic> payload) {
    if (payload['type'] == 'hello') return;
    if (!_openpilotOverlayMode) return;
    if (_debugOverlayPreviewMode) return;

    final next = _stabilizeOverlaySnapshot(
      _DriveOverlaySnapshot.fromSidecar(payload),
    );
    _syncLiveCameraKind(next);
    _cacheOverlaySnapshot(next);
    _overlayDiagFrames++;
    final now = DateTime.now();
    _sidecarLastFrameAt = now;
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
    final inferredCameraFrame = _cameraFrameIdFromSnapshot(next);
    final nowUs = _renderClock.elapsedMicroseconds;
    final cameraStale = _lastCameraFrameEventUs <= 0 ||
        (nowUs - _lastCameraFrameEventUs) > _LiveDriveCanvasScreenState._cameraFrameStaleUs;
    if (inferredCameraFrame != null &&
        (_lastCameraFrameId == null || cameraStale)) {
      _lastCameraFrameId = inferredCameraFrame;
      if (cameraStale && (nowUs - _lastCameraFallbackLogUs) >= 2000000) {
        _lastCameraFallbackLogUs = nowUs;
        debugPrint(
          '[DriveCanvas][sync] fallback cameraFrame=$inferredCameraFrame via sidecar (native frame event stale)',
        );
      }
    }
    _publishOverlaySynced();
  }

}
