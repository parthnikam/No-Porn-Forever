import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/content_guardian.dart';
import '../services/filter_vpn.dart';
import 'app_theme.dart';

class SafeBrowserPage extends StatefulWidget {
  const SafeBrowserPage({super.key});

  @override
  State<SafeBrowserPage> createState() => _SafeBrowserPageState();
}

class _SafeBrowserPageState extends State<SafeBrowserPage> {
  late final WebViewController _controller;
  final _urlCtrl = TextEditingController(text: 'https://www.wikipedia.org');
  final _guardian = ContentGuardian.instance;
  final _repaintKey = GlobalKey();
  Timer? _snapTimer;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _loading = true;
              _urlCtrl.text = url;
            });
          },
          onPageFinished: (url) {
            setState(() => _loading = false);
            unawaited(_onNavigated(url));
          },
          onNavigationRequest: (req) {
            unawaited(_guardian.checkTextNow(req.url, source: 'url'));
            return NavigationDecision.navigate;
          },
        ),
      );
    _load(_urlCtrl.text);
    _snapTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      unawaited(_snapshotAndClassify());
    });
  }

  Future<void> _onNavigated(String url) async {
    final uri = Uri.tryParse(url);
    final q = uri?.queryParameters['q'] ??
        uri?.queryParameters['query'] ??
        uri?.queryParameters['p'];
    if (q != null && q.trim().length >= 3) {
      final hit = await _guardian.checkTextNow(q, source: 'search');
      if (hit && mounted) return;
    }
    await _guardian.checkTextNow(url, source: 'url');
  }

  Future<void> _snapshotAndClassify() async {
    if (!_guardian.enabled) return;
    if (_guardian.state.value == GuardianState.locked) return;
    try {
      final boundary = _repaintKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 0.55);
      final bd = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bd == null) return;
      await _guardian.checkImageB64(base64Encode(bd.buffer.asUint8List()),
          source: 'webview');
    } catch (_) {}
  }

  Future<void> _load(String raw) async {
    var s = raw.trim();
    if (s.isEmpty) return;
    if (!s.contains('://')) {
      if (s.contains(' ') || !s.contains('.')) {
        s = 'https://www.google.com/search?q=${Uri.encodeComponent(s)}';
      } else {
        s = 'https://$s';
      }
    }
    final host = Uri.tryParse(s)?.host;
    if (host != null && host.isNotEmpty) {
      try {
        final r = await FilterVpn.instance.testDomain(host);
        if (r['blocked'] == true && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This site is blocked')),
          );
          return;
        }
      } catch (_) {}
    }
    final intentHit = await _guardian.checkTextNow(s, source: 'url');
    if (intentHit) return;
    await _controller.loadRequest(Uri.parse(s));
  }

  @override
  void dispose() {
    _snapTimer?.cancel();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.skyMist,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.ink,
        elevation: 0,
        title: Row(
          children: [
            Image.asset(
              'assets/logo_square.png',
              width: 28,
              height: 28,
              filterQuality: FilterQuality.none,
            ),
            const SizedBox(width: 10),
            const Text(
              'Safe browser',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Scan page',
            onPressed: _snapshotAndClassify,
            icon: const Icon(Icons.camera_alt_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    style: const TextStyle(color: AppColors.ink, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'Search or website',
                    ),
                    onChanged: (v) => _guardian.watchText(v, source: 'urlbar'),
                    onSubmitted: _load,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => _load(_urlCtrl.text),
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: RepaintBoundary(
              key: _repaintKey,
              child: WebViewWidget(controller: _controller),
            ),
          ),
        ],
      ),
    );
  }
}
