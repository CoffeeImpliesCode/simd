const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const stream = @import("../core/stream.zig");
const stage2 = @import("../core/stage2.zig");
const ondemand = @import("../core/ondemand.zig");
const lexical = @import("../core/json_lexical.zig");
const testing = std.testing;
const sentinel_count: usize = 3;

const IndexSink = struct {
    indexes: []u32,
    count: usize = 0,

    pub fn appendOffset(self: *@This(), offset: usize) lexical.Error!void {
        if (offset > std.math.maxInt(u32)) return error.InputTooLarge;
        if (self.count >= self.indexes.len) return error.CapacityExceeded;
        self.indexes[self.count] = @intCast(offset);
        self.count += 1;
    }

    pub fn appendMask(
        self: *@This(),
        comptime T: type,
        mask: T,
        base_offset: usize,
    ) lexical.Error!void {
        const output = self.indexes[self.count..];
        const written = try simd.extractBitIndexesChecked(
            T,
            mask,
            base_offset,
            output,
        );
        self.count += written;
    }
};

/// Initializes a chunk-fed JSONC Stage 1 indexer in document mode.
pub fn initStreamIndexer(
    allocator: std.mem.Allocator,
    chunk_len: usize,
) stream.StreamIndexer.InitError!stream.StreamIndexer {
    return stream.StreamIndexer.init(
        allocator,
        chunk_len,
        stream.Options{ .dialect = .jsonc, .mode = .document },
    );
}
/// Initializes a lazy JSONC document over parser-owned indexes.
pub fn initOnDemandDocument(
    parser: *ondemand.Parser,
    input: []const u8,
) !ondemand.Document {
    const indexes = try parser.prepareDocument(input);
    const token_count = try indexJsoncInto(simd.default_vector_len, indexes, input);
    return parser.completeDialectDocument(input, token_count, .jsonc);
}

pub fn indexJsonc(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    return indexJsoncImpl(simd.default_vector_len, allocator, input);
}

