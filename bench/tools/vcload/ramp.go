package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type ramp struct {
	base, transport, cgroup, out string
	clip                         *clip
	step, maxTime, collapse      time.Duration
	videoDeadline, audioDeadline time.Duration
	chatEvery                    time.Duration
	maxUsers                     int

	d     *dialer
	start time.Time

	mu    sync.Mutex
	users []*vuser
	byID  map[int]*vuser

	// counters for the current second (swapped out each second)
	cur  *window
	curM sync.Mutex

	probeMu sync.Mutex
	probe   *bufio.Writer
}

// window holds what happened in one second (and, merged, in one step).
type window struct {
	VSent, VRecv, VOnTime, VShown, VBad  int64
	ASent, ARecv, AOnTime, ABad          int64
	ChatSent, ChatRecv                   int64
	APIReqs, APIErr                      int64
	ConnectErr, SignupErr, Disconnects   int64
	SendErr, ServerErrors                int64
	TxBytes, RxBytes                     int64
	latV, latA, latChat, latAPI, latJoin []int64 // µs
}

func (w *window) merge(o *window) {
	w.VSent += o.VSent
	w.VRecv += o.VRecv
	w.VOnTime += o.VOnTime
	w.VShown += o.VShown
	w.VBad += o.VBad
	w.ASent += o.ASent
	w.ARecv += o.ARecv
	w.AOnTime += o.AOnTime
	w.ABad += o.ABad
	w.ChatSent += o.ChatSent
	w.ChatRecv += o.ChatRecv
	w.APIReqs += o.APIReqs
	w.APIErr += o.APIErr
	w.ConnectErr += o.ConnectErr
	w.SignupErr += o.SignupErr
	w.Disconnects += o.Disconnects
	w.SendErr += o.SendErr
	w.ServerErrors += o.ServerErrors
	w.TxBytes += o.TxBytes
	w.RxBytes += o.RxBytes
	w.latV = append(w.latV, o.latV...)
	w.latA = append(w.latA, o.latA...)
	w.latChat = append(w.latChat, o.latChat...)
	w.latAPI = append(w.latAPI, o.latAPI...)
	w.latJoin = append(w.latJoin, o.latJoin...)
}

func (r *ramp) add(fn func(w *window)) {
	r.curM.Lock()
	fn(r.cur)
	r.curM.Unlock()
}

// vuser is one simulated person: an account, a connection, and a call.
type vuser struct {
	r     *ramp
	idx   int
	acct  account
	c     conn
	added time.Time

	mu      sync.Mutex
	callID  int
	peer    *vuser
	inCall  atomic.Bool
	newCall chan struct{} // tells the senders a call started (start at a keyframe)
	chains  map[int]*chain
	vseq    atomic.Uint32
	aseq    atomic.Uint32
	closing atomic.Bool
}

// chain tracks one sender's video at this receiver: a frame shows only if it
// is on time and every frame since the last keyframe showed.
type chain struct {
	lastSeq int64
	broken  bool
}

