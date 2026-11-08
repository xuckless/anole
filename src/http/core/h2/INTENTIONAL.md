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
