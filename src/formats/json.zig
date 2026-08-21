const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const stream = @import("../core/stream.zig");
const ondemand = @import("../core/ondemand.zig");
const stage2 = @import("../core/stage2.zig");

const testing = std.testing;
const sentinel_count: usize = 3;

/// Initializes a chunk-fed RFC JSON Stage 1 indexer in document mode.
pub fn initStreamIndexer(
    allocator: std.mem.Allocator,
    chunk_len: usize,
) stream.StreamIndexer.InitError!stream.StreamIndexer {
    return stream.StreamIndexer.init(
        allocator,
        chunk_len,
        stream.Options{ .dialect = .json, .mode = .document },
    );
}

/// Builds an on-demand document backed by parser-owned structural storage.
///
/// The input must outlive the returned document.
pub fn initOnDemandDocument(
    parser: *ondemand.Parser,
    input: []const u8,
) !ondemand.Document {
    const indexes = try parser.prepareDocument(input);
    const token_count = try indexJsonInto(simd.default_vector_len, indexes, input);
    return parser.completeDocument(input, token_count);
}

test "on-demand JSON reuses parser-owned indexes without scratch allocation" {
    const input = "{\"a\":[0,1,2,3,4,5,6,7,8,9]}";
    const index_bytes = (input.len + sentinel_count) * @sizeOf(u32);
    var storage: [index_bytes + 16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);

    var parser = try ondemand.Parser.init(fixed.allocator(), input.len);
    defer parser.deinit();
    const indexes_pointer = parser.indexes.ptr;

    {
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        try testing.expectEqual(@as(u32, @intCast(input.len)), document.indexes[document.token_count]);
        try testing.expectEqual(
            @as(u32, @intCast(input.len)),
            document.indexes[document.token_count + 1],
        );
        try testing.expectEqual(@as(u32, 0), document.indexes[document.token_count + 2]);
    }

    {
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        try testing.expectEqual(@intFromPtr(indexes_pointer), @intFromPtr(parser.indexes.ptr));
    }
}

test "on-demand JSON grows in place without a temporary index" {
    const input = "[0,1,2,3,4,5,6,7,8,9]";
    const initial_bytes = sentinel_count * @sizeOf(u32);
    const grown_bytes = (input.len + sentinel_count) * @sizeOf(u32);
    var storage: [initial_bytes + grown_bytes + 16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);

    var parser = try ondemand.Parser.init(fixed.allocator(), 0);
    defer parser.deinit();
    {
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
    }
    const grown_indexes_pointer = parser.indexes.ptr;

    {
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
    }
    try testing.expectEqual(@intFromPtr(grown_indexes_pointer), @intFromPtr(parser.indexes.ptr));
}

test "on-demand JSON grow policy survives parser resize" {
    const first_input = "[0,1,2]";
    const second_input = "[0,1,2,3,4,5,6,7,8,9]";

    var parser = try ondemand.Parser.init(testing.allocator, 0);
    defer parser.deinit();

    {
        var document = try initOnDemandDocument(&parser, first_input);
        defer document.deinit();
    }
    const first_capacity = parser.capacity;

    {
        var document = try initOnDemandDocument(&parser, second_input);
        defer document.deinit();
    }

    try testing.expect(parser.grow_on_demand);
    try testing.expect(parser.capacity > first_capacity);
}

