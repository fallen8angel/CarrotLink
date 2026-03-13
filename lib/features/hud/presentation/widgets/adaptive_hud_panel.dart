import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/entities/original_hud_snapshot.dart';
import '../models/hud_adaptive_display_model.dart';
import '../models/hud_layout_profile.dart';
import 'adaptive_hud_drive_inline_sections.dart';
import 'adaptive_hud_home_sections.dart';
import 'adaptive_hud_primitives.dart';
import 'adaptive_hud_drive_overlay_sections.dart';
import 'adaptive_hud_drive_inline_surface.dart';
import 'adaptive_hud_drive_overlay_surface.dart';
import 'adaptive_hud_home_preview_surface.dart';

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
        final dockedChild = Padding(
          padding: EdgeInsets.all(profile.dockInset),
          child: child,
        );
        if (fillParent) {
          return SizedBox.expand(child: dockedChild);
        }
        if (matchParentWidth && constraints.maxWidth.isFinite) {
          return AspectRatio(
            aspectRatio: profile.preferredAspectRatio,
            child: dockedChild,
          );
        }
        final targetWidth = constraints.maxWidth.isFinite
            ? math.min(constraints.maxWidth, profile.maxWidth)
            : profile.maxWidth;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: targetWidth),
          child: AspectRatio(
            aspectRatio: profile.preferredAspectRatio,
            child: dockedChild,
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
    const backgroundTop = Color(0xFF0D3826);
    const backgroundBottom = Color(0xFF081F15);
    final isOverlay = profile.surface == HudSurfaceVariant.driveOverlay;
    final borderColor = model.cameraAlertBlinkOn
        ? const Color(0xFFFF6961).withValues(alpha: isOverlay ? 0.46 : 0.58)
        : Colors.white.withValues(
            alpha: isOverlay ? 0.12 : 0.18,
          );
    final decoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isOverlay
            ? <Color>[
                const Color(0xDD11442E),
                const Color(0xCC0A281B),
              ]
            : <Color>[
                backgroundTop,
                const Color(0xFF12412C),
                backgroundBottom,
              ],
      ),
      borderRadius: BorderRadius.circular(profile.borderRadius),
      border: Border.all(color: borderColor, width: 1.1),
      boxShadow: isOverlay
          ? const <BoxShadow>[]
          : const <BoxShadow>[
              BoxShadow(
                color: Color(0x8A000000),
                blurRadius: 20,
                offset: Offset(0, 12),
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
                      Colors.white.withValues(alpha: 0.01),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  opacity: model.cameraAlertBlinkOn ? 1.0 : 0.0,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          Color(0xC8A81919),
                          Color(0x8EFF5C57),
                          Color(0x660A0404),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: profile.padding,
              child:
                  showStateShell ? _buildStateLayout() : _buildSurfaceLayout(),
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
    final title = (stateTitle ?? '').trim();
    final message = (stateMessage ?? '').trim();
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
          if (title.isNotEmpty) ...<Widget>[
            SizedBox(height: compact ? 10 : 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: profile.secondaryValueFontSize + 1.0,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
          ],
          if (message.isNotEmpty) ...<Widget>[
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
                  fontSize: profile.labelFontSize + 1.0,
                  fontWeight: FontWeight.w700,
                  height: 1.24,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHomePreviewLayout() {
    final qualityLabel = _qualityMetaLabel();
    final compatibilityLabel = _compatibilityMetaLabel();
    final showHost = _showHostMetaLabel();
    return AdaptiveHudHomePreviewSurface(
      profile: profile,
      showMetrics: false,
      showDeviceMetrics: model.showDeviceMetrics,
      topStatusRow: _buildTopStatusRow(),
      metricRow: _buildMetricRow(),
      primaryColumn: AdaptiveHudHomePrimarySection(
        profile: profile,
        model: model,
        speedCluster: _buildSpeedCluster(),
      ),
      supportColumn: AdaptiveHudHomeSupportSection(
        profile: profile,
        model: model,
      ),
      footer: AdaptiveHudHomeFooter(
        profile: profile,
        model: model,
        qualityLabel: qualityLabel,
        compatibilityLabel: compatibilityLabel,
        showHost: showHost,
      ),
    );
  }

  Widget _buildDriveInlineLayout() {
    final qualityLabel = _qualityMetaLabel();
    final compatibilityLabel = _compatibilityMetaLabel(
      compact: profile.density == HudDensityClass.micro,
    );
    final showHost = _showHostMetaLabel();
    return AdaptiveHudDriveInlineSurface(
      profile: profile,
      showMetrics: false,
      showDeviceMetrics: model.showDeviceMetrics,
      topStatusRow: _buildTopStatusRow(),
      metricRow: _buildMetricRow(),
      primaryColumn: AdaptiveHudDriveInlinePrimarySection(
        profile: profile,
        model: model,
      ),
      supportColumn: AdaptiveHudDriveInlineSupportSection(
        profile: profile,
        model: model,
      ),
      footer: AdaptiveHudDriveInlineFooter(
        profile: profile,
        model: model,
        qualityLabel: qualityLabel,
        compatibilityLabel: compatibilityLabel,
        showHost: showHost,
      ),
    );
  }

  Widget _buildDriveOverlayLayout() {
    final compactMeta = _useCompactMetaPolicy();
    return AdaptiveHudDriveOverlaySurface(
      profile: profile,
      showMetrics: false,
      showDeviceMetrics: model.showDeviceMetrics,
      topStatusRow: _buildTopStatusRow(),
      metricRow: _buildMetricRow(),
      leftColumn: AdaptiveHudLeftClusterColumn(
        speedCluster: AdaptiveHudDriveOverlaySpeedCluster(
          profile: profile,
          model: model,
        ),
        model: model,
        profile: profile,
      ),
      rightColumn: AdaptiveHudRightClusterColumn(
        model: model,
        profile: profile,
      ),
      metaRow: AdaptiveHudDriveOverlayMetaRow(
        profile: profile,
        model: model,
        qualityLabel: _qualityMetaLabel(),
        compatibilityLabel: _compatibilityMetaLabel(compact: compactMeta),
        showHost: _showOverlayHostMeta(),
      ),
    );
  }

  Widget _buildTopStatusRow() {
    return AdaptiveHudTopMetricBar(
      model: model,
      profile: profile,
    );
  }

  Widget _buildMetricRow() {
    return const SizedBox.shrink();
  }

  Widget _buildSpeedCluster() {
    final integratedHomePreview =
        profile.surface == HudSurfaceVariant.homePreview;
    final content = Padding(
      padding: integratedHomePreview
          ? EdgeInsets.fromLTRB(
              profile.padding.left * 0.22,
              profile.padding.top * 0.12,
              profile.padding.right * 0.18,
              profile.padding.bottom * 0.10,
            )
          : EdgeInsets.all(profile.padding.left * 0.72),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '현재속도',
            style: TextStyle(
              color: integratedHomePreview
                  ? Colors.white.withValues(alpha: 0.54)
                  : Colors.white38,
              fontSize: profile.chipFontSize + 1.4,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.3,
            ),
          ),
          SizedBox(
              height:
                  profile.metricGap * (integratedHomePreview ? 0.08 : 0.12)),
          Expanded(
            child: Align(
              alignment: integratedHomePreview
                  ? Alignment.centerLeft
                  : Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  model.speedText,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: profile.speedFontSize +
                        (integratedHomePreview ? 14 : 10),
                    height: 0.84,
                    fontWeight: FontWeight.w900,
                    letterSpacing: integratedHomePreview ? -1.8 : -1.4,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (integratedHomePreview) {
      return content;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(profile.borderRadius - 8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: content,
    );
  }

  bool _useCompactMetaPolicy() {
    return profile.density == HudDensityClass.micro ||
        profile.density == HudDensityClass.compact;
  }

  bool _showHostMetaLabel() {
    if (model.hostText.isEmpty) return false;
    switch (profile.surface) {
      case HudSurfaceVariant.driveOverlay:
        return !_useCompactMetaPolicy() && model.isDegradedMeta;
      case HudSurfaceVariant.driveInline:
        return profile.density != HudDensityClass.micro &&
            (model.isDegradedMeta ||
                profile.density == HudDensityClass.spacious);
      case HudSurfaceVariant.preview:
      case HudSurfaceVariant.homePreview:
        return true;
    }
  }

  bool _showOverlayHostMeta() {
    return profile.surface == HudSurfaceVariant.driveOverlay &&
        _showHostMetaLabel();
  }

  String? _qualityMetaLabel() {
    final quality = model.qualityText.trim().toLowerCase();
    if (model.isPreview) return 'preview';
    if (!model.isDegradedMeta &&
        (quality.isEmpty || quality == 'live' || quality == 'semantic')) {
      return null;
    }
    if (quality.isEmpty || quality == 'live') {
      if (model.sourceText == 'COMPAT') return 'compat';
      if (model.sourceText == 'FALLBACK') return 'fallback';
      return 'degraded';
    }
    return quality;
  }

  String? _compatibilityMetaLabel({bool compact = false}) {
    if (!model.showCompatibilityHint) return null;
    if (compact) {
      return model.compatibilityBadgeText.isEmpty
          ? model.compatibilityHint
          : model.compatibilityBadgeText;
    }
    return model.compatibilityHint;
  }
}
