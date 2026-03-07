import '../../../../services/ssh_service.dart';
import '../models/hud_fallback_metrics_sample.dart';

class HudSshFallbackMetricsAdapter {
  final SSHService sshService;

  const HudSshFallbackMetricsAdapter({
    required this.sshService,
  });

  Future<HudFallbackMetricsSample?> fetch(String host) async {
    final normalizedHost = host.trim();
    if (normalizedHost.isEmpty || !sshService.isConnected) {
      return null;
    }

    final connectedHost = sshService.connectedIp?.trim();
    if (connectedHost == null || connectedHost != normalizedHost) {
      return null;
    }

    final metrics = await sshService.getHudFallbackMetrics();
    if (metrics == null) {
      return null;
    }

    return HudFallbackMetricsSample(
      host: normalizedHost,
      tsEpochMs: DateTime.now().millisecondsSinceEpoch,
      cpuTempC: metrics.cpuTempC,
      memPct: metrics.memPct,
      diskPct: metrics.diskPct,
    );
  }
}
