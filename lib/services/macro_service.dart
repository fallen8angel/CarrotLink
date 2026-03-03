import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants.dart';

class MacroService extends ChangeNotifier {
  List<Macro> _macros = [];
  List<Macro> get macros => _macros;

  MacroService() {
    _loadMacros();
  }

  Future<void> _loadMacros() async {
    final prefs = await SharedPreferences.getInstance();
    final String? stored = prefs.getString('custom_macros');
    if (stored != null) {
      final List<dynamic> decoded = jsonDecode(stored);
      _macros = decoded.map((e) => Macro.fromJson(e)).toList();
      notifyListeners();
    } else {
      // Add defaults requested by user
      _macros = [
        Macro(name: "Git Pull", command: "cd ${CarrotConstants.openpilotPath} && git pull"),
        Macro(name: "Git Force Sync", command: "cd ${CarrotConstants.openpilotPath} && git fetch --all && git reset --hard origin/\$(git rev-parse --abbrev-ref HEAD)"),
        Macro(name: "Git Reset~1", command: "cd ${CarrotConstants.openpilotPath} && git reset --hard HEAD~1"),
        Macro(name: "Reset Calibration", command: "rm ${CarrotConstants.paramsPath}/CalibrationParams"),
        Macro(name: "Reset Live Params", command: "rm ${CarrotConstants.paramsPath}/LiveParameters"),
        Macro(name: "Remove realdata", command: "rm -rf /data/media/0/realdata"),
        Macro(name: "Remove videos", command: "rm -rf /data/media/0/videos"),
        Macro(name: "Rebuild", command: "cd /data/openpilot && scons -c && rm .sconsign.dblite && rm -rf /tmp/scons_cache && rm prebuilt && sudo reboot"),
        Macro(name: "Soft restart", command: "tmux kill-session -t tmp 2>/dev/null; tmux new -d -s tmp; tmux split-window -v -t tmp; tmux send-keys -t tmp.0 \"/data/openpilot/launch_openpilot.sh\" C-m; tmux send-keys -t tmp.1 \"tmux kill-session -t comma\" C-m; tmux send-keys -t tmp.1 \"tmux rename-session -t tmp comma\" C-m; tmux send-keys -t tmp.1 \"exit\" C-m"),
        Macro(name: "Reboot", command: "sudo reboot"),
      ];
    }
  }

  Future<void> addMacro(String name, String command) async {
    _macros.add(Macro(name: name, command: command));
    await _saveMacros();
    notifyListeners();
  }

  Future<void> removeMacro(int index) async {
    _macros.removeAt(index);
    await _saveMacros();
    notifyListeners();
  }

  Future<void> updateMacro(int index, String name, String command) async {
    _macros[index] = Macro(name: name, command: command);
    await _saveMacros();
    notifyListeners();
  }

  Future<void> _saveMacros() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_macros.map((e) => e.toJson()).toList());
    await prefs.setString('custom_macros', encoded);
  }

  Future<void> resetToDefaults() async {
    _macros = [
      Macro(name: "Git Pull", command: "cd ${CarrotConstants.openpilotPath} && git pull"),
      Macro(name: "Git Force Sync", command: "cd ${CarrotConstants.openpilotPath} && git fetch --all && git reset --hard origin/\$(git rev-parse --abbrev-ref HEAD)"),
      Macro(name: "Git Reset~1", command: "cd ${CarrotConstants.openpilotPath} && git reset --hard HEAD~1"),
      Macro(name: "Reset Calibration", command: "rm ${CarrotConstants.paramsPath}/CalibrationParams"),
      Macro(name: "Reset Live Params", command: "rm ${CarrotConstants.paramsPath}/LiveParameters"),
      Macro(name: "Remove realdata", command: "rm -rf /data/media/0/realdata"),
      Macro(name: "Remove videos", command: "rm -rf /data/media/0/videos"),
      Macro(name: "Rebuild", command: "cd /data/openpilot && scons -c && rm .sconsign.dblite && rm -rf /tmp/scons_cache && rm prebuilt && sudo reboot"),
      Macro(name: "Soft restart", command: "tmux kill-session -t tmp 2>/dev/null; tmux new -d -s tmp; tmux split-window -v -t tmp; tmux send-keys -t tmp.0 \"/data/openpilot/launch_openpilot.sh\" C-m; tmux send-keys -t tmp.1 \"tmux kill-session -t comma\" C-m; tmux send-keys -t tmp.1 \"tmux rename-session -t tmp comma\" C-m; tmux send-keys -t tmp.1 \"exit\" C-m"),
      Macro(name: "Reboot", command: "sudo reboot"),
    ];
    await _saveMacros();
    notifyListeners();
  }
}

class Macro {
  final String name;
  final String command;

  Macro({required this.name, required this.command});

  Map<String, dynamic> toJson() => {'name': name, 'command': command};
  
  factory Macro.fromJson(Map<String, dynamic> json) {
    return Macro(name: json['name'], command: json['command']);
  }
}
