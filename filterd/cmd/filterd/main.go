package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/easypeasy/filterd/core"
	win "github.com/easypeasy/filterd/platform/windows"
)

func main() {
	// When launched by Windows Service Control Manager, jump straight into
	// protect mode — no CLI required.
	if isSvc, err := win.IsWindowsService(); err == nil && isSvc {
		setupServiceLogging()
		err := win.RunService(func(stop <-chan struct{}) error {
			return runProtect(runOptions{
				listen:     "127.0.0.1:53",
				upstream:   "1.1.1.1:53",
				systemDNS:  true,
				lockdown:   true,
				snapshot:   win.DefaultSnapshotPath(),
				stop:       stop,
			})
		})
		if err != nil {
			log.Printf("service error: %v", err)
			os.Exit(1)
		}
		return
	}

	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("filterd: ")

	if len(os.Args) < 2 {
		printUsage()
		os.Exit(2)
	}

	cmd := os.Args[1]
	args := os.Args[2:]

	var err error
	switch cmd {
	case "run":
		err = cmdRun(args)
	case "install":
		err = cmdInstall(args)
	case "uninstall":
		err = cmdUninstall(args)
	case "start":
		err = cmdStart(args)
	case "stop":
		err = cmdStop(args)
	case "test":
		err = cmdTest(args)
	case "status":
		err = cmdStatus(args)
	case "restore-dns":
		err = cmdRestoreDNS(args)
	case "help", "-h", "--help":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n", cmd)
		printUsage()
		os.Exit(2)
	}
	if err != nil {
		log.Printf("error: %v", err)
		os.Exit(1)
	}
}

func setupServiceLogging() {
	_ = os.MkdirAll(win.LogDir(), 0o755)
	logPath := win.DefaultLogPath()
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		log.SetFlags(log.LstdFlags | log.Lmsgprefix)
		log.SetPrefix("filterd: ")
		log.Printf("could not open log file %s: %v", logPath, err)
		return
	}
	// Keep process alive with file open; OS closes on exit.
	log.SetOutput(io.MultiWriter(f, os.Stderr))
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("filterd: ")
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `filterd — local DNS domain blocker (Windows)

Ship / everyday use (Administrator once):
  filterd install                 Install as Windows service + start (auto-runs at boot)
  filterd uninstall               Stop, restore DNS, remove service
  filterd start | stop            Control the installed service
  filterd status                  Service + DNS status

Dev / emergency:
  filterd run -protect            Foreground protect mode (Ctrl+C restores DNS)
  filterd run                     Dev proxy on :8053 (browser NOT filtered)
  filterd test <domain>           Check blocklist only
  filterd restore-dns             Fail-open if DNS left pointing at localhost

Service name: %s
Install dir:  %%ProgramFiles%%\EasyPeasy\filterd
Log file:     %%ProgramData%%\EasyPeasy\filterd\filterd.log

After install, reboot or wait for delayed auto-start — no terminal needed.
`, win.ServiceName)
}

// searchRoots returns directories to look for nsfw.txt / allowlist.txt.
func searchRoots() []string {
	var roots []string
	seen := map[string]bool{}
	add := func(p string) {
		if p == "" {
			return
		}
		abs, err := filepath.Abs(p)
		if err != nil {
			return
		}
		if !seen[abs] {
			seen[abs] = true
			roots = append(roots, abs)
		}
	}

	// Prefer install dir, then binary dir, then cwd.
	add(win.InstallDir())
	if exe, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exe)
		add(exeDir)
		add(filepath.Join(exeDir, ".."))
	}
	if cwd, err := os.Getwd(); err == nil {
		add(cwd)
		add(filepath.Join(cwd, "filterd"))
		add(filepath.Join(cwd, ".."))
	}
	return roots
}

