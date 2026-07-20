import 'package:carrot_pilot_manager/services/phone_media_host_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('normalizes IPv4 endpoints', () {
    expect(
      PhoneMediaHostStore.normalizeHost(
        ' http://192.168.43.27:7000/phone/media ',
      ),
      '192.168.43.27',
    );
    expect(
      PhoneMediaHostStore.normalizeHost('10.0.0.31:7766'),
      '10.0.0.31',
    );
  });

  test('rejects invalid hosts', () {
    expect(PhoneMediaHostStore.normalizeHost(''), isNull);
    expect(PhoneMediaHostStore.normalizeHost('comma.local'), isNull);
    expect(PhoneMediaHostStore.normalizeHost('192.168.1.999'), isNull);
  });

  test('replaces the previous host with the latest discovery', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PhoneMediaHostStore.preferenceKey: '192.168.43.12',
    });

    expect(await PhoneMediaHostStore.remember('192.168.43.27:7000'), isTrue);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(PhoneMediaHostStore.preferenceKey),
      '192.168.43.27',
    );
  });
}
