import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/carrot_profile_models.dart';
import '../../models/carrot_settings_models.dart';
import '../../services/backup_service.dart';
import '../../services/carrot_profile_compare_service.dart';
import '../../services/carrot_profile_service.dart';
import '../../services/carrot_server_settings_service.dart';
import '../../services/ssh_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/custom_toast.dart';
import 'carrot_profile_compare_screen.dart';
import 'widgets/carrot_setting_editor_widgets.dart';
import 'widgets/carrot_setting_group_status_widgets.dart';

enum _ProfileMenuAction {
  close,
  rename,
  duplicate,
  compare,
  apply,
  delete,
}

class CarrotProfileEditorScreen extends StatefulWidget {
  final CarrotProfileDocument document;
  final CarrotProfileService service;

  const CarrotProfileEditorScreen({
    super.key,
    required this.document,
    required this.service,
  });

  @override
  State<CarrotProfileEditorScreen> createState() =>
      _CarrotProfileEditorScreenState();
}

class _CarrotProfileEditorScreenState extends State<CarrotProfileEditorScreen> {
  static const Duration _highlightDuration = Duration(seconds: 2);
  static const Duration _persistDebounceDelay = Duration(milliseconds: 320);
  static const double _estimatedRowExtent = 150.0;
  static const double _estimatedGroupHeaderExtent = 52.0;

  final CarrotProfileCompareService _profileCompareService =
      const CarrotProfileCompareService();
  final CarrotServerSettingsService _carrotServer =
      CarrotServerSettingsService();

  late CarrotProfileDocument _document;
  late final TextEditingController _searchController;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _listViewportKey = GlobalKey();
  final Map<String, GlobalKey> _rowKeysByName = <String, GlobalKey>{};
  final Map<String, GlobalKey> _groupHeaderKeys = <String, GlobalKey>{};
  final Map<String, double> _groupScrollOffsets = <String, double>{};
  final Map<String, int> _stepByName = <String, int>{};
  final Map<String, double> _sliderDraftByName = <String, double>{};
  final Set<String> _collapsedGroups = <String>{};
  String _query = '';
  String? _highlightedItemName;
  String? _visibleGroup;
  String? _busyLabel;
  Timer? _highlightClearTimer;
  Timer? _persistDebounceTimer;
  bool _menuBusy = false;
  bool _groupSyncScheduled = false;
  bool _persistInFlight = false;
  bool _persistQueued = false;

  CarrotSettingsBundle get _bundle => _document.bundle;

