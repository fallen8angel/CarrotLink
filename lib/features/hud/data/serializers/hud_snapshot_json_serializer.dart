import 'dart:convert';

import '../../domain/entities/original_hud_snapshot.dart';

class HudSnapshotJsonSerializer {
  const HudSnapshotJsonSerializer._();

  static String encode(OriginalHudSnapshot snapshot) {
    return jsonEncode(toMap(snapshot));
  }

  static Map<String, dynamic> toMap(OriginalHudSnapshot snapshot) {
    return <String, dynamic>{
      'version': snapshot.version,
      'tsMonoMs': snapshot.tsMonoMs,
      'source': _compact(<String, dynamic>{
        'transport': snapshot.source.transport,
        'deviceHost': snapshot.source.deviceHost,
      }),
      'vehicle': _compact(<String, dynamic>{
        'speedClusterKph': snapshot.vehicle.speedClusterKph,
        'setSpeedClusterKph': snapshot.vehicle.setSpeedClusterKph,
        'speedClusterMps': snapshot.vehicle.speedClusterMps,
        'setSpeedClusterMps': snapshot.vehicle.setSpeedClusterMps,
        'gearText': snapshot.vehicle.gearText,
        'longActive': snapshot.vehicle.longActive,
        'latActive': snapshot.vehicle.latActive,
      }),
      'tempControl': _compact(<String, dynamic>{
        'mode': snapshot.tempControl.mode,
        'label': snapshot.tempControl.label,
        'speedKph': snapshot.tempControl.speedKph,
        'sourceRaw': snapshot.tempControl.sourceRaw,
        'applySpeedKph': snapshot.tempControl.applySpeedKph,
        'cruiseTargetKph': snapshot.tempControl.cruiseTargetKph,
        'isDecel': snapshot.tempControl.isDecel,
      }),
      'driveMode': _compact(<String, dynamic>{
        'code': snapshot.driveMode.code,
        'nameOriginal': snapshot.driveMode.nameOriginal,
        'kind': snapshot.driveMode.kind,
      }),
      'gap': _compact(<String, dynamic>{
        'personalityRaw': snapshot.gap.personalityRaw,
        'displayValue': snapshot.gap.displayValue,
        'barCount': snapshot.gap.barCount,
      }),
      'limits': _compact(<String, dynamic>{
        'mode': snapshot.limits.mode,
        'label': snapshot.limits.label,
        'displaySpeedKph': snapshot.limits.displaySpeedKph,
        'roadLimitSpeedKph': snapshot.limits.roadLimitSpeedKph,
        'cameraLimitSpeedKph': snapshot.limits.cameraLimitSpeedKph,
        'cameraSignType': snapshot.limits.cameraSignType,
        'isOverLimit': snapshot.limits.isOverLimit,
        'shouldBlink': snapshot.limits.shouldBlink,
      }),
      'connectivity': _compact(<String, dynamic>{
        'activeCarrot': snapshot.connectivity.activeCarrot,
        'badgeMode': snapshot.connectivity.badgeMode,
        'badgeLabel': snapshot.connectivity.badgeLabel,
      }),
      'signals': _compact(<String, dynamic>{
        'trafficStateLp': snapshot.signals.trafficStateLp,
        'trafficStateCarrot': snapshot.signals.trafficStateCarrot,
        'visualState': snapshot.signals.visualState,
        'redDot': snapshot.signals.redDot,
      }),
      'gps': _compact(<String, dynamic>{
        'hasFix': snapshot.gps.hasFix,
        'provider': snapshot.gps.provider,
      }),
      'device': _compact(<String, dynamic>{
        'cpuTempAvgC': snapshot.device.cpuTempAvgC,
        'cpuTempMaxC': snapshot.device.cpuTempMaxC,
        'memUsagePct': snapshot.device.memUsagePct,
        'diskUsedPct': snapshot.device.diskUsedPct,
        'freeSpacePct': snapshot.device.freeSpacePct,
        'voltV': snapshot.device.voltV,
        'metricPrimaryMode': snapshot.device.metricPrimaryMode,
      }),
      'visibility': _compact(<String, dynamic>{
        'showDeviceState': snapshot.visibility.showDeviceState,
        'showDateTimeMode': snapshot.visibility.showDateTimeMode,
      }),
      'meta': _compact(<String, dynamic>{
        'isPreview': snapshot.meta.isPreview,
        'isFallbackMetricsApplied': snapshot.meta.isFallbackMetricsApplied,
        'missingFields': snapshot.meta.missingFields,
        'quality': snapshot.meta.quality,
      }),
    };
  }

  static Map<String, dynamic> _compact(Map<String, dynamic> source) {
    source.removeWhere((key, value) => value == null);
    return source;
  }
}
