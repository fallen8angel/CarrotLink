part of 'connection_settings_screen.dart';

extension _ConnectionSettingsWidgets on _ConnectionSettingsScreenState {
  static const double _sectionSpacing = 16;
  static const double _buttonHeight = 44;
  static const BoxConstraints _iconActionConstraints =
      BoxConstraints.tightFor(width: 36, height: 36);

  ButtonStyle _primaryButtonStyle() {
    return ElevatedButton.styleFrom(
      minimumSize: const Size.fromHeight(_buttonHeight),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
  }

  Widget _compactIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: color),
      constraints: _iconActionConstraints,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }

  Widget _buildScreen(BuildContext context) {
    final ssh = Provider.of<SSHService>(context);
    final githubFeaturesEnabled = _isGitHubLoggedIn;
    final bottomPadding = MediaQuery.of(context).padding.bottom + 28;

    return Scaffold(
      appBar: AppBar(title: const Text('연결 설정')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPadding),
        children: [
          Text("1. 기기 연결", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _buildConnectionSection(ssh),
          if (!githubFeaturesEnabled) ...[
            const SizedBox(height: 12),
            _buildLoginRequiredNotice(),
          ],
          const SizedBox(height: _sectionSpacing),
          Text("2. GitHub 연동", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _buildGitHubSection(),
          const SizedBox(height: _sectionSpacing),
          Text("3. SSH Key", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _buildManualKeySection(),
          const SizedBox(height: _sectionSpacing),
          Text("4. GitHub SSH 키 관리",
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _buildFeatureGate(
            enabled: githubFeaturesEnabled,
            child: _buildGitHubKeyManagerSection(),
          ),
          const SizedBox(height: _sectionSpacing),
        ],
      ),
    );
  }

  Widget _buildFeatureGate({required bool enabled, required Widget child}) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: AbsorbPointer(
        absorbing: !enabled,
        child: child,
      ),
    );
  }

  Widget _buildLoginRequiredNotice() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              color: Theme.of(context).colorScheme.primary, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              "GitHub 로그인 시 키 자동관리/자동연결 기능이 활성화됩니다.",
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionSection(SSHService ssh) {
    final isConnecting = ssh.isConnecting;
    final isConnected = ssh.isConnected;
    final statusColor = isConnected
        ? Colors.green
        : (isConnecting ? Colors.orange : Colors.grey);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ipController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (value) {
              final trimmed = value.trim();
              if (trimmed.isEmpty) {
                if (_lockDiscoveryIpOverwrite || _autoFilledIp != null) {
                  _setStateSafe(() {
                    _lockDiscoveryIpOverwrite = false;
                    _autoFilledIp = null;
                  });
                }
                return;
              }
              if (_autoFilledIp != null && trimmed == _autoFilledIp) {
                return;
              }
              if (!_lockDiscoveryIpOverwrite || _autoFilledIp != null) {
                _setStateSafe(() {
                  _lockDiscoveryIpOverwrite = true;
                  _autoFilledIp = null;
                });
              }
            },
            decoration: InputDecoration(
              labelText: 'IP 주소',
              prefixIcon: const Icon(Icons.wifi),
              hintText: '예: 192.168.0.10',
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                tooltip: '자동 검색',
                onPressed:
                    isConnecting ? null : () async => _runGuidedDiscovery(),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.circle, size: 10, color: statusColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  ssh.connectionStatus,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[700],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isConnecting)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _manualDiscoverySession
                ? "검색 상태: 수동 / $_discoveryStatus"
                : "검색 상태: $_discoveryStatus",
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[700],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: _primaryButtonStyle(),
                  onPressed: (isConnected || isConnecting) ? null : _connect,
                  child: const Text('연결'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: _primaryButtonStyle(),
                  onPressed: (isConnected || isConnecting) ? _disconnect : null,
                  child: const Text('연결 해제'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleManualKeyPrimaryButton() async {
    if (_isManualKeyEditing) {
      await _applyManualKey();
      return;
    }
    _setStateSafe(() {
      _isManualKeyEditing = true;
    });
  }

  Widget _buildManualKeySection() {
    final activeLabel = _currentKeyType == 'generated'
        ? "현재 적용: ${_activeGeneratedTitle ?? _activeGeneratedId ?? 'GitHub 키'}"
        : (_currentKeyType == 'manual' ? "현재 적용: 수동 키" : "현재 적용: 없음");

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            activeLabel,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            "개인키(PEM)를 입력하거나 수정한 뒤 저장/적용하세요.",
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _manualKeyController,
            readOnly: !_isManualKeyEditing,
            minLines: 4,
            maxLines: 7,
            onChanged: (_) {
              if (_isManualKeyEditing) {
                _setStateSafe(() {});
              }
            },
            decoration: const InputDecoration(
              labelText: 'SSH Private Key (PEM)',
              hintText:
                  '-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----',
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: _primaryButtonStyle(),
                  onPressed: () => unawaited(_handleManualKeyPrimaryButton()),
                  child: Text(_isManualKeyEditing ? "키 저장/적용" : "키 적용/수정"),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "입력 키가 GitHub 공개키와 일치하면 해당 GitHub 키로 자동 매칭됩니다.",
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _isManualKeyEditing
                  ? "수정 후 같은 버튼을 다시 누르면 저장/적용됩니다."
                  : "버튼을 누르면 편집 모드로 전환됩니다.",
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGitHubSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "로그인하면 GitHub 키 동기화/관리 기능이 활성화됩니다.",
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          if (!_isGitHubLoggedIn)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loginToGitHub,
                icon: const Icon(Icons.login),
                label: const Text("GitHub 로그인"),
                style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(_buttonHeight),
                    backgroundColor: Colors.black87,
                    foregroundColor: Colors.white),
              ),
            )
          else ...[
            Row(
              children: [
                Icon(Icons.check_circle,
                    color: Theme.of(context).colorScheme.primary, size: 16),
                const SizedBox(width: 8),
                const Text("GitHub 로그인됨", style: TextStyle(fontSize: 12)),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await _githubService.clearToken();
                    await _checkGitHubLogin();
                  },
                  child: const Text("로그아웃", style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGitHubKeyManagerSection() {
    final activeGenerated =
        _currentKeyType == 'generated' && _activeGeneratedId != null;
    final activeText = activeGenerated
        ? "활성 키: ${_activeGeneratedTitle ?? _activeGeneratedId}"
        : (_currentKeyType == 'manual' ? "활성 키: 수동 입력 키" : "활성 키: 없음");

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  activeText,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              _compactIconButton(
                tooltip: "목록 새로고침",
                icon: Icons.refresh,
                onPressed: () async {
                  final loaded = await _loadKeys();
                  if (!loaded && mounted) {
                    CustomToast.show(context, "키 목록을 불러오지 못했습니다.",
                        isError: true);
                  }
                },
              ),
              _compactIconButton(
                tooltip: "새 키 생성",
                icon: Icons.add,
                onPressed: _generateAndRegisterKey,
              ),
              _compactIconButton(
                tooltip: "활성 키 해제",
                icon: Icons.link_off,
                onPressed: _hasActiveSshKey ? _clearKey : null,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "GitHub 키 ${_keys.length}개",
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const SizedBox(height: 8),
          if (_keys.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                "GitHub에 등록된 SSH 키가 없습니다.",
                style: TextStyle(fontSize: 12),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.withOpacity(0.2)),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _keys.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: Colors.grey.withOpacity(0.2),
                ),
                itemBuilder: (context, index) {
                  final key = _keys[index];
                  final keyId = key['id']?.toString() ?? '';
                  final keyTitle = key['title']?.toString() ?? 'untitled';
                  final parsedId = int.tryParse(keyId);
                  final hasLocalPrivate =
                      _localPrivateKeyAvailability[keyId] == true;
                  final isActive = _currentKeyType == 'generated' &&
                      _activeGeneratedId == keyId;

                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isActive ? Icons.check_circle : Icons.key_outlined,
                      size: 18,
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey[500],
                    ),
                    title: Text(
                      keyTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      "ID:$keyId · ${hasLocalPrivate ? "로컬 개인키 있음" : "개인키 없음"}",
                      style: TextStyle(
                        fontSize: 11,
                        color: hasLocalPrivate
                            ? Colors.grey[500]
                            : Colors.orange[300],
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _compactIconButton(
                          tooltip: hasLocalPrivate ? "이 키 적용" : "개인키 필요",
                          icon: Icons.play_arrow,
                          onPressed: (keyId.isEmpty || !hasLocalPrivate)
                              ? null
                              : () => _applyGeneratedKey(keyId, keyTitle),
                        ),
                        _compactIconButton(
                          tooltip: "키 삭제",
                          icon: Icons.delete_outline,
                          color: Theme.of(context).colorScheme.error,
                          onPressed: parsedId == null
                              ? null
                              : () => _deleteKey(parsedId),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 6),
          Text(
            "개인키가 없는 항목은 적용할 수 없습니다. SSH Key 섹션에 개인키를 넣으면 자동 매칭됩니다.",
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }
}