  @override
  void initState() {
    super.initState();
    _document = widget.document;
    _visibleGroup = _orderedGroups().isEmpty ? null : _orderedGroups().first;
    _searchController = TextEditingController()
      ..addListener(() {
        final next = _searchController.text.trim();
        if (next == _query) return;
        setState(() {
          _query = next;
          if (_query.isNotEmpty) {
            _collapsedGroups.clear();
          }
        });
        _groupScrollOffsets.clear();
        _scheduleVisibleGroupSync();
      });
    _scrollController.addListener(_scheduleVisibleGroupSync);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scheduleVisibleGroupSync();
    });
  }

  @override
  void dispose() {
    _highlightClearTimer?.cancel();
    _persistDebounceTimer?.cancel();
    _scrollController.removeListener(_scheduleVisibleGroupSync);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<String> _orderedGroups() {
    final groups = <String>[
      ..._bundle.groups.map((e) => e.group).where((e) => e.trim().isNotEmpty),
      ..._bundle.itemsByGroup.keys.where((e) => e.trim().isNotEmpty),
    ];
    final seen = <String>{};
    final ordered = <String>[];
    for (final group in groups) {
      if (seen.add(group)) ordered.add(group);
    }
    return ordered;
  }

  List<CarrotSettingItemMeta> _filteredItemsForGroup(String group) {
    final items =
        _bundle.itemsByGroup[group] ?? const <CarrotSettingItemMeta>[];
    if (_query.isEmpty) return items;
    final needle = _query.toLowerCase();
    return items.where((item) {
      final haystack = <String>[
        item.displayTitle,
        item.name,
        item.displayDescription ?? '',
        item.group,
      ].join(' ').toLowerCase();
      return haystack.contains(needle);
    }).toList();
  }

  List<CarrotSettingItemMeta> _flatFilteredItems() {
    final out = <CarrotSettingItemMeta>[];
    for (final group in _orderedGroups()) {
      out.addAll(_filteredItemsForGroup(group));
    }
    return out;
  }

  dynamic _effectiveValue(CarrotSettingItemMeta item) {
    return _document.values.containsKey(item.name)
        ? _document.values[item.name]
        : item.defaultValue;
  }

  bool _sameSettingValue(dynamic a, dynamic b) {
    if (a is num && b is num) {
      return (a.toDouble() - b.toDouble()).abs() < 0.0001;
    }
    return a?.toString() == b?.toString();
  }

  GlobalKey _rowKeyFor(String name) {
    return _rowKeysByName.putIfAbsent(name, () => GlobalKey());
  }

  GlobalKey _groupHeaderKeyFor(String group) {
    return _groupHeaderKeys.putIfAbsent(group, () => GlobalKey());
  }

  String? _groupForItemName(String itemName) {
    for (final entry in _bundle.itemsByGroup.entries) {
      final found = entry.value.any((item) => item.name == itemName);
      if (found) return entry.key;
    }
    return null;
  }

  void _toggleGroup(String group) {
    setState(() {
      if (_collapsedGroups.contains(group)) {
        _collapsedGroups.remove(group);
      } else {
        _collapsedGroups.add(group);
      }
      _visibleGroup = group;
    });
    _groupScrollOffsets.clear();
    _scheduleVisibleGroupSync();
  }

  void _expandAllGroups() {
    if (_collapsedGroups.isEmpty) return;
    setState(() {
      _collapsedGroups.clear();
    });
    _groupScrollOffsets.clear();
    _scheduleVisibleGroupSync();
  }

  void _collapseAllGroups() {
    final groups = _orderedGroups()
        .where((group) => _filteredItemsForGroup(group).isNotEmpty)
        .toList();
    if (groups.isEmpty) return;
    setState(() {
      _collapsedGroups
        ..clear()
        ..addAll(groups);
    });
    _groupScrollOffsets.clear();
    _scheduleVisibleGroupSync();
  }

  void _scheduleVisibleGroupSync() {
    if (_groupSyncScheduled) return;
    _groupSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _groupSyncScheduled = false;
      if (!mounted) return;
      _syncVisibleGroup();
    });
  }

  void _syncVisibleGroup() {
    final groups = _orderedGroups()
        .where((group) => _filteredItemsForGroup(group).isNotEmpty)
        .toList();
    if (groups.isEmpty) {
      if (_visibleGroup != null) {
        setState(() => _visibleGroup = null);
      }
      return;
    }

    final viewportContext = _listViewportKey.currentContext;
    if (viewportContext == null || !viewportContext.mounted) return;
    final viewportBox = viewportContext.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy + 4;
    final currentScrollOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    for (final group in groups) {
      final ctx = _groupHeaderKeyFor(group).currentContext;
      if (ctx == null || !ctx.mounted) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      _groupScrollOffsets[group] = currentScrollOffset + (top - viewportTop);
    }

    String nextGroup = _visibleGroup ?? groups.first;
    double? bestAboveOffset;
    double? bestBelowOffset;
    final probeOffset = currentScrollOffset + 12;
    for (final group in groups) {
      final offset = _groupScrollOffsets[group];
      if (offset == null) continue;
      if (offset <= probeOffset) {
        if (bestAboveOffset == null || offset > bestAboveOffset) {
          bestAboveOffset = offset;
          nextGroup = group;
        }
      } else if (bestAboveOffset == null) {
        if (bestBelowOffset == null || offset < bestBelowOffset) {
          bestBelowOffset = offset;
          nextGroup = group;
        }
      }
    }

    if (_visibleGroup != nextGroup) {
      setState(() => _visibleGroup = nextGroup);
    }
  }

  double _estimateGroupScrollOffset(String targetGroup) {
    final measured = _groupScrollOffsets[targetGroup];
    if (measured != null) return measured;
    const itemGap = 10.0;
    var offset = 0.0;
    for (final group in _orderedGroups()) {
      final items = _filteredItemsForGroup(group);
      if (items.isEmpty) continue;
      if (group == targetGroup) break;
      offset += _estimatedGroupHeaderExtent;
      if (!(_query.isEmpty && _collapsedGroups.contains(group))) {
        offset += items.length * (_estimatedRowExtent + itemGap);
      }
    }
    return offset;
  }

  void _setHighlighted(String itemName) {
    _highlightClearTimer?.cancel();
    setState(() => _highlightedItemName = itemName);
    _highlightClearTimer = Timer(_highlightDuration, () {
      if (!mounted) return;
      setState(() {
        if (_highlightedItemName == itemName) {
          _highlightedItemName = null;
        }
      });
    });
  }

  Future<void> _focusItemByName(String itemName) async {
    final group = _groupForItemName(itemName);
    if (group != null && _collapsedGroups.contains(group)) {
      setState(() => _collapsedGroups.remove(group));
    }
    final items = _flatFilteredItems();
    final index = items.indexWhere((e) => e.name == itemName);
    if (index < 0) return;

    if (_scrollController.hasClients) {
      final target = (index * _estimatedRowExtent).toDouble();
      final max = _scrollController.position.maxScrollExtent;
      await _scrollController.animateTo(
        target.clamp(0.0, max),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (!mounted) return;
    final ctx = _rowKeyFor(itemName).currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.2,
      );
    }
    _setHighlighted(itemName);
  }

  String get _statusModeText {
    if (_menuBusy) return '작업 중';
    return '편집 모드';
  }

  String get _statusDetailText {
    if (_busyLabel != null && _busyLabel!.trim().isNotEmpty) {
      return _busyLabel!;
    }
    if (_visibleGroup != null && _visibleGroup!.trim().isNotEmpty) {
      return _visibleGroup!;
    }
    return '프로필 오프라인 편집';
  }

  IconData get _statusIcon {
    if (_menuBusy) return Icons.sync;
    return Icons.edit;
  }

  void _schedulePersistDocument() {
    _persistDebounceTimer?.cancel();
    _persistDebounceTimer = Timer(_persistDebounceDelay, () {
      unawaited(_flushPersistDocument());
    });
  }

  Future<void> _flushPersistDocument() async {
    if (_persistInFlight) {
      _persistQueued = true;
      return;
    }
    _persistInFlight = true;
    try {
      while (mounted) {
        _persistQueued = false;
        final snapshot = _document;
        final saved = await widget.service.saveEditedProfile(snapshot);
        if (!mounted) return;
        if (identical(_document, snapshot)) {
          _document = saved;
        } else {
          _document = _document.copyWith(
            header: saved.header,
            settingsBundleJson: saved.settingsBundleJson,
          );
        }
        if (!_persistQueued) break;
      }
    } catch (e) {
      if (mounted) {
        CustomToast.show(context, '프로필 저장 실패: $e', isError: true);
      }
    } finally {
      _persistInFlight = false;
      if (mounted && _persistQueued) {
        unawaited(_flushPersistDocument());
      }
    }
  }

  Future<void> _showSearchResultPicker() async {
    final items = _flatFilteredItems();
    if (items.isEmpty) {
      CustomToast.show(context, '검색 결과가 없습니다.');
      return;
    }
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final sheetHorizontalPadding = window.isCompact
        ? 12.0
        : tokens.screenPadding.clamp(12.0, 22.0).toDouble();
    final searchSubtitleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 12.5,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };
    final selected = await showModalBottomSheet<CarrotSettingItemMeta>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        return ListView.separated(
          padding: EdgeInsets.fromLTRB(
            sheetHorizontalPadding,
            4,
            sheetHorizontalPadding,
            12,
          ),
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = items[index];
            return ListTile(
              title: Text(item.displayTitle),
              subtitle: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: searchSubtitleFontSize),
              ),
              trailing: const Icon(Icons.my_location),
              onTap: () => Navigator.of(context).pop(item),
            );
          },
        );
      },
    );
    if (!mounted || selected == null) return;
    await _focusItemByName(selected.name);
  }

  List<int> _unitCycleValues() {
    final cleaned = _bundle.unitCycle.where((e) => e > 0).toSet().toList()
      ..sort();
    return cleaned.isEmpty ? const [1, 2, 5, 10, 50, 100] : cleaned;
  }

  int _defaultStepFor(CarrotSettingItemMeta item) {
    final cycle = _unitCycleValues();
    final preferred = (item.unit ?? 1) <= 0 ? 1 : item.unit!;
    if (cycle.contains(preferred)) return preferred;
    for (final candidate in cycle) {
      if (candidate >= preferred) return candidate;
    }
    return cycle.last;
  }

  int _stepFor(CarrotSettingItemMeta item) =>
      _stepByName[item.name] ?? _defaultStepFor(item);

  void _cycleStep(CarrotSettingItemMeta item) {
    final cycle = _unitCycleValues();
    if (cycle.isEmpty) return;
    final current = _stepFor(item);
    final idx = cycle.indexOf(current);
    final next = idx < 0 ? cycle.first : cycle[(idx + 1) % cycle.length];
    setState(() => _stepByName[item.name] = next);
  }

  num? _asNumValue(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value.trim());
    return null;
  }

  dynamic _normalizeNumericValue(CarrotSettingItemMeta item, num raw) {
    var next = raw.toDouble();
    if (item.min != null && next < item.min!.toDouble()) {
      next = item.min!.toDouble();
    }
    if (item.max != null && next > item.max!.toDouble()) {
      next = item.max!.toDouble();
    }
    if (item.isIntegerRange) return next.round();
    return next;
  }

  int? _sliderDivisions(CarrotSettingItemMeta item, int step) {
    if (item.min == null || item.max == null || step <= 0) return null;
    final range = (item.max!.toDouble() - item.min!.toDouble()).abs();
    if (range <= 0) return null;
    final divisions = (range / step).round();
    if (divisions <= 0) return 1;
    return divisions > 1000 ? 1000 : divisions;
  }

  double? _sliderValueFor(CarrotSettingItemMeta item) {
    if (!item.supportsSlider || item.min == null || item.max == null) {
      return null;
    }
    final raw =
        _sliderDraftByName[item.name] ?? _asNumValue(_effectiveValue(item));
    if (raw == null) return null;
    final min = item.min!.toDouble();
    final max = item.max!.toDouble();
    return raw.toDouble().clamp(min, max);
  }

  Future<void> _saveValue(CarrotSettingItemMeta item, dynamic value) async {
    final current = _effectiveValue(item);
    if (_sameSettingValue(current, value)) {
      return;
    }
    final nextValues = Map<String, dynamic>.from(_document.values)
      ..[item.name] = value;
    setState(() {
      _document = _document.copyWith(values: nextValues);
      _sliderDraftByName.remove(item.name);
    });
    _schedulePersistDocument();
  }

  Future<void> _showQuickValueInput(CarrotSettingItemMeta item) async {
    final controller = TextEditingController(
      text: carrotDisplaySettingValue(_effectiveValue(item)),
    );
    final submitted = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.displayTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(
            labelText: '값 입력',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (!mounted || submitted == null) return;
    final parsed = num.tryParse(submitted.trim());
    if (parsed == null) {
      CustomToast.show(context, '숫자를 입력하세요.', isError: true);
      return;
    }
    await _saveValue(item, _normalizeNumericValue(item, parsed));
  }

  Future<void> _openEditor(CarrotSettingItemMeta item) async {
    if (item.isBooleanLike) {
      final next = !carrotAsBoolLike(_effectiveValue(item));
      await _saveValue(item, next ? 1 : 0);
      return;
    }
    await _showQuickValueInput(item);
  }

  String? _resolveTargetHost(SSHService ssh) {
    final host = (ssh.connectedIp ?? ssh.targetIp)?.trim();
    if (host == null || host.isEmpty) return null;
    return host;
  }

  Future<Map<String, dynamic>> _fetchCurrentParamsInChunks(
    String host,
    List<String> keys,
  ) async {
    if (keys.isEmpty) return const <String, dynamic>{};
    final out = <String, dynamic>{};
    const chunkSize = 80;
    for (var i = 0; i < keys.length; i += chunkSize) {
      final end = i + chunkSize > keys.length ? keys.length : i + chunkSize;
      final chunk = keys.sublist(i, end);
      out.addAll(await _carrotServer.fetchParamsBulk(host, chunk));
    }
    return out;
  }

  Future<Map<String, dynamic>?> _readLatestLocalBackupMap() async {
    final backupService = Provider.of<BackupService>(context, listen: false);
    final files = await backupService.listLocalBackupFiles();
    if (files.isEmpty) return null;
    final latest = files.first;
    final decoded = jsonDecode(await latest.readAsString());
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _jumpToVisibleGroup() async {
    final group = _visibleGroup;
    if (group == null || group.trim().isEmpty) return;
    final ctx = _groupHeaderKeyFor(group).currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignment: 0,
      );
      return;
    }
    if (!_scrollController.hasClients) return;
    final target = _estimateGroupScrollOffset(group);
    final max = _scrollController.position.maxScrollExtent;
    await _scrollController.animateTo(
      target.clamp(0.0, max),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    await Future<void>.delayed(const Duration(milliseconds: 16));
    if (!mounted) return;
    final nextContext = _groupHeaderKeyFor(group).currentContext;
    if (nextContext != null && nextContext.mounted) {
      await Scrollable.ensureVisible(
        nextContext,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: 0,
      );
    }
  }

  Future<bool> _confirmApplyDialog({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('아니오'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('예'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<int> _applyCompareProfileToCurrentDevice(
    List<CarrotProfileDiffEntry> entries,
  ) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    final host = _resolveTargetHost(ssh);
    if (!ssh.isConnected || host == null) {
      throw Exception('기기 연결 후 적용하세요.');
    }

    setState(() {
      _menuBusy = true;
      _busyLabel = '비교값을 현재 기기에 적용 중';
    });
    var success = 0;
    try {
      for (final entry in entries) {
        if (!_document.values.containsKey(entry.key)) continue;
        await _carrotServer.setParam(
          host,
          name: entry.key,
          value: _document.values[entry.key],
        );
        success++;
      }
      return success;
    } finally {
      if (mounted) {
        setState(() {
          _menuBusy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<int> _applyCompareBaselineToProfile(
    Map<String, dynamic> baseline,
    List<CarrotProfileDiffEntry> entries,
  ) async {
    setState(() {
      _menuBusy = true;
      _busyLabel = '비교 기준값을 프로필에 적용 중';
    });
    try {
      final nextValues = Map<String, dynamic>.from(_document.values);
      var changed = 0;
      for (final entry in entries) {
        if (baseline.containsKey(entry.key)) {
          nextValues[entry.key] = baseline[entry.key];
          changed++;
        } else if (nextValues.containsKey(entry.key)) {
          nextValues.remove(entry.key);
          changed++;
        }
      }

      if (changed <= 0) {
        return 0;
      }

      final saved = await widget.service.saveEditedProfile(
        _document.copyWith(values: nextValues),
      );
      if (mounted) {
        setState(() {
          _document = saved;
          for (final entry in entries) {
            _sliderDraftByName.remove(entry.key);
          }
        });
      }
      return changed;
    } finally {
      if (mounted) {
        setState(() {
          _menuBusy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<void> _openCompareScreen() async {
    if (_menuBusy) return;
    setState(() {
      _menuBusy = true;
      _busyLabel = '비교 화면 준비 중';
    });
    try {
      final ssh = Provider.of<SSHService>(context, listen: false);
      final host = _resolveTargetHost(ssh);
      var mode = CarrotProfileCompareMode.snapshot;
      var baselineLabel = '마지막 로컬 백업';
      Map<String, dynamic>? baseline;

      if (ssh.isConnected && host != null) {
        mode = CarrotProfileCompareMode.live;
        baselineLabel = '현재 기기';
        baseline = await _fetchCurrentParamsInChunks(
          host,
          _document.values.keys.toList()..sort(),
        );
      } else {
        baseline = await _readLatestLocalBackupMap();
      }

      if (baseline == null) {
        if (!mounted) return;
        CustomToast.show(
          context,
          '비교 기준을 찾을 수 없습니다. 기기를 연결하거나 로컬 백업을 먼저 만드세요.',
          isError: true,
        );
        return;
      }

      final result = _profileCompareService.build(
        bundle: _document.bundle,
        baseline: baseline,
        profile: _document.values,
        mode: mode,
        baselineLabel: baselineLabel,
      );
      if (!mounted) return;
      final outcome =
          await Navigator.of(context).push<CarrotProfileCompareActionResult>(
        MaterialPageRoute<CarrotProfileCompareActionResult>(
          builder: (_) => CarrotProfileCompareScreen(
            profileName: _document.header.name,
            result: result,
            onApplyToCurrentDevice: mode == CarrotProfileCompareMode.live
                ? () => _applyCompareProfileToCurrentDevice(result.entries)
                : null,
            onApplyToProfile: () =>
                _applyCompareBaselineToProfile(baseline!, result.entries),
          ),
        ),
      );
      if (!mounted || outcome == null) return;
      if (outcome.changedCount <= 0) {
        CustomToast.show(context, '바뀐 항목이 없습니다.');
        return;
      }
      final targetLabel =
          outcome.target == CarrotProfileCompareApplyTarget.device
              ? '현재 기기'
              : '프로필';
      CustomToast.show(
        context,
        '$targetLabel에 ${outcome.changedCount}개 항목 적용 완료',
      );
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '프로필 비교 실패: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _menuBusy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<void> _applyProfile() async {
    if (_menuBusy) return;
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, '기기 연결 후 적용하세요.', isError: true);
      return;
    }
    final host = _resolveTargetHost(ssh);
    if (host == null) {
      CustomToast.show(context, '대상 IP를 확인할 수 없습니다.', isError: true);
      return;
    }
    final confirmed = await _confirmApplyDialog(
      title: '프로필 적용',
      message: '현재 프로필 값을 기기에 적용할까요?',
    );
    if (!mounted || !confirmed) return;

    setState(() {
      _menuBusy = true;
      _busyLabel = '현재 기기에 프로필 적용 중';
    });
    var success = 0;
    var failed = 0;
    try {
      for (final entry in _document.values.entries) {
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
          _menuBusy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<String?> _promptProfileName({
    required String title,
    required String initialValue,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final submitted = await showDialog<String>(
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
    if (submitted == null) return null;
    final trimmed = submitted.trim();
    if (trimmed.isEmpty) {
      if (mounted) {
        CustomToast.show(context, '프로필 이름을 입력하세요.', isError: true);
      }
      return null;
    }
    return trimmed;
  }

  Future<void> _renameProfile() async {
    final nextName = await _promptProfileName(
      title: '프로필 이름 변경',
      initialValue: _document.header.name,
    );
    if (!mounted || nextName == null) return;
    setState(() {
      _menuBusy = true;
      _busyLabel = '프로필 이름 변경 중';
    });
    try {
      await widget.service.renameProfile(_document.header.id, nextName);
      final updated = await widget.service.readProfile(_document.header.id);
      if (!mounted || updated == null) return;
      setState(() => _document = updated);
      CustomToast.show(context, '프로필 이름 변경 완료');
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '이름 변경 실패: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _menuBusy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<void> _duplicateProfile() async {
    final nextName = await _promptProfileName(
      title: '프로필 복제',
      initialValue: '${_document.header.name} 복사본',
    );
    if (!mounted || nextName == null) return;
    setState(() {
      _menuBusy = true;
      _busyLabel = '프로필 복제 중';
    });
    try {
      await widget.service
          .duplicateProfile(_document.header.id, newName: nextName);
      if (!mounted) return;
      CustomToast.show(context, '프로필 복제 완료');
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '프로필 복제 실패: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _menuBusy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<void> _deleteProfile() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('프로필 삭제'),
        content: Text('프로필 "${_document.header.name}"을 삭제합니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _menuBusy = true;
      _busyLabel = '프로필 삭제 중';
    });
    try {
      await widget.service.deleteProfile(_document.header.id);
      if (!mounted) return;
      CustomToast.show(context, '프로필 삭제 완료');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '프로필 삭제 실패: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _menuBusy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<void> _handleMenuAction(_ProfileMenuAction action) async {
    switch (action) {
      case _ProfileMenuAction.close:
        Navigator.of(context).pop();
        break;
      case _ProfileMenuAction.rename:
        await _renameProfile();
        break;
      case _ProfileMenuAction.duplicate:
        await _duplicateProfile();
        break;
      case _ProfileMenuAction.compare:
        await _openCompareScreen();
        break;
      case _ProfileMenuAction.apply:
        await _applyProfile();
        break;
      case _ProfileMenuAction.delete:
        await _deleteProfile();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final horizontalPadding = window.isCompact
        ? 12.0
        : tokens.screenPadding.clamp(12.0, 24.0).toDouble();
    final searchTopPadding = window.isCompact ? 10.0 : 12.0;
    final searchBottomPadding = window.isCompact ? 6.0 : 8.0;
    final searchHeight = window.isCompact ? 38.0 : 40.0;
    final listItemGap = window.isCompact ? 8.0 : 10.0;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final searchTextSize = switch (window.windowClass) {
      UiWindowClass.compact => 13.0,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 14.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final searchIconSize = switch (window.windowClass) {
      UiWindowClass.compact => 16.0,
      UiWindowClass.medium => 16.0,
      UiWindowClass.expanded => 17.0,
      UiWindowClass.large => 18.0,
      UiWindowClass.extraLarge => 18.0,
    };
    final searchIconConstraint = switch (window.windowClass) {
      UiWindowClass.compact => 34.0,
      UiWindowClass.medium => 34.0,
      UiWindowClass.expanded => 36.0,
      UiWindowClass.large => 38.0,
      UiWindowClass.extraLarge => 38.0,
    };
    final searchSuffixWidth = switch (window.windowClass) {
      UiWindowClass.compact => 88.0,
      UiWindowClass.medium => 88.0,
      UiWindowClass.expanded => 96.0,
      UiWindowClass.large => 104.0,
      UiWindowClass.extraLarge => 104.0,
    };
    final groups = _orderedGroups()
        .where((group) => _filteredItemsForGroup(group).isNotEmpty)
        .toList();
    final listBottomPadding = 92.0 + bottomInset;

    return Scaffold(
      appBar: AppBar(
        title: Text(_document.header.name),
        actions: [
          if (_menuBusy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IgnorePointer(
            ignoring: _menuBusy,
            child: PopupMenuButton<_ProfileMenuAction>(
              onSelected: (action) => unawaited(_handleMenuAction(action)),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _ProfileMenuAction.close,
                  child: Text('닫기'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: _ProfileMenuAction.rename,
                  child: Text('이름 변경'),
                ),
                PopupMenuItem(
                  value: _ProfileMenuAction.duplicate,
                  child: Text('복제'),
                ),
                PopupMenuItem(
                  value: _ProfileMenuAction.compare,
                  child: Text('비교'),
                ),
                PopupMenuItem(
                  value: _ProfileMenuAction.apply,
                  child: Text('적용'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: _ProfileMenuAction.delete,
                  child: Text('삭제'),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  searchTopPadding,
                  horizontalPadding,
                  searchBottomPadding,
                ),
                child: SizedBox(
                  height: searchHeight,
                  child: TextField(
                    controller: _searchController,
                    style: TextStyle(fontSize: searchTextSize),
                    decoration: InputDecoration(
                      hintText: '프로필 항목 검색',
                      prefixIcon: Icon(Icons.search, size: searchIconSize),
                      prefixIconConstraints: BoxConstraints(
                        minWidth: searchIconConstraint,
                        minHeight: searchIconConstraint,
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : SizedBox(
                              width: searchSuffixWidth,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '검색 결과에서 이동',
                                    onPressed: _showSearchResultPicker,
                                    icon: Icon(Icons.my_location,
                                        size: searchIconSize),
                                  ),
                                  IconButton(
                                    onPressed: () => _searchController.clear(),
                                    icon:
                                        Icon(Icons.close, size: searchIconSize),
                                  ),
                                ],
                              ),
                            ),
                      filled: true,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
              if (groups.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    0,
                    horizontalPadding,
                    searchBottomPadding,
                  ),
                  child: CarrotCurrentGroupBanner(
                    label: '현재 그룹',
                    value: _visibleGroup ?? groups.first,
                    onExpandAll: _expandAllGroups,
                    onCollapseAll: _collapseAllGroups,
                    onJumpToCurrentGroup: _jumpToVisibleGroup,
                  ),
                ),
              Expanded(
                child: groups.isEmpty
                    ? Center(
                        child: Text(
                          '조건에 맞는 프로필 항목이 없습니다.',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : Container(
                        key: _listViewportKey,
                        child: ListView(
                          controller: _scrollController,
                          padding: EdgeInsets.fromLTRB(
                            horizontalPadding,
                            4,
                            horizontalPadding,
                            listBottomPadding,
                          ),
                          children: [
                            for (final group in groups) ...[
                              Builder(
                                builder: (context) {
                                  final items = _filteredItemsForGroup(group);
                                  final isCollapsed = _query.isEmpty &&
                                      _collapsedGroups.contains(group);
                                  return Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(2, 8, 2, 8),
                                    child: CarrotGroupSectionHeader(
                                      key: _groupHeaderKeyFor(group),
                                      title: group,
                                      count: items.length,
                                      isCollapsed: isCollapsed,
                                      onTap: () => _toggleGroup(group),
                                    ),
                                  );
                                },
                              ),
                              if (!(_query.isEmpty &&
                                  _collapsedGroups.contains(group)))
                                ..._filteredItemsForGroup(group).map((item) {
                                  final effectiveValue = _effectiveValue(item);
                                  final sliderValue = _sliderValueFor(item);
                                  final step = item.isBooleanLike
                                      ? null
                                      : _stepFor(item);
                                  return Padding(
                                    padding:
                                        EdgeInsets.only(bottom: listItemGap),
                                    child: KeyedSubtree(
                                      key: _rowKeyFor(item.name),
                                      child: CarrotSettingRowCard(
                                        item: item,
                                        value: effectiveValue,
                                        isSaving: false,
                                        isHighlighted:
                                            _highlightedItemName == item.name,
                                        quickStep: step,
                                        onValueCommitted: item.isBooleanLike
                                            ? null
                                            : (next) => unawaited(
                                                _saveValue(item, next)),
                                        onBooleanChanged: item.isBooleanLike
                                            ? (next) => _saveValue(
                                                  item,
                                                  next ? 1 : 0,
                                                )
                                            : null,
                                        onTap: () => _openEditor(item),
                                        onDecrement: null,
                                        onIncrement: null,
                                        onQuickInput: item.isBooleanLike
                                            ? null
                                            : () => _showQuickValueInput(item),
                                        onStepTap: item.isBooleanLike
                                            ? null
                                            : () => _cycleStep(item),
                                        sliderValue: sliderValue,
                                        sliderMin: item.min?.toDouble(),
                                        sliderMax: item.max?.toDouble(),
                                        sliderDivisions: step == null
                                            ? null
                                            : _sliderDivisions(item, step),
                                        onSliderChanged: null,
                                        onSliderChangeEnd: null,
                                      ),
                                    ),
                                  );
                                }),
                            ],
                          ],
                        ),
                      ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: IgnorePointer(
                child: CarrotFloatingStateCard(
                  icon: _statusIcon,
                  title: _statusModeText,
                  subtitle: _statusDetailText,
                  compact: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
