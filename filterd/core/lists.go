package core

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// ParseSource identifies which list a domain came from.
type ParseSource string

const (
	SourceUnknown ParseSource = "unknown"
)

// ParseStats summarizes a list load.
type ParseStats struct {
	Path      string
	Source    string
	Lines     int
	Added     int
	Skipped   int
	Duplicates int
}

// NormalizeDomain lowercases and strips trailing dots / whitespace.
// Returns empty string if the domain is not usable.
func NormalizeDomain(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Trim(s, ".")
	s = strings.ToLower(s)
	if s == "" {
		return ""
	}
	// Reject obvious garbage.
	if strings.ContainsAny(s, " \t\r\n/\\") {
		return ""
	}
	if strings.HasPrefix(s, "*.") {
		s = strings.TrimPrefix(s, "*.")
	}
	if s == "" || s == "*" {
		return ""
	}
	// Basic label check: must contain at least one dot for real sites,
	// but single-label names (localhost, intranet) are allowed for allowlists.
	for _, part := range strings.Split(s, ".") {
		if part == "" {
			return ""
		}
	}
	return s
}

// ParseAdblockLine extracts a domain from a HaGeZi / Adblock-style DNS line.
// Supports:
//
//	||domain.example^
//	||domain.example^$important
//	0.0.0.0 domain.example
//	127.0.0.1 domain.example
//	domain.example
//
// Returns empty string for comments, headers, and non-domain rules.
func ParseAdblockLine(line string) string {
	line = strings.TrimSpace(line)
	if line == "" {
		return ""
	}
	// Comments / section headers
	if line[0] == '!' || line[0] == '[' || line[0] == '#' {
		return ""
	}

	// ||domain^ or ||domain^$options
	if strings.HasPrefix(line, "||") {
		rest := line[2:]
		// Cut at separator used by ABP DNS lists
		for _, sep := range []string{"^", "$", "/", "*"} {
			if i := strings.Index(rest, sep); i >= 0 {
				// allow * only if not at start after ||
				if sep == "*" && i == 0 {
					return ""
				}
				if sep == "*" {
					// ||*.domain^ style already handled via Normalize
					rest = rest[:i]
					break
				}
				rest = rest[:i]
				break
			}
		}
		// If no ^ present, take up to whitespace
		if i := strings.IndexAny(rest, " \t"); i >= 0 {
			rest = rest[:i]
		}
		return NormalizeDomain(rest)
	}

	// hosts-file style: "0.0.0.0 domain" / "127.0.0.1 domain"
	fields := strings.Fields(line)
	if len(fields) >= 2 && (fields[0] == "0.0.0.0" || fields[0] == "127.0.0.1" || fields[0] == "::" || fields[0] == "::1") {
		return NormalizeDomain(fields[1])
	}

	// Bare domain (no spaces, looks like a hostname)
	if len(fields) == 1 && strings.Contains(fields[0], ".") {
		// Skip pure IP addresses
		if isIPv4Literal(fields[0]) {
			return ""
		}
		return NormalizeDomain(fields[0])
	}

	return ""
}

func isIPv4Literal(s string) bool {
	parts := strings.Split(s, ".")
	if len(parts) != 4 {
		return false
	}
	for _, p := range parts {
		if p == "" {
			return false
		}
		for _, c := range p {
			if c < '0' || c > '9' {
				return false
			}
		}
	}
	return true
}

// LoadListFile parses a block/allow list file and inserts domains into set.
// source is a short tag (e.g. "nsfw", "tif.mini", "allow").
func LoadListFile(path string, source string, set *DomainSet) (ParseStats, error) {
	stats := ParseStats{Path: path, Source: source}
	f, err := os.Open(path)
	if err != nil {
		return stats, fmt.Errorf("open list %s: %w", path, err)
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	// Some list lines can be long; raise token size.
	buf := make([]byte, 0, 64*1024)
	sc.Buffer(buf, 1024*1024)

	for sc.Scan() {
		stats.Lines++
		domain := ParseAdblockLine(sc.Text())
		if domain == "" {
			stats.Skipped++
			continue
		}
		if set.Add(domain, source) {
			stats.Added++
		} else {
			stats.Duplicates++
		}
	}
	if err := sc.Err(); err != nil {
		return stats, fmt.Errorf("read list %s: %w", path, err)
	}
	return stats, nil
}
