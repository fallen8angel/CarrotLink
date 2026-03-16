part of 'live_drive_canvas_screen.dart';

const Color _driveMenuDialogBg = Color(0xFF17120F);
const Color _driveMenuNavBg = Color(0xFF211A15);
const Color _driveMenuPanelBg = Color(0xFF1D1612);

extension _LiveDriveCanvasSettingsPopupComponents
    on _LiveDriveCanvasScreenState {
  Future<void> _openDriveSettingsPopupImpl() async {
    if (!mounted) return;

    Future<void> applyDefaults(StateSetter setLocalState) async {
      _onLayerToggleChanged(setLocalState, () {
        _debugShowArOverlay = true;
        _debugShowPathFill = true;
        _debugShowLaneLines = true;
        _debugShowRoadEdge = true;
        _debugShowLead1 = true;
        _debugShowLead2 = true;
        _debugShowRadarBadge = true;
        _debugShowRadarVector = true;
        _debugShowStopDistanceTf = true;
        _debugShowStateText = true;
        _debugShowStockTopRight = true;
        _debugShowLaneMetrics = true;
        _debugShowDebugPlot = true;
      });
    }

    await showDialog<void>(
      context: context,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final developerMode =
                Provider.of<DeveloperModeService>(sheetContext, listen: false);
            final yoloGroupVisible = developerMode.enabled;
            if (!yoloGroupVisible &&
                _driveSettingsPopupGroup == _DriveSettingsPopupGroup.yolo) {
              _driveSettingsPopupGroup = _DriveSettingsPopupGroup.graphics;
            }

            final window = UiWindowInfo.of(sheetContext);
            final screenSize = MediaQuery.of(sheetContext).size;
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
              isWideDialog ? 1080.0 : 760.0,
            );
            final contentHorizontalPadding = window.isCompact ? 12.0 : 16.0;
            final headerPadding = EdgeInsets.fromLTRB(
              window.isCompact ? 14 : 18,
              window.isCompact ? 10 : 12,
              10,
              window.isCompact ? 8 : 10,
            );
            final headerFontSize =
                window.isCompact ? 18.0 : (isWideDialog ? 20.0 : 19.0);
            final chipFontSize = window.isCompact ? 11.0 : 12.0;

            Future<void> refreshPopup() async {
              if (!mounted || !sheetContext.mounted) return;
              setLocalState(() {});
            }

            Widget buildGroupButton({
              required String title,
              required _DriveSettingsPopupGroup group,
            }) {
              final selected = _driveSettingsPopupGroup == group;
              return Container(
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFF2B221C) : _driveMenuNavBg,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: selected ? const Color(0xFFFFB07A) : Colors.white24,
                  ),
                ),
                child: TextButton(
                  onPressed: () {
                    setLocalState(() {
                      _driveSettingsPopupGroup = group;
                    });
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11),
                    ),
                  ),
                  child: Text(
                    title,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: chipFontSize + 1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              );
            }

            Widget buildSectionTitle(String title) {
              return Padding(
                padding: EdgeInsets.only(
                  top: window.isCompact ? 10 : 12,
                  bottom: window.isCompact ? 6 : 8,
                ),
                child: Text(
                  title,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: window.isCompact ? 14 : 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              );
            }

            Widget buildToggle({
              required String title,
              required bool value,
              required ValueChanged<bool> onChanged,
              bool enabled = true,
            }) {
              return Opacity(
                opacity: enabled ? 1 : 0.45,
                child: IgnorePointer(
                  ignoring: !enabled,
                  child: SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 0,
                      vertical: 0,
                    ),
                    value: value,
                    onChanged: onChanged,
                    title: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              );
            }

            Widget buildActionRow({
              required String title,
              String? value,
              Future<void> Function()? onTap,
              bool enabled = true,
              bool destructive = false,
            }) {
              final row = ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  title,
                  style: TextStyle(
                    color: enabled
                        ? (destructive ? const Color(0xFFFF8472) : Colors.white)
                        : Colors.white38,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: value != null
                    ? ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 280),
                        child: Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : (onTap != null
                        ? const Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white54,
                          )
                        : null),
                onTap: enabled && onTap != null
                    ? () => unawaited(onTap().then((_) => refreshPopup()))
                    : null,
              );
              return Opacity(opacity: enabled ? 1 : 0.45, child: row);
            }

            Widget buildSection({
              required String title,
              required List<Widget> rows,
            }) {
              final children = <Widget>[buildSectionTitle(title)];
              for (var i = 0; i < rows.length; i++) {
                children.add(rows[i]);
                if (i != rows.length - 1) {
                  children.add(const Divider(height: 1, color: Colors.white12));
                }
              }
              children.add(const SizedBox(height: 8));
              children.add(const Divider(height: 1, color: Colors.white12));
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              );
            }

            final currentVideoName = _developerPlaybackVideoPath == null ||
                    _developerPlaybackVideoPath!.trim().isEmpty
                ? '-'
                : p.basename(_developerPlaybackVideoPath!.trim());
            final playbackStateLabel =
                _isDeveloperPlaybackRequested ? 'offline' : 'live';
            final yoloSections = <Widget>[
              buildSection(
                title: 'YOLO',
                rows: [
                  buildActionRow(
                    title: '백엔드',
                    value: _driveYoloDebugSettings.runtimeBackend.label,
                    onTap: () async {
                      final selected =
                          await showModalBottomSheet<YoloRuntimeBackend>(
                        context: sheetContext,
                        backgroundColor: _driveMenuDialogBg,
                        builder: (ctx) {
                          return SafeArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final backend in YoloRuntimeBackend.values)
                                  ListTile(
                                    title: Text(
                                      backend.label,
                                      style:
                                          const TextStyle(color: Colors.white),
                                    ),
                                    trailing: backend ==
                                            _driveYoloDebugSettings
                                                .runtimeBackend
                                        ? const Icon(
                                            Icons.check_rounded,
                                            color: Color(0xFFFFB07A),
                                          )
                                        : null,
                                    onTap: () => Navigator.of(ctx).pop(backend),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                      if (selected == null) return;
                      await _setDriveYoloDebugSettings(
                        _driveYoloDebugSettings.copyWith(
                          runtimeBackend: selected,
                        ),
                      );
                    },
                  ),
                  buildActionRow(
                    title: '모델',
                    value: _driveYoloDebugSettings.modelVariant.settingsLabel,
                    onTap: () async {
                      final selectorSections = buildYoloModelSelectorSections(
                        backend: _driveYoloDebugSettings.runtimeBackend,
                      );
                      final selected =
                          await showModalBottomSheet<YoloModelVariant>(
                        context: sheetContext,
                        backgroundColor: _driveMenuDialogBg,
                        builder: (ctx) {
                          return SafeArea(
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                for (final entry
                                    in selectorSections.entries) ...[
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      14,
                                      16,
                                      6,
                                    ),
                                    child: Text(
                                      entry.key,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  for (final choice in entry.value)
                                    Opacity(
                                      opacity: choice.enabled ? 1 : 0.5,
                                      child: ListTile(
                                        enabled: choice.enabled,
                                        title: Text(
                                          choice.title,
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                        subtitle: Text(
                                          choice.subtitle,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                        trailing: choice.variant ==
                                                _driveYoloDebugSettings
                                                    .modelVariant
                                            ? const Icon(
                                                Icons.check_rounded,
                                                color: Color(0xFFFFB07A),
                                              )
                                            : null,
                                        onTap: !choice.enabled ||
                                                choice.variant == null
                                            ? null
                                            : () => Navigator.of(
                                                  ctx,
                                                ).pop(choice.variant),
                                      ),
                                    ),
                                ],
                                const SizedBox(height: 8),
                              ],
                            ),
                          );
                        },
                      );
                      if (selected == null) return;
                      await _setDriveYoloDebugSettings(
                        _driveYoloDebugSettings.copyWith(
                          modelVariant: selected,
                        ),
                      );
                    },
                  ),
                  buildToggle(
                    title: 'ExecuTorch',
                    value: _driveYoloDebugSettings.unsafeRuntimeEnabled,
                    onChanged: (value) {
                      unawaited(
                        _setDriveYoloDebugSettings(
                          _driveYoloDebugSettings.copyWith(
                            unsafeRuntimeEnabled: value,
                          ),
                        ).then((_) => refreshPopup()),
                      );
                    },
                  ),
                  buildToggle(
                    title: '활성화',
                    value: _driveYoloDebugSettings.enabled,
                    onChanged: (value) {
                      unawaited(
                        _setDriveYoloDebugSettings(
                          _driveYoloDebugSettings.copyWith(enabled: value),
                        ).then((_) => refreshPopup()),
                      );
                    },
                  ),
                  buildToggle(
                    title: '박스',
                    value: _driveYoloDebugSettings.showBoxes,
                    enabled: _driveYoloDebugSettings.enabled,
                    onChanged: (value) {
                      unawaited(
                        _setDriveYoloDebugSettings(
                          _driveYoloDebugSettings.copyWith(showBoxes: value),
                        ).then((_) => refreshPopup()),
                      );
                    },
                  ),
                  buildToggle(
                    title: '라벨',
                    value: _driveYoloDebugSettings.showLabels,
                    enabled: _driveYoloDebugSettings.enabled,
                    onChanged: (value) {
                      unawaited(
                        _setDriveYoloDebugSettings(
                          _driveYoloDebugSettings.copyWith(showLabels: value),
                        ).then((_) => refreshPopup()),
                      );
                    },
                  ),
                  buildToggle(
                    title: '신호등',
                    value: _driveYoloDebugSettings.showTrafficLights,
                    enabled: _driveYoloDebugSettings.enabled,
                    onChanged: (value) {
                      unawaited(
                        _setDriveYoloDebugSettings(
                          _driveYoloDebugSettings.copyWith(
                            showTrafficLights: value,
                          ),
                        ).then((_) => refreshPopup()),
                      );
                    },
                  ),
                  buildToggle(
                    title: '통계',
                    value: _driveYoloDebugSettings.showStats,
                    enabled: _driveYoloDebugSettings.enabled,
                    onChanged: (value) {
                      unawaited(
                        _setDriveYoloDebugSettings(
                          _driveYoloDebugSettings.copyWith(showStats: value),
                        ).then((_) => refreshPopup()),
                      );
                    },
                  ),
                ],
              ),
              buildSection(
                title: '재생',
                rows: [
                  buildActionRow(
                    title: '입력',
                    value: playbackStateLabel,
                  ),
                  buildActionRow(
                    title: '영상',
                    value: currentVideoName,
                  ),
                  buildActionRow(
                    title: '상단 빠른 제어',
                    value: '선택 / 재생 / 일시정지 / 복사',
                  ),
                  buildActionRow(
                    title: '위치',
                    value: _developerPlaybackController == null
                        ? '-'
                        : _developerPlaybackController!.value.position
                            .toString()
                            .split('.')
                            .first,
                  ),
                ],
              ),
              buildSection(
                title: '상태',
                rows: [
                  buildActionRow(
                    title: '상태 새로고침',
                    onTap: _loadDriveYoloRuntimeStatus,
                  ),
                  buildActionRow(
                    title: '상태 복사',
                    onTap: _copyDriveYoloRuntimeStatus,
                  ),
                  buildActionRow(
                    title: 'stage',
                    value: _driveYoloValue('stage'),
                  ),
                  buildActionRow(
                    title: 'blocker',
                    value: _driveYoloValue('blocker'),
                  ),
                  buildActionRow(
                    title: 'backend',
                    value: _driveYoloValue('runtimeBackend'),
                  ),
                  buildActionRow(
                    title: 'model',
                    value: _driveYoloValue('modelVariant'),
                  ),
                  buildActionRow(
                    title: 'detections',
                    value: _driveYoloValue('parsedDetectionCount'),
                  ),
                  buildActionRow(
                    title: 'parser',
                    value: _driveYoloValue('parserStrategy'),
                  ),
                  buildActionRow(
                    title: 'threshold',
                    value: _driveYoloValue('parserScoreThreshold'),
                  ),
                  buildActionRow(
                    title: 'above',
                    value: _driveYoloValue('parserAboveThresholdCount'),
                  ),
                  buildActionRow(
                    title: 'maxScore',
                    value: _driveYoloValue('parserMaxClassScore'),
                  ),
                  buildActionRow(
                    title: 'frames',
                    value: _driveYoloFrameSummary(),
                  ),
                  buildActionRow(
                    title: 'sync',
                    value: _driveYoloValue('syncSource'),
                  ),
                  buildActionRow(
                    title: 'playbackFrameId',
                    value: _driveYoloValue('playbackFrameId'),
                  ),
                  buildActionRow(
                    title: 'playbackPtsUs',
                    value: _driveYoloValue('playbackFramePtsUs'),
                  ),
                  buildActionRow(
                    title: 'syncToken',
                    value: _driveYoloValue('playbackFrameToken'),
                  ),
                  buildActionRow(
                    title: 'updated',
                    value: _developerPlaybackStatusUpdatedAt
                            ?.toLocal()
                            .toString() ??
                        '-',
                  ),
                ],
              ),
            ];

            final graphicsSections = <Widget>[
              buildSection(
                title: '전체',
                rows: [
                  buildToggle(
                    title: '오버레이 전체',
                    value: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowArOverlay = value,
                    ),
                  ),
                ],
              ),
              buildSection(
                title: '도로 / 차선',
                rows: [
                  buildToggle(
                    title: '도로 영역',
                    value: _debugShowPathFill,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowPathFill = value,
                    ),
                  ),
                  buildToggle(
                    title: '차선',
                    value: _debugShowLaneLines,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowLaneLines = value,
                    ),
                  ),
                  buildToggle(
                    title: '도로 경계',
                    value: _debugShowRoadEdge,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowRoadEdge = value,
                    ),
                  ),
                ],
              ),
              buildSection(
                title: '선행차 / 레이더',
                rows: [
                  buildToggle(
                    title: '선행차 1',
                    value: _debugShowLead1,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowLead1 = value,
                    ),
                  ),
                  buildToggle(
                    title: '선행차 2',
                    value: _debugShowLead2,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowLead2 = value,
                    ),
                  ),
                  buildToggle(
                    title: '레이더 배지',
                    value: _debugShowRadarBadge,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowRadarBadge = value,
                    ),
                  ),
                  buildToggle(
                    title: '레이더 벡터',
                    value: _debugShowRadarVector,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowRadarVector = value,
                    ),
                  ),
                ],
              ),
              buildSection(
                title: '텍스트 / 마커',
                rows: [
                  buildToggle(
                    title: '정지 거리',
                    value: _debugShowStopDistanceTf,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowStopDistanceTf = value,
                    ),
                  ),
                  buildToggle(
                    title: '상태 텍스트',
                    value: _debugShowStateText,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowStateText = value,
                    ),
                  ),
                  buildToggle(
                    title: 'LD/LT/SR',
                    value: _debugShowStockTopRight,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowStockTopRight = value,
                    ),
                  ),
                  buildToggle(
                    title: '레인모드/레인리스',
                    value: _debugShowLaneMetrics,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowLaneMetrics = value,
                    ),
                  ),
                  buildToggle(
                    title: '디버그 플롯',
                    value: _debugShowDebugPlot,
                    enabled: _debugShowArOverlay,
                    onChanged: (value) => _onLayerToggleChanged(
                      setLocalState,
                      () => _debugShowDebugPlot = value,
                    ),
                  ),
                ],
              ),
            ];

            final visibleSections =
                _driveSettingsPopupGroup == _DriveSettingsPopupGroup.graphics
                    ? graphicsSections
                    : yoloSections;

            return Dialog(
              backgroundColor: _driveMenuDialogBg,
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
                              '설정($_settingsMenuFlavorLabel)',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: headerFontSize,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (_driveSettingsPopupGroup ==
                              _DriveSettingsPopupGroup.graphics)
                            TextButton(
                              onPressed: () => applyDefaults(setLocalState),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                backgroundColor: _driveMenuNavBg,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  side: const BorderSide(color: Colors.white12),
                                ),
                              ),
                              child: const Text('기본값'),
                            ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white70,
                            ),
                            tooltip: '닫기',
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white12),
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.fromLTRB(
                        contentHorizontalPadding,
                        10,
                        contentHorizontalPadding,
                        10,
                      ),
                      color: _driveMenuPanelBg,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            buildGroupButton(
                              title: '그래픽',
                              group: _DriveSettingsPopupGroup.graphics,
                            ),
                            if (yoloGroupVisible) ...[
                              const SizedBox(width: 8),
                              buildGroupButton(
                                title: 'YOLO',
                                group: _DriveSettingsPopupGroup.yolo,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white12),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          contentHorizontalPadding,
                          10,
                          contentHorizontalPadding,
                          16,
                        ),
                        child: Column(children: visibleSections),
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
