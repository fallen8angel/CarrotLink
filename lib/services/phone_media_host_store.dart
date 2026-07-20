import 'package:shared_preferences/shared_preferences.dart';

class PhoneMediaHostStore {
  PhoneMediaHostStore._();

  static const String preferenceKey = 'phone_media_host';

  static String? normalizeHost(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;

    final value = raw.trim();
    final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
    final host = uri?.host.trim() ?? '';
    final octets = host.split('.');
    if (octets.length != 4) return null;
    if (octets.any((octet) {
      final value = int.tryParse(octet);
      return value == null || value < 0 || value > 255;
    })) {
      return null;
    }
    return host;
  }

  static Future<bool> remember(String? raw) async {
    final host = normalizeHost(raw);
    if (host == null) return false;

    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      if (preferences.getString(preferenceKey) == host) return true;
      return preferences.setString(preferenceKey, host);
    } catch (_) {
      return false;
    }
  }
}
