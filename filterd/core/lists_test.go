package core

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseAdblockLine(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"||example.com^", "example.com"},
		{"||SUB.Example.COM^", "sub.example.com"},
		{"||domain.example^$important", "domain.example"},
		{"! comment", ""},
		{"[Adblock Plus]", ""},
		{"", ""},
		{"0.0.0.0 ads.example.org", "ads.example.org"},
		{"127.0.0.1 tracker.test", "tracker.test"},
		{"bare-domain.example", "bare-domain.example"},
		{"||*.evil.com^", "evil.com"},
	}
	for _, tc := range cases {
		got := ParseAdblockLine(tc.in)
		if got != tc.want {
			t.Errorf("ParseAdblockLine(%q)=%q want %q", tc.in, got, tc.want)
		}
	}
}

func TestNormalizeDomain(t *testing.T) {
	if NormalizeDomain("  Foo.BAR. ") != "foo.bar" {
		t.Fatal("normalize failed")
	}
	if NormalizeDomain("") != "" {
		t.Fatal("empty should stay empty")
	}
}

func TestEngineAllowBeatsBlock(t *testing.T) {
	e := NewEngine()
	e.Block.Add("bad.example", "nsfw")
	e.Block.Add("example.com", "nsfw")
	e.Allow.Add("ok.example.com", "allow")

	d := e.Check("a.bad.example")
	if !d.Blocked || d.MatchedRule != "bad.example" {
		t.Fatalf("expected block on bad.example, got %+v", d)
	}

	d = e.Check("ok.example.com")
	if d.Blocked || d.AllowedBy != "ok.example.com" {
		t.Fatalf("allowlist should win, got %+v", d)
	}

	// parent block still hits other children
	d = e.Check("other.example.com")
	if !d.Blocked || d.MatchedRule != "example.com" {
		t.Fatalf("expected parent block example.com, got %+v", d)
	}
}

func TestParentWalk(t *testing.T) {
	e := NewEngine()
	e.Block.Add("example.com", "nsfw")
	d := e.Check("images.subdomain.example.com")
	if !d.Blocked || d.MatchedRule != "example.com" {
		t.Fatalf("parent walk failed: %+v", d)
	}
	d = e.Check("notblocked.org")
	if d.Blocked {
		t.Fatalf("should allow: %+v", d)
	}
}

func TestLoadListFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "list.txt")
	content := `[Adblock Plus]
! comment
||one.example^
||two.example^
||one.example^
0.0.0.0 three.example
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	set := NewDomainSet()
	stats, err := LoadListFile(path, "test", set)
	if err != nil {
		t.Fatal(err)
	}
	if set.Len() != 3 {
		t.Fatalf("len=%d stats=%+v", set.Len(), stats)
	}
	if stats.Added != 3 {
		t.Fatalf("added=%d", stats.Added)
	}
}
