// vcload drives the video-call app (bench/videocall/SPEC.md) over WebSocket
// or WebTransport.
//
//	vcload -smoke -transport ws -url https://127.0.0.1:8443
//	vcload -transport wt -url https://127.0.0.1:8443 -media /data/media/vc \
//	       -cgroup /host/cgroup/system.slice/docker-<id>.scope -out results/vc/anole-wt
//
// -smoke runs the protocol end to end with three users and prints each
// check. Otherwise it ramps: -batch more users (default 1) every -step until the server
// crashes (its cgroup goes away, or an OOM kill), stops answering, or calls
// collapse. Each user streams the clip's H.264 video and Opus audio to its
// peer at real time, and chats every 3 s. It writes seconds.jsonl (one line
// a second), steps.jsonl (one line per user count) and the probe call's
// per-frame arrival logs.
//
// It is a module of its own because it pins webtransport-go v0.10.0, the
// draft-02 release browsers speak (as bench/tools/wtload does).
package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"time"
)

func main() {
	smokeMode := flag.Bool("smoke", false, "check the protocol end to end and exit")
	url := flag.String("url", "https://127.0.0.1:8443", "server base URL")
	transport := flag.String("transport", "ws", "ws (WebSocket over HTTP/1.1), ws-h2 (RFC 8441), ws-h3 (RFC 9220) or wt")
	mediaDir := flag.String("media", "/data/media/vc", "directory with video.h264 and audio.opus")
	cgroup := flag.String("cgroup", "", "the server's cgroup directory (memory, CPU, OOM and crash detection)")
	out := flag.String("out", "", "output directory (ramp)")
	step := flag.Duration("step", 5*time.Second, "time between added users")
	batch := flag.Int("batch", 1, "users added each step")
	maxUsers := flag.Int("max-users", 3000, "stop after this many users")
	stopBelow := flag.Float64("stop-below", parseFloat(stopBelowDefault), "stop once displayed video is under this share for 2 steps in a row (0: off)")
	fastTo := flag.Int("fast-to", int(parseFloat(fastToDefault)), "join users in -fast-batch batches up to this many, settle -settle, then step by -batch (0: off; only when at most -max-users)")
	fastBatch := flag.Int("fast-batch", int(parseFloat(fastBatchDefault)), "users added each step up to -fast-to")
	settle, _ := time.ParseDuration(settleDefault)
	settleF := flag.Duration("settle", settle, "pause at -fast-to before the steps go on")
	hold := flag.Duration("hold", 0, "at -max-users, keep the users this long and measure it as one step before stopping")
	maxTime := flag.Duration("max-time", 2*time.Hour, "stop after this long")
	collapse := flag.Duration("collapse", 30*time.Second, "stop when calls stay collapsed this long")
	videoDeadline := flag.Duration("video-deadline", 200*time.Millisecond, "a frame later than this (one way) misses its playout")
	audioDeadline := flag.Duration("audio-deadline", 150*time.Millisecond, "an audio packet later than this misses its playout")
	chatEvery := flag.Duration("chat-every", 3*time.Second, "chat interval per user")
	deflate := flag.Bool("deflate", true, "smoke: expect the server to deflate media (false for MEDIA_DEFLATE=off)")
	flag.Parse()

	switch *transport {
	case "ws", "ws-h2", "ws-h3", "wt":
	default:
		fmt.Fprintln(os.Stderr, "-transport must be ws, ws-h2, ws-h3 or wt")
		os.Exit(2)
	}
	if *smokeMode {
		if runSmoke(*url, *transport, *deflate) > 0 {
			os.Exit(1)
		}
		return
	}
	if *out == "" {
		fmt.Fprintln(os.Stderr, "-out is required")
		os.Exit(2)
	}
	c, err := loadClip(*mediaDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	r := &ramp{base: *url, transport: *transport, clip: c, cgroup: *cgroup, out: *out, step: *step,
		maxUsers: *maxUsers, hold: *hold, stopBelow: *stopBelow, fastTo: *fastTo, fastBatch: max(1, *fastBatch), settle: *settleF, batch: max(1, *batch), maxTime: *maxTime, collapse: *collapse, videoDeadline: *videoDeadline,
		audioDeadline: *audioDeadline, chatEvery: *chatEvery}
	if err := r.run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// stopBelowDefault is -stop-below's default; a run's binary may set it at
// link time (-ldflags "-X main.stopBelowDefault=0.4") so a harness that
// passes fixed arguments picks the rule up.
var stopBelowDefault = "0"

// The fast start's defaults, set the same way (main.fastToDefault=700 ...).
var (
	fastToDefault    = "0"
	fastBatchDefault = "50"
	settleDefault    = "30s"
)

func parseFloat(s string) float64 {
	f, _ := strconv.ParseFloat(s, 64)
	return f
}