func (r *ramp) run() error {
	if err := os.MkdirAll(r.out, 0o755); err != nil {
		return err
	}
	r.d = newDialer(r.base, r.transport)
	r.byID = map[int]*vuser{}
	r.cur = &window{}
	pf, err := os.Create(filepath.Join(r.out, "probe.csv"))
	if err != nil {
		return err
	}
	defer pf.Close()
	r.probe = bufio.NewWriterSize(pf, 1<<20)
	fmt.Fprintln(r.probe, "receiver,sender,kind,seq,key,sent_us,recv_us,ok")
	secF, _ := os.Create(filepath.Join(r.out, "seconds.jsonl"))
	defer secF.Close()
	stepF, _ := os.Create(filepath.Join(r.out, "steps.jsonl"))
	defer stepF.Close()
	usersF, _ := os.Create(filepath.Join(r.out, "users.jsonl"))
	defer usersF.Close()

	fmt.Printf("vcload %s %s: %s; one user every %s\n", r.transport, r.base, r.clip, r.step)
	r.start = time.Now()
	cg := newCgroup(r.cgroup)
	load := newSelfCPU()
	health := &healthProbe{base: r.base}
	go health.loop()

	stepWin := &window{}
	stepStart := r.start
	collapsedFor, refusedFor := 0, 0
	reason := ""
	nextUser := r.start
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	sec := 0
	for reason == "" {
		now := time.Now()
		if !now.Before(nextUser) {
			// close the step of the previous user count, then add one
			n := r.count()
			if n > 0 {
				writeJSON(stepF, r.summary(stepWin, n, now.Sub(stepStart), cg, load, true))
			}
			stepWin, stepStart = &window{}, now
			if n >= r.maxUsers {
				reason = "max users"
				break
			}
			u := r.newUser(n)
			go u.run(usersF)
			nextUser = nextUser.Add(r.step)
		}
		<-tick.C
		sec++
		r.curM.Lock()
		w := r.cur
		r.cur = &window{}
		r.curM.Unlock()
		stepWin.merge(w)
		cg.sample()
		load.sample()
		row := r.summary(w, r.count(), time.Second, cg, load, false)
		row["t"] = sec
		row["health_ok"] = health.ok.Load()
		writeJSON(secF, row)
		connected, inCall := r.connected()
		if sec%10 == 0 {
			fmt.Printf("%5ds users %4d connected %4d in call %4d  video ok %5.1f%%  p99 %6.1f ms  mem %6.0f MB  cpu %.2f  load %.2f\n",
				sec, r.count(), connected, inCall, 100*ratio(w.VShown, w.VSent), pct(w.latV, 99)/1000,
				cg.memMB, cg.cpu, load.cpu)
		}
		switch {
		case cg.gone:
			reason = "crashed (container exited)"
		case cg.oom:
			reason = "crashed (OOM kill)"
		case time.Since(r.start) > r.maxTime:
			reason = "max time"
		}
		if inCall > 0 && w.VSent > 0 && ratio(w.VShown, w.VSent) < 0.1 {
			collapsedFor++
		} else {
			collapsedFor = 0
		}
		if time.Duration(collapsedFor)*time.Second >= r.collapse {
			reason = fmt.Sprintf("collapsed (under 10%% of video frames shown for %s)", r.collapse)
		}
		if w.ConnectErr+w.SignupErr > 0 && connected < r.count()/2 {
			refusedFor++
		} else {
			refusedFor = 0
		}
		if refusedFor >= 30 {
			reason = "refusing users for 30 s"
		}
	}
	r.probeMu.Lock()
	r.probe.Flush()
	r.probeMu.Unlock()
	sum := map[string]any{"transport": r.transport, "url": r.base, "stop": reason, "users": r.count(),
		"start_us": r.start.UnixMicro(),
		"seconds": int(time.Since(r.start).Seconds()), "step_s": r.step.Seconds(), "clip": r.clip.String(),
		"video_deadline_ms": r.videoDeadline.Milliseconds(), "audio_deadline_ms": r.audioDeadline.Milliseconds(),
		"mem_peak_mb": cg.peakMB}
	f, _ := os.Create(filepath.Join(r.out, "summary.json"))
	json.NewEncoder(f).Encode(sum)
	f.Close()
	fmt.Printf("stopped: %s at %d users after %s\n", reason, r.count(), time.Since(r.start).Round(time.Second))
	r.mu.Lock()
	for _, u := range r.users {
		u.closing.Store(true)
		if u.c != nil {
			u.c.close()
		}
	}
	r.mu.Unlock()
	return nil
}

func (r *ramp) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.users)
}

func (r *ramp) connected() (conn, inCall int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, u := range r.users {
		u.mu.Lock()
		if u.c != nil {
			conn++
		}
		u.mu.Unlock()
		if u.inCall.Load() {
			inCall++
		}
	}
	return
}

