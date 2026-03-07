class HudTempControlState {
  final String mode;
  final String? label;
  final double? speedKph;
  final String? sourceRaw;
  final double? applySpeedKph;
  final double? cruiseTargetKph;
  final bool isDecel;

  const HudTempControlState({
    this.mode = 'hidden',
    this.label,
    this.speedKph,
    this.sourceRaw,
    this.applySpeedKph,
    this.cruiseTargetKph,
    this.isDecel = false,
  });

  static const empty = HudTempControlState();

  HudTempControlState copyWith({
    String? mode,
    String? label,
    double? speedKph,
    String? sourceRaw,
    double? applySpeedKph,
    double? cruiseTargetKph,
    bool? isDecel,
  }) {
    return HudTempControlState(
      mode: mode ?? this.mode,
      label: label ?? this.label,
      speedKph: speedKph ?? this.speedKph,
      sourceRaw: sourceRaw ?? this.sourceRaw,
      applySpeedKph: applySpeedKph ?? this.applySpeedKph,
      cruiseTargetKph: cruiseTargetKph ?? this.cruiseTargetKph,
      isDecel: isDecel ?? this.isDecel,
    );
  }
}
