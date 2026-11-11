// h2count is a counting TCP proxy for HTTP/2: it accepts TLS (ALPN h2) and
// h2c prior knowledge, forwards the bytes unchanged to an upstream h2c
// server, and counts the client-to-server frames per connection with a 1 s
// sliding peak. It exists to calibrate the flood budgets of Anole's HTTP/2
// engine against real clients (research/h2h3-takeover/PLAN.md section 5.4).
// Go standard library only. See README.md.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"text/tabwriter"
	"time"
)

type listenFlag []string

func (l *listenFlag) String() string     { return strings.Join(*l, ",") }
func (l *listenFlag) Set(v string) error { *l = append(*l, v); return nil }

// Proxy holds the connections seen so far; one mutex guards all counters.
type Proxy struct {
	mu       sync.Mutex
	start    time.Time
	scenario string
	conns    []*Conn
	live     map[*Conn]time.Time
	cert     tls.Certificate
	lis      []net.Listener
	wg       sync.WaitGroup
}

func newProxy(scenario string) (*Proxy, error) {
	cert, err := selfSigned()
	if err != nil {
		return nil, err
	}
	return &Proxy{start: time.Now(), scenario: scenario, cert: cert, live: map[*Conn]time.Time{}}, nil
}

func (p *Proxy) now() time.Duration { return time.Since(p.start) } // monotonic

func (p *Proxy) setScenario(name string) {
	p.mu.Lock()
	p.scenario = name
	p.mu.Unlock()
}

// Listen starts a listener: kind is "tls" or "h2c", every accepted
// connection is forwarded to the h2c upstream address.
func (p *Proxy) Listen(kind, addr, upstream string) (net.Addr, error) {
	l, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	if kind == "tls" {
		l = tls.NewListener(l, &tls.Config{Certificates: []tls.Certificate{p.cert}, NextProtos: []string{"h2", "http/1.1"}})
	}
	p.mu.Lock()
	p.lis = append(p.lis, l)
	p.mu.Unlock()
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			p.wg.Add(1)
			go func() { defer p.wg.Done(); p.handle(c, kind+"@"+addr, upstream) }()
		}
	}()
	return l.Addr(), nil
}

type closeWriter interface{ CloseWrite() error }

func (p *Proxy) handle(client net.Conn, listener, upstream string) {
	defer client.Close()
	if tc, ok := client.(*tls.Conn); ok {
		if err := tc.Handshake(); err != nil {
			return
		}
		if tc.ConnectionState().NegotiatedProtocol != "h2" {
			p.mu.Lock()
			p.conns = append(p.conns, &Conn{Scenario: p.scenario, Listener: listener, Client: client.RemoteAddr().String(), Start: time.Now(),
				Rates: map[string]*Ctr{"not_h2": {Total: 1}}})
			p.mu.Unlock()
			return
		}
	}
	up, err := net.Dial("tcp", upstream)
	if err != nil {
		fmt.Fprintln(os.Stderr, "h2count: upstream:", err)
		return
	}
	defer up.Close()
	for _, c := range []net.Conn{client, up} {
		var raw net.Conn = c
		if tc, ok := c.(*tls.Conn); ok {
			raw = tc.NetConn()
		}
		if t, ok := raw.(*net.TCPConn); ok {
			t.SetNoDelay(true)
		}
	}
	p.mu.Lock()
	c := newConn(p.now)
	c.ID, c.Scenario, c.Listener, c.Client, c.Start = len(p.conns)+1, p.scenario, listener, client.RemoteAddr().String(), time.Now()
	p.conns = append(p.conns, c)
	p.live[c] = c.Start
	p.mu.Unlock()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); p.pipe(up, client, c, c.cf, &c.BytesC2S, &c.DesyncC) }()
	go func() { defer wg.Done(); p.pipe(client, up, c, c.sf, &c.BytesS2C, &c.DesyncS) }()
	wg.Wait()
	p.mu.Lock()
	c.Seconds = time.Since(c.Start).Seconds()
	delete(p.live, c)
	p.mu.Unlock()
}

// pipe copies src to dst unchanged, then shows the bytes to the parser, so a
// parse failure never changes what is forwarded.
func (p *Proxy) pipe(dst, src net.Conn, c *Conn, f *framer, bytes *int64, desync *bool) {
	buf := make([]byte, 32<<10)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if _, werr := dst.Write(buf[:n]); werr != nil {
				err = werr
			}
			p.mu.Lock()
			*bytes += int64(n)
			f.feed(buf[:n])
			*desync = f.desync
			p.mu.Unlock()
		}
		if err != nil {
			if cw, ok := dst.(closeWriter); ok && err == io.EOF {
				cw.CloseWrite()
			} else {
				dst.Close()
				src.Close()
			}
			return
		}
	}
}

// Close stops the listeners and closes nothing else; connections end with their peers.
func (p *Proxy) Close() {
	p.mu.Lock()
	for _, l := range p.lis {
		l.Close()
	}
	p.mu.Unlock()
}

type Report struct {
	Tool      string     `json:"tool"`
	Generated time.Time  `json:"generated"`
	Scenarios []Scenario `json:"scenarios"`
	Caveat    string     `json:"caveat"`
}

type Scenario struct {
	Name   string           `json:"name"`
	Conns  int              `json:"connections"`
	Rollup map[string]int64 `json:"rollup_max_over_connections"`
	Totals map[string]int64 `json:"rollup_total"`
	Detail []*Conn          `json:"conns"`
}

