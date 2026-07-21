//go:build windows

package windows

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/eventlog"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	// ServiceName is the SCM short name (sc query NoPornForeverFilterd).
	ServiceName = "NoPornForeverFilterd"
	// ServiceDisplayName shown in services.msc
	ServiceDisplayName = "NoPornForever DNS Filter (filterd)"
	// ServiceDescription for services.msc
	ServiceDescription = "Blocks adult/NSFW domains at the local DNS layer. Starts automatically with Windows."
)

// InstallDir is where the shippable binary + lists live after install.
func InstallDir() string {
	return filepath.Join(os.Getenv("ProgramFiles"), "NoPornForever", "filterd")
}

// LogDir is where service logs are written.
func LogDir() string {
	return filepath.Join(os.Getenv("ProgramData"), "NoPornForever", "filterd")
}

// DefaultLogPath is the main service log file.
func DefaultLogPath() string {
	return filepath.Join(LogDir(), "filterd.log")
}

// IsWindowsService reports whether this process was started by the SCM.
func IsWindowsService() (bool, error) {
	return svc.IsWindowsService()
}

// InstallService registers the Windows service and configures auto-start + recovery.
// exePath must be absolute; args are appended after the exe (e.g. ["run", "-protect"]).
func InstallService(exePath string, args []string) error {
	exePath, err := filepath.Abs(exePath)
	if err != nil {
		return err
	}
	if st, err := os.Stat(exePath); err != nil || st.IsDir() {
		return fmt.Errorf("service binary not found: %s", exePath)
	}

	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect SCM (need Administrator): %w", err)
	}
	defer m.Disconnect()

	// Build quoted ImagePath: "C:\Program Files\...\filterd.exe" run -protect
	binPath := windows.EscapeArg(exePath)
	for _, a := range args {
		binPath += " " + windows.EscapeArg(a)
	}

	s, err := m.OpenService(ServiceName)
	if err == nil {
		// Already installed — update config and close.
		defer s.Close()
		cfg, err := s.Config()
		if err != nil {
			return err
		}
		cfg.DisplayName = ServiceDisplayName
		cfg.Description = ServiceDescription
		cfg.StartType = mgr.StartAutomatic
		cfg.BinaryPathName = binPath
		if err := s.UpdateConfig(cfg); err != nil {
			return fmt.Errorf("update service: %w", err)
		}
	} else {
		s, err = m.CreateService(
			ServiceName,
			exePath,
			mgr.Config{
				DisplayName:      ServiceDisplayName,
				Description:      ServiceDescription,
				StartType:        mgr.StartAutomatic,
				ServiceStartName: "", // LocalSystem
				BinaryPathName:   binPath,
			},
			args...,
		)
		if err != nil {
			return fmt.Errorf("create service: %w", err)
		}
		defer s.Close()

		// Event log source for service messages (best-effort).
		_ = eventlog.InstallAsEventCreate(ServiceName, eventlog.Error|eventlog.Warning|eventlog.Info)
	}

	// Restart on failure: 5s, 30s, 60s — survives Task Manager "End task" on the process
	// for the common case (SCM restarts the service).
	if err := setServiceRecovery(s); err != nil {
		// Non-fatal: service still works without recovery actions.
		fmt.Fprintf(os.Stderr, "filterd: warning: could not set recovery actions: %v\n", err)
	}

	// Delayed auto-start reduces boot races with networking.
	if err := setDelayedAutoStart(s, true); err != nil {
		fmt.Fprintf(os.Stderr, "filterd: warning: delayed auto-start: %v\n", err)
	}

	return nil
}

// UninstallService stops (if running) and deletes the service registration.
func UninstallService() error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect SCM (need Administrator): %w", err)
	}
	defer m.Disconnect()

	s, err := m.OpenService(ServiceName)
	if err != nil {
		return fmt.Errorf("service not installed: %w", err)
	}
	defer s.Close()

	// Best-effort stop
	_, _ = s.Control(svc.Stop)
	for i := 0; i < 30; i++ {
		st, err := s.Query()
		if err != nil {
			break
		}
		if st.State == svc.Stopped {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}

	if err := s.Delete(); err != nil {
		return fmt.Errorf("delete service: %w", err)
	}
	_ = eventlog.Remove(ServiceName)
	return nil
}

// StartService asks SCM to start the service.
func StartService() error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect SCM (need Administrator): %w", err)
	}
	defer m.Disconnect()

	s, err := m.OpenService(ServiceName)
	if err != nil {
		return fmt.Errorf("service not installed — run: filterd install: %w", err)
	}
	defer s.Close()

	st, err := s.Query()
	if err != nil {
		return err
	}
	if st.State == svc.Running {
		return nil
	}
	return s.Start()
}

// StopService asks SCM to stop the service (triggers graceful cleanup).
func StopService() error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect SCM (need Administrator): %w", err)
	}
	defer m.Disconnect()

	s, err := m.OpenService(ServiceName)
	if err != nil {
		return fmt.Errorf("service not installed: %w", err)
	}
	defer s.Close()

	st, err := s.Query()
	if err != nil {
		return err
	}
	if st.State == svc.Stopped {
		return nil
	}
	_, err = s.Control(svc.Stop)
	return err
}

