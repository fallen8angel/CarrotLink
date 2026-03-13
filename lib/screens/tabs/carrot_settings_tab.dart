// ignore_for_file: unused_element, unused_element_parameter

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/carrot_settings_models.dart';
import '../../services/carrot_server_settings_service.dart';
import '../../services/ssh_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/custom_toast.dart';
import '../../widgets/design_components.dart';
import 'widgets/carrot_setting_editor_widgets.dart';

class _CarrotSettingFavorite {
  final String group;
  final String name;
  final String title;
  final int savedAtMs;

  const _CarrotSettingFavorite({
    required this.group,
    required this.name,
    required this.title,
    required this.savedAtMs,
  });

  String get key => '$group::$name';

  Map<String, dynamic> toJson() => {
        'group': group,
        'name': name,
        'title': title,
        'savedAtMs': savedAtMs,
      };

  factory _CarrotSettingFavorite.fromJson(Map<String, dynamic> json) {
    return _CarrotSettingFavorite(
      group: (json['group'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      savedAtMs: (json['savedAtMs'] is num)
          ? (json['savedAtMs'] as num).toInt()
          : DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class _CarrotSettingSearchHit {
  final CarrotSettingsGroupMeta group;
  final CarrotSettingItemMeta item;

  const _CarrotSettingSearchHit({
    required this.group,
    required this.item,
  });
}

class CarrotSettingsTab extends StatefulWidget {
  final String? initialFocusItemName;

  const CarrotSettingsTab({
    super.key,
    this.initialFocusItemName,
  });

  @override
  State<CarrotSettingsTab> createState() => _CarrotSettingsTabState();
}

class _CarrotSettingsTabState extends State<CarrotSettingsTab>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  static const String _favoritesPrefKey = 'carrot_settings_favorites_v1';
  final CarrotServerSettingsService _service = CarrotServerSettingsService();

  CarrotSettingsBundle? _bundle;
  String? _currentCar;
  bool _isLoading = false;
  bool _isRefreshingCar = false;
  String? _error;
  String _query = '';
  final TextEditingController _groupSearchController = TextEditingController();
  final FocusNode _groupSearchFocusNode = FocusNode();
  final List<_CarrotSettingFavorite> _favorites = <_CarrotSettingFavorite>[];
  String? _activeHost;
  int _loadEpoch = 0;
  bool _initialFocusHandled = false;
  double _lastKeyboardInset = 0.0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _groupSearchController.addListener(_onGroupSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastKeyboardInset = _currentKeyboardInset();
    });
    unawaited(_loadFavorites());
  }

  @override
  void dispose() {
    _groupSearchController.removeListener(_onGroupSearchChanged);
    _groupSearchController.dispose();
    _groupSearchFocusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onGroupSearchChanged() {
    final next = _groupSearchController.text.trim();
    if (next == _query) return;
    setState(() => _query = next);
  }

  Future<void> _loadFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_favoritesPrefKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final next = decoded
          .whereType<Map>()
          .map((e) =>
              _CarrotSettingFavorite.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.group.isNotEmpty && e.name.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _favorites
          ..clear()
          ..addAll(next);
      });
    } catch (_) {}
  }

  double _currentKeyboardInset() {
    final view = View.maybeOf(context);
    if (view != null) {
      return view.viewInsets.bottom / view.devicePixelRatio;
    }
    return MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0.0;
  }

