import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'dart:async';

import 'services/ssh_service.dart';
import 'screens/splash_screen.dart';
import 'services/macro_service.dart';
import 'services/google_drive_service.dart';
import 'services/backup_service.dart';
import 'services/background_service.dart';
import 'services/update_service.dart';
import 'services/diagnostics_service.dart';
import 'services/storage_layout_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ko_KR', null);
  initializeService(); // Don't await to prevent app freeze on startup
  unawaited(StorageLayoutService.instance.ensureBaseFolders());

  // Listen for exit command from background service
  FlutterBackgroundService().on('exitApp').listen((event) {
    SystemNavigator.pop();
  });

  // Keep app-wide orientation portrait-only.
  // Drive(HUD) screen temporarily enables landscape while active.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SSHService()),
        ChangeNotifierProvider(create: (_) => MacroService()),
        ChangeNotifierProvider(create: (_) => GoogleDriveService()),
        ChangeNotifierProvider(create: (_) => BackupService()),
        ChangeNotifierProvider(create: (_) => UpdateService()),
        ChangeNotifierProvider.value(value: DiagnosticsService.instance),
      ],
      child: const CarrotLinkApp(),
    ),
  );
}

class CarrotLinkApp extends StatelessWidget {
  const CarrotLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CarrotLink',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.darkTheme,
      home: const SplashScreen(),
    );
  }
}
