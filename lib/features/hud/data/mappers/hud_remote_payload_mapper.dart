import 'dart:math' as math;

import '../../domain/entities/hud_connectivity_state.dart';
import '../../domain/entities/hud_device_metrics_state.dart';
import '../../domain/entities/hud_drive_mode_state.dart';
import '../../domain/entities/hud_gps_state.dart';
import '../../domain/entities/hud_limit_state.dart';
import '../../domain/entities/hud_signal_state.dart';
import '../../domain/entities/hud_temp_control_state.dart';
import '../../domain/entities/hud_visibility_state.dart';
import '../../domain/entities/original_hud_snapshot.dart';

class HudRemotePayloadMapper {
  HudRemotePayloadMapper({
    Stopwatch? clock,
  }) : _clock = clock ?? (Stopwatch()..start());

  final Stopwatch _clock;

  OriginalHudSnapshot map({
    required Map<String, dynamic> raw,
    required String host,
    int? endpointPort,
    String? endpointPath,
    int? receivedAtMs,
  }) {
    if (_looksLikeSemanticSnapshot(raw)) {
      return _mapSemantic(
        raw,
        host,
        endpointPort: endpointPort,
        endpointPath: endpointPath,
        receivedAtMs: receivedAtMs,
      );
    }
    return _mapLegacy(
      raw,
      host,
      endpointPort: endpointPort,
      endpointPath: endpointPath,
      receivedAtMs: receivedAtMs,
    );
  }

  bool _looksLikeSemanticSnapshot(Map<String, dynamic> raw) {
    return raw['vehicle'] is Map || raw['tempControl'] is Map;
  }

