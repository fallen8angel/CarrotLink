class HudDriveModeState {
  final int? code;
  final String nameOriginal;
  final String kind;

  const HudDriveModeState({
    this.code,
    this.nameOriginal = 'NORM',
    this.kind = 'normal',
  });

  static const empty = HudDriveModeState();

  HudDriveModeState copyWith({
    int? code,
    String? nameOriginal,
    String? kind,
  }) {
    return HudDriveModeState(
      code: code ?? this.code,
      nameOriginal: nameOriginal ?? this.nameOriginal,
      kind: kind ?? this.kind,
    );
  }
}
