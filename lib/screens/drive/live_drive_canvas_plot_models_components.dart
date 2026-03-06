part of 'live_drive_canvas_screen.dart';

class _DriveDebugPlotSample {
  final int mode;
  final String title;
  final double yellow;
  final double green;
  final double orange;

  const _DriveDebugPlotSample({
    required this.mode,
    required this.title,
    required this.yellow,
    required this.green,
    required this.orange,
  });

  static _DriveDebugPlotSample? fromDynamic(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final mode = _DriveOverlaySnapshot._asInt(map['mode']) ?? 0;
    if (mode <= 0) return null;
    final title = (map['title']?.toString() ?? '').trim();
    final valuesRaw = map['values'];
    final values = <double>[];
    if (valuesRaw is List) {
      for (final item in valuesRaw.take(3)) {
        final v = _DriveOverlaySnapshot._asDouble(item);
        values.add(v != null && v.isFinite ? v : 0.0);
      }
    }
    while (values.length < 3) {
      values.add(0.0);
    }
    return _DriveDebugPlotSample(
      mode: mode,
      title: title.isEmpty ? 'no data' : title,
      yellow: values[0],
      green: values[1],
      orange: values[2],
    );
  }
}

class _DriveDebugPlotState {
  static const int maxSamples = 400;
  static const double _minSpan = 6.0;
  static const double _rangeSmoothing = 0.16;

  final int version;
  final int mode;
  final String title;
  final List<double> yellow;
  final List<double> green;
  final List<double> orange;
  final double minValue;
  final double maxValue;

  const _DriveDebugPlotState({
    required this.version,
    required this.mode,
    required this.title,
    required this.yellow,
    required this.green,
    required this.orange,
    required this.minValue,
    required this.maxValue,
  });

  const _DriveDebugPlotState.hidden()
      : version = 0,
        mode = 0,
        title = '',
        yellow = const <double>[],
        green = const <double>[],
        orange = const <double>[],
        minValue = -2.0,
        maxValue = 2.0;

  bool get isVisible =>
      mode > 0 &&
      yellow.isNotEmpty &&
      green.isNotEmpty &&
      orange.isNotEmpty;

  int get sampleCount => math.min(yellow.length, math.min(green.length, orange.length));

  double get latestYellow => yellow.isEmpty ? 0.0 : yellow.last;
  double get latestGreen => green.isEmpty ? 0.0 : green.last;
  double get latestOrange => orange.isEmpty ? 0.0 : orange.last;

  static double _lerpTowards(double current, double target, double factor) {
    return current + ((target - current) * factor);
  }

  static ({double minValue, double maxValue}) _resolveRange({
    required double rawMin,
    required double rawMax,
  }) {
    var minValue = rawMin;
    var maxValue = rawMax;
    if (!minValue.isFinite || !maxValue.isFinite) {
      minValue = -2.0;
      maxValue = 2.0;
    }
    if (minValue > -2.0) minValue = -2.0;
    if (maxValue < 2.0) maxValue = 2.0;
    final rawSpan = math.max(0.001, maxValue - minValue);
    final paddedSpan = math.max(_minSpan, rawSpan * 1.32);
    final center = (minValue + maxValue) * 0.5;
    final halfSpan = paddedSpan * 0.5;
    return (
      minValue: center - halfSpan,
      maxValue: center + halfSpan,
    );
  }

  _DriveDebugPlotState clear() {
    if (!isVisible && version == 0) {
      return this;
    }
    if (!isVisible) {
      return _DriveDebugPlotState(
        version: version,
        mode: 0,
        title: '',
        yellow: const <double>[],
        green: const <double>[],
        orange: const <double>[],
        minValue: -2.0,
        maxValue: 2.0,
      );
    }
    return _DriveDebugPlotState(
      version: version + 1,
      mode: 0,
      title: '',
      yellow: const <double>[],
      green: const <double>[],
      orange: const <double>[],
      minValue: -2.0,
      maxValue: 2.0,
    );
  }

  _DriveDebugPlotState push(_DriveDebugPlotSample sample) {
    final reset = !isVisible || mode != sample.mode || title != sample.title;
    final nextYellow =
        reset ? <double>[] : List<double>.from(yellow, growable: true);
    final nextGreen =
        reset ? <double>[] : List<double>.from(green, growable: true);
    final nextOrange =
        reset ? <double>[] : List<double>.from(orange, growable: true);
    nextYellow.add(sample.yellow);
    nextGreen.add(sample.green);
    nextOrange.add(sample.orange);
    while (nextYellow.length > maxSamples) {
      nextYellow.removeAt(0);
    }
    while (nextGreen.length > maxSamples) {
      nextGreen.removeAt(0);
    }
    while (nextOrange.length > maxSamples) {
      nextOrange.removeAt(0);
    }

    var minValue = double.infinity;
    var maxValue = double.negativeInfinity;
    for (final series in <List<double>>[nextYellow, nextGreen, nextOrange]) {
      for (final value in series) {
        if (!value.isFinite) continue;
        if (value < minValue) minValue = value;
        if (value > maxValue) maxValue = value;
      }
    }
    if (!minValue.isFinite || !maxValue.isFinite) {
      minValue = -2.0;
      maxValue = 2.0;
    }
    final resolved = _resolveRange(
      rawMin: minValue,
      rawMax: maxValue,
    );
    var nextMinValue = resolved.minValue;
    var nextMaxValue = resolved.maxValue;
    if (!reset && isVisible) {
      if (resolved.minValue < this.minValue) {
        nextMinValue = resolved.minValue;
      } else {
        nextMinValue = _lerpTowards(
          this.minValue,
          resolved.minValue,
          _rangeSmoothing,
        );
      }
      if (resolved.maxValue > this.maxValue) {
        nextMaxValue = resolved.maxValue;
      } else {
        nextMaxValue = _lerpTowards(
          this.maxValue,
          resolved.maxValue,
          _rangeSmoothing,
        );
      }
      if ((nextMaxValue - nextMinValue) < _minSpan) {
        final center = (nextMinValue + nextMaxValue) * 0.5;
        nextMinValue = center - (_minSpan * 0.5);
        nextMaxValue = center + (_minSpan * 0.5);
      }
    }

    return _DriveDebugPlotState(
      version: version + 1,
      mode: sample.mode,
      title: sample.title,
      yellow: List<double>.unmodifiable(nextYellow),
      green: List<double>.unmodifiable(nextGreen),
      orange: List<double>.unmodifiable(nextOrange),
      minValue: nextMinValue,
      maxValue: nextMaxValue,
    );
  }
}
