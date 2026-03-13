import 'package:carrot_pilot_manager/features/hud/data/mappers/hud_remote_payload_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HudRemotePayloadMapper legacy speed mapping', () {
    test('converts vEgo mps to speedClusterKph when vEgoKph is absent', () {
      final mapper = HudRemotePayloadMapper();

      final snapshot = mapper.map(
        raw: <String, dynamic>{
          'vEgo': 25.0,
          'vSetKph': 90.0,
          'gear': 'D',
        },
        host: '127.0.0.1',
      );

      expect(snapshot.source.transport, 'legacy_ws_carstate');
      expect(snapshot.vehicle.speedClusterKph, 90.0);
      expect(snapshot.vehicle.speedClusterMps, closeTo(25.0, 1e-9));
    });

    test('prefers explicit vEgoKph over converted vEgo fallback', () {
      final mapper = HudRemotePayloadMapper();

      final snapshot = mapper.map(
        raw: <String, dynamic>{
          'vEgo': 25.0,
          'vEgoKph': 88.0,
          'vSetKph': 100.0,
        },
        host: '127.0.0.1',
      );

      expect(snapshot.vehicle.speedClusterKph, 88.0);
      expect(snapshot.vehicle.speedClusterMps, closeTo(88.0 / 3.6, 1e-9));
    });

    test('prefers vEgoCluster over raw vEgo when both exist', () {
      final mapper = HudRemotePayloadMapper();

      final snapshot = mapper.map(
        raw: <String, dynamic>{
          'vEgo': 25.0,
          'vEgoCluster': 23.5,
          'vSetKph': 90.0,
        },
        host: '127.0.0.1',
      );

      expect(snapshot.vehicle.speedClusterKph, closeTo(84.6, 1e-9));
      expect(snapshot.vehicle.speedClusterMps, closeTo(23.5, 1e-9));
    });
  });
}
