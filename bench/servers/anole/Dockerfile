# The Anole bench server (bench/SPEC.md), plus Anole's gRPC interop server
# for MODE=grpc. Built from the repository root:
#   docker build -f bench/servers/anole/Dockerfile -t anole-bench/anole .
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
# Only what the build reads, so that changes elsewhere in bench/ keep the
# cached image.
COPY build.zig build.zig.zon LICENSE THIRD_PARTY_NOTICES README.md ./
COPY build/ build/
COPY src/ src/
COPY tests/ tests/
COPY examples/ examples/
COPY bench/servers/anole/build.zig bench/servers/anole/build.zig.zon bench/servers/anole/
COPY bench/servers/anole/src/ bench/servers/anole/src/
# Baseline x86-64, as Go (GOAMD64=v1) and Rust build by default; Zig's own
# default, the build host's CPU, would give Anole an edge the others lack.
RUN --mount=type=cache,target=/root/.cache/zig \
    cd bench/servers/anole && for i in 1 2 3; do zig build --fetch && break; sleep 2; done \
 && zig build -Doptimize=ReleaseFast -Dcpu=baseline \
 && cd /src && for i in 1 2 3; do zig build --fetch && break; sleep 2; done \
 && zig build grpc-interop-server -Doptimize=ReleaseFast -Dcpu=baseline \
 && mkdir /out && cp bench/servers/anole/zig-out/bin/anole-bench zig-out/bin/grpc-interop-server /out/

FROM debian:trixie-20251020-slim
COPY --from=build /out/ /usr/local/bin/
COPY bench/servers/anole/entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
