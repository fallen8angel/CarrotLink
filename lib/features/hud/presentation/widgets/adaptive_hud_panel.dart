import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/entities/original_hud_snapshot.dart';
import '../models/hud_adaptive_display_model.dart';
import '../models/hud_layout_profile.dart';
import 'adaptive_hud_primitives.dart';

class AdaptiveHudPanel extends StatelessWidget {
  final OriginalHudSnapshot snapshot;
  final HudSurfaceVariant surface;
  final bool fillParent;
  final bool matchParentWidth;
  final String? stateTitle;
  final String? stateMessage;
  final bool preferStateShell;

  const AdaptiveHudPanel({
    super.key,
    required this.snapshot,
    this.surface = HudSurfaceVariant.homePreview,
    this.fillParent = false,
    this.matchParentWidth = false,
    this.stateTitle,
    this.stateMessage,
    this.preferStateShell = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final profile = HudLayoutProfile.fromConstraints(
          constraints,
          surface: surface,
        );
        final model = HudAdaptiveDisplayModel.fromSnapshot(snapshot);
        final showStateShell = preferStateShell && snapshot.tsMonoMs <= 0;
        final child = RepaintBoundary(
          child: _AdaptiveHudPanelBody(
            profile: profile,
            model: model,
            stateTitle: stateTitle,
            stateMessage: stateMessage,
            showStateShell: showStateShell,
          ),
        );
        if (fillParent) {
          return SizedBox.expand(child: child);
        }
        if (matchParentWidth && constraints.maxWidth.isFinite) {
          return AspectRatio(
            aspectRatio: profile.preferredAspectRatio,
            child: child,
          );
        }
        final targetWidth = constraints.maxWidth.isFinite
            ? math.min(constraints.maxWidth, profile.maxWidth)
            : profile.maxWidth;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: targetWidth),
          child: AspectRatio(
            aspectRatio: profile.preferredAspectRatio,
            child: child,
          ),
        );
      },
    );
  }
}

class _AdaptiveHudPanelBody extends StatelessWidget {
  final HudLayoutProfile profile;
  final HudAdaptiveDisplayModel model;
  final String? stateTitle;
  final String? stateMessage;
  final bool showStateShell;

  const _AdaptiveHudPanelBody({
    required this.profile,
    required this.model,
    required this.stateTitle,
    required this.stateMessage,
    required this.showStateShell,
  });

