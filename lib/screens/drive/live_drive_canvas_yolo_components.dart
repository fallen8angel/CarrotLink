part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasYoloComponents on _LiveDriveCanvasScreenState {
  bool _driveYoloPayloadBoolValueImpl(
      Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'true' || text == '1' || text == 'yes';
  }

  Map<String, dynamic> _disabledDriveYoloConfigImpl([
    Map<String, dynamic>? base,
  ]) {
    return <String, dynamic>{
      if (base != null) ...base,
      'yoloEnabled': false,
      'enabled': false,
      'unsafeRuntimeEnabled': false,
      'yoloBoxes': false,
      'yoloLabels': false,
      'yoloTrafficLights': false,
      'yoloStats': false,
    };
  }

  Map<String, dynamic> _disabledDriveYoloStateImpl({
    String stage = 'disabled',
  }) {
    return <String, dynamic>{
      'enabled': false,
      'yoloEnabled': false,
      'runtimeReady': false,
      'yoloBoxes': false,
      'yoloLabels': false,
      'yoloTrafficLights': false,
      'yoloStats': false,
      'stage': stage,
      'parsedCandidateCount': 0,
      'parsedDetectionCount': 0,
      'parserAboveThresholdCount': 0,
      'parsedDetectionsPreview': const <String>[],
      'parsedDetections': const <Map<String, dynamic>>[],
    };
  }

  Future<void> _replaceDriveYoloRuntimeStatusImpl(
    YoloRuntimeStatusSnapshot snapshot, {
    bool persistConfig = false,
    bool persistState = false,
  }) async {
    if (mounted) {
      _safeSetState(() {
        _driveYoloRuntimeStatus = snapshot;
        _developerPlaybackStatusUpdatedAt = snapshot.updatedAt;
      });
    } else {
      _driveYoloRuntimeStatus = snapshot;
      _developerPlaybackStatusUpdatedAt = snapshot.updatedAt;
    }
    if (persistConfig) {
      await YoloRuntimeStatusStore.saveConfig(snapshot.config);
    }
    if (persistState) {
      await YoloRuntimeStatusStore.saveState(snapshot.state);
    }
  }

  Future<void> _clearDriveYoloRuntimeStatusImpl({
    Map<String, dynamic>? config,
    String stage = 'disabled',
  }) async {
    final snapshot = YoloRuntimeStatusSnapshot(
      config: _disabledDriveYoloConfigImpl(config),
      state: _disabledDriveYoloStateImpl(stage: stage),
      updatedAt: DateTime.now(),
    );
    await _replaceDriveYoloRuntimeStatusImpl(
      snapshot,
      persistConfig: config != null,
      persistState: true,
    );
  }

  int _driveYoloSourceIntValueImpl(String key) {
    final stateValue = _driveYoloRuntimeStatus.state[key];
    if (stateValue is int) return stateValue;
    if (stateValue is num) return stateValue.toInt();
    final configValue = _driveYoloRuntimeStatus.config[key];
    if (configValue is int) return configValue;
    if (configValue is num) return configValue.toInt();
    return int.tryParse('${stateValue ?? configValue ?? ''}') ?? 0;
  }

  bool _driveYoloSourceBoolValueImpl(String key) {
    final stateValue = _driveYoloRuntimeStatus.state[key];
    if (stateValue is bool) return stateValue;
    if (stateValue is num) return stateValue != 0;
    final stateText = stateValue?.toString().trim().toLowerCase() ?? '';
    if (stateText == 'true' || stateText == '1' || stateText == 'yes') {
      return true;
    }
    final configValue = _driveYoloRuntimeStatus.config[key];
    if (configValue is bool) return configValue;
    if (configValue is num) return configValue != 0;
    final configText = configValue?.toString().trim().toLowerCase() ?? '';
    return configText == 'true' || configText == '1' || configText == 'yes';
  }

  List<YoloDetection> _liveYoloDetectionsImpl() {
    return YoloDetection.listFromPayload(
      _driveYoloRuntimeStatus.state['parsedDetections'],
    );
  }

  Widget? _buildLiveYoloOverlayImpl({
    required Size fallbackSourceSize,
  }) {
    if (_isDeveloperPlaybackRequested) {
      return null;
    }
    final enabled = _driveYoloSourceBoolValueImpl('yoloEnabled');
    if (!enabled) {
      return null;
    }
    final rawDetections = _liveYoloDetectionsImpl();
    final showLabels = _driveYoloSourceBoolValueImpl('yoloLabels');
    final showStats = _driveYoloSourceBoolValueImpl('yoloStats');
    final forceVisibleBoxes = rawDetections.isNotEmpty &&
        !_driveYoloSourceBoolValueImpl('yoloBoxes') &&
        !showLabels;
    final showBoxes =
        _driveYoloSourceBoolValueImpl('yoloBoxes') || forceVisibleBoxes;
    if (!showBoxes && !showLabels && !showStats) {
      return null;
    }
    final sourceWidth = _driveYoloSourceIntValueImpl('sourceWidth');
    final sourceHeight = _driveYoloSourceIntValueImpl('sourceHeight');
    final sourceSize = Size(
      sourceWidth > 0 ? sourceWidth.toDouble() : fallbackSourceSize.width,
      sourceHeight > 0 ? sourceHeight.toDouble() : fallbackSourceSize.height,
    );
    final detections = _fuseLiveYoloDetectionsImpl(
      rawDetections,
      sourceSize: sourceSize,
    );
    // Detection age: pipeline latency in microseconds.
    final rawPipelineMs = _driveYoloRuntimeStatus.state['lastPipelineMs'];
    final detectionAgeUs = rawPipelineMs is num && rawPipelineMs > 0
        ? (rawPipelineMs * 1000).round()
        : 0;
    // Lead area rects for track anchoring.
    final syncedSnapshot = _liveYoloSyncedSnapshotImpl();
    final leadAreaRects = syncedSnapshot != null
        ? _liveYoloLeadAreasImpl(syncedSnapshot)
            .map((a) => a.rect)
            .toList(growable: false)
        : const <Rect>[];
    final overlayIdentity =
        'live_yolo_overlay_${_nativeCameraViewId ?? -1}_${_liveCameraName}_${sourceSize.width.round()}x${sourceSize.height.round()}';
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showBoxes || showLabels)
            RepaintBoundary(
              child: YoloDetectionOverlay(
                key: ValueKey<String>(overlayIdentity),
                detections: detections,
                sourceWidth: sourceSize.width,
                sourceHeight: sourceSize.height,
                showBoxes: showBoxes,
                showLabels: showLabels,
                detectionAgeUs: detectionAgeUs,
                leadAreas: leadAreaRects,
              ),
            ),
          if (showStats && detections.isNotEmpty)
            Positioned(
              left: 10,
              top: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.cyanAccent.withValues(alpha: 0.72),
                  ),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(
                    'YOLO ${detections.length} detections',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<YoloDetection> _fuseLiveYoloDetectionsImpl(
    List<YoloDetection> detections, {
    required Size sourceSize,
  }) {
    if (detections.isEmpty) {
      return detections;
    }
    final snapshot = _liveYoloSyncedSnapshotImpl();
    if (snapshot == null) {
      return detections;
    }
    final leadAreas = _liveYoloLeadAreasImpl(snapshot);
    final radarTargets = _liveYoloRadarCentersImpl(snapshot);
    final laneRegion = _liveYoloLaneRegionImpl(
      snapshot: snapshot,
      sourceSize: sourceSize,
    );
    final corridor = _liveYoloCorridorRectImpl(
      snapshot: snapshot,
      sourceSize: sourceSize,
      leadAreas: leadAreas,
      laneRegion: laneRegion,
    );
    final fused = <_DriveYoloFusedDetection>[];
    for (final detection in detections) {
      final f = _computeFusionFeatures(
        detection: detection,
        sourceSize: sourceSize,
        leadAreas: leadAreas,
        radarTargets: radarTargets,
        laneRegion: laneRegion,
        corridor: corridor,
      );
      final priority = _liveYoloFusionPriorityImpl(
        detection: detection,
        snapshot: snapshot,
        f: f,
      );
      if (!_keepLiveYoloDetectionImpl(
        detection: detection,
        sourceSize: sourceSize,
        snapshot: snapshot,
        f: f,
        priority: priority,
      )) {
        continue;
      }
      final adjustedScore = _liveYoloAdjustedScoreImpl(
        baseScore: detection.score,
        priority: priority,
      );
      fused.add(
        _DriveYoloFusedDetection(
          detection: detection.withScore(adjustedScore),
          priority: priority,
        ),
      );
    }
    if (fused.isEmpty) {
      return detections;
    }
    fused.sort(
      (left, right) => right.priority.compareTo(left.priority),
    );
    return fused
        .take(8)
        .map((entry) => entry.detection)
        .toList(growable: false);
  }

  _DriveOverlaySnapshot? _liveYoloSyncedSnapshotImpl() {
    final frameId = _driveYoloSourceIntValueImpl('lastFrameId');
    if (frameId > 0) {
      final synced = _findSyncedSnapshot(frameId, maxDelta: 4);
      if (synced != null) {
        return synced;
      }
      final current = _overlayNotifier.value;
      final currentDelta = _liveYoloSnapshotFrameDeltaImpl(current, frameId);
      if (currentDelta != null && currentDelta <= 4) {
        return current;
      }
      final latest = _latestOverlaySnapshot;
      final latestDelta = _liveYoloSnapshotFrameDeltaImpl(latest, frameId);
      if (latestDelta != null && latestDelta <= 4) {
        return latest;
      }
      return null;
    }
    return null;
  }

  int? _liveYoloSnapshotFrameDeltaImpl(
    _DriveOverlaySnapshot snapshot,
    int frameId,
  ) {
    if (frameId <= 0) {
      return null;
    }
    final deltas = <int>[];
    final cameraFrameId = _liveCameraKind == _DriveCameraKind.wideRoad
        ? snapshot.wideRoadFrameId
        : snapshot.roadFrameId;
    if (cameraFrameId != null && cameraFrameId > 0) {
      deltas.add((cameraFrameId - frameId).abs());
    }
    final modelFrameId = snapshot.modelFrameId;
    if (modelFrameId != null && modelFrameId > 0) {
      deltas.add((modelFrameId - frameId).abs());
    }
    if (deltas.isEmpty) {
      return null;
    }
    return deltas.reduce(math.min);
  }

  Map<String, dynamic>? _liveYoloCameraOverlay2dImpl(
    _DriveOverlaySnapshot snapshot,
  ) {
    final root = snapshot.sidecarOverlay2d;
    if (root == null) return null;
    final cameras = root['cameras'];
    if (cameras is! Map) return null;
    final key =
        _liveCameraKind == _DriveCameraKind.wideRoad ? 'wideRoad' : 'road';
    final selected = cameras[key];
    if (selected is! Map) return null;
    return Map<String, dynamic>.from(selected);
  }

  List<_DriveYoloLeadArea> _liveYoloLeadAreasImpl(
    _DriveOverlaySnapshot snapshot,
  ) {
    final cam = _liveYoloCameraOverlay2dImpl(snapshot);
    if (cam == null) {
      return const <_DriveYoloLeadArea>[];
    }
    final raw = cam['leadAreaBoxes'];
    if (raw is! List) {
      return const <_DriveYoloLeadArea>[];
    }
    final out = <_DriveYoloLeadArea>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final lead = Map<String, dynamic>.from(item);
      final bounds = _sourceBoundsFromOverlayPointsImpl(lead['points']);
      if (bounds == null) continue;
      out.add(
        _DriveYoloLeadArea(
          kind: lead['kind']?.toString() ?? 'lead',
          rect: bounds,
          radarDetected: _dynamicBoolImpl(lead['radar']),
        ),
      );
    }
    out.sort(
      (left, right) => (left.kind == 'leadOne' ? -1 : 1)
          .compareTo(right.kind == 'leadOne' ? -1 : 1),
    );
    return out;
  }

  List<Offset> _liveYoloRadarCentersImpl(_DriveOverlaySnapshot snapshot) {
    final cam = _liveYoloCameraOverlay2dImpl(snapshot);
    if (cam == null) {
      return const <Offset>[];
    }
    final raw = cam['radarTargets'];
    if (raw is! List) {
      return const <Offset>[];
    }
    final out = <Offset>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final center = _sourcePointFromOverlayPointImpl(item['center']);
      if (center == null) continue;
      out.add(center);
    }
    return out;
  }

  Rect _liveYoloCorridorRectImpl({
    required _DriveOverlaySnapshot snapshot,
    required Size sourceSize,
    required List<_DriveYoloLeadArea> leadAreas,
    _DriveYoloLaneRegion? laneRegion,
  }) {
    if (_shouldUseLaneRegionForCorridorImpl(laneRegion, sourceSize)) {
      final bounds = laneRegion!.bounds;
      final boundedWidth = bounds.width.clamp(
        sourceSize.width * 0.28,
        sourceSize.width * 0.72,
      );
      final boundedHeight = math.max(
        sourceSize.height * 0.56,
        bounds.height.clamp(
          sourceSize.height * 0.48,
          sourceSize.height * 0.92,
        ),
      );
      return Rect.fromCenter(
        center: Offset(
          bounds.center.dx.clamp(
            boundedWidth * 0.5,
            sourceSize.width - (boundedWidth * 0.5),
          ),
          bounds.center.dy.clamp(
            boundedHeight * 0.5,
            sourceSize.height - (boundedHeight * 0.5),
          ),
        ),
        width: boundedWidth,
        height: boundedHeight,
      );
    }
    var centerX = sourceSize.width * 0.5;
    if (leadAreas.isNotEmpty) {
      centerX = (centerX * 0.72) + (leadAreas.first.rect.center.dx * 0.28);
    }
    final direction = snapshot.laneChangeDirection;
    if (direction == 1) {
      centerX -= sourceSize.width * 0.08;
    } else if (direction == 2) {
      centerX += sourceSize.width * 0.08;
    }
    var width = sourceSize.width *
        (snapshot.activeLaneLine ? 0.42 : 0.50) *
        (snapshot.useLaneLineSpeed > 0 ? 0.92 : 1.0);
    if (snapshot.leftBlindspot || snapshot.rightBlindspot) {
      width *= 1.08;
    }
    width = width.clamp(sourceSize.width * 0.30, sourceSize.width * 0.66);
    return Rect.fromCenter(
      center: Offset(
        centerX.clamp(width * 0.5, sourceSize.width - (width * 0.5)),
        sourceSize.height * 0.58,
      ),
      width: width,
      height: sourceSize.height * 0.84,
    );
  }

  bool _shouldUseLaneRegionForCorridorImpl(
    _DriveYoloLaneRegion? laneRegion,
    Size sourceSize,
  ) {
    if (laneRegion == null) {
      return false;
    }
    final laneConfidence = _laneConfidenceImpl(laneRegion);
    if (laneConfidence < 0.55) {
      return false;
    }
    if (laneRegion.centerLine.length < 4) {
      return false;
    }
    final bounds = laneRegion.bounds;
    if (bounds.width < sourceSize.width * 0.18 ||
        bounds.height < sourceSize.height * 0.24) {
      return false;
    }
    return true;
  }

  _FusionFeatures _computeFusionFeatures({
    required YoloDetection detection,
    required Size sourceSize,
    required List<_DriveYoloLeadArea> leadAreas,
    required List<Offset> radarTargets,
    required _DriveYoloLaneRegion? laneRegion,
    required Rect corridor,
  }) {
    final rect = Rect.fromLTRB(
      detection.sourceLeft,
      detection.sourceTop,
      detection.sourceRight,
      detection.sourceBottom,
    );
    final centerXNorm =
        (detection.sourceCenterX / sourceSize.width).clamp(0.0, 1.0);
    final centerYNorm =
        (detection.sourceCenterY / sourceSize.height).clamp(0.0, 1.0);
    final centerBias =
        (1.0 - ((centerXNorm - 0.5).abs() / 0.5)).clamp(0.0, 1.0);
    final topBias = (1.0 - (centerYNorm / 0.62)).clamp(0.0, 1.0);
    final bottomBias = ((centerYNorm - 0.18) / 0.82).clamp(0.0, 1.0);
    final detectionArea = math.max(rect.width * rect.height, 1.0);
    final corridorArea =
        _rectIntersectionAreaImpl(rect, corridor) / detectionArea;
    final inCorridor = corridor.contains(rect.center);
    final laneConfidence = _laneConfidenceImpl(laneRegion);
    final laneCoverage = _laneCoverageImpl(rect, laneRegion);
    final laneInside = laneCoverage >= 0.34;
    final laneWeight = _laneWeightImpl(laneConfidence);
    final weightedLaneCoverage = laneCoverage * laneWeight;
    final pathAffinity = _pathAffinityImpl(rect.center, laneRegion);
    final weightedPathAffinity =
        pathAffinity * (0.45 + (laneConfidence * 0.55));
    final corridorCenterBias = (1.0 -
            ((rect.center.dx - corridor.center.dx).abs() /
                math.max(corridor.width * 0.60, 1.0)))
        .clamp(0.0, 1.0);
    final onLeftSide = rect.center.dx < (sourceSize.width * 0.46);
    final onRightSide = rect.center.dx > (sourceSize.width * 0.54);
    var leadIou = 0.0;
    var leadDistanceBias = 0.0;
    for (final leadArea in leadAreas) {
      leadIou = math.max(leadIou, _rectIouImpl(rect, leadArea.rect));
      final dx = rect.center.dx - leadArea.rect.center.dx;
      final dy = rect.center.dy - leadArea.rect.center.dy;
      final distance = math.sqrt((dx * dx) + (dy * dy));
      final maxDistance = math.max(
        96.0,
        math.max(leadArea.rect.width, leadArea.rect.height) * 1.8,
      );
      leadDistanceBias = math.max(
        leadDistanceBias,
        (1.0 - (distance / maxDistance)).clamp(0.0, 1.0),
      );
    }
    var radarAffinity = 0.0;
    for (final point in radarTargets) {
      final dx = rect.center.dx - point.dx;
      final dy = rect.center.dy - point.dy;
      final distance = math.sqrt((dx * dx) + (dy * dy));
      radarAffinity = math.max(
        radarAffinity,
        (1.0 - (distance / math.max(140.0, sourceSize.width * 0.20)))
            .clamp(0.0, 1.0),
      );
    }
    return _FusionFeatures(
      rect: rect,
      centerXNorm: centerXNorm,
      centerYNorm: centerYNorm,
      centerBias: centerBias,
      topBias: topBias,
      bottomBias: bottomBias,
      corridorArea: corridorArea,
      inCorridor: inCorridor,
      laneConfidence: laneConfidence,
      laneCoverage: laneCoverage,
      weightedLaneCoverage: weightedLaneCoverage,
      laneInside: laneInside,
      weightedPathAffinity: weightedPathAffinity,
      corridorCenterBias: corridorCenterBias,
      leadIou: leadIou,
      leadDistanceBias: leadDistanceBias,
      radarAffinity: radarAffinity,
      onLeftSide: onLeftSide,
      onRightSide: onRightSide,
    );
  }

  double _liveYoloFusionPriorityImpl({
    required YoloDetection detection,
    required _DriveOverlaySnapshot snapshot,
    required _FusionFeatures f,
  }) {
    final trafficContext =
        (snapshot.trafficState > 0 || snapshot.xState > 0) ? 0.12 : 0.0;
    final laneChangeContext = snapshot.laneChangeState > 0 ? 0.06 : 0.0;
    final blindspotContext = ((snapshot.leftBlindspot && f.onLeftSide) ||
            (snapshot.rightBlindspot && f.onRightSide))
        ? 0.12
        : 0.0;
    final laneChangeSideContext =
        ((snapshot.laneChangeDirection == 1 && f.onLeftSide) ||
                (snapshot.laneChangeDirection == 2 && f.onRightSide))
            ? 0.10
            : 0.0;
    switch (detection.classId) {
      case 9:
        return ((detection.score * 0.72) +
                (f.topBias * 0.38) +
                (f.centerBias * 0.12) +
                (f.corridorCenterBias * 0.18) +
                (f.weightedPathAffinity * 0.04) +
                trafficContext)
            .clamp(0.0, 1.35);
      case 2:
      case 5:
      case 7:
        return ((detection.score * 0.74) +
                (f.centerBias * 0.20) +
                (f.bottomBias * 0.18) +
                (f.weightedLaneCoverage * 0.40) +
                (f.laneInside ? 0.12 : 0.0) +
                (f.weightedPathAffinity * 0.28) +
                (f.corridorArea * 0.34) +
                (f.inCorridor ? 0.08 : 0.0) +
                (f.leadIou * 0.62) +
                (f.leadDistanceBias * 0.26) +
                (f.radarAffinity * 0.28) +
                laneChangeContext +
                blindspotContext +
                laneChangeSideContext)
            .clamp(0.0, 1.60);
      case 0:
      case 1:
      case 3:
        return ((detection.score * 0.76) +
                (f.bottomBias * 0.18) +
                (f.weightedLaneCoverage * 0.22) +
                (f.weightedPathAffinity * 0.12) +
                (f.corridorArea * 0.20) +
                (f.centerBias * 0.12) +
                (f.radarAffinity * 0.10) +
                blindspotContext +
                laneChangeSideContext)
            .clamp(0.0, 1.25);
      default:
        return ((detection.score * 0.84) + (f.centerBias * 0.10))
            .clamp(0.0, 1.05);
    }
  }

  bool _keepLiveYoloDetectionImpl({
    required YoloDetection detection,
    required Size sourceSize,
    required _DriveOverlaySnapshot snapshot,
    required _FusionFeatures f,
    required double priority,
  }) {
    switch (detection.classId) {
      case 9:
        if (f.centerYNorm > 0.72) return false;
        if (f.centerYNorm > 0.56 &&
            f.corridorCenterBias < 0.28 &&
            snapshot.trafficState <= 0 &&
            snapshot.xState <= 0 &&
            detection.score < 0.18) {
          return false;
        }
        if ((f.rect.width / sourceSize.width) > 0.22 &&
            detection.score < 0.18) {
          return false;
        }
        return priority >= 0.10;
      case 2:
      case 5:
      case 7:
        if (f.centerYNorm < 0.16 &&
            f.leadIou < 0.08 &&
            f.radarAffinity < 0.12 &&
            f.weightedLaneCoverage < 0.10 &&
            detection.score < 0.16) {
          return false;
        }
        if (f.corridorArea < 0.04 &&
            f.weightedLaneCoverage < 0.12 &&
            f.weightedPathAffinity < 0.18 &&
            f.radarAffinity < 0.10 &&
            f.leadIou < 0.06 &&
            detection.score < 0.10) {
          return false;
        }
        return priority >= 0.12;
      case 0:
      case 1:
      case 3:
        if (f.centerYNorm < 0.24 && detection.score < 0.13) {
          return false;
        }
        return priority >= 0.10;
      default:
        return priority >= 0.08;
    }
  }

  double _liveYoloAdjustedScoreImpl({
    required double baseScore,
    required double priority,
  }) {
    final delta = (priority - baseScore).clamp(-0.06, 0.16);
    return (baseScore + delta).clamp(0.0, 0.99);
  }

  double _laneWeightImpl(double laneConfidence) {
    if (laneConfidence <= 0.20) {
      return 0.0;
    }
    return (0.10 + (laneConfidence * 0.90)).clamp(0.0, 1.0);
  }

  _DriveYoloLaneRegion? _liveYoloLaneRegionImpl({
    required _DriveOverlaySnapshot snapshot,
    required Size sourceSize,
  }) {
    if (snapshot.laneLines.length < 3 || snapshot.path.length < 2) {
      return null;
    }
    final transform = _liveYoloProjectionTransformImpl(
      snapshot: snapshot,
      sourceSize: sourceSize,
    );
    if (transform == null) {
      return null;
    }
    final sceneMaxDistance = _liveYoloSceneMaxDistanceImpl(snapshot);
    final laneBaseX = snapshot.laneLines.first.line.x.isNotEmpty
        ? snapshot.laneLines.first.line.x
        : snapshot.path.x;
    final laneMaxIdx = laneBaseX.isNotEmpty
        ? _liveYoloGetPathLengthIdxImpl(laneBaseX, sceneMaxDistance)
        : _liveYoloGetPathLengthIdxImpl(snapshot.path.x, sceneMaxDistance);
    final leftLane = snapshot.laneLines[1];
    final rightLane = snapshot.laneLines[2];
    if (leftLane.line.length < 2 || rightLane.line.length < 2) {
      return null;
    }
    final laneProjection = _liveYoloProjectLanePairImpl(
      transform: transform,
      leftLane: leftLane.line,
      rightLane: rightLane.line,
      maxIdx: laneMaxIdx,
    );
    if (laneProjection == null) {
      return null;
    }
    final centerPoints = _liveYoloProjectSeriesImpl(
      transform,
      snapshot.path,
      _liveYoloGetPathLengthIdxImpl(snapshot.path.x, sceneMaxDistance),
    );
    final polygon = <Offset>[
      ...laneProjection.left,
      ...laneProjection.right.reversed,
    ];
    final path = _pathFromPolygonImpl(polygon);
    if (path == null) {
      return null;
    }
    Rect? bounds;
    for (final point in polygon) {
      bounds = bounds == null
          ? Rect.fromLTWH(point.dx, point.dy, 0.0, 0.0)
          : bounds.expandToInclude(
              Rect.fromLTWH(point.dx, point.dy, 0.0, 0.0),
            );
    }
    if (bounds == null || bounds.width <= 0.0 || bounds.height <= 0.0) {
      return null;
    }
    return _DriveYoloLaneRegion(
      path: path,
      bounds: bounds.inflate(8.0),
      centerLine:
          centerPoints.isNotEmpty ? centerPoints : laneProjection.center,
      leftConfidence: leftLane.probability,
      rightConfidence: rightLane.probability,
    );
  }

  _DriveYoloLaneProjection? _liveYoloProjectLanePairImpl({
    required _ProjectionTransform transform,
    required _XyzSeries leftLane,
    required _XyzSeries rightLane,
    required int maxIdx,
  }) {
    if (leftLane.length < 2 || rightLane.length < 2) {
      return null;
    }
    final leftPoints = <Offset>[];
    final rightPoints = <Offset>[];
    final centerPoints = <Offset>[];
    final end = math.min(
      maxIdx,
      math.min(leftLane.length, rightLane.length) - 1,
    );

    double? lastLeftY;
    double? lastRightY;
    double? lastCenterY;
    double? lastWidth;

    for (var i = 0; i <= end; i++) {
      final leftX = leftLane.x[i];
      final rightX = rightLane.x[i];
      if (!leftX.isFinite || !rightX.isFinite || leftX < 0.0 || rightX < 0.0) {
        continue;
      }

      Offset? leftPoint;
      Offset? rightPoint;
      final leftOk = _liveYoloMapToSourceImpl(
        transform,
        leftX,
        leftLane.y[i],
        leftLane.z[i],
        (value) => leftPoint = value,
      );
      final rightOk = _liveYoloMapToSourceImpl(
        transform,
        rightX,
        rightLane.y[i],
        rightLane.z[i],
        (value) => rightPoint = value,
      );
      if (!leftOk || !rightOk || leftPoint == null || rightPoint == null) {
        continue;
      }

      final lp = leftPoint!;
      final rp = rightPoint!;
      if (lp.dx >= (rp.dx - 4.0)) {
        continue;
      }

      final center = Offset((lp.dx + rp.dx) * 0.5, (lp.dy + rp.dy) * 0.5);
      final width = rp.dx - lp.dx;
      if (leftPoints.isNotEmpty) {
        if (lastLeftY != null && lp.dy > (lastLeftY + 20.0)) {
          continue;
        }
        if (lastRightY != null && rp.dy > (lastRightY + 20.0)) {
          continue;
        }
        if (lastCenterY != null && center.dy > (lastCenterY + 20.0)) {
          continue;
        }
        if (lastWidth != null && width > (lastWidth * 1.25)) {
          continue;
        }
      }

      leftPoints.add(lp);
      rightPoints.add(rp);
      centerPoints.add(center);
      lastLeftY = lp.dy;
      lastRightY = rp.dy;
      lastCenterY = center.dy;
      lastWidth = width;
    }

    if (leftPoints.length < 3 || rightPoints.length < 3) {
      return null;
    }
    return _DriveYoloLaneProjection(
      left: leftPoints,
      right: rightPoints,
      center: centerPoints,
    );
  }

  _ProjectionTransform? _liveYoloProjectionTransformImpl({
    required _DriveOverlaySnapshot snapshot,
    required Size sourceSize,
  }) {
    if (sourceSize.width <= 1.0 || sourceSize.height <= 1.0) {
      return null;
    }
    final src = _liveYoloEffectiveSourceSizeImpl(sourceSize);
    final calibTransform = _liveYoloCalibTransformForSourceImpl(
      snapshot,
      src,
    );
    return _ProjectionTransform(
      carSpaceTransform: calibTransform,
      clip: Rect.fromLTWH(0.0, 0.0, src.width, src.height),
      sourceScale: 1.0,
      xOffset: 0.0,
      yOffset: 0.0,
    );
  }

  Size _liveYoloEffectiveSourceSizeImpl(Size sourceSize) {
    if (sourceSize.width <= 1.0 || sourceSize.height <= 1.0) {
      return sourceSize;
    }
    final dw = (sourceSize.width - _DriveOverlayPainter._baseSourceWidth).abs();
    final dh =
        (sourceSize.height - _DriveOverlayPainter._baseSourceHeight).abs();
    if (dw <= 16.0 && dh <= 16.0) {
      return const Size(
        _DriveOverlayPainter._baseSourceWidth,
        _DriveOverlayPainter._baseSourceHeight,
      );
    }
    final c4Dw =
        (sourceSize.width - _DriveOverlayPainter._c4CanonicalSourceWidth).abs();
    final c4Dh =
        (sourceSize.height - _DriveOverlayPainter._c4CanonicalSourceHeight)
            .abs();
    final c4AltDh = (sourceSize.height - 768.0).abs();
    if (c4Dw <= 8.0 && (c4Dh <= 12.0 || c4AltDh <= 12.0)) {
      return const Size(
        _DriveOverlayPainter._c4CanonicalSourceWidth,
        _DriveOverlayPainter._c4CanonicalSourceHeight,
      );
    }
    return sourceSize;
  }

  _M3 _liveYoloCalibTransformForSourceImpl(
    _DriveOverlaySnapshot snapshot,
    Size source,
  ) {
    final wideCam = _liveCameraKind == _DriveCameraKind.wideRoad;
    final intrinsic = _liveYoloIntrinsicForSourceImpl(source, wideCam);
    final deviceFromCalib =
        _liveYoloRotationFromEulerImpl(snapshot.calibrationRpy);
    final wideFromDevice = wideCam
        ? _liveYoloRotationFromEulerImpl(snapshot.wideFromDeviceEuler)
        : const _M3.identity();
    final viewFromCalib = wideCam
        ? _LiveDriveCanvasScreenState._viewFromDevice
            .multiply(wideFromDevice.multiply(deviceFromCalib))
        : _LiveDriveCanvasScreenState._viewFromDevice.multiply(deviceFromCalib);
    return intrinsic.multiply(viewFromCalib);
  }

  _M3 _liveYoloRotationFromEulerImpl(List<double> rpy) {
    if (rpy.length < 3) return const _M3.identity();
    final roll = rpy[0];
    final pitch = rpy[1];
    final yaw = rpy[2];
    final cr = math.cos(roll);
    final sr = math.sin(roll);
    final cp = math.cos(pitch);
    final sp = math.sin(pitch);
    final cy = math.cos(yaw);
    final sy = math.sin(yaw);
    final rx = _M3(
      1.0,
      0.0,
      0.0,
      0.0,
      cr,
      -sr,
      0.0,
      sr,
      cr,
    );
    final ry = _M3(
      cp,
      0.0,
      sp,
      0.0,
      1.0,
      0.0,
      -sp,
      0.0,
      cp,
    );
    final rz = _M3(
      cy,
      -sy,
      0.0,
      sy,
      cy,
      0.0,
      0.0,
      0.0,
      1.0,
    );
    return rz.multiply(ry).multiply(rx);
  }

  _M3 _liveYoloIntrinsicForSourceImpl(Size source, bool wideCam) {
    final sx = source.width / _DriveOverlayPainter._baseSourceWidth;
    final sy = source.height / _DriveOverlayPainter._baseSourceHeight;
    final focal = wideCam ? 567.0 : 2648.0;
    return _M3(
      focal * sx,
      0.0,
      964.0 * sx,
      0.0,
      focal * sy,
      604.0 * sy,
      0.0,
      0.0,
      1.0,
    );
  }

  List<Offset> _liveYoloProjectSeriesImpl(
    _ProjectionTransform transform,
    _XyzSeries line,
    int maxIdx,
  ) {
    if (line.length < 2) {
      return const <Offset>[];
    }
    final points = <Offset>[];
    final end = math.min(maxIdx, line.length - 1);
    for (var i = 0; i <= end; i++) {
      final lx = line.x[i];
      if (!lx.isFinite || lx < 0.0) continue;
      final ly = line.y[i];
      final lz = line.z[i];
      Offset? point;
      final ok = _liveYoloMapToSourceImpl(
        transform,
        lx,
        ly,
        lz,
        (value) => point = value,
      );
      if (!ok || point == null) continue;
      if (points.isNotEmpty && point!.dy > (points.last.dy + 32.0)) {
        continue;
      }
      points.add(point!);
    }
    return points;
  }

  bool _liveYoloMapToSourceImpl(
    _ProjectionTransform transform,
    double inX,
    double inY,
    double inZ,
    void Function(Offset) onPoint,
  ) {
    final projected = transform.carSpaceTransform.transform(_V3(inX, inY, inZ));
    if (!projected.z.isFinite || projected.z <= 1e-3) {
      return false;
    }
    final out = Offset(projected.x / projected.z, projected.y / projected.z);
    if (!transform.clip.contains(out)) {
      return false;
    }
    onPoint(out);
    return true;
  }

  int _liveYoloGetPathLengthIdxImpl(List<double> lineX, double pathHeight) {
    var maxIdx = 0;
    for (var i = 1; i < lineX.length && lineX[i] <= pathHeight; i++) {
      maxIdx = i;
    }
    return maxIdx;
  }

  double _liveYoloSceneMaxDistanceImpl(_DriveOverlaySnapshot snapshot) {
    final modelMax = snapshot.path.x.isNotEmpty ? snapshot.path.x.last : 0.0;
    var maxDistance = modelMax.clamp(10.0, 100.0).toDouble();
    final leadOne = snapshot.leadOne;
    if (leadOne != null &&
        leadOne.status &&
        leadOne.dRel.isFinite &&
        leadOne.dRel > 0.0) {
      maxDistance = math.min(maxDistance, leadOne.dRel);
    }
    return maxDistance;
  }

  Path? _pathFromPolygonImpl(List<Offset> vertices) {
    if (vertices.length < 3) {
      return null;
    }
    final path = Path()..moveTo(vertices.first.dx, vertices.first.dy);
    for (var i = 1; i < vertices.length; i++) {
      path.lineTo(vertices[i].dx, vertices[i].dy);
    }
    path.close();
    return path;
  }

  double _laneCoverageImpl(Rect rect, _DriveYoloLaneRegion? laneRegion) {
    if (laneRegion == null) {
      return 0.0;
    }
    final samplePoints = <Offset>[
      rect.center,
      Offset(rect.left + (rect.width * 0.25), rect.bottom - 2.0),
      Offset(rect.right - (rect.width * 0.25), rect.bottom - 2.0),
      Offset(rect.center.dx, rect.bottom - 2.0),
    ];
    var inside = 0;
    for (final point in samplePoints) {
      if (laneRegion.path.contains(point)) {
        inside += 1;
      }
    }
    return inside / samplePoints.length;
  }

  double _pathAffinityImpl(Offset center, _DriveYoloLaneRegion? laneRegion) {
    if (laneRegion == null || laneRegion.centerLine.isEmpty) {
      return 0.0;
    }
    var bestDistance = double.infinity;
    for (final point in laneRegion.centerLine) {
      final dx = center.dx - point.dx;
      final dy = center.dy - point.dy;
      final distance = math.sqrt((dx * dx) + (dy * dy));
      if (distance < bestDistance) {
        bestDistance = distance;
      }
    }
    if (!bestDistance.isFinite) {
      return 0.0;
    }
    final maxDistance = math.max(72.0, laneRegion.bounds.width * 0.42);
    return (1.0 - (bestDistance / maxDistance)).clamp(0.0, 1.0);
  }

  double _laneConfidenceImpl(_DriveYoloLaneRegion? laneRegion) {
    if (laneRegion == null) {
      return 0.0;
    }
    return ((laneRegion.leftConfidence + laneRegion.rightConfidence) * 0.5)
        .clamp(0.0, 1.0);
  }

  Rect? _sourceBoundsFromOverlayPointsImpl(dynamic raw) {
    final points = _decodeOverlaySourcePointsImpl(raw);
    if (points.length < 3) {
      return null;
    }
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final point in points) {
      minX = math.min(minX, point.dx);
      minY = math.min(minY, point.dy);
      maxX = math.max(maxX, point.dx);
      maxY = math.max(maxY, point.dy);
    }
    if (!minX.isFinite ||
        !minY.isFinite ||
        !maxX.isFinite ||
        !maxY.isFinite ||
        maxX <= minX ||
        maxY <= minY) {
      return null;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  Offset? _sourcePointFromOverlayPointImpl(dynamic raw) {
    if (raw is List && raw.length >= 2) {
      final dx = _driveYoloSourceDoubleValueImpl(raw[0]);
      final dy = _driveYoloSourceDoubleValueImpl(raw[1]);
      if (dx != null && dy != null) {
        return Offset(dx, dy);
      }
    }
    return null;
  }

  List<Offset> _decodeOverlaySourcePointsImpl(dynamic raw) {
    if (raw is! List) {
      return const <Offset>[];
    }
    final out = <Offset>[];
    if (raw.length >= 2 && raw.first is List) {
      for (final item in raw) {
        final point = _sourcePointFromOverlayPointImpl(item);
        if (point != null) {
          out.add(point);
        }
      }
      return out;
    }
    if (raw.length >= 6) {
      for (var i = 0; i + 1 < raw.length; i += 2) {
        final point = _sourcePointFromOverlayPointImpl(
          <dynamic>[raw[i], raw[i + 1]],
        );
        if (point != null) {
          out.add(point);
        }
      }
    }
    return out;
  }

  double? _driveYoloSourceDoubleValueImpl(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse('${value ?? ''}');
  }

  bool _dynamicBoolImpl(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'true' || text == '1' || text == 'yes';
  }

  double _rectIouImpl(Rect a, Rect b) {
    final intersection = _rectIntersectionAreaImpl(a, b);
    if (intersection <= 0.0) {
      return 0.0;
    }
    final union = (a.width * a.height) + (b.width * b.height) - intersection;
    if (union <= 0.0) {
      return 0.0;
    }
    return intersection / union;
  }

  double _rectIntersectionAreaImpl(Rect a, Rect b) {
    final intersection = a.intersect(b);
    if (intersection.isEmpty) {
      return 0.0;
    }
    return intersection.width * intersection.height;
  }

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

  Future<void> _maybeAutoFallbackDriveYoloFromRuntimeStatusImpl(
    YoloRuntimeStatusSnapshot snapshot,
  ) async {
    final current = _driveYoloDebugSettings;
    if (_isDeveloperPlaybackRequested || !_canUseNativeCamera) {
      return;
    }
    if (!current.enabled) {
      return;
    }
    if (!YoloRuntimePolicy.shouldFallbackFromRuntimeFailure(
        current, snapshot)) {
      return;
    }
    final YoloDebugSettings fallback;
    if (current.runtimeBackend == YoloRuntimeBackend.liteRtGpu) {
      fallback = YoloRuntimePolicy.fallbackToLiteRtCpu(current);
    } else if (current.runtimeBackend == YoloRuntimeBackend.liteRtCpu) {
      fallback = YoloRuntimePolicy.fallbackToExecuTorchXnnpack(current);
    } else {
      fallback = current;
    }
    if (fallback == current) {
      return;
    }
    await _setDriveYoloDebugSettingsImpl(fallback);
    if (mounted) {
      final message = current.runtimeBackend == YoloRuntimeBackend.liteRtGpu
          ? 'LiteRT GPU 실패로 LiteRT CPU로 전환했습니다.'
          : 'LiteRT CPU 실패로 ExecuTorch XNNPACK으로 전환했습니다.';
      _toast(message);
    }
  }

  Future<YoloDebugSettings> _currentYoloDebugSettingsForNativeImpl() async {
    if (_isDeveloperPlaybackRequested || !_canUseNativeCamera) {
      return YoloDebugSettings.empty;
    }
    try {
      final settings = await YoloDebugSettingsStore.load();
      return settings.enabled ? settings : YoloDebugSettings.empty;
    } catch (_) {
      return YoloDebugSettings.empty;
    }
  }

  Future<void> _setDriveYoloDebugSettingsImpl(YoloDebugSettings next) async {
    if (_driveYoloDebugSettings == next) return;
    _safeSetState(() {
      _driveYoloDebugSettings = next;
    });
    final saved = await YoloDebugSettingsStore.save(next);
    if (saved != next) {
      if (mounted) {
        _safeSetState(() {
          _driveYoloDebugSettings = saved;
        });
      } else {
        _driveYoloDebugSettings = saved;
      }
    }
    if (_isDeveloperPlaybackRequested) {
      _syncDeveloperPlaybackLoop();
    } else {
      unawaited(_pushNativeYoloConfig(force: true));
    }
    if (!saved.enabled) {
      await _clearDriveYoloRuntimeStatusImpl(
        config: saved.toJson(),
        stage: 'disabled',
      );
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
    await _maybeAutoFallbackDriveYoloFromRuntimeStatusImpl(snapshot);
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

class _DriveYoloLeadArea {
  const _DriveYoloLeadArea({
    required this.kind,
    required this.rect,
    required this.radarDetected,
  });

  final String kind;
  final Rect rect;
  final bool radarDetected;
}

class _DriveYoloLaneProjection {
  const _DriveYoloLaneProjection({
    required this.left,
    required this.right,
    required this.center,
  });

  final List<Offset> left;
  final List<Offset> right;
  final List<Offset> center;
}

class _DriveYoloLaneRegion {
  const _DriveYoloLaneRegion({
    required this.path,
    required this.bounds,
    required this.centerLine,
    required this.leftConfidence,
    required this.rightConfidence,
  });

  final Path path;
  final Rect bounds;
  final List<Offset> centerLine;
  final double leftConfidence;
  final double rightConfidence;
}

class _DriveYoloFusedDetection {
  const _DriveYoloFusedDetection({
    required this.detection,
    required this.priority,
  });

  final YoloDetection detection;
  final double priority;
}

class _FusionFeatures {
  const _FusionFeatures({
    required this.rect,
    required this.centerXNorm,
    required this.centerYNorm,
    required this.centerBias,
    required this.topBias,
    required this.bottomBias,
    required this.corridorArea,
    required this.inCorridor,
    required this.laneConfidence,
    required this.laneCoverage,
    required this.weightedLaneCoverage,
    required this.laneInside,
    required this.weightedPathAffinity,
    required this.corridorCenterBias,
    required this.leadIou,
    required this.leadDistanceBias,
    required this.radarAffinity,
    required this.onLeftSide,
    required this.onRightSide,
  });

  final Rect rect;
  final double centerXNorm;
  final double centerYNorm;
  final double centerBias;
  final double topBias;
  final double bottomBias;
  final double corridorArea;
  final bool inCorridor;
  final double laneConfidence;
  final double laneCoverage;
  final double weightedLaneCoverage;
  final bool laneInside;
  final double weightedPathAffinity;
  final double corridorCenterBias;
  final double leadIou;
  final double leadDistanceBias;
  final double radarAffinity;
  final bool onLeftSide;
  final bool onRightSide;
}
