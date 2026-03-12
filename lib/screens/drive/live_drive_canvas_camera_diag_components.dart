part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasCameraDiagComponents on _LiveDriveCanvasScreenState {
  String _cameraDiagTimestampForFileName(DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}_'
        '${three(now.millisecond)}';
  }

  Future<Directory> _resolveCameraDiagDir() async {
    try {
      await StorageLayoutService.instance.ensureBaseFolders();
      final preferred =
          Directory('${StorageLayoutService.logsPath}/camera_errors');
      if (!await preferred.exists()) {
        await preferred.create(recursive: true);
      }
      return preferred;
    } catch (_) {
      final fallback =
          Directory('${Directory.systemTemp.path}/carrotlink_camera_errors');
      if (!await fallback.exists()) {
        await fallback.create(recursive: true);
      }
      return fallback;
    }
  }

  Future<void> _captureCameraErrorDiagnostics({
    required String source,
    required String reason,
  }) async {
    if (_cameraDiagCaptureInFlight) return;
    final now = DateTime.now();
    final last = _lastCameraDiagCapturedAt;
    if (last != null &&
        now.difference(last) <
            _LiveDriveCanvasScreenState._cameraDiagCaptureCooldown) {
      return;
    }

    _cameraDiagCaptureInFlight = true;
    _lastCameraDiagCapturedAt = now;
    try {
      final ssh = _sshService ??
          (mounted ? Provider.of<SSHService>(context, listen: false) : null);
      final report = <String, dynamic>{
        'timestamp': now.toIso8601String(),
        'hostIp': _hostIp,
        'source': source,
        'reason': reason,
        'modeTag': _modeTagLabel,
        'openpilotOverlayMode': _openpilotOverlayMode,
        'nativeCameraMode': _useNativeLiveCamera,
        'liveCamera': _liveCameraName,
        'cameraLoading': _cameraLoading,
        'cameraError': _cameraError,
        'sidecarConnected': _sidecarConnected,
        'sidecarPhase': _sidecarPhase.name,
      };

      if (_openpilotOverlayMode) {
        try {
          report['sidecarHealth'] = await _sidecarGetJson('/health');
        } catch (e) {
          report['sidecarHealthError'] = e.toString();
        }
        try {
          report['cameraHealth'] = await _cameraGetJson('/health');
        } catch (e) {
          report['cameraHealthError'] = e.toString();
        }
      } else {
        report['sidecarHealth'] = 'skipped (webrtc_mode)';
        report['cameraHealth'] = 'skipped (webrtc_mode)';
      }

      String tmuxTail = 'ssh_not_connected';
      if (ssh != null && ssh.isConnected) {
        try {
          final result = await ssh.executeCommandResult(
            _LiveDriveCanvasScreenState._cameraDiagTmuxTailCommand,
            timeout: const Duration(seconds: 25),
          );
          tmuxTail = [
            if (result.stdout.trim().isNotEmpty) result.stdout.trim(),
            if (result.stderr.trim().isNotEmpty)
              '\n[stderr]\n${result.stderr.trim()}',
            if (result.stdout.trim().isEmpty && result.stderr.trim().isEmpty)
              '(출력 없음)',
          ].join('\n');
          report['tmuxExitCode'] = result.exitCode;
        } catch (e) {
          tmuxTail = 'tmux_capture_failed: $e';
        }

        if (_openpilotOverlayMode) {
          try {
            report['sidecarStatusRaw'] = await _sidecarService.status(ssh);
          } catch (e) {
            report['sidecarStatusError'] = e.toString();
          }
        }
      }

      final dir = await _resolveCameraDiagDir();
      final file = File(
        '${dir.path}/camera_error_${_cameraDiagTimestampForFileName(now)}.log',
      );
      final pretty = const JsonEncoder.withIndent('  ').convert(report);
      await file.writeAsString(
        '''
=== camera_error diagnostics ===
$pretty

=== tmux tail ===
$tmuxTail
''',
      );
      debugPrint(
          '[DriveCanvas][diag] camera_error snapshot saved: ${file.path}');
    } catch (e) {
      debugPrint('[DriveCanvas][diag] camera_error snapshot failed: $e');
    } finally {
      _cameraDiagCaptureInFlight = false;
    }
  }
}
