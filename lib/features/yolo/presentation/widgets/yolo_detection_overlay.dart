import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../domain/entities/yolo_detection.dart';

class YoloDetectionOverlay extends StatefulWidget {
  const YoloDetectionOverlay({
    super.key,
    required this.detections,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.showBoxes,
    required this.showLabels,
    this.detectionAgeUs = 0,
    this.leadAreas = const <Rect>[],
  });

  final List<YoloDetection> detections;
  final double sourceWidth;
  final double sourceHeight;
  final bool showBoxes;
  final bool showLabels;

  /// Pipeline latency in microseconds — how old detections are when they arrive.
  final int detectionAgeUs;

  /// Openpilot lead area rects in source coordinates for track anchoring.
  final List<Rect> leadAreas;

  @override
  State<YoloDetectionOverlay> createState() => _YoloDetectionOverlayState();
}

class _YoloDetectionOverlayState extends State<YoloDetectionOverlay>
    with SingleTickerProviderStateMixin {
  static const Duration _trackTransitionDuration = Duration(milliseconds: 60);
  static const Duration _missingHoldDuration = Duration(milliseconds: 160);
  static const Duration _missingFadeDuration = Duration(milliseconds: 180);
  static const double _minMatchScore = 0.10;
  static const double _kalmanAlphaPosition = 0.78;
  static const double _kalmanBetaPosition = 0.18;
  static const double _kalmanAlphaSize = 0.55;
  static const double _kalmanBetaSize = 0.06;
  static const double _predictionLeadFactor = 1.15;

  final List<_SmoothedDetectionTrack> _tracks = <_SmoothedDetectionTrack>[];
  late final Ticker _ticker;
  int _nextTrackId = 1;
  int? _leadTrackId;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_handleTick);
    _reconcileDetections();
  }

  @override
  void didUpdateWidget(covariant YoloDetectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceWidth != widget.sourceWidth ||
        oldWidget.sourceHeight != widget.sourceHeight) {
      _resetTracks();
      return;
    }
    if (!listEquals(oldWidget.detections, widget.detections) ||
        oldWidget.detectionAgeUs != widget.detectionAgeUs) {
      _reconcileDetections();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _handleTick(Duration elapsed) {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    _tracks.removeWhere((track) => track.isExpired(nowUs));
    final needsAnim = _tracks.any((track) => track.needsAnimation(nowUs));
    if (!needsAnim) {
      _ticker.stop();
      // No animation needed — skip repaint.
      return;
    }
    if (!mounted) return;
    setState(() {});
  }

  void _resetTracks() {
    _tracks.clear();
    _leadTrackId = null;
    _nextTrackId = 1;
    if (_ticker.isActive) {
      _ticker.stop();
    }
    _reconcileDetections();
  }

  void _reconcileDetections() {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final ageUs = widget.detectionAgeUs.clamp(0, 300000);
    final measurementTimeUs = ageUs > 0 ? nowUs - ageUs : nowUs;
    final matchedTrackIds = <int>{};
    final sortedDetections = widget.detections.toList(growable: false)
      ..sort((left, right) => right.score.compareTo(left.score));

    // Adaptive transition duration: match detection cadence when age is known.
    final transitionDuration = ageUs > 20000
        ? Duration(microseconds: (ageUs * 0.85).round().clamp(40000, 180000))
        : _trackTransitionDuration;

    for (final detection in sortedDetections) {
      final matched = _bestTrackFor(
        detection,
        nowUs,
        matchedTrackIds,
        measurementTimeUs: measurementTimeUs,
      );
      if (matched != null) {
        matched.adopt(
          detection,
          nowUs,
          transitionDuration: transitionDuration,
          measurementTimeUs: measurementTimeUs,
        );
        matchedTrackIds.add(matched.id);
        continue;
      }
      final track = _SmoothedDetectionTrack(
        id: _nextTrackId++,
        detection: detection,
        nowUs: nowUs,
        measurementTimeUs: measurementTimeUs,
      );
      _tracks.add(track);
      matchedTrackIds.add(track.id);
    }

    for (final track in _tracks) {
      if (matchedTrackIds.contains(track.id) || track.isExpired(nowUs)) {
        continue;
      }
      track.markMissing(
        nowUs,
        holdDuration: _leadTrackId == track.id
            ? Duration(
                microseconds:
                    (_missingHoldDuration.inMicroseconds * 1.3).round(),
              )
            : _missingHoldDuration,
        fadeDuration: _missingFadeDuration,
      );
    }

    _tracks.removeWhere((track) => track.isExpired(nowUs));
    _leadTrackId = _selectLeadTrack(nowUs);
    final shouldAnimate = _tracks.any((track) => track.needsAnimation(nowUs));
    if (shouldAnimate && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldAnimate && _ticker.isActive) {
      _ticker.stop();
    }

    if (!mounted) return;
    setState(() {});
  }

  _SmoothedDetectionTrack? _bestTrackFor(
    YoloDetection detection,
    int nowUs,
    Set<int> matchedTrackIds, {
    required int measurementTimeUs,
  }) {
    _SmoothedDetectionTrack? bestTrack;
    var bestScore = double.negativeInfinity;
    // Compare track prediction at measurement time (when frame was captured),
    // not at nowUs, to avoid systematic lag offset in matching.
    final matchTimeUs = measurementTimeUs;
    for (final track in _tracks) {
      if (matchedTrackIds.contains(track.id) || track.isExpired(nowUs)) {
        continue;
      }
      if (_trackingGroupForClass(track.classId) !=
          _trackingGroupForClass(detection.classId)) {
        continue;
      }
      final candidate = track.currentDetection(matchTimeUs);
      final iou = _sourceIou(candidate, detection);
      final dx = candidate.sourceCenterX - detection.sourceCenterX;
      final dy = candidate.sourceCenterY - detection.sourceCenterY;
      final distance = math.sqrt((dx * dx) + (dy * dy));
      final sizeReference = math.max(
        72.0,
        math.max(
          math.max(candidate.sourceWidth, candidate.sourceHeight),
          math.max(detection.sourceWidth, detection.sourceHeight),
        ),
      );
      final maxDistance = math.max(160.0, sizeReference * 2.0);
      if (distance > maxDistance && iou < 0.02) {
        continue;
      }
      final closeness = (1.0 - (distance / maxDistance)).clamp(0.0, 1.0);
      // Size similarity: reward when candidate and detection have similar dimensions.
      final wRatio = math.min(candidate.sourceWidth, detection.sourceWidth) /
          math.max(candidate.sourceWidth, detection.sourceWidth).clamp(1.0, double.infinity);
      final hRatio = math.min(candidate.sourceHeight, detection.sourceHeight) /
          math.max(candidate.sourceHeight, detection.sourceHeight).clamp(1.0, double.infinity);
      final sizeSimilarity = math.sqrt(wRatio * hRatio).clamp(0.0, 1.0);
      // Aspect ratio similarity: penalise shape changes.
      final candAr = candidate.sourceWidth /
          candidate.sourceHeight.clamp(1.0, double.infinity);
      final detAr = detection.sourceWidth /
          detection.sourceHeight.clamp(1.0, double.infinity);
      final arSimilarity =
          (math.min(candAr, detAr) / math.max(candAr, detAr).clamp(0.01, double.infinity))
              .clamp(0.0, 1.0);
      final exactClassBonus = track.classId == detection.classId ? 0.16 : 0.0;
      final leadTrackBonus = track.id == _leadTrackId ? 0.22 : 0.0;
      // Lead area anchoring: boost match when detection overlaps openpilot lead.
      var leadAreaBonus = 0.0;
      if (widget.leadAreas.isNotEmpty) {
        final detRect = Rect.fromLTRB(
          detection.sourceLeft,
          detection.sourceTop,
          detection.sourceRight,
          detection.sourceBottom,
        );
        for (final leadRect in widget.leadAreas) {
          final intersection = detRect.intersect(leadRect);
          if (!intersection.isEmpty && intersection.width > 0 && intersection.height > 0) {
            final detArea = detRect.width * detRect.height;
            final overlap = (intersection.width * intersection.height) /
                math.max(detArea, 1.0);
            leadAreaBonus = math.max(leadAreaBonus, overlap * 0.30);
          }
        }
      }
      final score = (iou * 1.30) +
          (closeness * 1.10) +
          (sizeSimilarity * 0.45) +
          (arSimilarity * 0.20) +
          (math.min(candidate.score, detection.score) * 0.18) +
          exactClassBonus +
          leadTrackBonus +
          leadAreaBonus;
      if (score > bestScore) {
        bestScore = score;
        bestTrack = track;
      }
    }
    if (bestScore < _minMatchScore) {
      return null;
    }
    return bestTrack;
  }

  String _trackingGroupForClass(int classId) {
    switch (classId) {
      case 2:
      case 3:
        return 'car'; // car + motorcycle
      case 5:
      case 7:
        return 'large_vehicle'; // bus + truck
      case 0:
        return 'person';
      case 1:
        return 'bicycle';
      case 9:
        return 'traffic_light';
      default:
        return 'class_$classId';
    }
  }

  List<_RenderedDetection> _renderedDetections() {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final rendered = <_RenderedDetection>[];
    for (final track in _tracks) {
      if (track.isExpired(nowUs)) continue;
      final opacity = track.opacity(nowUs);
      if (opacity <= 0.01) continue;
      rendered.add(
        _RenderedDetection(
          trackId: track.id,
          detection: track.currentDetection(nowUs),
          opacity: opacity,
        ),
      );
    }
    rendered.sort(
      (left, right) => _renderPriority(right).compareTo(_renderPriority(left)),
    );
    return rendered;
  }

  int? _selectLeadTrack(int nowUs) {
    _SmoothedDetectionTrack? bestTrack;
    var bestPriority = double.negativeInfinity;
    for (final track in _tracks) {
      if (track.isExpired(nowUs) || !_isVehicleClass(track.classId)) {
        continue;
      }
      final priority = _detectionPriority(track.currentDetection(nowUs));
      if (priority > bestPriority) {
        bestPriority = priority;
        bestTrack = track;
      }
    }
    return bestTrack?.id;
  }

  bool _isVehicleClass(int classId) {
    return classId == 2 || classId == 5 || classId == 7;
  }

  double _renderPriority(_RenderedDetection rendered) {
    final leadBonus = rendered.trackId == _leadTrackId ? 0.35 : 0.0;
    return _detectionPriority(rendered.detection) + leadBonus;
  }

  double _detectionPriority(YoloDetection detection) {
    final centerBias = (1.0 -
            ((detection.sourceCenterX / widget.sourceWidth - 0.5).abs() / 0.5))
        .clamp(0.0, 1.0);
    final centerY =
        (detection.sourceCenterY / widget.sourceHeight).clamp(0.0, 1.0);
    final areaRatio = ((detection.sourceWidth * detection.sourceHeight) /
            (widget.sourceWidth * widget.sourceHeight))
        .clamp(0.0, 1.0);
    switch (detection.classId) {
      case 2:
      case 5:
      case 7:
        return (detection.score * 1.55) +
            (centerBias * 0.60) +
            (centerY * 0.75) +
            math.min(areaRatio * 10.0, 0.45);
      case 9:
        return (detection.score * 1.30) +
            ((1.0 - centerY) * 0.45) +
            (centerBias * 0.15);
      default:
        return detection.score;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sourceWidth <= 0 || widget.sourceHeight <= 0) {
      return const SizedBox.shrink();
    }
    final detections = _renderedDetections();
    if (detections.isEmpty) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: CustomPaint(
        painter: _YoloDetectionOverlayPainter(
          detections: detections,
          sourceWidth: widget.sourceWidth,
          sourceHeight: widget.sourceHeight,
          showBoxes: widget.showBoxes,
          showLabels: widget.showLabels,
        ),
      ),
    );
  }

  static double _sourceIou(YoloDetection left, YoloDetection right) {
    final overlapLeft = math.max(left.sourceLeft, right.sourceLeft);
    final overlapTop = math.max(left.sourceTop, right.sourceTop);
    final overlapRight = math.min(left.sourceRight, right.sourceRight);
    final overlapBottom = math.min(left.sourceBottom, right.sourceBottom);
    final overlapWidth = math.max(0.0, overlapRight - overlapLeft);
    final overlapHeight = math.max(0.0, overlapBottom - overlapTop);
    final overlapArea = overlapWidth * overlapHeight;
    if (overlapArea <= 0) return 0;
    final leftArea = left.sourceWidth * left.sourceHeight;
    final rightArea = right.sourceWidth * right.sourceHeight;
    final union = leftArea + rightArea - overlapArea;
    if (union <= 0) return 0;
    return overlapArea / union;
  }
}

