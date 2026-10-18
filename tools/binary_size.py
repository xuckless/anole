#!/usr/bin/env python3
"""Loaded size of an x86_64/aarch64 ELF binary, and how much of it is libc++,
libc++abi and libunwind (pulled in by BoringSSL), from the symbol table.

    zig build full -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast [-Dprofile=...]
    tools/binary_size.py zig-out/bin/full
"""
import struct, sys, re
def analyze(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'\x7fELF' and d[4] == 2
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3A)
    secs = []
    for i in range(shnum):
        name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize)
        secs.append((name, typ, flags, off, size, link, entsize))
    alloc = sum(s[4] for s in secs if s[2] & 2 and s[1] != 8)  # SHF_ALLOC, not NOBITS
    syms = {}
    for s in secs:
        if s[1] == 2:  # SYMTAB
            strtab = secs[s[5]]
            for j in range(s[4] // 24):
                nm, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', d, s[3] + j * 24)
                if size == 0 or info & 0xf not in (1, 2):
                    continue
                o = strtab[3] + nm
                name = d[o:d.index(b'\0', o)].decode('latin1')
                syms[(name, value)] = size
    cxx = re.compile(r'^(_ZN?K?St3__1|_ZNSt|_ZNKSt|_ZT[IVS]|_ZN10__cxxabiv1|__cxa_|_Unwind_|__gxx_personality|_Znw|_Zna|_Zdl|_Zda|_ZSt|__cxx|_ZN6__llvm|unw_|__unw_|__libunwind)')
    total = sum(syms.values())
    c = sum(v for (n, _), v in syms.items() if cxx.match(n))
    return alloc, total, c


def main():
    for p in sys.argv[1:]:
        a, t, c = analyze(p)
        print(f"{p}: loaded {a/1e6:.2f} MB, symbols {t/1e6:.2f} MB, libc++/abi/unwind {c/1e3:.0f} kB")


if __name__ == "__main__":
    main()
