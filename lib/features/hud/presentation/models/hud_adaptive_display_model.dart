import '../../domain/entities/original_hud_snapshot.dart';

class HudAdaptiveDisplayModel {
  final String speedText;
  final String setSpeedText;
  final String gearText;
  final String driveModeText;
  final String driveModeKind;
  final String tempLabel;
  final String tempSpeedText;
  final bool tempIsDecel;
  final String limitLabel;
  final String limitValueText;
  final bool limitCritical;
  final bool limitBlink;
  final String connectivityText;
  final bool showConnectivity;
  final bool hasGpsFix;
  final String gpsText;
  final int gapBarCount;
  final String gapText;
  final String signalState;
  final bool redDot;
  final String cpuText;
  final String memText;
  final String auxMetricLabel;
  final String auxMetricText;
  final bool showDeviceMetrics;
  final bool longActive;
  final bool latActive;
  final bool isPreview;
  final String sourceText;
  final String qualityText;
  final String hostText;
  final String compatibilityHint;
  final bool showCompatibilityHint;
  final int tsMonoMs;

  const HudAdaptiveDisplayModel({
    required this.speedText,
    required this.setSpeedText,
    required this.gearText,
    required this.driveModeText,
    required this.driveModeKind,
    required this.tempLabel,
    required this.tempSpeedText,
    required this.tempIsDecel,
    required this.limitLabel,
    required this.limitValueText,
    required this.limitCritical,
    required this.limitBlink,
    required this.connectivityText,
    required this.showConnectivity,
    required this.hasGpsFix,
    required this.gpsText,
    required this.gapBarCount,
    required this.gapText,
    required this.signalState,
    required this.redDot,
    required this.cpuText,
    required this.memText,
    required this.auxMetricLabel,
    required this.auxMetricText,
    required this.showDeviceMetrics,
    required this.longActive,
    required this.latActive,
    required this.isPreview,
    required this.sourceText,
    required this.qualityText,
    required this.hostText,
    required this.compatibilityHint,
    required this.showCompatibilityHint,
    required this.tsMonoMs,
  });

  factory HudAdaptiveDisplayModel.fromSnapshot(OriginalHudSnapshot snapshot) {
    final auxIsVolt = snapshot.device.metricPrimaryMode == 'volt';
    final tempLabel = (snapshot.tempControl.label ?? snapshot.tempControl.mode)
        .trim()
        .toLowerCase();
    final limitLabel = (snapshot.limits.label ?? snapshot.limits.mode)
        .trim()
        .toUpperCase();
    final sourceText = _buildSourceText(snapshot);
    final qualityText = _buildQualityText(snapshot);
    final compatibilityHint = _buildCompatibilityHint(snapshot);
    return HudAdaptiveDisplayModel(
      speedText: _formatInt(snapshot.vehicle.speedClusterKph),
      setSpeedText: _formatInt(snapshot.vehicle.setSpeedClusterKph),
      gearText: snapshot.vehicle.gearText.trim().isEmpty
          ? 'U'
          : snapshot.vehicle.gearText.trim(),
      driveModeText: snapshot.driveMode.nameOriginal,
      driveModeKind: snapshot.driveMode.kind,
      tempLabel: tempLabel.isEmpty ? 'apply' : tempLabel,
      tempSpeedText: _formatInt(snapshot.tempControl.speedKph),
      tempIsDecel: snapshot.tempControl.isDecel,
      limitLabel: limitLabel.isEmpty ? 'LIMIT' : limitLabel,
      limitValueText: _formatInt(snapshot.limits.displaySpeedKph),
      limitCritical: snapshot.limits.isOverLimit,
      limitBlink: snapshot.limits.shouldBlink,
      connectivityText: (snapshot.connectivity.badgeLabel ?? '').trim(),
      showConnectivity:
          (snapshot.connectivity.badgeLabel ?? '').trim().isNotEmpty,
      hasGpsFix: snapshot.gps.hasFix,
      gpsText: snapshot.gps.hasFix ? 'GPS' : 'NO GPS',
      gapBarCount: snapshot.gap.barCount.clamp(0, 4),
      gapText: snapshot.gap.displayValue > 0
          ? '${snapshot.gap.displayValue}'
          : '--',
      signalState: snapshot.signals.visualState,
      redDot: snapshot.signals.redDot,
      cpuText: _formatTemperature(snapshot.device.cpuTempAvgC),
      memText: _formatPercent(snapshot.device.memUsagePct),
      auxMetricLabel: auxIsVolt ? 'VOLT' : 'DISK',
      auxMetricText: auxIsVolt
          ? _formatVolt(snapshot.device.voltV)
          : _formatPercent(snapshot.device.diskUsedPct),
      showDeviceMetrics: snapshot.visibility.showDeviceState,
      longActive: snapshot.vehicle.longActive,
      latActive: snapshot.vehicle.latActive,
      isPreview: snapshot.meta.isPreview,
      sourceText: sourceText,
      qualityText: qualityText,
      hostText: (snapshot.source.deviceHost ?? '').trim(),
      compatibilityHint: compatibilityHint,
      showCompatibilityHint: compatibilityHint.isNotEmpty,
      tsMonoMs: snapshot.tsMonoMs,
    );
  }

  static String _buildSourceText(OriginalHudSnapshot snapshot) {
    if (snapshot.meta.isPreview) return 'PREVIEW';
    switch (snapshot.source.transport.trim().toLowerCase()) {
      case 'sidecar_hud':
        return 'HUD';
      case 'legacy_ws_carstate':
        return 'COMPAT';
      case 'ssh_fallback':
      case 'fallback':
        return 'FALLBACK';
      case 'unknown':
      case '':
        return 'REMOTE';
      default:
        return 'LIVE';
    }
  }

  static String _buildQualityText(OriginalHudSnapshot snapshot) {
    if (snapshot.meta.isPreview) return 'preview';
    final quality = snapshot.meta.quality.trim();
    return quality.isEmpty ? 'live' : quality;
  }

  static String _buildCompatibilityHint(OriginalHudSnapshot snapshot) {
    final missingCount = snapshot.meta.missingFields.length;
    if (missingCount > 0) {
      return '$missingCount missing';
    }
    if (snapshot.meta.isFallbackMetricsApplied) {
      return 'metric fallback';
    }
    return '';
  }

  static String _formatInt(double? value) {
    if (value == null) return '--';
    return '${value.round()}';
  }

  static String _formatTemperature(double? value) {
    if (value == null) return '--°C';
    return '${value.toStringAsFixed(0)}°C';
  }

  static String _formatPercent(double? value) {
    if (value == null) return '--%';
    return '${value.toStringAsFixed(0)}%';
  }

  static String _formatVolt(double? value) {
    if (value == null) return '--.-V';
    return '${value.toStringAsFixed(1)}V';
  }
}
