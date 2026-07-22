import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'classifier_api.dart';
import 'screen_capture.dart';

enum GuardianState { idle, watching, locked, error }

class GuardianEvent {
  GuardianEvent({
    required this.reason,
    required this.detail,
    required this.source,
    this.label,
    this.score,
  });
  final String reason;
  final String detail;
  final String source; // text | screen | url
  final String? label;
  final double? score;
}

/// Orchestrates text + screen classification against the desktop Classifier API.
/// Screen trips are primarily handled **natively** (works over Chrome).
class ContentGuardian {
  ContentGuardian._();
  static final ContentGuardian instance = ContentGuardian._();

  final ClassifierApi api = ClassifierApi.instance;
  final ScreenCapture capture = ScreenCapture.instance;

  final ValueNotifier<GuardianState> state = ValueNotifier(GuardianState.idle);
  final ValueNotifier<String> statusLine = ValueNotifier('Guardian off');
  final ValueNotifier<GuardianEvent?> lastHit = ValueNotifier(null);
  final ValueNotifier<int> textChecks = ValueNotifier(0);
  final ValueNotifier<int> screenChecks = ValueNotifier(0);

  Timer? _textDebounce;
  StreamSubscription? _eventSub;
  bool _enabled = false;
  bool _forceExitOnHit = true;

  VoidCallback? onLockout;

  bool get enabled => _enabled;

  Future<void> configure({
    required bool enabled,
    bool forceExitOnHit = true,
    Duration? screenEvery,
  }) async {
    _forceExitOnHit = forceExitOnHit;
    if (enabled) {
      await start();
    } else {
      await stop();
    }
  }

  Future<void> start() async {
    if (_enabled) return;
    _enabled = true;
    state.value = GuardianState.watching;
    statusLine.value = 'Guardian watching…';
    await _startScreenLoop();
  }

  Future<void> stop() async {
    _enabled = false;
    _textDebounce?.cancel();
    await _eventSub?.cancel();
    _eventSub = null;
    await capture.stop();
    if (state.value != GuardianState.locked) {
      state.value = GuardianState.idle;
      statusLine.value = 'Guardian off';
    }
  }

  void watchText(String text, {String source = 'text'}) {
    if (!_enabled || state.value == GuardianState.locked) return;
    _textDebounce?.cancel();
    final t = text.trim();
    if (t.length < 3) return;
    _textDebounce = Timer(const Duration(milliseconds: 650), () {
      unawaited(_classifyText(t, source: source));
    });
  }

  Future<bool> checkTextNow(String text, {String source = 'text'}) async {
    if (!_enabled || state.value == GuardianState.locked) return false;
    return _classifyText(text.trim(), source: source);
  }

  Future<bool> _classifyText(String text, {required String source}) async {
    if (text.isEmpty) return false;
    try {
      statusLine.value = 'Checking text…';
      final r = await api.classifyText(text);
      textChecks.value = textChecks.value + 1;
      statusLine.value =
          'Text: ${r.label} ${(r.score * 100).toStringAsFixed(0)}%';
      if (ClassifierApi.isTextNsfw(r)) {
        await _trip(
          GuardianEvent(
            reason: 'Explicit text intent',
            detail: text.length > 120 ? '${text.substring(0, 120)}…' : text,
            source: source,
            label: r.label,
            score: r.score,
          ),
        );
        return true;
      }
    } catch (e) {
      statusLine.value = 'Text API error: $e';
    }
    return false;
  }

  Future<void> _startScreenLoop() async {
    if (!Platform.isAndroid) {
      statusLine.value =
          'Screen guard: Android only (iOS: use Safe Browser)';
      return;
    }
    try {
      final ok = await capture.start(
        intervalMs: 2500,
        quality: 70,
        maxWidth: 960,
        apiBaseUrl: api.baseUrl,
      );
      if (!ok) {
        statusLine.value = 'Screen capture permission denied';
        return;
      }
      await _eventSub?.cancel();
      _eventSub = capture.events.listen(_onScreenEvent);
      statusLine.value = 'Screen guard on · ${api.baseUrl}';
    } catch (e) {
      statusLine.value = 'Screen capture failed: $e';
    }
  }

  void _onScreenEvent(Map<String, dynamic> event) {
    if (!_enabled && state.value != GuardianState.locked) return;
    final type = event['type'] as String? ?? '';
    switch (type) {
      case 'classify':
        screenChecks.value = screenChecks.value + 1;
        final label = event['label'] as String? ?? '';
        final score = (event['score'] as num?)?.toDouble() ?? 0;
        final ok = event['ok'] != false;
        if (!ok) {
          statusLine.value =
              'Screen API: ${event['error'] ?? 'error'}';
        } else {
          statusLine.value =
              'Screen: $label ${(score * 100).toStringAsFixed(0)}%';
        }
        break;
      case 'trip':
        unawaited(
          _trip(
            GuardianEvent(
              reason: event['reason'] as String? ?? 'NSFW on screen',
              detail: event['detail'] as String? ?? '',
              source: 'screen',
              label: event['label'] as String?,
              score: (event['score'] as num?)?.toDouble(),
            ),
            // Native LockoutActivity already force-closes; avoid double-exit race.
            forceExit: false,
          ),
        );
        break;
      case 'status':
        statusLine.value = 'Screen ${event['status'] ?? ''}';
        break;
      case 'frame':
        // Native is classifying; optional silent tick.
        break;
    }
  }

  /// Classify a one-off JPEG/PNG base64 (e.g. WebView snapshot).
  Future<bool> checkImageB64(String b64, {String source = 'webview'}) async {
    if (!_enabled || state.value == GuardianState.locked) return false;
    try {
      final r = await api.classifyImageB64(b64);
      screenChecks.value = screenChecks.value + 1;
      statusLine.value =
          'Page: ${r.label} ${(r.score * 100).toStringAsFixed(0)}%';
      if (ClassifierApi.isImageNsfw(r)) {
        await _trip(
          GuardianEvent(
            reason: 'NSFW content in browser',
            detail: r.label,
            source: source,
            label: r.label,
            score: r.score,
          ),
        );
        return true;
      }
    } catch (e) {
      statusLine.value = 'Image check error: $e';
    }
    return false;
  }

  Future<void> _trip(GuardianEvent event, {bool forceExit = true}) async {
    if (state.value == GuardianState.locked) return;
    state.value = GuardianState.locked;
    lastHit.value = event;
    statusLine.value = 'LOCKED: ${event.reason}';
    onLockout?.call();
    await HapticFeedback.heavyImpact();
    if (_forceExitOnHit && forceExit) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await stop();
      SystemNavigator.pop();
      if (Platform.isAndroid) {
        exit(0);
      }
    }
  }

  void acknowledgeUnlock() {
    lastHit.value = null;
    state.value = _enabled ? GuardianState.watching : GuardianState.idle;
    statusLine.value = _enabled ? 'Guardian watching…' : 'Guardian off';
  }
}
