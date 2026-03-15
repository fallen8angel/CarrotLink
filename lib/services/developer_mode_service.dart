import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeveloperModeService extends ChangeNotifier {
  DeveloperModeService() {
    unawaited(_load());
  }

  static const String _enabledPrefKey = 'developer_mode_enabled_v1';

  bool _enabled = false;
  bool _loaded = false;

  bool get enabled => _enabled;
  bool get loaded => _loaded;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledPrefKey) ?? false;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value && _loaded) {
      return;
    }
    _enabled = value;
    _loaded = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledPrefKey, value);
  }

  Future<bool> toggle() async {
    final next = !_enabled;
    await setEnabled(next);
    return next;
  }
}
