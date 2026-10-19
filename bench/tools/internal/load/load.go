// Package load runs the load tools (wrk, h2load, oha) and parses their
// output into one Result shape.
package load

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Result is one load run. Latencies are in milliseconds; a zero
// percentile means the tool does not report it (h2load).
type Result struct {
	Tool     string  `json:"tool"`
	Args     string  `json:"args"`
	Requests int64   `json:"requests"`
	RPS      float64 `json:"rps"`
	MBps     float64 `json:"mbps,omitempty"`
	Errors   int64   `json:"errors"`
	Non2xx   int64   `json:"non2xx"`
	MeanMS   float64 `json:"mean_ms"`
	P50MS    float64 `json:"p50_ms,omitempty"`
	P90MS    float64 `json:"p90_ms,omitempty"`
	P95MS    float64 `json:"p95_ms,omitempty"`
	P99MS    float64 `json:"p99_ms,omitempty"`
	P999MS   float64 `json:"p999_ms,omitempty"`
	MaxMS    float64 `json:"max_ms"`
}

func run(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	var out, errb bytes.Buffer
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	if err != nil {
		return out.String(), fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, tail(errb.String()+out.String(), 600))
	}
	return out.String(), nil
}

func tail(s string, n int) string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}

// WrkOpts: HTTP/1.1, cleartext or TLS, closed loop (as fast as it goes).
type WrkOpts struct {
	URL      string
	Threads  int
	Conns    int
	Duration time.Duration
	Script   string // report.lua, or a script that also sets the request
}

func Wrk(o WrkOpts) (Result, error) {
	if o.Threads > o.Conns {
		o.Threads = o.Conns
	}
	args := []string{"-t", strconv.Itoa(o.Threads), "-c", strconv.Itoa(o.Conns),
		"-d", fmt.Sprintf("%ds", int(o.Duration.Seconds())), "--timeout", "10s", "-s", o.Script, o.URL}
	out, err := run(o.Duration+60*time.Second, "wrk", args...)
	r := Result{Tool: "wrk", Args: strings.Join(args[:len(args)-1], " ")}
	if err != nil {
		return r, err
	}
	i := strings.Index(out, "JSON ")
	if i < 0 {
		return r, fmt.Errorf("wrk: no summary in %q", tail(out, 400))
	}
	var s struct {
		Requests, DurationUS, Bytes, Errors, Non2xx int64
		MeanUS                                      float64
		MaxUS, P50US, P90US, P99US, P999US          float64
	}
	line := out[i+5:]
	if j := strings.IndexByte(line, '\n'); j >= 0 {
		line = line[:j]
	}
	var raw map[string]float64
	if err := json.Unmarshal([]byte(line), &raw); err != nil {
		return r, fmt.Errorf("wrk summary %q: %v", line, err)
	}
	s.Requests, s.DurationUS, s.Bytes = int64(raw["requests"]), int64(raw["duration_us"]), int64(raw["bytes"])
	r.Requests, r.Errors, r.Non2xx = s.Requests, int64(raw["errors"]), int64(raw["non2xx"])
	sec := float64(s.DurationUS) / 1e6
	if sec > 0 {
		r.RPS = float64(s.Requests) / sec
		r.MBps = float64(s.Bytes) / sec / 1e6
	}
	r.MeanMS = raw["mean_us"] / 1000
	r.P50MS, r.P90MS = raw["p50_us"]/1000, raw["p90_us"]/1000
	r.P99MS, r.P999MS, r.MaxMS = raw["p99_us"]/1000, raw["p999_us"]/1000, raw["max_us"]/1000
	return r, nil
}

// H2loadOpts: HTTP/2 (h2c prior knowledge, or ALPN h2 over TLS) or HTTP/3.
type H2loadOpts struct {
	URL      string
	Threads  int
	Clients  int
	Streams  int // concurrent streams per connection (-m)
	Duration time.Duration
	H3       bool
}

var (
	reFinished = regexp.MustCompile(`finished in ([\d.]+)(\w+), ([\d.]+) req/s, ([\d.]+)(\w+)/s`)
	reRequests = regexp.MustCompile(`requests: (\d+) total, (\d+) started, (\d+) done, (\d+) succeeded, (\d+) failed, (\d+) errored, (\d+) timeout`)
	reStatus   = regexp.MustCompile(`status codes: (\d+) 2xx, (\d+) 3xx, (\d+) 4xx, (\d+) 5xx`)
	reReqTime  = regexp.MustCompile(`time for request:\s+([\d.]+)(\w+)\s+([\d.]+)(\w+)\s+([\d.]+)(\w+)`)
)

