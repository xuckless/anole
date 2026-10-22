# Migrating to 0.2

Anole 0.2.0 batches its breaking changes. This page has one section per
area; the full list is in [CHANGELOG.md](../CHANGELOG.md).

## The C ABI (0.6 to 0.7)

The C ABI moves to version 0.7. Before 1.0 every minor may break, so a library
serves only code built against the same version: check
`ANOLE_ABI_COMPATIBLE(anole_abi_version())` at load, and replace any
`major ==` / `minor >=` comparison with it.

Rename the calls and constants (a search and replace is enough for most):

| 0.6 | 0.7 |
| --- | --- |
| `anole_respond(r, ...)` | `anole_req_respond(r, ...)` |
| `anole_respond_fd(r, ..., int fd, ...)` | `anole_req_respond_fd(r, ..., intptr_t fd, ...)` |
| `anole_stream_start/write/write_wait/end` | `anole_req_stream_start/write/write_wait/end` |
| `anole_release(r)` | `anole_req_fail(r, 0, (anole_str){0})` (500) or `anole_handle_release(r)` (finalizers) |
| (none) | `anole_req_abort(r)` |
| `anole_wt_stream_release(s)` | `anole_handle_release(s)` |
| `anole_server_port(s, i, &port)` | `anole_server_listener(s, i, &info)`; `info.port`, `info.udp_port` |
| `anole_server_reload_certificates(s)` | `anole_server_reload_tls(s, 0, (anole_str){0}, (anole_str){0})` |
| `anole_server_reload_tls(s, f, c, cl, k, kl)` | `anole_server_reload_tls(s, f, (anole_str){c, cl}, (anole_str){k, kl})` |
| `anole_wt_send_datagram(w, d, n)` | `anole_wt_send_datagram(w, d, n, 0)` |
| `ANOLE_EV_WS_DRAIN` | `ANOLE_EV_WRITABLE` (`ev.handle` the socket) |
| `ANOLE_EV_ABORT` read as `anole_event` | `anole_abort_event` (`reason`, `status`) |
| `anole_request_spans(r)` = `r + 1` | the same helper, now reading `r->spans_off` |
| `anole_request_peer_cert(r)` | `anole_event_str(r, r->peer_cert)` |
| gRPC metadata at `c + 1` | `anole_grpc_metadata(c)` (`c->metadata_off`) |
| `ANOLE_DB_INT`... | `ANOLE_DB_TYPE_INT`...; `ANOLE_DB_WRITE`... are `ANOLE_DB_F_*` |
| `ANOLE_GRPC_OK`... | `ANOLE_GRPC_STATUS_OK`...; `ANOLE_GRPC_UNARY`... are `ANOLE_GRPC_KIND_*`; `ANOLE_GRPC_SEND_FINISH` is `ANOLE_GRPC_F_FINISH` |
| `ANOLE_WT_UNI`, `ANOLE_WT_FIN` | `ANOLE_WT_F_UNI`, `ANOLE_WT_F_FIN` (values kept) |
| `ANOLE_TLS_PEM`, `ANOLE_SERVER_SIGNALS`, `ANOLE_CONSUMER_SHARED`, `ANOLE_POLL_NOARM` | `ANOLE_TLS_F_PEM`, `ANOLE_SERVER_F_SIGNALS`, `ANOLE_CONSUMER_F_SHARED`, `ANOLE_POLL_F_NOARM` |
| enum-valued parameters as `int` (`anole_ws_send`'s type, the log callback's level) | `uint32_t`; `anole_consumer_fd` returns `intptr_t`; `anole_has_feature` returns `int32_t` |

Behaviour that changes with the rename:

- **Cleanup calls are idempotent.** `anole_handle_release`, `anole_req_abort`,
  `anole_ws_close`, `anole_ws_unsubscribe`, `anole_wt_close`,
  `anole_wt_stream_reset` and `anole_wt_stream_stop` answer `ANOLE_OK` on an
  object that is already over, set no error and are not counted in
  `anole_stats.gone`. Code that treated `ANOLE_E_GONE` from a close or release
  as harmless keeps working (it now gets OK). Answer and data calls still
  answer `ANOLE_E_GONE`.
- **A handle of the wrong kind, or 0, is `ANOLE_E_INVALID`** (token
  `WrongHandleKind`), not `ANOLE_E_GONE`. Code that relied on GONE to detect
  a wrong-kind handle must check `ANOLE_E_INVALID`.
- **Options structs and flags are checked.** An options struct larger than the
  library knows is refused unless the extra bytes are 0; unknown flag bits
  (`anole_db_options.flags` included) and non-zero reserved fields
  (`anole_db_value.reserved`, `anole_db_options.reserved`) are
  `ANOLE_E_INVALID`.
- **`ANOLE_E_TOOBIG` from a poll** writes an `ANOLE_EV_NONE` header with the
  needed `len`; allocate that once instead of doubling.
- **Records**: read the header spans through `spans_off` and the gRPC metadata
  through `metadata_off`, never `sizeof`; the client certificate is a span
  (`peer_cert`), no longer a length-prefixed blob.
- **`anole_ws_publish`** on a server that is not running is `ANOLE_E_STATE`
  (was `ANOLE_E_GONE`); a failed `dup` in `anole_req_respond_fd` is
  `ANOLE_E_SYSTEM` (was `ANOLE_E_INVALID`).
- **Generate, do not hand-write**: `include/anole.abi.json` (and
  `include/anole.schema.json` for the configuration) describe every record,
  constant, event and handle kind; generate your parsers from them, pinned to
  the Anole tag.

New in 0.7 (see docs/c-abi.md): `anole_server_open`, `anole_server_set_ready`,
`anole_server_listener(_count)`, `anole_last_error_name`, `anole_last_errno`,
`anole_consumer_set_wake`, the allocation table, abort reasons, and a destroy
that does not wait for answers only its caller could give.
