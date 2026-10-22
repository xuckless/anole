package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"sync"
	"unicode/utf8"
)

// Conn is one user's realtime connection, on either transport. Each
// implementation lets one goroutine write at a time.
type Conn interface {
	SendText(msg []byte) error
	SendMedia(kind byte, msg []byte) error
}

type User struct {
	ID    int
	Name  string
	Token string

	// Guarded by Hub.mu.
	online bool // a realtime connection is open or being set up
	conn   Conn
	call   *Call
}

type Call struct {
	ID      int
	A, B    *User
	nextMsg int
	history []json.RawMessage // the last 100 chat messages, as broadcast
}

func (c *Call) peer(u *User) *User {
	if c.A == u {
		return c.B
	}
	return c.A
}

const historyLimit = 100

// Hub holds all the app's state: users, the lobby and calls.
type Hub struct {
	mu       sync.Mutex
	byToken  map[string]*User
	nextUser int
	calls    map[int]*Call
	nextCall int
	lobby    []*User
}

func NewHub() *Hub {
	return &Hub{byToken: map[string]*User{}, calls: map[int]*Call{}}
}

func newToken() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func (h *Hub) CreateUser(name string) *User {
	token := newToken()
	h.mu.Lock()
	defer h.mu.Unlock()
	h.nextUser++
	u := &User{ID: h.nextUser, Name: name, Token: token}
	h.byToken[token] = u
	return u
}

func (h *Hub) UserByToken(token string) *User {
	if token == "" {
		return nil
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.byToken[token]
}

// Reserve claims the user's single realtime connection slot. It returns
// false when the user already has one.
func (h *Hub) Reserve(u *User) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if u.online {
		return false
	}
	u.online = true
	return true
}

// Release gives the slot back when the connection never got going.
func (h *Hub) Release(u *User) {
	h.mu.Lock()
	u.online = false
	h.mu.Unlock()
}

type userRef struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

type helloMsg struct {
	Type string  `json:"type"`
	User userRef `json:"user"`
}

type callMsg struct {
	Type   string  `json:"type"`
	CallID int     `json:"call_id"`
	Peer   userRef `json:"peer"`
}

type chatMsg struct {
	Type   string `json:"type"`
	CallID int    `json:"call_id"`
	ID     int    `json:"id"`
	From   string `json:"from"`
	Text   string `json:"text"`
	SentUs int64  `json:"sent_us"`
}

type peerLeftMsg struct {
	Type   string `json:"type"`
	CallID int    `json:"call_id"`
}

type errorMsg struct {
	Type  string `json:"type"`
	Error string `json:"error"`
}

func send(c Conn, v any) {
	b, _ := json.Marshal(v)
	c.SendText(b)
}

// outbox collects control messages while h.mu is held; they are sent after
// it is released, each through its connection's own write lock. Each
// user's messages are appended in the order the state changed.
type outbox []outMsg

type outMsg struct {
	to  Conn
	msg []byte
}

func (o *outbox) add(to Conn, v any) {
	b, _ := json.Marshal(v)
	*o = append(*o, outMsg{to, b})
}

func (o outbox) send() {
	for _, m := range o {
		m.to.SendText(m.msg)
	}
}

func sendError(c Conn, text string) {
	send(c, errorMsg{Type: "error", Error: text})
}

// Attach says hello, makes conn the user's live connection and puts the
// user in the lobby. Hello goes out first, before anyone can pair the user.
func (h *Hub) Attach(u *User, c Conn) {
	send(c, helloMsg{Type: "hello", User: userRef{u.ID, u.Name}})
	var out outbox
	h.mu.Lock()
	u.conn = c
	h.lobby = append(h.lobby, u)
	h.pair(&out)
	h.mu.Unlock()
	out.send()
}

