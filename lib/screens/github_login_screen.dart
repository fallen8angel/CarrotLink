import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/github_service.dart';
import '../services/diagnostics_service.dart';
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
  bool _isLoading = true;
  bool _isPolling = false;
  bool _approvalDetected = false;
  bool _pollInFlight = false;
  int _pollErrorCount = 0;
  int _pollAttempt = 0;
  int _pendingAfterApprovalCount = 0;
  int _maxPendingAfterApproval = 90;
  int _expiresInTotal = 900;
  bool _flowCompleted = false;
  DateTime? _pollDeadline;
  DateTime? _approvalDetectedAt;
  DateTime? _nextPollAllowedAt;
  String _pollStatusText = "인증 대기 중...";
  Timer? _uiTicker;
  WebViewController? _webViewController;
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
    super.dispose();
  }

  void _closeWithError(String message) {
    if (_flowCompleted) return;
    _flowCompleted = true;
    _isPolling = false;
    _uiTicker?.cancel();
    _diag.warn('github_oauth', message);
    if (!mounted) return;
    CustomToast.show(context, message, isError: true);
    Navigator.pop(context);
  }

  void _closeWithToken(String token) {
    if (_flowCompleted) return;
    _flowCompleted = true;
    _isPolling = false;
    _uiTicker?.cancel();
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

  Future<void> _initiateDeviceFlow() async {
    try {
      final deviceData = await widget.githubService.initiateDeviceFlow();
      if (mounted) {
        final expiresRaw = deviceData['expires_in'];
        final intervalRaw = deviceData['interval'];
        final expiresIn = expiresRaw is int
            ? expiresRaw
            : int.tryParse(expiresRaw?.toString() ?? '') ?? 900;
        final interval = intervalRaw is int
            ? intervalRaw
            : int.tryParse(intervalRaw?.toString() ?? '') ?? 5;
        final derivedMaxPending = (expiresIn ~/ 4).clamp(30, 120).toInt();
        setState(() {
          _userCode = deviceData['user_code'];
          _verificationUri = deviceData['verification_uri'];
          _verificationUriComplete = deviceData['verification_uri_complete'];
          _deviceCode = deviceData['device_code'];
          _interval = interval;
          _isLoading = false;
          _isPolling = true;
          _approvalDetected = false;
          _pollErrorCount = 0;
          _pollAttempt = 0;
          _pendingAfterApprovalCount = 0;
          _flowCompleted = false;
          _maxPendingAfterApproval = derivedMaxPending;
          _expiresInTotal = expiresIn;
          _pollDeadline = DateTime.now().add(Duration(seconds: expiresIn));
          _approvalDetectedAt = null;
          _pollStatusText = "인증 대기 중...";
        });
        _diag.info(
          'github_oauth',
          'Screen flow init interval=${_interval}s expires=${expiresIn}s maxAfterApproval=${_maxPendingAfterApproval}s',
        );
        _initWebView();
        _startUiTicker();
        _startPolling();
      }
    } catch (e) {
      if (mounted) {
        _diag.error('github_oauth', 'Device flow initialization failed: $e');
        _closeWithError("로그인 초기화 실패: $e");
      }
    }
  }

  void _initWebView() {
    final targetUri = _verificationUriComplete ??
        _verificationUri ??
        'https://github.com/login/device';

    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF1E1E1E))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {},
          onPageStarted: (String url) {
            if (url.contains('github.com/login/device/success')) {
              _diag.info('github_oauth', 'Success page started: $url');
            }
          },
          onPageFinished: (String url) {
            _handlePotentialApprovalUrl(url);
            unawaited(_injectOtpFocusAssist());
            Future.delayed(const Duration(milliseconds: 350), () {
              if (mounted) {
                unawaited(_injectOtpFocusAssist());
              }
            });
          },
          onNavigationRequest: (NavigationRequest request) {
            _handlePotentialApprovalUrl(request.url);
            return NavigationDecision.navigate;
          },
          onWebResourceError: (WebResourceError error) {
            _diag.warn(
              'github_webview',
              'Web resource error code=${error.errorCode} type=${error.errorType} desc=${error.description}',
            );
          },
        ),
      )
      ..loadRequest(Uri.parse(targetUri));
    setState(() {});
  }

  Future<void> _injectOtpFocusAssist() async {
    if (_webViewController == null) return;
    try {
      await _webViewController!.runJavaScript('''
(function () {
  try {
    var inputs = Array.from(document.querySelectorAll('input')).filter(function (el) {
      if (el.disabled || el.readOnly) return false;
      var t = (el.type || 'text').toLowerCase();
      if (!(t === 'text' || t === 'tel' || t === 'search' || t === '' || t === 'number')) return false;
      var maxLen = parseInt(el.maxLength || el.getAttribute('maxlength') || '0', 10);
      if (maxLen !== 1) return false;
      var rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    });

    if (inputs.length < 6) return;
    if (inputs.length > 10) inputs = inputs.slice(0, 10);

    var dispatchValueEvents = function (el) {
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };

    inputs.forEach(function (el, idx) {
      if (el.dataset.clAutonextBound === '1') return;
      el.dataset.clAutonextBound = '1';
      el.setAttribute('autocapitalize', 'characters');
      el.setAttribute('autocomplete', 'one-time-code');
      el.setAttribute('autocorrect', 'off');
      el.setAttribute('spellcheck', 'false');
      el.setAttribute('inputmode', 'text');
      el.setAttribute('data-lpignore', 'true');
      el.setAttribute('data-1p-ignore', 'true');
      el.setAttribute('data-bwignore', 'true');
      try { el.autocomplete = 'off'; } catch (_) {}

      el.addEventListener('input', function () {
        var v = (el.value || '').replace(/[^a-zA-Z0-9]/g, '').toUpperCase();
        if (v !== el.value) el.value = v;
        if (v.length > 1) {
          el.value = v.slice(0, 1);
          dispatchValueEvents(el);
        }
        if (el.value && idx < inputs.length - 1) {
          inputs[idx + 1].focus();
          inputs[idx + 1].select && inputs[idx + 1].select();
        }
      });

      el.addEventListener('keydown', function (e) {
        if (e.key === 'ArrowLeft' && idx > 0) {
          e.preventDefault();
          inputs[idx - 1].focus();
          inputs[idx - 1].select && inputs[idx - 1].select();
          return;
        }
        if (e.key === 'ArrowRight' && idx < inputs.length - 1) {
          e.preventDefault();
          inputs[idx + 1].focus();
          inputs[idx + 1].select && inputs[idx + 1].select();
          return;
        }

        if (e.key === 'Backspace' && !el.value && idx > 0) {
          e.preventDefault();
          inputs[idx - 1].focus();
          var prev = inputs[idx - 1];
          prev.value = '';
          dispatchValueEvents(prev);
          prev.select && prev.select();
          return;
        }

        if (e.key === 'Delete') {
          e.preventDefault();
          if (el.value) {
            el.value = '';
            dispatchValueEvents(el);
            return;
          }
          if (idx < inputs.length - 1) {
            var nextEl = inputs[idx + 1];
            nextEl.value = '';
            dispatchValueEvents(nextEl);
            nextEl.focus();
            nextEl.select && nextEl.select();
            return;
          }
        }
      });

      el.addEventListener('paste', function (e) {
        var clip = (e.clipboardData && e.clipboardData.getData('text')) || '';
        if (!clip) return;
        clip = clip.replace(/[^a-zA-Z0-9]/g, '').toUpperCase();
        if (!clip) return;
        e.preventDefault();
        for (var i = 0; i < inputs.length; i++) {
          inputs[i].value = clip[i] || '';
          dispatchValueEvents(inputs[i]);
        }
        var next = Math.min(clip.length, inputs.length - 1);
        if (clip.length >= inputs.length) {
          inputs[inputs.length - 1].blur();
        } else {
          inputs[next].focus();
          inputs[next].select && inputs[next].select();
        }
      });
    });

    var active = document.activeElement;
    var isInputActive = inputs.indexOf(active) >= 0;
    if (!isInputActive) {
      var firstEmpty = inputs.find(function (el) { return !el.value; });
      (firstEmpty || inputs[0]).focus();
    }
  } catch (e) {}
})();
      ''');
    } catch (_) {
      // Ignore if the current page context blocks script execution.
    }
  }

  void _handlePotentialApprovalUrl(String url) {
    if (_approvalDetected) return;
    if (!url.contains('github.com/login/device/success')) return;

    if (mounted) {
      setState(() {
        _approvalDetected = true;
        _approvalDetectedAt = DateTime.now();
        _pollStatusText = "승인됨, 토큰 확인 중";
        _pendingAfterApprovalCount = 0;
      });
    }
    _diag.info('github_oauth', 'Approval URL detected');

    // Poll once immediately after approval, then continue with server-guided interval.
    unawaited(_pollTokenOnce(force: true));
  }

  Future<void> _pollTokenOnce({bool force = false}) async {
    if (!_isPolling || !mounted || _deviceCode == null || _pollInFlight) return;
    if (!force &&
        _nextPollAllowedAt != null &&
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
        _closeWithToken(token);
        return;
      }

      _pollErrorCount = 0;
      if (_approvalDetected) {
        _pendingAfterApprovalCount += 1;
        final elapsed = DateTime.now()
            .difference(_approvalDetectedAt ?? DateTime.now())
            .inSeconds;

        if (mounted) {
          setState(() {
            _pollStatusText = "승인됨, 토큰 확인 중";
          });
        }

        if (elapsed >= _maxPendingAfterApproval ||
            _pendingAfterApprovalCount >= _maxPendingAfterApproval) {
          _closeWithError("승인 후 토큰 확인이 지연되고 있습니다. 네트워크 상태를 확인한 뒤 다시 시도해주세요.");
          return;
        }

        if (_pollAttempt % 10 == 0) {
          _diag.warn(
            'github_oauth',
            'Pending after approval elapsed=${elapsed}s attempts=$_pollAttempt',
          );
        }
      } else if (_pollAttempt % 15 == 0) {
        _diag.info('github_oauth',
            'Still waiting for approval attempts=$_pollAttempt');
      }
    } catch (e) {
      final message = e.toString();
      if (message.contains('slow_down')) {
        _interval += 5;
        if (_interval > 15) _interval = 15;
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
    if (remaining < 0) return 0;
    return remaining;
  }

  int _remainingApprovalSeconds() {
    final detectedAt = _approvalDetectedAt;
    if (detectedAt == null) return _maxPendingAfterApproval;
    final elapsed = DateTime.now().difference(detectedAt).inSeconds;
    final remaining = _maxPendingAfterApproval - elapsed;
    if (remaining < 0) return 0;
    return remaining;
  }

  double _approvalProgressValue() {
    if (_maxPendingAfterApproval <= 0) return 0;
    final detectedAt = _approvalDetectedAt;
    if (detectedAt == null) return 0;
    final elapsed = DateTime.now().difference(detectedAt).inSeconds;
    final raw = elapsed / _maxPendingAfterApproval;
    return raw.clamp(0.0, 1.0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _isPolling = false;
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text("GitHub 로그인"),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              _isPolling = false;
              Navigator.of(context).pop();
            },
          ),
          actions: [
            if (_webViewController != null)
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => _webViewController?.reload(),
                tooltip: "새로고침",
              ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  // 상단: 인증 코드 표시
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      border: Border(
                        bottom: BorderSide(color: Colors.grey[700]!),
                      ),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          "코드 입력은 자동 처리됩니다",
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 24),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF6D00),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _userCode ?? "ERROR",
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 6,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _approvalDetected
                              ? "승인 감지됨, 토큰 확인 중..."
                              : "입력 시 다음 칸으로 자동 이동합니다. 승인하면 앱이 자동 완료됩니다.",
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[300]),
                        ),
                        const SizedBox(height: 8),
                        if (_isPolling)
                          Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.grey[400],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _pollStatusText,
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.grey[400]),
                                  ),
                                ],
                              ),
                              if (_approvalDetected) ...[
                                const SizedBox(height: 6),
                                Text(
                                  "남은 시간 ${_remainingApprovalSeconds()}초",
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.grey[400]),
                                ),
                                const SizedBox(height: 6),
                                SizedBox(
                                  width: 240,
                                  child: LinearProgressIndicator(
                                    value: _approvalProgressValue(),
                                    minHeight: 4,
                                    backgroundColor: Colors.grey[800],
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                            Color(0xFFFF6D00)),
                                  ),
                                ),
                              ] else ...[
                                const SizedBox(height: 6),
                                Text(
                                  "인증 만료까지 ${_remainingFlowSeconds()}초",
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.grey[500]),
                                ),
                              ],
                            ],
                          ),
                      ],
                    ),
                  ),
                  // 하단: WebView로 GitHub 인증 페이지
                  Expanded(
                    child: _webViewController != null
                        ? WebViewWidget(controller: _webViewController!)
                        : const Center(child: CircularProgressIndicator()),
                  ),
                ],
              ),
      ),
    );
  }
}
