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
	ps := `
$ErrorActionPreference = 'Stop'
$out = @()
Get-DnsClientServerAddress -AddressFamily IPv4,IPv6 | Where-Object {
  $_.InterfaceAlias -notmatch 'Loopback'
} | ForEach-Object {
  $out += [pscustomobject]@{
    alias = $_.InterfaceAlias
    family = $_.AddressFamily.ToString()
    servers = @($_.ServerAddresses)
  }
}
if ($out.Count -eq 0) { '[]' } else { $out | ConvertTo-Json -Compress -Depth 4 }
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

// ApplyLocalhostDNS forces IPv4 DNS to 127.0.0.1 on every non-loopback adapter
// and CLEARS IPv6 DNS servers.
//
// Why not ::1? filterd listens on 127.0.0.1:53 only. Pointing IPv6 DNS at ::1
// with nothing answering there causes Chrome DNS_PROBE_FINISHED_BAD_CONFIG
// (nslookup shows Server Address ::1 → no response).
//
// Critical: Windows "smart multi-homed name resolution" queries DNS on ALL
// interfaces in parallel. If Ethernet still has the router (192.168.x.1) while
// Wi-Fi has 127.0.0.1, the router answer wins and filterd's NXDOMAIN is ignored.
func ApplyLocalhostDNS() error {
	// Set-DnsClientServerAddress replaces the entire server list (not just primary).
	ps := `
$ErrorActionPreference = 'Continue'
$aliases = Get-DnsClient | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } | Select-Object -ExpandProperty InterfaceAlias -Unique
if (-not $aliases) {
  $aliases = Get-NetAdapter | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } | Select-Object -ExpandProperty Name
}
$failed = @()
foreach ($alias in $aliases) {
  try {
    Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses @('127.0.0.1') -ErrorAction Stop
  } catch {
    $failed += "IPv4 ${alias}: $($_.Exception.Message)"
  }
  # Clear IPv6 DNS so Windows does not send queries to ::1 (filterd is IPv4-only).
  try {
    netsh interface ipv6 delete dnsservers name="$alias" all | Out-Null
  } catch {
    # Some adapters have no IPv6 stack; ignore.
  }
}
if ($failed.Count -gt 0) {
  Write-Output ('ERRORS:' + ($failed -join ' | '))
  exit 1
}
Write-Output ('OK adapters=' + ($aliases -join ','))
`
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", ps)
	out, err := cmd.CombinedOutput()
	msg := strings.TrimSpace(string(out))
	if err != nil {
		return fmt.Errorf("apply localhost DNS: %v (%s)", err, msg)
	}
	return nil
}

// RestoreDNS applies a snapshot. Adapters that no longer exist are skipped.
func RestoreDNS(snap *Snapshot) error {
	if snap == nil {
		return fmt.Errorf("nil snapshot")
	}

	// Group by alias+family already in snapshot entries.
	var errs []string
	for _, a := range snap.Adapters {
		alias := a.Alias
		if alias == "" {
			continue
		}
		servers := a.Servers
		// Build PowerShell ServerAddresses array
		var addrList string
		if len(servers) == 0 {
			// Reset to DHCP
			fam := ""
			if a.Family == "IPv6" {
				fam = " -AddressFamily IPv6"
			}
			ps := fmt.Sprintf(
				`Set-DnsClientServerAddress -InterfaceAlias '%s'%s -ResetServerAddresses -ErrorAction SilentlyContinue`,
				escapePS(alias), fam,
			)
			if err := runPS(ps); err != nil {
				errs = append(errs, fmt.Sprintf("%s dhcp: %v", alias, err))
			}
			continue
		}
		quoted := make([]string, len(servers))
		for i, s := range servers {
			quoted[i] = "'" + escapePS(s) + "'"
		}
		addrList = strings.Join(quoted, ",")
		fam := ""
		if a.Family == "IPv6" {
			fam = " -AddressFamily IPv6"
		}
		ps := fmt.Sprintf(
			`Set-DnsClientServerAddress -InterfaceAlias '%s'%s -ServerAddresses @(%s) -ErrorAction SilentlyContinue`,
			escapePS(alias), fam, addrList,
		)
		if err := runPS(ps); err != nil {
			errs = append(errs, fmt.Sprintf("%s set: %v", alias, err))
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
	if err := SaveSnapshot(snapshotPath, current); err != nil {
		return err
	}
	if err := ApplyLocalhostDNS(); err != nil {
		return err
	}
	// Close the multi-interface leak Windows uses by default.
	if err := DisableSmartMultiHomedResolution(); err != nil {
		// Non-fatal but important — log via returned warning-style error only if apply failed
		fmt.Fprintf(os.Stderr, "filterd: warning: could not disable smart multi-homed DNS: %v\n", err)
	}
	return nil
}

// FlushDNS clears the Windows resolver cache so new policy applies immediately.
func FlushDNS() error {
	cmd := exec.Command("ipconfig", "/flushdns")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ipconfig /flushdns: %v (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// RestoreFromFile loads snapshot and restores DNS.
func RestoreFromFile(snapshotPath string) error {
	snap, err := LoadSnapshot(snapshotPath)
	if err != nil {
		return err
	}
	if err := RestoreDNS(snap); err != nil {
		return err
	}
	// Leave SMHNR / browser policies as-is on restore? Better to restore browser policies off.
	// Keep SMHNR disabled only while protecting; re-enable on restore for cleanliness.
	_ = EnableSmartMultiHomedResolution()
	return nil
}

// DisableSmartMultiHomedResolution stops Windows from racing DNS queries across
// every NIC (which bypasses a filter that only rewrote one adapter).
func DisableSmartMultiHomedResolution() error {
	ps := `
