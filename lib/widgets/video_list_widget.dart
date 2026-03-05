import 'dart:io';
import 'package:carrot_pilot_manager/services/ssh_service.dart';
import 'package:chewie/chewie.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';

class VideoListWidget extends StatefulWidget {
  const VideoListWidget({super.key});

  @override
  State<VideoListWidget> createState() => _VideoListWidgetState();
}

class _VideoListWidgetState extends State<VideoListWidget> {
  List<SftpName> _videos = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final ssh = Provider.of<SSHService>(context, listen: false);
      if (!ssh.isConnected) {
        setState(() {
          _error = "Not connected";
          _isLoading = false;
        });
        return;
      }

      // Assuming videos are in /data/media/0/videos
      // If this path doesn't exist, we might need to check /data/media/0/realdata or similar
      const videoPath = "/data/media/0/videos";

      // Check if directory exists first (optional, but good practice)
      // For now, just try to list
      List<SftpName> files;
      try {
        files = await ssh.listFiles(videoPath);
      } catch (e) {
        // If folder doesn't exist, try to create it or just show empty
        // But user might not have created it yet.
        // Let's just return empty list for now to avoid ugly error
        if (e.toString().contains("No such file")) {
          setState(() {
            _videos = [];
            _isLoading = false;
            _error = "영상 폴더가 없습니다 (/data/media/0/videos)";
          });
          return;
        }
        rethrow;
      }

      // Filter for video files (e.g., .mp4, .mkv, .hevc)
      // Openpilot often uses .hevc which might not play natively in all players without conversion
      // But let's assume standard formats or that the player can handle it.
      // If the user specifically asked for "recordings", they might be .mp4 exports.
      final videoFiles = files.where((f) {
        final name = f.filename.toLowerCase();
        return name.endsWith('.mp4') ||
            name.endsWith('.mkv') ||
            name.endsWith('.avi') ||
            name.endsWith('.mov');
      }).toList();

      // Sort by modification time (newest first)
      videoFiles.sort(
          (a, b) => (b.attr.modifyTime ?? 0).compareTo(a.attr.modifyTime ?? 0));

      setState(() {
        _videos = videoFiles;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = "Failed to load videos: $e";
        _isLoading = false;
      });
    }
  }

  Future<void> _playVideo(SftpName file) async {
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final ssh = Provider.of<SSHService>(context, listen: false);
      final tempDir = await getTemporaryDirectory();
      final localPath = '${tempDir.path}/${file.filename}';
      final localFile = File(localPath);

      // Download if not exists or maybe always overwrite to be safe?
      // For caching, we could check if it exists.
      if (!await localFile.exists()) {
        final remotePath = "/data/media/0/videos/${file.filename}";
        await ssh.downloadBinaryFile(remotePath, localPath);
      }

      if (mounted) {
        Navigator.pop(context); // Close loading
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VideoPlayerScreen(videoFile: localFile),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error playing video: $e")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(child: Text(_error!));
    }

    if (_videos.isEmpty) {
      return const Center(
          child: Text("No videos found in /data/media/0/videos"));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final listHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
                .clamp(window.isCompact ? 170.0 : 180.0, 300.0)
                .toDouble()
            : 230.0;
        final itemWidth =
            (constraints.maxWidth * (window.isCompact ? 0.52 : 0.40))
                .clamp(window.isCompact ? 160.0 : 170.0, 260.0)
                .toDouble();
        return SizedBox(
          height: listHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _videos.length,
            itemBuilder: (context, index) {
              final video = _videos[index];
              return SizedBox(
                width: itemWidth,
                child: Card(
                  child: InkWell(
                    onTap: () => _playVideo(video),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Container(
                            color: scheme.surfaceContainerHighest,
                            child: const Center(
                              child: Icon(Icons.play_circle_outline, size: 48),
                            ),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.all(tokens.itemGap + 2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                video.filename,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                              Text(
                                _formatSize(video.attr.size ?? 0),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  }
}

class VideoPlayerScreen extends StatefulWidget {
  final File videoFile;

  const VideoPlayerScreen({super.key, required this.videoFile});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    _videoPlayerController = VideoPlayerController.file(widget.videoFile);
    await _videoPlayerController.initialize();

    _chewieController = ChewieController(
      videoPlayerController: _videoPlayerController,
      autoPlay: true,
      looping: false,
      aspectRatio: _videoPlayerController.value.aspectRatio,
    );

    setState(() {});
  }

  @override
  void dispose() {
    _videoPlayerController.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Video Player")),
      body: Center(
        child: _chewieController != null &&
                _videoPlayerController.value.isInitialized
            ? Chewie(controller: _chewieController!)
            : const CircularProgressIndicator(),
      ),
    );
  }
}
