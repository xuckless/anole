// parkwake: idle keep-alive connections woken while the server is busy.
//
//	parkwake -addr 127.0.0.1:8080 -idle 2000 -hold 15s -path /json
//
// Opens -idle HTTP/1.1 keep-alive connections and proves each with one
// request, prints "parked", lets them sit -hold (start the busy load in that
// time), then sends one request on every one of them at once and reports
// the wake latency: how long each waited for its answer, with -timeout as
// the limit. The output is one JSON line.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8080", "server host:port")
	idle := flag.Int("idle", 2000, "idle connections")
	hold := flag.Duration("hold", 15*time.Second, "time parked before the wake")
	path := flag.String("path", "/json", "request path")
	timeout := flag.Duration("timeout", 10*time.Second, "per-request limit on the wake")
	flag.Parse()

	req := []byte("GET " + *path + " HTTP/1.1\r\nHost: " + *addr + "\r\n\r\n")
	type kc struct {
		c net.Conn
		r *bufio.Reader
	}
	roundTrip := func(k kc) error {
		if _, err := k.c.Write(req); err != nil {
			return err
		}
		rsp, err := http.ReadResponse(k.r, nil)
		if err != nil {
			return err
		}
		_, err = io.Copy(io.Discard, rsp.Body)
		rsp.Body.Close()
		if err == nil && rsp.StatusCode != 200 {
			err = fmt.Errorf("status %d", rsp.StatusCode)
		}
		return err
	}
	conns := make([]kc, 0, *idle)
	openFailed := 0
	for i := 0; i < *idle; i++ {
		c, err := net.DialTimeout("tcp", *addr, 10*time.Second)
		if err != nil {
			openFailed++
			continue
		}
		k := kc{c, bufio.NewReader(c)}
		c.SetDeadline(time.Now().Add(10 * time.Second))
		if roundTrip(k) != nil {
			openFailed++
			c.Close()
			continue
		}
		c.SetDeadline(time.Time{})
		conns = append(conns, k)
	}
	fmt.Fprintf(os.Stderr, "parked %d (failed %d)\n", len(conns), openFailed)
	time.Sleep(*hold)

	lat := make([]float64, len(conns))
	var mu sync.Mutex
	timeouts, errs := 0, 0
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i, k := range conns {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			t := time.Now()
			k.c.SetDeadline(t.Add(*timeout))
			err := roundTrip(k)
			d := time.Since(t)
			lat[i] = float64(d.Microseconds()) / 1000
			if err != nil {
				mu.Lock()
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					timeouts++
				} else {
					errs++
				}
				mu.Unlock()
				lat[i] = -1
			}
		}()
	}
	t0 := time.Now()
	close(start)
	wg.Wait()
	all := time.Since(t0)
	ok := lat[:0:0]
	for _, v := range lat {
		if v >= 0 {
			ok = append(ok, v)
		}
	}
	sort.Float64s(ok)
	pct := func(p float64) float64 {
		if len(ok) == 0 {
			return 0
		}
		return ok[min(len(ok)-1, int(p*float64(len(ok))))]
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{
		"parked": len(conns), "open_failed": openFailed, "answered": len(ok), "timeouts": timeouts, "errors": errs,
		"p50_ms": pct(0.50), "p99_ms": pct(0.99), "max_ms": pct(1), "all_answered_ms": float64(all.Microseconds()) / 1000,
	})
	for _, k := range conns {
		k.c.Close()
	}
}
