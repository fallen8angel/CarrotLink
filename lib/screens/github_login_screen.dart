import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/diagnostics_service.dart';
import '../services/github_oauth_ui_service.dart';
import '../services/github_service.dart';
import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';
import '../widgets/custom_toast.dart';

class GithubLoginScreen extends StatefulWidget {
  final GitHubService githubService;

  const GithubLoginScreen({super.key, required this.githubService});

  @override
  State<GithubLoginScreen> createState() => _GithubLoginScreenState();
}

class _GithubLoginScreenState extends State<GithubLoginScreen> {
  String? _userCode;
  String? _verificationUri;
  String? _verificationUriComplete;
  String? _deviceCode;
  int _interval = 5;
  int _expiresInTotal = 900;
  bool _isLoading = true;
  bool _isPolling = false;
  bool _pollInFlight = false;
  bool _flowCompleted = false;
  int _pollErrorCount = 0;
  int _pollAttempt = 0;
  String _pollStatusText = "브라우저 승인 대기 중...";
  DateTime? _pollDeadline;
  DateTime? _nextPollAllowedAt;
  Timer? _uiTicker;
  final DiagnosticsService _diag = DiagnosticsService.instance;

  @override
  void initState() {
    super.initState();
    _initiateDeviceFlow();
  }

  @override
  void dispose() {
    _isPolling = false;
    _uiTicker?.cancel();
    unawaited(GitHubOAuthUiService.cancelCodeNotification());
    unawaited(GitHubOAuthUiService.hideCodeHud());
    super.dispose();
  }

  String _targetUri() {
    return _verificationUriComplete ??
        _verificationUri ??
        'https://github.com/login/device';
  }

  void _closeWithError(String message) {
    if (_flowCompleted) return;
    _flowCompleted = true;
    _isPolling = false;
    _uiTicker?.cancel();
    unawaited(GitHubOAuthUiService.cancelCodeNotification());
    unawaited(GitHubOAuthUiService.hideCodeHud());
    _diag.warn('github_oauth', message);
    if (!mounted) return;
    CustomToast.show(context, message, isError: true);
    Navigator.pop(context);
  }

  Future<void> _closeWithToken(String token) async {
    if (_flowCompleted) return;
    _flowCompleted = true;
    _isPolling = false;
    _uiTicker?.cancel();
    await GitHubOAuthUiService.bringAppToFront();
    unawaited(GitHubOAuthUiService.cancelCodeNotification());
    unawaited(GitHubOAuthUiService.hideCodeHud());
    _diag.info('github_oauth', 'Device flow finished with token');
    if (!mounted) return;
    CustomToast.show(context, "GitHub 로그인 성공!");
    Navigator.pop(context, token);
  }

  bool _isPollingExpired() {
    final deadline = _pollDeadline;
    if (deadline == null) return false;
    return DateTime.now().isAfter(deadline);
  }

