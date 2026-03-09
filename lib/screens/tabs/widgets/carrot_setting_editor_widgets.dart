import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/carrot_settings_models.dart';
import '../../../ui/adaptive/layout_tokens.dart';
import '../../../ui/adaptive/window_class.dart';
import '../../../widgets/custom_toast.dart';

bool carrotAsBoolLike(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final v = value.trim().toLowerCase();
    return v == '1' || v == 'true' || v == 'yes' || v == 'on';
  }
  return false;
}

String carrotDisplaySettingValue(dynamic value) {
  if (value == null) return '-';
  if (value is num) return carrotFmtNum(value);
  final s = value.toString().trim();
  return s.isEmpty ? '-' : s;
}

String carrotFmtNum(num? value) {
  if (value == null) return '-';
  final d = value.toDouble();
  if (d == d.roundToDouble()) return d.round().toString();
  return d.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
}

class CarrotSettingRowCard extends StatefulWidget {
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

  const CarrotSettingRowCard({
    super.key,
    required this.item,
    required this.value,
    required this.isSaving,
    this.isHighlighted = false,
    this.isFavorite = false,
    required this.quickStep,
    required this.onBooleanChanged,
    required this.onTap,
    this.onFavoriteLongPress,
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
  State<CarrotSettingRowCard> createState() => _CarrotSettingRowCardState();
}

class _CarrotSettingRowCardState extends State<CarrotSettingRowCard> {
  static const Duration _tapCommitDelay = Duration(milliseconds: 120);
  static const int _maxDiscreteSliderDivisions = 240;

  Timer? _commitDebounceTimer;
  dynamic _pendingCommitValue;
  double? _interactiveNumericValue;

  @override
  void didUpdateWidget(covariant CarrotSettingRowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.name != widget.item.name) {
      _commitDebounceTimer?.cancel();
      _pendingCommitValue = null;
      _interactiveNumericValue = null;
      return;
    }
    final interactive = _interactiveNumericValue;
    if (interactive == null) return;
    if (_valuesEqual(widget.value, _materializeNumeric(interactive))) {
      _interactiveNumericValue = null;
      _pendingCommitValue = null;
    }
  }

  @override
  void dispose() {
    _flushPendingCommit();
    _commitDebounceTimer?.cancel();
    super.dispose();
  }

  num? _asNumValue(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value.trim());
    return null;
  }

  dynamic _normalizeNumericValue(num raw) {
    var next = raw.toDouble();
    if (widget.item.min != null && next < widget.item.min!.toDouble()) {
      next = widget.item.min!.toDouble();
    }
    if (widget.item.max != null && next > widget.item.max!.toDouble()) {
      next = widget.item.max!.toDouble();
    }
    if (widget.item.isIntegerRange) return next.round();
    return next;
  }

  dynamic _materializeNumeric(double raw) {
    return _normalizeNumericValue(raw);
  }

  double _quantizeSliderValue(double raw) {
    final min = widget.sliderMin;
    final max = widget.sliderMax;
    if (min == null || max == null) return raw;
    final clamped = raw.clamp(min, max).toDouble();
    final step = _effectiveStep.toDouble().abs();
    if (step <= 0) return clamped;
    final ticks = ((clamped - min) / step).round();
    final snapped = min + (ticks * step);
    return snapped.clamp(min, max).toDouble();
  }

  bool _valuesEqual(dynamic a, dynamic b) {
    if (a is num && b is num) {
      return (a.toDouble() - b.toDouble()).abs() < 0.0001;
    }
    return a?.toString() == b?.toString();
  }

  int get _effectiveStep {
    final step = widget.quickStep ?? 1;
    return step <= 0 ? 1 : step;
  }

  dynamic get _displayValue {
    final interactive = _interactiveNumericValue;
    if (interactive == null) return widget.value;
    return _materializeNumeric(interactive);
  }

  double? get _displaySliderValue {
    final interactive = _interactiveNumericValue;
    if (interactive == null) return widget.sliderValue;
    final min = widget.sliderMin;
    final max = widget.sliderMax;
    if (min == null || max == null) return interactive;
    return interactive.clamp(min, max).toDouble();
  }

  double? get _currentNumericValue {
    final interactive = _interactiveNumericValue;
    if (interactive != null) return interactive;
    final numeric = _asNumValue(widget.value);
    if (numeric != null) return numeric.toDouble();
    final fallback = _asNumValue(widget.item.defaultValue);
    if (fallback != null) return fallback.toDouble();
    return widget.item.min?.toDouble();
  }

  void _setInteractiveValue(num next) {
    final normalized = _normalizeNumericValue(next);
    final numeric = _asNumValue(normalized)?.toDouble();
    if (numeric == null) return;
    setState(() {
      _interactiveNumericValue = numeric;
    });
  }

