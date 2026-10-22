/* tests/capi/grpc.c - the C ABI's gRPC server, tested from C (exit 0 = pass).
 *
 * A consumer thread implements anole.test.Echo (unary, server streaming,
 * client streaming, bidi) through anole.h alone, with no protobuf: its
 * messages are raw bytes, and the configuration lists the methods and their
 * call modes (no descriptors). The test speaks gRPC-Web over HTTP/1.1 with
 * a blocking socket client: every call mode, an error status with trailing
 * metadata, request and response metadata (-bin too), a deadline
 * (grpc-timeout), a cancel (the client hangs up), backpressure (ANOLE_BUSY
 * and ANOLE_EV_WRITABLE, and anole_grpc_send_wait), the answers' state
 * checks, and grpc.health.v1. Over HTTP/2 the Zig suite
 * (src/capi/grpc_test.zig) covers the same calls with descriptors, JSON and
 * transcoding.
 */
#define _GNU_SOURCE
#include "anole.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
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

static anole_str S(const char *s) {
  anole_str r = {s, strlen(s)};
  return r;
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

static void sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}

static void on_log(void *ud, int level, anole_str scope, anole_str msg) {
  (void)ud;
  if (level <= ANOLE_LOG_WARN || getenv("CAPI_LOG"))
    fprintf(stderr, "[%d %.*s] %.*s\n", level, (int)scope.len, scope.ptr, (int)msg.len, msg.ptr);
}

/* ---- the consumer -------------------------------------------------------------- */

enum { M_UNARY, M_SERVER, M_CLIENT, M_BIDI };

typedef struct {
  anole_grpc_call call;
  int kind;
  char acc[4096]; /* client streaming: the messages so far */
  size_t acc_len;
  int busy;          /* a "busy" server stream: pump_busy sends it */
  int left;          /* messages still to send */
  size_t last_size;  /* the last message's size, when not 1 KiB */
  int index;
} call_state;

static anole_consumer *consumer;
static atomic_int stop_consumer;
static atomic_int failures;
static atomic_ullong held;       /* a call left unanswered ("hold") */
static atomic_ullong last_abort; /* the handle of the last ANOLE_EV_ABORT */
static atomic_int writables, busies;
static atomic_llong held_timeout_us = -2;
static call_state calls[64];

static call_state *state_of(anole_grpc_call c, int create) {
  for (int i = 0; i < 64; i++)
    if (calls[i].call == c) return &calls[i];
  if (!create) return NULL;
  for (int i = 0; i < 64; i++)
    if (calls[i].call == 0) {
      memset(&calls[i], 0, sizeof calls[i]);
      calls[i].call = c;
      return &calls[i];
    }
  CHECK(!"too many calls");
  return NULL;
}

static void drop(anole_grpc_call c) {
  call_state *st = state_of(c, 0);
  if (st) st->call = 0;
}

static anole_str md_of(const anole_grpc_call_event *ev, const char *name) {
  const anole_span *sp = (const anole_span *)(ev + 1);
  for (uint16_t i = 0; i < ev->nmetadata; i++) {
    anole_str k = anole_event_str(ev, sp[2 * i]);
    if (k.len == strlen(name) && memcmp(k.ptr, name, k.len) == 0) return anole_event_str(ev, sp[2 * i + 1]);
  }
  anole_str none = {NULL, 0};
  return none;
}

static int is(anole_str s, const char *lit) { return s.len == strlen(lit) && memcmp(s.ptr, lit, s.len) == 0; }

