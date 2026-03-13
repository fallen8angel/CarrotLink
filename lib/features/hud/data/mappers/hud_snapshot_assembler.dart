import '../../domain/entities/original_hud_snapshot.dart';
import '../models/hud_fallback_metrics_sample.dart';
import 'hud_fallback_merge_policy.dart';
import 'hud_remote_payload_mapper.dart';

class HudSnapshotAssembler {
  final HudRemotePayloadMapper remotePayloadMapper;
  final HudFallbackMergePolicy fallbackMergePolicy;

  const HudSnapshotAssembler({
    required this.remotePayloadMapper,
    required this.fallbackMergePolicy,
  });

  OriginalHudSnapshot fromRemotePayload({
    required Map<String, dynamic> raw,
    required String host,
    int? endpointPort,
    String? endpointPath,
    int? receivedAtMs,
  }) {
    return remotePayloadMapper.map(
      raw: raw,
      host: host,
      endpointPort: endpointPort,
      endpointPath: endpointPath,
      receivedAtMs: receivedAtMs,
    );
  }

  OriginalHudSnapshot applyFallback({
    required OriginalHudSnapshot snapshot,
    required HudFallbackMetricsSample? fallback,
  }) {
    return fallbackMergePolicy.merge(
      primary: snapshot,
      fallback: fallback,
    );
  }

  OriginalHudSnapshot degrade({
    required String host,
    required OriginalHudSnapshot? base,
    Object? error,
  }) {
    final current = base ??
        OriginalHudSnapshot(
          source: HudSourceInfo(
            transport: 'remote_unavailable',
            deviceHost: host,
          ),
          meta: const HudMetaState(
            quality: 'degraded',
          ),
        );
    final missingFields = <String>{
      ...current.meta.missingFields,
      'remote.unavailable',
      if (error != null) 'remote.error',
    }.toList()
      ..sort();

    return current.copyWith(
      source: current.source.copyWith(
        deviceHost: host,
        transport: current.source.transport == 'unknown'
            ? 'remote_unavailable'
            : current.source.transport,
      ),
      meta: current.meta.copyWith(
        quality: current.meta.isPreview ? 'preview' : 'degraded',
        missingFields: missingFields,
      ),
    );
  }
}