/// Builds an owned, validated RFC JSON tape from the Stage1 structural index.
pub fn buildJsonTape(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage2.BuildError!stage2.Document {
    var structural_index = indexJson(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // Stage1 cannot represent inputs that Stage2 cannot address on its tape.
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);
    return stage2.buildTape(allocator, input, &structural_index, .json);
}

/// Validates RFC JSON and returns the first semantic diagnostic, if any.
pub fn validateJson(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage2.ValidationError!?stage2.Diagnostic {
    var structural_index = indexJson(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);
    return stage2.validate(input, &structural_index, .json);
}

pub fn indexJson(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage1.StructuralIndex.InitError!stage1.StructuralIndex {
    return indexJsonImpl(simd.default_vector_len, allocator, input);
}

pub fn indexJsonImpl(
    comptime VLEN: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) stage1.StructuralIndex.InitError!stage1.StructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);

    indexes.count = indexJsonInto(
        VLEN,
        indexes.indexes[0 .. indexes.indexes.len - sentinel_count],
        input,
    ) catch |err| switch (err) {
        error.CapacityExceeded => unreachable,
        error.InputTooLarge => return error.InputTooLarge,
    };
    try indexes.finish(input.len);
    return indexes;
}

fn indexJsonInto(
    comptime VLEN: usize,
    indexes: []u32,
    input: []const u8,
) !usize {
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);

    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var windows = simd.windows(u8, VLEN, input, 0);
    var base_offset: usize = 0;
    var index_count: usize = 0;
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
        if (candidate_count > indexes.len - index_count) return error.CapacityExceeded;
        @memcpy(
            indexes[index_count..][0..candidate_count],
            candidate_indexes[0..candidate_count],
        );
        index_count += candidate_count;

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

    return index_count;
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

test "indexJson matches scalar for sparse and dense masks at wide widths" {
    inline for ([_]usize{ 16, 32, 64, 128, 256, 512 }) |vlen| {
        const input_length = 2 * vlen + 3;

        var sparse: [2 * 512 + 3]u8 = @splat(' ');
        sparse[0] = '{';
        sparse[vlen - 1] = '[';
        sparse[vlen] = ']';
        sparse[vlen + 1] = ':';
        sparse[2 * vlen - 1] = ',';
        sparse[2 * vlen] = '}';
        sparse[input_length - 1] = 'n';
        try expectMatchesScalarAtWidth(vlen, sparse[0..input_length]);

        const structural_bytes = "{[,:]}";
        var dense: [2 * 512 + 3]u8 = undefined;
        for (dense[0..input_length], 0..) |*byte, offset| {
            byte.* = structural_bytes[offset % structural_bytes.len];
        }
        try expectMatchesScalarAtWidth(vlen, dense[0..input_length]);
    }
}

test "indexJson matches scalar for quote runs crossing wide boundaries" {
    inline for ([_]usize{ 16, 32, 64, 128, 256, 512 }) |vlen| {
        inline for ([_]usize{ vlen, 2 * vlen }) |boundary| {
            for (4..10) |run_length| {
                var input: [2 * 512 + 16]u8 = @splat(' ');
                input[0] = '[';

                const run_start = boundary - 3;
                for (run_start..run_start + run_length) |offset| {
                    input[offset] = '"';
                }

                var next_offset = run_start + run_length;
                if (run_length % 2 != 0) {
                    input[next_offset] = '"';
                    next_offset += 1;
                }
                input[next_offset] = '0';
                input[next_offset + 1] = ']';
                try expectMatchesScalarAtWidth(vlen, input[0 .. next_offset + 2]);
            }
        }
    }
}

test "indexJson matches scalar for backslash runs crossing wide boundaries" {
    inline for ([_]usize{ 16, 32, 64, 128, 256, 512 }) |vlen| {
        inline for ([_]usize{ vlen, 2 * vlen }) |boundary| {
            for (1..5) |left_count| {
                for (1..5) |right_count| {
                    var input: [2 * 512 + 16]u8 = @splat(' ');
                    input[0] = '[';
                    input[1] = '"';

                    const run_start = boundary - left_count;
                    const quote_offset = boundary + right_count;
                    for (run_start..quote_offset) |offset| {
                        input[offset] = '\\';
                    }
                    input[quote_offset] = '"';

                    var next_offset = quote_offset + 1;
                    if ((left_count + right_count) % 2 != 0) {
                        input[next_offset] = '"';
                        next_offset += 1;
                    }
                    input[next_offset] = '0';
                    input[next_offset + 1] = ']';
                    try expectMatchesScalarAtWidth(vlen, input[0 .. next_offset + 2]);
                }
            }
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

test "buildJsonTape returns a validated owned tape" {
    const input = "{\"ok\":true}";
    var document = try buildJsonTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    const expected_kinds = [_]stage2.TapeKind{
        .object_start,
        .key,
        .true_literal,
        .object_end,
    };
    try testing.expectEqual(expected_kinds.len, document.tape.len);
    for (document.tape, expected_kinds) |word, expected_kind| {
        try testing.expectEqual(expected_kind, word.tapeKind());
    }
    try testing.expectEqual(@as(u24, 1), document.tape[0].payload);
    try testing.expectEqual(@as(u32, 1), document.tape[1].offset);
    try testing.expectEqual(@as(u32, 6), document.tape[2].offset);
}

test "buildJsonTape Document.root borrows exact input while document stays alive" {
    const input =
        \\{"a\n":"x\u0041","number":-12.5e+2,"enabled":false,"missing":null}
    ;
    var document = try buildJsonTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    try cursor.advance();

    const raw_key = try cursor.rawValue();
    try testing.expectEqualStrings("a\\n", raw_key);
    try testing.expect(
        raw_key.ptr ==
            input.ptr + @as(usize, document.tape[cursor.position()].offset) + 1,
    );

    try cursor.advance();
    const raw_string = try cursor.rawValue();
    try testing.expectEqualStrings("x\\u0041", raw_string);
    try testing.expect(
        raw_string.ptr ==
            input.ptr + @as(usize, document.tape[cursor.position()].offset) + 1,
    );

    try cursor.advance();
    try cursor.advance();
    const raw_number = try cursor.rawValue();
    try testing.expectEqualStrings("-12.5e+2", raw_number);
    try testing.expect(
        raw_number.ptr == input.ptr + @as(usize, document.tape[cursor.position()].offset),
    );

    try cursor.advance();
    try cursor.advance();
    const raw_bool = try cursor.rawValue();
    try testing.expectEqualStrings("false", raw_bool);
    try testing.expect(
        raw_bool.ptr == input.ptr + @as(usize, document.tape[cursor.position()].offset),
    );

    try cursor.advance();
    try cursor.advance();
    const raw_null = try cursor.rawValue();
    try testing.expectEqualStrings("null", raw_null);
    try testing.expect(
        raw_null.ptr == input.ptr + @as(usize, document.tape[cursor.position()].offset),
    );
}

test "buildJsonTape rejects invalid RFC JSON grammar" {
    try testing.expectError(
        error.TrailingComma,
        buildJsonTape(testing.allocator, "[1,]"),
    );
}

test "validateJson returns first diagnostic with source location" {
    try testing.expect((try validateJson(testing.allocator, "{}")) == null);

    const malformed_escape = "\n  [\"bad\\q\"]";
    const escape_diagnostic = (try validateJson(
        testing.allocator,
        malformed_escape,
    )).?;
    try testing.expectEqual(error.InvalidEscape, escape_diagnostic.err);
    try testing.expectEqual(@as(usize, 9), escape_diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), escape_diagnostic.line);
    try testing.expectEqual(@as(u32, 9), escape_diagnostic.column);
    try testing.expectEqual(@as(usize, 1), escape_diagnostic.snippet_start);
    try testing.expectEqualStrings("  [\"bad\\q\"]", escape_diagnostic.snippet);

    const unclosed_array = "\n  [1";
    const array_diagnostic = (try validateJson(
        testing.allocator,
        unclosed_array,
    )).?;
    try testing.expectEqual(error.UnclosedArray, array_diagnostic.err);
    try testing.expectEqual(@as(usize, 3), array_diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), array_diagnostic.line);
    try testing.expectEqual(@as(u32, 3), array_diagnostic.column);
    try testing.expectEqualStrings("  [1", array_diagnostic.snippet);

    const unclosed_object = "\n {\"a\": 1";
    const object_diagnostic = (try validateJson(
        testing.allocator,
        unclosed_object,
    )).?;
    try testing.expectEqual(error.UnclosedObject, object_diagnostic.err);
    try testing.expectEqual(@as(usize, 2), object_diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), object_diagnostic.line);
    try testing.expectEqual(@as(u32, 2), object_diagnostic.column);
    try testing.expectEqualStrings(" {\"a\": 1", object_diagnostic.snippet);
}

test "refAllDecls" {
    testing.refAllDecls(@This());
    _ = simd;
}

fn expectJsonStreamIndexEqual(
    expected: *const stage1.StructuralIndex,
    actual: *const stage1.StructuralIndex,
) !void {
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + sentinel_count],
        actual.indexes[0 .. actual.count + sentinel_count],
    );
}

