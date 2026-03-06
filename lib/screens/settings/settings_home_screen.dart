import 'package:flutter/material.dart';
import '../../ui/adaptive/layout_tokens.dart';

import '../permission_screen.dart';
import '../diagnostics_screen.dart';
import 'connection_settings_screen.dart';
import 'hud_settings_screen.dart';
import 'info_settings_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final horizontalPadding = tokens.screenPadding.clamp(8.0, 20.0).toDouble();
    ListTile navTile({
      required IconData icon,
      required String title,
      required VoidCallback onTap,
    }) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        onTap: onTap,
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        children: [
          navTile(
            icon: Icons.link,
            title: '연결',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ConnectionSettingsScreen())),
          ),
          const Divider(),
          navTile(
            icon: Icons.security,
            title: '권한',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        const PermissionScreen(fromSettings: true))),
          ),
          const Divider(),
          navTile(
            icon: Icons.hub_outlined,
            title: 'HUD',
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const HudSettingsScreen())),
          ),
          const Divider(),
          navTile(
            icon: Icons.info_outline,
            title: '정보',
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const InfoSettingsScreen())),
          ),
          const Divider(),
          navTile(
            icon: Icons.bug_report_outlined,
            title: '진단 로그',
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
          ),
        ],
      ),
    );
  }
}
