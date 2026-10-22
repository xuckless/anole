//! libanole's symbol tool, run by `zig build capi` (no system binutils):
//!
//!   capi_symbols hide <in.o> <out.o> [<input.a|input.o> ...]
//!       Every defined global symbol of a relocatable object whose name does
//!       not start with `anole_` becomes hidden (ELF STV_HIDDEN, Mach-O
//!       private extern): the linker of a shared library or a Node/Python
//!       extension never exports it, so libanole's BoringSSL, nghttp2, zstd
//!       or zlib never bind to (or interpose on) the copies a host process
//!       carries. They stay global inside one link, so two static libraries
//!       defining the same name still clash there; hiding is what the
//!       formats offer in place, without rewriting relocations.
//!
//!       Mach-O only: the inputs the object was merged from (the static
//!       libraries and objects it links) give back the symbol flags that
//!       Zig's relocatable link (`zig build-obj` of several inputs) drops,
//!       N_ALT_ENTRY and N_NO_DEAD_STRIP. Without them a final link with
//!       -dead_strip (Apple's ld, and Zig's in release modes) cuts the
//!       merged object at every symbol: BoringSSL's assembly, whose
//!       functions call each other's alt entries with no relocation (one
//!       atom per file in the original), lost the pieces nothing pointed
//!       at, and the calls into them ran into other code (a crash in P-256
//!       key generation on the first TLS listener). A flag set on a symbol
//!       whose name merely matches is harmless: it only keeps code.
//!
//!       ELF only: the same link drops the inputs' empty .note.GNU-stack
//!       sections, without which GNU ld gives the final program or shared
//!       library an executable stack (and glibc 2.41 refuses to dlopen such
//!       a library, a Node or Python extension). The section is added back.
//!   capi_symbols check <file>
//!       Fails unless every symbol the file exports (an object's defined
//!       globals of default visibility; a shared library's dynamic symbols)
//!       is `anole_*`. Lists the exported `anole_*` names on success. An ELF
//!       object must also carry .note.GNU-stack.
//!
//! ELF64 little-endian and Mach-O 64 are read; COFF (Windows) exports only
//! what is marked dllexport, so it needs neither.
const std = @import("std");

const prefix = "anole_";

/// What linkers define in every shared library (the Mach-O header, the DSO
/// handle, ELF's section bounds): exported, but no code of ours.
const linker_symbols = [_][]const u8{ "_mh_dylib_header", "_dso_handle", "__dso_handle", "_init", "_fini", "_edata", "_end", "__bss_start" };

fn allowed(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, prefix)) return true;
    for (linker_symbols) |l| if (std.mem.eql(u8, name, l)) return true;
    return false;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return usage();
    const cmd = args[1];
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, args[2], arena, .unlimited);
    var out: std.Io.File.Writer = .init(.stdout(), io, &.{});
    if (std.mem.eql(u8, cmd, "hide")) {
        if (args.len < 4) return usage();
        const n = try hide(data);
        const noted = if (try formatOf(data) == .elf) try addGnuStack(arena, data) else null;
        var restored: usize = 0;
        if (args.len > 4 and try formatOf(data) == .macho) {
            var flags: std.StringHashMapUnmanaged(u16) = .empty;
            for (args[4..]) |path| try collectFlags(arena, try cwd.readFileAlloc(io, path, arena, .unlimited), &flags);
            restored = try restoreFlags(data, &flags);
        }
        const result = noted orelse data;
        // Padded to 8 bytes: Zig's archiver does not pad the last member of
        // an archive, and Apple's ld and ranlib call an odd-sized last
        // member "malformed". Trailing zeros are harmless in an object.
        const padded = try arena.alloc(u8, std.mem.alignForward(usize, result.len, 8));
        @memcpy(padded[0..result.len], result);
        @memset(padded[result.len..], 0);
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = padded });
        try out.interface.print("capi_symbols: {d} symbols hidden, {d} Mach-O symbol flags restored\n", .{ n, restored });
    } else if (std.mem.eql(u8, cmd, "check")) {
        var names: std.ArrayList([]const u8) = .empty;
        var bad: std.ArrayList([]const u8) = .empty;
        try exported(arena, data, &names);
        if (try formatOf(data) == .elf and rd(u16, data, 0x10) == 1 and elfSection(data, gnu_stack) == null) {
            std.log.err("{s}: no .note.GNU-stack section (GNU ld would make the stack executable)", .{args[2]});
            std.process.exit(1);
        }
        var ours: usize = 0;
        for (names.items) |n| {
            if (!allowed(n)) try bad.append(arena, n);
            if (std.mem.startsWith(u8, n, prefix)) ours += 1;
        }
        if (bad.items.len > 0) {
            for (bad.items[0..@min(bad.items.len, 50)]) |n| std.log.err("exported, not anole_*: {s}", .{n});
            std.log.err("{d} symbols exported that are not anole_* ({s})", .{ bad.items.len, args[2] });
            std.process.exit(1);
        }
        if (ours == 0) {
            std.log.err("no anole_* symbol exported from {s}", .{args[2]});
            std.process.exit(1);
        }
        try out.interface.print("capi_symbols: {d} anole_* symbols exported, nothing else\n", .{ours});
    } else return usage();
}

