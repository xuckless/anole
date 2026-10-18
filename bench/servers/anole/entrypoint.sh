#!/bin/sh
# MODE=grpc runs Anole's gRPC interop server; every other mode the bench server.
if [ "${MODE:-h1}" = grpc ]; then exec grpc-interop-server "${GRPC_PORT:-50051}"; fi
exec anole-bench
