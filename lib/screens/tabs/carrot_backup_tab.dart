import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../../services/backup_service.dart';
import '../../services/carrot_server_settings_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/ssh_service.dart';
import '../../services/storage_layout_service.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/custom_toast.dart';

enum _BackupSource { local, cloud }

enum _BackupDialogAction { copy, apply, delete }

class CarrotBackupTab extends StatefulWidget {
  const CarrotBackupTab({super.key});

  @override
  State<CarrotBackupTab> createState() => _CarrotBackupTabState();
}

class _CarrotBackupTabState extends State<CarrotBackupTab> {
  static const String _allDates = '전체 날짜';
  static const String _allBranches = '전체 브랜치';

  final CarrotServerSettingsService _carrotServer =
      CarrotServerSettingsService();

  _BackupSource _source = _BackupSource.local;
  List<_BackupListItem> _localItems = <_BackupListItem>[];
  List<_BackupListItem> _cloudItems = <_BackupListItem>[];

  String _selectedDate = _allDates;
  String _selectedBranch = _allBranches;

  bool _isLoadingLocal = false;
  bool _isLoadingCloud = false;
  bool _isApplying = false;
  String? _applyingId;
  bool _isDriveAuthBusy = false;

  StreamSubscription<void>? _backupSubscription;

  List<_BackupListItem> get _activeItems =>
      _source == _BackupSource.local ? _localItems : _cloudItems;

  bool get _isLoading =>
      _source == _BackupSource.local ? _isLoadingLocal : _isLoadingCloud;

  bool get _isCloudMode => _source == _BackupSource.cloud;

  List<String> get _dateOptions {
    final values = _activeItems.map((e) => e.dateLabel).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    return <String>[_allDates, ...values];
  }

  List<String> get _branchOptions {
    final values = _activeItems.map((e) => e.branch).toSet().toList()
      ..sort((a, b) => a.compareTo(b));
    return <String>[_allBranches, ...values];
  }

  List<_BackupListItem> get _filteredItems {
    return _activeItems.where((item) {
      final dateOk =
          _selectedDate == _allDates || item.dateLabel == _selectedDate;
      final branchOk =
          _selectedBranch == _allBranches || item.branch == _selectedBranch;
      return dateOk && branchOk;
    }).toList();
  }

  ({
    double filterMinHeight,
    double sourceSwitchMinHeight,
    double segmentMinHeight,
    double controlHorizontalPadding,
    double controlInnerPadding,
    double labelFontSize,
    double valueFontSize,
  }) _uiMetrics(BuildContext context) {
    final window = UiWindowInfo.of(context);
    return (
      filterMinHeight: switch (window.windowClass) {
        UiWindowClass.compact => 36.0,
        UiWindowClass.medium => 38.0,
        UiWindowClass.expanded => 40.0,
        UiWindowClass.large || UiWindowClass.extraLarge => 42.0,
      },
      sourceSwitchMinHeight: switch (window.windowClass) {
        UiWindowClass.compact => 40.0,
        UiWindowClass.medium => 42.0,
        UiWindowClass.expanded => 44.0,
        UiWindowClass.large || UiWindowClass.extraLarge => 46.0,
      },
      segmentMinHeight: switch (window.windowClass) {
        UiWindowClass.compact => 34.0,
        UiWindowClass.medium => 36.0,
        UiWindowClass.expanded => 38.0,
        UiWindowClass.large || UiWindowClass.extraLarge => 40.0,
      },
      controlHorizontalPadding: switch (window.windowClass) {
        UiWindowClass.compact => 8.0,
        UiWindowClass.medium => 10.0,
        UiWindowClass.expanded => 10.0,
        UiWindowClass.large || UiWindowClass.extraLarge => 12.0,
      },
      controlInnerPadding: switch (window.windowClass) {
        UiWindowClass.compact => 2.0,
        UiWindowClass.medium => 2.5,
        UiWindowClass.expanded => 3.0,
        UiWindowClass.large || UiWindowClass.extraLarge => 3.0,
      },
      labelFontSize: switch (window.windowClass) {
        UiWindowClass.compact => 12.0,
        UiWindowClass.medium => 12.5,
        UiWindowClass.expanded => 13.0,
        UiWindowClass.large || UiWindowClass.extraLarge => 13.5,
      },
      valueFontSize: switch (window.windowClass) {
        UiWindowClass.compact => 12.0,
        UiWindowClass.medium => 12.5,
        UiWindowClass.expanded => 13.0,
        UiWindowClass.large || UiWindowClass.extraLarge => 13.5,
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final backupService = Provider.of<BackupService>(context, listen: false);
      _backupSubscription = backupService.onBackupComplete.listen((_) {
        unawaited(_loadLocalBackups());
      });
      unawaited(_loadLocalBackups());
    });
  }

