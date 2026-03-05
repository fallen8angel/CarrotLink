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

  bool _isAnimatedPathMode(int mode) => mode >= 1 && mode <= 8;

  String get _liveCameraName =>
      _liveCameraKind == _DriveCameraKind.wideRoad ? 'wideRoad' : 'road';

  _DriveCameraKind _cameraKindFromLabel(
      String? raw, _DriveCameraKind fallback) {
    final v = (raw ?? '').trim().toLowerCase();
    if (v.isEmpty) return fallback;
    if (v == 'wideroad' || v == 'wide_road' || v == 'wide') {
      return _DriveCameraKind.wideRoad;
    }
    return _DriveCameraKind.road;
  }

  Size _sourceSizeForKind(_DriveCameraKind kind) =>
      _sourceSizeByKind[kind] ?? const Size(1928, 1208);

  void _updateSourceSize(
    Size next, {
    required _DriveCameraKind kind,
  }) {
    if (!next.width.isFinite ||
        !next.height.isFinite ||
        next.width <= 10 ||
        next.height <= 10) {
      return;
    }
    _sourceSizeByKind[kind] = next;
    if (kind != _liveCameraKind) {
      return;
    }
    _cameraSourceSize = next;
  }

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

  Future<void> _loadHudDefaultMode() async {
    final mode = await HudDriveSettingsService.getDefaultMode();
    if (!mounted) return;
    setState(() {
      _hudDefaultMode = mode;
      _hudModeLoaded = true;
    });
    _applyHudModeRuntime();
  }

  void _applyHudModeRuntime() {
    if (_openpilotOverlayMode) {
      _clearSidecarRecoverySchedule();
      _setSidecarPhase(
        _SidecarPhase.verifying,
        message: '사이드카 런타임 상태를 확인합니다.',
      );
      _startAdaptiveCameraQualityLoop();
      _suppressCameraErrors = true;
      if (mounted) {
        setState(() {
          _cameraLoading = true;
          _cameraError = null;
          _nativeCameraViewId = null;
        });
      } else {
        _cameraLoading = true;
        _cameraError = null;
        _nativeCameraViewId = null;
      }
      unawaited(_ensureSidecarRuntime(reason: 'mode_apply'));
      return;
    }
    _clearSidecarRecoverySchedule();
    _suppressCameraErrors = false;
    _setSidecarPhase(
        _residentSidecarManaged ? _SidecarPhase.idle : _SidecarPhase.stopping,
        message: _residentSidecarManaged
            ? '오픈파일럿 그래픽 모드를 종료했습니다.'
            : '오픈파일럿 그래픽 모드를 정리하는 중입니다.');
    _stopAdaptiveCameraQualityLoop(resetMode: true);
    _stopSidecarLoop();
    if (!_residentSidecarManaged) {
      unawaited(_stopSidecarProcessIfNeeded());
    }
    _applyOverlaySnapshot(
      const _DriveOverlaySnapshot.empty(),
      forceNativePush: true,
    );
    unawaited(_clearNativeOverlay());
    unawaited(_loadCameraSource(force: true));
  }

  void _handleNativeCameraEvent(dynamic event) {
    if (!_canUseNativeCamera) return;
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);
    final viewIdAny = map['viewId'];
    final viewId = viewIdAny is int
        ? viewIdAny
        : int.tryParse(viewIdAny?.toString() ?? '');
    if (_nativeCameraViewId != null &&
        viewId != null &&
        viewId != _nativeCameraViewId) {
      return;
    }
    final type = map['type']?.toString() ?? '';
    final eventCameraKind = _cameraKindFromLabel(
      map['camera']?.toString(),
      _liveCameraKind,
    );
    if (_cameraSuspendedByLifecycle && type != 'camera_state') return;
    if (type == 'camera_frame') {
      final frameId = _DriveOverlaySnapshot._asInt(map['frameId']);
      if (frameId != null) {
        _handleCameraFrameEvent(
          frameId,
          source: 'native',
          cameraKind: eventCameraKind,
        );
      }
      return;
    }
    if (type == 'camera_meta') {
      final width = _DriveOverlaySnapshot._asDouble(map['width']);
      final height = _DriveOverlaySnapshot._asDouble(map['height']);
      if (width != null &&
          height != null &&
          width.isFinite &&
          height.isFinite &&
          width > 10 &&
          height > 10) {
        final next = Size(width, height);
        final currentSize = _sourceSizeForKind(eventCameraKind);
        if ((next.width - currentSize.width).abs() > 0.5 ||
            (next.height - currentSize.height).abs() > 0.5) {
          debugPrint(
            '[DriveCanvas][native] camera_meta=${next.width.toStringAsFixed(0)}x${next.height.toStringAsFixed(0)}',
          );
          _updateSourceSize(next, kind: eventCameraKind);
        }
      }
      if (!mounted) return;
      setState(() {
        _cameraLoading = false;
        _cameraError = null;
      });
      return;
    }
    if (type == 'camera_state') {
      final state = map['state']?.toString() ?? '';
      debugPrint('[DriveCanvas][native] state=$state');
      if (!mounted) return;
      if (state == 'connected' || state.startsWith('decoder_configured')) {
        _sidecarTransitionTimer?.cancel();
        setState(() {
          _cameraLoading = false;
          _suppressCameraErrors = false;
          _cameraError = null;
        });
        _setSidecarPhase(
          _openpilotOverlayMode ? _SidecarPhase.running : _SidecarPhase.idle,
          message: '카메라 스트림 연결이 확인되었습니다.',
        );
      }
      return;
    }
    if (type == 'camera_error') {
      final reason = map['reason']?.toString().trim() ?? '';
      if (reason.isEmpty) return;
      final unsupported = reason.contains('invalid_ws_url') ||
          reason.contains('decoder_init_failed');
      if ((_sidecarTransitioning || _suppressCameraErrors) && !unsupported) {
        debugPrint('[DriveCanvas][native] suppressed error=$reason');
        return;
      }
      debugPrint('[DriveCanvas][native] error=$reason');
      if (!mounted) return;
      setState(() {
        _cameraError = '네이티브 디코더 오류: $reason';
        if (reason.contains('invalid_ws_url') ||
            reason.contains('decoder_init_failed')) {
          _nativeCameraUnsupported = true;
        }
      });
      unawaited(
        _captureCameraErrorDiagnostics(
          source: 'native',
          reason: reason,
        ),
      );
      if (_nativeCameraUnsupported) {
        unawaited(_loadCameraSource(force: true));
      }
    }
  }

  void _setOverlayVerifyMode(bool enabled) {
    if (!mounted) return;
    if (_overlayVerifyMode == enabled) return;
    setState(() {
      _overlayVerifyMode = enabled;
      if (!enabled) {
        _overlayVerifyText = '';
      }
    });
    _toast(enabled ? '정합 검증 ON' : '정합 검증 OFF');
    if (enabled && _debugShowVerifyPanel) {
      _refreshOverlayVerify(_overlayNotifier.value, force: true);
    }
  }

  void _setViewportFitMode(bool coverPreferred) {
    if (!mounted) return;
    if (_coverViewportPreferred == coverPreferred) return;
    setState(() => _coverViewportPreferred = coverPreferred);
    _toast(coverPreferred ? '크롭(cover) ON' : '레터박스(contain) ON');
  }

  void _setDebugGuides(bool enabled) {
    if (!mounted) return;
    if (_debugShowGuides == enabled) return;
    setState(() => _debugShowGuides = enabled);
    _toast(enabled ? '디버그 가이드 ON' : '디버그 가이드 OFF');
  }

  void _setDebugVerifyPanel(bool enabled) {
    if (!mounted) return;
    if (_debugShowVerifyPanel == enabled) return;
    setState(() {
      _debugShowVerifyPanel = enabled;
      if (!enabled) {
        _overlayVerifyText = '';
      }
    });
    _toast(enabled ? '우측 정보창 ON' : '우측 정보창 OFF');
    if (_overlayVerifyMode && enabled) {
      _refreshOverlayVerify(_overlayNotifier.value, force: true);
    }
  }

  void _setDebugViewportFrame(bool enabled) {
    if (!mounted) return;
    if (_debugShowViewportFrame == enabled) return;
    setState(() => _debugShowViewportFrame = enabled);
    _toast(enabled ? '레터박스 프레임 ON' : '레터박스 프레임 OFF');
  }

  Future<void> _loadHudDebugLayerToggles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const defaults = <String, bool>{
        'arOverlay': true,
        'pathFill': true,
        'laneLines': true,
        'roadEdge': true,
        'lead1': false,
        'lead2': false,
        'radarBadge': false,
        'radarVector': false,
        'stopDistanceTf': true,
        'stateText': true,
      };

      bool readBool(Map<String, dynamic> source, String key, bool fallback) {
        final value = source[key];
        if (value is bool) return value;
        if (value is num) return value != 0;
        if (value is String) {
          final norm = value.trim().toLowerCase();
          if (norm == 'true' || norm == '1') return true;
          if (norm == 'false' || norm == '0') return false;
        }
        return fallback;
      }

      void applyMap(Map<String, dynamic> map) {
        if (!mounted) {
          _debugShowArOverlay =
              readBool(map, 'arOverlay', defaults['arOverlay']!);
          _debugShowPathFill = readBool(map, 'pathFill', defaults['pathFill']!);
          _debugShowLaneLines =
              readBool(map, 'laneLines', defaults['laneLines']!);
          _debugShowRoadEdge = readBool(map, 'roadEdge', defaults['roadEdge']!);
          _debugShowLead1 = readBool(map, 'lead1', defaults['lead1']!);
          _debugShowLead2 = readBool(map, 'lead2', defaults['lead2']!);
          _debugShowRadarBadge =
              readBool(map, 'radarBadge', defaults['radarBadge']!);
          _debugShowRadarVector =
              readBool(map, 'radarVector', defaults['radarVector']!);
          _debugShowStopDistanceTf =
              readBool(map, 'stopDistanceTf', defaults['stopDistanceTf']!);
          _debugShowStateText =
              readBool(map, 'stateText', defaults['stateText']!);
          return;
        }

        setState(() {
          _debugShowArOverlay =
              readBool(map, 'arOverlay', defaults['arOverlay']!);
          _debugShowPathFill = readBool(map, 'pathFill', defaults['pathFill']!);
          _debugShowLaneLines =
              readBool(map, 'laneLines', defaults['laneLines']!);
          _debugShowRoadEdge = readBool(map, 'roadEdge', defaults['roadEdge']!);
          _debugShowLead1 = readBool(map, 'lead1', defaults['lead1']!);
          _debugShowLead2 = readBool(map, 'lead2', defaults['lead2']!);
          _debugShowRadarBadge =
              readBool(map, 'radarBadge', defaults['radarBadge']!);
          _debugShowRadarVector =
              readBool(map, 'radarVector', defaults['radarVector']!);
          _debugShowStopDistanceTf =
              readBool(map, 'stopDistanceTf', defaults['stopDistanceTf']!);
          _debugShowStateText =
              readBool(map, 'stateText', defaults['stateText']!);
        });
      }

      final initialized =
          prefs.getBool(_hudDebugLayerTogglesInitPrefKey) ?? false;
      if (!initialized) {
        applyMap(Map<String, dynamic>.from(defaults));
        await prefs.setString(
            _hudDebugLayerTogglesPrefKey, jsonEncode(defaults));
        await prefs.setBool(_hudDebugLayerTogglesInitPrefKey, true);
        return;
      }

      final raw = prefs.getString(_hudDebugLayerTogglesPrefKey);
      if (raw == null || raw.trim().isEmpty) {
        applyMap(Map<String, dynamic>.from(defaults));
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        applyMap(Map<String, dynamic>.from(defaults));
        return;
      }
      applyMap(Map<String, dynamic>.from(decoded));
    } catch (_) {}
  }

  Future<void> _saveHudDebugLayerToggles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, bool>{
        'arOverlay': _debugShowArOverlay,
        'pathFill': _debugShowPathFill,
        'laneLines': _debugShowLaneLines,
        'roadEdge': _debugShowRoadEdge,
        'lead1': _debugShowLead1,
        'lead2': _debugShowLead2,
        'radarBadge': _debugShowRadarBadge,
        'radarVector': _debugShowRadarVector,
        'stopDistanceTf': _debugShowStopDistanceTf,
        'stateText': _debugShowStateText,
      };
      await prefs.setString(_hudDebugLayerTogglesPrefKey, jsonEncode(payload));
      await prefs.setBool(_hudDebugLayerTogglesInitPrefKey, true);
    } catch (_) {}
  }

  void _onLayerToggleChanged(StateSetter setLocalState, VoidCallback update) {
    setState(update);
    setLocalState(() {});
    unawaited(_saveHudDebugLayerToggles());
  }

  void _clearSidecarRecoverySchedule() {
    _sidecarRecoveryTimer?.cancel();
    _sidecarRecoveryTimer = null;
    _sidecarRecoveryNextAt = null;
    _sidecarRecoveryBackoffSeconds = 1;
  }

  void _scheduleSidecarRuntimeRecovery({
    required String reason,
    Duration minDelay = const Duration(milliseconds: 600),
  }) {
    if (!_openpilotOverlayMode || _cameraSuspendedByLifecycle) return;
    final now = DateTime.now();
    if (_sidecarRecoveryNextAt != null &&
        now.isBefore(_sidecarRecoveryNextAt!)) {
      return;
    }
    final backoff = Duration(seconds: _sidecarRecoveryBackoffSeconds);
    final delay = backoff > minDelay ? backoff : minDelay;
    _sidecarRecoveryNextAt = now.add(delay);
    _sidecarRecoveryTimer?.cancel();
    _pushSidecarHistory(
      'AUTO_RECOVER',
      'scheduled ${delay.inMilliseconds}ms reason=$reason',
    );
    _sidecarRecoveryTimer = Timer(delay, () {
      _sidecarRecoveryTimer = null;
      _sidecarRecoveryNextAt = null;
      unawaited(_ensureSidecarRuntime(reason: 'recover:$reason'));
    });
    _sidecarRecoveryBackoffSeconds =
        math.min(_sidecarRecoveryBackoffSeconds * 2, 8);
  }

  void _handleCameraJsMessage(String raw) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final map = Map<String, dynamic>.from(decoded);
    final type = map['type']?.toString() ?? '';
    final eventCameraKind = _cameraKindFromLabel(
      map['camera']?.toString(),
      _liveCameraKind,
    );
    if (_cameraSuspendedByLifecycle) return;
    if (type == 'camera_frame') {
      final frameId = _DriveOverlaySnapshot._asInt(map['frameId']);
      if (frameId != null) {
        _handleCameraFrameEvent(
          frameId,
          source: 'web',
          cameraKind: eventCameraKind,
        );
      }
      return;
    }
    if (type == 'camera_meta') {
      final width = _DriveOverlaySnapshot._asDouble(map['width']);
      final height = _DriveOverlaySnapshot._asDouble(map['height']);
      if (width == null || height == null) return;
      if (!width.isFinite || !height.isFinite) return;
      if (width < 10 || height < 10) return;
      final next = Size(width, height);
      final currentSize = _sourceSizeForKind(eventCameraKind);
      if ((next.width - currentSize.width).abs() < 0.5 &&
          (next.height - currentSize.height).abs() < 0.5) {
        return;
      }
      if (!mounted) {
        _updateSourceSize(next, kind: eventCameraKind);
        return;
      }
      debugPrint(
        '[DriveCanvas] camera_meta=${next.width.toStringAsFixed(0)}x${next.height.toStringAsFixed(0)}',
      );
      setState(() {
        _updateSourceSize(next, kind: eventCameraKind);
      });
      return;
    }
    if (type == 'camera_error') {
      final reason = map['reason']?.toString().trim() ?? '';
      if (reason.isEmpty || !mounted) return;
      if (_sidecarTransitioning || _suppressCameraErrors) {
        debugPrint('[DriveCanvas] suppressed camera_error reason=$reason');
        return;
      }
      debugPrint('[DriveCanvas] camera_error reason=$reason');
      setState(() => _cameraError = '카메라 디코더 오류: $reason');
      unawaited(
        _captureCameraErrorDiagnostics(
          source: 'web',
          reason: reason,
        ),
      );
      return;
    }
    if (type == 'camera_timeline_ready') {
      return;
    }
  }

  String _overlayPreviewScenarioLabel(_OverlayPreviewScenario scenario) {
    switch (scenario) {
      case _OverlayPreviewScenario.highwayStraight:
        return '직선 주행';
      case _OverlayPreviewScenario.gentleLeft:
        return '완만 좌회전';
      case _OverlayPreviewScenario.gentleRight:
        return '완만 우회전';
      case _OverlayPreviewScenario.traffic:
        return '정체/근접 리드';
    }
  }

  void _setOverlayPreviewMode(bool enabled) {
    if (_debugOverlayPreviewMode == enabled) return;
    if (mounted) {
      setState(() {
        _debugOverlayPreviewMode = enabled;
        _cameraLoading = false;
        _cameraError = null;
        if (enabled) {
          // Preview intent: show all overlay layers by default.
          _debugShowPathFill = true;
          _debugShowLaneLines = true;
          _debugShowRoadEdge = true;
          _debugShowLead1 = true;
          _debugShowLead2 = true;
          _debugShowRadarBadge = true;
          _debugShowRadarVector = true;
          _debugShowStopDistanceTf = true;
          _debugShowStateText = true;
        }
      });
    } else {
      _debugOverlayPreviewMode = enabled;
      _cameraLoading = false;
      _cameraError = null;
      if (enabled) {
        _debugShowPathFill = true;
        _debugShowLaneLines = true;
        _debugShowRoadEdge = true;
        _debugShowLead1 = true;
        _debugShowLead2 = true;
        _debugShowRadarBadge = true;
        _debugShowRadarVector = true;
        _debugShowStopDistanceTf = true;
        _debugShowStateText = true;
      }
    }

    if (enabled) {
      _startOverlayPreviewLoop();
      _toast('프리뷰 모드 활성화 (실데이터 없이 그래픽 확인)');
      return;
    }

    _stopOverlayPreviewLoop();
    if (_openpilotOverlayMode && _latestOverlaySnapshot.path.length >= 2) {
      _applyOverlaySnapshot(_latestOverlaySnapshot, forceNativePush: true);
    } else {
      _applyOverlaySnapshot(
        const _DriveOverlaySnapshot.empty(),
        forceNativePush: true,
      );
    }
    _toast('프리뷰 모드 비활성화');
  }

  void _startOverlayPreviewLoop() {
    _overlayPreviewTimer?.cancel();
    _overlayPreviewFrameSeq = 0;
    _tickOverlayPreview();
    _overlayPreviewTimer =
        Timer.periodic(const Duration(milliseconds: 90), (_) {
      _tickOverlayPreview();
    });
  }

  void _stopOverlayPreviewLoop() {
    _overlayPreviewTimer?.cancel();
    _overlayPreviewTimer = null;
  }

  void _tickOverlayPreview() {
    if (!_debugOverlayPreviewMode) return;
    _overlayPreviewFrameSeq += 1;
    final next = _buildOverlayPreviewSnapshot(seq: _overlayPreviewFrameSeq);
    _latestOverlaySnapshot = next;
    _applyOverlaySnapshot(next, forceNativePush: true);
    _sidecarLastFrameAt = DateTime.now();
    if (_overlayDebugWindowStartMs <= 0) {
      _overlayDebugWindowStartMs = DateTime.now().millisecondsSinceEpoch - 500;
    }
  }

  List<List<double>> _previewRoadPathVertices({
    required int sourceWidth,
    required int sourceHeight,
    required double t,
  }) {
    final horizon = sourceHeight * 0.34;
    double curveAmp;
    switch (_debugOverlayPreviewScenario) {
      case _OverlayPreviewScenario.highwayStraight:
        curveAmp = 0.0;
      case _OverlayPreviewScenario.gentleLeft:
        curveAmp = -220.0;
      case _OverlayPreviewScenario.gentleRight:
        curveAmp = 220.0;
      case _OverlayPreviewScenario.traffic:
        curveAmp = 40.0;
    }
    final pointsLeft = <List<double>>[];
    final pointsRight = <List<double>>[];
    for (var i = 0; i < 18; i++) {
      final u = i / 17.0; // 0 (near) -> 1 (far)
      final y = (sourceHeight - 14.0) - (u * (sourceHeight - horizon - 14.0));
      final center = (sourceWidth * 0.5) +
          (curveAmp * u * u) +
          (math.sin(t + (u * 2.2)) *
              (_debugOverlayPreviewScenario == _OverlayPreviewScenario.traffic
                  ? 18.0
                  : 8.0));
      final halfW = ((1.0 - u) * 300.0 + 58.0).clamp(58.0, 300.0).toDouble();
      pointsLeft.add(<double>[center - halfW, y]);
      pointsRight.add(<double>[center + halfW, y]);
    }
    return <List<double>>[
      ...pointsLeft,
      ...pointsRight.reversed,
    ];
  }

  List<List<double>> _previewLanePolygon({
    required int sourceWidth,
    required int sourceHeight,
    required double t,
    required double laneFactor,
    required double thickness,
  }) {
    final horizon = sourceHeight * 0.34;
    double curveAmp;
    switch (_debugOverlayPreviewScenario) {
      case _OverlayPreviewScenario.highwayStraight:
        curveAmp = 0.0;
      case _OverlayPreviewScenario.gentleLeft:
        curveAmp = -220.0;
      case _OverlayPreviewScenario.gentleRight:
        curveAmp = 220.0;
      case _OverlayPreviewScenario.traffic:
        curveAmp = 40.0;
    }
    final left = <List<double>>[];
    final right = <List<double>>[];
    for (var i = 0; i < 15; i++) {
      final u = i / 14.0;
      final y = (sourceHeight - 14.0) - (u * (sourceHeight - horizon - 14.0));
      final center = (sourceWidth * 0.5) +
          (curveAmp * u * u) +
          (math.sin(t + (u * 2.2)) *
              (_debugOverlayPreviewScenario == _OverlayPreviewScenario.traffic
                  ? 18.0
                  : 8.0));
      final halfW = ((1.0 - u) * 300.0 + 58.0).clamp(58.0, 300.0).toDouble();
      final laneX = center + (halfW * laneFactor);
      left.add(<double>[laneX - (thickness * 0.5), y]);
      right.add(<double>[laneX + (thickness * 0.5), y]);
    }
    return <List<double>>[
      ...left,
      ...right.reversed,
    ];
  }

  _DriveOverlaySnapshot _buildOverlayPreviewSnapshot({required int seq}) {
    const sourceW = 1928;
    const sourceH = 1208;
    final t = seq * 0.05 * _debugOverlayPreviewSpeed;
    final pathVertices = _previewRoadPathVertices(
      sourceWidth: sourceW,
      sourceHeight: sourceH,
      t: t,
    );
    final leadNear =
        _debugOverlayPreviewScenario == _OverlayPreviewScenario.traffic;
    final leadU = leadNear ? 0.58 : 0.72;
    const horizon = sourceH * 0.34;
    double curveAmp;
    switch (_debugOverlayPreviewScenario) {
      case _OverlayPreviewScenario.highwayStraight:
        curveAmp = 0.0;
      case _OverlayPreviewScenario.gentleLeft:
        curveAmp = -220.0;
      case _OverlayPreviewScenario.gentleRight:
        curveAmp = 220.0;
      case _OverlayPreviewScenario.traffic:
        curveAmp = 40.0;
    }
    final leadY = (sourceH - 14.0) - (leadU * (sourceH - horizon - 14.0));
    final leadCenterX = (sourceW * 0.5) +
        (curveAmp * leadU * leadU) +
        (math.sin(t + (leadU * 2.2)) *
            (_debugOverlayPreviewScenario == _OverlayPreviewScenario.traffic
                ? 18.0
                : 8.0));
    final leadHalfW = (((1.0 - leadU) * 180.0) + (leadNear ? 130.0 : 92.0))
        .clamp(80.0, 180.0)
        .toDouble();
    final leadTop = leadY - (leadHalfW * 0.55);
    final leadBox = <List<double>>[
      <double>[leadCenterX - leadHalfW, leadTop],
      <double>[leadCenterX + leadHalfW, leadTop],
      <double>[leadCenterX + leadHalfW, leadY],
      <double>[leadCenterX - leadHalfW, leadY],
    ];
    final badgeDx = (leadHalfW * 0.88).clamp(58.0, 150.0).toDouble();
    final badgeDy = (leadHalfW * 0.56).clamp(44.0, 98.0).toDouble();
    final leadTwoHalfW = (leadHalfW * 0.72).clamp(56.0, 130.0).toDouble();
    final leadTwoCenterX = leadCenterX - (leadHalfW * 1.7);
    final leadTwoY = leadY + (leadHalfW * 0.32);
    final leadTwoTop = leadTwoY - (leadTwoHalfW * 0.58);
    final leadTwoBox = <List<double>>[
      <double>[leadTwoCenterX - leadTwoHalfW, leadTwoTop],
      <double>[leadTwoCenterX + leadTwoHalfW, leadTwoTop],
      <double>[leadTwoCenterX + leadTwoHalfW, leadTwoY],
      <double>[leadTwoCenterX - leadTwoHalfW, leadTwoY],
    ];
    final leadDist = leadNear ? 11.8 : 16.5;
    final visionDist = leadNear ? 12.5 : 17.7;
    final speedKph =
        _debugOverlayPreviewScenario == _OverlayPreviewScenario.traffic
            ? 28.0
            : 64.0;

    final sidecarOverlay2d = <String, dynamic>{
      'version': 1,
      'source': 'preview_mock',
      'cameraMode': 'road',
      'cameras': <String, dynamic>{
        'road': <String, dynamic>{
          'camera': 'road',
          'sourceWidth': sourceW.toDouble(),
          'sourceHeight': sourceH.toDouble(),
          'displayTransform': <String, dynamic>{
            'zoom': 1.0,
            'tx': 0.0,
            'ty': 0.0,
            'xOffset': 0.0,
            'yOffset': 0.0,
          },
          'modelFrameId': seq,
          'cameraFrameId': seq,
          'pathMode': 0,
          'pathColor': 3,
          'pathTrackVertices': pathVertices,
          'lanePolygons': <Map<String, dynamic>>[
            <String, dynamic>{
              'index': 1,
              'probability': 0.98,
              'points': _previewLanePolygon(
                sourceWidth: sourceW,
                sourceHeight: sourceH,
                t: t,
                laneFactor: -0.92,
                thickness: 9.0,
              ),
            },
            <String, dynamic>{
              'index': 2,
              'probability': 0.98,
              'points': _previewLanePolygon(
                sourceWidth: sourceW,
                sourceHeight: sourceH,
                t: t,
                laneFactor: 0.92,
                thickness: 9.0,
              ),
            },
          ],
          'roadEdgePolygons': const <Map<String, dynamic>>[],
          'leadAreaBoxes': <Map<String, dynamic>>[
            <String, dynamic>{
              'kind': 'leadOne',
              'points': leadBox,
              'radar': true,
              'radarTrackId': 2,
              'status': 1,
              'radarDistance': leadDist,
              'visionDistance': visionDist,
              'anchorCenter': <double>[leadCenterX, leadY],
              'anchorWidth': leadHalfW * 2.0,
              'radarBadgeCenter': <double>[
                leadCenterX - badgeDx,
                leadY + badgeDy
              ],
              'visionBadgeCenter': <double>[
                leadCenterX + badgeDx,
                leadY + badgeDy
              ],
              'stateTextCenter': <double>[
                leadCenterX,
                leadY + (badgeDy * 1.28)
              ],
              'strokeColorArgb': 0xFFFFA726,
              'fillColorArgb': 0x33000000,
              'radarBadgeColorArgb': 0xFFFF3B30,
              'visionBadgeColorArgb': 0xFF3D7BFF,
            },
            <String, dynamic>{
              'kind': 'leadTwo',
              'points': leadTwoBox,
              'radar': true,
              'radarTrackId': 12,
              'status': 1,
              'radarDistance': leadDist + 3.4,
              'anchorCenter': <double>[leadTwoCenterX, leadTwoY],
              'anchorWidth': leadTwoHalfW * 2.0,
              'strokeColorArgb': 0xFFB68A3A,
              'fillColorArgb': 0x33000000,
            },
          ],
          'radarTargets': <Map<String, dynamic>>[
            <String, dynamic>{
              'center': <double>[
                leadCenterX + (leadHalfW * 1.05),
                leadY + 20.0
              ],
              'speedMpsSigned': 4.9,
              'speedKphSigned': 17.6,
              'dRel': leadDist,
              'yRel': 0.1,
              'radar': true,
              'modelProb': 0.70,
              'future': <double>[
                leadCenterX + (leadHalfW * 1.18),
                leadY - 36.0
              ],
            },
            <String, dynamic>{
              'center': <double>[
                leadCenterX - (leadHalfW * 1.55),
                leadY + 14.0
              ],
              'speedMpsSigned': -5.6,
              'speedKphSigned': -20.1,
              'dRel': leadDist + 1.7,
              'yRel': -1.4,
              'radar': true,
              'modelProb': 0.82,
              'future': <double>[
                leadCenterX - (leadHalfW * 1.42),
                leadY - 20.0
              ],
            },
          ],
          'tfMarker': <String, dynamic>{
            'points': <List<double>>[
              <double>[leadCenterX - (leadHalfW * 0.7), leadY + 12.0],
              <double>[leadCenterX + (leadHalfW * 0.7), leadY + 12.0],
            ],
            'distance': leadDist,
            'tFollow': 1.20,
          },
          'meta': <String, dynamic>{
            'showRadarInfo': 3,
            'xState': 0,
            'trafficState': 0,
            'longActive': true,
            'vEgoMps': speedKph / 3.6,
            'brakeLights': false,
            'tFollow': 1.20,
            'desiredDistance': leadDist,
          },
        },
      },
    };
    sidecarOverlay2d['cameras']['wideRoad'] =
        sidecarOverlay2d['cameras']['road'];

    return _DriveOverlaySnapshot(
      path: const _XyzSeries(
        x: <double>[0, 5, 10, 15, 20, 30, 40, 60, 80],
        y: <double>[0, 0, 0, 0, 0, 0, 0, 0, 0],
        z: <double>[1.22, 1.22, 1.22, 1.22, 1.22, 1.22, 1.22, 1.22, 1.22],
      ),
      laneLines: const <_LaneLineSeries>[],
      roadEdges: const <_RoadEdgeSeries>[],
      active: true,
      activeLaneLine: true,
      carrotExperimentalMode: false,
      brakeLights: false,
      leadDetected: true,
      pathMode: 0,
      pathColor: 3,
      accel0: 0.0,
      aEgo: 0.0,
      speedMps: speedKph / 3.6,
      speedKph: speedKph,
      leftLaneLine: 20,
      rightLaneLine: 20,
      calibrationRpy: const <double>[0.0, 0.0, 0.0],
      wideFromDeviceEuler: const <double>[0.0, 0.0, 0.0],
      pathOffsetZ: 1.22,
      pathWidthRatio: 1.0,
      animationPhase: _pathAnimationPhase,
      modelFrameId: seq,
      roadFrameId: seq,
      wideRoadFrameId: seq,
      sidecarOverlay2d: sidecarOverlay2d,
      usingLateralPath: false,
      modelPathXMax: 80.0,
      lateralPathXMax: 0.0,
      navPathPoints: const <_NavPathPoint>[
        _NavPathPoint(x: 8.0, y: 0.0, d: 8.0),
        _NavPathPoint(x: 14.0, y: 0.2, d: 14.0),
        _NavPathPoint(x: 22.0, y: 0.6, d: 22.0),
        _NavPathPoint(x: 32.0, y: 1.3, d: 32.0),
      ],
      navTurnInfo: 2,
      navDistToTurn: 230.0,
      navMainText: '우회전',
    );
  }

  Widget _buildOverlayPreviewBackdrop() {
    return const CustomPaint(
      painter: _PreviewRoadBackdropPainter(),
      child: SizedBox.expand(),
    );
  }

  Future<void> _restorePortraitOrientation() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }

  Future<void> _setDisplayHighRefreshPreference(
    bool enabled, {
    required String reason,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final response =
          await _displayTuningChannel.invokeMapMethod<String, dynamic>(
        'setHighRefreshPreferred',
        <String, dynamic>{'enabled': enabled},
      );
      final appliedHz = (response?['refreshRate'] as num?)?.toDouble();
      debugPrint(
        '[DriveCanvas][display] high_refresh=$enabled reason=$reason hz=${appliedHz?.toStringAsFixed(1) ?? '-'}',
      );
    } on MissingPluginException {
      // Older builds may not expose display tuning channel yet.
    } catch (e) {
      debugPrint(
        '[DriveCanvas][display] high refresh preference failed: $e',
      );
    }
  }

  Future<void> _enableScreenAwake() async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  Future<void> _disableScreenAwake() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }

  Future<void> _loadAndApplyLandscapeOrientation() async {
    // Drive screen only: allow portrait + landscape while this screen is active.
    await _lockLandscapeOrientations();
  }

  Future<bool> _isSidecarBootstrapDone() async {
    if (_sidecarBootstrapDone != null) return _sidecarBootstrapDone!;
    try {
      final prefs = await SharedPreferences.getInstance();
      _sidecarBootstrapDone =
          prefs.getBool(_sidecarBootstrapDonePrefKey) ?? false;
    } catch (_) {
      _sidecarBootstrapDone ??= false;
    }
    return _sidecarBootstrapDone ?? false;
  }

  Future<void> _setSidecarBootstrapDone(bool value) async {
    _sidecarBootstrapDone = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_sidecarBootstrapDonePrefKey, value);
    } catch (_) {}
  }

  String _shortSidecarRevision(String? revision) {
    return _sidecarService.shortRevision(revision);
  }

  Future<void> _notifySidecarRevisionUpdated(String revision) async {
    final normalized = revision.trim();
    if (normalized.isEmpty) return;
    var shouldNotify = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '${widget.hostIp}:$normalized';
      final prev = prefs.getString(_sidecarRevisionNotifiedPrefKey);
      if (prev == key) {
        shouldNotify = false;
      } else {
        await prefs.setString(_sidecarRevisionNotifiedPrefKey, key);
      }
    } catch (_) {}
    if (!shouldNotify) return;
    _toast(
      '사이드카 업데이트됨 (sha256:${_shortSidecarRevision(normalized)})',
      duration: const Duration(seconds: 4),
    );
  }

  Future<void> _ensureSidecarRevisionUpToDate(SSHService ssh) async {
    final localRevision = await _sidecarService.localRevision();
    final remoteRevision = await _sidecarService.remoteRevision(ssh);
    _sidecarLocalRevision = localRevision;
    _sidecarRemoteRevision = remoteRevision;
    _sidecarLastRevisionCheckedAt = DateTime.now();

    if (remoteRevision == localRevision) {
      _sidecarRevisionAction = 'match';
      return;
    }

    _sidecarRevisionAction = 'mismatch';
    _pushSidecarHistory(
      'AUTO_REV',
      'mismatch local=${_shortSidecarRevision(localRevision)} remote=${_shortSidecarRevision(remoteRevision)}',
    );
    _setSidecarPhase(
      _SidecarPhase.deploying,
      message: '사이드카 업데이트 중...',
    );

    await _sidecarService.deploy(ssh);
    _sidecarLastDeployAt = DateTime.now();
    _sidecarLastDeployResult = 'success';

    final remoteAfter = await _sidecarService.remoteRevision(ssh);
    _sidecarRemoteRevision = remoteAfter;
    _sidecarLastRevisionCheckedAt = DateTime.now();
    if (remoteAfter != localRevision) {
      _sidecarRevisionAction = 'verify_fail';
      throw Exception(
        '사이드카 업데이트 검증 실패(local=${_shortSidecarRevision(localRevision)} remote=${_shortSidecarRevision(remoteAfter)})',
      );
    }

    _sidecarRevisionAction = 'updated';
    _pushSidecarHistory(
      'AUTO_REV',
      'updated rev=${_shortSidecarRevision(localRevision)}',
    );
    await _notifySidecarRevisionUpdated(localRevision);
  }

  bool _isSidecarDeployMissingError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('sidecar_not_deployed') ||
        message.contains('missing sidecar') ||
        message.contains('not deployed') ||
        message.contains('no such file');
  }

  Future<bool> _tryAutoBootstrapSidecar(
    SSHService ssh, {
    required Object startError,
  }) async {
    if (!_isSidecarDeployMissingError(startError)) return false;
    _sidecarLastBootstrapAt = DateTime.now();
    _sidecarLastBootstrapDetail = startError.toString();
    _sidecarLastBootstrapResult = 'pending';
    final done = await _isSidecarBootstrapDone();
    if (done) {
      // If device wiped sidecar files after bootstrap, allow one recovery deploy.
      _pushSidecarHistory('AUTO_BOOTSTRAP', 'recovery deploy requested');
    } else {
      _pushSidecarHistory('AUTO_BOOTSTRAP', 'first-run deploy requested');
    }
    _setSidecarPhase(
      _SidecarPhase.deploying,
      message: '사이드카 최초 설정을 적용하는 중...',
    );
    try {
      await _sidecarService.deploy(ssh);
      _sidecarLastDeployAt = DateTime.now();
      _sidecarLastDeployResult = 'success';
      _sidecarLastBootstrapAt = DateTime.now();
      _sidecarLastBootstrapResult = 'success';
      _sidecarLastBootstrapDetail = done
          ? 'recovery deploy (missing sidecar detected)'
          : 'first-run deploy';
      await _setSidecarBootstrapDone(true);
      _pushSidecarHistory('AUTO_BOOTSTRAP', 'deploy ok');
      return true;
    } catch (e) {
      _sidecarLastDeployResult = 'fail';
      _sidecarLastBootstrapAt = DateTime.now();
      _sidecarLastBootstrapResult = 'fail';
      _sidecarLastBootstrapDetail = e.toString();
      _pushSidecarHistory('AUTO_BOOTSTRAP_FAIL', '$e');
      return false;
    }
  }

  Future<void> _lockLandscapeOrientations() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _exitScreen() async {
    await _restorePortraitOrientation();
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

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

  String _buildLiveCameraHtml(_DriveCameraKind cameraKind) {
    final streamEndpoints = jsonEncode(
      _streamEndpointCandidates.map((u) => u.toString()).toList(),
    );
    final cameraName =
        cameraKind == _DriveCameraKind.wideRoad ? 'wideRoad' : 'road';
    final directWsUrl = 'ws://${widget.hostIp}:7766/ws/camera/$cameraName';
    final modePolicy = _openpilotOverlayMode ? 'sidecar_only' : 'webrtc_only';
    return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no" />
  <style>
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background: #000;
      overflow: hidden;
    }
    #root {
      position: fixed;
      inset: 0;
      width: 100vw;
      height: 100vh;
      background: #000;
      overflow: hidden;
    }
    #c {
      position: fixed;
      left: 0;
      top: 0;
      width: 100vw;
      height: 100vh;
      display: block;
      background: #000;
      z-index: 1;
      backface-visibility: hidden;
      transform: translateZ(0);
      will-change: transform;
    }
    #v {
      position: fixed;
      inset: 0;
      width: 100vw;
      height: 100vh;
      object-fit: cover;
      display: none;
      background: #000;
      z-index: 2;
      backface-visibility: hidden;
      transform: translateZ(0);
      will-change: transform;
    }
  </style>
