import 'package:flutter/material.dart';

import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';

class SettingsSubpageScaffold extends StatelessWidget {
  const SettingsSubpageScaffold({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.maxWidth,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final tokens = UiLayoutTokens.of(context);
    final window = UiWindowInfo.of(context);
    final bodyMaxWidth = maxWidth ??
        switch (window.windowClass) {
          UiWindowClass.compact => 720.0,
          UiWindowClass.medium => 820.0,
          _ => 920.0,
        };
    final horizontalPadding = tokens.screenPadding.clamp(8.0, 20.0).toDouble();
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: actions,
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: bodyMaxWidth),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              0,
              horizontalPadding,
              tokens.footerSpacer,
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.bottomSpacing = 20,
    this.showTopDivider = true,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final double bottomSpacing;
  final bool showTopDivider;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTopDivider)
            Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.65),
            ),
          if (showTopDivider) const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

class SettingsItemGroup extends StatelessWidget {
  const SettingsItemGroup({
    super.key,
    required this.children,
  });

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visibleChildren =
        children.where((child) => child is! SizedBox).toList();
    return Column(
      children: [
        for (var i = 0; i < visibleChildren.length; i++) ...[
          visibleChildren[i],
          if (i != visibleChildren.length - 1)
            Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
        ],
      ],
    );
  }
}

class SettingsActionRow extends StatelessWidget {
  const SettingsActionRow({
    super.key,
    required this.title,
    this.value,
    this.onTap,
    this.trailing,
    this.destructive = false,
    this.padding,
  });

  final String title;
  final String? value;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool destructive;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = destructive ? scheme.error : scheme.onSurface;
    return ListTile(
      contentPadding:
          padding ?? const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      title: Text(
        title,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
              color: foreground,
            ),
      ),
      subtitle: value != null && value!.trim().isNotEmpty
          ? Text(
              value!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            )
          : null,
      trailing: trailing ??
          (onTap != null
              ? Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant,
                )
              : null),
      onTap: onTap,
      dense: false,
      minVerticalPadding: 6,
    );
  }
}

class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.padding,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding:
          padding ?? const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      title: Text(
        title,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
              color: enabled
                  ? scheme.onSurface
                  : scheme.onSurface.withValues(alpha: 0.5),
            ),
      ),
      trailing: Switch.adaptive(
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
      dense: false,
      minVerticalPadding: 6,
      enabled: enabled,
      onTap: enabled && onChanged != null ? () => onChanged!(!value) : null,
    );
  }
}

class SettingsStatusNote extends StatelessWidget {
  const SettingsStatusNote({
    super.key,
    required this.text,
    this.color,
  });

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color ?? scheme.onSurfaceVariant,
            ),
      ),
    );
  }
}