// summary turns a window into one output row.
func (r *ramp) summary(w *window, users int, d time.Duration, cg *cgroup, load *selfCPU, step bool) map[string]any {
	connected, inCall := r.connected()
	s := d.Seconds()
	row := map[string]any{
		"users": users, "connected": connected, "in_call": inCall,
		"video_sent": w.VSent, "video_recv": w.VRecv, "video_on_time": w.VOnTime, "video_shown": w.VShown, "video_bad": w.VBad,
		"audio_sent": w.ASent, "audio_recv": w.ARecv, "audio_on_time": w.AOnTime, "audio_bad": w.ABad,
		"video_ok": ratio(w.VShown, w.VSent), "audio_ok": ratio(w.AOnTime, w.ASent),
		"chat_sent": w.ChatSent, "chat_recv": w.ChatRecv, "chat_ok": ratio(w.ChatRecv, w.ChatSent),
		"lat_video_p50_ms": pct(w.latV, 50) / 1000, "lat_video_p95_ms": pct(w.latV, 95) / 1000,
		"lat_video_p99_ms": pct(w.latV, 99) / 1000, "lat_video_max_ms": pct(w.latV, 100) / 1000,
		"lat_audio_p50_ms": pct(w.latA, 50) / 1000, "lat_audio_p99_ms": pct(w.latA, 99) / 1000,
		"lat_chat_p50_ms": pct(w.latChat, 50) / 1000, "lat_chat_p99_ms": pct(w.latChat, 99) / 1000,
		"lat_api_p50_ms": pct(w.latAPI, 50) / 1000, "lat_api_p99_ms": pct(w.latAPI, 99) / 1000,
		"lat_join_p50_ms": pct(w.latJoin, 50) / 1000, "lat_join_max_ms": pct(w.latJoin, 100) / 1000,
		"api_reqs": w.APIReqs, "api_errors": w.APIErr,
		"connect_errors": w.ConnectErr, "signup_errors": w.SignupErr, "disconnects": w.Disconnects,
		"send_errors": w.SendErr, "server_errors": w.ServerErrors,
		"errors":  w.ConnectErr + w.SignupErr + w.Disconnects + w.SendErr + w.APIErr + w.VBad + w.ABad,
		"mbps_up": float64(w.TxBytes) * 8 / s / 1e6, "mbps_down": float64(w.RxBytes) * 8 / s / 1e6,
		"mem_mb": cg.memMB, "mem_peak_mb": cg.peakMB, "cpu": cg.cpu, "load_cpu": load.cpu,
		"t_s": time.Since(r.start).Seconds(),
	}
	if step {
		row["cpu"], row["load_cpu"] = cg.cpuSince(), load.cpuSince()
		cg.markStep()
		load.markStep()
	}
	return row
}

func (r *ramp) newUser(idx int) *vuser {
	u := &vuser{r: r, idx: idx, added: time.Now(), chains: map[int]*chain{}, newCall: make(chan struct{}, 1)}
	r.mu.Lock()
	r.users = append(r.users, u)
	r.mu.Unlock()
	return u
}

// run signs the user up, connects, and keeps it connected (reconnecting
// after a drop) until the ramp ends.
func (u *vuser) run(usersF *os.File) {
	r := u.r
	name := "u" + strconv.Itoa(u.idx)
	for {
		a, err := signup(r.base, name)
		if err == nil {
			u.acct = a
			break
		}
		r.add(func(w *window) { w.SignupErr++ })
		if u.closing.Load() {
			return
		}
		time.Sleep(time.Second)
	}
	r.mu.Lock()
	r.byID[u.acct.ID] = u
	r.mu.Unlock()
	go u.sendVideo()
	go u.sendAudio()
	go u.chat()
	for !u.closing.Load() {
		c, err := r.d.dial(u.acct.Token, handlers{text: u.onText, media: u.onMedia})
		if err != nil {
			r.add(func(w *window) { w.ConnectErr++ })
			time.Sleep(time.Second)
			continue
		}
		u.mu.Lock()
		u.c = c
		u.mu.Unlock()
		<-c.done()
		u.mu.Lock()
		u.c = nil
		u.mu.Unlock()
		u.endCall()
		if u.closing.Load() {
			return
		}
		r.add(func(w *window) { w.Disconnects++ })
		time.Sleep(time.Second)
	}
}

