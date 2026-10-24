//! `include/anole.abi.json`: every record, constant, event and handle kind
//! of the C ABI as one JSON document, generated from `src/capi/abi.zig`
//! (the single source) so that anole-node and anole-py generate their
//! parsers from it instead of writing a layout or a constant by hand.
//!
//!   capi_abi_json <out.json>             writes the document
//!   capi_abi_json --check <committed>    exits 1 unless <committed> is what
//!                                        would be written (`zig build capi-abi-json`
//!                                        updates include/anole.abi.json)
//!
//! `constants(abi)` is also imported by `src/capi/abi_test.zig`, which
//! compares it with the constants `anole.h` declares.
const std = @import("std");
const abi = @import("capi_abi");

/// One integer constant of the ABI.
pub const Constant = struct {
    name: []const u8,
    value: i64,
    group: []const u8,
};

fn isConstantName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| if (!(std.ascii.isUpper(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

fn upper(comptime s: []const u8) []const u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        for (s, &out) |ch, *o| o.* = std.ascii.toUpper(ch);
        const final = out;
        return &final;
    }
}

fn groupOf(comptime name: []const u8) []const u8 {
    comptime {
        var best: ?abi.ConstantGroup = null;
        for (abi.constant_groups) |g| {
            if (std.mem.startsWith(u8, name, g.prefix) and (best == null or g.prefix.len > best.?.prefix.len)) best = g;
        }
        if (best) |b| return b.group;
        @compileError("constant " ++ name ++ " matches no group in abi.constant_groups: name its prefix there");
    }
}

/// Every constant of `abi_mod` (a module with the layout of abi.zig): its
/// integer declarations named in capitals, the event types and the
/// database error classes, in declaration order.
pub fn constants(comptime abi_mod: type) []const Constant {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var list: []const Constant = &.{};
        for (@typeInfo(abi_mod).@"struct".decl_names) |decl| {
            if (!isConstantName(decl)) continue;
            const v = @field(abi_mod, decl);
            switch (@typeInfo(@TypeOf(v))) {
                .int, .comptime_int => {},
                else => continue,
            }
            const name = "ANOLE_" ++ decl;
            list = list ++ &[_]Constant{.{ .name = name, .value = @intCast(v), .group = groupOf(name) }};
        }
        const ev = @typeInfo(abi_mod.EventType).@"enum";
        for (ev.field_names, ev.field_values) |n, v| {
            const name = "ANOLE_EV_" ++ upper(n);
            list = list ++ &[_]Constant{.{ .name = name, .value = v, .group = groupOf(name) }};
        }
        const dc = @typeInfo(abi_mod.DbErrorClass).@"enum";
        for (dc.field_names, dc.field_values) |n, v| {
            const name = "ANOLE_DB_ERR_" ++ upper(n);
            list = list ++ &[_]Constant{.{ .name = name, .value = v, .group = groupOf(name) }};
        }
        return list;
    }
}

const Jw = std.json.Stringify;

/// The name of a record type in `abi.records`, if it is one.
fn recordName(comptime T: type) ?[]const u8 {
    inline for (abi.records) |r| if (r[1] == T) return r[0];
    return null;
}

fn writeType(jw: *Jw, comptime T: type) !void {
    if (comptime recordName(T)) |n| return jw.write(n);
    if (T == usize) return jw.write("usize");
    switch (@typeInfo(T)) {
        .int => |i| return jw.write(switch (i.signedness) {
            .unsigned => switch (i.bits) {
                8 => "u8",
                16 => "u16",
                32 => "u32",
                64 => "u64",
                else => @compileError("unsupported width"),
            },
            .signed => switch (i.bits) {
                32 => "i32",
                64 => "i64",
                else => @compileError("unsupported width"),
            },
        }),
        .float => return jw.write("f64"),
        .pointer => return jw.write("ptr"),
        .optional => |o| return switch (@typeInfo(o.child)) {
            .pointer => |p| if (@typeInfo(p.child) == .@"fn") jw.write("fnptr") else jw.write("ptr"),
            else => @compileError("unsupported optional"),
        },
        // A fixed array of a scalar (anole_net_addr.addr): `{"array": {"type": "u8", "len": 16}}`.
        .array => |a| {
            try jw.beginObject();
            try jw.objectField("array");
            try jw.beginObject();
            try jw.objectField("type");
            try writeType(jw, a.child);
            try jw.objectField("len");
            try jw.write(a.len);
            try jw.endObject();
            try jw.endObject();
        },
        .@"union" => |u| {
            try jw.beginObject();
            try jw.objectField("union");
            try jw.beginArray();
            inline for (u.field_names, u.field_types) |n, F| {
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(n);
                try jw.objectField("type");
                try writeType(jw, F);
                try jw.endObject();
            }
            try jw.endArray();
            try jw.endObject();
        },
        else => @compileError("unsupported field type " ++ @typeName(T)),
    }
}

