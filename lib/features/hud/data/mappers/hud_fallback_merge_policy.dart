import '../../domain/entities/original_hud_snapshot.dart';
import '../models/hud_fallback_metrics_sample.dart';

class HudFallbackMergePolicy {
  const HudFallbackMergePolicy();

  OriginalHudSnapshot merge({
    required OriginalHudSnapshot primary,
    required HudFallbackMetricsSample? fallback,
  }) {
    if (fallback == null) {
      return primary;
    }

    var applied = false;
    var nextDevice = primary.device;
    final remainingMissing = primary.meta.missingFields.toSet();

    if (nextDevice.cpuTempAvgC == null && fallback.cpuTempC != null) {
      nextDevice = nextDevice.copyWith(cpuTempAvgC: fallback.cpuTempC);
      applied = true;
      remainingMissing.remove('device.cpuTempAvgC');
    }
    if (nextDevice.cpuTempMaxC == null && fallback.cpuTempC != null) {
      nextDevice = nextDevice.copyWith(cpuTempMaxC: fallback.cpuTempC);
      applied = true;
      remainingMissing.remove('device.cpuTempMaxC');
    }
    if (nextDevice.memUsagePct == null && fallback.memPct != null) {
      nextDevice = nextDevice.copyWith(memUsagePct: fallback.memPct);
      applied = true;
      remainingMissing.remove('device.memUsagePct');
    }
    if (nextDevice.diskUsedPct == null && fallback.diskPct != null) {
      nextDevice = nextDevice.copyWith(
        diskUsedPct: fallback.diskPct,
        metricPrimaryMode:
            nextDevice.voltV == null ? 'disk' : nextDevice.metricPrimaryMode,
      );
      applied = true;
      remainingMissing.remove('device.diskUsedPct');
    }

    if (!applied) {
      return primary;
    }

    return primary.copyWith(
      device: nextDevice,
      meta: primary.meta.copyWith(
        isFallbackMetricsApplied: true,
        quality: primary.meta.isPreview ? 'preview' : 'degraded',
        missingFields: remainingMissing.toList()..sort(),
      ),
    );
  }
}
