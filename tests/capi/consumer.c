/* tests/capi/consumer.c - a C consumer of libanole, and the C ABI's test suite.
 *
 *   consumer test                 the suite (exit 0 = pass)
 *   consumer serve <executors> <port> [consumers]
 *                                 benchmark server: GET /native (fixed
 *                                 response, on the protocol's reader),
 *                                 GET /native-task (the same on a task of
 *                                 its own), GET /hello and GET /users/:id
 *                                 (answered by consumer threads), POST
 *                                 /echo; runs until stdin closes
 *
 * Uses only include/anole.h. Each consumer thread waits on the doorbell fd
 * with poll(2) (an eventfd on Linux, a pipe on macOS), drains with
 * anole_poll, and answers in the same batch.
 */
#define _GNU_SOURCE
#include "anole.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CHECK(x)                                                                                    \
  do {                                                                                              \
    if (!(x)) {                                                                                     \
      anole_str e_ = anole_last_error();                                                            \
      fprintf(stderr, "FAIL %s:%d: %s (last error: %.*s)\n", __FILE__, __LINE__, #x, (int)e_.len, \
              e_.ptr);                                                                              \
      exit(1);                                                                                      \
    }                                                                                               \
  } while (0)

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static atomic_int log_lines;
static void on_log(void *ud, int level, anole_str scope, anole_str msg) {
  (void)ud;
  atomic_fetch_add(&log_lines, 1);
  if (level <= ANOLE_LOG_WARN || getenv("CAPI_LOG"))
    fprintf(stderr, "[%d %.*s] %.*s\n", level, (int)scope.len, scope.ptr, (int)msg.len, msg.ptr);
}

static anole_server *make_server(const char *json) {
  anole_server_options o = {sizeof o, {json, strlen(json)}, 0, 0, on_log, NULL};
  anole_server *s = NULL;
  CHECK(anole_server_create(&o, &s) == ANOLE_OK);
  return s;
}

/* ---- a tiny blocking HTTP/1.1 client ------------------------------------------ */

static int dial(uint16_t port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  CHECK(fd >= 0);
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  CHECK(connect(fd, (struct sockaddr *)&a, sizeof a) == 0);
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  return fd;
}

#define BODY_MAX (512 * 1024)

typedef struct {
  int status;
  char head[2048];
  char *body; /* BODY_MAX + 1 */
  size_t body_len;
  int eof; /* the connection closed before a whole response */
} response;

static void response_init(response *r) {
  memset(r, 0, sizeof *r);
  r->body = malloc(BODY_MAX + 1);
  CHECK(r->body);
}
static void response_free(response *r) { free(r->body); }

typedef struct {
  int fd;
  char buf[64 * 1024];
  size_t len, pos;
} conn_reader;

static int fill(conn_reader *c) {
  if (c->pos > 0) {
    memmove(c->buf, c->buf + c->pos, c->len - c->pos);
    c->len -= c->pos;
    c->pos = 0;
  }
  if (c->len == sizeof c->buf) return 0;
  ssize_t k = read(c->fd, c->buf + c->len, sizeof c->buf - c->len);
  if (k <= 0) return 0;
  c->len += (size_t)k;
  return 1;
}

/* A line ending in \r\n, without it; NULL at the end of the stream. */
static char *line(conn_reader *c) {
  for (;;) {
    char *p = memmem(c->buf + c->pos, c->len - c->pos, "\r\n", 2);
    if (p) {
      *p = 0;
      char *l = c->buf + c->pos;
      c->pos = (size_t)(p + 2 - c->buf);
      return l;
    }
    if (!fill(c)) return NULL;
  }
}

static int take(conn_reader *c, char *out, size_t n) {
  while (n > 0) {
    if (c->pos == c->len && !fill(c)) return 0;
    size_t k = c->len - c->pos < n ? c->len - c->pos : n;
    memcpy(out, c->buf + c->pos, k);
    c->pos += k;
    out += k;
    n -= k;
  }
  return 1;
}

/* Reads one response (Content-Length or chunked). */
static void read_response(conn_reader *c, response *r, int head_only) {
  r->status = 0;
  r->body_len = 0;
  r->eof = 0;
  r->head[0] = 0;
  char *l = line(c);
  if (!l) {
    r->eof = 1;
    return;
  }
  r->status = atoi(l + 9);
  size_t clen = 0;
  int chunked = 0, have_len = 0;
  for (;;) {
    l = line(c);
    if (!l) {
      r->eof = 1;
      return;
    }
    if (!*l) break;
    if (strlen(r->head) + strlen(l) + 2 < sizeof r->head) {
      strcat(r->head, l);
      strcat(r->head, "\n");
    }
    if (!strncasecmp(l, "content-length:", 15)) clen = strtoul(l + 15, NULL, 10), have_len = 1;
    if (!strncasecmp(l, "transfer-encoding:", 18) && strcasestr(l, "chunked")) chunked = 1;
  }
  if (head_only || r->status == 101) return;
  if (chunked) {
    for (;;) {
      l = line(c);
      if (!l) {
        r->eof = 1;
        return;
      }
      size_t n = strtoul(l, NULL, 16);
      if (n == 0) {
        while ((l = line(c)) && *l) {} /* trailers */
        break;
      }
      CHECK(r->body_len + n <= BODY_MAX);
      if (!take(c, r->body + r->body_len, n)) {
        r->eof = 1;
        return;
      }
      r->body_len += n;
      line(c);
    }
  } else if (have_len) {
    CHECK(clen <= BODY_MAX);
    if (!take(c, r->body, clen)) {
      r->eof = 1;
      return;
    }
    r->body_len = clen;
  }
  r->body[r->body_len] = 0;
}

static void send_request(int fd, const char *method, const char *path, const char *body, size_t body_len) {
  char head[512];
  int n = snprintf(head, sizeof head, "%s %s HTTP/1.1\r\nHost: x\r\nX-Test: Value\r\nContent-Length: %zu\r\n\r\n",
                   method, path, body_len);
  CHECK(write(fd, head, n) == n);
  size_t off = 0;
  while (off < body_len) {
    ssize_t k = write(fd, body + off, body_len - off);
    if (k <= 0) break; /* the server answered early (413) and closed */
    off += (size_t)k;
  }
}

static void roundtrip(conn_reader *c, const char *method, const char *path, const char *body, size_t body_len,
                      response *r) {
  send_request(c->fd, method, path, body, body_len);
  read_response(c, r, 0);
}

static void request(uint16_t port, const char *method, const char *path, const char *body, response *r) {
  static __thread conn_reader c;
  c.fd = dial(port);
  c.len = c.pos = 0;
  roundtrip(&c, method, path, body, body ? strlen(body) : 0, r);
  close(c.fd);
}

/* ---- consumers ------------------------------------------------------------------ */

typedef struct consumer_state consumer_state;
typedef void (*on_event_fn)(consumer_state *cs, const anole_event *ev);

struct consumer_state {
  anole_consumer *c;
  on_event_fn on_event;
  pthread_t thread;
  atomic_int stopped;
  atomic_int paused; /* tests: stop polling for a while */
  atomic_int ws_big; /* tests: large WebSocket messages taken (not echoed) */
  int use_wait; /* anole_poll_wait instead of the fd */
  _Alignas(8) unsigned char buf[1088 * 1024]; /* a 1000 KiB WebSocket message fits */
  /* for tests */
  anole_req held[64];
  atomic_int nheld;
  atomic_int sent, aborts, ws_open, ws_msgs, ws_closes, last_close_code;
  atomic_uintptr_t last_sent;
  atomic_ullong ws_handle;
  atomic_ullong last_abort; /* the handle of the latest ANOLE_EV_ABORT */
  uint64_t batches, events;
  int spin_us; /* serve: CAPI_SPIN_US */
};

static void dispatch(consumer_state *cs, int64_t n) {
  cs->batches++;
  for (int64_t off = 0; off < n;) {
    const anole_event *ev = (const anole_event *)(cs->buf + off);
    CHECK(ev->len >= sizeof(anole_event) && (ev->len & 7) == 0 && off + ev->len <= n);
    if (ev->type == ANOLE_EV_STOPPED) {
      atomic_store(&cs->stopped, 1);
    } else {
      cs->events++;
      cs->on_event(cs, ev);
    }
    off += ev->len;
  }
}

static void *consumer_main(void *arg) {
  consumer_state *cs = arg;
  if (cs->use_wait) {
    while (!atomic_load(&cs->stopped)) {
      int64_t n = anole_poll_wait(cs->c, cs->buf, sizeof cs->buf, 1000);
      CHECK(n >= 0);
      if (n > 0) dispatch(cs, n);
    }
    return NULL;
  }
  int fd = anole_consumer_fd(cs->c);
  while (!atomic_load(&cs->stopped)) {
    if (atomic_load(&cs->paused)) {
      usleep(1000);
      continue;
    }
    struct pollfd p = {fd, POLLIN, 0};
    int pr = poll(&p, 1, 1000);
    if (pr < 0 && errno != EINTR) break;
    double idle_since = 0;
    for (;;) {
      /* Optionally spin (NOARM polls) for spin_us before arming the doorbell. */
      int64_t n = anole_poll(cs->c, cs->buf, sizeof cs->buf, cs->spin_us > 0 ? ANOLE_POLL_NOARM : 0);
      CHECK(n >= 0);
      if (n == 0 && cs->spin_us > 0) {
        double t = now_ms();
        if (idle_since == 0) idle_since = t;
        if ((t - idle_since) * 1000.0 < cs->spin_us) continue;
        n = anole_poll(cs->c, cs->buf, sizeof cs->buf, 0);
        CHECK(n >= 0);
      }
      if (n == 0) break;
      idle_since = 0;
      dispatch(cs, n);
      if (atomic_load(&cs->stopped)) return NULL;
    }
  }
  return NULL;
}

static void start_consumer(consumer_state *cs) { CHECK(pthread_create(&cs->thread, NULL, consumer_main, cs) == 0); }

static anole_str header_of(const anole_request_event *r, const char *name) {
  const anole_span *sp = anole_request_spans(r);
  for (uint16_t i = 0; i < r->nheaders; i++) {
    anole_str k = anole_event_str(r, sp[2 * i]);
    if (k.len == strlen(name) && memcmp(k.ptr, name, k.len) == 0) return anole_event_str(r, sp[2 * i + 1]);
  }
  anole_str none = {NULL, 0};
  return none;
}

static anole_str param_of(const anole_request_event *r, const char *name) {
  const anole_span *sp = anole_request_spans(r) + 2 * r->nheaders;
  for (uint16_t i = 0; i < r->nparams; i++) {
    anole_str k = anole_event_str(r, sp[2 * i]);
    if (k.len == strlen(name) && memcmp(k.ptr, name, k.len) == 0) return anole_event_str(r, sp[2 * i + 1]);
  }
  anole_str none = {NULL, 0};
  return none;
}

static int str_is(anole_str s, const char *want) { return s.len == strlen(want) && memcmp(s.ptr, want, s.len) == 0; }

static int str_has(anole_str s, const char *want) {
  size_t n = strlen(want);
  for (size_t i = 0; i + n <= s.len; i++)
    if (memcmp(s.ptr + i, want, n) == 0) return 1;
  return 0;
}

static const anole_header text_plain[] = {{{"content-type", 12}, {"text/plain", 10}}};

#define BIG_LEN (200 * 1024)
static char big_body[BIG_LEN];
static char file_path[64];
static anole_server *current_server;

enum {
  R_HELLO = 1,
  R_ECHO = 2,
  R_HOLD = 3,
  R_USER = 4,
  R_RELEASE = 5,
  R_BORROW = 6,
  R_STREAM = 7,
  R_FILE = 8,
  R_SHORT = 9,
  R_WS = 10,
  R_HEAD = 11,
};

/* Reads a streamed request body whole (blocking: this is a test). */
static size_t read_body(anole_req h, char *out, size_t cap) {
  size_t n = 0;
  for (;;) {
    int64_t k = anole_req_read(h, out + n, cap - n, 2000);
    CHECK(k >= 0);
    if (k == 0) return n;
    n += (size_t)k;
    CHECK(n < cap);
  }
}

static void on_request(consumer_state *cs, const anole_request_event *r) {
  anole_req h = r->ev.handle;
  switch (r->route_id) {
  case R_HELLO:
    CHECK(anole_respond(h, 200, text_plain, 1, "Hello, World!", 13, 0) == ANOLE_OK);
    break;
  case R_ECHO: {
    if (r->flags & ANOLE_REQ_BODY_INLINE) {
      anole_str b = anole_event_str(r, r->body);
      CHECK(anole_respond(h, 200, text_plain, 1, b.ptr, b.len, 0) == ANOLE_OK);
    } else {
      CHECK(r->flags & ANOLE_REQ_BODY_STREAM);
      CHECK(r->body.len == 0);
      static char body[BODY_MAX];
      size_t n = read_body(h, body, sizeof body);
      CHECK(r->content_length == UINT64_MAX || r->content_length == n);
      CHECK(anole_respond(h, 200, text_plain, 1, body, n, 0) == ANOLE_OK);
    }
    break;
  }
  case R_HOLD:
  case R_SHORT: {
    int i = atomic_load(&cs->nheld);
    CHECK(i < 64);
    cs->held[i] = h;
    atomic_store(&cs->nheld, i + 1); /* after the handle: wait_for(nheld) then reads it */
    break;
  }
  case R_USER: {
    anole_str id = param_of(r, "id");
    anole_str xt = header_of(r, "x-test");
    char out[256];
    int n = snprintf(out, sizeof out, "user %.*s %.*s %.*s", (int)id.len, id.ptr, (int)xt.len, xt.ptr,
                     (int)r->query.len, (const char *)r + r->query.off);
    CHECK(anole_respond(h, 200, text_plain, 1, out, (size_t)n, 0) == ANOLE_OK);
    break;
  }
  case R_RELEASE:
    CHECK(anole_release(h) == ANOLE_OK);
    break;
  case R_BORROW:
    CHECK(anole_respond(h, 200, text_plain, 1, big_body, BIG_LEN, ANOLE_BODY_BORROW) == ANOLE_OK);
    break;
  case R_STREAM: {
    CHECK(anole_stream_start(h, 200, text_plain, 1) == ANOLE_OK);
    CHECK(anole_stream_write(h, "one,", 4, 0) == ANOLE_OK);
    CHECK(anole_stream_write(h, big_body, 1000, ANOLE_BODY_BORROW) == ANOLE_OK);
    CHECK(anole_stream_write_wait(h, ",two", 4, 1000) == ANOLE_OK);
    anole_header tr = {{"x-trailer", 9}, {"done", 4}};
    CHECK(anole_stream_end(h, &tr, 1) == ANOLE_OK);
    CHECK(anole_stream_write(h, "late", 4, 0) == ANOLE_E_GONE);
    break;
  }
  case R_FILE: {
    int fd = open(file_path, O_RDONLY);
    CHECK(fd >= 0);
    CHECK(anole_respond_fd(h, 200, text_plain, 1, fd, 6, 5) == ANOLE_OK);
    close(fd);
    break;
  }
  case R_HEAD: {
    /* the record itself: method, version, remote, listener, flags */
    char out[512];
    anole_str m = anole_event_str(r, r->method_name), ra = anole_event_str(r, r->remote_addr),
              ln = anole_event_str(r, r->listener), id = anole_event_str(r, r->id);
    int n = snprintf(out, sizeof out, "%d %.*s %d %d %.*s %.*s %zu", r->method, (int)m.len, m.ptr, r->version,
                     (r->flags & ANOLE_REQ_SECURE) != 0, (int)ln.len, ln.ptr, (int)ra.len, ra.ptr, id.len);
    /* No TLS here, so no client certificate. */
    CHECK((r->flags & ANOLE_REQ_PEER_CERT) == 0 && r->peer_cert == 0 && anole_request_peer_cert(r).len == 0);
    CHECK(anole_respond(h, 200, text_plain, 1, out, (size_t)n, 0) == ANOLE_OK);
    break;
  }
  default:
    CHECK(anole_respond(h, 404, NULL, 0, NULL, 0, 0) == ANOLE_OK);
  }
}

