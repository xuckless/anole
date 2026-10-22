/* spike/node/addon.c - THROWAWAY Node-API addon over libanole (M17 spike).
 * Not shipped; anole-node will be its own repo.
 *
 * The crossing as designed (research/c-abi-design-2026-10-21.md):
 *  - Anole's wake callback (on an executor) calls
 *    napi_call_threadsafe_function(nonblocking); the doorbell only rings
 *    when the consumer re-armed it (anole_poll returned 0), so at most one
 *    call is queued at a time.
 *  - On the JS thread, drain() polls into ONE JS-owned ArrayBuffer (no
 *    external buffers: V8's sandbox refuses them) and makes ONE JS call per
 *    batch: onBatch(bytes) decodes the records with a DataView, runs the
 *    handlers, and writes the replies into a second JS-owned ArrayBuffer,
 *    returning its length. drain() then answers each reply with
 *    anole_respond. Two crossings per batch, none per request.
 *
 * Reply buffer format (little-endian, written by JS):
 *   repeated { u32 handle_lo; u32 handle_hi; u16 status; u16 ct; u32 body_len; body bytes; pad to 4 }
 *   ct: 0 none, 1 text/plain, 2 application/json
 */
#define NAPI_VERSION 8
#include <node_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>

#include "anole.h"

