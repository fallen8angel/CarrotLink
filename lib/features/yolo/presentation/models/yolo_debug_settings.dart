class YoloDebugSettings {
  final bool enabled;
  final bool showBoxes;
  final bool showLabels;
  final bool showTrafficLights;
  final bool showStats;

  const YoloDebugSettings({
    this.enabled = false,
    this.showBoxes = false,
    this.showLabels = false,
    this.showTrafficLights = false,
    this.showStats = false,
  });

  static const empty = YoloDebugSettings();

  YoloDebugSettings copyWith({
    bool? enabled,
    bool? showBoxes,
    bool? showLabels,
    bool? showTrafficLights,
    bool? showStats,
  }) {
    return YoloDebugSettings(
      enabled: enabled ?? this.enabled,
      showBoxes: showBoxes ?? this.showBoxes,
      showLabels: showLabels ?? this.showLabels,
      showTrafficLights: showTrafficLights ?? this.showTrafficLights,
      showStats: showStats ?? this.showStats,
    );
  }

  Map<String, bool> toJson() {
    return <String, bool>{
      'yoloEnabled': enabled,
      'yoloBoxes': showBoxes,
      'yoloLabels': showLabels,
      'yoloTrafficLights': showTrafficLights,
      'yoloStats': showStats,
    };
  }

  factory YoloDebugSettings.fromJson(Map<String, dynamic> json) {
    bool readBool(String key) {
      final value = json[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'true' || normalized == '1') return true;
      }
      return false;
    }

    return YoloDebugSettings(
      enabled: readBool('yoloEnabled'),
      showBoxes: readBool('yoloBoxes'),
      showLabels: readBool('yoloLabels'),
      showTrafficLights: readBool('yoloTrafficLights'),
      showStats: readBool('yoloStats'),
    );
  }
}
