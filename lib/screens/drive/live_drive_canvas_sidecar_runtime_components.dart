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
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 300),
    Duration healthTimeout = const Duration(seconds: 2),
    Duration wsTimeout = const Duration(seconds: 2),
  }) async {
    Future<void> probeHealth() async {
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
        if (decoded is! Map || decoded['ok'] != true) {
          throw Exception('health not ok');
        }
      } finally {
        client.close(force: true);
      }
    }

    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        await probeHealth();

        WebSocket? ws;
        StreamSubscription<dynamic>? wsSub;
        try {
          final firstPacket = Completer<void>();
          ws = await WebSocket.connect(_liveCameraWsUrl).timeout(wsTimeout);
          wsSub = ws.listen(
            (event) {
              if (firstPacket.isCompleted) return;
              if (event is List<int> && event.isNotEmpty) {
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
        return;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(pollInterval);
      }
    }
    throw Exception('ready timeout: $lastError');
  }

  Future<void> _ensureSidecarRuntime({String reason = 'auto'}) async {
    if (!_openpilotOverlayMode || _cameraSuspendedByLifecycle) return;
    if (_debugOverlayPreviewMode) return;
    if (_sidecarAutoManaging) return;
    _cancelDelayedSidecarStop();
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) return;
    _sidecarAutoManaging = true;
    _suppressCameraErrors = true;
    _beginStartupProvisionalSync(reason: 'sidecar_runtime_start');
    _pushSidecarHistory('AUTO_RUNTIME', 'start reason=$reason');
    _setSidecarPhase(
      _SidecarPhase.verifying,
      message: '사이드카 런타임 상태를 확인하는 중입니다.',
    );
    if (mounted) {
      _safeSetState(() => _cameraLoading = true);
    } else {
      _cameraLoading = true;
    }
    try {
      await _ensureSidecarRevisionUpToDate(ssh);
      final statusRaw = await _sidecarService.status(ssh);
      final status = _parseStatusPairs(statusRaw);
      final running = status['running'] == '1';
      final listening = status['listening'] == '1';
      if (running && listening) {
        // Sidecar is already up — skip the full ready-wait so a brief WS
        // reconnect (350 ms) does not trigger a 3-second "verifying" banner.
        _pushSidecarHistory('AUTO_RUNTIME', 'reuse running/listening runtime');
        _startSidecarLoop();
        _setSidecarPhase(
          _SidecarPhase.running,
          message: '사이드카 실행 중',
        );
      } else {
        _setSidecarPhase(
          _SidecarPhase.starting,
          message:
              running || listening ? '사이드카 런타임 복구 중...' : '사이드카 시작 중...',
        );
        try {
          await _sidecarService.start(ssh);
          _sidecarLastStartAt = DateTime.now();
          _pushSidecarHistory('AUTO_START', 'start ok');
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
                message: '사이드카 시작 중...',
              );
              await _sidecarService.start(ssh);
              _sidecarLastStartAt = DateTime.now();
              _pushSidecarHistory('AUTO_START', 'start ok (after bootstrap)');
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
              message: '사이드카 시작 중...',
            );
            await _sidecarService.start(ssh);
            _sidecarLastStartAt = DateTime.now();
            _pushSidecarHistory('AUTO_RESTART', 'start ok (after deploy)');
          } else {
            rethrow;
          }
        }

        _startSidecarLoop();
        _setSidecarPhase(
          _SidecarPhase.verifying,
          message: '카메라 스트림 연결 확인 중...',
        );
        try {
          await _waitForSidecarReady(
            timeout: const Duration(milliseconds: 3000),
            pollInterval: const Duration(milliseconds: 150),
            healthTimeout: const Duration(milliseconds: 700),
            wsTimeout: const Duration(milliseconds: 1200),
          );
          _setSidecarPhase(
            _SidecarPhase.running,
            message: '사이드카 실행 중',
          );
        } catch (e) {
          _pushSidecarHistory('READY_DEFER', '$e');
          _setSidecarPhase(
            _SidecarPhase.running,
            message: '사이드카 연결 대기 중...',
          );
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
