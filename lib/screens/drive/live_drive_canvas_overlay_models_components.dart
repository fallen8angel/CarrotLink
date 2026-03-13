part of 'live_drive_canvas_screen.dart';

class _PreviewRoadBackdropPainter extends CustomPainter {
  const _PreviewRoadBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final skyRect = Offset.zero & Size(size.width, size.height * 0.58);
    final roadRect =
        Rect.fromLTWH(0, size.height * 0.34, size.width, size.height * 0.66);
    final skyPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0xFF6F88A6),
          Color(0xFF444D58),
        ],
      ).createShader(skyRect);
    final roadPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0xFF3E444C),
          Color(0xFF1D2127),
        ],
      ).createShader(roadRect);
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFF0E1117));
    canvas.drawRect(skyRect, skyPaint);
    canvas.drawRect(roadRect, roadPaint);

    final horizonY = size.height * 0.34;
    final roadPath = Path()
      ..moveTo(size.width * 0.08, size.height)
      ..lineTo(size.width * 0.92, size.height)
      ..lineTo(size.width * 0.59, horizonY)
      ..lineTo(size.width * 0.41, horizonY)
      ..close();
    canvas.drawPath(
      roadPath,
      Paint()
        ..color = const Color(0xFF2A2F36)
        ..style = PaintingStyle.fill,
    );

    final lanePaint = Paint()
      ..color = const Color(0xCCF7F7F7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final dashPaint = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawLine(
      Offset(size.width * 0.28, size.height),
      Offset(size.width * 0.47, horizonY),
      lanePaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.72, size.height),
      Offset(size.width * 0.53, horizonY),
      lanePaint,
    );
    for (var i = 0; i < 7; i++) {
      final t0 = i / 7.0;
      final t1 = (i + 0.5) / 7.0;
      final x0 = size.width * 0.5;
      final y0 = size.height + ((horizonY - size.height) * t0);
      final x1 = size.width * 0.5;
      final y1 = size.height + ((horizonY - size.height) * t1);
      canvas.drawLine(Offset(x0, y0), Offset(x1, y1), dashPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewRoadBackdropPainter oldDelegate) =>
      false;
}

class _DriveOverlaySnapshot {
  final _XyzSeries modelPath;
  final _XyzSeries path;
  final List<_LaneLineSeries> laneLines;
  final List<_RoadEdgeSeries> roadEdges;
  final bool active;
  final bool activeLaneLine;
  final bool carrotExperimentalMode;
  final bool brakeLights;
  final bool leadDetected;
  final int pathMode;
  final int pathColor;
  final double accel0;
  final double aEgo;
  final double? speedMps;
  final double? speedKph;
  final int leftLaneLine;
  final int rightLaneLine;
  final List<double> calibrationRpy;
  final List<double> wideFromDeviceEuler;
  final double pathOffsetZ;
  final double pathWidthRatio;
  final double animationPhase;
  final int? modelFrameId;
  final int? roadFrameId;
  final int? wideRoadFrameId;
  final _DriveDebugPlotSample? debugPlot;
  final Map<String, dynamic>? sidecarOverlay2d;
  final _RadarLeadSample? leadOne;
  final _RadarLeadSample? leadTwo;
  final List<_RadarTrackSample> leadsLeft;
  final List<_RadarTrackSample> leadsRight;
  final List<_RadarTrackSample> leadsCenter;
  final bool usingLateralPath;
  final double modelPathXMax;
  final double lateralPathXMax;
  final List<_NavPathPoint> navPathPoints;
  final int navTurnInfo;
  final double? navDistToTurn;
  final String navMainText;

  const _DriveOverlaySnapshot({
    required this.modelPath,
    required this.path,
    required this.laneLines,
    required this.roadEdges,
    required this.active,
    required this.activeLaneLine,
    required this.carrotExperimentalMode,
    required this.brakeLights,
    required this.leadDetected,
    required this.pathMode,
    required this.pathColor,
    required this.accel0,
    required this.aEgo,
    required this.speedMps,
    required this.speedKph,
    required this.leftLaneLine,
    required this.rightLaneLine,
    required this.calibrationRpy,
    required this.wideFromDeviceEuler,
    required this.pathOffsetZ,
    required this.pathWidthRatio,
    required this.animationPhase,
    required this.modelFrameId,
    required this.roadFrameId,
    required this.wideRoadFrameId,
    required this.debugPlot,
    required this.sidecarOverlay2d,
    required this.leadOne,
    required this.leadTwo,
    required this.leadsLeft,
    required this.leadsRight,
    required this.leadsCenter,
    required this.usingLateralPath,
    required this.modelPathXMax,
    required this.lateralPathXMax,
    required this.navPathPoints,
    required this.navTurnInfo,
    required this.navDistToTurn,
    required this.navMainText,
  });

