import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'diagnostics_service.dart';
import 'ssh_service.dart';

class LinkHudService {
  LinkHudService({DiagnosticsService? diagnostics})
      : _diag = diagnostics ?? DiagnosticsService.instance;

  final DiagnosticsService _diag;
  String? _cachedLocalRevision;
  final Map<String, Future<void>> _inFlightEnsureByHost =
      <String, Future<void>>{};
  final Map<String, DateTime> _lastEnsureSucceededAtByHost =
      <String, DateTime>{};

  static const String _sessionName = 'carrotlink_hud';
  static const String _pythonFileName = 'carrot_linkhud.py';
  static const String _runScriptName = 'run_carrot_linkhud.sh';
  static const String _pidFileName = 'carrot_linkhud.pid';
  static const String _logFileName = 'carrot_linkhud.log';
  static const String _revisionFileName = '.carrot_linkhud.rev';
  static const String _sidecarBasePath = '/data/media/0/carrotlink_sidecar';
  static const Duration _recentEnsureCooldown = Duration(seconds: 20);
  static const int defaultPort = 7767;

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
    required String hudPy,
    required String runScript,
  }) {
    final pyHash = _sha256Hex(hudPy);
    final shHash = _sha256Hex(runScript);
    final schema = 'carrot-linkhud-rev-v1\npy=$pyHash\nsh=$shHash\n';
    return _sha256Hex(schema);
  }

  Future<String> localRevision() async {
    final cached = _cachedLocalRevision;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    final py = _toUnixText(
      await rootBundle.loadString('assets/sidecar/carrot_linkhud.py'),
    );
    final sh = _toUnixText(
      await rootBundle.loadString('assets/sidecar/run_carrot_linkhud.sh'),
    );
    final revision = _buildRevisionFromTexts(hudPy: py, runScript: sh);
    _cachedLocalRevision = revision;
    return revision;
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

if [ -z "\$REPO" ] && [ "${strict ? '1' : '0'}" = "1" ]; then
  echo "OPENPILOT_REPO_NOT_FOUND"
  exit 2
fi

BASE="$_sidecarBasePath"
mkdir -p "\$BASE" "\$BASE/logs" >/dev/null 2>&1 || true
if [ ! -d "\$BASE" ]; then
  echo "SIDECAR_BASE_NOT_FOUND"
  exit 3
fi
echo "\$BASE"
''',
      ),
      timeout: const Duration(seconds: 12),
    );
    if (!result.isSuccess) {
      throw Exception('HUD agent 경로 확인 실패: ${result.output}');
    }
    final lines = result.output
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      throw Exception('HUD agent 경로 확인 실패: empty output');
    }
    if (lines.contains('OPENPILOT_REPO_NOT_FOUND')) {
      throw Exception('openpilot repo를 찾지 못했습니다.');
    }
    if (lines.contains('SIDECAR_BASE_NOT_FOUND')) {
      throw Exception('HUD agent 경로를 만들지 못했습니다.');
    }
    final base = lines.lastWhere(
      (e) => e.contains('/'),
      orElse: () => '',
    );
    if (base.isEmpty) {
      throw Exception('HUD agent 경로 확인 실패: invalid output ${result.output}');
    }
    return base;
  }

  Future<String?> remoteRevision(SSHService ssh) async {
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
      throw Exception('HUD agent 리비전 조회 실패: ${result.output}');
    }
    final rev = result.output.trim();
    return rev.isEmpty ? null : rev;
  }

  Future<String> deploy(SSHService ssh) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    final remoteBase = await _resolveRemoteBase(ssh);
    final py = _toUnixText(
      await rootBundle.loadString('assets/sidecar/carrot_linkhud.py'),
    );
    final sh = _toUnixText(
      await rootBundle.loadString('assets/sidecar/run_carrot_linkhud.sh'),
    );
    final revision = _buildRevisionFromTexts(hudPy: py, runScript: sh);

    final mkdir = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
mkdir -p "\$BASE" "\$BASE/logs"
''',
      ),
      timeout: const Duration(seconds: 20),
    );
    if (!mkdir.isSuccess) {
      throw Exception('HUD agent 경로 생성 실패: ${mkdir.output}');
    }

    await ssh.writeTextFile('$remoteBase/$_pythonFileName', py);
    await ssh.writeTextFile('$remoteBase/$_runScriptName', sh);
    await ssh.writeTextFile('$remoteBase/$_revisionFileName', '$revision\n');

    final chmod = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
