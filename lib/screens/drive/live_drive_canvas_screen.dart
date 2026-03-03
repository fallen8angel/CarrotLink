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
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/hud_drive_settings_service.dart';
import '../../services/sidecar_service.dart';
import '../../services/ssh_service.dart';
import '../../widgets/custom_toast.dart';

enum _DriveCameraKind { road, wideRoad }

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
  static const bool _temporaryLimitedHudControls = true;
  static const String _defaultSidecarProfile = 'p2';

  late final WebViewController _cameraController;
  final SidecarService _sidecarService = SidecarService();
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
  bool _replayBusy = false;
  bool _replayActive = false;
  bool _sidecarBusy = false;
  String? _replayRoute;
  int? _replaySegment;
  String? _replayError;
  _DriveCameraKind _liveCameraKind = _DriveCameraKind.road;
  bool _wideCamRequested = false;
  int _overlayDiagFrames = 0;
  DateTime _overlayDiagLastLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<int, _DriveOverlaySnapshot> _overlayByModelFrame =
      <int, _DriveOverlaySnapshot>{};
  final ListQueue<int> _overlayFrameOrder = ListQueue<int>();
  static const int _overlayFrameBufferSize = 220;
  static const int _overlaySyncMaxDeltaLive = 8;
  static const int _overlaySyncMaxDeltaReplay = 10;
  static const bool _strictFrameLock = true;
  static const int _strictFrameHoldUs = 120000;
  static const int _cameraFrameStaleUs = 350000;
  static const int _interpMinUs = 12000;
  static const int _interpMaxUs = 90000;
  bool _cameraSuspendedByLifecycle = false;
  bool _replayFrameClockReady = false;
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
  int _lastProfileEnforceUs = 0;
  static const int _profileEnforceIntervalUs = 3000000;
  int _lastCameraFallbackLogUs = 0;
  List<double> _lastValidCalibrationRpy = const <double>[];
  List<double> _lastValidWideFromDeviceEuler = const <double>[];
  double _lastValidPathOffsetZ = 1.22;
  String _hudDefaultMode = HudDriveSettingsService.modeWebrtc;
  String _hudSidecarProfile = _defaultSidecarProfile;

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
      'ws://${widget.hostIp}:7766/ws/live?encoding=zlib-json';

  bool get _openpilotOverlayMode =>
      HudDriveSettingsService.isOpenpilotOverlay(_hudDefaultMode);

  bool get _canUseNativeCamera => !kIsWeb && Platform.isAndroid;

  bool get _useNativeLiveCamera =>
      _canUseNativeCamera && !_replayActive && !_nativeCameraUnsupported;

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
    if (!_replayActive && kind != _liveCameraKind) {
      return;
    }
    _cameraSourceSize = next;
  }

  String get _liveCameraWsUrl =>
      'ws://${widget.hostIp}:7766/ws/camera/$_liveCameraName';

  bool get _coverViewport => true;

  int get _overlaySyncMaxDeltaCurrent =>
      _replayActive ? _overlaySyncMaxDeltaReplay : _overlaySyncMaxDeltaLive;

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
            setState(() => _cameraLoading = false);
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
    unawaited(_loadCameraSource(force: true));
    unawaited(_lockLandscapeOrientations());
    unawaited(_loadHudDefaultMode());
    unawaited(_refreshReplayStatus());
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
      _lastValidCalibrationRpy = const <double>[];
      _lastValidWideFromDeviceEuler = const <double>[];
      _lastValidPathOffsetZ = 1.22;
      unawaited(_loadCameraSource(force: true));
      _applyHudModeRuntime();
      unawaited(_refreshReplayStatus());
    }
  }

  Future<void> _loadHudDefaultMode() async {
    final mode = await HudDriveSettingsService.getDefaultMode();
    if (!mounted) return;
    setState(() {
      _hudDefaultMode = mode;
    });
    _applyHudModeRuntime();
  }

  void _applyHudModeRuntime() {
    if (_openpilotOverlayMode) {
      _startSidecarLoop();
      unawaited(_ensureDriveProfile());
      return;
    }
    _stopSidecarLoop();
    _applyOverlaySnapshot(
      const _DriveOverlaySnapshot.empty(),
      forceNativePush: true,
    );
    unawaited(_clearNativeOverlay());
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
        setState(() => _cameraLoading = false);
      }
      return;
    }
    if (type == 'camera_error') {
      final reason = map['reason']?.toString().trim() ?? '';
      if (reason.isEmpty) return;
      debugPrint('[DriveCanvas][native] error=$reason');
      if (!mounted) return;
      setState(() {
        _cameraError = '네이티브 디코더 오류: $reason';
        if (reason.contains('invalid_ws_url') ||
            reason.contains('decoder_init_failed')) {
          _nativeCameraUnsupported = true;
        }
      });
      if (_nativeCameraUnsupported) {
        unawaited(_loadCameraSource(force: true));
      }
    }
  }

  void _toggleOverlayVerifyMode() {
    if (!mounted) return;
    setState(() {
      _overlayVerifyMode = !_overlayVerifyMode;
      if (!_overlayVerifyMode) {
        _overlayVerifyText = '';
      }
    });
    _toast(_overlayVerifyMode ? '정합 검증 ON' : '정합 검증 OFF');
    if (_overlayVerifyMode) {
      _refreshOverlayVerify(_overlayNotifier.value, force: true);
    }
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
        if (_replayActive) {
          _replayFrameClockReady = true;
        }
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
      setState(() => _updateSourceSize(next, kind: eventCameraKind));
      return;
    }
    if (type == 'camera_error') {
      final reason = map['reason']?.toString().trim() ?? '';
      if (reason.isEmpty || !mounted) return;
      debugPrint('[DriveCanvas] camera_error reason=$reason');
      setState(() => _cameraError = '카메라 디코더 오류: $reason');
      return;
    }
    if (type == 'camera_timeline_ready') {
      if (_replayActive) {
        _replayFrameClockReady = true;
      }
      return;
    }
  }

  Future<void> _restorePortraitOrientation() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }

  Future<void> _lockLandscapeOrientations() async {
    await SystemChrome.setPreferredOrientations(const [
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
    _renderTicker?.dispose();
    _renderTicker = null;
    unawaited(_clearNativeOverlay());
    _stopSidecarLoop();
    final nativeSub = _nativeCameraEventSub;
    _nativeCameraEventSub = null;
    if (nativeSub != null) {
      unawaited(nativeSub.cancel());
    }
    _overlayNotifier.dispose();
    unawaited(_restorePortraitOrientation());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _resumeFromBackground();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _suspendForBackground();
        break;
    }
  }

  Uri _replayVideoUri(String route, int segment) {
    final segmentId = Uri.encodeComponent('$route--$segment');
    return Uri.parse(
      'http://${widget.hostIp}:8082/footage/qcamera/$segmentId',
    );
  }

  Uri _replayCameraTimelineUri(String route, int segment) {
    return _sidecarHttpUri(
      '/replay/camera_timeline',
      <String, String>{
        'route': route,
        'segment': '$segment',
      },
    );
  }

  String _buildLiveCameraHtml(_DriveCameraKind cameraKind) {
    final streamEndpoints = jsonEncode(
      _streamEndpointCandidates.map((u) => u.toString()).toList(),
    );
    final cameraName =
        cameraKind == _DriveCameraKind.wideRoad ? 'wideRoad' : 'road';
    final directWsUrl = 'ws://${widget.hostIp}:7766/ws/camera/$cameraName';
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

    const canvas = document.getElementById('c');
    const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
    const video = document.getElementById('v');

    let ws = null;
    let pc = null;
    let decoder = null;
    let decoderCodec = '';
    let waitingKey = true;
    let gotFrame = false;
    let watchdog = null;
    let reconnectTimer = null;
    let directProbeTimer = null;
    let mode = 'direct';
    let directErrorCount = 0;
    let webCodecsUnsupported = false;
    let lastDirectFrameId = -1;
    let droppedOutdated = 0;
    let droppedQueue = 0;
    let sourceW = 0;
    let sourceH = 0;
    let lastCameraFramePosted = -1;
    const pendingFrameIds = [];

    function resizeCanvas() {
      const w = Math.max(1, window.innerWidth || 1);
      const h = Math.max(1, window.innerHeight || 1);
      if (canvas.width !== w) canvas.width = w;
      if (canvas.height !== h) canvas.height = h;
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
      clearDirectProbe();
      if (webCodecsUnsupported) return;
      directProbeTimer = setTimeout(() => {
        directProbeTimer = null;
        if (mode === 'webrtc') {
          connectDirect().catch(() => {});
        }
      }, ms || 8000);
    }

    function scheduleReconnect(ms) {
      clearReconnect();
      reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        if (mode === 'direct') {
          connectDirect().catch(() => {});
        } else {
          connectWebRtc().catch(() => {});
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
      clearWatchdog();
      watchdog = setTimeout(() => {
        if (!gotFrame && mode === 'direct') {
          postToFlutter(payloadWithCamera({ type: 'camera_error', reason: 'no_frames' }));
          fallbackToWebRtc('no_frames');
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
      cleanupPc();
      cleanupSocket();
      closeDecoder();
      gotFrame = false;
      directErrorCount = 0;
      setMode('direct');

      if (!window.VideoDecoder || !window.EncodedVideoChunk) {
        webCodecsUnsupported = true;
        fallbackToWebRtc('webcodecs_unsupported');
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
            fallbackToWebRtc('decoder_unsupported');
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
          fallbackToWebRtc('socket_error');
        };
        ws.onclose = () => {
          if (mode === 'direct') {
            scheduleReconnect(gotFrame ? 700 : 1000);
          }
        };
      } catch (_) {
        fallbackToWebRtc('socket_open_failed');
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
      if (mode === 'direct') {
        connectDirect().catch(() => {});
      } else {
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
    connectWebRtc().catch(() => scheduleReconnect(1200));
  </script>
</body>
</html>
''';
  }

  String _buildReplayCameraHtml(Uri videoUri, Uri timelineUri) {
    final src = jsonEncode(videoUri.toString());
    final timelineSrc = jsonEncode(timelineUri.toString());
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
    #v {
      width: 100vw;
      height: 100vh;
      object-fit: cover;
      display: block;
      background: #000;
    }
  </style>
</head>
<body>
  <video id="v" autoplay playsinline muted></video>
  <script>
    const src = $src;
    const timelineSrc = $timelineSrc;
    const v = document.getElementById('v');
    let activeCamera = 'road';
    let syncRaf = null;
    let timelineTimes = [];
    let timelineFrameIds = [];
    let timelineDurationSec = 0;
    let lastPublishedFrame = -1;
    function postToFlutter(payload) {
      try {
        if (window.CarrotCamera && typeof window.CarrotCamera.postMessage === 'function') {
          window.CarrotCamera.postMessage(JSON.stringify(payload));
        }
      } catch (_) {}
    }
    function payloadWithCamera(payload) {
      if (!payload || typeof payload !== 'object') return payload;
      return Object.assign({ camera: activeCamera }, payload);
    }
    function publishFrame(frameId) {
      if (!Number.isFinite(frameId) || frameId < 0) return;
      if (frameId === lastPublishedFrame) return;
      lastPublishedFrame = frameId;
      postToFlutter(payloadWithCamera({ type: 'camera_frame', frameId: frameId }));
    }
    function publishMeta() {
      const w = Number(v.videoWidth || 0);
      const h = Number(v.videoHeight || 0);
      if (w > 0 && h > 0) {
        postToFlutter(payloadWithCamera({ type: 'camera_meta', width: w, height: h }));
      }
    }
    function frameIdForTime(sec) {
      if (!timelineFrameIds.length || !timelineTimes.length) return null;
      let t = Number(sec || 0);
      if (!Number.isFinite(t) || t < 0) t = 0;
      if (timelineDurationSec > 0) {
        t = t % timelineDurationSec;
      }
      let lo = 0;
      let hi = timelineTimes.length - 1;
      while (lo < hi) {
        const mid = Math.floor((lo + hi + 1) / 2);
        if (timelineTimes[mid] <= t) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      const idx = Math.max(0, Math.min(lo, timelineFrameIds.length - 1));
      return Number(timelineFrameIds[idx]);
    }
    function stopSyncLoop() {
      if (syncRaf !== null) {
        cancelAnimationFrame(syncRaf);
        syncRaf = null;
      }
    }
    function syncTick() {
      const frameId = frameIdForTime(v.currentTime);
      if (frameId !== null) {
        publishFrame(frameId);
      }
      syncRaf = requestAnimationFrame(syncTick);
    }
    function startSyncLoop() {
      stopSyncLoop();
      syncRaf = requestAnimationFrame(syncTick);
    }
    async function loadTimeline() {
      try {
        const res = await fetch(timelineSrc, { method: 'GET' });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const body = await res.json();
        const streams = body && body.streams ? body.streams : {};
        const preferred = String(body && body.preferredCamera ? body.preferredCamera : 'road');
        activeCamera = preferred === 'wideRoad' ? 'wideRoad' : 'road';
        const primary = streams[preferred] || streams.road || streams.wideRoad || null;
        if (!primary) throw new Error('no stream');
        const times = Array.isArray(primary.tSec) ? primary.tSec : [];
        const ids = Array.isArray(primary.frameIds) ? primary.frameIds : [];
        const n = Math.min(times.length, ids.length);
        timelineTimes = [];
        timelineFrameIds = [];
        for (let i = 0; i < n; i++) {
          const t = Number(times[i]);
          const id = Number(ids[i]);
          if (!Number.isFinite(t) || !Number.isFinite(id)) continue;
          if (id < 0) continue;
          if (timelineTimes.length && t < timelineTimes[timelineTimes.length - 1]) continue;
          timelineTimes.push(t);
          timelineFrameIds.push(Math.floor(id));
        }
        timelineDurationSec = timelineTimes.length ? timelineTimes[timelineTimes.length - 1] : 0;
        postToFlutter(
          payloadWithCamera({
            type: 'camera_timeline_ready',
            frames: timelineFrameIds.length,
          }),
        );
      } catch (e) {
        timelineTimes = [];
        timelineFrameIds = [];
        timelineDurationSec = 0;
        postToFlutter(
          payloadWithCamera({
            type: 'camera_error',
            reason: 'replay_timeline:' + String(e && e.message ? e.message : e),
          }),
        );
      }
    }
    v.src = src;
    v.loop = true;
    v.controls = false;
    v.addEventListener('loadedmetadata', publishMeta);
    v.addEventListener('canplay', async () => {
      publishMeta();
      try { await v.play(); } catch (_) {}
      startSyncLoop();
    });
    v.addEventListener('play', startSyncLoop);
    v.addEventListener('pause', stopSyncLoop);
    document.addEventListener('visibilitychange', async () => {
      if (!document.hidden) {
        publishMeta();
        try { await v.play(); } catch (_) {}
        startSyncLoop();
      }
    });
    window.addEventListener('beforeunload', stopSyncLoop);
    loadTimeline().then(() => {
      const frameId = frameIdForTime(0);
      if (frameId !== null) publishFrame(frameId);
    });
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
    final hasReplayTarget =
        _replayActive && _replayRoute != null && _replaySegment != null;
    if (!hasReplayTarget && _useNativeLiveCamera) {
      if (mounted) {
        setState(() {
          _cameraLoading = true;
          _cameraError = null;
        });
      }
      _cameraSourceKey = 'native-live:${widget.hostIp}:$_liveCameraName';
      return;
    }
    final key = hasReplayTarget
        ? 'replay:${widget.hostIp}:${_replayRoute!}:${_replaySegment!}'
        : 'live:${widget.hostIp}:$_liveCameraName';
    if (!force && _cameraSourceKey == key) return;
    _cameraSourceKey = key;

    if (mounted) {
      setState(() {
        _cameraLoading = true;
        _cameraError = null;
      });
    }

    try {
      if (hasReplayTarget) {
        final replayUri = _replayVideoUri(_replayRoute!, _replaySegment!);
        final timelineUri =
            _replayCameraTimelineUri(_replayRoute!, _replaySegment!);
        debugPrint(
          '[DriveCanvas] source=replay url=$replayUri timeline=$timelineUri',
        );
        await _cameraController.loadHtmlString(
          _buildReplayCameraHtml(replayUri, timelineUri),
          baseUrl: _cameraBaseUri.toString(),
        );
      } else {
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
      }
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
    if (_replayActive) return;
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
    if (!_cameraSuspendedByLifecycle) {
      unawaited(_loadCameraSource(force: true));
    }
  }

  void _suspendForBackground() {
    if (_cameraSuspendedByLifecycle) return;
    debugPrint('[DriveCanvas][lifecycle] suspend');
    _cameraSuspendedByLifecycle = true;
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
    _lastCameraFrameEventUs = 0;
    unawaited(_unloadWebCameraSurface());
    if (mounted) {
      setState(() {
        _nativeCameraViewId = null;
        _cameraLoading = false;
        _cameraError = null;
      });
    }
  }

  void _resumeFromBackground() {
    if (!_cameraSuspendedByLifecycle) return;
    debugPrint('[DriveCanvas][lifecycle] resume');
    _cameraSuspendedByLifecycle = false;
    unawaited(_lockLandscapeOrientations());
    _startSidecarLoop();
    unawaited(_ensureDriveProfile());
    unawaited(_loadCameraSource(force: true));
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
    if (_replayActive) {
      return snapshot.roadFrameId ?? snapshot.wideRoadFrameId;
    }
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
    if (!_overlayVerifyMode || !mounted) return;
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
      cameraKind: _replayActive ? _DriveCameraKind.road : _liveCameraKind,
      canvasSize: canvasSize,
      coverViewport: _coverViewport,
      cameraSourceLabel: _replayActive ? 'replay' : 'live',
      replayActive: _replayActive,
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
      showDebugGuides: _overlayVerifyMode,
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
    if (!_replayActive &&
        _lastPublishedModelFrameId != null &&
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
    if (!_replayActive && cameraKind != null && cameraKind != _liveCameraKind) {
      // Drop stale frame events from a camera stream that is no longer active.
      return;
    }
    _lastCameraFrameId = frameId;
    _lastCameraFrameEventUs = _renderClock.elapsedMicroseconds;
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
    }
  }

  void _handleSidecarWorkerEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);
    final type = map['type']?.toString() ?? '';
    if (type == 'connected') {
      final next = map['connected'] == true;
      if (next != _sidecarConnected) {
        if (mounted) {
          setState(() => _sidecarConnected = next);
        } else {
          _sidecarConnected = next;
        }
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

    // Keep using last valid calibration when live calibration is temporarily unavailable.
    if (snapshot.calibrationRpy.length >= 3) {
      _lastValidCalibrationRpy =
          snapshot.calibrationRpy.take(3).toList(growable: false);
    } else if (_lastValidCalibrationRpy.length >= 3) {
      next = next.copyWith(calibrationRpy: _lastValidCalibrationRpy);
    }

    if (snapshot.wideFromDeviceEuler.length >= 3) {
      _lastValidWideFromDeviceEuler =
          snapshot.wideFromDeviceEuler.take(3).toList(growable: false);
    } else if (_lastValidWideFromDeviceEuler.length >= 3) {
      next = next.copyWith(
        wideFromDeviceEuler: _lastValidWideFromDeviceEuler,
      );
    }

    final z = snapshot.pathOffsetZ;
    if (z.isFinite && z > 0.3 && z < 4.0) {
      _lastValidPathOffsetZ = z;
    } else {
      next = next.copyWith(pathOffsetZ: _lastValidPathOffsetZ);
    }

    // Enforce classic visual style (no blue 3-strip mode).
    var mode = next.pathMode;
    var color = next.pathColor;
    if (mode >= 13 && mode <= 15) mode = 0;
    if (color == 14 || color == 19) color = 3;
    if (mode != next.pathMode || color != next.pathColor) {
      next = next.copyWith(pathMode: mode, pathColor: color);
    }

    return next;
  }

  void _handleSidecarPayload(Map<String, dynamic> payload) {
    if (payload['type'] == 'hello') return;
    if (!_openpilotOverlayMode) return;
    final profile = payload['profile']?.toString().trim().toLowerCase();
    if (profile != null && profile.isNotEmpty && profile != 'p2') {
      final nowUs = _renderClock.elapsedMicroseconds;
      if ((nowUs - _lastProfileEnforceUs) >= _profileEnforceIntervalUs) {
        _lastProfileEnforceUs = nowUs;
        debugPrint('[DriveCanvas][profile] enforce p2 (current=$profile)');
        unawaited(_ensureDriveProfile());
      }
    }

    final next = _stabilizeOverlaySnapshot(
      _DriveOverlaySnapshot.fromSidecar(payload),
    );
    _syncLiveCameraKind(next);
    _cacheOverlaySnapshot(next);
    _overlayDiagFrames++;
    final now = DateTime.now();
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
    if (_replayActive && !_replayFrameClockReady) {
      if (inferredCameraFrame != null) {
        _lastCameraFrameId = inferredCameraFrame;
      }
    } else {
      final nowUs = _renderClock.elapsedMicroseconds;
      final cameraStale = _lastCameraFrameEventUs <= 0 ||
          (nowUs - _lastCameraFrameEventUs) > _cameraFrameStaleUs;
      if (inferredCameraFrame != null &&
          (_lastCameraFrameId == null || cameraStale)) {
        _lastCameraFrameId = inferredCameraFrame;
        if (cameraStale &&
            !_replayActive &&
            (nowUs - _lastCameraFallbackLogUs) >= 2000000) {
          _lastCameraFallbackLogUs = nowUs;
          debugPrint(
            '[DriveCanvas][sync] fallback cameraFrame=$inferredCameraFrame via sidecar (native frame event stale)',
          );
        }
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
    String path,
    Map<String, dynamic> body,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.postUrl(_sidecarHttpUri(path)).timeout(
            const Duration(seconds: 4),
          );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
      final response =
          await request.close().timeout(const Duration(seconds: 6));
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

  Future<void> _ensureDriveProfile() async {
    try {
      final resp = await _sidecarPostJson(
        '/profile',
        const <String, dynamic>{'profile': 'p2'},
      );
      final current = resp['profile']?.toString() ?? '?';
      debugPrint('[DriveCanvas][profile] requested=p2 result=$current');
    } catch (e) {
      debugPrint('[DriveCanvas][profile] enforce failed: $e');
      // Sidecar may be unavailable during startup; ignore.
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _runSidecarTask({
    required String title,
    required Future<String> Function(SSHService ssh) task,
  }) async {
    if (_sidecarBusy) return;
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, '기기와 연결되어 있지 않습니다.', isError: true);
      return;
    }

    if (mounted) {
      setState(() => _sidecarBusy = true);
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    String? output;
    Object? error;
    try {
      output = await task(ssh);
    } catch (e) {
      error = e;
    } finally {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) {
        setState(() => _sidecarBusy = false);
      }
    }

    if (!mounted) return;
    if (error != null) {
      CustomToast.show(context, '$title 실패: $error', isError: true);
      return;
    }
    CustomToast.show(context, '$title 완료');
    final text = (output ?? '').trim();
    if (text.isEmpty) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SelectableText(text),
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

  void _openSidecarActionPopup() {
    if (!_openpilotOverlayMode) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        var selectedProfile = _hudSidecarProfile;
        final titleStyle = Theme.of(sheetContext).textTheme.titleSmall;
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return SafeArea(
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.hub_outlined,
                              color: Theme.of(sheetContext).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '사이드카 제어',
                              style: titleStyle,
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: <String>[
                              'p0',
                              'p1',
                              'p2',
                              'p3',
                              'p4',
                            ].map((profile) {
                              final selected = selectedProfile == profile;
                              return ChoiceChip(
                                label: Text(profile.toUpperCase()),
                                selected: selected,
                                onSelected: _sidecarBusy
                                    ? null
                                    : (_) {
                                        setLocalState(
                                          () => selectedProfile = profile,
                                        );
                                        setState(
                                          () => _hudSidecarProfile = profile,
                                        );
                                      },
                              );
                            }).toList(growable: false),
                          ),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.publish),
                        title: const Text('배포/업데이트'),
                        onTap: _sidecarBusy
                            ? null
                            : () {
                                Navigator.of(sheetContext).pop();
                                unawaited(
                                  _runSidecarTask(
                                    title: '사이드카 배포',
                                    task: (ssh) => _sidecarService.deploy(ssh),
                                  ),
                                );
                              },
                      ),
                      ListTile(
                        leading: const Icon(Icons.play_circle_outline),
                        title: Text('시작 (${selectedProfile.toUpperCase()})'),
                        onTap: _sidecarBusy
                            ? null
                            : () {
                                final profileToStart = selectedProfile;
                                Navigator.of(sheetContext).pop();
                                unawaited(
                                  _runSidecarTask(
                                    title: '사이드카 시작',
                                    task: (ssh) => _sidecarService.start(
                                      ssh,
                                      profile: profileToStart,
                                    ),
                                  ).then((_) {
                                    _startSidecarLoop();
                                    if (_openpilotOverlayMode) {
                                      unawaited(_ensureDriveProfile());
                                    }
                                  }),
                                );
                              },
                      ),
                      ListTile(
                        leading: const Icon(Icons.stop_circle_outlined),
                        title: const Text(
                          '중지',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                        onTap: _sidecarBusy
                            ? null
                            : () {
                                Navigator.of(sheetContext).pop();
                                unawaited(
                                  _runSidecarTask(
                                    title: '사이드카 중지',
                                    task: (ssh) => _sidecarService.stop(ssh),
                                  ).then((_) => _stopSidecarLoop()),
                                );
                              },
                      ),
                      ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: const Text('상태 확인'),
                        onTap: _sidecarBusy
                            ? null
                            : () {
                                Navigator.of(sheetContext).pop();
                                unawaited(
                                  _runSidecarTask(
                                    title: '사이드카 상태',
                                    task: (ssh) => _sidecarService.status(ssh),
                                  ),
                                );
                              },
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _refreshReplayStatus() async {
    try {
      final response = await _sidecarGetJson('/replay/status');
      if (!mounted) return;
      final wasReplayActive = _replayActive;
      final active = response['active'] == true;
      final route = (response['route']?.toString().trim().isNotEmpty ?? false)
          ? response['route'].toString()
          : null;
      final segment = response['segment'] is num
          ? (response['segment'] as num).toInt()
          : int.tryParse(response['segment']?.toString() ?? '');
      final err = response['error']?.toString().trim() ?? '';
      setState(() {
        _replayActive = active;
        _replayRoute = route;
        _replaySegment = segment;
        _replayError = err.isEmpty ? null : err;
        _cameraSourceSize = active
            ? _sourceSizeForKind(_DriveCameraKind.road)
            : _sourceSizeForKind(_liveCameraKind);
      });
      if (wasReplayActive != active) {
        _replayFrameClockReady = false;
        _lastCameraFrameId = null;
        _lastCameraFrameEventUs = 0;
        _lastPublishedModelFrameId = null;
        _latestOverlaySnapshot = const _DriveOverlaySnapshot.empty();
        _overlayByModelFrame.clear();
        _overlayFrameOrder.clear();
        _pathAnimationPhase = 0.0;
        _pathAnimationSeq2 = -1;
        _pathAnimationForward = true;
        _lastPathAnimationTickUs = 0;
        _applyOverlaySnapshot(
          const _DriveOverlaySnapshot.empty(),
          forceNativePush: true,
        );
        unawaited(_clearNativeOverlay());
      }
      await _loadCameraSource();
    } catch (_) {
      // No-op: sidecar may be unavailable before deploy/start.
    }
  }

  Future<List<_ReplayRouteEntry>> _fetchReplayRoutes() async {
    final response = await _sidecarGetJson(
      '/replay/routes',
      query: const <String, String>{'limit': '300'},
    );
    final rawRoutes = response['routes'];
    if (rawRoutes is! List) return const <_ReplayRouteEntry>[];
    final routes = <_ReplayRouteEntry>[];
    for (final raw in rawRoutes) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final route = map['route']?.toString().trim() ?? '';
      if (route.isEmpty) continue;
      final segments = <int>[];
      final segRaw = map['segments'];
      if (segRaw is List) {
        for (final v in segRaw) {
          if (v is num) {
            segments.add(v.toInt());
          } else {
            final n = int.tryParse(v.toString());
            if (n != null) segments.add(n);
          }
        }
      }
      segments.sort();
      if (segments.isEmpty) continue;
      routes.add(_ReplayRouteEntry(route: route, segments: segments));
    }
    return routes;
  }

  Future<void> _startReplay({
    required String route,
    required int segment,
  }) async {
    if (_replayBusy) return;
    setState(() => _replayBusy = true);
    try {
      // Replay overlay validation needs modelV2, so request p2 profile first.
      try {
        await _sidecarPostJson(
            '/profile', const <String, dynamic>{'profile': 'p2'});
      } catch (_) {}

      final result = await _sidecarPostJson(
        '/replay/start',
        <String, dynamic>{
          'route': route,
          'segment': segment,
          'speed': 1.0,
        },
      );
      if (result['ok'] != true) {
        throw Exception(result['error']?.toString() ?? 'replay start failed');
      }
      await _refreshReplayStatus();
      _toast('테스트 재생 시작: $route -- $segment');
    } catch (e) {
      _toast('테스트 재생 시작 실패: $e');
    } finally {
      if (mounted) setState(() => _replayBusy = false);
    }
  }

  Future<void> _stopReplay() async {
    if (_replayBusy) return;
    setState(() => _replayBusy = true);
    try {
      await _sidecarPostJson('/replay/stop', const <String, dynamic>{});
      await _refreshReplayStatus();
      _toast('테스트 재생 중지');
    } catch (e) {
      _toast('테스트 재생 중지 실패: $e');
    } finally {
      if (mounted) setState(() => _replayBusy = false);
    }
  }

  Future<void> _openReplayPickerDialog() async {
    if (_replayBusy) return;
    setState(() => _replayBusy = true);
    List<_ReplayRouteEntry> routes = const <_ReplayRouteEntry>[];
    try {
      routes = await _fetchReplayRoutes();
      await _refreshReplayStatus();
    } catch (e) {
      _toast('테스트 목록 조회 실패: $e');
    } finally {
      if (mounted) setState(() => _replayBusy = false);
    }
    if (!mounted) return;

    String? selectedRoute;
    int? selectedSegment;
    if (_replayRoute != null) {
      final existing = routes.where((e) => e.route == _replayRoute).toList();
      if (existing.isNotEmpty) {
        selectedRoute = existing.first.route;
        if (_replaySegment != null &&
            existing.first.segments.contains(_replaySegment)) {
          selectedSegment = _replaySegment;
        } else {
          selectedSegment = existing.first.segments.last;
        }
      }
    }
    if (selectedRoute == null && routes.isNotEmpty) {
      selectedRoute = routes.first.route;
      selectedSegment = routes.first.segments.last;
    }

    final action = await showDialog<_ReplayDialogAction>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final currentRoute = routes.firstWhere(
              (e) => e.route == selectedRoute,
              orElse: () => routes.isNotEmpty
                  ? routes.first
                  : const _ReplayRouteEntry.empty(),
            );
            final currentSegments =
                currentRoute.isEmpty ? const <int>[] : currentRoute.segments;
            final selectedIsValid = selectedSegment != null &&
                currentSegments.contains(selectedSegment);
            if (!selectedIsValid && currentSegments.isNotEmpty) {
              selectedSegment = currentSegments.last;
            }

            return AlertDialog(
              title: const Text('로그/루트 테스트 재생'),
              content: SizedBox(
                width: 420,
                child: routes.isEmpty
                    ? const Text('사용 가능한 route/segment를 찾지 못했습니다.')
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DropdownButtonFormField<String>(
                            initialValue: selectedRoute,
                            decoration: const InputDecoration(
                              labelText: 'Route',
                              isDense: true,
                            ),
                            items: routes
                                .map(
                                  (e) => DropdownMenuItem<String>(
                                    value: e.route,
                                    child: Text(
                                      e.route,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              setDialogState(() {
                                selectedRoute = value;
                                final route = routes.firstWhere(
                                  (e) => e.route == value,
                                  orElse: () => const _ReplayRouteEntry.empty(),
                                );
                                if (!route.isEmpty) {
                                  selectedSegment = route.segments.last;
                                }
                              });
                            },
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<int>(
                            initialValue: selectedSegment,
                            decoration: const InputDecoration(
                              labelText: 'Segment',
                              isDense: true,
                            ),
                            items: currentSegments
                                .map(
                                  (seg) => DropdownMenuItem<int>(
                                    value: seg,
                                    child: Text('$seg'),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              setDialogState(() => selectedSegment = value);
                            },
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _replayActive
                                ? '현재 재생 중: ${_replayRoute ?? '-'} -- ${_replaySegment ?? '-'}'
                                : '현재 재생 중 아님',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white70),
                          ),
                          if (_replayError != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              '오류: $_replayError',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFFF8E8E),
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    const _ReplayDialogAction.cancel(),
                  ),
                  child: const Text('닫기'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    const _ReplayDialogAction.stop(),
                  ),
                  child: const Text('중지'),
                ),
                FilledButton(
                  onPressed: routes.isEmpty ||
                          selectedRoute == null ||
                          selectedSegment == null
                      ? null
                      : () => Navigator.of(context).pop(
                            _ReplayDialogAction.start(
                              route: selectedRoute!,
                              segment: selectedSegment!,
                            ),
                          ),
                  child: const Text('시작'),
                ),
              ],
            );
          },
        );
      },
    );

    if (action == null || !mounted) return;
    if (action.type == _ReplayActionType.start &&
        action.route != null &&
        action.segment != null) {
      await _startReplay(route: action.route!, segment: action.segment!);
      return;
    }
    if (action.type == _ReplayActionType.stop) {
      await _stopReplay();
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        unawaited(_restorePortraitOrientation());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF05070C),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final dockWidth = (constraints.maxWidth * 0.08)
                  .clamp(
                    constraints.maxWidth * 0.06,
                    constraints.maxWidth * 0.12,
                  )
                  .toDouble();

              return Row(
                children: [
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
                          icon:
                              const Icon(Icons.arrow_back, color: Colors.white),
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
                        IconButton(
                          onPressed: _temporaryLimitedHudControls || _replayBusy
                              ? null
                              : _openReplayPickerDialog,
                          icon: _replayBusy
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  _replayActive
                                      ? Icons.movie_filter
                                      : Icons.play_circle_outline,
                                  color: _temporaryLimitedHudControls
                                      ? Colors.white38
                                      : (_replayActive
                                          ? const Color(0xFF5DFF89)
                                          : Colors.white),
                                ),
                          tooltip: '로그/루트 테스트 재생',
                        ),
                        IconButton(
                          onPressed: _temporaryLimitedHudControls ||
                                  _replayBusy ||
                                  !_replayActive
                              ? null
                              : _stopReplay,
                          icon: const Icon(Icons.stop_circle_outlined),
                          color: _temporaryLimitedHudControls
                              ? Colors.white38
                              : const Color(0xFFFF8E8E),
                          tooltip: '테스트 재생 중지',
                        ),
                        IconButton(
                          onPressed: _temporaryLimitedHudControls
                              ? null
                              : _toggleOverlayVerifyMode,
                          icon: Icon(
                            _overlayVerifyMode
                                ? Icons.fact_check
                                : Icons.fact_check_outlined,
                            color: _temporaryLimitedHudControls
                                ? Colors.white38
                                : (_overlayVerifyMode
                                    ? const Color(0xFF5DFF89)
                                    : Colors.white),
                          ),
                          tooltip:
                              _overlayVerifyMode ? '정합 검증 ON' : '정합 검증 OFF',
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: _sidecarBusy || !_openpilotOverlayMode
                              ? null
                              : _openSidecarActionPopup,
                          icon: Icon(
                            Icons.hub_outlined,
                            color: _sidecarBusy || !_openpilotOverlayMode
                                ? Colors.white38
                                : const Color(0xFF87FFAA),
                          ),
                          tooltip: _openpilotOverlayMode
                              ? '사이드카 제어'
                              : 'WebRTC 모드에서는 비활성화',
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
                          final sourceW = _cameraSourceSize.width > 1
                              ? _cameraSourceSize.width
                              : 1928.0;
                          final sourceH = _cameraSourceSize.height > 1
                              ? _cameraSourceSize.height
                              : 1208.0;
                          final vw = viewport.maxWidth;
                          final vh = viewport.maxHeight;
                          if (vw <= 1 || vh <= 1) {
                            return const SizedBox.shrink();
                          }
                          final scale = _coverViewport
                              ? math.max(vw / sourceW, vh / sourceH)
                              : math.min(vw / sourceW, vh / sourceH);
                          final drawW = sourceW * scale;
                          final drawH = sourceH * scale;
                          final left = (vw - drawW) * 0.5;
                          final top = (vh - drawH) * 0.5;
                          final drawSize = Size(drawW, drawH);
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
                                        child: _cameraSuspendedByLifecycle
                                            ? const ColoredBox(
                                                color: Colors.black,
                                              )
                                            : (_useNativeLiveCamera
                                                ? AndroidView(
                                                    key: ValueKey<String>(
                                                      'native-live-${widget.hostIp}-${_replayActive ? 1 : 0}-$_liveCameraName',
                                                    ),
                                                    viewType:
                                                        'carrotlink/native_drive_video',
                                                    creationParams: <String,
                                                        dynamic>{
                                                      'wsUrl': _liveCameraWsUrl,
                                                    },
                                                    creationParamsCodec:
                                                        const StandardMessageCodec(),
                                                    onPlatformViewCreated:
                                                        (viewId) {
                                                      if (!mounted) return;
                                                      setState(() {
                                                        _nativeCameraViewId =
                                                            viewId;
                                                        _cameraLoading = true;
                                                        _cameraError = null;
                                                      });
                                                      if (_useNativeOverlayRenderer) {
                                                        unawaited(
                                                          _pushNativeOverlay(
                                                            _overlayNotifier
                                                                .value,
                                                            force: true,
                                                          ),
                                                        );
                                                      }
                                                    },
                                                  )
                                                : WebViewWidget(
                                                    controller:
                                                        _cameraController,
                                                  )),
                                      ),
                                      if (_openpilotOverlayMode &&
                                          !_useNativeOverlayRenderer)
                                        Positioned.fill(
                                          child: ValueListenableBuilder<
                                              _DriveOverlaySnapshot>(
                                            valueListenable: _overlayNotifier,
                                            builder: (context, overlay, _) {
                                              return IgnorePointer(
                                                child: CustomPaint(
                                                  painter: _DriveOverlayPainter(
                                                    snapshot: overlay,
                                                    isConnected:
                                                        _sidecarConnected,
                                                    sourceSize:
                                                        _cameraSourceSize,
                                                    cameraKind: _replayActive
                                                        ? _DriveCameraKind.road
                                                        : _liveCameraKind,
                                                    coverViewport:
                                                        _coverViewport,
                                                    showDebugGuides:
                                                        _overlayVerifyMode,
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      if (_cameraLoading)
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
                                    ],
                                  ),
                                ),
                                if (_cameraError != null)
                                  Positioned(
                                    left: 16,
                                    right: 16,
                                    bottom: 16,
                                    child: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xCC7A1010),
                                        borderRadius: BorderRadius.circular(10),
                                        border:
                                            Border.all(color: Colors.white24),
                                      ),
                                      child: Text(
                                        _cameraError!,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                if (_overlayVerifyMode &&
                                    _overlayVerifyText.isNotEmpty)
                                  Positioned(
                                    top: 14,
                                    right: 14,
                                    child: IgnorePointer(
                                      child: Container(
                                        width: math.min(vw * 0.42, 520),
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: const Color(0xCC0B111A),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          border: Border.all(
                                            color: const Color(0xFF2F5D8C),
                                          ),
                                        ),
                                        child: SelectableText(
                                          _overlayVerifyText,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                            color: Color(0xFFEAF3FF),
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
            },
          ),
        ),
      ),
    );
  }
}

class _ReplayRouteEntry {
  final String route;
  final List<int> segments;

  const _ReplayRouteEntry({
    required this.route,
    required this.segments,
  });

  const _ReplayRouteEntry.empty()
      : route = '',
        segments = const <int>[];

  bool get isEmpty => route.isEmpty || segments.isEmpty;
}

enum _ReplayActionType { cancel, start, stop }

class _ReplayDialogAction {
  final _ReplayActionType type;
  final String? route;
  final int? segment;

  const _ReplayDialogAction._({
    required this.type,
    this.route,
    this.segment,
  });

  const _ReplayDialogAction.cancel() : this._(type: _ReplayActionType.cancel);

  const _ReplayDialogAction.stop() : this._(type: _ReplayActionType.stop);

  const _ReplayDialogAction.start({
    required String route,
    required int segment,
  }) : this._(
          type: _ReplayActionType.start,
          route: route,
          segment: segment,
        );
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
        lateralPathXMax = 0.0;

  _DriveOverlaySnapshot copyWith({
    int? pathMode,
    int? pathColor,
    List<double>? calibrationRpy,
    List<double>? wideFromDeviceEuler,
    double? pathOffsetZ,
    double? animationPhase,
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
      sidecarOverlay2d: sidecarOverlay2d,
      usingLateralPath: usingLateralPath,
      modelPathXMax: modelPathXMax,
      lateralPathXMax: lateralPathXMax,
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
    final overlay2dRaw = payload['overlay2d'];
    Map<String, dynamic>? sidecarOverlay2d;
    if (overlay2dRaw is Map) {
      sidecarOverlay2d = Map<String, dynamic>.from(overlay2dRaw);
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
    void applyCalibration(dynamic raw) {
      if (raw is! Map) return;
      final map = Map<String, dynamic>.from(raw);
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
    }

    if (liveCalibration is Map) {
      applyCalibration(liveCalibration);
    }
    if (calibrationRpy.length < 3 || wideFromDeviceEuler.length < 3) {
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

class _DriveOverlayPainter extends CustomPainter {
  final _DriveOverlaySnapshot snapshot;
  final bool isConnected;
  final Size sourceSize;
  final _DriveCameraKind cameraKind;
  final bool coverViewport;
  final bool showDebugGuides;

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

  _ProjectionTransform _buildTransform(Size size) {
    final wideCam = cameraKind == _DriveCameraKind.wideRoad;
    final src = _effectiveSourceSize;
    final intrinsic = _intrinsicForSource(src, wideCam);
    final deviceFromCalib = _rotationFromEuler(snapshot.calibrationRpy);
    final wideFromDevice = wideCam
        ? _rotationFromEuler(snapshot.wideFromDeviceEuler)
        : const _M3.identity();
    final viewFromCalib = wideCam
        ? _viewFromDevice.multiply(wideFromDevice.multiply(deviceFromCalib))
        : _viewFromDevice.multiply(deviceFromCalib);
    final calibTransform = intrinsic.multiply(viewFromCalib);
    final placement = _sourceToCanvasPlacement(
      source: src,
      canvas: size,
      intrinsic: intrinsic,
      calibTransform: calibTransform,
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
  }) {
    final painter = _DriveOverlayPainter(
      snapshot: snapshot,
      isConnected: true,
      sourceSize: sourceSize,
      cameraKind: cameraKind,
      coverViewport: coverViewport,
      showDebugGuides: showDebugGuides,
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
    required bool replayActive,
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
      replayActive: replayActive,
    );
  }

  String _buildProjectionDebugText({
    required Size canvasSize,
    required String cameraSourceLabel,
    required bool replayActive,
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
        'fit=${coverViewport ? 'cover' : 'contain'} cam=${cameraKind.name} $cameraSourceLabel ${replayActive ? 'replay' : 'live'}';

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
  }) {
    if (sourcePoints.isEmpty) return const <Offset>[];
    final srcW = (sourceWidth > 1.0) ? sourceWidth : _baseSourceWidth;
    final srcH = (sourceHeight > 1.0) ? sourceHeight : _baseSourceHeight;
    final source = Size(srcW, srcH);
    final wideCam = cameraKind == _DriveCameraKind.wideRoad;
    final intrinsic = _intrinsicForSource(source, wideCam);
    final deviceFromCalib = _rotationFromEuler(snapshot.calibrationRpy);
    final wideFromDevice = wideCam
        ? _rotationFromEuler(snapshot.wideFromDeviceEuler)
        : const _M3.identity();
    final viewFromCalib = wideCam
        ? _viewFromDevice.multiply(wideFromDevice.multiply(deviceFromCalib))
        : _viewFromDevice.multiply(deviceFromCalib);
    final calibTransform = intrinsic.multiply(viewFromCalib);
    final placement = _sourceToCanvasPlacement(
      source: source,
      canvas: canvasSize,
      intrinsic: intrinsic,
      calibTransform: calibTransform,
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
    final sourceWidth =
        _DriveOverlaySnapshot._asDouble(cam['sourceWidth']) ?? _baseSourceWidth;
    final sourceHeight = _DriveOverlaySnapshot._asDouble(cam['sourceHeight']) ??
        _baseSourceHeight;
    final polygons = <Map<String, dynamic>>[];
    List<Map<String, dynamic>>? labels;

    final laneRaw = cam['lanePolygons'];
    if (laneRaw is List) {
      for (final item in laneRaw) {
        if (item is! Map) continue;
        final points = _mapSourcePointsToCanvas(
          _decodeOverlayPoints(item['points']),
          canvasSize: size,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
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
    if (edgeRaw is List) {
      for (final item in edgeRaw) {
        if (item is! Map) continue;
        final points = _mapSourcePointsToCanvas(
          _decodeOverlayPoints(item['points']),
          canvasSize: size,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
        );
        if (points.length < 3) continue;
        final std = _DriveOverlaySnapshot._asDouble(item['std']) ?? 1.0;
        polygons.add(_encodePolygon(points, _roadEdgeColor(std)));
      }
    }

    final trackVertices = _mapSourcePointsToCanvas(
      _decodeOverlayPoints(cam['pathTrackVertices']),
      canvasSize: size,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
    if (trackVertices.length >= 3) {
      _collectPathPolygonsByMode(
        polygons,
        trackVertices,
        snapshot.pathMode,
        snapshot.pathColor,
        snapshot.brakeLights,
      );
    }

    if (showDebugGuides) {
      _appendDebugScreenGridPolygons(
        polygons,
        canvasSize: size,
      );
      labels = _buildDebugGridLabels(canvasSize: size);
    }

    if (polygons.isEmpty && (labels == null || labels.isEmpty)) return null;
    return <String, dynamic>{
      'version': 3,
      'canvasWidth': size.width,
      'canvasHeight': size.height,
      'sourceWidth': sourceWidth,
      'sourceHeight': sourceHeight,
      'polygons': polygons,
      if (labels != null && labels.isNotEmpty) 'labels': labels,
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
    if (trackVertices != null && trackVertices.length >= 3) {
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

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
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
    if (trackVertices != null) {
      _drawPathByMode(canvas, trackVertices);
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
        oldDelegate.showDebugGuides != showDebugGuides;
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
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}
