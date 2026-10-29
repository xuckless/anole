// lint-path: src/example/doc.zig
//! Adapted from lalinsky/dusty (MIT), see LICENSE.dusty.
const std = @import("std");

/// A dusty server on a loopback port. // expect: DOC
fn a() void {}

/// Set `use_http2` to turn HTTP/2 on. // expect: DOC
fn b() void {}

/// Imports `dusty` as the core module.
fn c() void {}

// A plain comment may say dusty.
fn d() void {}