fn usage() error{Usage} {
    std.log.err("usage: capi_symbols hide <in.o> <out.o> [<input.a|input.o> ...] | check <file>", .{});
    return error.Usage;
}

const Format = enum { elf, macho };

fn formatOf(data: []const u8) !Format {
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "\x7fELF")) {
        if (data[4] != 2 or data[5] != 1) return error.UnsupportedElf; // 64-bit LE only
        return .elf;
    }
    if (data.len >= 4 and std.mem.readInt(u32, data[0..4], .little) == 0xfeedfacf) return .macho;
    return error.UnknownFormat;
}

fn rd(comptime T: type, data: []const u8, off: usize) T {
    return std.mem.readInt(T, data[off..][0..@sizeOf(T)], .little);
}

fn cstr(data: []const u8, off: usize) []const u8 {
    const rest = data[off..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse rest.len];
}

// ---- ELF ------------------------------------------------------------------------

const SHT_SYMTAB = 2;
const SHT_DYNSYM = 11;
const STB_GLOBAL = 1;
const STB_WEAK = 2;
const STV_DEFAULT = 0;
const STV_HIDDEN = 2;

const ElfTable = struct { off: usize, count: usize, strtab: usize };

fn elfTable(data: []const u8, want: u32) ?ElfTable {
    const shoff: usize = @intCast(rd(u64, data, 0x28));
    const shentsize = rd(u16, data, 0x3a);
    const shnum = rd(u16, data, 0x3c);
    for (0..shnum) |i| {
        const sh = shoff + i * shentsize;
        if (rd(u32, data, sh + 4) != want) continue;
        const off: usize = @intCast(rd(u64, data, sh + 0x18));
        const size: usize = @intCast(rd(u64, data, sh + 0x20));
        const link = rd(u32, data, sh + 0x28);
        const str_sh = shoff + @as(usize, link) * shentsize;
        return .{ .off = off, .count = size / 24, .strtab = @intCast(rd(u64, data, str_sh + 0x18)) };
    }
    return null;
}

/// Each defined global or weak symbol: its name and the offset of its
/// entry.
fn elfDefined(data: []const u8, t: ElfTable, f: anytype) !void {
    for (1..t.count) |i| {
        const e = t.off + i * 24;
        const info = data[e + 4];
        const bind = info >> 4;
        const shndx = rd(u16, data, e + 6);
        if (bind != STB_GLOBAL and bind != STB_WEAK) continue;
        if (shndx == 0) continue; // undefined
        try f.each(cstr(data, t.strtab + rd(u32, data, e)), e);
    }
}

const gnu_stack = ".note.GNU-stack";

/// The index of the section with this name, or null.
fn elfSection(data: []const u8, name: []const u8) ?usize {
    const shoff: usize = @intCast(rd(u64, data, 0x28));
    const shentsize = rd(u16, data, 0x3a);
    const shnum = rd(u16, data, 0x3c);
    const strtab: usize = @intCast(rd(u64, data, shoff + @as(usize, rd(u16, data, 0x3e)) * shentsize + 0x18));
    for (0..shnum) |i| {
        if (std.mem.eql(u8, cstr(data, strtab + rd(u32, data, shoff + i * shentsize)), name)) return i;
    }
    return null;
}

