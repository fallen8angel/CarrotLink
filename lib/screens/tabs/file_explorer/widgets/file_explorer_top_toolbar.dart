import 'package:flutter/material.dart';

import '../file_explorer_controller.dart';

enum _UploadOptionAction { toggleFolderRoot }

class FileExplorerTopToolbar extends StatelessWidget {
  final FileExplorerController controller;
  final TextEditingController searchController;
  final VoidCallback onGoHome;
  final VoidCallback? onGoUp;
  final VoidCallback onShowBookmarks;
  final VoidCallback onToggleSearch;
  final VoidCallback onToggleSelectionMode;
  final VoidCallback onCreateFolder;
  final VoidCallback onCreateFile;
  final VoidCallback onUploadFiles;
  final VoidCallback onUploadFolder;
  final bool includeRootDirectoryOnUpload;
  final VoidCallback onToggleUploadRootDirectory;
  final VoidCallback onToggleBatchPause;
  final VoidCallback onCancelBatch;
  final VoidCallback onRetryFailedTransfers;
  final VoidCallback onRefresh;
  final ValueChanged<FileSortMode> onSortSelected;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchClose;
  final Widget? selectionBar;

  const FileExplorerTopToolbar({
    super.key,
    required this.controller,
    required this.searchController,
    required this.onGoHome,
    required this.onGoUp,
    required this.onShowBookmarks,
    required this.onToggleSearch,
    required this.onToggleSelectionMode,
    required this.onCreateFolder,
    required this.onCreateFile,
    required this.onUploadFiles,
    required this.onUploadFolder,
    required this.includeRootDirectoryOnUpload,
    required this.onToggleUploadRootDirectory,
    required this.onToggleBatchPause,
    required this.onCancelBatch,
    required this.onRetryFailedTransfers,
    required this.onRefresh,
    required this.onSortSelected,
    required this.onSearchChanged,
    required this.onSearchClose,
    this.selectionBar,
  });

  @override
  Widget build(BuildContext context) {
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
              IconButton(
                icon: const Icon(Icons.home),
                tooltip: "홈",
                onPressed: onGoHome,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_upward),
                tooltip: "상위 폴더",
                onPressed: onGoUp,
              ),
              IconButton(
                icon: const Icon(Icons.bookmark_border),
                tooltip: "북마크",
                onPressed: onShowBookmarks,
              ),
              IconButton(
                icon: Icon(controller.showHidden
                    ? Icons.visibility_off
                    : Icons.visibility),
                tooltip: controller.showHidden ? "숨김파일 감추기" : "숨김파일 보기",
                onPressed: controller.toggleShowHidden,
              ),
              PopupMenuButton<FileSortMode>(
                tooltip: "정렬",
                icon: const Icon(Icons.sort),
                onSelected: onSortSelected,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: FileSortMode.name, child: Text("이름 정렬")),
                  PopupMenuItem(value: FileSortMode.size, child: Text("크기 정렬")),
                  PopupMenuItem(
                      value: FileSortMode.modified, child: Text("수정일 정렬")),
                ],
              ),
              const Spacer(),
              IconButton(
                icon: Icon(
                    controller.isSearching ? Icons.search_off : Icons.search),
                tooltip: controller.isSearching ? "검색 닫기" : "검색",
                onPressed: onToggleSearch,
              ),
              IconButton(
                icon: Icon(
                  controller.selectionMode
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                ),
                tooltip: controller.selectionMode ? "선택 해제" : "다중 선택",
                onPressed: onToggleSelectionMode,
              ),
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: "새 폴더",
                onPressed: onCreateFolder,
              ),
              IconButton(
                icon: const Icon(Icons.note_add_outlined),
                tooltip: "새 파일",
                onPressed: onCreateFile,
              ),
              IconButton(
                icon: const Icon(Icons.upload_file_outlined),
                tooltip: "로컬 파일 업로드",
                onPressed: onUploadFiles,
              ),
              IconButton(
                icon: const Icon(Icons.drive_folder_upload_outlined),
                tooltip: "로컬 폴더 업로드",
                onPressed: onUploadFolder,
              ),
              PopupMenuButton<_UploadOptionAction>(
                tooltip: "업로드 옵션",
                icon: const Icon(Icons.tune),
                onSelected: (action) {
                  if (action == _UploadOptionAction.toggleFolderRoot) {
                    onToggleUploadRootDirectory();
                  }
                },
                itemBuilder: (_) => [
                  CheckedPopupMenuItem<_UploadOptionAction>(
                    value: _UploadOptionAction.toggleFolderRoot,
                    checked: includeRootDirectoryOnUpload,
                    child: const Text("폴더 업로드 시 루트 폴더명 포함"),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: "새로고침",
                onPressed: onRefresh,
              ),
            ],
          ),
          if (controller.isSearching)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TextField(
                controller: searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: "파일/폴더 검색...",
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: onSearchClose,
                  ),
                ),
                onChanged: onSearchChanged,
              ),
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
