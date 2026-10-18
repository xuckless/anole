// Package testpb is the Go code for grpc.testing (tests/grpc/proto), generated
// with protoc 31.1, protoc-gen-go v1.36.12 and protoc-gen-go-grpc v1.6.2. The
// protos have no go_package option, so the M flags name this package.
// Regenerate from the repository root (in golang:1.27.2-alpine3.24 with
// `apk add protobuf`):
//
//	M=Mgrpc/testing/test.proto=github.com/xuckless/anole/bench/servers/gohttp/testpb,Mgrpc/testing/messages.proto=github.com/xuckless/anole/bench/servers/gohttp/testpb,Mgrpc/testing/empty.proto=github.com/xuckless/anole/bench/servers/gohttp/testpb
//	protoc -I tests/grpc/proto \
//	  --go_out=bench/servers/gohttp/testpb --go_opt=paths=source_relative,$M \
//	  --go-grpc_out=bench/servers/gohttp/testpb --go-grpc_opt=paths=source_relative,$M \
//	  grpc/testing/test.proto grpc/testing/messages.proto grpc/testing/empty.proto
//	mv bench/servers/gohttp/testpb/grpc/testing/* bench/servers/gohttp/testpb/
package testpb
