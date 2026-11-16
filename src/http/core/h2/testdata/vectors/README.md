# HTTP/2 golden vectors

What nghttp2 1.70.0 (xuckless/nghttp2, `anole` branch) answered to the inputs
of the HTTP/2 differential tests, recorded once while it was still linked, so
that the tests compare against it without the library (M6 of
research/h2h3-takeover/PLAN.md removed nghttp2 from the build).

The tests replay them: `h2/conn_diff_test.zig`, `h2/hpack_diff_test.zig` and
`h2/fields_test.zig`. The reader and the format are `h2/vectors.zig`
(little-endian; u32 counts and lengths, LEB128 where noted; a damaged file is
`error.Truncated`, never a panic).

| file | test | what is recorded |
| --- | --- | --- |
| `conn_corpus.bin` | nghttp2's fuzz corpus (`../h2_sessions.bin`, 136 client streams) | per profile and input: the runs (whole, then two on random cuts), each run's cut list, and per feed nghttp2's raw output bytes, its mem_recv2 error, want_read and last processed stream |
| `conn_seeds.bin` | the `fuzz: h2 conn recv` seeds | the same, for the 8 seeds |
| `conn_generated.bin` | generated sessions | the same, with the input inline: 200 per profile picked from the 2500 of the original test, covering every rule the comparison excuses and every outcome (open, GOAWAY, fatal) |
| `conn_plant.bin` | "the harness catches a planted divergence" | the unplanted runs of its three hand-built inputs |
| `hpack_vectors.bin` | RFC 7541 Appendix C and nghttp2's test blocks | per connection and block: whether nghttp2's inflater decoded it, the list size and the running CRC-32 of what it emitted, its dynamic table (entries, size, maximum, CRC-32 of the entries) |
| `hpack_corpus.bin` | `../hpack_blocks.bin` (real blocks from the fuzz corpus) | the same, at both decoded-list limits |
| `hpack_generated.bin` | generated blocks, half made by nghttp2's deflater | the same, blocks inline: three connections of 100 blocks |
| `encoder.bin` | our encoder through nghttp2's inflater | 40 field lists, the bytes our encoder produced under each of three table-size settings (default, 0, 1024), which nghttp2's inflater accepted, and which fields it decoded as never-indexed |
| `fields.bin` | `nghttp2_check_*` against `fields.zig` | one byte per string of the test's enumeration (every string of up to two bytes, then 20000 from a fixed xorshift stream): bit 0 name, 1 value, 2 value RFC 9113, 3 method, 4 path, 5 authority |

Intentional divergences (`../INTENTIONAL.md`) keep their documented outcome:
the replay classifies each difference between Conn and the recorded output
with the same rules and counts them, and an unexplained one fails.

## What changed with the recording

- The generated inputs are a frozen subset (about 400 sessions, 300 blocks)
  of what ran live before (5000 and 5000). The rest of the live generator
  still runs, against Conn alone (split invariance), where most of its value
  was.
- "Our encoder through nghttp2's inflater" asked a question about bytes not
  yet produced, so it cannot be replayed: `encoder.bin` keeps nghttp2's
  verdict on 40 lists under three settings, and the test checks that our
  encoder still produces these bytes and our decoder reads them back.

## Re-recording

Only possible with nghttp2 linked: commit 1012aa39 ("h2 tests: record
nghttp2's outputs as golden vectors") is the last one in which the diff
tests still ran live and `H2_RECORD=<absolute directory>` made them write
these files (the test binary runs in `.zig-cache`, so the directory must be
absolute; run the built `core-test` directly if `zig build` does not pass
the variable on). The nghttp2 server session the sessions were run against
(`Ng` there: no automatic WINDOW_UPDATE, credit given back as DATA arrives,
the header-list limit in the header callback, 200 and "ok" for every
request) and the generators of the blocks and sessions are in that commit
too. To extend the vectors, check it out.
