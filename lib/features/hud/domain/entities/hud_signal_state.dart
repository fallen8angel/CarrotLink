class HudSignalState {
  final int? trafficStateLp;
  final int? trafficStateCarrot;
  final String visualState;
  final bool redDot;

  const HudSignalState({
    this.trafficStateLp,
    this.trafficStateCarrot,
    this.visualState = 'off',
    this.redDot = false,
  });

  static const empty = HudSignalState();

  HudSignalState copyWith({
    int? trafficStateLp,
    int? trafficStateCarrot,
    String? visualState,
    bool? redDot,
  }) {
    return HudSignalState(
      trafficStateLp: trafficStateLp ?? this.trafficStateLp,
      trafficStateCarrot: trafficStateCarrot ?? this.trafficStateCarrot,
      visualState: visualState ?? this.visualState,
      redDot: redDot ?? this.redDot,
    );
  }
}
