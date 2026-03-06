import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';
import '../services/storage_layout_service.dart';
import 'dashboard_screen.dart';

class PermissionScreen extends StatefulWidget {
  final bool fromSettings;

  const PermissionScreen({super.key, this.fromSettings = false});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  bool _notificationGranted = false;
  bool _batteryGranted = false;
  bool _storageGranted = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<bool> _isStoragePermissionGranted() async {
    if (!Platform.isAndroid) return true;

    final manageStatus = await Permission.manageExternalStorage.status;
    if (manageStatus.isGranted) return true;

    final legacyStatus = await Permission.storage.status;
    return legacyStatus.isGranted;
  }

  Future<void> _checkPermissions() async {
    final notificationStatus = await Permission.notification.status;
    final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
    final storageStatus = await _isStoragePermissionGranted();

    if (mounted) {
      setState(() {
        _notificationGranted = notificationStatus.isGranted;
        _batteryGranted = batteryStatus.isGranted;
        _storageGranted = storageStatus;
      });
    }
  }

  Future<void> _requestNotification() async {
    final status = await Permission.notification.request();
    if (mounted) {
      setState(() {
        _notificationGranted = status.isGranted;
      });
    }
  }

  Future<void> _requestBattery() async {
    final status = await Permission.ignoreBatteryOptimizations.request();
    if (mounted) {
      setState(() {
        _batteryGranted = status.isGranted;
      });
    }
  }

  Future<void> _requestStorage() async {
    if (!Platform.isAndroid) return;

    var granted = await _isStoragePermissionGranted();
    if (!granted) {
      final manageStatus = await Permission.manageExternalStorage.request();
      granted = manageStatus.isGranted;
    }
    if (!granted) {
      final legacyStatus = await Permission.storage.request();
      granted = legacyStatus.isGranted;
    }

    if (mounted) {
      setState(() {
        _storageGranted = granted;
      });
    }

    if (granted) {
      await StorageLayoutService.instance.ensureBaseFolders();
    }
  }

