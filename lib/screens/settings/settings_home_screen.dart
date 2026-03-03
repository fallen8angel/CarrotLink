import 'package:flutter/material.dart';

import '../permission_screen.dart';
import '../diagnostics_screen.dart';
import 'connection_settings_screen.dart';
import 'hud_settings_screen.dart';
import 'info_settings_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('연결'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ConnectionSettingsScreen())),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('권한'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        const PermissionScreen(fromSettings: true))),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('HUD'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const HudSettingsScreen())),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('정보'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const InfoSettingsScreen())),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('진단 로그'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
          ),
        ],
      ),
    );
  }
}
