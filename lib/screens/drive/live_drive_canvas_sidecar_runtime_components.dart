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
  }) {
    if (!_openpilotOverlayMode || _cameraSuspendedByLifecycle) return;
    final now = DateTime.now();
    if (_sidecarRecoveryNextAt != null &&
        now.isBefore(_sidecarRecoveryNextAt!)) {
      return;
    }
    final backoff = Duration(seconds: _sidecarRecoveryBackoffSeconds);
    final delay = backoff > minDelay ? backoff : minDelay;
    _sidecarRecoveryNextAt = now.add(delay);
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
    _sidecarRecoveryBackoffSeconds =
        math.min(_sidecarRecoveryBackoffSeconds * 2, 8);
  }

  String _adaptiveCameraQualityLabel(_AdaptiveCameraQualityMode mode) {
    return 'stable';
  }

  void _resetAdaptiveCameraQualityState({bool resetMode = false}) {
    _adaptiveBadScore = 0;
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

  Map<String, dynamic> get _activeCameraRelayStatus {
    final relayRaw = _sidecarHealthSnapshot['cameraRelay'];
    if (relayRaw is! Map) return const <String, dynamic>{};
    final relay = Map<String, dynamic>.from(relayRaw);
    final camerasRaw = relay['cameras'];
    if (camerasRaw is! Map) return const <String, dynamic>{};
    final cameras = Map<String, dynamic>.from(camerasRaw);
    final cameraRaw = cameras[_liveCameraName];
    if (cameraRaw is! Map) return const <String, dynamic>{};
    return Map<String, dynamic>.from(cameraRaw);
  }

  bool get _sidecarProcessAlive => _sidecarProcessSnapshot['running'] == '1';

  bool get _sidecarProcessListening =>
      _sidecarProcessSnapshot['listening'] == '1';

  bool get _sidecarStreamEncoderdAlive =>
      (_sidecarCriticalProcSnapshot['stream_encoderd'] ?? '')
          .trim()
          .startsWith('up:');

  String get _sidecarProcessStatusLabel {
    if (!_openpilotOverlayMode) return 'inactive';
    if (_sidecarProcessAlive && _sidecarProcessListening) return 'up';
    if (_sidecarProcessAlive) return 'up_no_port';
    if (_sidecarProcessListening) return 'port_only';
    return 'down';
  }

  String get _sidecarCameraReadyLabel {
    if (!_openpilotOverlayMode) return 'inactive';
    if (!_sidecarProcessAlive) return 'sidecar_down';
    final camera = _activeCameraRelayStatus;
    if (camera.isEmpty) {
      return _sidecarStreamEncoderdAlive ? 'relay_missing' : 'unavailable';
    }
    final clients = (camera['clients'] as num?)?.toInt() ?? 0;
    final frames = (camera['frames'] as num?)?.toInt() ?? 0;
    final service = camera['service']?.toString().trim() ?? '';
    final codec = camera['codec']?.toString().trim() ?? '';
    if (!_sidecarStreamEncoderdAlive &&
        clients <= 0 &&
        frames <= 0 &&
        service.isEmpty &&
        codec.isEmpty) {
      return 'unavailable';
    }
    if (clients <= 0) return 'no_client';
    if (service.isEmpty) return 'no_service';
    if (codec.isEmpty) return 'no_codec';
    if (_lastCameraFrameId == null) {
      return frames > 0 ? 'await_local_frame' : 'no_frames';
    }
    return 'ready';
  }

  int? get _sidecarCameraAgeMs =>
      (_activeCameraRelayStatus['lastFrameAgeMs'] as num?)?.toInt();

  String get _sidecarCameraAgeLabel {
    final ageMs = _sidecarCameraAgeMs;
    if (ageMs == null || ageMs < 0) return '-';
    return '${ageMs}ms';
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
  }) =>
      (_hasDriveRuntimeProcesses(procs) ||
              _sidecarHealthIndicatesLiveRuntimeReady(health))
          ? SidecarService.driveRuntimeProfile
          : SidecarService.hudBootstrapProfile;

  Future<Map<String, String>> _loadDriveRuntimeCriticalProcStatus(
    SSHService ssh,
  ) async {
    try {
      final criticalRaw = await _sidecarService.criticalProcStatus(ssh);
      final parsed = _parseStatusPairs(criticalRaw);
      if (!mounted) {
        _sidecarCriticalProcSnapshot = parsed;
      } else {
        _safeSetState(() => _sidecarCriticalProcSnapshot = parsed);
      }
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

  String get _sidecarCameraRelaySummary {
    final camera = _activeCameraRelayStatus;
    if (camera.isEmpty) return 'cam=$_liveCameraName relay=missing';
    final clients = (camera['clients'] as num?)?.toInt() ?? 0;
    final frames = (camera['frames'] as num?)?.toInt() ?? 0;
    final queue = (camera['queue'] as num?)?.toInt() ?? 0;
    final queueMax = (camera['queueMax'] as num?)?.toInt() ?? 0;
    final queueDrops = (camera['queueDrops'] as num?)?.toInt() ?? 0;
    final sendDrops = (camera['sendDrops'] as num?)?.toInt() ?? 0;
    final ageMs = (camera['lastFrameAgeMs'] as num?)?.toInt();
    final service = (camera['service']?.toString() ?? '').trim();
    final codec = (camera['codec']?.toString() ?? '').trim();
    final serviceLabel = service.isEmpty ? '-' : service;
    final codecLabel = codec.isEmpty ? '-' : codec;
    final bufferLabel = queueMax > 0 ? '$queue/$queueMax' : '$queue';
    final parts = <String>[
      'cam=$_liveCameraName',
      'client=$clients',
      'frames=$frames',
      'service=$serviceLabel',
      'codec=$codecLabel',
      'q=$bufferLabel',
    ];
    if (queueDrops > 0) parts.add('qd=$queueDrops');
    if (sendDrops > 0) parts.add('sd=$sendDrops');
    if (ageMs != null) parts.add('age=${ageMs}ms');
    return parts.join(' ');
  }

  String get _sidecarLiveRelaySummary {
    final relayRaw = _sidecarHealthSnapshot['liveRelay'];
    if (relayRaw is! Map) return '-';
    final relay = Map<String, dynamic>.from(relayRaw);
    final clients = (relay['clients'] as num?)?.toInt() ?? 0;
    final sendDrops = (relay['sendDrops'] as num?)?.toInt() ?? 0;
    final buildMs = (relay['lastBuildMs'] as num?)?.toDouble();
    final sendMs = (relay['lastSendBatchMs'] as num?)?.toDouble();
    final buildLabel = buildMs == null ? '-' : buildMs.toStringAsFixed(1);
    final sendLabel = sendMs == null ? '-' : sendMs.toStringAsFixed(1);
    return 'clients=$clients build=${buildLabel}ms send=${sendLabel}ms drops=$sendDrops';
  }

  String get _sidecarRemotePyName {
    final raw = (_sidecarProcessSnapshot['py_name'] ?? '').trim();
    if (raw.isNotEmpty) return raw;
    return 'sidecar.py';
  }

  String get _sidecarRemoteRevisionLabel {
    final candidates = <String?>[
      _sidecarProcessSnapshot['remote_revision'],
      _sidecarRemoteRevision,
      _sidecarProcessSnapshot['remote_hash'],
      _sidecarProcessSnapshot['hash'],
      _sidecarProcessSnapshot['version'],
      _sidecarProcessSnapshot['commit'],
    ];
    for (final raw in candidates) {
      final value = (raw ?? '').trim();
      if (value.isNotEmpty) {
        return _shortSidecarRevision(value);
      }
    }
    return '-';
  }

  DateTime? get _sidecarRemoteUpdatedAt {
    final candidates = <String?>[
      _sidecarProcessSnapshot['rev_updated_epoch'],
      _sidecarProcessSnapshot['py_updated_epoch'],
    ];
    for (final raw in candidates) {
      final seconds = int.tryParse((raw ?? '').trim());
      if (seconds != null && seconds > 0) {
        return DateTime.fromMillisecondsSinceEpoch(
          seconds * 1000,
          isUtc: true,
        ).toLocal();
      }
    }
    return _sidecarLastDeployAt;
  }

  String get _sidecarRemoteUpdatedLabel {
    final when = _sidecarRemoteUpdatedAt;
    if (when == null) return '-';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${when.year}-${two(when.month)}-${two(when.day)} ${two(when.hour)}:${two(when.minute)}';
  }

  String get _sidecarScheduledStopSummary {
    final when = _sidecarScheduledStopAt;
    final reason = (_sidecarScheduledStopReason ?? '').trim();
    if (when == null) return '-';
    final remain = when.difference(DateTime.now()).inSeconds;
    final remainClamped = remain > 0 ? remain : 0;
    if (reason.isEmpty) return '${remainClamped}s 후';
    return '$reason / ${remainClamped}s 후';
  }

  Future<void> _refreshSidecarProcessStatus() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      if (!mounted) {
        _sidecarProcessSnapshot = <String, String>{};
        _sidecarCriticalProcSnapshot = <String, String>{};
        _sidecarHealthSnapshot = <String, dynamic>{};
        _sidecarProfileSnapshot = <String, dynamic>{};
        _sidecarCameraQualitySnapshot = <String, dynamic>{};
        _sidecarProcessCheckedAt = DateTime.now();
        _sidecarProcessStatusError = 'SSH 연결 안 됨';
        return;
      }
      _safeSetState(() {
        _sidecarProcessSnapshot = <String, String>{};
        _sidecarCriticalProcSnapshot = <String, String>{};
        _sidecarHealthSnapshot = <String, dynamic>{};
        _sidecarProfileSnapshot = <String, dynamic>{};
        _sidecarCameraQualitySnapshot = <String, dynamic>{};
        _sidecarProcessCheckedAt = DateTime.now();
        _sidecarProcessStatusError = 'SSH 연결 안 됨';
      });
      return;
    }

    final now = DateTime.now();
    final nextProcess = <String, String>{};
    final nextCritical = <String, String>{};
    var nextHealth = <String, dynamic>{};
    var nextProfile = <String, dynamic>{};
    var nextCameraQuality = <String, dynamic>{};
    String? nextError;
    String joinError(String message) =>
        nextError == null ? message : '$nextError / $message';
    try {
      final statusRaw = await _sidecarService.status(ssh);
      nextProcess.addAll(_parseStatusPairs(statusRaw));
      try {
        final criticalRaw = await _sidecarService.criticalProcStatus(ssh);
        nextCritical.addAll(_parseStatusPairs(criticalRaw));
      } catch (e) {
        nextError = joinError('critical proc 조회 실패: $e');
      }
      try {
        nextHealth = await _sidecarGetJson('/health');
      } catch (e) {
        nextError = joinError('health 조회 실패: $e');
      }
      try {
        final cameraHealth = await _cameraGetJson('/health');
        final relay = cameraHealth['cameraRelay'];
        if (relay is Map) {
          nextHealth['cameraRelay'] = Map<String, dynamic>.from(relay);
        }
      } catch (e) {
        nextError = joinError('camera health 조회 실패: $e');
      }
      try {
        final diagHealth = await _diagGetJson('/health');
        final relay = diagHealth['diagRelay'];
        if (relay is Map) {
          nextHealth['diagRelay'] = Map<String, dynamic>.from(relay);
        }
      } catch (e) {
        nextError = joinError('diag health 조회 실패: $e');
      }
      try {
        nextProfile = await _sidecarGetJson('/profile');
      } catch (e) {
        nextError = joinError('/profile 조회 실패: $e');
      }
      try {
        nextCameraQuality = await _cameraGetJson('/camera_quality');
      } catch (e) {
        nextError = joinError('/camera_quality 조회 실패: $e');
      }
    } catch (e) {
      nextError = e.toString();
    }

    if (!mounted) {
      _sidecarProcessSnapshot = nextProcess;
      _sidecarCriticalProcSnapshot = nextCritical;
      _sidecarHealthSnapshot = nextHealth;
      _sidecarProfileSnapshot = nextProfile;
      _sidecarCameraQualitySnapshot = nextCameraQuality;
      _sidecarProcessCheckedAt = now;
      _sidecarProcessStatusError = nextError;
      return;
    }
    _safeSetState(() {
      _sidecarProcessSnapshot = nextProcess;
      _sidecarCriticalProcSnapshot = nextCritical;
      _sidecarHealthSnapshot = nextHealth;
      _sidecarProfileSnapshot = nextProfile;
      _sidecarCameraQualitySnapshot = nextCameraQuality;
      _sidecarProcessCheckedAt = now;
      _sidecarProcessStatusError = nextError;
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
      !_debugOverlayPreviewMode &&
      (_isSidecarBusy ||
          _sidecarPhase == _SidecarPhase.failed ||
          (_openpilotOverlayMode && !_sidecarConnected) ||
          (_openpilotOverlayMode && _overlayStaleActive));

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
    if (_debugOverlayPreviewMode) return;
    if (_sidecarAutoManaging) return;
    final preserveVisibleNativeCamera =
        _useNativeLiveCamera &&
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
          await _sidecarService.start(ssh, profile: desiredProfile);
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
              await _sidecarService.start(ssh, profile: desiredProfile);
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
            _sidecarLastDeployAt = DateTime.now();
            _sidecarLastDeployResult = 'success';
            _pushSidecarHistory('AUTO_DEPLOY', 'ok');
            _setSidecarPhase(
              _SidecarPhase.starting,
              message: desiredProfile == SidecarService.hudBootstrapProfile
                  ? '주행 대기 중: HUD 전용 모드 유지 중...'
                  : '사이드카 시작 중...',
            );
            await _sidecarService.start(ssh, profile: desiredProfile);
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
      unawaited(_refreshSidecarProcessStatus());
      _clearSidecarRecoverySchedule();
      _suppressCameraErrors = false;
    } catch (e) {
      if (_LiveDriveCanvasScreenState._autoDeployDuringHudRuntime) {
        _sidecarLastDeployResult = 'fail';
      }
      _pushSidecarHistory('FAIL', 'auto runtime: $e');
      _setSidecarPhase(
        _SidecarPhase.failed,
        message: e.toString(),
      );
      _scheduleSidecarRuntimeRecovery(reason: 'runtime_failed');
      if (mounted) {
        _toast(
          '사이드카 자동 준비 실패: $e',
          isError: true,
          duration: const Duration(seconds: 5),
        );
      }
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
      _sidecarLastStopAt = DateTime.now();
      _pushSidecarHistory('AUTO_STOP', 'ok');
      unawaited(_refreshSidecarProcessStatus());
    } catch (_) {
      // Ignore stop errors during lifecycle transitions.
    } finally {
      _sidecarAutoManaging = false;
      _setSidecarPhase(_SidecarPhase.idle);
    }
  }

  Color _sidecarProcessStatusColor() {
    switch (_sidecarProcessStatusLabel) {
      case 'up':
        return const Color(0xFF73E07C);
      case 'up_no_port':
      case 'port_only':
        return const Color(0xFFF6B26B);
      case 'inactive':
        return Colors.white70;
      default:
        return const Color(0xFFFF8A8A);
    }
  }

  Color _sidecarCameraStatusColor() {
    switch (_sidecarCameraReadyLabel) {
      case 'ready':
        return const Color(0xFF73E07C);
      case 'inactive':
        return Colors.white70;
      case 'unavailable':
        return const Color(0xFFF6B26B);
      default:
        return const Color(0xFFFF8A8A);
    }
  }
}
