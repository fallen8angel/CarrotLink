import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'diagnostics_service.dart';
import 'ssh_service.dart';

class SidecarService {
  SidecarService({DiagnosticsService? diagnostics})
      : _diag = diagnostics ?? DiagnosticsService.instance;

  final DiagnosticsService _diag;
  String? _cachedLocalRevision;

  static const String _sessionName = 'carrotlink_view';
  static const String _pythonFileName = 'carrot_linkview.py';
  static const String _runScriptName = 'run_carrot_linkview.sh';
  static const String _pidFileName = 'sidecar.pid';
  static const String _logFileName = 'carrot_linkview.log';
  static const String _managedProcessName = 'carrot_linkview';
  static const String _revisionFileName = '.carrot_linkview.rev';
  static const String _defaultProfile = 'p2';
  static const Set<String> _supportedProfiles = <String>{
    'p0',
    'p1',
    'p2',
    'p3',
    'p4',
  };
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

  String _sha256Hex(String input) {
    final bytes = Uint8List.fromList(utf8.encode(input));
    final digest = SHA256Digest().process(bytes);
    final sb = StringBuffer();
    for (final b in digest) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  String _buildRevisionFromTexts({
    required String sidecarPy,
    required String runScript,
  }) {
    final pyHash = _sha256Hex(sidecarPy);
    final shHash = _sha256Hex(runScript);
    // Keep deterministic schema for future migrations.
    final schema = 'carrotlink-sidecar-rev-v1\npy=$pyHash\nsh=$shHash\n';
    return _sha256Hex(schema);
  }

  String shortRevision(String? revision, {int length = 12}) {
    final v = (revision ?? '').trim();
    if (v.isEmpty) return '-';
    return v.length <= length ? v : v.substring(0, length);
  }

  Future<String> localRevision() async {
    final cached = _cachedLocalRevision;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    final py = _toUnixText(
      await rootBundle.loadString('assets/sidecar/carrotlink_sidecar.py'),
    );
    final sh = _toUnixText(
      await rootBundle.loadString('assets/sidecar/run_sidecar.sh'),
    );
    final revision = _buildRevisionFromTexts(sidecarPy: py, runScript: sh);
    _cachedLocalRevision = revision;
    return revision;
  }

  Future<String?> remoteRevision(SSHService ssh) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }
    final remoteBase = await _resolveRemoteBase(ssh, strict: false);
    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
REV_FILE="\$BASE/$_revisionFileName"
if [ -f "\$REV_FILE" ]; then
  tr -d '\r' < "\$REV_FILE" | head -n 1
fi
''',
      ),
      timeout: const Duration(seconds: 8),
    );
    if (!result.isSuccess) {
      throw Exception('사이드카 리비전 조회 실패: ${result.output}');
    }
    final rev = result.output.trim();
    if (rev.isEmpty) return null;
    return rev;
  }

  Future<String> _resolveRemoteBase(
    SSHService ssh, {
    bool strict = true,
  }) async {
    final result = await ssh.executeCommandResult(
      _bash(
        '''
REPO=""
for d in /data/openpilot /home/comma/openpilot /data/media/0/openpilot /data/openpilot_source/openpilot; do
  if [ -d "\$d/selfdrive" ] && { [ -d "\$d/.git" ] || [ -f "\$d/launch_openpilot.sh" ] || [ -d "\$d/system" ]; }; then
    REPO="\$d"
    break
  fi
done

# Fallback scan for uncommon layouts.
if [ -z "\$REPO" ]; then
  for root in /data /home/comma /data/media/0; do
    if [ -d "\$root" ]; then
      FOUND=\$(find "\$root" -maxdepth 3 -type d -name openpilot 2>/dev/null | head -n 1 || true)
      if [ -n "\$FOUND" ] && [ -d "\$FOUND/selfdrive" ]; then
        REPO="\$FOUND"
        break
      fi
    fi
  done
fi

if [ -z "\$REPO" ]; then
  if [ "${strict ? '1' : '0'}" = "1" ]; then
    echo "OPENPILOT_REPO_NOT_FOUND"
    exit 2
  fi
  REPO="/data/openpilot"
fi

BASE="\$REPO/selfdrive/carrot"
mkdir -p "\$BASE" >/dev/null 2>&1 || true
if [ ! -d "\$BASE" ]; then
  if [ "${strict ? '1' : '0'}" = "1" ]; then
    echo "CARROT_BASE_NOT_FOUND"
    exit 3
  fi
  BASE="/data/openpilot/selfdrive/carrot"
fi
if [ "${strict ? '1' : '0'}" = "1" ] && [ ! -f "\$REPO/selfdrive/carrot/carrot_server.py" ]; then
  # carrotpilot 미탑재 기기라도 사이드카 배포는 허용하되, 진단에는 힌트를 남긴다.
  echo "CARROT_SERVER_MISSING_WARN"
fi
echo "\$BASE"
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
    if (lines.contains('OPENPILOT_REPO_NOT_FOUND')) {
      throw Exception('openpilot repo를 찾지 못했습니다.');
    }
    if (lines.contains('CARROT_BASE_NOT_FOUND')) {
      throw Exception('selfdrive/carrot 경로를 만들지 못했습니다.');
    }
    final base = lines.lastWhere(
      (e) => e.contains('/'),
      orElse: () => '',
    );
    if (base.isEmpty) {
      throw Exception('사이드카 경로 확인 실패: invalid output ${result.output}');
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
    final revision = _buildRevisionFromTexts(sidecarPy: py, runScript: sh);

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
    await ssh.writeTextFile('$remoteBase/$_revisionFileName', '$revision\n');

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

    final ensureManaged = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
REPO=\$(dirname "\$(dirname "\$BASE")")
CFG="\$REPO/system/manager/process_config.py"
if [ ! -f "\$CFG" ]; then
  echo "PROCESS_CONFIG_MISSING=\$CFG"
  exit 6
fi

python3 - "\$CFG" <<'PY'
import pathlib, sys

cfg = pathlib.Path(sys.argv[1])
needle = 'PythonProcess("$_managedProcessName", "selfdrive.carrot.carrot_linkview", always_run),'
text = cfg.read_text()

if f'PythonProcess("$_managedProcessName"' in text:
  print("MANAGED_PROC_ALREADY")
  raise SystemExit(0)

insert_line = f'  {needle}\\n'
anchor = 'PythonProcess("carrot_server", "selfdrive.carrot.carrot_server", always_run),'
if anchor in text:
  text = text.replace(anchor, anchor + '\\n' + insert_line.rstrip('\\n'), 1)
else:
  marker = '\\n]\\n\\nmanaged_processes'
  if marker in text:
    text = text.replace(marker, '\\n' + insert_line + ']\\n\\nmanaged_processes', 1)
  else:
    raise SystemExit("PROCESS_CONFIG_FORMAT_UNSUPPORTED")

cfg.write_text(text)
print("MANAGED_PROC_INSTALLED")
PY
''',
      ),
      timeout: const Duration(seconds: 25),
    );
    if (!ensureManaged.isSuccess) {
      throw Exception('매니저 프로세스 등록 실패: ${ensureManaged.output}');
    }

    _diag.info('sidecar', 'Deploy success managed=${ensureManaged.output}');
    final managedSummary = ensureManaged.output
        .split('\n')
        .map((e) => e.trim())
        .where((e) =>
            e.startsWith('MANAGED_PROC_') ||
            e.startsWith('PROCESS_CONFIG_') ||
            e.startsWith('PROCESS_CONFIG_FORMAT_'))
        .join(' ');
    if (managedSummary.isNotEmpty) {
      return '배포 완료: $remoteBase ($managedSummary, rev=${shortRevision(revision)})';
    }
    return '배포 완료: $remoteBase (rev=${shortRevision(revision)})';
  }

  Future<String> start(
    SSHService ssh, {
    int port = defaultPort,
    String profile = _defaultProfile,
  }) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    final remoteBase = await _resolveRemoteBase(ssh);
    final normalizedProfile =
        _supportedProfiles.contains(profile) ? profile : _defaultProfile;
    _diag.info(
      'sidecar',
      'Start request profile=$normalizedProfile port=$port',
    );
    final result = await ssh.executeCommandResult(
      _bash(
        // ignore: unnecessary_string_escapes
        '''
BASE=${_q(remoteBase)}
SESSION=${_q(_sessionName)}
PROFILE=${_q(normalizedProfile)}
PORT=${_q(port.toString())}
PIDFILE="\$BASE/$_pidFileName"
LOGFILE="\$BASE/logs/$_logFileName"
if [ ! -f "\$BASE/$_runScriptName" ] || [ ! -f "\$BASE/$_pythonFileName" ]; then
  echo "SIDECAR_NOT_DEPLOYED"
  exit 3
fi

# Idempotent start: if healthy sidecar is already up, reuse it.
if command -v curl >/dev/null 2>&1; then
  if curl -fsS --max-time 1 "http://127.0.0.1:\$PORT/health" 2>/dev/null | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
    echo "SIDECAR_ALREADY_RUNNING profile=\$PROFILE port=\$PORT base=\$BASE"
    exit 0
  fi
fi

kill_pid_if_alive() {
  KP="\$1"
  if [ -n "\$KP" ] && kill -0 "\$KP" 2>/dev/null; then
    kill "\$KP" 2>/dev/null || true
    sleep 0.15
    if kill -0 "\$KP" 2>/dev/null; then
      kill -9 "\$KP" 2>/dev/null || true
    fi
  fi
}

if command -v tmux >/dev/null 2>&1; then
  tmux has-session -t "\$SESSION" 2>/dev/null && tmux kill-session -t "\$SESSION" || true
fi

if [ -f "\$PIDFILE" ]; then
  OLD_PID=\$(cat "\$PIDFILE" 2>/dev/null || true)
  kill_pid_if_alive "\$OLD_PID"
  rm -f "\$PIDFILE" || true
fi

for PATTERN in "$_pythonFileName" "$_runScriptName"; do
  PIDS=\$(ps -eo pid,args 2>/dev/null | grep -F "\$PATTERN" | grep -v grep | awk '{print \$1}' | sort -u || true)
  for P in \$PIDS; do
    kill_pid_if_alive "\$P"
  done
done

if command -v ss >/dev/null 2>&1; then
  PORT_PIDS=\$(ss -ltnp 2>/dev/null | awk -v p=":\$PORT" '
    \$4 ~ (p "\$") {
      if (match(\$0, /pid=[0-9]+/)) {
        print substr(\$0, RSTART + 4, RLENGTH - 4)
      }
    }' | sort -u || true)
  for P in \$PORT_PIDS; do
    kill_pid_if_alive "\$P"
  done
fi

for i in \$(seq 1 15); do
  BUSY=0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print \$4}' | grep -E "[:.]\\\$PORT\$" >/dev/null 2>&1 && BUSY=1 || true
  fi
  if [ "\$BUSY" -eq 0 ]; then
    break
  fi
  sleep 0.2
done

if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | awk '{print \$4}' | grep -E "[:.]\\\$PORT\$" >/dev/null 2>&1; then
    echo "PORT_IN_USE_BEFORE_START=\$PORT"
    ss -ltnp 2>/dev/null | grep -E "[:.]\\\$PORT\\b" || true
    exit 5
  fi
fi

if command -v tmux >/dev/null 2>&1; then
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
      _diag.warn('sidecar', 'Start failed output=${result.output}');
      throw Exception('사이드카 시작 실패: ${result.output}');
    }
    _diag.info('sidecar', 'Start success output=${result.output}');
    return result.output.isEmpty ? 'SIDECAR_STARTED' : result.output;
  }

  Future<String> stop(
    SSHService ssh, {
    int port = defaultPort,
  }) async {
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
PORT=${_q(port.toString())}
PIDFILE="\$BASE/$_pidFileName"
STOPPED=0

kill_pid_if_alive() {
  KP="\$1"
  if [ -n "\$KP" ] && kill -0 "\$KP" 2>/dev/null; then
    kill "\$KP" 2>/dev/null || true
    sleep 0.15
    if kill -0 "\$KP" 2>/dev/null; then
      kill -9 "\$KP" 2>/dev/null || true
    fi
  fi
}

if command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t "\$SESSION" 2>/dev/null; then
    tmux kill-session -t "\$SESSION" || true
    STOPPED=1
  fi
fi
if [ -f "\$PIDFILE" ]; then
  PID=\$(cat "\$PIDFILE" 2>/dev/null || true)
  if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
    kill_pid_if_alive "\$PID"
    STOPPED=1
  fi
  rm -f "\$PIDFILE" || true
fi

for PATTERN in "$_pythonFileName" "$_runScriptName"; do
  PIDS=\$(ps -eo pid,args 2>/dev/null | grep -F "\$PATTERN" | grep -v grep | awk '{print \$1}' | sort -u || true)
  for P in \$PIDS; do
    kill_pid_if_alive "\$P"
    STOPPED=1
  done
done

if command -v ss >/dev/null 2>&1; then
  PORT_PIDS=\$(ss -ltnp 2>/dev/null | awk -v p=":\$PORT" '
    \$4 ~ (p "\$") {
      if (match(\$0, /pid=[0-9]+/)) {
        print substr(\$0, RSTART + 4, RLENGTH - 4)
      }
    }' | sort -u || true)
  for P in \$PORT_PIDS; do
    kill_pid_if_alive "\$P"
    STOPPED=1
  done
fi

for i in \$(seq 1 20); do
  BUSY=0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print \$4}' | grep -E "[:.]\\\$PORT\$" >/dev/null 2>&1 && BUSY=1 || true
  fi
  if [ "\$BUSY" -eq 0 ]; then
    break
  fi
  sleep 0.2
done

LISTEN=0
if command -v ss >/dev/null 2>&1; then
  ss -ltn 2>/dev/null | awk '{print \$4}' | grep -E "[:.]\\\$PORT\$" >/dev/null 2>&1 && LISTEN=1 || true
fi
if [ "\$STOPPED" -eq 1 ]; then
  echo "SIDECAR_STOPPED"
else
  echo "SIDECAR_NOT_RUNNING"
fi
echo "port_open=\$LISTEN"
''',
      ),
      timeout: const Duration(seconds: 15),
    );
    if (!result.isSuccess) {
      throw Exception('사이드카 중지 실패: ${result.output}');
    }
    _diag.info('sidecar', 'Stop output=${result.output}');
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
PORT_PIDS=""
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
  PORT_PIDS=\$(ss -ltnp 2>/dev/null | awk -v p=":\$PORT" '
    \$4 ~ (p "\$") {
      if (match(\$0, /pid=[0-9]+/)) {
        print substr(\$0, RSTART + 4, RLENGTH - 4)
      }
    }' | sort -u | tr '\n' ',' | sed 's/,\$//' || true)
fi
if [ "\$RUNNING" -eq 0 ] && [ "\$LISTEN" -eq 1 ]; then
  RUNNING=1
  METHOD="port_orphan"
fi
echo "running=\$RUNNING"
echo "listening=\$LISTEN"
echo "method=\$METHOD"
echo "port_pids=\$PORT_PIDS"
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

  Future<String> resetForTesting(
    SSHService ssh, {
    int port = defaultPort,
    bool removeManagerRegistration = true,
  }) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    // Best-effort stop first; continue even when stop fails.
    try {
      await stop(ssh, port: port);
    } catch (_) {}

    final remoteBase = await _resolveRemoteBase(ssh, strict: false);
    final removeRegistrationFlag = removeManagerRegistration ? '1' : '0';
    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
PORT=${_q(port.toString())}
REPO=\$(dirname "\$(dirname "\$BASE")")
CFG="\$REPO/system/manager/process_config.py"

# Remove current and legacy sidecar artifacts
rm -f "\$BASE/$_pythonFileName" "\$BASE/$_runScriptName" "\$BASE/$_revisionFileName" "\$BASE/$_pidFileName" "\$BASE/logs/$_logFileName" "\$BASE/carrotlink_sidecar.py" "\$BASE/run_sidecar.sh" "\$BASE/logs/sidecar.log"

# Cleanup any lingering listeners
if command -v ss >/dev/null 2>&1; then
  PORT_PIDS=\$(ss -ltnp 2>/dev/null | awk -v p=":\$PORT" '
    \$4 ~ (p "\$") {
      if (match(\$0, /pid=[0-9]+/)) {
        print substr(\$0, RSTART + 4, RLENGTH - 4)
      }
    }' | sort -u || true)
  for P in \$PORT_PIDS; do
    kill "\$P" 2>/dev/null || true
    sleep 0.1
    kill -9 "\$P" 2>/dev/null || true
  done
fi

REMOVED_CFG=0
if [ "$removeRegistrationFlag" = "1" ] && [ -f "\$CFG" ]; then
python3 - "\$CFG" <<'PY'
import pathlib, sys
cfg = pathlib.Path(sys.argv[1])
lines = cfg.read_text().splitlines()
needle_name = 'PythonProcess("$_managedProcessName"'
needle_module = 'selfdrive.carrot.carrot_linkview'
out = []
removed = 0
for line in lines:
  if removed == 0 and needle_name in line and needle_module in line:
    removed = 1
    continue
  out.append(line)
if removed:
  cfg.write_text("\\n".join(out) + "\\n")
print(f"removed={removed}")
PY
  REMOVED_CFG=1
fi

echo "SIDECAR_RESET_DONE base=\$BASE repo=\$REPO cfg_removed=\$REMOVED_CFG"
''',
      ),
      timeout: const Duration(seconds: 40),
    );
    if (!result.isSuccess) {
      throw Exception('사이드카 테스트 초기화 실패: ${result.output}');
    }
    return result.output;
  }
}
