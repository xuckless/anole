//! libdeflate's compressor (`-Dlibdeflate`), the one wrapper over the
//! injected `libdeflate` module (libdeflate.h bindings). Only built with
//! `use_libdeflate`.
//!
//! A compressor's memory comes from `block_cache`, through the allocator
//! hooks given at `create`; `destroy` gives it back. libdeflate keeps no
//! state between calls, so one compressor serves any number of bodies, and
//! the caller owns it (`encoders` keeps one per thread).
const std = @import("std");
const c = @import("libdeflate");
const block_cache = @import("block_cache.zig");

/// libdeflate's compressor (an opaque C struct).
pub const Compressor = @typeInfo(@typeInfo(@typeInfo(@TypeOf(c.libdeflate_alloc_compressor_ex)).@"fn".return_type.?).optional.child).pointer.child;

fn alloc(size: usize) callconv(.c) ?*anyopaque {
    return block_cache.alloc(size);
}

fn free(address: ?*anyopaque) callconv(.c) void {
    block_cache.free(address);
}

/// A compressor at `level` (0 to 12; 1 is fastest), or null when out of
/// memory. Free it with `destroy`.
pub fn create(level: c_int) ?*Compressor {
    const Options = @typeInfo(@typeInfo(@TypeOf(c.libdeflate_alloc_compressor_ex)).@"fn".param_types[1].?).pointer.child;
    var options = std.mem.zeroes(Options);
    options.sizeof_options = @sizeOf(Options);
    options.malloc_func = alloc;
    options.free_func = free;
    return c.libdeflate_alloc_compressor_ex(level, &options);
}

pub fn destroy(compressor: *Compressor) void {
    c.libdeflate_free_compressor(compressor);
}

/// `input` gzipped into `out`: the length written, or 0 when it does not
/// fit.
pub fn gzip(compressor: *Compressor, input: []const u8, out: []u8) usize {
    return c.libdeflate_gzip_compress(compressor, input.ptr, input.len, out.ptr, out.len);
}
