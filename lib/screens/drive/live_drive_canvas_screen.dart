import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/hud_drive_settings_service.dart';
import '../../services/hud_feature_settings_service.dart';

import '../../services/sidecar_service.dart';
import '../../services/ssh_service.dart';
import '../../services/storage_layout_service.dart';
import '../../features/yolo/yolo.dart';
import '../../ui/adaptive/display_feature_utils.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../features/hud/hud.dart';

part 'live_drive_canvas_overlay_components.dart';
part 'live_drive_canvas_overlay_models_components.dart';
part 'live_drive_canvas_ar_scene_components.dart';
part 'live_drive_canvas_ar_replay_components.dart';
part 'live_drive_canvas_plot_models_components.dart';
part 'live_drive_canvas_plot_components.dart';
part 'live_drive_canvas_overlay_math_components.dart';
part 'live_drive_canvas_debug_components.dart';
part 'live_drive_canvas_debug_actions_components.dart';
part 'live_drive_canvas_debug_popup_components.dart';
part 'live_drive_canvas_debug_popup_widgets_components.dart';
part 'live_drive_canvas_hud_components.dart';
part 'live_drive_canvas_overlay_sync_components.dart';
part 'live_drive_canvas_overlay_preview_components.dart';
part 'live_drive_canvas_camera_components.dart';
part 'live_drive_canvas_camera_html_components.dart';
part 'live_drive_canvas_camera_diag_components.dart';
part 'live_drive_canvas_sidecar_components.dart';
part 'live_drive_canvas_sidecar_bootstrap_components.dart';
part 'live_drive_canvas_sidecar_transport_components.dart';
part 'live_drive_canvas_sidecar_runtime_components.dart';
part 'live_drive_canvas_lifecycle_components.dart';
part 'live_drive_canvas_layout_components.dart';

enum _DriveCameraKind { road, wideRoad }

enum _SidecarPhase {
  idle,
  deploying,
  starting,
  verifying,
  running,
  stopping,
  failed
}

enum _AdaptiveCameraQualityMode {
  lowLatency,
}

enum _OverlayPreviewScenario {
  highwayStraight,
  gentleLeft,
  gentleRight,
  traffic,
}

enum _DriveViewportZoomPreset {
  zoomOut,
  fit,
  crop,
}

extension _DriveViewportZoomPresetX on _DriveViewportZoomPreset {
  bool get coverPreferred => switch (this) {
        _DriveViewportZoomPreset.zoomOut ||
        _DriveViewportZoomPreset.fit =>
          false,
        _DriveViewportZoomPreset.crop => true,
      };

  double get zoomFactor => switch (this) {
        _DriveViewportZoomPreset.zoomOut => 0.92,
        _DriveViewportZoomPreset.fit => 1.0,
        _DriveViewportZoomPreset.crop => 1.0,
      };

  IconData get icon => switch (this) {
        _DriveViewportZoomPreset.zoomOut => Icons.zoom_out_map_rounded,
        _DriveViewportZoomPreset.fit => Icons.fit_screen_rounded,
        _DriveViewportZoomPreset.crop => Icons.crop_free_rounded,
      };

  String get tooltip => switch (this) {
        _DriveViewportZoomPreset.zoomOut => '축소',
        _DriveViewportZoomPreset.fit => '정사이즈',
        _DriveViewportZoomPreset.crop => '크롭',
      };
}

class LiveDriveCanvasScreen extends StatefulWidget {
  final String hostIp;

  const LiveDriveCanvasScreen({
    super.key,
    required this.hostIp,
  });

  @override
  State<LiveDriveCanvasScreen> createState() => _LiveDriveCanvasScreenState();
}

