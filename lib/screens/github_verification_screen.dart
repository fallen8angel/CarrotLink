import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

class GithubVerificationScreen extends StatefulWidget {
  final String verificationUrl;
  final String userCode;

  const GithubVerificationScreen({
    super.key,
    required this.verificationUrl,
    required this.userCode,
  });

  @override
  State<GithubVerificationScreen> createState() => _GithubVerificationScreenState();
}

class _GithubVerificationScreenState extends State<GithubVerificationScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _showCodeInput = true;
  
  // 8자리 코드 입력을 위한 컨트롤러들 (하이픈 제외 8자리)
  final List<TextEditingController> _codeControllers = List.generate(8, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(8, (_) => FocusNode());

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
            });
          },
          onPageFinished: (String url) {
            setState(() {
              _isLoading = false;
            });

            // Check for success URL and close the screen
            if (url.contains('github.com/login/device/success')) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("인증이 완료되었습니다.")),
                );
                Future.delayed(const Duration(seconds: 1), () {
                  if (mounted) Navigator.of(context).pop(true);
                });
              }
            }
          },
          onWebResourceError: (error) {
            debugPrint("WebView Error: ${error.description}");
          },
        ),
      )
      ..setOnConsoleMessage((message) {
        debugPrint("WebView Console: ${message.message}");
      })
      ..loadRequest(Uri.parse(widget.verificationUrl));
  }

  @override
  void dispose() {
    for (var controller in _codeControllers) {
      controller.dispose();
    }
    for (var node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _onCodeChanged(int index, String value) {
    if (value.isNotEmpty) {
      // 다음 칸으로 자동 이동
      if (index < 7) {
        _focusNodes[index + 1].requestFocus();
      } else {
        // 마지막 칸이면 키보드 닫기
        _focusNodes[index].unfocus();
      }
    }
  }

  void _onKeyPressed(int index, RawKeyEvent event) {
    if (event is RawKeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.backspace) {
        if (_codeControllers[index].text.isEmpty && index > 0) {
          // 현재 칸이 비어있고 백스페이스 누르면 이전 칸으로
          _focusNodes[index - 1].requestFocus();
          _codeControllers[index - 1].clear();
        }
      }
    }
  }

  void _pasteCode() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    if (clipboardData?.text != null) {
      String code = clipboardData!.text!.replaceAll('-', '').replaceAll(' ', '').toUpperCase();
      if (code.length >= 8) {
        for (int i = 0; i < 8; i++) {
          _codeControllers[i].text = code[i];
        }
        setState(() {});
      }
    }
  }

  void _copyCodeToClipboard() {
    Clipboard.setData(ClipboardData(text: widget.userCode));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("코드가 복사되었습니다"), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 하이픈 제거한 코드
    final codeWithoutHyphen = widget.userCode.replaceAll('-', '');
    
    return Scaffold(
      appBar: AppBar(
        title: const Text("GitHub 인증"),
        actions: [
          IconButton(
            icon: Icon(_showCodeInput ? Icons.keyboard_hide : Icons.keyboard),
            onPressed: () => setState(() => _showCodeInput = !_showCodeInput),
            tooltip: "코드 입력창 토글",
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          // 코드 입력 UI (상단에 고정)
          if (_showCodeInput)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                border: Border(
                  bottom: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text("인증 코드: ", style: TextStyle(fontSize: 14)),
                      GestureDetector(
                        onTap: _copyCodeToClipboard,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            widget.userCode,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: _copyCodeToClipboard,
                        tooltip: "복사",
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    "아래 칸에 코드를 입력하거나 위 코드를 복사해서 붙여넣으세요",
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 첫 4자리
                      ...List.generate(4, (index) => _buildCodeBox(index, codeWithoutHyphen)),
                      // 하이픈
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text("-", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                      ),
                      // 나머지 4자리
                      ...List.generate(4, (index) => _buildCodeBox(index + 4, codeWithoutHyphen)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _pasteCode,
                    icon: const Icon(Icons.paste, size: 18),
                    label: const Text("클립보드에서 붙여넣기"),
                  ),
                ],
              ),
            ),
          // WebView
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_isLoading)
                  const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeBox(int index, String expectedCode) {
    final isCorrect = index < expectedCode.length && 
                      _codeControllers[index].text.toUpperCase() == expectedCode[index];
    
    return Container(
      width: 36,
      height: 44,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      child: RawKeyboardListener(
        focusNode: FocusNode(),
        onKey: (event) => _onKeyPressed(index, event),
        child: TextField(
          controller: _codeControllers[index],
          focusNode: _focusNodes[index],
          textAlign: TextAlign.center,
          maxLength: 1,
          keyboardType: TextInputType.visiblePassword, // 숫자+영문 키보드
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
            UpperCaseTextFormatter(),
          ],
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: isCorrect ? Colors.green : null,
          ),
          decoration: InputDecoration(
            counterText: "",
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: isCorrect ? Colors.green : Colors.grey,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: isCorrect ? Colors.green : Colors.grey.shade400,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.blue, width: 2),
            ),
            filled: true,
            fillColor: isCorrect ? Colors.green.withOpacity(0.1) : null,
          ),
          onChanged: (value) => _onCodeChanged(index, value),
        ),
      ),
    );
  }
}

// 대문자 변환 포맷터
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
