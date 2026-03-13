import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:carrot_pilot_manager/main.dart';
import 'package:carrot_pilot_manager/screens/splash_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const permissionChannel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );

  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'is_first_run': false,
    });
    PackageInfo.setMockInitialValues(
      appName: 'CarrotLink',
      packageName: 'com.example.carrot_pilot_manager',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (call) async {
          switch (call.method) {
            case 'checkPermissionStatus':
              return 1;
            case 'requestPermissions':
              return <int, int>{};
            default:
              return null;
          }
        });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
  });

  testWidgets('App starts without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(
      CarrotLinkApp(startupWarmup: Future<void>.value()),
    );

    expect(find.byType(SplashScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 250));
  });
}