  void _dismissSearchKeyboard() {
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    _groupSearchFocusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  bool _consumeBackForSearchKeyboard() {
    final keyboardVisible = _currentKeyboardInset() > 0.0;
    final searchFocused = _groupSearchFocusNode.hasFocus;
    if (!keyboardVisible && !searchFocused) {
      return false;
    }
    _dismissSearchKeyboard();
    return true;
  }

  Future<void> _persistFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_favorites.map((e) => e.toJson()).toList());
    await prefs.setString(_favoritesPrefKey, raw);
  }

  List<_CarrotSettingFavorite> _sortedFavorites() {
    final out = List<_CarrotSettingFavorite>.from(_favorites);
    out.sort((a, b) {
      final byTime = b.savedAtMs.compareTo(a.savedAtMs);
      if (byTime != 0) return byTime;
      final byGroup = a.group.compareTo(b.group);
      if (byGroup != 0) return byGroup;
      return a.title.compareTo(b.title);
    });
    return out;
  }

  Future<bool> _toggleFavorite(CarrotSettingItemMeta item) async {
    final key = '${item.group}::${item.name}';
    final existingIndex = _favorites.indexWhere((e) => e.key == key);
    late final bool nowFavorite;
    if (existingIndex >= 0) {
      nowFavorite = false;
      setState(() => _favorites.removeAt(existingIndex));
    } else {
      nowFavorite = true;
      setState(() {
        _favorites.add(
          _CarrotSettingFavorite(
            group: item.group,
            name: item.name,
            title: item.displayTitle,
            savedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      });
    }
    await _persistFavorites();
    return nowFavorite;
  }

  Future<void> _openFavoritesMenu() async {
    if (_favorites.isEmpty) {
      CustomToast.show(context, '즐겨찾기 항목이 없습니다.');
      return;
    }
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final sheetHorizontalPadding = window.isCompact
        ? 12.0
        : tokens.screenPadding.clamp(12.0, 22.0).toDouble();
    final sheetItemPadding = switch (window.windowClass) {
      UiWindowClass.compact => 6.0,
      UiWindowClass.medium => 7.0,
      UiWindowClass.expanded => 8.0,
      UiWindowClass.large => 10.0,
      UiWindowClass.extraLarge => 10.0,
    };
    final list = _sortedFavorites();
    final selected = await showModalBottomSheet<_CarrotSettingFavorite>(
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
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final fav = list[index];
            return ListTile(
              contentPadding:
                  EdgeInsets.symmetric(horizontal: sheetItemPadding),
              leading: const Icon(Icons.bookmark, color: Colors.amber),
              title: Text(
                fav.title.isEmpty ? fav.name : fav.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${fav.group} · ${fav.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pop(fav),
            );
          },
        );
      },
    );
    if (!mounted || selected == null) return;
    await _openFavoriteTarget(selected);
  }

  Future<void> _openFavoriteTarget(_CarrotSettingFavorite fav) async {
    final bundle = _bundle;
    if (bundle == null) return;

    CarrotSettingsGroupMeta? group;
    for (final g in bundle.groups) {
      if (g.group == fav.group) {
        group = g;
        break;
      }
    }
    final targetGroup = group;
    if (targetGroup == null) {
      CustomToast.show(context, '해당 그룹을 찾을 수 없습니다.', isError: true);
      return;
    }
    await _openGroupScreen(targetGroup, focusItemName: fav.name);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _activeHost != null) {
      unawaited(_refreshAll(silent: true));
    }
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final nextInset = _currentKeyboardInset();
    final keyboardClosed = _lastKeyboardInset > 0.0 && nextInset <= 0.0;
    _lastKeyboardInset = nextInset;
    if (keyboardClosed && _groupSearchFocusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _dismissSearchKeyboard();
      });
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
      _scheduleInitialFocusIfNeeded();
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

  bool _itemMatchesQuery(CarrotSettingItemMeta item, String query) {
    if (query.isEmpty) return true;
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

  List<_CarrotSettingSearchHit> _filteredSettingHits() {
    final bundle = _bundle;
    if (bundle == null) return const [];
    final query = _query.toLowerCase();
    if (query.isEmpty) return const [];

    final out = <_CarrotSettingSearchHit>[];
    for (final group in bundle.groups) {
      final items =
          bundle.itemsByGroup[group.group] ?? const <CarrotSettingItemMeta>[];
      for (final item in items) {
        if (_itemMatchesQuery(item, query)) {
          out.add(_CarrotSettingSearchHit(group: group, item: item));
        }
      }
    }
    return out;
  }

  void _scheduleInitialFocusIfNeeded() {
    if (_initialFocusHandled) return;
    final targetItemName = widget.initialFocusItemName?.trim() ?? '';
    if (targetItemName.isEmpty) {
      _initialFocusHandled = true;
      return;
    }
    final bundle = _bundle;
    if (bundle == null) return;

    CarrotSettingsGroupMeta? targetGroup;
    for (final group in bundle.groups) {
      final items =
          bundle.itemsByGroup[group.group] ?? const <CarrotSettingItemMeta>[];
      if (items.any((item) => item.name == targetItemName)) {
        targetGroup = group;
        break;
      }
    }

    _initialFocusHandled = true;
    if (targetGroup == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        CustomToast.show(
          context,
          '요청한 설정 항목($targetItemName)을 찾지 못했습니다.',
          isError: true,
        );
      });
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _openGroupScreen(
          targetGroup!,
          focusItemName: targetItemName,
        ),
      );
    });
  }

  Future<void> _openGroupScreen(
    CarrotSettingsGroupMeta group, {
    String? focusItemName,
  }) async {
    final bundle = _bundle;
    final host = _activeHost;
    if (bundle == null || host == null || host.isEmpty) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _CarrotSettingsGroupScreen(
          host: host,
          group: group,
          bundle: bundle,
          service: _service,
          initialFocusItemName: focusItemName,
          initialFavoriteNames: _favorites
              .where((e) => e.group == group.group)
              .map((e) => e.name)
              .toSet(),
          onToggleFavorite: _toggleFavorite,
        ),
      ),
    );
    if (changed == true && mounted) {
      setState(() {});
    }
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
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final horizontalPadding = window.isCompact
        ? 16.0
        : tokens.screenPadding.clamp(16.0, 28.0).toDouble();
    final topPadding = window.isCompact ? 16.0 : 18.0;
    final itemGap = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 14.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final ssh = context.watch<SSHService>();
    final host = ssh.connectedIp ?? ssh.targetIp;
    _scheduleLoadForHost(host);

    final body = host == null || host.isEmpty
        ? _buildNoHostState()
        : RefreshIndicator(
            onRefresh: () => _refreshAll(),
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                topPadding,
                horizontalPadding,
                24 + MediaQuery.of(context).padding.bottom,
              ),
              children: [
                _buildCarCard(),
                SizedBox(height: itemGap),
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

    return WillPopScope(
      onWillPop: () async => !_consumeBackForSearchKeyboard(),
      child: body,
    );
  }

  Widget _buildNoHostState() {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final horizontalPadding = window.isCompact
        ? 16.0
        : tokens.screenPadding.clamp(16.0, 28.0).toDouble();
    final verticalPadding = window.isCompact ? 16.0 : 18.0;

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      children: [
        DesignCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.settings_suggest_outlined),
                  SizedBox(width: tokens.itemGap + 2),
                  const Text(
                    '기기 연결 필요',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              SizedBox(height: tokens.itemGap + 2),
              Text(
                'carrot_server(7000) 연결이 필요합니다.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              SizedBox(height: tokens.sectionGap),
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
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final carLabel = (_currentCar == null || _currentCar!.trim().isEmpty)
        ? '차량 선택'
        : _currentCar!;
    final disabled = _bundle == null || _isLoading;
    final borderColor =
        Theme.of(context).colorScheme.outline.withValues(alpha: 0.45);
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
          padding: EdgeInsets.symmetric(
            horizontal: window.isCompact ? 12 : 14,
            vertical: window.isCompact ? 12 : 14,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              const Icon(Icons.directions_car_filled_outlined, size: 18),
              SizedBox(width: tokens.itemGap + 2),
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
              SizedBox(width: tokens.itemGap + 2),
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
    final tokens = UiLayoutTokens.of(context);
    return DesignCard(
      color:
          Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error),
              SizedBox(width: tokens.itemGap + 2),
              const Text('설정 불러오기 실패'),
            ],
          ),
          SizedBox(height: tokens.itemGap + 2),
          Text(
            message,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          SizedBox(height: tokens.sectionGap),
          FilledButton.tonal(
            onPressed: _isLoading ? null : () => _refreshAll(),
            child: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupsCard() {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final searchFieldWidth = switch (window.windowClass) {
      UiWindowClass.compact => 170.0,
      UiWindowClass.medium => 210.0,
      _ => 240.0,
    };
    final searchFieldHeight = window.isCompact ? 38.0 : 40.0;
    final helperFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      _ => 13.0,
    };
    final searchTextFontSize = window.isCompact ? 13.0 : 14.0;
    final groupCountFontSize = window.isCompact ? 11.0 : 12.0;

    final bundle = _bundle;
    if (bundle == null) return const SizedBox.shrink();
    final groups = bundle.groups;
    final hits = _filteredSettingHits();
    final isSearching = _query.isNotEmpty;
    return DesignCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune, color: Theme.of(context).colorScheme.primary),
              SizedBox(width: tokens.itemGap + 4),
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
                    SizedBox(height: tokens.itemGap / 2),
                    Text(
                      !isSearching
                          ? '${groups.length}개 그룹'
                          : '검색 중: "$_query" · ${hits.length}개 항목',
                      style: TextStyle(
                        fontSize: helperFontSize,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: searchFieldWidth,
                child: SizedBox(
                  height: searchFieldHeight,
                  child: TextField(
                    controller: _groupSearchController,
                    focusNode: _groupSearchFocusNode,
                    textInputAction: TextInputAction.search,
                    onTapOutside: (_) => _dismissSearchKeyboard(),
                    onEditingComplete: _dismissSearchKeyboard,
                    onSubmitted: (_) => _dismissSearchKeyboard(),
                    style: TextStyle(fontSize: searchTextFontSize),
                    decoration: InputDecoration(
                      hintText: '설정 검색',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: tokens.itemGap + 4,
                        vertical: 8,
                      ),
                      prefixIcon: const Icon(Icons.search, size: 16),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 32,
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
              SizedBox(width: tokens.itemGap / 2),
              IconButton(
                tooltip: '즐겨찾기 (${_favorites.length})',
                onPressed:
                    (_bundle == null || _isLoading) ? null : _openFavoritesMenu,
                icon: Icon(
                  Icons.bookmarks_outlined,
                  color: _favorites.isEmpty ? null : Colors.amber,
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.itemGap + 2),
          if (isSearching && hits.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: tokens.sectionGap + 8),
              child: Center(
                child: Text(
                  '검색 결과가 없습니다.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else if (isSearching)
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: hits.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final hit = hits[index];
                return ListTile(
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: tokens.itemGap / 2),
                  leading: const Icon(Icons.tune, size: 18),
                  title: Text(
                    hit.item.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${hit.group.displayName} · ${hit.item.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openGroupScreen(
                    hit.group,
                    focusItemName: hit.item.name,
                  ),
                );
              },
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
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: tokens.itemGap / 2),
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    child: Text(
                      '${g.count}',
                      style: TextStyle(
                        fontSize: groupCountFontSize,
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
                  onTap: () async {
                    await _openGroupScreen(g);
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
  final String? initialFocusItemName;
  final Set<String> initialFavoriteNames;
  final Future<bool> Function(CarrotSettingItemMeta item) onToggleFavorite;

  const _CarrotSettingsGroupScreen({
    required this.host,
    required this.group,
    required this.bundle,
    required this.service,
    this.initialFocusItemName,
    this.initialFavoriteNames = const <String>{},
    required this.onToggleFavorite,
  });

  @override
  State<_CarrotSettingsGroupScreen> createState() =>
      _CarrotSettingsGroupScreenState();
}

class _CarrotSettingsGroupScreenState
    extends State<_CarrotSettingsGroupScreen> {
  static const Duration _highlightDuration = Duration(seconds: 2);
  static const double _estimatedRowExtent = 150.0;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _rowKeysByName = <String, GlobalKey>{};
  Map<String, dynamic> _values = {};
  bool _loading = false;
  String? _error;
  String _query = '';
  String? _highlightedItemName;
  String? _pendingFocusItemName;
  late Set<String> _favoriteNames;
  final Set<String> _favoriteBusyNames = <String>{};
  final Map<String, int> _stepByName = <String, int>{};
  final Map<String, double> _sliderDraftByName = <String, double>{};
  final Map<String, dynamic> _pendingPersistValuesByName = <String, dynamic>{};
  final Set<String> _syncingNames = <String>{};
  Timer? _highlightClearTimer;

  List<CarrotSettingItemMeta> get _items =>
      widget.bundle.itemsByGroup[widget.group.group] ??
      const <CarrotSettingItemMeta>[];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _favoriteNames = Set<String>.from(widget.initialFavoriteNames);
    _pendingFocusItemName = widget.initialFocusItemName;
    unawaited(_loadValues());
  }

  @override
  void dispose() {
    _highlightClearTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.dispose();
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
      _requestPendingFocus();
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

  GlobalKey _rowKeyFor(String name) {
    return _rowKeysByName.putIfAbsent(name, () => GlobalKey());
  }

  void _requestPendingFocus() {
    if (_pendingFocusItemName == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_focusItemByName(_pendingFocusItemName!));
    });
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
    final exists = _items.any((e) => e.name == itemName);
    if (!exists) {
      _pendingFocusItemName = null;
      return;
    }

    // If current filter hides the target, clear filter first.
    if (_query.isNotEmpty && !_filteredItems().any((e) => e.name == itemName)) {
      _searchController.clear();
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    final items = _filteredItems();
    final index = items.indexWhere((e) => e.name == itemName);
    if (index < 0) {
      _pendingFocusItemName = null;
      return;
    }

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
    final key = _rowKeyFor(itemName);
    final ctx = key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.2,
      );
    }
    if (!mounted) return;
    _pendingFocusItemName = null;
    _setHighlighted(itemName);
  }

  Future<void> _showSearchResultPicker() async {
    final items = _filteredItems();
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

  bool _isFavoriteItem(CarrotSettingItemMeta item) {
    return _favoriteNames.contains(item.name);
  }

  Future<void> _toggleFavoriteItem(CarrotSettingItemMeta item) async {
    if (_favoriteBusyNames.contains(item.name)) return;
    setState(() => _favoriteBusyNames.add(item.name));
    try {
      final nowFavorite = await widget.onToggleFavorite(item);
      if (!mounted) return;
      setState(() {
        if (nowFavorite) {
          _favoriteNames.add(item.name);
        } else {
          _favoriteNames.remove(item.name);
        }
      });
      CustomToast.show(
        context,
        nowFavorite ? '즐겨찾기에 등록되었습니다.' : '즐겨찾기에서 제거되었습니다.',
      );
    } finally {
      if (mounted) setState(() => _favoriteBusyNames.remove(item.name));
    }
  }

  dynamic _effectiveValue(CarrotSettingItemMeta item) {
    return _values.containsKey(item.name)
        ? _values[item.name]
        : item.defaultValue;
  }

  bool _sameSettingValue(dynamic a, dynamic b) {
    if (a is num && b is num) {
      return (a.toDouble() - b.toDouble()).abs() < 0.0001;
    }
    return a?.toString() == b?.toString();
  }

  Future<void> _setValue(CarrotSettingItemMeta item, dynamic value) async {
    if (!mounted) return;
    final current = _values[item.name];
    if (_sameSettingValue(current, value) &&
        !_pendingPersistValuesByName.containsKey(item.name)) {
      return;
    }
    setState(() {
      _values[item.name] = value;
      _sliderDraftByName.remove(item.name);
    });
    _pendingPersistValuesByName[item.name] = value;
    if (_syncingNames.add(item.name)) {
      unawaited(_flushQueuedValue(item));
    }
  }

  Future<void> _flushQueuedValue(CarrotSettingItemMeta item) async {
    final name = item.name;
    while (mounted) {
      if (!_pendingPersistValuesByName.containsKey(name)) break;
      final target = _pendingPersistValuesByName.remove(name);
      try {
        final saved = await widget.service
            .setParam(widget.host, name: name, value: target);
        if (!mounted) return;
        if (!_pendingPersistValuesByName.containsKey(name) &&
            !_sameSettingValue(_values[name], saved)) {
          setState(() {
            _values[name] = saved;
          });
        }
      } catch (e) {
        if (mounted) {
          CustomToast.show(context, '저장 실패 ($name): $e', isError: true);
        }
      }
    }
    _syncingNames.remove(name);
    if (mounted &&
        _pendingPersistValuesByName.containsKey(name) &&
        _syncingNames.add(name)) {
      unawaited(_flushQueuedValue(item));
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
    final min = item.min!.toDouble();
    final max = item.max!.toDouble();
    return raw.toDouble().clamp(min, max);
  }

  Future<void> _showQuickValueInput(CarrotSettingItemMeta item) async {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final dialogHorizontalInset = window.isCompact
        ? 18.0
        : tokens.screenPadding.clamp(18.0, 32.0).toDouble();
    final dialogVerticalInset = switch (window.windowClass) {
      UiWindowClass.compact => 22.0,
      UiWindowClass.medium => 24.0,
      UiWindowClass.expanded => 26.0,
      UiWindowClass.large => 28.0,
      UiWindowClass.extraLarge => 28.0,
    };
    final dialogContentPadding = switch (window.windowClass) {
      UiWindowClass.compact => 16.0,
      UiWindowClass.medium => 18.0,
      UiWindowClass.expanded => 20.0,
      UiWindowClass.large => 20.0,
      UiWindowClass.extraLarge => 22.0,
    };
    final dialogFieldFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 13.0,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 14.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final cur = _effectiveValue(item);
    final controller = TextEditingController(text: _displaySettingValue(cur));
    final submitted = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: EdgeInsets.symmetric(
          horizontal: dialogHorizontalInset,
          vertical: dialogVerticalInset,
        ),
        contentPadding: EdgeInsets.fromLTRB(
          dialogContentPadding,
          12,
          dialogContentPadding,
          dialogContentPadding,
        ),
        title: Text(item.displayTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          style: TextStyle(fontSize: dialogFieldFontSize),
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
    if (item.isBooleanLike) {
      final next = !_asBoolLike(_effectiveValue(item));
      await _setValue(item, next ? 1 : 0);
      return;
    }
    await _showQuickValueInput(item);
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredItems();
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
                  hintText: '항목 검색',
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
                                icon: Icon(Icons.close, size: searchIconSize),
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
          if (_error != null)
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: 8,
              ),
              child: Material(
                color: Theme.of(context)
                    .colorScheme
                    .errorContainer
                    .withValues(alpha: 0.5),
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
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        4,
                        horizontalPadding,
                        20 + bottomInset,
                      ),
                      itemCount: items.length,
                      separatorBuilder: (_, __) =>
                          SizedBox(height: listItemGap),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final effectiveValue = _effectiveValue(item);
                        final sliderValue =
                            _sliderValueFor(item, effectiveValue);
                        final value = effectiveValue;
                        final step = item.isBooleanLike ? null : _stepFor(item);
                        return KeyedSubtree(
                          key: _rowKeyFor(item.name),
                          child: _SettingRowCard(
                            item: item,
                            value: value,
                            isSaving: false,
                            isHighlighted: _highlightedItemName == item.name,
                            isFavorite: _isFavoriteItem(item),
                            quickStep: step,
                            onValueCommitted: item.isBooleanLike
                                ? null
                                : (next) => unawaited(_setValue(item, next)),
                            onBooleanChanged: item.isBooleanLike
                                ? (next) => _setValue(item, next ? 1 : 0)
                                : null,
                            onTap: () => _openEditor(item),
                            onFavoriteLongPress: () =>
                                unawaited(_toggleFavoriteItem(item)),
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
  final bool isHighlighted;
  final bool isFavorite;
  final int? quickStep;
  final ValueChanged<bool>? onBooleanChanged;
  final VoidCallback? onTap;
  final VoidCallback? onFavoriteLongPress;
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
  final ValueChanged<dynamic>? onValueCommitted;

  const _SettingRowCard({
    required this.item,
    required this.value,
    required this.isSaving,
    required this.isHighlighted,
    required this.isFavorite,
    required this.quickStep,
    required this.onBooleanChanged,
    required this.onTap,
    required this.onFavoriteLongPress,
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
    this.onValueCommitted,
  });

  @override
  Widget build(BuildContext context) {
    return CarrotSettingRowCard(
      item: item,
      value: value,
      isSaving: isSaving,
      isHighlighted: isHighlighted,
      isFavorite: isFavorite,
      quickStep: quickStep,
      onBooleanChanged: onBooleanChanged,
      onTap: onTap,
      onFavoriteLongPress: onFavoriteLongPress,
      onDecrement: onDecrement,
      onIncrement: onIncrement,
      onQuickInput: onQuickInput,
      onStepTap: onStepTap,
      sliderValue: sliderValue,
      sliderMin: sliderMin,
      sliderMax: sliderMax,
      sliderDivisions: sliderDivisions,
      onSliderChanged: onSliderChanged,
      onSliderChangeEnd: onSliderChangeEnd,
      onValueCommitted: onValueCommitted,
    );
  }
}

class _InlineActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _InlineActionButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final buttonSize = switch (window.windowClass) {
      UiWindowClass.compact => 26.0,
      UiWindowClass.medium => 28.0,
      UiWindowClass.expanded => 30.0,
      UiWindowClass.large => 32.0,
      UiWindowClass.extraLarge => 32.0,
    };
    final iconSize = switch (window.windowClass) {
      UiWindowClass.compact => 14.0,
      UiWindowClass.medium => 14.0,
      UiWindowClass.expanded => 15.0,
      UiWindowClass.large => 16.0,
      UiWindowClass.extraLarge => 16.0,
    };
    final hitSize = switch (window.windowClass) {
      UiWindowClass.compact => buttonSize + 10,
      UiWindowClass.medium => buttonSize + 10,
      UiWindowClass.expanded => buttonSize + 10,
      UiWindowClass.large => buttonSize + 12,
      UiWindowClass.extraLarge => buttonSize + 12,
    };
    return SizedBox(
      width: hitSize,
      height: hitSize,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Center(
            child: Container(
              width: buttonSize,
              height: buttonSize,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: iconSize),
            ),
          ),
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
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final item = widget.item;
    final sliderDivisions = _sliderDivisions(item);
    final canSlider =
        item.supportsSlider && item.min != null && item.max != null;
    final sheetHorizontalPadding = window.isCompact
        ? 16.0
        : tokens.screenPadding.clamp(16.0, 28.0).toDouble();
    final sectionGap = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 14.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final compactTextSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.5,
      UiWindowClass.expanded => 13.0,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };
    final verticalInset = switch (window.windowClass) {
      UiWindowClass.compact => 16.0,
      UiWindowClass.medium => 16.0,
      UiWindowClass.expanded => 18.0,
      UiWindowClass.large => 18.0,
      UiWindowClass.extraLarge => 18.0,
    };
    final compactGap = switch (window.windowClass) {
      UiWindowClass.compact => 6.0,
      UiWindowClass.medium => 6.0,
      UiWindowClass.expanded => 7.0,
      UiWindowClass.large => 8.0,
      UiWindowClass.extraLarge => 8.0,
    };

    return Padding(
      padding: EdgeInsets.only(
        left: sheetHorizontalPadding,
        right: sheetHorizontalPadding,
        top: verticalInset,
        bottom: MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).viewPadding.bottom +
            verticalInset,
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
              padding: EdgeInsets.only(bottom: compactGap + 2),
              child: Text(
                item.displayDescription!,
                style: TextStyle(
                  fontSize: compactTextSize,
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
          SizedBox(height: sectionGap),
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
          SizedBox(height: sectionGap),
          Text(
            '단위(step)',
            style: TextStyle(
              fontSize: compactTextSize,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: compactGap),
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
          SizedBox(height: sectionGap),
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
              SizedBox(width: compactGap + 2),
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
          SizedBox(height: sectionGap - compactGap),
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
              SizedBox(width: compactGap + 2),
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
    final window = UiWindowInfo.of(context);
    final chipHorizontalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 10.0,
      UiWindowClass.medium => 10.0,
      UiWindowClass.expanded => 11.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final chipVerticalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 6.0,
      UiWindowClass.medium => 6.0,
      UiWindowClass.expanded => 7.0,
      UiWindowClass.large => 7.0,
      UiWindowClass.extraLarge => 7.0,
    };
    final chipFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 13.0,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: chipHorizontalPadding,
        vertical: chipVerticalPadding,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(fontSize: chipFontSize, fontWeight: FontWeight.w600),
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
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final searchHorizontalPadding = window.isCompact
        ? 16.0
        : tokens.screenPadding.clamp(16.0, 28.0).toDouble();
    final carListHorizontalPadding = window.isCompact
        ? 12.0
        : tokens.screenPadding.clamp(12.0, 24.0).toDouble();
    final carListGap = switch (window.windowClass) {
      UiWindowClass.compact => 6.0,
      UiWindowClass.medium => 7.0,
      UiWindowClass.expanded => 8.0,
      UiWindowClass.large => 8.0,
      UiWindowClass.extraLarge => 8.0,
    };
    final currentCarFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.5,
      UiWindowClass.expanded => 13.0,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };
    final avatarTextSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 13.0,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };

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
            padding: EdgeInsets.fromLTRB(
              searchHorizontalPadding,
              12,
              searchHorizontalPadding,
              8,
            ),
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
              padding: EdgeInsets.fromLTRB(
                searchHorizontalPadding,
                0,
                searchHorizontalPadding,
                8,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '현재: ${widget.currentCar}',
                  style: TextStyle(
                    fontSize: currentCarFontSize,
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
                padding: EdgeInsets.fromLTRB(
                  carListHorizontalPadding,
                  4,
                  carListHorizontalPadding,
                  20,
                ),
                itemCount: options.length,
                separatorBuilder: (_, __) => SizedBox(height: carListGap),
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
                            fontSize: avatarTextSize,
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
