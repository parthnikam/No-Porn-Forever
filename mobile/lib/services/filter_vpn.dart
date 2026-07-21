import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Cross-platform VPN / DNS-filter control surface.
///
/// **Dart does the product logic** (lists, matching, UI).
/// **Native OS APIs own the tunnel**:
/// - Android → [VpnService] (local VPN, DNS-only route)
/// - iOS → Network Extension (Packet Tunnel / DNS Proxy) — requires
///   Apple entitlements; scaffolded and queryable for judges.
class FilterVpn {
  FilterVpn._();
  static final FilterVpn instance = FilterVpn._();

  static const _channel = MethodChannel('com.nopornforever.filterd/vpn');
  static const _events = EventChannel('com.nopornforever.filterd/vpn_events');

  final ValueNotifier<VpnStatus> status = ValueNotifier(VpnStatus.idle);
  final ValueNotifier<VpnStats> stats = ValueNotifier(const VpnStats());
  final ValueNotifier<List<String>> recentBlocked =
      ValueNotifier<List<String>>(const []);

  StreamSubscription? _sub;
  bool _listening = false;

  Future<PlatformCapabilities> capabilities() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('capabilities');
      if (m == null) return PlatformCapabilities.unknown();
      return PlatformCapabilities.fromMap(m);
    } on MissingPluginException {
      return PlatformCapabilities.unknown();
    } on PlatformException catch (e) {
      return PlatformCapabilities.unknown(error: e.message);
    }
  }

  Future<void> startListening() async {
    if (_listening) return;
    _listening = true;
    _sub = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final map = Map<String, dynamic>.from(event);
      final type = map['type'] as String? ?? '';
      switch (type) {
        case 'status':
          status.value = VpnStatusX.fromString(map['status'] as String?);
          break;
        case 'stats':
          stats.value = VpnStats(
            queries: (map['queries'] as num?)?.toInt() ?? 0,
            blocked: (map['blocked'] as num?)?.toInt() ?? 0,
            allowed: (map['allowed'] as num?)?.toInt() ?? 0,
          );
          break;
        case 'blocked':
          final domain = map['domain'] as String? ?? '';
          if (domain.isEmpty) break;
          final next = [domain, ...recentBlocked.value];
          if (next.length > 32) next.removeRange(32, next.length);
          recentBlocked.value = next;
          break;
      }
    }, onError: (_) {});
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _listening = false;
  }

  Future<void> prepareAndStart() async {
    await startListening();
    status.value = VpnStatus.connecting;
    try {
      final ok = await _channel.invokeMethod<bool>('start') ?? false;
      if (!ok) {
        status.value = VpnStatus.idle;
        throw FilterVpnException('VPN start was cancelled or failed');
      }
      // Status events from native will update further.
      if (status.value == VpnStatus.connecting) {
        status.value = VpnStatus.active;
      }
    } on PlatformException catch (e) {
      status.value = VpnStatus.error;
      throw FilterVpnException(e.message ?? e.code);
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } finally {
      status.value = VpnStatus.idle;
    }
  }

  Future<Map<String, dynamic>> testDomain(String domain) async {
    final r = await _channel.invokeMapMethod<String, dynamic>(
      'testDomain',
      {'domain': domain},
    );
    return r ?? {'domain': domain, 'blocked': false};
  }

  Future<Map<String, dynamic>> reloadLists() async {
    final r = await _channel.invokeMapMethod<String, dynamic>('reloadLists');
    return r ?? {};
  }

  /// Human-readable platform note for demos / judges.
  String judgePitch() {
    if (kIsWeb) {
      return 'Web cannot run a device VPN. Use Android or iOS builds.';
    }
    if (Platform.isAndroid) {
      return 'Android: full local VPN DNS filter (VpnService) — same nsfw list as desktop filterd.';
    }
    if (Platform.isIOS) {
      return 'iOS: Network Extension scaffold ready; device build needs Apple DNS Proxy / Packet Tunnel entitlement + paid developer team.';
    }
    return 'This UI runs on ${Platform.operatingSystem}; tunnel plugins target Android & iOS.';
  }
}

class FilterVpnException implements Exception {
  FilterVpnException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum VpnStatus { idle, connecting, active, error }

extension VpnStatusX on VpnStatus {
  static VpnStatus fromString(String? s) {
    switch (s) {
      case 'active':
      case 'running':
        return VpnStatus.active;
      case 'connecting':
        return VpnStatus.connecting;
      case 'error':
        return VpnStatus.error;
      default:
        return VpnStatus.idle;
    }
  }

  String get label {
    switch (this) {
      case VpnStatus.idle:
        return 'Off';
      case VpnStatus.connecting:
        return 'Starting…';
      case VpnStatus.active:
        return 'Protected';
      case VpnStatus.error:
        return 'Error';
    }
  }
}

class VpnStats {
  const VpnStats({this.queries = 0, this.blocked = 0, this.allowed = 0});
  final int queries;
  final int blocked;
  final int allowed;
}

class PlatformCapabilities {
  PlatformCapabilities({
    required this.platform,
    required this.vpnSupported,
    required this.vpnImplemented,
    required this.overlaySupported,
    required this.notes,
    this.error,
  });

  final String platform;
  final bool vpnSupported;
  final bool vpnImplemented;
  final bool overlaySupported;
  final String notes;
  final String? error;

  factory PlatformCapabilities.unknown({String? error}) => PlatformCapabilities(
        platform: kIsWeb ? 'web' : Platform.operatingSystem,
        vpnSupported: false,
        vpnImplemented: false,
        overlaySupported: false,
        notes: 'Native bridge not available',
        error: error,
      );

  factory PlatformCapabilities.fromMap(Map<String, dynamic> m) {
    return PlatformCapabilities(
      platform: m['platform'] as String? ?? 'unknown',
      vpnSupported: m['vpnSupported'] as bool? ?? false,
      vpnImplemented: m['vpnImplemented'] as bool? ?? false,
      overlaySupported: m['overlaySupported'] as bool? ?? false,
      notes: m['notes'] as String? ?? '',
      error: m['error'] as String?,
    );
  }
}
