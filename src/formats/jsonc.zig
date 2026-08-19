const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const testing = std.testing;

pub fn indexJsonc(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var in_single_comment = false;
    var in_multi_comment = false;
    var previous_chunk_ends_in_backslash = false;
    var previous_backslash_run_odd = false;
    var skip_after_multi_comment = false;
    var previous_atom_candidate = false;
    var windows = simd.windows(u8, 64, input, ' ');
    var chunk_offset: usize = 0;

    while (windows.next()) |chunk| : (chunk_offset += 64) {
        const chunk_bytes: [64]u8 = chunk;
        const chunk_length = @min(@as(usize, 64), input.len -|
            @min(chunk_offset, input.len));
        const quote_mask = simd.matchByte(64, chunk, '"');
        const backslash_mask = simd.matchByte(64, chunk, '\\');
        const backslash_result = simd.computeBackslashRuns64(
            backslash_mask,
            previous_chunk_ends_in_backslash,
        );
        var odd_backslash_ends = backslash_result.odd_length_ends;
        if (previous_chunk_ends_in_backslash) {
            if ((backslash_mask & 1) == 0) {
                if (previous_backslash_run_odd) {
                    odd_backslash_ends |= 1;
                } else {
                    odd_backslash_ends &= ~@as(u64, 1);
                }
            } else if (previous_backslash_run_odd) {
                odd_backslash_ends ^= leadingRunEndMask(backslash_mask, chunk_length);
            }
        }
        const unescaped_quote_mask = quote_mask & ~odd_backslash_ends;
        const structural_mask = simd.matchAny4(64, chunk, '{', '}', '[', ']') |
            simd.matchAny2(64, chunk, ':', ',');
        const atom_mask = simd.matchAny4(64, chunk, '-', 't', 'f', 'n') |
            simd.matchRange(64, chunk, '0', '9');
        var trailing_backslash_parity = previous_backslash_run_odd;

        var visible_mask: u64 = 0;
        var byte_offset: usize = 0;
        while (byte_offset < chunk_length) : (byte_offset += 1) {
            const byte = chunk_bytes[byte_offset];
            const bit = @as(u64, 1) << @as(u6, @intCast(byte_offset));
            const absolute_offset = chunk_offset + byte_offset;
            if (byte == '\\') {
                trailing_backslash_parity = !trailing_backslash_parity;
            } else {
                trailing_backslash_parity = false;
            }
            if (skip_after_multi_comment) {
                skip_after_multi_comment = false;
                continue;
            }

            if (in_string) {
                if ((unescaped_quote_mask & bit) != 0) {
                    in_string = false;
                    previous_atom_candidate = false;
                }
                continue;
            }

            if (in_single_comment) {
                if (byte == '\n' or byte == '\r') {
                    in_single_comment = false;
                    previous_atom_candidate = false;
                }
                continue;
            }

            if (in_multi_comment) {
                if (byte == '*' and absolute_offset + 1 < input.len and
                    input[absolute_offset + 1] == '/')
                {
                    in_multi_comment = false;
                    previous_atom_candidate = false;
                    skip_after_multi_comment = true;
                }
                continue;
            }

            if ((unescaped_quote_mask & bit) != 0) {
                in_string = true;
                previous_atom_candidate = false;
                continue;
            }

            if (byte == '/' and absolute_offset + 1 < input.len) {
                const next_byte = input[absolute_offset + 1];
                if (next_byte == '/') {
                    in_single_comment = true;
                    previous_atom_candidate = false;
                    continue;
                }
                if (next_byte == '*') {
                    in_multi_comment = true;
                    previous_atom_candidate = false;
                    continue;
                }
            }

            const is_structural = (structural_mask & bit) != 0;
            if (is_structural) {
                visible_mask |= bit;
                previous_atom_candidate = false;
                continue;
            }

            const is_atom_candidate = (atom_mask & bit) != 0;
            if (is_atom_candidate) {
                if (!previous_atom_candidate) {
                    visible_mask |= bit;
                }
                previous_atom_candidate = true;
                continue;
            }

            previous_atom_candidate = false;
        }

        var indexes: [64]u32 = undefined;
        const index_count = simd.extractBitIndexes(
            visible_mask,
            chunk_offset,
            &indexes,
        );
        for (indexes[0..index_count]) |index| {
            result.indexes[result.count] = index;
            result.count += 1;
        }

        previous_chunk_ends_in_backslash = chunk_length == 64 and
            (backslash_mask & (@as(u64, 1) << 63)) != 0;
        previous_backslash_run_odd = trailing_backslash_parity;
    }

    return result;
}

fn validByteMask(valid_count: usize) u64 {
    if (valid_count == 64) return ~@as(u64, 0);
    if (valid_count == 0) return 0;
    return (@as(u64, 1) << @as(u6, @intCast(valid_count))) - 1;
}