  Future<void> _copyUserCode({bool toast = false}) async {
    final code = _userCode;
    if (code == null || code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (toast && mounted) {
      CustomToast.show(context, "코드를 복사했습니다.");
    }
  }

  Future<void> _showCodeNotification() async {
    final code = _userCode?.trim() ?? '';
    if (code.isEmpty) return;
    await GitHubOAuthUiService.showCodeNotification(
      code: code,
      url: _targetUri(),
    );
  }

  Future<void> _showMiniHudIfPossible() async {
    final code = _userCode?.trim() ?? '';
    if (code.isEmpty) return;
    final shown = await GitHubOAuthUiService.showCodeHud(code);
    if (shown) return;
    final hasPermission = await GitHubOAuthUiService.hasOverlayPermission();
    if (!hasPermission) {
      _diag.warn(
          'github_oauth', 'Mini HUD skipped: overlay permission missing');
    }
  }

  Future<bool> _openInExternalBrowser({bool showFailureToast = true}) async {
    final raw = _targetUri();
    Uri uri;
    try {
      uri = Uri.parse(raw);
    } catch (_) {
      if (showFailureToast && mounted) {
        CustomToast.show(context, '브라우저 URL이 올바르지 않습니다.', isError: true);
      }
      return false;
    }

    await _copyUserCode();
    await _showCodeNotification();
    await _showMiniHudIfPossible();

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && showFailureToast && mounted) {
        CustomToast.show(context, '브라우저를 열 수 없습니다.', isError: true);
      }
      return launched;
    } catch (e) {
      if (showFailureToast && mounted) {
        CustomToast.show(context, '브라우저 실행 실패: $e', isError: true);
      }
      return false;
    }
  }

  Future<void> _initiateDeviceFlow() async {
    try {
      final deviceData = await widget.githubService.initiateDeviceFlow();
      if (!mounted) return;
      final expiresRaw = deviceData['expires_in'];
      final intervalRaw = deviceData['interval'];
      final expiresIn = expiresRaw is int
          ? expiresRaw
          : int.tryParse(expiresRaw?.toString() ?? '') ?? 900;
      final interval = intervalRaw is int
          ? intervalRaw
          : int.tryParse(intervalRaw?.toString() ?? '') ?? 5;

      setState(() {
        _userCode = deviceData['user_code']?.toString();
        _verificationUri = deviceData['verification_uri']?.toString();
        _verificationUriComplete =
            deviceData['verification_uri_complete']?.toString();
        _deviceCode = deviceData['device_code']?.toString();
        _interval = interval;
        _expiresInTotal = expiresIn;
        _isLoading = false;
        _isPolling = true;
        _flowCompleted = false;
        _pollErrorCount = 0;
        _pollAttempt = 0;
        _pollStatusText = "브라우저 승인 대기 중...";
        _pollDeadline = DateTime.now().add(Duration(seconds: expiresIn));
      });

      _diag.info(
        'github_oauth',
        'Screen flow init interval=${_interval}s expires=${expiresIn}s',
      );

      await _copyUserCode();
      await _showCodeNotification();
      _startUiTicker();
      unawaited(_startPolling());

      final launched = await _openInExternalBrowser(showFailureToast: false);
      if (!launched && mounted) {
        CustomToast.show(
          context,
          "자동으로 브라우저를 열지 못했습니다. '브라우저 열기'를 눌러 진행하세요.",
          isError: true,
        );
      }
    } catch (e) {
      if (mounted) {
        _diag.error('github_oauth', 'Device flow initialization failed: $e');
        _closeWithError("로그인 초기화 실패: $e");
      }
    }
  }

  Future<void> _pollTokenOnce() async {
    if (!_isPolling || !mounted || _deviceCode == null || _pollInFlight) return;
    if (_nextPollAllowedAt != null &&
        DateTime.now().isBefore(_nextPollAllowedAt!)) {
      return;
    }
    if (_isPollingExpired()) {
      _closeWithError("인증 시간이 만료되었습니다. 다시 시도해주세요.");
      return;
    }

    _pollInFlight = true;
    _pollAttempt += 1;

    try {
      final token = await widget.githubService.pollForToken(_deviceCode!);
      if (token != null) {
        await _closeWithToken(token);
        return;
      }

      _pollErrorCount = 0;
      if (mounted) {
        setState(() {
          _pollStatusText = "브라우저 승인 대기 중...";
        });
      }

      if (_pollAttempt % 15 == 0) {
        _diag.info('github_oauth',
            'Still waiting for browser approval attempts=$_pollAttempt');
      }
    } catch (e) {
      final message = e.toString();
      if (message.contains('slow_down')) {
        _interval += 5;
        if (_interval > 20) _interval = 20;
        if (mounted) {
          setState(() {
            _pollStatusText = "요청 간격 조정 중... (${_interval}s)";
          });
        }
        _diag.warn(
            'github_oauth', 'slow_down received, new interval=${_interval}s');
      } else if (message.contains('expired_token')) {
        _closeWithError("인증 시간이 만료되었습니다. 다시 시도해주세요.");
      } else {
        _pollErrorCount += 1;
        _diag.warn(
          'github_oauth',
          'Polling error attempt=$_pollAttempt errors=$_pollErrorCount message=$message',
        );
        if (mounted) {
          setState(() {
            _pollStatusText = "토큰 확인 재시도 중... ($_pollErrorCount)";
          });
        }
        if (_pollErrorCount >= 6) {
          _closeWithError("인증 오류가 반복됩니다. 네트워크 상태를 확인하고 다시 시도해주세요.");
        }
      }
    } finally {
      _pollInFlight = false;
      if (_isPolling && !_flowCompleted) {
        _nextPollAllowedAt = DateTime.now().add(Duration(seconds: _interval));
      }
    }
  }

  Future<void> _startPolling() async {
    while (_isPolling && mounted) {
      if (_isPollingExpired()) {
        _closeWithError("인증 시간이 만료되었습니다. 다시 시도해주세요.");
        break;
      }
      final delay = _interval;
      await Future.delayed(Duration(seconds: delay));
      if (!_isPolling || !mounted) break;
      await _pollTokenOnce();
    }
  }

  void _startUiTicker() {
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _flowCompleted) {
        _uiTicker?.cancel();
        return;
      }
      setState(() {});
    });
  }

  int _remainingFlowSeconds() {
    final deadline = _pollDeadline;
    if (deadline == null) return _expiresInTotal;
    final remaining = deadline.difference(DateTime.now()).inSeconds;
    return remaining < 0 ? 0 : remaining;
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _isPolling = false;
          unawaited(GitHubOAuthUiService.cancelCodeNotification());
          unawaited(GitHubOAuthUiService.hideCodeHud());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text("GitHub 로그인"),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              _isPolling = false;
              unawaited(GitHubOAuthUiService.cancelCodeNotification());
              unawaited(GitHubOAuthUiService.hideCodeHud());
              Navigator.of(context).pop();
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.open_in_browser),
              tooltip: "브라우저 열기",
              onPressed: () => unawaited(_openInExternalBrowser()),
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.fromLTRB(
                  tokens.screenPadding.clamp(14.0, 24.0).toDouble(),
                  16,
                  tokens.screenPadding.clamp(14.0, 24.0).toDouble(),
                  24,
                ),
                children: [
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(
                      window.isCompact ? 14.0 : 16.0,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "외부 브라우저에서 인증하세요",
                          style: TextStyle(
                            fontSize: window.isCompact ? 12.5 : 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 10),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final compactCode =
                                window.isCompact || constraints.maxWidth < 360;
                            return Container(
                              width: double.infinity,
                              padding: EdgeInsets.symmetric(
                                vertical: compactCode ? 11 : 12,
                                horizontal: compactCode ? 10 : 14,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _userCode ?? "ERROR",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: compactCode ? 22 : 28,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: compactCode ? 4 : 6,
                                    color: scheme.onPrimary,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final compactActions =
                                window.isCompact || constraints.maxWidth < 380;
                            if (compactActions) {
                              return Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  FilledButton.icon(
                                    onPressed: () =>
                                        unawaited(_openInExternalBrowser()),
                                    icon: const Icon(Icons.open_in_browser),
                                    label: const Text("브라우저 열기"),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        unawaited(_copyUserCode(toast: true)),
                                    icon: const Icon(Icons.copy_all),
                                    label: const Text("복사"),
                                  ),
                                ],
                              );
                            }
                            return Row(
                              children: [
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: () =>
                                        unawaited(_openInExternalBrowser()),
                                    icon: const Icon(Icons.open_in_browser),
                                    label: const Text("브라우저 열기"),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      unawaited(_copyUserCode(toast: true)),
                                  icon: const Icon(Icons.copy_all),
                                  label: const Text("복사"),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: EdgeInsets.all(window.isCompact ? 10 : 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: Text(
                            _pollStatusText,
                            style: TextStyle(
                              fontSize: window.isCompact ? 11.5 : 12,
                            ),
                          ),
                        ),
                        Text(
                          "${_remainingFlowSeconds()}s",
                          style: TextStyle(
                            fontSize: window.isCompact ? 11.5 : 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "안내\n"
                    "1. 코드가 시스템 알림에 고정 표시됩니다.\n"
                    "2. 오버레이 권한이 있으면 작은 코드 HUD가 함께 표시됩니다.\n"
                    "3. 외부 브라우저에서 로그인/2FA/패스키(WebAuthn)를 진행하세요.\n"
                    "4. 승인 후 앱이 자동으로 로그인 완료됩니다.",
                    style: TextStyle(
                      fontSize: window.isCompact ? 11.5 : 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
