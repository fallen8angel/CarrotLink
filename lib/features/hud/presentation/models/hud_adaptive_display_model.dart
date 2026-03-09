import '../../domain/entities/original_hud_snapshot.dart';

class HudAdaptiveDisplayModel {
  static const int _assistFreshnessMs = 2500;

  final String speedText;
  final String setSpeedText;
  final String gearText;
  final String driveModeText;
  final bool showDriveMode;
  final String driveModeKind;
  final String tempLabel;
  final String tempSpeedText;
  final bool showTempControl;
  final bool tempIsDecel;
  final String limitLabel;
  final String limitValueText;
  final String limitDisplayText;
  final bool showLimit;
  final bool limitCritical;
  final bool limitBlink;
  final bool isCameraLimit;
  final bool cameraAlertBlinkOn;
  final String connectivityText;
  final String connectivityDisplayText;
  final bool showConnectivity;
  final bool hasGpsFix;
  final String gpsText;
  final bool showGpsBadge;
  final int gapBarCount;
  final String gapText;
  final bool showGap;
  final String signalState;
  final String signalDisplayText;
  final bool showSignalState;
  final bool redDot;
  final String cpuText;
  final String memText;
  final String auxMetricLabel;
  final String auxMetricText;
  final bool showDeviceMetrics;
  final bool longActive;
  final bool latActive;
  final bool isPreview;
  final String sourceText;
  final String qualityText;
  final String hostText;
  final String compatibilityHint;
  final String compatibilityBadgeText;
  final bool showCompatibilityHint;
  final bool isDegradedMeta;
  final int tsMonoMs;

  const HudAdaptiveDisplayModel({
    required this.speedText,
    required this.setSpeedText,
    required this.gearText,
    required this.driveModeText,
    required this.showDriveMode,
    required this.driveModeKind,
    required this.tempLabel,
    required this.tempSpeedText,
    required this.showTempControl,
    required this.tempIsDecel,
    required this.limitLabel,
    required this.limitValueText,
    required this.limitDisplayText,
    required this.showLimit,
    required this.limitCritical,
    required this.limitBlink,
    required this.isCameraLimit,
    required this.cameraAlertBlinkOn,
    required this.connectivityText,
    required this.connectivityDisplayText,
    required this.showConnectivity,
    required this.hasGpsFix,
    required this.gpsText,
    required this.showGpsBadge,
    required this.gapBarCount,
    required this.gapText,
    required this.showGap,
    required this.signalState,
    required this.signalDisplayText,
    required this.showSignalState,
    required this.redDot,
    required this.cpuText,
    required this.memText,
    required this.auxMetricLabel,
    required this.auxMetricText,
    required this.showDeviceMetrics,
    required this.longActive,
    required this.latActive,
    required this.isPreview,
    required this.sourceText,
    required this.qualityText,
    required this.hostText,
    required this.compatibilityHint,
    required this.compatibilityBadgeText,
    required this.showCompatibilityHint,
    required this.isDegradedMeta,
    required this.tsMonoMs,
  });

