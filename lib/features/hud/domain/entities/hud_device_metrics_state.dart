class HudDeviceMetricsState {
  final double? cpuTempAvgC;
  final double? cpuTempMaxC;
  final double? memUsagePct;
  final double? diskUsedPct;
  final double? freeSpacePct;
  final double? voltV;
  final String metricPrimaryMode;

  const HudDeviceMetricsState({
    this.cpuTempAvgC,
    this.cpuTempMaxC,
    this.memUsagePct,
    this.diskUsedPct,
    this.freeSpacePct,
    this.voltV,
    this.metricPrimaryMode = 'disk',
  });

  static const empty = HudDeviceMetricsState();

  HudDeviceMetricsState copyWith({
    double? cpuTempAvgC,
    double? cpuTempMaxC,
    double? memUsagePct,
    double? diskUsedPct,
    double? freeSpacePct,
    double? voltV,
    String? metricPrimaryMode,
  }) {
    return HudDeviceMetricsState(
      cpuTempAvgC: cpuTempAvgC ?? this.cpuTempAvgC,
      cpuTempMaxC: cpuTempMaxC ?? this.cpuTempMaxC,
      memUsagePct: memUsagePct ?? this.memUsagePct,
      diskUsedPct: diskUsedPct ?? this.diskUsedPct,
      freeSpacePct: freeSpacePct ?? this.freeSpacePct,
      voltV: voltV ?? this.voltV,
      metricPrimaryMode: metricPrimaryMode ?? this.metricPrimaryMode,
    );
  }
}
