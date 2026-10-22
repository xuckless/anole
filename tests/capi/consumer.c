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
  int use_wait; /* anole_poll_wait instead of the fd */
  _Alignas(8) unsigned char buf[256 * 1024];
  /* for tests */
  anole_req held[64];
  atomic_int nheld;
  atomic_int sent, aborts, ws_open, ws_msgs, ws_closes, last_close_code;
  atomic_uintptr_t last_sent;
  atomic_ullong ws_handle;
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
    int i = atomic_fetch_add(&cs->nheld, 1);
    CHECK(i < 64);
    cs->held[i] = h;
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
    if (str_is(d, "bye")) {
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
    int ab0 = atomic_load(&cs.aborts);
    atomic_store(&cs.nheld, 0);
    int fd = dial(port);
    send_request(fd, "GET", "/hold", NULL, 0);
    CHECK(wait_for(&cs.nheld, 1));
    close(fd);
    CHECK(wait_for(&cs.aborts, ab0 + 1));
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
    /* a subscriber that stops reading: publishes held up by it are bounded */
    {
      static char chunk[64 * 1024];
      uint32_t x = 12345;
      for (size_t i = 0; i < sizeof chunk; i++) {
        x = x * 1103515245u + 12345u;
        chunk[i] = (char)(x >> 24);
      }
      ws_connect(&c, port);
      CHECK(wait_for(&cs.ws_open, 3));
      int refused = 0;
      for (int i = 0; i < 8000 && !refused; i++) {
        anole_status st = anole_ws_publish(s, room, ANOLE_WS_BINARY, chunk, sizeof chunk, 0);
        CHECK(st == ANOLE_OK || st == ANOLE_E_AGAIN);
        if (st == ANOLE_E_AGAIN) refused = 1;
      }
      CHECK(refused);
      close(c.fd);
      CHECK(wait_for(&cs.ws_closes, 3));
      /* the held-up publishes end with the socket */
      int ok = 0;
      for (int i = 0; i < 300 && !ok; i++) {
        if (anole_ws_publish(s, room, ANOLE_WS_TEXT, "x", 1, 0) == ANOLE_OK) ok = 1;
        else usleep(10000);
      }
      CHECK(ok);
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

static int run_tests(void) {
  anole_str ws = {"websocket", 9};
  have_websocket = anole_has_feature(ws);
  test_basics();
  test_main_server();
  test_shared_consumer();
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
  if (argc >= 2 && strcmp(argv[1], "test") == 0) return run_tests();
  if (argc >= 4 && strcmp(argv[1], "serve") == 0)
    return serve(atoi(argv[2]), atoi(argv[3]), argc >= 5 ? atoi(argv[4]) : 1);
  fprintf(stderr, "usage: consumer test | consumer serve <executors> <port> [consumers]\n");
  return 2;
}