fn feedJsonStream(
    input: []const u8,
    split: usize,
    chunk_len: usize,
) !stage1.StructuralIndex {
    var indexer = try initStreamIndexer(testing.allocator, chunk_len);
    defer indexer.deinit();

    try indexer.feed(input[0..split]);
    try indexer.feed("");
    try indexer.feed(input[split..]);
    try indexer.finish();
    try indexer.finish();
    return indexer.take();
}

test "JSON stream wrapper matches one-shot at every partition and byte feed" {
    const input = "{\"alpha\":[true,false,null,-42],\"text\":\"a\\\\\\\"b\"}";
    var expected = try indexJson(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    for (0..input.len + 1) |split| {
        var actual = try feedJsonStream(input, split, 3);
        defer actual.deinit(testing.allocator);
        try expectJsonStreamIndexEqual(&expected, &actual);
    }

    var byte_indexer = try initStreamIndexer(testing.allocator, 1);
    defer byte_indexer.deinit();
    for (input) |byte| {
        try byte_indexer.feed(&.{byte});
    }
    try byte_indexer.finish();
    var byte_actual = byte_indexer.take();
    defer byte_actual.deinit(testing.allocator);
    try expectJsonStreamIndexEqual(&expected, &byte_actual);
}

test "JSON stream wrapper reset and finish lifecycle preserve document offsets" {
    const first_input = "{\"first\":true}";
    const second_input = "[-1,null]";
    var indexer = try initStreamIndexer(testing.allocator, 2);
    defer indexer.deinit();

    try indexer.feed(first_input);
    try indexer.finish();
    try indexer.finish();
    try testing.expectError(error.AlreadyFinished, indexer.feed("0"));
    var first = indexer.take();
    defer first.deinit(testing.allocator);

    indexer.reset();
    try indexer.feed(second_input[0..2]);
    try indexer.feed(second_input[2..]);
    try indexer.finish();
    var second = indexer.take();
    defer second.deinit(testing.allocator);

    var expected_first = try indexJson(testing.allocator, first_input);
    defer expected_first.deinit(testing.allocator);
    var expected_second = try indexJson(testing.allocator, second_input);
    defer expected_second.deinit(testing.allocator);
    try expectJsonStreamIndexEqual(&expected_first, &first);
    try expectJsonStreamIndexEqual(&expected_second, &second);
}
