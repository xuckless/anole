# syntax=docker/dockerfile:1
# Rust WebTransport bench server (wtransport 0.7.2, draft-02). Build from the repository root:
#   docker build -f bench/servers/axum-wt/Dockerfile -t anole-bench/axum-wt .
FROM rust:1.99.1-slim-trixie@sha256:4df2ae8cfdfebdfc13a65da7f253b73d68983dc0339f2719bc17a279c913b13d AS build
WORKDIR /repo/bench/servers/axum-wt
COPY bench/servers/axum-wt/Cargo.toml bench/servers/axum-wt/Cargo.lock ./
COPY bench/servers/axum-wt/src ./src
# Default release profile (opt-level 3, no LTO, codegen-units 16).
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/repo/bench/servers/axum-wt/target \
    cargo build --release --locked \
 && cp target/release/axum-wt-bench /usr/local/bin/axum-wt-bench

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:e792ab3d241a468a4fd7519ddbbebe66b49b5f365771716ea688ad40b6c6f1c2
COPY --from=build /usr/local/bin/axum-wt-bench /axum-wt-bench
ENTRYPOINT ["/axum-wt-bench"]