func findFile(name string) string {
	for _, root := range searchRoots() {
		p := filepath.Join(root, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	if st, err := os.Stat(name); err == nil && !st.IsDir() {
		abs, _ := filepath.Abs(name)
		return abs
	}
	return ""
}

func defaultListPaths() []string {
	if p := findFile("nsfw.txt"); p != "" {
		return []string{p}
	}
	return nil
}

func defaultAllowPath() string {
	return findFile("allowlist.txt")
}

func loadEngine(listCSV, allowPath string) (*core.Engine, error) {
	eng := core.NewEngine()

	var lists []string
	if strings.TrimSpace(listCSV) == "" {
		lists = defaultListPaths()
		if len(lists) == 0 {
			return nil, fmt.Errorf("nsfw.txt not found next to filterd (or pass -lists)")
		}
	} else {
		for _, p := range strings.Split(listCSV, ",") {
			p = strings.TrimSpace(p)
			if p != "" {
				lists = append(lists, p)
			}
		}
	}

	for _, p := range lists {
		src := sourceTag(p)
		stats, err := core.LoadListFile(p, src, eng.Block)
		if err != nil {
			return nil, err
		}
		log.Printf("loaded blocklist %s: +%d domains (%d lines, %d skipped, %d dupes) source=%s",
			p, stats.Added, stats.Lines, stats.Skipped, stats.Duplicates, src)
	}

	if strings.TrimSpace(allowPath) == "" {
		allowPath = defaultAllowPath()
	}
	if allowPath != "" {
		if st, err := os.Stat(allowPath); err == nil && !st.IsDir() {
			stats, err := core.LoadListFile(allowPath, "allow", eng.Allow)
			if err != nil {
				return nil, err
			}
			if stats.Added > 0 || stats.Lines > 0 {
				log.Printf("loaded allowlist %s: +%d domains", allowPath, stats.Added)
			}
		}
	}

	log.Printf("engine ready: %d blocked names, %d allow names", eng.Block.Len(), eng.Allow.Len())
	return eng, nil
}

func sourceTag(path string) string {
	base := filepath.Base(path)
	return strings.TrimSuffix(base, filepath.Ext(base))
}

func cmdTest(args []string) error {
	args = hoistFlags(args)
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	lists := fs.String("lists", "", "comma-separated blocklist paths")
	allow := fs.String("allow", "", "allowlist path")
	asJSON := fs.Bool("json", false, "JSON output")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() < 1 {
		return fmt.Errorf("usage: filterd test <domain> [flags]")
	}
	domain := fs.Arg(0)

	eng, err := loadEngine(*lists, *allow)
	if err != nil {
		return err
	}
	d := eng.Check(domain)
	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(d)
	}
	if d.Blocked {
		fmt.Printf("BLOCK  %s  (rule=%s source=%s)\n", d.Domain, d.MatchedRule, d.Source)
	} else if d.AllowedBy != "" {
		fmt.Printf("ALLOW  %s  (allowlist=%s)\n", d.Domain, d.AllowedBy)
	} else {
		fmt.Printf("ALLOW  %s  (not on blocklist)\n", d.Domain)
	}
	return nil
}

func hoistFlags(args []string) []string {
	var flags, pos []string
	boolFlags := map[string]bool{
		"-json": true, "--json": true,
		"-system-dns": true, "--system-dns": true,
		"-lockdown": true, "--lockdown": true,
		"-protect": true, "--protect": true,
		"-h": true, "-help": true, "--help": true,
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			pos = append(pos, args[i+1:]...)
			break
		}
		if strings.HasPrefix(a, "-") && a != "-" {
			flags = append(flags, a)
			if strings.Contains(a, "=") || boolFlags[a] {
				continue
			}
			if i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
				i++
				flags = append(flags, args[i])
			}
			continue
		}
		pos = append(pos, a)
	}
	return append(flags, pos...)
}

type runOptions struct {
	lists     string
	allow     string
	listen    string
	upstream  string
	systemDNS bool
	lockdown  bool
	snapshot  string
	stop      <-chan struct{} // if nil, use OS signals
}

