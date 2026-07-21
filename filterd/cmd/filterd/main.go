package main

import (
	"encoding/json"
	"flag"
	"fmt"
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

func printUsage() {
	fmt.Fprintf(os.Stderr, `filterd — local DNS domain blocker

Usage:
  filterd run [flags]              Start DNS proxy (optionally take over system DNS)
  filterd test <domain> [flags]    Check whether a domain would be blocked
  filterd status                   Show snapshot path / basic info
  filterd restore-dns              Restore DNS from last snapshot (fail-open recovery)

Common flags (run / test):
  -lists string
        Comma-separated blocklist files (default: filterd/nsfw.txt)
  -allow string
        Allowlist file (default: filterd/allowlist.txt if present)
  -listen string
        Listen address (default 127.0.0.1:8053; use 127.0.0.1:53 + admin for system DNS)
  -upstream string
        Upstream DNS host:port (default 1.1.1.1:53)
  -system-dns
        Point Windows adapters at 127.0.0.1 so browsers use filterd (requires admin)
  -lockdown
        Block outbound DNS to common public resolvers (requires admin)
  -protect
        Browser protection: -system-dns + -lockdown + listen 127.0.0.1:53 (requires admin)
  -json
        JSON output for test

IMPORTANT:
  "filterd test" only checks the list. It does NOT filter Chrome/Edge.
  Browsers use the OS DNS server. Without -protect / -system-dns they ignore filterd.

Examples:
  filterd test xhamster.com                 # list check only
  filterd run                               # dev proxy on :8053 (browser NOT filtered)
  filterd run -protect                      # elevated: filter whole machine
  filterd restore-dns                       # undo system DNS if needed
`)
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

	// Prefer the directory that contains the binary (filterd/), then cwd.
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

// defaultListPaths returns the NSFW blocklist next to the binary / in filterd/.
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

// hoistFlags moves -flag / --flag tokens (and their values) before positionals
// so `test example.com -lists x` works with the Go flag package.
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
			// flag with separate value
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

	// Browsers only see filterd if the OS sends DNS to us on :53.
	listenAddr := *listen
	if listenAddr == "" {
		if *systemDNS {
			listenAddr = "127.0.0.1:53"
		} else {
			listenAddr = "127.0.0.1:8053"
		}
	}

	eng, err := loadEngine(*lists, *allow)
	if err != nil {
		return err
	}

	if !*systemDNS {
		log.Printf("")
		log.Printf("*** DEV MODE: browsers will NOT be filtered ***")
		log.Printf("*** filterd is only on %s; your OS DNS is unchanged. ***", listenAddr)
		log.Printf("*** `filterd test` only checks the list file — it does not change the browser. ***")
		log.Printf("*** For browser blocking, run elevated: ***")
		log.Printf("***   filterd run -protect ***")
		log.Printf("*** Also disable Chrome/Edge Secure DNS (use system resolver). ***")
		log.Printf("")
	}

	// Optional Windows system integration
	appliedDNS := false
	appliedLock := false
	appliedBrowserPolicy := false
	if *systemDNS {
		if _, port, err := net.SplitHostPort(listenAddr); err == nil && port != "53" {
			log.Printf("warning: -system-dns points OS at 127.0.0.1 (port 53) but -listen is %s", listenAddr)
		}
		log.Printf("snapshot + apply system DNS → 127.0.0.1 on ALL adapters (snapshot %s)", *snapshotPath)
		if err := win.SnapshotAndApply(*snapshotPath); err != nil {
			return fmt.Errorf("system-dns: %w (run PowerShell/Terminal as Administrator)", err)
		}
		if bad, err := win.VerifyLocalhostDNS(); err != nil {
			log.Printf("verify DNS: %v", err)
		} else if len(bad) > 0 {
			log.Printf("WARNING: some adapters still not on localhost DNS (browser may bypass):")
			for _, b := range bad {
				log.Printf("  - %s", b)
			}
		} else {
			log.Printf("verified: all adapters use only 127.0.0.1 / ::1")
		}
		log.Printf("disabling Chrome/Edge Secure DNS + forcing ProxyMode=direct (blocks many VPN extensions)")
		if err := win.DisableBrowserSecureDNS(); err != nil {
			log.Printf("warning: could not set browser policies: %v", err)
			log.Printf("  manually: turn off Secure DNS; install extension/ Domain Guard for VPN bypass")
		} else {
			appliedBrowserPolicy = true
			log.Printf("Chrome/Edge: DoH off, ProxyMode=direct (restart browser)")
			log.Printf("VPN extensions still need: load unpacked extension/ (Domain Guard) — see extension/README.md")
		}
		if err := win.FlushDNS(); err != nil {
			log.Printf("flush DNS cache: %v (continuing)", err)
		}
		appliedDNS = true
	}
	if *lockdown {
		host, _, err := net.SplitHostPort(*upstream)
		if err != nil {
			host = *upstream
		}
		log.Printf("enabling DNS lockdown (public DNS :53 + DoH :443; upstream %s exempt on :53)", host)
		if err := win.EnableDNSLockdown(host); err != nil {
			return fmt.Errorf("lockdown: %w (try running as Administrator)", err)
		}
		appliedLock = true
	}

	proxy, err := core.NewProxy(core.ProxyConfig{
		ListenAddr: listenAddr,
		Upstream:   *upstream,
		Engine:     eng,
	})
	if err != nil {
		return err
	}

	// Fail-open cleanup on signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	cleanup := func() {
		if appliedLock {
			if err := win.DisableDNSLockdown(); err != nil {
				log.Printf("disable lockdown: %v", err)
			}
		}
		if appliedBrowserPolicy {
			if err := win.RestoreBrowserSecureDNS(); err != nil {
				log.Printf("restore browser DNS policy: %v", err)
			}
		}
		if appliedDNS {
			if err := win.RestoreFromFile(*snapshotPath); err != nil {
				log.Printf("restore DNS: %v — run: filterd restore-dns", err)
			} else {
				log.Printf("restored system DNS from snapshot")
			}
			_ = win.FlushDNS()
		}
	}

	go func() {
		sig := <-sigCh
		log.Printf("signal %v — shutting down (fail-open restore)", sig)
		_ = proxy.Shutdown()
		cleanup()
		os.Exit(0)
	}()

	log.Printf("starting proxy listen=%s upstream=%s system_dns=%v lockdown=%v",
		listenAddr, *upstream, *systemDNS, *lockdown)
	if *systemDNS {
		log.Printf("browser tip: fully quit Chrome/Edge (not just the tab) then reopen so DoH policy applies")
	}
	err = proxy.ListenAndServe()
	cleanup()
	return err
}

func cmdStatus(args []string) error {
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
	if err := win.RestoreFromFile(*snapshotPath); err != nil {
		return err
	}
	_ = win.DisableDNSLockdown()
	_ = win.RestoreBrowserSecureDNS()
	_ = win.FlushDNS()
	fmt.Println("DNS restored from snapshot; lockdown + browser DoH policies cleared.")
	return nil
}