/// A copy of a relocatable object with an empty .note.GNU-stack section
/// added (null when it has one): the section-name table is copied to the
/// end with the name appended, then the section headers with one more, so
/// every existing section keeps its index (symbols and relocations name
/// sections by index).
fn addGnuStack(arena: std.mem.Allocator, data: []const u8) !?[]u8 {
    if (elfSection(data, gnu_stack) != null) return null;
    const shoff: usize = @intCast(rd(u64, data, 0x28));
    const shentsize: usize = rd(u16, data, 0x3a);
    const shnum: usize = rd(u16, data, 0x3c);
    const shstrndx: usize = rd(u16, data, 0x3e);
    if (shentsize != 64 or shnum == 0 or shnum >= 0xff00) return error.UnsupportedElf;
    const str_sh = shoff + shstrndx * shentsize;
    const str_off: usize = @intCast(rd(u64, data, str_sh + 0x18));
    const str_size: usize = @intCast(rd(u64, data, str_sh + 0x20));

    const new_str_off = data.len;
    const new_str_size = str_size + gnu_stack.len + 1;
    const new_shoff = std.mem.alignForward(usize, new_str_off + new_str_size, 8);
    const out = try arena.alloc(u8, new_shoff + (shnum + 1) * shentsize);
    @memset(out, 0);
    @memcpy(out[0..data.len], data);
    @memcpy(out[new_str_off..][0..str_size], data[str_off..][0..str_size]);
    @memcpy(out[new_str_off + str_size ..][0..gnu_stack.len], gnu_stack);
    @memcpy(out[new_shoff..][0 .. shnum * shentsize], data[shoff..][0 .. shnum * shentsize]);
    const wr = struct {
        fn u64_(buf: []u8, off: usize, v: usize) void {
            std.mem.writeInt(u64, buf[off..][0..8], @intCast(v), .little);
        }
    };
    // The name table, moved.
    wr.u64_(out, new_shoff + shstrndx * shentsize + 0x18, new_str_off);
    wr.u64_(out, new_shoff + shstrndx * shentsize + 0x20, new_str_size);
    // The new section: SHT_PROGBITS, no flags (not executable), empty.
    const sh = new_shoff + shnum * shentsize;
    std.mem.writeInt(u32, out[sh..][0..4], @intCast(str_size), .little);
    std.mem.writeInt(u32, out[sh + 4 ..][0..4], 1, .little);
    wr.u64_(out, sh + 0x18, new_str_off);
    wr.u64_(out, sh + 0x30, 1);
    // The header.
    wr.u64_(out, 0x28, new_shoff);
    std.mem.writeInt(u16, out[0x3c..][0..2], @intCast(shnum + 1), .little);
    return out;
}

// ---- Mach-O ------------------------------------------------------------------------

const LC_SYMTAB = 0x2;
const N_EXT = 0x01;
const N_PEXT = 0x10;
const N_TYPE = 0x0e;
const N_SECT = 0x0e;
const N_ABS = 0x02;
const N_STAB = 0xe0;

const MachoTable = struct { off: usize, count: usize, strtab: usize };

fn machoTable(data: []const u8) !MachoTable {
    const ncmds = rd(u32, data, 16);
    var lc: usize = 32;
    for (0..ncmds) |_| {
        const cmd = rd(u32, data, lc);
        const size = rd(u32, data, lc + 4);
        if (cmd == LC_SYMTAB) return .{
            .off = rd(u32, data, lc + 8),
            .count = rd(u32, data, lc + 12),
            .strtab = rd(u32, data, lc + 16),
        };
        lc += size;
    }
    return error.NoSymbolTable;
}

/// Each defined external symbol, without the leading underscore.
fn machoDefined(data: []const u8, t: MachoTable, f: anytype) !void {
    for (0..t.count) |i| {
        const e = t.off + i * 16;
        const typ = data[e + 4];
        if (typ & N_STAB != 0 or typ & N_EXT == 0) continue;
        const kind = typ & N_TYPE;
        if (kind != N_SECT and kind != N_ABS) continue;
        const raw = cstr(data, t.strtab + rd(u32, data, e));
        try f.each(if (raw.len > 0 and raw[0] == '_') raw[1..] else raw, e);
    }
}

// ---- Mach-O symbol flags lost in a relocatable link ----------------------------------

const N_NO_DEAD_STRIP: u16 = 0x0020;
const N_ALT_ENTRY: u16 = 0x0200;
const kept_flags = N_NO_DEAD_STRIP | N_ALT_ENTRY;
const LC_SEGMENT_64 = 0x19;

/// The flags of every defined symbol of a Mach-O object, or of each Mach-O
/// member of an archive, by name (flags of equal names are joined).
fn collectFlags(arena: std.mem.Allocator, data: []const u8, flags: *std.StringHashMapUnmanaged(u16)) !void {
    if (std.mem.startsWith(u8, data, "!<arch>\n")) {
        var off: usize = 8;
        while (off + 60 <= data.len) {
            const name = data[off..][0..16];
            const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, data[off + 48 ..][0..10], " "), 10) catch return error.BadArchive;
            var body = off + 60;
            var len = size;
            // BSD long names: "#1/<n>", the name's n bytes before the data.
            if (std.mem.startsWith(u8, name, "#1/")) {
                const n = std.fmt.parseInt(usize, std.mem.trimEnd(u8, name[3..], " "), 10) catch return error.BadArchive;
                body += n;
                len -|= n;
            }
            if (body + len > data.len) return error.BadArchive;
            try collectObject(arena, data[body..][0..len], flags);
            off = std.mem.alignForward(usize, off + 60 + size, 2);
        }
        return;
    }
    try collectObject(arena, data, flags);
}

