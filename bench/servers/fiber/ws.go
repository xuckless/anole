package main

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/gofiber/contrib/v3/websocket"
	"github.com/gofiber/fiber/v3"
)

const wsReadLimit = 8 << 20

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

func registerWebSockets(app *fiber.App, tickHz int) {
	feed := &Feed{subs: map[chan []byte]struct{}{}}
	go feed.run(tickHz)
	positions := &Positions{net: map[string]int64{}}

	app.Get("/ws/echo", websocket.New(func(c *websocket.Conn) {
		c.SetReadLimit(wsReadLimit)
		for {
			mt, msg, err := c.ReadMessage()
			if err != nil {
				return
			}
			if err := c.WriteMessage(mt, msg); err != nil {
				return
			}
		}
	}))

	app.Get("/ws/feed", websocket.New(func(c *websocket.Conn) {
		ch := feed.subscribe()
		defer feed.unsubscribe(ch)
		closed := make(chan struct{})
		go func() { // client messages are ignored; reading notices the close
			defer close(closed)
			for {
				if _, _, err := c.ReadMessage(); err != nil {
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
				if err := c.WriteMessage(websocket.TextMessage, msg); err != nil {
					return
				}
			case <-closed:
				return
			}
		}
	}))

	app.Get("/ws/trade", websocket.New(func(c *websocket.Conn) {
		c.SetReadLimit(wsReadLimit)
		for {
			_, msg, err := c.ReadMessage()
			if err != nil {
				return
			}
			var o Order
			if err := json.Unmarshal(msg, &o); err != nil {
				return
			}
			pos := positions.apply(&o)
			out, _ := json.Marshal(Fill{ID: o.ID, Status: "filled", Px: o.Px, Qty: o.Qty, Pos: pos, T: o.T})
			if err := c.WriteMessage(websocket.TextMessage, out); err != nil {
				return
			}
		}
	}))
}
