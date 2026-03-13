import 'package:flutter/widgets.dart';

import '../models/hud_layout_profile.dart';

class AdaptiveHudDriveOverlaySurface extends StatelessWidget {
  final HudLayoutProfile profile;
  final bool showMetrics;
  final bool showDeviceMetrics;
  final Widget topStatusRow;
  final Widget metricRow;
  final Widget leftColumn;
  final Widget rightColumn;
  final Widget metaRow;

  const AdaptiveHudDriveOverlaySurface({
    super.key,
    required this.profile,
    required this.showMetrics,
    required this.showDeviceMetrics,
    required this.topStatusRow,
    required this.metricRow,
    required this.leftColumn,
    required this.rightColumn,
    required this.metaRow,
  });

  @override
  Widget build(BuildContext context) {
    final leftFlex = profile.wide
        ? (profile.density == HudDensityClass.micro ||
                profile.density == HudDensityClass.compact
            ? 5
            : 6)
        : 5;
    final rightFlex = profile.wide
        ? (profile.density == HudDensityClass.micro ||
                profile.density == HudDensityClass.compact
            ? 5
            : 5)
        : 4;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        topStatusRow,
        if (showMetrics && showDeviceMetrics) ...<Widget>[
          SizedBox(height: profile.sectionGap * 0.36),
          metricRow,
          SizedBox(height: profile.sectionGap * 0.46),
        ] else
          SizedBox(height: profile.sectionGap * 0.46),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(flex: leftFlex, child: leftColumn),
              SizedBox(width: profile.sectionGap * 0.40),
              Expanded(flex: rightFlex, child: rightColumn),
            ],
          ),
        ),
        if (metaRow is! SizedBox) ...<Widget>[
          SizedBox(height: profile.sectionGap * 0.42),
          metaRow,
        ],
      ],
    );
  }
}
