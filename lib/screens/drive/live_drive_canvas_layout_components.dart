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
    final dockRatio = switch (window.windowClass) {
      UiWindowClass.compact => 0.14,
      UiWindowClass.medium => 0.11,
      UiWindowClass.expanded => 0.09,
      UiWindowClass.large || UiWindowClass.extraLarge => 0.08,
    };
    final dockMin = switch (window.windowClass) {
      UiWindowClass.compact => 64.0,
      UiWindowClass.medium => 68.0,
      UiWindowClass.expanded => 72.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 76.0,
    };
    final dockMax = switch (window.windowClass) {
      UiWindowClass.compact => 104.0,
      UiWindowClass.medium => 112.0,
      UiWindowClass.expanded => 120.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 128.0,
    };

    final isLandscapeLayout = window.isLandscape;
    final dockWidth = isLandscapeLayout
        ? (constraints.maxWidth * dockRatio).clamp(dockMin, dockMax).toDouble()
        : 0.0;
    final hideHudForTinyViewport = _shouldHideHudForTinyViewport(
      window,
      constraints,
      isLandscape: isLandscapeLayout,
    );

    final mainContent = _buildDriveMainContentImpl(
      window,
      constraints,
      isLandscapeLayout: isLandscapeLayout,
      dockWidth: dockWidth,
      hideHudForTinyViewport: hideHudForTinyViewport,
    );

    final fabInset = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 14.0,
      UiWindowClass.expanded => 16.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 18.0,
    };
    final hasCenterNotice =
        _cameraCenterNoticeMessage() != null && !_debugOverlayPreviewMode;
    final hasBottomStatusBanner = !hasCenterNotice &&
        (_showSidecarStatusBanner ||
            !_hudModeLoaded ||
            (_cameraError?.isNotEmpty ?? false) ||
            _hudNoticeMessage != null);
    final fabBottom = hasBottomStatusBanner ? (fabInset + 72.0) : fabInset;
    final debugFab = FloatingActionButton.small(
      heroTag: isLandscapeLayout
          ? 'drive_debug_fab_landscape'
          : 'drive_debug_fab_portrait',
      tooltip: 'HUD 디버그',
      onPressed: _LiveDriveCanvasScreenState._temporaryLimitedHudControls
          ? null
          : _openDebugOptionsPopup,
      backgroundColor: const Color(0xCC2A1A12),
      foregroundColor: const Color(0xFFFFB07A),
      child: const Icon(Icons.tune_rounded),
    );
    final quickControls = _buildViewportZoomQuickControls(
      debugFab: debugFab,
      isLandscapeLayout: isLandscapeLayout,
    );

    if (isLandscapeLayout || hideHudForTinyViewport) {
      return Stack(
        children: [
          Positioned.fill(child: mainContent),
          if (_LiveDriveCanvasScreenState._hudDebugMenuEnabled)
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
              if (_LiveDriveCanvasScreenState._hudDebugMenuEnabled)
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
    required double dockWidth,
    required bool hideHudForTinyViewport,
  }) {
    return Row(
      children: [
        if (_LiveDriveCanvasScreenState._showDriveDock && isLandscapeLayout)
          _buildDriveDockImpl(dockWidth),
        Expanded(
          child: ColoredBox(
            color: Colors.black,
            child: _buildDriveViewportContentImpl(
              window,
              constraints,
              isLandscapeLayout: isLandscapeLayout,
              hideHudForTinyViewport: hideHudForTinyViewport,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildViewportZoomQuickControls({
    required Widget debugFab,
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
        debugFab,
      ],
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

  Widget _buildDriveDockImpl(double dockWidth) {
    return Container(
      width: dockWidth,
      decoration: const BoxDecoration(
        color: Color(0xFF11141A),
        border: Border(
          right: BorderSide(color: Colors.white24),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          IconButton(
            onPressed: _exitScreen,
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: '뒤로가기',
          ),
          const SizedBox(height: 6),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _sidecarConnected
                  ? const Color(0xFF24FF67)
                  : const Color(0xFFFF4C4C),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(
                children: [
                  if (_LiveDriveCanvasScreenState._hudDebugMenuEnabled)
                    IconButton(
                      onPressed: _LiveDriveCanvasScreenState
                              ._temporaryLimitedHudControls
                          ? null
                          : _openDebugOptionsPopup,
                      icon: const Icon(
                        Icons.tune,
                        color: Color(0xFF8FE7FF),
                      ),
                      tooltip: '디버그 옵션',
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
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
        var sourceW =
            _cameraSourceSize.width > 1 ? _cameraSourceSize.width : 1928.0;
        var sourceH =
            _cameraSourceSize.height > 1 ? _cameraSourceSize.height : 1208.0;
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
        final overlayBottomInset = switch (window.windowClass) {
          UiWindowClass.compact => 12.0,
          UiWindowClass.medium => 14.0,
          UiWindowClass.expanded => 16.0,
          UiWindowClass.large || UiWindowClass.extraLarge => 18.0,
        };
        final statusBannerMaxWidth = switch (window.windowClass) {
          UiWindowClass.compact => math.min(vw - (overlayInset * 2), 520.0),
          UiWindowClass.medium => math.min(vw * 0.72, 620.0),
          UiWindowClass.expanded => math.min(vw * 0.62, 700.0),
          UiWindowClass.large || UiWindowClass.extraLarge =>
            math.min(vw * 0.52, 760.0),
        };
        final verifyPanelWidth = switch (window.windowClass) {
          UiWindowClass.compact => math.min(vw * 0.58, 420.0),
          UiWindowClass.medium => math.min(vw * 0.52, 470.0),
          UiWindowClass.expanded => math.min(vw * 0.45, 520.0),
          UiWindowClass.large || UiWindowClass.extraLarge =>
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
        final hasCenterNotice =
            centerNoticeMessage != null && !_debugOverlayPreviewMode;
        final showBottomStatusBanners = !hasCenterNotice;
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
        final nativeViewportRectChanged =
            (_nativeOverlayVisibleViewportRect.left - visibleViewportRect.left)
                    .abs() >
                0.5 ||
            (_nativeOverlayVisibleViewportRect.top - visibleViewportRect.top)
                    .abs() >
                0.5 ||
            (_nativeOverlayVisibleViewportRect.width - visibleViewportRect.width)
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
                        ((_openpilotOverlayMode &&
                                !_useNativeOverlayRenderer) ||
                            _debugOverlayPreviewMode))
                      Positioned.fill(
                        child: ValueListenableBuilder<_DriveOverlaySnapshot>(
                          valueListenable: _overlayNotifier,
                          builder: (context, overlay, _) {
                            return IgnorePointer(
                              child: CustomPaint(
                                painter: _DriveOverlayPainter(
                                  snapshot: overlay,
                                  isConnected: _sidecarConnected,
                                  sourceSize: _cameraSourceSize,
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
                                  debugPlotState: _debugPlotState,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    if (_cameraLoading && !_debugOverlayPreviewMode)
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
              Positioned(
                top: overlayInset * 0.7,
                left: overlayInset,
                right: overlayInset,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: _buildSidecarRevisionBadge(window),
                ),
              ),
              Positioned(
                top: overlayInset * 0.7,
                right: overlayInset * 0.7,
                child: _buildDriveModeTag(window),
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
              if (showBottomStatusBanners && _showSidecarStatusBanner)
                Positioned(
                  left: overlayInset,
                  right: overlayInset,
                  bottom: overlayBottomInset,
                  child: Align(
                    alignment: Alignment.bottomCenter,
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
                                  _sidecarPhase == _SidecarPhase.failed
                                      ? Icons.error_outline
                                      : (_sidecarPhase ==
                                              _SidecarPhase.stopping
                                          ? Icons.stop_circle_outlined
                                          : (_sidecarPhase ==
                                                  _SidecarPhase.running
                                              ? Icons.check_circle_outline
                                              : Icons.hourglass_top_rounded)),
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
                            if (_sidecarPhase == _SidecarPhase.failed &&
                                (_sidecarPhaseMessage ?? '').trim().isNotEmpty)
                              Padding(
                                padding: EdgeInsets.only(
                                  top: statusBannerGap * 0.5,
                                ),
                                child: Text(
                                  _sidecarPhaseMessage!.trim(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: statusBannerBodyFont,
                                  ),
                                ),
                              ),
                            if (_isSidecarBusy) ...[
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
                )
              else if (showBottomStatusBanners && !_hudModeLoaded)
                Positioned(
                  left: overlayInset,
                  right: overlayInset,
                  bottom: overlayBottomInset,
                  child: Container(
                    padding: EdgeInsets.all(statusAlertPadding),
                    decoration: BoxDecoration(
                      color: const Color(0xCC1F1712),
                      borderRadius: BorderRadius.circular(statusBannerRadius),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Text(
                      'HUD 모드 설정을 불러오는 중...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: statusBannerBodyFont,
                      ),
                    ),
                  ),
                )
              else if (showBottomStatusBanners &&
                  _cameraError != null &&
                  !_debugOverlayPreviewMode)
                Positioned(
                  left: overlayInset,
                  right: overlayInset,
                  bottom: overlayBottomInset,
                  child: Container(
                    padding: EdgeInsets.all(statusAlertPadding),
                    decoration: BoxDecoration(
                      color: const Color(0xCC7A1010),
                      borderRadius: BorderRadius.circular(statusBannerRadius),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Text(
                      _cameraError!,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: statusBannerBodyFont,
                      ),
                    ),
                  ),
                )
              else if (showBottomStatusBanners && _hudNoticeMessage != null)
                Positioned(
                  left: overlayInset,
                  right: overlayInset,
                  bottom: overlayBottomInset,
                  child: Container(
                    padding: EdgeInsets.all(statusAlertPadding),
                    decoration: BoxDecoration(
                      color: _hudNoticeIsError
                          ? const Color(0xCC7A1010)
                          : const Color(0xCC1F1712),
                      borderRadius: BorderRadius.circular(statusBannerRadius),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Text(
                      _hudNoticeMessage!,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: statusBannerBodyFont,
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
