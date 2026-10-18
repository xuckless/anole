// Package ws drives the WebSocket scenarios: idle sockets, echo, the tick
// fan-out on /ws/feed and the trading simulation on /ws/trade.
package ws

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// Lat is a latency summary in milliseconds.
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

func (s *samples) add(us int64) {
	s.mu.Lock()
	s.us = append(s.us, us)
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

// dialer spreads sockets over source addresses 127.0.0.1-127.0.0.N, so
// more than one ephemeral port range of them can be open.
func dial(ctx context.Context, url string, i, sourceIPs int) (*websocket.Conn, error) {
	ip := net.IPv4(127, 0, 0, byte(1+i%max(1, sourceIPs)))
	tr := &http.Transport{
		DialContext:     (&net.Dialer{LocalAddr: &net.TCPAddr{IP: ip}, Timeout: 30 * time.Second}).DialContext,
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	c, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPClient: &http.Client{Transport: tr}})
	if err == nil {
		c.SetReadLimit(16 << 20)
	}
	return c, err
}

// OpenIdle opens n sockets to url (rate per second at most) and returns
// them, still open. Failures are counted, not fatal.
func OpenIdle(ctx context.Context, url string, n, rate, sourceIPs int) ([]*websocket.Conn, int) {
	conns := make([]*websocket.Conn, n)
	var failed atomic.Int64
	var wg sync.WaitGroup
	sem := make(chan struct{}, 256)
	gap := time.Second / time.Duration(max(1, rate))
	for i := 0; i < n; i++ {
		sem <- struct{}{}
		wg.Add(1)
		go func(i int) {
			defer func() { <-sem; wg.Done() }()
			c, err := dial(ctx, url, i, sourceIPs)
			if err != nil {
				failed.Add(1)
				return
			}
			conns[i] = c
			// Drain anything the server sends (pings) so the socket stays healthy.
			go func() {
				for {
					if _, _, err := c.Read(ctx); err != nil {
						return
					}
				}
			}()
		}(i)
		time.Sleep(gap)
	}
	wg.Wait()
	var open []*websocket.Conn
	for _, c := range conns {
		if c != nil {
			open = append(open, c)
		}
	}
	return open, int(failed.Load())
}

func CloseAll(conns []*websocket.Conn) {
	for _, c := range conns {
		c.CloseNow()
	}
}

// EchoResult is closed-loop echo traffic over many sockets.
type EchoResult struct {
	Conns  int     `json:"conns"`
	Msgs   int64   `json:"msgs"`
	MsgsPS float64 `json:"msgs_per_s"`
	Errors int64   `json:"errors"`
	RTT    Lat     `json:"rtt"`
}

// Echo: conns sockets, each sending size-byte messages and waiting for the
// echo before the next, for d.
func Echo(url string, conns, size int, d time.Duration) EchoResult {
	ctx, cancel := context.WithTimeout(context.Background(), d+30*time.Second)
	defer cancel()
	var msgs, errs atomic.Int64
	var lat samples
	payload := make([]byte, size)
	for i := range payload {
		payload[i] = 'a' + byte(i%26)
	}
	var wg sync.WaitGroup
	start := time.Now()
	end := start.Add(d)
	for i := 0; i < conns; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			c, err := dial(ctx, url, i, 4)
			if err != nil {
				errs.Add(1)
				return
			}
			defer c.CloseNow()
			for time.Now().Before(end) {
				t0 := time.Now()
				if err := c.Write(ctx, websocket.MessageText, payload); err != nil {
					errs.Add(1)
					return
				}
				if _, _, err := c.Read(ctx); err != nil {
					errs.Add(1)
					return
				}
				msgs.Add(1)
				if msgs.Load()%16 == 0 { // a sample of the round trips
					lat.add(time.Since(t0).Microseconds())
				}
			}
		}(i)
	}
	wg.Wait()
	el := time.Since(start).Seconds()
	return EchoResult{Conns: conns, Msgs: msgs.Load(), MsgsPS: float64(msgs.Load()) / el, Errors: errs.Load(), RTT: lat.summary()}
}

type tick struct {
	Seq int64 `json:"seq"`
	TS  int64 `json:"ts"`
}

