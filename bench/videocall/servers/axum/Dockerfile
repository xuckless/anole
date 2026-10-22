# syntax=docker/dockerfile:1
# Video-call relay on axum (bench/videocall/SPEC.md). Build from the repository root:
#   docker build -f bench/videocall/servers/axum/Dockerfile -t anole-bench/vc-axum .
FROM rust:1.99.1-slim-trixie@sha256:4df2ae8cfdfebdfc13a65da7f253b73d68983dc0339f2719bc17a279c913b13d AS build
WORKDIR /repo/bench/videocall/servers/axum
COPY bench/videocall/servers/axum/Cargo.toml bench/videocall/servers/axum/Cargo.lock ./
COPY bench/videocall/servers/axum/src ./src
# Default release profile (opt-level 3, no LTO, codegen-units 16).
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/repo/bench/videocall/servers/axum/target \
    cargo build --release --locked \
 && cp target/release/vc-axum /usr/local/bin/vc-axum

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:e792ab3d241a468a4fd7519ddbbebe66b49b5f365771716ea688ad40b6c6f1c2
COPY --from=build /usr/local/bin/vc-axum /vc-axum
ENTRYPOINT ["/vc-axum"]
