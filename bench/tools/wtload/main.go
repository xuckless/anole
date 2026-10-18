// wtload drives a WebTransport (draft-02) server's /wt/echo endpoint and
// prints one JSON line of results.
//
//	wtload -url https://127.0.0.1:8443/wt/echo -mode sessions  -n 200 -c 20
//	wtload -url https://127.0.0.1:8443/wt/echo -mode streams   -s 8 -d 10s -size 16384
//	wtload -url https://127.0.0.1:8443/wt/echo -mode datagrams -s 8 -d 10s -size 64 -rate 1000
//	wtload -url https://127.0.0.1:8443/wt/echo -mode idle      -s 4 -d 80s   (the 75 s idle rule)
//
// It exits with status 1 when nothing succeeded (no session opened), so
// "-mode sessions -n 1" doubles as a readiness probe.
//
// It is a module of its own because it pins webtransport-go v0.10.0, the
// last release that speaks draft-02 (the version browsers use), and the
// quic-go it requires; bench/tools tracks the current quic-go.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/quic-go/webtransport-go"
)

// Lat is a latency summary in milliseconds (the same shape benchctl uses).
type Lat struct {
	N      int     `json:"n"`
	P50MS  float64 `json:"p50_ms"`
	P99MS  float64 `json:"p99_ms"`
	P999MS float64 `json:"p999_ms"`
	MaxMS  float64 `json:"max_ms"`
}

// samples collects microsecond latencies from many goroutines.
type samples struct {
	mu sync.Mutex
	us []int64
}

func (s *samples) add(d time.Duration) {
	s.mu.Lock()
	s.us = append(s.us, d.Microseconds())
	s.mu.Unlock()
}

func (s *samples) summary() Lat {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.us) == 0 {
		return Lat{}
	}
	sort.Slice(s.us, func(i, j int) bool { return s.us[i] < s.us[j] })
	p := func(q float64) float64 { return float64(s.us[int(q*float64(len(s.us)-1))]) / 1000 }
	return Lat{N: len(s.us), P50MS: p(0.5), P99MS: p(0.99), P999MS: p(0.999), MaxMS: float64(s.us[len(s.us)-1]) / 1000}
}

// errSamples counts errors by message, so a failing run says why.
type errSamples struct {
	mu sync.Mutex
	n  int64
	m  map[string]int64
}

func (e *errSamples) add(err error) {
	msg := err.Error()
	if len(msg) > 200 {
		msg = msg[:200]
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.n++
	if e.m == nil {
		e.m = map[string]int64{}
	}
	if _, ok := e.m[msg]; ok || len(e.m) < 8 {
		e.m[msg]++
	}
}

func (e *errSamples) count() int64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.n
}

func (e *errSamples) messages() map[string]int64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.m) == 0 {
		return nil
	}
	out := make(map[string]int64, len(e.m))
	for k, v := range e.m {
		out[k] = v
	}
	return out
}

type config struct {
	url      string
	mode     string
	n        int
	c        int
	s        int
	p        int
	d        time.Duration
	size     int
	rate     int
	timeout  time.Duration
	idle     time.Duration
	keepOpen bool
}

