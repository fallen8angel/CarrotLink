import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'yolo_device_profile_service.dart';

class YoloRuntimeCapabilitySnapshot {
  const YoloRuntimeCapabilitySnapshot({
    required this.deviceKey,
    required this.qnnBlocked,
    required this.blocker,
    required this.detail,
    required this.updatedAt,
  });

  final String deviceKey;
  final bool qnnBlocked;
  final String blocker;
  final String detail;
  final DateTime? updatedAt;
}

class YoloRuntimeCapabilityStore {
  YoloRuntimeCapabilityStore._();

  static const String _prefKey = 'yolo_runtime_capability_v1';
  static const Duration _qnnFailureTtl = Duration(days: 7);

  static Future<YoloRuntimeCapabilitySnapshot> loadForCurrentDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final profile = await YoloDeviceProfileService.load();
    final deviceKey = _deviceKeyForProfile(profile);
    final root = _decodeMap(prefs.getString(_prefKey));
    final rawEntry = root[deviceKey];
    if (rawEntry is Map<String, dynamic>) {
      final snapshot = _snapshotFromEntry(deviceKey, rawEntry);
      if (_isExpired(snapshot)) {
        final cleared = _defaultSnapshot(deviceKey);
        root[deviceKey] = _encodeSnapshot(cleared);
        await prefs.setString(_prefKey, jsonEncode(root));
        return cleared;
      }
      return snapshot;
    }
    if (rawEntry is Map) {
      final snapshot = _snapshotFromEntry(
        deviceKey,
        rawEntry.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (_isExpired(snapshot)) {
        final cleared = _defaultSnapshot(deviceKey);
        root[deviceKey] = _encodeSnapshot(cleared);
        await prefs.setString(_prefKey, jsonEncode(root));
        return cleared;
      }
      return snapshot;
    }
    return _defaultSnapshot(deviceKey);
  }

  static Future<void> rememberQnnFailureForCurrentDevice({
    required String blocker,
    String detail = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final profile = await YoloDeviceProfileService.load();
    final deviceKey = _deviceKeyForProfile(profile);
    final root = _decodeMap(prefs.getString(_prefKey));
    root[deviceKey] = <String, dynamic>{
      'qnnBlocked': true,
      'blocker': blocker.trim(),
      'detail': detail.trim(),
      'updatedAt': DateTime.now().toIso8601String(),
    };
    await prefs.setString(_prefKey, jsonEncode(root));
  }

  static Future<void> clearQnnFailureForCurrentDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final profile = await YoloDeviceProfileService.load();
    final deviceKey = _deviceKeyForProfile(profile);
    final root = _decodeMap(prefs.getString(_prefKey));
    final rawEntry = root[deviceKey];
    if (rawEntry is! Map && rawEntry is! Map<String, dynamic>) {
      return;
    }
    root[deviceKey] = <String, dynamic>{
      'qnnBlocked': false,
      'blocker': '',
      'detail': '',
      'updatedAt': DateTime.now().toIso8601String(),
    };
    await prefs.setString(_prefKey, jsonEncode(root));
  }

  static String _deviceKeyForProfile(YoloAndroidDeviceProfile profile) {
    final fields = <String>[
      profile.platform,
      profile.manufacturer,
      profile.brand,
      profile.model,
      profile.device,
      profile.hardware,
      profile.board,
      profile.product,
      profile.socModel,
      profile.socManufacturer,
      profile.supportedAbis.join(','),
    ]
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (fields.isEmpty) {
      return 'unknown-device';
    }
    return fields.join('|');
  }

  static YoloRuntimeCapabilitySnapshot _snapshotFromEntry(
    String deviceKey,
    Map<String, dynamic> entry,
  ) {
    return YoloRuntimeCapabilitySnapshot(
      deviceKey: deviceKey,
      qnnBlocked: entry['qnnBlocked'] == true,
      blocker: entry['blocker']?.toString().trim() ?? '',
      detail: entry['detail']?.toString().trim() ?? '',
      updatedAt: DateTime.tryParse(entry['updatedAt']?.toString() ?? ''),
    );
  }

  static YoloRuntimeCapabilitySnapshot _defaultSnapshot(String deviceKey) {
    return YoloRuntimeCapabilitySnapshot(
      deviceKey: deviceKey,
      qnnBlocked: false,
      blocker: '',
      detail: '',
      updatedAt: null,
    );
  }

  static Map<String, dynamic> _encodeSnapshot(
    YoloRuntimeCapabilitySnapshot snapshot,
  ) {
    return <String, dynamic>{
      'qnnBlocked': snapshot.qnnBlocked,
      'blocker': snapshot.blocker,
      'detail': snapshot.detail,
      'updatedAt': snapshot.updatedAt?.toIso8601String(),
    };
  }

  static bool _isExpired(YoloRuntimeCapabilitySnapshot snapshot) {
    if (!snapshot.qnnBlocked) {
      return false;
    }
    final updatedAt = snapshot.updatedAt;
    if (updatedAt == null) {
      return true;
    }
    return DateTime.now().difference(updatedAt) >= _qnnFailureTtl;
  }

  static Map<String, dynamic> _decodeMap(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {}
    return <String, dynamic>{};
  }
}
