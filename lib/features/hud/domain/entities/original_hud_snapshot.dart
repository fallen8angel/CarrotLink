import 'hud_connectivity_state.dart';
import 'hud_device_metrics_state.dart';
import 'hud_drive_mode_state.dart';
import 'hud_gps_state.dart';
import 'hud_limit_state.dart';
import 'hud_signal_state.dart';
import 'hud_temp_control_state.dart';
import 'hud_visibility_state.dart';

class HudSourceInfo {
  final String transport;
  final String? deviceHost;

  const HudSourceInfo({
    this.transport = 'unknown',
    this.deviceHost,
  });

  static const empty = HudSourceInfo();

  HudSourceInfo copyWith({
    String? transport,
    String? deviceHost,
  }) {
    return HudSourceInfo(
      transport: transport ?? this.transport,
      deviceHost: deviceHost ?? this.deviceHost,
    );
  }
}

class HudVehicleState {
  final double? speedClusterKph;
  final double? setSpeedClusterKph;
  final double? speedClusterMps;
  final double? setSpeedClusterMps;
  final String gearText;
  final bool longActive;
  final bool latActive;

  const HudVehicleState({
    this.speedClusterKph,
    this.setSpeedClusterKph,
    this.speedClusterMps,
    this.setSpeedClusterMps,
    this.gearText = 'U',
    this.longActive = false,
    this.latActive = false,
  });

  static const empty = HudVehicleState();

  HudVehicleState copyWith({
    double? speedClusterKph,
    double? setSpeedClusterKph,
    double? speedClusterMps,
    double? setSpeedClusterMps,
    String? gearText,
    bool? longActive,
    bool? latActive,
  }) {
    return HudVehicleState(
      speedClusterKph: speedClusterKph ?? this.speedClusterKph,
      setSpeedClusterKph: setSpeedClusterKph ?? this.setSpeedClusterKph,
      speedClusterMps: speedClusterMps ?? this.speedClusterMps,
      setSpeedClusterMps: setSpeedClusterMps ?? this.setSpeedClusterMps,
      gearText: gearText ?? this.gearText,
      longActive: longActive ?? this.longActive,
      latActive: latActive ?? this.latActive,
    );
  }
}

class HudGapState {
  final int? personalityRaw;
  final int displayValue;
  final int barCount;

  const HudGapState({
    this.personalityRaw,
    this.displayValue = 0,
    this.barCount = 0,
  });

  static const empty = HudGapState();

  HudGapState copyWith({
    int? personalityRaw,
    int? displayValue,
    int? barCount,
  }) {
    return HudGapState(
      personalityRaw: personalityRaw ?? this.personalityRaw,
      displayValue: displayValue ?? this.displayValue,
      barCount: barCount ?? this.barCount,
    );
  }
}

class HudMetaState {
  final bool isPreview;
  final bool isFallbackMetricsApplied;
  final List<String> missingFields;
  final String quality;

  const HudMetaState({
    this.isPreview = false,
    this.isFallbackMetricsApplied = false,
    this.missingFields = const <String>[],
    this.quality = 'live',
  });

  static const empty = HudMetaState();

  HudMetaState copyWith({
    bool? isPreview,
    bool? isFallbackMetricsApplied,
    List<String>? missingFields,
    String? quality,
  }) {
    return HudMetaState(
      isPreview: isPreview ?? this.isPreview,
      isFallbackMetricsApplied:
          isFallbackMetricsApplied ?? this.isFallbackMetricsApplied,
      missingFields: missingFields ?? this.missingFields,
      quality: quality ?? this.quality,
    );
  }
}

class OriginalHudSnapshot {
  final int version;
  final int tsMonoMs;
  final HudSourceInfo source;
  final HudVehicleState vehicle;
  final HudTempControlState tempControl;
  final HudDriveModeState driveMode;
  final HudGapState gap;
  final HudLimitState limits;
  final HudConnectivityState connectivity;
  final HudSignalState signals;
  final HudGpsState gps;
  final HudDeviceMetricsState device;
  final HudVisibilityState visibility;
  final HudMetaState meta;

  const OriginalHudSnapshot({
    this.version = 1,
    this.tsMonoMs = 0,
    this.source = HudSourceInfo.empty,
    this.vehicle = HudVehicleState.empty,
    this.tempControl = HudTempControlState.empty,
    this.driveMode = HudDriveModeState.empty,
    this.gap = HudGapState.empty,
    this.limits = HudLimitState.empty,
    this.connectivity = HudConnectivityState.empty,
    this.signals = HudSignalState.empty,
    this.gps = HudGpsState.empty,
    this.device = HudDeviceMetricsState.empty,
    this.visibility = HudVisibilityState.empty,
    this.meta = HudMetaState.empty,
  });

  static const empty = OriginalHudSnapshot();

  OriginalHudSnapshot copyWith({
    int? version,
    int? tsMonoMs,
    HudSourceInfo? source,
    HudVehicleState? vehicle,
    HudTempControlState? tempControl,
    HudDriveModeState? driveMode,
    HudGapState? gap,
    HudLimitState? limits,
    HudConnectivityState? connectivity,
    HudSignalState? signals,
    HudGpsState? gps,
    HudDeviceMetricsState? device,
    HudVisibilityState? visibility,
    HudMetaState? meta,
  }) {
    return OriginalHudSnapshot(
      version: version ?? this.version,
      tsMonoMs: tsMonoMs ?? this.tsMonoMs,
      source: source ?? this.source,
      vehicle: vehicle ?? this.vehicle,
      tempControl: tempControl ?? this.tempControl,
      driveMode: driveMode ?? this.driveMode,
      gap: gap ?? this.gap,
      limits: limits ?? this.limits,
      connectivity: connectivity ?? this.connectivity,
      signals: signals ?? this.signals,
      gps: gps ?? this.gps,
      device: device ?? this.device,
      visibility: visibility ?? this.visibility,
      meta: meta ?? this.meta,
    );
  }
}
