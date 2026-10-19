package suite

import (
	"fmt"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/load"
	"github.com/xuckless/anole/bench/tools/internal/sut"
)

// wspipeConns: HttpArena's echo-ws-pipeline connection counts.
var wspipeConns = []int{512, 4096, 16384}

// WsPipe: HttpArena's echo-ws-pipeline, run with its own load generator
// (gcannon): every connection keeps 16 echo messages in flight on
// /ws/echo. Every server with WebSockets, every tier.
func (s *Suite) WsPipe() {
	for _, tier := range s.Tiers {
		for _, name := range s.Servers {
			if s.manifests[name].WS == "" {
				continue
			}
			srv, err := sut.Start(s.Cfg, name, "h1", tier, map[string]string{"TICK_HZ": "0"}, 0)
			if err != nil {
				s.record(Case{Scenario: "wspipe", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Error: err.Error()})
				continue
			}
			for _, conns := range wspipeConns {
				r, u, lcpu, err := s.measure(srv, true, func(d time.Duration) (load.Result, error) {
					return load.Gcannon(load.GcannonWS{URL: "http://127.0.0.1:8080/ws/echo", Conns: conns,
						Threads: min(s.LoadCPUs, 16), Pipeline: 16, Duration: d})
				})
				c := Case{Scenario: "wspipe", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Endpoint: "/ws/echo",
					Param: fmt.Sprintf("c=%d, 16 in flight", conns), Load: r, SUT: u, LoadCPU: lcpu, Note: s.note(srv, lcpu)}
				if err != nil {
					c.Error = err.Error()
				}
				s.record(c)
			}
			sut.Stop()
		}
	}
}
