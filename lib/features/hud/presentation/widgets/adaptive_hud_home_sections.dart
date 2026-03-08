import 'package:flutter/material.dart';

import '../models/hud_adaptive_display_model.dart';
import '../models/hud_layout_profile.dart';
import 'adaptive_hud_primitives.dart';

class AdaptiveHudHomePrimarySection extends StatelessWidget {
  final HudLayoutProfile profile;
  final HudAdaptiveDisplayModel model;
  final Widget speedCluster;

  const AdaptiveHudHomePrimarySection({
    super.key,
    required this.profile,
    required this.model,
    required this.speedCluster,
  });

  @override
  Widget build(BuildContext context) {
    return AdaptiveHudLeftClusterColumn(
      speedCluster: speedCluster,
      model: model,
      profile: profile,
    );
  }
}

class AdaptiveHudHomeSupportSection extends StatelessWidget {
  final HudLayoutProfile profile;
  final HudAdaptiveDisplayModel model;

  const AdaptiveHudHomeSupportSection({
    super.key,
    required this.profile,
    required this.model,
  });

  @override
  Widget build(BuildContext context) {
    return AdaptiveHudRightClusterColumn(
      model: model,
      profile: profile,
    );
  }
}

class AdaptiveHudHomeFooter extends StatelessWidget {
  final HudLayoutProfile profile;
  final HudAdaptiveDisplayModel model;
  final String? qualityLabel;
  final String? compatibilityLabel;
  final bool showHost;

  const AdaptiveHudHomeFooter({
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