class _SmoothedDetectionTrack {
  _SmoothedDetectionTrack({
    required this.id,
    required YoloDetection detection,
    required int nowUs,
    int? measurementTimeUs,
  })  : _state = detection,
        _renderFrom = detection,
        _lastMeasurementUs = measurementTimeUs ?? nowUs,
        _transitionStartedUs = nowUs,
        _transitionDurationUs = 1;

  final int id;
  YoloDetection _state;
  YoloDetection _renderFrom;
  int _lastMeasurementUs;
  int _transitionStartedUs;
  int _transitionDurationUs;
  int _holdUntilUs = 0;
  int _removeAfterUs = 0;
  int _consecutiveMisses = 0;
  double _velocityX = 0;
  double _velocityY = 0;
  double _velocityW = 0;
  double _velocityH = 0;

  int get classId => _state.classId;

  void adopt(
    YoloDetection detection,
    int nowUs, {
    required Duration transitionDuration,
    int? measurementTimeUs,
  }) {
    // Use measurement time (when frame was captured) for Kalman state,
    // so prediction automatically compensates for pipeline latency.
    final effectiveMeasurementUs = measurementTimeUs ?? nowUs;
    final predicted = currentDetection(effectiveMeasurementUs);
    final dtUs = math.max(1, effectiveMeasurementUs - _lastMeasurementUs);
    final dtSec = dtUs / 1000000.0;

    final predictedCx = predicted.sourceCenterX;
    final predictedCy = predicted.sourceCenterY;
    final predictedW = predicted.sourceWidth;
    final predictedH = predicted.sourceHeight;

    final measuredCx = detection.sourceCenterX;
    final measuredCy = detection.sourceCenterY;
    final measuredW = detection.sourceWidth;
    final measuredH = detection.sourceHeight;

    final residualCx = measuredCx - predictedCx;
    final residualCy = measuredCy - predictedCy;
    final residualW = measuredW - predictedW;
    final residualH = measuredH - predictedH;

    _velocityX = _clampVelocity(
      (_velocityX +
              ((_YoloDetectionOverlayState._kalmanBetaPosition * residualCx) /
                  dtSec)) *
          0.90,
    );
    _velocityY = _clampVelocity(
      (_velocityY +
              ((_YoloDetectionOverlayState._kalmanBetaPosition * residualCy) /
                  dtSec)) *
          0.90,
    );
    _velocityW = _clampVelocity(
      (_velocityW +
              ((_YoloDetectionOverlayState._kalmanBetaSize * residualW) /
                  dtSec)) *
          0.82,
    );
    _velocityH = _clampVelocity(
      (_velocityH +
              ((_YoloDetectionOverlayState._kalmanBetaSize * residualH) /
                  dtSec)) *
          0.82,
    );

    final correctedCx = predictedCx +
        (_YoloDetectionOverlayState._kalmanAlphaPosition * residualCx);
    final correctedCy = predictedCy +
        (_YoloDetectionOverlayState._kalmanAlphaPosition * residualCy);
    final correctedW =
        predictedW + (_YoloDetectionOverlayState._kalmanAlphaSize * residualW);
    final correctedH =
        predictedH + (_YoloDetectionOverlayState._kalmanAlphaSize * residualH);

    // _renderFrom captures current visual position for smooth transition.
    _renderFrom = currentDetection(nowUs);
    // _state is set at measurement time; _predictedState extrapolates forward
    // by pipeline latency automatically when rendering at nowUs.
    _state = _withSourceRect(
      detection.copyWith(
        score: (predicted.score * 0.20) + (detection.score * 0.80),
      ),
      centerX: correctedCx,
      centerY: correctedCy,
      width: correctedW,
      height: correctedH,
    );
    _lastMeasurementUs = effectiveMeasurementUs;
    _transitionStartedUs = nowUs;
    _transitionDurationUs = math.max(1, transitionDuration.inMicroseconds);
    _holdUntilUs = 0;
    _removeAfterUs = 0;
    _consecutiveMisses = 0;
  }

