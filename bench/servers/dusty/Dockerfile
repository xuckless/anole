# Upstream dusty on upstream zio (Anole's ancestors), for the ws scenario.
# Built from the repository root:
#   docker build -f bench/servers/dusty/Dockerfile -t anole-bench/dusty .
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
COPY bench/servers/dusty/ ./
# Baseline x86-64, as every other compiled server here.
RUN --mount=type=cache,target=/root/.cache/zig \
    for i in 1 2 3; do zig build --fetch && break; sleep 2; done \
 && zig build -Doptimize=ReleaseFast -Dcpu=baseline && cp zig-out/bin/dusty-bench /dusty-bench

FROM debian:trixie-20251020-slim
COPY --from=build /dusty-bench /usr/local/bin/dusty-bench
ENTRYPOINT ["/usr/local/bin/dusty-bench"]
