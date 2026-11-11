package main

import "time"

// Window keeps the largest number of events seen in any 1 s sliding window,
// as ten 100 ms buckets: the window is the current (partial) bucket plus the
// nine before it, so it spans 0.9 to 1.0 s and the peak can under-count by
// at most one bucket. It also keeps the largest single bucket. O(1) per event.
// The clock is passed in (a monotonic offset), which keeps tests free of sleeps.
type Window struct {
	b       [nBuckets]int64
	cur     int64
	started bool
	Peak    int64 // most events in any 1 s window
	Peak100 int64 // most events in any 100 ms bucket
}

const (
	nBuckets = 10
	bucketW  = 100 * time.Millisecond
)

func (w *Window) Add(now time.Duration, n int64) {
	abs := int64(now / bucketW)
	if !w.started {
		w.cur, w.started = abs, true
	}
	if abs > w.cur { // a clock that goes backwards just counts into the current bucket
		if gap := abs - w.cur; gap >= nBuckets {
			w.b = [nBuckets]int64{}
		} else {
			for i := int64(1); i <= gap; i++ {
				w.b[(w.cur+i)%nBuckets] = 0
			}
		}
		w.cur = abs
	}
	w.b[w.cur%nBuckets] += n
	var sum int64
	for _, v := range w.b {
		sum += v
	}
	w.Peak = max(w.Peak, sum)
	w.Peak100 = max(w.Peak100, w.b[w.cur%nBuckets])
}
