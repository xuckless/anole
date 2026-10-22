package suite

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/xuckless/anole/bench/tools/internal/load"
	"github.com/xuckless/anole/bench/tools/internal/sut"
	"github.com/xuckless/anole/bench/tools/internal/twelve"
)

const pgContainer = "anole-bench-pg"

// pg runs SQL in the shared Postgres as user bench.
func pg(db string, sql ...string) error {
	args := []string{"exec", pgContainer, "psql", "-v", "ON_ERROR_STOP=1", "-qAt", "-U", "bench", "-d", db}
	for _, s := range sql {
		args = append(args, "-c", s)
	}
	out, err := exec.Command("docker", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("psql: %v: %s", err, out)
	}
	return nil
}

// twelveSecret replaces the challenge's HS256 secret ("twelve-dollar-challenge",
// 23 bytes) for every server: RFC 7518 3.2 asks for at least 32, and Anole's
// JWT verification refuses shorter ones (since 0.1.0). bench/postgres/run.sh
// signs tokens.json with the same secret.
const twelveSecret = "twelve-dollar-challenge-hs256-32-byte-key"

// resetDB makes a fresh "run" database from the seed template.
func resetDB() error {
	if err := pg("postgres", "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'run'"); err != nil {
		return err
	}
	return pg("postgres", "DROP DATABASE IF EXISTS run", "CREATE DATABASE run TEMPLATE seed")
}

// pgCpuset re-pins the Postgres container (it gets more cores while the $12
// test runs, so the frameworks rather than the database set the score).
func pgCpuset(set string) error {
	out, err := exec.Command("docker", "update", "--cpuset-cpus", set, pgContainer).CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker update: %v: %s", err, out)
	}
	return nil
}

// TwelveSteps: users per step for the quick search; a step's window must
// pass the challenge's thresholds for the next one to run.
var twelveSteps = []int{2500, 5000, 10000, 15000, 20000, 25000, 30000, 40000, 50000, 60000, 80000, 100000}

