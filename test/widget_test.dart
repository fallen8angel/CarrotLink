// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:carrot_pilot_manager/main.dart';
import 'package:carrot_pilot_manager/screens/splash_screen.dart';

void main() {
  testWidgets('App starts without crashing', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const CarrotLinkApp());

    // Verify that SplashScreen is shown initially
    expect(find.byType(SplashScreen), findsOneWidget);

    // Wait for any async operations
    await tester.pumpAndSettle();
  });
}
