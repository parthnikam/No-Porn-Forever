//go:build windows

package windows

import (
	"fmt"
	"os/exec"
	"strings"
)

const (
	ruleBlockDNSUDP = "filterd-block-dns-udp"
	ruleBlockDNSTCP = "filterd-block-dns-tcp"
	ruleBlockDoT    = "filterd-block-dot-tcp"
)

// EnableDNSLockdown blocks outbound UDP/TCP 53 and TCP 853 for all processes.
//
// The local filter must then use an upstream that does not need raw port 53
// from this machine OR the filter must run before these rules are applied
// while using a non-53 path (DoH). For the MVP we block raw DNS bypass and
// keep filterd upstream on a fixed IP:53 — Windows Firewall block rules take
// precedence over allow rules, so process exceptions are unreliable.
//
// Practical approach used here:
//   - Block outbound DNS to *common public resolvers* on port 53 (not all destinations).
//   - filterd upstream should be set to an IP NOT in that list, OR we delete
//     the block for the upstream IP.
//
// Simpler MVP: block outbound UDP/TCP 53 to well-known public DNS IPs only.
// Local filterd → 1.1.1.1 would be blocked too if 1.1.1.1 is listed — so we
// either (a) use a less common upstream, or (b) use DoH.
//
// This implementation blocks known public DNS IPs except the configured
// upstream IP (passed in).
func EnableDNSLockdown(upstreamHost string) error {
	// Remove any previous rules first for idempotency.
	_ = DisableDNSLockdown()

	publicDNS := []string{
		"8.8.8.8", "8.8.4.4",
		"1.1.1.1", "1.0.0.1",
		"9.9.9.9", "149.112.112.112",
		"208.67.222.222", "208.67.220.220",
		"64.6.64.6", "64.6.65.6",
		"8.26.56.26", "8.20.247.20",
	}

	// Do not block the upstream host we actually use.
	var blockIPs []string
	for _, ip := range publicDNS {
		if ip == upstreamHost {
			continue
		}
		blockIPs = append(blockIPs, ip)
	}

	// One rule per protocol covering remote IPs via multiple rules (netsh
	// remoteip can take a list).
	remote := strings.Join(blockIPs, ",")
	if remote == "" {
		return nil
	}

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
	names := []string{ruleBlockDNSUDP, ruleBlockDNSTCP, ruleBlockDoT}
	var errs []string
	for _, n := range names {
		cmd := exec.Command("netsh", "advfirewall", "firewall", "delete", "rule", "name="+n)
		out, err := cmd.CombinedOutput()
		// "No rules match" is fine
		if err != nil && !strings.Contains(string(out), "No rules match") {
			errs = append(errs, fmt.Sprintf("%s: %v %s", n, err, strings.TrimSpace(string(out))))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("disable lockdown: %s", strings.Join(errs, "; "))
	}
	return nil
}
