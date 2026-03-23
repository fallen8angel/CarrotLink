import 'dart:io';

import 'package:carrot_pilot_manager/screens/tabs/file_editor_screen.dart';
import 'package:carrot_pilot_manager/screens/tabs/file_explorer/file_explorer_controller.dart';
import 'package:carrot_pilot_manager/screens/tabs/file_explorer/widgets/file_explorer_bottom_bar.dart';
import 'package:carrot_pilot_manager/screens/tabs/file_explorer/widgets/file_explorer_file_list_view.dart';
import 'package:carrot_pilot_manager/screens/tabs/file_explorer/widgets/file_explorer_top_toolbar.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../services/ssh_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/custom_toast.dart';

class FileExplorerTab extends StatefulWidget {
  const FileExplorerTab({super.key});

  @override
  State<FileExplorerTab> createState() => FileExplorerTabState();
}

enum _FileListTransitionDirection { neutral, forward, backward }

const int _maxInternalTextEditBytes = 4 * 1024 * 1024;
const int _maxInternalTextReadOnlyBytes = 32 * 1024 * 1024;
const int _maxExternalPreviewOpenWarningBytes = 128 * 1024 * 1024;
const int _maxExternalPreviewOpenHardLimitBytes = 1024 * 1024 * 1024; // 1GB
const Duration _previewCacheMaxAge = Duration(days: 3);
const Duration _previewCacheCleanupMinInterval = Duration(minutes: 5);
const int _previewCacheMaxFiles = 32;
const int _previewCacheMaxBytes = 512 * 1024 * 1024;

const Set<String> _knownTextExtensions = {
  '.txt',
  '.md',
  '.markdown',
  '.json',
  '.yaml',
  '.yml',
  '.xml',
  '.html',
  '.htm',
  '.css',
  '.js',
  '.mjs',
  '.cjs',
  '.ts',
  '.tsx',
  '.dart',
  '.java',
  '.kt',
  '.kts',
  '.py',
  '.sh',
  '.bash',
  '.zsh',
  '.ini',
  '.cfg',
  '.conf',
  '.properties',
  '.env',
  '.log',
  '.csv',
  '.sql',
  '.c',
  '.cc',
  '.cpp',
  '.cxx',
  '.h',
  '.hpp',
  '.go',
  '.rs',
  '.lua',
  '.toml',
  '.gradle',
  '.plist',
  '.patch',
  '.diff',
};

const Set<String> _externalMediaExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.bmp',
  '.webp',
  '.heic',
  '.mp4',
  '.mov',
  '.m4v',
  '.mkv',
  '.webm',
  '.avi',
  '.3gp',
  '.mp3',
  '.wav',
  '.aac',
  '.m4a',
  '.ogg',
  '.flac',
  '.opus',
  '.pdf',
};

class _PreviewCacheEntry {
  final File file;
  final FileStat stat;

  _PreviewCacheEntry({required this.file, required this.stat});
}

class FileExplorerTabState extends State<FileExplorerTab> {
  late final FileExplorerController _controller;
  late final Listenable _browserListenable;
  late final Listenable _topChromeListenable;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _pathFocusNode = FocusNode();
  _FileListTransitionDirection _fileListTransitionDirection =
      _FileListTransitionDirection.neutral;
  bool _didInit = false;
  DateTime? _lastPreviewCacheCleanupAt;
  bool _previewCacheCleanupRunning = false;

  @override
  void initState() {
    super.initState();
    _controller = FileExplorerController();
    _browserListenable = _controller.browserListenable;
    _topChromeListenable = Listenable.merge(
      [_controller.browserListenable, _controller.transferListenable],
    );
    _browserListenable.addListener(_handleControllerChanged);
    _syncPathField();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ssh = Provider.of<SSHService>(context);
    _controller.bindSsh(ssh);
    _schedulePreviewCacheCleanup();
    if (!_didInit) {
      _didInit = true;
      _controller.initializeIfNeeded().then((_) async {
        _showInterruptedOperationWarningIfNeeded();
        await _controller.ensureLoaded();
      });
    } else {
      _showInterruptedOperationWarningIfNeeded();
      _controller.ensureLoaded();
    }
  }

  @override
  void dispose() {
    _browserListenable.removeListener(_handleControllerChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _pathController.dispose();
    _pathFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    _syncPathField();
  }

  void _showInterruptedOperationWarningIfNeeded() {
    final label = _controller.takeStartupInterruptedOperationLabel();
    if (label == null || label.isEmpty || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      CustomToast.show(
        context,
        '이전 작업이 중단되었을 수 있습니다: $label',
        isError: true,
      );
    });
  }

  void _syncPathField() {
    if (_pathFocusNode.hasFocus) return;
    final target = _controller.currentPath;
    if (_pathController.text != target) {
      _pathController.text = target;
    }
  }

  void _schedulePreviewCacheCleanup({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        _lastPreviewCacheCleanupAt != null &&
        now.difference(_lastPreviewCacheCleanupAt!) <
            _previewCacheCleanupMinInterval) {
      return;
    }
    if (_previewCacheCleanupRunning) return;
    _lastPreviewCacheCleanupAt = now;
    _previewCacheCleanupRunning = true;
    _cleanupPreviewOpenCache().whenComplete(() {
      _previewCacheCleanupRunning = false;
    });
  }