func H2load(o H2loadOpts) (Result, error) {
	if o.Threads > o.Clients {
		o.Threads = o.Clients
	}
	args := []string{"-t", strconv.Itoa(o.Threads), "-c", strconv.Itoa(o.Clients),
		"-m", strconv.Itoa(o.Streams), "-D", strconv.Itoa(int(o.Duration.Seconds()))}
	if o.H3 {
		args = append(args, "--alpn-list=h3")
	}
	args = append(args, o.URL)
	out, err := run(o.Duration+60*time.Second, "h2load", args...)
	r := Result{Tool: "h2load", Args: strings.Join(args[:len(args)-1], " ")}
	if err != nil {
		return r, err
	}
	m := reFinished.FindStringSubmatch(out)
	if m == nil {
		return r, fmt.Errorf("h2load: %q", tail(out, 600))
	}
	r.RPS, _ = strconv.ParseFloat(m[3], 64)
	r.MBps = unitMB(m[4], m[5])
	if q := reRequests.FindStringSubmatch(out); q != nil {
		r.Requests, _ = strconv.ParseInt(q[4], 10, 64)
		failed, _ := strconv.ParseInt(q[5], 10, 64)
		errored, _ := strconv.ParseInt(q[6], 10, 64)
		timeout, _ := strconv.ParseInt(q[7], 10, 64)
		r.Errors = failed + errored + timeout
	}
	if q := reStatus.FindStringSubmatch(out); q != nil {
		for _, s := range q[2:] {
			n, _ := strconv.ParseInt(s, 10, 64)
			r.Non2xx += n
		}
	}
	if q := reReqTime.FindStringSubmatch(out); q != nil {
		r.MaxMS = ms(q[3], q[4])
		r.MeanMS = ms(q[5], q[6])
	}
	if r.Requests == 0 {
		return r, fmt.Errorf("h2load: no successful requests: %q", tail(out, 600))
	}
	return r, nil
}

func ms(v, unit string) float64 {
	f, _ := strconv.ParseFloat(v, 64)
	switch unit {
	case "us":
		return f / 1000
	case "s":
		return f * 1000
	}
	return f
}

func unitMB(v, unit string) float64 {
	f, _ := strconv.ParseFloat(v, 64)
	switch unit {
	case "KB":
		return f / 1000
	case "GB":
		return f * 1000
	case "B":
		return f / 1e6
	}
	return f
}

// OhaOpts: an open-loop run at a fixed rate with latency correction
// (coordinated omission accounted for), on any HTTP version.
type OhaOpts struct {
	URL      string
	Conns    int
	Rate     int // requests per second; 0 = closed loop
	Duration time.Duration
	Proto    string // "1.1", "2" or "3"
}

func Oha(o OhaOpts) (Result, error) {
	args := []string{"--no-tui", "--output-format", "json", "-z", fmt.Sprintf("%ds", int(o.Duration.Seconds())),
		"-c", strconv.Itoa(o.Conns), "--insecure"}
	if o.Rate > 0 {
		args = append(args, "-q", strconv.Itoa(o.Rate), "--latency-correction")
	}
	switch o.Proto {
	case "2":
		args = append(args, "--http2")
	case "3":
		args = append(args, "--http-version", "3")
	}
	args = append(args, o.URL)
	out, err := run(o.Duration+60*time.Second, "oha", args...)
	r := Result{Tool: "oha", Args: strings.Join(args[:len(args)-1], " ")}
	if err != nil {
		return r, err
	}
	var s struct {
		Summary struct {
			Total          float64 `json:"total"`
			RequestsPerSec float64 `json:"requestsPerSec"`
			Average        float64 `json:"average"`
			Slowest        float64 `json:"slowest"`
			SizePerSec     float64 `json:"sizePerSec"`
		} `json:"summary"`
		LatencyPercentiles     map[string]float64 `json:"latencyPercentiles"`
		StatusCodeDistribution map[string]int64   `json:"statusCodeDistribution"`
		ErrorDistribution      map[string]int64   `json:"errorDistribution"`
	}
	if err := json.Unmarshal([]byte(out), &s); err != nil {
		return r, fmt.Errorf("oha json: %v: %q", err, tail(out, 400))
	}
	for code, n := range s.StatusCodeDistribution {
		r.Requests += n
		if !strings.HasPrefix(code, "2") {
			r.Non2xx += n
		}
	}
	for _, n := range s.ErrorDistribution {
		r.Errors += n
	}
	r.RPS = s.Summary.RequestsPerSec
	r.MBps = s.Summary.SizePerSec / 1e6
	r.MeanMS, r.MaxMS = s.Summary.Average*1000, s.Summary.Slowest*1000
	r.P50MS = s.LatencyPercentiles["p50"] * 1000
	r.P90MS = s.LatencyPercentiles["p90"] * 1000
	r.P99MS = s.LatencyPercentiles["p99"] * 1000
	r.P999MS = s.LatencyPercentiles["p99.9"] * 1000
	return r, nil
}