  factory HudAdaptiveDisplayModel.fromSnapshot(OriginalHudSnapshot snapshot) {
    // Canonical c3 lower-left HUD mapping for CarrotLink:
    // - temp/apply slot is apply source + apply speed, not free-form debug text
    // - bottom strip is drive mode | LIMIT/CAM/section | APN/APM
    // - transport/debug metadata must not occupy semantic HUD slots
    // - if semantic live values are not present, footer slots must stay blank
    // - TBT/navigation overlay is out of scope for this display model
    final assistContext = _shouldShowAssistContext(snapshot);
    final semanticLive = _isSemanticLive(snapshot);
    final auxIsVolt = snapshot.device.metricPrimaryMode == 'volt';
    final tempLabel = (snapshot.tempControl.label ?? snapshot.tempControl.mode)
        .trim()
        .toLowerCase();
    final limitLabel =
        (snapshot.limits.label ?? snapshot.limits.mode).trim().toUpperCase();
    final showTempControl = semanticLive &&
        assistContext &&
        snapshot.tempControl.mode != 'hidden' &&
        ((_safeHasText(snapshot.tempControl.label)) ||
            snapshot.tempControl.speedKph != null);
    final showLimit = semanticLive && _hasMeaningfulLimit(snapshot);
    final showGpsBadge = snapshot.gps.hasFix;
    final gapValue =
        snapshot.gap.displayValue > 0 ? '${snapshot.gap.displayValue}' : '--';
    final showGap =
        semanticLive && assistContext && snapshot.gap.displayValue > 0;
    final normalizedSignalState =
        snapshot.signals.visualState.trim().toLowerCase();
    final showSignalState = semanticLive &&
        assistContext &&
        (normalizedSignalState == 'red' ||
            normalizedSignalState == 'green' ||
            normalizedSignalState == 'yellow');
    final sourceText = _buildSourceText(snapshot);
    final qualityText = _buildQualityText(snapshot);
    final compatibilityHint = _buildCompatibilityHint(snapshot);
    final compatibilityBadgeText = _buildCompatibilityBadgeText(snapshot);
    final connectivityText = _buildConnectivityText(snapshot);
    final isCameraLimit = snapshot.limits.mode == 'camera';
    final cameraAlertBlinkOn = semanticLive &&
        isCameraLimit &&
        _isCameraAlertBlinkOn(snapshot.tsMonoMs);
    final showDriveMode = semanticLive && _hasMeaningfulDriveMode(snapshot);
    final showConnectivity = semanticLive && connectivityText.isNotEmpty;
    final limitDisplayText = _buildLimitDisplayText(snapshot);
    final signalDisplayText = _buildSignalDisplayText(snapshot);
    return HudAdaptiveDisplayModel(
      speedText: _formatInt(snapshot.vehicle.speedClusterKph),
      setSpeedText: _formatInt(snapshot.vehicle.setSpeedClusterKph),
      gearText: snapshot.vehicle.gearText.trim().isEmpty
          ? 'U'
          : snapshot.vehicle.gearText.trim(),
      driveModeText: _buildDriveModeText(snapshot),
      showDriveMode: showDriveMode,
      driveModeKind: snapshot.driveMode.kind,
      tempLabel:
          showTempControl ? (tempLabel.isEmpty ? 'apply' : tempLabel) : '',
      tempSpeedText: _formatInt(snapshot.tempControl.speedKph),
      showTempControl: showTempControl,
      tempIsDecel: snapshot.tempControl.isDecel,
      limitLabel: showLimit ? (limitLabel.isEmpty ? 'LIMIT' : limitLabel) : '',
      limitValueText: _formatInt(snapshot.limits.displaySpeedKph),
      limitDisplayText: limitDisplayText,
      showLimit: showLimit,
      limitCritical: snapshot.limits.isOverLimit,
      limitBlink: snapshot.limits.shouldBlink,
      isCameraLimit: isCameraLimit,
      cameraAlertBlinkOn: cameraAlertBlinkOn,
      connectivityText: connectivityText,
      connectivityDisplayText: connectivityText,
      showConnectivity: showConnectivity,
      hasGpsFix: snapshot.gps.hasFix,
      gpsText: snapshot.gps.hasFix ? 'GPS' : '',
      showGpsBadge: showGpsBadge,
      gapBarCount: snapshot.gap.barCount.clamp(0, 4),
      gapText: gapValue,
      showGap: showGap,
      signalState: snapshot.signals.visualState,
      signalDisplayText: signalDisplayText,
      showSignalState: showSignalState,
      redDot: semanticLive && assistContext && snapshot.signals.redDot,
      cpuText: _formatTemperature(snapshot.device.cpuTempAvgC),
      memText: _formatPercent(snapshot.device.memUsagePct),
      auxMetricLabel: auxIsVolt ? 'VOLT' : 'DISK',
      auxMetricText: auxIsVolt
          ? _formatVolt(snapshot.device.voltV)
          : _formatPercent(snapshot.device.diskUsedPct),
      showDeviceMetrics: snapshot.visibility.showDeviceState,
      longActive: snapshot.vehicle.longActive,
      latActive: snapshot.vehicle.latActive,
      isPreview: snapshot.meta.isPreview,
      sourceText: sourceText,
      qualityText: qualityText,
      hostText: (snapshot.source.deviceHost ?? '').trim(),
      compatibilityHint: compatibilityHint,
      compatibilityBadgeText: compatibilityBadgeText,
      showCompatibilityHint: compatibilityHint.isNotEmpty,
      isDegradedMeta: _isDegradedMeta(snapshot),
      tsMonoMs: snapshot.tsMonoMs,
    );
  }

