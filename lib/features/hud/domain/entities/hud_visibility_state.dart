class HudVisibilityState {
  final bool showDeviceState;
  final int? showDateTimeMode;

  const HudVisibilityState({
    this.showDeviceState = true,
    this.showDateTimeMode,
  });

  static const empty = HudVisibilityState();

  HudVisibilityState copyWith({
    bool? showDeviceState,
    int? showDateTimeMode,
  }) {
    return HudVisibilityState(
      showDeviceState: showDeviceState ?? this.showDeviceState,
      showDateTimeMode: showDateTimeMode ?? this.showDateTimeMode,
    );
  }
}
