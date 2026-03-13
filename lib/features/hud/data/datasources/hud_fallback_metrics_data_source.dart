import 'dart:async';

import '../models/hud_fallback_metrics_sample.dart';

typedef HudFallbackMetricsFetcher = Future<HudFallbackMetricsSample?> Function(
  String host,
);

class HudFallbackMetricsDataSource {
  final HudFallbackMetricsFetcher fetcher;
  final Duration pollInterval;

  const HudFallbackMetricsDataSource({
    required this.fetcher,
    this.pollInterval = const Duration(seconds: 8),
  });

  Stream<HudFallbackMetricsSample> watch({
    required String host,
  }) {
    late final StreamController<HudFallbackMetricsSample> controller;
    Timer? timer;
    var inFlight = false;

    Future<void> poll() async {
      if (inFlight) {
        return;
      }
      inFlight = true;
      try {
        final sample = await fetcher(host);
        if (!controller.isClosed && sample != null) {
          controller.add(sample);
        }
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      } finally {
        inFlight = false;
      }
    }

    controller = StreamController<HudFallbackMetricsSample>(
      onListen: () {
        unawaited(poll());
        timer = Timer.periodic(pollInterval, (_) {
          unawaited(poll());
        });
      },
      onCancel: () async {
        timer?.cancel();
      },
    );

    return controller.stream;
  }
}
