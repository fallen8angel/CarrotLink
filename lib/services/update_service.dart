import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_filex/open_filex.dart';

class UpdateService extends ChangeNotifier {
  bool _isChecking = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String? _downloadedFilePath;
  Map<String, dynamic>? _latestRelease;
  String _currentVersion = ""; // 표시용 (예: 1.1007.2)
  String _currentVersionFull = ""; // 비교용 (예: 1.1007.2+19)
  String _statusMessage = "";
  String _channel = "stable"; // stable or dev
  late final Future<void> _versionLoadFuture;
  late final Future<void> _channelLoadFuture;

  bool get isChecking => _isChecking;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String? get downloadedFilePath => _downloadedFilePath;
  Map<String, dynamic>? get latestRelease => _latestRelease;
  String get currentVersion => _currentVersion;
  String get currentVersionFull => _currentVersionFull;
  String get statusMessage => _statusMessage;
  String get channel => _channel;

  UpdateService() {
    _versionLoadFuture = _loadVersion();
    _channelLoadFuture = _loadChannel();
  }

  Future<void> _ensureReady() async {
    await Future.wait<void>([
      _versionLoadFuture,
      _channelLoadFuture,
    ]);
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    // 표시용: 버전만 (예: 1.1007.2)
    _currentVersion = info.version;
    // 비교용: 버전+빌드번호 (예: 1.1007.2+19)
    _currentVersionFull = info.buildNumber.isNotEmpty
        ? "${info.version}+${info.buildNumber}"
        : info.version;
    notifyListeners();
  }

  Future<void> _loadChannel() async {
    final prefs = await SharedPreferences.getInstance();
    _channel = prefs.getString('update_channel') ?? "stable";
    notifyListeners();
  }

  Future<void> setChannel(String newChannel) async {
    if (_channel == newChannel) return;
    _channel = newChannel;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('update_channel', _channel);
    _latestRelease = null;
    _downloadedFilePath = null;
    _downloadProgress = 0.0;
    _statusMessage = "";
    notifyListeners();
    await checkForUpdate();
  }

  Future<bool> checkForUpdate({bool silent = false}) async {
    if (_isChecking) return false;
    await _ensureReady();
    _isChecking = true;
    if (!silent) {
      _statusMessage = "";
    }
    notifyListeners();

    try {
      // Check "Do not ask" preference if silent check (startup)
      if (silent) {
        final prefs = await SharedPreferences.getInstance();
        final lastIgnored = prefs.getString('ignore_update_until');
        if (lastIgnored != null) {
          final date = DateTime.parse(lastIgnored);
          if (DateTime.now().isBefore(date)) {
            _isChecking = false;
            notifyListeners();
            return false;
          }
        }
      }

      Map<String, dynamic>? releaseData;

      if (_channel == 'stable') {
        final url = Uri.parse(
            'https://api.github.com/repos/jominki354/CarrotLink/releases/latest');
        final response = await http.get(url);
        if (response.statusCode == 200) {
          releaseData = jsonDecode(response.body);
        } else if (!silent) {
          _statusMessage = "업데이트 확인 실패: HTTP ${response.statusCode}";
        }
      } else {
        // Dev channel: Get list of releases and pick the first one (latest by date)
        final url = Uri.parse(
            'https://api.github.com/repos/jominki354/CarrotLink/releases?per_page=1');
        final response = await http.get(url);
        if (response.statusCode == 200) {
          final List list = jsonDecode(response.body);
          if (list.isNotEmpty) {
            releaseData = list.first;
          }
        } else if (!silent) {
          _statusMessage = "업데이트 확인 실패: HTTP ${response.statusCode}";
        }
      }

      if (releaseData != null) {
        final String tagName = releaseData['tag_name'] ?? "";
        // Remove 'v' prefix only (keep build metadata for comparison)
        final latestVersion = tagName.replaceAll('v', '');

        // Compare versions (including build number if present)
        if (_isNewer(latestVersion, _currentVersionFull)) {
          _latestRelease = releaseData;

          // Check if file already exists
          await _checkExistingFile(releaseData);
          if (_downloadedFilePath == null && !silent) {
            _statusMessage = "새 업데이트가 있습니다.";
          }

          _isChecking = false;
          notifyListeners();
          return true;
        }
      }
    } catch (e) {
      debugPrint("Update check failed: $e");
      if (!silent) {
        _statusMessage = "업데이트 확인 실패: $e";
      }
    }

    _latestRelease = null;
    _downloadedFilePath = null;
    _downloadProgress = 0.0;
    if (!silent && _statusMessage.isEmpty) {
      _statusMessage = "최신 버전입니다.";
    } else if (silent) {
      _statusMessage = "";
    }
    _isChecking = false;
    notifyListeners();
    return false;
  }

