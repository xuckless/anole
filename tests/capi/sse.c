/* tests/capi/sse.c - the C ABI's server-sent events, tested from C (exit 0 = pass).
 *
 * A native route ("sse": {"topics": [...]}) served without the consumer, and
 * a consumer route ("sse": {"handler": N}) the consumer accepts with
 * anole_sse_accept: anole_sse_publish reaches subscribers, anole_sse_send
 * only its subscriber, a client that leaves is ANOLE_EV_SSE_CLOSE, and the
 * handle is then stale (ANOLE_E_GONE for sends, ANOLE_OK for cleanup).
 * Over HTTP/2 and with a queue that fills up, the Zig suite
 * (src/capi/sse_test.zig) covers the same calls.
 */
#define _GNU_SOURCE
#include "anole.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
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

static void on_watchdog(int sig) {
  (void)sig;
  const char *msg = "FAIL: still running after the watchdog's limit (hung); the step after the last \"ok\" line hangs\n";
  (void)!write(2, msg, strlen(msg));
  abort();
}

static void sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}

/* Hang guards, as src/testing/wait.zig: 10 s times ANOLE_TEST_TIMEOUT_FACTOR
   (a whole number, default 1), counted on the clock. Never a latency bound. */
static long timeout_factor(void) {
  const char *f = getenv("ANOLE_TEST_TIMEOUT_FACTOR");
  long n = f ? strtol(f, NULL, 10) : 1;
  return n < 1 ? 1 : n;
}

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static double wait_until(void) { return now_ms() + 10000.0 * (double)timeout_factor(); }

static void on_log(void *ud, uint32_t level, anole_str scope, anole_str msg) {
  (void)ud;
  if (level <= ANOLE_LOG_WARN || getenv("CAPI_LOG"))
    fprintf(stderr, "[%u %.*s] %.*s\n", level, (int)scope.len, scope.ptr, (int)msg.len, msg.ptr);
}

/* ---- the consumer -------------------------------------------------------------- */

static anole_consumer *consumer;
static atomic_int stop_consumer;
static atomic_int subscribes, closes;
static atomic_ullong handles[4];
static atomic_ullong last_close_handle;
static atomic_int last_close_reason = -1;

static void *consumer_main(void *arg) {
  (void)arg;
  static _Alignas(8) unsigned char buf[64 * 1024];
  while (!atomic_load(&stop_consumer)) {
    int64_t n = anole_poll_wait(consumer, buf, sizeof buf, 50);
    CHECK(n >= 0);
    for (int64_t off = 0; off < n;) {
      const anole_event *ev = (const anole_event *)(buf + off);
      CHECK(ev->len >= sizeof *ev && (ev->len & 7) == 0 && off + ev->len <= n);
      switch (ev->type) {
        case ANOLE_EV_SSE_SUBSCRIBE: {
          const anole_request_event *rq = (const anole_request_event *)ev;
          CHECK(rq->route_id == 7);
          anole_str topics[1] = {S("x")};
          anole_sse_accept_options o = {sizeof o, topics, 1, NULL, 0, 0, 0};
          anole_sse out = 0;
          CHECK(anole_sse_accept(ev->handle, &o, &out) == ANOLE_OK);
          /* The request handle is stale from here. */
          anole_sse again = 0;
          CHECK(anole_sse_accept(ev->handle, &o, &again) == ANOLE_E_GONE);
          /* The handle first: the test reads it once it sees the count. */
          int i = atomic_load(&subscribes);
          if (i < 4) atomic_store(&handles[i], out);
          atomic_fetch_add(&subscribes, 1);
          break;
        }
        case ANOLE_EV_SSE_CLOSE: {
          const anole_sse_close_event *c = (const anole_sse_close_event *)ev;
          atomic_store(&last_close_handle, ev->handle);
          atomic_store(&last_close_reason, (int)c->reason);
          atomic_fetch_add(&closes, 1);
          break;
        }
        default:
          break;
      }
      off += ev->len;
    }
  }
  return NULL;
}

/* ---- a client ------------------------------------------------------------------ */