fn leadingRunEndMask(backslashes: u64, valid_count: usize) u64 {
    const non_backslashes = ~backslashes | ~validByteMask(valid_count);
    if (non_backslashes == 0) return 0;
    const run_length = @ctz(non_backslashes);
    if (run_length >= valid_count) return 0;
    return @as(u64, 1) << @as(u6, @intCast(run_length));
}

fn scalarIndexJsonc(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var in_single_comment = false;
    var in_multi_comment = false;
    var skip_after_multi_comment = false;
    var previous_atom_candidate = false;
    var backslash_run_length: usize = 0;

    for (input, 0..) |byte, byte_offset| {
        const unescaped_quote = byte == '"' and backslash_run_length % 2 == 0;

        if (skip_after_multi_comment) {
            skip_after_multi_comment = false;
        } else if (in_string) {
            if (unescaped_quote) {
                in_string = false;
                previous_atom_candidate = false;
            }
        } else if (in_single_comment) {
            if (byte == '\n' or byte == '\r') {
                in_single_comment = false;
                previous_atom_candidate = false;
            }
        } else if (in_multi_comment) {
            if (byte == '*' and byte_offset + 1 < input.len and
                input[byte_offset + 1] == '/')
            {
                in_multi_comment = false;
                previous_atom_candidate = false;
                skip_after_multi_comment = true;
            }
        } else if (unescaped_quote) {
            in_string = true;
            previous_atom_candidate = false;
        } else if (byte == '/' and byte_offset + 1 < input.len) {
            const next_byte = input[byte_offset + 1];
            if (next_byte == '/') {
                in_single_comment = true;
                previous_atom_candidate = false;
            } else if (next_byte == '*') {
                in_multi_comment = true;
                previous_atom_candidate = false;
            } else {
                previous_atom_candidate = false;
            }
        } else if (isJsoncStructuralByte(byte)) {
            result.indexes[result.count] = @intCast(byte_offset);
            result.count += 1;
            previous_atom_candidate = false;
        } else if (isJsoncAtomByte(byte)) {
            if (!previous_atom_candidate) {
                result.indexes[result.count] = @intCast(byte_offset);
                result.count += 1;
            }
            previous_atom_candidate = true;
        } else {
            previous_atom_candidate = false;
        }

        if (byte == '\\') {
            backslash_run_length += 1;
        } else {
            backslash_run_length = 0;
        }
    }

    return result;
}

fn isJsoncStructuralByte(byte: u8) bool {
    return switch (byte) {
        '{', '}', '[', ']', ':', ',' => true,
        else => false,
    };
}

fn isJsoncAtomByte(byte: u8) bool {
    return switch (byte) {
        '-', 't', 'f', 'n', '0'...'9' => true,
        else => false,
    };
}

