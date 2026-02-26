import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ko_KR', null);
  initializeService(); // Don't await to prevent app freeze on startup
  unawaited(StorageLayoutService.instance.ensureBaseFolders());
  
  // Listen for exit command from background service
  FlutterBackgroundService().on('exitApp').listen((event) {
    SystemNavigator.pop();
  });

  // Lock orientation to portrait up
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
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF6D00), // Carrot Orange
          brightness: Brightness.dark,
          surface: const Color(0xFF121212),
          surfaceContainer: const Color(0xFF1E1E1E),
        ),
        textTheme: GoogleFonts.notoSansTextTheme(
          ThemeData.dark().textTheme,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        // cardTheme removed to fix build error
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF2C2C2C),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFFF6D00), width: 2),
          ),
          contentPadding: const EdgeInsets.all(20),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF6D00),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            elevation: 0,
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xFF333333),
          contentTextStyle: const TextStyle(color: Colors.white),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
        navigationBarTheme: NavigationBarThemeData(
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          height: 80,
          indicatorColor: const Color(0xFFFF6D00).withOpacity(0.2),
          iconTheme: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.selected)) {
              return const IconThemeData(color: Color(0xFFFF6D00));
            }
            return const IconThemeData(color: Colors.grey);
          }),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}