static void on_event(consumer_state *cs, const anole_event *ev) {
  switch (ev->type) {
  case ANOLE_EV_REQUEST:
    on_request(cs, (const anole_request_event *)ev);
    break;
  case ANOLE_EV_SENT: {
    const anole_sent_event *s = (const anole_sent_event *)ev;
    atomic_store(&cs->last_sent, (uintptr_t)s->data);
    atomic_fetch_add(&cs->sent, 1);
    break;
  }
  case ANOLE_EV_ABORT:
    atomic_store(&cs->last_abort, ev->handle);
    atomic_fetch_add(&cs->aborts, 1);
    break;
  case ANOLE_EV_WS_OPEN: {
    const anole_request_event *r = (const anole_request_event *)ev;
    CHECK(r->route_id == R_WS);
    CHECK(str_is(anole_event_str(r, r->path), "/ws"));
    anole_str room = {"room", 4};
    CHECK(anole_ws_subscribe(ev->handle, room) == ANOLE_OK);
    atomic_store(&cs->ws_handle, ev->handle);
    atomic_fetch_add(&cs->ws_open, 1);
    break;
  }
  case ANOLE_EV_WS_MESSAGE: {
    const anole_ws_message_event *m = (const anole_ws_message_event *)ev;
    anole_str d = anole_event_str(m, m->data);
    atomic_fetch_add(&cs->ws_msgs, 1);
    if (d.len > 1000) {
      atomic_fetch_add(&cs->ws_big, 1);
    } else if (str_is(d, "bye")) {
      anole_str why = {"bye", 3};
      CHECK(anole_ws_close(ev->handle, 1000, why) == ANOLE_OK);
    } else if (str_is(d, "pub")) {
      anole_str room = {"room", 4};
      CHECK(anole_ws_publish(current_server, room, ANOLE_WS_TEXT, "news", 4, 0) == ANOLE_OK);
    } else {
      CHECK(anole_ws_send(ev->handle, (int)m->type, d.ptr, d.len, 0) == ANOLE_OK);
    }
    break;
  }
  case ANOLE_EV_WS_CLOSE: {
    const anole_ws_close_event *c = (const anole_ws_close_event *)ev;
    atomic_store(&cs->last_close_code, c->code);
    atomic_fetch_add(&cs->ws_closes, 1);
    CHECK(anole_ws_send(ev->handle, ANOLE_WS_TEXT, "x", 1, 0) == ANOLE_E_GONE);
    break;
  }
  case ANOLE_EV_BODY:
  case ANOLE_EV_WRITABLE:
  case ANOLE_EV_WS_DRAIN:
    break;
  default:
    CHECK(!"unknown event type");
  }
}

/* ---- a tiny WebSocket client ------------------------------------------------------- */

static void ws_send_frame(int fd, int opcode, const char *data, size_t len) {
  unsigned char hdr[8] = {(unsigned char)(0x80 | opcode), (unsigned char)(0x80 | len), 1, 2, 3, 4};
  CHECK(len < 126);
  unsigned char payload[128];
  for (size_t i = 0; i < len; i++) payload[i] = (unsigned char)data[i] ^ hdr[2 + (i & 3)];
  CHECK(write(fd, hdr, 6) == 6);
  if (len) CHECK(write(fd, payload, len) == (ssize_t)len);
}

/* Writes binary frames of `len` bytes (zero mask) without blocking until the
   server stops taking them for 500 ms or `max` are out; finishes a frame cut
   short, blocking, once `paused` (the consumer's) is cleared. Returns the
   frames sent; *accepted: the bytes the server took before it stopped. */
static int ws_flood(int fd, size_t len, int max, size_t *accepted, atomic_int *paused) {
  size_t flen = 14 + len;
  unsigned char *f = calloc(1, flen);
  CHECK(f);
  f[0] = 0x82;
  f[1] = 0x80 | 127;
  for (int i = 0; i < 8; i++) f[2 + i] = (unsigned char)((uint64_t)len >> (56 - 8 * i));
  for (size_t i = 0; i < len; i++) f[14 + i] = (unsigned char)(i * 31 + 7);
  int fl = fcntl(fd, F_GETFL);
  CHECK(fcntl(fd, F_SETFL, fl | O_NONBLOCK) == 0);
  int sent = 0;
  size_t off = 0;
  double progress = now_ms();
  while (sent < max) {
    ssize_t n = write(fd, f + off, flen - off);
    if (n > 0) {
      off += (size_t)n;
      progress = now_ms();
      if (off == flen) {
        sent++;
        off = 0;
      }
      continue;
    }
    CHECK(n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));
    if (now_ms() - progress > 500) break;
    usleep(1000);
  }
  *accepted = (size_t)sent * flen + off;
  atomic_store(paused, 0);
  CHECK(fcntl(fd, F_SETFL, fl) == 0);
  if (off > 0) {
    CHECK(write(fd, f + off, flen - off) == (ssize_t)(flen - off));
    sent++;
  }
  free(f);
  return sent;
}

/* One frame from the server: its opcode, payload in out (NUL-terminated). */
static int ws_read_frame(conn_reader *c, char *out, size_t cap, size_t *len) {
  unsigned char h[2];
  if (!take(c, (char *)h, 2)) return -1;
  size_t n = h[1] & 0x7f;
  if (n == 126) {
    unsigned char l[2];
    CHECK(take(c, (char *)l, 2));
    n = ((size_t)l[0] << 8) | l[1];
  }
  CHECK(n + 1 <= cap);
  CHECK(take(c, out, n));
  out[n] = 0;
  *len = n;
  return h[0] & 0x0f;
}

static void ws_connect(conn_reader *c, uint16_t port) {
  c->fd = dial(port);
  c->len = c->pos = 0;
  const char *req = "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
  CHECK(write(c->fd, req, strlen(req)) == (ssize_t)strlen(req));
  response r;
  response_init(&r);
  read_response(c, &r, 1);
  CHECK(r.status == 101);
  CHECK(strstr(r.head, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
  response_free(&r);
}

/* ---- the suite ------------------------------------------------------------------------ */

/* Built without WebSocket (-Dprofile=minimal), the suite leaves it out. */
static int have_websocket;
static const char *ws_route = "{\"path\":\"/ws\",\"websocket\":{\"handler\":10}},";

static const char *test_config =
    "{\"listeners\":[{\"name\":\"main\",\"address\":\"127.0.0.1\",\"port\":0}],\"executors\":%d,"
    "\"limits\":{\"inline_body_max\":65536,\"body_max\":%d,\"max_inflight\":%d},"
    "\"timeouts\":{\"request_ms\":%d,\"shutdown_ms\":%d},"
    "\"middleware\":[{\"request_id\":{}}],"
    "\"routes\":["
    "{\"method\":\"GET\",\"path\":\"/native\",\"respond\":{\"status\":200,\"body\":\"native\","
    "\"headers\":{\"content-type\":\"text/plain\"}}},"
    "{\"method\":\"GET\",\"path\":\"/hello\",\"handler\":1},"
    "{\"method\":\"POST\",\"path\":\"/echo\",\"handler\":2},"
    "{\"method\":\"GET\",\"path\":\"/hold\",\"handler\":3},"
    "{\"method\":\"GET\",\"path\":\"/users/:id\",\"handler\":4},"
    "{\"method\":\"GET\",\"path\":\"/release\",\"handler\":5},"
    "{\"method\":\"GET\",\"path\":\"/borrow\",\"handler\":6},"
    "{\"method\":\"GET\",\"path\":\"/stream\",\"handler\":7},"
    "{\"method\":\"GET\",\"path\":\"/file\",\"handler\":8},"
    "{\"method\":\"GET\",\"path\":\"/short\",\"handler\":9,\"timeout_ms\":150},"
    "%s"
    "{\"method\":\"PUT\",\"path\":\"/head\",\"handler\":11},"
    "{\"method\":\"GET\",\"path\":\"/cached\",\"handler\":1,\"cache\":{\"ttl_ms\":60000}}],"
    "\"observe\":{\"health\":{},\"metrics\":{}}}";

typedef struct {
  uint16_t port;
  const char *path;
  response r;
  double ms;
} async_req;

static void *async_get(void *arg) {
  async_req *a = arg;
  double t0 = now_ms();
  request(a->port, "GET", a->path, NULL, &a->r);
  a->ms = now_ms() - t0;
  return NULL;
}

typedef struct {
  uint16_t port;
  int id, n, failures;
} hammer_arg;

static void *hammer(void *arg) {
  hammer_arg *h = arg;
  static __thread conn_reader c;
  c.fd = dial(h->port);
  c.len = c.pos = 0;
  response r;
  response_init(&r);
  for (int i = 0; i < h->n; i++) {
    char path[64], want[128];
    snprintf(path, sizeof path, "/users/%d-%d?q=%d", h->id, i, i);
    snprintf(want, sizeof want, "user %d-%d Value q=%d", h->id, i, i);
    roundtrip(&c, "GET", path, NULL, 0, &r);
    if (r.status != 200 || strcmp(r.body, want) != 0) h->failures++;
  }
  response_free(&r);
  close(c.fd);
  return NULL;
}

static int wait_for(atomic_int *v, int n) {
  for (int i = 0; i < 1000 && atomic_load(v) < n; i++) usleep(2000);
  return atomic_load(v) >= n;
}

static void test_basics(void) {
  CHECK((anole_abi_version() >> 16) == ANOLE_ABI_VERSION_MAJOR);
  CHECK((anole_abi_version() & 0xffff) >= ANOLE_ABI_VERSION_MINOR);
  anole_str v = anole_version();
  CHECK(v.len > 0 && v.ptr[0] >= '0' && v.ptr[0] <= '9');
  anole_str http2 = {"http2", 5}, nope = {"nope", 4};
  int h2 = anole_has_feature(http2);
  CHECK(h2 == 0 || h2 == 1);
  CHECK(anole_has_feature(nope) == 0);
  /* bad configuration, with the place in anole_last_error */
  const char *bad[] = {
      "{\"routes\":[{\"path\":\"/x\"}]}",
      "{\"nope\":1}",
      "{\"routes\":[{\"path\":\"/x\",\"handler\":1,\"respond\":{}}]}",
      "{\"listeners\":[{\"port\":70000}]}",
      "{\"routes\":[{\"method\":\"FETCH\",\"path\":\"/x\",\"handler\":1}]}",
      "{\"middleware\":[{\"jwt\":{}}]}",
      "not json",
  };
  for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
    anole_server_options o = {sizeof o, {bad[i], strlen(bad[i])}, 0, 0, NULL, NULL};
    anole_server *s = NULL;
    CHECK(anole_server_create(&o, &s) == ANOLE_E_CONFIG && s == NULL);
    CHECK(anole_last_error().len > 0);
  }
  anole_server_options o = {sizeof o, {"{}", 2}, 0x80, 0, NULL, NULL};
  anole_server *s = NULL;
  CHECK(anole_server_create(&o, &s) == ANOLE_E_INVALID);
  /* an options struct from an older header (smaller size) reads as zeros */
  anole_server_options small = {offsetof(anole_server_options, log_level), {"{}", 2}, 0, 99, NULL, NULL};
  CHECK(anole_server_create(&small, &s) == ANOLE_OK);
  /* routes name handlers: a consumer must be attached first */
  anole_server_destroy(s);
  const char *needs = "{\"listeners\":[{\"port\":0}],\"routes\":[{\"path\":\"/x\",\"handler\":1}]}";
  anole_server_options n = {sizeof n, {needs, strlen(needs)}, 0, 0, NULL, NULL};
  CHECK(anole_server_create(&n, &s) == ANOLE_OK);
  CHECK(anole_server_start(s) == ANOLE_E_STATE);
  anole_server_destroy(s);
  anole_server_destroy(NULL);
  printf("ok basics\n");
}

/* Route tables come from user code in bindings (app.get calls collected into
   the JSON), so a conflict is a user mistake: ANOLE_E_CONFIG naming the
   routes, never a panic that takes the host process with it. */
static void test_route_conflicts(void) {
#define LISTEN "{\"listeners\":[{\"address\":\"127.0.0.1\",\"port\":0}],"
#define OK200 "\"respond\":{\"status\":200}"
  static const struct {
    const char *json, *names;
  } cases[] = {
      /* the same route twice */
      {LISTEN "\"routes\":[{\"method\":\"GET\",\"path\":\"/\"," OK200 "},{\"method\":\"GET\",\"path\":\"/\"," OK200 "}]}",
       "GET /"},
      /* one parameter position, two names */
      {LISTEN "\"routes\":[{\"method\":\"GET\",\"path\":\"/users/:id\"," OK200
              "},{\"method\":\"GET\",\"path\":\"/users/:name/posts\"," OK200 "}]}",
       "/users/:name/posts"},
      /* a method route less specific than an any-method one */
      {LISTEN "\"routes\":[{\"path\":\"/a/b\"," OK200 "},{\"method\":\"GET\",\"path\":\"/a/:x\"," OK200 "}]}", "/a/:x"},
      /* a consumer route on a static prefix's own path */
      {LISTEN "\"routes\":[{\"path\":\"/assets\",\"static\":{\"dir\":\".\"}},"
              "{\"method\":\"GET\",\"path\":\"/assets/*rest\",\"handler\":1}]}",
       "/assets/*rest"},
      /* a route on the metrics path, which Anole adds while starting */
      {LISTEN "\"observe\":{\"metrics\":{}},\"routes\":[{\"method\":\"GET\",\"path\":\"/metrics\"," OK200 "}]}",
       "/metrics"},
  };
#undef LISTEN
#undef OK200
  for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
    anole_server_options o = {sizeof o, {cases[i].json, strlen(cases[i].json)}, 0, 0, NULL, NULL};
    anole_server *s = NULL;
    int rc = anole_server_create(&o, &s);
    if (rc == ANOLE_OK) {
      anole_consumer *c = NULL;
      anole_consumer_options co = {sizeof co, NULL, NULL, 0};
      CHECK(anole_consumer_attach(s, &co, &c) == ANOLE_OK);
      rc = anole_server_start(s);
    }
    anole_str why = anole_last_error();
    if (rc != ANOLE_E_CONFIG) fprintf(stderr, "route conflict case %zu: %d\n", i, rc);
    CHECK(rc == ANOLE_E_CONFIG);
    /* the message names the route */
    CHECK(why.len > 0 && memmem(why.ptr, why.len, cases[i].names, strlen(cases[i].names)) != NULL);
    anole_server_destroy(s);
  }
  /* and a server without conflicts still starts after them */
  const char *fine = "{\"listeners\":[{\"address\":\"127.0.0.1\",\"port\":0}],\"routes\":[{\"method\":\"GET\","
                     "\"path\":\"/users/:id\",\"respond\":{\"status\":200}},{\"method\":\"GET\",\"path\":"
                     "\"/users/:id/posts\",\"respond\":{\"status\":200}}]}";
  anole_server *s = make_server(fine);
  CHECK(anole_server_start(s) == ANOLE_OK);
  CHECK(anole_server_drain(s) == ANOLE_OK);
  CHECK(anole_server_wait(s, 5000) == ANOLE_OK);
  anole_server_destroy(s);
  printf("ok route conflicts: ANOLE_E_CONFIG naming the routes, no panic\n");
}