  const _DriveOverlaySnapshot.empty()
      : modelPath = const _XyzSeries.empty(),
        path = const _XyzSeries.empty(),
        laneLines = const <_LaneLineSeries>[],
        roadEdges = const <_RoadEdgeSeries>[],
        active = false,
        activeLaneLine = false,
        carrotExperimentalMode = false,
        brakeLights = false,
        leadDetected = false,
        pathMode = 0,
        pathColor = 3,
        accel0 = 0.0,
        aEgo = 0.0,
        speedMps = null,
        speedKph = null,
        leftLaneLine = 0,
        rightLaneLine = 0,
        calibrationRpy = const <double>[],
        wideFromDeviceEuler = const <double>[],
        pathOffsetZ = 1.22,
        pathWidthRatio = 1.0,
        animationPhase = 0.0,
        modelFrameId = null,
        roadFrameId = null,
        wideRoadFrameId = null,
        debugPlot = null,
        sidecarOverlay2d = null,
        leadOne = null,
        leadTwo = null,
        leadsLeft = const <_RadarTrackSample>[],
        leadsRight = const <_RadarTrackSample>[],
        leadsCenter = const <_RadarTrackSample>[],
        usingLateralPath = false,
        modelPathXMax = 0.0,
        lateralPathXMax = 0.0,
        navPathPoints = const <_NavPathPoint>[],
        navTurnInfo = 0,
        navDistToTurn = null,
        navMainText = '';

  _DriveOverlaySnapshot copyWith({
    int? pathMode,
    int? pathColor,
    List<double>? calibrationRpy,
    List<double>? wideFromDeviceEuler,
    double? pathOffsetZ,
    double? animationPhase,
    _DriveDebugPlotSample? debugPlot,
    Map<String, dynamic>? sidecarOverlay2d,
    List<_NavPathPoint>? navPathPoints,
    int? navTurnInfo,
    double? navDistToTurn,
    String? navMainText,
  }) {
    final phase = animationPhase ?? this.animationPhase;
    return _DriveOverlaySnapshot(
      modelPath: modelPath,
      path: path,
      laneLines: laneLines,
      roadEdges: roadEdges,
      active: active,
      activeLaneLine: activeLaneLine,
      carrotExperimentalMode: carrotExperimentalMode,
      brakeLights: brakeLights,
      leadDetected: leadDetected,
      pathMode: pathMode ?? this.pathMode,
      pathColor: pathColor ?? this.pathColor,
      accel0: accel0,
      aEgo: aEgo,
      speedMps: speedMps,
      speedKph: speedKph,
      leftLaneLine: leftLaneLine,
      rightLaneLine: rightLaneLine,
      calibrationRpy: calibrationRpy ?? this.calibrationRpy,
      wideFromDeviceEuler: wideFromDeviceEuler ?? this.wideFromDeviceEuler,
      pathOffsetZ: pathOffsetZ ?? this.pathOffsetZ,
      pathWidthRatio: pathWidthRatio,
      animationPhase: phase,
      modelFrameId: modelFrameId,
      roadFrameId: roadFrameId,
      wideRoadFrameId: wideRoadFrameId,
      debugPlot: debugPlot ?? this.debugPlot,
      sidecarOverlay2d: sidecarOverlay2d ?? this.sidecarOverlay2d,
      leadOne: leadOne,
      leadTwo: leadTwo,
      leadsLeft: leadsLeft,
      leadsRight: leadsRight,
      leadsCenter: leadsCenter,
      usingLateralPath: usingLateralPath,
      modelPathXMax: modelPathXMax,
      lateralPathXMax: lateralPathXMax,
      navPathPoints: navPathPoints ?? this.navPathPoints,
      navTurnInfo: navTurnInfo ?? this.navTurnInfo,
      navDistToTurn: navDistToTurn ?? this.navDistToTurn,
      navMainText: navMainText ?? this.navMainText,
    );
  }

  static double? _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static List<double> _asDoubleList(dynamic v) {
    if (v is! List) return const <double>[];
    final out = <double>[];
    for (final e in v) {
      final d = _asDouble(e);
      if (d != null) out.add(d);
    }
    return out;
  }

  static List<_NavPathPoint> _parseNaviPathPoints(dynamic raw) {
    if (raw is! String) return const <_NavPathPoint>[];
    final text = raw.trim();
    if (text.isEmpty) return const <_NavPathPoint>[];
    final out = <_NavPathPoint>[];
    for (final token in text.split(';')) {
      final part = token.trim();
      if (part.isEmpty) continue;
      final xyz = part.split(',');
      if (xyz.length != 3) continue;
      final x = _asDouble(xyz[0]);
      final y = _asDouble(xyz[1]);
      final d = _asDouble(xyz[2]);
      if (x == null || y == null || d == null) continue;
      if (!x.isFinite || !y.isFinite || !d.isFinite) continue;
      out.add(_NavPathPoint(x: x, y: y, d: d));
      if (out.length >= 200) break;
    }
    if (out.length <= 1) return const <_NavPathPoint>[];
    out.sort((a, b) => a.d.compareTo(b.d));
    return out;
  }

