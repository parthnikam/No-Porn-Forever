//go:build !windows

package windows

import "fmt"

// Stubs so non-Windows builds of the module still compile platform imports
// if someone builds with wrong tags. The main CLI uses build tags instead.

func DefaultSnapshotPath() string { return "" }

func InstallDir() string { return "" }
func LogDir() string     { return "" }
func DefaultLogPath() string {
	return ""
}

type AdapterDNS struct {
	Alias   string   `json:"alias"`
	Family  string   `json:"family"`
	Servers []string `json:"servers"`
}

type Snapshot struct {
	Adapters []AdapterDNS `json:"adapters"`
}

func GetAdapterDNS() ([]AdapterDNS, error)                    { return nil, errOS() }
func SaveSnapshot(string, []AdapterDNS) error                 { return errOS() }
func LoadSnapshot(string) (*Snapshot, error)                  { return nil, errOS() }
func ApplyLocalhostDNS() error                                { return errOS() }
func RestoreDNS(*Snapshot) error                              { return errOS() }
func SnapshotAndApply(string) error                           { return errOS() }
func RestoreFromFile(string) error                            { return errOS() }
func EnableDNSLockdown(string) error                          { return errOS() }
func DisableDNSLockdown() error                               { return errOS() }
func FlushDNS() error                                         { return errOS() }
func DisableBrowserSecureDNS() error                          { return errOS() }
func RestoreBrowserSecureDNS() error                          { return errOS() }
func DisableSmartMultiHomedResolution() error                 { return errOS() }
func EnableSmartMultiHomedResolution() error                  { return errOS() }
func VerifyLocalhostDNS() ([]string, error)                   { return nil, errOS() }
func IsWindowsService() (bool, error)                         { return false, nil }
func InstallService(string, []string) error                   { return errOS() }
func UninstallService() error                                 { return errOS() }
func StartService() error                                     { return errOS() }
func StopService() error                                      { return errOS() }
func QueryServiceState() (string, bool, error)                { return "not_installed", false, errOS() }
func RunService(ServiceRunner) error                          { return errOS() }
func CopyInstallFiles([]string) (string, error)               { return "", errOS() }

type ServiceRunner func(stop <-chan struct{}) error

const (
	ServiceName        = "NoPornForeverFilterd"
	ServiceDisplayName = "NoPornForever DNS Filter (filterd)"
)

func errOS() error { return fmt.Errorf("windows DNS helpers are only available on Windows") }
