// Package sut starts the server under test in its pinned, memory-capped
// container and samples its cgroup while a case runs.
package sut

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Tier is one resource budget: the cpuset the container is pinned to, the
// CPU count it is told about (WORKERS) and its memory cap (no swap).
type Tier struct {
	Name   string `json:"name"`
	CPUs   int    `json:"cpus"`
	Cpuset string `json:"cpuset"`
	MemMB  int    `json:"mem_mb"`
	PGPool int    `json:"pg_pool"`
}

// Manifest is bench/servers/<name>/manifest.json.
type Manifest struct {
	Name    string            `json:"name"`
	Label   string            `json:"label"`
	Modes   map[string]string `json:"modes"`
	TLSALPN []string          `json:"tls_alpn"`
	WS      string            `json:"ws"`
	WSH2    bool              `json:"ws_h2"`
	GRPC    string            `json:"grpc"`
	Twelve  string            `json:"twelve"`
	Static  string            `json:"static"`
	// WebTransport (draft-02) at /wt/echo in MODE=h3, and with what.
	WebTransport string `json:"webtransport"`
	// Ready is how to tell the server is up when it is not by GET
	// /plaintext: "wt" opens one WebTransport session.
	Ready string `json:"ready"`
	// Scenarios, when set, are the only scenarios the server takes part in
	// (the <name>-wt servers serve WebTransport and nothing else).
	Scenarios []string `json:"scenarios"`
}

// In reports whether the server takes part in scenario sc.
func (m Manifest) In(sc string) bool {
	return len(m.Scenarios) == 0 || slices.Contains(m.Scenarios, sc)
}

// Image is the Docker image for a server name: "anole" is anole-bench/anole,
// "anole@after" the tag anole-bench/anole:after (for before/after runs).
func Image(name string) string {
	if base, tag, ok := strings.Cut(name, "@"); ok {
		return "anole-bench/" + base + ":" + tag
	}
	return "anole-bench/" + name
}

func LoadManifest(benchDir, name string) (Manifest, error) {
	name, _, _ = strings.Cut(name, "@")
	var m Manifest
	b, err := os.ReadFile(filepath.Join(benchDir, "servers", name, "manifest.json"))
	if err != nil {
		return m, err
	}
	err = json.Unmarshal(b, &m)
	return m, err
}

func (m Manifest) Supports(mode string) bool {
	if mode == "grpc" {
		return m.GRPC != ""
	}
	_, ok := m.Modes[mode]
	return ok
}

// Config is what the suite knows about the host.
type Config struct {
	// HostBenchDir is bench/ as the Docker daemon sees it (for bind mounts).
	HostBenchDir string
	// CgroupRoot is the host's /sys/fs/cgroup as mounted here.
	CgroupRoot string
	// BenchDir is bench/ here, for the servers' manifests.
	BenchDir string
}

// Server is a running server container.
type Server struct {
	Name   string
	Mode   string
	ready  string
	Tier   Tier
	ID     string
	cgroup string
}

const containerName = "anole-bench-sut"

// Start runs anole-bench/<name> in MODE=mode on the tier's budget, with the
// extra environment given, and waits until it answers.
func Start(cfg Config, name, mode string, tier Tier, env map[string]string, memMB int) (*Server, error) {
	Stop()
	if memMB == 0 {
		memMB = tier.MemMB
	}
	args := []string{"run", "-d", "--name", containerName, "--network", "host",
		"--cpuset-cpus", tier.Cpuset, "--cpus", strconv.Itoa(tier.CPUs),
		"--memory", fmt.Sprintf("%dm", memMB), "--memory-swap", fmt.Sprintf("%dm", memMB),
		"--ulimit", "nofile=1048576:1048576",
		"-v", cfg.HostBenchDir + "/.data/certs:/certs:ro,z",
		"-v", cfg.HostBenchDir + "/.data/media:/media:ro,z",
		"-e", "MODE=" + mode, "-e", "WORKERS=" + strconv.Itoa(tier.CPUs),
	}
	for k, v := range env {
		args = append(args, "-e", k+"="+v)
	}
	args = append(args, Image(name))
	out, err := exec.Command("docker", args...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("docker run %s: %v: %s", name, err, out)
	}
	m, _ := LoadManifest(cfg.BenchDir, name)
	s := &Server{Name: name, Mode: mode, ready: m.Ready, Tier: tier, ID: strings.TrimSpace(string(out))}
	s.cgroup = filepath.Join(cfg.CgroupRoot, "system.slice", "docker-"+s.ID+".scope")
	if err := s.waitReady(60 * time.Second); err != nil {
		logs, _ := exec.Command("docker", "logs", "--tail", "30", containerName).CombinedOutput()
		Stop()
		return nil, fmt.Errorf("%s %s not ready: %v\n%s", name, mode, err, logs)
	}
	return s, nil
}

