import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/ssh_service.dart';
import '../../services/device_action_service.dart';
import '../../widgets/design_components.dart';
import '../../widgets/custom_toast.dart';

enum _GitToolsMenuAction {
  quickSetupFromLink,
  showDetails,
  clearLogs,
  advancedSettings,
  changeOrigin,
  setRepoPath,
  clearRepoPath,
  addRemote,
  editRemote,
  deleteRemote,
  setUpstream,
}

class _RepoLinkSpec {
  final String repoUrl;
  final String? branch;
  final String owner;
  final String repo;

  const _RepoLinkSpec({
    required this.repoUrl,
    required this.owner,
    required this.repo,
    this.branch,
  });
}

class GitTab extends StatefulWidget {
  const GitTab({super.key});

  @override
  State<GitTab> createState() => _GitTabState();
}

class _GitTabState extends State<GitTab> {
  static const String _gitLogsPrefKey = 'git_logs';
  static const String _gitRepoPathPrefKey = 'git_repo_path_override';

  bool _isLoading = false;
  bool _isLoadingSourceInfo = false;
  List<Map<String, String>> _logs = [];
  final ScrollController _scrollController = ScrollController();
  final DeviceActionService _actionService = DeviceActionService();
  GitBranchSnapshot? _gitSnapshot;
  String _repoPathOverride = '';