func (u *vuser) conn() conn {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.c
}

func (u *vuser) endCall() {
	u.mu.Lock()
	u.callID, u.peer = 0, nil
	u.mu.Unlock()
	u.inCall.Store(false)
}

func (u *vuser) onText(b []byte) {
	var m msg
	if json.Unmarshal(b, &m) != nil {
		return
	}
	r := u.r
	switch m.Type {
	case "call":
		r.mu.Lock()
		peer := r.byID[m.Peer.ID]
		r.mu.Unlock()
		u.mu.Lock()
		first := u.callID == 0 && u.peer == nil
		u.callID, u.peer = m.CallID, peer
		u.mu.Unlock()
		if first {
			d := time.Since(u.added).Microseconds()
			r.add(func(w *window) { w.latJoin = append(w.latJoin, d) })
		}
		u.inCall.Store(true)
		select {
		case u.newCall <- struct{}{}:
		default:
		}
		go u.history(m.CallID)
	case "peer_left":
		u.endCall()
	case "chat":
		if m.From != "u"+strconv.Itoa(u.idx) {
			lat := nowUS() - m.SentUS
			r.add(func(w *window) { w.ChatRecv++; w.latChat = append(w.latChat, lat); w.RxBytes += int64(len(b)) })
		}
	case "error":
		r.add(func(w *window) { w.ServerErrors++ })
	}
}

// history loads the call's chat history, as the app does when a call opens.
func (u *vuser) history(callID int) {
	t := time.Now()
	st, _, err := request("GET", u.r.base+"/api/calls/"+strconv.Itoa(callID)+"/messages", u.acct.Token, nil)
	d := time.Since(t).Microseconds()
	u.r.add(func(w *window) {
		w.APIReqs++
		if err != nil || st != 200 {
			w.APIErr++
		} else {
			w.latAPI = append(w.latAPI, d)
		}
	})
}

func (u *vuser) onMedia(b []byte) {
	r := u.r
	recv := nowUS()
	if len(b) < headerLen {
		r.add(func(w *window) { w.VBad++ })
		return
	}
	h := parseHeader(b)
	ok := h.Flags&flagCompressed != 0 && inflate(h, b[headerLen:]) == nil
	lat := recv - h.SentUS
	u.mu.Lock()
	peer := u.peer
	u.mu.Unlock()
	sender := -1
	if peer != nil {
		sender = peer.idx
	}
	if h.Kind == kindVideo {
		onTime := ok && lat <= r.videoDeadline.Microseconds()
		u.mu.Lock()
		ch := u.chains[sender]
		if ch == nil {
			ch = &chain{lastSeq: -1, broken: true}
			u.chains[sender] = ch
		}
		if int64(h.Seq) != ch.lastSeq+1 {
			ch.broken = true
		}
		if h.Flags&flagKey != 0 && onTime {
			ch.broken = false
		} else if !onTime {
			ch.broken = true
		}
		shown := onTime && !ch.broken
		ch.lastSeq = int64(h.Seq)
		u.mu.Unlock()
		r.add(func(w *window) {
			w.VRecv++
			w.RxBytes += int64(len(b))
			w.latV = append(w.latV, lat)
			if !ok {
				w.VBad++
			}
			if onTime {
				w.VOnTime++
			}
			if shown {
				w.VShown++
			}
		})
	} else {
		onTime := ok && lat <= r.audioDeadline.Microseconds()
		r.add(func(w *window) {
			w.ARecv++
			w.RxBytes += int64(len(b))
			w.latA = append(w.latA, lat)
			if !ok {
				w.ABad++
			}
			if onTime {
				w.AOnTime++
			}
		})
	}
	if u.idx < 2 {
		r.probeMu.Lock()
		fmt.Fprintf(r.probe, "%d,%d,%d,%d,%d,%d,%d,%t\n", u.idx, sender, h.Kind, h.Seq, h.Flags&flagKey, h.SentUS, recv, ok)
		r.probeMu.Unlock()
	}
}

