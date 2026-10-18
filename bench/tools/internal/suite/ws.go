package suite

import (
	"context"
	"fmt"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/load"
	"github.com/xuckless/anole/bench/tools/internal/sut"
	"github.com/xuckless/anole/bench/tools/internal/ws"
)

// FeedConfig is one fan-out load: subscribers on /ws/feed at a tick rate,
// and traders among them sending orders on /ws/trade.
type FeedConfig struct {
	Name    string
	Subs    int
	Traders int
	TickHz  int
	OrderHz int
}

var feedConfigs = []FeedConfig{
	{Name: "fanout-100x1000hz", Subs: 100, TickHz: 1000},
	{Name: "fanout-1000x1000hz", Subs: 1000, TickHz: 1000},
	{Name: "fanout-10000x100hz", Subs: 10000, TickHz: 100},
	// The trading bots: every bot watches the feed, one in ten trades.
	{Name: "trading-500bots", Subs: 500, Traders: 50, TickHz: 200, OrderHz: 20},
	{Name: "trading-2000bots", Subs: 2000, Traders: 200, TickHz: 500, OrderHz: 10},
}

// WebSockets: idle sockets (memory per socket), echo throughput and the
// feed fan-out and trading simulation, HTTP/1.1, first tier.
func (s *Suite) WebSockets() {
	tier := s.Tiers[0]
	idle := 10000
	if s.Profile.Name == "full" {
		idle = 50000
	}
	for _, name := range s.Servers {
		if s.manifests[name].WS == "" {
			continue
		}
		base := "ws://127.0.0.1:8080"
		// Idle sockets and echo, ticker off.
		srv, err := sut.Start(s.Cfg, name, "h1", tier, map[string]string{"TICK_HZ": "0"}, 0)
		if err != nil {
			s.record(Case{Scenario: "ws", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Error: err.Error()})
			continue
		}
		time.Sleep(2 * time.Second)
		before := srv.MemNowMB()
		smp := srv.Sample(time.Second, false)
		conns, failed := ws.OpenIdle(context.Background(), base+"/ws/echo", idle, 5000, 8)
		time.Sleep(5 * time.Second)
		after := srv.MemNowMB()
		u := smp.Stop()
		ws.CloseAll(conns)
		c := Case{Scenario: "ws", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Endpoint: "/ws/echo",
			Param: fmt.Sprintf("idle=%d", idle), SUT: u,
			Load: load.Result{Tool: "benchctl ws", Requests: int64(len(conns)), Errors: int64(failed)}}
		if len(conns) > 0 {
			c.Note = fmt.Sprintf("%.1f KB per socket (%.0f MB -> %.0f MB)", (after-before)*1024/float64(len(conns)), before, after)
		}
		if n := s.note(srv, 0); n != "" {
			c.Note += "; " + n
		}
		s.record(c)
		time.Sleep(3 * time.Second)

		for _, cs := range []int{64, 1024} {
			smp := srv.Sample(500*time.Millisecond, false)
			r := ws.Echo(base+"/ws/echo", cs, 64, s.Profile.Run)
			u := smp.Stop()
			s.record(Case{Scenario: "ws", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Endpoint: "/ws/echo",
				Param: fmt.Sprintf("echo c=%d", cs), SUT: u, Note: s.note(srv, 0),
				Load: load.Result{Tool: "benchctl ws", Requests: r.Msgs, RPS: r.MsgsPS, Errors: r.Errors,
					P50MS: r.RTT.P50MS, P99MS: r.RTT.P99MS, P999MS: r.RTT.P999MS, MaxMS: r.RTT.MaxMS}})
		}
		sut.Stop()

		for _, fc := range feedConfigs {
			srv, err := sut.Start(s.Cfg, name, "h1", tier, map[string]string{"TICK_HZ": fmt.Sprint(fc.TickHz)}, 0)
			if err != nil {
				s.record(Case{Scenario: "ws", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Param: fc.Name, Error: err.Error()})
				continue
			}
			smp := srv.Sample(500*time.Millisecond, false)
			r := ws.Feed(base+"/ws/feed", base+"/ws/trade", fc.Subs, fc.Traders, fc.TickHz, max(1, fc.OrderHz), s.Profile.Run)
			u := smp.Stop()
			c := Case{Scenario: "ws", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Endpoint: "/ws/feed",
				Param: fc.Name, SUT: u, Note: s.note(srv, 0),
				Load: load.Result{Tool: "benchctl ws", Requests: int64(r.Connected), RPS: r.Delivered, Errors: r.Gaps,
					P50MS: r.Lag.P50MS, P99MS: r.Lag.P99MS, P999MS: r.Lag.P999MS, MaxMS: r.Lag.MaxMS}}
			c.Feed = &r
			s.record(c)
			sut.Stop()
		}
	}
}