  String? get _preferredRepoPath {
    final trimmed = _repoPathOverride.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadLogs());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_initializeGitSourceSettings());
      }
    });
  }

  Future<void> _initializeGitSourceSettings() async {
    await _loadGitRepoPathOverride();
    if (!mounted) return;
    await _refreshGitSourceInfo(silent: true);
  }

  Future<void> _loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final String? storedLogs = prefs.getString(_gitLogsPrefKey);
    if (storedLogs != null) {
      try {
        final List<dynamic> decoded = jsonDecode(storedLogs);
        setState(() {
          _logs = decoded.map((e) {
            final map = Map<String, String>.from(e);
            map['isOld'] = 'true'; // Mark loaded logs as old
            return map;
          }).toList();
        });
        // Scroll to bottom after loading
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController
                .jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      } catch (e) {
        print("Error loading logs: $e");
      }
    }
  }

  Future<void> _saveLogs() async {
    final prefs = await SharedPreferences.getInstance();
    // Limit logs to last 100 entries to prevent overflow
    if (_logs.length > 100) {
      _logs = _logs.sublist(_logs.length - 100);
    }
    // Don't save 'isOld' property to disk, or just ignore it when loading
    // Actually, we can save it, but when we load next time, EVERYTHING becomes old.
    // So we should strip 'isOld' before saving, or just save as is and override on load.
    // Let's save as is.
    final String encoded = jsonEncode(_logs);
    await prefs.setString(_gitLogsPrefKey, encoded);
  }

  void _addLog(String message) {
    final time = DateFormat('HH:mm:ss').format(DateTime.now());
    setState(() {
      _logs.add({'time': time, 'message': message, 'isOld': 'false'});
    });
    _saveLogs(); // Save on every log add
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _clearLogs() async {
    setState(() {
      _logs.clear();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_gitLogsPrefKey);
  }

  Future<void> _loadGitRepoPathOverride() async {
    final prefs = await SharedPreferences.getInstance();
    final value = (prefs.getString(_gitRepoPathPrefKey) ?? '').trim();
    if (!mounted) return;
    setState(() {
      _repoPathOverride = value;
    });
  }

  Future<void> _saveGitRepoPathOverride(String value) async {
    final normalized = value.trim();
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      await prefs.remove(_gitRepoPathPrefKey);
    } else {
      await prefs.setString(_gitRepoPathPrefKey, normalized);
    }
    if (!mounted) return;
    setState(() {
      _repoPathOverride = normalized;
    });
  }

  bool _looksLikeOpenpilotRepoUrl(String url) {
    return url.toLowerCase().contains('openpilot');
  }

  String _remoteDisplayName(String remoteName, String url) {
    final owner = _guessOwnerFromGitUrl(url);
    if (owner == null || owner.isEmpty) return remoteName;
    if (remoteName == owner) return owner;
    return '$remoteName ($owner)';
  }

  String? _guessOwnerFromGitUrl(String url) {
    final normalized = url.trim();
    if (normalized.isEmpty) return null;
    final sshMatch = RegExp(r'^[^@]+@[^:]+:([^/]+)/').firstMatch(normalized);
    if (sshMatch != null) return sshMatch.group(1);
    final sshScheme =
        RegExp(r'^ssh://[^@]+@[^/]+/([^/]+)/').firstMatch(normalized);
    if (sshScheme != null) return sshScheme.group(1);
    final httpUri = Uri.tryParse(normalized);
    if (httpUri != null && httpUri.pathSegments.length >= 2) {
      return httpUri.pathSegments[0];
    }
    return null;
  }

  String? _toBrowserRepoUrl(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw.endsWith('.git') ? raw.substring(0, raw.length - 4) : raw;
    }
    final sshMatch = RegExp(r'^[^@]+@([^:]+):(.+)$').firstMatch(raw);
    if (sshMatch != null) {
      final host = sshMatch.group(1)!;
      var path = sshMatch.group(2)!;
      if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
      return 'https://$host/$path';
    }
    final sshUri = Uri.tryParse(raw);
    if (sshUri != null &&
        sshUri.scheme == 'ssh' &&
        sshUri.host.isNotEmpty &&
        sshUri.pathSegments.length >= 2) {
      final owner = sshUri.pathSegments[0];
      var repo = sshUri.pathSegments[1];
      if (repo.endsWith('.git')) repo = repo.substring(0, repo.length - 4);
      return 'https://${sshUri.host}/$owner/$repo';
    }
    return null;
  }

  _RepoLinkSpec? _parseRepoLink(String input) {
    var raw = input.trim();
    if (raw.isEmpty) return null;

    if (RegExp(r'^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$').hasMatch(raw)) {
      raw = 'https://github.com/$raw';
    }

    final sshMatch =
        RegExp(r'^[^@]+@([^:]+):([^/]+)/([^/]+?)(?:\.git)?$').firstMatch(raw);
    if (sshMatch != null) {
      final host = sshMatch.group(1)!;
      final owner = sshMatch.group(2)!;
      final repo = sshMatch.group(3)!;
      return _RepoLinkSpec(
        repoUrl: 'https://$host/$owner/$repo',
        owner: owner,
        repo: repo,
      );
    }

    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.pathSegments.length < 2) return null;

    final owner = uri.pathSegments[0];
    var repo = uri.pathSegments[1];
    if (repo.endsWith('.git')) {
      repo = repo.substring(0, repo.length - 4);
    }
    if (owner.isEmpty || repo.isEmpty) return null;

    String? branch;
    if (uri.pathSegments.length >= 4 && uri.pathSegments[2] == 'tree') {
      final branchSegments = uri.pathSegments.sublist(3);
      if (branchSegments.isNotEmpty) {
        branch = branchSegments.join('/');
      }
    }

    return _RepoLinkSpec(
      repoUrl: 'https://${uri.host}/$owner/$repo',
      owner: owner,
      repo: repo,
      branch: (branch ?? '').trim().isEmpty ? null : branch,
    );
  }

  String _makeRemoteNameCandidate(String owner) {
    var value = owner.trim().toLowerCase();
    value = value.replaceAll(RegExp(r'[^a-z0-9._-]'), '_');
    if (value.isEmpty) value = 'remote';
    if (value == 'origin') value = 'origin_alt';
    return value;
  }

  String _pickBranchForRemote(
    GitBranchSnapshot snapshot,
    String remoteName, {
    String? preferredBranch,
  }) {
    final remoteBranches = snapshot.branches
        .where((b) => (b['remote'] ?? '') == remoteName)
        .map((b) => (b['name'] ?? '').trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (remoteBranches.isEmpty) return '';

    final preferred = (preferredBranch ?? '').trim();
    if (preferred.isNotEmpty && remoteBranches.contains(preferred)) {
      return preferred;
    }

    final current = snapshot.currentBranch.trim();
    if (current.isNotEmpty && remoteBranches.contains(current)) {
      return current;
    }

    final defaultBranch = snapshot.defaultBranch.trim();
    if (defaultBranch.isNotEmpty && remoteBranches.contains(defaultBranch)) {
      return defaultBranch;
    }

    return remoteBranches.first;
  }

  Future<void> _quickSetupFromRepoLink() async {
    final initial = (_gitSnapshot?.originUrl.isNotEmpty ?? false)
        ? _gitSnapshot!.originUrl
        : ((_gitSnapshot?.repoUrl ?? '').trim());
    final controller = TextEditingController(text: initial);
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("소스 링크 자동 설정"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "기본 소스(origin)는 유지하고, 링크 저장소를 추가 소스로 등록합니다.\n브랜치 링크(/tree/...)면 해당 브랜치 전환/업데이트 기준 설정도 자동 시도합니다.",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "GitHub 링크",
                hintText: "https://github.com/jominki354/openpilot",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text("자동 설정"),
          ),
        ],
      ),
    );

    final raw = (input ?? '').trim();
    if (raw.isEmpty) return;

    final spec = _parseRepoLink(raw);
    if (spec == null) {
      if (!mounted) return;
      CustomToast.show(context, "지원하지 않는 링크 형식입니다.", isError: true);
      return;
    }

    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      if (!mounted) return;
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    if (!_looksLikeOpenpilotRepoUrl(spec.repoUrl)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("확인 필요"),
          content: const Text("입력한 링크가 openpilot 저장소로 보이지 않습니다. 계속할까요?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("취소"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("계속"),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _isLoadingSourceInfo = true;
      });
    }

    try {
      final remoteName = _makeRemoteNameCandidate(spec.owner);
      _addLog("소스 자동 추가 시작: ${spec.repoUrl} (remote=$remoteName)");

      final remoteResult = await _actionService.upsertGitRemote(
        ssh,
        remoteName: remoteName,
        remoteUrl: spec.repoUrl,
        preferredRepoPath: _preferredRepoPath,
      );
      final remoteOutput = [remoteResult.stdout, remoteResult.stderr]
          .where((e) => e.trim().isNotEmpty)
          .join('\n');
      if (remoteOutput.trim().isNotEmpty) {
        _addLog(remoteOutput.trim());
      }
      if (!remoteResult.ok) {
        throw Exception("소스 추가/수정 실패");
      }

      var snapshot = await _actionService.loadGitBranchSnapshot(
        ssh,
        preferredRepoPath: _preferredRepoPath,
      );
      if (!mounted) return;
      setState(() {
        _gitSnapshot = snapshot;
      });

      // 브랜치 링크일 때만 자동 전환 시도. 일반 저장소 링크는 소스 추가만 수행.
      final targetBranch = spec.branch == null
          ? ''
          : _pickBranchForRemote(
              snapshot,
              remoteName,
              preferredBranch: spec.branch,
            );

      if (targetBranch.isNotEmpty) {
        final checkoutResult = await _actionService.runAction(
          ssh,
          DeviceActionType.gitCheckout,
          branch: targetBranch,
          remote: remoteName,
          repoPathOverride: _preferredRepoPath,
        );
        if (checkoutResult.output.trim().isNotEmpty) {
          _addLog(checkoutResult.output.trim());
        }
        if (!checkoutResult.ok) {
          throw Exception("브랜치 전환 실패: $remoteName/$targetBranch");
        }

        final upstreamResult = await _actionService.setCurrentBranchUpstream(
          ssh,
          remoteName: remoteName,
          remoteBranch: targetBranch,
          preferredRepoPath: _preferredRepoPath,
        );
        if (upstreamResult.output.trim().isNotEmpty) {
          _addLog(upstreamResult.output.trim());
        }

        snapshot = await _actionService.loadGitBranchSnapshot(
          ssh,
          preferredRepoPath: _preferredRepoPath,
        );
        if (mounted) {
          setState(() {
            _gitSnapshot = snapshot;
          });
        }
        if (!mounted) return;
        CustomToast.show(
          context,
          "소스 추가 완료: $remoteName / 브랜치 전환: $remoteName/$targetBranch",
        );
      } else {
        if (!mounted) return;
        CustomToast.show(context, "소스 추가 완료: $remoteName (origin 유지)");
      }
    } catch (e) {
      if (!mounted) return;
      _addLog("자동 설정 실패: $e");
      CustomToast.show(context, "자동 설정 실패: $e", isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingSourceInfo = false;
        });
      }
    }
  }

  Future<void> _showAdvancedGitSettingsSheet() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: false,
      builder: (sheetCtx) {
        Future<void> run(_GitToolsMenuAction action) async {
          Navigator.pop(sheetCtx);
          if (!mounted) return;
          await _handleGitToolsMenuAction(action);
        }

        return SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                dense: true,
                title: Text(
                  "고급 Git 설정",
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text("기본 소스 변경"),
                subtitle: const Text("origin URL 변경"),
                onTap: () => run(_GitToolsMenuAction.changeOrigin),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text("코드 폴더 위치"),
                subtitle: const Text("openpilot 외 저장소 경로 지정"),
                onTap: () => run(_GitToolsMenuAction.setRepoPath),
              ),
              if (_repoPathOverride.trim().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text("코드 폴더 자동탐색"),
                  subtitle: const Text("수동 경로 설정 해제"),
                  onTap: () => run(_GitToolsMenuAction.clearRepoPath),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.add_link),
                title: const Text("소스 추가"),
                onTap: () => run(_GitToolsMenuAction.addRemote),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text("소스 수정"),
                onTap: () => run(_GitToolsMenuAction.editRemote),
              ),
              ListTile(
                leading: const Icon(Icons.link_off),
                title: const Text("소스 삭제"),
                onTap: () => run(_GitToolsMenuAction.deleteRemote),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.call_split),
                title: const Text("업데이트 기준 변경"),
                subtitle: const Text("현재 브랜치의 upstream 지정"),
                onTap: () => run(_GitToolsMenuAction.setUpstream),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showGitDetailsSheet() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      if (!mounted) return;
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    if (_gitSnapshot == null && !_isLoadingSourceInfo) {
      await _refreshGitSourceInfo();
    }
    if (!mounted) return;
    final snapshot = _gitSnapshot;
    if (snapshot == null) {
      CustomToast.show(context, "Git 상세정보를 불러오지 못했습니다.", isError: true);
      return;
    }

    final effectiveUrl =
        (snapshot.originUrl.isNotEmpty ? snapshot.originUrl : snapshot.repoUrl)
            .trim();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) {
        final color = Theme.of(sheetCtx).colorScheme;
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.78,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                const Text(
                  "현재 Git 상세정보",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                _detailTile("기본 소스(origin)",
                    snapshot.originUrl.isEmpty ? "-" : snapshot.originUrl),
                _detailTile(
                    "현재 브랜치",
                    snapshot.currentBranch.isEmpty
                        ? "-"
                        : snapshot.currentBranch),
                _detailTile("업데이트 기준",
                    snapshot.upstreamRef.isEmpty ? "-" : snapshot.upstreamRef),
                _detailTile("코드 폴더", snapshot.repoPath),
                _detailTile(
                  "설정한 폴더",
                  _repoPathOverride.trim().isEmpty
                      ? "(자동탐색)"
                      : _repoPathOverride.trim(),
                ),
                _detailTile(
                  "탐색 결과",
                  snapshot.repoPathSource.isEmpty
                      ? "-"
                      : snapshot.repoPathSource,
                ),
                if (!snapshot.hasOriginRemote)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      "origin이 없어 '${snapshot.primaryRemoteName.isEmpty ? '첫 번째 소스' : snapshot.primaryRemoteName}' 기준으로 표시 중",
                      style: TextStyle(
                        fontSize: 11,
                        color: color.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  "소스 목록 (${snapshot.remotes.length})",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: color.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                if (snapshot.remotes.isEmpty)
                  const Text(
                    "소스 없음",
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  )
                else
                  ...snapshot.remotes.map(
                    (remote) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        remote.name == 'origin'
                            ? Icons.link
                            : Icons.link_outlined,
                        size: 18,
                      ),
                      title: Text(
                        _remoteDisplayName(remote.name, remote.fetchUrl),
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        (remote.fetchUrl.isNotEmpty
                                    ? remote.fetchUrl
                                    : remote.pushUrl)
                                .isEmpty
                            ? "-"
                            : (remote.fetchUrl.isNotEmpty
                                ? remote.fetchUrl
                                : remote.pushUrl),
                        style: const TextStyle(fontSize: 11),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                if (effectiveUrl.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.pop(sheetCtx);
                          if (!mounted) return;
                          await _openCurrentRepoInBrowser();
                        },
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text("소스 열기"),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.pop(sheetCtx);
                          if (!mounted) return;
                          await _refreshGitSourceInfo();
                        },
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text("새로고침"),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshGitSourceInfo({bool silent = false}) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      if (!silent && mounted) {
        CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      }
      return;
    }

    if (mounted) {
      setState(() => _isLoadingSourceInfo = true);
    }
    try {
      final snapshot = await _actionService.loadGitBranchSnapshot(
        ssh,
        preferredRepoPath: _preferredRepoPath,
      );
      if (!mounted) return;
      setState(() {
        _gitSnapshot = snapshot;
      });
      if (!snapshot.hasOriginRemote && !silent) {
        CustomToast.show(
          context,
          "origin 리모트가 없어 첫 번째 리모트를 기준으로 표시합니다.",
          isError: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        CustomToast.show(context, "Git 정보 로드 실패: $e", isError: true);
      }
      _addLog("Git 정보 로드 실패: $e");
    } finally {
      if (mounted) {
        setState(() => _isLoadingSourceInfo = false);
      }
    }
  }

  Future<void> _openCurrentRepoInBrowser() async {
    final snapshot = _gitSnapshot;
    if (snapshot == null) return;
    final raw =
        (snapshot.originUrl.isNotEmpty ? snapshot.originUrl : snapshot.repoUrl)
            .trim();
    final browserUrl = _toBrowserRepoUrl(raw);
    if (browserUrl == null) {
      CustomToast.show(context, "브라우저로 열 수 없는 URL 형식입니다.", isError: true);
      return;
    }
    final uri = Uri.tryParse(browserUrl);
    if (uri == null) {
      CustomToast.show(context, "브라우저 URL 생성 실패", isError: true);
      return;
    }
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("원격 저장소 URL"),
        content: SelectableText(browserUrl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("닫기"),
          ),
        ],
      ),
    );
  }

  Future<void> _changeOriginRemoteUrl() async {
    final snapshot = _gitSnapshot;
    final initialUrl = snapshot == null
        ? ''
        : (snapshot.originUrl.isNotEmpty
            ? snapshot.originUrl
            : snapshot.repoUrl);
    final controller = TextEditingController(text: initialUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("원격 저장소(origin) 변경"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "예: https://github.com/ajouatom/openpilot 또는 git@github.com:ajouatom/openpilot.git",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "origin URL",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text("적용"),
          ),
        ],
      ),
    );

    final nextUrl = (value ?? '').trim();
    if (nextUrl.isEmpty || nextUrl == initialUrl.trim()) return;

    if (!_looksLikeOpenpilotRepoUrl(nextUrl)) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("확인 필요"),
          content: const Text(
            "입력한 URL이 openpilot 저장소로 보이지 않습니다.\n그래도 origin으로 설정할까요?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("취소"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("계속"),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    setState(() => _isLoadingSourceInfo = true);
    try {
      final result = await _actionService.setGitOriginRemote(
        ssh,
        nextUrl,
        preferredRepoPath: _preferredRepoPath,
      );
      _addLog("origin 변경: ${result.effectiveOriginUrl}");
      if (result.stdout.trim().isNotEmpty) _addLog(result.stdout.trim());
      if (result.stderr.trim().isNotEmpty) _addLog(result.stderr.trim());
      if (!mounted) return;
      if (!result.ok) {
        CustomToast.show(context, "origin 변경 실패", isError: true);
      } else if (!result.fetchSucceeded) {
        CustomToast.show(
          context,
          "origin은 변경됨, fetch 확인 실패(URL/권한 확인 필요)",
          isError: true,
        );
      } else {
        CustomToast.show(context, "origin 변경 및 fetch 확인 완료");
      }
      await _refreshGitSourceInfo(silent: true);
    } catch (e) {
      if (!mounted) return;
      _addLog("origin 변경 실패: $e");
      CustomToast.show(context, "origin 변경 실패: $e", isError: true);
    } finally {
      if (mounted) {
        setState(() => _isLoadingSourceInfo = false);
      }
    }
  }

  Future<void> _runGitAction(
    BuildContext context,
    DeviceActionType action,
    String successMessage, {
    String? branch,
    String? remote,
  }) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    setState(() => _isLoading = true);
    final actionLabel = successMessage.replaceAll(' 완료', '').trim();
    _addLog("명령 실행: $actionLabel");

    try {
      final result = await _actionService.runAction(
        ssh,
        action,
        branch: branch,
        remote: remote,
        repoPathOverride: _preferredRepoPath,
      );
      if (!mounted) return;

      if (result.output.trim().isNotEmpty) {
        _addLog(result.output.trim());
      }
      if (result.ok && result.output.trim().isEmpty) {
        _addLog("완료");
      }

      if (result.ok) {
        CustomToast.show(context, successMessage);
        if (action == DeviceActionType.gitCheckout ||
            action == DeviceActionType.gitPull ||
            action == DeviceActionType.gitSync ||
            action == DeviceActionType.gitResetHardClean) {
          unawaited(_refreshGitSourceInfo(silent: true));
        }
      } else {
        CustomToast.show(
          context,
          "${successMessage.replaceAll("완료", "실패")} (code: ${result.exitCode})",
          isError: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      _addLog("오류: $e");
      CustomToast.show(context, "명령 실행 실패: $e", isError: true);
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _rebootDevice(BuildContext context) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("기기 재부팅"),
        content: const Text("기기를 재부팅하시겠습니까?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("취소")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text("재부팅"),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      _addLog("기기 재부팅 중...");
      await _runGitAction(
        context,
        DeviceActionType.reboot,
        "재부팅 명령을 전송했습니다.",
      );
    }
  }

  Future<void> _selectBranch(BuildContext context) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    setState(() => _isLoading = true);
    _addLog("브랜치 목록 가져오는 중...");

    try {
      final snapshot = await _actionService.loadGitBranchSnapshot(
        ssh,
        preferredRepoPath: _preferredRepoPath,
      );

      setState(() => _isLoading = false);

      if (!mounted) return;
      setState(() {
        _gitSnapshot = snapshot;
      });
      final branches = snapshot.branches;
      final localRefs = snapshot.localRefs;

      showDialog(
        context: context,
        builder: (ctx) => _BranchListDialog(
          title: "브랜치 선택",
          branches: branches,
          defaultBranch: snapshot.defaultBranch,
          currentBranch: snapshot.currentBranch,
          localRefs: localRefs,
          repoUrl: snapshot.repoUrl,
          remotes: snapshot.remotes,
          currentUpstreamRemote: snapshot.upstreamRemote,
          onSelect: (remote, name) {
            Navigator.pop(ctx);
            _runGitAction(
              context,
              DeviceActionType.gitCheckout,
              "$remote/$name 브랜치로 변경됨",
              branch: name,
              remote: remote,
            );
          },
        ),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      _addLog("브랜치 목록 실패: $e");
    }
  }

  Future<void> _configureRepoPath() async {
    final controller = TextEditingController(text: _repoPathOverride);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("저장소 경로 설정"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "openpilot 외 저장소를 쓰는 경우 .git 폴더가 있는 경로를 입력하세요.\n예: /data/openpilot 또는 /data/myrepo",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "저장소 경로",
                hintText: "/data/openpilot",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text("자동탐색"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text("저장"),
          ),
        ],
      ),
    );

    if (result == null) return;
    final normalized = result.trim();
    if (normalized.isNotEmpty && !normalized.startsWith('/')) {
      if (!mounted) return;
      CustomToast.show(context, "리눅스 절대경로(/...) 형식으로 입력하세요.", isError: true);
      return;
    }
    if (normalized == _repoPathOverride.trim()) return;

    await _saveGitRepoPathOverride(normalized);
    if (!mounted) return;
    _addLog(
      normalized.isEmpty ? "저장소 경로 설정: 자동탐색" : "저장소 경로 설정: $normalized",
    );
    CustomToast.show(
        context, normalized.isEmpty ? "저장소 경로 자동탐색으로 변경" : "저장소 경로 저장됨");
    await _refreshGitSourceInfo();
  }

  Future<void> _addOrEditRemote({GitRemoteInfo? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final urlController = TextEditingController(
      text: existing == null
          ? ''
          : (existing.fetchUrl.isNotEmpty
              ? existing.fetchUrl
              : existing.pushUrl),
    );
    final payload = await showDialog<({String name, String url})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? "리모트 추가" : "리모트 수정"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: existing == null,
              enabled: existing == null,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "리모트 이름",
                hintText: "origin / jominki354",
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              autofocus: existing != null,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "리모트 URL",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소"),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(
                ctx,
                (
                  name: nameController.text.trim(),
                  url: urlController.text.trim(),
                ),
              );
            },
            child: const Text("적용"),
          ),
        ],
      ),
    );
    if (payload == null) return;

    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    setState(() => _isLoadingSourceInfo = true);
    try {
      final result = await _actionService.upsertGitRemote(
        ssh,
        remoteName: payload.name,
        remoteUrl: payload.url,
        preferredRepoPath: _preferredRepoPath,
      );
      _addLog("${existing == null ? '리모트 추가' : '리모트 수정'}: ${payload.name}");
      if (result.output.trim().isNotEmpty) _addLog(result.output.trim());
      if (!mounted) return;
      if (result.ok) {
        CustomToast.show(context, "리모트 ${existing == null ? '추가' : '수정'} 완료");
      } else {
        CustomToast.show(context, "리모트 ${existing == null ? '추가' : '수정'} 실패",
            isError: true);
      }
      await _refreshGitSourceInfo(silent: true);
    } catch (e) {
      if (!mounted) return;
      _addLog("리모트 ${existing == null ? '추가' : '수정'} 실패: $e");
      CustomToast.show(context, "리모트 설정 실패: $e", isError: true);
    } finally {
      if (mounted) setState(() => _isLoadingSourceInfo = false);
    }
  }

  Future<void> _removeRemote() async {
    final snapshot = _gitSnapshot;
    if (snapshot == null || snapshot.remotes.isEmpty) {
      CustomToast.show(context, "삭제할 리모트가 없습니다.", isError: true);
      return;
    }
    final target = await showDialog<GitRemoteInfo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text("리모트 삭제"),
        children: [
          for (final remote in snapshot.remotes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, remote),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(remote.name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (remote.fetchUrl.isNotEmpty)
                    Text(remote.fetchUrl,
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
        ],
      ),
    );
    if (target == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("리모트 삭제"),
        content: Text("'${target.name}' 리모트를 삭제할까요?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("취소")),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("삭제")),
        ],
      ),
    );
    if (confirm != true) return;

    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }
    setState(() => _isLoadingSourceInfo = true);
    try {
      final result = await _actionService.removeGitRemote(
        ssh,
        remoteName: target.name,
        preferredRepoPath: _preferredRepoPath,
      );
      _addLog("리모트 삭제: ${target.name}");
      if (result.output.trim().isNotEmpty) _addLog(result.output.trim());
      if (!mounted) return;
      CustomToast.show(context, result.ok ? "리모트 삭제 완료" : "리모트 삭제 실패",
          isError: !result.ok);
      await _refreshGitSourceInfo(silent: true);
    } catch (e) {
      if (!mounted) return;
      _addLog("리모트 삭제 실패: $e");
      CustomToast.show(context, "리모트 삭제 실패: $e", isError: true);
    } finally {
      if (mounted) setState(() => _isLoadingSourceInfo = false);
    }
  }

  Future<void> _selectRemoteToEdit() async {
    final snapshot = _gitSnapshot;
    if (snapshot == null || snapshot.remotes.isEmpty) {
      await _addOrEditRemote();
      return;
    }
    final picked = await showDialog<GitRemoteInfo?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text("리모트 수정"),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text("+ 새 리모트 추가"),
          ),
          ...snapshot.remotes.map(
            (remote) => SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, remote),
              child: Text(_remoteDisplayName(remote.name, remote.fetchUrl)),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await _addOrEditRemote(existing: picked);
  }

  Future<void> _setUpstreamForCurrentBranch() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    setState(() => _isLoading = true);
    try {
      final snapshot = await _actionService.loadGitBranchSnapshot(
        ssh,
        preferredRepoPath: _preferredRepoPath,
      );
      if (!mounted) return;
      setState(() {
        _gitSnapshot = snapshot;
        _isLoading = false;
      });

      await showDialog(
        context: context,
        builder: (ctx) => _BranchListDialog(
          title: "업스트림 지정",
          branches: snapshot.branches,
          defaultBranch: snapshot.defaultBranch,
          currentBranch: snapshot.currentBranch,
          currentUpstreamRemote: snapshot.upstreamRemote,
          localRefs: snapshot.localRefs,
          repoUrl: snapshot.repoUrl,
          remotes: snapshot.remotes,
          onSelect: (remote, name) async {
            Navigator.pop(ctx);
            setState(() => _isLoadingSourceInfo = true);
            try {
              final result = await _actionService.setCurrentBranchUpstream(
                ssh,
                remoteName: remote,
                remoteBranch: name,
                preferredRepoPath: _preferredRepoPath,
              );
              _addLog("업스트림 지정: ${snapshot.currentBranch} -> $remote/$name");
              if (result.output.trim().isNotEmpty)
                _addLog(result.output.trim());
              if (!mounted) return;
              CustomToast.show(context, result.ok ? "업스트림 지정 완료" : "업스트림 지정 실패",
                  isError: !result.ok);
              await _refreshGitSourceInfo(silent: true);
            } catch (e) {
              if (!mounted) return;
              _addLog("업스트림 지정 실패: $e");
              CustomToast.show(context, "업스트림 지정 실패: $e", isError: true);
            } finally {
              if (mounted) setState(() => _isLoadingSourceInfo = false);
            }
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _addLog("업스트림 지정용 브랜치 목록 실패: $e");
      CustomToast.show(context, "브랜치 목록 로드 실패: $e", isError: true);
    }
  }

  Future<void> _handleGitToolsMenuAction(_GitToolsMenuAction action) async {
    switch (action) {
      case _GitToolsMenuAction.quickSetupFromLink:
        await _quickSetupFromRepoLink();
        break;
      case _GitToolsMenuAction.showDetails:
        await _showGitDetailsSheet();
        break;
      case _GitToolsMenuAction.clearLogs:
        await _clearLogs();
        break;
      case _GitToolsMenuAction.advancedSettings:
        await _showAdvancedGitSettingsSheet();
        break;
      case _GitToolsMenuAction.changeOrigin:
        await _changeOriginRemoteUrl();
        break;
      case _GitToolsMenuAction.setRepoPath:
        await _configureRepoPath();
        break;
      case _GitToolsMenuAction.clearRepoPath:
        await _saveGitRepoPathOverride('');
        if (!mounted) return;
        _addLog("저장소 경로 설정: 자동탐색");
        CustomToast.show(context, "저장소 경로 자동탐색으로 변경");
        await _refreshGitSourceInfo();
        break;
      case _GitToolsMenuAction.addRemote:
        await _addOrEditRemote();
        break;
      case _GitToolsMenuAction.editRemote:
        await _selectRemoteToEdit();
        break;
      case _GitToolsMenuAction.deleteRemote:
        await _removeRemote();
        break;
      case _GitToolsMenuAction.setUpstream:
        await _setUpstreamForCurrentBranch();
        break;
    }
  }

  Future<void> _performGitSync(BuildContext context) async {
    await _runGitAction(context, DeviceActionType.gitSync, "Git Sync 완료");
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              children: [
                Expanded(
                  child: DesignCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.terminal,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "Git 로그",
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const Spacer(),
                            if (_isLoading)
                              const Padding(
                                padding: EdgeInsets.only(right: 8.0),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            PopupMenuButton<_GitToolsMenuAction>(
                              tooltip: "Git 옵션",
                              enabled: !(_isLoading || _isLoadingSourceInfo),
                              icon: const Icon(Icons.settings, size: 20),
                              onSelected: _handleGitToolsMenuAction,
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: _GitToolsMenuAction.quickSetupFromLink,
                                  child: Text("소스 링크 자동 설정"),
                                ),
                                const PopupMenuDivider(),
                                const PopupMenuItem(
                                  value: _GitToolsMenuAction.showDetails,
                                  child: Text("현재 Git 상세정보"),
                                ),
                                const PopupMenuDivider(),
                                const PopupMenuItem(
                                  value: _GitToolsMenuAction.clearLogs,
                                  child: Text("로그 지우기"),
                                ),
                                const PopupMenuDivider(),
                                const PopupMenuItem(
                                  value: _GitToolsMenuAction.advancedSettings,
                                  child: Text("고급 Git 설정"),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: Colors.grey.withValues(alpha: 0.2)),
                            ),
                            child: ListView.builder(
                              controller: _scrollController,
                              itemCount: _logs.length,
                              itemBuilder: (context, index) {
                                final log = _logs[index];
                                final isOld = log['isOld'] == 'true';
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 2.0),
                                  child: RichText(
                                    text: TextSpan(
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        color:
                                            isOld ? Colors.grey : Colors.white,
                                      ),
                                      children: [
                                        TextSpan(
                                          text: "[${log['time']}] ",
                                          style: TextStyle(
                                            color: isOld
                                                ? Colors.grey[600]
                                                : Colors.greenAccent,
                                          ),
                                        ),
                                        TextSpan(text: log['message']),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Bottom Section: Fixed Buttons
        Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                offset: const Offset(0, -2),
                blurRadius: 8,
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 2.8,
                  children: [
                    _buildActionButton(
                      context,
                      "브랜치 선택",
                      Icons.list,
                      Colors.blue,
                      () => _selectBranch(context),
                    ),
                    _buildActionButton(
                      context,
                      "Git Pull",
                      Icons.download,
                      Colors.green,
                      () => _runGitAction(
                        context,
                        DeviceActionType.gitPull,
                        "Git Pull 완료",
                      ),
                    ),
                    _buildActionButton(
                      context,
                      "Git Reset",
                      Icons.restore,
                      Colors.orange,
                      () => _runGitAction(
                        context,
                        DeviceActionType.gitResetHardClean,
                        "Git Reset 완료",
                      ),
                    ),
                    _buildActionButton(
                      context,
                      "Git Sync",
                      Icons.sync,
                      Colors.red,
                      () => _performGitSync(context),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildActionButton(
                  context,
                  "Reboot",
                  Icons.restart_alt,
                  Colors.red,
                  () => _rebootDevice(context),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(BuildContext context, String label, IconData icon,
      Color color, VoidCallback onTap) {
    return FilledButton.icon(
      onPressed: _isLoading ? null : onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: color.withOpacity(0.15),
        foregroundColor: color,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color.withOpacity(0.3)),
        ),
      ),
    );
  }
}

class _BranchListDialog extends StatefulWidget {
  final String title;
  final List<Map<String, String>> branches;
  final String defaultBranch;
  final String currentBranch;
  final String currentUpstreamRemote;
  final Map<String, String> localRefs;
  final String repoUrl;
  final List<GitRemoteInfo> remotes;
  final void Function(String remote, String branch) onSelect;

  const _BranchListDialog({
    required this.title,
    required this.branches,
    required this.defaultBranch,
    required this.currentBranch,
    required this.currentUpstreamRemote,
    required this.localRefs,
    required this.repoUrl,
    required this.remotes,
    required this.onSelect,
  });

  @override
  State<_BranchListDialog> createState() => _BranchListDialogState();
}

class _BranchListDialogState extends State<_BranchListDialog> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  late List<_BranchListRow> _rows;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _rows = _buildRows();
    _searchController.addListener(_handleSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rowIndex = _rows.indexWhere((r) =>
          r.branch != null &&
          r.branch!['name'] == widget.currentBranch &&
          ((r.branch!['remote'] ?? '') == widget.currentUpstreamRemote ||
              widget.currentUpstreamRemote.isEmpty));
      if (rowIndex != -1 && _scrollController.hasClients) {
        final offset = rowIndex * 64.0;
        // Clamp offset to maxScrollExtent
        final maxScroll = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(offset.clamp(0.0, maxScroll));
      }
    });
  }

  void _handleSearchChanged() {
    final next = _searchController.text.trim();
    if (next == _query) return;
    setState(() {
      _query = next;
      _rows = _buildRows(query: next);
    });
  }

  List<_BranchListRow> _buildRows({String query = ''}) {
    final grouped = <String, List<Map<String, String>>>{};
    final q = query.trim().toLowerCase();
    for (final branch in widget.branches) {
      final remote = (branch['remote'] ?? '').trim().isEmpty
          ? 'origin'
          : branch['remote']!.trim();
      final branchName = (branch['name'] ?? '').toLowerCase();
      if (q.isNotEmpty) {
        final remoteLabel = _remoteLabel(remote).toLowerCase();
        final owner = (_guessOwnerFromRemoteName(remote) ?? '').toLowerCase();
        final fullName = ('$remote/${branch['name'] ?? ''}').toLowerCase();
        final matched = branchName.contains(q) ||
            remote.toLowerCase().contains(q) ||
            remoteLabel.contains(q) ||
            owner.contains(q) ||
            fullName.contains(q);
        if (!matched) continue;
      }
      grouped.putIfAbsent(remote, () => <Map<String, String>>[]).add(branch);
    }

    final remoteOrder = <String>[
      ...widget.remotes.map((e) => e.name),
      ...grouped.keys.where((k) => !widget.remotes.any((e) => e.name == k)),
    ].toSet().toList();

    final rows = <_BranchListRow>[];
    for (final remote in remoteOrder) {
      final entries = grouped[remote];
      if (entries == null || entries.isEmpty) continue;
      rows.add(_BranchListRow.header(remote));
      for (final branch in entries) {
        rows.add(_BranchListRow.branch(branch));
      }
    }
    return rows;
  }

  String _remoteLabel(String remote) {
    GitRemoteInfo? info;
    for (final remoteInfo in widget.remotes) {
      if (remoteInfo.name == remote) {
        info = remoteInfo;
        break;
      }
    }
    if (info == null) return remote;
    final url = info.fetchUrl;
    final owner = _guessOwner(url);
    if (owner == null || owner.isEmpty) return remote;
    if (owner == remote) return owner;
    return '$remote ($owner)';
  }

  String? _guessOwner(String url) {
    final sshMatch = RegExp(r'^[^@]+@[^:]+:([^/]+)/').firstMatch(url);
    if (sshMatch != null) return sshMatch.group(1);
    final uri = Uri.tryParse(url);
    if (uri != null && uri.pathSegments.length >= 2) {
      return uri.pathSegments[0];
    }
    return null;
  }

  String? _guessOwnerFromRemoteName(String remoteName) {
    for (final remote in widget.remotes) {
      if (remote.name == remoteName) {
        return _guessOwner(remote.fetchUrl);
      }
    }
    return null;
  }

  String? _browserRepoUrlForRemote(String remote) {
    GitRemoteInfo? remoteInfo;
    for (final info in widget.remotes) {
      if (info.name == remote) {
        remoteInfo = info;
        break;
      }
    }
    final raw = remoteInfo?.fetchUrl ?? widget.repoUrl;
    if (raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw.endsWith('.git') ? raw.substring(0, raw.length - 4) : raw;
    }
    final sshMatch = RegExp(r'^[^@]+@([^:]+):(.+)$').firstMatch(raw);
    if (sshMatch != null) {
      final host = sshMatch.group(1)!;
      var path = sshMatch.group(2)!;
      if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
      return 'https://$host/$path';
    }
    return null;
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        height: 480,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: "브랜치/제작자(remote) 검색",
                isDense: true,
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: "지우기",
                        onPressed: _searchController.clear,
                        icon: const Icon(Icons.close, size: 18),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _rows.isEmpty
                  ? const Center(
                      child: Text(
                        "검색 결과가 없습니다.",
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      shrinkWrap: true,
                      itemCount: _rows.length,
                      itemBuilder: (ctx, index) {
                        final row = _rows[index];
                        if (row.isHeader) {
                          final remote = row.header!;
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
                            child: Row(
                              children: [
                                Icon(Icons.account_tree_outlined,
                                    size: 16,
                                    color:
                                        Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 6),
                                Text(
                                  _remoteLabel(remote),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        final branch = row.branch!;
                        final name = branch['name']!;
                        final remote = branch['remote'] ?? 'origin';
                        final date = branch['date']!;
                        final hash = branch['hash']!;
                        final isDefault = name == widget.defaultBranch;
                        final isCurrent = name == widget.currentBranch &&
                            (widget.currentUpstreamRemote.isEmpty ||
                                widget.currentUpstreamRemote == remote);

                        bool hasUpdate = false;
                        if (widget.localRefs.containsKey(name)) {
                          if (widget.localRefs[name] != hash) {
                            hasUpdate = true;
                          }
                        }

                        return ListTile(
                          tileColor: isCurrent
                              ? Theme.of(context).colorScheme.secondaryContainer
                              : null,
                          title: Row(
                            children: [
                              Text(name,
                                  style: TextStyle(
                                      fontWeight: isDefault
                                          ? FontWeight.bold
                                          : FontWeight.normal)),
                              if (isDefault) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text("Default",
                                      style: TextStyle(
                                          fontSize: 10, color: Colors.blue)),
                                ),
                              ],
                              if (isCurrent) ...[
                                const SizedBox(width: 8),
                                const Icon(Icons.check,
                                    size: 16, color: Colors.green),
                              ],
                            ],
                          ),
                          subtitle: Text(date,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                          trailing: hasUpdate
                              ? IconButton(
                                  icon: const Icon(Icons.priority_high,
                                      color: Colors.red, size: 20),
                                  tooltip: "업데이트 가능",
                                  onPressed: () async {
                                    if (widget.repoUrl.isNotEmpty) {
                                      final baseUrl =
                                          _browserRepoUrlForRemote(remote);
                                      if (baseUrl == null || baseUrl.isEmpty)
                                        return;
                                      final url = "$baseUrl/commits/$name";
                                      final uri = Uri.parse(url);
                                      if (await canLaunchUrl(uri)) {
                                        await launchUrl(uri,
                                            mode:
                                                LaunchMode.externalApplication);
                                      } else {
                                        if (context.mounted) {
                                          showDialog(
                                            context: context,
                                            builder: (_) => AlertDialog(
                                              title: const Text("커밋 내역"),
                                              content: SelectableText(url),
                                              actions: [
                                                TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(context),
                                                    child: const Text("닫기"))
                                              ],
                                            ),
                                          );
                                        }
                                      }
                                    }
                                  },
                                )
                              : null,
                          onTap: () => widget.onSelect(remote, name),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("닫기"),
        ),
      ],
    );
  }
}

class _BranchListRow {
  final String? header;
  final Map<String, String>? branch;

  const _BranchListRow._({
    this.header,
    this.branch,
  });

  const _BranchListRow.header(String value)
      : this._(header: value, branch: null);
  const _BranchListRow.branch(Map<String, String> value)
      : this._(header: null, branch: value);

  bool get isHeader => header != null;
}
