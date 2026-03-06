part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasOverlayPreviewComponents on _LiveDriveCanvasScreenState {
  String _overlayPreviewScenarioLabelImpl(_OverlayPreviewScenario scenario) {
    switch (scenario) {
      case _OverlayPreviewScenario.highwayStraight:
        return '직선 주행';
      case _OverlayPreviewScenario.gentleLeft:
        return '완만 좌회전';
      case _OverlayPreviewScenario.gentleRight:
        return '완만 우회전';
      case _OverlayPreviewScenario.traffic:
        return '정체/근접 리드';
    }
  }

  void _setOverlayPreviewModeImpl(bool enabled) {
    if (_debugOverlayPreviewMode == enabled) return;
    if (mounted) {
      _safeSetState(() {
        _debugOverlayPreviewMode = enabled;
        _cameraLoading = false;
        _cameraError = null;
        if (enabled) {
          _debugShowPathFill = true;
          _debugShowLaneLines = true;
          _debugShowRoadEdge = true;
          _debugShowLead1 = true;
          _debugShowLead2 = true;
          _debugShowRadarBadge = true;
          _debugShowRadarVector = true;
          _debugShowStopDistanceTf = true;
          _debugShowStateText = true;
        }
      });
    } else {
      _debugOverlayPreviewMode = enabled;
      _cameraLoading = false;
      _cameraError = null;
      if (enabled) {
        _debugShowPathFill = true;
        _debugShowLaneLines = true;
        _debugShowRoadEdge = true;
        _debugShowLead1 = true;
        _debugShowLead2 = true;
        _debugShowRadarBadge = true;
        _debugShowRadarVector = true;
        _debugShowStopDistanceTf = true;
        _debugShowStateText = true;
      }
    }

    if (enabled) {
      _startOverlayPreviewLoop();
      _toast('프리뷰 모드 활성화 (실데이터 없이 그래픽 확인)');
      return;
    }

    _stopOverlayPreviewLoop();
    if (_openpilotOverlayMode && _latestOverlaySnapshot.path.length >= 2) {
      _applyOverlaySnapshot(_latestOverlaySnapshot, forceNativePush: true);
    } else {
      _applyOverlaySnapshot(
        const _DriveOverlaySnapshot.empty(),
        forceNativePush: true,
      );
    }
    _toast('프리뷰 모드 비활성화');
  }

  void _startOverlayPreviewLoopImpl() {
    _overlayPreviewTimer?.cancel();
    _overlayPreviewFrameSeq = 0;
    _tickOverlayPreview();
    _overlayPreviewTimer =
        Timer.periodic(const Duration(milliseconds: 90), (_) {
      _tickOverlayPreview();
    });
  }

  void _stopOverlayPreviewLoopImpl() {
    _overlayPreviewTimer?.cancel();
    _overlayPreviewTimer = null;
  }

  void _tickOverlayPreviewImpl() {
    if (!_debugOverlayPreviewMode) return;
    _overlayPreviewFrameSeq += 1;
    final next = _buildOverlayPreviewSnapshot(seq: _overlayPreviewFrameSeq);
    _latestOverlaySnapshot = next;
    _applyOverlaySnapshot(next, forceNativePush: true);
    _sidecarLastFrameAt = DateTime.now();
    if (_overlayDebugWindowStartMs <= 0) {
      _overlayDebugWindowStartMs = DateTime.now().millisecondsSinceEpoch - 500;
    }
  }

  List<List<double>> _previewRoadPathVerticesImpl({
    required int sourceWidth,
    required int sourceHeight,
    required double t,
  }) {
    final horizon = sourceHeight * 0.34;
    double curveAmp;
    switch (_debugOverlayPreviewScenario) {
      case _OverlayPreviewScenario.highwayStraight:
        curveAmp = 0.0;
      case _OverlayPreviewScenario.gentleLeft:
        curveAmp = -220.0;
      case _OverlayPreviewScenario.gentleRight:
        curveAmp = 220.0;
      case _OverlayPreviewScenario.traffic:
        curveAmp = 40.0;
    }
    final pointsLeft = <List<double>>[];
    final pointsRight = <List<double>>[];
    for (var i = 0; i < 18; i++) {
      final u = i / 17.0;
      final y = (sourceHeight - 14.0) - (u * (sourceHeight - horizon - 14.0));
      final center = (sourceWidth * 0.5) +
          (curveAmp * u * u) +
          (math.sin(t + (u * 2.2)) *
              (_debugOverlayPreviewScenario == _OverlayPreviewScenario.traffic
                  ? 18.0
                  : 8.0));
      final halfW = ((1.0 - u) * 300.0 + 58.0).clamp(58.0, 300.0).toDouble();
      pointsLeft.add(<double>[center - halfW, y]);
      pointsRight.add(<double>[center + halfW, y]);
    }
    return <List<double>>[
      ...pointsLeft,
      ...pointsRight.reversed,
    ];
  }

  List<List<double>> _previewLanePolygonImpl({
    required int sourceWidth,
    required int sourceHeight,
    required double t,
    required double laneFactor,
    required double thickness,
  }) {
    final horizon = sourceHeight * 0.34;
    double curveAmp;
    switch (_debugOverlayPreviewScenario) {
      case _OverlayPreviewScenario.highwayStraight:
        curveAmp = 0.0;
      case _OverlayPreviewScenario.gentleLeft:
        curveAmp = -220.0;
      case _OverlayPreviewScenario.gentleRight:
        curveAmp = 220.0;
      case _OverlayPreviewScenario.traffic:
        curveAmp = 40.0;
    }
    final left = <List<double>>[];
    final right = <List<double>>[];
    for (var i = 0; i < 15; i++) {
      final u = i / 14.0;
      final y = (sourceHeight - 14.0) - (u * (sourceHeight - horizon - 14.0));
      final center = (sourceWidth * 0.5) +
          (curveAmp * u * u) +
          (math.sin(t + (u * 2.2)) *
              (_debugOverlayPreviewScenario == _OverlayPreviewScenario.traffic
                  ? 18.0
                  : 8.0));
      final halfW = ((1.0 - u) * 300.0 + 58.0).clamp(58.0, 300.0).toDouble();
      final laneX = center + (halfW * laneFactor);
      left.add(<double>[laneX - (thickness * 0.5), y]);
      right.add(<double>[laneX + (thickness * 0.5), y]);
    }
    return <List<double>>[
      ...left,
      ...right.reversed,
    ];
  }

  _DriveOverlaySnapshot _buildOverlayPreviewSnapshotImpl({required int seq}) {
    const sourceW = 1928;
    const sourceH = 1208;
    final t = seq * 0.05 * _debugOverlayPreviewSpeed;
    final pathVertices = _previewRoadPathVertices(
      sourceWidth: sourceW,
      sourceHeight: sourceH,
      t: t,
    );
    final leadNear =
        _debugOverlayPreviewScenario == _OverlayPreviewScenario.traffic;
    final leadU = leadNear ? 0.58 : 0.72;
    const horizon = sourceH * 0.34;
    double curveAmp;
    switch (_debugOverlayPreviewScenario) {
      case _OverlayPreviewScenario.highwayStraight:
        curveAmp = 0.0;
      case _OverlayPreviewScenario.gentleLeft:
        curveAmp = -220.0;
      case _OverlayPreviewScenario.gentleRight:
        curveAmp = 220.0;
      case _OverlayPreviewScenario.traffic:
        curveAmp = 40.0;
    }
    final leadY = (sourceH - 14.0) - (leadU * (sourceH - horizon - 14.0));
    final leadCenterX = (sourceW * 0.5) +
        (curveAmp * leadU * leadU) +
        (math.sin(t + (leadU * 2.2)) *
            (_debugOverlayPreviewScenario == _OverlayPreviewScenario.traffic
                ? 18.0
                : 8.0));
    final leadHalfW = (((1.0 - leadU) * 180.0) + (leadNear ? 130.0 : 92.0))
        .clamp(80.0, 180.0)
        .toDouble();
    final leadTop = leadY - (leadHalfW * 0.55);
    final leadBox = <List<double>>[
      <double>[leadCenterX - leadHalfW, leadTop],
      <double>[leadCenterX + leadHalfW, leadTop],
      <double>[leadCenterX + leadHalfW, leadY],
      <double>[leadCenterX - leadHalfW, leadY],
    ];
    final badgeDx = (leadHalfW * 0.88).clamp(58.0, 150.0).toDouble();
    final badgeDy = (leadHalfW * 0.56).clamp(44.0, 98.0).toDouble();
    final leadTwoHalfW = (leadHalfW * 0.72).clamp(56.0, 130.0).toDouble();
    final leadTwoCenterX = leadCenterX - (leadHalfW * 1.7);
    final leadTwoY = leadY + (leadHalfW * 0.32);
    final leadTwoTop = leadTwoY - (leadTwoHalfW * 0.58);
    final leadTwoBox = <List<double>>[
      <double>[leadTwoCenterX - leadTwoHalfW, leadTwoTop],
      <double>[leadTwoCenterX + leadTwoHalfW, leadTwoTop],
      <double>[leadTwoCenterX + leadTwoHalfW, leadTwoY],
      <double>[leadTwoCenterX - leadTwoHalfW, leadTwoY],
    ];
    final leadDist = leadNear ? 11.8 : 16.5;
    final visionDist = leadNear ? 12.5 : 17.7;
    final speedKph =
        _debugOverlayPreviewScenario == _OverlayPreviewScenario.traffic
            ? 28.0
            : 64.0;

    final sidecarOverlay2d = <String, dynamic>{
      'version': 1,
      'source': 'preview_mock',
      'cameraMode': 'road',
      'cameras': <String, dynamic>{
        'road': <String, dynamic>{
          'camera': 'road',
          'sourceWidth': sourceW.toDouble(),
          'sourceHeight': sourceH.toDouble(),
          'displayTransform': <String, dynamic>{
            'zoom': 1.0,
            'tx': 0.0,
            'ty': 0.0,
            'xOffset': 0.0,
            'yOffset': 0.0,
          },
          'modelFrameId': seq,
          'cameraFrameId': seq,
          'pathMode': 0,
          'pathColor': 3,
          'pathTrackVertices': pathVertices,
          'lanePolygons': <Map<String, dynamic>>[
            <String, dynamic>{
              'index': 1,
              'probability': 0.98,
              'points': _previewLanePolygon(
                sourceWidth: sourceW,
                sourceHeight: sourceH,
                t: t,
                laneFactor: -0.92,
                thickness: 9.0,
              ),
            },
            <String, dynamic>{
              'index': 2,
              'probability': 0.98,
              'points': _previewLanePolygon(
                sourceWidth: sourceW,
                sourceHeight: sourceH,
                t: t,
                laneFactor: 0.92,
                thickness: 9.0,
              ),
            },
          ],
          'roadEdgePolygons': const <Map<String, dynamic>>[],
          'leadAreaBoxes': <Map<String, dynamic>>[
            <String, dynamic>{
              'kind': 'leadOne',
              'points': leadBox,
              'radar': true,
              'radarTrackId': 2,
              'status': 1,
              'radarDistance': leadDist,
              'visionDistance': visionDist,
              'anchorCenter': <double>[leadCenterX, leadY],
              'anchorWidth': leadHalfW * 2.0,
              'radarBadgeCenter': <double>[
                leadCenterX - badgeDx,
                leadY + badgeDy
              ],
              'visionBadgeCenter': <double>[
                leadCenterX + badgeDx,
                leadY + badgeDy
              ],
              'stateTextCenter': <double>[
                leadCenterX,
                leadY + (badgeDy * 1.28)
              ],
              'strokeColorArgb': 0xFFFFA726,
              'fillColorArgb': 0x33000000,
              'radarBadgeColorArgb': 0xFFFF3B30,
              'visionBadgeColorArgb': 0xFF3D7BFF,
            },
            <String, dynamic>{
              'kind': 'leadTwo',
              'points': leadTwoBox,
              'radar': true,
              'radarTrackId': 12,
              'status': 1,
              'radarDistance': leadDist + 3.4,
              'anchorCenter': <double>[leadTwoCenterX, leadTwoY],
              'anchorWidth': leadTwoHalfW * 2.0,
              'strokeColorArgb': 0xFFB68A3A,
              'fillColorArgb': 0x33000000,
            },
          ],
          'radarTargets': <Map<String, dynamic>>[
            <String, dynamic>{
              'center': <double>[
                leadCenterX + (leadHalfW * 1.05),
                leadY + 20.0
              ],
              'speedMpsSigned': 4.9,
              'speedKphSigned': 17.6,
              'dRel': leadDist,
              'yRel': 0.1,
              'radar': true,
              'modelProb': 0.70,
              'future': <double>[
                leadCenterX + (leadHalfW * 1.18),
                leadY - 36.0
              ],
            },
            <String, dynamic>{
              'center': <double>[
                leadCenterX - (leadHalfW * 1.55),
                leadY + 14.0
              ],
              'speedMpsSigned': -5.6,
              'speedKphSigned': -20.1,
              'dRel': leadDist + 1.7,
              'yRel': -1.4,
              'radar': true,
              'modelProb': 0.82,
              'future': <double>[
                leadCenterX - (leadHalfW * 1.42),
                leadY - 20.0
              ],
            },
          ],
          'tfMarker': <String, dynamic>{
            'points': <List<double>>[
              <double>[leadCenterX - (leadHalfW * 0.7), leadY + 12.0],
              <double>[leadCenterX + (leadHalfW * 0.7), leadY + 12.0],
            ],
            'distance': leadDist,
            'tFollow': 1.20,
          },
          'meta': <String, dynamic>{
            'showRadarInfo': 3,
            'xState': 0,
            'trafficState': 0,
            'longActive': true,
            'vEgoMps': speedKph / 3.6,
            'brakeLights': false,
            'tFollow': 1.20,
            'desiredDistance': leadDist,
          },
        },
      },
    };
    sidecarOverlay2d['cameras']['wideRoad'] =
        sidecarOverlay2d['cameras']['road'];

    return _DriveOverlaySnapshot(
      path: const _XyzSeries(
        x: <double>[0, 5, 10, 15, 20, 30, 40, 60, 80],
        y: <double>[0, 0, 0, 0, 0, 0, 0, 0, 0],
        z: <double>[1.22, 1.22, 1.22, 1.22, 1.22, 1.22, 1.22, 1.22, 1.22],
      ),
      laneLines: const <_LaneLineSeries>[],
      roadEdges: const <_RoadEdgeSeries>[],
      active: true,
      activeLaneLine: true,
      carrotExperimentalMode: false,
      brakeLights: false,
      leadDetected: true,
      pathMode: 0,
      pathColor: 3,
      accel0: 0.0,
      aEgo: 0.0,
      speedMps: speedKph / 3.6,
      speedKph: speedKph,
      leftLaneLine: 20,
      rightLaneLine: 20,
      calibrationRpy: const <double>[0.0, 0.0, 0.0],
      wideFromDeviceEuler: const <double>[0.0, 0.0, 0.0],
      pathOffsetZ: 1.22,
      pathWidthRatio: 1.0,
      animationPhase: _pathAnimationPhase,
      modelFrameId: seq,
      roadFrameId: seq,
      wideRoadFrameId: seq,
      sidecarOverlay2d: sidecarOverlay2d,
      usingLateralPath: false,
      modelPathXMax: 80.0,
      lateralPathXMax: 0.0,
      navPathPoints: const <_NavPathPoint>[
        _NavPathPoint(x: 8.0, y: 0.0, d: 8.0),
        _NavPathPoint(x: 14.0, y: 0.2, d: 14.0),
        _NavPathPoint(x: 22.0, y: 0.6, d: 22.0),
        _NavPathPoint(x: 32.0, y: 1.3, d: 32.0),
      ],
      navTurnInfo: 2,
      navDistToTurn: 230.0,
      navMainText: '우회전',
    );
  }

  Widget _buildOverlayPreviewBackdropImpl() {
    return const CustomPaint(
      painter: _PreviewRoadBackdropPainter(),
      child: SizedBox.expand(),
    );
  }
}
