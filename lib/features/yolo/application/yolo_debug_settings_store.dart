import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../presentation/models/yolo_debug_settings.dart';
import 'yolo_runtime_policy.dart';

class YoloDebugSettingsStore {
  YoloDebugSettingsStore._();

  static const String _prefKey = 'developer_yolo_debug_settings_v1';
  static const String _migratedPrefKey = 'developer_yolo_debug_settings_migrated_v1';

  static const String _legacyHudDebugLayerTogglesPrefKey =
      'hud_debug_layer_toggles_v5';

  static const YoloDebugSettings _defaults = YoloDebugSettings.empty;

  static Future<YoloDebugSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw != null && raw.trim().isNotEmpty) {
      final decoded = _decode(raw);
      final normalized = await YoloRuntimePolicy.normalizeForProfile(decoded);
      if (normalized != decoded) {
        await prefs.setString(_prefKey, jsonEncode(normalized.toJson()));
      }
      return normalized;
    }

    final migrated = prefs.getBool(_migratedPrefKey) ?? false;
    if (!migrated) {
      final migratedSettings = await _migrateLegacyIfNeeded(prefs);
      if (migratedSettings != null) {
        final normalized =
            await YoloRuntimePolicy.normalizeForProfile(migratedSettings);
        if (normalized != migratedSettings) {
          await prefs.setString(_prefKey, jsonEncode(normalized.toJson()));
        }
        return normalized;
      }
    }

    final recommended =
        await YoloRuntimePolicy.recommendedDefaults(base: _defaults);
    await prefs.setString(_prefKey, jsonEncode(recommended.toJson()));
    await prefs.setBool(_migratedPrefKey, true);
    return recommended;
  }

  static Future<YoloDebugSettings> save(YoloDebugSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = await YoloRuntimePolicy.normalizeForProfile(settings);
    await prefs.setString(_prefKey, jsonEncode(normalized.toJson()));
    await prefs.setBool(_migratedPrefKey, true);
    return normalized;
  }

  static Future<YoloDebugSettings?> _migrateLegacyIfNeeded(
    SharedPreferences prefs,
  ) async {
    final raw = prefs.getString(_legacyHudDebugLayerTogglesPrefKey);
    await prefs.setBool(_migratedPrefKey, true);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    final settings = _decode(raw);
    await prefs.setString(_prefKey, jsonEncode(settings.toJson()));
    return settings;
  }

  static YoloDebugSettings _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return YoloDebugSettings.fromJson(decoded);
      }
      if (decoded is Map) {
        return YoloDebugSettings.fromJson(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
    } catch (_) {}
    return _defaults;
  }
}
