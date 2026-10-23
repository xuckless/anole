//! Java's `Utils.murmur2` (Kafka's default partitioner hash), so a key lands
//! on the partition a Java producer would choose.
const std = @import("std");

pub fn hash(data: []const u8) u32 {
    const m: u32 = 0x5bd1e995;
    const r = 24;
    var h: u32 = 0x9747b28c ^ @as(u32, @truncate(data.len));
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        var k = std.mem.readInt(u32, data[i..][0..4], .little);
        k *%= m;
        k ^= k >> r;
        k *%= m;
        h *%= m;
        h ^= k;
    }
    const rem = data.len - i;
    if (rem >= 3) h ^= @as(u32, data[i + 2]) << 16;
    if (rem >= 2) h ^= @as(u32, data[i + 1]) << 8;
    if (rem >= 1) {
        h ^= data[i];
        h *%= m;
    }
    h ^= h >> 13;
    h *%= m;
    h ^= h >> 15;
    return h;
}

/// The partition for `key` among `partitions`: `toPositive(murmur2(key)) % n`.
pub fn partition(key: []const u8, partitions: u32) u32 {
    return (hash(key) & 0x7fffffff) % partitions;
}

test "murmur2: Kafka's UtilsTest vectors" {
    const Case = struct { []const u8, i32 };
    for ([_]Case{
        .{ "21", -973932308 },
        .{ "foobar", -790332482 },
        .{ "a-little-bit-long-string", -985981536 },
        .{ "a-little-bit-longer-string", -1486304829 },
        .{ "lkjh234lh9fiuh90y23oiuhsafujhadof229phr9h19h89h8", -58897971 },
        .{ "abc", 479470107 },
    }) |c| try std.testing.expectEqual(c[1], @as(i32, @bitCast(hash(c[0]))));
}
