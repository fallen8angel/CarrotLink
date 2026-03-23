class YoloDetection {
  const YoloDetection({
    required this.classId,
    required this.label,
    required this.score,
    required this.inputLeft,
    required this.inputTop,
    required this.inputRight,
    required this.inputBottom,
    required this.sourceLeft,
    required this.sourceTop,
    required this.sourceRight,
    required this.sourceBottom,
  });

  final int classId;
  final String label;
  final double score;
  final double inputLeft;
  final double inputTop;
  final double inputRight;
  final double inputBottom;
  final double sourceLeft;
  final double sourceTop;
  final double sourceRight;
  final double sourceBottom;

  double get sourceWidth =>
      (sourceRight - sourceLeft).clamp(0, double.infinity);
  double get sourceHeight =>
      (sourceBottom - sourceTop).clamp(0, double.infinity);
  double get sourceCenterX => (sourceLeft + sourceRight) * 0.5;
  double get sourceCenterY => (sourceTop + sourceBottom) * 0.5;

  YoloDetection withScore(double score) {
    return YoloDetection(
      classId: classId,
      label: label,
      score: score,
      inputLeft: inputLeft,
      inputTop: inputTop,
      inputRight: inputRight,
      inputBottom: inputBottom,
      sourceLeft: sourceLeft,
      sourceTop: sourceTop,
      sourceRight: sourceRight,
      sourceBottom: sourceBottom,
    );
  }

  YoloDetection copyWith({
    int? classId,
    String? label,
    double? score,
    double? inputLeft,
    double? inputTop,
    double? inputRight,
    double? inputBottom,
    double? sourceLeft,
    double? sourceTop,
    double? sourceRight,
    double? sourceBottom,
  }) {
    return YoloDetection(
      classId: classId ?? this.classId,
      label: label ?? this.label,
      score: score ?? this.score,
      inputLeft: inputLeft ?? this.inputLeft,
      inputTop: inputTop ?? this.inputTop,
      inputRight: inputRight ?? this.inputRight,
      inputBottom: inputBottom ?? this.inputBottom,
      sourceLeft: sourceLeft ?? this.sourceLeft,
      sourceTop: sourceTop ?? this.sourceTop,
      sourceRight: sourceRight ?? this.sourceRight,
      sourceBottom: sourceBottom ?? this.sourceBottom,
    );
  }

  static YoloDetection lerp(
    YoloDetection a,
    YoloDetection b,
    double t,
  ) {
    final clamped = t.clamp(0.0, 1.0);
    double blend(double left, double right) =>
        left + ((right - left) * clamped);
    return YoloDetection(
      classId: b.classId,
      label: b.label,
      score: blend(a.score, b.score),
      inputLeft: blend(a.inputLeft, b.inputLeft),
      inputTop: blend(a.inputTop, b.inputTop),
      inputRight: blend(a.inputRight, b.inputRight),
      inputBottom: blend(a.inputBottom, b.inputBottom),
      sourceLeft: blend(a.sourceLeft, b.sourceLeft),
      sourceTop: blend(a.sourceTop, b.sourceTop),
      sourceRight: blend(a.sourceRight, b.sourceRight),
      sourceBottom: blend(a.sourceBottom, b.sourceBottom),
    );
  }

  static List<YoloDetection> listFromPayload(dynamic value) {
    if (value is! List) return const <YoloDetection>[];
    return value
        .map((entry) => fromPayload(entry))
        .whereType<YoloDetection>()
        .toList(growable: false);
  }

  static YoloDetection? fromPayload(dynamic value) {
    if (value is! Map) return null;
    final payload = value.map((key, entry) => MapEntry(key.toString(), entry));
    return YoloDetection(
      classId: _asInt(payload['classId']),
      label: payload['label']?.toString() ?? 'unknown',
      score: _asDouble(payload['score']),
      inputLeft: _asDouble(payload['inputLeft']),
      inputTop: _asDouble(payload['inputTop']),
      inputRight: _asDouble(payload['inputRight']),
      inputBottom: _asDouble(payload['inputBottom']),
      sourceLeft: _asDouble(payload['sourceLeft']),
      sourceTop: _asDouble(payload['sourceTop']),
      sourceRight: _asDouble(payload['sourceRight']),
      sourceBottom: _asDouble(payload['sourceBottom']),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static double _asDouble(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}