/* Sends the rest of a "busy" stream until ANOLE_BUSY, or finishes it. */
static void pump_busy(call_state *st) {
  static char kb[1024], big[5000];
  memset(kb, 'b', sizeof kb);
  memset(big, 'B', sizeof big);
  while (st->left > 0) {
    st->left--;
    int last_big = st->left == 0 && st->last_size == sizeof big;
    anole_status r = anole_grpc_send(st->call, last_big ? big : kb, last_big ? sizeof big : sizeof kb, 0);
    CHECK(r == ANOLE_OK || r == ANOLE_BUSY);
    if (r == ANOLE_BUSY) {
      atomic_fetch_add(&busies, 1);
      return; /* ANOLE_EV_WRITABLE comes */
    }
  }
  CHECK(anole_grpc_finish(st->call, ANOLE_GRPC_OK, S(""), NULL, 0) == ANOLE_OK);
  drop(st->call);
}

static void on_call(const anole_grpc_call_event *ev) {
  anole_grpc_call c = ev->ev.handle;
  anole_str method = anole_event_str(ev, ev->method);
  anole_str msg = anole_event_str(ev, ev->message);
  CHECK(ev->route_id == 1);
  /* gRPC-Web over HTTP/1.1, but the cancel test's gRPC over HTTP/2. */
  CHECK(ev->version == 11 || ev->version == 20);
  CHECK(ev->protocol == (ev->version == 20 ? ANOLE_GRPC_PROTOCOL_GRPC : ANOLE_GRPC_PROTOCOL_GRPC_WEB));
  switch (ev->method_id) {
    case M_UNARY: {
      CHECK(is(method, "/anole.test.Echo/Unary") && ev->kind == ANOLE_GRPC_UNARY);
      CHECK(ev->flags & ANOLE_GRPC_CALL_MESSAGE);
      /* The protocols' own headers are not metadata. */
      CHECK(md_of(ev, "content-type").ptr == NULL && md_of(ev, "te").ptr == NULL);
      CHECK(ev->version == 20 || md_of(ev, "x-grpc-web").len == 1);
      if (is(msg, "fail")) {
        anole_header t[2] = {{S("x-why"), S("test")}, {S("x-raw-bin"), {"\x00\x01\xff", 3}}};
        CHECK(anole_grpc_finish(c, ANOLE_GRPC_NOT_FOUND, S("no such thing"), t, 2) == ANOLE_OK);
        return;
      }
      if (is(msg, "hold")) {
        atomic_store(&held_timeout_us, ev->timeout_us);
        atomic_store(&held, c);
        return;
      }
      if (is(msg, "checks")) {
        /* Metadata: names checked, -bin values are bytes. */
        anole_header bad[1] = {{S("X-Upper"), S("v")}};
        CHECK(anole_grpc_send_headers(c, bad, 1) == ANOLE_E_INVALID);
        anole_header reserved[1] = {{S("grpc-status"), S("0")}};
        CHECK(anole_grpc_send_headers(c, reserved, 1) == ANOLE_E_INVALID);
        anole_header ctl[1] = {{S("x-a"), S("line\r\nbreak")}};
        CHECK(anole_grpc_send_headers(c, ctl, 1) == ANOLE_E_INVALID);
        /* OK without the message: refused for a unary call. */
        CHECK(anole_grpc_finish(c, ANOLE_GRPC_OK, S(""), NULL, 0) == ANOLE_E_STATE);
        CHECK(anole_grpc_read(c, 1) == ANOLE_E_STATE);
        anole_header h[1] = {{S("x-initial"), S("yes")}};
        CHECK(anole_grpc_send_headers(c, h, 1) == ANOLE_OK);
        CHECK(anole_grpc_send_headers(c, h, 1) == ANOLE_E_STATE);
        anole_str bin = md_of(ev, "x-data-bin");
        CHECK(bin.len == 3 && memcmp(bin.ptr, "\x00\x01\xff", 3) == 0);
        CHECK(anole_grpc_send(c, "checked", 7, 0) == ANOLE_OK);
        CHECK(anole_grpc_send(c, "again", 5, 0) == ANOLE_E_STATE);
        anole_str trace = md_of(ev, "x-trace");
        anole_header t[1] = {{S("x-echoed"), trace}};
        CHECK(anole_grpc_finish(c, ANOLE_GRPC_OK, S(""), t, 1) == ANOLE_OK);
        CHECK(anole_grpc_finish(c, ANOLE_GRPC_OK, S(""), NULL, 0) == ANOLE_E_GONE);
        return;
      }
      /* Echo, borrowed: ANOLE_EV_SENT is not awaited (the record outlives the call here). */
      CHECK(anole_grpc_send(c, msg.ptr, msg.len, ANOLE_GRPC_SEND_FINISH) == ANOLE_OK);
      return;
    }
    case M_SERVER: {
      CHECK(ev->kind == ANOLE_GRPC_SERVER_STREAMING);
      if (is(msg, "busy")) {
        call_state *st = state_of(c, 1);
        st->busy = 1;
        st->left = 64;
        pump_busy(st);
        return;
      }
      if (is(msg, "busylast")) {
        /* The last message is past the high-water mark by itself. */
        call_state *st = state_of(c, 1);
        st->busy = 1;
        st->left = 2;
        st->last_size = 5000;
        pump_busy(st);
        return;
      }
      if (is(msg, "wait")) {
        /* The blocking form: waits for room itself. */
        static char kb[1024];
        memset(kb, 'w', sizeof kb);
        for (int i = 0; i < 64; i++) CHECK(anole_grpc_send_wait(c, kb, sizeof kb, 5000) == ANOLE_OK);
        CHECK(anole_grpc_finish(c, ANOLE_GRPC_OK, S(""), NULL, 0) == ANOLE_OK);
        return;
      }
      int n = 0;
      for (size_t i = 0; i < msg.len; i++) n = n * 10 + (msg.ptr[i] - '0');
      for (int i = 0; i < n; i++) {
        char m[32];
        int k = snprintf(m, sizeof m, "tick%d", i);
        anole_status r = anole_grpc_send(c, m, (size_t)k, i == n - 1 ? ANOLE_GRPC_SEND_FINISH : 0);
        CHECK(r == ANOLE_OK || r == ANOLE_BUSY);
      }
      if (n == 0) CHECK(anole_grpc_finish(c, ANOLE_GRPC_OK, S(""), NULL, 0) == ANOLE_OK);
      return;
    }
    case M_CLIENT:
    case M_BIDI: {
      CHECK(!(ev->flags & ANOLE_GRPC_CALL_MESSAGE));
      call_state *st = state_of(c, 1);
      st->kind = ev->method_id;
      return;
    }
  }
  CHECK(!"unknown method");
}

