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

/// Initializes a chunk-fed JSON5 Stage 1 indexer in document mode.
pub fn initStreamIndexer(
    allocator: std.mem.Allocator,
    chunk_len: usize,
) stream.StreamIndexer.InitError!stream.StreamIndexer {
    return stream.StreamIndexer.init(
        allocator,
        chunk_len,
        stream.Options{ .dialect = .json5, .mode = .document },
    );
}
/// Initializes a lazy JSON5 document over parser-owned indexes.
pub fn initOnDemandDocument(
    parser: *ondemand.Parser,
    input: []const u8,
) !ondemand.Document {
    const indexes = try parser.prepareDocument(input);
    const token_count = try indexJson5Into(simd.default_vector_len, indexes, input);
    return parser.completeDialectDocument(input, token_count, .json5);
}

pub fn indexJson5(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    return indexJson5Impl(simd.default_vector_len, allocator, input);
}

/// Builds an owned, validated JSON5 tape from the Stage1 structural index.
pub fn buildJson5Tape(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage2.BuildError!stage2.Document {
    var structural_index = indexJson5(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);
    return stage2.buildTape(allocator, input, &structural_index, .json5);
}

/// Validates JSON5 and returns the first semantic diagnostic, if any.
pub fn validateJson5(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage2.ValidationError!?stage2.Diagnostic {
    var structural_index = indexJson5(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);
    return stage2.validate(input, &structural_index, .json5);
}

pub fn indexJson5Into(
    comptime VLEN: usize,
    indexes: []u32,
    input: []const u8,
) lexical.Error!usize {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var sink = IndexSink{ .indexes = indexes };
    var state: lexical.State = .{};
    lexical.feed(VLEN, .json5, &state, input, 0, &sink) catch |err| switch (err) {
        error.NonContiguousInput => unreachable,
        error.CapacityExceeded => return error.CapacityExceeded,
        error.InputTooLarge => return error.InputTooLarge,
    };
    lexical.finish(.json5, &state, &sink) catch |err| switch (err) {
        error.NonContiguousInput => unreachable,
        error.CapacityExceeded => return error.CapacityExceeded,
        error.InputTooLarge => return error.InputTooLarge,
    };
    return sink.count;
}

pub fn indexJson5Impl(
    comptime VLEN: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    result.count = indexJson5Into(
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

fn isJson5AtomByte(
    byte: u8,
    previous_atom_candidate: bool,
    input: []const u8,
    byte_offset: usize,
) bool {
    return switch (byte) {
        '-', '+', '.', '0'...'9', 'a'...'z', 'A'...'Z', '_', '$' => true,
        '\\' => byte_offset + 1 < input.len and input[byte_offset + 1] == 'u',
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

fn json5LineTerminatorWidth(input: []const u8, byte_offset: usize) ?usize {
    if (byte_offset >= input.len) return null;
    const byte = input[byte_offset];
    if (byte == '\n') return 1;
    if (byte == '\r') {
        return if (byte_offset + 1 < input.len and input[byte_offset + 1] == '\n')
            2
        else
            1;
    }
    if (byte == 0xe2 and byte_offset + 2 < input.len and
        input[byte_offset + 1] == 0x80 and
        (input[byte_offset + 2] == 0xa8 or input[byte_offset + 2] == 0xa9))
    {
        return 3;
    }
    return null;
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
    var skip_comment_byte = false;
    var previous_atom_candidate = false;
    var backslash_run_length: usize = 0;

    for (input, 0..) |byte, byte_offset| {
        const unescaped_double_quote = byte == '"' and backslash_run_length % 2 == 0;
        const unescaped_single_quote = byte == '\'' and backslash_run_length % 2 == 0;

        if (skip_comment_byte) {
            skip_comment_byte = false;
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
            if (json5LineTerminatorWidth(input, byte_offset) != null) {
                in_single_comment = false;
                previous_atom_candidate = false;
            }
        } else if (in_multi_comment) {
            if (byte == '*' and byte_offset + 1 < input.len and
                input[byte_offset + 1] == '/')
            {
                in_multi_comment = false;
                previous_atom_candidate = false;
                skip_comment_byte = true;
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
                skip_comment_byte = true;
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

    inline for ([_]usize{ 4, 5, 7, 16, 32, 64 }) |VLEN| {
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

test "JSON5 Stage2 builds extended values and raw views" {
    const input =
        "{unquoted:'single', escaped\\u004b:+.5, hex:-0x2A, inf:Infinity, nan:NaN, trailing:[1,2,],}";
    var document = try buildJson5Tape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    try cursor.advance();
    const raw_key = try cursor.rawValue();
    try testing.expectEqualStrings("unquoted", raw_key);
    try testing.expect(
        raw_key.ptr == input.ptr + @as(usize, document.tape[cursor.position()].offset),
    );
    try cursor.advance();
    const raw_string = try cursor.rawValue();
    try testing.expectEqualStrings("single", raw_string);
    try testing.expect(
        raw_string.ptr ==
            input.ptr + @as(usize, document.tape[cursor.position()].offset) + 1,
    );
    try testing.expect((try validateJson5(testing.allocator, input)) == null);
    try cursor.advance();
    const escaped_key = try cursor.rawValue();
    try testing.expectEqualStrings("escaped\\u004b", escaped_key);
    try testing.expect(
        escaped_key.ptr ==
            input.ptr + @as(usize, document.tape[cursor.position()].offset),
    );
    try cursor.advance();
    const signed_number = try cursor.rawValue();
    try testing.expectEqualStrings("+.5", signed_number);
    try testing.expect(
        signed_number.ptr ==
            input.ptr + @as(usize, document.tape[cursor.position()].offset),
    );
    try cursor.advance();
    try cursor.advance();
    try testing.expectEqualStrings("-0x2A", try cursor.rawValue());
    try cursor.advance();
    try cursor.advance();
    try testing.expectEqualStrings("Infinity", try cursor.rawValue());
}

test "JSON5 Stage2 reports numeric and identifier diagnostics" {
    const invalid_number = try validateJson5(testing.allocator, "{value:01}");
    if (invalid_number) |diagnostic| {
        try testing.expectEqual(error.InvalidNumber, diagnostic.err);
        try testing.expectEqual(@as(usize, 8), diagnostic.byte_offset);
    } else {
        return error.ExpectedDiagnostic;
    }

    const invalid_key = try validateJson5(testing.allocator, "{\\u0030foo:1}");
    if (invalid_key) |diagnostic| {
        try testing.expectEqual(error.UnexpectedToken, diagnostic.err);
        try testing.expectEqual(@as(usize, 1), diagnostic.byte_offset);
    } else {
        return error.ExpectedDiagnostic;
    }
}

test "JSON5 Stage2 accepts control whitespace and non-digit escapes" {
    const input = [_]u8{
        '{',  0x0b, 'k',  'e', 'y',  ':', 0x0c, '\'',
        '\\', 'A',  '\\', 'C', '\\', '/', '\\', 'D',
        '\\', 'C',  '\'', '}',
    };
    var document = try buildJson5Tape(testing.allocator, &input);
    defer document.deinit(testing.allocator);
    try testing.expect((try validateJson5(testing.allocator, &input)) == null);
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

test "indexJson5 tracks opposite quote delimiters inside strings" {
    const input = "{\"text\":\"a'b\", next:1}";
    inline for ([_]usize{ 4, 5, 7, 16, 32, 64 }) |VLEN| {
        try expectJson5ImplMatchesScalar(VLEN, input);
    }
}

test "indexJson5 keeps adjacent escaped and Unicode atom bytes together" {
    const input = "{foo\\u004bar:1, éfoo:2}";
    inline for ([_]usize{ 4, 5, 7, 16, 32, 64 }) |VLEN| {
        try expectJson5ImplMatchesScalar(VLEN, input);
    }
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

    inline for ([_]usize{ 4, 5, 7, 16, 32, 64 }) |VLEN| {
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
    inline for ([_]usize{ 4, 5, 7, 16, 32, 64 }) |VLEN| {
        try expectJson5ImplMatchesScalar(VLEN, &input);
    }
}

fn expectJson5StreamIndexEqual(
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

fn feedJson5Stream(
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

test "JSON5 stream wrapper matches one-shot across dialect features" {
    const input = "{//lead\nfoo:'value',arr:[+1,0x2A,],}";
    var expected = try indexJson5(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    for (0..input.len + 1) |split| {
        var actual = try feedJson5Stream(input, split, 3);
        defer actual.deinit(testing.allocator);
        try expectJson5StreamIndexEqual(&expected, &actual);
    }

    var byte_indexer = try initStreamIndexer(testing.allocator, 1);
    defer byte_indexer.deinit();
    for (input) |byte| {
        try byte_indexer.feed(&.{byte});
    }
    try byte_indexer.finish();
    var byte_actual = byte_indexer.take();
    defer byte_actual.deinit(testing.allocator);
    try expectJson5StreamIndexEqual(&expected, &byte_actual);
}

test "JSON5 stream wrapper reset and finish lifecycle preserve offsets" {
    const first_input = "{first:'discarded'}";
    const second_input = "[+1,0x2A,]";
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

    var expected_first = try indexJson5(testing.allocator, first_input);
    defer expected_first.deinit(testing.allocator);
    var expected_second = try indexJson5(testing.allocator, second_input);
    defer expected_second.deinit(testing.allocator);
    try expectJson5StreamIndexEqual(&expected_first, &first);
    try expectJson5StreamIndexEqual(&expected_second, &second);
}

test "JSON5 stream terminates comments at split Unicode separators" {
    const separators = [_][3]u8{
        .{ 0xe2, 0x80, 0xa8 },
        .{ 0xe2, 0x80, 0xa9 },
    };
    const separator_offsets = [_]usize{
        2 * simd.default_vector_len - 2,
        2 * simd.default_vector_len - 1,
    };

    var indexer = try initStreamIndexer(testing.allocator, 1);
    defer indexer.deinit();

    var case_index: usize = 0;
    for (separators) |separator| {
        for (separator_offsets) |separator_offset| {
            if (case_index != 0) indexer.reset();
            case_index += 1;

            var input: [2 * simd.default_vector_len + 7]u8 = @splat('x');
            input[0] = '[';
            input[1] = '/';
            input[2] = '/';
            @memcpy(
                input[separator_offset .. separator_offset + separator.len],
                separator[0..],
            );
            @memcpy(
                input[separator_offset + separator.len .. separator_offset + separator.len + 5],
                "true]",
            );
            const source = input[0 .. separator_offset + separator.len + 5];
            const expected_offsets = [_]u32{
                0,
                @intCast(separator_offset + separator.len),
                @intCast(source.len - 1),
            };

            var expected = try indexJson5(testing.allocator, source);
            defer expected.deinit(testing.allocator);
            try testing.expectEqualSlices(
                u32,
                &expected_offsets,
                expected.slice(),
            );

            // Bytewise feeds force both UTF-8 continuation boundaries.
            for (source) |byte| {
                try indexer.feed("");
                try indexer.feed(&.{byte});
            }
            try indexer.feed("");
            try indexer.finish();
            try indexer.finish();
            var actual = indexer.take();
            defer actual.deinit(testing.allocator);
            try expectJson5StreamIndexEqual(&expected, &actual);
        }
    }
}

test "JSON5 comment delimiters cannot overlap" {
    const input = "/*/1";
    var scalar = try scalarIndexJson5(testing.allocator, input);
    defer scalar.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), scalar.count);
    inline for (.{ 4, 5, 7, 16, 32, 64 }) |width| {
        try expectJson5ImplMatchesScalar(width, input);
    }
    var indexer = try initStreamIndexer(testing.allocator, 1);
    defer indexer.deinit();
    for (0..input.len) |offset| try indexer.feed(input[offset..][0..1]);
    try indexer.finish();
    var streamed = indexer.take();
    defer streamed.deinit(testing.allocator);
    try expectJson5StreamIndexEqual(&scalar, &streamed);
}
