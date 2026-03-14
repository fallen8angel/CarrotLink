import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/update_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
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
      builder: (ctx) => const UpdateDialog(),
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
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hasUpdate = updateService.hasUpdateAvailable;
    final ignoredMessage = updateService.ignoredUpdateMessage;

    return Scaffold(
      appBar: AppBar(title: const Text('정보')),
      body: ListView(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.screenPadding.clamp(8.0, 20.0).toDouble(),
        ),
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
            subtitle: updateService.isChecking
                ? const Text('확인 중...')
                : hasUpdate
                    ? Text(
                        ignoredMessage == null
                            ? '새 버전: ${updateService.latestReleaseTag}'
                            : '새 버전: ${updateService.latestReleaseTag}\n$ignoredMessage',
                      )
                    : const Text('최신 버전입니다'),
            trailing: updateService.isChecking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : hasUpdate
                    ? FilledButton.tonalIcon(
                        onPressed: () => _showUpdateDialog(context),
                        icon: Icon(
                          updateService.downloadedFilePath != null
                              ? Icons.install_mobile
                              : Icons.system_update,
                        ),
                        label: Text(
                          updateService.downloadedFilePath != null
                              ? '설치'
                              : '업데이트',
                        ),
                      )
                    : const Icon(Icons.check_circle, color: Colors.green),
            onTap: () => _showUpdateDialog(context),
          ),
          const Divider(),
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.screenPadding.clamp(8.0, 16.0).toDouble(),
              10,
              tokens.screenPadding.clamp(8.0, 16.0).toDouble(),
              10,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '업데이트 채널',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  updateService.channel == 'stable'
                      ? 'Stable (안정 버전)'
                      : 'Dev (개발 버전)',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: window.isCompact ? 12.5 : 13,
                  ),
                ),
                const SizedBox(height: 10),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'stable', label: Text('Stable')),
                    ButtonSegment(value: 'dev', label: Text('Dev')),
                  ],
                  selected: {updateService.channel},
                  onSelectionChanged: (Set<String> selection) async {
                    await updateService.setChannel(selection.first);
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
