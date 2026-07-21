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
        Comma-separated blocklist files (default: ../dns-blocklists/nsfw.txt,tif.mini.txt relative to repo)
  -allow string
        Allowlist file (optional)
  -listen string
        Listen address (default 127.0.0.1:8053; use 127.0.0.1:53 + admin for system DNS)
  -upstream string
        Upstream DNS host:port (default 1.1.1.1:53)
  -system-dns
        Snapshot adapter DNS and point it at 127.0.0.1 (Windows, requires admin)
  -lockdown
        Block outbound DNS to common public resolvers (Windows firewall; requires admin)
  -json
        JSON output for test

Examples:
  filterd test ads.example.com -lists testdata/sample-block.txt
  filterd run -lists ..\dns-blocklists\nsfw.txt,..\dns-blocklists\tif.mini.txt
  filterd run -listen 127.0.0.1:53 -system-dns -lockdown   # elevated
  filterd restore-dns
`)
}

func defaultListPaths() []string {
	// Prefer repo-relative dns-blocklists when running from filterd/
	candidates := []string{
		filepath.Join("..", "dns-blocklists", "nsfw.txt"),
		filepath.Join("..", "dns-blocklists", "tif.mini.txt"),
		filepath.Join("dns-blocklists", "nsfw.txt"),
		filepath.Join("dns-blocklists", "tif.mini.txt"),
	}
	var found []string
	seen := map[string]bool{}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			abs, _ := filepath.Abs(c)
			if !seen[abs] {
				seen[abs] = true
				found = append(found, c)
			}
		}
	}
	return found
}

func loadEngine(listCSV, allowPath string) (*core.Engine, error) {
	eng := core.NewEngine()

	var lists []string
	if strings.TrimSpace(listCSV) == "" {
		lists = defaultListPaths()
		if len(lists) == 0 {
			return nil, fmt.Errorf("no blocklists found; pass -lists path1,path2")
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

	if allowPath != "" {
		stats, err := core.LoadListFile(allowPath, "allow", eng.Allow)
		if err != nil {
			return nil, err
		}
		log.Printf("loaded allowlist %s: +%d domains", allowPath, stats.Added)
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
	listen := fs.String("listen", "127.0.0.1:8053", "listen address")
	upstream := fs.String("upstream", "1.1.1.1:53", "upstream DNS host:port")
	systemDNS := fs.Bool("system-dns", false, "point Windows adapters at 127.0.0.1")
	lockdown := fs.Bool("lockdown", false, "block outbound DNS to common public resolvers")
	snapshotPath := fs.String("snapshot", win.DefaultSnapshotPath(), "DNS snapshot path")
	if err := fs.Parse(args); err != nil {
		return err
	}

	eng, err := loadEngine(*lists, *allow)
	if err != nil {
		return err
	}

	// Optional Windows system integration
	appliedDNS := false
	appliedLock := false
	if *systemDNS {
		if _, port, err := net.SplitHostPort(*listen); err == nil && port != "53" {
			log.Printf("warning: -system-dns sets OS DNS to 127.0.0.1:53 but -listen is %s", *listen)
		}
		log.Printf("snapshot + apply system DNS → 127.0.0.1 (snapshot %s)", *snapshotPath)
		if err := win.SnapshotAndApply(*snapshotPath); err != nil {
			return fmt.Errorf("system-dns: %w (try running as Administrator)", err)
		}
		appliedDNS = true
	}
	if *lockdown {
		host, _, err := net.SplitHostPort(*upstream)
		if err != nil {
			host = *upstream
		}
		log.Printf("enabling DNS lockdown (common public resolvers; upstream %s exempt)", host)
		if err := win.EnableDNSLockdown(host); err != nil {
			return fmt.Errorf("lockdown: %w (try running as Administrator)", err)
		}
		appliedLock = true
	}

	proxy, err := core.NewProxy(core.ProxyConfig{
		ListenAddr: *listen,
		Upstream:   *upstream,
		Engine:     eng,
	})
	if err != nil {
		return err
	}

	// Fail-open cleanup on signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		log.Printf("signal %v — shutting down (fail-open restore)", sig)
		_ = proxy.Shutdown()
		if appliedLock {
			if err := win.DisableDNSLockdown(); err != nil {
				log.Printf("disable lockdown: %v", err)
			}
		}
		if appliedDNS {
			if err := win.RestoreFromFile(*snapshotPath); err != nil {
				log.Printf("restore DNS: %v — run: filterd restore-dns", err)
			} else {
				log.Printf("restored system DNS from snapshot")
			}
		}
		os.Exit(0)
	}()

	log.Printf("starting proxy listen=%s upstream=%s", *listen, *upstream)
	err = proxy.ListenAndServe()
	// If ListenAndServe returns, try cleanup
	if appliedLock {
		_ = win.DisableDNSLockdown()
	}
	if appliedDNS {
		_ = win.RestoreFromFile(*snapshotPath)
	}
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
	fmt.Println("DNS restored from snapshot; lockdown rules cleared.")
	return nil
}
