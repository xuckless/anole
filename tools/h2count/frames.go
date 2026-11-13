package main

import (
	"bytes"
	"fmt"
	"time"
)

// An incremental HTTP/2 frame reader for one direction of one connection,
// and the counters it feeds. Written from RFC 9113 section 4.1 (the 9-byte
// frame header) and the frame definitions of section 6; no HPACK, and only
// three flags of state per stream.

const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

const (
	tData, tHeaders, tPriority, tRst, tSettings            = 0, 1, 2, 3, 4
	tPushPromise, tPing, tGoaway, tWindowUpdate, tContinue = 5, 6, 7, 8, 9
	tPriorityUpdate                                        = 0x10 // RFC 9218 section 7.1
)

const (
	fEndStream  = 0x1 // DATA, HEADERS
	fAck        = 0x1 // SETTINGS, PING
	fEndHeaders = 0x4 // HEADERS, CONTINUATION
	fPadded     = 0x8 // DATA, HEADERS
	fPriority   = 0x20
)

type frameHdr struct {
	Len    uint32
	Type   byte
	Flags  byte
	Stream uint32
}

// framer splits a byte stream into frames and calls on once per frame, when
// its payload has fully arrived. first is the payload's first byte (the pad
// length of a padded frame); payload holds the first payloadKeep bytes (the
// SETTINGS entries, the error code of a GOAWAY or RST_STREAM).
type framer struct {
	pre     int // client preface bytes still expected
	seen    []byte
	hdr     [9]byte
	hn      int
	cur     frameHdr
	remain  uint32
	first   byte
	hasInit bool
	pay     []byte
	nframes int
	desync  bool
	at      int64 // byte offset of the first thing that did not parse
	off     int64
	on      func(h frameHdr, first byte, hasFirst bool, payload []byte)
}

const payloadKeep = 6 * 64

func newFramer(client bool, on func(frameHdr, byte, bool, []byte)) *framer {
	f := &framer{on: on}
	if client {
		f.pre = len(preface)
	}
	return f
}

func (f *framer) fail() { f.desync, f.at = true, f.off }

func (f *framer) feed(b []byte) {
	for len(b) > 0 && !f.desync {
		if f.pre > 0 {
			n := min(f.pre, len(b))
			f.seen = append(f.seen, b[:n]...)
			f.pre -= n
			f.off += int64(n)
			b = b[n:]
			if f.pre == 0 && !bytes.Equal(f.seen, []byte(preface)) {
				f.fail()
			}
			continue
		}
		if f.remain == 0 {
			n := min(9-f.hn, len(b))
			copy(f.hdr[f.hn:], b[:n])
			f.hn += n
			f.off += int64(n)
			b = b[n:]
			if f.hn < 9 {
				continue
			}
			f.cur = frameHdr{
				Len:    uint32(f.hdr[0])<<16 | uint32(f.hdr[1])<<8 | uint32(f.hdr[2]),
				Type:   f.hdr[3],
				Flags:  f.hdr[4],
				Stream: (uint32(f.hdr[5])&0x7f)<<24 | uint32(f.hdr[6])<<16 | uint32(f.hdr[7])<<8 | uint32(f.hdr[8]),
			}
			// Both sides open with SETTINGS (RFC 9113, 3.4); anything else first is not HTTP/2.
			if f.nframes == 0 && f.cur.Type != tSettings {
				f.fail()
				return
			}
			f.nframes++
			f.remain, f.hasInit, f.first, f.pay = f.cur.Len, false, 0, f.pay[:0]
			if f.remain == 0 {
				f.hn = 0
				f.on(f.cur, 0, false, nil)
			}
			continue
		}
		n := min(uint32(len(b)), f.remain)
		if !f.hasInit && n > 0 {
			f.first, f.hasInit = b[0], true
		}
		if (f.cur.Type == tSettings || f.cur.Type == tGoaway || f.cur.Type == tRst) && len(f.pay) < payloadKeep {
			f.pay = append(f.pay, b[:min(int(n), payloadKeep-len(f.pay))]...)
		}
		f.remain -= n
		f.off += int64(n)
		b = b[n:]
		if f.remain == 0 {
			f.hn = 0
			f.on(f.cur, f.first, f.hasInit, f.pay)
		}
	}
}

