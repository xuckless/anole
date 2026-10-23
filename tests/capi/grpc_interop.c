/* tests/capi/grpc_interop.c - grpc.testing.TestService implemented in C on
 * libanole's gRPC ABI, for gRPC's interop client:
 *
 *   capi-grpc-interop <port> [cert.pem key.pem]
 *
 * tests/grpc/interop/run.sh runs grpc-go's interop client against it (as
 * against the native tests/grpc/interop/server.zig). One consumer thread,
 * anole.h only, and protobuf by hand: the few messages of
 * grpc/testing/messages.proto it needs, read and written field by field.
 */
#define _GNU_SOURCE
#include "anole.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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

/* An answer that may fail because the client left (ANOLE_E_GONE). */
static void ok_or_gone(anole_status r) { CHECK(r == ANOLE_OK || r == ANOLE_BUSY || r == ANOLE_E_GONE); }

/* ---- protobuf, by hand ------------------------------------------------------------- */

typedef struct {
  const unsigned char *p, *end;
} pbr;

typedef struct {
  uint32_t field, wire;
  uint64_t v;
  const unsigned char *data;
  size_t len;
} pbf;

static int varint(pbr *r, uint64_t *out) {
  uint64_t v = 0;
  for (int shift = 0; shift < 64; shift += 7) {
    if (r->p >= r->end) return 0;
    unsigned char b = *r->p++;
    v |= (uint64_t)(b & 0x7f) << shift;
    if (!(b & 0x80)) {
      *out = v;
      return 1;
    }
  }
  return 0;
}

/* The next field; 0 at the end (or on bytes that do not decode). */
static int next(pbr *r, pbf *f) {
  uint64_t key;
  if (r->p >= r->end || !varint(r, &key)) return 0;
  f->field = (uint32_t)(key >> 3);
  f->wire = key & 7;
  switch (f->wire) {
    case 0:
      return varint(r, &f->v);
    case 1:
      if (r->end - r->p < 8) return 0;
      r->p += 8;
      return 1;
    case 2: {
      uint64_t l;
      if (!varint(r, &l) || l > (uint64_t)(r->end - r->p)) return 0;
      f->data = r->p;
      f->len = (size_t)l;
      r->p += l;
      return 1;
    }
    case 5:
      if (r->end - r->p < 4) return 0;
      r->p += 4;
      return 1;
  }
  return 0;
}

static pbr reader(const void *p, size_t len) {
  pbr r = {p, (const unsigned char *)p + len};
  return r;
}

static size_t put_varint(unsigned char *out, uint64_t v) {
  size_t n = 0;
  while (v >= 0x80) {
    out[n++] = (unsigned char)(v | 0x80);
    v >>= 7;
  }
  out[n++] = (unsigned char)v;
  return n;
}

/* A message whose field 1 is Payload{body: `size` zero bytes} (SimpleResponse,
   StreamingOutputCallResponse). Returns its length; `out` has room. */
static size_t payload_message(unsigned char *out, size_t size) {
  unsigned char inner[16];
  size_t k = 0;
  /* Payload.body (2), its length; the zeros follow. */
  inner[k++] = 0x12;
  k += put_varint(inner + k, size);
  size_t payload_len = size > 0 ? k + size : 0;
  size_t n = 0;
  out[n++] = 0x0a;
  n += put_varint(out + n, payload_len);
  if (size > 0) {
    memcpy(out + n, inner, k);
    n += k;
    memset(out + n, 0, size);
    n += size;
  }
  return n;
}

typedef struct {
  int code;
  const unsigned char *message;
  size_t message_len;
} echo_status;

static echo_status read_status(const unsigned char *p, size_t len) {
  echo_status s = {0, NULL, 0};
  pbr r = reader(p, len);
  pbf f;
  while (next(&r, &f)) {
    if (f.field == 1 && f.wire == 0) s.code = (int)f.v;
    if (f.field == 2 && f.wire == 2) s.message = f.data, s.message_len = f.len;
  }
  return s;
}

/* ---- the service ---------------------------------------------------------------------- */

enum { EMPTY, UNARY, CACHEABLE, STREAM_OUT, STREAM_IN, FULL_DUPLEX, HALF_DUPLEX, UNIMPLEMENTED };

typedef struct {
  anole_grpc_call call;
  int method;
  uint64_t total;                 /* StreamingInputCall */
  unsigned char trailing[256];    /* x-grpc-test-echo-trailing-bin, as bytes */
  size_t trailing_len;
  int has_trailing;
  int sizes[64], nsizes;          /* HalfDuplexCall: the responses to send */
} call_state;

static call_state calls[256];
static unsigned char *out_buf;

static call_state *state_of(anole_grpc_call c, int create) {
  for (int i = 0; i < 256; i++)
    if (calls[i].call == c) return &calls[i];
  if (!create) return NULL;
  for (int i = 0; i < 256; i++)
    if (calls[i].call == 0) {
      memset(&calls[i], 0, sizeof calls[i]);
      calls[i].call = c;
      return &calls[i];
    }
  return NULL;
}

