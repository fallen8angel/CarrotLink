import 'diagnostics_service.dart';
import 'ssh_service.dart';

enum DeviceActionType {
  gitPull,
  gitSync,
  gitResetHardClean,
  gitCheckout,
  reboot,
  softRestart,
  rebuildOpenpilot,
  resetLiveParameters,
  resetCalibration,
  deleteVideos,
  deleteLogs,
}

class DeviceActionResult {
  final DeviceActionType action;
  final bool ok;
  final int exitCode;
  final String command;
  final String stdout;
  final String stderr;
  final Duration duration;
  final String transport;

  const DeviceActionResult({
    required this.action,
    required this.ok,
    required this.exitCode,
    required this.command,
    required this.stdout,
    required this.stderr,
    required this.duration,
    required this.transport,
  });

  String get output {
    if (stdout.isNotEmpty && stderr.isNotEmpty) {
      return '$stdout\n$stderr';
    }
    if (stdout.isNotEmpty) return stdout;
    return stderr;
  }
}

class GitBranchSnapshot {
  final String repoPath;
  final String repoUrl;
  final String currentBranch;
  final String defaultBranch;
  final List<Map<String, String>> branches;
  final Map<String, String> localRefs;
  final String rawOutput;

  const GitBranchSnapshot({
    required this.repoPath,
    required this.repoUrl,
    required this.currentBranch,
    required this.defaultBranch,
    required this.branches,
    required this.localRefs,
    required this.rawOutput,
  });
}

class DeviceActionService {
  DeviceActionService({DiagnosticsService? diagnostics})
      : _diag = diagnostics ?? DiagnosticsService.instance;

  final DiagnosticsService _diag;

  Future<DeviceActionResult> runAction(
    SSHService ssh,
    DeviceActionType action, {
    String? branch,
  }) async {
    final script = _scriptFor(action, branch: branch);
    final command = _bash(script);
    final timeout = _timeoutFor(action);

    _diag.info('device_action', 'Run action=${action.name}');
    final result = await ssh.executeCommandResult(command, timeout: timeout);
    final wrapped = DeviceActionResult(
      action: action,
      ok: result.isSuccess,
      exitCode: result.exitCode,
      command: command,
      stdout: result.stdout,
      stderr: result.stderr,
      duration: result.duration,
      transport: 'ssh',
    );

    if (wrapped.ok) {
      _diag.info(
        'device_action',
        'Success action=${action.name} in ${wrapped.duration.inMilliseconds}ms',
      );
    } else {
      _diag.warn(
        'device_action',
        'Fail action=${action.name} code=${wrapped.exitCode} out=${wrapped.output}',
      );
    }
    return wrapped;
  }

  String previewAction(
    DeviceActionType action, {
    String? branch,
  }) {
    return _scriptFor(action, branch: branch).trim();
  }

  Future<GitBranchSnapshot> loadGitBranchSnapshot(SSHService ssh) async {
    final script = '''
${_repoDetectScript()}
git -C "\$REPO" fetch --all --prune >/dev/null 2>&1 || true
CURRENT_BRANCH="\$(git -C "\$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
DEFAULT_BRANCH="\$(git -C "\$REPO" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -n1)"
REPO_URL="\$(git -C "\$REPO" config --get remote.origin.url 2>/dev/null || true)"
echo "__META__|\$REPO|\$CURRENT_BRANCH|\$DEFAULT_BRANCH|\$REPO_URL"
git -C "\$REPO" for-each-ref --sort=-committerdate --format="%(refname:short)|%(committerdate:relative)|%(objectname)" refs/remotes/origin || true
echo "__LOCAL__"
git -C "\$REPO" for-each-ref --format="%(refname:short)|%(objectname)" refs/heads || true
''';

    final command = _bash(script);
    final result = await ssh.executeCommandResult(
      command,
      timeout: const Duration(seconds: 45),
    );

    if (!result.isSuccess) {
      throw Exception(
          result.output.isEmpty ? '브랜치 정보를 가져오지 못했습니다.' : result.output);
    }

    final lines = result.stdout
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (lines.isEmpty || !lines.first.startsWith('__META__|')) {
      throw Exception('브랜치 출력 형식이 올바르지 않습니다.');
    }

    final meta = lines.first.split('|');
    final repoPath = meta.length > 1 ? meta[1] : '';
    final currentBranch = meta.length > 2 ? meta[2] : '';
    final defaultBranch = meta.length > 3 ? meta[3] : '';
    var repoUrl = meta.length > 4 ? meta.sublist(4).join('|') : '';
    if (repoUrl.endsWith('.git')) {
      repoUrl = repoUrl.substring(0, repoUrl.length - 4);
    }

    final localMarkerIndex = lines.indexOf('__LOCAL__');
    final remoteLines = localMarkerIndex >= 0
        ? lines.sublist(1, localMarkerIndex)
        : lines.sublist(1);
    final localLines = localMarkerIndex >= 0
        ? lines.sublist(localMarkerIndex + 1)
        : const <String>[];

    final branches = remoteLines
        .map((line) {
          final parts = line.split('|');
          if (parts.isEmpty) return null;
          final fullName = parts[0];
          if (fullName.contains('->')) return null;

          var name = fullName;
          if (name.startsWith('origin/')) {
            name = name.substring('origin/'.length);
          } else if (name.contains('/')) {
            final idx = name.lastIndexOf('/');
            name = name.substring(idx + 1);
          }
          if (name.isEmpty || name == 'HEAD' || name == 'origin') {
            return null;
          }

          final date = parts.length > 1 ? parts[1] : '';
          final hash = parts.length > 2 ? parts[2] : '';
          return <String, String>{
            'name': name,
            'date': date,
            'hash': hash,
            'fullName': fullName,
          };
        })
        .whereType<Map<String, String>>()
        .toList();

    final localRefs = <String, String>{};
    for (final line in localLines) {
      final parts = line.split('|');
      if (parts.length != 2) continue;
      final branchName = parts[0].trim();
      final hash = parts[1].trim();
      if (branchName.isEmpty || hash.isEmpty) continue;
      localRefs[branchName] = hash;
    }

    return GitBranchSnapshot(
      repoPath: repoPath,
      repoUrl: repoUrl,
      currentBranch: currentBranch,
      defaultBranch: defaultBranch,
      branches: branches,
      localRefs: localRefs,
      rawOutput: result.stdout,
    );
  }

