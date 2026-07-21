import NetworkExtension
import os.log

/// iOS Network Extension entry point — product equivalent of Android VpnService
/// and desktop filterd.
///
/// Wire this file into an Xcode **Packet Tunnel Provider** target:
///   Bundle ID: com.NoPornForever.filterdMobile.FilterDnsExtension
///   App Group: group.com.NoPornForever.filterd
///
/// Flow (parity with Android/desktop):
///   1. Load nsfw.txt + allowlist from App Group / bundle
///   2. Own device DNS (NEDNSSettingsManager or tunnel DNS)
///   3. Match parent labels → NXDOMAIN / sinkhole
///   4. Forward allowed queries to 1.1.1.1
///
/// This scaffold compiles as documentation + future implementation host.
/// Full packet/DNS plumbing is enabled once the target is added in Xcode with
/// the Network Extension entitlement (paid Apple Developer Program).
class PacketTunnelProvider: NEPacketTunnelProvider {
  private let log = OSLog(subsystem: "com.NoPornForever.filterd", category: "tunnel")

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    os_log("NoPornForever tunnel starting", log: log, type: .info)

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.mtu = 1500

    let dns = NEDNSSettings(servers: ["1.1.1.1"])
    // When a full DNS proxy is used, matchdomains empty = all DNS.
    dns.matchDomains = [""]
    settings.dnsSettings = dns

    // Minimal IPv4 settings so the tunnel stays up; production should filter DNS
    // via NEDNSProxyProvider where entitlement allows.
    let ipv4 = NEIPv4Settings(addresses: ["10.83.0.2"], subnetMasks: ["255.255.255.255"])
    ipv4.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = ipv4

    setTunnelNetworkSettings(settings) { error in
      if let error = error {
        os_log("setTunnelNetworkSettings failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
        completionHandler(error)
        return
      }
      os_log("Tunnel settings applied — implement DNS filter loop next", log: self.log, type: .info)
      completionHandler(nil)
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    os_log("Tunnel stopped reason=%{public}d", log: log, type: .info, reason.rawValue)
    completionHandler()
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    completionHandler?(messageData)
  }
}