  OriginalHudSnapshot _mapSemantic(
    Map<String, dynamic> raw,
    String host, {
    int? endpointPort,
    String? endpointPath,
    int? receivedAtMs,
  }) {
    final source = _asMap(raw['source']);
    final vehicle = _asMap(raw['vehicle']);
    final tempControl = _asMap(raw['tempControl']);
    final driveMode = _asMap(raw['driveMode']);
    final gap = _asMap(raw['gap']);
    final limits = _asMap(raw['limits']);
    final connectivity = _asMap(raw['connectivity']);
    final signals = _asMap(raw['signals']);
    final gps = _asMap(raw['gps']);
    final device = _asMap(raw['device']);
    final visibility = _asMap(raw['visibility']);
    final meta = _asMap(raw['meta']);

    return OriginalHudSnapshot(
      version: _asInt(raw['version']) ?? 1,
      tsMonoMs: _asInt(raw['tsMonoMs']) ?? _clock.elapsedMilliseconds,
      source: HudSourceInfo(
        transport: _asString(source?['transport']) ?? 'sidecar_hud',
        deviceHost: _asString(source?['deviceHost']) ?? host,
        endpointPort: endpointPort,
        endpointPath: endpointPath,
        receivedAtMs: receivedAtMs,
      ),
      vehicle: HudVehicleState(
        speedClusterKph: _asDouble(vehicle?['speedClusterKph']),
        setSpeedClusterKph: _asDouble(vehicle?['setSpeedClusterKph']),
        speedClusterMps: _asDouble(vehicle?['speedClusterMps']),
        setSpeedClusterMps: _asDouble(vehicle?['setSpeedClusterMps']),
        gearText: _asString(vehicle?['gearText']) ?? 'U',
        longActive: _asBool(vehicle?['longActive']),
        latActive: _asBool(vehicle?['latActive']),
      ),
      tempControl: HudTempControlState(
        mode: _asString(tempControl?['mode']) ?? 'hidden',
        label: _asNullableString(tempControl?['label']),
        speedKph: _asDouble(tempControl?['speedKph']),
        sourceRaw: _asNullableString(tempControl?['sourceRaw']),
        applySpeedKph: _asDouble(tempControl?['applySpeedKph']),
        cruiseTargetKph: _asDouble(tempControl?['cruiseTargetKph']),
        isDecel: _asBool(tempControl?['isDecel']),
      ),
      driveMode: _buildDriveMode(
        code: _asInt(driveMode?['code']),
        nameOriginal: _asString(driveMode?['nameOriginal']),
        kind: _asString(driveMode?['kind']),
      ),
      gap: HudGapState(
        personalityRaw: _asInt(gap?['personalityRaw']),
        displayValue: _asInt(gap?['displayValue']) ?? 0,
        barCount: _asInt(gap?['barCount']) ?? 0,
      ),
      limits: _buildLimits(
        mode: _asString(limits?['mode']),
        label: _asString(limits?['label']),
        displaySpeedKph: _asDouble(limits?['displaySpeedKph']),
        roadLimitSpeedKph: _asDouble(limits?['roadLimitSpeedKph']),
        cameraLimitSpeedKph: _asDouble(limits?['cameraLimitSpeedKph']),
        cameraSignType: _asInt(limits?['cameraSignType']),
        isOverLimit: _asBool(limits?['isOverLimit']),
        shouldBlink: _asBool(limits?['shouldBlink']),
        currentSpeedKph: _asDouble(vehicle?['speedClusterKph']),
      ),
      connectivity: _buildConnectivity(
        activeCarrot: _asInt(connectivity?['activeCarrot']),
        badgeMode: _asString(connectivity?['badgeMode']),
        badgeLabel: _asString(connectivity?['badgeLabel']),
      ),
      signals: _buildSignals(
        trafficStateLp: _asInt(signals?['trafficStateLp']),
        trafficStateCarrot: _asInt(signals?['trafficStateCarrot']),
        visualState: _asString(signals?['visualState']),
        redDot: _asBool(signals?['redDot']),
      ),
      gps: HudGpsState(
        hasFix: _asBool(gps?['hasFix']),
        provider: _asNullableString(gps?['provider']),
      ),
      device: HudDeviceMetricsState(
        cpuTempAvgC: _asDouble(device?['cpuTempAvgC']),
        cpuTempMaxC: _asDouble(device?['cpuTempMaxC']),
        memUsagePct: _asDouble(device?['memUsagePct']),
        diskUsedPct: _asDouble(device?['diskUsedPct']),
        freeSpacePct: _asDouble(device?['freeSpacePct']),
        voltV: _asDouble(device?['voltV']),
        metricPrimaryMode: _asString(device?['metricPrimaryMode']) ?? 'disk',
      ),
      visibility: HudVisibilityState(
        showDeviceState:
            _asBool(visibility?['showDeviceState'], fallback: true),
        showDateTimeMode: _asInt(visibility?['showDateTimeMode']),
      ),
      meta: HudMetaState(
        isPreview: _asBool(meta?['isPreview']),
        isFallbackMetricsApplied: _asBool(meta?['isFallbackMetricsApplied']),
        missingFields: _stringList(meta?['missingFields']),
        quality: _asString(meta?['quality']) ?? 'live',
      ),
    );
  }

