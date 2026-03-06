part of 'live_drive_canvas_screen.dart';

class _DriveArScene {
  final List<_DriveArRoutePoint> routePoints;
  final _DriveArTurnCue? turnCue;
  final _DriveArSceneHealth health;
  final _DriveArPresentation presentation;

  const _DriveArScene({
    required this.routePoints,
    required this.turnCue,
    required this.health,
    required this.presentation,
  });

  const _DriveArScene.empty()
      : routePoints = const <_DriveArRoutePoint>[],
        turnCue = null,
        health = const _DriveArSceneHealth.empty(),
        presentation = const _DriveArPresentation.empty();

  bool get hasRoute => routePoints.length >= 2;
  bool get hasTurnCue => turnCue != null;
  bool get isEmpty => !hasRoute && !hasTurnCue;
  String get statusText {
    if (!health.calibrationOk) return '캘리브레이션 대기';
    if (!health.frameGapOk) return '프레임 정합 대기';
    if (turnCue?.isArrival ?? false) return '도착 임박';
    if (hasRoute) return '정상 경로';
    return '경로 탐색 중';
  }

  String get turnLabel {
    final cue = turnCue;
    if (cue == null) return '';
    final turnText = cue.primaryText.trim().isNotEmpty
        ? cue.primaryText.trim()
        : cue.fallbackLabel;
    final turnDistance = cue.distanceLabel;
    if (turnText.isEmpty) return turnDistance;
    if (turnDistance.isEmpty) return turnText;
    return '$turnDistance $turnText';
  }

  Map<String, dynamic> toPayload({
    required _DriveCameraKind cameraKind,
    Map<String, dynamic>? screenAnchors,
  }) {
    return <String, dynamic>{
      'sceneVersion': 1,
      'cameraKind': cameraKind.name,
      'health': health.toPayload(),
      'presentation': presentation.toPayload(),
      if (screenAnchors != null) 'screenAnchors': screenAnchors,
      'summary': <String, dynamic>{
        'statusText': statusText,
        'turnLabel': turnLabel,
        'routePointCount': routePoints.length,
      },
      if (routePoints.isNotEmpty)
        'routePoints': routePoints
            .map((p) => <double>[p.x, p.y, p.d])
            .toList(growable: false),
      if (turnCue != null) 'turnCue': turnCue!.toPayload(),
    };
  }
}

class _DriveArRoutePoint {
  final double x;
  final double y;
  final double d;

  const _DriveArRoutePoint({
    required this.x,
    required this.y,
    required this.d,
  });
}

class _DriveArTurnCue {
  final int turnInfo;
  final double? distanceMeters;
  final String primaryText;

  const _DriveArTurnCue({
    required this.turnInfo,
    required this.distanceMeters,
    required this.primaryText,
  });

  bool get isArrival =>
      turnInfo == 8 ||
      primaryText.contains('도착') ||
      primaryText.toLowerCase().contains('arrival');
  String get directionKey {
    switch (turnInfo) {
      case 1:
        return 'left';
      case 2:
        return 'right';
      case 3:
        return 'lane_left';
      case 4:
        return 'lane_right';
      case 7:
        return 'u_turn';
      case 8:
        return 'arrival';
      default:
        return 'none';
    }
  }

  String get fallbackLabel {
    switch (turnInfo) {
      case 1:
        return '좌회전';
      case 2:
        return '우회전';
      case 3:
        return '좌차선 변경';
      case 4:
        return '우차선 변경';
      case 7:
        return '유턴';
      case 8:
        return '도착';
      default:
        return '';
    }
  }

  String get distanceLabel {
    final distance = distanceMeters;
    if (distance == null || !distance.isFinite || distance <= 0) return '';
    if (distance >= 1000.0) {
      return '${(distance / 1000.0).toStringAsFixed(1)}km';
    }
    return '${distance.round()}m';
  }

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      'turnInfo': turnInfo,
      'distanceMeters': distanceMeters,
      'primaryText': primaryText,
      'isArrival': isArrival,
      'directionKey': directionKey,
      'fallbackLabel': fallbackLabel,
      'distanceLabel': distanceLabel,
    };
  }
}

class _DriveArPresentation {
  final String mode;
  final String accentKey;
  final String layoutProfile;
  final String turnDirectionKey;
  final String distanceBucket;
  final int renderBudget;
  final bool showGuidePrimitive;
  final bool showGuideTrail;
  final bool showCard;
  final bool showStatusPill;
  final bool showMeta;
  final bool compactPreferred;
  final int detailLevel;
  final int emphasisLevel;
  final double guideAlpha;
  final double trailAlpha;

  const _DriveArPresentation({
    required this.mode,
    required this.accentKey,
    required this.layoutProfile,
    required this.turnDirectionKey,
    required this.distanceBucket,
    required this.renderBudget,
    required this.showGuidePrimitive,
    required this.showGuideTrail,
    required this.showCard,
    required this.showStatusPill,
    required this.showMeta,
    required this.compactPreferred,
    required this.detailLevel,
    required this.emphasisLevel,
    required this.guideAlpha,
    required this.trailAlpha,
  });

