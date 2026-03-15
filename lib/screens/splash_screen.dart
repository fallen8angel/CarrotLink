import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/diagnostics_service.dart';
import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';
import 'dashboard_screen.dart';
import 'permission_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.startupWarmup,
  });

  final Future<void> startupWarmup;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String _version = "";
  String _status = '초기화 중...';
  final DiagnosticsService _diag = DiagnosticsService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_watchStartupWarmup());
    _loadVersion();
    unawaited(_checkFirstRun());
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 2),
      );
      if (mounted) {
        setState(() {
          _version = "v${info.version}+${info.buildNumber}";
        });
      }
    } catch (e) {
      _diag.warn('startup', 'PackageInfo load failed: $e');
    }
  }

  Future<void> _checkFirstRun() async {
    final stopwatch = Stopwatch()..start();
    _setStatus('실행 준비 확인 중...');
    try {
      final prefsFuture = SharedPreferences.getInstance().timeout(
        const Duration(seconds: 2),
      );
      final permissionsFuture = _hasRequiredPermissions().timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
      final prefs = await prefsFuture;
      final isFirstRun = prefs.getBool('is_first_run') ?? true;
      final hasRequiredPermissions = await permissionsFuture;
      final needsOnboarding = isFirstRun || !hasRequiredPermissions;

      _diag.info(
        'startup',
        'Splash checks done in ${stopwatch.elapsedMilliseconds}ms '
            'firstRun=$isFirstRun permissions=$hasRequiredPermissions',
      );
      _setStatus(needsOnboarding ? '권한 확인 화면으로 이동 중...' : '대시보드로 이동 중...');

      final splashMs = needsOnboarding ? 900 : 60;
      await Future.delayed(Duration(milliseconds: splashMs));
      _navigateFromSplash(needsOnboarding: needsOnboarding);
    } catch (e, st) {
      _diag.error(
        'startup',
        'Splash bootstrap failed after ${stopwatch.elapsedMilliseconds}ms: $e',
      );
      debugPrintStack(stackTrace: st);
      _setStatus('초기화 확인 실패, 대시보드로 이동 중...');
      await Future.delayed(const Duration(milliseconds: 120));
      _navigateFromSplash(needsOnboarding: false);
    }
  }

  Future<bool> _hasRequiredPermissions() async {
    if (!Platform.isAndroid) return true;

    final results = await Future.wait<PermissionStatus>([
      Permission.notification.status,
      Permission.ignoreBatteryOptimizations.status,
      Permission.manageExternalStorage.status,
      Permission.storage.status,
    ]);
    final notification = results[0];
    final battery = results[1];
    final manageStorage = results[2];
    final legacyStorage = results[3];

    final storageGranted = manageStorage.isGranted || legacyStorage.isGranted;
    return notification.isGranted && battery.isGranted && storageGranted;
  }

  Future<void> _watchStartupWarmup() async {
    final stopwatch = Stopwatch()..start();
    try {
      await widget.startupWarmup.timeout(
        const Duration(seconds: 5),
      );
      _diag.info(
        'startup',
        'Background warmup finished in ${stopwatch.elapsedMilliseconds}ms',
      );
    } catch (e) {
      _diag.warn(
        'startup',
        'Background warmup timeout/failure after ${stopwatch.elapsedMilliseconds}ms: $e',
      );
    }
  }

  void _navigateFromSplash({required bool needsOnboarding}) {
    if (!mounted) return;
    final route = MaterialPageRoute(
      builder: (context) =>
          needsOnboarding ? const PermissionScreen() : const DashboardScreen(),
    );
    Navigator.of(context).pushReplacement(route);
  }

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() {
      _status = value;
    });
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
                      const SizedBox(height: 10),
                      Text(
                        _status,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey[500],
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
