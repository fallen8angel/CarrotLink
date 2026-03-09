import 'package:flutter/material.dart';

import '../../services/carrot_profile_compare_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/custom_toast.dart';
import 'widgets/carrot_setting_group_status_widgets.dart';

enum CarrotProfileCompareApplyTarget { device, profile }

class CarrotProfileCompareActionResult {
  final CarrotProfileCompareApplyTarget target;
  final int changedCount;

  const CarrotProfileCompareActionResult({
    required this.target,
    required this.changedCount,
  });
}

class CarrotProfileCompareScreen extends StatefulWidget {
  final String profileName;
  final CarrotProfileCompareResult result;
  final Future<int> Function()? onApplyToCurrentDevice;
  final Future<int> Function()? onApplyToProfile;

  const CarrotProfileCompareScreen({
    super.key,
    required this.profileName,
    required this.result,
    this.onApplyToCurrentDevice,
    this.onApplyToProfile,
  });

  @override
  State<CarrotProfileCompareScreen> createState() =>
      _CarrotProfileCompareScreenState();
}

class _CarrotProfileCompareScreenState
    extends State<CarrotProfileCompareScreen> {
  static const double _estimatedGroupHeaderExtent = 52.0;
  static const double _estimatedDiffCardExtent = 116.0;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _listViewportKey = GlobalKey();
  final Map<String, GlobalKey> _groupHeaderKeys = <String, GlobalKey>{};
  final Map<String, double> _groupScrollOffsets = <String, double>{};
  final Set<String> _collapsedGroups = <String>{};
  String? _visibleGroup;
  bool _applyBusy = false;
  String? _applyBusyLabel;
  bool _groupSyncScheduled = false;

  Map<String, List<CarrotProfileDiffEntry>> get _grouped {
    final grouped = <String, List<CarrotProfileDiffEntry>>{};
    for (final entry in widget.result.entries) {
      grouped
          .putIfAbsent(entry.group, () => <CarrotProfileDiffEntry>[])
          .add(entry);
    }
    return grouped;
  }

  List<String> get _groups => _grouped.keys.toList();

  @override
  void initState() {
    super.initState();
    _visibleGroup = _groups.isEmpty ? null : _groups.first;
    _scrollController.addListener(_scheduleVisibleGroupSync);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scheduleVisibleGroupSync();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_scheduleVisibleGroupSync);
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _groupHeaderKeyFor(String group) {
    return _groupHeaderKeys.putIfAbsent(group, () => GlobalKey());
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
    final groups = _groups;
    if (groups.isEmpty) return;
    setState(() {
      _collapsedGroups
        ..clear()
        ..addAll(groups);
    });
    _groupScrollOffsets.clear();
    _scheduleVisibleGroupSync();
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
    final groups = _groups;
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
    const cardGap = 10.0;
    var offset = 0.0;
    for (final group in _groups) {
      if (group == targetGroup) break;
      offset += _estimatedGroupHeaderExtent;
      if (!_collapsedGroups.contains(group)) {
        final count = _grouped[group]?.length ?? 0;
        offset += count * (_estimatedDiffCardExtent + cardGap);
      }
    }
    return offset;
  }

  Future<bool> _confirmApplyAction({
    required CarrotProfileCompareApplyTarget target,
  }) async {
    final title =
        target == CarrotProfileCompareApplyTarget.device ? '현재기기 적용' : '프로필 적용';
    final message = target == CarrotProfileCompareApplyTarget.device
        ? '비교 결과의 프로필 값을 현재 기기에 적용할까요?'
        : '비교 기준값을 현재 프로필에 덮어쓸까요?';
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

  String get _statusDetail {
    if (_applyBusyLabel != null && _applyBusyLabel!.trim().isNotEmpty) {
      return _applyBusyLabel!;
    }
    if (widget.result.mode == CarrotProfileCompareMode.live) {
      return '현재 기기 기준';
    }
    return '마지막 로컬 백업 기준';
  }

  Future<void> _runApplyAction({
    required CarrotProfileCompareApplyTarget target,
    required Future<int> Function() action,
    required String busyLabel,
  }) async {
    if (_applyBusy) return;
    final confirmed = await _confirmApplyAction(target: target);
    if (!mounted || !confirmed) return;
    var didPop = false;
    setState(() {
      _applyBusy = true;
      _applyBusyLabel = busyLabel;
    });
    try {
      final changedCount = await action();
      if (!mounted) return;
      Navigator.of(context).pop(
        CarrotProfileCompareActionResult(
          target: target,
          changedCount: changedCount,
        ),
      );
      didPop = true;
      return;
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '적용 실패: $e', isError: true);
    } finally {
      if (mounted && !didPop) {
        setState(() {
          _applyBusy = false;
          _applyBusyLabel = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _grouped;
    final groups = grouped.keys.toList();
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final horizontalPadding = window.isCompact
        ? 12.0
        : tokens.screenPadding.clamp(12.0, 24.0).toDouble();
    final cardGap = window.isCompact ? 8.0 : 10.0;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final listBottomPadding = 104.0 + bottomInset;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.profileName} 비교'),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (groups.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    12,
                    horizontalPadding,
                    8,
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
                child: Container(
                  key: _listViewportKey,
                  child: ListView(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      groups.isEmpty ? 12 : 4,
                      horizontalPadding,
                      listBottomPadding,
                    ),
                    children: [
                      if (!widget.result.hasDiffs)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          child: Center(
                            child: Text(
                              '변경된 항목이 없습니다.',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
                      else
                        SizedBox(height: cardGap + 2),
                      for (final group in groups) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
                          child: CarrotGroupSectionHeader(
                            key: _groupHeaderKeyFor(group),
                            title: group,
                            count: grouped[group]!.length,
                            isCollapsed: _collapsedGroups.contains(group),
                            onTap: () => _toggleGroup(group),
                          ),
                        ),
                        if (!_collapsedGroups.contains(group))
                          ...grouped[group]!.map(
                            (entry) => Padding(
                              padding: EdgeInsets.only(bottom: cardGap),
                              child: _CompareEntryCard(
                                entry: entry,
                                baselineLabel: widget.result.baselineLabel,
                              ),
                            ),
                          ),
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
              child: _CompareBottomDock(
                subtitle: _statusDetail,
                busy: _applyBusy,
                canApplyToDevice: widget.onApplyToCurrentDevice != null &&
                    widget.result.hasDiffs,
                canApplyToProfile:
                    widget.onApplyToProfile != null && widget.result.hasDiffs,
                onApplyToDevice: widget.onApplyToCurrentDevice == null
                    ? null
                    : () => _runApplyAction(
                          target: CarrotProfileCompareApplyTarget.device,
                          action: widget.onApplyToCurrentDevice!,
                          busyLabel: '현재 기기에 적용 중',
                        ),
                onApplyToProfile: widget.onApplyToProfile == null
                    ? null
                    : () => _runApplyAction(
                          target: CarrotProfileCompareApplyTarget.profile,
                          action: widget.onApplyToProfile!,
                          busyLabel: '현재 값을 프로필에 적용 중',
                        ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompareEntryCard extends StatelessWidget {
  final CarrotProfileDiffEntry entry;
  final String baselineLabel;

  const _CompareEntryCard({
    required this.entry,
    required this.baselineLabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final baselineColor =
        entry.missingBaseline ? scheme.error : const Color(0xFFD7A800);
    final profileColor =
        entry.missingProfile ? scheme.error : const Color(0xFF2FA45A);

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              entry.key,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
              ),
              child: RichText(
                text: TextSpan(
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        height: 1.35,
                      ),
                  children: [
                    TextSpan(
                      text: '$baselineLabel  ',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text: entry.baselineValue,
                      style: TextStyle(
                        color: baselineColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    TextSpan(
                      text: '  >  ',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextSpan(
                      text: '프로필  ',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text: entry.profileValue,
                      style: TextStyle(
                        color: profileColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (entry.missingBaseline || entry.missingProfile) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (entry.missingBaseline)
                    _CompareFlag(
                      text: '$baselineLabel 값 없음',
                      color: scheme.errorContainer,
                      textColor: scheme.onErrorContainer,
                    ),
                  if (entry.missingProfile)
                    _CompareFlag(
                      text: '프로필 값 없음',
                      color: scheme.errorContainer,
                      textColor: scheme.onErrorContainer,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CompareFlag extends StatelessWidget {
  final String text;
  final Color color;
  final Color textColor;

  const _CompareFlag({
    required this.text,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      ),
    );
  }
}

class _CompareBottomDock extends StatelessWidget {
  final String subtitle;
  final bool busy;
  final bool canApplyToDevice;
  final bool canApplyToProfile;
  final VoidCallback? onApplyToDevice;
  final VoidCallback? onApplyToProfile;

  const _CompareBottomDock({
    required this.subtitle,
    required this.busy,
    required this.canApplyToDevice,
    required this.canApplyToProfile,
    required this.onApplyToDevice,
    required this.onApplyToProfile,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.98),
      elevation: 10,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Icon(
              busy ? Icons.sync : Icons.compare_arrows,
              size: 16,
              color: scheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '비교 모드',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: busy || !canApplyToProfile ? null : onApplyToProfile,
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('프로필 적용'),
            ),
            const SizedBox(width: 6),
            FilledButton.tonal(
              onPressed: busy || !canApplyToDevice ? null : onApplyToDevice,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('현재기기 적용'),
            ),
          ],
        ),
      ),
    );
  }
}