func main() {
	var cfg config
	flag.StringVar(&cfg.url, "url", "https://127.0.0.1:8443/wt/echo", "WebTransport endpoint")
	flag.StringVar(&cfg.mode, "mode", "sessions", "sessions | streams | datagrams | idle")
	flag.IntVar(&cfg.n, "n", 100, "sessions: how many sessions to open")
	flag.IntVar(&cfg.c, "c", 10, "sessions: how many handshakes in flight at once")
	flag.IntVar(&cfg.s, "s", 4, "streams, datagrams, idle: concurrent sessions (one QUIC connection each)")
	flag.IntVar(&cfg.p, "p", 1, "streams: streams in flight per session")
	flag.DurationVar(&cfg.d, "d", 5*time.Second, "streams, datagrams: how long to run; idle: how long to stay silent")
	flag.IntVar(&cfg.size, "size", 0, "bytes per stream (default 16384) or per datagram (default 64)")
	flag.IntVar(&cfg.rate, "rate", 1000, "datagrams: datagrams per second per session")
	flag.DurationVar(&cfg.timeout, "timeout", 10*time.Second, "per handshake and per stream round trip")
	flag.DurationVar(&cfg.idle, "idle", 120*time.Second, "QUIC idle timeout the client asks for")
	flag.BoolVar(&cfg.keepOpen, "keep", false, "sessions: keep every session open until all are done (concurrent sessions), instead of closing each after its handshake")
	flag.Parse()

	var out any
	var ok bool
	switch cfg.mode {
	case "sessions":
		r := runSessions(cfg)
		out, ok = r, r.OK > 0
	case "streams":
		if cfg.size == 0 {
			cfg.size = 16 << 10
		}
		r := runStreams(cfg)
		out, ok = r, r.SessionsOpen > 0
	case "datagrams":
		if cfg.size == 0 {
			cfg.size = 64
		}
		if cfg.size < headerLen {
			fmt.Fprintf(os.Stderr, "wtload: -size must be at least %d for datagrams\n", headerLen)
			os.Exit(2)
		}
		r := runDatagrams(cfg)
		out, ok = r, r.SessionsOpen > 0
	case "idle":
		if cfg.idle <= cfg.d {
			cfg.idle = cfg.d + 30*time.Second
		}
		r := runIdle(cfg)
		out, ok = r, r.SessionsOpen > 0
	default:
		fmt.Fprintf(os.Stderr, "wtload: unknown -mode %q (sessions, streams or datagrams)\n", cfg.mode)
		os.Exit(2)
	}
	b, _ := json.Marshal(out)
	os.Stdout.Write(append(b, '\n'))
	if !ok {
		os.Exit(1)
	}
}

func newDialer(cfg config) *webtransport.Dialer {
	keepAlive := cfg.idle / 3
	if cfg.mode == "idle" {
		keepAlive = 0 // stay silent, so the server's idle timeout is what counts
	}
	return &webtransport.Dialer{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true, NextProtos: []string{http3.NextProtoH3}},
		QUICConfig: &quic.Config{
			EnableDatagrams:                  true,
			EnableStreamResetPartialDelivery: true, // webtransport-go insists; draft-02 peers simply don't use it
			MaxIdleTimeout:                   cfg.idle,
			KeepAlivePeriod:                  keepAlive,
		},
	}
}

// dial opens one session (one QUIC connection) and checks the answer.
func dial(ctx context.Context, d *webtransport.Dialer, url string) (*webtransport.Session, error) {
	rsp, sess, err := d.Dial(ctx, url, nil)
	if err != nil {
		if rsp != nil {
			return nil, fmt.Errorf("status %d: %w", rsp.StatusCode, err)
		}
		return nil, err
	}
	return sess, nil
}

// ---- sessions ----

type sessionsResult struct {
	Mode        string           `json:"mode"`
	URL         string           `json:"url"`
	Sessions    int              `json:"sessions"`
	Concurrency int              `json:"concurrency"`
	OK          int64            `json:"ok"`
	Failures    int64            `json:"failures"`
	ElapsedS    float64          `json:"elapsed_s"`
	PerS        float64          `json:"sessions_per_s"`
	Handshake   Lat              `json:"handshake"`
	Errors      map[string]int64 `json:"error_samples,omitempty"`
}

