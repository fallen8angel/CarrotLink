part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasDebugPopupComponents on _LiveDriveCanvasScreenState {
  Future<void> _openDebugOptionsPopupImpl() async {
    if (!_LiveDriveCanvasScreenState._hudDebugMenuEnabled) {
      _toast('디버그 메뉴가 비활성화되어 있습니다.');
      return;
    }
    if (!mounted) return;
    final bootstrapDone = await _isSidecarBootstrapDone();
    if (!mounted) return;
    unawaited(_refreshSidecarProcessStatus());
    var refreshing = false;
    var actionRunning = false;
    var selectedGroup = 0;

    await showDialog<void>(
      context: context,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final debugEnabled =
                !_LiveDriveCanvasScreenState._temporaryLimitedHudControls &&
                    _overlayVerifyMode;
            final process = _sidecarProcessSnapshot;
            final health = _sidecarHealthSnapshot;
            final method = (process['method'] ?? '-').trim().isEmpty
                ? '-'
                : (process['method'] ?? '-');
            final pid = (process['pid'] ?? '').trim().isEmpty
                ? '-'
                : (process['pid'] ?? '-');
            final healthOk =
                health.isEmpty ? '-' : ((health['ok'] == true) ? 'ok' : 'fail');
            final healthProfile = (health['profile']?.toString() ?? '-');
            final healthClients = (health['clients']?.toString() ?? '-');
            final wsState = _sidecarConnected ? 'connected' : 'disconnected';
            final lastFrameAgo = _sidecarLastFrameAt == null
                ? '-'
                : '${DateTime.now().difference(_sidecarLastFrameAt!).inMilliseconds}ms 전';
            final remoteHash = (process['remote_hash'] ??
                    process['hash'] ??
                    process['version'] ??
                    process['commit'] ??
                    '-')
                .toString();
            final uptime = (process['uptime'] ??
                    process['uptime_sec'] ??
                    process['uptime_s'] ??
                    '-')
                .toString();
            final bootstrapConfigured =
                ((_sidecarBootstrapDone ?? bootstrapDone) ? '완료' : '미완료');
            final bootstrapLastResult = _sidecarLastBootstrapResult;
            final bootstrapLastAt = _fmtClock(_sidecarLastBootstrapAt);
            final bootstrapLastDetail =
                _sidecarLastBootstrapDetail.trim().isEmpty
                    ? '-'
                    : _sidecarLastBootstrapDetail.trim();

            var relayState = '-';
            final relayRaw = health['cameraRelay'];
            if (relayRaw is Map) {
              final relay = Map<String, dynamic>.from(relayRaw);
              final relayMode = relay['mode']?.toString() ?? '-';
              final relayRunning = relay['running']?.toString() ?? '-';
              final relayQuality = relay['qualityMode']?.toString() ?? '-';
              relayState =
                  'mode:$relayMode quality:$relayQuality running:$relayRunning';
            }
            final procStatusLabel = _sidecarProcessStatusLabel;
            final cameraReadyLabel = _sidecarCameraReadyLabel;
            final cameraRelaySummary = _sidecarCameraRelaySummary;
            final liveRelaySummary = _sidecarLiveRelaySummary;
            final scheduledStopSummary = _sidecarScheduledStopSummary;
            final remotePyName = _sidecarRemotePyName;
            final remoteUpdated = _sidecarRemoteUpdatedLabel;
            final profileEndpoint =
                (_sidecarProfileSnapshot['profile']?.toString() ?? '-').trim();
            final profileModesRaw = _sidecarProfileSnapshot['profiles'];
            final profileModeCount =
                profileModesRaw is List ? profileModesRaw.length : 0;
            final profileEndpointSummary = profileEndpoint.isEmpty
                ? '-'
                : '$profileEndpoint (${profileModeCount > 0 ? 'modes $profileModeCount' : 'modes -'})';
            final qualityEndpoint =
                (_sidecarCameraQualitySnapshot['mode']?.toString() ?? '-')
                    .trim();
            final qualityModesRaw = _sidecarCameraQualitySnapshot['modes'];
            final qualityModeCount =
                qualityModesRaw is List ? qualityModesRaw.length : 0;
            final qualityEndpointSummary = qualityEndpoint.isEmpty
                ? '-'
                : '$qualityEndpoint (${qualityModeCount > 0 ? 'modes $qualityModeCount' : 'modes -'})';
            final healthEndpointSummary = health.isEmpty
                ? '-'
                : 'ok:$healthOk profile:$healthProfile clients:$healthClients';

            String criticalValue(String name) {
              final value = (_sidecarCriticalProcSnapshot[name] ?? '-').trim();
              if (value.isEmpty) return '-';
              return value;
            }

            Color criticalColor(String name) {
              final value = criticalValue(name);
              return value.startsWith('up:')
                  ? const Color(0xFF73E07C)
                  : const Color(0xFFFF8A8A);
            }

            final history = _sidecarHistory.take(10).toList(growable: false);
            Future<void> runAction(Future<void> Function() action) async {
              if (actionRunning) return;
              setLocalState(() => actionRunning = true);
              try {
                await action();
                await _refreshSidecarProcessStatus();
              } finally {
                if (sheetContext.mounted) {
                  setLocalState(() => actionRunning = false);
                }
              }
            }

            final screenSize = MediaQuery.of(sheetContext).size;
            final window = UiWindowInfo.of(sheetContext);
            final tokens = UiLayoutTokens.of(sheetContext);
            final hingePadding =
                DisplayFeatureUtils.hingeAwarePadding(sheetContext);
            final isWideDialog =
                window.isExpandedOrAbove || screenSize.width >= 980;
            final baseInset = window.isCompact ? 8.0 : 12.0;
            final insetPadding = EdgeInsets.only(
              left: hingePadding.left + baseInset,
              top: hingePadding.top + (window.isCompact ? 8 : 10),
              right: hingePadding.right + baseInset,
              bottom: hingePadding.bottom + (window.isCompact ? 8 : 10),
            );
            final availableWidth =
                screenSize.width - insetPadding.left - insetPadding.right;
            final availableHeight =
                screenSize.height - insetPadding.top - insetPadding.bottom;
            final maxHeight = availableHeight * (isWideDialog ? 0.95 : 0.93);
            final maxWidth = math.min(
              availableWidth,
              isWideDialog ? 1280.0 : 1080.0,
            );
            final sidebarWidth = switch (window.windowClass) {
              UiWindowClass.compact => 0.0,
              UiWindowClass.medium => 176.0,
              UiWindowClass.expanded => 198.0,
              UiWindowClass.large => 220.0,
              UiWindowClass.extraLarge => 240.0,
            };
            final contentHorizontalPadding = window.isCompact
                ? 12.0
                : tokens.screenPadding.clamp(12.0, 18.0);
            final headerPadding = EdgeInsets.fromLTRB(
              window.isCompact ? 14 : 18,
              window.isCompact ? 10 : 12,
              10,
              window.isCompact ? 8 : 10,
            );
            final headerFontSize =
                window.isCompact ? 18.0 : (isWideDialog ? 20.0 : 19.0);
            final chipFontSize = window.isCompact ? 11.0 : 12.0;
            final chipIconSize = window.isCompact ? 15.0 : 16.0;
            final headerGap = window.isCompact ? 6.0 : 8.0;
            final chipSpacing = window.isCompact ? 6.0 : 8.0;
            final statusLabelWidth =
                window.isCompact ? 96.0 : (isWideDialog ? 128.0 : 110.0);
            final statusLabelFont = window.isCompact ? 11.0 : 12.0;
            final statusValueFont = window.isCompact ? 12.0 : 13.0;
            final statusCardPadding = window.isCompact ? 10.0 : 12.0;
            final statusCardRadius = window.isCompact ? 10.0 : 12.0;
            final statusGridSpacing = window.isCompact ? 8.0 : 10.0;

            Widget groupNavChip({
              required int index,
              required IconData icon,
              required String label,
            }) {
              return _buildDebugGroupNavChip(
                index: index,
                selectedGroup: selectedGroup,
                icon: icon,
                label: label,
                chipFontSize: chipFontSize,
                chipIconSize: chipIconSize,
                onSelected: (_) => setLocalState(() => selectedGroup = index),
              );
            }

            Widget groupNavItem({
              required int index,
              required IconData icon,
              required String label,
            }) {
              return _buildDebugGroupNavItem(
                index: index,
                selectedGroup: selectedGroup,
                icon: icon,
                label: label,
                onTap: () => setLocalState(() => selectedGroup = index),
              );
            }

            Widget sectionCard(
              String title,
              Widget child, {
              Widget? trailing,
            }) {
              return _buildDebugSectionCard(
                window: window,
                title: title,
                child: child,
                trailing: trailing,
              );
            }

            Widget statusGrid(
              List<({String label, String value, Color? color})> items, {
              int? columns,
            }) {
              return _buildDebugStatusGrid(
                statusGridSpacing: statusGridSpacing,
                statusCardPadding: statusCardPadding,
                statusCardRadius: statusCardRadius,
                statusLabelFont: statusLabelFont,
                statusValueFont: statusValueFont,
                items: items,
                columns: columns,
              );
            }

            Widget layerSwitch(
              String title,
              bool value,
              ValueChanged<bool>? onChanged,
            ) {
              return _buildDebugLayerSwitch(
                title: title,
                value: value,
                onChanged: onChanged,
              );
            }

            return Dialog(
              backgroundColor: _debugDialogBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: const BorderSide(color: Colors.white12),
              ),
              insetPadding: insetPadding,
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxHeight: maxHeight, maxWidth: maxWidth),
                child: Column(
                  children: [
                    Padding(
                      padding: headerPadding,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'HUD 디버그',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: headerFontSize,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (refreshing || actionRunning)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          IconButton(
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            icon: const Icon(Icons.close_rounded,
                                color: Colors.white70),
                            tooltip: '닫기',
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white12),
                    if (!isWideDialog) ...[
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.fromLTRB(
                          contentHorizontalPadding,
                          8,
                          contentHorizontalPadding,
                          8,
                        ),
                        color: _debugPanelBg,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              groupNavChip(
                                index: 0,
                                icon: Icons.dashboard_outlined,
                                label: '개요',
                              ),
                              SizedBox(width: headerGap),
                              groupNavChip(
                                index: 1,
                                icon: Icons.layers_outlined,
                                label: '레이어',
                              ),
                              SizedBox(width: headerGap),
                              groupNavChip(
                                index: 2,
                                icon: Icons.build_circle_outlined,
                                label: '점검',
                              ),
                              SizedBox(width: headerGap),
                              groupNavChip(
                                index: 3,
                                icon: Icons.history,
                                label: '이력',
                              ),
                              SizedBox(width: headerGap),
                              groupNavChip(
                                index: 4,
                                icon: Icons.slideshow_outlined,
                                label: '프리뷰',
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Divider(height: 1, color: Colors.white12),
                    ],
                    Expanded(
                      child: Row(
                        children: [
                          if (isWideDialog) ...[
                            Container(
                              width: sidebarWidth,
                              color: _debugPanelBg,
                              child: ListView(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                children: [
                                  groupNavItem(
                                    index: 0,
                                    icon: Icons.dashboard_outlined,
                                    label: '개요',
                                  ),
                                  groupNavItem(
                                    index: 1,
                                    icon: Icons.layers_outlined,
                                    label: '레이어',
                                  ),
                                  groupNavItem(
                                    index: 2,
                                    icon: Icons.build_circle_outlined,
                                    label: '점검',
                                  ),
                                  groupNavItem(
                                    index: 3,
                                    icon: Icons.history,
                                    label: '이력',
                                  ),
                                  groupNavItem(
                                    index: 4,
                                    icon: Icons.slideshow_outlined,
                                    label: '프리뷰',
                                  ),
                                ],
                              ),
                            ),
                            const VerticalDivider(
                              width: 1,
                              color: Colors.white12,
                            ),
                          ],
                          Expanded(
                            child: Column(
                              children: [
                                Container(
                                  width: double.infinity,
                                  padding: EdgeInsets.fromLTRB(
                                    contentHorizontalPadding,
                                    10,
                                    contentHorizontalPadding,
                                    10,
                                  ),
                                  color: _debugCardBgAlt,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          children: [
                                            _debugMetricPill(
                                                '단계', _sidecarStatusTitle()),
                                            SizedBox(width: chipSpacing),
                                            _debugMetricPill(
                                              'Proc',
                                              procStatusLabel,
                                            ),
                                            SizedBox(width: chipSpacing),
                                            _debugMetricPill(
                                              'Cam',
                                              cameraReadyLabel,
                                            ),
                                            SizedBox(width: chipSpacing),
                                            _debugMetricPill('WS', wsState),
                                            SizedBox(width: chipSpacing),
                                            _debugMetricPill(
                                                '최근 프레임', lastFrameAgo),
                                            SizedBox(width: chipSpacing),
                                            _debugMetricPill(
                                              '성능',
                                              'fps ${_overlayDebugFps.toStringAsFixed(1)} · gap ${_overlayModelCameraGap ?? '-'}',
                                            ),
                                          ],
                                        ),
                                      ),
                                      SizedBox(height: headerGap),
                                      Text(
                                        _sidecarPhaseMessage ?? '상태 메시지 없음',
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: chipFontSize,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1, color: Colors.white12),
                                Expanded(
                                  child: SingleChildScrollView(
                                    padding: EdgeInsets.fromLTRB(
                                      contentHorizontalPadding,
                                      10,
                                      contentHorizontalPadding,
                                      16 +
                                          MediaQuery.of(sheetContext)
                                              .viewInsets
                                              .bottom +
                                          8,
                                    ),
                                    child: Column(
                                      children: [
                                        if (selectedGroup == 0)
                                          sectionCard(
                                            '핵심 상태',
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                _statusLine(
                                                  '점검 시각',
                                                  _fmtClock(
                                                      _sidecarProcessCheckedAt),
                                                  labelWidth: statusLabelWidth,
                                                  labelFontSize:
                                                      statusLabelFont,
                                                  valueFontSize:
                                                      statusValueFont,
                                                ),
                                                SizedBox(height: headerGap),
                                                statusGrid(
                                                  [
                                                    (
                                                      label: '단계',
                                                      value:
                                                          _sidecarStatusTitle(),
                                                      color: null
                                                    ),
                                                    (
                                                      label: '프로세스 준비',
                                                      value: procStatusLabel,
                                                      color:
                                                          _sidecarProcessStatusColor()
                                                    ),
                                                    (
                                                      label: '카메라 준비',
                                                      value: cameraReadyLabel,
                                                      color:
                                                          _sidecarCameraStatusColor()
                                                    ),
                                                    (
                                                      label: 'WS',
                                                      value: wsState,
                                                      color: _sidecarConnected
                                                          ? const Color(
                                                              0xFF73E07C)
                                                          : const Color(
                                                              0xFFF6B26B)
                                                    ),
                                                    (
                                                      label: '최근 프레임',
                                                      value: lastFrameAgo,
                                                      color: null
                                                    ),
                                                    (
                                                      label: '성능',
                                                      value:
                                                          'fps ${_overlayDebugFps.toStringAsFixed(1)} · gap ${_overlayModelCameraGap ?? '-'}',
                                                      color: null
                                                    ),
                                                    (
                                                      label: '헬스',
                                                      value:
                                                          healthEndpointSummary,
                                                      color: (healthOk == 'ok')
                                                          ? const Color(
                                                              0xFF73E07C)
                                                          : const Color(
                                                              0xFFFF8A8A)
                                                    ),
                                                    (
                                                      label: '카메라 릴레이',
                                                      value: cameraRelaySummary,
                                                      color: null
                                                    ),
                                                    (
                                                      label: '릴레이 상태',
                                                      value: relayState,
                                                      color: null
                                                    ),
                                                    (
                                                      label: '오버레이 릴레이',
                                                      value: liveRelaySummary,
                                                      color: null
                                                    ),
                                                    (
                                                      label: 'Uptime',
                                                      value: uptime,
                                                      color: null
                                                    ),
                                                    (
                                                      label: '실행 방식',
                                                      value: method,
                                                      color: null
                                                    ),
                                                    (
                                                      label: 'PID',
                                                      value: pid,
                                                      color: null
                                                    ),
                                                    (
                                                      label: '유휴 종료',
                                                      value:
                                                          scheduledStopSummary,
                                                      color: null
                                                    ),
                                                  ],
                                                  columns: isWideDialog ? 3 : 2,
                                                ),
                                                if ((_sidecarProcessStatusError ??
                                                        '')
                                                    .trim()
                                                    .isNotEmpty)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            top: 8),
                                                    child: Text(
                                                      _sidecarProcessStatusError!
                                                          .trim(),
                                                      style: const TextStyle(
                                                        color:
                                                            Color(0xFFFF9AA5),
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            trailing: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                IconButton(
                                                  onPressed: refreshing ||
                                                          actionRunning
                                                      ? null
                                                      : () async {
                                                          setLocalState(() =>
                                                              refreshing =
                                                                  true);
                                                          await _refreshSidecarProcessStatus();
                                                          if (!sheetContext
                                                              .mounted) {
                                                            return;
                                                          }
                                                          setLocalState(() =>
                                                              refreshing =
                                                                  false);
                                                        },
                                                  icon: const Icon(
                                                      Icons.refresh_rounded,
                                                      size: 18,
                                                      color: Colors.white70),
                                                  tooltip: '상태 새로고침',
                                                ),
                                                IconButton(
                                                  onPressed: actionRunning
                                                      ? null
                                                      : () async {
                                                          await runAction(
                                                              _copyDebugSnapshot);
                                                        },
                                                  icon: const Icon(
                                                      Icons
                                                          .content_copy_rounded,
                                                      size: 17,
                                                      color: Colors.white70),
                                                  tooltip: '디버그 스냅샷 복사',
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (selectedGroup == 0)
                                          sectionCard(
                                            'comma 핵심 프로세스',
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                statusGrid(
                                                  [
                                                    (
                                                      label: 'locationd',
                                                      value: criticalValue(
                                                        'locationd',
                                                      ),
                                                      color: criticalColor(
                                                        'locationd',
                                                      )
                                                    ),
                                                    (
                                                      label: 'controlsd',
                                                      value: criticalValue(
                                                        'controlsd',
                                                      ),
                                                      color: criticalColor(
                                                        'controlsd',
                                                      )
                                                    ),
                                                    (
                                                      label: 'plannerd',
                                                      value: criticalValue(
                                                        'plannerd',
                                                      ),
                                                      color: criticalColor(
                                                        'plannerd',
                                                      )
                                                    ),
                                                    (
                                                      label: 'selfdrived',
                                                      value: criticalValue(
                                                        'selfdrived',
                                                      ),
                                                      color: criticalColor(
                                                        'selfdrived',
                                                      )
                                                    ),
                                                    (
                                                      label: 'stream_encoderd',
                                                      value: criticalValue(
                                                        'stream_encoderd',
                                                      ),
                                                      color: criticalColor(
                                                        'stream_encoderd',
                                                      )
                                                    ),

                                                  ],
                                                  columns: isWideDialog ? 3 : 2,
                                                ),
                                                const SizedBox(height: 6),
                                                const Text(
                                                  'camera ready와 별개로 comma onroad 핵심 프로세스가 살아있는지 분리해서 봅니다.',
                                                  style: TextStyle(
                                                    color: Colors.white60,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (selectedGroup == 0)
                                          sectionCard(
                                            '배포/버전 상세',
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                statusGrid(
                                                  [
                                                    (
                                                      label: '배포 결과',
                                                      value:
                                                          _sidecarLastDeployResult,
                                                      color: null
                                                    ),
                                                    (
                                                      label: '원격 해시/버전',
                                                      value: remoteHash,
                                                      color: null
                                                    ),
                                                    (
                                                      label: 'SHA (Local)',
                                                      value: _shortSidecarRevision(
                                                          _sidecarLocalRevision),
                                                      color: null
                                                    ),
                                                    (
                                                      label: 'SHA (Remote)',
                                                      value: _shortSidecarRevision(
                                                          _sidecarRemoteRevision),
                                                      color: null
                                                    ),
                                                    (
                                                      label: 'Revision 동작',
                                                      value:
                                                          _sidecarRevisionAction,
                                                      color: null
                                                    ),
                                                    (
                                                      label: 'Revision 점검',
                                                      value: _fmtClock(
                                                          _sidecarLastRevisionCheckedAt),
                                                      color: null
                                                    ),
                                                    (
                                                      label: 'PY 파일',
                                                      value: remotePyName,
                                                      color: null
                                                    ),
                                                    (
                                                      label: '원격 업데이트',
                                                      value: remoteUpdated,
                                                      color: null
                                                    ),
                                                    (
                                                      label: '최근 시작',
                                                      value: _fmtClock(
                                                          _sidecarLastStartAt),
                                                      color: null
                                                    ),
                                                    (
                                                      label: '최근 중지',
                                                      value: _fmtClock(
                                                          _sidecarLastStopAt),
                                                      color: null
                                                    ),
                                                  ],
                                                  columns: isWideDialog ? 3 : 2,
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (selectedGroup == 0)
                                          sectionCard(
                                            '엔드포인트 응답',
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                statusGrid(
                                                  [
                                                    (
                                                      label: 'GET /health',
                                                      value:
                                                          healthEndpointSummary,
                                                      color: healthOk == 'ok'
                                                          ? const Color(
                                                              0xFF73E07C)
                                                          : const Color(
                                                              0xFFFF8A8A)
                                                    ),
                                                    (
                                                      label: 'GET /profile',
                                                      value:
                                                          profileEndpointSummary,
                                                      color:
                                                          profileEndpointSummary ==
                                                                  '-'
                                                              ? const Color(
                                                                  0xFFFF8A8A)
                                                              : const Color(
                                                                  0xFF73E07C)
                                                    ),
                                                    (
                                                      label:
                                                          'GET /camera_quality',
                                                      value:
                                                          qualityEndpointSummary,
                                                      color:
                                                          qualityEndpointSummary ==
                                                                  '-'
                                                              ? const Color(
                                                                  0xFFFF8A8A)
                                                              : const Color(
                                                                  0xFF73E07C)
                                                    ),
                                                    (
                                                      label: '프로세스 점검',
                                                      value: _fmtClock(
                                                        _sidecarProcessCheckedAt,
                                                      ),
                                                      color: null
                                                    ),
                                                  ],
                                                  columns: isWideDialog ? 2 : 1,
                                                ),
                                                const SizedBox(height: 6),
                                                const Text(
                                                  '상단 배지와 이 영역은 같은 remote status / endpoint 스냅샷을 사용합니다.',
                                                  style: TextStyle(
                                                    color: Colors.white60,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (selectedGroup == 0)
                                          sectionCard(
                                            '최초설정 상태',
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                _statusLine(
                                                  '최초설정 완료(로컬)',
                                                  bootstrapConfigured,
                                                  labelWidth: statusLabelWidth,
                                                  labelFontSize:
                                                      statusLabelFont,
                                                  valueFontSize:
                                                      statusValueFont,
                                                ),
                                                _statusLine(
                                                  '마지막 자동설정 결과',
                                                  bootstrapLastResult,
                                                  labelWidth: statusLabelWidth,
                                                  labelFontSize:
                                                      statusLabelFont,
                                                  valueFontSize:
                                                      statusValueFont,
                                                ),
                                                _statusLine(
                                                  '마지막 자동설정 시각',
                                                  bootstrapLastAt,
                                                  labelWidth: statusLabelWidth,
                                                  labelFontSize:
                                                      statusLabelFont,
                                                  valueFontSize:
                                                      statusValueFont,
                                                ),
                                                _statusLine(
                                                  '상세',
                                                  bootstrapLastDetail,
                                                  labelWidth: statusLabelWidth,
                                                  labelFontSize:
                                                      statusLabelFont,
                                                  valueFontSize:
                                                      statusValueFont,
                                                ),
                                                const SizedBox(height: 6),
                                                const Text(
                                                  '사이드카 미배포 감지 시 자동설정(배포)을 1회 수행합니다.',
                                                  style: TextStyle(
                                                    color: Colors.white60,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (selectedGroup == 1)
                                          sectionCard(
                                            '그래픽 레이어 토글',
                                            Column(
                                              children: [

                                                layerSwitch(
                                                  'AR Overlay 표시',
                                                  _debugShowArOverlay,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugShowArOverlay =
                                                              value,
                                                    );
                                                    if (!value) {
                                                      unawaited(
                                                        _clearNativeOverlay(),
                                                      );
                                                    } else if (_useNativeOverlayRenderer) {
                                                      unawaited(
                                                        _pushNativeOverlay(
                                                          _overlayNotifier.value,
                                                          force: true,
                                                        ),
                                                      );
                                                    }
                                                  },
                                                ),
                                                layerSwitch(
                                                  'Native AR scene 전송',
                                                  _debugPushNativeArScene,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugPushNativeArScene =
                                                              value,
                                                    );
                                                    if (_useNativeOverlayRenderer) {
                                                      unawaited(
                                                        _pushNativeOverlay(
                                                          _overlayNotifier.value,
                                                          force: true,
                                                        ),
                                                      );
                                                    }
                                                  },
                                                ),
                                                layerSwitch(
                                                  'AR 자동 저장',
                                                  _debugArCaptureEnabled &&
                                                      _debugArAutoPersistEnabled,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () {
                                                        _debugArCaptureEnabled =
                                                            value;
                                                        _debugArAutoPersistEnabled =
                                                            value;
                                                      },
                                                    );
                                                  },
                                                ),
                                                const Divider(
                                                    color: Colors.white12,
                                                    height: 10),
                                                const Align(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: Padding(
                                                    padding: EdgeInsets.only(
                                                        top: 2, bottom: 4),
                                                    child: Text(
                                                      '주행 경로',
                                                      style: TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                layerSwitch(
                                                  'Path Fill',
                                                  _debugShowPathFill,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugShowPathFill =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'Lane Lines',
                                                  _debugShowLaneLines,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugShowLaneLines =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'Road Edge',
                                                  _debugShowRoadEdge,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugShowRoadEdge =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                const Divider(
                                                    color: Colors.white12,
                                                    height: 10),
                                                const Align(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: Padding(
                                                    padding: EdgeInsets.only(
                                                        top: 2, bottom: 4),
                                                    child: Text(
                                                      '리드/레이더',
                                                      style: TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                layerSwitch(
                                                  'Lead1',
                                                  _debugShowLead1,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugShowLead1 =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'Lead2',
                                                  _debugShowLead2,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugShowLead2 =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'Radar Badge',
                                                  _debugShowRadarBadge,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugShowRadarBadge =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'Radar Vector',
                                                  _debugShowRadarVector,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugShowRadarVector =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'Stop-distance (TF)',
                                                  _debugShowStopDistanceTf,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugShowStopDistanceTf =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'State Text',
                                                  _debugShowStateText,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugShowStateText =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                const Divider(
                                                    color: Colors.white12,
                                                    height: 10),
                                                const Align(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: Padding(
                                                    padding: EdgeInsets.only(
                                                        top: 2, bottom: 4),
                                                    child: Text(
                                                      'YOLO',
                                                      style: TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                layerSwitch(
                                                  'YOLO Enabled',
                                                  _debugYoloEnabled,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugYoloEnabled =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'YOLO Boxes',
                                                  _debugYoloBoxes,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugYoloBoxes =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'YOLO Labels',
                                                  _debugYoloLabels,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugYoloLabels =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'YOLO TrafficLight',
                                                  _debugYoloTrafficLights,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugYoloTrafficLights =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                layerSwitch(
                                                  'YOLO Stats',
                                                  _debugYoloStats,
                                                  (value) {
                                                    _onLayerToggleChanged(
                                                      setLocalState,
                                                      () =>
                                                          _debugYoloStats =
                                                              value,
                                                    );
                                                  },
                                                ),
                                                const Divider(
                                                    color: Colors.white12,
                                                    height: 10),
                                                const Align(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: Padding(
                                                    padding: EdgeInsets.only(
                                                        top: 2, bottom: 4),
                                                    child: Text(
                                                      '정합/검증',
                                                      style: TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                const Divider(
                                                    color: Colors.white12,
                                                    height: 14),
                                                layerSwitch(
                                                  '크롭(cover) 기본',
                                                  _coverViewportPreferred,
                                                  _LiveDriveCanvasScreenState
                                                          ._temporaryLimitedHudControls
                                                      ? null
                                                      : (value) {
                                                          _setViewportFitMode(
                                                              value);
                                                          setLocalState(() {});
                                                        },
                                                ),
                                                layerSwitch(
                                                  '정합 검증',
                                                  _overlayVerifyMode,
                                                  _LiveDriveCanvasScreenState
                                                          ._temporaryLimitedHudControls
                                                      ? null
                                                      : (value) {
                                                          _setOverlayVerifyMode(
                                                              value);
                                                          setLocalState(() {});
                                                        },
                                                ),
                                                layerSwitch(
                                                  '그리드/가이드',
                                                  _debugShowGuides,
                                                  debugEnabled
                                                      ? (value) {
                                                          _setDebugGuides(
                                                              value);
                                                          setLocalState(() {});
                                                        }
                                                      : null,
                                                ),
                                                layerSwitch(
                                                  '우측 정보창',
                                                  _debugShowVerifyPanel,
                                                  debugEnabled
                                                      ? (value) {
                                                          _setDebugVerifyPanel(
                                                              value);
                                                          setLocalState(() {});
                                                        }
                                                      : null,
                                                ),
                                                layerSwitch(
                                                  '레터박스 프레임',
                                                  _debugShowViewportFrame,
                                                  debugEnabled
                                                      ? (value) {
                                                          _setDebugViewportFrame(
                                                              value);
                                                          setLocalState(() {});
                                                        }
                                                      : null,
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (selectedGroup == 3)
                                          sectionCard(
                                            '자동화 이력 (최근 10개)',
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                if (history.isEmpty)
                                                  const Text(
                                                    '이력 없음',
                                                    style: TextStyle(
                                                      color: Colors.white54,
                                                      fontSize: 12,
                                                    ),
                                                  )
                                                else
                                                  ...history.map(
                                                    (line) => Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              bottom: 3),
                                                      child: Text(
                                                        line,
                                                        style: const TextStyle(
                                                          color: Colors.white70,
                                                          fontSize: 11,
                                                          fontFamily:
                                                              'monospace',
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        if (selectedGroup == 2)
                                          sectionCard(
                                            '즉시 점검',
                                            Column(
                                              children: [
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionHealth),
                                                    icon: const Icon(Icons
                                                        .health_and_safety_outlined),
                                                    label: const Text('헬스체크'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionWsProbe),
                                                    icon: const Icon(
                                                        Icons.wifi_tethering),
                                                    label: const Text('WS 프로브'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionTailLog),
                                                    icon: const Icon(
                                                        Icons.subject),
                                                    label: const Text(
                                                        '로그 tail 50'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionInspectArScene),
                                                    icon: const Icon(Icons
                                                        .view_in_ar_outlined),
                                                    label: const Text(
                                                        'AR scene 보기'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionCaptureArReplay),
                                                    icon: const Icon(
                                                        Icons.save_alt_rounded),
                                                    label:
                                                        const Text('AR 캡처 저장'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionExportArReplay),
                                                    icon: const Icon(Icons
                                                        .file_download_outlined),
                                                    label:
                                                        const Text('AR 파일 저장'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionUseLatestArReplay),
                                                    icon: const Icon(Icons
                                                        .play_circle_outline_rounded),
                                                    label:
                                                        const Text('마지막 캡처 재생'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionStopArReplay),
                                                    icon: const Icon(Icons
                                                        .stop_circle_outlined),
                                                    label:
                                                        const Text('AR 재생 종료'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionRedeploy),
                                                    icon: const Icon(Icons
                                                        .system_update_alt_rounded),
                                                    label: const Text('재배포'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionLegacyMigration),
                                                    icon: const Icon(Icons
                                                        .cleaning_services_rounded),
                                                    label: const Text(
                                                        '레거시 정리+재배포'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionRestart),
                                                    icon: const Icon(Icons
                                                        .restart_alt_rounded),
                                                    label: const Text('재시작'),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: FilledButton.icon(
                                                    style:
                                                        FilledButton.styleFrom(
                                                      backgroundColor:
                                                          const Color(
                                                              0xFF7A2A2A),
                                                    ),
                                                    onPressed: actionRunning
                                                        ? null
                                                        : () => runAction(
                                                            _debugActionResetSidecar),
                                                    icon: const Icon(Icons
                                                        .delete_forever_rounded),
                                                    label: const Text(
                                                        '사이드카 초기화(테스트)'),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (selectedGroup == 4)
                                          sectionCard(
                                            '그래픽 프리뷰 (개발용)',
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                layerSwitch(
                                                  '프리뷰 모드 사용 (alive/카메라 없이)',
                                                  _debugOverlayPreviewMode,
                                                  (value) {
                                                    _setOverlayPreviewMode(
                                                        value);
                                                    setLocalState(() {});
                                                  },
                                                ),
                                                const SizedBox(height: 8),
                                                DropdownButtonFormField<
                                                    _OverlayPreviewScenario>(
                                                  initialValue:
                                                      _debugOverlayPreviewScenario,
                                                  decoration:
                                                      const InputDecoration(
                                                    labelText: '시나리오',
                                                    border:
                                                        OutlineInputBorder(),
                                                    isDense: true,
                                                  ),
                                                  dropdownColor: _debugCardBg,
                                                  style: const TextStyle(
                                                      color: Colors.white),
                                                  items: _OverlayPreviewScenario
                                                      .values
                                                      .map(
                                                        (scenario) =>
                                                            DropdownMenuItem<
                                                                _OverlayPreviewScenario>(
                                                          value: scenario,
                                                          child: Text(
                                                            _overlayPreviewScenarioLabel(
                                                                scenario),
                                                          ),
                                                        ),
                                                      )
                                                      .toList(growable: false),
                                                  onChanged:
                                                      _debugOverlayPreviewMode
                                                          ? (next) {
                                                              if (next ==
                                                                  null) {
                                                                return;
                                                              }
                                                              _safeSetState(() {
                                                                _debugOverlayPreviewScenario =
                                                                    next;
                                                              });
                                                              _tickOverlayPreview();
                                                              setLocalState(
                                                                  () {});
                                                            }
                                                          : null,
                                                ),
                                                const SizedBox(height: 8),
                                                DropdownButtonFormField<int>(
                                                  initialValue:
                                                      _debugOverlayPreviewPlotMode,
                                                  decoration:
                                                      const InputDecoration(
                                                    labelText: 'Plot 미리보기 모드',
                                                    border:
                                                        OutlineInputBorder(),
                                                    isDense: true,
                                                  ),
                                                  dropdownColor: _debugCardBg,
                                                  style: const TextStyle(
                                                      color: Colors.white),
                                                  items: List<int>.generate(
                                                    11,
                                                    (index) => index,
                                                  )
                                                      .map(
                                                        (mode) =>
                                                            DropdownMenuItem<
                                                                int>(
                                                          value: mode,
                                                          child: Text(
                                                            _overlayPreviewPlotModeLabel(
                                                                mode),
                                                          ),
                                                        ),
                                                      )
                                                      .toList(growable: false),
                                                  onChanged:
                                                      _debugOverlayPreviewMode
                                                          ? (next) {
                                                              if (next ==
                                                                  null) {
                                                                return;
                                                              }
                                                              _safeSetState(() {
                                                                _debugOverlayPreviewPlotMode =
                                                                    next;
                                                              });
                                                              _tickOverlayPreview();
                                                              setLocalState(
                                                                  () {});
                                                            }
                                                          : null,
                                                ),
                                                const SizedBox(height: 12),
                                                Text(
                                                  '애니메이션 속도 ${_debugOverlayPreviewSpeed.toStringAsFixed(2)}x',
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                                Slider(
                                                  min: 0.5,
                                                  max: 2.0,
                                                  divisions: 15,
                                                  value:
                                                      _debugOverlayPreviewSpeed,
                                                  label:
                                                      _debugOverlayPreviewSpeed
                                                          .toStringAsFixed(2),
                                                  onChanged:
                                                      _debugOverlayPreviewMode
                                                          ? (value) {
                                                              _safeSetState(() {
                                                                _debugOverlayPreviewSpeed =
                                                                    value;
                                                              });
                                                              setLocalState(
                                                                  () {});
                                                            }
                                                          : null,
                                                ),
                                                const SizedBox(height: 6),
                                                Wrap(
                                                  spacing: 8,
                                                  runSpacing: 8,
                                                  children: [
                                                    OutlinedButton.icon(
                                                      onPressed:
                                                          _debugOverlayPreviewMode
                                                              ? () {
                                                                  _tickOverlayPreview();
                                                                  setLocalState(
                                                                      () {});
                                                                }
                                                              : null,
                                                      icon: const Icon(Icons
                                                          .refresh_rounded),
                                                      label: const Text(
                                                          '프레임 새로고침'),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 8),
                                                const Text(
                                                  '프리뷰는 실차 데이터와 분리된 mock 렌더입니다.\n디자인/배치 확인용으로만 사용하세요.',
                                                  style: TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
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
}
