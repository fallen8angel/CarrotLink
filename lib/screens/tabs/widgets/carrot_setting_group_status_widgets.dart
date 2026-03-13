import 'package:flutter/material.dart';

import '../../../ui/adaptive/window_class.dart';

class CarrotGroupSectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool isCollapsed;
  final VoidCallback? onTap;

  const CarrotGroupSectionHeader({
    super.key,
    required this.title,
    required this.count,
    required this.isCollapsed,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final window = UiWindowInfo.of(context);
    final titleSize = switch (window.windowClass) {
      UiWindowClass.compact => 14.0,
      UiWindowClass.medium => 14.0,
      UiWindowClass.expanded => 14.5,
      UiWindowClass.large => 15.0,
      UiWindowClass.extraLarge => 15.0,
    };

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: titleSize,
                  ),
                ),
              ),
              _HeaderPill(text: '$count개'),
              const SizedBox(width: 8),
              Icon(
                isCollapsed ? Icons.expand_more : Icons.expand_less,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CarrotCurrentGroupBanner extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onExpandAll;
  final VoidCallback? onCollapseAll;
  final VoidCallback? onJumpToCurrentGroup;

  const CarrotCurrentGroupBanner({
    super.key,
    required this.label,
    required this.value,
    this.onExpandAll,
    this.onCollapseAll,
    this.onJumpToCurrentGroup,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasActions = onExpandAll != null ||
        onCollapseAll != null ||
        onJumpToCurrentGroup != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.vertical_align_top,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (hasActions) ...[
            const SizedBox(width: 6),
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onExpandAll != null)
                      _HeaderActionButton(
                        text: '펼침',
                        onPressed: onExpandAll!,
                      ),
                    if (onCollapseAll != null) const SizedBox(width: 4),
                    if (onCollapseAll != null)
                      _HeaderActionButton(
                        text: '접음',
                        onPressed: onCollapseAll!,
                      ),
                    if (onJumpToCurrentGroup != null) const SizedBox(width: 4),
                    if (onJumpToCurrentGroup != null)
                      _HeaderActionButton(
                        text: '상단',
                        icon: Icons.vertical_align_top_rounded,
                        onPressed: onJumpToCurrentGroup!,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class CarrotFloatingStateCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool compact;
  final List<Widget> trailing;

  const CarrotFloatingStateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.compact = false,
    this.trailing = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.97),
      elevation: 10,
      borderRadius: BorderRadius.circular(compact ? 14 : 16),
      child: Padding(
        padding: compact
            ? const EdgeInsets.fromLTRB(12, 7, 12, 7)
            : const EdgeInsets.fromLTRB(14, 9, 14, 9),
        child: Row(
          children: [
            Icon(
              icon,
              size: compact ? 16 : 18,
              color: theme.colorScheme.primary,
            ),
            SizedBox(width: compact ? 8 : 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 12 : 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: compact ? 1 : 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 11 : 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing.isNotEmpty) ...[
              const SizedBox(width: 8),
              ...trailing,
            ],
          ],
        ),
      ),
    );
  }
}

class _HeaderPill extends StatelessWidget {
  final String text;

  const _HeaderPill({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _HeaderActionButton extends StatelessWidget {
  final String text;
  final IconData? icon;
  final VoidCallback onPressed;

  const _HeaderActionButton({
    required this.text,
    required this.onPressed,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 3),
              ],
              Text(
                text,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
