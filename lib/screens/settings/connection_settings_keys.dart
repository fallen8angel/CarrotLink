part of 'connection_settings_screen.dart';

extension _ConnectionSettingsKeys on _ConnectionSettingsScreenState {
  Future<Map<String, bool>> _buildLocalPrivateKeyAvailability(
    List<Map<String, dynamic>> keys,
  ) async {
    final availability = <String, bool>{};
    for (final key in keys) {
      final keyId = key['id']?.toString();
      if (keyId == null || keyId.isEmpty) continue;
      final generated = await _storage.read(key: 'generated_key_$keyId');
      final legacy = generated == null || generated.isEmpty
          ? await _storage.read(key: 'private_key_$keyId')
          : null;
      availability[keyId] = (generated != null && generated.isNotEmpty) ||
          (legacy != null && legacy.isNotEmpty);
    }
    return availability;
  }

  Future<Map<String, dynamic>?> _findMatchingRemoteKeyFromPrivateKey(
      String privateKey) async {
    final derivedPublic =
        await _githubService.getPublicKeyFromPrivateKey(privateKey);
    if (derivedPublic == null || derivedPublic.isEmpty) {
      return null;
    }
    if (_keys.isEmpty) {
      await _loadKeys();
    }
    return _findMatchingRemoteKeyByPublic(derivedPublic);
  }

  Future<void> _applyManualKey() async {
    final privateKey = _manualKeyController.text.trim();

    if (privateKey.isEmpty) {
      CustomToast.show(context, "개인키를 입력하세요.", isError: true);
      return;
    }

    if (!privateKey.contains('-----BEGIN') ||
        !privateKey.contains('PRIVATE KEY-----')) {
      CustomToast.show(context, "올바른 PEM 형식의 개인키를 입력하세요.", isError: true);
      return;
    }

    final matchedRemote =
        await _findMatchingRemoteKeyFromPrivateKey(privateKey);
    final matchedId = matchedRemote?['id']?.toString();
    final matchedTitle = matchedRemote?['title']?.toString() ?? 'GitHub 등록 키';
    final matchedAsGenerated = matchedId != null && matchedId.isNotEmpty;

    await _setActivePrivateKey(
      privateKey: privateKey,
      keyType: matchedAsGenerated ? 'generated' : 'manual',
      generatedId: matchedAsGenerated ? matchedId : null,
      generatedTitle: matchedAsGenerated ? matchedTitle : null,
    );

    if (matchedAsGenerated) {
      await _storage.write(key: 'generated_key_$matchedId', value: privateKey);
      await _storage.write(key: 'private_key_$matchedId', value: privateKey);
      final derivedPublic =
          await _githubService.getPublicKeyFromPrivateKey(privateKey);
      if (derivedPublic != null && derivedPublic.isNotEmpty) {
        await _storage.write(
            key: 'generated_pub_$matchedId', value: derivedPublic);
        await _storage.write(
            key: 'public_key_$matchedId', value: derivedPublic);
      }
    }

    await _backupPrivateKeyToLocal(
      privateKey,
      keyTitle: matchedAsGenerated
          ? matchedTitle
          : '${_ConnectionSettingsScreenState._managedKeyPrefix}_manual',
      interactive: true,
    );
    final gistSynced = await _syncActiveKeyToManagedGist(
      overridePrivateKey: privateKey,
      overrideTitle: matchedAsGenerated
          ? matchedTitle
          : '${_ConnectionSettingsScreenState._managedKeyPrefix}_manual',
      overrideKeyId: matchedAsGenerated ? matchedId : null,
    );
    final availability = await _buildLocalPrivateKeyAvailability(_keys);
    _setStateSafe(() {
      _localPrivateKeyAvailability = availability;
      _isManualKeyEditing = false;
    });
    _maybeAutoStartDiscovery();

    if (mounted) {
      final appliedMessage = matchedAsGenerated
          ? "SSH Key 적용 완료: $matchedTitle"
          : "SSH Key 적용 완료: 수동 키";
      if (gistSynced) {
        CustomToast.show(context, appliedMessage);
      } else {
        CustomToast.show(
          context,
          "$appliedMessage\n(gist 동기화 실패)",
          isError: true,
        );
      }
    }
  }

