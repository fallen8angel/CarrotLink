import 'package:flutter/material.dart';

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
  }) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        icon: Icon(icon, size: 18),
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
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border(
            top: BorderSide(
              color: Theme.of(context)
                  .colorScheme
                  .outlineVariant
                  .withValues(alpha: 0.5),
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
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: "/data/openpilot",
                  hintStyle: TextStyle(fontSize: 12),
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                onSubmitted: (_) => onNavigate(),
              ),
            ),
            const SizedBox(width: 6),
            _compactActionButton(
              icon: Icons.home,
              tooltip: "홈",
              onPressed: onGoHome,
            ),
            _compactActionButton(
              icon: Icons.arrow_back,
              tooltip: "뒤로",
              onPressed: onGoBack,
            ),
            _compactActionButton(
              icon: Icons.arrow_forward,
              tooltip: "앞으로",
              onPressed: onGoForward,
            ),
          ],
        ),
      ),
    );
  }
}
