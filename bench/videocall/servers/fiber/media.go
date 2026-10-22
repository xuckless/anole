package main

import (
	"bytes"
	"compress/flate"
	"os"
	"sync"
)

const (
	headerLen      = 24
	flagCompressed = 1 << 1
	maxMessage     = 1 << 20 // larger media messages close the connection
)

// flate.Writer allocates several hundred KB, so writers are reused through a
// pool; Reset starts a fresh, independent raw DEFLATE stream every time.
var flateWriters = sync.Pool{
	New: func() any {
		w, _ := flate.NewWriter(nil, flate.DefaultCompression)
		return w
	},
}

// compressMedia returns the header with the compressed flag set, followed by
// the payload as raw DEFLATE.
func compressMedia(msg []byte) []byte {
	var buf bytes.Buffer
	buf.Grow(len(msg) + 64)
	buf.Write(msg[:headerLen])
	w := flateWriters.Get().(*flate.Writer)
	w.Reset(&buf)
	w.Write(msg[headerLen:])
	w.Close()
	flateWriters.Put(w)
	out := buf.Bytes()
	out[1] |= flagCompressed
	return out
}

// RelayMedia compresses a media message from u and sends it to u's peer.
func (h *Hub) RelayMedia(u *User, msg []byte) {
	if len(msg) < headerLen || msg[1]&flagCompressed != 0 {
		return
	}
	peer := h.peerConn(u)
	if peer == nil {
		return
	}
	if !mediaDeflate {
		peer.SendMedia(msg[0], msg)
		return
	}
	peer.SendMedia(msg[0], compressMedia(msg))
}

// mediaDeflate is off with MEDIA_DEFLATE=off: media is relayed as it came
// (the benchmark's no-compression pass).
var mediaDeflate = os.Getenv("MEDIA_DEFLATE") != "off"
