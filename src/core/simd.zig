const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const assert = std.debug.assert;
const testing = std.testing;

pub const default_vector_len: usize = build_options.vector_len orelse
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f) and
            std.Target.x86.featureSetHas(builtin.cpu.features, .avx512bw))
            64
        else if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2))
            32
        else
            16,
        else => 16,
    };

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

pub fn prefixXor(comptime T: type, bitmask: T) T {
    const bits = @typeInfo(T).int.bits;
    comptime assert(bits > 0);
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
        if (len < 3) {
            @compileError("UTF-8 SIMD vector width must be at least 3 bytes");
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
    comptime {
        if (len < 3) {
            @compileError("UTF-8 SIMD vector width must be at least 3 bytes");
        }
    }
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
    comptime assert(ctz_result_type == std.math.Log2IntCeil(T));
}

test "@ctz returns Log2IntCeil for every mask width" {
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
