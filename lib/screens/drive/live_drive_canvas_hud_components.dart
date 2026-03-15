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
    if (_openpilotOverlayMode) {
      unawaited(_primeSidecarFlavorHints());
    }
  }

  Widget _buildDriveCameraSurfaceImpl() {
    if (_isDeveloperPlaybackRequested) {
      return _buildDeveloperPlaybackSurface();
    }
    if (_cameraSuspendedByLifecycle) {
      return const ColoredBox(color: Colors.black);
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
    if (_openpilotOverlayMode && !_nativeCameraAttachReady) {
      return const ColoredBox(color: Colors.black);
    }
    return WebViewWidget(controller: _cameraController);
  }

  String? _cameraCenterNoticeMessageImpl() {
    if (_isDeveloperPlaybackRequested) {
      if (_developerPlaybackLoading) {
        return '재생 영상 로드 중입니다.';
      }
      final error = _developerPlaybackError?.trim();
      if (error != null && error.isNotEmpty) {
        return error;
      }
      return null;
    }
    if (!_hudModeLoaded) return 'HUD 모드 설정을 불러오는 중입니다.';
    if (_openpilotOverlayMode && !_sidecarConnected) {
      return '사이드카 연결 대기 중입니다.';
    }
    if (_openpilotOverlayMode &&
        _profileRequiresLiveRuntime(_currentSidecarProfile) &&
        !_nativeCameraAttachReady) {
      return '카메라/그래픽 연결 대기 중입니다.';
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
    return AdaptiveHudHost(
      deviceIp: _hostIp,
      enabled: true,
      surface: HudSurfaceVariant.driveInline,
      fillParent: true,
      edgeToEdge: true,
      syncNativeOverlay: true,
      key: ValueKey<String>(
        'drive_hud_panel_${window.windowClass.name}_$_hostIp',
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