  static String _buildSourceText(OriginalHudSnapshot snapshot) {
    if (snapshot.tsMonoMs <= 0 && !snapshot.meta.isPreview) {
      return 'STBY';
    }
    if (snapshot.meta.isPreview) return 'PREVIEW';
    switch (snapshot.source.transport.trim().toLowerCase()) {
      case 'carrot_linkhud':
      case 'sidecar_hud':
        return 'HUD';
      case 'legacy_ws_carstate':
        return 'COMPAT';
      case 'ssh_fallback':
      case 'fallback':
        return 'FALLBACK';
      case 'unknown':
      case '':
        return 'REMOTE';
      default:
        return 'LIVE';
    }
  }

  static String _buildQualityText(OriginalHudSnapshot snapshot) {
    if (snapshot.meta.isPreview) return 'preview';
    final quality = snapshot.meta.quality.trim();
    return quality.isEmpty ? 'live' : quality;
  }

  static String _buildCompatibilityHint(OriginalHudSnapshot snapshot) {
    final missingCount = snapshot.meta.missingFields.length;
    if (missingCount > 0) {
      return '$missingCount missing';
    }
    if (snapshot.meta.isFallbackMetricsApplied) {
      return 'metric fallback';
    }
    return '';
  }

  static String _buildDriveModeText(OriginalHudSnapshot snapshot) {
    final raw = snapshot.driveMode.nameOriginal.trim().toUpperCase();
    return switch (raw) {
      'ECO' => '에코',
      'SAFE' => '안전',
      'FAST' => '고속',
      _ => '일반',
    };
  }

  static bool _isCameraAlertBlinkOn(int tsMonoMs) {
    if (tsMonoMs <= 0) return false;
    const fullCycleMs = 1600;
    const activeStartMs = 800;
    return tsMonoMs % fullCycleMs >= activeStartMs;
  }

  static bool _shouldShowAssistContext(OriginalHudSnapshot snapshot) {
    if (snapshot.meta.isPreview) return true;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final receivedAtMs = snapshot.source.receivedAtMs;
    final isFresh = receivedAtMs == null ||
        (nowMs - receivedAtMs).abs() <= _assistFreshnessMs;
    final speedClusterKph = snapshot.vehicle.speedClusterKph ?? 0.0;
    final hasMotionContext = speedClusterKph > 1.0;
    return isFresh &&
        (snapshot.vehicle.longActive ||
            snapshot.vehicle.latActive ||
            hasMotionContext);
  }

  static bool _isSemanticLive(OriginalHudSnapshot snapshot) {
    if (snapshot.meta.isPreview) return false;
    final transport = snapshot.source.transport.trim().toLowerCase();
    if (transport != 'sidecar_hud' && transport != 'carrot_linkhud') {
      return false;
    }
    final quality = snapshot.meta.quality.trim().toLowerCase();
    if (quality.isNotEmpty && quality != 'live' && quality != 'semantic') {
      return false;
    }
    final receivedAtMs = snapshot.source.receivedAtMs;
    if (receivedAtMs == null) return false;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return (nowMs - receivedAtMs).abs() <= _assistFreshnessMs;
  }

  static bool _hasMeaningfulDriveMode(OriginalHudSnapshot snapshot) {
    if (!_shouldShowAssistContext(snapshot)) return false;
    final driveModeKind = snapshot.driveMode.kind.trim().toLowerCase();
    if (driveModeKind.isEmpty || driveModeKind == 'hidden') {
      return false;
    }
    final driveModeName = snapshot.driveMode.nameOriginal.trim().toUpperCase();
    final isDefaultPlaceholder = snapshot.driveMode.code == null &&
        driveModeKind == 'normal' &&
        driveModeName == 'NORM';
    if (isDefaultPlaceholder &&
        !snapshot.vehicle.longActive &&
        !snapshot.vehicle.latActive) {
      return false;
    }
    return true;
  }

