const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");

const testing = std.testing;

pub fn indexJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);

    var windows = simd.windows(u8, 64, input, 0);
    var base_offset: usize = 0;
    var prev_in_string = false;
    var prev_ends_in_backslash = false;
    var prev_backslash_run_odd = false;
    var prev_in_atom = false;

    while (base_offset < input.len) {
        const chunk = windows.next().?;
        const valid_count = @min(input.len - base_offset, 64);
        const valid_mask = validByteMask(valid_count);

        const backslashes = simd.matchByte(64, chunk, '\\') & valid_mask;
        const backslash_result = simd.computeBackslashRuns64(
            backslashes,
            prev_ends_in_backslash,
        );
        var odd_backslash_ends = backslash_result.odd_length_ends & valid_mask;
        if (prev_ends_in_backslash) {
            if ((backslashes & 1) == 0) {
                if (prev_backslash_run_odd) {
                    odd_backslash_ends |= 1;
                } else {
                    odd_backslash_ends &= ~@as(u64, 1);
                }
            } else if (prev_backslash_run_odd) {
                odd_backslash_ends ^= leadingRunEndMask(backslashes, valid_count);
            }
        }

        const quotes = simd.matchByte(64, chunk, '"') & valid_mask;
        const unescaped_quotes = quotes & ~odd_backslash_ends;
        const inside_without_closing = simd.prefixXor(u64, unescaped_quotes) ^
            if (prev_in_string) ~@as(u64, 0) else 0;
        const string_mask = inside_without_closing | unescaped_quotes;
        const outside_string = ~string_mask & valid_mask;

        const structural = simd.matchAny4(64, chunk, '{', '}', '[', ']') |
            simd.matchAny2(64, chunk, ':', ',');
        const whitespace = simd.matchAny4(64, chunk, ' ', '\t', '\n', '\r');
        const atom_candidates = simd.matchRange(64, chunk, '0', '9') |
            simd.matchAny4(64, chunk, '-', 't', 'f', 'n');
        const atom_active = outside_string & ~(structural | whitespace | quotes);
        const atom_starts = atom_candidates & atom_active &
            ~((atom_active << 1) | if (prev_in_atom) @as(u64, 1) else 0);
        const record_boundaries = simd.matchByte(64, chunk, '\n');
        const structural_indexes = (structural | atom_starts | record_boundaries) & outside_string;

        indexes.count += simd.extractBitIndexes(
            structural_indexes,
            base_offset,
            indexes.indexes[indexes.count..],
        );

        prev_in_string = (inside_without_closing & (@as(u64, 1) << 63)) != 0;
        prev_ends_in_backslash = valid_count == 64 and
            (backslashes & (@as(u64, 1) << 63)) != 0;
        prev_backslash_run_odd = trailingBackslashRunOdd(
            chunk,
            valid_count,
            prev_backslash_run_odd,
        );
        prev_in_atom = valid_count != 0 and
            (atom_active & (@as(u64, 1) << @as(u6, @intCast(valid_count - 1)))) != 0;
        base_offset += 64;
    }

    return indexes;
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

fn trailingBackslashRunOdd(
    chunk: simd.Vec(64, u8),
    valid_count: usize,
    prev_run_odd: bool,
) bool {
    if (valid_count == 0) return false;
    const bytes: [64]u8 = chunk;
    var run_length: usize = 0;
    var index = valid_count;
    while (index > 0 and bytes[index - 1] == '\\') : (index -= 1) {
        run_length += 1;
    }
    if (index == 0) return (run_length % 2 == 0) == prev_run_odd;
    return run_length % 2 != 0;
}

fn scalarIndexJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var backslash_run_length: usize = 0;
    var prev_in_atom = false;
    for (input, 0..) |byte, index| {
        if (byte == '"' and backslash_run_length % 2 == 0) {
            in_string = !in_string;
        }

        if (!in_string) {
            if (isStructuralByte(byte) or byte == '\n') {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            } else if (isAtomByte(byte) and !prev_in_atom) {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            }
        }

        prev_in_atom = !in_string and byte != '"' and
            !isStructuralByte(byte) and !isWhitespaceByte(byte);
        if (byte == '\\') {
            backslash_run_length += 1;
        } else {
            backslash_run_length = 0;
        }
    }

    return result;
}