static void test_main_server(void) {
  char json[4096];
  snprintf(json, sizeof json, test_config, 4, 128 * 1024, 64, 400, 600, have_websocket ? ws_route : "");
  anole_server *s = make_server(json);
  current_server = s;

  {
    anole_server *s2 = NULL;
    anole_server_options o = {sizeof o, {"{}", 2}, 0, 0, NULL, NULL};
    CHECK(anole_server_create(&o, &s2) == ANOLE_E_STATE);
  }
  static consumer_state cs;
  cs.on_event = on_event;
  anole_consumer_options co = {sizeof co, NULL, NULL, 0};
  CHECK(anole_consumer_attach(s, &co, &cs.c) == ANOLE_OK);
  CHECK(anole_consumer_fd(cs.c) >= 0);
  CHECK(anole_server_start(s) == ANOLE_OK);
  CHECK(anole_server_start(s) == ANOLE_E_STATE);
  {
    anole_consumer *late = NULL;
    CHECK(anole_consumer_attach(s, &co, &late) == ANOLE_E_STATE && late == NULL);
  }
  uint16_t port = 0;
  CHECK(anole_server_port(s, 0, &port) == ANOLE_OK && port != 0);
  CHECK(anole_server_port(s, 1, &port) == ANOLE_E_INVALID);
  start_consumer(&cs);

  response r;
  response_init(&r);
  request(port, "GET", "/native", NULL, &r);
  CHECK(r.status == 200 && strcmp(r.body, "native") == 0);
  request(port, "GET", "/hello", NULL, &r);
  CHECK(r.status == 200 && strcmp(r.body, "Hello, World!") == 0);
  CHECK(strcasestr(r.head, "x-request-id:")); /* native middleware ran */
  request(port, "GET", "/users/42?a=b", NULL, &r);
  CHECK(r.status == 200 && strcmp(r.body, "user 42 Value a=b") == 0);
  request(port, "POST", "/echo", "the body", &r);
  CHECK(r.status == 200 && strcmp(r.body, "the body") == 0);
  request(port, "GET", "/release", NULL, &r);
  CHECK(r.status == 500);
  request(port, "GET", "/nope", NULL, &r);
  CHECK(r.status == 404);
  request(port, "PUT", "/head", NULL, &r);
  CHECK(r.status == 200);
  {
    char want[64];
    snprintf(want, sizeof want, "4 PUT 11 0 main 127.0.0.1:");
    CHECK(strncmp(r.body, want, strlen(want)) == 0);
    CHECK(strstr(r.body, " 0") != r.body + strlen(r.body) - 2); /* a request id */
  }
  request(port, "GET", "/healthz", NULL, &r);
  CHECK(r.status == 200);
  printf("ok routes\n");

  /* bodies: 64 KiB inline; 100 KiB streamed (anole_req_read); past body_max 413 */
  {
    static char big[200 * 1024];
    memset(big, 'a', sizeof big);
    for (size_t i = 0; i < sizeof big; i += 1000) big[i] = (char)('0' + (i / 1000) % 10);
    static conn_reader c;
    c.fd = dial(port);
    c.len = c.pos = 0;
    roundtrip(&c, "POST", "/echo", big, 65536, &r);
    CHECK(r.status == 200 && r.body_len == 65536 && memcmp(r.body, big, 65536) == 0);
    roundtrip(&c, "POST", "/echo", big, 100 * 1024, &r);
    CHECK(r.status == 200 && r.body_len == 100 * 1024 && memcmp(r.body, big, 100 * 1024) == 0);
    close(c.fd);
    c.fd = dial(port);
    c.len = c.pos = 0;
    roundtrip(&c, "POST", "/echo", big, sizeof big, &r);
    CHECK(r.status == 413 || r.eof);
    close(c.fd);
  }
  printf("ok bodies\n");

  /* borrowed body: ANOLE_EV_SENT once Anole is done with it */
  {
    memset(big_body, 'b', sizeof big_body);
    int sent0 = atomic_load(&cs.sent);
    request(port, "GET", "/borrow", NULL, &r);
    CHECK(r.status == 200 && r.body_len == BIG_LEN && r.body[0] == 'b' && r.body[BIG_LEN - 1] == 'b');
    CHECK(wait_for(&cs.sent, sent0 + 1));
    CHECK(atomic_load(&cs.last_sent) == (uintptr_t)big_body);
  }
  printf("ok borrowed body\n");

  /* streamed response (chunked over HTTP/1.1), with a borrowed chunk */
  {
    int sent0 = atomic_load(&cs.sent);
    request(port, "GET", "/stream", NULL, &r);
    CHECK(r.status == 200 && r.body_len == 1008);
    CHECK(memcmp(r.body, "one,", 4) == 0 && memcmp(r.body + 1004, ",two", 4) == 0);
    CHECK(wait_for(&cs.sent, sent0 + 1));
  }
  printf("ok streamed response\n");

  /* a file: bytes 6..10 of it, the consumer's fd closed at once */
  {
    snprintf(file_path, sizeof file_path, "/tmp/anole-capi-%d.txt", (int)getpid());
    FILE *f = fopen(file_path, "w");
    CHECK(f);
    fputs("hello world, from a file", f);
    fclose(f);
    request(port, "GET", "/file", NULL, &r);
    CHECK(r.status == 200 && strcmp(r.body, "world") == 0);
    unlink(file_path);
  }
  printf("ok respond_fd\n");

  /* the response cache (one per executor: one connection here): the
     second request never reaches the consumer */
  {
    static conn_reader c;
    c.fd = dial(port);
    c.len = c.pos = 0;
    uint64_t ev0 = cs.events;
    roundtrip(&c, "GET", "/cached", NULL, 0, &r);
    CHECK(r.status == 200 && strcmp(r.body, "Hello, World!") == 0);
    roundtrip(&c, "GET", "/cached", NULL, 0, &r);
    CHECK(r.status == 200 && strcmp(r.body, "Hello, World!") == 0);
    CHECK(cs.events == ev0 + 1);
    close(c.fd);
  }
  printf("ok response cache\n");

  /* answered handle: a second answer is GONE; so are made-up handles */
  {
    pthread_t t;
    async_req a = {port, "/hold", {0}, 0};
    response_init(&a.r);
    atomic_store(&cs.nheld, 0);
    CHECK(pthread_create(&t, NULL, async_get, &a) == 0);
    CHECK(wait_for(&cs.nheld, 1));
    anole_req h = cs.held[0];
    CHECK(anole_respond(h, 999, NULL, 0, NULL, 0, 0) == ANOLE_E_INVALID); /* still owed */
    CHECK(anole_respond(h, 201, NULL, 0, "late-ok", 7, 0) == ANOLE_OK);
    pthread_join(t, NULL);
    CHECK(a.r.status == 201 && strcmp(a.r.body, "late-ok") == 0);
    response_free(&a.r);
    CHECK(anole_respond(h, 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    CHECK(anole_release(h) == ANOLE_E_GONE);
    CHECK(anole_stream_write(h, "x", 1, 0) == ANOLE_E_GONE);
    char rb[8];
    CHECK(anole_req_read(h, rb, sizeof rb, 0) == ANOLE_E_GONE);
    CHECK(anole_respond(0, 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    CHECK(anole_respond(h + 1, 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    CHECK(anole_respond(h ^ (1ull << 60), 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    CHECK(anole_respond(h | (0xffffffull << 32), 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    CHECK(anole_respond(h, 200, NULL, 0, NULL, 0, 2) == ANOLE_E_INVALID);
    /* Every error answer sets its own text: none is left over from an earlier call. */
    CHECK(str_has(anole_last_error(), "invalid"));
    CHECK(anole_respond(h, 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    CHECK(str_has(anole_last_error(), "stale"));
    CHECK(anole_ws_send(h, ANOLE_WS_TEXT, "x", 1, 0) == (have_websocket ? ANOLE_E_GONE : ANOLE_E_UNSUPPORTED));

    /* slot reuse: same executor and slot, newer generation, old one stays GONE */
    anole_req first = h;
    int reused = 0;
    for (int i = 0; i < 300 && !reused; i++) {
      async_req b = {port, "/hold", {0}, 0};
      response_init(&b.r);
      atomic_store(&cs.nheld, 0);
      CHECK(pthread_create(&t, NULL, async_get, &b) == 0);
      CHECK(wait_for(&cs.nheld, 1));
      anole_req h2 = cs.held[0];
      anole_header bad = {{"bad name", 8}, {"v", 1}};
      CHECK(anole_respond(h2, 200, &bad, 1, NULL, 0, 0) == ANOLE_E_INVALID);
      anole_header bad_value = {{"x-ok", 4}, {"a\r\nb", 4}};
      CHECK(anole_respond(h2, 200, &bad_value, 1, NULL, 0, 0) == ANOLE_E_INVALID);
      anole_header framing[] = {{{"Connection", 10}, {"close", 5}}, {{"transfer-encoding", 17}, {"chunked", 7}}};
      CHECK(anole_respond(h2, 200, &framing[0], 1, NULL, 0, 0) == ANOLE_E_INVALID);
      CHECK(anole_respond(h2, 200, &framing[1], 1, NULL, 0, 0) == ANOLE_E_INVALID);
      CHECK(anole_respond(h2, 200, NULL, 0, "x", 1, 0) == ANOLE_OK);
      pthread_join(t, NULL);
      CHECK(b.r.status == 200);
      response_free(&b.r);
      if ((h2 >> 32) == (first >> 32) && h2 != first) {
        CHECK((uint32_t)h2 > (uint32_t)first);
        CHECK(anole_respond(first, 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
        reused = 1;
      }
    }
    CHECK(reused);
    printf("ok stale handles and slot reuse\n");
  }

  /* deadlines: 504 after request_ms, and after a route's own timeout_ms;
     the late answer is GONE */
  {
    anole_stats st0 = {.size = sizeof st0}, st1 = {.size = sizeof st1};
    CHECK(anole_server_stats(s, &st0) == ANOLE_OK);
    const char *paths[] = {"/hold", "/short"};
    double lo[] = {380, 130}, hi[] = {1500, 380};
    for (int i = 0; i < 2; i++) {
      pthread_t t;
      async_req a = {port, paths[i], {0}, 0};
      response_init(&a.r);
      atomic_store(&cs.nheld, 0);
      CHECK(pthread_create(&t, NULL, async_get, &a) == 0);
      pthread_join(t, NULL);
      CHECK(a.r.status == 504);
      CHECK(a.ms >= lo[i] && a.ms < hi[i]);
      CHECK(wait_for(&cs.nheld, 1));
      CHECK(anole_respond(cs.held[0], 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
      response_free(&a.r);
      printf("ok deadline %s (504 after %.0f ms)\n", paths[i], a.ms);
    }
    CHECK(anole_server_stats(s, &st1) == ANOLE_OK);
    CHECK(st1.expired == st0.expired + 2 && st1.gone >= st0.gone + 2);
  }

  /* a client that leaves: ANOLE_EV_ABORT, and the handle is GONE */
  {
    atomic_store(&cs.nheld, 0);
    int fd = dial(port);
    send_request(fd, "GET", "/hold", NULL, 0);
    CHECK(wait_for(&cs.nheld, 1));
    close(fd);
    /* This request's own ABORT: the deadline checks above may still have
       theirs in flight. */
    for (int i = 0; i < 1000 && atomic_load(&cs.last_abort) != cs.held[0]; i++) usleep(2000);
    CHECK(atomic_load(&cs.last_abort) == cs.held[0]);
    CHECK(anole_respond(cs.held[0], 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
  }
  printf("ok client gone\n");

  /* WebSocket: echo, publish to a topic, a close from the consumer */
  if (have_websocket) {
    static conn_reader c;
    char buf[256];
    size_t n;
    ws_connect(&c, port);
    CHECK(wait_for(&cs.ws_open, 1));
    ws_send_frame(c.fd, 1, "hello ws", 8);
    CHECK(ws_read_frame(&c, buf, sizeof buf, &n) == 1 && n == 8 && memcmp(buf, "hello ws", 8) == 0);
    ws_send_frame(c.fd, 2, "\x01\x02", 2);
    CHECK(ws_read_frame(&c, buf, sizeof buf, &n) == 2 && n == 2);
    ws_send_frame(c.fd, 1, "pub", 3);
    CHECK(ws_read_frame(&c, buf, sizeof buf, &n) == 1 && strcmp(buf, "news") == 0);
    anole_stats st = {.size = sizeof st};
    CHECK(anole_server_stats(s, &st) == ANOLE_OK && st.websockets == 1 && st.ws_messages_in >= 3);
    ws_send_frame(c.fd, 1, "bye", 3);
    CHECK(ws_read_frame(&c, buf, sizeof buf, &n) == 8 && n >= 2);
    CHECK((((unsigned char)buf[0] << 8) | (unsigned char)buf[1]) == 1000);
    ws_send_frame(c.fd, 8, "\x03\xe8", 2);
    CHECK(wait_for(&cs.ws_closes, 1));
    CHECK(atomic_load(&cs.last_close_code) == 1000);
    close(c.fd);
    /* a socket whose peer just leaves: 1006 */
    ws_connect(&c, port);
    CHECK(wait_for(&cs.ws_open, 2));
    close(c.fd);
    CHECK(wait_for(&cs.ws_closes, 2));
    CHECK(atomic_load(&cs.last_close_code) == 1006);
    CHECK(anole_ws_send(atomic_load(&cs.ws_handle), ANOLE_WS_TEXT, "x", 1, 0) == ANOLE_E_GONE);
    anole_str room = {"room", 4};
    CHECK(anole_ws_subscribe(atomic_load(&cs.ws_handle), room) == ANOLE_E_GONE);
    CHECK(anole_ws_close(atomic_load(&cs.ws_handle), 999, room) == ANOLE_E_INVALID);
    /* a consumer that falls behind: the messages queued for it are bounded,
       and the socket feeding it is held back (TCP backpressure) */
    {
      int big0 = atomic_load(&cs.ws_big);
      atomic_store(&cs.paused, 1);
      ws_connect(&c, port);
      size_t accepted = 0;
      int frames = ws_flood(c.fd, 1000 * 1024, 200, &accepted, &cs.paused);
      CHECK(accepted < (size_t)48 << 20);
      CHECK(wait_for(&cs.ws_open, 3));
      for (int i = 0; i < 1000 && atomic_load(&cs.ws_big) < big0 + frames; i++) usleep(5000);
      CHECK(atomic_load(&cs.ws_big) == big0 + frames);
      close(c.fd);
      CHECK(wait_for(&cs.ws_closes, 3));
    }
    /* a subscriber that stops reading holds up no publish: what is queued
       for it is bounded (limits.ws_high_water), and another subscriber
       still gets every publish */
    {
      static char chunk[60 * 1024]; /* fits a 16-bit frame length */
      uint32_t x = 12345;
      for (size_t i = 0; i < sizeof chunk; i++) {
        x = x * 1103515245u + 12345u;
        chunk[i] = (char)(x >> 24);
      }
      ws_connect(&c, port);
      CHECK(wait_for(&cs.ws_open, 4));
      for (int i = 0; i < 2000; i++) {
        anole_status st = anole_ws_publish(s, room, ANOLE_WS_BINARY, chunk, sizeof chunk, 0);
        CHECK(st == ANOLE_OK || st == ANOLE_E_AGAIN);
        if (st == ANOLE_E_AGAIN) usleep(1000);
      }
      static conn_reader c2;
      static char frame[64 * 1024];
      ws_connect(&c2, port);
      CHECK(wait_for(&cs.ws_open, 5));
      int ok = 0;
      for (int i = 0; i < 300 && !ok; i++) {
        if (anole_ws_publish(s, room, ANOLE_WS_TEXT, "after", 5, 0) == ANOLE_OK) ok = 1;
        else usleep(10000);
      }
      CHECK(ok);
      /* chunks still being fanned out may come first */
      size_t n2 = 0;
      int op;
      while ((op = ws_read_frame(&c2, frame, sizeof frame, &n2)) == 2) {}
      CHECK(op == 1 && strcmp(frame, "after") == 0);
      close(c2.fd);
      close(c.fd);
      CHECK(wait_for(&cs.ws_closes, 5));
    }
  }
  printf("ok websocket\n");

  /* many clients at once, keep-alive, answers never mixed up */
  {
    enum { T = 16, N = 2000 };
    pthread_t t[T];
    hammer_arg h[T];
    for (int i = 0; i < T; i++) {
      h[i] = (hammer_arg){port, i, N, 0};
      CHECK(pthread_create(&t[i], NULL, hammer, &h[i]) == 0);
    }
    int failures = 0;
    for (int i = 0; i < T; i++) {
      pthread_join(t[i], NULL);
      failures += h[i].failures;
    }
    CHECK(failures == 0);
    anole_stats st = {.size = sizeof st};
    CHECK(anole_server_stats(s, &st) == ANOLE_OK);
    printf("ok concurrency (%d requests, %llu batches, %llu wakes, %llu rewakes)\n", T * N,
           (unsigned long long)cs.batches, (unsigned long long)st.wakes, (unsigned long long)st.rewakes);
  }

  /* drain with requests in flight: one answered during the drain (200),
     one never answered (504 at its deadline, before shutdown_ms) */
  {
    pthread_t t1, t2;
    async_req a = {port, "/hold", {0}, 0}, b = {port, "/hold", {0}, 0};
    response_init(&a.r);
    response_init(&b.r);
    atomic_store(&cs.nheld, 0);
    CHECK(pthread_create(&t1, NULL, async_get, &a) == 0);
    CHECK(pthread_create(&t2, NULL, async_get, &b) == 0);
    CHECK(wait_for(&cs.nheld, 2));
    double t0 = now_ms();
    CHECK(anole_server_drain(s) == ANOLE_OK);
    CHECK(anole_server_drain(s) == ANOLE_OK); /* again: no-op */
    CHECK(anole_server_wait(s, 0) == ANOLE_E_TIMEOUT);
    usleep(100 * 1000);
    CHECK(anole_respond(cs.held[0], 200, NULL, 0, "drained", 7, 0) == ANOLE_OK);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    async_req *answered = a.r.status == 200 ? &a : &b, *dropped = answered == &a ? &b : &a;
    CHECK(answered->r.status == 200 && strcmp(answered->r.body, "drained") == 0);
    CHECK(dropped->r.status == 504 || dropped->r.eof);
    CHECK(anole_server_wait(s, 10000) == ANOLE_OK);
    double took = now_ms() - t0;
    CHECK(anole_respond(cs.held[1], 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    pthread_join(cs.thread, NULL);
    CHECK(atomic_load(&cs.stopped));
    /* after the stop, polls return 0 */
    CHECK(anole_poll(cs.c, cs.buf, sizeof cs.buf, 0) == 0);
    printf("ok drain (stopped after %.0f ms; dropped request: %s)\n", took,
           dropped->r.eof ? "connection closed" : "504");
    response_free(&a.r);
    response_free(&b.r);
  }
  response_free(&r);
  CHECK(atomic_load(&log_lines) > 0); /* "listening on ..." went to the callback */
  anole_server_destroy(s);
  current_server = NULL;
}

/* Polls `c` until a request arrives; its handle. */
static anole_req next_request(anole_consumer *c) {
  static _Alignas(8) unsigned char buf[64 * 1024];
  for (int i = 0; i < 100; i++) {
    int64_t n = anole_poll_wait(c, buf, sizeof buf, 100);
    CHECK(n >= 0);
    for (int64_t off = 0; off < n;) {
      const anole_event *ev = (const anole_event *)(buf + off);
      if (ev->type == ANOLE_EV_REQUEST) return ev->handle;
      off += ev->len;
    }
  }
  CHECK(!"no request arrived");
  return 0;
}

/* A handle from a destroyed server is ANOLE_E_GONE on the next one, even
   where the new server's request sits in the same slot (test suites create
   and destroy a server per test; a late answer from one test must not land
   on the next one's request). */
static void test_stale_across_servers(void) {
  const char *json = "{\"listeners\":[{\"address\":\"127.0.0.1\",\"port\":0}],\"executors\":1,"
                     "\"timeouts\":{\"shutdown_ms\":200},"
                     "\"routes\":[{\"method\":\"GET\",\"path\":\"/hold\",\"handler\":1}]}";
  anole_consumer_options co = {sizeof co, NULL, NULL, 0};
  anole_req old = 0;
  for (int round = 0; round < 2; round++) {
    anole_server *s = make_server(json);
    anole_consumer *c = NULL;
    CHECK(anole_consumer_attach(s, &co, &c) == ANOLE_OK);
    CHECK(anole_server_start(s) == ANOLE_OK);
    uint16_t port = 0;
    CHECK(anole_server_port(s, 0, &port) == ANOLE_OK);
    conn_reader cr = {0};
    cr.fd = dial(port);
    send_request(cr.fd, "GET", "/hold", NULL, 0);
    anole_req h = next_request(c);
    if (round == 0) {
      /* Left unanswered: the drain cuts it. */
      old = h;
      CHECK(anole_server_drain(s) == ANOLE_OK);
      CHECK(anole_server_wait(s, 5000) == ANOLE_OK);
      anole_server_destroy(s);
      close(cr.fd);
      continue;
    }
    /* The old handle, as a late answer from the first server's test would
       send it: refused, and the new request untouched. */
    CHECK(anole_respond(old, 200, text_plain, 1, "old", 3, 0) == ANOLE_E_GONE);
    CHECK(anole_respond(h, 200, text_plain, 1, "new", 3, 0) == ANOLE_OK);
    response r;
    response_init(&r);
    read_response(&cr, &r, 0);
    CHECK(r.status == 200 && strcmp(r.body, "new") == 0);
    response_free(&r);
    close(cr.fd);
    CHECK(anole_server_drain(s) == ANOLE_OK);
    CHECK(anole_server_wait(s, 5000) == ANOLE_OK);
    anole_server_destroy(s);
  }
  printf("ok stale handles across servers: ANOLE_E_GONE\n");
}

/* A second server: a shared consumer on anole_poll_wait threads, max_inflight
   503, and a drain that cuts a request waiting past shutdown_ms. */
static void test_shared_consumer(void) {
  char json[4096];
  snprintf(json, sizeof json, test_config, 1, 128 * 1024, 2, 5000, 300, have_websocket ? ws_route : "");
  anole_server *s = make_server(json);
  static consumer_state cs[2];
  anole_consumer_options co = {sizeof co, NULL, NULL, ANOLE_CONSUMER_SHARED};
  anole_consumer *c = NULL;
  CHECK(anole_consumer_attach(s, &co, &c) == ANOLE_OK);
  CHECK(anole_consumer_fd(c) == -1);
  CHECK(anole_server_start(s) == ANOLE_OK);
  uint16_t port;
  CHECK(anole_server_port(s, 0, &port) == ANOLE_OK);
  for (int i = 0; i < 2; i++) {
    cs[i].c = c;
    cs[i].on_event = on_event;
    cs[i].use_wait = 1;
    start_consumer(&cs[i]);
  }
  response r;
  response_init(&r);
  for (int i = 0; i < 50; i++) {
    request(port, "GET", "/hello", NULL, &r);
    CHECK(r.status == 200);
  }
  CHECK(cs[0].events + cs[1].events == 50);
  /* max_inflight 2 per executor: the third request is 503 */
  pthread_t t1, t2;
  async_req a = {port, "/hold", {0}, 0}, b = {port, "/hold", {0}, 0};
  response_init(&a.r);
  response_init(&b.r);
  CHECK(pthread_create(&t1, NULL, async_get, &a) == 0);
  CHECK(pthread_create(&t2, NULL, async_get, &b) == 0);
  for (int i = 0; i < 1000 && atomic_load(&cs[0].nheld) + atomic_load(&cs[1].nheld) < 2; i++) usleep(2000);
  request(port, "GET", "/hello", NULL, &r);
  CHECK(r.status == 503);
  double t0 = now_ms();
  CHECK(anole_server_drain(s) == ANOLE_OK);
  pthread_join(t1, NULL);
  pthread_join(t2, NULL);
  CHECK(a.r.eof || a.r.status >= 500);
  CHECK(anole_server_wait(s, -1) == ANOLE_OK);
  double took = now_ms() - t0;
  CHECK(took < 2000);
  for (int i = 0; i < 2; i++) {
    atomic_store(&cs[i].stopped, 1);
    pthread_join(cs[i].thread, NULL);
  }
  anole_stats st = {.size = sizeof st};
  CHECK(anole_server_stats(s, &st) == ANOLE_OK);
  CHECK(st.busy == 1 && st.inflight == 0);
  /* stats from an older header: only what its size covers */
  anole_stats small = {.size = offsetof(anole_stats, inflight), .inflight = 77};
  CHECK(anole_server_stats(s, &small) == ANOLE_OK && small.inflight == 77 && small.requests > 0);
  anole_server_destroy(s);
  response_free(&r);
  response_free(&a.r);
  response_free(&b.r);
  printf("ok shared consumer, max_inflight 503, drain past shutdown_ms (%.0f ms)\n", took);
}

/* ---- databases (anole_db_*) ----------------------------------------------------------------- */

#define LIT(s) ((anole_str){s, sizeof(s) - 1})

/* The next ANOLE_EV_DB_RESULT, copied into `out` (other events are not
   expected here). */
static unsigned char db_buf[1 << 20];
static const anole_db_result_event *db_next(anole_consumer *c, void *out, size_t cap) {
  static size_t have = 0, at = 0;
  for (;;) {
    if (at < have) {
      const anole_event *ev = (const anole_event *)(db_buf + at);
      at += ev->len;
      if (ev->type != ANOLE_EV_DB_RESULT) continue;
      CHECK(ev->len <= cap);
      memcpy(out, ev, ev->len);
      return (const anole_db_result_event *)out;
    }
    int64_t n = anole_poll_wait(c, db_buf, sizeof db_buf, 10000);
    CHECK(n > 0);
    have = (size_t)n;
    at = 0;
  }
}

static const anole_db_cell *db_cell(const anole_db_result_event *r, uint32_t row, uint32_t col) {
  const anole_db_cell *cells = (const anole_db_cell *)((const char *)r + r->cells.off);
  return &cells[row * r->ncolumns + col];
}

static anole_str db_column(const anole_db_result_event *r, uint32_t col) {
  const anole_span *names = (const anole_span *)((const char *)r + r->columns.off);
  return anole_event_str(r, names[col]);
}

static void test_db(void) {
  anole_str sqlite_name = LIT("sqlite");
  if (!anole_has_feature(sqlite_name)) {
    printf("ok databases (SQLite not built in)\n");
    return;
  }
  char path[64];
  snprintf(path, sizeof path, "/tmp/anole-capi-%d.db", (int)getpid());
  char json[2048];
  snprintf(json, sizeof json,
           "{\"executors\": 1, \"listeners\": [{\"port\": 0}],"
           " \"limits\": {\"db_result_max\": 65536},"
           " \"databases\": [{\"name\": \"main\", \"sqlite\": {\"path\": \"%s\","
           "   \"init\": \"CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL,"
           " qty INTEGER, price REAL, data BLOB);\"}}]}",
           path);
  anole_server *s = make_server(json);
  anole_db *db = NULL;
  anole_str main_name = LIT("main"), nope = LIT("nope");
  CHECK(anole_db_find(s, nope, &db) == ANOLE_E_INVALID);
  CHECK(anole_db_find(s, main_name, &db) == ANOLE_OK && db != NULL);
  anole_consumer *c = NULL;
  anole_consumer_options co = {sizeof co, NULL, NULL, 0};
  CHECK(anole_consumer_attach(s, &co, &c) == ANOLE_OK);
  anole_str sel = LIT("SELECT 1");
  CHECK(anole_db_query(db, c, sel, NULL, 0, NULL, 1) == ANOLE_E_STATE); /* not started */
  CHECK(anole_server_start(s) == ANOLE_OK);
  static unsigned char rec[1 << 20];
  const anole_db_result_event *r;

  /* exec with every value type */
  anole_str ins = LIT("INSERT INTO items (name, qty, price, data) VALUES (?, ?, ?, ?)");
  anole_db_value v[4] = {{ANOLE_DB_TEXT, 0, {.s = LIT("apple")}},
                         {ANOLE_DB_INT, 0, {.i = 3}},
                         {ANOLE_DB_FLOAT, 0, {.f = 1.25}},
                         {ANOLE_DB_BLOB, 0, {.s = LIT("\x00\x01\x02")}}};
  CHECK(anole_db_exec(db, c, ins, v, 4, NULL, 10) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->user_data == 10 && r->status == ANOLE_OK && r->changes == 1 && r->last_insert_rowid == 1);
  CHECK(r->ncolumns == 0 && r->nrows == 0 && r->http_status == 0);
  v[0].v.s = LIT("pear");
  v[1].type = ANOLE_DB_NULL;
  CHECK(anole_db_exec(db, c, ins, v, 4, NULL, 11) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->last_insert_rowid == 2);

  /* a read: names and cells */
  anole_str q = LIT("SELECT id, name AS label, qty, price, data FROM items ORDER BY id");
  CHECK(anole_db_query(db, c, q, NULL, 0, NULL, 12) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->user_data == 12 && r->status == ANOLE_OK && r->ncolumns == 5 && r->nrows == 2);
  CHECK(str_is(db_column(r, 1), "label"));
  CHECK(db_cell(r, 0, 0)->type == ANOLE_DB_INT && db_cell(r, 0, 0)->v.i == 1);
  CHECK(db_cell(r, 0, 1)->type == ANOLE_DB_TEXT && str_is(anole_event_str(r, db_cell(r, 0, 1)->v.s), "apple"));
  CHECK(db_cell(r, 0, 3)->type == ANOLE_DB_FLOAT && db_cell(r, 0, 3)->v.f == 1.25);
  CHECK(db_cell(r, 0, 4)->type == ANOLE_DB_BLOB && db_cell(r, 0, 4)->v.s.len == 3);
  CHECK(memcmp(anole_event_str(r, db_cell(r, 0, 4)->v.s).ptr, "\x00\x01\x02", 3) == 0);
  CHECK(db_cell(r, 1, 2)->type == ANOLE_DB_NULL);
  CHECK(r->source == ANOLE_DB_FROM_DATABASE);

  /* failures: a unique key, a syntax error, a wrong value type */
  v[0].v.s = LIT("apple");
  CHECK(anole_db_exec(db, c, ins, v, 4, NULL, 13) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_DB && r->http_status == 409 && r->error_class == ANOLE_DB_ERR_UNIQUE);
  CHECK(str_is(anole_event_str(r, r->constraint), "items.name") && r->error.len > 0 && r->error_code.len > 0);
  anole_str bad = LIT("SELEKT 1");
  CHECK(anole_db_query(db, c, bad, NULL, 0, NULL, 14) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_DB && r->http_status == 500 && r->error_class == ANOLE_DB_ERR_OTHER);
  anole_db_value wrong = {99, 0, {.i = 0}};
  CHECK(anole_db_query(db, c, sel, &wrong, 1, NULL, 15) == ANOLE_E_INVALID);

  /* several statements without parameters */
  anole_str script = LIT("CREATE TABLE t2 (x); INSERT INTO t2 VALUES (1); INSERT INTO t2 VALUES (2);");
  CHECK(anole_db_exec(db, c, script, NULL, 0, NULL, 16) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->changes == 2);

  /* the cache: a hit until invalidated */
  anole_db_options cached = {sizeof cached, 0, 0, 60000, 0, LIT("items")};
  anole_str count = LIT("SELECT count(*) AS n FROM items");
  CHECK(anole_db_query(db, c, count, NULL, 0, &cached, 20) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->source == ANOLE_DB_FROM_DATABASE && db_cell(r, 0, 0)->v.i == 2);
  v[0].v.s = LIT("plum");
  CHECK(anole_db_exec(db, c, ins, v, 4, NULL, 21) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(anole_db_query(db, c, count, NULL, 0, &cached, 22) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->source == ANOLE_DB_FROM_CACHE && db_cell(r, 0, 0)->v.i == 2);
  anole_str items = LIT("items");
  CHECK(anole_db_invalidate(db, items) == ANOLE_OK);
  CHECK(anole_db_query(db, c, count, NULL, 0, &cached, 23) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->source == ANOLE_DB_FROM_DATABASE && db_cell(r, 0, 0)->v.i == 3);

  /* many at once, coalesced: each answered once */
  enum { MANY = 200 };
  static int seen[MANY];
  memset(seen, 0, sizeof seen);
  anole_db_options co_opts = {sizeof co_opts, ANOLE_DB_COALESCE, 0, 0, 0, {NULL, 0}};
  for (int i = 0; i < MANY; i++) CHECK(anole_db_query(db, c, count, NULL, 0, &co_opts, 1000 + i) == ANOLE_OK);
  int coalesced = 0;
  for (int i = 0; i < MANY; i++) {
    r = db_next(c, rec, sizeof rec);
    CHECK(r->user_data >= 1000 && r->user_data < 1000 + MANY && !seen[r->user_data - 1000]);
    seen[r->user_data - 1000] = 1;
    CHECK(r->status == ANOLE_OK && db_cell(r, 0, 0)->v.i == 3);
    if (r->source == ANOLE_DB_FROM_COALESCED) coalesced++;
  }

  /* a timeout interrupts the statement */
  anole_str slow = LIT("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT count(*) FROM n");
  anole_db_options quick = {sizeof quick, 0, 50, 0, 0, {NULL, 0}};
  double t0 = now_ms();
  CHECK(anole_db_query(db, c, slow, NULL, 0, &quick, 30) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_TIMEOUT && r->http_status == 504 && r->error_class == ANOLE_DB_ERR_TIMEOUT);
  CHECK(now_ms() - t0 < 2000);

  /* an answer past limits.db_result_max */
  anole_str huge = LIT("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 10000) SELECT x FROM n");
  CHECK(anole_db_query(db, c, huge, NULL, 0, NULL, 31) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_TOOBIG && r->nrows == 0);

  /* a poll buffer too small for the next answer: TOOBIG, the record stays */
  anole_str some = LIT("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 100) SELECT x FROM n");
  CHECK(anole_db_query(db, c, some, NULL, 0, NULL, 32) == ANOLE_OK);
  unsigned char tiny[256];
  int64_t n;
  do n = anole_poll_wait(c, tiny, sizeof tiny, 10000);
  while (n == 0);
  CHECK(n == ANOLE_E_TOOBIG);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->user_data == 32 && r->nrows == 100);

  CHECK(anole_server_drain(s) == ANOLE_OK);
  CHECK(anole_server_wait(s, -1) == ANOLE_OK);
  CHECK(anole_db_query(db, c, sel, NULL, 0, NULL, 40) == ANOLE_E_STATE);
  anole_server_destroy(s);
  unlink(path);
  char side[80];
  snprintf(side, sizeof side, "%s-wal", path);
  unlink(side);
  snprintf(side, sizeof side, "%s-shm", path);
  unlink(side);
  printf("ok databases: values both ways, errors, scripts, cache, %d of %d coalesced, timeout, size limit\n", coalesced, MANY);
}

/* PostgreSQL, against the server ANOLE_TEST_POSTGRES_URL names (zig build
   capi-test -Dpostgres-test-url=...; tests/postgres/run.sh). */
static void test_db_postgres(void) {
  anole_str pg_name = LIT("postgres");
  const char *url = getenv("ANOLE_TEST_POSTGRES_URL");
  if (!anole_has_feature(pg_name) || url == NULL || url[0] == 0) {
    printf("ok postgres (%s)\n", anole_has_feature(pg_name) ? "no ANOLE_TEST_POSTGRES_URL" : "not built in");
    return;
  }
  char json[4096];
  snprintf(json, sizeof json,
           "{\"executors\": 2, \"listeners\": [{\"port\": 0}],"
           " \"limits\": {\"db_result_max\": 65536},"
           " \"databases\": [{\"name\": \"pg\", \"postgres\": {\"url\": \"%s\", \"max_connections\": 4,"
           "   \"init\": \"DROP TABLE IF EXISTS anole_capi_items; CREATE TABLE anole_capi_items (id bigserial PRIMARY KEY,"
           " name text UNIQUE NOT NULL, qty int4, price numeric(8, 2), ok bool, data bytea, at timestamptz)\"}}]}",
           url);
  anole_server *s = make_server(json);
  anole_db *db = NULL;
  anole_str name = LIT("pg");
  CHECK(anole_db_find(s, name, &db) == ANOLE_OK && db != NULL);
  anole_consumer *c = NULL;
  anole_consumer_options co = {sizeof co, NULL, NULL, 0};
  CHECK(anole_consumer_attach(s, &co, &c) == ANOLE_OK);
  CHECK(anole_server_start(s) == ANOLE_OK);
  static unsigned char rec[1 << 20];
  const anole_db_result_event *r;

  /* every value type, sent as the parameter's type or as text */
  anole_str ins = LIT("INSERT INTO anole_capi_items (name, qty, price, ok, data, at) VALUES ($1, $2, $3, $4, $5, $6)");
  anole_db_value v[6] = {{ANOLE_DB_TEXT, 0, {.s = LIT("apple")}},     {ANOLE_DB_INT, 0, {.i = 3}},
                         {ANOLE_DB_FLOAT, 0, {.f = 1.25}},            {ANOLE_DB_BOOL, 0, {.i = 1}},
                         {ANOLE_DB_BLOB, 0, {.s = LIT("\x00\x01\x02")}}, {ANOLE_DB_TEXT, 0, {.s = LIT("2026-10-22T10:00:00Z")}}};
  CHECK(anole_db_exec(db, c, ins, v, 6, NULL, 10) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->user_data == 10 && r->status == ANOLE_OK && r->changes == 1 && r->last_insert_rowid == 0);
  /* RETURNING through a query; an int sent to a text parameter */
  anole_str ret = LIT("INSERT INTO anole_capi_items (name, qty) VALUES ($1::text, $2) RETURNING id");
  anole_db_value v2[2] = {{ANOLE_DB_INT, 0, {.i = 42}}, {ANOLE_DB_NULL, 0, {.i = 0}}};
  CHECK(anole_db_query(db, c, ret, v2, 2, NULL, 11) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->nrows == 1 && db_cell(r, 0, 0)->type == ANOLE_DB_INT && db_cell(r, 0, 0)->v.i == 2);
  CHECK(db_cell(r, 0, 0)->db_type == 20);

  /* a read: converted cells, the rest as text, each with its type OID */
  anole_str q = LIT("SELECT id, name AS label, qty, price, ok, data, at FROM anole_capi_items ORDER BY id");
  CHECK(anole_db_query(db, c, q, NULL, 0, NULL, 12) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->ncolumns == 7 && r->nrows == 2);
  CHECK(str_is(db_column(r, 1), "label"));
  CHECK(db_cell(r, 0, 0)->type == ANOLE_DB_INT && db_cell(r, 0, 0)->v.i == 1);
  CHECK(db_cell(r, 0, 1)->type == ANOLE_DB_TEXT && db_cell(r, 0, 1)->db_type == 25);
  CHECK(str_is(anole_event_str(r, db_cell(r, 0, 1)->v.s), "apple"));
  CHECK(db_cell(r, 0, 2)->type == ANOLE_DB_INT && db_cell(r, 0, 2)->v.i == 3 && db_cell(r, 0, 2)->db_type == 23);
  CHECK(db_cell(r, 0, 3)->type == ANOLE_DB_TEXT && db_cell(r, 0, 3)->db_type == 1700);
  CHECK(str_is(anole_event_str(r, db_cell(r, 0, 3)->v.s), "1.25"));
  CHECK(db_cell(r, 0, 4)->type == ANOLE_DB_BOOL && db_cell(r, 0, 4)->v.i == 1);
  CHECK(db_cell(r, 0, 5)->type == ANOLE_DB_BLOB && db_cell(r, 0, 5)->v.s.len == 3);
  CHECK(memcmp(anole_event_str(r, db_cell(r, 0, 5)->v.s).ptr, "\x00\x01\x02", 3) == 0);
  CHECK(db_cell(r, 0, 6)->type == ANOLE_DB_TEXT && db_cell(r, 0, 6)->db_type == 1184);
  CHECK(str_is(anole_event_str(r, db_cell(r, 1, 1)->v.s), "42"));
  CHECK(db_cell(r, 1, 2)->type == ANOLE_DB_NULL && db_cell(r, 1, 2)->db_type == 23);

  /* failures: a unique key, a syntax error, a value PostgreSQL refuses */
  CHECK(anole_db_exec(db, c, ins, v, 6, NULL, 13) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_DB && r->http_status == 409 && r->error_class == ANOLE_DB_ERR_UNIQUE);
  CHECK(str_is(anole_event_str(r, r->constraint), "anole_capi_items_name_key"));
  CHECK(str_is(anole_event_str(r, r->error_code), "23505") && r->error.len > 0);
  anole_str bad = LIT("SELEKT 1");
  CHECK(anole_db_query(db, c, bad, NULL, 0, NULL, 14) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_DB && r->http_status == 500 && r->error_class == ANOLE_DB_ERR_OTHER);
  CHECK(str_is(anole_event_str(r, r->error_code), "42601"));
  anole_str as_int = LIT("SELECT $1::int4");
  anole_db_value half = {ANOLE_DB_FLOAT, 0, {.f = 1.5}};
  CHECK(anole_db_query(db, c, as_int, &half, 1, NULL, 15) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_DB && str_is(anole_event_str(r, r->error_code), "22P02"));

  /* the cache: a hit until invalidated */
  anole_db_options cached = {sizeof cached, 0, 0, 60000, 0, LIT("items")};
  anole_str count = LIT("SELECT count(*) AS n FROM anole_capi_items");
  for (int round = 0; round < 2; round++) {
    CHECK(anole_db_query(db, c, count, NULL, 0, &cached, 20) == ANOLE_OK);
    r = db_next(c, rec, sizeof rec);
    CHECK(r->status == ANOLE_OK && db_cell(r, 0, 0)->v.i == 2);
  }
  /* (two executors: the second may have missed; a third ask hits one of them) */
  CHECK(anole_db_query(db, c, count, NULL, 0, &cached, 21) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->source == ANOLE_DB_FROM_CACHE);
  anole_str items = LIT("items");
  CHECK(anole_db_invalidate(db, items) == ANOLE_OK);
  CHECK(anole_db_query(db, c, count, NULL, 0, &cached, 22) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->source == ANOLE_DB_FROM_DATABASE);

  /* many at once, coalesced: each answered once */
  enum { MANY = 200 };
  static int seen[MANY];
  memset(seen, 0, sizeof seen);
  anole_db_options co_opts = {sizeof co_opts, ANOLE_DB_COALESCE, 0, 0, 0, {NULL, 0}};
  for (int i = 0; i < MANY; i++) CHECK(anole_db_query(db, c, count, NULL, 0, &co_opts, 1000 + i) == ANOLE_OK);
  int coalesced = 0;
  for (int i = 0; i < MANY; i++) {
    r = db_next(c, rec, sizeof rec);
    CHECK(r->user_data >= 1000 && r->user_data < 1000 + MANY && !seen[r->user_data - 1000]);
    seen[r->user_data - 1000] = 1;
    CHECK(r->status == ANOLE_OK && db_cell(r, 0, 0)->v.i == 2);
    if (r->source == ANOLE_DB_FROM_COALESCED) coalesced++;
  }

  /* a timeout cancels the statement on the server; the pool carries on */
  anole_str slow = LIT("SELECT pg_sleep(10)");
  anole_db_options quick = {sizeof quick, 0, 100, 0, 0, {NULL, 0}};
  double t0 = now_ms();
  CHECK(anole_db_query(db, c, slow, NULL, 0, &quick, 30) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_TIMEOUT && r->http_status == 504 && r->error_class == ANOLE_DB_ERR_TIMEOUT);
  CHECK(now_ms() - t0 < 3000);
  CHECK(anole_db_query(db, c, count, NULL, 0, NULL, 31) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && db_cell(r, 0, 0)->v.i == 2);

  /* an answer past limits.db_result_max */
  anole_str huge = LIT("SELECT x FROM generate_series(1, 20000) x");
  CHECK(anole_db_query(db, c, huge, NULL, 0, NULL, 32) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_TOOBIG && r->nrows == 0);

  anole_str drop = LIT("DROP TABLE anole_capi_items");
  CHECK(anole_db_exec(db, c, drop, NULL, 0, NULL, 33) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK);

  CHECK(anole_server_drain(s) == ANOLE_OK);
  CHECK(anole_server_wait(s, -1) == ANOLE_OK);
  CHECK(anole_db_query(db, c, count, NULL, 0, NULL, 40) == ANOLE_E_STATE);
  anole_server_destroy(s);
  printf("ok postgres: values both ways with type OIDs, RETURNING, errors, cache, %d of %d coalesced, timeout, size limit\n",
         coalesced, MANY);
}

/* Redis, against the server ANOLE_TEST_REDIS_URL names (zig build
   capi-test -Dredis-test-url=...; tests/redis/run.sh). */
static void test_db_redis(void) {
  anole_str redis_name = LIT("redis");
  const char *url = getenv("ANOLE_TEST_REDIS_URL");
  if (!anole_has_feature(redis_name) || url == NULL || url[0] == 0) {
    printf("ok redis (%s)\n", anole_has_feature(redis_name) ? "no ANOLE_TEST_REDIS_URL" : "not built in");
    return;
  }
  char json[2048];
  snprintf(json, sizeof json,
           "{\"executors\": 2, \"listeners\": [{\"port\": 0}], \"limits\": {\"db_result_max\": 65536},"
           " \"databases\": [{\"name\": \"kv\", \"redis\": {\"url\": \"%s\"}}]}",
           url);
  anole_server *s = make_server(json);
  anole_db *db = NULL;
  anole_str name = LIT("kv");
  CHECK(anole_db_find(s, name, &db) == ANOLE_OK);
  anole_consumer *c = NULL;
  anole_consumer_options co = {sizeof co, NULL, NULL, 0};
  CHECK(anole_consumer_attach(s, &co, &c) == ANOLE_OK);
  CHECK(anole_server_start(s) == ANOLE_OK);
  static unsigned char rec[1 << 20];
  const anole_db_result_event *r;
  anole_str del = LIT("DEL"), set = LIT("SET"), get = LIT("GET"), rpush = LIT("RPUSH"), lrange = LIT("LRANGE");
  anole_db_value keys[3] = {{ANOLE_DB_TEXT, 0, {.s = LIT("anole:capi:s")}},
                            {ANOLE_DB_TEXT, 0, {.s = LIT("anole:capi:l")}},
                            {ANOLE_DB_TEXT, 0, {.s = LIT("anole:capi:n")}}};
  CHECK(anole_db_exec(db, c, del, keys, 3, NULL, 1) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->nrows == 0);

  /* SET with binary-safe bytes and an int, then GET */
  anole_db_value sv[4] = {keys[0], {ANOLE_DB_BLOB, 0, {.s = LIT("v\x00w")}}, {ANOLE_DB_TEXT, 0, {.s = LIT("EX")}},
                          {ANOLE_DB_INT, 0, {.i = 60}}};
  CHECK(anole_db_query(db, c, set, sv, 4, NULL, 2) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->ncolumns == 0 && r->nrows == 1);
  CHECK(db_cell(r, 0, 0)->type == ANOLE_DB_TEXT && str_is(anole_event_str(r, db_cell(r, 0, 0)->v.s), "OK"));
  CHECK(anole_db_query(db, c, get, keys, 1, NULL, 3) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(db_cell(r, 0, 0)->type == ANOLE_DB_BLOB && db_cell(r, 0, 0)->v.s.len == 3);
  CHECK(memcmp(anole_event_str(r, db_cell(r, 0, 0)->v.s).ptr, "v\x00w", 3) == 0);
  CHECK(anole_db_query(db, c, get, &keys[2], 1, NULL, 4) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->nrows == 1 && db_cell(r, 0, 0)->type == ANOLE_DB_NULL);

  /* exec: an integer reply as `changes` */
  anole_db_value lv[4] = {keys[1], {ANOLE_DB_TEXT, 0, {.s = LIT("a")}}, {ANOLE_DB_INT, 0, {.i = 2}},
                          {ANOLE_DB_FLOAT, 0, {.f = 2.5}}};
  CHECK(anole_db_exec(db, c, rpush, lv, 4, NULL, 5) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->changes == 3);

  /* an array; a nested reply from a script, in preorder */
  anole_db_value rv[3] = {keys[1], {ANOLE_DB_INT, 0, {.i = 0}}, {ANOLE_DB_INT, 0, {.i = -1}}};
  CHECK(anole_db_query(db, c, lrange, rv, 3, NULL, 6) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->nrows == 4 && db_cell(r, 0, 0)->type == ANOLE_DB_ARRAY && db_cell(r, 0, 0)->v.i == 3);
  CHECK(str_is(anole_event_str(r, db_cell(r, 0, 3)->v.s), "2.5"));
  anole_str eval = LIT("EVAL");
  anole_db_value ev[2] = {{ANOLE_DB_TEXT, 0, {.s = LIT("return {1, {2, 'x'}, 3}")}}, {ANOLE_DB_INT, 0, {.i = 0}}};
  CHECK(anole_db_query(db, c, eval, ev, 2, NULL, 7) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->nrows == 6);
  CHECK(db_cell(r, 0, 0)->type == ANOLE_DB_ARRAY && db_cell(r, 0, 0)->v.i == 3);
  CHECK(db_cell(r, 0, 1)->type == ANOLE_DB_INT && db_cell(r, 0, 1)->v.i == 1);
  CHECK(db_cell(r, 0, 2)->type == ANOLE_DB_ARRAY && db_cell(r, 0, 2)->v.i == 2);
  CHECK(db_cell(r, 0, 4)->type == ANOLE_DB_BLOB && db_cell(r, 0, 5)->v.i == 3);

  /* a server error; an empty command */
  anole_str incr = LIT("INCR");
  CHECK(anole_db_query(db, c, incr, &keys[1], 1, NULL, 8) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_DB && r->http_status == 500 && r->error_class == ANOLE_DB_ERR_OTHER);
  CHECK(str_is(anole_event_str(r, r->error_code), "WRONGTYPE"));
  anole_str blank = LIT("  ");
  CHECK(anole_db_query(db, c, blank, NULL, 0, NULL, 9) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_DB && r->http_status == 400);

  /* the cache, for read commands: a hit until invalidated */
  anole_db_options cached = {sizeof cached, 0, 0, 60000, 0, LIT("l")};
  for (int round = 0; round < 3; round++) {
    CHECK(anole_db_query(db, c, lrange, rv, 3, &cached, 20) == ANOLE_OK);
    r = db_next(c, rec, sizeof rec);
    CHECK(r->status == ANOLE_OK && db_cell(r, 0, 0)->v.i == 3);
    if (round == 2) CHECK(r->source == ANOLE_DB_FROM_CACHE);
  }
  anole_str l = LIT("l");
  CHECK(anole_db_invalidate(db, l) == ANOLE_OK);
  CHECK(anole_db_query(db, c, lrange, rv, 3, &cached, 21) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->source == ANOLE_DB_FROM_DATABASE);

  /* many at once, coalesced */
  enum { MANY = 200 };
  anole_db_options co_opts = {sizeof co_opts, ANOLE_DB_COALESCE, 0, 0, 0, {NULL, 0}};
  for (int i = 0; i < MANY; i++) CHECK(anole_db_query(db, c, get, keys, 1, &co_opts, 1000 + i) == ANOLE_OK);
  int coalesced = 0;
  for (int i = 0; i < MANY; i++) {
    r = db_next(c, rec, sizeof rec);
    CHECK(r->status == ANOLE_OK && db_cell(r, 0, 0)->v.s.len == 3);
    if (r->source == ANOLE_DB_FROM_COALESCED) coalesced++;
  }

  /* a timeout: a blocking pop that waits longer */
  anole_str blpop = LIT("BLPOP");
  anole_db_value bv[2] = {keys[2], {ANOLE_DB_INT, 0, {.i = 5}}};
  anole_db_options quick = {sizeof quick, 0, 100, 0, 0, {NULL, 0}};
  double t0 = now_ms();
  CHECK(anole_db_query(db, c, blpop, bv, 2, &quick, 30) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_TIMEOUT && r->http_status == 504);
  CHECK(now_ms() - t0 < 3000);

  /* an answer past limits.db_result_max */
  anole_str setrange = LIT("SETRANGE");
  anole_db_value sr[3] = {keys[2], {ANOLE_DB_INT, 0, {.i = 100000}}, {ANOLE_DB_TEXT, 0, {.s = LIT("x")}}};
  CHECK(anole_db_exec(db, c, setrange, sr, 3, NULL, 31) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->changes == 100001);
  CHECK(anole_db_query(db, c, get, &keys[2], 1, NULL, 32) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_TOOBIG);

  CHECK(anole_db_exec(db, c, del, keys, 3, NULL, 33) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->changes == 3);
  CHECK(anole_server_drain(s) == ANOLE_OK);
  CHECK(anole_server_wait(s, -1) == ANOLE_OK);
  anole_server_destroy(s);
  printf("ok redis: commands with binary values, nested replies, errors, cache, %d of %d coalesced, timeout, size limit\n",
         coalesced, MANY);
}

/* ---- a little BSON, for the MongoDB part ---- */

typedef struct {
  unsigned char buf[96 * 1024];
  size_t len;
  size_t open[8];
  int depth;
} bson_b;

static void bb_raw(bson_b *b, const void *p, size_t n) {
  CHECK(b->len + n <= sizeof b->buf);
  memcpy(b->buf + b->len, p, n);
  b->len += n;
}
static void bb_i32le(bson_b *b, int32_t v) {
  unsigned char x[4] = {(unsigned char)v, (unsigned char)(v >> 8), (unsigned char)(v >> 16), (unsigned char)(v >> 24)};
  bb_raw(b, x, 4);
}
static void bb_begin(bson_b *b) {
  b->open[b->depth++] = b->len;
  bb_i32le(b, 0);
}
static void bb_end(bson_b *b) {
  unsigned char z = 0;
  bb_raw(b, &z, 1);
  size_t start = b->open[--b->depth];
  int32_t n = (int32_t)(b->len - start);
  unsigned char x[4] = {(unsigned char)n, (unsigned char)(n >> 8), (unsigned char)(n >> 16), (unsigned char)(n >> 24)};
  memcpy(b->buf + start, x, 4);
}
static void bb_key(bson_b *b, unsigned char type, const char *name) {
  bb_raw(b, &type, 1);
  bb_raw(b, name, strlen(name) + 1);
}
static void bb_int(bson_b *b, const char *name, int32_t v) {
  bb_key(b, 0x10, name);
  bb_i32le(b, v);
}
static void bb_bool(bson_b *b, const char *name, int v) {
  unsigned char x = v ? 1 : 0;
  bb_key(b, 0x08, name);
  bb_raw(b, &x, 1);
}
static void bb_str(bson_b *b, const char *name, const char *v, size_t n) {
  bb_key(b, 0x02, name);
  bb_i32le(b, (int32_t)n + 1);
  bb_raw(b, v, n);
  unsigned char z = 0;
  bb_raw(b, &z, 1);
}
static void bb_doc(bson_b *b, const char *name) { bb_key(b, 0x03, name), bb_begin(b); }
static void bb_arr(bson_b *b, const char *name) { bb_key(b, 0x04, name), bb_begin(b); }
static anole_db_value bb_value(const bson_b *b) {
  anole_db_value v = {ANOLE_DB_BLOB, 0, {.s = {(const char *)b->buf, b->len}}};
  return v;
}

/* The element `name` at the top of `doc`: its type, and a pointer to its value. */
static int bson_find(const unsigned char *doc, size_t len, const char *name, const unsigned char **value) {
  size_t at = 4;
  while (at < len && doc[at] != 0) {
    unsigned char t = doc[at++];
    const char *key = (const char *)doc + at;
    at += strlen(key) + 1;
    const unsigned char *v = doc + at;
    size_t n;
    switch (t) {
      case 0x01: case 0x09: case 0x11: case 0x12: n = 8; break;
      case 0x02: n = 4 + (size_t)(v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24); break;
      case 0x03: case 0x04: n = (size_t)(v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24); break;
      case 0x05: n = 5 + (size_t)(v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24); break;
      case 0x07: n = 12; break;
      case 0x08: n = 1; break;
      case 0x0A: n = 0; break;
      case 0x10: n = 4; break;
      default: return -1;
    }
    if (strcmp(key, name) == 0) {
      *value = v;
      return t;
    }
    at += n;
  }
  return -1;
}
static int span_has(anole_str s, const char *want) {
  size_t n = strlen(want);
  for (size_t i = 0; i + n <= s.len; i++)
    if (memcmp(s.ptr + i, want, n) == 0) return 1;
  return 0;
}
static int32_t le32(const unsigned char *v) { return (int32_t)(v[0] | v[1] << 8 | v[2] << 16 | (uint32_t)v[3] << 24); }
static int64_t le64(const unsigned char *v) { return (int64_t)((uint64_t)(uint32_t)le32(v) | (uint64_t)(uint32_t)le32(v + 4) << 32); }
static int64_t bson_int(const anole_db_result_event *r, uint32_t row, const char *name) {
  anole_str d = anole_event_str(r, db_cell(r, row, 0)->v.s);
  const unsigned char *v;
  int t = bson_find((const unsigned char *)d.ptr, d.len, name, &v);
  if (t == 0x10) return le32(v);
  if (t == 0x12) return le64(v);
  return -999;
}
static int bson_str_is(const anole_db_result_event *r, uint32_t row, const char *name, const char *want) {
  anole_str d = anole_event_str(r, db_cell(r, row, 0)->v.s);
  const unsigned char *v;
  if (bson_find((const unsigned char *)d.ptr, d.len, name, &v) != 0x02) return 0;
  return strcmp((const char *)v + 4, want) == 0;
}

/* MongoDB, against the server ANOLE_TEST_MONGODB_URL names (zig build
   capi-test -Dmongodb-test-url=...; tests/mongodb/run.sh). */
static void test_db_mongodb(void) {
  anole_str mongo_name = LIT("mongodb");
  const char *url = getenv("ANOLE_TEST_MONGODB_URL");
  if (!anole_has_feature(mongo_name) || url == NULL || url[0] == 0) {
    printf("ok mongodb (%s)\n", anole_has_feature(mongo_name) ? "no ANOLE_TEST_MONGODB_URL" : "not built in");
    return;
  }
  char json[4096];
  snprintf(json, sizeof json,
           "{\"executors\": 2, \"listeners\": [{\"port\": 0}], \"limits\": {\"db_result_max\": 65536},"
           " \"databases\": [{\"name\": \"docs\", \"mongodb\": {\"url\": \"%s\", \"database\": \"anole_capi\"}}]}",
           url);
  anole_server *s = make_server(json);
  anole_db *db = NULL;
  anole_str name = LIT("docs");
  CHECK(anole_db_find(s, name, &db) == ANOLE_OK);
  anole_consumer *c = NULL;
  anole_consumer_options co = {sizeof co, NULL, NULL, 0};
  CHECK(anole_consumer_attach(s, &co, &c) == ANOLE_OK);
  CHECK(anole_server_start(s) == ANOLE_OK);
  static unsigned char rec[1 << 20];
  static bson_b b1, b2, b3;
  const anole_db_result_event *r;
  anole_db_value p[3];

  /* a clean collection */
  anole_str drop = LIT("runCommand");
  b1.len = 0;
  bb_begin(&b1), bb_str(&b1, "drop", "items", 5), bb_end(&b1);
  p[0] = bb_value(&b1);
  CHECK(anole_db_query(db, c, drop, p, 1, NULL, 1) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec); /* ok, or NamespaceNotFound: either way it is gone */

  /* insertOne: the summary carries the new _id */
  anole_str ins1 = LIT("insertOne items");
  b1.len = 0;
  bb_begin(&b1), bb_str(&b1, "name", "apple", 5), bb_int(&b1, "qty", 3), bb_end(&b1);
  p[0] = bb_value(&b1);
  CHECK(anole_db_query(db, c, ins1, p, 1, NULL, 2) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->ncolumns == 1 && r->nrows == 1 && db_cell(r, 0, 0)->type == ANOLE_DB_BSON);
  CHECK(str_is(db_column(r, 0), "document"));
  {
    anole_str d = anole_event_str(r, db_cell(r, 0, 0)->v.s);
    const unsigned char *v;
    CHECK(bson_find((const unsigned char *)d.ptr, d.len, "insertedId", &v) == 0x07);
  }

  /* insertMany through exec: the count as changes */
  anole_str insn = LIT("insertMany items");
  b1.len = b2.len = 0;
  bb_begin(&b1), bb_str(&b1, "name", "pear", 4), bb_int(&b1, "qty", 5), bb_end(&b1);
  bb_begin(&b2), bb_str(&b2, "name", "plum", 4), bb_int(&b2, "qty", 7), bb_end(&b2);
  p[0] = bb_value(&b1), p[1] = bb_value(&b2);
  CHECK(anole_db_exec(db, c, insn, p, 2, NULL, 3) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->changes == 2 && r->nrows == 0);

  /* find with a filter and options under the command's names */
  anole_str find = LIT("find items");
  b1.len = b2.len = 0;
  bb_begin(&b1), bb_doc(&b1, "qty"), bb_int(&b1, "$gte", 4), bb_end(&b1), bb_end(&b1);
  bb_begin(&b2), bb_doc(&b2, "sort"), bb_int(&b2, "qty", -1), bb_end(&b2), bb_doc(&b2, "projection"), bb_int(&b2, "_id", 0),
      bb_end(&b2), bb_int(&b2, "batchSize", 1), bb_end(&b2);
  p[0] = bb_value(&b1), p[1] = bb_value(&b2);
  CHECK(anole_db_query(db, c, find, p, 2, NULL, 4) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->nrows == 2);
  CHECK(bson_str_is(r, 0, "name", "plum") && bson_int(r, 0, "qty") == 7 && bson_str_is(r, 1, "name", "pear"));

  /* findOne, countDocuments, aggregate */
  anole_str find1 = LIT("findOne items");
  b1.len = 0;
  bb_begin(&b1), bb_str(&b1, "name", "apple", 5), bb_end(&b1);
  p[0] = bb_value(&b1);
  CHECK(anole_db_query(db, c, find1, p, 1, NULL, 5) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->nrows == 1 && bson_int(r, 0, "qty") == 3);
  anole_str count = LIT("countDocuments items");
  CHECK(anole_db_query(db, c, count, NULL, 0, NULL, 6) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->nrows == 1 && db_cell(r, 0, 0)->type == ANOLE_DB_INT && db_cell(r, 0, 0)->v.i == 3);
  anole_str agg = LIT("aggregate items");
  b1.len = 0;
  bb_begin(&b1), bb_doc(&b1, "0"), bb_doc(&b1, "$group"), bb_key(&b1, 0x0A, "_id"), bb_doc(&b1, "total"),
      bb_str(&b1, "$sum", "$qty", 4), bb_end(&b1), bb_end(&b1), bb_end(&b1), bb_end(&b1);
  p[0] = bb_value(&b1);
  CHECK(anole_db_query(db, c, agg, p, 1, NULL, 7) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->nrows == 1 && bson_int(r, 0, "total") == 15);

  /* updateOne and deleteOne */
  anole_str upd = LIT("updateOne items");
  b1.len = b2.len = 0;
  bb_begin(&b1), bb_str(&b1, "name", "apple", 5), bb_end(&b1);
  bb_begin(&b2), bb_doc(&b2, "$inc"), bb_int(&b2, "qty", 1), bb_end(&b2), bb_end(&b2);
  p[0] = bb_value(&b1), p[1] = bb_value(&b2);
  CHECK(anole_db_query(db, c, upd, p, 2, NULL, 8) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && bson_int(r, 0, "matchedCount") == 1 && bson_int(r, 0, "modifiedCount") == 1);
  anole_str del = LIT("deleteOne items");
  b1.len = 0;
  bb_begin(&b1), bb_str(&b1, "name", "plum", 4), bb_end(&b1);
  p[0] = bb_value(&b1);
  CHECK(anole_db_exec(db, c, del, p, 1, NULL, 9) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK && r->changes == 1);

  /* a unique index, then a duplicate: 409 with the server's code */
  anole_str cmd = LIT("runCommand");
  b1.len = 0;
  bb_begin(&b1), bb_str(&b1, "createIndexes", "items", 5), bb_arr(&b1, "indexes"), bb_doc(&b1, "0"), bb_doc(&b1, "key"),
      bb_int(&b1, "name", 1), bb_end(&b1), bb_str(&b1, "name", "name_1", 6), bb_bool(&b1, "unique", 1), bb_end(&b1),
      bb_end(&b1), bb_end(&b1);
  p[0] = bb_value(&b1);
  CHECK(anole_db_query(db, c, cmd, p, 1, NULL, 10) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK);
  b1.len = 0;
  bb_begin(&b1), bb_str(&b1, "name", "apple", 5), bb_end(&b1);
  p[0] = bb_value(&b1);
  CHECK(anole_db_exec(db, c, ins1, p, 1, NULL, 11) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_DB && r->http_status == 409 && r->error_class == ANOLE_DB_ERR_UNIQUE);
  CHECK(str_is(anole_event_str(r, r->error_code), "11000"));

  /* calls Anole refuses: 400 */
  anole_str nope = LIT("frobnicate items"), bare = LIT("find");
  CHECK(anole_db_query(db, c, nope, NULL, 0, NULL, 12) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_DB && r->http_status == 400);
  CHECK(anole_db_query(db, c, bare, NULL, 0, NULL, 13) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->http_status == 400);
  anole_db_value text = {ANOLE_DB_TEXT, 0, {.s = LIT("{}")}};
  CHECK(anole_db_query(db, c, find, &text, 1, NULL, 14) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->http_status == 400);
  b1.len = b2.len = 0;
  bb_begin(&b1), bb_end(&b1);
  bb_begin(&b2), bb_int(&b2, "limt", 1), bb_end(&b2);
  p[0] = bb_value(&b1), p[1] = bb_value(&b2);
  CHECK(anole_db_query(db, c, find, p, 2, NULL, 15) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->http_status == 400 && span_has(anole_event_str(r, r->error), "limt"));

  /* the cache: a hit until invalidated */
  anole_db_options cached = {sizeof cached, 0, 0, 60000, 0, LIT("items")};
  for (int round = 0; round < 3; round++) {
    CHECK(anole_db_query(db, c, find, NULL, 0, &cached, 20) == ANOLE_OK);
    r = db_next(c, rec, sizeof rec);
    CHECK(r->status == ANOLE_OK && r->nrows == 2);
    if (round == 2) CHECK(r->source == ANOLE_DB_FROM_CACHE);
  }
  anole_str items = LIT("items");
  CHECK(anole_db_invalidate(db, items) == ANOLE_OK);
  CHECK(anole_db_query(db, c, find, NULL, 0, &cached, 21) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->source == ANOLE_DB_FROM_DATABASE);

  /* many at once, coalesced */
  enum { MANY = 200 };
  anole_db_options co_opts = {sizeof co_opts, ANOLE_DB_COALESCE, 0, 0, 0, {NULL, 0}};
  for (int i = 0; i < MANY; i++) CHECK(anole_db_query(db, c, count, NULL, 0, &co_opts, 1000 + i) == ANOLE_OK);
  int coalesced = 0;
  for (int i = 0; i < MANY; i++) {
    r = db_next(c, rec, sizeof rec);
    CHECK(r->status == ANOLE_OK && db_cell(r, 0, 0)->v.i == 2);
    if (r->source == ANOLE_DB_FROM_COALESCED) coalesced++;
  }

  /* a timeout: a filter that sleeps on the server */
  b1.len = 0;
  bb_begin(&b1), bb_str(&b1, "$where", "sleep(3000) || true", 19), bb_end(&b1);
  p[0] = bb_value(&b1);
  anole_db_options quick = {sizeof quick, 0, 200, 0, 0, {NULL, 0}};
  double t0 = now_ms();
  CHECK(anole_db_query(db, c, find, p, 1, &quick, 30) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_TIMEOUT && r->http_status == 504);
  CHECK(now_ms() - t0 < 2500);

  /* an answer past limits.db_result_max */
  static char big[70000];
  memset(big, 'x', sizeof big);
  b3.len = 0;
  bb_begin(&b3), bb_str(&b3, "name", "big", 3), bb_str(&b3, "blob", big, sizeof big), bb_end(&b3);
  p[0] = bb_value(&b3);
  CHECK(anole_db_exec(db, c, ins1, p, 1, NULL, 31) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK);
  CHECK(anole_db_query(db, c, find, NULL, 0, NULL, 32) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_E_TOOBIG);

  b1.len = 0;
  bb_begin(&b1), bb_str(&b1, "drop", "items", 5), bb_end(&b1);
  p[0] = bb_value(&b1);
  CHECK(anole_db_query(db, c, drop, p, 1, NULL, 33) == ANOLE_OK);
  r = db_next(c, rec, sizeof rec);
  CHECK(r->status == ANOLE_OK);
  CHECK(anole_server_drain(s) == ANOLE_OK);
  CHECK(anole_server_wait(s, -1) == ANOLE_OK);
  anole_server_destroy(s);
  printf("ok mongodb: CRUD and aggregate with BSON both ways, errors, cache, %d of %d coalesced, timeout, size limit\n",
         coalesced, MANY);
}

/* ---- WebTransport: the server in C, the client in Zig (tests/capi/wt_client.zig,
   passed as the second argument) ---------------------------------------------- */

static const char *wt_client_path;

typedef struct {
  anole_wt_stream h;
  anole_wt session;
  int uni, ours, used;
  char got[64];
  size_t len;
} wt_ent;

typedef struct {
  wt_ent ents[32];
  anole_wt session;
  anole_wt_stream first_stream; /* for the stale check after the close */
  int opened, closed, released, drains, borrow_sent;
  uint32_t close_code, close_by;
  char reason[64];
} wt_state;

static wt_ent *wt_find(wt_state *st, anole_wt_stream h) {
  for (int i = 0; i < 32; i++)
    if (st->ents[i].used && st->ents[i].h == h) return &st->ents[i];
  return NULL;
}

static wt_ent *wt_add(wt_state *st, anole_wt_stream h, anole_wt session, int uni, int ours) {
  for (int i = 0; i < 32; i++)
    if (!st->ents[i].used) {
      wt_ent *e = &st->ents[i];
      memset(e, 0, sizeof *e);
      e->used = 1, e->h = h, e->session = session, e->uni = uni, e->ours = ours;
      if (!st->first_stream) st->first_stream = h;
      return e;
    }
  CHECK(0);
  return NULL;
}

static void wt_forget(wt_state *st, wt_ent *e) {
  CHECK(anole_wt_stream_release(e->h) == ANOLE_OK);
  /* Stale at once. */
  CHECK(anole_wt_stream_write(e->h, "x", 1, 0) == ANOLE_E_GONE);
  e->used = 0;
  st->released++;
}

/* Borrowed by a WebTransport write: static, as it must stay until
   ANOLE_EV_SENT. */
static const char wt_borrowed[] = "hello ";

static void wt_event(wt_state *st, const anole_event *ev) {
  switch (ev->type) {
  case ANOLE_EV_SENT: {
    const anole_sent_event *se = (const anole_sent_event *)ev;
    if (se->data == (uint64_t)(uintptr_t)wt_borrowed && se->len == 6) st->borrow_sent++;
    break;
  }
  case ANOLE_EV_WT_OPEN: {
    const anole_request_event *r = (const anole_request_event *)ev;
    CHECK(r->route_id == 5);
    CHECK(str_is(anole_event_str(r, r->path), "/wt"));
    st->session = ev->handle;
    st->opened++;
    CHECK(anole_wt_max_datagram(ev->handle) > 0);
    anole_wt_stream u = 0;
    CHECK(anole_wt_open_stream(ev->handle, ANOLE_WT_UNI, &u) == ANOLE_OK && u != 0);
    /* Bit 0 is ANOLE_BODY_BORROW on every send-type call: a borrowed
       write does not end the stream (ANOLE_EV_SENT follows); unknown flag
       bits are refused. */
    CHECK(anole_wt_stream_write(u, wt_borrowed, 6, ANOLE_BODY_BORROW) == ANOLE_OK);
    CHECK(anole_wt_stream_write(u, "x", 1, 0x80) == ANOLE_E_INVALID);
    CHECK(anole_wt_stream_write(u, "from C", 6, ANOLE_WT_FIN) == ANOLE_OK);
    /* Written with its end: still goes out whole after the release. */
    CHECK(anole_wt_stream_write(u, "more", 4, 0) == ANOLE_E_INVALID);
    CHECK(anole_wt_stream_release(u) == ANOLE_OK);
    CHECK(anole_wt_open_stream(ev->handle, 4, &u) == ANOLE_E_INVALID);
    break;
  }
  case ANOLE_EV_WT_STREAM: {
    const anole_wt_stream_event *se = (const anole_wt_stream_event *)ev;
    CHECK(se->session == st->session && se->route_id == 5);
    wt_add(st, ev->handle, se->session, (se->flags & ANOLE_WT_UNI) != 0, 0);
    if (se->flags & ANOLE_WT_UNI) CHECK(anole_wt_stream_write(ev->handle, "x", 1, 0) == ANOLE_E_INVALID);
    break;
  }
  case ANOLE_EV_WT_DATA: {
    const anole_wt_data_event *de = (const anole_wt_data_event *)ev;
    wt_ent *e = wt_find(st, ev->handle);
    CHECK(e != NULL);
    anole_str d = anole_event_str(de, de->data);
    int fin = (de->flags & ANOLE_WT_FIN) != 0;
    if (e->uni || e->ours) {
      CHECK(e->len + d.len <= sizeof e->got);
      memcpy(e->got + e->len, d.ptr, d.len);
      e->len += d.len;
      if (!fin) break;
      char out[32];
      int n;
      if (e->uni) {
        n = snprintf(out, sizeof out, "uni:%zu", e->len);
      } else {
        CHECK(e->len == 6 && memcmp(e->got, "thanks", 6) == 0);
        n = snprintf(out, sizeof out, "thanked");
      }
      /* Released before the answer: the client closes the session once it
         has "thanked", and a stream is stale from its session's close on. */
      anole_wt session = e->session;
      wt_forget(st, e);
      CHECK(anole_wt_send_datagram(session, out, (size_t)n) == ANOLE_OK);
    } else {
      anole_status rc = anole_wt_stream_write(ev->handle, d.ptr, d.len, fin ? ANOLE_WT_FIN : 0);
      CHECK(rc == ANOLE_OK || rc == ANOLE_BUSY);
      if (fin) wt_forget(st, e);
    }
    break;
  }
  case ANOLE_EV_WT_DATAGRAM: {
    const anole_wt_datagram_event *de = (const anole_wt_datagram_event *)ev;
    anole_str d = anole_event_str(de, de->data);
    char out[128];
    int n = snprintf(out, sizeof out, "echo:%.*s", (int)d.len, d.ptr);
    CHECK(anole_wt_send_datagram(ev->handle, out, (size_t)n) == ANOLE_OK);
    if (d.len == 4 && memcmp(d.ptr, "open", 4) == 0) {
      anole_wt_stream b = 0;
      CHECK(anole_wt_open_stream(ev->handle, 0, &b) == ANOLE_OK);
      wt_add(st, b, ev->handle, 0, 1);
      CHECK(anole_wt_stream_write(b, "from C", 6, ANOLE_WT_FIN) == ANOLE_OK);
    }
    break;
  }
  case ANOLE_EV_WT_DRAIN:
    st->drains++;
    break;
  case ANOLE_EV_WT_CLOSE: {
    const anole_wt_close_event *ce = (const anole_wt_close_event *)ev;
    CHECK(ev->handle == st->session && ce->route_id == 5);
    st->close_code = ce->code;
    st->close_by = ce->by;
    anole_str r = anole_event_str(ce, ce->reason);
    snprintf(st->reason, sizeof st->reason, "%.*s", (int)r.len, r.ptr);
    st->closed++;
    break;
  }
  default:
    break;
  }
}

static void test_webtransport(void) {
  anole_str name = LIT("webtransport");
  if (!anole_has_feature(name) || wt_client_path == NULL) {
    printf("ok webtransport (%s)\n", anole_has_feature(name) ? "no client given" : "not built in");
    return;
  }
  const char *json = "{\"executors\": 2, \"timeouts\": {\"shutdown_ms\": 2000},"
                     " \"listeners\": [{\"port\": 0, \"tls\": {\"self_signed\": true}, \"http3\": true}],"
                     " \"routes\": [{\"path\": \"/wt\", \"webtransport\": {\"handler\": 5}}]}";
  anole_server *s = make_server(json);
  anole_consumer *c = NULL;
  anole_consumer_options co = {sizeof co, NULL, NULL, 0};
  CHECK(anole_consumer_attach(s, &co, &c) == ANOLE_OK);
  CHECK(anole_server_start(s) == ANOLE_OK);
  uint16_t port = 0;
  CHECK(anole_server_port(s, 1, &port) == ANOLE_OK && port != 0);

  pid_t pid = fork();
  CHECK(pid >= 0);
  if (pid == 0) {
    char arg[16];
    snprintf(arg, sizeof arg, "%u", port);
    execl(wt_client_path, wt_client_path, arg, (char *)NULL);
    _exit(127);
  }
  static wt_state st;
  memset(&st, 0, sizeof st);
  static char buf[256 * 1024] __attribute__((aligned(8)));
  int exited = 0, status = 0;
  double deadline = now_ms() + 20000;
  while ((!exited || !st.closed) && now_ms() < deadline) {
    int64_t n = anole_poll_wait(c, buf, sizeof buf, 50);
    CHECK(n >= 0);
    for (int64_t off = 0; off < n;) {
      const anole_event *ev = (const anole_event *)(buf + off);
      wt_event(&st, ev);
      off += ev->len;
    }
    if (!exited && waitpid(pid, &status, WNOHANG) == pid) exited = 1;
  }
  if (!exited) {
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
  }
  CHECK(exited && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  CHECK(st.opened == 1 && st.closed == 1);
  CHECK(st.close_code == 7 && st.close_by == ANOLE_WT_CLOSED_PEER && strcmp(st.reason, "done") == 0);
  CHECK(st.released >= 3);
  CHECK(st.borrow_sent == 1);
  /* The session and its streams are stale after the close. */
  CHECK(anole_wt_close(st.session, 0, LIT("")) == ANOLE_E_GONE);
  CHECK(anole_wt_send_datagram(st.session, "x", 1) == ANOLE_E_GONE);
  CHECK(anole_wt_max_datagram(st.session) == ANOLE_E_GONE);
  anole_wt_stream x = 0;
  CHECK(anole_wt_open_stream(st.session, 0, &x) == ANOLE_E_GONE);
  CHECK(anole_wt_stream_write(st.first_stream, "x", 1, 0) == ANOLE_E_GONE);
  CHECK(anole_wt_stream_reset(st.first_stream, 1) == ANOLE_E_GONE);
  /* A request handle is not a session. */
  CHECK(anole_wt_close(1, 0, LIT("")) == ANOLE_E_GONE);
  anole_stats stats = {sizeof stats};
  CHECK(anole_server_stats(s, &stats) == ANOLE_OK && stats.wt_sessions == 0);
  CHECK(anole_server_drain(s) == ANOLE_OK);
  CHECK(anole_server_wait(s, -1) == ANOLE_OK);
  anole_server_destroy(s);
  printf("ok webtransport: a session from a Zig client, streams both ways, datagrams, the client's close\n");
}

static void test_tls(void) {
  anole_str name = LIT("tls");
  if (!anole_has_feature(name)) {
    printf("ok tls (not built in)\n");
    return;
  }
  /* Mutual TLS settings the configuration refuses. */
  const char *bad[] = {
      "{\"listeners\": [{\"tls\": {\"self_signed\": true, \"client_auth\": \"always\"}}]}",
      "{\"listeners\": [{\"tls\": {\"self_signed\": true, \"client_auth\": \"require\"}}]}",
      "{\"listeners\": [{\"tls\": {\"self_signed\": true, \"client_ca_file\": \"ca.pem\"}}]}",
      "{\"listeners\": [{\"proxy_protocol_from\": [\"10.0.0.0/8\"]}]}",
  };
  for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
    anole_server_options o = {sizeof o, {bad[i], strlen(bad[i])}, 0, 0, on_log, NULL};
    anole_server *x = NULL;
    CHECK(anole_server_create(&o, &x) == ANOLE_E_CONFIG && x == NULL);
    CHECK(anole_last_error().len > 0);
  }
  /* Settings it takes. */
  anole_server *p = make_server("{\"trusted_proxy_hops\": 1, \"trust_forwarded_proto\": false,"
                                " \"trust_forwarded_host\": true, \"listeners\": [{\"port\": 0,"
                                " \"proxy_protocol\": true, \"proxy_protocol_from\": [\"127.0.0.1\", \"10.0.0.0/8\"]}]}");
  CHECK(anole_server_start(p) == ANOLE_OK);
  /* No TLS listener: nothing to reload. */
  CHECK(anole_server_reload_tls(p, 0, NULL, 0, NULL, 0) == ANOLE_E_STATE);
  CHECK(anole_server_reload_certificates(p) == ANOLE_E_STATE);
  CHECK(anole_server_drain(p) == ANOLE_OK);
  CHECK(anole_server_wait(p, -1) == ANOLE_OK);
  anole_server_destroy(p);

  anole_server *s = make_server("{\"listeners\": [{\"port\": 0, \"tls\": {\"self_signed\": true}}]}");
  /* Not running yet. */
  CHECK(anole_server_reload_tls(s, 0, NULL, 0, NULL, 0) == ANOLE_E_STATE);
  CHECK(anole_server_start(s) == ANOLE_OK);
  CHECK(anole_server_reload_tls(s, 0, NULL, 0, NULL, 0) == ANOLE_OK);
  CHECK(anole_server_reload_tls(s, 2, NULL, 0, NULL, 0) == ANOLE_E_INVALID);
  CHECK(anole_server_reload_tls(s, 0, NULL, 0, "k", 1) == ANOLE_E_INVALID);
  CHECK(anole_server_reload_tls(s, ANOLE_TLS_PEM, "c", 0, "k", 1) == ANOLE_E_INVALID);
  const char junk[] = "-----BEGIN CERTIFICATE-----\nnot base64\n-----END CERTIFICATE-----\n";
  CHECK(anole_server_reload_tls(s, ANOLE_TLS_PEM, junk, strlen(junk), junk, strlen(junk)) == ANOLE_E_INVALID);
  CHECK(anole_last_error().len > 0);
  const char *missing = "/nonexistent/anole-cert.pem";
  CHECK(anole_server_reload_tls(s, 0, missing, strlen(missing), missing, strlen(missing)) == ANOLE_E_SYSTEM);
  /* Still serving the certificate it had: a reload from it works. */
  CHECK(anole_server_reload_certificates(s) == ANOLE_OK);
  CHECK(anole_server_drain(s) == ANOLE_OK);
  CHECK(anole_server_wait(s, -1) == ANOLE_OK);
  anole_server_destroy(s);
  printf("ok tls: mutual TLS and proxy settings in the configuration, anole_server_reload_tls's refusals\n");
}

/* A hang fails the run instead of holding CI until the job's timeout: the
   last "ok" line printed (stdout is line-buffered) names the last step that
   passed. abort() leaves a core where cores are kept. */
static void on_watchdog(int sig) {
  (void)sig;
  const char *msg = "FAIL: still running after the watchdog's limit (hung); the step after the last \"ok\" line hangs\n";
  (void)!write(2, msg, strlen(msg));
  abort();
}

static void start_watchdog(unsigned seconds) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  signal(SIGALRM, on_watchdog);
  alarm(seconds);
}

static int run_tests(void) {
  start_watchdog(600);
  anole_str ws = {"websocket", 9};
  have_websocket = anole_has_feature(ws);
  test_basics();
  test_route_conflicts();
  test_main_server();
  test_stale_across_servers();
  test_shared_consumer();
  test_db();
  test_db_postgres();
  test_db_redis();
  test_db_mongodb();
  test_webtransport();
  test_tls();
  printf("PASS\n");
  return 0;
}

/* ---- the benchmark server ----------------------------------------------------------------- */

static void bench_event(consumer_state *cs, const anole_event *ev) {
  (void)cs;
  if (ev->type != ANOLE_EV_REQUEST) return;
  const anole_request_event *r = (const anole_request_event *)ev;
  anole_req h = r->ev.handle;
  if (r->route_id == R_USER) {
    anole_str id = param_of(r, "id");
    char out[128];
    int n = snprintf(out, sizeof out, "user %.*s", (int)id.len, id.ptr);
    anole_respond(h, 200, text_plain, 1, out, (size_t)n, 0);
  } else if (r->route_id == R_ECHO) {
    anole_str b = anole_event_str(r, r->body);
    anole_respond(h, 200, text_plain, 1, b.ptr, b.len, 0);
  } else {
    anole_respond(h, 200, text_plain, 1, "Hello, World!", 13, 0);
  }
}

static int serve(int executors, int port, int consumers) {
  char json[2048];
  snprintf(json, sizeof json,
           "{\"listeners\":[{\"address\":\"127.0.0.1\",\"port\":%d}],\"executors\":%d,"
           "\"limits\":{\"max_inflight\":4096},"
           "\"routes\":["
           "{\"method\":\"GET\",\"path\":\"/native\",\"respond\":{\"status\":200,\"body\":\"Hello, World!\","
           "\"headers\":{\"content-type\":\"text/plain\"}}},"
           "{\"method\":\"GET\",\"path\":\"/native-task\",\"no_wait\":false,\"respond\":{\"status\":200,"
           "\"body\":\"Hello, World!\",\"headers\":{\"content-type\":\"text/plain\"}}},"
           "{\"method\":\"GET\",\"path\":\"/hello\",\"handler\":1},"
           "{\"method\":\"GET\",\"path\":\"/hello-task\",\"handler\":1,\"no_wait\":false},"
           "{\"method\":\"POST\",\"path\":\"/echo\",\"handler\":2},"
           "{\"method\":\"GET\",\"path\":\"/users/:id\",\"handler\":4}]}",
           port, executors);
  anole_server *s = make_server(json);
  static consumer_state cs[16];
  anole_consumer_options co = {sizeof co, NULL, NULL, 0};
  const char *spin = getenv("CAPI_SPIN_US");
  for (int i = 0; i < consumers; i++) {
    cs[i].spin_us = spin ? atoi(spin) : 0;
    cs[i].on_event = bench_event;
    CHECK(anole_consumer_attach(s, &co, &cs[i].c) == ANOLE_OK);
  }
  CHECK(anole_server_start(s) == ANOLE_OK);
  for (int i = 0; i < consumers; i++) start_consumer(&cs[i]);
  fprintf(stderr, "serving on 127.0.0.1:%d with %d executors, %d consumer thread(s)\n", port, executors, consumers);
  char c;
  while (read(0, &c, 1) > 0) {}
  anole_stats st = {.size = sizeof st};
  anole_server_stats(s, &st);
  uint64_t ev = 0, b = 0;
  for (int i = 0; i < consumers; i++) ev += cs[i].events, b += cs[i].batches;
  fprintf(stderr, "events %llu batches %llu (%.1f per batch) wakes %llu rewakes %llu detached %llu expired %llu\n",
          (unsigned long long)ev, (unsigned long long)b, b ? (double)ev / b : 0.0, (unsigned long long)st.wakes,
          (unsigned long long)st.rewakes, (unsigned long long)st.detached, (unsigned long long)st.expired);
  anole_server_drain(s);
  anole_server_wait(s, -1);
  for (int i = 0; i < consumers; i++) pthread_join(cs[i].thread, NULL);
  anole_server_destroy(s);
  return 0;
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  CHECK((anole_abi_version() >> 16) == ANOLE_ABI_VERSION_MAJOR);
  if (argc >= 2 && strcmp(argv[1], "test") == 0) {
    /* The WebTransport client (tests/capi/wt_client.zig), when built. */
    if (argc >= 3) wt_client_path = argv[2];
    return run_tests();
  }
  if (argc >= 4 && strcmp(argv[1], "serve") == 0)
    return serve(atoi(argv[2]), atoi(argv[3]), argc >= 5 ? atoi(argv[4]) : 1);
  fprintf(stderr, "usage: consumer test | consumer serve <executors> <port> [consumers]\n");
  return 2;
}
