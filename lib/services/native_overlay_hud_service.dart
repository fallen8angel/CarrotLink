import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/hud/hud.dart';

class NativeOverlayHudService {
  NativeOverlayHudService._();

  static const MethodChannel _channel = MethodChannel('carrotlink/overlay_hud');
  static final RegExp _ipv4Regex = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
  static const String _enabledPrefKey = 'hud_overlay_enabled';
  static bool? _enabledCache;
  static String? _lastSemanticSnapshotJson;
  static String? _lastSemanticSnapshotHost;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get isSupported => _isAndroid;

  static Future<bool> isEnabled() async {
    final cached = _enabledCache;
    if (cached != null) return cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_enabledPrefKey) ?? false;
      _enabledCache = enabled;
      return enabled;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    _enabledCache = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledPrefKey, enabled);
    } catch (_) {}
  }

  static Future<bool> hasPermission() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestPermission() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('requestPermission');
    } catch (_) {}
  }

  static Future<bool> start(String host) async {
    if (!_isAndroid) return false;
    final enabled = await isEnabled();
    if (!enabled) return false;
    final normalizedHost = normalizeHost(host);
    if (normalizedHost == null) return false;
    try {
      final cachedSnapshotJson = _cachedSnapshotJsonForHost(normalizedHost);
      return await _channel.invokeMethod<bool>(
            'start',
            {
              'host': normalizedHost,
              if (cachedSnapshotJson != null &&
                  cachedSnapshotJson.isNotEmpty)
                'snapshotJson': cachedSnapshotJson,
            },
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> updateEndpoint(String host) async {
    if (!_isAndroid) return;
    final enabled = await isEnabled();
    if (!enabled) return;
    final normalizedHost = normalizeHost(host);
    if (normalizedHost == null) return;
    try {
      final cachedSnapshotJson = _cachedSnapshotJsonForHost(normalizedHost);
      await _channel.invokeMethod(
        'updateEndpoint',
        {
          'host': normalizedHost,
          if (cachedSnapshotJson != null && cachedSnapshotJson.isNotEmpty)
            'snapshotJson': cachedSnapshotJson,
        },
      );
    } catch (_) {}
  }

  static Future<void> updateSemanticSnapshot(
    OriginalHudSnapshot snapshot,
  ) async {
    if (!_isAndroid) return;
    final snapshotJson = HudSnapshotJsonSerializer.encode(snapshot);
    _lastSemanticSnapshotJson = snapshotJson;
    _lastSemanticSnapshotHost = normalizeHost(snapshot.source.deviceHost);
    final enabled = await isEnabled();
    if (!enabled) return;
    final running = await isRunning();
    if (!running) return;
    try {
      await _channel.invokeMethod(
        'updateSemanticSnapshot',
        {
          'snapshotJson': snapshotJson,
        },
      );
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  static Future<void> resetPosition() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('resetPosition');
    } catch (_) {}
  }

  static Future<bool> isRunning() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  static String? _cachedSnapshotJsonForHost(String normalizedHost) {
    final cachedSnapshotJson = _lastSemanticSnapshotJson;
    if (cachedSnapshotJson == null || cachedSnapshotJson.isEmpty) {
      return null;
    }
    final cachedHost = _lastSemanticSnapshotHost;
    if (cachedHost == null || cachedHost == normalizedHost) {
      return cachedSnapshotJson;
    }
    return null;
  }

  static String? normalizeHost(String? raw) {
    if (raw == null) return null;
    var input = raw.trim();
    if (input.isEmpty) return null;

    if (input.contains('://')) {
      final parsed = Uri.tryParse(input);
      if (parsed != null && parsed.host.isNotEmpty) {
        input = parsed.host;
      }
    }

    if (input.contains(':')) {
      final index = input.indexOf(':');
      if (index > 0) {
        input = input.substring(0, index);
      }
    }

    if (!_ipv4Regex.hasMatch(input)) return null;

    final octets = input.split('.');
    if (octets.length != 4) return null;
    for (final octet in octets) {
      final value = int.tryParse(octet);
      if (value == null || value < 0 || value > 255) {
        return null;
      }
    }
    return input;
  }
}
