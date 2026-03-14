import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';

class SectionTabBar extends StatelessWidget {
  final TabController controller;
  final List<Widget> tabs;
  final bool isScrollable;

  const SectionTabBar({
    super.key,
    required this.controller,
    required this.tabs,
    this.isScrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final compactLandscape = window.isConstrainedLandscape;
    final verticalPadding = compactLandscape
        ? 6.0
        : switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 9.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large => 11.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final labelSize = compactLandscape
        ? 12.0
        : switch (window.windowClass) {
      UiWindowClass.compact => 12.5,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 13.5,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final labelPadding = compactLandscape
        ? 8.0
        : switch (window.windowClass) {
      UiWindowClass.compact => 10.0,
      UiWindowClass.medium => 11.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final indicatorWeight = compactLandscape
        ? 2.4
        : switch (window.windowClass) {
      UiWindowClass.compact => 2.5,
      UiWindowClass.medium => 2.6,
      UiWindowClass.expanded => 2.8,
      UiWindowClass.large => 3.0,
      UiWindowClass.extraLarge => 3.0,
    };
    final indicatorHorizontalInset = compactLandscape
        ? 6.0
        : switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 10.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 16.0,
    };

    return Container(
      padding: EdgeInsets.fromLTRB(
        compactLandscape
            ? 8.0
            : tokens.screenPadding.clamp(8.0, 24.0),
        verticalPadding,
        compactLandscape
            ? 8.0
            : tokens.screenPadding.clamp(8.0, 24.0),
        4,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          bottom: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabCount = math.max(1, tabs.length);
          final estimatedTabWidth =
              isScrollable ? 96.0 : (constraints.maxWidth / tabCount);
          final adaptiveInset = math.min(
            indicatorHorizontalInset,
            math.max(4.0, estimatedTabWidth * 0.22),
          );

          return TabBar(
            controller: controller,
            isScrollable: isScrollable,
            labelColor: colors.primary,
            unselectedLabelColor: colors.onSurfaceVariant,
            automaticIndicatorColorAdjustment: false,
            labelStyle: TextStyle(
              fontSize: labelSize,
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: TextStyle(
              fontSize: labelSize,
              fontWeight: FontWeight.w500,
            ),
            labelPadding: EdgeInsets.symmetric(horizontal: labelPadding),
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: UnderlineTabIndicator(
              borderSide: BorderSide(
                color: colors.primary.withValues(alpha: 0.96),
                width: indicatorWeight + 0.8,
              ),
              insets: EdgeInsets.symmetric(horizontal: adaptiveInset),
            ),
            dividerColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
            overlayColor: WidgetStateProperty.resolveWith<Color?>(
              (states) => states.contains(WidgetState.pressed)
                  ? colors.primary.withValues(alpha: 0.06)
                  : null,
            ),
            tabs: tabs,
          );
        },
      ),
    );
  }
}
