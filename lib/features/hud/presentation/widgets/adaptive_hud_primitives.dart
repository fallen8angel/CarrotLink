import 'package:flutter/material.dart';

import '../models/hud_adaptive_display_model.dart';
import '../models/hud_layout_profile.dart';

const Color _hudAccentGreen = Color(0xFF34C96E);
const Color _hudAccentAmber = Color(0xFFFFC94A);
const Color _hudSurfaceGreen = Color(0xE0145B3C);
const Color _hudSurfaceGreenDeep = Color(0xEC0C3824);
const Color _hudSurfaceGreenSoft = Color(0xD9114A31);
const List<Shadow> hudStrongTextShadows = <Shadow>[
  Shadow(
    color: Color(0xF0000000),
    offset: Offset(0, 1.4),
    blurRadius: 3.6,
  ),
  Shadow(
    color: Color(0xA0000000),
    offset: Offset(0, 0),
    blurRadius: 1.2,
  ),
];

double adaptiveHudBandHeight(HudLayoutProfile profile) => switch (profile.density) {
      HudDensityClass.micro => 30.0,
      HudDensityClass.compact => 34.0,
      HudDensityClass.regular => 38.0,
      HudDensityClass.spacious => 42.0,
    };

class AdaptiveHudMetricTile extends StatelessWidget {
  final String label;
  final String value;
  final HudLayoutProfile profile;
  final Color accent;

  const AdaptiveHudMetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.profile,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final icon = switch (label.trim().toUpperCase()) {
      'CPU' => Icons.thermostat_rounded,
      'MEM' => Icons.memory_rounded,
      'VOLT' => Icons.bolt_rounded,
      _ => Icons.storage_rounded,
    };
    final compactValue = value.replaceAll('°C', '°').replaceAll('.0V', 'V');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _hudSurfaceGreenSoft,
        borderRadius: BorderRadius.circular(profile.borderRadius - 10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: profile.density == HudDensityClass.micro ? 8 : 10,
          vertical: profile.density == HudDensityClass.micro ? 6 : 7,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: profile.chipFontSize + 4,
              color: Colors.white,
            ),
            const SizedBox(width: 6),
            Text(
              compactValue,
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.chipFontSize + 3.2,
                fontWeight: FontWeight.w900,
                height: 1.0,
                shadows: hudStrongTextShadows,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AdaptiveHudTempCard extends StatelessWidget {
  final String label;
  final String value;
  final HudLayoutProfile profile;
  final Color accent;

  const AdaptiveHudTempCard({
    super.key,
    required this.label,
    required this.value,
    required this.profile,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: <Color>[
            _hudSurfaceGreen,
            _hudSurfaceGreenDeep,
          ],
        ),
        borderRadius: BorderRadius.circular(profile.borderRadius - 8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
      ),
      child: Padding(
        padding: EdgeInsets.all(profile.padding.left * 0.72),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label.toUpperCase(),
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.labelFontSize + 1.8,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
                shadows: hudStrongTextShadows,
              ),
            ),
            const Spacer(),
            Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.primaryValueFontSize + 3.2,
                fontWeight: FontWeight.w900,
                height: 1.0,
                shadows: hudStrongTextShadows,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AdaptiveHudModeStripe extends StatelessWidget {
  final String label;
  final String kind;
  final HudLayoutProfile profile;

  const AdaptiveHudModeStripe({
    super.key,
    required this.label,
    required this.kind,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    final bg = switch (kind) {
      'eco' => _hudSurfaceGreen,
      'safe' => _hudSurfaceGreen,
      'fast' => _hudSurfaceGreen,
      _ => _hudSurfaceGreenSoft,
    };
    final fg = switch (kind) {
      'safe' => Colors.white,
      'fast' => Colors.white,
      'eco' => Colors.white,
      _ => Colors.white,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: profile.density == HudDensityClass.micro ? 10 : 12,
          vertical: profile.density == HudDensityClass.micro ? 4 : 6,
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontSize: profile.secondaryValueFontSize - 1.8,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.3,
              shadows: hudStrongTextShadows,
            ),
          ),
        ),
      ),
    );
  }
}

