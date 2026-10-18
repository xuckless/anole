// Package video plays the 4K test video the way a browser does, many
// viewers at once: progressive MP4 through Range requests, or HLS segment
// by segment. A viewer keeps at most Ahead of video buffered beyond its
// playhead, starts once StartBuffer is buffered, and stalls when the
// playhead catches the buffer.
package video

import (
	"bufio"
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go/http3"
)

// ClipSeconds is the test clip's length (bench/media/gen.sh).
const ClipSeconds = 60

type Options struct {
	Base        string  // https://127.0.0.1:8443 or http://127.0.0.1:8080
	Proto       string  // "h1", "h2" (TLS), "h3"
	Kind        string  // "mp4" or "hls"
	BitrateBps  float64 // 0: the MP4's size over ClipSeconds
	Ahead       time.Duration
	StartBuffer time.Duration
	Chunk       int64 // Range request size for mp4 (browsers ask ~1-4 MB at a time once playing)
}

type Result struct {
	Viewers      int     `json:"viewers"`
	Started      int     `json:"started"`
	Stalled      int     `json:"stalled"`
	StallSeconds float64 `json:"stall_s"`
	PlaySeconds  float64 `json:"play_s"`
	StartupP50MS float64 `json:"startup_p50_ms"`
	StartupMaxMS float64 `json:"startup_max_ms"`
	Errors       int64   `json:"errors"`
	Gbps         float64 `json:"gbps"`
}

// StallRatio is stall time over play time.
func (r Result) StallRatio() float64 {
	if r.PlaySeconds == 0 {
		return 1
	}
	return r.StallSeconds / r.PlaySeconds
}

func client(proto string, i int) *http.Client {
	tlsCfg := &tls.Config{InsecureSkipVerify: true}
	switch proto {
	case "h3":
		return &http.Client{Transport: &http3.Transport{TLSClientConfig: tlsCfg}}
	case "h2":
		tr := &http.Transport{TLSClientConfig: tlsCfg, ForceAttemptHTTP2: true, MaxConnsPerHost: 1}
		return &http.Client{Transport: tr}
	default:
		ip := net.IPv4(127, 0, 0, byte(1+i%8))
		tr := &http.Transport{
			TLSClientConfig: tlsCfg, MaxConnsPerHost: 1, ForceAttemptHTTP2: false,
			TLSNextProto: map[string]func(string, *tls.Conn) http.RoundTripper{},
			DialContext:  (&net.Dialer{LocalAddr: &net.TCPAddr{IP: ip}}).DialContext,
		}
		return &http.Client{Transport: tr}
	}
}

// viewer is one playback. bytesFor(d) is how many bytes d of video is.
type viewer struct {
	o        Options
	c        *http.Client
	got      int64 // bytes downloaded
	start    time.Time
	playing  time.Time
	stall    time.Duration
	stalls   int
	stalling bool
	stallAt  time.Time
}

func (v *viewer) bytesFor(d time.Duration) int64 {
	return int64(v.o.BitrateBps / 8 * d.Seconds())
}

// playhead in bytes, accounting for stalls.
func (v *viewer) playhead(now time.Time) int64 {
	if v.playing.IsZero() {
		return 0
	}
	played := now.Sub(v.playing) - v.stall
	if v.stalling {
		played -= now.Sub(v.stallAt)
	}
	return v.bytesFor(played)
}

// account is called after each read: starts playback, and tracks stalls.
func (v *viewer) account(now time.Time) {
	if v.playing.IsZero() {
		if v.got >= v.bytesFor(v.o.StartBuffer) {
			v.playing = now
		}
		return
	}
	ph := v.playhead(now)
	switch {
	case !v.stalling && ph >= v.got:
		v.stalling, v.stallAt = true, now
		v.stalls++
	case v.stalling && v.got-ph >= v.bytesFor(time.Second):
		v.stall += now.Sub(v.stallAt)
		v.stalling = false
	}
}

