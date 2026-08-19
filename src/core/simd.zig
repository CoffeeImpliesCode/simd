const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const default_vector_len: usize = 64;

pub fn Vec(comptime len: usize, comptime T: type) type {
    comptime assert(len > 0);
    return @Vector(len, T);
}

pub fn Mask(comptime bit_count: usize) type {
    comptime assert(bit_count > 0);
    return @Int(.unsigned, bit_count);
}

pub const EvenBits64: u64 = 0x5555555555555555;
pub const OddBits64: u64 = 0xAAAAAAAAAAAAAAAA;

pub fn ChunkIterator(comptime T: type, comptime len: usize, comptime pad: bool) type {
    comptime assert(len > 0);
    return struct {
        const Self = @This();

        fill: ?T,
        rest: []const T,

        pub fn init(data: []const T, fill: ?T) Self {
            if (pad) {
                assert(fill != null);
            }
            return .{
                .fill = fill,
                .rest = data,
            };
        }

        pub fn next(self: *Self) ?Vec(len, T) {
            if (self.rest.len < len) {
                if (self.rest.len == 0 or !pad) return null;
                var values: [len]T = @splat(self.fill.?);
                for (self.rest, 0..) |elem, idx| {
                    values[idx] = elem;
                }
                self.rest = &.{};
                return values;
            }
            const v: Vec(len, T) = self.rest[0..len].*;
            self.rest = self.rest[len..];
            return v;
        }
    };
}

pub fn windows(
    comptime T: type,
    comptime len: usize,
    data: []const T,
    comptime fill: ?T,
) ChunkIterator(T, len, fill != null) {
    return ChunkIterator(T, len, fill != null).init(data, fill);
}

pub fn prefixXor(comptime T: type, bitmask: T) T {
    const bits = @typeInfo(T).int.bits;
    comptime assert(bits > 0);
    comptime assert(std.math.isPowerOfTwo(bits));

    var x = bitmask;
    const steps = @typeInfo(std.math.Log2Int(T)).int.bits;
    inline for (0..steps) |step| {
        x ^= x << comptime (1 << step);
    }
    return x;
}

pub const BackslashResult64 = struct {
    odd_length_ends: u64,
    ends_in_backslash: bool,
};

pub fn computeBackslashRuns64(backslash_mask: u64, prev_ends_in_backslash: bool) BackslashResult64 {
    const b = backslash_mask;
    if (b == 0) {
        return .{
            .odd_length_ends = if (prev_ends_in_backslash) @as(u64, 1) else 0,
            .ends_in_backslash = false,
        };
    }

    const prev_start: u64 = if (prev_ends_in_backslash) @as(u64, 1) else 0;
    const starts = (b & ~((b << 1) | prev_start)) | (if (prev_ends_in_backslash and (b & 1) != 0) @as(u64, 1) else 0);

    const even_starts = starts & EvenBits64;
    const odd_starts = starts & OddBits64;

    const even_carries = (b +% even_starts) & ~b;
    const odd_carries = (b +% odd_starts) & ~b;

    const od1 = even_carries & OddBits64;
    const od2 = odd_carries & EvenBits64;

    const odd_length_ends = od1 | od2;
    const ends_in_backslash = (b & (@as(u64, 1) << 63)) != 0;

    return .{
        .odd_length_ends = odd_length_ends,
        .ends_in_backslash = ends_in_backslash,
    };
}

pub fn matchByte(comptime len: usize, v: Vec(len, u8), target: u8) Mask(len) {
    const splatted: Vec(len, u8) = @splat(target);
    const eq: Vec(len, bool) = v == splatted;
    return @bitCast(eq);
}

pub fn matchAny2(comptime len: usize, v: Vec(len, u8), c1: u8, c2: u8) Mask(len) {
    const eq1: Vec(len, bool) = v == @as(Vec(len, u8), @splat(c1));
    const eq2: Vec(len, bool) = v == @as(Vec(len, u8), @splat(c2));
    const combined: Vec(len, bool) = eq1 | eq2;
    return @bitCast(combined);
}

pub fn matchAny4(comptime len: usize, v: Vec(len, u8), c1: u8, c2: u8, c3: u8, c4: u8) Mask(len) {
    const eq1: Vec(len, bool) = v == @as(Vec(len, u8), @splat(c1));
    const eq2: Vec(len, bool) = v == @as(Vec(len, u8), @splat(c2));
    const eq3: Vec(len, bool) = v == @as(Vec(len, u8), @splat(c3));
    const eq4: Vec(len, bool) = v == @as(Vec(len, u8), @splat(c4));
    const combined: Vec(len, bool) = eq1 | eq2 | eq3 | eq4;
    return @bitCast(combined);
}

pub fn matchRange(comptime len: usize, v: Vec(len, u8), min: u8, max: u8) Mask(len) {
    const ge_min: Vec(len, bool) = v >= @as(Vec(len, u8), @splat(min));
    const le_max: Vec(len, bool) = v <= @as(Vec(len, u8), @splat(max));
    const in_range: Vec(len, bool) = ge_min & le_max;
    return @bitCast(in_range);
}

pub fn extractBitIndexes(bitmask: u64, base_offset: usize, out_indexes: []u32) usize {
    var mask = bitmask;
    var written: usize = 0;
    while (mask != 0) {
        const bit_pos = @ctz(mask);
        if (written < out_indexes.len) {
            out_indexes[written] = @as(u32, @intCast(base_offset + bit_pos));
            written += 1;
        }
        mask &= mask - 1;
    }
    return written;
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

test "computeBackslashRuns64 detects escaped quotes" {
    const sample = "\\\"Nam\\\"";
    var b_mask: u64 = 0;
    for (sample, 0..) |c, i| {
        if (c == '\\') b_mask |= (@as(u64, 1) << @as(u6, @intCast(i)));
    }
    const res = computeBackslashRuns64(b_mask, false);
    try testing.expect(!res.ends_in_backslash);
    try testing.expect((res.odd_length_ends & (@as(u64, 1) << 1)) != 0);
}

test "extractBitIndexes collects set bit offsets" {
    var out_indexes: [64]u32 = undefined;
    const mask: u64 = (@as(u64, 1) << 3) | (@as(u64, 1) << 17) | (@as(u64, 1) << 45);
    const count = extractBitIndexes(mask, 1000, &out_indexes);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(u32, 1003), out_indexes[0]);
    try testing.expectEqual(@as(u32, 1017), out_indexes[1]);
    try testing.expectEqual(@as(u32, 1045), out_indexes[2]);
}
