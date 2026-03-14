import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/carrot_settings_models.dart';
import 'carrot_server_settings_service.dart';
import 'ssh_service.dart';
import 'google_drive_service.dart';
import 'storage_layout_service.dart';

class BackupSyncResult {
  final bool skipped;
  final int downloaded;
  final int uploaded;
  final int downloadFailed;
  final int uploadFailed;

  const BackupSyncResult({
    required this.skipped,
    required this.downloaded,
    required this.uploaded,
    required this.downloadFailed,
    required this.uploadFailed,
  });

  int get successCount => downloaded + uploaded;
  int get failedCount => downloadFailed + uploadFailed;
  bool get hasChanges => successCount > 0;
}

class BackupService extends ChangeNotifier {
  static const int _fixedIntervalMinutes = 60;
  static const int _safetySyncIntervalMinutes = 30;
  static const Duration _eventSyncDebounce = Duration(seconds: 5);
  static const Duration _eventSyncMinInterval = Duration(seconds: 20);
  static const int _paramsChunkSize = 80;

  bool _isBackingUp = false;
  double _progress = 0.0;
  String _statusMessage = "";

  bool get isBackingUp => _isBackingUp;
  double get progress => _progress;
  String get statusMessage => _statusMessage;

  // Event to notify when a backup is completed so screens can refresh lists
  final StreamController<void> _backupCompleteController =
      StreamController<void>.broadcast();
  Stream<void> get onBackupComplete => _backupCompleteController.stream;

  Timer? _monitorTimer;
  Timer? _syncSafetyTimer;
  Timer? _pendingEventSyncTimer;
  SSHService? _sshService;
  GoogleDriveService? _driveService;
  final CarrotServerSettingsService _carrotServer =
      CarrotServerSettingsService();
  VoidCallback? _sshListener;
  bool _wasConnected = false;
  DateTime? _lastEventSyncAt;

  DateTime? _lastCheckTime;
  DateTime? get lastCheckTime => _lastCheckTime;

  DateTime? _lastBackupTime;
  DateTime? get lastBackupTime => _lastBackupTime;

  int _intervalMinutes = _fixedIntervalMinutes;
  DateTime? get nextCheckTime {
    if (_lastCheckTime == null) return null;
    return _lastCheckTime!.add(Duration(minutes: _intervalMinutes));
  }

  Future<void> _loadPersistedState() async {
    final prefs = await SharedPreferences.getInstance();
    final checkTimeStr = prefs.getString('last_check_time');
    final backupTimeStr = prefs.getString('last_backup_time');

    if (checkTimeStr != null) {
      _lastCheckTime = DateTime.tryParse(checkTimeStr);
    }
    if (backupTimeStr != null) {
      _lastBackupTime = DateTime.tryParse(backupTimeStr);
    }
    notifyListeners();
  }

  Future<void> _savePersistedState() async {
    final prefs = await SharedPreferences.getInstance();
    if (_lastCheckTime != null) {
      await prefs.setString(
          'last_check_time', _lastCheckTime!.toIso8601String());
    }
    if (_lastBackupTime != null) {
      await prefs.setString(
          'last_backup_time', _lastBackupTime!.toIso8601String());
    }
  }

  void _updateNotification(String content) {
    final service = FlutterBackgroundService();

    String checkTime = _lastCheckTime != null
        ? DateFormat('HH:mm:ss').format(_lastCheckTime!)
        : "--:--:--";
    String backupTime = _lastBackupTime != null
        ? DateFormat('MM/dd HH:mm').format(_lastBackupTime!)
        : "--/-- --:--";

    // Format: 백업 확인:확인 시간 l 최근 백업: 시간
    // Use the passed content as prefix if it's specific (like "백업 진행 중..."), otherwise default to "백업 확인"
    String prefix = "백업 확인";
    if (content.contains("백업 진행 중") || content.contains("업로드")) {
      prefix = content;
    }

    String fullContent = "$prefix: $checkTime | 최근 백업: $backupTime";

    // Use 'updateContent' as defined in background_service.dart
    service.invoke("updateContent", {"content": fullContent});
  }

  Future<void> _performCheck() async {
    final ssh = _sshService;
    final driveService = _driveService;

    if (ssh == null || driveService == null) return;
    if (!ssh.isConnected || _isBackingUp) return;

    try {
      _lastCheckTime = DateTime.now();
      await _savePersistedState();
      notifyListeners();
      _updateNotification("모니터링 중");

      final now = DateTime.now();
      if (_lastBackupTime != null &&
          now.difference(_lastBackupTime!) <
              const Duration(minutes: _fixedIntervalMinutes)) {
        return;
      }

      await createBackup(ssh, driveService, isAuto: true);
    } catch (e) {
      print("Monitor error: $e");
    }
  }