class _LiveDriveCanvasScreenState extends State<LiveDriveCanvasScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const EventChannel _nativeCameraEventChannel =
      EventChannel('carrotlink/native_drive_video_events');
  static const MethodChannel _nativeCameraControlChannel =
      MethodChannel('carrotlink/native_drive_video_control');
  static const MethodChannel _displayTuningChannel =
      MethodChannel('carrotlink/display_tuning');
  static const bool _hudDebugMenuEnabled = true;
  static const bool _temporaryLimitedHudControls = false;
  static const bool _showDriveDock = false;
  static const bool _webCameraSharpenEnabled = true;
  // Sidecar is treated as an externally managed resident process on comma.
  static const bool _residentSidecarManaged = true;
  static const bool _autoDeployDuringHudRuntime = false;
  static const String _sidecarBootstrapDonePrefKey =
      'sidecar_bootstrap_done_v1';
  static const String _sidecarRevisionNotifiedPrefKey =
      'sidecar_revision_notified_v1';
  static const String _hudDebugLayerTogglesPrefKey =
      'hud_debug_layer_toggles_v5';
  static const String _hudDebugLayerTogglesInitPrefKey =
      'hud_debug_layer_toggles_init_v5';
  static const String _viewportZoomPresetPortraitPrefKey =
      'drive_viewport_zoom_preset_portrait_v1';
  static const String _viewportZoomPresetLandscapePrefKey =
      'drive_viewport_zoom_preset_landscape_v1';
  static const _M3 _viewFromDevice = _M3(
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    1.0,
    1.0,
    0.0,
    0.0,
  );

  late final WebViewController _cameraController;
  final SidecarService _sidecarService = SidecarService.shared;

  SSHService? _sshService;
  bool _driveFeatureGuardHandled = false;
  SSHService? _observedSshService;
  SharedRuntimeManager? _sharedRuntimeManager;
  late String _activeHostIp;
  bool _lastObservedSshConnected = false;
  String? _lastObservedConnectedHost;
  bool _cameraLoading = true;
  String? _cameraError;
  String? _cameraSourceKey;
  bool _nativeCameraAttachReady = false;
  Size _cameraSourceSize = const Size(1928, 1208);
  final Map<_DriveCameraKind, Size> _sourceSizeByKind =
      <_DriveCameraKind, Size>{
    _DriveCameraKind.road: const Size(1928, 1208),
    _DriveCameraKind.wideRoad: const Size(1928, 1208),
  };
  StreamSubscription<dynamic>? _nativeCameraEventSub;
  int? _nativeCameraViewId;
  bool _nativeCameraUnsupported = false;
  bool _isDisposing = false;
  final bool _nativeOverlayEnabled = true;
  Size _nativeOverlaySize = Size.zero;
  Rect _nativeOverlayVisibleViewportRect = Rect.zero;
  int _lastNativeOverlayPushUs = 0;
  static const int _nativeOverlayPushIntervalUs = 16666;

  bool _sidecarConnected = false;
  bool _sidecarAutoManaging = false;
  bool _sidecarTransitioning = false;
  bool _suppressCameraErrors = false;
  Timer? _sidecarTransitionTimer;
  Timer? _sidecarRecoveryTimer;
  Timer? _overlayDisconnectDebounce;
  DateTime? _sidecarRecoveryNextAt;
  int _sidecarRecoveryBackoffSeconds = 1;
  _SidecarPhase _sidecarPhase = _SidecarPhase.idle;
  String? _sidecarPhaseMessage;
  String? _hudNoticeMessage;
  bool _hudNoticeIsError = false;
  Timer? _hudNoticeTimer;
  _DriveCameraKind _liveCameraKind = _DriveCameraKind.road;
  bool _wideCamRequested = false;
  int _overlayDiagFrames = 0;
  DateTime _overlayDiagLastLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<int, _DriveOverlaySnapshot> _overlayByModelFrame =
      <int, _DriveOverlaySnapshot>{};
  final ListQueue<int> _overlayFrameOrder = ListQueue<int>();
  static const int _overlayFrameBufferSize = 220;
  static const int _overlaySyncMaxDeltaLive = 8;
  static const bool _strictFrameLock = true;
  static const int _strictFrameHoldUs = 120000;
  static const int _cameraFrameStaleUs = 350000;
  static const int _startupProvisionalSyncWindowUs = 4000000;
  static const int _startupProvisionalNativeSettleFrames = 3;
  static const int _interpMinUs = 12000;
  static const int _interpMaxUs = 90000;
  static const Duration _cameraDiagCaptureCooldown = Duration(seconds: 12);
  static const Duration _lifecycleSuspendDelay = Duration(milliseconds: 3200);
  static const Duration _sidecarWarmProcessKeepAlive = Duration(seconds: 35);
  static const Duration _backgroundProcessKeepAlive = Duration(seconds: 45);
  static const Duration _backgroundUiResetGrace = Duration(seconds: 15);
  static const String _cameraDiagTmuxTailCommand = '''
if command -v tmux >/dev/null 2>&1; then
  echo "== tmux sessions =="
  tmux ls 2>&1 || true
  echo
  if tmux has-session -t comma 2>/dev/null; then
    echo "== comma:0.0 recent output (last 300 lines) =="
    tmux capture-pane -pt comma:0.0 -S -300 2>&1 || true
  else
    echo "comma session not found"
  fi
else
  echo "tmux not installed"
fi
''';
  bool _cameraSuspendedByLifecycle = false;
  bool _cameraDiagCaptureInFlight = false;
  DateTime? _lastCameraDiagCapturedAt;
  int? _lastCameraFrameId;
  int _lastCameraFrameEventUs = 0;
  int _cameraErrorGraceUntilUs = 0;
  int? _lastPublishedModelFrameId;
  int _lastSyncHitUs = 0;
  int _lastOverlayPublishUs = 0;
  int _lastSyncedArrivalUs = 0;
  double _smoothedSyncIntervalUs = 50000.0;
  late final Stopwatch _renderClock;
  Ticker? _renderTicker;
  _DriveOverlaySnapshot _renderFromSnapshot =
      const _DriveOverlaySnapshot.empty();
  _DriveOverlaySnapshot _renderToSnapshot = const _DriveOverlaySnapshot.empty();
  int _renderInterpStartUs = 0;
  int _renderInterpDurationUs = 50000;
  bool _renderInterpActive = false;
  _DriveOverlaySnapshot _latestOverlaySnapshot =
      const _DriveOverlaySnapshot.empty();
  double _pathAnimationPhase = 0.0;
  int _pathAnimationSeq2 = -1;
  bool _pathAnimationForward = true;
  int _lastPathAnimationTickUs = 0;
  int? _lastNativeOverlaySignature;
  bool _lastNativeOverlayHadPayload = false;
  int? _lastNativeArSceneSignature;
  bool _lastNativeArSceneHadPayload = false;
  int? _lastNativeYoloConfigSignature;
  Map<String, dynamic>? _lastNativeYoloState;
  bool _overlayVerifyMode = false;
  String _overlayVerifyText = '';
  int _lastOverlayVerifyUpdateUs = 0;
  static const int _overlayVerifyIntervalUs = 200000;
  _DriveViewportZoomPreset _viewportZoomPreset = _DriveViewportZoomPreset.crop;
  bool? _lastViewportZoomOrientationLandscape;
  bool _debugShowGuides = false;
  bool _debugShowVerifyPanel = false;
  bool _debugShowViewportFrame = false;
  // AR debug overlay defaults:
  // - Core AR/lead/radar layers stay enabled by default.
  // - Native AR scene, autosave, and YOLO overlays stay off by default.
  bool _debugShowArOverlay = true;
  bool _debugShowPathFill = true;
  bool _debugShowLaneLines = true;
  bool _debugShowRoadEdge = true;
  bool _debugShowLead1 = true;
  bool _debugShowLead2 = true;
  bool _debugShowRadarBadge = true;
  bool _debugShowRadarVector = true;
  bool _debugShowStopDistanceTf = true;
  bool _debugShowStateText = true;
  bool _debugYoloEnabled = false;
  bool _debugYoloBoxes = false;
  bool _debugYoloLabels = false;
  bool _debugYoloTrafficLights = false;
  bool _debugYoloStats = false;
  bool _debugPushNativeArScene = false;
  bool _debugArCaptureEnabled = false;
  bool _debugArAutoPersistEnabled = false;
  bool _debugArReplayMode = false;
  _DriveArReplayFrame? _activeArReplayFrame;
  final ListQueue<_DriveArReplayFrame> _arReplayFrames =
      ListQueue<_DriveArReplayFrame>();
  int _arReplayCaptureSeq = 0;
  int _lastArReplayCaptureUs = 0;
  int _lastArReplayPersistUs = 0;
  static const int _arReplayCaptureIntervalUs = 250000;
  static const int _arReplayPersistIntervalUs = 1500000;
  static const int _arReplayMaxFrames = 96;
  String? _lastArReplayExportPath;
  String? _arReplaySessionId;
  String? _arReplaySessionDirPath;
  String? _arReplaySessionTimelinePath;
  String? _arReplaySessionMetaPath;
  int _lastPersistedArReplaySeq = 0;
  Map<String, String> _sidecarProcessSnapshot = <String, String>{};
  Map<String, String> _sidecarCriticalProcSnapshot = <String, String>{};
  Map<String, dynamic> _sidecarHealthSnapshot = <String, dynamic>{};
  Map<String, dynamic> _sidecarProfileSnapshot = <String, dynamic>{};
  Map<String, dynamic> _sidecarCameraQualitySnapshot = <String, dynamic>{};
  DateTime? _sidecarProcessCheckedAt;
  DateTime? _sidecarLastDeployAt;
  DateTime? _sidecarLastStartAt;
  DateTime? _sidecarLastStopAt;
  DateTime? _sidecarLastRevisionCheckedAt;
  DateTime? _sidecarLastFrameAt;
  String _sidecarLastDeployResult = '-';
  String? _sidecarLocalRevision;
  String? _sidecarRemoteRevision;
  String _sidecarRevisionAction = '-';
  DateTime? _sidecarLastBootstrapAt;
  String _sidecarLastBootstrapResult = '-';
  String _sidecarLastBootstrapDetail = '-';
  String? _sidecarProcessStatusError;
  DateTime? _sidecarScheduledStopAt;
  String? _sidecarScheduledStopReason;
  int _overlayDebugWindowStartMs = 0;
  int _overlayDebugWindowFrames = 0;
  double _overlayDebugFps = 0.0;
  int _overlayDropCount = 0;
  int? _overlayPrevModelFrameId;
  int? _overlayModelCameraGap;
  _DriveDebugPlotState _debugPlotState = const _DriveDebugPlotState.hidden();
  final ListQueue<String> _sidecarHistory = ListQueue<String>();
  int _lastCameraFallbackLogUs = 0;
  bool _overlayStaleActive = false;
  String _overlayStaleReason = '';
  int _lastConsumedSharedOverlayFrameSequence = 0;
  bool _startupProvisionalSyncEnabled = false;
  int _startupProvisionalSyncUntilUs = 0;
  int _startupNativeFrameSettleCount = 0;
  int _lastProvisionalSyncLogUs = 0;
  Timer? _lifecycleSuspendTimer;
  Timer? _sidecarProcessStopTimer;
  Timer? _backgroundUiResetTimer;
  Timer? _adaptiveCameraQualityTimer;
  bool _backgroundUiResetDone = false;
  String _hudDefaultMode = HudDriveSettingsService.modeOpenpilotOverlay;
  bool _hudModeLoaded = false;
  _AdaptiveCameraQualityMode _adaptiveCameraQualityMode =
      _AdaptiveCameraQualityMode.lowLatency;
  int _adaptiveBadScore = 0;
  bool _adaptiveCameraQualityBusy = false;
  bool _adaptiveCameraQualitySynced = false;
  bool? _sidecarBootstrapDone;
  bool _debugOverlayPreviewMode = false;
  _OverlayPreviewScenario _debugOverlayPreviewScenario =
      _OverlayPreviewScenario.highwayStraight;
  int _debugOverlayPreviewPlotMode = 6;
  double _debugOverlayPreviewSpeed = 1.0;
  bool _sidecarRevisionBadgeExpanded = false;
  Timer? _overlayPreviewTimer;
  int _overlayPreviewFrameSeq = 0;
  int _lastDebugPlotSampleUs = 0;
  static const int _debugPlotMissingClearGraceUs = 1500000;

  final ValueNotifier<_DriveOverlaySnapshot> _overlayNotifier =
      ValueNotifier<_DriveOverlaySnapshot>(
    const _DriveOverlaySnapshot.empty(),
  );

  String get _hostIp => _activeHostIp;

  String? _normalizeDriveHost(String? raw) {
    final host = raw?.trim();
    if (host == null || host.isEmpty) {
      return null;
    }
    return host;
  }

  Uri get _cameraBaseUri => Uri(
        scheme: 'http',
        host: _hostIp,
        port: 5001,
      );

  List<Uri> get _streamEndpointCandidates => <Uri>[
        Uri(
          scheme: 'http',
          host: _hostIp,
          port: 5001,
          path: '/stream',
        ),
        Uri(
          scheme: 'http',
          host: _hostIp,
          port: 7000,
          path: '/stream',
        ),
      ];

  bool get _openpilotOverlayMode =>
      HudDriveSettingsService.isOpenpilotOverlay(_hudDefaultMode);

  String get _modeTagLabel => 'Stock';

  bool get _canUseNativeCamera => !kIsWeb && Platform.isAndroid;

  bool get _useNativeLiveCamera =>
      _openpilotOverlayMode && _canUseNativeCamera && !_nativeCameraUnsupported;

  bool get _useNativeOverlayRenderer =>
      _openpilotOverlayMode && _useNativeLiveCamera && _nativeOverlayEnabled;

  String get _liveCameraName =>
      _liveCameraKind == _DriveCameraKind.wideRoad ? 'wideRoad' : 'road';

  Size _sourceSizeForKind(_DriveCameraKind kind) =>
      _sourceSizeByKind[kind] ?? const Size(1928, 1208);

  String get _liveCameraWsUrl =>
      'ws://$_hostIp:7766/ws/camera/$_liveCameraName';

  bool get _coverViewport =>
      _overlayVerifyMode ? false : _viewportZoomPreset.coverPreferred;

  bool get _coverViewportPreferred => _viewportZoomPreset.coverPreferred;

  double get _viewportPlacementZoom =>
      _overlayVerifyMode ? 1.0 : _viewportZoomPreset.zoomFactor;

  int get _overlaySyncMaxDeltaCurrent => _overlaySyncMaxDeltaLive;

  @override
  void initState() {
    super.initState();
    _activeHostIp = widget.hostIp.trim();
    _renderClock = Stopwatch()..start();
    _renderTicker = createTicker(_onRenderTick)..start();
    WidgetsBinding.instance.addObserver(this);
    _cameraController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel(
        'CarrotCamera',
        onMessageReceived: (message) => _handleCameraJsMessage(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            _safeSetState(() {
              _cameraLoading = true;
              _cameraError = null;
            });
          },
          onPageFinished: (_) {
            _safeSetState(() {
              _cameraLoading = false;
            });
          },
          onWebResourceError: (error) {
            _safeSetState(() {
              _cameraLoading = false;
              _cameraError = '카메라 로드 실패: ${error.description}';
            });
          },
        ),
      );
    if (_canUseNativeCamera) {
      _nativeCameraEventSub = _nativeCameraEventChannel
          .receiveBroadcastStream()
          .listen(_handleNativeCameraEvent, onError: (_) {});
    }
    unawaited(_enableScreenAwake());
    unawaited(_setDisplayHighRefreshPreference(true, reason: 'drive_init'));
    unawaited(_loadAndApplyLandscapeOrientation());
    unawaited(_loadHudDebugLayerToggles());
    unawaited(_loadHudDefaultMode());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final featureSettings =
        Provider.of<HudFeatureSettingsService>(context, listen: false);
    if (!featureSettings.enabled && !_driveFeatureGuardHandled) {
      _driveFeatureGuardHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _toast('HUD/Stock 기능이 비활성화되어 있습니다.', isError: true);
        Navigator.of(context).maybePop();
      });
      return;
    }
    final ssh = Provider.of<SSHService>(context, listen: false);
    final sharedRuntime =
        Provider.of<SharedRuntimeManager>(context, listen: false);
    if (!identical(_sshService, ssh)) {
      _sshService = ssh;
    }
    _attachSshListener(ssh);
    _attachSharedOverlayRuntime(sharedRuntime);
    unawaited(_syncViewportZoomPresetForOrientation());
  }

  @override
  void didUpdateWidget(covariant LiveDriveCanvasScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hostIp != widget.hostIp) {
      unawaited(
        _handleDriveHostTransition(
          widget.hostIp,
          reason: 'route_host_changed',
          forceRestart: true,
        ),
      );
    }
  }

  void _attachSshListener(SSHService ssh) {
    if (identical(_observedSshService, ssh)) {
      return;
    }
    _detachSshListener();
    _observedSshService = ssh;
    _lastObservedSshConnected = ssh.isConnected;
    _lastObservedConnectedHost = _normalizeDriveHost(ssh.connectedIp);
    ssh.addListener(_handleObservedSshChanged);
    final currentHost = _lastObservedConnectedHost;
    if (_lastObservedSshConnected &&
        currentHost != null &&
        currentHost != _hostIp) {
      unawaited(
        _handleDriveHostTransition(
          currentHost,
          reason: 'attach_sync',
          forceRestart: true,
        ),
      );
    }
  }

  void _detachSshListener() {
    final ssh = _observedSshService;
    if (ssh != null) {
      ssh.removeListener(_handleObservedSshChanged);
    }
    _observedSshService = null;
  }

  void _handleObservedSshChanged() {
    final ssh = _observedSshService;
    if (ssh == null || !mounted) {
      return;
    }
    final connected = ssh.isConnected;
    final host = _normalizeDriveHost(ssh.connectedIp);
    final connectedChanged = connected != _lastObservedSshConnected;
    final hostChanged = host != _lastObservedConnectedHost;
    _lastObservedSshConnected = connected;
    _lastObservedConnectedHost = host;

    if (!connected) {
      if (connectedChanged) {
        unawaited(
          _handleDriveConnectionLost(reason: 'ssh_disconnected'),
        );
      }
      return;
    }

    final nextHost = host ?? _hostIp;
    if (connectedChanged || hostChanged || nextHost != _hostIp) {
      unawaited(
        _handleDriveHostTransition(
          nextHost,
          reason: connectedChanged ? 'ssh_reconnected' : 'ssh_host_changed',
          forceRestart: true,
        ),
      );
    }
  }

  void _resetDriveRuntimeState({
    required bool cameraLoading,
    String? cameraError,
  }) {
    _applyOverlaySnapshot(
      const _DriveOverlaySnapshot.empty(),
      forceNativePush: true,
    );
    if (mounted) {
      _safeSetState(() {
        _cameraSourceKey = null;
        _nativeCameraViewId = null;
        _nativeCameraUnsupported = false;
        _nativeCameraAttachReady = false;
        _liveCameraKind = _DriveCameraKind.road;
        _cameraSourceSize = const Size(1928, 1208);
        _wideCamRequested = false;
        _cameraLoading = cameraLoading;
        _cameraError = cameraError;
      });
    } else {
      _cameraSourceKey = null;
      _nativeCameraViewId = null;
      _nativeCameraUnsupported = false;
      _nativeCameraAttachReady = false;
      _liveCameraKind = _DriveCameraKind.road;
      _cameraSourceSize = const Size(1928, 1208);
      _wideCamRequested = false;
      _cameraLoading = cameraLoading;
      _cameraError = cameraError;
    }
    _sourceSizeByKind[_DriveCameraKind.road] = const Size(1928, 1208);
    _sourceSizeByKind[_DriveCameraKind.wideRoad] = const Size(1928, 1208);
    _overlayByModelFrame.clear();
    _overlayFrameOrder.clear();
    _latestOverlaySnapshot = const _DriveOverlaySnapshot.empty();
    _pathAnimationPhase = 0.0;
    _pathAnimationSeq2 = -1;
    _pathAnimationForward = true;
    _lastPathAnimationTickUs = 0;
    _lastCameraFrameId = null;
    _lastCameraFrameEventUs = 0;
    _cameraErrorGraceUntilUs = 0;
    _lastPublishedModelFrameId = null;
    _lastSyncHitUs = 0;
    _lastOverlayPublishUs = 0;
    _lastSyncedArrivalUs = 0;
    _clearOverlayStaleState();
    _lastConsumedSharedOverlayFrameSequence = 0;
  }

  Future<void> _handleDriveHostTransition(
    String nextHost, {
    required String reason,
    bool forceRestart = false,
  }) async {
    final normalizedHost = _normalizeDriveHost(nextHost);
    if (normalizedHost == null) {
      return;
    }
    if (!forceRestart && normalizedHost == _hostIp) {
      return;
    }
    final previousHost = _hostIp;
    _activeHostIp = normalizedHost;
    _pushSidecarHistory(
      'HOST_CHANGE',
      '$previousHost -> $normalizedHost reason=$reason',
    );
    _clearSidecarRecoverySchedule();
    _cancelDelayedSidecarStop();
    _stopAdaptiveCameraQualityLoop(resetMode: true);
    _stopSidecarLoop();
    _resetDriveRuntimeState(cameraLoading: true);
    await _clearNativeOverlay();
    await _unloadWebCameraSurface();
    if (_cameraSuspendedByLifecycle) {
      return;
    }
    _applyHudModeRuntime();
  }

  Future<void> _handleDriveConnectionLost({
    required String reason,
  }) async {
    _pushSidecarHistory('SSH_LOST', reason);
    _clearSidecarRecoverySchedule();
    _cancelDelayedSidecarStop();
    _stopAdaptiveCameraQualityLoop(resetMode: true);
    _stopSidecarLoop();
    _setSidecarPhase(
      _SidecarPhase.idle,
      message: 'SSH 연결을 기다리는 중입니다.',
    );
    _resetDriveRuntimeState(
      cameraLoading: false,
      cameraError: '기기 연결이 끊어졌습니다.',
    );
    await _clearNativeOverlay();
    await _unloadWebCameraSurface();
  }

  Future<void> _loadHudDefaultMode() => _loadHudDefaultModeImpl();

  void _applyHudModeRuntime() => _applyHudModeRuntimeImpl();

  void _handleNativeCameraEvent(dynamic event) =>
      _handleNativeCameraEventImpl(event);

  void _setOverlayVerifyMode(bool enabled) =>
      _setOverlayVerifyModeImpl(enabled);

  void _setViewportFitMode(bool coverPreferred) =>
      _setViewportFitModeImpl(coverPreferred);

  void _setViewportZoomPreset(_DriveViewportZoomPreset preset) =>
      _setViewportZoomPresetImpl(preset);

  Future<void> _syncViewportZoomPresetForOrientation() =>
      _syncViewportZoomPresetForOrientationImpl();

  void _setDebugGuides(bool enabled) => _setDebugGuidesImpl(enabled);

  void _setDebugVerifyPanel(bool enabled) => _setDebugVerifyPanelImpl(enabled);

  void _setDebugViewportFrame(bool enabled) =>
      _setDebugViewportFrameImpl(enabled);

  Future<void> _loadHudDebugLayerToggles() => _loadHudDebugLayerTogglesImpl();

  Future<void> _saveHudDebugLayerToggles() => _saveHudDebugLayerTogglesImpl();

  void _onLayerToggleChanged(StateSetter setLocalState, VoidCallback update) =>
      _onLayerToggleChangedImpl(setLocalState, update);

  void _clearSidecarRecoverySchedule() => _clearSidecarRecoveryScheduleImpl();

  void _scheduleSidecarRuntimeRecovery({
    required String reason,
    Duration minDelay = const Duration(milliseconds: 600),
  }) =>
      _scheduleSidecarRuntimeRecoveryImpl(
        reason: reason,
        minDelay: minDelay,
      );

  void _handleCameraJsMessage(String raw) => _handleCameraJsMessageImpl(raw);

  String _overlayPreviewScenarioLabel(_OverlayPreviewScenario scenario) =>
      _overlayPreviewScenarioLabelImpl(scenario);

  String _overlayPreviewPlotModeLabel(int mode) =>
      _overlayPreviewPlotModeLabelImpl(mode);

  _DriveDebugPlotSample? _buildOverlayPreviewDebugPlot({
    required int seq,
    required double t,
    required double speedKph,
    required double leadDist,
  }) =>
      _buildOverlayPreviewDebugPlotImpl(
        seq: seq,
        t: t,
        speedKph: speedKph,
        leadDist: leadDist,
      );

  void _setOverlayPreviewMode(bool enabled) =>
      _setOverlayPreviewModeImpl(enabled);

  void _startOverlayPreviewLoop() => _startOverlayPreviewLoopImpl();

  void _stopOverlayPreviewLoop() => _stopOverlayPreviewLoopImpl();

  void _tickOverlayPreview() => _tickOverlayPreviewImpl();

  List<List<double>> _previewRoadPathVertices({
    required int sourceWidth,
    required int sourceHeight,
    required double t,
  }) =>
      _previewRoadPathVerticesImpl(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        t: t,
      );

  List<List<double>> _previewLanePolygon({
    required int sourceWidth,
    required int sourceHeight,
    required double t,
    required double laneFactor,
    required double thickness,
  }) =>
      _previewLanePolygonImpl(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        t: t,
        laneFactor: laneFactor,
        thickness: thickness,
      );

  _DriveOverlaySnapshot _buildOverlayPreviewSnapshot({required int seq}) =>
      _buildOverlayPreviewSnapshotImpl(seq: seq);

  Widget _buildOverlayPreviewBackdrop() => _buildOverlayPreviewBackdropImpl();

  Future<void> _restorePortraitOrientation() =>
      _restorePortraitOrientationImpl();

  Future<void> _setDisplayHighRefreshPreference(
    bool enabled, {
    required String reason,
  }) =>
      _setDisplayHighRefreshPreferenceImpl(enabled, reason: reason);

  Future<void> _enableScreenAwake() => _enableScreenAwakeImpl();

  Future<void> _disableScreenAwake() => _disableScreenAwakeImpl();

  Future<void> _loadAndApplyLandscapeOrientation() =>
      _loadAndApplyLandscapeOrientationImpl();

  Future<bool> _isSidecarBootstrapDone() => _isSidecarBootstrapDoneImpl();

  Future<void> _setSidecarBootstrapDone(bool value) =>
      _setSidecarBootstrapDoneImpl(value);

  String _shortSidecarRevision(String? revision) =>
      _shortSidecarRevisionImpl(revision);

  Future<void> _notifySidecarRevisionUpdated(String revision) =>
      _notifySidecarRevisionUpdatedImpl(revision);

  Future<void> _ensureSidecarRevisionUpToDate(SSHService ssh) =>
      _ensureSidecarRevisionUpToDateImpl(ssh);

  bool _isSidecarDeployMissingError(Object error) =>
      _isSidecarDeployMissingErrorImpl(error);

  Future<bool> _tryAutoBootstrapSidecar(
    SSHService ssh, {
    required Object startError,
  }) =>
      _tryAutoBootstrapSidecarImpl(ssh, startError: startError);

  Future<void> _lockLandscapeOrientations() => _lockLandscapeOrientationsImpl();

  Future<void> _exitScreen() => _exitScreenImpl();

  @override
  void dispose() {
    _isDisposing = true;
    _detachSshListener();
    _detachSharedOverlayRuntime();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      _persistArReplaySessionIfNeeded(force: true, reason: 'dispose'),
    );
    _stopOverlayPreviewLoop();
    _sidecarTransitionTimer?.cancel();
    _sidecarTransitionTimer = null;
    _sidecarRecoveryTimer?.cancel();
    _sidecarRecoveryTimer = null;
    _overlayDisconnectDebounce?.cancel();
    _overlayDisconnectDebounce = null;
    _hudNoticeTimer?.cancel();
    _hudNoticeTimer = null;
    _stopAdaptiveCameraQualityLoop(resetMode: true);
    _cancelLifecycleSuspendTimer();
    _cancelDelayedSidecarStop();
    _cancelBackgroundUiResetTimer();
    _renderTicker?.dispose();
    _renderTicker = null;
    unawaited(_clearNativeOverlay());
    _stopSidecarLoop();
    // Keep the resident sidecar alive when leaving the drive route so
    // returning from dashboard tabs does not cold-start stock graphics again.
    unawaited(_stopSidecarProcessIfNeeded());
    final nativeSub = _nativeCameraEventSub;
    _nativeCameraEventSub = null;
    if (nativeSub != null) {
      unawaited(nativeSub.cancel());
    }
    unawaited(_disableScreenAwake());
    unawaited(_setDisplayHighRefreshPreference(false, reason: 'drive_dispose'));
    _overlayNotifier.dispose();
    unawaited(_restorePortraitOrientation());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_enableScreenAwake());
        _cancelLifecycleSuspendTimer();
        _resumeFromBackground();
        break;
      case AppLifecycleState.inactive:
        // Notification shade / transient focus loss can emit inactive briefly.
        // Keep camera alive here to avoid visible flicker.
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(_disableScreenAwake());
        _scheduleSuspendForBackground();
        break;
    }
  }

  String _buildLiveCameraHtml(_DriveCameraKind cameraKind) =>
      _buildLiveCameraHtmlImpl(cameraKind);

  String _buildIdleCameraHtml() => _buildIdleCameraHtmlImpl();

  Future<void> _unloadWebCameraSurface() => _unloadWebCameraSurfaceImpl();

  _DriveOverlaySnapshot _stabilizeOverlaySnapshot(
    _DriveOverlaySnapshot snapshot,
  ) =>
      _stabilizeOverlaySnapshotImpl(snapshot);

  Uri _sidecarHttpUri(String path, [Map<String, String>? query]) =>
      _sidecarHttpUriImpl(path, query);

  Uri _cameraHttpUri(String path, [Map<String, String>? query]) =>
      _cameraHttpUriImpl(path, query);

  Widget _statusLine(
    String label,
    String value, {
    double labelWidth = 126,
    double labelFontSize = 13,
    double valueFontSize = 13,
    EdgeInsets? padding,
    Color? valueColor,
  }) =>
      _statusLineImpl(
        label,
        value,
        labelWidth: labelWidth,
        labelFontSize: labelFontSize,
        valueFontSize: valueFontSize,
        padding: padding,
        valueColor: valueColor,
      );

  Widget _debugMetricPill(String label, String value) =>
      _debugMetricPillImpl(label, value);

  Future<void> _showDebugTextDialog(String title, String content) =>
      _showDebugTextDialogImpl(title, content);

  Future<void> _debugActionHealth() => _debugActionHealthImpl();

  Future<void> _debugActionWsProbe() => _debugActionWsProbeImpl();

  Future<void> _debugActionTailLog() => _debugActionTailLogImpl();

  Future<void> _debugActionRedeploy() => _debugActionRedeployImpl();

  Future<void> _debugActionLegacyMigration() =>
      _debugActionLegacyMigrationImpl();

  Future<void> _debugActionRestart() => _debugActionRestartImpl();

  Future<void> _debugActionInspectArScene() => _debugActionInspectArSceneImpl();

  Future<void> _debugActionCaptureArReplay() =>
      _debugActionCaptureArReplayImpl();

  Future<void> _debugActionUseLatestArReplay() =>
      _debugActionUseLatestArReplayImpl();

  Future<void> _debugActionStopArReplay() => _debugActionStopArReplayImpl();

  Future<void> _debugActionExportArReplay() => _debugActionExportArReplayImpl();

  String _arReplayStatusLabel() => _arReplayStatusLabelImpl();

  Map<String, dynamic>? _currentLiveArScenePayload() =>
      _currentLiveArScenePayloadImpl();

  Future<void> _captureArReplayFrame({
    required Map<String, dynamic> arScenePayload,
    int? viewId,
    Map<String, dynamic>? nativeRenderDebug,
    bool force = false,
  }) =>
      _captureArReplayFrameImpl(
        arScenePayload: arScenePayload,
        viewId: viewId,
        nativeRenderDebug: nativeRenderDebug,
        force: force,
      );

  Future<Map<String, dynamic>?> _fetchNativeArRenderDebug(int viewId) =>
      _fetchNativeArRenderDebugImpl(viewId);

  Future<void> _persistArReplaySessionIfNeeded({
    bool force = false,
    String? reason,
  }) =>
      _persistArReplaySessionIfNeededImpl(force: force, reason: reason);

  void _setArReplayMode(
    bool enabled, {
    _DriveArReplayFrame? frame,
  }) =>
      _setArReplayModeImpl(enabled, frame: frame);

  Future<bool> _confirmDebugAction({
    required String title,
    required String message,
    String confirmText = '?ㅽ뻾',
  }) =>
      _confirmDebugActionImpl(
        title: title,
        message: message,
        confirmText: confirmText,
      );

  Future<void> _debugActionResetSidecar() => _debugActionResetSidecarImpl();

  String _buildDebugSnapshotText() => _buildDebugSnapshotTextImpl();

  Future<void> _copyDebugSnapshot() => _copyDebugSnapshotImpl();

  void _toast(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 2),
  }) {
    _hudNoticeTimer?.cancel();
    _safeSetState(() {
      _hudNoticeMessage = message;
      _hudNoticeIsError = isError;
    });
    _hudNoticeTimer = Timer(duration, () {
      _safeSetState(() {
        _hudNoticeMessage = null;
        _hudNoticeIsError = false;
      });
    });
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted || _isDisposing) return;
    setState(fn);
  }

  Future<void> _openDebugOptionsPopup() => _openDebugOptionsPopupImpl();

  Widget _buildDriveCameraSurface() => _buildDriveCameraSurfaceImpl();

  String? _cameraCenterNoticeMessage() => _cameraCenterNoticeMessageImpl();

  Widget _buildDriveModeTag(UiWindowInfo window) =>
      _buildDriveModeTagImpl(window);

  Widget _buildSidecarRevisionBadge(UiWindowInfo window) =>
      _buildSidecarRevisionBadgeImpl(window);

  double _hudPreferredAspectRatioForWindow(
    UiWindowInfo window, {
    required bool wide,
  }) =>
      _hudPreferredAspectRatioForWindowImpl(window, wide: wide);

  double _computePortraitHudHeight(
    UiWindowInfo window,
    BoxConstraints constraints,
  ) =>
      _computePortraitHudHeightImpl(window, constraints);

  Widget _buildPortraitHudPanel(UiWindowInfo window) =>
      _buildPortraitHudPanelImpl(window);

  bool _shouldHideHudForTinyViewport(
    UiWindowInfo window,
    BoxConstraints constraints, {
    required bool isLandscape,
  }) =>
      _shouldHideHudForTinyViewportImpl(
        window,
        constraints,
        isLandscape: isLandscape,
      );

  double _computeLandscapeHudOverlayHeight(
    UiWindowInfo window,
    Size drawSize,
  ) =>
      _computeLandscapeHudOverlayHeightImpl(window, drawSize);

  double _computeLandscapeHudOverlayWidth(
    UiWindowInfo window,
    double overlayHeight,
  ) =>
      _computeLandscapeHudOverlayWidthImpl(window, overlayHeight);

  Widget _buildLandscapeHudOverlay(
    UiWindowInfo window,
    Size drawSize, {
    double? overlayHeight,
    double? overlayWidth,
  }) =>
      _buildLandscapeHudOverlayImpl(
        window,
        drawSize,
        overlayHeight: overlayHeight,
        overlayWidth: overlayWidth,
      );

  Widget _buildDriveScaffoldBody(UiWindowInfo window) =>
      _buildDriveScaffoldBodyImpl(window);

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        unawaited(_restorePortraitOrientation());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF05070C),
        body: _buildDriveScaffoldBody(window),
      ),
    );
  }
}
