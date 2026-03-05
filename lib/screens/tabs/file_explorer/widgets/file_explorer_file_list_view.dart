import 'dart:async';
import 'dart:collection';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:carrot_pilot_manager/widgets/connection_required_view.dart';
import '../../../../ui/adaptive/window_class.dart';

import '../file_explorer_controller.dart';

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
  static const int _maxFolderCountConcurrentRequests = 2;
  static const Duration _folderCountUiRefreshDebounce =
      Duration(milliseconds: 48);
  static const int _checkboxTapSuppressWindowMs = 220;

  bool _isAutoLoadingMore = false;
  final Map<String, int> _folderItemCountCache = <String, int>{};
  final Set<String> _folderItemCountLoading = <String>{};
  final Set<String> _folderItemCountFailed = <String>{};
  final Queue<String> _folderItemCountQueue = Queue<String>();
  int _activeFolderItemCountRequests = 0;
  int _folderCountGeneration = 0;
  Timer? _folderCountUiRefreshTimer;
  String _folderCountCachePath = '';
  bool _folderCountCacheShowHidden = false;
  final Map<String, int> _recentCheckboxTapMs = <String, int>{};

  @override
  void initState() {
    super.initState();
    _resetFolderCountCacheIfNeeded();
  }

  @override
  void didUpdateWidget(covariant FileExplorerFileListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resetFolderCountCacheIfNeeded();
    _drainFolderCountQueue();
  }

  @override
  void dispose() {
    _folderCountUiRefreshTimer?.cancel();
    _recentCheckboxTapMs.clear();
    super.dispose();
  }

  void _markCheckboxTap(String fullPath) {
    _recentCheckboxTapMs[fullPath] = DateTime.now().millisecondsSinceEpoch;
  }

  bool _consumeRecentCheckboxTap(String fullPath) {
    final tappedAt = _recentCheckboxTapMs[fullPath];
    if (tappedAt == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentCheckboxTapMs.remove(fullPath);
    return (now - tappedAt) <= _checkboxTapSuppressWindowMs;
  }

  void _resetFolderCountCacheIfNeeded() {
    final path = widget.controller.currentPath;
    final showHidden = widget.controller.showHidden;
    if (_folderCountCachePath == path &&
        _folderCountCacheShowHidden == showHidden) {
      return;
    }
    _folderCountGeneration += 1;
    _folderCountCachePath = path;
    _folderCountCacheShowHidden = showHidden;
    _folderCountUiRefreshTimer?.cancel();
    _folderCountUiRefreshTimer = null;
    _folderItemCountCache.clear();
    _folderItemCountLoading.clear();
    _folderItemCountFailed.clear();
    _folderItemCountQueue.clear();
  }

  void _scheduleFolderCountUiRefresh() {
    if (_folderCountUiRefreshTimer != null) return;
    _folderCountUiRefreshTimer = Timer(_folderCountUiRefreshDebounce, () {
      _folderCountUiRefreshTimer = null;
      if (!mounted) return;
      setState(() {});
    });
  }

  void _drainFolderCountQueue() {
    final ssh = widget.controller.ssh;
    if (ssh == null || !ssh.isConnected) return;

    while (_activeFolderItemCountRequests < _maxFolderCountConcurrentRequests &&
        _folderItemCountQueue.isNotEmpty) {
      final fullPath = _folderItemCountQueue.removeFirst();
      final generation = _folderCountGeneration;
      final showHidden = widget.controller.showHidden;
      final cachePathSnapshot = widget.controller.currentPath;
      _activeFolderItemCountRequests += 1;

      ssh.listFiles(fullPath).then((items) {
        if (!mounted) return;
        if (generation != _folderCountGeneration) return;
        if (_folderCountCachePath != cachePathSnapshot ||
            _folderCountCacheShowHidden != showHidden) {
          return;
        }
        final count = items.where((entry) {
          if (entry.filename == '.' || entry.filename == '..') return false;
          if (!showHidden && entry.filename.startsWith('.')) return false;
          return true;
        }).length;
        _folderItemCountCache[fullPath] = count;
        _folderItemCountFailed.remove(fullPath);
        _folderItemCountLoading.remove(fullPath);
        _scheduleFolderCountUiRefresh();
      }).catchError((_) {
        if (!mounted) return;
        if (generation != _folderCountGeneration) return;
        if (_folderCountCachePath != cachePathSnapshot ||
            _folderCountCacheShowHidden != showHidden) {
          return;
        }
        _folderItemCountFailed.add(fullPath);
        _folderItemCountLoading.remove(fullPath);
        _scheduleFolderCountUiRefresh();
      }).whenComplete(() {
        if (_activeFolderItemCountRequests > 0) {
          _activeFolderItemCountRequests -= 1;
        }
        if (mounted) {
          _drainFolderCountQueue();
        }
      });
    }
  }

  void _ensureFolderItemCount(String fullPath) {
    if (_folderItemCountCache.containsKey(fullPath) ||
        _folderItemCountLoading.contains(fullPath) ||
        _folderItemCountFailed.contains(fullPath)) {
      return;
    }

    final ssh = widget.controller.ssh;
    if (ssh == null || !ssh.isConnected) return;

    _folderItemCountLoading.add(fullPath);
    _folderItemCountQueue.add(fullPath);
    _drainFolderCountQueue();
  }

  String _folderSubtitle(String fullPath) {
    final cached = _folderItemCountCache[fullPath];
    if (cached != null) return '$cached개 항목';
    if (_folderItemCountFailed.contains(fullPath)) return '항목수 확인 실패';
    if (_folderItemCountLoading.contains(fullPath)) return '항목수 계산 중...';
    return '항목수 계산 중...';
  }

  String _formatFileSize(int? size) {
    if (size == null) return '';
    if (size < 1024) return '$size B';
    const units = <String>['KB', 'MB', 'GB', 'TB'];
    var value = size.toDouble();
    var unitIndex = -1;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final fraction = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
    return '${value.toStringAsFixed(fraction)} ${units[unitIndex]}';
  }

  String _formatDateTime(int? seconds) {
    if (seconds == null || seconds <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  String _formatPermissionsOctal(SftpName item) {
    final mode = item.attr.mode;
    if (mode == null) return '-';
    final perms = mode.value & 0x1FF;
    return perms.toRadixString(8).padLeft(3, '0');
  }

  String _formatPermissionsRwx(SftpName item) {
    final mode = item.attr.mode;
    if (mode == null) return '---------';

    String bit(bool on, String char) => on ? char : '-';

    return [
      bit(mode.userRead, 'r'),
      bit(mode.userWrite, 'w'),
      bit(mode.userExecute, 'x'),
      bit(mode.groupRead, 'r'),
      bit(mode.groupWrite, 'w'),
      bit(mode.groupExecute, 'x'),
      bit(mode.otherRead, 'r'),
      bit(mode.otherWrite, 'w'),
      bit(mode.otherExecute, 'x'),
    ].join();
  }

  String _fileTypeLabel(SftpName item) {
    if (item.attr.isDirectory) return '폴더';
    if (item.attr.isSymbolicLink) return '심볼릭 링크';
    if (item.attr.isFile) return '파일';
    return '기타';
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
    final window = UiWindowInfo.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        window.isCompact ? 12 : 16,
        8,
        window.isCompact ? 12 : 16,
        12,
      ),
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
    int index,
    List<SftpName> visibleFiles,
  ) {
    final controller = widget.controller;
    final window = UiWindowInfo.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isLoadMore =
        controller.canLoadMoreVisible && index >= visibleFiles.length;
    if (isLoadMore) {
      return _buildLoadMoreTile();
    }

    final item = visibleFiles[index];
    final isDir = item.attr.isDirectory;
    final isLink = item.attr.isSymbolicLink;
    final fullPath = controller.fullPathOf(item);
    final isSelected = controller.isSelected(fullPath);
    final lowerName = item.filename.toLowerCase();
    final canExtract = !isDir &&
        (lowerName.endsWith('.zip') ||
            lowerName.endsWith('.tar') ||
            lowerName.endsWith('.tar.gz') ||
            lowerName.endsWith('.tgz'));
    final leadingIcon = Icon(
      isDir ? Icons.folder : (isLink ? Icons.link : Icons.insert_drive_file),
      size: 18,
      color: isDir
          ? scheme.tertiary
          : (isLink ? scheme.primary : scheme.onSurfaceVariant),
    );
    if (isDir) {
      _ensureFolderItemCount(fullPath);
    }

    return ListTile(
      key: ValueKey(fullPath),
      dense: true,
      visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
      selected: isSelected,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.22),
      contentPadding: EdgeInsets.symmetric(
        horizontal: window.isCompact ? 8 : 10,
        vertical: 0,
      ),
      horizontalTitleGap: 6,
      minLeadingWidth: window.isCompact ? 32 : 36,
      minVerticalPadding: 2,
      leading: SizedBox(
        width: window.isCompact ? 32 : 36,
        height: window.isCompact ? 32 : 36,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _markCheckboxTap(fullPath);
            controller.toggleSelection(fullPath);
          },
          child: Center(
            child: IgnorePointer(
              child: Checkbox(
                value: isSelected,
                onChanged: (_) {},
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.padded,
              ),
            ),
          ),
        ),
      ),
      title: Row(
        children: [
          leadingIcon,
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              item.filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
      subtitle: isDir
          ? Text(_folderSubtitle(fullPath))
          : Text(_formatFileSize(item.attr.size)),
      onLongPress: () {
        _showItemActionsDialog(
          item: item,
          fullPath: fullPath,
          canExtract: canExtract,
        );
      },
      onTap: () {
        if (_consumeRecentCheckboxTap(fullPath)) {
          return;
        }
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
    );
  }

  Future<void> _showItemActionsDialog({
    required SftpName item,
    required String fullPath,
    required bool canExtract,
  }) async {
    final isDir = item.attr.isDirectory;
    final hasAnySelection = widget.controller.selectedCount > 0;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        SimpleDialogOption actionOption(
          String value,
          String label, {
          Color? color,
        }) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, value),
            child: Text(
              label,
              style: color == null ? null : TextStyle(color: color),
            ),
          );
        }

        return SimpleDialog(
          title: Text(
            item.filename,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          children: [
            if (!isDir) actionOption('edit', '편집'),
            actionOption('properties', '속성'),
            actionOption('rename', '이름 바꾸기'),
            actionOption('chmod', '권한 설정'),
            actionOption('download', '다운로드'),
            actionOption('copy_path', '경로 복사'),
            actionOption('copy_clip', '클립보드 복사'),
            actionOption('cut_clip', '클립보드 잘라내기'),
            actionOption('select', '선택에 추가'),
            if (hasAnySelection) actionOption('clear_selection', '선택 해제'),
            if (canExtract) actionOption('extract', '압축 해제'),
            actionOption(
              'delete',
              '삭제',
              color: Theme.of(dialogContext).colorScheme.error,
            ),
          ],
        );
      },
    );

    if (action == null) return;

    switch (action) {
      case 'edit':
        await widget.onEditFile(item);
        break;
      case 'properties':
        await _showPropertiesDialog(item: item, fullPath: fullPath);
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
      case 'clear_selection':
        widget.controller.clearSelection();
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
  }

  Future<void> _showPropertiesDialog({
    required SftpName item,
    required String fullPath,
  }) async {
    final attrs = item.attr;
    final lines = <String>[
      '이름: ${item.filename}',
      '종류: ${_fileTypeLabel(item)}',
      '경로: $fullPath',
      '크기: ${attrs.isDirectory ? '-' : _formatFileSize(attrs.size)}',
      '수정시간: ${_formatDateTime(attrs.modifyTime)}',
      '접근시간: ${_formatDateTime(attrs.accessTime)}',
      'UID: ${attrs.userID ?? '-'}',
      'GID: ${attrs.groupID ?? '-'}',
      '권한(rwx): ${_formatPermissionsRwx(item)}',
      '권한(octal): ${_formatPermissionsOctal(item)}',
      '원시 mode: ${attrs.mode?.value ?? '-'}',
    ];
    if (attrs.extended != null && attrs.extended!.isNotEmpty) {
      lines.add('extended:');
      for (final entry in attrs.extended!.entries) {
        lines.add('  ${entry.key} = ${entry.value}');
      }
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('파일 속성'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(lines.join('\n')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _resetFolderCountCacheIfNeeded();
    final controller = widget.controller;
    final window = UiWindowInfo.of(context);
    final visibleFiles = controller.visibleFiles;

    if (!controller.isConnected) {
      return const ConnectionRequiredView(
        description: '파일 탐색기를 사용하려면 먼저 기기에 연결하세요.',
      );
    }

    if (controller.isLoading && visibleFiles.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (visibleFiles.isEmpty) {
      return const Center(child: Text("표시할 파일이 없습니다."));
    }

    final itemCount =
        visibleFiles.length + (controller.canLoadMoreVisible ? 1 : 0);

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView.builder(
        key: ValueKey('${controller.currentPath}|${controller.showHidden}'),
        padding: EdgeInsets.only(bottom: window.isCompact ? 12 : 16),
        itemCount: itemCount,
        cacheExtent: 720,
        itemBuilder: (context, index) =>
            _buildFileTile(context, index, visibleFiles),
      ),
    );
  }
}