// Stop removes the server container, if any.
func Stop() {
	exec.Command("docker", "rm", "-f", containerName).Run()
}

// Exited reports whether the container stopped (an OOM kill, a crash).
func (s *Server) Exited() (bool, string) {
	out, err := exec.Command("docker", "inspect", "-f", "{{.State.Running}} {{.State.OOMKilled}} {{.State.ExitCode}}", s.ID).Output()
	if err != nil {
		return true, "gone"
	}
	f := strings.Fields(string(out))
	if len(f) == 3 && f[0] == "false" {
		if f[1] == "true" {
			return true, "oom-killed"
		}
		return true, "exited " + f[2]
	}
	return false, ""
}

// OOMEvents is the cgroup's oom_kill count (a kill of any process in it).
func (s *Server) OOMEvents() int {
	return int(readKV(filepath.Join(s.cgroup, "memory.events"))["oom_kill"])
}

func (s *Server) waitReady(limit time.Duration) error {
	deadline := time.Now().Add(limit)
	var last error
	for time.Now().Before(deadline) {
		if exited, why := s.Exited(); exited {
			return fmt.Errorf("container %s", why)
		}
		last = probe(s.Mode, s.ready)
		if last == nil {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return last
}

// URL is the base URL of the mode's listener.
func URL(mode string) string {
	switch mode {
	case "tls", "h3":
		return "https://127.0.0.1:8443"
	default:
		return "http://127.0.0.1:8080"
	}
}

func probe(mode, ready string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if ready == "wt" {
		return exec.CommandContext(ctx, "wtload", "-url", URL(mode)+"/wt/echo", "-mode", "sessions", "-n", "1", "-c", "1", "-timeout", "2s").Run()
	}
	var args []string
	switch mode {
	case "grpc":
		c, err := net.DialTimeout("tcp", "127.0.0.1:50051", time.Second)
		if err == nil {
			c.Close()
		}
		return err
	case "h2c":
		args = []string{"--http2-prior-knowledge"}
	case "tls":
		args = []string{"-k"}
	case "h3":
		args = []string{"-k", "--http3-only"}
	}
	args = append(args, "-sf", "-o", "/dev/null", URL(mode)+"/plaintext")
	return exec.CommandContext(ctx, "curl", args...).Run()
}

// Usage is what a sampler saw over one case.
type Usage struct {
	// CPU: average cores busy (1.0 = one core flat out).
	CPU float64 `json:"cpu"`
	// MemMB: peak of anon + kernel memory (no page cache) over the case.
	MemMB float64 `json:"mem_mb"`
	// MemAvgMB: its average.
	MemAvgMB float64 `json:"mem_avg_mb"`
	// CurrentPeakMB: peak of memory.current (page cache included).
	CurrentPeakMB float64 `json:"current_peak_mb"`
	// CoresBusy: how busy the server's cpuset was (from /proc/stat), in
	// cores. It includes the kernel's softirq network work, which no cgroup
	// is charged for (on loopback it is a large share), so it is the
	// number that says whether the server's CPUs were saturated.
	CoresBusy float64  `json:"cores_busy"`
	Samples   []Sample `json:"samples,omitempty"`
}

type Sample struct {
	T     float64 `json:"t"`
	MemMB float64 `json:"mem_mb"`
	CPU   float64 `json:"cpu"`
	Busy  float64 `json:"busy,omitempty"`
}

// Sampler reads a cgroup every interval until Stop.
type Sampler struct {
	dir      string
	cpus     []int
	interval time.Duration
	keep     bool
	done     chan struct{}
	wg       sync.WaitGroup
	u        Usage
}

// Sample starts sampling the server's cgroup; keep stores every sample
// (for the time-series plots of the memory and GC tests).
func (s *Server) Sample(interval time.Duration, keep bool) *Sampler {
	sm := newSampler(s.cgroup, interval, keep)
	sm.cpus = parseCpuset(s.Tier.Cpuset)
	sm.start()
	return sm
}

// StartSampler samples any cgroup directory (the load generator's own,
// "/sys/fs/cgroup" inside its container).
func StartSampler(dir string, interval time.Duration, keep bool) *Sampler {
	sm := newSampler(dir, interval, keep)
	sm.start()
	return sm
}

func newSampler(dir string, interval time.Duration, keep bool) *Sampler {
	return &Sampler{dir: dir, interval: interval, keep: keep, done: make(chan struct{})}
}

func (sm *Sampler) start() {
	sm.wg.Add(1)
	go sm.loop()
}

func (sm *Sampler) loop() {
	defer sm.wg.Done()
	t0 := time.Now()
	cpu0 := cpuUsec(sm.dir)
	busy0 := busyTicks(sm.cpus)
	prevT, prevCPU, prevBusy := t0, cpu0, busy0
	var memSum float64
	n := 0
	tick := time.NewTicker(sm.interval)
	defer tick.Stop()
	for {
		select {
		case <-sm.done:
			el := time.Since(t0).Seconds()
			if el > 0 {
				sm.u.CPU = float64(cpuUsec(sm.dir)-cpu0) / 1e6 / el
				if len(sm.cpus) > 0 {
					sm.u.CoresBusy = float64(busyTicks(sm.cpus)-busy0) / clockTicks / el
				}
			}
			if n > 0 {
				sm.u.MemAvgMB = memSum / float64(n)
			}
			return
		case now := <-tick.C:
			st := readKV(filepath.Join(sm.dir, "memory.stat"))
			mem := float64(st["anon"]+st["kernel"]) / (1 << 20)
			cur := float64(readInt(filepath.Join(sm.dir, "memory.current"))) / (1 << 20)
			c := cpuUsec(sm.dir)
			b := busyTicks(sm.cpus)
			memSum += mem
			n++
			if mem > sm.u.MemMB {
				sm.u.MemMB = mem
			}
			if cur > sm.u.CurrentPeakMB {
				sm.u.CurrentPeakMB = cur
			}
			if sm.keep {
				sm.u.Samples = append(sm.u.Samples, Sample{
					T:     now.Sub(t0).Seconds(),
					MemMB: mem,
					CPU:   float64(c-prevCPU) / 1e6 / now.Sub(prevT).Seconds(),
					Busy:  float64(b-prevBusy) / clockTicks / now.Sub(prevT).Seconds(),
				})
			}
			prevT, prevCPU, prevBusy = now, c, b
		}
	}
}

func (sm *Sampler) Stop() Usage {
	close(sm.done)
	sm.wg.Wait()
	return sm.u
}

// MemNowMB is anon + kernel memory right now.
func (s *Server) MemNowMB() float64 {
	st := readKV(filepath.Join(s.cgroup, "memory.stat"))
	return float64(st["anon"]+st["kernel"]) / (1 << 20)
}

func cpuUsec(dir string) int64 {
	return readKV(filepath.Join(dir, "cpu.stat"))["usage_usec"]
}

func readKV(path string) map[string]int64 {
	m := map[string]int64{}
	f, err := os.Open(path)
	if err != nil {
		return m
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), " ")
		if !ok {
			continue
		}
		n, _ := strconv.ParseInt(v, 10, 64)
		m[k] = n
	}
	return m
}

