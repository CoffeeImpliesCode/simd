const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

const vector_len = lib.default_vector_len;

test "refAllDecls" {
    testing.refAllDecls(lib);
    testing.refAllDecls(lib.simd);
    testing.refAllDecls(lib.stage1);
    testing.refAllDecls(lib.stream);
    testing.refAllDecls(lib.stage2);
    testing.refAllDecls(lib.ondemand);
    testing.refAllDecls(lib.debug);
    testing.refAllDecls(lib.formats);
    testing.refAllDecls(lib.formats.json);
    testing.refAllDecls(lib.formats.jsonl);
    testing.refAllDecls(lib.formats.jsonc);
    testing.refAllDecls(lib.formats.json5);
    testing.refAllDecls(lib.formats.markdown);
    testing.refAllDecls(lib.formats.xml);
}

test "core: prefixXor matches mathematical parity" {
    const test_patterns = [_]u64{
        0x0000000000000000,
        0xFFFFFFFFFFFFFFFF,
        0x5555555555555555,
        0xAAAAAAAAAAAAAAAA,
        0x0000000000000001,
        0x8000000000000000,
        0x123456789ABCDEF0,
        0x0F0F0F0F0F0F0F0F,
    };

    for (test_patterns) |pattern| {
        const simd_result = lib.prefixXor(u64, pattern);
        var expected: u64 = 0;
        var parity: u1 = 0;
        inline for (0..64) |i| {
            parity ^= @as(u1, @truncate(pattern >> i));
            expected |= (@as(u64, parity) << i);
        }
        try testing.expectEqual(expected, simd_result);
    }
}

fn expectStructuralWidths(comptime index_fn: anytype, input: []const u8) !void {
    var expected = try index_fn(16, testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try testing.expect(expected.count > 0);

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        var actual = try index_fn(vlen, testing.allocator, input);
        defer actual.deinit(testing.allocator);
        try testing.expectEqualSlices(
            u32,
            expected.indexes[0..expected.count],
            actual.indexes[0..actual.count],
        );
    }
}

fn expectTokenWidths(comptime index_fn: anytype, input: []const u8) !void {
    var expected = try index_fn(16, testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try testing.expect(expected.count > 0);

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        var actual = try index_fn(vlen, testing.allocator, input);
        defer actual.deinit(testing.allocator);

        try testing.expectEqualSlices(
            u32,
            expected.indexes[0..expected.count],
            actual.indexes[0..actual.count],
        );
        try testing.expectEqualSlices(
            @TypeOf(expected.kinds[0]),
            expected.kinds[0..expected.count],
            actual.kinds[0..actual.count],
        );
    }
}

test "corpus: JSON indexing on example_config.json" {
    const json_data = @embedFile("corpus/json/example_config.json");
    try expectStructuralWidths(lib.formats.json.indexJsonImpl, json_data);
}

test "corpus: JSONL indexing on amazon_cellphones.ndjson" {
    const jsonl_data = @embedFile("corpus/jsonl/amazon_cellphones.ndjson");
    try expectStructuralWidths(lib.formats.jsonl.indexJsonlImpl, jsonl_data);
}

test "corpus: JSONC indexing on config.jsonc" {
    const jsonc_data = @embedFile("corpus/jsonc/config.jsonc");
    try expectStructuralWidths(lib.formats.jsonc.indexJsoncImpl, jsonc_data);
}

test "corpus: JSON5 indexing on sample.json5" {
    const json5_data = @embedFile("corpus/json5/sample.json5");
    try expectStructuralWidths(lib.formats.json5.indexJson5Impl, json5_data);
}

test "corpus: Markdown indexing on document.md" {
    const md_data = @embedFile("corpus/markdown/document.md");
    try expectTokenWidths(lib.formats.markdown.indexMarkdownImpl, md_data);
}

