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
  final Map<String, Future<void>> _inFlightEnsureByHost =
      <String, Future<void>>{};
  final Map<String, DateTime> _lastEnsureSucceededAtByHost =
      <String, DateTime>{};
  static final Map<String, DateTime> _lastLegacyCleanupAttemptAtByHost =
      <String, DateTime>{};

  static const String _sessionName = 'carrotlink_view';
  static const String _pythonFileName = 'sidecar.py';
  static const String _runScriptName = 'sidecar.sh';
  static const String _pidFileName = 'sidecar.pid';
  static const String _logFileName = 'sidecar.log';
  static const String _revisionFileName = '.sidecar.rev';
  static const String _legacyCleanupMarkerName = '.sidecar.legacy_cleanup_v2';
  static const String _legacyPythonFileName = 'carrot_linkview.py';
  static const String _legacyRunScriptName = 'run_carrot_linkview.sh';
  static const String _olderLegacyPythonFileName = 'carrotlink_sidecar.py';
  static const String _olderLegacyRunScriptName = 'run_sidecar.sh';
  static const String _legacyLogFileName = 'carrot_linkview.log';
  static const String _legacyRevisionFileName = '.carrot_linkview.rev';
  static const String _managedFolderName = 'carrotlink';
  static const String _legacyRepoFolderName = 'carrot';
  static const String _legacySidecarBasePath =
      '/data/media/0/carrotlink_sidecar';
  static const String _legacyManagedModule = 'selfdrive.carrot.carrot_linkview';
  static const String _defaultProfile = 'p2';
  static const Set<String> _supportedProfiles = <String>{
    'p0',
    'p1',
    'p2',
    'p3',
    'p4',
  };
  static const int defaultPort = 7766;
  static const Duration _recentEnsureCooldown = Duration(seconds: 20);
  static const Duration _legacyCleanupCooldown = Duration(seconds: 45);
  static const bool _autoLegacyCleanupEnabled = false;

  Future<bool> _isHealthy(SSHService ssh) async {
    final result = await ssh.executeCommandResult(
      _bash(
        '''
SIDE_PORT=${_q(defaultPort.toString())}
check_sidecar() {
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi
  curl -fsS --max-time 1 "http://127.0.0.1:\$SIDE_PORT/health" 2>/dev/null | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' &&
    curl -fsS --max-time 1 "http://127.0.0.1:\$SIDE_PORT/health" 2>/dev/null | grep -Fq '"kind":"carrotlink_sidecar_broker_v1"'
}
if check_sidecar; then
  echo "SIDECAR_HEALTH_OK"
else
  echo "SIDECAR_HEALTH_BAD"
fi
''',
      ),
      timeout: const Duration(seconds: 6),
    );
    if (!result.isSuccess) {
      return false;
    }
    return result.output.contains('SIDECAR_HEALTH_OK');
  }

  String _bash(String script) {
    final normalized = _dedentShellScript(_toUnixText(script));
    final escaped = normalized.replaceAll("'", "'\"'\"'");
    return "bash -lc '$escaped'";
  }

  String _q(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  String _toUnixText(String input) {
    return input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  String _dedentShellScript(String input) {
    final lines = input.split('\n');
    var minIndent = 1 << 30;
    for (final line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }
      final indent = line.length - line.trimLeft().length;
      if (indent < minIndent) {
        minIndent = indent;
      }
    }
    if (minIndent == 1 << 30 || minIndent == 0) {
      return input;
    }
    return lines.map((line) {
      if (line.trim().isEmpty) {
        return '';
      }
      return line.length >= minIndent ? line.substring(minIndent) : line;
    }).join('\n');
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
    final schema =
        'carrotlink-sidecar-rev-v4\npy=$pyHash\nsh=$shHash\n';
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
      await rootBundle.loadString('assets/sidecar/sidecar.py'),
    );
    final sh = _toUnixText(
      await rootBundle.loadString('assets/sidecar/sidecar.sh'),
    );
    final revision = _buildRevisionFromTexts(
      sidecarPy: py,
      runScript: sh,
    );
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

  Future<void> ensureRunning(SSHService ssh) {
    if (!ssh.isConnected) {
      return Future<void>.value();
    }
    final hostKey = (ssh.connectedIp ?? ssh.targetIp ?? 'connected').trim();
    final inFlight = _inFlightEnsureByHost[hostKey];
    if (inFlight != null) {
      return inFlight;
    }
    final now = DateTime.now();
    final lastOk = _lastEnsureSucceededAtByHost[hostKey];
    if (lastOk != null && now.difference(lastOk) < _recentEnsureCooldown) {
      final future = _isHealthy(ssh).then<Future<void>>((healthy) {
        if (healthy) {
          return Future<void>.value();
        }
        return _ensureRunningInternal(ssh, hostKey: hostKey);
      }).then((_) {});
      _inFlightEnsureByHost[hostKey] = future;
      return future.whenComplete(() {
        if (identical(_inFlightEnsureByHost[hostKey], future)) {
          _inFlightEnsureByHost.remove(hostKey);
        }
      });
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
    // Always check revision even if healthy — a running old sidecar must be
    // replaced when our bundled assets have changed.
    final localRev = await localRevision();
    final remoteRev = await remoteRevision(ssh).catchError((_) => null);
    final revisionMatch = remoteRev != null && remoteRev == localRev;

    if (revisionMatch && await _isHealthy(ssh)) {
      _lastEnsureSucceededAtByHost[hostKey] = DateTime.now();
      return;
    }

    if (!revisionMatch) {
      _diag.info(
        'sidecar',
        'Revision mismatch local=${shortRevision(localRev)} '
            'remote=${shortRevision(remoteRev ?? "-")} — stop+deploy+start',
      );
      try {
        await stop(ssh);
      } catch (_) {}
      await deploy(ssh);
      await start(ssh);
      _lastEnsureSucceededAtByHost[hostKey] = DateTime.now();
      return;
    }

    try {
      await start(ssh);
      _lastEnsureSucceededAtByHost[hostKey] = DateTime.now();
      return;
    } catch (e) {
      final message = e.toString();
      if (message.contains('SIDECAR_ARTIFACTS_NOT_DEPLOYED') ||
          message.contains('SIDECAR_NOT_DEPLOYED')) {
        await deploy(ssh);
        await start(ssh);
        _lastEnsureSucceededAtByHost[hostKey] = DateTime.now();
        return;
      }
      rethrow;
    }
  }

  Future<void> _maybeCleanupLegacyInstall(
    SSHService ssh, {
    bool force = false,
  }) async {
    if (!_autoLegacyCleanupEnabled && !force) {
      return;
    }
    final hostKey = (ssh.connectedIp ?? ssh.targetIp ?? 'connected').trim();
    if (!force) {
      final lastAttempt = _lastLegacyCleanupAttemptAtByHost[hostKey];
      if (lastAttempt != null &&
          DateTime.now().difference(lastAttempt) < _legacyCleanupCooldown) {
        return;
      }
    }
    _lastLegacyCleanupAttemptAtByHost[hostKey] = DateTime.now();
    try {
      final output = await cleanupLegacyInstall(ssh, force: force);
      final trimmed = output.trim();
      if (trimmed.isEmpty || trimmed.contains('LEGACY_CLEANUP_ALREADY_DONE')) {
        return;
      }
      final summary = trimmed
          .split('\n')
          .map((e) => e.trim())
          .where((e) =>
              e.startsWith('LEGACY_CLEANUP_') ||
              e.startsWith('repo=') ||
              e.startsWith('new_base=') ||
              e.startsWith('legacy_base=') ||
              e.startsWith('cfg_removed=') ||
              e.startsWith('legacy_files_removed=') ||
              e.startsWith('legacy_runtime_killed='))
          .join(' ');
      if (summary.isNotEmpty) {
        _diag.info('sidecar', 'Legacy cleanup $summary');
      }
    } catch (e) {
      _diag.warn('sidecar', 'Legacy cleanup skipped/fail: $e');
    }
  }

  Future<String> cleanupLegacyInstall(
    SSHService ssh, {
    bool force = false,
  }) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    final remoteBase = await _resolveRemoteBase(ssh, strict: false);
    final repoRoot = _repoRootFromBase(remoteBase);
    final probePaths = _sidecarLegacyProbePaths(repoRoot);
    final removalPaths = _sidecarLegacyRemovalPaths(repoRoot);
    final runtimePatterns = _sidecarLegacyRuntimePatterns(repoRoot);
    final pathProbeExpr = probePaths.isEmpty
        ? 'false'
        : probePaths.map((path) => '[ -e ${_q(path)} ]').join(' || ');
    final processProbeBlocks = runtimePatterns
        .map(
          (pattern) => '''
if ps -eo pid=,args= 2>/dev/null | awk -v pat=${_q(pattern)} 'index(\$0, pat) { found=1 } END { exit(found ? 0 : 1) }'; then
  NEED_CLEAN=1
fi
''',
        )
        .join('\n');
    final removalBlocks = removalPaths
        .map(
          (path) => '''
if [ -e ${_q(path)} ]; then
  rm -rf -- ${_q(path)} 2>/dev/null || true
  FILES_REMOVED=1
fi
''',
        )
        .join('\n');
    final killPatternBlocks = runtimePatterns
        .map((pattern) => 'kill_pattern ${_q(pattern)}')
        .join('\n');
    final configBlock = repoRoot == null
        ? ''
        : '''
CFG=${_q('$repoRoot/system/manager/process_config.py')}
if [ -f "\$CFG" ] && command -v python3 >/dev/null 2>&1; then
  PY_OUT=\$(python3 -c ${_q(_sidecarProcessConfigCleanupPy())} "\$CFG" 2>&1 || true)
  case "\$PY_OUT" in
    *cfg_removed=1*) CFG_REMOVED=1 ;;
  esac
  if [ -n "\$PY_OUT" ]; then
    echo "\$PY_OUT"
  fi
fi
''';
    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
MARKER="\$BASE/$_legacyCleanupMarkerName"
FORCE=${force ? '1' : '0'}
LEGACY_BASE="$_legacySidecarBasePath"
REPO=${_q(repoRoot ?? '')}
NEW_BASE=${_q(remoteBase)}

if [ "\$FORCE" != "1" ] && [ -f "\$MARKER" ]; then
  NEED_CLEAN=0
  if $pathProbeExpr; then
    NEED_CLEAN=1
  fi

  if [ "\$NEED_CLEAN" != "1" ] && [ -n "\$REPO" ]; then
    CFG=${_q(repoRoot == null ? '' : '$repoRoot/system/manager/process_config.py')}
    if [ -f "\$CFG" ] && grep -Fq ${_q(_legacyManagedModule)} "\$CFG" 2>/dev/null; then
      NEED_CLEAN=1
    fi
  fi

  if [ "\$NEED_CLEAN" != "1" ]; then
    $processProbeBlocks
  fi

  if [ "\$NEED_CLEAN" != "1" ]; then
    echo "LEGACY_CLEANUP_ALREADY_DONE"
    echo "repo=\$REPO"
    echo "new_base=\$NEW_BASE"
    echo "legacy_base=\$LEGACY_BASE"
    exit 0
  fi
fi

CFG_REMOVED=0
FILES_REMOVED=0
RUNTIME_KILLED=0

kill_pid_if_alive() {
  KP="\$1"
  if [ -n "\$KP" ] && kill -0 "\$KP" 2>/dev/null; then
    kill "\$KP" 2>/dev/null || true
    sleep 0.15
    if kill -0 "\$KP" 2>/dev/null; then
      kill -9 "\$KP" 2>/dev/null || true
    fi
    RUNTIME_KILLED=1
  fi
}

kill_pattern() {
  PATTERN="\$1"
  PIDS=\$(ps -eo pid=,args= 2>/dev/null | awk -v pat="\$PATTERN" 'index(\$0, pat) { print \$1 }' | sort -u || true)
  for P in \$PIDS; do
    kill_pid_if_alive "\$P"
  done
}

$configBlock

$removalBlocks

$killPatternBlocks

# When openpilot repo exists and the managed install has moved to
# selfdrive/carrotlink, remove the obsolete legacy base directory itself.
if [ -n "\$REPO" ] && [ "\$NEW_BASE" != "\$LEGACY_BASE" ] && [ -d "\$LEGACY_BASE" ]; then
  rm -rf "\$LEGACY_BASE" 2>/dev/null || true
  if [ ! -d "\$LEGACY_BASE" ]; then
    FILES_REMOVED=1
  fi
fi

if command -v tmux >/dev/null 2>&1; then
  tmux has-session -t "$_sessionName" 2>/dev/null && tmux kill-session -t "$_sessionName" || true
  tmux has-session -t "carrotlink_camera" 2>/dev/null && tmux kill-session -t "carrotlink_camera" || true
  tmux has-session -t "carrotlink_diag" 2>/dev/null && tmux kill-session -t "carrotlink_diag" || true
fi

mkdir -p "\$BASE" >/dev/null 2>&1 || true
date +%s > "\$MARKER" 2>/dev/null || true
echo "LEGACY_CLEANUP_DONE"
echo "repo=\$REPO"
echo "new_base=\$NEW_BASE"
echo "legacy_base=\$LEGACY_BASE"
echo "cfg_removed=\$CFG_REMOVED"
echo "legacy_files_removed=\$FILES_REMOVED"
echo "legacy_runtime_killed=\$RUNTIME_KILLED"
''',
      ),
      timeout: const Duration(seconds: 45),
    );
    if (!result.isSuccess) {
      throw Exception(
        'legacy cleanup 실패(exit=${result.exitCode} base=$remoteBase): ${result.output}',
      );
    }
    return result.output;
  }

  String? _repoRootFromBase(String remoteBase) {
    const suffix = '/selfdrive/$_managedFolderName';
    if (!remoteBase.endsWith(suffix)) {
      return null;
    }
    return remoteBase.substring(0, remoteBase.length - suffix.length);
  }

  List<String> _sidecarLegacyProbePaths(String? repoRoot) {
    final paths = <String>[
      '$_legacySidecarBasePath/$_pythonFileName',
      '$_legacySidecarBasePath/$_runScriptName',
      '$_legacySidecarBasePath/camera.py',
      '$_legacySidecarBasePath/camera.sh',
      '$_legacySidecarBasePath/diag.py',
      '$_legacySidecarBasePath/diag.sh',
      '$_legacySidecarBasePath/$_legacyPythonFileName',
      '$_legacySidecarBasePath/$_legacyRunScriptName',
      '$_legacySidecarBasePath/$_olderLegacyPythonFileName',
      '$_legacySidecarBasePath/$_olderLegacyRunScriptName',
      '$_legacySidecarBasePath/$_legacyRevisionFileName',
      '$_legacySidecarBasePath/logs/$_legacyLogFileName',
    ];
    if (repoRoot != null) {
      final legacyRepoBase = '$repoRoot/selfdrive/$_legacyRepoFolderName';
      final managedBase = '$repoRoot/selfdrive/$_managedFolderName';
      paths.addAll(<String>[
        '$legacyRepoBase/$_pythonFileName',
        '$legacyRepoBase/$_runScriptName',
        '$legacyRepoBase/camera.py',
        '$legacyRepoBase/camera.sh',
        '$legacyRepoBase/diag.py',
        '$legacyRepoBase/diag.sh',
        '$legacyRepoBase/$_legacyPythonFileName',
        '$legacyRepoBase/$_legacyRunScriptName',
        '$legacyRepoBase/$_olderLegacyPythonFileName',
        '$legacyRepoBase/$_olderLegacyRunScriptName',
        '$managedBase/$_legacyPythonFileName',
        '$managedBase/$_legacyRunScriptName',
        '$managedBase/$_olderLegacyPythonFileName',
        '$managedBase/$_olderLegacyRunScriptName',
        '$managedBase/$_legacyRevisionFileName',
        '$managedBase/logs/$_legacyLogFileName',
      ]);
    }
    return paths;
  }

  List<String> _sidecarLegacyRemovalPaths(String? repoRoot) {
    final paths = <String>[
      '$_legacySidecarBasePath/$_pythonFileName',
      '$_legacySidecarBasePath/$_runScriptName',
      '$_legacySidecarBasePath/$_legacyPythonFileName',
      '$_legacySidecarBasePath/$_legacyRunScriptName',
      '$_legacySidecarBasePath/$_olderLegacyPythonFileName',
      '$_legacySidecarBasePath/$_olderLegacyRunScriptName',
      '$_legacySidecarBasePath/$_revisionFileName',
      '$_legacySidecarBasePath/.camera.rev',
      '$_legacySidecarBasePath/.diag.rev',
      '$_legacySidecarBasePath/$_legacyRevisionFileName',
      '$_legacySidecarBasePath/$_pidFileName',
      '$_legacySidecarBasePath/camera.pid',
      '$_legacySidecarBasePath/diag.pid',
      '$_legacySidecarBasePath/logs/$_logFileName',
      '$_legacySidecarBasePath/camera.py',
      '$_legacySidecarBasePath/camera.sh',
      '$_legacySidecarBasePath/diag.py',
      '$_legacySidecarBasePath/diag.sh',
      '$_legacySidecarBasePath/diag_snapshot.json',
      '$_legacySidecarBasePath/logs/camera.log',
      '$_legacySidecarBasePath/logs/diag.log',
      '$_legacySidecarBasePath/logs/$_legacyLogFileName',
    ];
    if (repoRoot != null) {
      final legacyRepoBase = '$repoRoot/selfdrive/$_legacyRepoFolderName';
      final managedBase = '$repoRoot/selfdrive/$_managedFolderName';
      paths.addAll(<String>[
        '$legacyRepoBase/$_pythonFileName',
        '$legacyRepoBase/$_runScriptName',
        '$legacyRepoBase/$_revisionFileName',
        '$legacyRepoBase/.camera.rev',
        '$legacyRepoBase/.diag.rev',
        '$legacyRepoBase/$_pidFileName',
        '$legacyRepoBase/camera.pid',
        '$legacyRepoBase/diag.pid',
        '$legacyRepoBase/logs/$_logFileName',
        '$legacyRepoBase/camera.py',
        '$legacyRepoBase/camera.sh',
        '$legacyRepoBase/diag.py',
        '$legacyRepoBase/diag.sh',
        '$legacyRepoBase/diag_snapshot.json',
        '$legacyRepoBase/logs/camera.log',
        '$legacyRepoBase/logs/diag.log',
        '$legacyRepoBase/$_legacyPythonFileName',
        '$legacyRepoBase/$_legacyRunScriptName',
        '$legacyRepoBase/$_olderLegacyPythonFileName',
        '$legacyRepoBase/$_olderLegacyRunScriptName',
        '$legacyRepoBase/$_legacyRevisionFileName',
        '$legacyRepoBase/logs/$_legacyLogFileName',
        '$managedBase/$_legacyPythonFileName',
        '$managedBase/$_legacyRunScriptName',
        '$managedBase/$_olderLegacyPythonFileName',
        '$managedBase/$_olderLegacyRunScriptName',
        '$managedBase/$_legacyRevisionFileName',
        '$managedBase/logs/$_legacyLogFileName',
      ]);
    }
    return paths;
  }

  List<String> _sidecarLegacyRuntimePatterns(String? repoRoot) {
    final patterns = <String>[
      _legacyManagedModule,
      '$_legacySidecarBasePath/$_legacyPythonFileName',
      '$_legacySidecarBasePath/$_olderLegacyPythonFileName',
      '$_legacySidecarBasePath/$_legacyRunScriptName',
      '$_legacySidecarBasePath/$_olderLegacyRunScriptName',
      '$_legacySidecarBasePath/$_pythonFileName',
      '$_legacySidecarBasePath/camera.py',
      '$_legacySidecarBasePath/diag.py',
      '$_legacySidecarBasePath/$_runScriptName',
      '$_legacySidecarBasePath/camera.sh',
      '$_legacySidecarBasePath/diag.sh',
    ];
    if (repoRoot != null) {
      final legacyRepoBase = '$repoRoot/selfdrive/$_legacyRepoFolderName';
      final managedBase = '$repoRoot/selfdrive/$_managedFolderName';
      patterns.addAll(<String>[
        '$legacyRepoBase/$_pythonFileName',
        '$legacyRepoBase/camera.py',
        '$legacyRepoBase/diag.py',
        '$legacyRepoBase/$_legacyPythonFileName',
        '$legacyRepoBase/$_olderLegacyPythonFileName',
        '$legacyRepoBase/$_runScriptName',
        '$legacyRepoBase/camera.sh',
        '$legacyRepoBase/diag.sh',
        '$legacyRepoBase/$_legacyRunScriptName',
        '$legacyRepoBase/$_olderLegacyRunScriptName',
        '$managedBase/$_legacyPythonFileName',
        '$managedBase/$_olderLegacyPythonFileName',
        '$managedBase/$_legacyRunScriptName',
        '$managedBase/$_olderLegacyRunScriptName',
      ]);
    }
    return patterns;
  }

  String _sidecarProcessConfigCleanupPy() {
    return '''
import pathlib, sys
cfg = pathlib.Path(sys.argv[1])
text = cfg.read_text()
lines = text.splitlines()
needle_module = ${jsonEncode(_legacyManagedModule)}
removed = 0
out = []
for line in lines:
    if needle_module in line:
        removed = 1
        continue
    out.append(line)
if removed:
    cfg.write_text("\\n".join(out) + "\\n")
print(f"cfg_removed={removed}")
''';
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

if [ -z "\$REPO" ] && [ "${strict ? '1' : '0'}" = "1" ]; then
  echo "OPENPILOT_REPO_NOT_FOUND"
  exit 2
fi

if [ -n "\$REPO" ]; then
  BASE="\$REPO/selfdrive/$_managedFolderName"
else
  BASE="$_legacySidecarBasePath"
fi
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
    if (lines.contains('SIDECAR_BASE_NOT_FOUND')) {
      throw Exception('사이드카 경로를 만들지 못했습니다.');
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

    await _maybeCleanupLegacyInstall(ssh);
    _diag.info('sidecar', 'Deploy start');
    final remoteBase = await _resolveRemoteBase(ssh);
    final py =
        _toUnixText(await rootBundle.loadString('assets/sidecar/sidecar.py'));
    final sh =
        _toUnixText(await rootBundle.loadString('assets/sidecar/sidecar.sh'));
    final revision = _buildRevisionFromTexts(
      sidecarPy: py,
      runScript: sh,
    );

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

    _diag.info('sidecar', 'Deploy success base=$remoteBase');
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
SIDE_PIDFILE="\$BASE/$_pidFileName"
SIDE_LOGFILE="\$BASE/logs/$_logFileName"
if [ ! -f "\$BASE/$_runScriptName" ] || [ ! -f "\$BASE/$_pythonFileName" ]; then
  echo "SIDECAR_ARTIFACTS_NOT_DEPLOYED"
  exit 3
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
  PORT_TO_CHECK="\$1"
  if ! command -v ss >/dev/null 2>&1; then
    return 1
  fi
  ss -ltn 2>/dev/null | awk -v p=":\$PORT_TO_CHECK" '\$4 ~ (p "\$") { found=1 } END { exit(found ? 0 : 1) }'
}

port_pids() {
  PORT_TO_CHECK="\$1"
  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi
  ss -ltnp 2>/dev/null | awk -v p=":\$PORT_TO_CHECK" '
    \$4 ~ (p "\$") {
      if (match(\$0, /pid=[0-9]+/)) {
        print substr(\$0, RSTART + 4, RLENGTH - 4)
      }
    }' | sort -u || true
}

health_ok() {
  PORT_TO_CHECK="\$1"
  EXPECT_KIND="\$2"
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi
  curl -fsS --max-time 1 "http://127.0.0.1:\$PORT_TO_CHECK/health" 2>/dev/null | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' &&
  curl -fsS --max-time 1 "http://127.0.0.1:\$PORT_TO_CHECK/health" 2>/dev/null | grep -Fq '"kind":"'"\$EXPECT_KIND"'"'
}

start_service() {
  KIND="\$1"
  SESSION_NAME="\$2"
  RUN_SCRIPT="\$3"
  PID_FILE="\$4"
  LOG_FILE="\$5"
  TARGET_PORT="\$6"
  EXPECT_KIND="\$7"
  EXTRA_ENV="\$8"

  if command -v tmux >/dev/null 2>&1; then
    tmux has-session -t "\$SESSION_NAME" 2>/dev/null && tmux kill-session -t "\$SESSION_NAME" || true
  fi

  if [ -f "\$PID_FILE" ]; then
    OLD_PID=\$(cat "\$PID_FILE" 2>/dev/null || true)
    kill_pid_if_alive "\$OLD_PID"
    rm -f "\$PID_FILE" || true
  fi

  for P in \$(port_pids "\$TARGET_PORT"); do
    kill_pid_if_alive "\$P"
  done

  for i in \$(seq 1 15); do
    if ! port_open "\$TARGET_PORT"; then
      break
    fi
    sleep 0.2
  done

  if port_open "\$TARGET_PORT"; then
    echo "\${KIND}_PORT_IN_USE_BEFORE_START=\$TARGET_PORT"
    exit 5
  fi

  if command -v tmux >/dev/null 2>&1; then
    tmux new-session -d -s "\$SESSION_NAME" "env CARROTLINK_SIDECAR_BASE=\$BASE CARROTLINK_SIDECAR_PROFILE=\$PROFILE CARROTLINK_SIDECAR_PORT=\$PORT CARROTLINK_CAMERA_PORT=\$CAMERA_PORT \$EXTRA_ENV bash \$BASE/\$RUN_SCRIPT >> \$LOG_FILE 2>&1"
    echo "\${KIND}_start_method=tmux"
  else
    nohup env CARROTLINK_SIDECAR_BASE="\$BASE" CARROTLINK_SIDECAR_PROFILE="\$PROFILE" CARROTLINK_SIDECAR_PORT="\$PORT" CARROTLINK_CAMERA_PORT="\$CAMERA_PORT" \$EXTRA_ENV bash "\$BASE/\$RUN_SCRIPT" >> "\$LOG_FILE" 2>&1 &
    NEW_PID=\$!
    if [ -n "\$NEW_PID" ]; then
      echo "\$NEW_PID" > "\$PID_FILE"
    fi
    echo "\${KIND}_start_method=nohup"
  fi

  READY=0
  if command -v curl >/dev/null 2>&1; then
    for i in \$(seq 1 40); do
      if health_ok "\$TARGET_PORT" "\$EXPECT_KIND"; then
        READY=1
        break
      fi
      sleep 0.25
    done
  else
    sleep 2
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "\$SESSION_NAME" 2>/dev/null; then
      READY=1
    elif [ -f "\$PID_FILE" ]; then
      PID=\$(cat "\$PID_FILE" 2>/dev/null || true)
      if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
        READY=1
      fi
    fi
  fi

  if [ "\$READY" -ne 1 ] && port_open "\$TARGET_PORT"; then
    READY=1
  fi
  if [ "\$READY" -ne 1 ]; then
    echo "\${KIND}_START_FAILED"
    if [ -f "\$LOG_FILE" ]; then
      echo "--- \${KIND}_log tail ---"
      tail -n 80 "\$LOG_FILE"
    fi
    exit 4
  fi
}

if health_ok "\$PORT" "carrotlink_sidecar_broker_v1"; then
  echo "SIDECAR_ALREADY_RUNNING profile=\$PROFILE port=\$PORT base=\$BASE"
  exit 0
fi

start_service "SIDECAR" "\$SESSION" "$_runScriptName" "\$SIDE_PIDFILE" "\$SIDE_LOGFILE" "\$PORT" "carrotlink_sidecar_broker_v1" "CARROTLINK_SIDECAR_HOST=0.0.0.0"

SIDE_PORT_PIDS=\$(port_pids "\$PORT" | tr '\n' ',' | sed 's/,\$//' || true)
echo "SIDECAR_STARTED profile=\$PROFILE port=\$PORT base=\$BASE"
echo "sidecar_port_pids=\$SIDE_PORT_PIDS"
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
SIDE_PIDFILE="\$BASE/$_pidFileName"
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

port_open() {
  PORT_TO_CHECK="\$1"
  if ! command -v ss >/dev/null 2>&1; then
    return 1
  fi
  ss -ltn 2>/dev/null | awk -v p=":\$PORT_TO_CHECK" '\$4 ~ (p "\$") { found=1 } END { exit(found ? 0 : 1) }'
}

if command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t "\$SESSION" 2>/dev/null; then
    tmux kill-session -t "\$SESSION" || true
    STOPPED=1
  fi
fi
if [ -f "\$SIDE_PIDFILE" ]; then
  PID=\$(cat "\$SIDE_PIDFILE" 2>/dev/null || true)
  if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
    kill_pid_if_alive "\$PID"
    STOPPED=1
  fi
  rm -f "\$SIDE_PIDFILE" || true
fi

if command -v ss >/dev/null 2>&1; then
  PORT_PIDS="\$(ss -ltnp 2>/dev/null | awk -v p=":\$PORT" '
    \$4 ~ (p "\$") {
      if (match(\$0, /pid=[0-9]+/)) {
        print substr(\$0, RSTART + 4, RLENGTH - 4)
      }
    }' | sort -u || true)"
  for P in \$PORT_PIDS; do
    kill_pid_if_alive "\$P"
    STOPPED=1
  done
fi

for i in \$(seq 1 20); do
  if ! port_open "\$PORT"; then
    break
  fi
  sleep 0.2
done

if [ "\$STOPPED" -eq 1 ]; then
  echo "SIDECAR_STOPPED"
else
  echo "SIDECAR_NOT_RUNNING"
fi
echo "port_open=\$(if port_open "\$PORT"; then echo 1; else echo 0; fi)"
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
PYFILE="\$BASE/$_pythonFileName"
REVFILE="\$BASE/$_revisionFileName"
RUNNING=0
LISTEN=0
METHOD="none"
PORT_PIDS=""
file_mtime() {
  if ! command -v stat >/dev/null 2>&1; then
    return 0
  fi
  stat -c %Y "\$1" 2>/dev/null || stat -f %m "\$1" 2>/dev/null || true
}
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
  ss -ltn 2>/dev/null | awk -v p=":\$PORT" '\$4 ~ (p "\$") { found=1 } END { exit(found ? 0 : 1) }' && LISTEN=1 || true
  PORT_PIDS=\$(ss -ltnp 2>/dev/null | awk -v p=":\$PORT" '
    \$4 ~ (p "\$") {
      if (match(\$0, /pid=[0-9]+/)) {
        print substr(\$0, RSTART + 4, RLENGTH - 4)
      }
    }' | sort -u | tr '\\n' ',' | sed 's/,\$//' || true)
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
echo "py_name=$_pythonFileName"
if [ -f "\$PYFILE" ]; then
  echo "py_updated_epoch=\$(file_mtime "\$PYFILE")"
else
  echo "py_updated_epoch="
fi
if [ -f "\$REVFILE" ]; then
  echo "remote_revision=\$(tr -d '\\r' < "\$REVFILE" | head -n 1)"
  echo "rev_updated_epoch=\$(file_mtime "\$REVFILE")"
else
  echo "remote_revision="
  echo "rev_updated_epoch="
fi
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

  Future<String> criticalProcStatus(SSHService ssh) async {
    if (!ssh.isConnected) {
      throw Exception('기기와 연결되어 있지 않습니다.');
    }

    final result = await ssh.executeCommandResult(
      _bash(
        '''
emit_proc() {
  NAME="\$1"
  PATTERN="\$2"
  PIDS=\$(ps -eo pid,args 2>/dev/null | awk -v pat="\$PATTERN" '
    index(\$0, pat) {
      if (out != "") out = out ","
      out = out \$1
    }
    END { print out }
  ' || true)
  if [ -n "\$PIDS" ]; then
    echo "\$NAME=up:\$PIDS"
  else
    echo "\$NAME=down"
  fi
}

emit_proc "locationd" "selfdrive.locationd.locationd"
emit_proc "controlsd" "selfdrive.controls.controlsd"
emit_proc "plannerd" "selfdrive.controls.plannerd"
emit_proc "selfdrived" "selfdrive.selfdrived.selfdrived"
emit_proc "stream_encoderd" "encoderd --stream"
emit_proc "webrtcd" "system.webrtc.webrtcd"
''',
      ),
      timeout: const Duration(seconds: 12),
    );
    if (!result.isSuccess) {
      throw Exception('핵심 프로세스 상태 조회 실패: ${result.output}');
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
    if (removeManagerRegistration) {
      await _maybeCleanupLegacyInstall(ssh, force: true);
    }

    final remoteBase = await _resolveRemoteBase(ssh, strict: false);
    final result = await ssh.executeCommandResult(
      _bash(
        '''
BASE=${_q(remoteBase)}
PORT=${_q(port.toString())}

# Remove current and legacy sidecar artifacts
rm -f "\$BASE/$_pythonFileName" "\$BASE/$_runScriptName" "\$BASE/$_revisionFileName" "\$BASE/$_pidFileName" "\$BASE/logs/$_logFileName" "\$BASE/$_legacyPythonFileName" "\$BASE/$_legacyRunScriptName" "\$BASE/$_olderLegacyPythonFileName" "\$BASE/$_olderLegacyRunScriptName" "\$BASE/$_legacyRevisionFileName" "\$BASE/logs/$_legacyLogFileName"

# Cleanup any lingering listeners
if command -v ss >/dev/null 2>&1; then
  PORT_PIDS="\$(ss -ltnp 2>/dev/null | awk -v p=":\$PORT" '
    \$4 ~ (p "\$") {
      if (match(\$0, /pid=[0-9]+/)) {
        print substr(\$0, RSTART + 4, RLENGTH - 4)
      }
    }' | sort -u || true)"
  for P in \$PORT_PIDS; do
    kill "\$P" 2>/dev/null || true
    sleep 0.1
    kill -9 "\$P" 2>/dev/null || true
  done
fi

echo "SIDECAR_RESET_DONE base=\$BASE"
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
