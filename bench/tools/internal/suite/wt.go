package suite

import (
	"fmt"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/load"
	"github.com/xuckless/anole/bench/tools/internal/sut"
)

// WebTransport: draft-02 against /wt/echo (SPEC.md) on the first tier.
// Session setup (a QUIC handshake plus an extended CONNECT each), stream
// echo throughput and round trips, and datagram echo round trips and loss
// at a fixed rate. Anole serves it from its own HTTP/3; the other stacks
// from their <name>-wt servers.
func (s *Suite) WebTransport() {
	tier := s.Tiers[0]
	url := sut.URL("h3") + "/wt/echo"
	sessions := 2000
	if s.Profile.Name == "full" {
		sessions = 10000
	}
	cases := []struct {
		param string
		o     load.WtOpts
	}{
		{fmt.Sprintf("sessions n=%d c=64", sessions), load.WtOpts{Mode: "sessions", N: sessions, C: 64}},
		{"streams 16 sessions x 4, 16 KiB", load.WtOpts{Mode: "streams", S: 16, P: 4, Size: 16 << 10}},
		{"datagrams 64 sessions x 1000/s, 64 B", load.WtOpts{Mode: "datagrams", S: 64, Rate: 1000, Size: 64}},
	}
	for _, name := range s.Servers {
		m := s.manifests[name]
		if m.WebTransport == "" {
			continue
		}
		srv, err := sut.Start(s.Cfg, name, "h3", tier, nil, 0)
		if err != nil {
			s.record(Case{Scenario: "wt", Server: name, Mode: "h3", Proto: "wt", Tier: tier.Name, Error: err.Error()})
			continue
		}
		for _, tc := range cases {
			var note string
			r, u, lcpu, err := s.measure(srv, true, func(d time.Duration) (load.Result, error) {
				o := tc.o
				o.URL = url
				if o.Mode != "sessions" {
					o.Duration = d
				}
				r, n, err := load.Wtload(o)
				note = n
				return r, err
			})
			c := Case{Scenario: "wt", Server: name, Mode: "h3", Proto: "wt", Tier: tier.Name, Endpoint: "/wt/echo",
				Param: tc.param, Load: r, SUT: u, LoadCPU: lcpu, Note: note, Label: m.WebTransport}
			if err != nil {
				c.Error = err.Error()
			}
			if n := s.note(srv, lcpu); n != "" {
				if c.Note != "" {
					c.Note += "; "
				}
				c.Note += n
			}
			s.record(c)
		}
		sut.Stop()
	}
}
