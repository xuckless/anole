// sseload opens -n server-sent-event subscribers, holds them idle, then
// publishes timestamped events and measures how long each takes to reach
// every subscriber.
//
//	sseload -sub http://127.0.0.1:8080/sse -pub http://127.0.0.1:8080/publish \
//	        -n 50000 -ips 127.0.0.2,127.0.0.3,127.0.0.4 -idle 60s -events 20 -every 2s
//
// Subscribers dial from -ips in turn (each source address has its own
// ephemeral ports), -rate a second. Once all are connected it prints
// "connected" on stderr, waits -idle (the orchestrator samples the server's
// memory and CPU then), and prints "publishing" before the first event.
// Each event's data is the publish time in Unix nanoseconds; a subscriber
// records the arrival delay. Prints the result as JSON.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type eventStat struct {
	Reached  int     `json:"reached"`
	Received int     `json:"received"`
	P50      float64 `json:"p50_ms"`
	P99      float64 `json:"p99_ms"`
	Max      float64 `json:"all_ms"`
}

type result struct {
	Wanted        int         `json:"subscribers"`
	Connected     int64       `json:"connected"`
	ConnectErrors int64       `json:"connect_errors"`
	FirstError    string      `json:"first_error,omitempty"`
	ConnectSecs   float64     `json:"connect_s"`
	Dropped       int64       `json:"streams_ended"`
	Events        []eventStat `json:"events"`
	P50           float64     `json:"p50_ms"`
	P99           float64     `json:"p99_ms"`
	AllMedian     float64     `json:"all_ms_median"`
	AllMax        float64     `json:"all_ms_max"`
}

func main() {
	sub := flag.String("sub", "http://127.0.0.1:8080/sse", "subscribe URL")
	pub := flag.String("pub", "http://127.0.0.1:8080/publish", "publish URL (POST, body = event data)")
	n := flag.Int("n", 50000, "subscribers")
	ips := flag.String("ips", "127.0.0.2,127.0.0.3,127.0.0.4,127.0.0.5", "source addresses, comma-separated")
	rate := flag.Int("rate", 5000, "subscribers opened a second")
	idle := flag.Duration("idle", 60*time.Second, "idle time once all are connected")
	events := flag.Int("events", 20, "events published")
	every := flag.Duration("every", 2*time.Second, "time between events")
	settle := flag.Duration("settle", 2*time.Second, "time after an event before its delays are read")
	flag.Parse()

	u := strings.TrimPrefix(*sub, "http://")
	host, path, _ := strings.Cut(u, "/")
	path = "/" + path
	srcs := strings.Split(*ips, ",")

	// lat[e] collects event e's delays in ms.
	lat := make([][]float64, *events)
	var latMu = make([]sync.Mutex, *events)
	var connected, connErrs, ended atomic.Int64
	var firstErr atomic.Value
	start := time.Now()
	tick := time.NewTicker(time.Second / time.Duration(*rate))
	var ready sync.WaitGroup
	for i := 0; i < *n; i++ {
		<-tick.C
		ready.Add(1)
		go func(i int) {
			d := net.Dialer{Timeout: 10 * time.Second, LocalAddr: &net.TCPAddr{IP: net.ParseIP(srcs[i%len(srcs)])}}
			c, err := d.Dial("tcp", host)
			if err != nil {
				connErrs.Add(1)
				firstErr.CompareAndSwap(nil, err.Error())
				ready.Done()
				return
			}
			defer c.Close()
			fmt.Fprintf(c, "GET %s HTTP/1.1\r\nHost: %s\r\nAccept: text/event-stream\r\n\r\n", path, host)
			r := bufio.NewReaderSize(c, 512)
			// The response head.
			status, err := r.ReadString('\n')
			if err != nil || !strings.Contains(status, " 200") {
				connErrs.Add(1)
				firstErr.CompareAndSwap(nil, fmt.Sprintf("status %q %v", strings.TrimSpace(status), err))
				ready.Done()
				return
			}
			for {
				l, err := r.ReadString('\n')
				if err != nil || l == "\r\n" {
					break
				}
			}
			connected.Add(1)
			ready.Done()
			// Chunked or not, the event lines come through: take "data:" lines.
			for {
				l, err := r.ReadString('\n')
				if err != nil {
					ended.Add(1)
					return
				}
				rest, ok := strings.CutPrefix(l, "data:")
				if !ok {
					continue
				}
				now := time.Now().UnixNano()
				f := strings.Fields(strings.TrimSpace(rest))
				if len(f) != 2 {
					continue
				}
				e, _ := strconv.Atoi(f[0])
				ts, _ := strconv.ParseInt(f[1], 10, 64)
				if e < 0 || e >= len(lat) {
					continue
				}
				latMu[e].Lock()
				lat[e] = append(lat[e], float64(now-ts)/1e6)
				latMu[e].Unlock()
			}
		}(i)
	}
	tick.Stop()
	ready.Wait()
	connSecs := time.Since(start).Seconds()
	fmt.Fprintf(os.Stderr, "connected %d (errors %d) in %.1f s\n", connected.Load(), connErrs.Load(), connSecs)
	time.Sleep(*idle)
	fmt.Fprintln(os.Stderr, "publishing")

	res := result{Wanted: *n, Connected: connected.Load(), ConnectErrors: connErrs.Load(), ConnectSecs: connSecs}
	if e, _ := firstErr.Load().(string); e != "" {
		res.FirstError = e
	}
	var all, alls []float64
	client := &http.Client{Timeout: 30 * time.Second}
	for e := 0; e < *events; e++ {
		body := fmt.Sprintf("%d %d", e, time.Now().UnixNano())
		rsp, err := client.Post(*pub, "text/plain", bytes.NewBufferString(body))
		reached := -1
		if err == nil {
			b, _ := io.ReadAll(rsp.Body)
			rsp.Body.Close()
			reached, _ = strconv.Atoi(strings.TrimSpace(string(b)))
		}
		time.Sleep(*settle)
		latMu[e].Lock()
		xs := append([]float64(nil), lat[e]...)
		latMu[e].Unlock()
		sort.Float64s(xs)
		st := eventStat{Reached: reached, Received: len(xs)}
		if len(xs) > 0 {
			st.P50, st.P99, st.Max = xs[len(xs)/2], xs[min(len(xs)-1, len(xs)*99/100)], xs[len(xs)-1]
			alls = append(alls, st.Max)
		}
		res.Events = append(res.Events, st)
		all = append(all, xs...)
		if wait := *every - *settle; wait > 0 {
			time.Sleep(wait)
		}
	}
	sort.Float64s(all)
	sort.Float64s(alls)
	if len(all) > 0 {
		res.P50, res.P99 = all[len(all)/2], all[min(len(all)-1, len(all)*99/100)]
	}
	if len(alls) > 0 {
		res.AllMedian, res.AllMax = alls[len(alls)/2], alls[len(alls)-1]
	}
	res.Dropped = ended.Load()
	json.NewEncoder(os.Stdout).Encode(res)
}
