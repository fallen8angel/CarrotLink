import 'package:flutter/material.dart';
import 'dart:ui' as ui;

class DisplayFeatureUtils {
  const DisplayFeatureUtils._();

  static EdgeInsets hingeAwarePadding(BuildContext context) {
    final mq = MediaQuery.of(context);
    final base = mq.padding;
    final features = mq.displayFeatures;
    if (features.isEmpty) {
      return base;
    }

    double extraLeft = 0;
    double extraRight = 0;
    double extraTop = 0;
    double extraBottom = 0;

    for (final f in features) {
      // Treat fold/hinge as a non-content area.
      if (f.type != ui.DisplayFeatureType.hinge &&
          f.type != ui.DisplayFeatureType.fold) {
        continue;
      }
      final b = f.bounds;
      if (b.width > b.height) {
        // Horizontal fold/hinge.
        final topHalf = b.center.dy <= (mq.size.height * 0.5);
        if (topHalf) {
          extraTop = extraTop > b.bottom ? extraTop : b.bottom;
        } else {
          final candidate = mq.size.height - b.top;
          extraBottom = extraBottom > candidate ? extraBottom : candidate;
        }
      } else {
        // Vertical fold/hinge.
        final leftHalf = b.center.dx <= (mq.size.width * 0.5);
        if (leftHalf) {
          extraLeft = extraLeft > b.right ? extraLeft : b.right;
        } else {
          final candidate = mq.size.width - b.left;
          extraRight = extraRight > candidate ? extraRight : candidate;
        }
      }
    }

    return EdgeInsets.only(
      left: base.left > extraLeft ? base.left : extraLeft,
      top: base.top > extraTop ? base.top : extraTop,
      right: base.right > extraRight ? base.right : extraRight,
      bottom: base.bottom > extraBottom ? base.bottom : extraBottom,
    );
  }
}
