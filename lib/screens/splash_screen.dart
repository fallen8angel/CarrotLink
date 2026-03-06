import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';
import '../services/storage_layout_service.dart';
import 'dashboard_screen.dart';
import 'permission_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String _version = "";

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _checkFirstRun();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _version = "v${info.version}+${info.buildNumber}";
      });
    }
  }

  Future<void> _checkFirstRun() async {
    final prefs = await SharedPreferences.getInstance();
    final isFirstRun = prefs.getBool('is_first_run') ?? true;
    final hasRequiredPermissions = await _hasRequiredPermissions();
    final needsOnboarding = isFirstRun || !hasRequiredPermissions;

    // Always keep Flutter splash visible for a short minimum duration so
    // users can actually perceive the 2nd-stage splash screen.
    final splashMs = needsOnboarding ? 1500 : 450;
    await Future.delayed(Duration(milliseconds: splashMs));
    unawaited(StorageLayoutService.instance.ensureBaseFolders());

    if (mounted) {
      if (needsOnboarding) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const PermissionScreen()),
        );
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const DashboardScreen()),
        );
      }
    }
  }

  Future<bool> _hasRequiredPermissions() async {
    if (!Platform.isAndroid) return true;

    final notification = await Permission.notification.status;
    final battery = await Permission.ignoreBatteryOptimizations.status;
    final manageStorage = await Permission.manageExternalStorage.status;
    final legacyStorage = await Permission.storage.status;

    final storageGranted = manageStorage.isGranted || legacyStorage.isGranted;
    return notification.isGranted && battery.isGranted && storageGranted;
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final maxContentWidth = switch (window.windowClass) {
      UiWindowClass.compact => 340.0,
      UiWindowClass.medium => 420.0,
      UiWindowClass.expanded => 520.0,
      UiWindowClass.large => 580.0,
      UiWindowClass.extraLarge => 640.0,
    };
    final logoSize = (window.shortestSide * 0.22).clamp(88.0, 156.0).toDouble();
    final topGap = switch (window.windowClass) {
      UiWindowClass.compact => 14.0,
      UiWindowClass.medium => 16.0,
      _ => 18.0,
    };
    final titleGap = switch (window.windowClass) {
      UiWindowClass.compact => 18.0,
      UiWindowClass.medium => 20.0,
      _ => 22.0,
    };
    final versionGap = switch (window.windowClass) {
      UiWindowClass.compact => 6.0,
      UiWindowClass.medium => 8.0,
      _ => 10.0,
    };

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.screenPadding),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: topGap),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Logo
                      Image.asset(
                        'assets/icon.png',
                        width: logoSize,
                        height: logoSize,
                        errorBuilder: (context, error, stackTrace) {
                          return Icon(
                            Icons.directions_car,
                            size: logoSize,
                            color: const Color(0xFFFF6D00),
                          );
                        },
                      ),
                      SizedBox(height: titleGap),
                      // App Name
                      Text(
                        'CarrotLink',
                        textAlign: TextAlign.center,
                        style:
                            Theme.of(context).textTheme.headlineLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFFFF6D00),
                                ),
                      ),
                      SizedBox(height: versionGap),
                      // Version
                      Text(
                        _version,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.grey,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