static void on_message(const anole_grpc_message_event *ev) {
  anole_grpc_call c = ev->ev.handle;
  call_state *st = state_of(c, 0);
  CHECK(st);
  anole_str data = anole_event_str(ev, ev->data);
  if (st->kind == M_CLIENT) {
    CHECK(st->acc_len + data.len <= sizeof st->acc);
    memcpy(st->acc + st->acc_len, data.ptr, data.len);
    st->acc_len += data.len;
  } else {
    char m[256];
    int k = snprintf(m, sizeof m, "%.*s#%d", (int)data.len, data.ptr, st->index++);
    anole_status r = anole_grpc_send(c, m, (size_t)k, 0);
    CHECK(r == ANOLE_OK || r == ANOLE_BUSY);
  }
  CHECK(anole_grpc_read(c, 1) == ANOLE_OK);
}

static void on_half_close(anole_grpc_call c) {
  call_state *st = state_of(c, 0);
  CHECK(st);
  if (st->kind == M_CLIENT) {
    CHECK(anole_grpc_send(c, st->acc, st->acc_len, 0) == ANOLE_OK);
    anole_header t[1] = {{S("x-count"), S("done")}};
    CHECK(anole_grpc_finish(c, ANOLE_GRPC_OK, S(""), t, 1) == ANOLE_OK);
  } else {
    CHECK(anole_grpc_finish(c, ANOLE_GRPC_OK, S(""), NULL, 0) == ANOLE_OK);
  }
  drop(c);
}

