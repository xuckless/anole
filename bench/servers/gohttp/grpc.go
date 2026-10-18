package main

import (
	"context"
	"net"

	"google.golang.org/grpc"

	"github.com/xuckless/anole/bench/servers/gohttp/testpb"
)

type testService struct {
	testpb.UnimplementedTestServiceServer
}

// UnaryCall answers with response_size zero bytes, as the interop server does.
func (testService) UnaryCall(_ context.Context, req *testpb.SimpleRequest) (*testpb.SimpleResponse, error) {
	return &testpb.SimpleResponse{
		Payload: &testpb.Payload{Type: req.GetResponseType(), Body: make([]byte, req.GetResponseSize())},
	}, nil
}

func serveGRPC(addr string) error {
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	s := grpc.NewServer()
	testpb.RegisterTestServiceServer(s, testService{})
	return s.Serve(lis)
}
