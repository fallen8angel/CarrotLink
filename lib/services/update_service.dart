import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_filex/open_filex.dart';
import 'github_service.dart';

class UpdateService extends ChangeNotifier {
  static const String _ignoreUpdateUntilKey = 'ignore_update_until';
  static const String _ignoreUpdateTagKey = 'ignore_update_tag';
  static const String _releaseApiBase =
      'https://hl-cloud.leehyuk1108-comma.workers.dev/api/releases';

  bool _isChecking = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String? _downloadedFilePath;
  Map<String, dynamic>? _latestRelease;
  String _currentVersion = ""; // 표시용 (예: 1.1007.2)
  String _currentVersionFull = ""; // 비교용 (예: 1.1007.2+19)
  String _statusMessage = "";
  bool _lastCheckSucceeded = false;
  String _channel = "stable"; // stable or dev
  late final Future<void> _versionLoadFuture;
  late final Future<void> _channelLoadFuture;
  late final Future<void> _ignoredStateLoadFuture;
  DateTime? _ignoredUntil;
  String? _ignoredTag;
  final GitHubService _githubService = GitHubService();

  bool get isChecking => _isChecking;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String? get downloadedFilePath => _downloadedFilePath;
  Map<String, dynamic>? get latestRelease => _latestRelease;
  bool get hasUpdateAvailable => _latestRelease != null;
  String get currentVersion => _currentVersion;
  String get currentVersionFull => _currentVersionFull;
  String get statusMessage => _statusMessage;
  bool get lastCheckSucceeded => _lastCheckSucceeded;
  String get channel => _channel;
  String? get latestReleaseTag => _latestRelease?['tag_name']?.toString();
  DateTime? get ignoredUntil => isUpdateIgnored ? _ignoredUntil : null;
  bool get isUpdateIgnored => _isIgnoredRelease(latestReleaseTag);

  UpdateService() {
    _versionLoadFuture = _loadVersion();
    _channelLoadFuture = _loadChannel();
    _ignoredStateLoadFuture = _loadIgnoredState();
  }

