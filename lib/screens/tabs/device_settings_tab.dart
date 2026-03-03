import 'package:flutter/material.dart';

import '../../widgets/section_tab_bar.dart';
import 'carrot_backup_tab.dart';
import 'carrot_settings_tab.dart';

class DeviceSettingsTab extends StatefulWidget {
  const DeviceSettingsTab({super.key});

  @override
  State<DeviceSettingsTab> createState() => _DeviceSettingsTabState();
}

class _DeviceSettingsTabState extends State<DeviceSettingsTab>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
    return Column(
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
            children: const [
              CarrotSettingsTab(),
              CarrotBackupTab(),
            ],
          ),
        ),
      ],
    );
  }
}
