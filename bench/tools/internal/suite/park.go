package suite

import (
	"bufio"
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/load"
	"github.com/xuckless/anole/bench/tools/internal/sut"
	"github.com/xuckless/anole/bench/tools/internal/ws"
)

// parkConns: idle connection counts; the wake tests use the last.
var parkConns = []int{10000, 32000}

const (
	parkIdle   = 30 * time.Second // sit idle this long before memory is read
	wakeSample = 1000             // connections woken one at a time
	wakeConc   = 256              // then all of them, this many at a time
	burstConns = 16000
)

// kaConn: an idle keep-alive connection that made one request.
type kaConn struct {
	c net.Conn
	r *bufio.Reader
}

var kaReq = []byte("GET /plaintext HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

// roundTrip sends one GET /plaintext and reads the answer through.
func (k kaConn) roundTrip() error {
	k.c.SetDeadline(time.Now().Add(10 * time.Second))
	defer k.c.SetDeadline(time.Time{})
	if _, err := k.c.Write(kaReq); err != nil {
		return err
	}
	n := -1
	for {
		line, err := k.r.ReadString('\n')
		if err != nil {
			return err
		}
		if line == "\r\n" {
			break
		}
		if name, v, ok := strings.Cut(line, ":"); ok && strings.EqualFold(name, "content-length") {
			n, _ = strconv.Atoi(strings.TrimSpace(v))
		}
	}
	if n < 0 {
		return fmt.Errorf("no content-length")
	}
	_, err := k.r.Discard(n)
	return err
}

// openKA opens n keep-alive connections (TLS on 8443 when tlsOn), one
// request on each, spread over 127.0.0.1-8.
func openKA(n int, tlsOn bool) ([]kaConn, int) {
	conns := make([]kaConn, n)
	var failed atomic.Int64
	var wg sync.WaitGroup
	sem := make(chan struct{}, 256)
	for i := 0; i < n; i++ {
		sem <- struct{}{}
		wg.Add(1)
		go func(i int) {
			defer func() { <-sem; wg.Done() }()
			d := &net.Dialer{LocalAddr: &net.TCPAddr{IP: net.IPv4(127, 0, 0, byte(1+i%8))}, Timeout: 10 * time.Second}
			var c net.Conn
			var err error
			if tlsOn {
				c, err = tls.DialWithDialer(d, "tcp", "127.0.0.1:8443", &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"http/1.1"}})
			} else {
				c, err = d.Dial("tcp", "127.0.0.1:8080")
			}
			if err == nil {
				k := kaConn{c, bufio.NewReaderSize(c, 4096)}
				if err = k.roundTrip(); err == nil {
					conns[i] = k
					return
				}
				c.Close()
			}
			failed.Add(1)
		}(i)
	}
	wg.Wait()
	var open []kaConn
	for _, k := range conns {
		if k.c != nil {
			open = append(open, k)
		}
	}
	return open, int(failed.Load())
}

// wakeKA sends one request on each connection, conc at a time.
func wakeKA(conns []kaConn, conc int) (ws.Lat, int) {
	us := make([]int64, 0, len(conns))
	var mu sync.Mutex
	var failed atomic.Int64
	var wg sync.WaitGroup
	sem := make(chan struct{}, max(1, conc))
	for _, k := range conns {
		sem <- struct{}{}
		wg.Add(1)
		go func(k kaConn) {
			defer func() { <-sem; wg.Done() }()
			t0 := time.Now()
			if err := k.roundTrip(); err != nil {
				failed.Add(1)
				return
			}
			mu.Lock()
			us = append(us, time.Since(t0).Microseconds())
			mu.Unlock()
		}(k)
	}
	wg.Wait()
	return latOf(us), int(failed.Load())
}

func latOf(us []int64) ws.Lat {
	if len(us) == 0 {
		return ws.Lat{}
	}
	sort.Slice(us, func(i, j int) bool { return us[i] < us[j] })
	p := func(q float64) float64 { return float64(us[int(q*float64(len(us)-1))]) / 1000 }
	return ws.Lat{N: len(us), P50MS: p(0.5), P99MS: p(0.99), P999MS: p(0.999), MaxMS: float64(us[len(us)-1]) / 1000}
}

