const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

fn checkMonotonicBounds(indexes: []const u32, input_len: usize) !void {
    for (indexes, 0..) |offset, i| {
        try testing.expect(offset < input_len);
        if (i > 0) {
            try testing.expect(indexes[i - 1] < offset);
        }
    }
}

fn scalarUtf8FailureOffset(input: []const u8) ?usize {
    var index: usize = 0;
    while (index < input.len) {
        const first = input[index];
        if (first < 0x80) {
            index += 1;
            continue;
        }

        const sequence_length: usize = switch (first) {
            0xC2...0xDF => 2,
            0xE0...0xEF => 3,
            0xF0...0xF4 => 4,
            else => return index,
        };
        if (input.len - index < sequence_length) return index;

        if (!scalarUtf8SecondByteValid(first, input[index + 1])) {
            return index + 1;
        }
        var continuation_offset: usize = 2;
        while (continuation_offset < sequence_length) : (continuation_offset += 1) {
            const byte = input[index + continuation_offset];
            if (byte < 0x80 or byte > 0xBF) return index + continuation_offset;
        }
        index += sequence_length;
    }
    return null;
}

fn scalarUtf8SecondByteValid(first: u8, second: u8) bool {
    return switch (first) {
        0xE0 => second >= 0xA0 and second <= 0xBF,
        0xED => second >= 0x80 and second <= 0x9F,
        0xF0 => second >= 0x90 and second <= 0xBF,
        0xF4 => second >= 0x80 and second <= 0x8F,
        else => second >= 0x80 and second <= 0xBF,
    };
}

fn scalarUtf8SequenceStart(input: []const u8, invalid_offset: usize) usize {
    var sequence_start = @min(invalid_offset, input.len);
    var continuation_count: usize = 0;
    while (sequence_start > 0 and
        input[sequence_start - 1] >= 0x80 and
        input[sequence_start - 1] <= 0xBF)
    {
        sequence_start -= 1;
        continuation_count += 1;
    }
    if (sequence_start == 0) return invalid_offset;

    const lead = input[sequence_start - 1];
    const expected_continuations: usize = switch (lead) {
        0xC0...0xDF => 1,
        0xE0...0xEF => 2,
        0xF0...0xF4 => 3,
        else => 0,
    };
    if (continuation_count < expected_continuations) return sequence_start - 1;
    return invalid_offset;
}

fn isXmlCharacterScalar(codepoint: u21) bool {
    return codepoint == 0x9 or codepoint == 0xA or codepoint == 0xD or
        (codepoint >= 0x20 and codepoint <= 0xD7FF) or
        (codepoint >= 0xE000 and codepoint <= 0xFFFD) or
        (codepoint >= 0x10000 and codepoint <= 0x10FFFF);
}

fn scalarXmlCharacterFailureOffset(
    input: []const u8,
    invalid_utf8_start: ?usize,
) ?usize {
    var index: usize = 0;
    while (index < input.len) {
        if (invalid_utf8_start) |offset| {
            if (index >= offset) return null;
        }
        const width: usize = @intCast(
            std.unicode.utf8ByteSequenceLength(input[index]) catch return null,
        );
        if (input.len - index < width) return null;
        const codepoint = std.unicode.utf8Decode(input[index .. index + width]) catch return null;
        if (!isXmlCharacterScalar(codepoint)) return index;
        index += width;
    }
    return null;
}

fn expectJsonSemanticUtf8(payload: []const u8) !void {
    var input: [input_size_max + 4]u8 = undefined;
    input[0] = '[';
    input[1] = '"';
    @memcpy(input[2..][0..payload.len], payload);
    input[2 + payload.len] = '"';
    input[3 + payload.len] = ']';
    const source = input[0 .. payload.len + 4];

    const expected_offset = scalarUtf8FailureOffset(payload);
    const diagnostic = lib.formats.json.validateJson(testing.allocator, source) catch |err| {
        if (err == error.OutOfMemory) return;
        return err;
    };
    if (expected_offset) |offset| {
        try testing.expect(diagnostic != null);
        try testing.expectEqual(error.InvalidUtf8, diagnostic.?.err);
        try testing.expectEqual(@as(usize, 2) + offset, diagnostic.?.byte_offset);
    } else {
        try testing.expect(diagnostic == null);
    }
}

fn expectJsoncCommentSemanticUtf8(payload: []const u8) !void {
    var input: [input_size_max + 8]u8 = undefined;
    input[0] = '/';
    input[1] = '/';
    @memcpy(input[2..][0..payload.len], payload);
    input[2 + payload.len] = '\n';
    input[3 + payload.len] = '{';
    input[4 + payload.len] = '}';
    const source = input[0 .. payload.len + 5];

    const expected_offset = scalarUtf8FailureOffset(payload);
    const diagnostic = lib.formats.jsonc.validateJsonc(testing.allocator, source) catch |err| {
        if (err == error.OutOfMemory) return;
        return err;
    };
    if (expected_offset) |offset| {
        try testing.expect(diagnostic != null);
        try testing.expectEqual(error.InvalidUtf8, diagnostic.?.err);
        try testing.expectEqual(@as(usize, 2) + offset, diagnostic.?.byte_offset);
    } else {
        try testing.expect(diagnostic == null);
    }
}