// Twelve: the $12 challenge on Postgres. Each server is first checked with
// the challenge's golden tests on a fresh database, then driven with
// load.js's users in rising steps until a step fails p95 < 500 ms,
// p99 < 1 s, < 1% errors. The score is the last step that passed.
func (s *Suite) Twelve(pgCPUs, pgCPUsDefault string) {
	tokens, err := twelve.LoadTokens(filepath.Join(s.BenchDir, ".data", "seed", "tokens.json"))
	if err != nil {
		s.record(Case{Scenario: "twelve", Error: "tokens: " + err.Error()})
		return
	}
	if err := pgCpuset(pgCPUs); err != nil {
		s.record(Case{Scenario: "twelve", Error: err.Error()})
		return
	}
	defer pgCpuset(pgCPUsDefault)

	warm, ramp, hold := 60*time.Second, 20*time.Second, 40*time.Second
	if s.Profile.Name == "full" {
		warm, ramp, hold = 120*time.Second, 60*time.Second, 5*time.Minute
	}
	for _, tier := range s.Tiers {
		for _, name := range s.Servers {
			if s.manifests[name].Twelve == "" {
				continue
			}
			env := map[string]string{
				"DATABASE_URL": "postgres://bench@127.0.0.1:5432/run",
				"PG_POOL":      fmt.Sprint(tier.PGPool),
				"JWT_SECRET":   twelveSecret,
			}
			fail := func(err error) {
				s.record(Case{Scenario: "twelve", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Error: err.Error()})
			}
			var lo, hi int
			var u sut.Usage
			if s.TwelveBrackets != nil {
				// Refining an earlier run: only the bisection, between the
				// last step that passed and the first that failed.
				b, ok := s.TwelveBrackets[tier.Name+"|"+name]
				if !ok {
					continue
				}
				lo, hi = b[0], b[1]
			} else {
				// Correctness first, on its own fresh database.
				if err := resetDB(); err != nil {
					fail(err)
					continue
				}
				if _, err := sut.Start(s.Cfg, name, "h1", tier, env, 0); err != nil {
					fail(err)
					continue
				}
				golden := exec.Command("bash", filepath.Join(s.BenchDir, "twelve", "test.sh"), "http://127.0.0.1:8080")
				golden.Env = append(golden.Environ(), "GOLDEN="+filepath.Join(s.BenchDir, "twelve", "golden"), "JWT_SECRET="+twelveSecret)
				out, err := golden.CombinedOutput()
				sut.Stop()
				if err != nil {
					fail(fmt.Errorf("golden tests failed: %s", lastLines(string(out), 6)))
					continue
				}

				if err := resetDB(); err != nil {
					fail(err)
					continue
				}
				srv, err := sut.Start(s.Cfg, name, "h1", tier, env, 0)
				if err != nil {
					fail(err)
					continue
				}
				d := &twelve.Driver{Base: "http://127.0.0.1:8080", Tokens: tokens, SourceIPs: 8}
				steps := []twelve.Step{{Users: 1000, Ramp: ramp, Hold: warm}}
				for _, n := range twelveSteps {
					steps = append(steps, twelve.Step{Users: n, Ramp: ramp, Hold: hold})
				}
				smp := srv.Sample(time.Second, true)
				self := sut.StartSampler("/sys/fs/cgroup", time.Second, false)
				first := true
				windows := d.Run(steps, func(w twelve.Window) bool {
					if first { // the warm-up step is not scored
						first = false
						return false
					}
					exited, _ := srv.Exited()
					return exited || !w.Pass()
				})
				u = smp.Stop()
				lu := self.Stop()
				for i, w := range windows {
					c := s.twelveCase(name, tier, w, u, lu.CPU)
					if i == 0 {
						c.Param = "warmup"
					} else if w.Pass() {
						lo = w.Users
					} else {
						hi = w.Users
					}
					// The server's fate (an OOM kill, an exit) belongs to the
					// window it ended in, not to every window before it.
					if i == len(windows)-1 {
						if n := s.note(srv, 0); n != "" {
							c.Note = strings.TrimPrefix(c.Note+"; "+n, "; ")
						}
					}
					s.record(c)
				}
				sut.Stop()
			}

			// Bisect between the last window that passed and the first that
			// failed, each probe on a fresh server and database (the failure
			// may have been an OOM kill), until the bracket is within 5%.
			for hi > 0 && hi-lo > max(1000, lo/20) {
				mid := (lo + hi) / 2
				mid -= mid % 250
				_, pu, ok := s.twelveProbe(name, tier, env, tokens, mid, ramp, hold)
				if ok {
					lo = mid
					u = pu
				} else {
					hi = mid
				}
			}
			s.record(Case{Scenario: "twelve", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Param: "score",
				Load: load.Result{Tool: "benchctl vu", Requests: int64(lo)}, SUT: sut.Usage{MemMB: u.MemMB, CoresBusy: u.CoresBusy},
				Note: fmt.Sprintf("passed %d users, failed %d", lo, hi)})
		}
	}
}

// twelveCase is a scored window as a case.
func (s *Suite) twelveCase(name string, tier sut.Tier, w twelve.Window, u sut.Usage, loadCPU float64) Case {
	c := Case{Scenario: "twelve", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name,
		Param: fmt.Sprintf("users=%d", w.Users),
		Load: load.Result{Tool: "benchctl vu", Requests: int64(w.Requests), RPS: w.RPS, Errors: int64(w.Failed),
			P50MS: w.P50MS, P95MS: w.P95MS, P99MS: w.P99MS, MaxMS: w.MaxMS},
		SUT: windowUsage(u, w.Start, w.End), LoadCPU: loadCPU}
	if !w.Pass() {
		c.Note = "failed the thresholds"
	}
	return c
}

