// wsecho runs the ws scenario's echo case on its own (for A/B runs):
// -c sockets on /ws/echo, each sending a -size message and waiting for it
// back, for -d.
//
//	wsecho -url ws://127.0.0.1:8080/ws/echo -c 64 -d 30s
//
// Prints the result as JSON.
package main

import (
	"encoding/json"
	"flag"
	"os"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/ws"
)

func main() {
	url := flag.String("url", "ws://127.0.0.1:8080/ws/echo", "echo endpoint")
	conns := flag.Int("c", 64, "sockets")
	size := flag.Int("size", 64, "message size in bytes")
	d := flag.Duration("d", 30*time.Second, "measured time")
	flag.Parse()
	json.NewEncoder(os.Stdout).Encode(ws.Echo(*url, *conns, *size, *d))
}
