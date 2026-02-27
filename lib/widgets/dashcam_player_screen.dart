import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class DashcamPlayerScreen extends StatefulWidget {
  final File? videoFile;
  final Uri? videoUri;
  final String title;
  final List<File> previewFrames;
  final Duration previewStep;
  final bool useScaffold;
  final Future<void> Function(int startSec, int endSec)? onShareRange;
  final VoidCallback? onClose;

  const DashcamPlayerScreen({
    super.key,
    this.videoFile,
    this.videoUri,
    required this.title,
    required this.previewFrames,
    required this.previewStep,
    this.useScaffold = true,
    this.onShareRange,
    this.onClose,
  }) : assert(videoFile != null || videoUri != null);

  @override
  State<DashcamPlayerScreen> createState() => _DashcamPlayerScreenState();
}

class _DashcamPlayerScreenState extends State<DashcamPlayerScreen> {
  static const Duration _positionPollInterval = Duration(milliseconds: 180);
  static const Duration _controlsAutoHideDelay = Duration(seconds: 4);

  late final VideoPlayerController _controller;
  Timer? _positionTimer;
  Timer? _controlsTimer;

  bool _initialized = false;
  bool _isScrubbing = false;
  bool _wasPlayingBeforeScrub = false;
  bool _showControls = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _scrubSeconds = 0;
  double _playbackSpeed = 1.0;
  String? _initError;

