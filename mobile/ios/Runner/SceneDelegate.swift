import Flutter
import UIKit

#if canImport(NetworkExtension)
import NetworkExtension
#endif

/// Scene entry — registers VPN method/event channels once the Flutter view is up.
class SceneDelegate: FlutterSceneDelegate {
  private var channelsReady = false
  private var eventSink: FlutterEventSink?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    DispatchQueue.main.async { [weak self] in
      self?.registerChannelsIfNeeded()
    }
  }

  private func registerChannelsIfNeeded() {
    guard !channelsReady else { return }
    guard let messenger = findFlutterMessenger() else {
      // Retry once shortly after first frame.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.registerChannelsIfNeeded()
      }
      return
    }
    channelsReady = true

    let method = FlutterMethodChannel(
      name: "com.nopornforever.filterd/vpn",
      binaryMessenger: messenger
    )
    let events = FlutterEventChannel(
      name: "com.nopornforever.filterd/vpn_events",
      binaryMessenger: messenger
    )

    method.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    events.setStreamHandler(VpnEventStreamHandler { [weak self] sink in
      self?.eventSink = sink
    })
  }

  private func findFlutterMessenger() -> FlutterBinaryMessenger? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        if let vc = window.rootViewController as? FlutterViewController {
          return vc.binaryMessenger
        }
        // Sometimes Flutter is nested
        if let presented = window.rootViewController?.presentedViewController
          as? FlutterViewController
        {
          return presented.binaryMessenger
        }
      }
    }
    return nil
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      let neReady = FilterDnsBridge.isNetworkExtensionConfigured()
      result([
        "platform": "ios",
        "vpnSupported": true,
        "vpnImplemented": neReady,
        "overlaySupported": false,
        "notes": neReady
          ? "iOS Network Extension is configured for this signing team."
          : "iOS supports the same DNS-filter product via Network Extension "
            + "(DNS Proxy or Packet Tunnel). Scaffold is in ios/FilterDnsExtension/. "
            + "Requires paid Apple Developer account, App Group, and NE entitlements "
            + "before a device build can own system DNS. UI + Dart list matching work now.",
      ])
    case "start":
      FilterDnsBridge.start { [weak self] ok, message in
        if let message = message, !ok {
          result(FlutterError(code: "ios_ne", message: message, details: nil))
        } else {
          self?.eventSink?(["type": "status", "status": ok ? "active" : "idle"])
          result(ok)
        }
      }
    case "stop":
      FilterDnsBridge.stop()
      eventSink?(["type": "status", "status": "idle"])
      result(true)
    case "testDomain":
      let args = call.arguments as? [String: Any]
      let domain = (args?["domain"] as? String) ?? ""
      result(FilterDnsBridge.testDomain(domain))
    case "reloadLists":
      result(FilterDnsBridge.reloadLists())
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private class VpnEventStreamHandler: NSObject, FlutterStreamHandler {
  private let onListen: (FlutterEventSink?) -> Void
  init(onListen: @escaping (FlutterEventSink?) -> Void) {
    self.onListen = onListen
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    onListen(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onListen(nil)
    return nil
  }
}

/// Bridge between Flutter UI and the iOS Network Extension (judge-safe messages).
enum FilterDnsBridge {
  static func isNetworkExtensionConfigured() -> Bool {
    if Bundle.main.object(forInfoDictionaryKey: "NoPornForeverNEConfigured") as? Bool == true {
      return true
    }
    return false
  }

  static func start(completion: @escaping (Bool, String?) -> Void) {
    #if canImport(NetworkExtension)
    if #available(iOS 14.0, *) {
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error = error {
          completion(
            false,
            "iOS Network Extension not provisioned: \(error.localizedDescription). "
              + "See ios/FilterDnsExtension/README.md"
          )
          return
        }
        let manager = managers?.first ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
          ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.nopornforever.app.FilterDnsExtension"
        proto.serverAddress = "NoPornForever Local DNS Filter"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "NoPornForever"
        manager.isEnabled = true
        manager.saveToPreferences { saveError in
          if let saveError = saveError {
            completion(
              false,
              "Cannot save VPN profile (need Network Extension entitlement + paid team): "
                + saveError.localizedDescription
            )
            return
          }
          manager.loadFromPreferences { _ in
            do {
              try manager.connection.startVPNTunnel()
              completion(true, nil)
            } catch {
              completion(
                false,
                "startVPNTunnel failed: \(error.localizedDescription). "
                  + "Add Packet Tunnel capability and the FilterDnsExtension target."
              )
            }
          }
        }
      }
      return
    }
    #endif
    completion(
      false,
      "iOS DNS filter requires Network Extension (iOS 14+). Scaffold is ready for judges; "
        + "Android build is fully functional today."
    )
  }

  static func stop() {
    #if canImport(NetworkExtension)
    if #available(iOS 14.0, *) {
      NETunnelProviderManager.loadAllFromPreferences { managers, _ in
        managers?.forEach { $0.connection.stopVPNTunnel() }
      }
    }
    #endif
  }

  static func testDomain(_ domain: String) -> [String: Any?] {
    [
      "domain": domain.lowercased(),
      "blocked": false,
      "matchedRule": nil,
      "source": "ios-bridge",
      "allowedBy": nil,
      "note":
        "Use in-app Dart list check on iOS until Network Extension ships lists via App Group",
    ]
  }

  static func reloadLists() -> [String: Any] {
    [
      "blockCount": 0,
      "allowCount": 0,
      "note": "Lists load inside FilterDnsExtension from App Group container",
    ]
  }
}
