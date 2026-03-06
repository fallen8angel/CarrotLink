part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasDebugActionsComponents on _LiveDriveCanvasScreenState {
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
      'toggles=ar=$_debugShowArOverlay path=$_debugShowPathFill lane=$_debugShowLaneLines edge=$_debugShowRoadEdge lead1=$_debugShowLead1 lead2=$_debugShowLead2 radarBadge=$_debugShowRadarBadge radarVector=$_debugShowRadarVector tf=$_debugShowStopDistanceTf state=$_debugShowStateText',
      'preview=mode=$_debugOverlayPreviewMode scenario=${_overlayPreviewScenarioLabel(_debugOverlayPreviewScenario)} plot=${_overlayPreviewPlotModeLabel(_debugOverlayPreviewPlotMode)} speed=${_debugOverlayPreviewSpeed.toStringAsFixed(2)}x',
      if ((_sidecarProcessStatusError ?? '').trim().isNotEmpty)
        'error=${_sidecarProcessStatusError!.trim()}',
    ].join('\n');
  }

  Future<void> _copyDebugSnapshotImpl() async {
    final text = _buildDebugSnapshotText();
    await Clipboard.setData(ClipboardData(text: text));
    _pushSidecarHistory('CHECK', 'snapshot copied');
    _toast('디버그 스냅샷 복사 완료');
  }
}
