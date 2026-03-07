import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../services/ssh_service.dart';
import '../../application/hud_controller.dart';
import '../../application/hud_controller_state.dart';
import '../../application/hud_module.dart';
import '../../domain/repositories/hud_repository.dart';

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
  HudRepository? _repository;
  HudController? _controller;

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
    final controller = _controller;
    final repository = _repository;
    _controller = null;
    _repository = null;
    if (controller != null) {
      controller.removeListener(_handleControllerChanged);
      unawaited(controller.clear());
      controller.dispose();
    }
    if (repository != null) {
      unawaited(repository.dispose());
    }
    super.dispose();
  }

  void _createBinding() {
    final repository = HudModule.createRepository(
      sshService: widget.sshService,
    );
    final controller = HudModule.createController(
      repository: repository,
    );
    controller.addListener(_handleControllerChanged);
    _repository = repository;
    _controller = controller;
    unawaited(_bindCurrent());
  }

  void _recreateBinding() {
    final oldController = _controller;
    final oldRepository = _repository;
    _controller = null;
    _repository = null;
    if (oldController != null) {
      oldController.removeListener(_handleControllerChanged);
      unawaited(oldController.clear());
      oldController.dispose();
    }
    if (oldRepository != null) {
      unawaited(oldRepository.dispose());
    }
    _createBinding();
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
    await controller.bindLive(host);
  }

  void _handleControllerChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
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