// throttle waits while the buffer is full.
func (v *viewer) throttle(ctx context.Context) bool {
	for {
		if v.playing.IsZero() || v.got-v.playhead(time.Now()) < v.bytesFor(v.o.Ahead) {
			return true
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// fetch reads one response body into the buffer accounting.
func (v *viewer) fetch(ctx context.Context, url, rng string, total *atomic.Int64) (int64, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if rng != "" {
		req.Header.Set("Range", rng)
	}
	res, err := v.c.Do(req)
	if err != nil {
		return 0, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 && res.StatusCode != 206 {
		return 0, fmt.Errorf("status %d", res.StatusCode)
	}
	buf := make([]byte, 64<<10)
	var n int64
	for {
		k, err := res.Body.Read(buf)
		if k > 0 {
			n += int64(k)
			v.got += int64(k)
			total.Add(int64(k))
			v.account(time.Now())
		}
		if err == io.EOF {
			return n, nil
		}
		if err != nil {
			return n, err
		}
	}
}

func (v *viewer) runMP4(ctx context.Context, size int64, total *atomic.Int64) error {
	var off int64
	for ctx.Err() == nil {
		if !v.throttle(ctx) {
			return nil
		}
		end := min(off+v.o.Chunk, size) - 1
		n, err := v.fetch(ctx, v.o.Base+"/static/video/4k.mp4", fmt.Sprintf("bytes=%d-%d", off, end), total)
		if err != nil {
			return err
		}
		off += n
		if off >= size {
			off = 0 // loop the clip; the playhead keeps going
		}
	}
	return nil
}

func (v *viewer) runHLS(ctx context.Context, segs []string, total *atomic.Int64) error {
	if _, err := v.fetch(ctx, v.o.Base+"/static/video/hls/init.mp4", "", total); err != nil {
		return err
	}
	for i := 0; ctx.Err() == nil; i = (i + 1) % len(segs) {
		if !v.throttle(ctx) {
			return nil
		}
		if _, err := v.fetch(ctx, v.o.Base+"/static/video/hls/"+segs[i], "", total); err != nil {
			return err
		}
	}
	return nil
}

// Probe reads what the players need: the MP4's size and the HLS segments.
func Probe(o Options) (int64, []string, error) {
	c := client(o.Proto, 0)
	res, err := c.Head(o.Base + "/static/video/4k.mp4")
	if err != nil {
		return 0, nil, err
	}
	res.Body.Close()
	size := res.ContentLength
	res, err = c.Get(o.Base + "/static/video/hls/index.m3u8")
	if err != nil {
		return 0, nil, err
	}
	defer res.Body.Close()
	var segs []string
	sc := bufio.NewScanner(res.Body)
	for sc.Scan() {
		if l := strings.TrimSpace(sc.Text()); l != "" && !strings.HasPrefix(l, "#") {
			segs = append(segs, l)
		}
	}
	if size <= 0 || len(segs) == 0 {
		return 0, nil, fmt.Errorf("probe: size %d, %d segments", size, len(segs))
	}
	return size, segs, nil
}

// Play runs viewers players for d, started evenly over the first ramp.
func Play(o Options, viewers int, ramp, d time.Duration) (Result, error) {
	size, segs, err := Probe(o)
	if err != nil {
		return Result{}, err
	}
	if o.BitrateBps == 0 {
		o.BitrateBps = float64(size) * 8 / ClipSeconds
	}
	ctx, cancel := context.WithTimeout(context.Background(), ramp+d)
	defer cancel()
	var total, errs atomic.Int64
	var mu sync.Mutex
	var all []*viewer
	var wg sync.WaitGroup
	t0 := time.Now()
	for i := 0; i < viewers; i++ {
		v := &viewer{o: o, c: client(o.Proto, i), start: time.Now()}
		mu.Lock()
		all = append(all, v)
		mu.Unlock()
		wg.Add(1)
		go func() {
			defer wg.Done()
			var err error
			if o.Kind == "hls" {
				err = v.runHLS(ctx, segs, &total)
			} else {
				err = v.runMP4(ctx, size, &total)
			}
			if err != nil && ctx.Err() == nil {
				errs.Add(1)
			}
		}()
		time.Sleep(ramp / time.Duration(max(1, viewers)))
	}
	wg.Wait()
	end := time.Now()
	r := Result{Viewers: viewers, Errors: errs.Load(), Gbps: float64(total.Load()) * 8 / end.Sub(t0).Seconds() / 1e9}
	var startups []float64
	for _, v := range all {
		if v.playing.IsZero() {
			continue
		}
		r.Started++
		startups = append(startups, float64(v.playing.Sub(v.start).Milliseconds()))
		st := v.stall
		if v.stalling {
			st += end.Sub(v.stallAt)
		}
		if v.stalls > 0 {
			r.Stalled++
		}
		r.StallSeconds += st.Seconds()
		r.PlaySeconds += end.Sub(v.playing).Seconds()
	}
	// A viewer that never started counts as stalled for its whole time.
	for _, v := range all {
		if v.playing.IsZero() {
			r.Stalled++
			r.StallSeconds += end.Sub(v.start).Seconds()
			r.PlaySeconds += end.Sub(v.start).Seconds()
		}
	}
	if len(startups) > 0 {
		sort.Float64s(startups)
		r.StartupP50MS = startups[len(startups)/2]
		r.StartupMaxMS = startups[len(startups)-1]
	}
	return r, nil
}
