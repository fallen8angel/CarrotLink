import 'package:carrot_pilot_manager/features/hud/domain/entities/hud_connectivity_state.dart';
import 'package:carrot_pilot_manager/features/hud/domain/entities/hud_device_metrics_state.dart';
import 'package:carrot_pilot_manager/features/hud/domain/entities/hud_drive_mode_state.dart';
import 'package:carrot_pilot_manager/features/hud/domain/entities/hud_gps_state.dart';
import 'package:carrot_pilot_manager/features/hud/domain/entities/hud_limit_state.dart';
import 'package:carrot_pilot_manager/features/hud/domain/entities/hud_signal_state.dart';
import 'package:carrot_pilot_manager/features/hud/domain/entities/hud_temp_control_state.dart';
import 'package:carrot_pilot_manager/features/hud/domain/entities/hud_visibility_state.dart';
import 'package:carrot_pilot_manager/features/hud/domain/entities/original_hud_snapshot.dart';
import 'package:carrot_pilot_manager/features/hud/presentation/models/hud_adaptive_display_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  OriginalHudSnapshot buildSnapshot({
    int? receivedAtMs,
    List<String> missingFields = const <String>[],
    List<String> staleReasons = const <String>[],
  }) {
    return OriginalHudSnapshot(
      tsMonoMs: 1234,
      source: HudSourceInfo(
        transport: 'sidecar_hud',
        deviceHost: '172.30.1.20',
        receivedAtMs: receivedAtMs,
      ),
      vehicle: const HudVehicleState(
        speedClusterKph: 80,
        setSpeedClusterKph: 100,
        gearText: 'D',
      ),
      tempControl: const HudTempControlState(mode: 'hidden'),
      driveMode: const HudDriveModeState(
        code: 0,
        nameOriginal: 'NORM',
        kind: 'normal',
      ),
      gap: const HudGapState(displayValue: 0, barCount: 0),
      limits: const HudLimitState(mode: 'hidden'),
      connectivity: const HudConnectivityState(),
      signals: const HudSignalState(),
      gps: const HudGpsState(hasFix: true, provider: 'external'),
      device: const HudDeviceMetricsState(
        cpuTempAvgC: 38,
        memUsagePct: 27,
        voltV: 4.9,
      ),
      visibility: const HudVisibilityState(showDeviceState: true),
      meta: HudMetaState(
        quality: 'semantic',
        missingFields: missingFields,
        staleReasons: staleReasons,
      ),
    );
  }

  group('HudAdaptiveDisplayModel compatibility hint', () {
    test('shows stale hint when snapshot stops updating', () {
      final staleSnapshot = buildSnapshot(
        receivedAtMs: DateTime.now()
                .subtract(const Duration(seconds: 5))
                .millisecondsSinceEpoch,
      );

      final model = HudAdaptiveDisplayModel.fromSnapshot(staleSnapshot);

      expect(model.showCompatibilityHint, isTrue);
      expect(model.compatibilityHint, '업데이트 지연');
      expect(model.compatibilityBadgeText, '지연');
    });

    test('shows vehicle wait hint when carState is missing', () {
      final snapshot = buildSnapshot(
        receivedAtMs: DateTime.now().millisecondsSinceEpoch,
        missingFields: const <String>['vehicle.carState'],
      );

      final model = HudAdaptiveDisplayModel.fromSnapshot(snapshot);

      expect(model.showCompatibilityHint, isTrue);
      expect(model.compatibilityHint, '차량 데이터 대기');
      expect(model.compatibilityBadgeText, '차량');
    });

    test('shows stale reason hint when sidecar reports device stall', () {
      final snapshot = buildSnapshot(
        receivedAtMs: DateTime.now().millisecondsSinceEpoch,
        staleReasons: const <String>['device.deviceState.stale'],
      );

      final model = HudAdaptiveDisplayModel.fromSnapshot(snapshot);

      expect(model.showCompatibilityHint, isTrue);
      expect(model.compatibilityHint, '기기 상태 지연');
      expect(model.compatibilityBadgeText, '기기');
    });
  });
}
