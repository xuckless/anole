# The load generator and orchestrator image: every client tool the suite
# runs, plus benchctl (bench/tools). Built from the repository root:
#   docker build -f bench/loadgen/Dockerfile -t anole-bench/loadgen .
FROM fedora:44 AS wrk
RUN dnf -q install -y gcc make git perl openssl-devel unzip && dnf clean all
# wg/wrk master (the last tag, 4.2.0, predates fixes for current compilers).
RUN git clone -q https://github.com/wg/wrk /wrk && cd /wrk \
 && git checkout -q a211dd5a7050b1f9e8a9870b95513060e72ac4a0 \
 && make -j"$(nproc)" WITH_OPENSSL=/usr >/dev/null && cp wrk /usr/local/bin/wrk

# gcannon: HttpArena's io_uring load generator, for its WebSocket profiles
# (bench/tools/internal/suite/wspipe.go). Needs io_uring, so the loadgen
# container runs with seccomp unconfined (bench/suite.sh).
FROM fedora:44 AS gcannon
RUN dnf -q install -y gcc make git liburing-devel && dnf clean all
RUN git clone -q https://github.com/MDA2AV/gcannon /gcannon && cd /gcannon \
 && git checkout -q 11c802b2bdfe9af2fac4ac2571ae2de4c530cc62 \
 && make -j"$(nproc)" >/dev/null && cp gcannon /usr/local/bin/gcannon

FROM golang:1.27.2 AS tools
WORKDIR /src
COPY bench/tools/go.mod bench/tools/go.sum ./
RUN --mount=type=cache,target=/root/go/pkg/mod go mod download
COPY bench/tools/ ./
RUN --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -o /out/benchctl ./cmd/benchctl
# wtload: its own module (it pins the last draft-02 webtransport-go).
RUN --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    cd wtload && CGO_ENABLED=0 go build -o /out/wtload .

FROM fedora:44
RUN dnf -q install -y nghttp2 curl jq openssl procps-ng iproute bash findutils ffmpeg-free liburing \
 && dnf clean all
ARG OHA=1.16.0
ARG K6=2.3.0
ARG GHZ=0.121.0
ARG DOCKER=29.9.1
RUN curl -fsSL -o /usr/local/bin/oha https://github.com/hatoo/oha/releases/download/v$OHA/oha-linux-amd64 \
 && chmod +x /usr/local/bin/oha \
 && curl -fsSL https://github.com/grafana/k6/releases/download/v$K6/k6-v$K6-linux-amd64.tar.gz \
    | tar -xz -C /usr/local/bin --strip-components=1 k6-v$K6-linux-amd64/k6 \
 && curl -fsSL https://github.com/bojand/ghz/releases/download/v$GHZ/ghz-linux-x86_64.tar.gz \
    | tar -xz -C /usr/local/bin ghz \
 && curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-$DOCKER.tgz \
    | tar -xz -C /usr/local/bin --strip-components=1 docker/docker
COPY --from=wrk /usr/local/bin/wrk /usr/local/bin/wrk
COPY --from=gcannon /usr/local/bin/gcannon /usr/local/bin/gcannon
COPY --from=tools /out/benchctl /out/wtload /usr/local/bin/
WORKDIR /bench
ENTRYPOINT ["benchctl"]
