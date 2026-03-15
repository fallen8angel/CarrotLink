import 'package:shared_preferences/shared_preferences.dart';

class YoloStockDebugPlaybackStore {
  YoloStockDebugPlaybackStore._();

  static const String _selectedVideoPathPrefKey =
      'developer_yolo_stock_playback_video_path_v1';

  static Future<String?> loadSelectedVideoPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_selectedVideoPathPrefKey)?.trim();
    if (path == null || path.isEmpty) {
      return null;
    }
    return path;
  }

  static Future<void> saveSelectedVideoPath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = path?.trim();
    if (normalized == null || normalized.isEmpty) {
      await prefs.remove(_selectedVideoPathPrefKey);
      return;
    }
    await prefs.setString(_selectedVideoPathPrefKey, normalized);
  }
}