  @override
  void dispose() {
    _backupSubscription?.cancel();
    super.dispose();
  }

  void _normalizeFilters() {
    final dates = _dateOptions;
    final branches = _branchOptions;
    if (!dates.contains(_selectedDate)) {
      _selectedDate = _allDates;
    }
    if (!branches.contains(_selectedBranch)) {
      _selectedBranch = _allBranches;
    }
  }

  Future<void> _loadLocalBackups() async {
    if (!mounted) return;
    setState(() => _isLoadingLocal = true);
    try {
      final backupService = Provider.of<BackupService>(context, listen: false);
      final files = await backupService.listLocalBackupFiles();
      final loaded = files.map((file) {
        final meta = _parseBackupName(path.basename(file.path), file);
        return _BackupListItem(
          source: _BackupSource.local,
          id: file.path,
          fileName: path.basename(file.path),
          branch: meta.branch,
          dateLabel: meta.dateLabel,
          timeLabel: meta.timeLabel,
          sortEpoch: meta.sortEpoch,
          localFile: file,
          cloudFile: null,
        );
      }).toList()
        ..sort((a, b) => b.sortEpoch.compareTo(a.sortEpoch));

      if (!mounted) return;
      setState(() {
        _localItems = loaded;
        if (_source == _BackupSource.local) {
          _normalizeFilters();
        }
      });
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '로컬 백업 목록 로드 실패: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoadingLocal = false);
    }
  }

  Future<void> _loadCloudBackups() async {
    if (!mounted) return;
    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    if (driveService.currentUser == null) {
      setState(() {
        _cloudItems = <_BackupListItem>[];
        if (_source == _BackupSource.cloud) {
          _normalizeFilters();
        }
      });
      return;
    }

    setState(() => _isLoadingCloud = true);
    try {
      final files = await driveService.listFiles();
      final loaded = files
          .where((f) =>
              (f.id?.isNotEmpty ?? false) && (f.name?.isNotEmpty ?? false))
          .map((f) {
        final name = f.name!;
        final meta =
            _parseBackupName(name, null, fallbackCreatedTime: f.createdTime);
        return _BackupListItem(
          source: _BackupSource.cloud,
          id: f.id!,
          fileName: name,
          branch: meta.branch,
          dateLabel: meta.dateLabel,
          timeLabel: meta.timeLabel,
          sortEpoch: meta.sortEpoch,
          localFile: null,
          cloudFile: f,
        );
      }).toList()
        ..sort((a, b) => b.sortEpoch.compareTo(a.sortEpoch));

      if (!mounted) return;
      setState(() {
        _cloudItems = loaded;
        if (_source == _BackupSource.cloud) {
          _normalizeFilters();
        }
      });
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '클라우드 백업 목록 로드 실패: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoadingCloud = false);
    }
  }

  Future<void> _refreshActive() async {
    if (_source == _BackupSource.local) {
      await _loadLocalBackups();
      return;
    }
    await _loadCloudBackups();
  }

  Future<void> _switchSource(_BackupSource next) async {
    if (_source == next) return;
    setState(() {
      _source = next;
      _selectedDate = _allDates;
      _selectedBranch = _allBranches;
    });
    if (next == _BackupSource.cloud) {
      await _loadCloudBackups();
    } else {
      await _loadLocalBackups();
    }
  }

