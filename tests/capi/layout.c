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
_Static_assert(sizeof(void *) == 8 && sizeof(size_t) == 8, "64-bit targets only");
_Static_assert(sizeof(anole_request_event) == 128, "anole_request_event");
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
AT(anole_request_event, spans_off, 92);
AT(anole_request_event, content_length, 96);
AT(anole_request_event, peer_cert, 104);
AT(anole_request_event, timeout_us, 112);
AT(anole_request_event, subprotocol, 120);
_Static_assert(sizeof(anole_abort_event) == 24, "anole_abort_event");
AT(anole_abort_event, reason, 16);
AT(anole_abort_event, status, 18);
_Static_assert(sizeof(anole_ws_accept_options) == 48, "anole_ws_accept_options");
AT(anole_ws_accept_options, flags, 8);
AT(anole_ws_accept_options, reserved, 12);
AT(anole_ws_accept_options, subprotocol, 16);
AT(anole_ws_accept_options, headers, 32);
AT(anole_ws_accept_options, nheaders, 40);
_Static_assert(sizeof(anole_grpc_call_event) == 104, "anole_grpc_call_event");
AT(anole_grpc_call_event, method, 32);
AT(anole_grpc_call_event, claims, 72);
AT(anole_grpc_call_event, timeout_us, 80);
AT(anole_grpc_call_event, metadata_off, 88);
AT(anole_grpc_call_event, peer_cert, 96);
_Static_assert(sizeof(anole_listener_info) == 72, "anole_listener_info");
AT(anole_listener_info, name, 8);
AT(anole_listener_info, address, 24);
AT(anole_listener_info, port, 40);
AT(anole_listener_info, udp_port, 42);
AT(anole_listener_info, flags, 44);
AT(anole_listener_info, state, 48);
AT(anole_listener_info, error_errno, 52);
AT(anole_listener_info, error_name, 56);
_Static_assert(sizeof(anole_db_options) == 48, "anole_db_options");
AT(anole_db_options, reserved, 20);
AT(anole_db_options, cache_tag, 24);
AT(anole_db_options, req, 40);
_Static_assert(sizeof(anole_db_tx_options) == 32, "anole_db_tx_options");
AT(anole_db_tx_options, flags, 8);
AT(anole_db_tx_options, isolation, 12);
AT(anole_db_tx_options, timeout_ms, 16);
AT(anole_db_tx_options, reserved, 20);
AT(anole_db_tx_options, req, 24);
_Static_assert(sizeof(anole_db_result_event) == 104, "anole_db_result_event");
AT(anole_db_result_event, constraint, 88);
AT(anole_db_result_event, table, 96);
_Static_assert(sizeof(anole_db_tx) == 8, "anole_db_tx");
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
