import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

class WebRtcDriveScreen extends StatefulWidget {
  final String hostIp;

  const WebRtcDriveScreen({
    super.key,
    required this.hostIp,
  });

  @override
  State<WebRtcDriveScreen> createState() => _WebRtcDriveScreenState();
}

class _WebRtcDriveScreenState extends State<WebRtcDriveScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  String? _errorText;

  Uri get _baseUri => Uri(
        scheme: 'http',
        host: widget.hostIp,
        port: 7000,
      );

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _isLoading = true;
              _errorText = null;
            });
          },
          onPageFinished: (_) async {
            await _applyCameraFocusedLayout();
            if (!mounted) return;
            setState(() => _isLoading = false);
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _errorText = '로드 실패: ${error.description}';
            });
          },
        ),
      )
      ..loadRequest(_baseUri);
  }

  Future<void> _applyCameraFocusedLayout() async {
    const script = '''
(() => {
  const run = () => {
    try {
      if (typeof showPage === 'function') {
        showPage('home', false);
      }
      const topbar = document.querySelector('.topbar');
      if (topbar) topbar.style.display = 'none';

      const pageHome = document.getElementById('pageHome');
      if (pageHome) {
        pageHome.style.display = '';
        pageHome.style.padding = '0';
        pageHome.style.margin = '0';
        pageHome.style.border = 'none';
        pageHome.style.borderRadius = '0';
        pageHome.style.background = '#000';
      }

      const pageSetting = document.getElementById('pageSetting');
      if (pageSetting) pageSetting.style.display = 'none';
      const pageCar = document.getElementById('pageCar');
      if (pageCar) pageCar.style.display = 'none';
      const pageTools = document.getElementById('pageTools');
      if (pageTools) pageTools.style.display = 'none';
      const pageBranch = document.getElementById('pageBranch');
      if (pageBranch) pageBranch.style.display = 'none';

      const rtcCard = document.getElementById('rtcCard');
      if (rtcCard) {
        rtcCard.style.display = 'block';
        rtcCard.style.margin = '0';
        rtcCard.style.padding = '0';
        rtcCard.style.border = 'none';
        rtcCard.style.borderRadius = '0';
        rtcCard.style.background = '#000';
      }

      if (pageHome) {
        Array.from(pageHome.children).forEach((node) => {
          if (node && node.id === 'rtcCard') return;
          if (node) node.style.display = 'none';
        });
      }

      const rtcTitle = document.getElementById('webrtcTitle');
      if (rtcTitle) rtcTitle.style.display = 'none';
      const rtcFsBtn = document.getElementById('btnRtcFs');
      if (rtcFsBtn) rtcFsBtn.style.display = 'none';

      const rtcWrap = document.getElementById('rtcWrap');
      if (rtcWrap) {
        rtcWrap.style.width = '100%';
        rtcWrap.style.minHeight = '100vh';
      }

      const rtcVideo = document.getElementById('rtcVideo');
      if (rtcVideo) {
        rtcVideo.style.display = 'block';
        rtcVideo.style.width = '100%';
        rtcVideo.style.height = 'auto';
        rtcVideo.style.maxHeight = 'none';
      }
    } catch (_) {}
  };
  run();
  setTimeout(run, 350);
  setTimeout(run, 1200);
})();
''';
    await _controller.runJavaScript(script);
  }

  Future<void> _reload() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });
    await _controller.reload();
  }

  Future<void> _openInBrowser() async {
    await launchUrl(
      _baseUri,
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('주행화면 (${widget.hostIp})'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '브라우저로 열기',
            onPressed: _openInBrowser,
            icon: const Icon(Icons.open_in_browser),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black26,
                child: Center(
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
          if (_errorText != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _errorText!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
