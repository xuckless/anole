package main

import (
	"bytes"
	"compress/flate"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/quic-go/webtransport-go"
)

// The media header (bench/videocall/SPEC.md): 24 bytes, little-endian.
const (
	headerLen      = 24
	kindVideo      = 1
	kindAudio      = 2
	flagKey        = 1
	flagCompressed = 2
)

type header struct {
	Kind, Flags uint8
	Seq         uint32
	SentUS      int64
	CRC, Len    uint32
}

func (h header) put(b []byte) {
	b[0], b[1], b[2], b[3] = h.Kind, h.Flags, 0, 0
	binary.LittleEndian.PutUint32(b[4:], h.Seq)
	binary.LittleEndian.PutUint64(b[8:], uint64(h.SentUS))
	binary.LittleEndian.PutUint32(b[16:], h.CRC)
	binary.LittleEndian.PutUint32(b[20:], h.Len)
}

func parseHeader(b []byte) header {
	return header{Kind: b[0], Flags: b[1], Seq: binary.LittleEndian.Uint32(b[4:]),
		SentUS: int64(binary.LittleEndian.Uint64(b[8:])), CRC: binary.LittleEndian.Uint32(b[16:]),
		Len: binary.LittleEndian.Uint32(b[20:])}
}

// mediaMessage builds header + payload for one frame or packet.
func mediaMessage(kind, flags uint8, seq uint32, sentUS int64, payload []byte) []byte {
	m := make([]byte, headerLen+len(payload))
	header{Kind: kind, Flags: flags, Seq: seq, SentUS: sentUS, CRC: crc32.ChecksumIEEE(payload), Len: uint32(len(payload))}.put(m)
	copy(m[headerLen:], payload)
	return m
}

var inflaters = sync.Pool{New: func() any { return flate.NewReader(bytes.NewReader(nil)) }}

// checkPayload checks a relayed payload's length and CRC, inflating it
// first when the server compressed it.
func checkPayload(h header, body []byte) error {
	if h.Flags&flagCompressed != 0 {
		return inflate(h, body)
	}
	if uint32(len(body)) != h.Len || crc32.ChecksumIEEE(body) != h.CRC {
		return errors.New("crc mismatch")
	}
	return nil
}

// inflate undoes the server's raw DEFLATE and checks length and CRC.
func inflate(h header, body []byte) error {
	r := inflaters.Get().(io.ReadCloser)
	defer inflaters.Put(r)
	r.(flate.Resetter).Reset(bytes.NewReader(body), nil)
	out := make([]byte, h.Len)
	if _, err := io.ReadFull(r, out); err != nil {
		return fmt.Errorf("inflate: %w", err)
	}
	if n, _ := r.Read(make([]byte, 1)); n != 0 {
		return errors.New("inflate: longer than orig_len")
	}
	if crc32.ChecksumIEEE(out) != h.CRC {
		return errors.New("crc mismatch")
	}
	return nil
}

func nowUS() int64 { return time.Now().UnixMicro() }

// conn is one user's realtime connection, on either transport. Received
// messages go to the handlers until the connection ends; done is then closed.
type conn interface {
	sendText(b []byte) error
	sendMedia(kind uint8, b []byte) error
	close()
	done() <-chan struct{}
}

type handlers struct {
	text  func([]byte)
	media func([]byte)
}

var tlsConfig = &tls.Config{InsecureSkipVerify: true}

// statusError is a refused upgrade, with the HTTP status.
type statusError struct{ status int }

func (e statusError) Error() string { return fmt.Sprintf("status %d", e.status) }

// WebSocket ----------------------------------------------------------------

type wsConn struct {
	c    *websocket.Conn
	fin  chan struct{}
	once sync.Once
}

var wsHTTP = &http.Client{Transport: &http.Transport{TLSClientConfig: tlsConfig, MaxIdleConnsPerHost: -1}}

