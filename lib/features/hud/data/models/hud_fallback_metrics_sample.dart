class HudFallbackMetricsSample {
  final String host;
  final int tsEpochMs;
  final double? cpuTempC;
  final double? memPct;
  final double? diskPct;

  const HudFallbackMetricsSample({
    required this.host,
    required this.tsEpochMs,
    this.cpuTempC,
    this.memPct,
    this.diskPct,
  });
}