  static int _turnInfoFromNavInstruction({
    required String maneuverType,
    required String maneuverModifier,
    required String fallbackText,
  }) {
    final type = maneuverType.trim().toLowerCase();
    final modifier = maneuverModifier.trim().toLowerCase();
    final fallback = fallbackText.trim().toLowerCase();

    bool containsAny(String source, List<String> needles) {
      for (final n in needles) {
        if (source.contains(n)) return true;
      }
      return false;
    }

    final isArrival =
        containsAny(type, const <String>['arrive', 'destination']) ||
            containsAny(fallback, const <String>['도착']);
    if (isArrival) return 8;

    final isUturn =
        containsAny(type, const <String>['uturn', 'u-turn', 'u turn']) ||
            containsAny(fallback, const <String>['유턴']);
    if (isUturn) return 7;

    final isLeft = containsAny(modifier, const <String>['left']) ||
        containsAny(fallback, const <String>['좌']);
    final isRight = containsAny(modifier, const <String>['right']) ||
        containsAny(fallback, const <String>['우']);

    final isLaneLike = containsAny(type, const <String>[
      'fork',
      'merge',
      'ramp',
      'onramp',
      'offramp',
      'change lane',
    ]);
    if (isLaneLike) {
      if (isLeft) return 3;
      if (isRight) return 4;
    }

    final isTurnLike = containsAny(type, const <String>[
      'turn',
      'roundabout',
      'exit roundabout',
      'continue',
    ]);
    if (isTurnLike) {
      if (isLeft) return 1;
      if (isRight) return 2;
    }

    if (containsAny(fallback, const <String>['좌회전'])) return 1;
    if (containsAny(fallback, const <String>['우회전'])) return 2;
    return 0;
  }

  static double _maxFinite(List<double> values) {
    var out = 0.0;
    for (final v in values) {
      if (v.isFinite && v > out) out = v;
    }
    return out;
  }

  static double _lerp(double a, double b, double t) {
    return a + (b - a) * t;
  }

  static double? _lerpNullable(double? a, double? b, double t) {
    if (a == null && b == null) return null;
    final av = a ?? b ?? 0.0;
    final bv = b ?? a ?? 0.0;
    return _lerp(av, bv, t);
  }

  static _XyzSeries _lerpSeries(_XyzSeries a, _XyzSeries b, double t) {
    final count = math.min(a.length, b.length);
    if (count < 2) return t < 0.5 ? a : b;
    final x = List<double>.generate(
      count,
      (i) => _lerp(a.x[i], b.x[i], t),
      growable: false,
    );
    final y = List<double>.generate(
      count,
      (i) => _lerp(a.y[i], b.y[i], t),
      growable: false,
    );
    final z = List<double>.generate(
      count,
      (i) => _lerp(a.z[i], b.z[i], t),
      growable: false,
    );
    return _XyzSeries(x: x, y: y, z: z);
  }

  static List<_LaneLineSeries> _lerpLaneLines(
    List<_LaneLineSeries> a,
    List<_LaneLineSeries> b,
    double t,
  ) {
    final count = math.min(a.length, b.length);
    if (count == 0) return t < 0.5 ? a : b;
    return List<_LaneLineSeries>.generate(
      count,
      (i) => _LaneLineSeries(
        line: _lerpSeries(a[i].line, b[i].line, t),
        probability: _lerp(a[i].probability, b[i].probability, t),
        std: _lerp(a[i].std, b[i].std, t),
      ),
      growable: false,
    );
  }

  static List<_RoadEdgeSeries> _lerpRoadEdges(
    List<_RoadEdgeSeries> a,
    List<_RoadEdgeSeries> b,
    double t,
  ) {
    final count = math.min(a.length, b.length);
    if (count == 0) return t < 0.5 ? a : b;
    return List<_RoadEdgeSeries>.generate(
      count,
      (i) => _RoadEdgeSeries(
        line: _lerpSeries(a[i].line, b[i].line, t),
        std: _lerp(a[i].std, b[i].std, t),
      ),
      growable: false,
    );
  }

  static _RadarLeadSample? _lerpRadarLead(
    _RadarLeadSample? a,
    _RadarLeadSample? b,
    double t,
  ) {
    if (a == null) return b;
    if (b == null) return a;
    return _RadarLeadSample(
      dRel: _lerp(a.dRel, b.dRel, t),
      yRel: _lerp(a.yRel, b.yRel, t),
      vRel: _lerp(a.vRel, b.vRel, t),
      vLeadK: _lerp(a.vLeadK, b.vLeadK, t),
      vLat: _lerp(a.vLat, b.vLat, t),
      aRel: _lerp(a.aRel, b.aRel, t),
      aLeadK: _lerp(a.aLeadK, b.aLeadK, t),
      status: t < 0.5 ? a.status : b.status,
      radar: t < 0.5 ? a.radar : b.radar,
      radarTrackId: t < 0.5 ? a.radarTrackId : b.radarTrackId,
      modelProb: _lerp(a.modelProb, b.modelProb, t),
      score: _lerp(a.score, b.score, t),
    );
  }