test "corpus: XML indexing on catalog.xml" {
    const xml_data = @embedFile("corpus/xml/catalog.xml");
    try expectTokenWidths(lib.formats.xml.indexXmlImpl, xml_data);
}
test "public Stage 2 JSON corpus builds validates and exposes raw spans" {
    const input = @embedFile("corpus/json/example_config.json");
    try testing.expect((try lib.formats.json.validateJson(testing.allocator, input)) == null);

    var document = try lib.formats.json.buildJsonTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(lib.stage2.Dialect.json, document.dialect);
    try testing.expect(document.tape.len > 0);

    var cursor = try document.root(input);
    try testing.expectEqual(
        lib.stage2.TapeKind.object_start,
        (try cursor.peek()).tapeKind(),
    );
    try cursor.advance();
    try testing.expectEqual(lib.stage2.TapeKind.key, (try cursor.peek()).tapeKind());
    const key_word = try cursor.peek();
    const raw_key = try cursor.rawValue();
    try testing.expectEqualStrings("app_name", raw_key);
    try testing.expect(
        raw_key.ptr == input.ptr + @as(usize, key_word.offset) + 1,
    );
    try cursor.advance();
    try testing.expectEqualStrings("MyApp", try cursor.rawValue());

    const invalid_input = "[1,]";
    const diagnostic = (try lib.formats.json.validateJson(
        testing.allocator,
        invalid_input,
    )).?;
    try testing.expectEqual(error.TrailingComma, diagnostic.err);
    try testing.expectEqual(
        std.mem.indexOfScalar(u8, invalid_input, ']').?,
        diagnostic.byte_offset,
    );
}

test "public Stage 2 JSONC corpus accepts comments and rejects trailing commas" {
    const input = @embedFile("corpus/jsonc/config.jsonc");
    try testing.expect((try lib.formats.jsonc.validateJsonc(
        testing.allocator,
        input,
    )) == null);

    var document = try lib.formats.jsonc.buildJsoncTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(lib.stage2.Dialect.jsonc, document.dialect);
    var cursor = try document.root(input);
    try cursor.advance();
    const key_word = try cursor.peek();
    try testing.expectEqual(lib.stage2.TapeKind.key, key_word.tapeKind());
    const raw_key = try cursor.rawValue();
    try testing.expectEqualStrings("name", raw_key);
    try testing.expect(
        raw_key.ptr == input.ptr + @as(usize, key_word.offset) + 1,
    );

    const invalid_input = "{\"a\":1,}";
    const diagnostic = (try lib.formats.jsonc.validateJsonc(
        testing.allocator,
        invalid_input,
    )).?;
    try testing.expectEqual(error.TrailingComma, diagnostic.err);
    try testing.expectEqual(
        std.mem.indexOfScalar(u8, invalid_input, '}').?,
        diagnostic.byte_offset,
    );
}

test "public Stage 2 JSON5 corpus preserves extended grammar raw spans" {
    const input = @embedFile("corpus/json5/sample.json5");
    try testing.expect((try lib.formats.json5.validateJson5(
        testing.allocator,
        input,
    )) == null);

    var document = try lib.formats.json5.buildJson5Tape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(lib.stage2.Dialect.json5, document.dialect);
    var cursor = try document.root(input);
    var saw_unquoted_key = false;
    var saw_single_quoted_string = false;
    var saw_hex_number = false;

    while (cursor.position() < document.tape.len) {
        const word = try cursor.peek();
        switch (word.tapeKind()) {
            .key, .string, .number, .true_literal, .false_literal, .null_literal => {
                const raw = try cursor.rawValue();
                const source_offset: usize = @intCast(word.offset);
                const raw_start = if (input[source_offset] == '\'' or
                    input[source_offset] == '"')
                    source_offset + 1
                else
                    source_offset;
                try testing.expect(raw.ptr == input.ptr + raw_start);
                if (std.mem.eql(u8, raw, "unquotedKey")) saw_unquoted_key = true;
                if (std.mem.eql(u8, raw, "single quoted value with \"nested double quotes\"")) {
                    saw_single_quoted_string = true;
                }
                if (std.mem.eql(u8, raw, "0xDEADBEEF")) saw_hex_number = true;
            },
            else => {},
        }
        try cursor.advance();
    }

    try testing.expect(saw_unquoted_key);
    try testing.expect(saw_single_quoted_string);
    try testing.expect(saw_hex_number);

    const invalid_input = "{value:01}";
    const diagnostic = (try lib.formats.json5.validateJson5(
        testing.allocator,
        invalid_input,
    )).?;
    try testing.expectEqual(error.InvalidNumber, diagnostic.err);
    try testing.expectEqual(@as(usize, 8), diagnostic.byte_offset);
}

