// Package suite runs the benchmark scenarios against each server and
// writes one JSON line per case to <out>/cases.jsonl.
package suite

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/load"
	"github.com/xuckless/anole/bench/tools/internal/sut"
	"github.com/xuckless/anole/bench/tools/internal/video"
	"github.com/xuckless/anole/bench/tools/internal/ws"
)

// Profile sets how long each case runs and how often it repeats.
type Profile struct {
	Name   string
	Warmup time.Duration
	Run    time.Duration
	Reps   int
	// Endpoints for the raw-throughput matrix.
	Endpoints []string
	// Connection counts for the concurrency sweep.
	Conns []int
}

var Profiles = map[string]Profile{
	"quick": {Name: "quick", Warmup: 5 * time.Second, Run: 15 * time.Second, Reps: 1,
		Endpoints: []string{"/plaintext", "/json"}, Conns: []int{64, 256, 1024, 4096, 10000}},
	"full": {Name: "full", Warmup: 15 * time.Second, Run: 30 * time.Second, Reps: 3,
		Endpoints: []string{"/plaintext", "/json", "/list"}, Conns: []int{16, 64, 256, 1024, 4096, 10000, 25000}},
}

// Case is one measured run.
type Case struct {
	Scenario string      `json:"scenario"`
	Server   string      `json:"server"`
	Label    string      `json:"label"`
	Mode     string      `json:"mode"`
	Proto    string      `json:"proto"`
	Tier     string      `json:"tier"`
	Endpoint string      `json:"endpoint,omitempty"`
	Param    string      `json:"param,omitempty"`
	Load     load.Result `json:"load"`
	SUT      sut.Usage   `json:"sut"`
	LoadCPU  float64     `json:"loadgen_cpu"`
	Note     string      `json:"note,omitempty"`
	// Feed: the fan-out and trading details (scenario ws).
	Feed *ws.FeedResult `json:"feed,omitempty"`
	// Video: the paced viewers' playback (scenario video).
	Video *video.Result `json:"video,omitempty"`
	Error string        `json:"error,omitempty"`
	At    time.Time     `json:"at"`
}

type Suite struct {
	Cfg      sut.Config
	BenchDir string
	Out      string
	Profile  Profile
	Servers  []string
	Tiers    []sut.Tier
	LoadCPUs int
	// Modes, when set, limits raw to those server modes (h1, tls, h2c, h3).
	Modes []string
	// TwelveBrackets, when set, makes the $12 scenario refine an earlier
	// run: per "tier|server", the users that passed and the users that failed.
	TwelveBrackets map[string][2]int
	mu             sync.Mutex
	cases          []Case
	f              *os.File
	manifests      map[string]sut.Manifest
}

