import 'package:flutter/material.dart';

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
    final hasQuery =
        controller.searchQuery.isNotEmpty || searchController.text.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withValues(alpha: 0.5),
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
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: "검색",
                    hintStyle: const TextStyle(fontSize: 12),
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
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 4),
            Row(
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
            Row(
              children: [
                Text(
                  '${controller.retryLabel} 실패 ${controller.retryableFailureCount}건',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
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