test "public Stage 2 JSONL corpus exposes records and global diagnostics" {
    const corpus = @embedFile("corpus/jsonl/amazon_cellphones.ndjson");
    try testing.expect((try lib.formats.jsonl.validateJsonl(
        testing.allocator,
        corpus,
    )) == null);

    var corpus_document = try lib.formats.jsonl.buildJsonlTape(
        testing.allocator,
        corpus,
    );
    defer corpus_document.deinit(testing.allocator);
    try testing.expect(corpus_document.records.len > 0);
    const first_corpus_record = corpus_document.record(0).?;
    try testing.expectEqual(@as(usize, 0), first_corpus_record.source_start);
    try testing.expect(first_corpus_record.source_end > first_corpus_record.source_start);
    var corpus_cursor = try first_corpus_record.root();
    try testing.expectEqual(
        lib.stage2.TapeKind.array_start,
        (try corpus_cursor.peek()).tapeKind(),
    );

    const input = " \r\n\n{\"a\":1}\r\n2\r\n\n";
    try testing.expect((try lib.formats.jsonl.validateJsonl(
        testing.allocator,
        input,
    )) == null);
    var document = try lib.formats.jsonl.buildJsonlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), document.records.len);
    try testing.expectEqualStrings("{\"a\":1}\r", document.records[0].source);
    try testing.expectEqualStrings("2\r", document.records[1].source);
    try testing.expectEqual(@as(usize, 4), document.records[0].source_start);
    try testing.expectEqual(@as(usize, 13), document.records[1].source_start);
    try testing.expect(document.record(2) == null);

    var record_cursor = try document.cursor(0);
    try record_cursor.advance();
    const record_key_word = try record_cursor.peek();
    const record_key = try record_cursor.rawValue();
    try testing.expectEqualStrings("a", record_key);
    try testing.expect(
        record_key.ptr ==
            input.ptr + document.records[0].source_start +
                @as(usize, record_key_word.offset) + 1,
    );

    const invalid_input = "{}\n  [1,]\n{}\n";
    const close_bracket = std.mem.indexOfScalar(u8, invalid_input, ']').?;
    const diagnostic = (try lib.formats.jsonl.validateJsonl(
        testing.allocator,
        invalid_input,
    )).?;
    try testing.expectEqual(@as(usize, 1), diagnostic.record_index);
    try testing.expectEqual(@as(usize, 3), diagnostic.source_start);
    try testing.expectEqual(close_bracket + 1, diagnostic.source_end);
    try testing.expectEqual(error.TrailingComma, diagnostic.err);
    try testing.expectEqual(close_bracket, diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), diagnostic.line);
    try testing.expectEqual(@as(u32, 6), diagnostic.column);
    try testing.expect(
        diagnostic.snippet.ptr == invalid_input.ptr + diagnostic.snippet_start,
    );
}

