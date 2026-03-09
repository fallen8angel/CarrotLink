import '../models/carrot_settings_models.dart';

enum CarrotProfileCompareMode { live, snapshot }

class CarrotProfileDiffEntry {
  final String key;
  final String title;
  final String group;
  final String baselineValue;
  final String profileValue;
  final bool missingBaseline;
  final bool missingProfile;

  const CarrotProfileDiffEntry({
    required this.key,
    required this.title,
    required this.group,
    required this.baselineValue,
    required this.profileValue,
    required this.missingBaseline,
    required this.missingProfile,
  });
}

class CarrotProfileCompareResult {
  final CarrotProfileCompareMode mode;
  final String baselineLabel;
  final int totalKeys;
  final int changedCount;
  final int missingBaselineCount;
  final int missingProfileCount;
  final List<CarrotProfileDiffEntry> entries;

  const CarrotProfileCompareResult({
    required this.mode,
    required this.baselineLabel,
    required this.totalKeys,
    required this.changedCount,
    required this.missingBaselineCount,
    required this.missingProfileCount,
    required this.entries,
  });

  bool get hasDiffs => entries.isNotEmpty;

  String get modeLabel => mode == CarrotProfileCompareMode.live
      ? 'Live Compare'
      : 'Snapshot Compare';
}

class CarrotProfileCompareService {
  const CarrotProfileCompareService();

  CarrotProfileCompareResult build({
    required CarrotSettingsBundle bundle,
    required Map<String, dynamic> baseline,
    required Map<String, dynamic> profile,
    required CarrotProfileCompareMode mode,
    required String baselineLabel,
  }) {
    final metaByName = <String, CarrotSettingItemMeta>{};
    final groupOrder = <String, int>{};
    final itemOrder = <String, int>{};
    for (var i = 0; i < bundle.groups.length; i++) {
      groupOrder[bundle.groups[i].group] = i;
    }
    var runningItemOrder = 0;
    for (final items in bundle.itemsByGroup.values) {
      for (final item in items) {
        metaByName[item.name] = item;
        itemOrder[item.name] = runningItemOrder++;
      }
    }

    final keys = <String>{...baseline.keys, ...profile.keys}.toList()..sort();
    final entries = <CarrotProfileDiffEntry>[];
    var missingBaselineCount = 0;
    var missingProfileCount = 0;

    for (final key in keys) {
      final hasBaseline = baseline.containsKey(key);
      final hasProfile = profile.containsKey(key);
      if (!hasBaseline) missingBaselineCount++;
      if (!hasProfile) missingProfileCount++;

      final baselineValue = baseline[key];
      final profileValue = profile[key];
      if (_normalizeValue(baselineValue) == _normalizeValue(profileValue)) {
        continue;
      }

      final meta = metaByName[key];
      entries.add(
        CarrotProfileDiffEntry(
          key: key,
          title: meta?.displayTitle ?? key,
          group: meta?.group ?? 'unknown',
          baselineValue: _displayValue(baselineValue),
          profileValue: _displayValue(profileValue),
          missingBaseline: !hasBaseline,
          missingProfile: !hasProfile,
        ),
      );
    }

    entries.sort((a, b) {
      final byGroup = (groupOrder[a.group] ?? 1 << 20)
          .compareTo(groupOrder[b.group] ?? 1 << 20);
      if (byGroup != 0) return byGroup;
      final byItem =
          (itemOrder[a.key] ?? 1 << 20).compareTo(itemOrder[b.key] ?? 1 << 20);
      if (byItem != 0) return byItem;
      final byTitle = a.title.compareTo(b.title);
      if (byTitle != 0) return byTitle;
      return a.key.compareTo(b.key);
    });

    return CarrotProfileCompareResult(
      mode: mode,
      baselineLabel: baselineLabel,
      totalKeys: keys.length,
      changedCount: entries.length,
      missingBaselineCount: missingBaselineCount,
      missingProfileCount: missingProfileCount,
      entries: entries,
    );
  }

  String _normalizeValue(dynamic value) {
    if (value == null) return '';
    final raw = value.toString().trim();
    if (raw.isEmpty) return '';

    final lower = raw.toLowerCase();
    if (lower == 'true') return '1';
    if (lower == 'false') return '0';

    final asNum = num.tryParse(raw);
    if (asNum != null) {
      if (asNum == asNum.roundToDouble()) {
        return asNum.toInt().toString();
      }
      return asNum.toString();
    }
    return raw;
  }

  String _displayValue(dynamic value) {
    if (value == null) return '(없음)';
    final text = value.toString().trim();
    if (text.isEmpty) return '(빈값)';
    return text;
  }
}