class AdaptiveHudInfoPill extends StatelessWidget {
  final String label;
  final Color color;
  final HudLayoutProfile profile;
  final bool blinking;
  final bool dense;

  const AdaptiveHudInfoPill({
    super.key,
    required this.label,
    required this.color,
    required this.profile,
    this.blinking = false,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final horizontal = dense
        ? (profile.density == HudDensityClass.micro ? 9.0 : 10.0)
        : (profile.density == HudDensityClass.micro ? 10.0 : 12.0);
    final vertical = dense
        ? (profile.density == HudDensityClass.micro ? 4.0 : 5.0)
        : (profile.density == HudDensityClass.micro ? 6.0 : 8.0);
    return Opacity(
      opacity: blinking ? 0.68 : 1.0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.34)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontal,
            vertical: vertical,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: profile.chipFontSize + (dense ? 0.2 : 0.6),
              fontWeight: FontWeight.w900,
              letterSpacing: 0.28,
            ),
          ),
        ),
      ),
    );
  }
}

class AdaptiveHudGapBars extends StatelessWidget {
  final int count;
  final String label;
  final HudLayoutProfile profile;
  final bool compact;

  const AdaptiveHudGapBars({
    super.key,
    required this.count,
    required this.label,
    required this.profile,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final bars = List<Widget>.generate(4, (index) {
      final active = index < count;
      return Expanded(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: active
              ? (compact ? 12 : 16)
              : (compact ? 6 : 8),
          margin: EdgeInsets.symmetric(horizontal: profile.metricGap * 0.18),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.white24,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      );
    });
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _hudSurfaceGreenSoft,
        borderRadius: BorderRadius.circular(profile.borderRadius - 10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 10,
          vertical: compact ? 9 : 12,
        ),
        child: Column(
          children: <Widget>[
            Text(
              'GAP $label',
              style: TextStyle(
                color: Colors.white70,
                fontSize: profile.chipFontSize + 0.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.3,
              ),
            ),
            SizedBox(height: compact ? 8 : 10),
            Row(children: bars),
          ],
        ),
      ),
    );
  }
}

class AdaptiveHudGapValueChip extends StatelessWidget {
  final String label;
  final HudLayoutProfile profile;

