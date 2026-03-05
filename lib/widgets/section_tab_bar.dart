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
    final verticalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 9.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large => 11.0,
      UiWindowClass.extraLarge => 12.0,
    };
    final labelSize = switch (window.windowClass) {
      UiWindowClass.compact => 12.5,
      UiWindowClass.medium => 13.0,
      UiWindowClass.expanded => 13.5,
      UiWindowClass.large => 14.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final labelPadding = switch (window.windowClass) {
      UiWindowClass.compact => 10.0,
      UiWindowClass.medium => 11.0,
      UiWindowClass.expanded => 12.0,
      UiWindowClass.large => 13.0,
      UiWindowClass.extraLarge => 14.0,
    };
    final indicatorWeight = switch (window.windowClass) {
      UiWindowClass.compact => 2.5,
      UiWindowClass.medium => 2.6,
      UiWindowClass.expanded => 2.8,
      UiWindowClass.large => 3.0,
      UiWindowClass.extraLarge => 3.0,
    };

    return Container(
      padding: EdgeInsets.fromLTRB(
        tokens.screenPadding.clamp(8.0, 24.0),
        verticalPadding,
        tokens.screenPadding.clamp(8.0, 24.0),
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
      child: TabBar(
        controller: controller,
        isScrollable: isScrollable,
        labelColor: colors.primary,
        unselectedLabelColor: colors.onSurfaceVariant,
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
        indicatorWeight: indicatorWeight,
        dividerColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.pressed)
              ? colors.primary.withValues(alpha: 0.06)
              : null,
        ),
        tabs: tabs,
      ),
    );
  }
}