func readInt(path string) int64 {
	b, _ := os.ReadFile(path)
	n, _ := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	return n
}

// clockTicks is USER_HZ, the unit of /proc/stat (100 on Linux).
const clockTicks = 100

// busyTicks sums the non-idle time of the given CPUs from /proc/stat.
func busyTicks(cpus []int) int64 {
	if len(cpus) == 0 {
		return 0
	}
	want := map[string]bool{}
	for _, c := range cpus {
		want["cpu"+strconv.Itoa(c)] = true
	}
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0
	}
	var total int64
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) < 9 || !want[f[0]] {
			continue
		}
		// user nice system idle iowait irq softirq steal
		for i, v := range f[1:9] {
			if i == 3 || i == 4 {
				continue
			}
			n, _ := strconv.ParseInt(v, 10, 64)
			total += n
		}
	}
	return total
}

func parseCpuset(set string) []int {
	var out []int
	for _, part := range strings.Split(set, ",") {
		lo, hi, ok := strings.Cut(strings.TrimSpace(part), "-")
		a, err := strconv.Atoi(lo)
		if err != nil {
			continue
		}
		b := a
		if ok {
			b, _ = strconv.Atoi(hi)
		}
		for c := a; c <= b; c++ {
			out = append(out, c)
		}
	}
	return out
}
