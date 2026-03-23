import 'yolo_runtime_backend.dart';

enum YoloModelFamily {
  liteRt(
    groupLabel: 'LiteRT',
    shortLabel: 'litert',
    selectorDescription: 'LiteRT .tflite — GPU(OpenCL) or CPU',
  ),
  genericExecutorch(
    groupLabel: 'Generic ExecuTorch',
    shortLabel: 'generic',
    selectorDescription: 'generic ExecuTorch/XNNPACK .pte',
  );

  const YoloModelFamily({
    required this.groupLabel,
    required this.shortLabel,
    required this.selectorDescription,
  });

  final String groupLabel;
  final String shortLabel;
  final String selectorDescription;
}

enum YoloModelVariant {
  yolo26nLiteRt(
    wireValue: 'yolo26n_litert',
    label: 'YOLO26n LiteRT',
    family: YoloModelFamily.liteRt,
    wireAliases: <String>[
      'yolo26n_litert',
      'yolo26n_tflite',
      'yolo26n_gpu',
      'yolo26n_fp16',
      'yolo26n_float16',
    ],
    assetBaseNames: <String>[
      'yolo26n_float16',
      'yolo26n_fp16',
      'yolo26n_litert',
      'yolo26n',
    ],
  ),
  yolo26sLiteRt(
    wireValue: 'yolo26s_litert',
    label: 'YOLO26s LiteRT',
    family: YoloModelFamily.liteRt,
    wireAliases: <String>[
      'yolo26s_litert',
      'yolo26s_tflite',
      'yolo26s_gpu',
      'yolo26s_fp16',
      'yolo26s_float16',
    ],
    assetBaseNames: <String>[
      'yolo26s_float16',
      'yolo26s_fp16',
      'yolo26s_litert',
      'yolo26s',
    ],
  ),
  yolo26n(
    wireValue: 'yolo26n',
    label: 'YOLO26n',
    family: YoloModelFamily.genericExecutorch,
    wireAliases: <String>['yolo26n'],
    assetBaseNames: <String>['yolo26n'],
  ),
  yolo26s(
    wireValue: 'yolo26s',
    label: 'YOLO26s',
    family: YoloModelFamily.genericExecutorch,
    wireAliases: <String>['yolo26s'],
    assetBaseNames: <String>['yolo26s'],
  );

  const YoloModelVariant({
    required this.wireValue,
    required this.label,
    required this.family,
    required this.wireAliases,
    required this.assetBaseNames,
  });

  final String wireValue;
  final String label;
  final YoloModelFamily family;
  final List<String> wireAliases;
  final List<String> assetBaseNames;

  String get settingsLabel => '$label / ${family.shortLabel}';

  bool get isLiteRt => family == YoloModelFamily.liteRt;

  bool get isLargeModel =>
      this == YoloModelVariant.yolo26s ||
      this == YoloModelVariant.yolo26sLiteRt;

  YoloModelVariant get genericVariant {
    switch (this) {
      case YoloModelVariant.yolo26nLiteRt:
      case YoloModelVariant.yolo26n:
        return YoloModelVariant.yolo26n;
      case YoloModelVariant.yolo26sLiteRt:
      case YoloModelVariant.yolo26s:
        return YoloModelVariant.yolo26s;
    }
  }

  YoloModelVariant get liteRtVariant {
    switch (this) {
      case YoloModelVariant.yolo26nLiteRt:
      case YoloModelVariant.yolo26n:
        return YoloModelVariant.yolo26nLiteRt;
      case YoloModelVariant.yolo26sLiteRt:
      case YoloModelVariant.yolo26s:
        return YoloModelVariant.yolo26sLiteRt;
    }
  }

  String get primaryAssetFileName => isLiteRt
      ? '${assetBaseNames.first}.tflite'
      : '${assetBaseNames.first}.pte';

  String get assetFileHint {
    final ext = isLiteRt ? '.tflite' : '.pte';
    return assetBaseNames.take(3).map((name) => '$name$ext').join(' / ');
  }

  String selectorSubtitle({
    required YoloRuntimeBackend backend,
  }) {
    if (isLiteRt) {
      return '${family.selectorDescription} · 예: $assetFileHint';
    }
    final base = family.selectorDescription;
    if (backend.isLiteRt) {
      return '$base · XNNPACK backend에서 사용';
    }
    return base;
  }

  static YoloModelVariant fromWireValue(String? raw) {
    final normalized = _normalize(raw);
    final compact = _compact(normalized);
    for (final variant in values) {
      if (variant._matches(normalized, compact)) {
        return variant;
      }
    }
    return YoloModelVariant.yolo26nLiteRt;
  }

  bool _matches(String normalized, String compact) {
    if (normalized.isEmpty) return false;
    for (final alias in wireAliases) {
      final aliasNormalized = _normalize(alias);
      if (normalized == aliasNormalized) {
        return true;
      }
      if (compact == _compact(aliasNormalized)) {
        return true;
      }
    }
    return false;
  }

  static String _normalize(String? raw) {
    var value = raw?.trim().toLowerCase() ?? '';
    if (value.endsWith('.pte')) {
      value = value.substring(0, value.length - 4);
    }
    if (value.endsWith('.tflite')) {
      value = value.substring(0, value.length - 7);
    }
    return value;
  }

  static String _compact(String raw) {
    return raw.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }
}

class YoloModelSelectorChoice {
  const YoloModelSelectorChoice({
    required this.title,
    required this.subtitle,
    required this.enabled,
    this.variant,
  });

  final String title;
  final String subtitle;
  final bool enabled;
  final YoloModelVariant? variant;
}

Map<String, List<YoloModelSelectorChoice>> buildYoloModelSelectorSections({
  required YoloRuntimeBackend backend,
}) {
  return <String, List<YoloModelSelectorChoice>>{
    for (final family in YoloModelFamily.values)
      family.groupLabel: [
        for (final variant
            in YoloModelVariant.values.where((value) => value.family == family))
          YoloModelSelectorChoice(
            variant: variant,
            title: variant.label,
            subtitle: variant.selectorSubtitle(backend: backend),
            enabled: backend.isLiteRt ? variant.isLiteRt : !variant.isLiteRt,
          ),
      ],
  };
}
