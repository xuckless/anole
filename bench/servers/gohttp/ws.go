package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const wsReadLimit = 8 << 20

// Like gorilla and fasthttp/websocket, accept any Origin.
var acceptOptions = &websocket.AcceptOptions{OriginPatterns: []string{"*"}}

type Tick struct {
	Seq int64  `json:"seq"`
	TS  int64  `json:"ts"`
	Sym string `json:"sym"`
	Px  int64  `json:"px"`
	Qty int64  `json:"qty"`
}

type Order struct {
	ID   int64  `json:"id"`
	Sym  string `json:"sym"`
	Side string `json:"side"`
	Px   int64  `json:"px"`
	Qty  int64  `json:"qty"`
	T    int64  `json:"t"`
}

type Fill struct {
	ID     int64  `json:"id"`
	Status string `json:"status"`
	Px     int64  `json:"px"`
	Qty    int64  `json:"qty"`
	Pos    int64  `json:"pos"`
	T      int64  `json:"t"`
}

// Feed is the one tick stream per process. Each subscriber gets a buffered
// channel; one that falls a full second behind is dropped.
type Feed struct {
	mu   sync.Mutex
	subs map[chan []byte]struct{}
}

func (f *Feed) subscribe() chan []byte {
	ch := make(chan []byte, 1024)
	f.mu.Lock()
	f.subs[ch] = struct{}{}
	f.mu.Unlock()
	return ch
}

func (f *Feed) unsubscribe(ch chan []byte) {
	f.mu.Lock()
	if _, ok := f.subs[ch]; ok {
		delete(f.subs, ch)
		close(ch)
	}
	f.mu.Unlock()
}

// run wakes every 10 ms and sends hz/100 ticks, each with a fresh timestamp.
func (f *Feed) run(hz int) {
	perWake := hz / 100
	var seq int64
	for range time.Tick(10 * time.Millisecond) {
		for range perWake {
			seq++
			f.mu.Lock()
			if len(f.subs) > 0 {
				msg, _ := json.Marshal(Tick{Seq: seq, TS: time.Now().UnixMicro(), Sym: "BTCUSD", Px: 100000 + seq%1000, Qty: 1 + seq%10})
				for ch := range f.subs {
					select {
					case ch <- msg:
					default: // slow consumer
						delete(f.subs, ch)
						close(ch)
					}
				}
			}
			f.mu.Unlock()
		}
	}
}

// Positions is the shared per-symbol net quantity for /ws/trade.
type Positions struct {
	mu  sync.Mutex
	net map[string]int64
}

func (p *Positions) apply(o *Order) int64 {
	qty := o.Qty
	if o.Side == "sell" {
		qty = -qty
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.net[o.Sym] += qty
	return p.net[o.Sym]
}

func registerWebSockets(mux *http.ServeMux, tickHz int) {
	feed := &Feed{subs: map[chan []byte]struct{}{}}
	go feed.run(tickHz)
	positions := &Positions{net: map[string]int64{}}

	mux.HandleFunc("GET /ws/echo", func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, acceptOptions)
		if err != nil {
			return
		}
		defer c.CloseNow()
		c.SetReadLimit(wsReadLimit)
		ctx := r.Context()
		for {
			typ, msg, err := c.Read(ctx)
			if err != nil {
				return
			}
			if err := c.Write(ctx, typ, msg); err != nil {
				return
			}
		}
	})

	mux.HandleFunc("GET /ws/feed", func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, acceptOptions)
		if err != nil {
			return
		}
		defer c.CloseNow()
		ch := feed.subscribe()
		defer feed.unsubscribe(ch)
		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		go func() { // client messages are ignored; reading notices the close
			defer cancel()
			for {
				if _, _, err := c.Read(ctx); err != nil {
					return
				}
			}
		}()
		for {
			select {
			case msg, ok := <-ch:
				if !ok {
					return
				}
				if err := c.Write(ctx, websocket.MessageText, msg); err != nil {
					return
				}
			case <-ctx.Done():
				return
			}
		}
	})

	mux.HandleFunc("GET /ws/trade", func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, acceptOptions)
		if err != nil {
			return
		}
		defer c.CloseNow()
		c.SetReadLimit(wsReadLimit)
		ctx := r.Context()
		for {
			_, msg, err := c.Read(ctx)
			if err != nil {
				return
			}
			var o Order
			if err := json.Unmarshal(msg, &o); err != nil {
				return
			}
			pos := positions.apply(&o)
			out, _ := json.Marshal(Fill{ID: o.ID, Status: "filled", Px: o.Px, Qty: o.Qty, Pos: pos, T: o.T})
			if err := c.Write(ctx, websocket.MessageText, out); err != nil {
				return
			}
		}
	})
}
