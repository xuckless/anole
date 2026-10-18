package suite

import (
	"bufio"
	"fmt"
	"net"
	"path/filepath"
	"sync"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/load"
	"github.com/xuckless/anole/bench/tools/internal/sut"
)

// openKeepAlive opens n connections, sends one GET on each, reads the
// answer and leaves the connection open (idle keep-alive, as a browser
// tab holds it). Spread over 127.0.0.1-8 for the port range.
func openKeepAlive(n int) ([]net.Conn, int) {
	conns := make([]net.Conn, n)
	var wg sync.WaitGroup
	sem := make(chan struct{}, 256)
	req := []byte("GET /plaintext HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
	failed := 0
	var mu sync.Mutex
	for i := 0; i < n; i++ {
		sem <- struct{}{}
		wg.Add(1)
		go func(i int) {
			defer func() { <-sem; wg.Done() }()
			d := net.Dialer{LocalAddr: &net.TCPAddr{IP: net.IPv4(127, 0, 0, byte(1+i%8))}, Timeout: 10 * time.Second}
			c, err := d.Dial("tcp", "127.0.0.1:8080")
			if err == nil {
				c.SetDeadline(time.Now().Add(10 * time.Second))
				if _, err = c.Write(req); err == nil {
					r := bufio.NewReader(c)
					var line string
					// Status line and headers; the body is 13 bytes.
					for line, err = r.ReadString('\n'); err == nil && line != "\r\n"; line, err = r.ReadString('\n') {
					}
					if err == nil {
						_, err = r.Discard(13)
					}
				}
				c.SetDeadline(time.Time{})
			}
			if err != nil {
				mu.Lock()
				failed++
				mu.Unlock()
				if c != nil {
					c.Close()
				}
				return
			}
			conns[i] = c
		}(i)
	}
	wg.Wait()
	var open []net.Conn
	for _, c := range conns {
		if c != nil {
			open = append(open, c)
		}
	}
	return open, failed
}

// Memory: what idle keep-alive connections cost; the same load under a
// tight memory cap; and concurrent 1 MB uploads. First tier.
func (s *Suite) Memory() {
	tier := s.Tiers[0]
	idle := []int{10000}
	if s.Profile.Name == "full" {
		idle = []int{10000, 50000}
	}
	for _, name := range s.Servers {
		if !s.manifests[name].Supports("h1") {
			continue
		}
		srv, err := sut.Start(s.Cfg, name, "h1", tier, nil, 0)
		if err != nil {
			s.record(Case{Scenario: "mem", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Error: err.Error()})
			continue
		}
		for _, n := range idle {
			time.Sleep(2 * time.Second)
			before := srv.MemNowMB()
			conns, failed := openKeepAlive(n)
			time.Sleep(5 * time.Second)
			after := srv.MemNowMB()
			c := Case{Scenario: "mem", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Endpoint: "/plaintext",
				Param: fmt.Sprintf("idle-keepalive=%d", n), SUT: sut.Usage{MemMB: after},
				Load: load.Result{Tool: "benchctl", Requests: int64(len(conns)), Errors: int64(failed)}}
			if len(conns) > 0 {
				c.Note = fmt.Sprintf("%.1f KB per connection (%.0f MB -> %.0f MB)", (after-before)*1024/float64(len(conns)), before, after)
			}
			if n := s.note(srv, 0); n != "" {
				c.Note += "; " + n
			}
			s.record(c)
			for _, c := range conns {
				c.Close()
			}
		}
		// Concurrent uploads: 64 connections each POSTing 1 MiB to /echo.
		r, u, lcpu, err := s.measure(srv, true, func(d time.Duration) (load.Result, error) {
			return load.Wrk(load.WrkOpts{URL: sut.URL("h1") + "/echo", Threads: 8, Conns: 64, Duration: d,
				Script: filepath.Join(s.BenchDir, "loadgen", "upload.lua")})
		})
		c := Case{Scenario: "mem", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Endpoint: "/echo",
			Param: "upload 1MiB c=64", Load: r, SUT: u, LoadCPU: lcpu, Note: s.note(srv, lcpu)}
		if err != nil {
			c.Error = err.Error()
		}
		s.record(c)
		sut.Stop()

		// The same /list load with a 256 MB cap.
		for _, capMB := range []int{256} {
			srv, err := sut.Start(s.Cfg, name, "h1", tier, nil, capMB)
			if err != nil {
				s.record(Case{Scenario: "mem", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Param: fmt.Sprintf("cap=%dMB", capMB), Error: err.Error()})
				continue
			}
			r, u, lcpu, err := s.measure(srv, true, func(d time.Duration) (load.Result, error) {
				return load.Wrk(load.WrkOpts{URL: sut.URL("h1") + "/list", Threads: 8, Conns: 1024, Duration: d, Script: s.script()})
			})
			c := Case{Scenario: "mem", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Endpoint: "/list",
				Param: fmt.Sprintf("cap=%dMB c=1024", capMB), Load: r, SUT: u, LoadCPU: lcpu, Note: s.note(srv, lcpu)}
			if err != nil {
				c.Error = err.Error()
			}
			s.record(c)
			sut.Stop()
		}
	}
}

// GC: a retained heap of RETAIN objects (1M) that a collector has to keep
// tracing, plus an allocation-heavy request (/gc/alloc builds and
// serializes 2000 objects). Closed loop first for the maximum, then an
// open-loop fixed rate at half of it for the tail latency, with memory
// sampled every 250 ms for the sawtooth.
func (s *Suite) GC() {
	tier := s.Tiers[0]
	for _, name := range s.Servers {
		if s.manifests[name].Twelve == "" { // every app server; not nginx
			continue
		}
		srv, err := sut.Start(s.Cfg, name, "h1", tier, map[string]string{"RETAIN": "1000000"}, 0)
		if err != nil {
			s.record(Case{Scenario: "gc", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Error: err.Error()})
			continue
		}
		time.Sleep(3 * time.Second)
		base := srv.MemNowMB()
		url := sut.URL("h1") + "/gc/alloc"
		r, u, lcpu, err := s.measure(srv, true, func(d time.Duration) (load.Result, error) {
			return load.Wrk(load.WrkOpts{URL: url, Threads: 8, Conns: 64, Duration: d, Script: s.script()})
		})
		c := Case{Scenario: "gc", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Endpoint: "/gc/alloc",
			Param: "closed c=64", Load: r, SUT: u, LoadCPU: lcpu,
			Note: fmt.Sprintf("retained heap %.0f MB at idle", base)}
		if err != nil {
			c.Error = err.Error()
		}
		if n := s.note(srv, lcpu); n != "" {
			c.Note += "; " + n
		}
		s.record(c)
		if err == nil && r.RPS > 0 {
			rate := int(r.RPS / 2)
			smp := srv.Sample(250*time.Millisecond, true)
			r2, err := load.Oha(load.OhaOpts{URL: url, Conns: 64, Rate: rate, Duration: 2 * s.Profile.Run, Proto: "1.1"})
			u2 := smp.Stop()
			c := Case{Scenario: "gc", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Endpoint: "/gc/alloc",
				Param: "rate=50%max", Load: r2, SUT: u2, Note: s.note(srv, 0)}
			if err != nil {
				c.Error = err.Error()
			}
			s.record(c)
		}
		sut.Stop()
	}
}
