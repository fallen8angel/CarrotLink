import 'package:flutter/material.dart';

import '../file_explorer_controller.dart';

class FileExplorerBottomBar extends StatelessWidget {
  final FileExplorerController controller;
  final TextEditingController pathController;
  final FocusNode pathFocusNode;
  final VoidCallback? onGoBack;
  final VoidCallback? onGoForward;
  final VoidCallback onNavigate;
  final VoidCallback? onPaste;

  const FileExplorerBottomBar({
    super.key,
    required this.controller,
    required this.pathController,
    required this.pathFocusNode,
    required this.onGoBack,
    required this.onGoForward,
    required this.onNavigate,
    required this.onPaste,
  });

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
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: "뒤로",
              onPressed: onGoBack,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              tooltip: "앞으로",
              onPressed: onGoForward,
            ),
            Expanded(
              child: TextField(
                controller: pathController,
                focusNode: pathFocusNode,
                textInputAction: TextInputAction.go,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: "/data/openpilot",
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => onNavigate(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_right_alt),
              tooltip: "이동",
              onPressed: onNavigate,
            ),
            IconButton(
              icon: Icon(
                  controller.clipboardIsCut ? Icons.content_cut : Icons.copy),
              tooltip: controller.hasClipboard
                  ? (controller.clipboardIsCut
                      ? "잘라내기 ${controller.clipboardCount}개 준비됨"
                      : "복사 ${controller.clipboardCount}개 준비됨")
                  : "클립보드 비어있음",
              onPressed: null,
            ),
            IconButton(
              icon: const Icon(Icons.assignment_return),
              tooltip: "붙여넣기",
              onPressed: onPaste,
            ),
          ],
        ),
      ),
    );
  }
}
