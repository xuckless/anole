package main

import (
	"crypto/tls"
	"encoding/binary"
	"errors"
	"io"
	"net/http"
	"sync"

	"github.com/quic-go/quic-go/http3"
	"github.com/quic-go/webtransport-go"
)

var errTooBig = errors.New("message too big")

// writeFrame writes a u32 LE length and the message.
func writeFrame(w io.Writer, msg []byte) error {
	var n [4]byte
	binary.LittleEndian.PutUint32(n[:], uint32(len(msg)))
	if _, err := w.Write(n[:]); err != nil {
		return err
	}
	_, err := w.Write(msg)
	return err
}

// readFrames calls fn for each length-prefixed message until the stream ends.
func readFrames(r io.Reader, fn func([]byte)) error {
	var n [4]byte
	for {
		if _, err := io.ReadFull(r, n[:]); err != nil {
			return err
		}
		size := binary.LittleEndian.Uint32(n[:])
		if size > maxMessage {
			return errTooBig
		}
		msg := make([]byte, size)
		if _, err := io.ReadFull(r, msg); err != nil {
			return err
		}
		fn(msg)
	}
}

type wtMediaStream struct {
	mu sync.Mutex
	s  *webtransport.SendStream
}

// wtConn sends text on the control stream and media on one lazily opened
// unidirectional stream per kind, each with its own write lock.
type wtConn struct {
	sess  *webtransport.Session
	ctlMu sync.Mutex
	ctl   *webtransport.Stream
	mu    sync.Mutex
	media map[byte]*wtMediaStream
}

func (w *wtConn) SendText(msg []byte) error {
	w.ctlMu.Lock()
	defer w.ctlMu.Unlock()
	return writeFrame(w.ctl, msg)
}

func (w *wtConn) SendMedia(kind byte, msg []byte) error {
	w.mu.Lock()
	st := w.media[kind]
	if st == nil {
		st = &wtMediaStream{}
		w.media[kind] = st
	}
	w.mu.Unlock()

	st.mu.Lock()
	defer st.mu.Unlock()
	if st.s == nil {
		s, err := w.sess.OpenUniStreamSync(w.sess.Context())
		if err != nil {
			return err
		}
		st.s = s
	}
	return writeFrame(st.s, msg)
}

func newWTServer(hub *Hub, addr string, cert tls.Certificate) *webtransport.Server {
	mux := http.NewServeMux()
	wt := &webtransport.Server{
		H3: &http3.Server{
			Addr:      addr,
			Handler:   mux,
			TLSConfig: http3.ConfigureTLSConfig(&tls.Config{Certificates: []tls.Certificate{cert}}),
		},
		// The load client sends no Origin header.
		CheckOrigin: func(*http.Request) bool { return true },
	}
	webtransport.ConfigureHTTP3Server(wt.H3)

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, `{"status":"ok"}`)
	})
	mux.HandleFunc("CONNECT /wt", func(w http.ResponseWriter, r *http.Request) {
		u := hub.UserByToken(r.URL.Query().Get("token"))
		if u == nil {
			writeJSON(w, http.StatusUnauthorized, `{"error":"unauthorized"}`)
			return
		}
		if !hub.Reserve(u) {
			writeJSON(w, http.StatusConflict, `{"error":"already connected"}`)
			return
		}
		sess, err := wt.Upgrade(w, r)
		if err != nil {
			hub.Release(u)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		serveWT(hub, u, sess)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusNotFound, `{"error":"not found"}`)
	})
	return wt
}

func writeJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	io.WriteString(w, body)
}

// serveWT runs one session: the first bidirectional stream is the control
// stream, and every incoming unidirectional stream carries media.
func serveWT(hub *Hub, u *User, sess *webtransport.Session) {
	ctx := sess.Context()
	ctl, err := sess.AcceptStream(ctx)
	if err != nil {
		hub.Release(u)
		sess.CloseWithError(0, "")
		return
	}
	conn := &wtConn{sess: sess, ctl: ctl, media: map[byte]*wtMediaStream{}}
	hub.Attach(u, conn)
	defer hub.Detach(u)

	go func() {
		for {
			st, err := sess.AcceptUniStream(ctx)
			if err != nil {
				return
			}
			go func() {
				err := readFrames(st, func(msg []byte) { hub.RelayMedia(u, msg) })
				if err == errTooBig {
					sess.CloseWithError(0, err.Error())
				}
			}()
		}
	}()

	err = readFrames(ctl, func(msg []byte) { hub.HandleText(u, conn, msg) })
	if err == errTooBig {
		sess.CloseWithError(0, err.Error())
	} else {
		sess.CloseWithError(0, "")
	}
}
