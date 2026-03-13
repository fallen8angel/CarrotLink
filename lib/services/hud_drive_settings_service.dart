import 'package:shared_preferences/shared_preferences.dart';

class HudDriveSettingsService {
  HudDriveSettingsService._();

  /// @deprecated WebRTC mode removed. Kept for migration compatibility only.
  static const String modeWebrtc = 'webrtc';
  static const String modeOpenpilotOverlay = 'openpilot_overlay';
  static const String _defaultModePrefKey = 'hud_drive_default_mode';

  /// Always returns [modeOpenpilotOverlay] — WebRTC mode is removed.
  static Future<String> getDefaultMode() async {
    return modeOpenpilotOverlay;
  }

  /// No-op: only [modeOpenpilotOverlay] is supported.
  static Future<void> setDefaultMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_defaultModePrefKey, modeOpenpilotOverlay);
  }

  static bool isOpenpilotOverlay(String mode) => true;
}
