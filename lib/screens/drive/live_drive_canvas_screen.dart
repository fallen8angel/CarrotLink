import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
import '../../services/sidecar_service.dart';
import '../../services/ssh_service.dart';
import '../../services/storage_layout_service.dart';
import '../../ui/adaptive/display_feature_utils.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/home_hud_preview_card.dart';

part 'live_drive_canvas_overlay_components.dart';
part 'live_drive_canvas_overlay_models_components.dart';
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
      'hud_debug_layer_toggles_v3';
  static const String _hudDebugLayerTogglesInitPrefKey =
      'hud_debug_layer_toggles_init_v3';
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
  final SidecarService _sidecarService = SidecarService();
  SSHService? _sshService;
  bool _cameraLoading = true;
  String? _cameraError;
  String? _cameraSourceKey;
  Size _cameraSourceSize = const Size(1928, 1208);
  final Map<_DriveCameraKind, Size> _sourceSizeByKind =
      <_DriveCameraKind, Size>{
    _DriveCameraKind.road: const Size(1928, 1208),
    _DriveCameraKind.wideRoad: const Size(1928, 1208),
  };
  StreamSubscription<dynamic>? _nativeCameraEventSub;
  int? _nativeCameraViewId;
  bool _nativeCameraUnsupported = false;
  final bool _nativeOverlayEnabled = true;
  Size _nativeOverlaySize = Size.zero;
  int _lastNativeOverlayPushUs = 0;
  static const int _nativeOverlayPushIntervalUs = 16666;

  Isolate? _sidecarWorkerIsolate;
  ReceivePort? _sidecarWorkerReceivePort;
  StreamSubscription? _sidecarWorkerSubscription;
  bool _sidecarConnected = false;
  int _sidecarSession = 0;
  bool _sidecarAutoManaging = false;
  bool _sidecarTransitioning = false;
  bool _suppressCameraErrors = false;
  Timer? _sidecarTransitionTimer;
  Timer? _sidecarRecoveryTimer;
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
  static const int _interpMinUs = 12000;
  static const int _interpMaxUs = 90000;
  static const Duration _cameraDiagCaptureCooldown = Duration(seconds: 12);
  static const Duration _lifecycleSuspendDelay = Duration(milliseconds: 2600);
  static const Duration _backgroundProcessKeepAlive = Duration(seconds: 45);
  static const Duration _backgroundUiResetGrace = Duration(seconds: 8);
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
  int? _lastPublishedModelFrameId;
  int _lastSyncHitUs = 0;
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
  bool _overlayVerifyMode = false;
  String _overlayVerifyText = '';
  int _lastOverlayVerifyUpdateUs = 0;
  static const int _overlayVerifyIntervalUs = 200000;
  bool _coverViewportPreferred = true;
  bool _debugShowGuides = false;
  bool _debugShowVerifyPanel = false;
  bool _debugShowViewportFrame = false;
  bool _debugShowArOverlay = true;
  bool _debugShowPathFill = true;
  bool _debugShowLaneLines = true;
  bool _debugShowRoadEdge = true;
  bool _debugShowLead1 = false;
  bool _debugShowLead2 = false;
  bool _debugShowRadarBadge = false;
  bool _debugShowRadarVector = false;
  bool _debugShowStopDistanceTf = true;
  bool _debugShowStateText = true;
  Map<String, String> _sidecarProcessSnapshot = <String, String>{};
  Map<String, dynamic> _sidecarHealthSnapshot = <String, dynamic>{};
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
  int _overlayDebugWindowStartMs = 0;
  int _overlayDebugWindowFrames = 0;
  double _overlayDebugFps = 0.0;
  int _overlayDropCount = 0;
  int? _overlayPrevModelFrameId;
  int? _overlayModelCameraGap;
  final ListQueue<String> _sidecarHistory = ListQueue<String>();
  int _lastCameraFallbackLogUs = 0;
  Timer? _lifecycleSuspendTimer;
  Timer? _sidecarProcessStopTimer;
  Timer? _backgroundUiResetTimer;
  Timer? _adaptiveCameraQualityTimer;
  bool _backgroundUiResetDone = false;
  String _hudDefaultMode = HudDriveSettingsService.modeWebrtc;
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
  double _debugOverlayPreviewSpeed = 1.0;
  Timer? _overlayPreviewTimer;
  int _overlayPreviewFrameSeq = 0;

  final ValueNotifier<_DriveOverlaySnapshot> _overlayNotifier =
      ValueNotifier<_DriveOverlaySnapshot>(
    const _DriveOverlaySnapshot.empty(),
  );

  Uri get _cameraBaseUri => Uri(
        scheme: 'http',
        host: widget.hostIp,
        port: 5001,
      );

  List<Uri> get _streamEndpointCandidates => <Uri>[
        Uri(
          scheme: 'http',
          host: widget.hostIp,
          port: 5001,
          path: '/stream',
        ),
        Uri(
          scheme: 'http',
          host: widget.hostIp,
          port: 7000,
          path: '/stream',
        ),
      ];

  String get _sidecarWsUrl =>
      'ws://${widget.hostIp}:7766/ws/live?encoding=zlib-json&camera=$_liveCameraName';

  bool get _openpilotOverlayMode =>
      HudDriveSettingsService.isOpenpilotOverlay(_hudDefaultMode);

  String get _modeTagLabel => _openpilotOverlayMode ? 'openpilot' : 'webrtc';

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
      'ws://${widget.hostIp}:7766/ws/camera/$_liveCameraName';

  bool get _coverViewport =>
      _overlayVerifyMode ? false : _coverViewportPreferred;

  int get _overlaySyncMaxDeltaCurrent => _overlaySyncMaxDeltaLive;

  @override
  void initState() {
    super.initState();
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
            if (!mounted) return;
            setState(() {
              _cameraLoading = true;
              _cameraError = null;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() {
              _cameraLoading = false;
            });
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() {
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
    _sshService ??= Provider.of<SSHService>(context, listen: false);
  }

  @override
  void didUpdateWidget(covariant LiveDriveCanvasScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hostIp != widget.hostIp) {
      _applyOverlaySnapshot(
        const _DriveOverlaySnapshot.empty(),
        forceNativePush: true,
      );
      setState(() {
        _cameraSourceKey = null;
        _nativeCameraViewId = null;
        _nativeCameraUnsupported = false;
        _liveCameraKind = _DriveCameraKind.road;
        _cameraSourceSize = const Size(1928, 1208);
        _wideCamRequested = false;
      });
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
      _lastPublishedModelFrameId = null;
      _stopAdaptiveCameraQualityLoop(resetMode: true);
      _applyHudModeRuntime();
    }
  }

  Future<void> _loadHudDefaultMode() => _loadHudDefaultModeImpl();

  void _applyHudModeRuntime() => _applyHudModeRuntimeImpl();

  void _handleNativeCameraEvent(dynamic event) =>
      _handleNativeCameraEventImpl(event);

  void _setOverlayVerifyMode(bool enabled) =>
      _setOverlayVerifyModeImpl(enabled);

  void _setViewportFitMode(bool coverPreferred) =>
      _setViewportFitModeImpl(coverPreferred);

  void _setDebugGuides(bool enabled) => _setDebugGuidesImpl(enabled);

  void _setDebugVerifyPanel(bool enabled) =>
      _setDebugVerifyPanelImpl(enabled);

  void _setDebugViewportFrame(bool enabled) =>
      _setDebugViewportFrameImpl(enabled);

  Future<void> _loadHudDebugLayerToggles() =>
      _loadHudDebugLayerTogglesImpl();

  Future<void> _saveHudDebugLayerToggles() =>
      _saveHudDebugLayerTogglesImpl();

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

  void _setOverlayPreviewMode(bool enabled) =>
      _setOverlayPreviewModeImpl(enabled);

  void _startOverlayPreviewLoop() => _startOverlayPreviewLoopImpl();

  void _stopOverlayPreviewLoop() => _stopOverlayPreviewLoopImpl();

  void _tickOverlayPreview() => _tickOverlayPreviewImpl();

  List<List<double>> _previewRoadPathVertices({
    required int sourceWidth,
    required int sourceHeight,
    required double t,
  }) => _previewRoadPathVerticesImpl(
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
  }) => _previewLanePolygonImpl(
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
  }) => _setDisplayHighRefreshPreferenceImpl(enabled, reason: reason);

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
  }) => _tryAutoBootstrapSidecarImpl(ssh, startError: startError);

  Future<void> _lockLandscapeOrientations() =>
      _lockLandscapeOrientationsImpl();

  Future<void> _exitScreen() => _exitScreenImpl();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopOverlayPreviewLoop();
    _sidecarTransitionTimer?.cancel();
    _sidecarTransitionTimer = null;
    _sidecarRecoveryTimer?.cancel();
    _sidecarRecoveryTimer = null;
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
    if (!_residentSidecarManaged) {
      unawaited(_stopSidecarProcessIfNeeded());
    }
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

  Map<String, dynamic>? _mergeSidecarOverlay2dTrackVertices({
    required Map<String, dynamic>? current,
    required Map<String, dynamic>? previous,
  }) =>
      _mergeSidecarOverlay2dTrackVerticesImpl(
        current: current,
        previous: previous,
      );

  Uri _sidecarHttpUri(String path, [Map<String, String>? query]) =>
      _sidecarHttpUriImpl(path, query);

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


  Future<void> _debugActionRestart() => _debugActionRestartImpl();


  Future<bool> _confirmDebugAction({
    required String title,
    required String message,
    String confirmText = '?ㅽ뻾',
  }) => _confirmDebugActionImpl(
        title: title,
        message: message,
        confirmText: confirmText,
      );


  Future<void> _debugActionResetSidecar() =>
      _debugActionResetSidecarImpl();


  String _buildDebugSnapshotText() => _buildDebugSnapshotTextImpl();


  Future<void> _copyDebugSnapshot() => _copyDebugSnapshotImpl();

  void _toast(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!mounted) return;
    _hudNoticeTimer?.cancel();
    setState(() {
      _hudNoticeMessage = message;
      _hudNoticeIsError = isError;
    });
    _hudNoticeTimer = Timer(duration, () {
      if (!mounted) return;
      setState(() {
        _hudNoticeMessage = null;
        _hudNoticeIsError = false;
      });
    });
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }


  Future<void> _openDebugOptionsPopup() => _openDebugOptionsPopupImpl();


  Widget _buildDriveCameraSurface() => _buildDriveCameraSurfaceImpl();


  String? _cameraCenterNoticeMessage() => _cameraCenterNoticeMessageImpl();


  Widget _buildDriveModeTag(UiWindowInfo window) =>
      _buildDriveModeTagImpl(window);


  double _computePortraitHudHeight(
    UiWindowInfo window,
    BoxConstraints constraints,
  ) => _computePortraitHudHeightImpl(window, constraints);


  Widget _buildPortraitHudPanel(UiWindowInfo window) =>
      _buildPortraitHudPanelImpl(window);


  bool _shouldHideHudForTinyViewport(
    UiWindowInfo window,
    BoxConstraints constraints, {
    required bool isLandscape,
  }) => _shouldHideHudForTinyViewportImpl(
        window,
        constraints,
        isLandscape: isLandscape,
      );


  double _computeLandscapeHudOverlaySize(
    UiWindowInfo window,
    Size drawSize,
  ) => _computeLandscapeHudOverlaySizeImpl(window, drawSize);


  Widget _buildLandscapeHudOverlay(
    UiWindowInfo window,
    Size drawSize, {
    double? overlaySize,
  }) => _buildLandscapeHudOverlayImpl(
      window,
      drawSize,
      overlaySize: overlaySize,
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
