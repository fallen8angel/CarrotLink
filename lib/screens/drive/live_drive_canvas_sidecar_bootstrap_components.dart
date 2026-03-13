part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasSidecarBootstrapComponents
    on _LiveDriveCanvasScreenState {
  Future<bool> _isSidecarBootstrapDoneImpl() async {
    if (_sidecarBootstrapDone != null) return _sidecarBootstrapDone!;
    try {
      final prefs = await SharedPreferences.getInstance();
      _sidecarBootstrapDone = prefs.getBool(
            _LiveDriveCanvasScreenState._sidecarBootstrapDonePrefKey,
          ) ??
          false;
    } catch (_) {
      _sidecarBootstrapDone ??= false;
    }
    return _sidecarBootstrapDone ?? false;
  }

  Future<void> _setSidecarBootstrapDoneImpl(bool value) async {
    _sidecarBootstrapDone = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
        _LiveDriveCanvasScreenState._sidecarBootstrapDonePrefKey,
        value,
      );
    } catch (_) {}
  }

  String _shortSidecarRevisionImpl(String? revision) {
    return _sidecarService.shortRevision(revision);
  }

  Future<void> _notifySidecarRevisionUpdatedImpl(String revision) async {
    final normalized = revision.trim();
    if (normalized.isEmpty) return;
    var shouldNotify = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_hostIp:$normalized';
      final prev = prefs.getString(
        _LiveDriveCanvasScreenState._sidecarRevisionNotifiedPrefKey,
      );
      if (prev == key) {
        shouldNotify = false;
      } else {
        await prefs.setString(
          _LiveDriveCanvasScreenState._sidecarRevisionNotifiedPrefKey,
          key,
        );
      }
    } catch (_) {}
    if (!shouldNotify) return;
    _toast(
      '사이드카 업데이트됨 (sha256:${_shortSidecarRevision(normalized)})',
      duration: const Duration(seconds: 4),
    );
  }

  Future<void> _ensureSidecarRevisionUpToDateImpl(SSHService ssh) async {
    final localRevision = await _sidecarService.localRevision();
    final remoteRevision = await _sidecarService.remoteRevision(ssh);
    _sidecarLocalRevision = localRevision;
    _sidecarRemoteRevision = remoteRevision;
    _sidecarLastRevisionCheckedAt = DateTime.now();

    if (remoteRevision == localRevision) {
      _sidecarRevisionAction = 'match';
      return;
    }

    _sidecarRevisionAction = 'mismatch';
    _pushSidecarHistory(
      'AUTO_REV',
      'mismatch local=${_shortSidecarRevision(localRevision)} remote=${_shortSidecarRevision(remoteRevision)}',
    );
    _setSidecarPhase(
      _SidecarPhase.deploying,
      message: '사이드카 업데이트 중...',
    );

    await _sidecarService.deploy(ssh);
    _sidecarLastDeployAt = DateTime.now();
    _sidecarLastDeployResult = 'success';

    final remoteAfter = await _sidecarService.remoteRevision(ssh);
    _sidecarRemoteRevision = remoteAfter;
    _sidecarLastRevisionCheckedAt = DateTime.now();
    if (remoteAfter != localRevision) {
      _sidecarRevisionAction = 'verify_fail';
      throw Exception(
        '사이드카 업데이트 검증 실패(local=${_shortSidecarRevision(localRevision)} remote=${_shortSidecarRevision(remoteAfter)})',
      );
    }

    _sidecarRevisionAction = 'updated';
    _pushSidecarHistory(
      'AUTO_REV',
      'updated rev=${_shortSidecarRevision(localRevision)}',
    );
    await _notifySidecarRevisionUpdated(localRevision);
  }

  bool _isSidecarDeployMissingErrorImpl(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('sidecar_not_deployed') ||
        message.contains('missing sidecar') ||
        message.contains('not deployed') ||
        message.contains('no such file');
  }

  Future<bool> _tryAutoBootstrapSidecarImpl(
    SSHService ssh, {
    required Object startError,
  }) async {
    if (!_isSidecarDeployMissingError(startError)) return false;
    _sidecarLastBootstrapAt = DateTime.now();
    _sidecarLastBootstrapDetail = startError.toString();
    _sidecarLastBootstrapResult = 'pending';
    final done = await _isSidecarBootstrapDone();
    if (done) {
      _pushSidecarHistory('AUTO_BOOTSTRAP', 'recovery deploy requested');
    } else {
      _pushSidecarHistory('AUTO_BOOTSTRAP', 'first-run deploy requested');
    }
    _setSidecarPhase(
      _SidecarPhase.deploying,
      message: '사이드카 최초 설정을 적용하는 중...',
    );
    try {
      await _sidecarService.deploy(ssh);
      _sidecarLastDeployAt = DateTime.now();
      _sidecarLastDeployResult = 'success';
      _sidecarLastBootstrapAt = DateTime.now();
      _sidecarLastBootstrapResult = 'success';
      _sidecarLastBootstrapDetail = done
          ? 'recovery deploy (missing sidecar detected)'
          : 'first-run deploy';
      await _setSidecarBootstrapDone(true);
      _pushSidecarHistory('AUTO_BOOTSTRAP', 'deploy ok');
      return true;
    } catch (e) {
      _sidecarLastDeployResult = 'fail';
      _sidecarLastBootstrapAt = DateTime.now();
      _sidecarLastBootstrapResult = 'fail';
      _sidecarLastBootstrapDetail = e.toString();
      _pushSidecarHistory('AUTO_BOOTSTRAP_FAIL', '$e');
      return false;
    }
  }
}