  const AdaptiveHudGapValueChip({
    super.key,
    required this.label,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _hudSurfaceGreenSoft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(
          '($label)',
          style: TextStyle(
            color: Colors.white70,
            fontSize: profile.chipFontSize + 0.9,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

class AdaptiveHudSetSpeedPanel extends StatelessWidget {
  final HudAdaptiveDisplayModel model;
  final HudLayoutProfile profile;

  const AdaptiveHudSetSpeedPanel({
    super.key,
    required this.model,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    final hasGear = model.gearText.trim().toUpperCase() != 'U';
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 220.0;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 180.0;
        final tight = height < 230 || width < 230;
        final veryTight = height < 198 || width < 206;
        final supportCompact = veryTight || width < 248;
        final blockPadding = EdgeInsets.all(
          (profile.padding.left * (tight ? 0.52 : 0.66)).clamp(8.0, 16.0),
        );
        final tempLabelText =
            model.showTempControl ? model.tempLabel : 'TEMP';
        final tempSpeedText =
            model.showTempControl ? model.tempSpeedText : '--';
        return DecoratedBox(
          decoration: BoxDecoration(
            color: _hudSurfaceGreenSoft,
            borderRadius: BorderRadius.circular(profile.borderRadius - 8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
          ),
          child: Padding(
            padding: blockPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '설정속도',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: profile.chipFontSize + 1.8,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.3,
                    shadows: hudStrongTextShadows,
                  ),
                ),
                SizedBox(height: profile.metricGap * 0.16),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      height: tight
                          ? (profile.primaryValueFontSize + 2)
                          : (profile.primaryValueFontSize + 8)
                                .clamp(28, 60)
                                .toDouble(),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            model.setSpeedText,
                            style: TextStyle(
                              color: const Color(0xFFF4F7FB),
                              fontSize: profile.primaryValueFontSize +
                                  (tight ? 4 : 8),
                              fontWeight: FontWeight.w900,
                              height: 0.92,
                              letterSpacing: -0.8,
                              shadows: hudStrongTextShadows,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: profile.metricGap * 0.24),
                _AdaptiveHudSupportLine(
                  leftText: tempLabelText,
                  rightText: tempSpeedText,
                  profile: profile,
                  compact: supportCompact,
                ),
                SizedBox(height: profile.metricGap * (supportCompact ? 0.18 : 0.26)),
                _AdaptiveHudSupportDetailArea(
                  count: model.showGap ? model.gapBarCount : 0,
                  gapLabel: model.showGap ? model.gapText : '--',
                  gearText: hasGear ? model.gearText : '',
                  profile: profile,
                  compact: supportCompact,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class AdaptiveHudGearChip extends StatelessWidget {
  final String gearText;
  final HudLayoutProfile profile;

  const AdaptiveHudGearChip({
    super.key,
    required this.gearText,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    final unknown = gearText.trim().toUpperCase() == 'U';
    final displayText = unknown ? '–' : gearText;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: unknown ? 0.045 : 0.08),
        borderRadius: BorderRadius.circular(profile.borderRadius - 12),
        border: Border.all(
          color: Colors.white.withValues(alpha: unknown ? 0.10 : 0.16),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: unknown ? 10 : 12,
          vertical: unknown ? 6 : 8,
        ),
        child: Text(
          displayText,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: unknown ? Colors.white38 : Colors.white.withValues(alpha: 0.92),
            fontSize: unknown
                ? profile.secondaryValueFontSize - 2
                : profile.gearFontSize * 0.46,
            fontWeight: FontWeight.w900,
            height: 1.0,
            shadows: hudStrongTextShadows,
          ),
        ),
      ),
    );
  }
}

class AdaptiveHudSignalIndicator extends StatelessWidget {
  final String signalState;
  final HudLayoutProfile profile;

  const AdaptiveHudSignalIndicator({
    super.key,
    required this.signalState,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    final normalized = signalState.trim().toLowerCase();
    if (normalized.isEmpty || normalized == 'off') {
      return const SizedBox.shrink();
    }
    final color = switch (normalized) {
      'red' => const Color(0xFFFF5C5C),
      'green' => _hudAccentGreen,
      'yellow' => _hudAccentAmber,
      _ => Colors.white38,
    };
    return Container(
      width: profile.labelFontSize + 8,
      height: profile.labelFontSize + 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: color.withValues(alpha: 0.32),
            blurRadius: 8,
            spreadRadius: 0.3,
          ),
        ],
      ),
    );
  }
}

class AdaptiveHudTopMetricBar extends StatelessWidget {
  final HudAdaptiveDisplayModel model;
  final HudLayoutProfile profile;

  const AdaptiveHudTopMetricBar({
    super.key,
    required this.model,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    final barHeight = adaptiveHudBandHeight(profile);
    return SizedBox(
      height: barHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _hudSurfaceGreen,
          borderRadius: BorderRadius.circular(profile.borderRadius - 10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.26)),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: _AdaptiveHudMetricBarCell(
                icon: Icons.thermostat_rounded,
                value: model.cpuText.replaceAll('°C', '°'),
                accent: Colors.white,
                profile: profile,
              ),
            ),
            _AdaptiveHudMetricDivider(profile: profile),
            Expanded(
              child: _AdaptiveHudMetricBarCell(
                icon: Icons.memory_rounded,
                value: model.memText,
                accent: Colors.white,
                profile: profile,
              ),
            ),
            _AdaptiveHudMetricDivider(profile: profile),
            Expanded(
              child: _AdaptiveHudMetricBarCell(
                icon: model.auxMetricLabel == 'VOLT'
                    ? Icons.bolt_rounded
                    : Icons.storage_rounded,
                value: model.auxMetricText.replaceAll('.0V', 'V'),
                accent: Colors.white,
                profile: profile,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AdaptiveHudInfoRow extends StatelessWidget {
  final HudAdaptiveDisplayModel model;
  final HudLayoutProfile profile;
  final bool dense;

  const AdaptiveHudInfoRow({
    super.key,
    required this.model,
    required this.profile,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: dense ? profile.sectionGap * 0.34 : profile.sectionGap * 0.5,
      runSpacing: dense ? profile.sectionGap * 0.28 : profile.sectionGap * 0.4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        AdaptiveHudInfoPill(
          label: model.limitDisplayText,
          color: model.limitCritical
              ? const Color(0xFFFF6357)
              : Colors.white,
          profile: profile,
          blinking: model.limitBlink,
          dense: dense,
        ),
        AdaptiveHudInfoPill(
          label: model.connectivityDisplayText,
          color: Colors.white,
          profile: profile,
          dense: dense,
        ),
      ],
    );
  }
}

class AdaptiveHudBottomStrip extends StatelessWidget {
  final HudAdaptiveDisplayModel model;
  final HudLayoutProfile profile;

  const AdaptiveHudBottomStrip({
    super.key,
    required this.model,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    final signalActive = model.showSignalState;
    final signalText = signalActive ? model.signalDisplayText : '--';
    final barHeight = adaptiveHudBandHeight(profile);
    final signalWidth = switch (profile.density) {
      HudDensityClass.micro => 34.0,
      HudDensityClass.compact => 40.0,
      HudDensityClass.regular => 46.0,
      HudDensityClass.spacious => 52.0,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _hudSurfaceGreen,
        borderRadius: BorderRadius.circular(profile.borderRadius - 10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.26)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: profile.sectionGap * 0.72,
          vertical: ((barHeight - (profile.chipFontSize + 4)) / 2)
              .clamp(2.0, 4.0),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: profile.chipFontSize + 12,
              child: Align(
                alignment: Alignment.centerLeft,
                child: AdaptiveHudStatusDot(
                  color: model.redDot
                      ? const Color(0xFFFF5C5C)
                      : Colors.white24,
                  size: profile.chipFontSize + 2,
                ),
              ),
            ),
            _AdaptiveHudMetricDivider(profile: profile),
            Expanded(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: _AdaptiveHudBottomStripTextSegment(
                      text: model.driveModeText,
                      profile: profile,
                      color: Colors.white.withValues(alpha: 0.96),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  _AdaptiveHudMetricDivider(profile: profile),
                  Expanded(
                    child: _AdaptiveHudBottomStripTextSegment(
                      text: model.showLimit ? model.limitDisplayText : '',
                      profile: profile,
                      color: Colors.white,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  _AdaptiveHudMetricDivider(profile: profile),
                  Expanded(
                    child: _AdaptiveHudBottomStripTextSegment(
                      text: model.showConnectivity
                          ? model.connectivityDisplayText
                          : '',
                      profile: profile,
                      color: Colors.white,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
            _AdaptiveHudMetricDivider(profile: profile),
            SizedBox(
              width: signalWidth,
              child: Align(
                alignment: Alignment.centerRight,
                child: _AdaptiveHudBottomStripTextSegment(
                  text: signalText,
                  profile: profile,
                  color: signalActive
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.34),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdaptiveHudBottomStripTextSegment extends StatelessWidget {
  final String text;
  final HudLayoutProfile profile;
  final Color color;
  final TextAlign textAlign;

  const _AdaptiveHudBottomStripTextSegment({
    required this.text,
    required this.profile,
    required this.color,
    required this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: switch (textAlign) {
        TextAlign.left => Alignment.centerLeft,
        TextAlign.right => Alignment.centerRight,
        _ => Alignment.center,
      },
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
        style: TextStyle(
          color: color,
          fontSize: profile.chipFontSize + 2.8,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.18,
          height: 1.0,
          shadows: hudStrongTextShadows,
        ),
      ),
    );
  }
}

class AdaptiveHudLeftClusterColumn extends StatelessWidget {
  final Widget speedCluster;
  final HudAdaptiveDisplayModel model;
  final HudLayoutProfile profile;

  const AdaptiveHudLeftClusterColumn({
    super.key,
    required this.speedCluster,
    required this.model,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(child: speedCluster);
  }
}

class AdaptiveHudRightClusterColumn extends StatelessWidget {
  final HudAdaptiveDisplayModel model;
  final HudLayoutProfile profile;

  const AdaptiveHudRightClusterColumn({
    super.key,
    required this.model,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: AdaptiveHudSetSpeedPanel(
        model: model,
        profile: profile,
      ),
    );
  }
}

class _AdaptiveHudSupportLine extends StatelessWidget {
  final String leftText;
  final String rightText;
  final HudLayoutProfile profile;
  final bool compact;

  const _AdaptiveHudSupportLine({
    required this.leftText,
    required this.rightText,
    required this.profile,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final labelFontSize = compact
        ? profile.chipFontSize + 0.4
        : profile.labelFontSize + 1.8;
    final valueFontSize = compact
        ? profile.chipFontSize + 1.4
        : profile.labelFontSize + 2.4;
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            leftText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: labelFontSize,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.22,
              shadows: hudStrongTextShadows,
            ),
          ),
          SizedBox(height: profile.metricGap * 0.10),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              rightText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.86),
                fontSize: valueFontSize,
                fontWeight: FontWeight.w900,
                height: 1.0,
                shadows: hudStrongTextShadows,
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            leftText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: labelFontSize,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.22,
              shadows: hudStrongTextShadows,
            ),
          ),
        ),
        SizedBox(width: profile.metricGap * 0.46),
        Text(
          rightText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.86),
            fontSize: valueFontSize,
            fontWeight: FontWeight.w900,
            height: 1.0,
            shadows: hudStrongTextShadows,
          ),
        ),
      ],
    );
  }
}

class _AdaptiveHudSupportDetailArea extends StatelessWidget {
  final int count;
  final String gapLabel;
  final String gearText;
  final HudLayoutProfile profile;
  final bool compact;

  const _AdaptiveHudSupportDetailArea({
    required this.count,
    required this.gapLabel,
    required this.gearText,
    required this.profile,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final gearWidget = _AdaptiveHudMiniGearStatus(
      gearText: gearText,
      profile: profile,
      compact: compact,
    );
    final gapWidget = _AdaptiveHudMiniGapStatus(
      count: count,
      label: gapLabel,
      profile: profile,
      compact: compact,
      stacked: false,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        gapWidget,
        SizedBox(height: profile.metricGap * (compact ? 0.18 : 0.24)),
        Align(
          alignment: Alignment.centerRight,
          child: gearWidget,
        ),
      ],
    );
  }
}

class _AdaptiveHudMiniGapStatus extends StatelessWidget {
  final int count;
  final String label;
  final HudLayoutProfile profile;
  final bool compact;
  final bool stacked;

  const _AdaptiveHudMiniGapStatus({
    required this.count,
    required this.label,
    required this.profile,
    required this.compact,
    this.stacked = false,
  });

  @override
  Widget build(BuildContext context) {
    final barCount = count.clamp(0, 4);
    final activeHeight = compact ? 8.0 : 10.0;
    final inactiveHeight = compact ? 3.0 : 4.0;
    final gapText = '(${label == '--' ? '--' : label})';
    final barRow = SizedBox(
      height: activeHeight,
      child: Row(
        children: List<Widget>.generate(4, (index) {
          final active = index < barCount;
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              margin: EdgeInsets.symmetric(
                horizontal: profile.metricGap * 0.08,
              ),
              height: active ? activeHeight : inactiveHeight,
              decoration: BoxDecoration(
                color: active
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          );
        }),
      ),
    );
    final gapLabel = Text(
      gapText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: stacked ? TextAlign.left : TextAlign.right,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.84),
        fontSize: compact
            ? profile.chipFontSize + 0.3
            : profile.labelFontSize + 0.9,
        fontWeight: FontWeight.w900,
        letterSpacing: 0.16,
        shadows: hudStrongTextShadows,
      ),
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          barRow,
          SizedBox(height: profile.metricGap * 0.18),
          gapLabel,
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: barRow),
        SizedBox(width: profile.metricGap * 0.26),
        Flexible(child: gapLabel),
      ],
    );
  }
}

class _AdaptiveHudMiniGearStatus extends StatelessWidget {
  final String gearText;
  final HudLayoutProfile profile;
  final bool compact;

  const _AdaptiveHudMiniGearStatus({
    required this.gearText,
    required this.profile,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final hasGear = gearText.trim().isNotEmpty;
    final value = hasGear ? gearText.trim().toUpperCase() : '–';
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: compact ? 46 : 58,
        maxWidth: compact ? 78 : 94,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Text(
            'GEAR',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.58),
              fontSize:
                  compact ? profile.chipFontSize - 1.8 : profile.chipFontSize - 0.8,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.26,
              shadows: hudStrongTextShadows,
            ),
          ),
          SizedBox(height: compact ? 2 : 3),
          Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Colors.white.withValues(alpha: hasGear ? 0.95 : 0.42),
              fontSize: compact
                  ? profile.secondaryValueFontSize - 4.4
                  : profile.secondaryValueFontSize - 2.2,
              fontWeight: FontWeight.w900,
              height: 1.0,
              shadows: hudStrongTextShadows,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdaptiveHudMetricBarCell extends StatelessWidget {
  final IconData icon;
  final String value;
  final Color accent;
  final HudLayoutProfile profile;

  const _AdaptiveHudMetricBarCell({
    required this.icon,
    required this.value,
    required this.accent,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: profile.sectionGap * 0.45,
        vertical: profile.metricGap * 0.45,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            icon,
            size: profile.chipFontSize + 4.4,
            color: accent,
          ),
          SizedBox(width: profile.metricGap * 0.4),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.chipFontSize + 2.9,
                fontWeight: FontWeight.w900,
                height: 1.0,
                shadows: hudStrongTextShadows,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdaptiveHudMetricDivider extends StatelessWidget {
  final HudLayoutProfile profile;

  const _AdaptiveHudMetricDivider({
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    final dividerHeight = adaptiveHudBandHeight(profile) - 10;
    return Container(
      width: 1,
      height: dividerHeight,
      color: Colors.white.withValues(alpha: 0.08),
    );
  }
}

class AdaptiveHudStatusBand extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final HudLayoutProfile profile;

  const AdaptiveHudStatusBand({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _hudSurfaceGreenSoft,
        borderRadius: BorderRadius.circular(profile.borderRadius - 10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                color: Colors.white54,
                fontSize: profile.chipFontSize + 0.5,
                fontWeight: FontWeight.w800,
                shadows: hudStrongTextShadows,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.chipFontSize + 1.8,
                fontWeight: FontWeight.w900,
                shadows: hudStrongTextShadows,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AdaptiveHudActiveChip extends StatelessWidget {
  final String label;
  final bool active;
  final HudLayoutProfile profile;

  const AdaptiveHudActiveChip({
    super.key,
    required this.label,
    required this.active,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active
            ? const Color(0xFF6FF3A4).withValues(alpha: 0.16)
            : Colors.white10,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? const Color(0xFF6FF3A4) : Colors.white12,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: active ? 0.96 : 0.72),
            fontSize: profile.chipFontSize + 0.2,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.2,
            shadows: hudStrongTextShadows,
          ),
        ),
      ),
    );
  }
}

class AdaptiveHudStatusDot extends StatelessWidget {
  final Color color;
  final double size;

  const AdaptiveHudStatusDot({
    super.key,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: color.withValues(alpha: 0.45),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}
