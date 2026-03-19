part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasDiagLoggingComponents on _LiveDriveCanvasScreenState {
  Map<String, dynamic> _diagStringKeyMap(Object? raw) {
    if (raw is Map<String, dynamic>) {
      return Map<String, dynamic>.from(raw);
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{};
  }

  List<dynamic> _diagList(Object? raw) {
    if (raw is List) {
      return List<dynamic>.from(raw);
    }
    return const <dynamic>[];
  }

  Map<String, dynamic> _selectedSidecarServiceHealth() {
    final raw = _diagStringKeyMap(_sidecarHealthSnapshot['serviceHealth']);
    if (raw.isEmpty) {
      return <String, dynamic>{};
    }
    const names = <String>[
      'carState',
      'selfdriveState',
      'controlsState',
      'modelV2',
      'roadCameraState',
      'wideRoadCameraState',
      'radarState',
      'liveCalibration',
    ];
    final out = <String, dynamic>{};
    for (final name in names) {
      final entry = _diagStringKeyMap(raw[name]);
      if (entry.isNotEmpty) {
        out[name] = entry;
      }
    }
    return out;
  }

  String? _diagNormalizedPhaseMessage(String phase, String? message) {
    final text = (message ?? '').trim();
    if (text.isEmpty) return null;
    if (phase == _SidecarPhase.running.name &&
        (text == '사이드카 연결이 복구되었습니다.' || text == '카메라 스트림 연결이 확인되었습니다.')) {
      return null;
    }
    return text;
  }

  Map<String, dynamic> _diagCameraRelaySummary(
      Map<String, dynamic> sidecarHealth) {
    final relay = _diagStringKeyMap(sidecarHealth['cameraRelay']);
    final cameras = _diagStringKeyMap(relay['cameras']);
    final road = _diagStringKeyMap(cameras['road']);
    return <String, dynamic>{
      'mode': relay['mode'],
      'qualityMode': relay['qualityMode'],
      'transport': relay['transport'],
      'port': relay['port'],
      'road': <String, dynamic>{
        'service': road['service'],
        'frames': road['frames'],
        'lastFrameId': road['lastFrameId'],
        'nullFrameIdCount': road['nullFrameIdCount'],
        'lastFrameAgeMs': road['lastFrameAgeMs'],
        'queueDrops': road['queueDrops'],
        'sendDrops': road['sendDrops'],
        'rawFrame': _diagStringKeyMap(road['rawFrame']),
        'packedMeta': _diagStringKeyMap(road['packedMeta']),
      },
    };
  }

  String _diagNativeSyncMode(Map<String, dynamic> native) {
    if (native['syntheticSyncActive'] == true) {
      return 'synthetic';
    }
    final sourceFrameId = (native['lastSourceFrameId'] as num?)?.toInt() ?? -1;
    if (sourceFrameId >= 0) {
      return 'source';
    }
    return 'unknown';
  }

  String? _diagFrameIdRootCauseHint({
    required Map<String, dynamic> native,
    required Map<String, dynamic> sidecarHealth,
    required Map<String, dynamic> serviceHealth,
  }) {
    final candidates = (native['sourceFrameCandidates'] ?? '').toString();
    final parsedFrameIdRaw = (native['parsedFrameIdRaw'] ?? '').toString();
    final relay = _diagCameraRelaySummary(sidecarHealth);
    final relayRoad = _diagStringKeyMap(relay['road']);
    final relayLastFrameId = (relayRoad['lastFrameId'] as num?)?.toInt() ?? -1;
    final relayRawFrame = _diagStringKeyMap(relayRoad['rawFrame']);
    final relayPackedMeta = _diagStringKeyMap(relayRoad['packedMeta']);
    final relayRawFrameId = (relayRawFrame['frameId'] as num?)?.toInt() ?? -1;
    final relayPackedFrameId =
        (relayPackedMeta['frameId'] as num?)?.toInt() ?? -1;
    final roadCameraState = _diagStringKeyMap(serviceHealth['roadCameraState']);
    final roadCameraFrameId =
        (roadCameraState['frameId'] as num?)?.toInt() ?? -1;
    if (candidates.contains('frameId=null') &&
        roadCameraFrameId >= 0 &&
        relayRawFrameId < 0 &&
        relayLastFrameId < 0) {
      return 'roadCameraState.frameId는 있으나 cameraRelay raw frame 샘플과 lastFrameId가 비어 있습니다. relay producer가 받는 frame 객체 경계에서 frameId가 빠지는 쪽이 가장 유력합니다.';
    }
    if (candidates.contains('frameId=null') &&
        relayRawFrameId >= 0 &&
        relayPackedFrameId < 0) {
      return 'cameraRelay raw frame 샘플에는 frameId가 있으나 packed meta에선 비어 있습니다. sidecar packet packing 경계를 확인해야 합니다.';
    }
    if (candidates.contains('frameId=null') &&
        relayPackedFrameId >= 0 &&
        parsedFrameIdRaw.contains('null')) {
      return 'cameraRelay packed meta에는 frameId가 있으나 native가 파싱한 최근 meta.frameId는 null입니다. websocket packet 전달 또는 native parse 경계를 확인해야 합니다.';
    }
    if (candidates.contains('frameId=null') && roadCameraFrameId < 0) {
      return 'camera service 자체에서 frameId가 비어 들어올 가능성이 있습니다.';
    }
    return null;
  }

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
    final sidecarHealth = _diagStringKeyMap(_sidecarHealthSnapshot);
    final serviceHealth = _selectedSidecarServiceHealth();
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
          'syncMode': native == null
              ? 'unknown'
              : _diagNativeSyncMode(_diagStringKeyMap(native)),
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
          'phaseMessage': _diagNormalizedPhaseMessage(
              _sidecarPhase.name, _sidecarPhaseMessage),
          'phaseMessageRaw': _sidecarPhaseMessage,
          'profile':
              sidecarHealth['profile'] ?? _sidecarProfileSnapshot['profile'],
          'variant': sidecarHealth['variant'] ??
              _sidecarProfileSnapshot['variant'] ??
              _sidecarVariantHint,
          'repoFlavor': sidecarHealth['repoFlavor'] ??
              _sidecarProfileSnapshot['repoFlavor'] ??
              _sidecarRepoFlavorHint,
          'startupProtectionActive': sidecarHealth['startupProtectionActive'],
          'radarReady': sidecarHealth['radarReady'],
          'radarFreshStable': sidecarHealth['radarFreshStable'],
          'radarExpected': SidecarService.profileRequiresFullRuntime(
              (sidecarHealth['profile'] ?? _sidecarProfileSnapshot['profile'])
                  ?.toString()),
          'staleReasons': _diagList(sidecarHealth['staleReasons']),
          'missingFields': _diagList(sidecarHealth['missingFields']),
          'serviceHealth': serviceHealth,
          'cameraRelay': _diagCameraRelaySummary(sidecarHealth),
          'frameIdRootCauseHint': native == null
              ? null
              : _diagFrameIdRootCauseHint(
                  native: _diagStringKeyMap(native),
                  sidecarHealth: sidecarHealth,
                  serviceHealth: serviceHealth,
                ),
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

  Map<String, dynamic> _driveDiagnosticsClipboardPayload() {
    final nowUs = _renderClock.elapsedMicroseconds;
    final lastFrameAgeMs = _lastCameraFrameEventUs <= 0
        ? null
        : math.max(0, ((nowUs - _lastCameraFrameEventUs) / 1000).round());
    final sidecarHealth = _diagStringKeyMap(_sidecarHealthSnapshot);
    final sidecarProfile = _diagStringKeyMap(_sidecarProfileSnapshot);
    final repoFlavor = (sidecarHealth['repoFlavor'] ??
            sidecarProfile['repoFlavor'] ??
            _sidecarRepoFlavorHint)
        .toString()
        .trim();
    final variant = (sidecarHealth['variant'] ??
            sidecarProfile['variant'] ??
            _sidecarVariantHint)
        .toString()
        .trim();
    final activeProfile =
        (sidecarHealth['profile'] ?? sidecarProfile['profile'])
            .toString()
            .trim()
            .toLowerCase();
    final serviceHealth = _selectedSidecarServiceHealth();
    final nativeCameraDiag = _diagStringKeyMap(_lastNativeCameraDiag);
    return <String, dynamic>{
      'capturedAt': DateTime.now().toIso8601String(),
      'hostIp': _hostIp,
      'modeTag': _modeTagLabel,
      'overlayMode': _openpilotOverlayMode,
      'nativeCameraMode': _useNativeLiveCamera,
      'liveCamera': _liveCameraName,
      'flavorContext': <String, dynamic>{
        'repoFlavor': repoFlavor,
        'variant': variant,
        'profile': activeProfile,
        'bootstrapProfile': SidecarService.isBootstrapProfile(activeProfile),
        'profileOmitsCarState':
            SidecarService.profileOmitsCarState(activeProfile),
        'c4ReaderPressureRisk': repoFlavor == SidecarService.repoFlavorC4,
      },
      'camera': <String, dynamic>{
        'loading': _cameraLoading,
        'error': _cameraError,
        'lastFrameId': _lastCameraFrameId,
        'lastFrameAgeMs': lastFrameAgeMs,
        'syncMode': _diagNativeSyncMode(nativeCameraDiag),
        'sourceSize': <String, dynamic>{
          'width': _cameraSourceSize.width.round(),
          'height': _cameraSourceSize.height.round(),
        },
      },
      'overlay': <String, dynamic>{
        'fps': double.parse(_overlayDebugFps.toStringAsFixed(2)),
        'dropCountTotal': _overlayDropCount,
        'modelCameraGapLatest': _overlayModelCameraGap,
        'staleActive': _overlayStaleActive,
        'staleReason': _overlayStaleReason,
        'lastPublishedModelFrameId': _lastPublishedModelFrameId,
      },
      'sidecar': <String, dynamic>{
        'connected': _sidecarConnected,
        'phase': _sidecarPhase.name,
        'phaseMessage': _diagNormalizedPhaseMessage(
            _sidecarPhase.name, _sidecarPhaseMessage),
        'phaseMessageRaw': _sidecarPhaseMessage,
        'profile': sidecarHealth['profile'] ?? sidecarProfile['profile'],
        'variant': variant,
        'repoFlavor': repoFlavor,
        'startupProtectionActive': sidecarHealth['startupProtectionActive'],
        'radarReady': sidecarHealth['radarReady'],
        'radarFreshStable': sidecarHealth['radarFreshStable'],
        'radarExpected':
            SidecarService.profileRequiresFullRuntime(activeProfile),
        'staleReasons': _diagList(sidecarHealth['staleReasons']),
        'missingFields': _diagList(sidecarHealth['missingFields']),
        'serviceHealth': serviceHealth,
        'cameraRelay': _diagCameraRelaySummary(sidecarHealth),
        'frameIdRootCauseHint': _diagFrameIdRootCauseHint(
          native: nativeCameraDiag,
          sidecarHealth: sidecarHealth,
          serviceHealth: serviceHealth,
        ),
        'process': Map<String, String>.from(_sidecarProcessSnapshot),
      },
      'logs': <String, dynamic>{
        'driveDiagnostics': _driveDiagFilePath,
        'cameraDiagnostics': _lastCameraDiagFilePath,
      },
      'nativeCameraDiag': _lastNativeCameraDiag,
    };
  }

  Future<List<dynamic>> _readDriveDiagTailEvents({int maxLines = 80}) async {
    final path = _driveDiagFilePath;
    if (path == null || path.trim().isEmpty) {
      return const <dynamic>[];
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        return const <dynamic>[];
      }
      final lines = await file.readAsLines();
      if (lines.isEmpty) {
        return const <dynamic>[];
      }
      final start = math.max(0, lines.length - maxLines);
      final events = <dynamic>[];
      for (final line in lines.sublist(start)) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          events.add(jsonDecode(trimmed));
        } catch (_) {
          events.add(<String, dynamic>{'raw': trimmed});
        }
      }
      return events;
    } catch (_) {
      return const <dynamic>[];
    }
  }

  Future<Directory> _resolveDriveDiagExportDir() async {
    final base = await _resolveDriveDiagDir();
    final exportDir = Directory('${base.path}/exports');
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }
    return exportDir;
  }

  Future<void> _shareDriveDiagnosticsLogImpl() async {
    _emitDriveDiagSummary();
    final sink = _driveDiagSink;
    if (sink != null) {
      try {
        await sink.flush();
      } catch (_) {}
    }
    final payload = _driveDiagnosticsClipboardPayload();
    final tailEvents = await _readDriveDiagTailEvents();
    final exportDir = await _resolveDriveDiagExportDir();
    final now = DateTime.now();
    final exportFile = File(
      '${exportDir.path}/drive_diag_export_${_driveDiagTimestampForFileName(now)}.json',
    );
    final exportPayload = <String, dynamic>{
      'schema': 'carrotlink.drive_diagnostics.export.v1',
      'exportedAt': now.toIso8601String(),
      'summary': payload,
      'tailEvents': tailEvents,
      'attachments': <String, dynamic>{
        'driveDiagnostics': _driveDiagFilePath,
        'cameraDiagnostics': _lastCameraDiagFilePath,
      },
    };
    await exportFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(exportPayload),
    );

    final files = <XFile>[
      XFile(exportFile.path, mimeType: 'application/json'),
    ];
    final drivePath = _driveDiagFilePath;
    if (drivePath != null && drivePath.trim().isNotEmpty) {
      final driveFile = File(drivePath);
      if (await driveFile.exists()) {
        files.add(XFile(driveFile.path, mimeType: 'application/x-ndjson'));
      }
    }
    final cameraDiagPath = _lastCameraDiagFilePath;
    if (cameraDiagPath != null && cameraDiagPath.trim().isNotEmpty) {
      final cameraFile = File(cameraDiagPath);
      if (await cameraFile.exists()) {
        files.add(XFile(cameraFile.path, mimeType: 'text/plain'));
      }
    }

    final result = await Share.shareXFiles(
      files,
      subject: 'CarrotLink drive diagnostics',
      text: 'CarrotLink 주행 진단 로그입니다. host=$_hostIp mode=$_modeTagLabel',
    );
    _appendDriveDiagEvent(
      'log_shared',
      <String, dynamic>{
        'exportFile': exportFile.path,
        'logFile': _driveDiagFilePath,
        'cameraDiagFile': _lastCameraDiagFilePath,
        'shareStatus': result.status.name,
        'shareRaw': result.raw,
      },
    );
    if (!mounted) return;
    if (result.status == ShareResultStatus.dismissed) {
      _toast('로그 공유가 취소되었습니다.');
      return;
    }
    _toast('주행 로그 공유 창을 열었습니다.');
  }
}
