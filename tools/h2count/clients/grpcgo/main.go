// A tiny grpc-go client for tools/h2count: unary bursts and cancelled calls
// against examples/grpc's Greeter. The message is encoded by hand (field 1,
// a string), so no protoc and no generated code are needed.
package main

import (
	"context"
	"flag"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

type rawCodec struct{}

func (rawCodec) Name() string { return "proto" }
func (rawCodec) Marshal(v any) ([]byte, error) {
	return *v.(*[]byte), nil
}
func (rawCodec) Unmarshal(b []byte, v any) error {
	*v.(*[]byte) = append((*v.(*[]byte))[:0], b...)
	return nil
}

func hello(name string) []byte { return append([]byte{0x0a, byte(len(name))}, name...) }

func main() {
	addr := flag.String("addr", "127.0.0.1:9083", "gRPC server (h2c)")
	burst := flag.Int("burst", 1000, "unary calls in the burst")
	workers := flag.Int("workers", 50, "concurrent goroutines")
	cancels := flag.Int("cancels", 20, "calls cut off by a 100 ms deadline")
	flag.Parse()

	conn, err := grpc.NewClient(*addr, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithDefaultCallOptions(grpc.ForceCodec(rawCodec{})))
	if err != nil {
		panic(err)
	}
	defer conn.Close()

	var ok, failed atomic.Int64
	jobs := make(chan int)
	var wg sync.WaitGroup
	for range *workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				in, out := hello(fmt.Sprintf("n%d", i)), []byte(nil)
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				if err := conn.Invoke(ctx, "/greeter.Greeter/SayHello", &in, &out); err != nil {
					failed.Add(1)
				} else {
					ok.Add(1)
				}
				cancel()
			}
		}()
	}
	for i := range *burst {
		jobs <- i
	}
	close(jobs)
	wg.Wait()

	var cut atomic.Int64
	for range *cancels {
		wg.Add(1)
		go func() {
			defer wg.Done()
			in, out := hello("slow"), []byte(nil)
			ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
			defer cancel()
			if conn.Invoke(ctx, "/greeter.Greeter/SayHello", &in, &out) != nil {
				cut.Add(1)
			}
		}()
	}
	wg.Wait()
	fmt.Printf("unary ok=%d failed=%d, cancelled=%d of %d\n", ok.Load(), failed.Load(), cut.Load(), *cancels)
}
