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
    return Padding(
      padding: EdgeInsets.fromLTRB(
        profile.padding.left * 0.26,
        profile.padding.top * 0.14,
        profile.padding.right * 0.18,
        profile.padding.bottom * 0.12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '현재속도',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: profile.chipFontSize + 1.4,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.3,
              shadows: hudStrongTextShadows,
            ),
          ),
          SizedBox(height: profile.metricGap * 0.08),
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
                    fontSize: profile.speedFontSize + 14,
                    height: 0.84,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.8,
                    shadows: hudStrongTextShadows,
                  ),
                ),
              ),
            ),
          ),
        ],
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
      qualityLabel: qualityLabel,
      compatibilityLabel: compatibilityLabel,
      showHost: showHost,
    );
  }
}