  static _DriveOverlaySnapshot interpolate(
    _DriveOverlaySnapshot from,
    _DriveOverlaySnapshot to,
    double t,
  ) {
    final tt = t.clamp(0.0, 1.0).toDouble();
    if (tt <= 0.0) return from;
    if (tt >= 1.0) return to;
    return _DriveOverlaySnapshot(
      modelPath: _lerpSeries(from.modelPath, to.modelPath, tt),
      path: _lerpSeries(from.path, to.path, tt),
      laneLines: _lerpLaneLines(from.laneLines, to.laneLines, tt),
      roadEdges: _lerpRoadEdges(from.roadEdges, to.roadEdges, tt),
      active: tt < 0.5 ? from.active : to.active,
      activeLaneLine: tt < 0.5 ? from.activeLaneLine : to.activeLaneLine,
      carrotExperimentalMode:
          tt < 0.5 ? from.carrotExperimentalMode : to.carrotExperimentalMode,
      brakeLights: tt < 0.5 ? from.brakeLights : to.brakeLights,
      leadDetected: tt < 0.5 ? from.leadDetected : to.leadDetected,
      pathMode: tt < 0.5 ? from.pathMode : to.pathMode,
      pathColor: tt < 0.5 ? from.pathColor : to.pathColor,
      accel0: _lerp(from.accel0, to.accel0, tt),
      aEgo: _lerp(from.aEgo, to.aEgo, tt),
      speedMps: _lerpNullable(from.speedMps, to.speedMps, tt),
      speedKph: _lerpNullable(from.speedKph, to.speedKph, tt),
      leftLaneLine: tt < 0.5 ? from.leftLaneLine : to.leftLaneLine,
      rightLaneLine: tt < 0.5 ? from.rightLaneLine : to.rightLaneLine,
      calibrationRpy: tt < 0.5 ? from.calibrationRpy : to.calibrationRpy,
      wideFromDeviceEuler:
          tt < 0.5 ? from.wideFromDeviceEuler : to.wideFromDeviceEuler,
      pathOffsetZ: _lerp(from.pathOffsetZ, to.pathOffsetZ, tt),
      pathWidthRatio: _lerp(from.pathWidthRatio, to.pathWidthRatio, tt),
      animationPhase: _lerp(from.animationPhase, to.animationPhase, tt),
      modelFrameId: tt < 0.5 ? from.modelFrameId : to.modelFrameId,
      roadFrameId: tt < 0.5 ? from.roadFrameId : to.roadFrameId,
      wideRoadFrameId: tt < 0.5 ? from.wideRoadFrameId : to.wideRoadFrameId,
      debugPlot: to.debugPlot ?? from.debugPlot,
      sidecarOverlay2d: tt < 0.5 ? from.sidecarOverlay2d : to.sidecarOverlay2d,
      leadOne: _lerpRadarLead(from.leadOne, to.leadOne, tt),
      leadTwo: _lerpRadarLead(from.leadTwo, to.leadTwo, tt),
      leadsLeft: tt < 0.5 ? from.leadsLeft : to.leadsLeft,
      leadsRight: tt < 0.5 ? from.leadsRight : to.leadsRight,
      leadsCenter: tt < 0.5 ? from.leadsCenter : to.leadsCenter,
      usingLateralPath: tt < 0.5 ? from.usingLateralPath : to.usingLateralPath,
      modelPathXMax: _lerp(from.modelPathXMax, to.modelPathXMax, tt),
      lateralPathXMax: _lerp(from.lateralPathXMax, to.lateralPathXMax, tt),
      navPathPoints: tt < 0.5 ? from.navPathPoints : to.navPathPoints,
      navTurnInfo: tt < 0.5 ? from.navTurnInfo : to.navTurnInfo,
      navDistToTurn: tt < 0.5 ? from.navDistToTurn : to.navDistToTurn,
      navMainText: tt < 0.5 ? from.navMainText : to.navMainText,
    );
  }