$ErrorActionPreference = 'Stop'
$path = 'HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient'
if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
New-ItemProperty -Path $path -Name 'DisableSmartNameResolution' -PropertyType DWord -Value 1 -Force | Out-Null
# Also hardens the service-level switch where present
$p2 = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'
if (Test-Path $p2) {
  New-ItemProperty -Path $p2 -Name 'DisableParallelAandAAAA' -PropertyType DWord -Value 1 -Force | Out-Null
}
`
	return runPS(ps)
}

// EnableSmartMultiHomedResolution undoes DisableSmartMultiHomedResolution.
func EnableSmartMultiHomedResolution() error {
	ps := `
$ErrorActionPreference = 'SilentlyContinue'
Remove-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient' -Name 'DisableSmartNameResolution' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'DisableParallelAandAAAA' -ErrorAction SilentlyContinue
`
	return runPS(ps)
}

// DisableBrowserSecureDNS turns off Chrome/Edge DoH via machine policy so the
// browser uses the OS resolver (filterd) instead of encrypted DNS over HTTPS.
// Also forces ProxyMode=direct so many "VPN extensions" cannot install a proxy
// (they often work by setting chrome.proxy). Pair with the Domain Guard extension.
func DisableBrowserSecureDNS() error {
	ps := `
$ErrorActionPreference = 'Stop'
function Ensure-Key($path) {
  if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}
foreach ($path in @(
  'HKLM:\SOFTWARE\Policies\Google\Chrome',
  'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
)) {
  Ensure-Key $path
  New-ItemProperty -Path $path -Name 'DnsOverHttpsMode' -PropertyType String -Value 'off' -Force | Out-Null
  New-ItemProperty -Path $path -Name 'BuiltInDnsClientEnabled' -PropertyType DWord -Value 0 -Force | Out-Null
  # Prevent VPN extensions from owning the browser proxy stack.
  New-ItemProperty -Path $path -Name 'ProxyMode' -PropertyType String -Value 'direct' -Force | Out-Null
}
`
	return runPS(ps)
}

// RestoreBrowserSecureDNS removes the policies we set (user can re-enable in UI).
func RestoreBrowserSecureDNS() error {
	ps := `
$ErrorActionPreference = 'SilentlyContinue'
foreach ($path in @(
  'HKLM:\SOFTWARE\Policies\Google\Chrome',
  'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
)) {
  Remove-ItemProperty -Path $path -Name 'DnsOverHttpsMode' -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $path -Name 'BuiltInDnsClientEnabled' -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $path -Name 'ProxyMode' -ErrorAction SilentlyContinue
}
`
	return runPS(ps)
}

// VerifyLocalhostDNS reports adapters that still do not point only at loopback.
func VerifyLocalhostDNS() (bad []string, err error) {
	list, err := GetAdapterDNS()
	if err != nil {
		return nil, err
	}
	for _, a := range list {
		if strings.Contains(strings.ToLower(a.Alias), "loopback") {
			continue
		}
		if len(a.Servers) == 0 {
			// empty can mean DHCP inheritance — treat as bad while protecting
			bad = append(bad, fmt.Sprintf("%s [%s]: (empty/DHCP)", a.Alias, a.Family))
			continue
		}
		// IPv6 with empty servers is OK (we clear IPv6 DNS intentionally).
		if a.Family == "IPv6" {
			for _, s := range a.Servers {
				// ::1 is a misconfiguration for our IPv4-only listener.
				if s == "::1" || (s != "" && s != "127.0.0.1") {
					bad = append(bad, fmt.Sprintf("%s [%s]: %v (clear IPv6 DNS; filterd is IPv4-only)", a.Alias, a.Family, a.Servers))
					break
				}
			}
			continue
		}
		for _, s := range a.Servers {
			if s != "127.0.0.1" {
				bad = append(bad, fmt.Sprintf("%s [%s]: %v", a.Alias, a.Family, a.Servers))
				break
			}
		}
	}
	return bad, nil
}

func escapePS(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

func runPS(script string) error {
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func runNetsh(args ...string) error {
	cmd := exec.Command("netsh", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("netsh %s: %v (%s)", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}
