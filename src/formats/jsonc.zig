const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const testing = std.testing;

pub fn indexJsonc(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    return indexJsoncImpl(simd.default_vector_len, allocator, input);
}

pub fn indexJsoncImpl(
    comptime VLEN: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);

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
    var windows = simd.windows(u8, VLEN, input, ' ');
    var chunk_offset: usize = 0;

    while (chunk_offset < input.len) {
        const chunk = windows.next().?;
        const chunk_bytes: [VLEN]u8 = chunk;
        const chunk_length = @min(input.len - chunk_offset, VLEN);
        const valid_mask = validByteMask(VLEN, chunk_length);
        const top_bit: Mask = @as(Mask, 1) << @as(Shift, @intCast(VLEN - 1));
        const quote_mask = simd.matchByte(VLEN, chunk, '"') & valid_mask;
        const backslash_mask = simd.matchByte(VLEN, chunk, '\\') & valid_mask;
        const backslash_result = simd.computeBackslashRuns(
            Mask,
            backslash_mask,
            previous_chunk_ends_in_backslash,
        );
        var odd_backslash_ends = backslash_result.odd_length_ends & valid_mask;
        if (previous_chunk_ends_in_backslash) {
            if ((backslash_mask & @as(Mask, 1)) == 0) {
                if (previous_backslash_run_odd) {
                    odd_backslash_ends |= 1;
                } else {
                    odd_backslash_ends &= ~@as(Mask, 1);
                }
            } else if (previous_backslash_run_odd) {
                odd_backslash_ends ^= leadingRunEndMask(VLEN, backslash_mask, chunk_length);
            }
        }
        const unescaped_quote_mask = quote_mask & ~odd_backslash_ends;
        const structural_mask = simd.matchAny4(VLEN, chunk, '{', '}', '[', ']') |
            simd.matchAny2(VLEN, chunk, ':', ',');
        const atom_mask = simd.matchAny4(VLEN, chunk, '-', 't', 'f', 'n') |
            simd.matchRange(VLEN, chunk, '0', '9');

        var visible_mask: Mask = 0;
        var byte_offset: usize = 0;
        while (byte_offset < chunk_length) : (byte_offset += 1) {
            const byte = chunk_bytes[byte_offset];
            const bit = @as(Mask, 1) << @as(Shift, @intCast(byte_offset));
            const absolute_offset = chunk_offset + byte_offset;
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

        var indexes: [VLEN]u32 = undefined;
        const index_count = simd.extractBitIndexes(
            Mask,
            visible_mask,
            chunk_offset,
            &indexes,
        );
        for (indexes[0..index_count]) |index| {
            result.indexes[result.count] = index;
            result.count += 1;
        }

        previous_chunk_ends_in_backslash = chunk_length == VLEN and
            (backslash_mask & top_bit) != 0;
        previous_backslash_run_odd = trailingBackslashRunOdd(
            VLEN,
            chunk,
            chunk_length,
            previous_backslash_run_odd,
        );
        chunk_offset += VLEN;
    }
    try result.finish(input.len);

    return result;
}

fn validByteMask(comptime VLEN: usize, valid_count: usize) simd.Mask(VLEN) {
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);

    if (valid_count == VLEN) return ~@as(Mask, 0);
    if (valid_count == 0) return 0;
    return (@as(Mask, 1) << @as(Shift, @intCast(valid_count))) - 1;
}

fn leadingRunEndMask(
    comptime VLEN: usize,
    backslashes: simd.Mask(VLEN),
    valid_count: usize,
) simd.Mask(VLEN) {
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);

    const non_backslashes = ~backslashes | ~validByteMask(VLEN, valid_count);
    if (non_backslashes == 0) return 0;
    const run_length: usize = @intCast(@ctz(non_backslashes));
    if (run_length >= valid_count) return 0;
    return @as(Mask, 1) << @as(Shift, @intCast(run_length));
}