  void markMissing(
    int nowUs, {
    required Duration holdDuration,
    required Duration fadeDuration,
  }) {
    if (_removeAfterUs > 0) {
      return;
    }
    _renderFrom = currentDetection(nowUs);
    _consecutiveMisses += 1;
    _holdUntilUs = nowUs + holdDuration.inMicroseconds;
    _removeAfterUs = _holdUntilUs + fadeDuration.inMicroseconds;
    _velocityX *= 0.80;
    _velocityY *= 0.80;
    _velocityW *= 0.70;
    _velocityH *= 0.70;
  }

  YoloDetection currentDetection(int nowUs) {
    final predicted = _predictedState(nowUs);
    if (_transitionDurationUs <= 1) {
      return predicted;
    }
    final elapsedUs =
        (nowUs - _transitionStartedUs).clamp(0, _transitionDurationUs);
    final rawT = (elapsedUs / _transitionDurationUs).clamp(0.0, 1.0);
    final easedT = 1.0 - math.pow(1.0 - rawT, 3).toDouble();
    return YoloDetection.lerp(_renderFrom, predicted, easedT);
  }

  YoloDetection _predictedState(int nowUs) {
    // Allow up to 400ms prediction window to accommodate pipeline latency.
    final elapsedUs = (nowUs - _lastMeasurementUs).clamp(0, 400000);
    final dtSec = elapsedUs / 1000000.0;
    final predictiveGain = _removeAfterUs > 0
        ? 1.0
        : _YoloDetectionOverlayState._predictionLeadFactor;
    final centerX =
        _state.sourceCenterX + (_velocityX * dtSec * predictiveGain);
    final centerY =
        _state.sourceCenterY + (_velocityY * dtSec * predictiveGain);
    final width = _state.sourceWidth + (_velocityW * dtSec * 0.35);
    final height = _state.sourceHeight + (_velocityH * dtSec * 0.35);
    return _withSourceRect(
      _state,
      centerX: centerX,
      centerY: centerY,
      width: width,
      height: height,
    );
  }