func cmdRun(args []string) error {
	args = hoistFlags(args)
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	lists := fs.String("lists", "", "comma-separated blocklist paths")
	allow := fs.String("allow", "", "allowlist path")
	listen := fs.String("listen", "", "listen address (default 127.0.0.1:8053, or :53 with -system-dns)")
	upstream := fs.String("upstream", "1.1.1.1:53", "upstream DNS host:port")
	systemDNS := fs.Bool("system-dns", false, "point Windows adapters at 127.0.0.1 (REQUIRED for browsers)")
	lockdown := fs.Bool("lockdown", false, "block outbound DNS to common public resolvers")
	protect := fs.Bool("protect", false, "shorthand: -system-dns -lockdown and listen on 127.0.0.1:53")
	snapshotPath := fs.String("snapshot", win.DefaultSnapshotPath(), "DNS snapshot path")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *protect {
		*systemDNS = true
		*lockdown = true
	}

	listenAddr := *listen
	if listenAddr == "" {
		if *systemDNS {
			listenAddr = "127.0.0.1:53"
		} else {
			listenAddr = "127.0.0.1:8053"
		}
	}

	return runProtect(runOptions{
		lists:     *lists,
		allow:     *allow,
		listen:    listenAddr,
		upstream:  *upstream,
		systemDNS: *systemDNS,
		lockdown:  *lockdown,
		snapshot:  *snapshotPath,
		stop:      nil,
	})
}

func runProtect(opt runOptions) error {
	if !opt.systemDNS {
		log.Printf("")
		log.Printf("*** DEV MODE: browsers will NOT be filtered ***")
		log.Printf("*** filterd is only on %s; your OS DNS is unchanged. ***", opt.listen)
		log.Printf("*** For always-on protection: filterd install  (Administrator) ***")
		log.Printf("")
	}

	eng, err := loadEngine(opt.lists, opt.allow)
	if err != nil {
		return err
	}

	appliedDNS := false
	appliedLock := false
	appliedBrowserPolicy := false

	if opt.systemDNS {
		if _, port, err := net.SplitHostPort(opt.listen); err == nil && port != "53" {
			log.Printf("warning: -system-dns points OS at 127.0.0.1 (port 53) but -listen is %s", opt.listen)
		}
		log.Printf("snapshot + apply system DNS → 127.0.0.1 on ALL adapters (snapshot %s)", opt.snapshot)
		if err := win.SnapshotAndApply(opt.snapshot); err != nil {
			return fmt.Errorf("system-dns: %w (run as Administrator / install the service)", err)
		}
		if bad, err := win.VerifyLocalhostDNS(); err != nil {
			log.Printf("verify DNS: %v", err)
		} else if len(bad) > 0 {
			log.Printf("WARNING: some adapters still not on localhost DNS (browser may bypass):")
			for _, b := range bad {
				log.Printf("  - %s", b)
			}
		} else {
			log.Printf("verified: adapters use localhost DNS (IPv4)")
		}
		log.Printf("disabling Chrome/Edge Secure DNS + ProxyMode=direct")
		if err := win.DisableBrowserSecureDNS(); err != nil {
			log.Printf("warning: could not set browser policies: %v", err)
		} else {
			appliedBrowserPolicy = true
		}
		if err := win.FlushDNS(); err != nil {
			log.Printf("flush DNS cache: %v (continuing)", err)
		}
		appliedDNS = true
	}

	if opt.lockdown {
		host, _, err := net.SplitHostPort(opt.upstream)
		if err != nil {
			host = opt.upstream
		}
		log.Printf("enabling DNS lockdown (upstream %s exempt)", host)
		if err := win.EnableDNSLockdown(host); err != nil {
			return fmt.Errorf("lockdown: %w (need Administrator)", err)
		}
		appliedLock = true
	}

	proxy, err := core.NewProxy(core.ProxyConfig{
		ListenAddr: opt.listen,
		Upstream:   opt.upstream,
		Engine:     eng,
	})
	if err != nil {
		return err
	}

	cleanup := func() {
		if appliedLock {
			if err := win.DisableDNSLockdown(); err != nil {
				log.Printf("disable lockdown: %v", err)
			}
		}
		if appliedBrowserPolicy {
			// Leave browser policies in place while the product is "installed".
			// Only strip them on uninstall / restore-dns, not on every service restart.
			// (Re-applying on each start is fine; clearing on brief restart would flash DoH back on.)
			_ = appliedBrowserPolicy
		}
		if appliedDNS {
			// Fail-open: restore DNS when the filter actually stops.
			if err := win.RestoreFromFile(opt.snapshot); err != nil {
				log.Printf("restore DNS: %v — run: filterd restore-dns", err)
			} else {
				log.Printf("restored system DNS from snapshot")
			}
			_ = win.FlushDNS()
		}
	}

	// Stop signal: service channel or Ctrl+C
	stopCh := opt.stop
	var sigCh chan os.Signal
	if stopCh == nil {
		sigCh = make(chan os.Signal, 1)
		signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("starting proxy listen=%s upstream=%s system_dns=%v lockdown=%v",
			opt.listen, opt.upstream, opt.systemDNS, opt.lockdown)
		errCh <- proxy.ListenAndServe()
	}()

	var runErr error
	if stopCh != nil {
		select {
		case <-stopCh:
			log.Printf("service stop requested — shutting down (fail-open restore DNS)")
			_ = proxy.Shutdown()
			runErr = <-errCh
		case runErr = <-errCh:
			log.Printf("proxy exited: %v", runErr)
		}
	} else {
		select {
		case sig := <-sigCh:
			log.Printf("signal %v — shutting down (fail-open restore DNS)", sig)
			_ = proxy.Shutdown()
			runErr = <-errCh
		case runErr = <-errCh:
		}
	}

	cleanup()
	if runErr != nil && !strings.Contains(runErr.Error(), "closed") {
		return runErr
	}
	return nil
}

