class HudGpsState {
  final bool hasFix;
  final String? provider;

  const HudGpsState({
    this.hasFix = false,
    this.provider,
  });

  static const empty = HudGpsState();

  HudGpsState copyWith({
    bool? hasFix,
    String? provider,
  }) {
    return HudGpsState(
      hasFix: hasFix ?? this.hasFix,
      provider: provider ?? this.provider,
    );
  }
}