test "public Stage 2 Markdown corpus preserves token parity and local limits" {
    const input = @embedFile("corpus/markdown/document.md");
    var index = try lib.formats.markdown.indexMarkdown(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expect((try lib.formats.markdown.validateMarkdown(
        testing.allocator,
        input,
    )) == null);

    var document = try lib.formats.markdown.buildMarkdownTape(
        testing.allocator,
        input,
    );
    defer document.deinit(testing.allocator);
    try testing.expectEqual(index.count, document.tape.len);
    for (document.tape, 0..) |word, tape_index| {
        try testing.expectEqual(index.kinds[tape_index], word.tapeKind());
        try testing.expectEqual(index.indexes[tape_index], word.offset);
        try testing.expect(@as(usize, word.offset) < input.len);
    }

    const unclosed_fence = "```zig\n# hidden [x](y)";
    try testing.expect((try lib.formats.markdown.validateMarkdown(
        testing.allocator,
        unclosed_fence,
    )) == null);
    var fence_document = try lib.formats.markdown.buildMarkdownTape(
        testing.allocator,
        unclosed_fence,
    );
    defer fence_document.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), fence_document.tape.len);
    try testing.expectEqual(
        lib.formats.markdown.MarkdownTokenKind.code_fence,
        fence_document.tape[0].tapeKind(),
    );

    const invalid_input = "#";
    var indexes = [_]u32{@intCast(invalid_input.len)};
    var kinds = [_]lib.formats.markdown.MarkdownTokenKind{.heading};
    const forged = lib.formats.markdown.MarkdownStructuralIndex{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 1,
    };
    const diagnostic = (try lib.formats.markdown.validateMarkdownIndex(
        invalid_input,
        &forged,
    )).?;
    try testing.expectEqual(error.InvalidTokenIndex, diagnostic.err);
    try testing.expectEqual(invalid_input.len, diagnostic.byte_offset);
}

test "public Stage 2 XML catalog exposes source spans and matching errors" {
    const input = @embedFile("corpus/xml/catalog.xml");
    try testing.expect((try lib.formats.xml.validateXml(input)) == null);

    var document = try lib.formats.xml.buildXmlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    try testing.expect(document.tape.len > 0);

    var saw_declaration = false;
    var saw_comment = false;
    var saw_attribute = false;
    var saw_text = false;
    var saw_cdata = false;
    var saw_self_close = false;
    for (document.tape, 0..) |word, tape_index| {
        const span = try document.sourceSpan(input, tape_index);
        try testing.expect(span.ptr == input.ptr + @as(usize, word.offset));
        try testing.expectEqual(word.sourceLength(), span.len);
        switch (word.tapeKind()) {
            .xml_declaration => saw_declaration = true,
            .comment => saw_comment = true,
            .attribute => saw_attribute = true,
            .text => saw_text = true,
            .cdata => saw_cdata = true,
            .self_closing_element => saw_self_close = true,
            else => {},
        }
    }
    try testing.expect(saw_declaration);
    try testing.expect(saw_comment);
    try testing.expect(saw_attribute);
    try testing.expect(saw_text);
    try testing.expect(saw_cdata);
    try testing.expect(saw_self_close);

    const invalid_input = "<a><b></a>";
    const diagnostic = (try lib.formats.xml.validateXml(invalid_input)).?;
    try testing.expectEqual(error.MismatchedTag, diagnostic.err);
    try testing.expectEqual(@as(usize, 8), diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 1), diagnostic.line);
    try testing.expectEqual(@as(u32, 9), diagnostic.column);
}

