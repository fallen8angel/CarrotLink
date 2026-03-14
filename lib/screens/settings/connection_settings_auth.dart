part of 'connection_settings_screen.dart';

extension _ConnectionSettingsAuth on _ConnectionSettingsScreenState {
  Future<void> _checkGitHubLogin() async {
    bool loggedIn = false;
    try {
      final status = await _githubService.validateSavedToken();
      switch (status) {
        case GitHubTokenValidationStatus.missing:
          loggedIn = false;
          break;
        case GitHubTokenValidationStatus.valid:
          loggedIn = true;
          break;
        case GitHubTokenValidationStatus.invalid:
          loggedIn = false;
          await _githubService.clearToken();
          break;
        case GitHubTokenValidationStatus.insufficientScope:
          loggedIn = false;
          await _githubService.clearToken();
          _diag.warn('github',
              'Saved token missing required scopes(admin:public_key + gist + repo). forcing re-login');
          break;
        case GitHubTokenValidationStatus.transientError:
          final token = await _githubService.getToken();
          loggedIn = token != null && token.isNotEmpty;
          _diag.warn(
            'github',
            'Token validation deferred due transient network/server issue. keepLoggedIn=$loggedIn',
          );
          break;
      }
    } catch (e) {
      loggedIn = false;
      _diag.warn('github', 'Login check failed: $e');
    }

    if (mounted) {
      _setStateSafe(() => _isGitHubLoggedIn = loggedIn);
      if (loggedIn) {
        await _syncKeyStateAfterLogin(interactive: false);
      }
      _maybeAutoStartDiscovery();
    }
  }

  Future<void> _syncKeyStateAfterLogin({required bool interactive}) async {
    _diag.info('key', 'Sync key state after login');
    final loaded = await _loadKeys();
    if (!loaded) {
      final restoredLocalOnly =
          await _restoreLocalBackupOnly(interactive: interactive);
      if (restoredLocalOnly) {
        _diag.warn('key', 'Loaded local backup key without GitHub key list');
      }
      return;
    }

    if (_hasActiveSshKey) {
      await _attachActiveKeyToRemoteIfPossible();
      await _syncActiveKeyToManagedGist();
      return;
    }

    final restoredFromGist =
        await _restoreFromManagedKeyringGist(interactive: interactive);
    if (restoredFromGist) {
      _diag.info('key', 'Restored key from managed gist');
      await _loadKeys();
      return;
    }

    final restored =
        await _restoreFromLocalBackupAndSync(interactive: interactive);
    if (restored) {
      _diag.info('key', 'Restored key from local backup and synced to GitHub');
      await _loadKeys();
      return;
    }

    final reused = await _activateFirstUsableGeneratedKey();
    if (reused) {
      _diag.info('key', 'Activated existing generated key');
      await _syncActiveKeyToManagedGist();
    }
  }

  Future<void> _loginToGitHub() async {
    // Simplified flow: always use GitHub Device Flow.
    await _startDeviceFlow();
  }

  // ignore: unused_element
  Future<bool> _ensureOpenpilotReady({
    bool interactive = true,
    bool allowKeyGeneration = true,
  }) async {
    if (!_isGitHubLoggedIn) {
      if (interactive && mounted) {
        CustomToast.show(context, "GitHub 로그인 후 사용할 수 있습니다.", isError: true);
      }
      return false;
    }

    if (_hasActiveSshKey) {
      return true;
    }

    final loaded = await _loadKeys();
    if (!loaded) {
      if (interactive && mounted) {
        CustomToast.show(context, "GitHub 키 목록을 불러오지 못했습니다.", isError: true);
      }
      return false;
    }

    if (_hasActiveSshKey) {
      await _attachActiveKeyToRemoteIfPossible();
      await _syncActiveKeyToManagedGist();
      return true;
    }

    final restoredFromGist =
        await _restoreFromManagedKeyringGist(interactive: interactive);
    if (restoredFromGist) {
      return true;
    }

    final restoredLocalOnly =
        await _restoreLocalBackupOnly(interactive: interactive);
    if (restoredLocalOnly) {
      _diag.info('key', 'Recovered local key for connect readiness');
      return true;
    }

    final restored =
        await _restoreFromLocalBackupAndSync(interactive: interactive);
    if (restored) {
      await _loadKeys();
      return true;
    }

    final reused = await _activateFirstUsableGeneratedKey();
    if (reused) {
      return true;
    }

    if (allowKeyGeneration && _keys.isEmpty) {
      if (interactive) {
        await _showKeyGenerationDialog();
      }
      if (_hasActiveSshKey) return true;
    }

    if (interactive && mounted) {
      if (_keys.isEmpty) {
        CustomToast.show(context, "사용 가능한 키가 없어 생성이 필요합니다.", isError: true);
      } else {
        CustomToast.show(context, "적용 가능한 개인키가 없습니다. 로컬 키를 적용하거나 새 키를 생성하세요.",
            isError: true);
      }
    }
    return false;
  }

