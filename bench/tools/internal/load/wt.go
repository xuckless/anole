package load

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// WtOpts runs wtload (bench/tools/wtload), a WebTransport draft-02 client.
type WtOpts struct {
	URL  string
	Mode string // sessions, streams or datagrams
	N, C int    // sessions: how many, how many handshakes at once
	S, P int    // streams, datagrams: sessions; streams in flight per session
	Size int    // bytes per stream or per datagram
	Rate int    // datagrams per second per session
	// Duration of a streams or datagrams run.
	Duration time.Duration
}

type wtLatency struct {
	N    int64   `json:"n"`
	P50  float64 `json:"p50_ms"`
	P99  float64 `json:"p99_ms"`
	P999 float64 `json:"p999_ms"`
	Max  float64 `json:"max_ms"`
}

type wtOut struct {
	OK              int64            `json:"ok"`
	Failures        int64            `json:"failures"`
	SessionsPerS    float64          `json:"sessions_per_s"`
	Handshake       wtLatency        `json:"handshake"`
	Streams         int64            `json:"streams"`
	StreamsPerS     float64          `json:"streams_per_s"`
	MBPerS          float64          `json:"mb_per_s"`
	RTT             wtLatency        `json:"rtt"`
	Errors          int64            `json:"errors"`
	Mismatches      int64            `json:"mismatches"`
	SessionFailures int64            `json:"session_failures"`
	Sent            int64            `json:"sent"`
	Received        int64            `json:"received"`
	LossPct         float64          `json:"loss_pct"`
	SendErrors      int64            `json:"send_errors"`
	Corrupt         int64            `json:"corrupt"`
	DurationS       float64          `json:"duration_s"`
	ErrorSamples    map[string]int64 `json:"error_samples"`
}

// Wtload runs one wtload measurement. The note says what the result's
// columns cannot: datagram loss, and the most common error.
func Wtload(o WtOpts) (Result, string, error) {
	args := []string{"-url", o.URL, "-mode", o.Mode}
	add := func(flag string, v int) {
		if v > 0 {
			args = append(args, flag, strconv.Itoa(v))
		}
	}
	add("-n", o.N)
	add("-c", o.C)
	add("-s", o.S)
	add("-p", o.P)
	add("-size", o.Size)
	add("-rate", o.Rate)
	if o.Duration > 0 {
		args = append(args, "-d", o.Duration.String())
	}
	// wtload exits 1 when no session opened, with its JSON still printed.
	out, runErr := run(o.Duration+3*time.Minute, "wtload", args...)
	var w wtOut
	if err := json.Unmarshal([]byte(lastLine(out)), &w); err != nil {
		if runErr != nil {
			return Result{}, "", runErr
		}
		return Result{}, "", fmt.Errorf("wtload output: %v: %q", err, out)
	}
	r := Result{Tool: "wtload", Args: strings.Join(args, " ")}
	lat := w.RTT
	var notes []string
	switch o.Mode {
	case "sessions":
		r.Requests, r.RPS, r.Errors = w.OK, w.SessionsPerS, w.Failures
		lat = w.Handshake
	case "streams":
		r.Requests, r.RPS, r.MBps = w.Streams, w.StreamsPerS, w.MBPerS
		r.Errors = w.Errors + w.Mismatches + w.SessionFailures
	case "datagrams":
		r.Requests, r.Errors = w.Received, w.SendErrors+w.Corrupt+w.SessionFailures
		if w.DurationS > 0 {
			r.RPS = float64(w.Received) / w.DurationS
		}
		notes = append(notes, fmt.Sprintf("loss %.2f%% (%d of %d)", w.LossPct, w.Sent-w.Received, w.Sent))
	}
	r.P50MS, r.P99MS, r.P999MS, r.MaxMS = lat.P50, lat.P99, lat.P999, lat.Max
	if len(w.ErrorSamples) > 0 {
		keys := make([]string, 0, len(w.ErrorSamples))
		for k := range w.ErrorSamples {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(i, j int) bool { return w.ErrorSamples[keys[i]] > w.ErrorSamples[keys[j]] })
		notes = append(notes, fmt.Sprintf("%dx %s", w.ErrorSamples[keys[0]], keys[0]))
	}
	if r.Requests == 0 && runErr != nil {
		return r, strings.Join(notes, "; "), fmt.Errorf("wtload: nothing completed: %s", strings.Join(notes, "; "))
	}
	return r, strings.Join(notes, "; "), nil
}

func lastLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		return s[i+1:]
	}
	return s
}
