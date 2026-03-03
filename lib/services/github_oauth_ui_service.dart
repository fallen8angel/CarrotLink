import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class GitHubOAuthUiService {
  GitHubOAuthUiService._();

  static const MethodChannel _channel =
      MethodChannel('carrotlink/github_oauth_ui');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> showCodeNotification({
    required String code,
    required String url,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('showCodeNotification', {
        'code': code,
        'url': url,
      });
    } catch (_) {}
  }

  static Future<void> cancelCodeNotification() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('cancelCodeNotification');
    } catch (_) {}
  }

  static Future<bool> hasOverlayPermission() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('hasOverlayPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestOverlayPermission() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } catch (_) {}
  }

  static Future<bool> showCodeHud(String code) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'showCodeHud',
            {'code': code},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> hideCodeHud() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('hideCodeHud');
    } catch (_) {}
  }

  static Future<bool> bringAppToFront() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('bringAppToFront') ?? false;
    } catch (_) {
      return false;
    }
  }
}
