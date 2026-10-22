/* tests/capi/consumer.c - a C consumer of libanole (M17 spike).
 *
 *   consumer test                 correctness suite (exit 0 = pass)
 *   consumer serve <executors> <port> [consumers]
 *                                 benchmark server: GET /native (fixed
 *                                 response, no consumer), GET /hello and
 *                                 GET /users/:id (answered by consumer
 *                                 threads), POST /echo; runs until stdin
 *                                 closes or SIGINT
 *
 * Uses only include/anole.h. Each consumer thread waits on the doorbell fd
 * with poll(2) (an eventfd on Linux, a pipe on macOS), drains with
 * anole_poll, and answers in the same batch.
 */
#define _GNU_SOURCE
#include "anole.h"

#include <arpa/inet.h>
#include <errno.h>
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

static anole_server *make_server(const char *json) {
  anole_server_options o = {sizeof o, {json, strlen(json)}, 0};
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

typedef struct {
  int status;
  char body[70000];
  size_t body_len;
  int eof; /* connection closed with no response */
} response;

/* Sends one request on fd and reads one response (Content-Length bodies). */
static void roundtrip(int fd, const char *method, const char *path, const char *body, size_t body_len,
                      response *r) {
  char head[512];
  int n = snprintf(head, sizeof head, "%s %s HTTP/1.1\r\nHost: x\r\nX-Test: Value\r\nContent-Length: %zu\r\n\r\n",
                   method, path, body_len);
  CHECK(write(fd, head, n) == n);
  if (body_len) CHECK(write(fd, body, body_len) == (ssize_t)body_len);
  static __thread char buf[140000];
  size_t len = 0;
  memset(r, 0, sizeof *r);
  for (;;) {
    ssize_t k = read(fd, buf + len, sizeof buf - len - 1);
    if (k <= 0) {
      r->eof = 1;
      return;
    }
    len += (size_t)k;
    buf[len] = 0;
    char *end = strstr(buf, "\r\n\r\n");
    if (!end) continue;
    size_t hlen = (size_t)(end + 4 - buf);
    size_t clen = 0;
    char *cl = strcasestr(buf, "\ncontent-length:");
    if (cl && cl < end) clen = strtoul(cl + 16, NULL, 10);
    if (len < hlen + clen) continue;
    r->status = atoi(buf + 9);
    memcpy(r->body, buf + hlen, clen);
    r->body_len = clen;
    r->body[clen] = 0;
    return;
  }
}

static void request(uint16_t port, const char *method, const char *path, const char *body, response *r) {
  int fd = dial(port);
  roundtrip(fd, method, path, body, body ? strlen(body) : 0, r);
  close(fd);
}

/* ---- consumers ------------------------------------------------------------------ */

typedef struct consumer_state consumer_state;
typedef void (*on_request_fn)(consumer_state *cs, const anole_request_event *ev);

struct consumer_state {
  anole_consumer *c;
  on_request_fn on_request;
  pthread_t thread;
  atomic_int stopped;
  _Alignas(8) unsigned char buf[256 * 1024];
  /* for tests */
  anole_req held[64];
  atomic_int nheld;
  uint64_t batches, events;
  int spin_us; /* serve: CAPI_SPIN_US */
};

static void *consumer_main(void *arg) {
  consumer_state *cs = arg;
  int fd = anole_consumer_fd(cs->c);
  for (;;) {
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
      cs->batches++;
      for (int64_t off = 0; off < n;) {
        const anole_event *ev = (const anole_event *)(cs->buf + off);
        CHECK(ev->len >= sizeof(anole_event) && (ev->len & 7) == 0);
        if (ev->type == ANOLE_EV_REQUEST) {
          cs->events++;
          cs->on_request(cs, (const anole_request_event *)ev);
        } else if (ev->type == ANOLE_EV_STOPPED) {
          atomic_store(&cs->stopped, 1);
          return NULL;
        }
        off += ev->len;
      }
    }
  }
  return NULL;
}

