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
  final String requestedRepoPath;
  final String repoPathSource;
  final String repoUrl;
  final String originUrl;
  final String primaryRemoteName;
  final String currentBranch;
  final String defaultBranch;
  final String upstreamRef;
  final String upstreamRemote;
  final String upstreamBranch;
  final List<GitRemoteInfo> remotes;
  final List<Map<String, String>> branches;
  final Map<String, String> localRefs;
  final String rawOutput;

  const GitBranchSnapshot({
    required this.repoPath,
    required this.requestedRepoPath,
    required this.repoPathSource,
    required this.repoUrl,
    required this.originUrl,
    required this.primaryRemoteName,
    required this.currentBranch,
    required this.defaultBranch,
    required this.upstreamRef,
    required this.upstreamRemote,
    required this.upstreamBranch,
    required this.remotes,
    required this.branches,
    required this.localRefs,
    required this.rawOutput,
  });

  bool get hasOriginRemote => remotes.any((e) => e.name == 'origin');
  bool get usingConfiguredRepoPath =>
      requestedRepoPath.isNotEmpty &&
      repoPath == requestedRepoPath &&
      repoPathSource == 'preferred';
  bool get fellBackFromConfiguredRepoPath =>
      requestedRepoPath.isNotEmpty && repoPath != requestedRepoPath;
  bool get isLikelyOpenpilotRepo {
    final candidate =
        (originUrl.isNotEmpty ? originUrl : repoUrl).toLowerCase();
    return candidate.contains('openpilot');
  }
}

class GitRemoteInfo {
  final String name;
  final String fetchUrl;
  final String pushUrl;

  const GitRemoteInfo({
    required this.name,
    required this.fetchUrl,
    required this.pushUrl,
  });
}

class GitRemoteUpdateResult {
  final bool ok;
  final String effectiveOriginUrl;
  final bool fetchSucceeded;
  final String stdout;
  final String stderr;

  const GitRemoteUpdateResult({
    required this.ok,
    required this.effectiveOriginUrl,
    required this.fetchSucceeded,
    required this.stdout,
    required this.stderr,
  });
}

class GitConfigCommandResult {
  final bool ok;
  final int exitCode;
  final String stdout;
  final String stderr;

