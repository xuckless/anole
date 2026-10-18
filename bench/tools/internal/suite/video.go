package suite

import (
	"fmt"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/load"
	"github.com/xuckless/anole/bench/tools/internal/sut"
	"github.com/xuckless/anole/bench/tools/internal/video"
)

// The test clip's bitrate (bench/media/gen.sh): 25 Mbit/s.
const videoBitrate = 25e6

// Video: the 4K clip from /static/video/, per protocol the server serves
// natively. Unpaced: as many bytes as the server can push (downloads of the
// whole file). Paced: viewers that play in real time with a 30 s buffer,
// and how many of them stall; memory per stream from the server's growth.
func (s *Suite) Video() {
	tier := s.Tiers[0]
	viewers := 200
	if s.Profile.Name == "full" {
		viewers = 500
	}
	for _, name := range s.Servers {
		m := s.manifests[name]
		if m.Static == "" {
			continue
		}
		for _, mode := range []string{"h1", "tls", "h3"} {
			if !m.Supports(mode) {
				continue
			}
			srv, err := sut.Start(s.Cfg, name, mode, tier, map[string]string{"TICK_HZ": "0"}, 0)
			if err != nil {
				s.record(Case{Scenario: "video", Server: name, Mode: mode, Tier: tier.Name, Error: err.Error()})
				continue
			}
			base := sut.URL(mode)
			type run struct{ proto, kind string }
			var runs []run
			switch mode {
			case "h1":
				runs = []run{{"h1", "mp4"}, {"h1", "hls"}}
			case "tls":
				runs = []run{{"h1", "mp4"}}
				if contains(m.TLSALPN, "h2") {
					runs = append(runs, run{"h2", "hls"})
				}
			case "h3":
				runs = []run{{"h3", "hls"}}
			}
			for _, rn := range runs {
				proto := rn.proto
				if mode == "tls" {
					proto += "-tls"
				}
				if proto == "h2-tls" {
					proto = "h2-tls"
				}
				// Unpaced: whole-file downloads, closed loop.
				url := base + "/static/video/4k.mp4"
				r, u, lcpu, err := s.measure(srv, false, func(d time.Duration) (load.Result, error) {
					switch rn.proto {
					case "h1":
						return load.Wrk(load.WrkOpts{URL: url, Threads: 8, Conns: 64, Duration: d, Script: s.script()})
					default:
						return load.H2load(load.H2loadOpts{URL: url, Threads: 4, Clients: 16, Streams: 4, Duration: d, H3: rn.proto == "h3"})
					}
				})
				if rn.kind == "mp4" || rn.proto != "h1" {
					c := Case{Scenario: "video", Server: name, Mode: mode, Proto: proto, Tier: tier.Name, Endpoint: "4k.mp4",
						Param: "unpaced", Load: r, SUT: u, LoadCPU: lcpu, Note: s.note(srv, lcpu)}
					if err != nil {
						c.Error = err.Error()
					} else {
						c.Note = fmt.Sprintf("%.2f Gbit/s", r.MBps*8/1000) + prefixNote(c.Note)
					}
					s.record(c)
				}

				// Paced viewers.
				time.Sleep(2 * time.Second)
				idle := srv.MemNowMB()
				smp := srv.Sample(500*time.Millisecond, false)
				pr, err := video.Play(video.Options{Base: base, Proto: rn.proto, Kind: rn.kind, BitrateBps: videoBitrate,
					Ahead: 30 * time.Second, StartBuffer: 2 * time.Second, Chunk: 2 << 20}, viewers, 10*time.Second, 2*s.Profile.Run)
				pu := smp.Stop()
				c := Case{Scenario: "video", Server: name, Mode: mode, Proto: proto, Tier: tier.Name, Endpoint: rn.kind,
					Param: fmt.Sprintf("paced viewers=%d", viewers), SUT: pu,
					Load: load.Result{Tool: "benchctl video", Requests: int64(pr.Started), Errors: pr.Errors, MBps: pr.Gbps * 125}}
				if err != nil {
					c.Error = err.Error()
				} else {
					c.Note = fmt.Sprintf("%.2f Gbit/s; %d of %d stalled, stall ratio %.2f%%; startup p50 %.0f ms; %.0f KB per stream",
						pr.Gbps, pr.Stalled, pr.Viewers, pr.StallRatio()*100, pr.StartupP50MS, (pu.MemMB-idle)*1024/float64(viewers)) +
						prefixNote(s.note(srv, 0))
				}
				c.Video = &pr
				s.record(c)
			}
			sut.Stop()
		}
	}
}

func prefixNote(n string) string {
	if n == "" {
		return ""
	}
	return "; " + n
}
