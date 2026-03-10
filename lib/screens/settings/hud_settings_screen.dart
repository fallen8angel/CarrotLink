import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/hud_drive_settings_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/custom_toast.dart';

class HudSettingsScreen extends StatefulWidget {
  const HudSettingsScreen({super.key});

  @override
  State<HudSettingsScreen> createState() => _HudSettingsScreenState();
}

class _HudSettingsScreenState extends State<HudSettingsScreen> {
  bool _loading = true;
  String _defaultDriveMode = HudDriveSettingsService.modeWebrtc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final defaultDriveMode = await HudDriveSettingsService.getDefaultMode();
    if (!mounted) return;
    setState(() {
      _defaultDriveMode = defaultDriveMode;
      _loading = false;
    });
  }

  Future<void> _changeDefaultMode(String value) async {
    if (value == _defaultDriveMode) return;
    await HudDriveSettingsService.setDefaultMode(value);
    if (!mounted) return;
    setState(() => _defaultDriveMode = value);
    final label = _modeLabel(value);
    CustomToast.show(context, 'HUD 기본 모드를 $label(으)로 설정했습니다.');
  }

  String _modeLabel(String value) {
    return value == HudDriveSettingsService.modeOpenpilotOverlay
        ? 'Stock'
        : 'WebRTC';
  }

  Widget _buildCompactModeButton({
    required BuildContext context,
    required ColorScheme scheme,
    required String value,
  }) {
    final selected = _defaultDriveMode == value;
    return Expanded(
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => unawaited(_changeDefaultMode(value)),
          child: Ink(
            decoration: ShapeDecoration(
              color: selected ? scheme.primaryContainer : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: BorderSide(
                  color: selected
                      ? scheme.primary.withValues(alpha: 0.55)
                      : scheme.outlineVariant,
                  width: selected ? 1.4 : 1.0,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
              child: Text(
                _modeLabel(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? scheme.onPrimaryContainer
                          : scheme.onSurface,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('HUD')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.only(
                left: tokens.screenPadding.clamp(12.0, 24.0).toDouble(),
                right: tokens.screenPadding.clamp(12.0, 24.0).toDouble(),
                top: 14.0,
                bottom: tokens.footerSpacer,
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.tune,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '사이드카 기본 진입 모드',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact =
                          window.isCompact || constraints.maxWidth < 520;
                      if (!compact) {
                        return SegmentedButton<String>(
                          segments: const <ButtonSegment<String>>[
                            ButtonSegment<String>(
                              value: HudDriveSettingsService.modeWebrtc,
                              label: Text('WebRTC'),
                            ),
                            ButtonSegment<String>(
                              value:
                                  HudDriveSettingsService.modeOpenpilotOverlay,
                              label: Text('Stock'),
                            ),
                          ],
                          selected: <String>{_defaultDriveMode},
                          onSelectionChanged: (selected) {
                            if (selected.isEmpty) return;
                            unawaited(_changeDefaultMode(selected.first));
                          },
                        );
                      }

                      return Row(
                        children: [
                          _buildCompactModeButton(
                            context: context,
                            scheme: scheme,
                            value: HudDriveSettingsService.modeWebrtc,
                          ),
                          const SizedBox(width: 12),
                          _buildCompactModeButton(
                            context: context,
                            scheme: scheme,
                            value: HudDriveSettingsService.modeOpenpilotOverlay,
                          ),
                        ],
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Text(
                    'WebRTC: 카메라만 표시, Stock: 카메라 + 그래픽 오버레이',
                    style: TextStyle(
                      fontSize: window.isCompact ? 11.5 : 12.0,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
