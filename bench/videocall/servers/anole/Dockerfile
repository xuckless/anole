# The video-call app on Anole v0.1.3 (fetched by build.zig.zon, as an
# application does), built from the repository root:
#   docker build -f bench/videocall/servers/anole/Dockerfile -t anole-bench/vc-anole .
FROM debian:trixie-20251020-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils git \
 && rm -rf /var/lib/apt/lists/*
ARG ZIG=0.17.0
ARG ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
RUN curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/$ZIG/zig-x86_64-linux-$ZIG.tar.xz \
 && echo "$ZIG_SHA256  /tmp/zig.tar.xz" | sha256sum -c - \
 && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
WORKDIR /app
COPY bench/videocall/servers/anole/build.zig bench/videocall/servers/anole/build.zig.zon ./
COPY bench/videocall/servers/anole/src/ src/
# ReleaseSafe, as Anole's docs tell applications to build. Baseline x86-64,
# as Go (GOAMD64=v1) and Rust build by default.
RUN --mount=type=cache,target=/root/.cache/zig \
    for i in 1 2 3; do zig build --fetch && break; sleep 2; done \
 && zig build -Doptimize=ReleaseSafe -Dcpu=baseline

FROM debian:trixie-20251020-slim
COPY --from=build /app/zig-out/bin/videocall /usr/local/bin/videocall
ENTRYPOINT ["/usr/local/bin/videocall"]
