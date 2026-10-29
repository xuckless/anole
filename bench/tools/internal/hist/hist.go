// Package hist is a log-linear latency histogram for the load tools.
package hist

import "math/bits"

// Hist is a log-linear histogram of nanoseconds: 32 sub-buckets per power
// of two (about 3% resolution).
type Hist [64 * 32]uint64

func (h *Hist) Add(ns int64) {
	v := uint64(max(ns, 1))
	e := 63 - bits.LeadingZeros64(v)
	var i int
	if e < 5 {
		i = int(v)
	} else {
		i = (e-4)*32 + int(v>>(e-5)&31)
	}
	h[min(i, len(h)-1)]++
}

func lower(i int) float64 {
	if i < 32 {
		return float64(i)
	}
	e := i/32 + 4
	return float64(uint64(32+i%32) << (e - 5))
}

func (h *Hist) Merge(o *Hist) {
	for i := range h {
		h[i] += o[i]
	}
}

func (h *Hist) Pct(p float64) float64 { // milliseconds
	var n uint64
	for _, c := range h {
		n += c
	}
	if n == 0 {
		return 0
	}
	want := uint64(p*float64(n)) + 1
	var s uint64
	for i, c := range h {
		s += c
		if s >= min(want, n) {
			return lower(i) / 1e6
		}
	}
	return 0
}