// memNote: what n idle connections cost, from the cgroup before and after.
func memNote(n int, a0, k0, s0, c0, a1, k1, s1, c1 float64) string {
	per := func(d float64) float64 { return d * 1024 / float64(max(1, n)) }
	return fmt.Sprintf("%.1f KB per connection (anon %.1f + kernel %.1f, of which sock %.1f; memory.current %.1f); anon %.0f -> %.0f MB, kernel %.0f -> %.0f MB, current %.0f -> %.0f MB",
		per(a1+k1-a0-k0), per(a1-a0), per(k1-k0), per(s1-s0), per(c1-c0), a0, a1, k0, k1, c0, c1)
}

// Park: the cost of idle connections and of waking them. Keep-alive
// (plain and TLS) and WebSocket connections that sit idle parkIdle, then
// the memory; then a request on wakeSample of them one at a time and on
// all of them wakeConc at a time; and the memory peak while burstConns
// WebSockets connect at once. Every tier; a fresh server for each count.
func (s *Suite) Park() {
	for _, tier := range s.Tiers {
		for _, name := range s.Servers {
			for _, mode := range []string{"h1", "tls"} {
				if !s.manifests[name].Supports(mode) {
					continue
				}
				for _, n := range parkConns {
					s.parkKA(name, mode, tier, n)
				}
			}
			if s.manifests[name].WS == "" {
				continue
			}
			for _, path := range []string{"/ws/echo", "/ws/echo-cb"} {
				for _, n := range parkConns {
					if !s.parkWS(name, tier, path, n) {
						break // no such route
					}
				}
				s.parkBurst(name, tier, path)
			}
		}
	}
}

func (s *Suite) parkKA(name, mode string, tier sut.Tier, n int) {
	proto := map[string]string{"h1": "h1", "tls": "h1-tls"}[mode]
	srv, err := sut.Start(s.Cfg, name, mode, tier, nil, 0)
	if err != nil {
		s.record(Case{Scenario: "park", Server: name, Mode: mode, Proto: proto, Tier: tier.Name, Error: err.Error()})
		return
	}
	defer sut.Stop()
	time.Sleep(2 * time.Second)
	a0, k0, s0, c0 := srv.MemStat()
	conns, failed := openKA(n, mode == "tls")
	time.Sleep(parkIdle)
	a1, k1, s1, c1 := srv.MemStat()
	c := Case{Scenario: "park", Server: name, Mode: mode, Proto: proto, Tier: tier.Name, Endpoint: "/plaintext",
		Param: fmt.Sprintf("idle n=%d", n), SUT: sut.Usage{MemMB: a1 + k1, CurrentPeakMB: c1},
		Load: load.Result{Tool: "benchctl", Requests: int64(len(conns)), Errors: int64(failed)},
		Note: memNote(len(conns), a0, k0, s0, c0, a1, k1, s1, c1)}
	if x := s.note(srv, 0); x != "" {
		c.Note += "; " + x
	}
	s.record(c)
	if n == parkConns[len(parkConns)-1] {
		s.parkWakeKA(srv, name, mode, proto, tier, conns)
	}
	for _, k := range conns {
		k.c.Close()
	}
}

func (s *Suite) parkWakeKA(srv *sut.Server, name, mode, proto string, tier sut.Tier, conns []kaConn) {
	for _, w := range []struct {
		param string
		set   []kaConn
		conc  int
	}{
		{fmt.Sprintf("wake %d of %d, one at a time", min(wakeSample, len(conns)), len(conns)), conns[:min(wakeSample, len(conns))], 1},
		{fmt.Sprintf("wake all %d, %d at a time", len(conns), wakeConc), conns, wakeConc},
	} {
		// Idle again past the park threshold before each wake.
		time.Sleep(5 * time.Second)
		t0 := time.Now()
		lat, failed := wakeKA(w.set, w.conc)
		el := time.Since(t0)
		c := Case{Scenario: "park", Server: name, Mode: mode, Proto: proto, Tier: tier.Name, Endpoint: "/plaintext",
			Param: w.param, Load: load.Result{Tool: "benchctl", Requests: int64(lat.N), RPS: float64(lat.N) / el.Seconds(),
				Errors: int64(failed), P50MS: lat.P50MS, P99MS: lat.P99MS, P999MS: lat.P999MS, MaxMS: lat.MaxMS},
			Note: s.note(srv, 0)}
		s.record(c)
	}
}

