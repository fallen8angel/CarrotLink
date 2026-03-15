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
    return FilledButton.styleFrom(
      minimumSize: Size.fromHeight(metrics.buttonHeight),
      padding: EdgeInsets.symmetric(
        horizontal: metrics.gapLg,
        vertical: metrics.gapMd,
      ),
    );
  }

  InputDecoration _textFieldDecoration({
    required String labelText,
    String? hintText,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      suffixIcon: suffixIcon,
      border: const OutlineInputBorder(),
      isDense: true,
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

  Widget _buildScreen(
    BuildContext context, {
    required UiWindowInfo window,
    required UiLayoutTokens tokens,
  }) {
    final ssh = Provider.of<SSHService>(context);
    final githubFeaturesEnabled = _isGitHubLoggedIn;
    final maxContentWidth = switch (window.windowClass) {
      UiWindowClass.compact => 640.0,
      UiWindowClass.medium => 720.0,
      _ => 760.0,
    };

    return SettingsSubpageScaffold(
      title: '연결 설정',
      maxWidth: maxContentWidth,
      children: [
        SettingsSection(
          title: '기기',
          showTopDivider: false,
          child: SettingsItemGroup(
            children: [
              _buildExpandablePanel(
                id: 'device',
                title: '기기 연결',
                value: _connectionSummary(ssh),
                child: _buildConnectionSection(ssh),
              ),
            ],
          ),
        ),
        SettingsSection(
          title: '계정 및 키',
          child: SettingsItemGroup(
            children: [
              _buildExpandablePanel(
                id: 'github',
                title: 'GitHub 연동',
                value: _isGitHubLoggedIn ? '로그인됨' : '로그인 필요',
                child: _buildGitHubSection(),
              ),
              _buildExpandablePanel(
                id: 'manual_key',
                title: 'SSH Key',
                value: _manualKeySummary(),
                child: _buildManualKeySection(),
              ),
              _buildExpandablePanel(
                id: 'github_keys',
                title: 'GitHub SSH 키 관리',
                value: githubFeaturesEnabled
                    ? _githubKeySummary()
                    : 'GitHub 로그인 필요',
                child: _buildFeatureGate(
                  enabled: githubFeaturesEnabled,
                  child: _buildGitHubKeyManagerSection(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _connectionSummary(SSHService ssh) {
    if (ssh.isConnected) {
      final ip = (ssh.connectedIp ?? ssh.targetIp ?? '').trim();
      return ip.isEmpty ? '연결됨' : '연결됨 · $ip';
    }
    if (ssh.isConnecting) {
      return '연결 중';
    }
    final typedIp = _ipController.text.trim();
    if (typedIp.isNotEmpty) {
      return typedIp;
    }
    if (_manualDiscoverySession || ssh.isDiscoveryActive) {
      return '자동 검색 중';
    }
    return '자동 검색 / 수동 입력';
  }

  String _manualKeySummary() {
    return switch (_currentKeyType) {
      'generated' => _activeGeneratedTitle ?? 'GitHub 키 적용됨',
      'manual' => '수동 키 적용됨',
      _ => '적용된 키 없음',
    };
  }

  String _githubKeySummary() {
    if (_keys.isEmpty) {
      return '등록된 키 없음';
    }
    final active = _currentKeyType == 'generated' &&
        _activeGeneratedTitle != null &&
        _activeGeneratedTitle!.trim().isNotEmpty;
    if (active) {
      return '${_keys.length}개 · ${_activeGeneratedTitle!}';
    }
    return '${_keys.length}개';
  }

  Widget _buildExpandablePanel({
    required String id,
    required String title,
    required String value,
    required Widget child,
  }) {
    final expanded = _expandedPanelId == id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Icon(
            expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          ),
          onTap: () {
            _setStateSafe(() {
              _expandedPanelId = expanded ? null : id;
            });
          },
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: child,
          ),
          crossFadeState:
              expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 160),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
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

    return Column(
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
          decoration: _textFieldDecoration(
            labelText: 'IP 주소',
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
            Icon(Icons.circle, size: metrics.statusDotSize, color: statusColor),
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
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        SizedBox(height: metrics.gapXs),
        SettingsStatusNote(
          text: "검색 상태: ${_compactDiscoveryStatus(ssh)} · $_discoveryStatus",
        ),
        SizedBox(height: metrics.gapLg),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                style: _primaryButtonStyle(context),
                onPressed: (isConnected || isConnecting) ? null : _connect,
                child: const Text('연결'),
              ),
            ),
            SizedBox(width: metrics.gapLg),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: Size.fromHeight(metrics.buttonHeight),
                  padding: EdgeInsets.symmetric(
                    horizontal: metrics.gapLg,
                    vertical: metrics.gapMd,
                  ),
                ),
                onPressed: (isConnected || isConnecting) ? _disconnect : null,
                child: const Text('연결 해제'),
              ),
            ),
          ],
        ),
      ],
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          activeLabel,
          style: TextStyle(
            fontSize: metrics.textBody,
            fontWeight: FontWeight.w600,
          ),
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
          decoration: _textFieldDecoration(
            labelText: 'SSH Private Key (PEM)',
            hintText:
                '-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----',
          ),
          style: TextStyle(fontFamily: 'monospace', fontSize: metrics.monoText),
        ),
        SizedBox(height: metrics.gapMd),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                style: _primaryButtonStyle(context),
                onPressed: () => unawaited(_handleManualKeyPrimaryButton()),
                child: Text(_isManualKeyEditing ? "키 저장/적용" : "키 적용/수정"),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGitHubSection() {
    final metrics = _adaptiveMetrics(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_isGitHubLoggedIn)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _loginToGitHub,
              icon: const Icon(Icons.login),
              label: const Text("GitHub 로그인"),
              style: FilledButton.styleFrom(
                minimumSize: Size.fromHeight(metrics.buttonHeight),
              ),
            ),
          )
        else
          SettingsItemGroup(
            children: [
              SettingsActionRow(
                title: 'GitHub 로그인',
                value: '완료',
                trailing: TextButton(
                  onPressed: () async {
                    await _githubService.clearToken();
                    await _checkGitHubLogin();
                  },
                  child: Text(
                    '로그아웃',
                    style: TextStyle(fontSize: metrics.textBody),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildGitHubKeyManagerSection() {
    final metrics = _adaptiveMetrics(context);
    final activeGenerated =
        _currentKeyType == 'generated' && _activeGeneratedId != null;
    final activeText = activeGenerated
        ? "활성 키: ${_activeGeneratedTitle ?? _activeGeneratedId}"
        : (_currentKeyType == 'manual' ? "활성 키: 수동 입력 키" : "활성 키: 없음");

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                activeText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
                  CustomToast.show(context, "키 목록을 불러오지 못했습니다.", isError: true);
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
        SizedBox(height: metrics.gapMd),
        if (_keys.isEmpty)
          Text(
            "GitHub에 등록된 SSH 키가 없습니다.",
            style: TextStyle(fontSize: metrics.textBody),
          )
        else
          SettingsItemGroup(
            children: [
              for (final key in _keys)
                Builder(
                  builder: (context) {
                    final keyId = key['id']?.toString() ?? '';
                    final keyTitle = key['title']?.toString() ?? 'untitled';
                    final parsedId = int.tryParse(keyId);
                    final hasLocalPrivate =
                        _localPrivateKeyAvailability[keyId] == true;
                    final isActive = _currentKeyType == 'generated' &&
                        _activeGeneratedId == keyId;

                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
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
                            icon: Icons.task_alt_rounded,
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
            ],
          ),
      ],
    );
  }
}
