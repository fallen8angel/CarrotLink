import 'package:flutter/material.dart';
import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';

class ConnectionRequiredView extends StatelessWidget {
  final String title;
  final String description;
  final String? detail;
  final IconData icon;

  const ConnectionRequiredView({
    super.key,
    this.title = '기기 연결 필요',
    this.description = '기기와 연결되어 있지 않습니다.',
    this.detail,
    this.icon = Icons.portable_wifi_off_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactHeight =
            constraints.maxHeight > 0 && constraints.maxHeight < 220;
        final margin = compactHeight ? 8.0 : tokens.itemGap + 8.0;
        final vPadding = compactHeight ? 12.0 : 18.0;
        final iconSize = compactHeight ? 22.0 : 26.0;
        final titleGap = compactHeight ? 6.0 : 8.0;
        final bodyGap = compactHeight ? 4.0 : 6.0;

        final content = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: window.isCompact ? 420 : 520),
          child: Container(
            margin: EdgeInsets.all(margin),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: vPadding),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: iconSize, color: scheme.onSurfaceVariant),
                SizedBox(height: titleGap),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: bodyGap),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                  textAlign: TextAlign.center,
                ),
                if (detail != null && detail!.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        );

        if (constraints.maxHeight <= 0) {
          return Center(child: content);
        }
        return Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: content,
          ),
        );
      },
    );
  }
}