fn collectObject(arena: std.mem.Allocator, data: []const u8, flags: *std.StringHashMapUnmanaged(u16)) !void {
    if (data.len < 32 or rd(u32, data, 0) != 0xfeedfacf) return; // not Mach-O 64 (a symbol index, ...)
    const t = machoTable(data) catch return; // no symbols (an empty assembly file)
    for (0..t.count) |i| {
        const e = t.off + i * 16;
        const typ = data[e + 4];
        if (typ & N_STAB != 0 or typ & N_TYPE != N_SECT) continue;
        const desc = rd(u16, data, e + 6) & kept_flags;
        if (desc == 0) continue;
        const gop = try flags.getOrPut(arena, cstr(data, t.strtab + rd(u32, data, e)));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* |= desc;
    }
}

/// Sets the collected flags on the object's symbols of the same names. An
/// alt entry is never put at the start of its section (nothing to join).
fn restoreFlags(data: []u8, flags: *const std.StringHashMapUnmanaged(u16)) !usize {
    var starts: [256]u64 = @splat(0);
    {
        const ncmds = rd(u32, data, 16);
        var lc: usize = 32;
        var sect: usize = 1;
        for (0..ncmds) |_| {
            const cmd = rd(u32, data, lc);
            if (cmd == LC_SEGMENT_64) {
                const nsects = rd(u32, data, lc + 64);
                for (0..nsects) |j| {
                    if (sect < starts.len) starts[sect] = rd(u64, data, lc + 72 + j * 80 + 32);
                    sect += 1;
                }
            }
            lc += rd(u32, data, lc + 4);
        }
    }
    const t = try machoTable(data);
    var n: usize = 0;
    for (0..t.count) |i| {
        const e = t.off + i * 16;
        const typ = data[e + 4];
        if (typ & N_STAB != 0 or typ & N_TYPE != N_SECT) continue;
        var want = flags.get(cstr(data, t.strtab + rd(u32, data, e))) orelse continue;
        const sect = data[e + 5];
        if (want & N_ALT_ENTRY != 0 and rd(u64, data, e + 8) == starts[sect]) want &= ~N_ALT_ENTRY;
        const desc = rd(u16, data, e + 6);
        if (desc | want == desc) continue;
        std.mem.writeInt(u16, data[e + 6 ..][0..2], desc | want, .little);
        n += 1;
    }
    return n;
}

// ---- hide and check ------------------------------------------------------------------

fn hide(data: []u8) !usize {
    const Hider = struct {
        data: []u8,
        format: Format,
        n: usize = 0,
        fn each(h: *@This(), name: []const u8, e: usize) !void {
            if (std.mem.startsWith(u8, name, prefix)) return;
            switch (h.format) {
                .elf => h.data[e + 5] = (h.data[e + 5] & ~@as(u8, 3)) | STV_HIDDEN,
                .macho => h.data[e + 4] |= N_PEXT,
            }
            h.n += 1;
        }
    };
    const format = try formatOf(data);
    var h: Hider = .{ .data = data, .format = format };
    switch (format) {
        .elf => {
            if (rd(u16, data, 0x10) != 1) return error.NotRelocatable; // ET_REL
            try elfDefined(data, elfTable(data, SHT_SYMTAB) orelse return error.NoSymbolTable, &h);
        },
        .macho => {
            if (rd(u32, data, 12) != 1) return error.NotRelocatable; // MH_OBJECT
            try machoDefined(data, try machoTable(data), &h);
        },
    }
    return h.n;
}

fn exported(arena: std.mem.Allocator, data: []const u8, names: *std.ArrayList([]const u8)) !void {
    const Lister = struct {
        arena: std.mem.Allocator,
        data: []const u8,
        format: Format,
        names: *std.ArrayList([]const u8),
        fn each(l: *@This(), name: []const u8, e: usize) !void {
            const visible = switch (l.format) {
                .elf => l.data[e + 5] & 3 == STV_DEFAULT,
                .macho => l.data[e + 4] & N_PEXT == 0,
            };
            if (visible) try l.names.append(l.arena, name);
        }
    };
    const format = try formatOf(data);
    var l: Lister = .{ .arena = arena, .data = data, .format = format, .names = names };
    switch (format) {
        .elf => {
            // A shared library exports its dynamic symbols; an object what
            // its symbol table holds.
            const t = elfTable(data, SHT_DYNSYM) orelse elfTable(data, SHT_SYMTAB) orelse return error.NoSymbolTable;
            try elfDefined(data, t, &l);
        },
        .macho => try machoDefined(data, try machoTable(data), &l),
    }
}
