import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart' as xterm;
import 'package:dartssh2/dartssh2.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/ssh_service.dart';
import '../../services/macro_service.dart';
import '../../widgets/custom_toast.dart';
import 'file_explorer_tab.dart';
import 'macro_tab.dart';
// import 'system_tab.dart'; // Removed

class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key});

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
        TabBar(
          controller: _tabController,
          labelColor: Theme.of(context).colorScheme.primary,
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(text: "터미널", icon: Icon(Icons.terminal)),
            Tab(text: "매크로", icon: Icon(Icons.edit_note)),
            Tab(text: "파일", icon: Icon(Icons.folder_outlined)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              TerminalScreen(),
              MacroTab(),
              FileExplorerTab(),
            ],
          ),
        ),
      ],
    );
  }
}

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with AutomaticKeepAliveClientMixin {
  late final xterm.Terminal _terminal;
  final xterm.TerminalController _terminalController =
      xterm.TerminalController();
  SSHSession? _session;
  SSHService? _sshService;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  bool _isSessionActive = false;
  bool _isStartingTerminal = false;
  bool _manualSessionClose = false;
  bool _shouldAutoReattach = false;
  double _fontSize = 14.0;
  bool _showVirtualKeys = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _terminal = xterm.Terminal(
      maxLines: 10000,
    );
    // _startTerminal(); // Auto-connect removed
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _fontSize = prefs.getDouble('terminal_font_size') ?? 14.0;
    });
  }

  Future<void> _updateFontSize(double newSize) async {
    final size = newSize.clamp(8.0, 32.0);
    setState(() => _fontSize = size);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('terminal_font_size', size);
  }

  void _sendMacro(String command) {
    if (_session != null) {
      _session!.write(utf8.encode("$command\n"));
      _terminal.write("\r\n> $command\r\n");
    } else {
      CustomToast.show(context, "터미널이 연결되지 않았습니다.", isError: true);
    }
  }

  void _sendKey(String key) {
    if (_session != null) {
      _session!.write(utf8.encode(key));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ssh = Provider.of<SSHService>(context);
    if (!identical(_sshService, ssh)) {
      _sshService?.removeListener(_onSshChanged);
      _sshService = ssh;
      _sshService?.addListener(_onSshChanged);
    }
  }

  @override
  void dispose() {
    _sshService?.removeListener(_onSshChanged);
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _session?.close();
    super.dispose();
  }

  void _onSshChanged() {
    final ssh = _sshService;
    if (!mounted || ssh == null) return;

    if (!ssh.isConnected) {
      if (_isSessionActive) {
        _terminal.write('\r\n[SSH 연결 끊김]\r\n');
      }
      setState(() {
        _isSessionActive = false;
      });
      _session = null;
      return;
    }

    if (_shouldAutoReattach && !_isSessionActive && !_isStartingTerminal) {
      _terminal.write('\r\n[SSH 재연결 감지: 터미널 자동 복구 시도]\r\n');
      _startTerminal(autoReconnect: true);
    }
  }

  Future<void> _startTerminal({bool autoReconnect = false}) async {
    final ssh = _sshService ?? Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      if (!autoReconnect) {
        _terminal.write('SSH 연결 대기 중...\r\n');
      }
      return;
    }

    if (_isSessionActive || _isStartingTerminal) return;

    try {
      _isStartingTerminal = true;
      if (!autoReconnect) {
        _terminal.write('터미널 세션 시작 중...\r\n');
      }
      _session = await ssh.startShell();
      if (!mounted) return;
      setState(() => _isSessionActive = true);
      _manualSessionClose = false;
      _shouldAutoReattach = true;

      _terminal.onOutput = (data) {
        _session?.write(utf8.encode(data));
      };

      _stdoutSub?.cancel();
      _stderrSub?.cancel();

      _stdoutSub = _session!.stdout.listen((data) {
        _terminal.write(utf8.decode(data));
      });

      _stderrSub = _session!.stderr.listen((data) {
        _terminal.write(utf8.decode(data));
      });

      _session!.done.then((_) {
        final manualClose = _manualSessionClose;
        _manualSessionClose = false;
        _session = null;
        if (mounted) {
          setState(() => _isSessionActive = false);
          _terminal.write('\r\n세션이 종료되었습니다.\r\n');
        }

        if (!manualClose &&
            mounted &&
            (_sshService?.isConnected ?? false) &&
            _shouldAutoReattach) {
          Future.delayed(const Duration(seconds: 1), () {
            if (!mounted) return;
            if ((_sshService?.isConnected ?? false) &&
                !_isSessionActive &&
                !_isStartingTerminal &&
                _shouldAutoReattach) {
              _terminal.write('[세션 자동 복구 시도]\r\n');
              _startTerminal(autoReconnect: true);
            }
          });
        }
      });
    } catch (e) {
      _terminal.write('오류 발생: $e\r\n');
    } finally {
      _isStartingTerminal = false;
    }
  }

  Future<void> _stopTerminal({bool manual = true}) async {
    if (manual) {
      _shouldAutoReattach = false;
    }
    _manualSessionClose = manual;
    try {
      await _stdoutSub?.cancel();
      await _stderrSub?.cancel();
    } catch (_) {}
    _stdoutSub = null;
    _stderrSub = null;
    try {
      _session?.close();
    } catch (_) {}
    _session = null;
    if (mounted) {
      setState(() => _isSessionActive = false);
    }
  }

  Future<void> _copySelection() async {
    final selection = _terminalController.selection;
    if (selection != null) {
      final text = _terminal.buffer.getText(selection);
      if (text.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) {
          CustomToast.show(context, "복사되었습니다.");
        }
        _terminalController.clearSelection();
      }
    } else {
      if (mounted) {
        CustomToast.show(context, "선택된 텍스트가 없습니다.", isError: true);
      }
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _session?.write(utf8.encode(data!.text!));
      if (mounted) {
        CustomToast.show(context, "붙여넣기 완료");
      }
    }
  }

  Widget _buildVirtualKey(String label, String code) {
    return InkWell(
      onTap: () => _sendKey(code),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.withOpacity(0.3)),
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final macros = Provider.of<MacroService>(context).macros;

    return Column(
      children: [
        // Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove),
                onPressed: () => _updateFontSize(_fontSize - 2),
                tooltip: "글자 작게",
              ),
              Text("${_fontSize.toInt()}pt"),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => _updateFontSize(_fontSize + 2),
                tooltip: "글자 크게",
              ),
              Container(
                height: 24,
                width: 1,
                color: Colors.grey.withOpacity(0.5),
                margin: const EdgeInsets.symmetric(horizontal: 8),
              ),
              IconButton(
                icon: const Icon(Icons.copy),
                onPressed: _copySelection,
                tooltip: "복사",
              ),
              IconButton(
                icon: const Icon(Icons.paste),
                onPressed: _paste,
                tooltip: "붙여넣기",
              ),
              IconButton(
                icon: Icon(
                    _showVirtualKeys ? Icons.keyboard_hide : Icons.keyboard),
                onPressed: () =>
                    setState(() => _showVirtualKeys = !_showVirtualKeys),
                tooltip: "가상 키보드",
              ),
              const Spacer(),
              if (!_isSessionActive)
                ElevatedButton.icon(
                  onPressed: () => _startTerminal(),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text("연결"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                )
              else
                ElevatedButton.icon(
                  onPressed: () => _stopTerminal(manual: true),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text("끊기"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: xterm.TerminalView(
            _terminal,
            controller: _terminalController,
            textStyle: xterm.TerminalStyle(
                fontSize: _fontSize, fontFamily: 'monospace'),
            readOnly: false,
          ),
        ),

        // Fixed Bottom Area (Virtual Keys + Macros)
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                offset: const Offset(0, -2),
                blurRadius: 4,
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Virtual Keypad
                if (_showVirtualKeys)
                  Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          const SizedBox(width: 8),
                          _buildVirtualKey("ESC", "\x1b"),
                          const SizedBox(width: 8),
                          _buildVirtualKey("TAB", "\t"),
                          const SizedBox(width: 8),
                          _buildVirtualKey("CTRL+C", "\x03"),
                          const SizedBox(width: 8),
                          _buildVirtualKey("UP", "\x1b[A"),
                          const SizedBox(width: 8),
                          _buildVirtualKey("DOWN", "\x1b[B"),
                          const SizedBox(width: 8),
                          _buildVirtualKey("LEFT", "\x1b[D"),
                          const SizedBox(width: 8),
                          _buildVirtualKey("RIGHT", "\x1b[C"),
                          const SizedBox(width: 8),
                          _buildVirtualKey("ENTER", "\r"),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),

                // Quick Macros
                if (macros.isNotEmpty)
                  Container(
                    height: 50,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: macros.length,
                      itemBuilder: (context, index) {
                        final macro = macros[index];
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ElevatedButton(
                            onPressed: () => _sendMacro(macro.command),
                            style: ElevatedButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              minimumSize: const Size(0, 36),
                            ),
                            child: Text(macro.name),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
