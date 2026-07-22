import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Client for the desktop/local NoPornForever Classifier API
/// (`classifier-api` on port 8765).
///
/// Phone cannot run the heavy HF models comfortably — it calls the same API
/// the browser extension uses. Point [baseUrl] at:
/// - Android emulator → `http://10.0.2.2:8765`
/// - Physical device → `http://<PC-LAN-IP>:8765` (API must bind 0.0.0.0)
class ClassifierApi {
  ClassifierApi._();
  static final ClassifierApi instance = ClassifierApi._();

  static const _prefsKey = 'classifier_api_base';
  static const defaultPort = 8765;

  String _baseUrl = _defaultBaseUrl();
  final http.Client _client = http.Client();

  String get baseUrl => _baseUrl;

  /// Your PC on the LAN (phone on same Wi‑Fi). Emulator can still override in UI
  /// to http://10.0.2.2:8765 if needed.
  static const String lanHostDefault = '192.168.0.149';

  static String _defaultBaseUrl() {
    if (Platform.isAndroid) {
      // Physical phone on same Wi‑Fi → PC classifier-api.
      return 'http://$lanHostDefault:$defaultPort';
    }
    return 'http://$lanHostDefault:$defaultPort';
  }

  Future<void> loadSavedBaseUrl() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_prefsKey);
    if (saved != null && saved.trim().isNotEmpty) {
      _baseUrl = saved.trim().replaceAll(RegExp(r'/$'), '');
    }
  }

  Future<void> setBaseUrl(String url) async {
    _baseUrl = url.trim().replaceAll(RegExp(r'/$'), '');
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, _baseUrl);
  }

  Uri _u(String path) => Uri.parse('$_baseUrl$path');

  Future<Map<String, dynamic>> health() async {
    final res = await _client.get(_u('/health')).timeout(const Duration(seconds: 4));
    if (res.statusCode != 200) {
      throw ClassifierException('health ${res.statusCode}: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<bool> isOnline() async {
    try {
      final h = await health();
      return h['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Labels: `safe` | `nsfw` (distilbert text classifier).
  Future<TextClassResult> classifyText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const TextClassResult(label: 'safe', score: 1, ms: 0);
    }
    final res = await _client
        .post(
          _u('/classify/text'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'text': trimmed}),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw ClassifierException('text ${res.statusCode}: ${res.body}');
    }
    final m = jsonDecode(res.body) as Map<String, dynamic>;
    return TextClassResult(
      label: (m['label'] as String? ?? 'safe').toLowerCase(),
      score: (m['score'] as num?)?.toDouble() ?? 0,
      ms: (m['ms'] as num?)?.toDouble() ?? 0,
      cached: m['cached'] == true,
    );
  }

  /// Image labels from strangerguardhf model.
  Future<ImageClassResult> classifyImageB64(String imageB64) async {
    final res = await _client
        .post(
          _u('/classify/image'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'image_b64': imageB64}),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw ClassifierException('image ${res.statusCode}: ${res.body}');
    }
    final m = jsonDecode(res.body) as Map<String, dynamic>;
    return ImageClassResult(
      ok: m['ok'] != false,
      keep: m['keep'] == true,
      label: m['label'] as String? ?? 'error',
      score: (m['score'] as num?)?.toDouble() ?? 0,
      ms: (m['ms'] as num?)?.toDouble() ?? 0,
      error: m['error'] as String?,
      cached: m['cached'] == true,
    );
  }

  /// True when text intent is explicit NSFW.
  static bool isTextNsfw(TextClassResult r, {double minScore = 0.55}) {
    return r.label == 'nsfw' && r.score >= minScore;
  }

  /// True when image is adult content.
  /// Note: ignore API `keep` — that field is for the browser extension fail-open path.
  static bool isImageNsfw(ImageClassResult r, {double minScore = 0.40}) {
    if (!r.ok) return false;
    final label = r.label.toLowerCase().trim();
    if (label == 'pornography' || label == 'hentai') {
      return r.score >= minScore;
    }
    if (label == 'enticing or sensual') {
      return r.score >= 0.55;
    }
    return false;
  }
}

class TextClassResult {
  const TextClassResult({
    required this.label,
    required this.score,
    this.ms = 0,
    this.cached = false,
  });
  final String label;
  final double score;
  final double ms;
  final bool cached;
}

class ImageClassResult {
  const ImageClassResult({
    required this.ok,
    required this.label,
    required this.score,
    this.keep = false,
    this.ms = 0,
    this.error,
    this.cached = false,
  });
  final bool ok;
  final bool keep;
  final String label;
  final double score;
  final double ms;
  final String? error;
  final bool cached;
}

class ClassifierException implements Exception {
  ClassifierException(this.message);
  final String message;
  @override
  String toString() => message;
}