static int dial(uint16_t port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  CHECK(fd >= 0);
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  CHECK(connect(fd, (struct sockaddr *)&a, sizeof a) == 0);
  struct timeval tv = {10, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  return fd;
}

static int open_stream(uint16_t port, const char *path, const char *extra) {
  int fd = dial(port);
  char req[512];
  int n = snprintf(req, sizeof req, "GET %s HTTP/1.1\r\nHost: x\r\nAccept: text/event-stream\r\n%s\r\n", path, extra);
  CHECK(write(fd, req, (size_t)n) == n);
  return fd;
}

/* Reads until `needle` is in what has come (appended to buf); the whole text. */
static const char *read_until(int fd, char *buf, size_t cap, size_t *len, const char *needle) {
  while (!memmem(buf, *len, needle, strlen(needle))) {
    CHECK(*len + 1 < cap);
    ssize_t n = read(fd, buf + *len, cap - *len - 1);
    CHECK(n > 0);
    *len += (size_t)n;
    buf[*len] = 0;
  }
  return buf;
}

static void wait_for(atomic_int *v, int at_least) {
  for (double until = wait_until(); atomic_load(v) < at_least && now_ms() < until;) sleep_ms(2);
  CHECK(atomic_load(v) >= at_least);
}

int main(void) {
  signal(SIGALRM, on_watchdog);
  alarm(120 * (unsigned)timeout_factor());
  setvbuf(stdout, NULL, _IOLBF, 0);
  const char *json =
      "{\"executors\": 2, \"sse\": {\"heartbeat_ms\": null}, \"limits\": {\"sse_max_event\": 1024},"
      " \"listeners\": [{\"address\": \"127.0.0.1\", \"port\": 0}],"
      " \"routes\": [{\"path\": \"/live\", \"sse\": {\"topics\": [\"news\"]}},"
      "              {\"path\": \"/me\", \"sse\": {\"handler\": 7}}]}";
  anole_server_options o = {sizeof o, {json, strlen(json)}, 0, 0, on_log, NULL};
  anole_server *s = NULL;
  CHECK(anole_server_create(&o, &s) == ANOLE_OK);
  anole_consumer_options co = {sizeof co, NULL, NULL, ANOLE_CONSUMER_F_SHARED};
  CHECK(anole_consumer_attach(s, &co, &consumer) == ANOLE_OK);
  /* Before start: nothing to publish to. */
  CHECK(anole_sse_publish(s, S("news"), S(""), "early", 5, 0) == ANOLE_E_STATE);
  CHECK(anole_server_start(s) == ANOLE_OK);
  anole_listener_info info = {sizeof info};
  CHECK(anole_server_listener(s, 0, &info) == ANOLE_OK && info.port != 0);
  uint16_t port = info.port;
  pthread_t t;
  CHECK(pthread_create(&t, NULL, consumer_main, NULL) == 0);

  /* Argument checks. */
  CHECK(anole_sse_publish(s, S("news"), S("a\rb"), "x", 1, 0) == ANOLE_E_INVALID);
  CHECK(anole_sse_publish(s, S("news"), S("a\nb"), "x", 1, 0) == ANOLE_E_INVALID);
  CHECK(anole_sse_publish(s, S(""), S(""), "x", 1, 0) == ANOLE_E_INVALID);
  CHECK(anole_sse_publish(s, S("news"), S(""), "x", 1, 2) == ANOLE_E_INVALID);
  {
    char big[1025];
    memset(big, 'x', sizeof big);
    CHECK(anole_sse_publish(s, S("news"), S(""), big, sizeof big, 0) == ANOLE_E_INVALID);
  }
  anole_watch *w = NULL;
  CHECK(anole_watch_find(s, S("nope"), &w) == ANOLE_E_INVALID);
  printf("ok argument checks\n");

  /* A native route. */
  {
    char buf[4096];
    size_t len = 0;
    int fd = open_stream(port, "/live", "");
    read_until(fd, buf, sizeof buf, &len, "text/event-stream");
    read_until(fd, buf, sizeof buf, &len, "id: "); /* the open line: the subscriber is in the hub */
    CHECK(anole_sse_publish(s, S("news"), S("tick"), "hello", 5, 0) == ANOLE_OK);
    read_until(fd, buf, sizeof buf, &len, "data: hello");
    CHECK(strstr(buf, "event: tick"));
    close(fd);
    printf("ok native route\n");
  }

  /* A consumer route. */
  {
    char b1[4096], b2[4096];
    size_t l1 = 0, l2 = 0;
    int c1 = open_stream(port, "/me", "");
    wait_for(&subscribes, 1);
    int c2 = open_stream(port, "/me", "");
    wait_for(&subscribes, 2);
    anole_sse h1 = atomic_load(&handles[0]), h2 = atomic_load(&handles[1]);
    CHECK(h1 && h2 && h1 != h2);
    CHECK(anole_sse_send(h1, S("only"), "for one", 7, 0) == ANOLE_OK);
    CHECK(anole_sse_send(h2, S("only"), "for two", 7, 0) == ANOLE_OK);
    read_until(c1, b1, sizeof b1, &l1, "data: for one");
    CHECK(!strstr(b1, "for two"));
    read_until(c2, b2, sizeof b2, &l2, "data: for two");
    CHECK(!strstr(b2, "for one"));
    CHECK(anole_sse_send(h1, S("a\nb"), "x", 1, 0) == ANOLE_E_INVALID);
    CHECK(anole_sse_send(h1, S(""), "x", 1, 1) == ANOLE_E_INVALID);
    /* The topic the consumer named. */
    CHECK(anole_sse_publish(s, S("x"), S(""), "both", 4, 0) == ANOLE_OK);
    read_until(c1, b1, sizeof b1, &l1, "data: both");
    read_until(c2, b2, sizeof b2, &l2, "data: both");
    /* A client that leaves: SSE_CLOSE (client gone), then the handle is stale. */
    close(c1);
    wait_for(&closes, 1);
    CHECK(atomic_load(&last_close_reason) == ANOLE_SSE_CLOSED_CLIENT_GONE);
    CHECK(atomic_load(&last_close_handle) == h1);
    CHECK(anole_sse_send(h1, S(""), "late", 4, 0) == ANOLE_E_GONE);
    CHECK(anole_sse_close(h1) == ANOLE_OK);
    CHECK(anole_handle_release(h1) == ANOLE_OK);
    /* anole_sse_close on a live one: CLOSED. */
    CHECK(anole_sse_close(h2) == ANOLE_OK);
    wait_for(&closes, 2);
    CHECK(atomic_load(&last_close_reason) == ANOLE_SSE_CLOSED_CLOSED);
    close(c2);
    printf("ok consumer route\n");
  }

  CHECK(anole_server_drain(s) == ANOLE_OK);
  CHECK(anole_server_wait(s, 10000) == ANOLE_OK);
  atomic_store(&stop_consumer, 1);
  pthread_join(t, NULL);
  anole_server_destroy(s);
  printf("sse: all passed\n");
  return 0;
}
