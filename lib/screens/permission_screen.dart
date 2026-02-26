import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    return Scaffold(
      appBar: widget.fromSettings 
          ? AppBar(title: const Text("권한 설정")) 
          : null,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.fromSettings) ...[
                const SizedBox(height: 40),
                const Icon(Icons.security, size: 80, color: Color(0xFFFF6D00)),
                const SizedBox(height: 24),
                Text(
                  "권한 설정",
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  "안정적인 연결/백업을 위해\n다음 권한을 확인해주세요.",
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 12),
                  Text(
                    "${_grantedPermissionCount()}/${_requiredPermissionCount()} 권한 허용됨",
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[500],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 40),
              ],
              
              _buildPermissionItem(
                icon: Icons.notifications_active,
                title: "알림 권한",
                description: "백그라운드 서비스 상태를 표시하기 위해 필요합니다.",
                isGranted: _notificationGranted,
                onTap: _requestNotification,
              ),
              const SizedBox(height: 16),
              _buildPermissionItem(
                icon: Icons.battery_alert,
                title: "배터리 최적화 제외",
                description: "화면이 꺼져도 연결이 끊기지 않도록 합니다.",
                isGranted: _batteryGranted,
                onTap: _requestBattery,
              ),
              const SizedBox(height: 16),
              _buildPermissionItem(
                icon: Icons.folder_open,
                title: "저장소 접근",
                description: "SSH 키 백업/복원을 위해 필요합니다.",
                isGranted: _storageGranted,
                onTap: _requestStorage,
              ),

              const Spacer(),
              
              ElevatedButton(
                onPressed: _finish,
                child: Text(widget.fromSettings ? "완료" : "시작하기"),
              ),
              if (!widget.fromSettings)
                TextButton(
                  onPressed: _finish,
                  child: const Text("나중에 설정하기", style: TextStyle(color: Colors.grey)),
                ),
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: isGranted 
            ? Border.all(color: Colors.green.withOpacity(0.5)) 
            : null,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isGranted ? Colors.green.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isGranted ? Icons.check : icon,
              color: isGranted ? Colors.green : Colors.grey,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
              ],
            ),
          ),
          if (!isGranted)
            TextButton(
              onPressed: onTap,
              child: const Text("허용"),
            ),
        ],
      ),
    );
  }
}
