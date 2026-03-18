import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:msgpack_dart/msgpack_dart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/developer_mode_service.dart';
import '../../services/hud_drive_settings_service.dart';
import '../../services/hud_feature_settings_service.dart';
import '../../services/sidecar_service.dart';
import '../../services/ssh_service.dart';
import '../../services/storage_layout_service.dart';
import '../../features/yolo/yolo.dart';
import '../../ui/adaptive/display_feature_utils.dart';
import '../../ui/adaptive/window_class.dart';
import '../../features/hud/hud.dart';

part 'live_drive_canvas_overlay_components.dart';
part 'live_drive_canvas_overlay_models_components.dart';
part 'live_drive_canvas_plot_models_components.dart';
part 'live_drive_canvas_plot_components.dart';
part 'live_drive_canvas_overlay_math_components.dart';
part 'live_drive_canvas_settings_popup_components.dart';
part 'live_drive_canvas_hud_components.dart';
part 'live_drive_canvas_overlay_sync_components.dart';
part 'live_drive_canvas_yolo_components.dart';
part 'live_drive_canvas_dev_playback_components.dart';
part 'live_drive_canvas_camera_components.dart';
part 'live_drive_canvas_camera_html_components.dart';
part 'live_drive_canvas_camera_diag_components.dart';
part 'live_drive_canvas_diag_logging_components.dart';
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

enum _CameraAttachPhase {
  idle,
  surfaceReady,
  socketConnecting,
  socketConnected,
  waitingFirstFrame,
  retrying,
  streaming,
}

enum _AdaptiveCameraQualityMode {
  lowLatency,
}

enum _DriveViewportZoomPreset {
  zoomOut,
  fit,
  crop,
}

