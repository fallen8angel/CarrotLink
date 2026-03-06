part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasDebugActionsComponents
    on _LiveDriveCanvasScreenState {
  String _prettyDebugJson(Object? value) {
    const encoder = JsonEncoder.withIndent('  ');
    try {
      return encoder.convert(value);
    } catch (_) {
      return value?.toString() ?? 'null';
    }
  }

  Map<String, dynamic>? _coerceStringMap(dynamic raw) {
    if (raw is! Map) return null;
    return raw.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }

  String _nativeArRenderBandsSummary(Map<String, dynamic>? bands) {
    if (bands == null || bands.isEmpty) return '-';
    final clutter = bands['overlayComplexityBand'] ?? '-';
    final anchor = bands['effectiveAnchorBand'] ?? '-';
    final budget = bands['budgetBand'] ?? '-';
    final stage = bands['degradationStage'] ?? '-';
    return 'clutter=$clutter anchor=$anchor budget=$budget stage=$stage';
  }

  String _nativeArRenderAdviceSummary(dynamic raw) {
    if (raw is! List || raw.isEmpty) return '-';
    return raw.map((e) => e.toString()).join(',');
  }

  List<String> _arSceneDiagnosisLines({
    required _DriveArScene localScene,
    required Map<String, dynamic>? localPayload,
    required Map<String, dynamic>? nativePayload,
    required int? nativeViewId,
  }) {
    final lines = <String>[];
    final hasRoute = localScene.routePoints.isNotEmpty;
    final hasTurn = localScene.turnCue != null;
    if (localPayload == null) {
      lines.add('live scene 없음');
      if (!localScene.health.calibrationOk) {
        lines.add('- calibration 이 아직 준비되지 않음');
      }
      if (!localScene.health.frameGapOk) {
        lines.add('- model/camera frame gap 이 허용 범위를 벗어남');
      }
      if (!hasRoute && !hasTurn) {
        lines.add('- route path 와 turn cue 가 모두 비어 있음');
      } else if (!hasRoute) {
        lines.add('- route path 가 비어 있음');
      } else if (!hasTurn) {
        lines.add('- turn cue 가 비어 있음');
      }
    } else {
      lines.add('live scene 존재');
    }

    if (nativeViewId == null) {
      lines.add('- native camera view 가 아직 생성되지 않음');
    } else if (nativePayload == null && localPayload != null) {
      lines.add('- native payload 가 아직 push 되지 않았거나 clear 된 상태');
    }

    if (!hasRoute &&
        !hasTurn &&
        nativeViewId == null &&
        !localScene.health.calibrationOk) {
      lines.add('- 폰 TMap/fake GPS 만으로는 현재 live AR scene 이 생성되지 않음');
      lines.add('- comma sidecar live 데이터 또는 저장된 AR replay 가 필요함');
    }

    if (_debugArReplayMode && _activeArReplayFrame != null) {
      lines.add('replay 활성: ${_activeArReplayFrame!.label}');
    } else if (_arReplayFrames.isNotEmpty) {
      lines.add('저장된 replay ${_arReplayFrames.length}개 있음: "마지막 캡처 재생"으로 테스트 가능');
    }

    if (lines.isEmpty) {
      lines.add('특이사항 없음');
    }
    return lines;
  }

  String _nativeArRenderSummary(Map<String, dynamic>? debug) {
    if (debug == null || debug.isEmpty) return '-';
    final stabilized = _coerceStringMap(debug['stabilizedPolicy']);
    final retention = _coerceStringMap(debug['retention']);
    final anchorSmoothing = _coerceStringMap(debug['anchorSmoothing']);
    final smoothedBands = _coerceStringMap(debug['smoothedBands']);
    final stats = _coerceStringMap(debug['stats']);
    final budget = stabilized?['effectiveRenderBudget'] ?? '-';
    final shellAlpha = stabilized?['shellAlphaMultiplier'] ?? '-';
    final guideAlpha = stabilized?['guideAlphaMultiplier'] ?? '-';
    final trailAlpha = stabilized?['trailAlphaMultiplier'] ?? '-';
    final retained = retention?['retainedFraction'] ?? '-';
    final retainReason = retention?['lastReason'] ?? '-';
    final gateDelta = anchorSmoothing?['gateDeltaPx'] ?? '-';
    final statusDelta = anchorSmoothing?['statusDeltaPx'] ?? '-';
    final bands = _nativeArRenderBandsSummary(smoothedBands);
    final advice = _nativeArRenderAdviceSummary(debug['tuningAdvice']);
    final stage = stats?['lastDegradationStage'] ?? '-';
    final unstableFrames = stats?['unstableFrames'] ?? '-';
    final stageChanges = stats?['degradationStageChanges'] ?? '-';
    return 'budget=$budget shellAlpha=$shellAlpha guideAlpha=$guideAlpha '
        'trailAlpha=$trailAlpha retained=$retained reason=$retainReason '
        'gateDelta=$gateDelta statusDelta=$statusDelta '
        'bands={$bands} stage=$stage unstable=$unstableFrames '
        'stageChanges=$stageChanges advice=$advice';
  }

  Future<void> _debugActionHealthImpl() async {
    try {
      await _refreshSidecarProcessStatus();
      _pushSidecarHistory('CHECK', 'health');
      _toast('헬스체크 완료');
    } catch (e) {
      _pushSidecarHistory('FAIL', 'health: $e');
      _toast('헬스체크 실패: $e', isError: true);
    }
  }

  Future<void> _debugActionWsProbeImpl() async {
    try {
      await _waitForSidecarReady();
      _pushSidecarHistory('CHECK', 'ws probe ok');
      _toast('WS 프로브 성공');
    } catch (e) {
      _pushSidecarHistory('FAIL', 'ws probe: $e');
      _toast('WS 프로브 실패: $e', isError: true);
    }
  }

  Future<void> _debugActionTailLogImpl() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _toast('SSH 연결 안됨', isError: true);
      return;
    }
    try {
      final text = await _sidecarService.tailLog(ssh, lines: 50);
      _pushSidecarHistory('CHECK', 'tail log');
      await _showDebugTextDialog('사이드카 로그 tail(50)', text.trim());
    } catch (e) {
      _pushSidecarHistory('FAIL', 'tail log: $e');
      _toast('로그 조회 실패: $e', isError: true);
    }
  }

  Future<void> _debugActionRedeployImpl() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _toast('SSH 연결 안됨', isError: true);
      return;
    }
    try {
      _setSidecarPhase(_SidecarPhase.deploying, message: '수동 재배포 중...');
      await _sidecarService.deploy(ssh);
      _sidecarLastDeployAt = DateTime.now();
      _sidecarLastDeployResult = 'success';
      _sidecarLocalRevision = await _sidecarService.localRevision();
      _sidecarRemoteRevision = await _sidecarService.remoteRevision(ssh);
      _sidecarLastRevisionCheckedAt = DateTime.now();
      _sidecarRevisionAction = 'manual_deploy';
      _pushSidecarHistory('MANUAL_DEPLOY', 'ok');
      await _refreshSidecarProcessStatus();
      _setSidecarPhase(_SidecarPhase.idle, message: '재배포 완료');
      _toast('재배포 완료 (sha256:${_shortSidecarRevision(_sidecarLocalRevision)})');
    } catch (e) {
      _sidecarLastDeployResult = 'fail';
      _sidecarRevisionAction = 'manual_deploy_fail';
      _pushSidecarHistory('FAIL', 'redeploy: $e');
      _setSidecarPhase(_SidecarPhase.failed, message: e.toString());
      _toast('재배포 실패: $e', isError: true);
    }
  }

  Future<void> _debugActionRestartImpl() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _toast('SSH 연결 안됨', isError: true);
      return;
    }
    try {
      _setSidecarPhase(_SidecarPhase.stopping, message: '수동 재시작(중지)...');
      await _sidecarService.stop(ssh);
      _sidecarLastStopAt = DateTime.now();
      _setSidecarPhase(_SidecarPhase.starting, message: '수동 재시작(시작)...');
      await _sidecarService.start(ssh);
      _sidecarLastStartAt = DateTime.now();
      await _waitForSidecarReady();
      _startSidecarLoop();
      _pushSidecarHistory('MANUAL_RESTART', 'ok');
      await _refreshSidecarProcessStatus();
      _setSidecarPhase(_SidecarPhase.running, message: '재시작 완료');
      _toast('재시작 완료');
    } catch (e) {
      _pushSidecarHistory('FAIL', 'restart: $e');
      _setSidecarPhase(_SidecarPhase.failed, message: e.toString());
      _toast('재시작 실패: $e', isError: true);
    }
  }

  Future<void> _debugActionInspectArSceneImpl() async {
    final localScene = _overlayNotifier.value.buildArScene(
      cameraKind: _liveCameraKind,
    );
    final localPayload = localScene.isEmpty
        ? null
        : localScene.toPayload(cameraKind: _liveCameraKind);

    Map<String, dynamic>? nativePayload;
    Map<String, dynamic>? nativeRenderDebug;
    final viewId = _nativeCameraViewId;
    if (viewId != null) {
      try {
        final raw = await _LiveDriveCanvasScreenState
            ._nativeCameraControlChannel
            .invokeMethod<dynamic>(
          'getArScene',
          <String, dynamic>{'viewId': viewId},
        );
        nativePayload = _coerceStringMap(raw);
      } catch (e) {
        nativePayload = <String, dynamic>{'error': e.toString()};
      }
      try {
        final raw = await _LiveDriveCanvasScreenState
            ._nativeCameraControlChannel
            .invokeMethod<dynamic>(
          'getArRenderDebug',
          <String, dynamic>{'viewId': viewId},
        );
        nativeRenderDebug = _coerceStringMap(raw);
      } catch (e) {
        nativeRenderDebug = <String, dynamic>{'error': e.toString()};
      }
    }

    final diagnosis = _arSceneDiagnosisLines(
      localScene: localScene,
      localPayload: localPayload,
      nativePayload: nativePayload,
      nativeViewId: viewId,
    );

    final lines = <String>[
      'cameraKind=${_liveCameraKind.name}',
      'bridgeEnabled=$_debugPushNativeArScene',
      'replayStatus=${_arReplayStatusLabel()}',
      'nativeViewId=${viewId ?? '-'}',
      'localRoutePoints=${localScene.routePoints.length}',
      'localTurnInfo=${localScene.turnCue?.turnInfo ?? 0}',
      'localLayoutProfile=${localScene.presentation.layoutProfile}',
      'localRenderBudget=${localScene.presentation.renderBudget}',
      'localFrameGap=${localScene.health.frameGap ?? '-'}',
      'localCalibrationOk=${localScene.health.calibrationOk}',
      'localFrameGapOk=${localScene.health.frameGapOk}',
      '',
      '[diagnosis]',
      ...diagnosis,
      '',
      '[local payload]',
      _prettyDebugJson(localPayload),
      '',
      '[native payload]',
      _prettyDebugJson(nativePayload),
      '',
      '[native render summary]',
      _nativeArRenderSummary(nativeRenderDebug),
      '',
      '[native render]',
      _prettyDebugJson(nativeRenderDebug),
    ];

    _pushSidecarHistory('CHECK', 'inspect ar_scene');
    await _showDebugTextDialog('AR Scene', lines.join('\n'));
  }

  Future<bool> _confirmDebugActionImpl({
    required String title,
    required String message,
    String confirmText = '실행',
  }) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _debugActionResetSidecarImpl() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _toast('SSH 연결 안됨', isError: true);
      return;
    }

    final confirmed = await _confirmDebugAction(
      title: '사이드카 테스트 초기화',
      message: '사이드카 파일/로그를 삭제하고 프로세스 등록도 제거합니다.\n'
          '완전 초기 상태 테스트용입니다. 계속할까요?',
      confirmText: '초기화',
    );
    if (!confirmed) return;

    try {
      _setSidecarPhase(_SidecarPhase.stopping, message: '사이드카 초기화 중...');
      _stopSidecarLoop();
      await _sidecarService.resetForTesting(ssh,
          removeManagerRegistration: true);
      _sidecarLastStopAt = DateTime.now();
      _sidecarLastDeployAt = null;
      _sidecarLastDeployResult = '-';
      _sidecarLocalRevision = null;
      _sidecarRemoteRevision = null;
      _sidecarLastRevisionCheckedAt = DateTime.now();
      _sidecarRevisionAction = 'reset';
      _sidecarLastBootstrapAt = DateTime.now();
      _sidecarLastBootstrapResult = 'reset';
      _sidecarLastBootstrapDetail = 'manual testing reset';
      await _setSidecarBootstrapDone(false);
      _pushSidecarHistory('MANUAL_RESET', 'sidecar wiped for clean test');
      await _refreshSidecarProcessStatus();
      _setSidecarPhase(_SidecarPhase.idle, message: '사이드카 초기화 완료');
      _toast('사이드카 초기화 완료');
    } catch (e) {
      _pushSidecarHistory('FAIL', 'reset: $e');
      _setSidecarPhase(_SidecarPhase.failed, message: e.toString());
      _toast('사이드카 초기화 실패: $e', isError: true);
    }
  }

  String _buildDebugSnapshotTextImpl() {
    final process = _sidecarProcessSnapshot;
    final health = _sidecarHealthSnapshot;
    final profile = _sidecarProfileSnapshot;
    final cameraQuality = _sidecarCameraQualitySnapshot;
    final arScene = _overlayNotifier.value.buildArScene(
      cameraKind: _liveCameraKind,
    );
    final arText = arScene.turnCue?.primaryText ?? '';
    return [
      'time=${DateTime.now().toIso8601String()}',
      'phase=$_sidecarPhase',
      'connected=$_sidecarConnected',
      'cameraQuality=${_adaptiveCameraQualityLabel(_adaptiveCameraQualityMode)} score=$_adaptiveBadScore',
      'deploy=$_sidecarLastDeployResult at ${_fmtClock(_sidecarLastDeployAt)}',
      'revision local=${_shortSidecarRevision(_sidecarLocalRevision)} remote=${_shortSidecarRevision(_sidecarRemoteRevision)} action=$_sidecarRevisionAction checked=${_fmtClock(_sidecarLastRevisionCheckedAt)}',
      'remote_py=$_sidecarRemotePyName remote_rev=$_sidecarRemoteRevisionLabel remote_updated=$_sidecarRemoteUpdatedLabel',
      'bootstrap=$_sidecarLastBootstrapResult at ${_fmtClock(_sidecarLastBootstrapAt)} done=${_sidecarBootstrapDone ?? false}',
      'start=${_fmtClock(_sidecarLastStartAt)} stop=${_fmtClock(_sidecarLastStopAt)}',
      'process=${jsonEncode(process)}',
      'health=${jsonEncode(health)}',
      'profile=${jsonEncode(profile)}',
      'camera_quality=${jsonEncode(cameraQuality)}',
      'lastFrame=${_fmtClock(_sidecarLastFrameAt)} fps=${_overlayDebugFps.toStringAsFixed(1)} gap=${_overlayModelCameraGap ?? '-'} drops=$_overlayDropCount',
      'toggles=ar=$_debugShowArOverlay nativeArScene=$_debugPushNativeArScene path=$_debugShowPathFill lane=$_debugShowLaneLines edge=$_debugShowRoadEdge lead1=$_debugShowLead1 lead2=$_debugShowLead2 radarBadge=$_debugShowRadarBadge radarVector=$_debugShowRadarVector tf=$_debugShowStopDistanceTf state=$_debugShowStateText',
      'replay=${_arReplayStatusLabel()}',
      'arScene=camera=${_liveCameraKind.name} profile=${arScene.presentation.layoutProfile} budget=${arScene.presentation.renderBudget} route=${arScene.routePoints.length} turn=${arScene.turnCue?.turnInfo ?? 0} dist=${arScene.turnCue?.distanceMeters?.toStringAsFixed(1) ?? '-'} frameGap=${arScene.health.frameGap ?? '-'} calibrationOk=${arScene.health.calibrationOk} frameGapOk=${arScene.health.frameGapOk} text=${jsonEncode(arText)}',
      'preview=mode=$_debugOverlayPreviewMode scenario=${_overlayPreviewScenarioLabel(_debugOverlayPreviewScenario)} plot=${_overlayPreviewPlotModeLabel(_debugOverlayPreviewPlotMode)} speed=${_debugOverlayPreviewSpeed.toStringAsFixed(2)}x',
      if ((_sidecarProcessStatusError ?? '').trim().isNotEmpty)
        'error=${_sidecarProcessStatusError!.trim()}',
    ].join('\n');
  }

  Future<String> _buildDebugSnapshotTextWithNativeImpl() async {
    final base = _buildDebugSnapshotText();
    final viewId = _nativeCameraViewId;
    if (viewId == null) {
      return '$base\nnativeRender=-';
    }
    try {
      final raw = await _LiveDriveCanvasScreenState._nativeCameraControlChannel
          .invokeMethod<dynamic>(
        'getArRenderDebug',
        <String, dynamic>{'viewId': viewId},
      );
      final debug = _coerceStringMap(raw);
      return '$base\nnativeRender=${_nativeArRenderSummary(debug)}';
    } catch (e) {
      return '$base\nnativeRender=error:${e.toString()}';
    }
  }

  Future<void> _copyDebugSnapshotImpl() async {
    final text = await _buildDebugSnapshotTextWithNativeImpl();
    await Clipboard.setData(ClipboardData(text: text));
    _pushSidecarHistory('CHECK', 'snapshot copied');
    _toast('디버그 스냅샷 복사 완료');
  }
}
