part of 'connection_settings_screen.dart';

extension _ConnectionSettingsDiscovery on _ConnectionSettingsScreenState {
  void _maybeAutoStartDiscovery() {
    if (!mounted) return;
    if (!_isOpenpilotReady) return;
    if (_ipController.text.trim().isNotEmpty) return;

    final ssh = _sshRef;
    if (ssh == null) return;
    if (ssh.isConnected || ssh.isConnecting || ssh.isDiscoveryActive) return;

    unawaited(
      _startDiscovery(
        manualSession: false,
        forceRestart: false,
        timeout: const Duration(seconds: 15),
      ),
    );
  }

  Future<void> _runGuidedDiscovery() async {
    if (!mounted) return;
    _getSsh().resumeAutoReconnect();
    _setStateSafe(() {
      _lockDiscoveryIpOverwrite = false;
      _autoFilledIp = null;
      _ipController.clear();
      _manualDiscoverySession = true;
      _discoverySeenIps.clear();
    });
    await _startDiscovery(
      manualSession: true,
      forceRestart: true,
      timeout: const Duration(seconds: 60),
      toastOnStart: true,
    );
    if (!mounted) return;
    _diag.info('discovery', 'Manual discovery started from settings');
    CustomToast.show(context, 'IP 자동 검색을 시작합니다.');
  }

  Future<void> _startDiscovery({
    required bool manualSession,
    required bool forceRestart,
    required Duration timeout,
    bool toastOnStart = false,
  }) async {
    try {
      final ssh = _getSsh();
      final started = await ssh.startDiscovery(
        forceRestart: forceRestart,
        timeout: timeout,
        source: manualSession ? 'settings_manual' : 'settings_auto',
        manualSession: manualSession,
      );

      if (!started && manualSession && mounted) {
        CustomToast.show(context, "이미 검색 중입니다.");
      }
      _diag.info(
        'discovery',
        'Settings discovery start manual=$manualSession force=$forceRestart timeout=${timeout.inSeconds}s started=$started',
      );

      if (mounted) {
        _setStateSafe(() {
          _manualDiscoverySession = manualSession;
          _discoveryStatus = manualSession ? '수동 검색 중...' : '자동 검색 중...';
        });
      }
      _discoveryStatusTimer?.cancel();
      _discoveryStatusTimer =
          Timer(timeout + const Duration(milliseconds: 300), () {
        if (!mounted) return;
        _setStateSafe(() {
          _discoveryStatus = '대기';
          _manualDiscoverySession = false;
          _discoverySeenIps.clear();
        });
      });

      if (toastOnStart && manualSession && mounted) {
        CustomToast.show(context, "기기 검색을 시작합니다.");
      }

      _discoverySubscription?.cancel();
      _discoverySubscription = ssh.ipDiscoveryStream.listen(
        (ip) {
          if (!mounted) return;
          if (ssh.discoverySource != 'settings_manual' &&
              ssh.discoverySource != 'settings_auto') {
            return;
          }

          var isNewCandidate = false;
          _setStateSafe(() {
            if (_discoverySeenIps.add(ip)) {
              isNewCandidate = true;
              if (_discoverySeenIps.length > 8) {
                _discoverySeenIps.remove(_discoverySeenIps.first);
              }
            }
          });

          final currentIp = _ipController.text.trim();
          final canAutoFill = !_lockDiscoveryIpOverwrite &&
              (currentIp.isEmpty ||
                  (_autoFilledIp != null && currentIp == _autoFilledIp));

          if (canAutoFill && currentIp != ip) {
            _setStateSafe(() {
              _ipController.text = ip;
              _autoFilledIp = ip;
            });
            if (manualSession && isNewCandidate) {
              CustomToast.show(context, "기기 발견: $ip (자동 입력)");
            }
            debugPrint('[Settings] Auto-filled discovered IP: $ip');
          } else if (manualSession && currentIp != ip && isNewCandidate) {
            CustomToast.show(context, "기기 발견: $ip");
          }

          if (manualSession && mounted) {
            _setStateSafe(() {
              _discoveryStatus = '검색 중 (${_discoverySeenIps.length}개 발견)';
            });
          }
          if (isNewCandidate) {
            _diag.info('discovery', 'Settings candidate: $ip');
            debugPrint(
                '[Settings] Discovered IP candidate: $ip (manual lock: $_lockDiscoveryIpOverwrite)');
          }
        },
        onError: (e) => debugPrint("Discovery error: $e"),
      );
    } catch (e) {
      debugPrint("Failed to start discovery: $e");
    }
  }

