import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/developer_mode_service.dart';
import '../services/diagnostics_service.dart';
import '../ui/adaptive/window_class.dart';
import '../widgets/custom_toast.dart';
import 'settings/settings_subpage_components.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final developerMode = context.watch<DeveloperModeService>();
    final window = UiWindowInfo.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (!developerMode.enabled) {
      return const SettingsSubpageScaffold(
        title: '진단 로그',
        children: [
          SettingsSection(
            title: '상태',
            showTopDivider: false,
            child: SettingsStatusNote(text: '개발자 모드가 비활성화되어 있습니다.'),
          ),
        ],
      );
    }
    return SettingsSubpageScaffold(
      title: '진단 로그',
      actions: [
        IconButton(
          onPressed: () async {
            final text = context.read<DiagnosticsService>().exportText();
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              CustomToast.show(context, '진단 로그를 복사했습니다.');
            }
          },
          icon: const Icon(Icons.copy_all),
          tooltip: '전체 복사',
        ),
        IconButton(
          onPressed: () => context.read<DiagnosticsService>().clear(),
          icon: const Icon(Icons.delete_sweep),
          tooltip: '로그 지우기',
        ),
      ],
      children: [
        Consumer<DiagnosticsService>(
          builder: (context, diagnostics, _) {
            final entries = diagnostics.entries;
            if (entries.isEmpty) {
              return const SettingsSection(
                title: '로그',
                showTopDivider: false,
                child: SettingsStatusNote(text: '로그가 없습니다.'),
              );
            }

            return SettingsSection(
              title: '로그',
              showTopDivider: false,
              child: SettingsItemGroup(
                children: [
                  for (final e in entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${e.timestamp.toLocal()}  [${e.level}]  ${e.category}',
                        style: TextStyle(
                          fontSize: window.isCompact ? 10.5 : 11,
                          color: switch (e.level) {
                            'ERROR' => scheme.error,
                            'WARN' => scheme.tertiary,
                            _ => scheme.onSurfaceVariant,
                          },
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          e.message,
                          style: TextStyle(
                            fontSize: window.isCompact ? 12.5 : 13,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
