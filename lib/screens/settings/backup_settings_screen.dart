import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/ssh_service.dart';
import '../../services/backup_service.dart';
import '../../services/google_drive_service.dart';
import '../../widgets/custom_toast.dart';

class BackupSettingsScreen extends StatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  int _interval = 3;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _interval = prefs.getInt('backup_interval_minutes') ?? 3;
    });
  }

  Future<void> _saveSettings(int newValue) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('backup_interval_minutes', newValue);
    setState(() {
      _interval = newValue;
    });

    // Restart monitoring with new interval
    if (mounted) {
      final ssh = Provider.of<SSHService>(context, listen: false);
      final backupService = Provider.of<BackupService>(context, listen: false);
      final driveService =
          Provider.of<GoogleDriveService>(context, listen: false);
      backupService.startMonitoring(ssh, driveService);

      CustomToast.show(context, "설정이 저장되었습니다.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('백업 설정')),
      body: ListView(
        children: [
          ListTile(
            title: const Text("자동 백업 주기"),
            subtitle: Text("$_interval분 마다 변경 사항을 확인합니다."),
            trailing: DropdownButton<int>(
              value: _interval,
              items: const [
                DropdownMenuItem(value: 1, child: Text("1분")),
                DropdownMenuItem(value: 3, child: Text("3분")),
                DropdownMenuItem(value: 5, child: Text("5분")),
                DropdownMenuItem(value: 10, child: Text("10분")),
                DropdownMenuItem(value: 30, child: Text("30분")),
                DropdownMenuItem(value: 60, child: Text("1시간")),
              ],
              onChanged: (value) {
                if (value != null) {
                  _saveSettings(value);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
