import 'dart:async';

import '../../../services/sidecar_service.dart';
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

typedef HudTransportBootstrapResult = ({
  String? component,
  Object? error,
  StackTrace? stackTrace
});

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

class HudControllerLease {
  final HudController controller;
  final Future<void> Function() _release;
  bool _released = false;

  HudControllerLease._({
    required this.controller,
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
  static const Duration _repositoryDisposeGrace = Duration(seconds: 30);
  static const Duration _controllerDisposeGrace = Duration(seconds: 45);
  static final SidecarService _sidecarService = SidecarService.shared;
  static final Map<Object, _HudRepositoryPoolEntry> _repositoryPool =
      <Object, _HudRepositoryPoolEntry>{};
  static final Map<Object, _HudControllerPoolEntry> _controllerPool =
      <Object, _HudControllerPoolEntry>{};

  static Future<HudTransportBootstrapResult> ensureLiveTransport(
    SSHService sshService,
    {String profile = SidecarService.hudBootstrapProfile}
  ) async {
    if (!sshService.isConnected) {
      return (component: null, error: null, stackTrace: null);
    }

    String? component;
    Object? error;
    StackTrace? stackTrace;

    void capture(
      String nextComponent,
      Object nextError,
      StackTrace nextStackTrace,
    ) {
      component ??= nextComponent;
      error ??= nextError;
      stackTrace ??= nextStackTrace;
    }

    try {
      await _sidecarService.ensureRunning(sshService, profile: profile);
    } catch (e, s) {
      capture('sidecar', e, s);
    }

    return (
      component: component,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static HudRepository createRepository({
    SSHService? sshService,
    String clientRole = 'app_hud',
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
      remoteStreamDataSource: remoteStreamDataSource ??
          HudRemoteStreamDataSource(clientRole: clientRole),
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
    String clientRole = 'app_hud',
  }) {
    final sshKey = sshService ?? _nullSshKey;
    final key = sshKey;
    final entry = _repositoryPool.putIfAbsent(
      key,
      () => _HudRepositoryPoolEntry(
        repository: createRepository(
          sshService: sshService,
          clientRole: clientRole,
        ),
      ),
    );
    entry.pendingDisposeTimer?.cancel();
    entry.pendingDisposeTimer = null;
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
          current.pendingDisposeTimer?.cancel();
          current.pendingDisposeTimer =
              Timer(_repositoryDisposeGrace, () async {
            final latest = _repositoryPool[key];
            if (!identical(latest, current) || current.refCount > 0) {
              return;
            }
            _repositoryPool.remove(key);
            await current.repository.dispose();
          });
        }
      },
    );
  }

  static HudControllerLease acquireSharedController({
    SSHService? sshService,
    String clientRole = 'app_hud',
  }) {
    final sshKey = sshService ?? _nullSshKey;
    final key = sshKey;
    final entry = _controllerPool.putIfAbsent(key, () {
      final repositoryLease = acquireSharedRepository(
        sshService: sshService,
        clientRole: clientRole,
      );
      return _HudControllerPoolEntry(
        controller: createController(
          repository: repositoryLease.repository,
        ),
        repositoryLease: repositoryLease,
      );
    });
    entry.pendingDisposeTimer?.cancel();
    entry.pendingDisposeTimer = null;
    entry.refCount += 1;
    return HudControllerLease._(
      controller: entry.controller,
      release: () async {
        final current = _controllerPool[key];
        if (current == null) {
          return;
        }
        current.refCount -= 1;
        if (current.refCount <= 0) {
          current.pendingDisposeTimer?.cancel();
          current.pendingDisposeTimer =
              Timer(_controllerDisposeGrace, () async {
            final latest = _controllerPool[key];
            if (!identical(latest, current) || current.refCount > 0) {
              return;
            }
            _controllerPool.remove(key);
            await current.controller.clear();
            current.controller.dispose();
            await current.repositoryLease.release();
          });
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
  Timer? pendingDisposeTimer;

  _HudRepositoryPoolEntry({
    required this.repository,
  });
}

class _HudControllerPoolEntry {
  final HudController controller;
  final HudRepositoryLease repositoryLease;
  int refCount = 0;
  Timer? pendingDisposeTimer;

  _HudControllerPoolEntry({
    required this.controller,
    required this.repositoryLease,
  });
}
