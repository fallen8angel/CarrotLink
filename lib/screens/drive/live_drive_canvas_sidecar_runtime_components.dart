part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasSidecarRuntimeComponents
    on _LiveDriveCanvasScreenState {
  void _clearSidecarRecoveryScheduleImpl() {
    _sidecarRecoveryTimer?.cancel();
    _sidecarRecoveryTimer = null;
    _sidecarRecoveryNextAt = null;
    _sidecarRecoveryBackoffSeconds = 1;
  }

  void _scheduleSidecarRuntimeRecoveryImpl({
    required String reason,
    Duration minDelay = const Duration(milliseconds: 600),
    bool preferSooner = false,
  }) {
    if (!_openpilotOverlayMode || _cameraSuspendedByLifecycle) return;
    final now = DateTime.now();
    final backoff = Duration(seconds: _sidecarRecoveryBackoffSeconds);
    final delay =
        preferSooner ? minDelay : (backoff > minDelay ? backoff : minDelay);
    final nextAt = now.add(delay);
    if (_sidecarRecoveryNextAt != null &&
        now.isBefore(_sidecarRecoveryNextAt!) &&
        !nextAt.isBefore(_sidecarRecoveryNextAt!)) {
      return;
    }
    _sidecarRecoveryNextAt = nextAt;
    _sidecarRecoveryTimer?.cancel();
    _pushSidecarHistory(
      'AUTO_RECOVER',
      'scheduled ${delay.inMilliseconds}ms reason=$reason',
    );
    _sidecarRecoveryTimer = Timer(delay, () {
      _sidecarRecoveryTimer = null;
      _sidecarRecoveryNextAt = null;
      unawaited(_ensureSidecarRuntime(reason: 'recover:$reason'));
    });
    if (!preferSooner) {
      _sidecarRecoveryBackoffSeconds =
          math.min(_sidecarRecoveryBackoffSeconds * 2, 8);
    }
  }

  String _adaptiveCameraQualityLabel(_AdaptiveCameraQualityMode mode) {
    return 'stable';
  }

  void _resetAdaptiveCameraQualityState({bool resetMode = false}) {
    _adaptiveCameraQualitySynced = false;
    if (resetMode) {
      _adaptiveCameraQualityMode = _AdaptiveCameraQualityMode.lowLatency;
    }
  }

  void _startAdaptiveCameraQualityLoop() {
    _adaptiveCameraQualityTimer?.cancel();
    _adaptiveCameraQualityTimer = null;
    _resetAdaptiveCameraQualityState(resetMode: true);
    unawaited(
      _setAdaptiveCameraQualityMode(
        _adaptiveCameraQualityMode,
        reason: 'init',
        force: true,
      ),
    );
  }

  void _stopAdaptiveCameraQualityLoop({bool resetMode = false}) {
    _adaptiveCameraQualityTimer?.cancel();
    _adaptiveCameraQualityTimer = null;
    _adaptiveCameraQualityBusy = false;
    _resetAdaptiveCameraQualityState(resetMode: resetMode);
  }

  Future<void> _setAdaptiveCameraQualityMode(
    _AdaptiveCameraQualityMode _, {
    required String reason,
    bool force = false,
  }) async {
    if (!_openpilotOverlayMode || _cameraSuspendedByLifecycle) return;
    if (_adaptiveCameraQualityBusy) return;
    if (!force && _adaptiveCameraQualitySynced) {
      return;
    }
    _adaptiveCameraQualityBusy = true;
    final modeLabel =
        _adaptiveCameraQualityLabel(_AdaptiveCameraQualityMode.lowLatency);
    try {
      final response = await _cameraPostJson(
        '/camera_quality',
        body: <String, dynamic>{'mode': modeLabel},
      );
      if (response['ok'] != true) {
        throw Exception(response['error']?.toString() ?? 'unknown error');
      }
      _adaptiveCameraQualityMode = _AdaptiveCameraQualityMode.lowLatency;
      _adaptiveCameraQualitySynced = true;
      _pushSidecarHistory('CAM_QUALITY', 'mode=$modeLabel reason=$reason');
    } catch (e) {
      _adaptiveCameraQualitySynced = false;
      _pushSidecarHistory(
          'CAM_QUALITY_FAIL', 'mode=$modeLabel reason=$reason $e');
    } finally {
      _adaptiveCameraQualityBusy = false;
    }
  }

  String _fmtClock(DateTime? when) {
    if (when == null) return '-';
    final t = when.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Map<String, String> _parseStatusPairs(String raw) {
    final parsed = <String, String>{};
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final idx = trimmed.indexOf('=');
      if (idx <= 0) continue;
      final key = trimmed.substring(0, idx).trim();
      final value = trimmed.substring(idx + 1).trim();
      if (key.isEmpty) continue;
      parsed[key] = value;
    }
    return parsed;
  }

  bool _profileRequiresLiveRuntime(String? profile) {
    return SidecarService.profileProvidesGraphicsRuntime(profile);
  }

  String _preferredDriveRuntimeProfile([Map<String, dynamic>? health]) {
    return SidecarService.driveRuntimeProfileForFlavor(_sidecarRepoFlavorOf(
      health,
    ));
  }

  String _normalizeSidecarVariant(String? variant) {
    final normalized = (variant ?? '').trim().toLowerCase();
    switch (normalized) {
      case SidecarService.c4SafeVariant:
        return SidecarService.c4SafeVariant;
      case SidecarService.defaultVariant:
      default:
        return SidecarService.defaultVariant;
    }
  }

  String _normalizeSidecarRepoFlavor(String? flavor) {
    final normalized = (flavor ?? '').trim().toLowerCase();
    switch (normalized) {
      case SidecarService.repoFlavorC3:
        return SidecarService.repoFlavorC3;
      case SidecarService.repoFlavorC4:
        return SidecarService.repoFlavorC4;
      case SidecarService.repoFlavorUnknown:
      default:
        return SidecarService.repoFlavorUnknown;
    }
  }

  void _applyResolvedSidecarFlavorHints({
    String? repoFlavor,
    String? variant,
  }) {
    final normalizedFlavor = _normalizeSidecarRepoFlavor(repoFlavor);
    final normalizedVariant = _normalizeSidecarVariant(variant);
    if (_sidecarRepoFlavorHint == normalizedFlavor &&
        _sidecarVariantHint == normalizedVariant) {
      return;
    }
    if (!mounted) {
      _sidecarRepoFlavorHint = normalizedFlavor;
      _sidecarVariantHint = normalizedVariant;
      return;
    }
    _safeSetState(() {
      _sidecarRepoFlavorHint = normalizedFlavor;
      _sidecarVariantHint = normalizedVariant;
    });
  }

  Future<void> _primeSidecarFlavorHintsImpl({
    bool forceRefresh = false,
  }) async {
    if (!_openpilotOverlayMode) {
      return;
    }
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      return;
    }
    if (!forceRefresh &&
        _sidecarRepoFlavorOf() != SidecarService.repoFlavorUnknown) {
      return;
    }
    if (_sidecarFlavorHintResolving) {
      return;
    }
    _sidecarFlavorHintResolving = true;
    try {
      final resolvedVariant = await _sidecarService.resolveRemoteVariant(
        ssh,
        forceRefresh: forceRefresh,
      );
      final resolvedRepoFlavor = await _sidecarService.resolveRemoteRepoFlavor(
        ssh,
        forceRefresh: forceRefresh,
      );
      _applyResolvedSidecarFlavorHints(
        repoFlavor: resolvedRepoFlavor,
        variant: resolvedVariant,
      );
    } catch (_) {
      // Ignore flavor-hint priming failures; runtime bootstrap will retry.
    } finally {
      _sidecarFlavorHintResolving = false;
    }
  }

  String _sidecarRepoFlavorOf([Map<String, dynamic>? snapshot]) {
    final candidates = <dynamic>[
      snapshot?['repoFlavor'],
      _sidecarHealthSnapshot['repoFlavor'],
      _sidecarProfileSnapshot['repoFlavor'],
      _sidecarRepoFlavorHint,
    ];
    for (final raw in candidates) {
      final text = raw?.toString().trim();
      if (text == null || text.isEmpty) {
        continue;
      }
      final normalized = _normalizeSidecarRepoFlavor(text);
      if (normalized != SidecarService.repoFlavorUnknown) {
        return normalized;
      }
    }
    return SidecarService.repoFlavorUnknown;
  }

  String get _currentSidecarProfile =>
      _sidecarProfileName(_sidecarProfileSnapshot) ??
      SidecarService.hudBootstrapProfile;

  String _preferredBootstrapProfile([Map<String, dynamic>? health]) {
    if (_sidecarRepoFlavorOf(health) == SidecarService.repoFlavorC4) {
      return SidecarService.c4HudBootstrapProfile;
    }
    return SidecarService.hudBootstrapProfile;
  }

  bool _sidecarHealthServiceFresh(
    Map<String, dynamic> health,
    String name,
  ) {
    final raw = health['serviceHealth'];
    if (raw is! Map) {
      return false;
    }
    final service = raw[name];
    if (service is Map<String, dynamic>) {
      return service['isFresh'] == true;
    }
    if (service is Map) {
      return service['isFresh'] == true;
    }
    return false;
  }

  bool _sidecarHealthIndicatesGraphicsRuntimeReady([
    Map<String, dynamic>? health,
  ]) {
    final snapshot = health ?? _sidecarHealthSnapshot;
    if (snapshot.isEmpty) {
      return false;
    }
    if (snapshot['graphicsReady'] == true) {
      return true;
    }
    final expectedCameraService = _liveCameraName == 'wideRoad'
        ? 'wideRoadCameraState'
        : 'roadCameraState';
    return snapshot['hudReady'] == true &&
        snapshot['liveReady'] == true &&
        _sidecarHealthServiceFresh(snapshot, 'liveCalibration') &&
        _sidecarHealthServiceFresh(snapshot, 'modelV2') &&
        _sidecarHealthServiceFresh(snapshot, expectedCameraService);
  }

  bool _sidecarHealthIndicatesDriveRuntimeReady(
      [Map<String, dynamic>? health]) {
    final snapshot = health ?? _sidecarHealthSnapshot;
    if (snapshot.isEmpty) {
      return false;
    }
    if (snapshot['driveReady'] == true) {
      return true;
    }
    return _sidecarHealthIndicatesGraphicsRuntimeReady(snapshot) &&
        _sidecarHealthServiceFresh(snapshot, 'carState') &&
        _sidecarHealthServiceFresh(snapshot, 'controlsState');
  }

  bool _sidecarHealthIndicatesFullRuntimeReady([Map<String, dynamic>? health]) {
    final snapshot = health ?? _sidecarHealthSnapshot;
    if (snapshot.isEmpty) {
      return false;
    }
    if (snapshot['fullReady'] == true) {
      return true;
    }
    return _sidecarHealthIndicatesDriveRuntimeReady(snapshot) &&
        _sidecarHealthServiceFresh(snapshot, 'radarState');
  }

  bool _shouldRecoverSidecarForOverlayStall() {
    if (!_openpilotOverlayMode ||
        !_sidecarConnected ||
        _cameraSuspendedByLifecycle ||
        _startupProvisionalSyncActive) {
      return false;
    }
    return !_sidecarHealthIndicatesGraphicsRuntimeReady();
  }

  bool _shouldEscalateToSidecarRecovery({
    bool graphicsCritical = false,
    bool vehicleCritical = false,
    bool fullCritical = false,
  }) {
    if (!_openpilotOverlayMode || _cameraSuspendedByLifecycle) {
      return false;
    }
    if (_sidecarAutoManaging) {
      return false;
    }
    final hasFallback = _hasRenderableOverlayFallback();
    final graphicsReady =
        _sidecarHealthIndicatesGraphicsRuntimeReady(_sidecarHealthSnapshot);
    final driveReady =
        _sidecarHealthIndicatesDriveRuntimeReady(_sidecarHealthSnapshot);
    final fullReady = _sidecarHealthIndicatesFullRuntimeReady(
      _sidecarHealthSnapshot,
    );

    if (graphicsCritical && graphicsReady && hasFallback) {
      return false;
    }
    if (vehicleCritical && driveReady && hasFallback) {
      return false;
    }
    if (fullCritical && !_overlayStaleActive && hasFallback && fullReady) {
      return false;
    }
    if (_sidecarConnected &&
        _shouldHoldRunningPhaseForTransientReconnect &&
        hasFallback &&
        !_overlayStaleActive) {
      if (graphicsCritical || vehicleCritical) {
        return false;
      }
    }
    if (!_sidecarConnected) {
      return true;
    }
    if (_overlayStaleActive) {
      return true;
    }
    if (!hasFallback && (graphicsCritical || vehicleCritical)) {
      return true;
    }
    return fullCritical && !fullReady;
  }

  String _bootstrapModeLabel(String profile) {
    return SidecarService.isC4GraphicsBootstrapProfile(profile)
        ? '그래픽 부트스트랩 모드'
        : 'HUD 부트스트랩 모드';
  }

  void _setNativeCameraAttachReady(bool value) {
    if (_nativeCameraAttachReady == value) {
      return;
    }
    if (mounted) {
      _safeSetState(() {
        _nativeCameraAttachReady = value;
        if (!value) {
          _nativeCameraViewId = null;
          _cameraSourceKey = null;
        }
      });
    } else {
      _nativeCameraAttachReady = value;
      if (!value) {
        _nativeCameraViewId = null;
        _cameraSourceKey = null;
      }
    }
  }

  bool _isSidecarCriticalProcUp(Map<String, String> procs, String name) =>
      (procs[name] ?? '').trim().startsWith('up:');

  bool _hasVehicleRuntimeProcesses(Map<String, String> procs) {
    final hasControlCore = _isSidecarCriticalProcUp(procs, 'selfdrived') &&
        (_isSidecarCriticalProcUp(procs, 'controlsd') ||
            _isSidecarCriticalProcUp(procs, 'plannerd'));
    final hasVisionCore = _isSidecarCriticalProcUp(procs, 'stream_encoderd') &&
        _isSidecarCriticalProcUp(procs, 'modeld') &&
        _isSidecarCriticalProcUp(procs, 'camerad');
    return hasControlCore && hasVisionCore;
  }

  bool _hasDriveRuntimeProcesses(Map<String, String> procs) {
    return _hasVehicleRuntimeProcesses(procs) &&
        _isSidecarCriticalProcUp(procs, 'radard');
  }

  String _selectDriveRuntimeProfile(
    Map<String, String> procs, {
    Map<String, dynamic>? health,
  }) {
    final desiredProfile = _preferredDriveRuntimeProfile(health);
    final runtimeProcessReady = SidecarService.profileRequiresFullRuntime(
      desiredProfile,
    )
        ? _hasDriveRuntimeProcesses(procs)
        : _hasVehicleRuntimeProcesses(procs);
    final runtimeHealthReady = SidecarService.profileRequiresFullRuntime(
      desiredProfile,
    )
        ? _sidecarHealthIndicatesFullRuntimeReady(health)
        : _sidecarHealthIndicatesDriveRuntimeReady(health);
    return (runtimeProcessReady || runtimeHealthReady)
        ? desiredProfile
        : _preferredBootstrapProfile(health);
  }

  Future<Map<String, String>> _loadDriveRuntimeCriticalProcStatus(
    SSHService ssh,
  ) async {
    try {
      final criticalRaw = await _sidecarService.criticalProcStatus(ssh);
      final parsed = _parseStatusPairs(criticalRaw);
      return parsed;
    } catch (_) {
      return const <String, String>{};
    }
  }

  String? _sidecarProfileName(Map<String, dynamic> raw) {
    final profile = raw['profile']?.toString().trim();
    if (profile == null || profile.isEmpty) {
      return null;
    }
    return profile;
  }

  Future<String?> _loadRunningSidecarProfile() async {
    try {
      final profileSnapshot = await _sidecarGetJson('/profile');
      if (!mounted) {
        _sidecarProfileSnapshot = profileSnapshot;
      } else {
        _safeSetState(() => _sidecarProfileSnapshot = profileSnapshot);
      }
      return _sidecarProfileName(profileSnapshot);
    } catch (_) {
      return _sidecarProfileName(_sidecarProfileSnapshot);
    }
  }

  Future<void> _refreshSidecarProcessStatus() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      if (!mounted) {
        _sidecarProcessSnapshot = <String, String>{};
        _sidecarHealthSnapshot = <String, dynamic>{};
        _sidecarProfileSnapshot = <String, dynamic>{};
        _sidecarRepoFlavorHint = SidecarService.repoFlavorUnknown;
        _sidecarVariantHint = SidecarService.defaultVariant;
        return;
      }
      _safeSetState(() {
        _sidecarProcessSnapshot = <String, String>{};
        _sidecarHealthSnapshot = <String, dynamic>{};
        _sidecarProfileSnapshot = <String, dynamic>{};
        _sidecarRepoFlavorHint = SidecarService.repoFlavorUnknown;
        _sidecarVariantHint = SidecarService.defaultVariant;
      });
      return;
    }

    final nextProcess = <String, String>{};
    final nextCritical = <String, String>{};
    var nextHealth = <String, dynamic>{};
    var nextProfile = <String, dynamic>{};
    try {
      final statusRaw = await _sidecarService.status(ssh);
      nextProcess.addAll(_parseStatusPairs(statusRaw));
      try {
        final criticalRaw = await _sidecarService.criticalProcStatus(ssh);
        nextCritical.addAll(_parseStatusPairs(criticalRaw));
      } catch (_) {}
      try {
        nextHealth = await _sidecarGetJson('/health');
      } catch (_) {}
      try {
        final cameraHealth = await _cameraGetJson('/health');
        final relay = cameraHealth['cameraRelay'];
        if (relay is Map) {
          nextHealth['cameraRelay'] = Map<String, dynamic>.from(relay);
        }
      } catch (_) {}
      try {
        final diagHealth = await _diagGetJson('/health');
        final relay = diagHealth['diagRelay'];
        if (relay is Map) {
          nextHealth['diagRelay'] = Map<String, dynamic>.from(relay);
        }
      } catch (_) {}
      try {
        nextProfile = await _sidecarGetJson('/profile');
      } catch (_) {}
    } catch (_) {}

    if (!mounted) {
      _sidecarProcessSnapshot = nextProcess;
      _sidecarHealthSnapshot = nextHealth;
      _sidecarProfileSnapshot = nextProfile;
      return;
    }
    _safeSetState(() {
      _sidecarProcessSnapshot = nextProcess;
      _sidecarHealthSnapshot = nextHealth;
      _sidecarProfileSnapshot = nextProfile;
    });
  }

  void _pushSidecarHistory(String type, String summary) {
    final line = '[${_fmtClock(DateTime.now())}] $type $summary';
    _sidecarHistory.addFirst(line);
    while (_sidecarHistory.length > 20) {
      _sidecarHistory.removeLast();
    }
  }

  bool get _isSidecarBusy =>
      _sidecarPhase == _SidecarPhase.deploying ||
      _sidecarPhase == _SidecarPhase.starting ||
      _sidecarPhase == _SidecarPhase.verifying ||
      _sidecarPhase == _SidecarPhase.stopping;

  bool get _isSidecarHardBusy =>
      _sidecarPhase == _SidecarPhase.deploying ||
      _sidecarPhase == _SidecarPhase.starting ||
      _sidecarPhase == _SidecarPhase.stopping;

  bool get _driveStatusIsError {
    final cameraError = (_cameraError ?? '').trim();
    if (cameraError.isNotEmpty) {
      final lower = cameraError.toLowerCase();
      final retryLike = cameraError.contains('재요청') ||
          cameraError.contains('재동기화') ||
          cameraError.contains('재시도');
      if (!retryLike &&
          !lower.startsWith('socket_failure:') &&
          !cameraError.startsWith('네이티브 뷰어 오류: socket_failure:')) {
        return true;
      }
    }
    return _hudNoticeIsError;
  }

  bool get _driveStatusIsReconnecting {
    if (_shouldSuppressTransientReconnectBanner) {
      return false;
    }
    if (_cameraAttachPendingBeforeFirstFrame &&
        _cameraAttachPhase == _CameraAttachPhase.retrying) {
      return true;
    }
    final cameraError = (_cameraError ?? '').trim();
    if (cameraError.contains('재요청') ||
        cameraError.contains('재동기화') ||
        cameraError.contains('재시도')) {
      return true;
    }
    if (_sidecarPhase == _SidecarPhase.running &&
        _openpilotOverlayMode &&
        !_sidecarConnected) {
      return true;
    }
    return false;
  }

  bool get _shouldSuppressTransientReconnectBanner {
    if (!_openpilotOverlayMode) return false;
    if (_cameraAttachPhase != _CameraAttachPhase.retrying) return false;
    if (_cameraAttachStartedUs <= 0) return false;
    if (_lastCameraFrameId == null && !_hasRenderableOverlayFallback()) {
      return false;
    }
    final elapsedUs = _renderClock.elapsedMicroseconds - _cameraAttachStartedUs;
    return elapsedUs >= 0 && elapsedUs < 2500000;
  }

  bool get _shouldSuppressTransientGraphicsDelayedBanner {
    if (!_openpilotOverlayMode || !_overlayStaleActive) return false;
    if (_overlayStaleStartedUs <= 0) return false;
    if (!_hasRenderableOverlayFallback()) return false;
    if (!_overlayPublicationLooksHealthy(maxAgeUs: 2400000)) return false;
    final elapsedUs = _renderClock.elapsedMicroseconds - _overlayStaleStartedUs;
    return elapsedUs >= 0 && elapsedUs < 2200000;
  }

  bool get _shouldHoldRunningPhaseForTransientReconnect =>
      _openpilotOverlayMode &&
      _sidecarPhase == _SidecarPhase.running &&
      (_lastCameraFrameId != null || _hasRenderableOverlayFallback());

  bool get _driveStatusIsPreparing {
    if (!_hudModeLoaded) return true;
    if (_openpilotOverlayMode && !_sidecarConnected) return true;
    if (_isSidecarHardBusy) return true;
    if (_openpilotOverlayMode &&
        _profileRequiresLiveRuntime(_currentSidecarProfile) &&
        !_nativeCameraAttachReady) {
      return true;
    }
    if (_cameraAttachPendingBeforeFirstFrame &&
        !_shouldUseDegradedOverlayFallbackUi()) {
      return true;
    }
    if (_openpilotOverlayMode &&
        _cameraLoading &&
        _nativeCameraAttachReady &&
        _lastCameraFrameId == null &&
        !_shouldUseDegradedOverlayFallbackUi()) {
      return true;
    }
    return false;
  }

  _DriveBannerState? _currentDriveBannerState() {
    if (_isDeveloperPlaybackRequested) {
      return null;
    }
    if (_sidecarPhase == _SidecarPhase.failed || _driveStatusIsError) {
      final cameraError = (_cameraError ?? '').trim();
      final notice = (_hudNoticeMessage ?? '').trim();
      final detail = cameraError.isNotEmpty
          ? (cameraError.startsWith('네이티브 뷰어 오류:')
              ? '카메라 연결에 문제가 있어 다시 시도하고 있습니다.'
              : cameraError)
          : (notice.isEmpty ? '주행 화면 연결을 복구하는 중입니다.' : notice);
      return _DriveBannerState(
        kind: _DriveBannerKind.error,
        title: '연결 오류',
        detail: detail,
        icon: Icons.error_outline,
        color: const Color(0xCC7A1010),
      );
    }
    if (_driveStatusIsReconnecting) {
      return const _DriveBannerState(
        kind: _DriveBannerKind.reconnecting,
        title: '재연결 중',
        detail: '카메라 또는 그래픽 연결을 다시 시도하고 있습니다.',
        icon: Icons.refresh_rounded,
        color: Color(0xCC6A4312),
      );
    }
    if (_openpilotOverlayMode &&
        _overlayStaleActive &&
        !_shouldSuppressTransientGraphicsDelayedBanner) {
      return const _DriveBannerState(
        kind: _DriveBannerKind.graphicsDelayed,
        title: '그래픽 지연',
        detail: '마지막 정상 그래픽을 유지한 채 갱신을 다시 시도하고 있습니다.',
        icon: Icons.sync_problem_rounded,
        color: Color(0xCC6A4312),
      );
    }
    if (_driveStatusIsPreparing ||
        _isSidecarHardBusy ||
        (_openpilotOverlayMode && !_sidecarConnected)) {
      String detail = '주행 데이터를 준비하는 중입니다.';
      if (!_hudModeLoaded) {
        detail = '주행 화면을 초기화하는 중입니다.';
      } else if (_openpilotOverlayMode && !_sidecarConnected) {
        detail = '주행 데이터를 연결하는 중입니다.';
      } else if (_openpilotOverlayMode &&
          _profileRequiresLiveRuntime(_currentSidecarProfile) &&
          !_nativeCameraAttachReady) {
        detail = '로드카메라와 그래픽을 준비하는 중입니다.';
      } else if ((_cameraAttachPendingBeforeFirstFrame &&
              !_shouldUseDegradedOverlayFallbackUi()) ||
          (_openpilotOverlayMode &&
              _cameraLoading &&
              _nativeCameraAttachReady &&
              _lastCameraFrameId == null &&
              !_shouldUseDegradedOverlayFallbackUi())) {
        detail = '로드카메라 첫 화면을 불러오는 중입니다.';
      } else if (_isSidecarHardBusy &&
          _profileRequiresLiveRuntime(_currentSidecarProfile)) {
        detail = '로드카메라와 그래픽을 준비하는 중입니다.';
      }
      return _DriveBannerState(
        kind: _DriveBannerKind.preparing,
        title: '연결 준비 중',
        detail: detail,
        icon: Icons.hourglass_top_rounded,
        color: const Color(0xCC4A2E12),
      );
    }
    final notice = (_hudNoticeMessage ?? '').trim();
    if (notice.isNotEmpty) {
      return _DriveBannerState(
        kind: _DriveBannerKind.notice,
        title: '알림',
        detail: notice,
        icon: Icons.info_outline_rounded,
        color: const Color(0xCC1E3A2A),
      );
    }
    return null;
  }

  bool get _showSidecarStatusBanner => _currentDriveBannerState() != null;

  String _sidecarStatusTitle() => _currentDriveBannerState()?.title ?? '대기 중';

  String? _sidecarStatusDetailMessage() => _currentDriveBannerState()?.detail;

  IconData _sidecarStatusIcon() =>
      _currentDriveBannerState()?.icon ?? Icons.hourglass_top_rounded;

  Color _sidecarStatusColor() =>
      _currentDriveBannerState()?.color ?? const Color(0xCC1E3A2A);

  bool get _shouldPresentRunningSidecarPhase {
    if (!_openpilotOverlayMode) {
      return false;
    }
    if (_shouldHoldRunningPhaseForTransientReconnect) {
      return true;
    }
    if (_lastCameraFrameId != null) {
      return true;
    }
    if (_hasRenderableOverlayFallback()) {
      return true;
    }
    return _sidecarHealthIndicatesGraphicsRuntimeReady(_sidecarHealthSnapshot);
  }

  void _setOperationalSidecarPhase({
    String? runningMessage,
    String? waitingMessage,
    String? idleMessage,
    bool preferRunning = false,
    bool clearHardBusy = false,
  }) {
    final canOverrideHardBusy = clearHardBusy &&
        (_sidecarPhase == _SidecarPhase.starting ||
            _sidecarPhase == _SidecarPhase.deploying);
    if ((!canOverrideHardBusy && _isSidecarHardBusy) ||
        _sidecarPhase == _SidecarPhase.failed) {
      return;
    }
    if (!_openpilotOverlayMode) {
      _setSidecarPhase(_SidecarPhase.idle, message: idleMessage);
      return;
    }
    final shouldRun = preferRunning || _shouldPresentRunningSidecarPhase;
    if (shouldRun) {
      _setSidecarPhase(_SidecarPhase.running, message: runningMessage);
      return;
    }
    final shouldVerify = _sidecarConnected ||
        _nativeCameraAttachReady ||
        _cameraAttachPendingBeforeFirstFrame ||
        _cameraLoading ||
        _profileRequiresLiveRuntime(_currentSidecarProfile);
    if (shouldVerify) {
      _setSidecarPhase(
        _SidecarPhase.verifying,
        message: waitingMessage ?? runningMessage,
      );
      return;
    }
    _setSidecarPhase(_SidecarPhase.idle, message: idleMessage);
  }

  void _setHardSidecarPhase(
    _SidecarPhase phase, {
    String? message,
  }) {
    assert(
      phase == _SidecarPhase.idle ||
          phase == _SidecarPhase.deploying ||
          phase == _SidecarPhase.starting ||
          phase == _SidecarPhase.stopping ||
          phase == _SidecarPhase.failed,
      'hard sidecar phase must be idle/deploying/starting/stopping/failed',
    );
    _setSidecarPhase(phase, message: message);
  }

  void _setSidecarPhase(
    _SidecarPhase phase, {
    String? message,
  }) {
    final busy = phase == _SidecarPhase.deploying ||
        phase == _SidecarPhase.starting ||
        phase == _SidecarPhase.verifying ||
        phase == _SidecarPhase.stopping;
    if (_isDisposing) {
      _sidecarPhase = phase;
      _sidecarPhaseMessage = message;
      _sidecarTransitioning = busy;
      return;
    }
    final oldPhase = _sidecarPhase;
    final oldMessage = _sidecarPhaseMessage;
    final suppressNoisyRunningTransition =
        oldPhase == _SidecarPhase.running &&
            phase == _SidecarPhase.running &&
            _isNoisySteadyRunningPhaseMessage(oldMessage) &&
            _isNoisySteadyRunningPhaseMessage(message);
    if ((_sidecarPhase != phase || _sidecarPhaseMessage != message) &&
        !suppressNoisyRunningTransition) {
      _appendDriveDiagEvent(
        'sidecar_phase',
        <String, dynamic>{
          'phase': phase.name,
          'message': message,
          'busy': busy,
        },
      );
    }
    if (mounted) {
      _safeSetState(() {
        _sidecarPhase = phase;
        _sidecarPhaseMessage = message;
        _sidecarTransitioning = busy;
        if (busy) {
          _cameraError = null;
        }
      });
    } else {
      _sidecarPhase = phase;
      _sidecarPhaseMessage = message;
      _sidecarTransitioning = busy;
      if (busy) {
        _cameraError = null;
      }
    }
  }

  bool _isNoisySteadyRunningPhaseMessage(String? message) {
    final text = (message ?? '').trim();
    if (text.isEmpty) return false;
    return text == '사이드카 연결이 복구되었습니다.' ||
        text == '카메라 스트림 연결이 확인되었습니다.';
  }

  Future<void> _waitForSidecarReady({
    required String profile,
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 300),
    Duration healthTimeout = const Duration(seconds: 2),
    Duration wsTimeout = const Duration(seconds: 2),
    bool allowEarlyCameraAttach = false,
  }) async {
    final requiresLiveRuntime = _profileRequiresLiveRuntime(profile);
    final expectedProfile = profile.trim().toLowerCase();
    final expectedCameraService = _liveCameraName == 'wideRoad'
        ? 'wideRoadCameraState'
        : 'roadCameraState';
    var cameraAttachPrimed = false;

    void primeCameraAttach(String reason) {
      if (!allowEarlyCameraAttach || !requiresLiveRuntime) {
        return;
      }
      if (cameraAttachPrimed || _nativeCameraAttachReady) {
        return;
      }
      cameraAttachPrimed = true;
      _setNativeCameraAttachReady(true);
      _startCameraErrorGrace(reason: reason);
      if (!_cameraSuspendedByLifecycle) {
        unawaited(_loadCameraSource(force: true));
      }
    }

    bool serviceFresh(Map<String, dynamic> health, String name) {
      final raw = health['serviceHealth'];
      if (raw is! Map) {
        return false;
      }
      final service = raw[name];
      if (service is Map<String, dynamic>) {
        return service['isFresh'] == true;
      }
      if (service is Map) {
        return service['isFresh'] == true;
      }
      return false;
    }

    bool freshnessReady(Map<String, dynamic> health) {
      final raw = health['serviceHealth'];
      if (raw is! Map || raw.isEmpty) {
        return true;
      }
      final reportedProfile =
          (health['profile'] ?? profile).toString().trim().toLowerCase();
      final graphicsReady = health['graphicsReady'] == true ||
          (serviceFresh(health, 'selfdriveState') &&
              serviceFresh(health, 'liveCalibration') &&
              serviceFresh(health, 'modelV2') &&
              serviceFresh(health, expectedCameraService));
      final vehicleReady = health['vehicleReady'] == true ||
          (serviceFresh(health, 'selfdriveState') &&
              (SidecarService.profileOmitsCarState(reportedProfile) ||
                  serviceFresh(health, 'carState')));
      final controlsReady = health['controlsReady'] == true ||
          serviceFresh(health, 'controlsState');
      final driveReady = health['driveReady'] == true ||
          (graphicsReady && vehicleReady && controlsReady);
      final fullReady = health['fullReady'] == true ||
          (driveReady && serviceFresh(health, 'radarState'));
      final hudCoreFresh = serviceFresh(health, 'selfdriveState') &&
          (SidecarService.profileOmitsCarState(reportedProfile) ||
              serviceFresh(health, 'carState'));
      if (!hudCoreFresh) {
        return false;
      }
      if (SidecarService.profileRequiresFullRuntime(reportedProfile)) {
        return fullReady;
      }
      if (SidecarService.profileProvidesVehicleRuntime(reportedProfile)) {
        return driveReady;
      }
      if (!SidecarService.profileProvidesGraphicsRuntime(reportedProfile)) {
        return vehicleReady || hudCoreFresh;
      }
      return graphicsReady;
    }

    Future<Map<String, dynamic>> probeHealth() async {
      final client = HttpClient()..connectionTimeout = healthTimeout;
      try {
        final request = await client.getUrl(_sidecarHttpUri('/health')).timeout(
              healthTimeout,
            );
        final response = await request.close().timeout(healthTimeout);
        final body = await utf8.decodeStream(response).timeout(healthTimeout);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('health http ${response.statusCode}');
        }
        final decoded =
            body.trim().isEmpty ? <String, dynamic>{} : jsonDecode(body);
        if (decoded is! Map) {
          throw Exception('health invalid');
        }
        final health = Map<String, dynamic>.from(decoded);
        _applyResolvedSidecarFlavorHints(
          repoFlavor: health['repoFlavor']?.toString(),
          variant: health['variant']?.toString(),
        );
        if (health['ok'] != true) {
          throw Exception('health not ok');
        }
        final reportedProfile =
            (health['profile'] ?? '').toString().trim().toLowerCase();
        if (reportedProfile.isNotEmpty && reportedProfile != expectedProfile) {
          throw Exception('health profile mismatch: $reportedProfile');
        }
        final effectiveProfile =
            reportedProfile.isEmpty ? expectedProfile : reportedProfile;
        final driveReady = health['driveReady'] == true ||
            ((health['graphicsReady'] == true) &&
                (health['vehicleReady'] == true) &&
                (health['controlsReady'] == true ||
                    serviceFresh(health, 'controlsState')));
        final ready = health['ready'] == true ||
            (SidecarService.profileRequiresFullRuntime(effectiveProfile)
                ? health['fullReady'] == true
                : SidecarService.profileProvidesVehicleRuntime(effectiveProfile)
                    ? driveReady
                    : SidecarService.profileProvidesGraphicsRuntime(
                            effectiveProfile)
                        ? health['graphicsReady'] == true
                        : (health['vehicleReady'] == true ||
                            health['hudReady'] == true));
        if (!ready) {
          throw Exception('health not ready');
        }
        if (!freshnessReady(health)) {
          throw Exception('health stale');
        }
        return health;
      } finally {
        client.close(force: true);
      }
    }

    Map<String, dynamic>? decodeWsPayload(dynamic event) {
      try {
        if (event is String) {
          final decoded = jsonDecode(event);
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
          if (decoded is Map) {
            return Map<String, dynamic>.from(decoded);
          }
        } else if (event is List<int>) {
          var bytes = event;
          try {
            bytes = zlib.decode(bytes);
          } catch (_) {
            // Sidecar may send plain UTF-8 JSON frames during fallback paths.
          }
          try {
            final decoded =
                jsonDecode(utf8.decode(bytes, allowMalformed: true));
            if (decoded is Map<String, dynamic>) {
              return decoded;
            }
            if (decoded is Map) {
              return Map<String, dynamic>.from(decoded);
            }
          } catch (_) {
            final decoded = deserialize(Uint8List.fromList(bytes));
            if (decoded is Map<String, dynamic>) {
              return decoded;
            }
            if (decoded is Map) {
              return Map<String, dynamic>.from(decoded);
            }
          }
        }
      } catch (_) {}
      return null;
    }

    Future<void> probeLiveWs() async {
      WebSocket? ws;
      StreamSubscription<dynamic>? wsSub;
      try {
        final firstLiveFrame = Completer<void>();
        final sessionId = DateTime.now().microsecondsSinceEpoch;
        final liveWsUrl =
            'ws://$_hostIp:7766/ws/live?encoding=msgpack&camera=$_liveCameraName'
            '&role=drive_ready_probe&session=ready_$sessionId';
        ws = await WebSocket.connect(liveWsUrl).timeout(wsTimeout);
        wsSub = ws.listen(
          (event) {
            if (firstLiveFrame.isCompleted) return;
            final payload = decodeWsPayload(event);
            if (payload == null || payload['type'] == 'hello') {
              return;
            }
            final frame = OverlayStreamFrame.fromPayload(
              host: _hostIp,
              payload: payload,
              sequence: 0,
            );
            final hasFrameIds =
                frame.modelFrameId != null || frame.roadFrameId != null;
            if (hasFrameIds) {
              firstLiveFrame.complete();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!firstLiveFrame.isCompleted) {
              firstLiveFrame.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (!firstLiveFrame.isCompleted) {
              firstLiveFrame.completeError(Exception('live ws closed'));
            }
          },
          cancelOnError: true,
        );
        await firstLiveFrame.future.timeout(wsTimeout);
      } finally {
        await wsSub?.cancel();
        await ws?.close();
      }
    }

    Future<void> probeCameraWs() async {
      WebSocket? ws;
      StreamSubscription<dynamic>? wsSub;
      try {
        final firstPacket = Completer<void>();
        ws = await WebSocket.connect(_liveCameraWsUrl).timeout(wsTimeout);
        wsSub = ws.listen(
          (event) {
            if (firstPacket.isCompleted) return;
            if (event is List<int> && event.isNotEmpty) {
              primeCameraAttach('camera_probe_ready');
              firstPacket.complete();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!firstPacket.isCompleted) {
              firstPacket.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (!firstPacket.isCompleted) {
              firstPacket.completeError(Exception('camera ws closed'));
            }
          },
          cancelOnError: true,
        );
        await firstPacket.future.timeout(wsTimeout);
      } finally {
        await wsSub?.cancel();
        await ws?.close();
      }
    }

    final deadline = DateTime.now().add(timeout);
    var healthReady = false;
    var liveWsReady = false;
    var cameraWsReady = false;
    Object? lastError;
    Object? lastCameraProbeError;
    while (DateTime.now().isBefore(deadline)) {
      if (!healthReady) {
        try {
          await probeHealth();
          healthReady = true;
          if (requiresLiveRuntime) {
            primeCameraAttach('health_ready');
          }
        } catch (e) {
          lastError = e;
          await Future<void>.delayed(pollInterval);
          continue;
        }
      }

      if (requiresLiveRuntime && !liveWsReady) {
        try {
          await probeLiveWs();
          liveWsReady = true;
          primeCameraAttach('live_probe_ready');
          final runtime = _sharedRuntimeManager;
          if (runtime != null && !runtime.overlayConnected) {
            unawaited(
              runtime.ensureOverlayStream(
                forceRestart: true,
                camera: _liveCameraName,
              ),
            );
          }
        } catch (e) {
          lastError = e;
          await Future<void>.delayed(pollInterval);
          continue;
        }
      }

      if (requiresLiveRuntime && !cameraWsReady) {
        try {
          await probeCameraWs();
          cameraWsReady = true;
        } catch (e) {
          lastCameraProbeError = e;
        }
      }

      if (!requiresLiveRuntime || liveWsReady) {
        return;
      }

      lastError = lastCameraProbeError ?? lastError;
      await Future<void>.delayed(pollInterval);
    }
    throw Exception('ready timeout: ${lastError ?? lastCameraProbeError}');
  }

  Future<void> _ensureSidecarRuntime({String reason = 'auto'}) async {
    if (!_openpilotOverlayMode || _cameraSuspendedByLifecycle) return;
    if (_sidecarAutoManaging) return;
    final preserveVisibleNativeCamera = _useNativeLiveCamera &&
        _nativeCameraViewId != null &&
        _cameraError == null &&
        !_cameraSuspendedByLifecycle;
    _cancelDelayedSidecarStop();
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) return;
    _sidecarAutoManaging = true;
    _suppressCameraErrors = true;
    if (!preserveVisibleNativeCamera) {
      _setNativeCameraAttachReady(false);
    }
    _startCameraErrorGrace(
      reason: 'sidecar_runtime_start',
      windowUs: 6000000,
    );
    _beginStartupProvisionalSync(reason: 'sidecar_runtime_start');
    _pushSidecarHistory('AUTO_RUNTIME', 'start reason=$reason');
    _setOperationalSidecarPhase(
      waitingMessage: '사이드카 런타임 상태를 확인하는 중입니다.',
    );
    if (mounted) {
      _safeSetState(() => _cameraLoading = !preserveVisibleNativeCamera);
    } else {
      _cameraLoading = !preserveVisibleNativeCamera;
    }
    try {
      await _ensureSidecarRevisionUpToDate(ssh);
      final resolvedVariant = await _sidecarService.resolveRemoteVariant(ssh);
      final resolvedRepoFlavor =
          await _sidecarService.resolveRemoteRepoFlavor(ssh);
      _applyResolvedSidecarFlavorHints(
        repoFlavor: resolvedRepoFlavor,
        variant: resolvedVariant,
      );
      final statusRaw = await _sidecarService.status(ssh);
      final status = _parseStatusPairs(statusRaw);
      final running = status['running'] == '1';
      final listening = status['listening'] == '1';
      final criticalProcs = await _loadDriveRuntimeCriticalProcStatus(ssh);
      final desiredProfile = _selectDriveRuntimeProfile(
        criticalProcs,
        health: _sidecarHealthSnapshot,
      );
      final requiresLiveRuntime = _profileRequiresLiveRuntime(desiredProfile);
      final runningProfile =
          running && listening ? await _loadRunningSidecarProfile() : null;
      final reuseExistingRuntime = running &&
          listening &&
          (runningProfile == desiredProfile ||
              (runningProfile == null &&
                  SidecarService.isBootstrapProfile(desiredProfile)));
      if (reuseExistingRuntime) {
        // Reuse the live runtime when possible, but still verify readiness
        // briefly so the first Stock attach does not race camera/live startup.
        _pushSidecarHistory(
          'AUTO_RUNTIME',
          'reuse running/listening runtime profile=${runningProfile ?? desiredProfile}',
        );
        if (requiresLiveRuntime) {
          _startSidecarLoop();
        } else {
          _stopSidecarLoop(resetSession: true);
        }
        _setOperationalSidecarPhase(
          runningMessage: SidecarService.isBootstrapProfile(desiredProfile)
              ? '주행 대기 중: ${_bootstrapModeLabel(desiredProfile)} 유지 중'
              : '사이드카 실행 중',
          waitingMessage: SidecarService.isBootstrapProfile(desiredProfile)
              ? '${_bootstrapModeLabel(desiredProfile)} 연결 확인 중...'
              : '카메라 스트림 연결 확인 중...',
          preferRunning: true,
        );
        try {
          await _waitForSidecarReady(
            profile: desiredProfile,
            timeout: requiresLiveRuntime
                ? const Duration(milliseconds: 2200)
                : const Duration(milliseconds: 1200),
            pollInterval: const Duration(milliseconds: 150),
            healthTimeout: const Duration(milliseconds: 700),
            wsTimeout: const Duration(milliseconds: 1000),
            allowEarlyCameraAttach: requiresLiveRuntime,
          );
          if (requiresLiveRuntime) {
            _setNativeCameraAttachReady(true);
            _startCameraErrorGrace(reason: 'runtime_reuse_ready');
            if (!_cameraSuspendedByLifecycle) {
              unawaited(_loadCameraSource(force: true));
            }
          }
        } catch (e) {
          _pushSidecarHistory('READY_DEFER', '$e');
          if (requiresLiveRuntime) {
            _setOperationalSidecarPhase(
              runningMessage: SidecarService.isBootstrapProfile(desiredProfile)
                  ? '${_bootstrapModeLabel(desiredProfile)} 연결 대기 중...'
                  : '카메라/그래픽 연결 대기 중...',
              waitingMessage:
                  SidecarService.isBootstrapProfile(desiredProfile)
                      ? '${_bootstrapModeLabel(desiredProfile)} 연결 확인 중...'
                      : '카메라 스트림 연결 확인 중...',
              preferRunning: true,
            );
            if (_shouldEscalateToSidecarRecovery(graphicsCritical: true)) {
              _scheduleSidecarRuntimeRecovery(reason: 'ready_deferred_reuse');
            }
          }
        }
      } else {
        _setHardSidecarPhase(
          _SidecarPhase.starting,
          message: SidecarService.isBootstrapProfile(desiredProfile)
              ? '주행 대기 중: ${_bootstrapModeLabel(desiredProfile)} 유지 중...'
              : (running || listening ? '사이드카 런타임 복구 중...' : '사이드카 시작 중...'),
        );
        try {
          _startCameraErrorGrace(
            reason: 'sidecar_start',
            windowUs: 7000000,
          );
          await _sidecarService.start(
            ssh,
            profile: desiredProfile,
            variant: resolvedVariant,
            repoFlavor: resolvedRepoFlavor,
          );
          _sidecarLastStartAt = DateTime.now();
          _pushSidecarHistory('AUTO_START', 'start ok profile=$desiredProfile');
        } catch (startError) {
          _pushSidecarHistory('AUTO_START_FAIL', '$startError');
          var recoveredByBootstrap = false;
          if (!_LiveDriveCanvasScreenState._autoDeployDuringHudRuntime) {
            recoveredByBootstrap = await _tryAutoBootstrapSidecar(
              ssh,
              startError: startError,
            );
            if (recoveredByBootstrap) {
              _setHardSidecarPhase(
                _SidecarPhase.starting,
                message: SidecarService.isBootstrapProfile(desiredProfile)
                    ? '주행 대기 중: ${_bootstrapModeLabel(desiredProfile)} 유지 중...'
                    : '사이드카 시작 중...',
              );
              await _sidecarService.start(
                ssh,
                profile: desiredProfile,
                variant: resolvedVariant,
                repoFlavor: resolvedRepoFlavor,
              );
              _sidecarLastStartAt = DateTime.now();
              _pushSidecarHistory(
                'AUTO_START',
                'start ok (after bootstrap) profile=$desiredProfile',
              );
            }
          }
          if (recoveredByBootstrap) {
            // no-op; startup recovered
          } else if (_LiveDriveCanvasScreenState._autoDeployDuringHudRuntime) {
            _setHardSidecarPhase(
              _SidecarPhase.deploying,
              message: '사이드카 배포/복구 중...',
            );
            await _sidecarService.deploy(ssh);
            _pushSidecarHistory('AUTO_DEPLOY', 'ok');
            _setHardSidecarPhase(
              _SidecarPhase.starting,
              message: SidecarService.isBootstrapProfile(desiredProfile)
                  ? '주행 대기 중: ${_bootstrapModeLabel(desiredProfile)} 유지 중...'
                  : '사이드카 시작 중...',
            );
            await _sidecarService.start(
              ssh,
              profile: desiredProfile,
              variant: resolvedVariant,
              repoFlavor: resolvedRepoFlavor,
            );
            _sidecarLastStartAt = DateTime.now();
            _pushSidecarHistory(
              'AUTO_RESTART',
              'start ok (after deploy) profile=$desiredProfile',
            );
          } else {
            rethrow;
          }
        }

        if (requiresLiveRuntime) {
          _startSidecarLoop();
        } else {
          _stopSidecarLoop(resetSession: true);
        }
        _setOperationalSidecarPhase(
          runningMessage: SidecarService.isBootstrapProfile(desiredProfile)
              ? '주행 대기 중: ${_bootstrapModeLabel(desiredProfile)} 유지 중'
              : '사이드카 실행 중',
          waitingMessage: SidecarService.isBootstrapProfile(desiredProfile)
              ? '${_bootstrapModeLabel(desiredProfile)} 연결 확인 중...'
              : '카메라 스트림 연결 확인 중...',
          clearHardBusy: true,
        );
        try {
          await _waitForSidecarReady(
            profile: desiredProfile,
            timeout: const Duration(milliseconds: 3000),
            pollInterval: const Duration(milliseconds: 150),
            healthTimeout: const Duration(milliseconds: 700),
            wsTimeout: const Duration(milliseconds: 1200),
            allowEarlyCameraAttach: requiresLiveRuntime,
          );
          if (requiresLiveRuntime) {
            _setNativeCameraAttachReady(true);
            _startCameraErrorGrace(reason: 'runtime_ready');
            if (!_cameraSuspendedByLifecycle) {
              unawaited(_loadCameraSource(force: true));
            }
          }
          _setOperationalSidecarPhase(
            runningMessage: SidecarService.isBootstrapProfile(desiredProfile)
                ? '주행 대기 중: ${_bootstrapModeLabel(desiredProfile)} 유지 중'
                : '사이드카 실행 중',
            waitingMessage: SidecarService.isBootstrapProfile(desiredProfile)
                ? '${_bootstrapModeLabel(desiredProfile)} 연결 확인 중...'
                : '카메라 스트림 연결 확인 중...',
            preferRunning: true,
            clearHardBusy: true,
          );
        } catch (e) {
          _pushSidecarHistory('READY_DEFER', '$e');
          _setOperationalSidecarPhase(
            runningMessage: SidecarService.isBootstrapProfile(desiredProfile)
                ? '${_bootstrapModeLabel(desiredProfile)} 연결 대기 중...'
                : '사이드카 연결 대기 중...',
            waitingMessage: SidecarService.isBootstrapProfile(desiredProfile)
                ? '${_bootstrapModeLabel(desiredProfile)} 연결 확인 중...'
                : '카메라 스트림 연결 확인 중...',
            preferRunning: true,
            clearHardBusy: true,
          );
          if (requiresLiveRuntime &&
              _shouldEscalateToSidecarRecovery(graphicsCritical: true)) {
            _scheduleSidecarRuntimeRecovery(reason: 'ready_deferred');
          }
        }
      }
      await _refreshSidecarProcessStatus();
      final activeProfile = _currentSidecarProfile;
      final waitingForGraphics = _profileRequiresLiveRuntime(activeProfile) &&
          !_sidecarHealthIndicatesGraphicsRuntimeReady(_sidecarHealthSnapshot);
      final waitingForDriveRuntime =
          SidecarService.profileProvidesVehicleRuntime(activeProfile) &&
              !SidecarService.profileRequiresFullRuntime(activeProfile) &&
              !_sidecarHealthIndicatesDriveRuntimeReady(_sidecarHealthSnapshot);
      final waitingForFullRuntime =
          SidecarService.profileRequiresFullRuntime(activeProfile) &&
              !_sidecarHealthIndicatesFullRuntimeReady(_sidecarHealthSnapshot);
      if (waitingForGraphics) {
        _pushSidecarHistory(
          'GRAPHICS_BOOTSTRAP_WAIT',
          'profile=$activeProfile graphicsReady='
              '${_sidecarHealthIndicatesGraphicsRuntimeReady(_sidecarHealthSnapshot)}',
        );
        _setOperationalSidecarPhase(
          runningMessage: SidecarService.isBootstrapProfile(activeProfile)
              ? '${_bootstrapModeLabel(activeProfile)} 연결 대기 중...'
              : '카메라/그래픽 연결 대기 중...',
          waitingMessage: SidecarService.isBootstrapProfile(activeProfile)
              ? '${_bootstrapModeLabel(activeProfile)} 연결 확인 중...'
              : '카메라 스트림 연결 확인 중...',
          preferRunning: true,
        );
        if (_shouldEscalateToSidecarRecovery(graphicsCritical: true)) {
          _scheduleSidecarRuntimeRecovery(
            reason: 'graphics_bootstrap_wait',
            minDelay: const Duration(milliseconds: 1200),
            preferSooner: true,
          );
        }
      } else if (waitingForDriveRuntime) {
        _pushSidecarHistory(
          'DRIVE_RUNTIME_WAIT',
          'profile=$activeProfile carStateFresh='
              '${_sidecarHealthServiceFresh(_sidecarHealthSnapshot, 'carState')} '
              'controlsFresh=${_sidecarHealthServiceFresh(_sidecarHealthSnapshot, 'controlsState')}',
        );
        _setOperationalSidecarPhase(
          runningMessage: '차량 상태 연결을 다시 맞추는 중입니다.',
          waitingMessage: '주행 데이터를 연결하는 중입니다.',
          preferRunning: true,
        );
        if (_shouldEscalateToSidecarRecovery(vehicleCritical: true)) {
          _scheduleSidecarRuntimeRecovery(
            reason: 'drive_runtime_unstable',
            minDelay: const Duration(milliseconds: 900),
            preferSooner: true,
          );
        }
      } else if (waitingForFullRuntime) {
        _pushSidecarHistory(
          'FULL_RUNTIME_WAIT',
          'profile=$activeProfile carStateFresh='
              '${_sidecarHealthServiceFresh(_sidecarHealthSnapshot, 'carState')} '
              'controlsFresh=${_sidecarHealthServiceFresh(_sidecarHealthSnapshot, 'controlsState')} '
              'radarFresh=${_sidecarHealthServiceFresh(_sidecarHealthSnapshot, 'radarState')}',
        );
        _setOperationalSidecarPhase(
          runningMessage: '고급 주행 상태를 다시 확인하는 중입니다.',
          waitingMessage: '주행 데이터를 연결하는 중입니다.',
          preferRunning: true,
        );
        if (_shouldEscalateToSidecarRecovery(fullCritical: true)) {
          _scheduleSidecarRuntimeRecovery(
            reason: 'full_runtime_unstable',
            minDelay: const Duration(milliseconds: 900),
            preferSooner: true,
          );
        }
      } else {
        _clearSidecarRecoverySchedule();
      }
      _suppressCameraErrors = false;
    } catch (e) {
      _pushSidecarHistory('FAIL', 'auto runtime: $e');
      _setHardSidecarPhase(
        _SidecarPhase.failed,
        message: '사이드카 준비가 지연되어 자동 복구를 재시도하는 중입니다.',
      );
      _scheduleSidecarRuntimeRecovery(reason: 'runtime_failed');
    } finally {
      _sidecarAutoManaging = false;
    }
  }

  Future<void> _stopSidecarProcessIfNeeded({bool force = false}) async {
    if (_sidecarAutoManaging) return;
    if (_LiveDriveCanvasScreenState._residentSidecarManaged && !force) {
      _pushSidecarHistory('AUTO_STOP_SKIP', 'resident sidecar mode');
      _setHardSidecarPhase(_SidecarPhase.idle);
      return;
    }
    _cancelDelayedSidecarStop();
    _clearSidecarRecoverySchedule();
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _setHardSidecarPhase(_SidecarPhase.idle);
      return;
    }
    _sidecarAutoManaging = true;
    _pushSidecarHistory('AUTO_STOP', 'start');
    _setHardSidecarPhase(
      _SidecarPhase.stopping,
      message: '사이드카 프로세스를 중지하는 중입니다.',
    );
    try {
      await _sidecarService.stop(ssh);
      _pushSidecarHistory('AUTO_STOP', 'ok');
      unawaited(_refreshSidecarProcessStatus());
    } catch (_) {
      // Ignore stop errors during lifecycle transitions.
    } finally {
      _sidecarAutoManaging = false;
      _setHardSidecarPhase(_SidecarPhase.idle);
    }
  }
}
