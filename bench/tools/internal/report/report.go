// Package report turns a run's cases.jsonl into report.md.
package report

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/xuckless/anole/bench/tools/internal/suite"
)

var serverOrder = []string{"anole", "fiber", "gohttp", "axum", "express", "fastify", "fastapi", "nginx"}
var protoOrder = []string{"h1", "h1-tls", "h2c", "h2-tls", "h3"}

func rank(order []string, s string) int {
	for i, v := range order {
		if v == s {
			return i
		}
	}
	return len(order)
}

func Read(dir string) ([]suite.Case, error) {
	f, err := os.Open(filepath.Join(dir, "cases.jsonl"))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var cases []suite.Case
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 16<<20)
	for sc.Scan() {
		var c suite.Case
		if json.Unmarshal(sc.Bytes(), &c) == nil {
			cases = append(cases, c)
		}
	}
	// A later case for the same key replaces an earlier one (re-runs).
	latest := map[string]int{}
	for i, c := range cases {
		latest[key(c)] = i
	}
	var out []suite.Case
	for i, c := range cases {
		if latest[key(c)] == i {
			out = append(out, c)
		}
	}
	return out, nil
}

func key(c suite.Case) string {
	return strings.Join([]string{c.Scenario, c.Server, c.Mode, c.Proto, c.Tier, c.Endpoint, c.Param}, "|")
}

type doc struct {
	strings.Builder
	notes []string
}

func (d *doc) note(c suite.Case) string {
	text := c.Note
	if c.Error != "" {
		text = "error: " + firstLine(c.Error)
	}
	if text == "" {
		return ""
	}
	d.notes = append(d.notes, fmt.Sprintf("%s %s %s %s %s %s: %s", c.Scenario, c.Server, c.Tier, c.Proto, c.Endpoint, c.Param, text))
	return fmt.Sprintf(" [%d]", len(d.notes))
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:200] + "..."
	}
	return s
}

func num(f float64) string {
	s := fmt.Sprintf("%.0f", f)
	var b strings.Builder
	for i, ch := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(ch)
	}
	return b.String()
}

func uniq(cases []suite.Case, f func(suite.Case) string, order []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, c := range cases {
		v := f(c)
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		ri, rj := rank(order, out[i]), rank(order, out[j])
		if ri != rj {
			return ri < rj
		}
		return out[i] < out[j]
	})
	return out
}

func filter(cases []suite.Case, f func(suite.Case) bool) []suite.Case {
	var out []suite.Case
	for _, c := range cases {
		if f(c) {
			out = append(out, c)
		}
	}
	return out
}

func Write(dir string) error {
	cases, err := Read(dir)
	if err != nil {
		return err
	}
	var d doc
	d.WriteString("# Benchmark report\n\n")
	if env, err := os.ReadFile(filepath.Join(dir, "env.json")); err == nil {
		d.WriteString("Environment: see `env.json`.\n\n```json\n" + string(env) + "\n```\n\n")
	}
	raw(&d, filter(cases, func(c suite.Case) bool { return c.Scenario == "raw" }))
	conns(&d, filter(cases, func(c suite.Case) bool { return c.Scenario == "conns" }))
	latency(&d, filter(cases, func(c suite.Case) bool { return c.Scenario == "latency" }))
	if len(d.notes) > 0 {
		d.WriteString("## Notes\n\n")
		for i, n := range d.notes {
			fmt.Fprintf(&d, "%d. %s\n", i+1, n)
		}
	}
	return os.WriteFile(filepath.Join(dir, "report.md"), []byte(d.String()), 0o644)
}

func raw(d *doc, cases []suite.Case) {
	if len(cases) == 0 {
		return
	}
	d.WriteString("## Max throughput (closed loop)\n\n")
	d.WriteString("Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.\n\n")
	for _, tier := range uniq(cases, func(c suite.Case) string { return c.Tier }, []string{"1cpu", "4cpu"}) {
		for _, ep := range uniq(cases, func(c suite.Case) string { return c.Endpoint }, []string{"/plaintext", "/json", "/list"}) {
			sub := filter(cases, func(c suite.Case) bool { return c.Tier == tier && c.Endpoint == ep })
			protos := uniq(sub, func(c suite.Case) string { return c.Proto }, protoOrder)
			protos = filter2(protos)
			fmt.Fprintf(d, "### %s, GET %s\n\n| Server |", tier, ep)
			for _, p := range protos {
				fmt.Fprintf(d, " %s |", p)
			}
			d.WriteString("\n| --- |" + strings.Repeat(" ---: |", len(protos)) + "\n")
			for _, srv := range uniq(sub, func(c suite.Case) string { return c.Server }, serverOrder) {
				fmt.Fprintf(d, "| %s |", srv)
				for _, p := range protos {
					cell := "N/A"
					for _, c := range sub {
						if c.Server == srv && c.Proto == p {
							cell = rawCell(d, c)
						}
					}
					fmt.Fprintf(d, " %s |", cell)
				}
				d.WriteString("\n")
			}
			d.WriteString("\n")
		}
	}
}

