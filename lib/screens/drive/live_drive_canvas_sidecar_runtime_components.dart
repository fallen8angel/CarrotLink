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
    switch ((profile ?? '').trim().toLowerCase()) {
      case 'p2':
      case 'p3':
      case 'p4':
        return true;
      default:
        return false;
    }
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

  String _sidecarVariantOf([Map<String, dynamic>? snapshot]) {
    final candidates = <dynamic>[
      snapshot?['variant'],
      _sidecarHealthSnapshot['variant'],
      _sidecarProfileSnapshot['variant'],
      _sidecarVariantHint,
    ];
    for (final raw in candidates) {
      final text = raw?.toString().trim();
      if (text == null || text.isEmpty) {
        continue;
      }
      final normalized = _normalizeSidecarVariant(text);
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return SidecarService.defaultVariant;
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

  bool _healthUsesC4SafeBootstrap([Map<String, dynamic>? health]) {
    final snapshot = health ?? _sidecarHealthSnapshot;
    if (_sidecarVariantOf(snapshot) != SidecarService.c4SafeVariant ||
        _sidecarRepoFlavorOf(snapshot) != SidecarService.repoFlavorC4) {
      return false;
    }
    if (snapshot.isEmpty) {
      return true;
    }
    if (snapshot['startupProtectionActive'] == true) {
      return true;
    }
    return snapshot['radarFreshStable'] != true ||
        snapshot['radarReady'] != true;
  }

  bool _healthRequiresC4SafeLiveStability([Map<String, dynamic>? health]) =>
      _sidecarVariantOf(health) == SidecarService.c4SafeVariant &&
      _sidecarRepoFlavorOf(health) == SidecarService.repoFlavorC4;

  bool _shouldDowngradeLiveRuntimeForC4Safe([Map<String, dynamic>? health]) {
    final snapshot = health ?? _sidecarHealthSnapshot;
    if (!_healthRequiresC4SafeLiveStability(snapshot)) {
      return false;
    }
    final profile =
        (snapshot['profile'] ?? _currentSidecarProfile).toString().trim();
    if (!_profileRequiresLiveRuntime(profile)) {
      return false;
    }
    if (snapshot.isEmpty) {
      return false;
    }
    return snapshot['startupProtectionActive'] == true ||
        snapshot['radarFreshStable'] != true ||
        snapshot['radarReady'] != true ||
        snapshot['liveReady'] != true;
  }

  String get _currentSidecarProfile =>
      _sidecarProfileName(_sidecarProfileSnapshot) ??
      SidecarService.hudBootstrapProfile;

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

  bool _sidecarHealthIndicatesLiveRuntimeReady([Map<String, dynamic>? health]) {
    final snapshot = health ?? _sidecarHealthSnapshot;
    if (snapshot.isEmpty) {
      return false;
    }
    final expectedCameraService = _liveCameraName == 'wideRoad'
        ? 'wideRoadCameraState'
        : 'roadCameraState';
    final hudReady = snapshot['hudReady'] == true;
    final liveReady = snapshot['liveReady'] == true;
    final modelFresh = _sidecarHealthServiceFresh(snapshot, 'modelV2');
    final cameraFresh =
        _sidecarHealthServiceFresh(snapshot, expectedCameraService);
    if (_healthRequiresC4SafeLiveStability(snapshot) &&
        (snapshot['startupProtectionActive'] == true ||
            snapshot['radarReady'] != true ||
            snapshot['radarFreshStable'] != true)) {
      return false;
    }
    return hudReady && liveReady && modelFresh && cameraFresh;
  }

  bool _shouldRecoverSidecarForOverlayStall() {
    if (!_openpilotOverlayMode ||
        !_sidecarConnected ||
        _cameraSuspendedByLifecycle ||
        _startupProvisionalSyncActive) {
      return false;
    }
    return !_sidecarHealthIndicatesLiveRuntimeReady();
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

  bool _hasDriveRuntimeProcesses(Map<String, String> procs) {
    final hasControlCore = _isSidecarCriticalProcUp(procs, 'selfdrived') &&
        (_isSidecarCriticalProcUp(procs, 'controlsd') ||
            _isSidecarCriticalProcUp(procs, 'plannerd'));
    final hasVisionCore = _isSidecarCriticalProcUp(procs, 'stream_encoderd') &&
        _isSidecarCriticalProcUp(procs, 'modeld') &&
        _isSidecarCriticalProcUp(procs, 'camerad');
    final hasRadarCore = _isSidecarCriticalProcUp(procs, 'radard');
    return hasControlCore && hasVisionCore && hasRadarCore;
  }

  String _selectDriveRuntimeProfile(
    Map<String, String> procs, {
    Map<String, dynamic>? health,
  }) {
    if (_healthUsesC4SafeBootstrap(health)) {
      return SidecarService.hudBootstrapProfile;
    }
    return (_hasDriveRuntimeProcesses(procs) ||
            _sidecarHealthIndicatesLiveRuntimeReady(health))
        ? SidecarService.driveRuntimeProfile
        : SidecarService.hudBootstrapProfile;
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

  bool get _showSidecarStatusBanner =>
      (!_isDeveloperPlaybackRequested &&
          (_isSidecarBusy ||
              _sidecarPhase == _SidecarPhase.failed ||
              (_openpilotOverlayMode && !_sidecarConnected) ||
              (_openpilotOverlayMode && _overlayStaleActive)));

  String _sidecarStatusTitle() {
    if (_sidecarPhase == _SidecarPhase.failed) return '사이드카 준비 실패';
    if (_isSidecarBusy) return '사이드카 준비 중...';
    if (_openpilotOverlayMode && !_sidecarConnected) {
      return '사이드카 연결 대기 중...';
    }
    if (_openpilotOverlayMode && _overlayStaleActive) {
      return '오버레이 업데이트 지연';
    }
    if (_sidecarPhase == _SidecarPhase.running) return '사이드카 실행 중';
    return '사이드카 비활성';
  }

  String? _sidecarStatusDetailMessage() {
    if (_openpilotOverlayMode && _overlayStaleActive) {
      final reason = _overlayStaleReason.trim();
      if (reason.isEmpty) {
        return '마지막 정상 스냅샷을 잠시 유지합니다.';
      }
      return '마지막 정상 스냅샷 유지 중 · $reason';
    }
    final message = (_sidecarPhaseMessage ?? '').trim();
    if (message.isEmpty) {
      return null;
    }
    return message;
  }

  IconData _sidecarStatusIcon() {
    if (_sidecarPhase == _SidecarPhase.failed) {
      return Icons.error_outline;
    }
    if (_openpilotOverlayMode && _overlayStaleActive) {
      return Icons.sync_problem_rounded;
    }
    if (_sidecarPhase == _SidecarPhase.stopping) {
      return Icons.stop_circle_outlined;
    }
    if (_sidecarPhase == _SidecarPhase.running) {
      return Icons.check_circle_outline;
    }
    return Icons.hourglass_top_rounded;
  }

  Color _sidecarStatusColor() {
    if (_sidecarPhase == _SidecarPhase.failed) return const Color(0xCC7A1010);
    if (_isSidecarBusy) return const Color(0xCC4A2E12);
    if (_openpilotOverlayMode && _overlayStaleActive) {
      return const Color(0xCC6A4312);
    }
    return const Color(0xCC1E3A2A);
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
    if (_sidecarPhase != phase || _sidecarPhaseMessage != message) {
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
      final hudCoreFresh = serviceFresh(health, 'carState') &&
          serviceFresh(health, 'selfdriveState');
      if (!hudCoreFresh) {
        return false;
      }
      if (!requiresLiveRuntime) {
        return true;
      }
      if (_healthRequiresC4SafeLiveStability(health) &&
          (health['startupProtectionActive'] == true ||
              health['radarReady'] != true ||
              health['radarFreshStable'] != true)) {
        return false;
      }
      return serviceFresh(health, 'modelV2') &&
          serviceFresh(health, expectedCameraService);
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
        final ready = requiresLiveRuntime
            ? (health['ready'] == true ||
                (health['hudReady'] == true && health['liveReady'] == true))
            : (health['ready'] == true || health['hudReady'] == true);
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
    _setSidecarPhase(
      _SidecarPhase.verifying,
      message: '사이드카 런타임 상태를 확인하는 중입니다.',
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
      final currentProfile =
          running && listening ? await _loadRunningSidecarProfile() : null;
      final reuseExistingRuntime = running &&
          listening &&
          (currentProfile == desiredProfile ||
              (currentProfile == null &&
                  desiredProfile == SidecarService.hudBootstrapProfile));
      if (reuseExistingRuntime) {
        // Reuse the live runtime when possible, but still verify readiness
        // briefly so the first Stock attach does not race camera/live startup.
        _pushSidecarHistory(
          'AUTO_RUNTIME',
          'reuse running/listening runtime profile=${currentProfile ?? desiredProfile}',
        );
        if (requiresLiveRuntime) {
          _startSidecarLoop();
        } else {
          _stopSidecarLoop(resetSession: true);
        }
        _setSidecarPhase(
          _SidecarPhase.running,
          message: desiredProfile == SidecarService.hudBootstrapProfile
              ? '주행 대기 중: HUD 전용 모드 유지 중'
              : '사이드카 실행 중',
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
            _setSidecarPhase(
              _SidecarPhase.running,
              message: '카메라/그래픽 연결 대기 중...',
            );
            _scheduleSidecarRuntimeRecovery(reason: 'ready_deferred_reuse');
          }
        }
      } else {
        _setSidecarPhase(
          _SidecarPhase.starting,
          message: desiredProfile == SidecarService.hudBootstrapProfile
              ? '주행 대기 중: HUD 전용 모드 유지 중...'
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
              _setSidecarPhase(
                _SidecarPhase.starting,
                message: desiredProfile == SidecarService.hudBootstrapProfile
                    ? '주행 대기 중: HUD 전용 모드 유지 중...'
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
            _setSidecarPhase(
              _SidecarPhase.deploying,
              message: '사이드카 배포/복구 중...',
            );
            await _sidecarService.deploy(ssh);
            _pushSidecarHistory('AUTO_DEPLOY', 'ok');
            _setSidecarPhase(
              _SidecarPhase.starting,
              message: desiredProfile == SidecarService.hudBootstrapProfile
                  ? '주행 대기 중: HUD 전용 모드 유지 중...'
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
        _setSidecarPhase(
          _SidecarPhase.verifying,
          message: desiredProfile == SidecarService.hudBootstrapProfile
              ? 'HUD 전용 연결 확인 중...'
              : '카메라 스트림 연결 확인 중...',
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
          _setSidecarPhase(
            _SidecarPhase.running,
            message: desiredProfile == SidecarService.hudBootstrapProfile
                ? '주행 대기 중: HUD 전용 모드 유지 중'
                : '사이드카 실행 중',
          );
        } catch (e) {
          _pushSidecarHistory('READY_DEFER', '$e');
          _setSidecarPhase(
            _SidecarPhase.running,
            message: desiredProfile == SidecarService.hudBootstrapProfile
                ? 'HUD 전용 연결 대기 중...'
                : '사이드카 연결 대기 중...',
          );
          if (requiresLiveRuntime) {
            _scheduleSidecarRuntimeRecovery(reason: 'ready_deferred');
          }
        }
      }
      await _refreshSidecarProcessStatus();
      final keepBootstrapForC4 =
          desiredProfile == SidecarService.hudBootstrapProfile &&
              _healthUsesC4SafeBootstrap(_sidecarHealthSnapshot);
      final downgradeLiveForC4 =
          _shouldDowngradeLiveRuntimeForC4Safe(_sidecarHealthSnapshot);
      if (keepBootstrapForC4) {
        _pushSidecarHistory(
          'C4_SAFE_HOLD',
          'profile=p1 waiting radar startupProtection='
              '${_sidecarHealthSnapshot['startupProtectionActive']} '
              'radarFreshStable=${_sidecarHealthSnapshot['radarFreshStable']}',
        );
        _setSidecarPhase(
          _SidecarPhase.running,
          message: 'c4 안정화 대기 중: HUD 전용 모드 유지 중',
        );
        _scheduleSidecarRuntimeRecovery(
          reason: 'c4_safe_bootstrap_hold',
          minDelay: const Duration(milliseconds: 1200),
          preferSooner: true,
        );
      } else if (downgradeLiveForC4) {
        _pushSidecarHistory(
          'C4_SAFE_DOWNGRADE',
          'profile=$_currentSidecarProfile startupProtection='
              '${_sidecarHealthSnapshot['startupProtectionActive']} '
              'radarFreshStable=${_sidecarHealthSnapshot['radarFreshStable']}',
        );
        _setSidecarPhase(
          _SidecarPhase.running,
          message: 'c4 런타임 안정화 재시도 중...',
        );
        _scheduleSidecarRuntimeRecovery(
          reason: 'c4_safe_live_unstable',
          minDelay: const Duration(milliseconds: 900),
          preferSooner: true,
        );
      } else {
        _clearSidecarRecoverySchedule();
      }
      _suppressCameraErrors = false;
    } catch (e) {
      _pushSidecarHistory('FAIL', 'auto runtime: $e');
      _setSidecarPhase(
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
      _setSidecarPhase(_SidecarPhase.idle);
      return;
    }
    _cancelDelayedSidecarStop();
    _clearSidecarRecoverySchedule();
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _setSidecarPhase(_SidecarPhase.idle);
      return;
    }
    _sidecarAutoManaging = true;
    _pushSidecarHistory('AUTO_STOP', 'start');
    _setSidecarPhase(
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
      _setSidecarPhase(_SidecarPhase.idle);
    }
  }

}
