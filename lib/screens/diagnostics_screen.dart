import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/diagnostics_service.dart';
import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';
import '../widgets/custom_toast.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('진단 로그'),
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
      ),
      body: Consumer<DiagnosticsService>(
        builder: (context, diagnostics, _) {
          final entries = diagnostics.entries;
          if (entries.isEmpty) {
            return const Center(child: Text('로그가 없습니다.'));
          }

          return ListView.separated(
            padding: EdgeInsets.all(
              tokens.screenPadding.clamp(12.0, 20.0).toDouble(),
            ),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const Divider(height: 16),
            itemBuilder: (context, index) {
              final e = entries[index];
              final color = switch (e.level) {
                'ERROR' => scheme.error,
                'WARN' => scheme.tertiary,
                _ => scheme.onSurfaceVariant,
              };
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${e.timestamp.toLocal()}  [${e.level}]  ${e.category}',
                    style: TextStyle(
                      fontSize: window.isCompact ? 10.5 : 11,
                      color: color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    e.message,
                    style: TextStyle(fontSize: window.isCompact ? 12.5 : 13),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
