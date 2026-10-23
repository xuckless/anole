// udpload sends datagrams to a UDP echo server from -sockets sockets (each
// its own source port, so a SO_REUSEPORT group spreads them) and counts the
// echoes.
//
//	udpload -addr 127.0.0.1:7001 -sockets 64 -size 64 -window 32 -d 10s
//
// Each socket keeps up to -window datagrams unanswered (0: sends without
// waiting, as fast as it can, for an overload). Prints the result as JSON.
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:7001", "server")
	sockets := flag.Int("sockets", 64, "client sockets")
	size := flag.Int("size", 64, "datagram bytes (at least 8)")
	window := flag.Int("window", 32, "unanswered datagrams per socket; 0: unpaced flood")
	d := flag.Duration("d", 10*time.Second, "time")
	flag.Parse()
	ra, err := net.ResolveUDPAddr("udp", *addr)
	if err != nil {
		panic(err)
	}
	var sent, recv atomic.Int64
	var stop atomic.Bool
	var wg sync.WaitGroup
	for i := 0; i < *sockets; i++ {
		c, err := net.DialUDP("udp", nil, ra)
		if err != nil {
			panic(err)
		}
		c.SetReadBuffer(4 << 20)
		credit := make(chan struct{}, max(1, *window))
		for j := 0; j < cap(credit); j++ {
			credit <- struct{}{}
		}
		wg.Add(2)
		go func() { // receiver
			defer wg.Done()
			b := make([]byte, 65536)
			for !stop.Load() {
				c.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
				if _, err := c.Read(b); err != nil {
					// A lost datagram: give its credit back after a timeout.
					if *window > 0 {
						select {
						case credit <- struct{}{}:
						default:
						}
					}
					continue
				}
				recv.Add(1)
				if *window > 0 {
					select {
					case credit <- struct{}{}:
					default:
					}
				}
			}
		}()
		go func() { // sender
			defer wg.Done()
			b := make([]byte, max(8, *size))
			var seq uint64
			for !stop.Load() {
				if *window > 0 {
					select {
					case <-credit:
					case <-time.After(100 * time.Millisecond):
						continue
					}
				}
				seq++
				binary.LittleEndian.PutUint64(b, seq)
				if _, err := c.Write(b); err == nil {
					sent.Add(1)
				}
			}
		}()
	}
	t0 := time.Now()
	time.Sleep(*d)
	stop.Store(true)
	el := time.Since(t0).Seconds()
	wg.Wait()
	json.NewEncoder(os.Stdout).Encode(map[string]any{
		"sockets": *sockets, "size": *size, "window": *window,
		"sent": sent.Load(), "received": recv.Load(),
		"sent_per_s": float64(sent.Load()) / el, "received_per_s": float64(recv.Load()) / el,
		"lost": sent.Load() - recv.Load(),
	})
}
