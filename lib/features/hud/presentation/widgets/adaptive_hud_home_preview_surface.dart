import 'package:flutter/widgets.dart';

import '../models/hud_layout_profile.dart';

class AdaptiveHudHomePreviewSurface extends StatelessWidget {
  final HudLayoutProfile profile;
  final bool showMetrics;
  final bool showDeviceMetrics;
  final Widget topStatusRow;
  final Widget metricRow;
  final Widget primaryColumn;
  final Widget supportColumn;
  final Widget footer;

  const AdaptiveHudHomePreviewSurface({
    super.key,
    required this.profile,
    required this.showMetrics,
    required this.showDeviceMetrics,
    required this.topStatusRow,
    required this.metricRow,
    required this.primaryColumn,
    required this.supportColumn,
    required this.footer,
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
        if (profile.showTopStatusRow) ...<Widget>[
          topStatusRow,
          SizedBox(height: profile.sectionGap * 0.46),
        ],
        if (showMetrics && showDeviceMetrics) ...<Widget>[
          metricRow,
          SizedBox(height: profile.sectionGap),
        ],
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(flex: leftFlex, child: primaryColumn),
              SizedBox(width: profile.sectionGap * 0.38),
              Expanded(flex: rightFlex, child: supportColumn),
            ],
          ),
        ),
        if (profile.showFooterDetails) ...<Widget>[
          SizedBox(height: profile.sectionGap * 0.42),
          footer,
        ],
      ],
    );
  }
}
