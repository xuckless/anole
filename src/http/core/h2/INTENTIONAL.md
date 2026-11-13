# Intentional divergences from nghttp2

Where the HTTP/2 core in this directory behaves differently from nghttp2 on
purpose. The differential tests (`*_diff_test.zig`, PLAN §5.3) accept exactly
these and nothing else.

## HPACK (hpack.zig)

1. **A decoded header-list limit.** The decoder adds name + value + 32 per
   field (RFC 9113 §6.5.2) and refuses the first field that takes the list
   past `max_list_size` with `HeaderListTooLarge`, before emitting or copying
   it; `skipRest()` then decodes the rest of the block for its table effects
   (RFC 9113 §4.3, §10.5.1: the block must be processed to keep the
   connection state). nghttp2's inflater has no limit; Anole's nghttp2
   callback (`onHeader` in server/h2_nghttp2.zig) had the same rule. The diff
   harness accepts it only when nghttp2's list is over the limit, our fields
   are a prefix of nghttp2's, and the tables agree after the block.
2. **The skip-mode cost cap.** While skipping, the literals (which copy their
   strings into the scratch and the table; nghttp2 shares them by refcount)
   may cost up to twice `max_list_size`; past it `skipRest()` returns
   `HeaderBlockTooCostly`, a connection error (ENHANCE_YOUR_CALM, RFC 9113
   §10.5). Without it a 2-byte literal with indexing on a 4 KiB dynamic name
   copies 4 KiB, about 2000x amplification. Skipped indexed references cost
   nothing and aren't counted.
3. **A field's strings larger than the scratch are a connection error**
   (`HeaderBlockTooCostly`, only in skip mode; emitting, it is
   `HeaderListTooLarge` first). The scratch is at least `max_list_size`
   bytes, so such a field is over the limit by itself; nghttp2 allocates
   whatever the string decodes to.
4. **The encoder never indexes and sends one size update to 0 first**
   (RFC 7541 §2.3.2, §4.2, §6.3). Its bytes differ from nghttp2's deflater,
   which indexes; the tests compare decoded lists, not bytes. The size update
   to 0 at the start of the connection's first block is what lets an
   nghttp2 peer that lowered SETTINGS_HEADER_TABLE_SIZE accept our blocks
   (it then requires a size update, nghttp2_hd.c
   `nghttp2_hd_inflate_change_table_size`), and after it no SETTINGS can be
   below our table's maximum again.

The decoder's other differences are API shape, not behaviour: it takes one
complete block instead of nghttp2's incremental input, so a block that ends
inside a representation is the same COMPRESSION_ERROR nghttp2 gives at
`in_final`.

## Connection limits (conn.zig)

PLAN §5.4 and D15 (research/s2/h2-m2/connlimits.md). nghttp2 references are
v1.70.0's lib/nghttp2_session.c (the fork, 0f8bc1c).

1. **The reset budget is charged only for streams not answered, and for the
   resets we send because of the peer's errors** (D15 point 1). A peer's
   RST_STREAM on a stream whose END_STREAM we had queued (`answered`), or on
   one already closed, costs nothing; every RST_STREAM we queue answering a
   peer error (STREAM_CLOSED, a stream window overflow, a broken
   content-length or head, a PRIORITY self-dependency) is charged, answered
   or not (MadeYouReset, CVE-2025-8671). nghttp2's
   `session_update_stream_reset_ratelim` (:4186) charges every received
   RST_STREAM and charges the provoked ones to its glitch budget instead
   (:3747, :3884, :5130).
2. **The rapid-reset answer is GOAWAY ENHANCE_YOUR_CALM and the connection
   ends** (PLAN §5.4). nghttp2 queues a graceful GOAWAY INTERNAL_ERROR
   (:4196) and goes on reading.
3. **Empty frames and unknown or extension frames have their own budget**
   (`Limits.empty_frame_rate`, 100 tokens refilled at 100/s; D15 point 2):
   DATA with an empty payload and no END_STREAM, HEADERS with an empty
   fragment and no END_STREAM (END_HEADERS or not), an empty CONTINUATION
   without END_HEADERS, and every frame of an unknown type but
   PRIORITY_UPDATE (9). nghttp2 charges these to its one glitch budget
   (10000, 330/s: :5721, :6930, :6025), which conn.zig keeps
   (`glitch_burst/rate`) for blocks decoded only for the table; the D15
   point 5 calibration kept both buckets (9). An empty HEADERS or
   CONTINUATION isn't a glitch in nghttp2.
