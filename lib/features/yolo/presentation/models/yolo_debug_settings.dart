import '../../domain/entities/yolo_model_variant.dart';
import '../../domain/entities/yolo_runtime_backend.dart';

class YoloDebugSettings {
  final bool enabled;
  final bool unsafeRuntimeEnabled;
  final YoloRuntimeBackend runtimeBackend;
  final YoloModelVariant modelVariant;
  final bool showBoxes;
  final bool showLabels;
  final bool showTrafficLights;
  final bool showStats;

  const YoloDebugSettings({
    this.enabled = false,
    this.unsafeRuntimeEnabled = false,
    this.runtimeBackend = YoloRuntimeBackend.executorchQnn,
    this.modelVariant = YoloModelVariant.yolo26n,
    this.showBoxes = false,
    this.showLabels = false,
    this.showTrafficLights = false,
    this.showStats = false,
  });

  static const empty = YoloDebugSettings();

  YoloDebugSettings copyWith({
    bool? enabled,
    bool? unsafeRuntimeEnabled,
    YoloRuntimeBackend? runtimeBackend,
    YoloModelVariant? modelVariant,
    bool? showBoxes,
    bool? showLabels,
    bool? showTrafficLights,
    bool? showStats,
  }) {
    return YoloDebugSettings(
      enabled: enabled ?? this.enabled,
      unsafeRuntimeEnabled: unsafeRuntimeEnabled ?? this.unsafeRuntimeEnabled,
      runtimeBackend: runtimeBackend ?? this.runtimeBackend,
      modelVariant: modelVariant ?? this.modelVariant,
      showBoxes: showBoxes ?? this.showBoxes,
      showLabels: showLabels ?? this.showLabels,
      showTrafficLights: showTrafficLights ?? this.showTrafficLights,
      showStats: showStats ?? this.showStats,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'yoloEnabled': enabled,
      'unsafeRuntimeEnabled': unsafeRuntimeEnabled,
      'runtimeBackend': runtimeBackend.wireValue,
      'modelVariant': modelVariant.wireValue,
      'yoloBoxes': showBoxes,
      'yoloLabels': showLabels,
      'yoloTrafficLights': showTrafficLights,
      'yoloStats': showStats,
    };
  }

  factory YoloDebugSettings.fromJson(Map<String, dynamic> json) {
    bool readBool(String key) {
      final value = json[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'true' || normalized == '1') return true;
      }
      return false;
    }

    return YoloDebugSettings(
      enabled: readBool('yoloEnabled'),
      unsafeRuntimeEnabled: readBool('unsafeRuntimeEnabled'),
      runtimeBackend: YoloRuntimeBackend.fromWireValue(
        json['runtimeBackend']?.toString(),
      ),
      modelVariant: YoloModelVariant.fromWireValue(
        json['modelVariant']?.toString(),
      ),
      showBoxes: readBool('yoloBoxes'),
      showLabels: readBool('yoloLabels'),
      showTrafficLights: readBool('yoloTrafficLights'),
      showStats: readBool('yoloStats'),
    );
  }
}
