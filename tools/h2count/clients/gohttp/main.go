// A Go net/http client for tools/h2count: 100 concurrent GETs, a 16 MiB
// upload and cancelled downloads against the test site, over TLS (ALPN h2)
// or h2c with prior knowledge. Exits 1 on any mismatch, and when a response
// is not HTTP/2 (a silent fallback to HTTP/1.1 is a failure).
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"

	"golang.org/x/net/http2"
)

type zeros struct{ left int }

func (z *zeros) Read(p []byte) (int, error) {
	if z.left == 0 {
		return 0, io.EOF
	}
	n := min(len(p), z.left)
	clear(p[:n])
	z.left -= n
	return n, nil
}

func main() {
	base := flag.String("url", "https://localhost:19443", "site base URL")
	h2c := flag.Bool("h2c", false, "HTTP/2 with prior knowledge over plain TCP (http:// URL)")
	ca := flag.String("ca", "", "PEM file trusted for TLS (default: the system roots)")
	flag.Parse()

	var rt http.RoundTripper
	if *h2c {
		rt = &http2.Transport{AllowHTTP: true, DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		}}
	} else {
		cfg := &tls.Config{}
		if *ca != "" {
			pem, err := os.ReadFile(*ca)
			if err != nil {
				fmt.Println(err)
				os.Exit(1)
			}
			cfg.RootCAs = x509.NewCertPool()
			cfg.RootCAs.AppendCertsFromPEM(pem)
		}
		rt = &http.Transport{TLSClientConfig: cfg, ForceAttemptHTTP2: true}
	}
	cl := &http.Client{Transport: rt}

	var bad, badProto atomic.Int64
	fail := func(format string, a ...any) { bad.Add(1); fmt.Printf("FAIL "+format+"\n", a...) }
	check := func(r *http.Response) {
		if r.Proto != "HTTP/2.0" {
			badProto.Add(1)
		}
	}

	var wg sync.WaitGroup
	var gets atomic.Int64
	for i := 1; i <= 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, err := cl.Get(fmt.Sprintf("%s/r/%d", *base, i))
			if err != nil {
				fail("GET /r/%d: %v", i, err)
				return
			}
			defer r.Body.Close()
			b, _ := io.ReadAll(r.Body)
			check(r)
			if r.StatusCode != 200 || !strings.HasPrefix(string(b), fmt.Sprintf("resource %d:", i)) {
				fail("GET /r/%d: %d %q", i, r.StatusCode, b)
				return
			}
			gets.Add(1)
		}()
	}
	wg.Wait()

	const size = 16 << 20
	var up int64
	r, err := cl.Post(*base+"/upload", "application/octet-stream", &zeros{size})
	if err != nil {
		fail("upload: %v", err)
	} else {
		check(r)
		b, _ := io.ReadAll(r.Body)
		r.Body.Close()
		if _, err := fmt.Sscan(string(b), &up); err != nil || up != size {
			fail("upload: %d %q", r.StatusCode, b)
		}
	}

	var cut atomic.Int64
	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			req, _ := http.NewRequestWithContext(ctx, "GET", *base+"/download", nil)
			r, err := cl.Do(req)
			if err != nil {
				fail("cancel: %v", err)
				return
			}
			check(r)
			io.CopyN(io.Discard, r.Body, 64<<10)
			cancel()
			if _, err := io.Copy(io.Discard, r.Body); err != nil {
				cut.Add(1)
			}
			r.Body.Close()
		}()
	}
	wg.Wait()
	// The connection must still work after the cancels.
	if r, err := cl.Get(*base + "/r/1"); err != nil || r.StatusCode != 200 {
		fail("GET after the cancels: %v", err)
	} else {
		r.Body.Close()
	}

	fmt.Printf("gohttp get ok=%d upload=%d cancelled=%d of 20 non-h2=%d failures=%d\n", gets.Load(), up, cut.Load(), badProto.Load(), bad.Load())
	if bad.Load() != 0 || badProto.Load() != 0 || cut.Load() != 20 {
		os.Exit(1)
	}
}
