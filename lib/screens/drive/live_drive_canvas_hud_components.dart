part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasHudComponents on _LiveDriveCanvasScreenState {
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
    if (_openpilotOverlayMode && !_sidecarConnected) {
      return const ColoredBox(color: Colors.black);
    }
    if (_useNativeLiveCamera) {
      return AndroidView(
        key: ValueKey<String>(
          'native-live-${widget.hostIp}-$_liveCameraName',
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
    final scheme = Theme.of(context).colorScheme;
    final fontSize = switch (window.windowClass) {
      UiWindowClass.compact => 20.0,
      UiWindowClass.medium => 22.0,
      UiWindowClass.expanded => 23.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 24.0,
    };
    final horizontalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 16.0,
      UiWindowClass.medium => 18.0,
      UiWindowClass.expanded => 20.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 22.0,
    };
    final verticalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 10.0,
      UiWindowClass.expanded => 11.0,
      UiWindowClass.large || UiWindowClass.extraLarge => 12.0,
    };
    final label = _modeTagLabel;
    final isOpenpilot = label == 'openpilot';
    final tagBorderColor = scheme.primary.withValues(
      alpha: isOpenpilot ? 0.95 : 0.72,
    );
    final tagFillColor = isOpenpilot
        ? scheme.primary.withValues(alpha: 0.24)
        : Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.16),
            scheme.surfaceContainerHighest.withValues(alpha: 0.72),
          );
    final tagTextColor =
        isOpenpilot ? scheme.primary : scheme.onSurface.withValues(alpha: 0.94);

    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tagFillColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: tagBorderColor.withValues(alpha: 0.95),
            width: 1.4,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x4D000000),
              blurRadius: 10,
              offset: Offset(0, 4),
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
              letterSpacing: 0.35,
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
    final aspect = height / math.max(1.0, width);
    var ratio = switch (window.windowClass) {
      UiWindowClass.compact => 0.365,
      UiWindowClass.medium => 0.35,
      UiWindowClass.expanded => 0.338,
      UiWindowClass.large => 0.328,
      UiWindowClass.extraLarge => 0.32,
    };

    if (aspect >= 2.05) {
      ratio += 0.015;
    } else if (aspect >= 1.9) {
      ratio += 0.008;
    } else if (aspect <= 1.55) {
      ratio -= 0.02;
    } else if (aspect <= 1.7) {
      ratio -= 0.012;
    }

    if (window.shortestSide >= 720) {
      ratio -= 0.01;
    } else if (window.shortestSide <= 380) {
      ratio += 0.01;
    }

    final minHeight = switch (window.windowClass) {
      UiWindowClass.compact => 200.0,
      UiWindowClass.medium => 212.0,
      UiWindowClass.expanded => 224.0,
      UiWindowClass.large => 234.0,
      UiWindowClass.extraLarge => 244.0,
    };
    final maxHeight = switch (window.windowClass) {
      UiWindowClass.compact => math.min(460.0, height * 0.44),
      UiWindowClass.medium => math.min(470.0, height * 0.43),
      UiWindowClass.expanded => math.min(480.0, height * 0.42),
      UiWindowClass.large => math.min(500.0, height * 0.41),
      UiWindowClass.extraLarge => math.min(520.0, height * 0.4),
    };

    return (height * ratio).clamp(minHeight, maxHeight).toDouble();
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
        child: HomeHudPreviewCard(
          deviceIp: widget.hostIp,
          enabled: true,
          fillParent: true,
          key: ValueKey<String>(
              'drive_hud_panel_${window.windowClass.name}_${widget.hostIp}'),
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

  double _computeLandscapeHudOverlaySizeImpl(UiWindowInfo window, Size drawSize) {
    final base = math.min(drawSize.width, drawSize.height);
    final ratio = switch (window.windowClass) {
      UiWindowClass.compact => 0.305,
      UiWindowClass.medium => 0.29,
      UiWindowClass.expanded => 0.275,
      UiWindowClass.large => 0.262,
      UiWindowClass.extraLarge => 0.25,
    };
    final minSize = switch (window.windowClass) {
      UiWindowClass.compact => 182.0,
      UiWindowClass.medium => 198.0,
      UiWindowClass.expanded => 214.0,
      UiWindowClass.large => 230.0,
      UiWindowClass.extraLarge => 246.0,
    };
    final maxSize = switch (window.windowClass) {
      UiWindowClass.compact => 352.0,
      UiWindowClass.medium => 376.0,
      UiWindowClass.expanded => 404.0,
      UiWindowClass.large => 432.0,
      UiWindowClass.extraLarge => 460.0,
    };
    final viewportCap = drawSize.height * 0.48;
    final upperBound = math.max(minSize, math.min(maxSize, viewportCap));
    return (base * ratio).clamp(minSize, upperBound).toDouble();
  }

  Widget _buildLandscapeHudOverlayImpl(
    UiWindowInfo window,
    Size drawSize, {
    double? overlaySize,
  }) {
    final size =
        overlaySize ?? _computeLandscapeHudOverlaySize(window, drawSize);
    return Opacity(
      opacity: 0.8,
      child: SizedBox(
        width: size,
        height: size,
        child: HomeHudPreviewCard(
          deviceIp: widget.hostIp,
          enabled: true,
          fillParent: true,
          key: ValueKey<String>(
            'drive_hud_overlay_${window.windowClass.name}_${widget.hostIp}',
          ),
        ),
      ),
    );
  }

}
