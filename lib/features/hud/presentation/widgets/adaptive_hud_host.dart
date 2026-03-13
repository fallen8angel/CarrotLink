import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../services/native_overlay_hud_service.dart';
import '../../../../services/ssh_service.dart';
import '../../application/hud_controller_state.dart';
import '../../application/hud_runtime_manager.dart';
import '../../domain/entities/original_hud_snapshot.dart';
import '../models/hud_layout_profile.dart';
import 'adaptive_hud_panel.dart';
import 'hud_controller_builder.dart';

class AdaptiveHudHost extends StatelessWidget {
  final String? deviceIp;
  final bool enabled;
  final bool fillParent;
  final bool edgeToEdge;
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
    this.edgeToEdge = false,
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
        edgeToEdge: edgeToEdge,
        matchParentWidth: matchParentWidth,
        preferStateShell: false,
      );
    }

    final runtime = preview ? null : _resolveRuntimeManager(context);
    if (runtime != null) {
      return AnimatedBuilder(
        animation: runtime,
        builder: (context, _) {
          final controller = runtime.controller;
          if (controller == null) {
            return AdaptiveHudPanel(
              snapshot: OriginalHudSnapshot.empty,
              surface: surface,
              fillParent: fillParent,
              edgeToEdge: edgeToEdge,
              matchParentWidth: matchParentWidth,
              preferStateShell: false,
            );
          }
          return AnimatedBuilder(
            animation: controller,
            builder: (context, __) {
              final state = controller.state;
              final snapshot = state.snapshot;
              final viewState = _HudHostViewState.fromControllerState(
                state,
                preview: preview,
              );
              return _HudSnapshotCallbackBridge(
                snapshot: snapshot,
                fallbackHost: resolvedHost,
                syncNativeOverlay: syncNativeOverlay,
                onSnapshot: onSnapshot,
                child: AdaptiveHudPanel(
                  snapshot: snapshot,
                  surface: surface,
                  fillParent: fillParent,
                  edgeToEdge: edgeToEdge,
                  matchParentWidth: matchParentWidth,
                  preferStateShell: viewState.preferStateShell,
                ),
              );
            },
          );
        },
      );
    }

    return HudControllerBuilder(
      host: resolvedHost,
      clientRole: _resolveClientRole(surface),
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
          fallbackHost: resolvedHost,
          syncNativeOverlay: syncNativeOverlay,
          onSnapshot: onSnapshot,
          child: AdaptiveHudPanel(
            snapshot: snapshot,
            surface: surface,
            fillParent: fillParent,
            edgeToEdge: edgeToEdge,
            matchParentWidth: matchParentWidth,
            preferStateShell: viewState.preferStateShell,
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

  SharedRuntimeManager? _resolveRuntimeManager(BuildContext context) {
    try {
      return Provider.of<SharedRuntimeManager>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  String _resolveClientRole(HudSurfaceVariant surface) {
    // In-app HUD should share one transport session per host. Surface differences
    // are purely presentational; splitting transport by home/drive made HUD feel
    // like it was constantly reinitializing on tab/route changes.
    return 'app_hud';
  }
}

class _HudHostViewState {
  final bool preferStateShell;

  const _HudHostViewState({
    required this.preferStateShell,
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
      return const _HudHostViewState(preferStateShell: false);
    }
    if (state.lastError != null) {
      return const _HudHostViewState(preferStateShell: false);
    }
    return const _HudHostViewState(preferStateShell: false);
  }
}

class _HudSnapshotCallbackBridge extends StatefulWidget {
  final OriginalHudSnapshot snapshot;
  final String? fallbackHost;
  final bool syncNativeOverlay;
  final ValueChanged<OriginalHudSnapshot>? onSnapshot;
  final Widget child;

  const _HudSnapshotCallbackBridge({
    required this.snapshot,
    required this.fallbackHost,
    required this.syncNativeOverlay,
    required this.onSnapshot,
    required this.child,
  });

  @override
  State<_HudSnapshotCallbackBridge> createState() =>
      _HudSnapshotCallbackBridgeState();
}

class _HudSnapshotCallbackBridgeState extends State<_HudSnapshotCallbackBridge>
    with WidgetsBindingObserver {
  int _lastDeliveredTs = -1;
  int _lastOverlayPushEpochMs = 0;
  bool _overlayLifecycleBusy = false;
  AppLifecycleState? _lastLifecycleState;
  int _lastLifecycleSyncEpochMs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleCallbackIfNeeded();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HudSnapshotCallbackBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleCallbackIfNeeded();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!widget.syncNativeOverlay) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_lastLifecycleState == state &&
        nowMs - _lastLifecycleSyncEpochMs < 250) {
      return;
    }
    _lastLifecycleState = state;
    _lastLifecycleSyncEpochMs = nowMs;
    unawaited(_syncOverlayForLifecycle(state));
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

  Future<void> _syncOverlayForLifecycle(AppLifecycleState state) async {
    if (!mounted) return;
    if (!NativeOverlayHudService.isSupported) return;
    if (_overlayLifecycleBusy) return;
    _overlayLifecycleBusy = true;
    try {
      if (state == AppLifecycleState.resumed) {
        final running = await NativeOverlayHudService.isRunning();
        if (running) {
          await NativeOverlayHudService.stop();
        }
        return;
      }
      if (state != AppLifecycleState.paused &&
          state != AppLifecycleState.inactive) {
        return;
      }
      final hasPermission = await NativeOverlayHudService.hasPermission();
      if (!hasPermission) return;
      final host = NativeOverlayHudService.normalizeHost(
            widget.snapshot.source.deviceHost,
          ) ??
          NativeOverlayHudService.normalizeHost(widget.fallbackHost);
      if (host == null) return;
      final running = await NativeOverlayHudService.isRunning();
      if (running) {
        await NativeOverlayHudService.updateEndpoint(host);
      } else {
        await NativeOverlayHudService.start(host);
      }
    } finally {
      _overlayLifecycleBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