enum _DriveSettingsPopupGroup {
  graphics,
  yolo,
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
  int _nativeCameraAttachEpoch = 0;
  bool _nativeCameraUnsupported = false;
  bool _isDisposing = false;
  final bool _nativeOverlayEnabled = true;
  Size _nativeOverlaySize = Size.zero;
  Rect _nativeOverlayVisibleViewportRect = Rect.zero;
  int _lastNativeOverlayPushUs = 0;
  static const int _nativeOverlayPushIntervalUs = 16666;
  bool _nativeOverlayPushBusy = false;
  int _nativeOverlayRelayoutEpoch = 0;
  int _nativeOverlayRelayoutGraceUntilUs = 0;
  _DriveOverlaySnapshot? _pendingNativeOverlaySnapshot;
  bool _pendingNativeOverlayForce = false;

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
  static const int _staleDegradedPublishAfterUs = 900000;
  static const int _cameraFrameStaleUs = 350000;
  static const int _cameraHealthyFrameAgeUs = 1200000;
  static const int _startupProvisionalSyncWindowUs = 4000000;
  static const int _cameraFirstFrameDegradedHoldUs = 12000000;
  static const int _cameraFirstFrameForceReattachUs = 6500000;
  static const int _cameraFirstFrameRecoveryCooldownUs = 8000000;
  static const int _startupProvisionalNativeSettleFrames = 3;
  static const int _interpMinUs = 6000;
  static const int _interpMaxUs = 50000;
  static const Duration _cameraDiagCaptureCooldown = Duration(seconds: 12);
  static const Duration _cameraTransientErrorEscalationDelay =
      Duration(seconds: 5);
  static const int _cameraStartupSocketFailureSuppressWindowUs = 6000000;
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
  IOSink? _driveDiagSink;
  String? _driveDiagFilePath;
  bool _driveDiagInitInFlight = false;
  bool _driveDiagClosing = false;
  Timer? _driveDiagSummaryTimer;
  DateTime? _driveDiagSessionStartedAt;
  Map<String, dynamic>? _lastNativeCameraDiag;
  String? _lastCameraDiagFilePath;
  int _driveDiagOverlayPushCallsWindow = 0;
  int _driveDiagOverlayPushSentWindow = 0;
  int _driveDiagOverlayPushCoalescedWindow = 0;
  int _driveDiagOverlayPushSkippedWindow = 0;
  int _driveDiagOverlayPushDuplicateWindow = 0;
  int _driveDiagOverlayPushNoSurfaceWindow = 0;
  int _driveDiagOverlayPayloadFramesWindow = 0;
  int _driveDiagCameraFrameEventsWindow = 0;
  int _driveDiagSyncGapSamplesWindow = 0;
  int _driveDiagSyncGapSumWindow = 0;
  int _driveDiagSyncGapMaxWindow = 0;
  int _driveDiagInterpSamplesWindow = 0;
  int _driveDiagInterpSumUsWindow = 0;
  int _driveDiagInterpMaxUsWindow = 0;
  int _driveDiagStaleEnterWindow = 0;
  int _driveDiagStaleAccumulatedUsWindow = 0;
  int? _driveDiagStaleStartedUs;
  int? _driveDiagLastOverlayPushModelFrameId;
  int? _lastCameraFrameId;
  int _lastCameraFrameEventUs = 0;
  int _cameraErrorGraceUntilUs = 0;
  int _cameraAttachStartedUs = 0;
  int _cameraStartupSocketFailureCount = 0;
  int _lastCameraFirstFrameRecoveryUs = 0;
  int _cameraFirstFrameRecoveryCount = 0;
  _CameraAttachPhase _cameraAttachPhase = _CameraAttachPhase.idle;
  Timer? _cameraTransientErrorTimer;
  String? _cameraTransientErrorSource;
  String? _cameraTransientErrorReason;
  String? _cameraTransientErrorMessage;
  int? _lastPublishedModelFrameId;
  int _lastSyncHitUs = 0;
  int _lastOverlayPublishUs = 0;
  int _lastSyncedArrivalUs = 0;
  double _smoothedSyncIntervalUs = 33333.0;
  late final Stopwatch _renderClock;
  Ticker? _renderTicker;
  _DriveOverlaySnapshot _renderFromSnapshot =
      const _DriveOverlaySnapshot.empty();
  _DriveOverlaySnapshot _renderToSnapshot = const _DriveOverlaySnapshot.empty();
  int _renderInterpStartUs = 0;
  int _renderInterpDurationUs = 24000;
  bool _renderInterpActive = false;
  _DriveOverlaySnapshot _latestOverlaySnapshot =
      const _DriveOverlaySnapshot.empty();
  double _pathAnimationPhase = 0.0;
  int _pathAnimationSeq2 = -1;
  bool _pathAnimationForward = true;
  int _lastPathAnimationTickUs = 0;
  int? _lastNativeOverlaySignature;
  bool _lastNativeOverlayHadPayload = false;
  int? _lastNativeYoloConfigSignature;
  final bool _overlayVerifyMode = false;
  String _overlayVerifyText = '';
  int _lastOverlayVerifyUpdateUs = 0;
  static const int _overlayVerifyIntervalUs = 200000;
  _DriveViewportZoomPreset _viewportZoomPreset = _DriveViewportZoomPreset.crop;
  bool? _lastViewportZoomOrientationLandscape;
  final bool _debugShowGuides = false;
  final bool _debugShowVerifyPanel = false;
  final bool _debugShowViewportFrame = false;
  // AR debug overlay defaults:
  // - Core AR/lead/radar layers stay enabled by default.
  // - YOLO overlays stay off by default.
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
  bool _debugShowStockTopRight = true;
  bool _debugShowLaneMetrics = true;
  bool _debugShowDebugPlot = true;
  // Developer-only offline playback lives next to the live stock path on
  // purpose so it can be removed later without rewriting the production
  // native/web camera feed logic.
  _DriveSettingsPopupGroup _driveSettingsPopupGroup =
      _DriveSettingsPopupGroup.graphics;
  YoloDebugSettings _driveYoloDebugSettings = YoloDebugSettings.empty;
  YoloRuntimeStatusSnapshot _driveYoloRuntimeStatus =
      const YoloRuntimeStatusSnapshot(
    config: <String, dynamic>{},
    state: <String, dynamic>{},
    updatedAt: null,
  );
  String? _developerPlaybackVideoPath;
  VideoPlayerController? _developerPlaybackController;
  Timer? _developerPlaybackTimer;
  VoidCallback? _developerPlaybackControllerListener;
  bool _developerPlaybackEnabled = false;
  bool _developerPlaybackLoading = false;
  bool _developerPlaybackBusy = false;
  String? _developerPlaybackError;
  DateTime? _developerPlaybackStatusUpdatedAt;
  int _developerPlaybackLastRequestedPositionMs = -1;
  int _developerPlaybackNextTickAtMs = 0;
  String? _developerPlaybackLastResolvedFrameToken;
  int _developerPlaybackSourceEpoch = 0;
  Map<String, String> _sidecarProcessSnapshot = <String, String>{};
  Map<String, dynamic> _sidecarHealthSnapshot = <String, dynamic>{};
  Map<String, dynamic> _sidecarProfileSnapshot = <String, dynamic>{};
  String _sidecarRepoFlavorHint = SidecarService.repoFlavorUnknown;
  String _sidecarVariantHint = SidecarService.defaultVariant;
  bool _sidecarFlavorHintResolving = false;
  DateTime? _sidecarLastStartAt;
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
  int _overlayStaleStartedUs = 0;
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
  bool _adaptiveCameraQualityBusy = false;
  bool _adaptiveCameraQualitySynced = false;
  bool? _sidecarBootstrapDone;
  int _lastDebugPlotSampleUs = 0;
  int _lastDebugPlotQueueUs = 0;
  _DriveDebugPlotSample? _latestDebugPlotSample;
  static const int _debugPlotMissingClearGraceUs = 1500000;
  static const int _debugPlotTargetQueueIntervalUs = 33333;

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

