part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasOverlayPreviewComponents
    on _LiveDriveCanvasScreenState {
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

  String _overlayPreviewPlotModeLabelImpl(int mode) {
    switch (mode) {
      case 0:
        return '꺼짐';
      case 1:
        return '1. Accel';
      case 2:
        return '2. Speed/Accel';
      case 3:
        return '3. Model';
      case 4:
        return '4. Lead';
      case 5:
        return '5. Lead Jerk';
      case 6:
        return '6. Steer';
      case 7:
        return '7. SteerA';
      case 8:
        return '8. Curvature';
      case 9:
        return '9. No data';
      case 10:
        return '10. No data';
    }
    return '$mode. Custom';
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
      _clearDebugPlotState();
      _startOverlayPreviewLoop();
      _toast('프리뷰 모드 활성화 (실데이터 없이 그래픽 확인)');
      return;
    }

    _stopOverlayPreviewLoop();
    _clearDebugPlotState();
    if (_openpilotOverlayMode && _latestOverlaySnapshot.path.length >= 2) {
      _recordDebugPlotSample(_latestOverlaySnapshot);
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
    _recordDebugPlotSample(next);
    _applyOverlaySnapshot(next, forceNativePush: true);
    _sidecarLastFrameAt = DateTime.now();
    if (_overlayDebugWindowStartMs <= 0) {
      _overlayDebugWindowStartMs = DateTime.now().millisecondsSinceEpoch - 500;
    }
  }

  _DriveDebugPlotSample? _buildOverlayPreviewDebugPlotImpl({
    required int seq,
    required double t,
    required double speedKph,
    required double leadDist,
  }) {
    final mode = _debugOverlayPreviewPlotMode;
    if (mode <= 0) return null;

    final scenarioCurve = switch (_debugOverlayPreviewScenario) {
      _OverlayPreviewScenario.highwayStraight => 0.0,
      _OverlayPreviewScenario.gentleLeft => -1.0,
      _OverlayPreviewScenario.gentleRight => 1.0,
      _OverlayPreviewScenario.traffic => 0.45,
    };
    final cruiseSpeed = speedKph / 3.6;
    final phase = t + (seq * 0.0125);
    final fastWave = math.sin(phase * 1.9);
    final midWave = math.sin((phase * 1.2) + 0.7);
    final slowWave = math.cos((phase * 0.85) - 0.45);
    late final List<double> values;
    late final String title;

    switch (mode) {
      case 1:
        values = <double>[
          fastWave * 1.4,
          (fastWave * 1.1) + 0.25,
          (midWave * 1.6) - 0.15,
        ];
        title = '1.Accel (Y:a_ego, G:a_target, O:a_out)';
        break;
      case 2:
        values = <double>[
          cruiseSpeed + (slowWave * 1.1),
          (cruiseSpeed - 0.5) + (midWave * 0.8),
          (fastWave * 1.2),
        ];
        title = '2.Speed/Accel(Y:speed_0, G:v_ego, O:a_ego)';
        break;
      case 3:
        values = <double>[
          32.0 + (midWave * 4.5),
          14.0 + (slowWave * 2.8),
          17.0 + (fastWave * 3.1),
        ];
        title = '3.Model(Y:pos_32, G:vel_32, O:vel_0)';
        break;
      case 4:
        values = <double>[
          (fastWave * 1.0),
          -(leadDist / 18.0) + (midWave * 0.8),
          (scenarioCurve * 4.0) + (slowWave * 2.4),
        ];
        title = '4.Lead(Y:accel, G:a_lead, O:v_rel)';
        break;
      case 5:
        values = <double>[
          fastWave * 1.25,
          (midWave * 1.6) - 0.2,
          slowWave * 2.1,
        ];
        title = '5.Lead(Y:a_ego, G:a_lead, O:j_lead)';
        break;
      case 6:
        values = <double>[
          ((scenarioCurve * 0.9) + fastWave) * 8.0,
          ((scenarioCurve * 1.1) + midWave) * 8.6,
          ((scenarioCurve * 0.8) + slowWave) * 7.4,
        ];
        title = '6.Steer(Y:actual, G:desire, O:output)';
        break;
      case 7:
        values = <double>[
          (scenarioCurve * 12.0) + (fastWave * 4.0),
          (scenarioCurve * 14.5) + (midWave * 4.6),
          (scenarioCurve * 7.5) + (slowWave * 3.2),
        ];
        title = '7.SteerA (Y:Actual, G:Target, O:Offset*10)';
        break;
      case 8:
        final curvature = ((scenarioCurve * 1.8) + (slowWave * 0.6)) * 100.0;
        values = <double>[curvature, curvature, curvature];
        title = '8.Curvature (Y:G:O same)';
        break;
      case 9:
      case 10:
        values = const <double>[0.0, 0.0, 0.0];
        title = 'no data';
        break;
      default:
        values = const <double>[0.0, 0.0, 0.0];
        title = 'no data';
        break;
    }

    return _DriveDebugPlotSample(
      mode: mode,
      title: title,
      yellow: values[0],
      green: values[1],
      orange: values[2],
    );
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
    final debugPlot = _buildOverlayPreviewDebugPlot(
      seq: seq,
      t: t,
      speedKph: speedKph,
      leadDist: leadDist,
    );

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

    const previewModelPath = _XyzSeries(
      x: <double>[0, 5, 10, 15, 20, 30, 40, 60, 80],
      y: <double>[0, 0, 0, 0, 0, 0, 0, 0, 0],
      z: <double>[1.22, 1.22, 1.22, 1.22, 1.22, 1.22, 1.22, 1.22, 1.22],
    );

    return _DriveOverlaySnapshot(
      modelPath: previewModelPath,
      path: previewModelPath,
      laneLines: const <_LaneLineSeries>[],
      roadEdges: const <_RoadEdgeSeries>[],
      active: true,
      activeLaneLine: true,
      carrotExperimentalMode: false,
      brakeLights: false,
      leadDetected: true,
      leadOne: _RadarLeadSample(
        dRel: leadDist,
        yRel: 0.0,
        vRel: -1.2,
        vLeadK: (speedKph / 3.6) - 1.2,
        vLat: 0.0,
        aRel: 0.0,
        aLeadK: 0.0,
        status: true,
        radar: true,
        radarTrackId: 0,
        modelProb: 0.92,
        score: 0.92,
      ),
      leadTwo: _RadarLeadSample(
        dRel: leadDist + 3.4,
        yRel: 2.2,
        vRel: -0.6,
        vLeadK: (speedKph / 3.6) - 0.6,
        vLat: 0.0,
        aRel: 0.0,
        aLeadK: 0.0,
        status: true,
        radar: true,
        radarTrackId: 12,
        modelProb: 0.68,
        score: 0.68,
      ),
      leadsLeft: const <_RadarTrackSample>[],
      leadsRight: const <_RadarTrackSample>[],
      leadsCenter: const <_RadarTrackSample>[],
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
      debugPlot: debugPlot,
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
