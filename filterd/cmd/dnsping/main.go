package main

import (
	"fmt"
	"os"

	"github.com/miekg/dns"
)

func main() {
	addr := "127.0.0.1:8053"
	names := []string{"sub.blocked.test.", "example.com."}
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
	if len(os.Args) > 2 {
		names = os.Args[2:]
		for i := range names {
			if names[i][len(names[i])-1] != '.' {
				names[i] += "."
			}
		}
	}
	c := new(dns.Client)
	for _, name := range names {
		m := new(dns.Msg)
		m.SetQuestion(name, dns.TypeA)
		r, rtt, err := c.Exchange(m, addr)
		if err != nil {
			fmt.Printf("%s ERR %v\n", name, err)
			continue
		}
		fmt.Printf("%s rcode=%s answers=%d rtt=%s\n", name, dns.RcodeToString[r.Rcode], len(r.Answer), rtt)
		for _, a := range r.Answer {
			fmt.Printf("  %s\n", a.String())
		}
	}
}
