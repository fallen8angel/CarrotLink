import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../services/ssh_service.dart';
import '../../widgets/connection_required_view.dart';
import '../../services/device_action_service.dart';
import '../../widgets/custom_toast.dart';

enum _GitToolsMenuAction {
  quickSetupFromLink,
  showDetails,
  logDisplaySettings,
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
  static const String _gitLogFontSizePtPrefKey = 'git_log_font_size_pt';
  static const String _gitLogWrapPrefKey = 'git_log_wrap';
  static const String _gitLogDimOldPrefKey = 'git_log_dim_old';
  static const String _gitLogAutoScrollPrefKey = 'git_log_auto_scroll';
  static const String _gitLogHighContrastPrefKey = 'git_log_high_contrast';
  static const String _gitLogEmphasisLevelPrefKey = 'git_log_emphasis_level';

  bool _isLoading = false;
  bool _isLoadingSourceInfo = false;
  List<Map<String, String>> _logs = [];
  final ScrollController _scrollController = ScrollController();
  final DeviceActionService _actionService = DeviceActionService();
  GitBranchSnapshot? _gitSnapshot;
  String _repoPathOverride = '';
  double _gitLogFontSizePt = 12.0;
  bool _gitLogWrap = true;
  bool _gitLogDimOld = true;
  bool _gitLogAutoScroll = true;
  int _gitLogEmphasisLevel = 0;

