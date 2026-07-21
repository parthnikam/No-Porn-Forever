//go:build !windows

package windows

import "fmt"

// Stubs so non-Windows builds of the module still compile platform imports
// if someone builds with wrong tags. The main CLI uses build tags instead.

func DefaultSnapshotPath() string { return "" }

type AdapterDNS struct {
	Alias   string   `json:"alias"`
	Family  string   `json:"family"`
	Servers []string `json:"servers"`
}

type Snapshot struct {
	Adapters []AdapterDNS `json:"adapters"`
}

func GetAdapterDNS() ([]AdapterDNS, error) { return nil, errOS() }
func SaveSnapshot(string, []AdapterDNS) error { return errOS() }
func LoadSnapshot(string) (*Snapshot, error)  { return nil, errOS() }
func ApplyLocalhostDNS() error                { return errOS() }
func RestoreDNS(*Snapshot) error              { return errOS() }
func SnapshotAndApply(string) error           { return errOS() }
func RestoreFromFile(string) error            { return errOS() }
func EnableDNSLockdown(string) error          { return errOS() }
func DisableDNSLockdown() error               { return errOS() }
func FlushDNS() error                         { return errOS() }
func DisableBrowserSecureDNS() error          { return errOS() }
func RestoreBrowserSecureDNS() error          { return errOS() }
func DisableSmartMultiHomedResolution() error { return errOS() }
func EnableSmartMultiHomedResolution() error  { return errOS() }
func VerifyLocalhostDNS() ([]string, error)   { return nil, errOS() }

func errOS() error { return fmt.Errorf("windows DNS helpers are only available on Windows") }
