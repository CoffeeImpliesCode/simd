const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const testing = std.testing;

pub fn indexJson5(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    return indexJson5Impl(simd.default_vector_len, allocator, input);
}

pub fn indexJson5Impl(
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
    var string_quote: u8 = 0;
    var in_single_comment = false;
    var in_multi_comment = false;
    var previous_chunk_ends_in_backslash = false;
    var previous_backslash_run_odd = false;
    var skip_after_multi_comment = false;
    var previous_atom_candidate = false;
    var windows = simd.windows(u8, VLEN, input, ' ');
    var chunk_offset: usize = 0;

    while (windows.next()) |chunk| : (chunk_offset += VLEN) {
        const chunk_bytes: [VLEN]u8 = chunk;
        const chunk_length = @min(@as(usize, VLEN), input.len -|
            @min(chunk_offset, input.len));
        const valid_mask = validByteMask(VLEN, chunk_length);
        const top_bit: Mask = @as(Mask, 1) <<
            @as(Shift, @intCast(VLEN - 1));
        const double_quote_mask: Mask =
            simd.matchByte(VLEN, chunk, '"') & valid_mask;
        const single_quote_mask: Mask =
            simd.matchByte(VLEN, chunk, '\'') & valid_mask;
        const backslash_mask: Mask =
            simd.matchByte(VLEN, chunk, '\\') & valid_mask;
        const backslash_result = simd.computeBackslashRuns(
            simd.Mask(VLEN),
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
                odd_backslash_ends ^= leadingRunEndMask(
                    VLEN,
                    backslash_mask,
                    chunk_length,
                );
            }
        }
        const unescaped_double_quote_mask =
            double_quote_mask & ~odd_backslash_ends;
        const unescaped_single_quote_mask =
            single_quote_mask & ~odd_backslash_ends;
        const structural_mask: Mask = (simd.matchAny4(
            VLEN,
            chunk,
            '{',
            '}',
            '[',
            ']',
        ) | simd.matchAny2(VLEN, chunk, ':', ',')) & valid_mask;
        const identifier_mask: Mask = (simd.matchRange(
            VLEN,
            chunk,
            'a',
            'z',
        ) | simd.matchRange(VLEN, chunk, 'A', 'Z') |
            simd.matchAny2(VLEN, chunk, '_', '$')) & valid_mask;
        const atom_mask: Mask = (simd.matchByte(
            VLEN,
            chunk,
            '-',
        ) | simd.matchRange(VLEN, chunk, '0', '9') |
            identifier_mask) & valid_mask;
        var trailing_backslash_parity = previous_backslash_run_odd;

        var visible_mask: Mask = 0;
        var byte_offset: usize = 0;
        while (byte_offset < chunk_length) : (byte_offset += 1) {
            const byte = chunk_bytes[byte_offset];
            const bit: Mask = @as(Mask, 1) <<
                @as(Shift, @intCast(byte_offset));
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
                const quote_mask = if (string_quote == '\'')
                    unescaped_single_quote_mask
                else
                    unescaped_double_quote_mask;
                if ((quote_mask & bit) != 0) {
                    in_string = false;
                    string_quote = 0;
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

            if ((unescaped_double_quote_mask & bit) != 0 or
                (unescaped_single_quote_mask & bit) != 0)
            {
                in_string = true;
                string_quote = byte;
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

            const is_atom_candidate = (atom_mask & bit) != 0 or isJson5AtomByte(
                byte,
                previous_atom_candidate,
                input,
                absolute_offset,
            );
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
            simd.Mask(VLEN),
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
        previous_backslash_run_odd = trailing_backslash_parity;
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

fn isJson5AtomByte(
    byte: u8,
    previous_atom_candidate: bool,
    input: []const u8,
    byte_offset: usize,
) bool {
    return switch (byte) {
        '-', '0'...'9', 'a'...'z', 'A'...'Z', '_', '$' => true,
        0x80...0xbf => previous_atom_candidate,
        0xc0...0xff => !isJson5UnicodeWhitespace(input, byte_offset),
        else => false,
    };
}

fn isJson5UnicodeWhitespace(input: []const u8, byte_offset: usize) bool {
    const byte = input[byte_offset];
    if (byte == 0xc2) {
        return byte_offset + 1 < input.len and input[byte_offset + 1] == 0xa0;
    }
    if (byte == 0xe1) {
        return byte_offset + 2 < input.len and input[byte_offset + 1] == 0x9a and
            input[byte_offset + 2] == 0x80;
    }
    if (byte == 0xe2 and byte_offset + 2 < input.len) {
        const second_byte = input[byte_offset + 1];
        const third_byte = input[byte_offset + 2];
        if (second_byte == 0x80) {
            return third_byte >= 0x80 and third_byte <= 0x8a or third_byte == 0xa8 or
                third_byte == 0xa9 or third_byte == 0xaf;
        }
        return second_byte == 0x81 and third_byte == 0x9f;
    }
    if (byte == 0xe3) {
        return byte_offset + 2 < input.len and input[byte_offset + 1] == 0x80 and
            input[byte_offset + 2] == 0x80;
    }
    if (byte == 0xef) {
        return byte_offset + 2 < input.len and input[byte_offset + 1] == 0xbb and
            input[byte_offset + 2] == 0xbf;
    }
    return false;
}

fn scalarIndexJson5(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var string_quote: u8 = 0;
    var in_single_comment = false;
    var in_multi_comment = false;
    var skip_after_multi_comment = false;
    var previous_atom_candidate = false;
    var backslash_run_length: usize = 0;

    for (input, 0..) |byte, byte_offset| {
        const unescaped_double_quote = byte == '"' and backslash_run_length % 2 == 0;
        const unescaped_single_quote = byte == '\'' and backslash_run_length % 2 == 0;

        if (skip_after_multi_comment) {
            skip_after_multi_comment = false;
        } else if (in_string) {
            const closes_string = if (string_quote == '\'')
                unescaped_single_quote
            else
                unescaped_double_quote;
            if (closes_string) {
                in_string = false;
                string_quote = 0;
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
        } else if (unescaped_double_quote or unescaped_single_quote) {
            in_string = true;
            string_quote = byte;
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
        } else if (isJson5StructuralByte(byte)) {
            result.indexes[result.count] = @intCast(byte_offset);
            result.count += 1;
            previous_atom_candidate = false;
        } else if (isJson5AtomByte(
            byte,
            previous_atom_candidate,
            input,
            byte_offset,
        )) {
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

fn isJson5StructuralByte(byte: u8) bool {
    return switch (byte) {
        '{', '}', '[', ']', ':', ',' => true,
        else => false,
    };
}

fn expectJson5MatchesScalar(input: []const u8) !void {
    var expected = try scalarIndexJson5(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var actual = try indexJson5(testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    for (actual.slice(), 0..) |index, index_offset| {
        try testing.expect(index < input.len);
        if (index_offset > 0) {
            try testing.expect(actual.slice()[index_offset - 1] < index);
        }
    }
}

fn expectJson5ImplMatchesScalar(
    comptime VLEN: usize,
    input: []const u8,
) !void {
    var expected = try scalarIndexJson5(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var actual = try indexJson5Impl(VLEN, testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
}

test "indexJson5 implementations match scalar around vector boundaries" {
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |VLEN| {
        for (boundary_lengths) |length| {
            var boundary_input: [66]u8 = @splat(' ');
            if (length > 0) {
                boundary_input[length - 1] = '$';
            }
            try expectJson5ImplMatchesScalar(VLEN, boundary_input[0..length]);
        }

        var block_input: [VLEN * 5 + 8]u8 = @splat(' ');
        block_input[0] = '{';
        block_input[VLEN - 1] = 0xc3;
        block_input[VLEN] = 0xa9;
        block_input[VLEN + 1] = ':';
        block_input[VLEN + 2 .. VLEN + 6].* = "0x2A".*;
        block_input[VLEN + 6] = ',';
        block_input[VLEN * 2 - 1] = '/';
        block_input[VLEN * 2] = '*';
        block_input[VLEN * 2 + 1 .. VLEN * 2 + 4].* = "\"['".*;
        block_input[VLEN * 3 - 1] = '*';
        block_input[VLEN * 3] = '/';
        block_input[VLEN * 3 + 1 .. VLEN * 3 + 4].* = "_k:".*;
        block_input[VLEN * 3 + 4] = '\'';
        block_input[VLEN * 4 - 1] = '\\';
        block_input[VLEN * 4] = '\'';
        block_input[VLEN * 4 + 1] = '\'';
        block_input[VLEN * 4 + 2] = ',';
        block_input[VLEN * 5 - 1] = 0xc2;
        block_input[VLEN * 5] = 0xa0;
        block_input[VLEN * 5 + 1 .. VLEN * 5 + 8].* = "$ok:1,}".*;
        try expectJson5ImplMatchesScalar(VLEN, &block_input);

        var line_input: [VLEN * 2 + 5]u8 = @splat(' ');
        line_input[0] = '[';
        line_input[VLEN - 1] = '/';
        line_input[VLEN] = '/';
        line_input[VLEN + 1 .. VLEN + 4].* = "'{\"".*;
        line_input[VLEN * 2 - 1] = '\n';
        line_input[VLEN * 2 .. VLEN * 2 + 5].* = "0xf,]".*;
        try expectJson5ImplMatchesScalar(VLEN, &line_input);
    }
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

test "indexJson5 indexes identifiers, strings, hex numbers, and trailing commas" {
    const input = "{key:'value', hex:0x2A, $ok:true, _n:null,}";
    const expected = [_]u32{
        0, 1, 4, 12, 14, 17, 18, 22, 24, 27, 28, 32, 34, 36, 37, 41, 42,
    };

    var index = try indexJson5(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJson5 excludes comments and comment markers in single strings" {
    const input = "{/*'fake':0x1*/real:'//text', trailing:[0Xf,],//x\nnext:'it\\'s'}";
    const expected = [_]u32{
        0, 15, 19, 28, 30, 38, 39, 40, 43, 44, 45, 50, 54, 62,
    };

    var index = try indexJson5(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJson5 carries quote and comment state across SIMD chunks" {
    var input: [137]u8 = @splat(' ');
    input[0] = '[';
    input[1] = '\'';
    input[63] = '\\';
    input[64] = '\'';
    input[65] = '/';
    input[66] = '/';
    input[67] = '\'';
    input[68] = ',';
    input[69] = '0';
    input[70] = 'X';
    input[71] = 'f';
    input[72] = ',';
    input[73] = '/';
    input[74] = '*';
    input[127] = '*';
    input[128] = '/';
    input[129] = ',';
    input[130] = '$';
    input[131] = 'k';
    input[132] = 'e';
    input[133] = 'y';
    input[134] = ':';
    input[135] = '1';
    input[136] = ']';
    const expected = [_]u32{ 0, 68, 69, 72, 129, 130, 134, 135, 136 };

    var index = try indexJson5(testing.allocator, &input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJson5 handles even backslash runs across chunks" {
    var input: [70]u8 = @splat(' ');
    input[0] = '[';
    input[1] = '\'';
    input[62] = '\\';
    input[63] = '\\';
    input[64] = '\'';
    input[65] = '/';
    input[66] = '/';
    input[67] = '[';
    input[68] = '\n';
    input[69] = ']';
    const expected = [_]u32{ 0, 69 };

    var index = try indexJson5(testing.allocator, &input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJson5 handles every short backslash run across a chunk" {
    var input: [72]u8 = @splat(' ');
    for (0..8) |run_length| {
        input = @splat(' ');
        input[0] = '[';
        input[1] = '\'';
        const run_start = 64 - run_length;
        for (run_start..64) |index| {
            input[index] = '\\';
        }
        input[64] = '\'';
        if (run_length % 2 == 0) {
            input[65] = '1';
            input[66] = ']';
        } else {
            input[65] = '\'';
            input[66] = '1';
            input[67] = ']';
        }

        var index = try indexJson5(testing.allocator, &input);
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

test "indexJson5 carries block comment starts across chunks" {
    var input: [72]u8 = @splat(' ');
    input[0] = '[';
    input[62] = '/';
    input[63] = '*';
    input[64] = '{';
    input[68] = '*';
    input[69] = '/';
    input[70] = '0';
    input[71] = ']';
    const expected = [_]u32{ 0, 70, 71 };

    var index = try indexJson5(testing.allocator, &input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJson5 indexes unicode-leading unquoted keys" {
    const input = "{é:1, $ok:0x1A, _n:-0x2b,}";
    const expected = [_]u32{ 0, 1, 3, 4, 5, 7, 10, 11, 15, 17, 19, 20, 25, 26 };

    var index = try indexJson5(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJson5 does not index Unicode whitespace as an atom" {
    const input = [_]u8{
        '{', 'a', ':', 0xc2, 0xa0, '1', ',', 0xe2, 0x80, 0xa8, 'b', ':', '2', '}',
    };
    const expected = [_]u32{ 0, 1, 2, 5, 6, 10, 11, 12, 13 };

    var index = try indexJson5(testing.allocator, &input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJson5 matches scalar for adversarial lexical forms" {
    // The scalar implementation defines lexical precedence for conflicting delimiters.
    const cases = [_][]const u8{
        "",
        "{}",
        "[]",
        "{a:1,}",
        "[0x1A,]",
        "{'url':'http://foo/*bar*/','tail':'*/ // /*'}",
        "{// \" /* */ [ ] { } : , false\nnext:'it\\'s'}",
        "{/* \" // [ ] { } : , false */real:0x1A}",
        "{/* unterminated ' // [ ] { } : , false",
        "{é:1,名字:-0x2b,}",
        "['escaped \\' quote',\"double // /*\",-0X2b,]",
    };

    inline for ([_]usize{ 16, 32, 64 }) |VLEN| {
        for (cases) |input| {
            try expectJson5ImplMatchesScalar(VLEN, input);
        }
    }
}

test "indexJson5 carries block comments across both SIMD boundaries" {
    var input: [136]u8 = @splat(' ');
    for (62..64) |comment_start| {
        for (126..128) |comment_end| {
            input = @splat(' ');
            input[0] = '[';
            input[comment_start] = '/';
            input[comment_start + 1] = '*';
            input[80] = '\'';
            input[81] = '{';
            input[82] = '"';
            input[comment_end] = '*';
            input[comment_end + 1] = '/';
            input[comment_end + 2] = '0';
            input[comment_end + 3] = ']';
            try expectJson5MatchesScalar(&input);
        }
    }
}

test "indexJson5 carries escaped single quotes across a SIMD boundary" {
    var input: [130]u8 = @splat(' ');
    input[0] = '[';
    input[62] = '\'';
    input[63] = '\\';
    input[64] = '\'';
    input[65] = '/';
    input[66] = '/';
    input[67] = '*';
    input[68] = '*';
    input[69] = '/';
    input[126] = '\'';

    input[127] = ',';
    input[128] = '0';
    input[129] = ']';

    try expectJson5MatchesScalar(&input);
}

test "indexJson5 indexes a unicode key across a SIMD boundary" {
    var input: [70]u8 = @splat(' ');
    input[0] = '{';
    input[62] = 0xc3;
    input[63] = 0xa9;
    input[64] = ':';
    input[65] = '1';
    input[66] = ',';
    input[67] = '}';

    try expectJson5MatchesScalar(&input);
}

test "indexJson5 handles unterminated comments and every final chunk length" {
    var input: [130]u8 = @splat(' ');
    input[0] = '[';
    input[62..64].* = "/*".*;
    input[64] = '\'';
    input[65] = '{';
    input[126] = '*';
    input[127] = '/';
    input[128] = '0';
    input[129] = ']';

    for (0..input.len + 1) |input_length| {
        try expectJson5MatchesScalar(input[0..input_length]);
    }
}

test "indexJson5 matches scalar for every backslash run crossing byte 64" {
    var input: [70]u8 = @splat(' ');
    for (0..64) |run_length| {
        input = @splat(' ');
        input[0] = '[';
        input[1] = '\'';
        const run_start = 65 - run_length;
        for (run_start..65) |byte_offset| {
            input[byte_offset] = '\\';
        }
        input[65] = '\'';
        if (run_length % 2 == 0) {
            input[66] = '1';
            input[67] = ']';
        } else {
            input[66] = '\'';
            input[67] = '1';
            input[68] = ']';
        }
        try expectJson5MatchesScalar(&input);
    }
}

test "indexJson5 matches scalar for every byte value" {
    var input: [512]u8 = undefined;
    for (0..input.len) |byte_offset| {
        input[byte_offset] = @as(u8, @truncate(byte_offset));
    }
    inline for ([_]usize{ 16, 32, 64 }) |VLEN| {
        try expectJson5ImplMatchesScalar(VLEN, &input);
    }
}