// Ctr is one counter: its total and its busiest second and 100 ms.
type Ctr struct {
	Total   int64 `json:"total"`
	Peak1s  int64 `json:"peak_1s"`
	Peak100 int64 `json:"peak_100ms"`
	w       Window
}

type stream struct{ clientEnd, serverEnd bool }

// Conn is everything counted on one proxied connection (client to server
// unless a name starts with s2c_).
type Conn struct {
	ID       int              `json:"id"`
	Scenario string           `json:"scenario"`
	Listener string           `json:"listener"`
	Client   string           `json:"client_addr"`
	Start    time.Time        `json:"start"`
	Seconds  float64          `json:"duration_s"`
	BytesC2S int64            `json:"bytes_c2s"`
	BytesS2C int64            `json:"bytes_s2c"`
	Rates    map[string]*Ctr  `json:"rates"`
	Max      map[string]int64 `json:"max"`
	Unknown  map[string]int64 `json:"unknown_types,omitempty"`
	Settings map[string]int64 `json:"settings_ids,omitempty"`
	// Codes counts GOAWAY and RST_STREAM error codes per direction ("s2c_goaway:0xb").
	Codes map[string]int64 `json:"error_codes,omitempty"`
	// GoawayDebug is the debug data of the server's GOAWAY frames (the engine puts its reason there).
	GoawayDebug []string `json:"s2c_goaway_debug,omitempty"`
	// ServerSettings counts the server's SETTINGS entries as "0x0009=1".
	ServerSettings map[string]int64 `json:"server_settings,omitempty"`
	DesyncC        bool             `json:"desync_c2s,omitempty"`
	DesyncS        bool             `json:"desync_s2c,omitempty"`

	now     func() time.Duration
	streams map[uint32]*stream
	blk     struct {
		active       bool
		conts, bytes int64
	}
	cf, sf *framer
}

func newConn(now func() time.Duration) *Conn {
	c := &Conn{
		Rates: map[string]*Ctr{}, Max: map[string]int64{},
		Unknown: map[string]int64{}, Settings: map[string]int64{}, Codes: map[string]int64{}, ServerSettings: map[string]int64{},
		now: now, streams: map[uint32]*stream{},
	}
	c.cf = newFramer(true, c.fromClient)
	c.sf = newFramer(false, c.fromServer)
	return c
}

func (c *Conn) add(name string, n int64) {
	r := c.Rates[name]
	if r == nil {
		r = &Ctr{}
		c.Rates[name] = r
	}
	r.Total += n
	r.w.Add(c.now(), n)
	r.Peak1s, r.Peak100 = r.w.Peak, r.w.Peak100
}

func (c *Conn) setMax(name string, v int64) { c.Max[name] = max(c.Max[name], v) }

// payloadLen is a DATA or HEADERS payload without its padding and, for
// HEADERS, the priority fields. It can be negative for a malformed frame.
func payloadLen(h frameHdr, first byte, hasFirst bool) int64 {
	n := int64(h.Len)
	if h.Type == tHeaders && h.Flags&fPriority != 0 {
		n -= 5
	}
	if h.Flags&fPadded != 0 {
		if !hasFirst {
			return -1
		}
		n -= 1 + int64(first)
	}
	return n
}

// code counts the error code at payload[off:off+4] of a GOAWAY or RST_STREAM.
func (c *Conn) code(name string, payload []byte, off int) {
	if len(payload) >= off+4 {
		v := uint32(payload[off])<<24 | uint32(payload[off+1])<<16 | uint32(payload[off+2])<<8 | uint32(payload[off+3])
		c.Codes[fmt.Sprintf("%s:0x%x", name, v)]++
	}
}

func (c *Conn) finishBlock() {
	c.setMax("continuations_per_block", c.blk.conts)
	c.setMax("header_block_bytes", c.blk.bytes)
	c.blk.active = false
}

func (c *Conn) closeIfDone(id uint32, s *stream) {
	if s.clientEnd && s.serverEnd {
		delete(c.streams, id)
	}
}

