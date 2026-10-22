#!/bin/sh
# The clip every simulated user sends, into $1 (default /out):
#   video.h264  1080p30 H.264 High, 4 Mbit/s CBR, keyframe every 2 s, no
#               B-frames (x264 zerolatency, as video calls run), Annex B with
#               an AUD before each access unit
#   audio.opus  Opus 48 kHz mono, 64 kbit/s CBR, 20 ms packets (VoIP mode)
#   ref.json    frame and packet counts
# The picture is synthetic but busy (moving test pattern with temporal
# sensor-like noise), so the encoder has to spend its whole bitrate.
set -eu
out=${1:-/out}
dur=60
mkdir -p "$out"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30,noise=alls=14:allf=t+u,format=yuv420p" -t $dur \
  -c:v libx264 -profile:v high -preset medium -tune zerolatency \
  -b:v 4M -maxrate 4M -bufsize 4M -x264-params "nal-hrd=cbr:keyint=60:min-keyint=60:scenecut=0:bframes=0" \
  -bsf:v h264_metadata=aud=insert -f h264 "$out/video.h264"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=220:sample_rate=48000,volume=0.4" \
  -f lavfi -i "anoisesrc=color=pink:sample_rate=48000:amplitude=0.08" \
  -filter_complex "[0][1]amix=inputs=2,tremolo=f=3:d=0.6,aformat=channel_layouts=mono" -t $dur \
  -c:a libopus -b:a 64k -vbr off -application voip -frame_duration 20 "$out/audio.opus"
frames=$(ffprobe -v error -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$out/video.h264")
packets=$(ffprobe -v error -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$out/audio.opus")
printf '{"video_frames":%s,"audio_packets":%s,"seconds":%s}\n' "$frames" "$packets" "$dur" > "$out/ref.json"
ls -l "$out"
