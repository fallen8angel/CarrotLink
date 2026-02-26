import 'package:flutter/foundation.dart';

class DiagnosticsEntry {
  DiagnosticsEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
  });

  final DateTime timestamp;
  final String level;
  final String category;
  final String message;
}

class DiagnosticsService extends ChangeNotifier {
  DiagnosticsService._();

  static final DiagnosticsService instance = DiagnosticsService._();
  static const int _maxEntries = 200;

  final List<DiagnosticsEntry> _entries = [];

  List<DiagnosticsEntry> get entries => List.unmodifiable(_entries.reversed);

  void info(String category, String message) => _log('INFO', category, message);
  void warn(String category, String message) => _log('WARN', category, message);
  void error(String category, String message) =>
      _log('ERROR', category, message);

  void _log(String level, String category, String message) {
    _entries.add(
      DiagnosticsEntry(
        timestamp: DateTime.now(),
        level: level,
        category: category,
        message: message,
      ),
    );

    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    // Mirror diagnostics to logcat for realtime terminal debugging (OAuth/SSH/discovery).
    // ignore: avoid_print
    print('[DIAG][$level][$category] $message');
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String exportText() {
    final lines = <String>[];
    for (final e in _entries) {
      lines.add(
        '[${e.timestamp.toIso8601String()}] ${e.level.padRight(5)} '
        '[${e.category}] ${e.message}',
      );
    }
    return lines.join('\n');
  }
}