  String get _settingsMenuFlavorLabel {
    if (!_openpilotOverlayMode) {
      return 'stock';
    }
    final flavor = (_sidecarHealthSnapshot['repoFlavor'] ??
            _sidecarProfileSnapshot['repoFlavor'] ??
            _sidecarRepoFlavorHint)
        .toString()
        .trim()
        .toLowerCase();
    switch (flavor) {
      case SidecarService.repoFlavorC3:
        return 'c3';
      case SidecarService.repoFlavorC4:
        return 'c4';
      default:
        return 'unknown';
    }
  }

  String get _modeTagLabel {
    if (!_openpilotOverlayMode) {
      return 'Stock';
    }
    switch (_settingsMenuFlavorLabel) {
      case SidecarService.repoFlavorC3:
        return 'c3';
      case SidecarService.repoFlavorC4:
        return 'c4';
      default:
        return '';
    }
  }

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
            if (_lastCameraFrameId != null) {
              _safeSetState(() {
                _cameraLoading = false;
              });
            }
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
    unawaited(_loadYoloDebugSettings());
    unawaited(_loadDriveYoloRuntimeStatus());
    unawaited(_loadDeveloperPlaybackSelection());
    unawaited(_loadHudDefaultMode());
    unawaited(_startDriveDiagnosticsLogging());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final developerMode =
        Provider.of<DeveloperModeService>(context, listen: false);
    if (!developerMode.enabled && _developerPlaybackEnabled) {
      unawaited(_toggleDeveloperPlaybackEnabled());
    }
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
    if (_hudModeLoaded && _openpilotOverlayMode && ssh.isConnected) {
      unawaited(_primeSidecarFlavorHints());
    }
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
      return;
    }
    unawaited(_primeSidecarFlavorHints());
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
        _nativeCameraAttachEpoch += 1;
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
      _nativeCameraAttachEpoch += 1;
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
    _cameraAttachStartedUs = 0;
    _cameraStartupSocketFailureCount = 0;
    _lastCameraFirstFrameRecoveryUs = 0;
    _cameraFirstFrameRecoveryCount = 0;
    _cameraAttachPhase = _CameraAttachPhase.idle;
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
    _applyResolvedSidecarFlavorHints(
      repoFlavor: SidecarService.repoFlavorUnknown,
      variant: SidecarService.defaultVariant,
    );
    _pushSidecarHistory(
      'HOST_CHANGE',
      '$previousHost -> $normalizedHost reason=$reason',
    );
    _appendDriveDiagEvent(
      'host_transition',
      <String, dynamic>{
        'from': previousHost,
        'to': normalizedHost,
        'reason': reason,
      },
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
    unawaited(_primeSidecarFlavorHints(forceRefresh: true));
  }

  Future<void> _handleDriveConnectionLost({
    required String reason,
  }) async {
    _pushSidecarHistory('SSH_LOST', reason);
    _appendDriveDiagEvent(
      'connection_lost',
      <String, dynamic>{'reason': reason},
    );
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

  Future<void> _primeSidecarFlavorHints({bool forceRefresh = false}) =>
      _primeSidecarFlavorHintsImpl(forceRefresh: forceRefresh);

  void _applyHudModeRuntime() => _applyHudModeRuntimeImpl();

  void _handleNativeCameraEvent(dynamic event) =>
      _handleNativeCameraEventImpl(event);

  void _setViewportZoomPreset(_DriveViewportZoomPreset preset) =>
      _setViewportZoomPresetImpl(preset);

  Future<void> _syncViewportZoomPresetForOrientation() =>
      _syncViewportZoomPresetForOrientationImpl();

  Future<void> _loadHudDebugLayerToggles() => _loadHudDebugLayerTogglesImpl();

  Future<void> _saveHudDebugLayerToggles() => _saveHudDebugLayerTogglesImpl();

  Future<void> _loadYoloDebugSettings() => _loadYoloDebugSettingsImpl();

  Future<void> _loadDriveYoloRuntimeStatus() =>
      _loadDriveYoloRuntimeStatusImpl();

  Future<void> _loadDeveloperPlaybackSelection() =>
      _loadDeveloperPlaybackSelectionImpl();

  Future<void> _selectDeveloperPlaybackVideo() =>
      _selectDeveloperPlaybackVideoImpl();

  Future<void> _clearDeveloperPlaybackSelection() =>
      _clearDeveloperPlaybackSelectionImpl();

  Future<void> _toggleDeveloperPlaybackEnabled() =>
      _toggleDeveloperPlaybackEnabledImpl();

  Future<void> _pauseDeveloperPlayback() => _pauseDeveloperPlaybackImpl();

  Future<void> _resumeDeveloperPlayback() => _resumeDeveloperPlaybackImpl();

  Future<void> _clearDeveloperPlaybackSession() =>
      _clearDeveloperPlaybackSessionImpl();

  Future<void> _copyDriveYoloRuntimeStatus() =>
      _copyDriveYoloRuntimeStatusImpl();

  Future<void> _shareDriveDiagnosticsLog() => _shareDriveDiagnosticsLogImpl();

  Future<void> _setDriveYoloDebugSettings(YoloDebugSettings next) =>
      _setDriveYoloDebugSettingsImpl(next);

  Future<void> _maybeAutoFallbackDriveYoloFromRuntimeStatus(
    YoloRuntimeStatusSnapshot snapshot,
  ) =>
      _maybeAutoFallbackDriveYoloFromRuntimeStatusImpl(snapshot);

  String _driveYoloValue(String key) => _driveYoloValueImpl(key);

  String _driveYoloFrameSummary() => _driveYoloFrameSummaryImpl();

  void _onLayerToggleChanged(StateSetter setLocalState, VoidCallback update) =>
      _onLayerToggleChangedImpl(setLocalState, update);

  void _clearSidecarRecoverySchedule() => _clearSidecarRecoveryScheduleImpl();

  void _scheduleSidecarRuntimeRecovery({
    required String reason,
    Duration minDelay = const Duration(milliseconds: 600),
    bool preferSooner = false,
  }) =>
      _scheduleSidecarRuntimeRecoveryImpl(
        reason: reason,
        minDelay: minDelay,
        preferSooner: preferSooner,
      );

  void _handleCameraJsMessage(String raw) => _handleCameraJsMessageImpl(raw);

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

  @override
  void dispose() {
    _isDisposing = true;
    _detachSshListener();
    _detachSharedOverlayRuntime();
    WidgetsBinding.instance.removeObserver(this);
    _sidecarTransitionTimer?.cancel();
    _sidecarTransitionTimer = null;
    _sidecarRecoveryTimer?.cancel();
    _sidecarRecoveryTimer = null;
    _overlayDisconnectDebounce?.cancel();
    _overlayDisconnectDebounce = null;
    _cameraTransientErrorTimer?.cancel();
    _cameraTransientErrorTimer = null;
    _hudNoticeTimer?.cancel();
    _hudNoticeTimer = null;
    _stopAdaptiveCameraQualityLoop(resetMode: true);
    _cancelLifecycleSuspendTimer();
    _cancelDelayedSidecarStop();
    _cancelBackgroundUiResetTimer();
    _developerPlaybackTimer?.cancel();
    _developerPlaybackTimer = null;
    final developerPlaybackController = _developerPlaybackController;
    final developerPlaybackListener = _developerPlaybackControllerListener;
    _developerPlaybackController = null;
    _developerPlaybackControllerListener = null;
    if (developerPlaybackController != null &&
        developerPlaybackListener != null) {
      developerPlaybackController.removeListener(developerPlaybackListener);
    }
    if (developerPlaybackController != null) {
      unawaited(developerPlaybackController.dispose());
    }
    unawaited(_clearDeveloperPlaybackSession());
    unawaited(_stopDriveDiagnosticsLogging(reason: 'dispose'));
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

  Future<void> _openDriveSettingsPopup() => _openDriveSettingsPopupImpl();

  Widget _buildDriveCameraSurface() => _buildDriveCameraSurfaceImpl();

  Widget _buildDeveloperPlaybackSurface() =>
      _buildDeveloperPlaybackSurfaceImpl();

  bool get _isDeveloperPlaybackRequested => _isDeveloperPlaybackRequestedImpl;

  Size get _effectiveViewportSourceSize => _effectiveViewportSourceSizeImpl;

  String? _cameraCenterNoticeMessage() => _cameraCenterNoticeMessageImpl();

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