#define CHECK(x)                                                                    \
  do {                                                                              \
    napi_status s_ = (x);                                                           \
    if (s_ != napi_ok) {                                                            \
      fprintf(stderr, "napi call failed (%d) at %s:%d: %s\n", s_, __FILE__, __LINE__, #x); \
      abort();                                                                      \
    }                                                                               \
  } while (0)

typedef struct {
  anole_server *server;
  anole_consumer *consumer;
  napi_threadsafe_function tsfn;
  napi_ref on_batch;     /* JS (bytes) -> reply bytes */
  napi_ref events_ab;    /* ArrayBuffer the events land in */
  napi_ref replies_ab;   /* ArrayBuffer the replies come back in */
  void *events;
  size_t events_cap;
  unsigned char *replies;
  size_t replies_cap;
  int stopped;
  /* counters */
  double batches, events_n, wake_calls;
} addon_state;

static addon_state st;

/* On an Anole executor: must not block or enter JS. */
static _Atomic unsigned long wake_failures, wakes_sent;
/* Bun 1.3.14 loses napi_call_threadsafe_function calls made from several
   threads at once (found by this spike: sent = delivered + 1 at the stall).
   Wakes are rare (only when the consumer sleeps), so one lock around the
   call costs nothing measurable and keeps Bun's queue single-producer.
   ANOLE_SPIKE_WAKE_LOCK=0 turns it off to show the bug. */
static pthread_mutex_t wake_lock = PTHREAD_MUTEX_INITIALIZER;
static int use_wake_lock = 1;
static void wake(void *ud) {
  (void)ud;
  wakes_sent++;
  if (use_wake_lock) pthread_mutex_lock(&wake_lock);
  if (napi_call_threadsafe_function(st.tsfn, NULL, napi_tsfn_nonblocking) != napi_ok) wake_failures++;
  if (use_wake_lock) pthread_mutex_unlock(&wake_lock);
}

static const anole_header ct_text[] = {{{"content-type", 12}, {"text/plain", 10}}};
static const anole_header ct_json[] = {{{"content-type", 12}, {"application/json", 16}}};

/* On the JS thread. */
static void drain(napi_env env) {
  napi_value on_batch, undefined, arg, result;
  CHECK(napi_get_reference_value(env, st.on_batch, &on_batch));
  CHECK(napi_get_undefined(env, &undefined));
  for (;;) {
    int64_t n = anole_poll(st.consumer, st.events, st.events_cap, 0);
    if (n <= 0) {
      if (n < 0) fprintf(stderr, "anole_poll: %lld\n", (long long)n);
      return;
    }
    st.batches++;
    CHECK(napi_create_double(env, (double)n, &arg));
    CHECK(napi_call_function(env, undefined, on_batch, 1, &arg, &result));
    double rlen = 0;
    if (napi_get_value_double(env, result, &rlen) != napi_ok || rlen < 0) rlen = 0;
    if (rlen < 0 || (size_t)rlen > st.replies_cap) abort();
    /* answer the batch */
    size_t off = 0, end = (size_t)rlen;
    while (off + 16 <= end) {
      uint32_t lo, hi, body_len;
      uint16_t status, ct;
      memcpy(&lo, st.replies + off, 4);
      memcpy(&hi, st.replies + off + 4, 4);
      memcpy(&status, st.replies + off + 8, 2);
      memcpy(&ct, st.replies + off + 10, 2);
      memcpy(&body_len, st.replies + off + 12, 4);
      off += 16;
      anole_req h = ((uint64_t)hi << 32) | lo;
      const anole_header *hs = ct == 1 ? ct_text : ct == 2 ? ct_json : NULL;
      anole_respond(h, status, hs, hs ? 1 : 0, st.replies + off, body_len, 0);
      off += (body_len + 3) & ~(size_t)3;
    }
    /* STOPPED is reported by JS through its return; check the record */
    const anole_event *first = st.events;
    if (first->type == ANOLE_EV_STOPPED) {
      st.stopped = 1;
      return;
    }
  }
}

static void call_js(napi_env env, napi_value js_cb, void *context, void *data) {
  (void)js_cb;
  (void)context;
  (void)data;
  if (!env) return;
  st.wake_calls++;
  drain(env);
}

static napi_value js_error(napi_env env, const char *what, int code) {
  anole_str e = anole_last_error();
  char msg[600];
  snprintf(msg, sizeof msg, "%s failed (%d): %.*s", what, code, (int)e.len, e.ptr);
  napi_throw_error(env, NULL, msg);
  return NULL;
}

/* start(configJson: string, onBatch: (bytes) => replyBytes, events: ArrayBuffer, replies: ArrayBuffer) -> port */
static napi_value start(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value argv[4];
  CHECK(napi_get_cb_info(env, info, &argc, argv, NULL, NULL));
  size_t len = 0;
  CHECK(napi_get_value_string_utf8(env, argv[0], NULL, 0, &len));
  char *json = malloc(len + 1);
  CHECK(napi_get_value_string_utf8(env, argv[0], json, len + 1, &len));
  CHECK(napi_create_reference(env, argv[1], 1, &st.on_batch));
  CHECK(napi_create_reference(env, argv[2], 1, &st.events_ab));
  CHECK(napi_create_reference(env, argv[3], 1, &st.replies_ab));
  CHECK(napi_get_arraybuffer_info(env, argv[2], &st.events, &st.events_cap));
  CHECK(napi_get_arraybuffer_info(env, argv[3], (void **)&st.replies, &st.replies_cap));

  napi_value name;
  CHECK(napi_create_string_utf8(env, "anole-wake", NAPI_AUTO_LENGTH, &name));
  CHECK(napi_create_threadsafe_function(env, NULL, NULL, name, 0, 1, NULL, NULL, NULL, call_js, &st.tsfn));

  const char *wl = getenv("ANOLE_SPIKE_WAKE_LOCK");
  use_wake_lock = !(wl && wl[0] == '0');
  anole_server_options o = {sizeof o, {json, len}, 0};
  int rc = anole_server_create(&o, &st.server);
  free(json);
  if (rc != ANOLE_OK) return js_error(env, "anole_server_create", rc);
  anole_consumer_options co = {sizeof co, wake, NULL, 0};
  rc = anole_consumer_attach(st.server, &co, &st.consumer);
  if (rc != ANOLE_OK) return js_error(env, "anole_consumer_attach", rc);
  rc = anole_server_start(st.server);
  if (rc != ANOLE_OK) return js_error(env, "anole_server_start", rc);
  uint16_t port = 0;
  anole_server_port(st.server, 0, &port);
  napi_value out;
  CHECK(napi_create_uint32(env, port, &out));
  return out;
}

/* stop(): drain; the consumer keeps answering until STOPPED, then frees. */
static napi_value stop(napi_env env, napi_callback_info info) {
  (void)info;
  anole_server_drain(st.server);
  /* Serve what is in flight from here (the JS thread is ours now). */
  while (!st.stopped) {
    drain(env);
    if (!st.stopped) {
      struct timespec ts = {0, 1000000};
      nanosleep(&ts, NULL);
    }
  }
  anole_stats as = {.size = sizeof as};
  anole_server_stats(st.server, &as);
  anole_server_destroy(st.server);
  st.server = NULL;
  napi_release_threadsafe_function(st.tsfn, napi_tsfn_release);
  napi_value out;
  CHECK(napi_create_object(env, &out));
  napi_value v;
  CHECK(napi_create_double(env, st.batches, &v));
  CHECK(napi_set_named_property(env, out, "batches", v));
  CHECK(napi_create_double(env, st.wake_calls, &v));
  CHECK(napi_set_named_property(env, out, "wakes", v));
  CHECK(napi_create_double(env, (double)as.rewakes, &v));
  CHECK(napi_set_named_property(env, out, "anole_rewakes", v));
  CHECK(napi_create_double(env, (double)as.wakes, &v));
  CHECK(napi_set_named_property(env, out, "anole_wakes", v));
  CHECK(napi_create_double(env, (double)wakes_sent, &v));
  CHECK(napi_set_named_property(env, out, "wakes_sent", v));
  CHECK(napi_create_double(env, (double)wake_failures, &v));
  CHECK(napi_set_named_property(env, out, "wake_failures", v));
  return out;
}

NAPI_MODULE_INIT(/* napi_env env, napi_value exports */) {
  napi_property_descriptor props[] = {
      {"start", NULL, start, NULL, NULL, NULL, napi_default, NULL},
      {"stop", NULL, stop, NULL, NULL, NULL, napi_default, NULL},
  };
  CHECK(napi_define_properties(env, exports, 2, props));
  return exports;
}
