class HudLimitState {
  final String mode;
  final String? label;
  final double? displaySpeedKph;
  final double? roadLimitSpeedKph;
  final double? cameraLimitSpeedKph;
  final int? cameraSignType;
  final bool isOverLimit;
  final bool shouldBlink;

  const HudLimitState({
    this.mode = 'hidden',
    this.label,
    this.displaySpeedKph,
    this.roadLimitSpeedKph,
    this.cameraLimitSpeedKph,
    this.cameraSignType,
    this.isOverLimit = false,
    this.shouldBlink = false,
  });

  static const empty = HudLimitState();

  HudLimitState copyWith({
    String? mode,
    String? label,
    double? displaySpeedKph,
    double? roadLimitSpeedKph,
    double? cameraLimitSpeedKph,
    int? cameraSignType,
    bool? isOverLimit,
    bool? shouldBlink,
  }) {
    return HudLimitState(
      mode: mode ?? this.mode,
      label: label ?? this.label,
      displaySpeedKph: displaySpeedKph ?? this.displaySpeedKph,
      roadLimitSpeedKph: roadLimitSpeedKph ?? this.roadLimitSpeedKph,
      cameraLimitSpeedKph: cameraLimitSpeedKph ?? this.cameraLimitSpeedKph,
      cameraSignType: cameraSignType ?? this.cameraSignType,
      isOverLimit: isOverLimit ?? this.isOverLimit,
      shouldBlink: shouldBlink ?? this.shouldBlink,
    );
  }
}
