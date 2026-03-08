import 'package:flutter/material.dart';

import '../models/hud_adaptive_display_model.dart';
import '../models/hud_layout_profile.dart';
import 'adaptive_hud_primitives.dart';

class AdaptiveHudDriveOverlaySpeedCluster extends StatelessWidget {
  final HudLayoutProfile profile;
  final HudAdaptiveDisplayModel model;

  const AdaptiveHudDriveOverlaySpeedCluster({
    super.key,
    required this.profile,
    required this.model,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xD9114A31),
        borderRadius: BorderRadius.circular(profile.borderRadius - 8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
      ),
      child: Padding(
        padding: EdgeInsets.all(profile.padding.left * 0.72),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '현재속도',
              style: TextStyle(
                color: Colors.white70,
                fontSize: profile.chipFontSize + 1.4,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.3,
                shadows: hudStrongTextShadows,
              ),
            ),
            SizedBox(height: profile.metricGap * 0.12),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    model.speedText,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: profile.speedFontSize + 12,
                      height: 0.82,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.5,
                      shadows: hudStrongTextShadows,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AdaptiveHudDriveOverlayMetaRow extends StatelessWidget {
  final HudLayoutProfile profile;
  final HudAdaptiveDisplayModel model;
  final String? qualityLabel;
  final String? compatibilityLabel;
  final bool showHost;

  const AdaptiveHudDriveOverlayMetaRow({
    super.key,
    required this.profile,
    required this.model,
    required this.qualityLabel,
    required this.compatibilityLabel,
    required this.showHost,
  });

  @override
  Widget build(BuildContext context) {
    return AdaptiveHudBottomStrip(
      model: model,
      profile: profile,
    );
  }
}