// QueryServiceState returns a short status string for humans.
func QueryServiceState() (state string, installed bool, err error) {
	m, err := mgr.Connect()
	if err != nil {
		return "", false, err
	}
	defer m.Disconnect()

	s, err := m.OpenService(ServiceName)
	if err != nil {
		return "not_installed", false, nil
	}
	defer s.Close()

	st, err := s.Query()
	if err != nil {
		return "", true, err
	}
	switch st.State {
	case svc.Stopped:
		return "stopped", true, nil
	case svc.StartPending:
		return "start_pending", true, nil
	case svc.StopPending:
		return "stop_pending", true, nil
	case svc.Running:
		return "running", true, nil
	case svc.ContinuePending:
		return "continue_pending", true, nil
	case svc.PausePending:
		return "pause_pending", true, nil
	case svc.Paused:
		return "paused", true, nil
	default:
		return fmt.Sprintf("unknown(%d)", st.State), true, nil
	}
}

// ServiceRunner is called when the service enters the Running state.
// It must block until stop is closed or work is finished, then return.
type ServiceRunner func(stop <-chan struct{}) error

type filterService struct {
	run ServiceRunner
	elog *eventlog.Log
}


func (f *filterService) Execute(args []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (ssec bool, errno uint32) {
	const cmds = svc.AcceptStop | svc.AcceptShutdown
	changes <- svc.Status{State: svc.StartPending}

	stop := make(chan struct{})
	errCh := make(chan error, 1)
	go func() {
		errCh <- f.run(stop)
	}()

	changes <- svc.Status{State: svc.Running, Accepts: cmds}
	if f.elog != nil {
		_ = f.elog.Info(1, "NoPornForeverd service running (DNS protect mode)")
	}

loop:
	for {
		select {
		case err := <-errCh:
			if err != nil && f.elog != nil {
				_ = f.elog.Error(1, "filterd exited: "+err.Error())
			}
			break loop
		case c := <-r:
			switch c.Cmd {
			case svc.Interrogate:
				changes <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				changes <- svc.Status{State: svc.StopPending}
				close(stop)
				select {
				case err := <-errCh:
					if err != nil && f.elog != nil {
						_ = f.elog.Warning(1, "filterd stop: "+err.Error())
					}
				case <-time.After(25 * time.Second):
					if f.elog != nil {
						_ = f.elog.Warning(1, "filterd stop timed out")
					}
				}
				break loop
			default:
				// ignore pause etc.
			}
		}
	}

	changes <- svc.Status{State: svc.Stopped}
	return false, 0
}

// RunService blocks as a Windows service named ServiceName.
func RunService(run ServiceRunner) error {
	elog, err := eventlog.Open(ServiceName)
	if err != nil {
		// Continue without event log if source missing.
		elog = nil
	} else {
		defer elog.Close()
	}
	return svc.Run(ServiceName, &filterService{run: run, elog: elog})
}


// CopyInstallFiles copies the running exe + list files into InstallDir().
// Returns the installed exe path.
func CopyInstallFiles(listFiles []string) (installedExe string, err error) {
	srcExe, err := os.Executable()
	if err != nil {
		return "", err
	}
	srcExe, err = filepath.EvalSymlinks(srcExe)
	if err != nil {
		srcExe, _ = os.Executable()
	}

	dir := InstallDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	_ = os.MkdirAll(LogDir(), 0o755)

	dstExe := filepath.Join(dir, "filterd.exe")
	if err := copyFile(srcExe, dstExe); err != nil {
		return "", fmt.Errorf("copy filterd.exe: %w", err)
	}

	for _, src := range listFiles {
		if src == "" {
			continue
		}
		if st, err := os.Stat(src); err != nil || st.IsDir() {
			continue
		}
		dst := filepath.Join(dir, filepath.Base(src))
		if err := copyFile(src, dst); err != nil {
			return "", fmt.Errorf("copy %s: %w", filepath.Base(src), err)
		}
	}
	return dstExe, nil
}


func copyFile(src, dst string) error {
	in, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	// Write to temp then rename so a running service binary can be replaced next reboot
	// (if locked, fall back to direct write).
	tmp := dst + ".new"
	if err := os.WriteFile(tmp, in, 0o755); err != nil {
		return os.WriteFile(dst, in, 0o755)
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(dst)
		if err2 := os.Rename(tmp, dst); err2 != nil {
			_ = os.Remove(tmp)
			return os.WriteFile(dst, in, 0o755)
		}
	}
	return nil
}


func setServiceRecovery(s *mgr.Service) error {
	// Equivalent to: sc failure NoPornForeverFilterd reset= 86400 actions= restart/5000/restart/30000/restart/60000
	actions := []mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 60 * time.Second},
	}
	return s.SetRecoveryActions(actions, 86400)
}


func setDelayedAutoStart(s *mgr.Service, delayed bool) error {
	var d uint32
	if delayed {
		d = 1
	}
	info := windows.SERVICE_DELAYED_AUTO_START_INFO{IsDelayedAutoStartUp: d}
	return windows.ChangeServiceConfig2(
		s.Handle,
		windows.SERVICE_CONFIG_DELAYED_AUTO_START_INFO,
		(*byte)(unsafe.Pointer(&info)),
	)
}