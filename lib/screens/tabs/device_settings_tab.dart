import 'package:flutter/material.dart';

import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/section_tab_bar.dart';
import 'carrot_backup_tab.dart';
import 'carrot_settings_tab.dart';

class DeviceSettingsTab extends StatefulWidget {
  final int initialTabIndex;
  final String? initialFocusItemName;

  const DeviceSettingsTab({
    super.key,
    this.initialTabIndex = 0,
    this.initialFocusItemName,
  });

  @override
  State<DeviceSettingsTab> createState() => _DeviceSettingsTabState();
}

class _DeviceSettingsTabState extends State<DeviceSettingsTab>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    final initialIndex = widget.initialTabIndex.clamp(0, 1).toInt();
    _tabController =
        TabController(length: 2, vsync: this, initialIndex: initialIndex);
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) return;
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final maxWidth = switch (window.windowClass) {
      UiWindowClass.compact => double.infinity,
      UiWindowClass.medium => 980.0,
      UiWindowClass.expanded => 1180.0,
      UiWindowClass.large => 1320.0,
      UiWindowClass.extraLarge => 1440.0,
    };

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: window.isCompact ? 0 : tokens.screenPadding,
          ),
          child: Column(
            children: [
              SectionTabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: "콤마설정", icon: Icon(Icons.tune_outlined)),
                  Tab(text: "당근백업", icon: Icon(Icons.backup_outlined)),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    CarrotSettingsTab(
                      initialFocusItemName: widget.initialFocusItemName,
                    ),
                    const CarrotBackupTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