  @override
  Widget build(BuildContext context) {
    const backgroundTop = Color(0xFF0C1220);
    const backgroundBottom = Color(0xFF05080F);
    final isOverlay = profile.surface == HudSurfaceVariant.driveOverlay;
    final borderColor = Colors.white.withValues(
      alpha: isOverlay ? 0.12 : 0.18,
    );
    final decoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isOverlay
            ? <Color>[
                const Color(0xC20A1018),
                const Color(0xB8060A11),
              ]
            : <Color>[
                backgroundTop,
                const Color(0xFF08111D),
                backgroundBottom,
              ],
      ),
      borderRadius: BorderRadius.circular(profile.borderRadius),
      border: Border.all(color: borderColor, width: 1.1),
      boxShadow: isOverlay
          ? const <BoxShadow>[]
          : const <BoxShadow>[
              BoxShadow(
                color: Color(0x30000000),
                blurRadius: 18,
                offset: Offset(0, 10),
              ),
            ],
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(profile.borderRadius),
      child: DecoratedBox(
        decoration: decoration,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Colors.white.withValues(alpha: 0.05),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: profile.padding,
              child: showStateShell ? _buildStateLayout() : _buildSurfaceLayout(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSurfaceLayout() {
    switch (profile.surface) {
      case HudSurfaceVariant.driveOverlay:
        return _buildDriveOverlayLayout();
      case HudSurfaceVariant.driveInline:
        return _buildDriveInlineLayout();
      case HudSurfaceVariant.preview:
      case HudSurfaceVariant.homePreview:
        return _buildHomePreviewLayout();
    }
  }

  Widget _buildStateLayout() {
    final title = (stateTitle ?? '').trim().isEmpty ? 'HUD 대기' : stateTitle!.trim();
    final message = (stateMessage ?? '').trim().isEmpty
        ? '의미 데이터 수신 전입니다.'
        : stateMessage!.trim();
    final compact = profile.density == HudDensityClass.micro ||
        profile.density == HudDensityClass.compact;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AdaptiveHudStatusDot(
            color: const Color(0xFF5BD7FF),
            size: compact ? 14 : 16,
          ),
          SizedBox(height: compact ? 10 : 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: profile.secondaryValueFontSize,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
          SizedBox(height: compact ? 6 : 8),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: profile.maxWidth * (compact ? 0.78 : 0.68),
            ),
            child: Text(
              message,
              textAlign: TextAlign.center,
              maxLines: compact ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white60,
                fontSize: profile.labelFontSize + 0.4,
                fontWeight: FontWeight.w600,
                height: 1.24,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomePreviewLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (profile.showTopStatusRow) ...<Widget>[
          _buildTopStatusRow(),
          SizedBox(height: profile.sectionGap),
        ],
        if (profile.showMetrics && model.showDeviceMetrics) ...<Widget>[
          _buildMetricRow(),
          SizedBox(height: profile.sectionGap),
        ],
        Expanded(
          child: profile.useThreeColumnMainRow
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(flex: 5, child: _buildHomePrimaryColumn()),
                    SizedBox(width: profile.sectionGap),
                    Expanded(flex: 4, child: _buildHomeSupportColumn()),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(flex: 5, child: _buildHomePrimaryColumn()),
                    SizedBox(height: profile.sectionGap),
                    Expanded(flex: 4, child: _buildHomeSupportColumn()),
                  ],
                ),
        ),
        if (profile.showFooterDetails) ...<Widget>[
          SizedBox(height: profile.sectionGap),
          _buildFooter(),
        ],
      ],
    );
  }

  Widget _buildDriveInlineLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (profile.showTopStatusRow) ...<Widget>[
          _buildTopStatusRow(),
          SizedBox(height: profile.sectionGap),
        ],
        if (profile.showMetrics && model.showDeviceMetrics) ...<Widget>[
          _buildMetricRow(),
          SizedBox(height: profile.sectionGap),
        ],
        Expanded(
          child: profile.useThreeColumnMainRow
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(flex: 5, child: _buildDriveInlinePrimaryColumn()),
                    SizedBox(width: profile.sectionGap),
                    Expanded(flex: 4, child: _buildDriveInlineSupportColumn()),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(flex: 5, child: _buildDriveInlinePrimaryColumn()),
                    SizedBox(height: profile.sectionGap),
                    Expanded(flex: 4, child: _buildDriveInlineSupportColumn()),
                  ],
                ),
        ),
        SizedBox(height: profile.sectionGap),
        _buildDriveInlineFooter(),
      ],
    );
  }

  Widget _buildDriveOverlayLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildTopStatusRow(),
        SizedBox(height: profile.sectionGap * 0.85),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(flex: 5, child: _buildOverlaySpeedCluster()),
              SizedBox(width: profile.sectionGap * 0.85),
              Expanded(flex: 4, child: _buildOverlayCenterColumn()),
              SizedBox(width: profile.sectionGap * 0.85),
              Expanded(flex: 2, child: _buildOverlayRightRail()),
            ],
          ),
        ),
        SizedBox(height: profile.sectionGap * 0.7),
        _buildOverlayMetaRow(),
      ],
    );
  }

  Widget _buildTopStatusRow() {
    return Row(
      children: <Widget>[
        AdaptiveHudStatusDot(
          color: model.redDot ? const Color(0xFFFF4D4D) : _signalColor(),
          size: profile.labelFontSize + 5,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            model.driveModeText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.88),
              fontSize: profile.labelFontSize + 1,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        AdaptiveHudInfoPill(
          label: model.sourceText,
          color: const Color(0xFF7AA7FF),
          profile: profile,
        ),
        if (model.showCompatibilityHint) ...<Widget>[
          const SizedBox(width: 8),
          Flexible(
            child: AdaptiveHudInfoPill(
              label: model.compatibilityHint,
              color: const Color(0xFFFFB347),
              profile: profile,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMetricRow() {
    return Row(
      children: <Widget>[
        Expanded(
          child: AdaptiveHudMetricTile(
            label: 'CPU',
            value: model.cpuText,
            profile: profile,
            accent: const Color(0xFF4EDC87),
          ),
        ),
        SizedBox(width: profile.metricGap),
        Expanded(
          child: AdaptiveHudMetricTile(
            label: 'MEM',
            value: model.memText,
            profile: profile,
            accent: const Color(0xFF4FA7FF),
          ),
        ),
        SizedBox(width: profile.metricGap),
        Expanded(
          child: AdaptiveHudMetricTile(
            label: model.auxMetricLabel,
            value: model.auxMetricText,
            profile: profile,
            accent: const Color(0xFFFFBF47),
          ),
        ),
      ],
    );
  }

  Widget _buildSpeedCluster() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(profile.borderRadius - 8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Padding(
        padding: EdgeInsets.all(profile.padding.left * 0.82),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  model.gpsText,
                  style: TextStyle(
                    color: model.hasGpsFix
                        ? const Color(0xFF7BE495)
                        : Colors.white54,
                    fontSize: profile.labelFontSize,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.45,
                  ),
                ),
                const Spacer(),
                AdaptiveHudActiveChip(
                  label: 'LON',
                  active: model.longActive,
                  profile: profile,
                ),
                const SizedBox(width: 6),
                AdaptiveHudActiveChip(
                  label: 'LAT',
                  active: model.latActive,
                  profile: profile,
                ),
              ],
            ),
            const Spacer(),
            Text(
              model.speedText,
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.speedFontSize,
                height: 0.88,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.2,
              ),
            ),
            SizedBox(height: profile.metricGap),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  'SET',
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: profile.labelFontSize,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  model.setSpeedText,
                  style: TextStyle(
                    color: const Color(0xFF83F28F),
                    fontSize: profile.primaryValueFontSize,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomePrimaryColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: _buildSpeedCluster()),
        SizedBox(height: profile.sectionGap),
        Row(
          children: <Widget>[
            Expanded(
              child: AdaptiveHudGapBars(
                count: model.gapBarCount,
                label: model.gapText,
                profile: profile,
              ),
            ),
            SizedBox(width: profile.sectionGap),
            AdaptiveHudStatusBand(
              label: 'SIG',
              value: model.signalState.toUpperCase(),
              color: _signalColor(),
              profile: profile,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHomeSupportColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: _buildCenterColumn()),
              SizedBox(width: profile.sectionGap),
              SizedBox(width: profile.maxWidth * 0.16, child: _buildRightRail()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDriveInlinePrimaryColumn() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(flex: 5, child: _buildSpeedCluster()),
        SizedBox(width: profile.sectionGap),
        Expanded(
          flex: 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(profile.borderRadius - 10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Padding(
              padding: EdgeInsets.all(profile.padding.left * 0.7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: Center(
                      child: Text(
                        model.gearText,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: profile.gearFontSize,
                          fontWeight: FontWeight.w800,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: profile.sectionGap * 0.8),
                  AdaptiveHudGapBars(
                    count: model.gapBarCount,
                    label: model.gapText,
                    profile: profile,
                    compact: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDriveInlineSupportColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: AdaptiveHudTempCard(
                  label: model.tempLabel,
                  value: model.tempSpeedText,
                  profile: profile,
                  accent: model.tempIsDecel
                      ? const Color(0xFFFFB347)
                      : const Color(0xFF4EF28B),
                ),
              ),
              SizedBox(width: profile.sectionGap),
              SizedBox(
                width: math.max(74, profile.maxWidth * 0.13),
                child: AdaptiveHudStatusBand(
                  label: 'SIG',
                  value: model.signalState.toUpperCase(),
                  color: _signalColor(),
                  profile: profile,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: profile.sectionGap),
        AdaptiveHudModeStripe(
          label: model.driveModeText,
          kind: model.driveModeKind,
          profile: profile,
        ),
        SizedBox(height: profile.sectionGap),
        Row(
          children: <Widget>[
            Expanded(
              child: AdaptiveHudInfoPill(
                label: '${model.limitLabel} ${model.limitValueText}',
                color: model.limitCritical
                    ? const Color(0xFFFF6357)
                    : const Color(0xFFFFD15A),
                profile: profile,
                blinking: model.limitBlink,
              ),
            ),
            if (model.showConnectivity) ...<Widget>[
              SizedBox(width: profile.sectionGap * 0.7),
              Flexible(
                child: AdaptiveHudInfoPill(
                  label: model.connectivityText,
                  color: const Color(0xFF5BD7FF),
                  profile: profile,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildOverlaySpeedCluster() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              model.gpsText,
              style: TextStyle(
                color: model.hasGpsFix
                    ? const Color(0xFF7BE495)
                    : Colors.white54,
                fontSize: profile.labelFontSize,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.45,
              ),
            ),
            const Spacer(),
            AdaptiveHudActiveChip(
              label: 'LON',
              active: model.longActive,
              profile: profile,
            ),
            const SizedBox(width: 6),
            AdaptiveHudActiveChip(
              label: 'LAT',
              active: model.latActive,
              profile: profile,
            ),
          ],
        ),
        const Spacer(),
        Text(
          model.speedText,
          style: TextStyle(
            color: Colors.white,
            fontSize: profile.speedFontSize,
            height: 0.86,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.3,
          ),
        ),
        SizedBox(height: profile.metricGap * 0.7),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Text(
              'SET',
              style: TextStyle(
                color: Colors.white60,
                fontSize: profile.labelFontSize,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.35,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              model.setSpeedText,
              style: TextStyle(
                color: const Color(0xFF83F28F),
                fontSize: profile.primaryValueFontSize,
                fontWeight: FontWeight.w800,
                height: 1.0,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCenterColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: AdaptiveHudTempCard(
            label: model.tempLabel,
            value: model.tempSpeedText,
            profile: profile,
            accent: model.tempIsDecel
                ? const Color(0xFFFFB347)
                : const Color(0xFF4EF28B),
          ),
        ),
        SizedBox(height: profile.sectionGap),
        AdaptiveHudModeStripe(
          label: model.driveModeText,
          kind: model.driveModeKind,
          profile: profile,
        ),
        SizedBox(height: profile.sectionGap),
        Row(
          children: <Widget>[
            Expanded(
              child: AdaptiveHudInfoPill(
                label: '${model.limitLabel} ${model.limitValueText}',
                color: model.limitCritical
                    ? const Color(0xFFFF6357)
                    : const Color(0xFFFFD15A),
                profile: profile,
                blinking: model.limitBlink,
              ),
            ),
            if (model.showConnectivity) ...<Widget>[
              const SizedBox(width: 8),
              AdaptiveHudInfoPill(
                label: model.connectivityText,
                color: const Color(0xFF5BD7FF),
                profile: profile,
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildOverlayCenterColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: AdaptiveHudTempCard(
            label: model.tempLabel,
            value: model.tempSpeedText,
            profile: profile,
            accent: model.tempIsDecel
                ? const Color(0xFFFFB347)
                : const Color(0xFF4EF28B),
          ),
        ),
        SizedBox(height: profile.sectionGap * 0.75),
        AdaptiveHudModeStripe(
          label: model.driveModeText,
          kind: model.driveModeKind,
          profile: profile,
        ),
        SizedBox(height: profile.sectionGap * 0.75),
        AdaptiveHudInfoPill(
          label: '${model.limitLabel} ${model.limitValueText}',
          color: model.limitCritical
              ? const Color(0xFFFF6357)
              : const Color(0xFFFFD15A),
          profile: profile,
          blinking: model.limitBlink,
        ),
      ],
    );
  }

  Widget _buildRightRail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(profile.borderRadius - 10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
            ),
            child: Center(
              child: Text(
                model.gearText,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: profile.gearFontSize,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: profile.sectionGap),
        AdaptiveHudGapBars(
          count: model.gapBarCount,
          label: model.gapText,
          profile: profile,
        ),
        SizedBox(height: profile.sectionGap),
        AdaptiveHudStatusBand(
          label: 'SIG',
          value: model.signalState.toUpperCase(),
          color: _signalColor(),
          profile: profile,
        ),
      ],
    );
  }

  Widget _buildOverlayRightRail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Center(
            child: Text(
              model.gearText,
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.gearFontSize,
                fontWeight: FontWeight.w800,
                height: 1.0,
              ),
            ),
          ),
        ),
        SizedBox(height: profile.sectionGap * 0.7),
        AdaptiveHudGapBars(
          count: model.gapBarCount,
          label: model.gapText,
          profile: profile,
          compact: true,
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Row(
      children: <Widget>[
        Text(
          model.qualityText,
          style: TextStyle(
            color: Colors.white38,
            fontSize: profile.chipFontSize,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.35,
          ),
        ),
        if (model.hostText.isNotEmpty) ...<Widget>[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              model.hostText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white30,
                fontSize: profile.chipFontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        const Spacer(),
        if (model.showCompatibilityHint) ...<Widget>[
          Text(
            model.compatibilityHint,
            style: TextStyle(
              color: const Color(0xFFFFBF75),
              fontSize: profile.chipFontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
        ],
        Text(
          'gap ${model.gapText}',
          style: TextStyle(
            color: Colors.white54,
            fontSize: profile.chipFontSize,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          model.tsMonoMs > 0 ? '#${model.tsMonoMs}' : '--',
          style: TextStyle(
            color: Colors.white24,
            fontSize: profile.chipFontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildOverlayMetaRow() {
    return Row(
      children: <Widget>[
        if (model.showConnectivity) ...<Widget>[
          Flexible(
            child: AdaptiveHudInfoPill(
              label: model.connectivityText,
              color: const Color(0xFF5BD7FF),
              profile: profile,
            ),
          ),
          const SizedBox(width: 8),
        ],
        Text(
          model.qualityText,
          style: TextStyle(
            color: Colors.white38,
            fontSize: profile.chipFontSize,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.35,
          ),
        ),
        if (model.hostText.isNotEmpty) ...<Widget>[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              model.hostText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white30,
                fontSize: profile.chipFontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ] else
          const Spacer(),
        if (model.showCompatibilityHint) ...<Widget>[
          const SizedBox(width: 8),
          Text(
            model.compatibilityHint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: const Color(0xFFFFBF75),
              fontSize: profile.chipFontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDriveInlineFooter() {
    return Row(
      children: <Widget>[
        Text(
          model.qualityText,
          style: TextStyle(
            color: Colors.white38,
            fontSize: profile.chipFontSize,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.35,
          ),
        ),
        if (model.hostText.isNotEmpty) ...<Widget>[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              model.hostText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white30,
                fontSize: profile.chipFontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ] else
          const Spacer(),
        if (model.showCompatibilityHint) ...<Widget>[
          const SizedBox(width: 8),
          Text(
            model.compatibilityHint,
            style: TextStyle(
              color: const Color(0xFFFFBF75),
              fontSize: profile.chipFontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }

  Color _signalColor() {
    switch (model.signalState) {
      case 'red':
        return const Color(0xFFFF5252);
      case 'green':
        return const Color(0xFF41E077);
      default:
        return Colors.white24;
    }
  }
}
