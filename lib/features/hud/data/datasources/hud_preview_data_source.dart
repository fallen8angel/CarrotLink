import 'dart:async';
import 'dart:math' as math;

import '../../domain/entities/hud_connectivity_state.dart';
import '../../domain/entities/hud_device_metrics_state.dart';
import '../../domain/entities/hud_drive_mode_state.dart';
import '../../domain/entities/hud_gps_state.dart';
import '../../domain/entities/hud_limit_state.dart';
import '../../domain/entities/hud_signal_state.dart';
import '../../domain/entities/hud_temp_control_state.dart';
import '../../domain/entities/hud_visibility_state.dart';
import '../../domain/entities/original_hud_snapshot.dart';

class HudPreviewDataSource {
  HudPreviewDataSource({
    Stopwatch? clock,
    this.tickInterval = const Duration(milliseconds: 240),
  }) : _clock = clock ?? (Stopwatch()..start());

  final Stopwatch _clock;
  final Duration tickInterval;

  Stream<OriginalHudSnapshot> watch() {
    return Stream<OriginalHudSnapshot>.periodic(tickInterval, _buildSnapshot)
        .asBroadcastStream();
  }

  OriginalHudSnapshot _buildSnapshot(int tick) {
    final phase = tick / 10.0;
    final egoKph = 34.0 + (math.sin(phase) * 6.0);
    const setKph = 80.0;
    final applyKph = 83.0 + (math.sin(phase / 2.0) * 2.0);
    final cpu = 74.0 + (math.sin(phase / 3.0) * 3.0);
    final mem = 63.0 + (math.cos(phase / 4.0) * 4.0);
    final disk = 64.0 + (math.sin(phase / 5.0) * 1.8);
    final volt = 12.7 + (math.sin(phase / 8.0) * 0.15);
    final signalPhase = tick % 48;
    final signalState = signalPhase < 7
        ? 'red'
        : (signalPhase >= 28 && signalPhase < 35 ? 'green' : 'off');

    return OriginalHudSnapshot(
      tsMonoMs: _clock.elapsedMilliseconds,
      source: const HudSourceInfo(
        transport: 'preview',
      ),
      vehicle: HudVehicleState(
        speedClusterKph: egoKph,
        setSpeedClusterKph: setKph,
        speedClusterMps: egoKph / 3.6,
        setSpeedClusterMps: setKph / 3.6,
        gearText: 'D',
        longActive: true,
        latActive: true,
      ),
      tempControl: HudTempControlState(
        mode: 'apply',
        label: 'eco',
        speedKph: applyKph,
        sourceRaw: 'eco',
        applySpeedKph: applyKph,
        cruiseTargetKph: setKph,
      ),
      driveMode: const HudDriveModeState(
        code: 1,
        nameOriginal: 'ECO',
        kind: 'eco',
      ),
      gap: const HudGapState(
        personalityRaw: 1,
        displayValue: 2,
        barCount: 2,
      ),
      limits: const HudLimitState(
        mode: 'limit',
        label: 'LIMIT',
        displaySpeedKph: 70,
        roadLimitSpeedKph: 70,
      ),
      connectivity: const HudConnectivityState(
        activeCarrot: 2,
        badgeMode: 'apn',
        badgeLabel: 'APN',
      ),
      signals: HudSignalState(
        trafficStateLp: signalState == 'red'
            ? 1
            : (signalState == 'green' ? 3 : 0),
        trafficStateCarrot: signalState == 'red'
            ? 1
            : (signalState == 'green' ? 3 : 0),
        visualState: signalState,
        redDot: signalState == 'red',
      ),
      gps: const HudGpsState(
        hasFix: true,
        provider: 'preview',
      ),
      device: HudDeviceMetricsState(
        cpuTempAvgC: cpu,
        cpuTempMaxC: cpu + 2.4,
        memUsagePct: mem,
        diskUsedPct: disk,
        freeSpacePct: 100.0 - disk,
        voltV: volt,
        metricPrimaryMode: tick % 24 < 12 ? 'volt' : 'disk',
      ),
      visibility: const HudVisibilityState(
        showDeviceState: true,
        showDateTimeMode: 1,
      ),
      meta: const HudMetaState(
        isPreview: true,
        quality: 'preview',
      ),
    );
  }
}
