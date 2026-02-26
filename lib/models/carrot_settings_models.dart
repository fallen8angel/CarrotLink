class CarrotSettingsBundle {
  final String? path;
  final String? apilot;
  final List<int> unitCycle;
  final List<CarrotSettingsGroupMeta> groups;
  final Map<String, List<CarrotSettingItemMeta>> itemsByGroup;

  const CarrotSettingsBundle({
    required this.path,
    required this.apilot,
    required this.unitCycle,
    required this.groups,
    required this.itemsByGroup,
  });

  factory CarrotSettingsBundle.fromJson(Map<String, dynamic> json) {
    final groupsJson = (json['groups'] as List?) ?? const [];
    final groups = groupsJson
        .whereType<Map>()
        .map((e) =>
            CarrotSettingsGroupMeta.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    final itemsByGroup = <String, List<CarrotSettingItemMeta>>{};
    final rawItemsByGroup = json['items_by_group'];
    if (rawItemsByGroup is Map) {
      for (final entry in rawItemsByGroup.entries) {
        final key = entry.key.toString();
        final list = (entry.value as List?) ?? const [];
        itemsByGroup[key] = list
            .whereType<Map>()
            .map((e) =>
                CarrotSettingItemMeta.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    }

    final unitCycle = <int>[];
    final unitCycleJson = (json['unit_cycle'] as List?) ?? const [];
    for (final v in unitCycleJson) {
      final parsed = _asInt(v);
      if (parsed != null) unitCycle.add(parsed);
    }

    return CarrotSettingsBundle(
      path: json['path']?.toString(),
      apilot: json['apilot']?.toString(),
      unitCycle: unitCycle.isEmpty ? const [1, 2, 5, 10, 50, 100] : unitCycle,
      groups: groups,
      itemsByGroup: itemsByGroup,
    );
  }
}

class CarrotSettingsGroupMeta {
  final String group;
  final String? egroup;
  final String? cgroup;
  final int count;

  const CarrotSettingsGroupMeta({
    required this.group,
    required this.egroup,
    required this.cgroup,
    required this.count,
  });

  factory CarrotSettingsGroupMeta.fromJson(Map<String, dynamic> json) {
    return CarrotSettingsGroupMeta(
      group: (json['group'] ?? '').toString(),
      egroup: json['egroup']?.toString(),
      cgroup: json['cgroup']?.toString(),
      count: _asInt(json['count']) ?? 0,
    );
  }

  String get displayName => group.isNotEmpty ? group : '-';

  String? get subtitle {
    return null;
  }
}

class CarrotSettingItemMeta {
  final String group;
  final String name;
  final String? title;
  final String? descr;
  final String? etitle;
  final String? edescr;
  final String? ctitle;
  final String? cdescr;
  final num? min;
  final num? max;
  final dynamic defaultValue;
  final int? unit;

  const CarrotSettingItemMeta({
    required this.group,
    required this.name,
    required this.title,
    required this.descr,
    required this.etitle,
    required this.edescr,
    required this.ctitle,
    required this.cdescr,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.unit,
  });

  factory CarrotSettingItemMeta.fromJson(Map<String, dynamic> json) {
    return CarrotSettingItemMeta(
      group: (json['group'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      title: json['title']?.toString(),
      descr: json['descr']?.toString(),
      etitle: json['etitle']?.toString(),
      edescr: json['edescr']?.toString(),
      ctitle: json['ctitle']?.toString(),
      cdescr: json['cdescr']?.toString(),
      min: _asNum(json['min']),
      max: _asNum(json['max']),
      defaultValue: json['default'],
      unit: _asInt(json['unit']),
    );
  }

  bool get hasNumericRange => min != null && max != null;
  bool get isIntegerRange =>
      min != null &&
      max != null &&
      min!.roundToDouble() == min!.toDouble() &&
      max!.roundToDouble() == max!.toDouble();

  bool get isBooleanLike =>
      hasNumericRange && min == 0 && max == 1 && isIntegerRange;

  bool get supportsSlider {
    if (!hasNumericRange || isBooleanLike) return false;
    final range = (max! - min!).abs();
    return range <= 20000;
  }

  String get displayTitle {
    final candidates = [title, name];
    for (final c in candidates) {
      if (c != null && c.trim().isNotEmpty) return c.trim();
    }
    return name;
  }

  String? get displayDescription {
    final candidates = [descr];
    for (final c in candidates) {
      if (c != null && c.trim().isNotEmpty) return c.trim();
    }
    return null;
  }
}

class CarrotCarsBundle {
  final List<String> sources;
  final Map<String, List<String>> makers;

  const CarrotCarsBundle({
    required this.sources,
    required this.makers,
  });

  factory CarrotCarsBundle.fromJson(Map<String, dynamic> json) {
    final sources = <String>[];
    final rawSources = (json['sources'] as List?) ?? const [];
    for (final s in rawSources) {
      final v = s.toString();
      if (v.isNotEmpty) sources.add(v);
    }

    final makers = <String, List<String>>{};
    final rawMakers = json['makers'];
    if (rawMakers is Map) {
      for (final entry in rawMakers.entries) {
        final maker = entry.key.toString();
        final list = (entry.value as List?) ?? const [];
        makers[maker] = list
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList()
          ..sort();
      }
    }
    return CarrotCarsBundle(sources: sources, makers: makers);
  }
}

class CarrotCarOption {
  final String maker;
  final String fullLine;
  final String modelOnly;

  const CarrotCarOption({
    required this.maker,
    required this.fullLine,
    required this.modelOnly,
  });

  factory CarrotCarOption.fromFullLine(String maker, String fullLine) {
    final prefix = '$maker ';
    var modelOnly = fullLine;
    if (fullLine.startsWith(prefix)) {
      modelOnly = fullLine.substring(prefix.length).trim();
    } else {
      final parts = fullLine.split(' ');
      if (parts.length >= 2) {
        modelOnly = parts.sublist(1).join(' ').trim();
      }
    }
    return CarrotCarOption(
        maker: maker, fullLine: fullLine, modelOnly: modelOnly);
  }

  String get searchableText => '$maker $modelOnly $fullLine'.toLowerCase();
}

num? _asNum(dynamic value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value);
  return null;
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
