import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum HudStockInstallTarget {
  c3('c3'),
  c4('c4');

  const HudStockInstallTarget(this.wireValue);
  final String wireValue;

  static HudStockInstallTarget fromWireValue(String? value) {
    switch ((value ?? '').trim().toLowerCase()) {
      case 'c4':
        return HudStockInstallTarget.c4;
      case 'c3':
      default:
        return HudStockInstallTarget.c3;
    }
  }
}

class HudFeatureSettingsService extends ChangeNotifier {
  HudFeatureSettingsService() {
    unawaited(_load());
  }

  static const String _enabledPrefKey = 'hud_stock_feature_enabled_v1';
  static const String _installTargetPrefKey = 'hud_stock_install_target_v1';

  bool _enabled = false;
  bool _loaded = false;
  HudStockInstallTarget _installTarget = HudStockInstallTarget.c3;

  bool get enabled => _enabled;
  bool get loaded => _loaded;
  HudStockInstallTarget get installTarget => _installTarget;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledPrefKey) ?? false;
    _installTarget = HudStockInstallTarget.fromWireValue(
      prefs.getString(_installTargetPrefKey),
    );
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

  Future<void> setInstallTarget(HudStockInstallTarget target) async {
    if (_installTarget == target && _loaded) {
      return;
    }
    _installTarget = target;
    _loaded = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_installTargetPrefKey, target.wireValue);
  }
}
