part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasDiagLoggingComponents on _LiveDriveCanvasScreenState {
  String _driveDiagTimestampForFileName(DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Future<Directory> _resolveDriveDiagDir() async {
    try {
      await StorageLayoutService.instance.ensureBaseFolders();
      final preferred =
          Directory('${StorageLayoutService.logsPath}/drive_diagnostics');
      if (!await preferred.exists()) {
        await preferred.create(recursive: true);
      }
      return preferred;
    } catch (_) {
      final fallback = Directory(
          '${Directory.systemTemp.path}/carrotlink_drive_diagnostics');
      if (!await fallback.exists()) {
        await fallback.create(recursive: true);
      }
      return fallback;
    }
  }

  Future<void> _startDriveDiagnosticsLogging() async {
    if (_isDisposing ||
        _driveDiagClosing ||
        _driveDiagSink != null ||
        _driveDiagInitInFlight) {
      return;
    }
    _driveDiagInitInFlight = true;
    try {
      final now = DateTime.now();
      final dir = await _resolveDriveDiagDir();
      final file = File(
        '${dir.path}/drive_diag_${_driveDiagTimestampForFileName(now)}.ndjson',
      );
      final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      _driveDiagSink = sink;
      _driveDiagFilePath = file.path;
      _driveDiagSessionStartedAt = now;
      _appendDriveDiagEvent(
        'session_start',
        <String, dynamic>{
          'hostIp': _hostIp,
          'modeTag': _modeTagLabel,
          'nativeCamera': _useNativeLiveCamera,
          'overlayMode': _openpilotOverlayMode,
        },
      );
      _driveDiagSummaryTimer?.cancel();
      _driveDiagSummaryTimer = Timer.periodic(
          const Duration(seconds: 1), (_) => _emitDriveDiagSummary());
      debugPrint('[DriveCanvas][diag] drive summary log: ${file.path}');
    } catch (e) {
      debugPrint('[DriveCanvas][diag] failed to start drive summary log: $e');
    } finally {
      _driveDiagInitInFlight = false;
    }
  }

  Future<void> _stopDriveDiagnosticsLogging({
    required String reason,
  }) async {
    _driveDiagSummaryTimer?.cancel();
    _driveDiagSummaryTimer = null;
    _driveDiagClosing = true;
    final sink = _driveDiagSink;
    if (sink == null) {
      _driveDiagClosing = false;
      _driveDiagFilePath = null;
      _driveDiagSessionStartedAt = null;
      return;
    }
    _driveDiagSink = null;
    try {
      _rollDriveDiagStaleWindow(_renderClock.elapsedMicroseconds);
      final event = <String, dynamic>{
        'ts': DateTime.now().toIso8601String(),
        'type': 'session_end',
        'reason': reason,
        'hostIp': _hostIp,
      };
      sink.writeln(jsonEncode(event));
      await sink.flush();
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
    } finally {
      _driveDiagClosing = false;
      _driveDiagFilePath = null;
      _driveDiagSessionStartedAt = null;
    }
  }

  void _appendDriveDiagEvent(String type, Map<String, dynamic> payload) {
    if (_isDisposing || _driveDiagClosing) {
      return;
    }
    final sink = _driveDiagSink;
    if (sink == null) return;
    final event = <String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'type': type,
      ...payload,
    };
    try {
      sink.writeln(jsonEncode(event));
    } catch (_) {
      if (identical(_driveDiagSink, sink)) {
        _driveDiagSink = null;
      }
    }
  }

  void _recordNativeCameraDiag(Map<String, dynamic> payload) {
    _lastNativeCameraDiag = payload;
    final decodeBacklog = (payload['decodeBacklog'] as num?)?.toInt() ?? 0;
    final packetAgeMs = (payload['packetAgeMs'] as num?)?.toInt() ?? -1;
    final decodeAgeMs = (payload['decodeAgeMs'] as num?)?.toInt() ?? -1;
    if (decodeBacklog >= 1 || packetAgeMs >= 1200 || decodeAgeMs >= 1200) {
      _appendDriveDiagEvent(
        'camera_alert',
        <String, dynamic>{
          'state': payload['state'],
          'packetAgeMs': packetAgeMs,
          'decodeAgeMs': decodeAgeMs,
          'decodeBacklog': decodeBacklog,
          'codecBacklog': (payload['codecBacklog'] as num?)?.toInt() ?? 0,
          'dropsWindow': (payload['dropsWindow'] as num?)?.toInt() ?? 0,
          'connectAttempts': (payload['connectAttempts'] as num?)?.toInt() ?? 0,
        },
      );
    }
  }

  void _recordOverlayPayloadArrival() {
    _driveDiagOverlayPayloadFramesWindow += 1;
  }

  void _recordCameraFrameForDiag({
    required int frameId,
    required String source,
  }) {
    _driveDiagCameraFrameEventsWindow += 1;
    if (frameId % 120 == 0) {
      _appendDriveDiagEvent(
        'camera_frame_checkpoint',
        <String, dynamic>{
          'frameId': frameId,
          'source': source,
          'camera': _liveCameraName,
        },
      );
    }
  }

  void _recordOverlayPushCall() {
    _driveDiagOverlayPushCallsWindow += 1;
  }

  void _recordOverlayPushCoalesced() {
    _driveDiagOverlayPushCoalescedWindow += 1;
  }

  void _recordOverlayPushSkipped({
    required bool duplicate,
    required bool noSurface,
  }) {
    _driveDiagOverlayPushSkippedWindow += 1;
    if (duplicate) {
      _driveDiagOverlayPushDuplicateWindow += 1;
    }
    if (noSurface) {
      _driveDiagOverlayPushNoSurfaceWindow += 1;
    }
  }

  void _recordOverlayPushSent(_DriveOverlaySnapshot snapshot) {
    _driveDiagOverlayPushSentWindow += 1;
    final modelFrame = snapshot.modelFrameId;
    if (modelFrame != null &&
        _driveDiagLastOverlayPushModelFrameId == modelFrame) {
      _driveDiagOverlayPushDuplicateWindow += 1;
    }
    _driveDiagLastOverlayPushModelFrameId = modelFrame;
  }

  void _recordFrameSyncRenderTarget(_DriveOverlaySnapshot next) {
    final modelFrame = next.modelFrameId;
    final cameraFrame = _cameraFrameIdFromSnapshot(next);
    if (modelFrame != null && cameraFrame != null) {
      final gap = (modelFrame - cameraFrame).abs();
      _driveDiagSyncGapSamplesWindow += 1;
      _driveDiagSyncGapSumWindow += gap;
      if (gap > _driveDiagSyncGapMaxWindow) {
        _driveDiagSyncGapMaxWindow = gap;
      }
    }
    _driveDiagInterpSamplesWindow += 1;
    _driveDiagInterpSumUsWindow += _renderInterpDurationUs;
    if (_renderInterpDurationUs > _driveDiagInterpMaxUsWindow) {
      _driveDiagInterpMaxUsWindow = _renderInterpDurationUs;
    }
  }

  void _recordOverlayStaleEnter(String reason) {
    if (_driveDiagStaleStartedUs != null) return;
    _driveDiagStaleStartedUs = _renderClock.elapsedMicroseconds;
    _driveDiagStaleEnterWindow += 1;
    _appendDriveDiagEvent(
      'sync_stale_enter',
      <String, dynamic>{'reason': reason},
    );
  }

  void _recordOverlayStaleExit() {
    final startedUs = _driveDiagStaleStartedUs;
    if (startedUs == null) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    final durationUs = math.max(0, nowUs - startedUs);
    _driveDiagStaleAccumulatedUsWindow += durationUs;
    _driveDiagStaleStartedUs = null;
    _appendDriveDiagEvent(
      'sync_stale_exit',
      <String, dynamic>{
        'durationMs': (durationUs / 1000).round(),
      },
    );
  }

  void _rollDriveDiagStaleWindow(int nowUs) {
    final startedUs = _driveDiagStaleStartedUs;
    if (startedUs == null) return;
    final durationUs = math.max(0, nowUs - startedUs);
    _driveDiagStaleAccumulatedUsWindow += durationUs;
    _driveDiagStaleStartedUs = nowUs;
  }

  void _emitDriveDiagSummary() {
    if (_driveDiagSink == null) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    _rollDriveDiagStaleWindow(nowUs);
    final native = _lastNativeCameraDiag;
    final syncGapSamples = _driveDiagSyncGapSamplesWindow;
    final interpSamples = _driveDiagInterpSamplesWindow;
    _appendDriveDiagEvent(
      'summary',
      <String, dynamic>{
        'sessionAgeSec': _driveDiagSessionStartedAt == null
            ? null
            : DateTime.now().difference(_driveDiagSessionStartedAt!).inSeconds,
        'hostIp': _hostIp,
        'camera': <String, dynamic>{
          'cameraName': _liveCameraName,
          'loading': _cameraLoading,
          'error': _cameraError,
          'lastFrameId': _lastCameraFrameId,
          'frameEventsWindow': _driveDiagCameraFrameEventsWindow,
          'native': native,
        },
        'overlay': <String, dynamic>{
          'fps': double.parse(_overlayDebugFps.toStringAsFixed(2)),
          'dropCountTotal': _overlayDropCount,
          'modelCameraGapLatest': _overlayModelCameraGap,
          'payloadFramesWindow': _driveDiagOverlayPayloadFramesWindow,
          'pushCallsWindow': _driveDiagOverlayPushCallsWindow,
          'pushSentWindow': _driveDiagOverlayPushSentWindow,
          'pushCoalescedWindow': _driveDiagOverlayPushCoalescedWindow,
          'pushSkippedWindow': _driveDiagOverlayPushSkippedWindow,
          'pushDuplicateWindow': _driveDiagOverlayPushDuplicateWindow,
          'pushNoSurfaceWindow': _driveDiagOverlayPushNoSurfaceWindow,
          'lastPublishedModelFrameId': _lastPublishedModelFrameId,
        },
        'sync': <String, dynamic>{
          'staleActive': _overlayStaleActive,
          'staleReason': _overlayStaleReason,
          'staleEnterWindow': _driveDiagStaleEnterWindow,
          'staleDurationMsWindow':
              (_driveDiagStaleAccumulatedUsWindow / 1000).round(),
          'gapAvgWindow': syncGapSamples <= 0
              ? null
              : double.parse(
                  (_driveDiagSyncGapSumWindow / syncGapSamples)
                      .toStringAsFixed(2),
                ),
          'gapMaxWindow':
              syncGapSamples <= 0 ? null : _driveDiagSyncGapMaxWindow,
          'interpAvgMsWindow': interpSamples <= 0
              ? null
              : double.parse(
                  ((_driveDiagInterpSumUsWindow / interpSamples) / 1000.0)
                      .toStringAsFixed(2),
                ),
          'interpMaxMsWindow': interpSamples <= 0
              ? null
              : double.parse(
                  (_driveDiagInterpMaxUsWindow / 1000.0).toStringAsFixed(2),
                ),
          'lastSyncHitAgoMs': _lastSyncHitUs <= 0
              ? null
              : ((nowUs - _lastSyncHitUs) / 1000).round(),
        },
        'sidecar': <String, dynamic>{
          'connected': _sidecarConnected,
          'phase': _sidecarPhase.name,
          'phaseMessage': _sidecarPhaseMessage,
        },
        'logFile': _driveDiagFilePath,
      },
    );

    _driveDiagOverlayPushCallsWindow = 0;
    _driveDiagOverlayPushSentWindow = 0;
    _driveDiagOverlayPushCoalescedWindow = 0;
    _driveDiagOverlayPushSkippedWindow = 0;
    _driveDiagOverlayPushDuplicateWindow = 0;
    _driveDiagOverlayPushNoSurfaceWindow = 0;
    _driveDiagOverlayPayloadFramesWindow = 0;
    _driveDiagCameraFrameEventsWindow = 0;
    _driveDiagSyncGapSamplesWindow = 0;
    _driveDiagSyncGapSumWindow = 0;
    _driveDiagSyncGapMaxWindow = 0;
    _driveDiagInterpSamplesWindow = 0;
    _driveDiagInterpSumUsWindow = 0;
    _driveDiagInterpMaxUsWindow = 0;
    _driveDiagStaleEnterWindow = 0;
    _driveDiagStaleAccumulatedUsWindow = 0;
  }
}
