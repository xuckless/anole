package main

import (
	"math/rand"
	"reflect"
	"testing"
	"time"
)

func frame(t byte, flags byte, stream uint32, payload []byte) []byte {
	n := len(payload)
	b := []byte{byte(n >> 16), byte(n >> 8), byte(n), t, flags, byte(stream >> 24), byte(stream >> 16), byte(stream >> 8), byte(stream)}
	return append(b, payload...)
}

func sample() []byte {
	var b []byte
	b = append(b, preface...)
	b = append(b, frame(tSettings, 0, 0, []byte{0, 3, 0, 0, 0, 100, 0, 4, 0, 1, 0, 0, 0x1a, 0x1a, 0, 0, 0, 1})...) // 3 entries, one GREASE
	b = append(b, frame(tPing, 0, 0, make([]byte, 8))...)
	b = append(b, frame(tHeaders, fEndHeaders, 1, []byte("abcd"))...)
	b = append(b, frame(tData, 0, 1, nil)...)                      // empty DATA
	b = append(b, frame(tData, fPadded, 1, []byte{3, 0, 0, 0})...) // padded, empty
	b = append(b, frame(tHeaders, 0, 3, []byte("xy"))...)
	b = append(b, frame(tContinue, 0, 3, []byte("zz"))...)
	b = append(b, frame(tContinue, fEndHeaders, 3, []byte("z"))...)
	b = append(b, frame(tRst, 0, 1, []byte{0, 0, 0, 8})...)
	b = append(b, frame(0x10, 0, 0, []byte{1, 2})...)
	b = append(b, frame(tPriority, 0, 3, make([]byte, 5))...)
	b = append(b, frame(tWindowUpdate, 0, 0, []byte{0, 0, 1, 0})...)
	return b
}

func feedAll(chunks func(b []byte) [][]byte) *Conn {
	c := newConn(func() time.Duration { return 0 })
	for _, ch := range chunks(sample()) {
		c.cf.feed(ch)
	}
	return c
}

func totals(c *Conn) map[string]int64 {
	m := map[string]int64{}
	for k, r := range c.Rates {
		m[k] = r.Total
	}
	for k, v := range c.Max {
		m["max:"+k] = v
	}
	return m
}

func TestCounts(t *testing.T) {
	c := feedAll(func(b []byte) [][]byte { return [][]byte{b} })
	want := map[string]int64{
		"frames": 12, "settings": 1, "settings_entries": 3, "ping": 1, "headers": 2, "requests": 2, "data": 2, "data_empty": 2,
		"continuation": 2, "rst": 1, "rst_unanswered": 1, "priority_update": 1, "priority": 1, "window_update": 1,
	}
	got := totals(c)
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %d, want %d (all: %v)", k, got[k], v, got)
		}
	}
	if got["max:continuations_per_block"] != 2 || got["max:peak_streams"] != 2 || got["max:settings_entries_per_frame"] != 3 {
		t.Errorf("maxima: %v", got)
	}
	if len(c.Unknown) != 0 || c.Settings["0x1a1a"] != 1 || c.cf.desync || c.Codes["c2s_rst:0x8"] != 1 {
		t.Errorf("unknown %v settings %v codes %v desync %v", c.Unknown, c.Settings, c.Codes, c.cf.desync)
	}
}

func TestChunkingInvariant(t *testing.T) {
	whole := totals(feedAll(func(b []byte) [][]byte { return [][]byte{b} }))
	one := totals(feedAll(func(b []byte) [][]byte {
		var o [][]byte
		for i := range b {
			o = append(o, b[i:i+1])
		}
		return o
	}))
	if !reflect.DeepEqual(whole, one) {
		t.Errorf("1-byte chunks differ:\n%v\n%v", whole, one)
	}
	rng := rand.New(rand.NewSource(7))
	for range 50 {
		got := totals(feedAll(func(b []byte) [][]byte {
			var o [][]byte
			for len(b) > 0 {
				n := min(1+rng.Intn(40), len(b))
				o, b = append(o, b[:n]), b[n:]
			}
			return o
		}))
		if !reflect.DeepEqual(whole, got) {
			t.Fatalf("random chunks differ:\n%v\n%v", whole, got)
		}
	}
}

func TestDesync(t *testing.T) {
	for name, in := range map[string][]byte{
		"bad preface":        []byte("GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
		"first not SETTINGS": append([]byte(preface), frame(tPing, 0, 0, make([]byte, 8))...),
		"garbage":            append([]byte(preface), []byte("\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff")...),
	} {
		c := newConn(func() time.Duration { return 0 })
		c.cf.feed(in)
		if !c.cf.desync {
			t.Errorf("%s: no desync", name)
		}
		c.cf.feed([]byte("more bytes after desync")) // must not panic or count
	}
}

func TestUnansweredRST(t *testing.T) {
	c := newConn(func() time.Duration { return 0 })
	c.cf.feed(append([]byte(preface), frame(tSettings, 0, 0, nil)...))
	c.sf.feed(frame(tSettings, 0, 0, nil))
	c.cf.feed(frame(tHeaders, fEndHeaders|fEndStream, 1, []byte("a")))
	c.sf.feed(frame(tHeaders, fEndHeaders|fEndStream, 1, []byte("b"))) // answered completely
	c.cf.feed(frame(tRst, 0, 1, []byte{0, 0, 0, 8}))                   // stream already closed: not counted
	c.cf.feed(frame(tHeaders, fEndHeaders|fEndStream, 3, []byte("a")))
	c.cf.feed(frame(tRst, 0, 3, []byte{0, 0, 0, 8})) // unanswered
	got := totals(c)
	if got["rst"] != 2 || got["rst_unanswered"] != 1 {
		t.Errorf("%v", got)
	}
}

func TestServerCodesAndSettings(t *testing.T) {
	sv := append(frame(tSettings, 0, 0, []byte{0, 3, 0, 0, 0, 100, 0, 9, 0, 0, 0, 1}), // MAX_CONCURRENT_STREAMS=100, NO_RFC7540_PRIORITIES=1
		frame(tRst, 0, 1, []byte{0, 0, 0, 8})...)
	sv = append(sv, frame(tGoaway, 0, 0, []byte{0, 0, 0, 5, 0, 0, 0, 0xb, 'x'})...) // last stream 5, ENHANCE_YOUR_CALM, debug data
	for _, chunk := range []int{len(sv), 1, 7} {
		c := newConn(func() time.Duration { return 0 })
		c.cf.feed([]byte(preface))
		c.cf.feed(frame(tSettings, 0, 0, nil))
		for b := sv; len(b) > 0; {
			n := min(chunk, len(b))
			c.sf.feed(b[:n])
			b = b[n:]
		}
		if len(c.GoawayDebug) != 1 || c.GoawayDebug[0] != "x" {
			t.Errorf("chunk %d goaway debug %q", chunk, c.GoawayDebug)
		}
		want := map[string]int64{"s2c_rst:0x8": 1, "s2c_goaway:0xb": 1}
		if !reflect.DeepEqual(c.Codes, want) {
			t.Errorf("chunk %d codes %v", chunk, c.Codes)
		}
		if c.ServerSettings["0x0009=1"] != 1 || c.ServerSettings["0x0003=100"] != 1 || len(c.ServerSettings) != 2 {
			t.Errorf("chunk %d settings %v", chunk, c.ServerSettings)
		}
	}
}
