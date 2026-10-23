// grpcload drives grpc.testing.TestService/UnaryCall with grpc-go over a
// Unix socket, h2c or TLS, for comparing transports with one handler:
//
//	grpcload -target unix:/sock/grpc.sock -conns 4 -c 64 -d 30s
//	grpcload -target 127.0.0.1:50051 ...
//	grpcload -target 127.0.0.1:50052 -tls ...
//
// -c calls in flight spread over -conns connections, each call waiting for
// its answer before the next. The request asks for -size response bytes.
// It is a module of its own so the tools module does not carry grpc-go.
// Prints the result as JSON.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding"
)

// raw passes []byte through as the message.
type raw struct{}

func (raw) Marshal(v any) ([]byte, error) { return *(v.(*[]byte)), nil }
func (raw) Unmarshal(b []byte, v any) error {
	*(v.(*[]byte)) = append((*(v.(*[]byte)))[:0], b...)
	return nil
}
func (raw) Name() string { return "proto" }

func init() { encoding.RegisterCodec(raw{}) }

type result struct {
	Target string  `json:"target"`
	Conns  int     `json:"conns"`
	Calls  int     `json:"concurrency"`
	OK     int64   `json:"ok"`
	Errors int64   `json:"errors"`
	RPS    float64 `json:"rps"`
	P50    float64 `json:"p50_ms"`
	P99    float64 `json:"p99_ms"`
	P999   float64 `json:"p999_ms"`
	Max    float64 `json:"max_ms"`
	First  string  `json:"first_error,omitempty"`
}

func main() {
	target := flag.String("target", "127.0.0.1:50051", "unix:/path, or host:port")
	useTLS := flag.Bool("tls", false, "TLS (certificate not verified)")
	conns := flag.Int("conns", 4, "connections")
	calls := flag.Int("c", 64, "calls in flight")
	size := flag.Int("size", 0, "response bytes asked for")
	d := flag.Duration("d", 30*time.Second, "measured time")
	warm := flag.Duration("warm", 3*time.Second, "warm-up before measuring")
	flag.Parse()

	creds := insecure.NewCredentials()
	if *useTLS {
		creds = credentials.NewTLS(&tls.Config{InsecureSkipVerify: true})
	}
	cc := make([]*grpc.ClientConn, *conns)
	for i := range cc {
		c, err := grpc.NewClient(*target, grpc.WithTransportCredentials(creds))
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		defer c.Close()
		cc[i] = c
	}
	// SimpleRequest{response_size: size}: field 2, varint.
	req := []byte{0x10}
	for v := uint64(*size); ; v >>= 7 {
		if v < 0x80 {
			req = append(req, byte(v))
			break
		}
		req = append(req, byte(v)|0x80)
	}

	var measuring atomic.Bool
	var ok, errs atomic.Int64
	var firstErr atomic.Value
	lat := make([][]float64, *calls)
	// Calls run without a deadline and stop on a flag, so the ones in
	// flight at the end are neither cut nor counted as errors.
	var stop atomic.Bool
	ctx := context.Background()
	var wg sync.WaitGroup
	for i := 0; i < *calls; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			c := cc[i%len(cc)]
			var resp []byte
			for !stop.Load() {
				r := req
				t0 := time.Now()
				err := c.Invoke(ctx, "/grpc.testing.TestService/UnaryCall", &r, &resp)
				el := time.Since(t0)
				if !measuring.Load() {
					continue
				}
				if stop.Load() {
					return
				}
				if err != nil {
					errs.Add(1)
					firstErr.CompareAndSwap(nil, err.Error())
					continue
				}
				ok.Add(1)
				lat[i] = append(lat[i], float64(el.Microseconds())/1000)
			}
		}(i)
	}
	time.Sleep(*warm)
	measuring.Store(true)
	t0 := time.Now()
	time.Sleep(*d)
	stop.Store(true)
	el := time.Since(t0).Seconds()
	wg.Wait()

	var all []float64
	for _, l := range lat {
		all = append(all, l...)
	}
	sort.Float64s(all)
	pct := func(p float64) float64 {
		if len(all) == 0 {
			return 0
		}
		return all[min(len(all)-1, int(p*float64(len(all))))]
	}
	r := result{Target: *target, Conns: *conns, Calls: *calls, OK: ok.Load(), Errors: errs.Load(),
		RPS: float64(ok.Load()) / el, P50: pct(0.5), P99: pct(0.99), P999: pct(0.999), Max: pct(1)}
	if e, _ := firstErr.Load().(string); e != "" {
		r.First = e
	}
	json.NewEncoder(os.Stdout).Encode(r)
}
