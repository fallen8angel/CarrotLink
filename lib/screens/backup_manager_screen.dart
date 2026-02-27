import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;
import 'package:googleapis/drive/v3.dart' as drive;
import '../../services/ssh_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/backup_service.dart';
import '../../services/carrot_server_settings_service.dart';

class BackupManagerScreen extends StatefulWidget {
  const BackupManagerScreen({super.key});

  @override
  State<BackupManagerScreen> createState() => _BackupManagerScreenState();
}

class _BackupManagerScreenState extends State<BackupManagerScreen>
    with SingleTickerProviderStateMixin {
  static const int _paramsChunkSize = 80;
  final CarrotServerSettingsService _carrotServer =
      CarrotServerSettingsService();

  late TabController _tabController;

  // Local Backups State
  List<FileSystemEntity> _localBackups = [];
  bool _isLocalLoading = false;
  bool _localSortAscending = false;
  File? _comparingFile;
  String? _lastRestoredPath;
  final Set<String> _selectedLocalPaths = {};

  // Cloud Backups State
  List<drive.File> _cloudBackups = [];
  bool _isCloudLoading = false;
  bool _cloudSortAscending = false;
  final Set<String> _selectedCloudIds = {};

  // Common State
  bool _isSelectionMode = false;
  StreamSubscription? _backupSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabSelection);

    _loadLastRestored();
    _loadLocalBackups();
    // Cloud backups are loaded when tab is switched or manually refreshed to save API calls,
    // but we can load them initially if signed in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final driveService =
          Provider.of<GoogleDriveService>(context, listen: false);
      if (driveService.currentUser != null) {
        _loadCloudBackups();
        final backupService =
            Provider.of<BackupService>(context, listen: false);
        backupService.syncBackups(driveService);
      }
    });

    final backupService = Provider.of<BackupService>(context, listen: false);
    _backupSubscription = backupService.onBackupComplete.listen((_) {
      _loadLocalBackups();
      // Removed automatic snackbar to reduce annoyance
    });
  }

  void _handleTabSelection() {
    if (_tabController.indexIsChanging) {
      setState(() {
        _isSelectionMode = false;
        _selectedLocalPaths.clear();
        _selectedCloudIds.clear();
      });
      // Load cloud backups if switching to cloud tab and list is empty
      if (_tabController.index == 1 && _cloudBackups.isEmpty) {
        _loadCloudBackups();
      }
    } else {
      // Update UI when tab settles (for AppBar actions)
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _backupSubscription?.cancel();
    super.dispose();
  }

  // --- Local Backup Methods ---

  Future<void> _loadLocalBackups() async {
    if (_localBackups.isEmpty) setState(() => _isLocalLoading = true);
    try {
      final backupService = Provider.of<BackupService>(context, listen: false);
      _localBackups = await backupService.listLocalBackupFiles();
      _sortLocalBackups();
    } catch (e) {
      print("Error loading local backups: $e");
    } finally {
      if (mounted) setState(() => _isLocalLoading = false);
    }
  }

  void _sortLocalBackups() {
    _localBackups.sort((a, b) {
      final nameA = path.basename(a.path);
      final nameB = path.basename(b.path);
      // Sort by filename (which starts with timestamp)
      return _localSortAscending
          ? nameA.compareTo(nameB)
          : nameB.compareTo(nameA);
    });
  }

  Future<void> _deleteSelectedLocalBackups() async {
    if (_selectedLocalPaths.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("선택 삭제"),
        content: Text("${_selectedLocalPaths.length}개의 로컬 백업을 삭제하시겠습니까?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("취소")),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("삭제")),
        ],
      ),
    );

    if (confirm == true) {
      int deletedCount = 0;
      final driveService =
          Provider.of<GoogleDriveService>(context, listen: false);
      final pathsToDelete = List<String>.from(_selectedLocalPaths);

      // 1. Delete local files immediately and update UI
      for (final pathStr in pathsToDelete) {
        try {
          final file = File(pathStr);
          if (await file.exists()) {
            await file.delete();
            deletedCount++;
          }
        } catch (e) {
          print("Error deleting local file $pathStr: $e");
        }
      }

      // Update UI immediately
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("$deletedCount개 삭제 완료. 클라우드 동기화 중...")));
        _toggleSelectionMode();
        _loadLocalBackups(); // Reload local list
      }

      // 2. Sync delete to cloud in background
      if (driveService.currentUser != null) {
        try {
          final cloudFiles = await driveService.listFiles();
          final futures = <Future>[];

          for (final pathStr in pathsToDelete) {
            final filename = path.basename(pathStr);
            try {
              final cloudFile = cloudFiles.firstWhere((f) => f.name == filename,
                  orElse: () => drive.File());
              if (cloudFile.id != null) {
                futures.add(driveService.deleteFile(cloudFile.id!));
              }
            } catch (_) {}
          }

          if (futures.isNotEmpty) {
            await Future.wait(futures);
            if (mounted) {
              // Optional: Notify when cloud sync is done
              // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("클라우드 동기화 완료")));
            }
          }
        } catch (e) {
          print("Cloud sync error: $e");
        }
      }
    }
  }

  // --- Cloud Backup Methods ---

  Future<void> _loadCloudBackups() async {
    setState(() => _isCloudLoading = true);
    try {
      final driveService =
          Provider.of<GoogleDriveService>(context, listen: false);
      if (driveService.currentUser == null) {
        _cloudBackups = [];
        return;
      }
      final files = await driveService.listFiles();
      _cloudBackups = files;
      _sortCloudBackups();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("클라우드 로드 실패: $e")));
    } finally {
      if (mounted) setState(() => _isCloudLoading = false);
    }
  }

  void _sortCloudBackups() {
    _cloudBackups.sort((a, b) {
      final nameA = a.name ?? "";
      final nameB = b.name ?? "";
      // Sort by filename (which starts with timestamp)
      return _cloudSortAscending
          ? nameA.compareTo(nameB)
          : nameB.compareTo(nameA);
    });
  }

  Future<void> _deleteSelectedCloudBackups() async {
    if (_selectedCloudIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("선택 삭제"),
        content: Text("${_selectedCloudIds.length}개의 클라우드 백업을 삭제하시겠습니까?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("취소")),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("삭제")),
        ],
      ),
    );

    if (confirm == true) {
      final driveService =
          Provider.of<GoogleDriveService>(context, listen: false);
      final idsToDelete = List<String>.from(_selectedCloudIds);

      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("삭제 중...")));

      // Optimistic UI Update: Remove from list immediately
      setState(() {
        _cloudBackups
            .removeWhere((f) => f.id != null && idsToDelete.contains(f.id));
        _toggleSelectionMode(); // Exit selection mode
      });

      // Perform deletion in background (parallel)
      try {
        final futures = idsToDelete.map((id) => driveService.deleteFile(id));
        await Future.wait(futures);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("${idsToDelete.length}개 삭제 완료")));
        }
      } catch (e) {
        print("Error deleting cloud files: $e");
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text("일부 파일 삭제 실패: $e")));
          _loadCloudBackups(); // Revert/Reload on error
        }
      }
    }
  }

  // --- Common Methods ---

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      _selectedLocalPaths.clear();
      _selectedCloudIds.clear();
    });
  }

  void _toggleLocalSelection(String path) {
    setState(() {
      if (_selectedLocalPaths.contains(path)) {
        _selectedLocalPaths.remove(path);
      } else {
        _selectedLocalPaths.add(path);
      }
    });
  }

  void _toggleCloudSelection(String id) {
    setState(() {
      if (_selectedCloudIds.contains(id)) {
        _selectedCloudIds.remove(id);
      } else {
        _selectedCloudIds.add(id);
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (_tabController.index == 0) {
        _selectedLocalPaths.clear();
        for (var file in _localBackups) {
          _selectedLocalPaths.add(file.path);
        }
      } else {
        _selectedCloudIds.clear();
        for (var file in _cloudBackups) {
          if (file.id != null) _selectedCloudIds.add(file.id!);
        }
      }
    });
  }

  void _deselectAll() {
    setState(() {
      if (_tabController.index == 0) {
        _selectedLocalPaths.clear();
      } else {
        _selectedCloudIds.clear();
      }
    });
  }

  // ... Existing helper methods (_loadLastRestored, _setLastRestored, _createBackup, _deleteBackup, _restoreWithDiff, _performRestore, _uploadToDrive, _handleDriveConnection, _showBackupContents, _deleteCloudFile, _parseBackupInfo, _formatBackupName, _downloadFromDrive) ...
  // I need to keep these methods. I will copy them from the previous file content or just reference them if I'm using replace_string_in_file carefully.
  // Since I'm replacing the whole class structure, I need to include them.

  Future<void> _loadLastRestored() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _lastRestoredPath = prefs.getString('last_restored_backup');
    });
  }

  Future<void> _setLastRestored(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_restored_backup', path);
    setState(() {
      _lastRestoredPath = path;
    });
  }

  Future<void> _createBackup() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    final backupService = Provider.of<BackupService>(context, listen: false);
    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);

    if (!ssh.isConnected) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("연결되지 않음")));
      return;
    }
    backupService.createBackup(ssh, driveService);
  }

  Future<void> _deleteBackup(File file) async {
    try {
      final filename = path.basename(file.path);
      await file.delete();

      final driveService =
          Provider.of<GoogleDriveService>(context, listen: false);
      if (driveService.currentUser != null) {
        try {
          final files = await driveService.listFiles();
          final cloudFile = files.firstWhere((f) => f.name == filename,
              orElse: () => drive.File());
          if (cloudFile.id != null) {
            await driveService.deleteFile(cloudFile.id!);
            if (mounted)
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("클라우드 파일도 삭제되었습니다.")));
          }
        } catch (e) {
          print("Cloud delete sync failed: $e");
        }
      }

      await _loadLocalBackups();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("삭제되었습니다.")));
    } catch (e) {
      print("Delete error: $e");
    }
  }

  Future<void> _restoreWithDiff(File file) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("연결되지 않음")));
      return;
    }
    final host = _resolveTargetHost(ssh);
    if (host == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("대상 IP를 확인할 수 없습니다.")));
      return;
    }

    setState(() => _comparingFile = file);

    try {
      final content = await file.readAsString();
      final Map<String, dynamic> backupParams =
          Map<String, dynamic>.from(jsonDecode(content) as Map);
      final keys = backupParams.keys.toList();
      final currentParams = await _fetchCurrentParamsInChunks(host, keys);

      final List<Map<String, String>> diffs = [];
      for (final key in keys) {
        final backupVal = backupParams[key];
        final currentVal = currentParams[key];

        if (!_isSameValue(backupVal, currentVal)) {
          diffs.add({
            'key': key,
            'backup': _displayValue(backupVal),
            'current': _displayValue(currentVal),
          });
        }
      }

      if (mounted) {
        setState(() => _comparingFile = null);

        if (diffs.isEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text("변경된 설정이 없습니다.")));
          return;
        }

        showDialog(
          context: context,
          builder: (context) => _DiffRestoreDialog(
              diffs: diffs,
              onRestore: (selectedKeys) async {
                Navigator.pop(context);
                await _performRestore(
                  backupParams,
                  selectedKeys,
                  host: host,
                  restoredPath: file.path,
                );
              }),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _comparingFile = null);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("비교 실패: $e")));
      }
    }
  }

  Future<void> _performRestore(
      Map<String, dynamic> backupParams, List<String> keysToRestore,
      {required String host, String? restoredPath}) async {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text("복원 시작...")));

    try {
      int successCount = 0;
      for (final key in keysToRestore) {
        if (!backupParams.containsKey(key)) continue;
        final value = backupParams[key];
        await _carrotServer.setParam(host, name: key, value: value);
        successCount++;
      }

      if (restoredPath != null && restoredPath.isNotEmpty) {
        await _setLastRestored(restoredPath);
      }

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("$successCount개 항목 복원 완료")));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("복원 실패: $e")));
      }
    }
  }

  String? _resolveTargetHost(SSHService ssh) {
    final connected = ssh.connectedIp?.trim();
    if (connected != null && connected.isNotEmpty) {
      return connected;
    }
    final target = ssh.targetIp?.trim();
    if (target != null && target.isNotEmpty) {
      return target;
    }
    return null;
  }

  Future<Map<String, dynamic>> _fetchCurrentParamsInChunks(
      String host, List<String> keys) async {
    if (keys.isEmpty) return const {};
    final out = <String, dynamic>{};
    for (var i = 0; i < keys.length; i += _paramsChunkSize) {
      final end = (i + _paramsChunkSize > keys.length)
          ? keys.length
          : i + _paramsChunkSize;
      final chunk = keys.sublist(i, end);
      final values = await _carrotServer.fetchParamsBulk(host, chunk);
      out.addAll(values);
    }
    return out;
  }

  bool _isSameValue(dynamic a, dynamic b) {
    return _normalizeValue(a) == _normalizeValue(b);
  }

  String _normalizeValue(dynamic value) {
    if (value == null) return '';
    final raw = value.toString().trim();
    if (raw.isEmpty) return '';

    final lower = raw.toLowerCase();
    if (lower == 'true') return '1';
    if (lower == 'false') return '0';

    final asNum = num.tryParse(raw);
    if (asNum != null) {
      if (asNum == asNum.roundToDouble()) {
        return asNum.toInt().toString();
      }
      return asNum.toString();
    }
    return raw;
  }

  String _displayValue(dynamic value) {
    if (value == null) return "(없음)";
    final text = value.toString();
    if (text.trim().isEmpty) return "(빈값)";
    return text;
  }

  Future<void> _uploadToDrive(File file) async {
    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text("구글 드라이브 업로드 중...")));
    try {
      await driveService.uploadFile(file);
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("업로드 완료")));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("업로드 실패: $e")));
    }
  }

  Future<void> _showBackupContents(File file) async {
    try {
      final content = await file.readAsString();
      final Map<String, dynamic> data = jsonDecode(content);
      final keys = data.keys.toList()..sort();

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_formatBackupName(path.basename(file.path))),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("총 ${keys.length}개 항목"),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    itemCount: keys.length,
                    itemBuilder: (context, index) {
                      final key = keys[index];
                      final value = data[key];
                      return ListTile(
                        title: Text(key,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold)),
                        subtitle: Text(value.toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12)),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("닫기")),
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("파일 읽기 실패: $e")));
    }
  }

  Future<void> _downloadFromDrive(String fileId, String fileName) async {
    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    final backupService = Provider.of<BackupService>(context, listen: false);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text("다운로드 중...")));
    try {
      final savePath =
          await backupService.buildLocalBackupPathForFileName(fileName);
      await driveService.downloadFile(fileId, savePath);
      await _loadLocalBackups();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("다운로드 완료")));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("다운로드 실패: $e")));
    }
  }

  Future<void> _deleteCloudFile(String fileId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("삭제 확인"),
        content: const Text("정말 삭제하시겠습니까?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("취소")),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("삭제")),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final driveService =
            Provider.of<GoogleDriveService>(context, listen: false);
        await driveService.deleteFile(fileId);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text("삭제되었습니다.")));
          _loadCloudBackups();
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text("삭제 실패: $e")));
      }
    }
  }

  Map<String, dynamic> _parseBackupInfo(String name) {
    String dateStr = "";
    String branchName = "";
    bool isAuto = name.contains("_auto.json");

    String nameForParsing =
        name.replaceAll('.json', '').replaceAll('_auto', '');

    if (name.startsWith("backup_")) {
      final parts = nameForParsing.split('_');
      if (parts.length >= 3) {
        dateStr = "${parts[1]}${parts[2]}";
        if (parts.length > 3) branchName = parts.sublist(3).join('_');
      }
    } else {
      // New format: branch-yyyymmddHHmm(.json)
      final branchRegex = RegExp(r'^(.+)-(\d{12,14})(?:-\d+)?$');
      final branchMatch = branchRegex.firstMatch(nameForParsing);
      if (branchMatch != null) {
        branchName = branchMatch.group(1)!;
        dateStr = branchMatch.group(2)!;
      }

      // Match 12 or 14 digits
      if (dateStr.isEmpty) {
        final regex = RegExp(r'^(\d{12,14})\((.*)\)$');
        final match = regex.firstMatch(nameForParsing);
        if (match != null) {
          dateStr = match.group(1)!;
          branchName = match.group(2)!;
        } else {
          final dateRegex = RegExp(r'^(\d{12,14})');
          final dateMatch = dateRegex.firstMatch(nameForParsing);
          if (dateMatch != null) {
            dateStr = dateMatch.group(1)!;
          }
        }
      }
    }

    String displayName = name;
    try {
      if (dateStr.length == 14) {
        String yy = dateStr.substring(2, 4);
        String mm = dateStr.substring(4, 6);
        String dd = dateStr.substring(6, 8);
        String hh = dateStr.substring(8, 10);
        String min = dateStr.substring(10, 12);
        String sec = dateStr.substring(12, 14);
        displayName = "$yy년 $mm월 $dd일 $hh시 $min분 $sec초";
      } else if (dateStr.length == 12) {
        String yy = dateStr.substring(2, 4);
        String mm = dateStr.substring(4, 6);
        String dd = dateStr.substring(6, 8);
        String hh = dateStr.substring(8, 10);
        String min = dateStr.substring(10, 12);
        displayName = "$yy년 $mm월 $dd일 $hh시 $min분";
      } else if (dateStr.length == 14 ||
          (dateStr.length == 15 && dateStr.contains('_'))) {
        String cleanDate = dateStr.replaceAll('_', '');
        if (cleanDate.length >= 12) {
          String yy = cleanDate.substring(2, 4);
          String mm = cleanDate.substring(4, 6);
          String dd = cleanDate.substring(6, 8);
          String hh = cleanDate.substring(8, 10);
          String min = cleanDate.substring(10, 12);
          displayName = "$yy년 $mm월 $dd일 $hh시 $min분";
        }
      }
    } catch (e) {
      displayName = name;
    }

    return {
      'displayName': displayName,
      'branch': branchName,
      'isAuto': isAuto,
    };
  }

  String _formatBackupName(String name) {
    final info = _parseBackupInfo(name);
    String result = info['branch'].isNotEmpty
        ? "${info['displayName']} (${info['branch']})"
        : info['displayName'];

    if (info['isAuto']) {
      result += " [자동]";
    }
    return result;
  }

  Future<void> _handleDriveConnection() async {
    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    if (driveService.currentUser == null) {
      await driveService.signIn();
    } else {
      await driveService.signOut();
    }
    setState(() {});
    if (driveService.currentUser != null) {
      _loadCloudBackups();
    }
  }

  @override
  Widget build(BuildContext context) {
    final driveService = Provider.of<GoogleDriveService>(context);
    final backupService = Provider.of<BackupService>(context);
    final isSignedIn = driveService.currentUser != null;
    final isLocalTab = _tabController.index == 0;

    final selectedCount =
        isLocalTab ? _selectedLocalPaths.length : _selectedCloudIds.length;
    final totalCount = isLocalTab ? _localBackups.length : _cloudBackups.length;

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_isSelectionMode) {
          _toggleSelectionMode();
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            NestedScrollView(
              headerSliverBuilder: (context, innerBoxIsScrolled) {
                return [
                  SliverAppBar.medium(
                    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                    scrolledUnderElevation: 0,
                    title: Text(
                      _isSelectionMode ? "$selectedCount개 선택됨" : "백업 관리",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    leading: _isSelectionMode
                        ? IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: _toggleSelectionMode)
                        : const BackButton(),
                    actions: [
                      if (_isSelectionMode) ...[
                        IconButton(
                          icon: const Icon(Icons.select_all),
                          onPressed: selectedCount == totalCount
                              ? _deselectAll
                              : _selectAll,
                          tooltip: "전체 선택/해제",
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: selectedCount == 0
                              ? null
                              : (isLocalTab
                                  ? _deleteSelectedLocalBackups
                                  : _deleteSelectedCloudBackups),
                          tooltip: "선택 삭제",
                        ),
                      ] else ...[
                        IconButton(
                          icon: const Icon(Icons.checklist),
                          onPressed: _toggleSelectionMode,
                          tooltip: "선택 모드",
                        ),
                        if (!isLocalTab)
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: _loadCloudBackups,
                            tooltip: "새로고침",
                          ),
                      ],
                    ],
                  ),
                  SliverPersistentHeader(
                    delegate: _SliverTabBarDelegate(
                      TabBar(
                        controller: _tabController,
                        labelColor: Theme.of(context).colorScheme.primary,
                        unselectedLabelColor:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                        indicatorSize: TabBarIndicatorSize.label,
                        tabs: const [
                          Tab(text: "로컬 저장소"),
                          Tab(text: "구글 드라이브"),
                        ],
                      ),
                    ),
                    pinned: true,
                  ),
                  SliverToBoxAdapter(
                    child: _buildSortHeader(backupService, isLocalTab),
                  ),
                ];
              },
              body: Stack(
                children: [
                  TabBarView(
                    controller: _tabController,
                    children: [
                      _buildLocalList(),
                      _buildCloudList(isSignedIn),
                    ],
                  ),
                  // Loading Overlay (Prevents layout shift)
                  if (backupService.isBackingUp)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(
                          value: backupService.progress),
                    ),
                ],
              ),
            ),
            if (backupService.isBackingUp)
              Positioned(
                top: MediaQuery.of(context).padding.top + 10,
                left: 16,
                right: 16,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF333333).withOpacity(0.95),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            )),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            backupService.statusMessage,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        floatingActionButton: isLocalTab
            ? FloatingActionButton.extended(
                onPressed: backupService.isBackingUp ? null : _createBackup,
                icon: const Icon(Icons.add),
                label: const Text("백업 생성"),
              )
            : null,
      ),
    );
  }

  Widget _buildSortHeader(BackupService backupService, bool isLocalTab) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left: Last Check Time
          if (backupService.lastCheckTime != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.access_time,
                      size: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    "확인: ${DateFormat('HH:mm:ss').format(backupService.lastCheckTime!)}",
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          else
            const SizedBox(),

          // Right: Sort Button
          TextButton.icon(
            onPressed: _isSelectionMode
                ? null
                : () {
                    setState(() {
                      if (isLocalTab) {
                        _localSortAscending = !_localSortAscending;
                        _sortLocalBackups();
                      } else {
                        _cloudSortAscending = !_cloudSortAscending;
                        _sortCloudBackups();
                      }
                    });
                  },
            icon: Icon(
                (isLocalTab ? _localSortAscending : _cloudSortAscending)
                    ? Icons.arrow_upward
                    : Icons.arrow_downward,
                size: 16),
            label: Text((isLocalTab ? _localSortAscending : _cloudSortAscending)
                ? "오래된 순"
                : "최신 순"),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalList() {
    if (_isLocalLoading)
      return const Center(child: CircularProgressIndicator());
    if (_localBackups.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_off,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text("백업 기록이 없습니다.",
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 80), // Space for FAB
      itemCount: _localBackups.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final file = _localBackups[index] as File;
        final name = path.basename(file.path);

        final info = _parseBackupInfo(name);
        final displayName = info['displayName'];
        final branch = info['branch'];
        final isAuto = info['isAuto'];

        final isComparing = _comparingFile == file;
        final isLastRestored = _lastRestoredPath == file.path;
        final isSelected = _selectedLocalPaths.contains(file.path);
        final isSignedIn =
            Provider.of<GoogleDriveService>(context).currentUser != null;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            elevation: 0,
            color: isSelected
                ? Theme.of(context).colorScheme.secondaryContainer
                : Theme.of(context).colorScheme.surfaceContainer,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: isSelected
                  ? BorderSide(
                      color: Theme.of(context).colorScheme.primary, width: 2)
                  : BorderSide.none,
            ),
            child: InkWell(
              onTap: _isSelectionMode
                  ? () => _toggleLocalSelection(file.path)
                  : () => _showBackupContents(file),
              onLongPress: () {
                if (!_isSelectionMode) {
                  _toggleSelectionMode();
                  _toggleLocalSelection(file.path);
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    // Icon / Checkbox
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: isLastRestored
                            ? Colors.green.withOpacity(0.2)
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: _isSelectionMode
                          ? Checkbox(
                              value: isSelected,
                              onChanged: (val) =>
                                  _toggleLocalSelection(file.path),
                            )
                          : Icon(
                              isLastRestored
                                  ? Icons.check_circle
                                  : Icons.description,
                              color: isLastRestored
                                  ? Colors.green
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            ),
                    ),
                    const SizedBox(width: 16),
                    // Content
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: isLastRestored ? Colors.green : null,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              if (branch.isNotEmpty)
                                Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(branch,
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant)),
                                ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isAuto
                                      ? Colors.orange.withOpacity(0.2)
                                      : Colors.blue.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(isAuto ? "자동" : "수동",
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: isAuto
                                            ? Colors.orange
                                            : Colors.blue,
                                        fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 8),
                              FutureBuilder<String>(
                                future: file.length().then((len) =>
                                    "${(len / 1024).toStringAsFixed(1)} KB"),
                                builder: (context, snapshot) => Text(
                                    snapshot.data ?? "...",
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Actions
                    if (!_isSelectionMode)
                      isComparing
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert),
                              onSelected: (value) {
                                if (value == 'upload') {
                                  if (isSignedIn) {
                                    _uploadToDrive(file);
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                            content: Text("구글 로그인 필요")));
                                  }
                                } else if (value == 'restore') {
                                  _restoreWithDiff(file);
                                } else if (value == 'delete') {
                                  _deleteBackup(file);
                                }
                              },
                              itemBuilder: (BuildContext context) =>
                                  <PopupMenuEntry<String>>[
                                PopupMenuItem<String>(
                                  value: 'upload',
                                  enabled: isSignedIn,
                                  child: const Row(
                                    children: [
                                      Icon(Icons.cloud_upload, size: 20),
                                      SizedBox(width: 12),
                                      Text('업로드'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem<String>(
                                  value: 'restore',
                                  child: Row(
                                    children: [
                                      Icon(Icons.restore, size: 20),
                                      SizedBox(width: 12),
                                      Text('복원 (비교)'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem<String>(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      Icon(Icons.delete_outline,
                                          color: Colors.red, size: 20),
                                      SizedBox(width: 12),
                                      Text('삭제',
                                          style: TextStyle(color: Colors.red)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCloudList(bool isSignedIn) {
    if (!isSignedIn) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            const Text("구글 드라이브에 연결되어 있지 않습니다."),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _handleDriveConnection,
              icon: const Icon(Icons.login),
              label: const Text("연결하기"),
            ),
          ],
        ),
      );
    }

    if (_isCloudLoading)
      return const Center(child: CircularProgressIndicator());
    if (_cloudBackups.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_queue,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text("클라우드 백업이 없습니다.",
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: _cloudBackups.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final file = _cloudBackups[index];
        final info = _parseBackupInfo(file.name ?? "Unknown");
        final displayName = info['displayName'];
        final branch = info['branch'];
        final isAuto = info['isAuto'];
        final isSelected = _selectedCloudIds.contains(file.id);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            elevation: 0,
            color: isSelected
                ? Theme.of(context).colorScheme.secondaryContainer
                : Theme.of(context).colorScheme.surfaceContainer,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: isSelected
                  ? BorderSide(
                      color: Theme.of(context).colorScheme.primary, width: 2)
                  : BorderSide.none,
            ),
            child: InkWell(
              onTap: _isSelectionMode
                  ? () => _toggleCloudSelection(file.id!)
                  : null,
              onLongPress: () {
                if (!_isSelectionMode) {
                  _toggleSelectionMode();
                  _toggleCloudSelection(file.id!);
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: _isSelectionMode
                          ? Checkbox(
                              value: isSelected,
                              onChanged: (val) =>
                                  _toggleCloudSelection(file.id!),
                            )
                          : Icon(
                              Icons.cloud,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              if (branch.isNotEmpty)
                                Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(branch,
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant)),
                                ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isAuto
                                      ? Colors.orange.withOpacity(0.2)
                                      : Colors.blue.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(isAuto ? "자동" : "수동",
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: isAuto
                                            ? Colors.orange
                                            : Colors.blue,
                                        fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 8),
                              if (file.size != null)
                                Text(
                                    "${(int.parse(file.size!) / 1024).toStringAsFixed(1)} KB",
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (!_isSelectionMode)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert),
                        onSelected: (value) {
                          if (value == 'download') {
                            _downloadFromDrive(file.id!, file.name!);
                          } else if (value == 'delete') {
                            _deleteCloudFile(file.id!);
                          }
                        },
                        itemBuilder: (BuildContext context) =>
                            <PopupMenuEntry<String>>[
                          const PopupMenuItem<String>(
                            value: 'download',
                            child: Row(
                              children: [
                                Icon(Icons.download, size: 20),
                                SizedBox(width: 12),
                                Text('다운로드'),
                              ],
                            ),
                          ),
                          const PopupMenuItem<String>(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline,
                                    color: Colors.red, size: 20),
                                SizedBox(width: 12),
                                Text('삭제', style: TextStyle(color: Colors.red)),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar _tabBar;

  _SliverTabBarDelegate(this._tabBar);

  @override
  double get minExtent => _tabBar.preferredSize.height;
  @override
  double get maxExtent => _tabBar.preferredSize.height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: _tabBar,
    );
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return false;
  }
}

class _DiffRestoreDialog extends StatefulWidget {
  final List<Map<String, String>> diffs;
  final Function(List<String>) onRestore;

  const _DiffRestoreDialog({required this.diffs, required this.onRestore});

  @override
  State<_DiffRestoreDialog> createState() => _DiffRestoreDialogState();
}

class _DiffRestoreDialogState extends State<_DiffRestoreDialog> {
  final Set<String> _selectedKeys = {};

  @override
  void initState() {
    super.initState();
    // Default select all
    for (var diff in widget.diffs) {
      _selectedKeys.add(diff['key']!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("변경 사항 비교"),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("총 ${widget.diffs.length}개 항목"),
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_selectedKeys.length == widget.diffs.length) {
                        _selectedKeys.clear();
                      } else {
                        for (var diff in widget.diffs) {
                          _selectedKeys.add(diff['key']!);
                        }
                      }
                    });
                  },
                  child: Text(_selectedKeys.length == widget.diffs.length
                      ? "전체 해제"
                      : "전체 선택"),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: widget.diffs.length,
                itemBuilder: (context, index) {
                  final diff = widget.diffs[index];
                  final key = diff['key']!;
                  final backupVal = diff['backup']!;
                  final currentVal = diff['current']!;
                  final isSelected = _selectedKeys.contains(key);

                  return CheckboxListTile(
                    value: isSelected,
                    onChanged: (val) {
                      setState(() {
                        if (val == true) {
                          _selectedKeys.add(key);
                        } else {
                          _selectedKeys.remove(key);
                        }
                      });
                    },
                    title: Text(key,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("백업: $backupVal",
                            style: const TextStyle(
                                color: Colors.green, fontSize: 12)),
                        Text("현재: $currentVal",
                            style: const TextStyle(
                                color: Colors.red, fontSize: 12)),
                      ],
                    ),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("취소"),
        ),
        ElevatedButton(
          onPressed: _selectedKeys.isEmpty
              ? null
              : () => widget.onRestore(_selectedKeys.toList()),
          child: Text("${_selectedKeys.length}개 복원"),
        ),
      ],
    );
  }
}
