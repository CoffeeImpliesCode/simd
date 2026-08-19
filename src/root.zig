const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const default_vector_len: usize = 64;

pub fn Vec(comptime len: usize, comptime T: type) type {
    return @Vector(len, T);
}

pub fn Mask(comptime bit_count: usize) type {
    return std.meta.Int(.unsigned, bit_count);
}

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
                var v: Vec(len, T) = @splat(self.fill.?);
                for (self.rest, 0..) |elem, idx| {
                    v[idx] = elem;
                }
                self.rest = &.{};
                return v;
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

pub fn prefixXor(bitmask: anytype) @TypeOf(bitmask) {
    const T = @TypeOf(bitmask);
    const bits = @typeInfo(T).int.bits;
    comptime assert(bits > 0);
    comptime assert(std.math.isPowerOfTwo(bits));

    var x = bitmask;
    const steps = @typeInfo(std.math.Log2Int(T)).int.bits;
    inline for (0..steps) |step| {
        const shift = @as(u6, @intCast(1 << step));
        x ^= x << shift;
    }
    return x;
}

pub fn matchByte(comptime len: usize, v: Vec(len, u8), target: u8) Mask(len) {
    const splatted: Vec(len, u8) = @splat(target);
    const eq: Vec(len, bool) = v == splatted;
    return @bitCast(eq);
}

pub fn findQuotes(comptime len: usize, v: Vec(len, u8)) Mask(len) {
    return matchByte(len, v, '"');
}

pub fn findWhitespace(comptime len: usize, v: Vec(len, u8)) Mask(len) {
    const is_space: Vec(len, bool) = (v == @as(Vec(len, u8), @splat(' '))) |
        (v == @as(Vec(len, u8), @splat('\t'))) |
        (v == @as(Vec(len, u8), @splat('\n'))) |
        (v == @as(Vec(len, u8), @splat('\r')));
    return @bitCast(is_space);
}

pub fn findDigits(comptime len: usize, v: Vec(len, u8)) Mask(len) {
    const zero: Vec(len, u8) = @splat('0');
    const nine: Vec(len, u8) = @splat('9');
    const is_digit: Vec(len, bool) = (v >= zero) & (v <= nine);
    return @bitCast(is_digit);
}

pub fn findStructural(comptime len: usize, v: Vec(len, u8)) Mask(len) {
    const is_struct: Vec(len, bool) = (v == @as(Vec(len, u8), @splat('{'))) |
        (v == @as(Vec(len, u8), @splat('}'))) |
        (v == @as(Vec(len, u8), @splat('['))) |
        (v == @as(Vec(len, u8), @splat(']'))) |
        (v == @as(Vec(len, u8), @splat(':'))) |
        (v == @as(Vec(len, u8), @splat(',')));
    return @bitCast(is_struct);
}

pub const StringMaskResult = struct {
    mask: u64,
    ends_in_string: bool,
};

pub fn classifyStrings64(quotes_mask: u64, starts_in_string: bool) StringMaskResult {
    const prev_fill: u64 = if (starts_in_string) ~@as(u64, 0) else 0;
    const inside_without_closing = prefixXor(quotes_mask) ^ prev_fill;
    const string_mask = inside_without_closing | quotes_mask;
    const high_bit_mask: u64 = @as(u64, 1) << 63;
    const ends_in_string = (inside_without_closing & high_bit_mask) != 0;

    return .{
        .mask = string_mask,
        .ends_in_string = ends_in_string,
    };
}

// -------------------------------------------------------------------------
// Scalar Reference Oracles (for test validation & verification)
// -------------------------------------------------------------------------

pub fn scalarPrefixXor64(bitmask: u64) u64 {
    var result: u64 = 0;
    var parity: u1 = 0;
    inline for (0..64) |i| {
        const bit = @as(u1, @truncate(bitmask >> i));
        parity ^= bit;
        result |= (@as(u64, parity) << i);
    }
    return result;
}

pub fn scalarFindDigits64(bytes: [64]u8) u64 {
    var mask: u64 = 0;
    for (bytes, 0..) |b, i| {
        if (b >= '0' and b <= '9') {
            mask |= (@as(u64, 1) << @as(u6, @intCast(i)));
        }
    }
    return mask;
}

