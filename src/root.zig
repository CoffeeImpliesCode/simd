const std = @import("std");
const assert = std.debug.assert;

pub const default_vector_len: usize = 64;

pub fn Vec(comptime len: usize, comptime T: type) type {
    comptime assert(len > 0);
    return @Vector(len, T);
}

pub fn Mask(comptime bit_count: usize) type {
    comptime assert(bit_count > 0);
    return @Int(.unsigned, bit_count);
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
    const inside_without_closing = prefixXor(u64, quotes_mask) ^ prev_fill;
    const string_mask = inside_without_closing | quotes_mask;
    const high_bit_mask: u64 = @as(u64, 1) << 63;
    const ends_in_string = (inside_without_closing & high_bit_mask) != 0;

    return .{
        .mask = string_mask,
        .ends_in_string = ends_in_string,
    };
}
