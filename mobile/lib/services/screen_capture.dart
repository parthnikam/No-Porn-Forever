import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Android MediaProjection screen frames as JPEG base64.
/// iOS: not available system-wide (use in-app WebView snapshots instead).
class ScreenCapture {
  ScreenCapture._();
  static final ScreenCapture instance = ScreenCapture._();

  static const _method = MethodChannel('com.nopornforever.filterd/screen');
  static const _events = EventChannel('com.nopornforever.filterd/screen_frames');

  StreamSubscription? _sub;
  final _controller = StreamController<String>.broadcast();

  Stream<String> get frames => _controller.stream;

  bool get supported => Platform.isAndroid;

  Future<Map<String, dynamic>> capabilities() async {
    if (!Platform.isAndroid) {
      return {
        'platform': Platform.operatingSystem,
        'screenCaptureSupported': false,
        'notes':
            'iOS cannot capture other apps\' screens. Use Safe Browser snapshots + text guardian.',
      };
    }
    try {
      final m = await _method.invokeMapMethod<String, dynamic>('capabilities');
      return m ?? {'screenCaptureSupported': true};
    } catch (_) {
      return {'screenCaptureSupported': true};
    }
  }

  /// Starts projection (shows system consent once). Interval in ms.
  Future<bool> start({int intervalMs = 4000, int quality = 55, int maxWidth = 720}) async {
    if (!Platform.isAndroid) return false;
    final ok = await _method.invokeMethod<bool>('start', {
          'intervalMs': intervalMs,
          'quality': quality,
          'maxWidth': maxWidth,
        }) ??
        false;
    if (!ok) return false;
    await _sub?.cancel();
    _sub = _events.receiveBroadcastStream().listen((event) {
      if (event is String && event.isNotEmpty) {
        _controller.add(event);
      } else if (event is Map && event['b64'] is String) {
        _controller.add(event['b64'] as String);
      }
    });
    return true;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    if (Platform.isAndroid) {
      try {
        await _method.invokeMethod('stop');
      } catch (_) {}
    }
  }
}
