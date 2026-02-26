import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../constants.dart';
import '../../../services/ssh_service.dart';

enum FileSortMode { name, size, modified }

class FileDownloadSummary {
  final int success;
  final int failed;
  final int skipped;
  final String downloadDirectory;

  const FileDownloadSummary({
    required this.success,
    required this.failed,
    required this.skipped,
    required this.downloadDirectory,
  });
}

class FileUploadSummary {
  final int success;
  final int failed;
  final int skipped;
  final String remoteDirectory;

  const FileUploadSummary({
    required this.success,
    required this.failed,
    required this.skipped,
    required this.remoteDirectory,
  });
}

class FileExplorerController extends ChangeNotifier {
  static const String _bookmarkKey = 'file_bookmarks';
  static const Duration _progressEmitInterval = Duration(milliseconds: 120);

  SSHService? _ssh;
  bool _initialized = false;

  String _currentPath = CarrotConstants.openpilotPath;
  final List<SftpName> _files = [];
  final List<SftpName> _visibleFiles = [];
  bool _isLoading = false;
  bool _isBatchBusy = false;
  String _batchMessage = '';
  bool _isSearching = false;
  String _searchQuery = '';
  List<String> _bookmarks = [];
  final List<String> _backHistory = [];
  final List<String> _forwardHistory = [];
  bool _selectionMode = false;
  final Set<String> _selectedPaths = <String>{};
  bool _showHidden = false;
  FileSortMode _sortMode = FileSortMode.name;
  bool _sortAscending = true;
  final Set<String> _clipboardPaths = <String>{};
  bool _clipboardCut = false;
  DateTime _lastProgressEmittedAt = DateTime.fromMillisecondsSinceEpoch(0);

  SSHService? get ssh => _ssh;
  String get currentPath => _currentPath;
  List<SftpName> get visibleFiles => List.unmodifiable(_visibleFiles);
  bool get isLoading => _isLoading;
  bool get isBatchBusy => _isBatchBusy;
  String get batchMessage => _batchMessage;
  bool get isSearching => _isSearching;
  String get searchQuery => _searchQuery;
  List<String> get bookmarks => List.unmodifiable(_bookmarks);
  bool get canGoBack => _backHistory.isNotEmpty;
  bool get canGoForward => _forwardHistory.isNotEmpty;
  bool get selectionMode => _selectionMode;
  bool get showHidden => _showHidden;
  FileSortMode get sortMode => _sortMode;
  bool get sortAscending => _sortAscending;
  int get selectedCount => _selectedPaths.length;
  Set<String> get selectedPaths => Set.unmodifiable(_selectedPaths);
  bool get hasClipboard => _clipboardPaths.isNotEmpty;
  bool get clipboardIsCut => _clipboardCut;
  int get clipboardCount => _clipboardPaths.length;
  bool get isConnected => _ssh?.isConnected ?? false;

  void bindSsh(SSHService sshService) {
    if (identical(_ssh, sshService)) return;
    _ssh = sshService;
  }

