package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"golang.org/x/net/http2"
)

// WebSockets over an HTTP/2 stream (RFC 8441) or an HTTP/3 stream (RFC
// 9220): an extended CONNECT with :protocol websocket, then RFC 6455 frames
// (masked from the client) as the stream's data. Each user gets its own
// connection, as each user is its own browser.

const (
	opCont   = 0
	opText   = 1
	opBinary = 2
	opClose  = 8
	opPing   = 9
	opPong   = 10
)

type streamConn struct {
	r      *bufio.Reader
	w      io.Writer
	flush  func()
	closer func()
	wmu    sync.Mutex
	fin    chan struct{}
	once   sync.Once
}

func (s *streamConn) writeFrame(op byte, payload []byte) error {
	var hdr [14]byte
	hdr[0] = 0x80 | op
	n := 2
	switch l := len(payload); {
	case l < 126:
		hdr[1] = 0x80 | byte(l)
	case l < 1<<16:
		hdr[1] = 0x80 | 126
		binary.BigEndian.PutUint16(hdr[2:], uint16(l))
		n = 4
	default:
		hdr[1] = 0x80 | 127
		binary.BigEndian.PutUint64(hdr[2:], uint64(l))
		n = 10
	}
	var key [4]byte
	rand.Read(key[:])
	copy(hdr[n:], key[:])
	n += 4
	buf := make([]byte, n+len(payload))
	copy(buf, hdr[:n])
	for i, b := range payload {
		buf[n+i] = b ^ key[i&3]
	}
	s.wmu.Lock()
	defer s.wmu.Unlock()
	if _, err := s.w.Write(buf); err != nil {
		return err
	}
	if s.flush != nil {
		s.flush()
	}
	return nil
}

// readMessage returns the next text or binary message, answering pings and
// joining fragments.
func (s *streamConn) readMessage() (byte, []byte, error) {
	var op byte
	var msg []byte
	for {
		var h [2]byte
		if _, err := io.ReadFull(s.r, h[:]); err != nil {
			return 0, nil, err
		}
		fin, fop := h[0]&0x80 != 0, h[0]&0x0f
		l := uint64(h[1] & 0x7f)
		switch l {
		case 126:
			var b [2]byte
			if _, err := io.ReadFull(s.r, b[:]); err != nil {
				return 0, nil, err
			}
			l = uint64(binary.BigEndian.Uint16(b[:]))
		case 127:
			var b [8]byte
			if _, err := io.ReadFull(s.r, b[:]); err != nil {
				return 0, nil, err
			}
			l = binary.BigEndian.Uint64(b[:])
		}
		if h[1]&0x80 != 0 || l > 8<<20 {
			return 0, nil, errors.New("bad frame from server")
		}
		p := make([]byte, l)
		if _, err := io.ReadFull(s.r, p); err != nil {
			return 0, nil, err
		}
		switch fop {
		case opPing:
			s.writeFrame(opPong, p)
			continue
		case opPong:
			continue
		case opClose:
			s.writeFrame(opClose, p)
			return 0, nil, io.EOF
		case opCont:
			msg = append(msg, p...)
		default:
			op, msg = fop, p
		}
		if fin {
			return op, msg, nil
		}
	}
}

func (s *streamConn) run(h handlers) {
	defer s.close()
	for {
		op, b, err := s.readMessage()
		if err != nil {
			return
		}
		if op == opText {
			h.text(b)
		} else {
			h.media(b)
		}
	}
}

func (s *streamConn) sendText(b []byte) error           { return s.writeFrame(opText, b) }
func (s *streamConn) sendMedia(_ uint8, b []byte) error { return s.writeFrame(opBinary, b) }
func (s *streamConn) close() {
	s.once.Do(func() {
		s.writeFrame(opClose, []byte{0x03, 0xe8})
		s.closer()
		close(s.fin)
	})
}
func (s *streamConn) done() <-chan struct{} { return s.fin }

func wsURL(base, token string) string {
	return base + "/ws?token=" + url.QueryEscape(token)
}

// dialWSH2 opens a WebSocket over its own HTTP/2 connection.
func dialWSH2(ctx context.Context, base, token string, h handlers) (conn, error) {
	tr := &http2.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"h2"}},
		ReadIdleTimeout: 30 * time.Second}
	pr, pw := io.Pipe()
	// The stream outlives the dial's timeout, so it gets a context of its own.
	sctx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(sctx, http.MethodConnect, wsURL(base, token), pr)
	if err != nil {
		cancel()
		return nil, err
	}
	req.Header.Set(":protocol", "websocket")
	req.Header.Set("Sec-WebSocket-Version", "13")
	type result struct {
		rsp *http.Response
		err error
	}
	ch := make(chan result, 1)
	go func() {
		rsp, err := tr.RoundTrip(req)
		ch <- result{rsp, err}
	}()
	var res result
	select {
	case res = <-ch:
	case <-ctx.Done():
		cancel()
		pw.Close()
		return nil, ctx.Err()
	}
	if res.err != nil {
		cancel()
		pw.Close()
		return nil, res.err
	}
	if res.rsp.StatusCode != http.StatusOK {
		res.rsp.Body.Close()
		cancel()
		pw.Close()
		tr.CloseIdleConnections()
		return nil, statusError{res.rsp.StatusCode}
	}
	s := &streamConn{r: bufio.NewReaderSize(res.rsp.Body, 64<<10), w: pw, fin: make(chan struct{}),
		closer: func() { pw.Close(); res.rsp.Body.Close(); cancel(); tr.CloseIdleConnections() }}
	go s.run(h)
	return s, nil
}

var h3Transport = &http3.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true, NextProtos: []string{http3.NextProtoH3}}}

// dialWSH3 opens a WebSocket over its own HTTP/3 connection.
func dialWSH3(ctx context.Context, base, token string, h handlers) (conn, error) {
	u, err := url.Parse(base)
	if err != nil {
		return nil, err
	}
	qc, err := quic.DialAddr(ctx, u.Host, &tls.Config{InsecureSkipVerify: true, NextProtos: []string{http3.NextProtoH3}},
		&quic.Config{MaxIdleTimeout: 60 * time.Second, KeepAlivePeriod: 10 * time.Second})
	if err != nil {
		return nil, err
	}
	fail := func(err error) (conn, error) {
		qc.CloseWithError(0, "")
		return nil, err
	}
	cc := h3Transport.NewClientConn(qc)
	select {
	case <-cc.ReceivedSettings():
	case <-ctx.Done():
		return fail(ctx.Err())
	}
	str, err := cc.OpenRequestStream(ctx)
	if err != nil {
		return fail(err)
	}
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodConnect, wsURL(base, token), nil)
	req.Proto = "websocket"
	req.Header.Set("Sec-WebSocket-Version", "13")
	if err := str.SendRequestHeader(req); err != nil {
		return fail(err)
	}
	rsp, err := str.ReadResponse()
	if err != nil {
		return fail(err)
	}
	if rsp.StatusCode != http.StatusOK {
		return fail(statusError{rsp.StatusCode})
	}
	s := &streamConn{r: bufio.NewReaderSize(str, 64<<10), w: str, fin: make(chan struct{}),
		closer: func() { str.Close(); qc.CloseWithError(0, "") }}
	go s.run(h)
	return s, nil
}