fn expectJsoncMatchesScalar(input: []const u8) !void {
    var expected = try scalarIndexJsonc(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var actual = try indexJsonc(testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    for (actual.slice(), 0..) |index, index_offset| {
        try testing.expect(index < input.len);
        if (index_offset > 0) {
            try testing.expect(actual.slice()[index_offset - 1] < index);
        }
    }
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

test "indexJsonc excludes line and block comments" {
    const input = "{\"a\":1,//[,] false\n\"b\":true/*{:}*/, \"c\":null}";
    const expected = [_]u32{ 0, 4, 5, 6, 22, 23, 34, 39, 40, 44 };

    var index = try indexJsonc(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonc ignores comment markers inside strings" {
    const input = "{\"url\":\"//not /* comment */\",/* \"quoted\" // */\"n\":-12}";
    const expected = [_]u32{ 0, 6, 28, 49, 50, 53 };

    var index = try indexJsonc(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonc carries comments across SIMD chunks" {
    var input: [132]u8 = @splat(' ');
    input[0] = '{';
    input[63] = '/';
    input[64] = '/';
    input[65] = '[';
    input[70] = '\n';
    input[71..75].* = "true".*;
    input[75] = '/';
    input[76] = '*';
    input[80] = '{';
    input[127] = '*';
    input[128] = '/';
    input[129] = ',';
    input[130] = '0';
    input[131] = '}';
    const expected = [_]u32{ 0, 71, 129, 130, 131 };

    var index = try indexJsonc(testing.allocator, &input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonc preserves escaped quote state across chunks" {
    var input: [71]u8 = @splat(' ');
    input[0] = '[';
    input[1] = '"';
    input[63] = '\\';
    input[64] = '"';
    input[65] = '/';
    input[66] = '/';
    input[67] = '"';
    input[68] = ',';
    input[69] = '1';
    input[70] = ']';
    const expected = [_]u32{ 0, 68, 69, 70 };

    var index = try indexJsonc(testing.allocator, &input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonc emits one start per atom" {
    const input = "true false 123 -45";
    const expected = [_]u32{ 0, 5, 11, 15 };

    var index = try indexJsonc(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonc handles even backslash runs across chunks" {
    var input: [70]u8 = @splat(' ');
    input[0] = '[';
    input[1] = '"';
    input[62] = '\\';
    input[63] = '\\';
    input[64] = '"';
    input[65] = '/';
    input[66] = '/';
    input[67] = '[';
    input[68] = '\n';
    input[69] = ']';
    const expected = [_]u32{ 0, 69 };

    var index = try indexJsonc(testing.allocator, &input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonc handles every short backslash run across a chunk" {
    var input: [72]u8 = @splat(' ');
    for (0..8) |run_length| {
        input = @splat(' ');
        input[0] = '[';
        input[1] = '"';
        const run_start = 64 - run_length;
        for (run_start..64) |index| {
            input[index] = '\\';
        }
        input[64] = '"';
        if (run_length % 2 == 0) {
            input[65] = '1';
            input[66] = ']';
        } else {
            input[65] = '"';
            input[66] = '1';
            input[67] = ']';
        }

        var index = try indexJsonc(testing.allocator, &input);
        defer index.deinit(testing.allocator);
        if (run_length % 2 == 0) {
            const expected = [_]u32{ 0, 65, 66 };
            try testing.expectEqualSlices(u32, &expected, index.slice());
        } else {
            const expected = [_]u32{ 0, 66, 67 };
            try testing.expectEqualSlices(u32, &expected, index.slice());
        }
    }
}

test "indexJsonc carries block comment starts across chunks" {
    var input: [72]u8 = @splat(' ');
    input[0] = '[';
    input[62] = '/';
    input[63] = '*';
    input[64] = '{';
    input[68] = '*';
    input[69] = '/';
    input[70] = '1';
    input[71] = ']';
    const expected = [_]u32{ 0, 70, 71 };

    var index = try indexJsonc(testing.allocator, &input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonc matches scalar for adversarial strings and comments" {
    // The scalar implementation defines lexical precedence for conflicting delimiters.
    const cases = [_][]const u8{
        "",
        "\"http://foo/*bar*/ and */ // /*\"",
        "{\"url\":\"http://foo/*bar*/\",\"tail\":\"*/ // /*\"}",
        "{// \" /* */ [ ] { } : , false\n\"value\":1}",
        "{/* \" // [ ] { } : , false */\"value\":1}",
        "{/* unterminated \" // [ ] { } : , false",
        "[\"escaped quote: \\\" // still string\",0]",
        "[\"even slash run: \\\\\"/* comment */1]",
    };

    for (cases) |input| {
        try expectJsoncMatchesScalar(input);
    }
}

test "indexJsonc carries a block comment across two exact SIMD boundaries" {
    var input: [132]u8 = @splat(' ');
    input[0] = '[';
    input[62] = '/';
    input[63] = '*';
    input[64] = '"';
    input[65] = '{';
    input[100] = '"';
    input[126] = '*';
    input[127] = '/';
    input[128] = ',';
    input[129] = 'n';
    input[130] = 'u';
    input[131] = ']';

    try expectJsoncMatchesScalar(&input);
}

test "indexJsonc matches scalar around every adjacent chunk boundary offset" {
    // Each delimiter begins on both sides of a 64-byte boundary.
    var input: [136]u8 = @splat(' ');
    for (62..66) |comment_start| {
        for (126..130) |comment_end| {
            input = @splat(' ');
            input[0] = '[';
            input[comment_start] = '/';
            input[comment_start + 1] = '*';
            input[96] = '"';
            input[97] = '{';
            input[comment_end] = '*';
            input[comment_end + 1] = '/';
            input[comment_end + 2] = '1';
            input[135] = ']';
            try expectJsoncMatchesScalar(&input);
        }
    }
}

test "indexJsonc handles unterminated comments and all final chunk lengths" {
    var input: [130]u8 = @splat(' ');
    for (0..input.len + 1) |input_length| {
        input = @splat(' ');
        if (input_length > 0) input[0] = '[';
        if (input_length > 63) input[62..64].* = "/*".*;
        if (input_length > 64) input[64] = '"';
        if (input_length > 65) input[65] = '{';
        try expectJsoncMatchesScalar(input[0..input_length]);
    }
}

test "indexJsonc matches scalar for every backslash run crossing byte 64" {
    var input: [70]u8 = @splat(' ');
    for (0..64) |run_length| {
        input = @splat(' ');
        input[0] = '[';
        input[1] = '"';
        const run_start = 65 - run_length;
        for (run_start..65) |byte_offset| {
            input[byte_offset] = '\\';
        }
        input[65] = '"';
        if (run_length % 2 == 0) {
            input[66] = '1';
            input[67] = ']';
        } else {
            input[66] = '"';
            input[67] = '1';
            input[68] = ']';
        }
        try expectJsoncMatchesScalar(&input);
    }
}

test "indexJsonc matches scalar for every byte value" {
    var input: [512]u8 = undefined;
    for (0..input.len) |byte_offset| {
        input[byte_offset] = @as(u8, @truncate(byte_offset));
    }
    try expectJsoncMatchesScalar(&input);
}
