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

class HudRepositoryLease {
  final HudRepository repository;
  final Future<void> Function() _release;
  bool _released = false;

  HudRepositoryLease._({
    required this.repository,
    required Future<void> Function() release,
  }) : _release = release;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}

class HudModule {
  static final Object _nullSshKey = Object();
  static final Map<Object, _HudRepositoryPoolEntry> _repositoryPool =
      <Object, _HudRepositoryPoolEntry>{};

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

  static HudRepositoryLease acquireSharedRepository({
    SSHService? sshService,
  }) {
    final key = sshService ?? _nullSshKey;
    final entry = _repositoryPool.putIfAbsent(
      key,
      () => _HudRepositoryPoolEntry(
        repository: createRepository(sshService: sshService),
      ),
    );
    entry.refCount += 1;
    return HudRepositoryLease._(
      repository: entry.repository,
      release: () async {
        final current = _repositoryPool[key];
        if (current == null) {
          return;
        }
        current.refCount -= 1;
        if (current.refCount <= 0) {
          _repositoryPool.remove(key);
          await current.repository.dispose();
        }
      },
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

class _HudRepositoryPoolEntry {
  final HudRepository repository;
  int refCount = 0;

  _HudRepositoryPoolEntry({
    required this.repository,
  });
}
