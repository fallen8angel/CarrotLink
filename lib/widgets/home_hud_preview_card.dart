import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

class HomeHudPreviewCard extends StatefulWidget {
  final String? deviceIp;
  final bool enabled;
  final double? fallbackCpuTempC;
  final double? fallbackMemPct;
  final double? fallbackDiskPct;

  const HomeHudPreviewCard({
    super.key,
    this.deviceIp,
    this.enabled = true,
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
    final effectiveMemPct = _snapshot.memPct ?? widget.fallbackMemPct;
    final effectiveDiskValue = _snapshot.diskValue ?? widget.fallbackDiskPct;
    final effectiveDiskLabel = _snapshot.diskValue != null
        ? _snapshot.diskLabel
        : (widget.fallbackDiskPct != null ? 'DISK' : _snapshot.diskLabel);
    final tempColor = _tempColor(_snapshot.tempIsDecel);
    final driveModeBg = _driveModeBg(_snapshot.driveModeKind);
    final driveModeFg = _driveModeFg(_snapshot.driveModeKind);
    final barsOn = _snapshot.tfBars.clamp(0, 4);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF010A18),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white70, width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _HudMiniMetric(
                          label: 'CPU',
                          value: _fmtCpu(
                            _snapshot.cpuTempC ?? widget.fallbackCpuTempC,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _HudMiniMetric(
                          label: 'MEM',
                          value: _fmtMem(effectiveMemPct),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _HudMiniMetric(
                          label: effectiveDiskLabel,
                          value:
                              _fmtDisk(effectiveDiskValue, effectiveDiskLabel),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 66, 44),
                            child: Opacity(
                              opacity: 0.95,
                              child: Image.asset(
                                'assets/speed_bg.png',
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => const SizedBox(),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          top: 2,
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: _signalColor(_snapshot.tlight),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.black54,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                        if (_snapshot.redDot)
                          Positioned(
                            left: 22,
                            top: 30,
                            child: Container(
                              width: 16,
                              height: 16,
                              decoration: const BoxDecoration(
                                color: Color(0xFFFF2A2A),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        Positioned(
                          left: 36,
                          top: 38,
                          child: Text(
                            _fmtMainSpeed(_snapshot.vEgoKph),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 56,
                              letterSpacing: -2,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 64,
                          top: 18,
                          child: Text(
                            _snapshot.tempSource,
                            style: const TextStyle(
                              color: Color(0xFF22FF61),
                              fontWeight: FontWeight.w800,
                              fontSize: 24,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 74,
                          top: 46,
                          child: Text(
                            _fmtTempSpeed(_snapshot.tempSpeedKph),
                            style: TextStyle(
                              color: tempColor,
                              fontWeight: FontWeight.w900,
                              fontSize: 40,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 102,
                          top: 98,
                          child: Text(
                            _fmtSetSpeed(_snapshot.vSetKph),
                            style: const TextStyle(
                              color: Color(0xFF22FF61),
                              fontWeight: FontWeight.w900,
                              fontSize: 40,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 88,
                          child: Container(
                            width: 44,
                            height: 66,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border:
                                  Border.all(color: Colors.white70, width: 2),
                            ),
                            child: Text(
                              _snapshot.gear,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 50,
                                height: 1.0,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 2,
                          child: Column(
                            children: List.generate(
                              4,
                              (idx) => Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                width: 44,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: idx >= 4 - barsOn
                                      ? const Color(0xFF1CFF57)
                                      : const Color(0xFF505862),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 56,
                          bottom: 2,
                          child: Row(
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
                                      fontSize: 22,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Container(
                                    width: 94,
                                    height: 34,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: driveModeBg,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: Colors.black38,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Text(
                                      _snapshot.driveModeName,
                                      style: TextStyle(
                                        color: driveModeFg,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 20,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const Spacer(),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'LIMIT',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 22,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Container(
                                    width: 90,
                                    height: 34,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: _snapshot.speedLimitOver
                                          ? const Color(0xFFFF2A2A)
                                          : const Color(0xFF010A18),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: Colors.black45,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Text(
                                      _fmtLimit(_snapshot.speedLimitKph),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 20,
                                      ),
                                    ),
                                  ),
                                ],
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

  const _HudMiniMetric({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E9A44),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black38, width: 1.5),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 14,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 18,
              height: 1.0,
            ),
          ),
        ],
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