  Future<void> _connect() async {
    final ssh = _getSsh();
    if (ssh.isConnecting) {
      CustomToast.show(context, "이미 연결 시도 중입니다.");
      return;
    }
    if (ssh.isConnected) {
      CustomToast.show(context, "이미 연결되어 있습니다.");
      return;
    }

    ssh.resumeAutoReconnect();
    final ipToSave = _ipController.text.trim();
    const usernameToSave = _ConnectionSettingsScreenState._fixedSshUsername;
    const port = _ConnectionSettingsScreenState._fixedSshPort;

    if (ipToSave.isEmpty) {
      CustomToast.show(context, "IP 주소를 입력하세요.", isError: true);
      return;
    }
    final parsedIp = InternetAddress.tryParse(ipToSave);
    if (parsedIp == null || parsedIp.type != InternetAddressType.IPv4) {
      CustomToast.show(context, "올바른 IPv4 주소를 입력하세요.", isError: true);
      return;
    }

    try {
      final privateKey = _currentPrivateKey?.trim();
      final savedPassword = _passwordController.text.trim();
      final authKey =
          (privateKey != null && privateKey.isNotEmpty) ? privateKey : null;
      final authPassword = authKey == null
          ? (savedPassword.isNotEmpty ? savedPassword : null)
          : null;

      if (authKey == null && authPassword == null) {
        CustomToast.show(context, "SSH 키 또는 비밀번호를 준비하세요.", isError: true);
        return;
      }

      await ssh.connect(
        ipToSave,
        usernameToSave,
        port: port,
        password: authPassword,
        privateKey: authKey,
      );

      // IP는 브로드캐스트 기준으로만 사용한다.
      await _storage.delete(key: 'ssh_ip');
      await _storage.write(key: 'ssh_username', value: usernameToSave);
      await _storage.write(key: 'ssh_port', value: port.toString());
      if (authPassword != null) {
        await _storage.write(key: 'ssh_password', value: authPassword);
      }
      _lockDiscoveryIpOverwrite = true;
      _autoFilledIp = null;
      ssh.stopDiscovery();
      _discoveryStatusTimer?.cancel();
      if (mounted) {
        _setStateSafe(() {
          _discoveryStatus = '대기';
          _manualDiscoverySession = false;
          _discoverySeenIps.clear();
        });
      }
      debugPrint(
          '[Settings] Connection successful, endpoint saved: $ipToSave:$port');
      _diag.info('ssh',
          'Manual connect success endpoint=$usernameToSave@$ipToSave:$port');

      if (mounted) {
        CustomToast.show(context, '연결 성공');
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('[Settings] Connection failed: $e');
      _diag.warn('ssh',
          'Manual connect failed endpoint=$usernameToSave@$ipToSave:$port error=$e');
      if (mounted) {
        CustomToast.show(context, '연결 실패: $e', isError: true);
        await _showSimpleFailureLog("SSH 연결 실패", e.toString());
      }
    }
  }

  Future<void> _disconnect() async {
    final ssh = _getSsh();
    final wasConnecting = ssh.isConnecting && !ssh.isConnected;
    await ssh.disconnect();
    if (mounted) {
      CustomToast.show(context, wasConnecting ? '연결 시도 취소됨' : '연결 해제됨');
    }
  }

  String _buildRecentDiagSnippet({int maxLines = 12}) {
    final rows = _diag.entries.take(maxLines).map((entry) {
      final iso = entry.timestamp.toIso8601String();
      final hhmmss = iso.length >= 19 ? iso.substring(11, 19) : iso;
      return '[$hhmmss][${entry.level}/${entry.category}] ${entry.message}';
    }).toList();
    if (rows.isEmpty) {
      return '최근 내부 로그가 없습니다.';
    }
    return rows.join('\n');
  }

  Future<void> _showSimpleFailureLog(String title, String errorMessage) async {
    if (!mounted) return;
    final logText = _buildRecentDiagSnippet();
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                errorMessage,
                style: TextStyle(color: scheme.error),
              ),
              SizedBox(height: tokens.itemGap + 6),
              Text(
                "최근 내부 로그",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: window.isCompact ? 13.0 : 14.0,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(tokens.itemGap + 6),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  logText,
                  style: TextStyle(
                    fontSize: window.isCompact ? 10.5 : 11.0,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("확인"),
          ),
        ],
      ),
    );
  }
}
