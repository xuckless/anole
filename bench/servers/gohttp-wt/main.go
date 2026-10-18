// The Go WebTransport bench server: /wt/echo (bench/SPEC.md, "WebTransport")
// on webtransport-go v0.10.0 over quic-go's http3, plus /plaintext over the
// same HTTP/3 endpoint for the readiness probe.
//
//	MODE=h3  WebTransport and HTTP/3 on UDP HTTPS_PORT (default 8443)
//
// webtransport-go v0.10.0 is the last release that speaks draft-02, the
// version Chrome, Edge and Firefox use; v0.11 and later speak draft-15.
package main

import (
	"context"
	"crypto/tls"
	"io"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/quic-go/webtransport-go"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	if mode := env("MODE", "h1"); mode != "h3" {
		log.Printf("unsupported MODE %q: this server only does h3 (WebTransport)", mode)
		os.Exit(3)
	}
	workers, err := strconv.Atoi(env("WORKERS", "1"))
	if err != nil || workers < 1 {
		log.Fatalf("WORKERS: %q", os.Getenv("WORKERS"))
	}
	runtime.GOMAXPROCS(workers)

	cert, err := tls.LoadX509KeyPair(env("CERT_FILE", "/certs/cert.pem"), env("KEY_FILE", "/certs/key.pem"))
	if err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	wt := &webtransport.Server{
		H3: &http3.Server{
			Addr:      ":" + env("HTTPS_PORT", "8443"),
			Handler:   mux,
			TLSConfig: http3.ConfigureTLSConfig(&tls.Config{Certificates: []tls.Certificate{cert}}),
			// quic-go's default idle timeout is 30 s; the spec wants 75 s or more.
			QUICConfig: &quic.Config{MaxIdleTimeout: 120 * time.Second},
		},
		// The load client sends no Origin; a browser page on another origin would.
		CheckOrigin: func(*http.Request) bool { return true },
	}
	webtransport.ConfigureHTTP3Server(wt.H3)

	mux.HandleFunc("GET /plaintext", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte("Hello, World!"))
	})
	mux.HandleFunc("CONNECT /wt/echo", func(w http.ResponseWriter, r *http.Request) {
		sess, err := wt.Upgrade(w, r)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		go echoStreams(sess)
		echoDatagrams(sess)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`{"error":"not found"}`))
	})

	log.Fatal(wt.ListenAndServe())
}

// echoStreams sends every bidirectional stream back on itself and ends the
// send side once the client's has ended.
func echoStreams(sess *webtransport.Session) {
	for {
		str, err := sess.AcceptStream(context.Background())
		if err != nil {
			return
		}
		go func() {
			if _, err := io.Copy(str, str); err != nil {
				str.CancelRead(0)
				str.CancelWrite(0)
				return
			}
			str.Close()
		}()
	}
}

// echoDatagrams sends every datagram back unchanged until the session ends.
func echoDatagrams(sess *webtransport.Session) {
	for {
		b, err := sess.ReceiveDatagram(context.Background())
		if err != nil {
			return
		}
		sess.SendDatagram(b)
	}
}
