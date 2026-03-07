import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../services/native_overlay_hud_service.dart';
import '../../../../services/ssh_service.dart';
import '../../application/hud_controller_state.dart';
import '../../domain/entities/original_hud_snapshot.dart';
import '../models/hud_layout_profile.dart';
import 'adaptive_hud_panel.dart';
import 'hud_controller_builder.dart';

class AdaptiveHudHost extends StatelessWidget {
  final String? deviceIp;
  final bool enabled;
  final bool fillParent;
  final bool matchParentWidth;
  final HudSurfaceVariant surface;
  final bool preview;
  final SSHService? sshService;
  final bool syncNativeOverlay;
  final ValueChanged<OriginalHudSnapshot>? onSnapshot;

  const AdaptiveHudHost({
    super.key,
    this.deviceIp,
    this.enabled = true,
    this.fillParent = false,
    this.matchParentWidth = false,
    this.surface = HudSurfaceVariant.homePreview,
    this.preview = false,
    this.sshService,
    this.syncNativeOverlay = false,
    this.onSnapshot,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedHost = _normalizeIp(deviceIp);
    if (!enabled || (!preview && resolvedHost == null)) {
      return AdaptiveHudPanel(
        snapshot: OriginalHudSnapshot.empty,
        surface: surface,
        fillParent: fillParent,
        matchParentWidth: matchParentWidth,
        preferStateShell: true,
        stateTitle: 'HUD 대기',
        stateMessage: preview ? '미리보기 준비 중입니다.' : '기기 연결 후 HUD를 표시합니다.',
      );
    }

    return HudControllerBuilder(
      host: resolvedHost,
      preview: preview,
      sshService: _resolveSshService(context),
      builder: (context, controller, state) {
        final snapshot = state.snapshot;
        final viewState = _HudHostViewState.fromControllerState(
          state,
          preview: preview,
        );
        return _HudSnapshotCallbackBridge(
          snapshot: snapshot,
          syncNativeOverlay: syncNativeOverlay,
          onSnapshot: onSnapshot,
          child: AdaptiveHudPanel(
            snapshot: snapshot,
            surface: surface,
            fillParent: fillParent,
            matchParentWidth: matchParentWidth,
            preferStateShell: viewState.preferStateShell,
            stateTitle: viewState.title,
            stateMessage: viewState.message,
          ),
        );
      },
    );
  }

  SSHService? _resolveSshService(BuildContext context) {
    if (sshService != null) {
      return sshService;
    }
    try {
      return Provider.of<SSHService>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  String? _normalizeIp(String? raw) {
    if (raw == null) return null;
    final ip = raw.trim();
    if (ip.isEmpty) return null;
    final ipv4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
    if (!ipv4.hasMatch(ip)) return null;
    return ip;
  }
}

class _HudHostViewState {
  final bool preferStateShell;
  final String? title;
  final String? message;

  const _HudHostViewState({
    required this.preferStateShell,
    this.title,
    this.message,
  });

  factory _HudHostViewState.fromControllerState(
    HudControllerState state, {
    required bool preview,
  }) {
    final hasSnapshot = state.snapshot.tsMonoMs > 0;
    if (hasSnapshot) {
      return const _HudHostViewState(preferStateShell: false);
    }
    if (state.isLoading == true) {
      return _HudHostViewState(
        preferStateShell: true,
        title: preview ? 'HUD 미리보기' : 'HUD 연결 중',
        message: preview
            ? '미리보기 샘플을 준비하는 중입니다.'
            : '콤마 HUD 의미 데이터를 수신하는 중입니다.',
      );
    }
    if (state.lastError != null) {
      return _HudHostViewState(
        preferStateShell: true,
        title: 'HUD 연결 실패',
        message: '${state.host ?? '기기'}에서 HUD 데이터를 불러오지 못했습니다.',
      );
    }
    return _HudHostViewState(
      preferStateShell: true,
      title: preview ? 'HUD 미리보기' : 'HUD 대기',
      message: preview
          ? '미리보기 데이터 대기 중입니다.'
          : 'HUD 의미 데이터가 아직 도착하지 않았습니다.',
    );
  }
}

class _HudSnapshotCallbackBridge extends StatefulWidget {
  final OriginalHudSnapshot snapshot;
  final bool syncNativeOverlay;
  final ValueChanged<OriginalHudSnapshot>? onSnapshot;
  final Widget child;

  const _HudSnapshotCallbackBridge({
    required this.snapshot,
    required this.syncNativeOverlay,
    required this.onSnapshot,
    required this.child,
  });

  @override
  State<_HudSnapshotCallbackBridge> createState() =>
      _HudSnapshotCallbackBridgeState();
}

class _HudSnapshotCallbackBridgeState extends State<_HudSnapshotCallbackBridge> {
  int _lastDeliveredTs = -1;
  int _lastOverlayPushEpochMs = 0;

  @override
  void initState() {
    super.initState();
    _scheduleCallbackIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _HudSnapshotCallbackBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleCallbackIfNeeded();
  }

  void _scheduleCallbackIfNeeded() {
    final callback = widget.onSnapshot;
    final syncNativeOverlay = widget.syncNativeOverlay;
    if (callback == null && !syncNativeOverlay) return;
    final ts = widget.snapshot.tsMonoMs;
    if (ts <= 0 || ts == _lastDeliveredTs) return;
    _lastDeliveredTs = ts;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (callback != null) {
        callback(widget.snapshot);
      }
      if (syncNativeOverlay) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - _lastOverlayPushEpochMs >= 140) {
          _lastOverlayPushEpochMs = nowMs;
          unawaited(
            NativeOverlayHudService.updateSemanticSnapshot(widget.snapshot),
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
