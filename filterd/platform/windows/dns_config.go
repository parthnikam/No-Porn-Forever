//go:build windows

package windows

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// AdapterDNS is a snapshot of one interface's DNS servers.
type AdapterDNS struct {
	Alias   string   `json:"alias"`
	Family  string   `json:"family"` // "IPv4" or "IPv6"
	Servers []string `json:"servers"`
}

// Snapshot is persisted so we can restore DNS after stop/crash.
type Snapshot struct {
	Adapters []AdapterDNS `json:"adapters"`
}

// DefaultSnapshotPath is where we store previous DNS settings.
func DefaultSnapshotPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "filterd", "dns_snapshot.json")
}

// GetAdapterDNS returns DNS servers for all connected adapters (IPv4 + IPv6).
func GetAdapterDNS() ([]AdapterDNS, error) {
	// PowerShell is reliable across Win10/11 for this.
	ps := `
$ErrorActionPreference = 'Stop'
$out = @()
Get-DnsClientServerAddress -AddressFamily IPv4,IPv6 | Where-Object {
  $_.ServerAddresses -and $_.InterfaceAlias -notmatch 'Loopback'
} | ForEach-Object {
  $out += [pscustomobject]@{
    alias = $_.InterfaceAlias
    family = $_.AddressFamily.ToString()
    servers = @($_.ServerAddresses)
  }
}
$out | ConvertTo-Json -Compress -Depth 4
`
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", ps)
	raw, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("Get-DnsClientServerAddress: %s", string(ee.Stderr))
		}
		return nil, err
	}
	raw = []byte(strings.TrimSpace(string(raw)))
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}

	// PowerShell may return a single object or an array.
	var list []AdapterDNS
	if raw[0] == '{' {
		var one AdapterDNS
		if err := json.Unmarshal(raw, &one); err != nil {
			return nil, err
		}
		list = []AdapterDNS{one}
	} else {
		if err := json.Unmarshal(raw, &list); err != nil {
			return nil, err
		}
	}
	// Normalize family names
	for i := range list {
		f := strings.ToLower(list[i].Family)
		if strings.Contains(f, "v4") || f == "2" {
			list[i].Family = "IPv4"
		} else {
			list[i].Family = "IPv6"
		}
	}
	return list, nil
}

// SaveSnapshot writes adapters to path.
func SaveSnapshot(path string, adapters []AdapterDNS) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(Snapshot{Adapters: adapters}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

// LoadSnapshot reads a previous snapshot.
func LoadSnapshot(path string) (*Snapshot, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Snapshot
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

// ApplyLocalhostDNS points IPv4 DNS at 127.0.0.1 and IPv6 at ::1 for active adapters.
func ApplyLocalhostDNS() error {
	adapters, err := activeInterfaceAliases()
	if err != nil {
		return err
	}
	if len(adapters) == 0 {
		return fmt.Errorf("no active network adapters found")
	}
	for _, alias := range adapters {
		// IPv4
		if err := runNetsh("interface", "ip", "set", "dns", fmt.Sprintf("name=%s", alias), "static", "127.0.0.1", "validate=no"); err != nil {
			// try alternate quoting
			if err2 := runNetsh("interface", "ip", "set", "dns", "name="+alias, "static", "127.0.0.1", "validate=no"); err2 != nil {
				return fmt.Errorf("set IPv4 DNS on %q: %v / %v", alias, err, err2)
			}
		}
		// IPv6 — set to ::1 so queries stay local; if it fails, continue
		_ = runNetsh("interface", "ipv6", "set", "dns", "name="+alias, "static", "::1", "validate=no")
	}
	return nil
}

// RestoreDNS applies a snapshot. Adapters that no longer exist are skipped.
func RestoreDNS(snap *Snapshot) error {
	if snap == nil {
		return fmt.Errorf("nil snapshot")
	}
	var errs []string
	for _, a := range snap.Adapters {
		if len(a.Servers) == 0 {
			// DHCP DNS
			fam := "ip"
			if a.Family == "IPv6" {
				fam = "ipv6"
			}
			if err := runNetsh("interface", fam, "set", "dns", "name="+a.Alias, "dhcp"); err != nil {
				errs = append(errs, fmt.Sprintf("%s %s dhcp: %v", a.Alias, a.Family, err))
			}
			continue
		}
		fam := "ip"
		if a.Family == "IPv6" {
			fam = "ipv6"
		}
		// first server with set, rest with add
		if err := runNetsh("interface", fam, "set", "dns", "name="+a.Alias, "static", a.Servers[0], "validate=no"); err != nil {
			errs = append(errs, fmt.Sprintf("%s %s set %s: %v", a.Alias, a.Family, a.Servers[0], err))
			continue
		}
		for i := 1; i < len(a.Servers); i++ {
			_ = runNetsh("interface", fam, "add", "dns", "name="+a.Alias, a.Servers[i], fmt.Sprintf("index=%d", i+1), "validate=no")
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("restore partial failures: %s", strings.Join(errs, "; "))
	}
	return nil
}

// SnapshotAndApply saves current DNS then points adapters at localhost.
func SnapshotAndApply(snapshotPath string) error {
	current, err := GetAdapterDNS()
	if err != nil {
		return fmt.Errorf("snapshot current DNS: %w", err)
	}
	// If we already point at 127.0.0.1 only, still save what we have
	if err := SaveSnapshot(snapshotPath, current); err != nil {
		return err
	}
	return ApplyLocalhostDNS()
}

// RestoreFromFile loads snapshot and restores DNS.
func RestoreFromFile(snapshotPath string) error {
	snap, err := LoadSnapshot(snapshotPath)
	if err != nil {
		return err
	}
	return RestoreDNS(snap)
}

func activeInterfaceAliases() ([]string, error) {
	ps := `
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceAlias -notmatch 'Loopback' } | Select-Object -ExpandProperty Name
`
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", ps)
	raw, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var aliases []string
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			aliases = append(aliases, line)
		}
	}
	return aliases, nil
}

func runNetsh(args ...string) error {
	cmd := exec.Command("netsh", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("netsh %s: %v (%s)", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}
