import 'package:flutter/material.dart';

import 'window_class.dart';

class UiLayoutTokens {
  final double screenPadding;
  final double itemGap;
  final double sectionGap;
  final double footerSpacer;

  const UiLayoutTokens({
    required this.screenPadding,
    required this.itemGap,
    required this.sectionGap,
    required this.footerSpacer,
  });

  static UiLayoutTokens of(BuildContext context) {
    final window = UiWindowInfo.of(context);
    switch (window.windowClass) {
      case UiWindowClass.compact:
        return const UiLayoutTokens(
          screenPadding: 16,
          itemGap: 6,
          sectionGap: 12,
          footerSpacer: 120,
        );
      case UiWindowClass.medium:
        return const UiLayoutTokens(
          screenPadding: 20,
          itemGap: 8,
          sectionGap: 14,
          footerSpacer: 130,
        );
      case UiWindowClass.expanded:
        return const UiLayoutTokens(
          screenPadding: 24,
          itemGap: 10,
          sectionGap: 16,
          footerSpacer: 140,
        );
      case UiWindowClass.large:
      case UiWindowClass.extraLarge:
        return const UiLayoutTokens(
          screenPadding: 28,
          itemGap: 12,
          sectionGap: 18,
          footerSpacer: 150,
        );
    }
  }
}
