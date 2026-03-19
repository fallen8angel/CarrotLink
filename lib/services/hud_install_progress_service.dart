import 'package:flutter/foundation.dart';

class HudInstallProgressService extends ChangeNotifier {
  HudInstallProgressService._();

  static final HudInstallProgressService shared = HudInstallProgressService._();

  bool _busy = false;
  final List<HudInstallStepLog> _steps = <HudInstallStepLog>[];
  final List<String> _terminalLines = <String>[];

  bool get busy => _busy;
  List<HudInstallStepLog> get steps =>
      List<HudInstallStepLog>.unmodifiable(_steps);
  List<String> get terminalLines => List<String>.unmodifiable(_terminalLines);

  void beginRun() {
    _busy = true;
    _steps.clear();
    notifyListeners();
  }

  void finishRun() {
    if (!_busy) return;
    _busy = false;
    notifyListeners();
  }

  void clearTerminal() {
    if (_terminalLines.isEmpty) return;
    _terminalLines.clear();
    notifyListeners();
  }

  void appendTerminal(String section, String output) {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
    final normalized = output.trim().isEmpty ? '(출력 없음)' : output.trim();
    _terminalLines.add('[$stamp] $section');
    _terminalLines.add(normalized);
    _terminalLines.add('');
    notifyListeners();
  }

  void addStep(
    String label, {
    HudInstallStepStatus status = HudInstallStepStatus.pending,
  }) {
    _steps.add(HudInstallStepLog(label: label, status: status, detail: null));
    notifyListeners();
  }

  void updateLastStep({
    required HudInstallStepStatus status,
    String? detail,
  }) {
    if (_steps.isEmpty) return;
    final last = _steps.last;
    _steps[_steps.length - 1] = HudInstallStepLog(
      label: last.label,
      status: status,
      detail: detail,
    );
    notifyListeners();
  }
}

enum HudInstallStepStatus { pending, running, ok, warn, fail }

class HudInstallStepLog {
  const HudInstallStepLog({
    required this.label,
    required this.status,
    this.detail,
  });

  final String label;
  final HudInstallStepStatus status;
  final String? detail;
}
