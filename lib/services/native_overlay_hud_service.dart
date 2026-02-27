import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeOverlayHudService {
  NativeOverlayHudService._();

  static const MethodChannel _channel = MethodChannel('carrotlink/overlay_hud');
  static final RegExp _ipv4Regex = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get isSupported => _isAndroid;

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
    final normalizedHost = normalizeHost(host);
    if (normalizedHost == null) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'start',
            {'host': normalizedHost},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> updateEndpoint(String host) async {
    if (!_isAndroid) return;
    final normalizedHost = normalizeHost(host);
    if (normalizedHost == null) return;
    try {
      await _channel.invokeMethod(
        'updateEndpoint',
        {'host': normalizedHost},
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