  void _setInteractiveSliderValue(double next) {
    final snapped = _quantizeSliderValue(next);
    _setInteractiveValue(snapped);
  }

  void _scheduleValueCommit(dynamic value) {
    if (widget.onValueCommitted == null) return;
    _pendingCommitValue = value;
    _commitDebounceTimer?.cancel();
    _commitDebounceTimer = Timer(_tapCommitDelay, _flushPendingCommit);
  }

  void _flushPendingCommit() {
    final callback = widget.onValueCommitted;
    final value = _pendingCommitValue;
    if (callback == null || value == null) return;
    _pendingCommitValue = null;
    callback(value);
  }

  void _handleSliderChanged(double value) {
    if (widget.onValueCommitted == null) {
      widget.onSliderChanged?.call(_quantizeSliderValue(value));
      return;
    }
    _setInteractiveSliderValue(value);
  }

  void _handleSliderChangeEnd(double value) {
    if (widget.onValueCommitted == null) {
      widget.onSliderChangeEnd?.call(_quantizeSliderValue(value));
      return;
    }
    final next = _normalizeNumericValue(_quantizeSliderValue(value));
    _setInteractiveValue(_asNumValue(next) ?? value);
    _pendingCommitValue = null;
    _commitDebounceTimer?.cancel();
    widget.onValueCommitted?.call(next);
  }