static void *consumer_main(void *arg) {
  (void)arg;
  static _Alignas(8) unsigned char buf[256 * 1024];
  while (!atomic_load(&stop_consumer)) {
    int64_t n = anole_poll_wait(consumer, buf, sizeof buf, 50);
    CHECK(n >= 0);
    for (int64_t off = 0; off < n;) {
      const anole_event *ev = (const anole_event *)(buf + off);
      CHECK(ev->len >= sizeof *ev && (ev->len & 7) == 0 && off + ev->len <= n);
      switch (ev->type) {
        case ANOLE_EV_GRPC_CALL:
          on_call((const anole_grpc_call_event *)ev);
          break;
        case ANOLE_EV_GRPC_MESSAGE:
          on_message((const anole_grpc_message_event *)ev);
          break;
        case ANOLE_EV_GRPC_HALF_CLOSE:
          on_half_close(ev->handle);
          break;
        case ANOLE_EV_WRITABLE: {
          atomic_fetch_add(&writables, 1);
          call_state *st = state_of(ev->handle, 0);
          /* Even with nothing left to send: the stream ends here when its
             last message was the one past the high-water mark. */
          if (st && st->busy) pump_busy(st);
          break;
        }
        case ANOLE_EV_ABORT:
          drop(ev->handle);
          atomic_store(&last_abort, ev->handle);
          break;
        default:
          break;
      }
      off += ev->len;
    }
  }
  return NULL;
}

/* ---- a gRPC-Web client over a blocking socket --------------------------------------- */

static uint16_t port;

static int dial(void) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  CHECK(fd >= 0);
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  CHECK(connect(fd, (struct sockaddr *)&a, sizeof a) == 0);
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  /* An answer that never comes fails the run (read_all) rather than hang it. */
  struct timeval tv = {20, 0};
  CHECK(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) == 0);
  return fd;
}

typedef struct {
  int status;
  char head[4096];
  unsigned char *body;
  size_t len, cap;
  /* The response's frames: messages, and the trailer block. */
  char messages[128][5100];
  size_t message_len[128];
  int nmessages;
  char trailers[1024];
} reply;

static size_t read_all(int fd, unsigned char **out) {
  size_t cap = 1 << 16, len = 0;
  unsigned char *b = malloc(cap);
  CHECK(b);
  for (;;) {
    if (len == cap) {
      cap *= 2;
      b = realloc(b, cap);
      CHECK(b);
    }
    ssize_t k = read(fd, b + len, cap - len);
    if (k < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) CHECK(!"no answer within 20 s");
    if (k <= 0) break;
    len += (size_t)k;
  }
  *out = b;
  return len;
}

/* One gRPC-Web call: `frames` are the request messages; the connection
   closes after the response (Connection: close), which ends the read. */
