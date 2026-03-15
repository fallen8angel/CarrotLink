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
    _pushSidecarHistory(
      'AUTO_REV_NOTICE',
      'updated rev=${_shortSidecarRevision(normalized)}',
    );
  }

  Future<void> _ensureSidecarRevisionUpToDateImpl(SSHService ssh) async {
    final localRevision = await _sidecarService.localRevision();
    final remoteRevision = await _sidecarService.remoteRevision(ssh);

    if (remoteRevision == localRevision) {
      return;
    }

    _pushSidecarHistory(
      'AUTO_REV',
      'mismatch local=${_shortSidecarRevision(localRevision)} remote=${_shortSidecarRevision(remoteRevision)}',
    );
    _setSidecarPhase(
      _SidecarPhase.deploying,
      message: '사이드카 업데이트 중...',
    );

    await _sidecarService.deploy(ssh);

    final remoteAfter = await _sidecarService.remoteRevision(ssh);
    if (remoteAfter != localRevision) {
      throw Exception(
        '사이드카 업데이트 검증 실패(local=${_shortSidecarRevision(localRevision)} remote=${_shortSidecarRevision(remoteAfter)})',
      );
    }

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
      await _setSidecarBootstrapDone(true);
      _pushSidecarHistory('AUTO_BOOTSTRAP', 'deploy ok');
      return true;
    } catch (e) {
      _pushSidecarHistory('AUTO_BOOTSTRAP_FAIL', '$e');
      return false;
    }
  }
}
