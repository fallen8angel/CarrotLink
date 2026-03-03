import 'package:flutter/material.dart';

import '../../widgets/section_tab_bar.dart';
import 'git_tab.dart';
import 'system_tab.dart';

class GitManagementTab extends StatefulWidget {
  const GitManagementTab({super.key});

  @override
  State<GitManagementTab> createState() => _GitManagementTabState();
}

class _GitManagementTabState extends State<GitManagementTab>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SectionTabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Git', icon: Icon(Icons.source_outlined)),
            Tab(
                text: '관리',
                icon: Icon(Icons.settings_system_daydream_outlined)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              GitTab(),
              SystemTab(),
            ],
          ),
        ),
      ],
    );
  }
}
