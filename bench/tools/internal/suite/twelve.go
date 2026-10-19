package suite

import (
	"fmt"
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
			}
			fail := func(err error) {
				s.record(Case{Scenario: "twelve", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Error: err.Error()})
			}
			// Correctness first, on its own fresh database.
			if err := resetDB(); err != nil {
				fail(err)
				continue
			}
			srv, err := sut.Start(s.Cfg, name, "h1", tier, env, 0)
			if err != nil {
				fail(err)
				continue
			}
			golden := exec.Command("bash", filepath.Join(s.BenchDir, "twelve", "test.sh"), "http://127.0.0.1:8080")
			golden.Env = append(golden.Environ(), "GOLDEN="+filepath.Join(s.BenchDir, "twelve", "golden"))
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
			srv, err = sut.Start(s.Cfg, name, "h1", tier, env, 0)
			if err != nil {
				fail(err)
				continue
			}
			d := &twelve.Driver{Base: "http://127.0.0.1:8080", Tokens: tokens, SourceIPs: 8}
			steps := []twelve.Step{{Users: 1000, Ramp: ramp, Hold: warm}}
			for _, u := range twelveSteps {
				steps = append(steps, twelve.Step{Users: u, Ramp: ramp, Hold: hold})
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
			u := smp.Stop()
			lu := self.Stop()
			score := 0
			for i, w := range windows {
				c := Case{Scenario: "twelve", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name,
					Param: fmt.Sprintf("users=%d", w.Users),
					Load: load.Result{Tool: "benchctl vu", Requests: int64(w.Requests), RPS: w.RPS, Errors: int64(w.Failed),
						P50MS: w.P50MS, P95MS: w.P95MS, P99MS: w.P99MS, MaxMS: w.MaxMS},
					SUT: windowUsage(u, w.Start, w.End), LoadCPU: lu.CPU}
				if i == 0 {
					c.Param = "warmup"
				} else if w.Pass() {
					score = w.Users
				} else {
					c.Note = "failed the thresholds"
				}
				if n := s.note(srv, 0); n != "" {
					c.Note = strings.TrimPrefix(c.Note+"; "+n, "; ")
				}
				s.record(c)
			}
			s.record(Case{Scenario: "twelve", Server: name, Mode: "h1", Proto: "h1", Tier: tier.Name, Param: "score",
				Load: load.Result{Tool: "benchctl vu", Requests: int64(score)}, SUT: sut.Usage{MemMB: u.MemMB, CoresBusy: u.CoresBusy}})
			sut.Stop()
		}
	}
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
