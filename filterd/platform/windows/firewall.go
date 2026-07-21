//go:build windows

package windows

import (
	"fmt"
	"os/exec"
	"strings"
)

const (
	ruleBlockDNSUDP  = "filterd-block-dns-udp"
	ruleBlockDNSTCP  = "filterd-block-dns-tcp"
	ruleBlockDoT     = "filterd-block-dot-tcp"
	ruleBlockDoH443  = "filterd-block-doh-443"
	ruleBlockDoH853  = "filterd-block-dot-public"
)

// wellKnownPublicDNS are resolvers apps use to bypass local DNS settings.
// Upstream IP used by filterd itself is exempted from the port-53 blocks.
var wellKnownPublicDNS = []string{
	"8.8.8.8", "8.8.4.4",
	"1.1.1.1", "1.0.0.1",
	"9.9.9.9", "149.112.112.112",
	"208.67.222.222", "208.67.220.220",
	"64.6.64.6", "64.6.65.6",
	"8.26.56.26", "8.20.247.20",
	// Cloudflare / Google DoH anycast often used by Chrome Secure DNS
	"162.159.36.1", "162.159.46.1",
	"104.16.248.249", "104.16.249.249",
}

// EnableDNSLockdown blocks common DNS-bypass paths:
//   - UDP/TCP 53 to public resolvers (except filterd upstream)
//   - TCP 853 (DoT) globally
//   - TCP 443 to well-known DoH resolver IPs (Chrome Secure DNS)
func EnableDNSLockdown(upstreamHost string) error {
	_ = DisableDNSLockdown()

	var blockIPs []string
	for _, ip := range wellKnownPublicDNS {
		if ip == upstreamHost {
			continue
		}
		blockIPs = append(blockIPs, ip)
	}
	remote := strings.Join(blockIPs, ",")
	if remote == "" {
		return nil
	}

	// All public DNS IPs including upstream for DoH-on-443 (filterd uses plain :53).
	dohRemote := strings.Join(wellKnownPublicDNS, ",")

	cmds := [][]string{
		{"advfirewall", "firewall", "add", "rule",
			"name=" + ruleBlockDNSUDP, "dir=out", "action=block",
			"protocol=UDP", "remoteport=53", "remoteip=" + remote, "enable=yes"},
		{"advfirewall", "firewall", "add", "rule",
			"name=" + ruleBlockDNSTCP, "dir=out", "action=block",
			"protocol=TCP", "remoteport=53", "remoteip=" + remote, "enable=yes"},
		{"advfirewall", "firewall", "add", "rule",
			"name=" + ruleBlockDoT, "dir=out", "action=block",
			"protocol=TCP", "remoteport=853", "enable=yes"},
		// Block HTTPS to known DoH anycast IPs (does not block general HTTPS).
		{"advfirewall", "firewall", "add", "rule",
			"name=" + ruleBlockDoH443, "dir=out", "action=block",
			"protocol=TCP", "remoteport=443", "remoteip=" + dohRemote, "enable=yes"},
	}
	for _, args := range cmds {
		if err := runNetsh(args...); err != nil {
			return err
		}
	}
	return nil
}

// DisableDNSLockdown removes filterd firewall rules.
func DisableDNSLockdown() error {
	names := []string{ruleBlockDNSUDP, ruleBlockDNSTCP, ruleBlockDoT, ruleBlockDoH443, ruleBlockDoH853}
	var errs []string
	for _, n := range names {
		cmd := exec.Command("netsh", "advfirewall", "firewall", "delete", "rule", "name="+n)
		out, err := cmd.CombinedOutput()
		if err != nil && !strings.Contains(string(out), "No rules match") {
			errs = append(errs, fmt.Sprintf("%s: %v %s", n, err, strings.TrimSpace(string(out))))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("disable lockdown: %s", strings.Join(errs, "; "))
	}
	return nil
}
