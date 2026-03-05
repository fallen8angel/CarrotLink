import 'package:flutter/material.dart';

enum UiWindowClass {
  compact,
  medium,
  expanded,
  large,
  extraLarge,
}

class UiWindowInfo {
  final Size size;
  final double shortestSide;
  final bool isLandscape;
  final UiWindowClass windowClass;

  const UiWindowInfo({
    required this.size,
    required this.shortestSide,
    required this.isLandscape,
    required this.windowClass,
  });

  bool get isCompact => windowClass == UiWindowClass.compact;
  bool get isMedium => windowClass == UiWindowClass.medium;
  bool get isExpandedOrAbove =>
      windowClass == UiWindowClass.expanded ||
      windowClass == UiWindowClass.large ||
      windowClass == UiWindowClass.extraLarge;

  static UiWindowInfo of(BuildContext context) {
    final mq = MediaQuery.of(context);
    return fromSize(mq.size);
  }

  static UiWindowInfo fromSize(Size size) {
    final width = size.width;
    final klass = classifyWidth(width);
    return UiWindowInfo(
      size: size,
      shortestSide: size.shortestSide,
      isLandscape: size.width >= size.height,
      windowClass: klass,
    );
  }

  static UiWindowClass classifyWidth(double width) {
    if (width < 600) return UiWindowClass.compact;
    if (width < 840) return UiWindowClass.medium;
    if (width < 1200) return UiWindowClass.expanded;
    if (width < 1600) return UiWindowClass.large;
    return UiWindowClass.extraLarge;
  }
}
