package main

import (
	"crypto/sha256"
	"crypto/tls"
	"io"
	"math/rand"
	"net"
	"testing"
)

// A trivial upstream that reads what the client sends and answers with its
// own fixed bytes: both directions must arrive unchanged through the proxy,
// and the report must hold the counted frames.
func TestProxyVerbatim(t *testing.T) {
	up, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer up.Close()
	rng := rand.New(rand.NewSource(1))
	clientBytes := append([]byte(preface), frame(tSettings, 0, 0, []byte{0, 3, 0, 0, 0, 100})...)
	junk := make([]byte, 300000)
	rng.Read(junk)
	clientBytes = append(clientBytes, junk...) // not frames after the first: counted as desync, still forwarded
	serverBytes := append(frame(tSettings, 0, 0, nil), junk[:5000]...)
	got := make(chan [32]byte, 1)
	go func() {
		c, err := up.Accept()
		if err != nil {
			return
		}
		go func() { c.Write(serverBytes); c.(*net.TCPConn).CloseWrite() }()
		b, _ := io.ReadAll(c)
		got <- sha256.Sum256(b)
	}()

	for _, kind := range []string{"h2c", "tls"} {
		t.Run(kind, func(t *testing.T) {
			p, err := newProxy(kind)
			if err != nil {
				t.Fatal(err)
			}
			addr, err := p.Listen(kind, "127.0.0.1:0", up.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			var cc net.Conn
			if kind == "tls" {
				cc, err = tls.Dial("tcp", addr.String(), &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"h2"}})
			} else {
				cc, err = net.Dial("tcp", addr.String())
			}
			if err != nil {
				t.Fatal(err)
			}
			go func() { cc.Write(clientBytes); cc.(closeWriter).CloseWrite() }()
			back, _ := io.ReadAll(cc)
			if sha256.Sum256(back) != sha256.Sum256(serverBytes) {
				t.Error("server to client bytes changed")
			}
			if sha256.Sum256(clientBytes) != <-got {
				t.Error("client to server bytes changed")
			}
			cc.Close()
			p.Close()
			p.wg.Wait()
			r := p.Report()
			if len(r.Scenarios) != 1 || r.Scenarios[0].Totals["settings"] != 1 || r.Scenarios[0].Totals["settings_entries"] != 1 {
				t.Errorf("report: %+v", r.Scenarios)
			}
			if r.Table() == "" {
				t.Error("empty table")
			}
		})
		// next iteration needs a fresh upstream connection
		if kind == "h2c" {
			go func() {
				c, err := up.Accept()
				if err != nil {
					return
				}
				go func() { c.Write(serverBytes); c.(*net.TCPConn).CloseWrite() }()
				b, _ := io.ReadAll(c)
				got <- sha256.Sum256(b)
			}()
		}
	}
}

// readFrames reads whole frames from c and calls fn for each header.
func readFrames(c net.Conn, skipPreface bool, fn func(typ byte, stream uint32)) {
	if skipPreface {
		if _, err := io.ReadFull(c, make([]byte, len(preface))); err != nil {
			return
		}
	}
	h := make([]byte, 9)
	for {
		if _, err := io.ReadFull(c, h); err != nil {
			return
		}
		n := int(h[0])<<16 | int(h[1])<<8 | int(h[2])
		if _, err := io.CopyN(io.Discard, c, int64(n)); err != nil {
			return
		}
		fn(h[3], uint32(h[5])<<24|uint32(h[6])<<16|uint32(h[7])<<8|uint32(h[8]))
	}
}

// An upstream that answers each request at once must never be seen answering
// before the request was registered: every stream is closed at the end.
func TestAnsweredStreamsLeaveNothingBehind(t *testing.T) {
	up, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer up.Close()
	go func() {
		c, err := up.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		c.Write(frame(tSettings, 0, 0, nil))
		readFrames(c, true, func(typ byte, stream uint32) {
			if typ == tHeaders {
				c.Write(frame(tHeaders, fEndHeaders|fEndStream, stream, []byte("x")))
			}
		})
	}()
	p, err := newProxy("streams")
	if err != nil {
		t.Fatal(err)
	}
	addr, err := p.Listen("h2c", "127.0.0.1:0", up.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	cc, err := net.Dial("tcp", addr.String())
	if err != nil {
		t.Fatal(err)
	}
	cc.Write(append([]byte(preface), frame(tSettings, 0, 0, nil)...))
	answered := make(chan struct{}, 1)
	go readFrames(cc, false, func(typ byte, _ uint32) {
		if typ == tHeaders {
			answered <- struct{}{}
		}
	})
	const n = 2000
	for i := 0; i < n; i++ {
		cc.Write(frame(tHeaders, fEndHeaders|fEndStream, uint32(2*i+1), []byte("x")))
		<-answered
	}
	cc.Close()
	p.Close()
	p.wg.Wait()
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.conns) != 1 {
		t.Fatalf("conns: %d", len(p.conns))
	}
	if left := len(p.conns[0].streams); left != 0 {
		t.Errorf("%d streams still open after every request was answered", left)
	}
	if got := p.conns[0].Max["peak_streams"]; got != 1 {
		t.Errorf("peak_streams %d, want 1", got)
	}
}

// Dump while a connection is still changing its counters must not race
// (run with -race; without it the maps abort with a concurrent write).
func TestDumpDuringTraffic(t *testing.T) {
	up, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer up.Close()
	go func() {
		c, err := up.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		io.Copy(io.Discard, c)
	}()
	p, err := newProxy("dump")
	if err != nil {
		t.Fatal(err)
	}
	addr, err := p.Listen("h2c", "127.0.0.1:0", up.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	cc, err := net.Dial("tcp", addr.String())
	if err != nil {
		t.Fatal(err)
	}
	cc.Write(append([]byte(preface), frame(tSettings, 0, 0, nil)...))
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 3000; i++ {
			cc.Write(frame(byte(0x20+i%200), 0, 0, nil)) // new unknown type: a new map key each time
			cc.Write(frame(tPing, 0, 0, make([]byte, 8)))
		}
	}()
	for dumping := true; dumping; {
		select {
		case <-done:
			dumping = false
		default:
		}
		if b, table := p.Dump(); len(b) == 0 || table == "" {
			t.Fatal("empty dump")
		}
	}
	cc.Close()
	p.Close()
	p.wg.Wait()
}
