import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
import '../../services/macro_service.dart';
import '../../widgets/design_components.dart';
import '../../widgets/custom_toast.dart';

import '../../widgets/command_execution_dialog.dart';

class MacroTab extends StatefulWidget {
  const MacroTab({super.key});

  @override
  State<MacroTab> createState() => _MacroTabState();
}

class _MacroTabState extends State<MacroTab> {
  @override
  void initState() {
    super.initState();
    // Ensure macros are loaded. If empty, try reloading (though service usually handles it).
    // We can force a notify if needed, but let's just rely on Provider.
    // If the list is empty, it might be because it hasn't loaded yet.
    // We can try to trigger a reload if it's empty.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final service = Provider.of<MacroService>(context, listen: false);
      if (service.macros.isEmpty) {
        // There is no public reload method, but we can add one or just trust it loads.
        // If it's empty, maybe it's really empty?
        // But user said "first press empty... then shows".
        // This implies a rebuild fixes it.
        // setState here might help if it was a timing issue.
        setState(() {});
      }
    });
  }

  void _showAddDialog(BuildContext context, {int? index, String? initialName, String? initialCmd}) {
    final nameCtrl = TextEditingController(text: initialName);
    final cmdCtrl = TextEditingController(text: initialCmd);
    final isEditing = index != null;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEditing ? "매크로 수정" : "매크로 추가"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "이름")),
            TextField(controller: cmdCtrl, decoration: const InputDecoration(labelText: "명령어")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("취소")),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.isNotEmpty && cmdCtrl.text.isNotEmpty) {
                final service = Provider.of<MacroService>(context, listen: false);
                if (isEditing) {
                  service.updateMacro(index, nameCtrl.text, cmdCtrl.text);
                } else {
                  service.addMacro(nameCtrl.text, cmdCtrl.text);
                }
                Navigator.pop(ctx);
              }
            },
            child: Text(isEditing ? "수정" : "추가"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final macros = Provider.of<MacroService>(context).macros;

    return Scaffold(
      appBar: AppBar(
        title: const Text("매크로 관리"),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: "기본 매크로 복원",
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text("기본 매크로 복원"),
                  content: const Text("모든 커스텀 매크로가 삭제되고 기본 매크로로 초기화됩니다. 계속하시겠습니까?"),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("취소")),
                    ElevatedButton(
                      onPressed: () {
                        Provider.of<MacroService>(context, listen: false).resetToDefaults();
                        Navigator.pop(ctx);
                        CustomToast.show(context, "기본 매크로가 복원되었습니다.");
                      },
                      child: const Text("복원"),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context),
        child: const Icon(Icons.add),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 150),
        itemCount: macros.length,
        itemBuilder: (ctx, index) {
          final macro = macros[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: DesignCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                onTap: () async {
                  final ssh = Provider.of<SSHService>(context, listen: false);
                  if (!ssh.isConnected) {
                    CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
                    return;
                  }
                  
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (context) => CommandExecutionDialog(
                      title: macro.name,
                      command: macro.command,
                      autoClose: false, // Let user see the output
                    ),
                  );
                },
                title: Text(macro.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(macro.command, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, color: Colors.blue),
                      onPressed: () => _showAddDialog(context, index: index, initialName: macro.name, initialCmd: macro.command),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () => Provider.of<MacroService>(context, listen: false).removeMacro(index),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
