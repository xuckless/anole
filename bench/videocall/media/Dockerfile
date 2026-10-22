# ffmpeg (libx264, libopus), numpy and Netflix's vmaf CLI (libvmaf 3.0.0,
# built from source: Debian packages no libvmaf), for making the video-call
# clip and scoring the probe call. Built from the repository root:
#   docker build -f bench/videocall/media/Dockerfile -t anole-bench/vc-media .
FROM debian:trixie-20251020-slim AS vmaf
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl meson ninja-build nasm gcc g++ xxd \
 && rm -rf /var/lib/apt/lists/*
ARG VMAF=3.0.0
RUN curl -fsSL https://github.com/Netflix/vmaf/archive/refs/tags/v$VMAF.tar.gz | tar -xz -C /tmp \
 && cd /tmp/vmaf-$VMAF/libvmaf \
 && meson setup build --buildtype release -Ddefault_library=static -Denable_float=true -Dbuilt_in_models=true \
 && ninja -C build tools/vmaf && cp build/tools/vmaf /usr/local/bin/vmaf

FROM debian:trixie-20251020-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg python3 python3-numpy \
 && rm -rf /var/lib/apt/lists/*
COPY --from=vmaf /usr/local/bin/vmaf /usr/local/bin/vmaf
COPY bench/videocall/media/gen.sh bench/videocall/media/quality.py /usr/local/bin/
