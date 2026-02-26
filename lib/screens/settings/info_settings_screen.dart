import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/update_service.dart';
import '../../widgets/update_dialog.dart';

class InfoSettingsScreen extends StatefulWidget {
  const InfoSettingsScreen({super.key});

  @override
  State<InfoSettingsScreen> createState() => _InfoSettingsScreenState();
}

class _InfoSettingsScreenState extends State<InfoSettingsScreen> {
  void _showUpdateDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => UpdateDialog(),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.orange),
            SizedBox(width: 8),
            Text("CarrotLink"),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.person, color: Colors.blue),
              title: Text("제작자"),
              subtitle: Text("kooingh354"),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.discord, color: Colors.indigo),
              title: Text("Discord"),
              subtitle: Text("kooingh354"),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("확인"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final updateService = context.watch<UpdateService>();

    return Scaffold(
      appBar: AppBar(title: const Text('정보')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('버전'),
            subtitle: Text(updateService.currentVersion.isEmpty
                ? 'Loading...'
                : updateService.currentVersion),
            onTap: () => _showAboutDialog(context),
          ),
          ListTile(
            title: const Text('GitHub'),
            subtitle: const Text('당근파일럿'),
            onTap: () async {
              final url = Uri.parse('https://github.com/jominki354/CarrotLink');
              if (await canLaunchUrl(url)) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
          ),
          ListTile(
            title: const Text('업데이트 확인'),
            subtitle: updateService.latestRelease != null
                ? Text('새 버전: ${updateService.latestRelease!['tag_name']}')
                : const Text('최신 버전입니다'),
            trailing: updateService.latestRelease != null
                ? const Icon(Icons.system_update, color: Colors.orange)
                : const Icon(Icons.check_circle, color: Colors.green),
            onTap: () => _showUpdateDialog(context),
          ),
          const Divider(),
          ListTile(
            title: const Text('업데이트 채널'),
            subtitle: Text(updateService.channel == 'stable'
                ? 'Stable (안정 버전)'
                : 'Dev (개발 버전)'),
            trailing: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'stable', label: Text('Stable')),
                ButtonSegment(value: 'dev', label: Text('Dev')),
              ],
              selected: {updateService.channel},
              onSelectionChanged: (Set<String> selection) {
                updateService.setChannel(selection.first);
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
