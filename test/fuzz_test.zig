const std = @import("std");
const lib = @import("simd_lib");
const checking = @import("checking.zig");
const testing = std.testing;

// Mirror the core scalar contract without calling parser code: an invalid
// byte (including sequence constraints) reports its own offset; truncation
// reports the sequence lead byte.
fn scalarUtf8FailureOffset(input: []const u8) ?usize {
    var index: usize = 0;
    while (index < input.len) {
        const first = input[index];
        if (first < 0x80) {
            index += 1;
            continue;
        }

        const sequence_length: usize = switch (first) {
            0xC0...0xDF => 2,
            0xE0...0xEF => 3,
            0xF0...0xF4 => 4,
            else => return index,
        };
        if (input.len - index == 1) return index;

        if (!scalarUtf8SecondByteValid(first, input[index + 1])) {
            return index + 1;
        }
        // C0/C1 classify the next byte before reporting an overlong lead.
        if (first <= 0xC1) return index;
        var continuation_offset: usize = 2;
        while (continuation_offset < sequence_length) : (continuation_offset += 1) {
            if (continuation_offset >= input.len - index) return index;
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

// XML reports malformed scalars at their sequence start, unlike the JSON
// string/comment byte diagnostics checked above.
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

fn expectJsonlStreamPartitions(
    input: []const u8,
    expected: *const lib.StructuralIndex,
) !void {
    const cuts = checking.fuzzCuts(input.len);
    var stream = try lib.formats.jsonl.initStreamIndexer(
        testing.allocator,
        3,
    );
    defer stream.deinit();

    try checking.feedPartitions(input, &cuts, &stream, true);
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try checking.expectIndexParity(expected, &actual, true);
}

fn expectMarkdownStreamPartitions(
    input: []const u8,
    expected: *const lib.formats.markdown.MarkdownStructuralIndex,
) !void {
    const cuts = checking.fuzzCuts(input.len);
    var stream = try lib.formats.markdown.MarkdownStreamIndexer.init(
        testing.allocator,
        3,
    );
    defer stream.deinit();

    try checking.feedPartitions(input, &cuts, &stream, true);
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try checking.expectTokenParity(expected, &actual, true);
}

fn expectXmlStreamPartitions(
    input: []const u8,
    expected: *const lib.formats.xml.XmlStructuralIndex,
) !void {
    const cuts = checking.fuzzCuts(input.len);
    var stream = try lib.formats.xml.XmlStreamIndexer.init(
        testing.allocator,
        3,
    );
    defer stream.deinit();

    try checking.feedPartitions(input, &cuts, &stream, true);
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try checking.expectTokenParity(expected, &actual, true);
}

const deterministic_case_count = 2_048;
const bounded_property_case_count = 256;
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

fn runDeterministicSmithCasesLimited(
    seed: u64,
    case_count: usize,
    comptime invariant: anytype,
) !void {
    std.debug.assert(seed != 0);
    std.debug.assert(case_count > 0);

    var state = seed;
    var input_buffer: [input_size_max]u8 = undefined;
    for (0..case_count) |case_index| {
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

fn runDeterministicSmithCases(seed: u64, comptime invariant: anytype) !void {
    try runDeterministicSmithCasesLimited(seed, deterministic_case_count, invariant);
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

    try checking.expectMonotonicBounds(idx.slice(), input.len);
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

    try checking.expectMonotonicBounds(idx.slice(), input.len);
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

    try checking.expectMonotonicBounds(idx.slice(), input.len);
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

    try checking.expectMonotonicBounds(idx.slice(), input.len);
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
    try checking.expectMonotonicBounds(slice, input.len);
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
    try checking.expectMonotonicBounds(slice, input.len);
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

const stage2_input_max: usize = 128;

fn appendBytes(output: []u8, offset: *usize, bytes: []const u8) void {
    @memcpy(output[offset.*..][0..bytes.len], bytes);
    offset.* += bytes.len;
}

fn appendSafePayload(raw: []const u8, output: []u8, offset: *usize) void {
    const payload_len = @max(@as(usize, 1), @min(raw.len, @as(usize, 32)));
    if (raw.len == 0) {
        output[offset.*] = 'a';
        offset.* += 1;
        return;
    }
    for (0..payload_len) |index| {
        output[offset.*] = 'a' + @as(u8, @truncate(raw[index] % 26));
        offset.* += 1;
    }
}

fn makeJsonCase(raw: []const u8, output: []u8) []const u8 {
    var offset: usize = 0;
    appendBytes(output, &offset, "{\"text\":\"");
    appendSafePayload(raw, output, &offset);
    appendBytes(output, &offset, "\",\"items\":[0,1,true,null]}");
    return output[0..offset];
}

fn makeJsoncCase(raw: []const u8, output: []u8) []const u8 {
    var offset: usize = 0;
    appendBytes(output, &offset, "// fuzz comment\n{\"text\":\"");
    appendSafePayload(raw, output, &offset);
    appendBytes(output, &offset, "\",\"items\":[0,1,true,null]}");
    return output[0..offset];
}

fn makeJson5Case(raw: []const u8, output: []u8) []const u8 {
    var offset: usize = 0;
    appendBytes(output, &offset, "{unquotedKey:'");
    appendSafePayload(raw, output, &offset);
    appendBytes(output, &offset, "',hex:0x1a,items:[0,1,true,null]}");
    return output[0..offset];
}

fn makeJsonlCase(raw: []const u8, output: []u8) []const u8 {
    var offset: usize = 0;
    appendBytes(output, &offset, "{\"text\":\"");
    appendSafePayload(raw, output, &offset);
    appendBytes(output, &offset, "\"}\n[0,1,true,null]\n");
    return output[0..offset];
}

fn makeYamlCase(raw: []const u8, output: []u8) []const u8 {
    var offset: usize = 0;
    appendBytes(output, &offset, "name: ");
    appendSafePayload(raw, output, &offset);
    appendBytes(output, &offset, "\nitems:\n  - one\n  - two\n");
    return output[0..offset];
}

fn expectStage2Json(input: []const u8) !void {
    var index = lib.formats.json.indexJson(testing.allocator, input) catch |err| {
        if (checking.isCapacityError(err)) return;
        return err;
    };
    defer index.deinit(testing.allocator);
    try checking.expectMonotonicBounds(index.slice(), input.len);
    try checking.expectValidationBuildParity(
        lib.formats.json.validateJson,
        lib.formats.json.buildJsonTape,
        input,
        checking.expectJsonDocument,
    );
}

fn expectStage2Jsonc(input: []const u8) !void {
    var index = lib.formats.jsonc.indexJsonc(testing.allocator, input) catch |err| {
        if (checking.isCapacityError(err)) return;
        return err;
    };
    defer index.deinit(testing.allocator);
    try checking.expectMonotonicBounds(index.slice(), input.len);
    try checking.expectValidationBuildParity(
        lib.formats.jsonc.validateJsonc,
        lib.formats.jsonc.buildJsoncTape,
        input,
        checking.expectJsonDocument,
    );
}

fn expectStage2Json5(input: []const u8) !void {
    var index = lib.formats.json5.indexJson5(testing.allocator, input) catch |err| {
        if (checking.isCapacityError(err)) return;
        return err;
    };
    defer index.deinit(testing.allocator);
    try checking.expectMonotonicBounds(index.slice(), input.len);
    try checking.expectValidationBuildParity(
        lib.formats.json5.validateJson5,
        lib.formats.json5.buildJson5Tape,
        input,
        checking.expectJsonDocument,
    );
}

// JSONL keeps its permissive compatibility profile: blank records are accepted.
fn expectStage2Jsonl(input: []const u8) !void {
    var index = lib.formats.jsonl.indexJsonl(testing.allocator, input) catch |err| {
        if (checking.isCapacityError(err)) return;
        return err;
    };
    defer index.deinit(testing.allocator);
    try checking.expectMonotonicBounds(index.slice(), input.len);
    try checking.expectValidationBuildParity(
        lib.formats.jsonl.validateJsonl,
        lib.formats.jsonl.buildJsonlTape,
        input,
        checking.expectJsonlDocument,
    );
}

fn expectYamlStreamParity(input: []const u8) !void {
    const cuts = checking.fuzzCuts(input.len);
    var expected = lib.formats.yaml.indexYaml(testing.allocator, input) catch |expected_err| {
        var stream = lib.formats.yaml.YamlStreamIndexer.init(testing.allocator, 3) catch |err| {
            if (checking.isCapacityError(err)) return;
            return err;
        };
        defer stream.deinit();
        try checking.feedPartitions(input, &cuts, &stream, true);
        stream.finish() catch |actual_err| {
            try testing.expectEqualStrings(@errorName(expected_err), @errorName(actual_err));
            return;
        };
        try testing.expect(false);
        return;
    };
    defer expected.deinit(testing.allocator);

    var stream = try lib.formats.yaml.YamlStreamIndexer.init(testing.allocator, 3);
    defer stream.deinit();
    try checking.feedPartitions(input, &cuts, &stream, true);
    try stream.finish();
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try checking.expectYamlParity(&expected, &actual, true);
}

fn expectStage2Yaml(input: []const u8) !void {
    var index = lib.formats.yaml.indexYaml(testing.allocator, input) catch |err| {
        if (checking.isCapacityError(err)) return;
        try checking.expectValidationBuildParity(
            lib.formats.yaml.validateYaml,
            lib.formats.yaml.buildYamlTape,
            input,
            checking.expectYamlDocument,
        );
        return;
    };
    defer index.deinit(testing.allocator);
    try checking.expectBounds(index.slice(), input.len);

    const indexed_diagnostic = lib.formats.yaml.validateYamlIndex(
        testing.allocator,
        input,
        &index,
    ) catch |err| {
        if (checking.isCapacityError(err)) return;
        return err;
    };
    const diagnostic = lib.formats.yaml.validateYaml(testing.allocator, input) catch |err| {
        if (checking.isCapacityError(err)) return;
        return err;
    };
    try testing.expect((indexed_diagnostic == null) == (diagnostic == null));
    if (indexed_diagnostic) |indexed| {
        try testing.expect(diagnostic != null);
        try testing.expectEqual(indexed.err, diagnostic.?.err);
        try testing.expectEqual(indexed.kind, diagnostic.?.kind);
        try testing.expectEqual(indexed.byte_offset, diagnostic.?.byte_offset);
    }
    try checking.expectValidationBuildParity(
        lib.formats.yaml.validateYaml,
        lib.formats.yaml.buildYamlTape,
        input,
        checking.expectYamlDocument,
    );
}

test "fuzz: Stage2 JSON family and YAML build validate tape cursor parity" {
    try runDeterministicSmithCasesLimited(
        0x517c_c1b7_2722_0a95,
        bounded_property_case_count,
        testFuzzStage2,
    );
}

fn testFuzzStage2(_: void, smith: *testing.Smith) !void {
    var raw_buffer: [input_size_max]u8 = undefined;
    const raw_len = smith.slice(&raw_buffer);
    const raw = raw_buffer[0..raw_len];

    try expectStage2Json(raw);
    try expectStage2Jsonc(raw);
    try expectStage2Json5(raw);
    try expectStage2Jsonl(raw);
    try expectStage2Yaml(raw);
    try expectYamlStreamParity(raw);

    var json_buffer: [stage2_input_max]u8 = undefined;
    const json = makeJsonCase(raw, &json_buffer);
    try expectStage2Json(json);

    var jsonc_buffer: [stage2_input_max]u8 = undefined;
    const jsonc = makeJsoncCase(raw, &jsonc_buffer);
    try expectStage2Jsonc(jsonc);

    var json5_buffer: [stage2_input_max]u8 = undefined;
    const json5 = makeJson5Case(raw, &json5_buffer);
    try expectStage2Json5(json5);

    var jsonl_buffer: [stage2_input_max]u8 = undefined;
    const jsonl = makeJsonlCase(raw, &jsonl_buffer);
    try expectStage2Jsonl(jsonl);

    var yaml_buffer: [stage2_input_max]u8 = undefined;
    const yaml = makeYamlCase(raw, &yaml_buffer);
    try expectStage2Yaml(yaml);
    try expectYamlStreamParity(yaml);

    try expectStage2Json("[1,]");
    try expectStage2Jsonc("{\"a\":1,}");
    try expectStage2Json5("{value:01}");
    try expectStage2Jsonl("{}\n[1,]\n");
    try expectStage2Yaml("name: [Ada,]\n");
    try expectYamlStreamParity("name: [Ada,]\n");
}

test "fuzz: SIMD match windows prefix backslash and UTF8 differential" {
    try runDeterministicSmithCasesLimited(
        0x8f1b_bcdc_6a7e_11c3,
        bounded_property_case_count,
        testFuzzSimd,
    );
}

fn testFuzzSimd(_: void, smith: *testing.Smith) !void {
    var buffer: [input_size_max]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    try checking.expectSimdMatchWindows(input);
    try checking.expectUtf8Widths(input);

    const mask16 = smith.value(u16);
    const mask32 = smith.value(u32);
    const mask64 = smith.value(u64);
    const previous = smith.boolWeighted(1, 1);
    try testing.expectEqual(
        checking.scalarPrefixXor(u16, mask16),
        lib.prefixXor(u16, mask16),
    );
    try testing.expectEqual(
        checking.scalarPrefixXor(u32, mask32),
        lib.prefixXor(u32, mask32),
    );
    try testing.expectEqual(
        checking.scalarPrefixXor(u64, mask64),
        lib.prefixXor(u64, mask64),
    );
    try testing.expectEqual(
        checking.scalarBackslashRunParity(u16, mask16, previous),
        lib.computeBackslashRuns(u16, mask16, previous),
    );
    try testing.expectEqual(
        checking.scalarBackslashRunParity(u32, mask32, previous),
        lib.computeBackslashRuns(u32, mask32, previous),
    );
    try testing.expectEqual(
        checking.scalarBackslashRunParity(u64, mask64, previous),
        lib.computeBackslashRuns(u64, mask64, previous),
    );
}
