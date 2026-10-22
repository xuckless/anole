/* tests/capi/layout.c - the record layouts anole.h promises, checked at
   compile time on every target the C ABI builds for (Windows included):
   zig cc -target x86_64-windows-gnu -Iinclude -c tests/capi/layout.c */
#include <stddef.h>
#include "anole.h"

_Static_assert(sizeof(anole_event) == 16, "anole_event");
_Static_assert(offsetof(anole_event, handle) == 8, "anole_event.handle");
_Static_assert(sizeof(anole_span) == 8, "anole_span");
_Static_assert(sizeof(anole_request_event) == 64, "anole_request_event");
_Static_assert(offsetof(anole_request_event, route_id) == 16, "route_id");
_Static_assert(offsetof(anole_request_event, method_name) == 24, "method_name");
_Static_assert(offsetof(anole_request_event, path) == 32, "path");
_Static_assert(offsetof(anole_request_event, query) == 40, "query");
_Static_assert(offsetof(anole_request_event, body) == 48, "body");
_Static_assert(offsetof(anole_request_event, nheaders) == 56, "nheaders");
_Static_assert(offsetof(anole_request_event, nparams) == 58, "nparams");
_Static_assert(sizeof(anole_req) == 8, "anole_req");
_Static_assert(offsetof(anole_server_options, size) == 0, "options start with size");
_Static_assert(offsetof(anole_consumer_options, size) == 0, "options start with size");
_Static_assert(offsetof(anole_stats, size) == 0, "stats start with size");
int anole_layout_ok;