fn expectXmlSemanticUtf8(payload: []const u8) !void {
    var input: [input_size_max + 7]u8 = undefined;
    input[0] = '<';
    input[1] = 'a';
    input[2] = '>';
    @memcpy(input[3..][0..payload.len], payload);
    input[3 + payload.len] = '<';
    input[4 + payload.len] = '/';
    input[5 + payload.len] = 'a';
    input[6 + payload.len] = '>';
    const source = input[0 .. payload.len + 7];

    const invalid_utf8_offset = if (scalarUtf8FailureOffset(payload)) |offset|
        scalarUtf8SequenceStart(payload, offset)
    else
        null;
    const invalid_character_offset =
        scalarXmlCharacterFailureOffset(payload, invalid_utf8_offset);
    const diagnostic = lib.formats.xml.validateXml(source) catch |err| {
        if (err == error.OutOfMemory) return;
        return err;
    };

    if (invalid_character_offset) |offset| {
        const character_is_first = if (invalid_utf8_offset) |utf8_offset|
            offset < utf8_offset
        else
            true;
        if (character_is_first) {
            try testing.expect(diagnostic != null);
            try testing.expectEqual(error.InvalidCharacter, diagnostic.?.err);
            try testing.expectEqual(@as(usize, 3) + offset, diagnostic.?.byte_offset);
            return;
        }
    }
    if (invalid_utf8_offset) |offset| {
        try testing.expect(diagnostic != null);
        try testing.expectEqual(error.InvalidUtf8, diagnostic.?.err);
        try testing.expectEqual(@as(usize, 3) + offset, diagnostic.?.byte_offset);
    } else {
        try testing.expect(diagnostic == null);
    }
}

const stream_sentinel_count: usize = 3;

fn fuzzCuts(input_len: usize) [4]usize {
    return .{
        0,
        input_len / 3,
        input_len / 2,
        input_len,
    };
}

fn expectJsonlStreamPartitions(
    input: []const u8,
    expected: *const lib.StructuralIndex,
) !void {
    const cuts = fuzzCuts(input.len);
    var stream = try lib.formats.jsonl.initStreamIndexer(
        testing.allocator,
        3,
    );
    defer stream.deinit();

    var start: usize = 0;
    for (cuts) |cut| {
        try testing.expect(cut >= start);
        try stream.feed(input[start..cut]);
        try stream.feed("");
        start = cut;
    }
    try stream.feed(input[start..]);
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + stream_sentinel_count],
        actual.indexes[0 .. actual.count + stream_sentinel_count],
    );
}

fn expectMarkdownStreamPartitions(
    input: []const u8,
    expected: *const lib.formats.markdown.MarkdownStructuralIndex,
) !void {
    const cuts = fuzzCuts(input.len);
    var stream = try lib.formats.markdown.MarkdownStreamIndexer.init(
        testing.allocator,
        3,
    );
    defer stream.deinit();

    var start: usize = 0;
    for (cuts) |cut| {
        try testing.expect(cut >= start);
        try stream.feed(input[start..cut]);
        try stream.feed("");
        start = cut;
    }
    try stream.feed(input[start..]);
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + stream_sentinel_count],
        actual.indexes[0 .. actual.count + stream_sentinel_count],
    );
    try testing.expectEqualSlices(
        lib.formats.markdown.MarkdownTokenKind,
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
}

fn expectXmlStreamPartitions(
    input: []const u8,
    expected: *const lib.formats.xml.XmlStructuralIndex,
) !void {
    const cuts = fuzzCuts(input.len);
    var stream = try lib.formats.xml.XmlStreamIndexer.init(
        testing.allocator,
        3,
    );
    defer stream.deinit();

    var start: usize = 0;
    for (cuts) |cut| {
        try testing.expect(cut >= start);
        try stream.feed(input[start..cut]);
        try stream.feed("");
        start = cut;
    }
    try stream.feed(input[start..]);
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + stream_sentinel_count],
        actual.indexes[0 .. actual.count + stream_sentinel_count],
    );
    try testing.expectEqualSlices(
        lib.formats.xml.XmlTokenKind,

        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
}

const deterministic_case_count = 2_048;
const input_size_max = 512;

fn xorshift64(state: *u64) u64 {
    std.debug.assert(state.* != 0);

    var value = state.*;
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    state.* = value;
    return value;
}