pub fn scalarFindWhitespace64(bytes: [64]u8) u64 {
    var mask: u64 = 0;
    for (bytes, 0..) |b, i| {
        if (b == ' ' or b == '\t' or b == '\n' or b == '\r') {
            mask |= (@as(u64, 1) << @as(u6, @intCast(i)));
        }
    }
    return mask;
}

pub fn scalarFindStructural64(bytes: [64]u8) u64 {
    var mask: u64 = 0;
    for (bytes, 0..) |b, i| {
        if (b == '{' or b == '}' or b == '[' or b == ']' or b == ':' or b == ',') {
            mask |= (@as(u64, 1) << @as(u6, @intCast(i)));
        }
    }
    return mask;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "refAllDecls" {
    testing.refAllDecls(@This());
}

test "prefixXor matches scalar reference across bit patterns" {
    const test_patterns = [_]u64{
        0x0000000000000000,
        0xFFFFFFFFFFFFFFFF,
        0x5555555555555555,
        0xAAAAAAAAAAAAAAAA,
        0x0000000000000001,
        0x8000000000000000,
        0x123456789ABCDEF0,
        0x0F0F0F0F0F0F0F0F,
    };

    for (test_patterns) |pattern| {
        const simd_res = prefixXor(pattern);
        const scalar_res = scalarPrefixXor64(pattern);
        try testing.expectEqual(scalar_res, simd_res);
    }
}

test "SIMD byte matching against scalar oracles" {
    var bytes: [64]u8 = undefined;
    for (0..64) |i| {
        bytes[i] = @as(u8, @intCast(i % 128));
    }
    bytes[5] = '"';
    bytes[12] = '"';
    bytes[20] = '{';
    bytes[21] = '}';
    bytes[30] = ' ';
    bytes[31] = '\n';
    bytes[40] = '7';
    bytes[41] = '9';

    const v: Vec(64, u8) = bytes;

    const quotes_simd = findQuotes(64, v);
    try testing.expectEqual((@as(u64, 1) << 5) | (@as(u64, 1) << 12), quotes_simd);

    const ws_simd = findWhitespace(64, v);
    const ws_scalar = scalarFindWhitespace64(bytes);
    try testing.expectEqual(ws_scalar, ws_simd);

    const digits_simd = findDigits(64, v);
    const digits_scalar = scalarFindDigits64(bytes);
    try testing.expectEqual(digits_scalar, digits_simd);

    const struct_simd = findStructural(64, v);
    const struct_scalar = scalarFindStructural64(bytes);
    try testing.expectEqual(struct_scalar, struct_simd);
}

test "ChunkIterator with and without padding" {
    const data = "0123456789ABCDEF_extra";
    var iter_unpadded = windows(u8, 16, data, null);
    const chunk1 = iter_unpadded.next();
    try testing.expect(chunk1 != null);
    try testing.expectEqualStrings("0123456789ABCDEF", &@as([16]u8, chunk1.?));
    const chunk2 = iter_unpadded.next();
    try testing.expect(chunk2 == null);

    var iter_padded = windows(u8, 16, data, 'x');
    _ = iter_padded.next();
    const chunk_tail = iter_padded.next();
    try testing.expect(chunk_tail != null);
    try testing.expectEqualStrings("_extraxxxxxxxxxx", &@as([16]u8, chunk_tail.?));
    try testing.expect(iter_padded.next() == null);
}

test "classifyStrings64 string state transitions" {
    const quote_mask: u64 = (@as(u64, 1) << 4) | (@as(u64, 1) << 10);
    const res1 = classifyStrings64(quote_mask, false);
    try testing.expect(!res1.ends_in_string);
    // Bits 4 through 10 should be 1
    const expected_span: u64 = ((@as(u64, 1) << 11) - 1) ^ ((@as(u64, 1) << 4) - 1);
    try testing.expectEqual(expected_span, res1.mask);

    // Open quote at bit 60 that extends beyond chunk boundary
    const quote_open: u64 = @as(u64, 1) << 60;
    const res2 = classifyStrings64(quote_open, false);
    try testing.expect(res2.ends_in_string);

    // Next chunk starts in string and closes at bit 5
    const quote_close: u64 = @as(u64, 1) << 5;
    const res3 = classifyStrings64(quote_close, true);
    try testing.expect(!res3.ends_in_string);
    const expected_closed: u64 = (@as(u64, 1) << 6) - 1;
    try testing.expectEqual(expected_closed, res3.mask);
}