  Future<void> _finish() async {
    await StorageLayoutService.instance.ensureBaseFolders();

    if (!widget.fromSettings) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_first_run', false);

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const DashboardScreen()),
        );
      }
    } else {
      if (!mounted) return;
      Navigator.pop(context);
    }
  }

  int _requiredPermissionCount() {
    if (!Platform.isAndroid) return 0;
    return 3;
  }

  int _grantedPermissionCount() {
    if (!Platform.isAndroid) return 0;
    var count = 0;
    if (_notificationGranted) count++;
    if (_batteryGranted) count++;
    if (_storageGranted) count++;
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final media = MediaQuery.of(context);
    final tokens = UiLayoutTokens.of(context);
    final isLandscape = media.size.width > media.size.height;
    final isShortLandscape = isLandscape && media.size.height < 560;
    final maxContentWidth = switch (window.windowClass) {
      UiWindowClass.compact => isLandscape ? 760.0 : 560.0,
      UiWindowClass.medium => 640.0,
      UiWindowClass.expanded => 760.0,
      UiWindowClass.large => 840.0,
      UiWindowClass.extraLarge => 920.0,
    };
    final screenPadding = switch (window.windowClass) {
      UiWindowClass.compact => isShortLandscape ? 12.0 : 16.0,
      UiWindowClass.medium => 20.0,
      UiWindowClass.expanded => 24.0,
      UiWindowClass.large => 28.0,
      UiWindowClass.extraLarge => 32.0,
    };
    final headerIconSize = switch (window.windowClass) {
      UiWindowClass.compact => isShortLandscape ? 48.0 : 68.0,
      UiWindowClass.medium => 74.0,
      _ => 80.0,
    };

    return Scaffold(
      appBar: widget.fromSettings ? AppBar(title: const Text("권한 설정")) : null,
      bottomNavigationBar: _buildBottomActionBar(context, isShortLandscape),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, _) {
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxContentWidth),
                child: Scrollbar(
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    primary: true,
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: ClampingScrollPhysics(),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      screenPadding,
                      screenPadding,
                      screenPadding,
                      screenPadding + 16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!widget.fromSettings) ...[
                          if (isShortLandscape)
                            _buildCompactLandscapeHeader(
                                context, headerIconSize)
                          else
                            _buildDefaultHeader(
                                context, tokens, headerIconSize),
                          SizedBox(height: tokens.sectionGap + 6),
                        ],
                        _buildPermissionItem(
                          icon: Icons.notifications_active,
                          title: "알림 권한",
                          description: "백그라운드 서비스 상태를 표시하기 위해 필요합니다.",
                          isGranted: _notificationGranted,
                          onTap: _requestNotification,
                        ),
                        SizedBox(height: tokens.itemGap + 8),
                        _buildPermissionItem(
                          icon: Icons.battery_alert,
                          title: "배터리 최적화 제외",
                          description: "화면이 꺼져도 연결이 끊기지 않도록 합니다.",
                          isGranted: _batteryGranted,
                          onTap: _requestBattery,
                        ),
                        SizedBox(height: tokens.itemGap + 8),
                        _buildPermissionItem(
                          icon: Icons.folder_open,
                          title: "저장소 접근",
                          description: "SSH 키 백업/복원을 위해 필요합니다.",
                          isGranted: _storageGranted,
                          onTap: _requestStorage,
                        ),
                        SizedBox(height: tokens.itemGap),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildDefaultHeader(
    BuildContext context,
    UiLayoutTokens tokens,
    double headerIconSize,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: tokens.sectionGap + 14),
        Icon(
          Icons.security,
          size: headerIconSize,
          color: Theme.of(context).colorScheme.primary,
        ),
        SizedBox(height: tokens.sectionGap + 10),
        Text(
          "권한 설정",
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: tokens.itemGap + 8),
        Text(
          "안정적인 연결/백업을 위해 다음 권한을 확인해주세요.",
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          textAlign: TextAlign.center,
        ),
        if (Platform.isAndroid) ...[
          SizedBox(height: tokens.itemGap + 4),
          Text(
            "${_grantedPermissionCount()}/${_requiredPermissionCount()} 권한 허용됨",
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  Widget _buildCompactLandscapeHeader(BuildContext context, double iconSize) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.security, size: iconSize, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "권한 설정",
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  "권한을 허용하면 연결/백업이 안정적으로 동작합니다.",
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 6),
                  Text(
                    "${_grantedPermissionCount()}/${_requiredPermissionCount()} 권한 허용됨",
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActionBar(BuildContext context, bool isShortLandscape) {
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final padding = isShortLandscape ? 10.0 : 14.0;
    final horizontal = isShortLandscape ? 12.0 : 16.0;

    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(horizontal, padding, horizontal, padding),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.96),
          border: Border(
            top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.35)),
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton(
                onPressed: _finish,
                child: Text(widget.fromSettings ? "완료" : "시작하기"),
              ),
              if (!widget.fromSettings) ...[
                SizedBox(height: tokens.itemGap - 2),
                TextButton(
                  onPressed: _finish,
                  child: const Text(
                    "나중에 설정하기",
                    style: TextStyle(color: Colors.white60),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionItem({
    required IconData icon,
    required String title,
    required String description,
    required bool isGranted,
    required VoidCallback onTap,
  }) {
    final window = UiWindowInfo.of(context);
    final media = MediaQuery.of(context);
    final isShortLandscape =
        media.size.width > media.size.height && media.size.height < 560;
    final scheme = Theme.of(context).colorScheme;
    final titleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => isShortLandscape ? 14.0 : 15.0,
      UiWindowClass.medium => 16.0,
      _ => 17.0,
    };
    final descFontSize = switch (window.windowClass) {
      UiWindowClass.compact => isShortLandscape ? 11.5 : 12.0,
      UiWindowClass.medium => 12.5,
      _ => 13.0,
    };

    return Container(
      padding: EdgeInsets.all(isShortLandscape ? 12 : 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isGranted
              ? Colors.green.withValues(alpha: 0.5)
              : scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = window.isCompact ||
              constraints.maxWidth < 420 ||
              isShortLandscape;
          final allowButton = FilledButton.tonal(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              minimumSize: Size(68, isShortLandscape ? 34 : 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: const Text("허용"),
          );
          final statusIcon = Container(
            padding: EdgeInsets.all(isShortLandscape ? 8 : 10),
            decoration: BoxDecoration(
              color: isGranted
                  ? Colors.green.withValues(alpha: 0.1)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.65),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isGranted ? Icons.check : icon,
              color: isGranted ? Colors.green : scheme.onSurfaceVariant,
            ),
          );

          final descriptionBlock = Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: titleFontSize,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: descFontSize,
                  ),
                ),
              ],
            ),
          );

          if (!compact) {
            return Row(
              children: [
                statusIcon,
                const SizedBox(width: 16),
                descriptionBlock,
                if (!isGranted) allowButton,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  statusIcon,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: titleFontSize,
                                ),
                              ),
                            ),
                            if (!isGranted) allowButton,
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          description,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: descFontSize,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
