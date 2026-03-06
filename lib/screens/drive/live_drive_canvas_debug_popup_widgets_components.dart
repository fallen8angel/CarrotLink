part of 'live_drive_canvas_screen.dart';

const Color _debugDialogBg = Color(0xFF17120F);
const Color _debugNavBg = Color(0xFF211A15);
const Color _debugCardBg = Color(0xFF1F1712);
const Color _debugCardBgAlt = Color(0xFF231A14);
const Color _debugPanelBg = Color(0xFF1D1612);
const Color _debugSelectedBg = Color(0xFF7A5644);
const Color _debugSelectedBorder = Color(0xFFD6A88C);

extension _LiveDriveCanvasDebugPopupWidgetsComponents
    on _LiveDriveCanvasScreenState {
  Widget _buildDebugLayerSwitch({
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return SwitchListTile(
      dense: false,
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      title: Text(title),
    );
  }

  Widget _buildDebugGroupNavItem({
    required int index,
    required int selectedGroup,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final selected = selectedGroup == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? _debugSelectedBg : _debugNavBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? _debugSelectedBorder : Colors.white12,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDebugGroupNavChip({
    required int index,
    required int selectedGroup,
    required IconData icon,
    required String label,
    required double chipFontSize,
    required double chipIconSize,
    required ValueChanged<bool> onSelected,
  }) {
    final selected = selectedGroup == index;
    return ChoiceChip(
      selected: selected,
      onSelected: onSelected,
      selectedColor: _debugSelectedBg,
      backgroundColor: _debugNavBg,
      side: BorderSide(
        color: selected ? _debugSelectedBorder : Colors.white12,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      avatar: Icon(icon, size: chipIconSize, color: Colors.white),
      label: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: chipFontSize,
          fontWeight: FontWeight.w700,
        ),
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
    );
  }

  Widget _buildDebugSectionCard({
    required UiWindowInfo window,
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    final cardPadding = EdgeInsets.fromLTRB(
      window.isCompact ? 14 : 16,
      window.isCompact ? 12 : 14,
      window.isCompact ? 14 : 16,
      window.isCompact ? 12 : 14,
    );
    final titleFont = window.isCompact ? 14.0 : 15.0;
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: window.isCompact ? 12 : 14),
      padding: cardPadding,
      decoration: BoxDecoration(
        color: _debugCardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: titleFont,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          SizedBox(height: window.isCompact ? 6 : 8),
          child,
        ],
      ),
    );
  }

  Widget _buildDebugStatusMetricCard({
    required double statusCardPadding,
    required double statusCardRadius,
    required double statusLabelFont,
    required double statusValueFont,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Container(
      padding: EdgeInsets.all(statusCardPadding),
      decoration: BoxDecoration(
        color: _debugCardBgAlt,
        borderRadius: BorderRadius.circular(statusCardRadius),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white60,
              fontSize: statusLabelFont,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? Colors.white,
              fontSize: statusValueFont + 1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugStatusGrid({
    required double statusGridSpacing,
    required double statusCardPadding,
    required double statusCardRadius,
    required double statusLabelFont,
    required double statusValueFont,
    required List<({String label, String value, Color? color})> items,
    int? columns,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final targetColumns = columns ??
            (constraints.maxWidth >= 760
                ? 3
                : (constraints.maxWidth >= 520 ? 2 : 1));
        final width = (constraints.maxWidth -
                statusGridSpacing * (targetColumns - 1)) /
            targetColumns;
        return Wrap(
          spacing: statusGridSpacing,
          runSpacing: statusGridSpacing,
          children: [
            for (final item in items)
              SizedBox(
                width: width,
                child: _buildDebugStatusMetricCard(
                  statusCardPadding: statusCardPadding,
                  statusCardRadius: statusCardRadius,
                  statusLabelFont: statusLabelFont,
                  statusValueFont: statusValueFont,
                  label: item.label,
                  value: item.value,
                  valueColor: item.color,
                ),
              ),
          ],
        );
      },
    );
  }
}
