import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'classifier_api.dart';

/// Android MediaProjection + **native** image classification.
///
/// Frames are classified inside [ScreenCaptureService] so trips still fire
/// while Chrome is in the foreground (Flutter is often paused then).
class ScreenCapture {
  ScreenCapture._();
  static final ScreenCapture instance = ScreenCapture._();

  static const _method = MethodChannel('com.nopornforever.filterd/screen');
  static const _events = EventChannel('com.nopornforever.filterd/screen_frames');

  StreamSubscription? _sub;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();

  /// Events: frame | classify | trip | status
  Stream<Map<String, dynamic>> get events => _controller.stream;

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

  /// Starts projection (system consent once). Native service classifies frames.
  Future<bool> start({
    int intervalMs = 2500,
    int quality = 70,
    int maxWidth = 960,
    String? apiBaseUrl,
  }) async {
    if (!Platform.isAndroid) return false;
    final base = apiBaseUrl ?? ClassifierApi.instance.baseUrl;
    final ok = await _method.invokeMethod<bool>('start', {
          'intervalMs': intervalMs,
          'quality': quality,
          'maxWidth': maxWidth,
          'apiBaseUrl': base,
        }) ??
        false;
    if (!ok) return false;
    await _sub?.cancel();
    _sub = _events.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        _controller.add(Map<String, dynamic>.from(event));
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
