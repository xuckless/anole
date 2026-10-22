/* tests/capi/layout.c - the record layouts anole.h promises, checked at
   compile time on every target the C ABI builds for (Windows included; CI
   compiles it with zig cc for x86_64 and aarch64 Windows):
     zig cc -target x86_64-windows-gnu -std=c99 -Iinclude -c tests/capi/layout.c
   On Linux and macOS, `zig build capi-test` checks every struct against the
   Zig side as well (src/capi/abi_test.zig). */
#include <stddef.h>
#include "anole.h"

#define AT(type, field, off) _Static_assert(offsetof(type, field) == (off), #type "." #field)

_Static_assert(sizeof(anole_event) == 16, "anole_event");
AT(anole_event, len, 4);
AT(anole_event, handle, 8);
_Static_assert(sizeof(anole_span) == 8, "anole_span");
_Static_assert(sizeof(anole_request_event) == 104, "anole_request_event");
AT(anole_request_event, route_id, 16);
AT(anole_request_event, method, 20);
AT(anole_request_event, version, 21);
AT(anole_request_event, flags, 22);
AT(anole_request_event, method_name, 24);
AT(anole_request_event, path, 32);
AT(anole_request_event, query, 40);
AT(anole_request_event, body, 48);
AT(anole_request_event, remote_addr, 56);
AT(anole_request_event, listener, 64);
AT(anole_request_event, id, 72);
AT(anole_request_event, claims, 80);
AT(anole_request_event, nheaders, 88);
AT(anole_request_event, nparams, 90);
AT(anole_request_event, content_length, 96);
_Static_assert(sizeof(anole_sent_event) == 32, "anole_sent_event");
_Static_assert(sizeof(anole_ws_message_event) == 32, "anole_ws_message_event");
AT(anole_ws_message_event, data, 24);
_Static_assert(sizeof(anole_ws_close_event) == 32, "anole_ws_close_event");
AT(anole_ws_close_event, code, 20);
AT(anole_ws_close_event, reason, 24);
_Static_assert(sizeof(anole_req) == 8 && sizeof(anole_ws) == 8, "handles");
AT(anole_server_options, size, 0);
AT(anole_consumer_options, size, 0);
AT(anole_stats, size, 0);
int anole_layout_ok;