// twelveProbe runs one bisection probe: a fresh database and server, a
// short warm-up at 1 000 users, a ramp to users at no more than 1 000 new
// users a second, and one scored window. It records the window and says
// whether it passed.
func (s *Suite) twelveProbe(name string, tier sut.Tier, env map[string]string, tokens []twelve.Token, users int, ramp, hold time.Duration) (twelve.Window, sut.Usage, bool) {
	fail := func(err error) {
		s.record(Case{Scenario: "twelve", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name,
			Param: fmt.Sprintf("users=%d (bisect)", users), Error: err.Error()})
	}
	if err := resetDB(); err != nil {
		fail(err)
		return twelve.Window{}, sut.Usage{}, false
	}
	srv, err := sut.Start(s.Cfg, name, "h1", tier, env, 0)
	if err != nil {
		fail(err)
		return twelve.Window{}, sut.Usage{}, false
	}
	defer sut.Stop()
	d := &twelve.Driver{Base: "http://127.0.0.1:8080", Tokens: tokens, SourceIPs: 8}
	up := max(ramp, time.Duration(users-1000)*time.Millisecond)
	smp := srv.Sample(time.Second, true)
	self := sut.StartSampler("/sys/fs/cgroup", time.Second, false)
	windows := d.Run([]twelve.Step{{Users: 1000, Ramp: ramp, Hold: 30 * time.Second}, {Users: users, Ramp: up, Hold: hold}},
		func(twelve.Window) bool { return false })
	u := smp.Stop()
	lu := self.Stop()
	if len(windows) < 2 {
		fail(fmt.Errorf("no window at %d users", users))
		return twelve.Window{}, u, false
	}
	w := windows[len(windows)-1]
	c := s.twelveCase(name, tier, w, u, lu.CPU)
	c.Param = fmt.Sprintf("users=%d (bisect)", users)
	exited, _ := srv.Exited()
	if n := s.note(srv, 0); n != "" {
		c.Note = strings.TrimPrefix(c.Note+"; "+n, "; ")
	}
	s.record(c)
	return w, u, w.Pass() && !exited && srv.OOMEvents() == 0
}

// windowUsage is the peak memory and mean CPU of the samples in [from, to).
func windowUsage(u sut.Usage, from, to float64) sut.Usage {
	var w sut.Usage
	n := 0
	for _, sm := range u.Samples {
		if sm.T < from || sm.T >= to {
			continue
		}
		if sm.MemMB > w.MemMB {
			w.MemMB = sm.MemMB
		}
		w.CPU += sm.CPU
		w.CoresBusy += sm.Busy
		n++
	}
	if n > 0 {
		w.CPU /= float64(n)
		w.CoresBusy /= float64(n)
	}
	return w
}

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, " | ")
}

// LoadTwelveBrackets reads an earlier $12 run's windows and keeps, per tier
// and server, the most users that passed and the fewest that failed, for
// servers that failed somewhere (one that passed every step has no bracket).
// A bisection probe that ended with the server gone counts as failed.
func (s *Suite) LoadTwelveBrackets(path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	lo, hi := map[string]int{}, map[string]int{}
	for _, line := range strings.Split(string(b), "\n") {
		var c Case
		if json.Unmarshal([]byte(line), &c) != nil || c.Scenario != "twelve" || c.Error != "" {
			continue
		}
		var users int
		if _, err := fmt.Sscanf(c.Param, "users=%d", &users); err != nil {
			continue
		}
		k := c.Tier + "|" + c.Server
		failed := strings.Contains(c.Note, "failed the thresholds") ||
			(strings.HasSuffix(c.Param, "(bisect)") && (strings.Contains(c.Note, "server ") || strings.Contains(c.Note, "OOM")))
		if failed {
			if hi[k] == 0 || users < hi[k] {
				hi[k] = users
			}
		} else if users > lo[k] {
			lo[k] = users
		}
	}
	s.TwelveBrackets = map[string][2]int{}
	for k, h := range hi {
		s.TwelveBrackets[k] = [2]int{min(lo[k], h), h}
	}
	return nil
}
