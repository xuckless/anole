#!/bin/sh
# The 4K test video every server streams: 60 s of 3840x2160 at 60 fps, AV1
# (what YouTube serves at 4K) at about 25 Mbit/s, from a moving test
# pattern with grain so the encoder cannot cheat the bitrate down.
#   bench/.data/media/video/4k.mp4          progressive MP4, moov first (Range playback)
#   bench/.data/media/video/hls/index.m3u8  HLS, 4 s fMP4 segments (YouTube-style)
# Needs ffmpeg with libsvtav1. Pinned to MEDIA_CPUS (default 16-19), niced.
set -eu
out=$(cd "$(dirname "$0")/.." && pwd)/.data/media/video
[ -f "$out/hls/index.m3u8" ] && [ -f "$out/4k.mp4" ] && { echo "media present: $out"; exit 0; }
mkdir -p "$out/hls"
run() { nice -n 19 taskset -c "${MEDIA_CPUS:-16-19}" "$@"; }
run ffmpeg -hide_banner -loglevel warning -y \
  -f lavfi -i "testsrc2=size=3840x2160:rate=60:duration=60,noise=alls=12:allf=t" \
  -c:v libsvtav1 -preset 9 -b:v 25M -g 240 -pix_fmt yuv420p \
  -movflags +faststart "$out/4k.mp4"
run ffmpeg -hide_banner -loglevel warning -y -i "$out/4k.mp4" -c copy \
  -f hls -hls_time 4 -hls_playlist_type vod -hls_segment_type fmp4 \
  -hls_fmp4_init_filename init.mp4 -hls_segment_filename "$out/hls/seg%03d.m4s" "$out/hls/index.m3u8"
ls -la "$out" "$out/hls" | head -30
