import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../../services/link_hud_service.dart';
import '../../../../services/ssh_service.dart';
import '../../application/hud_controller.dart';
import '../../application/hud_controller_state.dart';
import '../../application/hud_module.dart';

typedef HudControllerViewBuilder = Widget Function(
  BuildContext context,
  HudController controller,
  HudControllerState state,
);

class HudControllerBuilder extends StatefulWidget {
  final String? host;
  final bool preview;
  final SSHService? sshService;
  final HudControllerViewBuilder builder;

  const HudControllerBuilder({
    super.key,
    this.host,
    this.preview = false,
    this.sshService,
    required this.builder,
  });

  @override
  State<HudControllerBuilder> createState() => _HudControllerBuilderState();
}

class _HudControllerBuilderState extends State<HudControllerBuilder> {
  static final LinkHudService _linkHudService = LinkHudService();
  HudRepositoryLease? _repositoryLease;
  HudController? _controller;
  SSHService? _observedSshService;
  bool _buildScheduled = false;
  bool _lastObservedSshConnected = false;
  String? _lastObservedSshEndpoint;

  @override
  void initState() {
    super.initState();
    _createBinding();
  }

  @override
  void didUpdateWidget(covariant HudControllerBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hostChanged = oldWidget.host != widget.host;
    final previewChanged = oldWidget.preview != widget.preview;
    final sshChanged = oldWidget.sshService != widget.sshService;

    if (sshChanged) {
      _recreateBinding();
      return;
    }
    if (hostChanged || previewChanged) {
      unawaited(_bindCurrent());
    }
  }

  @override
  void dispose() {
    _detachSshListener();
    final controller = _controller;
    final repositoryLease = _repositoryLease;
    _controller = null;
    _repositoryLease = null;
    if (controller != null) {
      controller.removeListener(_handleControllerChanged);
      unawaited(controller.clear());
      controller.dispose();
    }
    if (repositoryLease != null) {
      unawaited(repositoryLease.release());
    }
    super.dispose();
  }

  void _createBinding() {
    _attachSshListener();
    final repositoryLease = HudModule.acquireSharedRepository(
      sshService: widget.sshService,
    );
    final controller = HudModule.createController(
      repository: repositoryLease.repository,
    );
    controller.addListener(_handleControllerChanged);
    _repositoryLease = repositoryLease;
    _controller = controller;
    unawaited(_bindCurrent());
  }

  void _recreateBinding() {
    _detachSshListener();
    final oldController = _controller;
    final oldRepositoryLease = _repositoryLease;
    _controller = null;
    _repositoryLease = null;
    if (oldController != null) {
      oldController.removeListener(_handleControllerChanged);
      unawaited(oldController.clear());
      oldController.dispose();
    }
    if (oldRepositoryLease != null) {
      unawaited(oldRepositoryLease.release());
    }
    _createBinding();
  }

  void _attachSshListener() {
    final ssh = widget.sshService;
    if (identical(_observedSshService, ssh)) {
      return;
    }
    _detachSshListener();
    _observedSshService = ssh;
    if (ssh == null) {
      _lastObservedSshConnected = false;
      _lastObservedSshEndpoint = null;
      return;
    }
    _lastObservedSshConnected = ssh.isConnected;
    _lastObservedSshEndpoint = _currentSshEndpoint(ssh);
    ssh.addListener(_handleSshChanged);
  }

  void _detachSshListener() {
    final ssh = _observedSshService;
    if (ssh != null) {
      ssh.removeListener(_handleSshChanged);
    }
    _observedSshService = null;
  }

  String? _currentSshEndpoint(SSHService ssh) {
    final endpoint = (ssh.connectedIp ?? ssh.targetIp)?.trim();
    if (endpoint == null || endpoint.isEmpty) {
      return null;
    }
    return endpoint;
  }

  void _handleSshChanged() {
    final ssh = _observedSshService;
    if (ssh == null || widget.preview) {
      return;
    }
    final connected = ssh.isConnected;
    final endpoint = _currentSshEndpoint(ssh);
    final connectedChanged = connected != _lastObservedSshConnected;
    final endpointChanged = endpoint != _lastObservedSshEndpoint;
    _lastObservedSshConnected = connected;
    _lastObservedSshEndpoint = endpoint;

    if (widget.host == null || widget.host!.trim().isEmpty) {
      return;
    }
    if ((connectedChanged && connected) || (connected && endpointChanged)) {
      unawaited(_bindCurrent());
    }
  }

  Future<void> _bindCurrent() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    if (widget.preview) {
      await controller.bindPreview();
      return;
    }
    final host = widget.host?.trim();
    if (host == null || host.isEmpty) {
      await controller.clear();
      return;
    }
    final ssh = widget.sshService;
    if (ssh != null && ssh.isConnected) {
      try {
        await _linkHudService.ensureRunning(ssh);
      } catch (_) {}
    }
    await controller.bindLive(host);
  }

  void _handleControllerChanged() {
    if (!mounted) {
      return;
    }
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
      return;
    }
    if (_buildScheduled) {
      return;
    }
    _buildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _buildScheduled = false;
      if (!mounted) {
        return;
      }
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const SizedBox.shrink();
    }
    return widget.builder(
      context,
      controller,
      controller.state,
    );
  }
}