  factory _DriveOverlaySnapshot.fromSidecar(Map<String, dynamic> payload) {
    final carState = payload['carState'];
    final selfdriveState = payload['selfdriveState'];
    final controlsState = payload['controlsState'];
    final longitudinalPlan = payload['longitudinalPlan'];
    final lateralPlan = payload['lateralPlan'];
    final radarState = payload['radarState'];
    final pathStyle = payload['pathStyle'];
    final liveCalibration = payload['liveCalibration'];
    final cachedCalibration = payload['cachedCalibration'];
    final roadCameraState = payload['roadCameraState'];
    final wideRoadCameraState = payload['wideRoadCameraState'];
    final modelV2 = payload['modelV2'];
    final carrotMan = payload['carrotMan'];
    final navInstructionCarrot = payload['navInstructionCarrot'];
    final debugPlot = _DriveDebugPlotSample.fromDynamic(payload['debugPlot']);
    final overlay2dRaw = payload['overlay2d'];
    Map<String, dynamic>? sidecarOverlay2d;
    if (overlay2dRaw is Map) {
      sidecarOverlay2d = Map<String, dynamic>.from(overlay2dRaw);
    }

    var navPathPoints = const <_NavPathPoint>[];
    var navTurnInfo = 0;
    double? navDistToTurn;
    var navMainText = '';
    if (carrotMan is Map) {
      navPathPoints = _parseNaviPathPoints(carrotMan['naviPaths']);
      navTurnInfo = _asInt(carrotMan['xTurnInfo']) ?? 0;
      navDistToTurn = _asDouble(carrotMan['xDistToTurn']);
      navMainText = (carrotMan['szTBTMainText']?.toString() ?? '').trim();
    }
    if (navInstructionCarrot is Map) {
      final instructionPrimary =
          (navInstructionCarrot['maneuverPrimaryText']?.toString() ?? '')
              .trim();
      final instructionType =
          (navInstructionCarrot['maneuverType']?.toString() ?? '').trim();
      final instructionModifier =
          (navInstructionCarrot['maneuverModifier']?.toString() ?? '').trim();
      final maneuverDistance =
          _asDouble(navInstructionCarrot['maneuverDistance']);
      final remainingDistance =
          _asDouble(navInstructionCarrot['distanceRemaining']);
      final candidateDistance =
          (maneuverDistance != null && maneuverDistance > 0.0)
              ? maneuverDistance
              : ((remainingDistance != null && remainingDistance > 0.0)
                  ? remainingDistance
                  : null);
      if ((navDistToTurn == null || navDistToTurn <= 0.0) &&
          candidateDistance != null) {
        navDistToTurn = candidateDistance;
      }
      if (navMainText.isEmpty && instructionPrimary.isNotEmpty) {
        navMainText = instructionPrimary;
      }
      if (navTurnInfo == 0) {
        navTurnInfo = _turnInfoFromNavInstruction(
          maneuverType: instructionType,
          maneuverModifier: instructionModifier,
          fallbackText: navMainText,
        );
      }
    }

    double? speedMps;
    double? speedKph;
    var aEgo = 0.0;
    var brakeLights = false;
    var useLaneLineSpeed = 0;
    var leftLaneLine = 0;
    var rightLaneLine = 0;
    if (carState is Map) {
      final vEgo = _asDouble(carState['vEgo']);
      if (vEgo != null) {
        speedMps = vEgo;
        speedKph = vEgo * 3.6;
      }
      aEgo = _asDouble(carState['aEgo']) ?? 0.0;
      final brakeRaw = carState['brakeLights'];
      if (brakeRaw is bool) brakeLights = brakeRaw;
      if (brakeRaw is num) brakeLights = brakeRaw != 0;
      useLaneLineSpeed = _asInt(carState['useLaneLineSpeed']) ?? 0;
      leftLaneLine = _asInt(carState['leftLaneLine']) ?? 0;
      rightLaneLine = _asInt(carState['rightLaneLine']) ?? 0;
    }

    bool active = false;
    if (selfdriveState is Map) {
      final activeRaw = selfdriveState['active'];
      if (activeRaw is bool) active = activeRaw;
      if (activeRaw is num) active = activeRaw != 0;
    }

    var activeLaneLine = false;
    if (controlsState is Map) {
      final laneRaw = controlsState['activeLaneLine'];
      if (laneRaw is bool) activeLaneLine = laneRaw;
      if (laneRaw is num) activeLaneLine = laneRaw != 0;
    }

    var carrotExperimentalMode = false;
    var accel0 = 0.0;
    if (longitudinalPlan is Map) {
      final xState = _asInt(longitudinalPlan['xState']) ?? -1;
      carrotExperimentalMode = xState == 4;
      accel0 = _asDouble(longitudinalPlan['accel0']) ?? 0.0;
    }

    var leadDetected = false;
    _RadarLeadSample? leadOne;
    _RadarLeadSample? leadTwo;
    var leadsLeft = const <_RadarTrackSample>[];
    var leadsRight = const <_RadarTrackSample>[];
    var leadsCenter = const <_RadarTrackSample>[];
    if (radarState is Map) {
      leadOne = _parseRadarLead(radarState['leadOne']);
      leadTwo = _parseRadarLead(radarState['leadTwo']);
      leadsLeft = _parseRadarTracks(radarState['leadsLeft']);
      leadsRight = _parseRadarTracks(radarState['leadsRight']);
      leadsCenter = _parseRadarTracks(radarState['leadsCenter']);
      final leadOneRaw = radarState['leadOne'];
      if (leadOneRaw is Map) {
        final status = leadOneRaw['status'];
        if (status is bool) leadDetected = status;
        if (status is num) leadDetected = status != 0;
      }
    }

    var modelPath = const _XyzSeries.empty();
    var lateralPath = const _XyzSeries.empty();
    var lines = const <_LaneLineSeries>[];
    var edges = const <_RoadEdgeSeries>[];
    int? modelFrameId;

    if (modelV2 is Map) {
      modelFrameId = _asInt(modelV2['frameId']);
      final x = _asDoubleList(modelV2['pathX']);
      final y = _asDoubleList(modelV2['pathY']);
      final z = _asDoubleList(modelV2['pathZ']);
      if (x.isNotEmpty && y.isNotEmpty) {
        var count = math.min(x.length, y.length);
        if (z.isNotEmpty) {
          count = math.min(count, z.length);
        }
        if (count >= 2) {
          final zOut = z.isEmpty
              ? List<double>.filled(count, 0.0, growable: false)
              : z.take(count).toList(growable: false);
          modelPath = _XyzSeries(
            x: x.take(count).toList(growable: false),
            y: y.take(count).toList(growable: false),
            z: zOut,
          );
        }
      }

      final probs = _asDoubleList(modelV2['laneLineProbs']);
      final stds = _asDoubleList(modelV2['laneLineStds']);
      final laneRaw = modelV2['laneLines'];
      if (laneRaw is List) {
        final parsed = <_LaneLineSeries>[];
        for (var i = 0; i < laneRaw.length; i++) {
          final e = laneRaw[i];
          if (e is! Map) continue;
          final map = Map<String, dynamic>.from(e);
          final lx = _asDoubleList(map['x']);
          final ly = _asDoubleList(map['y']);
          final lz = _asDoubleList(map['z']);
          if (lx.isEmpty || ly.isEmpty) continue;
          var count = math.min(lx.length, ly.length);
          if (lz.isNotEmpty) {
            count = math.min(count, lz.length);
          }
          if (count < 2) continue;
          final prob = i < probs.length ? probs[i].clamp(0, 1) : 0.5;
          final std = i < stds.length ? stds[i].clamp(0, 2) : 1.0;
          final zOut = lz.isEmpty
              ? List<double>.filled(count, 0.0, growable: false)
              : lz.take(count).toList(growable: false);
          parsed.add(
            _LaneLineSeries(
              line: _XyzSeries(
                x: lx.take(count).toList(growable: false),
                y: ly.take(count).toList(growable: false),
                z: zOut,
              ),
              probability: prob.toDouble(),
              std: std.toDouble(),
            ),
          );
        }
        lines = parsed;
      }

      final edgeRaw = modelV2['roadEdges'];
      final edgeStds = _asDoubleList(modelV2['roadEdgeStds']);
      if (edgeRaw is List) {
        final parsed = <_RoadEdgeSeries>[];
        for (var i = 0; i < edgeRaw.length; i++) {
          final e = edgeRaw[i];
          if (e is! Map) continue;
          final map = Map<String, dynamic>.from(e);
          final ex = _asDoubleList(map['x']);
          final ey = _asDoubleList(map['y']);
          final ez = _asDoubleList(map['z']);
          if (ex.isEmpty || ey.isEmpty) continue;
          var count = math.min(ex.length, ey.length);
          if (ez.isNotEmpty) {
            count = math.min(count, ez.length);
          }
          if (count < 2) continue;
          final std = i < edgeStds.length ? edgeStds[i].clamp(0, 2) : 1.0;
          final zOut = ez.isEmpty
              ? List<double>.filled(count, 0.0, growable: false)
              : ez.take(count).toList(growable: false);
          parsed.add(
            _RoadEdgeSeries(
              line: _XyzSeries(
                x: ex.take(count).toList(growable: false),
                y: ey.take(count).toList(growable: false),
                z: zOut,
              ),
              std: std.toDouble(),
            ),
          );
        }
        edges = parsed;
      }
    }

    if (lateralPlan is Map) {
      final posRaw = lateralPlan['position'];
      if (posRaw is Map) {
        final posMap = Map<String, dynamic>.from(posRaw);
        final x = _asDoubleList(posMap['x']);
        final y = _asDoubleList(posMap['y']);
        final z = _asDoubleList(posMap['z']);
        if (x.isNotEmpty && y.isNotEmpty) {
          var count = math.min(x.length, y.length);
          if (z.isNotEmpty) {
            count = math.min(count, z.length);
          }
          if (count >= 2) {
            final zOut = z.isEmpty
                ? List<double>.filled(count, 0.0, growable: false)
                : z.take(count).toList(growable: false);
            lateralPath = _XyzSeries(
              x: x.take(count).toList(growable: false),
              y: y.take(count).toList(growable: false),
              z: zOut,
            );
          }
        }
      }
    }

    var calibrationRpy = const <double>[];
    var wideFromDeviceEuler = const <double>[];
    var pathOffsetZ = 1.22;
    bool applyCalibration(dynamic raw) {
      if (raw is! Map) return false;
      final map = Map<String, dynamic>.from(raw);
      final calStatus = _asInt(map['calStatus']);
      // openpilot UI parity: apply calibration only when CALIBRATED(1).
      if (calStatus != null && calStatus != 1) {
        return false;
      }
      final rpy = _asDoubleList(map['rpyCalib']);
      if (rpy.length >= 3) {
        calibrationRpy = rpy.take(3).toList(growable: false);
      }
      final wideEuler = _asDoubleList(map['wideFromDeviceEuler']);
      if (wideEuler.length >= 3) {
        wideFromDeviceEuler = wideEuler.take(3).toList(growable: false);
      }
      final h = _asDouble(map['height']);
      if (h != null && h.isFinite && h > 0.3 && h < 4.0) {
        pathOffsetZ = h;
      }
      return calibrationRpy.length >= 3 && wideFromDeviceEuler.length >= 3;
    }

    var liveApplied = false;
    if (liveCalibration is Map) {
      liveApplied = applyCalibration(liveCalibration);
    }
    if (!liveApplied &&
        (calibrationRpy.length < 3 || wideFromDeviceEuler.length < 3)) {
      applyCalibration(cachedCalibration);
    }

    final modelPathXMax = _maxFinite(modelPath.x);
    final lateralPathXMax = _maxFinite(lateralPath.x);
    final canUseLateralPathPrimary = activeLaneLine &&
        lateralPath.length >= 2 &&
        lateralPathXMax >= 8.0 &&
        (modelPathXMax <= 0.0 || lateralPathXMax >= (modelPathXMax * 0.35));
    // Keep path visible in low-speed/static scenes when model path collapses.
    final canUseLateralPathFallback = !activeLaneLine &&
        lateralPath.length >= 2 &&
        lateralPathXMax >= 8.0 &&
        modelPathXMax > 0.0 &&
        modelPathXMax < 8.0;
    final canUseLateralPath =
        canUseLateralPathPrimary || canUseLateralPathFallback;
    final path = canUseLateralPath ? lateralPath : modelPath;

    var showPathModeNormal = 0;
    var showPathColorNormal = 3;
    var showPathModeLane = 0;
    var showPathColorLane = 3;
    var showPathColorCruiseOff = 3;
    var showPathWidth = 100;
    if (pathStyle is Map) {
      showPathModeNormal =
          _asInt(pathStyle['showPathMode']) ?? showPathModeNormal;
      showPathColorNormal =
          _asInt(pathStyle['showPathColor']) ?? showPathColorNormal;
      showPathModeLane =
          _asInt(pathStyle['showPathModeLane']) ?? showPathModeLane;
      showPathColorLane =
          _asInt(pathStyle['showPathColorLane']) ?? showPathColorLane;
      showPathColorCruiseOff =
          _asInt(pathStyle['showPathColorCruiseOff']) ?? showPathColorCruiseOff;
      showPathWidth = _asInt(pathStyle['showPathWidth']) ?? showPathWidth;
    }
    final pathWidthRatio = (showPathWidth.toDouble() / 100.0).clamp(0.1, 3.0);
    var pathMode = activeLaneLine ? showPathModeLane : showPathModeNormal;
    var pathColor = activeLaneLine ? showPathColorLane : showPathColorNormal;
    if (!active) {
      pathColor = showPathColorCruiseOff;
    }
    if (pathColor >= 20) {
      if (active) {
        pathColor = 13;
        if (leadDetected) {
          if (accel0.abs() < 0.5) {
            pathColor = 12;
          } else if (accel0 >= 0.5) {
            pathColor = 11;
          } else {
            pathColor = 10;
          }
        }
      } else {
        pathColor = 19;
      }
    }
    if (useLaneLineSpeed > 0 && !activeLaneLine) {
      pathMode = showPathModeLane;
    }

    int? roadFrameId;
    if (roadCameraState is Map) {
      roadFrameId = _asInt(roadCameraState['frameId']);
    }
    int? wideRoadFrameId;
    if (wideRoadCameraState is Map) {
      wideRoadFrameId = _asInt(wideRoadCameraState['frameId']);
    }

    return _DriveOverlaySnapshot(
      modelPath: modelPath,
      path: path,
      laneLines: lines,
      roadEdges: edges,
      active: active,
      activeLaneLine: activeLaneLine,
      carrotExperimentalMode: carrotExperimentalMode,
      brakeLights: brakeLights,
      leadDetected: leadDetected,
      pathMode: pathMode,
      pathColor: pathColor,
      accel0: accel0,
      aEgo: aEgo,
      speedMps: speedMps,
      speedKph: speedKph,
      leftLaneLine: leftLaneLine,
      rightLaneLine: rightLaneLine,
      calibrationRpy: calibrationRpy,
      wideFromDeviceEuler: wideFromDeviceEuler,
      pathOffsetZ: pathOffsetZ,
      pathWidthRatio: pathWidthRatio,
      animationPhase: 0.0,
      modelFrameId: modelFrameId,
      roadFrameId: roadFrameId,
      wideRoadFrameId: wideRoadFrameId,
      debugPlot: debugPlot,
      sidecarOverlay2d: sidecarOverlay2d,
      leadOne: leadOne,
      leadTwo: leadTwo,
      leadsLeft: leadsLeft,
      leadsRight: leadsRight,
      leadsCenter: leadsCenter,
      usingLateralPath: canUseLateralPath,
      modelPathXMax: modelPathXMax,
      lateralPathXMax: lateralPathXMax,
      navPathPoints: navPathPoints,
      navTurnInfo: navTurnInfo,
      navDistToTurn: navDistToTurn,
      navMainText: navMainText,
    );
  }
}