static void drop(anole_grpc_call c) {
  call_state *st = state_of(c, 0);
  if (st) st->call = 0;
}

static anole_str md_of(const anole_grpc_call_event *ev, const char *name) {
  const anole_span *sp = anole_grpc_metadata((const anole_grpc_call_event *)ev);
  for (uint16_t i = 0; i < ev->nmetadata; i++) {
    anole_str k = anole_event_str(ev, sp[2 * i]);
    if (k.len == strlen(name) && memcmp(k.ptr, name, k.len) == 0) return anole_event_str(ev, sp[2 * i + 1]);
  }
  anole_str none = {NULL, 0};
  return none;
}

/* Ends the call with `code`, echoing the trailing metadata it asked for. */
static void finish(call_state *st, int code, const unsigned char *msg, size_t msg_len) {
  anole_header t[1];
  size_t n = 0;
  if (st->has_trailing) {
    t[0].name = S("x-grpc-test-echo-trailing-bin");
    t[0].value.ptr = (const char *)st->trailing;
    t[0].value.len = st->trailing_len;
    n = 1;
  }
  anole_str m = {(const char *)msg, msg_len};
  ok_or_gone(anole_grpc_finish(st->call, (uint32_t)code, m, t, n));
  drop(st->call);
}

static void sleep_us(uint64_t us) {
  struct timespec ts = {(time_t)(us / 1000000), (long)(us % 1000000) * 1000L};
  nanosleep(&ts, NULL);
}

/* The responses a StreamingOutputCallRequest asks for; its status, if any.
   Returns 0 when the call ended (a status, or the client left). */
static int stream_out(call_state *st, const unsigned char *p, size_t len, int send_now) {
  pbr r = reader(p, len);
  pbf f;
  echo_status status = {0, NULL, 0};
  while (next(&r, &f)) {
    if (f.field == 7 && f.wire == 2) status = read_status(f.data, f.len);
  }
  if (status.code != 0) {
    finish(st, status.code, status.message, status.message_len);
    return 0;
  }
  r = reader(p, len);
  while (next(&r, &f)) {
    if (f.field != 2 || f.wire != 2) continue;
    uint64_t size = 0, interval = 0;
    pbr pr = reader(f.data, f.len);
    pbf g;
    while (next(&pr, &g)) {
      if (g.field == 1 && g.wire == 0) size = g.v;
      if (g.field == 2 && g.wire == 0) interval = g.v;
    }
    if (!send_now) {
      if (st->nsizes < 64) st->sizes[st->nsizes++] = (int)size;
      continue;
    }
    if (interval > 0) sleep_us(interval);
    size_t n = payload_message(out_buf, size);
    anole_status s = anole_grpc_send_wait(st->call, out_buf, n, 10000);
    if (s == ANOLE_E_GONE) return 0;
    CHECK(s == ANOLE_OK);
  }
  return 1;
}

static void on_call(const anole_grpc_call_event *ev) {
  anole_grpc_call c = ev->ev.handle;
  call_state *st = state_of(c, 1);
  CHECK(st);
  st->method = ev->method_id;
  anole_str initial = md_of(ev, "x-grpc-test-echo-initial");
  if (initial.ptr) {
    anole_header h[1] = {{S("x-grpc-test-echo-initial"), initial}};
    ok_or_gone(anole_grpc_send_headers(c, h, 1));
  }
  anole_str trailing = md_of(ev, "x-grpc-test-echo-trailing-bin");
  if (trailing.ptr && trailing.len <= sizeof st->trailing) {
    memcpy(st->trailing, trailing.ptr, trailing.len);
    st->trailing_len = trailing.len;
    st->has_trailing = 1;
  }
  anole_str msg = anole_event_str(ev, ev->message);
  switch (ev->method_id) {
    case EMPTY:
      ok_or_gone(anole_grpc_send(c, "", 0, 0));
      finish(st, ANOLE_GRPC_STATUS_OK, NULL, 0);
      return;
    case UNARY:
    case CACHEABLE: {
      pbr r = reader(msg.ptr, msg.len);
      pbf f;
      uint64_t size = 0;
      int expect_compressed = 0;
      echo_status status = {0, NULL, 0};
      while (next(&r, &f)) {
        if (f.field == 2 && f.wire == 0) size = f.v;
        if (f.field == 7 && f.wire == 2) status = read_status(f.data, f.len);
        if (f.field == 8 && f.wire == 2) {
          pbr b = reader(f.data, f.len);
          pbf g;
          while (next(&b, &g))
            if (g.field == 1 && g.wire == 0) expect_compressed = g.v != 0;
        }
      }
      if (expect_compressed && !(ev->flags & ANOLE_GRPC_CALL_COMPRESSED)) {
        finish(st, ANOLE_GRPC_STATUS_INVALID_ARGUMENT, (const unsigned char *)"expected a compressed request", 29);
        return;
      }
      if (status.code != 0) {
        finish(st, status.code, status.message, status.message_len);
        return;
      }
      size_t n = payload_message(out_buf, size);
      ok_or_gone(anole_grpc_send(c, out_buf, n, 0));
      finish(st, ANOLE_GRPC_STATUS_OK, NULL, 0);
      return;
    }
    case STREAM_OUT:
      if (stream_out(st, (const unsigned char *)msg.ptr, msg.len, 1)) finish(st, ANOLE_GRPC_STATUS_OK, NULL, 0);
      return;
    case STREAM_IN:
    case FULL_DUPLEX:
    case HALF_DUPLEX:
      return; /* messages follow */
    default:
      finish(st, ANOLE_GRPC_STATUS_UNIMPLEMENTED, (const unsigned char *)"not implemented", 15);
      return;
  }
}