  Future<void> initializeIfNeeded() async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    _bookmarks = prefs.getStringList(_bookmarkKey) ??
        <String>[CarrotConstants.openpilotPath, CarrotConstants.mediaPath];
    _applyVisibleFilter(notify: false);
    notifyListeners();
  }

  Future<void> ensureLoaded() async {
    if (_visibleFiles.isNotEmpty || _isLoading) return;
    if (!isConnected) return;
    await navigate(_currentPath, addToHistory: false);
  }

  void _assertSshReady() {
    if (_ssh == null || !_ssh!.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }
  }

  void _applyVisibleFilter({bool notify = true}) {
    final filtered = _files.where((item) {
      if (!_showHidden && item.filename.startsWith('.')) return false;
      if (_searchQuery.isEmpty) return true;
      return item.filename.toLowerCase().contains(_searchQuery);
    }).toList();

    int compareByMode(SftpName a, SftpName b) {
      switch (_sortMode) {
        case FileSortMode.size:
          final aSize = a.attr.size ?? 0;
          final bSize = b.attr.size ?? 0;
          return aSize.compareTo(bSize);
        case FileSortMode.modified:
          final aTime = a.attr.modifyTime ?? 0;
          final bTime = b.attr.modifyTime ?? 0;
          return aTime.compareTo(bTime);
        case FileSortMode.name:
          return a.filename.compareTo(b.filename);
      }
    }

    filtered.sort((a, b) {
      if (a.attr.isDirectory && !b.attr.isDirectory) return -1;
      if (!a.attr.isDirectory && b.attr.isDirectory) return 1;
      final result = compareByMode(a, b);
      return _sortAscending ? result : -result;
    });

    _visibleFiles
      ..clear()
      ..addAll(filtered);

    final visiblePathSet = _visibleFiles
        .map((f) => p.posix.join(_currentPath, f.filename))
        .toSet();
    _selectedPaths.removeWhere((path) => !visiblePathSet.contains(path));
    if (_selectedPaths.isEmpty) {
      _selectionMode = false;
    }

    if (notify) notifyListeners();
  }

  void setSearching(bool enabled) {
    _isSearching = enabled;
    if (!enabled) {
      _searchQuery = '';
    }
    _applyVisibleFilter();
  }

  void updateSearchQuery(String value) {
    _searchQuery = value.toLowerCase().trim();
    _applyVisibleFilter();
  }

  void toggleShowHidden() {
    _showHidden = !_showHidden;
    _applyVisibleFilter();
  }

  void setSortMode(FileSortMode mode) {
    if (_sortMode == mode) {
      _sortAscending = !_sortAscending;
    } else {
      _sortMode = mode;
      _sortAscending = true;
    }
    _applyVisibleFilter();
  }

  String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  Future<SSHCommandResult> _runCommand(
    String command, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    _assertSshReady();
    return _ssh!.executeCommandResult(command, timeout: timeout);
  }

  Future<void> navigate(
    String path, {
    bool addToHistory = true,
  }) async {
    _assertSshReady();
    final normalized = p.posix.normalize(path);
    _isLoading = true;
    notifyListeners();
    try {
      final listed = await _ssh!.listFiles(normalized);
      if (addToHistory && normalized != _currentPath) {
        _backHistory.add(_currentPath);
        _forwardHistory.clear();
      }
      _currentPath = normalized;
      _files
        ..clear()
        ..addAll(listed.where((f) => f.filename != '.' && f.filename != '..'));
      clearSelection(notify: false);
      _isLoading = false;
      _applyVisibleFilter(notify: false);
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> goBack() async {
    if (_backHistory.isEmpty) return;
    final target = _backHistory.removeLast();
    _forwardHistory.add(_currentPath);
    await navigate(target, addToHistory: false);
  }

  Future<void> goForward() async {
    if (_forwardHistory.isEmpty) return;
    final target = _forwardHistory.removeLast();
    _backHistory.add(_currentPath);
    await navigate(target, addToHistory: false);
  }

  Future<void> goHome() async {
    await navigate(CarrotConstants.openpilotPath);
  }

  Future<void> goUp() async {
    if (_currentPath == '/') return;
    await navigate(p.posix.dirname(_currentPath));
  }

  Future<void> refresh() async {
    await navigate(_currentPath, addToHistory: false);
  }

  Future<void> addBookmark() async {
    if (_bookmarks.contains(_currentPath)) return;
    _bookmarks = List<String>.from(_bookmarks)..add(_currentPath);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_bookmarkKey, _bookmarks);
    notifyListeners();
  }

  Future<void> removeBookmark(String path) async {
    _bookmarks = List<String>.from(_bookmarks)..remove(path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_bookmarkKey, _bookmarks);
    notifyListeners();
  }

  String fullPathOf(SftpName item) => p.posix.join(_currentPath, item.filename);

  bool isSelected(String fullPath) => _selectedPaths.contains(fullPath);

  void enterSelectionMode([String? fullPath]) {
    _selectionMode = true;
    if (fullPath != null) {
      _selectedPaths.add(fullPath);
    }
    notifyListeners();
  }

  void clearSelection({bool notify = true}) {
    _selectionMode = false;
    _selectedPaths.clear();
    if (notify) notifyListeners();
  }

  void toggleSelection(String fullPath) {
    if (_selectedPaths.contains(fullPath)) {
      _selectedPaths.remove(fullPath);
    } else {
      _selectedPaths.add(fullPath);
    }
    if (_selectedPaths.isEmpty) {
      _selectionMode = false;
    } else {
      _selectionMode = true;
    }
    notifyListeners();
  }

  void selectAllVisible() {
    _selectionMode = true;
    _selectedPaths
      ..clear()
      ..addAll(_visibleFiles.map((item) => fullPathOf(item)));
    notifyListeners();
  }

  SftpName? findByFullPath(String fullPath) {
    for (final item in _files) {
      if (p.posix.join(_currentPath, item.filename) == fullPath) {
        return item;
      }
    }
    return null;
  }

  Future<void> createDirectory(String name) async {
    final fullPath = p.posix.join(_currentPath, name);
    final result = await _runCommand("mkdir -p -- ${_shellQuote(fullPath)}");
    if (!result.isSuccess) {
      throw Exception(result.output.trim().isEmpty
          ? '폴더 생성 실패 (exit=${result.exitCode})'
          : result.output.trim());
    }
    await refresh();
  }

  Future<void> createFile(String name) async {
    final fullPath = p.posix.join(_currentPath, name);
    final result = await _runCommand("touch -- ${_shellQuote(fullPath)}");
    if (!result.isSuccess) {
      throw Exception(result.output.trim().isEmpty
          ? '파일 생성 실패 (exit=${result.exitCode})'
          : result.output.trim());
    }
    await refresh();
  }

  Future<void> rename(String oldPath, String newPath) async {
    _assertSshReady();
    await _ssh!.renameFile(oldPath, newPath);
    await refresh();
  }

  Future<void> changePermissions(String fullPath, String perms) async {
    final result = await _runCommand(
      "chmod $perms -- ${_shellQuote(fullPath)}",
    );
    if (!result.isSuccess) {
      throw Exception(result.output.trim().isEmpty
          ? '권한 변경 실패 (exit=${result.exitCode})'
          : result.output.trim());
    }
    await refresh();
  }

  Future<void> deletePaths(Set<String> paths) async {
    if (paths.isEmpty) return;
    final quoted = paths.map(_shellQuote).join(' ');
    final result = await _runCommand(
      "rm -rf -- $quoted",
      timeout: const Duration(minutes: 5),
    );
    if (!result.isSuccess) {
      throw Exception(result.output.trim().isEmpty
          ? '삭제 실패 (exit=${result.exitCode})'
          : result.output.trim());
    }
    clearSelection(notify: false);
    await refresh();
  }

  Future<void> copyToDirectory(Set<String> paths, String targetPath) async {
    if (paths.isEmpty) return;
    final sources = paths.map(_shellQuote).join(' ');
    final cmd =
        "mkdir -p -- ${_shellQuote(targetPath)} && cp -a -- $sources ${_shellQuote('$targetPath/')}";
    final result = await _runCommand(cmd, timeout: const Duration(minutes: 5));
    if (!result.isSuccess) {
      throw Exception(result.output.trim().isEmpty
          ? '복사 실패 (exit=${result.exitCode})'
          : result.output.trim());
    }
  }

  Future<void> compressSelected(String archiveName) async {
    if (_selectedPaths.isEmpty) return;
    final names = _selectedPaths.map((e) => p.posix.basename(e)).toList();
    final args = names.map(_shellQuote).join(' ');
    final cmd =
        "cd ${_shellQuote(_currentPath)} && tar -czf ${_shellQuote(archiveName)} -- $args";
    final result = await _runCommand(cmd, timeout: const Duration(minutes: 5));
    if (!result.isSuccess) {
      throw Exception(result.output.trim().isEmpty
          ? '압축 실패 (exit=${result.exitCode})'
          : result.output.trim());
    }
    clearSelection(notify: false);
    await refresh();
  }

  void setClipboard(Set<String> paths, {required bool cut}) {
    _clipboardPaths
      ..clear()
      ..addAll(paths);
    _clipboardCut = cut;
    notifyListeners();
  }

  void clearClipboard() {
    _clipboardPaths.clear();
    _clipboardCut = false;
    notifyListeners();
  }

  Future<void> pasteClipboardToCurrentPath() async {
    if (_clipboardPaths.isEmpty) return;
    final sources = _clipboardPaths.map(_shellQuote).join(' ');
    final dest = _shellQuote('$_currentPath/');
    final command =
        _clipboardCut ? "mv -- $sources $dest" : "cp -a -- $sources $dest";
    final result =
        await _runCommand(command, timeout: const Duration(minutes: 5));
    if (!result.isSuccess) {
      throw Exception(result.output.trim().isEmpty
          ? '붙여넣기 실패 (exit=${result.exitCode})'
          : result.output.trim());
    }
    if (_clipboardCut) {
      clearClipboard();
    }
    await refresh();
  }

  Future<Directory> _resolveDownloadDir() async {
    final preferred = Directory('/storage/emulated/0/CarrotLink/downloads');
    try {
      if (!await preferred.exists()) {
        await preferred.create(recursive: true);
      }
      return preferred;
    } catch (_) {
      final docs = await getApplicationDocumentsDirectory();
      final fallback = Directory('${docs.path}/downloads');
      if (!await fallback.exists()) {
        await fallback.create(recursive: true);
      }
      return fallback;
    }
  }

  String _ensureUniqueLocalPath(String directoryPath, String fileName) {
    final ext = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    var index = 0;
    while (true) {
      final name = index == 0 ? fileName : '$stem($index)$ext';
      final candidate = p.join(directoryPath, name);
      if (!File(candidate).existsSync()) {
        return candidate;
      }
      index += 1;
    }
  }

  String _buildTempArchivePath(String baseName) {
    final now = DateTime.now();
    final stamp =
        "${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}";
    return "/tmp/carrotlink_${baseName}_$stamp.tar.gz";
  }

  bool _shouldEmitProgressNow() {
    final now = DateTime.now();
    if (now.difference(_lastProgressEmittedAt) >= _progressEmitInterval) {
      _lastProgressEmittedAt = now;
      return true;
    }
    return false;
  }

  Future<FileDownloadSummary> downloadPaths(Set<String> remotePaths) async {
    _assertSshReady();
    if (remotePaths.isEmpty) {
      return const FileDownloadSummary(
        success: 0,
        failed: 0,
        skipped: 0,
        downloadDirectory: '',
      );
    }

    final downloadDir = await _resolveDownloadDir();
    var success = 0;
    var failed = 0;
    var skipped = 0;

    _isBatchBusy = true;
    _batchMessage = '다운로드 준비 중...';
    _lastProgressEmittedAt = DateTime.fromMillisecondsSinceEpoch(0);
    notifyListeners();

    for (final remotePath in remotePaths) {
      final item = findByFullPath(remotePath);
      final isDirectory = item != null && item.attr.isDirectory;
      final itemName = p.posix.basename(remotePath);
      String downloadTargetPath = remotePath;
      String localFileName = itemName;
      String? tempArchivePath;

      if (isDirectory) {
        tempArchivePath = _buildTempArchivePath(itemName);
        localFileName = "$itemName.tar.gz";
        final parent = p.posix.dirname(remotePath);
        final cmd =
            "tar -czf ${_shellQuote(tempArchivePath)} -C ${_shellQuote(parent)} ${_shellQuote(itemName)}";
        final tarResult = await _runCommand(
          cmd,
          timeout: const Duration(minutes: 15),
        );
        if (!tarResult.isSuccess) {
          failed += 1;
          continue;
        }
        downloadTargetPath = tempArchivePath;
      }

      final localPath = _ensureUniqueLocalPath(downloadDir.path, localFileName);
      try {
        await _ssh!.downloadBinaryFile(
          downloadTargetPath,
          localPath,
          onProgress: (received, total) {
            if (_shouldEmitProgressNow()) {
              final pct =
                  total > 0 ? (received * 100 / total).toStringAsFixed(0) : '?';
              _batchMessage = '다운로드 중: $localFileName ($pct%)';
              notifyListeners();
            }
          },
        );
        success += 1;
      } catch (_) {
        failed += 1;
      } finally {
        if (tempArchivePath != null) {
          await _runCommand("rm -f -- ${_shellQuote(tempArchivePath)}");
        }
      }
    }

    _isBatchBusy = false;
    _batchMessage = '';
    notifyListeners();

    return FileDownloadSummary(
      success: success,
      failed: failed,
      skipped: skipped,
      downloadDirectory: downloadDir.path,
    );
  }

  Future<FileUploadSummary> uploadLocalFiles(List<String> localPaths) async {
    _assertSshReady();
    if (localPaths.isEmpty) {
      return FileUploadSummary(
        success: 0,
        failed: 0,
        skipped: 0,
        remoteDirectory: _currentPath,
      );
    }

    var success = 0;
    var failed = 0;
    var skipped = 0;

    _isBatchBusy = true;
    _batchMessage = '업로드 준비 중...';
    _lastProgressEmittedAt = DateTime.fromMillisecondsSinceEpoch(0);
    notifyListeners();

    for (final localPath in localPaths) {
      final local = File(localPath);
      if (!await local.exists()) {
        skipped += 1;
        continue;
      }

      final fileName = p.basename(localPath);
      final remotePath = p.posix.join(_currentPath, fileName);
      try {
        await _ssh!.uploadBinaryFile(
          localPath,
          remotePath,
          onProgress: (sent, total) {
            if (_shouldEmitProgressNow()) {
              final pct =
                  total > 0 ? (sent * 100 / total).toStringAsFixed(0) : '?';
              _batchMessage = '업로드 중: $fileName ($pct%)';
              notifyListeners();
            }
          },
        );
        success += 1;
      } catch (_) {
        failed += 1;
      }
    }

    _isBatchBusy = false;
    _batchMessage = '';
    notifyListeners();
    await refresh();

    return FileUploadSummary(
      success: success,
      failed: failed,
      skipped: skipped,
      remoteDirectory: _currentPath,
    );
  }

  Future<FileUploadSummary> uploadLocalDirectory(
    String localDirectoryPath, {
    bool includeRootDirectory = true,
  }) async {
    _assertSshReady();
    final rootDir = Directory(localDirectoryPath);
    if (!await rootDir.exists()) {
      throw Exception('로컬 폴더를 찾을 수 없습니다: $localDirectoryPath');
    }

    final rootName = p.basename(rootDir.path);
    final remoteRoot = includeRootDirectory
        ? p.posix.join(_currentPath, rootName)
        : _currentPath;

    var success = 0;
    var failed = 0;
    var skipped = 0;

    _isBatchBusy = true;
    _batchMessage = '폴더 업로드 준비 중...';
    _lastProgressEmittedAt = DateTime.fromMillisecondsSinceEpoch(0);
    notifyListeners();

    try {
      final mkdirRoot =
          await _runCommand("mkdir -p -- ${_shellQuote(remoteRoot)}");
      if (!mkdirRoot.isSuccess) {
        throw Exception(
          mkdirRoot.output.trim().isEmpty
              ? '원격 폴더 생성 실패 (exit=${mkdirRoot.exitCode})'
              : mkdirRoot.output.trim(),
        );
      }

      await for (final entity
          in rootDir.list(recursive: true, followLinks: false)) {
        final relative = p.relative(entity.path, from: rootDir.path);
        if (relative == '.' || relative.isEmpty) {
          continue;
        }
        final relativePosix = relative.replaceAll('\\', '/');
        final remotePath = p.posix.join(remoteRoot, relativePosix);

        if (entity is Directory) {
          final mkdir =
              await _runCommand("mkdir -p -- ${_shellQuote(remotePath)}");
          if (!mkdir.isSuccess) {
            failed += 1;
          }
          continue;
        }

        if (entity is! File) {
          skipped += 1;
          continue;
        }

        try {
          await _ssh!.uploadBinaryFile(
            entity.path,
            remotePath,
            onProgress: (sent, total) {
              if (_shouldEmitProgressNow()) {
                final pct =
                    total > 0 ? (sent * 100 / total).toStringAsFixed(0) : '?';
                _batchMessage = '업로드 중: $relativePosix ($pct%)';
                notifyListeners();
              }
            },
          );
          success += 1;
        } catch (_) {
          failed += 1;
        }
      }
    } finally {
      _isBatchBusy = false;
      _batchMessage = '';
      notifyListeners();
    }

    await refresh();
    return FileUploadSummary(
      success: success,
      failed: failed,
      skipped: skipped,
      remoteDirectory: remoteRoot,
    );
  }
}
