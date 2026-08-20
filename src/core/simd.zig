const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;

pub const default_vector_len: usize = switch (builtin.cpu.arch) {
    .x86, .x86_64 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f) and
        std.Target.x86.featureSetHas(builtin.cpu.features, .avx512bw))
        64
    else if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2))
        32
    else
        16,
    else => 16,
};

comptime {
    assert(
        default_vector_len == 16 or
            default_vector_len == 32 or
            default_vector_len == 64,
    );
}

pub fn Vec(comptime len: usize, comptime T: type) type {
    comptime assert(len > 0);
    return @Vector(len, T);
}

pub fn Mask(comptime bit_count: usize) type {
    comptime assert(bit_count > 0);
    return @Int(.unsigned, bit_count);
}

fn validateMaskType(comptime T: type) void {
    const int_info = switch (@typeInfo(T)) {
        .int => |info| info,
        else => @compileError("mask type must be u16, u32, or u64"),
    };
    if (int_info.signedness != .unsigned or
        !std.math.isPowerOfTwo(int_info.bits) or
        int_info.bits < 16 or
        int_info.bits > 64)
    {
        @compileError("mask type must be u16, u32, or u64");
    }
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

pub fn BackslashResult(comptime T: type) type {
    comptime validateMaskType(T);
    return struct {
        odd_length_ends: T,
        ends_in_backslash: bool,
    };
}

pub fn computeBackslashRuns(
    comptime T: type,
    backslash_mask: T,
    prev_ends_in_backslash: bool,
) BackslashResult(T) {
    comptime validateMaskType(T);

    const b = backslash_mask;
    const one: T = 1;
    if (b == 0) {
        return .{
            .odd_length_ends = if (prev_ends_in_backslash) one else 0,
            .ends_in_backslash = false,
        };
    }

    const even_bits: T = std.math.maxInt(T) / 3;
    const odd_bits: T = ~even_bits;
    const prev_start: T = @intFromBool(prev_ends_in_backslash);
    const starts = (b & ~((b << 1) | prev_start)) |
        (if (prev_ends_in_backslash and (b & 1) != 0) one else 0);

    const even_starts = starts & even_bits;
    const odd_starts = starts & odd_bits;

    const even_carries = (b +% even_starts) & ~b;
    const odd_carries = (b +% odd_starts) & ~b;

    const odd_length_ends =
        (even_carries & odd_bits) | (odd_carries & even_bits);
    const top_bit = one << (@typeInfo(T).int.bits - 1);

    return .{
        .odd_length_ends = odd_length_ends,
        .ends_in_backslash = (b & top_bit) != 0,
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

pub fn extractBitIndexes(
    comptime T: type,
    bitmask: T,
    base_offset: usize,
    out_indexes: []u32,
) usize {
    comptime validateMaskType(T);

    var mask = bitmask;
    var written: usize = 0;
    while (mask != 0 and written < out_indexes.len) {
        const bit_pos: usize = @ctz(mask);
        out_indexes[written] = @intCast(base_offset + bit_pos);
        written += 1;
        mask &= mask - 1;
    }
    return written;
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

fn scalarBackslashRunParity(
    comptime T: type,
    backslash_mask: T,
    prev_ends_in_backslash: bool,
) BackslashResult(T) {
    comptime validateMaskType(T);

    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    var odd_length_ends: T =
        if (prev_ends_in_backslash and backslash_mask == 0) one else 0;
    var run_length: usize = 0;
    var bit_index: usize = 0;
    while (bit_index < bit_count) : (bit_index += 1) {
        const bit = (backslash_mask & (one << @as(Shift, @intCast(bit_index)))) != 0;
        if (bit) {
            run_length += 1;
            continue;
        }
        if (run_length != 0) {
            if (run_length % 2 != 0) {
                odd_length_ends |= one << @as(Shift, @intCast(bit_index));
            }
            run_length = 0;
        }
    }

    return .{
        .odd_length_ends = odd_length_ends,
        .ends_in_backslash = (backslash_mask & (one << @as(Shift, @intCast(bit_count - 1)))) != 0,
    };
}

fn backslashRunMask(comptime T: type, start: usize, length: usize) T {
    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    const end = @min(start + length, bit_count);
    var mask: T = 0;
    var bit_index = start;
    while (bit_index < end) : (bit_index += 1) {
        mask |= one << @as(Shift, @intCast(bit_index));
    }
    return mask;
}

fn expectBoundaryBackslashRunParity(comptime T: type) !void {
    const bit_count: usize = @typeInfo(T).int.bits;
    const boundary_positions = [_]usize{ 14, 15, 16, 17, 30, 31, 32, 33 };
    const run_lengths = [_]usize{ 1, 2, 3, 4 };

    for (boundary_positions) |start| {
        if (start >= bit_count) continue;
        for (run_lengths) |length| {
            const mask = backslashRunMask(T, start, length);
            for ([_]bool{ false, true }) |prev_ends_in_backslash| {
                const expected = scalarBackslashRunParity(
                    T,
                    mask,
                    prev_ends_in_backslash,
                );
                const actual = computeBackslashRuns(
                    T,
                    mask,
                    prev_ends_in_backslash,
                );
                try testing.expectEqual(expected.odd_length_ends, actual.odd_length_ends);
                try testing.expectEqual(expected.ends_in_backslash, actual.ends_in_backslash);
            }
        }
    }
}

fn expectBackslashRunParity(comptime T: type) !void {
    const one: T = 1;
    const mixed_runs: T = 0b1110_1101;
    const result = computeBackslashRuns(T, mixed_runs, false);
    const expected = scalarBackslashRunParity(T, mixed_runs, false);

    try testing.expectEqual((one << 1) | (one << 8), result.odd_length_ends);
    try testing.expect(!result.ends_in_backslash);
    try testing.expectEqual(expected.odd_length_ends, result.odd_length_ends);
    try testing.expectEqual(expected.ends_in_backslash, result.ends_in_backslash);

    const even_run = computeBackslashRuns(T, 0b11, false);
    const expected_even_run = scalarBackslashRunParity(T, 0b11, false);
    try testing.expectEqual(@as(T, 0), even_run.odd_length_ends);
    try testing.expectEqual(expected_even_run.odd_length_ends, even_run.odd_length_ends);
    try testing.expectEqual(expected_even_run.ends_in_backslash, even_run.ends_in_backslash);

    const carried_run = computeBackslashRuns(T, 0, true);
    const expected_carried_run = scalarBackslashRunParity(T, 0, true);
    try testing.expectEqual(one, carried_run.odd_length_ends);
    try testing.expectEqual(expected_carried_run.odd_length_ends, carried_run.odd_length_ends);
    try testing.expectEqual(expected_carried_run.ends_in_backslash, carried_run.ends_in_backslash);

    const top_bit = one << (@typeInfo(T).int.bits - 1);
    const trailing_run = computeBackslashRuns(T, top_bit, false);
    const expected_trailing_run = scalarBackslashRunParity(T, top_bit, false);
    try testing.expectEqual(
        expected_trailing_run.ends_in_backslash,
        trailing_run.ends_in_backslash,
    );

    try expectBoundaryBackslashRunParity(T);
}

test "computeBackslashRuns handles u16 escaped-run parity" {
    try expectBackslashRunParity(u16);
}

test "computeBackslashRuns handles u32 escaped-run parity" {
    try expectBackslashRunParity(u32);
}

test "computeBackslashRuns handles u64 escaped-run parity" {
    try expectBackslashRunParity(u64);
}

fn expectCtzResultType(comptime T: type) void {
    comptime validateMaskType(T);
    const ctz_result_type = @TypeOf(@ctz(@as(T, 1)));
    comptime assert(ctz_result_type == std.math.Log2Int(T));
}

test "@ctz returns Log2Int for every mask width" {
    comptime {
        expectCtzResultType(u16);
        expectCtzResultType(u32);
        expectCtzResultType(u64);
    }
}

fn expectBitIndexExtraction(comptime T: type) !void {
    const bit_count = @typeInfo(T).int.bits;
    const one: T = 1;
    const mask = (one << 1) | (one << (bit_count / 2)) | (one << (bit_count - 1));

    var indexes: [3]u32 = undefined;
    const count = extractBitIndexes(T, mask, 100, &indexes);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(u32, 101), indexes[0]);
    try testing.expectEqual(@as(u32, @intCast(100 + bit_count / 2)), indexes[1]);
    try testing.expectEqual(@as(u32, @intCast(100 + bit_count - 1)), indexes[2]);

    var bounded_indexes: [2]u32 = undefined;
    const bounded_count = extractBitIndexes(T, mask, 200, &bounded_indexes);
    try testing.expectEqual(@as(usize, 2), bounded_count);
    try testing.expectEqual(@as(u32, 201), bounded_indexes[0]);
    try testing.expectEqual(@as(u32, @intCast(200 + bit_count / 2)), bounded_indexes[1]);

    var empty: [0]u32 = .{};
    try testing.expectEqual(@as(usize, 0), extractBitIndexes(T, mask, 0, &empty));
}

test "extractBitIndexes handles u16 masks" {
    try expectBitIndexExtraction(u16);
}

test "extractBitIndexes handles u32 masks" {
    try expectBitIndexExtraction(u32);
}

test "extractBitIndexes handles u64 masks" {
    try expectBitIndexExtraction(u64);
}