static void on_message(const anole_grpc_message_event *ev) {
  call_state *st = state_of(ev->ev.handle, 0);
  if (!st) return;
  anole_str data = anole_event_str(ev, ev->data);
  switch (st->method) {
    case STREAM_IN: {
      pbr r = reader(data.ptr, data.len);
      pbf f;
      while (next(&r, &f)) {
        if (f.field != 1 || f.wire != 2) continue;
        pbr pr = reader(f.data, f.len);
        pbf g;
        while (next(&pr, &g))
          if (g.field == 2 && g.wire == 2) st->total += g.len;
      }
      break;
    }
    case FULL_DUPLEX:
      if (!stream_out(st, (const unsigned char *)data.ptr, data.len, 1)) return;
      break;
    case HALF_DUPLEX:
      stream_out(st, (const unsigned char *)data.ptr, data.len, 0);
      break;
  }
  ok_or_gone(anole_grpc_read(st->call, 1));
}

static void on_half_close(anole_grpc_call c) {
  call_state *st = state_of(c, 0);
  if (!st) return;
  if (st->method == STREAM_IN) {
    unsigned char m[16];
    size_t n = 0;
    m[n++] = 0x08;
    n += put_varint(m + n, st->total);
    ok_or_gone(anole_grpc_send(c, m, n, 0));
  } else if (st->method == HALF_DUPLEX) {
    for (int i = 0; i < st->nsizes; i++) {
      size_t n = payload_message(out_buf, (size_t)st->sizes[i]);
      if (anole_grpc_send_wait(c, out_buf, n, 10000) != ANOLE_OK) {
        drop(c);
        return;
      }
    }
  }
  finish(st, ANOLE_GRPC_STATUS_OK, NULL, 0);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <port> [cert.pem key.pem]\n", argv[0]);
    return 2;
  }
  out_buf = malloc(4 << 20);
  CHECK(out_buf);
  char tls[1024] = "";
  if (argc >= 4) snprintf(tls, sizeof tls, ", \"tls\": {\"cert_file\": \"%s\", \"key_file\": \"%s\"}, \"http3\": true", argv[2], argv[3]);
  char json[4096];
  snprintf(json, sizeof json,
           "{\"listeners\": [{\"address\": \"127.0.0.1\", \"port\": %d%s}],"
           " \"grpc\": {\"services\": [{\"name\": \"grpc.testing.TestService\", \"handler\": 1, \"methods\": ["
           "  {\"name\": \"EmptyCall\", \"kind\": \"unary\"}, {\"name\": \"UnaryCall\", \"kind\": \"unary\"},"
           "  {\"name\": \"CacheableUnaryCall\", \"kind\": \"unary\"},"
           "  {\"name\": \"StreamingOutputCall\", \"kind\": \"server_streaming\"},"
           "  {\"name\": \"StreamingInputCall\", \"kind\": \"client_streaming\"},"
           "  {\"name\": \"FullDuplexCall\", \"kind\": \"bidi_streaming\"},"
           "  {\"name\": \"HalfDuplexCall\", \"kind\": \"bidi_streaming\"},"
           "  {\"name\": \"UnimplementedCall\", \"kind\": \"unary\"}]}]}}",
           atoi(argv[1]), tls);
  anole_server_options o = {sizeof o, {json, strlen(json)}, 0, 0, NULL, NULL};
  anole_server *s = NULL;
  CHECK(anole_server_create(&o, &s) == ANOLE_OK);
  anole_consumer *consumer = NULL;
  anole_consumer_options co = {sizeof co, NULL, NULL, ANOLE_CONSUMER_F_SHARED};
  CHECK(anole_consumer_attach(s, &co, &consumer) == ANOLE_OK);
  CHECK(anole_server_start(s) == ANOLE_OK);
  fprintf(stderr, "capi grpc interop server on 127.0.0.1:%s (%s)\n", argv[1], argc >= 4 ? "TLS + HTTP/3" : "h2c");
  static _Alignas(8) unsigned char buf[2 << 20];
  for (;;) {
    int64_t n = anole_poll_wait(consumer, buf, sizeof buf, 1000);
    CHECK(n >= 0);
    for (int64_t off = 0; off < n;) {
      const anole_event *ev = (const anole_event *)(buf + off);
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
        case ANOLE_EV_ABORT:
          drop(ev->handle);
          break;
        case ANOLE_EV_STOPPED:
          anole_server_destroy(s);
          return 0;
      }
      off += ev->len;
    }
  }
}