class _XyzSeries {
  final List<double> x;
  final List<double> y;
  final List<double> z;

  const _XyzSeries({
    required this.x,
    required this.y,
    required this.z,
  });

  const _XyzSeries.empty()
      : x = const <double>[],
        y = const <double>[],
        z = const <double>[];

  int get length => math.min(x.length, math.min(y.length, z.length));
}

class _LaneLineSeries {
  final _XyzSeries line;
  final double probability;
  final double std;

  const _LaneLineSeries({
    required this.line,
    required this.probability,
    required this.std,
  });
}

class _RoadEdgeSeries {
  final _XyzSeries line;
  final double std;

  const _RoadEdgeSeries({
    required this.line,
    required this.std,
  });
}

class _RadarLeadSample {
  final double dRel;
  final double yRel;
  final double vRel;
  final double vLeadK;
  final double vLat;
  final double aRel;
  final double aLeadK;
  final bool status;
  final bool radar;
  final int radarTrackId;
  final double modelProb;
  final double score;

  const _RadarLeadSample({
    required this.dRel,
    required this.yRel,
    required this.vRel,
    required this.vLeadK,
    required this.vLat,
    required this.aRel,
    required this.aLeadK,
    required this.status,
    required this.radar,
    required this.radarTrackId,
    required this.modelProb,
    required this.score,
  });
}