  OriginalHudSnapshot _mapLegacy(
    Map<String, dynamic> raw,
    String host, {
    int? endpointPort,
    String? endpointPath,
    int? receivedAtMs,
  }) {
    final missingFields = <String>{
      'connectivity.activeCarrot',
      'gps.hasFix',
      'limits.cameraLimitSpeedKph',
      'limits.cameraSignType',
      'signals.trafficStateLp',
      'signals.trafficStateCarrot',
      'visibility.showDeviceState',
      'visibility.showDateTimeMode',
    };

    final rawVego = _asDouble(raw['vEgo']);
    final rawVegoKph = rawVego == null ? null : rawVego * 3.6;
    final speedClusterKph = _asDouble(raw['vEgoKph']) ?? rawVegoKph;
    final setSpeedClusterKph =
        _asDouble(raw['vSetKph']) ?? _asDouble(raw['setSpeedClusterKph']);
    final diskLabel = (_asString(raw['diskLabel']) ?? 'DISK').toUpperCase();
    final diskOrVolt = _asDouble(raw['diskPct']);
    final rawTemp = _asMap(raw['temp']);
    final tempSourceRaw = _asNullableString(rawTemp?['source']) ??
        _asNullableString(raw['tempSource']);
    final applySpeedKph =
        _asDouble(rawTemp?['speed']) ?? _asDouble(raw['applySpeedKph']);
    final cruiseTargetKph = _asDouble(raw['cruiseTargetKph']);

    return OriginalHudSnapshot(
      tsMonoMs: _clock.elapsedMilliseconds,
      source: HudSourceInfo(
        transport: 'legacy_ws_carstate',
        deviceHost: host,
        endpointPort: endpointPort,
        endpointPath: endpointPath,
        receivedAtMs: receivedAtMs,
      ),
      vehicle: HudVehicleState(
        speedClusterKph: speedClusterKph,
        setSpeedClusterKph: setSpeedClusterKph,
        speedClusterMps: speedClusterKph == null ? null : speedClusterKph / 3.6,
        setSpeedClusterMps:
            setSpeedClusterKph == null ? null : setSpeedClusterKph / 3.6,
        gearText: _asString(raw['gear']) ?? 'U',
        longActive: _asBool(raw['longActive']) || _asBool(raw['enabled']),
        latActive: _asBool(raw['latActive']),
      ),
      tempControl: _buildTempControl(
        sourceRaw: tempSourceRaw,
        applySpeedKph: applySpeedKph,
        cruiseTargetKph: cruiseTargetKph,
        setSpeedClusterKph: setSpeedClusterKph,
        isDecel: _asBool(rawTemp?['is_decel']) || _asBool(raw['tempIsDecel']),
      ),
      driveMode: _buildDriveMode(
        code: _asInt(raw['driveModeCode']) ?? _asInt(raw['myDrivingMode']),
        nameOriginal: _asString(_asMap(raw['driveMode'])?['name']) ??
            _asString(raw['driveModeName']),
        kind: _asString(_asMap(raw['driveMode'])?['kind']) ??
            _asString(raw['driveModeKind']),
      ),
      gap: _buildGap(
        tfBars: _asInt(raw['tfBars']),
        tfGap: _asInt(raw['tfGap']),
      ),
      limits: _buildLimits(
        mode: _asString(raw['limitMode']),
        label: _asString(raw['limitLabel']),
        displaySpeedKph: _asDouble(raw['speedLimitKph']) ??
            _asDouble(raw['displaySpeedKph']),
        roadLimitSpeedKph: _asDouble(raw['roadLimitSpeedKph']) ??
            _asDouble(raw['speedLimitKph']),
        cameraLimitSpeedKph: _asDouble(raw['cameraLimitSpeedKph']),
        cameraSignType: _asInt(raw['cameraSignType']),
        isOverLimit: _asBool(raw['speedLimitOver']),
        shouldBlink: _asBool(raw['speedLimitBlink']),
        currentSpeedKph: speedClusterKph,
      ),
      connectivity: _buildConnectivity(
        activeCarrot: _asInt(raw['activeCarrot']),
        badgeMode: _asString(raw['badgeMode']),
        badgeLabel: _asNullableString(raw['badgeLabel']),
      ),
      signals: _buildSignals(
        trafficStateLp: _asInt(raw['trafficStateLp']),
        trafficStateCarrot: _asInt(raw['trafficStateCarrot']),
        visualState: _asString(raw['tlight']) ?? _asString(raw['visualState']),
        redDot: _asBool(raw['redDot']),
      ),
      gps: const HudGpsState(
        hasFix: false,
      ),
      device: HudDeviceMetricsState(
        cpuTempAvgC: _asAverageDouble(raw['cpuTempC']) ??
            _asAverageDouble(raw['cpuTemp']) ??
            _asAverageDouble(raw['cpu_temp_c']),
        cpuTempMaxC: _asMaxDouble(raw['cpuTempC']) ??
            _asMaxDouble(raw['cpuTemp']) ??
            _asMaxDouble(raw['cpu_temp_c']),
        memUsagePct: _asDouble(raw['memPct']) ??
            _asDouble(raw['mem']) ??
            _asDouble(raw['memoryUsagePercent']),
        diskUsedPct:
            diskLabel == 'DISK' ? diskOrVolt : _asDouble(raw['diskUsedPct']),
        freeSpacePct: _asDouble(raw['freeSpacePct']),
        voltV: diskLabel == 'VOLT' ? diskOrVolt : _asDouble(raw['voltV']),
        metricPrimaryMode: diskLabel == 'VOLT' ? 'volt' : 'disk',
      ),
      visibility: const HudVisibilityState(
        showDeviceState: true,
      ),
      meta: HudMetaState(
        missingFields: missingFields.toList()..sort(),
        quality: 'compat',
      ),
    );
  }

