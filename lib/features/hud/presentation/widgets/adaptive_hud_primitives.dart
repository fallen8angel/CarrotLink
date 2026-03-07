import 'package:flutter/material.dart';

import '../models/hud_layout_profile.dart';

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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(profile.borderRadius - 10),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                color: Colors.white60,
                fontSize: profile.chipFontSize,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.35,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.secondaryValueFontSize,
                fontWeight: FontWeight.w800,
                height: 1.0,
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
        gradient: LinearGradient(
          colors: <Color>[
            accent.withValues(alpha: 0.14),
            Colors.white.withValues(alpha: 0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(profile.borderRadius - 8),
        border: Border.all(color: accent.withValues(alpha: 0.32)),
      ),
      child: Padding(
        padding: EdgeInsets.all(profile.padding.left * 0.72),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label.toUpperCase(),
              style: TextStyle(
                color: accent,
                fontSize: profile.labelFontSize,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
            const Spacer(),
            Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.primaryValueFontSize,
                fontWeight: FontWeight.w800,
                height: 1.0,
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
      'eco' => const Color(0xFF0D6E3F),
      'safe' => const Color(0xFF7E4E18),
      'fast' => const Color(0xFF792626),
      _ => const Color(0xFF293240),
    };
    final fg = switch (kind) {
      'safe' => const Color(0xFFFFD085),
      'fast' => const Color(0xFFFFB0AB),
      'eco' => const Color(0xFF88F0A0),
      _ => Colors.white,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontSize: profile.secondaryValueFontSize - 2,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
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

  const AdaptiveHudInfoPill({
    super.key,
    required this.label,
    required this.color,
    required this.profile,
    this.blinking = false,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: blinking ? 0.68 : 1.0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.34)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: profile.chipFontSize,
              fontWeight: FontWeight.w800,
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
            color: active ? const Color(0xFF66E18D) : Colors.white12,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      );
    });
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(profile.borderRadius - 10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
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
                fontSize: profile.chipFontSize,
                fontWeight: FontWeight.w800,
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
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(profile.borderRadius - 10),
        border: Border.all(color: color.withValues(alpha: 0.34)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                color: Colors.white54,
                fontSize: profile.chipFontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.chipFontSize + 1,
                fontWeight: FontWeight.w800,
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
            color: active ? const Color(0xFF85F6AF) : Colors.white54,
            fontSize: profile.chipFontSize - 0.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
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