/// Builds an owned, validated JSONC tape from the Stage1 structural index.
pub fn buildJsoncTape(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage2.BuildError!stage2.Document {
    var structural_index = indexJsonc(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);
    return stage2.buildTape(allocator, input, &structural_index, .jsonc);
}

/// Validates JSONC and returns the first semantic diagnostic, if any.
pub fn validateJsonc(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage2.ValidationError!?stage2.Diagnostic {
    var structural_index = indexJsonc(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);
    return stage2.validate(input, &structural_index, .jsonc);
}

pub fn indexJsoncInto(
    comptime VLEN: usize,
    indexes: []u32,
    input: []const u8,
) lexical.Error!usize {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var sink = IndexSink{ .indexes = indexes };
    var state: lexical.State = .{};
    lexical.feed(VLEN, .jsonc, &state, input, 0, &sink) catch |err| switch (err) {
        error.NonContiguousInput => unreachable,
        error.CapacityExceeded => return error.CapacityExceeded,
        error.InputTooLarge => return error.InputTooLarge,
    };
    lexical.finish(.jsonc, &state, &sink) catch |err| switch (err) {
        error.NonContiguousInput => unreachable,
        error.CapacityExceeded => return error.CapacityExceeded,
        error.InputTooLarge => return error.InputTooLarge,
    };
    return sink.count;
}

pub fn indexJsoncImpl(
    comptime VLEN: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    result.count = indexJsoncInto(
        VLEN,
        result.indexes[0 .. result.indexes.len - sentinel_count],
        input,
    ) catch |err| switch (err) {
        error.CapacityExceeded => unreachable,
        error.NonContiguousInput => unreachable,
        error.InputTooLarge => return error.InputTooLarge,
    };
    try result.finish(input.len);
    return result;
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
    var skip_comment_byte = false;
    var previous_in_atom = false;
    var backslash_run_length: usize = 0;

    for (input, 0..) |byte, byte_offset| {
        const unescaped_quote = byte == '"' and backslash_run_length % 2 == 0;

        if (skip_comment_byte) {
            skip_comment_byte = false;
        } else if (in_string) {
            if (unescaped_quote) {
                in_string = false;
                previous_in_atom = false;
            }
        } else if (in_single_comment) {
            if (byte == '\n' or byte == '\r') {
                in_single_comment = false;
                previous_in_atom = false;
            }
        } else if (in_multi_comment) {
            if (byte == '*' and byte_offset + 1 < input.len and
                input[byte_offset + 1] == '/')
            {
                in_multi_comment = false;
                previous_in_atom = false;
                skip_comment_byte = true;
            }
        } else if (unescaped_quote) {
            in_string = true;
            previous_in_atom = false;
        } else if (byte == '/' and byte_offset + 1 < input.len) {
            const next_byte = input[byte_offset + 1];
            if (next_byte == '/') {
                in_single_comment = true;
                previous_in_atom = false;
            } else if (next_byte == '*') {
                in_multi_comment = true;
                skip_comment_byte = true;
                previous_in_atom = false;
            } else {
                previous_in_atom = !isJsoncWhitespace(byte);
            }
        } else if (isJsoncStructuralByte(byte)) {
            result.indexes[result.count] = @intCast(byte_offset);
            result.count += 1;
            previous_in_atom = false;
        } else if (isJsoncAtomByte(byte)) {
            if (!previous_in_atom) {
                result.indexes[result.count] = @intCast(byte_offset);
                result.count += 1;
            }
            previous_in_atom = true;
        } else {
            previous_in_atom = !isJsoncWhitespace(byte);
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

fn isJsoncWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
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

    inline for ([_]usize{ 4, 5, 7, 16, 32, 64 }) |vlen| {
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

    inline for ([_]usize{ 4, 5, 7, 16, 32, 64 }) |vlen| {
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

test "JSONC Stage2 builds comments and exposes raw values" {
    const input = "{/* leading */\"name\": [1, // line\n true]}";
    var document = try buildJsoncTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    try testing.expectEqual(stage2.TapeKind.object_start, (try cursor.peek()).tapeKind());
    try cursor.advance();
    const raw_name = try cursor.rawValue();
    try testing.expectEqualStrings("name", raw_name);
    try testing.expect(
        raw_name.ptr ==
            input.ptr + @as(usize, document.tape[cursor.position()].offset) + 1,
    );
    try cursor.advance();
    try cursor.advance();
    try testing.expectEqualStrings("1", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqual(stage2.TapeKind.true_literal, (try cursor.peek()).tapeKind());
    try testing.expect((try validateJsonc(testing.allocator, input)) == null);
}

test "JSONC Stage2 reports dialect diagnostics" {
    const single_quote = try validateJsonc(testing.allocator, "{'a':1}");
    if (single_quote) |diagnostic| {
        try testing.expectEqual(error.UnexpectedToken, diagnostic.err);
        try testing.expectEqual(@as(usize, 1), diagnostic.byte_offset);
    } else {
        return error.ExpectedDiagnostic;
    }

    const trailing_comma = try validateJsonc(testing.allocator, "{\"a\":1,}");
    if (trailing_comma) |diagnostic| {
        try testing.expectEqual(error.TrailingComma, diagnostic.err);
        try testing.expectEqual(@as(usize, 7), diagnostic.byte_offset);
    } else {
        return error.ExpectedDiagnostic;
    }

    const unterminated_comment = try validateJsonc(testing.allocator, "/*");
    if (unterminated_comment) |diagnostic| {
        try testing.expectEqual(@as(usize, 0), diagnostic.byte_offset);
    } else {
        return error.ExpectedDiagnostic;
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

    inline for ([_]usize{ 4, 5, 7, 16, 32, 64 }) |vlen| {
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
    inline for ([_]usize{ 4, 5, 7, 16, 32, 64 }) |vlen| {
        try expectJsoncMatchesScalarAtWidth(vlen, &input);
    }
}

fn expectJsoncStreamIndexEqual(
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

fn feedJsoncStream(
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

test "JSONC stream wrapper matches one-shot across comments and partitions" {
    const input =
        "{/*lead*/\"alpha\":[true,//tail\nfalse],\"text\":\"a\\\\\\\"b\"}";
    var expected = try indexJsonc(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    for (0..input.len + 1) |split| {
        var actual = try feedJsoncStream(input, split, 3);
        defer actual.deinit(testing.allocator);
        try expectJsoncStreamIndexEqual(&expected, &actual);
    }

    var byte_indexer = try initStreamIndexer(testing.allocator, 1);
    defer byte_indexer.deinit();
    for (input) |byte| {
        try byte_indexer.feed(&.{byte});
    }
    try byte_indexer.finish();
    var byte_actual = byte_indexer.take();
    defer byte_actual.deinit(testing.allocator);
    try expectJsoncStreamIndexEqual(&expected, &byte_actual);
}

test "JSONC stream wrapper reset and finish lifecycle preserve offsets" {
    const first_input = "{/*discard*/\"first\":true}";
    const second_input = "{\"second\":2}";
    var indexer = try initStreamIndexer(testing.allocator, 2);
    defer indexer.deinit();

    try indexer.feed(first_input);
    try indexer.finish();
    try indexer.finish();
    try testing.expectError(error.AlreadyFinished, indexer.feed("0"));
    var first = indexer.take();
    defer first.deinit(testing.allocator);

    indexer.reset();
    try indexer.feed(second_input[0..3]);
    try indexer.feed(second_input[3..]);
    try indexer.finish();
    var second = indexer.take();
    defer second.deinit(testing.allocator);

    var expected_first = try indexJsonc(testing.allocator, first_input);
    defer expected_first.deinit(testing.allocator);
    var expected_second = try indexJsonc(testing.allocator, second_input);
    defer expected_second.deinit(testing.allocator);
    try expectJsoncStreamIndexEqual(&expected_first, &first);
    try expectJsoncStreamIndexEqual(&expected_second, &second);
}

test "JSONC comment delimiters cannot overlap" {
    const input = "/*/1";
    var scalar = try scalarIndexJsonc(testing.allocator, input);
    defer scalar.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), scalar.count);
    inline for (.{ 4, 5, 7, 16, 32, 64 }) |width| {
        try expectJsoncMatchesScalarAtWidth(width, input);
    }
    var indexer = try initStreamIndexer(testing.allocator, 1);
    defer indexer.deinit();
    for (0..input.len) |offset| try indexer.feed(input[offset..][0..1]);
    try indexer.finish();
    var streamed = indexer.take();
    defer streamed.deinit(testing.allocator);
    try expectJsoncStreamIndexEqual(&scalar, &streamed);
}