  HudGapState _buildGap({
    required int? tfBars,
    required int? tfGap,
  }) {
    final displayValue = tfBars ?? tfGap ?? 0;
    final raw = displayValue > 0 ? displayValue - 1 : null;
    return HudGapState(
      personalityRaw: raw,
      displayValue: displayValue,
      barCount: math.max(0, displayValue),
    );
  }

  HudTempControlState _buildTempControl({
    required String? sourceRaw,
    required double? applySpeedKph,
    required double? cruiseTargetKph,
    required double? setSpeedClusterKph,
    required bool isDecel,
  }) {
    if ((sourceRaw?.isNotEmpty ?? false) && applySpeedKph != null) {
      return HudTempControlState(
        mode: 'apply',
        label: sourceRaw,
        speedKph: applySpeedKph,
        sourceRaw: sourceRaw,
        applySpeedKph: applySpeedKph,
        cruiseTargetKph: cruiseTargetKph,
        isDecel: isDecel,
      );
    }

    if (cruiseTargetKph != null &&
        setSpeedClusterKph != null &&
        (cruiseTargetKph - setSpeedClusterKph).abs() >= 0.5) {
      return HudTempControlState(
        mode: 'eco',
        label: 'eco',
        speedKph: cruiseTargetKph,
        sourceRaw: sourceRaw,
        applySpeedKph: applySpeedKph,
        cruiseTargetKph: cruiseTargetKph,
        isDecel: isDecel,
      );
    }

    return HudTempControlState(
      sourceRaw: sourceRaw,
      applySpeedKph: applySpeedKph,
      cruiseTargetKph: cruiseTargetKph,
      isDecel: isDecel,
    );
  }

  HudDriveModeState _buildDriveMode({
    required int? code,
    required String? nameOriginal,
    required String? kind,
  }) {
    final normalizedCode = code ?? _codeFromDriveMode(nameOriginal, kind);
    switch (normalizedCode) {
      case 1:
        return const HudDriveModeState(
          code: 1,
          nameOriginal: 'ECO',
          kind: 'eco',
        );
      case 2:
        return const HudDriveModeState(
          code: 2,
          nameOriginal: 'SAFE',
          kind: 'safe',
        );
      case 4:
        return const HudDriveModeState(
          code: 4,
          nameOriginal: 'FAST',
          kind: 'fast',
        );
      default:
        return const HudDriveModeState(
          code: 3,
          nameOriginal: 'NORM',
          kind: 'normal',
        );
    }
  }

  int _codeFromDriveMode(String? nameOriginal, String? kind) {
    final token = '${nameOriginal ?? ''} ${kind ?? ''}'.toLowerCase();
    if (token.contains('eco')) return 1;
    if (token.contains('safe')) return 2;
    if (token.contains('sport') || token.contains('fast')) return 4;
    return 3;
  }

  HudConnectivityState _buildConnectivity({
    required int? activeCarrot,
    required String? badgeMode,
    required String? badgeLabel,
  }) {
    final normalizedMode = (badgeMode ?? '').trim().toLowerCase();
    if (normalizedMode == 'apn' || normalizedMode == 'apm') {
      return HudConnectivityState(
        activeCarrot: activeCarrot,
        badgeMode: normalizedMode,
        badgeLabel: badgeLabel ?? normalizedMode.toUpperCase(),
      );
    }
    if (activeCarrot != null) {
      if (activeCarrot >= 2) {
        return HudConnectivityState(
          activeCarrot: activeCarrot,
          badgeMode: 'apn',
          badgeLabel: 'APN',
        );
      }
      if (activeCarrot >= 1) {
        return HudConnectivityState(
          activeCarrot: activeCarrot,
          badgeMode: 'apm',
          badgeLabel: 'APM',
        );
      }
    }
    return HudConnectivityState(
      activeCarrot: activeCarrot,
    );
  }

