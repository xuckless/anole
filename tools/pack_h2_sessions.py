#!/usr/bin/env python3
"""Writes src/http/core/h2/testdata/h2_sessions.bin, whole client byte
streams for the 'h2 conn diff:' tests, from nghttp2's fuzz corpus.

    tools/pack_h2_sessions.py <nghttp2>/fuzz/corpus

The pinned source is xuckless/nghttp2 0f8bc1c (v1.70.0 + the RFC 9113
patch; MIT, see LICENSE.nghttp2). Its fuzz/corpus/h2spec and
fuzz/corpus/nghttp files are client streams recorded against nghttpd
(fuzz/README.rst): the preface, then frames, taken as they are.

Format, little endian, as hpack_blocks.bin: u32 file count; per file a u32
length and the bytes. Files are taken in sorted order of
"<directory>/<name>".
"""
import os
import struct
import sys

OUT = os.path.join(os.path.dirname(__file__), "..", "src", "http", "core", "h2", "testdata", "h2_sessions.bin")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = sys.argv[1]
    names = sorted(
        f"{d}/{n}"
        for d in ("h2spec", "nghttp")
        for n in os.listdir(os.path.join(root, d))
    )
    out = bytearray(struct.pack("<I", len(names)))
    for name in names:
        with open(os.path.join(root, name), "rb") as f:
            data = f.read()
        out += struct.pack("<I", len(data)) + data
    with open(OUT, "wb") as f:
        f.write(out)
    print(f"{len(names)} sessions, {len(out)} bytes -> {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