test "public JSON cursor keeps exact input and document live through nested navigation" {
    const input =
        \\{"nested":[1,{"deep":[]}],"empty_object":{},"empty_array":[]}
    ;
    var document = try lib.formats.json.buildJsonTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var cursor: lib.stage2.TapeCursor = try document.root(input);
    try testing.expectEqual(lib.stage2.TapeKind.object_start, (try cursor.peek()).tapeKind());
    try testing.expectEqual(@as(u32, 3), try cursor.containerCount());

    try cursor.advance();
    try testing.expectEqualStrings("nested", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqual(@as(u32, 2), try cursor.containerCount());

    var inner_end = cursor;
    try inner_end.advance();
    try inner_end.skipValue();
    try inner_end.advance();
    try inner_end.advance();
    try inner_end.skipValue();
    try inner_end.advance();
    try testing.expectEqual(
        lib.stage2.TapeKind.array_end,
        (try inner_end.peek()).tapeKind(),
    );
    const inner_start = try inner_end.matchingStart();
    try testing.expectEqual(@as(usize, 2), inner_start.position());

    var nested_end = cursor;
    try nested_end.advance();
    try nested_end.skipValue();
    try nested_end.skipValue();
    try testing.expectEqual(lib.stage2.TapeKind.array_end, (try nested_end.peek()).tapeKind());
    const nested_start = try nested_end.matchingStart();
    try testing.expectEqual(cursor.position(), nested_start.position());

    try cursor.skipValue();
    try testing.expectEqual(lib.stage2.TapeKind.key, (try cursor.peek()).tapeKind());
    try testing.expectEqual(@as(usize, 10), cursor.position());
    try testing.expectEqualStrings("empty_object", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqual(@as(u32, 0), try cursor.containerCount());
    try cursor.skipValue();

    try testing.expectEqualStrings("empty_array", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqual(@as(u32, 0), try cursor.containerCount());
    try cursor.skipValue();

    try testing.expectEqual(lib.stage2.TapeKind.object_end, (try cursor.peek()).tapeKind());
    const root_start = try cursor.matchingStart();
    try testing.expectEqual(@as(usize, 0), root_start.position());
}

test "public JSON cursor rejects malformed borrowed source and public tape" {
    const input = "\"value\"";
    var document = try lib.formats.json.buildJsonTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var wrong_source_cursor = try document.root("\"x\"");
    try testing.expectError(error.SourceOutOfBounds, wrong_source_cursor.rawValue());

    var invalid_source_cursor = try document.root("\"valuex");
    try testing.expectError(error.InvalidSource, invalid_source_cursor.rawValue());

    const escaped_input = "\"a\\n\"";
    var escaped_document = try lib.formats.json.buildJsonTape(
        testing.allocator,
        escaped_input,
    );
    defer escaped_document.deinit(testing.allocator);
    var malformed_escape_cursor = try escaped_document.root("\"a\\q\"");
    try testing.expectError(error.InvalidSource, malformed_escape_cursor.rawValue());

    var empty_tape: [0]lib.stage2.TapeWord = .{};
    const empty_document = lib.stage2.Document{
        .tape = empty_tape[0..],
        .dialect = .json,
    };
    try testing.expectError(error.TapeOutOfBounds, empty_document.root(""));

    var invalid_kind_tape = [_]lib.stage2.TapeWord{.{
        .kind = std.math.maxInt(u8),
        .payload = 0,
        .offset = 0,
    }};
    const invalid_kind_document = lib.stage2.Document{
        .tape = invalid_kind_tape[0..],
        .dialect = .json,
    };
    try testing.expectError(error.InvalidTapeKind, invalid_kind_document.root("0"));

    var wrong_end_tape = [_]lib.stage2.TapeWord{
        .{
            .kind = @intFromEnum(lib.stage2.TapeKind.array_start),
            .payload = 0,
            .offset = 0,
        },
        .{
            .kind = @intFromEnum(lib.stage2.TapeKind.object_end),
            .payload = 0,
            .offset = 1,
        },
    };
    const wrong_end_document = lib.stage2.Document{
        .tape = wrong_end_tape[0..],
        .dialect = .json,
    };
    var wrong_end_cursor = try wrong_end_document.root("[]");
    try testing.expectError(error.InvalidTapeOrder, wrong_end_cursor.skipValue());

    var malformed_interior_tape = [_]lib.stage2.TapeWord{
        .{
            .kind = @intFromEnum(lib.stage2.TapeKind.array_start),
            .payload = 0,
            .offset = 0,
        },
        .{
            .kind = @intFromEnum(lib.stage2.TapeKind.number),
            .payload = 0,
            .offset = 1,
        },
        .{
            .kind = @intFromEnum(lib.stage2.TapeKind.array_end),
            .payload = 0,
            .offset = 2,
        },
    };
    const malformed_interior_document = lib.stage2.Document{
        .tape = malformed_interior_tape[0..],
        .dialect = .json,
    };
    var malformed_interior_end = try malformed_interior_document.root("[0]");
    try malformed_interior_end.advance();
    try malformed_interior_end.advance();
    const malformed_interior_start = try malformed_interior_end.matchingStart();
    try testing.expectEqual(@as(usize, 0), malformed_interior_start.position());
}

fn expectOnDemandEvent(
    expected: lib.ondemand.Event,
    actual: lib.ondemand.Event,
) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .key => |raw| switch (actual) {
            .key => |actual_raw| try testing.expectEqualStrings(raw, actual_raw),
            else => unreachable,
        },
        .string => |raw| switch (actual) {
            .string => |actual_raw| try testing.expectEqualStrings(raw, actual_raw),
            else => unreachable,
        },
        .number => |raw| switch (actual) {
            .number => |actual_raw| try testing.expectEqualStrings(raw, actual_raw),
            else => unreachable,
        },
        .bool => |value| switch (actual) {
            .bool => |actual_value| try testing.expectEqual(value, actual_value),
            else => unreachable,
        },
        else => {},
    }
}

test "on-demand Parser emits JSON events from quote-aware indexes" {
    const input =
        \\{"syntax{}[],:":"text { [ ] } , :","items":[42,true,false,null]}
    ;
    var parser = try lib.ondemand.Parser.init(testing.allocator, input.len);
    defer parser.deinit();

    var document = document: {
        var structural_index = try lib.formats.json.indexJson(testing.allocator, input);
        defer structural_index.deinit(testing.allocator);
        break :document try parser.iterate(input, &structural_index);
    };
    defer document.deinit();
    var reader = try document.eventReader();

    try expectOnDemandEvent(.object_start, (try reader.next()).?);
    try expectOnDemandEvent(.{ .key = "syntax{}[],:" }, (try reader.peek()).?);
    try expectOnDemandEvent(.{ .key = "syntax{}[],:" }, (try reader.next()).?);
    try expectOnDemandEvent(.{ .string = "text { [ ] } , :" }, (try reader.next()).?);
    try expectOnDemandEvent(.{ .key = "items" }, (try reader.next()).?);
    try expectOnDemandEvent(.array_start, (try reader.next()).?);
    try expectOnDemandEvent(.{ .number = "42" }, (try reader.next()).?);
    try expectOnDemandEvent(.{ .bool = true }, (try reader.next()).?);
    try expectOnDemandEvent(.{ .bool = false }, (try reader.next()).?);
    try expectOnDemandEvent(.null, (try reader.next()).?);
    try expectOnDemandEvent(.array_end, (try reader.next()).?);
    try expectOnDemandEvent(.object_end, (try reader.next()).?);
    try testing.expect((try reader.next()) == null);
}

test "on-demand EventReader skips one nested JSON value" {
    const input =
        \\{"skip":{"quoted":"{ [ , : ] }","nested":[1,{"deep":false}]},"after":null}
    ;
    var parser = try lib.ondemand.Parser.init(testing.allocator, input.len);
    defer parser.deinit();

    var document = document: {
        var structural_index = try lib.formats.json.indexJson(testing.allocator, input);
        defer structural_index.deinit(testing.allocator);
        break :document try parser.initDocument(input, &structural_index);
    };
    defer document.deinit();
    var reader = try document.eventReader();

    try expectOnDemandEvent(.object_start, (try reader.next()).?);
    try expectOnDemandEvent(.{ .key = "skip" }, (try reader.next()).?);
    try reader.skip();
    try expectOnDemandEvent(.{ .key = "after" }, (try reader.next()).?);
    try expectOnDemandEvent(.null, (try reader.next()).?);
    try expectOnDemandEvent(.object_end, (try reader.next()).?);
    try testing.expect((try reader.next()) == null);
}

const stream_sentinel_count: usize = 3;

fn expectJsonStreamParity(
    input: []const u8,
    actual: *const lib.StructuralIndex,
) !void {
    var expected = try lib.formats.json.indexJson(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0..expected.count],
        actual.indexes[0..actual.count],
    );
    try testing.expectEqualSlices(
        u32,
        expected.indexes[expected.count..][0..stream_sentinel_count],
        actual.indexes[actual.count..][0..stream_sentinel_count],
    );
}