  Future<void> _ensureReady() async {
    await Future.wait<void>([
      _versionLoadFuture,
      _channelLoadFuture,
      _ignoredStateLoadFuture,
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

  Future<void> _loadIgnoredState() async {
    final prefs = await SharedPreferences.getInstance();
    final ignoredUntilRaw = prefs.getString(_ignoreUpdateUntilKey);
    _ignoredTag = prefs.getString(_ignoreUpdateTagKey);
    if (ignoredUntilRaw != null && ignoredUntilRaw.isNotEmpty) {
      _ignoredUntil = DateTime.tryParse(ignoredUntilRaw);
    }
    if (_ignoredUntil != null && !_ignoredUntil!.isAfter(DateTime.now())) {
      await clearIgnoredUpdate(notify: false);
    } else {
      notifyListeners();
    }
  }

  bool _isIgnoredRelease(String? releaseTag) {
    if (releaseTag == null || releaseTag.isEmpty) return false;
    if (_ignoredUntil == null || !_ignoredUntil!.isAfter(DateTime.now())) {
      return false;
    }
    if (_ignoredTag == null || _ignoredTag!.isEmpty) {
      return true;
    }
    return _ignoredTag == releaseTag;
  }

  Future<void> _clearIgnoredUpdateFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_ignoreUpdateUntilKey);
    await prefs.remove(_ignoreUpdateTagKey);
  }

  Future<void> _refreshIgnoredStateForRelease(String? releaseTag) async {
    final expired =
        _ignoredUntil != null && !_ignoredUntil!.isAfter(DateTime.now());
    final differentRelease = _ignoredTag != null &&
        _ignoredTag!.isNotEmpty &&
        releaseTag != null &&
        releaseTag.isNotEmpty &&
        _ignoredTag != releaseTag;
    if (expired || differentRelease) {
      await clearIgnoredUpdate(notify: false);
    }
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
    _lastCheckSucceeded = false;
    if (!silent) {
      _statusMessage = "";
    }
    notifyListeners();

    try {
      final releaseData = await _fetchLatestRelease(silent: silent);

      if (releaseData != null) {
        _lastCheckSucceeded = true;
        final String tagName = releaseData['tag_name'] ?? "";
        final latestVersion = tagName.replaceFirst(RegExp(r'^[vV]'), '');

        // Compare versions (including build number if present)
        if (_isNewer(latestVersion, _currentVersionFull)) {
          await _refreshIgnoredStateForRelease(tagName);
          _latestRelease = releaseData;

          // Check if file already exists
          await _checkExistingFile(releaseData);
          if (_downloadedFilePath == null && !silent) {
            _statusMessage = "새 업데이트가 있습니다.";
          }

          _isChecking = false;
          notifyListeners();
          return !silent || !_isIgnoredRelease(tagName);
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
    List<int>? parseCore(String value) {
      final normalized = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
      final core = normalized.split('+').first.split('-').first;
      final parts = core.split('.').map(int.tryParse).toList();
      if (parts.isEmpty || parts.any((part) => part == null)) return null;
      return parts.cast<int>();
    }

    int parseBuild(String value) {
      final pieces = value.split('+');
      if (pieces.length < 2) return 0;
      return int.tryParse(pieces.last.trim()) ?? 0;
    }

    final remoteParts = parseCore(remote);
    final currentParts = parseCore(current);
    if (remoteParts == null || currentParts == null) {
      debugPrint('Version comparison failed: remote=$remote current=$current');
      return remote != current;
    }

    final partCount = remoteParts.length > currentParts.length
        ? remoteParts.length
        : currentParts.length;
    for (var i = 0; i < partCount; i++) {
      final remotePart = i < remoteParts.length ? remoteParts[i] : 0;
      final currentPart = i < currentParts.length ? currentParts[i] : 0;
      if (remotePart > currentPart) return true;
      if (remotePart < currentPart) return false;
    }

    return parseBuild(remote) > parseBuild(current);
  }

  Future<Map<String, dynamic>?> _fetchLatestRelease({
    required bool silent,
  }) async {
    final response = await _requestReleaseEndpoint();
    if (response.statusCode != 200) {
      if (!silent) {
        _statusMessage = '업데이트 확인 실패: HTTP ${response.statusCode}';
      }
      return null;
    }

    final decoded = jsonDecode(response.body);
    if (_channel == 'stable') {
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return null;
    }

    if (decoded is List && decoded.isNotEmpty) {
      final first = decoded.first;
      if (first is Map<String, dynamic>) {
        return first;
      }
      if (first is Map) {
        return Map<String, dynamic>.from(first.cast<String, dynamic>());
      }
    }
    return null;
  }

  Future<http.Response> _requestReleaseEndpoint() {
    final path = _channel == 'stable'
        ? '$_releaseApiBase/latest'
        : '$_releaseApiBase?per_page=1';
    return http.get(
      Uri.parse(path),
      headers: const {'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 20));
  }

  Map<String, String> _buildGitHubHeaders({
    String? token,
    bool binaryAsset = false,
  }) {
    final headers = <String, String>{
      'Accept': binaryAsset
          ? 'application/octet-stream'
          : 'application/vnd.github+json',
    };
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'token $token';
    }
    return headers;
  }

  Map<String, dynamic>? _findApkAsset(Map<String, dynamic> releaseData) {
    final assets = releaseData['assets'];
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is! Map) continue;
      final map = Map<String, dynamic>.from(asset.cast<String, dynamic>());
      final name = map['name']?.toString() ?? '';
      if (name.endsWith('.apk')) {
        return map;
      }
    }
    return null;
  }

  Future<List<String>> _candidateUpdateFilePaths(Object? tagName) async {
    final tag = (tagName ?? '').toString().trim();
    if (tag.isEmpty) {
      return <String>[];
    }
    final paths = <String>[];
    final seen = <String>{};

    void addPath(String path) {
      final normalized = path.trim();
      if (normalized.isEmpty || !seen.add(normalized)) {
        return;
      }
      paths.add(normalized);
    }

    addPath('/storage/emulated/0/Download/CarrotLink/update_$tag.apk');

    final extDir = await getExternalStorageDirectory();
    if (extDir != null) {
      addPath('${extDir.path}/update_$tag.apk');
    }

    final docsDir = await getApplicationDocumentsDirectory();
    addPath('${docsDir.path}/update_$tag.apk');

    return paths;
  }

  Future<Directory> _resolveUpdateDownloadDir() async {
    final preferred = Directory('/storage/emulated/0/Download/CarrotLink');
    try {
      if (!await preferred.exists()) {
        await preferred.create(recursive: true);
      }
      if (await preferred.exists()) {
        return preferred;
      }
    } catch (_) {}

    final extDir = await getExternalStorageDirectory();
    if (extDir != null) {
      try {
        if (!await extDir.exists()) {
          await extDir.create(recursive: true);
        }
        if (await extDir.exists()) {
          return extDir;
        }
      } catch (_) {}
    }

    final docsDir = await getApplicationDocumentsDirectory();
    if (!await docsDir.exists()) {
      await docsDir.create(recursive: true);
    }
    return docsDir;
  }

  Future<void> _checkExistingFile(Map<String, dynamic> releaseData) async {
    final tagName = releaseData['tag_name'];
    final candidatePaths = await _candidateUpdateFilePaths(tagName);
    for (final filePath in candidatePaths) {
      final file = File(filePath);
      if (await file.exists()) {
        _downloadedFilePath = filePath;
        _statusMessage = "다운로드 완료";
        _downloadProgress = 1.0;
        return;
      }
    }
    _downloadedFilePath = null;
    _downloadProgress = 0.0;
    _statusMessage = "";
  }

  Future<void> downloadUpdate() async {
    if (_isDownloading) return;
    if (_latestRelease == null) {
      _statusMessage = "다운로드할 업데이트가 없습니다.";
      notifyListeners();
      return;
    }
    await clearIgnoredUpdate(notify: false);

    final asset = _findApkAsset(_latestRelease!);
    final downloadUrl = asset?['browser_download_url']?.toString();
    final assetApiUrl = asset?['url']?.toString();

    if (downloadUrl == null && assetApiUrl == null) {
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
      final dir = await _resolveUpdateDownloadDir();
      await dir.create(recursive: true);
      final filePath = "${dir.path}/update_$tagName.apk";
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }

      client = http.Client();
      final token = await _githubService.getToken();
      final requestUri = Uri.parse(
        (token != null && token.isNotEmpty && assetApiUrl != null)
            ? assetApiUrl
            : (downloadUrl ?? assetApiUrl!),
      );
      final request = http.Request('GET', requestUri)
        ..headers.addAll(
          _buildGitHubHeaders(
            token: (assetApiUrl != null) ? token : null,
            binaryAsset: assetApiUrl != null,
          ),
        );
      final response = await client.send(request);
      if (response.statusCode != 200) {
        _isDownloading = false;
        _statusMessage = _buildDownloadErrorMessage(
          response.statusCode,
          usedToken: token != null && token.isNotEmpty,
        );
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
    await clearIgnoredUpdate(notify: false);
    final result = await OpenFilex.open(path);
    if (result.type == ResultType.done) {
      _statusMessage = "설치 화면을 열었습니다.";
    } else {
      _statusMessage = "설치 실행 실패: ${result.message}";
    }
    notifyListeners();
  }

  Future<void> ignoreUpdateFor3Days() async {
    final releaseTag = latestReleaseTag;
    if (releaseTag == null || releaseTag.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final date = DateTime.now().add(const Duration(days: 3));
    await prefs.setString(_ignoreUpdateUntilKey, date.toIso8601String());
    await prefs.setString(_ignoreUpdateTagKey, releaseTag);
    _ignoredUntil = date;
    _ignoredTag = releaseTag;
    _statusMessage = "업데이트 알림을 3일간 숨깁니다.";
    notifyListeners();
  }

  Future<void> clearIgnoredUpdate({bool notify = true}) async {
    await _clearIgnoredUpdateFromPrefs();
    _ignoredUntil = null;
    _ignoredTag = null;
    if (notify) {
      notifyListeners();
    }
  }

  String _buildDownloadErrorMessage(
    int statusCode, {
    required bool usedToken,
  }) {
    switch (statusCode) {
      case 401:
        return '다운로드 실패: GitHub 인증이 만료되었습니다. 다시 로그인하세요.';
      case 403:
        return usedToken
            ? '다운로드 실패: GitHub 권한이 부족합니다. 다시 로그인하세요.'
            : '다운로드 실패: GitHub 접근이 제한되었습니다.';
      case 404:
        return usedToken
            ? '다운로드 실패: private 릴리즈 자산 접근 권한이 없습니다. GitHub를 다시 로그인하세요.'
            : '다운로드 실패: 릴리즈 자산을 찾을 수 없습니다.';
      default:
        return '다운로드 실패: HTTP $statusCode';
    }
  }

  String? get ignoredUpdateMessage {
    if (!isUpdateIgnored || _ignoredUntil == null) return null;
    final date = _ignoredUntil!;
    final hh = date.hour.toString().padLeft(2, '0');
    final mm = date.minute.toString().padLeft(2, '0');
    return '알림 일시중지: ${date.month}/${date.day} $hh:$mm 까지';
  }
}
