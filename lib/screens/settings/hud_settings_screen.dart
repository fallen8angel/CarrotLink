import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/hud_drive_settings_service.dart';
import '../../services/native_overlay_hud_service.dart';
import '../../widgets/custom_toast.dart';

class HudSettingsScreen extends StatefulWidget {
  const HudSettingsScreen({super.key});

  @override
  State<HudSettingsScreen> createState() => _HudSettingsScreenState();
}

class _HudSettingsScreenState extends State<HudSettingsScreen> {
  bool _loading = true;
  bool _enabled = true;
  bool _running = false;
  bool _hasPermission = false;
  String _defaultDriveMode = HudDriveSettingsService.modeWebrtc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await NativeOverlayHudService.isEnabled();
    final running = await NativeOverlayHudService.isRunning();
    final hasPermission = await NativeOverlayHudService.hasPermission();
    final defaultDriveMode = await HudDriveSettingsService.getDefaultMode();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _running = running;
      _hasPermission = hasPermission;
      _defaultDriveMode = defaultDriveMode;
      _loading = false;
    });
  }

  Future<void> _toggle(bool next) async {
    setState(() => _enabled = next);
    await NativeOverlayHudService.setEnabled(next);
    if (!next) {
      await NativeOverlayHudService.stop();
      if (mounted) {
        CustomToast.show(context, 'HUD 오버레이를 비활성화했습니다.');
      }
    } else {
      if (mounted) {
        CustomToast.show(context, 'HUD 오버레이를 활성화했습니다.');
      }
    }
    await _load();
  }

  Future<void> _requestPermission() async {
    await NativeOverlayHudService.requestPermission();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await _load();
  }

  Future<void> _changeDefaultMode(String value) async {
    if (value == _defaultDriveMode) return;
    await HudDriveSettingsService.setDefaultMode(value);
    if (!mounted) return;
    setState(() => _defaultDriveMode = value);
    final label = value == HudDriveSettingsService.modeOpenpilotOverlay
        ? '오픈파일럿 그래픽'
        : 'WebRTC';
    CustomToast.show(context, 'HUD 기본 모드를 $label(으)로 설정했습니다.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HUD')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile.adaptive(
                  value: _enabled,
                  onChanged: _toggle,
                  title: const Text('HUD 오버레이 사용'),
                  subtitle: const Text('앱이 백그라운드일 때 HUD 오버레이 표시'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    _hasPermission ? Icons.check_circle : Icons.warning_amber,
                    color: _hasPermission ? Colors.green : Colors.orange,
                  ),
                  title: const Text('다른 앱 위에 표시 권한'),
                  subtitle: Text(_hasPermission ? '허용됨' : '권한 필요'),
                  trailing: TextButton(
                    onPressed: _requestPermission,
                    child: const Text('권한 설정'),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    _running ? Icons.visibility : Icons.visibility_off,
                    color: _running ? Colors.green : Colors.grey,
                  ),
                  title: const Text('현재 오버레이 상태'),
                  subtitle: Text(_running ? '실행 중' : '중지됨'),
                  trailing: IconButton(
                    tooltip: '새로고침',
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Row(
                    children: [
                      const Icon(Icons.tune, size: 18, color: Colors.white70),
                      const SizedBox(width: 8),
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
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: SegmentedButton<String>(
                    segments: const <ButtonSegment<String>>[
                      ButtonSegment<String>(
                        value: HudDriveSettingsService.modeWebrtc,
                        label: Text('WebRTC'),
                      ),
                      ButtonSegment<String>(
                        value: HudDriveSettingsService.modeOpenpilotOverlay,
                        label: Text('오픈파일럿 그래픽'),
                      ),
                    ],
                    selected: <String>{_defaultDriveMode},
                    onSelectionChanged: (selected) {
                      if (selected.isEmpty) return;
                      unawaited(_changeDefaultMode(selected.first));
                    },
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'WebRTC: 카메라만 표시, 오픈파일럿 그래픽: 카메라 + 그래픽 오버레이',
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              ],
            ),
    );
  }
}