func runSessions(cfg config) sessionsResult {
	d := newDialer(cfg)
	var lat samples
	var errs errSamples
	var ok atomic.Int64
	var next atomic.Int64
	var mu sync.Mutex
	var open []*webtransport.Session

	start := time.Now()
	var wg sync.WaitGroup
	for w := 0; w < max(1, cfg.c); w++ {
		wg.Go(func() {
			for next.Add(1) <= int64(cfg.n) {
				ctx, cancel := context.WithTimeout(context.Background(), cfg.timeout)
				t0 := time.Now()
				sess, err := dial(ctx, d, cfg.url)
				cancel()
				if err != nil {
					errs.add(err)
					continue
				}
				lat.add(time.Since(t0))
				ok.Add(1)
				if cfg.keepOpen {
					mu.Lock()
					open = append(open, sess)
					mu.Unlock()
				} else {
					sess.CloseWithError(0, "")
				}
			}
		})
	}
	wg.Wait()
	elapsed := time.Since(start)
	for _, s := range open {
		s.CloseWithError(0, "")
	}
	return sessionsResult{
		Mode: "sessions", URL: cfg.url, Sessions: cfg.n, Concurrency: cfg.c,
		OK: ok.Load(), Failures: errs.count(), ElapsedS: round3(elapsed.Seconds()),
		PerS: round3(float64(ok.Load()) / elapsed.Seconds()), Handshake: lat.summary(), Errors: errs.messages(),
	}
}

// ---- streams ----

type streamsResult struct {
	Mode            string           `json:"mode"`
	URL             string           `json:"url"`
	Sessions        int              `json:"sessions"`
	SessionsOpen    int64            `json:"sessions_open"`
	PerSession      int              `json:"streams_in_flight_per_session"`
	Size            int              `json:"size"`
	DurationS       float64          `json:"duration_s"`
	Streams         int64            `json:"streams"`
	StreamsPerS     float64          `json:"streams_per_s"`
	MBPerS          float64          `json:"mb_per_s"`
	RTT             Lat              `json:"rtt"`
	Errors          int64            `json:"errors"`
	Mismatches      int64            `json:"mismatches"`
	ErrorSamples    map[string]int64 `json:"error_samples,omitempty"`
	SessionFailures int64            `json:"session_failures"`
}

func runStreams(cfg config) streamsResult {
	d := newDialer(cfg)
	payload := make([]byte, cfg.size)
	for i := range payload {
		payload[i] = byte(i*7 + i>>8)
	}
	var lat samples
	var errs, sessErrs errSamples
	var done, mismatches, opened atomic.Int64

	sessions := openSessions(cfg, d, &sessErrs)
	opened.Store(int64(len(sessions)))

	start := time.Now()
	deadline := start.Add(cfg.d)
	var wg sync.WaitGroup
	for _, sess := range sessions {
		for range max(1, cfg.p) {
			wg.Go(func() {
				buf := make([]byte, cfg.size+1)
				for time.Now().Before(deadline) {
					if sess.Context().Err() != nil {
						errs.add(errors.New("session closed: " + context.Cause(sess.Context()).Error()))
						return
					}
					t0 := time.Now()
					n, err := roundTrip(sess, payload, buf, cfg.timeout)
					if err != nil {
						errs.add(err)
						continue
					}
					if n != len(payload) || !bytes.Equal(buf[:n], payload) {
						mismatches.Add(1)
						errs.add(fmt.Errorf("echo mismatch: got %d bytes, want %d", n, len(payload)))
						continue
					}
					lat.add(time.Since(t0))
					done.Add(1)
				}
			})
		}
	}
	wg.Wait()
	elapsed := time.Since(start)
	for _, s := range sessions {
		s.CloseWithError(0, "")
	}
	n := done.Load()
	return streamsResult{
		Mode: "streams", URL: cfg.url, Sessions: cfg.s, SessionsOpen: opened.Load(), PerSession: max(1, cfg.p),
		Size: cfg.size, DurationS: round3(elapsed.Seconds()), Streams: n,
		StreamsPerS: round3(float64(n) / elapsed.Seconds()),
		// payload bytes echoed back per second (one direction), in 10^6 bytes
		MBPerS: round3(float64(n) * float64(cfg.size) / elapsed.Seconds() / 1e6),
		RTT:    lat.summary(), Errors: errs.count(), Mismatches: mismatches.Load(),
		ErrorSamples: errs.messages(), SessionFailures: sessErrs.count(),
	}
}

