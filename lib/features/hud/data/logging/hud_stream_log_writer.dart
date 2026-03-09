import 'dart:convert';
import 'dart:io';

import '../../../../services/storage_layout_service.dart';
import '../../domain/entities/original_hud_snapshot.dart';
import '../models/hud_remote_stream_event.dart';

class HudStreamLogWriter {
  final String host;

  HudStreamLogWriter({
    required this.host,
  });

  IOSink? _sink;
  Future<void>? _openingFuture;
  Future<void> _writeQueue = Future<void>.value();
  bool _disabled = false;
  bool _disposed = false;
  int _writeCount = 0;

  Future<void> logSessionStart() async {
    await _write(<String, dynamic>{
      'type': 'session_start',
      'timestamp': DateTime.now().toIso8601String(),
      'host': host,
    });
  }

  Future<void> logRaw(HudRemoteStreamEvent event) async {
    await _write(<String, dynamic>{
      'type': 'raw',
      'timestamp': DateTime.now().toIso8601String(),
      'host': host,
      'port': event.port,
      'path': event.path,
      'receivedAtMs': event.receivedAtMs,
      'payload': event.payload,
    });
  }

  Future<void> logMapped({
    required OriginalHudSnapshot snapshot,
  }) async {
    await _write(<String, dynamic>{
      'type': 'mapped',
      'timestamp': DateTime.now().toIso8601String(),
      'host': host,
      'tsMonoMs': snapshot.tsMonoMs,
      'transport': snapshot.source.transport,
      'endpointPort': snapshot.source.endpointPort,
      'endpointPath': snapshot.source.endpointPath,
      'quality': snapshot.meta.quality,
      'missingFields': snapshot.meta.missingFields,
      'fallbackMetricsApplied': snapshot.meta.isFallbackMetricsApplied,
      'speedClusterKph': snapshot.vehicle.speedClusterKph,
      'setSpeedClusterKph': snapshot.vehicle.setSpeedClusterKph,
      'gearText': snapshot.vehicle.gearText,
      'longActive': snapshot.vehicle.longActive,
      'latActive': snapshot.vehicle.latActive,
      'driveModeName': snapshot.driveMode.nameOriginal,
      'driveModeKind': snapshot.driveMode.kind,
      'tempMode': snapshot.tempControl.mode,
      'tempLabel': snapshot.tempControl.label,
      'tempSpeedKph': snapshot.tempControl.speedKph,
      'gapDisplayValue': snapshot.gap.displayValue,
      'gapBarCount': snapshot.gap.barCount,
      'limitMode': snapshot.limits.mode,
      'limitLabel': snapshot.limits.label,
      'limitSpeedKph': snapshot.limits.displaySpeedKph,
      'connectivityMode': snapshot.connectivity.badgeMode,
      'connectivityLabel': snapshot.connectivity.badgeLabel,
      'signalState': snapshot.signals.visualState,
      'gpsHasFix': snapshot.gps.hasFix,
    });
  }

  Future<void> logError({
    required String type,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    await _write(<String, dynamic>{
      'type': type,
      'timestamp': DateTime.now().toIso8601String(),
      'host': host,
      'error': error?.toString(),
      'stackTrace': stackTrace?.toString(),
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    try {
      await _writeQueue;
    } catch (_) {}
    final openingFuture = _openingFuture;
    if (openingFuture != null) {
      try {
        await openingFuture;
      } catch (_) {}
    }
    final sink = _sink;
    _sink = null;
    if (sink == null) return;
    try {
      await sink.flush();
    } catch (_) {}
    try {
      await sink.close();
    } catch (_) {}
  }

  Future<void> _write(Map<String, dynamic> entry) async {
    if (_disabled || _disposed) return;
    final queued = _writeQueue.then((_) => _writeSerialized(entry));
    _writeQueue = queued.catchError((_) {});
    await queued;
  }

  Future<void> _writeSerialized(Map<String, dynamic> entry) async {
    if (_disabled || _disposed) return;
    final sink = await _ensureSink();
    if (sink == null) return;
    sink.writeln(jsonEncode(entry));
    _writeCount += 1;
    if (_writeCount % 4 == 0) {
      try {
        await sink.flush();
      } catch (_) {}
    }
  }

  Future<IOSink?> _ensureSink() async {
    if (_disabled || _disposed) return null;
    final current = _sink;
    if (current != null) return current;
    if (_openingFuture != null) {
      await _openingFuture;
      return _sink;
    }
    _openingFuture = _openSink();
    try {
      await _openingFuture;
    } finally {
      _openingFuture = null;
    }
    return _sink;
  }

  Future<void> _openSink() async {
    try {
      final dir = await _resolveLogDir();
      final hostTag = host.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
      final file = File('${dir.path}/hud_stream_${hostTag}_latest.ndjson');
      if (await file.exists()) {
        await file.delete();
      }
      _sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    } catch (_) {
      _disabled = true;
    }
  }

  Future<Directory> _resolveLogDir() async {
    try {
      await StorageLayoutService.instance.ensureBaseFolders();
      final preferred = Directory('${StorageLayoutService.logsPath}/hud');
      if (!await preferred.exists()) {
        await preferred.create(recursive: true);
      }
      return preferred;
    } catch (_) {
      final fallback = Directory('${Directory.systemTemp.path}/carrotlink_hud');
      if (!await fallback.exists()) {
        await fallback.create(recursive: true);
      }
      return fallback;
    }
  }
}
