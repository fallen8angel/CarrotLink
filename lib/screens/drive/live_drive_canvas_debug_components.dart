part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasDebugComponents on _LiveDriveCanvasScreenState {
  Widget _statusLineImpl(
    String label,
    String value, {
    double labelWidth = 126,
    double labelFontSize = 13,
    double valueFontSize = 13,
    EdgeInsets? padding,
    Color? valueColor,
  }) {
    return Padding(
      padding: padding ?? const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: TextStyle(color: Colors.white60, fontSize: labelFontSize),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: valueFontSize,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _debugMetricPillImpl(String label, String value) {
    final window = UiWindowInfo.of(context);
    final minWidth = switch (window.windowClass) {
      UiWindowClass.compact => 102.0,
      UiWindowClass.medium => 108.0,
      UiWindowClass.expanded => 114.0,
      UiWindowClass.large => 120.0,
      UiWindowClass.extraLarge => 128.0,
    };
    final horizontalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 9.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large => 10.0,
      UiWindowClass.extraLarge => 11.0,
    };
    final verticalPadding = switch (window.windowClass) {
      UiWindowClass.compact => 8.0,
      UiWindowClass.medium => 9.0,
      UiWindowClass.expanded => 10.0,
      UiWindowClass.large => 10.0,
      UiWindowClass.extraLarge => 11.0,
    };
    return Container(
      constraints: BoxConstraints(minWidth: minWidth),
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF231A14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDebugTextDialogImpl(String title, String content) async {
    if (!mounted) return;
    final window = UiWindowInfo.of(context);
    final dialogMaxWidth = switch (window.windowClass) {
      UiWindowClass.compact => 420.0,
      UiWindowClass.medium => 520.0,
      UiWindowClass.expanded => 620.0,
      UiWindowClass.large => 700.0,
      UiWindowClass.extraLarge => 760.0,
    };
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: dialogMaxWidth,
          child: SingleChildScrollView(
            child: SelectableText(
              content,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }
}