fn isWhitespaceByte(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

fn isStructuralByte(byte: u8) bool {
    return switch (byte) {
        '{', '}', '[', ']', ':', ',' => true,
        else => false,
    };
}

fn isAtomByte(byte: u8) bool {
    return switch (byte) {
        '-', 't', 'f', 'n', '0'...'9' => true,
        else => false,
    };
}

fn expectValidIndexes(input_length: usize, indexes: []const u32) !void {
    try testing.expect(indexes.len <= input_length);
    for (indexes, 0..) |index, position| {
        const index_usize: usize = @intCast(index);
        try testing.expect(index_usize < input_length);
        if (position > 0) {
            try testing.expect(indexes[position - 1] < index);
        }
    }
}

fn expectMatchesScalar(input: []const u8) !void {
    var expected = try scalarIndexJsonl(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try expectValidIndexes(input.len, expected.slice());

    var actual = try indexJsonl(testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    try expectValidIndexes(input.len, actual.slice());
}

test "indexJsonl handles empty lines, CRLF, and trailing newlines" {
    const cases = [_][]const u8{
        "",
        "\n",
        "\n\n\n",
        "\r\n",
        "\r\n\n",
        "{\"a\":0}\r\n{\"b\":-0}\n\n",
        " \r\n\t\n",
    };

    for (cases) |input| {
        try expectMatchesScalar(input);
    }
}

test "indexJsonl distinguishes newlines inside and outside strings" {
    const input = "{\"text\":\"first\nsecond\r\nthird\"}\r\n\n{\"n\":1}\n";
    try expectMatchesScalar(input);

    var index = try indexJsonl(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try expectValidIndexes(input.len, index.slice());

    const expected = [_]u32{ 0, 7, 29, 31, 32, 33, 37, 38, 39, 40 };
    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonl handles degenerate records and numeric atom starts" {
    const cases = [_][]const u8{
        "\"\"",
        "\"",
        "'",
        "{",
        "}",
        "[",
        "]",
        ":",
        ",",
        "-123.45e+6\n0\r\n-0\n1E10",
    };

    for (cases) |input| {
        try expectMatchesScalar(input);
    }

    const numeric_input = "-123.45e+6\n0\r\n-0\n1E10";
    var index = try indexJsonl(testing.allocator, numeric_input);
    defer index.deinit(testing.allocator);
    try expectValidIndexes(numeric_input.len, index.slice());
}

test "indexJsonl handles alternating backslash runs around chunk boundaries" {
    const boundary_offsets = [_]usize{ 62, 63, 64, 65 };

    for (boundary_offsets) |run_start| {
        for (1..130) |run_length| {
            var input: [260]u8 = @splat(' ');
            input[0] = '[';
            input[1] = '"';
            for (run_start..run_start + run_length) |offset| {
                input[offset] = '\\';
            }

            const quote_offset = run_start + run_length;
            input[quote_offset] = '"';
            var next_offset = quote_offset + 1;
            if (run_length % 2 != 0) {
                input[next_offset] = '"';
                next_offset += 1;
            }
            input[next_offset] = '0';
            input[next_offset + 1] = ']';
            input[next_offset + 2] = '\n';
            try expectMatchesScalar(input[0 .. next_offset + 3]);
        }
    }

    for (boundary_offsets) |quote_offset| {
        for (0..10) |run_length| {
            var input: [100]u8 = @splat(' ');
            input[0] = '[';
            input[1] = '"';
            const run_start = quote_offset - run_length;
            for (run_start..quote_offset) |offset| {
                input[offset] = '\\';
            }

            input[quote_offset] = '"';
            var next_offset = quote_offset + 1;
            if (run_length % 2 != 0) {
                input[next_offset] = '"';
                next_offset += 1;
            }
            input[next_offset] = '0';
            input[next_offset + 1] = ']';
            input[next_offset + 2] = '\n';
            try expectMatchesScalar(input[0 .. next_offset + 3]);
        }
    }
}

test "indexJsonl preserves unterminated string state at boundary EOFs" {
    const lengths = [_]usize{ 62, 63, 64, 65, 66 };
    for (lengths) |length| {
        var input: [66]u8 = @splat(' ');
        input[0] = '"';
        input[length - 1] = '\n';
        try expectMatchesScalar(input[0..length]);
    }
}

test "indexJsonl indexes each unquoted record boundary" {
    const input = "{\"a\":1}\n{\"b\":2}\n";
    const expected = [_]u32{ 0, 4, 5, 6, 7, 8, 12, 13, 14, 15 };

    var index = try indexJsonl(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
    try expectValidIndexes(input.len, index.slice());
}

test "indexJsonl emits one start for each complete numeric atom" {
    const input = "1.2\n3e4\n-5.6e-7\n";
    const expected = [_]u32{ 0, 3, 4, 7, 8, 15 };

    var index = try indexJsonl(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &expected, index.slice());
    try expectValidIndexes(input.len, index.slice());
}

test "indexJsonl ignores newlines inside strings" {
    try expectMatchesScalar("{\"text\":\"first\nsecond\"}\n{\"n\":null}\n");
}

test "indexJsonl matches scalar reference across SIMD chunks" {
    var input: [132]u8 = @splat(' ');
    input[0] = '[';
    input[1] = '"';
    input[63] = '\\';
    input[64] = '"';
    input[92] = '"';
    input[93] = ']';
    input[94] = '\n';
    input[95] = '{';
    input[96] = '"';
    input[97] = 'n';
    input[98] = '"';
    input[99] = ':';
    input[100] = '0';
    input[101] = '}';
    input[102] = '\n';
    try expectMatchesScalar(&input);
}

test "indexJsonl differential adversarial byte matrix" {
    const alphabet = [_]u8{
        '{',  '}',  '[', ']', ':', ',', '"', '\\', '-', 't', 'f', 'n',
        '0',  '1',  '2', '3', '4', '5', '6', '7',  '8', '9', ' ', '\t',
        '\r', '\n', '.', '+', '/', 'a', 'x',
    };
    const boundary_lengths = [_]usize{
        0, 1, 2, 61, 62, 63, 64, 65, 66, 127, 128, 129, 191, 192, 193, 255, 256, 257,
    };
    var state: u64 = 0xbb67ae8584caa73b;
    var input: [257]u8 = undefined;

    for (0..512) |case_index| {
        const length = if (case_index < boundary_lengths.len)
            boundary_lengths[case_index]
        else
            @as(usize, @intCast(state % 258));

        for (0..length) |offset| {
            state = state *% 0x9e3779b97f4a7c15 +% 0xbb67ae8584caa73b;
            const alphabet_index: usize = @intCast(state % @as(u64, alphabet.len));
            input[offset] = alphabet[alphabet_index];
        }
        try expectMatchesScalar(input[0..length]);
    }
}

test "refAllDecls" {
    testing.refAllDecls(@This());
    _ = simd;
}