  Future<void> startMonitoring(
      SSHService ssh, GoogleDriveService driveService) async {
    // Clean up existing listeners/timers first
    _monitorTimer?.cancel();
    _syncSafetyTimer?.cancel();
    _pendingEventSyncTimer?.cancel();
    if (_sshService != null && _sshListener != null) {
      _sshService!.removeListener(_sshListener!);
    }

    _sshService = ssh;
    _driveService = driveService;

    await _loadPersistedState(); // Load state on start

    _updateNotification("모니터링 시작됨");

    _intervalMinutes = _fixedIntervalMinutes;
    print(
        "Starting backup monitoring with fixed interval: $_intervalMinutes minutes");

    // Setup SSH listener to trigger check on connection
    _wasConnected = ssh.isConnected;
    _sshListener = () {
      if (ssh.isConnected && !_wasConnected) {
        print("SSH Connected: Triggering immediate backup check");
        unawaited(_performCheck());
        requestEventSync(
          reason: 'ssh_connected',
          debounce: const Duration(seconds: 2),
        );
      }
      _wasConnected = ssh.isConnected;
    };
    ssh.addListener(_sshListener!);

    // Initial check (if already connected)
    if (ssh.isConnected) {
      unawaited(_performCheck());
      requestEventSync(
        reason: 'app_start_connected',
        debounce: const Duration(seconds: 2),
      );
    }

    _monitorTimer = Timer.periodic(
      Duration(minutes: _intervalMinutes),
      (timer) => unawaited(_performCheck()),
    );

    _syncSafetyTimer = Timer.periodic(
      const Duration(minutes: _safetySyncIntervalMinutes),
      (timer) =>
          requestEventSync(reason: 'safety_timer', debounce: Duration.zero),
    );

    requestEventSync(
      reason: 'app_start',
      debounce: const Duration(seconds: 2),
    );
  }

  void stopMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
    _syncSafetyTimer?.cancel();
    _syncSafetyTimer = null;
    _pendingEventSyncTimer?.cancel();
    _pendingEventSyncTimer = null;