static void start_consumer(consumer_state *cs) {
  CHECK(pthread_create(&cs->thread, NULL, consumer_main, cs) == 0);
}

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

static const anole_header text_plain[] = {{{"content-type", 12}, {"text/plain", 10}}};

/* The answers: 1 hello, 2 echo, 3 hold (the test answers later), 4 user, 5 release. */
static void answer(consumer_state *cs, const anole_request_event *r) {
  anole_req h = r->ev.handle;
  switch (r->route_id) {
  case 1:
    CHECK(anole_respond(h, 200, text_plain, 1, "Hello, World!", 13, 0) == ANOLE_OK);
    break;
  case 2: {
    anole_str b = anole_event_str(r, r->body);
    CHECK(r->flags & ANOLE_REQ_BODY_INLINE);
    CHECK(anole_respond(h, 200, text_plain, 1, b.ptr, b.len, 0) == ANOLE_OK);
    break;
  }
  case 3: {
    int i = atomic_fetch_add(&cs->nheld, 1);
    CHECK(i < 64);
    cs->held[i] = h;
    break;
  }
  case 4: {
    anole_str id = param_of(r, "id");
    anole_str xt = header_of(r, "x-test");
    char out[256];
    int n = snprintf(out, sizeof out, "user %.*s %.*s %.*s", (int)id.len, id.ptr, (int)xt.len, xt.ptr,
                     (int)r->query.len, (const char *)r + r->query.off);
    CHECK(anole_respond(h, 200, text_plain, 1, out, (size_t)n, 0) == ANOLE_OK);
    break;
  }
  case 5:
    CHECK(anole_release(h) == ANOLE_OK);
    break;
  default:
    CHECK(anole_respond(h, 404, NULL, 0, NULL, 0, 0) == ANOLE_OK);
  }
}

/* ---- the correctness suite ------------------------------------------------------------ */

static const char *test_config =
    "{\"listeners\":[{\"address\":\"127.0.0.1\",\"port\":0}],\"executors\":%d,"
    "\"limits\":{\"inline_body_max\":65536,\"max_inflight\":%d},"
    "\"timeouts\":{\"request_ms\":%d,\"shutdown_ms\":%d},"
    "\"routes\":["
    "{\"method\":\"GET\",\"path\":\"/native\",\"respond\":{\"status\":200,\"body\":\"native\","
    "\"headers\":{\"content-type\":\"text/plain\"}}},"
    "{\"method\":\"GET\",\"path\":\"/hello\",\"handler\":1},"
    "{\"method\":\"POST\",\"path\":\"/echo\",\"handler\":2},"
    "{\"method\":\"GET\",\"path\":\"/hold\",\"handler\":3},"
    "{\"method\":\"GET\",\"path\":\"/users/:id\",\"handler\":4},"
    "{\"method\":\"GET\",\"path\":\"/release\",\"handler\":5}]}";

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
  int fd = dial(h->port);
  response r;
  for (int i = 0; i < h->n; i++) {
    char path[64], want[128];
    snprintf(path, sizeof path, "/users/%d-%d?q=%d", h->id, i, i);
    snprintf(want, sizeof want, "user %d-%d Value q=%d", h->id, i, i);
    roundtrip(fd, "GET", path, NULL, 0, &r);
    if (r.status != 200 || strcmp(r.body, want) != 0) h->failures++;
  }
  close(fd);
  return NULL;
}

static int wait_held(consumer_state *cs, int n) {
  for (int i = 0; i < 500 && atomic_load(&cs->nheld) < n; i++) usleep(2000);
  return atomic_load(&cs->nheld) >= n;
}

