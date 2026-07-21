package core

import (
	"strings"
	"sync"
)

// Decision is the result of a policy check.
type Decision struct {
	Domain      string `json:"domain"`
	Blocked     bool   `json:"blocked"`
	MatchedRule string `json:"matched_rule,omitempty"`
	Source      string `json:"source,omitempty"`
	AllowedBy   string `json:"allowed_by,omitempty"`
}

// DomainSet is an in-memory set of domains with optional provenance.
type DomainSet struct {
	mu      sync.RWMutex
	domains map[string]string // domain -> source
}

// NewDomainSet creates an empty set.
func NewDomainSet() *DomainSet {
	return &DomainSet{domains: make(map[string]string)}
}

// Add inserts domain. Returns true if it was new.
func (s *DomainSet) Add(domain, source string) bool {
	domain = NormalizeDomain(domain)
	if domain == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.domains[domain]; ok {
		return false
	}
	if source == "" {
		source = string(SourceUnknown)
	}
	s.domains[domain] = source
	return true
}

// HasExact reports whether domain is in the set (no parent walk).
func (s *DomainSet) HasExact(domain string) bool {
	domain = NormalizeDomain(domain)
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, ok := s.domains[domain]
	return ok
}

// Len returns number of domains.
func (s *DomainSet) Len() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.domains)
}

// Match walks the domain and parents: a.b.example.com → a.b.example.com, b.example.com, example.com
// Returns matched domain and source if found.
func (s *DomainSet) Match(domain string) (matched string, source string, ok bool) {
	domain = NormalizeDomain(domain)
	if domain == "" {
		return "", "", false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	for {
		if src, found := s.domains[domain]; found {
			return domain, src, true
		}
		// strip leftmost label
		i := strings.IndexByte(domain, '.')
		if i < 0 {
			return "", "", false
		}
		domain = domain[i+1:]
		if domain == "" {
			return "", "", false
		}
	}
}

// Engine holds block and allow sets.
type Engine struct {
	Block *DomainSet
	Allow *DomainSet
}

// NewEngine creates empty block/allow sets.
func NewEngine() *Engine {
	return &Engine{
		Block: NewDomainSet(),
		Allow: NewDomainSet(),
	}
}

// Check returns the policy decision for a query name.
// Allowlist wins over blocklist.
func (e *Engine) Check(domain string) Decision {
	domain = NormalizeDomain(domain)
	d := Decision{Domain: domain}
	if domain == "" {
		return d
	}

	if matched, src, ok := e.Allow.Match(domain); ok {
		d.AllowedBy = matched
		d.Source = src
		d.Blocked = false
		return d
	}
	if matched, src, ok := e.Block.Match(domain); ok {
		d.Blocked = true
		d.MatchedRule = matched
		d.Source = src
		return d
	}
	return d
}
