class HudConnectivityState {
  final int? activeCarrot;
  final String badgeMode;
  final String? badgeLabel;

  const HudConnectivityState({
    this.activeCarrot,
    this.badgeMode = 'hidden',
    this.badgeLabel,
  });

  static const empty = HudConnectivityState();

  HudConnectivityState copyWith({
    int? activeCarrot,
    String? badgeMode,
    String? badgeLabel,
  }) {
    return HudConnectivityState(
      activeCarrot: activeCarrot ?? this.activeCarrot,
      badgeMode: badgeMode ?? this.badgeMode,
      badgeLabel: badgeLabel ?? this.badgeLabel,
    );
  }
}
