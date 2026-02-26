import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

class StorageLayoutService {
  StorageLayoutService._();

  static final StorageLayoutService instance = StorageLayoutService._();

  static const String rootPath = '/storage/emulated/0/CarrotLink';
  static const List<String> _baseFolders = <String>[
    'auth',
    'routes',
    'logs',
    'fleet',
    'app',
    'tmp',
  ];

  static String folderPath(String folderName) => '$rootPath/$folderName';
  static String get authPath => folderPath('auth');
  static String get routesPath => folderPath('routes');
  static String get logsPath => folderPath('logs');
  static String get fleetPath => folderPath('fleet');
  static String get appPath => folderPath('app');
  static String get tmpPath => folderPath('tmp');

  Future<bool> ensureBaseFolders() async {
    if (!Platform.isAndroid) return true;
    if (!await _hasStoragePermission()) return false;

    try {
      final root = Directory(rootPath);
      if (!await root.exists()) {
        await root.create(recursive: true);
      }

      for (final folderName in _baseFolders) {
        final dir = Directory(folderPath(folderName));
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
      }

      return await validateBaseFolders();
    } catch (_) {
      return false;
    }
  }

  Future<bool> validateBaseFolders() async {
    try {
      final root = Directory(rootPath);
      if (!await root.exists()) return false;

      for (final folderName in _baseFolders) {
        if (!await Directory(folderPath(folderName)).exists()) {
          return false;
        }
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _hasStoragePermission() async {
    final manageStorage = await Permission.manageExternalStorage.status;
    if (manageStorage.isGranted) return true;

    final legacyStorage = await Permission.storage.status;
    return legacyStorage.isGranted;
  }
}
