import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/cmake.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart' show Mode;
import 'package:re_highlight/styles/stackoverflow-light.dart';
import 'package:re_highlight/styles/tokyo-night-dark.dart';

import '../../services/ssh_service.dart';
import '../../widgets/custom_toast.dart';

class FileEditorScreen extends StatefulWidget {
  final String filePath;
  final String initialContent;
  final bool initialReadOnly;
  final bool lockReadOnly;
  final bool largeReadOnlyMode;
  final int? fileSizeBytes;

  const FileEditorScreen({
    super.key,
    required this.filePath,
    required this.initialContent,
    this.initialReadOnly = true,
    this.lockReadOnly = false,
    this.largeReadOnlyMode = false,
    this.fileSizeBytes,
  });

  @override
  State<FileEditorScreen> createState() => _FileEditorScreenState();
}

class _SyntaxLanguageSpec {
  final String key;
  final Mode mode;

  const _SyntaxLanguageSpec(this.key, this.mode);
}

class _FileEditorScreenState extends State<FileEditorScreen> {
  static const int _maxHighlightedTextBytes = 2 * 1024 * 1024;

  late final CodeLineEditingController _editorController;
  late final CodeFindController _findController;

  bool _isDirty = false;
  bool _readOnly = true;
  bool _wordWrap = false;
  double _fontSize = 13;
  int _currentLine = 1;
  int _currentColumn = 1;

  String get _originalContent => widget.initialContent;
  String get _fileName {
    final parts = widget.filePath.split('/');
    return parts.isEmpty ? widget.filePath : parts.last;
  }

  @override
  void initState() {
    super.initState();
    _editorController =
        CodeLineEditingController.fromText(widget.initialContent);
    _findController = CodeFindController(_editorController);
    _readOnly = widget.initialReadOnly || widget.lockReadOnly;
    _editorController.addListener(_handleEditorChanged);
    _syncCursorPosition();
  }

  @override
  void dispose() {
    _editorController.removeListener(_handleEditorChanged);
    _findController.dispose();
    _editorController.dispose();
    super.dispose();
  }

  void _handleEditorChanged() {
    if (!mounted) return;
    final dirtyNow = _editorController.text != _originalContent;
    final selection = _editorController.selection;
    final line = selection.extentIndex >= 0 ? selection.extentIndex + 1 : 1;
    final column = selection.extentOffset >= 0 ? selection.extentOffset + 1 : 1;

    if (_isDirty == dirtyNow &&
        _currentLine == line &&
        _currentColumn == column) {
      return;
    }

    setState(() {
      _isDirty = dirtyNow;
      _currentLine = line;
      _currentColumn = column;
    });
  }

  void _syncCursorPosition() {
    final selection = _editorController.selection;
    _currentLine = selection.extentIndex >= 0 ? selection.extentIndex + 1 : 1;
    _currentColumn =
        selection.extentOffset >= 0 ? selection.extentOffset + 1 : 1;
  }

