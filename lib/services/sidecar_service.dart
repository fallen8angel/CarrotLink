import 'package:flutter/services.dart';

import 'diagnostics_service.dart';
import 'ssh_service.dart';

class SidecarService {
  SidecarService({DiagnosticsService? diagnostics})
      : _diag = diagnostics ?? DiagnosticsService.instance;

  final DiagnosticsService _diag;

  static const String _sessionName = 'carrotlink_view';
  static const String _pythonFileName = 'carrot_linkview.py';
  static const String _runScriptName = 'run_carrot_linkview.sh';
  static const String _pidFileName = 'sidecar.pid';
  static const String _logFileName = 'carrot_linkview.log';
  static const String _fixedProfile = 'p2';
  static const int defaultPort = 7766;

  String _bash(String script) {
    final escaped = script.replaceAll("'", "'\"'\"'");
    return "bash -lc '$escaped'";
  }

  String _q(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  String _toUnixText(String input) {
    return input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  Future<String> _resolveRemoteBase(
    SSHService ssh, {
    bool strict = true,
  }) async {
    final result = await ssh.executeCommandResult(
      _bash(
        '''
REPO=""
for d in /data/openpilot /home/comma/openpilot; do
  if [ -d "\$d/selfdrive/carrot" ]; then
    REPO="\$d"
    break
  fi
done
if [ -n "\$REPO" ]; then
  echo "\$REPO/selfdrive/carrot"
  exit 0
fi
if [ "${strict ? '1' : '0'}" = "1" ]; then
  echo "OPENPILOT_REPO_NOT_FOUND"
  exit 2
fi
echo "/data/openpilot/selfdrive/carrot"
''',
      ),
      timeout: const Duration(seconds: 12),
    );
    if (!result.isSuccess) {
      throw Exception('사이드카 경로 확인 실패: ${result.output}');
    }
    final lines = result.output
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      throw Exception('사이드카 경로 확인 실패: empty output');
    }
    final base = lines.last;
    if (base == 'OPENPILOT_REPO_NOT_FOUND') {
      throw Exception('openpilot repo를 찾지 못했습니다.');
    }
    return base;
  }

  Future<String> deploy(SSHService ssh) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    _diag.info('sidecar', 'Deploy start');
    final remoteBase = await _resolveRemoteBase(ssh);
    final py = _toUnixText(
        await rootBundle.loadString('assets/sidecar/carrotlink_sidecar.py'));
    final sh = _toUnixText(
        await rootBundle.loadString('assets/sidecar/run_sidecar.sh'));

    final mkdir = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
mkdir -p "\$BASE" "\$BASE/logs"
''',
      ),
      timeout: const Duration(seconds: 30),
    );
    if (!mkdir.isSuccess) {
      throw Exception('배포 경로 생성 실패: ${mkdir.output}');
    }

    await ssh.writeTextFile('$remoteBase/$_pythonFileName', py);
    await ssh.writeTextFile('$remoteBase/$_runScriptName', sh);

    final chmod = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
chmod 755 "\$BASE/$_runScriptName" "\$BASE/$_pythonFileName"
''',
      ),
      timeout: const Duration(seconds: 20),
    );
    if (!chmod.isSuccess) {
      throw Exception('실행 권한 설정 실패: ${chmod.output}');
    }

    _diag.info('sidecar', 'Deploy success');
    return '배포 완료: $remoteBase';
  }

  Future<String> start(
    SSHService ssh, {
    int port = defaultPort,
  }) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    final remoteBase = await _resolveRemoteBase(ssh);
    _diag.info('sidecar', 'Start request profile=$_fixedProfile port=$port');
    final result = await ssh.executeCommandResult(
      _bash(
        // ignore: unnecessary_string_escapes
        '''
BASE=${_q(remoteBase)}
SESSION=${_q(_sessionName)}
PROFILE=${_q(_fixedProfile)}
PORT=${_q(port.toString())}
PIDFILE="\$BASE/$_pidFileName"
LOGFILE="\$BASE/logs/$_logFileName"
if [ ! -f "\$BASE/$_runScriptName" ] || [ ! -f "\$BASE/$_pythonFileName" ]; then
  echo "SIDECAR_NOT_DEPLOYED"
  exit 3
fi

if [ -f "\$PIDFILE" ]; then
  OLD_PID=\$(cat "\$PIDFILE" 2>/dev/null || true)
  if [ -n "\$OLD_PID" ] && kill -0 "\$OLD_PID" 2>/dev/null; then
    kill "\$OLD_PID" 2>/dev/null || true
    sleep 0.2
  fi
  rm -f "\$PIDFILE" || true
fi

if command -v tmux >/dev/null 2>&1; then
  tmux has-session -t "\$SESSION" 2>/dev/null && tmux kill-session -t "\$SESSION" || true
  tmux new-session -d -s "\$SESSION" "env CARROTLINK_SIDECAR_BASE=\$BASE CARROTLINK_SIDECAR_PROFILE=\$PROFILE CARROTLINK_SIDECAR_PORT=\$PORT bash \$BASE/$_runScriptName >> \$LOGFILE 2>&1"
  echo "start_method=tmux"
else
  nohup env CARROTLINK_SIDECAR_BASE="\$BASE" CARROTLINK_SIDECAR_PROFILE="\$PROFILE" CARROTLINK_SIDECAR_PORT="\$PORT" bash "\$BASE/$_runScriptName" >> "\$LOGFILE" 2>&1 &
  NEW_PID=\$!
  if [ -n "\$NEW_PID" ]; then
    echo "\$NEW_PID" > "\$PIDFILE"
  fi
  echo "start_method=nohup"
fi

READY=0
if command -v curl >/dev/null 2>&1; then
  for i in \$(seq 1 40); do
    if curl -fsS --max-time 1 "http://127.0.0.1:\$PORT/health" 2>/dev/null | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
      READY=1
      break
    fi
    sleep 0.25
  done
else
  sleep 2
  if tmux has-session -t "\$SESSION" 2>/dev/null; then
    READY=1
  elif [ -f "\$PIDFILE" ]; then
    PID=\$(cat "\$PIDFILE" 2>/dev/null || true)
    if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
      READY=1
    fi
  fi
fi
if [ "\$READY" -ne 1 ] && command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | awk '{print \$4}' | grep -E "[:.]\\\$PORT\$" >/dev/null 2>&1; then
    READY=1
  fi
fi
if [ "\$READY" -eq 1 ]; then
  echo "SIDECAR_STARTED profile=\$PROFILE port=\$PORT base=\$BASE"
else
  echo "SIDECAR_START_FAILED"
  if command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "\$SESSION" 2>/dev/null; then
      echo "tmux_running=1"
      tmux capture-pane -t "\$SESSION" -p | tail -n 40
    else
      echo "tmux_running=0"
    fi
  fi
  if [ -f "\$PIDFILE" ]; then
    PID=\$(cat "\$PIDFILE" 2>/dev/null || true)
    if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
      echo "nohup_pid_alive=1 pid=\$PID"
    else
      echo "nohup_pid_alive=0 pid=\$PID"
    fi
  fi
  if [ -f "\$LOGFILE" ]; then
    echo "--- $_logFileName tail ---"
    tail -n 80 "\$LOGFILE"
  else
    echo "sidecar_log_missing=\$LOGFILE"
  fi
  exit 4
fi
''',
      ),
      timeout: const Duration(seconds: 60),
    );
    if (!result.isSuccess) {
      _diag.warn('sidecar', 'Start failed output=$result.output');
      throw Exception('사이드카 시작 실패: ${result.output}');
    }
    _diag.info('sidecar', 'Start success output=$result.output');
    return result.output.isEmpty ? 'SIDECAR_STARTED' : result.output;
  }

  Future<String> stop(SSHService ssh) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    _diag.info('sidecar', 'Stop request');
    final remoteBase = await _resolveRemoteBase(ssh, strict: false);
    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