  String? get _preferredRepoPath {
    final trimmed = _repoPathOverride.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadLogViewSettings());
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
        if (_gitLogAutoScroll) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController
                  .jumpTo(_scrollController.position.maxScrollExtent);
            }
          });
        }
      } catch (e) {
        debugPrint("Error loading logs: $e");
      }
    }
  }

  Future<void> _loadLogViewSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _gitLogFontSizePt = prefs.getDouble(_gitLogFontSizePtPrefKey) ?? 12.0;
      _gitLogWrap = prefs.getBool(_gitLogWrapPrefKey) ?? true;
      _gitLogDimOld = prefs.getBool(_gitLogDimOldPrefKey) ?? true;
      _gitLogAutoScroll = prefs.getBool(_gitLogAutoScrollPrefKey) ?? true;
      final storedLevel = prefs.getInt(_gitLogEmphasisLevelPrefKey);
      if (storedLevel != null) {
        _gitLogEmphasisLevel = storedLevel.clamp(0, 2);
      } else {
        _gitLogEmphasisLevel =
            (prefs.getBool(_gitLogHighContrastPrefKey) ?? false) ? 1 : 0;
      }
    });
  }

  Future<void> _saveLogViewSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_gitLogFontSizePtPrefKey, _gitLogFontSizePt);
    await prefs.setBool(_gitLogWrapPrefKey, _gitLogWrap);
    await prefs.setBool(_gitLogDimOldPrefKey, _gitLogDimOld);
    await prefs.setBool(_gitLogAutoScrollPrefKey, _gitLogAutoScroll);
    await prefs.setInt(_gitLogEmphasisLevelPrefKey, _gitLogEmphasisLevel);
    await prefs.setBool(_gitLogHighContrastPrefKey, _gitLogEmphasisLevel > 0);
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
    if (_gitLogAutoScroll) {
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

  ({
    EdgeInsets insetPadding,
    EdgeInsets contentPadding,
    double hintFontSize,
    double bodyFontSize,
    double titleFontSize,
    double gapSmall,
    double gapMedium,
    double maxContentWidth,
  }) _dialogMetrics(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final insetHorizontal = window.isCompact
        ? 16.0
        : tokens.screenPadding.clamp(16.0, 30.0).toDouble();
    final insetVertical = switch (window.windowClass) {
      UiWindowClass.compact => 22.0,
      UiWindowClass.medium => 24.0,
      UiWindowClass.expanded => 26.0,
      UiWindowClass.large => 28.0,
      UiWindowClass.extraLarge => 30.0,
    };
    final contentPaddingValue = switch (window.windowClass) {
      UiWindowClass.compact => 16.0,
      UiWindowClass.medium => 18.0,
      UiWindowClass.expanded => 20.0,
      UiWindowClass.large => 22.0,
      UiWindowClass.extraLarge => 24.0,
    };
    final hintFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 13.0,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };
    final bodyFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 13.0,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 14.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final titleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 18.0,
      UiWindowClass.medium => 18.0,
      UiWindowClass.expanded => 19.0,
      UiWindowClass.large => 20.0,
      UiWindowClass.extraLarge => 20.0,
    };
    final maxContentWidth = switch (window.windowClass) {
      UiWindowClass.compact => 420.0,
      UiWindowClass.medium => 470.0,
      UiWindowClass.expanded => 540.0,
      UiWindowClass.large => 600.0,
      UiWindowClass.extraLarge => 660.0,
    };

    return (
      insetPadding: EdgeInsets.symmetric(
        horizontal: insetHorizontal,
        vertical: insetVertical,
      ),
      contentPadding: EdgeInsets.fromLTRB(
        contentPaddingValue,
        12,
        contentPaddingValue,
        contentPaddingValue,
      ),
      hintFontSize: hintFontSize,
      bodyFontSize: bodyFontSize,
      titleFontSize: titleFontSize,
      gapSmall: 8.0,
      gapMedium: 12.0,
      maxContentWidth: maxContentWidth,
    );
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
    final dialogMetrics = _dialogMetrics(context);
    final initial = (_gitSnapshot?.originUrl.isNotEmpty ?? false)
        ? _gitSnapshot!.originUrl
        : ((_gitSnapshot?.repoUrl ?? '').trim());
    final controller = TextEditingController(text: initial);
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final metrics = _dialogMetrics(ctx);
        return AlertDialog(
          insetPadding: metrics.insetPadding,
          contentPadding: metrics.contentPadding,
          title: Text(
            "소스 링크 자동 설정",
            style: TextStyle(fontSize: metrics.titleFontSize),
          ),
          content: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "기본 소스(origin)는 유지하고, 링크 저장소를 추가 소스로 등록합니다.\n브랜치 링크(/tree/...)면 해당 브랜치 전환/업데이트 기준 설정도 자동 시도합니다.",
                  style: TextStyle(
                    fontSize: metrics.hintFontSize,
                    color: Colors.grey,
                  ),
                ),
                SizedBox(height: metrics.gapMedium),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 3,
                  minLines: 1,
                  style: TextStyle(fontSize: metrics.bodyFontSize),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: "GitHub 링크",
                    hintText: "https://github.com/jominki354/openpilot",
                  ),
                ),
              ],
            ),
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
        );
      },
    );

    final raw = (input ?? '').trim();
    if (raw.isEmpty) return;

    final spec = _parseRepoLink(raw);
    if (spec == null) {
      if (!mounted) return;
      CustomToast.show(context, "지원하지 않는 링크 형식입니다.", isError: true);
      return;
    }

    if (!mounted) return;
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
          insetPadding: dialogMetrics.insetPadding,
          contentPadding: dialogMetrics.contentPadding,
          title: Text(
            "확인 필요",
            style: TextStyle(fontSize: dialogMetrics.titleFontSize),
          ),
          content: ConstrainedBox(
            constraints:
                BoxConstraints(maxWidth: dialogMetrics.maxContentWidth),
            child: Text(
              "입력한 링크가 openpilot 저장소로 보이지 않습니다. 계속할까요?",
              style: TextStyle(fontSize: dialogMetrics.bodyFontSize),
            ),
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
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final sheetHorizontalPadding = window.isCompact
        ? 0.0
        : tokens.screenPadding.clamp(0.0, 18.0).toDouble();
    final sheetBottomGap = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 9.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large => 10.0,
      UiWindowClass.extraLarge => 10.0,
    };
    final titleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 15.0,
      UiWindowClass.medium => 15.0,
      UiWindowClass.expanded => 16.0,
      UiWindowClass.large => 16.0,
      UiWindowClass.extraLarge => 16.0,
    };
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
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: sheetHorizontalPadding),
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  dense: true,
                  title: Text(
                    "고급 Git 설정",
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: titleFontSize,
                    ),
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
                SizedBox(height: sheetBottomGap),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatPt(double value) {
    final rounded = (value * 10).round() / 10;
    if (rounded == rounded.roundToDouble()) {
      return '${rounded.toStringAsFixed(0)}pt';
    }
    return '${rounded.toStringAsFixed(1)}pt';
  }

  String _emphasisLabel(int level) {
    switch (level) {
      case 1:
        return '보통';
      case 2:
        return '강하게';
      default:
        return '끔';
    }
  }

  Future<void> _showLogDisplaySettingsSheet() async {
    if (!mounted) return;
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final sheetHorizontalPadding = window.isCompact
        ? 0.0
        : tokens.screenPadding.clamp(0.0, 18.0).toDouble();
    final titleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 15.0,
      UiWindowClass.medium => 15.0,
      UiWindowClass.expanded => 16.0,
      UiWindowClass.large => 16.0,
      UiWindowClass.extraLarge => 16.0,
    };
    var draftFontSize = _gitLogFontSizePt;
    var draftWrap = _gitLogWrap;
    var draftDimOld = _gitLogDimOld;
    var draftAutoScroll = _gitLogAutoScroll;
    var draftEmphasisLevel = _gitLogEmphasisLevel;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: false,
      builder: (sheetCtx) {
        final bottomDockGap = MediaQuery.viewPaddingOf(sheetCtx).bottom + 12.0;
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            return SafeArea(
              top: false,
              child: Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: sheetHorizontalPadding),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(bottom: bottomDockGap),
                  children: [
                    ListTile(
                      dense: true,
                      title: Text(
                        "로그 표시 설정",
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: titleFontSize,
                        ),
                      ),
                      subtitle: Text(
                        "현재 폰트: ${_formatPt(draftFontSize)}",
                      ),
                    ),
                    ListTile(
                      title: const Text("폰트 크기"),
                      subtitle: Text(
                        "${_formatPt(draftFontSize)} · 10pt ~ 20pt",
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: "작게",
                            onPressed: draftFontSize <= 10.0
                                ? null
                                : () {
                                    setSheetState(() {
                                      draftFontSize = (draftFontSize - 0.5)
                                          .clamp(10.0, 20.0);
                                    });
                                  },
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          Expanded(
                            child: Slider(
                              value: draftFontSize,
                              min: 10.0,
                              max: 20.0,
                              divisions: 20,
                              label: _formatPt(draftFontSize),
                              onChanged: (value) {
                                setSheetState(() {
                                  draftFontSize = ((value * 2).round() / 2)
                                      .clamp(10.0, 20.0);
                                });
                              },
                            ),
                          ),
                          IconButton(
                            tooltip: "크게",
                            onPressed: draftFontSize >= 20.0
                                ? null
                                : () {
                                    setSheetState(() {
                                      draftFontSize = (draftFontSize + 0.5)
                                          .clamp(10.0, 20.0);
                                    });
                                  },
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        ],
                      ),
                    ),
                    SwitchListTile.adaptive(
                      title: const Text("자동 줄바꿈"),
                      subtitle: const Text("끄면 가로 스크롤로 한 줄 유지"),
                      value: draftWrap,
                      onChanged: (value) {
                        setSheetState(() => draftWrap = value);
                      },
                    ),
                    SwitchListTile.adaptive(
                      title: const Text("오래된 로그 흐리게"),
                      subtitle: const Text("이전 세션 로그를 더 연하게 표시"),
                      value: draftDimOld,
                      onChanged: (value) {
                        setSheetState(() => draftDimOld = value);
                      },
                    ),
                    SwitchListTile.adaptive(
                      title: const Text("최신 로그 자동 스크롤"),
                      subtitle: const Text("새 로그가 들어오면 맨 아래로 이동"),
                      value: draftAutoScroll,
                      onChanged: (value) {
                        setSheetState(() => draftAutoScroll = value);
                      },
                    ),
                    ListTile(
                      title: const Text("강조 강도"),
                      subtitle: Text(
                        "현재: ${_emphasisLabel(draftEmphasisLevel)}",
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment<int>(value: 0, label: Text('끔')),
                          ButtonSegment<int>(value: 1, label: Text('보통')),
                          ButtonSegment<int>(value: 2, label: Text('강하게')),
                        ],
                        selected: <int>{draftEmphasisLevel},
                        onSelectionChanged: (selection) {
                          setSheetState(() {
                            draftEmphasisLevel = selection.first;
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: FilledButton(
                        onPressed: () async {
                          setState(() {
                            _gitLogFontSizePt = draftFontSize;
                            _gitLogWrap = draftWrap;
                            _gitLogDimOld = draftDimOld;
                            _gitLogAutoScroll = draftAutoScroll;
                            _gitLogEmphasisLevel = draftEmphasisLevel;
                          });
                          await _saveLogViewSettings();
                          if (!mounted) return;
                          Navigator.pop(sheetCtx);
                          CustomToast.show(context, "로그 표시 설정 저장 완료");
                        },
                        child: const Text("적용"),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
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
        final window = UiWindowInfo.of(sheetCtx);
        final tokens = UiLayoutTokens.of(sheetCtx);
        final color = Theme.of(sheetCtx).colorScheme;
        final sheetHorizontalPadding = window.isCompact
            ? 16.0
            : tokens.screenPadding.clamp(16.0, 26.0).toDouble();
        final detailTitleSize = switch (window.windowClass) {
          UiWindowClass.compact => 16.0,
          UiWindowClass.medium => 16.0,
          UiWindowClass.expanded => 17.0,
          UiWindowClass.large => 18.0,
          UiWindowClass.extraLarge => 18.0,
        };
        final detailMetaLabelSize = switch (window.windowClass) {
          UiWindowClass.compact => 11.0,
          UiWindowClass.medium => 11.0,
          UiWindowClass.expanded => 12.0,
          UiWindowClass.large => 12.0,
          UiWindowClass.extraLarge => 12.0,
        };
        final detailMetaValueSize = switch (window.windowClass) {
          UiWindowClass.compact => 13.0,
          UiWindowClass.medium => 13.0,
          UiWindowClass.expanded => 14.0,
          UiWindowClass.large => 14.0,
          UiWindowClass.extraLarge => 14.0,
        };
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.78,
            ),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                sheetHorizontalPadding,
                8,
                sheetHorizontalPadding,
                16,
              ),
              children: [
                Text(
                  "현재 Git 상세정보",
                  style: TextStyle(
                    fontSize: detailTitleSize,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                _detailTile(
                  "기본 소스(origin)",
                  snapshot.originUrl.isEmpty ? "-" : snapshot.originUrl,
                  labelFontSize: detailMetaLabelSize,
                  valueFontSize: detailMetaValueSize,
                ),
                _detailTile(
                  "현재 브랜치",
                  snapshot.currentBranch.isEmpty ? "-" : snapshot.currentBranch,
                  labelFontSize: detailMetaLabelSize,
                  valueFontSize: detailMetaValueSize,
                ),
                _detailTile(
                  "업데이트 기준",
                  snapshot.upstreamRef.isEmpty ? "-" : snapshot.upstreamRef,
                  labelFontSize: detailMetaLabelSize,
                  valueFontSize: detailMetaValueSize,
                ),
                _detailTile(
                  "코드 폴더",
                  snapshot.repoPath,
                  labelFontSize: detailMetaLabelSize,
                  valueFontSize: detailMetaValueSize,
                ),
                _detailTile(
                  "설정한 폴더",
                  _repoPathOverride.trim().isEmpty
                      ? "(자동탐색)"
                      : _repoPathOverride.trim(),
                  labelFontSize: detailMetaLabelSize,
                  valueFontSize: detailMetaValueSize,
                ),
                _detailTile(
                  "탐색 결과",
                  snapshot.repoPathSource.isEmpty
                      ? "-"
                      : snapshot.repoPathSource,
                  labelFontSize: detailMetaLabelSize,
                  valueFontSize: detailMetaValueSize,
                ),
                if (!snapshot.hasOriginRemote)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      "origin이 없어 '${snapshot.primaryRemoteName.isEmpty ? '첫 번째 소스' : snapshot.primaryRemoteName}' 기준으로 표시 중",
                      style: TextStyle(
                        fontSize: detailMetaLabelSize,
                        color: color.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  "소스 목록 (${snapshot.remotes.length})",
                  style: TextStyle(
                    fontSize: detailMetaValueSize,
                    fontWeight: FontWeight.w700,
                    color: color.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                if (snapshot.remotes.isEmpty)
                  Text(
                    "소스 없음",
                    style: TextStyle(
                      fontSize: detailMetaValueSize,
                      color: Colors.grey,
                    ),
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
                        style: TextStyle(fontSize: detailMetaValueSize),
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
                        style: TextStyle(fontSize: detailMetaLabelSize),
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

  Widget _detailTile(
    String label,
    String value, {
    double labelFontSize = 11,
    double valueFontSize = 13,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: labelFontSize, color: Colors.grey),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(fontSize: valueFontSize),
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

  Future<void> _refreshGitHeadState({bool silent = false}) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      return;
    }

    try {
      final headSnapshot = await _actionService.loadGitHeadSnapshot(
        ssh,
        preferredRepoPath: _preferredRepoPath,
      );
      if (!mounted) return;
      setState(() {
        final current = _gitSnapshot;
        _gitSnapshot = current == null
            ? headSnapshot
            : current.copyWith(
                repoPath: headSnapshot.repoPath,
                requestedRepoPath: headSnapshot.requestedRepoPath,
                repoPathSource: headSnapshot.repoPathSource,
                repoUrl: headSnapshot.repoUrl,
                originUrl: headSnapshot.originUrl,
                primaryRemoteName: headSnapshot.primaryRemoteName,
                currentBranch: headSnapshot.currentBranch,
                defaultBranch: headSnapshot.defaultBranch,
                upstreamRef: headSnapshot.upstreamRef,
                upstreamRemote: headSnapshot.upstreamRemote,
                upstreamBranch: headSnapshot.upstreamBranch,
                rawOutput: headSnapshot.rawOutput,
              );
      });
    } catch (e) {
      if (!silent && mounted) {
        _addLog("Git 상태 갱신 실패: $e");
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
    final metrics = _dialogMetrics(context);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        insetPadding: metrics.insetPadding,
        contentPadding: metrics.contentPadding,
        title: Text(
          "원격 저장소 URL",
          style: TextStyle(fontSize: metrics.titleFontSize),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
          child: SelectableText(
            browserUrl,
            style: TextStyle(fontSize: metrics.bodyFontSize),
          ),
        ),
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
    final dialogMetrics = _dialogMetrics(context);
    final initialUrl = snapshot == null
        ? ''
        : (snapshot.originUrl.isNotEmpty
            ? snapshot.originUrl
            : snapshot.repoUrl);
    final controller = TextEditingController(text: initialUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: dialogMetrics.insetPadding,
        contentPadding: dialogMetrics.contentPadding,
        title: Text(
          "원격 저장소(origin) 변경",
          style: TextStyle(fontSize: dialogMetrics.titleFontSize),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: dialogMetrics.maxContentWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "예: https://github.com/ajouatom/openpilot 또는 git@github.com:ajouatom/openpilot.git",
                style: TextStyle(
                  fontSize: dialogMetrics.hintFontSize,
                  color: Colors.grey,
                ),
              ),
              SizedBox(height: dialogMetrics.gapMedium),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                style: TextStyle(fontSize: dialogMetrics.bodyFontSize),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: "origin URL",
                ),
              ),
            ],
          ),
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

    if (!mounted) return;
    if (!_looksLikeOpenpilotRepoUrl(nextUrl)) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          insetPadding: dialogMetrics.insetPadding,
          contentPadding: dialogMetrics.contentPadding,
          title: Text(
            "확인 필요",
            style: TextStyle(fontSize: dialogMetrics.titleFontSize),
          ),
          content: ConstrainedBox(
            constraints:
                BoxConstraints(maxWidth: dialogMetrics.maxContentWidth),
            child: Text(
              "입력한 URL이 openpilot 저장소로 보이지 않습니다.\n그래도 origin으로 설정할까요?",
              style: TextStyle(fontSize: dialogMetrics.bodyFontSize),
            ),
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

    if (!mounted) return;
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
      } else {
        CustomToast.show(context, "origin 변경 완료 (원격 반영은 Git Sync 실행)");
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
    DeviceActionType action,
    String successMessage, {
    String? branch,
    String? remote,
  }) async {
    if (!mounted) return;
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
          unawaited(_refreshGitHeadState(silent: true));
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

  Future<void> _rebootDevice() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    final metrics = _dialogMetrics(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: metrics.insetPadding,
        contentPadding: metrics.contentPadding,
        title: Text(
          "기기 재부팅",
          style: TextStyle(fontSize: metrics.titleFontSize),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
          child: Text(
            "기기를 재부팅하시겠습니까?",
            style: TextStyle(fontSize: metrics.bodyFontSize),
          ),
        ),
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
        DeviceActionType.reboot,
        "재부팅 명령을 전송했습니다.",
      );
    }
  }

  Future<void> _selectBranch() async {
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
              DeviceActionType.gitCheckout,
              "$name 브랜치로 변경됨",
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
    final dialogMetrics = _dialogMetrics(context);
    final controller = TextEditingController(text: _repoPathOverride);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: dialogMetrics.insetPadding,
        contentPadding: dialogMetrics.contentPadding,
        title: Text(
          "저장소 경로 설정",
          style: TextStyle(fontSize: dialogMetrics.titleFontSize),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: dialogMetrics.maxContentWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "openpilot 외 저장소를 쓰는 경우 .git 폴더가 있는 경로를 입력하세요.\n예: /data/openpilot 또는 /data/myrepo",
                style: TextStyle(
                  fontSize: dialogMetrics.hintFontSize,
                  color: Colors.grey,
                ),
              ),
              SizedBox(height: dialogMetrics.gapMedium),
              TextField(
                controller: controller,
                autofocus: true,
                style: TextStyle(fontSize: dialogMetrics.bodyFontSize),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: "저장소 경로",
                  hintText: "/data/openpilot",
                ),
              ),
            ],
          ),
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
    final dialogMetrics = _dialogMetrics(context);
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
        insetPadding: dialogMetrics.insetPadding,
        contentPadding: dialogMetrics.contentPadding,
        title: Text(
          existing == null ? "리모트 추가" : "리모트 수정",
          style: TextStyle(fontSize: dialogMetrics.titleFontSize),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: dialogMetrics.maxContentWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: existing == null,
                enabled: existing == null,
                style: TextStyle(fontSize: dialogMetrics.bodyFontSize),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: "리모트 이름",
                  hintText: "origin / jominki354",
                ),
              ),
              SizedBox(height: dialogMetrics.gapMedium),
              TextField(
                controller: urlController,
                autofocus: existing != null,
                minLines: 1,
                maxLines: 3,
                style: TextStyle(fontSize: dialogMetrics.bodyFontSize),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: "리모트 URL",
                ),
              ),
            ],
          ),
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

    if (!mounted) return;
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
    final dialogMetrics = _dialogMetrics(context);
    final snapshot = _gitSnapshot;
    if (snapshot == null || snapshot.remotes.isEmpty) {
      CustomToast.show(context, "삭제할 리모트가 없습니다.", isError: true);
      return;
    }
    final target = await showDialog<GitRemoteInfo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        insetPadding: dialogMetrics.insetPadding,
        titlePadding: EdgeInsets.fromLTRB(
          dialogMetrics.contentPadding.left,
          12,
          dialogMetrics.contentPadding.right,
          8,
        ),
        contentPadding: EdgeInsets.fromLTRB(
          dialogMetrics.contentPadding.left,
          0,
          dialogMetrics.contentPadding.right,
          dialogMetrics.contentPadding.bottom,
        ),
        title: Text(
          "리모트 삭제",
          style: TextStyle(fontSize: dialogMetrics.titleFontSize),
        ),
        children: [
          for (final remote in snapshot.remotes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, remote),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(remote.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: dialogMetrics.bodyFontSize,
                      )),
                  if (remote.fetchUrl.isNotEmpty)
                    Text(remote.fetchUrl,
                        style: TextStyle(
                          fontSize: dialogMetrics.hintFontSize,
                          color: Colors.grey,
                        )),
                ],
              ),
            ),
        ],
      ),
    );
    if (target == null) return;

    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: dialogMetrics.insetPadding,
        contentPadding: dialogMetrics.contentPadding,
        title: Text(
          "리모트 삭제",
          style: TextStyle(fontSize: dialogMetrics.titleFontSize),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: dialogMetrics.maxContentWidth),
          child: Text(
            "'${target.name}' 리모트를 삭제할까요?",
            style: TextStyle(fontSize: dialogMetrics.bodyFontSize),
          ),
        ),
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

    if (!mounted) return;
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
    final dialogMetrics = _dialogMetrics(context);
    final snapshot = _gitSnapshot;
    if (snapshot == null || snapshot.remotes.isEmpty) {
      await _addOrEditRemote();
      return;
    }
    final picked = await showDialog<GitRemoteInfo?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        insetPadding: dialogMetrics.insetPadding,
        titlePadding: EdgeInsets.fromLTRB(
          dialogMetrics.contentPadding.left,
          12,
          dialogMetrics.contentPadding.right,
          8,
        ),
        contentPadding: EdgeInsets.fromLTRB(
          dialogMetrics.contentPadding.left,
          0,
          dialogMetrics.contentPadding.right,
          dialogMetrics.contentPadding.bottom,
        ),
        title: Text(
          "리모트 수정",
          style: TextStyle(fontSize: dialogMetrics.titleFontSize),
        ),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text(
              "+ 새 리모트 추가",
              style: TextStyle(fontSize: dialogMetrics.bodyFontSize),
            ),
          ),
          ...snapshot.remotes.map(
            (remote) => SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, remote),
              child: Text(
                _remoteDisplayName(remote.name, remote.fetchUrl),
                style: TextStyle(fontSize: dialogMetrics.bodyFontSize),
              ),
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
              if (result.output.trim().isNotEmpty) {
                _addLog(result.output.trim());
              }
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
      case _GitToolsMenuAction.logDisplaySettings:
        await _showLogDisplaySettingsSheet();
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

  Future<void> _performGitSync() async {
    await _runGitAction(DeviceActionType.gitSync, "Git Sync 완료");
  }

  // ── Cached layout metrics ──────────────────────────────────────────
  Size? _cachedViewportSize;
  UiWindowClass? _cachedWindowClass;
  _GitLayoutMetrics? _cachedLayout;

  _GitLayoutMetrics _computeLayout(
    Size viewportSize,
    UiWindowInfo window,
    UiLayoutTokens tokens,
  ) {
    if (_cachedLayout != null &&
        _cachedViewportSize == viewportSize &&
        _cachedWindowClass == window.windowClass) {
      return _cachedLayout!;
    }
    _cachedViewportSize = viewportSize;
    _cachedWindowClass = window.windowClass;
    _cachedLayout = _GitLayoutMetrics.compute(
      viewportSize: viewportSize,
      window: window,
      tokens: tokens,
      isLoading: _isLoading,
    );
    return _cachedLayout!;
  }

  @override
  Widget build(BuildContext context) {
    final viewportSize = MediaQuery.sizeOf(context);
    final connected = context.watch<SSHService>().isConnected;
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final m = _computeLayout(viewportSize, window, tokens);

    final fixedTwoPaneLandscape = m.fixedTwoPaneLandscape;
    final compactLandscapeLayout = m.compactLandscapeLayout;
    final useWideSplit = m.useWideSplit;
    final outerHorizontal = m.outerHorizontal;
    final topPadding = m.topPadding;
    final bottomPanelPadding = m.bottomPanelPadding;
    final logContainerPadding = m.logContainerPadding;
    final logContainerRadius = m.logContainerRadius;
    final logOverlayInset = m.logOverlayInset;
    final logBottomOverlayReservedHeight = _isLoading
        ? (compactLandscapeLayout ? 28.0 : (window.isCompact ? 32.0 : 36.0))
        : 0.0;
    final logLineFontSize = _gitLogFontSizePt;
    final actionSpacing = m.actionSpacing;
    final actionButtonExtent = m.actionButtonExtent;
    final actionPanelMaxHeight = m.actionPanelMaxHeight;
    final actionPaneEffectiveMaxWidth = m.actionPaneEffectiveMaxWidth;
    final actionPaneMinWidth = m.actionPaneMinWidth;

    Widget buildLogCard() {
      final overlayMenuIconSize =
          compactLandscapeLayout ? 17.0 : (window.isCompact ? 18.0 : 20.0);
      final overlayControl = DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(logContainerRadius),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopupMenuButton<_GitToolsMenuAction>(
              tooltip: "Git 옵션",
              enabled: !(_isLoading || _isLoadingSourceInfo),
              padding: compactLandscapeLayout
                  ? const EdgeInsets.all(2)
                  : const EdgeInsets.all(6),
              constraints: compactLandscapeLayout
                  ? const BoxConstraints(minWidth: 32, minHeight: 32)
                  : const BoxConstraints(minWidth: 38, minHeight: 38),
              icon: Icon(Icons.settings, size: overlayMenuIconSize),
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
                  value: _GitToolsMenuAction.logDisplaySettings,
                  child: Text("로그 표시 설정"),
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
      );

      final emptyContent = Center(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            logContainerPadding,
            logContainerPadding,
            logContainerPadding,
            logContainerPadding + logBottomOverlayReservedHeight,
          ),
          child: Text(
            _isLoading ? 'Git 작업을 진행 중입니다...' : '아직 Git 로그가 없습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: compactLandscapeLayout ? 12.0 : 13.0,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );

      final logList = ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          logContainerPadding,
          logContainerPadding,
          logContainerPadding,
          logContainerPadding + logBottomOverlayReservedHeight,
        ),
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          final log = _logs[index];
          final isOld = log['isOld'] == 'true';
          final emphasisActive = _gitLogEmphasisLevel > 0;
          final messageColor = isOld && _gitLogDimOld
              ? (emphasisActive ? Colors.white70 : Colors.grey)
              : Colors.white;
          final timeColor = isOld && _gitLogDimOld
              ? (emphasisActive
                  ? Colors.greenAccent.shade100
                  : Colors.grey[600])
              : Colors.greenAccent;
          final emphasisShadows = switch (_gitLogEmphasisLevel) {
            1 => const [
                Shadow(
                  color: Colors.black87,
                  offset: Offset(1, 0),
                  blurRadius: 0,
                ),
                Shadow(
                  color: Colors.black87,
                  offset: Offset(-1, 0),
                  blurRadius: 0,
                ),
                Shadow(
                  color: Colors.black87,
                  offset: Offset(0, 1),
                  blurRadius: 0,
                ),
                Shadow(
                  color: Colors.black87,
                  offset: Offset(0, -1),
                  blurRadius: 0,
                ),
                Shadow(
                  color: Colors.black45,
                  offset: Offset(0, 0),
                  blurRadius: 3,
                ),
              ],
            2 => const [
                Shadow(
                  color: Colors.black,
                  offset: Offset(1.2, 0),
                  blurRadius: 0,
                ),
                Shadow(
                  color: Colors.black,
                  offset: Offset(-1.2, 0),
                  blurRadius: 0,
                ),
                Shadow(
                  color: Colors.black,
                  offset: Offset(0, 1.2),
                  blurRadius: 0,
                ),
                Shadow(
                  color: Colors.black,
                  offset: Offset(0, -1.2),
                  blurRadius: 0,
                ),
                Shadow(
                  color: Colors.black87,
                  offset: Offset(1, 1),
                  blurRadius: 3,
                ),
                Shadow(
                  color: Colors.black54,
                  offset: Offset(0, 0),
                  blurRadius: 6,
                ),
              ],
            _ => null,
          };
          final text = RichText(
            softWrap: _gitLogWrap,
            overflow: TextOverflow.visible,
            text: TextSpan(
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: logLineFontSize,
                color: messageColor,
                height: 1.3,
                shadows: emphasisShadows,
              ),
              children: [
                TextSpan(
                  text: "[${log['time']}] ",
                  style: TextStyle(
                    color: timeColor,
                    fontWeight: FontWeight.w700,
                    shadows: emphasisShadows,
                  ),
                ),
                TextSpan(text: log['message']),
              ],
            ),
          );
          return Padding(
            padding: EdgeInsets.symmetric(
              vertical:
                  compactLandscapeLayout ? 1.5 : (window.isCompact ? 2.0 : 3.0),
            ),
            child: _gitLogWrap
                ? text
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: text,
                  ),
          );
        },
      );

      return DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(logContainerRadius),
          border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(logContainerRadius),
          child: Stack(
            children: [
              Positioned.fill(
                child: connected
                    ? (_logs.isEmpty ? emptyContent : logList)
                    : Padding(
                        padding: EdgeInsets.fromLTRB(
                          logContainerPadding,
                          logContainerPadding,
                          logContainerPadding,
                          logContainerPadding + logBottomOverlayReservedHeight,
                        ),
                        child: const ConnectionRequiredView(
                          description: 'Git 기능을 사용하려면 먼저 기기에 연결하세요.',
                        ),
                      ),
              ),
              Positioned(
                top: logOverlayInset,
                right: logOverlayInset,
                child: overlayControl,
              ),
              if (_isLoading)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: logOverlayInset,
                  child: Center(
                    child: _GitLogLoadingIndicator(
                      compact: compactLandscapeLayout || window.isCompact,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    Widget buildActionBody() {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final crossAxisCount = fixedTwoPaneLandscape
                  ? (width >= 280 ? 2 : 1)
                  : width >= 960
                      ? 4
                      : (width >= 700 ? 3 : (width >= 280 ? 2 : 1));
              final actions = <Widget>[
                _buildActionButton(
                  context,
                  "브랜치 선택",
                  Icons.list,
                  Colors.blue,
                  _selectBranch,
                  enabled: connected,
                  dense: compactLandscapeLayout,
                ),
                _buildActionButton(
                  context,
                  "Git Pull",
                  Icons.download,
                  Colors.green,
                  () => _runGitAction(
                    DeviceActionType.gitPull,
                    "Git Pull 완료",
                  ),
                  enabled: connected,
                  dense: compactLandscapeLayout,
                ),
                _buildActionButton(
                  context,
                  "Git Reset",
                  Icons.restore,
                  Colors.orange,
                  () => _runGitAction(
                    DeviceActionType.gitResetHardClean,
                    "Git Reset 완료",
                  ),
                  enabled: connected,
                  dense: compactLandscapeLayout,
                ),
                _buildActionButton(
                  context,
                  "Git Sync",
                  Icons.sync,
                  Colors.red,
                  _performGitSync,
                  enabled: connected,
                  dense: compactLandscapeLayout,
                ),
              ];
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: actionSpacing,
                  crossAxisSpacing: actionSpacing,
                  mainAxisExtent: actionButtonExtent,
                ),
                itemCount: actions.length,
                itemBuilder: (context, index) => actions[index],
              );
            },
          ),
          SizedBox(height: actionSpacing),
          _buildActionButton(
            context,
            "Reboot",
            Icons.restart_alt,
            Colors.red,
            _rebootDevice,
            enabled: connected,
            dense: compactLandscapeLayout,
          ),
        ],
      );
    }

    if (fixedTwoPaneLandscape) {
      final fixedActionPaneWidth =
          (viewportSize.width * 0.40).clamp(280.0, 420.0).toDouble();

      return Padding(
        padding: EdgeInsets.fromLTRB(
          outerHorizontal,
          topPadding,
          outerHorizontal,
          bottomPanelPadding,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: buildLogCard(),
            ),
            SizedBox(width: actionSpacing),
            SizedBox(
              width: fixedActionPaneWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      offset: const Offset(0, 2),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    bottomPanelPadding,
                    bottomPanelPadding,
                    bottomPanelPadding,
                    0,
                  ),
                  child: SingleChildScrollView(
                    child: buildActionBody(),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (useWideSplit) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          outerHorizontal,
          topPadding,
          outerHorizontal,
          bottomPanelPadding,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: buildLogCard()),
            SizedBox(width: actionSpacing),
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: actionPaneMinWidth,
                  maxWidth: actionPaneEffectiveMaxWidth,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        offset: const Offset(0, 2),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      bottomPanelPadding,
                      bottomPanelPadding,
                      bottomPanelPadding,
                      0,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: actionPanelMaxHeight,
                      ),
                      child: SingleChildScrollView(
                        child: buildActionBody(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              outerHorizontal,
              topPadding,
              outerHorizontal,
              0,
            ),
            child: buildLogCard(),
          ),
        ),
        Container(
          padding: EdgeInsets.all(bottomPanelPadding),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                offset: const Offset(0, -2),
                blurRadius: 8,
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            bottom: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: actionPanelMaxHeight),
              child: SingleChildScrollView(
                child: buildActionBody(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(BuildContext context, String label, IconData icon,
      Color color, VoidCallback onTap,
      {bool enabled = true, bool dense = false}) {
    final window = UiWindowInfo.of(context);
    final iconSize = dense ? 16.0 : (window.isCompact ? 18.0 : 20.0);
    final radius = dense ? 10.0 : (window.isCompact ? 12.0 : 14.0);
    final horizontalPadding = dense ? 10.0 : 14.0;
    final verticalPadding = dense ? 10.0 : 14.0;
    final fontSize = dense ? 13.0 : (window.isCompact ? 14.0 : 15.0);
    return FilledButton.icon(
      onPressed: _isLoading || !enabled ? null : onTap,
      icon: Icon(icon, size: iconSize),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: fontSize),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.15),
        foregroundColor: color,
        elevation: 0,
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: verticalPadding,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: color.withValues(alpha: 0.3)),
        ),
      ),
    );
  }
}