func filter2(xs []string) []string {
	var out []string
	for _, x := range xs {
		if x != "" {
			out = append(out, x)
		}
	}
	return out
}

func rawCell(d *doc, c suite.Case) string {
	if c.Error != "" {
		return "fail" + d.note(c)
	}
	lat := fmt.Sprintf("p99 %.2f ms", c.Load.P99MS)
	if c.Load.P99MS == 0 {
		lat = fmt.Sprintf("mean %.2f ms", c.Load.MeanMS)
	}
	return fmt.Sprintf("**%s** %s [%.0f MB, %.2f]%s", num(c.Load.RPS), lat, c.SUT.MemMB, c.SUT.CoresBusy, d.note(c))
}

func conns(d *doc, cases []suite.Case) {
	if len(cases) == 0 {
		return
	}
	d.WriteString("## Concurrent connections (HTTP/1.1 keep-alive, GET /json)\n\n")
	d.WriteString("req/s / p99 ms / server memory MB at each connection count.\n\n")
	params := uniq(cases, func(c suite.Case) string { return c.Param }, nil)
	sort.Slice(params, func(i, j int) bool { return paramN(params[i]) < paramN(params[j]) })
	for _, tier := range uniq(cases, func(c suite.Case) string { return c.Tier }, nil) {
		sub := filter(cases, func(c suite.Case) bool { return c.Tier == tier })
		fmt.Fprintf(d, "### %s\n\n| Server |", tier)
		for _, p := range params {
			fmt.Fprintf(d, " %s |", p)
		}
		d.WriteString("\n| --- |" + strings.Repeat(" ---: |", len(params)) + "\n")
		for _, srv := range uniq(sub, func(c suite.Case) string { return c.Server }, serverOrder) {
			fmt.Fprintf(d, "| %s |", srv)
			for _, p := range params {
				cell := "-"
				for _, c := range sub {
					if c.Server == srv && c.Param == p {
						if c.Error != "" {
							cell = "fail" + d.note(c)
						} else {
							cell = fmt.Sprintf("%s / %.1f / %.0f%s", num(c.Load.RPS), c.Load.P99MS, c.SUT.MemMB, d.note(c))
						}
					}
				}
				fmt.Fprintf(d, " %s |", cell)
			}
			d.WriteString("\n")
		}
		d.WriteString("\n")
	}
}

func paramN(p string) int {
	var n int
	fmt.Sscanf(strings.TrimPrefix(p, "c="), "%d", &n)
	return n
}

func latency(d *doc, cases []suite.Case) {
	if len(cases) == 0 {
		return
	}
	d.WriteString("## Latency at fixed request rates (open loop, GET /json)\n\n")
	d.WriteString("oha with `--latency-correction` (coordinated omission accounted for), 64 connections. p50 / p99 / p99.9 in ms; a rate a server could not sustain is marked in the notes.\n\n")
	d.WriteString("| Server | Proto | Rate | Achieved req/s | p50 | p99 | p99.9 | max | Memory MB | CPU |\n| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n")
	sort.SliceStable(cases, func(i, j int) bool {
		a, b := cases[i], cases[j]
		if a.Server != b.Server {
			return rank(serverOrder, a.Server) < rank(serverOrder, b.Server)
		}
		if a.Proto != b.Proto {
			return rank(protoOrder, a.Proto) < rank(protoOrder, b.Proto)
		}
		return a.Load.RPS < b.Load.RPS
	})
	for _, c := range cases {
		if c.Error != "" {
			fmt.Fprintf(d, "| %s | %s | %s | fail%s | | | | | | |\n", c.Server, c.Proto, c.Param, d.note(c))
			continue
		}
		fmt.Fprintf(d, "| %s | %s | %s | %s%s | %.2f | %.2f | %.2f | %.1f | %.0f | %.2f |\n", c.Server, c.Proto, c.Param,
			num(c.Load.RPS), d.note(c), c.Load.P50MS, c.Load.P99MS, c.Load.P999MS, c.Load.MaxMS, c.SUT.MemMB, c.SUT.CPU)
	}
	d.WriteString("\n")
}
