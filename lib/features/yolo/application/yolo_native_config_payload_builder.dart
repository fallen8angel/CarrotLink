import 'dart:convert';
import 'dart:ui';

import '../domain/entities/yolo_model_variant.dart';
import '../presentation/models/yolo_debug_settings.dart';

class YoloNativeConfigPayloadBuilder {
  YoloNativeConfigPayloadBuilder._();

  /// Default input size per model variant.
  /// yolo26n: 416×416 (needs resolution to compensate weaker features).
  /// yolo26s: 352×352 (stronger features, lower resolution for speed parity).
  static int defaultInputSizeFor(YoloModelVariant variant) {
    return variant.isLargeModel ? 352 : 416;
  }

  static Map<String, dynamic> build({
    required YoloDebugSettings settings,
    required String camera,
    required Size sourceSize,
    String? runtimeBackend,
    String? modelVariant,
    int? inputWidth,
    int? inputHeight,
    int samplePeriodMs = 60,
  }) {
    final effectiveVariant = modelVariant != null
        ? YoloModelVariant.fromWireValue(modelVariant)
        : settings.modelVariant;
    final defaultSize = defaultInputSizeFor(effectiveVariant);
    return <String, dynamic>{
      ...settings.toJson(),
      'runtimeBackend': runtimeBackend ?? settings.runtimeBackend.wireValue,
      'modelVariant': modelVariant ?? settings.modelVariant.wireValue,
      'camera': camera,
      'sourceWidth': sourceSize.width.round(),
      'sourceHeight': sourceSize.height.round(),
      'inputWidth': inputWidth ?? defaultSize,
      'inputHeight': inputHeight ?? defaultSize,
      'samplePeriodMs': samplePeriodMs,
    };
  }

  static int signature(Map<String, dynamic> payload) {
    try {
      return jsonEncode(payload).hashCode;
    } catch (_) {
      return payload.toString().hashCode;
    }
  }
}