  _BackupNameMeta _parseBackupName(
    String fileName,
    File? localFile, {
    DateTime? fallbackCreatedTime,
  }) {
    final plain = fileName.replaceAll('.json', '');
    final branchRegex = RegExp(r'^(.+)-(\d{12,14})(?:-\d+)?$');
    final branchMatch = branchRegex.firstMatch(plain);
    if (branchMatch != null) {
      final branch = branchMatch.group(1)!;
      final stamp = branchMatch.group(2)!;
      final dt = _parseStamp(stamp);
      if (dt != null) {
        return _BackupNameMeta(
          branch: branch,
          dateLabel: DateFormat('yyyy-MM-dd').format(dt),
          timeLabel: DateFormat('yyyy-MM-dd HH:mm').format(dt),
          sortEpoch: dt.millisecondsSinceEpoch,
        );
      }
      final fallback = fallbackCreatedTime ??
          (localFile?.statSync().modified ?? DateTime.now());
      return _BackupNameMeta(
        branch: branch,
        dateLabel: DateFormat('yyyy-MM-dd').format(fallback),
        timeLabel: fileName,
        sortEpoch: fallback.millisecondsSinceEpoch,
      );
    }

    final legacyStamp = RegExp(r'^(\d{12,14})').firstMatch(plain)?.group(1);
    final dt = legacyStamp == null ? null : _parseStamp(legacyStamp);
    if (dt != null) {
      return _BackupNameMeta(
        branch: 'unknown',
        dateLabel: DateFormat('yyyy-MM-dd').format(dt),
        timeLabel: DateFormat('yyyy-MM-dd HH:mm').format(dt),
        sortEpoch: dt.millisecondsSinceEpoch,
      );
    }

    final fallback = fallbackCreatedTime ??
        (localFile?.statSync().modified ?? DateTime.now());
    return _BackupNameMeta(
      branch: 'unknown',
      dateLabel: DateFormat('yyyy-MM-dd').format(fallback),
      timeLabel: DateFormat('yyyy-MM-dd HH:mm').format(fallback),
      sortEpoch: fallback.millisecondsSinceEpoch,
    );
  }

  DateTime? _parseStamp(String stamp) {
    try {
      if (stamp.length == 12) {
        return DateTime.parse(
          '${stamp.substring(0, 4)}-${stamp.substring(4, 6)}-${stamp.substring(6, 8)} '
          '${stamp.substring(8, 10)}:${stamp.substring(10, 12)}:00',
        );
      }
      if (stamp.length == 14) {
        return DateTime.parse(
          '${stamp.substring(0, 4)}-${stamp.substring(4, 6)}-${stamp.substring(6, 8)} '
          '${stamp.substring(8, 10)}:${stamp.substring(10, 12)}:${stamp.substring(12, 14)}',
        );
      }
    } catch (_) {}
    return null;
  }

  String? _resolveTargetHost(SSHService ssh) {
    final connected = ssh.connectedIp?.trim();
    if (connected != null && connected.isNotEmpty) return connected;
    final target = ssh.targetIp?.trim();
    if (target != null && target.isNotEmpty) return target;
    return null;
  }

