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
/// On hit: lock UI and optionally force-close the app.
class ContentGuardian {
  ContentGuardian._();
  static final ContentGuardian instance = ContentGuardian._();

  final ClassifierApi api = ClassifierApi.instance;
  final ScreenCapture capture = ScreenCapture.instance;

  final ValueNotifier<GuardianState> state =
      ValueNotifier(GuardianState.idle);
  final ValueNotifier<String> statusLine =
      ValueNotifier('Guardian off');
  final ValueNotifier<GuardianEvent?> lastHit = ValueNotifier(null);
  final ValueNotifier<int> textChecks = ValueNotifier(0);
  final ValueNotifier<int> screenChecks = ValueNotifier(0);

  Timer? _textDebounce;
  Timer? _screenTimer;
  StreamSubscription? _frameSub;
  bool _classifyingFrame = false;
  bool _enabled = false;
  bool _forceExitOnHit = true;
  Duration screenInterval = const Duration(seconds: 4);

  VoidCallback? onLockout;

  bool get enabled => _enabled;

  Future<void> configure({
    required bool enabled,
    bool forceExitOnHit = true,
    Duration? screenEvery,
  }) async {
    _forceExitOnHit = forceExitOnHit;
    if (screenEvery != null) screenInterval = screenEvery;
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
    _screenTimer?.cancel();
    await _frameSub?.cancel();
    _frameSub = null;
    await capture.stop();
    if (state.value != GuardianState.locked) {
      state.value = GuardianState.idle;
      statusLine.value = 'Guardian off';
    }
  }

  /// Call from any text field (search box, URL bar, demo input).
  void watchText(String text, {String source = 'text'}) {
    if (!_enabled || state.value == GuardianState.locked) return;
    _textDebounce?.cancel();
    final t = text.trim();
    if (t.length < 3) return;
    _textDebounce = Timer(const Duration(milliseconds: 650), () {
      unawaited(_classifyText(t, source: source));
    });
  }

  /// Immediate check (submit / URL navigate).
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
      // Fail-open for connectivity — do not brick typing offline.
    }
    return false;
  }

  Future<void> _startScreenLoop() async {
    if (!Platform.isAndroid) {
      statusLine.value =
          'Screen guard: Android MediaProjection only (iOS: use Safe Browser)';
      return;
    }
    try {
      final ok = await capture.start();
      if (!ok) {
        statusLine.value = 'Screen capture permission denied';
        return;
      }
      await _frameSub?.cancel();
      _frameSub = capture.frames.listen((b64) {
        unawaited(_onFrame(b64));
      });
      statusLine.value = 'Screen + text guardian active';
    } catch (e) {
      statusLine.value = 'Screen capture failed: $e';
    }
  }

  Future<void> _onFrame(String b64) async {
    if (!_enabled || _classifyingFrame || state.value == GuardianState.locked) {
      return;
    }
    _classifyingFrame = true;
    try {
      statusLine.value = 'Scanning screen…';
      final r = await api.classifyImageB64(b64);
      screenChecks.value = screenChecks.value + 1;
      if (!r.ok) {
        statusLine.value = 'Screen soft-fail: ${r.error ?? r.label}';
        return;
      }
      statusLine.value =
          'Screen: ${r.label} ${(r.score * 100).toStringAsFixed(0)}%';
      if (ClassifierApi.isImageNsfw(r)) {
        await _trip(
          GuardianEvent(
            reason: 'NSFW on screen',
            detail: 'Image classifier: ${r.label}',
            source: 'screen',
            label: r.label,
            score: r.score,
          ),
        );
      }
    } catch (e) {
      statusLine.value = 'Screen API error: $e';
    } finally {
      _classifyingFrame = false;
    }
  }

  /// Classify a one-off JPEG/PNG base64 (e.g. WebView snapshot).
  Future<bool> checkImageB64(String b64, {String source = 'webview'}) async {
    if (!_enabled || state.value == GuardianState.locked) return false;
    try {
      final r = await api.classifyImageB64(b64);
      screenChecks.value = screenChecks.value + 1;
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

  Future<void> _trip(GuardianEvent event) async {
    if (state.value == GuardianState.locked) return;
    state.value = GuardianState.locked;
    lastHit.value = event;
    statusLine.value = 'LOCKED: ${event.reason}';
    onLockout?.call();
    // Haptic + kill path
    await HapticFeedback.heavyImpact();
    if (_forceExitOnHit) {
      // Give lockout UI a moment to paint, then force-close.
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      await stop();
      SystemNavigator.pop();
      // Hard exit if still alive (Android).
      if (Platform.isAndroid) {
        exit(0);
      }
    }
  }

  /// Unlock after lock when force-exit is disabled (settings / parent PIN later).
  void acknowledgeUnlock() {
    lastHit.value = null;
    state.value = _enabled ? GuardianState.watching : GuardianState.idle;
    statusLine.value = _enabled ? 'Guardian watching…' : 'Guardian off';
  }
}
