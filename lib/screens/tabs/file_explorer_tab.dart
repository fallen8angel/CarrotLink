import 'package:carrot_pilot_manager/screens/tabs/file_editor_screen.dart';
import 'package:carrot_pilot_manager/screens/tabs/file_explorer/file_explorer_controller.dart';
import 'package:carrot_pilot_manager/screens/tabs/file_explorer/widgets/file_explorer_bottom_bar.dart';
import 'package:carrot_pilot_manager/screens/tabs/file_explorer/widgets/file_explorer_file_list_view.dart';
import 'package:carrot_pilot_manager/screens/tabs/file_explorer/widgets/file_explorer_top_toolbar.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../services/ssh_service.dart';
import '../../widgets/custom_toast.dart';

class FileExplorerTab extends StatefulWidget {
  const FileExplorerTab({super.key});

  @override
  State<FileExplorerTab> createState() => _FileExplorerTabState();
}

class _FileExplorerTabState extends State<FileExplorerTab> {
  late final FileExplorerController _controller;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  final FocusNode _pathFocusNode = FocusNode();
  bool _didInit = false;

  @override
  void initState() {
    super.initState();
    _controller = FileExplorerController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ssh = Provider.of<SSHService>(context);
    _controller.bindSsh(ssh);
    if (!_didInit) {
      _didInit = true;
      _controller.initializeIfNeeded().then((_) => _controller.ensureLoaded());
    } else {
      _controller.ensureLoaded();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _pathController.dispose();
    _pathFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _syncPathField() {
    if (_pathFocusNode.hasFocus) return;
    final target = _controller.currentPath;
    if (_pathController.text != target) {
      _pathController.text = target;
      _pathController.selection =
          TextSelection.collapsed(offset: target.length);
    }
  }

  Future<void> _navigateWithError(String path, {bool showToast = true}) async {
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

  Future<String?> _promptInput({
    required String title,
    String? initialValue,
    String label = '입력',
    String actionLabel = '확인',
  }) async {
    final controller = TextEditingController(text: initialValue ?? '');
    return showDialog<String>(
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
        await _promptInput(title: "새 폴더", label: "폴더 이름", actionLabel: "생성");
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
        await _promptInput(title: "새 파일", label: "파일 이름", actionLabel: "생성");
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
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => ListView(
        children: [
          const ListTile(
            title: Text("북마크", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ..._controller.bookmarks.map(
            (path) => ListTile(
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
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text("현재 위치 추가"),
            onTap: () async {
              Navigator.pop(ctx);
              await _controller.addBookmark();
              if (mounted) {
                CustomToast.show(context, "북마크 추가됨");
              }
            },
          ),
        ],
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

  Future<void> _changePermissions(SftpName item) async {
    final perms = await _promptInput(
      title: "권한 변경 (chmod)",
      initialValue: "755",
      label: "예: 755",
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
    final now = DateTime.now();
    final defaultName =
        "archive_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}.tar.gz";
    final name = await _promptInput(
      title: "압축 파일명",
      initialValue: defaultName,
      label: "압축 파일명",
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
      final cmd =
          "mkdir -p -- ${_quoteShell(name)} && (tar -xf ${_quoteShell(fullPath)} -C ${_quoteShell(name)} || unzip -o ${_quoteShell(fullPath)} -d ${_quoteShell(name)})";
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
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "압축 해제 실패: $e", isError: true);
    }
  }

  Future<void> _editFile(SftpName item) async {
    final ssh = _controller.ssh;
    if (ssh == null || !ssh.isConnected) {
      if (mounted) {
        CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      }
      return;
    }
    final fullPath = _controller.fullPathOf(item);
    if ((item.attr.size ?? 0) > 1024 * 1024) {
      CustomToast.show(context, "파일이 너무 커서 편집할 수 없습니다.", isError: true);
      return;
    }
    try {
      final content = await ssh.readTextFile(fullPath);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FileEditorScreen(
            filePath: fullPath,
            initialContent: content,
          ),
        ),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "파일 열기 실패: $e", isError: true);
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

  Widget _buildSelectionToolbar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
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
            const SizedBox(width: 6),
            ActionChip(
              label: const Text("선택 해제"),
              onPressed: _controller.clearSelection,
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
      onGoHome: () => _controller.goHome().catchError((e) {
        if (mounted) {
          CustomToast.show(context, "이동 실패: $e", isError: true);
        }
      }),
      onGoUp: _controller.currentPath == '/'
          ? null
          : () => _controller.goUp().catchError((e) {
                if (mounted) {
                  CustomToast.show(context, "이동 실패: $e", isError: true);
                }
              }),
      onShowBookmarks: _showBookmarks,
      onToggleSearch: () {
        _controller.setSearching(!_controller.isSearching);
        if (!_controller.isSearching) {
          _searchController.clear();
        }
      },
      onToggleSelectionMode: () {
        if (_controller.selectionMode) {
          _controller.clearSelection();
        } else {
          _controller.enterSelectionMode();
        }
      },
      onCreateFolder: _createFolder,
      onCreateFile: _createFile,
      onUploadFiles: _uploadLocalFiles,
      onUploadFolder: _uploadLocalFolder,
      includeRootDirectoryOnUpload: _controller.includeRootDirectoryOnUpload,
      onToggleUploadRootDirectory: _toggleUploadRootDirectory,
      onToggleBatchPause: _controller.toggleBatchPause,
      onCancelBatch: _controller.cancelCurrentBatch,
      onRetryFailedTransfers: _retryFailedTransfers,
      onRefresh: _refresh,
      onSortSelected: _controller.setSortMode,
      onSearchChanged: _controller.updateSearchQuery,
      onSearchClose: () {
        _searchController.clear();
        _controller.setSearching(false);
      },
      selectionBar: _controller.selectionMode ? _buildSelectionToolbar() : null,
    );
  }

  Widget _buildBottomPathBar() {
    return FileExplorerBottomBar(
      controller: _controller,
      pathController: _pathController,
      pathFocusNode: _pathFocusNode,
      onGoBack: _controller.canGoBack
          ? () => _controller.goBack().catchError((e) {
                if (mounted) {
                  CustomToast.show(context, "이동 실패: $e", isError: true);
                }
              })
          : null,
      onGoForward: _controller.canGoForward
          ? () => _controller.goForward().catchError((e) {
                if (mounted) {
                  CustomToast.show(context, "이동 실패: $e", isError: true);
                }
              })
          : null,
      onNavigate: () => _navigateWithError(_pathController.text.trim()),
      onPaste: _controller.hasClipboard ? _pasteClipboard : null,
    );
  }

  Widget _buildFileList() {
    return FileExplorerFileListView(
      controller: _controller,
      onNavigateDirectory: _navigateWithError,
      onEditFile: _editFile,
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        _syncPathField();
        return Column(
          children: [
            _buildTopToolbar(),
            if (_controller.isLoading && _controller.visibleFiles.isNotEmpty)
              const LinearProgressIndicator(),
            Expanded(child: _buildFileList()),
            _buildBottomPathBar(),
          ],
        );
      },
    );
  }
}
