// lint-path: src/example/u1.zig
const yy = @import("anole_yyjson_c"); // expect: U1
const std = @import("std");

extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern fn some_c_function() void; // expect: U1
const E = extern struct { a: u32 };
const U = extern union { a: u32, b: f32 };