// Detach handles a disconnect: the call ends and the user leaves the lobby.
func (h *Hub) Detach(u *User) {
	var out outbox
	h.mu.Lock()
	if u.call != nil {
		h.endCall(u, &out)
		h.pair(&out)
	} else {
		for i, w := range h.lobby {
			if w == u {
				h.lobby = append(h.lobby[:i], h.lobby[i+1:]...)
				break
			}
		}
	}
	u.conn = nil
	u.online = false
	h.mu.Unlock()
	out.send()
}

// pair puts the two oldest waiting users into a new call, while it can.
func (h *Hub) pair(out *outbox) {
	for len(h.lobby) >= 2 {
		a, b := h.lobby[0], h.lobby[1]
		h.lobby = h.lobby[2:]
		h.nextCall++
		call := &Call{ID: h.nextCall, A: a, B: b}
		h.calls[call.ID] = call
		a.call, b.call = call, call
		out.add(a.conn, callMsg{Type: "call", CallID: call.ID, Peer: userRef{b.ID, b.Name}})
		out.add(b.conn, callMsg{Type: "call", CallID: call.ID, Peer: userRef{a.ID, a.Name}})
	}
}

// endCall ends u's call; the peer is told and goes back to the lobby.
func (h *Hub) endCall(u *User, out *outbox) {
	call := u.call
	peer := call.peer(u)
	u.call, peer.call = nil, nil
	if peer.conn != nil {
		out.add(peer.conn, peerLeftMsg{Type: "peer_left", CallID: call.ID})
		h.lobby = append(h.lobby, peer)
	}
}

type clientMsg struct {
	Type   string          `json:"type"`
	Text   json.RawMessage `json:"text"`
	SentUs int64           `json:"sent_us"`
}

// HandleText handles one text message from the client on conn.
func (h *Hub) HandleText(u *User, c Conn, raw []byte) {
	var m clientMsg
	if err := json.Unmarshal(raw, &m); err != nil {
		sendError(c, "bad message")
		return
	}
	switch m.Type {
	case "chat":
		var text string
		if err := json.Unmarshal(m.Text, &text); err != nil {
			sendError(c, "invalid chat")
			return
		}
		if n := utf8.RuneCountInString(text); n < 1 || n > 500 {
			sendError(c, "invalid chat")
			return
		}
		h.chat(u, c, text, m.SentUs)
	case "leave":
		h.leave(u)
	default:
		sendError(c, "bad message")
	}
}

func (h *Hub) chat(u *User, c Conn, text string, sentUs int64) {
	h.mu.Lock()
	call := u.call
	if call == nil {
		h.mu.Unlock()
		sendError(c, "not in a call")
		return
	}
	call.nextMsg++
	b, _ := json.Marshal(chatMsg{Type: "chat", CallID: call.ID, ID: call.nextMsg, From: u.Name, Text: text, SentUs: sentUs})
	call.history = append(call.history, b)
	if len(call.history) > historyLimit {
		call.history = call.history[len(call.history)-historyLimit:]
	}
	a, bc := call.A.conn, call.B.conn
	h.mu.Unlock()
	a.SendText(b)
	bc.SendText(b)
}

func (h *Hub) leave(u *User) {
	var out outbox
	h.mu.Lock()
	if u.call != nil {
		h.endCall(u, &out)
		h.lobby = append(h.lobby, u)
		h.pair(&out)
	}
	h.mu.Unlock()
	out.send()
}

// History returns a call's chat history for the user, or an HTTP status.
func (h *Hub) History(callID int, u *User) ([]json.RawMessage, int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	call := h.calls[callID]
	if call == nil {
		return nil, 404
	}
	if call.A != u && call.B != u {
		return nil, 403
	}
	return append(make([]json.RawMessage, 0, len(call.history)), call.history...), 200
}

// peerConn is the connection of u's peer, or nil when u isn't in a call.
func (h *Hub) peerConn(u *User) Conn {
	h.mu.Lock()
	defer h.mu.Unlock()
	if u.call == nil {
		return nil
	}
	return u.call.peer(u).conn
}
