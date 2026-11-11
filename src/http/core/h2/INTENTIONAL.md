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
   fragment and neither END_STREAM nor END_HEADERS, an empty CONTINUATION
   without END_HEADERS, and every frame of an unknown type. nghttp2 charges
   these to its one glitch budget (10000, 330/s: :5721, :6930, :6025), which
   conn.zig keeps for PRIORITY and blocks decoded only for the table until
   the D15 point 5 calibration picks one. An empty HEADERS or CONTINUATION
   isn't a glitch in nghttp2.
4. **The control-frame budget counts our RST_STREAMs too, sends a GOAWAY when
   spent, and is released as the writer writes.** PLAN §5.4 counts queued
   PING ACK + SETTINGS ACK + RST_STREAM against 1000; nghttp2's
   `max_outbound_ack` counts only the two ACKs (nghttp2.h's
   `nghttp2_option_set_max_outbound_ack`; :7343, :7493), releases each when
   it is packed (:2244, :2302), and returns NGHTTP2_ERR_FLOODED with no
   GOAWAY. Here the count empties once `advance` passes the last answer
   queued (Go's queuedControlFrames). Too many CONTINUATIONs
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
8. **New streams are refused while more than `Limits.out_high` bytes wait to
   be written** (a peer that stops reading, CVE-2019-9517; h2o's
   OUTBUF_SOFT_MAX_SIZE), with the same refused budget. nghttp2 has no such
   rule. Credit, SETTINGS, PING, RST_STREAM and DATA on open streams are
   still processed; the write timeout that ends such a connection is M3's.
