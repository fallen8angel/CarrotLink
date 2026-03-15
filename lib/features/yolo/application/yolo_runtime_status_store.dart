import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class YoloRuntimeStatusSnapshot {
  const YoloRuntimeStatusSnapshot({
    required this.config,
    required this.state,
    required this.updatedAt,
  });

  final Map<String, dynamic> config;
  final Map<String, dynamic> state;
  final DateTime? updatedAt;
}

class YoloRuntimeStatusStore {
  YoloRuntimeStatusStore._();

  static const String _lastConfigPrefKey = 'yolo_last_config_v1';
  static const String _lastStatePrefKey = 'yolo_last_state_v1';
  static const String _lastUpdatedPrefKey = 'yolo_last_updated_v1';

  static Future<void> saveConfig(Map<String, dynamic> payload) async {
    await _save(_lastConfigPrefKey, payload);
  }

  static Future<void> saveState(Map<String, dynamic> payload) async {
    await _save(_lastStatePrefKey, payload);
  }

  static Future<YoloRuntimeStatusSnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final config = _decodeMap(prefs.getString(_lastConfigPrefKey));
    final state = _decodeMap(prefs.getString(_lastStatePrefKey));
    final updatedRaw = prefs.getString(_lastUpdatedPrefKey);
    return YoloRuntimeStatusSnapshot(
      config: config,
      state: state,
      updatedAt: updatedRaw == null ? null : DateTime.tryParse(updatedRaw),
    );
  }

  static Future<void> _save(String key, Map<String, dynamic> payload) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(payload));
    await prefs.setString(
      _lastUpdatedPrefKey,
      DateTime.now().toIso8601String(),
    );
  }

  static Map<String, dynamic> _decodeMap(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {}
    return const <String, dynamic>{};
  }
}
