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
  });

  final List<YoloDetection> detections;
  final double sourceWidth;
  final double sourceHeight;
  final bool showBoxes;
  final bool showLabels;

  @override
  State<YoloDetectionOverlay> createState() => _YoloDetectionOverlayState();
}

class _YoloDetectionOverlayState extends State<YoloDetectionOverlay>
    with SingleTickerProviderStateMixin {
  static const Duration _trackTransitionDuration = Duration(milliseconds: 120);
  static const Duration _missingHoldDuration = Duration(milliseconds: 140);
  static const Duration _missingFadeDuration = Duration(milliseconds: 180);
  static const double _minMatchScore = 0.18;

  final List<_SmoothedDetectionTrack> _tracks = <_SmoothedDetectionTrack>[];
  late final Ticker _ticker;
  int _nextTrackId = 1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_handleTick);
    _reconcileDetections();
  }

  @override
  void didUpdateWidget(covariant YoloDetectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.detections, widget.detections)) {
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
    if (!_tracks.any((track) => track.needsAnimation(nowUs))) {
      _ticker.stop();
    }
    if (!mounted) return;
    setState(() {});
  }

  void _reconcileDetections() {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final matchedTrackIds = <int>{};
    final sortedDetections = widget.detections.toList(growable: false)
      ..sort((left, right) => right.score.compareTo(left.score));

    for (final detection in sortedDetections) {
      final matched = _bestTrackFor(detection, nowUs, matchedTrackIds);
      if (matched != null) {
        matched.adopt(
          detection,
          nowUs,
          transitionDuration: _trackTransitionDuration,
        );
        matchedTrackIds.add(matched.id);
        continue;
      }
      final track = _SmoothedDetectionTrack(
        id: _nextTrackId++,
        detection: detection,
        nowUs: nowUs,
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
        holdDuration: _missingHoldDuration,
        fadeDuration: _missingFadeDuration,
      );
    }

    _tracks.removeWhere((track) => track.isExpired(nowUs));
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
    Set<int> matchedTrackIds,
  ) {
    _SmoothedDetectionTrack? bestTrack;
    var bestScore = double.negativeInfinity;
    for (final track in _tracks) {
      if (matchedTrackIds.contains(track.id) || track.isExpired(nowUs)) {
        continue;
      }
      if (track.classId != detection.classId) {
        continue;
      }
      final candidate = track.currentDetection(nowUs);
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
      final maxDistance = math.max(92.0, sizeReference * 1.8);
      if (distance > maxDistance && iou < 0.04) {
        continue;
      }
      final closeness = (1.0 - (distance / maxDistance)).clamp(0.0, 1.0);
      final score = (iou * 1.35) +
          (closeness * 0.75) +
          (math.min(candidate.score, detection.score) * 0.15);
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

  List<_RenderedDetection> _renderedDetections() {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final rendered = <_RenderedDetection>[];
    for (final track in _tracks) {
      if (track.isExpired(nowUs)) continue;
      final opacity = track.opacity(nowUs);
      if (opacity <= 0.01) continue;
      rendered.add(
        _RenderedDetection(
          detection: track.currentDetection(nowUs),
          opacity: opacity,
        ),
      );
    }
    rendered.sort(
      (left, right) => right.detection.score.compareTo(left.detection.score),
    );
    return rendered;
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
  })  : _from = detection,
        _to = detection,
        _transitionStartedUs = nowUs,
        _transitionDurationUs = 1;

  final int id;
  YoloDetection _from;
  YoloDetection _to;
  int _transitionStartedUs;
  int _transitionDurationUs;
  int _holdUntilUs = 0;
  int _removeAfterUs = 0;

  int get classId => _to.classId;

  void adopt(
    YoloDetection detection,
    int nowUs, {
    required Duration transitionDuration,
  }) {
    final current = currentDetection(nowUs);
    _from = current;
    _to = detection;
    _transitionStartedUs = nowUs;
    _transitionDurationUs = math.max(1, transitionDuration.inMicroseconds);
    _holdUntilUs = 0;
    _removeAfterUs = 0;
  }

  void markMissing(
    int nowUs, {
    required Duration holdDuration,
    required Duration fadeDuration,
  }) {
    if (_removeAfterUs > 0) {
      return;
    }
    final current = currentDetection(nowUs);
    _from = current;
    _to = current;
    _transitionStartedUs = nowUs;
    _transitionDurationUs = 1;
    _holdUntilUs = nowUs + holdDuration.inMicroseconds;
    _removeAfterUs = _holdUntilUs + fadeDuration.inMicroseconds;
  }

  YoloDetection currentDetection(int nowUs) {
    if (_transitionDurationUs <= 1) {
      return _to;
    }
    final elapsed = (nowUs - _transitionStartedUs)
        .clamp(0, _transitionDurationUs)
        .toDouble();
    final rawT = (elapsed / _transitionDurationUs).clamp(0.0, 1.0);
    final easedT = 1.0 - math.pow(1.0 - rawT, 3).toDouble();
    return YoloDetection.lerp(_from, _to, easedT);
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
    final transitionEndsAtUs = _transitionStartedUs + _transitionDurationUs;
    return nowUs < transitionEndsAtUs ||
        (_removeAfterUs > 0 && nowUs < _removeAfterUs);
  }

  bool isExpired(int nowUs) {
    return _removeAfterUs > 0 && nowUs >= _removeAfterUs;
  }
}

class _RenderedDetection {
  const _RenderedDetection({
    required this.detection,
    required this.opacity,
  });

  final YoloDetection detection;
  final double opacity;
}

class _YoloDetectionOverlayPainter extends CustomPainter {
  const _YoloDetectionOverlayPainter({
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

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty || sourceWidth <= 0 || sourceHeight <= 0) return;
    final scaleX = size.width / sourceWidth;
    final scaleY = size.height / sourceHeight;

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
      final color = _colorForLabel(detection.label).withValues(
        alpha: opacity,
      );
      if (showBoxes) {
        final stroke = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2;
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(7)),
          stroke,
        );
      }

      if (showLabels) {
        final label =
            '${detection.label} ${(detection.score * 100).toStringAsFixed(0)}%';
        final textPainter = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: opacity),
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: math.min(size.width * 0.6, 220));
        final labelRect = Rect.fromLTWH(
          rect.left,
          math.max(0, rect.top - textPainter.height - 8),
          textPainter.width + 10,
          textPainter.height + 6,
        );
        final fill = Paint()
          ..color = color.withValues(alpha: opacity * 0.82)
          ..style = PaintingStyle.fill;
        canvas.drawRRect(
          RRect.fromRectAndRadius(labelRect, const Radius.circular(7)),
          fill,
        );
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