    if (_sshService != null && _sshListener != null) {
      _sshService!.removeListener(_sshListener!);
      _sshListener = null;
    }
    _sshService = null;
    _driveService = null;

  }

  void requestEventSync({
    required String reason,
    Duration debounce = _eventSyncDebounce,
  }) {
    final driveService = _driveService;
    if (driveService == null || driveService.currentUser == null) {
      return;
    }

    _pendingEventSyncTimer?.cancel();
    _pendingEventSyncTimer = Timer(debounce, () {
      unawaited(_runEventSync(reason));
    });
  }

  Future<void> _runEventSync(String reason) async {
    final driveService = _driveService;
    if (driveService == null || driveService.currentUser == null) return;
    if (_isBackingUp) return;

    final now = DateTime.now();
    if (_lastEventSyncAt != null &&
        now.difference(_lastEventSyncAt!) < _eventSyncMinInterval) {
      return;
    }

    final hasNetwork = await _hasUsableNetwork();
    if (!hasNetwork) return;

    _lastEventSyncAt = now;
    await syncBackups(driveService, reason: reason);
  }

  Future<bool> _hasUsableNetwork() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.any((item) => item != ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  Future<void> createBackup(SSHService ssh, GoogleDriveService driveService,
      {bool isAuto = false, int retryCount = 0}) async {
    if (_isBackingUp) return;

    _isBackingUp = true;
    var backupSucceeded = false;
    _progress = 0.0;
    _statusMessage = "파라미터 목록 가져오는 중...";
    notifyListeners();
    _updateNotification("백업 진행 중...");

    try {
      if (!ssh.isConnected) {
        throw Exception("SSH 연결이 끊어졌습니다.");
      }

      final host = _resolveHost(ssh);
      if (host == null) {
        throw Exception("연결 대상 IP를 확인할 수 없습니다.");
      }
      final branchName = await _resolveBranchName(ssh);

      final backupData = await _fetchAllParamsAsJson(host);
      if (backupData.isEmpty) {
        throw Exception("백업할 파라미터가 없습니다.");
      }

      final rootDir = await getLocalBackupRootDirectory();
      final now = DateTime.now();
      final dateDir = await _ensureDateDirectory(rootDir, now);
      final timestamp = DateFormat('yyyyMMddHHmm').format(now);
      final baseName = '$branchName-$timestamp';
      final file = await _resolveUniqueBackupFile(dateDir, baseName);
      _statusMessage = "파일 저장 중...";
      notifyListeners();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(backupData),
      );

      _lastBackupTime = DateTime.now();
      await _savePersistedState();

      if (driveService.currentUser != null) {
        _statusMessage = "클라우드 업로드 중...";
        notifyListeners();
        try {
          await driveService.uploadFile(file);
        } catch (e) {
          print("Auto upload failed: $e");
        }
      }

      backupSucceeded = true;
      _backupCompleteController.add(null);
    } catch (e) {
      _statusMessage = "백업 실패: $e";
      print("Backup error: $e");
    } finally {
      _isBackingUp = false;
      _progress = 0.0;
      _statusMessage = "";
      notifyListeners();
      _updateNotification("대기 중");
      if (backupSucceeded) {
        requestEventSync(
          reason: 'backup_created',
          debounce: const Duration(seconds: 2),
        );
      }
    }
  }

  String? _resolveHost(SSHService ssh) {
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

  Future<String> _resolveBranchName(SSHService ssh) async {
    try {
      final result = await ssh.executeCommand(
        "cd /data/openpilot && git rev-parse --abbrev-ref HEAD",
      );
      if (!result.startsWith("Error")) {
        final branch = _sanitizeBranchName(result.trim());
        if (branch.isNotEmpty) {
          return branch;
        }
      }
    } catch (_) {}
    return "unknown";
  }

  String _sanitizeBranchName(String branch) {
    var value = branch.trim();
    if (value.isEmpty) return "unknown";
    value = value.replaceAll(RegExp(r"\s+"), "-");
    value = value.replaceAll(RegExp(r"[^a-zA-Z0-9._-]"), "-");
    value = value.replaceAll(RegExp(r"-{2,}"), "-");
    value = value.replaceAll(RegExp(r"^-+|-+$"), "");
    return value.isEmpty ? "unknown" : value;
  }

  Future<File> _resolveUniqueBackupFile(Directory dir, String baseName) async {
    var attempt = 0;
    while (true) {
      final suffix = attempt == 0 ? "" : "-$attempt";
      final candidate = File('${dir.path}/$baseName$suffix.json');
      if (!await candidate.exists()) {
        return candidate;
      }
      attempt++;
    }
  }

  Future<Map<String, dynamic>> _fetchAllParamsAsJson(String host) async {
    _statusMessage = "설정 메타데이터 가져오는 중...";
    notifyListeners();

    final CarrotSettingsBundle bundle = await _carrotServer.fetchSettings(host);
    final names = _collectParamNames(bundle);
    if (names.isEmpty) {
      return const {};
    }

    final result = <String, dynamic>{};
    var loaded = 0;

    for (final chunk in _chunk(names, _paramsChunkSize)) {
      final values = await _carrotServer.fetchParamsBulk(host, chunk);
      result.addAll(values);

      loaded += chunk.length;
      _progress = loaded / names.length;
      _statusMessage = "설정값 수집 중... ($loaded/${names.length})";
      notifyListeners();
    }

    return result;
  }

  List<String> _collectParamNames(CarrotSettingsBundle bundle) {
    final names = <String>{'CarSelected3'};
    for (final entries in bundle.itemsByGroup.values) {
      for (final item in entries) {
        final name = item.name.trim();
        if (name.isNotEmpty) {
          names.add(name);
        }
      }
    }
    final list = names.toList();
    list.sort();
    return list;
  }

  Iterable<List<String>> _chunk(List<String> values, int size) sync* {
    for (var i = 0; i < values.length; i += size) {
      final end = (i + size > values.length) ? values.length : i + size;
      yield values.sublist(i, end);
    }
  }

  Future<Directory> getLocalBackupRootDirectory() async {
    if (Platform.isAndroid) {
      await StorageLayoutService.instance.ensureBaseFolders();
      final root = Directory(StorageLayoutService.backupsPath);
      if (!await root.exists()) {
        await root.create(recursive: true);
      }
      return root;
    }

    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/backups');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<List<File>> listLocalBackupFiles() async {
    final root = await getLocalBackupRootDirectory();
    if (!await root.exists()) {
      return const <File>[];
    }

    final files = root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => _isBackupFileName(path.basename(f.path)))
        .toList();
    files
        .sort((a, b) => path.basename(b.path).compareTo(path.basename(a.path)));
    return files;
  }

  Future<String> buildLocalBackupPathForFileName(String fileName) async {
    final root = await getLocalBackupRootDirectory();
    final folderName = _folderNameFromFileName(fileName);
    final dateDir = Directory('${root.path}/$folderName');
    if (!await dateDir.exists()) {
      await dateDir.create(recursive: true);
    }
    return '${dateDir.path}/$fileName';
  }

  Future<Directory> _ensureDateDirectory(Directory root, DateTime time) async {
    final folderName = DateFormat('yyyy-MM-dd').format(time);
    final dateDir = Directory('${root.path}/$folderName');
    if (!await dateDir.exists()) {
      await dateDir.create(recursive: true);
    }
    return dateDir;
  }

  bool _isBackupFileName(String fileName) {
    final oldFormatRegex = RegExp(r'^\d{12,14}\(.*\)(_auto)?\.json$');
    final branchFormatRegex = RegExp(r'^.+-\d{12,14}(?:-\d+)?\.json$');
    return (fileName.startsWith('backup_') && fileName.endsWith('.json')) ||
        oldFormatRegex.hasMatch(fileName) ||
        branchFormatRegex.hasMatch(fileName);
  }

  String _folderNameFromFileName(String fileName) {
    String? stamp;
    final branchFormatMatch =
        RegExp(r'-(\d{12,14})(?:-\d+)?\.json$').firstMatch(fileName);
    if (branchFormatMatch != null) {
      stamp = branchFormatMatch.group(1);
    } else {
      final oldMatch = RegExp(r'^(\d{8})').firstMatch(fileName);
      stamp = oldMatch?.group(1);
    }
    if (stamp == null || stamp.length < 8) return 'misc';

    final yyyy = stamp.substring(0, 4);
    final mm = stamp.substring(4, 6);
    final dd = stamp.substring(6, 8);
    return '$yyyy-$mm-$dd';
  }

  Future<BackupSyncResult> syncBackups(
    GoogleDriveService driveService, {
    String reason = 'manual',
  }) async {
    if (_isBackingUp) {
      return const BackupSyncResult(
        skipped: true,
        downloaded: 0,
        uploaded: 0,
        downloadFailed: 0,
        uploadFailed: 0,
      );
    }
    if (driveService.currentUser == null) {
      return const BackupSyncResult(
        skipped: true,
        downloaded: 0,
        uploaded: 0,
        downloadFailed: 0,
        uploadFailed: 0,
      );
    }
    if (!await _hasUsableNetwork()) {
      return const BackupSyncResult(
        skipped: true,
        downloaded: 0,
        uploaded: 0,
        downloadFailed: 0,
        uploadFailed: 0,
      );
    }

    _isBackingUp = true;
    _statusMessage = "동기화 중...";
    notifyListeners();

    var downloaded = 0;
    var uploaded = 0;
    var downloadFailed = 0;
    var uploadFailed = 0;

    try {
      final localFiles = await listLocalBackupFiles();
      final localFileNames =
          localFiles.map((f) => path.basename(f.path)).toSet();

      // 2. List Cloud Files
      final cloudFiles = await driveService.listFiles();
      final cloudFileNames =
          cloudFiles.map((f) => f.name).whereType<String>().toSet();

      // 3. Download Missing (Cloud -> Local)
      for (final cloudFile in cloudFiles) {
        if (cloudFile.name != null &&
            !localFileNames.contains(cloudFile.name)) {
          _statusMessage = "다운로드 중: ${cloudFile.name}";
          notifyListeners();
          try {
            final savePath =
                await buildLocalBackupPathForFileName(cloudFile.name!);
            await driveService.downloadFile(cloudFile.id!, savePath);
            downloaded++;
          } catch (e) {
            downloadFailed++;
            print("Sync download failed for ${cloudFile.name}: $e");
          }
        }
      }

      // 4. Upload Missing (Local -> Cloud)
      for (final localFile in localFiles) {
        final name = path.basename(localFile.path);
        if (!cloudFileNames.contains(name)) {
          _statusMessage = "업로드 중: $name";
          notifyListeners();
          try {
            await driveService.uploadFile(localFile);
            uploaded++;
          } catch (e) {
            uploadFailed++;
            print("Sync upload failed for $name: $e");
          }
        }
      }

      _backupCompleteController.add(null); // Refresh UI
    } catch (e) {
      print("Sync error($reason): $e");
    } finally {
      _isBackingUp = false;
      _statusMessage = "";
      notifyListeners();
    }

    return BackupSyncResult(
      skipped: false,
      downloaded: downloaded,
      uploaded: uploaded,
      downloadFailed: downloadFailed,
      uploadFailed: uploadFailed,
    );
  }

  @override
  void dispose() {
    _monitorTimer?.cancel();
    _syncSafetyTimer?.cancel();
    _pendingEventSyncTimer?.cancel();
    if (_sshService != null && _sshListener != null) {
      _sshService!.removeListener(_sshListener!);
      _sshListener = null;
    }
    _backupCompleteController.close();
    super.dispose();
  }
}
