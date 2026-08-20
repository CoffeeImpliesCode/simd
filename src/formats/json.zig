const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");

const testing = std.testing;

pub fn indexJson(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    return indexJsonImpl(simd.default_vector_len, allocator, input);
}

pub fn indexJsonImpl(
    comptime VLEN: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);

    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);

    var windows = simd.windows(u8, VLEN, input, 0);
    var base_offset: usize = 0;
    var prev_in_string = false;
    var prev_ends_in_backslash = false;
    var prev_backslash_run_odd = false;
    var prev_in_atom = false;

    while (base_offset < input.len) {
        const chunk = windows.next().?;
        const valid_count = @min(input.len - base_offset, VLEN);
        const valid_mask = validByteMask(VLEN, valid_count);
        const top_bit: Mask = @as(Mask, 1) << @as(Shift, @intCast(VLEN - 1));

        const backslashes: Mask = simd.matchByte(VLEN, chunk, '\\') & valid_mask;
        const backslash_result = simd.computeBackslashRuns(
            Mask,
            backslashes,
            prev_ends_in_backslash,
        );
        var odd_backslash_ends = backslash_result.odd_length_ends & valid_mask;
        if (prev_ends_in_backslash) {
            if ((backslashes & @as(Mask, 1)) == 0) {
                if (prev_backslash_run_odd) {
                    odd_backslash_ends |= 1;
                } else {
                    odd_backslash_ends &= ~@as(Mask, 1);
                }
            } else if (prev_backslash_run_odd) {
                odd_backslash_ends ^= leadingRunEndMask(VLEN, backslashes, valid_count);
            }
        }

        const quotes: Mask = simd.matchByte(VLEN, chunk, '"') & valid_mask;
        const unescaped_quotes = quotes & ~odd_backslash_ends;
        const inside_without_closing = simd.prefixXor(Mask, unescaped_quotes) ^
            if (prev_in_string) ~@as(Mask, 0) else 0;
        const opening_quotes = unescaped_quotes & inside_without_closing;
        const string_mask = inside_without_closing | unescaped_quotes;
        const outside_string = ~string_mask & valid_mask;

        const structural: Mask = simd.matchAny4(VLEN, chunk, '{', '}', '[', ']') |
            simd.matchAny2(VLEN, chunk, ':', ',');
        const whitespace: Mask = simd.matchAny4(VLEN, chunk, ' ', '\t', '\n', '\r');
        const atom_candidates: Mask = simd.matchRange(VLEN, chunk, '0', '9') |
            simd.matchAny4(VLEN, chunk, '-', 't', 'f', 'n');
        const atom_active = outside_string & ~(structural | whitespace | quotes);
        const atom_starts = atom_candidates & atom_active &
            ~((atom_active << @as(Shift, 1)) |
                if (prev_in_atom) @as(Mask, 1) else 0);
        const structural_indexes = ((structural | atom_starts) & outside_string) |
            opening_quotes;
        var candidate_indexes: [VLEN]u32 = undefined;
        const candidate_count = simd.extractBitIndexes(
            Mask,
            structural_indexes,
            base_offset,
            &candidate_indexes,
        );
        @memcpy(
            indexes.indexes[indexes.count..][0..candidate_count],
            candidate_indexes[0..candidate_count],
        );
        indexes.count += candidate_count;

        prev_in_string = (inside_without_closing & top_bit) != 0;
        prev_ends_in_backslash = valid_count == VLEN and
            (backslashes & top_bit) != 0;
        prev_backslash_run_odd = trailingBackslashRunOdd(
            VLEN,
            chunk,
            valid_count,
            prev_backslash_run_odd,
        );
        prev_in_atom = valid_count != 0 and
            (atom_active & (@as(Mask, 1) <<
                @as(Shift, @intCast(valid_count - 1)))) != 0;
        base_offset += VLEN;
    }

    try indexes.finish(input.len);
    return indexes;
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