chmod 755 "\$BASE/$_pythonFileName" "\$BASE/$_runScriptName"
''',
      ),
      timeout: const Duration(seconds: 12),
    );
    if (!chmod.isSuccess) {
      throw Exception('HUD agent 실행 권한 설정 실패: ${chmod.output}');
    }

    _diag.info('linkhud', 'Deploy success base=$remoteBase');
    return remoteBase;
  }

  Future<String> start(
    SSHService ssh, {
    int port = defaultPort,
  }) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    final remoteBase = await _resolveRemoteBase(ssh);
    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
SESSION=${_q(_sessionName)}
PORT=${_q(port.toString())}
PIDFILE="\$BASE/$_pidFileName"
LOGFILE="\$BASE/logs/$_logFileName"
if [ ! -f "\$BASE/$_runScriptName" ] || [ ! -f "\$BASE/$_pythonFileName" ]; then
  echo "HUD_AGENT_NOT_DEPLOYED"
  exit 3
fi

if command -v curl >/dev/null 2>&1; then
  if curl -fsS --max-time 1 "http://127.0.0.1:\$PORT/health" 2>/dev/null | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
    echo "HUD_AGENT_ALREADY_RUNNING port=\$PORT base=\$BASE"
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

port_open() {
  if ! command -v ss >/dev/null 2>&1; then
    return 1
  fi
  ss -ltn 2>/dev/null | awk -v p=":\$PORT" '\$4 ~ (p "\$") { found=1 } END { exit(found ? 0 : 1) }'
}

if command -v tmux >/dev/null 2>&1; then
  tmux has-session -t "\$SESSION" 2>/dev/null && tmux kill-session -t "\$SESSION" || true
fi

if [ -f "\$PIDFILE" ]; then
  OLD_PID=\$(cat "\$PIDFILE" 2>/dev/null || true)
  kill_pid_if_alive "\$OLD_PID"
  rm -f "\$PIDFILE" || true
fi

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

for i in \$(seq 1 12); do
  if ! port_open; then
    break
  fi
  sleep 0.2
done

if command -v tmux >/dev/null 2>&1; then
  tmux new-session -d -s "\$SESSION" "env CARROTLINK_SIDECAR_BASE=\$BASE CARROTLINK_HUD_PORT=\$PORT bash \$BASE/$_runScriptName >> \$LOGFILE 2>&1"
else
  nohup env CARROTLINK_SIDECAR_BASE="\$BASE" CARROTLINK_HUD_PORT="\$PORT" bash "\$BASE/$_runScriptName" >> "\$LOGFILE" 2>&1 &
  NEW_PID=\$!
  if [ -n "\$NEW_PID" ]; then
    echo "\$NEW_PID" > "\$PIDFILE"
  fi
fi

READY=0
if command -v curl >/dev/null 2>&1; then
  for i in \$(seq 1 32); do
    if curl -fsS --max-time 1 "http://127.0.0.1:\$PORT/health" 2>/dev/null | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
      READY=1
      break
    fi
    sleep 0.25
  done
else
  sleep 2
  if port_open; then
    READY=1
  fi
fi

if [ "\$READY" -eq 1 ]; then
  echo "HUD_AGENT_STARTED port=\$PORT base=\$BASE"
else
  echo "HUD_AGENT_START_FAILED"
  if [ -f "\$LOGFILE" ]; then
    tail -n 80 "\$LOGFILE"
  fi
  exit 4
fi
''',
      ),
      timeout: const Duration(seconds: 40),
    );
    if (!result.isSuccess) {
      throw Exception('HUD agent 시작 실패: ${result.output}');
    }
    _diag.info('linkhud', 'Start success output=${result.output}');
    return result.output;
  }

  Future<void> ensureRunning(SSHService ssh) {
    if (!ssh.isConnected) {
      return Future<void>.value();
    }
    final hostKey = (ssh.connectedIp ?? ssh.targetIp ?? 'connected').trim();
    final now = DateTime.now();
    final lastOk = _lastEnsureSucceededAtByHost[hostKey];
    if (lastOk != null && now.difference(lastOk) < _recentEnsureCooldown) {
      return Future<void>.value();
    }
    final inFlight = _inFlightEnsureByHost[hostKey];
    if (inFlight != null) {
      return inFlight;
    }
    final future = _ensureRunningInternal(ssh, hostKey: hostKey);
    _inFlightEnsureByHost[hostKey] = future;
    return future.whenComplete(() {
      if (identical(_inFlightEnsureByHost[hostKey], future)) {
        _inFlightEnsureByHost.remove(hostKey);
      }
    });
  }

  Future<void> _ensureRunningInternal(
    SSHService ssh, {
    required String hostKey,
  }) async {
    final localRev = await localRevision();
    final remoteRev = await remoteRevision(ssh);
    if (remoteRev != localRev) {
      await deploy(ssh);
    }
    try {
      await start(ssh);
      _lastEnsureSucceededAtByHost[hostKey] = DateTime.now();
    } catch (e) {
      final message = e.toString();
      if (!message.contains('HUD_AGENT_NOT_DEPLOYED')) {
        rethrow;
      }
      await deploy(ssh);
      await start(ssh);
      _lastEnsureSucceededAtByHost[hostKey] = DateTime.now();
    }
  }
}
