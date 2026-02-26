import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../file_explorer_controller.dart';

class FileExplorerFileListView extends StatelessWidget {
  final FileExplorerController controller;
  final Future<void> Function(String fullPath) onNavigateDirectory;
  final Future<void> Function(SftpName item) onEditFile;
  final Future<void> Function(SftpName item) onRename;
  final Future<void> Function(SftpName item) onChangePermissions;
  final Future<void> Function(SftpName item) onDownload;
  final Future<void> Function(String fullPath) onCopyPath;
  final void Function(String fullPath) onSelect;
  final void Function(String fullPath) onCopyClipboard;
  final void Function(String fullPath) onCutClipboard;
  final Future<void> Function(SftpName item) onDelete;
  final Future<void> Function(String fullPath) onExtractArchive;

  const FileExplorerFileListView({
    super.key,
    required this.controller,
    required this.onNavigateDirectory,
    required this.onEditFile,
    required this.onRename,
    required this.onChangePermissions,
    required this.onDownload,
    required this.onCopyPath,
    required this.onSelect,
    required this.onCopyClipboard,
    required this.onCutClipboard,
    required this.onDelete,
    required this.onExtractArchive,
  });

  @override
  Widget build(BuildContext context) {
    if (controller.isLoading && controller.visibleFiles.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.visibleFiles.isEmpty) {
      return const Center(child: Text("표시할 파일이 없습니다."));
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: controller.visibleFiles.length,
      itemBuilder: (context, index) {
        final item = controller.visibleFiles[index];
        final isDir = item.attr.isDirectory;
        final isLink = item.attr.isSymbolicLink;
        final fullPath = controller.fullPathOf(item);
        final isSelected = controller.isSelected(fullPath);
        final canExtract = !isDir &&
            (item.filename.endsWith('.zip') ||
                item.filename.endsWith('.tar') ||
                item.filename.endsWith('.tar.gz') ||
                item.filename.endsWith('.tgz'));

        return ListTile(
          leading: controller.selectionMode
              ? Checkbox(
                  value: isSelected,
                  onChanged: (_) => controller.toggleSelection(fullPath),
                )
              : Icon(
                  isDir
                      ? Icons.folder
                      : (isLink ? Icons.link : Icons.insert_drive_file),
                  color: isDir
                      ? Colors.amber
                      : (isLink ? Colors.blue : Colors.grey),
                ),
          title: Text(
            item.filename,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          subtitle: isDir
              ? const Text("폴더")
              : Text(item.attr.size != null
                  ? "${(item.attr.size! / 1024).toStringAsFixed(1)} KB"
                  : ""),
          onLongPress: () => controller.enterSelectionMode(fullPath),
          onTap: () {
            if (controller.selectionMode) {
              controller.toggleSelection(fullPath);
              return;
            }
            if (isDir) {
              onNavigateDirectory(fullPath);
            } else {
              onEditFile(item);
            }
          },
          trailing: controller.selectionMode
              ? null
              : PopupMenuButton<String>(
                  onSelected: (value) async {
                    switch (value) {
                      case 'edit':
                        await onEditFile(item);
                        break;
                      case 'rename':
                        await onRename(item);
                        break;
                      case 'chmod':
                        await onChangePermissions(item);
                        break;
                      case 'download':
                        await onDownload(item);
                        break;
                      case 'copy_path':
                        await onCopyPath(fullPath);
                        break;
                      case 'select':
                        onSelect(fullPath);
                        break;
                      case 'copy_clip':
                        onCopyClipboard(fullPath);
                        break;
                      case 'cut_clip':
                        onCutClipboard(fullPath);
                        break;
                      case 'delete':
                        await onDelete(item);
                        break;
                      case 'extract':
                        await onExtractArchive(fullPath);
                        break;
                    }
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    if (!isDir)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('편집'),
                      ),
                    const PopupMenuItem(
                      value: 'rename',
                      child: Text('이름 바꾸기'),
                    ),
                    const PopupMenuItem(
                      value: 'chmod',
                      child: Text('권한 설정'),
                    ),
                    const PopupMenuItem(
                      value: 'download',
                      child: Text('다운로드'),
                    ),
                    const PopupMenuItem(
                      value: 'copy_path',
                      child: Text('경로 복사'),
                    ),
                    const PopupMenuItem(
                      value: 'copy_clip',
                      child: Text('클립보드 복사'),
                    ),
                    const PopupMenuItem(
                      value: 'cut_clip',
                      child: Text('클립보드 잘라내기'),
                    ),
                    const PopupMenuItem(
                      value: 'select',
                      child: Text('선택에 추가'),
                    ),
                    if (canExtract)
                      const PopupMenuItem(
                        value: 'extract',
                        child: Text('압축 해제'),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('삭제', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
