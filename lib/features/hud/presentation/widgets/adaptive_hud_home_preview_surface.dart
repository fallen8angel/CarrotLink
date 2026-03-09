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
    final integratedHomePreview =
        profile.surface == HudSurfaceVariant.homePreview;
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
          SizedBox(
            height: profile.sectionGap * (integratedHomePreview ? 0.28 : 0.46),
          ),
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
              SizedBox(
                width:
                    profile.sectionGap * (integratedHomePreview ? 0.18 : 0.38),
              ),
              if (integratedHomePreview)
                Container(
                  width: 1,
                  margin: EdgeInsets.symmetric(
                    vertical: profile.metricGap * 0.12,
                  ),
                  color: const Color(0xFFFFFFFF).withValues(alpha: 0.12),
                ),
              if (integratedHomePreview)
                SizedBox(width: profile.sectionGap * 0.18),
              Expanded(flex: rightFlex, child: supportColumn),
            ],
          ),
        ),
        if (profile.showFooterDetails) ...<Widget>[
          SizedBox(
            height: profile.sectionGap * (integratedHomePreview ? 0.26 : 0.42),
          ),
          footer,
        ],
      ],
    );
  }
}