</head>
<body>
  <div id="root">
    <canvas id="c"></canvas>
    <video id="v" autoplay playsinline muted></video>
  </div>
  <script>
    const DIRECT_WS_URL = ${jsonEncode(directWsUrl)};
    const CAMERA_NAME = ${jsonEncode(cameraName)};
    const STREAM_ENDPOINTS = $streamEndpoints;
    const CODEC_CANDIDATES = ['avc1.640028', 'avc1.64001f', 'avc1.4d401f', 'avc1.42e01f', 'avc1.42e01e'];
    const MODE_POLICY = ${jsonEncode(modePolicy)};
    const ALLOW_DIRECT = MODE_POLICY === 'sidecar_only';
    const ALLOW_WEBRTC = MODE_POLICY === 'webrtc_only';
    const ENABLE_SHARPEN = ${_webCameraSharpenEnabled ? 'true' : 'false'};

    const canvas = document.getElementById('c');
    const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
    const video = document.getElementById('v');
    const DEVICE_MEMORY_GB = Number(navigator.deviceMemory || 0);
    const CPU_THREADS = Number(navigator.hardwareConcurrency || 0);

    let ws = null;
    let pc = null;
    let decoder = null;
    let decoderCodec = '';
    let waitingKey = true;
    let gotFrame = false;
    let watchdog = null;
    let reconnectTimer = null;
    let directProbeTimer = null;
    let mode = ALLOW_DIRECT ? 'direct' : 'webrtc';
    let directErrorCount = 0;
    let webCodecsUnsupported = false;
    let lastDirectFrameId = -1;
    let droppedOutdated = 0;
    let droppedQueue = 0;
    let sourceW = 0;
    let sourceH = 0;
    let lastCameraFramePosted = -1;
    let renderDpr = 1.0;
    const pendingFrameIds = [];

    function computeRenderDpr() {
      const base = Number(window.devicePixelRatio || 1);
      let cap = 1.12;
      if (CPU_THREADS >= 8 || DEVICE_MEMORY_GB >= 6) {
        cap = 1.45;
      } else if (CPU_THREADS >= 6 || DEVICE_MEMORY_GB >= 4) {
        cap = 1.30;
      } else if (CPU_THREADS >= 4 || DEVICE_MEMORY_GB >= 3) {
        cap = 1.20;
      }
      return Math.max(1.0, Math.min(base, cap));
    }

    function applySharpenFilter() {
      if (!ENABLE_SHARPEN) {
        canvas.style.filter = 'none';
        return;
      }
      const applyBoost = renderDpr <= 1.24;
      if (!applyBoost) {
        canvas.style.filter = 'none';
        return;
      }
      canvas.style.filter = 'contrast(1.05) saturate(1.04) brightness(1.01)';
    }

    function resizeCanvas() {
      const cssW = Math.max(1, window.innerWidth || 1);
      const cssH = Math.max(1, window.innerHeight || 1);
      renderDpr = computeRenderDpr();
      const pixelW = Math.max(1, Math.round(cssW * renderDpr));
      const pixelH = Math.max(1, Math.round(cssH * renderDpr));
      if (canvas.width !== pixelW) canvas.width = pixelW;
      if (canvas.height !== pixelH) canvas.height = pixelH;
      canvas.style.width = cssW + 'px';
      canvas.style.height = cssH + 'px';
      try { ctx.imageSmoothingEnabled = true; } catch (_) {}
      try { ctx.imageSmoothingQuality = renderDpr > 1.25 ? 'medium' : 'high'; } catch (_) {}
      applySharpenFilter();
    }

    function setMode(next) {
      mode = next;
      if (next === 'direct') {
        canvas.style.display = 'block';
        video.style.display = 'none';
        try { video.pause(); } catch (_) {}
      } else {
        canvas.style.display = 'none';
        video.style.display = 'block';
      }
    }

    function postToFlutter(payload) {
      try {
        if (window.CarrotCamera && typeof window.CarrotCamera.postMessage === 'function') {
          window.CarrotCamera.postMessage(JSON.stringify(payload));
        }
      } catch (_) {}
    }

    function payloadWithCamera(payload) {
      if (!payload || typeof payload !== 'object') return payload;
      return Object.assign({ camera: CAMERA_NAME }, payload);
    }

    function publishSourceSize(width, height) {
      if (!Number.isFinite(width) || !Number.isFinite(height)) return;
      if (width <= 0 || height <= 0) return;
      if (sourceW === width && sourceH === height) return;
      sourceW = width;
      sourceH = height;
      postToFlutter(payloadWithCamera({ type: 'camera_meta', width, height }));
    }

    function publishCameraFrame(frameId) {
      if (!Number.isFinite(frameId) || frameId < 0) return;
      if (frameId <= lastCameraFramePosted) return;
      lastCameraFramePosted = frameId;
      postToFlutter(payloadWithCamera({ type: 'camera_frame', frameId: frameId }));
    }

    function drawFrameCover(frame) {
      const sw = Math.max(1, Number(frame.displayWidth || frame.codedWidth || 0));
      const sh = Math.max(1, Number(frame.displayHeight || frame.codedHeight || 0));
      publishSourceSize(sw, sh);

      const cw = Math.max(1, canvas.width);
      const ch = Math.max(1, canvas.height);
      const scale = Math.max(cw / sw, ch / sh);
      const dw = sw * scale;
      const dh = sh * scale;
      const dx = (cw - dw) * 0.5;
      const dy = (ch - dh) * 0.5;

      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, cw, ch);
      try {
        ctx.drawImage(frame, dx, dy, dw, dh);
      } finally {
        try { frame.close(); } catch (_) {}
      }
    }

    function clearReconnect() {
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
    }

    function clearDirectProbe() {
      if (directProbeTimer) {
        clearTimeout(directProbeTimer);
        directProbeTimer = null;
      }
    }

    function scheduleDirectProbe(ms) {
      if (!ALLOW_DIRECT) return;
      clearDirectProbe();
      if (webCodecsUnsupported) return;
      directProbeTimer = setTimeout(() => {
        directProbeTimer = null;
        if (mode === 'webrtc' && ALLOW_DIRECT) {
          connectDirect().catch(() => {});
        }
      }, ms || 8000);
    }

    function scheduleReconnect(ms) {
      clearReconnect();
      reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        if (mode === 'direct' && ALLOW_DIRECT) {
          connectDirect().catch(() => {});
        } else if (ALLOW_WEBRTC) {
          connectWebRtc().catch(() => {});
        } else if (ALLOW_DIRECT) {
          connectDirect().catch(() => {});
        }
      }, ms || 900);
    }

    function clearWatchdog() {
      if (watchdog) {
        clearTimeout(watchdog);
        watchdog = null;
      }
    }

    function armWatchdog() {
      if (!ALLOW_DIRECT) return;
      clearWatchdog();
      watchdog = setTimeout(() => {
        if (!gotFrame && mode === 'direct' && ALLOW_DIRECT) {
          postToFlutter(payloadWithCamera({ type: 'camera_error', reason: 'no_frames' }));
          if (ALLOW_WEBRTC) {
            fallbackToWebRtc('no_frames');
          } else {
            scheduleReconnect(900);
          }
        }
      }, 4500);
    }

    function cleanupSocket() {
      clearWatchdog();
      try { if (ws) ws.close(); } catch (_) {}
      ws = null;
    }

    function cleanupPc() {
      try { if (pc) pc.close(); } catch (_) {}
      pc = null;
      try { video.srcObject = null; } catch (_) {}
    }

    function normalizeTimestamp(rawTs) {
      let ts = Number(rawTs || 0);
      if (!Number.isFinite(ts) || ts <= 0) {
        ts = performance.now() * 1000.0;
      } else if (ts > 1000000000000000) {
        ts = ts / 1000.0;
      } else if (ts > 1000000000000) {
        // microseconds scale already
      } else if (ts > 1000000000) {
        ts = ts * 1000.0;
      } else {
        ts = ts * 1000000.0;
      }
      return Math.max(0, Math.floor(ts));
    }

    function closeDecoder() {
      if (!decoder) return;
      try { decoder.close(); } catch (_) {}
      decoder = null;
      decoderCodec = '';
      waitingKey = true;
      lastDirectFrameId = -1;
      pendingFrameIds.length = 0;
    }

    function parseFramePacket(buf) {
      if (!buf || buf.byteLength < 5) return null;
      const view = new DataView(buf);
      const metaLen = view.getUint32(0, false);
      if (metaLen < 2 || metaLen > 65536) return null;
      const offset = 4 + metaLen;
      if (offset >= buf.byteLength) return null;
      try {
        const metaBytes = new Uint8Array(buf, 4, metaLen);
        const metaText = new TextDecoder().decode(metaBytes);
        const meta = JSON.parse(metaText);
        const data = new Uint8Array(buf, offset);
        if (!data || data.length === 0) return null;
        return { meta, data };
      } catch (_) {
        return null;
      }
    }

    function hasStartCode(data) {
      const n = data.length;
      for (let i = 0; i + 3 < n; i++) {
        if (data[i] === 0 && data[i + 1] === 0) {
          if (data[i + 2] === 1) return true;
          if (data[i + 2] === 0 && data[i + 3] === 1) return true;
        }
      }
      return false;
    }

    function concatChunks(parts, total) {
      const out = new Uint8Array(total);
      let o = 0;
      for (const p of parts) {
        out.set(p, o);
        o += p.length;
      }
      return out;
    }

    function avccPayloadToAnnexB(data, lengthSize) {
      let off = 0;
      const parts = [];
      let total = 0;
      const ls = Math.max(1, Math.min(4, lengthSize || 4));
      while (off + ls <= data.length) {
        let nalLen = 0;
        for (let i = 0; i < ls; i++) {
          nalLen = (nalLen << 8) | data[off + i];
        }
        off += ls;
        if (nalLen <= 0 || off + nalLen > data.length) return null;
        const start = new Uint8Array([0, 0, 0, 1]);
        const nal = data.subarray(off, off + nalLen);
        parts.push(start, nal);
        total += start.length + nal.length;
        off += nalLen;
      }
      if (off !== data.length || total <= 0) return null;
      return concatChunks(parts, total);
    }

    function avcConfigToAnnexB(data) {
      if (!data || data.length < 7) return null;
      if (data[0] !== 1) return null;
      const lengthSize = (data[4] & 0x03) + 1;
      let off = 5;
      const numSps = data[off] & 0x1f;
      off += 1;
      const parts = [];
      let total = 0;

      for (let i = 0; i < numSps; i++) {
        if (off + 2 > data.length) return null;
        const len = (data[off] << 8) | data[off + 1];
        off += 2;
        if (len <= 0 || off + len > data.length) return null;
        const start = new Uint8Array([0, 0, 0, 1]);
        const sps = data.subarray(off, off + len);
        parts.push(start, sps);
        total += start.length + sps.length;
        off += len;
      }

      if (off + 1 > data.length) return null;
      const numPps = data[off];
      off += 1;
      for (let i = 0; i < numPps; i++) {
        if (off + 2 > data.length) return null;
        const len = (data[off] << 8) | data[off + 1];
        off += 2;
        if (len <= 0 || off + len > data.length) return null;
        const start = new Uint8Array([0, 0, 0, 1]);
        const pps = data.subarray(off, off + len);
        parts.push(start, pps);
        total += start.length + pps.length;
        off += len;
      }

      let framePart = null;
      if (off < data.length) {
        framePart = avccPayloadToAnnexB(data.subarray(off), lengthSize);
      }
      if (framePart && framePart.length > 0) {
        parts.push(framePart);
        total += framePart.length;
      }
      if (total <= 0) return null;
      return concatChunks(parts, total);
    }

    function toAnnexB(data, isKeyFrame) {
      if (!data || data.length === 0) return null;
      if (hasStartCode(data)) return data;
      if (isKeyFrame && data[0] === 1) {
        const keyConverted = avcConfigToAnnexB(data);
        if (keyConverted && keyConverted.length > 0) return keyConverted;
      }
      const directConverted = avccPayloadToAnnexB(data, 4);
      if (directConverted && directConverted.length > 0) return directConverted;
      return data;
    }

    async function chooseDecoderCodec(codecHint) {
      if (!window.VideoDecoder || !window.VideoDecoder.isConfigSupported) {
        return (typeof codecHint === 'string' && codecHint.length > 0) ? codecHint : 'avc1.640028';
      }
      const candidates = [];
      if (typeof codecHint === 'string' && codecHint.length > 0) candidates.push(codecHint);
      for (const c of CODEC_CANDIDATES) if (!candidates.includes(c)) candidates.push(c);
      for (const codec of candidates) {
        try {
          const result = await VideoDecoder.isConfigSupported({
            codec: codec,
            optimizeForLatency: true,
            hardwareAcceleration: 'prefer-hardware',
          });
          if (result && result.supported) return codec;
        } catch (_) {}
      }
      return null;
    }

    async function ensureDecoder(codecHint) {
      if (!window.VideoDecoder || !window.EncodedVideoChunk) return false;
      if (decoder && decoder.state === 'configured') {
        return true;
      }
      closeDecoder();
      const selected = await chooseDecoderCodec(codecHint);
      if (!selected) return false;
      decoderCodec = selected;
      try {
        decoder = new VideoDecoder({
          output: (frame) => {
            gotFrame = true;
            clearWatchdog();
            const renderedFrameId = pendingFrameIds.length ? pendingFrameIds.shift() : null;
            if (Number.isFinite(renderedFrameId)) {
              publishCameraFrame(renderedFrameId);
            }
            drawFrameCover(frame);
          },
          error: () => {
            directErrorCount++;
            postToFlutter(
              payloadWithCamera({ type: 'camera_error', reason: 'decoder_error' }),
            );
            closeDecoder();
            if (directErrorCount >= 2) {
              fallbackToWebRtc('decoder_error');
            } else {
              scheduleReconnect(900);
            }
          }
        });
        decoder.configure({
          codec: decoderCodec,
          optimizeForLatency: true,
          hardwareAcceleration: 'prefer-hardware',
        });
        waitingKey = true;
        return true;
      } catch (_) {
        closeDecoder();
        return false;
      }
    }

    function fallbackToWebRtc(reason) {
      cleanupSocket();
      closeDecoder();
      if (!ALLOW_WEBRTC) {
        setMode('direct');
        postToFlutter(
          payloadWithCamera({
            type: 'camera_error',
            reason: 'direct_only_reconnect:' + String(reason || 'unknown'),
          }),
        );
        scheduleReconnect(900);
        return;
      }
      setMode('webrtc');
      postToFlutter(
        payloadWithCamera({
          type: 'camera_error',
          reason: 'fallback_webrtc:' + String(reason || 'unknown'),
        }),
      );
      connectWebRtc().catch(() => {});
      scheduleDirectProbe(8000);
    }

    async function connectDirect() {
      if (!ALLOW_DIRECT) {
        if (ALLOW_WEBRTC) {
          connectWebRtc().catch(() => {});
        }
        return;
      }
      cleanupPc();
      cleanupSocket();
      closeDecoder();
      gotFrame = false;
      directErrorCount = 0;
      setMode('direct');

      if (!window.VideoDecoder || !window.EncodedVideoChunk) {
        webCodecsUnsupported = true;
        if (ALLOW_WEBRTC) {
          fallbackToWebRtc('webcodecs_unsupported');
        } else {
          postToFlutter(
            payloadWithCamera({
              type: 'camera_error',
              reason: 'webcodecs_unsupported',
            }),
          );
          scheduleReconnect(1500);
        }
        return;
      }
      webCodecsUnsupported = false;

      armWatchdog();
      try {
        ws = new WebSocket(DIRECT_WS_URL);
        ws.binaryType = 'arraybuffer';
        ws.onopen = () => {
          armWatchdog();
          clearDirectProbe();
        };
        ws.onmessage = async (event) => {
          if (typeof event.data === 'string') return;
          const parsed = parseFramePacket(event.data);
          if (!parsed) return;
          const meta = parsed.meta || {};
          if (!(await ensureDecoder(meta.codec))) {
            if (ALLOW_WEBRTC) {
              fallbackToWebRtc('decoder_unsupported');
            } else {
              postToFlutter(
                payloadWithCamera({
                  type: 'camera_error',
                  reason: 'decoder_unsupported',
                }),
              );
              scheduleReconnect(900);
            }
            return;
          }

          const frameId = Number(meta.frameId ?? -1);
          if (Number.isFinite(frameId) && frameId >= 0) {
            if (lastDirectFrameId >= 0 && frameId <= lastDirectFrameId) {
              droppedOutdated++;
              return;
            }
            lastDirectFrameId = frameId;
          }

          const metaW = Number(meta.width || 0);
          const metaH = Number(meta.height || 0);
          if (metaW > 0 && metaH > 0) {
            publishSourceSize(metaW, metaH);
          }

          const chunkType = meta.keyFrame === true ? 'key' : 'delta';
          if (waitingKey && chunkType !== 'key') return;
          waitingKey = false;

          if (decoder && decoder.decodeQueueSize > 2 && chunkType !== 'key') {
            droppedQueue++;
            return;
          }

          try {
            const ts = normalizeTimestamp(meta.timestampEof || meta.timestampSof || meta.ts);
            const annexb = toAnnexB(parsed.data, chunkType === 'key');
            if (!annexb || annexb.length === 0) return;
            const chunk = new EncodedVideoChunk({
              type: chunkType,
              timestamp: ts,
              data: annexb,
            });
            if (Number.isFinite(frameId) && frameId >= 0) {
              pendingFrameIds.push(frameId);
            }
            decoder.decode(chunk);
            if ((droppedOutdated + droppedQueue) > 0 && ((droppedOutdated + droppedQueue) % 120) === 0) {
              console.log('[DriveCanvas] direct drops outdated=' + droppedOutdated + ' queue=' + droppedQueue);
            }
          } catch (_) {
            if (pendingFrameIds.length) pendingFrameIds.pop();
            waitingKey = true;
          }
        };
        ws.onerror = () => {
          if (ALLOW_WEBRTC) {
            fallbackToWebRtc('socket_error');
          } else {
            postToFlutter(
              payloadWithCamera({
                type: 'camera_error',
                reason: 'socket_error',
              }),
            );
            scheduleReconnect(900);
          }
        };
        ws.onclose = () => {
          if (mode === 'direct') {
            scheduleReconnect(gotFrame ? 700 : 1000);
          }
        };
      } catch (_) {
        if (ALLOW_WEBRTC) {
          fallbackToWebRtc('socket_open_failed');
        } else {
          postToFlutter(
            payloadWithCamera({
              type: 'camera_error',
              reason: 'socket_open_failed',
            }),
          );
          scheduleReconnect(1100);
        }
      }
    }

    async function waitIceComplete(timeoutMs) {
      if (!pc || pc.iceGatheringState === 'complete') return;
      await new Promise((resolve) => {
        const t = setTimeout(resolve, timeoutMs || 8000);
        const onChange = () => {
          if (!pc || pc.iceGatheringState === 'complete') {
            try { pc.removeEventListener('icegatheringstatechange', onChange); } catch (_) {}
            clearTimeout(t);
            resolve();
          }
        };
        pc.addEventListener('icegatheringstatechange', onChange);
      });
    }

    async function connectWebRtc() {
      if (!ALLOW_WEBRTC) {
        if (ALLOW_DIRECT) {
          connectDirect().catch(() => {});
        }
        return;
      }
      cleanupPc();
      try {
        pc = new RTCPeerConnection({
          iceServers: [],
          sdpSemantics: 'unified-plan',
          iceCandidatePoolSize: 1
        });
        pc.addTransceiver('video', { direction: 'recvonly' });

        pc.ontrack = async (ev) => {
          const stream = (ev.streams && ev.streams[0]) ? ev.streams[0] : new MediaStream([ev.track]);
          video.srcObject = stream;
          try { await video.play(); } catch (_) {}
          setTimeout(() => {
            const w = Number(video.videoWidth || 0);
            const h = Number(video.videoHeight || 0);
            if (w > 0 && h > 0) publishSourceSize(w, h);
          }, 100);
        };

        pc.onconnectionstatechange = () => {
          const st = pc ? pc.connectionState : 'closed';
          if (st === 'failed' || st === 'disconnected' || st === 'closed') {
            cleanupPc();
            scheduleReconnect(1500);
          }
        };

        pc.oniceconnectionstatechange = () => {
          const st = pc ? pc.iceConnectionState : 'closed';
          if (st === 'failed' || st === 'disconnected' || st === 'closed') {
            cleanupPc();
            scheduleReconnect(1500);
          }
        };

        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        await waitIceComplete(8000);

        let ans = null;
        let lastErr = 'no endpoint';
        for (const endpoint of STREAM_ENDPOINTS) {
          try {
            const r = await fetch(endpoint, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                sdp: pc.localDescription.sdp,
                cameras: [CAMERA_NAME],
                bridge_services_in: [],
                bridge_services_out: []
              })
            });
            if (!r.ok) {
              lastErr = endpoint + ' http ' + r.status;
              continue;
            }
            const body = await r.json();
            if (body && body.sdp) {
              ans = body;
              break;
            }
            lastErr = endpoint + ' invalid answer';
          } catch (e) {
            lastErr = endpoint + ' ' + (e && e.message ? e.message : String(e));
          }
        }
        if (!ans || !ans.sdp) throw new Error(lastErr);
        await pc.setRemoteDescription({ type: ans.type || 'answer', sdp: ans.sdp });
      } catch (_) {
        cleanupPc();
        scheduleReconnect(2000);
      }
    }

    resizeCanvas();
    window.addEventListener('resize', resizeCanvas);
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) return;
      if (mode === 'direct' && ALLOW_DIRECT) {
        connectDirect().catch(() => {});
      } else if (ALLOW_WEBRTC) {
        connectWebRtc().catch(() => {});
      }
    });
    window.addEventListener('beforeunload', () => {
      cleanupSocket();
      closeDecoder();
      cleanupPc();
      clearReconnect();
      clearDirectProbe();
    });
    if (ALLOW_DIRECT) {
      connectDirect().catch(() => scheduleReconnect(1200));
    } else if (ALLOW_WEBRTC) {
      connectWebRtc().catch(() => scheduleReconnect(1200));
    }
  </script>
