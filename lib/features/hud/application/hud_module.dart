import '../../../services/ssh_service.dart';
import '../data/adapters/hud_ssh_fallback_metrics_adapter.dart';
import '../data/datasources/hud_fallback_metrics_data_source.dart';
import '../data/datasources/hud_preview_data_source.dart';
import '../data/datasources/hud_remote_stream_data_source.dart';
import '../data/mappers/hud_fallback_merge_policy.dart';
import '../data/mappers/hud_remote_payload_mapper.dart';
import '../data/mappers/hud_snapshot_assembler.dart';
import '../data/repositories/hud_repository_impl.dart';
import '../domain/repositories/hud_repository.dart';
import 'hud_controller.dart';

class HudModule {
  static HudRepository createRepository({
    SSHService? sshService,
    HudRemoteStreamDataSource? remoteStreamDataSource,
    HudPreviewDataSource? previewDataSource,
    HudRemotePayloadMapper? remotePayloadMapper,
    HudFallbackMergePolicy? fallbackMergePolicy,
    HudFallbackMetricsDataSource? fallbackMetricsDataSource,
  }) {
    final fallbackSource = fallbackMetricsDataSource ??
        (sshService == null
            ? null
            : HudFallbackMetricsDataSource(
                fetcher: HudSshFallbackMetricsAdapter(
                  sshService: sshService,
                ).fetch,
              ));

    return HudRepositoryImpl(
      remoteStreamDataSource:
          remoteStreamDataSource ?? const HudRemoteStreamDataSource(),
      previewDataSource: previewDataSource ?? HudPreviewDataSource(),
      fallbackMetricsDataSource: fallbackSource,
      snapshotAssembler: HudSnapshotAssembler(
        remotePayloadMapper: remotePayloadMapper ?? HudRemotePayloadMapper(),
        fallbackMergePolicy:
            fallbackMergePolicy ?? const HudFallbackMergePolicy(),
      ),
    );
  }

  static HudController createController({
    SSHService? sshService,
    HudRepository? repository,
  }) {
    return HudController(
      repository ?? createRepository(sshService: sshService),
    );
  }
}