  const GitConfigCommandResult({
    required this.ok,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  String get output {
    if (stdout.isNotEmpty && stderr.isNotEmpty) return '$stdout\n$stderr';
    if (stdout.isNotEmpty) return stdout;
    return stderr;
  }
}

class DeviceActionService {
  DeviceActionService({DiagnosticsService? diagnostics})
      : _diag = diagnostics ?? DiagnosticsService.instance;

  final DiagnosticsService _diag;

  Future<DeviceActionResult> runAction(
    SSHService ssh,
    DeviceActionType action, {
    String? branch,
    String? remote,
    String? repoPathOverride,
  }) async {
    final script = _scriptFor(
      action,
      branch: branch,
      remote: remote,
      repoPathOverride: repoPathOverride,
    );
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
    String? remote,
    String? repoPathOverride,
  }) {
    return _scriptFor(
      action,
      branch: branch,
      remote: remote,
      repoPathOverride: repoPathOverride,
    ).trim();
  }

  Future<GitBranchSnapshot> loadGitBranchSnapshot(
    SSHService ssh, {
    String? preferredRepoPath,
  }) async {
    final script = '''
${_repoDetectScript(preferredRepoPath: preferredRepoPath)}
git -C "\$REPO" fetch --all --prune >/dev/null 2>&1 || true
PRIMARY_REMOTE="\$(git -C "\$REPO" remote | head -n1 | tr -d '\\r')"
CURRENT_BRANCH="\$(git -C "\$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
UPSTREAM_REF="\$(git -C "\$REPO" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
DEFAULT_BRANCH="\$(git -C "\$REPO" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -n1)"
ORIGIN_URL="\$(git -C "\$REPO" config --get remote.origin.url 2>/dev/null || true)"
if [ -n "\$ORIGIN_URL" ]; then
  REPO_URL="\$ORIGIN_URL"
else
  REPO_URL="\$(git -C "\$REPO" remote get-url "\$PRIMARY_REMOTE" 2>/dev/null || true)"
fi
echo "__META__|\$REPO|\$REPO_SOURCE|\$REQUESTED_REPO|\$CURRENT_BRANCH|\$DEFAULT_BRANCH|\$REPO_URL|\$ORIGIN_URL|\$PRIMARY_REMOTE|\$UPSTREAM_REF"
echo "__REMOTES__"
git -C "\$REPO" remote -v || true
echo "__BRANCHES__"
git -C "\$REPO" for-each-ref --sort=-committerdate --format="%(refname:short)|%(committerdate:relative)|%(objectname)" refs/remotes || true
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
    final repoPathSource = meta.length > 2 ? meta[2] : '';
    final requestedRepoPath = meta.length > 3 ? meta[3] : '';
    final currentBranch = meta.length > 4 ? meta[4] : '';
    final defaultBranch = meta.length > 5 ? meta[5] : '';
    var repoUrl = meta.length > 6 ? meta[6] : '';
    var originUrl = meta.length > 7 ? meta[7] : '';
    final primaryRemoteName = meta.length > 8 ? meta[8] : '';
    final upstreamRef = meta.length > 9 ? meta.sublist(9).join('|') : '';
    if (repoUrl.endsWith('.git'))
      repoUrl = repoUrl.substring(0, repoUrl.length - 4);
    if (originUrl.endsWith('.git')) {
      originUrl = originUrl.substring(0, originUrl.length - 4);
    }

    final remotesMarkerIndex = lines.indexOf('__REMOTES__');
    final branchesMarkerIndex = lines.indexOf('__BRANCHES__');
    final localMarkerIndex = lines.indexOf('__LOCAL__');
    final remoteConfigLines =
        (remotesMarkerIndex >= 0 && branchesMarkerIndex > remotesMarkerIndex)
            ? lines.sublist(remotesMarkerIndex + 1, branchesMarkerIndex)
            : const <String>[];
    final remoteBranchLines =
        (branchesMarkerIndex >= 0 && localMarkerIndex > branchesMarkerIndex)
            ? lines.sublist(branchesMarkerIndex + 1, localMarkerIndex)
            : (localMarkerIndex >= 0
                ? lines.sublist(1, localMarkerIndex)
                : lines.sublist(1));
    final localLines = localMarkerIndex >= 0
        ? lines.sublist(localMarkerIndex + 1)
        : const <String>[];

    final remoteMap = <String, Map<String, String>>{};
    for (final line in remoteConfigLines) {
      final match =
          RegExp(r'^([^\s]+)\s+(.+)\s+\((fetch|push)\)$').firstMatch(line);
      if (match == null) continue;
      final name = match.group(1)!.trim();
      final url = match.group(2)!.trim();
      final kind = match.group(3)!.trim();
      final entry = remoteMap.putIfAbsent(
          name,
          () => {
                'fetch': '',
                'push': '',
              });
      entry[kind] =
          url.endsWith('.git') ? url.substring(0, url.length - 4) : url;
    }
    final remotes = remoteMap.entries
        .map((entry) => GitRemoteInfo(
              name: entry.key,
              fetchUrl: entry.value['fetch'] ?? '',
              pushUrl: entry.value['push'] ?? '',
            ))
        .toList()
      ..sort((a, b) {
        if (a.name == 'origin') return -1;
        if (b.name == 'origin') return 1;
        if (a.name == primaryRemoteName) return -1;
        if (b.name == primaryRemoteName) return 1;
        return a.name.compareTo(b.name);
      });

    final branches = remoteBranchLines
        .map((line) {
          final parts = line.split('|');
          if (parts.isEmpty) return null;
          final fullName = parts[0];
          if (fullName.contains('->')) return null;
          final slashIndex = fullName.indexOf('/');
          if (slashIndex <= 0 || slashIndex >= fullName.length - 1) return null;
          final remoteName = fullName.substring(0, slashIndex);
          final name = fullName.substring(slashIndex + 1);
          if (name.isEmpty || name == 'HEAD' || name == 'origin') {
            return null;
          }

          final date = parts.length > 1 ? parts[1] : '';
          final hash = parts.length > 2 ? parts[2] : '';
          return <String, String>{
            'name': name,
            'remote': remoteName,
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

    String upstreamRemote = '';
    String upstreamBranch = '';
    if (upstreamRef.contains('/')) {
      final idx = upstreamRef.indexOf('/');
      upstreamRemote = upstreamRef.substring(0, idx);
      upstreamBranch = upstreamRef.substring(idx + 1);
    }

    return GitBranchSnapshot(
      repoPath: repoPath,
      requestedRepoPath: requestedRepoPath,
      repoPathSource: repoPathSource,
      repoUrl: repoUrl,
      originUrl: originUrl,
      primaryRemoteName: primaryRemoteName,
      currentBranch: currentBranch,
      defaultBranch: defaultBranch,
      upstreamRef: upstreamRef,
      upstreamRemote: upstreamRemote,
      upstreamBranch: upstreamBranch,
      remotes: remotes,
      branches: branches,
      localRefs: localRefs,
      rawOutput: result.stdout,
    );
  }

  Future<GitRemoteUpdateResult> setGitOriginRemote(
      SSHService ssh, String originUrl,
      {String? preferredRepoPath}) async {
    final normalizedUrl = originUrl.trim();
    if (normalizedUrl.isEmpty) {
      throw Exception('원격 저장소 URL이 비어 있습니다.');
    }

    final script = '''
${_repoDetectScript(preferredRepoPath: preferredRepoPath)}
URL="${_sanitizeRemoteUrl(normalizedUrl)}"
if git -C "\$REPO" remote get-url origin >/dev/null 2>&1; then
  git -C "\$REPO" remote set-url origin "\$URL"
else
  git -C "\$REPO" remote add origin "\$URL"
fi
EFFECTIVE_URL="\$(git -C "\$REPO" config --get remote.origin.url 2>/dev/null || true)"
FETCH_OK=0
git -C "\$REPO" fetch origin --prune >/dev/null 2>&1 || FETCH_OK=1
echo "__RESULT__|\$EFFECTIVE_URL|\$FETCH_OK"
''';

    final result = await ssh.executeCommandResult(
      _bash(script),
      timeout: const Duration(seconds: 60),
    );

    final lines = [
      ...result.stdout.split('\n'),
      ...result.stderr.split('\n'),
    ].map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    String? markerLine;
    for (final line in lines) {
      if (line.startsWith('__RESULT__|')) {
        markerLine = line;
        break;
      }
    }
    var effective = normalizedUrl;
    var fetchSucceeded = false;
    if (markerLine != null) {
      final parts = markerLine.split('|');
      if (parts.length > 1 && parts[1].trim().isNotEmpty) {
        effective = parts[1].trim();
      }
      if (parts.length > 2) {
        fetchSucceeded = parts[2].trim() == '0';
      }
    }

    return GitRemoteUpdateResult(
      ok: result.isSuccess,
      effectiveOriginUrl: effective,
      fetchSucceeded: fetchSucceeded,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  Future<GitConfigCommandResult> upsertGitRemote(
    SSHService ssh, {
    required String remoteName,
    required String remoteUrl,
    String? preferredRepoPath,
  }) async {
    final name = _sanitizeRemote(remoteName);
    final url = _sanitizeRemoteUrl(remoteUrl);
    final script = '''
${_repoDetectScript(preferredRepoPath: preferredRepoPath)}
NAME="$name"
URL="$url"
if git -C "\$REPO" remote get-url "\$NAME" >/dev/null 2>&1; then
  git -C "\$REPO" remote set-url "\$NAME" "\$URL"
else
  git -C "\$REPO" remote add "\$NAME" "\$URL"
fi
git -C "\$REPO" fetch "\$NAME" --prune >/dev/null 2>&1 || true
git -C "\$REPO" remote -v
''';
    final result = await ssh.executeCommandResult(
      _bash(script),
      timeout: const Duration(seconds: 60),
    );
    return GitConfigCommandResult(
      ok: result.isSuccess,
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  Future<GitConfigCommandResult> removeGitRemote(
    SSHService ssh, {
    required String remoteName,
    String? preferredRepoPath,
  }) async {
    final name = _sanitizeRemote(remoteName);
    final script = '''
${_repoDetectScript(preferredRepoPath: preferredRepoPath)}
NAME="$name"
if ! git -C "\$REPO" remote | grep -Fxq "\$NAME"; then
  echo "remote not found: \$NAME"
  exit 0
fi
git -C "\$REPO" remote remove "\$NAME"
git -C "\$REPO" remote -v || true
''';
    final result = await ssh.executeCommandResult(
      _bash(script),
      timeout: const Duration(seconds: 45),
    );
    return GitConfigCommandResult(
      ok: result.isSuccess,
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  Future<GitConfigCommandResult> setCurrentBranchUpstream(
    SSHService ssh, {
    required String remoteName,
    required String remoteBranch,
    String? preferredRepoPath,
  }) async {
    final remote = _sanitizeRemote(remoteName);
    final branch = _sanitizeBranch(remoteBranch);
    final script = '''
${_repoDetectScript(preferredRepoPath: preferredRepoPath)}
REMOTE="$remote"
RBRANCH="$branch"
CURRENT_BRANCH="\$(git -C "\$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ -z "\$CURRENT_BRANCH" ]; then
  echo "current branch not found"
  exit 2
fi
git -C "\$REPO" fetch "\$REMOTE" --prune >/dev/null 2>&1 || true
if ! git -C "\$REPO" show-ref --verify --quiet "refs/remotes/\$REMOTE/\$RBRANCH"; then
  echo "remote branch not found: \$REMOTE/\$RBRANCH"
  exit 3
fi
git -C "\$REPO" branch --set-upstream-to="\$REMOTE/\$RBRANCH" "\$CURRENT_BRANCH"
git -C "\$REPO" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true
''';
    final result = await ssh.executeCommandResult(
      _bash(script),
      timeout: const Duration(seconds: 45),
    );
    return GitConfigCommandResult(
      ok: result.isSuccess,
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
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
    String? remote,
    String? repoPathOverride,
  }) {
    switch (action) {
      case DeviceActionType.gitPull:
        return '''
${_repoDetectScript(preferredRepoPath: repoPathOverride)}
git -C "\$REPO" pull
''';
      case DeviceActionType.gitSync:
        return '''
${_repoDetectScript(preferredRepoPath: repoPathOverride)}
BRANCH="\$(git -C "\$REPO" rev-parse --abbrev-ref HEAD)"
git -C "\$REPO" fetch --all --prune
UPSTREAM="\$(git -C "\$REPO" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
if [ -n "\$UPSTREAM" ] && git -C "\$REPO" rev-parse --verify --quiet "\$UPSTREAM" >/dev/null 2>&1; then
  git -C "\$REPO" reset --hard "\$UPSTREAM"
elif git -C "\$REPO" rev-parse --verify --quiet "origin/\$BRANCH" >/dev/null 2>&1; then
  git -C "\$REPO" reset --hard "origin/\$BRANCH"
else
  echo "upstream/origin branch not found, fetch-only done"
fi
''';
      case DeviceActionType.gitResetHardClean:
        return '''
${_repoDetectScript(preferredRepoPath: repoPathOverride)}
git -C "\$REPO" reset --hard HEAD
''';
      case DeviceActionType.gitCheckout:
        final normalized = _sanitizeBranch(branch);
        final remoteName = _sanitizeRemote(remote);
        return '''
${_repoDetectScript(preferredRepoPath: repoPathOverride)}
BRANCH="$normalized"
REMOTE="$remoteName"
git -C "\$REPO" fetch --all --prune
if git -C "\$REPO" show-ref --verify --quiet "refs/heads/\$BRANCH"; then
  git -C "\$REPO" checkout "\$BRANCH"
else
  if git -C "\$REPO" show-ref --verify --quiet "refs/remotes/\$REMOTE/\$BRANCH"; then
    git -C "\$REPO" checkout -B "\$BRANCH" "\$REMOTE/\$BRANCH"
  elif git -C "\$REPO" show-ref --verify --quiet "refs/remotes/origin/\$BRANCH"; then
    git -C "\$REPO" checkout -B "\$BRANCH" "origin/\$BRANCH"
  else
    echo "remote branch not found: \$REMOTE/\$BRANCH"
    exit 3
  fi
fi
''';
      case DeviceActionType.reboot:
        return 'sudo reboot';
      case DeviceActionType.softRestart:
        return '''
${_repoDetectScript(preferredRepoPath: repoPathOverride)}
tmux kill-session -t comma 2>/dev/null || true
rm -f /tmp/safe_staging_overlay.lock 2>/dev/null || true
sleep 1
tmux new-session -d -s comma "bash -lc \\"\$REPO/launch_openpilot.sh\\""
''';
      case DeviceActionType.rebuildOpenpilot:
        return '''
${_repoDetectScript(preferredRepoPath: repoPathOverride)}
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

  String _sanitizeRemote(String? remote) {
    final value = (remote ?? '').trim();
    if (value.isEmpty) return 'origin';
    final pattern = RegExp(r'^[A-Za-z0-9._-]+$');
    if (!pattern.hasMatch(value)) {
      throw Exception('유효하지 않은 리모트 이름입니다.');
    }
    return value;
  }

  String _sanitizeRemoteUrl(String url) {
    final value = url.trim();
    if (value.isEmpty) {
      throw Exception('유효하지 않은 원격 저장소 URL입니다.');
    }
    final pattern = RegExp(r'^[A-Za-z0-9:/@._~#?&=%+\-]+$');
    if (!pattern.hasMatch(value)) {
      throw Exception('지원하지 않는 URL 형식입니다.');
    }
    return value;
  }

  String _repoDetectScript({String? preferredRepoPath}) {
    final preferred = (preferredRepoPath ?? '').trim();
    final preferredEscaped =
        preferred.isEmpty ? '' : _escapeForDoubleQuotedShell(preferred);
    return '''
REPO=""
REPO_SOURCE=""
REQUESTED_REPO="$preferredEscaped"
if [ -n "\$REQUESTED_REPO" ] && [ -d "\$REQUESTED_REPO/.git" ]; then
  REPO="\$REQUESTED_REPO"
  REPO_SOURCE="preferred"
fi
if [ -z "\$REPO" ]; then
  for d in /data/openpilot /home/comma/openpilot; do
    if [ -d "\$d/.git" ]; then
      REPO="\$d"
      REPO_SOURCE="\$( [ -n "\$REQUESTED_REPO" ] && echo fallback || echo default )"
      break
    fi
  done
fi
if [ -z "\$REPO" ] && [ -n "\$REQUESTED_REPO" ]; then
  if [ -d "\$REQUESTED_REPO" ]; then
    echo "configured repo path exists but .git not found: \$REQUESTED_REPO"
  else
    echo "configured repo path not found: \$REQUESTED_REPO"
  fi
fi
if [ -z "\$REPO" ]; then
  echo OPENPILOT_REPO_NOT_FOUND
  exit 2
fi
''';
  }

  String _escapeForDoubleQuotedShell(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll(r'$', r'\$')
        .replaceAll('`', r'\`');
  }

  String _bash(String script) {
    final escaped = script.replaceAll("'", "'\"'\"'");
    return "bash -lc '$escaped'";
  }
}
