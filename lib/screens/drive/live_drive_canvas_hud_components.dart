part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasHudComponents on _LiveDriveCanvasScreenState {
  double _hudPreferredAspectRatioForWindowImpl(
    UiWindowInfo window, {
    required bool wide,
  }) {
    return switch (window.windowClass) {
      UiWindowClass.compact => wide ? 1.24 : 0.92,
      UiWindowClass.medium => wide ? 1.30 : 0.96,
      UiWindowClass.expanded => wide ? 1.36 : 1.00,
      UiWindowClass.large => wide ? 1.42 : 1.04,
      UiWindowClass.extraLarge => wide ? 1.46 : 1.06,
    };
  }

  Future<void> _loadHudDefaultModeImpl() async {
    final mode = await HudDriveSettingsService.getDefaultMode();
    if (!mounted) return;
    _safeSetState(() {
      _hudDefaultMode = mode;
      _hudModeLoaded = true;
    });
    _applyHudModeRuntime();
  }

  Widget _buildDriveCameraSurfaceImpl() {
    if (_cameraSuspendedByLifecycle) {
      return const ColoredBox(color: Colors.black);
    }
    if (_debugOverlayPreviewMode) {
      return _buildOverlayPreviewBackdrop();
    }
    if (!_hudModeLoaded) {
      return const ColoredBox(color: Colors.black);
    }
    if (_useNativeLiveCamera) {
      return AndroidView(
        key: ValueKey<String>(
          'native-live-$_hostIp-$_liveCameraName',
        ),
        viewType: 'carrotlink/native_drive_video',
        creationParams: <String, dynamic>{
          'wsUrl': _liveCameraWsUrl,
        },
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: (viewId) {
          if (!mounted) {
            return;
          }
          _safeSetState(() {
            _nativeCameraViewId = viewId;
            _cameraLoading = true;
            _cameraError = null;
          });
          if (_useNativeOverlayRenderer) {
            unawaited(
              _pushNativeOverlay(
                _overlayNotifier.value,
                force: true,
              ),
            );
          }
          unawaited(_pushNativeYoloConfig(force: true));
        },
      );
    }
    return WebViewWidget(controller: _cameraController);
  }

  String? _cameraCenterNoticeMessageImpl() {
    if (_debugOverlayPreviewMode) return null;
    if (!_hudModeLoaded) return 'HUD 모드 설정을 불러오는 중입니다.';
    if (_openpilotOverlayMode && !_sidecarConnected) {
      return '사이드카 연결 대기 중입니다.';
    }
    final err = _cameraError?.trim();
    if (err != null && err.isNotEmpty) {
      return err;
    }
    final notice = _hudNoticeMessage?.trim();
    if (notice != null && notice.isNotEmpty) {
      return notice;
    }
    if (_openpilotOverlayMode &&
        !_cameraLoading &&
        _lastCameraFrameId == null) {
      return '로드카메라 프레임 대기 중입니다.';
    }
    return null;
  }

  Widget _buildDriveModeTagImpl(UiWindowInfo window) {
    final fontSize = switch (window.windowClass) {
      UiWindowClass.compact => 11.0,
      UiWindowClass.medium => 11.5,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 12.5,
    };
    final horizontalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 10.0,
      UiWindowClass.medium => 11.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 13.0,
    };
    final verticalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 5.0,
      UiWindowClass.medium => 5.5,
      UiWindowClass.expanded => 6.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 6.5,
    };
    final label = _modeTagLabel;
    final isOpenpilot = _openpilotOverlayMode;
    final tagBorderColor = isOpenpilot ? _debugSelectedBorder : Colors.white12;
    final tagFillColor = isOpenpilot ? _debugSelectedBg : _debugNavBg;
    const tagTextColor = Colors.white;

    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tagFillColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: tagBorderColor,
            width: 1.0,
          ),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 8,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: tagTextColor,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.15,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidecarRevisionBadgeImpl(UiWindowInfo window) {
    if (!_openpilotOverlayMode) {
      return const SizedBox.shrink();
    }
    final pyName = _sidecarRemotePyName;
    final revision = _sidecarRemoteRevisionLabel;
    final updated = _sidecarRemoteUpdatedLabel;
    final procStatus = _sidecarProcessStatusLabel;
    final camStatus = _sidecarCameraReadyLabel;
    final fpsLabel = _overlayDebugFps.toStringAsFixed(1);
    final ageLabel = _sidecarCameraAgeLabel;
    final titleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 10.0,
      UiWindowClass.medium => 10.5,
      UiWindowClass.expanded => 11.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 11.5,
    };
    final bodyFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 9.0,
      UiWindowClass.medium => 9.5,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 10.5,
    };
    final metaFontSize = bodyFontSize - 0.2;
    final collapsed = !_sidecarRevisionBadgeExpanded;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: collapsed
          ? Material(
              key: const ValueKey<String>('sidecar-badge-collapsed'),
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => _safeSetState(
                  () => _sidecarRevisionBadgeExpanded = true,
                ),
                child: Ink(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: _debugCardBg.withValues(alpha: 0.90),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white12),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.memory_rounded,
                    size: 18,
                    color: Colors.white70,
                  ),
                ),
              ),
            )
          : Material(
              key: const ValueKey<String>('sidecar-badge-expanded'),
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _safeSetState(
                  () => _sidecarRevisionBadgeExpanded = false,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _debugCardBg.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            pyName,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: titleFontSize,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.1,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'sha $revision · $updated',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: bodyFontSize,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.05,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            'proc $procStatus · cam $camStatus',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: metaFontSize,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.04,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            'fps $fpsLabel · age $ageLabel',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: metaFontSize,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.04,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  double _computePortraitHudHeightImpl(
      UiWindowInfo window, BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final horizontalInset = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 14.0,
      UiWindowClass.expanded => 16.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 18.0,
    };
    final usableWidth = math.max(1.0, width - (horizontalInset * 2));
    final aspectRatio = _hudPreferredAspectRatioForWindow(window, wide: true);
    final desiredHeight = usableWidth / aspectRatio;

    final minHeight = switch (window.windowClass) {
      UiWindowClass.compact => 190.0,
      UiWindowClass.medium => 204.0,
      UiWindowClass.expanded => 216.0,
      UiWindowClass.large => 228.0,
      UiWindowClass.extraLarge => 236.0,
    };
    final maxHeight = switch (window.windowClass) {
      UiWindowClass.compact => math.min(430.0, height * 0.42),
      UiWindowClass.medium => math.min(450.0, height * 0.41),
      UiWindowClass.expanded => math.min(470.0, height * 0.4),
      UiWindowClass.large => math.min(490.0, height * 0.39),
      UiWindowClass.extraLarge => math.min(510.0, height * 0.38),
    };

    return desiredHeight.clamp(minHeight, maxHeight).toDouble();
  }

  Widget _buildPortraitHudPanelImpl(UiWindowInfo window) {
    final panelPadding = switch (window.windowClass) {
      UiWindowClass.compact => 6.0,
      UiWindowClass.medium => 8.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 12.0,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E16),
        border:
            Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.2))),
      ),
      child: Padding(
        padding:
            EdgeInsets.fromLTRB(panelPadding, panelPadding, panelPadding, 0),
        child: AdaptiveHudHost(
          deviceIp: _hostIp,
          enabled: true,
          surface: HudSurfaceVariant.driveInline,
          fillParent: true,
          syncNativeOverlay: true,
          key: ValueKey<String>(
              'drive_hud_panel_${window.windowClass.name}_$_hostIp'),
        ),
      ),
    );
  }

  bool _shouldHideHudForTinyViewportImpl(
    UiWindowInfo window,
    BoxConstraints constraints, {
    required bool isLandscape,
  }) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final shortest = math.min(width, height);

    // Hide HUD only for truly tiny multi-window cases.
    // Full-screen compact portrait must keep HUD visible.
    if (shortest < 300) {
      return true;
    }
    if (height < 300) {
      return true;
    }
    if (isLandscape && width < 560) {
      return true;
    }
    if (!isLandscape && height < 560 && width < 430) {
      return true;
    }
    if (!isLandscape && window.windowClass != UiWindowClass.compact) {
      return false;
    }
    if (isLandscape && height < 360) {
      return true;
    }
    return false;
  }

  double _computeLandscapeHudOverlayHeightImpl(
    UiWindowInfo window,
    Size drawSize,
  ) {
    final base = math.min(drawSize.width, drawSize.height);
    final ratio = switch (window.windowClass) {
      UiWindowClass.compact => 0.30,
      UiWindowClass.medium => 0.29,
      UiWindowClass.expanded => 0.28,
      UiWindowClass.large => 0.27,
      UiWindowClass.extraLarge => 0.26,
    };
    final minSize = switch (window.windowClass) {
      UiWindowClass.compact => 184.0,
      UiWindowClass.medium => 196.0,
      UiWindowClass.expanded => 208.0,
      UiWindowClass.large => 220.0,
      UiWindowClass.extraLarge => 232.0,
    };
    final maxSize = switch (window.windowClass) {
      UiWindowClass.compact => 304.0,
      UiWindowClass.medium => 324.0,
      UiWindowClass.expanded => 344.0,
      UiWindowClass.large => 364.0,
      UiWindowClass.extraLarge => 384.0,
    };
    final viewportCap = drawSize.height * 0.44;
    final upperBound = math.max(minSize, math.min(maxSize, viewportCap));
    return (base * ratio).clamp(minSize, upperBound).toDouble();
  }

  double _computeLandscapeHudOverlayWidthImpl(
    UiWindowInfo window,
    double overlayHeight,
  ) {
    return overlayHeight *
        _hudPreferredAspectRatioForWindow(window, wide: true);
  }

  Widget _buildLandscapeHudOverlayImpl(
    UiWindowInfo window,
    Size drawSize, {
    double? overlayHeight,
    double? overlayWidth,
  }) {
    final height =
        overlayHeight ?? _computeLandscapeHudOverlayHeight(window, drawSize);
    final width =
        overlayWidth ?? _computeLandscapeHudOverlayWidth(window, height);
    return Opacity(
      opacity: 0.8,
      child: SizedBox(
        width: width,
        height: height,
        child: AdaptiveHudHost(
          deviceIp: _hostIp,
          enabled: true,
          surface: HudSurfaceVariant.driveOverlay,
          fillParent: true,
          syncNativeOverlay: true,
          key: ValueKey<String>(
            'drive_hud_overlay_${window.windowClass.name}_$_hostIp',
          ),
        ),
      ),
    );
  }
}
