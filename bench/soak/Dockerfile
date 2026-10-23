# examples/full from an Anole source tree, for the soak/leak test
# (bench/soak/run.sh). The build context is that tree, e.g. a `git archive`
# of the commit under test:
#   docker build -f bench/soak/Dockerfile --build-arg OPTIMIZE=ReleaseSafe -t anole-bench/soak-full:ReleaseSafe <tree>
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
COPY . .
ARG OPTIMIZE=ReleaseSafe
# Baseline x86-64, as for the other bench builds.
RUN --mount=type=cache,target=/root/.cache/zig \
    for i in 1 2 3; do zig build --fetch && break; sleep 2; done \
 && zig build full -Doptimize=$OPTIMIZE -Dcpu=baseline \
 && mkdir /out && cp zig-out/bin/full /out/

FROM debian:trixie-20251020-slim
COPY --from=build /out/full /usr/local/bin/full
ENTRYPOINT ["/usr/local/bin/full"]
