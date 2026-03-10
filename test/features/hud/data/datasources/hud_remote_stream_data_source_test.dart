import 'package:carrot_pilot_manager/features/hud/data/datasources/hud_remote_stream_data_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default HUD stream candidates only target semantic HUD endpoints', () {
    const dataSource = HudRemoteStreamDataSource();

    expect(
      dataSource.candidates,
      const <({int port, String path})>[
        (port: 7767, path: '/ws/hud'),
        (port: 7766, path: '/ws/hud'),
      ],
    );
  });
}