// GhzOpts: gRPC unary calls to grpc.testing.TestService/UnaryCall.
type GhzOpts struct {
	Target      string // host:port, plaintext (h2c)
	ProtoDir    string // holds grpc/testing/test.proto
	Conns       int
	Concurrency int
	RespSize    int // response_size: bytes of payload in each reply
	Duration    time.Duration
}

// Ghz runs ghz for o.Duration. ghz reports latencies in nanoseconds and has
// no p99.9.
func Ghz(o GhzOpts) (Result, error) {
	args := []string{"--insecure", "--import-paths", o.ProtoDir,
		"--proto", filepath.Join(o.ProtoDir, "grpc", "testing", "test.proto"),
		"--call", "grpc.testing.TestService/UnaryCall",
		"-d", fmt.Sprintf(`{"response_size":%d}`, o.RespSize),
		"--connections", strconv.Itoa(o.Conns), "-c", strconv.Itoa(o.Concurrency),
		"-z", o.Duration.String(), "--format", "json", o.Target}
	out, err := run(o.Duration+time.Minute, "ghz", args...)
	if err != nil {
		return Result{}, err
	}
	var g struct {
		Count   int64   `json:"count"`
		RPS     float64 `json:"rps"`
		Average float64 `json:"average"`
		Slowest float64 `json:"slowest"`
		Dist    []struct {
			Percentage int     `json:"percentage"`
			Latency    float64 `json:"latency"`
		} `json:"latencyDistribution"`
		Status map[string]int64 `json:"statusCodeDistribution"`
	}
	if err := json.Unmarshal([]byte(out), &g); err != nil {
		return Result{}, fmt.Errorf("ghz output: %v: %s", err, tail(out, 300))
	}
	r := Result{Tool: "ghz", Args: strings.Join(args, " "), Requests: g.Count, RPS: g.RPS,
		MeanMS: g.Average / 1e6, MaxMS: g.Slowest / 1e6}
	for code, n := range g.Status {
		if code != "OK" {
			r.Errors += n
		}
	}
	for _, p := range g.Dist {
		switch p.Percentage {
		case 50:
			r.P50MS = p.Latency / 1e6
		case 90:
			r.P90MS = p.Latency / 1e6
		case 95:
			r.P95MS = p.Latency / 1e6
		case 99:
			r.P99MS = p.Latency / 1e6
		}
	}
	return r, nil
}

// GcannonWS: gcannon's WebSocket echo (HttpArena's ws-echo profiles).
type GcannonWS struct {
	URL      string // ws://127.0.0.1:8080/ws/echo as http://, gcannon's form
	Conns    int
	Threads  int
	Pipeline int // messages in flight per connection
	Duration time.Duration
}

// Gcannon runs gcannon --ws --json. Its rate is echoed frames per second.
func Gcannon(o GcannonWS) (Result, error) {
	args := []string{o.URL, "--ws", "--json", "-c", strconv.Itoa(o.Conns), "-t", strconv.Itoa(o.Threads),
		"-p", strconv.Itoa(o.Pipeline), "-d", fmt.Sprintf("%ds", int(o.Duration.Seconds()))}
	out, err := run(o.Duration+time.Minute, "gcannon", args...)
	r := Result{Tool: "gcannon", Args: strings.Join(args[1:], " ")}
	if err != nil {
		return r, err
	}
	var g struct {
		Elapsed   float64 `json:"elapsed_sec"`
		Responses int64   `json:"responses"`
		RPS       float64 `json:"rps"`
		WSFrames  int64   `json:"ws_frames"`
		WSUpgr    int64   `json:"ws_upgrades"`
		Latency   struct {
			Avg, P50, P90, P99, P999 float64
		} `json:"latency_us"`
		Errors struct {
			Connect, Read, Timeout int64
		} `json:"errors"`
		Reconnects int64 `json:"reconnects"`
	}
	i := strings.IndexByte(out, '{')
	if i < 0 || json.Unmarshal([]byte(out[i:]), &g) != nil {
		return r, fmt.Errorf("gcannon: no JSON in %q", tail(out, 400))
	}
	frames := g.WSFrames
	if frames == 0 {
		frames = g.Responses
	}
	r.Requests, r.RPS = frames, g.RPS
	if g.Elapsed > 0 && frames > 0 {
		r.RPS = float64(frames) / g.Elapsed
	}
	r.Errors = g.Errors.Connect + g.Errors.Read + g.Errors.Timeout
	r.MeanMS, r.P50MS, r.P90MS, r.P99MS, r.P999MS = g.Latency.Avg/1e3, g.Latency.P50/1e3, g.Latency.P90/1e3, g.Latency.P99/1e3, g.Latency.P999/1e3
	if r.Requests == 0 {
		return r, fmt.Errorf("gcannon: no frames echoed: %q", tail(out, 400))
	}
	return r, nil
}
