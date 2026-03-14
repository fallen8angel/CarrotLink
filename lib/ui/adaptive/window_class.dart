import 'dart:ui' as ui;

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
  final bool hasHinge;
  final bool hasVerticalHinge;
  final bool hasHorizontalHinge;

  const UiWindowInfo({
    required this.size,
    required this.shortestSide,
    required this.isLandscape,
    required this.windowClass,
    this.hasHinge = false,
    this.hasVerticalHinge = false,
    this.hasHorizontalHinge = false,
  });

  bool get isCompact => windowClass == UiWindowClass.compact;
  bool get isMedium => windowClass == UiWindowClass.medium;
  bool get isExpandedOrAbove =>
      windowClass == UiWindowClass.expanded ||
      windowClass == UiWindowClass.large ||
      windowClass == UiWindowClass.extraLarge;
  bool get hasTightHeight => size.height < 640;
  bool get isConstrainedLandscape => isLandscape && hasTightHeight;

  static UiWindowInfo of(BuildContext context) {
    final mq = MediaQuery.of(context);
    final hasVerticalHinge = mq.displayFeatures.any((f) {
      if (f.type != ui.DisplayFeatureType.hinge &&
          f.type != ui.DisplayFeatureType.fold) {
        return false;
      }
      return f.bounds.height >= f.bounds.width;
    });
    final hasHorizontalHinge = mq.displayFeatures.any((f) {
      if (f.type != ui.DisplayFeatureType.hinge &&
          f.type != ui.DisplayFeatureType.fold) {
        return false;
      }
      return f.bounds.width > f.bounds.height;
    });
    final width = mq.size.width;
    final klass = classifyWidth(width);
    return UiWindowInfo(
      size: mq.size,
      shortestSide: mq.size.shortestSide,
      isLandscape: mq.size.width >= mq.size.height,
      windowClass: klass,
      hasHinge: hasVerticalHinge || hasHorizontalHinge,
      hasVerticalHinge: hasVerticalHinge,
      hasHorizontalHinge: hasHorizontalHinge,
    );
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