  Future<void> _toggleDriveLink(bool isSignedIn) async {
    if (_isDriveAuthBusy) return;
    setState(() => _isDriveAuthBusy = true);

    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    try {
      if (isSignedIn) {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('구글 드라이브 연동 해제'),
            content: const Text('구글 드라이브 연동을 해제하시겠습니까?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('해제'),
              ),
            ],
          ),
        );
        if (confirm == true) {
          await driveService.signOut();
          if (mounted) {
            setState(() => _cloudItems = <_BackupListItem>[]);
          }
        }
      } else {
        final account = await driveService.signIn();
        if (!mounted) return;
        if (account == null) {
          CustomToast.show(context, '구글 연동이 취소되었습니다.', isError: true);
        } else {
          final backupService =
              Provider.of<BackupService>(context, listen: false);
          backupService.requestEventSync(
            reason: 'drive_linked',
            debounce: const Duration(seconds: 2),
          );
          await _loadCloudBackups();
        }
      }
    } catch (e) {
      if (!mounted) return;
      final message = e.toString();
      final hint =
          (message.contains('10') || message.contains('DEVELOPER_ERROR'))
              ? ' (Google OAuth 설정 확인 필요)'
              : '';
      CustomToast.show(context, '구글 연동 실패: $message$hint', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isDriveAuthBusy = false);
      }
    }
  }

  Future<void> _syncNow() async {
    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    if (driveService.currentUser == null) {
      CustomToast.show(context, '구글 연동 후 사용하세요.', isError: true);
      return;
    }
    final backupService = Provider.of<BackupService>(context, listen: false);
    final result = await backupService.syncBackups(
      driveService,
      reason: 'manual',
    );
    await _loadLocalBackups();
    await _loadCloudBackups();
    if (!mounted) return;
    if (result.skipped) {
      CustomToast.show(context, '동기화 건너뜀 (네트워크/연동/작업 상태 확인)');
      return;
    }
    final summary =
        '동기화 완료 · 업로드 ${result.uploaded} / 다운로드 ${result.downloaded}';
    if (result.failedCount > 0) {
      CustomToast.show(
        context,
        '$summary · 실패 ${result.failedCount}',
        isError: true,
      );
      return;
    }
    if (!result.hasChanges) {
      CustomToast.show(context, '동기화 완료 (변경 없음)');
      return;
    }
    CustomToast.show(context, summary);
  }

  Future<void> _backupNow() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, '기기 연결 후 실행하세요.', isError: true);
      return;
    }
    final backupService = Provider.of<BackupService>(context, listen: false);
    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    await backupService.createBackup(ssh, driveService, isAuto: false);
    await _loadLocalBackups();
    if (driveService.currentUser != null) {
      await _loadCloudBackups();
    }
  }

  Future<Map<String, dynamic>> _readBackupMap(_BackupListItem item) async {
    if (item.source == _BackupSource.local) {
      final local = item.localFile;
      if (local == null) return const <String, dynamic>{};
      final raw = await local.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, dynamic>{};
      return Map<String, dynamic>.from(decoded);
    }

    final cloud = item.cloudFile;
    if (cloud == null || cloud.id == null) {
      return const <String, dynamic>{};
    }

    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    await StorageLayoutService.instance.ensureBaseFolders();
    final tmpDir = Directory(StorageLayoutService.tmpPath);
    if (!await tmpDir.exists()) {
      await tmpDir.create(recursive: true);
    }

    final tempName =
        'cloud_tmp_${DateTime.now().millisecondsSinceEpoch}_${item.fileName}';
    final tempPath = path.join(tmpDir.path, tempName);
    final tempFile = File(tempPath);

    try {
      await driveService.downloadFile(cloud.id!, tempPath);
      final raw = await tempFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, dynamic>{};
      return Map<String, dynamic>.from(decoded);
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Future<void> _showBackupDetails(_BackupListItem item) async {
    FocusManager.instance.primaryFocus?.unfocus();
    Map<String, dynamic> values;
    try {
      values = await _readBackupMap(item);
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '백업 파일 읽기 실패: $e', isError: true);
      return;
    }
    if (!mounted) return;

    final keys = values.keys.map((e) => e.toString()).toList()..sort();
    final action = await showDialog<_BackupDialogAction>(
      context: context,
      builder: (context) {
        final media = MediaQuery.of(context);
        final dialogHeight = (media.size.height *
                (media.size.width > media.size.height ? 0.72 : 0.58))
            .clamp(300.0, 620.0)
            .toDouble();
        return AlertDialog(
          title: Text(item.branch),
          content: SizedBox(
            width: double.maxFinite,
            height: dialogHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${item.timeLabel} · ${keys.length}개 키',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.separated(
                    itemCount: keys.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final key = keys[index];
                      final value = values[key];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            key,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            value?.toString() ?? '(없음)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          Navigator.pop(context);
                        },
                        child: const Text('닫기'),
                      ),
                      TextButton(
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          Navigator.pop(context, _BackupDialogAction.copy);
                        },
                        child: const Text('복사'),
                      ),
                      TextButton(
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          Navigator.pop(context, _BackupDialogAction.delete);
                        },
                        child: const Text('삭제',
                            style: TextStyle(color: Colors.red)),
                      ),
                      FilledButton(
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          Navigator.pop(context, _BackupDialogAction.apply);
                        },
                        child: const Text('적용'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    FocusManager.instance.primaryFocus?.unfocus();

    if (action == _BackupDialogAction.copy) {
      try {
        final jsonText = const JsonEncoder.withIndent('  ').convert(values);
        await Clipboard.setData(ClipboardData(text: jsonText));
        if (!mounted) return;
        CustomToast.show(context, '백업 JSON을 클립보드에 복사했습니다.');
      } catch (e) {
        if (!mounted) return;
        CustomToast.show(context, '복사 실패: $e', isError: true);
      }
      return;
    }
    if (action == _BackupDialogAction.delete) {
      await _deleteSingleBackup(item);
      return;
    }
    if (action == _BackupDialogAction.apply) {
      await _applyBackupValues(item, values);
    }
  }

  Future<void> _applyBackupValues(
      _BackupListItem item, Map<String, dynamic> values) async {
    if (_isApplying) return;
    if (values.isEmpty) {
      if (!mounted) return;
      CustomToast.show(context, '적용할 키가 없습니다.', isError: true);
      return;
    }

    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      if (!mounted) return;
      CustomToast.show(context, '기기 연결 후 적용하세요.', isError: true);
      return;
    }
    final host = _resolveTargetHost(ssh);
    if (host == null) {
      if (!mounted) return;
      CustomToast.show(context, '대상 IP를 확인할 수 없습니다.', isError: true);
      return;
    }

    setState(() {
      _isApplying = true;
      _applyingId = item.id;
    });

    var success = 0;
    var failed = 0;
    try {
      for (final entry in values.entries) {
        try {
          await _carrotServer.setParam(host,
              name: entry.key, value: entry.value);
          success++;
        } catch (_) {
          failed++;
        }
      }
      if (!mounted) return;
      if (failed == 0) {
        CustomToast.show(context, '$success개 키 적용 완료');
      } else {
        CustomToast.show(context, '$success개 적용 / $failed개 실패', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isApplying = false;
          _applyingId = null;
        });
      }
    }
  }

  Future<void> _deleteSingleBackup(_BackupListItem item) async {
    try {
      if (item.source == _BackupSource.local) {
        final local = item.localFile;
        if (local != null && await local.exists()) {
          await local.delete();
        }
        await _loadLocalBackups();
      } else {
        final cloud = item.cloudFile;
        if (cloud != null && cloud.id != null) {
          final driveService =
              Provider.of<GoogleDriveService>(context, listen: false);
          await driveService.deleteFile(cloud.id!);
        }
        await _loadCloudBackups();
      }

      if (!mounted) return;
      CustomToast.show(context, '백업이 삭제되었습니다.');
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '삭제 실패: $e', isError: true);
    }
  }

  Future<bool> _confirmDialog(String title, String content) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _deleteAllLocalBackups() async {
    final ok = await _confirmDialog('로컬 전체 삭제', '로컬 백업 파일을 모두 삭제합니다.');
    if (!ok) return;
    await _deleteLocalAllInternal(showToast: true);
  }

  Future<void> _deleteAllCloudBackups() async {
    final signedIn =
        Provider.of<GoogleDriveService>(context, listen: false).currentUser !=
            null;
    if (!signedIn) {
      CustomToast.show(context, '구글 연동 후 사용하세요.', isError: true);
      return;
    }

    final ok = await _confirmDialog(
      '클라우드 전체 삭제',
      'Google Drive 백업 파일을 모두 삭제합니다.',
    );
    if (!ok) return;
    await _deleteCloudAllInternal(showToast: true, requireSignedIn: true);
  }

  Future<void> _deleteAllBoth() async {
    final ok = await _confirmDialog(
      '전체 삭제',
      '로컬 + 클라우드 백업을 모두 삭제합니다.',
    );
    if (!ok) return;

    await _deleteLocalAllInternal(showToast: false);
    await _deleteCloudAllInternal(showToast: false, requireSignedIn: false);
    if (!mounted) return;
    CustomToast.show(context, '로컬 + 클라우드 전체 삭제 완료');
  }

  Future<void> _deleteLocalAllInternal({required bool showToast}) async {
    try {
      final backupService = Provider.of<BackupService>(context, listen: false);
      final localFiles = await backupService.listLocalBackupFiles();
      for (final file in localFiles) {
        if (await file.exists()) {
          await file.delete();
        }
      }
      await _loadLocalBackups();
      if (!mounted) return;
      if (showToast) {
        CustomToast.show(context, '로컬 백업 전체 삭제 완료');
      }
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '로컬 전체 삭제 실패: $e', isError: true);
    }
  }

  Future<void> _deleteCloudAllInternal({
    required bool showToast,
    required bool requireSignedIn,
  }) async {
    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    if (driveService.currentUser == null) {
      if (requireSignedIn && mounted) {
        CustomToast.show(context, '구글 연동 후 사용하세요.', isError: true);
      }
      return;
    }

    try {
      final files = await driveService.listFiles();
      for (final file in files) {
        if (file.id != null) {
          await driveService.deleteFile(file.id!);
        }
      }
      await _loadCloudBackups();
      if (!mounted) return;
      if (showToast) {
        CustomToast.show(context, '클라우드 백업 전체 삭제 완료');
      }
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '클라우드 전체 삭제 실패: $e', isError: true);
    }
  }

  Widget _buildCompactFilter({
    required String label,
    required String value,
    required List<String> options,
    required ValueChanged<String> onChanged,
  }) {
    final ui = _uiMetrics(context);
    return Container(
      constraints: BoxConstraints(minHeight: ui.filterMinHeight),
      padding: EdgeInsets.symmetric(horizontal: ui.controlHorizontalPadding),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Text(
            '$label ',
            style: TextStyle(
              fontSize: ui.labelFontSize,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                isExpanded: true,
                isDense: true,
                style: TextStyle(
                  fontSize: ui.valueFontSize,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                items: options
                    .map((e) => DropdownMenuItem<String>(
                          value: e,
                          child: Text(
                            e,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: (next) {
                  if (next == null) return;
                  onChanged(next);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceSwitch() {
    final ui = _uiMetrics(context);
    Widget segment({
      required String text,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(minHeight: ui.segmentMinHeight),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              text,
              style: TextStyle(
                fontSize: ui.valueFontSize,
                fontWeight: FontWeight.w700,
                color: selected
                    ? Theme.of(context).colorScheme.onPrimaryContainer
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      constraints: BoxConstraints(minHeight: ui.sourceSwitchMinHeight),
      padding: EdgeInsets.all(ui.controlInnerPadding),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          segment(
            text: '로컬',
            selected: _source == _BackupSource.local,
            onTap: () => unawaited(_switchSource(_BackupSource.local)),
          ),
          segment(
            text: '클라우드',
            selected: _source == _BackupSource.cloud,
            onTap: () => unawaited(_switchSource(_BackupSource.cloud)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final driveService = Provider.of<GoogleDriveService>(context);
    final backupService = Provider.of<BackupService>(context);
    final isSignedIn = driveService.currentUser != null;

    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compactActions = constraints.maxWidth < 680;
                  final driveButton = OutlinedButton.icon(
                    onPressed: _isDriveAuthBusy
                        ? null
                        : () => _toggleDriveLink(isSignedIn),
                    icon: Icon(
                      isSignedIn ? Icons.check_circle : Icons.cloud_off,
                      color: isSignedIn ? Colors.green : null,
                      size: 18,
                    ),
                    label: Text(
                      _isDriveAuthBusy ? '처리중' : (isSignedIn ? '연동됨' : '구글 연동'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                  final menuButton = PopupMenuButton<String>(
                    tooltip: '메뉴',
                    onSelected: (value) {
                      if (value == 'sync') {
                        unawaited(_syncNow());
                      } else if (value == 'local') {
                        unawaited(_deleteAllLocalBackups());
                      } else if (value == 'cloud') {
                        unawaited(_deleteAllCloudBackups());
                      } else if (value == 'both') {
                        unawaited(_deleteAllBoth());
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'sync', child: Text('동기화')),
                      PopupMenuItem(value: 'local', child: Text('로컬 전체 삭제')),
                      PopupMenuItem(value: 'cloud', child: Text('클라우드 전체 삭제')),
                      PopupMenuItem(
                          value: 'both', child: Text('로컬+클라우드 전체 삭제')),
                    ],
                  );

                  if (!compactActions) {
                    return Row(
                      children: [
                        Expanded(child: _buildSourceSwitch()),
                        const SizedBox(width: 8),
                        driveButton,
                        menuButton,
                      ],
                    );
                  }

                  return Column(
                    children: [
                      _buildSourceSwitch(),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: driveButton),
                          menuButton,
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
            if (backupService.isBackingUp)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: LinearProgressIndicator(value: backupService.progress),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compactFilters = constraints.maxWidth < 640;
                  final dateFilter = _buildCompactFilter(
                    label: '날짜',
                    value: _selectedDate,
                    options: _dateOptions,
                    onChanged: (value) => setState(() => _selectedDate = value),
                  );
                  final branchFilter = _buildCompactFilter(
                    label: '브랜치',
                    value: _selectedBranch,
                    options: _branchOptions,
                    onChanged: (value) =>
                        setState(() => _selectedBranch = value),
                  );
                  final refreshButton = IconButton(
                    onPressed: _isLoading ? null : _refreshActive,
                    icon: const Icon(Icons.refresh),
                    tooltip: '새로고침',
                  );

                  if (!compactFilters) {
                    return Row(
                      children: [
                        Expanded(child: dateFilter),
                        const SizedBox(width: 8),
                        Expanded(child: branchFilter),
                        refreshButton,
                      ],
                    );
                  }

                  return Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: dateFilter),
                          const SizedBox(width: 8),
                          Expanded(child: branchFilter),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: refreshButton,
                      ),
                    ],
                  );
                },
              ),
            ),
            Expanded(child: _buildList(isSignedIn: isSignedIn)),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            heroTag: 'carrot_backup_create_fab',
            onPressed: backupService.isBackingUp ? null : _backupNow,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  Widget _buildList({required bool isSignedIn}) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_isCloudMode && !isSignedIn) {
      return Center(
        child: Text(
          '구글 연동 후 클라우드 백업을 확인할 수 있습니다.',
          style:
              TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      );
    }

    final list = _filteredItems;
    if (list.isEmpty) {
      return Center(
        child: Text(
          '조건에 맞는 백업이 없습니다.',
          style:
              TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 86),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = list[index];
        final isApplying = _isApplying && _applyingId == item.id;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          child: ListTile(
            dense: true,
            onTap: (_isApplying && !isApplying)
                ? null
                : () => _showBackupDetails(item),
            title: Text(
              item.branch,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(item.timeLabel),
            trailing: isApplying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
          ),
        );
      },
    );
  }
}

class _BackupNameMeta {
  final String branch;
  final String dateLabel;
  final String timeLabel;
  final int sortEpoch;

  const _BackupNameMeta({
    required this.branch,
    required this.dateLabel,
    required this.timeLabel,
    required this.sortEpoch,
  });
}

class _BackupListItem {
  final _BackupSource source;
  final String id;
  final String fileName;
  final String branch;
  final String dateLabel;
  final String timeLabel;
  final int sortEpoch;
  final File? localFile;
  final drive.File? cloudFile;

  const _BackupListItem({
    required this.source,
    required this.id,
    required this.fileName,
    required this.branch,
    required this.dateLabel,
    required this.timeLabel,
    required this.sortEpoch,
    required this.localFile,
    required this.cloudFile,
  });
}