// FeedResult is the tick fan-out as the subscribers saw it.
type FeedResult struct {
	Subscribers int     `json:"subscribers"`
	Connected   int     `json:"connected"`
	TickHz      int     `json:"tick_hz"`
	Expected    float64 `json:"expected_per_s"`
	Delivered   float64 `json:"delivered_per_s"`
	Gaps        int64   `json:"gaps"`
	Lag         Lat     `json:"lag"`
	Orders      int64   `json:"orders,omitempty"`
	OrdersPS    float64 `json:"orders_per_s,omitempty"`
	OrderErrors int64   `json:"order_errors,omitempty"`
	OrderRTT    Lat     `json:"order_rtt,omitempty"`
}

// Feed: subs sockets on feedURL for d; traders of them also hold a socket
// on tradeURL and send orderHz orders a second each, waiting for each ack.
// Lag is receive time minus the server's send stamp (same host clock).
func Feed(feedURL, tradeURL string, subs, traders, tickHz, orderHz int, d time.Duration) FeedResult {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	res := FeedResult{Subscribers: subs, TickHz: tickHz, Expected: float64(subs * tickHz)}
	var lag, rtt samples
	var received, gaps, orders, orderErrs atomic.Int64
	var connected atomic.Int64
	var measuring atomic.Bool
	var wg sync.WaitGroup
	ready := make(chan struct{})

	for i := 0; i < subs; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			c, err := dial(ctx, feedURL, i, 8)
			if err != nil {
				return
			}
			defer c.CloseNow()
			connected.Add(1)
			var last int64
			n := 0
			for {
				_, b, err := c.Read(ctx)
				if err != nil {
					return
				}
				if !measuring.Load() {
					continue
				}
				var t tick
				if json.Unmarshal(b, &t) != nil {
					continue
				}
				now := time.Now().UnixMicro()
				received.Add(1)
				if last != 0 && t.Seq != last+1 {
					gaps.Add(1)
				}
				last = t.Seq
				// Every subscriber's lag is sampled, one tick in eight.
				if n++; n%8 == 0 {
					lag.add(now - t.TS)
				}
			}
		}(i)
	}
	for i := 0; i < traders; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			c, err := dial(ctx, tradeURL, i, 8)
			if err != nil {
				orderErrs.Add(1)
				return
			}
			defer c.CloseNow()
			<-ready
			tk := time.NewTicker(time.Second / time.Duration(orderHz))
			defer tk.Stop()
			side := [2]string{"buy", "sell"}
			for id := 1; ; id++ {
				select {
				case <-ctx.Done():
					return
				case <-tk.C:
				}
				t0 := time.Now()
				msg := `{"id":` + strconv.Itoa(id) + `,"sym":"BTCUSD","side":"` + side[id%2] + `","px":100100,"qty":` + strconv.Itoa(1+id%5) + `,"t":` + strconv.FormatInt(t0.UnixMicro(), 10) + `}`
				if err := c.Write(ctx, websocket.MessageText, []byte(msg)); err != nil {
					if ctx.Err() == nil {
						orderErrs.Add(1)
					}
					return
				}
				if _, _, err := c.Read(ctx); err != nil {
					if ctx.Err() == nil {
						orderErrs.Add(1)
					}
					return
				}
				if measuring.Load() {
					orders.Add(1)
					rtt.add(time.Since(t0).Microseconds())
				}
			}
		}(i)
	}
	// Let every socket connect, settle for two seconds, then measure.
	deadline := time.Now().Add(60 * time.Second)
	for connected.Load() < int64(subs) && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	close(ready)
	time.Sleep(2 * time.Second)
	measuring.Store(true)
	t0 := time.Now()
	time.Sleep(d)
	measuring.Store(false)
	el := time.Since(t0).Seconds()
	cancel()
	wg.Wait()
	res.Connected = int(connected.Load())
	res.Delivered = float64(received.Load()) / el
	res.Gaps = gaps.Load()
	res.Lag = lag.summary()
	if traders > 0 {
		res.Orders = orders.Load()
		res.OrdersPS = float64(orders.Load()) / el
		res.OrderErrors = orderErrs.Load()
		res.OrderRTT = rtt.summary()
	}
	return res
}

func (r FeedResult) String() string {
	return fmt.Sprintf("%d/%d subs, %.0f of %.0f msgs/s, lag p99 %.2f ms, orders %.0f/s rtt p99 %.2f ms",
		r.Connected, r.Subscribers, r.Delivered, r.Expected, r.Lag.P99MS, r.OrdersPS, r.OrderRTT.P99MS)
}
