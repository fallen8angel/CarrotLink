import 'dart:async';
import 'dart:io';

import 'package:carrot_pilot_manager/widgets/drive_list_widget.dart';
import 'package:carrot_pilot_manager/widgets/video_list_widget.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../services/ssh_service.dart';
import '../../widgets/custom_toast.dart';
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
    return Column(
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
    );
  }
}

class _DashcamLogsView extends StatelessWidget {
  const _DashcamLogsView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        Text(
          "대시캠",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 8),
        Text(
          "주행 기록(라우트) 목록입니다.",
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        SizedBox(height: 12),
        SizedBox(height: 320, child: DriveListWidget()),
        SizedBox(height: 16),
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
  bool _isLoading = true;
  String? _error;
  String? _resolvedFolder;
  List<SftpName> _videos = [];

  @override
  void initState() {
    super.initState();
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _resolvedFolder = null;
      _videos = [];
    });

    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      setState(() {
        _error = "기기와 연결되어 있지 않습니다.";
        _isLoading = false;
      });
      return;
    }

    try {
      final exts = ['.mp4', '.mkv', '.avi', '.mov', '.ts', '.hevc'];

      for (final folder in widget.folderCandidates) {
        try {
          final files = await ssh.listFiles(folder);
          final videos = files.where((f) {
            final name = f.filename.toLowerCase();
            return exts.any(name.endsWith);
          }).toList();
          videos.sort(
            (a, b) =>
                (b.attr.modifyTime ?? 0).compareTo(a.attr.modifyTime ?? 0),
          );

          if (videos.isNotEmpty) {
            setState(() {
              _resolvedFolder = folder;
              _videos = videos;
              _isLoading = false;
            });
            return;
          }
        } catch (_) {
          // 후보 경로 실패는 다음 후보로 진행
        }
      }

      setState(() {
        _error = widget.emptyMessage;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
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
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  "폴더: ${_resolvedFolder ?? '-'}",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: "새로고침",
                onPressed: _loadVideos,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: _videos.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final video = _videos[index];
              return ListTile(
                dense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
                ),
                leading: const Icon(Icons.play_circle_outline),
                title: Text(
                  video.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  _formatSize(video.attr.size ?? 0),
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () => _playVideo(video),
              );
            },
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

  Future<void> _refreshTmux({bool silent = false}) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _output = "기기와 연결되어 있지 않습니다.";
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  "tmux 실시간 로그 (${_isLive ? "ON" : "OFF"})",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: "메뉴",
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
                          _isLive
                              ? Icons.pause_circle_outline
                              : Icons.play_arrow,
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
            ],
          ),
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: SelectableText(
                    _output.isEmpty ? "(출력 없음)" : _output,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