fn expectJsonStreamWithCuts(
    input: []const u8,
    cuts: []const usize,
    empty_feeds: bool,
) !void {
    var stream = try lib.stream.StreamIndexer.init(testing.allocator, vector_len);
    defer stream.deinit();

    var start: usize = 0;
    if (empty_feeds) try stream.feed("");
    for (cuts) |cut| {
        try testing.expect(cut >= start);
        try testing.expect(cut <= input.len);
        try stream.feed(input[start..cut]);
        if (empty_feeds) try stream.feed("");
        start = cut;
    }
    try stream.feed(input[start..]);
    if (empty_feeds) try stream.feed("");
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try expectJsonStreamParity(input, &actual);
}

fn expectJsonStreamByteFeeds(input: []const u8) !void {
    var stream = try lib.stream.StreamIndexer.init(testing.allocator, 1);
    defer stream.deinit();

    for (input) |byte| {
        try stream.feed(&.{byte});
    }
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try expectJsonStreamParity(input, &actual);
}

test "stream: one feed and byte feeds match JSON indexing" {
    const input =
        \\{"text":"punctuation {}[],: stays quoted","value":-12345,"ok":true}
    ;

    try expectJsonStreamWithCuts(input, &.{}, false);
    try expectJsonStreamByteFeeds(input);
}