// sendVideo sends the clip's frames at 30 fps while the user is in a call,
// starting each call at a keyframe. sent_us is the frame's capture time, so
// time spent queued in the client (backpressure) counts as latency.
func (u *vuser) sendVideo() {
	r, c := u.r, u.r.clip
	gops := len(c.video) / c.gop
	pos := 0
	next := time.Now()
	for !u.closing.Load() {
		select {
		case <-u.newCall:
			pos = rand.IntN(gops) * c.gop
			u.r.logStart(u, kindVideo, u.vseq.Load(), pos)
		default:
		}
		time.Sleep(time.Until(next))
		next = next.Add(frameUS * time.Microsecond)
		cn := u.conn()
		if cn == nil || !u.inCall.Load() {
			continue
		}
		i := pos % len(c.video)
		pos++
		flags := uint8(0)
		if c.key[i] {
			flags = flagKey
		}
		m := mediaMessage(kindVideo, flags, u.vseq.Add(1)-1, next.Add(-frameUS*time.Microsecond).UnixMicro(), c.video[i])
		err := cn.sendMedia(kindVideo, m)
		r.add(func(w *window) {
			w.VSent++
			w.TxBytes += int64(len(m))
			if err != nil {
				w.SendErr++
			}
		})
	}
}

func (u *vuser) sendAudio() {
	r, c := u.r, u.r.clip
	pos := rand.IntN(len(c.audio))
	r.logStart(u, kindAudio, 0, pos)
	next := time.Now()
	for !u.closing.Load() {
		time.Sleep(time.Until(next))
		next = next.Add(audioUS * time.Microsecond)
		cn := u.conn()
		if cn == nil || !u.inCall.Load() {
			continue
		}
		p := c.audio[pos%len(c.audio)]
		pos++
		m := mediaMessage(kindAudio, 0, u.aseq.Add(1)-1, next.Add(-audioUS*time.Microsecond).UnixMicro(), p)
		err := cn.sendMedia(kindAudio, m)
		r.add(func(w *window) {
			w.ASent++
			w.TxBytes += int64(len(m))
			if err != nil {
				w.SendErr++
			}
		})
	}
}

// chat sends a message to the peer every chatEvery while in a call.
func (u *vuser) chat() {
	r := u.r
	time.Sleep(time.Duration(rand.Int64N(int64(r.chatEvery))))
	t := time.NewTicker(r.chatEvery)
	defer t.Stop()
	n := 0
	for !u.closing.Load() {
		<-t.C
		cn := u.conn()
		if cn == nil || !u.inCall.Load() {
			continue
		}
		n++
		b := []byte(fmt.Sprintf(`{"type":"chat","text":"message %d from u%d: are you seeing my screen ok?","sent_us":%d}`, n, u.idx, nowUS()))
		err := cn.sendText(b)
		r.add(func(w *window) {
			w.ChatSent++
			w.TxBytes += int64(len(b))
			if err != nil {
				w.SendErr++
			}
		})
	}
}

// logStart records where in the clip a probe user's track starts, so the
// quality pass can line received frames up with the source.
// Start lines: sender idx, -1, kind, the first seq sent from there, the
// clip position, 0, the time, "start". Audio starts once, video at each call.
func (r *ramp) logStart(u *vuser, kind uint8, seq uint32, pos int) {
	if u.idx >= 2 {
		return
	}
	r.probeMu.Lock()
	fmt.Fprintf(r.probe, "%d,-1,%d,%d,%d,0,%d,start\n", u.idx, kind, seq, pos, nowUS())
	r.probeMu.Unlock()
}

// helpers ------------------------------------------------------------------

func writeJSON(f *os.File, v any) {
	b, _ := json.Marshal(v)
	f.Write(append(b, '\n'))
}

func ratio(a, b int64) float64 {
	if b == 0 {
		return 0
	}
	return float64(a) / float64(b)
}

