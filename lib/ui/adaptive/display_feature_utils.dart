import 'dart:math' as math;
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

    const edgeTolerance = 1.0;
    for (final f in features) {
      if (f.type != ui.DisplayFeatureType.hinge &&
          f.type != ui.DisplayFeatureType.fold) {
        continue;
      }
      final b = f.bounds;
      final isHorizontal = b.width > b.height;
      if (isHorizontal) {
        final nearTop = b.top <= edgeTolerance;
        final nearBottom = (mq.size.height - b.bottom).abs() <= edgeTolerance;
        if (nearTop) {
          extraTop = math.max(extraTop, b.bottom);
        } else if (nearBottom) {
          extraBottom = math.max(extraBottom, mq.size.height - b.top);
        }
      } else {
        final nearLeft = b.left <= edgeTolerance;
        final nearRight = (mq.size.width - b.right).abs() <= edgeTolerance;
        if (nearLeft) {
          extraLeft = math.max(extraLeft, b.right);
        } else if (nearRight) {
          extraRight = math.max(extraRight, mq.size.width - b.left);
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
