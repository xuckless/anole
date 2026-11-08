#!/usr/bin/env python3
"""Writes src/http/core/h2/testdata/hpack_blocks.bin, real HPACK header
blocks for the 'h2 hpack diff:' tests, from nghttp2's fuzz corpus (client
byte streams: the preface, then frames).

    tools/extract_hpack_blocks.py <nghttp2>/fuzz/corpus

The pinned source is xuckless/nghttp2 0f8bc1c (v1.70.0 + the RFC 9113
patch). Each corpus file is one connection: its HEADERS and PUSH_PROMISE
fragments, with CONTINUATIONs appended up to END_HEADERS, padding and
priority stripped, are the connection's blocks in order, so the test
decodes them on one decoder as the server would. A block left unfinished
(EOF, or another frame before END_HEADERS) is dropped and the file ends
there. The walker trusts nothing: a frame past EOF ends the file.

Format, little endian: u32 connection count; per connection a u32 block
count; per block a u32 length and the bytes. Files are taken in sorted
order and connections without blocks are left out.
"""
import os
import struct
import sys

OUT = os.path.join(os.path.dirname(__file__), "..", "src", "http", "core", "h2", "testdata", "hpack_blocks.bin")
PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
HEADERS, PUSH_PROMISE, CONTINUATION = 0x1, 0x5, 0x9
END_HEADERS, PADDED, PRIORITY = 0x4, 0x8, 0x20


def fragment(ftype, flags, payload):
    """The header block fragment of a HEADERS or PUSH_PROMISE payload, or None."""
    p = payload
    pad = 0
    if flags & PADDED:
        if not p:
            return None
        pad, p = p[0], p[1:]
    if ftype == HEADERS and flags & PRIORITY:
        p = p[5:]
    if ftype == PUSH_PROMISE:
        p = p[4:]
    if pad > len(p):
        return None
    return p[: len(p) - pad]


def blocks(data):
    if data.startswith(PREFACE):
        data = data[len(PREFACE):]
    out = []
    cur = None
    i = 0
    while i + 9 <= len(data):
        length = int.from_bytes(data[i:i + 3], "big")
        ftype, flags = data[i + 3], data[i + 4]
        payload = data[i + 9:i + 9 + length]
        if len(payload) < length:
            break
        i += 9 + length
        if cur is not None:
            if ftype != CONTINUATION:
                break
            cur += payload
        elif ftype in (HEADERS, PUSH_PROMISE):
            frag = fragment(ftype, flags, payload)
            if frag is None:
                break
            cur = bytearray(frag)
        else:
            continue
        if flags & END_HEADERS:
            out.append(bytes(cur))
            cur = None
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = sys.argv[1]
    conns = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            with open(os.path.join(dirpath, name), "rb") as f:
                b = blocks(f.read())
            if b:
                conns.append(b)
    out = bytearray(struct.pack("<I", len(conns)))
    for b in conns:
        out += struct.pack("<I", len(b))
        for blk in b:
            out += struct.pack("<I", len(blk)) + blk
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(out)
    print(f"{len(conns)} connections, {sum(len(b) for b in conns)} blocks, {len(out)} bytes -> {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