func (c *Conn) fromClient(h frameHdr, first byte, hasFirst bool, payload []byte) {
	c.add("frames", 1)
	c.setMax("frame_len", int64(h.Len))
	end := h.Flags&fEndStream != 0
	switch h.Type {
	case tData:
		c.add("data", 1)
		if payloadLen(h, first, hasFirst) <= 0 && !end {
			c.add("data_empty", 1)
		}
		if s := c.streams[h.Stream]; s != nil && end {
			s.clientEnd = true
			c.closeIfDone(h.Stream, s)
		}
	case tHeaders:
		c.add("headers", 1)
		n := payloadLen(h, first, hasFirst)
		if n <= 0 && !end {
			c.add("headers_empty", 1)
		}
		c.blk.active, c.blk.conts, c.blk.bytes = true, 0, max(n, 0)
		s := c.streams[h.Stream]
		if s == nil && h.Stream != 0 {
			s = &stream{}
			c.streams[h.Stream] = s
			c.add("requests", 1)
			c.setMax("peak_streams", int64(len(c.streams)))
		}
		if s != nil && end {
			s.clientEnd = true
			c.closeIfDone(h.Stream, s)
		}
		if h.Flags&fEndHeaders != 0 {
			c.finishBlock()
		}
	case tContinue:
		c.add("continuation", 1)
		if h.Len == 0 {
			c.add("continuation_empty", 1)
		}
		if !c.blk.active {
			c.add("continuation_stray", 1)
			break
		}
		c.blk.conts++
		c.blk.bytes += int64(h.Len)
		if h.Flags&fEndHeaders != 0 {
			c.finishBlock()
		}
	case tPriority:
		c.add("priority", 1)
	case tPriorityUpdate:
		c.add("priority_update", 1)
	case tRst:
		c.add("rst", 1)
		c.code("c2s_rst", payload, 0)
		if s := c.streams[h.Stream]; s != nil {
			if !s.serverEnd {
				c.add("rst_unanswered", 1)
			}
			delete(c.streams, h.Stream)
		}
	case tSettings:
		if h.Flags&fAck != 0 {
			c.add("settings_ack", 1)
			break
		}
		c.add("settings", 1)
		c.add("settings_entries", int64(h.Len/6))
		c.setMax("settings_entries_per_frame", int64(h.Len/6))
		for i := 0; i+6 <= len(payload); i += 6 {
			c.Settings[fmt.Sprintf("0x%04x", uint16(payload[i])<<8|uint16(payload[i+1]))]++
		}
	case tPing:
		if h.Flags&fAck != 0 {
			c.add("ping_ack", 1)
		} else {
			c.add("ping", 1)
		}
	case tGoaway:
		c.add("goaway", 1)
		c.code("c2s_goaway", payload, 4)
		c.code("c2s_goaway_last_stream", payload, 0)
	case tWindowUpdate:
		c.add("window_update", 1)
	case tPushPromise:
		c.add("push_promise", 1)
	default:
		c.add("unknown", 1)
		c.Unknown[fmt.Sprintf("0x%02x", h.Type)]++
	}
}

// fromServer only follows streams (so that a client RST can be told from
// one for an answered stream) and counts a few frames for ratios.
func (c *Conn) fromServer(h frameHdr, _ byte, _ bool, payload []byte) {
	end := h.Flags&fEndStream != 0
	switch h.Type {
	case tData:
		c.add("s2c_data", 1)
		fallthrough
	case tHeaders:
		if s := c.streams[h.Stream]; s != nil && end {
			s.serverEnd = true
			c.closeIfDone(h.Stream, s)
		}
	case tRst:
		c.add("s2c_rst", 1)
		c.code("s2c_rst", payload, 0)
		delete(c.streams, h.Stream)
	case tGoaway:
		c.add("s2c_goaway", 1)
		c.code("s2c_goaway", payload, 4)
		if len(payload) > 8 && len(c.GoawayDebug) < 8 {
			c.GoawayDebug = append(c.GoawayDebug, string(payload[8:]))
		}
	case tSettings:
		if h.Flags&fAck == 0 {
			c.add("s2c_settings", 1)
			for i := 0; i+6 <= len(payload); i += 6 {
				id := uint16(payload[i])<<8 | uint16(payload[i+1])
				v := uint32(payload[i+2])<<24 | uint32(payload[i+3])<<16 | uint32(payload[i+4])<<8 | uint32(payload[i+5])
				c.ServerSettings[fmt.Sprintf("0x%04x=%d", id, v)]++
			}
		}
	case tPing:
		if h.Flags&fAck == 0 {
			c.add("s2c_ping", 1)
		}
	}
}
