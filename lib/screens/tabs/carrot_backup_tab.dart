import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../../models/carrot_profile_models.dart';
import '../../services/backup_service.dart';
import '../../services/carrot_profile_service.dart';
import '../../services/carrot_server_settings_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/ssh_service.dart';
import '../../services/storage_layout_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/custom_toast.dart';
import 'carrot_profile_editor_screen.dart';

enum _BackupSource { local, cloud, profile }

enum _BackupDialogAction { copy, apply, delete }

class CarrotBackupTab extends StatefulWidget {
  const CarrotBackupTab({super.key});

  @override
  State<CarrotBackupTab> createState() => _CarrotBackupTabState();
}

class _CarrotBackupTabState extends State<CarrotBackupTab>
    with WidgetsBindingObserver {
  static const String _allDates = '전체 날짜';
  static const String _allBranches = '전체 브랜치';
  static const Duration _autoRefreshInterval = Duration(minutes: 1);

  final CarrotServerSettingsService _carrotServer =
      CarrotServerSettingsService();
  final CarrotProfileService _profileService = CarrotProfileService();

  _BackupSource _source = _BackupSource.local;
  List<_BackupListItem> _localItems = <_BackupListItem>[];
  List<_BackupListItem> _cloudItems = <_BackupListItem>[];
  List<_BackupListItem> _profileItems = <_BackupListItem>[];

  String _selectedDate = _allDates;
  String _selectedBranch = _allBranches;

  bool _isLoadingLocal = false;
  bool _isLoadingCloud = false;
  bool _isLoadingProfile = false;
  bool _isApplying = false;
  String? _applyingId;
  bool _isDriveAuthBusy = false;

  StreamSubscription<void>? _backupSubscription;
  Timer? _autoRefreshTimer;

  List<_BackupListItem> get _activeItems => switch (_source) {
        _BackupSource.local => _localItems,
        _BackupSource.cloud => _cloudItems,
        _BackupSource.profile => _profileItems,
      };

  bool get _isLoading => switch (_source) {
        _BackupSource.local => _isLoadingLocal,
        _BackupSource.cloud => _isLoadingCloud,
        _BackupSource.profile => _isLoadingProfile,
      };

  bool get _isCloudMode => _source == _BackupSource.cloud;
  bool get _isProfileMode => _source == _BackupSource.profile;

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
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final backupService = Provider.of<BackupService>(context, listen: false);
      _backupSubscription = backupService.onBackupComplete.listen((_) {
        unawaited(_handleBackupChanged());
      });
      _startAutoRefreshLoop();
      unawaited(_loadLocalBackups());
      unawaited(_loadProfiles(silent: true));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backupSubscription?.cancel();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshActive(silent: true));
    }
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

  void _startAutoRefreshLoop() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      unawaited(_refreshActive(silent: true));
    });
  }

  Future<void> _handleBackupChanged() async {
    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    await _loadLocalBackups(silent: true);
    if (!mounted) return;
    if (driveService.currentUser != null) {
      await _loadCloudBackups(silent: true);
    }
  }

  Future<void> _loadLocalBackups({bool silent = false}) async {
    if (!mounted) return;
    final showLoading = !silent || _localItems.isEmpty;
    if (showLoading) {
      setState(() => _isLoadingLocal = true);
    }
    try {
      final backupService = Provider.of<BackupService>(context, listen: false);
      final files = await backupService.listLocalBackupFiles();
      final loaded = files.map((file) {
        final meta = _parseBackupName(path.basename(file.path), file);
        return _BackupListItem(
          source: _BackupSource.local,
          id: file.path,
          fileName: path.basename(file.path),
          title: meta.branch,
          subtitle: meta.timeLabel,
          branch: meta.branch,
          dateLabel: meta.dateLabel,
          timeLabel: meta.timeLabel,
          sortEpoch: meta.sortEpoch,
          localFile: file,
          cloudFile: null,
          profileHeader: null,
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
      if (!silent) {
        CustomToast.show(context, '로컬 백업 목록 로드 실패: $e', isError: true);
      }
    } finally {
      if (mounted && showLoading) setState(() => _isLoadingLocal = false);
    }
  }

  Future<void> _loadCloudBackups({bool silent = false}) async {
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

    final showLoading = !silent || _cloudItems.isEmpty;
    if (showLoading) {
      setState(() => _isLoadingCloud = true);
    }
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
          title: meta.branch,
          subtitle: meta.timeLabel,
          branch: meta.branch,
          dateLabel: meta.dateLabel,
          timeLabel: meta.timeLabel,
          sortEpoch: meta.sortEpoch,
          localFile: null,
          cloudFile: f,
          profileHeader: null,
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
      if (!silent) {
        CustomToast.show(context, '클라우드 백업 목록 로드 실패: $e', isError: true);
      }
    } finally {
      if (mounted && showLoading) setState(() => _isLoadingCloud = false);
    }
  }

  Future<void> _loadProfiles({bool silent = false}) async {
    if (!mounted) return;
    final showLoading = !silent || _profileItems.isEmpty;
    if (showLoading) {
      setState(() => _isLoadingProfile = true);
    }
    try {
      final profiles = await _profileService.listProfiles();
      final loaded = profiles.map((header) {
        final updatedAt = DateTime.fromMillisecondsSinceEpoch(
          header.updatedAtMs > 0 ? header.updatedAtMs : header.createdAtMs,
        );
        return _BackupListItem(
          source: _BackupSource.profile,
          id: header.id,
          fileName: '${header.id}.json',
          title: header.name,
          subtitle:
              '${DateFormat('yyyy-MM-dd HH:mm').format(updatedAt)} · ${header.sourceBranch} · ${header.paramCount}개',
          branch: header.sourceBranch,
          dateLabel: DateFormat('yyyy-MM-dd').format(updatedAt),
          timeLabel: DateFormat('yyyy-MM-dd HH:mm').format(updatedAt),
          sortEpoch: updatedAt.millisecondsSinceEpoch,
          localFile: null,
          cloudFile: null,
          profileHeader: header,
        );
      }).toList()
        ..sort((a, b) => b.sortEpoch.compareTo(a.sortEpoch));

      if (!mounted) return;
      setState(() {
        _profileItems = loaded;
        if (_source == _BackupSource.profile) {
          _normalizeFilters();
        }
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        CustomToast.show(context, '프로필 목록 로드 실패: $e', isError: true);
      }
    } finally {
      if (mounted && showLoading) setState(() => _isLoadingProfile = false);
    }
  }

  Future<void> _refreshActive({bool silent = false}) async {
    if (!mounted || _isApplying || _isDriveAuthBusy) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (silent && lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    if (_source == _BackupSource.local) {
      await _loadLocalBackups(silent: silent);
      return;
    }
    if (_source == _BackupSource.profile) {
      await _loadProfiles(silent: silent);
      return;
    }
    final driveService =
        Provider.of<GoogleDriveService>(context, listen: false);
    if (driveService.currentUser == null) return;
    await _loadCloudBackups(silent: silent);
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
    } else if (next == _BackupSource.profile) {
      await _loadProfiles();
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

  Future<String?> _promptProfileName({
    required String title,
    String? initialValue,
  }) async {
    final controller = TextEditingController(text: initialValue ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '프로필 이름',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    final trimmed = result?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  Future<void> _createProfileFromCurrentDevice() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, '기기 연결 후 프로필을 저장하세요.', isError: true);
      return;
    }
    final host = _resolveTargetHost(ssh);
    if (host == null) {
      CustomToast.show(context, '대상 IP를 확인할 수 없습니다.', isError: true);
      return;
    }
    final name = await _promptProfileName(title: '새 프로필 저장');
    if (name == null) return;

    try {
      await _profileService.createProfileFromDevice(
        name: name,
        host: host,
        ssh: ssh,
      );
      await _loadProfiles(silent: true);
      if (!mounted) return;
      setState(() {
        _source = _BackupSource.profile;
        _selectedDate = _allDates;
        _selectedBranch = _allBranches;
      });
      CustomToast.show(context, '프로필 저장 완료');
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '프로필 저장 실패: $e', isError: true);
    }
  }

  Future<void> _openProfileEditor(CarrotProfileDocument document) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CarrotProfileEditorScreen(
          document: document,
          service: _profileService,
        ),
      ),
    );
    if (!mounted) return;
    await _loadProfiles(silent: true);
  }

  Future<void> _openProfileFromItem(_BackupListItem item) async {
    final document = await _profileService.readProfile(item.id);
    if (document == null) {
      if (!mounted) return;
      CustomToast.show(context, '프로필을 찾을 수 없습니다.', isError: true);
      await _loadProfiles(silent: true);
      return;
    }
    if (!mounted) return;
    await _openProfileEditor(document);
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

    final action = await showModalBottomSheet<_BackupDialogAction>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  item.subtitle,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.playlist_add_check_circle_outlined),
                  title: const Text('적용'),
                  subtitle: const Text('이 백업 값을 현재 기기에 적용'),
                  onTap: () =>
                      Navigator.pop(context, _BackupDialogAction.apply),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.copy_all_outlined),
                  title: const Text('복사'),
                  subtitle: const Text('백업 JSON을 클립보드에 복사'),
                  onTap: () => Navigator.pop(context, _BackupDialogAction.copy),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    '삭제',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  subtitle: const Text('이 백업 항목 삭제'),
                  onTap: () =>
                      Navigator.pop(context, _BackupDialogAction.delete),
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
      await _applyValueMap(
        applyId: item.id,
        values: values,
      );
    }
  }

  Future<void> _applyValueMap({
    required String applyId,
    required Map<String, dynamic> values,
  }) async {
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
      _applyingId = applyId;
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
      } else if (item.source == _BackupSource.cloud) {
        final cloud = item.cloudFile;
        if (cloud != null && cloud.id != null) {
          final driveService =
              Provider.of<GoogleDriveService>(context, listen: false);
          await driveService.deleteFile(cloud.id!);
        }
        await _loadCloudBackups();
      } else {
        await _profileService.deleteProfile(item.id);
        await _loadProfiles(silent: true);
      }

      if (!mounted) return;
      CustomToast.show(
        context,
        item.source == _BackupSource.profile ? '프로필이 삭제되었습니다.' : '백업이 삭제되었습니다.',
      );
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

  Future<void> _deleteAllProfiles() async {
    final ok = await _confirmDialog('프로필 전체 삭제', '저장된 프로필을 모두 삭제합니다.');
    if (!ok) return;
    try {
      await _profileService.deleteAllProfiles();
      await _loadProfiles(silent: true);
      if (!mounted) return;
      CustomToast.show(context, '프로필 전체 삭제 완료');
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '프로필 전체 삭제 실패: $e', isError: true);
    }
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
          segment(
            text: '프로필',
            selected: _source == _BackupSource.profile,
            onTap: () => unawaited(_switchSource(_BackupSource.profile)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final driveService = Provider.of<GoogleDriveService>(context);
    final backupService = Provider.of<BackupService>(context);
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final ui = _uiMetrics(context);
    final media = MediaQuery.of(context);
    final isSignedIn = driveService.currentUser != null;
    final horizontalPadding = tokens.screenPadding.clamp(12.0, 24.0).toDouble();
    final panelTopPadding = window.isCompact ? 10.0 : 12.0;
    final sourceSectionGap = window.isCompact ? 8.0 : 9.0;
    final filterTopPadding = window.isCompact ? 9.0 : 10.0;
    final filterBottomPadding = window.isCompact ? 7.0 : 8.0;
    final filterGap = window.isCompact ? 6.0 : 8.0;
    final fabBottomInset = math.max(16.0, media.padding.bottom + 12.0);
    final listBottomPadding = math.max(86.0, media.padding.bottom + 82.0);
    final isTinyLandscape =
        media.orientation == Orientation.landscape && media.size.height < 560.0;

    final topSection = Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            panelTopPadding,
            horizontalPadding,
            0,
          ),
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
                  } else if (value == 'save_profile') {
                    unawaited(_createProfileFromCurrentDevice());
                  } else if (value == 'local') {
                    unawaited(_deleteAllLocalBackups());
                  } else if (value == 'cloud') {
                    unawaited(_deleteAllCloudBackups());
                  } else if (value == 'profile') {
                    unawaited(_deleteAllProfiles());
                  } else if (value == 'both') {
                    unawaited(_deleteAllBoth());
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'sync', child: Text('동기화')),
                  PopupMenuItem(
                      value: 'save_profile', child: Text('현재 기기로 프로필 저장')),
                  PopupMenuItem(value: 'local', child: Text('로컬 전체 삭제')),
                  PopupMenuItem(value: 'cloud', child: Text('클라우드 전체 삭제')),
                  PopupMenuItem(value: 'profile', child: Text('프로필 전체 삭제')),
                  PopupMenuItem(value: 'both', child: Text('로컬+클라우드 전체 삭제')),
                ],
              );

              if (!compactActions) {
                return Row(
                  children: [
                    Expanded(child: _buildSourceSwitch()),
                    SizedBox(width: filterGap),
                    Flexible(
                      fit: FlexFit.loose,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: ui.sourceSwitchMinHeight,
                          minWidth: 98,
                          maxWidth: switch (window.windowClass) {
                            UiWindowClass.compact => 132.0,
                            UiWindowClass.medium => 140.0,
                            UiWindowClass.expanded => 148.0,
                            UiWindowClass.large ||
                            UiWindowClass.extraLarge =>
                              156.0,
                          },
                        ),
                        child: driveButton,
                      ),
                    ),
                    menuButton,
                  ],
                );
              }

              return Column(
                children: [
                  _buildSourceSwitch(),
                  SizedBox(height: sourceSectionGap),
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
        Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            filterTopPadding,
            horizontalPadding,
            filterBottomPadding,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compactFilters = constraints.maxWidth < 700;
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
                onChanged: (value) => setState(() => _selectedBranch = value),
              );
              return Row(
                children: [
                  Expanded(child: dateFilter),
                  SizedBox(width: compactFilters ? 6 : filterGap),
                  Expanded(child: branchFilter),
                ],
              );
            },
          ),
        ),
      ],
    );

    return Stack(
      children: [
        if (isTinyLandscape)
          CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: topSection),
              SliverToBoxAdapter(
                child: _buildList(
                  isSignedIn: isSignedIn,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  listBottomPadding: listBottomPadding,
                ),
              ),
            ],
          )
        else
          Column(
            children: [
              topSection,
              Expanded(
                child: _buildList(
                  isSignedIn: isSignedIn,
                  listBottomPadding: listBottomPadding,
                ),
              ),
            ],
          ),
        Positioned(
          right: horizontalPadding,
          bottom: fabBottomInset,
          child: FloatingActionButton(
            heroTag: 'carrot_backup_create_fab',
            onPressed: backupService.isBackingUp
                ? null
                : (_isProfileMode
                    ? _createProfileFromCurrentDevice
                    : _backupNow),
            child: Icon(_isProfileMode ? Icons.bookmark_add : Icons.add),
          ),
        ),
      ],
    );
  }

  Widget _buildList({
    required bool isSignedIn,
    bool shrinkWrap = false,
    ScrollPhysics? physics,
    required double listBottomPadding,
  }) {
    final horizontalPadding =
        UiLayoutTokens.of(context).screenPadding.clamp(12.0, 24.0).toDouble();
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
          _isProfileMode ? '조건에 맞는 프로필이 없습니다.' : '조건에 맞는 백업이 없습니다.',
          style:
              TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: shrinkWrap,
      physics: physics,
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        0,
        horizontalPadding,
        listBottomPadding,
      ),
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
                : () => item.source == _BackupSource.profile
                    ? _openProfileFromItem(item)
                    : _showBackupDetails(item),
            title: Text(
              item.title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(item.subtitle),
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
  final String title;
  final String subtitle;
  final String branch;
  final String dateLabel;
  final String timeLabel;
  final int sortEpoch;
  final File? localFile;
  final drive.File? cloudFile;
  final CarrotProfileHeader? profileHeader;

  const _BackupListItem({
    required this.source,
    required this.id,
    required this.fileName,
    required this.title,
    required this.subtitle,
    required this.branch,
    required this.dateLabel,
    required this.timeLabel,
    required this.sortEpoch,
    required this.localFile,
    required this.cloudFile,
    required this.profileHeader,
  });
}