// roundTrip opens a bidirectional stream, writes payload, ends the send
// side and reads the echo up to the server's FIN into buf.
func roundTrip(sess *webtransport.Session, payload, buf []byte, timeout time.Duration) (int, error) {
	ctx, cancel := context.WithTimeout(sess.Context(), timeout)
	defer cancel()
	str, err := sess.OpenStreamSync(ctx)
	if err != nil {
		return 0, fmt.Errorf("open stream: %w", err)
	}
	str.SetDeadline(time.Now().Add(timeout))
	if _, err := str.Write(payload); err != nil {
		str.CancelRead(0)
		return 0, fmt.Errorf("write: %w", err)
	}
	if err := str.Close(); err != nil {
		str.CancelRead(0)
		return 0, fmt.Errorf("close send: %w", err)
	}
	n := 0
	for {
		m, err := str.Read(buf[n:])
		n += m
		if err == io.EOF {
			return n, nil
		}
		if err != nil {
			str.CancelRead(0)
			return n, fmt.Errorf("read: %w", err)
		}
		if n == len(buf) { // more than was sent
			str.CancelRead(0)
			return n, nil
		}
	}
}

func openSessions(cfg config, d *webtransport.Dialer, errs *errSamples) []*webtransport.Session {
	var mu sync.Mutex
	var out []*webtransport.Session
	var wg sync.WaitGroup
	for range max(1, cfg.s) {
		wg.Go(func() {
			ctx, cancel := context.WithTimeout(context.Background(), cfg.timeout)
			defer cancel()
			sess, err := dial(ctx, d, cfg.url)
			if err != nil {
				errs.add(err)
				return
			}
			mu.Lock()
			out = append(out, sess)
			mu.Unlock()
		})
	}
	wg.Wait()
	if len(out) == 0 {
		msgs := errs.messages()
		parts := make([]string, 0, len(msgs))
		for k := range msgs {
			parts = append(parts, k)
		}
		fmt.Fprintf(os.Stderr, "wtload: no session opened: %s\n", strings.Join(parts, "; "))
	}
	return out
}

// ---- datagrams ----

// A datagram starts with the sequence number, the send time (nanoseconds
// since the run started) and the session's index, then padding.
const headerLen = 8 + 8 + 4

type datagramsResult struct {
	Mode            string           `json:"mode"`
	URL             string           `json:"url"`
	Sessions        int              `json:"sessions"`
	SessionsOpen    int64            `json:"sessions_open"`
	Size            int              `json:"size"`
	RatePerSession  int              `json:"rate_per_session"`
	DurationS       float64          `json:"duration_s"`
	Sent            int64            `json:"sent"`
	Received        int64            `json:"received"`
	LossPct         float64          `json:"loss_pct"`
	SendErrors      int64            `json:"send_errors"`
	Corrupt         int64            `json:"corrupt"`
	RTT             Lat              `json:"rtt"`
	ErrorSamples    map[string]int64 `json:"error_samples,omitempty"`
	SessionFailures int64            `json:"session_failures"`
}