  HudLimitState _buildLimits({
    required String? mode,
    required String? label,
    required double? displaySpeedKph,
    required double? roadLimitSpeedKph,
    required double? cameraLimitSpeedKph,
    required int? cameraSignType,
    required bool isOverLimit,
    required bool shouldBlink,
    required double? currentSpeedKph,
  }) {
    final explicitMode = (mode ?? '').trim().toLowerCase();
    final normalizedLabel = (label ?? '').trim().toUpperCase();
    final resolvedMode = explicitMode.isNotEmpty
        ? explicitMode
        : (cameraLimitSpeedKph != null && cameraLimitSpeedKph > 0
            ? 'camera'
            : (roadLimitSpeedKph != null && roadLimitSpeedKph > 0
                ? 'limit'
                : (displaySpeedKph != null && displaySpeedKph > 0
                    ? (normalizedLabel == 'CAM' ? 'camera' : 'limit')
                    : 'hidden')));

    final resolvedDisplay = switch (resolvedMode) {
      'camera' => cameraLimitSpeedKph ?? displaySpeedKph,
      'limit' => roadLimitSpeedKph ?? displaySpeedKph,
      _ => null,
    };
    final computedOverLimit = resolvedDisplay != null && currentSpeedKph != null
        ? currentSpeedKph > (resolvedDisplay + 2.0)
        : isOverLimit;

    return HudLimitState(
      mode: resolvedMode,
      label: resolvedMode == 'hidden'
          ? null
          : (normalizedLabel.isNotEmpty
              ? normalizedLabel
              : (resolvedMode == 'camera' ? 'CAM' : 'LIMIT')),
      displaySpeedKph: resolvedDisplay,
      roadLimitSpeedKph: roadLimitSpeedKph,
      cameraLimitSpeedKph: cameraLimitSpeedKph,
      cameraSignType: cameraSignType,
      isOverLimit: computedOverLimit,
      shouldBlink: shouldBlink || resolvedMode == 'camera',
    );
  }

  HudSignalState _buildSignals({
    required int? trafficStateLp,
    required int? trafficStateCarrot,
    required String? visualState,
    required bool redDot,
  }) {
    final normalized = (visualState ?? '').trim().toLowerCase();
    final resolvedVisualState = switch (normalized) {
      'red' || 'stop' => 'red',
      'green' || 'go' => 'green',
      'yellow' || 'amber' => 'yellow',
      'off' || 'none' || '' => redDot ? 'red' : 'off',
      _ => redDot ? 'red' : normalized,
    };

    return HudSignalState(
      trafficStateLp: trafficStateLp,
      trafficStateCarrot: trafficStateCarrot,
      visualState: resolvedVisualState,
      redDot: redDot,
    );
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return null;
  }

  double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  double? _asAverageDouble(dynamic value) {
    if (value is Iterable) {
      var sum = 0.0;
      var count = 0;
      for (final item in value) {
        final parsed = _asDouble(item);
        if (parsed == null) continue;
        sum += parsed;
        count += 1;
      }
      if (count > 0) {
        return sum / count;
      }
      return null;
    }
    return _asDouble(value);
  }

  double? _asMaxDouble(dynamic value) {
    if (value is Iterable) {
      double? maxValue;
      for (final item in value) {
        final parsed = _asDouble(item);
        if (parsed == null) continue;
        maxValue = maxValue == null ? parsed : math.max(maxValue, parsed);
      }
      return maxValue;
    }
    return _asDouble(value);
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  bool _asBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
        return true;
      }
      if (normalized == 'false' || normalized == '0' || normalized == 'no') {
        return false;
      }
    }
    return fallback;
  }

  String? _asNullableString(dynamic value) {
    final text = _asString(value);
    if (text == null || text.trim().isEmpty) {
      return null;
    }
    return text;
  }

  String? _asString(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return text;
  }

  List<String> _stringList(dynamic value) {
    if (value is Iterable) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }
}
