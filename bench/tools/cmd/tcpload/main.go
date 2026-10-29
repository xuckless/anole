// tcpload drives a raw TCP echo server: -conns connections, each with one
// -size message outstanding (write it, read the same number of bytes back),
// and counts the round trips after -warmup.
//
//	tcpload -addr 127.0.0.1:7000 -conns 256 -size 64 -warmup 3s -d 15s
//
// Prints the result as JSON: messages/s and the round-trip percentiles.
package main

import (
	"encoding/json"
	"flag"
	"github.com/xuckless/anole/bench/tools/internal/hist"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:7000", "server")
	conns := flag.Int("conns", 256, "connections")
	size := flag.Int("size", 64, "message bytes")
	ips := flag.String("ips", "", "comma-separated local source addresses, round robin")
	warmup := flag.Duration("warmup", 3*time.Second, "not counted")
	d := flag.Duration("d", 15*time.Second, "counted time")
	flag.Parse()
	var src []*net.TCPAddr
	for _, ip := range strings.Split(*ips, ",") {
		if ip != "" {
			src = append(src, &net.TCPAddr{IP: net.ParseIP(ip)})
		}
	}
	cs := make([]net.Conn, *conns)
	for i := range cs {
		dl := net.Dialer{Timeout: 5 * time.Second}
		if len(src) > 0 {
			dl.LocalAddr = src[i%len(src)]
		}
		c, err := dl.Dial("tcp", *addr)
		if err != nil {
			panic(err)
		}
		cs[i] = c
	}
	var counting, stop atomic.Bool
	var errs atomic.Int64
	hs := make([]hist.Hist, *conns)
	var wg sync.WaitGroup
	for i, c := range cs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			out := make([]byte, *size)
			in := make([]byte, *size)
			for j := range out {
				out[j] = byte(i + j)
			}
			for !stop.Load() {
				t := time.Now()
				_, err := c.Write(out)
				if err == nil {
					_, err = io.ReadFull(c, in)
				}
				if err != nil {
					if !stop.Load() {
						errs.Add(1)
					}
					return
				}
				if counting.Load() {
					hs[i].Add(int64(time.Since(t)))
				}
			}
		}()
	}
	time.Sleep(*warmup)
	counting.Store(true)
	t0 := time.Now()
	time.Sleep(*d)
	counting.Store(false)
	el := time.Since(t0).Seconds()
	stop.Store(true)
	for _, c := range cs {
		c.SetDeadline(time.Now())
	}
	wg.Wait()
	var all hist.Hist
	for i := range hs {
		all.Merge(&hs[i])
	}
	var n uint64
	for _, c := range all {
		n += c
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{
		"conns": *conns, "size": *size, "messages": n, "msgs_per_s": float64(n) / el,
		"p50_ms": all.Pct(0.50), "p99_ms": all.Pct(0.99), "p999_ms": all.Pct(0.999),
		"errors": errs.Load(),
	})
}