  void _handleStepAdjust(int deltaSign) {
    if (widget.item.isBooleanLike) return;
    if (widget.onValueCommitted == null) {
      if (deltaSign < 0) {
        widget.onDecrement?.call();
      } else {
        widget.onIncrement?.call();
      }
      return;
    }
    final current = _currentNumericValue ?? 0;
    final next = _normalizeNumericValue(current + (_effectiveStep * deltaSign));
    final numeric = _asNumValue(next) ?? current;
    _setInteractiveValue(numeric);
    _scheduleValueCommit(next);
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final description =
        widget.item.displayDescription?.replaceAll('\n', ' ').trim();
    final rangeText = (widget.item.min != null && widget.item.max != null)
        ? '범위 ${carrotFmtNum(widget.item.min)} ~ ${carrotFmtNum(widget.item.max)}'
        : null;
    final subtitleParts = <String>[];
    if (description != null && description.isNotEmpty) {
      subtitleParts.add(description);
    }
    if (rangeText != null) subtitleParts.add(rangeText);

    final borderColor = widget.isHighlighted
        ? Theme.of(context).colorScheme.primary
        : Colors.transparent;
    final bgColor = widget.isHighlighted
        ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.36)
        : Theme.of(context).colorScheme.surfaceContainer;
    final controlColumnMinWidth = switch (window.windowClass) {
      UiWindowClass.compact => 170.0,
      UiWindowClass.medium => 186.0,
      UiWindowClass.expanded => 210.0,
      UiWindowClass.large => 226.0,
      UiWindowClass.extraLarge => 238.0,
    };
    final controlColumnMaxWidth = switch (window.windowClass) {
      UiWindowClass.compact => 220.0,
      UiWindowClass.medium => 252.0,
      UiWindowClass.expanded => 308.0,
      UiWindowClass.large => 348.0,
      UiWindowClass.extraLarge => 380.0,
    };
    final controlColumnRatio = switch (window.windowClass) {
      UiWindowClass.compact => 0.46,
      UiWindowClass.medium => 0.43,
      UiWindowClass.expanded => 0.39,
      UiWindowClass.large => 0.36,
      UiWindowClass.extraLarge => 0.34,
    };
    final minimumInfoColumnWidth = switch (window.windowClass) {
      UiWindowClass.compact => 132.0,
      UiWindowClass.medium => 156.0,
      UiWindowClass.expanded => 190.0,
      UiWindowClass.large => 220.0,
      UiWindowClass.extraLarge => 248.0,
    };
    final contentGap = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 10.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final cardHorizontalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 13.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final cardVerticalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 10.0,
      UiWindowClass.medium => 10.0,
      UiWindowClass.expanded => 11.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final titleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 14.0,
      UiWindowClass.medium => 14.0,
      UiWindowClass.expanded => 14.5,
      UiWindowClass.large => 15.0,
      UiWindowClass.extraLarge => 15.0,
    };
    final nameFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 11.0,
      UiWindowClass.medium => 11.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 12.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final subtitleFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.0,
      UiWindowClass.medium => 12.0,
      UiWindowClass.expanded => 12.5,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 13.0,
    };
    final valueFontSize = switch (window.windowClass) {
      UiWindowClass.compact => 16.0,
      UiWindowClass.medium => 17.0,
      UiWindowClass.expanded => 17.0,
      UiWindowClass.large => 18.0,
      UiWindowClass.extraLarge => 18.0,
    };
    final displayValue = _displayValue;
    final displaySliderValue = _displaySliderValue;
    final effectiveSliderDivisions = (() {
      final raw = widget.sliderDivisions;
      if (raw == null || raw <= 0) return raw;
      return raw > _maxDiscreteSliderDivisions ? null : raw;
    })();

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: borderColor,
            width: widget.isHighlighted ? 1.4 : 0,
          ),
        ),
        child: Stack(
          children: [
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onLongPress: widget.onFavoriteLongPress,
                onTap: widget.onTap,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    cardHorizontalPadding,
                    cardVerticalPadding,
                    cardHorizontalPadding,
                    cardVerticalPadding,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final preferredControlWidth = (constraints.maxWidth *
                              controlColumnRatio)
                          .clamp(controlColumnMinWidth, controlColumnMaxWidth)
                          .toDouble();
                      final fallbackControlFloor = controlColumnMinWidth * 0.82;
                      final maxAllowedControlWidth = constraints.maxWidth -
                          minimumInfoColumnWidth -
                          contentGap;
                      final adaptiveControlWidth = math.min(
                        preferredControlWidth,
                        math.min(
                          controlColumnMaxWidth,
                          math.max(
                            fallbackControlFloor,
                            maxAllowedControlWidth,
                          ),
                        ),
                      );

                      return Row(
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
                                        widget.item.displayTitle,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: titleFontSize,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.item.name,
                                  style: TextStyle(
                                    fontSize: nameFontSize,
                                    fontFamily: 'monospace',
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                if (subtitleParts.isNotEmpty)
                                  Text(
                                    subtitleParts.join(' · '),
                                    style: TextStyle(
                                      fontSize: subtitleFontSize,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                const SizedBox(height: 8),
                                if (widget.item.isBooleanLike)
                                  Text(
                                    carrotDisplaySettingValue(displayValue),
                                    style: TextStyle(
                                      fontSize: valueFontSize,
                                      fontWeight: FontWeight.w800,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          SizedBox(width: contentGap),
                          if (widget.item.isBooleanLike)
                            Switch(
                              value: carrotAsBoolLike(displayValue),
                              onChanged: widget.onBooleanChanged,
                            )
                          else
                            SizedBox(
                              width: adaptiveControlWidth,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: CarrotValuePill(
                                          text: carrotDisplaySettingValue(
                                            displayValue,
                                          ),
                                          onTap: widget.onQuickInput,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      CarrotTinyInfoPill(
                                        text: '단위 ${widget.quickStep ?? 1}',
                                        onTap: widget.onStepTap,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (displaySliderValue != null &&
                                      widget.sliderMin != null &&
                                      widget.sliderMax != null)
                                    Row(
                                      children: [
                                        CarrotInlineActionButton(
                                          icon: Icons.remove,
                                          onTap: () => _handleStepAdjust(-1),
                                        ),
                                        Expanded(
                                          child: SliderTheme(
                                            data: SliderTheme.of(context)
                                                .copyWith(
                                              trackHeight: 7,
                                              thumbShape:
                                                  const RoundSliderThumbShape(
                                                enabledThumbRadius: 11,
                                              ),
                                              overlayShape:
                                                  const RoundSliderOverlayShape(
                                                overlayRadius: 18,
                                              ),
                                            ),
                                            child: SizedBox(
                                              height: 42,
                                              child: Slider(
                                                value: displaySliderValue,
                                                min: widget.sliderMin!,
                                                max: widget.sliderMax!,
                                                divisions:
                                                    effectiveSliderDivisions,
                                                onChanged: _handleSliderChanged,
                                                onChangeEnd:
                                                    _handleSliderChangeEnd,
                                              ),
                                            ),
                                          ),
                                        ),
                                        CarrotInlineActionButton(
                                          icon: Icons.add,
                                          onTap: () => _handleStepAdjust(1),
                                        ),
                                      ],
                                    )
                                  else
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        CarrotInlineActionButton(
                                          icon: Icons.remove,
                                          onTap: () => _handleStepAdjust(-1),
                                        ),
                                        const SizedBox(width: 6),
                                        CarrotInlineActionButton(
                                          icon: Icons.add,
                                          onTap: () => _handleStepAdjust(1),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            if (!widget.isSaving && widget.isFavorite)
              const Positioned(
                top: 6,
                right: 6,
                child: IgnorePointer(
                  child: Icon(
                    Icons.bookmark,
                    size: 16,
                    color: Colors.amber,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class CarrotInlineActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const CarrotInlineActionButton({
    super.key,
    required this.icon,
    this.onTap,
  });

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

class CarrotValuePill extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;

  const CarrotValuePill({
    super.key,
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

class CarrotTinyInfoPill extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;

  const CarrotTinyInfoPill({
    super.key,
    required this.text,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            text,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}

class CarrotMetaChip extends StatelessWidget {
  final String label;
  final String value;

  const CarrotMetaChip({
    super.key,
    required this.label,
    required this.value,
  });

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

class CarrotSettingEditSheet extends StatefulWidget {
  final CarrotSettingItemMeta item;
  final dynamic currentValue;
  final List<int> unitCycle;
  final Future<void> Function(dynamic value) onCommit;

  const CarrotSettingEditSheet({
    super.key,
    required this.item,
    required this.currentValue,
    required this.unitCycle,
    required this.onCommit,
  });

  @override
  State<CarrotSettingEditSheet> createState() => _CarrotSettingEditSheetState();
}

class _CarrotSettingEditSheetState extends State<CarrotSettingEditSheet> {
  late final TextEditingController _inputController;
  late double _value;
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
    _step = _defaultStep();
    _inputController = TextEditingController(text: _displayNumber(_value));
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  int _defaultStep() {
    final cycle = widget.unitCycle.where((e) => e > 0).toSet().toList()..sort();
    if (cycle.isEmpty) {
      return (widget.item.unit ?? 1) <= 0 ? 1 : widget.item.unit!;
    }
    final preferred = (widget.item.unit ?? 1) <= 0 ? 1 : widget.item.unit!;
    if (cycle.contains(preferred)) return preferred;
    for (final candidate in cycle) {
      if (candidate >= preferred) return candidate;
    }
    return cycle.last;
  }

  double _clamp(double value) {
    final min = widget.item.min?.toDouble();
    final max = widget.item.max?.toDouble();
    if (min != null && value < min) value = min;
    if (max != null && value > max) value = max;
    return value;
  }

  Future<void> _commitValue(double next) async {
    if (_saving) return;
    final normalized = _normalize(next);
    setState(() {
      _saving = true;
      _value = normalized.toDouble();
      _inputController.text = _displayNumber(_value);
    });
    try {
      await widget.onCommit(normalized);
      _changed = true;
      if (!mounted) return;
      Navigator.of(context).pop(_changed);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  dynamic _normalize(double value) {
    final clamped = _clamp(value);
    if (widget.item.isIntegerRange) return clamped.round();
    return clamped;
  }

  int? _sliderDivisions() {
    if (!widget.item.isIntegerRange ||
        widget.item.min == null ||
        widget.item.max == null) {
      return null;
    }
    final min = widget.item.min!.toInt();
    final max = widget.item.max!.toInt();
    final range = max - min;
    if (range <= 0) return null;
    if (_step <= 0) return range;
    final divisions = (range / _step).round();
    if (divisions <= 0) return 1;
    return divisions > 1000 ? 1000 : divisions;
  }

  String _displayNumber(double value) {
    if (widget.item.isIntegerRange) return value.round().toString();
    return value.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final canSlider = widget.item.supportsSlider &&
        widget.item.min != null &&
        widget.item.max != null;
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
                  widget.item.displayTitle,
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
          if ((widget.item.displayDescription ?? '').isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: compactGap + 2),
              child: Text(
                widget.item.displayDescription!,
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
              CarrotMetaChip(label: '현재', value: _displayNumber(_value)),
              if (widget.item.defaultValue != null)
                CarrotMetaChip(
                  label: '기본값',
                  value: widget.item.defaultValue.toString(),
                ),
              if (widget.item.min != null && widget.item.max != null)
                CarrotMetaChip(
                  label: '범위',
                  value:
                      '${carrotFmtNum(widget.item.min)} ~ ${carrotFmtNum(widget.item.max)}',
                ),
            ],
          ),
          SizedBox(height: sectionGap),
          TextField(
            controller: _inputController,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
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
            children:
                (widget.unitCycle.where((e) => e > 0).toSet().toList()..sort())
                    .map(
                      (unit) => ChoiceChip(
                        label: Text('$unit'),
                        selected: _step == unit,
                        onSelected: (selected) {
                          if (!selected) return;
                          setState(() => _step = unit);
                        },
                      ),
                    )
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
              value: _value.clamp(
                widget.item.min!.toDouble(),
                widget.item.max!.toDouble(),
              ),
              min: widget.item.min!.toDouble(),
              max: widget.item.max!.toDouble(),
              divisions: _sliderDivisions(),
              label: _displayNumber(_value),
              onChanged: _saving
                  ? null
                  : (v) {
                      setState(() {
                        _value = v;
                        _inputController.text = _displayNumber(v);
                      });
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
}
