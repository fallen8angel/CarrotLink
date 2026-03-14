import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'dart:async';

import 'services/ssh_service.dart';
import 'screens/splash_screen.dart';
import 'services/macro_service.dart';
import 'services/google_drive_service.dart';
import 'services/backup_service.dart';
import 'services/update_service.dart';
import 'services/diagnostics_service.dart';
import 'services/hud_feature_settings_service.dart';
import 'services/storage_layout_service.dart';
import 'features/hud/hud.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final startupWarmup = _runStartupWarmup();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SSHService()),
        ChangeNotifierProvider(create: (_) => HudFeatureSettingsService()),
        ChangeNotifierProxyProvider2<SSHService, HudFeatureSettingsService,
            SharedRuntimeManager>(
          create: (_) => SharedRuntimeManager(),
          update: (_, ssh, featureSettings, manager) {
            final runtime = manager ?? SharedRuntimeManager();
            runtime.attachSshService(ssh);
            runtime.attachFeatureSettings(featureSettings);
            return runtime;
          },
        ),
        ChangeNotifierProvider(create: (_) => MacroService()),
        ChangeNotifierProvider(create: (_) => GoogleDriveService()),
        ChangeNotifierProvider(create: (_) => BackupService()),
        ChangeNotifierProvider(create: (_) => UpdateService()),
        ChangeNotifierProvider.value(value: DiagnosticsService.instance),
      ],
      child: CarrotLinkApp(startupWarmup: startupWarmup),
    ),
  );
}

Future<void> _runStartupWarmup() async {
  // Yield first so the Android launch screen can hand off to Flutter ASAP.
  await Future<void>.delayed(Duration.zero);
  await _runStartupStep(
    'intl',
    () => initializeDateFormatting('ko_KR', null),
  );
  await _runStartupStep(
    'orientation',
    () => SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]),
  );
  await _runStartupStep(
    'storage_layout',
    () => StorageLayoutService.instance.ensureBaseFolders(),
  );
}

Future<void> _runStartupStep(
  String label,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e, st) {
    debugPrint('[Startup] $label failed: $e');
    debugPrint('$st');
  }
}

class CarrotLinkApp extends StatelessWidget {
  const CarrotLinkApp({
    super.key,
    required this.startupWarmup,
  });

  final Future<void> startupWarmup;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CarrotLink',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.darkTheme,
      home: SplashScreen(startupWarmup: startupWarmup),
    );
  }
}