class _RadarTrackSample {
  final double dRel;
  final double yRel;
  final double vRel;
  final double vLeadK;
  final double vLat;
  final double aRel;
  final double aLeadK;
  final bool radar;
  final int radarTrackId;
  final double modelProb;
  final double score;

  const _RadarTrackSample({
    required this.dRel,
    required this.yRel,
    required this.vRel,
    required this.vLeadK,
    required this.vLat,
    required this.aRel,
    required this.aLeadK,
    required this.radar,
    required this.radarTrackId,
    required this.modelProb,
    required this.score,
  });
}

_RadarLeadSample? _parseRadarLead(dynamic raw) {
  if (raw is! Map) return null;
  final map = Map<String, dynamic>.from(raw);
  final dRel = _DriveOverlaySnapshot._asDouble(map['dRel']);
  final yRel = _DriveOverlaySnapshot._asDouble(map['yRel']);
  if (dRel == null || yRel == null || !dRel.isFinite || !yRel.isFinite) {
    return null;
  }
  return _RadarLeadSample(
    dRel: dRel,
    yRel: yRel,
    vRel: _DriveOverlaySnapshot._asDouble(map['vRel']) ?? 0.0,
    vLeadK: _DriveOverlaySnapshot._asDouble(map['vLeadK']) ?? 0.0,
    vLat: _DriveOverlaySnapshot._asDouble(map['vLat']) ?? 0.0,
    aRel: _DriveOverlaySnapshot._asDouble(map['aRel']) ?? 0.0,
    aLeadK: _DriveOverlaySnapshot._asDouble(map['aLeadK']) ?? 0.0,
    status: map['status'] == true ||
        _DriveOverlaySnapshot._asInt(map['status']) == 1,
    radar:
        map['radar'] == true || _DriveOverlaySnapshot._asInt(map['radar']) == 1,
    radarTrackId: _DriveOverlaySnapshot._asInt(map['radarTrackId']) ?? -1,
    modelProb: _DriveOverlaySnapshot._asDouble(map['modelProb']) ?? 0.0,
    score: _DriveOverlaySnapshot._asDouble(map['score']) ?? 0.0,
  );
}

