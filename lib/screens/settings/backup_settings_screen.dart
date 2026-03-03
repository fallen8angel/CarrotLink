import 'package:flutter/material.dart';

class BackupSettingsScreen extends StatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('백업 설정')),
      body: ListView(
        children: [
          ListTile(
            title: const Text("자동 백업 주기"),
            subtitle: const Text("로컬 백업은 마지막 백업 시점 기준 1시간마다 저장됩니다."),
            trailing: const Text("1시간 고정"),
          ),
        ],
      ),
    );
  }
}