fn runDeterministicSmithCases(seed: u64, comptime invariant: anytype) !void {
    std.debug.assert(seed != 0);

    var state = seed;
    var input_buffer: [input_size_max]u8 = undefined;
    for (0..deterministic_case_count) |case_index| {
        const input_len: usize = switch (case_index) {
            0 => 0,
            1 => input_size_max,
            else => @intCast(xorshift64(&state) % @as(u64, input_size_max + 1)),
        };
        const input = input_buffer[0..input_len];
        for (input) |*byte| {
            byte.* = @truncate(xorshift64(&state));
        }

        var smith: testing.Smith = .{ .in = input };
        try invariant({}, &smith);
    }
}

// -------------------------------------------------------------------------
// JSON Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: JSON indexer invariants" {
    try runDeterministicSmithCases(0x243f_6a88_85a3_08d3, testFuzzJson);
}

fn testFuzzJson(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.json.indexJson(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    try checkMonotonicBounds(idx.slice(), input.len);
}

// -------------------------------------------------------------------------
// JSONL Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: JSONL indexer invariants" {
    try runDeterministicSmithCases(0x1319_8a2e_0370_7344, testFuzzJsonl);
}

fn testFuzzJsonl(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.jsonl.indexJsonl(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    try checkMonotonicBounds(idx.slice(), input.len);
    try expectJsonlStreamPartitions(input, &idx);
}

// -------------------------------------------------------------------------
// JSONC Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: JSONC indexer invariants" {
    try runDeterministicSmithCases(0xa409_3822_299f_31d0, testFuzzJsonc);
}

fn testFuzzJsonc(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.jsonc.indexJsonc(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    try checkMonotonicBounds(idx.slice(), input.len);
}

// -------------------------------------------------------------------------
// JSON5 Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: JSON5 indexer invariants" {
    try runDeterministicSmithCases(0x082e_fa98_ec4e_6c89, testFuzzJson5);
}

fn testFuzzJson5(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.json5.indexJson5(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    try checkMonotonicBounds(idx.slice(), input.len);
}

// -------------------------------------------------------------------------
// Markdown Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: Markdown indexer invariants" {
    try runDeterministicSmithCases(0x4528_21e6_38d0_1377, testFuzzMarkdown);
}

fn testFuzzMarkdown(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.markdown.indexMarkdown(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    const slice = idx.indexes[0..idx.count];
    try checkMonotonicBounds(slice, input.len);
    try testing.expect(idx.count <= idx.kinds.len);
    try expectMarkdownStreamPartitions(input, &idx);
}

// -------------------------------------------------------------------------
// XML Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: XML indexer invariants" {
    try runDeterministicSmithCases(0xbe54_66cf_34e9_0c6c, testFuzzXml);
}

fn testFuzzXml(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.xml.indexXml(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    const slice = idx.indexes[0..idx.count];
    try checkMonotonicBounds(slice, input.len);
    try testing.expect(idx.count <= idx.kinds.len);
    try expectXmlStreamPartitions(input, &idx);
}

fn sanitizeJsonUtf8Payload(input: []const u8, output: []u8) []const u8 {
    for (input, 0..) |byte, index| {
        output[index] = if (byte < 0x20 or byte == '"' or byte == '\\') 'a' else byte;
    }
    return output[0..input.len];
}

fn sanitizeJsoncCommentPayload(input: []const u8, output: []u8) []const u8 {
    for (input, 0..) |byte, index| {
        output[index] = if (byte == '\n' or byte == '\r') 'a' else byte;
    }
    return output[0..input.len];
}

fn sanitizeXmlUtf8Payload(input: []const u8, output: []u8) []const u8 {
    for (input, 0..) |byte, index| {
        output[index] = if (byte == '<' or byte == '&' or byte == ']') 'a' else byte;
    }
    return output[0..input.len];
}

// Compare semantic validator diagnostics with an independent scalar UTF-8 oracle.
test "fuzz: semantic UTF-8 differential" {
    try runDeterministicSmithCases(0x9e37_79b9_7f4a_7c15, testFuzzSemanticUtf8);
}

fn testFuzzSemanticUtf8(_: void, smith: *testing.Smith) !void {
    var raw: [input_size_max]u8 = undefined;
    const len = smith.slice(&raw);
    const input = raw[0..len];

    var json_payload_buffer: [input_size_max]u8 = undefined;
    const json_payload = sanitizeJsonUtf8Payload(input, &json_payload_buffer);
    try expectJsonSemanticUtf8(json_payload);

    var comment_payload_buffer: [input_size_max]u8 = undefined;
    const comment_payload = sanitizeJsoncCommentPayload(input, &comment_payload_buffer);
    try expectJsoncCommentSemanticUtf8(comment_payload);

    var xml_payload_buffer: [input_size_max]u8 = undefined;
    const xml_payload = sanitizeXmlUtf8Payload(input, &xml_payload_buffer);
    try expectXmlSemanticUtf8(xml_payload);
}
