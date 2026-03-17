import '../domain/entities/yolo_model_variant.dart';
import '../domain/entities/yolo_runtime_backend.dart';
import '../presentation/models/yolo_debug_settings.dart';
import 'yolo_device_profile_service.dart';
import 'yolo_runtime_status_store.dart';

class YoloRuntimePolicy {
  YoloRuntimePolicy._();

  static const Set<String> _qnnFatalBlockers = <String>{
    'backend_environment_unavailable',
    'qnn_backend_bridge_missing',
    'qnn_backend_not_packaged',
    'qnn_delegate_init_failed',
    'qnn_dsp_transport_failed',
    'qnn_env_config_failed',
    'qnn_htp_runtime_missing',
    'qnn_htp_stub_missing',
    'qnn_lowered_runtime_guarded',
    'qnn_model_metadata_incomplete',
    'qnn_model_metadata_invalid',
    'qnn_model_metadata_missing',
    'qnn_model_requires_qnn_backend',
    'qnn_model_variant_mismatch',
    'qnn_runtime_dir_unavailable',
    'qnn_runtime_libs_missing',
    'qnn_sdk_version_mismatch',
    'qnn_skel_assets_missing',
    'qnn_skel_extract_failed',
    'qnn_system_runtime_missing',
  };

  static Future<YoloDebugSettings> recommendedDefaults({
    YoloDebugSettings base = YoloDebugSettings.empty,
  }) async {
    final profile = await YoloDeviceProfileService.load();
    final backend = profile.supportsQnn
        ? YoloRuntimeBackend.liteRtGpu
        : YoloRuntimeBackend.liteRtCpu;
    const model = YoloModelVariant.yolo26nLiteRt;
    return normalizeForProfile(
      base.copyWith(
        runtimeBackend: backend,
        modelVariant: model,
      ),
    );
  }

  static Future<YoloDebugSettings> normalizeForProfile(
    YoloDebugSettings settings,
  ) async {
    var next = _normalizeBackendModelPair(settings);
    // Downgrade large model if not in allowed profile.
    final profile = await YoloDeviceProfileService.load();
    if (!profile.allowsYolo26sByDefault && next.modelVariant.isLargeModel) {
      next = next.copyWith(
        modelVariant: next.runtimeBackend.isLiteRt
            ? YoloModelVariant.yolo26nLiteRt
            : YoloModelVariant.yolo26n,
      );
    }
    return next;
  }

  static bool shouldFallbackFromRuntimeFailure(
    YoloDebugSettings settings,
    YoloRuntimeStatusSnapshot snapshot,
  ) {
    if (settings.runtimeBackend == YoloRuntimeBackend.liteRtGpu) {
      final rawBlocker =
          snapshot.state['runtimeBlocker'] ?? snapshot.state['blocker'];
      final blocker = rawBlocker?.toString().trim().toLowerCase() ?? '';
      return blocker == 'litert_gpu_unsupported' ||
          blocker == 'litert_gpu_delegate_failed' ||
          blocker == 'litert_interpreter_load_failed' ||
          blocker == 'litert_init_failed';
    }
    if (settings.runtimeBackend != YoloRuntimeBackend.executorchQnn) {
      return false;
    }
    final rawBlocker =
        snapshot.state['runtimeBlocker'] ?? snapshot.state['blocker'];
    final blocker = rawBlocker?.toString().trim().toLowerCase() ?? '';
    if (blocker.isEmpty) {
      return false;
    }
    return _qnnFatalBlockers.contains(blocker) || blocker.startsWith('qnn_');
  }

  static bool shouldRememberQnnFailure(
    YoloDebugSettings settings,
    YoloRuntimeStatusSnapshot snapshot,
  ) {
    if (settings.runtimeBackend != YoloRuntimeBackend.executorchQnn) {
      return false;
    }
    return shouldFallbackFromRuntimeFailure(settings, snapshot);
  }

  static bool shouldClearRememberedQnnFailure(
    YoloDebugSettings settings,
    YoloRuntimeStatusSnapshot snapshot,
  ) {
    if (settings.runtimeBackend != YoloRuntimeBackend.executorchQnn) {
      return false;
    }
    final state = snapshot.state;
    final blocker =
        (state['runtimeBlocker'] ?? state['blocker'])?.toString().trim() ?? '';
    final forwardSuccesses = _readInt(state['forwardSuccesses']);
    return forwardSuccesses > 0 && blocker.isEmpty;
  }

  static YoloDebugSettings fallbackFromQnnFailure(YoloDebugSettings settings) {
    final normalized = _normalizeBackendModelPair(settings);
    return normalized.copyWith(
      runtimeBackend: YoloRuntimeBackend.executorchXnnpack,
      modelVariant: normalized.modelVariant.genericVariant,
    );
  }

  static YoloDebugSettings fallbackToLiteRtCpu(YoloDebugSettings settings) {
    return settings.copyWith(
      runtimeBackend: YoloRuntimeBackend.liteRtCpu,
      modelVariant: settings.modelVariant.liteRtVariant,
    );
  }

  static YoloDebugSettings _normalizeBackendModelPair(
    YoloDebugSettings settings,
  ) {
    if (settings.runtimeBackend.isLiteRt && !settings.modelVariant.isLiteRt) {
      return settings.copyWith(
        modelVariant: settings.modelVariant.liteRtVariant,
      );
    }
    if (settings.runtimeBackend == YoloRuntimeBackend.executorchQnn &&
        !settings.modelVariant.isQnnLowered) {
      return settings.copyWith(modelVariant: settings.modelVariant.qnnVariant);
    }
    if (settings.runtimeBackend == YoloRuntimeBackend.executorchXnnpack &&
        (settings.modelVariant.isQnnLowered || settings.modelVariant.isLiteRt)) {
      return settings.copyWith(
        modelVariant: settings.modelVariant.genericVariant,
      );
    }
    return settings;
  }

  static int _readInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }
}