test "stream: empty feeds and SIMD boundary cuts match JSON indexing" {
    const input =
        \\{"padding":"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz","tail":[false,null,-987654321]}
    ;
    const cuts = [_]usize{
        vector_len - 1,
        vector_len,
        vector_len + 1,
    };

    try expectJsonStreamWithCuts(input, &cuts, true);
}

test "stream: quote backslash and atom splits match JSON indexing" {
    const input =
        \\{"text":"odd\\\"quote","atom":-12345,"bool":true}
    ;
    const quote_cut = std.mem.indexOf(u8, input, "\"odd").? + 1;
    const backslash_cut = std.mem.indexOf(u8, input, "\\\\\\\"").? + 2;
    const atom_cut = std.mem.indexOf(u8, input, "-12345").? + 3;
    const cuts = [_]usize{ quote_cut, backslash_cut, atom_cut };

    try expectJsonStreamWithCuts(input, &cuts, false);
}

test "stream: finish is idempotent and take survives reset" {
    const first_input = "{\"first\":\"quoted []{}:,\",\"value\":false}";
    const second_input = "[-1,null,\"second\\\\document\"]";

    var results = results: {
        var stream = try lib.stream.StreamIndexer.init(testing.allocator, 2);
        defer stream.deinit();

        try stream.feed(first_input);
        try stream.finish();
        try stream.finish();
        var first = stream.take();
        errdefer first.deinit(testing.allocator);

        stream.reset();
        try stream.feed("");
        try stream.feed(second_input[0..3]);
        try stream.feed(second_input[3..]);
        try stream.finish();
        try stream.finish();
        const second = stream.take();

        break :results .{
            .first = first,
            .second = second,
        };
    };
    defer results.first.deinit(testing.allocator);
    defer results.second.deinit(testing.allocator);

    try expectJsonStreamParity(first_input, &results.first);
    try expectJsonStreamParity(second_input, &results.second);
}
