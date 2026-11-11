package main

import (
	"testing"
	"time"
)

func TestWindowPeaks(t *testing.T) {
	ms := func(n int) time.Duration { return time.Duration(n) * time.Millisecond }
	var w Window
	w.Add(ms(10), 50) // one bucket
	w.Add(ms(150), 50)
	if w.Peak != 100 || w.Peak100 != 50 {
		t.Fatalf("peak %d/%d, want 100/50", w.Peak, w.Peak100)
	}
	// Events 1 s apart are not in one window.
	var v Window
	v.Add(ms(0), 50)
	v.Add(ms(1000), 50)
	if v.Peak != 50 {
		t.Errorf("1 s apart: peak %d, want 50", v.Peak)
	}
	// A burst straddling a bucket boundary is in one window.
	var s Window
	s.Add(ms(950), 50)
	s.Add(ms(1050), 50)
	if s.Peak != 100 {
		t.Errorf("straddling: peak %d, want 100", s.Peak)
	}
	// A long gap forgets everything; a clock that steps back counts into the current bucket.
	var g Window
	g.Add(ms(0), 10)
	g.Add(ms(60_000), 1)
	g.Add(ms(59_000), 1)
	if g.Peak != 10 || g.b[g.cur%nBuckets] != 2 {
		t.Errorf("gap/backwards: peak %d bucket %d", g.Peak, g.b[g.cur%nBuckets])
	}
}
