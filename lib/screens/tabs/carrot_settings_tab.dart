import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/carrot_settings_models.dart';
import '../../services/carrot_server_settings_service.dart';
import '../../services/ssh_service.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/design_components.dart';

class CarrotSettingsTab extends StatefulWidget {
  const CarrotSettingsTab({super.key});

  @override
  State<CarrotSettingsTab> createState() => _CarrotSettingsTabState();
}

class _CarrotSettingsTabState extends State<CarrotSettingsTab>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final CarrotServerSettingsService _service = CarrotServerSettingsService();

  CarrotSettingsBundle? _bundle;
  String? _currentCar;
  bool _isLoading = false;
  bool _isRefreshingCar = false;
  String? _error;
  String _query = '';
  final TextEditingController _groupSearchController = TextEditingController();
  String? _activeHost;
  int _loadEpoch = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _groupSearchController.addListener(_onGroupSearchChanged);
  }

  @override
  void dispose() {
    _groupSearchController.removeListener(_onGroupSearchChanged);
    _groupSearchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onGroupSearchChanged() {
    final next = _groupSearchController.text.trim();
    if (next == _query) return;
    setState(() => _query = next);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _activeHost != null) {
      unawaited(_refreshAll(silent: true));
    }
  }

  void _scheduleLoadForHost(String? host) {
    if (host == null || host.isEmpty) return;
    if (_activeHost == host && (_bundle != null || _isLoading)) return;
    _activeHost = host;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeHost != host) return;
      unawaited(_refreshAll(initial: true));
    });
  }

  Future<void> _refreshAll({bool initial = false, bool silent = false}) async {
    final host = _activeHost;
    if (host == null || host.isEmpty) return;
    final epoch = ++_loadEpoch;
    if (!silent) {
      setState(() {
        _isLoading = true;
        if (initial) _error = null;
      });
    }
    try {
      final bundle = await _service.fetchSettings(host);
      final values =
          await _service.fetchParamsBulk(host, const ['CarSelected3']);
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _bundle = bundle;
        _currentCar = values['CarSelected3']?.toString();
        _error = null;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      if (!silent) {
        setState(() {
          _error = e.toString();
        });
      }
    } finally {
      if (mounted && epoch == _loadEpoch && !silent) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _refreshCurrentCar() async {
    final host = _activeHost;
    if (host == null || host.isEmpty) return;
    setState(() => _isRefreshingCar = true);
    try {
      final values =
          await _service.fetchParamsBulk(host, const ['CarSelected3']);
      if (!mounted) return;
      setState(() {
        _currentCar = values['CarSelected3']?.toString();
      });
    } catch (e) {
      if (mounted) {
        CustomToast.show(context, '차량 정보 갱신 실패: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isRefreshingCar = false);
    }
  }

  List<CarrotSettingsGroupMeta> _filteredGroups() {
    final bundle = _bundle;
    if (bundle == null) return const [];
    final query = _query.toLowerCase();
    final groups = bundle.groups;
    if (query.isEmpty) return groups;

    bool itemMatches(CarrotSettingItemMeta item) {
      final pool = [
        item.name,
        item.title,
        item.descr,
        item.etitle,
        item.edescr,
        item.ctitle,
        item.cdescr,
      ].whereType<String>().join(' ').toLowerCase();
      return pool.contains(query);
    }

    return groups.where((g) {
      final groupMatch = [
        g.group,
        g.egroup,
        g.cgroup,
      ].whereType<String>().join(' ').toLowerCase().contains(query);
      if (groupMatch) return true;
      final items =
          bundle.itemsByGroup[g.group] ?? const <CarrotSettingItemMeta>[];
      return items.any(itemMatches);
    }).toList();
  }

  Future<void> _openCarSelector() async {
    final host = _activeHost;
    if (host == null || host.isEmpty) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _CarSelectorScreen(
          host: host,
          currentCar: _currentCar,
          service: _service,
        ),
      ),
    );
    if (changed == true) {
      await _refreshCurrentCar();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final ssh = context.watch<SSHService>();
    final host = ssh.connectedIp ?? ssh.targetIp;
    _scheduleLoadForHost(host);

    if (host == null || host.isEmpty) {
      return _buildNoHostState();
    }

    return RefreshIndicator(
      onRefresh: () => _refreshAll(),
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          24 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          _buildCarCard(),
          const SizedBox(height: 12),
          if (_isLoading && _bundle == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null && _bundle == null)
            _buildErrorCard(_error!)
          else ...[
            _buildGroupsCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildNoHostState() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DesignCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.settings_suggest_outlined),
                  SizedBox(width: 8),
                  Text(
                    '기기 연결 필요',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'carrot_server(7000) 연결이 필요합니다.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => CustomToast.show(context, '먼저 기기에 연결하세요.'),
                icon: const Icon(Icons.link),
                label: const Text('연결 후 사용'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCarCard() {
    final carLabel = (_currentCar == null || _currentCar!.trim().isEmpty)
        ? '차량 선택'
        : _currentCar!;
    final disabled = _bundle == null || _isLoading;
    final borderColor = Theme.of(context).colorScheme.outline.withOpacity(0.45);
    final textColor = Theme.of(context).colorScheme.onSurface;

    return Material(
      color: disabled
          ? Theme.of(context).colorScheme.surfaceContainerHighest
          : Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: disabled ? null : _openCarSelector,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              const Icon(Icons.directions_car_filled_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  carLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: textColor,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              const SizedBox(width: 8),
              if (_isRefreshingCar)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.expand_more,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCard(String message) {
    return DesignCard(
      color: Theme.of(context).colorScheme.errorContainer.withOpacity(0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              const Text('설정 불러오기 실패'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: _isLoading ? null : () => _refreshAll(),
            child: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupsCard() {
    final bundle = _bundle;
    if (bundle == null) return const SizedBox.shrink();
    final groups = _filteredGroups();
    return DesignCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '주행 설정',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _query.isEmpty
                          ? '${groups.length}개 그룹'
                          : '검색 중: "$_query" · ${groups.length}개',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 150,
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _groupSearchController,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '설정 검색',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      prefixIcon: const Icon(Icons.search, size: 16),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '검색 초기화',
                              onPressed: _groupSearchController.clear,
                              icon: const Icon(Icons.close, size: 16),
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  '검색 결과가 없습니다.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: groups.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final g = groups[index];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    child: Text(
                      '${g.count}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  title: Text(
                    g.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: g.subtitle == null
                      ? null
                      : Text(
                          g.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _CarrotSettingsGroupScreen(
                          host: _activeHost!,
                          group: g,
                          bundle: bundle,
                          service: _service,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
        ],
      ),
    );
  }
}

class _CarrotSettingsGroupScreen extends StatefulWidget {
  final String host;
  final CarrotSettingsGroupMeta group;
  final CarrotSettingsBundle bundle;
  final CarrotServerSettingsService service;

  const _CarrotSettingsGroupScreen({
    required this.host,
    required this.group,
    required this.bundle,
    required this.service,
  });

  @override
  State<_CarrotSettingsGroupScreen> createState() =>
      _CarrotSettingsGroupScreenState();
}

class _CarrotSettingsGroupScreenState
    extends State<_CarrotSettingsGroupScreen> {
  final TextEditingController _searchController = TextEditingController();
  Map<String, dynamic> _values = {};
  bool _loading = false;
  String? _error;
  String _query = '';
  final Set<String> _savingNames = <String>{};
  final Map<String, int> _stepByName = <String, int>{};
  final Map<String, double> _sliderDraftByName = <String, double>{};

  List<CarrotSettingItemMeta> get _items =>
      widget.bundle.itemsByGroup[widget.group.group] ??
      const <CarrotSettingItemMeta>[];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    unawaited(_loadValues());
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final q = _searchController.text.trim();
    if (q == _query) return;
    setState(() => _query = q);
  }

  Future<void> _loadValues() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final names = _items.map((e) => e.name).toList();
      final values = await widget.service.fetchParamsBulk(widget.host, names);
      if (!mounted) return;
      setState(() {
        _values = values;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<CarrotSettingItemMeta> _filteredItems() {
    if (_query.isEmpty) return _items;
    final q = _query.toLowerCase();
    return _items.where((item) {
      final hay = [
        item.name,
        item.title,
        item.descr,
        item.etitle,
        item.edescr,
        item.ctitle,
        item.cdescr,
      ].whereType<String>().join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  dynamic _effectiveValue(CarrotSettingItemMeta item) {
    return _values.containsKey(item.name)
        ? _values[item.name]
        : item.defaultValue;
  }

  Future<void> _setValue(CarrotSettingItemMeta item, dynamic value) async {
    if (_savingNames.contains(item.name)) return;
    setState(() => _savingNames.add(item.name));
    try {
      final saved = await widget.service
          .setParam(widget.host, name: item.name, value: value);
      if (!mounted) return;
      setState(() {
        _values[item.name] = saved;
      });
    } catch (e) {
      if (mounted) {
        CustomToast.show(context, '저장 실패 (${item.name}): $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _savingNames.remove(item.name));
    }
  }

  int _quickStep(CarrotSettingItemMeta item) {
    final unit = item.unit ?? 1;
    return unit <= 0 ? 1 : unit;
  }

  List<int> _unitCycleValues() {
    final cleaned = widget.bundle.unitCycle.where((e) => e > 0).toSet().toList()
      ..sort();
    if (cleaned.isEmpty) return const [1, 2, 5, 10, 50, 100];
    return cleaned;
  }

  int _defaultStepFor(CarrotSettingItemMeta item) {
    final cycle = _unitCycleValues();
    final preferred = _quickStep(item);
    if (cycle.contains(preferred)) return preferred;
    for (final c in cycle) {
      if (c >= preferred) return c;
    }
    return cycle.last;
  }

  int _stepFor(CarrotSettingItemMeta item) {
    return _stepByName[item.name] ?? _defaultStepFor(item);
  }

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
    if (item.isIntegerRange) {
      return next.round();
    }
    return next;
  }

  Future<void> _adjustValueByStep(
    CarrotSettingItemMeta item,
    int deltaSign, {
    int? stepOverride,
  }) async {
    if (item.isBooleanLike || _savingNames.contains(item.name)) return;
    final cur = _asNumValue(_effectiveValue(item)) ??
        _asNumValue(item.defaultValue) ??
        item.min ??
        0;
    final step = (stepOverride ?? _stepFor(item)) * deltaSign;
    final next = _normalizeNumericValue(item, cur + step);
    await _setValue(item, next);
  }

  double _quantizeSliderValue(
    CarrotSettingItemMeta item,
    double value, {
    int? stepOverride,
  }) {
    if (item.min == null || item.max == null) return value;
    final min = item.min!.toDouble();
    final max = item.max!.toDouble();
    final clamped = value.clamp(min, max).toDouble();
    final step = (stepOverride ?? _stepFor(item)).abs();
    if (step <= 0) return clamped;
    final ticks = ((clamped - min) / step).round();
    final snapped = min + (ticks * step);
    return snapped.clamp(min, max).toDouble();
  }

  int? _sliderDivisions(CarrotSettingItemMeta item, int step) {
    if (item.min == null || item.max == null || step <= 0) return null;
    final range = (item.max!.toDouble() - item.min!.toDouble()).abs();
    if (range <= 0) return null;
    final divisions = (range / step).round();
    if (divisions <= 0) return 1;
    return divisions > 1000 ? 1000 : divisions;
  }

  double? _sliderValueFor(CarrotSettingItemMeta item, dynamic currentValue) {
    if (!item.supportsSlider || item.min == null || item.max == null) {
      return null;
    }
    final raw = _sliderDraftByName[item.name] ?? _asNumValue(currentValue);
    if (raw == null) return null;
    return _quantizeSliderValue(item, raw.toDouble());
  }

  void _onSliderChanged(
    CarrotSettingItemMeta item,
    double value, {
    int? stepOverride,
  }) {
    if (_savingNames.contains(item.name)) return;
    final snapped =
        _quantizeSliderValue(item, value, stepOverride: stepOverride);
    setState(() => _sliderDraftByName[item.name] = snapped);
  }

  Future<void> _onSliderChangeEnd(
    CarrotSettingItemMeta item,
    double value, {
    int? stepOverride,
  }) async {
    if (_savingNames.contains(item.name)) return;
    setState(() => _sliderDraftByName.remove(item.name));
    final snapped =
        _quantizeSliderValue(item, value, stepOverride: stepOverride);
    await _setValue(item, _normalizeNumericValue(item, snapped));
  }

  Future<void> _showQuickValueInput(CarrotSettingItemMeta item) async {
    if (_savingNames.contains(item.name)) return;
    final cur = _effectiveValue(item);
    final controller = TextEditingController(text: _displaySettingValue(cur));
    final submitted = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.displayTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          decoration: const InputDecoration(
            labelText: '값 입력',
            border: OutlineInputBorder(),
            isDense: true,
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
            child: const Text('적용'),
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
    await _setValue(item, _normalizeNumericValue(item, parsed));
  }

  Future<void> _openEditor(CarrotSettingItemMeta item) async {
    final current = _effectiveValue(item);
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _SettingEditSheet(
        item: item,
        currentValue: current,
        unitCycle: widget.bundle.unitCycle,
        onCommit: (value) => _setValue(item, value),
      ),
    );
    if (changed == true && mounted) {
      CustomToast.show(context, '${item.displayTitle} 저장됨');
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredItems();
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.displayName),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _loading ? null : _loadValues,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '항목 검색',
                  prefixIcon: const Icon(Icons.search, size: 16),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () => _searchController.clear(),
                          icon: const Icon(Icons.close, size: 16),
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
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Material(
                color: Theme.of(context)
                    .colorScheme
                    .errorContainer
                    .withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.error_outline,
                      color: Theme.of(context).colorScheme.error),
                  title: const Text('값 불러오기 실패'),
                  subtitle: Text(_error!,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadValues,
              child: _loading && _values.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(12, 4, 12, 20 + bottomInset),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final effectiveValue = _effectiveValue(item);
                        final sliderValue =
                            _sliderValueFor(item, effectiveValue);
                        final value = sliderValue ?? effectiveValue;
                        final isSaving = _savingNames.contains(item.name);
                        final step = item.isBooleanLike ? null : _stepFor(item);
                        return _SettingRowCard(
                          item: item,
                          value: value,
                          isSaving: isSaving,
                          quickStep: step,
                          onBooleanChanged: item.isBooleanLike
                              ? (next) => _setValue(item, next ? 1 : 0)
                              : null,
                          onTap: null,
                          onDecrement: item.isBooleanLike
                              ? null
                              : () => _adjustValueByStep(item, -1,
                                  stepOverride: step),
                          onIncrement: item.isBooleanLike
                              ? null
                              : () => _adjustValueByStep(item, 1,
                                  stepOverride: step),
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
                          onSliderChanged:
                              item.isBooleanLike || sliderValue == null
                                  ? null
                                  : (v) => _onSliderChanged(
                                        item,
                                        v,
                                        stepOverride: step,
                                      ),
                          onSliderChangeEnd:
                              item.isBooleanLike || sliderValue == null
                                  ? null
                                  : (v) => unawaited(
                                        _onSliderChangeEnd(
                                          item,
                                          v,
                                          stepOverride: step,
                                        ),
                                      ),
                          onResetDefault: () =>
                              _setValue(item, item.defaultValue),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingRowCard extends StatelessWidget {
  final CarrotSettingItemMeta item;
  final dynamic value;
  final bool isSaving;
  final int? quickStep;
  final ValueChanged<bool>? onBooleanChanged;
  final VoidCallback? onTap;
  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;
  final VoidCallback? onQuickInput;
  final VoidCallback? onStepTap;
  final double? sliderValue;
  final double? sliderMin;
  final double? sliderMax;
  final int? sliderDivisions;
  final ValueChanged<double>? onSliderChanged;
  final ValueChanged<double>? onSliderChangeEnd;
  final VoidCallback onResetDefault;

  const _SettingRowCard({
    required this.item,
    required this.value,
    required this.isSaving,
    required this.quickStep,
    required this.onBooleanChanged,
    required this.onTap,
    required this.onDecrement,
    required this.onIncrement,
    required this.onQuickInput,
    required this.onStepTap,
    required this.sliderValue,
    required this.sliderMin,
    required this.sliderMax,
    required this.sliderDivisions,
    required this.onSliderChanged,
    required this.onSliderChangeEnd,
    required this.onResetDefault,
  });

  @override
  Widget build(BuildContext context) {
    final description = item.displayDescription?.replaceAll('\n', ' ').trim();
    final rangeText = (item.min != null && item.max != null)
        ? '범위 ${_fmtNum(item.min)} ~ ${_fmtNum(item.max)}'
        : null;
    final subtitleParts = <String>[];
    if (description != null && description.isNotEmpty) {
      subtitleParts.add(description);
    }
    if (rangeText != null) subtitleParts.add(rangeText);

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onLongPress: onResetDefault,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.displayTitle,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (isSaving)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.name,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (subtitleParts.isNotEmpty)
                      Text(
                        subtitleParts.join(' · '),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 8),
                    if (item.isBooleanLike)
                      Text(
                        _displaySettingValue(value),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (item.isBooleanLike)
                Switch(
                  value: _asBoolLike(value),
                  onChanged: isSaving ? null : onBooleanChanged,
                )
              else
                SizedBox(
                  width: 172,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _ValuePill(
                              text: _displaySettingValue(value),
                              onTap: isSaving ? null : onQuickInput,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _TinyInfoPill(
                            text: '단위 ${quickStep ?? 1}',
                            onTap: isSaving ? null : onStepTap,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (sliderValue != null &&
                          sliderMin != null &&
                          sliderMax != null)
                        Row(
                          children: [
                            _InlineActionButton(
                              icon: Icons.remove,
                              onTap: isSaving ? null : onDecrement,
                            ),
                            const SizedBox(width: 2),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 7,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 11,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 18,
                                  ),
                                ),
                                child: SizedBox(
                                  height: 42,
                                  child: Slider(
                                    value: sliderValue!,
                                    min: sliderMin!,
                                    max: sliderMax!,
                                    divisions: sliderDivisions,
                                    onChanged:
                                        isSaving ? null : onSliderChanged,
                                    onChangeEnd:
                                        isSaving ? null : onSliderChangeEnd,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 2),
                            _InlineActionButton(
                              icon: Icons.add,
                              onTap: isSaving ? null : onIncrement,
                            ),
                          ],
                        )
                      else
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            _InlineActionButton(
                              icon: Icons.remove,
                              onTap: isSaving ? null : onDecrement,
                            ),
                            const SizedBox(width: 6),
                            _InlineActionButton(
                              icon: Icons.add,
                              onTap: isSaving ? null : onIncrement,
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _InlineActionButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: SizedBox(
          width: 26,
          height: 26,
          child: Icon(icon, size: 14),
        ),
      ),
    );
  }
}

class _ValuePill extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;

  const _ValuePill({
    required this.text,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

class _TinyInfoPill extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;

  const _TinyInfoPill({
    required this.text,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
    if (onTap == null) {
      return Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: child,
      );
    }
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: child,
      ),
    );
  }
}

class _SettingEditSheet extends StatefulWidget {
  final CarrotSettingItemMeta item;
  final dynamic currentValue;
  final List<int> unitCycle;
  final Future<void> Function(dynamic value) onCommit;

  const _SettingEditSheet({
    required this.item,
    required this.currentValue,
    required this.unitCycle,
    required this.onCommit,
  });

  @override
  State<_SettingEditSheet> createState() => _SettingEditSheetState();
}

class _SettingEditSheetState extends State<_SettingEditSheet> {
  late double _value;
  late TextEditingController _inputController;
  late int _step;
  bool _saving = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    final initial = _toDouble(widget.currentValue) ??
        _toDouble(widget.item.defaultValue) ??
        (widget.item.min?.toDouble() ?? 0);
    _value = _clamp(initial);
    _step = _initialStep();
    _inputController = TextEditingController(text: _displayNumber(_value));
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  int _initialStep() {
    final preferred = widget.item.unit ?? 1;
    if (widget.unitCycle.contains(preferred)) return preferred;
    return widget.unitCycle.isEmpty ? preferred : widget.unitCycle.first;
  }

  double _clamp(double v) {
    final min = widget.item.min?.toDouble();
    final max = widget.item.max?.toDouble();
    if (min != null && v < min) v = min;
    if (max != null && v > max) v = max;
    return v;
  }

  dynamic _materialize(double value) {
    if (widget.item.isIntegerRange) return value.round();
    return value;
  }

  void _setLocal(double next) {
    final clamped = _clamp(next);
    setState(() {
      _value = clamped;
      _inputController.text = _displayNumber(clamped);
    });
  }

  Future<void> _commitValue(double next) async {
    if (_saving) return;
    final clamped = _clamp(next);
    setState(() {
      _saving = true;
    });
    try {
      await widget.onCommit(_materialize(clamped));
      if (!mounted) return;
      setState(() {
        _value = clamped;
        _inputController.text = _displayNumber(clamped);
        _changed = true;
      });
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final sliderDivisions = _sliderDivisions(item);
    final canSlider =
        item.supportsSlider && item.min != null && item.max != null;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).viewPadding.bottom +
            16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.displayTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(_changed),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if ((item.displayDescription ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                item.displayDescription!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetaChip(label: '현재', value: _displayNumber(_value)),
              if (item.defaultValue != null)
                _MetaChip(label: '기본값', value: item.defaultValue.toString()),
              if (item.min != null && item.max != null)
                _MetaChip(
                  label: '범위',
                  value: '${_fmtNum(item.min)} ~ ${_fmtNum(item.max)}',
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _inputController,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            decoration: InputDecoration(
              labelText: '값 입력',
              suffixIcon: IconButton(
                tooltip: '입력값 적용',
                icon: const Icon(Icons.check),
                onPressed: _saving
                    ? null
                    : () {
                        final v = double.tryParse(_inputController.text.trim());
                        if (v == null) {
                          CustomToast.show(context, '숫자를 입력하세요.',
                              isError: true);
                          return;
                        }
                        unawaited(_commitValue(v));
                      },
              ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) {
              if (_saving) return;
              final v = double.tryParse(_inputController.text.trim());
              if (v != null) {
                unawaited(_commitValue(v));
              }
            },
          ),
          const SizedBox(height: 12),
          Text(
            '단위(step)',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: widget.unitCycle
                .map((u) => ChoiceChip(
                      label: Text('$u'),
                      selected: _step == u,
                      onSelected: (selected) {
                        if (!selected) return;
                        setState(() => _step = u);
                      },
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving
                      ? null
                      : () => unawaited(_commitValue(_value - _step)),
                  icon: const Icon(Icons.remove),
                  label: Text('- $_step'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving
                      ? null
                      : () => unawaited(_commitValue(_value + _step)),
                  icon: const Icon(Icons.add),
                  label: Text('+ $_step'),
                ),
              ),
            ],
          ),
          if (canSlider) ...[
            const SizedBox(height: 10),
            Slider(
              value: _value.clamp(item.min!.toDouble(), item.max!.toDouble()),
              min: item.min!.toDouble(),
              max: item.max!.toDouble(),
              divisions: sliderDivisions,
              label: _displayNumber(_value),
              onChanged: _saving
                  ? null
                  : (v) {
                      _setLocal(v);
                    },
              onChangeEnd: _saving ? null : (v) => unawaited(_commitValue(v)),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: _saving || widget.item.defaultValue == null
                      ? null
                      : () {
                          final dv = _toDouble(widget.item.defaultValue);
                          if (dv != null) {
                            unawaited(_commitValue(dv));
                          }
                        },
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('기본값 복원'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed:
                    _saving ? null : () => Navigator.of(context).pop(_changed),
                child: const Text('닫기'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int? _sliderDivisions(CarrotSettingItemMeta item) {
    if (!item.isIntegerRange || item.min == null || item.max == null) {
      return null;
    }
    final min = item.min!.toInt();
    final max = item.max!.toInt();
    final range = max - min;
    if (range <= 0) return null;
    if (range <= 200) return range;
    return 200;
  }

  String _displayNumber(double v) {
    if (widget.item.isIntegerRange) return v.round().toString();
    return v.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final String value;

  const _MetaChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CarSelectorScreen extends StatefulWidget {
  final String host;
  final String? currentCar;
  final CarrotServerSettingsService service;

  const _CarSelectorScreen({
    required this.host,
    required this.currentCar,
    required this.service,
  });

  @override
  State<_CarSelectorScreen> createState() => _CarSelectorScreenState();
}

class _CarSelectorScreenState extends State<_CarSelectorScreen> {
  final TextEditingController _searchController = TextEditingController();
  CarrotCarsBundle? _cars;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    unawaited(_loadCars());
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final q = _searchController.text.trim();
    if (q == _query) return;
    setState(() => _query = q);
  }

  Future<void> _loadCars() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cars = await widget.service.fetchCars(widget.host);
      if (!mounted) return;
      setState(() => _cars = cars);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<CarrotCarOption> _flattenedOptions(CarrotCarsBundle bundle) {
    final out = <CarrotCarOption>[];
    final makers = bundle.makers.keys.toList()..sort();
    for (final maker in makers) {
      final list = bundle.makers[maker] ?? const <String>[];
      for (final full in list) {
        out.add(CarrotCarOption.fromFullLine(maker, full));
      }
    }
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return out;
    return out.where((e) => e.searchableText.contains(q)).toList();
  }

  Future<void> _selectCar(CarrotCarOption option) async {
    if (_saving) return;
    if (widget.currentCar != null &&
        widget.currentCar!.trim().isNotEmpty &&
        widget.currentCar!.trim() == option.fullLine.trim()) {
      Navigator.of(context).pop(false);
      return;
    }

    setState(() => _saving = true);
    try {
      await widget.service
          .setParam(widget.host, name: 'CarSelected3', value: option.fullLine);
      if (!mounted) return;
      CustomToast.show(context, '차량 선택이 완료되었습니다: ${option.modelOnly}');
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        CustomToast.show(context, '차량 설정 실패: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cars = _cars;
    final options =
        cars == null ? const <CarrotCarOption>[] : _flattenedOptions(cars);

    return Scaffold(
      appBar: AppBar(
        title: const Text('차량 선택'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _loading || _saving ? null : _loadCars,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '제작사/모델 검색',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () => _searchController.clear(),
                        icon: const Icon(Icons.close),
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          if (widget.currentCar != null && widget.currentCar!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '현재: ${widget.currentCar}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          if (_loading && cars == null)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null && cars == null)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(height: 8),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: _loadCars,
                        child: const Text('다시 시도'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                itemCount: options.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final option = options[index];
                  final selected = widget.currentCar != null &&
                      widget.currentCar!.trim() == option.fullLine.trim();
                  return Material(
                    color: selected
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(14),
                    child: ListTile(
                      dense: true,
                      enabled: !_saving,
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: selected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.secondaryContainer,
                        child: Text(
                          option.maker.isNotEmpty ? option.maker[0] : '?',
                          style: TextStyle(
                            color: selected
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(context)
                                    .colorScheme
                                    .onSecondaryContainer,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      title: Text(option.modelOnly),
                      subtitle: Text(option.maker),
                      trailing: selected
                          ? const Icon(Icons.check_circle)
                          : const Icon(Icons.chevron_right),
                      onTap: () => _selectCar(option),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

bool _asBoolLike(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final v = value.trim().toLowerCase();
    return v == '1' || v == 'true' || v == 'yes' || v == 'on';
  }
  return false;
}

String _displaySettingValue(dynamic value) {
  if (value == null) return '-';
  if (value is num) return _fmtNum(value);
  final s = value.toString().trim();
  return s.isEmpty ? '-' : s;
}

String _fmtNum(num? value) {
  if (value == null) return '-';
  final d = value.toDouble();
  if (d == d.roundToDouble()) return d.round().toString();
  return d.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
}