SESSION=${_q(_sessionName)}
PIDFILE="\$BASE/$_pidFileName"
STOPPED=0
if command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t "\$SESSION" 2>/dev/null; then
    tmux kill-session -t "\$SESSION" || true
    STOPPED=1
  fi
fi
if [ -f "\$PIDFILE" ]; then
  PID=\$(cat "\$PIDFILE" 2>/dev/null || true)
  if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
    kill "\$PID" 2>/dev/null || true
    STOPPED=1
  fi
  rm -f "\$PIDFILE" || true
fi
if [ "\$STOPPED" -eq 1 ]; then
  echo "SIDECAR_STOPPED"
else
  echo "SIDECAR_NOT_RUNNING"
fi
''',
      ),
      timeout: const Duration(seconds: 15),
    );
    if (!result.isSuccess) {
      throw Exception('사이드카 중지 실패: ${result.output}');
    }
    _diag.info('sidecar', 'Stop output=$result.output');
    return result.output;
  }

  Future<String> status(
    SSHService ssh, {
    int port = defaultPort,
  }) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    final remoteBase = await _resolveRemoteBase(ssh, strict: false);
    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
SESSION=${_q(_sessionName)}
PORT=${_q(port.toString())}
PIDFILE="\$BASE/$_pidFileName"
RUNNING=0
LISTEN=0
METHOD="none"
if command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t "\$SESSION" 2>/dev/null; then
    RUNNING=1
    METHOD="tmux"
  fi
fi
if [ -f "\$PIDFILE" ]; then
  PID=\$(cat "\$PIDFILE" 2>/dev/null || true)
  if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
    RUNNING=1
    if [ "\$METHOD" = "none" ]; then
      METHOD="nohup"
    fi
  fi
fi
if command -v ss >/dev/null 2>&1; then
  ss -ltn 2>/dev/null | awk '{print \$4}' | grep -E "[:.]\\\$PORT\$" >/dev/null 2>&1 && LISTEN=1 || true
fi
echo "running=\$RUNNING"
echo "listening=\$LISTEN"
echo "method=\$METHOD"
echo "session=\$SESSION"
echo "base=\$BASE"
if [ -f "\$PIDFILE" ]; then
  echo "pid=\$(cat "\$PIDFILE" 2>/dev/null || true)"
else
  echo "pid="
fi
if [ -f "\$BASE/logs/$_logFileName" ]; then
  echo "log_bytes=\$(wc -c < "\$BASE/logs/$_logFileName" 2>/dev/null || echo 0)"
else
  echo "log_bytes=0"
fi
if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time 1 "http://127.0.0.1:\$PORT/health" 2>/dev/null || true
fi
''',
      ),
      timeout: const Duration(seconds: 20),
    );
    if (!result.isSuccess) {
      throw Exception('사이드카 상태 조회 실패: ${result.output}');
    }
    return result.output;
  }

  Future<String> tailLog(
    SSHService ssh, {
    int lines = 120,
  }) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }
    final safeLines = lines.clamp(20, 500);
    final remoteBase = await _resolveRemoteBase(ssh, strict: false);
    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
LOG="\$BASE/logs/$_logFileName"
if [ -f "\$LOG" ]; then
  tail -n $safeLines "\$LOG"
else
  echo "sidecar log not found: \$LOG"
fi
''',
      ),
      timeout: const Duration(seconds: 20),
    );
    if (!result.isSuccess) {
      throw Exception('사이드카 로그 조회 실패: ${result.output}');
    }
    return result.output;
  }
}