fn trailingBackslashRunOdd(
    comptime VLEN: usize,
    chunk: simd.Vec(VLEN, u8),
    valid_count: usize,
    prev_run_odd: bool,
) bool {
    if (valid_count == 0) return false;
    const bytes: [VLEN]u8 = chunk;
    var run_length: usize = 0;
    var index = valid_count;
    while (index > 0 and bytes[index - 1] == '\\') : (index -= 1) {
        run_length += 1;
    }
    if (index == 0) return (run_length % 2 == 0) == prev_run_odd;
    return run_length % 2 != 0;
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
    try result.finish(input.len);

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
    return expectJsoncMatchesScalarAtWidth(simd.default_vector_len, input);
}

fn expectJsoncMatchesScalarAtWidth(comptime VLEN: usize, input: []const u8) !void {
    var expected = try scalarIndexJsonc(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var actual = try indexJsoncImpl(VLEN, testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    for (actual.slice(), 0..) |index, index_offset| {
        try testing.expect(index < input.len);
        if (index_offset > 0) {
            try testing.expect(actual.slice()[index_offset - 1] < index);
        }
    }
}

test "indexJsonc width differential covers comment delimiters" {
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        for (boundary_lengths) |length| {
            var boundary_input: [66]u8 = @splat(' ');
            if (length > 0) {
                boundary_input[length - 1] = 'n';
            }
            try expectJsoncMatchesScalarAtWidth(vlen, boundary_input[0..length]);
        }

        var line_comment: [69]u8 = @splat(' ');
        line_comment[0] = '[';
        line_comment[vlen - 1] = '/';
        line_comment[vlen] = '/';
        line_comment[vlen + 1] = '{';
        line_comment[vlen + 2] = '\n';
        line_comment[vlen + 3] = '1';
        line_comment[vlen + 4] = ']';
        try expectJsoncMatchesScalarAtWidth(vlen, line_comment[0 .. vlen + 5]);

        var block_comment: [131]u8 = @splat(' ');
        block_comment[0] = '[';
        block_comment[vlen - 1] = '/';
        block_comment[vlen] = '*';
        block_comment[vlen + 1] = '{';
        block_comment[2 * vlen - 1] = '*';
        block_comment[2 * vlen] = '/';
        block_comment[2 * vlen + 1] = '1';
        block_comment[2 * vlen + 2] = ']';
        try expectJsoncMatchesScalarAtWidth(vlen, block_comment[0 .. 2 * vlen + 3]);
    }
}

test "indexJsonc width differential covers escaped boundary quotes" {
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        for (boundary_lengths) |length| {
            var boundary_input: [66]u8 = @splat(' ');
            if (length > 0) {
                boundary_input[0] = '[';
            }
            if (length > 1) {
                boundary_input[1] = '"';
            }
            if (length > 3) {
                boundary_input[length - 2] = '\\';
            }
            if (length > 2) {
                boundary_input[length - 1] = '"';
            }
            try expectJsoncMatchesScalarAtWidth(vlen, boundary_input[0..length]);
        }

        var odd_run: [71]u8 = @splat(' ');
        odd_run[0] = '[';
        odd_run[1] = '"';
        odd_run[vlen - 1] = '\\';
        odd_run[vlen] = '"';
        odd_run[vlen + 1] = '/';
        odd_run[vlen + 2] = '/';
        odd_run[vlen + 3] = '"';
        odd_run[vlen + 4] = ',';
        odd_run[vlen + 5] = '1';
        odd_run[vlen + 6] = ']';
        try expectJsoncMatchesScalarAtWidth(vlen, odd_run[0 .. vlen + 7]);

        var even_run: [71]u8 = @splat(' ');
        even_run[0] = '[';
        even_run[1] = '"';
        even_run[vlen - 2] = '\\';
        even_run[vlen - 1] = '\\';
        even_run[vlen] = '"';
        even_run[vlen + 1] = '/';
        even_run[vlen + 2] = '/';
        even_run[vlen + 3] = '{';
        even_run[vlen + 4] = '\n';
        even_run[vlen + 5] = '1';
        even_run[vlen + 6] = ']';
        try expectJsoncMatchesScalarAtWidth(vlen, even_run[0 .. vlen + 7]);
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

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        for (cases) |input| {
            try expectJsoncMatchesScalarAtWidth(vlen, input);
        }
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
    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        try expectJsoncMatchesScalarAtWidth(vlen, &input);
    }
}
