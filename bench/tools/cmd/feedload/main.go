// feedload runs one feed/trading case of the suite's ws scenario on its own
// (for profiling): subscribers on /ws/feed, traders on /ws/trade.
//
//	feedload -url ws://127.0.0.1:8080 -subs 2000 -traders 200 -tick-hz 500 -order-hz 10 -d 30s
//
// The server ticks at the TICK_HZ it was started with; -tick-hz only sets
// the expected rate. Prints the result as JSON.
package main

import (
	"encoding/json"
	"flag"
	"os"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/ws"
)

func main() {
	url := flag.String("url", "ws://127.0.0.1:8080", "server base URL")
	subs := flag.Int("subs", 2000, "feed subscribers")
	traders := flag.Int("traders", 200, "traders (one order socket each)")
	tickHz := flag.Int("tick-hz", 500, "the server's tick rate")
	orderHz := flag.Int("order-hz", 10, "orders a second per trader")
	d := flag.Duration("d", 30*time.Second, "measured time")
	flag.Parse()
	r := ws.Feed(*url+"/ws/feed", *url+"/ws/trade", *subs, *traders, *tickHz, *orderHz, *d)
	json.NewEncoder(os.Stdout).Encode(r)
}