  bool _isNewer(String remote, String current) {
    try {
      // 빌드 메타데이터 (+숫자) 제거
      final remoteBase = remote.split('+')[0];
      final currentBase = current.split('+')[0];

      List<int> rParts =
          remoteBase.split('.').map((e) => int.parse(e)).toList();
      List<int> cParts =
          currentBase.split('.').map((e) => int.parse(e)).toList();

      // Pad with zeros if lengths differ (e.g. 1.0 vs 1.0.0)
      while (rParts.length < 3) {
        rParts.add(0);
      }
      while (cParts.length < 3) {
        cParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (rParts[i] > cParts[i]) return true;
        if (rParts[i] < cParts[i]) return false;
      }

      // 버전이 같으면 빌드 번호 비교 (있는 경우)
      final remoteBuild =
          remote.contains('+') ? int.tryParse(remote.split('+')[1]) ?? 0 : 0;
      final currentBuild =
          current.contains('+') ? int.tryParse(current.split('+')[1]) ?? 0 : 0;

      return remoteBuild > currentBuild;
    } catch (e) {
      // Fallback to string comparison if parsing fails
      debugPrint("Version comparison failed: $e");
      return remote != current;
    }
  }

  Future<void> _checkExistingFile(Map<String, dynamic> releaseData) async {
    final tagName = releaseData['tag_name'];
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final filePath = "${dir.path}/update_$tagName.apk";
    final file = File(filePath);
    if (await file.exists()) {
      _downloadedFilePath = filePath;
      _statusMessage = "다운로드 완료";
      _downloadProgress = 1.0;
    } else {
      _downloadedFilePath = null;
      _downloadProgress = 0.0;
      _statusMessage = "";
    }
  }

  Future<void> downloadUpdate() async {
    if (_isDownloading) return;
    if (_latestRelease == null) {
      _statusMessage = "다운로드할 업데이트가 없습니다.";
      notifyListeners();
      return;
    }

    final List assets = _latestRelease!['assets'] ?? [];
    String? downloadUrl;
    for (var asset in assets) {
      if (asset['name'].toString().endsWith('.apk')) {
        downloadUrl = asset['browser_download_url'];
        break;
      }
    }

    if (downloadUrl == null) {
      _statusMessage = "릴리즈에 APK 자산이 없습니다.";
      notifyListeners();
      return;
    }

    _isDownloading = true;
    _downloadedFilePath = null;
    _downloadProgress = 0.0;
    _statusMessage = "다운로드 중...";
    notifyListeners();

    http.Client? client;
    IOSink? sink;
    try {
      final tagName = _latestRelease!['tag_name'];
      final dir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      await dir.create(recursive: true);
      final filePath = "${dir.path}/update_$tagName.apk";
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }

      client = http.Client();
      final request = http.Request('GET', Uri.parse(downloadUrl));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        _isDownloading = false;
        _statusMessage = "다운로드 실패: HTTP ${response.statusCode}";
        notifyListeners();
        return;
      }
      final total = response.contentLength ?? 0;
      int received = 0;
      sink = file.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _downloadProgress = received / total;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      _downloadedFilePath = filePath;
      _isDownloading = false;
      _statusMessage = "다운로드 완료. 설치 버튼을 누르세요.";
      _downloadProgress = 1.0;
      notifyListeners();
    } catch (e) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      _isDownloading = false;
      _statusMessage = "다운로드 실패: $e";
      notifyListeners();
    } finally {
      client?.close();
    }
  }

  Future<void> installUpdate() async {
    final path = _downloadedFilePath;
    if (path == null || path.trim().isEmpty) {
      _statusMessage = "설치 파일이 없습니다.";
      notifyListeners();
      return;
    }
    final result = await OpenFilex.open(path);
    if (result.type == ResultType.done) {
      _statusMessage = "설치 화면을 열었습니다.";
    } else {
      _statusMessage = "설치 실행 실패: ${result.message}";
    }
    notifyListeners();
  }

  Future<void> ignoreUpdateFor3Days() async {
    final prefs = await SharedPreferences.getInstance();
    final date = DateTime.now().add(const Duration(days: 3));
    await prefs.setString('ignore_update_until', date.toIso8601String());
    _latestRelease = null; // Hide update for now
    notifyListeners();
  }
}
