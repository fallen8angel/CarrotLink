import 'package:flutter/material.dart';
import '../../ui/adaptive/layout_tokens.dart';

class BackupSettingsScreen extends StatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final tokens = UiLayoutTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('백업 설정')),
      body: ListView(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.screenPadding.clamp(8.0, 20.0).toDouble(),
        ),
        children: const [
          ListTile(
            title: Text("자동 백업 주기"),
            subtitle: Text("로컬 백업은 마지막 백업 시점 기준 1시간마다 저장됩니다."),
            trailing: Text("1시간 고정"),
          ),
        ],
      ),
    );
  }
}