  const _DriveArPresentation.empty()
      : mode = 'idle',
        accentKey = 'inactive',
        layoutProfile = 'idle',
        turnDirectionKey = 'none',
        distanceBucket = 'none',
        renderBudget = 0,
        showGuidePrimitive = false,
        showGuideTrail = false,
        showCard = false,
        showStatusPill = false,
        showMeta = false,
        compactPreferred = false,
        detailLevel = 0,
        emphasisLevel = 0,
        guideAlpha = 0.0,
        trailAlpha = 0.0;

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      'mode': mode,
      'accentKey': accentKey,
      'layoutProfile': layoutProfile,
      'turnDirectionKey': turnDirectionKey,
      'distanceBucket': distanceBucket,
      'renderBudget': renderBudget,
      'showGuidePrimitive': showGuidePrimitive,
      'showGuideTrail': showGuideTrail,
      'showCard': showCard,
      'showStatusPill': showStatusPill,
      'showMeta': showMeta,
      'compactPreferred': compactPreferred,
      'detailLevel': detailLevel,
      'emphasisLevel': emphasisLevel,
      'guideAlpha': guideAlpha,
      'trailAlpha': trailAlpha,
    };
  }
}

class _DriveArSceneHealth {
  final int? modelFrameId;
  final int? cameraFrameId;
  final int? frameGap;
  final bool frameGapOk;
  final bool calibrationOk;
  final bool hasRoute;
  final bool hasTurnCue;

  const _DriveArSceneHealth({
    required this.modelFrameId,
    required this.cameraFrameId,
    required this.frameGap,
    required this.frameGapOk,
    required this.calibrationOk,
    required this.hasRoute,
    required this.hasTurnCue,
  });

  const _DriveArSceneHealth.empty()
      : modelFrameId = null,
        cameraFrameId = null,
        frameGap = null,
        frameGapOk = true,
        calibrationOk = false,
        hasRoute = false,
        hasTurnCue = false;

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      'modelFrameId': modelFrameId,
      'cameraFrameId': cameraFrameId,
      'frameGap': frameGap,
      'frameGapOk': frameGapOk,
      'calibrationOk': calibrationOk,
      'hasRoute': hasRoute,
      'hasTurnCue': hasTurnCue,
    };
  }
}

extension _DriveOverlaySnapshotArSceneX on _DriveOverlaySnapshot {
  _DriveArScene buildArScene({
    required _DriveCameraKind cameraKind,
    int frameGapTolerance = 8,
  }) {
    final routePoints = <_DriveArRoutePoint>[];
    for (final point in navPathPoints) {
      if (!point.x.isFinite || !point.y.isFinite || !point.d.isFinite) {
        continue;
      }
      routePoints.add(
        _DriveArRoutePoint(
          x: point.x,
          y: point.y,
          d: point.d,
        ),
      );
      if (routePoints.length >= 200) break;
    }

    final turnText = navMainText.trim();
    final hasTurnCue = navTurnInfo != 0 || turnText.isNotEmpty;
    final turnCue = hasTurnCue
        ? _DriveArTurnCue(
            turnInfo: navTurnInfo,
            distanceMeters: navDistToTurn,
            primaryText: turnText,
          )
        : null;

    final cameraFrameId = switch (cameraKind) {
      _DriveCameraKind.road => roadFrameId ?? wideRoadFrameId,
      _DriveCameraKind.wideRoad => wideRoadFrameId ?? roadFrameId,
    };
    final gap = (modelFrameId != null && cameraFrameId != null)
        ? (modelFrameId! - cameraFrameId).abs()
        : null;
    final calibrationOk = cameraKind == _DriveCameraKind.wideRoad
        ? calibrationRpy.length >= 3 && wideFromDeviceEuler.length >= 3
        : calibrationRpy.length >= 3;
    final health = _DriveArSceneHealth(
      modelFrameId: modelFrameId,
      cameraFrameId: cameraFrameId,
      frameGap: gap,
      frameGapOk: gap == null || gap <= frameGapTolerance,
      calibrationOk: calibrationOk,
      hasRoute: routePoints.length >= 2,
      hasTurnCue: turnCue != null,
    );
    final compactPreferred = cameraKind == _DriveCameraKind.wideRoad;
    final presentation = _buildArPresentation(
      cameraKind: cameraKind,
      health: health,
      compactPreferred: compactPreferred,
      hasRoute: routePoints.length >= 2,
      turnCue: turnCue,
      routePointCount: routePoints.length,
    );

    if (routePoints.length < 2 && turnCue == null) {
      return const _DriveArScene.empty();
    }

    return _DriveArScene(
      routePoints: routePoints,
      turnCue: turnCue,
      health: health,
      presentation: presentation,
    );
  }