fn scalarIndexJson(
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
            if (!in_string) {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            }
            in_string = !in_string;
        } else if (!in_string) {
            if (isStructuralByte(byte)) {
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

    try result.finish(input.len);
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
    return expectMatchesScalarAtWidth(simd.default_vector_len, input);
}

fn expectMatchesScalarAtWidth(comptime VLEN: usize, input: []const u8) !void {
    var expected = try scalarIndexJson(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try expectValidIndexes(input.len, expected.slice());

    var actual = try indexJsonImpl(VLEN, testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    try expectValidIndexes(input.len, actual.slice());
}

test "indexJson matches scalar at all SIMD widths" {
    const cases = [_][]const u8{
        "",
        "{}",
        "{\"id\":-12,\"ok\":true,\"none\":null,\"bad\":false}",
        "{\"text\":\"{ [ ] } : , - 012 tfn\",\"value\":0}",
        "[\"escaped quote: \\\" and slash: \\\\\",0]",
        "\"unterminated",
        "\"{[:]}:,-123.45e+6",
        "-123.45e+6 0 -0 1E10",
    };

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        for (cases) |input| {
            try expectMatchesScalarAtWidth(vlen, input);
        }
    }
}

test "indexJson width differential covers vector boundaries" {
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        for (boundary_lengths) |length| {
            var input: [66]u8 = @splat(' ');
            if (length > 0) {
                input[length - 1] = 'n';
            }
            try expectMatchesScalarAtWidth(vlen, input[0..length]);
        }
    }
}

test "indexJson matches scalar structural indexes" {
    // The scalar implementation defines the byte-exact Stage 1 contract.
    const cases = [_][]const u8{
        "",
        "{}",
        "{\"id\":-12,\"ok\":true,\"none\":null,\"bad\":false}",
        "{\"text\":\"{ [ ] } : , - 012 tfn\",\"value\":0}",
        "[\"escaped quote: \\\" and slash: \\\\\",0]",
    };

    for (cases) |input| {
        try expectMatchesScalar(input);
    }
}

test "indexJson emits one start per atom" {
    const input = "true false 123 -45";
    const expected = [_]u32{ 0, 5, 11, 15 };

    var index = try indexJson(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJson emits one start for decimal and exponent atoms" {
    const input = "1.2 3e4 -5.6e-7";
    const expected = [_]u32{ 0, 4, 8 };

    var index = try indexJson(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJson handles short backslash runs crossing a chunk" {
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
        try expectMatchesScalar(&input);
    }
}

test "indexJson preserves quote and backslash state across chunks" {
    // Both odd and even trailing runs exercise the state carried through byte 64.
    var odd_run_input: [130]u8 = @splat('x');
    odd_run_input[0] = '[';
    odd_run_input[1] = '"';
    odd_run_input[63] = '\\';
    odd_run_input[64] = '"';
    odd_run_input[100] = '"';
    odd_run_input[129] = ']';
    try expectMatchesScalar(&odd_run_input);

    var even_run_input: [67]u8 = @splat('x');
    even_run_input[0] = '[';
    even_run_input[1] = '"';
    even_run_input[62] = '\\';
    even_run_input[63] = '\\';
    even_run_input[64] = '"';
    even_run_input[65] = '1';
    even_run_input[66] = ']';
    try expectMatchesScalar(&even_run_input);
}

test "indexJson ignores padded bytes at final chunk boundaries" {
    // These lengths cover both sides of a full 64-byte SIMD window.
    var input_63: [63]u8 = @splat(' ');
    input_63[62] = 'n';
    try expectMatchesScalar(&input_63);

    var input_64: [64]u8 = @splat(' ');
    input_64[63] = 'n';
    try expectMatchesScalar(&input_64);

    var input_65: [65]u8 = @splat(' ');
    input_65[64] = 'n';
    try expectMatchesScalar(&input_65);
}

test "indexJson handles empty degenerate and unterminated documents" {
    const cases = [_][]const u8{
        "",
        "\"\"",
        " ",
        "\t\r\n",
        "\"",
        "'",
        "{",
        "}",
        "[",
        "]",
        ":",
        ",",
        "\"unterminated",
        "\"{[:]}:,-123.45e+6",
    };

    for (cases) |input| {
        try expectMatchesScalar(input);
    }
}

test "indexJson emits opening quotes and excludes string contents and closing quotes" {
    const outside = "{[:]}:,";
    const outside_expected = [_]u32{ 0, 1, 2, 3, 4, 5, 6 };

    var outside_index = try indexJson(testing.allocator, outside);
    defer outside_index.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &outside_expected, outside_index.slice());
    try expectValidIndexes(outside.len, outside_index.slice());

    const quoted = "[\"x\",\"\"]";
    const quoted_expected = [_]u32{ 0, 1, 4, 5, 7 };
    var quoted_index = try indexJson(testing.allocator, quoted);
    defer quoted_index.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &quoted_expected, quoted_index.slice());
    try expectValidIndexes(quoted.len, quoted_index.slice());

    try expectMatchesScalar("\"{[:]}:,\"");
    try expectMatchesScalar("{\"inside\":\"{[:]}:,\",\"outside\":[0]}");
}

test "indexJson indexes complete numeric atoms once" {
    const input = "-123.45e+6 0 -0 1E10";
    const expected = [_]u32{ 0, 11, 13, 16 };

    var index = try indexJson(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &expected, index.slice());
    try expectValidIndexes(input.len, index.slice());
    try expectMatchesScalar(input);
}

test "indexJson handles alternating backslash runs around chunk boundaries" {
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
            try expectMatchesScalar(input[0 .. next_offset + 2]);
        }
    }

    for (boundary_offsets) |quote_offset| {
        for (0..10) |run_length| {
            var input: [96]u8 = @splat(' ');
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
            try expectMatchesScalar(input[0 .. next_offset + 2]);
        }
    }
}

test "indexJson preserves unterminated string state at boundary EOFs" {
    const lengths = [_]usize{ 62, 63, 64, 65, 66 };
    for (lengths) |length| {
        var input: [66]u8 = @splat(' ');
        input[0] = '"';
        input[length - 1] = '{';
        try expectMatchesScalar(input[0..length]);
    }
}

test "indexJson differential adversarial byte matrix" {
    const alphabet = [_]u8{
        '{',  '}',  '[', ']', ':', ',', '"', '\\', '-', 't', 'f', 'n',
        '0',  '1',  '2', '3', '4', '5', '6', '7',  '8', '9', ' ', '\t',
        '\r', '\n', '.', '+', '/', 'a', 'x',
    };
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        var state: u64 = 0x6a09e667f3bcc909;
        var input: [257]u8 = undefined;

        for (0..512) |case_index| {
            const length = if (case_index < boundary_lengths.len)
                boundary_lengths[case_index]
            else
                @as(usize, @intCast(state % 258));

            for (0..length) |offset| {
                state = state *% 0x9e3779b97f4a7c15 +% 0x6a09e667f3bcc909;
                const alphabet_index: usize = @intCast(state % @as(u64, alphabet.len));
                input[offset] = alphabet[alphabet_index];
            }
            try expectMatchesScalarAtWidth(vlen, input[0..length]);
        }
    }
}

test "refAllDecls" {
    testing.refAllDecls(@This());
    _ = simd;
}
