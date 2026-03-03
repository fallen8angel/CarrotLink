import 'package:shared_preferences/shared_preferences.dart';

class HudDriveSettingsService {
  HudDriveSettingsService._();

  static const String modeWebrtc = 'webrtc';
  static const String modeOpenpilotOverlay = 'openpilot_overlay';
  static const String _defaultModePrefKey = 'hud_drive_default_mode';

  static Future<String> getDefaultMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = (prefs.getString(_defaultModePrefKey) ?? modeWebrtc).trim();
    if (raw == modeOpenpilotOverlay) return modeOpenpilotOverlay;
    return modeWebrtc;
  }

  static Future<void> setDefaultMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized =
        mode == modeOpenpilotOverlay ? modeOpenpilotOverlay : modeWebrtc;
    await prefs.setString(_defaultModePrefKey, normalized);
  }

  static bool isOpenpilotOverlay(String mode) => mode == modeOpenpilotOverlay;
}