  _DriveArPresentation _buildArPresentation({
    required _DriveCameraKind cameraKind,
    required _DriveArSceneHealth health,
    required bool compactPreferred,
    required bool hasRoute,
    required _DriveArTurnCue? turnCue,
    required int routePointCount,
  }) {
    final isWide = cameraKind == _DriveCameraKind.wideRoad;
    final directionKey = turnCue?.directionKey ?? 'none';
    final distanceBucket = _distanceBucket(turnCue?.distanceMeters);
    if (!health.calibrationOk || !health.frameGapOk) {
      return _DriveArPresentation(
        mode: 'caution',
        accentKey: 'warning',
        layoutProfile: isWide ? 'wide_monitor' : 'road_attached',
        turnDirectionKey: directionKey,
        distanceBucket: distanceBucket,
        renderBudget: 0,
        showGuidePrimitive: false,
        showGuideTrail: false,
        showCard: !isWide,
        showStatusPill: true,
        showMeta: false,
        compactPreferred: compactPreferred,
        detailLevel: 0,
        emphasisLevel: 0,
        guideAlpha: 0.0,
        trailAlpha: 0.0,
      );
    }
    if (turnCue?.isArrival ?? false) {
      return _DriveArPresentation(
        mode: 'arrival',
        accentKey: 'arrival',
        layoutProfile: isWide ? 'wide_monitor' : 'road_attached',
        turnDirectionKey: directionKey,
        distanceBucket: 'arrival',
        renderBudget: isWide ? 1 : 3,
        showGuidePrimitive: !isWide,
        showGuideTrail: false,
        showCard: !isWide,
        showStatusPill: true,
        showMeta: !isWide,
        compactPreferred: compactPreferred,
        detailLevel: isWide ? 1 : 3,
        emphasisLevel: isWide ? 2 : 3,
        guideAlpha: isWide ? 0.0 : 0.92,
        trailAlpha: 0.0,
      );
    }
    if (turnCue != null) {
      final emphasisLevel = switch (distanceBucket) {
        'immediate' => 3,
        'near' => 2,
        'far' => 1,
        _ => 1,
      };
      return _DriveArPresentation(
        mode: 'turn',
        accentKey: 'active',
        layoutProfile: isWide ? 'wide_monitor' : 'road_attached',
        turnDirectionKey: directionKey,
        distanceBucket: distanceBucket,
        renderBudget: isWide
            ? (distanceBucket == 'immediate' ? 2 : 1)
            : (distanceBucket == 'immediate' ? 3 : 2),
        showGuidePrimitive: !isWide || distanceBucket != 'far',
        showGuideTrail: !isWide,
        showCard: !isWide,
        showStatusPill: true,
        showMeta: !isWide && (!compactPreferred || routePointCount >= 10),
        compactPreferred: compactPreferred,
        detailLevel: isWide ? 1 : (routePointCount >= 12 ? 3 : 2),
        emphasisLevel: emphasisLevel,
        guideAlpha: switch (distanceBucket) {
          'immediate' => isWide ? 0.74 : 1.0,
          'near' => isWide ? 0.68 : 0.92,
          _ => isWide ? 0.56 : 0.84,
        },
        trailAlpha: switch (distanceBucket) {
          'immediate' => isWide ? 0.0 : 0.96,
          'near' => isWide ? 0.0 : 0.88,
          _ => isWide ? 0.0 : 0.78,
        },
      );
    }
    if (hasRoute) {
      return _DriveArPresentation(
        mode: 'route',
        accentKey: 'active',
        layoutProfile: isWide ? 'wide_monitor' : 'road_attached',
        turnDirectionKey: directionKey,
        distanceBucket: distanceBucket,
        renderBudget: isWide ? 0 : 2,
        showGuidePrimitive: !isWide,
        showGuideTrail: !isWide,
        showCard: !compactPreferred,
        showStatusPill: !isWide,
        showMeta: false,
        compactPreferred: compactPreferred,
        detailLevel: isWide ? 0 : (routePointCount >= 16 ? 2 : 1),
        emphasisLevel: 1,
        guideAlpha: isWide ? 0.0 : 0.74,
        trailAlpha: isWide ? 0.0 : 0.66,
      );
    }
    return _DriveArPresentation(
      mode: 'idle',
      accentKey: 'inactive',
      layoutProfile: 'idle',
      turnDirectionKey: directionKey,
      distanceBucket: distanceBucket,
      renderBudget: 0,
      showGuidePrimitive: false,
      showGuideTrail: false,
      showCard: false,
      showStatusPill: false,
      showMeta: false,
      compactPreferred: compactPreferred,
      detailLevel: 0,
      emphasisLevel: 0,
      guideAlpha: 0.0,
      trailAlpha: 0.0,
    );
  }

  String _distanceBucket(double? distanceMeters) {
    if (distanceMeters == null ||
        !distanceMeters.isFinite ||
        distanceMeters <= 0) {
      return 'none';
    }
    if (distanceMeters <= 60.0) return 'immediate';
    if (distanceMeters <= 180.0) return 'near';
    return 'far';
  }
}