fn writeRecord(jw: *Jw, comptime name: []const u8, comptime T: type) !void {
    try jw.objectField(name);
    try jw.beginObject();
    try jw.objectField("size");
    try jw.write(@sizeOf(T));
    try jw.objectField("align");
    try jw.write(@alignOf(T));
    try jw.objectField("fields");
    try jw.beginArray();
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, F| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(fname);
        try jw.objectField("offset");
        try jw.write(@offsetOf(T, fname));
        try jw.objectField("type");
        try writeType(jw, F);
        try jw.endObject();
    }
    try jw.endArray();
    var any = false;
    for (abi.arrays) |a| if (std.mem.eql(u8, a.record, name)) {
        any = true;
    };
    if (any) {
        try jw.objectField("arrays");
        try jw.beginArray();
        for (abi.arrays) |a| {
            if (!std.mem.eql(u8, a.record, name)) continue;
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(a.name);
            if (a.at) |v| {
                try jw.objectField("at");
                try jw.write(v);
            }
            if (a.after) |v| {
                try jw.objectField("after");
                try jw.write(v);
            }
            if (a.span) |v| {
                try jw.objectField("span");
                try jw.write(v);
            }
            try jw.objectField("item");
            try jw.write(a.item);
            try jw.objectField("count");
            try jw.write(a.count);
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.endObject();
}

/// The document.
pub fn render(arena: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: Jw = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try jw.beginObject();
    try jw.objectField("anole_abi_json");
    try jw.write(1);

    try jw.objectField("abi");
    try jw.beginObject();
    try jw.objectField("major");
    try jw.write(abi.version_major);
    try jw.objectField("minor");
    try jw.write(abi.version_minor);
    try jw.objectField("version");
    try jw.write(abi.version);
    try jw.endObject();

    try jw.objectField("endian");
    try jw.write("little");
    try jw.objectField("record_align");
    try jw.write(abi.record_align);

    try jw.objectField("handle_kinds");
    try jw.beginArray();
    for (abi.handle_kinds) |k| {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(k.kind);
        try jw.objectField("name");
        try jw.write(k.name);
        try jw.objectField("c_type");
        try jw.write(k.c_type);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("events");
    try jw.beginArray();
    for (abi.events) |ev| {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(ev.type);
        try jw.objectField("name");
        try jw.write(ev.name);
        try jw.objectField("record");
        try jw.write(ev.record);
        try jw.objectField("handles");
        try jw.write(ev.handles);
        try jw.objectField("obligation");
        try jw.write(ev.obligation);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("event_ranges");
    try jw.beginArray();
    for (abi.event_ranges) |r| {
        try jw.beginObject();
        try jw.objectField("from");
        try jw.write(r.from);
        try jw.objectField("to");
        try jw.write(r.to);
        try jw.objectField("use");
        try jw.write(r.use);
        try jw.endObject();
    }
    try jw.endArray();

    // Constants, grouped; groups by name, constants in declaration order.
    try jw.objectField("constants");
    try jw.beginObject();
    var groups: std.ArrayList([]const u8) = .empty;
    for (abi.constant_groups) |g| {
        var seen = false;
        for (groups.items) |x| seen = seen or std.mem.eql(u8, x, g.group);
        if (!seen) try groups.append(arena, g.group);
    }
    std.mem.sort([]const u8, groups.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const all = comptime constants(abi);
    for (groups.items) |group| {
        try jw.objectField(group);
        try jw.beginObject();
        for (all) |c| {
            if (!std.mem.eql(u8, c.group, group)) continue;
            try jw.objectField(c.name);
            try jw.write(c.value);
        }
        try jw.endObject();
    }
    try jw.endObject();

    try jw.objectField("records");
    try jw.beginObject();
    inline for (abi.records) |r| try writeRecord(&jw, r[0], r[1]);
    try jw.endObject();

    try jw.objectField("error_names");
    try jw.write(@as([]const []const u8, &abi.error_names));
    try jw.endObject();
    try aw.writer.writeByte('\n');
    return aw.written();
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const cwd = std.Io.Dir.cwd();
    if (args.len == 3 and std.mem.eql(u8, args[1], "--check")) {
        const want = try render(arena);
        const have = cwd.readFileAlloc(io, args[2], arena, .unlimited) catch "";
        if (!std.mem.eql(u8, want, have)) {
            std.log.err("{s} is stale: run `zig build capi-abi-json`", .{args[2]});
            std.process.exit(1);
        }
        return;
    }
    if (args.len == 2) {
        const text = try render(arena);
        try cwd.writeFile(io, .{ .sub_path = args[1], .data = text });
        return;
    }
    std.log.err("usage: capi_abi_json <out.json> | --check <committed.json>", .{});
    std.process.exit(2);
}
