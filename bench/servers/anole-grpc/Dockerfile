# The gRPC transport bench server (Unix socket, h2c and TLS listeners at once).
# Built from the repository root:
#   docker build -f bench/servers/anole-grpc/Dockerfile -t anole-bench/anole-grpc .
FROM debian:trixie-20251020-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils git \
 && rm -rf /var/lib/apt/lists/*
ARG ZIG=0.17.0
ARG ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
RUN curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/$ZIG/zig-x86_64-linux-$ZIG.tar.xz \
 && echo "$ZIG_SHA256  /tmp/zig.tar.xz" | sha256sum -c - \
 && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
WORKDIR /src
COPY build.zig build.zig.zon LICENSE THIRD_PARTY_NOTICES README.md ./
COPY build/ build/
COPY src/ src/
COPY tests/ tests/
COPY examples/ examples/
COPY bench/grpc/proto/ bench/grpc/proto/
COPY bench/servers/anole-grpc/build.zig bench/servers/anole-grpc/build.zig.zon bench/servers/anole-grpc/
COPY bench/servers/anole-grpc/src/ bench/servers/anole-grpc/src/
# Baseline x86-64, as the bench server.
RUN --mount=type=cache,target=/root/.cache/zig \
    cd bench/servers/anole-grpc && for i in 1 2 3; do zig build --fetch && break; sleep 2; done \
 && zig build -Doptimize=ReleaseFast -Dcpu=baseline \
 && mkdir /out && cp zig-out/bin/anole-grpc /out/

FROM debian:trixie-20251020-slim
COPY --from=build /out/anole-grpc /usr/local/bin/anole-grpc
RUN mkdir /sock
ENTRYPOINT ["anole-grpc"]
