package suite

import (
	"fmt"
	"path/filepath"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/load"
	"github.com/xuckless/anole/bench/tools/internal/sut"
)

// GRPC: unary calls (grpc.testing.TestService/UnaryCall, the interop
// semantics) with ghz over plaintext HTTP/2, on every tier: an empty reply
// and a 1 KiB one, 8 connections with 64 calls in flight.
func (s *Suite) GRPC() {
	for _, tier := range s.Tiers {
		for _, name := range s.Servers {
			if s.manifests[name].GRPC == "" {
				continue
			}
			srv, err := sut.Start(s.Cfg, name, "grpc", tier, nil, 0)
			if err != nil {
				s.record(Case{Scenario: "grpc", Server: name, Mode: "grpc", Proto: "grpc", Tier: tier.Name, Error: err.Error()})
				continue
			}
			for _, size := range []int{0, 1024} {
				r, u, lcpu, err := s.measure(srv, true, func(d time.Duration) (load.Result, error) {
					return load.Ghz(load.GhzOpts{Target: "127.0.0.1:50051", ProtoDir: filepath.Join(s.BenchDir, "grpc", "proto"),
						Conns: 8, Concurrency: 64, RespSize: size, Duration: d})
				})
				c := Case{Scenario: "grpc", Server: name, Mode: "grpc", Proto: "grpc", Tier: tier.Name, Endpoint: "UnaryCall",
					Param: fmt.Sprintf("%s, %d B reply", tier.Name, size), Load: r, SUT: u, LoadCPU: lcpu, Note: s.note(srv, lcpu)}
				if err != nil {
					c.Error = err.Error()
				}
				s.record(c)
			}
			sut.Stop()
		}
	}
}