  @override
  void initState() {
    super.initState();
    if (widget.videoFile != null) {
      _controller = VideoPlayerController.file(widget.videoFile!);
    } else {
      _controller = VideoPlayerController.networkUrl(widget.videoUri!);
    }
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _controlsTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      await _controller.setLooping(false);
      if (!mounted) return;
      setState(() {
        _initialized = true;
        _duration = _controller.value.duration;
        _position = _controller.value.position;
      });
      _startPositionTimer();
      _restartControlsAutoHide();
      await _controller.play();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _initialized = false;
        _initError = '영상을 재생할 수 없습니다.';
      });
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(_positionPollInterval, (_) {
      if (!_initialized || !mounted || _isScrubbing) return;
      final value = _controller.value;
      setState(() {
        _position = value.position;
        _duration = value.duration;
      });
    });
  }

  void _restartControlsAutoHide() {
    _controlsTimer?.cancel();
    if (!_controller.value.isPlaying) return;
    _controlsTimer = Timer(_controlsAutoHideDelay, () {
      if (!mounted || _isScrubbing) return;
      setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _restartControlsAutoHide();
    }
  }

  Future<void> _togglePlayPause() async {
    if (!_initialized) return;
    if (_controller.value.isPlaying) {
      await _controller.pause();
    } else {
      await _controller.play();
    }
    if (!mounted) return;
    setState(() {
      _position = _controller.value.position;
      _duration = _controller.value.duration;
    });
    _restartControlsAutoHide();
  }

  Future<void> _seekBySeconds(int delta) async {
    if (!_initialized) return;
    final durationMs = _duration.inMilliseconds;
    final nextMs =
        (_position.inMilliseconds + delta * 1000).clamp(0, durationMs);
    await _controller.seekTo(Duration(milliseconds: nextMs));
    if (!mounted) return;
    setState(() => _position = Duration(milliseconds: nextMs));
    _restartControlsAutoHide();
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    _playbackSpeed = speed;
    await _controller.setPlaybackSpeed(speed);
    if (!mounted) return;
    setState(() {});
    _restartControlsAutoHide();
  }

  void _onScrubStart(double value) {
    if (!_initialized) return;
    _wasPlayingBeforeScrub = _controller.value.isPlaying;
    _isScrubbing = true;
    _scrubSeconds = value;
    unawaited(_controller.pause());
    setState(() {});
  }

  void _onScrubChanged(double value) {
    if (!_initialized) return;
    _scrubSeconds = value;
    setState(() {});
  }

  Future<void> _onScrubEnd(double value) async {
    if (!_initialized) return;
    final target = Duration(milliseconds: (value * 1000).round());
    await _controller.seekTo(target);
    if (_wasPlayingBeforeScrub) {
      await _controller.play();
    }
    if (!mounted) return;
    setState(() {
      _isScrubbing = false;
      _position = target;
    });
    _restartControlsAutoHide();
  }

  String _formatDuration(Duration value) {
    final total = value.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  File? _previewFrameForSecond(double second) {
    if (widget.previewFrames.isEmpty) return null;
    final step =
        widget.previewStep.inSeconds <= 0 ? 2 : widget.previewStep.inSeconds;
    final index = (second / step).round();
    final clamped = index.clamp(0, widget.previewFrames.length - 1);
    return widget.previewFrames[clamped];
  }

  List<PopupMenuEntry<double>> _speedMenuItems() {
    const values = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    return values
        .map(
          (speed) => PopupMenuItem<double>(
            value: speed,
            child: Text('${speed.toStringAsFixed(speed == 1.0 ? 0 : 2)}x'),
          ),
        )
        .toList();
  }

  Future<void> _openRangeShareSheet() async {
    if (!_initialized || widget.onShareRange == null) return;
    final totalSeconds = _duration.inSeconds;
    if (totalSeconds <= 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('구간 공유를 위한 재생 길이가 부족합니다.')),
      );
      return;
    }

    var startSec = math.max(0, _position.inSeconds - 10).toDouble();
    var endSec = math.min(totalSeconds.toDouble(), _position.inSeconds + 10.0);
    if (endSec <= startSec + 1) {
      endSec = math.min(totalSeconds.toDouble(), startSec + 1);
      if (endSec <= startSec) {
        startSec = math.max(0, endSec - 1);
      }
    }

    final selected = await showModalBottomSheet<(int, int)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final startFrame = _previewFrameForSecond(startSec);
            final endFrame = _previewFrameForSecond(endSec);

            Widget frameThumb(File? file, String label, double seconds) {
              return Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        color: Colors.black12,
                        height: 88,
                        width: double.infinity,
                        child: file == null
                            ? const Center(child: Icon(Icons.movie_outlined))
                            : Image.file(file, fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _formatDuration(
                          Duration(milliseconds: (seconds * 1000).round())),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              );
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '구간 공유',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '키프레임처럼 시작/종료를 선택해 공유',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        frameThumb(startFrame, '시작', startSec),
                        const SizedBox(width: 10),
                        frameThumb(endFrame, '종료', endSec),
                      ],
                    ),
                    const SizedBox(height: 10),
                    RangeSlider(
                      min: 0,
                      max: totalSeconds.toDouble(),
                      values: RangeValues(startSec, endSec),
                      labels: RangeLabels(
                        _formatDuration(
                            Duration(milliseconds: (startSec * 1000).round())),
                        _formatDuration(
                            Duration(milliseconds: (endSec * 1000).round())),
                      ),
                      onChanged: (range) {
                        var s = range.start;
                        var e = range.end;
                        if (e <= s + 1) {
                          if (e >= totalSeconds) {
                            s = e - 1;
                          } else {
                            e = s + 1;
                          }
                        }
                        setModalState(() {
                          startSec = s.clamp(0, totalSeconds - 1).toDouble();
                          endSec = e.clamp(1, totalSeconds).toDouble();
                        });
                      },
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('취소'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => Navigator.pop(
                              context,
                              (startSec.round(), endSec.round()),
                            ),
                            icon: const Icon(Icons.share),
                            label: const Text('이 구간 공유'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (selected == null) return;
    await widget.onShareRange!(selected.$1, selected.$2);
  }

  Widget _buildPreviewBubble({
    required double maxWidth,
    required double seconds,
  }) {
    final frame = _previewFrameForSecond(seconds);
    final durationSec = math.max(1, _duration.inSeconds).toDouble();
    final ratio = (seconds / durationSec).clamp(0.0, 1.0);
    const bubbleWidth = 180.0;
    const bubbleHeight = 120.0;
    final left = math.max(0, maxWidth - bubbleWidth) * ratio;

    return Transform.translate(
      offset: Offset(left, 0),
      child: Container(
        width: bubbleWidth,
        height: bubbleHeight,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 10,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
                child: frame == null
                    ? Container(
                        color: Colors.black26,
                        child: const Center(
                          child: Icon(Icons.movie, color: Colors.white54),
                        ),
                      )
                    : Image.file(
                        frame,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatDuration(Duration(milliseconds: (seconds * 1000).round())),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsOverlay() {
    final durationSec = math.max(1, _duration.inMilliseconds / 1000).toDouble();
    final positionSec =
        (_isScrubbing ? _scrubSeconds : (_position.inMilliseconds / 1000))
            .clamp(0.0, durationSec)
            .toDouble();

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: _showControls ? 1 : 0,
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.48),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.7),
              ],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 10,
                right: 10,
                top: 8,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    PopupMenuButton<double>(
                      tooltip: '배속',
                      onSelected: (speed) =>
                          unawaited(_setPlaybackSpeed(speed)),
                      itemBuilder: (_) => _speedMenuItems(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Text(
                          '${_playbackSpeed.toStringAsFixed(_playbackSpeed == 1.0 ? 0 : 2)}x',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    if (widget.onShareRange != null)
                      IconButton(
                        tooltip: '구간 공유',
                        onPressed: () => unawaited(_openRangeShareSheet()),
                        icon: const Icon(Icons.ios_share, color: Colors.white),
                      ),
                    if (widget.onClose != null) ...[
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: '닫기',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close, color: Colors.white),
                      ),
                    ],
                  ],
                ),
              ),
              Align(
                alignment: Alignment.center,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () => unawaited(_seekBySeconds(-10)),
                      iconSize: 42,
                      color: Colors.white,
                      icon: const Icon(Icons.replay_10),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: () => unawaited(_togglePlayPause()),
                      iconSize: 68,
                      color: Colors.white,
                      icon: Icon(
                        _controller.value.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: () => unawaited(_seekBySeconds(10)),
                      iconSize: 42,
                      color: Colors.white,
                      icon: const Icon(Icons.forward_10),
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_isScrubbing)
                            _buildPreviewBubble(
                              maxWidth: constraints.maxWidth,
                              seconds: positionSec,
                            ),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 4,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 7,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14,
                              ),
                            ),
                            child: Slider(
                              min: 0,
                              max: durationSec,
                              value: positionSec,
                              onChangeStart: _onScrubStart,
                              onChanged: _onScrubChanged,
                              onChangeEnd: (value) =>
                                  unawaited(_onScrubEnd(value)),
                            ),
                          ),
                          Row(
                            children: [
                              Text(
                                _formatDuration(Duration(
                                    milliseconds:
                                        (positionSec * 1000).round())),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _formatDuration(_duration),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoBody() {
    if (!_initialized) {
      return Center(
        child: _initError == null
            ? const CircularProgressIndicator()
            : Text(
                _initError!,
                style: const TextStyle(color: Colors.white70),
              ),
      );
    }

    final aspect = _controller.value.aspectRatio <= 0
        ? (16 / 9)
        : _controller.value.aspectRatio;

    return LayoutBuilder(
      builder: (context, constraints) {
        var width = constraints.maxWidth;
        var height = width / aspect;
        if (height > constraints.maxHeight) {
          height = constraints.maxHeight;
          width = height * aspect;
        }

        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  InteractiveViewer(
                    minScale: 1.0,
                    maxScale: 3.5,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: aspect,
                        child: VideoPlayer(_controller),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTap: () => unawaited(_seekBySeconds(-10)),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTap: () => unawaited(_seekBySeconds(10)),
                        ),
                      ),
                    ],
                  ),
                  _buildControlsOverlay(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.useScaffold) {
      return ColoredBox(
        color: Colors.black,
        child: _buildVideoBody(),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('세그먼트 재생'),
      ),
      body: _buildVideoBody(),
    );
  }
}
