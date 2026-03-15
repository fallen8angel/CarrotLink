import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/developer_mode_service.dart';
import '../../services/update_service.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/update_dialog.dart';
import 'settings_subpage_components.dart';

class InfoSettingsScreen extends StatefulWidget {
  const InfoSettingsScreen({super.key});

  @override
  State<InfoSettingsScreen> createState() => _InfoSettingsScreenState();
}

class _InfoSettingsScreenState extends State<InfoSettingsScreen> {
  static const int _developerModeTapTarget = 5;

  int _developerModeTapCount = 0;
  DateTime? _lastDeveloperModeTapAt;

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
        title: const Text("CarrotLink"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("제작자"),
              subtitle: const Text("kooingh354"),
              onTap: _handleDeveloperModeTap,
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
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

  Future<void> _handleDeveloperModeTap() async {
    final developerMode = context.read<DeveloperModeService>();
    final now = DateTime.now();
    final last = _lastDeveloperModeTapAt;
    if (last == null || now.difference(last) > const Duration(seconds: 2)) {
      _developerModeTapCount = 0;
    }
    _lastDeveloperModeTapAt = now;
    _developerModeTapCount += 1;

    final remaining = _developerModeTapTarget - _developerModeTapCount;
    if (remaining > 0) {
      CustomToast.show(
        context,
        developerMode.enabled
            ? '개발자 모드 해제까지 $remaining회 남았습니다.'
            : '개발자 모드 활성화까지 $remaining회 남았습니다.',
      );
      return;
    }

    _developerModeTapCount = 0;
    final enabled = await developerMode.toggle();
    if (!mounted) return;
    CustomToast.show(
      context,
      enabled ? '개발자 모드를 활성화했습니다.' : '개발자 모드를 비활성화했습니다.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final updateService = context.watch<UpdateService>();
    final window = UiWindowInfo.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hasUpdate = updateService.hasUpdateAvailable;
    final ignoredMessage = updateService.ignoredUpdateMessage;

    return SettingsSubpageScaffold(
      title: '정보',
      maxWidth: switch (window.windowClass) {
        UiWindowClass.compact => 640.0,
        UiWindowClass.medium => 720.0,
        _ => 760.0,
      },
      children: [
        SettingsSection(
          title: '정보',
          showTopDivider: false,
          child: SettingsItemGroup(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('버전'),
                subtitle: Text(updateService.currentVersion.isEmpty
                    ? 'Loading...'
                    : updateService.currentVersion),
                onTap: () => _showAboutDialog(context),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('GitHub'),
                subtitle: const Text('당근파일럿'),
                onTap: () async {
                  final url =
                      Uri.parse('https://github.com/jominki354/CarrotLink');
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  }
                },
              ),
            ],
          ),
        ),
        SettingsSection(
          title: '업데이트',
          child: SettingsItemGroup(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
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
            ],
          ),
        ),
        SettingsSection(
          title: '업데이트 채널',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
    );
  }
}
