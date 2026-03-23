part of 'live_drive_canvas_screen.dart';

class _DeveloperPlaybackVideoChoice {
  const _DeveloperPlaybackVideoChoice({
    required this.path,
    required this.label,
    required this.subtitle,
    this.isPickerAction = false,
  });

  final String path;
  final String label;
  final String subtitle;
  final bool isPickerAction;
}

extension _LiveDriveCanvasDeveloperPlaybackComponents
    on _LiveDriveCanvasScreenState {
  // This source mode is intentionally developer-only. It reuses the stock
  // viewport/zoom path while keeping offline video input separate from the
  // production live road-camera source so the whole path can be removed later.
  bool get _isDeveloperPlaybackRequestedImpl =>
      _developerPlaybackEnabled &&
      (_developerPlaybackVideoPath?.trim().isNotEmpty ?? false);

  bool get _isDeveloperPlaybackActiveImpl {
    final controller = _developerPlaybackController;
    return _isDeveloperPlaybackRequestedImpl &&
        controller != null &&
        controller.value.isInitialized;
  }

  Size get _effectiveViewportSourceSizeImpl {
    final controller = _developerPlaybackController;
    if (_isDeveloperPlaybackActiveImpl &&
        controller != null &&
        controller.value.isInitialized) {
      final size = controller.value.size;
      if (size.width > 1 && size.height > 1) {
        return size;
      }
    }
    return _cameraSourceSize;
  }

  Future<void> _loadDeveloperPlaybackSelectionImpl() async {
    final selectedPath =
        await YoloStockDebugPlaybackStore.loadSelectedVideoPath();
    if (selectedPath == null || selectedPath.isEmpty) return;
    final file = File(selectedPath);
    if (!await file.exists()) {
      await YoloStockDebugPlaybackStore.saveSelectedVideoPath(null);
      return;
    }
    if (mounted) {
      _safeSetState(() {
        _developerPlaybackVideoPath = selectedPath;
      });
    } else {
      _developerPlaybackVideoPath = selectedPath;
    }
  }

  Future<void> _selectDeveloperPlaybackVideoImpl() async {
    final keepOfflineMode =
        _developerPlaybackEnabled || _developerPlaybackController != null;
    final keepPlaying = _developerPlaybackController?.value.isPlaying ?? false;
    final choices = await _developerPlaybackChoices();
    if (!mounted) return;
    final selected = await showModalBottomSheet<_DeveloperPlaybackVideoChoice>(
      context: context,
      backgroundColor: const Color(0xFF17120F),
      builder: (ctx) {
        return SafeArea(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: choices.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: Colors.white12),
            itemBuilder: (context, index) {
              final choice = choices[index];
              return ListTile(
                title: Text(
                  choice.label,
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: choice.subtitle.isEmpty
                    ? null
                    : Text(
                        choice.subtitle,
                        style: const TextStyle(color: Colors.white70),
                      ),
                onTap: () => Navigator.of(ctx).pop(choice),
              );
            },
          ),
        );
      },
    );
    if (selected == null) return;

    if (selected.isPickerAction) {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowMultiple: false,
        withData: false,
        allowedExtensions: const <String>[
          'ts',
          'mp4',
          'mov',
          'mkv',
          'avi',
          'webm',
        ],
      );
      final path = picked?.files.single.path?.trim();
      if (path == null || path.isEmpty) return;
      await _setDeveloperPlaybackVideoPath(
        path,
        requestOfflineMode: keepOfflineMode,
        startPlaying: keepPlaying,
      );
      return;
    }

    await _setDeveloperPlaybackVideoPath(
      selected.path,
      requestOfflineMode: keepOfflineMode,
      startPlaying: keepPlaying,
    );
  }

  Future<void> _clearDeveloperPlaybackSelectionImpl() async {
    await _stopDeveloperPlayback(clearSelection: true);
  }

  Future<void> _toggleDeveloperPlaybackEnabledImpl() async {
    if (_developerPlaybackEnabled) {
      await _stopDeveloperPlayback(clearSelection: false);
      return;
    }
    final selectedPath = _developerPlaybackVideoPath?.trim();
    if (selectedPath == null || selectedPath.isEmpty) {
      await _selectDeveloperPlaybackVideo();
      return;
    }
    await _setDeveloperPlaybackVideoPath(
      selectedPath,
      requestOfflineMode: true,
      startPlaying: true,
    );
  }

  Future<void> _pauseDeveloperPlaybackImpl() async {
    final controller = _developerPlaybackController;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.pause();
    _developerPlaybackTimer?.cancel();
    _developerPlaybackTimer = null;
    _developerPlaybackNextTickAtMs = 0;
    await _runDeveloperPlaybackTick(force: true);
    if (!mounted) return;
    // Keep the last YOLO snapshot on screen for freeze-frame debugging.
    _safeSetState(() {});
  }

  Future<void> _resumeDeveloperPlaybackImpl() async {
    final controller = _developerPlaybackController;
    if (controller == null || !controller.value.isInitialized) return;
    _developerPlaybackLastRequestedPositionMs = -1;
    _developerPlaybackNextTickAtMs = 0;
    await controller.play();
    if (mounted) {
      _safeSetState(() {});
    }
    _syncDeveloperPlaybackLoop();
    await _runDeveloperPlaybackTick(force: true);
  }

  Future<void> _waitForDeveloperPlaybackIdle({
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (_developerPlaybackBusy && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<void> _setDeveloperPlaybackVideoPath(
    String path, {
    required bool requestOfflineMode,
    bool startPlaying = false,
  }) async {
    final normalized = path.trim();
    if (normalized.isEmpty) return;
    final file = File(normalized);
    if (!await file.exists()) {
      if (!mounted) return;
      _toast('영상 파일을 찾을 수 없습니다.', isError: true);
      return;
    }

    final wasOfflineRequested = _developerPlaybackEnabled;
    final previousController = _developerPlaybackController;
    final wasOfflinePrepared =
        wasOfflineRequested || previousController != null;
    final needsOfflineBootstrap = requestOfflineMode &&
        !wasOfflineRequested &&
        previousController == null;

    await YoloStockDebugPlaybackStore.saveSelectedVideoPath(normalized);
    if (wasOfflinePrepared) {
      _developerPlaybackSourceEpoch += 1;
      _developerPlaybackTimer?.cancel();
      _developerPlaybackTimer = null;
      _developerPlaybackNextTickAtMs = 0;
      _developerPlaybackLastResolvedFrameToken = null;
      await _waitForDeveloperPlaybackIdle();
      _developerPlaybackController = null;
      _detachDeveloperPlaybackControllerListener(previousController);
      if (previousController != null) {
        await previousController.pause();
        await previousController.dispose();
      }
      await _clearDeveloperPlaybackSession();
    }
    if (requestOfflineMode) {
      await _disableNativeYoloForDeveloperPlaybackImpl();
      _nativeCameraViewId = null;
      _lastNativeYoloConfigSignature = null;
      await _clearNativeOverlay();
    }

    final loadingSnapshot = YoloRuntimeStatusSnapshot(
      config: const <String, dynamic>{},
      state: <String, dynamic>{
        'stage': requestOfflineMode
            ? 'offline_video_playback_loading'
            : 'offline_video_playback_selected',
        'inputPath': normalized,
        'parsedDetections': const <Map<String, dynamic>>[],
      },
      updatedAt: DateTime.now(),
    );
    if (mounted) {
      _safeSetState(() {
        _developerPlaybackVideoPath = normalized;
        _developerPlaybackEnabled = requestOfflineMode;
        _developerPlaybackLoading = requestOfflineMode;
        _developerPlaybackError = null;
        _developerPlaybackLastRequestedPositionMs = -1;
        _developerPlaybackNextTickAtMs = 0;
        _developerPlaybackLastResolvedFrameToken = null;
        _driveYoloRuntimeStatus = loadingSnapshot;
        _developerPlaybackStatusUpdatedAt = loadingSnapshot.updatedAt;
      });
    } else {
      _developerPlaybackVideoPath = normalized;
      _developerPlaybackEnabled = requestOfflineMode;
      _developerPlaybackLoading = requestOfflineMode;
      _developerPlaybackError = null;
      _developerPlaybackLastRequestedPositionMs = -1;
      _developerPlaybackNextTickAtMs = 0;
      _developerPlaybackLastResolvedFrameToken = null;
      _driveYoloRuntimeStatus = loadingSnapshot;
      _developerPlaybackStatusUpdatedAt = loadingSnapshot.updatedAt;
    }

    if (!requestOfflineMode) return;
    // Let the AndroidView teardown finish before the offline YOLO session
    // boots. The developer-only playback path must not overlap with the live
    // native YOLO runtime on the same device process.
    if (needsOfflineBootstrap) {
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    await _initializeDeveloperPlaybackController(
      normalized,
      startPlaying: startPlaying,
    );
  }

  Future<void> _initializeDeveloperPlaybackController(
    String path, {
    required bool startPlaying,
  }) async {
    final initEpoch = _developerPlaybackSourceEpoch;
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.setLooping(true);
      if (startPlaying) {
        await controller.play();
      } else {
        await controller.seekTo(Duration.zero);
      }
      if (initEpoch != _developerPlaybackSourceEpoch) {
        await controller.dispose();
        return;
      }
      if (!mounted) {
        _developerPlaybackController = controller;
        _attachDeveloperPlaybackControllerListener(controller);
        _developerPlaybackLoading = false;
        _developerPlaybackError = null;
        _cameraLoading = false;
        _cameraError = null;
        return;
      }
      _safeSetState(() {
        _developerPlaybackController = controller;
        _attachDeveloperPlaybackControllerListener(controller);
        _developerPlaybackLoading = false;
        _developerPlaybackError = null;
        _cameraLoading = false;
        _cameraError = null;
      });
      if (startPlaying) {
        _syncDeveloperPlaybackLoop();
      }
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      _safeSetState(() {
        _developerPlaybackEnabled = false;
        _developerPlaybackLoading = false;
        _developerPlaybackError = '영상 재생 준비 실패: $e';
      });
    }
  }

  Future<void> _stopDeveloperPlayback({
    required bool clearSelection,
  }) async {
    _developerPlaybackSourceEpoch += 1;
    _developerPlaybackTimer?.cancel();
    _developerPlaybackTimer = null;
    _developerPlaybackNextTickAtMs = 0;
    _developerPlaybackLastResolvedFrameToken = null;
    await _waitForDeveloperPlaybackIdle();
    final controller = _developerPlaybackController;
    _developerPlaybackController = null;
    _detachDeveloperPlaybackControllerListener(controller);
    if (controller != null) {
      await controller.pause();
      await controller.dispose();
    }
    await _clearDeveloperPlaybackSession();
    if (clearSelection) {
      await YoloStockDebugPlaybackStore.saveSelectedVideoPath(null);
    }
    if (mounted) {
      _safeSetState(() {
        _developerPlaybackEnabled = false;
        _developerPlaybackLoading = false;
        _developerPlaybackError = null;
        _developerPlaybackLastRequestedPositionMs = -1;
        _developerPlaybackNextTickAtMs = 0;
        _developerPlaybackLastResolvedFrameToken = null;
        if (clearSelection) {
          _developerPlaybackVideoPath = null;
        }
      });
    } else {
      _developerPlaybackEnabled = false;
      _developerPlaybackLoading = false;
      _developerPlaybackError = null;
      _developerPlaybackLastRequestedPositionMs = -1;
      _developerPlaybackNextTickAtMs = 0;
      _developerPlaybackLastResolvedFrameToken = null;
      if (clearSelection) {
        _developerPlaybackVideoPath = null;
      }
    }
    unawaited(_pushNativeYoloConfig(force: true));
  }

  Future<void> _clearDeveloperPlaybackSessionImpl() async {
    try {
      await YoloOfflineDebugRunner.clearVideoPlaybackSession();
    } catch (_) {
      // Developer-only debug cleanup should not break the stock route.
    }
  }

  int _developerPlaybackSourceIntValue(String key) {
    final stateValue = _driveYoloRuntimeStatus.state[key];
    if (stateValue is int) return stateValue;
    if (stateValue is num) return stateValue.toInt();
    final configValue = _driveYoloRuntimeStatus.config[key];
    if (configValue is int) return configValue;
    if (configValue is num) return configValue.toInt();
    return int.tryParse('${stateValue ?? configValue ?? ''}') ?? 0;
  }

  bool _developerPlaybackSourceBoolValue(String key) {
    final stateValue = _driveYoloRuntimeStatus.state[key];
    if (stateValue is bool) return stateValue;
    if (stateValue is num) return stateValue != 0;
    final stateText = stateValue?.toString().trim().toLowerCase() ?? '';
    if (stateText == 'true' || stateText == '1' || stateText == 'yes') {
      return true;
    }
    final configValue = _driveYoloRuntimeStatus.config[key];
    if (configValue is bool) return configValue;
    if (configValue is num) return configValue != 0;
    final configText = configValue?.toString().trim().toLowerCase() ?? '';
    return configText == 'true' || configText == '1' || configText == 'yes';
  }

  Duration _developerPlaybackTickInterval() {
    final raw = _developerPlaybackSourceIntValue('samplePeriodMs');
    final resolved = raw > 0 ? raw : 140;
    final devIntervalMs = math.max(90, math.min(resolved, 140));
    return Duration(milliseconds: devIntervalMs);
  }

  String? _developerPlaybackFrameToken(YoloRuntimeStatusSnapshot snapshot) {
    final value = snapshot.state['playbackFrameToken'] ??
        snapshot.config['playbackFrameToken'];
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty || text == '-') {
      return null;
    }
    return text;
  }

  void _detachDeveloperPlaybackControllerListener(
    VideoPlayerController? controller,
  ) {
    final listener = _developerPlaybackControllerListener;
    if (controller != null && listener != null) {
      controller.removeListener(listener);
    }
    if (controller == null ||
        identical(controller, _developerPlaybackController)) {
      _developerPlaybackControllerListener = null;
    }
  }

  void _attachDeveloperPlaybackControllerListener(
    VideoPlayerController controller,
  ) {
    _detachDeveloperPlaybackControllerListener(controller);
    void listener() => _handleDeveloperPlaybackControllerChanged();
    _developerPlaybackControllerListener = listener;
    controller.addListener(listener);
  }

  void _handleDeveloperPlaybackControllerChanged() {
    final controller = _developerPlaybackController;
    if (controller == null || !controller.value.isInitialized) {
      _developerPlaybackTimer?.cancel();
      _developerPlaybackTimer = null;
      return;
    }
    if (!_developerPlaybackEnabled ||
        !_driveYoloDebugSettings.enabled ||
        _developerPlaybackLoading ||
        _developerPlaybackError != null) {
      _developerPlaybackTimer?.cancel();
      _developerPlaybackTimer = null;
      return;
    }
    if (!controller.value.isPlaying) {
      _developerPlaybackTimer?.cancel();
      _developerPlaybackTimer = null;
      return;
    }
    _scheduleDeveloperPlaybackTick();
  }

  void _scheduleDeveloperPlaybackTick({bool force = false}) {
    final controller = _developerPlaybackController;
    if (controller == null || !controller.value.isInitialized) return;
    if ((!_developerPlaybackEnabled || !_driveYoloDebugSettings.enabled) &&
        !force) {
      return;
    }
    if (!controller.value.isPlaying && !force) return;
    if (_developerPlaybackBusy) return;
    final position = controller.value.position;
    if (!force && position < const Duration(milliseconds: 550)) {
      return;
    }
    final positionMs = position.inMilliseconds;
    if (!force && _developerPlaybackLastRequestedPositionMs == positionMs) {
      return;
    }
    if (_developerPlaybackTimer != null && !force) {
      return;
    }
    _developerPlaybackTimer?.cancel();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final delayMs =
        force ? 0 : math.max(0, _developerPlaybackNextTickAtMs - nowMs);
    _developerPlaybackTimer = Timer(Duration(milliseconds: delayMs), () {
      _developerPlaybackTimer = null;
      unawaited(_runDeveloperPlaybackTick(force: force));
    });
  }

  void _syncDeveloperPlaybackLoop() {
    _developerPlaybackTimer?.cancel();
    _developerPlaybackTimer = null;
    if (!_isDeveloperPlaybackActiveImpl) return;
    if (!_driveYoloDebugSettings.enabled) return;
    final controller = _developerPlaybackController;
    if (controller == null || !controller.value.isPlaying) return;
    _scheduleDeveloperPlaybackTick();
  }

  Future<void> _runDeveloperPlaybackTick({bool force = false}) async {
    if (_developerPlaybackBusy) return;
    final path = _developerPlaybackVideoPath?.trim();
    final controller = _developerPlaybackController;
    final requestEpoch = _developerPlaybackSourceEpoch;
    if (path == null ||
        path.isEmpty ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    if (!_developerPlaybackEnabled && !force) return;
    if (!_driveYoloDebugSettings.enabled && !force) return;
    if (!controller.value.isPlaying && !force) return;
    final position = controller.value.position;
    if (!force && position < const Duration(milliseconds: 550)) {
      return;
    }
    final positionMs = position.inMilliseconds;
    if (!force && _developerPlaybackLastRequestedPositionMs == positionMs) {
      return;
    }
    _developerPlaybackBusy = true;
    try {
      final snapshot = await YoloOfflineDebugRunner.runVideoFrameAtPosition(
        path: path,
        position: position,
        settings: _driveYoloDebugSettings,
        camera: _liveCameraName,
      );
      _developerPlaybackNextTickAtMs = DateTime.now().millisecondsSinceEpoch +
          _developerPlaybackTickInterval().inMilliseconds;
      if (requestEpoch != _developerPlaybackSourceEpoch) return;
      final frameToken = _developerPlaybackFrameToken(snapshot);
      if (!force &&
          frameToken != null &&
          frameToken == _developerPlaybackLastResolvedFrameToken) {
        _developerPlaybackLastRequestedPositionMs = positionMs;
        return;
      }
      if (!mounted) {
        _developerPlaybackLastRequestedPositionMs = positionMs;
        _developerPlaybackLastResolvedFrameToken = frameToken;
        _driveYoloRuntimeStatus = snapshot;
        _developerPlaybackStatusUpdatedAt = snapshot.updatedAt;
        return;
      }
      _safeSetState(() {
        _developerPlaybackLastRequestedPositionMs = positionMs;
        _developerPlaybackLastResolvedFrameToken = frameToken;
        _driveYoloRuntimeStatus = snapshot;
        _developerPlaybackStatusUpdatedAt = snapshot.updatedAt;
      });
    } catch (e) {
      _developerPlaybackNextTickAtMs = DateTime.now().millisecondsSinceEpoch +
          _developerPlaybackTickInterval().inMilliseconds;
      if (requestEpoch != _developerPlaybackSourceEpoch) return;
      if (!mounted) return;
      _safeSetState(() {
        _driveYoloRuntimeStatus = YoloRuntimeStatusSnapshot(
          config: const <String, dynamic>{},
          state: <String, dynamic>{
            'stage': 'offline_video_playback_debug_failed',
            'blocker': 'runtime_request_failed',
            'lastError': e.toString(),
          },
          updatedAt: DateTime.now(),
        );
        _developerPlaybackStatusUpdatedAt = DateTime.now();
      });
    } finally {
      _developerPlaybackBusy = false;
    }
  }

  Future<List<_DeveloperPlaybackVideoChoice>>
      _developerPlaybackChoices() async {
    final choices = <_DeveloperPlaybackVideoChoice>[
      const _DeveloperPlaybackVideoChoice(
        path: '__pick__',
        label: '파일 선택',
        subtitle: '',
        isPickerAction: true,
      ),
    ];
    final recentFiles = await _recentDashcamCacheVideoFiles();
    for (final file in recentFiles) {
      final stat = await file.stat();
      choices.add(
        _DeveloperPlaybackVideoChoice(
          path: file.path,
          label: p.basename(file.path),
          subtitle: stat.modified.toLocal().toString(),
        ),
      );
    }
    return choices;
  }

  Future<List<File>> _recentDashcamCacheVideoFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final cacheRoot = Directory(p.join(tempDir.path, 'dashcam_cache'));
      if (!await cacheRoot.exists()) return const <File>[];
      final files = <File>[];
      await for (final entity in cacheRoot.list(recursive: true)) {
        if (entity is! File) continue;
        final lower = entity.path.toLowerCase();
        if (lower.endsWith('.ts') ||
            lower.endsWith('.mp4') ||
            lower.endsWith('.mov') ||
            lower.endsWith('.mkv') ||
            lower.endsWith('.avi') ||
            lower.endsWith('.webm')) {
          files.add(entity);
        }
      }
      files.sort((a, b) {
        final aStat = a.statSync();
        final bStat = b.statSync();
        return bStat.modified.compareTo(aStat.modified);
      });
      return files.take(12).toList(growable: false);
    } catch (_) {
      return const <File>[];
    }
  }

  Widget _buildDeveloperPlaybackSurfaceImpl() {
    if (!_isDeveloperPlaybackRequestedImpl) {
      return const ColoredBox(color: Colors.black);
    }
    final controller = _developerPlaybackController;
    if (_developerPlaybackLoading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2.4),
      );
    }
    if (_developerPlaybackError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Text(
            _developerPlaybackError!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    final enabled = _driveYoloDebugSettings.enabled &&
        _developerPlaybackSourceBoolValue('yoloEnabled');
    if (!enabled) {
      return VideoPlayer(controller);
    }
    final detections = YoloDetection.listFromPayload(
      _driveYoloRuntimeStatus.state['parsedDetections'],
    );
    final showLabels = _developerPlaybackSourceBoolValue('yoloLabels');
    final forceVisibleBoxes = detections.isNotEmpty &&
        !_developerPlaybackSourceBoolValue('yoloBoxes') &&
        !showLabels;
    final showBoxes =
        _developerPlaybackSourceBoolValue('yoloBoxes') || forceVisibleBoxes;
    final sourceWidth = _developerPlaybackSourceIntValue('sourceWidth');
    final sourceHeight = _developerPlaybackSourceIntValue('sourceHeight');
    final sourceSize = Size(
      sourceWidth > 0 ? sourceWidth.toDouble() : controller.value.size.width,
      sourceHeight > 0 ? sourceHeight.toDouble() : controller.value.size.height,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        VideoPlayer(controller),
        if (showBoxes || showLabels)
          YoloDetectionOverlay(
            key: ValueKey<String>(
              'developer_playback_overlay_$_developerPlaybackSourceEpoch',
            ),
            detections: detections,
            sourceWidth: sourceSize.width,
            sourceHeight: sourceSize.height,
            showBoxes: showBoxes,
            showLabels: showLabels,
          ),
        if (detections.isNotEmpty)
          Positioned(
            left: 10,
            top: 10,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Colors.cyanAccent.withValues(alpha: 0.72),
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  'YOLO ${detections.length} detections',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
