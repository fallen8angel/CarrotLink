import 'package:flutter/widgets.dart';

enum HudDensityClass {
  micro,
  compact,
  regular,
  spacious,
}

enum HudSurfaceVariant {
  homePreview,
  driveInline,
  driveOverlay,
  preview,
}

class HudLayoutProfile {
  final HudDensityClass density;
  final HudSurfaceVariant surface;
  final bool wide;
  final double preferredAspectRatio;
  final double borderRadius;
  final EdgeInsets padding;
  final double sectionGap;
  final double metricGap;
  final double speedFontSize;
  final double primaryValueFontSize;
  final double secondaryValueFontSize;
  final double labelFontSize;
  final double chipFontSize;
  final double gearFontSize;
  final bool showMetrics;
  final bool showTopStatusRow;
  final bool showFooterDetails;
  final bool useThreeColumnMainRow;
  final double maxWidth;

  const HudLayoutProfile({
    required this.density,
    required this.surface,
    required this.wide,
    required this.preferredAspectRatio,
    required this.borderRadius,
    required this.padding,
    required this.sectionGap,
    required this.metricGap,
    required this.speedFontSize,
    required this.primaryValueFontSize,
    required this.secondaryValueFontSize,
    required this.labelFontSize,
    required this.chipFontSize,
    required this.gearFontSize,
    required this.showMetrics,
    required this.showTopStatusRow,
    required this.showFooterDetails,
    required this.useThreeColumnMainRow,
    required this.maxWidth,
  });

