// Package twelve drives the $12 server challenge's traffic: virtual users
// that browse the feed with think time, exactly as bench/twelve/load.js,
// in goroutines instead of k6 VUs (k6 needs megabytes per VU; the search
// reaches tens of thousands of users).
package twelve

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

const (
	likeProb = 0.15
	postProb = 0.02
)

type Token struct {
	Username string `json:"username"`
	Token    string `json:"token"`
}

func LoadTokens(path string) ([]Token, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var t []Token
	return t, json.Unmarshal(b, &t)
}

// Window is what the users saw over one stretch of a run.
type Window struct {
	Start    float64 `json:"start_s"`
	End      float64 `json:"end_s"`
	Users    int     `json:"users"`
	Requests int     `json:"requests"`
	Failed   int     `json:"failed"`
	RPS      float64 `json:"rps"`
	P50MS    float64 `json:"p50_ms"`
	P95MS    float64 `json:"p95_ms"`
	P99MS    float64 `json:"p99_ms"`
	MaxMS    float64 `json:"max_ms"`
}

// Pass is the challenge's threshold: p95 < 500 ms, p99 < 1 s, < 1% failed.
func (w Window) Pass() bool {
	if w.Requests == 0 {
		return false
	}
	return w.P95MS < 500 && w.P99MS < 1000 && float64(w.Failed)/float64(w.Requests) < 0.01
}

type sample struct {
	at     time.Time
	us     uint32
	failed bool
}

// recorder collects every request's latency, in shards so that tens of
// thousands of users do not contend on one lock.
type recorder struct {
	shards [64]struct {
		sync.Mutex
		s []sample
	}
}

func (r *recorder) add(vu int, s sample) {
	sh := &r.shards[vu%len(r.shards)]
	sh.Lock()
	sh.s = append(sh.s, s)
	sh.Unlock()
}

