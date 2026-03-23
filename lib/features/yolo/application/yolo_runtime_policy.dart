import '../domain/entities/yolo_model_variant.dart';
import '../domain/entities/yolo_runtime_backend.dart';
import '../presentation/models/yolo_debug_settings.dart';
import 'yolo_device_profile_service.dart';
import 'yolo_runtime_status_store.dart';

class YoloRuntimePolicy {
  YoloRuntimePolicy._();

  static Future<YoloDebugSettings> recommendedDefaults({
    YoloDebugSettings base = YoloDebugSettings.empty,
  }) async {
    await YoloDeviceProfileService.load();
    const backend = YoloRuntimeBackend.liteRtGpu;
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
    final rawBlocker =
        snapshot.state['runtimeBlocker'] ?? snapshot.state['blocker'];
    final blocker = rawBlocker?.toString().trim().toLowerCase() ?? '';
    if (settings.runtimeBackend == YoloRuntimeBackend.liteRtNpu ||
        settings.runtimeBackend == YoloRuntimeBackend.liteRtGpu) {
      return false;
    }
    if (settings.runtimeBackend == YoloRuntimeBackend.liteRtCpu) {
      return blocker == 'model_not_found' ||
          blocker == 'litert_model_not_found' ||
          blocker == 'litert_compiled_model_load_failed' ||
          blocker == 'litert_buffer_alloc_failed' ||
          blocker == 'litert_interpreter_load_failed' ||
          blocker == 'litert_init_failed' ||
          blocker == 'litert_inference_failed';
    }
    return false;
  }

  static YoloDebugSettings fallbackToLiteRtCpu(YoloDebugSettings settings) {
    return settings.copyWith(
      runtimeBackend: YoloRuntimeBackend.liteRtCpu,
      modelVariant: settings.modelVariant.liteRtVariant,
    );
  }

  static YoloDebugSettings fallbackToExecuTorchXnnpack(
    YoloDebugSettings settings,
  ) {
    final normalized = _normalizeBackendModelPair(settings);
    return normalized.copyWith(
      runtimeBackend: YoloRuntimeBackend.executorchXnnpack,
      modelVariant: normalized.modelVariant.genericVariant,
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
    if (settings.runtimeBackend == YoloRuntimeBackend.executorchXnnpack &&
        settings.modelVariant.isLiteRt) {
      return settings.copyWith(
        modelVariant: settings.modelVariant.genericVariant,
      );
    }
    return settings;
  }
}