  double opacity(int nowUs) {
    if (_removeAfterUs <= 0) {
      return 1.0;
    }
    if (nowUs <= _holdUntilUs) {
      return 1.0;
    }
    final fadeWindow = (_removeAfterUs - _holdUntilUs).clamp(1, 1 << 30);
    final elapsed = (nowUs - _holdUntilUs).clamp(0, fadeWindow).toDouble();
    final t = (elapsed / fadeWindow).clamp(0.0, 1.0);
    return 1.0 - t;
  }

  bool needsAnimation(int nowUs) {
    if (isExpired(nowUs)) {
      return false;
    }
    if (_removeAfterUs > 0 && nowUs < _removeAfterUs) {
      return true;
    }
    final transitionEndsAtUs = _transitionStartedUs + _transitionDurationUs;
    if (nowUs < transitionEndsAtUs) {
      return true;
    }
    final velocityMagnitude = _velocityX.abs() +
        _velocityY.abs() +
        (_velocityW.abs() * 0.35) +
        (_velocityH.abs() * 0.35);
    return (nowUs - _lastMeasurementUs) < 400000 || velocityMagnitude > 12.0;
  }

  bool isExpired(int nowUs) {
    return _removeAfterUs > 0 && nowUs >= _removeAfterUs;
  }

  static YoloDetection _withSourceRect(
    YoloDetection base, {
    required double centerX,
    required double centerY,
    required double width,
    required double height,
  }) {
    final safeWidth = math.max(6.0, width);
    final safeHeight = math.max(6.0, height);
    final left = centerX - (safeWidth * 0.5);
    final top = centerY - (safeHeight * 0.5);
    return base.copyWith(
      sourceLeft: left,
      sourceTop: top,
      sourceRight: left + safeWidth,
      sourceBottom: top + safeHeight,
    );
  }

