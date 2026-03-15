import 'package:flutter/services.dart';

import '../domain/entities/yolo_runtime_backend.dart';
import 'yolo_debug_settings_store.dart';
import 'yolo_native_config_payload_builder.dart';
import 'yolo_runtime_status_store.dart';
import '../presentation/models/yolo_debug_settings.dart';

class YoloOfflineDebugRunner {
  YoloOfflineDebugRunner._();

  static const MethodChannel _channel =
      MethodChannel('carrotlink/native_drive_video_control');

  static _OfflineDebugSettingsResolution _resolveOfflineDebugSettings(
    YoloDebugSettings settings,
  ) {
    var effective = settings.copyWith(enabled: true);
    var forcedBoxesVisible = false;
    var forcedRuntimeBackend = false;

    if (!effective.showBoxes && !effective.showLabels) {
      effective = effective.copyWith(showBoxes: true);
      forcedBoxesVisible = true;
    }

    // Generic playback models are still not QNN-lowered, so keep the
    // requested backend for diagnostics instead of silently swapping it.
    if (effective.runtimeBackend == YoloRuntimeBackend.executorchQnn) {
      forcedRuntimeBackend = false;
    }

    return _OfflineDebugSettingsResolution(
      settings: effective,
      forcedBoxesVisible: forcedBoxesVisible,
      forcedRuntimeBackend: forcedRuntimeBackend,
    );
  }

  static void _annotateOfflineSnapshot(
    Map<String, dynamic> config,
    Map<String, dynamic> state, {
    required _OfflineDebugSettingsResolution resolution,
  }) {
    if (resolution.forcedBoxesVisible) {
      config['yoloBoxes'] = true;
      state['yoloBoxes'] = true;
      state['offlineOverlayFallback'] = 'forced_boxes_visible';
      state['offlineOverlayHint'] = 'boxes_enabled_for_playback_visibility';
    }
    if (resolution.forcedRuntimeBackend) {
      state['offlineBackendFallback'] = 'playback_backend_forced';
    }
  }

  static Future<YoloRuntimeStatusSnapshot> runImageFile({
    required String path,
    YoloDebugSettings? settings,
    String camera = 'road',
  }) async {
    final resolution = _resolveOfflineDebugSettings(
      settings ?? await YoloDebugSettingsStore.load(),
    );
    final effectiveSettings = resolution.settings;
    final payload = YoloNativeConfigPayloadBuilder.build(
      settings: effectiveSettings,
      camera: camera,
      sourceSize: const Size(1928, 1208),
    );
    final result = await _channel.invokeMethod<dynamic>(
      'runYoloDebugImageFile',
      <String, dynamic>{
        'path': path,
        'yoloConfig': payload,
      },
    );
    if (result is! Map) {
      throw StateError('invalid_yolo_debug_image_result');
    }
    final mapped = result.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final config = _mapOf(mapped['config']);
    final state = _mapOf(mapped['state']);
    _annotateOfflineSnapshot(
      config,
      state,
      resolution: resolution,
    );
    await YoloRuntimeStatusStore.saveConfig(config);
    await YoloRuntimeStatusStore.saveState(state);
    return YoloRuntimeStatusStore.load();
  }

  static Future<YoloRuntimeStatusSnapshot> runVideoFile({
    required String path,
    YoloDebugSettings? settings,
    String camera = 'road',
    int sampleFrames = 3,
  }) async {
    final resolution = _resolveOfflineDebugSettings(
      settings ?? await YoloDebugSettingsStore.load(),
    );
    final effectiveSettings = resolution.settings;
    final payload = YoloNativeConfigPayloadBuilder.build(
      settings: effectiveSettings,
      camera: camera,
      sourceSize: const Size(1928, 1208),
    );
    final result = await _channel.invokeMethod<dynamic>(
      'runYoloDebugVideoFile',
      <String, dynamic>{
        'path': path,
        'yoloConfig': payload,
        'sampleFrames': sampleFrames,
      },
    );
    if (result is! Map) {
      throw StateError('invalid_yolo_debug_video_result');
    }
    final mapped = result.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final config = _mapOf(mapped['config']);
    final state = _mapOf(mapped['state']);
    _annotateOfflineSnapshot(
      config,
      state,
      resolution: resolution,
    );
    await YoloRuntimeStatusStore.saveConfig(config);
    await YoloRuntimeStatusStore.saveState(state);
    return YoloRuntimeStatusStore.load();
  }

  static Future<YoloRuntimeStatusSnapshot> runVideoFrameAtPosition({
    required String path,
    required Duration position,
    YoloDebugSettings? settings,
    String camera = 'road',
  }) async {
    final resolution = _resolveOfflineDebugSettings(
      settings ?? await YoloDebugSettingsStore.load(),
    );
    final effectiveSettings = resolution.settings;
    final payload = YoloNativeConfigPayloadBuilder.build(
      settings: effectiveSettings,
      camera: camera,
      sourceSize: const Size(1928, 1208),
    );
    final result = await _channel.invokeMethod<dynamic>(
      'runYoloDebugVideoFrame',
      <String, dynamic>{
        'path': path,
        'yoloConfig': payload,
        'positionMs': position.inMilliseconds,
      },
    );
    if (result is! Map) {
      throw StateError('invalid_yolo_debug_video_frame_result');
    }
    final mapped = result.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final config = _mapOf(mapped['config']);
    final state = _mapOf(mapped['state']);
    _annotateOfflineSnapshot(
      config,
      state,
      resolution: resolution,
    );
    await YoloRuntimeStatusStore.saveConfig(config);
    await YoloRuntimeStatusStore.saveState(state);
    return YoloRuntimeStatusStore.load();
  }

  static Future<void> clearVideoPlaybackSession() async {
    await _channel.invokeMethod<void>('clearYoloDebugVideoSession');
  }

  static Map<String, dynamic> _mapOf(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{};
  }
}

class _OfflineDebugSettingsResolution {
  const _OfflineDebugSettingsResolution({
    required this.settings,
    required this.forcedBoxesVisible,
    required this.forcedRuntimeBackend,
  });

  final YoloDebugSettings settings;
  final bool forcedBoxesVisible;
  final bool forcedRuntimeBackend;
}
