part of 'connection_settings_screen.dart';

extension _ConnectionSettingsWidgets on _ConnectionSettingsScreenState {
  ({
    double sectionSpacing,
    double sectionHeaderGap,
    double cardPadding,
    double buttonHeight,
    EdgeInsets pagePadding,
    BoxConstraints iconActionConstraints,
    double iconActionIconSize,
    double textCaption,
    double textBody,
    double textTitle,
    double monoText,
    double gapXs,
    double gapSm,
    double gapMd,
    double gapLg,
    double statusDotSize,
    double spinnerSize,
  }) _adaptiveMetrics(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final sectionSpacing = switch (window.windowClass) {
      UiWindowClass.compact => 16.0,
      UiWindowClass.medium => 18.0,
      _ => 20.0,
    };
    final sectionHeaderGap = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 14.0,
      _ => 16.0,
    };
    final cardPadding = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 14.0,
      _ => 16.0,
    };
    final buttonHeight = switch (window.windowClass) {
      UiWindowClass.compact => 44.0,
      UiWindowClass.medium => 46.0,
      _ => 48.0,
    };
    final iconSide = switch (window.windowClass) {
      UiWindowClass.compact => 36.0,
      UiWindowClass.medium => 38.0,
      _ => 40.0,
    };
    final iconActionIconSize = switch (window.windowClass) {
      UiWindowClass.compact => 18.0,
      UiWindowClass.medium => 19.0,
      _ => 20.0,
    };
    final textCaption = switch (window.windowClass) {
      UiWindowClass.compact => 11.0,
      UiWindowClass.medium => 11.5,
      _ => 12.0,
    };
    final textBody = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.5,
      _ => 13.0,
    };
    final textTitle = switch (window.windowClass) {
      UiWindowClass.compact => 13.0,
      UiWindowClass.medium => 13.5,
      _ => 14.0,
    };
    final monoText = switch (window.windowClass) {
      UiWindowClass.compact => 11.0,
      UiWindowClass.medium => 11.5,
      _ => 12.0,
    };
    final gapXs = switch (window.windowClass) {
      UiWindowClass.compact => 4.0,
      UiWindowClass.medium => 5.0,
      _ => 6.0,
    };
    final gapSm = switch (window.windowClass) {
      UiWindowClass.compact => 6.0,
      UiWindowClass.medium => 7.0,
      _ => 8.0,
    };
    final gapMd = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 10.0,
      _ => 12.0,
    };
    final gapLg = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 14.0,
      _ => 16.0,
    };
    final statusDotSize = switch (window.windowClass) {
      UiWindowClass.compact => 10.0,
      UiWindowClass.medium => 11.0,
      _ => 12.0,
    };
    final spinnerSize = switch (window.windowClass) {
      UiWindowClass.compact => 14.0,
      UiWindowClass.medium => 15.0,
      _ => 16.0,
    };
    return (
      sectionSpacing: sectionSpacing,
      sectionHeaderGap: sectionHeaderGap,
      cardPadding: cardPadding,
      buttonHeight: buttonHeight,
      pagePadding: EdgeInsets.fromLTRB(
        tokens.screenPadding,
        tokens.screenPadding,
        tokens.screenPadding,
        MediaQuery.of(context).padding.bottom + 28,
      ),
      iconActionConstraints:
          BoxConstraints.tightFor(width: iconSide, height: iconSide),
      iconActionIconSize: iconActionIconSize,
      textCaption: textCaption,
      textBody: textBody,
      textTitle: textTitle,
      monoText: monoText,
      gapXs: gapXs,
      gapSm: gapSm,
      gapMd: gapMd,
      gapLg: gapLg,
      statusDotSize: statusDotSize,
      spinnerSize: spinnerSize,
    );
  }

  ButtonStyle _primaryButtonStyle(BuildContext context) {
    final metrics = _adaptiveMetrics(context);
    return ElevatedButton.styleFrom(
      minimumSize: Size.fromHeight(metrics.buttonHeight),
      padding: EdgeInsets.symmetric(
        horizontal: metrics.gapLg,
        vertical: metrics.gapMd,
      ),
    );
  }

  Widget _compactIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    final metrics = _adaptiveMetrics(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: metrics.iconActionIconSize, color: color),
      constraints: metrics.iconActionConstraints,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }

  Widget _buildScreen(BuildContext context) {
    final metrics = _adaptiveMetrics(context);
    final ssh = Provider.of<SSHService>(context);
    final githubFeaturesEnabled = _isGitHubLoggedIn;

    return Scaffold(
      appBar: AppBar(title: const Text('연결 설정')),
      body: ListView(
        padding: metrics.pagePadding,
        children: [
          Text("1. 기기 연결", style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: metrics.sectionHeaderGap),
          _buildConnectionSection(ssh),
          if (!githubFeaturesEnabled) ...[
            SizedBox(height: metrics.sectionHeaderGap),
            _buildLoginRequiredNotice(),
          ],
          SizedBox(height: metrics.sectionSpacing),
          Text("2. GitHub 연동", style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: metrics.sectionHeaderGap),
          _buildGitHubSection(),
          SizedBox(height: metrics.sectionSpacing),
          Text("3. SSH Key", style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: metrics.sectionHeaderGap),
          _buildManualKeySection(),
          SizedBox(height: metrics.sectionSpacing),
          Text("4. GitHub SSH 키 관리",
              style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: metrics.sectionHeaderGap),
          _buildFeatureGate(
            enabled: githubFeaturesEnabled,
            child: _buildGitHubKeyManagerSection(),
          ),
          SizedBox(height: metrics.sectionSpacing),
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
    final metrics = _adaptiveMetrics(context);
    return Container(
      padding: EdgeInsets.all(metrics.cardPadding),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              color: Theme.of(context).colorScheme.primary,
              size: metrics.iconActionIconSize),
          SizedBox(width: metrics.gapMd),
          Expanded(
            child: Text(
              "GitHub 로그인 시 키 자동관리/자동연결 기능이 활성화됩니다.",
              style: TextStyle(fontSize: metrics.textBody),
            ),
          ),
        ],
      ),
    );
  }

  String _compactDiscoveryStatus(SSHService ssh) {
    final seenAt = ssh.serviceCandidateSeenAt;
    final hasFreshCandidate = ssh.serviceCandidateIp != null &&
        seenAt != null &&
        DateTime.now().difference(seenAt) <= const Duration(seconds: 45);
    final searching =
        _manualDiscoverySession || ssh.isDiscoveryActive || hasFreshCandidate;
    return searching ? "검색중" : "후보없음";
  }

  Widget _buildConnectionSection(SSHService ssh) {
    final metrics = _adaptiveMetrics(context);
    final isConnecting = ssh.isConnecting;
    final isConnected = ssh.isConnected;
    final statusColor = isConnected
        ? Colors.green
        : (isConnecting ? Colors.orange : Colors.grey);

    return Container(
      padding: EdgeInsets.all(metrics.cardPadding),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
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
          SizedBox(height: metrics.gapMd),
          Row(
            children: [
              Icon(Icons.circle,
                  size: metrics.statusDotSize, color: statusColor),
              SizedBox(width: metrics.gapSm),
              Expanded(
                child: Text(
                  ssh.connectionStatus,
                  style: TextStyle(
                    fontSize: metrics.textCaption,
                    color: Colors.grey[700],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isConnecting)
                SizedBox(
                  width: metrics.spinnerSize,
                  height: metrics.spinnerSize,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          SizedBox(height: metrics.gapXs),
          Text(
            "검색 상태: ${_compactDiscoveryStatus(ssh)}",
            style: TextStyle(
              fontSize: metrics.textCaption,
              color: Colors.grey[700],
            ),
          ),
          SizedBox(height: metrics.gapLg),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: _primaryButtonStyle(context),
                  onPressed: (isConnected || isConnecting) ? null : _connect,
                  child: const Text('연결'),
                ),
              ),
              SizedBox(width: metrics.gapLg),
              Expanded(
                child: ElevatedButton(
                  style: _primaryButtonStyle(context),
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
    final metrics = _adaptiveMetrics(context);
    final activeLabel = _currentKeyType == 'generated'
        ? "현재 적용: ${_activeGeneratedTitle ?? _activeGeneratedId ?? 'GitHub 키'}"
        : (_currentKeyType == 'manual' ? "현재 적용: 수동 키" : "현재 적용: 없음");

    return Container(
      padding: EdgeInsets.all(metrics.cardPadding),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            activeLabel,
            style: TextStyle(
              fontSize: metrics.textBody,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: metrics.gapSm),
          Text(
            "개인키(PEM)를 입력하거나 수정한 뒤 저장/적용하세요.",
            style: TextStyle(fontSize: metrics.textCaption, color: Colors.grey),
          ),
          SizedBox(height: metrics.gapLg),
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
            style:
                TextStyle(fontFamily: 'monospace', fontSize: metrics.monoText),
          ),
          SizedBox(height: metrics.gapMd),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: _primaryButtonStyle(context),
                  onPressed: () => unawaited(_handleManualKeyPrimaryButton()),
                  child: Text(_isManualKeyEditing ? "키 저장/적용" : "키 적용/수정"),
                ),
              ),
            ],
          ),
          SizedBox(height: metrics.gapSm),
          Text(
            "입력 키가 GitHub 공개키와 일치하면 해당 GitHub 키로 자동 매칭됩니다.",
            style: TextStyle(
                fontSize: metrics.textCaption, color: Colors.grey[600]),
          ),
          Padding(
            padding: EdgeInsets.only(top: metrics.gapXs),
            child: Text(
              _isManualKeyEditing
                  ? "수정 후 같은 버튼을 다시 누르면 저장/적용됩니다."
                  : "버튼을 누르면 편집 모드로 전환됩니다.",
              style: TextStyle(
                  fontSize: metrics.textCaption, color: Colors.grey[500]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGitHubSection() {
    final metrics = _adaptiveMetrics(context);
    return Container(
      padding: EdgeInsets.all(metrics.cardPadding),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "로그인하면 GitHub 키 동기화/관리 기능이 활성화됩니다.",
            style: TextStyle(fontSize: metrics.textCaption, color: Colors.grey),
          ),
          SizedBox(height: metrics.gapLg),
          if (!_isGitHubLoggedIn)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loginToGitHub,
                icon: const Icon(Icons.login),
                label: const Text("GitHub 로그인"),
                style: ElevatedButton.styleFrom(
                    minimumSize: Size.fromHeight(metrics.buttonHeight),
                    backgroundColor: Colors.black87,
                    foregroundColor: Colors.white),
              ),
            )
          else ...[
            Row(
              children: [
                Icon(Icons.check_circle,
                    color: Theme.of(context).colorScheme.primary,
                    size: metrics.iconActionIconSize - 2),
                SizedBox(width: metrics.gapMd),
                Text("GitHub 로그인됨",
                    style: TextStyle(fontSize: metrics.textBody)),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await _githubService.clearToken();
                    await _checkGitHubLogin();
                  },
                  child: Text("로그아웃",
                      style: TextStyle(fontSize: metrics.textBody)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGitHubKeyManagerSection() {
    final metrics = _adaptiveMetrics(context);
    final activeGenerated =
        _currentKeyType == 'generated' && _activeGeneratedId != null;
    final activeText = activeGenerated
        ? "활성 키: ${_activeGeneratedTitle ?? _activeGeneratedId}"
        : (_currentKeyType == 'manual' ? "활성 키: 수동 입력 키" : "활성 키: 없음");

    return Container(
      padding: EdgeInsets.all(metrics.cardPadding),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  activeText,
                  style: TextStyle(
                    fontSize: metrics.textBody,
                    fontWeight: FontWeight.w600,
                  ),
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
          SizedBox(height: metrics.gapXs),
          Text(
            "GitHub 키 ${_keys.length}개",
            style: TextStyle(
                fontSize: metrics.textCaption, color: Colors.grey[500]),
          ),
          SizedBox(height: metrics.gapMd),
          if (_keys.isEmpty)
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(metrics.cardPadding - 2),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "GitHub에 등록된 SSH 키가 없습니다.",
                style: TextStyle(fontSize: metrics.textBody),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _keys.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: Colors.grey.withValues(alpha: 0.2),
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
                      style: TextStyle(fontSize: metrics.textTitle),
                    ),
                    subtitle: Text(
                      "ID:$keyId · ${hasLocalPrivate ? "로컬 개인키 있음" : "개인키 없음"}",
                      style: TextStyle(
                        fontSize: metrics.textCaption,
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
          SizedBox(height: metrics.gapSm),
          Text(
            "개인키가 없는 항목은 적용할 수 없습니다. SSH Key 섹션에 개인키를 넣으면 자동 매칭됩니다.",
            style: TextStyle(
                fontSize: metrics.textCaption, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }
}