</body>
</html>
''';
  }

  String _buildIdleCameraHtml() {
    return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no" />
  <style>
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background: #000;
      overflow: hidden;
    }
  </style>
</head>
<body></body>
</html>
''';
  }

  Future<void> _unloadWebCameraSurface() async {
    try {
      await _cameraController.loadHtmlString(
        _buildIdleCameraHtml(),
        baseUrl: _cameraBaseUri.toString(),
      );
    } catch (_) {}
  }

  Future<void> _loadCameraSource({bool force = false}) async {
    if (!_hudModeLoaded) return;

    if (_useNativeLiveCamera) {
      if (mounted) {
        setState(() {
          _cameraLoading = true;
          _cameraError = null;
        });
      }
      _cameraSourceKey = 'native-live:${widget.hostIp}:$_liveCameraName';
      return;
    }
    final key = 'live:${widget.hostIp}:$_liveCameraName';
    if (!force && _cameraSourceKey == key) return;
    _cameraSourceKey = key;

    if (mounted) {
      setState(() {
        _cameraLoading = true;
        _cameraError = null;
      });
    }

    try {
      final endpoints =
          _streamEndpointCandidates.map((uri) => uri.toString()).join(', ');
      final direct = _liveCameraWsUrl;
      debugPrint(
        '[DriveCanvas] source=live base=${_cameraBaseUri.toString()} direct=$direct fallback=$endpoints camera=$_liveCameraName',
      );
      await _cameraController.loadHtmlString(
        _buildLiveCameraHtml(_liveCameraKind),
        baseUrl: _cameraBaseUri.toString(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraLoading = false;
        _cameraError = '카메라 로드 실패: $e';
      });
    }
  }

  bool _hasWideRoadCapability(_DriveOverlaySnapshot snapshot) {
    if (snapshot.wideRoadFrameId != null) return true;
    return snapshot.wideFromDeviceEuler.length >= 3;
  }

  _DriveCameraKind _selectLiveCameraKind(_DriveOverlaySnapshot snapshot) {
    if (!_hasWideRoadCapability(snapshot)) {
      _wideCamRequested = false;
      return _DriveCameraKind.road;
    }
    // openpilot 기준: vEgo < 10 m/s => wide 요청, vEgo > 15 m/s => road 복귀
    final speedMps = snapshot.speedMps ?? 0.0;
    if (speedMps < 10.0) {
      _wideCamRequested = true;
    } else if (speedMps > 15.0) {
      _wideCamRequested = false;
    }
    _wideCamRequested = _wideCamRequested && snapshot.carrotExperimentalMode;
    return _wideCamRequested
        ? _DriveCameraKind.wideRoad
        : _DriveCameraKind.road;
  }

  void _syncLiveCameraKind(_DriveOverlaySnapshot snapshot) {
    final nextKind = _selectLiveCameraKind(snapshot);
    if (nextKind == _liveCameraKind) return;
    unawaited(_clearNativeOverlay());
    if (!mounted) {
      _liveCameraKind = nextKind;
      _cameraSourceSize = _sourceSizeForKind(nextKind);
      _lastCameraFrameId = null;
      _lastCameraFrameEventUs = 0;
      return;
    }
    setState(() {
      _liveCameraKind = nextKind;
      _cameraSourceSize = _sourceSizeForKind(nextKind);
      _nativeCameraViewId = null;
      _cameraLoading = true;
      _cameraError = null;
    });
    _lastCameraFrameId = null;
    _lastCameraFrameEventUs = 0;
    if (_openpilotOverlayMode && !_cameraSuspendedByLifecycle) {
      _startSidecarLoop();
    }
    if (!_cameraSuspendedByLifecycle) {
      unawaited(_loadCameraSource(force: true));
    }
  }

  void _suspendForBackground() {
    _cancelLifecycleSuspendTimer();
    if (_cameraSuspendedByLifecycle) return;
    debugPrint('[DriveCanvas][lifecycle] suspend');
    _clearSidecarRecoverySchedule();
    _cameraSuspendedByLifecycle = true;
    _backgroundUiResetDone = false;
    _stopAdaptiveCameraQualityLoop();
    unawaited(
      _setDisplayHighRefreshPreference(false, reason: 'drive_background'),
    );
    _scheduleDelayedSidecarStop();
    _scheduleBackgroundUiReset();
  }

  void _resumeFromBackground() {
    _cancelLifecycleSuspendTimer();
    _cancelDelayedSidecarStop();
    _cancelBackgroundUiResetTimer();
    if (!_cameraSuspendedByLifecycle) return;
    debugPrint('[DriveCanvas][lifecycle] resume');
    _cameraSuspendedByLifecycle = false;
    unawaited(_lockLandscapeOrientations());
    unawaited(
      _setDisplayHighRefreshPreference(true, reason: 'drive_resume'),
    );
    if (!_backgroundUiResetDone) {
      if (_openpilotOverlayMode) {
        _startAdaptiveCameraQualityLoop();
        if (!_sidecarConnected) {
          unawaited(_ensureSidecarRuntime(reason: 'resume_quick'));
        } else {
          _setSidecarPhase(_SidecarPhase.running, message: '사이드카 실행 중');
        }
      } else {
        unawaited(_loadCameraSource(force: false));
      }
      return;
    }
    _applyHudModeRuntime();
  }

  void _scheduleSuspendForBackground() {
    if (_cameraSuspendedByLifecycle) return;
    _cancelLifecycleSuspendTimer();
    _lifecycleSuspendTimer = Timer(_lifecycleSuspendDelay, () {
      _lifecycleSuspendTimer = null;
      if (!mounted) return;
      _suspendForBackground();
    });
  }

  void _cancelLifecycleSuspendTimer() {
    _lifecycleSuspendTimer?.cancel();
    _lifecycleSuspendTimer = null;
  }

  void _cancelDelayedSidecarStop() {
    _sidecarProcessStopTimer?.cancel();
    _sidecarProcessStopTimer = null;
  }

  void _cancelBackgroundUiResetTimer() {
    _backgroundUiResetTimer?.cancel();
    _backgroundUiResetTimer = null;
  }

  void _scheduleBackgroundUiReset() {
    _cancelBackgroundUiResetTimer();
    _backgroundUiResetTimer = Timer(_backgroundUiResetGrace, () {
      _backgroundUiResetTimer = null;
      if (!mounted || !_cameraSuspendedByLifecycle) return;
      _backgroundUiResetDone = true;
      _performBackgroundUiReset();
    });
  }

  void _performBackgroundUiReset() {
    _stopSidecarLoop();
    _lastCameraFrameId = null;
    _lastCameraFrameEventUs = 0;
    _lastPublishedModelFrameId = null;
    _lastSyncHitUs = 0;
    _lastSyncedArrivalUs = 0;
    _latestOverlaySnapshot = const _DriveOverlaySnapshot.empty();
    _overlayByModelFrame.clear();
    _overlayFrameOrder.clear();
    _pathAnimationPhase = 0.0;
    _pathAnimationSeq2 = -1;
    _pathAnimationForward = true;
    _lastPathAnimationTickUs = 0;
    _renderInterpActive = false;
    _applyOverlaySnapshot(
      const _DriveOverlaySnapshot.empty(),
      forceNativePush: true,
    );
    unawaited(_clearNativeOverlay());
    _cameraSourceKey = null;
    _nativeCameraViewId = null;
    unawaited(_unloadWebCameraSurface());
    if (mounted) {
      setState(() {
        _nativeCameraViewId = null;
        _cameraLoading = false;
        _cameraError = null;
      });
    }
  }

  void _scheduleDelayedSidecarStop() {
    _cancelDelayedSidecarStop();
    if (_residentSidecarManaged) {
      _pushSidecarHistory(
          'BG_KEEPALIVE', 'resident mode: process stop skipped');
      return;
    }
    if (!_openpilotOverlayMode) {
      unawaited(_stopSidecarProcessIfNeeded());
      return;
    }
    _pushSidecarHistory(
      'BG_KEEPALIVE',
      'defer stop ${_backgroundProcessKeepAlive.inSeconds}s',
    );
    _sidecarProcessStopTimer = Timer(_backgroundProcessKeepAlive, () {
      _sidecarProcessStopTimer = null;
      if (!mounted || !_cameraSuspendedByLifecycle) return;
      _setSidecarPhase(
        _SidecarPhase.stopping,
        message: '백그라운드 유지 시간이 지나 사이드카를 중지합니다.',
      );
      _stopSidecarLoop();
      unawaited(_stopSidecarProcessIfNeeded());
    });
  }

  void _cacheOverlaySnapshot(_DriveOverlaySnapshot snapshot) {
    _latestOverlaySnapshot = snapshot;
    final modelFrameId = snapshot.modelFrameId;
    if (modelFrameId == null || modelFrameId < 0) return;
    if (!_overlayByModelFrame.containsKey(modelFrameId)) {
      _overlayFrameOrder.addLast(modelFrameId);
    }
    _overlayByModelFrame[modelFrameId] = snapshot;
    while (_overlayFrameOrder.length > _overlayFrameBufferSize) {
      final drop = _overlayFrameOrder.removeFirst();
      _overlayByModelFrame.remove(drop);
    }
  }

  _DriveOverlaySnapshot? _findSyncedSnapshot(
    int cameraFrameId, {
    required int maxDelta,
  }) {
    final exact = _overlayByModelFrame[cameraFrameId];
    if (exact != null) return exact;
    for (var delta = 1; delta <= maxDelta; delta++) {
      final lo = _overlayByModelFrame[cameraFrameId - delta];
      if (lo != null) return lo;
      final hi = _overlayByModelFrame[cameraFrameId + delta];
      if (hi != null) return hi;
    }
    return null;
  }

  int? _cameraFrameIdFromSnapshot(_DriveOverlaySnapshot snapshot) {
    if (_liveCameraKind == _DriveCameraKind.wideRoad) {
      return snapshot.wideRoadFrameId ?? snapshot.roadFrameId;
    }
    return snapshot.roadFrameId;
  }

  void _applyOverlaySnapshot(
    _DriveOverlaySnapshot snapshot, {
    bool forceNativePush = false,
  }) {
    final decorated = snapshot.copyWith(animationPhase: _pathAnimationPhase);
    _overlayNotifier.value = decorated;
    _refreshOverlayVerify(decorated, force: forceNativePush);
    if (_useNativeOverlayRenderer) {
      unawaited(
        _pushNativeOverlay(decorated, force: forceNativePush),
      );
    }
  }

  Future<void> _clearNativeOverlay() async {
    final viewId = _nativeCameraViewId;
    if (viewId == null) return;
    try {
      await _nativeCameraControlChannel.invokeMethod<bool>(
        'clearOverlay',
        <String, dynamic>{'viewId': viewId},
      );
      _lastNativeOverlaySignature = null;
      _lastNativeOverlayHadPayload = false;
    } catch (_) {}
  }

  int _buildOverlaySignature(_DriveOverlaySnapshot snapshot) {
    final cameraFrameId = _liveCameraKind == _DriveCameraKind.wideRoad
        ? (snapshot.wideRoadFrameId ?? snapshot.roadFrameId ?? -1)
        : (snapshot.roadFrameId ?? snapshot.wideRoadFrameId ?? -1);
    final animBucket = _isAnimatedPathMode(snapshot.pathMode)
        ? (snapshot.animationPhase * 10.0).round()
        : 0;
    return Object.hashAll(<Object?>[
      snapshot.modelFrameId ?? -1,
      cameraFrameId,
      snapshot.pathMode,
      snapshot.pathColor,
      snapshot.leftLaneLine,
      snapshot.rightLaneLine,
      snapshot.path.length,
      snapshot.laneLines.length,
      snapshot.roadEdges.length,
      snapshot.navPathPoints.length,
      snapshot.navTurnInfo,
      (snapshot.navDistToTurn ?? -1.0).round(),
      snapshot.navMainText,
      animBucket,
      _nativeOverlaySize.width.round(),
      _nativeOverlaySize.height.round(),
      _liveCameraKind.index,
      _coverViewport ? 1 : 0,
    ]);
  }

  void _refreshOverlayVerify(
    _DriveOverlaySnapshot snapshot, {
    bool force = false,
  }) {
    if (!_overlayVerifyMode || !_debugShowVerifyPanel || !mounted) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    if (!force &&
        (nowUs - _lastOverlayVerifyUpdateUs) < _overlayVerifyIntervalUs) {
      return;
    }
    _lastOverlayVerifyUpdateUs = nowUs;
    final canvasSize =
        (_nativeOverlaySize.width > 1 && _nativeOverlaySize.height > 1)
            ? _nativeOverlaySize
            : const Size(1928, 1208);
    final text = _DriveOverlayPainter.buildProjectionDebugText(
      snapshot: snapshot,
      sourceSize: _cameraSourceSize,
      cameraKind: _liveCameraKind,
      canvasSize: canvasSize,
      coverViewport: _coverViewport,
      cameraSourceLabel: 'live',
    );
    if (!mounted) return;
    if (_overlayVerifyText != text) {
      setState(() => _overlayVerifyText = text);
    }
  }

  Future<void> _pushNativeOverlay(
    _DriveOverlaySnapshot snapshot, {
    bool force = false,
  }) async {
    if (!_openpilotOverlayMode) {
      await _clearNativeOverlay();
      _lastNativeOverlaySignature = null;
      _lastNativeOverlayHadPayload = false;
      return;
    }
    if (!_debugShowArOverlay) {
      if (_lastNativeOverlayHadPayload) {
        await _clearNativeOverlay();
      }
      _lastNativeOverlaySignature = null;
      _lastNativeOverlayHadPayload = false;
      return;
    }
    if (!_useNativeOverlayRenderer) return;
    final viewId = _nativeCameraViewId;
    if (viewId == null) return;
    if (_nativeOverlaySize.width <= 1 || _nativeOverlaySize.height <= 1) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    if (!force &&
        (nowUs - _lastNativeOverlayPushUs) < _nativeOverlayPushIntervalUs) {
      return;
    }
    final signature = _buildOverlaySignature(snapshot);
    if (!force &&
        !_isAnimatedPathMode(snapshot.pathMode) &&
        _lastNativeOverlaySignature == signature) {
      return;
    }
    final payload = _DriveOverlayPainter.buildNativeOverlayPayload(
      snapshot: snapshot,
      sourceSize: _cameraSourceSize,
      cameraKind: _liveCameraKind,
      canvasSize: _nativeOverlaySize,
      coverViewport: _coverViewport,
      showDebugGuides: _overlayVerifyMode && _debugShowGuides,
      showPathFill: _debugShowPathFill,
      showLaneLines: _debugShowLaneLines,
      showRoadEdge: _debugShowRoadEdge,
      showLead1: _debugShowLead1,
      showLead2: _debugShowLead2,
      showRadarBadge: _debugShowRadarBadge,
      showRadarVector: _debugShowRadarVector,
      showStopDistanceTf: _debugShowStopDistanceTf,
      showStateText: _debugShowStateText,
    );
    if (!force &&
        _lastNativeOverlaySignature == signature &&
        _lastNativeOverlayHadPayload == (payload != null)) {
      return;
    }
    _lastNativeOverlayPushUs = nowUs;
    try {
      if (payload == null) {
        await _nativeCameraControlChannel.invokeMethod<bool>(
          'clearOverlay',
          <String, dynamic>{'viewId': viewId},
        );
      } else {
        await _nativeCameraControlChannel.invokeMethod<bool>(
          'updateOverlay',
          <String, dynamic>{
            'viewId': viewId,
            'overlay': payload,
          },
        );
      }
      _lastNativeOverlaySignature = signature;
      _lastNativeOverlayHadPayload = payload != null;
    } catch (_) {}
  }

  void _publishOverlaySynced() {
    if (!mounted) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    final cameraFrameId = _lastCameraFrameId;
    if (cameraFrameId == null) {
      if (_strictFrameLock) {
        if (_lastPublishedModelFrameId != null &&
            (nowUs - _lastSyncHitUs) > _strictFrameHoldUs) {
          _renderInterpActive = false;
          _applyOverlaySnapshot(
            const _DriveOverlaySnapshot.empty(),
            forceNativePush: true,
          );
          _lastPublishedModelFrameId = null;
        }
        return;
      }
      _setRenderTarget(_latestOverlaySnapshot, nowUs: nowUs);
      _lastPublishedModelFrameId = _latestOverlaySnapshot.modelFrameId;
      return;
    }

    final synced = _findSyncedSnapshot(
      cameraFrameId,
      maxDelta: _overlaySyncMaxDeltaCurrent,
    );
    if (synced == null) {
      // If exact sync is temporarily unavailable, keep using the newest model
      // snapshot so path/lane rendering doesn't disappear entirely.
      if (_latestOverlaySnapshot.path.length >= 2 &&
          _latestOverlaySnapshot.modelFrameId != null &&
          _lastPublishedModelFrameId == null) {
        _setRenderTarget(_latestOverlaySnapshot, nowUs: nowUs);
        _lastPublishedModelFrameId = _latestOverlaySnapshot.modelFrameId;
        return;
      }
      if (_strictFrameLock &&
          _lastPublishedModelFrameId != null &&
          (nowUs - _lastSyncHitUs) > _strictFrameHoldUs) {
        _renderInterpActive = false;
        _applyOverlaySnapshot(
          const _DriveOverlaySnapshot.empty(),
          forceNativePush: true,
        );
        _lastPublishedModelFrameId = null;
      }
      return;
    }
    final modelFrameId = synced.modelFrameId;
    if (_lastPublishedModelFrameId != null &&
        modelFrameId != null &&
        modelFrameId < (_lastPublishedModelFrameId! - 1)) {
      return;
    }
    if (modelFrameId != null && modelFrameId == _lastPublishedModelFrameId) {
      return;
    }
    _lastSyncHitUs = nowUs;
    _setRenderTarget(synced, nowUs: nowUs);
    _lastPublishedModelFrameId = modelFrameId;
  }

  void _setRenderTarget(_DriveOverlaySnapshot next, {required int nowUs}) {
    final prevArrival = _lastSyncedArrivalUs;
    if (prevArrival > 0) {
      final dt = nowUs - prevArrival;
      if (dt > 5000 && dt < 300000) {
        _smoothedSyncIntervalUs =
            (_smoothedSyncIntervalUs * 0.85) + (dt.toDouble() * 0.15);
      }
    }
    _lastSyncedArrivalUs = nowUs;
    _renderFromSnapshot = _overlayNotifier.value;
    _renderToSnapshot = next;
    _renderInterpStartUs = nowUs;
    _renderInterpDurationUs = (_smoothedSyncIntervalUs * 0.8)
        .round()
        .clamp(_interpMinUs, _interpMaxUs);
    _renderInterpActive = true;
    _renderTicker ??= createTicker(_onRenderTick)..start();
  }

  void _advancePathAnimationTick({
    required int nowUs,
    required _DriveOverlaySnapshot snapshot,
  }) {
    if (!_isAnimatedPathMode(snapshot.pathMode) || snapshot.path.length < 2) {
      _pathAnimationPhase = 0.0;
      _pathAnimationSeq2 = -1;
      _pathAnimationForward = true;
      _lastPathAnimationTickUs = nowUs;
      return;
    }

    final prevTickUs = _lastPathAnimationTickUs;
    _lastPathAnimationTickUs = nowUs;
    var dtUs = 50000.0;
    if (prevTickUs > 0) {
      dtUs = (nowUs - prevTickUs).toDouble();
    }
    dtUs = dtUs.clamp(4000.0, 120000.0);
    final tickScale = dtUs / 50000.0; // openpilot UI(20Hz) 기준 스케일

    final speedKph = snapshot.speedKph ?? ((snapshot.speedMps ?? 0.0) * 3.6);
    final seq = math.max(0.3, speedKph / 100.0);
    final maxSeq = _estimateAnimatedMaxSeq(snapshot);
    final accel = snapshot.aEgo;
    if (accel < -1.0) {
      _pathAnimationForward = false;
    } else if (accel > -0.5) {
      _pathAnimationForward = true;
    }
    final step = seq * tickScale;
    if (_pathAnimationForward) {
      _pathAnimationPhase += step;
      if (_pathAnimationPhase > maxSeq) {
        _pathAnimationPhase =
            _pathAnimationSeq2 >= 0 ? _pathAnimationSeq2.toDouble() : 0.0;
      }
    } else {
      _pathAnimationPhase -= step;
      if (_pathAnimationPhase < 0.0) {
        _pathAnimationPhase = _pathAnimationSeq2 >= 0
            ? _pathAnimationSeq2.toDouble()
            : maxSeq.toDouble();
      }
    }
    _pathAnimationSeq2 = (maxSeq > 15)
        ? ((_pathAnimationPhase.floor() - (maxSeq ~/ 2) + maxSeq) % maxSeq)
        : -5;
    if (_pathAnimationPhase.abs() > 1000000.0) {
      _pathAnimationPhase = _pathAnimationPhase % maxSeq.toDouble();
    }
  }

  int _estimateAnimatedMaxSeq(_DriveOverlaySnapshot snapshot) {
    final modelMax = snapshot.path.x.isNotEmpty ? snapshot.path.x.last : 0.0;
    final maxDistance = modelMax.clamp(10.0, 100.0);
    var dist = 2.0;
    var count = 0;
    while (true) {
      if (dist >= maxDistance) {
        count++;
        break;
      }
      count++;
      dist += dist * 0.15;
      if (count > 256) break;
    }
    final maxSeq = math.min((count ~/ 2) + 3, 16);
    return math.max(1, maxSeq);
  }

  void _onRenderTick(Duration _) {
    if (!mounted) return;
    final nowUs = _renderClock.elapsedMicroseconds;
    final tickSnapshot =
        _renderInterpActive ? _renderToSnapshot : _overlayNotifier.value;
    _advancePathAnimationTick(nowUs: nowUs, snapshot: tickSnapshot);
    if (!_renderInterpActive) {
      if (_useNativeOverlayRenderer) {
        final current = _overlayNotifier.value;
        if (current.path.length >= 2 && _isAnimatedPathMode(current.pathMode)) {
          _applyOverlaySnapshot(current);
        }
      } else if (_isAnimatedPathMode(_overlayNotifier.value.pathMode)) {
        _applyOverlaySnapshot(_overlayNotifier.value);
      }
      return;
    }
    final elapsedUs = nowUs - _renderInterpStartUs;
    if (elapsedUs >= _renderInterpDurationUs) {
      _applyOverlaySnapshot(_renderToSnapshot);
      _renderInterpActive = false;
      return;
    }
    final t = elapsedUs / _renderInterpDurationUs;
    _applyOverlaySnapshot(
      _DriveOverlaySnapshot.interpolate(
          _renderFromSnapshot, _renderToSnapshot, t),
    );
  }

  void _handleCameraFrameEvent(
    int frameId, {
    required String source,
    _DriveCameraKind? cameraKind,
  }) {
    if (frameId < 0) return;
    if (cameraKind != null && cameraKind != _liveCameraKind) {
      // Drop stale frame events from a camera stream that is no longer active.
      return;
    }
    _lastCameraFrameId = frameId;
    _lastCameraFrameEventUs = _renderClock.elapsedMicroseconds;
    if (mounted && _cameraLoading) {
      setState(() {
        _cameraLoading = false;
      });
    } else if (!mounted && _cameraLoading) {
      _cameraLoading = false;
    }
    _publishOverlaySynced();
    if (frameId % 60 == 0) {
      debugPrint(
        '[DriveCanvas][sync] cameraFrame=$frameId source=$source cam=$_liveCameraName',
      );
    }
  }

  void _startSidecarLoop() {
    _stopSidecarLoop(resetSession: false);
    _sidecarSession++;
    final session = _sidecarSession;
    unawaited(_startSidecarWorker(session));
  }

  void _stopSidecarLoop({bool resetSession = true}) {
    if (resetSession) _sidecarSession++;
    _sidecarWorkerSubscription?.cancel();
    _sidecarWorkerSubscription = null;
    _sidecarWorkerReceivePort?.close();
    _sidecarWorkerReceivePort = null;
    _sidecarWorkerIsolate?.kill(priority: Isolate.immediate);
    _sidecarWorkerIsolate = null;
    if (mounted && _sidecarConnected) {
      setState(() => _sidecarConnected = false);
    } else {
      _sidecarConnected = false;
    }
  }

  Future<void> _startSidecarWorker(int session) async {
    if (!mounted || session != _sidecarSession) return;
    final receivePort = ReceivePort();
    _sidecarWorkerReceivePort = receivePort;
    _sidecarWorkerSubscription = receivePort.listen((event) {
      if (!mounted || session != _sidecarSession) return;
      _handleSidecarWorkerEvent(event);
    });
    try {
      final isolate = await Isolate.spawn<Map<String, dynamic>>(
        _driveSidecarWorkerMain,
        <String, dynamic>{
          'wsUrl': _sidecarWsUrl,
          'sendPort': receivePort.sendPort,
        },
        debugName: 'drive_sidecar_worker_${widget.hostIp}',
      );
      if (!mounted || session != _sidecarSession) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _sidecarWorkerIsolate = isolate;
    } catch (_) {
      _sidecarWorkerSubscription?.cancel();
      _sidecarWorkerSubscription = null;
      _sidecarWorkerReceivePort?.close();
      _sidecarWorkerReceivePort = null;
      if (_sidecarConnected && mounted) {
        setState(() => _sidecarConnected = false);
      } else {
        _sidecarConnected = false;
      }
      _setSidecarPhase(
        _SidecarPhase.failed,
        message: '사이드카 워커 시작에 실패했습니다.',
      );
    }
  }

  void _handleSidecarWorkerEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);
    final type = map['type']?.toString() ?? '';
    if (type == 'connected') {
      final next = map['connected'] == true;
      _pushSidecarHistory('WS', next ? 'connected' : 'disconnected');
      if (next && _isSidecarBusy) {
        _sidecarTransitionTimer?.cancel();
      }
      if (mounted) {
        setState(() {
          _sidecarConnected = next;
          if (next) {
            _suppressCameraErrors = false;
            _cameraError = null;
          } else if (_openpilotOverlayMode) {
            _suppressCameraErrors = true;
            _cameraError = null;
            _cameraLoading = false;
          }
        });
      } else {
        _sidecarConnected = next;
        if (next) {
          _suppressCameraErrors = false;
          _cameraError = null;
        } else if (_openpilotOverlayMode) {
          _suppressCameraErrors = true;
          _cameraError = null;
          _cameraLoading = false;
        }
      }
      if (next) {
        _clearSidecarRecoverySchedule();
        _setSidecarPhase(
          _SidecarPhase.running,
          message: '사이드카 연결이 복구되었습니다.',
        );
        if (!_adaptiveCameraQualitySynced) {
          unawaited(
            _setAdaptiveCameraQualityMode(
              _adaptiveCameraQualityMode,
              reason: 'ws_reconnected',
              force: true,
            ),
          );
        }
      } else if (_openpilotOverlayMode && !_cameraSuspendedByLifecycle) {
        _setSidecarPhase(
          _SidecarPhase.verifying,
          message: '사이드카 재연결을 시도합니다.',
        );
      } else if (!_openpilotOverlayMode) {
        _setSidecarPhase(_SidecarPhase.idle);
      }
      if (next && !_cameraSuspendedByLifecycle) {
        unawaited(_loadCameraSource(force: true));
      } else if (!next &&
          _openpilotOverlayMode &&
          !_cameraSuspendedByLifecycle &&
          !_isSidecarBusy) {
        _scheduleSidecarRuntimeRecovery(reason: 'worker_disconnected');
      }
      return;
    }
    if (type != 'frame') return;
    final rawPayload = map['payload'];
    if (rawPayload is! Map) return;
    final payload = Map<String, dynamic>.from(rawPayload);
    _handleSidecarPayload(payload);
  }

  _DriveOverlaySnapshot _stabilizeOverlaySnapshot(
    _DriveOverlaySnapshot snapshot,
  ) {
    var next = snapshot;
    final previous = _latestOverlaySnapshot;
    final mergedOverlay2d = _mergeSidecarOverlay2dTrackVertices(
      current: next.sidecarOverlay2d,
      previous: previous.sidecarOverlay2d,
    );
    if (!identical(mergedOverlay2d, next.sidecarOverlay2d)) {
      next = next.copyWith(sidecarOverlay2d: mergedOverlay2d);
    }

    // Enforce classic visual style (no blue 3-strip mode).
    var mode = next.pathMode;
    var color = next.pathColor;
    if (mode >= 13 && mode <= 15) mode = 0;
    if (color == 14 || color == 19) color = 3;
    if (mode != next.pathMode || color != next.pathColor) {
      next = next.copyWith(pathMode: mode, pathColor: color);
    }

    final hasCurrentNavHint = next.navTurnInfo != 0 ||
        (next.navDistToTurn != null && next.navDistToTurn! > 0.0) ||
        next.navMainText.trim().isNotEmpty;
    if (hasCurrentNavHint) {
      var navPathPoints = next.navPathPoints;
      var navTurnInfo = next.navTurnInfo;
      var navDistToTurn = next.navDistToTurn;
      var navMainText = next.navMainText;
      var navChanged = false;

      if (navPathPoints.length < 2 && previous.navPathPoints.length >= 2) {
        navPathPoints = previous.navPathPoints;
        navChanged = true;
      }
      if (navTurnInfo == 0 && previous.navTurnInfo != 0) {
        navTurnInfo = previous.navTurnInfo;
        navChanged = true;
      }
      if ((navDistToTurn == null || navDistToTurn <= 0.0) &&
          previous.navDistToTurn != null &&
          previous.navDistToTurn! > 0.0) {
        navDistToTurn = previous.navDistToTurn;
        navChanged = true;
      }
      if (navMainText.trim().isEmpty &&
          previous.navMainText.trim().isNotEmpty) {
        navMainText = previous.navMainText;
        navChanged = true;
      }

      if (navChanged) {
        next = next.copyWith(
          navPathPoints: navPathPoints,
          navTurnInfo: navTurnInfo,
          navDistToTurn: navDistToTurn,
          navMainText: navMainText,
        );
      }
    }

    return next;
  }

  Map<String, dynamic>? _mergeSidecarOverlay2dTrackVertices({
    required Map<String, dynamic>? current,
    required Map<String, dynamic>? previous,
  }) {
    if (current == null || previous == null) return current;
    final currentCamerasRaw = current['cameras'];
    final previousCamerasRaw = previous['cameras'];
    if (currentCamerasRaw is! Map || previousCamerasRaw is! Map) return current;

    final currentCameras = Map<String, dynamic>.from(currentCamerasRaw);
    final previousCameras = Map<String, dynamic>.from(previousCamerasRaw);
    var changed = false;

    for (final entry in currentCameras.entries.toList(growable: false)) {
      final key = entry.key;
      final currentCamRaw = entry.value;
      final previousCamRaw = previousCameras[key];
      if (currentCamRaw is! Map || previousCamRaw is! Map) continue;

      final currentCam = Map<String, dynamic>.from(currentCamRaw);
      final previousCam = Map<String, dynamic>.from(previousCamRaw);
      final currentTrack = currentCam['pathTrackVertices'];
      final previousTrack = previousCam['pathTrackVertices'];
      final currentLen = currentTrack is List ? currentTrack.length : 0;
      final previousLen = previousTrack is List ? previousTrack.length : 0;
      final needTrackFallback = currentLen < 6 && previousLen >= 6;
      if (!needTrackFallback) continue;

      currentCam['pathTrackVertices'] =
          List<dynamic>.from(previousTrack as List);
      final metaRaw = currentCam['meta'];
      final meta = metaRaw is Map<String, dynamic>
          ? Map<String, dynamic>.from(metaRaw)
          : <String, dynamic>{};
      meta['pathTrackFallback'] = 'previous_frame';
      currentCam['meta'] = meta;
      currentCameras[key] = currentCam;
      changed = true;
    }

    if (!changed) return current;
    final merged = Map<String, dynamic>.from(current);
    merged['cameras'] = currentCameras;
    return merged;
  }

  void _handleSidecarPayload(Map<String, dynamic> payload) {
    if (payload['type'] == 'hello') return;
    if (!_openpilotOverlayMode) return;
    if (_debugOverlayPreviewMode) return;

    final next = _stabilizeOverlaySnapshot(
      _DriveOverlaySnapshot.fromSidecar(payload),
    );
    _syncLiveCameraKind(next);
    _cacheOverlaySnapshot(next);
    _overlayDiagFrames++;
    final now = DateTime.now();
    _sidecarLastFrameAt = now;
    _tickOverlayDebugMetrics(next, now);
    if (now.difference(_overlayDiagLastLogAt).inSeconds >= 2) {
      final frameGap = (next.modelFrameId != null && next.roadFrameId != null)
          ? (next.modelFrameId! - next.roadFrameId!).abs()
          : -1;
      final wideGap =
          (next.modelFrameId != null && next.wideRoadFrameId != null)
              ? (next.modelFrameId! - next.wideRoadFrameId!).abs()
              : -1;
      debugPrint(
        '[DriveCanvas][overlay] fps~${(_overlayDiagFrames / 2.0).toStringAsFixed(1)} '
        'pathPts=${next.path.length} lanes=${next.laneLines.length} '
        'edges=${next.roadEdges.length} frameGap=$frameGap wideGap=$wideGap '
        'pathSrc=${next.usingLateralPath ? 'lateral' : 'model'} '
        'mx=${next.modelPathXMax.toStringAsFixed(1)} '
        'lx=${next.lateralPathXMax.toStringAsFixed(1)} '
        'calib=${next.calibrationRpy.length >= 3 ? 1 : 0} '
        'wideCal=${next.wideFromDeviceEuler.length >= 3 ? 1 : 0} '
        'mode=${next.pathMode} color=${next.pathColor} '
        'modelFrame=${next.modelFrameId} roadFrame=${next.roadFrameId} '
        'wideRoadFrame=${next.wideRoadFrameId} cam=$_liveCameraName '
        'viewport=${_coverViewport ? 'cover' : 'contain'}',
      );
      _overlayDiagFrames = 0;
      _overlayDiagLastLogAt = now;
    }
    if (!mounted) return;
    final inferredCameraFrame = _cameraFrameIdFromSnapshot(next);
    final nowUs = _renderClock.elapsedMicroseconds;
    final cameraStale = _lastCameraFrameEventUs <= 0 ||
        (nowUs - _lastCameraFrameEventUs) > _cameraFrameStaleUs;
    if (inferredCameraFrame != null &&
        (_lastCameraFrameId == null || cameraStale)) {
      _lastCameraFrameId = inferredCameraFrame;
      if (cameraStale && (nowUs - _lastCameraFallbackLogUs) >= 2000000) {
        _lastCameraFallbackLogUs = nowUs;
        debugPrint(
          '[DriveCanvas][sync] fallback cameraFrame=$inferredCameraFrame via sidecar (native frame event stale)',
        );
      }
    }
    _publishOverlaySynced();
  }

  Uri _sidecarHttpUri(String path, [Map<String, String>? query]) {
    return Uri(
      scheme: 'http',
      host: widget.hostIp,
      port: 7766,
      path: path,
      queryParameters: query,
    );
  }

  Future<Map<String, dynamic>> _sidecarGetJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(_sidecarHttpUri(path, query)).timeout(
            const Duration(seconds: 4),
          );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      final text = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: $text');
      }
      final decoded =
          text.trim().isEmpty ? <String, dynamic>{} : jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw Exception('invalid response');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _sidecarPostJson(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.postUrl(_sidecarHttpUri(path)).timeout(
            const Duration(seconds: 4),
          );
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.write(jsonEncode(body));
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      final text = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: $text');
      }
      final decoded =
          text.trim().isEmpty ? <String, dynamic>{} : jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw Exception('invalid response');
    } finally {
      client.close(force: true);
    }
  }

  String _cameraDiagTimestampForFileName(DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}_'
        '${three(now.millisecond)}';
  }

  Future<Directory> _resolveCameraDiagDir() async {
    try {
      await StorageLayoutService.instance.ensureBaseFolders();
      final preferred =
          Directory('${StorageLayoutService.logsPath}/camera_errors');
      if (!await preferred.exists()) {
        await preferred.create(recursive: true);
      }
      return preferred;
    } catch (_) {
      final fallback =
          Directory('${Directory.systemTemp.path}/carrotlink_camera_errors');
      if (!await fallback.exists()) {
        await fallback.create(recursive: true);
      }
      return fallback;
    }
  }

  Future<void> _captureCameraErrorDiagnostics({
    required String source,
    required String reason,
  }) async {
    if (_cameraDiagCaptureInFlight) return;
    final now = DateTime.now();
    final last = _lastCameraDiagCapturedAt;
    if (last != null && now.difference(last) < _cameraDiagCaptureCooldown) {
      return;
    }

    _cameraDiagCaptureInFlight = true;
    _lastCameraDiagCapturedAt = now;
    try {
      final ssh = _sshService ??
          (mounted ? Provider.of<SSHService>(context, listen: false) : null);
      final report = <String, dynamic>{
        'timestamp': now.toIso8601String(),
        'hostIp': widget.hostIp,
        'source': source,
        'reason': reason,
        'modeTag': _modeTagLabel,
        'openpilotOverlayMode': _openpilotOverlayMode,
        'nativeCameraMode': _useNativeLiveCamera,
        'liveCamera': _liveCameraName,
        'cameraLoading': _cameraLoading,
        'cameraError': _cameraError,
        'sidecarConnected': _sidecarConnected,
        'sidecarPhase': _sidecarPhase.name,
      };

      if (_openpilotOverlayMode) {
        try {
          report['sidecarHealth'] = await _sidecarGetJson('/health');
        } catch (e) {
          report['sidecarHealthError'] = e.toString();
        }
      } else {
        report['sidecarHealth'] = 'skipped (webrtc_mode)';
      }

      String tmuxTail = 'ssh_not_connected';
      if (ssh != null && ssh.isConnected) {
        try {
          final result = await ssh.executeCommandResult(
            _cameraDiagTmuxTailCommand,
            timeout: const Duration(seconds: 25),
          );
          tmuxTail = [
            if (result.stdout.trim().isNotEmpty) result.stdout.trim(),
            if (result.stderr.trim().isNotEmpty)
              '\n[stderr]\n${result.stderr.trim()}',
            if (result.stdout.trim().isEmpty && result.stderr.trim().isEmpty)
              '(출력 없음)',
          ].join('\n');
          report['tmuxExitCode'] = result.exitCode;
        } catch (e) {
          tmuxTail = 'tmux_capture_failed: $e';
        }

        if (_openpilotOverlayMode) {
          try {
            report['sidecarStatusRaw'] = await _sidecarService.status(ssh);
          } catch (e) {
            report['sidecarStatusError'] = e.toString();
          }
        }
      }

      final dir = await _resolveCameraDiagDir();
      final file = File(
        '${dir.path}/camera_error_${_cameraDiagTimestampForFileName(now)}.log',
      );
      final pretty = const JsonEncoder.withIndent('  ').convert(report);
      await file.writeAsString(
        '''
=== camera_error diagnostics ===
$pretty

=== tmux tail ===
$tmuxTail
''',
      );
      debugPrint(
          '[DriveCanvas][diag] camera_error snapshot saved: ${file.path}');
    } catch (e) {
      debugPrint('[DriveCanvas][diag] camera_error snapshot failed: $e');
    } finally {
      _cameraDiagCaptureInFlight = false;
    }
  }

  String _adaptiveCameraQualityLabel(_AdaptiveCameraQualityMode mode) {
    return 'low_latency';
  }

  void _resetAdaptiveCameraQualityState({bool resetMode = false}) {
    _adaptiveBadScore = 0;
    _adaptiveCameraQualitySynced = false;
    if (resetMode) {
      _adaptiveCameraQualityMode = _AdaptiveCameraQualityMode.lowLatency;
    }
  }

  void _startAdaptiveCameraQualityLoop() {
    _adaptiveCameraQualityTimer?.cancel();
    _adaptiveCameraQualityTimer = null;
    _resetAdaptiveCameraQualityState(resetMode: true);
    unawaited(
      _setAdaptiveCameraQualityMode(
        _adaptiveCameraQualityMode,
        reason: 'init',
        force: true,
      ),
    );
  }

  void _stopAdaptiveCameraQualityLoop({bool resetMode = false}) {
    _adaptiveCameraQualityTimer?.cancel();
    _adaptiveCameraQualityTimer = null;
    _adaptiveCameraQualityBusy = false;
    _resetAdaptiveCameraQualityState(resetMode: resetMode);
  }

  Future<void> _setAdaptiveCameraQualityMode(
    _AdaptiveCameraQualityMode _, {
    required String reason,
    bool force = false,
  }) async {
    if (!_openpilotOverlayMode || _cameraSuspendedByLifecycle) return;
    if (_adaptiveCameraQualityBusy) return;
    if (!force && _adaptiveCameraQualitySynced) {
      return;
    }
    _adaptiveCameraQualityBusy = true;
    final modeLabel =
        _adaptiveCameraQualityLabel(_AdaptiveCameraQualityMode.lowLatency);
    try {
      final response = await _sidecarPostJson(
        '/camera_quality',
        body: <String, dynamic>{'mode': modeLabel},
      );
      if (response['ok'] != true) {
        throw Exception(response['error']?.toString() ?? 'unknown error');
      }
      _adaptiveCameraQualityMode = _AdaptiveCameraQualityMode.lowLatency;
      _adaptiveCameraQualitySynced = true;
      _pushSidecarHistory('CAM_QUALITY', 'mode=$modeLabel reason=$reason');
    } catch (e) {
      _adaptiveCameraQualitySynced = false;
      _pushSidecarHistory(
          'CAM_QUALITY_FAIL', 'mode=$modeLabel reason=$reason $e');
    } finally {
      _adaptiveCameraQualityBusy = false;
    }
  }

  String _fmtClock(DateTime? when) {
    if (when == null) return '-';
    final t = when.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Map<String, String> _parseStatusPairs(String raw) {
    final parsed = <String, String>{};
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final idx = trimmed.indexOf('=');
      if (idx <= 0) continue;
      final key = trimmed.substring(0, idx).trim();
      final value = trimmed.substring(idx + 1).trim();
      if (key.isEmpty) continue;
      parsed[key] = value;
    }
    return parsed;
  }

  Future<void> _refreshSidecarProcessStatus() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      if (!mounted) {
        _sidecarProcessSnapshot = <String, String>{};
        _sidecarHealthSnapshot = <String, dynamic>{};
        _sidecarProcessCheckedAt = DateTime.now();
        _sidecarProcessStatusError = 'SSH 연결 안됨';
        return;
      }
      setState(() {
        _sidecarProcessSnapshot = <String, String>{};
        _sidecarHealthSnapshot = <String, dynamic>{};
        _sidecarProcessCheckedAt = DateTime.now();
        _sidecarProcessStatusError = 'SSH 연결 안됨';
      });
      return;
    }

    final now = DateTime.now();
    final nextProcess = <String, String>{};
    var nextHealth = <String, dynamic>{};
    String? nextError;
    try {
      final statusRaw = await _sidecarService.status(ssh);
      nextProcess.addAll(_parseStatusPairs(statusRaw));
      try {
        nextHealth = await _sidecarGetJson('/health');
      } catch (e) {
        nextError = 'health 조회 실패: $e';
      }
    } catch (e) {
      nextError = e.toString();
    }

    if (!mounted) {
      _sidecarProcessSnapshot = nextProcess;
      _sidecarHealthSnapshot = nextHealth;
      _sidecarProcessCheckedAt = now;
      _sidecarProcessStatusError = nextError;
      return;
    }
    setState(() {
      _sidecarProcessSnapshot = nextProcess;
      _sidecarHealthSnapshot = nextHealth;
      _sidecarProcessCheckedAt = now;
      _sidecarProcessStatusError = nextError;
    });
  }

  Widget _statusLine(
    String label,
    String value, {
    double labelWidth = 126,
    double labelFontSize = 13,
    double valueFontSize = 13,
    EdgeInsets? padding,
    Color? valueColor,
  }) {
    return Padding(
      padding: padding ?? const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: TextStyle(color: Colors.white60, fontSize: labelFontSize),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: valueFontSize,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _debugMetricPill(String label, String value) {
    final window = UiWindowInfo.of(context);
    final minWidth = switch (window.windowClass) {
      UiWindowClass.compact => 102.0,
      UiWindowClass.medium => 108.0,
      UiWindowClass.expanded => 114.0,
      UiWindowClass.large => 120.0,
      UiWindowClass.extraLarge => 128.0,
    };
    final horizontalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 9.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large => 10.0,
      UiWindowClass.extraLarge => 11.0,
    };
    final verticalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 9.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large => 10.0,
      UiWindowClass.extraLarge => 11.0,
    };
    return Container(
      constraints: BoxConstraints(minWidth: minWidth),
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF231A14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  void _pushSidecarHistory(String type, String summary) {
    final line = '[${_fmtClock(DateTime.now())}] $type $summary';
    _sidecarHistory.addFirst(line);
    while (_sidecarHistory.length > 20) {
      _sidecarHistory.removeLast();
    }
  }

  void _tickOverlayDebugMetrics(_DriveOverlaySnapshot next, DateTime now) {
    final nowMs = now.millisecondsSinceEpoch;
    if (_overlayDebugWindowStartMs <= 0) {
      _overlayDebugWindowStartMs = nowMs;
      _overlayDebugWindowFrames = 0;
    }
    _overlayDebugWindowFrames += 1;
    final elapsed = nowMs - _overlayDebugWindowStartMs;
    if (elapsed >= 1000) {
      _overlayDebugFps = (_overlayDebugWindowFrames * 1000.0) / elapsed;
      _overlayDebugWindowStartMs = nowMs;
      _overlayDebugWindowFrames = 0;
    }

    final modelFrame = next.modelFrameId;
    if (modelFrame != null) {
      final prev = _overlayPrevModelFrameId;
      if (prev != null && modelFrame > prev + 1) {
        _overlayDropCount += (modelFrame - prev - 1);
      }
      _overlayPrevModelFrameId = modelFrame;
    }

    final camFrame = _cameraFrameIdFromSnapshot(next);
    if (modelFrame != null && camFrame != null) {
      _overlayModelCameraGap = (modelFrame - camFrame).abs();
    }
  }

  Future<void> _showDebugTextDialog(String title, String content) async {
    if (!mounted) return;
    final window = UiWindowInfo.of(context);
    final dialogMaxWidth = switch (window.windowClass) {
      UiWindowClass.compact => 420.0,
      UiWindowClass.medium => 520.0,
      UiWindowClass.expanded => 620.0,
      UiWindowClass.large => 700.0,
      UiWindowClass.extraLarge => 760.0,
    };
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: dialogMaxWidth,
          child: SingleChildScrollView(
            child: SelectableText(
              content,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Future<void> _debugActionHealth() async {
    try {
      await _refreshSidecarProcessStatus();
      _pushSidecarHistory('CHECK', 'health');
      _toast('헬스체크 완료');
    } catch (e) {
      _pushSidecarHistory('FAIL', 'health: $e');
      _toast('헬스체크 실패: $e', isError: true);
    }
  }

  Future<void> _debugActionWsProbe() async {
    try {
      await _waitForSidecarReady();
      _pushSidecarHistory('CHECK', 'ws probe ok');
      _toast('WS 프로브 성공');
    } catch (e) {
      _pushSidecarHistory('FAIL', 'ws probe: $e');
      _toast('WS 프로브 실패: $e', isError: true);
    }
  }

  Future<void> _debugActionTailLog() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _toast('SSH 연결 안됨', isError: true);
      return;
    }
    try {
      final text = await _sidecarService.tailLog(ssh, lines: 50);
      _pushSidecarHistory('CHECK', 'tail log');
      await _showDebugTextDialog('사이드카 로그 tail(50)', text.trim());
    } catch (e) {
      _pushSidecarHistory('FAIL', 'tail log: $e');
      _toast('로그 조회 실패: $e', isError: true);
    }
  }

  Future<void> _debugActionRedeploy() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _toast('SSH 연결 안됨', isError: true);
      return;
    }
    try {
      _setSidecarPhase(_SidecarPhase.deploying, message: '수동 재배포 중...');
      await _sidecarService.deploy(ssh);
      _sidecarLastDeployAt = DateTime.now();
      _sidecarLastDeployResult = 'success';
      _sidecarLocalRevision = await _sidecarService.localRevision();
      _sidecarRemoteRevision = await _sidecarService.remoteRevision(ssh);
      _sidecarLastRevisionCheckedAt = DateTime.now();
      _sidecarRevisionAction = 'manual_deploy';
      _pushSidecarHistory('MANUAL_DEPLOY', 'ok');
      await _refreshSidecarProcessStatus();
      _setSidecarPhase(_SidecarPhase.idle, message: '재배포 완료');
      _toast('재배포 완료 (sha256:${_shortSidecarRevision(_sidecarLocalRevision)})');
    } catch (e) {
      _sidecarLastDeployResult = 'fail';
      _sidecarRevisionAction = 'manual_deploy_fail';
      _pushSidecarHistory('FAIL', 'redeploy: $e');
      _setSidecarPhase(_SidecarPhase.failed, message: e.toString());
      _toast('재배포 실패: $e', isError: true);
    }
  }

  Future<void> _debugActionRestart() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _toast('SSH 연결 안됨', isError: true);
      return;
    }
    try {
      _setSidecarPhase(_SidecarPhase.stopping, message: '수동 재시작(중지)...');
      await _sidecarService.stop(ssh);
      _sidecarLastStopAt = DateTime.now();
      _setSidecarPhase(_SidecarPhase.starting, message: '수동 재시작(시작)...');
      await _sidecarService.start(ssh);
      _sidecarLastStartAt = DateTime.now();
      await _waitForSidecarReady();
      _startSidecarLoop();
      _pushSidecarHistory('MANUAL_RESTART', 'ok');
      await _refreshSidecarProcessStatus();
      _setSidecarPhase(_SidecarPhase.running, message: '재시작 완료');
      _toast('재시작 완료');
    } catch (e) {
      _pushSidecarHistory('FAIL', 'restart: $e');
      _setSidecarPhase(_SidecarPhase.failed, message: e.toString());
      _toast('재시작 실패: $e', isError: true);
    }
  }

  Future<bool> _confirmDebugAction({
    required String title,
    required String message,
    String confirmText = '실행',
  }) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _debugActionResetSidecar() async {
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _toast('SSH 연결 안됨', isError: true);
      return;
    }

    final confirmed = await _confirmDebugAction(
      title: '사이드카 테스트 초기화',
      message: '사이드카 파일/로그를 삭제하고 프로세스 등록도 제거합니다.\n'
          '완전 초기 상태 테스트용입니다. 계속할까요?',
      confirmText: '초기화',
    );
    if (!confirmed) return;

    try {
      _setSidecarPhase(_SidecarPhase.stopping, message: '사이드카 초기화 중...');
      _stopSidecarLoop();
      await _sidecarService.resetForTesting(ssh,
          removeManagerRegistration: true);
      _sidecarLastStopAt = DateTime.now();
      _sidecarLastDeployAt = null;
      _sidecarLastDeployResult = '-';
      _sidecarLocalRevision = null;
      _sidecarRemoteRevision = null;
      _sidecarLastRevisionCheckedAt = DateTime.now();
      _sidecarRevisionAction = 'reset';
      _sidecarLastBootstrapAt = DateTime.now();
      _sidecarLastBootstrapResult = 'reset';
      _sidecarLastBootstrapDetail = 'manual testing reset';
      await _setSidecarBootstrapDone(false);
      _pushSidecarHistory('MANUAL_RESET', 'sidecar wiped for clean test');
      await _refreshSidecarProcessStatus();
      _setSidecarPhase(_SidecarPhase.idle, message: '사이드카 초기화 완료');
      _toast('사이드카 초기화 완료');
    } catch (e) {
      _pushSidecarHistory('FAIL', 'reset: $e');
      _setSidecarPhase(_SidecarPhase.failed, message: e.toString());
      _toast('사이드카 초기화 실패: $e', isError: true);
    }
  }

  String _buildDebugSnapshotText() {
    final process = _sidecarProcessSnapshot;
    final health = _sidecarHealthSnapshot;
    return [
      'time=${DateTime.now().toIso8601String()}',
      'phase=$_sidecarPhase',
      'connected=$_sidecarConnected',
      'cameraQuality=${_adaptiveCameraQualityLabel(_adaptiveCameraQualityMode)} score=$_adaptiveBadScore',
      'deploy=$_sidecarLastDeployResult at ${_fmtClock(_sidecarLastDeployAt)}',
      'revision local=${_shortSidecarRevision(_sidecarLocalRevision)} remote=${_shortSidecarRevision(_sidecarRemoteRevision)} action=$_sidecarRevisionAction checked=${_fmtClock(_sidecarLastRevisionCheckedAt)}',
      'bootstrap=$_sidecarLastBootstrapResult at ${_fmtClock(_sidecarLastBootstrapAt)} done=${_sidecarBootstrapDone ?? false}',
      'start=${_fmtClock(_sidecarLastStartAt)} stop=${_fmtClock(_sidecarLastStopAt)}',
      'process=${jsonEncode(process)}',
      'health=${jsonEncode(health)}',
      'lastFrame=${_fmtClock(_sidecarLastFrameAt)} fps=${_overlayDebugFps.toStringAsFixed(1)} gap=${_overlayModelCameraGap ?? '-'} drops=$_overlayDropCount',
      'toggles=ar=$_debugShowArOverlay path=$_debugShowPathFill lane=$_debugShowLaneLines edge=$_debugShowRoadEdge lead1=$_debugShowLead1 lead2=$_debugShowLead2 radarBadge=$_debugShowRadarBadge radarVector=$_debugShowRadarVector tf=$_debugShowStopDistanceTf state=$_debugShowStateText',
      'preview=mode=$_debugOverlayPreviewMode scenario=${_overlayPreviewScenarioLabel(_debugOverlayPreviewScenario)} speed=${_debugOverlayPreviewSpeed.toStringAsFixed(2)}x',
      if ((_sidecarProcessStatusError ?? '').trim().isNotEmpty)
        'error=${_sidecarProcessStatusError!.trim()}',
    ].join('\n');
  }

  Future<void> _copyDebugSnapshot() async {
    final text = _buildDebugSnapshotText();
    await Clipboard.setData(ClipboardData(text: text));
    _pushSidecarHistory('CHECK', 'snapshot copied');
    _toast('디버그 스냅샷 복사 완료');
  }

  bool get _isSidecarBusy =>
      _sidecarPhase == _SidecarPhase.deploying ||
      _sidecarPhase == _SidecarPhase.starting ||
      _sidecarPhase == _SidecarPhase.verifying ||
      _sidecarPhase == _SidecarPhase.stopping;

  bool get _showSidecarStatusBanner =>
      !_debugOverlayPreviewMode &&
      (_isSidecarBusy ||
          _sidecarPhase == _SidecarPhase.failed ||
          (_openpilotOverlayMode && !_sidecarConnected));

  String _sidecarStatusTitle() {
    if (_sidecarPhase == _SidecarPhase.failed) return '사이드카 준비 실패';
    if (_isSidecarBusy) return '사이드카 준비 중...';
    if (_openpilotOverlayMode && !_sidecarConnected) return '사이드카 연결 대기 중...';
    if (_sidecarPhase == _SidecarPhase.running) return '사이드카 실행 중';
    return '사이드카 비활성';
  }

  Color _sidecarStatusColor() {
    if (_sidecarPhase == _SidecarPhase.failed) return const Color(0xCC7A1010);
    if (_isSidecarBusy) return const Color(0xCC4A2E12);
    return const Color(0xCC1E3A2A);
  }

  void _setSidecarPhase(
    _SidecarPhase phase, {
    String? message,
  }) {
    final busy = phase == _SidecarPhase.deploying ||
        phase == _SidecarPhase.starting ||
        phase == _SidecarPhase.verifying ||
        phase == _SidecarPhase.stopping;
    if (mounted) {
      setState(() {
        _sidecarPhase = phase;
        _sidecarPhaseMessage = message;
        _sidecarTransitioning = busy;
        if (busy) {
          _cameraError = null;
        }
      });
    } else {
      _sidecarPhase = phase;
      _sidecarPhaseMessage = message;
      _sidecarTransitioning = busy;
      if (busy) {
        _cameraError = null;
      }
    }
  }

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

  _M3 _rotationFromEulerForVideo(List<double> rpy) {
    if (rpy.length < 3) return const _M3.identity();
    final roll = rpy[0];
    final pitch = rpy[1];
    final yaw = rpy[2];

    final cr = math.cos(roll);
    final sr = math.sin(roll);
    final cp = math.cos(pitch);
    final sp = math.sin(pitch);
    final cy = math.cos(yaw);
    final sy = math.sin(yaw);

    final rx = _M3(
      1.0,
      0.0,
      0.0,
      0.0,
      cr,
      -sr,
      0.0,
      sr,
      cr,
    );
    final ry = _M3(
      cp,
      0.0,
      sp,
      0.0,
      1.0,
      0.0,
      -sp,
      0.0,
      cp,
    );
    final rz = _M3(
      cy,
      -sy,
      0.0,
      sy,
      cy,
      0.0,
      0.0,
      0.0,
      1.0,
    );
    return rz.multiply(ry).multiply(rx);
  }

  _M3 _intrinsicForVideo(Size source, bool wideCam) {
    final sx = source.width / 1928.0;
    final sy = source.height / 1208.0;
    final focal = wideCam ? 567.0 : 2648.0;
    return _M3(
      focal * sx,
      0.0,
      964.0 * sx,
      0.0,
      focal * sy,
      604.0 * sy,
      0.0,
      0.0,
      1.0,
    );
  }

  _DriveVideoPlacement _buildVideoPlacement({
    required Size source,
    required Size viewport,
    required _DriveOverlaySnapshot snapshot,
    required _DriveCameraKind cameraKind,
    required bool coverViewport,
    required bool openpilotTransform,
  }) {
    final fitScale = coverViewport
        ? math.max(
            viewport.width / source.width, viewport.height / source.height)
        : math.min(
            viewport.width / source.width, viewport.height / source.height);

    var scale = fitScale;
    var xOffset = 0.0;
    var yOffset = 0.0;
    var dx = (viewport.width - source.width * scale) * 0.5;
    var dy = (viewport.height - source.height * scale) * 0.5;

    if (openpilotTransform) {
      final wideCam = cameraKind == _DriveCameraKind.wideRoad;
      final zoom = wideCam ? 2.0 : 1.1;
      scale = fitScale * zoom;

      final intrinsic = _intrinsicForVideo(source, wideCam);
      final deviceFromCalib =
          _rotationFromEulerForVideo(snapshot.calibrationRpy);
      final wideFromDevice = wideCam
          ? _rotationFromEulerForVideo(snapshot.wideFromDeviceEuler)
          : const _M3.identity();
      final viewFromCalib = wideCam
          ? _viewFromDevice.multiply(wideFromDevice.multiply(deviceFromCalib))
          : _viewFromDevice.multiply(deviceFromCalib);
      final calibTransform = intrinsic.multiply(viewFromCalib);
      final inf = calibTransform.transform(const _V3(1000.0, 0.0, 0.0));
      if (inf.z.isFinite && inf.z.abs() > 1e-6) {
        final centerX = intrinsic.m02;
        final centerY = intrinsic.m12;
        final maxXOffset =
            math.max(0.0, centerX * scale - viewport.width * 0.5 - 5.0);
        final maxYOffset =
            math.max(0.0, centerY * scale - viewport.height * 0.5 - 5.0);
        xOffset = (((inf.x / inf.z) - centerX) * scale)
            .clamp(-maxXOffset, maxXOffset)
            .toDouble();
        yOffset = (((inf.y / inf.z) - centerY) * scale)
            .clamp(-maxYOffset, maxYOffset)
            .toDouble();
        dx = (viewport.width * 0.5 - xOffset) - (centerX * scale);
        dy = (viewport.height * 0.5 - yOffset) - (centerY * scale);
      } else {
        dx = (viewport.width - source.width * scale) * 0.5;
        dy = (viewport.height - source.height * scale) * 0.5;
      }
    }

    return _DriveVideoPlacement(
      left: dx,
      top: dy,
      width: source.width * scale,
      height: source.height * scale,
      scale: scale,
      xOffset: xOffset,
      yOffset: yOffset,
    );
  }

  Future<void> _waitForSidecarReady({
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 300),
    Duration healthTimeout = const Duration(seconds: 2),
    Duration wsTimeout = const Duration(seconds: 2),
  }) async {
    Future<void> probeHealth() async {
      final client = HttpClient()..connectionTimeout = healthTimeout;
      try {
        final request = await client.getUrl(_sidecarHttpUri('/health')).timeout(
              healthTimeout,
            );
        final response = await request.close().timeout(healthTimeout);
        final body = await utf8.decodeStream(response).timeout(healthTimeout);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('health http ${response.statusCode}');
        }
        final decoded =
            body.trim().isEmpty ? <String, dynamic>{} : jsonDecode(body);
        if (decoded is! Map || decoded['ok'] != true) {
          throw Exception('health not ok');
        }
      } finally {
        client.close(force: true);
      }
    }

    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        await probeHealth();

        WebSocket? ws;
        try {
          ws = await WebSocket.connect(_liveCameraWsUrl).timeout(wsTimeout);
        } finally {
          await ws?.close();
        }
        return;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(pollInterval);
      }
    }
    throw Exception('ready timeout: $lastError');
  }

  Future<void> _ensureSidecarRuntime({String reason = 'auto'}) async {
    if (!_openpilotOverlayMode || _cameraSuspendedByLifecycle) return;
    if (_debugOverlayPreviewMode) return;
    if (_sidecarAutoManaging) return;
    _cancelDelayedSidecarStop();
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) return;
    _sidecarAutoManaging = true;
    _suppressCameraErrors = true;
    _pushSidecarHistory('AUTO_RUNTIME', 'start reason=$reason');
    _setSidecarPhase(
      _SidecarPhase.verifying,
      message: '사이드카 실행 상태를 확인하는 중입니다.',
    );
    if (mounted) {
      setState(() => _cameraLoading = true);
    } else {
      _cameraLoading = true;
    }
    try {
      await _ensureSidecarRevisionUpToDate(ssh);
      final statusRaw = await _sidecarService.status(ssh);
      final status = _parseStatusPairs(statusRaw);
      final running = status['running'] == '1';
      final listening = status['listening'] == '1';
      if (running && listening) {
        _pushSidecarHistory('AUTO_RUNTIME', 'reuse running/listening runtime');
      } else {
        _setSidecarPhase(
          _SidecarPhase.starting,
          message: running || listening ? '사이드카 런타임 복구 중...' : '사이드카 시작 중...',
        );
        try {
          await _sidecarService.start(ssh);
          _sidecarLastStartAt = DateTime.now();
          _pushSidecarHistory('AUTO_START', 'start ok');
        } catch (startError) {
          _pushSidecarHistory('AUTO_START_FAIL', '$startError');
          var recoveredByBootstrap = false;
          if (!_autoDeployDuringHudRuntime) {
            recoveredByBootstrap = await _tryAutoBootstrapSidecar(
              ssh,
              startError: startError,
            );
            if (recoveredByBootstrap) {
              _setSidecarPhase(
                _SidecarPhase.starting,
                message: '사이드카 시작 중...',
              );
              await _sidecarService.start(ssh);
              _sidecarLastStartAt = DateTime.now();
              _pushSidecarHistory('AUTO_START', 'start ok (after bootstrap)');
            }
          }
          if (recoveredByBootstrap) {
            // no-op; startup recovered
          } else if (_autoDeployDuringHudRuntime) {
            _setSidecarPhase(
              _SidecarPhase.deploying,
              message: '사이드카 배포/복구 중...',
            );
            await _sidecarService.deploy(ssh);
            _sidecarLastDeployAt = DateTime.now();
            _sidecarLastDeployResult = 'success';
            _pushSidecarHistory('AUTO_DEPLOY', 'ok');
            _setSidecarPhase(
              _SidecarPhase.starting,
              message: '사이드카 시작 중...',
            );
            await _sidecarService.start(ssh);
            _sidecarLastStartAt = DateTime.now();
            _pushSidecarHistory('AUTO_RESTART', 'start ok (after deploy)');
          } else {
            rethrow;
          }
        }
      }

      _startSidecarLoop();
      _setSidecarPhase(
        _SidecarPhase.verifying,
        message: '카메라 스트림 연결 확인 중...',
      );
      try {
        await _waitForSidecarReady(
          timeout: const Duration(milliseconds: 2200),
          pollInterval: const Duration(milliseconds: 150),
          healthTimeout: const Duration(milliseconds: 700),
          wsTimeout: const Duration(milliseconds: 700),
        );
        _setSidecarPhase(
          _SidecarPhase.running,
          message: '사이드카 실행 중',
        );
      } catch (e) {
        _pushSidecarHistory('READY_DEFER', '$e');
        _setSidecarPhase(
          _SidecarPhase.running,
          message: '사이드카 연결 대기 중...',
        );
      }
      unawaited(_refreshSidecarProcessStatus());
      _clearSidecarRecoverySchedule();
      _suppressCameraErrors = false;
    } catch (e) {
      if (_autoDeployDuringHudRuntime) {
        _sidecarLastDeployResult = 'fail';
      }
      _pushSidecarHistory('FAIL', 'auto runtime: $e');
      _setSidecarPhase(
        _SidecarPhase.failed,
        message: e.toString(),
      );
      _scheduleSidecarRuntimeRecovery(reason: 'runtime_failed');
      if (mounted) {
        _toast(
          '사이드카 자동 준비 실패: $e',
          isError: true,
          duration: const Duration(seconds: 5),
        );
      }
    } finally {
      _sidecarAutoManaging = false;
    }
  }

  Future<void> _stopSidecarProcessIfNeeded({bool force = false}) async {
    if (_sidecarAutoManaging) return;
    if (_residentSidecarManaged && !force) {
      _pushSidecarHistory('AUTO_STOP_SKIP', 'resident sidecar mode');
      _setSidecarPhase(_SidecarPhase.idle);
      return;
    }
    _cancelDelayedSidecarStop();
    _clearSidecarRecoverySchedule();
    final ssh = _sshService ??
        (mounted ? Provider.of<SSHService>(context, listen: false) : null);
    if (ssh == null || !ssh.isConnected) {
      _setSidecarPhase(_SidecarPhase.idle);
      return;
    }
    _sidecarAutoManaging = true;
    _pushSidecarHistory('AUTO_STOP', 'start');
    _setSidecarPhase(
      _SidecarPhase.stopping,
      message: '사이드카 프로세스를 중지하는 중입니다.',
    );
    try {
      await _sidecarService.stop(ssh);
      _sidecarLastStopAt = DateTime.now();
      _pushSidecarHistory('AUTO_STOP', 'ok');
      unawaited(_refreshSidecarProcessStatus());
    } catch (_) {
      // Ignore stop errors during lifecycle transitions.
    } finally {
      _sidecarAutoManaging = false;
      _setSidecarPhase(_SidecarPhase.idle);
    }
  }

  Future<void> _openDebugOptionsPopup() async {
    if (!_hudDebugMenuEnabled) {
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
    const debugDialogBg = Color(0xFF17120F);
    const debugNavBg = Color(0xFF211A15);
    const debugCardBg = Color(0xFF1F1712);
    const debugCardBgAlt = Color(0xFF231A14);
    const debugPanelBg = Color(0xFF1D1612);
    const debugSelectedBg = Color(0xFF7A5644);
    const debugSelectedBorder = Color(0xFFD6A88C);

    await showDialog<void>(
      context: context,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final debugEnabled =
                !_temporaryLimitedHudControls && _overlayVerifyMode;
            final process = _sidecarProcessSnapshot;
            final health = _sidecarHealthSnapshot;
            final running = process.isEmpty
                ? '-'
                : ((process['running'] == '1') ? '실행' : '중지');
            final listening = process.isEmpty
                ? '-'
                : ((process['listening'] == '1') ? 'LISTEN' : '닫힘');
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

            final history = _sidecarHistory.take(10).toList(growable: false);
            final layerToggleEnabled = _openpilotOverlayMode;

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

            Widget layerSwitch(
              String title,
              bool value,
              ValueChanged<bool>? onChanged,
            ) {
              return SwitchListTile(
                dense: false,
                contentPadding: EdgeInsets.zero,
                value: value,
                onChanged: onChanged,
                title: Text(title),
              );
            }

            Widget groupNavItem({
              required int index,
              required IconData icon,
              required String label,
            }) {
              final selected = selectedGroup == index;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setLocalState(() => selectedGroup = index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected ? debugSelectedBg : debugNavBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected ? debugSelectedBorder : Colors.white12,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(icon, size: 18, color: Colors.white),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
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

            Widget sectionCard(
              String title,
              Widget child, {
              Widget? trailing,
            }) {
              final cardPadding = EdgeInsets.fromLTRB(
                window.isCompact ? 14 : 16,
                window.isCompact ? 12 : 14,
                window.isCompact ? 14 : 16,
                window.isCompact ? 12 : 14,
              );
              final titleFont = window.isCompact ? 14.0 : 15.0;
              return Container(
                width: double.infinity,
                margin: EdgeInsets.only(bottom: window.isCompact ? 12 : 14),
                padding: cardPadding,
                decoration: BoxDecoration(
                  color: debugCardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: titleFont,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (trailing != null) trailing,
                      ],
                    ),
                    SizedBox(height: window.isCompact ? 6 : 8),
                    child,
                  ],
                ),
              );
            }

            Widget statusMetricCard(
              String label,
              String value, {
              Color? valueColor,
            }) {
              return Container(
                padding: EdgeInsets.all(statusCardPadding),
                decoration: BoxDecoration(
                  color: debugCardBgAlt,
                  borderRadius: BorderRadius.circular(statusCardRadius),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: statusLabelFont,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: valueColor ?? Colors.white,
                        fontSize: statusValueFont + 1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              );
            }

            Widget statusGrid(
              List<({String label, String value, Color? color})> items, {
              int? columns,
            }) {
              return LayoutBuilder(
                builder: (context, constraints) {
                  final targetColumns = columns ??
                      (constraints.maxWidth >= 760
                          ? 3
                          : (constraints.maxWidth >= 520 ? 2 : 1));
                  final width = (constraints.maxWidth -
                          statusGridSpacing * (targetColumns - 1)) /
                      targetColumns;
                  return Wrap(
                    spacing: statusGridSpacing,
                    runSpacing: statusGridSpacing,
                    children: [
                      for (final item in items)
                        SizedBox(
                          width: width,
                          child: statusMetricCard(
                            item.label,
                            item.value,
                            valueColor: item.color,
                          ),
                        ),
                    ],
                  );
                },
              );
            }

            Widget groupNavChip({
              required int index,
              required IconData icon,
              required String label,
            }) {
              final selected = selectedGroup == index;
              return ChoiceChip(
                selected: selected,
                onSelected: (_) => setLocalState(() => selectedGroup = index),
                selectedColor: debugSelectedBg,
                backgroundColor: debugNavBg,
                side: BorderSide(
                  color: selected ? debugSelectedBorder : Colors.white12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                avatar: Icon(icon, size: chipIconSize, color: Colors.white),
                label: Text(
                  label,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: chipFontSize,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: const VisualDensity(
                  horizontal: -1,
                  vertical: -1,
                ),
              );
            }

            return Dialog(
              backgroundColor: debugDialogBg,
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
                        color: debugPanelBg,
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
                              color: debugPanelBg,
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
                                  color: debugCardBgAlt,
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
                                                      label: '프로세스',
                                                      value:
                                                          '$running / $listening',
                                                      color: null
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
                                                          'ok:$healthOk profile:$healthProfile clients:$healthClients',
                                                      color: (healthOk == 'ok')
                                                          ? const Color(
                                                              0xFF73E07C)
                                                          : const Color(
                                                              0xFFFF8A8A)
                                                    ),
                                                    (
                                                      label: '카메라 릴레이',
                                                      value: relayState,
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
                                                if (!layerToggleEnabled)
                                                  const Padding(
                                                    padding: EdgeInsets.only(
                                                        bottom: 6),
                                                    child: Align(
                                                      alignment:
                                                          Alignment.centerLeft,
                                                      child: Text(
                                                        '현재 WebRTC 모드라 레이어 토글이 비활성화됩니다.',
                                                        style: TextStyle(
                                                          color: Colors.white54,
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                layerSwitch(
                                                  'AR Overlay 표시',
                                                  _debugShowArOverlay,
                                                  layerToggleEnabled
                                                      ? (value) {
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
                                                                _overlayNotifier
                                                                    .value,
                                                                force: true,
                                                              ),
                                                            );
                                                          }
                                                        }
                                                      : null,
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
                                                  layerToggleEnabled
                                                      ? (value) {
                                                          _onLayerToggleChanged(
                                                            setLocalState,
                                                            () =>
                                                                _debugShowPathFill =
                                                                    value,
                                                          );
                                                        }
                                                      : null,
                                                ),
                                                layerSwitch(
                                                  'Lane Lines',
                                                  _debugShowLaneLines,
                                                  layerToggleEnabled
                                                      ? (value) {
                                                          _onLayerToggleChanged(
                                                            setLocalState,
                                                            () =>
                                                                _debugShowLaneLines =
                                                                    value,
                                                          );
                                                        }
                                                      : null,
                                                ),
                                                layerSwitch(
                                                  'Road Edge',
                                                  _debugShowRoadEdge,
                                                  layerToggleEnabled
                                                      ? (value) {
                                                          _onLayerToggleChanged(
                                                            setLocalState,
                                                            () =>
                                                                _debugShowRoadEdge =
                                                                    value,
                                                          );
                                                        }
                                                      : null,
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
                                                  layerToggleEnabled
                                                      ? (value) {
                                                          _onLayerToggleChanged(
                                                            setLocalState,
                                                            () =>
                                                                _debugShowLead1 =
                                                                    value,
                                                          );
                                                        }
                                                      : null,
                                                ),
                                                layerSwitch(
                                                  'Lead2',
                                                  _debugShowLead2,
                                                  layerToggleEnabled
                                                      ? (value) {
                                                          _onLayerToggleChanged(
                                                            setLocalState,
                                                            () =>
                                                                _debugShowLead2 =
                                                                    value,
                                                          );
                                                        }
                                                      : null,
                                                ),
                                                layerSwitch(
                                                  'Radar Badge',
                                                  _debugShowRadarBadge,
                                                  layerToggleEnabled
                                                      ? (value) {
                                                          _onLayerToggleChanged(
                                                            setLocalState,
                                                            () =>
                                                                _debugShowRadarBadge =
                                                                    value,
                                                          );
                                                        }
                                                      : null,
                                                ),
                                                layerSwitch(
                                                  'Radar Vector',
                                                  _debugShowRadarVector,
                                                  layerToggleEnabled
                                                      ? (value) {
                                                          _onLayerToggleChanged(
                                                            setLocalState,
                                                            () =>
                                                                _debugShowRadarVector =
                                                                    value,
                                                          );
                                                        }
                                                      : null,
                                                ),
                                                layerSwitch(
                                                  'Stop-distance (TF)',
                                                  _debugShowStopDistanceTf,
                                                  layerToggleEnabled
                                                      ? (value) {
                                                          _onLayerToggleChanged(
                                                            setLocalState,
                                                            () =>
                                                                _debugShowStopDistanceTf =
                                                                    value,
                                                          );
                                                        }
                                                      : null,
                                                ),
                                                layerSwitch(
                                                  'State Text',
                                                  _debugShowStateText,
                                                  layerToggleEnabled
                                                      ? (value) {
                                                          _onLayerToggleChanged(
                                                            setLocalState,
                                                            () =>
                                                                _debugShowStateText =
                                                                    value,
                                                          );
                                                        }
                                                      : null,
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
                                                  _temporaryLimitedHudControls
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
                                                  _temporaryLimitedHudControls
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
                                                  dropdownColor: debugCardBg,
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
                                                              setState(() {
                                                                _debugOverlayPreviewScenario =
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
                                                              setState(() {
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

  Widget _buildDriveCameraSurface() {
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
          setState(() {
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

  String? _cameraCenterNoticeMessage() {
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

  Widget _buildDriveModeTag(UiWindowInfo window) {
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

  double _computePortraitHudHeight(
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

  Widget _buildPortraitHudPanel(UiWindowInfo window) {
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

  bool _shouldHideHudForTinyViewport(
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

  double _computeLandscapeHudOverlaySize(UiWindowInfo window, Size drawSize) {
    final base = math.min(drawSize.width, drawSize.height);
    final ratio = switch (window.windowClass) {
      UiWindowClass.compact => 0.33,
      UiWindowClass.medium => 0.315,
      UiWindowClass.expanded => 0.30,
      UiWindowClass.large => 0.285,
      UiWindowClass.extraLarge => 0.27,
    };
    final minSize = switch (window.windowClass) {
      UiWindowClass.compact => 200.0,
      UiWindowClass.medium => 220.0,
      UiWindowClass.expanded => 240.0,
      UiWindowClass.large => 260.0,
      UiWindowClass.extraLarge => 280.0,
    };
    final maxSize = switch (window.windowClass) {
      UiWindowClass.compact => 390.0,
      UiWindowClass.medium => 410.0,
      UiWindowClass.expanded => 440.0,
      UiWindowClass.large => 470.0,
      UiWindowClass.extraLarge => 500.0,
    };
    final viewportCap = drawSize.height * 0.52;
    final upperBound = math.max(minSize, math.min(maxSize, viewportCap));
    return (base * ratio).clamp(minSize, upperBound).toDouble();
  }

  Widget _buildLandscapeHudOverlay(UiWindowInfo window, Size drawSize) {
    final size = _computeLandscapeHudOverlaySize(window, drawSize);
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

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final media = MediaQuery.of(context);
    final hingeAware = DisplayFeatureUtils.hingeAwarePadding(context);
    final foldInsets = EdgeInsets.only(
      left: math.max(0.0, hingeAware.left - media.padding.left),
      top: math.max(0.0, hingeAware.top - media.padding.top),
      right: math.max(0.0, hingeAware.right - media.padding.right),
      bottom: math.max(0.0, hingeAware.bottom - media.padding.bottom),
    );

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        unawaited(_restorePortraitOrientation());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF05070C),
        body: SafeArea(
          child: Padding(
            padding: foldInsets,
            child: LayoutBuilder(
              builder: (context, constraints) {
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
                    ? (constraints.maxWidth * dockRatio)
                        .clamp(
                          dockMin,
                          dockMax,
                        )
                        .toDouble()
                    : 0.0;
                final hideHudForTinyViewport = _shouldHideHudForTinyViewport(
                  window,
                  constraints,
                  isLandscape: isLandscapeLayout,
                );

                final mainContent = Row(
                  children: [
                    if (_showDriveDock && isLandscapeLayout)
                      Container(
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
                              icon: const Icon(Icons.arrow_back,
                                  color: Colors.white),
                              tooltip: '나가기',
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
                                    if (_hudDebugMenuEnabled)
                                      IconButton(
                                        onPressed: _temporaryLimitedHudControls
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
                      ),
                    Expanded(
                      child: ColoredBox(
                        color: Colors.black,
                        child: LayoutBuilder(
                          builder: (context, viewport) {
                            var sourceW = _cameraSourceSize.width > 1
                                ? _cameraSourceSize.width
                                : 1928.0;
                            var sourceH = _cameraSourceSize.height > 1
                                ? _cameraSourceSize.height
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
                              openpilotTransform: _openpilotOverlayMode,
                            );
                            final drawW = placement.width;
                            final drawH = placement.height;
                            final left = placement.left;
                            final top = placement.top;
                            final overlayInset = switch (window.windowClass) {
                              UiWindowClass.compact => 12.0,
                              UiWindowClass.medium => 14.0,
                              UiWindowClass.expanded =>
                                window.isLandscape ? 16.0 : 14.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                18.0,
                            };
                            final overlayBottomInset =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 12.0,
                              UiWindowClass.medium => 14.0,
                              UiWindowClass.expanded => 16.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                18.0,
                            };
                            final statusBannerMaxWidth =
                                switch (window.windowClass) {
                              UiWindowClass.compact =>
                                math.min(vw - (overlayInset * 2), 520.0),
                              UiWindowClass.medium =>
                                math.min(vw * 0.72, 620.0),
                              UiWindowClass.expanded =>
                                math.min(vw * 0.62, 700.0),
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                math.min(vw * 0.52, 760.0),
                            };
                            final verifyPanelWidth =
                                switch (window.windowClass) {
                              UiWindowClass.compact =>
                                math.min(vw * 0.58, 420.0),
                              UiWindowClass.medium =>
                                math.min(vw * 0.52, 470.0),
                              UiWindowClass.expanded =>
                                math.min(vw * 0.45, 520.0),
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                math.min(vw * 0.38, 580.0),
                            };
                            final statusBannerPaddingH =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 10.0,
                              UiWindowClass.medium => 11.0,
                              UiWindowClass.expanded => 12.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                13.0,
                            };
                            final statusBannerPaddingV =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 8.0,
                              UiWindowClass.medium => 9.0,
                              UiWindowClass.expanded => 10.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                11.0,
                            };
                            final statusBannerRadius =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 10.0,
                              UiWindowClass.medium => 11.0,
                              UiWindowClass.expanded => 12.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                13.0,
                            };
                            final statusBannerTitleFont =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 13.0,
                              UiWindowClass.medium => 13.5,
                              UiWindowClass.expanded => 14.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                14.5,
                            };
                            final statusBannerBodyFont =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 11.0,
                              UiWindowClass.medium => 11.5,
                              UiWindowClass.expanded => 12.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                12.5,
                            };
                            final statusBannerIconSize =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 16.0,
                              UiWindowClass.medium => 17.0,
                              UiWindowClass.expanded => 18.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                19.0,
                            };
                            final statusBannerGap =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 6.0,
                              UiWindowClass.medium => 7.0,
                              UiWindowClass.expanded => 8.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                9.0,
                            };
                            final statusBannerProgressHeight =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 2.0,
                              UiWindowClass.medium => 2.5,
                              UiWindowClass.expanded => 3.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                3.5,
                            };
                            final statusAlertPadding =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 10.0,
                              UiWindowClass.medium => 11.0,
                              UiWindowClass.expanded => 12.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                13.0,
                            };
                            final centerNoticeMessage =
                                _cameraCenterNoticeMessage();
                            final hasCenterNotice =
                                centerNoticeMessage != null &&
                                    !_debugOverlayPreviewMode;
                            final showBottomStatusBanners = !hasCenterNotice;
                            final hudOverlayBottomInset =
                                switch (window.windowClass) {
                              UiWindowClass.compact => 64.0,
                              UiWindowClass.medium => 66.0,
                              UiWindowClass.expanded => 68.0,
                              UiWindowClass.large ||
                              UiWindowClass.extraLarge =>
                                70.0,
                            };
                            final drawSize = Size(drawW, drawH);
                            if ((_nativeOverlaySize.width - drawW).abs() >
                                    0.5 ||
                                (_nativeOverlaySize.height - drawH).abs() >
                                    0.5) {
                              _nativeOverlaySize = drawSize;
                              if (_useNativeOverlayRenderer) {
                                unawaited(
                                  _pushNativeOverlay(
                                    _overlayNotifier.value,
                                    force: true,
                                  ),
                                );
                              }
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
                                            child: ValueListenableBuilder<
                                                _DriveOverlaySnapshot>(
                                              valueListenable: _overlayNotifier,
                                              builder: (context, overlay, _) {
                                                return IgnorePointer(
                                                  child: CustomPaint(
                                                    painter:
                                                        _DriveOverlayPainter(
                                                      snapshot: overlay,
                                                      isConnected:
                                                          _sidecarConnected,
                                                      sourceSize:
                                                          _cameraSourceSize,
                                                      cameraKind:
                                                          _liveCameraKind,
                                                      coverViewport:
                                                          _coverViewport,
                                                      showDebugGuides:
                                                          _overlayVerifyMode &&
                                                              _debugShowGuides,
                                                      showPathFill:
                                                          _debugShowPathFill,
                                                      showLaneLines:
                                                          _debugShowLaneLines,
                                                      showRoadEdge:
                                                          _debugShowRoadEdge,
                                                      showLead1:
                                                          _debugShowLead1,
                                                      showLead2:
                                                          _debugShowLead2,
                                                      showRadarBadge:
                                                          _debugShowRadarBadge,
                                                      showRadarVector:
                                                          _debugShowRadarVector,
                                                      showStopDistanceTf:
                                                          _debugShowStopDistanceTf,
                                                      showStateText:
                                                          _debugShowStateText,
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        if (_cameraLoading &&
                                            !_debugOverlayPreviewMode)
                                          const Positioned.fill(
                                            child: ColoredBox(
                                              color: Colors.black45,
                                              child: Center(
                                                child:
                                                    CircularProgressIndicator(
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
                                                    maxWidth:
                                                        statusBannerMaxWidth,
                                                  ),
                                                  child: Container(
                                                    margin:
                                                        EdgeInsets.symmetric(
                                                      horizontal:
                                                          overlayInset * 0.5,
                                                    ),
                                                    padding: EdgeInsets.all(
                                                        statusAlertPadding),
                                                    decoration: BoxDecoration(
                                                      color: const Color(
                                                          0xCC1F1712),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              statusBannerRadius),
                                                      border: Border.all(
                                                          color:
                                                              Colors.white24),
                                                    ),
                                                    child: Text(
                                                      centerNoticeMessage,
                                                      textAlign:
                                                          TextAlign.center,
                                                      maxLines: 3,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize:
                                                            statusBannerBodyFont,
                                                        fontWeight:
                                                            FontWeight.w600,
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
                                    right: overlayInset * 0.7,
                                    child: _buildDriveModeTag(window),
                                  ),
                                  if (isLandscapeLayout &&
                                      !hideHudForTinyViewport)
                                    Positioned(
                                      left: overlayInset,
                                      bottom: hudOverlayBottomInset,
                                      child: IgnorePointer(
                                        child: _buildLandscapeHudOverlay(
                                          window,
                                          Size(vw, vh),
                                        ),
                                      ),
                                    ),
                                  if (showBottomStatusBanners &&
                                      _showSidecarStatusBanner)
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
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      statusBannerRadius),
                                              border: Border.all(
                                                  color: Colors.white24),
                                            ),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Icon(
                                                      _sidecarPhase ==
                                                              _SidecarPhase
                                                                  .failed
                                                          ? Icons.error_outline
                                                          : (_sidecarPhase ==
                                                                  _SidecarPhase
                                                                      .stopping
                                                              ? Icons
                                                                  .stop_circle_outlined
                                                              : (_sidecarPhase ==
                                                                      _SidecarPhase
                                                                          .running
                                                                  ? Icons
                                                                      .check_circle_outline
                                                                  : Icons
                                                                      .hourglass_top_rounded)),
                                                      color: Colors.white,
                                                      size:
                                                          statusBannerIconSize,
                                                    ),
                                                    SizedBox(
                                                        width: statusBannerGap),
                                                    Expanded(
                                                      child: Text(
                                                        _sidecarStatusTitle(),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                          fontSize:
                                                              statusBannerTitleFont,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                if (_sidecarPhase ==
                                                        _SidecarPhase.failed &&
                                                    (_sidecarPhaseMessage ?? '')
                                                        .trim()
                                                        .isNotEmpty)
                                                  Padding(
                                                    padding: EdgeInsets.only(
                                                      top:
                                                          statusBannerGap * 0.5,
                                                    ),
                                                    child: Text(
                                                      _sidecarPhaseMessage!
                                                          .trim(),
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: Colors.white70,
                                                        fontSize:
                                                            statusBannerBodyFont,
                                                      ),
                                                    ),
                                                  ),
                                                if (_isSidecarBusy) ...[
                                                  SizedBox(
                                                      height: statusBannerGap),
                                                  ClipRRect(
                                                    borderRadius:
                                                        const BorderRadius.all(
                                                      Radius.circular(999),
                                                    ),
                                                    child:
                                                        LinearProgressIndicator(
                                                      minHeight:
                                                          statusBannerProgressHeight,
                                                      backgroundColor:
                                                          const Color(
                                                              0x553A4C63),
                                                      valueColor:
                                                          const AlwaysStoppedAnimation<
                                                              Color>(
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
                                  else if (showBottomStatusBanners &&
                                      !_hudModeLoaded)
                                    Positioned(
                                      left: overlayInset,
                                      right: overlayInset,
                                      bottom: overlayBottomInset,
                                      child: Container(
                                        padding:
                                            EdgeInsets.all(statusAlertPadding),
                                        decoration: BoxDecoration(
                                          color: const Color(0xCC1F1712),
                                          borderRadius: BorderRadius.circular(
                                              statusBannerRadius),
                                          border:
                                              Border.all(color: Colors.white24),
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
                                        padding:
                                            EdgeInsets.all(statusAlertPadding),
                                        decoration: BoxDecoration(
                                          color: const Color(0xCC7A1010),
                                          borderRadius: BorderRadius.circular(
                                              statusBannerRadius),
                                          border:
                                              Border.all(color: Colors.white24),
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
                                  else if (showBottomStatusBanners &&
                                      _hudNoticeMessage != null)
                                    Positioned(
                                      left: overlayInset,
                                      right: overlayInset,
                                      bottom: overlayBottomInset,
                                      child: Container(
                                        padding:
                                            EdgeInsets.all(statusAlertPadding),
                                        decoration: BoxDecoration(
                                          color: _hudNoticeIsError
                                              ? const Color(0xCC7A1010)
                                              : const Color(0xCC1F1712),
                                          borderRadius: BorderRadius.circular(
                                              statusBannerRadius),
                                          border:
                                              Border.all(color: Colors.white24),
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
                                          padding: EdgeInsets.all(
                                              statusAlertPadding),
                                          decoration: BoxDecoration(
                                            color: const Color(0xCC1B140F),
                                            borderRadius: BorderRadius.circular(
                                                statusBannerRadius),
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
                        ),
                      ),
                    ),
                  ],
                );

                final fabInset = switch (window.windowClass) {
                  UiWindowClass.compact => 12.0,
                  UiWindowClass.medium => 14.0,
                  UiWindowClass.expanded => 16.0,
                  UiWindowClass.large || UiWindowClass.extraLarge => 18.0,
                };
                final hasCenterNotice = _cameraCenterNoticeMessage() != null &&
                    !_debugOverlayPreviewMode;
                final hasBottomStatusBanner = !hasCenterNotice &&
                    (_showSidecarStatusBanner ||
                        !_hudModeLoaded ||
                        (_cameraError?.isNotEmpty ?? false) ||
                        _hudNoticeMessage != null);
                final fabBottom =
                    hasBottomStatusBanner ? (fabInset + 72.0) : fabInset;
                final debugFab = FloatingActionButton.small(
                  heroTag: isLandscapeLayout
                      ? 'drive_debug_fab_landscape'
                      : 'drive_debug_fab_portrait',
                  tooltip: 'HUD 디버그',
                  onPressed: _temporaryLimitedHudControls
                      ? null
                      : _openDebugOptionsPopup,
                  backgroundColor: const Color(0xCC2A1A12),
                  foregroundColor: const Color(0xFFFFB07A),
                  child: const Icon(Icons.tune_rounded),
                );

                if (isLandscapeLayout) {
                  return Stack(
                    children: [
                      Positioned.fill(child: mainContent),
                      if (_hudDebugMenuEnabled)
                        Positioned(
                          right: fabInset,
                          bottom: fabBottom,
                          child: debugFab,
                        ),
                    ],
                  );
                }

                if (hideHudForTinyViewport) {
                  return Stack(
                    children: [
                      Positioned.fill(child: mainContent),
                      if (_hudDebugMenuEnabled)
                        Positioned(
                          right: fabInset,
                          bottom: fabBottom,
                          child: debugFab,
                        ),
                    ],
                  );
                }

                final portraitHudHeight =
                    _computePortraitHudHeight(window, constraints);

                return Column(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(child: mainContent),
                          if (_hudDebugMenuEnabled)
                            Positioned(
                              right: fabInset,
                              bottom: fabBottom,
                              child: debugFab,
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
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewRoadBackdropPainter extends CustomPainter {
  const _PreviewRoadBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final skyRect = Offset.zero & Size(size.width, size.height * 0.58);
    final roadRect =
        Rect.fromLTWH(0, size.height * 0.34, size.width, size.height * 0.66);
    final skyPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0xFF6F88A6),
          Color(0xFF444D58),
        ],
      ).createShader(skyRect);
    final roadPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0xFF3E444C),
          Color(0xFF1D2127),
        ],
      ).createShader(roadRect);
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFF0E1117));
    canvas.drawRect(skyRect, skyPaint);
    canvas.drawRect(roadRect, roadPaint);

    final horizonY = size.height * 0.34;
    final roadPath = Path()
      ..moveTo(size.width * 0.08, size.height)
      ..lineTo(size.width * 0.92, size.height)
      ..lineTo(size.width * 0.59, horizonY)
      ..lineTo(size.width * 0.41, horizonY)
      ..close();
    canvas.drawPath(
      roadPath,
      Paint()
        ..color = const Color(0xFF2A2F36)
        ..style = PaintingStyle.fill,
    );

    final lanePaint = Paint()
      ..color = const Color(0xCCF7F7F7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final dashPaint = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawLine(
      Offset(size.width * 0.28, size.height),
      Offset(size.width * 0.47, horizonY),
      lanePaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.72, size.height),
      Offset(size.width * 0.53, horizonY),
      lanePaint,
    );
    for (var i = 0; i < 7; i++) {
      final t0 = i / 7.0;
      final t1 = (i + 0.5) / 7.0;
      final x0 = size.width * 0.5;
      final y0 = size.height + ((horizonY - size.height) * t0);
      final x1 = size.width * 0.5;
      final y1 = size.height + ((horizonY - size.height) * t1);
      canvas.drawLine(Offset(x0, y0), Offset(x1, y1), dashPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewRoadBackdropPainter oldDelegate) =>
      false;
}

class _DriveOverlaySnapshot {
  final _XyzSeries path;
  final List<_LaneLineSeries> laneLines;
  final List<_RoadEdgeSeries> roadEdges;
  final bool active;
  final bool activeLaneLine;
  final bool carrotExperimentalMode;
  final bool brakeLights;
  final bool leadDetected;
  final int pathMode;
  final int pathColor;
  final double accel0;
  final double aEgo;
  final double? speedMps;
  final double? speedKph;
  final int leftLaneLine;
  final int rightLaneLine;
  final List<double> calibrationRpy;
  final List<double> wideFromDeviceEuler;
  final double pathOffsetZ;
  final double pathWidthRatio;
  final double animationPhase;
  final int? modelFrameId;
  final int? roadFrameId;
  final int? wideRoadFrameId;
  final Map<String, dynamic>? sidecarOverlay2d;
  final bool usingLateralPath;
  final double modelPathXMax;
  final double lateralPathXMax;
  final List<_NavPathPoint> navPathPoints;
  final int navTurnInfo;
  final double? navDistToTurn;
  final String navMainText;

  const _DriveOverlaySnapshot({
    required this.path,
    required this.laneLines,
    required this.roadEdges,
    required this.active,
    required this.activeLaneLine,
    required this.carrotExperimentalMode,
    required this.brakeLights,
    required this.leadDetected,
    required this.pathMode,
    required this.pathColor,
    required this.accel0,
    required this.aEgo,
    required this.speedMps,
    required this.speedKph,
    required this.leftLaneLine,
    required this.rightLaneLine,
    required this.calibrationRpy,
    required this.wideFromDeviceEuler,
    required this.pathOffsetZ,
    required this.pathWidthRatio,
    required this.animationPhase,
    required this.modelFrameId,
    required this.roadFrameId,
    required this.wideRoadFrameId,
    required this.sidecarOverlay2d,
    required this.usingLateralPath,
    required this.modelPathXMax,
    required this.lateralPathXMax,
    required this.navPathPoints,
    required this.navTurnInfo,
    required this.navDistToTurn,
    required this.navMainText,
  });

  const _DriveOverlaySnapshot.empty()
      : path = const _XyzSeries.empty(),
        laneLines = const <_LaneLineSeries>[],
        roadEdges = const <_RoadEdgeSeries>[],
        active = false,
        activeLaneLine = false,
        carrotExperimentalMode = false,
        brakeLights = false,
        leadDetected = false,
        pathMode = 0,
        pathColor = 3,
        accel0 = 0.0,
        aEgo = 0.0,
        speedMps = null,
        speedKph = null,
        leftLaneLine = 0,
        rightLaneLine = 0,
        calibrationRpy = const <double>[],
        wideFromDeviceEuler = const <double>[],
        pathOffsetZ = 1.22,
        pathWidthRatio = 1.0,
        animationPhase = 0.0,
        modelFrameId = null,
        roadFrameId = null,
        wideRoadFrameId = null,
        sidecarOverlay2d = null,
        usingLateralPath = false,
        modelPathXMax = 0.0,
        lateralPathXMax = 0.0,
        navPathPoints = const <_NavPathPoint>[],
        navTurnInfo = 0,
        navDistToTurn = null,
        navMainText = '';

  _DriveOverlaySnapshot copyWith({
    int? pathMode,
    int? pathColor,
    List<double>? calibrationRpy,
    List<double>? wideFromDeviceEuler,
    double? pathOffsetZ,
    double? animationPhase,
    Map<String, dynamic>? sidecarOverlay2d,
    List<_NavPathPoint>? navPathPoints,
    int? navTurnInfo,
    double? navDistToTurn,
    String? navMainText,
  }) {
    final phase = animationPhase ?? this.animationPhase;
    return _DriveOverlaySnapshot(
      path: path,
      laneLines: laneLines,
      roadEdges: roadEdges,
      active: active,
      activeLaneLine: activeLaneLine,
      carrotExperimentalMode: carrotExperimentalMode,
      brakeLights: brakeLights,
      leadDetected: leadDetected,
      pathMode: pathMode ?? this.pathMode,
      pathColor: pathColor ?? this.pathColor,
      accel0: accel0,
      aEgo: aEgo,
      speedMps: speedMps,
      speedKph: speedKph,
      leftLaneLine: leftLaneLine,
      rightLaneLine: rightLaneLine,
      calibrationRpy: calibrationRpy ?? this.calibrationRpy,
      wideFromDeviceEuler: wideFromDeviceEuler ?? this.wideFromDeviceEuler,
      pathOffsetZ: pathOffsetZ ?? this.pathOffsetZ,
      pathWidthRatio: pathWidthRatio,
      animationPhase: phase,
      modelFrameId: modelFrameId,
      roadFrameId: roadFrameId,
      wideRoadFrameId: wideRoadFrameId,
      sidecarOverlay2d: sidecarOverlay2d ?? this.sidecarOverlay2d,
      usingLateralPath: usingLateralPath,
      modelPathXMax: modelPathXMax,
      lateralPathXMax: lateralPathXMax,
      navPathPoints: navPathPoints ?? this.navPathPoints,
      navTurnInfo: navTurnInfo ?? this.navTurnInfo,
      navDistToTurn: navDistToTurn ?? this.navDistToTurn,
      navMainText: navMainText ?? this.navMainText,
    );
  }

  static double? _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static List<double> _asDoubleList(dynamic v) {
    if (v is! List) return const <double>[];
    final out = <double>[];
    for (final e in v) {
      final d = _asDouble(e);
      if (d != null) out.add(d);
    }
    return out;
  }

  static List<_NavPathPoint> _parseNaviPathPoints(dynamic raw) {
    if (raw is! String) return const <_NavPathPoint>[];
    final text = raw.trim();
    if (text.isEmpty) return const <_NavPathPoint>[];
    final out = <_NavPathPoint>[];
    for (final token in text.split(';')) {
      final part = token.trim();
      if (part.isEmpty) continue;
      final xyz = part.split(',');
      if (xyz.length != 3) continue;
      final x = _asDouble(xyz[0]);
      final y = _asDouble(xyz[1]);
      final d = _asDouble(xyz[2]);
      if (x == null || y == null || d == null) continue;
      if (!x.isFinite || !y.isFinite || !d.isFinite) continue;
      out.add(_NavPathPoint(x: x, y: y, d: d));
      if (out.length >= 200) break;
    }
    if (out.length <= 1) return const <_NavPathPoint>[];
    out.sort((a, b) => a.d.compareTo(b.d));
    return out;
  }

  static int _turnInfoFromNavInstruction({
    required String maneuverType,
    required String maneuverModifier,
    required String fallbackText,
  }) {
    final type = maneuverType.trim().toLowerCase();
    final modifier = maneuverModifier.trim().toLowerCase();
    final fallback = fallbackText.trim().toLowerCase();

    bool containsAny(String source, List<String> needles) {
      for (final n in needles) {
        if (source.contains(n)) return true;
      }
      return false;
    }

    final isArrival =
        containsAny(type, const <String>['arrive', 'destination']) ||
            containsAny(fallback, const <String>['도착']);
    if (isArrival) return 8;

    final isUturn =
        containsAny(type, const <String>['uturn', 'u-turn', 'u turn']) ||
            containsAny(fallback, const <String>['유턴']);
    if (isUturn) return 7;

    final isLeft = containsAny(modifier, const <String>['left']) ||
        containsAny(fallback, const <String>['좌']);
    final isRight = containsAny(modifier, const <String>['right']) ||
        containsAny(fallback, const <String>['우']);

    final isLaneLike = containsAny(type, const <String>[
      'fork',
      'merge',
      'ramp',
      'onramp',
      'offramp',
      'change lane',
    ]);
    if (isLaneLike) {
      if (isLeft) return 3;
      if (isRight) return 4;
    }

    final isTurnLike = containsAny(type, const <String>[
      'turn',
      'roundabout',
      'exit roundabout',
      'continue',
    ]);
    if (isTurnLike) {
      if (isLeft) return 1;
      if (isRight) return 2;
    }

    if (containsAny(fallback, const <String>['좌회전'])) return 1;
    if (containsAny(fallback, const <String>['우회전'])) return 2;
    return 0;
  }

  static double _maxFinite(List<double> values) {
    var out = 0.0;
    for (final v in values) {
      if (v.isFinite && v > out) out = v;
    }
    return out;
  }

  static double _lerp(double a, double b, double t) {
    return a + (b - a) * t;
  }

  static double? _lerpNullable(double? a, double? b, double t) {
    if (a == null && b == null) return null;
    final av = a ?? b ?? 0.0;
    final bv = b ?? a ?? 0.0;
    return _lerp(av, bv, t);
  }

  static _XyzSeries _lerpSeries(_XyzSeries a, _XyzSeries b, double t) {
    final count = math.min(a.length, b.length);
    if (count < 2) return t < 0.5 ? a : b;
    final x = List<double>.generate(
      count,
      (i) => _lerp(a.x[i], b.x[i], t),
      growable: false,
    );
    final y = List<double>.generate(
      count,
      (i) => _lerp(a.y[i], b.y[i], t),
      growable: false,
    );
    final z = List<double>.generate(
      count,
      (i) => _lerp(a.z[i], b.z[i], t),
      growable: false,
    );
    return _XyzSeries(x: x, y: y, z: z);
  }

  static List<_LaneLineSeries> _lerpLaneLines(
    List<_LaneLineSeries> a,
    List<_LaneLineSeries> b,
    double t,
  ) {
    final count = math.min(a.length, b.length);
    if (count == 0) return t < 0.5 ? a : b;
    return List<_LaneLineSeries>.generate(
      count,
      (i) => _LaneLineSeries(
        line: _lerpSeries(a[i].line, b[i].line, t),
        probability: _lerp(a[i].probability, b[i].probability, t),
        std: _lerp(a[i].std, b[i].std, t),
      ),
      growable: false,
    );
  }

  static List<_RoadEdgeSeries> _lerpRoadEdges(
    List<_RoadEdgeSeries> a,
    List<_RoadEdgeSeries> b,
    double t,
  ) {
    final count = math.min(a.length, b.length);
    if (count == 0) return t < 0.5 ? a : b;
    return List<_RoadEdgeSeries>.generate(
      count,
      (i) => _RoadEdgeSeries(
        line: _lerpSeries(a[i].line, b[i].line, t),
        std: _lerp(a[i].std, b[i].std, t),
      ),
      growable: false,
    );
  }

  static _DriveOverlaySnapshot interpolate(
    _DriveOverlaySnapshot from,
    _DriveOverlaySnapshot to,
    double t,
  ) {
    final tt = t.clamp(0.0, 1.0).toDouble();
    if (tt <= 0.0) return from;
    if (tt >= 1.0) return to;
    return _DriveOverlaySnapshot(
      path: _lerpSeries(from.path, to.path, tt),
      laneLines: _lerpLaneLines(from.laneLines, to.laneLines, tt),
      roadEdges: _lerpRoadEdges(from.roadEdges, to.roadEdges, tt),
      active: tt < 0.5 ? from.active : to.active,
      activeLaneLine: tt < 0.5 ? from.activeLaneLine : to.activeLaneLine,
      carrotExperimentalMode:
          tt < 0.5 ? from.carrotExperimentalMode : to.carrotExperimentalMode,
      brakeLights: tt < 0.5 ? from.brakeLights : to.brakeLights,
      leadDetected: tt < 0.5 ? from.leadDetected : to.leadDetected,
      pathMode: tt < 0.5 ? from.pathMode : to.pathMode,
      pathColor: tt < 0.5 ? from.pathColor : to.pathColor,
      accel0: _lerp(from.accel0, to.accel0, tt),
      aEgo: _lerp(from.aEgo, to.aEgo, tt),
      speedMps: _lerpNullable(from.speedMps, to.speedMps, tt),
      speedKph: _lerpNullable(from.speedKph, to.speedKph, tt),
      leftLaneLine: tt < 0.5 ? from.leftLaneLine : to.leftLaneLine,
      rightLaneLine: tt < 0.5 ? from.rightLaneLine : to.rightLaneLine,
      calibrationRpy: tt < 0.5 ? from.calibrationRpy : to.calibrationRpy,
      wideFromDeviceEuler:
          tt < 0.5 ? from.wideFromDeviceEuler : to.wideFromDeviceEuler,
      pathOffsetZ: _lerp(from.pathOffsetZ, to.pathOffsetZ, tt),
      pathWidthRatio: _lerp(from.pathWidthRatio, to.pathWidthRatio, tt),
      animationPhase: _lerp(from.animationPhase, to.animationPhase, tt),
      modelFrameId: tt < 0.5 ? from.modelFrameId : to.modelFrameId,
      roadFrameId: tt < 0.5 ? from.roadFrameId : to.roadFrameId,
      wideRoadFrameId: tt < 0.5 ? from.wideRoadFrameId : to.wideRoadFrameId,
      sidecarOverlay2d: tt < 0.5 ? from.sidecarOverlay2d : to.sidecarOverlay2d,
      usingLateralPath: tt < 0.5 ? from.usingLateralPath : to.usingLateralPath,
      modelPathXMax: _lerp(from.modelPathXMax, to.modelPathXMax, tt),
      lateralPathXMax: _lerp(from.lateralPathXMax, to.lateralPathXMax, tt),
      navPathPoints: tt < 0.5 ? from.navPathPoints : to.navPathPoints,
      navTurnInfo: tt < 0.5 ? from.navTurnInfo : to.navTurnInfo,
      navDistToTurn: tt < 0.5 ? from.navDistToTurn : to.navDistToTurn,
      navMainText: tt < 0.5 ? from.navMainText : to.navMainText,
    );
  }

  factory _DriveOverlaySnapshot.fromSidecar(Map<String, dynamic> payload) {
    final carState = payload['carState'];
    final selfdriveState = payload['selfdriveState'];
    final controlsState = payload['controlsState'];
    final longitudinalPlan = payload['longitudinalPlan'];
    final lateralPlan = payload['lateralPlan'];
    final radarState = payload['radarState'];
    final pathStyle = payload['pathStyle'];
    final liveCalibration = payload['liveCalibration'];
    final cachedCalibration = payload['cachedCalibration'];
    final roadCameraState = payload['roadCameraState'];
    final wideRoadCameraState = payload['wideRoadCameraState'];
    final modelV2 = payload['modelV2'];
    final carrotMan = payload['carrotMan'];
    final navInstructionCarrot = payload['navInstructionCarrot'];
    final overlay2dRaw = payload['overlay2d'];
    Map<String, dynamic>? sidecarOverlay2d;
    if (overlay2dRaw is Map) {
      sidecarOverlay2d = Map<String, dynamic>.from(overlay2dRaw);
    }

    var navPathPoints = const <_NavPathPoint>[];
    var navTurnInfo = 0;
    double? navDistToTurn;
    var navMainText = '';
    if (carrotMan is Map) {
      navPathPoints = _parseNaviPathPoints(carrotMan['naviPaths']);
      navTurnInfo = _asInt(carrotMan['xTurnInfo']) ?? 0;
      navDistToTurn = _asDouble(carrotMan['xDistToTurn']);
      navMainText = (carrotMan['szTBTMainText']?.toString() ?? '').trim();
    }
    if (navInstructionCarrot is Map) {
      final instructionPrimary =
          (navInstructionCarrot['maneuverPrimaryText']?.toString() ?? '')
              .trim();
      final instructionType =
          (navInstructionCarrot['maneuverType']?.toString() ?? '').trim();
      final instructionModifier =
          (navInstructionCarrot['maneuverModifier']?.toString() ?? '').trim();
      final maneuverDistance =
          _asDouble(navInstructionCarrot['maneuverDistance']);
      final remainingDistance =
          _asDouble(navInstructionCarrot['distanceRemaining']);
      final candidateDistance =
          (maneuverDistance != null && maneuverDistance > 0.0)
              ? maneuverDistance
              : ((remainingDistance != null && remainingDistance > 0.0)
                  ? remainingDistance
                  : null);
      if ((navDistToTurn == null || navDistToTurn <= 0.0) &&
          candidateDistance != null) {
        navDistToTurn = candidateDistance;
      }
      if (navMainText.isEmpty && instructionPrimary.isNotEmpty) {
        navMainText = instructionPrimary;
      }
      if (navTurnInfo == 0) {
        navTurnInfo = _turnInfoFromNavInstruction(
          maneuverType: instructionType,
          maneuverModifier: instructionModifier,
          fallbackText: navMainText,
        );
      }
    }

    double? speedMps;
    double? speedKph;
    var aEgo = 0.0;
    var brakeLights = false;
    var useLaneLineSpeed = 0;
    var leftLaneLine = 0;
    var rightLaneLine = 0;
    if (carState is Map) {
      final vEgo = _asDouble(carState['vEgo']);
      if (vEgo != null) {
        speedMps = vEgo;
        speedKph = vEgo * 3.6;
      }
      aEgo = _asDouble(carState['aEgo']) ?? 0.0;
      final brakeRaw = carState['brakeLights'];
      if (brakeRaw is bool) brakeLights = brakeRaw;
      if (brakeRaw is num) brakeLights = brakeRaw != 0;
      useLaneLineSpeed = _asInt(carState['useLaneLineSpeed']) ?? 0;
      leftLaneLine = _asInt(carState['leftLaneLine']) ?? 0;
      rightLaneLine = _asInt(carState['rightLaneLine']) ?? 0;
    }

    bool active = false;
    if (selfdriveState is Map) {
      final activeRaw = selfdriveState['active'];
      if (activeRaw is bool) active = activeRaw;
      if (activeRaw is num) active = activeRaw != 0;
    }

    var activeLaneLine = false;
    if (controlsState is Map) {
      final laneRaw = controlsState['activeLaneLine'];
      if (laneRaw is bool) activeLaneLine = laneRaw;
      if (laneRaw is num) activeLaneLine = laneRaw != 0;
    }

    var carrotExperimentalMode = false;
    var accel0 = 0.0;
    if (longitudinalPlan is Map) {
      final xState = _asInt(longitudinalPlan['xState']) ?? -1;
      carrotExperimentalMode = xState == 4;
      accel0 = _asDouble(longitudinalPlan['accel0']) ?? 0.0;
    }

    var leadDetected = false;
    if (radarState is Map) {
      final leadOne = radarState['leadOne'];
      if (leadOne is Map) {
        final status = leadOne['status'];
        if (status is bool) leadDetected = status;
        if (status is num) leadDetected = status != 0;
      }
    }

    var modelPath = const _XyzSeries.empty();
    var lateralPath = const _XyzSeries.empty();
    var lines = const <_LaneLineSeries>[];
    var edges = const <_RoadEdgeSeries>[];
    int? modelFrameId;

    if (modelV2 is Map) {
      modelFrameId = _asInt(modelV2['frameId']);
      final x = _asDoubleList(modelV2['pathX']);
      final y = _asDoubleList(modelV2['pathY']);
      final z = _asDoubleList(modelV2['pathZ']);
      if (x.isNotEmpty && y.isNotEmpty) {
        var count = math.min(x.length, y.length);
        if (z.isNotEmpty) {
          count = math.min(count, z.length);
        }
        if (count >= 2) {
          final zOut = z.isEmpty
              ? List<double>.filled(count, 0.0, growable: false)
              : z.take(count).toList(growable: false);
          modelPath = _XyzSeries(
            x: x.take(count).toList(growable: false),
            y: y.take(count).toList(growable: false),
            z: zOut,
          );
        }
      }

      final probs = _asDoubleList(modelV2['laneLineProbs']);
      final stds = _asDoubleList(modelV2['laneLineStds']);
      final laneRaw = modelV2['laneLines'];
      if (laneRaw is List) {
        final parsed = <_LaneLineSeries>[];
        for (var i = 0; i < laneRaw.length; i++) {
          final e = laneRaw[i];
          if (e is! Map) continue;
          final map = Map<String, dynamic>.from(e);
          final lx = _asDoubleList(map['x']);
          final ly = _asDoubleList(map['y']);
          final lz = _asDoubleList(map['z']);
          if (lx.isEmpty || ly.isEmpty) continue;
          var count = math.min(lx.length, ly.length);
          if (lz.isNotEmpty) {
            count = math.min(count, lz.length);
          }
          if (count < 2) continue;
          final prob = i < probs.length ? probs[i].clamp(0, 1) : 0.5;
          final std = i < stds.length ? stds[i].clamp(0, 2) : 1.0;
          final zOut = lz.isEmpty
              ? List<double>.filled(count, 0.0, growable: false)
              : lz.take(count).toList(growable: false);
          parsed.add(
            _LaneLineSeries(
              line: _XyzSeries(
                x: lx.take(count).toList(growable: false),
                y: ly.take(count).toList(growable: false),
                z: zOut,
              ),
              probability: prob.toDouble(),
              std: std.toDouble(),
            ),
          );
        }
        lines = parsed;
      }

      final edgeRaw = modelV2['roadEdges'];
      final edgeStds = _asDoubleList(modelV2['roadEdgeStds']);
      if (edgeRaw is List) {
        final parsed = <_RoadEdgeSeries>[];
        for (var i = 0; i < edgeRaw.length; i++) {
          final e = edgeRaw[i];
          if (e is! Map) continue;
          final map = Map<String, dynamic>.from(e);
          final ex = _asDoubleList(map['x']);
          final ey = _asDoubleList(map['y']);
          final ez = _asDoubleList(map['z']);
          if (ex.isEmpty || ey.isEmpty) continue;
          var count = math.min(ex.length, ey.length);
          if (ez.isNotEmpty) {
            count = math.min(count, ez.length);
          }
          if (count < 2) continue;
          final std = i < edgeStds.length ? edgeStds[i].clamp(0, 2) : 1.0;
          final zOut = ez.isEmpty
              ? List<double>.filled(count, 0.0, growable: false)
              : ez.take(count).toList(growable: false);
          parsed.add(
            _RoadEdgeSeries(
              line: _XyzSeries(
                x: ex.take(count).toList(growable: false),
                y: ey.take(count).toList(growable: false),
                z: zOut,
              ),
              std: std.toDouble(),
            ),
          );
        }
        edges = parsed;
      }
    }

    if (lateralPlan is Map) {
      final posRaw = lateralPlan['position'];
      if (posRaw is Map) {
        final posMap = Map<String, dynamic>.from(posRaw);
        final x = _asDoubleList(posMap['x']);
        final y = _asDoubleList(posMap['y']);
        final z = _asDoubleList(posMap['z']);
        if (x.isNotEmpty && y.isNotEmpty) {
          var count = math.min(x.length, y.length);
          if (z.isNotEmpty) {
            count = math.min(count, z.length);
          }
          if (count >= 2) {
            final zOut = z.isEmpty
                ? List<double>.filled(count, 0.0, growable: false)
                : z.take(count).toList(growable: false);
            lateralPath = _XyzSeries(
              x: x.take(count).toList(growable: false),
              y: y.take(count).toList(growable: false),
              z: zOut,
            );
          }
        }
      }
    }

    var calibrationRpy = const <double>[];
    var wideFromDeviceEuler = const <double>[];
    var pathOffsetZ = 1.22;
    bool applyCalibration(dynamic raw) {
      if (raw is! Map) return false;
      final map = Map<String, dynamic>.from(raw);
      final calStatus = _asInt(map['calStatus']);
      // openpilot UI parity: apply calibration only when CALIBRATED(1).
      if (calStatus != null && calStatus != 1) {
        return false;
      }
      final rpy = _asDoubleList(map['rpyCalib']);
      if (rpy.length >= 3) {
        calibrationRpy = rpy.take(3).toList(growable: false);
      }
      final wideEuler = _asDoubleList(map['wideFromDeviceEuler']);
      if (wideEuler.length >= 3) {
        wideFromDeviceEuler = wideEuler.take(3).toList(growable: false);
      }
      final h = _asDouble(map['height']);
      if (h != null && h.isFinite && h > 0.3 && h < 4.0) {
        pathOffsetZ = h;
      }
      return calibrationRpy.length >= 3 && wideFromDeviceEuler.length >= 3;
    }

    var liveApplied = false;
    if (liveCalibration is Map) {
      liveApplied = applyCalibration(liveCalibration);
    }
    if (!liveApplied &&
        (calibrationRpy.length < 3 || wideFromDeviceEuler.length < 3)) {
      applyCalibration(cachedCalibration);
    }

    final modelPathXMax = _maxFinite(modelPath.x);
    final lateralPathXMax = _maxFinite(lateralPath.x);
    final canUseLateralPathPrimary = activeLaneLine &&
        lateralPath.length >= 2 &&
        lateralPathXMax >= 8.0 &&
        (modelPathXMax <= 0.0 || lateralPathXMax >= (modelPathXMax * 0.35));
    // Keep path visible in low-speed/static scenes when model path collapses.
    final canUseLateralPathFallback = !activeLaneLine &&
        lateralPath.length >= 2 &&
        lateralPathXMax >= 8.0 &&
        modelPathXMax > 0.0 &&
        modelPathXMax < 8.0;
    final canUseLateralPath =
        canUseLateralPathPrimary || canUseLateralPathFallback;
    final path = canUseLateralPath ? lateralPath : modelPath;

    var showPathModeNormal = 0;
    var showPathColorNormal = 3;
    var showPathModeLane = 0;
    var showPathColorLane = 3;
    var showPathColorCruiseOff = 3;
    var showPathWidth = 100;
    if (pathStyle is Map) {
      showPathModeNormal =
          _asInt(pathStyle['showPathMode']) ?? showPathModeNormal;
      showPathColorNormal =
          _asInt(pathStyle['showPathColor']) ?? showPathColorNormal;
      showPathModeLane =
          _asInt(pathStyle['showPathModeLane']) ?? showPathModeLane;
      showPathColorLane =
          _asInt(pathStyle['showPathColorLane']) ?? showPathColorLane;
      showPathColorCruiseOff =
          _asInt(pathStyle['showPathColorCruiseOff']) ?? showPathColorCruiseOff;
      showPathWidth = _asInt(pathStyle['showPathWidth']) ?? showPathWidth;
    }
    final pathWidthRatio = (showPathWidth.toDouble() / 100.0).clamp(0.1, 3.0);
    var pathMode = activeLaneLine ? showPathModeLane : showPathModeNormal;
    var pathColor = activeLaneLine ? showPathColorLane : showPathColorNormal;
    if (!active) {
      pathColor = showPathColorCruiseOff;
    }
    if (pathColor >= 20) {
      if (active) {
        pathColor = 13;
        if (leadDetected) {
          if (accel0.abs() < 0.5) {
            pathColor = 12;
          } else if (accel0 >= 0.5) {
            pathColor = 11;
          } else {
            pathColor = 10;
          }
        }
      } else {
        pathColor = 19;
      }
    }
    if (useLaneLineSpeed > 0 && !activeLaneLine) {
      pathMode = showPathModeLane;
    }

    int? roadFrameId;
    if (roadCameraState is Map) {
      roadFrameId = _asInt(roadCameraState['frameId']);
    }
    int? wideRoadFrameId;
    if (wideRoadCameraState is Map) {
      wideRoadFrameId = _asInt(wideRoadCameraState['frameId']);
    }

    return _DriveOverlaySnapshot(
      path: path,
      laneLines: lines,
      roadEdges: edges,
      active: active,
      activeLaneLine: activeLaneLine,
      carrotExperimentalMode: carrotExperimentalMode,
      brakeLights: brakeLights,
      leadDetected: leadDetected,
      pathMode: pathMode,
      pathColor: pathColor,
      accel0: accel0,
      aEgo: aEgo,
      speedMps: speedMps,
      speedKph: speedKph,
      leftLaneLine: leftLaneLine,
      rightLaneLine: rightLaneLine,
      calibrationRpy: calibrationRpy,
      wideFromDeviceEuler: wideFromDeviceEuler,
      pathOffsetZ: pathOffsetZ,
      pathWidthRatio: pathWidthRatio,
      animationPhase: 0.0,
      modelFrameId: modelFrameId,
      roadFrameId: roadFrameId,
      wideRoadFrameId: wideRoadFrameId,
      sidecarOverlay2d: sidecarOverlay2d,
      usingLateralPath: canUseLateralPath,
      modelPathXMax: modelPathXMax,
      lateralPathXMax: lateralPathXMax,
      navPathPoints: navPathPoints,
      navTurnInfo: navTurnInfo,
      navDistToTurn: navDistToTurn,
      navMainText: navMainText,
    );
  }
}

class _XyzSeries {
  final List<double> x;
  final List<double> y;
  final List<double> z;

  const _XyzSeries({
    required this.x,
    required this.y,
    required this.z,
  });

  const _XyzSeries.empty()
      : x = const <double>[],
        y = const <double>[],
        z = const <double>[];

  int get length => math.min(x.length, math.min(y.length, z.length));
}

class _LaneLineSeries {
  final _XyzSeries line;
  final double probability;
  final double std;

  const _LaneLineSeries({
    required this.line,
    required this.probability,
    required this.std,
  });
}

class _RoadEdgeSeries {
  final _XyzSeries line;
  final double std;

  const _RoadEdgeSeries({
    required this.line,
    required this.std,
  });
}

class _NavPathPoint {
  final double x;
  final double y;
  final double d;

  const _NavPathPoint({
    required this.x,
    required this.y,
    required this.d,
  });
}

class _DriveOverlayPainter extends CustomPainter {
  final _DriveOverlaySnapshot snapshot;
  final bool isConnected;
  final Size sourceSize;
  final _DriveCameraKind cameraKind;
  final bool coverViewport;
  final bool showDebugGuides;
  final bool showPathFill;
  final bool showLaneLines;
  final bool showRoadEdge;
  final bool showLead1;
  final bool showLead2;
  final bool showRadarBadge;
  final bool showRadarVector;
  final bool showStopDistanceTf;
  final bool showStateText;

  static const double _baseSourceWidth = 1928.0;
  static const double _baseSourceHeight = 1208.0;
  static const double _clipMargin = 500.0;
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

  const _DriveOverlayPainter({
    required this.snapshot,
    required this.isConnected,
    required this.sourceSize,
    required this.cameraKind,
    required this.coverViewport,
    this.showDebugGuides = false,
    this.showPathFill = true,
    this.showLaneLines = true,
    this.showRoadEdge = true,
    this.showLead1 = true,
    this.showLead2 = true,
    this.showRadarBadge = true,
    this.showRadarVector = true,
    this.showStopDistanceTf = true,
    this.showStateText = true,
  });

  _M3 _rotationFromEuler(List<double> rpy) {
    if (rpy.length < 3) return const _M3.identity();
    final roll = rpy[0];
    final pitch = rpy[1];
    final yaw = rpy[2];

    final cr = math.cos(roll);
    final sr = math.sin(roll);
    final cp = math.cos(pitch);
    final sp = math.sin(pitch);
    final cy = math.cos(yaw);
    final sy = math.sin(yaw);

    final rx = _M3(
      1.0,
      0.0,
      0.0,
      0.0,
      cr,
      -sr,
      0.0,
      sr,
      cr,
    );
    final ry = _M3(
      cp,
      0.0,
      sp,
      0.0,
      1.0,
      0.0,
      -sp,
      0.0,
      cp,
    );
    final rz = _M3(
      cy,
      -sy,
      0.0,
      sy,
      cy,
      0.0,
      0.0,
      0.0,
      1.0,
    );
    return rz.multiply(ry).multiply(rx);
  }

  _M3 _intrinsicForSource(Size source, bool wideCam) {
    final sx = source.width / _baseSourceWidth;
    final sy = source.height / _baseSourceHeight;
    final focal = wideCam ? 567.0 : 2648.0;
    return _M3(
      focal * sx,
      0.0,
      964.0 * sx,
      0.0,
      focal * sy,
      604.0 * sy,
      0.0,
      0.0,
      1.0,
    );
  }

  _M3 _calibTransformForSource(Size source) {
    final wideCam = cameraKind == _DriveCameraKind.wideRoad;
    final intrinsic = _intrinsicForSource(source, wideCam);
    final deviceFromCalib = _rotationFromEuler(snapshot.calibrationRpy);
    final wideFromDevice = wideCam
        ? _rotationFromEuler(snapshot.wideFromDeviceEuler)
        : const _M3.identity();
    final viewFromCalib = wideCam
        ? _viewFromDevice.multiply(wideFromDevice.multiply(deviceFromCalib))
        : _viewFromDevice.multiply(deviceFromCalib);
    return intrinsic.multiply(viewFromCalib);
  }

  _SourceCanvasPlacement _sourceToCanvasPlacementProjected({
    required Size source,
    required Size canvas,
  }) {
    final wideCam = cameraKind == _DriveCameraKind.wideRoad;
    final intrinsic = _intrinsicForSource(source, wideCam);
    final calibTransform = _calibTransformForSource(source);
    return _sourceToCanvasPlacement(
      source: source,
      canvas: canvas,
      intrinsic: intrinsic,
      calibTransform: calibTransform,
    );
  }

  Color _pathColorFromIndex(int idx) {
    final n = idx % 10;
    switch (n) {
      case 0:
        return const Color(0xFFFF0000);
      case 1:
        return const Color(0xFFFF9900);
      case 2:
        return const Color(0xFFDACA25);
      case 3:
        return const Color(0xFF00CB00);
      case 4:
        return const Color(0xFF0000FF);
      case 5:
        return const Color(0xFF000080);
      case 6:
        return const Color(0xFF8B00FF);
      case 7:
        return const Color(0xFFDA6F25);
      case 8:
        return const Color(0xFFFFFFFF);
      case 9:
      default:
        return const Color(0xFF000000);
    }
  }

  double _pathHalfWidthByMode(int mode, double ratio) {
    return ratio;
  }

  double _clampDouble(double v, double min, double max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  Color _roadEdgeColor(double std) {
    final t = _clampDouble(std / 2.0, 0.0, 1.0);
    final r = _clampDouble((1.0 - t) * 255.0, 0.0, 255.0).round();
    final b = _clampDouble(t * 255.0, 0.0, 255.0).round();
    return Color.fromARGB(255, r, 0, b);
  }

  Size get _effectiveSourceSize {
    if (sourceSize.width > 1 && sourceSize.height > 1) {
      final dw = (sourceSize.width - _baseSourceWidth).abs();
      final dh = (sourceSize.height - _baseSourceHeight).abs();
      // Some decoders report 1936x1216 while the projection intrinsics are
      // calibrated for 1928x1208. Snap near-by metadata to the canonical size.
      if (dw <= 16.0 && dh <= 16.0) {
        return const Size(_baseSourceWidth, _baseSourceHeight);
      }
      return sourceSize;
    }
    return const Size(_baseSourceWidth, _baseSourceHeight);
  }

  // -------------------------------------------------------------------------
  // Projection/Mapping invariants (MUST NOT change in adaptive UI refactors)
  //
  // This block is the source-of-truth for camera->overlay geometric alignment.
  // Keep these equations and transform order stable unless doing explicit
  // projection-engine work with field validation:
  // - _sourceToCanvasPlacement
  // - _sourceToCanvasPlacementFromDisplayTransform
  // - _buildTransform
  // - _mapToScreen
  //
  // Adaptive/responsive changes must be limited to surrounding UI shells
  // (dock/panel/popup/safe-area spacing), not these math paths.
  // -------------------------------------------------------------------------
  _SourceCanvasPlacement _sourceToCanvasPlacement({
    required Size source,
    required Size canvas,
    required _M3 intrinsic,
    required _M3 calibTransform,
  }) {
    final sx = canvas.width / source.width;
    final sy = canvas.height / source.height;
    final scale = coverViewport ? math.max(sx, sy) : math.min(sx, sy);
    final drawW = source.width * scale;
    final drawH = source.height * scale;
    var dx = (canvas.width - drawW) * 0.5;
    var dy = (canvas.height - drawH) * 0.5;
    var xOffset = 0.0;
    var yOffset = 0.0;

    // openpilot annotated_camera::calcFrameMatrix style:
    // use the projected point at "infinity" to compute x/y screen offset.
    final inf = calibTransform.transform(const _V3(1000.0, 0.0, 0.0));
    if (inf.z.isFinite && inf.z.abs() > 1e-6) {
      final centerX = intrinsic.m02;
      final centerY = intrinsic.m12;
      final maxXOffset =
          math.max(0.0, centerX * scale - canvas.width * 0.5 - 5.0);
      final maxYOffset =
          math.max(0.0, centerY * scale - canvas.height * 0.5 - 5.0);
      xOffset = _clampDouble(
        ((inf.x / inf.z) - centerX) * scale,
        -maxXOffset,
        maxXOffset,
      );
      yOffset = _clampDouble(
        ((inf.y / inf.z) - centerY) * scale,
        -maxYOffset,
        maxYOffset,
      );
      dx = (canvas.width * 0.5 - xOffset) - (centerX * scale);
      dy = (canvas.height * 0.5 - yOffset) - (centerY * scale);
    }

    return _SourceCanvasPlacement(
      transform: _M3(
        scale,
        0.0,
        dx,
        0.0,
        scale,
        dy,
        0.0,
        0.0,
        1.0,
      ),
      scale: scale,
      xOffset: xOffset,
      yOffset: yOffset,
    );
  }

  _SourceCanvasPlacement _sourceToCanvasPlacementFromDisplayTransform({
    required Size source,
    required Size canvas,
    required Map<String, dynamic>? displayTransform,
  }) {
    final sx = canvas.width / source.width;
    final sy = canvas.height / source.height;
    final fitScale = coverViewport ? math.max(sx, sy) : math.min(sx, sy);
    final baseDrawW = source.width * fitScale;
    final baseDrawH = source.height * fitScale;
    final baseDx = (canvas.width - baseDrawW) * 0.5;
    final baseDy = (canvas.height - baseDrawH) * 0.5;

    final zoomRaw = displayTransform == null
        ? null
        : _DriveOverlaySnapshot._asDouble(displayTransform['zoom']);
    final txRaw = displayTransform == null
        ? null
        : _DriveOverlaySnapshot._asDouble(displayTransform['tx']);
    final tyRaw = displayTransform == null
        ? null
        : _DriveOverlaySnapshot._asDouble(displayTransform['ty']);
    final xOffsetRaw = displayTransform == null
        ? null
        : _DriveOverlaySnapshot._asDouble(displayTransform['xOffset']);
    final yOffsetRaw = displayTransform == null
        ? null
        : _DriveOverlaySnapshot._asDouble(displayTransform['yOffset']);

    final zoom =
        (zoomRaw != null && zoomRaw.isFinite && zoomRaw > 0.1) ? zoomRaw : 1.0;
    final tx = (txRaw != null && txRaw.isFinite)
        ? txRaw
        : ((source.width - (source.width * zoom)) * 0.5);
    final ty = (tyRaw != null && tyRaw.isFinite)
        ? tyRaw
        : ((source.height - (source.height * zoom)) * 0.5);

    return _SourceCanvasPlacement(
      transform: _M3(
        fitScale * zoom,
        0.0,
        (fitScale * tx) + baseDx,
        0.0,
        fitScale * zoom,
        (fitScale * ty) + baseDy,
        0.0,
        0.0,
        1.0,
      ),
      scale: fitScale * zoom,
      xOffset: (xOffsetRaw != null && xOffsetRaw.isFinite) ? xOffsetRaw : 0.0,
      yOffset: (yOffsetRaw != null && yOffsetRaw.isFinite) ? yOffsetRaw : 0.0,
    );
  }

  _ProjectionTransform _buildTransform(Size size) {
    final src = _effectiveSourceSize;
    final calibTransform = _calibTransformForSource(src);
    final placement = _sourceToCanvasPlacementProjected(
      source: src,
      canvas: size,
    );
    final sourceToCanvas = placement.transform;
    // Keep projection math aligned with openpilot-style transform pipeline:
    // canvas <- source fit <- intrinsics/extrinsics calibrated projection.
    final carSpaceTransform = sourceToCanvas.multiply(calibTransform);
    final clip = Rect.fromLTWH(
      -_clipMargin,
      -_clipMargin,
      size.width + (_clipMargin * 2.0),
      size.height + (_clipMargin * 2.0),
    );
    return _ProjectionTransform(
      carSpaceTransform: carSpaceTransform,
      clip: clip,
      sourceScale: placement.scale,
      xOffset: placement.xOffset,
      yOffset: placement.yOffset,
    );
  }

  bool _mapToScreen(
    _ProjectionTransform transform,
    double inX,
    double inY,
    double inZ,
    void Function(Offset) onPoint,
  ) {
    final p = transform.carSpaceTransform.transform(_V3(inX, inY, inZ));
    if (!p.z.isFinite || p.z <= 1e-3) return false;
    final out = Offset(p.x / p.z, p.y / p.z);
    if (!transform.clip.contains(out)) return false;
    onPoint(out);
    return true;
  }

  int _getPathLengthIdx(List<double> lineX, double pathHeight) {
    var maxIdx = 0;
    for (var i = 1; i < lineX.length && lineX[i] <= pathHeight; i++) {
      maxIdx = i;
    }
    return maxIdx;
  }

  double _interp1D(double x, List<double> xp, List<double> fp) {
    if (xp.isEmpty || fp.isEmpty) return 0.0;
    final n = math.min(xp.length, fp.length);
    if (n <= 1) return fp.first;
    if (x <= xp.first) return fp.first;
    if (x >= xp[n - 1]) return fp[n - 1];
    for (var i = 1; i < n; i++) {
      final x0 = xp[i - 1];
      final x1 = xp[i];
      if (x <= x1) {
        final span = x1 - x0;
        if (span.abs() < 1e-9) return fp[i];
        final t = (x - x0) / span;
        return fp[i - 1] + (fp[i] - fp[i - 1]) * t;
      }
    }
    return fp[n - 1];
  }

  List<double> _monotonicX(List<double> src) {
    if (src.isEmpty) return const <double>[];
    final out = List<double>.filled(src.length, 0.0, growable: false);
    var prev = src.first;
    out[0] = prev;
    for (var i = 1; i < src.length; i++) {
      final v = src[i];
      if (v < prev) {
        out[i] = prev;
      } else {
        out[i] = v;
        prev = v;
      }
    }
    return out;
  }

  List<Offset>? _mapLineToPolygonVertices(
    _ProjectionTransform transform,
    _XyzSeries line,
    double yOff,
    double zOff,
    int maxIdx, {
    bool allowInvert = true,
    double lineCenterShift = 0.0,
  }) {
    if (line.length < 2) return null;
    final left = <Offset>[];
    final right = <Offset>[];
    final end = math.min(maxIdx, line.length - 1);
    for (var i = 0; i <= end; i++) {
      final lx = line.x[i];
      if (!lx.isFinite || lx < 0.0) continue;
      final ly = line.y[i] + lineCenterShift;
      final lz = line.z[i];
      Offset? lp;
      Offset? rp;
      final okL = _mapToScreen(
        transform,
        lx,
        ly - yOff,
        lz + zOff,
        (p) => lp = p,
      );
      final okR = _mapToScreen(
        transform,
        lx,
        ly + yOff,
        lz + zOff,
        (p) => rp = p,
      );
      if (!okL || !okR || lp == null || rp == null) continue;
      if (!allowInvert && left.isNotEmpty && lp!.dy > left.last.dy) {
        continue;
      }
      left.add(lp!);
      right.insert(0, rp!);
    }
    if (left.length < 2 || right.length < 2) return null;
    return <Offset>[...left, ...right];
  }

  Path? _mapLineToPolygon(
    _ProjectionTransform transform,
    _XyzSeries line,
    double yOff,
    double zOff,
    int maxIdx, {
    bool allowInvert = true,
    double lineCenterShift = 0.0,
  }) {
    final vertices = _mapLineToPolygonVertices(
      transform,
      line,
      yOff,
      zOff,
      maxIdx,
      allowInvert: allowInvert,
      lineCenterShift: lineCenterShift,
    );
    if (vertices == null || vertices.length < 3) return null;
    return _pathFromVertices(vertices);
  }

  List<Offset>? _mapLineToTrackVerticesDist(
    _ProjectionTransform transform,
    _XyzSeries line,
    double widthApply,
    double zOffStart,
    double zOffEnd,
    double maxDistance, {
    double startDistance = 2.0,
    bool allowInvert = true,
  }) {
    if (line.length < 2) return null;
    final n = line.length;
    final lineXs = _monotonicX(line.x.take(n).toList(growable: false));
    if (lineXs.isEmpty) return null;
    final lineYs = line.y.take(n).toList(growable: false);
    final lineZs = line.z.take(n).toList(growable: false);
    final idxs = List<double>.generate(n, (i) => i.toDouble(), growable: false);

    final left = <Offset>[];
    final right = <Offset>[];
    var dist = startDistance;
    var done = false;
    while (!done) {
      if (dist >= maxDistance) {
        dist = maxDistance;
        done = true;
      }
      final zOff = _interp1D(dist, const <double>[
        0.0,
        100.0
      ], <double>[
        zOffStart,
        zOffEnd,
      ]);
      final yScale = _interp1D(
        zOff,
        const <double>[-3.0, 0.0, 3.0],
        const <double>[1.5, 0.5, 1.5],
      );
      final yOff = yScale * widthApply;
      final idx = _interp1D(dist, lineXs, idxs);
      if (idx >= (n - 1)) break;
      final lineY = _interp1D(idx, idxs, lineYs);
      final lineZ = _interp1D(idx, idxs, lineZs);

      Offset? lp;
      Offset? rp;
      final okL = _mapToScreen(
        transform,
        dist,
        lineY - yOff,
        lineZ + zOff,
        (p) => lp = p,
      );
      final okR = _mapToScreen(
        transform,
        dist,
        lineY + yOff,
        lineZ + zOff,
        (p) => rp = p,
      );
      if (okL && okR && lp != null && rp != null) {
        if (!allowInvert && left.isNotEmpty && lp!.dy > left.last.dy) {
          dist += dist * 0.15;
          continue;
        }
        left.add(lp!);
        right.insert(0, rp!);
      }
      dist += dist * 0.15;
    }
    if (left.length < 2 || right.length < 2) return null;
    return <Offset>[...left, ...right];
  }

  Path _pathFromVertices(List<Offset> vertices) {
    final path = Path()..moveTo(vertices.first.dx, vertices.first.dy);
    for (var i = 1; i < vertices.length; i++) {
      path.lineTo(vertices[i].dx, vertices[i].dy);
    }
    path.close();
    return path;
  }

  void _drawTrackPolygon(
    Canvas canvas,
    List<Offset> vertices,
    Color fillColor, {
    required bool strokeEnabled,
    required Color strokeColor,
  }) {
    if (vertices.length < 3) return;
    final path = _pathFromVertices(vertices);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = fillColor.withValues(alpha: 0.42),
    );
    if (strokeEnabled) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = strokeColor,
      );
    }
  }

  void _drawSpecialModes(
    Canvas canvas,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    final glen = (trackLen ~/ 2) - 1;
    if (glen < 2) return;
    var g = 0.05;
    var gc = 0.4;
    if (mode == 13) {
      g = 0.2;
      gc = 0.10;
    } else if (mode == 14) {
      g = 0.45;
      gc = 0.05;
    } else if (mode == 15) {
      gc = g;
    }

    final strip0 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    final strip1 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    final strip2 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    for (var i = 0; i < glen; i++) {
      final e = trackLen - i - 1;
      final ge = (glen * 2) - 1 - i;
      final p1 = trackVertices[i];
      final p2 = trackVertices[e];
      strip0[i] = p1;
      strip0[ge] = Offset(
        p1.dx + (p2.dx - p1.dx) * g,
        p1.dy + (p2.dy - p1.dy) * g,
      );
      strip1[i] = Offset(
        p1.dx + (p2.dx - p1.dx) * (0.5 - gc),
        p1.dy + (p2.dy - p1.dy) * (0.5 - gc),
      );
      strip1[ge] = Offset(
        p1.dx + (p2.dx - p1.dx) * (0.5 + gc),
        p1.dy + (p2.dy - p1.dy) * (0.5 + gc),
      );
      strip2[i] = Offset(
        p1.dx + (p2.dx - p1.dx) * (1.0 - g),
        p1.dy + (p2.dy - p1.dy) * (1.0 - g),
      );
      strip2[ge] = p2;
    }

    final baseColor = _pathColorFromIndex(colorIdx);
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    if (mode == 13 || mode == 14) {
      _drawTrackPolygon(
        canvas,
        strip0,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
    if (mode == 13 || mode == 15) {
      _drawTrackPolygon(
        canvas,
        strip1,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
    if (mode == 13 || mode == 14) {
      _drawTrackPolygon(
        canvas,
        strip2,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
  }

  void _drawComplexPath(
    Canvas canvas,
    List<Offset> trackVertices,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 5) return;
    final baseColor = _pathColorFromIndex(colorIdx);
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    for (var i = 0; i < half - 1; i += 3) {
      final e = trackLen - i - 1;
      if (i + 2 >= half || e - 2 < 0) break;
      final p0 = trackVertices[i];
      final p1 = trackVertices[i + 1];
      final p2l = trackVertices[i + 2];
      final p2r = trackVertices[e - 2];
      final p3 = trackVertices[e - 1];
      final p4 = trackVertices[e];
      final p2 = Offset((p2l.dx + p2r.dx) * 0.5, (p2l.dy + p2r.dy) * 0.5);
      final p5 = Offset((p1.dx + p3.dx) * 0.5, (p1.dy + p3.dy) * 0.5);
      _drawTrackPolygon(
        canvas,
        <Offset>[p0, p1, p2, p3, p4, p5],
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
  }

  void _drawMode1To6(
    Canvas canvas,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
    int pathDrawSeq,
    int pathDrawSeq2,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 5) return;
    var colorN = 0;
    for (var i = 0; i < half - 4; i += 2) {
      final draw = (half < 8 ||
          mode == 5 ||
          mode == 6 ||
          pathDrawSeq == i ~/ 2 ||
          pathDrawSeq == (i ~/ 2) - 2 ||
          pathDrawSeq2 == i ~/ 2 ||
          pathDrawSeq2 == (i ~/ 2) - 2);
      if (!draw) {
        if (i > 1) colorN = (colorN + 1) % 7;
        continue;
      }
      final idx = (mode == 2 || mode == 6) ? colorN : (colorIdx % 10);
      final fill = _pathColorFromIndex(idx);
      final strokeEnabled = colorIdx >= 10 || brakeLights;
      final strokeColor =
          brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
      _drawTrackPolygon(
        canvas,
        <Offset>[
          trackVertices[i],
          trackVertices[i + 2],
          trackVertices[trackLen - i - 3],
          trackVertices[trackLen - i - 1],
        ],
        fill,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      if (i > 1) colorN = (colorN + 1) % 7;
    }
  }

  void _drawMode3To8(
    Canvas canvas,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
    int pathDrawSeq,
    int pathDrawSeq2,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 6) return;
    var colorN = 0;
    for (var i = 0; i < half - 4; i += 2) {
      if (i + 4 >= half || trackLen - i - 5 < 0) break;
      final draw = (half < 8 ||
          mode == 7 ||
          mode == 8 ||
          pathDrawSeq == i ~/ 2 ||
          pathDrawSeq == (i ~/ 2) - 2 ||
          pathDrawSeq2 == i ~/ 2 ||
          pathDrawSeq2 == (i ~/ 2) - 2);
      if (!draw) {
        if (i > 1) colorN = (colorN + 1) % 7;
        continue;
      }
      final idx = (mode == 4 || mode == 8) ? colorN : (colorIdx % 10);
      final fill = _pathColorFromIndex(idx);
      final strokeEnabled = colorIdx >= 10 || brakeLights;
      final strokeColor =
          brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);

      final p1 = trackVertices[i + 2];
      final p3 = trackVertices[trackLen - i - 3];
      _drawTrackPolygon(
        canvas,
        <Offset>[
          trackVertices[i],
          p1,
          Offset(
            (trackVertices[i + 4].dx + trackVertices[trackLen - i - 5].dx) *
                0.5,
            (trackVertices[i + 4].dy + trackVertices[trackLen - i - 5].dy) *
                0.5,
          ),
          p3,
          trackVertices[trackLen - i - 1],
          Offset((p1.dx + p3.dx) * 0.5, (p1.dy + p3.dy) * 0.5),
        ],
        fill,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      if (i > 1) colorN = (colorN + 1) % 7;
    }
  }

  void _drawAnimatedPath(
    Canvas canvas,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    if (trackLen < 8) return;
    final maxSeq = math.min((trackLen ~/ 4) + 3, 16);
    if (maxSeq <= 0) return;
    final phase = snapshot.animationPhase;
    var normalized = phase % maxSeq;
    if (normalized < 0) normalized += maxSeq;
    final seqInt = normalized.floor();
    final pathDrawSeq2 =
        (maxSeq > 15) ? ((seqInt - (maxSeq ~/ 2) + maxSeq) % maxSeq) : -5;
    switch (mode) {
      case 1:
      case 2:
      case 5:
      case 6:
        _drawMode1To6(
          canvas,
          trackVertices,
          mode,
          colorIdx,
          brakeLights,
          seqInt,
          pathDrawSeq2,
        );
        break;
      case 3:
      case 4:
      case 7:
      case 8:
        _drawMode3To8(
          canvas,
          trackVertices,
          mode,
          colorIdx,
          brakeLights,
          seqInt,
          pathDrawSeq2,
        );
        break;
      default:
        _drawComplexPath(canvas, trackVertices, colorIdx, brakeLights);
        break;
    }
  }

  void _drawPathByMode(
    Canvas canvas,
    List<Offset> trackVertices,
  ) {
    final mode = snapshot.pathMode;
    final colorIdx = snapshot.pathColor;
    final brakeLights = snapshot.brakeLights;
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    final fillColor = _pathColorFromIndex(colorIdx);
    if (mode == 0) {
      _drawTrackPolygon(
        canvas,
        trackVertices,
        fillColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      return;
    }
    if (mode >= 13 && mode <= 15) {
      _drawSpecialModes(canvas, trackVertices, mode, colorIdx, brakeLights);
      return;
    }
    if (mode >= 9) {
      _drawComplexPath(canvas, trackVertices, colorIdx, brakeLights);
      return;
    }
    _drawAnimatedPath(canvas, trackVertices, mode, colorIdx, brakeLights);
  }

  static Map<String, dynamic>? buildNativeOverlayPayload({
    required _DriveOverlaySnapshot snapshot,
    required Size sourceSize,
    required _DriveCameraKind cameraKind,
    required Size canvasSize,
    required bool coverViewport,
    bool showDebugGuides = false,
    bool showPathFill = true,
    bool showLaneLines = true,
    bool showRoadEdge = true,
    bool showLead1 = true,
    bool showLead2 = true,
    bool showRadarBadge = true,
    bool showRadarVector = true,
    bool showStopDistanceTf = true,
    bool showStateText = true,
  }) {
    final painter = _DriveOverlayPainter(
      snapshot: snapshot,
      isConnected: true,
      sourceSize: sourceSize,
      cameraKind: cameraKind,
      coverViewport: coverViewport,
      showDebugGuides: showDebugGuides,
      showPathFill: showPathFill,
      showLaneLines: showLaneLines,
      showRoadEdge: showRoadEdge,
      showLead1: showLead1,
      showLead2: showLead2,
      showRadarBadge: showRadarBadge,
      showRadarVector: showRadarVector,
      showStopDistanceTf: showStopDistanceTf,
      showStateText: showStateText,
    );
    return painter._buildNativeOverlayPayload(canvasSize);
  }

  static String buildProjectionDebugText({
    required _DriveOverlaySnapshot snapshot,
    required Size sourceSize,
    required _DriveCameraKind cameraKind,
    required Size canvasSize,
    required bool coverViewport,
    required String cameraSourceLabel,
  }) {
    final painter = _DriveOverlayPainter(
      snapshot: snapshot,
      isConnected: true,
      sourceSize: sourceSize,
      cameraKind: cameraKind,
      coverViewport: coverViewport,
    );
    return painter._buildProjectionDebugText(
      canvasSize: canvasSize,
      cameraSourceLabel: cameraSourceLabel,
    );
  }

  String _buildProjectionDebugText({
    required Size canvasSize,
    required String cameraSourceLabel,
  }) {
    final src = _effectiveSourceSize;
    final transform = _buildTransform(canvasSize);
    final cameraFrameId = cameraKind == _DriveCameraKind.wideRoad
        ? (snapshot.wideRoadFrameId ?? snapshot.roadFrameId)
        : snapshot.roadFrameId;
    final modelFrameId = snapshot.modelFrameId;
    final gap = (cameraFrameId != null && modelFrameId != null)
        ? (modelFrameId - cameraFrameId).abs()
        : null;

    final sampleLines = <String>[];
    final refLines = <String>[];
    final line = snapshot.path;
    if (line.length >= 2) {
      final n = line.length;
      final xs = _monotonicX(line.x.take(n).toList(growable: false));
      final ys = line.y.take(n).toList(growable: false);
      final zs = line.z.take(n).toList(growable: false);
      if (xs.isNotEmpty && ys.isNotEmpty && zs.isNotEmpty) {
        final idxs =
            List<double>.generate(n, (i) => i.toDouble(), growable: false);
        for (final d in const <double>[5, 10, 20, 30, 40, 60]) {
          if (d > xs.last) continue;
          final idx = _interp1D(d, xs, idxs);
          if (idx >= (n - 1)) continue;
          final y = _interp1D(idx, idxs, ys);
          final z = _interp1D(idx, idxs, zs);
          Offset? p;
          final ok = _mapToScreen(
            transform,
            d,
            y,
            z + (snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22),
            (pt) => p = pt,
          );
          if (!ok || p == null) {
            sampleLines.add('${d.toStringAsFixed(0)}m: out');
          } else {
            sampleLines.add(
              '${d.toStringAsFixed(0)}m: (${p!.dx.toStringAsFixed(1)}, ${p!.dy.toStringAsFixed(1)})',
            );
          }
        }
      }
    }

    final refZ = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
    for (final d in const <double>[5, 10, 20]) {
      Offset? p;
      final ok = _mapToScreen(transform, d, 0.0, refZ, (pt) => p = pt);
      if (!ok || p == null) {
        refLines.add('${d.toStringAsFixed(0)}m: out');
      } else {
        refLines.add(
          '${d.toStringAsFixed(0)}m: (${p!.dx.toStringAsFixed(1)}, ${p!.dy.toStringAsFixed(1)})',
        );
      }
    }

    final rpy = snapshot.calibrationRpy;
    final rpyText = rpy.length >= 3
        ? '${rpy[0].toStringAsFixed(3)}, ${rpy[1].toStringAsFixed(3)}, ${rpy[2].toStringAsFixed(3)}'
        : 'n/a';
    final wideEuler = snapshot.wideFromDeviceEuler;
    final wideText = wideEuler.length >= 3
        ? '${wideEuler[0].toStringAsFixed(3)}, ${wideEuler[1].toStringAsFixed(3)}, ${wideEuler[2].toStringAsFixed(3)}'
        : 'n/a';

    final sampleText = sampleLines.isEmpty
        ? 'samples: n/a'
        : 'samples: ${sampleLines.join(' | ')}';
    final refText = refLines.isEmpty
        ? 'center ref: n/a'
        : 'center ref: ${refLines.join(' | ')}';
    final gapText = gap == null ? 'n/a' : '$gap';
    final placementText =
        'video shift x=${transform.xOffset.toStringAsFixed(1)} y=${transform.yOffset.toStringAsFixed(1)} scale=${transform.sourceScale.toStringAsFixed(3)}';
    final frameText =
        'frame model=${modelFrameId ?? '-'} cam=${cameraFrameId ?? '-'} gap=$gapText';
    final modeText =
        'path mode=${snapshot.pathMode} color=${snapshot.pathColor} width=${snapshot.pathWidthRatio.toStringAsFixed(2)} '
        'active=${snapshot.active ? 1 : 0} lane=${snapshot.activeLaneLine ? 1 : 0}';
    final pathSourceText =
        'path src=${snapshot.usingLateralPath ? 'lateral' : 'model'} '
        'len=${snapshot.path.length} '
        'modelX=${snapshot.modelPathXMax.toStringAsFixed(1)} '
        'lateralX=${snapshot.lateralPathXMax.toStringAsFixed(1)}';
    final sourceText =
        'src ${src.width.toStringAsFixed(0)}x${src.height.toStringAsFixed(0)} '
        'canvas ${canvasSize.width.toStringAsFixed(0)}x${canvasSize.height.toStringAsFixed(0)} '
        'fit=${coverViewport ? 'cover' : 'contain'} cam=${cameraKind.name} $cameraSourceLabel';

    return <String>[
      '[Projection Verify]',
      sourceText,
      frameText,
      modeText,
      pathSourceText,
      'calib rpy: $rpyText',
      'wide euler: $wideText',
      placementText,
      sampleText,
      refText,
    ].join('\n');
  }

  List<Offset> _decodeOverlayPoints(dynamic raw) {
    if (raw is List) {
      if (raw.length >= 2 && raw.first is List) {
        final out = <Offset>[];
        for (final item in raw) {
          if (item is! List || item.length < 2) continue;
          final dx = _DriveOverlaySnapshot._asDouble(item[0]);
          final dy = _DriveOverlaySnapshot._asDouble(item[1]);
          if (dx == null || dy == null) continue;
          out.add(Offset(dx, dy));
        }
        return out;
      }
      if (raw.length >= 6) {
        final out = <Offset>[];
        for (var i = 0; i + 1 < raw.length; i += 2) {
          final dx = _DriveOverlaySnapshot._asDouble(raw[i]);
          final dy = _DriveOverlaySnapshot._asDouble(raw[i + 1]);
          if (dx == null || dy == null) continue;
          out.add(Offset(dx, dy));
        }
        return out;
      }
    }
    return const <Offset>[];
  }

  List<Offset> _mapSourcePointsToCanvas(
    List<Offset> sourcePoints, {
    required Size canvasSize,
    required double sourceWidth,
    required double sourceHeight,
    Map<String, dynamic>? displayTransform,
  }) {
    if (sourcePoints.isEmpty) return const <Offset>[];
    final srcW = (sourceWidth > 1.0) ? sourceWidth : _baseSourceWidth;
    final srcH = (sourceHeight > 1.0) ? sourceHeight : _baseSourceHeight;
    final source = Size(srcW, srcH);
    // Invariant: sidecar points are already projected in source pixel space.
    // Only apply the same display transform used by the camera layer.
    // Do not insert extra projection/normalization here for UI-only changes.
    final placement = _sourceToCanvasPlacementFromDisplayTransform(
      source: source,
      canvas: canvasSize,
      displayTransform: displayTransform,
    );
    final out = <Offset>[];
    for (final p in sourcePoints) {
      final mapped = placement.transform.transform(_V3(p.dx, p.dy, 1.0));
      if (!mapped.x.isFinite || !mapped.y.isFinite) continue;
      out.add(Offset(mapped.x, mapped.y));
    }
    return out;
  }

  Map<String, dynamic>? _currentCameraOverlay2d() {
    final root = snapshot.sidecarOverlay2d;
    if (root == null) return null;
    final cameras = root['cameras'];
    if (cameras is! Map) return null;
    final key = cameraKind == _DriveCameraKind.wideRoad ? 'wideRoad' : 'road';
    final selected = cameras[key];
    if (selected is! Map) return null;
    return Map<String, dynamic>.from(selected);
  }

  Map<String, dynamic>? _buildNativeOverlayPayloadFromSidecar2d(Size size) {
    final cam = _currentCameraOverlay2d();
    if (cam == null) return null;
    final transform = _buildTransform(size);
    final sourceWidth =
        _DriveOverlaySnapshot._asDouble(cam['sourceWidth']) ?? _baseSourceWidth;
    final sourceHeight = _DriveOverlaySnapshot._asDouble(cam['sourceHeight']) ??
        _baseSourceHeight;
    final displayTransformRaw = cam['displayTransform'];
    final displayTransform = displayTransformRaw is Map
        ? Map<String, dynamic>.from(displayTransformRaw)
        : null;
    var sidecarPathMode =
        _DriveOverlaySnapshot._asInt(cam['pathMode']) ?? snapshot.pathMode;
    var sidecarPathColor =
        _DriveOverlaySnapshot._asInt(cam['pathColor']) ?? snapshot.pathColor;
    // Enforce classic visual style on sidecar-provided payload as well.
    if (sidecarPathMode >= 13 && sidecarPathMode <= 15) {
      sidecarPathMode = 0;
    }
    if (sidecarPathColor == 14 || sidecarPathColor == 19) {
      sidecarPathColor = 3;
    }
    var sidecarBrakeLights = snapshot.brakeLights;
    final meta = cam['meta'];
    if (meta is Map) {
      final brakeRaw = meta['brakeLights'];
      if (brakeRaw is bool) {
        sidecarBrakeLights = brakeRaw;
      } else if (brakeRaw is num) {
        sidecarBrakeLights = brakeRaw != 0;
      } else if (brakeRaw is String) {
        final lower = brakeRaw.trim().toLowerCase();
        if (lower == '1' || lower == 'true' || lower == 'yes') {
          sidecarBrakeLights = true;
        } else if (lower == '0' || lower == 'false' || lower == 'no') {
          sidecarBrakeLights = false;
        }
      }
    }
    final polygons = <Map<String, dynamic>>[];
    final labels = <Map<String, dynamic>>[];

    final laneRaw = cam['lanePolygons'];
    if (showLaneLines && laneRaw is List) {
      for (final item in laneRaw) {
        if (item is! Map) continue;
        final points = _mapSourcePointsToCanvas(
          _decodeOverlayPoints(item['points']),
          canvasSize: size,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          displayTransform: displayTransform,
        );
        if (points.length < 3) continue;
        final probability =
            (_DriveOverlaySnapshot._asDouble(item['probability']) ?? 0.0)
                .clamp(0.0, 1.0);
        if (probability <= 0.3) continue;
        final laneIndex = _DriveOverlaySnapshot._asInt(item['index']) ?? -1;
        Color laneColor = Colors.white;
        if (laneIndex == 1 && snapshot.leftLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        } else if (laneIndex == 2 && snapshot.rightLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        }
        polygons.add(
          _encodePolygon(
            points,
            laneColor.withValues(alpha: 220.0 / 255.0),
          ),
        );
      }
    }

    final edgeRaw = cam['roadEdgePolygons'];
    if (showRoadEdge && edgeRaw is List) {
      for (final item in edgeRaw) {
        if (item is! Map) continue;
        final points = _mapSourcePointsToCanvas(
          _decodeOverlayPoints(item['points']),
          canvasSize: size,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          displayTransform: displayTransform,
        );
        if (points.length < 3) continue;
        final std = _DriveOverlaySnapshot._asDouble(item['std']) ?? 1.0;
        polygons.add(_encodePolygon(points, _roadEdgeColor(std)));
      }
    }

    var trackVertices = _mapSourcePointsToCanvas(
      _decodeOverlayPoints(cam['pathTrackVertices']),
      canvasSize: size,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      displayTransform: displayTransform,
    );
    if (trackVertices.length < 3 && snapshot.path.length >= 2) {
      final modelMax = snapshot.path.x.isNotEmpty ? snapshot.path.x.last : 0.0;
      final maxDistance = modelMax.clamp(10.0, 100.0);
      final widthApply = _pathHalfWidthByMode(
        sidecarPathMode,
        snapshot.pathWidthRatio,
      );
      final zOff = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
      final fallbackTrack = _mapLineToTrackVerticesDist(
        transform,
        snapshot.path,
        widthApply,
        zOff,
        zOff,
        maxDistance,
        startDistance: snapshot.active ? 2.0 : 3.5,
        allowInvert: false,
      );
      if (fallbackTrack != null && fallbackTrack.length >= 3) {
        trackVertices = fallbackTrack;
      }
    }
    if (showPathFill && trackVertices.length >= 3) {
      _collectPathPolygonsByMode(
        polygons,
        trackVertices,
        sidecarPathMode,
        sidecarPathColor,
        sidecarBrakeLights,
      );
    }

    _appendSidecarLeadAndRadarPolygons(
      cam: cam,
      canvasSize: size,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      displayTransform: displayTransform,
      polygons: polygons,
      labels: labels,
      showLead1: showLead1,
      showLead2: showLead2,
      showRadarBadge: showRadarBadge,
      showRadarVector: showRadarVector,
      showStopDistanceTf: showStopDistanceTf,
      showStateText: showStateText,
    );
    _appendNavArOverlayPolygons(
      polygons: polygons,
      labels: labels,
      transform: transform,
      canvasSize: size,
    );

    if (showDebugGuides) {
      _appendDebugScreenGridPolygons(
        polygons,
        canvasSize: size,
      );
      labels.addAll(_buildDebugGridLabels(canvasSize: size));
    }

    if (polygons.isEmpty && labels.isEmpty) return null;
    return <String, dynamic>{
      'version': 3,
      'canvasWidth': size.width,
      'canvasHeight': size.height,
      'sourceWidth': sourceWidth,
      'sourceHeight': sourceHeight,
      'polygons': polygons,
      if (labels.isNotEmpty) 'labels': labels,
    };
  }

  Map<String, dynamic>? _buildNativeOverlayPayload(Size size) {
    final sidecarPayload = _buildNativeOverlayPayloadFromSidecar2d(size);
    if (sidecarPayload != null) return sidecarPayload;
    if (snapshot.path.length < 2) return null;

    final transform = _buildTransform(size);
    final modelMax = snapshot.path.x.isNotEmpty ? snapshot.path.x.last : 0.0;
    final maxDistance = modelMax.clamp(10.0, 100.0);
    final laneBaseX = snapshot.laneLines.isNotEmpty
        ? snapshot.laneLines.first.line.x
        : snapshot.path.x;
    final laneMaxIdx = laneBaseX.isNotEmpty
        ? _getPathLengthIdx(laneBaseX, maxDistance)
        : _getPathLengthIdx(snapshot.path.x, maxDistance);

    final polygons = <Map<String, dynamic>>[];
    List<Map<String, dynamic>>? labels;

    if (showLaneLines) {
      for (var i = 0; i < snapshot.laneLines.length; i++) {
        final ln = snapshot.laneLines[i];
        var lineWidth = 0.025;
        if (i == 1 && snapshot.leftLaneLine >= 20) {
          lineWidth = 0.05;
        }
        final poly = _mapLineToPolygonVertices(
          transform,
          ln.line,
          lineWidth,
          0.0,
          laneMaxIdx,
        );
        if (poly == null) continue;
        final alpha = ln.probability > 0.3 ? (220.0 / 255.0) : 0.0;
        if (alpha <= 0.0) continue;
        Color laneColor = Colors.white;
        if (i == 1 && snapshot.leftLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        } else if (i == 2 && snapshot.rightLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        }
        polygons.add(_encodePolygon(
          poly,
          laneColor.withValues(alpha: alpha),
        ));
        if (i == 1 && (snapshot.leftLaneLine % 10) == 4) {
          final doublePoly = _mapLineToPolygonVertices(
            transform,
            ln.line,
            lineWidth,
            0.0,
            laneMaxIdx,
            lineCenterShift: -0.3,
          );
          if (doublePoly != null) {
            polygons.add(_encodePolygon(
              doublePoly,
              laneColor.withValues(alpha: alpha),
            ));
          }
        }
      }
    }

    if (showRoadEdge) {
      for (final edge in snapshot.roadEdges) {
        final poly = _mapLineToPolygonVertices(
          transform,
          edge.line,
          0.025,
          0.0,
          laneMaxIdx,
        );
        if (poly == null) continue;
        polygons.add(_encodePolygon(poly, _roadEdgeColor(edge.std)));
      }
    }

    final pathMode = snapshot.pathMode;
    final widthApply = _pathHalfWidthByMode(pathMode, snapshot.pathWidthRatio);
    final zOff = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
    final startDistance = snapshot.active ? 2.0 : 3.5;
    final trackVertices = _mapLineToTrackVerticesDist(
      transform,
      snapshot.path,
      widthApply,
      zOff,
      zOff,
      maxDistance,
      startDistance: startDistance,
      allowInvert: false,
    );
    if (showPathFill && trackVertices != null && trackVertices.length >= 3) {
      final colorIdx = snapshot.pathColor;
      final brakeLights = snapshot.brakeLights;
      _collectPathPolygonsByMode(
        polygons,
        trackVertices,
        pathMode,
        colorIdx,
        brakeLights,
      );
    }
    labels ??= <Map<String, dynamic>>[];
    _appendNavArOverlayPolygons(
      polygons: polygons,
      labels: labels,
      transform: transform,
      canvasSize: size,
    );
    if (labels.isEmpty) labels = null;

    if (showDebugGuides) {
      _appendDebugGuidePolygons(
        polygons,
        canvasSize: size,
        transform: transform,
        trackVertices: trackVertices,
      );
      labels = _buildDebugGridLabels(canvasSize: size);
    }

    if (polygons.isEmpty && (labels == null || labels.isEmpty)) return null;
    final src = _effectiveSourceSize;
    return <String, dynamic>{
      'version': 2,
      'canvasWidth': size.width,
      'canvasHeight': size.height,
      'sourceWidth': src.width,
      'sourceHeight': src.height,
      'polygons': polygons,
      if (labels != null && labels.isNotEmpty) 'labels': labels,
    };
  }

  void _appendPathPolygon(
    List<Map<String, dynamic>> out,
    List<Offset> vertices,
    Color fillColor, {
    required bool strokeEnabled,
    required Color strokeColor,
  }) {
    if (vertices.length < 3) return;
    out.add(
      _encodePolygon(
        vertices,
        fillColor.withValues(alpha: 0.42),
        strokeColor: strokeEnabled ? strokeColor : null,
        strokeWidth: strokeEnabled ? 2.0 : 0.0,
      ),
    );
  }

  void _collectSpecialModePolygons(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    final glen = (trackLen ~/ 2) - 1;
    if (glen < 2) return;
    var g = 0.05;
    var gc = 0.4;
    if (mode == 13) {
      g = 0.2;
      gc = 0.10;
    } else if (mode == 14) {
      g = 0.45;
      gc = 0.05;
    } else if (mode == 15) {
      gc = g;
    }

    final strip0 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    final strip1 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    final strip2 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    for (var i = 0; i < glen; i++) {
      final e = trackLen - i - 1;
      final ge = (glen * 2) - 1 - i;
      final p1 = trackVertices[i];
      final p2 = trackVertices[e];
      strip0[i] = p1;
      strip0[ge] = Offset(
        p1.dx + (p2.dx - p1.dx) * g,
        p1.dy + (p2.dy - p1.dy) * g,
      );
      strip1[i] = Offset(
        p1.dx + (p2.dx - p1.dx) * (0.5 - gc),
        p1.dy + (p2.dy - p1.dy) * (0.5 - gc),
      );
      strip1[ge] = Offset(
        p1.dx + (p2.dx - p1.dx) * (0.5 + gc),
        p1.dy + (p2.dy - p1.dy) * (0.5 + gc),
      );
      strip2[i] = Offset(
        p1.dx + (p2.dx - p1.dx) * (1.0 - g),
        p1.dy + (p2.dy - p1.dy) * (1.0 - g),
      );
      strip2[ge] = p2;
    }

    final baseColor = _pathColorFromIndex(colorIdx);
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    if (mode == 13 || mode == 14) {
      _appendPathPolygon(
        out,
        strip0,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
    if (mode == 13 || mode == 15) {
      _appendPathPolygon(
        out,
        strip1,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
    if (mode == 13 || mode == 14) {
      _appendPathPolygon(
        out,
        strip2,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
  }

  void _collectComplexPathPolygons(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 5) return;
    final baseColor = _pathColorFromIndex(colorIdx);
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    for (var i = 0; i < half - 1; i += 3) {
      final e = trackLen - i - 1;
      if (i + 2 >= half || e - 2 < 0) break;
      final p0 = trackVertices[i];
      final p1 = trackVertices[i + 1];
      final p2l = trackVertices[i + 2];
      final p2r = trackVertices[e - 2];
      final p3 = trackVertices[e - 1];
      final p4 = trackVertices[e];
      final p2 = Offset((p2l.dx + p2r.dx) * 0.5, (p2l.dy + p2r.dy) * 0.5);
      final p5 = Offset((p1.dx + p3.dx) * 0.5, (p1.dy + p3.dy) * 0.5);
      _appendPathPolygon(
        out,
        <Offset>[p0, p1, p2, p3, p4, p5],
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
  }

  void _collectMode1To6Polygons(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
    int pathDrawSeq,
    int pathDrawSeq2,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 5) return;
    var colorN = 0;
    for (var i = 0; i < half - 4; i += 2) {
      final draw = (half < 8 ||
          mode == 5 ||
          mode == 6 ||
          pathDrawSeq == i ~/ 2 ||
          pathDrawSeq == (i ~/ 2) - 2 ||
          pathDrawSeq2 == i ~/ 2 ||
          pathDrawSeq2 == (i ~/ 2) - 2);
      if (!draw) {
        if (i > 1) colorN = (colorN + 1) % 7;
        continue;
      }
      final idx = (mode == 2 || mode == 6) ? colorN : (colorIdx % 10);
      final fill = _pathColorFromIndex(idx);
      final strokeEnabled = colorIdx >= 10 || brakeLights;
      final strokeColor =
          brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
      _appendPathPolygon(
        out,
        <Offset>[
          trackVertices[i],
          trackVertices[i + 2],
          trackVertices[trackLen - i - 3],
          trackVertices[trackLen - i - 1],
        ],
        fill,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      if (i > 1) colorN = (colorN + 1) % 7;
    }
  }

  void _collectMode3To8Polygons(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
    int pathDrawSeq,
    int pathDrawSeq2,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 6) return;
    var colorN = 0;
    for (var i = 0; i < half - 4; i += 2) {
      if (i + 4 >= half || trackLen - i - 5 < 0) break;
      final draw = (half < 8 ||
          mode == 7 ||
          mode == 8 ||
          pathDrawSeq == i ~/ 2 ||
          pathDrawSeq == (i ~/ 2) - 2 ||
          pathDrawSeq2 == i ~/ 2 ||
          pathDrawSeq2 == (i ~/ 2) - 2);
      if (!draw) {
        if (i > 1) colorN = (colorN + 1) % 7;
        continue;
      }
      final idx = (mode == 4 || mode == 8) ? colorN : (colorIdx % 10);
      final fill = _pathColorFromIndex(idx);
      final strokeEnabled = colorIdx >= 10 || brakeLights;
      final strokeColor =
          brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);

      final p1 = trackVertices[i + 2];
      final p3 = trackVertices[trackLen - i - 3];
      _appendPathPolygon(
        out,
        <Offset>[
          trackVertices[i],
          p1,
          Offset(
            (trackVertices[i + 4].dx + trackVertices[trackLen - i - 5].dx) *
                0.5,
            (trackVertices[i + 4].dy + trackVertices[trackLen - i - 5].dy) *
                0.5,
          ),
          p3,
          trackVertices[trackLen - i - 1],
          Offset((p1.dx + p3.dx) * 0.5, (p1.dy + p3.dy) * 0.5),
        ],
        fill,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      if (i > 1) colorN = (colorN + 1) % 7;
    }
  }

  void _collectAnimatedPathPolygons(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    if (trackLen < 8) return;
    final maxSeq = math.min((trackLen ~/ 4) + 3, 16);
    if (maxSeq <= 0) return;
    final phase = snapshot.animationPhase;
    var normalized = phase % maxSeq;
    if (normalized < 0) normalized += maxSeq;
    final seqInt = normalized.floor();
    final pathDrawSeq2 =
        (maxSeq > 15) ? ((seqInt - (maxSeq ~/ 2) + maxSeq) % maxSeq) : -5;
    switch (mode) {
      case 1:
      case 2:
      case 5:
      case 6:
        _collectMode1To6Polygons(
          out,
          trackVertices,
          mode,
          colorIdx,
          brakeLights,
          seqInt,
          pathDrawSeq2,
        );
        break;
      case 3:
      case 4:
      case 7:
      case 8:
        _collectMode3To8Polygons(
          out,
          trackVertices,
          mode,
          colorIdx,
          brakeLights,
          seqInt,
          pathDrawSeq2,
        );
        break;
      default:
        _collectComplexPathPolygons(out, trackVertices, colorIdx, brakeLights);
        break;
    }
  }

  void _collectPathPolygonsByMode(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
  ) {
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    final fillColor = _pathColorFromIndex(colorIdx);
    if (mode == 0) {
      _appendPathPolygon(
        out,
        trackVertices,
        fillColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      return;
    }
    if (mode >= 13 && mode <= 15) {
      _collectSpecialModePolygons(
          out, trackVertices, mode, colorIdx, brakeLights);
      return;
    }
    if (mode >= 9) {
      _collectComplexPathPolygons(out, trackVertices, colorIdx, brakeLights);
      return;
    }
    _collectAnimatedPathPolygons(
        out, trackVertices, mode, colorIdx, brakeLights);
  }

  Map<String, dynamic> _encodePolygon(
    List<Offset> vertices,
    Color fillColor, {
    Color? strokeColor,
    double strokeWidth = 0.0,
  }) {
    final points = <double>[];
    for (final v in vertices) {
      points
        ..add(v.dx)
        ..add(v.dy);
    }
    return <String, dynamic>{
      'points': points,
      'fillColor': fillColor.toARGB32(),
      if (strokeColor != null) 'strokeColor': strokeColor.toARGB32(),
      if (strokeColor != null) 'strokeWidth': strokeWidth,
    };
  }

  List<Offset> _lineQuadVertices(Offset a, Offset b, double thickness) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = math.sqrt((dx * dx) + (dy * dy));
    if (!len.isFinite || len <= 1e-6) {
      final t = thickness * 0.5;
      return <Offset>[
        Offset(a.dx - t, a.dy - t),
        Offset(a.dx + t, a.dy - t),
        Offset(a.dx + t, a.dy + t),
        Offset(a.dx - t, a.dy + t),
      ];
    }
    final nx = -dy / len;
    final ny = dx / len;
    final t = thickness * 0.5;
    final ox = nx * t;
    final oy = ny * t;
    return <Offset>[
      Offset(a.dx + ox, a.dy + oy),
      Offset(b.dx + ox, b.dy + oy),
      Offset(b.dx - ox, b.dy - oy),
      Offset(a.dx - ox, a.dy - oy),
    ];
  }

  void _appendDebugLinePolygon(
    List<Map<String, dynamic>> out, {
    required Offset a,
    required Offset b,
    required Color color,
    double thickness = 2.0,
  }) {
    if (!a.dx.isFinite ||
        !a.dy.isFinite ||
        !b.dx.isFinite ||
        !b.dy.isFinite ||
        thickness <= 0.0) {
      return;
    }
    final quad = _lineQuadVertices(a, b, thickness);
    if (quad.length < 4) return;
    out.add(_encodePolygon(quad, color));
  }

  Rect? _verticesBounds(List<Offset> vertices) {
    if (vertices.isEmpty) return null;
    var minX = vertices.first.dx;
    var minY = vertices.first.dy;
    var maxX = vertices.first.dx;
    var maxY = vertices.first.dy;
    for (final p in vertices) {
      if (!p.dx.isFinite || !p.dy.isFinite) continue;
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    if ((maxX - minX) <= 1e-3 || (maxY - minY) <= 1e-3) return null;
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  bool _boolFromDynamic(dynamic raw, {bool fallback = false}) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final value = raw.trim().toLowerCase();
      if (value == '1' || value == 'true' || value == 'yes' || value == 'on') {
        return true;
      }
      if (value == '0' || value == 'false' || value == 'no' || value == 'off') {
        return false;
      }
    }
    return fallback;
  }

  List<Offset> _rectVertices(
      double left, double top, double right, double bottom) {
    return <Offset>[
      Offset(left, top),
      Offset(right, top),
      Offset(right, bottom),
      Offset(left, bottom),
    ];
  }

  List<Offset> _roundedRectVertices(
    Rect rect, {
    double radius = 15.0,
    int segmentsPerCorner = 4,
  }) {
    if (rect.width <= 0.0 || rect.height <= 0.0) return const <Offset>[];
    final r = math.min(radius, math.min(rect.width, rect.height) * 0.5);
    final seg = math.max(2, segmentsPerCorner);
    final points = <Offset>[];
    void addArc(Offset center, double start, double end) {
      for (var i = 0; i <= seg; i++) {
        final t = i / seg;
        final a = start + ((end - start) * t);
        points.add(Offset(
            center.dx + (math.cos(a) * r), center.dy + (math.sin(a) * r)));
      }
    }

    addArc(Offset(rect.right - r, rect.top + r), -math.pi / 2.0, 0.0);
    addArc(Offset(rect.right - r, rect.bottom - r), 0.0, math.pi / 2.0);
    addArc(Offset(rect.left + r, rect.bottom - r), math.pi / 2.0, math.pi);
    addArc(Offset(rect.left + r, rect.top + r), math.pi, math.pi * 1.5);
    return points;
  }

  List<Offset> _circleVertices(
    Offset center,
    double radius, {
    int segments = 18,
  }) {
    if (radius <= 0.0) return const <Offset>[];
    final steps = segments < 6 ? 6 : segments;
    final points = <Offset>[];
    for (var i = 0; i < steps; i++) {
      final theta = (math.pi * 2.0 * i) / steps;
      points.add(
        Offset(
          center.dx + (math.cos(theta) * radius),
          center.dy + (math.sin(theta) * radius),
        ),
      );
    }
    return points;
  }

  void _appendOverlayLabel(
    List<Map<String, dynamic>> labels, {
    required Offset anchor,
    required String text,
    required Color color,
    double size = 20.0,
    bool centered = true,
  }) {
    final content = text.trim();
    if (content.isEmpty || !anchor.dx.isFinite || !anchor.dy.isFinite) return;
    final x =
        centered ? (anchor.dx - (content.length * size * 0.22)) : anchor.dx;
    labels.add(<String, dynamic>{
      'x': x,
      'y': anchor.dy,
      'text': content,
      'color': color.toARGB32(),
      'size': size,
    });
  }

  void _appendBadge(
    List<Map<String, dynamic>> polygons,
    List<Map<String, dynamic>> labels, {
    required Offset center,
    required String text,
    required Color fillColor,
    required Color textColor,
    Color? strokeColor,
    double fontSize = 22.0,
    double minWidth = 54.0,
    double height = 38.0,
  }) {
    final content = text.trim();
    if (content.isEmpty || !center.dx.isFinite || !center.dy.isFinite) return;
    final width = math
        .max(minWidth, (content.length * fontSize * 0.62) + 18.0)
        .toDouble();
    final left = center.dx - (width * 0.5);
    final top = center.dy - (height * 0.5);
    final right = left + width;
    final bottom = top + height;
    polygons.add(
      _encodePolygon(
        _rectVertices(left, top, right, bottom),
        fillColor,
        strokeColor: strokeColor,
        strokeWidth: strokeColor == null ? 0.0 : 2.0,
      ),
    );
    _appendOverlayLabel(
      labels,
      anchor: Offset(center.dx, top + (height * 0.70)),
      text: content,
      color: textColor,
      size: fontSize,
      centered: true,
    );
  }

  String _navTurnText(int turnInfo, String fallbackText) {
    final fallback = fallbackText.trim();
    if (fallback.isNotEmpty) return fallback;
    switch (turnInfo) {
      case 1:
        return '좌회전';
      case 2:
        return '우회전';
      case 3:
        return '좌차선 변경';
      case 4:
        return '우차선 변경';
      case 7:
        return '유턴';
      case 8:
        return '도착';
      default:
        return '';
    }
  }

  String _formatNavDistance(double? distanceMeters) {
    if (distanceMeters == null ||
        !distanceMeters.isFinite ||
        distanceMeters <= 0) {
      return '';
    }
    if (distanceMeters >= 1000.0) {
      return '${(distanceMeters / 1000.0).toStringAsFixed(1)}km';
    }
    return '${distanceMeters.round()}m';
  }

  List<Offset> _arrowHeadVertices(Offset center, double angle, double size) {
    final forward = Offset(math.cos(angle), math.sin(angle));
    final side = Offset(-forward.dy, forward.dx);
    final tip = Offset(
      center.dx + (forward.dx * size),
      center.dy + (forward.dy * size),
    );
    final rear = Offset(
      center.dx - (forward.dx * size * 0.92),
      center.dy - (forward.dy * size * 0.92),
    );
    final left = Offset(
      rear.dx + (side.dx * size * 0.70),
      rear.dy + (side.dy * size * 0.70),
    );
    final right = Offset(
      rear.dx - (side.dx * size * 0.70),
      rear.dy - (side.dy * size * 0.70),
    );
    final inner = Offset(
      center.dx - (forward.dx * size * 0.16),
      center.dy - (forward.dy * size * 0.16),
    );
    return <Offset>[left, tip, right, inner];
  }

  void _appendNavArOverlayPolygons({
    required List<Map<String, dynamic>> polygons,
    required List<Map<String, dynamic>> labels,
    required _ProjectionTransform transform,
    required Size canvasSize,
  }) {
    if (cameraKind != _DriveCameraKind.road) return;

    // Road-camera AR tuning knobs:
    // - distanceScale: perspective depth scaling for nav path/chevrons
    // - pathVerticalOffsetPx: vertical offset applied to projected nav path
    // - gateVerticalOffsetPx: additional vertical offset for turn board
    const distanceScale = 0.92;
    final pathVerticalOffsetPx = canvasSize.height * 0.018;
    final gateVerticalOffsetPx = -(canvasSize.height * 0.028);

    final navPath = snapshot.navPathPoints;
    final hasTurnText = snapshot.navMainText.trim().isNotEmpty;
    final hasTurnInfo = snapshot.navTurnInfo != 0 || hasTurnText;
    if (navPath.length < 2 && !hasTurnInfo) return;

    final laneBaseLine = snapshot.laneLines.length > 2
        ? snapshot.laneLines[2].line
        : (snapshot.laneLines.isNotEmpty
            ? snapshot.laneLines.first.line
            : null);
    final laneX = laneBaseLine?.x ?? snapshot.path.x;
    final laneZ = laneBaseLine?.z ?? snapshot.path.z;
    final zOffset = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;

    final projected = <Offset>[];
    final projectedDist = <double>[];
    for (final p in navPath) {
      if (!p.x.isFinite || !p.y.isFinite || !p.d.isFinite) continue;
      if (p.x < 2.0 || p.x > 140.0) continue;
      final sampleDist = (p.d > 0 ? p.d : p.x) * distanceScale;
      var z = 0.0;
      if (laneX.isNotEmpty && laneZ.isNotEmpty) {
        final idx = _getPathLengthIdx(laneX, sampleDist);
        if (laneZ.isNotEmpty) {
          final zi = idx.clamp(0, laneZ.length - 1);
          z = laneZ[zi];
        }
      }
      Offset? out;
      final ok = _mapToScreen(
        transform,
        ((p.x < 3.0 ? 5.0 : p.x) * distanceScale).clamp(2.0, 140.0),
        p.y,
        z + zOffset,
        (pt) => out = pt,
      );
      if (!ok || out == null) continue;
      final o = Offset(out!.dx, out!.dy + pathVerticalOffsetPx);
      if (o.dx < -60.0 ||
          o.dx > canvasSize.width + 60.0 ||
          o.dy < -60.0 ||
          o.dy > canvasSize.height + 60.0) {
        continue;
      }
      projected.add(o);
      projectedDist.add(sampleDist);
      if (projected.length >= 90) break;
    }

    if (projected.length >= 2) {
      final segmentStep = math.max(1, (projected.length / 34).floor());
      for (var i = 0; i + segmentStep < projected.length; i += segmentStep) {
        final a = projected[i];
        final b = projected[i + segmentStep];
        final t = i / math.max(1, projected.length - 1);
        final glowWidth = (11.0 - (t * 4.5)).clamp(4.8, 11.0);
        final coreWidth = (5.6 - (t * 2.2)).clamp(2.4, 5.6);
        polygons.add(
          _encodePolygon(
            _lineQuadVertices(a, b, glowWidth),
            const Color(0x5535FF84),
          ),
        );
        polygons.add(
          _encodePolygon(
            _lineQuadVertices(a, b, coreWidth),
            const Color(0xCC2EEA6A),
          ),
        );
      }

      final chevronCount = math.min(3, projected.length - 1);
      final chevronSize = (canvasSize.width * 0.013).clamp(8.0, 14.0);
      for (var c = 0; c < chevronCount; c++) {
        final idx = (((c + 1) * (projected.length - 2)) / (chevronCount + 1))
            .round()
            .clamp(0, projected.length - 2);
        final a = projected[idx];
        final b = projected[idx + 1];
        final dir = b - a;
        final len = dir.distance;
        if (!len.isFinite || len <= 1.0) continue;
        final center = Offset(
          a.dx + (dir.dx * 0.35),
          a.dy + (dir.dy * 0.35),
        );
        final angle = math.atan2(dir.dy, dir.dx);
        polygons.add(
          _encodePolygon(
            _arrowHeadVertices(center, angle, chevronSize),
            const Color(0xCC244CFF),
            strokeColor: const Color(0xCCFFFFFF),
            strokeWidth: 1.4,
          ),
        );
      }
    }

    final turnText = _navTurnText(snapshot.navTurnInfo, snapshot.navMainText);
    final turnDistText = _formatNavDistance(snapshot.navDistToTurn);
    final gateText = turnText.isEmpty
        ? ''
        : (turnDistText.isEmpty ? turnText : '$turnDistText 후 $turnText');

    if (gateText.isNotEmpty) {
      Offset gateAnchor;
      if (projected.isNotEmpty) {
        var anchorIdx = -1;
        for (var i = 0; i < projected.length; i++) {
          final d = i < projectedDist.length ? projectedDist[i] : 0.0;
          if (d >= 14.0 && d <= 38.0) {
            anchorIdx = i;
            break;
          }
        }
        if (anchorIdx < 0) anchorIdx = projected.length ~/ 2;
        gateAnchor = projected[anchorIdx];
      } else {
        gateAnchor = Offset(canvasSize.width * 0.5, canvasSize.height * 0.28);
      }

      final fontSize = (canvasSize.width * 0.017).clamp(13.0, 20.0);
      final boardWidth = math
          .min(
            canvasSize.width * 0.66,
            math.max(170.0, (gateText.length * fontSize * 0.58) + 38.0),
          )
          .toDouble();
      final boardHeight = (fontSize * 2.2).clamp(46.0, 74.0);
      final left = (gateAnchor.dx - (boardWidth * 0.5))
          .clamp(12.0, canvasSize.width - boardWidth - 12.0);
      final top = (gateAnchor.dy -
              boardHeight -
              (fontSize * 1.8) +
              gateVerticalOffsetPx)
          .clamp(12.0, canvasSize.height - boardHeight - 20.0);
      final gateRect = Rect.fromLTWH(left, top, boardWidth, boardHeight);

      polygons.add(
        _encodePolygon(
          _roundedRectVertices(gateRect, radius: 14.0, segmentsPerCorner: 5),
          const Color(0xE617A84B),
          strokeColor: const Color(0xCCFFFFFF),
          strokeWidth: 1.4,
        ),
      );
      _appendOverlayLabel(
        labels,
        anchor:
            Offset(gateRect.center.dx, gateRect.center.dy + (fontSize * 0.22)),
        text: gateText,
        color: Colors.white,
        size: fontSize,
        centered: true,
      );
    }

    String statusText;
    Color statusFill;
    if (snapshot.navTurnInfo == 8 ||
        turnText.contains('도착') ||
        snapshot.navMainText.contains('도착')) {
      statusText = '도착 임박';
      statusFill = const Color(0xE617A84B);
    } else if (projected.length >= 2) {
      statusText = '정상 경로';
      statusFill = const Color(0xE617A84B);
    } else {
      statusText = '경로 탐색 중';
      statusFill = const Color(0xD9A36800);
    }
    _appendBadge(
      polygons,
      labels,
      center: Offset(canvasSize.width * 0.5, canvasSize.height - 58.0),
      text: statusText,
      fillColor: statusFill,
      textColor: Colors.white,
      strokeColor: const Color(0xB3FFFFFF),
      fontSize: (canvasSize.width * 0.012).clamp(12.0, 16.0),
      minWidth: 132.0,
      height: 36.0,
    );
  }

  void _appendSidecarLeadAndRadarPolygons({
    required Map<String, dynamic> cam,
    required Size canvasSize,
    required double sourceWidth,
    required double sourceHeight,
    required Map<String, dynamic>? displayTransform,
    required List<Map<String, dynamic>> polygons,
    required List<Map<String, dynamic>> labels,
    required bool showLead1,
    required bool showLead2,
    required bool showRadarBadge,
    required bool showRadarVector,
    required bool showStopDistanceTf,
    required bool showStateText,
  }) {
    final meta = cam['meta'];
    final showRadarInfo = meta is Map
        ? (_DriveOverlaySnapshot._asInt(meta['showRadarInfo']) ?? 0)
        : 0;
    final xState =
        meta is Map ? (_DriveOverlaySnapshot._asInt(meta['xState']) ?? 0) : 0;
    final trafficState = meta is Map
        ? (_DriveOverlaySnapshot._asInt(meta['trafficState']) ?? 0)
        : 0;
    final longActive = meta is Map
        ? _boolFromDynamic(meta['longActive'], fallback: false)
        : false;
    final vEgoMps = meta is Map
        ? (_DriveOverlaySnapshot._asDouble(meta['vEgoMps']) ?? 0.0)
        : 0.0;

    var drawDistanceBadges = true;
    String? stateText;
    if (longActive) {
      if (xState == 3 || xState == 5) {
        drawDistanceBadges = false;
        if (vEgoMps < 1.0) {
          stateText = trafficState >= 1000 ? 'Signal Error' : 'Signal Ready';
        } else {
          stateText = 'Signal slowing';
        }
      } else if (xState == 4) {
        drawDistanceBadges = false;
        stateText = 'E2E주행중';
      } else if (xState == 0 || xState == 1 || xState == 2) {
        drawDistanceBadges = true;
      } else {
        drawDistanceBadges = false;
      }
    }
    final badgeTextColor = xState == 0
        ? Colors.white
        : (xState == 1 ? const Color(0xFFB0B0B0) : const Color(0xFF23D55D));

    Offset? mapSingleSourcePoint(dynamic raw) {
      if (raw is! List || raw.length < 2) return null;
      final sx = _DriveOverlaySnapshot._asDouble(raw[0]);
      final sy = _DriveOverlaySnapshot._asDouble(raw[1]);
      if (sx == null || sy == null) return null;
      final mapped = _mapSourcePointsToCanvas(
        <Offset>[Offset(sx, sy)],
        canvasSize: canvasSize,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        displayTransform: displayTransform,
      );
      if (mapped.isEmpty) return null;
      return mapped.first;
    }

    Offset? leadPrimaryCenter;
    Rect? leadPrimaryBounds;
    final leadRaw = cam['leadAreaBoxes'];
    if (leadRaw is List) {
      for (final item in leadRaw) {
        if (item is! Map) continue;
        final lead = Map<String, dynamic>.from(item);
        final mapped = _mapSourcePointsToCanvas(
          _decodeOverlayPoints(lead['points']),
          canvasSize: canvasSize,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          displayTransform: displayTransform,
        );
        if (mapped.length < 3) continue;
        final bounds = _verticesBounds(mapped);
        if (bounds == null) continue;

        final kind = lead['kind']?.toString() ?? 'leadOne';
        if (kind == 'leadOne' && !showLead1) continue;
        if (kind == 'leadTwo' && !showLead2) continue;
        final status = _DriveOverlaySnapshot._asInt(lead['status']) ?? 0;
        final radarDetected = _boolFromDynamic(lead['radar']);
        final radarTrackId =
            _DriveOverlaySnapshot._asInt(lead['radarTrackId']) ?? -1;
        final isLeadScc = radarTrackId < 1;
        final strokeArgb =
            _DriveOverlaySnapshot._asInt(lead['strokeColorArgb']);
        final fillArgb = _DriveOverlaySnapshot._asInt(lead['fillColorArgb']);

        Color strokeColor;
        Color fillColor;
        if (strokeArgb != null || fillArgb != null) {
          strokeColor = strokeArgb != null
              ? Color(strokeArgb)
              : (kind == 'leadTwo'
                  ? const Color(0xFFB68A3A)
                  : const Color(0xFFFFA726));
          fillColor = fillArgb != null
              ? Color(fillArgb)
              : (kind == 'leadTwo'
                  ? (status >= 2
                      ? const Color(0x66FF3B30)
                      : const Color(0x33000000))
                  : const Color(0x33000000));
        } else if (kind == 'leadTwo') {
          strokeColor = const Color(0xFFB68A3A);
          fillColor =
              status >= 2 ? const Color(0x66FF3B30) : const Color(0x33000000);
        } else {
          fillColor = const Color(0x33000000);
          if (!radarDetected) {
            strokeColor = const Color(0xFF3D7BFF);
          } else {
            strokeColor =
                isLeadScc ? const Color(0xFFFF3B30) : const Color(0xFFFFA726);
          }
        }
        polygons.add(
          _encodePolygon(
            _roundedRectVertices(bounds, radius: 15.0, segmentsPerCorner: 4),
            fillColor,
            strokeColor: strokeColor,
            strokeWidth: 3.0,
          ),
        );

        if (kind == 'leadOne') {
          leadPrimaryBounds ??= bounds;
          leadPrimaryCenter ??=
              mapSingleSourcePoint(lead['anchorCenter']) ?? bounds.center;
          final radarDist =
              _DriveOverlaySnapshot._asDouble(lead['radarDistance']) ?? 0.0;
          final visionDist =
              _DriveOverlaySnapshot._asDouble(lead['visionDistance']) ?? 0.0;
          final radarBadgeCenter =
              mapSingleSourcePoint(lead['radarBadgeCenter']);
          final visionBadgeCenter =
              mapSingleSourcePoint(lead['visionBadgeCenter']);
          final radarBadgeColorArgb =
              _DriveOverlaySnapshot._asInt(lead['radarBadgeColorArgb']);
          final visionBadgeColorArgb =
              _DriveOverlaySnapshot._asInt(lead['visionBadgeColorArgb']);
          final canvasBadgeDx =
              (bounds.width * 0.62).clamp(64.0, 140.0).toDouble();
          final canvasBadgeY = bounds.bottom +
              (bounds.height * 0.32).clamp(18.0, 48.0).toDouble();
          if (drawDistanceBadges && showRadarBadge && radarDist > 0.0) {
            _appendBadge(
              polygons,
              labels,
              center: radarBadgeCenter ??
                  Offset(bounds.center.dx - canvasBadgeDx, canvasBadgeY),
              text: radarDist.toStringAsFixed(1),
              fillColor: radarBadgeColorArgb != null
                  ? Color(radarBadgeColorArgb)
                  : (isLeadScc
                      ? const Color(0xFFFF3B30)
                      : const Color(0xFFFFA726)),
              textColor: badgeTextColor,
            );
          }
          if (drawDistanceBadges && showRadarBadge && visionDist > 0.0) {
            _appendBadge(
              polygons,
              labels,
              center: visionBadgeCenter ??
                  Offset(bounds.center.dx + canvasBadgeDx, canvasBadgeY),
              text: visionDist.toStringAsFixed(1),
              fillColor: visionBadgeColorArgb != null
                  ? Color(visionBadgeColorArgb)
                  : const Color(0xFF3D7BFF),
              textColor: badgeTextColor,
            );
          }
        }
      }
    }

    final tfRaw = cam['tfMarker'];
    if (showStopDistanceTf && tfRaw is Map) {
      final tf = Map<String, dynamic>.from(tfRaw);
      final mapped = _mapSourcePointsToCanvas(
        _decodeOverlayPoints(tf['points']),
        canvasSize: canvasSize,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        displayTransform: displayTransform,
      );
      if (mapped.length >= 2) {
        final left = mapped.first;
        final right = mapped.last;
        _appendDebugLinePolygon(
          polygons,
          a: left,
          b: right,
          color: Colors.white,
          thickness: 3.0,
        );
        final dist = _DriveOverlaySnapshot._asDouble(tf['distance']) ?? 0.0;
        final tFollow = _DriveOverlaySnapshot._asDouble(tf['tFollow']) ?? 0.0;
        if (dist > 0.0) {
          _appendOverlayLabel(
            labels,
            anchor: right,
            text: '${dist.toStringAsFixed(1)}(${tFollow.toStringAsFixed(2)})',
            color: Colors.white,
            size: 20.0,
            centered: false,
          );
        }
      }
    }

    if (showStateText && stateText != null) {
      dynamic leadOneAnchorRaw;
      if (leadRaw is List) {
        for (final e in leadRaw) {
          if (e is Map && (e['kind']?.toString() ?? 'leadOne') == 'leadOne') {
            leadOneAnchorRaw = e;
            break;
          }
        }
      }
      Offset? stateAnchor;
      if (leadOneAnchorRaw is Map) {
        final stateCenterRaw = leadOneAnchorRaw['stateTextCenter'];
        stateAnchor = mapSingleSourcePoint(stateCenterRaw);
      }
      if (stateAnchor == null && leadOneAnchorRaw is Map) {
        final raw = leadOneAnchorRaw['anchorCenter'];
        final anchorWidthSrc =
            _DriveOverlaySnapshot._asDouble(leadOneAnchorRaw['anchorWidth']);
        final sourceStateDy = (anchorWidthSrc != null && anchorWidthSrc > 0.0)
            ? (anchorWidthSrc * 0.52).clamp(52.0, 140.0).toDouble()
            : 60.0;
        if (raw is List && raw.length >= 2) {
          final ax = _DriveOverlaySnapshot._asDouble(raw[0]);
          final ay = _DriveOverlaySnapshot._asDouble(raw[1]);
          if (ax != null && ay != null) {
            stateAnchor =
                mapSingleSourcePoint(<double>[ax, ay + sourceStateDy]);
          }
        }
      }
      final primaryCenter = leadPrimaryCenter;
      final anchor = stateAnchor ??
          (primaryCenter != null
              ? Offset(
                  primaryCenter.dx,
                  (leadPrimaryBounds?.bottom ?? primaryCenter.dy) +
                      ((leadPrimaryBounds?.height ?? 72.0) * 0.72)
                          .clamp(36.0, 92.0)
                          .toDouble(),
                )
              : Offset(canvasSize.width * 0.5, canvasSize.height * 0.72));
      _appendOverlayLabel(
        labels,
        anchor: anchor,
        text: stateText,
        color: Colors.white,
        size: 34.0,
        centered: true,
      );
    }

    final radarRaw = cam['radarTargets'];
    if (showRadarInfo <= 0 ||
        radarRaw is! List ||
        (!showRadarBadge && !showRadarVector)) {
      return;
    }
    for (final item in radarRaw) {
      if (item is! Map) continue;
      final radar = Map<String, dynamic>.from(item);
      final center = mapSingleSourcePoint(radar['center']);
      if (center == null) continue;

      final vSigned =
          _DriveOverlaySnapshot._asDouble(radar['speedMpsSigned']) ?? 0.0;
      final speedAbs = vSigned.abs();
      final dRel = _DriveOverlaySnapshot._asDouble(radar['dRel']) ?? 0.0;
      final yRel = _DriveOverlaySnapshot._asDouble(radar['yRel']) ?? 0.0;
      final radarDetected = _boolFromDynamic(radar['radar']);
      final modelProb =
          _DriveOverlaySnapshot._asDouble(radar['modelProb']) ?? 0.0;

      final future = mapSingleSourcePoint(radar['future']);
      if (showRadarVector && future != null && speedAbs > 3.0) {
        _appendDebugLinePolygon(
          polygons,
          a: center,
          b: future,
          color: vSigned >= 0.0
              ? const Color(0xFF23D55D)
              : const Color(0xFFFF3B30),
          thickness: 3.0,
        );
        polygons.add(
          _encodePolygon(
            _circleVertices(future, 7.0),
            vSigned >= 0.0 ? const Color(0xFF23D55D) : const Color(0xFFFF3B30),
          ),
        );
      }

      if (showRadarBadge && speedAbs > 3.0) {
        final speedKph =
            _DriveOverlaySnapshot._asDouble(radar['speedKphSigned']) ??
                (vSigned * 3.6);
        Color badgeColor;
        if (!radarDetected) {
          badgeColor = const Color(0xFF3D7BFF);
        } else if ((modelProb - 0.01).abs() < 1e-3) {
          badgeColor = const Color(0xFF23D55D);
        } else if (vSigned > 0.0) {
          badgeColor = const Color(0xFFFFA726);
        } else {
          badgeColor = const Color(0xFFFF3B30);
        }
        _appendBadge(
          polygons,
          labels,
          center: Offset(center.dx, center.dy - 14.0),
          text: speedKph.toStringAsFixed(0),
          fillColor: badgeColor,
          textColor: Colors.white,
        );
        if (showRadarInfo >= 2) {
          _appendOverlayLabel(
            labels,
            anchor: Offset(center.dx, center.dy - 44.0),
            text: yRel.toStringAsFixed(1),
            color: Colors.white,
            size: 18.0,
            centered: true,
          );
          _appendOverlayLabel(
            labels,
            anchor: Offset(center.dx, center.dy + 28.0),
            text: dRel.toStringAsFixed(1),
            color: Colors.white,
            size: 18.0,
            centered: true,
          );
        }
      } else if (showRadarInfo >= 3) {
        _appendOverlayLabel(
          labels,
          anchor: center,
          text: '*',
          color: Colors.white,
          size: 28.0,
          centered: true,
        );
      }
    }
  }

  void _appendDebugScreenGridPolygons(
    List<Map<String, dynamic>> out, {
    required Size canvasSize,
  }) {
    const minorColor = Color(0x9955FF55);
    const majorColor = Color(0xEE00FF00);
    const cols = 10;
    const rows = 6;
    // Strong frame border so the 2D grid coverage is visually unmistakable.
    _appendDebugLinePolygon(
      out,
      a: const Offset(0, 0),
      b: Offset(canvasSize.width, 0),
      color: majorColor,
      thickness: 3.0,
    );
    _appendDebugLinePolygon(
      out,
      a: Offset(canvasSize.width, 0),
      b: Offset(canvasSize.width, canvasSize.height),
      color: majorColor,
      thickness: 3.0,
    );
    _appendDebugLinePolygon(
      out,
      a: Offset(canvasSize.width, canvasSize.height),
      b: Offset(0, canvasSize.height),
      color: majorColor,
      thickness: 3.0,
    );
    _appendDebugLinePolygon(
      out,
      a: Offset(0, canvasSize.height),
      b: const Offset(0, 0),
      color: majorColor,
      thickness: 3.0,
    );

    for (var i = 1; i < cols; i++) {
      final x = (canvasSize.width * i) / cols;
      final isMajor =
          i == (cols ~/ 2) || i == (cols ~/ 4) || i == ((cols * 3) ~/ 4);
      _appendDebugLinePolygon(
        out,
        a: Offset(x, 0),
        b: Offset(x, canvasSize.height),
        color: isMajor ? majorColor : minorColor,
        thickness: isMajor ? 2.4 : 1.6,
      );
    }
    for (var i = 1; i < rows; i++) {
      final y = (canvasSize.height * i) / rows;
      final isMajor = i == (rows ~/ 2);
      _appendDebugLinePolygon(
        out,
        a: Offset(0, y),
        b: Offset(canvasSize.width, y),
        color: isMajor ? majorColor : minorColor,
        thickness: isMajor ? 2.4 : 1.6,
      );
    }
  }

  List<Map<String, dynamic>> _buildDebugGridLabels({
    required Size canvasSize,
  }) {
    const cols = 10;
    const rows = 6;
    const color = Color(0xDDFAFF9A);
    final labels = <Map<String, dynamic>>[];
    for (var r = 0; r <= rows; r++) {
      final y = (canvasSize.height * r) / rows;
      for (var c = 0; c <= cols; c++) {
        final x = (canvasSize.width * c) / cols;
        final nx = (c / cols).toStringAsFixed(1);
        final ny = (r / rows).toStringAsFixed(1);
        final lx =
            _clampDouble(x + 4.0, 2.0, math.max(2.0, canvasSize.width - 48.0));
        final ly = _clampDouble(
            y + 11.0, 10.0, math.max(10.0, canvasSize.height - 2.0));
        labels.add(<String, dynamic>{
          'x': lx,
          'y': ly,
          'text': '$nx,$ny',
          'color': color.toARGB32(),
          'size': 10.0,
        });
      }
    }
    return labels;
  }

  void _drawDebugGridLabels(
    Canvas canvas, {
    required Size size,
  }) {
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    );
    final labels = _buildDebugGridLabels(canvasSize: size);
    for (final raw in labels) {
      final dx = _DriveOverlaySnapshot._asDouble(raw['x']);
      final dy = _DriveOverlaySnapshot._asDouble(raw['y']);
      final text = raw['text']?.toString() ?? '';
      if (dx == null || dy == null || text.isEmpty) continue;
      final colorInt = _DriveOverlaySnapshot._asInt(raw['color']) ??
          const Color(0xDDFAFF9A).toARGB32();
      final sizePx = _DriveOverlaySnapshot._asDouble(raw['size']) ?? 10.0;
      tp.text = TextSpan(
        text: text,
        style: TextStyle(
          color: Color(colorInt),
          fontSize: sizePx,
          fontWeight: FontWeight.w500,
        ),
      );
      tp.layout(maxWidth: 80.0);
      tp.paint(canvas, Offset(dx, dy));
    }
  }

  void _drawDebugScreenGrid(
    Canvas canvas, {
    required Size size,
  }) {
    final minorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = const Color(0x9955FF55);
    final majorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = const Color(0xEE00FF00);
    const cols = 10;
    const rows = 6;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      majorPaint,
    );
    for (var i = 1; i < cols; i++) {
      final x = (size.width * i) / cols;
      final isMajor =
          i == (cols ~/ 2) || i == (cols ~/ 4) || i == ((cols * 3) ~/ 4);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        isMajor ? majorPaint : minorPaint,
      );
    }
    for (var i = 1; i < rows; i++) {
      final y = (size.height * i) / rows;
      final isMajor = i == (rows ~/ 2);
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        isMajor ? majorPaint : minorPaint,
      );
    }
    _drawDebugGridLabels(
      canvas,
      size: size,
    );
  }

  List<List<Offset>> _buildWorldGridPolylines(_ProjectionTransform transform) {
    final polylines = <List<Offset>>[];
    final zBase = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
    const gridLat = <double>[-3.5, -1.75, 0.0, 1.75, 3.5];
    const gridDist = <double>[3.0, 5.0, 8.0, 12.0, 20.0, 30.0, 45.0, 60.0];

    for (final lat in gridLat) {
      final line = <Offset>[];
      for (final dist in gridDist) {
        Offset? p;
        final ok = _mapToScreen(transform, dist, lat, zBase, (pt) => p = pt);
        if (!ok || p == null) continue;
        line.add(p!);
      }
      if (line.length >= 2) polylines.add(line);
    }

    for (final dist in gridDist) {
      final line = <Offset>[];
      for (final lat in gridLat) {
        Offset? p;
        final ok = _mapToScreen(transform, dist, lat, zBase, (pt) => p = pt);
        if (!ok || p == null) continue;
        line.add(p!);
      }
      if (line.length >= 2) polylines.add(line);
    }
    return polylines;
  }

  void _appendDebugWorldGridPolygons(
    List<Map<String, dynamic>> out, {
    required _ProjectionTransform transform,
  }) {
    final gridLines = _buildWorldGridPolylines(transform);
    if (gridLines.isEmpty) return;
    const lineColor = Color(0x6674B9FF);
    for (final line in gridLines) {
      for (var i = 1; i < line.length; i++) {
        _appendDebugLinePolygon(
          out,
          a: line[i - 1],
          b: line[i],
          color: lineColor,
          thickness: 1.6,
        );
      }
    }
  }

  void _drawDebugWorldGrid(
    Canvas canvas, {
    required _ProjectionTransform transform,
  }) {
    final gridLines = _buildWorldGridPolylines(transform);
    if (gridLines.isEmpty) return;
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x6674B9FF);
    for (final line in gridLines) {
      if (line.length < 2) continue;
      final path = Path()..moveTo(line.first.dx, line.first.dy);
      for (var i = 1; i < line.length; i++) {
        path.lineTo(line[i].dx, line[i].dy);
      }
      canvas.drawPath(path, gridPaint);
    }
  }

  void _appendDebugGuidePolygons(
    List<Map<String, dynamic>> out, {
    required Size canvasSize,
    required _ProjectionTransform transform,
    required List<Offset>? trackVertices,
  }) {
    _appendDebugScreenGridPolygons(
      out,
      canvasSize: canvasSize,
    );
    final cx = canvasSize.width * 0.5;
    final cy = canvasSize.height * 0.5;
    const centerColor = Color(0x88FF4D4D);
    _appendDebugLinePolygon(
      out,
      a: Offset(cx, 0),
      b: Offset(cx, canvasSize.height),
      color: centerColor,
      thickness: 2.0,
    );
    _appendDebugLinePolygon(
      out,
      a: Offset(0, cy),
      b: Offset(canvasSize.width, cy),
      color: centerColor,
      thickness: 2.0,
    );
    _appendDebugWorldGridPolygons(
      out,
      transform: transform,
    );

    if (trackVertices == null || trackVertices.length < 3) return;
    final bounds = _verticesBounds(trackVertices);
    if (bounds == null) return;
    const boxColor = Color(0xCCFFD700);
    _appendDebugLinePolygon(
      out,
      a: bounds.topLeft,
      b: bounds.topRight,
      color: boxColor,
      thickness: 2.5,
    );
    _appendDebugLinePolygon(
      out,
      a: bounds.topRight,
      b: bounds.bottomRight,
      color: boxColor,
      thickness: 2.5,
    );
    _appendDebugLinePolygon(
      out,
      a: bounds.bottomRight,
      b: bounds.bottomLeft,
      color: boxColor,
      thickness: 2.5,
    );
    _appendDebugLinePolygon(
      out,
      a: bounds.bottomLeft,
      b: bounds.topLeft,
      color: boxColor,
      thickness: 2.5,
    );
  }

  void _drawDebugGuides(
    Canvas canvas, {
    required Size size,
    required _ProjectionTransform transform,
    required List<Offset>? trackVertices,
  }) {
    _drawDebugScreenGrid(
      canvas,
      size: size,
    );
    final centerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0x99FF4D4D);
    canvas.drawLine(
      Offset(size.width * 0.5, 0),
      Offset(size.width * 0.5, size.height),
      centerPaint,
    );
    canvas.drawLine(
      Offset(0, size.height * 0.5),
      Offset(size.width, size.height * 0.5),
      centerPaint,
    );
    _drawDebugWorldGrid(
      canvas,
      transform: transform,
    );

    if (trackVertices == null || trackVertices.length < 3) return;
    final bounds = _verticesBounds(trackVertices);
    if (bounds == null) return;
    final rectPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xCCFFD700);
    canvas.drawRect(bounds, rectPaint);
  }

  void _drawEncodedOverlayPayload(
    Canvas canvas,
    Size canvasSize,
    Map<String, dynamic> payload,
  ) {
    final polygonsRaw = payload['polygons'];
    if (polygonsRaw is List) {
      for (final item in polygonsRaw) {
        if (item is! Map) continue;
        final points = _decodeOverlayPoints(item['points']);
        if (points.length < 3) continue;
        final fillInt = _DriveOverlaySnapshot._asInt(item['fillColor']) ??
            const Color(0x00000000).toARGB32();
        final strokeInt = _DriveOverlaySnapshot._asInt(item['strokeColor']);
        final strokeWidth =
            (_DriveOverlaySnapshot._asDouble(item['strokeWidth']) ?? 0.0)
                .clamp(0.0, 20.0);
        final path = _pathFromVertices(points);
        final fillColor = Color(fillInt);
        final fillAlpha = (fillColor.a * 255.0).round().clamp(0, 255);
        if (fillAlpha > 0) {
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.fill
              ..color = fillColor,
          );
        }
        if (strokeInt != null && strokeWidth > 0.0) {
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..color = Color(strokeInt),
          );
        }
      }
    }

    final labelsRaw = payload['labels'];
    if (labelsRaw is! List || labelsRaw.isEmpty) return;
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    );
    for (final item in labelsRaw) {
      if (item is! Map) continue;
      final dx = _DriveOverlaySnapshot._asDouble(item['x']);
      final dy = _DriveOverlaySnapshot._asDouble(item['y']);
      final text = item['text']?.toString() ?? '';
      if (dx == null || dy == null || text.isEmpty) continue;
      final colorInt = _DriveOverlaySnapshot._asInt(item['color']) ??
          const Color(0xFFFFFFFF).toARGB32();
      final sizePx = (_DriveOverlaySnapshot._asDouble(item['size']) ?? 16.0)
          .clamp(8.0, 72.0);
      final centered = _boolFromDynamic(item['centered']);
      tp.text = TextSpan(
        text: text,
        style: TextStyle(
          color: Color(colorInt),
          fontSize: sizePx,
          fontWeight: FontWeight.w700,
        ),
      );
      final labelMaxWidth = (canvasSize.width * 0.42).clamp(140.0, 760.0);
      tp.layout(maxWidth: labelMaxWidth.toDouble());
      final paintOffset = centered
          ? Offset(dx - (tp.width * 0.5), dy - (tp.height * 0.5))
          : Offset(dx, dy - tp.height);
      tp.paint(canvas, paintOffset);
    }
  }

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final sidecarPayload = _buildNativeOverlayPayloadFromSidecar2d(size);
    if (sidecarPayload != null) {
      _drawEncodedOverlayPayload(canvas, size, sidecarPayload);
      return;
    }
    if (snapshot.path.length < 2) return;
    final transform = _buildTransform(size);
    final modelMax = snapshot.path.x.isNotEmpty ? snapshot.path.x.last : 0.0;
    final maxDistance = modelMax.clamp(10.0, 100.0);
    final laneBaseX = snapshot.laneLines.isNotEmpty
        ? snapshot.laneLines.first.line.x
        : snapshot.path.x;
    final laneMaxIdx = laneBaseX.isNotEmpty
        ? _getPathLengthIdx(laneBaseX, maxDistance)
        : _getPathLengthIdx(snapshot.path.x, maxDistance);

    if (showLaneLines) {
      final laneFill = Paint()..style = PaintingStyle.fill;
      for (var i = 0; i < snapshot.laneLines.length; i++) {
        final ln = snapshot.laneLines[i];
        var lineWidth = 0.025;
        if (i == 1 && snapshot.leftLaneLine >= 20) {
          lineWidth = 0.05;
        }
        final poly = _mapLineToPolygon(
          transform,
          ln.line,
          lineWidth,
          0.0,
          laneMaxIdx,
        );
        if (poly == null) continue;
        final alpha = ln.probability > 0.3 ? (220.0 / 255.0) : 0.0;
        if (alpha <= 0.0) continue;
        Color laneColor = Colors.white;
        if (i == 1 && snapshot.leftLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        } else if (i == 2 && snapshot.rightLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        }
        laneFill.color = laneColor.withValues(alpha: alpha);
        canvas.drawPath(poly, laneFill);
        if (i == 1 && (snapshot.leftLaneLine % 10) == 4) {
          final doublePoly = _mapLineToPolygon(
            transform,
            ln.line,
            lineWidth,
            0.0,
            laneMaxIdx,
            lineCenterShift: -0.3,
          );
          if (doublePoly != null) {
            canvas.drawPath(doublePoly, laneFill);
          }
        }
      }
    }

    if (showRoadEdge) {
      final edgeFill = Paint()..style = PaintingStyle.fill;
      for (final edge in snapshot.roadEdges) {
        final poly = _mapLineToPolygon(
          transform,
          edge.line,
          0.025,
          0.0,
          laneMaxIdx,
        );
        if (poly == null) continue;
        edgeFill.color = _roadEdgeColor(edge.std);
        canvas.drawPath(poly, edgeFill);
      }
    }

    final pathMode = snapshot.pathMode;
    final widthApply = _pathHalfWidthByMode(pathMode, snapshot.pathWidthRatio);
    final zOff = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
    final startDistance = snapshot.active ? 2.0 : 3.5;
    final trackVertices = _mapLineToTrackVerticesDist(
      transform,
      snapshot.path,
      widthApply,
      zOff,
      zOff,
      maxDistance,
      startDistance: startDistance,
      allowInvert: false,
    );
    if (showPathFill && trackVertices != null) {
      _drawPathByMode(canvas, trackVertices);
    }
    final navPolygons = <Map<String, dynamic>>[];
    final navLabels = <Map<String, dynamic>>[];
    _appendNavArOverlayPolygons(
      polygons: navPolygons,
      labels: navLabels,
      transform: transform,
      canvasSize: size,
    );
    if (navPolygons.isNotEmpty || navLabels.isNotEmpty) {
      _drawEncodedOverlayPayload(
        canvas,
        size,
        <String, dynamic>{
          'polygons': navPolygons,
          if (navLabels.isNotEmpty) 'labels': navLabels,
        },
      );
    }
    if (showDebugGuides) {
      _drawDebugGuides(
        canvas,
        size: size,
        transform: transform,
        trackVertices: trackVertices,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DriveOverlayPainter oldDelegate) {
    return oldDelegate.snapshot != snapshot ||
        oldDelegate.isConnected != isConnected ||
        oldDelegate.sourceSize != sourceSize ||
        oldDelegate.cameraKind != cameraKind ||
        oldDelegate.coverViewport != coverViewport ||
        oldDelegate.showDebugGuides != showDebugGuides ||
        oldDelegate.showPathFill != showPathFill ||
        oldDelegate.showLaneLines != showLaneLines ||
        oldDelegate.showRoadEdge != showRoadEdge ||
        oldDelegate.showLead1 != showLead1 ||
        oldDelegate.showLead2 != showLead2 ||
        oldDelegate.showRadarBadge != showRadarBadge ||
        oldDelegate.showRadarVector != showRadarVector ||
        oldDelegate.showStopDistanceTf != showStopDistanceTf ||
        oldDelegate.showStateText != showStateText;
  }
}

class _ProjectionTransform {
  final _M3 carSpaceTransform;
  final Rect clip;
  final double sourceScale;
  final double xOffset;
  final double yOffset;

  const _ProjectionTransform({
    required this.carSpaceTransform,
    required this.clip,
    required this.sourceScale,
    required this.xOffset,
    required this.yOffset,
  });
}

class _DriveVideoPlacement {
  final double left;
  final double top;
  final double width;
  final double height;
  final double scale;
  final double xOffset;
  final double yOffset;

  const _DriveVideoPlacement({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.scale,
    required this.xOffset,
    required this.yOffset,
  });
}

class _SourceCanvasPlacement {
  final _M3 transform;
  final double scale;
  final double xOffset;
  final double yOffset;

  const _SourceCanvasPlacement({
    required this.transform,
    required this.scale,
    required this.xOffset,
    required this.yOffset,
  });
}

class _V3 {
  final double x;
  final double y;
  final double z;

  const _V3(this.x, this.y, this.z);
}

class _M3 {
  final double m00;
  final double m01;
  final double m02;
  final double m10;
  final double m11;
  final double m12;
  final double m20;
  final double m21;
  final double m22;

  const _M3(
    this.m00,
    this.m01,
    this.m02,
    this.m10,
    this.m11,
    this.m12,
    this.m20,
    this.m21,
    this.m22,
  );

  const _M3.identity()
      : m00 = 1.0,
        m01 = 0.0,
        m02 = 0.0,
        m10 = 0.0,
        m11 = 1.0,
        m12 = 0.0,
        m20 = 0.0,
        m21 = 0.0,
        m22 = 1.0;

  _M3 multiply(_M3 o) {
    return _M3(
      m00 * o.m00 + m01 * o.m10 + m02 * o.m20,
      m00 * o.m01 + m01 * o.m11 + m02 * o.m21,
      m00 * o.m02 + m01 * o.m12 + m02 * o.m22,
      m10 * o.m00 + m11 * o.m10 + m12 * o.m20,
      m10 * o.m01 + m11 * o.m11 + m12 * o.m21,
      m10 * o.m02 + m11 * o.m12 + m12 * o.m22,
      m20 * o.m00 + m21 * o.m10 + m22 * o.m20,
      m20 * o.m01 + m21 * o.m11 + m22 * o.m21,
      m20 * o.m02 + m21 * o.m12 + m22 * o.m22,
    );
  }

  _V3 transform(_V3 v) {
    return _V3(
      m00 * v.x + m01 * v.y + m02 * v.z,
      m10 * v.x + m11 * v.y + m12 * v.z,
      m20 * v.x + m21 * v.y + m22 * v.z,
    );
  }
}

@pragma('vm:entry-point')
Future<void> _driveSidecarWorkerMain(Map<String, dynamic> config) async {
  final wsUrl = (config['wsUrl']?.toString() ?? '').trim();
  final sendPort = config['sendPort'] as SendPort?;
  if (wsUrl.isEmpty || sendPort == null) return;
  while (true) {
    WebSocket? socket;
    try {
      socket = await WebSocket.connect(wsUrl).timeout(
        const Duration(seconds: 4),
      );
      sendPort.send(<String, dynamic>{'type': 'connected', 'connected': true});
      await for (final event in socket) {
        Map<String, dynamic>? payload;
        if (event is String) {
          try {
            final decoded = jsonDecode(event);
            if (decoded is Map<String, dynamic>) {
              payload = decoded;
            } else if (decoded is Map) {
              payload = Map<String, dynamic>.from(decoded);
            }
          } catch (_) {
            payload = null;
          }
        } else if (event is List<int>) {
          List<int> bytes = event;
          try {
            bytes = zlib.decode(bytes);
          } catch (_) {
            // server may still send plain UTF-8 payloads.
          }
          try {
            final decoded = jsonDecode(utf8.decode(bytes));
            if (decoded is Map<String, dynamic>) {
              payload = decoded;
            } else if (decoded is Map) {
              payload = Map<String, dynamic>.from(decoded);
            }
          } catch (_) {
            payload = null;
          }
        }
        if (payload == null) continue;
        sendPort.send(<String, dynamic>{
          'type': 'frame',
          'payload': payload,
        });
      }
    } catch (_) {
      // reconnect loop
    } finally {
      sendPort.send(<String, dynamic>{'type': 'connected', 'connected': false});
      try {
        await socket?.close();
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }
}