  static double _clampVelocity(double value) {
    return value.clamp(-1500.0, 1500.0).toDouble();
  }
}

class _RenderedDetection {
  _RenderedDetection({
    required this.trackId,
    required this.detection,
    required this.opacity,
  }) : labelText =
            '${detection.label} ${(detection.score * 100).toInt()}%';

  final int trackId;
  final YoloDetection detection;
  final double opacity;
  final String labelText;
}

class _YoloDetectionOverlayPainter extends CustomPainter {
  _YoloDetectionOverlayPainter({
    required this.detections,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.showBoxes,
    required this.showLabels,
  });

  final List<_RenderedDetection> detections;
  final double sourceWidth;
  final double sourceHeight;
  final bool showBoxes;
  final bool showLabels;

  // Reusable Paint objects — only color is updated per detection.
  static final Paint _boxShadowPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5.2;
  static final Paint _boxStrokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.8;
  static final Paint _boxFillPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _labelFillPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _labelAccentPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.1;
  static const Radius _boxRadius = Radius.circular(7);

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty || sourceWidth <= 0 || sourceHeight <= 0) return;
    final scaleX = size.width / sourceWidth;
    final scaleY = size.height / sourceHeight;
    final labelMaxWidth = math.min(size.width * 0.6, 220.0);

    for (final rendered in detections) {
      final detection = rendered.detection;
      final rect = Rect.fromLTRB(
        detection.sourceLeft * scaleX,
        detection.sourceTop * scaleY,
        detection.sourceRight * scaleX,
        detection.sourceBottom * scaleY,
      );
      if (rect.width < 2 || rect.height < 2) continue;

      final opacity = rendered.opacity.clamp(0.0, 1.0);
      final color = _colorForLabel(detection.label).withValues(alpha: opacity);
      if (showBoxes) {
        _boxShadowPaint.color =
            Colors.black.withValues(alpha: opacity * 0.88);
        _boxStrokePaint.color = color;
        _boxFillPaint.color = color.withValues(alpha: opacity * 0.12);
        final shape = RRect.fromRectAndRadius(rect, _boxRadius);
        canvas.drawRRect(shape, _boxFillPaint);
        canvas.drawRRect(shape, _boxShadowPaint);
        canvas.drawRRect(shape, _boxStrokePaint);
      }

      if (showLabels) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: rendered.labelText,
            style: TextStyle(
              color: Colors.white.withValues(alpha: opacity),
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: labelMaxWidth);
        final labelRect = Rect.fromLTWH(
          rect.left,
          math.max(0, rect.top - textPainter.height - 8),
          textPainter.width + 10,
          textPainter.height + 6,
        );
        _labelFillPaint.color =
            Colors.black.withValues(alpha: opacity * 0.84);
        _labelAccentPaint.color = color.withValues(alpha: opacity * 0.92);
        final labelShape = RRect.fromRectAndRadius(labelRect, _boxRadius);
        canvas.drawRRect(labelShape, _labelFillPaint);
        canvas.drawRRect(labelShape, _labelAccentPaint);
        textPainter.paint(
          canvas,
          Offset(labelRect.left + 5, labelRect.top + 3),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _YoloDetectionOverlayPainter oldDelegate) {
    return oldDelegate.detections != detections ||
        oldDelegate.sourceWidth != sourceWidth ||
        oldDelegate.sourceHeight != sourceHeight ||
        oldDelegate.showBoxes != showBoxes ||
        oldDelegate.showLabels != showLabels;
  }

  static Color _colorForLabel(String label) {
    final lower = label.toLowerCase();
    if (lower.contains('traffic light')) return Colors.amber;
    if (lower.contains('person')) return Colors.lightGreenAccent;
    if (lower.contains('car') ||
        lower.contains('truck') ||
        lower.contains('bus') ||
        lower.contains('motorcycle') ||
        lower.contains('bicycle')) {
      return Colors.cyanAccent;
    }
    return Colors.orangeAccent;
  }
}

bool listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
