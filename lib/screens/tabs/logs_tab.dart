import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:carrot_pilot_manager/widgets/video_list_widget.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/diagnostics_service.dart';
import '../../services/ssh_service.dart';
import '../../services/storage_layout_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/connection_required_view.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/dashcam_player_screen.dart';
import '../../widgets/section_tab_bar.dart';

class LogsTab extends StatefulWidget {
  const LogsTab({super.key});

  @override
  State<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<LogsTab> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final maxWidth = window.isConstrainedLandscape
        ? double.infinity
        : switch (window.windowClass) {
      UiWindowClass.compact => double.infinity,
      UiWindowClass.medium => 1020.0,
      UiWindowClass.expanded => 1220.0,
      UiWindowClass.large => 1360.0,
      UiWindowClass.extraLarge => 1480.0,
    };

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal:
                (window.isCompact || window.isConstrainedLandscape)
                    ? 0
                    : tokens.screenPadding,
          ),
          child: Column(
            children: [
              SectionTabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: "대시캠녹화", icon: Icon(Icons.videocam_outlined)),
                  Tab(text: "화면녹화", icon: Icon(Icons.screen_share_outlined)),
                  Tab(text: "TMUX", icon: Icon(Icons.terminal_outlined)),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: const [
                    _DashcamLogsView(),
                    _RemoteVideoLogsView(
                      folderCandidates: [
                        "/data/media/0/videos",
                        "/data/media/0/screenrecord",
                        "/data/media/0/screen_recordings",
                        "/data/media/0/screenrecords",
                        "/data/media/0/ScreenRecords",
                        "/data/media/0/Movies",
                        "/sdcard/Movies",
                      ],
                      emptyMessage: "화면녹화 폴더/영상이 없습니다.",
                    ),
                    _TmuxLogsView(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashcamRouteEntry {
  final String route;
  final List<String> segmentFolders;
  final int latestModifiedEpoch;

  const _DashcamRouteEntry({
    required this.route,
    required this.segmentFolders,
    required this.latestModifiedEpoch,
  });
}

class _SegmentPlaybackAssets {
  final File? videoFile;
  final Uri? videoUri;
  final List<File> previewFrames;
  final Duration previewStep;

  const _SegmentPlaybackAssets({
    this.videoFile,
    this.videoUri,
    required this.previewFrames,
    required this.previewStep,
  }) : assert(videoFile != null || videoUri != null);
}

class _SegmentShareOptions {
  final bool convertToMp4;
  final bool includeRlog;
  final bool includeQlog;
  final bool saveOnly;

  const _SegmentShareOptions({
    required this.convertToMp4,
    required this.includeRlog,
    required this.includeQlog,
    required this.saveOnly,
  });
}

class _SegmentShareMetadata {
  final String carName;
  final String branch;
  final String commit;
  final String dongleId;
  final String serial;

  const _SegmentShareMetadata({
    required this.carName,
    required this.branch,
    required this.commit,
    required this.dongleId,
    required this.serial,
  });
}

class _DashcamLogsView extends StatefulWidget {
  const _DashcamLogsView();

  @override
  State<_DashcamLogsView> createState() => _DashcamLogsViewState();
}

class _DashcamLogsViewState extends State<_DashcamLogsView> {
  static const Duration _autoRefreshInterval = Duration(seconds: 10);
  static const int _shareSizeWarningBytes = 150 * 1024 * 1024;
  final DiagnosticsService _diag = DiagnosticsService.instance;

  bool _isLoading = true;
  bool _isDisconnected = false;
  bool? _lastConnected;
  int _loadEpoch = 0;
  String? _error;
  List<_DashcamRouteEntry> _routes = const <_DashcamRouteEntry>[];
  final Set<String> _expandedRoutes = <String>{};
  Timer? _refreshTimer;

  ({
    EdgeInsets insetPadding,
    EdgeInsets contentPadding,
    double bodyFontSize,
    double maxContentWidth,
  }) _dialogMetrics(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final insetHorizontal = window.isCompact
        ? 16.0
        : tokens.screenPadding.clamp(16.0, 28.0).toDouble();
    final insetVertical = switch (window.windowClass) {
      UiWindowClass.compact => 20.0,
      UiWindowClass.medium => 22.0,
      UiWindowClass.expanded => 24.0,
      UiWindowClass.large => 24.0,
      UiWindowClass.extraLarge => 26.0,
    };
    final contentPaddingValue = switch (window.windowClass) {
      UiWindowClass.compact => 16.0,
      UiWindowClass.medium => 18.0,
      UiWindowClass.expanded => 20.0,
      UiWindowClass.large => 20.0,
      UiWindowClass.extraLarge => 22.0,
    };
    final bodyFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 13.0,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 14.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final maxContentWidth = switch (window.windowClass) {
      UiWindowClass.compact => 420.0,
      UiWindowClass.medium => 460.0,
      UiWindowClass.expanded => 520.0,
      UiWindowClass.large => 560.0,
      UiWindowClass.extraLarge => 600.0,
    };
    return (
      insetPadding: EdgeInsets.symmetric(
        horizontal: insetHorizontal,
        vertical: insetVertical,
      ),
      contentPadding: EdgeInsets.fromLTRB(
        contentPaddingValue,
        12,
        contentPaddingValue,
        contentPaddingValue,
      ),
      bodyFontSize: bodyFontSize,
      maxContentWidth: maxContentWidth,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final connected = Provider.of<SSHService>(context).isConnected;
    if (_lastConnected == connected) return;
    _lastConnected = connected;

    if (connected) {
      _startAutoRefresh();
      unawaited(_loadRoutes());
      return;
    }

    _stopAutoRefresh();
    _loadEpoch++;
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _isDisconnected = true;
      _error = null;
      _routes = const <_DashcamRouteEntry>[];
      _expandedRoutes.clear();
    });
  }

  @override
  void dispose() {
    _stopAutoRefresh();
    super.dispose();
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      if (!mounted) return;
      final ssh = Provider.of<SSHService>(context, listen: false);
      if (!ssh.isConnected) return;
      unawaited(_loadRoutes(silent: true));
    });
  }

  void _stopAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<void> _loadRoutes({bool silent = false}) async {
    final epoch = ++_loadEpoch;
    final ssh = Provider.of<SSHService>(context, listen: false);

    if (!ssh.isConnected) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _isLoading = false;
        _isDisconnected = true;
        _error = null;
        _routes = const <_DashcamRouteEntry>[];
        _expandedRoutes.clear();
      });
      return;
    }

    if (!silent && mounted) {
      setState(() {
        _isLoading = true;
        _isDisconnected = false;
        _error = null;
      });
    }

    try {
      final files = await ssh.listFiles('/data/media/0/realdata');
      if (!mounted || epoch != _loadEpoch) return;

      final routeSegments = <String, List<String>>{};
      final routeModified = <String, int>{};

      for (final item in files) {
        if (!item.attr.isDirectory || !item.filename.contains('--')) {
          continue;
        }
        final parts = item.filename.split('--');
        if (parts.length < 2) continue;
        if (int.tryParse(parts.last) == null) continue;

        final routeName = parts.sublist(0, parts.length - 1).join('--');
        routeSegments
            .putIfAbsent(routeName, () => <String>[])
            .add(item.filename);

        final modified = item.attr.modifyTime ?? 0;
        final prev = routeModified[routeName] ?? 0;
        if (modified > prev) {
          routeModified[routeName] = modified;
        }
      }

      final loaded = routeSegments.entries.map((entry) {
        final sortedSegments = [...entry.value]
          ..sort((a, b) => _segmentIndex(a).compareTo(_segmentIndex(b)));
        return _DashcamRouteEntry(
          route: entry.key,
          segmentFolders: sortedSegments,
          latestModifiedEpoch: routeModified[entry.key] ?? 0,
        );
      }).toList()
        ..sort((a, b) {
          final byRoute = b.route.compareTo(a.route);
          if (byRoute != 0) return byRoute;
          return b.latestModifiedEpoch.compareTo(a.latestModifiedEpoch);
        });

      final validExpanded = _expandedRoutes
          .where((route) => loaded.any((entry) => entry.route == route))
          .toSet();

      setState(() {
        _routes = loaded;
        _expandedRoutes
          ..clear()
          ..addAll(validExpanded);
        _isDisconnected = false;
        _error = null;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _isLoading = false;
        _error = '대시캠 목록 로드 실패: $e';
      });
    }
  }

  int _segmentIndex(String segmentFolderName) {
    final value = segmentFolderName.split('--').last;
    return int.tryParse(value) ?? 0;
  }

  String _formatRouteTitle(String route) {
    return route.replaceFirst(RegExp(r'^0+(?=\d{3})'), '');
  }

  String? _formatRouteDateLabel(String route) {
    try {
      if (route.contains('-') && route.contains('--')) {
        final parts = route.split('--');
        if (parts.length >= 2) {
          final date = parts[0]; // 2024-11-25
          final time = parts[1]; // 14-30-00
          final t = time.split('-');
          if (t.length >= 2) {
            return '$date ${t[0]}:${t[1]}';
          }
          return date;
        }
      }
      final compact = route.split('--');
      if (compact.length >= 2 && compact.first.length >= 8) {
        final d = compact.first;
        final yyyy = d.substring(0, 4);
        final mm = d.substring(4, 6);
        final dd = d.substring(6, 8);
        final time = compact[1];
        if (time.length >= 4) {
          return '$yyyy-$mm-$dd ${time.substring(0, 2)}:${time.substring(2, 4)}';
        }
        return '$yyyy-$mm-$dd';
      }
    } catch (_) {}
    return null;
  }

  Future<void> _openSegmentInBrowser(
      String route, String segmentFolderName) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    final ip = (ssh.connectedIp ?? ssh.targetIp ?? '').trim();
    if (ip.isEmpty) {
      CustomToast.show(context, '연결 IP를 확인할 수 없습니다.', isError: true);
      return;
    }
    final segment = _segmentIndex(segmentFolderName);
    final url = Uri.parse('http://$ip:8082/footage/$route?$segment,qcamera');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return;
    }
    if (!mounted) return;
    CustomToast.show(context, '브라우저를 열 수 없습니다.', isError: true);
  }

  String _safeToken(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  }

  String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  String _segmentRemoteDir(String segmentFolderName) {
    return '/data/media/0/realdata/$segmentFolderName';
  }

  Future<bool> _remoteFileExists(SSHService ssh, String remotePath) async {
    final checkCmd =
        'test -f ${_shellQuote(remotePath)} && echo yes || echo no';
    final result = await ssh.executeCommand(checkCmd);
    return result.trim() == 'yes';
  }

  Future<int?> _remoteFileSize(SSHService ssh, String remotePath) async {
    final cmd = 'stat -c %s ${_shellQuote(remotePath)} 2>/dev/null || echo -1';
    final out = (await ssh.executeCommand(cmd)).trim();
    final parsed = int.tryParse(out);
    if (parsed == null || parsed < 0) return null;
    return parsed;
  }

  Future<int?> _waitForRemoteFileReady(
    SSHService ssh,
    String remotePath, {
    int retries = 6,
    Duration interval = const Duration(milliseconds: 250),
  }) async {
    int? lastValidSize;
    for (var i = 0; i < retries; i++) {
      final size = await _remoteFileSize(ssh, remotePath);
      if (size != null && size > 0) {
        if (lastValidSize != null && lastValidSize == size) {
          return size;
        }
        lastValidSize = size;
      }
      if (i < retries - 1) {
        await Future<void>.delayed(interval);
      }
    }
    return lastValidSize;
  }

  Future<T> _runWithLoadingDialog<T>(
    String message,
    Future<T> Function() action,
  ) async {
    if (!mounted) return action();
    final metrics = _dialogMetrics(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          insetPadding: metrics.insetPadding,
          contentPadding: metrics.contentPadding,
          content: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
            child: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(fontSize: metrics.bodyFontSize),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      return await action();
    } finally {
      if (mounted) {
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) {
          nav.pop();
        }
      }
    }
  }

  Future<T> _runWithStatusDialog<T>(
    String initialMessage,
    Future<T> Function(void Function(String message) updateStatus) action,
  ) async {
    if (!mounted) return action((_) {});
    final metrics = _dialogMetrics(context);
    final statusText = ValueNotifier<String>(initialMessage);
    var dialogActive = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          insetPadding: metrics.insetPadding,
          contentPadding: metrics.contentPadding,
          content: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
            child: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ValueListenableBuilder<String>(
                    valueListenable: statusText,
                    builder: (_, text, __) => Text(
                      text,
                      style: TextStyle(fontSize: metrics.bodyFontSize),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      return await action((message) {
        if (!dialogActive) return;
        statusText.value = message;
      });
    } finally {
      dialogActive = false;
      if (mounted) {
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) {
          nav.pop();
        }
      }
      statusText.dispose();
    }
  }

  Future<_SegmentPlaybackAssets> _preparePlaybackAssets(
    String route,
    String segmentFolderName, {
    void Function(String message)? onStatus,
  }) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      throw Exception('연결이 필요합니다.');
    }

    final remoteDir = _segmentRemoteDir(segmentFolderName);
    final remoteTsPath = '$remoteDir/qcamera.ts';
    final remoteMp4Path = '$remoteDir/qcamera.mp4';

    String remoteVideoPath;
    String localVideoName;
    onStatus?.call('원격 영상 파일 확인 중...');
    if (await _remoteFileExists(ssh, remoteTsPath)) {
      remoteVideoPath = remoteTsPath;
      localVideoName = 'qcamera.ts';
    } else if (await _remoteFileExists(ssh, remoteMp4Path)) {
      remoteVideoPath = remoteMp4Path;
      localVideoName = 'qcamera.mp4';
    } else {
      throw Exception('qcamera 영상 파일을 찾을 수 없습니다.');
    }

    final tempDir = await getTemporaryDirectory();
    final cacheRoot = Directory(p.join(tempDir.path, 'dashcam_cache'));
    if (!await cacheRoot.exists()) {
      await cacheRoot.create(recursive: true);
    }
    final segmentIndex = _segmentIndex(segmentFolderName);
    final token = '${_safeToken(route)}_$segmentIndex';
    final localVideoPath = p.join(cacheRoot.path, '${token}_$localVideoName');
    final localVideo = File(localVideoPath);
    var hasLocalVideo = await localVideo.exists();
    var localVideoSize = 0;
    if (hasLocalVideo) {
      localVideoSize = await localVideo.length();
      if (localVideoSize <= 0) {
        try {
          await localVideo.delete();
        } catch (_) {}
        hasLocalVideo = false;
      }
    }
    if (hasLocalVideo) {
      onStatus?.call('캐시 무결성 확인 중...');
      final remoteSize = await _remoteFileSize(ssh, remoteVideoPath);
      if (remoteSize != null &&
          remoteSize > 0 &&
          localVideoSize != remoteSize) {
        onStatus?.call('캐시 불일치 감지, 재다운로드 준비 중...');
        try {
          await localVideo.delete();
        } catch (_) {}
        hasLocalVideo = false;
      }
    }

    final localPreviewDir =
        Directory(p.join(cacheRoot.path, '${token}_preview'));
    List<File> localPreviews = <File>[];
    if (await localPreviewDir.exists()) {
      localPreviews = localPreviewDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } else {
      await localPreviewDir.create(recursive: true);
    }

    File? playbackFile;
    Uri? playbackUri;
    if (hasLocalVideo) {
      onStatus?.call('캐시된 영상을 불러오는 중...');
      playbackFile = localVideo;
    } else {
      onStatus?.call('미캐시 상태: 영상 다운로드 준비 중...');
      try {
        await ssh.downloadBinaryFile(
          remoteVideoPath,
          localVideoPath,
          onProgress: (received, total) {
            if (total > 0) {
              final percent = (received * 100 ~/ total).clamp(0, 100);
              onStatus?.call('영상 다운로드 중... $percent%');
            } else {
              onStatus?.call('영상 다운로드 중...');
            }
          },
        );
        final localSize = await localVideo.length();
        if (localSize <= 0) {
          throw Exception('다운로드된 영상 크기가 0입니다.');
        }
        playbackFile = localVideo;
      } catch (e) {
        final ip = (ssh.connectedIp ?? ssh.targetIp ?? '').trim();
        if (ip.isNotEmpty) {
          onStatus?.call('다운로드 실패, 스트리밍 재생으로 전환 중...');
          final segment = _segmentIndex(segmentFolderName);
          playbackUri =
              Uri.parse('http://$ip:8082/footage/$route?$segment,qcamera');
        } else {
          throw Exception('영상 다운로드 실패: $e');
        }
      }
    }

    return _SegmentPlaybackAssets(
      videoFile: playbackFile,
      videoUri: playbackUri,
      previewFrames: localPreviews,
      previewStep: const Duration(seconds: 2),
    );
  }

  Future<void> _openSegmentPlayer(
    String route,
    String segmentFolderName,
  ) async {
    try {
      final assets = await _runWithStatusDialog<_SegmentPlaybackAssets>(
        '세그먼트 정밀 재생 준비 중...',
        (updateStatus) => _preparePlaybackAssets(
          route,
          segmentFolderName,
          onStatus: updateStatus,
        ),
      );
      if (!mounted) return;
      final segment = _segmentIndex(segmentFolderName);
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          final screenSize = MediaQuery.of(dialogContext).size;
          final window = UiWindowInfo.of(dialogContext);
          final dialogHorizontalInset = switch (window.windowClass) {
            UiWindowClass.compact => 10.0,
            UiWindowClass.medium => 16.0,
            UiWindowClass.expanded => 20.0,
            UiWindowClass.large => 24.0,
            UiWindowClass.extraLarge => 28.0,
          };
          final dialogVerticalInset = switch (window.windowClass) {
            UiWindowClass.compact => 16.0,
            UiWindowClass.medium => 18.0,
            UiWindowClass.expanded => 20.0,
            UiWindowClass.large => 22.0,
            UiWindowClass.extraLarge => 24.0,
          };
          final contentWidth = screenSize.width - (dialogHorizontalInset * 2);
          final targetHeight = (contentWidth * 9 / 16) + 200;
          final maxHeightRatio = switch (window.windowClass) {
            UiWindowClass.compact => 0.82,
            UiWindowClass.medium => 0.80,
            UiWindowClass.expanded => 0.78,
            UiWindowClass.large => 0.76,
            UiWindowClass.extraLarge => 0.74,
          };
          final maxHeight = screenSize.height * maxHeightRatio;
          final minHeight = switch (window.windowClass) {
            UiWindowClass.compact => 380.0,
            UiWindowClass.medium => 400.0,
            UiWindowClass.expanded => 420.0,
            UiWindowClass.large => 430.0,
            UiWindowClass.extraLarge => 440.0,
          };
          final dialogHeight = targetHeight < minHeight
              ? minHeight
              : (targetHeight > maxHeight ? maxHeight : targetHeight);
          return Dialog(
            insetPadding: EdgeInsets.symmetric(
              horizontal: dialogHorizontalInset,
              vertical: dialogVerticalInset,
            ),
            backgroundColor: Colors.transparent,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Material(
                color: Colors.black,
                child: SizedBox(
                  width: double.infinity,
                  height: dialogHeight,
                  child: DashcamPlayerScreen(
                    videoFile: assets.videoFile,
                    videoUri: assets.videoUri,
                    title: '${_formatRouteTitle(route)} · Segment $segment',
                    previewFrames: assets.previewFrames,
                    previewStep: assets.previewStep,
                    useScaffold: false,
                    onShareRange: (startSec, endSec) => _shareSegmentClip(
                        route, segmentFolderName,
                        startSec: startSec, endSec: endSec),
                    onClose: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
              ),
            ),
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '정밀 재생 실패: $e', isError: true);
    }
  }

  Future<_SegmentShareOptions?> _showShareOptionsDialog(
      {bool forClip = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return null;
    var convertToMp4 =
        forClip ? true : (prefs.getBool('share_convert_mp4') ?? false);
    var includeRlog = true;
    var includeQlog = true;
    var saveOnly = false;

    final result = await showDialog<_SegmentShareOptions>(
      context: context,
      builder: (context) {
        final window = UiWindowInfo.of(context);
        final tokens = UiLayoutTokens.of(context);
        final dialogHorizontalInset = window.isCompact
            ? 12.0
            : tokens.screenPadding.clamp(12.0, 26.0).toDouble();
        final dialogVerticalInset = switch (window.windowClass) {
          UiWindowClass.compact => 20.0,
          UiWindowClass.medium => 22.0,
          UiWindowClass.expanded => 24.0,
          UiWindowClass.large => 24.0,
          UiWindowClass.extraLarge => 26.0,
        };
        final dialogContentPadding = switch (window.windowClass) {
          UiWindowClass.compact => 16.0,
          UiWindowClass.medium => 18.0,
          UiWindowClass.expanded => 20.0,
          UiWindowClass.large => 20.0,
          UiWindowClass.extraLarge => 22.0,
        };
        final dialogTitleBottomGap = switch (window.windowClass) {
          UiWindowClass.compact => 8.0,
          UiWindowClass.medium => 9.0,
          UiWindowClass.expanded => 10.0,
          UiWindowClass.large => 10.0,
          UiWindowClass.extraLarge => 10.0,
        };
        final maxDialogWidth = switch (window.windowClass) {
          UiWindowClass.compact => 420.0,
          UiWindowClass.medium => 460.0,
          UiWindowClass.expanded => 520.0,
          UiWindowClass.large => 560.0,
          UiWindowClass.extraLarge => 600.0,
        };
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              insetPadding: EdgeInsets.symmetric(
                horizontal: dialogHorizontalInset,
                vertical: dialogVerticalInset,
              ),
              contentPadding: EdgeInsets.fromLTRB(
                dialogContentPadding,
                dialogTitleBottomGap,
                dialogContentPadding,
                dialogContentPadding,
              ),
              title: Text(forClip ? '구간 공유 옵션' : '세그먼트 공유 옵션'),
              content: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxDialogWidth),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!forClip)
                        SwitchListTile(
                          value: convertToMp4,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('MP4로 변환'),
                          subtitle: const Text('qcamera.ts를 qcamera.mp4로 변환'),
                          onChanged: (value) =>
                              setLocalState(() => convertToMp4 = value),
                        ),
                      CheckboxListTile(
                        value: includeRlog,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('rlog 포함'),
                        onChanged: (value) =>
                            setLocalState(() => includeRlog = value ?? false),
                      ),
                      CheckboxListTile(
                        value: includeQlog,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('qlog 포함'),
                        onChanged: (value) =>
                            setLocalState(() => includeQlog = value ?? false),
                      ),
                      SwitchListTile(
                        value: saveOnly,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('공유창 없이 로컬 저장만'),
                        onChanged: (value) =>
                            setLocalState(() => saveOnly = value),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(
                      context,
                      _SegmentShareOptions(
                        convertToMp4: convertToMp4,
                        includeRlog: includeRlog,
                        includeQlog: includeQlog,
                        saveOnly: saveOnly,
                      ),
                    );
                  },
                  child: const Text('확인'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null && !forClip) {
      await prefs.setBool('share_convert_mp4', result.convertToMp4);
    }
    return result;
  }

  Future<(String remotePath, String localName)?> _pickLogArtifact(
    SSHService ssh, {
    required String remoteDir,
    required String baseName,
    required String route,
    required int segmentIndex,
  }) async {
    final variants = <(String remotePath, String localName)>[
      (
        '$remoteDir/$baseName.zst',
        '$route--$segmentIndex--$baseName.zst',
      ),
      (
        '$remoteDir/$baseName.bz2',
        '$route--$segmentIndex--$baseName.bz2',
      ),
      (
        '$remoteDir/$baseName',
        '$route--$segmentIndex--$baseName',
      ),
    ];
    for (final variant in variants) {
      if (await _remoteFileExists(ssh, variant.$1)) {
        return variant;
      }
    }
    return null;
  }

  Future<List<XFile>> _prepareShareFiles(
    String route,
    String segmentFolderName,
    _SegmentShareOptions options, {
    int? clipStartSec,
    int? clipEndSec,
    void Function(String message)? onStatus,
  }) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      throw Exception('연결이 필요합니다.');
    }

    final segmentIndex = _segmentIndex(segmentFolderName);
    final remoteDir = _segmentRemoteDir(segmentFolderName);
    onStatus?.call('공유 대상 파일 확인 중...');

    final items = <(String remotePath, String localName)>[];
    final remoteTsPath = '$remoteDir/qcamera.ts';
    final remoteMp4Path = '$remoteDir/qcamera.mp4';

    if (clipStartSec != null && clipEndSec != null) {
      onStatus?.call('구간 영상 소스 확인 중...');
      final hasMp4 = await _remoteFileExists(ssh, remoteMp4Path);
      final hasTs = await _remoteFileExists(ssh, remoteTsPath);
      if (!hasMp4 && !hasTs) {
        throw Exception('qcamera 영상 파일이 없습니다.');
      }
      final sourceVideoPath = hasMp4 ? remoteMp4Path : remoteTsPath;
      final startSec = clipStartSec;
      final endSec = clipEndSec;
      final remoteClipPath =
          '$remoteDir/.carrotlink_share_clip_${startSec}s_${endSec}s.mp4';
      onStatus?.call('구간 영상 자르는 중... ($startSec~$endSec초)');
      final clipCmd = '(rm -f ${_shellQuote(remoteClipPath)}; '
          'ffmpeg -hide_banner -loglevel error -y -ss $startSec -to $endSec '
          '-i ${_shellQuote(sourceVideoPath)} -c copy ${_shellQuote(remoteClipPath)} '
          '|| ffmpeg -hide_banner -loglevel error -y -ss $startSec -to $endSec '
          '-i ${_shellQuote(sourceVideoPath)} -c:v libx264 -preset veryfast -crf 23 '
          '-an ${_shellQuote(remoteClipPath)})';
      final clipResult = await ssh.executeCommandResult(
        clipCmd,
        timeout: const Duration(minutes: 4),
      );
      if (clipResult.exitCode != 0 ||
          !await _remoteFileExists(ssh, remoteClipPath)) {
        final reason = clipResult.stderr.isNotEmpty
            ? clipResult.stderr
            : clipResult.stdout;
        throw Exception('영상 구간 자르기 실패: $reason');
      }
      final clipSize = await _waitForRemoteFileReady(
            ssh,
            remoteClipPath,
            retries: 8,
            interval: const Duration(milliseconds: 300),
          ) ??
          0;
      if (clipSize <= 0) {
        throw Exception('영상 구간 자르기 실패: 생성 파일 크기가 0입니다.');
      }
      onStatus?.call('구간 영상 생성 완료');
      items.add(
        (
          remoteClipPath,
          '$route--$segmentIndex--clip_${startSec}s_${endSec}s.mp4',
        ),
      );
    } else if (options.convertToMp4) {
      onStatus?.call('MP4 변환 상태 확인 중...');
      final hasMp4 = await _remoteFileExists(ssh, remoteMp4Path);
      if (!hasMp4) {
        final hasTs = await _remoteFileExists(ssh, remoteTsPath);
        if (!hasTs) {
          throw Exception('qcamera.ts 파일이 없습니다.');
        }
        onStatus?.call('qcamera.ts -> mp4 변환 중...');
        final convertCmd = 'ffmpeg -hide_banner -loglevel error -y -i '
            '${_shellQuote(remoteTsPath)} -c copy ${_shellQuote(remoteMp4Path)}';
        final convertResult = await ssh.executeCommandResult(convertCmd);
        if (convertResult.exitCode != 0 ||
            !await _remoteFileExists(ssh, remoteMp4Path)) {
          final reason = convertResult.stderr.isNotEmpty
              ? convertResult.stderr
              : convertResult.stdout;
          throw Exception('MP4 변환 실패: $reason');
        }
      }
      items.add((remoteMp4Path, '$route--$segmentIndex--qcamera.mp4'));
    } else {
      onStatus?.call('원본 qcamera.ts 확인 중...');
      final hasTs = await _remoteFileExists(ssh, remoteTsPath);
      if (!hasTs) {
        throw Exception('qcamera.ts 파일이 없습니다.');
      }
      items.add((remoteTsPath, '$route--$segmentIndex--qcamera.ts'));
    }

    if (options.includeRlog) {
      onStatus?.call('rlog 파일 확인 중...');
      final artifact = await _pickLogArtifact(
        ssh,
        remoteDir: remoteDir,
        baseName: 'rlog',
        route: route,
        segmentIndex: segmentIndex,
      );
      if (artifact != null) {
        items.add(artifact);
      }
    }
    if (options.includeQlog) {
      onStatus?.call('qlog 파일 확인 중...');
      final artifact = await _pickLogArtifact(
        ssh,
        remoteDir: remoteDir,
        baseName: 'qlog',
        route: route,
        segmentIndex: segmentIndex,
      );
      if (artifact != null) {
        items.add(artifact);
      }
    }

    if (items.isEmpty) {
      return const <XFile>[];
    }

    final tempDir = await getTemporaryDirectory();
    final shareDir = Directory(p.join(tempDir.path, 'dashcam_share'));
    if (!await shareDir.exists()) {
      await shareDir.create(recursive: true);
    }

    final out = <XFile>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final localPath = p.join(shareDir.path, item.$2);
      final localFile = File(localPath);
      if (await localFile.exists()) {
        try {
          await localFile.delete();
        } catch (_) {}
      }
      onStatus?.call('파일 다운로드 중... (${i + 1}/${items.length}) ${item.$2}');
      await ssh.downloadBinaryFile(
        item.$1,
        localPath,
        onProgress: (received, total) {
          if (total > 0) {
            final percent = (received * 100 ~/ total).clamp(0, 100);
            onStatus?.call(
              '파일 다운로드 중... (${i + 1}/${items.length}) ${item.$2} $percent%',
            );
          }
        },
      );
      final localSize = await localFile.length();
      if (localSize <= 0) {
        throw Exception('다운로드 실패: ${item.$2} 파일 크기가 0입니다.');
      }
      out.add(XFile(localPath));
    }
    onStatus?.call('파일 준비 완료. 공유창 여는 중...');
    return out;
  }

  String _timestamp() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Future<String> _saveShareFilesToLocal(List<XFile> files) async {
    await StorageLayoutService.instance.ensureBaseFolders();
    final folder = Directory(
      '${StorageLayoutService.routesPath}/shared_exports/${_timestamp()}',
    );
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    for (final file in files) {
      final source = File(file.path);
      final target = File(p.join(folder.path, p.basename(file.path)));
      await source.copy(target.path);
    }
    return folder.path;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<int> _totalFileBytes(List<XFile> files) async {
    var total = 0;
    for (final file in files) {
      try {
        total += await File(file.path).length();
      } catch (_) {}
    }
    return total;
  }

  String _compactForDiag(String text, {int max = 220}) {
    final normalized = text.replaceAll('\n', ' ').trim();
    if (normalized.length <= max) return normalized;
    return '${normalized.substring(0, max)}...';
  }

  Future<bool> _confirmLargeShareIfNeeded(List<XFile> files) async {
    final totalBytes = await _totalFileBytes(files);
    if (totalBytes < _shareSizeWarningBytes) {
      return true;
    }
    if (!mounted) return false;
    final metrics = _dialogMetrics(context);
    final message = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: metrics.insetPadding,
        contentPadding: metrics.contentPadding,
        title: const Text('대용량 공유 경고'),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
          child: Text(
            '첨부 총 용량이 ${_formatBytes(totalBytes)} 입니다.\n'
            '메신저 앱 제한으로 전송이 실패할 수 있습니다.\n'
            '계속 공유할까요?',
            style: TextStyle(fontSize: metrics.bodyFontSize),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('계속'),
          ),
        ],
      ),
    );
    return message ?? false;
  }

  Future<void> _shareSegment(
    String route,
    String segmentFolderName,
  ) async {
    final options = await _showShareOptionsDialog();
    if (options == null) return;

    try {
      final files = await _runWithStatusDialog<List<XFile>>(
        options.convertToMp4 ? 'MP4 변환 및 파일 준비 중...' : '세그먼트 파일 준비 중...',
        (updateStatus) => _prepareShareFiles(
          route,
          segmentFolderName,
          options,
          onStatus: updateStatus,
        ),
      );
      if (!mounted) return;
      if (files.isEmpty) {
        CustomToast.show(context, '공유할 파일이 없습니다.', isError: true);
        return;
      }
      final totalBytes = await _totalFileBytes(files);
      _diag.info(
        'share',
        'ready route=$route segment=${_segmentIndex(segmentFolderName)} files=${files.length} bytes=$totalBytes saveOnly=${options.saveOnly}',
      );

      if (options.saveOnly) {
        final savedPath = await _saveShareFilesToLocal(files);
        _diag.info('share', 'saved_only path=$savedPath');
        if (!mounted) return;
        CustomToast.show(context, '로컬 저장 완료: $savedPath');
        return;
      }
      final confirmed = await _confirmLargeShareIfNeeded(files);
      if (!mounted) return;
      if (!confirmed) {
        _diag.warn('share', 'cancelled_large_payload');
        CustomToast.show(context, '공유를 취소했습니다.');
        return;
      }

      final metadata = await _loadShareMetadata();
      if (!mounted) return;
      await Share.shareXFiles(
        files,
        text: _buildShareText(
          route: route,
          segmentIndex: _segmentIndex(segmentFolderName),
          files: files,
          metadata: metadata,
        ),
      );
      _diag.info(
        'share',
        'share_sheet_opened route=$route segment=${_segmentIndex(segmentFolderName)} files=${files.length}',
      );
    } catch (e) {
      _diag.error('share', 'segment_share_failed route=$route error=$e');
      if (!mounted) return;
      CustomToast.show(context, '세그먼트 공유 실패: $e', isError: true);
    }
  }

  Future<void> _shareSegmentClip(
    String route,
    String segmentFolderName, {
    required int startSec,
    required int endSec,
  }) async {
    if (endSec <= startSec || startSec < 0) {
      if (!mounted) return;
      CustomToast.show(context, '구간 선택이 올바르지 않습니다.', isError: true);
      return;
    }

    final options = await _showShareOptionsDialog(forClip: true);
    if (options == null) return;

    try {
      final files = await _runWithStatusDialog<List<XFile>>(
        '구간 공유 파일 준비 중...',
        (updateStatus) => _prepareShareFiles(
          route,
          segmentFolderName,
          options,
          clipStartSec: startSec,
          clipEndSec: endSec,
          onStatus: updateStatus,
        ),
      );
      if (!mounted) return;
      if (files.isEmpty) {
        CustomToast.show(context, '공유할 파일이 없습니다.', isError: true);
        return;
      }
      final totalBytes = await _totalFileBytes(files);
      _diag.info(
        'share',
        'clip_ready route=$route segment=${_segmentIndex(segmentFolderName)} range=${startSec}s-${endSec}s files=${files.length} bytes=$totalBytes saveOnly=${options.saveOnly}',
      );

      if (options.saveOnly) {
        final savedPath = await _saveShareFilesToLocal(files);
        _diag.info('share', 'clip_saved_only path=$savedPath');
        if (!mounted) return;
        CustomToast.show(context, '로컬 저장 완료: $savedPath');
        return;
      }
      final confirmed = await _confirmLargeShareIfNeeded(files);
      if (!mounted) return;
      if (!confirmed) {
        _diag.warn('share', 'clip_cancelled_large_payload');
        CustomToast.show(context, '공유를 취소했습니다.');
        return;
      }

      final metadata = await _loadShareMetadata();
      if (!mounted) return;
      CustomToast.show(context, '구간 파일 준비 완료. 공유 앱을 선택하세요.');
      await Share.shareXFiles(
        files,
        text: _buildShareText(
          route: route,
          segmentIndex: _segmentIndex(segmentFolderName),
          clipStartSec: startSec,
          clipEndSec: endSec,
          files: files,
          metadata: metadata,
        ),
      );
      _diag.info(
        'share',
        'clip_share_sheet_opened route=$route segment=${_segmentIndex(segmentFolderName)} range=${startSec}s-${endSec}s files=${files.length}',
      );
    } catch (e) {
      _diag.error(
        'share',
        'clip_share_failed route=$route segment=${_segmentIndex(segmentFolderName)} range=${startSec}s-${endSec}s error=$e',
      );
      if (!mounted) return;
      CustomToast.show(context, '구간 공유 실패: $e', isError: true);
    }
  }

  Future<String> _safeMetaRead(Future<String> Function() read) async {
    try {
      final value = (await read()).trim();
      return value.isEmpty ? 'unknown' : value;
    } catch (_) {
      return 'unknown';
    }
  }

  Future<_SegmentShareMetadata> _loadShareMetadata() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    final values = await Future.wait<String>([
      _safeMetaRead(
        () => ssh.executeCommand(
          'cat /data/params/d/CarSelected3 2>/dev/null || '
          'cat /data/params/d/CarName 2>/dev/null || echo unknown',
        ),
      ),
      _safeMetaRead(() => ssh.getBranch()),
      _safeMetaRead(() => ssh.getCommitHash()),
      _safeMetaRead(() => ssh.getDongleId()),
      _safeMetaRead(() => ssh.getSerial()),
    ]);
    return _SegmentShareMetadata(
      carName: values[0],
      branch: values[1],
      commit: values[2],
      dongleId: values[3],
      serial: values[4],
    );
  }

  String _buildShareText({
    required String route,
    required int segmentIndex,
    required List<XFile> files,
    required _SegmentShareMetadata metadata,
    int? clipStartSec,
    int? clipEndSec,
  }) {
    final attachedKinds = <String>{};
    final attachedFiles = <String>[];
    for (final f in files) {
      final name = p.basename(f.path);
      final lower = name.toLowerCase();
      attachedFiles.add(name);
      if (lower.contains('rlog')) {
        attachedKinds.add('rlog');
      } else if (lower.contains('qlog')) {
        attachedKinds.add('qlog');
      } else if (lower.contains('qcamera') ||
          lower.contains('clip_') ||
          lower.endsWith('.mp4') ||
          lower.endsWith('.ts')) {
        attachedKinds.add('영상');
      } else {
        attachedKinds.add('파일');
      }
    }

    final segmentLabel = clipStartSec != null && clipEndSec != null
        ? 'Segment $segmentIndex ($clipStartSec~$clipEndSec초)'
        : 'Segment $segmentIndex';
    final kindsLabelText = attachedKinds.isEmpty
        ? '없음'
        : (attachedKinds.toList()..sort()).join(', ');
    final filesLabelText = attachedFiles.isEmpty
        ? '없음'
        : (attachedFiles.toList()..sort()).join(', ');

    return <String>[
      '차량정보: ${metadata.carName}',
      '브랜치: ${metadata.branch} 커밋번호: ${metadata.commit}',
      '동글 ID: ${metadata.dongleId} 시리얼: ${metadata.serial}',
      '$route -- $segmentLabel',
      '첨부유형: $kindsLabelText',
      '첨부파일: $filesLabelText',
    ].join('\n');
  }

  Future<void> _uploadSegmentToCarrotServer(
    String route,
    String segmentFolderName,
  ) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    final ip = (ssh.connectedIp ?? ssh.targetIp ?? '').trim();
    if (ip.isEmpty) {
      _diag.warn(
        'carrot_upload',
        'skip_no_ip route=$route segmentFolder=$segmentFolderName',
      );
      if (!mounted) return;
      CustomToast.show(context, '연결 IP를 확인할 수 없습니다.', isError: true);
      return;
    }

    final segment = _segmentIndex(segmentFolderName);
    final uri = Uri(
      scheme: 'http',
      host: ip,
      port: 8082,
      path: '/footage/full/upload_carrot/$route/$segment',
    );
    _diag.info(
      'carrot_upload',
      'start route=$route segment=$segment uri=$uri',
    );

    try {
      final response = await _runWithLoadingDialog<http.Response>(
        'Carrot 서버로 로그 전송 중...',
        () => http.post(uri).timeout(const Duration(minutes: 10)),
      );
      if (!mounted) return;
      final body = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
      _diag.info(
        'carrot_upload',
        'response route=$route segment=$segment status=${response.statusCode} body=${_compactForDiag(body)}',
      );
      if (response.statusCode == 200) {
        final message = body.isEmpty ? '로그 전송 완료' : '로그 전송 완료: $body';
        _diag.info('carrot_upload', 'success route=$route segment=$segment');
        CustomToast.show(context, message);
      } else {
        final reason = body.isEmpty ? 'HTTP ${response.statusCode}' : body;
        _diag.warn(
          'carrot_upload',
          'failed route=$route segment=$segment status=${response.statusCode} reason=${_compactForDiag(reason)}',
        );
        CustomToast.show(
          context,
          '로그 전송 실패 (${response.statusCode}): $reason',
          isError: true,
        );
      }
    } catch (e) {
      final lower = e.toString().toLowerCase();
      if (lower.contains('cleartext') || lower.contains('not permitted')) {
        _diag.error(
          'carrot_upload',
          'exception_cleartext route=$route segment=$segment uri=$uri error=$e',
        );
      } else {
        _diag.error(
          'carrot_upload',
          'exception route=$route segment=$segment uri=$uri error=$e',
        );
      }
      if (!mounted) return;
      CustomToast.show(context, '로그 전송 실패: $e', isError: true);
    }
  }

  Future<void> _showSegmentActions(
    String route,
    String segmentFolderName,
  ) async {
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_browser),
              title: const Text('Fleet 접속'),
              subtitle: const Text('브라우저에서 Fleet 재생/다운로드'),
              onTap: () => Navigator.pop(context, 'fleet'),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('로그 전송'),
              subtitle: const Text('Carrot 서버(FTP)로 전송'),
              onTap: () => Navigator.pop(context, 'upload'),
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('로그 공유'),
              subtitle: const Text('영상/rlog/qlog 공유'),
              onTap: () => Navigator.pop(context, 'share'),
            ),
          ],
        ),
      ),
    );

    if (selected == 'fleet') {
      await _openSegmentInBrowser(route, segmentFolderName);
    } else if (selected == 'upload') {
      await _uploadSegmentToCarrotServer(route, segmentFolderName);
    } else if (selected == 'share') {
      await _shareSegment(route, segmentFolderName);
    }
  }

  void _toggleRouteExpanded(String route) {
    setState(() {
      if (_expandedRoutes.contains(route)) {
        _expandedRoutes.remove(route);
      } else {
        _expandedRoutes.add(route);
      }
    });
  }

  Widget _buildRouteTile(_DashcamRouteEntry entry) {
    final window = UiWindowInfo.of(context);
    final tileHorizontalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 14.0,
      UiWindowClass.large => 16.0,
      UiWindowClass.extraLarge => 16.0,
    };
    final expandedHorizontalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 10.0,
      UiWindowClass.medium => 11.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final segmentBadgeRadius = switch (window.windowClass) {
      UiWindowClass.compact => 13.0,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 14.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 15.0,
    };
    final segmentBadgeFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 11.0,
      UiWindowClass.medium => 11.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final segmentTitleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 13.0,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 13.5,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final segmentSubtitleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 11.0,
      UiWindowClass.medium => 11.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final segmentTrailingWidth = switch (window.windowClass) {
      UiWindowClass.compact => 44.0,
      UiWindowClass.medium => 46.0,
      UiWindowClass.expanded => 48.0,
      UiWindowClass.large => 48.0,
      UiWindowClass.extraLarge => 50.0,
    };

    final expanded = _expandedRoutes.contains(entry.route);
    final dateLabel = _formatRouteDateLabel(entry.route);
    final subtitle = dateLabel == null
        ? '세그먼트 ${entry.segmentFolders.length}개'
        : '$dateLabel · 세그먼트 ${entry.segmentFolders.length}개';

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        children: [
          ListTile(
            dense: true,
            contentPadding:
                EdgeInsets.symmetric(horizontal: tileHorizontalPadding),
            onTap: () => _toggleRouteExpanded(entry.route),
            leading: const Icon(Icons.alt_route),
            title: Text(
              _formatRouteTitle(entry.route),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
            ),
          ),
          if (expanded)
            Padding(
              padding: EdgeInsets.fromLTRB(
                expandedHorizontalPadding,
                0,
                expandedHorizontalPadding,
                8,
              ),
              child: Column(
                children: entry.segmentFolders.map((segmentFolder) {
                  final segment = _segmentIndex(segmentFolder);
                  return ListTile(
                    dense: true,
                    visualDensity: const VisualDensity(vertical: -3),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: expandedHorizontalPadding,
                      vertical: 0,
                    ),
                    leading: CircleAvatar(
                      radius: segmentBadgeRadius,
                      child: Text(
                        '$segment',
                        style: TextStyle(fontSize: segmentBadgeFontSize),
                      ),
                    ),
                    title: Text(
                      '세그먼트 $segment',
                      style: TextStyle(fontSize: segmentTitleFontSize),
                    ),
                    subtitle: Text(
                      segmentFolder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: segmentSubtitleFontSize),
                    ),
                    trailing: SizedBox(
                      width: segmentTrailingWidth,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            tooltip: '세그먼트 메뉴',
                            visualDensity: const VisualDensity(
                                horizontal: -3, vertical: -3),
                            onPressed: () => unawaited(_showSegmentActions(
                                entry.route, segmentFolder)),
                            icon: const Icon(Icons.more_vert, size: 20),
                          ),
                        ],
                      ),
                    ),
                    onTap: () => unawaited(
                        _openSegmentPlayer(entry.route, segmentFolder)),
                    onLongPress: () => unawaited(
                        _showSegmentActions(entry.route, segmentFolder)),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final listHorizontalPadding = window.isCompact
        ? 12.0
        : tokens.screenPadding.clamp(12.0, 24.0).toDouble();
    final listGap = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 9.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large => 10.0,
      UiWindowClass.extraLarge => 10.0,
    };

    return Column(
      children: [
        const _LogsSubHeader(
          title: '대시캠 녹화',
          description: '주행 라우트 목록입니다. 자동으로 주기 갱신됩니다.',
        ),
        Expanded(
          child: _isDisconnected
              ? const ConnectionRequiredView(
                  description: '대시캠 로그를 보려면 먼저 기기에 연결하세요.',
                )
              : _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text(_error!))
                      : _routes.isEmpty
                          ? const Center(child: Text('주행 기록이 없습니다.'))
                          : ListView.separated(
                              padding: EdgeInsets.fromLTRB(
                                listHorizontalPadding,
                                10,
                                listHorizontalPadding,
                                16,
                              ),
                              itemCount: _routes.length,
                              separatorBuilder: (_, __) =>
                                  SizedBox(height: listGap),
                              itemBuilder: (context, index) =>
                                  _buildRouteTile(_routes[index]),
                            ),
        ),
      ],
    );
  }
}

