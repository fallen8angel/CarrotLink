import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/adaptive/window_class.dart';

class HomeHudPreviewCard extends StatefulWidget {
  final String? deviceIp;
  final bool enabled;
  final bool fillParent;
  final bool matchParentWidth;
  final double? fallbackCpuTempC;
  final double? fallbackMemPct;
  final double? fallbackDiskPct;

  const HomeHudPreviewCard({
    super.key,
    this.deviceIp,
    this.enabled = true,
    this.fillParent = false,
    this.matchParentWidth = false,
    this.fallbackCpuTempC,
    this.fallbackMemPct,
    this.fallbackDiskPct,
  });

  @override
  State<HomeHudPreviewCard> createState() => _HomeHudPreviewCardState();
}

class _HomeHudPreviewCardState extends State<HomeHudPreviewCard> {
  Isolate? _workerIsolate;
  ReceivePort? _workerReceivePort;
  StreamSubscription? _workerSubscription;
  int _workerToken = 0;
  String? _activeIp;
  _HudSnapshot _snapshot = const _HudSnapshot();

  @override
  void initState() {
    super.initState();
    _restartChannelIfNeeded(force: true);
  }

  @override
  void didUpdateWidget(covariant HomeHudPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceIp != widget.deviceIp ||
        oldWidget.enabled != widget.enabled) {
      _restartChannelIfNeeded(force: true);
    }
  }

  @override
  void dispose() {
    _stopWorker();
    super.dispose();
  }

  String? _normalizeIp(String? raw) {
    if (raw == null) return null;
    final ip = raw.trim();
    if (ip.isEmpty) return null;
    final ipv4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
    if (!ipv4.hasMatch(ip)) return null;
    return ip;
  }

  void _restartChannelIfNeeded({bool force = false}) {
    if (!widget.enabled) {
      _activeIp = null;
      _stopWorker();
      if (mounted) {
        setState(() => _snapshot = const _HudSnapshot());
      }
      return;
    }
    final nextIp = _normalizeIp(widget.deviceIp);
    if (!force && nextIp == _activeIp) return;
    _activeIp = nextIp;
    _stopWorker();
    if (nextIp == null) {
      if (mounted) {
        setState(() => _snapshot = const _HudSnapshot());
      }
      return;
    }
    final token = _workerToken;
    unawaited(_startWorker(nextIp, token));
  }

  void _stopWorker() {
    _workerToken++;
    _workerSubscription?.cancel();
    _workerSubscription = null;
    _workerReceivePort?.close();
    _workerReceivePort = null;
    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerIsolate = null;
  }

  Future<void> _startWorker(String ip, int token) async {
    if (!widget.enabled || _activeIp != ip || token != _workerToken) return;
    final receivePort = ReceivePort();
    _workerReceivePort = receivePort;
    _workerSubscription = receivePort.listen((event) {
      if (!mounted || token != _workerToken) return;
      _handleWorkerEvent(event);
    });
    try {
      final isolate = await Isolate.spawn<Map<String, dynamic>>(
        _hudWsWorkerMain,
        <String, dynamic>{
          'ip': ip,
          'maxHz': 10,
          'sendPort': receivePort.sendPort,
        },
        debugName: 'hud_ws_worker_$ip',
      );
      if (token != _workerToken) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _workerIsolate = isolate;
    } catch (_) {
      // Keep last snapshot and retry when widget updates state/IP.
    }
  }

  void _handleWorkerEvent(dynamic event) {
    if (!mounted) return;
    if (event is! Map) return;
    final payload = event['payload'];
    if (payload is! Map) return;
    try {
      final next = _HudSnapshot.fromWs(Map<String, dynamic>.from(payload));
      setState(() => _snapshot = next);
    } catch (_) {
      // ignore malformed worker payload
    }
  }

  String _fmtCpu(double? v) =>
      v == null ? '--\u00b0C' : '${v.toStringAsFixed(0)}\u00b0C';

  String _fmtMem(double? v) => v == null ? '--%' : '${v.toStringAsFixed(0)}%';

  String _fmtDisk(double? v, String label) {
    if (v == null) return label == 'DISK' ? '--%' : '--.-V';
    if (label == 'DISK') return '${v.toStringAsFixed(0)}%';
    return '${v.toStringAsFixed(1)}V';
  }

  String _fmtMainSpeed(double? v) => v == null ? '--' : '${v.round()}';

  String _fmtSetSpeed(double? v) => v == null ? '--' : '${v.round()}';

  String _fmtTempSpeed(double? v) => v == null ? '--' : '${v.round()}';

  String _fmtLimit(double? v) => v == null ? '--' : '${v.round()}';

  Color _signalColor(String tlight) {
    switch (tlight) {
      case 'red':
        return const Color(0xFFFF2A2A);
      case 'green':
        return const Color(0xFF15D14B);
      default:
        return Colors.white24;
    }
  }

  Color _driveModeBg(String kind) {
    switch (kind) {
      case 'eco':
        return const Color(0xFF10C248);
      case 'safe':
        return const Color(0xFFFF9C2A);
      case 'sport':
        return const Color(0xFFFF2A2A);
      default:
        return const Color(0xFFE7EEF7);
    }
  }

  Color _driveModeFg(String kind) {
    switch (kind) {
      case 'normal':
      case 'safe':
        return const Color(0xFF1A1F26);
      default:
        return Colors.white;
    }
  }

  Color _tempColor(bool isDecel) =>
      isDecel ? const Color(0xFFFF9C2A) : const Color(0xFF22FF61);

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final media = MediaQuery.of(context);
    final effectiveMemPct = _snapshot.memPct ?? widget.fallbackMemPct;
    final effectiveDiskValue = _snapshot.diskValue ?? widget.fallbackDiskPct;
    final effectiveDiskLabel = _snapshot.diskValue != null
        ? _snapshot.diskLabel
        : (widget.fallbackDiskPct != null ? 'DISK' : _snapshot.diskLabel);
    final tempColor = _tempColor(_snapshot.tempIsDecel);
    final driveModeBg = _driveModeBg(_snapshot.driveModeKind);
    final driveModeFg = _driveModeFg(_snapshot.driveModeKind);
    final barsOn = _snapshot.tfBars.clamp(0, 4);
    final maxCardWidthByClass = switch (window.windowClass) {
      UiWindowClass.compact => 340.0,
      UiWindowClass.medium => 380.0,
      UiWindowClass.expanded => 420.0,
      UiWindowClass.large => 460.0,
      UiWindowClass.extraLarge => 500.0,
    };
    final landscapeCap = media.orientation == Orientation.landscape
        ? (media.size.height * 0.46).clamp(260.0, 420.0).toDouble()
        : maxCardWidthByClass;
    final maxCardWidth = math.min(maxCardWidthByClass, landscapeCap);
    final maxScale = switch (window.windowClass) {
      UiWindowClass.compact => 1.12,
      UiWindowClass.medium => 1.16,
      UiWindowClass.expanded => 1.2,
      UiWindowClass.large => 1.22,
      UiWindowClass.extraLarge => 1.24,
    };
    final clampedMedia = media.copyWith(
      textScaler: media.textScaler.clamp(
        minScaleFactor: 0.9,
        maxScaleFactor: maxScale,
      ),
    );
    final previewAspectRatio = switch (window.windowClass) {
      UiWindowClass.compact => 1.68,
      UiWindowClass.medium => 1.76,
      UiWindowClass.expanded => 1.84,
      UiWindowClass.large => 1.92,
      UiWindowClass.extraLarge => 2.0,
    };

    final hudCore = LayoutBuilder(
      builder: (context, constraints) {
        final finiteW =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 340.0;
        final finiteH =
            constraints.maxHeight.isFinite ? constraints.maxHeight : finiteW;
        final side = (widget.fillParent || widget.matchParentWidth)
            ? math.min(finiteW, finiteH).clamp(170.0, 560.0).toDouble()
            : finiteW;
        final scale = side / 340.0;
        final metricGap = 8 * scale;
        final bodyTopGap = (7 * scale).clamp(2.0, 10.0).toDouble();
        final metricHeight = math.max(32.0, 56 * scale);
        final mainSpeedFont = 78 * scale;
        final setSpeedFont = 44 * scale;
        final tempSourceFont = 32 * scale;
        final tempSpeedFont = 52 * scale;
        final gearColor = _snapshot.gear.trim().toUpperCase() == 'P'
            ? const Color(0xFF22FF61)
            : Colors.white;

        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF010A18),
            borderRadius: BorderRadius.circular(20 * scale),
            border: Border.all(color: Colors.white70, width: 2 * scale),
          ),
          child: Padding(
            padding: EdgeInsets.all(10 * scale),
            child: Column(
              children: [
                SizedBox(
                  height: metricHeight,
                  child: Row(
                    children: [
                      Expanded(
                        child: _HudMiniMetric(
                          label: 'CPU',
                          value: _fmtCpu(
                            _snapshot.cpuTempC ?? widget.fallbackCpuTempC,
                          ),
                          scale: scale,
                        ),
                      ),
                      SizedBox(width: metricGap),
                      Expanded(
                        child: _HudMiniMetric(
                          label: 'MEM',
                          value: _fmtMem(effectiveMemPct),
                          scale: scale,
                        ),
                      ),
                      SizedBox(width: metricGap),
                      Expanded(
                        child: _HudMiniMetric(
                          label: effectiveDiskLabel,
                          value:
                              _fmtDisk(effectiveDiskValue, effectiveDiskLabel),
                          scale: scale,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: bodyTopGap),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, bodyConstraints) {
                      final w = bodyConstraints.maxWidth;
                      final h = bodyConstraints.maxHeight;
                      final rawBodyScale = math.min(w / 320.0, h / 230.0);
                      final bottomDockInset =
                          (16.0 * rawBodyScale).clamp(10.0, 22.0).toDouble();
                      final usableH = math.max(140.0, h - bottomDockInset);
                      final bodyScale =
                          math.min(w / 320.0, usableH / 230.0);

                      double px(double r) => w * r;
                      double py(double r) => usableH * r;
                      double bottomY(double r) => bottomDockInset + py(r);

                      return Stack(
                        children: [
                          Positioned.fill(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                px(0.08),
                                py(0.12),
                                px(0.14),
                                py(0.18),
                              ),
                              child: Opacity(
                                opacity: 0.95,
                                child: Image.asset(
                                  'assets/speed_bg.png',
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) =>
                                      const SizedBox(),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: px(0.01),
                            top: py(0.00),
                            child: Container(
                              width: 20 * bodyScale,
                              height: 20 * bodyScale,
                              decoration: BoxDecoration(
                                color: _signalColor(_snapshot.tlight),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.black54,
                                  width: 1.5 * scale,
                                ),
                              ),
                            ),
                          ),
                          if (_snapshot.redDot)
                            Positioned(
                              left: px(0.09),
                              top: py(0.10),
                              child: Container(
                                width: 14 * scale,
                                height: 14 * scale,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFFF2A2A),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          Positioned(
                            left: px(0.10),
                            top: py(0.19),
                            child: Text(
                              _fmtMainSpeed(_snapshot.vEgoKph),
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: mainSpeedFont * 0.92,
                                letterSpacing: -2 * scale,
                                height: 0.92,
                              ),
                            ),
                          ),
                          Positioned(
                            right: px(0.12),
                            top: py(0.045),
                            child: SizedBox(
                              width: px(0.24),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text(
                                  _snapshot.tempSource,
                                  style: TextStyle(
                                    color: const Color(0xFF22FF61),
                                    fontWeight: FontWeight.w800,
                                    fontSize: tempSourceFont * 0.68,
                                    height: 0.95,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: px(0.07),
                            top: py(0.11),
                            child: SizedBox(
                              width: px(0.20),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text(
                                  _fmtTempSpeed(_snapshot.tempSpeedKph),
                                  style: TextStyle(
                                    color: tempColor,
                                    fontWeight: FontWeight.w900,
                                    fontSize: tempSpeedFont * 0.74,
                                    height: 0.95,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: px(0.56),
                            top: py(0.305),
                            child: SizedBox(
                              width: px(0.13),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text(
                                  _fmtSetSpeed(_snapshot.vSetKph),
                                  style: TextStyle(
                                    color: const Color(0xFF22FF61),
                                    fontWeight: FontWeight.w900,
                                    fontSize: setSpeedFont * 0.8,
                                    height: 0.95,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: px(0.00),
                            top: py(0.27),
                            child: Container(
                              width: 44 * bodyScale,
                              height: 72 * bodyScale,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius:
                                    BorderRadius.circular(16 * bodyScale),
                                border: Border.all(
                                  color: Colors.white70,
                                  width: 2 * bodyScale,
                                ),
                              ),
                              child: Text(
                                _snapshot.gear,
                                style: TextStyle(
                                  color: gearColor,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 54 * bodyScale,
                                  height: 0.95,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            bottom: bottomY(0.00),
                            child: Column(
                              children: List.generate(
                                4,
                                (idx) => Container(
                                  margin:
                                      EdgeInsets.only(bottom: 6 * bodyScale),
                                  width: 42 * bodyScale,
                                  height: 11 * bodyScale,
                                  decoration: BoxDecoration(
                                    color: idx >= 4 - barsOn
                                        ? const Color(0xFF1CFF57)
                                        : const Color(0xFF505862),
                                    borderRadius:
                                        BorderRadius.circular(3 * bodyScale),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            right: px(0.18),
                            bottom: bottomY(0.00),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'GPS',
                                      style: TextStyle(
                                        color: _snapshot.gpsOk
                                            ? Colors.white
                                            : Colors.white54,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 22 * bodyScale,
                                      ),
                                    ),
                                    SizedBox(height: 2 * bodyScale),
                                    Container(
                                      width: 96 * bodyScale,
                                      height: 34 * bodyScale,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: driveModeBg,
                                        borderRadius: BorderRadius.circular(
                                            14 * bodyScale),
                                        border: Border.all(
                                          color: Colors.black38,
                                          width: 1.5 * bodyScale,
                                        ),
                                      ),
                                      child: Text(
                                        _snapshot.driveModeName,
                                        style: TextStyle(
                                          color: driveModeFg,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 19 * bodyScale,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const Spacer(),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'LIMIT',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 22 * bodyScale,
                                      ),
                                    ),
                                    SizedBox(height: 2 * bodyScale),
                                    Container(
                                      width: 90 * bodyScale,
                                      height: 34 * bodyScale,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: _snapshot.speedLimitOver
                                            ? const Color(0xFFFF2A2A)
                                            : const Color(0xFF010A18),
                                        borderRadius: BorderRadius.circular(
                                            14 * bodyScale),
                                        border: Border.all(
                                          color: Colors.black45,
                                          width: 1.5 * bodyScale,
                                        ),
                                      ),
                                      child: Text(
                                        _fmtLimit(_snapshot.speedLimitKph),
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 20 * bodyScale,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    return MediaQuery(
      data: clampedMedia,
      child: widget.fillParent
          ? SizedBox.expand(child: hudCore)
          : Center(
              child: widget.matchParentWidth
                  ? AspectRatio(
                      aspectRatio: previewAspectRatio,
                      child: hudCore,
                    )
                  : ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxCardWidth),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: hudCore,
                      ),
                    ),
            ),
    );
  }
}

@pragma('vm:entry-point')
Future<void> _hudWsWorkerMain(Map<String, dynamic> config) async {
  final ip = (config['ip']?.toString() ?? '').trim();
  final maxHz = (config['maxHz'] as int?) ?? 10;
  final sendPort = config['sendPort'] as SendPort?;
  if (ip.isEmpty || sendPort == null) return;
  final minIntervalMs = maxHz <= 0 ? 100 : (1000 / maxHz).round();
  var lastSentMs = 0;
  while (true) {
    WebSocket? socket;
    try {
      socket = await WebSocket.connect('ws://$ip:7000/ws/carstate');
      await for (final event in socket) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastSentMs < minIntervalMs) continue;
        Map<String, dynamic>? payload;
        try {
          final decoded = jsonDecode(event.toString());
          if (decoded is Map<String, dynamic>) {
            payload = decoded;
          } else if (decoded is Map) {
            payload = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {
          payload = null;
        }
        if (payload == null) continue;
        lastSentMs = nowMs;
        sendPort.send({
          'type': 'snapshot',
          'payload': payload,
        });
      }
    } catch (_) {
      // reconnect loop
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}

class _HudMiniMetric extends StatelessWidget {
  final String label;
  final String value;
  final double scale;

  const _HudMiniMetric({
    required this.label,
    required this.value,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    final labelFont = (13.0 * scale).clamp(8.0, 16.0).toDouble();
    final valueFont = (18.0 * scale).clamp(10.0, 22.0).toDouble();
    final verticalPadding = (6 * scale).clamp(2.0, 6.0).toDouble();
    final horizontalPadding = (8 * scale).clamp(3.0, 8.0).toDouble();
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: verticalPadding,
        horizontal: horizontalPadding,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1E9A44),
        borderRadius: BorderRadius.circular(10 * scale),
        border: Border.all(color: Colors.black38, width: 1.5 * scale),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: constraints.maxWidth,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: labelFont,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 2 * scale),
              SizedBox(
                width: constraints.maxWidth,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: valueFont,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _HudSnapshot {
  final double? cpuTempC;
  final double? memPct;
  final double? diskValue;
  final String diskLabel;
  final double? vEgoKph;
  final double? vSetKph;
  final String gear;
  final bool gpsOk;
  final int tfBars;
  final String driveModeName;
  final String driveModeKind;
  final String tlight;
  final bool redDot;
  final String tempSource;
  final double? tempSpeedKph;
  final bool tempIsDecel;
  final double? speedLimitKph;
  final bool speedLimitOver;

  const _HudSnapshot({
    this.cpuTempC,
    this.memPct,
    this.diskValue,
    this.diskLabel = 'VOLT',
    this.vEgoKph,
    this.vSetKph,
    this.gear = 'U',
    this.gpsOk = false,
    this.tfBars = 0,
    this.driveModeName = 'Normal',
    this.driveModeKind = 'normal',
    this.tlight = 'off',
    this.redDot = false,
    this.tempSource = 'eco',
    this.tempSpeedKph,
    this.tempIsDecel = false,
    this.speedLimitKph,
    this.speedLimitOver = false,
  });

  static double? _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is Iterable) {
      double? maxValue;
      for (final item in v) {
        final parsed = _asDouble(item);
        if (parsed == null) continue;
        maxValue = maxValue == null ? parsed : math.max(maxValue, parsed);
      }
      return maxValue;
    }
    if (v is String) return double.tryParse(v);
    return null;
  }

  static double? _firstDouble(Map<String, dynamic> raw, List<String> keys) {
    for (final key in keys) {
      final v = _asDouble(raw[key]);
      if (v != null) return v;
    }
    return null;
  }

  static int _asInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static bool _asBool(dynamic v, {bool fallback = false}) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final lower = v.toLowerCase();
      return lower == 'true' || lower == '1' || lower == 'yes';
    }
    return fallback;
  }

  factory _HudSnapshot.fromWs(Map<String, dynamic> raw) {
    final vEgoMs = _asDouble(raw['vEgo']);
    final temp = raw['temp'];
    String tempSource = 'eco';
    double? tempSpeed;
    bool isDecel = false;
    if (temp is Map) {
      final source = temp['source']?.toString().trim() ?? '';
      if (source.isNotEmpty) tempSource = source;
      tempSpeed = _asDouble(temp['speed']);
      isDecel = _asBool(temp['is_decel']);
    }

    final driveMode = raw['driveMode'];
    String modeName = 'Normal';
    String modeKind = 'normal';
    if (driveMode is Map) {
      final n = driveMode['name']?.toString().trim() ?? '';
      final k = driveMode['kind']?.toString().trim() ?? '';
      if (n.isNotEmpty) modeName = n;
      if (k.isNotEmpty) modeKind = k;
    }

    final label = (raw['diskLabel']?.toString().trim().toUpperCase() ?? 'VOLT');
    return _HudSnapshot(
      cpuTempC: _firstDouble(raw, const ['cpuTempC', 'cpuTemp', 'cpu_temp_c']),
      memPct: _firstDouble(raw,
          const ['memPct', 'memPctC', 'mem', 'mem_pct', 'memoryUsagePercent']),
      diskValue: _firstDouble(raw, const ['diskPct', 'disk', 'disk_pct']),
      diskLabel: label.isEmpty ? 'VOLT' : label,
      vEgoKph: vEgoMs == null ? null : (vEgoMs * 3.6),
      vSetKph: _asDouble(raw['vSetKph']),
      gear: (raw['gear']?.toString().trim().isNotEmpty ?? false)
          ? raw['gear'].toString()
          : 'U',
      gpsOk: _asBool(raw['gpsOk']),
      tfBars: _asInt(raw['tfBars'], fallback: _asInt(raw['tfGap'])),
      driveModeName: modeName,
      driveModeKind: modeKind,
      tlight: (raw['tlight']?.toString().trim().toLowerCase() ?? 'off'),
      redDot: _asBool(raw['redDot']),
      tempSource: tempSource,
      tempSpeedKph: tempSpeed,
      tempIsDecel: isDecel,
      speedLimitKph: _asDouble(raw['speedLimitKph']),
      speedLimitOver: _asBool(raw['speedLimitOver']),
    );
  }
}
