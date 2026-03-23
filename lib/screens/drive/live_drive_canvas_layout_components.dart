part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasLayoutComponents on _LiveDriveCanvasScreenState {
  EdgeInsets _driveFoldInsetsImpl() {
    final media = MediaQuery.of(context);
    final hingeAware = DisplayFeatureUtils.hingeAwarePadding(context);
    return EdgeInsets.only(
      left: math.max(0.0, hingeAware.left - media.padding.left),
      top: math.max(0.0, hingeAware.top - media.padding.top),
      right: math.max(0.0, hingeAware.right - media.padding.right),
      bottom: math.max(0.0, hingeAware.bottom - media.padding.bottom),
    );
  }

  Widget _buildDriveScaffoldBodyImpl(UiWindowInfo window) {
    return SafeArea(
      child: Padding(
        padding: _driveFoldInsetsImpl(),
        child: LayoutBuilder(
          builder: (context, constraints) =>
              _buildDriveResponsiveLayoutImpl(window, constraints),
        ),
      ),
    );
  }

  Widget _buildDriveResponsiveLayoutImpl(
    UiWindowInfo window,
    BoxConstraints constraints,
  ) {
    final isLandscapeLayout = window.isLandscape;
    final hideHudForTinyViewport = _shouldHideHudForTinyViewport(
      window,
      constraints,
      isLandscape: isLandscapeLayout,
    );

    final mainContent = _buildDriveMainContentImpl(
      window,
      constraints,
      isLandscapeLayout: isLandscapeLayout,
      hideHudForTinyViewport: hideHudForTinyViewport,
    );

    final fabInset = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 14.0,
      UiWindowClass.expanded => 16.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 18.0,
    };
    final fabBottom = fabInset;
    final settingsFab = FloatingActionButton.small(
      heroTag: isLandscapeLayout
          ? 'drive_settings_fab_landscape'
          : 'drive_settings_fab_portrait',
      tooltip: '설정',
      onPressed: _openDriveSettingsPopup,
      backgroundColor: const Color(0xCC2A1A12),
      foregroundColor: const Color(0xFFFFB07A),
      child: const Icon(Icons.settings_rounded),
    );
    final quickControls = _buildViewportZoomQuickControls(
      settingsFab: settingsFab,
      isLandscapeLayout: isLandscapeLayout,
    );
    final developerPlaybackQuickControls = _buildDeveloperPlaybackQuickControls(
      isLandscapeLayout: isLandscapeLayout,
    );

    if (isLandscapeLayout || hideHudForTinyViewport) {
      return Stack(
        children: [
          Positioned.fill(child: mainContent),
          if (developerPlaybackQuickControls != null)
            Positioned(
              right: fabInset,
              top: fabInset,
              child: developerPlaybackQuickControls,
            ),
          Positioned(
            right: fabInset,
            bottom: fabBottom,
            child: quickControls,
          ),
        ],
      );
    }

    final portraitHudHeight = _computePortraitHudHeight(window, constraints);

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: mainContent),
              if (developerPlaybackQuickControls != null)
                Positioned(
                  right: fabInset,
                  top: fabInset,
                  child: developerPlaybackQuickControls,
                ),
              Positioned(
                right: fabInset,
                bottom: fabBottom,
                child: quickControls,
              ),
            ],
          ),
        ),
        SizedBox(
          width: double.infinity,
          height: portraitHudHeight,
          child: _buildPortraitHudPanel(window),
        ),
      ],
    );
  }

  Widget _buildDriveMainContentImpl(
    UiWindowInfo window,
    BoxConstraints constraints, {
    required bool isLandscapeLayout,
    required bool hideHudForTinyViewport,
  }) {
    return ColoredBox(
      color: Colors.black,
      child: _buildDriveViewportContentImpl(
        window,
        constraints,
        isLandscapeLayout: isLandscapeLayout,
        hideHudForTinyViewport: hideHudForTinyViewport,
      ),
    );
  }

  Widget _buildViewportZoomQuickControls({
    required Widget settingsFab,
    required bool isLandscapeLayout,
  }) {
    final spacing = isLandscapeLayout ? 8.0 : 7.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ..._DriveViewportZoomPreset.values.map(
          (preset) => Padding(
            padding: EdgeInsets.only(right: spacing),
            child: _buildViewportZoomButton(preset),
          ),
        ),
        settingsFab,
      ],
    );
  }

  Widget? _buildDeveloperPlaybackQuickControls({
    required bool isLandscapeLayout,
  }) {
    final developerMode = Provider.of<DeveloperModeService>(context);
    if (!developerMode.enabled) return null;
    final hasSelection =
        _developerPlaybackVideoPath?.trim().isNotEmpty ?? false;
    final controller = _developerPlaybackController;
    final canControlPlayback = _developerPlaybackEnabled &&
        controller != null &&
        controller.value.isInitialized;
    final playbackRunning = canControlPlayback && controller.value.isPlaying;
    final currentVideoName = hasSelection
        ? p.basename(_developerPlaybackVideoPath!.trim())
        : '영상 미선택';
    final subtitle = canControlPlayback
        ? controller.value.position.toString().split('.').first
        : (_developerPlaybackEnabled ? '준비 중' : '대기');

    Widget actionButton({
      required String tooltip,
      required IconData icon,
      required VoidCallback? onTap,
      bool selected = false,
      bool destructive = false,
    }) {
      final backgroundColor = destructive
          ? const Color(0xFFC25B4C)
          : (selected ? const Color(0xFFE88C53) : const Color(0xCC2A1A12));
      return Tooltip(
        message: tooltip,
        child: Material(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Icon(
                icon,
                size: 18,
                color: onTap == null ? Colors.white38 : Colors.white,
              ),
            ),
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: isLandscapeLayout ? 320 : 280,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xCC17120F),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  currentVideoName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Color(0xFFFFD7B7),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  actionButton(
                    tooltip: '영상 선택',
                    icon: Icons.video_library_rounded,
                    onTap: () => unawaited(_selectDeveloperPlaybackVideo()),
                  ),
                  actionButton(
                    tooltip: _developerPlaybackEnabled ? '재생 종료' : '오프라인 재생',
                    icon: _developerPlaybackEnabled
                        ? Icons.stop_circle_rounded
                        : Icons.play_circle_fill_rounded,
                    onTap: hasSelection
                        ? () => unawaited(_toggleDeveloperPlaybackEnabled())
                        : null,
                    selected: _developerPlaybackEnabled,
                  ),
                  actionButton(
                    tooltip: playbackRunning ? '일시정지' : '재생',
                    icon: playbackRunning
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_arrow_rounded,
                    onTap: !canControlPlayback
                        ? null
                        : () => unawaited(
                              playbackRunning
                                  ? _pauseDeveloperPlayback()
                                  : _resumeDeveloperPlayback(),
                            ),
                  ),
                  actionButton(
                    tooltip: '상태 복사',
                    icon: Icons.content_copy_rounded,
                    onTap: () => unawaited(_copyDriveYoloRuntimeStatus()),
                  ),
                  actionButton(
                    tooltip: '선택 해제',
                    icon: Icons.close_rounded,
                    onTap: hasSelection
                        ? () => unawaited(_clearDeveloperPlaybackSelection())
                        : null,
                    destructive: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewportZoomButton(_DriveViewportZoomPreset preset) {
    final active = _viewportZoomPreset == preset;
    return Tooltip(
      message: preset.tooltip,
      child: Material(
        color: active ? const Color(0xFFE88C53) : const Color(0xCC2A1A12),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _setViewportZoomPreset(preset),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(
              preset.icon,
              size: 18,
              color: active ? Colors.white : const Color(0xFFFFB07A),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDriveViewportContentImpl(
    UiWindowInfo window,
    BoxConstraints constraints, {
    required bool isLandscapeLayout,
    required bool hideHudForTinyViewport,
  }) {
    return LayoutBuilder(
      builder: (context, viewport) {
        final effectiveSourceSize = _effectiveViewportSourceSize;
        var sourceW =
            effectiveSourceSize.width > 1 ? effectiveSourceSize.width : 1928.0;
        var sourceH = effectiveSourceSize.height > 1
            ? effectiveSourceSize.height
            : 1208.0;
        if ((sourceW - 1928.0).abs() <= 16.0 &&
            (sourceH - 1208.0).abs() <= 16.0) {
          sourceW = 1928.0;
          sourceH = 1208.0;
        }
        final vw = viewport.maxWidth;
        final vh = viewport.maxHeight;
        if (vw <= 1 || vh <= 1) {
          return const SizedBox.shrink();
        }
        final placement = _buildVideoPlacement(
          source: Size(sourceW, sourceH),
          viewport: Size(vw, vh),
          snapshot: _overlayNotifier.value,
          cameraKind: _liveCameraKind,
          coverViewport: _coverViewport,
          viewportZoom: _viewportPlacementZoom,
          openpilotTransform: _openpilotOverlayMode,
        );
        final drawW = placement.width;
        final drawH = placement.height;
        final left = placement.left;
        final top = placement.top;
        final fullSurfaceRect = Rect.fromLTWH(0.0, 0.0, drawW, drawH);
        final visibleViewportRect =
            Rect.fromLTWH(-left, -top, vw, vh).intersect(fullSurfaceRect);
        final overlayInset = switch (window.windowClass) {
          UiWindowClass.compact => 12.0,
          UiWindowClass.medium => 14.0,
          UiWindowClass.expanded => window.isLandscape ? 16.0 : 14.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 18.0,
        };
        final statusBannerMaxWidth = switch (window.windowClass) {
          UiWindowClass.compact => math.min(vw - (overlayInset * 2), 520.0),
          UiWindowClass.medium => math.min(vw * 0.72, 620.0),
          UiWindowClass.expanded => math.min(vw * 0.62, 700.0),
          UiWindowClass.large ||
          UiWindowClass.extraLarge =>
            math.min(vw * 0.52, 760.0),
        };
        final verifyPanelWidth = switch (window.windowClass) {
          UiWindowClass.compact => math.min(vw * 0.58, 420.0),
          UiWindowClass.medium => math.min(vw * 0.52, 470.0),
          UiWindowClass.expanded => math.min(vw * 0.45, 520.0),
          UiWindowClass.large ||
          UiWindowClass.extraLarge =>
            math.min(vw * 0.38, 580.0),
        };
        final statusBannerPaddingH = switch (window.windowClass) {
          UiWindowClass.compact => 10.0,
          UiWindowClass.medium => 11.0,
          UiWindowClass.expanded => 12.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 13.0,
        };
        final statusBannerPaddingV = switch (window.windowClass) {
          UiWindowClass.compact => 8.0,
          UiWindowClass.medium => 9.0,
          UiWindowClass.expanded => 10.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 11.0,
        };
        final statusBannerRadius = switch (window.windowClass) {
          UiWindowClass.compact => 10.0,
          UiWindowClass.medium => 11.0,
          UiWindowClass.expanded => 12.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 13.0,
        };
        final statusBannerTitleFont = switch (window.windowClass) {
          UiWindowClass.compact => 13.0,
          UiWindowClass.medium => 13.5,
          UiWindowClass.expanded => 14.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 14.5,
        };
        final statusBannerBodyFont = switch (window.windowClass) {
          UiWindowClass.compact => 11.0,
          UiWindowClass.medium => 11.5,
          UiWindowClass.expanded => 12.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 12.5,
        };
        final statusBannerIconSize = switch (window.windowClass) {
          UiWindowClass.compact => 16.0,
          UiWindowClass.medium => 17.0,
          UiWindowClass.expanded => 18.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 19.0,
        };
        final statusBannerGap = switch (window.windowClass) {
          UiWindowClass.compact => 6.0,
          UiWindowClass.medium => 7.0,
          UiWindowClass.expanded => 8.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 9.0,
        };
        final statusBannerProgressHeight = switch (window.windowClass) {
          UiWindowClass.compact => 2.0,
          UiWindowClass.medium => 2.5,
          UiWindowClass.expanded => 3.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 3.5,
        };
        final statusAlertPadding = switch (window.windowClass) {
          UiWindowClass.compact => 10.0,
          UiWindowClass.medium => 11.0,
          UiWindowClass.expanded => 12.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 13.0,
        };
        final centerNoticeMessage = _cameraCenterNoticeMessage();
        final hasCenterNotice = centerNoticeMessage != null;
        final drawSize = Size(drawW, drawH);
        final landscapeHudHeight = isLandscapeLayout && !hideHudForTinyViewport
            ? _computeLandscapeHudOverlayHeight(window, drawSize)
            : 0.0;
        final landscapeHudWidth = landscapeHudHeight > 0
            ? _computeLandscapeHudOverlayWidth(window, landscapeHudHeight)
            : 0.0;
        final landscapeHudLeftBound = math.max(
          overlayInset,
          vw - landscapeHudWidth - overlayInset,
        );
        final landscapeHudTopBound = math.max(
          overlayInset,
          vh - landscapeHudHeight - overlayInset,
        );
        final landscapeHudLeft = (left + overlayInset)
            .clamp(overlayInset, landscapeHudLeftBound)
            .toDouble();
        final landscapeHudTop =
            (top + drawH - landscapeHudHeight - overlayInset)
                .clamp(overlayInset, landscapeHudTopBound)
                .toDouble();
        final nativeViewportRectChanged = (_nativeOverlayVisibleViewportRect
                            .left -
                        visibleViewportRect.left)
                    .abs() >
                0.5 ||
            (_nativeOverlayVisibleViewportRect.top - visibleViewportRect.top)
                    .abs() >
                0.5 ||
            (_nativeOverlayVisibleViewportRect.width -
                        visibleViewportRect.width)
                    .abs() >
                0.5 ||
            (_nativeOverlayVisibleViewportRect.height -
                        visibleViewportRect.height)
                    .abs() >
                0.5;
        _nativeOverlayVisibleViewportRect = visibleViewportRect;
        if ((_nativeOverlaySize.width - drawW).abs() > 0.5 ||
            (_nativeOverlaySize.height - drawH).abs() > 0.5) {
          _nativeOverlaySize = drawSize;
          if (_useNativeOverlayRenderer) {
            unawaited(
              _pushNativeOverlay(
                _overlayNotifier.value,
                force: true,
              ),
            );
          }
        } else if (nativeViewportRectChanged && _useNativeOverlayRenderer) {
          unawaited(
            _pushNativeOverlay(
              _overlayNotifier.value,
              force: true,
            ),
          );
        }

        return ClipRect(
          child: Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                width: drawW,
                height: drawH,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _buildDriveCameraSurface(),
                    ),
                    if (_debugShowArOverlay &&
                        _openpilotOverlayMode &&
                        !_useNativeOverlayRenderer)
                      Positioned.fill(
                        child: ValueListenableBuilder<_DriveOverlaySnapshot>(
                          valueListenable: _overlayNotifier,
                          builder: (context, overlay, _) {
                            return IgnorePointer(
                              child: CustomPaint(
                                painter: _DriveOverlayPainter(
                                  snapshot: overlay,
                                  isConnected: _sidecarConnected,
                                  sourceSize: effectiveSourceSize,
                                  cameraKind: _liveCameraKind,
                                  coverViewport: _coverViewport,
                                  viewportZoom: _viewportPlacementZoom,
                                  visibleViewportRect: visibleViewportRect,
                                  showDebugGuides:
                                      _overlayVerifyMode && _debugShowGuides,
                                  showPathFill: _debugShowPathFill,
                                  showLaneLines: _debugShowLaneLines,
                                  showRoadEdge: _debugShowRoadEdge,
                                  showLead1: _debugShowLead1,
                                  showLead2: _debugShowLead2,
                                  showRadarBadge: _debugShowRadarBadge,
                                  showRadarVector: _debugShowRadarVector,
                                  showStopDistanceTf: _debugShowStopDistanceTf,
                                  showStateText: _debugShowStateText,
                                  showStockTopRight: _debugShowStockTopRight,
                                  showLaneMetrics: _debugShowLaneMetrics,
                                  showDebugPlot: _debugShowDebugPlot,
                                  debugPlotState: _debugPlotState,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    if (_buildLiveYoloOverlay(
                          fallbackSourceSize: effectiveSourceSize,
                        )
                        case final liveYoloOverlay?)
                      Positioned.fill(
                        child: liveYoloOverlay,
                      ),
                    if (_shouldShowCameraLoadingOverlay())
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black45,
                          child: Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      ),
                    if (hasCenterNotice)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: statusBannerMaxWidth,
                              ),
                              child: Container(
                                margin: EdgeInsets.symmetric(
                                  horizontal: overlayInset * 0.5,
                                ),
                                padding: EdgeInsets.all(statusAlertPadding),
                                decoration: BoxDecoration(
                                  color: const Color(0xCC1F1712),
                                  borderRadius: BorderRadius.circular(
                                    statusBannerRadius,
                                  ),
                                  border: Border.all(color: Colors.white24),
                                ),
                                child: Text(
                                  centerNoticeMessage,
                                  textAlign: TextAlign.center,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: statusBannerBodyFont,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (isLandscapeLayout && !hideHudForTinyViewport)
                Positioned(
                  left: landscapeHudLeft,
                  top: landscapeHudTop,
                  child: IgnorePointer(
                    child: _buildLandscapeHudOverlay(
                      window,
                      drawSize,
                      overlayHeight: landscapeHudHeight,
                      overlayWidth: landscapeHudWidth,
                    ),
                  ),
                ),
              if (_showSidecarStatusBanner)
                Positioned(
                  left: overlayInset,
                  right: overlayInset,
                  top: overlayInset,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: statusBannerMaxWidth,
                      ),
                      child: Container(
                        padding: EdgeInsets.fromLTRB(
                          statusBannerPaddingH,
                          statusBannerPaddingV,
                          statusBannerPaddingH,
                          statusBannerPaddingV,
                        ),
                        decoration: BoxDecoration(
                          color: _sidecarStatusColor(),
                          borderRadius: BorderRadius.circular(
                            statusBannerRadius,
                          ),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _sidecarStatusIcon(),
                                  color: Colors.white,
                                  size: statusBannerIconSize,
                                ),
                                SizedBox(width: statusBannerGap),
                                Expanded(
                                  child: Text(
                                    _sidecarStatusTitle(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: statusBannerTitleFont,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (_sidecarStatusDetailMessage() != null)
                              Padding(
                                padding: EdgeInsets.only(
                                  top: statusBannerGap * 0.5,
                                ),
                                child: Text(
                                  _sidecarStatusDetailMessage()!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: statusBannerBodyFont,
                                  ),
                                ),
                              ),
                            if (_isSidecarHardBusy) ...[
                              SizedBox(height: statusBannerGap),
                              ClipRRect(
                                borderRadius: const BorderRadius.all(
                                  Radius.circular(999),
                                ),
                                child: LinearProgressIndicator(
                                  minHeight: statusBannerProgressHeight,
                                  backgroundColor: const Color(0x553A4C63),
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                    Color(0xFF69C8FF),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_overlayVerifyMode &&
                  _debugShowViewportFrame &&
                  !_coverViewport)
                Positioned(
                  left: left,
                  top: top,
                  width: drawW,
                  height: drawH,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: const Color(0xFF62FF8B),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              if (_overlayVerifyMode &&
                  _debugShowVerifyPanel &&
                  _overlayVerifyText.isNotEmpty)
                Positioned(
                  top: overlayInset,
                  right: overlayInset,
                  child: IgnorePointer(
                    child: Container(
                      width: verifyPanelWidth,
                      padding: EdgeInsets.all(statusAlertPadding),
                      decoration: BoxDecoration(
                        color: const Color(0xCC1B140F),
                        borderRadius: BorderRadius.circular(statusBannerRadius),
                        border: Border.all(
                          color: const Color(0xFF9A6C4A),
                        ),
                      ),
                      child: SelectableText(
                        _overlayVerifyText,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: statusBannerBodyFont,
                          color: const Color(0xFFFFE9D2),
                          height: 1.25,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
