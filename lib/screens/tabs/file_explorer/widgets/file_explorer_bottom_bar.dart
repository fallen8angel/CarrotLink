import 'package:flutter/material.dart';

import '../../../../ui/adaptive/layout_tokens.dart';
import '../../../../ui/adaptive/window_class.dart';

class FileExplorerBottomBar extends StatelessWidget {
  final TextEditingController pathController;
  final FocusNode pathFocusNode;
  final VoidCallback? onGoHome;
  final VoidCallback? onGoBack;
  final VoidCallback? onGoForward;
  final VoidCallback onNavigate;

  const FileExplorerBottomBar({
    super.key,
    required this.pathController,
    required this.pathFocusNode,
    required this.onGoHome,
    required this.onGoBack,
    required this.onGoForward,
    required this.onNavigate,
  });

  Widget _compactActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    required bool compact,
  }) {
    final buttonSize = compact ? 32.0 : 36.0;
    return SizedBox(
      width: buttonSize,
      height: buttonSize,
      child: IconButton(
        icon: Icon(icon, size: compact ? 18 : 20),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          tokens.screenPadding.clamp(8.0, 16.0).toDouble(),
          6,
          tokens.screenPadding.clamp(8.0, 16.0).toDouble(),
          8,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border(
            top: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: pathController,
                focusNode: pathFocusNode,
                textInputAction: TextInputAction.go,
                maxLines: 1,
                autocorrect: false,
                enableSuggestions: false,
                style: TextStyle(fontSize: window.isCompact ? 12.5 : 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: "/data/openpilot",
                  hintStyle: TextStyle(
                    fontSize: window.isCompact ? 11.5 : 12,
                  ),
                  border: const OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: window.isCompact ? 9 : 10,
                  ),
                ),
                onSubmitted: (_) => onNavigate(),
              ),
            ),
            const SizedBox(width: 6),
            _compactActionButton(
              icon: Icons.home,
              tooltip: "홈",
              onPressed: onGoHome,
              compact: window.isCompact,
            ),
            _compactActionButton(
              icon: Icons.arrow_back,
              tooltip: "뒤로",
              onPressed: onGoBack,
              compact: window.isCompact,
            ),
            _compactActionButton(
              icon: Icons.arrow_forward,
              tooltip: "앞으로",
              onPressed: onGoForward,
              compact: window.isCompact,
            ),
          ],
        ),
      ),
    );
  }
}
