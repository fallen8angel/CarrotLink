import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ssh_service.dart';
import '../ui/adaptive/layout_tokens.dart';
import '../ui/adaptive/window_class.dart';

class CommandExecutionDialog extends StatefulWidget {
  final String title;
  final String command;
  final bool autoClose;

  const CommandExecutionDialog({
    super.key,
    required this.title,
    required this.command,
    this.autoClose = false,
  });

  @override
  State<CommandExecutionDialog> createState() => _CommandExecutionDialogState();
}

class _CommandExecutionDialogState extends State<CommandExecutionDialog> {
  final ScrollController _scrollController = ScrollController();
  final List<String> _logs = [];
  bool _isRunning = true;
  int? _exitCode;
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _startExecution();
  }

  void _startExecution() {
    final ssh = Provider.of<SSHService>(context, listen: false);

    _logs.add("> ${widget.command}");

    try {
      final stream = ssh.executeCommandStream(
        widget.command,
        onExit: (code) {
          if (mounted) {
            setState(() {
              _isRunning = false;
              _exitCode = code;
              _logs.add("\n[Process exited with code $code]");
            });
            _scrollToBottom();

            if (widget.autoClose && code == 0) {
              Future.delayed(const Duration(seconds: 1), () {
                if (mounted) Navigator.pop(context, true);
              });
            }
          }
        },
      );

      _subscription = stream.listen(
        (data) {
          final text = utf8.decode(data, allowMalformed: true);
          if (mounted) {
            setState(() {
              // Split by lines to handle partial chunks better in UI if needed,
              // but appending text is simpler for a terminal view.
              // We'll just append to the last log entry if it doesn't end with newline,
              // or add new entries. For simplicity, let's just add chunks.
              _logs.add(text);
            });
            _scrollToBottom();
          }
        },
        onError: (e) {
          if (mounted) {
            setState(() {
              _logs.add("\nError: $e");
              _isRunning = false;
              _exitCode = -1;
            });
          }
        },
      );
    } catch (e) {
      setState(() {
        _logs.add("Failed to start command: $e");
        _isRunning = false;
        _exitCode = -1;
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final window = UiWindowInfo.of(context);
    final tokens = UiLayoutTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isSuccess = _exitCode == 0;
    final media = MediaQuery.of(context);
    final dialogHeight =
        (media.size.height * (window.isLandscape ? 0.62 : 0.44))
            .clamp(220.0, 460.0)
            .toDouble();

    return AlertDialog(
      title: Row(
        children: [
          if (_isRunning)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (isSuccess)
            const Icon(Icons.check_circle, color: Colors.green)
          else
            Icon(Icons.error, color: scheme.error),
          const SizedBox(width: 12),
          Expanded(child: Text(widget.title)),
        ],
      ),
      content: Container(
        width: double.maxFinite,
        height: dialogHeight,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
        padding: EdgeInsets.all(tokens.itemGap + 2),
        child: SelectionArea(
          child: ListView.builder(
            controller: _scrollController,
            itemCount: _logs.length,
            itemBuilder: (context, index) {
              return Text(
                _logs[index],
                style: const TextStyle(
                  color: Color(0xFF9EF3BD),
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              );
            },
          ),
        ),
      ),
      actions: [
        if (!_isRunning)
          TextButton(
            onPressed: () => Navigator.pop(context, isSuccess),
            child: const Text("닫기"),
          )
        else
          TextButton(
            onPressed: () {
              // We can't easily kill the remote process without a PID,
              // but we can stop listening and close the dialog.
              _subscription?.cancel();
              Navigator.pop(context, false);
            },
            child: const Text(
                "숨기기"), // "Cancel" might imply killing the process, which we can't guarantee here
          ),
      ],
    );
  }
}
