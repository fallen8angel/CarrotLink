import 'dart:convert';
import 'dart:ui';

import '../presentation/models/yolo_debug_settings.dart';

class YoloNativeConfigPayloadBuilder {
  YoloNativeConfigPayloadBuilder._();

  static Map<String, dynamic> build({
    required YoloDebugSettings settings,
    required String camera,
    required Size sourceSize,
    String? runtimeBackend,
    String? modelVariant,
    int inputWidth = 416,
    int inputHeight = 416,
    int samplePeriodMs = 200,
  }) {
    return <String, dynamic>{
      ...settings.toJson(),
      'runtimeBackend': runtimeBackend ?? settings.runtimeBackend.wireValue,
      'modelVariant': modelVariant ?? settings.modelVariant.wireValue,
      'camera': camera,
      'sourceWidth': sourceSize.width.round(),
      'sourceHeight': sourceSize.height.round(),
      'inputWidth': inputWidth,
      'inputHeight': inputHeight,
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