func New(cfg sut.Config, benchDir, out string, p Profile, servers []string, tiers []sut.Tier, loadCPUs int) (*Suite, error) {
	if err := os.MkdirAll(out, 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(out, "cases.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	s := &Suite{Cfg: cfg, BenchDir: benchDir, Out: out, Profile: p, Servers: servers, Tiers: tiers,
		LoadCPUs: loadCPUs, f: f, manifests: map[string]sut.Manifest{}}
	for _, name := range servers {
		m, err := sut.LoadManifest(benchDir, name)
		if err != nil {
			return nil, fmt.Errorf("manifest %s: %v", name, err)
		}
		s.manifests[name] = m
	}
	return s, nil
}

func (s *Suite) Close() { s.f.Close() }

// ServersIn is the servers of all that take part in scenario sc.
func (s *Suite) ServersIn(all []string, sc string) []string {
	var in []string
	for _, name := range all {
		if s.manifests[name].In(sc) {
			in = append(in, name)
		}
	}
	return in
}

func (s *Suite) record(c Case) {
	c.At = time.Now().UTC()
	if c.Label == "" {
		m := s.manifests[c.Server]
		c.Label = m.Modes[c.Mode]
		if c.Mode == "grpc" {
			c.Label = m.GRPC
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cases = append(s.cases, c)
	b, _ := json.Marshal(c)
	s.f.Write(append(b, '\n'))
	status := fmt.Sprintf("%10.0f req/s  p99 %7.2f ms  mem %6.1f MB  cpu %.2f (busy %.2f)  loadgen %.1f", c.Load.RPS, c.Load.P99MS, c.SUT.MemMB, c.SUT.CPU, c.SUT.CoresBusy, c.LoadCPU)
	if c.Error != "" {
		status = "ERROR " + firstLine(c.Error)
	}
	log.Printf("%-8s %-8s %-6s %-7s %-10s %-12s %s", c.Scenario, c.Server, c.Tier, c.Proto, c.Endpoint, c.Param, status)
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// measure runs fn Reps times (after one warm-up when warm is true) while
// sampling the server and this container, and keeps the median run by
// req/s.
func (s *Suite) measure(srv *sut.Server, warm bool, fn func(d time.Duration) (load.Result, error)) (load.Result, sut.Usage, float64, error) {
	if warm && s.Profile.Warmup > 0 {
		fn(s.Profile.Warmup)
	}
	type rep struct {
		r    load.Result
		u    sut.Usage
		lcpu float64
	}
	var reps []rep
	var lastErr error
	for i := 0; i < s.Profile.Reps; i++ {
		smp := srv.Sample(500*time.Millisecond, false)
		self := sut.StartSampler("/sys/fs/cgroup", 500*time.Millisecond, false)
		r, err := fn(s.Profile.Run)
		u := smp.Stop()
		lu := self.Stop()
		if err != nil {
			lastErr = err
			continue
		}
		reps = append(reps, rep{r, u, lu.CPU})
	}
	if len(reps) == 0 {
		return load.Result{}, sut.Usage{}, 0, lastErr
	}
	sort.Slice(reps, func(i, j int) bool { return reps[i].r.RPS < reps[j].r.RPS })
	m := reps[len(reps)/2]
	return m.r, m.u, m.lcpu, nil
}

// note flags a run whose load generator was near its own limit, or whose
// server died.
func (s *Suite) note(srv *sut.Server, loadCPU float64) string {
	var notes []string
	if loadCPU > 0.7*float64(s.LoadCPUs) {
		notes = append(notes, fmt.Sprintf("load generator at %.1f of %d CPUs", loadCPU, s.LoadCPUs))
	}
	if exited, why := srv.Exited(); exited {
		notes = append(notes, "server "+why)
	} else if n := srv.OOMEvents(); n > 0 {
		notes = append(notes, fmt.Sprintf("%d OOM kills", n))
	}
	return strings.Join(notes, "; ")
}

func (s *Suite) wrkThreads(tier sut.Tier) int {
	if tier.CPUs >= 4 {
		return 16
	}
	return 8
}

func (s *Suite) script() string { return filepath.Join(s.BenchDir, "loadgen", "report.lua") }

// protos lists what one server mode is driven with: each entry is a
// protocol name and the function that runs one load case for it.
func (s *Suite) protos(m sut.Manifest, mode string, tier sut.Tier) []string {
	switch mode {
	case "h1":
		return []string{"h1"}
	case "h2c":
		return []string{"h2c"}
	case "tls":
		out := []string{"h1-tls"}
		for _, a := range m.TLSALPN {
			if a == "h2" {
				out = append(out, "h2-tls")
			}
		}
		return out
	case "h3":
		return []string{"h3"}
	}
	return nil
}

// closedLoop is the max-throughput load for a protocol.
func (s *Suite) closedLoop(proto, url string, tier sut.Tier, conns int, d time.Duration) (load.Result, error) {
	t := s.wrkThreads(tier)
	switch proto {
	case "h1", "h1-tls":
		return load.Wrk(load.WrkOpts{URL: url, Threads: t, Conns: conns, Duration: d, Script: s.script()})
	case "h2c", "h2-tls":
		return load.H2load(load.H2loadOpts{URL: url, Threads: t / 2, Clients: 64, Streams: 10, Duration: d})
	case "h3":
		return load.H2load(load.H2loadOpts{URL: url, Threads: t / 2, Clients: 64, Streams: 10, Duration: d, H3: true})
	}
	return load.Result{}, fmt.Errorf("unknown proto %s", proto)
}

var rawModes = []string{"h1", "tls", "h2c", "h3"}

// Raw: the max-throughput matrix (closed loop), every server, tier,
// supported protocol and endpoint.
func (s *Suite) Raw() {
	for _, tier := range s.Tiers {
		for _, name := range s.Servers {
			m := s.manifests[name]
			for _, mode := range rawModes {
				if !m.Supports(mode) || (len(s.Modes) > 0 && !slices.Contains(s.Modes, mode)) {
					continue
				}
				srv, err := sut.Start(s.Cfg, name, mode, tier, nil, 0)
				if err != nil {
					s.record(Case{Scenario: "raw", Server: name, Mode: mode, Tier: tier.Name, Error: err.Error()})
					continue
				}
				for _, proto := range s.protos(m, mode, tier) {
					for _, ep := range s.Profile.Endpoints {
						url := sut.URL(mode) + ep
						r, u, lcpu, err := s.measure(srv, true, func(d time.Duration) (load.Result, error) {
							return s.closedLoop(proto, url, tier, 256, d)
						})
						c := Case{Scenario: "raw", Server: name, Mode: mode, Proto: proto, Tier: tier.Name, Endpoint: ep,
							Load: r, SUT: u, LoadCPU: lcpu, Note: s.note(srv, lcpu)}
						if err != nil {
							c.Error = err.Error()
						}
						s.record(c)
					}
				}
				sut.Stop()
			}
		}
	}
}

// Conns: the concurrent-users sweep, HTTP/1.1 keep-alive /json at rising
// connection counts, on the first tier.
func (s *Suite) Conns() {
	tier := s.Tiers[0]
	for _, name := range s.Servers {
		srv, err := sut.Start(s.Cfg, name, "h1", tier, nil, 0)
		if err != nil {
			s.record(Case{Scenario: "conns", Server: name, Mode: "h1", Tier: tier.Name, Error: err.Error()})
			continue
		}
		for _, c := range s.Profile.Conns {
			url := sut.URL("h1") + "/json"
			r, u, lcpu, err := s.measure(srv, c == s.Profile.Conns[0], func(d time.Duration) (load.Result, error) {
				return load.Wrk(load.WrkOpts{URL: url, Threads: s.wrkThreads(sut.Tier{CPUs: 4}), Conns: c, Duration: d, Script: s.script()})
			})
			cs := Case{Scenario: "conns", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Endpoint: "/json",
				Param: fmt.Sprintf("c=%d", c), Load: r, SUT: u, LoadCPU: lcpu, Note: s.note(srv, lcpu)}
			if err != nil {
				cs.Error = err.Error()
			}
			s.record(cs)
			if exited, _ := srv.Exited(); exited {
				break
			}
		}
		sut.Stop()
	}
}

// maxRPS is the best raw /json req/s a server reached for a protocol on a
// tier in this run, or 0.
func (s *Suite) maxRPS(server, proto, tier string) float64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	best := 0.0
	for _, c := range s.cases {
		if c.Scenario == "raw" && c.Server == server && c.Proto == proto && c.Tier == tier && c.Endpoint == "/json" && c.Error == "" && c.Load.RPS > best {
			best = c.Load.RPS
		}
	}
	return best
}

// LoadPrior reads cases from earlier runs (to find each server's max for
// the latency rates when raw is not part of this run).
func (s *Suite) LoadPrior(paths []string) {
	for _, p := range paths {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			var c Case
			if json.Unmarshal([]byte(line), &c) == nil && c.Scenario != "" {
				s.cases = append(s.cases, c)
			}
		}
	}
}

// Fixed request rates every server is measured at (when it can sustain
// them), plus fractions of its own maximum.
var latencyRates = []int{1000, 5000, 20000}
var latencyFractions = []float64{0.5, 0.75}

// Latency: open-loop fixed-rate runs with coordinated-omission correction
// (oha), per protocol, /json, first tier.
func (s *Suite) Latency() {
	tier := s.Tiers[0]
	for _, name := range s.Servers {
		m := s.manifests[name]
		for _, mode := range []string{"h1", "tls", "h3"} {
			if !m.Supports(mode) {
				continue
			}
			proto := map[string]string{"h1": "h1", "tls": "h2-tls", "h3": "h3"}[mode]
			ohaProto := map[string]string{"h1": "1.1", "tls": "2", "h3": "3"}[mode]
			if proto == "h2-tls" && !contains(m.TLSALPN, "h2") {
				proto, ohaProto = "h1-tls", "1.1"
			}
			max := s.maxRPS(name, proto, tier.Name)
			type rate struct {
				n     int
				label string
			}
			var rates []rate
			for _, r := range latencyRates {
				if max == 0 || float64(r) <= max*0.9 {
					rates = append(rates, rate{r, fmt.Sprintf("rate=%d", r)})
				}
			}
			// The % of max rates only over HTTP/1.1 (wrk in raw): raw measures h2 and h3
			// with h2load's 64 connections × 10 streams, which oha (one
			// request in flight per connection) cannot reach.
			if max > 0 && ohaProto == "1.1" {
				for _, f := range latencyFractions {
					rates = append(rates, rate{int(max * f), fmt.Sprintf("rate=%.0f%%max", f*100)})
				}
			}
			if len(rates) == 0 {
				continue
			}
			srv, err := sut.Start(s.Cfg, name, mode, tier, nil, 0)
			if err != nil {
				s.record(Case{Scenario: "latency", Server: name, Mode: mode, Proto: proto, Tier: tier.Name, Error: err.Error()})
				continue
			}
			for i, rt := range rates {
				url := sut.URL(mode) + "/json"
				r, u, lcpu, err := s.measure(srv, i == 0, func(d time.Duration) (load.Result, error) {
					return load.Oha(load.OhaOpts{URL: url, Conns: 64, Rate: rt.n, Duration: d, Proto: ohaProto})
				})
				c := Case{Scenario: "latency", Server: name, Mode: mode, Proto: proto, Tier: tier.Name, Endpoint: "/json",
					Param: rt.label, Load: r, SUT: u, LoadCPU: lcpu, Note: s.note(srv, lcpu)}
				if err != nil {
					c.Error = err.Error()
				} else if r.RPS < float64(rt.n)*0.95 {
					c.Note = strings.TrimPrefix(c.Note+fmt.Sprintf("; fell behind: %.0f of %d req/s", r.RPS, rt.n), "; ")
				}
				s.record(c)
			}
			sut.Stop()
		}
	}
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