static int run_tests(void) {
  char json[2048];
  snprintf(json, sizeof json, test_config, 4, 64, 400, 600);
  anole_server *s = make_server(json);

  /* create refuses a second server, and bad config. */
  {
    anole_server *s2 = NULL;
    anole_server_options o = {sizeof o, {"{}", 2}, 0};
    CHECK(anole_server_create(&o, &s2) == ANOLE_E_STATE);
  }
  static consumer_state cs;
  cs.on_request = answer;
  anole_consumer_options co = {sizeof co, NULL, NULL, 0};
  CHECK(anole_consumer_attach(s, &co, &cs.c) == ANOLE_OK);
  CHECK(anole_consumer_fd(cs.c) >= 0);
  CHECK(anole_server_start(s) == ANOLE_OK);
  {
    anole_consumer *late = NULL;
    CHECK(anole_consumer_attach(s, &co, &late) == ANOLE_E_STATE && late == NULL);
  }
  uint16_t port = 0;
  CHECK(anole_server_port(s, 0, &port) == ANOLE_OK && port != 0);
  start_consumer(&cs);
  printf("listening on %u\n", port);

  response r;
  /* native and consumer routes */
  request(port, "GET", "/native", NULL, &r);
  CHECK(r.status == 200 && strcmp(r.body, "native") == 0);
  request(port, "GET", "/hello", NULL, &r);
  CHECK(r.status == 200 && strcmp(r.body, "Hello, World!") == 0);
  request(port, "GET", "/users/42?a=b", NULL, &r);
  CHECK(r.status == 200 && strcmp(r.body, "user 42 Value a=b") == 0);
  request(port, "POST", "/echo", "the body", &r);
  CHECK(r.status == 200 && strcmp(r.body, "the body") == 0);
  request(port, "GET", "/release", NULL, &r);
  CHECK(r.status == 500);
  request(port, "GET", "/nope", NULL, &r);
  CHECK(r.status == 404);
  printf("ok routes\n");

  /* a 64 KiB body inline; one byte more is 413 */
  {
    static char big[65537];
    memset(big, 'a', sizeof big - 1);
    int fd = dial(port);
    roundtrip(fd, "POST", "/echo", big, 65536, &r);
    CHECK(r.status == 200 && r.body_len == 65536);
    close(fd);
    fd = dial(port);
    roundtrip(fd, "POST", "/echo", big, 65537, &r);
    CHECK(r.status == 413);
    close(fd);
  }
  printf("ok bodies\n");

  /* answered handle: a second answer is GONE; so are made-up handles */
  {
    pthread_t t;
    async_req a = {port, "/hold", {0}, 0};
    atomic_store(&cs.nheld, 0);
    CHECK(pthread_create(&t, NULL, async_get, &a) == 0);
    CHECK(wait_held(&cs, 1));
    anole_req h = cs.held[0];
    CHECK(anole_respond(h, 201, NULL, 0, "late-ok", 7, 0) == ANOLE_OK);
    pthread_join(t, NULL);
    CHECK(a.r.status == 201 && strcmp(a.r.body, "late-ok") == 0);
    CHECK(anole_respond(h, 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    CHECK(anole_release(h) == ANOLE_E_GONE);
    CHECK(anole_respond(0, 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    CHECK(anole_respond(h + 1, 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);       /* next generation */
    CHECK(anole_respond(h ^ (1ull << 60), 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE); /* bad executor */
    CHECK(anole_respond(h | (0xffffffull << 32), 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE); /* bad slot */
    CHECK(anole_respond(h, 200, NULL, 0, NULL, 0, 1) == ANOLE_E_INVALID);
    /* invalid header: refused, the request is still owed (none here) */
    printf("ok stale handles\n");

    /* slot reuse: same executor and slot, newer generation, old one stays GONE */
    anole_req first = h;
    int reused = 0;
    for (int i = 0; i < 200 && !reused; i++) {
      async_req b = {port, "/hold", {0}, 0};
      atomic_store(&cs.nheld, 0);
      CHECK(pthread_create(&t, NULL, async_get, &b) == 0);
      CHECK(wait_held(&cs, 1));
      anole_req h2 = cs.held[0];
      anole_header bad = {{"bad name", 8}, {"v", 1}};
      CHECK(anole_respond(h2, 200, &bad, 1, NULL, 0, 0) == ANOLE_E_INVALID);
      CHECK(anole_respond(h2, 200, NULL, 0, "x", 1, 0) == ANOLE_OK);
      pthread_join(t, NULL);
      CHECK(b.r.status == 200);
      if ((h2 >> 32) == (first >> 32) && h2 != first) {
        CHECK((uint32_t)h2 > (uint32_t)first);
        CHECK(anole_respond(first, 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
        reused = 1;
      }
    }
    CHECK(reused);
    printf("ok slot reuse\n");
  }

  /* deadline: 504 after request_ms, the late answer is GONE */
  {
    anole_stats st0 = {.size = sizeof st0}, st1 = {.size = sizeof st1};
    CHECK(anole_server_stats(s, &st0) == ANOLE_OK);
    pthread_t t;
    async_req a = {port, "/hold", {0}, 0};
    atomic_store(&cs.nheld, 0);
    CHECK(pthread_create(&t, NULL, async_get, &a) == 0);
    pthread_join(t, NULL);
    CHECK(a.r.status == 504);
    CHECK(a.ms >= 380 && a.ms < 1500);
    CHECK(wait_held(&cs, 1));
    CHECK(anole_respond(cs.held[0], 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    CHECK(anole_server_stats(s, &st1) == ANOLE_OK);
    CHECK(st1.expired == st0.expired + 1 && st1.gone >= st0.gone + 1);
    printf("ok deadline (504 after %.0f ms)\n", a.ms);
  }

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
    printf("ok concurrency (%d requests, %llu batches, %llu wakes)\n", T * N, (unsigned long long)cs.batches,
           (unsigned long long)st.wakes);
  }

  /* drain with requests in flight: one answered during the drain (200),
     one never answered (dropped at shutdown_ms; its late answer is GONE) */
  {
    pthread_t t1, t2;
    async_req a = {port, "/hold", {0}, 0}, b = {port, "/hold", {0}, 0};
    atomic_store(&cs.nheld, 0);
    CHECK(pthread_create(&t1, NULL, async_get, &a) == 0);
    CHECK(pthread_create(&t2, NULL, async_get, &b) == 0);
    CHECK(wait_held(&cs, 2));
    double t0 = now_ms();
    CHECK(anole_server_drain(s) == ANOLE_OK);
    CHECK(anole_server_drain(s) == ANOLE_OK); /* again: no-op */
    usleep(100 * 1000);
    CHECK(anole_respond(cs.held[0], 200, NULL, 0, "drained", 7, 0) == ANOLE_OK);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    async_req *answered = a.r.status == 200 ? &a : &b, *dropped = answered == &a ? &b : &a;
    CHECK(answered->r.status == 200 && strcmp(answered->r.body, "drained") == 0);
    /* the request deadline (400 ms) fires before the shutdown deadline (600 ms) */
    CHECK(dropped->r.status == 504 || dropped->r.eof);
    CHECK(anole_server_wait(s) == ANOLE_OK);
    double took = now_ms() - t0;
    CHECK(anole_respond(cs.held[1], 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    pthread_join(cs.thread, NULL);
    CHECK(atomic_load(&cs.stopped));
    printf("ok drain (stopped after %.0f ms; dropped request: %s)\n", took,
           dropped->r.eof ? "connection closed" : "504");
  }
  anole_server_destroy(s);

  /* a second server after the first is destroyed; drain cancels a request
     waiting past shutdown_ms (request deadline longer) */
  {
    snprintf(json, sizeof json, test_config, 1, 2, 5000, 300);
    s = make_server(json);
    static consumer_state cs2;
    cs2.on_request = answer;
    CHECK(anole_consumer_attach(s, &co, &cs2.c) == ANOLE_OK);
    CHECK(anole_server_start(s) == ANOLE_OK);
    CHECK(anole_server_port(s, 0, &port) == ANOLE_OK);
    start_consumer(&cs2);
    /* max_inflight 2 per executor: the third request is 503 */
    pthread_t t1, t2;
    async_req a = {port, "/hold", {0}, 0}, b = {port, "/hold", {0}, 0};
    CHECK(pthread_create(&t1, NULL, async_get, &a) == 0);
    CHECK(pthread_create(&t2, NULL, async_get, &b) == 0);
    CHECK(wait_held(&cs2, 2));
    request(port, "GET", "/hello", NULL, &r);
    CHECK(r.status == 503);
    double t0 = now_ms();
    CHECK(anole_server_drain(s) == ANOLE_OK);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    CHECK(a.r.eof || a.r.status >= 500);
    CHECK(anole_server_wait(s) == ANOLE_OK);
    double took = now_ms() - t0;
    CHECK(took < 2000);
    CHECK(anole_respond(cs2.held[0], 200, NULL, 0, NULL, 0, 0) == ANOLE_E_GONE);
    pthread_join(cs2.thread, NULL);
    anole_stats st = {.size = sizeof st};
    CHECK(anole_server_stats(s, &st) == ANOLE_OK);
    CHECK(st.busy == 1 && st.expired >= 2);
    anole_server_destroy(s);
    printf("ok max_inflight 503 and drain past shutdown_ms (%.0f ms, client saw %s)\n", took,
           a.r.eof ? "close" : "5xx");
  }

  /* bad config */
  {
    anole_server_options o = {sizeof o, {"{\"routes\":[{\"path\":\"/x\"}]}", 26}, 0};
    anole_server *bad = NULL;
    CHECK(anole_server_create(&o, &bad) == ANOLE_E_CONFIG);
    anole_str e = anole_last_error();
    CHECK(e.len > 0);
    o.config_json.ptr = "{\"nope\":1}";
    o.config_json.len = 10;
    CHECK(anole_server_create(&o, &bad) == ANOLE_E_CONFIG);
    printf("ok bad config (%.*s)\n", (int)anole_last_error().len, anole_last_error().ptr);
  }
  printf("PASS\n");
  return 0;
}

/* ---- the benchmark server ----------------------------------------------------------------- */

static void bench_answer(consumer_state *cs, const anole_request_event *r) {
  (void)cs;
  anole_req h = r->ev.handle;
  if (r->route_id == 4) {
    anole_str id = param_of(r, "id");
    char out[128];
    int n = snprintf(out, sizeof out, "user %.*s", (int)id.len, id.ptr);
    anole_respond(h, 200, text_plain, 1, out, (size_t)n, 0);
  } else if (r->route_id == 2) {
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
           "{\"method\":\"POST\",\"path\":\"/echo\",\"handler\":2},"
           "{\"method\":\"GET\",\"path\":\"/users/:id\",\"handler\":4}]}",
           port, executors);
  anole_server *s = make_server(json);
  static consumer_state cs[16];
  anole_consumer_options co = {sizeof co, NULL, NULL, 0};
  const char *spin = getenv("CAPI_SPIN_US");
  for (int i = 0; i < consumers; i++) {
    cs[i].spin_us = spin ? atoi(spin) : 0;
    cs[i].on_request = bench_answer;
    CHECK(anole_consumer_attach(s, &co, &cs[i].c) == ANOLE_OK);
  }
  CHECK(anole_server_start(s) == ANOLE_OK);
  for (int i = 0; i < consumers; i++) start_consumer(&cs[i]);
  fprintf(stderr, "serving on 127.0.0.1:%d with %d executors, %d consumer thread(s)\n", port, executors, consumers);
  /* until stdin closes */
  char c;
  while (read(0, &c, 1) > 0) {}
  anole_stats st = {.size = sizeof st};
  anole_server_stats(s, &st);
  uint64_t ev = 0, b = 0;
  for (int i = 0; i < consumers; i++) ev += cs[i].events, b += cs[i].batches;
  fprintf(stderr, "events %llu batches %llu (%.1f per batch) wakes %llu expired %llu\n", (unsigned long long)ev,
          (unsigned long long)b, b ? (double)ev / b : 0.0, (unsigned long long)st.wakes,
          (unsigned long long)st.expired);
  anole_server_drain(s);
  anole_server_wait(s);
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