  Duration _timeoutFor(DeviceActionType action) {
    switch (action) {
      case DeviceActionType.rebuildOpenpilot:
        return const Duration(minutes: 20);
      case DeviceActionType.gitSync:
      case DeviceActionType.gitPull:
        return const Duration(minutes: 3);
      default:
        return const Duration(seconds: 90);
    }
  }

  String _scriptFor(
    DeviceActionType action, {
    String? branch,
  }) {
    switch (action) {
      case DeviceActionType.gitPull:
        return '''
${_repoDetectScript()}
git -C "\$REPO" pull
''';
      case DeviceActionType.gitSync:
        return '''
${_repoDetectScript()}
BRANCH="\$(git -C "\$REPO" rev-parse --abbrev-ref HEAD)"
git -C "\$REPO" fetch --all --prune
if git -C "\$REPO" rev-parse --verify --quiet "origin/\$BRANCH" >/dev/null 2>&1; then
  git -C "\$REPO" reset --hard "origin/\$BRANCH"
else
  echo "origin/\$BRANCH not found, fetch-only done"
fi
''';
      case DeviceActionType.gitResetHardClean:
        return '''
${_repoDetectScript()}
git -C "\$REPO" reset --hard HEAD
''';
      case DeviceActionType.gitCheckout:
        final normalized = _sanitizeBranch(branch);
        return '''
${_repoDetectScript()}
BRANCH="$normalized"
git -C "\$REPO" fetch --all --prune
if git -C "\$REPO" show-ref --verify --quiet "refs/heads/\$BRANCH"; then
  git -C "\$REPO" checkout "\$BRANCH"
else
  git -C "\$REPO" checkout -B "\$BRANCH" "origin/\$BRANCH"
fi
''';
      case DeviceActionType.reboot:
        return 'sudo reboot';
      case DeviceActionType.softRestart:
        return '''
${_repoDetectScript()}
tmux kill-session -t comma 2>/dev/null || true
rm -f /tmp/safe_staging_overlay.lock 2>/dev/null || true
sleep 1
tmux new-session -d -s comma "bash -lc \\"\$REPO/launch_openpilot.sh\\""
''';
      case DeviceActionType.rebuildOpenpilot:
        return '''
${_repoDetectScript()}
cd "\$REPO"
scons -c
rm -f .sconsign.dblite
rm -rf /tmp/scons_cache
rm -rf prebuilt
sudo reboot
''';
      case DeviceActionType.resetLiveParameters:
        return 'rm -f /data/params/d/LiveParameters';
      case DeviceActionType.resetCalibration:
        return 'rm -f /data/params/d/CalibrationParams';
      case DeviceActionType.deleteVideos:
        return '''
TARGET="/data/media/0/videos"
if [ ! -d "\$TARGET" ]; then
  echo "videos path not found (skip)"
  exit 0
fi
COUNT=\$(find "\$TARGET" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
find "\$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
echo "deleted entries: \$COUNT"
''';
      case DeviceActionType.deleteLogs:
        return '''
TARGET="/data/media/0/realdata"
if [ ! -d "\$TARGET" ]; then
  echo "realdata path not found (skip)"
  exit 0
fi
COUNT=\$(find "\$TARGET" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
find "\$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
echo "deleted entries: \$COUNT"
''';
    }
  }

  String _sanitizeBranch(String? branch) {
    final value = (branch ?? '').trim();
    final pattern = RegExp(r'^[A-Za-z0-9._/-]+$');
    if (value.isEmpty || !pattern.hasMatch(value)) {
      throw Exception('유효하지 않은 브랜치 이름입니다.');
    }
    return value;
  }

  String _repoDetectScript() {
    return '''
REPO=""
for d in /data/openpilot /home/comma/openpilot; do
  if [ -d "\$d/.git" ]; then
    REPO="\$d"
    break
  fi
done
if [ -z "\$REPO" ]; then
  echo OPENPILOT_REPO_NOT_FOUND
  exit 2
fi
''';
  }

  String _bash(String script) {
    final escaped = script.replaceAll("'", "'\"'\"'");
    return "bash -lc '$escaped'";
  }
}