class _GitLogLoadingIndicator extends StatefulWidget {
  final bool compact;

  const _GitLogLoadingIndicator({required this.compact});

  @override
  State<_GitLogLoadingIndicator> createState() =>
      _GitLogLoadingIndicatorState();
}

class _GitLogLoadingIndicatorState extends State<_GitLogLoadingIndicator> {
  Timer? _timer;
  int _activeIndex = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 240), (_) {
      if (!mounted) return;
      setState(() {
        _activeIndex = (_activeIndex + 1) % 3;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dotSize = widget.compact ? 5.0 : 6.0;
    final spacing = widget.compact ? 5.0 : 6.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: widget.compact ? 10 : 12,
          vertical: widget.compact ? 6 : 7,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            final isActive = index == _activeIndex;
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing / 2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(
                  color: isActive
                      ? Colors.greenAccent
                      : Colors.white.withValues(alpha: 0.34),
                  borderRadius: BorderRadius.circular(dotSize),
                  boxShadow: isActive
                      ? [
                          BoxShadow(
                            color: Colors.greenAccent.withValues(alpha: 0.45),
                            blurRadius: widget.compact ? 6 : 8,
                            spreadRadius: 0.4,
                          ),
                        ]
                      : null,
                ),
              ),
            );
          }),
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
  String? _selectedRemote;
  String? _currentRemoteForHighlight;
  late List<Map<String, String>> _visibleBranches;

  ({
    EdgeInsets insetPadding,
    EdgeInsets contentPadding,
    double titleFontSize,
    double bodyFontSize,
    double maxContentWidth,
  }) _dialogMetrics(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final insetHorizontal = window.isCompact
        ? 14.0
        : tokens.screenPadding.clamp(14.0, 28.0).toDouble();
    final insetVertical = switch (window.windowClass) {
      UiWindowClass.compact => 18.0,
      UiWindowClass.medium => 20.0,
      UiWindowClass.expanded => 22.0,
      UiWindowClass.large => 24.0,
      UiWindowClass.extraLarge => 24.0,
    };
    final contentPaddingValue = switch (window.windowClass) {
      UiWindowClass.compact => 14.0,
      UiWindowClass.medium => 16.0,
      UiWindowClass.expanded => 18.0,
      UiWindowClass.large => 18.0,
      UiWindowClass.extraLarge => 20.0,
    };
    final titleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 17.0,
      UiWindowClass.medium => 17.0,
      UiWindowClass.expanded => 18.0,
      UiWindowClass.large => 18.0,
      UiWindowClass.extraLarge => 18.0,
    };
    final bodyFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 13.0,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 14.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final maxContentWidth = switch (window.windowClass) {
      UiWindowClass.compact => 620.0,
      UiWindowClass.medium => 700.0,
      UiWindowClass.expanded => 780.0,
      UiWindowClass.large => 860.0,
      UiWindowClass.extraLarge => 920.0,
    };
    return (
      insetPadding: EdgeInsets.symmetric(
        horizontal: insetHorizontal,
        vertical: insetVertical,
      ),
      contentPadding: EdgeInsets.fromLTRB(
        contentPaddingValue,
        10,
        contentPaddingValue,
        contentPaddingValue,
      ),
      titleFontSize: titleFontSize,
      bodyFontSize: bodyFontSize,
      maxContentWidth: maxContentWidth,
    );
  }

  @override
  void initState() {
    super.initState();
    _selectedRemote = _resolveInitialRemote();
    _currentRemoteForHighlight = _resolveCurrentRemoteForHighlight();
    _visibleBranches = _branchesForRemote(_selectedRemote);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rowIndex = _visibleBranches.indexWhere((branch) {
        final name = branch['name'] ?? '';
        if (name != widget.currentBranch) return false;
        if (widget.currentUpstreamRemote.isEmpty) return true;
        return _normalizedRemote(branch) == widget.currentUpstreamRemote;
      });
      if (rowIndex != -1 && _scrollController.hasClients) {
        final offset = rowIndex * 64.0;
        final maxScroll = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(offset.clamp(0.0, maxScroll));
      }
    });
  }

  List<String> _availableRemotes() {
    final groups = _repositoryGroups();
    return groups.keys.toList();
  }

  List<String> _orderedRemoteNames() {
    final remotesWithBranch = <String>{};
    for (final branch in widget.branches) {
      remotesWithBranch.add(_normalizedRemote(branch));
    }
    final ordered = <String>[
      ...widget.remotes.map((e) => e.name).where(remotesWithBranch.contains),
      ...remotesWithBranch.where(
          (name) => !widget.remotes.any((remote) => remote.name == name)),
    ];
    return ordered.toSet().toList();
  }

  Map<String, List<String>> _repositoryGroups() {
    final groups = <String, List<String>>{};
    for (final remote in _orderedRemoteNames()) {
      final id = _repositoryIdForRemoteName(remote);
      final list = groups.putIfAbsent(id, () => <String>[]);
      if (!list.contains(remote)) {
        list.add(remote);
      }
    }
    return groups;
  }

  String _repositoryIdForBranch(Map<String, String> branch) {
    return _repositoryIdForRemoteName(_normalizedRemote(branch));
  }

  String _repositoryIdForRemoteName(String remoteName) {
    GitRemoteInfo? info;
    for (final remoteInfo in widget.remotes) {
      if (remoteInfo.name == remoteName) {
        info = remoteInfo;
        break;
      }
    }

    final rawUrl = ((info?.fetchUrl ?? '').trim().isNotEmpty)
        ? info!.fetchUrl
        : (info?.pushUrl ?? '');
    final repoKey = _hostOwnerRepoKey(rawUrl);
    if (repoKey != null && repoKey.isNotEmpty) {
      return 'repo:$repoKey';
    }
    final owner = _guessOwner(rawUrl);
    if (owner != null && owner.isNotEmpty) {
      return 'owner:${owner.toLowerCase()}';
    }
    if (remoteName == 'origin' || remoteName == 'upstream') {
      return 'repo:default';
    }
    return 'remote:$remoteName';
  }

  int _remotePriority(String remoteName) {
    if (widget.currentUpstreamRemote.isNotEmpty &&
        remoteName == widget.currentUpstreamRemote) {
      return -2;
    }
    if (remoteName == 'origin') return -1;
    final ordered = _orderedRemoteNames();
    final idx = ordered.indexOf(remoteName);
    if (idx >= 0) return idx;
    return ordered.length + 50;
  }

  String? _hostOwnerRepoKey(String url) {
    final normalized = url.trim();
    if (normalized.isEmpty) return null;

    final scpLike =
        RegExp(r'^[^@]+@([^:]+):([^/]+)/([^/]+?)(?:\.git)?$').firstMatch(
      normalized,
    );
    if (scpLike != null) {
      final host = scpLike.group(1)!.toLowerCase();
      final owner = scpLike.group(2)!.toLowerCase();
      final repo = scpLike.group(3)!.toLowerCase();
      return '$host/$owner/$repo';
    }

    final sshUri = Uri.tryParse(normalized);
    if (sshUri != null &&
        sshUri.scheme == 'ssh' &&
        sshUri.host.isNotEmpty &&
        sshUri.pathSegments.length >= 2) {
      final owner = sshUri.pathSegments[0].toLowerCase();
      var repo = sshUri.pathSegments[1].toLowerCase();
      if (repo.endsWith('.git')) repo = repo.substring(0, repo.length - 4);
      return '${sshUri.host.toLowerCase()}/$owner/$repo';
    }

    final uri = Uri.tryParse(normalized);
    if (uri != null && uri.host.isNotEmpty && uri.pathSegments.length >= 2) {
      final owner = uri.pathSegments[0].toLowerCase();
      var repo = uri.pathSegments[1].toLowerCase();
      if (repo.endsWith('.git')) repo = repo.substring(0, repo.length - 4);
      return '${uri.host.toLowerCase()}/$owner/$repo';
    }
    return null;
  }

  String? _guessOwnerRepo(String url) {
    final key = _hostOwnerRepoKey(url);
    if (key == null || key.isEmpty) return null;
    final parts = key.split('/');
    if (parts.length < 3) return null;
    return '${parts[1]}/${parts[2]}';
  }

  String? _resolveInitialRemote() {
    final repositories = _availableRemotes();
    if (repositories.isEmpty) return null;
    if (widget.currentUpstreamRemote.isNotEmpty &&
        repositories.contains(
            _repositoryIdForRemoteName(widget.currentUpstreamRemote))) {
      return _repositoryIdForRemoteName(widget.currentUpstreamRemote);
    }
    final originRepo = _repositoryIdForRemoteName('origin');
    if (repositories.contains(originRepo)) return originRepo;
    return repositories.first;
  }

  List<Map<String, String>> _branchesForRemote(String? remote) {
    if (remote == null || remote.isEmpty) return const [];
    final selectedByName = <String, Map<String, String>>{};
    for (final branch in widget.branches) {
      if (_repositoryIdForBranch(branch) != remote) continue;
      final name = (branch['name'] ?? '').trim();
      if (name.isEmpty) continue;

      final current = selectedByName[name];
      if (current == null) {
        selectedByName[name] = branch;
        continue;
      }

      final nextPriority = _remotePriority(_normalizedRemote(branch));
      final currentPriority = _remotePriority(_normalizedRemote(current));
      if (nextPriority < currentPriority) {
        selectedByName[name] = branch;
      }
    }
    return selectedByName.values.toList();
  }

  String? _resolveCurrentRemoteForHighlight() {
    if (widget.currentUpstreamRemote.isNotEmpty) {
      return _repositoryIdForRemoteName(widget.currentUpstreamRemote);
    }

    final candidates = <String>[];
    for (final remote in _availableRemotes()) {
      final hasCurrentBranch = _branchesForRemote(remote).any(
        (branch) => (branch['name'] ?? '') == widget.currentBranch,
      );
      if (hasCurrentBranch) {
        candidates.add(remote);
      }
    }

    if (candidates.length == 1) {
      return candidates.first;
    }
    return null;
  }

  String _normalizedRemote(Map<String, String> branch) {
    final remote = (branch['remote'] ?? '').trim();
    return remote.isEmpty ? 'origin' : remote;
  }

  String _repositoryLabel(String repositoryId, List<String> groupedRemotes) {
    GitRemoteInfo? info;
    for (final remote in groupedRemotes) {
      for (final remoteInfo in widget.remotes) {
        if (remoteInfo.name == remote) {
          info = remoteInfo;
          break;
        }
      }
      if (info != null) {
        final candidateUrl =
            info.fetchUrl.trim().isNotEmpty ? info.fetchUrl : info.pushUrl;
        if (candidateUrl.trim().isNotEmpty) {
          break;
        }
      }
    }

    String rawUrl = '';
    if (info != null) {
      rawUrl = info.fetchUrl.trim().isNotEmpty ? info.fetchUrl : info.pushUrl;
    }
    final ownerRepo = _guessOwnerRepo(rawUrl);
    if (ownerRepo != null && ownerRepo.isNotEmpty) return ownerRepo;

    final owner = _guessOwner(rawUrl);
    if (owner != null && owner.isNotEmpty) return owner;
    if (groupedRemotes.contains('origin')) return '기본 저장소';
    if (groupedRemotes.isNotEmpty) return groupedRemotes.first;
    return repositoryId;
  }

  Map<String, String> _repositoryLabels(
    List<String> repositories,
    Map<String, List<String>> groups,
  ) {
    final labels = <String, String>{};
    final counts = <String, int>{};

    for (final repository in repositories) {
      final label =
          _repositoryLabel(repository, groups[repository] ?? const <String>[]);
      labels[repository] = label;
      counts[label] = (counts[label] ?? 0) + 1;
    }

    for (final repository in repositories) {
      final label = labels[repository] ?? repository;
      if ((counts[label] ?? 0) > 1) {
        final remotes = groups[repository] ?? const <String>[];
        final suffix = remotes.contains('origin')
            ? 'origin'
            : (remotes.isNotEmpty ? remotes.first : '');
        labels[repository] = suffix.isEmpty ? label : '$label ($suffix)';
      }
    }
    return labels;
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

  void _changeRemote(String? remote) {
    if (remote == null || remote == _selectedRemote) return;
    setState(() {
      _selectedRemote = remote;
      _visibleBranches = _branchesForRemote(remote);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(0);
    });
  }

  Map<String, int> _branchCountByRepository() {
    final counts = <String, int>{};
    for (final branch in widget.branches) {
      final repoId = _repositoryIdForBranch(branch);
      counts[repoId] = (counts[repoId] ?? 0) + 1;
    }
    return counts;
  }

  Future<void> _showRepositoryPicker({
    required List<String> repositories,
    required Map<String, String> repositoryLabels,
    required Map<String, List<String>> repositoryGroups,
    required Map<String, int> branchCounts,
  }) async {
    if (repositories.isEmpty) return;
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final sheetHorizontalPadding = window.isCompact
        ? 12.0
        : tokens.screenPadding.clamp(12.0, 24.0).toDouble();
    final titleBottomGap = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 9.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large => 10.0,
      UiWindowClass.extraLarge => 10.0,
    };
    final repositoryRowHorizontalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 9.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final repositorySubtitleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 12.5,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };
    final picked = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            sheetHorizontalPadding,
            6,
            sheetHorizontalPadding,
            12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '저장소 선택',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              SizedBox(height: titleBottomGap),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: repositories.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final repoId = repositories[index];
                    final isSelected = repoId == _selectedRemote;
                    final label = repositoryLabels[repoId] ?? repoId;
                    final aliases =
                        repositoryGroups[repoId] ?? const <String>[];
                    final branchCount = branchCounts[repoId] ?? 0;
                    final subtitle = aliases.isEmpty
                        ? '$branchCount개 브랜치'
                        : '원격 ${aliases.join(', ')} · $branchCount개 브랜치';
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: repositoryRowHorizontalPadding,
                        vertical: 2,
                      ),
                      title: Text(
                        label,
                        style: TextStyle(
                          fontWeight:
                              isSelected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: repositorySubtitleFontSize),
                      ),
                      trailing: isSelected
                          ? Icon(
                              Icons.check_circle,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.pop(sheetContext, repoId),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || picked == null) return;
    _changeRemote(picked);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final dialogMetrics = _dialogMetrics(context);
    final dialogHeight = switch (window.windowClass) {
      UiWindowClass.compact => 430.0,
      UiWindowClass.medium => 460.0,
      UiWindowClass.expanded => 500.0,
      UiWindowClass.large => 540.0,
      UiWindowClass.extraLarge => 560.0,
    };
    final contentInset = tokens.screenPadding.clamp(10.0, 18.0).toDouble();
    final rowGap = switch (window.windowClass) {
      UiWindowClass.compact => 10.0,
      UiWindowClass.medium => 10.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final branchRowPadding = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 13.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final infoLabelFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 11.0,
      UiWindowClass.medium => 11.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final infoValueFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 13.0,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };
    final branchSubFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 12.5,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };

    final repositories = _availableRemotes();
    final repositoryGroups = _repositoryGroups();
    final remoteLabels = _repositoryLabels(repositories, repositoryGroups);
    final branchCounts = _branchCountByRepository();
    final selectedRemote = _selectedRemote;
    final selectedRemoteLabel = selectedRemote == null
        ? '-'
        : (remoteLabels[selectedRemote] ?? selectedRemote);

    return AlertDialog(
      insetPadding: dialogMetrics.insetPadding,
      contentPadding: dialogMetrics.contentPadding,
      title: Text(
        widget.title,
        style: TextStyle(fontSize: dialogMetrics.titleFontSize),
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogMetrics.maxContentWidth,
        ),
        child: SizedBox(
          width: double.maxFinite,
          height: dialogHeight,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding:
                    EdgeInsets.symmetric(horizontal: contentInset, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.call_split, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '현재 브랜치: ${widget.currentBranch}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: infoValueFontSize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${_visibleBranches.length}개',
                      style: TextStyle(
                        fontSize: infoLabelFontSize,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: rowGap),
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _showRepositoryPicker(
                    repositories: repositories,
                    repositoryLabels: remoteLabels,
                    repositoryGroups: repositoryGroups,
                    branchCounts: branchCounts,
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: contentInset, vertical: 10),
                    child: Row(
                      children: [
                        const Icon(Icons.account_tree_outlined, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '저장소',
                                style: TextStyle(
                                  fontSize: infoLabelFontSize,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                              SizedBox(height: tokens.itemGap / 2),
                              Text(
                                selectedRemoteLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: infoValueFontSize,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.expand_more, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: rowGap),
              if (selectedRemote != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '선택 저장소: $selectedRemoteLabel',
                      style: TextStyle(
                        fontSize: infoValueFontSize,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: _visibleBranches.isEmpty
                    ? Center(
                        child: Text(
                          "선택한 저장소에 브랜치가 없습니다.",
                          style: TextStyle(
                            fontSize: branchSubFontSize,
                            color: Colors.grey,
                          ),
                        ),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: ListView.builder(
                          controller: _scrollController,
                          shrinkWrap: true,
                          padding: EdgeInsets.symmetric(
                              vertical: window.isCompact ? 2 : 3),
                          clipBehavior: Clip.hardEdge,
                          itemCount: _visibleBranches.length,
                          itemBuilder: (ctx, index) {
                            final branch = _visibleBranches[index];
                            final name = branch['name']!;
                            final remote = _normalizedRemote(branch);
                            final date = branch['date']!;
                            final hash = branch['hash']!;
                            final isDefault = name == widget.defaultBranch;
                            final isCurrent = name == widget.currentBranch &&
                                _currentRemoteForHighlight != null &&
                                _currentRemoteForHighlight ==
                                    _repositoryIdForBranch(branch);

                            bool hasUpdate = false;
                            if (widget.localRefs.containsKey(name)) {
                              if (widget.localRefs[name] != hash) {
                                hasUpdate = true;
                              }
                            }

                            return Padding(
                              key: ValueKey('$remote/$name'),
                              padding: EdgeInsets.symmetric(
                                  vertical: window.isCompact ? 2 : 3),
                              child: Material(
                                color: isCurrent
                                    ? Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer
                                        .withValues(alpha: 0.72)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                clipBehavior: Clip.antiAlias,
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: branchRowPadding,
                                    vertical: 2,
                                  ),
                                  leading:
                                      const Icon(Icons.alt_route, size: 18),
                                  title: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontWeight: isDefault
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                      if (isDefault) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.blue
                                                .withValues(alpha: 0.2),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            "Default",
                                            style: TextStyle(
                                              fontSize: infoLabelFontSize - 1,
                                              color: Colors.blue,
                                            ),
                                          ),
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
                                      style: TextStyle(
                                          fontSize: branchSubFontSize,
                                          color: Colors.grey)),
                                  trailing: hasUpdate
                                      ? IconButton(
                                          icon: const Icon(Icons.priority_high,
                                              color: Colors.red, size: 20),
                                          tooltip: "업데이트 가능",
                                          onPressed: () async {
                                            if (widget.repoUrl.isNotEmpty) {
                                              final baseUrl =
                                                  _browserRepoUrlForRemote(
                                                      remote);
                                              if (baseUrl == null ||
                                                  baseUrl.isEmpty) {
                                                return;
                                              }
                                              final url =
                                                  "$baseUrl/commits/$name";
                                              final uri = Uri.parse(url);
                                              if (await canLaunchUrl(uri)) {
                                                await launchUrl(uri,
                                                    mode: LaunchMode
                                                        .externalApplication);
                                              } else {
                                                if (context.mounted) {
                                                  final infoDialogMetrics =
                                                      _dialogMetrics(context);
                                                  showDialog(
                                                    context: context,
                                                    builder: (_) => AlertDialog(
                                                      insetPadding:
                                                          infoDialogMetrics
                                                              .insetPadding,
                                                      contentPadding:
                                                          infoDialogMetrics
                                                              .contentPadding,
                                                      title: Text(
                                                        "커밋 내역",
                                                        style: TextStyle(
                                                          fontSize:
                                                              infoDialogMetrics
                                                                  .titleFontSize,
                                                        ),
                                                      ),
                                                      content: ConstrainedBox(
                                                        constraints:
                                                            BoxConstraints(
                                                          maxWidth:
                                                              infoDialogMetrics
                                                                  .maxContentWidth,
                                                        ),
                                                        child: SelectableText(
                                                          url,
                                                          style: TextStyle(
                                                            fontSize:
                                                                infoDialogMetrics
                                                                    .bodyFontSize,
                                                          ),
                                                        ),
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                    context),
                                                            child: const Text(
                                                                "닫기"))
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
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("닫기"),
        ),
      ],
    );
  }
}

// ── Pre-computed layout metrics for _GitTabState.build() ──────────
class _GitLayoutMetrics {
  final bool fixedTwoPaneLandscape;
  final bool compactLandscapeLayout;
  final bool useWideSplit;
  final double outerHorizontal;
  final double topPadding;
  final double bottomPanelPadding;
  final double logContainerPadding;
  final double logContainerRadius;
  final double logOverlayInset;
  final double actionSpacing;
  final double actionButtonExtent;
  final double actionPanelMaxHeight;
  final double actionPaneEffectiveMaxWidth;
  final double actionPaneMinWidth;

  const _GitLayoutMetrics._({
    required this.fixedTwoPaneLandscape,
    required this.compactLandscapeLayout,
    required this.useWideSplit,
    required this.outerHorizontal,
    required this.topPadding,
    required this.bottomPanelPadding,
    required this.logContainerPadding,
    required this.logContainerRadius,
    required this.logOverlayInset,
    required this.actionSpacing,
    required this.actionButtonExtent,
    required this.actionPanelMaxHeight,
    required this.actionPaneEffectiveMaxWidth,
    required this.actionPaneMinWidth,
  });

  factory _GitLayoutMetrics.compute({
    required Size viewportSize,
    required UiWindowInfo window,
    required UiLayoutTokens tokens,
    required bool isLoading,
  }) {
    final shortViewport = viewportSize.height < 620;
    final fixedTwoPaneLandscape = window.isLandscape &&
        viewportSize.width >= 700.0 &&
        (window.isCompact ||
            window.isConstrainedLandscape ||
            viewportSize.height < 700.0);
    final useWideSplit = fixedTwoPaneLandscape ||
        (!window.isConstrainedLandscape &&
            window.isLandscape &&
            (window.isExpandedOrAbove || viewportSize.width >= 680.0));
    final compactLandscapeLayout =
        fixedTwoPaneLandscape || (useWideSplit && shortViewport);
    final outerHorizontal = compactLandscapeLayout
        ? 10.0
        : (window.isCompact
            ? 12.0
            : tokens.screenPadding.clamp(14.0, 28.0).toDouble());
    final topPadding = compactLandscapeLayout
        ? 8.0
        : switch (window.windowClass) {
            UiWindowClass.compact => tokens.sectionGap,
            UiWindowClass.medium => tokens.itemGap + 4,
            UiWindowClass.expanded => tokens.itemGap + 2,
            UiWindowClass.large ||
            UiWindowClass.extraLarge =>
              tokens.itemGap + 2,
          };
    final bottomPanelPadding = compactLandscapeLayout
        ? 8.0
        : (window.isCompact ? tokens.itemGap + 2 : tokens.sectionGap + 2);
    final logContainerPadding =
        compactLandscapeLayout ? 6.0 : (window.isCompact ? 8.0 : 10.0);
    final logContainerRadius =
        compactLandscapeLayout ? 8.0 : (window.isCompact ? 8.0 : 10.0);
    final logOverlayInset =
        compactLandscapeLayout ? 6.0 : (window.isCompact ? 8.0 : 10.0);
    final actionSpacing = compactLandscapeLayout
        ? 8.0
        : (window.isCompact ? tokens.itemGap + 2 : 10.0);
    final actionPaneWidth = compactLandscapeLayout
        ? switch (window.windowClass) {
            UiWindowClass.compact => 292.0,
            UiWindowClass.medium => 304.0,
            UiWindowClass.expanded => 316.0,
            UiWindowClass.large => 324.0,
            UiWindowClass.extraLarge => 332.0,
          }
        : switch (window.windowClass) {
            UiWindowClass.compact => 300.0,
            UiWindowClass.medium => 320.0,
            UiWindowClass.expanded => 330.0,
            UiWindowClass.large => 350.0,
            UiWindowClass.extraLarge => 370.0,
          };
    final actionButtonExtent = compactLandscapeLayout
        ? switch (window.windowClass) {
            UiWindowClass.compact => 62.0,
            UiWindowClass.medium => 60.0,
            UiWindowClass.expanded => 58.0,
            UiWindowClass.large => 56.0,
            UiWindowClass.extraLarge => 56.0,
          }
        : switch (window.windowClass) {
            UiWindowClass.compact => 76.0,
            UiWindowClass.medium => 74.0,
            UiWindowClass.expanded => 70.0,
            UiWindowClass.large => 68.0,
            UiWindowClass.extraLarge => 66.0,
          };
    final estimatedGridColumns = actionPaneWidth >= 960
        ? 4
        : (actionPaneWidth >= 700 ? 3 : (actionPaneWidth >= 280 ? 2 : 1));
    const actionButtonCount = 4;
    final estimatedGridRows =
        (actionButtonCount + estimatedGridColumns - 1) ~/ estimatedGridColumns;
    final estimatedActionBodyHeight = (estimatedGridRows * actionButtonExtent) +
        ((estimatedGridRows - 1) * actionSpacing) +
        actionSpacing +
        actionButtonExtent +
        8.0;
    final baseActionPanelMaxHeight = switch (window.windowClass) {
      UiWindowClass.compact => 430.0,
      UiWindowClass.medium => 390.0,
      UiWindowClass.expanded => 360.0,
      UiWindowClass.large => 350.0,
      UiWindowClass.extraLarge => 340.0,
    };
    final computedActionPanelMaxHeight =
        (viewportSize.height * (shortViewport ? 0.38 : 0.46))
            .clamp(140.0, baseActionPanelMaxHeight)
            .toDouble();
    final wideActionPanelMaxHeight =
        computedActionPanelMaxHeight < estimatedActionBodyHeight
            ? estimatedActionBodyHeight
            : computedActionPanelMaxHeight;
    final veryShortViewport = viewportSize.height < 520;
    final actionPanelMaxHeight = useWideSplit
        ? (compactLandscapeLayout
            ? (viewportSize.height - (topPadding + bottomPanelPadding))
                .clamp(220.0, wideActionPanelMaxHeight)
                .toDouble()
            : wideActionPanelMaxHeight)
        : (veryShortViewport
            ? computedActionPanelMaxHeight.clamp(120.0, 210.0).toDouble()
            : computedActionPanelMaxHeight);
    final actionPaneEffectiveMaxWidth =
        (viewportSize.width * (compactLandscapeLayout ? 0.40 : 0.44))
            .clamp(compactLandscapeLayout ? 276.0 : 240.0, actionPaneWidth)
            .toDouble();
    final actionPaneMinWidth = compactLandscapeLayout
        ? 276.0
        : switch (window.windowClass) {
            UiWindowClass.compact => 200.0,
            UiWindowClass.medium => 220.0,
            UiWindowClass.expanded => 228.0,
            UiWindowClass.large || UiWindowClass.extraLarge => 248.0,
          };

    return _GitLayoutMetrics._(
      fixedTwoPaneLandscape: fixedTwoPaneLandscape,
      compactLandscapeLayout: compactLandscapeLayout,
      useWideSplit: useWideSplit,
      outerHorizontal: outerHorizontal,
      topPadding: topPadding,
      bottomPanelPadding: bottomPanelPadding,
      logContainerPadding: logContainerPadding,
      logContainerRadius: logContainerRadius,
      logOverlayInset: logOverlayInset,
      actionSpacing: actionSpacing,
      actionButtonExtent: actionButtonExtent,
      actionPanelMaxHeight: actionPanelMaxHeight,
      actionPaneEffectiveMaxWidth: actionPaneEffectiveMaxWidth,
      actionPaneMinWidth: actionPaneMinWidth,
    );
  }
}