func runDatagrams(cfg config) datagramsResult {
	d := newDialer(cfg)
	var lat samples
	var errs, sessErrs errSamples
	var sent, received, corrupt atomic.Int64

	sessions := openSessions(cfg, d, &sessErrs)
	base := time.Now()
	end := base.Add(cfg.d)
	grace := 1 * time.Second // replies that arrive later than this after the last send count as lost

	var wg sync.WaitGroup
	for idx, sess := range sessions {
		// receiver
		wg.Go(func() {
			ctx, cancel := context.WithDeadline(sess.Context(), end.Add(grace))
			defer cancel()
			for {
				b, err := sess.ReceiveDatagram(ctx)
				if err != nil {
					return
				}
				now := time.Since(base)
				if len(b) != cfg.size || binary.BigEndian.Uint32(b[16:20]) != uint32(idx) {
					corrupt.Add(1)
					continue
				}
				ts := time.Duration(binary.BigEndian.Uint64(b[8:16]))
				lat.add(now - ts)
				received.Add(1)
			}
		})
		// sender: paced on a 1 ms grid (or the interval, if longer), sending
		// whatever is due so the average rate holds.
		wg.Go(func() {
			buf := make([]byte, cfg.size)
			for i := headerLen; i < len(buf); i++ {
				buf[i] = byte(i)
			}
			binary.BigEndian.PutUint32(buf[16:20], uint32(idx))
			step := max(time.Millisecond, time.Second/time.Duration(max(1, cfg.rate)))
			tick := time.NewTicker(step)
			defer tick.Stop()
			var seq uint64
			for {
				now := time.Now()
				if !now.Before(end) {
					return
				}
				due := uint64(float64(now.Sub(base)) / float64(time.Second) * float64(cfg.rate))
				for ; seq < due; seq++ {
					binary.BigEndian.PutUint64(buf[0:8], seq)
					binary.BigEndian.PutUint64(buf[8:16], uint64(time.Since(base)))
					if err := sess.SendDatagram(buf); err != nil {
						errs.add(err)
						if sess.Context().Err() != nil {
							return
						}
						continue
					}
					sent.Add(1)
				}
				<-tick.C
			}
		})
	}
	wg.Wait()
	for _, s := range sessions {
		s.CloseWithError(0, "")
	}
	s, r := sent.Load(), received.Load()
	loss := 0.0
	if s > 0 {
		loss = round3(100 * float64(s-r) / float64(s))
	}
	return datagramsResult{
		Mode: "datagrams", URL: cfg.url, Sessions: cfg.s, SessionsOpen: int64(len(sessions)), Size: cfg.size,
		RatePerSession: cfg.rate, DurationS: round3(cfg.d.Seconds()), Sent: s, Received: r, LossPct: loss,
		SendErrors: errs.count(), Corrupt: corrupt.Load(), RTT: lat.summary(), ErrorSamples: errs.messages(),
		SessionFailures: sessErrs.count(),
	}
}

func round3(f float64) float64 { return float64(int64(f*1000+0.5)) / 1000 }

// ---- idle ----

type idleResult struct {
	Mode            string           `json:"mode"`
	URL             string           `json:"url"`
	Sessions        int              `json:"sessions"`
	SessionsOpen    int64            `json:"sessions_open"`
	IdleS           float64          `json:"idle_s"`
	Alive           int64            `json:"alive"`
	Dead            int64            `json:"dead"`
	ErrorSamples    map[string]int64 `json:"error_samples,omitempty"`
	SessionFailures int64            `json:"session_failures"`
}

// runIdle opens S sessions, sends nothing for D (no keep-alives; the
// client's own idle timeout is longer), then does one stream round trip
// on each: a server whose QUIC idle timeout is shorter than D has dropped
// the connection by then.
func runIdle(cfg config) idleResult {
	d := newDialer(cfg)
	var errs, sessErrs errSamples
	var alive atomic.Int64
	sessions := openSessions(cfg, d, &sessErrs)
	time.Sleep(cfg.d)
	payload := []byte("still there?")
	var wg sync.WaitGroup
	for _, sess := range sessions {
		wg.Go(func() {
			buf := make([]byte, len(payload)+1)
			n, err := roundTrip(sess, payload, buf, 5*time.Second)
			if err == nil && bytes.Equal(buf[:n], payload) {
				alive.Add(1)
				return
			}
			if err == nil {
				err = fmt.Errorf("echo mismatch: got %d bytes", n)
			}
			errs.add(err)
		})
	}
	wg.Wait()
	for _, s := range sessions {
		s.CloseWithError(0, "")
	}
	return idleResult{
		Mode: "idle", URL: cfg.url, Sessions: cfg.s, SessionsOpen: int64(len(sessions)), IdleS: round3(cfg.d.Seconds()),
		Alive: alive.Load(), Dead: int64(len(sessions)) - alive.Load(), ErrorSamples: errs.messages(),
		SessionFailures: sessErrs.count(),
	}
}
