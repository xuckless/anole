//! libanole's symbol tool, run by `zig build capi` (no system binutils):
//!
//!   capi_symbols hide <in.o> <out.o>
//!       Every defined global symbol of a relocatable object whose name does
//!       not start with `anole_` becomes hidden (ELF STV_HIDDEN, Mach-O
//!       private extern): the linker of a shared library or a Node/Python
//!       extension never exports it, so libanole's BoringSSL, nghttp2, zstd
//!       or zlib never bind to (or interpose on) the copies a host process
//!       carries. They stay global inside one link, so two static libraries
//!       defining the same name still clash there; hiding is what the
//!       formats offer in place, without rewriting relocations.
//!   capi_symbols check <file>
//!       Fails unless every symbol the file exports (an object's defined
//!       globals of default visibility; a shared library's dynamic symbols)
//!       is `anole_*`. Lists the exported `anole_*` names on success.
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
        if (args.len != 4) return usage();
        const n = try hide(data);
        // Padded to 8 bytes: Zig's archiver does not pad the last member of
        // an archive, and Apple's ld and ranlib call an odd-sized last
        // member "malformed". Trailing zeros are harmless in an object.
        const padded = try arena.alloc(u8, std.mem.alignForward(usize, data.len, 8));
        @memcpy(padded[0..data.len], data);
        @memset(padded[data.len..], 0);
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = padded });
        try out.interface.print("capi_symbols: {d} symbols hidden\n", .{n});
    } else if (std.mem.eql(u8, cmd, "check")) {
        var names: std.ArrayList([]const u8) = .empty;
        var bad: std.ArrayList([]const u8) = .empty;
        try exported(arena, data, &names);
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
    std.log.err("usage: capi_symbols hide <in.o> <out.o> | check <file>", .{});
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
