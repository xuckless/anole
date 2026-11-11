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
