import 'dart:async';

import '../../domain/entities/original_hud_snapshot.dart';
import '../../domain/repositories/hud_repository.dart';
import '../datasources/hud_fallback_metrics_data_source.dart';
import '../datasources/hud_preview_data_source.dart';
import '../datasources/hud_remote_stream_data_source.dart';
import '../mappers/hud_snapshot_assembler.dart';
import '../models/hud_fallback_metrics_sample.dart';

class HudRepositoryImpl implements HudRepository {
  final HudRemoteStreamDataSource remoteStreamDataSource;
  final HudFallbackMetricsDataSource? fallbackMetricsDataSource;
  final HudPreviewDataSource previewDataSource;
  final HudSnapshotAssembler snapshotAssembler;

  HudRepositoryImpl({
    required this.remoteStreamDataSource,
    required this.previewDataSource,
    required this.snapshotAssembler,
    this.fallbackMetricsDataSource,
  });

  final Map<String, _HudLiveSession> _sessions = <String, _HudLiveSession>{};
  final Map<String, OriginalHudSnapshot> _latestByHost =
      <String, OriginalHudSnapshot>{};

  Stream<OriginalHudSnapshot>? _previewStream;
  OriginalHudSnapshot? _latestPreview;

  @override
  Stream<OriginalHudSnapshot> watchLive({
    required String host,
  }) {
    return _ensureSession(host).controller.stream;
  }

  @override
  Stream<OriginalHudSnapshot> watchPreview() {
    _previewStream ??= previewDataSource.watch().map((snapshot) {
      _latestPreview = snapshot;
      return snapshot;
    }).asBroadcastStream();
    return _previewStream!;
  }

  @override
  Future<OriginalHudSnapshot?> getLatest({
    String? host,
  }) async {
    if (host != null && host.trim().isNotEmpty) {
      return _latestByHost[host];
    }
    if (_latestPreview != null) {
      return _latestPreview;
    }
    for (final snapshot in _latestByHost.values) {
      return snapshot;
    }
    return null;
  }

  @override
  Future<void> warmUp({
    required String host,
  }) async {
    _ensureSession(host);
  }

  @override
  Future<void> disposeHost(String host) async {
    final session = _sessions.remove(host);
    _latestByHost.remove(host);
    if (session == null) {
      return;
    }
    await session.dispose();
  }

  @override
  Future<void> dispose() async {
    final hosts = _sessions.keys.toList(growable: false);
    for (final host in hosts) {
      await disposeHost(host);
    }
    _previewStream = null;
    _latestPreview = null;
  }

  _HudLiveSession _ensureSession(String host) {
    return _sessions.putIfAbsent(host, () {
      final controller = StreamController<OriginalHudSnapshot>.broadcast();
      final session = _HudLiveSession(controller: controller);

      session.remoteSubscription = remoteStreamDataSource
          .watch(host: host)
          .listen((rawPayload) {
        final remoteSnapshot = snapshotAssembler.fromRemotePayload(
          raw: rawPayload,
          host: host,
        );
        session.latestRemote = remoteSnapshot;
        final mergedSnapshot = snapshotAssembler.applyFallback(
          snapshot: remoteSnapshot,
          fallback: session.latestFallback,
        );
        session.latestMerged = mergedSnapshot;
        _latestByHost[host] = mergedSnapshot;
        if (!controller.isClosed) {
          controller.add(mergedSnapshot);
        }
      }, onError: (error, stackTrace) {
        final degraded = snapshotAssembler.degrade(
          host: host,
          base: session.latestMerged ?? session.latestRemote,
          error: error,
        );
        session.latestMerged = degraded;
        _latestByHost[host] = degraded;
        if (!controller.isClosed) {
          controller.add(degraded);
          controller.addError(error, stackTrace);
        }
      });

      if (fallbackMetricsDataSource != null) {
        session.fallbackSubscription =
            fallbackMetricsDataSource!.watch(host: host).listen((sample) {
          session.latestFallback = sample;
          final current = session.latestRemote ?? session.latestMerged;
          if (current == null) {
            return;
          }
          final mergedSnapshot = snapshotAssembler.applyFallback(
            snapshot: current,
            fallback: sample,
          );
          session.latestMerged = mergedSnapshot;
          _latestByHost[host] = mergedSnapshot;
          if (!controller.isClosed) {
            controller.add(mergedSnapshot);
          }
        }, onError: (error, stackTrace) {
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          }
        });
      }

      return session;
    });
  }
}

class _HudLiveSession {
  final StreamController<OriginalHudSnapshot> controller;
  StreamSubscription<Map<String, dynamic>>? remoteSubscription;
  StreamSubscription<HudFallbackMetricsSample>? fallbackSubscription;
  OriginalHudSnapshot? latestRemote;
  OriginalHudSnapshot? latestMerged;
  HudFallbackMetricsSample? latestFallback;

  _HudLiveSession({
    required this.controller,
  });

  Future<void> dispose() async {
    await remoteSubscription?.cancel();
    await fallbackSubscription?.cancel();
    await controller.close();
  }
}
