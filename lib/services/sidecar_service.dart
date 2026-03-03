import 'package:flutter/services.dart';

import 'diagnostics_service.dart';
import 'ssh_service.dart';

class SidecarService {
  SidecarService({DiagnosticsService? diagnostics})
      : _diag = diagnostics ?? DiagnosticsService.instance;

  final DiagnosticsService _diag;

  static const String remoteBase = '/data/media/0/carrotlink_sidecar';
  static const String _sessionName = 'carrotlink_sidecar';
  static const int defaultPort = 7766;

  String _bash(String script) {
    final escaped = script.replaceAll("'", "'\"'\"'");
    return "bash -lc '$escaped'";
  }

  String _q(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  Future<String> deploy(SSHService ssh) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    _diag.info('sidecar', 'Deploy start');
    final py =
        await rootBundle.loadString('assets/sidecar/carrotlink_sidecar.py');
    final sh = await rootBundle.loadString('assets/sidecar/run_sidecar.sh');

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

    await ssh.writeTextFile('$remoteBase/carrotlink_sidecar.py', py);
    await ssh.writeTextFile('$remoteBase/run_sidecar.sh', sh);

    final chmod = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
chmod 755 "\$BASE/run_sidecar.sh" "\$BASE/carrotlink_sidecar.py"
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
    String profile = 'p2',
    int port = defaultPort,
  }) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    final p = profile.trim().toLowerCase();
    if (!{'p0', 'p1', 'p2', 'p3'}.contains(p)) {
      throw Exception('지원하지 않는 프로파일입니다: $profile');
    }

    _diag.info('sidecar', 'Start request profile=$p port=$port');
    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
SESSION=${_q(_sessionName)}
PROFILE=${_q(p)}
PORT=${_q(port.toString())}
if [ ! -f "\$BASE/run_sidecar.sh" ]; then
  echo "SIDECAR_NOT_DEPLOYED"
  exit 3
fi
tmux has-session -t "\$SESSION" 2>/dev/null && tmux kill-session -t "\$SESSION" || true
tmux new-session -d -s "\$SESSION" "bash -lc 'export CARROTLINK_SIDECAR_BASE=\"\$BASE\"; export CARROTLINK_SIDECAR_PROFILE=\"\$PROFILE\"; export CARROTLINK_SIDECAR_PORT=\"\$PORT\"; \"\$BASE/run_sidecar.sh\" >> \"\$BASE/logs/sidecar.log\" 2>&1'"
sleep 1
if tmux has-session -t "\$SESSION" 2>/dev/null; then
  echo "SIDECAR_STARTED"
else
  echo "SIDECAR_START_FAILED"
  exit 4
fi
''',
      ),
      timeout: const Duration(seconds: 40),
    );
    if (!result.isSuccess) {
      throw Exception('사이드카 시작 실패: ${result.output}');
    }
    return result.output.isEmpty ? 'SIDECAR_STARTED' : result.output;
  }

  Future<String> stop(SSHService ssh) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    _diag.info('sidecar', 'Stop request');
    final result = await ssh.executeCommandResult(
      _bash(
        '''
SESSION=${_q(_sessionName)}
if tmux has-session -t "\$SESSION" 2>/dev/null; then
  tmux kill-session -t "\$SESSION"
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
    return result.output;
  }

  Future<String> status(
    SSHService ssh, {
    int port = defaultPort,
  }) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
SESSION=${_q(_sessionName)}
PORT=${_q(port.toString())}
RUNNING=0
LISTEN=0
tmux has-session -t "\$SESSION" 2>/dev/null && RUNNING=1 || true
if command -v ss >/dev/null 2>&1; then
  ss -ltn 2>/dev/null | awk '{print \$4}' | grep -E "[:.]\\\$PORT\$" >/dev/null 2>&1 && LISTEN=1 || true
fi
echo "running=\$RUNNING"
echo "listening=\$LISTEN"
echo "session=\$SESSION"
echo "base=\$BASE"
if [ -f "\$BASE/logs/sidecar.log" ]; then
  echo "log_bytes=\$(wc -c < "\$BASE/logs/sidecar.log" 2>/dev/null || echo 0)"
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
    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
LOG="\$BASE/logs/sidecar.log"
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
