import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/carrot_profile_models.dart';
import '../models/carrot_settings_models.dart';
import 'carrot_server_settings_service.dart';
import 'ssh_service.dart';
import 'storage_layout_service.dart';

class CarrotProfileService {
  static const int _indexVersion = 1;
  static const String _indexFileName = 'index.json';
  static const int _paramChunkSize = 80;

  final CarrotServerSettingsService _settingsService;

  CarrotProfileService({
    CarrotServerSettingsService? settingsService,
  }) : _settingsService = settingsService ?? CarrotServerSettingsService();

  Future<List<CarrotProfileHeader>> listProfiles() async {
    final index = await _loadIndex();
    final profiles = List<CarrotProfileHeader>.from(index.profiles);
    profiles.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return profiles;
  }

  Future<CarrotProfileDocument?> readProfile(String id) async {
    final file = await _profileFile(id);
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    return CarrotProfileDocument.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<CarrotProfileDocument> createProfileFromDevice({
    required String name,
    required String host,
    required SSHService ssh,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw Exception('프로필 이름을 입력하세요.');
    }

    final bundle = await _settingsService.fetchSettings(host);
    final values = await _fetchAllValues(host, bundle);
    final now = DateTime.now().millisecondsSinceEpoch;
    final header = CarrotProfileHeader(
      id: 'profile_$now',
      name: trimmedName,
      createdAtMs: now,
      updatedAtMs: now,
      sourceBranch: await _resolveBranchName(ssh),
      sourceDongleId: await _safeRead(() => ssh.getDongleId()),
      sourceSerial: await _safeRead(() => ssh.getSerial()),
      sourceCar: values['CarSelected3']?.toString(),
      paramCount: values.length,
      schemaVersion: _schemaVersion(bundle),
    );
    final document = CarrotProfileDocument(
      header: header,
      settingsBundleJson: bundle.toJson(),
      values: values,
    );
    await saveProfileDocument(document);
    return document;
  }

  Future<CarrotProfileDocument> saveEditedProfile(
    CarrotProfileDocument document, {
    String? newName,
  }) async {
    final trimmedName = newName?.trim();
    if (trimmedName != null && trimmedName.isEmpty) {
      throw Exception('프로필 이름을 입력하세요.');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = document.copyWith(
      header: document.header.copyWith(
        name: trimmedName ?? document.header.name,
        updatedAtMs: now,
        sourceCar: document.values['CarSelected3']?.toString(),
        paramCount: document.values.length,
        schemaVersion: _schemaVersion(document.bundle),
      ),
    );
    await saveProfileDocument(next);
    return next;
  }

  Future<CarrotProfileDocument> duplicateProfile(
    String id, {
    String? newName,
  }) async {
    final source = await readProfile(id);
    if (source == null) {
      throw Exception('프로필을 찾을 수 없습니다.');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final trimmedName = newName?.trim();
    final targetName = (trimmedName == null || trimmedName.isEmpty)
        ? '${source.header.name} 복사본'
        : trimmedName;
    final duplicate = CarrotProfileDocument(
      header: CarrotProfileHeader(
        id: 'profile_$now',
        name: targetName,
        createdAtMs: now,
        updatedAtMs: now,
        sourceBranch: source.header.sourceBranch,
        sourceDongleId: source.header.sourceDongleId,
        sourceSerial: source.header.sourceSerial,
        sourceCar: source.values['CarSelected3']?.toString(),
        paramCount: source.values.length,
        schemaVersion: _schemaVersion(source.bundle),
      ),
      settingsBundleJson: Map<String, dynamic>.from(source.settingsBundleJson),
      values: Map<String, dynamic>.from(source.values),
    );
    await saveProfileDocument(duplicate);
    return duplicate;
  }

  Future<void> saveProfileDocument(CarrotProfileDocument document) async {
    await _writeDocument(document);
    final index = await _loadIndex();
    final nextProfiles = List<CarrotProfileHeader>.from(index.profiles);
    final existingIndex =
        nextProfiles.indexWhere((e) => e.id == document.header.id);
    if (existingIndex >= 0) {
      nextProfiles[existingIndex] = document.header;
    } else {
      nextProfiles.add(document.header);
    }
    await _writeIndex(
      CarrotProfileIndex(version: _indexVersion, profiles: nextProfiles),
    );
  }

  Future<void> renameProfile(String id, String newName) async {
    final trimmedName = newName.trim();
    if (trimmedName.isEmpty) {
      throw Exception('프로필 이름을 입력하세요.');
    }
    final document = await readProfile(id);
    if (document == null) {
      throw Exception('프로필을 찾을 수 없습니다.');
    }
    final updated = document.copyWith(
      header: document.header.copyWith(
        name: trimmedName,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await saveProfileDocument(updated);
  }

  Future<void> deleteProfile(String id) async {
    final file = await _profileFile(id);
    if (await file.exists()) {
      await file.delete();
    }
    final index = await _loadIndex();
    final nextProfiles = index.profiles.where((e) => e.id != id).toList();
    await _writeIndex(
      CarrotProfileIndex(version: _indexVersion, profiles: nextProfiles),
    );
  }

  Future<void> deleteAllProfiles() async {
    final dir = await _profilesDirectory();
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (path.basename(entity.path) == _indexFileName) continue;
      await entity.delete();
    }
    await _writeIndex(
      const CarrotProfileIndex(version: _indexVersion, profiles: []),
    );
  }

  Future<Map<String, dynamic>> _fetchAllValues(
    String host,
    CarrotSettingsBundle bundle,
  ) async {
    final names = bundle.itemsByGroup.values
        .expand((items) => items.map((item) => item.name))
        .where((name) => name.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final values = <String, dynamic>{};
    for (var i = 0; i < names.length; i += _paramChunkSize) {
      final chunk = names.sublist(
        i,
        i + _paramChunkSize > names.length ? names.length : i + _paramChunkSize,
      );
      values.addAll(await _settingsService.fetchParamsBulk(host, chunk));
    }
    return values;
  }

  String _schemaVersion(CarrotSettingsBundle bundle) {
    final itemCount = bundle.itemsByGroup.values.fold<int>(
      0,
      (sum, items) => sum + items.length,
    );
    return '${bundle.groups.length}:$itemCount:${bundle.unitCycle.join(",")}';
  }

  Future<String> _resolveBranchName(SSHService ssh) async {
    try {
      final output = await ssh.executeCommand(
        'cd /data/openpilot && git rev-parse --abbrev-ref HEAD',
      );
      final branch = output.trim();
      if (branch.isNotEmpty && !branch.startsWith('Error')) {
        return branch;
      }
    } catch (_) {}
    return 'unknown';
  }

  Future<String?> _safeRead(Future<String> Function() reader) async {
    try {
      final value = (await reader()).trim();
      if (value.isEmpty) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _profilesDirectory() async {
    await StorageLayoutService.instance.ensureBaseFolders();
    final dir = Directory(StorageLayoutService.profilesPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _indexFile() async {
    final dir = await _profilesDirectory();
    return File(path.join(dir.path, _indexFileName));
  }

  Future<File> _profileFile(String id) async {
    final dir = await _profilesDirectory();
    return File(path.join(dir.path, '$id.json'));
  }

  Future<CarrotProfileIndex> _loadIndex() async {
    final file = await _indexFile();
    if (!await file.exists()) {
      return _rebuildIndex();
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return _rebuildIndex();
      }
      return CarrotProfileIndex.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return _rebuildIndex();
    }
  }

  Future<CarrotProfileIndex> _rebuildIndex() async {
    final dir = await _profilesDirectory();
    final profiles = <CarrotProfileHeader>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = path.basename(entity.path);
      if (!name.endsWith('.json') || name == _indexFileName) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map) continue;
        final document =
            CarrotProfileDocument.fromJson(Map<String, dynamic>.from(decoded));
        profiles.add(document.header);
      } catch (_) {}
    }
    final index =
        CarrotProfileIndex(version: _indexVersion, profiles: profiles);
    await _writeIndex(index);
    return index;
  }

  Future<void> _writeDocument(CarrotProfileDocument document) async {
    final file = await _profileFile(document.header.id);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(document.toJson()),
    );
  }

  Future<void> _writeIndex(CarrotProfileIndex index) async {
    final file = await _indexFile();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(index.toJson()),
    );
  }
}
