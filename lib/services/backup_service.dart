import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ssh_service.dart';
import 'google_drive_service.dart';

class BackupService extends ChangeNotifier {
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
  SSHService? _sshService;
  GoogleDriveService? _driveService;
  VoidCallback? _sshListener;
  bool _wasConnected = false;

  String? _lastParamsHash;
  DateTime? _lastCheckTime;
  DateTime? get lastCheckTime => _lastCheckTime;

  DateTime? _lastBackupTime;
  DateTime? get lastBackupTime => _lastBackupTime;

  int _intervalMinutes = 3;
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
      // Check if params changed by hashing all files in /data/params/d/
      // Using md5sum on all files and then hashing the result
      // This command lists all files, calculates md5 for each, sorts them (for consistency), and hashes the result.
      const cmd =
          "find /data/params/d/ -type f -exec md5sum {} + | sort | md5sum";
      final result = await ssh.executeCommand(cmd);

      _lastCheckTime = DateTime.now();
      _savePersistedState(); // Save state
      notifyListeners(); // Update UI with last check time
      _updateNotification("모니터링 중");

      if (!result.startsWith("Error") && result.isNotEmpty) {
        final currentHash = result.trim();

        // Initialize hash if null (first run)
        if (_lastParamsHash == null) {
          _lastParamsHash = currentHash;
          return;
        }

        if (_lastParamsHash != currentHash) {
          print("Params changed! Auto-backing up...");
          await createBackup(ssh, driveService, isAuto: true);
          _lastParamsHash = currentHash; // Update hash after backup
        }
      }
    } catch (e) {
      print("Monitor error: $e");
    }
  }

  Future<void> startMonitoring(
      SSHService ssh, GoogleDriveService driveService) async {
    // Clean up existing listeners/timers first
    _monitorTimer?.cancel();
    if (_sshService != null && _sshListener != null) {
      _sshService!.removeListener(_sshListener!);
    }

    _sshService = ssh;
    _driveService = driveService;

    await _loadPersistedState(); // Load state on start

    // Start Background Service to keep app alive
    // Permission is handled in DashboardScreen
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    _updateNotification("모니터링 시작됨");

    final prefs = await SharedPreferences.getInstance();
    _intervalMinutes = prefs.getInt('backup_interval_minutes') ?? 3;

    print(
        "Starting backup monitoring with interval: $_intervalMinutes minutes");

    // Setup SSH listener to trigger check on connection
    _wasConnected = ssh.isConnected;
    _sshListener = () {
      if (ssh.isConnected && !_wasConnected) {
        print("SSH Connected: Triggering immediate backup check");
        _performCheck();
      }
      _wasConnected = ssh.isConnected;
    };
    ssh.addListener(_sshListener!);

    // Initial check (if already connected)
    if (ssh.isConnected) {
      _performCheck();
    }

    _monitorTimer =
        Timer.periodic(Duration(minutes: _intervalMinutes), (timer) async {
      _performCheck();
    });
  }

  void stopMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = null;

    if (_sshService != null && _sshListener != null) {
      _sshService!.removeListener(_sshListener!);
      _sshListener = null;
    }
    _sshService = null;
    _driveService = null;

    final service = FlutterBackgroundService();
    service.invoke("stopService");
  }

  Future<void> createBackup(SSHService ssh, GoogleDriveService driveService,
      {bool isAuto = false, int retryCount = 0}) async {
    if (_isBackingUp) return;

    const maxRetries = 3;

    _isBackingUp = true;
    _progress = 0.0;
    _statusMessage = retryCount > 0
        ? "재시도 중 ($retryCount/$maxRetries)..."
        : "파라미터 목록 가져오는 중...";
    notifyListeners();
    _updateNotification("백업 진행 중...");

    try {
      // 연결 상태 확인
      if (!ssh.isConnected) {
        throw Exception("SSH 연결이 끊어졌습니다.");
      }

      // Get branch name
      String branch = "unknown";
      try {
        final branchResult = await ssh.executeCommand(
            "cd /data/openpilot && git rev-parse --abbrev-ref HEAD");
        if (!branchResult.startsWith("Error")) {
          branch = branchResult.trim();
        }
      } catch (_) {}

      final managerContent = await ssh
          .executeCommand("cat /data/openpilot/system/manager/manager.py");
      if (managerContent.isEmpty) throw Exception("manager.py를 읽을 수 없습니다.");

      final keys = <String>[];
      final defaultParamsRegex =
          RegExp(r'default_params\s*(?::[\s\S]*?)?=\s*\[([\s\S]*?)\]');
      final match = defaultParamsRegex.firstMatch(managerContent);

      if (match != null) {
        final listContent = match.group(1)!;
        final keyRegex = RegExp("\\(\\s*['\"]([^'\"]+)['\"]\\s*,");
        final keyMatches = keyRegex.allMatches(listContent);
        for (final m in keyMatches) {
          keys.add(m.group(1)!);
        }
      }

      final Map<String, String> backupData = {};
      int current = 0;
      final total = keys.length;

      _statusMessage = "데이터 읽는 중...";
      notifyListeners();

      // 방법 1: 배치로 여러 파일을 한번에 읽기 (빠름)
      // xargs와 cat을 사용하여 여러 파일을 한번에 읽음
      // 형식: ===KEY=== 로 구분
      final keysString = keys.join(' ');
      final batchCmd = '''
for key in $keysString; do
  if [ -f "/data/params/d/\$key" ]; then
    echo "===\$key==="
    cat "/data/params/d/\$key" 2>/dev/null || true
  fi
done
''';

      final batchResult = await ssh.executeCommand(batchCmd);

      if (!batchResult.startsWith("Error") && batchResult.contains("===")) {
        // 결과 파싱
        String? currentKey;
        final buffer = StringBuffer();

        for (final line in batchResult.split('\n')) {
          if (line.startsWith('===') && line.endsWith('===')) {
            // 이전 키의 값 저장
            if (currentKey != null) {
              backupData[currentKey] = buffer.toString().trim();
            }
            // 새 키 시작
            currentKey = line.substring(3, line.length - 3);
            buffer.clear();
          } else if (currentKey != null) {
            if (buffer.isNotEmpty) buffer.writeln();
            buffer.write(line);
          }
        }
        // 마지막 키 저장
        if (currentKey != null && buffer.isNotEmpty) {
          backupData[currentKey] = buffer.toString().trim();
        }
      }

      // 방법 2: Fallback - 개별 파일 읽기 (느리지만 확실함)
      // 배치 방법이 실패했거나 결과가 부족한 경우
      final missingKeys =
          keys.where((k) => !backupData.containsKey(k)).toList();

      if (missingKeys.isNotEmpty) {
        print(
            "Batch read got ${backupData.length}/${keys.length} keys. Reading ${missingKeys.length} missing keys...");

        for (final key in missingKeys) {
          current++;
          _progress = current / missingKeys.length;
          _statusMessage = "추가 데이터 읽는 중... ($current/${missingKeys.length})";
          notifyListeners();

          final value =
              await ssh.executeCommand("cat /data/params/d/$key 2>/dev/null");
          if (!value.startsWith("Error") && value.isNotEmpty) {
            backupData[key] = value.trim();
          }
        }
      }

      final dir = await getApplicationDocumentsDirectory();

      // Check for duplicates (Skip if identical to last backup)
      if (backupData.isNotEmpty) {
        try {
          final files = dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList();
          if (files.isNotEmpty) {
            files.sort((a, b) => b.path.compareTo(a.path)); // Newest first
            final lastFile = files.first;
            final lastContent = await lastFile.readAsString();
            final Map<String, dynamic> lastJson = jsonDecode(lastContent);

            bool isSame = true;
            if (lastJson.length != backupData.length) {
              isSame = false;
            } else {
              for (final key in backupData.keys) {
                if (lastJson[key] != backupData[key]) {
                  isSame = false;
                  break;
                }
              }
            }

            if (isSame) {
              print(
                  "Backup skipped: Content identical to last backup (${lastFile.path})");
              return;
            }
          }
        } catch (e) {
          print("Duplicate check failed: $e");
        }
      }

      // New format: 20251212173055(BranchName).json or 20251212173055(BranchName)_auto.json
      // Added seconds to prevent overwriting if multiple backups are made within a minute
      final timestamp = DateFormat('yyyyMMddHHmmss').format(DateTime.now());
      final safeBranch = branch.replaceAll(RegExp(r'[^\w\-]'), '_');
      final suffix = isAuto ? "_auto" : "";
      final fileName = '$timestamp($safeBranch)$suffix.json';
      final file = File('${dir.path}/$fileName');

      // Ensure we don't write if something went wrong or empty
      if (backupData.isNotEmpty) {
        await file.writeAsString(jsonEncode(backupData));

        _lastBackupTime = DateTime.now(); // Update last backup time
        _savePersistedState(); // Save state

        // Auto Upload
        // Try to ensure we are signed in if possible, or just check current state
        if (driveService.currentUser != null) {
          _statusMessage = "클라우드 업로드 중...";
          notifyListeners();
          try {
            await driveService.uploadFile(file);
          } catch (e) {
            print("Auto upload failed: $e");
            // Don't fail the whole backup just because upload failed
          }
        } else {
          print("Auto upload skipped: Not signed in");
        }

        _backupCompleteController.add(null); // Notify listeners
      }
    } catch (e) {
      _statusMessage = "백업 실패: $e";
      print("Backup error: $e");

      // 네트워크 관련 에러면 재시도
      final errorStr = e.toString().toLowerCase();
      final isNetworkError = errorStr.contains('socket') ||
          errorStr.contains('connection') ||
          errorStr.contains('timeout') ||
          errorStr.contains('broken pipe') ||
          errorStr.contains('ssh 연결');

      if (isNetworkError && retryCount < 3) {
        _isBackingUp = false; // 재시도를 위해 플래그 해제
        _statusMessage = "네트워크 오류 - ${retryCount + 1}번째 재시도 대기 중...";
        notifyListeners();

        // 대기 후 재시도 (5초, 10초, 15초)
        await Future.delayed(Duration(seconds: 5 * (retryCount + 1)));

        // 재연결 대기 (최대 10초)
        for (int i = 0; i < 10; i++) {
          if (ssh.isConnected) break;
          await Future.delayed(const Duration(seconds: 1));
        }

        if (ssh.isConnected) {
          print("Retrying backup (attempt ${retryCount + 1})...");
          await createBackup(ssh, driveService,
              isAuto: isAuto, retryCount: retryCount + 1);
          return;
        }
      }
    } finally {
      _isBackingUp = false;
      _progress = 0.0;
      _statusMessage = "";
      notifyListeners();
      _updateNotification("대기 중");
    }
  }

  Future<void> syncBackups(GoogleDriveService driveService) async {
    if (_isBackingUp) return;
    if (driveService.currentUser == null) return;

    _isBackingUp = true;
    _statusMessage = "동기화 중...";
    notifyListeners();

    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!dir.existsSync()) dir.createSync();

      // 1. List Local Files
      final localFiles = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      final localFileNames = localFiles
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .toSet();

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
            await driveService.downloadFile(
                cloudFile.id!, '${dir.path}/${cloudFile.name}');
          } catch (e) {
            print("Sync download failed for ${cloudFile.name}: $e");
          }
        }
      }

      // 4. Upload Missing (Local -> Cloud)
      for (final localFile in localFiles) {
        final name = localFile.path.split(Platform.pathSeparator).last;
        if (!cloudFileNames.contains(name)) {
          _statusMessage = "업로드 중: $name";
          notifyListeners();
          try {
            await driveService.uploadFile(localFile);
          } catch (e) {
            print("Sync upload failed for $name: $e");
          }
        }
      }

      _backupCompleteController.add(null); // Refresh UI
    } catch (e) {
      print("Sync error: $e");
    } finally {
      _isBackingUp = false;
      _statusMessage = "";
      notifyListeners();
    }
  }
}