  Future<void> _cleanupPreviewOpenCache() async {
    try {
      final dir = await _resolvePreviewOpenDir();
      if (!await dir.exists()) return;

      final entities = await dir.list(followLinks: false).toList();
      final files = <_PreviewCacheEntry>[];
      for (final entity in entities) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          files.add(_PreviewCacheEntry(file: entity, stat: stat));
        } catch (_) {}
      }

      if (files.isEmpty) return;

      final now = DateTime.now();
      for (final entry in files) {
        final modified = entry.stat.modified;
        if (now.difference(modified) > _previewCacheMaxAge) {
          try {
            await entry.file.delete();
          } catch (_) {}
        }
      }

      final remained = <_PreviewCacheEntry>[];
      final refreshedEntities = await dir.list(followLinks: false).toList();
      for (final entity in refreshedEntities) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          remained.add(_PreviewCacheEntry(file: entity, stat: stat));
        } catch (_) {}
      }

      if (remained.length <= _previewCacheMaxFiles) {
        var totalBytes = 0;
        for (final entry in remained) {
          totalBytes += entry.stat.size;
        }
        if (totalBytes <= _previewCacheMaxBytes) return;
      }

      remained.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
      var totalBytes = 0;
      for (final entry in remained) {
        totalBytes += entry.stat.size;
      }

      while (remained.length > _previewCacheMaxFiles ||
          totalBytes > _previewCacheMaxBytes) {
        if (remained.isEmpty) break;
        final target = remained.removeAt(0);
        totalBytes -= target.stat.size;
        try {
          await target.file.delete();
        } catch (_) {}
      }
    } catch (_) {
      // Silent cleanup: temp cache maintenance should not impact UX.
    }
  }

  Future<void> _navigateWithError(
    String path, {
    bool showToast = true,
    _FileListTransitionDirection transitionDirection =
        _FileListTransitionDirection.neutral,
  }) async {
    if (mounted) {
      setState(() {
        _fileListTransitionDirection = transitionDirection;
      });
    }
    try {
      await _controller.navigate(path);
    } catch (e) {
      if (!mounted || !showToast) return;
      CustomToast.show(context, "이동 실패: $e", isError: true);
    }
  }

  Future<void> _refresh() async {
    try {
      await _controller.refresh();
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "새로고침 실패: $e", isError: true);
    }
  }

  void _clearSearch({bool unfocus = false}) {
    final hadQuery =
        _searchController.text.isNotEmpty || _controller.searchQuery.isNotEmpty;
    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
    }
    if (hadQuery) {
      _controller.updateSearchQuery('');
    }
    if (unfocus) {
      _searchFocusNode.unfocus();
    }
  }

  Future<void> _goHomeWithError() async {
    if (mounted) {
      setState(() {
        _fileListTransitionDirection = _FileListTransitionDirection.neutral;
      });
    }
    try {
      await _controller.goHome();
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "이동 실패: $e", isError: true);
    }
  }

  Future<void> _goUpWithError() async {
    if (mounted) {
      setState(() {
        _fileListTransitionDirection = _FileListTransitionDirection.backward;
      });
    }
    try {
      await _controller.goUp();
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "이동 실패: $e", isError: true);
    }
  }

  Future<void> _goBackWithError() async {
    if (mounted) {
      setState(() {
        _fileListTransitionDirection = _FileListTransitionDirection.backward;
      });
    }
    try {
      await _controller.goBack();
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "이동 실패: $e", isError: true);
    }
  }

  Future<void> _goForwardWithError() async {
    if (mounted) {
      setState(() {
        _fileListTransitionDirection = _FileListTransitionDirection.forward;
      });
    }
    try {
      await _controller.goForward();
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "이동 실패: $e", isError: true);
    }
  }

  bool get _canStepBackTowardRoot =>
      _controller.canGoBack || _controller.currentPath != '/';

  Future<void> _goBackTowardRootWithError() async {
    if (_controller.canGoBack) {
      await _goBackWithError();
      return;
    }
    if (_controller.currentPath != '/') {
      if (mounted) {
        setState(() {
          _fileListTransitionDirection = _FileListTransitionDirection.backward;
        });
      }
      try {
        await _controller.goUp(addToHistory: false);
      } catch (e) {
        if (!mounted) return;
        CustomToast.show(context, "이동 실패: $e", isError: true);
      }
    }
  }

  Future<bool> handleSystemBack() async {
    if (_controller.isLoading) {
      // 폴더 이동/로딩 중에는 back 이벤트를 소비해 앱 종료로 빠지는 것을 방지
      return true;
    }

    if (_pathFocusNode.hasFocus || _searchFocusNode.hasFocus) {
      _pathFocusNode.unfocus();
      _searchFocusNode.unfocus();
      return true;
    }

    if (_searchController.text.isNotEmpty ||
        _controller.searchQuery.isNotEmpty) {
      _clearSearch(unfocus: true);
      return true;
    }

    if (_controller.selectedCount > 0) {
      _controller.clearSelection();
      return true;
    }

    if (_controller.canGoBack) {
      await _goBackWithError();
      return true;
    }

    if (_controller.currentPath != '/') {
      if (mounted) {
        setState(() {
          _fileListTransitionDirection = _FileListTransitionDirection.backward;
        });
      }
      try {
        await _controller.goUp(addToHistory: false);
      } catch (e) {
        if (!mounted) return true;
        CustomToast.show(context, "이동 실패: $e", isError: true);
      }
      return true;
    }

    return false;
  }

  Future<String?> _promptInput({
    required String title,
    String? initialValue,
    String label = '입력',
    String actionLabel = '확인',
  }) async {
    final controller = TextEditingController(text: initialValue ?? '');
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(labelText: label),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("취소"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(actionLabel),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("취소"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: destructive
                ? ElevatedButton.styleFrom(backgroundColor: Colors.red)
                : null,
            child: const Text("확인"),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _createFolder() async {
    final name =
        await _promptInput(title: "새 폴더", initialValue: "untitled", label: "폴더 이름", actionLabel: "생성");
    if (name == null || name.isEmpty) return;
    try {
      await _controller.createDirectory(name);
      if (!mounted) return;
      CustomToast.show(context, "폴더 생성됨");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "폴더 생성 실패: $e", isError: true);
    }
  }

  Future<void> _createFile() async {
    final name =
        await _promptInput(title: "새 파일", initialValue: "untitled", label: "파일 이름", actionLabel: "생성");
    if (name == null || name.isEmpty) return;
    try {
      await _controller.createFile(name);
      if (!mounted) return;
      CustomToast.show(context, "파일 생성됨");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "파일 생성 실패: $e", isError: true);
    }
  }

  Future<void> _uploadLocalFiles() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) return;

      final paths = picked.files
          .map((f) => f.path)
          .whereType<String>()
          .where((p) => p.isNotEmpty)
          .toList();
      if (paths.isEmpty) {
        if (mounted) {
          CustomToast.show(context, "선택된 로컬 파일 경로가 없습니다.", isError: true);
        }
        return;
      }

      final summary = await _controller.uploadLocalFiles(paths);
      if (!mounted) return;
      CustomToast.show(
        context,
        summary.canceled
            ? "업로드 취소됨: 성공 ${summary.success} / 스킵 ${summary.skipped} / 실패 ${summary.failed}"
            : "업로드 완료: 성공 ${summary.success} / 스킵 ${summary.skipped} / 실패 ${summary.failed}",
        isError: summary.failed > 0 || summary.canceled,
      );
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "업로드 실패: $e", isError: true);
    }
  }

  Future<void> _uploadLocalFolder() async {
    try {
      final directoryPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '업로드할 폴더 선택',
      );
      if (directoryPath == null || directoryPath.isEmpty) return;

      final summary = await _controller.uploadLocalDirectory(
        directoryPath,
        includeRootDirectory: _controller.includeRootDirectoryOnUpload,
      );
      if (!mounted) return;
      CustomToast.show(
        context,
        summary.canceled
            ? "폴더 업로드 취소됨: 성공 ${summary.success} / 스킵 ${summary.skipped} / 실패 ${summary.failed}"
            : "폴더 업로드 완료: 성공 ${summary.success} / 스킵 ${summary.skipped} / 실패 ${summary.failed}",
        isError: summary.failed > 0 || summary.canceled,
      );
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "폴더 업로드 실패: $e", isError: true);
    }
  }

  Future<void> _toggleUploadRootDirectory() async {
    await _controller.toggleIncludeRootDirectoryOnUpload();
    if (!mounted) return;
    final enabled = _controller.includeRootDirectoryOnUpload;
    CustomToast.show(
      context,
      enabled ? "폴더 업로드: 루트 폴더명 포함" : "폴더 업로드: 루트 폴더명 제외",
    );
  }

  Future<void> _retryFailedTransfers() async {
    final result = await _controller.retryFailedTransfers();
    if (!mounted || result == null) return;
    CustomToast.show(
      context,
      result.canceled
          ? "${result.label} 취소됨: 성공 ${result.success} / 스킵 ${result.skipped} / 실패 ${result.failed}"
          : "${result.label} 완료: 성공 ${result.success} / 스킵 ${result.skipped} / 실패 ${result.failed}",
      isError: result.failed > 0 || result.canceled,
    );
  }

  Future<void> _showBookmarks() async {
    if (!mounted) return;
    final bookmarks = _controller.bookmarks.toList();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => ListView.builder(
        // +2 for header and "add current" footer.
        itemCount: bookmarks.length + 2,
        itemBuilder: (ctx, index) {
          if (index == 0) {
            return const ListTile(
              title:
                  Text("북마크", style: TextStyle(fontWeight: FontWeight.bold)),
            );
          }
          if (index <= bookmarks.length) {
            final path = bookmarks[index - 1];
            return ListTile(
              leading: const Icon(Icons.bookmark),
              title: Text(path),
              onTap: () {
                Navigator.pop(ctx);
                _navigateWithError(path);
              },
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _controller.removeBookmark(path);
                },
              ),
            );
          }
          return ListTile(
            leading: const Icon(Icons.add),
            title: const Text("현재 위치 추가"),
            onTap: () async {
              Navigator.pop(ctx);
              await _controller.addBookmark();
              if (mounted) {
                CustomToast.show(context, "북마크 추가됨");
              }
            },
          );
        },
      ),
    );
  }

  Future<void> _rename(SftpName item) async {
    final fullPath = _controller.fullPathOf(item);
    final newName = await _promptInput(
      title: "이름 바꾸기",
      initialValue: item.filename,
      label: "새 이름",
    );
    if (newName == null || newName.isEmpty || newName == item.filename) return;

    final newPath = p.posix.join(_controller.currentPath, newName);
    try {
      await _controller.rename(fullPath, newPath);
      if (!mounted) return;
      CustomToast.show(context, "이름 변경됨");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "이름 변경 실패: $e", isError: true);
    }
  }

  /// Parse octal permission string from SftpName.longname (e.g. "drwxr-xr-x").
  String _parseCurrentPermissions(SftpName item) {
    try {
      final mode = item.longname;
      if (mode.length < 10) return '755';
      final perms = mode.substring(1, 10); // "rwxr-xr-x"
      int octal = 0;
      for (var i = 0; i < 9; i++) {
        if (perms[i] != '-') {
          octal |= 1 << (8 - i);
        }
      }
      return octal.toRadixString(8).padLeft(3, '0');
    } catch (_) {
      return '755';
    }
  }

  Future<void> _changePermissions(SftpName item) async {
    final currentPerms = _parseCurrentPermissions(item);
    final perms = await _promptInput(
      title: "권한 변경 (chmod)",
      initialValue: currentPerms,
      label: "현재: $currentPerms",
    );
    if (perms == null || perms.isEmpty) return;
    try {
      await _controller.changePermissions(_controller.fullPathOf(item), perms);
      if (!mounted) return;
      CustomToast.show(context, "권한 변경됨");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "권한 변경 실패: $e", isError: true);
    }
  }

  Future<void> _deleteSingle(SftpName item) async {
    final ok = await _confirm(
      title: "삭제 확인",
      message: "${item.filename} 항목을 삭제하시겠습니까?",
      destructive: true,
    );
    if (!ok) return;
    try {
      await _controller.deletePaths({_controller.fullPathOf(item)});
      if (!mounted) return;
      CustomToast.show(context, "삭제됨");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "삭제 실패: $e", isError: true);
    }
  }

  Future<void> _deleteSelected() async {
    if (_controller.selectedCount == 0) return;
    final ok = await _confirm(
      title: "선택 항목 삭제",
      message: "${_controller.selectedCount}개 항목을 삭제하시겠습니까?",
      destructive: true,
    );
    if (!ok) return;
    try {
      await _controller.deletePaths(_controller.selectedPaths);
      if (!mounted) return;
      CustomToast.show(context, "삭제 완료");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "삭제 실패: $e", isError: true);
    }
  }

  Future<void> _copySelectedToDirectory() async {
    if (_controller.selectedCount == 0) return;
    final target = await _promptInput(
      title: "복사 대상",
      initialValue: _controller.currentPath,
      label: "대상 경로",
      actionLabel: "복사",
    );
    if (target == null || target.isEmpty) return;
    try {
      await _controller.copyToDirectory(_controller.selectedPaths, target);
      if (!mounted) return;
      CustomToast.show(context, "복사 완료");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "복사 실패: $e", isError: true);
    }
  }

  Future<void> _compressSelected() async {
    if (_controller.selectedCount == 0) return;
    final name = await _promptInput(
      title: "압축 파일명",
      initialValue: "archive.tar.gz",
      label: "예: backup.zip / backup.tar.gz",
      actionLabel: "압축",
    );
    if (name == null || name.isEmpty) return;
    try {
      await _controller.compressSelected(name);
      if (!mounted) return;
      CustomToast.show(context, "압축 완료");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "압축 실패: $e", isError: true);
    }
  }

  Future<void> _downloadSelected() async {
    if (_controller.selectedCount == 0) return;
    try {
      final summary =
          await _controller.downloadPaths(_controller.selectedPaths);
      if (!mounted) return;
      CustomToast.show(
        context,
        summary.canceled
            ? "다운로드 취소됨: 성공 ${summary.success} / 스킵 ${summary.skipped} / 실패 ${summary.failed}"
            : "다운로드 완료: 성공 ${summary.success} / 스킵 ${summary.skipped} / 실패 ${summary.failed}",
        isError: summary.failed > 0 || summary.canceled,
      );
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "다운로드 실패: $e", isError: true);
    }
  }

  Future<void> _downloadSingle(SftpName item) async {
    final fullPath = _controller.fullPathOf(item);
    try {
      final summary = await _controller.downloadPaths({fullPath});
      if (!mounted) return;
      CustomToast.show(
        context,
        summary.canceled
            ? "다운로드 취소됨: 성공 ${summary.success} / 스킵 ${summary.skipped} / 실패 ${summary.failed}"
            : "다운로드 완료: 성공 ${summary.success} / 스킵 ${summary.skipped} / 실패 ${summary.failed}",
        isError: summary.failed > 0 || summary.canceled,
      );
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "다운로드 실패: $e", isError: true);
    }
  }

  Future<void> _copyPath(String fullPath) async {
    await Clipboard.setData(ClipboardData(text: fullPath));
    if (mounted) {
      CustomToast.show(context, "경로 복사됨");
    }
  }

  String _quoteShell(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  Future<void> _extractArchive(String fullPath) async {
    final name = await _promptInput(
      title: "압축 해제 경로",
      initialValue: _controller.currentPath,
      label: "대상 경로",
    );
    if (name == null || name.isEmpty) return;

    try {
      final ssh = _controller.ssh;
      if (ssh == null || !ssh.isConnected) {
        throw Exception('기기와 연결되어 있지 않습니다.');
      }
      final targetPath = name.startsWith('/')
          ? p.posix.normalize(name)
          : p.posix.normalize(p.posix.join(_controller.currentPath, name));
      final cmd =
          "mkdir -p -- ${_quoteShell(targetPath)} && (tar -xf ${_quoteShell(fullPath)} -C ${_quoteShell(targetPath)} || unzip -o ${_quoteShell(fullPath)} -d ${_quoteShell(targetPath)})";
      final result = await ssh.executeCommandResult(
        cmd,
        timeout: const Duration(minutes: 5),
      );
      if (!result.isSuccess) {
        throw Exception(result.output.trim().isEmpty
            ? "압축 해제 실패 (exit=${result.exitCode})"
            : result.output.trim());
      }
      if (!mounted) return;
      CustomToast.show(context, "압축 해제 완료");
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "압축 해제 실패: $e", isError: true);
    }
  }

  String _fileExtension(String fileName) => p.extension(fileName).toLowerCase();

  bool _isMediaLikeFile(SftpName item) {
    final ext = _fileExtension(item.filename);
    return _externalMediaExtensions.contains(ext);
  }

  bool _isLikelyTextFile(SftpName item) {
    final lower = item.filename.toLowerCase();
    final ext = _fileExtension(item.filename);
    if (_knownTextExtensions.contains(ext)) return true;
    if (lower == 'makefile' ||
        lower == 'cmakelists.txt' ||
        lower.endsWith('.gitignore') ||
        lower.endsWith('.gitattributes') ||
        lower.endsWith('.bashrc') ||
        lower.endsWith('.zshrc') ||
        lower.endsWith('.profile')) {
      return true;
    }
    if (_externalMediaExtensions.contains(ext)) return false;
    final size = item.attr.size ?? 0;
    if (size == 0) return true;
    return size <= _maxInternalTextReadOnlyBytes;
  }

  Future<Directory> _resolvePreviewOpenDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'preview_open'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _buildUniquePreviewPath(String directoryPath, String fileName) {
    final ext = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    final safeStem = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    var index = 0;
    while (true) {
      final suffix = index == 0 ? '' : '_$index';
      final candidate = p.join(
        directoryPath,
        '${DateTime.now().millisecondsSinceEpoch}_$safeStem$suffix$ext',
      );
      if (!File(candidate).existsSync()) return candidate;
      index += 1;
    }
  }

  String _friendlyExternalOpenFailureMessage(
    SftpName item,
    OpenResult result,
  ) {
    final raw = (result.message).trim();
    final typeName = result.type.toString().split('.').last.toLowerCase();
    final lowerRaw = raw.toLowerCase();
    final noApp = typeName.contains('noapp') ||
        lowerRaw.contains('no app') ||
        lowerRaw.contains('noapp') ||
        lowerRaw.contains('code4') ||
        lowerRaw.contains('code 4');

    if (noApp) {
      if (item.attr.isSymbolicLink) {
        return '링크 파일을 열 수 있는 앱이 없습니다. 길게 눌러 속성/경로 복사를 사용하세요.';
      }
      final ext = _fileExtension(item.filename);
      if (ext.isEmpty) {
        return '확장자 없는 파일을 열 수 있는 앱이 없습니다.';
      }
      return '이 파일을 열 수 있는 앱이 없습니다 ($ext).';
    }

    if (raw.isEmpty) {
      return '외부 앱으로 열기에 실패했습니다.';
    }
    return '외부 앱으로 열기 실패: $raw';
  }

  Future<T> _runBusyDialog<T>(
      String message, Future<T> Function() action) async {
    if (!mounted) {
      return action();
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );

    try {
      return await action();
    } finally {
      if (mounted) {
        final navigator = Navigator.of(context, rootNavigator: true);
        if (navigator.canPop()) {
          navigator.pop();
        }
      }
    }
  }

  Future<void> _openFileExternally(SftpName item) async {
    final ssh = _controller.ssh;
    if (ssh == null || !ssh.isConnected) {
      if (mounted) {
        CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      }
      return;
    }

    final remotePath = _controller.fullPathOf(item);
    final size = item.attr.size ?? 0;

    if (size > _maxExternalPreviewOpenHardLimitBytes) {
      final sizeGb = (size / (1024 * 1024 * 1024)).toStringAsFixed(1);
      if (!mounted) return;
      CustomToast.show(context, "$sizeGb GB — 외부 열기에 너무 큰 파일입니다.",
          isError: true);
      return;
    }
    if (size > _maxExternalPreviewOpenWarningBytes) {
      final sizeMb = (size / (1024 * 1024)).toStringAsFixed(1);
      final shouldContinue = await _confirm(
        title: "대용량 외부 열기",
        message:
            "$sizeMb MB 파일입니다. 임시 저장 후 외부 앱으로 열기 때문에 오래 걸리거나 실패할 수 있습니다. 계속하시겠습니까?",
      );
      if (!shouldContinue) return;
    }

    try {
      _schedulePreviewCacheCleanup();
      final localPath = await _runBusyDialog<String>(
        '외부 앱으로 열기 준비 중...',
        () async {
          final dir = await _resolvePreviewOpenDir();
          final localPath = _buildUniquePreviewPath(dir.path, item.filename);
          await ssh.downloadBinaryFile(remotePath, localPath);
          return localPath;
        },
      );

      if (!mounted) return;
      final result = await OpenFilex.open(localPath);
      if (!mounted) return;
      _schedulePreviewCacheCleanup(force: true);
      if (result.type != ResultType.done) {
        CustomToast.show(
          context,
          _friendlyExternalOpenFailureMessage(item, result),
          isError: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '외부 열기 실패: $e', isError: true);
    }
  }

  Future<void> _openTextFile(
    SftpName item, {
    bool showErrorToast = true,
  }) async {
    final ssh = _controller.ssh;
    if (ssh == null || !ssh.isConnected) {
      if (mounted) {
        CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      }
      return;
    }
    final fullPath = _controller.fullPathOf(item);
    final size = item.attr.size ?? 0;
    final largeReadOnlyMode = size > _maxInternalTextEditBytes;
    if (size > _maxInternalTextReadOnlyBytes) {
      throw Exception('TEXT_FILE_TOO_LARGE');
    }
    try {
      final content = await _runBusyDialog<String>(
        largeReadOnlyMode ? '대용량 텍스트 읽는 중...' : '텍스트 파일 여는 중...',
        () => ssh.readTextFile(fullPath),
      );
      if (!mounted) return;
      if (largeReadOnlyMode) {
        CustomToast.show(context, '대용량 파일은 읽기 전용으로 열립니다.');
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FileEditorScreen(
            filePath: fullPath,
            initialContent: content,
            initialReadOnly: true,
            lockReadOnly: largeReadOnlyMode,
            largeReadOnlyMode: largeReadOnlyMode,
            fileSizeBytes: item.attr.size,
          ),
        ),
      );
      await _refresh();
    } catch (e) {
      if (showErrorToast && mounted) {
        CustomToast.show(context, "파일 열기 실패: $e", isError: true);
      }
      rethrow;
    }
  }

  Future<void> _openFile(SftpName item) async {
    if (item.attr.isDirectory) {
      await _navigateWithError(
        _controller.fullPathOf(item),
        transitionDirection: _FileListTransitionDirection.forward,
      );
      return;
    }

    final mediaPreferred = _isMediaLikeFile(item);
    if (mediaPreferred) {
      await _openFileExternally(item);
      return;
    }

    final likelyText = _isLikelyTextFile(item);
    if (!likelyText) {
      await _openFileExternally(item);
      return;
    }

    try {
      await _openTextFile(
        item,
        showErrorToast: false,
      );
    } catch (e) {
      final isTooLarge = e.toString().contains('TEXT_FILE_TOO_LARGE');
      if (isTooLarge) {
        if (mounted) {
          final sizeMb =
              ((item.attr.size ?? 0) / (1024 * 1024)).toStringAsFixed(1);
          CustomToast.show(context, '대용량 텍스트($sizeMb MB): 외부 앱으로 여는 중...');
        }
        await _openFileExternally(item);
        return;
      }
      await _openFileExternally(item);
    }
  }

  void _setClipboardFromSelection(bool cut) {
    if (_controller.selectedCount == 0) return;
    _controller.setClipboard(_controller.selectedPaths, cut: cut);
    CustomToast.show(context, cut ? "잘라내기 준비됨" : "복사 준비됨");
  }

  void _setClipboardSingle(String fullPath, bool cut) {
    _controller.setClipboard({fullPath}, cut: cut);
    CustomToast.show(context, cut ? "잘라내기 준비됨" : "복사 준비됨");
  }

  Future<void> _pasteClipboard() async {
    if (!_controller.hasClipboard) return;
    try {
      await _controller.pasteClipboardToCurrentPath();
      if (!mounted) return;
      CustomToast.show(context, "붙여넣기 완료");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "붙여넣기 실패: $e", isError: true);
    }
  }

  Future<void> _runQuickActionFromSheet(
    BuildContext sheetContext,
    Future<void> Function() action,
  ) async {
    Navigator.pop(sheetContext);
    await action();
  }

  Future<void> _showQuickActionsSheet() async {
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final canPaste = _controller.hasClipboard;
        final hiddenOn = _controller.showHidden;
        final hasCheckedItems = _controller.selectedCount > 0;
        final includeRoot = _controller.includeRootDirectoryOnUpload;
        final sortMode = _controller.sortMode;

        Widget actionTile({
          required String title,
          IconData? icon,
          String? subtitle,
          bool checked = false,
          VoidCallback? onTap,
          bool enabled = true,
        }) {
          return ListTile(
            enabled: enabled,
            leading: icon == null ? null : Icon(icon),
            title: Text(title),
            subtitle: subtitle == null ? null : Text(subtitle),
            trailing: checked ? const Icon(Icons.check, size: 18) : null,
            onTap: enabled ? onTap : null,
          );
        }

        return SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text(
                  "파일 메뉴",
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              actionTile(
                title: "새로고침",
                icon: Icons.refresh,
                onTap: () => _runQuickActionFromSheet(sheetContext, _refresh),
              ),
              actionTile(
                title: "상위 폴더",
                icon: Icons.arrow_upward,
                onTap: _controller.currentPath == '/'
                    ? null
                    : () =>
                        _runQuickActionFromSheet(sheetContext, _goUpWithError),
                enabled: _controller.currentPath != '/',
              ),
              actionTile(
                title: "이동",
                icon: Icons.arrow_right_alt,
                subtitle: _pathController.text.trim().isEmpty
                    ? null
                    : _pathController.text.trim(),
                onTap: () => _runQuickActionFromSheet(
                  sheetContext,
                  () => _navigateWithError(_pathController.text.trim()),
                ),
              ),
              actionTile(
                title: "붙여넣기",
                icon: Icons.assignment_return,
                onTap: canPaste
                    ? () =>
                        _runQuickActionFromSheet(sheetContext, _pasteClipboard)
                    : null,
                enabled: canPaste,
              ),
              actionTile(
                title: "북마크",
                icon: Icons.bookmark_border,
                onTap: () => _runQuickActionFromSheet(
                  sheetContext,
                  _showBookmarks,
                ),
              ),
              const Divider(height: 8),
              actionTile(
                title: "새 폴더",
                icon: Icons.create_new_folder_outlined,
                onTap: () =>
                    _runQuickActionFromSheet(sheetContext, _createFolder),
              ),
              actionTile(
                title: "새 파일",
                icon: Icons.note_add_outlined,
                onTap: () =>
                    _runQuickActionFromSheet(sheetContext, _createFile),
              ),
              actionTile(
                title: "파일 업로드",
                icon: Icons.upload_file_outlined,
                onTap: () =>
                    _runQuickActionFromSheet(sheetContext, _uploadLocalFiles),
              ),
              actionTile(
                title: "폴더 업로드",
                icon: Icons.drive_folder_upload_outlined,
                onTap: () =>
                    _runQuickActionFromSheet(sheetContext, _uploadLocalFolder),
              ),
              const Divider(height: 8),
              actionTile(
                title: "숨김파일",
                icon: hiddenOn ? Icons.visibility_off : Icons.visibility,
                checked: hiddenOn,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _controller.toggleShowHidden();
                },
              ),
              actionTile(
                title: "전체선택",
                icon: Icons.select_all,
                checked: !hasCheckedItems && _controller.visibleCount > 0,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _controller.selectAllVisible();
                },
              ),
              if (hasCheckedItems)
                actionTile(
                  title: "선택 해제",
                  icon: Icons.check_box_outline_blank,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _controller.clearSelection();
                  },
                ),
              actionTile(
                title: "폴더명 포함",
                icon: Icons.tune,
                checked: includeRoot,
                subtitle: "폴더 업로드 시",
                onTap: () => _runQuickActionFromSheet(
                  sheetContext,
                  _toggleUploadRootDirectory,
                ),
              ),
              const Divider(height: 8),
              actionTile(
                title: "이름순",
                icon: Icons.sort_by_alpha,
                checked: sortMode == FileSortMode.name,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _controller.setSortMode(FileSortMode.name);
                },
              ),
              actionTile(
                title: "크기순",
                icon: Icons.data_object,
                checked: sortMode == FileSortMode.size,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _controller.setSortMode(FileSortMode.size);
                },
              ),
              actionTile(
                title: "수정순",
                icon: Icons.schedule,
                checked: sortMode == FileSortMode.modified,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _controller.setSortMode(FileSortMode.modified);
                },
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQuickActionFab(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    if (bottomInset > 0) return const SizedBox.shrink();
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final rightInset = window.isCompact ? 14.0 : 18.0;
    final bottomOffset = (window.isCompact ? 70.0 : 76.0) +
        safeBottom +
        (tokens.itemGap.clamp(4.0, 8.0));

    return Positioned(
      right: rightInset,
      bottom: bottomOffset,
      child: FloatingActionButton.small(
        heroTag: 'file_explorer_quick_actions_fab',
        onPressed: _showQuickActionsSheet,
        tooltip: "파일 메뉴",
        child: const Icon(Icons.more_horiz),
      ),
    );
  }

  Widget _buildSelectionToolbar() {
    final scheme = Theme.of(context).colorScheme;
    final clearSelectionChip = ActionChip(
      avatar: Icon(
        Icons.check_box_outline_blank_rounded,
        size: 16,
        color: scheme.onErrorContainer,
      ),
      label: Text(
        "선택 해제",
        style: TextStyle(
          color: scheme.onErrorContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
      backgroundColor: scheme.errorContainer.withValues(alpha: 0.9),
      side: BorderSide(
        color: scheme.error.withValues(alpha: 0.45),
      ),
      onPressed: _controller.clearSelection,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            clearSelectionChip,
            const SizedBox(width: 6),
            Chip(label: Text("${_controller.selectedCount}개 선택")),
            const SizedBox(width: 6),
            ActionChip(
              label: const Text("전체 선택"),
              onPressed: _controller.selectAllVisible,
            ),
            const SizedBox(width: 6),
            ActionChip(
              label: const Text("복사"),
              onPressed: () => _setClipboardFromSelection(false),
            ),
            const SizedBox(width: 6),
            ActionChip(
              label: const Text("잘라내기"),
              onPressed: () => _setClipboardFromSelection(true),
            ),
            const SizedBox(width: 6),
            ActionChip(
              label: const Text("붙여넣기"),
              onPressed: _controller.hasClipboard ? _pasteClipboard : null,
            ),
            const SizedBox(width: 6),
            ActionChip(
              label: const Text("경로복사"),
              onPressed: () => _copyPath(_controller.selectedPaths.join('\n')),
            ),
            const SizedBox(width: 6),
            ActionChip(
              label: const Text("폴더로 복사"),
              onPressed: _copySelectedToDirectory,
            ),
            const SizedBox(width: 6),
            ActionChip(
              label: const Text("압축"),
              onPressed: _compressSelected,
            ),
            const SizedBox(width: 6),
            ActionChip(
              label: const Text("다운로드"),
              onPressed: _downloadSelected,
            ),
            const SizedBox(width: 6),
            ActionChip(
              label: const Text("삭제"),
              onPressed: _deleteSelected,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopToolbar() {
    return FileExplorerTopToolbar(
      controller: _controller,
      searchController: _searchController,
      searchFocusNode: _searchFocusNode,
      onClearSearch: () => _clearSearch(unfocus: false),
      onToggleBatchPause: _controller.toggleBatchPause,
      onCancelBatch: _controller.cancelCurrentBatch,
      onRetryFailedTransfers: _retryFailedTransfers,
      onSearchChanged: _controller.updateSearchQuery,
      selectionBar:
          _controller.selectedCount > 0 ? _buildSelectionToolbar() : null,
    );
  }

  Widget _buildBottomPathBar() {
    return FileExplorerBottomBar(
      pathController: _pathController,
      pathFocusNode: _pathFocusNode,
      onGoHome: _goHomeWithError,
      onGoBack: _canStepBackTowardRoot ? _goBackTowardRootWithError : null,
      onGoForward: _controller.canGoForward ? _goForwardWithError : null,
      onNavigate: () => _navigateWithError(
        _pathController.text.trim(),
        transitionDirection: _FileListTransitionDirection.neutral,
      ),
    );
  }

  Widget _buildFileList() {
    return FileExplorerFileListView(
      controller: _controller,
      onNavigateDirectory: (path) => _navigateWithError(
        path,
        transitionDirection: _FileListTransitionDirection.forward,
      ),
      onEditFile: _openFile,
      onRename: _rename,
      onChangePermissions: _changePermissions,
      onDownload: _downloadSingle,
      onCopyPath: _copyPath,
      onSelect: _controller.enterSelectionMode,
      onCopyClipboard: (path) => _setClipboardSingle(path, false),
      onCutClipboard: (path) => _setClipboardSingle(path, true),
      onDelete: _deleteSingle,
      onExtractArchive: _extractArchive,
    );
  }

  Widget _buildAnimatedFileList() {
    final currentPath = _controller.currentPath;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        );
      },
      transitionBuilder: (child, animation) {
        final beginOffset = switch (_fileListTransitionDirection) {
          _FileListTransitionDirection.forward => const Offset(0.05, 0),
          _FileListTransitionDirection.backward => const Offset(-0.05, 0),
          _FileListTransitionDirection.neutral => const Offset(0, 0.02),
        };

        final offsetAnimation = Tween<Offset>(
          begin: beginOffset,
          end: Offset.zero,
        ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));

        return ClipRect(
          child: FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: offsetAnimation,
              child: child,
            ),
          ),
        );
      },
      child: KeyedSubtree(
        key: ValueKey(currentPath),
        child: _buildFileList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            AnimatedBuilder(
              animation: _topChromeListenable,
              builder: (context, _) => _buildTopToolbar(),
            ),
            AnimatedBuilder(
              animation: _browserListenable,
              builder: (context, _) {
                if (!_controller.isLoading) {
                  return const SizedBox.shrink();
                }
                return const LinearProgressIndicator();
              },
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: _browserListenable,
                builder: (context, _) => RepaintBoundary(
                  child: _buildAnimatedFileList(),
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _browserListenable,
              builder: (context, _) => _buildBottomPathBar(),
            ),
          ],
        ),
        _buildQuickActionFab(context),
      ],
    );
  }
}