  factory HudLayoutProfile.fromConstraints(
    BoxConstraints constraints, {
    HudSurfaceVariant surface = HudSurfaceVariant.homePreview,
  }) {
    final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
    final height = constraints.maxHeight.isFinite && constraints.maxHeight > 0
        ? constraints.maxHeight
            : width / 1.76;
    final shortest = width < height ? width : height;
    final aspect = width / (height <= 0 ? 1 : height);
    final density = shortest < 190
        ? HudDensityClass.micro
        : shortest < 280
            ? HudDensityClass.compact
            : shortest < 420
                ? HudDensityClass.regular
                : HudDensityClass.spacious;
    final wideThreshold = switch (surface) {
      HudSurfaceVariant.driveOverlay => 1.12,
      HudSurfaceVariant.driveInline => 1.18,
      HudSurfaceVariant.preview => 1.22,
      HudSurfaceVariant.homePreview => 1.26,
    };
    final wide = aspect >= wideThreshold;

    switch (density) {
      case HudDensityClass.micro:
        return HudLayoutProfile(
          density: HudDensityClass.micro,
          surface: surface,
          wide: false,
          preferredAspectRatio: switch (surface) {
            HudSurfaceVariant.driveOverlay => 1.86,
            HudSurfaceVariant.driveInline => 1.74,
            HudSurfaceVariant.preview => 1.64,
            HudSurfaceVariant.homePreview => 1.58,
          },
          borderRadius: 18,
          padding: const EdgeInsets.all(12),
          sectionGap: 10,
          metricGap: 8,
          speedFontSize: 58,
          primaryValueFontSize: 26,
          secondaryValueFontSize: 18,
          labelFontSize: 11,
          chipFontSize: 10,
          gearFontSize: 30,
          showMetrics: true,
          showTopStatusRow: surface != HudSurfaceVariant.homePreview,
          showFooterDetails: surface == HudSurfaceVariant.homePreview,
          useThreeColumnMainRow: false,
          maxWidth: switch (surface) {
            HudSurfaceVariant.driveOverlay => 420.0,
            HudSurfaceVariant.driveInline => 380.0,
            HudSurfaceVariant.preview => 360.0,
            HudSurfaceVariant.homePreview => 340.0,
          },
        );
      case HudDensityClass.compact:
        return HudLayoutProfile(
          density: HudDensityClass.compact,
          surface: surface,
          wide: wide,
          preferredAspectRatio: switch (surface) {
            HudSurfaceVariant.driveOverlay => wide ? 1.94 : 1.32,
            HudSurfaceVariant.driveInline => wide ? 1.76 : 1.08,
            HudSurfaceVariant.preview => wide ? 1.72 : 1.02,
            HudSurfaceVariant.homePreview => wide ? 1.66 : 1.0,
          },
          borderRadius: 20,
          padding: const EdgeInsets.all(14),
          sectionGap: 12,
          metricGap: 9,
          speedFontSize: 70,
          primaryValueFontSize: 29,
          secondaryValueFontSize: 20,
          labelFontSize: 12,
          chipFontSize: 11,
          gearFontSize: 36,
          showMetrics: true,
          showTopStatusRow: true,
          showFooterDetails: surface != HudSurfaceVariant.driveOverlay,
          useThreeColumnMainRow:
              wide && surface != HudSurfaceVariant.driveInline,
          maxWidth: switch (surface) {
            HudSurfaceVariant.driveOverlay => 500.0,
            HudSurfaceVariant.driveInline => 440.0,
            HudSurfaceVariant.preview => 420.0,
            HudSurfaceVariant.homePreview => 400.0,
          },
        );
      case HudDensityClass.regular:
        return HudLayoutProfile(
          density: HudDensityClass.regular,
          surface: surface,
          wide: wide,
          preferredAspectRatio: switch (surface) {
            HudSurfaceVariant.driveOverlay => wide ? 2.06 : 1.46,
            HudSurfaceVariant.driveInline => wide ? 1.88 : 1.18,
            HudSurfaceVariant.preview => wide ? 1.84 : 1.12,
            HudSurfaceVariant.homePreview => wide ? 1.78 : 1.08,
          },
          borderRadius: 24,
          padding: const EdgeInsets.all(18),
          sectionGap: 14,
          metricGap: 10,
          speedFontSize: 86,
          primaryValueFontSize: 34,
          secondaryValueFontSize: 24,
          labelFontSize: 13,
          chipFontSize: 11.5,
          gearFontSize: 44,
          showMetrics: true,
          showTopStatusRow: true,
          showFooterDetails: surface != HudSurfaceVariant.driveOverlay,
          useThreeColumnMainRow: wide,
          maxWidth: switch (surface) {
            HudSurfaceVariant.driveOverlay => 620.0,
            HudSurfaceVariant.driveInline => 560.0,
            HudSurfaceVariant.preview => 520.0,
            HudSurfaceVariant.homePreview => 500.0,
          },
        );
      case HudDensityClass.spacious:
        return HudLayoutProfile(
          density: HudDensityClass.spacious,
          surface: surface,
          wide: wide,
          preferredAspectRatio: switch (surface) {
            HudSurfaceVariant.driveOverlay => wide ? 2.18 : 1.54,
            HudSurfaceVariant.driveInline => wide ? 2.0 : 1.22,
            HudSurfaceVariant.preview => wide ? 1.98 : 1.16,
            HudSurfaceVariant.homePreview => wide ? 1.94 : 1.12,
          },
          borderRadius: 28,
          padding: const EdgeInsets.all(22),
          sectionGap: 16,
          metricGap: 12,
          speedFontSize: 100,
          primaryValueFontSize: 40,
          secondaryValueFontSize: 28,
          labelFontSize: 14,
          chipFontSize: 12.5,
          gearFontSize: 52,
          showMetrics: true,
          showTopStatusRow: true,
          showFooterDetails: surface != HudSurfaceVariant.driveOverlay,
          useThreeColumnMainRow: true,
          maxWidth: switch (surface) {
            HudSurfaceVariant.driveOverlay => 760.0,
            HudSurfaceVariant.driveInline => 680.0,
            HudSurfaceVariant.preview => 640.0,
            HudSurfaceVariant.homePreview => 620.0,
          },
        );
    }
  }
}