// cmdInstall copies binary+lists to Program Files and registers an auto-start service.
func cmdInstall(args []string) error {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	lists := fs.String("lists", "", "extra comma-separated list files to copy")
	if err := fs.Parse(args); err != nil {
		return err
	}

	// Collect files to install next to the service binary.
	var toCopy []string
	if p := findFile("nsfw.txt"); p != "" {
		toCopy = append(toCopy, p)
	} else {
		return fmt.Errorf("nsfw.txt not found — place it next to filterd.exe before install")
	}
	if p := findFile("allowlist.txt"); p != "" {
		toCopy = append(toCopy, p)
	}
	if *lists != "" {
		for _, p := range strings.Split(*lists, ",") {
			p = strings.TrimSpace(p)
			if p != "" {
				toCopy = append(toCopy, p)
			}
		}
	}

	// Stop existing instance if running in foreground / old service
	state, installed, _ := win.QueryServiceState()
	if installed && state == "running" {
		log.Printf("stopping existing service...")
		_ = win.StopService()
		time.Sleep(time.Second)
	}

	exe, err := win.CopyInstallFiles(toCopy)
	if err != nil {
		return err
	}
	log.Printf("installed files to %s", win.InstallDir())

	// Service ImagePath: "C:\Program Files\EasyPeasy\filterd\filterd.exe" run -protect
	// (When SCM starts us, IsWindowsService is true and we ignore CLI — but
	// keeping run -protect makes sc qc readable and allows manual start.)
	if err := win.InstallService(exe, []string{"run", "-protect"}); err != nil {
		return err
	}
	log.Printf("Windows service %q registered (Automatic, delayed start, restart on failure)", win.ServiceName)

	if err := win.StartService(); err != nil {
		return fmt.Errorf("service installed but start failed: %w", err)
	}
	log.Printf("service started — DNS protection is active")
	log.Printf("log: %s", win.DefaultLogPath())
	fmt.Println()
	fmt.Println("OK. filterd will start automatically at every boot.")
	fmt.Println("You can close this window. Manage via services.msc or:")
	fmt.Println("  filterd status | stop | start | uninstall")
	return nil
}

