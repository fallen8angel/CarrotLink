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
import '../../widgets/section_tab_bar.dart';
import 'file_explorer_tab.dart';
import 'macro_tab.dart';
// import 'system_tab.dart'; // Removed

class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key});

  @override
  State<TerminalTab> createState() => TerminalTabState();
}

class TerminalTabState extends State<TerminalTab>
    with SingleTickerProviderStateMixin {
  static const String _lastTerminalSubTabIndexKey =
      'terminal_last_sub_tab_index';
  late TabController _tabController;
  final GlobalKey<FileExplorerTabState> _fileExplorerTabKey =
      GlobalKey<FileExplorerTabState>();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_handleSubTabChanged);
    unawaited(_restoreLastSubTabIndex());
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleSubTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _handleSubTabChanged() {
    if (_tabController.indexIsChanging) return;
    unawaited(_persistLastSubTabIndex(_tabController.index));
  }

  Future<void> _restoreLastSubTabIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_lastTerminalSubTabIndexKey);
    if (saved == null || saved < 0 || saved >= _tabController.length) return;
    if (!mounted) return;
    _tabController.index = saved;
  }

  Future<void> _persistLastSubTabIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastTerminalSubTabIndexKey, index);
  }

  Future<bool> handleSystemBack() async {
    if (!mounted) return false;
    final animationValue = _tabController.animation?.value;
    final fileTabVisibleOrTransitioning = _tabController.index == 2 ||
        (_tabController.indexIsChanging &&
            (_tabController.index == 2 || _tabController.previousIndex == 2)) ||
        (animationValue != null && (animationValue - 2).abs() < 0.6);
    if (!fileTabVisibleOrTransitioning) return false;
    return await _fileExplorerTabKey.currentState?.handleSystemBack() ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SectionTabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: "터미널", icon: Icon(Icons.terminal)),
            Tab(text: "매크로", icon: Icon(Icons.edit_note)),
            Tab(text: "파일", icon: Icon(Icons.folder_outlined)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              const TerminalScreen(),
              const MacroTab(),
              FileExplorerTab(key: _fileExplorerTabKey),
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
  static const Duration _terminalOutputFlushInterval =
      Duration(milliseconds: 16);
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
  final StringBuffer _pendingTerminalOutput = StringBuffer();
  Timer? _terminalOutputFlushTimer;
  int _sessionGeneration = 0;
  bool _terminalContextMenuOpen = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _terminal = xterm.Terminal(
      maxLines: 10000,
    );
    _terminal.onOutput = (data) {
      final session = _session;
      if (session == null) return;
      try {
        session.write(utf8.encode(data));
      } catch (_) {}
    };
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      final session = _session;
      if (session == null || !_isSessionActive) return;
      try {
        session.resizeTerminal(width, height, pixelWidth, pixelHeight);
      } catch (_) {}
    };
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
    final session = _session;
    if (session != null) {
      session.write(utf8.encode("$command\n"));
      _writeTerminal("\r\n> $command\r\n");
    } else {
      CustomToast.show(context, "터미널이 연결되지 않았습니다.", isError: true);
    }
  }

  void _sendKey(String key) {
    final session = _session;
    if (session != null) {
      session.write(utf8.encode(key));
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
    _sessionGeneration += 1;
    _terminalOutputFlushTimer?.cancel();
    _flushPendingTerminalOutput();
    unawaited(_stdoutSub?.cancel());
    unawaited(_stderrSub?.cancel());
    try {
      _session?.close();
    } catch (_) {}
    _stdoutSub = null;
    _stderrSub = null;
    _session = null;
    super.dispose();
  }

  void _writeTerminal(String text) {
    if (text.isEmpty) return;
    _pendingTerminalOutput.write(text);
    if (_terminalOutputFlushTimer != null) return;
    _terminalOutputFlushTimer = Timer(_terminalOutputFlushInterval, () {
      _terminalOutputFlushTimer = null;
      _flushPendingTerminalOutput();
    });
  }

  void _flushPendingTerminalOutput() {
    if (_pendingTerminalOutput.isEmpty) return;
    final chunk = _pendingTerminalOutput.toString();
    _pendingTerminalOutput.clear();
    _terminal.write(chunk);
  }

  Future<void> _cancelSessionStreams() async {
    try {
      await _stdoutSub?.cancel();
    } catch (_) {}
    try {
      await _stderrSub?.cancel();
    } catch (_) {}
    _stdoutSub = null;
    _stderrSub = null;
  }

  Future<void> _syncRemoteTerminalSize([SSHSession? session]) async {
    final target = session ?? _session;
    if (target == null) return;
    final width = _terminal.viewWidth <= 0 ? 80 : _terminal.viewWidth;
    final height = _terminal.viewHeight <= 0 ? 24 : _terminal.viewHeight;
    try {
      target.resizeTerminal(width, height);
    } catch (_) {}
  }

  RelativeRect _menuPositionForGlobalOffset(Offset? globalPosition) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final renderBox = overlay.context.findRenderObject() as RenderBox;
    final local = globalPosition == null
        ? Offset(renderBox.size.width / 2, renderBox.size.height * 0.62)
        : renderBox.globalToLocal(globalPosition);
    final dx =
        (local.dx.clamp(12.0, renderBox.size.width - 12.0) as num).toDouble();
    final dy =
        (local.dy.clamp(12.0, renderBox.size.height - 12.0) as num).toDouble();
    return RelativeRect.fromLTRB(
      dx,
      dy,
      renderBox.size.width - dx,
      renderBox.size.height - dy,
    );
  }

  Future<void> _showTerminalContextMenu({Offset? globalPosition}) async {
    if (!mounted || _terminalContextMenuOpen) return;
    final hasSelection = _terminalController.selection != null;
    _terminalContextMenuOpen = true;
    try {
      final action = await showMenu<String>(
        context: context,
        position: _menuPositionForGlobalOffset(globalPosition),
        items: [
          PopupMenuItem<String>(
            value: 'copy',
            enabled: hasSelection,
            child: const Text('복사'),
          ),
          const PopupMenuItem<String>(
            value: 'paste',
            child: Text('붙여넣기'),
          ),
          PopupMenuItem<String>(
            value: 'clear_selection',
            enabled: hasSelection,
            child: const Text('선택 해제'),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: 'cursor_up',
            child: Text('커서 ↑'),
          ),
          const PopupMenuItem<String>(
            value: 'cursor_down',
            child: Text('커서 ↓'),
          ),
          const PopupMenuItem<String>(
            value: 'cursor_left',
            child: Text('커서 ←'),
          ),
          const PopupMenuItem<String>(
            value: 'cursor_right',
            child: Text('커서 →'),
          ),
          const PopupMenuItem<String>(
            value: 'enter',
            child: Text('엔터'),
          ),
          const PopupMenuItem<String>(
            value: 'ctrl_c',
            child: Text('CTRL+C'),
          ),
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: 'toggle_virtual_keys',
            child: Text(_showVirtualKeys ? '가상키 숨기기' : '가상키 보기'),
          ),
        ],
      );

      if (!mounted || action == null) return;

      switch (action) {
        case 'copy':
          await _copySelection();
          break;
        case 'paste':
          await _paste();
          break;
        case 'clear_selection':
          _terminalController.clearSelection();
          break;
        case 'cursor_up':
          _sendKey('\x1b[A');
          break;
        case 'cursor_down':
          _sendKey('\x1b[B');
          break;
        case 'cursor_left':
          _sendKey('\x1b[D');
          break;
        case 'cursor_right':
          _sendKey('\x1b[C');
          break;
        case 'enter':
          _sendKey('\r');
          break;
        case 'ctrl_c':
          _sendKey('\x03');
          break;
        case 'toggle_virtual_keys':
          setState(() => _showVirtualKeys = !_showVirtualKeys);
          break;
      }
    } finally {
      _terminalContextMenuOpen = false;
    }
  }

  void _handleTerminalTapUp(TapUpDetails details) {
    if (_terminalController.selection == null) return;
    unawaited(_showTerminalContextMenu(globalPosition: details.globalPosition));
  }

  void _handleTerminalSecondaryTapUp(TapUpDetails details) {
    unawaited(_showTerminalContextMenu(globalPosition: details.globalPosition));
  }

  void _onSshChanged() {
    final ssh = _sshService;
    if (!mounted || ssh == null) return;

    if (!ssh.isConnected) {
      if (_isSessionActive) {
        _writeTerminal('\r\n[SSH 연결 끊김]\r\n');
      }
      _sessionGeneration += 1;
      _isStartingTerminal = false;
      unawaited(_cancelSessionStreams());
      setState(() {
        _isSessionActive = false;
      });
      _session = null;
      return;
    }

    if (_shouldAutoReattach && !_isSessionActive && !_isStartingTerminal) {
      _writeTerminal('\r\n[SSH 재연결 감지: 터미널 자동 복구 시도]\r\n');
      unawaited(_startTerminal(autoReconnect: true));
    }
  }

  Future<void> _startTerminal({bool autoReconnect = false}) async {
    final ssh = _sshService ?? Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      if (!autoReconnect) {
        _writeTerminal('SSH 연결 대기 중...\r\n');
      }
      return;
    }

    if (_isSessionActive || _isStartingTerminal) return;
    final generation = ++_sessionGeneration;

    try {
      _isStartingTerminal = true;
      if (!autoReconnect) {
        _writeTerminal('터미널 세션 시작 중...\r\n');
      }
      final session = await ssh.startShell(
        width: _terminal.viewWidth <= 0 ? 80 : _terminal.viewWidth,
        height: _terminal.viewHeight <= 0 ? 24 : _terminal.viewHeight,
      );
      if (!mounted || generation != _sessionGeneration) {
        try {
          session.close();
        } catch (_) {}
        return;
      }
      _session = session;
      setState(() => _isSessionActive = true);
      _manualSessionClose = false;
      _shouldAutoReattach = true;
      await _cancelSessionStreams();
      unawaited(_syncRemoteTerminalSize(session));

      _stdoutSub = session.stdout.listen(
        (data) {
          if (generation != _sessionGeneration) return;
          _writeTerminal(utf8.decode(data, allowMalformed: true));
        },
        onError: (error) {
          if (generation != _sessionGeneration) return;
          _writeTerminal('\r\n[stdout 오류] $error\r\n');
        },
      );

      _stderrSub = session.stderr.listen(
        (data) {
          if (generation != _sessionGeneration) return;
          _writeTerminal(utf8.decode(data, allowMalformed: true));
        },
        onError: (error) {
          if (generation != _sessionGeneration) return;
          _writeTerminal('\r\n[stderr 오류] $error\r\n');
        },
      );

      session.done.then((_) {
        if (generation != _sessionGeneration) return;
        final manualClose = _manualSessionClose;
        _manualSessionClose = false;
        _session = null;
        if (mounted) {
          setState(() => _isSessionActive = false);
          _writeTerminal('\r\n세션이 종료되었습니다.\r\n');
        }

        if (!manualClose &&
            mounted &&
            (_sshService?.isConnected ?? false) &&
            _shouldAutoReattach) {
          Future.delayed(const Duration(seconds: 1), () {
            if (!mounted) return;
            if (generation != _sessionGeneration) return;
            if ((_sshService?.isConnected ?? false) &&
                !_isSessionActive &&
                !_isStartingTerminal &&
                _shouldAutoReattach) {
              _writeTerminal('[세션 자동 복구 시도]\r\n');
              unawaited(_startTerminal(autoReconnect: true));
            }
          });
        }
      });
    } catch (e) {
      if (generation == _sessionGeneration) {
        _writeTerminal('오류 발생: $e\r\n');
      }
    } finally {
      if (generation == _sessionGeneration) {
        _isStartingTerminal = false;
      }
    }
  }

  Future<void> _stopTerminal({bool manual = true}) async {
    if (manual) {
      _shouldAutoReattach = false;
    }
    _manualSessionClose = manual;
    _sessionGeneration += 1;
    _isStartingTerminal = false;
    await _cancelSessionStreams();
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
    final session = _session;
    if (session == null) {
      if (mounted) {
        CustomToast.show(context, "터미널이 연결되지 않았습니다.", isError: true);
      }
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      session.write(utf8.encode(data!.text!));
      if (mounted) {
        CustomToast.show(context, "붙여넣기 완료");
      }
    } else if (mounted) {
      CustomToast.show(context, "클립보드에 텍스트가 없습니다.", isError: true);
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
          border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
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
                color: Colors.grey.withValues(alpha: 0.5),
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
            onTapUp: (details, _) => _handleTerminalTapUp(details),
            onSecondaryTapUp: (details, _) =>
                _handleTerminalSecondaryTapUp(details),
            readOnly: false,
          ),
        ),

        // Fixed Bottom Area (Virtual Keys + Macros)
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
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
