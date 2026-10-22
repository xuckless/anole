package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"time"
)

// smokeUser is one user of the smoke check: its account, connection, and
// what it has received.
type smokeUser struct {
	account
	c     conn
	text  chan []byte
	media chan []byte
}

type smoke struct {
	base      string
	d         *dialer
	failed    int
	transport string
}

func (s *smoke) check(name string, ok bool, detail string, args ...any) {
	mark := "ok  "
	if !ok {
		mark = "FAIL"
		s.failed++
	}
	fmt.Printf("%s %s", mark, name)
	if !ok && detail != "" {
		fmt.Printf(": "+detail, args...)
	}
	fmt.Println()
}

func (s *smoke) user(name string) *smokeUser {
	a, err := signup(s.base, name)
	s.check("POST /api/users "+name, err == nil && a.ID > 0 && regexp.MustCompile(`^[0-9a-f]{32}$`).MatchString(a.Token) && a.Name == name,
		"%v %+v", err, a)
	return &smokeUser{account: a, text: make(chan []byte, 64), media: make(chan []byte, 64)}
}

func (s *smoke) connect(u *smokeUser) error {
	c, err := s.d.dial(u.Token, handlers{
		text:  func(b []byte) { u.text <- b },
		media: func(b []byte) { u.media <- b },
	})
	u.c = c
	return err
}

// next waits for the user's next text message.
func (u *smokeUser) next(d time.Duration) (msg, string) {
	select {
	case b := <-u.text:
		var m msg
		json.Unmarshal(b, &m)
		return m, string(b)
	case <-time.After(d):
		return msg{}, "(nothing)"
	}
}

func (u *smokeUser) quietText(d time.Duration) (string, bool) {
	select {
	case b := <-u.text:
		return string(b), false
	case <-time.After(d):
		return "", true
	}
}

func (u *smokeUser) quietMedia(d time.Duration) bool {
	select {
	case <-u.media:
		return false
	case <-time.After(d):
		return true
	}
}

func (u *smokeUser) send(s string) { u.c.sendText([]byte(s)) }

