// The Go net/http bench server: the contract in bench/SPEC.md on the standard
// library, plus quic-go for HTTP/3 and grpc-go for gRPC.
//
//	MODE=h1   HTTP/1.1 on HTTP_PORT (default 8080)
//	MODE=h2c  HTTP/2 prior knowledge (and HTTP/1.1) on HTTP_PORT
//	MODE=tls  HTTPS, ALPN h2 + http/1.1, on HTTPS_PORT (default 8443)
//	MODE=h3   HTTP/3 on UDP HTTPS_PORT (and HTTPS on TCP HTTPS_PORT)
//	MODE=grpc grpc.testing.TestService on GRPC_PORT (default 50051)
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	n, err := strconv.Atoi(env(key, strconv.Itoa(def)))
	if err != nil {
		log.Fatalf("%s: %v", key, err)
	}
	return n
}

type Message struct {
	Message string `json:"message"`
}

type Item struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Active bool   `json:"active"`
	Score  int    `json:"score"`
}

type Node struct {
	ID     int      `json:"id"`
	Name   string   `json:"name"`
	Tags   []string `json:"tags"`
	Active bool     `json:"active"`
}

type Retained struct {
	ID   int      `json:"id"`
	Name string   `json:"name"`
	Tags []string `json:"tags"`
}

// retained stays reachable for the life of the process (the GC test).
var retained []Retained

func buildRetained(n int) {
	retained = make([]Retained, n)
	for i := range n {
		retained[i] = Retained{
			ID:   i,
			Name: "retained-" + strconv.Itoa(i),
			Tags: []string{"x" + strconv.Itoa(i%7), "y" + strconv.Itoa(i%11), "z" + strconv.Itoa(i%13)},
		}
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		log.Printf("json: %v", err)
		status, b = http.StatusInternalServerError, []byte(`{"error":"internal server error"}`)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(b)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, struct {
		Error string `json:"error"`
	}{msg})
}

func routes() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /plaintext", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		io.WriteString(w, "Hello, World!")
	})
	mux.HandleFunc("GET /json", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, Message{Message: "Hello, World!"})
	})
	mux.HandleFunc("GET /users/{id}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		io.WriteString(w, "user "+r.PathValue("id"))
	})
	mux.HandleFunc("GET /list", func(w http.ResponseWriter, r *http.Request) {
		items := make([]Item, 50)
		for i := 1; i <= 50; i++ {
			items[i-1] = Item{ID: i, Name: "item-" + strconv.Itoa(i), Active: i%2 == 0, Score: i * 7}
		}
		writeJSON(w, http.StatusOK, struct {
			Items []Item `json:"items"`
		}{items})
	})
	mux.HandleFunc("POST /echo", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 8<<20))
		if err != nil {
			if _, ok := errors.AsType[*http.MaxBytesError](err); ok {
				writeError(w, http.StatusRequestEntityTooLarge, "body too large")
			} else {
				writeError(w, http.StatusBadRequest, "bad body")
			}
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.Write(body)
	})
	mux.HandleFunc("GET /gc/alloc", func(w http.ResponseWriter, r *http.Request) {
		n, err := strconv.Atoi(r.URL.Query().Get("n"))
		if err != nil || n < 0 {
			n = 2000
		}
		nodes := make([]Node, n)
		for i := range n {
			nodes[i] = Node{
				ID:     i,
				Name:   "node-" + strconv.Itoa(i),
				Tags:   []string{"a" + strconv.Itoa(i%7), "b" + strconv.Itoa(i%11), "c" + strconv.Itoa(i%13)},
				Active: i%2 == 0,
			}
		}
		out, err := json.Marshal(nodes)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		writeJSON(w, http.StatusOK, struct {
			N     int `json:"n"`
			Bytes int `json:"bytes"`
		}{n, len(out)})
	})
	mux.HandleFunc("GET /gc/stats", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, struct {
			Retained int `json:"retained"`
		}{len(retained)})
	})
	mux.Handle("GET /static/", http.StripPrefix("/static", http.FileServer(http.Dir(env("MEDIA_DIR", "/media")))))

	registerWebSockets(mux, envInt("TICK_HZ", 1000))

	if dsn := os.Getenv("DATABASE_URL"); dsn != "" {
		registerTwelve(mux, dsn, envInt("PG_POOL", 20), env("JWT_SECRET", "twelve-dollar-challenge"))
	}

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "not found")
	})
	return mux
}

func main() {
	runtime.GOMAXPROCS(envInt("WORKERS", 1))

	mode := env("MODE", "h1")
	switch mode {
	case "h1", "h2c", "tls", "h3", "grpc":
	default:
		fmt.Fprintf(os.Stderr, "gohttp: unsupported MODE %q (supported: h1, h2c, tls, h3, grpc)\n", mode)
		os.Exit(3)
	}
	buildRetained(envInt("RETAIN", 0))

	httpAddr := "0.0.0.0:" + env("HTTP_PORT", "8080")
	httpsAddr := "0.0.0.0:" + env("HTTPS_PORT", "8443")
	certFile, keyFile := env("CERT_FILE", "/certs/cert.pem"), env("KEY_FILE", "/certs/key.pem")

	if mode == "grpc" {
		log.Fatal(serveGRPC("0.0.0.0:" + env("GRPC_PORT", "50051")))
	}

	mux := routes()
	switch mode {
	case "h1":
		srv := &http.Server{Addr: httpAddr, Handler: mux}
		log.Fatal(srv.ListenAndServe())
	case "h2c":
		var protocols http.Protocols
		protocols.SetHTTP1(true)
		protocols.SetUnencryptedHTTP2(true)
		srv := &http.Server{Addr: httpAddr, Handler: mux, Protocols: &protocols}
		log.Fatal(srv.ListenAndServe())
	case "tls":
		srv := &http.Server{Addr: httpsAddr, Handler: mux}
		log.Fatal(srv.ListenAndServeTLS(certFile, keyFile))
	case "h3":
		// quic-go's idle timeout defaults to 30 s; keep idle connections for 120 s.
		h3 := &http3.Server{Addr: httpsAddr, Handler: mux, QUICConfig: &quic.Config{MaxIdleTimeout: 120 * time.Second}}
		// HTTPS on TCP too, advertising h3 in Alt-Svc (what http3.ListenAndServeTLS does).
		srv := &http.Server{Addr: httpsAddr, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			h3.SetQUICHeaders(w.Header())
			mux.ServeHTTP(w, r)
		})}
		go func() { log.Fatal(srv.ListenAndServeTLS(certFile, keyFile)) }()
		log.Fatal(h3.ListenAndServeTLS(certFile, keyFile))
	}
}