func cmdUninstall(args []string) error {
	_ = args
	log.Printf("stopping service...")
	_ = win.StopService()
	time.Sleep(1500 * time.Millisecond)

	// Always try fail-open DNS restore
	_ = win.DisableDNSLockdown()
	_ = win.RestoreBrowserSecureDNS()
	if err := win.RestoreFromFile(win.DefaultSnapshotPath()); err != nil {
		log.Printf("DNS restore: %v (may already be clean)", err)
	} else {
		log.Printf("restored system DNS")
	}
	_ = win.FlushDNS()

	if err := win.UninstallService(); err != nil {
		// still try to report
		log.Printf("uninstall service: %v", err)
	} else {
		log.Printf("service removed")
	}

	// Leave Program Files bits for forensic/debug; optional wipe:
	// User can delete InstallDir manually. We remove log marker only.
	fmt.Println("OK. filterd service uninstalled; DNS should be restored.")
	fmt.Printf("Files left in %s (delete folder manually if desired).\n", win.InstallDir())
	return nil
}

func cmdStart(args []string) error {
	_ = args
	if err := win.StartService(); err != nil {
		return err
	}
	fmt.Println("service start requested")
	return nil
}

func cmdStop(args []string) error {
	_ = args
	if err := win.StopService(); err != nil {
		return err
	}
	fmt.Println("service stop requested (DNS restore runs on graceful stop)")
	return nil
}

func cmdStatus(args []string) error {
	_ = args
	state, installed, err := win.QueryServiceState()
	if err != nil {
		fmt.Printf("service query: %v\n", err)
	} else if !installed {
		fmt.Printf("service: not installed (run: filterd install)\n")
	} else {
		fmt.Printf("service: %s (%s)\n", state, win.ServiceName)
	}
	fmt.Printf("install dir: %s\n", win.InstallDir())
	fmt.Printf("log file:    %s\n", win.DefaultLogPath())

	path := win.DefaultSnapshotPath()
	fmt.Printf("snapshot path: %s\n", path)
	if st, err := os.Stat(path); err == nil {
		fmt.Printf("snapshot exists: yes (%s, %d bytes)\n", st.ModTime().Format(time.RFC3339), st.Size())
		snap, err := win.LoadSnapshot(path)
		if err == nil {
			fmt.Printf("snapshot adapters: %d\n", len(snap.Adapters))
			for _, a := range snap.Adapters {
				fmt.Printf("  - %s [%s]: %v\n", a.Alias, a.Family, a.Servers)
			}
		}
	} else {
		fmt.Printf("snapshot exists: no\n")
	}
	current, err := win.GetAdapterDNS()
	if err != nil {
		fmt.Printf("current DNS: (unavailable: %v)\n", err)
	} else {
		fmt.Printf("current adapter DNS entries: %d\n", len(current))
		for _, a := range current {
			fmt.Printf("  - %s [%s]: %v\n", a.Alias, a.Family, a.Servers)
		}
	}
	return nil
}

func cmdRestoreDNS(args []string) error {
	fs := flag.NewFlagSet("restore-dns", flag.ContinueOnError)
	snapshotPath := fs.String("snapshot", win.DefaultSnapshotPath(), "DNS snapshot path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	// Prefer stopping service first so it doesn't re-apply DNS
	_, installed, _ := win.QueryServiceState()
	if installed {
		_ = win.StopService()
		time.Sleep(time.Second)
	}
	if err := win.RestoreFromFile(*snapshotPath); err != nil {
		return err
	}
	_ = win.DisableDNSLockdown()
	_ = win.RestoreBrowserSecureDNS()
	_ = win.FlushDNS()
	fmt.Println("DNS restored from snapshot; lockdown + browser DoH policies cleared.")
	if installed {
		fmt.Println("Note: service was stopped. Run filterd start to re-enable protection.")
	}
	return nil
}