  Future<void> _startDeviceFlow() async {
    if (!mounted) return;
    _diag.info('github_oauth', 'Launching GitHub device flow screen');
    final nav = Navigator.of(context);
    final token = await nav.push<String>(
      MaterialPageRoute(
        builder: (context) => GithubLoginScreen(githubService: _githubService),
      ),
    );

    if (!mounted) return;
    if (token != null) {
      _diag.info(
          'github_oauth', 'Device flow returned token, verifying in settings');
      await _githubService.saveToken(token);
      if (!mounted) return;
      await _checkGitHubLogin();
      if (!mounted) return;
      if (!_isGitHubLoggedIn) {
        CustomToast.show(context, "GitHub 인증 결과를 확인하지 못했습니다. 다시 시도해주세요.",
            isError: true);
        return;
      }
      await _syncKeyStateAfterLogin(interactive: true);
      if (!mounted) return;
      final ssh = _sshRef;
      if (ssh != null) {
        await ssh.syncAutoConnectProfile();
      } else {
        await _getSsh().syncAutoConnectProfile();
      }
      CustomToast.show(context, "GitHub 로그인 성공");
      if (!_hasActiveSshKey) {
        final loaded = await _loadKeys();
        if (!mounted) return;
        if (loaded && _keys.isEmpty) {
          await _showKeyGenerationDialog();
        } else {
          CustomToast.show(context, "적용 가능한 개인키가 없습니다. 로컬 키를 적용하거나 새 키를 생성하세요.",
              isError: true);
        }
      }
    }
  }

  Future<void> _showKeyGenerationDialog() async {
    if (!mounted) return;
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("SSH 키 생성"),
        content: Padding(
          padding: EdgeInsets.only(top: tokens.itemGap),
          child: Text(
            "GitHub 로그인이 완료되었습니다.\n\n새로운 SSH 키를 생성하고 GitHub에 등록하시겠습니까?\n\n이렇게 하면 기기에 비밀번호 없이 연결할 수 있습니다.",
            style: TextStyle(fontSize: window.isCompact ? 13.0 : 13.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("나중에"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("키 생성"),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      await _generateAndRegisterKey();
    }
  }

  Future<void> _generateAndRegisterKey() async {
    try {
      CustomToast.show(context, "키 생성 중...");
      await Future.delayed(const Duration(milliseconds: 100));

      final helper = SSHKeyHelper();
      final keyPair = await helper.generateAndSaveKey();

      if (mounted) CustomToast.show(context, "GitHub에 등록 중...");
      final title = _newManagedKeyTitle();
      final keyId =
          await _githubService.uploadPublicKey(title, keyPair['public']!);

      if (keyId != null) {
        // 새 구조로 저장
        await _storage.write(
            key: 'generated_key_$keyId', value: keyPair['private']);
        await _storage.write(
            key: 'generated_pub_$keyId', value: keyPair['public']);

        // 기존 구조에도 저장 (호환성)
        await _storage.write(
            key: 'private_key_$keyId', value: keyPair['private']);
        await _storage.write(
            key: 'public_key_$keyId', value: keyPair['public']);

        debugPrint("Saved key with ID: $keyId");

        // 바로 적용
        await _applyGeneratedKey(keyId.toString(), title);
        await _backupPrivateKeyToLocal(
          keyPair['private']!,
          keyTitle: title,
          interactive: true,
        );
      }

      await _loadKeys();

      if (mounted) {
        CustomToast.show(
            context, "키 생성 완료!\n기기에서 GitHub 사용자명을 설정하면 자동으로 키를 가져옵니다.");
      }
    } catch (e) {
      if (mounted) CustomToast.show(context, "오류: $e", isError: true);
    }
  }

  // ========== 연결 관련 ==========
}