  Future<bool> _confirmCloseIfDirty() async {
    if (!_isDirty) return true;

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('저장하지 않은 변경사항'),
        content: const Text('변경사항을 저장하지 않고 나가시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('저장 안 함'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('저장'),
          ),
        ],
      ),
    );

    if (action == 'discard') return true;
    if (action != 'save') return false;

    await _save();
    return !_isDirty;
  }

  Future<void> _save() async {
    if (_readOnly) {
      CustomToast.show(context, '읽기 전용 모드입니다. 편집 모드를 켜세요.');
      return;
    }

    var createBackup = false;
    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('파일 저장'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('변경 사항을 저장하시겠습니까?'),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    value: createBackup,
                    onChanged: (value) {
                      setStateDialog(() => createBackup = value ?? false);
                    },
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('백업본 만들기 (.backup)'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('저장'),
                ),
              ],
            );
          },
        );
      },
    );

    if (shouldSave != true) return;
    if (!mounted) return;

    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
      final content = _editorController.text;
      await ssh.writeTextFile(widget.filePath, content);
      if (createBackup) {
        await ssh.writeTextFile('${widget.filePath}.backup', content);
      }
      if (!mounted) return;
      setState(() => _isDirty = false);
      CustomToast.show(context, createBackup ? '저장 및 백업 완료' : '저장되었습니다.');
    } catch (e) {
      if (!mounted) return;
      CustomToast.show(context, '저장 실패: $e', isError: true);
    }
  }

  Future<void> _goToLine() async {
    final input = TextEditingController();
    final lineText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('줄 이동'),
        content: TextField(
          controller: input,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: '1 - ${_editorController.lineCount}',
          ),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text.trim()),
            child: const Text('이동'),
          ),
        ],
      ),
    );

    final line = int.tryParse((lineText ?? '').trim());
    if (line == null) return;
    final target = line.clamp(1, _editorController.lineCount) - 1;
    _editorController.selectLine(target);
    _editorController.makeCursorCenterIfInvisible();
  }

  void _toggleReadOnly() {
    if (widget.lockReadOnly && _readOnly) {
      CustomToast.show(context, '대용량 파일은 읽기 전용으로만 열립니다.');
      return;
    }
    setState(() {
      _readOnly = !_readOnly;
    });
    if (!_readOnly) {
      CustomToast.show(context, '편집 모드');
    }
  }

  void _changeFontSize(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(10, 24).toDouble();
    });
  }

  _SyntaxLanguageSpec _resolveSyntaxSpec(String path) {
    final lower = path.toLowerCase();
    final fileName = lower.split('/').last;
    final ext = fileName.contains('.') ? '.${fileName.split('.').last}' : '';

    if (fileName == 'makefile' || fileName.startsWith('makefile.')) {
      return _SyntaxLanguageSpec('makefile', langMakefile);
    }
    if (fileName == 'cmakelists.txt') {
      return _SyntaxLanguageSpec('cmake', langCmake);
    }
    if (fileName.endsWith('.bashrc') ||
        fileName.endsWith('.zshrc') ||
        fileName.endsWith('.profile') ||
        fileName.endsWith('.sh')) {
      return _SyntaxLanguageSpec('bash', langBash);
    }

    switch (ext) {
      case '.dart':
        return _SyntaxLanguageSpec('dart', langDart);
      case '.json':
        return _SyntaxLanguageSpec('json', langJson);
      case '.yaml':
      case '.yml':
        return _SyntaxLanguageSpec('yaml', langYaml);
      case '.xml':
      case '.html':
      case '.svg':
        return _SyntaxLanguageSpec('xml', langXml);
      case '.js':
      case '.mjs':
      case '.cjs':
        return _SyntaxLanguageSpec('javascript', langJavascript);
      case '.ts':
      case '.tsx':
        return _SyntaxLanguageSpec('typescript', langTypescript);
      case '.java':
        return _SyntaxLanguageSpec('java', langJava);
      case '.kt':
      case '.kts':
        return _SyntaxLanguageSpec('kotlin', langKotlin);
      case '.py':
        return _SyntaxLanguageSpec('python', langPython);
      case '.c':
      case '.cc':
      case '.cpp':
      case '.cxx':
      case '.h':
      case '.hpp':
        return _SyntaxLanguageSpec('cpp', langCpp);
      case '.sql':
        return _SyntaxLanguageSpec('sql', langSql);
      case '.md':
      case '.markdown':
        return _SyntaxLanguageSpec('markdown', langMarkdown);
      case '.ini':
      case '.cfg':
      case '.conf':
        return _SyntaxLanguageSpec('ini', langIni);
      case '.properties':
        return _SyntaxLanguageSpec('properties', langProperties);
      case '.diff':
      case '.patch':
        return _SyntaxLanguageSpec('diff', langDiff);
      case '.go':
        return _SyntaxLanguageSpec('go', langGo);
      case '.rs':
        return _SyntaxLanguageSpec('rust', langRust);
      case '.lua':
        return _SyntaxLanguageSpec('lua', langLua);
      case '.nginx':
        return _SyntaxLanguageSpec('nginx', langNginx);
      case '.sh':
      case '.zsh':
      case '.bash':
        return _SyntaxLanguageSpec('shell', langShell);
      default:
        return _SyntaxLanguageSpec('plaintext', langPlaintext);
    }
  }

  CodeHighlightTheme _buildCodeTheme(BuildContext context) {
    final spec = _resolveSyntaxSpec(widget.filePath);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CodeHighlightTheme(
      languages: {
        spec.key: CodeHighlightThemeMode(
          mode: spec.mode,
          maxSize: _maxHighlightedTextBytes,
          maxLineLength: 256 * 1024,
        ),
      },
      theme: isDark ? tokyoNightDarkTheme : stackoverflowLightTheme,
    );
  }

  Widget _buildEditor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CodeEditor(
      controller: _editorController,
      findController: _findController,
      readOnly: _readOnly,
      wordWrap: _wordWrap,
      autofocus: true,
      style: CodeEditorStyle(
        fontSize: _fontSize,
        fontFamily: 'monospace',
        backgroundColor: colors.surface,
        textColor: colors.onSurface,
        cursorLineColor: colors.primary.withValues(alpha: 0.08),
        selectionColor: colors.primary.withValues(alpha: 0.20),
        highlightColor: colors.tertiary.withValues(alpha: 0.20),
        codeTheme: _buildCodeTheme(context),
      ),
      border: Border.all(
        color: Theme.of(context).dividerColor.withValues(alpha: 0.6),
      ),
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      verticalScrollbarWidth: 6,
      horizontalScrollbarHeight: 0,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      indicatorBuilder:
          (context, editingController, chunkController, notifier) {
        return Row(
          children: [
            DefaultCodeLineNumber(
              controller: editingController,
              notifier: notifier,
            ),
            DefaultCodeChunkIndicator(
              width: 16,
              controller: chunkController,
              notifier: notifier,
            ),
          ],
        );
      },
      findBuilder: (context, controller, readOnly) {
        return _EditorFindPanel(
          controller: controller,
          readOnly: readOnly,
        );
      },
      onChanged: (_) {
        // Listener handles dirty/cursor sync. This callback keeps editor shortcut
        // behavior intact and avoids accidental omission of future hooks.
      },
    );
  }

  Widget _buildStatusBar(BuildContext context) {
    final text = _editorController.text;
    final lineCount = _editorController.lineCount;
    final charCount = text.length;
    final codeUnitCount = text.codeUnits.length;
    final colors = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            widget.largeReadOnlyMode
                ? '대용량 읽기 전용'
                : (_readOnly ? '읽기 전용' : '편집 모드'),
            style: style,
          ),
          Text('Ln $_currentLine, Col $_currentColumn', style: style),
          Text('줄 $lineCount', style: style),
          Text('문자 $charCount', style: style),
          Text('코드단위 ${_formatBytes(codeUnitCount)}', style: style),
          if (widget.fileSizeBytes != null)
            Text('파일 ${_formatBytes(widget.fileSizeBytes!)}', style: style),
          if (_isDirty)
            Text(
              '미저장 변경',
              style: style?.copyWith(color: colors.error),
            ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unitIndex = -1;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final fixed = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
    return '${value.toStringAsFixed(fixed)} ${units[unitIndex]}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, _) async {
        final navigator = Navigator.of(context);
        if (didPop) return;
        final canLeave = await _confirmCloseIfDirty();
        if (!mounted || !canLeave) return;
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 8,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                widget.filePath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: Theme.of(context).hintColor),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '찾기',
              icon: const Icon(Icons.search),
              onPressed: _findController.findMode,
            ),
            IconButton(
              tooltip: '바꾸기',
              icon: const Icon(Icons.find_replace),
              onPressed: _readOnly ? null : _findController.replaceMode,
            ),
            IconButton(
              tooltip: _wordWrap ? '줄바꿈 해제' : '줄바꿈',
              icon: Icon(_wordWrap ? Icons.wrap_text : Icons.notes),
              onPressed: () => setState(() => _wordWrap = !_wordWrap),
            ),
            PopupMenuButton<String>(
              tooltip: '옵션',
              onSelected: (value) async {
                switch (value) {
                  case 'edit_mode':
                    _toggleReadOnly();
                    break;
                  case 'save':
                    await _save();
                    break;
                  case 'find':
                    _findController.findMode();
                    break;
                  case 'replace':
                    if (!_readOnly) _findController.replaceMode();
                    break;
                  case 'goto':
                    await _goToLine();
                    break;
                  case 'font_up':
                    _changeFontSize(1);
                    break;
                  case 'font_down':
                    _changeFontSize(-1);
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  value: 'edit_mode',
                  enabled: !(widget.lockReadOnly && _readOnly),
                  child: Text(
                    widget.lockReadOnly && _readOnly
                        ? '읽기 전용(고정)'
                        : (_readOnly ? '편집 모드' : '읽기 전용 전환'),
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'save',
                  enabled: !_readOnly && _isDirty,
                  child: const Text('저장'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'goto',
                  child: Text('줄 이동'),
                ),
                const PopupMenuItem<String>(
                  value: 'font_up',
                  child: Text('글자 크게'),
                ),
                const PopupMenuItem<String>(
                  value: 'font_down',
                  child: Text('글자 작게'),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: _buildEditor(context),
                ),
              ),
              _buildStatusBar(context),
            ],
          ),
        ),
        floatingActionButton: (!_readOnly && _isDirty)
            ? FloatingActionButton.small(
                onPressed: _save,
                tooltip: '저장',
                child: const Icon(Icons.save),
              )
            : null,
      ),
    );
  }
}

