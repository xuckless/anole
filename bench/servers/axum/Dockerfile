# syntax=docker/dockerfile:1
# Axum bench server (bench/SPEC.md). Build from the repository root:
#   docker build -f bench/servers/axum/Dockerfile -t anole-bench/axum .
FROM rust:1.99.1-slim-trixie@sha256:4df2ae8cfdfebdfc13a65da7f253b73d68983dc0339f2719bc17a279c913b13d AS build
# protoc for tonic-prost-build (build.rs).
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler \
 && rm -rf /var/lib/apt/lists/*
# Same layout as the repository, so build.rs finds the interop proto at ../../../tests/grpc/proto.
COPY tests/grpc/proto /repo/tests/grpc/proto
WORKDIR /repo/bench/servers/axum
COPY bench/servers/axum/Cargo.toml bench/servers/axum/Cargo.lock bench/servers/axum/build.rs ./
COPY bench/servers/axum/src ./src
# Default release profile (opt-level 3, no LTO, codegen-units 16).
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/repo/bench/servers/axum/target \
    cargo build --release --locked \
 && cp target/release/axum-bench /usr/local/bin/axum-bench

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:e792ab3d241a468a4fd7519ddbbebe66b49b5f365771716ea688ad40b6c6f1c2
COPY --from=build /usr/local/bin/axum-bench /axum-bench
ENTRYPOINT ["/axum-bench"]