func (r *recorder) window(from, to time.Time) Window {
	var lat []uint32
	failed := 0
	for i := range r.shards {
		sh := &r.shards[i]
		sh.Lock()
		for _, s := range sh.s {
			if !s.at.Before(from) && s.at.Before(to) {
				lat = append(lat, s.us)
				if s.failed {
					failed++
				}
			}
		}
		sh.Unlock()
	}
	w := Window{Requests: len(lat), Failed: failed}
	if d := to.Sub(from).Seconds(); d > 0 {
		w.RPS = float64(len(lat)) / d
	}
	if len(lat) == 0 {
		return w
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	pct := func(p float64) float64 { return float64(lat[int(p*float64(len(lat)-1))]) / 1000 }
	w.P50MS, w.P95MS, w.P99MS, w.MaxMS = pct(0.50), pct(0.95), pct(0.99), float64(lat[len(lat)-1])/1000
	return w
}

// Driver runs users against one base URL.
type Driver struct {
	Base   string
	Tokens []Token
	// SourceIPs spread connections over 127.0.0.x so that more than one
	// port range's worth (~28k) of users can connect.
	SourceIPs int

	rec    recorder
	active atomic.Int64
	t0     time.Time
}

// user is one virtual user: one keep-alive connection, load.js's loop.
func (d *Driver) user(ctx context.Context, vu int) {
	ip := net.IPv4(127, 0, 0, byte(1+vu%max(1, d.SourceIPs)))
	tr := &http.Transport{
		DialContext:         (&net.Dialer{LocalAddr: &net.TCPAddr{IP: ip}, Timeout: 30 * time.Second}).DialContext,
		MaxConnsPerHost:     1,
		MaxIdleConnsPerHost: 1,
		IdleConnTimeout:     0,
		DisableCompression:  true,
		ForceAttemptHTTP2:   false,
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 60 * time.Second}
	tok := d.Tokens[(vu)%len(d.Tokens)]
	auth := "Bearer " + tok.Token
	rng := rand.New(rand.NewPCG(uint64(vu), 42))
	between := func(lo, hi float64) time.Duration {
		return time.Duration((lo + rng.Float64()*(hi-lo)) * float64(time.Second))
	}
	sleep := func(dur time.Duration) bool {
		t := time.NewTimer(dur)
		defer t.Stop()
		select {
		case <-ctx.Done():
			return false
		case <-t.C:
			return true
		}
	}
	do := func(method, path string, body []byte, ok func(int) bool) ([]byte, bool) {
		var rd io.Reader
		if body != nil {
			rd = bytes.NewReader(body)
		}
		req, _ := http.NewRequestWithContext(ctx, method, d.Base+path, rd)
		if method == http.MethodPost {
			req.Header.Set("Authorization", auth)
			req.Header.Set("Content-Type", "application/json")
		}
		start := time.Now()
		res, err := client.Do(req)
		var out []byte
		failed := err != nil
		if err == nil {
			out, err = io.ReadAll(res.Body)
			res.Body.Close()
			failed = err != nil || !ok(res.StatusCode)
		}
		if ctx.Err() != nil {
			return nil, false // cut off by the end of the run: not a sample
		}
		el := time.Since(start)
		d.rec.add(vu, sample{at: start.Add(el), us: uint32(min(el.Microseconds(), 1<<31)), failed: failed})
		return out, !failed
	}
	is := func(codes ...int) func(int) bool {
		return func(c int) bool {
			for _, x := range codes {
				if c == x {
					return true
				}
			}
			return false
		}
	}

	d.active.Add(1)
	defer d.active.Add(-1)
	if !sleep(between(0, 5)) { // spread out users that start together
		return
	}
	for iter := 0; ctx.Err() == nil; iter++ {
		body, ok := do(http.MethodGet, "/feed", nil, is(200))
		if !ok {
			if !sleep(between(3, 7)) {
				return
			}
			continue
		}
		var feed struct {
			Posts []struct {
				ID int64 `json:"id"`
			} `json:"posts"`
		}
		json.Unmarshal(body, &feed)
		if len(feed.Posts) == 0 {
			if !sleep(between(3, 7)) {
				return
			}
			continue
		}
		post := feed.Posts[rng.IntN(len(feed.Posts))].ID
		if !sleep(between(3, 7)) {
			return
		}
		do(http.MethodGet, fmt.Sprintf("/posts/%d", post), nil, is(200))
		if !sleep(between(3, 8)) {
			return
		}
		if rng.Float64() < likeProb {
			do(http.MethodPost, fmt.Sprintf("/posts/%d/like", post), nil, is(200, 201))
		}
		if rng.Float64() < postProb {
			b, _ := json.Marshal(map[string]string{"body": fmt.Sprintf("%s says hi at %s (VU %d, iter %d)",
				tok.Username, time.Now().UTC().Format("2006-01-02T15:04:05.000Z"), vu+1, iter)})
			do(http.MethodPost, "/posts", b, is(201))
		}
		if !sleep(between(5, 15)) {
			return
		}
	}
}

// Step is one stage of a run: ramp linearly to Users over Ramp, then hold.
type Step struct {
	Users int
	Ramp  time.Duration
	Hold  time.Duration
}

// Run runs the steps back to back, users added (never removed) as each
// step ramps up, and returns one window per step's hold. stop is checked
// after each step: returning true ends the run early.
func (d *Driver) Run(steps []Step, stop func(Window) bool) []Window {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d.t0 = time.Now()
	var wg sync.WaitGroup
	started := 0
	var windows []Window
	for _, st := range steps {
		add := st.Users - started
		if add > 0 {
			gap := st.Ramp / time.Duration(add)
			for i := 0; i < add; i++ {
				wg.Add(1)
				go func(vu int) {
					defer wg.Done()
					d.user(ctx, vu)
				}(started + i)
				time.Sleep(gap)
			}
			started = st.Users
		}
		from := time.Now()
		time.Sleep(st.Hold)
		w := d.rec.window(from, time.Now())
		w.Start, w.End = from.Sub(d.t0).Seconds(), time.Since(d.t0).Seconds()
		w.Users = int(d.active.Load())
		windows = append(windows, w)
		if stop != nil && stop(w) {
			break
		}
	}
	cancel()
	wg.Wait()
	return windows
}
