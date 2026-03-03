part of 'connection_settings_screen.dart';

extension _ConnectionSettingsPersistence on _ConnectionSettingsScreenState {
  String _normalizePublicKeyForCompare(String key) {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0]} ${parts[1]}';
    }
    return trimmed;
  }

  Map<String, dynamic>? _findMatchingRemoteKeyByPublic(String localPublicKey) {
    final localNormalized = _normalizePublicKeyForCompare(localPublicKey);
    if (localNormalized.isEmpty) return null;

    for (final key in _keys) {
      final remoteRaw = key['key']?.toString() ?? '';
      final remoteNormalized = _normalizePublicKeyForCompare(remoteRaw);
      if (remoteNormalized == localNormalized) {
        return key;
      }
    }
    return null;
  }

  Future<void> _migrateAndLoadSettings() async {
    // 기존 구조에서 새 구조로 마이그레이션
    final oldActiveId = await _storage.read(key: 'active_key_id');
    final newKeyType = await _storage.read(key: 'current_key_type');

    if (oldActiveId != null && newKeyType == null) {
      // 마이그레이션 필요
      final oldPrivateKey =
          await _storage.read(key: 'private_key_$oldActiveId');
      final oldPublicKey = await _storage.read(key: 'public_key_$oldActiveId');

      if (oldPrivateKey != null) {
        // 새 구조로 복사
        await _storage.write(
            key: 'generated_key_$oldActiveId', value: oldPrivateKey);
        if (oldPublicKey != null) {
          await _storage.write(
              key: 'generated_pub_$oldActiveId', value: oldPublicKey);
        }
        await _storage.write(key: 'current_key_type', value: 'generated');
        await _storage.write(key: 'current_private_key', value: oldPrivateKey);
        await _storage.write(key: 'active_generated_id', value: oldActiveId);
      }
    }

    await _migrateLegacyUserPrivateKey();
    await _loadSettings();
    await _refreshBackupStatus();
  }

  Future<void> _migrateLegacyUserPrivateKey() async {
    final currentKey = await _storage.read(key: 'current_private_key');
    if (currentKey != null && currentKey.isNotEmpty) {
      return;
    }

    final legacyPrivate = await _storage.read(key: 'user_private_key');
    if (legacyPrivate == null || legacyPrivate.isEmpty) {
      return;
    }

    await _storage.write(key: 'current_key_type', value: 'generated');
    await _storage.write(key: 'current_private_key', value: legacyPrivate);
    await _storage.delete(key: 'active_generated_id');
    await _storage.write(key: 'key_verified', value: 'false');

    await _backupPrivateKeyToLocal(
      legacyPrivate,
      keyTitle: 'carrotpilot_legacy',
      interactive: false,
    );
  }

  Future<void> _loadSettings() async {
    await _storage.delete(key: 'ssh_ip');
    var username = await _storage.read(key: 'ssh_username');
    final password = await _storage.read(key: 'ssh_password');
    var port = await _storage.read(key: 'ssh_port');

    if (username == null || username.trim().isEmpty) {
      username = _ConnectionSettingsScreenState._fixedSshUsername;
      await _storage.write(key: 'ssh_username', value: username);
    }
    if (port == null || port.trim().isEmpty) {
      port = _ConnectionSettingsScreenState._fixedSshPort.toString();
      await _storage.write(key: 'ssh_port', value: port);
    }

    debugPrint('[Settings] Loaded Username: $username');

    // 새 구조에서 키 로드
    final keyType = await _storage.read(key: 'current_key_type');
    final privateKey = await _storage.read(key: 'current_private_key');
    final generatedId = await _storage.read(key: 'active_generated_id');

    String? generatedTitle;
    if (generatedId != null) {
      // GitHub 키 목록에서 제목 찾기 (나중에 로드됨)
      generatedTitle = "carrotpilot 키";
    }

    if (mounted) {
      _setStateSafe(() {
        _ipController.clear();
        _lockDiscoveryIpOverwrite = false;
        _autoFilledIp = null;
        if (username != null) _usernameController.text = username;
        if (password != null) _passwordController.text = password;
        if (port != null && port.isNotEmpty) _portController.text = port;

        _currentKeyType = keyType;
        _currentPrivateKey = privateKey;
        _activeGeneratedId = generatedId;
        _activeGeneratedTitle = generatedTitle;
        _manualKeyController.text = privateKey ?? '';
      });
      _maybeAutoStartDiscovery();
    }
  }

  // ========== 키 적용/해제 메서드 ==========

  Future<void> _setActivePrivateKey({
    required String privateKey,
    required String keyType,
    String? generatedId,
    String? generatedTitle,
  }) async {
    await _storage.write(key: 'current_key_type', value: keyType);
    await _storage.write(key: 'current_private_key', value: privateKey);
    if (generatedId != null && generatedId.isNotEmpty) {
      await _storage.write(key: 'active_generated_id', value: generatedId);
    } else {
      await _storage.delete(key: 'active_generated_id');
    }
    await _storage.write(key: 'key_verified', value: 'false');
    if (mounted) {
      try {
        Provider.of<SSHService>(context, listen: false).resumeAutoReconnect();
      } catch (_) {}
    }

    if (!mounted) return;
    _setStateSafe(() {
      _currentKeyType = keyType;
      _currentPrivateKey = privateKey;
      _activeGeneratedId = generatedId;
      _activeGeneratedTitle = generatedTitle;
      if (!_isManualKeyEditing) {
        _manualKeyController.text = privateKey;
      }
    });
  }

  Future<void> _backupPrivateKeyToLocal(
    String privateKey, {
    required String keyTitle,
    bool interactive = false,
  }) async {
    // Request shared-storage access only on explicit/interactive flow.
    // If denied, backup still attempts app-specific external storage.
    if (interactive) {
      await _keyBackupService.ensureStoragePermission(
          requestForSharedStorage: true);
    }

    final savedPath = await _keyBackupService.savePrivateKeyBackup(
      privateKey: privateKey,
      keyTitle: keyTitle,
    );
    if (interactive && mounted) {
      if (savedPath != null) {
        CustomToast.show(context, "로컬 키 백업 완료");
      } else {
        CustomToast.show(context, "로컬 키 백업 실패", isError: true);
      }
    }
    await _refreshBackupStatus();
  }

  Future<void> _refreshBackupStatus() async {
    final status = await _keyBackupService.getBackupLocationStatus();
    final labels = <String>[];
    if (status['auth'] == true) labels.add('CarrotLink/auth');
    if (status['documents'] == true) labels.add('Documents');
    if (status['download'] == true) labels.add('Download');
    if (status['app_external'] == true) labels.add('App-External');
    final summary = labels.isEmpty ? '백업 없음' : '백업 위치: ${labels.join(", ")}';

    if (!mounted) return;
    _setStateSafe(() {
      _backupLocationSummary = summary;
    });
  }

  Future<bool> _restoreLocalBackupOnly({bool interactive = false}) async {
    try {
      if (interactive) {
        await _keyBackupService.ensureStoragePermission(
            requestForSharedStorage: true);
      }

      final backup = await _keyBackupService.loadPrivateKeyBackup();
      if (backup == null) return false;

      await _setActivePrivateKey(
        privateKey: backup.privateKey,
        keyType: 'generated',
        generatedId: null,
        generatedTitle: backup.keyTitle,
      );
      await _backupPrivateKeyToLocal(
        backup.privateKey,
        keyTitle: backup.keyTitle,
        interactive: false,
      );

      if (interactive && mounted) {
        CustomToast.show(context, "로컬 백업 키를 불러왔습니다.");
      }
      return true;
    } catch (e) {
      debugPrint("Failed to restore local backup key only: $e");
      return false;
    }
  }

  Future<bool> _restoreFromLocalBackupAndSync(
      {bool interactive = false}) async {
    try {
      if (interactive) {
        await _keyBackupService.ensureStoragePermission(
            requestForSharedStorage: true);
      }

      final backup = await _keyBackupService.loadPrivateKeyBackup();
      if (backup == null) {
        return false;
      }

      final derivedPublic =
          await _githubService.getPublicKeyFromPrivateKey(backup.privateKey);
      if (derivedPublic == null || derivedPublic.isEmpty) {
        return false;
      }

      Map<String, dynamic>? matched =
          _findMatchingRemoteKeyByPublic(derivedPublic);

      String finalTitle = backup.keyTitle;
      String? finalKeyId;
      if (matched != null) {
        finalKeyId = matched['id']?.toString();
        finalTitle = matched['title']?.toString() ?? backup.keyTitle;
      } else {
        final uploadTitle = _newManagedKeyTitle();
        try {
          final createdId =
              await _githubService.uploadPublicKey(uploadTitle, derivedPublic);
          if (createdId != null) {
            finalKeyId = createdId.toString();
            finalTitle = uploadTitle;
          }
        } catch (e) {
          final message = e.toString();
          if (message.contains('key is already in use')) {
            _diag.warn(
              'key',
              'GitHub reports key already in use; reload and match existing key',
            );
            final loaded = await _loadKeys();
            if (loaded) {
              matched = _findMatchingRemoteKeyByPublic(derivedPublic);
              if (matched != null) {
                finalKeyId = matched['id']?.toString();
                finalTitle = matched['title']?.toString() ?? backup.keyTitle;
              }
            }
          } else {
            rethrow;
          }
        }
      }

      if (finalKeyId == null || finalKeyId.isEmpty) {
        if (interactive && mounted) {
          CustomToast.show(context, "로컬 키는 찾았지만 GitHub 동기화에 실패했습니다.",
              isError: true);
        }
        return false;
      }

      await _storage.write(
          key: 'generated_key_$finalKeyId', value: backup.privateKey);
      await _storage.write(
          key: 'generated_pub_$finalKeyId', value: derivedPublic);
      // Backward compatibility keys
      await _storage.write(
          key: 'private_key_$finalKeyId', value: backup.privateKey);
      await _storage.write(key: 'public_key_$finalKeyId', value: derivedPublic);

      await _setActivePrivateKey(
        privateKey: backup.privateKey,
        keyType: 'generated',
        generatedId: finalKeyId,
        generatedTitle: finalTitle,
      );
      await _backupPrivateKeyToLocal(
        backup.privateKey,
        keyTitle: finalTitle,
        interactive: false,
      );
      await _syncActiveKeyToManagedGist(
        overridePrivateKey: backup.privateKey,
        overrideTitle: finalTitle,
        overrideKeyId: finalKeyId,
      );

      if (interactive && mounted) {
        CustomToast.show(context, "로컬 백업 키를 복원했습니다.");
      }
      return true;
    } catch (e) {
      debugPrint("Failed to restore local backup key: $e");
      if (interactive && mounted) {
        CustomToast.show(context, "로컬 키 복원 실패: $e", isError: true);
      }
      return false;
    }
  }

  Future<bool> _restoreFromManagedKeyringGist(
      {bool interactive = false}) async {
    if (!_isGitHubLoggedIn) return false;

    try {
      final keyring = await _githubService.loadManagedKeyring();
      if (keyring == null) return false;

      final activeFingerprint = keyring['activeFingerprint']?.toString() ?? '';
      final rawKeys = keyring['keys'];
      if (rawKeys is! List || rawKeys.isEmpty) {
        return false;
      }

      String? selectedPrivate;
      String? selectedId;
      String? selectedTitle;
      bool selectedPreferred = false;
      var matchedCount = 0;

      for (final raw in rawKeys) {
        if (raw is! Map) continue;
        final item = raw.cast<String, dynamic>();
        final privateKey = item['privateKeyPem']?.toString() ?? '';
        if (privateKey.isEmpty) continue;

        final derivedPublic =
            await _githubService.getPublicKeyFromPrivateKey(privateKey);
        if (derivedPublic == null || derivedPublic.isEmpty) continue;

        final matched = _findMatchingRemoteKeyByPublic(derivedPublic);
        if (matched == null) continue;

        final keyId = matched['id']?.toString();
        if (keyId == null || keyId.isEmpty) continue;

        final title = matched['title']?.toString() ??
            item['title']?.toString() ??
            _ConnectionSettingsScreenState._managedKeyPrefix;

        await _storage.write(key: 'generated_key_$keyId', value: privateKey);
        await _storage.write(key: 'generated_pub_$keyId', value: derivedPublic);
        await _storage.write(key: 'private_key_$keyId', value: privateKey);
        await _storage.write(key: 'public_key_$keyId', value: derivedPublic);

        matchedCount += 1;
        final fp = item['fingerprint']?.toString() ?? '';
        final isPreferred =
            activeFingerprint.isNotEmpty && fp == activeFingerprint;

        if (selectedPrivate == null || (!selectedPreferred && isPreferred)) {
          selectedPrivate = privateKey;
          selectedId = keyId;
          selectedTitle = title;
          selectedPreferred = isPreferred;
        }
      }

      if (selectedPrivate == null || selectedId == null) {
        return false;
      }

      await _setActivePrivateKey(
        privateKey: selectedPrivate,
        keyType: 'generated',
        generatedId: selectedId,
        generatedTitle: selectedTitle,
      );
      await _backupPrivateKeyToLocal(
        selectedPrivate,
        keyTitle:
            selectedTitle ?? _ConnectionSettingsScreenState._managedKeyPrefix,
        interactive: false,
      );
      await _syncActiveKeyToManagedGist(
        overridePrivateKey: selectedPrivate,
        overrideTitle:
            selectedTitle ?? _ConnectionSettingsScreenState._managedKeyPrefix,
        overrideKeyId: selectedId,
      );
      _diag.info('key',
          'Restored from managed gist matched=$matchedCount activeId=$selectedId');

      if (interactive && mounted) {
        CustomToast.show(context, "GitHub 키 저장소에서 개인키를 복원했습니다.");
      }
      return true;
    } catch (e) {
      debugPrint("Failed to restore key from managed gist: $e");
      if (interactive && mounted) {
        CustomToast.show(context, "GitHub 키 복원 실패: $e", isError: true);
      }
      return false;
    }
  }

  Future<bool> _syncActiveKeyToManagedGist({
    String? overridePrivateKey,
    String? overrideTitle,
    String? overrideKeyId,
  }) async {
    if (!_isGitHubLoggedIn) return false;

    final privateKey = overridePrivateKey ?? _currentPrivateKey;
    if (privateKey == null || privateKey.isEmpty) return false;

    final keyIdRaw = overrideKeyId ?? _activeGeneratedId;
    final keyId = keyIdRaw == null ? null : int.tryParse(keyIdRaw);
    final title = overrideTitle ??
        _activeGeneratedTitle ??
        _ConnectionSettingsScreenState._managedKeyPrefix;

    try {
      await _githubService.upsertManagedKeyringKey(
        privateKeyPem: privateKey,
        title: title,
        githubKeyId: keyId,
        setActive: true,
      );
      return true;
    } catch (e) {
      _diag.warn('key', 'Managed gist sync failed: $e');
      return false;
    }
  }

  Future<void> _attachActiveKeyToRemoteIfPossible() async {
    if (!_hasActiveSshKey || _activeGeneratedId != null || _keys.isEmpty) {
      return;
    }

    final privateKey = _currentPrivateKey;
    if (privateKey == null || privateKey.isEmpty) return;

    final derivedPublic =
        await _githubService.getPublicKeyFromPrivateKey(privateKey);
    if (derivedPublic == null || derivedPublic.isEmpty) return;

    final matched = _findMatchingRemoteKeyByPublic(derivedPublic);
    if (matched == null) return;

    final matchedId = matched['id']?.toString();
    if (matchedId == null || matchedId.isEmpty) return;

    await _storage.write(key: 'generated_key_$matchedId', value: privateKey);
    await _storage.write(key: 'generated_pub_$matchedId', value: derivedPublic);
    await _storage.write(key: 'private_key_$matchedId', value: privateKey);
    await _storage.write(key: 'public_key_$matchedId', value: derivedPublic);
    await _storage.write(key: 'active_generated_id', value: matchedId);
    await _storage.write(key: 'current_key_type', value: 'generated');

    if (!mounted) return;
    _setStateSafe(() {
      _currentKeyType = 'generated';
      _activeGeneratedId = matchedId;
      _activeGeneratedTitle =
          matched['title']?.toString() ?? _activeGeneratedTitle;
    });
    await _syncActiveKeyToManagedGist(
      overridePrivateKey: privateKey,
      overrideTitle: matched['title']?.toString() ?? _activeGeneratedTitle,
      overrideKeyId: matchedId,
    );
  }
}
