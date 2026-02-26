import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'storage_layout_service.dart';

class KeyBackupData {
  KeyBackupData({
    required this.privateKey,
    required this.keyTitle,
    required this.checksumSha256,
    required this.filePath,
  });

  final String privateKey;
  final String keyTitle;
  final String checksumSha256;
  final String filePath;
}

class KeyBackupService {
  static const String _backupFileName = 'carrotpilot_ssh_key_backup_v1.json';
  static const String _backupFolderName = 'CarrotLink';

  File _sharedPrimaryBackupFile() {
    return File('${StorageLayoutService.authPath}/$_backupFileName');
  }

  List<File> _legacySharedBackupFiles() {
    return <File>[
      File('/storage/emulated/0/$_backupFolderName/keys/$_backupFileName'),
      File('/storage/emulated/0/Documents/$_backupFolderName/$_backupFileName'),
      File('/storage/emulated/0/Download/$_backupFolderName/$_backupFileName'),
    ];
  }

  File _appExternalBackupFile(String basePath) {
    return File('$basePath/$_backupFolderName/auth/$_backupFileName');
  }

  File _legacyAppExternalBackupFile(String basePath) {
    return File('$basePath/$_backupFolderName/$_backupFileName');
  }

  Future<bool> ensureStoragePermission({bool requestForSharedStorage = false}) async {
    if (!Platform.isAndroid) return true;

    final manage = Permission.manageExternalStorage;
    if (await manage.isGranted) return true;
    if (!requestForSharedStorage) return false;

    final status = await manage.request();
    return status.isGranted;
  }

  Future<String?> savePrivateKeyBackup({
    required String privateKey,
    required String keyTitle,
  }) async {
    final files = await _writableBackupFiles();
    if (files.isEmpty) return null;

    final payload = <String, dynamic>{
      'version': 1,
      'keyTitle': keyTitle,
      'checksumSha256': _sha256Hex(privateKey),
      'privateKey': privateKey,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    final encoded = const JsonEncoder.withIndent('  ').convert(payload);

    String? firstSuccessPath;
    for (final file in files) {
      try {
        await file.writeAsString(encoded);
        firstSuccessPath ??= file.path;
      } catch (_) {
        continue;
      }
    }

    return firstSuccessPath;
  }

  Future<KeyBackupData?> loadPrivateKeyBackup() async {
    for (final file in await _candidateBackupFiles()) {
      try {
        if (!await file.exists()) continue;
        final text = await file.readAsString();
        final data = jsonDecode(text);
        if (data is! Map<String, dynamic>) continue;

        final privateKey = data['privateKey']?.toString();
        final keyTitle = data['keyTitle']?.toString() ?? 'carrotpilot';
        final checksum = data['checksumSha256']?.toString();
        if (privateKey == null || privateKey.isEmpty || checksum == null || checksum.isEmpty) {
          continue;
        }

        final currentChecksum = _sha256Hex(privateKey);
        if (checksum.toLowerCase() != currentChecksum.toLowerCase()) {
          continue;
        }

        final keys = SSHKeyPair.fromPem(privateKey);
        if (keys.isEmpty) continue;

        return KeyBackupData(
          privateKey: privateKey,
          keyTitle: keyTitle,
          checksumSha256: currentChecksum,
          filePath: file.path,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<List<File>> _writableBackupFiles() async {
    final files = <File>[];
    await StorageLayoutService.instance.ensureBaseFolders();

    if (await _canUseSharedStorage()) {
      final primaryShared = _sharedPrimaryBackupFile();
      try {
        final dir = primaryShared.parent;
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        if (await dir.exists()) {
          files.add(primaryShared);
        }
      } catch (_) {}
    }

    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final fallback = Directory('${ext.path}/$_backupFolderName/auth');
        if (!await fallback.exists()) {
          await fallback.create(recursive: true);
        }
        if (await fallback.exists()) {
          files.add(_appExternalBackupFile(ext.path));
        }
      }
    } catch (_) {}

    return files;
  }

  Future<List<File>> _candidateBackupFiles() async {
    final files = <File>[];

    if (await _canUseSharedStorage()) {
      files.add(_sharedPrimaryBackupFile());
      files.addAll(_legacySharedBackupFiles());
    }

    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        files.add(_appExternalBackupFile(ext.path));
        files.add(_legacyAppExternalBackupFile(ext.path));
      }
    } catch (_) {}

    return files;
  }

  Future<Map<String, bool>> getBackupLocationStatus() async {
    final status = <String, bool>{
      'auth': false,
      'shared_root': false,
      'documents': false,
      'download': false,
      'app_external': false,
    };

    if (await _canUseSharedStorage()) {
      final authExists = await _sharedPrimaryBackupFile().exists();
      status['auth'] = authExists;
      status['shared_root'] = authExists;
      status['documents'] = await File(
        '/storage/emulated/0/Documents/$_backupFolderName/$_backupFileName',
      ).exists();
      status['download'] = await File(
        '/storage/emulated/0/Download/$_backupFolderName/$_backupFileName',
      ).exists();
    }

    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final primary = await _appExternalBackupFile(ext.path).exists();
        final legacy = await _legacyAppExternalBackupFile(ext.path).exists();
        status['app_external'] = primary || legacy;
      }
    } catch (_) {}

    return status;
  }

  Future<bool> _canUseSharedStorage() async {
    if (!Platform.isAndroid) return true;
    final manage = await Permission.manageExternalStorage.status;
    if (manage.isGranted) return true;

    final legacy = await Permission.storage.status;
    return legacy.isGranted;
  }

  String _sha256Hex(String input) {
    final bytes = Uint8List.fromList(utf8.encode(input));
    final digest = SHA256Digest().process(bytes);
    final buffer = StringBuffer();
    for (final b in digest) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
