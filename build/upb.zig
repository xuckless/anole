//! upb, protobuf's C runtime, from the protobuf 36.2 release tarball
//! (BSD-3-Clause; utf8_range MIT): the amalgamation the Ruby extension ships
//! (ruby/ext/google/protobuf_c/ruby-upb.c, one file holding the wire format,
//! reflection from descriptors and the proto3 JSON mapping) and
//! third_party/utf8_range, built as they are. The C ABI's gRPC server uses it
//! through src/capi/upb_shim.c to turn JSON (Connect, gRPC-Web JSON, JSON
//! transcoding) into the protobuf bytes a consumer reads, and back, with the
//! descriptors the consumer gives; nothing else in Anole calls it, so no
//! other binary links it.
const std = @import("std");

pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "upb",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true }),
    });
    const m = lib.root_module;
    m.addIncludePath(upstream.path("ruby/ext/google/protobuf_c"));
    m.addIncludePath(upstream.path("third_party/utf8_range"));
    const flags: []const []const u8 = &.{"-std=c99"};
    m.addCSourceFile(.{ .file = upstream.path("ruby/ext/google/protobuf_c/ruby-upb.c"), .flags = flags });
    m.addCSourceFile(.{ .file = upstream.path("third_party/utf8_range/utf8_range.c"), .flags = flags });
    // Anole's few entry points over it (C, so that upb's inline functions
    // and macros stay on the C side).
    m.addCSourceFile(.{ .file = b.path("src/capi/upb_shim.c"), .flags = flags });
    return lib;
}

/// Bindings of src/capi/upb_shim.h, linking `lib`.
pub fn module(
    b: *std.Build,
    /// `b.lazyImport(@This(), "translate_c").?.Translator`, resolved by build.zig.
    comptime Translator: type,
    translate_c: *std.Build.Dependency,
    lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const t: Translator = .init(translate_c, .{
        .name = "upb_shim",
        .c_source_file = b.path("src/capi/upb_shim.h"),
        .target = target,
        .optimize = optimize,
    });
    t.mod.linkLibrary(lib);
    return t.mod;
}
