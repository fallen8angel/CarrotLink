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
  final double dockInset;
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
    required this.dockInset,
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
    final heightWeightedShortest = (() {
      final heightBudget = switch (surface) {
        HudSurfaceVariant.driveOverlay => height * 0.76,
        HudSurfaceVariant.driveInline => height * 0.84,
        _ => height,
      };
      return shortest < heightBudget ? shortest : heightBudget;
    })();
    final density = heightWeightedShortest < 190
        ? HudDensityClass.micro
        : heightWeightedShortest < 280
            ? HudDensityClass.compact
            : heightWeightedShortest < 420
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
            HudSurfaceVariant.driveOverlay => 1.14,
            HudSurfaceVariant.driveInline => 1.08,
            HudSurfaceVariant.preview => 1.28,
            HudSurfaceVariant.homePreview => 0.92,
          },
          borderRadius: 18,
          dockInset: surface == HudSurfaceVariant.driveOverlay ? 4 : 6,
          padding: const EdgeInsets.all(13),
          sectionGap: 11,
          metricGap: 9,
          speedFontSize: 74,
          primaryValueFontSize: 34,
          secondaryValueFontSize: 24,
          labelFontSize: 13.5,
          chipFontSize: 12.5,
          gearFontSize: 38,
          showMetrics: true,
          showTopStatusRow: true,
          showFooterDetails: true,
          useThreeColumnMainRow: false,
          maxWidth: switch (surface) {
            HudSurfaceVariant.driveOverlay => 452.0,
            HudSurfaceVariant.driveInline => 404.0,
            HudSurfaceVariant.preview => 384.0,
            HudSurfaceVariant.homePreview => 360.0,
          },
        );
      case HudDensityClass.compact:
        return HudLayoutProfile(
          density: HudDensityClass.compact,
          surface: surface,
          wide: wide,
          preferredAspectRatio: switch (surface) {
            HudSurfaceVariant.driveOverlay => wide ? 1.16 : 0.94,
            HudSurfaceVariant.driveInline => wide ? 1.08 : 0.80,
            HudSurfaceVariant.preview => wide ? 1.30 : 0.90,
            HudSurfaceVariant.homePreview => wide ? 0.98 : 0.88,
          },
          borderRadius: 20,
          dockInset: surface == HudSurfaceVariant.driveOverlay ? 6 : 8,
          padding: const EdgeInsets.all(16),
          sectionGap: 13,
          metricGap: 10,
          speedFontSize: 90,
          primaryValueFontSize: 38,
          secondaryValueFontSize: 26,
          labelFontSize: 14.5,
          chipFontSize: 13.5,
          gearFontSize: 46,
          showMetrics: true,
          showTopStatusRow: true,
          showFooterDetails: surface != HudSurfaceVariant.driveOverlay,
          useThreeColumnMainRow:
              wide && surface != HudSurfaceVariant.driveInline,
          maxWidth: switch (surface) {
            HudSurfaceVariant.driveOverlay => 540.0,
            HudSurfaceVariant.driveInline => 476.0,
            HudSurfaceVariant.preview => 452.0,
            HudSurfaceVariant.homePreview => 428.0,
          },
        );
      case HudDensityClass.regular:
        return HudLayoutProfile(
          density: HudDensityClass.regular,
          surface: surface,
          wide: wide,
          preferredAspectRatio: switch (surface) {
            HudSurfaceVariant.driveOverlay => wide ? 1.20 : 0.98,
            HudSurfaceVariant.driveInline => wide ? 1.10 : 0.84,
            HudSurfaceVariant.preview => wide ? 1.36 : 0.96,
            HudSurfaceVariant.homePreview => wide ? 1.02 : 0.92,
          },
          borderRadius: 24,
          dockInset: surface == HudSurfaceVariant.driveOverlay ? 8 : 10,
          padding: const EdgeInsets.all(20),
          sectionGap: 15,
          metricGap: 11,
          speedFontSize: 110,
          primaryValueFontSize: 45,
          secondaryValueFontSize: 31,
          labelFontSize: 15.5,
          chipFontSize: 14.5,
          gearFontSize: 56,
          showMetrics: true,
          showTopStatusRow: true,
          showFooterDetails: surface != HudSurfaceVariant.driveOverlay,
          useThreeColumnMainRow: wide,
          maxWidth: switch (surface) {
            HudSurfaceVariant.driveOverlay => 670.0,
            HudSurfaceVariant.driveInline => 604.0,
            HudSurfaceVariant.preview => 560.0,
            HudSurfaceVariant.homePreview => 536.0,
          },
        );
      case HudDensityClass.spacious:
        return HudLayoutProfile(
          density: HudDensityClass.spacious,
          surface: surface,
          wide: wide,
          preferredAspectRatio: switch (surface) {
            HudSurfaceVariant.driveOverlay => wide ? 1.26 : 1.02,
            HudSurfaceVariant.driveInline => wide ? 1.16 : 0.90,
            HudSurfaceVariant.preview => wide ? 1.44 : 1.00,
            HudSurfaceVariant.homePreview => wide ? 1.08 : 0.96,
          },
          borderRadius: 28,
          dockInset: surface == HudSurfaceVariant.driveOverlay ? 10 : 12,
          padding: const EdgeInsets.all(24),
          sectionGap: 18,
          metricGap: 13,
          speedFontSize: 128,
          primaryValueFontSize: 52,
          secondaryValueFontSize: 36,
          labelFontSize: 16.5,
          chipFontSize: 15.5,
          gearFontSize: 68,
          showMetrics: true,
          showTopStatusRow: true,
          showFooterDetails: surface != HudSurfaceVariant.driveOverlay,
          useThreeColumnMainRow: true,
          maxWidth: switch (surface) {
            HudSurfaceVariant.driveOverlay => 820.0,
            HudSurfaceVariant.driveInline => 734.0,
            HudSurfaceVariant.preview => 690.0,
            HudSurfaceVariant.homePreview => 668.0,
          },
        );
    }
  }
}