// parkWS: n idle WebSockets on path; false when the route is missing.
func (s *Suite) parkWS(name string, tier sut.Tier, path string, n int) bool {
	srv, err := sut.Start(s.Cfg, name, "h1", tier, map[string]string{"TICK_HZ": "0"}, 0)
	if err != nil {
		s.record(Case{Scenario: "park", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Endpoint: path, Error: err.Error()})
		return true
	}
	defer sut.Stop()
	url := "ws://127.0.0.1:8080" + path
	if probe, failed := ws.OpenQuiet(context.Background(), url, 1, 1, 1); failed > 0 {
		return false
	} else {
		ws.CloseAll(probe)
	}
	time.Sleep(2 * time.Second)
	a0, k0, s0, c0 := srv.MemStat()
	conns, failed := ws.OpenQuiet(context.Background(), url, n, 5000, 8)
	time.Sleep(parkIdle)
	a1, k1, s1, c1 := srv.MemStat()
	c := Case{Scenario: "park", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Endpoint: path,
		Param: fmt.Sprintf("idle n=%d", n), SUT: sut.Usage{MemMB: a1 + k1, CurrentPeakMB: c1},
		Load: load.Result{Tool: "benchctl ws", Requests: int64(len(conns)), Errors: int64(failed)},
		Note: memNote(len(conns), a0, k0, s0, c0, a1, k1, s1, c1)}
	if x := s.note(srv, 0); x != "" {
		c.Note += "; " + x
	}
	s.record(c)
	if n == parkConns[len(parkConns)-1] {
		for _, w := range []struct {
			param string
			set   int
			conc  int
		}{
			{fmt.Sprintf("wake %d of %d, one at a time", min(wakeSample, len(conns)), len(conns)), min(wakeSample, len(conns)), 1},
			{fmt.Sprintf("wake all %d, %d at a time", len(conns), wakeConc), len(conns), wakeConc},
		} {
			time.Sleep(5 * time.Second)
			t0 := time.Now()
			lat, failed := ws.WakeEcho(conns[:w.set], w.conc)
			el := time.Since(t0)
			s.record(Case{Scenario: "park", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Endpoint: path,
				Param: w.param, Load: load.Result{Tool: "benchctl ws", Requests: int64(lat.N), RPS: float64(lat.N) / el.Seconds(),
					Errors: int64(failed), P50MS: lat.P50MS, P99MS: lat.P99MS, P999MS: lat.P999MS, MaxMS: lat.MaxMS},
				Note: s.note(srv, 0)})
		}
	}
	ws.CloseAll(conns)
	return true
}

// parkBurst: the memory peak while burstConns WebSockets connect as fast
// as the client can, sampled every 50 ms, and what is left 30 s later.
func (s *Suite) parkBurst(name string, tier sut.Tier, path string) {
	srv, err := sut.Start(s.Cfg, name, "h1", tier, map[string]string{"TICK_HZ": "0"}, 0)
	if err != nil {
		return
	}
	defer sut.Stop()
	url := "ws://127.0.0.1:8080" + path
	if probe, failed := ws.OpenQuiet(context.Background(), url, 1, 1, 1); failed > 0 {
		return
	} else {
		ws.CloseAll(probe)
	}
	time.Sleep(2 * time.Second)
	a0, k0, s0, c0 := srv.MemStat()
	smp := srv.Sample(50*time.Millisecond, false)
	t0 := time.Now()
	conns, failed := ws.OpenQuiet(context.Background(), url, burstConns, 1_000_000, 8)
	el := time.Since(t0)
	time.Sleep(time.Second)
	u := smp.Stop()
	time.Sleep(parkIdle)
	a1, k1, s1, c1 := srv.MemStat()
	peak := u.MemMB - (a0 + k0)
	c := Case{Scenario: "park", Server: name, Mode: "h1", Proto: "ws", Tier: tier.Name, Endpoint: path,
		Param: fmt.Sprintf("burst n=%d", burstConns), SUT: u,
		Load: load.Result{Tool: "benchctl ws", Requests: int64(len(conns)), RPS: float64(len(conns)) / el.Seconds(), Errors: int64(failed)},
		Note: fmt.Sprintf("peak %.1f KB per connection (%.0f MB over the idle server's %.0f MB) while connecting in %.1f s; %s 30 s later",
			peak*1024/float64(max(1, len(conns))), peak, a0+k0, el.Seconds(), memNote(len(conns), a0, k0, s0, c0, a1, k1, s1, c1))}
	if x := s.note(srv, 0); x != "" {
		c.Note += "; " + x
	}
	s.record(c)
	ws.CloseAll(conns)
}
