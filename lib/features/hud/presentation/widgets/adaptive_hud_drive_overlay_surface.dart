import 'package:flutter/widgets.dart';

import '../models/hud_layout_profile.dart';

class AdaptiveHudDriveOverlaySurface extends StatelessWidget {
  final HudLayoutProfile profile;
  final Widget topStatusRow;
  final Widget leftColumn;
  final Widget rightColumn;
  final Widget metaRow;

  const AdaptiveHudDriveOverlaySurface({
    super.key,
    required this.profile,
    required this.topStatusRow,
    required this.leftColumn,
    required this.rightColumn,
    required this.metaRow,
  });

  @override
  Widget build(BuildContext context) {
    final leftFlex = profile.wide ? 6 : 5;
    final rightFlex = profile.wide ? 5 : 4;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        topStatusRow,
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