func runSmoke(base, transport string, deflate bool) int {
	s := &smoke{base: base, d: newDialer(base, transport), transport: transport}
	fmt.Printf("smoke %s %s\n", transport, base)

	st, b, err := request("GET", base+"/health", "", nil)
	s.check("GET /health", err == nil && st == 200 && string(b) == `{"status":"ok"}`, "%v %d %s", err, st, b)
	st, b, _ = request("POST", base+"/api/users", "", []byte(`{"name":"bad name!"}`))
	s.check("POST /api/users invalid name -> 400", st == 400 && string(b) == `{"error":"invalid name"}`, "%d %s", st, b)
	st, b, _ = request("POST", base+"/api/users", "", []byte(`{"name":`))
	s.check("POST /api/users malformed -> 400", st == 400 && string(b) == `{"error":"malformed JSON body"}`, "%d %s", st, b)

	_, err = s.d.dial("00000000000000000000000000000000", handlers{text: func([]byte) {}, media: func([]byte) {}})
	se, isStatus := err.(statusError)
	s.check("connect with an unknown token -> 401", isStatus && se.status == 401, "%v", err)

	before := s.failed
	a, b2, c := s.user("smoke_a"), s.user("smoke_b"), s.user("smoke_c")
	if s.failed > before {
		return s.failed
	}
	err = s.connect(a)
	s.check("A connects", err == nil, "%v", err)
	if err != nil {
		return s.failed
	}
	m, raw := a.next(3 * time.Second)
	want := fmt.Sprintf(`{"type":"hello","user":{"id":%d,"name":"smoke_a"}}`, a.ID)
	s.check("A gets hello", raw == want, "got %s, want %s", raw, want)

	err = s.connect(b2)
	s.check("B connects", err == nil, "%v", err)
	if err != nil {
		return s.failed
	}
	b2.next(3 * time.Second) // hello
	ma, rawA := a.next(3 * time.Second)
	mb, rawB := b2.next(3 * time.Second)
	callID := ma.CallID
	s.check("A and B get the same call", ma.Type == "call" && mb.Type == "call" && ma.CallID > 0 && ma.CallID == mb.CallID, "%s / %s", rawA, rawB)
	wantA := fmt.Sprintf(`{"type":"call","call_id":%d,"peer":{"id":%d,"name":"smoke_b"}}`, callID, b2.ID)
	s.check("call message bytes", rawA == wantA, "got %s, want %s", rawA, wantA)

	_, err = s.d.dial(a.Token, handlers{text: func([]byte) {}, media: func([]byte) {}})
	se, isStatus = err.(statusError)
	s.check("second connection for A -> 409", isStatus && se.status == 409, "%v", err)

	// chat
	sent := nowUS()
	a.send(fmt.Sprintf(`{"type":"chat","text":"hello \"b\" ✓","sent_us":%d}`, sent))
	wantChat := fmt.Sprintf(`{"type":"chat","call_id":%d,"id":1,"from":"smoke_a","text":"hello \"b\" ✓","sent_us":%d}`, callID, sent)
	_, ra := a.next(3 * time.Second)
	_, rb := b2.next(3 * time.Second)
	s.check("chat reaches both, exact bytes", ra == wantChat && rb == wantChat, "A got %s, B got %s, want %s", ra, rb, wantChat)
	b2.send(fmt.Sprintf(`{"type":"chat","text":"hi","sent_us":%d}`, sent))
	m, _ = a.next(3 * time.Second)
	b2.next(3 * time.Second)
	s.check("chat ids count per call", m.ID == 2 && m.From == "smoke_b", "%+v", m)
	a.send(`{"type":"chat","text":"","sent_us":1}`)
	_, raw = a.next(3 * time.Second)
	s.check("empty chat -> invalid chat", raw == `{"type":"error","error":"invalid chat"}`, "%s", raw)
	a.send(`{"type":`)
	_, raw = a.next(3 * time.Second)
	s.check("malformed -> bad message", raw == `{"type":"error","error":"bad message"}`, "%s", raw)
	a.send(`{"type":"dance"}`)
	_, raw = a.next(3 * time.Second)
	s.check("unknown type -> bad message", raw == `{"type":"error","error":"bad message"}`, "%s", raw)
	_, quiet := b2.quietText(300 * time.Millisecond)
	s.check("errors go to the sender only", quiet, "")

	// media
	key := randBytes(120_000)
	a.c.sendMedia(kindVideo, mediaMessage(kindVideo, flagKey, 0, sent, key))
	audio := randBytes(160)
	a.c.sendMedia(kindAudio, mediaMessage(kindAudio, 0, 0, sent+1, audio))
	gotV, gotA := false, false
	for i := 0; i < 2; i++ {
		select {
		case mb := <-b2.media:
			h := parseHeader(mb)
			want := map[bool]uint8{true: flagKey}[h.Kind == kindVideo]
			if deflate {
				want |= flagCompressed
			}
			ok := len(mb) > headerLen && h.Flags == want && h.Seq == 0
			err := checkPayload(h, mb[headerLen:])
			if h.Kind == kindVideo {
				gotV = ok && err == nil && h.SentUS == sent && h.Len == uint32(len(key))
				s.check("video relayed intact (inflated when compressed)", gotV, "flags %d err %v len %d", h.Flags, err, h.Len)
			} else {
				gotA = ok && err == nil && h.SentUS == sent+1 && h.Len == 160
				s.check("audio relayed intact (inflated when compressed)", gotA, "flags %d err %v", h.Flags, err)
			}
		case <-time.After(3 * time.Second):
		}
	}
	s.check("both media messages arrived", gotV && gotA, "video %v audio %v", gotV, gotA)
	s.check("the sender gets no media back", a.quietMedia(300*time.Millisecond), "")
	a.c.sendMedia(kindVideo, mediaMessage(kindVideo, flagCompressed, 1, sent, key[:100]))
	s.check("client media with the compressed bit is dropped", b2.quietMedia(500*time.Millisecond), "")

	// history
	path := base + "/api/calls/" + strconv.Itoa(callID) + "/messages"
	st, body, _ := request("GET", path, a.Token, nil)
	var hist struct {
		CallID   int               `json:"call_id"`
		Messages []json.RawMessage `json:"messages"`
	}
	json.Unmarshal(body, &hist)
	s.check("history for a participant", st == 200 && hist.CallID == callID && len(hist.Messages) == 2 && string(hist.Messages[0]) == wantChat,
		"%d %s", st, body)
	st, body, _ = request("GET", path, c.Token, nil)
	s.check("history for an outsider -> 403", st == 403 && string(body) == `{"error":"forbidden"}`, "%d %s", st, body)
	st, body, _ = request("GET", path, "", nil)
	s.check("history without a token -> 401", st == 401 && string(body) == `{"error":"unauthorized"}`, "%d %s", st, body)
	st, body, _ = request("GET", base+"/api/calls/99999/messages", a.Token, nil)
	s.check("history of an unknown call -> 404", st == 404 && string(body) == `{"error":"call not found"}`, "%d %s", st, body)

	// leave, re-pairing, disconnect
	a.send(`{"type":"leave"}`)
	_, raw = b2.next(3 * time.Second)
	s.check("leave -> peer_left", raw == fmt.Sprintf(`{"type":"peer_left","call_id":%d}`, callID), "%s", raw)
	m1, r1 := a.next(3 * time.Second)
	m2, r2 := b2.next(3 * time.Second)
	s.check("both back in the lobby and paired again", m1.Type == "call" && m2.Type == "call" && m1.CallID == m2.CallID && m1.CallID != callID,
		"%s / %s", r1, r2)
	b2.c.close()
	_, raw = a.next(5 * time.Second)
	s.check("disconnect -> peer_left", raw == fmt.Sprintf(`{"type":"peer_left","call_id":%d}`, m1.CallID), "%s", raw)
	a.send(`{"type":"chat","text":"anyone?","sent_us":1}`)
	_, raw = a.next(3 * time.Second)
	s.check("chat alone -> not in a call", raw == `{"type":"error","error":"not in a call"}`, "%s", raw)
	a.c.close()

	// The first connection is gone; a new one works.
	time.Sleep(300 * time.Millisecond)
	err = s.connect(a)
	if err == nil {
		_, raw = a.next(3 * time.Second)
		a.c.close()
	}
	s.check("reconnect after close", err == nil && raw == want, "%v %s", err, raw)
	_ = m

	// A media message over 1 MiB of payload ends the connection.
	if err := s.connect(c); err == nil {
		c.next(3 * time.Second) // hello
		// In a goroutine: webtransport-go's Write can block for good once
		// the server has closed the session under it.
		go c.c.sendMedia(kindVideo, mediaMessage(kindVideo, flagKey, 0, sent, randBytes(1<<20+1)))
		closed := false
		select {
		case <-c.c.done():
			closed = true
		case <-time.After(5 * time.Second):
		}
		c.c.close()
		s.check("oversize media closes the connection", closed, "still open after 5 s")
	} else {
		s.check("C connects", false, "%v", err)
	}

	if s.failed == 0 {
		fmt.Println("PASS")
	} else {
		fmt.Printf("FAILED %d checks\n", s.failed)
	}
	return s.failed
}