func dialWS(ctx context.Context, base, token string, h handlers) (conn, error) {
	u := strings.Replace(base, "https://", "wss://", 1) + "/ws?token=" + token
	c, rsp, err := websocket.Dial(ctx, u, &websocket.DialOptions{HTTPClient: wsHTTP, CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		if rsp != nil && rsp.StatusCode != http.StatusSwitchingProtocols {
			return nil, statusError{rsp.StatusCode}
		}
		return nil, err
	}
	c.SetReadLimit(4 << 20)
	w := &wsConn{c: c, fin: make(chan struct{})}
	go func() {
		defer w.close()
		for {
			typ, b, err := c.Read(context.Background())
			if err != nil {
				return
			}
			if typ == websocket.MessageText {
				h.text(b)
			} else {
				h.media(b)
			}
		}
	}()
	return w, nil
}

func (w *wsConn) sendText(b []byte) error {
	return w.c.Write(context.Background(), websocket.MessageText, b)
}
func (w *wsConn) sendMedia(_ uint8, b []byte) error {
	return w.c.Write(context.Background(), websocket.MessageBinary, b)
}
func (w *wsConn) close() {
	w.once.Do(func() { w.c.CloseNow(); close(w.fin) })
}
func (w *wsConn) done() <-chan struct{} { return w.fin }

// WebTransport -------------------------------------------------------------

type wtConn struct {
	s       *webtransport.Session
	ctl     *webtransport.Stream
	ctlMu   sync.Mutex
	uni     map[uint8]*webtransport.SendStream
	uniMu   sync.Mutex
	fin     chan struct{}
	once    sync.Once
	handler handlers
}

func newWTDialer() *webtransport.Dialer {
	return &webtransport.Dialer{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true, NextProtos: []string{http3.NextProtoH3}},
		QUICConfig: &quic.Config{EnableDatagrams: true, EnableStreamResetPartialDelivery: true,
			MaxIdleTimeout: 60 * time.Second, KeepAlivePeriod: 10 * time.Second,
			MaxIncomingStreams: 1000, MaxIncomingUniStreams: 1000},
	}
}

func dialWT(ctx context.Context, d *webtransport.Dialer, base, token string, h handlers) (conn, error) {
	rsp, s, err := d.Dial(ctx, base+"/wt?token="+token, nil)
	if err != nil {
		if rsp != nil && rsp.StatusCode != http.StatusOK {
			return nil, statusError{rsp.StatusCode}
		}
		return nil, err
	}
	ctl, err := s.OpenStreamSync(ctx)
	if err == nil {
		// webtransport-go sends the stream's header with the first write;
		// without one the server never sees the control stream.
		_, err = ctl.Write(nil)
	}
	if err != nil {
		s.CloseWithError(0, "")
		return nil, err
	}
	w := &wtConn{s: s, ctl: ctl, uni: map[uint8]*webtransport.SendStream{}, fin: make(chan struct{}), handler: h}
	go func() {
		defer w.close()
		readFrames(ctl, h.text)
	}()
	go func() {
		for {
			st, err := s.AcceptUniStream(context.Background())
			if err != nil {
				return
			}
			go readFrames(st, h.media)
		}
	}()
	go func() {
		<-s.Context().Done()
		w.close()
	}()
	return w, nil
}

// readFrames reads u32 LE length-prefixed messages until the stream ends.
func readFrames(r io.Reader, fn func([]byte)) {
	var lb [4]byte
	for {
		if _, err := io.ReadFull(r, lb[:]); err != nil {
			return
		}
		n := binary.LittleEndian.Uint32(lb[:])
		if n > 8<<20 {
			return
		}
		b := make([]byte, n)
		if _, err := io.ReadFull(r, b); err != nil {
			return
		}
		fn(b)
	}
}

func frame(b []byte) []byte {
	f := make([]byte, 4+len(b))
	binary.LittleEndian.PutUint32(f, uint32(len(b)))
	copy(f[4:], b)
	return f
}

func (w *wtConn) sendText(b []byte) error {
	w.ctlMu.Lock()
	defer w.ctlMu.Unlock()
	_, err := w.ctl.Write(frame(b))
	return err
}

// sendMedia writes on the kind's own uni stream, opened on first use. One
// goroutine sends each kind, so a stream has a single writer.
func (w *wtConn) sendMedia(kind uint8, b []byte) error {
	w.uniMu.Lock()
	st := w.uni[kind]
	if st == nil {
		var err error
		st, err = w.s.OpenUniStreamSync(context.Background())
		if err != nil {
			w.uniMu.Unlock()
			return err
		}
		w.uni[kind] = st
	}
	w.uniMu.Unlock()
	_, err := st.Write(frame(b))
	return err
}

func (w *wtConn) close() {
	w.once.Do(func() { w.s.CloseWithError(0, ""); close(w.fin) })
}
func (w *wtConn) done() <-chan struct{} { return w.fin }