4. **The control-frame budget counts our RST_STREAMs too, sends a GOAWAY when
   spent, and is released as the writer writes.** PLAN §5.4 counts queued
   PING ACK + SETTINGS ACK + RST_STREAM against 1000; nghttp2's
   `max_outbound_ack` counts only the two ACKs (nghttp2.h's
   `nghttp2_option_set_max_outbound_ack`; :7343, :7493), releases each when
   it is packed (:2244, :2302), and returns NGHTTP2_ERR_FLOODED with no
   GOAWAY. Here the count is released an epoch at a time as `advance` passes
   the answers (Go's queuedControlFrames releases per frame), so under a
   standing backlog it stays within one epoch of what is really unwritten. Too many CONTINUATIONs
   (`max_continuations`) is likewise GOAWAY ENHANCE_YOUR_CALM where nghttp2
   returns NGHTTP2_ERR_TOO_MANY_CONTINUATIONS (:6831) with no GOAWAY.
5. **A header block over `max_header_list_size` bytes on the wire is a
   connection error (ENHANCE_YOUR_CALM) before it is decoded.** The block is
   decoded whole (hpack.zig), so this bounds its assembly buffer; nghttp2
   inflates as the bytes arrive and has no such cap. A legitimate block is
   smaller than its decoded list (each field costs at least 32), so no
   request the list limit accepts is refused. Go closes the connection in
   the same case (golang/go#65051).
6. **A request head past `max_header_list_size` (decoded) or
   `max_header_count` regular fields (a cookie's crumbs once, pseudo-headers
   not counted) is answered 431 with END_STREAM, then RST_STREAM(NO_ERROR)
   if the request was still open**, and charged to the refused budget; the
   rest of the block is decoded for the table. Trailers past a limit reset
   the stream with INTERNAL_ERROR. nghttp2 has no field count or list limit
   of its own; today's engine resets the stream with INTERNAL_ERROR for the
   list size (h2_nghttp2.zig `onHeader`) and answers 431 for the count from
   the request layer. The diff harness's nghttp2 callback has to apply the
   same limits.
7. **A request past `max_concurrent_streams` is REFUSED_STREAM, also once our
   SETTINGS are acknowledged**, charged to the refused budget
   (`refused_stream_burst/rate`; GOAWAY ENHANCE_YOUR_CALM when spent).
   nghttp2 makes it a connection PROTOCOL_ERROR past the acknowledged value
   (:3998) and refuses only past one not yet acknowledged (:4014). RFC 9113
   §5.1.2 allows either; a refused stream is safe for the client to retry.
8. **New streams are refused while more than `Limits.out_high` owned bytes
   (HEADERS, control frames, DATA frame headers) wait to be written** (a peer that stops reading, CVE-2019-9517; h2o's
   OUTBUF_SOFT_MAX_SIZE), with the same refused budget. nghttp2 has no such
   rule. Credit, SETTINGS, PING, RST_STREAM and DATA on open streams are
   still processed; the write timeout that ends such a connection is M3's.
   Borrowed DATA isn't counted: it is framed only at `pending`, so a peer
   that reads normally while one large frame is being written (a 16 MiB
   SETTINGS_MAX_FRAME_SIZE, or many iovecs) is never refused.
9. **PRIORITY and PRIORITY_UPDATE are validated and charged to no budget**
   (rule `priority_update` for the second). The D15 point 5 calibration
   (bench/results/20261111-h2-limits-calibration/README.md, "Findings that
   change something" and "Budget by budget") measured Chromium sending
   about one PRIORITY per subresource (117 on one page load, 956/s and 1354
   on one connection on reloads), above the glitch budget's 330/s; Conn has
   no priority tree, so a PRIORITY frame holds no state and queues no output
   (CVE-2019-9513 was about the tree). nghttp2 charges every PRIORITY to its
   glitch budget (:5843). PRIORITY_UPDATE (type 0x10, RFC 9218 §7.1) is what
   RFC 9218 clients (Chromium, Firefox) send instead once they see our
   SETTINGS_NO_RFC7540_PRIORITIES = 1, at about the same rate, so it isn't
   counted as an unknown frame (3) either; it is checked and ignored:
   shorter than 4 bytes is FRAME_SIZE_ERROR, on a stream other than 0, for
   Prioritized Stream ID 0, or for a push stream (an even ID; we push
   nothing, so every one is idle) PROTOCOL_ERROR, all connection errors.
   nghttp2 with the extension on checks the length (:6192), the stream
   (:4982) and the idle push stream (:4987) the same way and charges the
   glitch budget (:6198); it ignores Prioritized Stream ID 0, which RFC 9218
   §7.1 makes a PROTOCOL_ERROR, and makes an idle request stream past
   SETTINGS_MAX_CONCURRENT_STREAMS a PROTOCOL_ERROR (:5004), which Conn,
   keeping no idle streams, doesn't check. Today's engine doesn't turn the
   extension on, so its nghttp2 takes type 0x10 as unknown: ignored, and
   charged to the glitch budget (:6161). The diff harness accepts Conn
   ending the connection with a `PRIORITY_UPDATE:` reason on a frame
   nghttp2 ignored, and nghttp2 running out of its glitch budget first (rule
   `empty_budget`).

## The session (conn.zig against an nghttp2 server session)

`conn_diff_test.zig` (PLAN §5.3) feeds the same client bytes to Conn and
to an nghttp2 server session set up as today's engine sets it up, and
compares the output; the limits entries above are its rules
`reset_budget` (1, 2), `empty_budget` (3), `continuations` (4),
`block_bytes` (5), `head_431` (6), `refused` (7, 8) and `priority_update`
(9), and HPACK 2 and 3
its `hpack_cost`. Both sides are drained after every frame, as if their
writers kept up: nghttp2 closes a stream once its last frame is written
(CLOSING until then, and judged by its earlier state), Conn once that frame
is queued, and Conn frames DATA only when drained, so otherwise either
side's answers would depend on when its writer ran.

1. **Frame sizes, scheduling and HPACK bytes.** Not compared: header blocks
   are decoded, DATA is concatenated per stream with END_STREAM's place,
   and neither the interleaving of DATA across streams nor its place among
   the control frames is compared (nghttp2 sends its urgent queue, then the
   regular one, then DATA by its scheduler; Conn queues in order and frames
   DATA at `pending`). The order of the responses is compared.
2. **WINDOW_UPDATE batching.** nghttp2 sends a WINDOW_UPDATE as soon as
   half the window is consumed, per DATA chunk, one queued at a time
   (nghttp2_helper.c `nghttp2_should_send_window_update`,
   `session_update_consumed_size`); Conn batches (`due`: half the window,
   or the window spent and some consumed, as python-hyper/h2 does). The
   totals per stream and for the connection are held to within half a
   window of nghttp2's, never above it by more, never below while the
   stream can still receive, and never an increment of 0. The same bound
   holds between Conn's output for one input whole and cut: its batching
   follows how the reads cut the DATA payloads.
3. **Output already queued when the connection ends is still sent**
   (rule `queued_output`). On a connection error nghttp2 drops what it had
   queued while handling the frame (`session_is_closing` in
   `nghttp2_session_prep_frame`'s predicates: the RST_STREAM before a
   COMPRESSION_ERROR's GOAWAY, a response queued in the same callback);
   Conn's `out` is a byte FIFO whose slices the writer may already hold
   (PLAN §3.3), so what it queued goes out before the GOAWAY. RFC 9113
   §5.4.1 asks only for the GOAWAY before the close. Accepted when both
   sent the same GOAWAY, every frame nghttp2 sent, Conn sent too, and
   Conn's others are only PING and SETTINGS ACKs, RST_STREAMs, and the
   handler's response on a stream nghttp2 sent nothing on.
4. **After the peer's GOAWAY, nghttp2 is done whenever no stream is open**
   (rule `peer_goaway`). Its `session_is_closing` is then true (want_read
   is 0 once GOAWAY was received and no stream is active, and want_write
   once its queue is empty): it answers no PING or SETTINGS
   (`nghttp2_session_on_ping_received`, `..._on_settings_received`), drops
   the last frame it pops, and the engine closes the connection
   (server/h2_nghttp2.zig, when neither wants to read or write). Conn
   leaves the close to the transport (M3) and goes on answering. The
   harness feeds nothing after the frame that leaves nghttp2 done (the
   engine reads no more), and accepts the batch when Conn sent no GOAWAY,
   every frame nghttp2 sent Conn sent too, and Conn's others are only
   what nghttp2 drops while closing: PING ACK, SETTINGS ACK, RST_STREAM.
5. **DATA is charged to the receive windows for the whole frame at its
   header** (rule `window_per_frame`). nghttp2 charges each chunk as it
   reads it (`nghttp2_session_update_recv_{connection,stream}_window_size`
   in NGHTTP2_IB_READ_DATA), so credit the handler gives back for a frame's
   first bytes makes room for the rest when the reads cut it finely, and a
   frame larger than the window is taken or refused depending on the cuts.
   RFC 9113 §6.9.1: the frame's length is what must fit. Conn's answer no
   longer depends on how the reads cut the frame (the differential's split
   invariance found it; conn_test.zig "a DATA frame past the window is a
   FLOW_CONTROL_ERROR however the reads cut it"). Accepted when Conn ends
   with FLOW_CONTROL_ERROR, nghttp2 doesn't, and the input was cut.

## The server engine (server.zig against server/h2_nghttp2.zig)

Not part of the differential tests: what the engine does differently from
the nghttp2 engine it replaces.

1. **A tunnel's window is never below `stream_window`.** An extended
   CONNECT (RFC 8441) reads at `Http2.tunnel_window`: the nghttp2 engine
   set its local window to that (`setTunnelWindow`), shrinking it when
   `tunnel_window` was the smaller. Conn has no way to shrink a window it
   has granted (a WINDOW_UPDATE only adds), so a smaller `tunnel_window` is
   left at `stream_window`; the only effect is the peer's pacing on that
   stream. Both defaults (128 KiB over 64 KiB) raise it.
2. **A tunnel's or a parked response's send cap counts blocks.** Their
   sends are copied into 16 KiB blocks, cut into DATA parts at each kick
   (at most 16 cuts a block); the cap (`max_pending`, 1 MiB for a
   WebSocket) counts a block closed for its cuts as full, so many tiny
   kicked sends wait sooner than on the nghttp2 engine's byte-counted
   outbox, and never hold more than about the cap in blocks. A message is
   still always taken when nothing is queued.