static void call(const char *method, const char *const *msgs, int n, const char *extra_headers, reply *r) {
  memset(r, 0, sizeof *r);
  unsigned char body[16384];
  size_t blen = 0;
  for (int i = 0; i < n; i++) {
    size_t l = strlen(msgs[i]);
    body[blen++] = 0;
    body[blen++] = (unsigned char)(l >> 24);
    body[blen++] = (unsigned char)(l >> 16);
    body[blen++] = (unsigned char)(l >> 8);
    body[blen++] = (unsigned char)l;
    memcpy(body + blen, msgs[i], l);
    blen += l;
  }
  int fd = dial();
  char head[1024];
  int hl = snprintf(head, sizeof head,
                    "POST /anole.test.Echo/%s HTTP/1.1\r\nHost: x\r\nContent-Type: application/grpc-web+proto\r\n"
                    "X-Grpc-Web: 1\r\nConnection: close\r\n%sContent-Length: %zu\r\n\r\n",
                    method, extra_headers ? extra_headers : "", blen);
  CHECK(write(fd, head, (size_t)hl) == hl);
  CHECK(write(fd, body, blen) == (ssize_t)blen);
  unsigned char *raw;
  size_t raw_len = read_all(fd, &raw);
  close(fd);
  CHECK(raw_len > 12);
  r->status = atoi((char *)raw + 9);
  unsigned char *end_head = memmem(raw, raw_len, "\r\n\r\n", 4);
  CHECK(end_head);
  size_t head_len = (size_t)(end_head - raw);
  CHECK(head_len < sizeof r->head);
  memcpy(r->head, raw, head_len);
  /* The body: Content-Length or chunked. */
  unsigned char *p = end_head + 4, *stop = raw + raw_len;
  r->body = malloc(raw_len);
  CHECK(r->body);
  if (strcasestr(r->head, "transfer-encoding: chunked")) {
    while (p < stop) {
      size_t k = strtoul((char *)p, NULL, 16);
      p = memmem(p, (size_t)(stop - p), "\r\n", 2);
      CHECK(p);
      p += 2;
      if (k == 0) break;
      memcpy(r->body + r->len, p, k);
      r->len += k;
      p += k + 2;
    }
  } else {
    memcpy(r->body, p, (size_t)(stop - p));
    r->len = (size_t)(stop - p);
  }
  free(raw);
  for (size_t off = 0; off + 5 <= r->len;) {
    unsigned flag = r->body[off];
    size_t l = ((size_t)r->body[off + 1] << 24) | ((size_t)r->body[off + 2] << 16) | ((size_t)r->body[off + 3] << 8) |
               r->body[off + 4];
    CHECK(off + 5 + l <= r->len);
    if (flag & 0x80) {
      CHECK(l < sizeof r->trailers);
      memcpy(r->trailers, r->body + off + 5, l);
    } else {
      CHECK(r->nmessages < 128 && l < sizeof r->messages[0]);
      memcpy(r->messages[r->nmessages], r->body + off + 5, l);
      r->message_len[r->nmessages++] = l;
    }
    off += 5 + l;
  }
  free(r->body);
  r->body = NULL;
}

static int has_trailer(const reply *r, const char *line) { return strstr(r->trailers, line) != NULL; }

static int msg_is(const reply *r, int i, const char *s) {
  return i < r->nmessages && r->message_len[i] == strlen(s) && memcmp(r->messages[i], s, strlen(s)) == 0;
}

static uint64_t wait_for(atomic_ullong *v, uint64_t want) {
  for (int i = 0; i < 2500; i++) {
    uint64_t got = atomic_load(v);
    if (want ? got == want : got != 0) return got;
    sleep_ms(2);
  }
  CHECK(!"timed out");
  return 0;
}

/* A health check: grpc.health.v1.Health/Check, HealthCheckRequest{service}
   as protobuf by hand; returns the status (HealthCheckResponse.status). */
static int health(const char *service) {
  unsigned char req[300];
  size_t l = strlen(service);
  req[0] = 0x0a;
  req[1] = (unsigned char)l;
  memcpy(req + 2, service, l);
  unsigned char body[310];
  size_t blen = 0;
  body[blen++] = 0;
  body[blen++] = 0;
  body[blen++] = 0;
  body[blen++] = 0;
  body[blen++] = (unsigned char)(l + 2);
  memcpy(body + blen, req, l + 2);
  blen += l + 2;
  int fd = dial();
  char head[512];
  int hl = snprintf(head, sizeof head,
                    "POST /grpc.health.v1.Health/Check HTTP/1.1\r\nHost: x\r\nContent-Type: application/grpc-web+proto\r\n"
                    "Connection: close\r\nContent-Length: %zu\r\n\r\n",
                    blen);
  CHECK(write(fd, head, (size_t)hl) == hl);
  CHECK(write(fd, body, blen) == (ssize_t)blen);
  unsigned char *raw;
  size_t n = read_all(fd, &raw);
  close(fd);
  unsigned char *p = memmem(raw, n, "\r\n\r\n", 4);
  CHECK(p);
  int status = -1;
  /* The message frame: 00 00000002 08 <status>, or an empty message (UNKNOWN). */
  unsigned char *f = memmem(p, n - (size_t)(p - raw), "\x00\x00\x00\x00\x02\x08", 6);
  if (f) status = f[6];
  else if (memmem(p, n - (size_t)(p - raw), "\x00\x00\x00\x00\x00", 5)) status = 0;
  free(raw);
  return status;
}