class _RemoteVideoLogsView extends StatefulWidget {
  final List<String> folderCandidates;
  final String emptyMessage;

  const _RemoteVideoLogsView({
    required this.folderCandidates,
    required this.emptyMessage,
  });

  @override
  State<_RemoteVideoLogsView> createState() => _RemoteVideoLogsViewState();
}

class _RemoteVideoLogsViewState extends State<_RemoteVideoLogsView> {
  static const Duration _autoRefreshInterval = Duration(seconds: 30);

  bool _isLoading = true;
  bool _isDisconnected = false;
  bool? _lastConnected;
  int _loadEpoch = 0;
  String? _error;
  String? _resolvedFolder;
  List<SftpName> _videos = [];
  Timer? _autoRefreshTimer;

  @override
  void dispose() {
    _stopAutoRefresh();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final connected = Provider.of<SSHService>(context).isConnected;
    if (_lastConnected == connected) return;
    _lastConnected = connected;

    if (connected) {
      _startAutoRefresh();
      unawaited(_loadVideos());
      return;
    }

    _stopAutoRefresh();
    if (_isDisconnected &&
        !_isLoading &&
        _error == null &&
        _resolvedFolder == null &&
        _videos.isEmpty) {
      return;
    }

    _loadEpoch++;
    setState(() {
      _isLoading = false;
      _isDisconnected = true;
      _error = null;
      _resolvedFolder = null;
      _videos = [];
    });
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      if (!mounted) return;
      final ssh = Provider.of<SSHService>(context, listen: false);
      if (!ssh.isConnected) return;
      unawaited(_loadVideos(silent: true));
    });
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  Future<void> _loadVideos({bool silent = false}) async {
    final epoch = ++_loadEpoch;
    if (!mounted || epoch != _loadEpoch) return;
    if (!silent) {
      setState(() {
        _isLoading = true;
        _isDisconnected = false;
        _error = null;
      });
    }

    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _isDisconnected = true;
        _error = null;
        _isLoading = false;
        _resolvedFolder = null;
        _videos = [];
      });
      return;
    }

    try {
      final exts = ['.mp4', '.mkv', '.avi', '.mov', '.ts', '.hevc'];

      for (final folder in widget.folderCandidates) {
        try {
          final files = await ssh.listFiles(folder);
          if (!mounted || epoch != _loadEpoch) return;
          final videos = files.where((f) {
            final name = f.filename.toLowerCase();
            return exts.any(name.endsWith);
          }).toList();
          videos.sort(
            (a, b) =>
                (b.attr.modifyTime ?? 0).compareTo(a.attr.modifyTime ?? 0),
          );

          if (videos.isNotEmpty) {
            if (!mounted || epoch != _loadEpoch) return;
            setState(() {
              _resolvedFolder = folder;
              _videos = videos;
              _isDisconnected = false;
              _error = null;
              _isLoading = false;
            });
            return;
          }
        } catch (_) {
          // 후보 경로 실패는 다음 후보로 진행
        }
      }

      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _isDisconnected = false;
        _error = widget.emptyMessage;
        _resolvedFolder = null;
        _videos = [];
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _isDisconnected = false;
        _error = "영상 목록 로드 실패: $e";
        _isLoading = false;
      });
    }
  }

  Future<void> _playVideo(SftpName file) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    final base = _resolvedFolder;
    if (base == null || base.isEmpty) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final remotePath = "$base/${file.filename}";
      final tempDir = await getTemporaryDirectory();
      final localPath = "${tempDir.path}/${file.filename}";
      final localFile = File(localPath);
      await ssh.downloadBinaryFile(remotePath, localPath);

      if (!mounted) return;
      Navigator.pop(context);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(videoFile: localFile),
        ),
      );
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        CustomToast.show(context, "영상 재생 실패: $e", isError: true);
      }
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) {
      return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
    }
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final listHorizontalPadding = window.isCompact
        ? 12.0
        : tokens.screenPadding.clamp(12.0, 24.0).toDouble();
    final listGap = switch (window.windowClass) {
      UiWindowClass.compact => 6.0,
      UiWindowClass.medium => 7.0,
      UiWindowClass.expanded => 8.0,
      UiWindowClass.large => 8.0,
      UiWindowClass.extraLarge => 8.0,
    };
    final tileHorizontalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 10.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final videoSubtitleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 11.0,
      UiWindowClass.medium => 11.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 12.0,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _LogsSubHeader(
          title: '화면 녹화',
          description: '기기 내부 화면녹화 영상 목록입니다.',
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _isDisconnected
                  ? const ConnectionRequiredView(
                      description: '화면녹화 목록을 보려면 먼저 기기에 연결하세요.',
                    )
                  : _error != null
                      ? Center(child: Text(_error!))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ListView.separated(
                                padding: EdgeInsets.fromLTRB(
                                  listHorizontalPadding,
                                  10,
                                  listHorizontalPadding,
                                  24,
                                ),
                                itemCount: _videos.length,
                                separatorBuilder: (_, __) =>
                                    SizedBox(height: listGap),
                                itemBuilder: (context, index) {
                                  final video = _videos[index];
                                  return Material(
                                    color: scheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(10),
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      onTap: () => _playVideo(video),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          border: Border.all(
                                            color: scheme.outlineVariant
                                                .withValues(
                                              alpha: 0.45,
                                            ),
                                          ),
                                        ),
                                        child: ListTile(
                                          dense: true,
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: tileHorizontalPadding,
                                            vertical: 2,
                                          ),
                                          leading: const Icon(
                                            Icons.play_circle_outline,
                                          ),
                                          title: Text(
                                            video.filename,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          subtitle: Text(
                                            _formatSize(video.attr.size ?? 0),
                                            style: TextStyle(
                                              fontSize: videoSubtitleFontSize,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
        ),
      ],
    );
  }
}

class _TmuxLogsView extends StatefulWidget {
  const _TmuxLogsView();

  @override
  State<_TmuxLogsView> createState() => _TmuxLogsViewState();
}

class _TmuxLogsViewState extends State<_TmuxLogsView> {
  bool _isLoading = true;
  String _output = '';
  bool _isLive = true;
  Timer? _pollTimer;
  final ScrollController _scrollController = ScrollController();

  static const int _maxVisibleLines = 350;
  static const Duration _pollInterval = Duration(seconds: 3);

  ({
    EdgeInsets insetPadding,
    EdgeInsets contentPadding,
    double bodyFontSize,
    double maxContentWidth,
  }) _dialogMetrics(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final insetHorizontal = window.isCompact
        ? 16.0
        : tokens.screenPadding.clamp(16.0, 28.0).toDouble();
    final insetVertical = switch (window.windowClass) {
      UiWindowClass.compact => 20.0,
      UiWindowClass.medium => 22.0,
      UiWindowClass.expanded => 24.0,
      UiWindowClass.large => 24.0,
      UiWindowClass.extraLarge => 26.0,
    };
    final contentPaddingValue = switch (window.windowClass) {
      UiWindowClass.compact => 16.0,
      UiWindowClass.medium => 18.0,
      UiWindowClass.expanded => 20.0,
      UiWindowClass.large => 20.0,
      UiWindowClass.extraLarge => 22.0,
    };
    final bodyFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 13.0,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 14.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final maxContentWidth = switch (window.windowClass) {
      UiWindowClass.compact => 420.0,
      UiWindowClass.medium => 460.0,
      UiWindowClass.expanded => 520.0,
      UiWindowClass.large => 560.0,
      UiWindowClass.extraLarge => 600.0,
    };
    return (
      insetPadding: EdgeInsets.symmetric(
        horizontal: insetHorizontal,
        vertical: insetVertical,
      ),
      contentPadding: EdgeInsets.fromLTRB(
        contentPaddingValue,
        12,
        contentPaddingValue,
        contentPaddingValue,
      ),
      bodyFontSize: bodyFontSize,
      maxContentWidth: maxContentWidth,
    );
  }

  static const String _tmuxInspectCommand = '''
if command -v tmux >/dev/null 2>&1; then
  echo "== tmux sessions =="
  tmux ls 2>&1 || true
  echo
  if tmux has-session -t comma 2>/dev/null; then
    echo "== comma:0.0 recent output (last 500 lines) =="
    tmux capture-pane -pt comma:0.0 -S -500 2>&1 || true
  else
    echo "comma session not found"
  fi
else
  echo "tmux not installed"
fi
''';

  static const String _tmuxInspectCommandFull = '''
if command -v tmux >/dev/null 2>&1; then
  echo "== tmux sessions =="
  tmux ls 2>&1 || true
  echo
  if tmux has-session -t comma 2>/dev/null; then
    echo "== comma:0.0 full output =="
    tmux capture-pane -pt comma:0.0 -S - 2>&1 || true
  else
    echo "comma session not found"
  fi
else
  echo "tmux not installed"
fi
''';

  @override
  void initState() {
    super.initState();
    _refreshTmux();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    if (!_isLive) return;
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      if (mounted) {
        _refreshTmux(silent: true);
      }
    });
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  String _trimOutput(String text) {
    final lines = text.split('\n');
    if (lines.length <= _maxVisibleLines) {
      return text;
    }
    final kept = lines.sublist(lines.length - _maxVisibleLines).join('\n');
    return "[이전 ${lines.length - _maxVisibleLines}줄은 화면에서 숨김]\n$kept";
  }

  Future<String> _fetchTmuxOutput({required bool fullHistory}) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      throw Exception("기기와 연결되어 있지 않습니다.");
    }

    final result = await ssh.executeCommandResult(
      fullHistory ? _tmuxInspectCommandFull : _tmuxInspectCommand,
      timeout: fullHistory
          ? const Duration(seconds: 60)
          : const Duration(seconds: 30),
    );
    final stdout = result.stdout.trim();
    final stderr = result.stderr.trim();
    return [
      if (stdout.isNotEmpty) stdout,
      if (stderr.isNotEmpty) "\n[stderr]\n$stderr",
      if (stdout.isEmpty && stderr.isEmpty) "(출력 없음)",
    ].join('\n');
  }

  Future<Directory> _resolveTmuxDownloadDir() async {
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

  String _timestampForFileName() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Future<T> _runBlockingAction<T>(
    String message,
    Future<T> Function() action,
  ) async {
    if (!mounted) return action();
    final metrics = _dialogMetrics(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          insetPadding: metrics.insetPadding,
          contentPadding: metrics.contentPadding,
          content: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
            child: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(fontSize: metrics.bodyFontSize),
                  ),
                ),
              ],
            ),
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

  Future<void> _refreshTmux({bool silent = false}) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _output = '';
      });
      return;
    }

    if (!silent && mounted) {
      setState(() => _isLoading = true);
    }
    try {
      final merged = await _fetchTmuxOutput(fullHistory: false);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _output = _trimOutput(merged);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _output = "tmux 조회 실패: $e";
      });
    }
  }

  Future<void> _copyOutput() async {
    try {
      final fullText = await _runBlockingAction<String>(
        'tmux 전체 로그 가져오는 중...',
        () => _fetchTmuxOutput(fullHistory: true),
      );
      await Clipboard.setData(ClipboardData(text: fullText));
      if (!mounted) return;
      CustomToast.show(context, "tmux 전체 로그를 복사했습니다.");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "tmux 로그 복사 실패: $e", isError: true);
    }
  }

  Future<void> _downloadOutputAsFile() async {
    try {
      final fullText = await _runBlockingAction<String>(
        'tmux 전체 로그 파일 저장 중...',
        () => _fetchTmuxOutput(fullHistory: true),
      );
      final dir = await _resolveTmuxDownloadDir();
      final file =
          File('${dir.path}/tmux_comma_${_timestampForFileName()}.log');
      await file.writeAsString(fullText);
      if (!mounted) return;
      CustomToast.show(context, "tmux 로그 저장됨: ${file.path}");
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, "tmux 로그 다운로드 실패: $e", isError: true);
    }
  }

  void _toggleLive(bool enabled) {
    setState(() => _isLive = enabled);
    _startPolling();
    if (enabled) {
      _refreshTmux(silent: true);
    }
  }

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'toggle_live':
        _toggleLive(!_isLive);
        break;
      case 'copy_all':
        await _copyOutput();
        break;
      case 'download':
        await _downloadOutputAsFile();
        break;
      case 'refresh':
        await _refreshTmux();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = context.watch<SSHService>().isConnected;
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final outputHorizontalPadding = window.isCompact
        ? 16.0
        : tokens.screenPadding.clamp(16.0, 28.0).toDouble();
    final outputFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.5,
      UiWindowClass.expanded => 13.0,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };

    return Column(
      children: [
        _LogsSubHeader(
          title: 'TMUX 로그',
          description: 'comma 세션 실시간 로그를 확인합니다. (${_isLive ? "ON" : "OFF"})',
          trailing: SizedBox(
            width: 36,
            height: 36,
            child: PopupMenuButton<String>(
              tooltip: "메뉴",
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 36,
                minHeight: 36,
              ),
              iconSize: 22,
              splashRadius: 20,
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                unawaited(_handleMenuAction(value));
              },
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  value: 'toggle_live',
                  child: Row(
                    children: [
                      Icon(
                        _isLive ? Icons.pause_circle_outline : Icons.play_arrow,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(_isLive ? '실시간 갱신 끄기' : '실시간 갱신 켜기'),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'refresh',
                  child: Row(
                    children: [
                      Icon(Icons.refresh, size: 18),
                      SizedBox(width: 8),
                      Text('새로고침'),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'copy_all',
                  child: Row(
                    children: [
                      Icon(Icons.copy_all, size: 18),
                      SizedBox(width: 8),
                      Text('전체 복사'),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'download',
                  child: Row(
                    children: [
                      Icon(Icons.download, size: 18),
                      SizedBox(width: 8),
                      Text('파일 저장'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: !connected
              ? const ConnectionRequiredView(
                  description: 'TMUX 로그를 보려면 먼저 기기에 연결하세요.',
                )
              : _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        outputHorizontalPadding,
                        10,
                        outputHorizontalPadding,
                        24,
                      ),
                      child: SelectableText(
                        _output.isEmpty ? "(출력 없음)" : _output,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: outputFontSize,
                        ),
                      ),
                    ),
        ),
      ],
    );
  }
}

class _LogsSubHeader extends StatelessWidget {
  final String title;
  final String description;
  final Widget? trailing;

  const _LogsSubHeader({
    required this.title,
    required this.description,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final headerHorizontalPadding = window.isCompact
        ? 14.0
        : tokens.screenPadding.clamp(14.0, 26.0).toDouble();
    final headerTopPadding = switch (window.windowClass) {
      UiWindowClass.compact => 10.0,
      UiWindowClass.medium => 11.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final descriptionFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.5,
      UiWindowClass.expanded => 13.0,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };
    final descriptionTopGap = switch (window.windowClass) {
      UiWindowClass.compact => 3.0,
      UiWindowClass.medium => 3.0,
      UiWindowClass.expanded => 4.0,
      UiWindowClass.large => 4.0,
      UiWindowClass.extraLarge => 4.0,
    };
    final trailingSlot = trailing == null
        ? null
        : SizedBox(
            width: window.isCompact ? 34 : 36,
            height: window.isCompact ? 34 : 36,
            child: Center(child: trailing!),
          );

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        headerHorizontalPadding,
        headerTopPadding,
        headerHorizontalPadding - 4,
        8,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainer
            .withValues(alpha: 0.55),
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withValues(alpha: 0.45),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              if (trailingSlot != null) ...[
                const SizedBox(width: 6),
                trailingSlot,
              ],
            ],
          ),
          SizedBox(height: descriptionTopGap),
          Text(
            description,
            maxLines: window.isCompact ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: descriptionFontSize,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