// pct is the p-th percentile of µs samples (100 is the max).
func pct(xs []int64, p float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	s := append([]int64(nil), xs...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	i := int(p / 100 * float64(len(s)-1))
	return float64(s[i])
}

// cgroup reads the server's memory and CPU, and notices OOM kills and exits.
type cgroup struct {
	dir                string
	memMB, peakMB, cpu float64
	gone, oom          bool
	lastUS, stepUS     int64
	lastT, stepT       time.Time
	oom0               int64
}

func newCgroup(dir string) *cgroup {
	c := &cgroup{dir: dir, lastT: time.Now(), stepT: time.Now()}
	if dir != "" {
		c.lastUS, c.stepUS = c.usage(), c.usage()
		c.oom0 = c.events()["oom_kill"]
	}
	return c
}

func (c *cgroup) read(name string) string {
	b, err := os.ReadFile(filepath.Join(c.dir, name))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func (c *cgroup) usage() int64 {
	for _, l := range strings.Split(c.read("cpu.stat"), "\n") {
		if v, ok := strings.CutPrefix(l, "usage_usec "); ok {
			n, _ := strconv.ParseInt(v, 10, 64)
			return n
		}
	}
	return 0
}

func (c *cgroup) events() map[string]int64 {
	m := map[string]int64{}
	for _, l := range strings.Split(c.read("memory.events"), "\n") {
		if k, v, ok := strings.Cut(l, " "); ok {
			m[k], _ = strconv.ParseInt(v, 10, 64)
		}
	}
	return m
}

func (c *cgroup) sample() {
	if c.dir == "" {
		return
	}
	if _, err := os.Stat(c.dir); err != nil {
		c.gone = true
		return
	}
	if v, err := strconv.ParseFloat(c.read("memory.current"), 64); err == nil {
		c.memMB = v / (1 << 20)
	}
	if v, err := strconv.ParseFloat(c.read("memory.peak"), 64); err == nil {
		c.peakMB = v / (1 << 20)
	}
	if c.events()["oom_kill"] > c.oom0 {
		c.oom = true
	}
	now, us := time.Now(), c.usage()
	c.cpu = float64(us-c.lastUS) / float64(now.Sub(c.lastT).Microseconds())
	c.lastUS, c.lastT = us, now
}

func (c *cgroup) cpuSince() float64 {
	if c.dir == "" {
		return 0
	}
	return float64(c.lastUS-c.stepUS) / float64(c.lastT.Sub(c.stepT).Microseconds()+1)
}
func (c *cgroup) markStep() { c.stepUS, c.stepT = c.lastUS, c.lastT }

// selfCPU is the load generator's own CPU use, in cores.
type selfCPU struct {
	cpu            float64
	last, stepTick int64
	lastT, stepT   time.Time
}

func newSelfCPU() *selfCPU {
	s := &selfCPU{lastT: time.Now(), stepT: time.Now()}
	s.last = s.ticks()
	s.stepTick = s.last
	return s
}

func (s *selfCPU) ticks() int64 {
	b, err := os.ReadFile("/proc/self/stat")
	if err != nil {
		return 0
	}
	f := strings.Fields(string(b[strings.LastIndexByte(string(b), ')')+2:]))
	u, _ := strconv.ParseInt(f[11], 10, 64)
	k, _ := strconv.ParseInt(f[12], 10, 64)
	return u + k
}

func (s *selfCPU) sample() {
	now, t := time.Now(), s.ticks()
	s.cpu = float64(t-s.last) / 100 / now.Sub(s.lastT).Seconds()
	s.last, s.lastT = t, now
}
func (s *selfCPU) cpuSince() float64 {
	return float64(s.last-s.stepTick) / 100 / (s.lastT.Sub(s.stepT).Seconds() + 1e-9)
}
func (s *selfCPU) markStep() { s.stepTick, s.stepT = s.last, s.lastT }

// healthProbe asks /health every 2 s.
type healthProbe struct {
	base string
	ok   atomic.Bool
}

func (h *healthProbe) loop() {
	for {
		st, _, err := request("GET", h.base+"/health", "", nil)
		h.ok.Store(err == nil && st == 200)
		time.Sleep(2 * time.Second)
	}
}
