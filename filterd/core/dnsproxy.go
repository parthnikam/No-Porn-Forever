package core

import (
	"context"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/miekg/dns"
)

// ProxyConfig configures the local DNS filter.
type ProxyConfig struct {
	// ListenAddr e.g. "127.0.0.1:53" or "127.0.0.1:5353"
	ListenAddr string
	// Upstream is host:port for plain DNS (e.g. "1.1.1.1:53")
	Upstream string
	// UpstreamTimeout for each upstream query
	UpstreamTimeout time.Duration
	// Engine holds block/allow policy
	Engine *Engine
	// Logger optional; defaults to log.Default()
	Logger *log.Logger
}

// Stats are runtime counters.
type Stats struct {
	Queries   atomic.Uint64
	Blocked   atomic.Uint64
	Allowed   atomic.Uint64
	UpstreamE atomic.Uint64
}

// Proxy is a filtering DNS server.
type Proxy struct {
	cfg       ProxyConfig
	udpServer *dns.Server
	tcpServer *dns.Server
	stats     Stats
	log       *log.Logger

	mu       sync.Mutex
	lastHits []string // ring of recent blocked domains
}

// NewProxy builds a proxy (does not start listening).
func NewProxy(cfg ProxyConfig) (*Proxy, error) {
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = "127.0.0.1:8053"
	}
	if cfg.Upstream == "" {
		cfg.Upstream = "1.1.1.1:53"
	}
	if cfg.UpstreamTimeout <= 0 {
		cfg.UpstreamTimeout = 3 * time.Second
	}
	if cfg.Engine == nil {
		return nil, fmt.Errorf("Engine is required")
	}
	logger := cfg.Logger
	if logger == nil {
		logger = log.Default()
	}
	p := &Proxy{cfg: cfg, log: logger, lastHits: make([]string, 0, 32)}
	return p, nil
}

// StatsSnapshot returns counters.
func (p *Proxy) StatsSnapshot() (queries, blocked, allowed, upstreamErr uint64) {
	return p.stats.Queries.Load(), p.stats.Blocked.Load(), p.stats.Allowed.Load(), p.stats.UpstreamE.Load()
}

// RecentBlocked returns a copy of recent blocked domain names.
func (p *Proxy) RecentBlocked() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]string, len(p.lastHits))
	copy(out, p.lastHits)
	return out
}

func (p *Proxy) recordBlock(domain string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.lastHits) >= 32 {
		p.lastHits = p.lastHits[1:]
	}
	p.lastHits = append(p.lastHits, domain)
}

// ListenAndServe starts UDP+TCP DNS and blocks until Shutdown.
func (p *Proxy) ListenAndServe() error {
	mux := dns.NewServeMux()
	mux.HandleFunc(".", p.handle)

	p.udpServer = &dns.Server{
		Addr:    p.cfg.ListenAddr,
		Net:     "udp",
		Handler: mux,
	}
	p.tcpServer = &dns.Server{
		Addr:    p.cfg.ListenAddr,
		Net:     "tcp",
		Handler: mux,
	}

	errCh := make(chan error, 2)
	go func() {
		p.log.Printf("DNS proxy listening on udp://%s (upstream %s)", p.cfg.ListenAddr, p.cfg.Upstream)
		errCh <- p.udpServer.ListenAndServe()
	}()
	go func() {
		p.log.Printf("DNS proxy listening on tcp://%s", p.cfg.ListenAddr)
		errCh <- p.tcpServer.ListenAndServe()
	}()

	err := <-errCh
	_ = p.Shutdown()
	if err != nil && !strings.Contains(err.Error(), "use of closed network connection") {
		return err
	}
	return nil
}

// Shutdown stops the proxy.
func (p *Proxy) Shutdown() error {
	var first error
	if p.udpServer != nil {
		if err := p.udpServer.Shutdown(); err != nil && first == nil {
			first = err
		}
	}
	if p.tcpServer != nil {
		if err := p.tcpServer.Shutdown(); err != nil && first == nil {
			first = err
		}
	}
	return first
}

func (p *Proxy) handle(w dns.ResponseWriter, r *dns.Msg) {
	p.stats.Queries.Add(1)
	if r == nil || len(r.Question) == 0 {
		return
	}

	q := r.Question[0]
	name := strings.TrimSuffix(q.Name, ".")
	decision := p.cfg.Engine.Check(name)

	// Only filter A/AAAA/HTTPS (SVCB) style lookups by name; still apply to any QTYPE for blocked names.
	if decision.Blocked {
		p.stats.Blocked.Add(1)
		p.recordBlock(name)
		p.log.Printf("BLOCK %s (rule=%s source=%s)", name, decision.MatchedRule, decision.Source)
		m := new(dns.Msg)
		m.SetReply(r)
		m.Rcode = dns.RcodeNameError // NXDOMAIN
		m.Authoritative = true
		_ = w.WriteMsg(m)
		return
	}

	p.stats.Allowed.Add(1)
	resp, err := p.forward(r)
	if err != nil {
		p.stats.UpstreamE.Add(1)
		p.log.Printf("upstream error for %s: %v", name, err)
		m := new(dns.Msg)
		m.SetReply(r)
		m.Rcode = dns.RcodeServerFailure
		_ = w.WriteMsg(m)
		return
	}
	_ = w.WriteMsg(resp)
}

func (p *Proxy) forward(r *dns.Msg) (*dns.Msg, error) {
	client := &dns.Client{
		Net:     "udp",
		Timeout: p.cfg.UpstreamTimeout,
	}
	ctx, cancel := context.WithTimeout(context.Background(), p.cfg.UpstreamTimeout)
	defer cancel()

	// Prefer ExchangeContext when available via dial.
	conn, err := net.DialTimeout("udp", p.cfg.Upstream, p.cfg.UpstreamTimeout)
	if err != nil {
		// fall back to TCP
		return p.forwardTCP(r)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(p.cfg.UpstreamTimeout))

	co := &dns.Conn{Conn: conn}
	if err := co.WriteMsg(r); err != nil {
		return nil, err
	}
	resp, err := co.ReadMsg()
	if err != nil {
		// truncation → TCP retry
		return p.forwardTCP(r)
	}
	if resp.Truncated {
		return p.forwardTCP(r)
	}
	_ = ctx
	_ = client
	return resp, nil
}

func (p *Proxy) forwardTCP(r *dns.Msg) (*dns.Msg, error) {
	client := &dns.Client{Net: "tcp", Timeout: p.cfg.UpstreamTimeout}
	resp, _, err := client.Exchange(r, p.cfg.Upstream)
	return resp, err
}
