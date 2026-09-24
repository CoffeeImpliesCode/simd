const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const assert = std.debug.assert;
const testing = std.testing;

pub const native_vector_len: usize = switch (builtin.cpu.arch) {
    .x86, .x86_64 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f) and
        std.Target.x86.featureSetHas(builtin.cpu.features, .avx512bw))
        64
    else if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2))
        32
    else
        16,
    else => 16,
};

pub const default_vector_len: usize = build_options.vector_len orelse native_vector_len;

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
        else => @compileError("mask type must be an unsigned integer"),
    };
    if (int_info.signedness != .unsigned) {
        @compileError("mask type must be an unsigned integer");
    }
    if (int_info.bits == 0) {
        @compileError("mask type must contain at least one bit");
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

const PrefixXorPclmul = struct {
    fn multiply(bitmask: u64) u64 {
        const product = asm (
            \\ vpclmulqdq $0x00, %[bitmask], %[ones], %[out]
            : [out] "=x" (-> @Vector(2, u64)),
            : [bitmask] "x" (@as(@Vector(2, u64), @bitCast(@as(u128, bitmask)))),
              [ones] "x" (@as(@Vector(2, u64), @bitCast(@as(u128, std.math.maxInt(u64))))),
        );
        return @truncate(@as(u128, @bitCast(product)));
    }
};

pub fn prefixXor(comptime T: type, bitmask: T) T {
    const bits = @typeInfo(T).int.bits;
    comptime assert(bits > 0);
    if (comptime bits <= 64 and
        builtin.cpu.arch == .x86_64 and
        builtin.zig_backend != .stage2_c and
        builtin.cpu.has(.x86, .avx) and
        builtin.cpu.has(.x86, .pclmul))
    {
        const Unsigned = @Int(.unsigned, bits);
        const extended: u64 = @as(Unsigned, @bitCast(bitmask));
        const prefix = PrefixXorPclmul.multiply(extended);
        return @bitCast(@as(Unsigned, @truncate(prefix)));
    }
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

    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    // maxInt(T) / 3 starts on the wrong lane for odd-width masks.
    var even_bits: T = 0;
    inline for (0..bit_count) |bit_index| {
        if (bit_index % 2 == 0) {
            even_bits |= one << @as(Shift, @intCast(bit_index));
        }
    }
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

pub fn validMask(comptime bits: usize, valid_count: usize) Mask(bits) {
    comptime assert(bits > 0);
    assert(valid_count <= bits);

    const Result = Mask(bits);
    if (valid_count == bits) return std.math.maxInt(Result);
    if (valid_count == 0) return 0;

    const Shift = std.math.Log2Int(Result);
    return (@as(Result, 1) << @as(Shift, @intCast(valid_count))) - 1;
}

pub fn matchJsonWhitespace(comptime len: usize, v: Vec(len, u8)) Mask(len) {
    comptime assert(len > 0);

    const tab: Vec(len, u8) = @splat(0x09);
    const distance_from_tab = v -% tab;
    const folded_distance = distance_from_tab |
        ((distance_from_tab & @as(Vec(len, u8), @splat(0x02))) <<
            @as(Vec(len, u8), @splat(1)));
    const control_whitespace = folded_distance <= @as(Vec(len, u8), @splat(0x04));
    const whitespace = control_whitespace | (v == @as(Vec(len, u8), @splat(0x20)));
    if (comptime len % 8 != 0) {
        var result: Mask(len) = 0;
        inline for (0..len) |lane| {
            result |= @as(Mask(len), @intFromBool(whitespace[lane])) << lane;
        }
        return result;
    }
    return @bitCast(whitespace);
}

pub fn trailingRunOdd(
    comptime bits: usize,
    mask: Mask(bits),
    valid_count: usize,
    previous_odd: bool,
) bool {
    comptime assert(bits > 0);
    assert(valid_count <= bits);
    if (valid_count == 0) return false;

    const valid = validMask(bits, valid_count);
    const masked = mask & valid;
    const non_matching = (~masked) & valid;
    if (non_matching == 0) {
        return (valid_count % 2 == 0) == previous_odd;
    }

    const Shift = std.math.Log2Int(Mask(bits));
    const alignment: Shift = @intCast(bits - valid_count);
    const trailing_count: usize = @intCast(@clz(non_matching << alignment));
    return trailing_count % 2 != 0;
}

pub fn extractBitIndexes(
    comptime T: type,
    bitmask: T,
    base_offset: usize,
    out_indexes: []u32,
) usize {
    comptime validateMaskType(T);

    const bit_count: usize = @typeInfo(T).int.bits;
    // Widen before ctz because non-byte-aligned integers carry spare storage bits.
    const Storage = if (bit_count <= 8)
        u8
    else if (bit_count <= 16)
        u16
    else if (bit_count <= 32)
        u32
    else if (bit_count <= 64)
        u64
    else
        @Int(.unsigned, (bit_count + 7) / 8 * 8);
    const logical_bits: Storage = @intCast(std.math.maxInt(T));
    var mask: Storage = @as(Storage, @intCast(bitmask)) & logical_bits;
    var written: usize = 0;
    inline for (0..8) |_| {
        if (mask != 0 and written < out_indexes.len) {
            const bit_pos: usize = @ctz(mask);
            out_indexes[written] = @intCast(base_offset + bit_pos);
            written += 1;
            mask &= mask - 1;
        }
    }
    while (mask != 0 and written < out_indexes.len) {
        const bit_pos: usize = @ctz(mask);
        out_indexes[written] = @intCast(base_offset + bit_pos);
        written += 1;
        mask &= mask - 1;
    }
    return written;
}

pub fn extractBitIndexesChecked(
    comptime T: type,
    bitmask: T,
    base_offset: usize,
    out_indexes: []u32,
) error{ CapacityExceeded, InputTooLarge }!usize {
    comptime validateMaskType(T);

    const required_count: usize = @intCast(@popCount(bitmask));
    if (out_indexes.len < required_count) return error.CapacityExceeded;
    if (required_count == 0) return 0;

    const bit_count: usize = @typeInfo(T).int.bits;
    const leading_zero_count: usize = @intCast(@clz(bitmask));
    const highest_bit: usize = bit_count - leading_zero_count - 1;
    const highest_offset = std.math.add(usize, base_offset, highest_bit) catch {
        return error.InputTooLarge;
    };
    if (highest_offset > std.math.maxInt(u32)) return error.InputTooLarge;

    var mask = bitmask;
    var written: usize = 0;
    while (mask != 0) {
        const bit_pos: usize = @intCast(@ctz(mask));
        out_indexes[written] = @intCast(base_offset + bit_pos);
        written += 1;
        mask &= mask - 1;
    }
    return written;
}

pub const Utf8ErrorKind = enum(u8) {
    invalid_header,
    unexpected_continuation,
    missing_continuation,
    truncated_sequence,
    overlong,
    surrogate,
    too_large,
};

pub const Utf8Error = struct {
    kind: Utf8ErrorKind,
    offset: usize,
};

pub const Utf8Result = union(enum) {
    valid,
    invalid: Utf8Error,
};

const Utf8BlockState = struct {
    continuation_count: u2 = 0,
    constrained_header: u8 = 0,
};

fn utf8Invalid(kind: Utf8ErrorKind, offset: usize) Utf8Result {
    return .{ .invalid = .{
        .kind = kind,
        .offset = offset,
    } };
}

fn utf8Continuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xbf;
}

fn validateUtf8Scalar(input: []const u8) Utf8Result {
    var offset: usize = 0;
    while (offset < input.len) {
        const header = input[offset];
        if (header <= 0x7f) {
            offset += 1;
            continue;
        }
        if (header <= 0xbf) {
            return utf8Invalid(.unexpected_continuation, offset);
        }
        if (header <= 0xc1) {
            if (offset + 1 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            if (!utf8Continuation(input[offset + 1])) {
                return utf8Invalid(.missing_continuation, offset + 1);
            }
            return utf8Invalid(.overlong, offset);
        }
        if (header <= 0xdf) {
            if (offset + 1 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            if (!utf8Continuation(input[offset + 1])) {
                return utf8Invalid(.missing_continuation, offset + 1);
            }
            offset += 2;
            continue;
        }
        if (header <= 0xef) {
            if (offset + 1 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            const continuation_1 = input[offset + 1];
            if (!utf8Continuation(continuation_1)) {
                return utf8Invalid(.missing_continuation, offset + 1);
            }
            if (header == 0xe0 and continuation_1 < 0xa0) {
                return utf8Invalid(.overlong, offset + 1);
            }
            if (header == 0xed and continuation_1 >= 0xa0) {
                return utf8Invalid(.surrogate, offset + 1);
            }
            if (offset + 2 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            if (!utf8Continuation(input[offset + 2])) {
                return utf8Invalid(.missing_continuation, offset + 2);
            }
            offset += 3;
            continue;
        }
        if (header <= 0xf4) {
            if (offset + 1 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            const continuation_1 = input[offset + 1];
            if (!utf8Continuation(continuation_1)) {
                return utf8Invalid(.missing_continuation, offset + 1);
            }
            if (header == 0xf0 and continuation_1 < 0x90) {
                return utf8Invalid(.overlong, offset + 1);
            }
            if (header == 0xf4 and continuation_1 > 0x8f) {
                return utf8Invalid(.too_large, offset + 1);
            }
            if (offset + 2 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            if (!utf8Continuation(input[offset + 2])) {
                return utf8Invalid(.missing_continuation, offset + 2);
            }
            if (offset + 3 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            if (!utf8Continuation(input[offset + 3])) {
                return utf8Invalid(.missing_continuation, offset + 3);
            }
            offset += 4;
            continue;
        }
        if (header <= 0xf7) {
            return utf8Invalid(.too_large, offset);
        }
        return utf8Invalid(.invalid_header, offset);
    }
    return .valid;
}

fn utf8ContinuationMask(comptime len: usize, count: u2) Mask(len) {
    return switch (count) {
        0 => 0,
        1 => 0b001,
        2 => 0b011,
        3 => 0b111,
    };
}

fn utf8ConstrainedContinuationValid(header: u8, continuation: u8) bool {
    return switch (header) {
        0xe0 => continuation >= 0xa0 and continuation <= 0xbf,
        0xed => continuation >= 0x80 and continuation <= 0x9f,
        0xf0 => continuation >= 0x90 and continuation <= 0xbf,
        0xf4 => continuation >= 0x80 and continuation <= 0x8f,
        else => true,
    };
}

fn utf8BlockIsValid(
    comptime len: usize,
    bytes: Vec(len, u8),
    state: *Utf8BlockState,
) bool {
    const ascii = matchRange(len, bytes, 0x00, 0x7f);
    const continuation = matchRange(len, bytes, 0x80, 0xbf);
    const lead_2 = matchRange(len, bytes, 0xc2, 0xdf);
    const lead_3 = matchRange(len, bytes, 0xe0, 0xef);
    const lead_4 = matchRange(len, bytes, 0xf0, 0xf4);
    const valid_byte = ascii | continuation | lead_2 | lead_3 | lead_4;
    if (~valid_byte != 0) return false;

    const expected_continuation =
        ((lead_2 | lead_3 | lead_4) << 1) |
        ((lead_3 | lead_4) << 2) |
        (lead_4 << 3) |
        utf8ContinuationMask(len, state.continuation_count);
    if (continuation != expected_continuation) return false;
    if (state.constrained_header != 0 and
        !utf8ConstrainedContinuationValid(state.constrained_header, bytes[0]))
    {
        return false;
    }

    const bad_e0 = (matchByte(len, bytes, 0xe0) << 1) &
        matchRange(len, bytes, 0x80, 0x9f);
    const bad_ed = (matchByte(len, bytes, 0xed) << 1) &
        matchRange(len, bytes, 0xa0, 0xbf);
    const bad_f0 = (matchByte(len, bytes, 0xf0) << 1) &
        matchRange(len, bytes, 0x80, 0x8f);
    const bad_f4 = (matchByte(len, bytes, 0xf4) << 1) &
        matchRange(len, bytes, 0x90, 0xbf);
    if ((bad_e0 | bad_ed | bad_f0 | bad_f4) != 0) return false;

    const bytes_array: [len]u8 = @bitCast(bytes);
    var trailing_index: usize = len;
    var trailing_count: u2 = 0;
    var trailing_header: u8 = 0;
    while (trailing_index > 0) {
        trailing_index -= 1;
        const byte = bytes_array[trailing_index];
        const required_count: usize = if (byte >= 0xf0 and byte <= 0xf4)
            3
        else if (byte >= 0xe0 and byte <= 0xef)
            2
        else if (byte >= 0xc2 and byte <= 0xdf)
            1
        else
            0;
        if (required_count == 0) {
            if (!utf8Continuation(byte)) break;
            continue;
        }
        const bytes_after = len - trailing_index - 1;
        if (bytes_after < required_count) {
            trailing_count = @intCast(required_count - bytes_after);
            if (bytes_after == 0) trailing_header = byte;
        }
        break;
    }
    state.continuation_count = trailing_count;
    state.constrained_header = trailing_header;
    return true;
}

// Full blocks use vector masks; a non-ASCII tail is replayed by the scalar
// classifier so short input is never over-read.

fn utf8SuspectOffset(comptime len: usize, input: []const u8) ?usize {
    comptime {
        if (len < 4) {
            @compileError(
                "UTF-8 SIMD vector width must be at least 4 bytes for four-byte UTF-8 " ++
                    "and mask-shift algorithms",
            );
        }
    }
    var state: Utf8BlockState = .{};
    var offset: usize = 0;
    while (input.len - offset >= len) : (offset += len) {
        const bytes: Vec(len, u8) = input[offset..][0..len].*;
        if (!utf8BlockIsValid(len, bytes, &state)) return offset;
    }

    if (state.continuation_count != 0) return offset;
    for (input[offset..], 0..) |byte, tail_offset| {
        if (byte >= 0x80) return offset + tail_offset;
    }
    return null;
}

fn utf8ReplayStart(input: []const u8, suspect_offset: usize) usize {
    var replay_start = @min(suspect_offset, input.len);
    if (replay_start == input.len) {
        return replay_start - @min(@as(usize, 3), replay_start);
    }
    while (replay_start > 0 and utf8Continuation(input[replay_start - 1])) {
        replay_start -= 1;
    }
    if (replay_start > 0) {
        const preceding = input[replay_start - 1];
        if (preceding >= 0xc2 and preceding <= 0xf4) {
            replay_start -= 1;
        }
    }
    return replay_start;
}

fn validateUtf8Replay(input: []const u8, suspect_offset: usize) Utf8Result {
    const replay_start = utf8ReplayStart(input, suspect_offset);
    return switch (validateUtf8Scalar(input[replay_start..])) {
        .valid => .valid,
        .invalid => |error_info| .{ .invalid = .{
            .kind = error_info.kind,
            .offset = replay_start + error_info.offset,
        } },
    };
}

pub fn validateUtf8WithWidth(comptime len: usize, input: []const u8) Utf8Result {
    if (comptime len < 4) return validateUtf8Scalar(input);

    // SIMD identifies a suspect block; scalar replay establishes the first
    // failure class and offset without exposing internal mask bits.
    const suspect_offset = utf8SuspectOffset(len, input) orelse return .valid;
    return validateUtf8Replay(input, suspect_offset);
}

pub fn validateUtf8(input: []const u8) Utf8Result {
    return validateUtf8WithWidth(default_vector_len, input);
}

fn expectUtf8Result(
    input: []const u8,
    expected: Utf8Result,
) !void {
    inline for ([_]usize{ 16, 32, 64 }) |width| {
        try testing.expectEqual(expected, validateUtf8WithWidth(width, input));
    }
    try testing.expectEqual(expected, validateUtf8(input));
}

fn expectUtf8ValidSequenceAtBoundary(
    comptime width: usize,
    sequence: []const u8,
    start: usize,
) !void {
    var input: [68]u8 = [_]u8{'a'} ** 68;
    @memcpy(input[start..][0..sequence.len], sequence);
    const expected: Utf8Result = .valid;
    try testing.expectEqual(
        expected,
        validateUtf8WithWidth(width, input[0 .. start + sequence.len]),
    );
}

fn expectUtf8ValidSequenceInsideBlock(
    comptime width: usize,
    sequence: []const u8,
) !void {
    var input: [width + 1]u8 = [_]u8{'a'} ** (width + 1);
    @memcpy(input[1..][0..sequence.len], sequence);
    const expected: Utf8Result = .valid;
    try testing.expectEqual(expected, validateUtf8WithWidth(width, &input));
}

fn expectUtf8InvalidSequenceAtBoundary(
    comptime width: usize,
    sequence: []const u8,
    start: usize,
    kind: Utf8ErrorKind,
    error_relative_offset: usize,
) !void {
    var input: [68]u8 = [_]u8{'a'} ** 68;
    @memcpy(input[start..][0..sequence.len], sequence);
    const expected = Utf8Result{ .invalid = .{
        .kind = kind,
        .offset = start + error_relative_offset,
    } };
    try testing.expectEqual(
        expected,
        validateUtf8WithWidth(width, input[0 .. start + sequence.len]),
    );
}

test "UTF-8 widths below four match scalar validation" {
    const cases = [_][]const u8{
        "ASCII only",
        &[_]u8{ 0xf0, 0x90, 0x8d, 0x88 },
        &[_]u8{ 'x', 0x80 },
        &[_]u8{ 'x', 0xf0, 0x90, 0x8d },
    };

    for (cases) |input| {
        const expected = validateUtf8Scalar(input);
        inline for ([_]usize{ 1, 2, 3 }) |width| {
            try testing.expectEqual(expected, validateUtf8WithWidth(width, input));
        }
    }
}

test "UTF-8 accepts ASCII and valid sequences at every SIMD width" {
    const sequences = [_][]const u8{
        &[_]u8{ 0xc2, 0xa2 },
        &[_]u8{ 0xe0, 0xa0, 0x80 },
        &[_]u8{ 0xed, 0x9f, 0xbf },
        &[_]u8{ 0xf0, 0x90, 0x8d, 0x88 },
        &[_]u8{ 0xf4, 0x8f, 0xbf, 0xbf },
    };

    inline for ([_]usize{ 16, 32, 64 }) |width| {
        var ascii: [width * 2 + 3]u8 = [_]u8{'x'} ** (width * 2 + 3);
        const expected: Utf8Result = .valid;
        try testing.expectEqual(expected, validateUtf8WithWidth(width, &ascii));

        for (sequences) |sequence| {
            try expectUtf8ValidSequenceInsideBlock(width, sequence);
            inline for ([_]usize{ width - 3, width - 2, width - 1, width }) |start| {
                if (start + sequence.len <= 68) {
                    try expectUtf8ValidSequenceAtBoundary(width, sequence, start);
                }
            }
        }
    }
}

test "UTF-8 reports exact scalar error classes and offsets" {
    const cases = [_]struct {
        bytes: []const u8,
        kind: Utf8ErrorKind,
        offset: usize,
    }{
        .{ .bytes = &[_]u8{0x80}, .kind = .unexpected_continuation, .offset = 0 },
        .{ .bytes = &[_]u8{ 0xc2, 0x20 }, .kind = .missing_continuation, .offset = 1 },
        .{ .bytes = &[_]u8{ 0xe2, 0x82, 0x20 }, .kind = .missing_continuation, .offset = 2 },
        .{ .bytes = &[_]u8{ 0xf0, 0x90, 0x8d, 0x20 }, .kind = .missing_continuation, .offset = 3 },
        .{ .bytes = &[_]u8{ 0xc0, 0x80 }, .kind = .overlong, .offset = 0 },
        .{ .bytes = &[_]u8{ 0xe0, 0x80, 0x80 }, .kind = .overlong, .offset = 1 },
        .{ .bytes = &[_]u8{ 0xf0, 0x80, 0x80, 0x80 }, .kind = .overlong, .offset = 1 },
        .{ .bytes = &[_]u8{ 0xed, 0xa0, 0x80 }, .kind = .surrogate, .offset = 1 },
        .{ .bytes = &[_]u8{ 0xf4, 0x90, 0x80, 0x80 }, .kind = .too_large, .offset = 1 },
        .{ .bytes = &[_]u8{ 0xf5, 0x80, 0x80, 0x80 }, .kind = .too_large, .offset = 0 },
        .{ .bytes = &[_]u8{0xff}, .kind = .invalid_header, .offset = 0 },
        .{ .bytes = &[_]u8{0xe2}, .kind = .truncated_sequence, .offset = 0 },
        .{ .bytes = &[_]u8{ 0xf0, 0x90 }, .kind = .truncated_sequence, .offset = 0 },
    };
    for (cases) |case| {
        const expected = Utf8Result{ .invalid = .{
            .kind = case.kind,
            .offset = case.offset,
        } };
        try expectUtf8Result(case.bytes, expected);
    }
}

test "UTF-8 reports truncation at block edges and tails" {
    const prefixes = [_][]const u8{
        &[_]u8{0xc2},
        &[_]u8{ 0xe2, 0x82 },
        &[_]u8{ 0xf0, 0x90, 0x8d },
    };

    inline for ([_]usize{ 16, 32, 64 }) |width| {
        for (prefixes) |prefix| {
            inline for ([_]usize{ width - 1, width, width + 1 }) |start| {
                if (start + prefix.len <= 68) {
                    var input: [68]u8 = [_]u8{'z'} ** 68;
                    @memcpy(input[start..][0..prefix.len], prefix);
                    const expected = Utf8Result{ .invalid = .{
                        .kind = .truncated_sequence,
                        .offset = start,
                    } };
                    try testing.expectEqual(
                        expected,
                        validateUtf8WithWidth(width, input[0 .. start + prefix.len]),
                    );
                }
            }
        }
    }
}

test "UTF-8 SIMD widths match the scalar classifier" {
    const corpus = [_][]const u8{
        "",
        "ASCII only",
        &[_]u8{ 0x80, 'x' },
        &[_]u8{ 'x', 0xe0, 0x80, 0x80 },
        &[_]u8{ 'x', 0xed, 0xa0, 0x80 },
        &[_]u8{ 'x', 0xf4, 0x90, 0x80, 0x80 },
        &[_]u8{ 'x', 0xf0, 0x90 },
        &[_]u8{ 'x', 0xff },
    };

    for (corpus) |input| {
        try expectUtf8Result(input, validateUtf8Scalar(input));
    }
}

test "UTF-8 carries valid and invalid sequences across SIMD blocks" {
    const valid_sequences = [_][]const u8{
        &[_]u8{ 0xc2, 0xa2 },
        &[_]u8{ 0xe2, 0x82, 0xac },
        &[_]u8{ 0xf0, 0x90, 0x8d, 0x88 },
    };
    const invalid_sequences = [_]struct {
        bytes: []const u8,
        kind: Utf8ErrorKind,
        error_relative_offset: usize,
    }{
        .{
            .bytes = &[_]u8{0x80},
            .kind = .unexpected_continuation,
            .error_relative_offset = 0,
        },
        .{
            .bytes = &[_]u8{0xff},
            .kind = .invalid_header,
            .error_relative_offset = 0,
        },
        .{
            .bytes = &[_]u8{ 0xc2, 0x20 },
            .kind = .missing_continuation,
            .error_relative_offset = 1,
        },
        .{
            .bytes = &[_]u8{ 0xe0, 0x80, 0x80 },
            .kind = .overlong,
            .error_relative_offset = 1,
        },
        .{
            .bytes = &[_]u8{ 0xed, 0xa0, 0x80 },
            .kind = .surrogate,
            .error_relative_offset = 1,
        },
        .{
            .bytes = &[_]u8{ 0xf4, 0x90, 0x80, 0x80 },
            .kind = .too_large,
            .error_relative_offset = 1,
        },
    };
    inline for ([_]usize{ 16, 32, 64 }) |width| {
        for (valid_sequences) |sequence| {
            inline for ([_]usize{ width - 3, width - 2, width - 1, width }) |start| {
                if (start + sequence.len <= 68) {
                    try expectUtf8ValidSequenceAtBoundary(width, sequence, start);
                }
            }
        }
        for (invalid_sequences) |case| {
            inline for ([_]usize{ width - 3, width - 2, width - 1, width }) |start| {
                if (start + case.bytes.len <= 68) {
                    try expectUtf8InvalidSequenceAtBoundary(
                        width,
                        case.bytes,
                        start,
                        case.kind,
                        case.error_relative_offset,
                    );
                }
            }
        }
    }
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

fn scalarPrefixXor(comptime T: type, bitmask: T) T {
    comptime validateMaskType(T);

    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    var parity = false;
    var result: T = 0;
    var bit_index: usize = 0;
    while (bit_index < bit_count) : (bit_index += 1) {
        const bit = (bitmask & (one << @as(Shift, @intCast(bit_index)))) != 0;
        parity = parity != bit;
        if (parity) result |= one << @as(Shift, @intCast(bit_index));
    }
    return result;
}

fn prefixXorAlternatingMask(comptime T: type, comptime even_bits_set: bool) T {
    comptime validateMaskType(T);

    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    var mask: T = 0;
    inline for (0..bit_count) |bit_index| {
        if ((bit_index % 2 == 0) == even_bits_set) {
            mask |= one << @as(Shift, @intCast(bit_index));
        }
    }
    return mask;
}

fn prefixXorQuotePairMask(
    comptime T: type,
    comptime first_bit_index: usize,
    comptime second_bit_index: usize,
) T {
    comptime validateMaskType(T);
    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    comptime assert(first_bit_index < second_bit_index);
    comptime assert(second_bit_index < bit_count);

    const one: T = 1;
    return (one << @as(Shift, @intCast(first_bit_index))) |
        (one << @as(Shift, @intCast(second_bit_index)));
}

fn expectPrefixXorMask(comptime T: type, bitmask: T) !void {
    const expected = scalarPrefixXor(T, bitmask);
    const actual = prefixXor(T, bitmask);
    try testing.expectEqual(expected, actual);
}

fn expectPrefixXorMasks(comptime T: type) !void {
    comptime validateMaskType(T);

    const bit_count: usize = @typeInfo(T).int.bits;
    const one: T = 1;
    try expectPrefixXorMask(T, 0);
    try expectPrefixXorMask(T, std.math.maxInt(T));
    try expectPrefixXorMask(T, prefixXorAlternatingMask(T, true));
    try expectPrefixXorMask(T, prefixXorAlternatingMask(T, false));
    const Shift = std.math.Log2Int(T);
    inline for ([_]usize{ 0, bit_count / 2, bit_count - 1 }) |bit_index| {
        try expectPrefixXorMask(T, one << @as(Shift, @intCast(bit_index)));
    }

    if (bit_count > 1) {
        try expectPrefixXorMask(T, prefixXorQuotePairMask(T, 0, 1));
        try expectPrefixXorMask(
            T,
            prefixXorQuotePairMask(T, bit_count - 2, bit_count - 1),
        );
        try expectPrefixXorMask(T, prefixXorQuotePairMask(T, 0, bit_count - 1));
    }

    inline for ([_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256 }) |boundary| {
        if (boundary < bit_count) {
            try expectPrefixXorMask(
                T,
                prefixXorQuotePairMask(T, boundary - 1, boundary),
            );
        }
    }
}

test "prefixXor matches scalar prefix parity across arbitrary mask widths" {
    inline for ([_]usize{
        1,  2,  3,  7,   8,   15,  16,  31,  32,
        63, 64, 65, 127, 128, 255, 256, 511, 512,
    }) |bit_count| {
        try expectPrefixXorMasks(Mask(bit_count));
    }
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

fn expectExhaustiveBackslashRunParity(comptime T: type) !void {
    const bit_count: usize = @typeInfo(T).int.bits;
    comptime assert(bit_count < @bitSizeOf(usize));
    const mask_count = @as(usize, 1) << bit_count;

    var mask_value: usize = 0;
    while (mask_value < mask_count) : (mask_value += 1) {
        const backslash_mask: T = @intCast(mask_value);
        for ([_]bool{ false, true }) |prev_ends_in_backslash| {
            const expected = scalarBackslashRunParity(
                T,
                backslash_mask,
                prev_ends_in_backslash,
            );
            const actual = computeBackslashRuns(
                T,
                backslash_mask,
                prev_ends_in_backslash,
            );
            try testing.expectEqual(expected.odd_length_ends, actual.odd_length_ends);
            try testing.expectEqual(expected.ends_in_backslash, actual.ends_in_backslash);
        }
    }
}

test "computeBackslashRuns matches scalar parity for every small mask" {
    inline for (.{ u4, u5, u7 }) |T| {
        try expectExhaustiveBackslashRunParity(T);
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

test "extractBitIndexes handles arbitrary mask widths" {
    inline for (.{ u4, u5, u7, u16, u32, u64 }) |T| {
        try expectBitIndexExtraction(T);
    }
}

fn expectMatchedByteIndexExtraction(comptime len: usize) !void {
    const base_offset: usize = 500;
    var matching_lane: usize = 0;
    while (matching_lane < len) : (matching_lane += 1) {
        var bytes: [len]u8 = @splat(0);
        bytes[matching_lane] = '<';

        const vector: Vec(len, u8) = bytes;
        const punctuation_mask = matchAny4(len, vector, '<', '>', '=', '"') |
            matchByte(len, vector, '\'');
        var indexes: [len]u32 = undefined;
        const count = extractBitIndexes(Mask(len), punctuation_mask, base_offset, &indexes);

        try testing.expectEqual(@as(usize, 1), count);
        try testing.expectEqual(
            @as(u32, @intCast(base_offset + matching_lane)),
            indexes[0],
        );
    }
}

test "comparison masks extract only matching vector lanes" {
    inline for (.{ 4, 5, 7, 16, 32, 64 }) |len| {
        try expectMatchedByteIndexExtraction(len);
    }
}

fn expectCtzResultType(comptime T: type) void {
    comptime validateMaskType(T);
    const ctz_result_type = @TypeOf(@ctz(@as(T, 1)));
    comptime assert(ctz_result_type == std.math.Log2IntCeil(T));
}

test "@ctz returns Log2IntCeil for every mask width" {
    comptime {
        expectCtzResultType(u16);
        expectCtzResultType(u32);
        expectCtzResultType(u64);
    }
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

fn scalarJsonWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn expectJsonWhitespaceForWidth(comptime len: usize) !void {
    var bytes: [len]u8 = undefined;
    var byte_start: usize = 0;
    while (byte_start < 256) : (byte_start += 1) {
        for (0..len) |lane| {
            bytes[lane] = @intCast((byte_start + lane) % 256);
        }

        const vector: Vec(len, u8) = bytes;
        const actual = matchJsonWhitespace(len, vector);
        var expected: Mask(len) = 0;
        for (bytes, 0..) |byte, lane| {
            if (scalarJsonWhitespace(byte)) {
                expected |= @as(Mask(len), 1) <<
                    @as(std.math.Log2Int(Mask(len)), @intCast(lane));
            }
        }
        try testing.expectEqual(expected, actual);
    }
}

test "matchJsonWhitespace agrees with scalar classification for every byte" {
    inline for (.{ 4, 5, 7, 16, 32, 64 }) |len| {
        try expectJsonWhitespaceForWidth(len);
    }
}

fn expectValidMasks(comptime bits: usize) !void {
    var valid_count: usize = 0;
    while (valid_count <= bits) : (valid_count += 1) {
        const expected: Mask(bits) = if (valid_count == bits)
            std.math.maxInt(Mask(bits))
        else if (valid_count == 0)
            0
        else
            (@as(Mask(bits), 1) <<
                @as(std.math.Log2Int(Mask(bits)), @intCast(valid_count))) - 1;
        try testing.expectEqual(expected, validMask(bits, valid_count));
    }
}

test "validMask canonicalizes every width and tail count" {
    inline for (.{ 4, 5, 7, 16, 32, 64 }) |bits| {
        try expectValidMasks(bits);
    }
}

fn scalarTrailingRunOdd(
    comptime T: type,
    mask: T,
    valid_count: usize,
    previous_odd: bool,
) bool {
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    if (valid_count == 0) return false;

    var run_length: usize = 0;
    var bit_index = valid_count;
    while (bit_index > 0 and
        (mask & (one << @as(Shift, @intCast(bit_index - 1)))) != 0)
    {
        bit_index -= 1;
        run_length += 1;
    }
    if (bit_index == 0) return (run_length % 2 == 0) == previous_odd;
    return run_length % 2 != 0;
}

fn expectTrailingRunOddSmall(comptime T: type) !void {
    const bits: usize = @typeInfo(T).int.bits;
    const mask_count: usize = @as(usize, 1) << bits;
    var mask_value: usize = 0;
    while (mask_value < mask_count) : (mask_value += 1) {
        const mask: T = @intCast(mask_value);
        var valid_count: usize = 0;
        while (valid_count <= bits) : (valid_count += 1) {
            for ([_]bool{ false, true }) |previous_odd| {
                try testing.expectEqual(
                    scalarTrailingRunOdd(T, mask, valid_count, previous_odd),
                    trailingRunOdd(bits, mask, valid_count, previous_odd),
                );
            }
        }
    }
}

fn alternatingMask(comptime T: type) T {
    const bits: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    var result: T = 0;
    inline for (0..bits) |bit_index| {
        if (bit_index % 2 == 0) {
            result |= one << @as(Shift, @intCast(bit_index));
        }
    }
    return result;
}

fn expectTrailingRunOddWide(comptime T: type) !void {
    const bits: usize = @typeInfo(T).int.bits;
    const masks = [_]T{
        0,
        std.math.maxInt(T),
        alternatingMask(T),
        @as(T, 1),
        std.math.maxInt(T) ^ @as(T, 1),
    };
    for (masks) |mask| {
        var valid_count: usize = 0;
        while (valid_count <= bits) : (valid_count += 1) {
            for ([_]bool{ false, true }) |previous_odd| {
                try testing.expectEqual(
                    scalarTrailingRunOdd(T, mask, valid_count, previous_odd),
                    trailingRunOdd(bits, mask, valid_count, previous_odd),
                );
            }
        }
    }
}

test "trailingRunOdd agrees with scalar carry for all small masks" {
    inline for (.{ u4, u5, u7 }) |T| {
        try expectTrailingRunOddSmall(T);
    }
}

test "trailingRunOdd agrees with scalar carry for wide masks" {
    inline for (.{ u16, u32, u64 }) |T| {
        try expectTrailingRunOddWide(T);
    }
}

fn expectCheckedBitIndexExtraction(comptime T: type) !void {
    const bits: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    const bitmask = (one << @as(Shift, 0)) |
        (one << @as(Shift, @intCast(bits / 2))) |
        (one << @as(Shift, @intCast(bits - 1)));

    var indexes: [3]u32 = undefined;
    const count = try extractBitIndexesChecked(T, bitmask, 100, &indexes);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(u32, 100), indexes[0]);
    try testing.expectEqual(@as(u32, @intCast(100 + bits / 2)), indexes[1]);
    try testing.expectEqual(@as(u32, @intCast(100 + bits - 1)), indexes[2]);

    var short_indexes = [_]u32{ 0xdead_beef, 0xcafe_babe };
    try testing.expectError(
        error.CapacityExceeded,
        extractBitIndexesChecked(T, bitmask, 100, &short_indexes),
    );
    try testing.expectEqualSlices(
        u32,
        &.{ 0xdead_beef, 0xcafe_babe },
        &short_indexes,
    );

    var overflow_indexes = [_]u32{ 0xdead_beef, 0xcafe_babe, 0xfeed_face };
    try testing.expectError(
        error.InputTooLarge,
        extractBitIndexesChecked(
            T,
            bitmask,
            @as(usize, std.math.maxInt(u32)),
            &overflow_indexes,
        ),
    );
    try testing.expectEqualSlices(
        u32,
        &.{ 0xdead_beef, 0xcafe_babe, 0xfeed_face },
        &overflow_indexes,
    );

    var boundary_index: [1]u32 = undefined;
    try testing.expectEqual(
        @as(usize, 1),
        try extractBitIndexesChecked(
            T,
            one,
            @as(usize, std.math.maxInt(u32)),
            &boundary_index,
        ),
    );
    try testing.expectEqual(std.math.maxInt(u32), boundary_index[0]);

    var empty: [0]u32 = .{};
    try testing.expectEqual(
        @as(usize, 0),
        try extractBitIndexesChecked(
            T,
            0,
            std.math.maxInt(usize),
            &empty,
        ),
    );
}

test "extractBitIndexesChecked emits complete output at all supported widths" {
    inline for (.{ u4, u5, u7, u16, u32, u64 }) |T| {
        try expectCheckedBitIndexExtraction(T);
    }
}
