import 'package:flutter/material.dart';
import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';

class CustomToast {
  static OverlayEntry? _lastEntry;

  static void show(BuildContext context, String message,
      {bool isError = false}) {
    _lastEntry?.remove();
    _lastEntry = null;

    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top +
            (UiWindowInfo.of(context).isCompact ? 10 : 14),
        left: UiLayoutTokens.of(context)
            .screenPadding
            .clamp(12.0, 24.0)
            .toDouble(),
        right: UiLayoutTokens.of(context)
            .screenPadding
            .clamp(12.0, 24.0)
            .toDouble(),
        child: Material(
          color: Colors.transparent,
          child: _ToastWidget(message: message, isError: isError),
        ),
      ),
    );

    _lastEntry = overlayEntry;
    overlay.insert(overlayEntry);

    Future.delayed(const Duration(seconds: 2), () {
      if (_lastEntry == overlayEntry) {
        overlayEntry.remove();
        _lastEntry = null;
      }
    });
  }
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final bool isError;

  const _ToastWidget({required this.message, required this.isError});

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _opacity = Tween<double>(begin: 0.0, end: 1.0)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _offset = Tween<Offset>(begin: const Offset(0, -0.5), end: Offset.zero)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final scheme = Theme.of(context).colorScheme;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _offset,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: window.isCompact ? 14 : 16,
            vertical: window.isCompact ? 11 : 12,
          ),
          decoration: BoxDecoration(
            color: widget.isError
                ? scheme.error.withValues(alpha: 0.9)
                : const Color(0xFF333333).withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              Icon(
                widget.isError
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                color: Colors.white,
                size: window.isCompact ? 19 : 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: window.isCompact ? 13.5 : 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