  static bool _hasMeaningfulLimit(OriginalHudSnapshot snapshot) {
    if (!_shouldShowAssistContext(snapshot)) return false;
    if (snapshot.limits.mode == 'hidden' ||
        snapshot.limits.displaySpeedKph == null) {
      return false;
    }
    final speedClusterKph = snapshot.vehicle.speedClusterKph ?? 0.0;
    final hasActiveAssist =
        snapshot.vehicle.longActive || snapshot.vehicle.latActive;
    final hasMotionContext = speedClusterKph > 1.0;
    final urgentLimitContext = snapshot.limits.isOverLimit ||
        snapshot.limits.shouldBlink ||
        snapshot.limits.mode == 'camera';
    return hasActiveAssist || hasMotionContext || urgentLimitContext;
  }

  static String _buildLimitDisplayText(OriginalHudSnapshot snapshot) {
    final speedText = _formatInt(snapshot.limits.displaySpeedKph);
    final rawLabel = (snapshot.limits.label ?? '').trim();
    final upperLabel = rawLabel.toUpperCase();
    final isSection = rawLabel.contains('구간') ||
        upperLabel.contains('SECTION') ||
        upperLabel.contains('AVG');
    final baseLabel = snapshot.limits.isOverLimit
        ? '과속중'
        : isSection
            ? '구간'
            : snapshot.limits.mode == 'camera'
                ? 'CAM'
                : 'LIMIT';
    if (snapshot.limits.displaySpeedKph == null) {
      return '$baseLabel --';
    }
    return '$baseLabel $speedText';
  }

  static String _buildConnectivityText(OriginalHudSnapshot snapshot) {
    final badge = (snapshot.connectivity.badgeLabel ?? '').trim().toUpperCase();
    final mode = snapshot.connectivity.badgeMode.trim().toLowerCase();
    if (badge == 'APN' || mode == 'apn') return 'APN';
    if (badge == 'APM' || mode == 'apm') return 'APM';
    return '';
  }

  static String _buildSignalDisplayText(OriginalHudSnapshot snapshot) {
    final normalized = snapshot.signals.visualState.trim().toLowerCase();
    return switch (normalized) {
      'red' => '적색',
      'green' => '녹색',
      'yellow' => '황색',
      _ => '없음',
    };
  }

  static String _buildCompatibilityBadgeText(OriginalHudSnapshot snapshot) {
    final missingCount = snapshot.meta.missingFields.length;
    if (missingCount > 0) {
      return '$missingCount miss';
    }
    if (snapshot.meta.isFallbackMetricsApplied) {
      return 'fallback';
    }
    return '';
  }

  static bool _isDegradedMeta(OriginalHudSnapshot snapshot) {
    if (snapshot.meta.isPreview) return true;

    final transport = snapshot.source.transport.trim().toLowerCase();
    if (transport == 'legacy_ws_carstate' ||
        transport == 'ssh_fallback' ||
        transport == 'fallback') {
      return true;
    }

    final quality = snapshot.meta.quality.trim().toLowerCase();
    if (quality.isNotEmpty && quality != 'live') {
      return true;
    }

    return snapshot.meta.missingFields.isNotEmpty ||
        snapshot.meta.isFallbackMetricsApplied;
  }

  static String _formatInt(double? value) {
    if (value == null) return '--';
    return '${value.round()}';
  }

  static String _formatTemperature(double? value) {
    if (value == null) return '--°C';
    return '${value.toStringAsFixed(0)}°C';
  }

  static String _formatPercent(double? value) {
    if (value == null) return '--%';
    return '${value.toStringAsFixed(0)}%';
  }

  static String _formatVolt(double? value) {
    if (value == null) return '--.-V';
    return '${value.toStringAsFixed(1)}V';
  }

  static bool _safeHasText(String? value) => (value ?? '').trim().isNotEmpty;
}