List<_RadarTrackSample> _parseRadarTracks(dynamic raw) {
  if (raw is! List) return const <_RadarTrackSample>[];
  final out = <_RadarTrackSample>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final map = Map<String, dynamic>.from(item);
    final dRel = _DriveOverlaySnapshot._asDouble(map['dRel']);
    final yRel = _DriveOverlaySnapshot._asDouble(map['yRel']);
    if (dRel == null || yRel == null || !dRel.isFinite || !yRel.isFinite) {
      continue;
    }
    out.add(
      _RadarTrackSample(
        dRel: dRel,
        yRel: yRel,
        vRel: _DriveOverlaySnapshot._asDouble(map['vRel']) ?? 0.0,
        vLeadK: _DriveOverlaySnapshot._asDouble(map['vLeadK']) ?? 0.0,
        vLat: _DriveOverlaySnapshot._asDouble(map['vLat']) ?? 0.0,
        aRel: _DriveOverlaySnapshot._asDouble(map['aRel']) ?? 0.0,
        aLeadK: _DriveOverlaySnapshot._asDouble(map['aLeadK']) ?? 0.0,
        radar: map['radar'] == true ||
            _DriveOverlaySnapshot._asInt(map['radar']) == 1,
        radarTrackId: _DriveOverlaySnapshot._asInt(map['radarTrackId']) ?? -1,
        modelProb: _DriveOverlaySnapshot._asDouble(map['modelProb']) ?? 0.0,
        score: _DriveOverlaySnapshot._asDouble(map['score']) ?? 0.0,
      ),
    );
  }
  return out;
}

class _NavPathPoint {
  final double x;
  final double y;
  final double d;

  const _NavPathPoint({
    required this.x,
    required this.y,
    required this.d,
  });
}
