import 'package:flutter/material.dart';

import '../../../../ui/adaptive/layout_tokens.dart';
import '../../../../ui/adaptive/window_class.dart';
import '../file_explorer_controller.dart';

class FileExplorerTopToolbar extends StatelessWidget {
  final FileExplorerController controller;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final VoidCallback onClearSearch;
  final VoidCallback onToggleBatchPause;
  final VoidCallback onCancelBatch;
  final VoidCallback onRetryFailedTransfers;
  final ValueChanged<String> onSearchChanged;
  final Widget? selectionBar;

  const FileExplorerTopToolbar({
    super.key,
    required this.controller,
    required this.searchController,
    required this.searchFocusNode,
    required this.onClearSearch,
    required this.onToggleBatchPause,
    required this.onCancelBatch,
    required this.onRetryFailedTransfers,
    required this.onSearchChanged,
    this.selectionBar,
  });

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final retryLabelMinWidth = window.isCompact ? 0.0 : 120.0;
    final retryLabelMaxWidth = switch (window.windowClass) {
      UiWindowClass.compact => 220.0,
      UiWindowClass.medium => 260.0,
      UiWindowClass.expanded => 320.0,
      UiWindowClass.large => 380.0,
      UiWindowClass.extraLarge => 420.0,
    };
    final hasQuery =
        controller.searchQuery.isNotEmpty || searchController.text.isNotEmpty;

    return Container(
      padding: EdgeInsets.fromLTRB(
        tokens.screenPadding.clamp(8.0, 16.0).toDouble(),
        8,
        tokens.screenPadding.clamp(8.0, 16.0).toDouble(),
        6,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: searchController,
                  focusNode: searchFocusNode,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(
                    fontSize: window.isCompact ? 12.5 : 13,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: "검색",
                    hintStyle: TextStyle(
                      fontSize: window.isCompact ? 11.5 : 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onChanged: onSearchChanged,
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: Icon(hasQuery ? Icons.close : Icons.search),
                tooltip: hasQuery ? "검색 지우기" : "검색",
                onPressed: hasQuery
                    ? onClearSearch
                    : () => searchFocusNode.requestFocus(),
              ),
            ],
          ),
          if (selectionBar != null) selectionBar!,
          if (controller.isBatchBusy) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
                value: controller.batchProgressValue > 0
                    ? controller.batchProgressValue
                    : null),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                controller.batchProgressText.isEmpty
                    ? controller.batchMessage
                    : '${controller.batchProgressText}  ${controller.batchMessage}',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: onToggleBatchPause,
                  icon: Icon(controller.isBatchPaused
                      ? Icons.play_arrow
                      : Icons.pause),
                  label: Text(controller.isBatchPaused ? '재개' : '일시정지'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: controller.canCancelBatch ? onCancelBatch : null,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('취소'),
                ),
              ],
            ),
          ],
          if (!controller.isBatchBusy && controller.hasRetryableFailures) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: retryLabelMinWidth,
                    maxWidth: retryLabelMaxWidth,
                  ),
                  child: Text(
                    '${controller.retryLabel} 실패 ${controller.retryableFailureCount}건',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  onPressed: onRetryFailedTransfers,
                  icon: const Icon(Icons.refresh),
                  label: const Text('실패 재시도'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