  Future<void> _applyGeneratedKey(String keyId, String title) async {
    final privateKey = await _storage.read(key: 'generated_key_$keyId');

    if (privateKey == null) {
      // 기존 구조에서 찾기 (마이그레이션 안 된 경우)
      final oldKey = await _storage.read(key: 'private_key_$keyId');
      if (oldKey != null) {
        await _storage.write(key: 'generated_key_$keyId', value: oldKey);
        await _applyGeneratedKey(keyId, title);
        return;
      }
      if (mounted) {
        CustomToast.show(
            context, "이 키의 개인키가 저장되어 있지 않습니다.\n이 기기에서 생성한 키만 사용할 수 있습니다.",
            isError: true);
      }
      return;
    }

    _setStateSafe(() {
      _isManualKeyEditing = false;
    });

    await _setActivePrivateKey(
      privateKey: privateKey,
      keyType: 'generated',
      generatedId: keyId,
      generatedTitle: title,
    );
    await _backupPrivateKeyToLocal(
      privateKey,
      keyTitle: title,
      interactive: false,
    );
    final gistSynced = await _syncActiveKeyToManagedGist(
      overridePrivateKey: privateKey,
      overrideTitle: title,
      overrideKeyId: keyId,
    );
    _maybeAutoStartDiscovery();

    if (mounted) {
      if (gistSynced) {
        CustomToast.show(context, "SSH 키가 적용되었습니다: $title");
      } else {
        CustomToast.show(
          context,
          "SSH 키 적용은 완료됐지만 gist 동기화에 실패했습니다.",
          isError: true,
        );
      }
    }
  }

  Future<void> _clearKey() async {
    await _storage.delete(key: 'current_key_type');
    await _storage.delete(key: 'current_private_key');
    await _storage.delete(key: 'active_generated_id');

    _setStateSafe(() {
      _currentKeyType = null;
      _currentPrivateKey = null;
      _activeGeneratedId = null;
      _activeGeneratedTitle = null;
      _manualKeyController.clear();
      _isManualKeyEditing = false;
    });

    if (mounted) CustomToast.show(context, "SSH 키가 해제되었습니다.");
  }

  // ========== GitHub 관련 ==========

  Future<bool> _loadKeys() async {
    try {
      final keys = await _githubService.listPublicKeys();
      final availability = await _buildLocalPrivateKeyAvailability(keys);
      if (mounted) {
        _setStateSafe(() {
          _keys = keys;
          _localPrivateKeyAvailability = availability;
        });

        // 활성화된 키의 제목 업데이트
        if (_activeGeneratedId != null) {
          for (final key in keys) {
            if (key['id']?.toString() == _activeGeneratedId) {
              _setStateSafe(() =>
                  _activeGeneratedTitle = key['title'] ?? 'carrotpilot 키');
              break;
            }
          }
        }
      }
      return true;
    } catch (e) {
      debugPrint("Failed to load keys: $e");
      return false;
    }
  }

  Future<void> _deleteKey(int id) async {
    try {
      final window = UiWindowInfo.of(context);
      final tokens = UiLayoutTokens.of(context);
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("키 삭제"),
          content: Padding(
            padding: EdgeInsets.only(top: tokens.itemGap),
            child: Text(
              "정말로 이 키를 GitHub에서 삭제하시겠습니까?",
              style: TextStyle(fontSize: window.isCompact ? 13.0 : 13.5),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text("취소")),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text("삭제")),
          ],
        ),
      );

      if (confirm == true) {
        await _githubService.deletePublicKey(id);
        var gistSynced = true;
        try {
          await _githubService.removeManagedKeyringKeyByGitHubId(id);
        } catch (e) {
          gistSynced = false;
          _diag.warn('key', 'Failed to remove key from managed gist: $e');
        }

        // 삭제된 키가 현재 사용 중이면 해제
        if (_activeGeneratedId == id.toString()) {
          await _clearKey();
        }

        // 저장된 키 데이터도 삭제
        await _storage.delete(key: 'generated_key_$id');
        await _storage.delete(key: 'generated_pub_$id');
        await _storage.delete(key: 'private_key_$id');
        await _storage.delete(key: 'public_key_$id');

        if (mounted) {
          if (gistSynced) {
            CustomToast.show(context, "키가 삭제되었습니다.");
          } else {
            CustomToast.show(
              context,
              "GitHub 키는 삭제됐지만 gist 동기화는 실패했습니다.",
              isError: true,
            );
          }
        }
        await _loadKeys();
      }
    } catch (e) {
      if (mounted) CustomToast.show(context, "삭제 실패: $e", isError: true);
    }
  }

  Future<bool> _activateFirstUsableGeneratedKey() async {
    if (_keys.isEmpty) return false;
    for (final key in _keys) {
      final keyId = key['id']?.toString();
      if (keyId == null || keyId.isEmpty) continue;

      final keyTitle = key['title']?.toString() ?? 'carrotpilot 키';

      final privateKey = await _storage.read(key: 'generated_key_$keyId') ??
          await _storage.read(key: 'private_key_$keyId');
      if (privateKey == null || privateKey.isEmpty) continue;

      await _applyGeneratedKey(keyId, keyTitle);
      return true;
    }
    return false;
  }
}
