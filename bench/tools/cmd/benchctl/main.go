// benchctl drives the cross-framework benchmark (bench/README.md). It runs
// in the anole-bench/loadgen container, which bench/suite.sh starts with the
// Docker socket, the host's cgroup tree and bench/ mounted.
//
//	benchctl suite  [-profile quick|full] [-tiers 1,4] [-only raw,conns,latency] [-servers a,b] -out DIR
//	benchctl report DIR
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/report"
	"github.com/xuckless/anole/bench/tools/internal/suite"
	"github.com/xuckless/anole/bench/tools/internal/sut"
)

func main() {
	log.SetFlags(log.Ltime)
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "suite":
		runSuite(os.Args[2:])
	case "report":
		if len(os.Args) < 3 {
			usage()
		}
		if err := report.Write(os.Args[2]); err != nil {
			log.Fatal(err)
		}
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: benchctl suite [flags] | benchctl report DIR")
	os.Exit(2)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// cpusetSize counts the CPUs in a cpuset list like "8-15,20-27".
func cpusetSize(set string) int {
	n := 0
	for _, part := range strings.Split(set, ",") {
		lo, hi, ok := strings.Cut(part, "-")
		a, _ := strconv.Atoi(lo)
		b := a
		if ok {
			b, _ = strconv.Atoi(hi)
		}
		n += b - a + 1
	}
	return n
}

var allServers = "anole,fiber,gohttp,axum,express,fastify,fastapi,nginx"
var allScenarios = []string{"raw", "conns", "latency", "twelve", "ws", "mem", "gc", "video"}

func runSuite(args []string) {
	fs := flag.NewFlagSet("suite", flag.ExitOnError)
	profile := fs.String("profile", "quick", "quick or full")
	tiers := fs.String("tiers", "1,4", "tiers to run (1 and/or 4 CPUs)")
	only := fs.String("only", strings.Join(allScenarios, ","), "scenarios")
	servers := fs.String("servers", allServers, "servers")
	out := fs.String("out", "", "results directory")
	prior := fs.String("prior", "", "comma-separated cases.jsonl files from earlier runs (max req/s for latency rates)")
	fs.Parse(args)
	if *out == "" {
		log.Fatal("-out is required")
	}
	p, ok := suite.Profiles[*profile]
	if !ok {
		log.Fatalf("unknown profile %s", *profile)
	}
	var ts []sut.Tier
	for _, t := range strings.Split(*tiers, ",") {
		switch t {
		case "1":
			ts = append(ts, sut.Tier{Name: "1cpu", CPUs: 1, Cpuset: env("SUT_CPUS_1", "2"), MemMB: 2048, PGPool: 20})
		case "4":
			ts = append(ts, sut.Tier{Name: "4cpu", CPUs: 4, Cpuset: env("SUT_CPUS_4", "0,2,4,6"), MemMB: 8192, PGPool: 40})
		default:
			log.Fatalf("unknown tier %s", t)
		}
	}
	cfg := sut.Config{HostBenchDir: env("BENCH_HOST_DIR", ""), CgroupRoot: env("HOST_CGROUP", "/host/cgroup")}
	if cfg.HostBenchDir == "" {
		log.Fatal("BENCH_HOST_DIR is not set (run through bench/suite.sh)")
	}
	s, err := suite.New(cfg, "/bench", *out, p, strings.Split(*servers, ","), ts, cpusetSize(env("LOAD_CPUS", "8-15,20-27")))
	if err != nil {
		log.Fatal(err)
	}
	defer s.Close()
	if *prior != "" {
		s.LoadPrior(strings.Split(*prior, ","))
	}
	start := time.Now()
	for _, sc := range strings.Split(*only, ",") {
		t0 := time.Now()
		log.Printf("== %s", sc)
		switch sc {
		case "raw":
			s.Raw()
		case "conns":
			s.Conns()
		case "latency":
			s.Latency()
		case "ws":
			s.WebSockets()
		case "mem":
			s.Memory()
		case "gc":
			s.GC()
		case "video":
			s.Video()
		case "twelve":
			s.Twelve(env("PG_CPUS_TWELVE", "16-27"), env("PG_CPUS", "16-19"))
		default:
			log.Printf("unknown scenario %s (skipped)", sc)
		}
		log.Printf("== %s took %s", sc, time.Since(t0).Round(time.Second))
	}
	sut.Stop()
	log.Printf("suite took %s", time.Since(start).Round(time.Second))
	if err := report.Write(*out); err != nil {
		log.Print(err)
	}
	log.Printf("report: %s", filepath.Join(*out, "report.md"))
}