/* ---- just enough HTTP/2 to start a call and reset it ------------------------------- */

static void h2_frame(int fd, unsigned type, unsigned flags, unsigned stream, const void *payload, size_t len) {
  unsigned char h[9] = {(unsigned char)(len >> 16), (unsigned char)(len >> 8), (unsigned char)len, (unsigned char)type,
                        (unsigned char)flags, (unsigned char)(stream >> 24), (unsigned char)(stream >> 16),
                        (unsigned char)(stream >> 8), (unsigned char)stream};
  CHECK(write(fd, h, 9) == 9);
  if (len) CHECK(write(fd, payload, len) == (ssize_t)len);
}

/* An HPACK literal without indexing, new name, no Huffman. */
static size_t hpack(unsigned char *out, const char *name, const char *value) {
  size_t n = strlen(name), v = strlen(value), k = 0;
  out[k++] = 0;
  out[k++] = (unsigned char)n;
  memcpy(out + k, name, n);
  k += n;
  out[k++] = (unsigned char)v;
  memcpy(out + k, value, v);
  return k + v;
}

/* The preface, SETTINGS, and a unary call on stream 1 whose message is "hold". */
static void h2_call_and_hold(int fd) {
  const char preface[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
  CHECK(write(fd, preface, sizeof preface - 1) == (ssize_t)(sizeof preface - 1));
  h2_frame(fd, 4, 0, 0, NULL, 0);
  unsigned char block[512];
  size_t k = 0;
  k += hpack(block + k, ":method", "POST");
  k += hpack(block + k, ":scheme", "http");
  k += hpack(block + k, ":path", "/anole.test.Echo/Unary");
  k += hpack(block + k, ":authority", "x");
  k += hpack(block + k, "content-type", "application/grpc");
  k += hpack(block + k, "te", "trailers");
  h2_frame(fd, 1, 4, 1, block, k); /* HEADERS, END_HEADERS */
  h2_frame(fd, 0, 1, 1, "\x00\x00\x00\x00\x04hold", 9); /* DATA, END_STREAM */
}

int main(void) {
  start_watchdog(300);
  CHECK(anole_has_feature(S("grpc")) == 1);
  const char *json =
      "{\"executors\": 2, \"listeners\": [{\"address\": \"127.0.0.1\", \"port\": 0}],"
      " \"limits\": {\"stream_high_water\": 4096},"
      " \"grpc\": {\"health\": true, \"services\": [{\"name\": \"anole.test.Echo\", \"handler\": 1, \"read_ahead\": 2,"
      "   \"methods\": [{\"name\": \"Unary\", \"kind\": \"unary\"}, {\"name\": \"ServerStream\", \"kind\": \"server_streaming\"},"
      "                {\"name\": \"ClientStream\", \"kind\": \"client_streaming\"}, {\"name\": \"Bidi\", \"kind\": \"bidi_streaming\"}]}]}}";
  anole_server_options o = {sizeof o, {json, strlen(json)}, 0, 0, on_log, NULL};
  anole_server *s = NULL;
  CHECK(anole_server_create(&o, &s) == ANOLE_OK);
  anole_consumer_options co = {sizeof co, NULL, NULL, ANOLE_CONSUMER_SHARED};
  CHECK(anole_consumer_attach(s, &co, &consumer) == ANOLE_OK);
  /* Health before start: kept until the service exists. */
  CHECK(anole_grpc_health_set(s, S("later.Service"), ANOLE_GRPC_HEALTH_NOT_SERVING) == ANOLE_OK);
  CHECK(anole_grpc_health_set(s, S("x"), 7) == ANOLE_E_INVALID);
  CHECK(anole_server_start(s) == ANOLE_OK);
  CHECK(anole_server_port(s, 0, &port) == ANOLE_OK);
  pthread_t t;
  CHECK(pthread_create(&t, NULL, consumer_main, NULL) == 0);
  reply *r = malloc(sizeof *r);
  CHECK(r);

  /* Unary. */
  {
    const char *m[] = {"hello"};
    call("Unary", m, 1, NULL, r);
    CHECK(r->status == 200 && r->nmessages == 1 && msg_is(r, 0, "hello"));
    CHECK(has_trailer(r, "grpc-status:0"));
    printf("ok unary\n");
  }
  /* An error status with trailing metadata (-bin as base64). */
  {
    const char *m[] = {"fail"};
    call("Unary", m, 1, NULL, r);
    CHECK(r->status == 200 && r->nmessages == 0);
    CHECK(has_trailer(r, "grpc-status:5") && has_trailer(r, "grpc-message:no such thing"));
    CHECK(has_trailer(r, "x-why:test") && has_trailer(r, "x-raw-bin:AAH/"));
    printf("ok error status and trailers\n");
  }
  /* Metadata both ways, and the answer functions' checks. */
  {
    const char *m[] = {"checks"};
    call("Unary", m, 1, "X-Trace: t1\r\nX-Data-Bin: AAH/\r\n", r);
    CHECK(r->status == 200 && msg_is(r, 0, "checked"));
    CHECK(strcasestr(r->head, "x-initial: yes"));
    CHECK(has_trailer(r, "grpc-status:0") && has_trailer(r, "x-echoed:t1"));
    printf("ok metadata and state checks\n");
  }
  /* Server streaming. */
  {
    const char *m[] = {"5"};
    call("ServerStream", m, 1, NULL, r);
    CHECK(r->status == 200 && r->nmessages == 5 && msg_is(r, 0, "tick0") && msg_is(r, 4, "tick4"));
    CHECK(has_trailer(r, "grpc-status:0"));
    const char *z[] = {"0"};
    call("ServerStream", z, 1, NULL, r);
    CHECK(r->nmessages == 0 && has_trailer(r, "grpc-status:0"));
    printf("ok server streaming\n");
  }
  /* Backpressure: past stream_high_water, ANOLE_BUSY, then ANOLE_EV_WRITABLE. */
  {
    const char *m[] = {"busy"};
    call("ServerStream", m, 1, NULL, r);
    CHECK(r->nmessages == 64 && r->message_len[63] == 1024 && has_trailer(r, "grpc-status:0"));
    CHECK(atomic_load(&busies) > 0 && atomic_load(&writables) > 0);
    const char *w[] = {"wait"};
    call("ServerStream", w, 1, NULL, r);
    CHECK(r->nmessages == 64 && has_trailer(r, "grpc-status:0"));
    /* ANOLE_BUSY on the last message: the ANOLE_EV_WRITABLE after it is
       when the consumer ends the stream. */
    const char *l[] = {"busylast"};
    call("ServerStream", l, 1, NULL, r);
    CHECK(r->nmessages == 2 && r->message_len[0] == 1024 && r->message_len[1] == 5000);
    CHECK(has_trailer(r, "grpc-status:0"));
    printf("ok backpressure\n");
  }
  /* Client streaming: more messages than read_ahead (2). */
  {
    const char *m[] = {"a", "b", "c", "d", "e", "f"};
    call("ClientStream", m, 6, NULL, r);
    CHECK(r->status == 200 && r->nmessages == 1 && msg_is(r, 0, "abcdef"));
    CHECK(has_trailer(r, "grpc-status:0") && has_trailer(r, "x-count:done"));
    printf("ok client streaming\n");
  }
  /* Bidi (half duplex over HTTP/1.1: the requests, then the answers). */
  {
    const char *m[] = {"x", "y", "z"};
    call("Bidi", m, 3, NULL, r);
    CHECK(r->nmessages == 3 && msg_is(r, 0, "x#0") && msg_is(r, 2, "z#2"));
    CHECK(has_trailer(r, "grpc-status:0"));
    printf("ok bidi\n");
  }
  /* A deadline: DEADLINE_EXCEEDED for the client, ANOLE_EV_ABORT for the
     consumer, and its late answer is ANOLE_E_GONE. */
  {
    atomic_store(&held, 0);
    const char *m[] = {"hold"};
    call("Unary", m, 1, "Grpc-Timeout: 200m\r\n", r);
    CHECK(r->status == 200 && has_trailer(r, "grpc-status:4"));
    uint64_t h = wait_for(&held, 0);
    long long us = atomic_load(&held_timeout_us);
    CHECK(us > 0 && us <= 200000);
    wait_for(&last_abort, h);
    CHECK(anole_grpc_send(h, "late", 4, ANOLE_GRPC_SEND_FINISH) == ANOLE_E_GONE);
    printf("ok deadline\n");
  }
  /* A cancel: the client resets the stream (HTTP/2, cleartext; HTTP/1.1
     cannot tell a hang-up while the answer is pending); ANOLE_EV_ABORT, and
     the late answer is ANOLE_E_GONE. */
  {
    atomic_store(&held, 0);
    int fd = dial();
    h2_call_and_hold(fd);
    uint64_t h = wait_for(&held, 0);
    CHECK(atomic_load(&held_timeout_us) == -1);
    h2_frame(fd, 3, 0, 1, "\x00\x00\x00\x08", 4); /* RST_STREAM, CANCEL */
    wait_for(&last_abort, h);
    CHECK(anole_grpc_finish(h, ANOLE_GRPC_OK, S(""), NULL, 0) == ANOLE_E_GONE);
    close(fd);
    printf("ok cancel\n");
  }
  /* JSON needs descriptors: none here, so 415. */
  {
    int fd = dial();
    const char req[] =
        "POST /anole.test.Echo/Unary HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nConnection: close\r\n"
        "Content-Length: 2\r\n\r\n{}";
    CHECK(write(fd, req, sizeof req - 1) == (ssize_t)(sizeof req - 1));
    unsigned char *raw;
    size_t n = read_all(fd, &raw);
    close(fd);
    CHECK(n > 12 && atoi((char *)raw + 9) == 415);
    free(raw);
    printf("ok json refused without descriptors\n");
  }
  /* Health: the services SERVING, a status set before start, one after. */
  {
    CHECK(health("") == 1 && health("anole.test.Echo") == 1 && health("later.Service") == 2);
    CHECK(anole_grpc_health_set(s, S("anole.test.Echo"), ANOLE_GRPC_HEALTH_NOT_SERVING) == ANOLE_OK);
    int st = 0;
    for (int i = 0; i < 500 && (st = health("anole.test.Echo")) != 2; i++) sleep_ms(2);
    CHECK(st == 2);
    printf("ok health\n");
  }
  /* Handles of another kind are not calls. */
  CHECK(anole_grpc_finish(0, 0, S(""), NULL, 0) == ANOLE_E_GONE);
  CHECK(anole_grpc_send(12345, "x", 1, 0) == ANOLE_E_GONE);
  CHECK(anole_grpc_send(1, "x", 1, 64) == ANOLE_E_INVALID);

  free(r);
  CHECK(anole_server_drain(s) == ANOLE_OK);
  CHECK(anole_server_wait(s, 10000) == ANOLE_OK);
  atomic_store(&stop_consumer, 1);
  pthread_join(t, NULL);
  anole_stats st = {sizeof st};
  CHECK(anole_server_stats(s, &st) == ANOLE_OK);
  CHECK(st.inflight == 0);
  anole_server_destroy(s);
  CHECK(atomic_load(&failures) == 0);
  printf("grpc: all passed\n");
  return 0;
}
