import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../../services/hud_feature_settings_service.dart';
import '../../../services/sidecar_service.dart';
import '../../../services/ssh_service.dart';
import 'hud_controller.dart';
import 'hud_controller_state.dart';
import 'hud_module.dart';
import '../domain/entities/original_hud_snapshot.dart';

@immutable
class OverlayStreamFrame {
  final String host;
  final Map<String, dynamic> payload;
  final int? modelFrameId;
  final int? roadFrameId;
  final int? wideRoadFrameId;
  final int receivedAtMs;
  final int sequence;

  const OverlayStreamFrame._({
    required this.host,
    required this.payload,
    required this.modelFrameId,
    required this.roadFrameId,
    required this.wideRoadFrameId,
    required this.receivedAtMs,
    required this.sequence,
  });

  factory OverlayStreamFrame.fromPayload({
    required String host,
    required Map<String, dynamic> payload,
    required int sequence,
  }) {
    final normalized = Map<String, dynamic>.from(payload);
    int? readFrameId(String key) {
      final raw = normalized[key];
      if (raw is! Map) return null;
      final value = raw['frameId'];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    return OverlayStreamFrame._(
      host: host,
      payload: Map<String, dynamic>.unmodifiable(normalized),
      modelFrameId: readFrameId('modelV2'),
      roadFrameId: readFrameId('roadCameraState'),
      wideRoadFrameId: readFrameId('wideRoadCameraState'),
      receivedAtMs: DateTime.now().millisecondsSinceEpoch,
      sequence: sequence,
    );
  }
}

@pragma('vm:entry-point')
Future<void> _overlayRuntimeWorkerMain(Map<String, dynamic> config) async {
  final wsUrl = (config['wsUrl']?.toString() ?? '').trim();
  final sendPort = config['sendPort'] as SendPort?;
  if (wsUrl.isEmpty || sendPort == null) {
    return;
  }

  Map<String, dynamic>? decodePayload(dynamic event) {
    try {
      if (event is String) {
        final decoded = jsonDecode(event);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } else if (event is List<int>) {
        var bytes = event;
        try {
          bytes = zlib.decode(bytes);
        } catch (_) {
          // Sidecar may still send plain UTF-8 frames during fallback paths.
        }
        final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {}
    return null;
  }

  while (true) {
    WebSocket? socket;
    try {
      socket = await WebSocket.connect(wsUrl).timeout(
        const Duration(seconds: 4),
      );
      sendPort.send(<String, dynamic>{'type': 'connected', 'connected': true});
      await for (final event in socket) {
        final payload = decodePayload(event);
        if (payload == null) {
          continue;
        }
        sendPort.send(<String, dynamic>{
          'type': 'frame',
          'payload': payload,
        });
      }
    } catch (_) {
      // Retry loop keeps the app-scope overlay stream warm through startup races.
    } finally {
      sendPort.send(<String, dynamic>{'type': 'connected', 'connected': false});
      try {
        await socket?.close();
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }
}

class SharedRuntimeManager extends ChangeNotifier {
  static const int _overlayFrameBufferSize = 220;
  static const Duration _overlayBackgroundGrace = Duration(seconds: 15);
  static const String _bootstrapTransportProfile =
      SidecarService.hudBootstrapProfile;

  SSHService? _sshService;
  HudFeatureSettingsService? _featureSettings;
  HudControllerLease? _controllerLease;
  HudController? _controller;
  bool _appForeground = true;
  String? _targetHost;
  String? _bindingHost;
  final ValueNotifier<int> _overlayStreamTick = ValueNotifier<int>(0);
  final Map<int, OverlayStreamFrame> _overlayByModelFrame =
      <int, OverlayStreamFrame>{};
  final ListQueue<int> _overlayFrameOrder = ListQueue<int>();
  Isolate? _overlayWorkerIsolate;
  ReceivePort? _overlayWorkerReceivePort;
  StreamSubscription<dynamic>? _overlayWorkerSubscription;
  int _overlayWorkerGeneration = 0;
  int _overlaySequence = 0;
  bool _overlayConnected = false;
  String? _overlayHost;
  OverlayStreamFrame? _latestOverlayFrame;
  bool _forceControllerRebind = false;
  Timer? _overlayBackgroundStopTimer;
  int _transportEnsureGeneration = 0;
  final LinkedHashMap<String, OriginalHudSnapshot> _hudSnapshotByHost =
      LinkedHashMap<String, OriginalHudSnapshot>();

  HudController? get controller => _controller;
  HudControllerState get state => _controller?.state ?? HudControllerState.idle;
  String? get targetHost => _targetHost;
  bool get appForeground => _appForeground;
  bool get overlayConnected => _overlayConnected;
  String? get overlayHost => _overlayHost;
  OverlayStreamFrame? get latestOverlayFrame => _latestOverlayFrame;
  ValueListenable<int> get overlayStreamListenable => _overlayStreamTick;
  OriginalHudSnapshot? hudSnapshotForHost(String host) =>
      _hudSnapshotByHost[host.trim()];
  List<OverlayStreamFrame> get overlayFrameBuffer => _overlayFrameOrder
      .map((frameId) => _overlayByModelFrame[frameId])
      .whereType<OverlayStreamFrame>()
      .toList(growable: false);

  void attachSshService(SSHService sshService) {
    if (identical(_sshService, sshService)) {
      return;
    }
    _sshService?.removeListener(_handleSshChanged);
    _sshService = sshService;
    _ensureControllerLease();
    sshService.addListener(_handleSshChanged);
    _handleSshChanged();
  }

  void attachFeatureSettings(HudFeatureSettingsService featureSettings) {
    if (identical(_featureSettings, featureSettings)) {
      return;
    }
    _featureSettings?.removeListener(_handleFeatureSettingsChanged);
    _featureSettings = featureSettings;
    featureSettings.addListener(_handleFeatureSettingsChanged);
    _handleFeatureSettingsChanged();
  }

  bool get _hudFeatureEnabled => _featureSettings?.enabled ?? false;

  void setAppForeground(bool value) {
    if (_appForeground == value) {
      return;
    }
    _appForeground = value;
    if (!_hudFeatureEnabled) {
      unawaited(resetRuntime(clearCachedSnapshots: false));
      notifyListeners();
      return;
    }
    if (_appForeground) {
      _cancelOverlayBackgroundStopTimer();
      unawaited(_ensureBound());
    } else {
      _scheduleOverlayBackgroundStop();
    }
    notifyListeners();
  }

  Future<void> prewarm() async {
    if (!_hudFeatureEnabled) {
      return;
    }
    await _ensureBound(forceEnsureRunning: true);
  }

  Future<void> ensureOverlayStream({
    bool forceRestart = false,
  }) async {
    if (!_hudFeatureEnabled) {
      _stopOverlayWorker(clearCache: true);
      return;
    }
    final host = _resolveConnectedHost();
    if (!_shouldKeepOverlayWorkerAlive) {
      _stopOverlayWorker(clearCache: false);
      return;
    }
    if (host == null) {
      _stopOverlayWorker(clearCache: true);
      return;
    }

    final hostChanged = _overlayHost != host;
    final needsRestart =
        forceRestart || hostChanged || _overlayWorkerIsolate == null;
    if (!needsRestart) {
      return;
    }

    _stopOverlayWorker(clearCache: hostChanged);
    _overlayHost = host;
    final generation = ++_overlayWorkerGeneration;
    final receivePort = ReceivePort();
    _overlayWorkerReceivePort = receivePort;
    _overlayWorkerSubscription = receivePort.listen((event) {
      if (generation != _overlayWorkerGeneration) {
        return;
      }
      _handleOverlayWorkerEvent(host, event);
    });

    try {
      final isolate = await Isolate.spawn<Map<String, dynamic>>(
        _overlayRuntimeWorkerMain,
        <String, dynamic>{
          'wsUrl': _overlayWsUrl(host, generation),
          'sendPort': receivePort.sendPort,
        },
        debugName: 'app_overlay_runtime_$host',
      );
      if (generation != _overlayWorkerGeneration) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _overlayWorkerIsolate = isolate;
    } catch (_) {
      _overlayWorkerSubscription?.cancel();
      _overlayWorkerSubscription = null;
      _overlayWorkerReceivePort?.close();
      _overlayWorkerReceivePort = null;
      if (_overlayConnected) {
        _overlayConnected = false;
        _publishOverlayTick();
      }
    }
  }

  void _ensureControllerLease() {
    if (_controllerLease != null) {
      return;
    }
    final lease = HudModule.acquireSharedController(
      sshService: _sshService,
      clientRole: 'app_hud',
    );
    final controller = lease.controller;
    controller.addListener(_handleControllerChanged);
    _controllerLease = lease;
    _controller = controller;
    notifyListeners();
  }

  String? _resolveConnectedHost() {
    final host = _sshService?.connectedIp?.trim();
    if (host == null || host.isEmpty) {
      return null;
    }
    return host;
  }

  void _handleSshChanged() {
    final previousHost = _targetHost;
    _targetHost = _resolveConnectedHost();
    if (!_hudFeatureEnabled) {
      _bindingHost = null;
      _forceControllerRebind = true;
      _stopOverlayWorker(clearCache: true);
      notifyListeners();
      return;
    }
    if (_targetHost == null) {
      _bindingHost = null;
      _forceControllerRebind = true;
      _stopOverlayWorker(clearCache: true);
    }
    notifyListeners();
    if (_appForeground) {
      unawaited(
        _ensureBound(forceEnsureRunning: previousHost != _targetHost),
      );
    }
  }

  void _handleFeatureSettingsChanged() {
    if (!_hudFeatureEnabled) {
      unawaited(resetRuntime(clearCachedSnapshots: true));
      notifyListeners();
      return;
    }
    notifyListeners();
    if (_appForeground) {
      unawaited(_ensureBound(forceEnsureRunning: true));
    }
  }

  Future<void> _ensureBound({
    bool forceEnsureRunning = false,
  }) async {
    if (!_hudFeatureEnabled) {
      return;
    }
    final controller = _controller;
    final ssh = _sshService;
    final host = _resolveConnectedHost();
    if (controller == null || ssh == null || host == null || !_appForeground) {
      if (host == null) {
        _stopOverlayWorker(clearCache: true);
      } else if (!_appForeground) {
        _scheduleOverlayBackgroundStop();
      }
      return;
    }
    final forceControllerRebind = _forceControllerRebind;
    if (_bindingHost == host && !forceControllerRebind) {
      if (forceEnsureRunning) {
        _scheduleTransportEnsure(
          host: host,
          controller: controller,
          ssh: ssh,
        );
      }
      await ensureOverlayStream();
      return;
    }
    final alreadyBound =
        controller.state.host == host && !controller.state.isPreview;
    if (alreadyBound && !forceControllerRebind) {
      _seedCachedHudSnapshotIfAvailable(controller, host);
      if (forceEnsureRunning) {
        _scheduleTransportEnsure(
          host: host,
          controller: controller,
          ssh: ssh,
        );
      }
      await ensureOverlayStream();
      return;
    }
    _bindingHost = host;
    try {
      _seedCachedHudSnapshotIfAvailable(controller, host);
      await controller.bindLive(host, force: forceControllerRebind);
      if (_targetHost == host && identical(_controller, controller)) {
        _forceControllerRebind = false;
      }
      if (forceEnsureRunning || controller.state.snapshot.tsMonoMs <= 0) {
        _scheduleTransportEnsure(
          host: host,
          controller: controller,
          ssh: ssh,
        );
      }
    } finally {
      if (identical(_bindingHost, host)) {
        _bindingHost = null;
      }
    }
    await ensureOverlayStream();
  }

  Future<void> resetRuntime({
    bool clearCachedSnapshots = true,
    bool releaseHostSession = false,
  }) async {
    _targetHost = null;
    _bindingHost = null;
    _forceControllerRebind = true;
    _transportEnsureGeneration += 1;
    _stopOverlayWorker(clearCache: true);
    if (clearCachedSnapshots) {
      _hudSnapshotByHost.clear();
    }
    final controller = _controller;
    if (controller != null) {
      await controller.clear(releaseHost: releaseHostSession);
    }
    notifyListeners();
  }

  void _handleControllerChanged() {
    final controller = _controller;
    if (controller != null) {
      final state = controller.state;
      final host = state.host?.trim() ?? '';
      final snapshot = state.snapshot;
      if (!state.isPreview && host.isNotEmpty && snapshot.tsMonoMs > 0) {
        _cacheHudSnapshot(host, snapshot);
      }
    }
    notifyListeners();
  }

  void _seedCachedHudSnapshotIfAvailable(
    HudController controller,
    String host,
  ) {
    final cached = _hudSnapshotByHost[host];
    if (cached == null || cached.tsMonoMs <= 0) {
      return;
    }
    if (controller.state.snapshot.tsMonoMs > 0 &&
        controller.state.host?.trim() == host) {
      return;
    }
    controller.seedLiveSnapshot(host: host, snapshot: cached);
  }

  void _scheduleTransportEnsure({
    required String host,
    required HudController controller,
    required SSHService ssh,
  }) {
    if (!ssh.isConnected) {
      return;
    }
    final generation = ++_transportEnsureGeneration;
    unawaited(
      _ensureTransportReady(
        generation: generation,
        host: host,
        controller: controller,
        ssh: ssh,
      ),
    );
  }

  Future<void> _ensureTransportReady({
    required int generation,
    required String host,
    required HudController controller,
    required SSHService ssh,
  }) async {
    final ensureResult = await HudModule.ensureLiveTransport(
      ssh,
      profile: _bootstrapTransportProfile,
    );
    if (generation != _transportEnsureGeneration) {
      return;
    }
    if (_targetHost != host || !identical(_controller, controller)) {
      return;
    }
    final ensureError = ensureResult.error;
    if (ensureError != null &&
        controller.state.host == host &&
        controller.state.snapshot.tsMonoMs <= 0) {
      controller.reportBindingError(
        host: host,
        isPreview: false,
        error: ensureError,
        stackTrace: ensureResult.stackTrace,
      );
    }
  }

  void _cacheHudSnapshot(String host, OriginalHudSnapshot snapshot) {
    _hudSnapshotByHost.remove(host);
    _hudSnapshotByHost[host] = snapshot;
    while (_hudSnapshotByHost.length > 4) {
      _hudSnapshotByHost.remove(_hudSnapshotByHost.keys.first);
    }
  }

  void _handleOverlayWorkerEvent(String host, dynamic event) {
    if (event is! Map) {
      return;
    }
    final map = Map<String, dynamic>.from(event);
    final type = map['type']?.toString() ?? '';
    if (type == 'connected') {
      final next = map['connected'] == true;
      if (_overlayConnected != next) {
        _overlayConnected = next;
        _publishOverlayTick();
      }
      return;
    }
    if (type != 'frame') {
      return;
    }
    final rawPayload = map['payload'];
    if (rawPayload is! Map) {
      return;
    }
    final payload = Map<String, dynamic>.from(rawPayload);
    if (payload['type'] == 'hello') {
      return;
    }

    final frame = OverlayStreamFrame.fromPayload(
      host: host,
      payload: payload,
      sequence: ++_overlaySequence,
    );
    _latestOverlayFrame = frame;
    final modelFrameId = frame.modelFrameId;
    if (modelFrameId != null && modelFrameId >= 0) {
      if (!_overlayByModelFrame.containsKey(modelFrameId)) {
        _overlayFrameOrder.addLast(modelFrameId);
      }
      _overlayByModelFrame[modelFrameId] = frame;
      while (_overlayFrameOrder.length > _overlayFrameBufferSize) {
        final drop = _overlayFrameOrder.removeFirst();
        _overlayByModelFrame.remove(drop);
      }
    }
    _publishOverlayTick();
  }

  String _overlayWsUrl(String host, int generation) {
    return 'ws://$host:7766/ws/live'
        '?encoding=json'
        '&camera=road'
        '&role=drive_overlay'
        '&session=app_overlay_$generation';
  }

  void _publishOverlayTick() {
    _overlayStreamTick.value = _overlayStreamTick.value + 1;
  }

  bool get _shouldKeepOverlayWorkerAlive =>
      _appForeground || (_overlayBackgroundStopTimer?.isActive ?? false);

  void _scheduleOverlayBackgroundStop() {
    if (_overlayWorkerIsolate == null) {
      return;
    }
    _overlayBackgroundStopTimer?.cancel();
    _overlayBackgroundStopTimer = Timer(_overlayBackgroundGrace, () {
      _overlayBackgroundStopTimer = null;
      if (_appForeground) {
        return;
      }
      _stopOverlayWorker(clearCache: false);
    });
  }

  void _cancelOverlayBackgroundStopTimer() {
    _overlayBackgroundStopTimer?.cancel();
    _overlayBackgroundStopTimer = null;
  }

  void _clearOverlayCache() {
    _latestOverlayFrame = null;
    _overlayByModelFrame.clear();
    _overlayFrameOrder.clear();
    _overlaySequence = 0;
  }

  void _stopOverlayWorker({
    required bool clearCache,
  }) {
    _cancelOverlayBackgroundStopTimer();
    _overlayWorkerGeneration += 1;
    _overlayWorkerSubscription?.cancel();
    _overlayWorkerSubscription = null;
    _overlayWorkerReceivePort?.close();
    _overlayWorkerReceivePort = null;
    _overlayWorkerIsolate?.kill(priority: Isolate.immediate);
    _overlayWorkerIsolate = null;

    var shouldPublish = false;
    if (_overlayConnected) {
      _overlayConnected = false;
      shouldPublish = true;
    }
    if (clearCache) {
      final hadCache = _overlayHost != null ||
          _latestOverlayFrame != null ||
          _overlayFrameOrder.isNotEmpty;
      _overlayHost = null;
      _clearOverlayCache();
      shouldPublish = shouldPublish || hadCache;
    }
    if (shouldPublish) {
      _publishOverlayTick();
    }
  }

  @override
  void dispose() {
    _sshService?.removeListener(_handleSshChanged);
    _featureSettings?.removeListener(_handleFeatureSettingsChanged);
    _transportEnsureGeneration += 1;
    _cancelOverlayBackgroundStopTimer();
    _stopOverlayWorker(clearCache: false);
    _overlayStreamTick.dispose();
    final controller = _controller;
    final lease = _controllerLease;
    _controller = null;
    _controllerLease = null;
    if (controller != null) {
      controller.removeListener(_handleControllerChanged);
    }
    if (lease != null) {
      unawaited(lease.release());
    }
    super.dispose();
  }
}

@Deprecated('Use SharedRuntimeManager instead.')
class HudRuntimeManager extends SharedRuntimeManager {}
