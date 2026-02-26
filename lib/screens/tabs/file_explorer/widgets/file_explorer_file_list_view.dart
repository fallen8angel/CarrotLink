import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_fancy_tree_view2/flutter_fancy_tree_view2.dart';

import '../file_explorer_controller.dart';

class _FileTreeNode {
  final SftpName? item;
  final bool isLoadMore;

  const _FileTreeNode.item(this.item) : isLoadMore = false;
  const _FileTreeNode.loadMore()
      : item = null,
        isLoadMore = true;
}

class FileExplorerFileListView extends StatefulWidget {
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
  State<FileExplorerFileListView> createState() =>
      _FileExplorerFileListViewState();
}

class _FileExplorerFileListViewState extends State<FileExplorerFileListView> {
  late final TreeController<_FileTreeNode> _treeController;
  int _treeFingerprint = 0;
  bool _isAutoLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _treeController = TreeController<_FileTreeNode>(
      roots: const <_FileTreeNode>[],
      childrenProvider: (_) => const <_FileTreeNode>[],
    );
    _syncTreeFromController(force: true);
  }

  @override
  void didUpdateWidget(covariant FileExplorerFileListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTreeFromController();
  }

  @override
  void dispose() {
    _treeController.dispose();
    super.dispose();
  }

  int _computeTreeFingerprint() {
    final items = widget.controller.visibleFiles;
    var hash = 17;
    hash = 37 * hash + items.length;
    hash = 37 * hash + widget.controller.canLoadMoreVisible.hashCode;
    final sampleCount = items.length > 320 ? 320 : items.length;
    for (var i = 0; i < sampleCount; i++) {
      final item = items[i];
      hash = 37 * hash + item.filename.hashCode;
      hash = 37 * hash + item.attr.isDirectory.hashCode;
    }
    return hash;
  }

  void _syncTreeFromController({bool force = false}) {
    final nextFingerprint = _computeTreeFingerprint();
    if (!force && nextFingerprint == _treeFingerprint) {
      return;
    }
    _treeFingerprint = nextFingerprint;

    final roots = <_FileTreeNode>[
      ...widget.controller.visibleFiles.map(_FileTreeNode.item),
      if (widget.controller.canLoadMoreVisible) const _FileTreeNode.loadMore(),
    ];
    _treeController.roots = roots;
  }

  Future<void> _loadMore() async {
    if (_isAutoLoadingMore || !widget.controller.canLoadMoreVisible) return;
    _isAutoLoadingMore = true;
    try {
      await widget.controller.loadMoreVisibleItems();
    } finally {
      _isAutoLoadingMore = false;
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.extentAfter < 260) {
      _loadMore();
    }
    return false;
  }

  Widget _buildLoadMoreTile() {
    final controller = widget.controller;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: OutlinedButton.icon(
        onPressed: controller.isLoadingMoreVisible ? null : _loadMore,
        icon: controller.isLoadingMoreVisible
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.unfold_more),
        label: Text(
          controller.isLoadingMoreVisible
              ? '더 불러오는 중...'
              : '더 보기 (${controller.visibleCount}/${controller.totalFilteredCount})',
        ),
      ),
    );
  }

  Widget _buildFileTile(
    BuildContext context,
    TreeEntry<_FileTreeNode> entry,
  ) {
    final node = entry.node;
    if (node.isLoadMore) {
      return _buildLoadMoreTile();
    }

    final item = node.item!;
    final controller = widget.controller;
    final isDir = item.attr.isDirectory;
    final isLink = item.attr.isSymbolicLink;
    final fullPath = controller.fullPathOf(item);
    final isSelected = controller.isSelected(fullPath);
    final canExtract = !isDir &&
        (item.filename.endsWith('.zip') ||
            item.filename.endsWith('.tar') ||
            item.filename.endsWith('.tar.gz') ||
            item.filename.endsWith('.tgz'));

    return TreeIndentation(
      entry: entry,
      guide: const IndentGuide(indent: 0),
      child: ListTile(
        leading: controller.selectionMode
            ? Checkbox(
                value: isSelected,
                onChanged: (_) => controller.toggleSelection(fullPath),
              )
            : Icon(
                isDir
                    ? Icons.folder
                    : (isLink ? Icons.link : Icons.insert_drive_file),
                color:
                    isDir ? Colors.amber : (isLink ? Colors.blue : Colors.grey),
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
            widget.onNavigateDirectory(fullPath);
          } else {
            widget.onEditFile(item);
          }
        },
        trailing: controller.selectionMode
            ? null
            : PopupMenuButton<String>(
                onSelected: (value) async {
                  switch (value) {
                    case 'edit':
                      await widget.onEditFile(item);
                      break;
                    case 'rename':
                      await widget.onRename(item);
                      break;
                    case 'chmod':
                      await widget.onChangePermissions(item);
                      break;
                    case 'download':
                      await widget.onDownload(item);
                      break;
                    case 'copy_path':
                      await widget.onCopyPath(fullPath);
                      break;
                    case 'select':
                      widget.onSelect(fullPath);
                      break;
                    case 'copy_clip':
                      widget.onCopyClipboard(fullPath);
                      break;
                    case 'cut_clip':
                      widget.onCutClipboard(fullPath);
                      break;
                    case 'delete':
                      await widget.onDelete(item);
                      break;
                    case 'extract':
                      await widget.onExtractArchive(fullPath);
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncTreeFromController();
    final controller = widget.controller;

    if (controller.isLoading && controller.visibleFiles.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.visibleFiles.isEmpty) {
      return const Center(child: Text("표시할 파일이 없습니다."));
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: TreeView<_FileTreeNode>(
        treeController: _treeController,
        padding: const EdgeInsets.only(bottom: 12),
        nodeBuilder: _buildFileTile,
      ),
    );
  }
}