// Report snapshots every connection (still open ones with their time so far)
// and rolls each scenario up: per counter the largest 1 s peak over its
// connections, because every budget applies to one connection.
func (p *Proxy) Report() *Report {
	p.mu.Lock()
	defer p.mu.Unlock()
	byName := map[string]*Scenario{}
	var order []string
	for _, c := range p.conns {
		if c.Seconds == 0 {
			c.Seconds = time.Since(c.Start).Seconds()
		}
		s := byName[c.Scenario]
		if s == nil {
			s = &Scenario{Name: c.Scenario, Rollup: map[string]int64{}, Totals: map[string]int64{}}
			byName[c.Scenario] = s
			order = append(order, c.Scenario)
		}
		s.Conns++
		s.Detail = append(s.Detail, c)
		for k, r := range c.Rates {
			s.Rollup[k+"/s"] = max(s.Rollup[k+"/s"], r.Peak1s)
			s.Rollup[k+"/100ms"] = max(s.Rollup[k+"/100ms"], r.Peak100)
			s.Totals[k] += r.Total
			s.Rollup[k+"/conn_total"] = max(s.Rollup[k+"/conn_total"], r.Total)
		}
		for k, v := range c.Max {
			s.Rollup[k] = max(s.Rollup[k], v)
		}
	}
	r := &Report{Tool: "h2count", Generated: time.Now().UTC(),
		Caveat: "client-to-server frames seen by a TLS-terminating TCP proxy; peaks are over 0.9-1.0 s windows; unanswered RSTs are judged from END_STREAM on the wire"}
	for _, n := range order {
		r.Scenarios = append(r.Scenarios, *byName[n])
	}
	return r
}

var tableCols = []struct{ head, key string }{
	{"conns", ""}, {"streams", "peak_streams"}, {"req/s", "requests/s"}, {"PING/s", "ping/s"}, {"SETT", "settings/conn_total"},
	{"ent/frm", "settings_entries_per_frame"}, {"RST/s", "rst/s"}, {"RST/100ms", "rst/100ms"}, {"RSTun", "rst_unanswered/conn_total"},
	{"emptyD", "data_empty/conn_total"}, {"emptyH", "headers_empty/conn_total"}, {"emptyC", "continuation_empty/conn_total"},
	{"unk", "unknown/conn_total"}, {"CONT/blk", "continuations_per_block"}, {"hblk B", "header_block_bytes"},
	{"WU/s", "window_update/s"}, {"PRIO", "priority/conn_total"},
}

func (r *Report) Table() string {
	var sb strings.Builder
	tw := tabwriter.NewWriter(&sb, 0, 0, 2, ' ', 0)
	fmt.Fprint(tw, "scenario")
	for _, c := range tableCols {
		fmt.Fprint(tw, "\t", c.head)
	}
	fmt.Fprintln(tw)
	for _, s := range r.Scenarios {
		fmt.Fprint(tw, s.Name)
		for _, c := range tableCols {
			if c.key == "" {
				fmt.Fprint(tw, "\t", s.Conns)
			} else {
				fmt.Fprint(tw, "\t", s.Rollup[c.key])
			}
		}
		fmt.Fprintln(tw)
	}
	tw.Flush()
	return sb.String()
}

func selfSigned() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: "h2count"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(48 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}

func main() {
	var listens listenFlag
	flag.Var(&listens, "listen", "kind@addr=upstream, e.g. tls@:9443=127.0.0.1:8080 or h2c@:9080=127.0.0.1:8080 (repeatable)")
	out := flag.String("out", "h2count.json", "JSON report written at exit (and on GET /dump)")
	certOut := flag.String("cert-out", "", "write the generated certificate (PEM) here")
	ctl := flag.String("ctl", "127.0.0.1:9990", "control address: GET /scenario?name=X starts a new bucket, GET /dump writes the report")
	label := flag.String("label", "run", "name of the first scenario")
	flag.Parse()
	if len(listens) == 0 {
		fmt.Fprintln(os.Stderr, "usage: h2count -listen tls@:9443=127.0.0.1:8080 [-listen h2c@:9080=...] [-out file.json]")
		os.Exit(2)
	}
	p, err := newProxy(*label)
	if err != nil {
		fmt.Fprintln(os.Stderr, "h2count:", err)
		os.Exit(1)
	}
	if *certOut != "" {
		der := p.cert.Certificate[0]
		if err := os.WriteFile(*certOut, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "h2count:", err)
			os.Exit(1)
		}
	}
	for _, l := range listens {
		kindAddr, upstream, ok := strings.Cut(l, "=")
		kind, addr, ok2 := strings.Cut(kindAddr, "@")
		if !ok || !ok2 || (kind != "tls" && kind != "h2c") {
			fmt.Fprintln(os.Stderr, "h2count: bad -listen", l)
			os.Exit(2)
		}
		a, err := p.Listen(kind, addr, upstream)
		if err != nil {
			fmt.Fprintln(os.Stderr, "h2count:", err)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "h2count: %s on %s -> %s\n", kind, a, upstream)
	}
	write := func() {
		r := p.Report()
		b, _ := json.MarshalIndent(r, "", " ")
		if err := os.WriteFile(*out, b, 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "h2count:", err)
		}
		fmt.Fprint(os.Stderr, r.Table())
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/scenario", func(w http.ResponseWriter, r *http.Request) {
		p.setScenario(r.URL.Query().Get("name"))
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/dump", func(w http.ResponseWriter, r *http.Request) { write(); fmt.Fprintln(w, "ok") })
	cl, err := net.Listen("tcp", *ctl)
	if err != nil {
		fmt.Fprintln(os.Stderr, "h2count:", err)
		os.Exit(1)
	}
	go http.Serve(cl, mux)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	p.Close()
	write()
}