class _EditorFindPanel extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;
  final bool readOnly;

  const _EditorFindPanel({
    required this.controller,
    required this.readOnly,
  });

  @override
  Size get preferredSize {
    final state = controller.value;
    if (state == null) return Size.zero;
    return Size.fromHeight(state.replaceMode ? 92 : 52);
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.value;
    if (state == null) return const SizedBox.shrink();

    final result = state.result;
    final resultText = result == null
        ? '0/0'
        : '${result.matches.isEmpty ? 0 : result.index + 1}/${result.matches.length}';

    final panelColor = Theme.of(context).colorScheme.surfaceContainerHighest;

    Widget actionIcon({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
    }) {
      return IconButton(
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
      );
    }

    Widget textInput({
      required TextEditingController textController,
      required FocusNode focusNode,
      required String hint,
    }) {
      return TextField(
        controller: textController,
        focusNode: focusNode,
        maxLines: 1,
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: textInput(
                  textController: controller.findInputController,
                  focusNode: controller.findInputFocusNode,
                  hint: '찾기',
                ),
              ),
              const SizedBox(width: 8),
              Text(resultText, style: Theme.of(context).textTheme.bodySmall),
              TextButton(
                onPressed: controller.toggleCaseSensitive,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Aa',
                  style: TextStyle(
                    fontWeight: state.option.caseSensitive
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
              ),
              TextButton(
                onPressed: controller.toggleRegex,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  '.*',
                  style: TextStyle(
                    fontWeight:
                        state.option.regex ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
              actionIcon(
                icon: Icons.keyboard_arrow_up,
                tooltip: '이전',
                onPressed: result == null ? null : controller.previousMatch,
              ),
              actionIcon(
                icon: Icons.keyboard_arrow_down,
                tooltip: '다음',
                onPressed: result == null ? null : controller.nextMatch,
              ),
              actionIcon(
                icon:
                    state.replaceMode ? Icons.expand_less : Icons.find_replace,
                tooltip: state.replaceMode ? '바꾸기 닫기' : '바꾸기',
                onPressed: readOnly ? null : controller.toggleMode,
              ),
              actionIcon(
                icon: Icons.close,
                tooltip: '닫기',
                onPressed: controller.close,
              ),
            ],
          ),
          if (state.replaceMode) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: textInput(
                    textController: controller.replaceInputController,
                    focusNode: controller.replaceInputFocusNode,
                    hint: '바꿀 내용',
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: result == null ? null : controller.replaceMatch,
                  child: const Text('바꾸기'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed:
                      result == null ? null : controller.replaceAllMatches,
                  child: const Text('모두'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
