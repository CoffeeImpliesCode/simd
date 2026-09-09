const std = @import("std");
const lib = @import("simd_lib");
const checking = @import("checking.zig");
const resident_contract = @import("resident_contract_test.zig");
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
    testing.refAllDecls(lib.formats.yaml);
    testing.refAllDecls(resident_contract);
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
        try testing.expectEqual(checking.scalarPrefixXor(u64, pattern), simd_result);
    }
}

test "upstream corpus manifests pin provenance for offline tests" {
    const manifests = [_]struct {
        contents: []const u8,
        source: []const u8,
        revision: []const u8,
        offline_rule: []const u8,
    }{
        .{
            .contents = @embedFile("corpus/upstream/json/MANIFEST.md"),
            .source = "https://github.com/nst/JSONTestSuite",
            .revision = "1ef36fa01286573e846ac449e8683f8833c5b26a",
            .offline_rule = "Tests must use only checked-in corpus files and metadata.",
        },
        .{
            .contents = @embedFile("corpus/upstream/jsonl/MANIFEST.md"),
            .source = "wardi/jsonlines",
            .revision = "a8e8671adf470477cd2cc1dfc40c30825f421baa",
            .offline_rule = "Tests must read checked-in files only.",
        },
        .{
            .contents = @embedFile("corpus/upstream/jsonc/MANIFEST.md"),
            .source = "https://github.com/microsoft/node-jsonc-parser.git",
            .revision = "37e207ed23f544efc33a1893f21e0bf10b250df0",
            .offline_rule = "Corpus tests must use only checked-in files",
        },
        .{
            .contents = @embedFile("corpus/upstream/json5/MANIFEST.md"),
            .source = "https://github.com/json5/json5-tests.git",
            .revision = "ceb24d4080137d70833f86c25659c1331b80a387",
            .offline_rule = "Tests must read only checked-in local files",
        },
        .{
            .contents = @embedFile("corpus/upstream/markdown/MANIFEST.md"),
            .source = "commonmark/commonmark-spec",
            .revision = "9103e341a973013013bb1a80e13567007c5cef6f",
            .offline_rule = "must not fetch network resources during tests",
        },
        .{
            .contents = @embedFile("corpus/upstream/xml/MANIFEST.md"),
            .source = "https://www.w3.org/XML/Test/xmlts20130923.tar.gz",
            .revision = "9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f",
            .offline_rule = "Tests must not access the network.",
        },
        .{
            .contents = @embedFile("corpus/upstream/yaml/MANIFEST.md"),
            .source = "https://github.com/yaml/yaml-test-suite",
            .revision = "6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f",
            .offline_rule = "Tests must read only checked-in corpus files and metadata.",
        },
    };

    for (manifests) |manifest| {
        try testing.expect(manifest.contents.len > 0);
        try testing.expect(std.mem.indexOf(u8, manifest.contents, manifest.source) != null);
        try testing.expect(std.mem.indexOf(u8, manifest.contents, manifest.revision) != null);
        try testing.expect(std.mem.indexOf(u8, manifest.contents, manifest.offline_rule) != null);
    }
}

test "corpus: JSON indexing on example_config.json" {
    const json_data = @embedFile("corpus/json/example_config.json");
    try checking.expectStructuralWidths(lib.formats.json.indexJsonImpl, json_data);
}

test "corpus: JSONL indexing on amazon_cellphones.ndjson" {
    const jsonl_data = @embedFile("corpus/jsonl/amazon_cellphones.ndjson");
    try checking.expectStructuralWidths(lib.formats.jsonl.indexJsonlImpl, jsonl_data);
}

test "corpus: JSONC indexing on config.jsonc" {
    const jsonc_data = @embedFile("corpus/jsonc/config.jsonc");
    try checking.expectStructuralWidths(lib.formats.jsonc.indexJsoncImpl, jsonc_data);
}

test "corpus: JSON5 indexing on sample.json5" {
    const json5_data = @embedFile("corpus/json5/sample.json5");
    try checking.expectStructuralWidths(lib.formats.json5.indexJson5Impl, json5_data);
}

test "corpus: Markdown indexing on document.md" {
    const md_data = @embedFile("corpus/markdown/document.md");
    try checking.expectTokenWidths(lib.formats.markdown.indexMarkdownImpl, md_data);
}

test "corpus: XML indexing on catalog.xml" {
    const xml_data = @embedFile("corpus/xml/catalog.xml");
    try checking.expectTokenWidths(lib.formats.xml.indexXmlImpl, xml_data);
}

test "corpus: YAML indexing on basic.yaml" {
    const yaml_data = @embedFile("corpus/yaml/basic.yaml");
    try checking.expectStructuralWidths(lib.formats.yaml.indexYamlImpl, yaml_data);
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

test "public Stage 2 rejects a mutated index view before allocation" {
    const input = "[0]";
    var offsets = [_]u32{ 0, 1, 2 };
    const view = try lib.stage2.IndexView.init(input, &offsets, 0);
    offsets[1] = @intCast(input.len);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try testing.expectError(
        error.InvalidStructuralIndex,
        lib.stage2.buildTapeView(failing.allocator(), input, view, .json),
    );
    try testing.expectError(
        error.InvalidStructuralIndex,
        lib.stage2.validateView(input, view, .json),
    );
}

test "public JSONL tapes keep nested links local through final record" {
    const input = "\n{\"a\":[1,{\"b\":[]}]}\r\n[[2],{\"c\":3}]";
    var document = try lib.formats.jsonl.buildJsonlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), document.records.len);
    try testing.expectEqualStrings(
        "{\"a\":[1,{\"b\":[]}]}\r",
        document.records[0].source,
    );
    try testing.expectEqualStrings("[[2],{\"c\":3}]", document.records[1].source);
    try testing.expectEqual(input.len, document.records[1].source_end);

    var first = try document.cursor(0);
    var second = try document.cursor(1);
    try testing.expectEqual(
        lib.stage2.TapeKind.object_start,
        (try first.peek()).tapeKind(),
    );
    try testing.expectEqual(
        lib.stage2.TapeKind.array_start,
        (try second.peek()).tapeKind(),
    );
    try first.advance();
    try second.advance();
    try testing.expectEqual(lib.stage2.TapeKind.key, (try first.peek()).tapeKind());
    try testing.expectEqual(
        lib.stage2.TapeKind.array_start,
        (try second.peek()).tapeKind(),
    );

    for (document.records) |*record_value| {
        var cursor = try record_value.root();
        while (cursor.position() < record_value.document.tape.len) {
            const word = try cursor.peek();
            switch (word.tapeKind()) {
                .object_end, .array_end => {
                    const end_position = cursor.position();
                    const start = try cursor.matchingStart();
                    try testing.expect(start.position() < end_position);
                    try testing.expect(start.position() < record_value.document.tape.len);
                },
                else => {},
            }
            try cursor.advance();
        }
    }
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

test "public YAML corpus exposes index, tape, diagnostics, and unsupported results" {
    const input = @embedFile("corpus/yaml/basic.yaml");

    try testing.expect((try lib.formats.yaml.validateYaml(
        testing.allocator,
        input,
    )) == null);

    var index = try lib.formats.yaml.indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expect((try lib.formats.yaml.validateYamlIndex(
        testing.allocator,
        input,
        &index,
    )) == null);

    var document = try lib.formats.yaml.buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    try testing.expectEqual(index.count, document.tape.len);

    var cursor = try document.root(input);
    try testing.expectEqual(
        lib.formats.yaml.YamlTokenKind.document_start,
        (try cursor.peek()).tapeKind(),
    );
    for (document.tape, 0..) |word, tape_index| {
        try testing.expectEqual(index.kinds[tape_index], word.tapeKind());
        try testing.expectEqual(index.indexes[tape_index], word.offset);
        try testing.expectEqual(
            @as(usize, index.lengths[tape_index]),
            word.sourceLength(),
        );
        switch (word.tapeKind()) {
            .key, .scalar => {
                const span = try cursor.span();
                try testing.expect(span.ptr == input.ptr + @as(usize, word.offset));
                try testing.expectEqual(word.sourceLength(), span.len);
            },
            else => {},
        }
        try cursor.advance();
    }

    const invalid_input = "name: [Ada,]\n";
    const invalid = (try lib.formats.yaml.validateYaml(
        testing.allocator,
        invalid_input,
    )).?;
    try testing.expectEqual(error.Invalid, invalid.err);
    try testing.expectEqual(
        lib.formats.yaml.YamlDiagnosticKind.syntax,
        invalid.kind,
    );
    try testing.expectEqual(@as(u32, 1), invalid.line);
    try testing.expect(invalid.column > 1);
    try testing.expect(invalid.byte_offset < invalid_input.len);
    const direct = lib.formats.yaml.yamlDiagnosticAt(
        invalid_input,
        error.Invalid,
        invalid.byte_offset,
    );
    try testing.expectEqual(invalid.byte_offset, direct.byte_offset);
    try testing.expectEqual(invalid.snippet_start, direct.snippet_start);

    const unsupported_input = "%YAML 1.2\nname: Ada\n";
    const unsupported = (try lib.formats.yaml.validateYaml(
        testing.allocator,
        unsupported_input,
    )).?;
    try testing.expectEqual(error.Unsupported, unsupported.err);
    try testing.expectEqual(
        lib.formats.yaml.YamlDiagnosticKind.unsupported,
        unsupported.kind,
    );
    try testing.expectError(
        error.Unsupported,
        lib.formats.yaml.buildYamlTape(testing.allocator, unsupported_input),
    );
}

test "public YAML stream matches one-shot index across byte feeds" {
    const input = @embedFile("corpus/yaml/basic.yaml");
    var expected = try lib.formats.yaml.indexYaml(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var stream = try lib.formats.yaml.YamlStreamIndexer.init(testing.allocator, 1);
    defer stream.deinit();
    for (input, 0..) |_, offset| {
        try stream.feed(input[offset .. offset + 1]);
    }
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    try testing.expectEqualSlices(
        lib.formats.yaml.YamlTokenKind,
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
    try testing.expectEqualSlices(
        u32,
        expected.lengths[0..expected.count],
        actual.lengths[0..actual.count],
    );
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

fn expectOnDemandRawStringEvent(
    expected_raw: []const u8,
    actual: lib.ondemand.Event,
) !void {
    try expectOnDemandEvent(.{ .string = expected_raw }, actual);
    switch (actual) {
        .string => |raw| try testing.expect(raw.ptr == expected_raw.ptr),
        else => unreachable,
    }
}

fn expectOnDemandStringDocument(
    input: []const u8,
    expected_raw: []const u8,
) !void {
    var parser = try lib.ondemand.Parser.init(testing.allocator, input.len);
    defer parser.deinit();

    var document = try lib.formats.json.initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();

    const event = (try reader.next()) orelse return error.TestUnexpectedResult;
    try expectOnDemandRawStringEvent(expected_raw, event);
    try testing.expect((try reader.next()) == null);
}

fn expectOnDemandErrorAfterEvents(
    input: []const u8,
    expected_events: []const lib.ondemand.Event,
    expected_error: anyerror,
) !void {
    var parser = try lib.ondemand.Parser.init(testing.allocator, input.len);
    defer parser.deinit();

    var document = try lib.formats.json.initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();

    for (expected_events) |expected| {
        const event = (try reader.next()) orelse return error.TestUnexpectedResult;
        try expectOnDemandEvent(expected, event);
    }
    try testing.expectError(expected_error, reader.next());
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

test "on-demand EventReader preserves long ASCII raw string slices" {
    const raw_len = 1024;
    var input: [raw_len + 2]u8 = undefined;
    input[0] = '"';
    @memset(input[1 .. input.len - 1], 'a');
    input[input.len - 1] = '"';

    try expectOnDemandStringDocument(&input, input[1 .. input.len - 1]);
}

test "on-demand EventReader scans quotes and backslashes at SIMD boundaries" {
    const widths = [_]usize{ 16, 32, 64, 128, 256, 512 };

    inline for (widths) |width| {
        const boundary_offsets = [_]usize{ width - 1, width, width + 1 };
        inline for (boundary_offsets) |boundary_offset| {
            var quote_input: [520]u8 = undefined;
            const quote_input_len = boundary_offset + 1;
            @memset(quote_input[0..quote_input_len], 'a');
            quote_input[0] = '"';
            quote_input[boundary_offset] = '"';
            try expectOnDemandStringDocument(
                quote_input[0..quote_input_len],
                quote_input[1..boundary_offset],
            );

            var backslash_input: [520]u8 = undefined;
            const closing_quote_offset = boundary_offset + 3;
            const backslash_input_len = closing_quote_offset + 1;
            @memset(backslash_input[0..backslash_input_len], 'a');
            backslash_input[0] = '"';
            backslash_input[boundary_offset] = '\\';
            backslash_input[boundary_offset + 1] = '"';
            backslash_input[boundary_offset + 2] = 'z';
            backslash_input[closing_quote_offset] = '"';
            try expectOnDemandStringDocument(
                backslash_input[0..backslash_input_len],
                backslash_input[1..closing_quote_offset],
            );
        }
    }
}

test "on-demand EventReader rejects raw controls and malformed escapes" {
    const cases = [_]struct {
        input: []const u8,
        expected_error: anyerror,
    }{
        .{ .input = "\"\x00\"", .expected_error = error.InvalidEscape },
        .{ .input = "\"\x1f\"", .expected_error = error.InvalidEscape },
        .{ .input = "\"\n\"", .expected_error = error.InvalidEscape },
        .{ .input = "\"\\q\"", .expected_error = error.InvalidEscape },
        .{ .input = "\"\\u12G4\"", .expected_error = error.InvalidEscape },
        .{ .input = "\"\\u123\"", .expected_error = error.InvalidEscape },
    };

    for (cases) |case| {
        try expectOnDemandErrorAfterEvents(
            case.input,
            &.{},
            case.expected_error,
        );
    }
}

test "on-demand EventReader accepts multibyte UTF-8 across SIMD boundaries" {
    const widths = [_]usize{ 16, 32, 64, 128, 256, 512 };
    const sequences = [_][]const u8{
        "\xc2\xa2",
        "\xe2\x82\xac",
        "\xf0\x9f\x98\x80",
    };

    inline for (widths) |width| {
        for (sequences) |sequence| {
            var input: [520]u8 = undefined;
            const sequence_start = width - 1;
            const closing_quote_offset = sequence_start + sequence.len;
            const input_len = closing_quote_offset + 1;
            @memset(input[0..input_len], 'a');
            input[0] = '"';
            @memcpy(
                input[sequence_start..closing_quote_offset],
                sequence,
            );
            input[closing_quote_offset] = '"';

            try expectOnDemandStringDocument(
                input[0..input_len],
                input[1..closing_quote_offset],
            );
        }
    }
}

test "on-demand EventReader rejects invalid UTF-8 across SIMD boundaries" {
    const widths = [_]usize{ 16, 32, 64, 128, 256, 512 };
    const invalid_sequences = [_][]const u8{
        &.{0x80},
        &.{ 0xc0, 0xaf },
        &.{ 0xe2, 0x82 },
        &.{ 0xed, 0xa0, 0x80 },
        &.{ 0xf4, 0x90, 0x80, 0x80 },
    };

    inline for (widths) |width| {
        for (invalid_sequences) |sequence| {
            var input: [520]u8 = undefined;
            const sequence_start = width - 1;
            const closing_quote_offset = sequence_start + sequence.len;
            const input_len = closing_quote_offset + 1;
            @memset(input[0..input_len], 'a');
            input[0] = '"';
            @memcpy(
                input[sequence_start..closing_quote_offset],
                sequence,
            );
            input[closing_quote_offset] = '"';

            try expectOnDemandErrorAfterEvents(
                input[0..input_len],
                &.{},
                error.InvalidUtf8,
            );
        }
    }
}

test "on-demand EventReader reports string syntax before UTF-8 errors" {
    const cases = [_]struct {
        input: []const u8,
        expected_error: anyerror,
    }{
        .{
            .input = &.{ '"', 0x80, '\\', 'q', '"' },
            .expected_error = error.InvalidEscape,
        },
        .{
            .input = &.{ '"', '\\', 'q', 0x80, '"' },
            .expected_error = error.InvalidEscape,
        },
        .{
            .input = &.{ '"', 0x80, 0x1f, '"' },
            .expected_error = error.InvalidEscape,
        },
        .{
            .input = &.{ '"', 0x80 },
            .expected_error = error.UnterminatedString,
        },
    };

    for (cases) |case| {
        try expectOnDemandErrorAfterEvents(
            case.input,
            &.{},
            case.expected_error,
        );
    }
}

test "on-demand EventReader preserves valid events before string errors" {
    const input = "{\"ok\":\"value\",\"bad\":\"\\q\"}";
    var parser = try lib.ondemand.Parser.init(testing.allocator, input.len);
    defer parser.deinit();

    var document = try lib.formats.json.initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();

    try expectOnDemandEvent(.object_start, (try reader.next()).?);
    try expectOnDemandEvent(.{ .key = "ok" }, (try reader.next()).?);
    try expectOnDemandRawStringEvent(input[7..12], (try reader.next()).?);
    try expectOnDemandEvent(.{ .key = "bad" }, (try reader.next()).?);
    try testing.expectError(error.InvalidEscape, reader.next());
}

fn appendBoundaryTestBytes(
    buffer: []u8,
    length: *usize,
    bytes: []const u8,
) void {
    std.debug.assert(length.* <= buffer.len);
    std.debug.assert(bytes.len <= buffer.len - length.*);
    @memcpy(buffer[length.*..][0..bytes.len], bytes);
    length.* += bytes.len;
}

fn appendBoundaryTestWhitespace(
    buffer: []u8,
    length: *usize,
    count: usize,
) void {
    const whitespace = " \t\n\r";
    std.debug.assert(length.* <= buffer.len);
    std.debug.assert(count <= buffer.len - length.*);
    for (buffer[length.*..][0..count], 0..) |*byte, index| {
        byte.* = whitespace[index % whitespace.len];
    }
    length.* += count;
}

fn expectOnDemandEvents(
    input: []const u8,
    expected_events: []const lib.ondemand.Event,
) !void {
    var parser = try lib.ondemand.Parser.init(testing.allocator, input.len);
    defer parser.deinit();

    var document = try lib.formats.json.initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();

    for (expected_events) |expected| {
        const actual = (try reader.next()) orelse return error.TestUnexpectedResult;
        try expectOnDemandEvent(expected, actual);
    }
    try testing.expect((try reader.next()) == null);
}

test "on-demand EventReader preserves events across long whitespace boundaries" {
    const widths = [_]usize{ 16, 32, 64, 128, 256, 512 };
    const expected_events = [_]lib.ondemand.Event{
        .object_start,
        .{ .key = "outer" },
        .array_start,
        .{ .number = "0" },
        .{ .number = "1" },
        .array_end,
        .object_end,
    };

    for (widths) |width| {
        const gap_lengths = [_]usize{ width - 1, width, width + 1 };
        for (gap_lengths) |gap_length| {
            var input_buffer: [2600]u8 = undefined;
            var input_length: usize = 0;
            appendBoundaryTestWhitespace(&input_buffer, &input_length, gap_length);
            appendBoundaryTestBytes(&input_buffer, &input_length, "{\"outer\"");
            appendBoundaryTestWhitespace(&input_buffer, &input_length, gap_length);
            appendBoundaryTestBytes(&input_buffer, &input_length, ":[0");
            appendBoundaryTestWhitespace(&input_buffer, &input_length, gap_length);
            appendBoundaryTestBytes(&input_buffer, &input_length, ",1");
            appendBoundaryTestWhitespace(&input_buffer, &input_length, gap_length);
            appendBoundaryTestBytes(&input_buffer, &input_length, "]");
            appendBoundaryTestWhitespace(&input_buffer, &input_length, gap_length);
            appendBoundaryTestBytes(&input_buffer, &input_length, "}");

            try expectOnDemandEvents(input_buffer[0..input_length], &expected_events);
        }
    }
}

test "on-demand EventReader rejects non-whitespace at block boundaries" {
    const widths = [_]usize{ 16, 32, 64, 128, 256, 512 };
    const positions = [_]struct {
        prefix: []const u8,
        suffix: []const u8,
        expected_events: []const lib.ondemand.Event,
    }{
        .{
            .prefix = "",
            .suffix = " {}",
            .expected_events = &.{},
        },
        .{
            .prefix = "{\"outer\"",
            .suffix = " :0}",
            .expected_events = &.{
                .object_start,
                .{ .key = "outer" },
            },
        },
        .{
            .prefix = "[0",
            .suffix = " ,1]",
            .expected_events = &.{
                .array_start,
                .{ .number = "0" },
            },
        },
        .{
            .prefix = "{\"outer\":0",
            .suffix = " }",
            .expected_events = &.{
                .object_start,
                .{ .key = "outer" },
                .{ .number = "0" },
            },
        },
        .{
            .prefix = "[0",
            .suffix = " ]",
            .expected_events = &.{
                .array_start,
                .{ .number = "0" },
            },
        },
    };
    const invalid_bytes = [_]struct {
        byte: u8,
        expected_error: anyerror,
    }{
        .{ .byte = '@', .expected_error = error.UnexpectedToken },
        .{ .byte = '+', .expected_error = error.InvalidNumber },
    };

    for (widths) |width| {
        for (positions) |position| {
            for (invalid_bytes) |invalid| {
                var input_buffer: [540]u8 = undefined;
                var input_length: usize = 0;
                appendBoundaryTestBytes(&input_buffer, &input_length, position.prefix);
                appendBoundaryTestWhitespace(&input_buffer, &input_length, width);
                input_buffer[input_length] = invalid.byte;
                input_length += 1;
                appendBoundaryTestBytes(&input_buffer, &input_length, position.suffix);

                try expectOnDemandErrorAfterEvents(
                    input_buffer[0..input_length],
                    position.expected_events,
                    invalid.expected_error,
                );
            }
        }
    }
}

test "on-demand EventReader accepts exact JSON whitespace around block boundaries" {
    const widths = [_]usize{ 1, 3, 7, 16, 31, 32, 63, 64, 65, 128, 256, 512 };
    const whitespace_bytes = [_]u8{ 0x09, 0x0a, 0x0d, 0x20 };
    const expected_events = [_]lib.ondemand.Event{
        .object_start,
        .{ .key = "x" },
        .{ .number = "0" },
        .object_end,
    };

    for (widths) |width| {
        const candidate_offsets = [_]usize{ width - 1, width, width + 1 };
        for (candidate_offsets) |candidate_offset| {
            for (whitespace_bytes) |whitespace_byte| {
                var input_buffer: [528]u8 = undefined;
                var input_length: usize = 0;
                appendBoundaryTestBytes(&input_buffer, &input_length, "{\"x\"");
                appendBoundaryTestWhitespace(
                    &input_buffer,
                    &input_length,
                    candidate_offset,
                );
                input_buffer[input_length] = whitespace_byte;
                input_length += 1;
                appendBoundaryTestBytes(&input_buffer, &input_length, ":0}");

                try expectOnDemandEvents(input_buffer[0..input_length], &expected_events);
            }
        }
    }
}

test "on-demand EventReader rejects nearby bytes around whitespace block boundaries" {
    const widths = [_]usize{ 1, 3, 7, 16, 31, 32, 63, 64, 65, 128, 256, 512 };
    const non_whitespace_bytes = [_]u8{ 0x0b, 0x0c, 0x1f, 0x21, 0x80 };
    const expected_events = [_]lib.ondemand.Event{
        .object_start,
        .{ .key = "x" },
    };

    for (widths) |width| {
        const candidate_offsets = [_]usize{ width - 1, width, width + 1 };
        for (candidate_offsets) |candidate_offset| {
            for (non_whitespace_bytes) |non_whitespace_byte| {
                var input_buffer: [528]u8 = undefined;
                var input_length: usize = 0;
                appendBoundaryTestBytes(&input_buffer, &input_length, "{\"x\"");
                appendBoundaryTestWhitespace(
                    &input_buffer,
                    &input_length,
                    candidate_offset,
                );
                input_buffer[input_length] = non_whitespace_byte;
                input_length += 1;
                appendBoundaryTestBytes(&input_buffer, &input_length, ":0}");

                try expectOnDemandErrorAfterEvents(
                    input_buffer[0..input_length],
                    &expected_events,
                    error.UnexpectedToken,
                );
            }
        }
    }
}

fn expectJsonStreamParity(
    input: []const u8,
    actual: *const lib.StructuralIndex,
) !void {
    var expected = try lib.formats.json.indexJson(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try checking.expectIndexParity(&expected, actual, true);
}

fn expectJsonStreamWithCuts(
    input: []const u8,
    cuts: []const usize,
    empty_feeds: bool,
) !void {
    var stream = try lib.stream.StreamIndexer.init(
        testing.allocator,
        vector_len,
        lib.stream.Options{ .dialect = .json, .mode = .document },
    );
    defer stream.deinit();

    if (empty_feeds) try stream.feed("");
    try checking.feedPartitions(input, cuts, &stream, empty_feeds);
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try expectJsonStreamParity(input, &actual);
}

fn expectJsonStreamByteFeeds(input: []const u8) !void {
    var stream = try lib.stream.StreamIndexer.init(
        testing.allocator,
        1,
        lib.stream.Options{ .dialect = .json, .mode = .document },
    );
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
    const cut_center: usize = @max(2, @min(vector_len, input.len -| 2));
    const cuts = [_]usize{
        cut_center - 1,
        cut_center,
        cut_center + 1,
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
        var stream = try lib.stream.StreamIndexer.init(
            testing.allocator,
            2,
            lib.stream.Options{ .dialect = .json, .mode = .document },
        );
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
fn expectJsonlStreamParity(
    input: []const u8,
    cuts: []const usize,
) !void {
    var expected = try lib.formats.jsonl.indexJsonl(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var stream = try lib.formats.jsonl.initStreamIndexer(
        testing.allocator,
        vector_len,
    );
    defer stream.deinit();

    try checking.feedPartitions(input, cuts, &stream, true);
    try stream.finish();
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try checking.expectIndexParity(&expected, &actual, true);
}

fn expectMarkdownStreamParity(
    input: []const u8,
    cuts: []const usize,
) !void {
    var expected = try lib.formats.markdown.indexMarkdown(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var stream = try lib.formats.markdown.MarkdownStreamIndexer.init(
        testing.allocator,
        vector_len,
    );
    defer stream.deinit();

    try checking.feedPartitions(input, cuts, &stream, true);
    try stream.finish();
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try checking.expectTokenParity(&expected, &actual, true);
}

fn expectXmlStreamParity(
    input: []const u8,
    cuts: []const usize,
) !void {
    var expected = try lib.formats.xml.indexXml(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var stream = try lib.formats.xml.XmlStreamIndexer.init(
        testing.allocator,
        vector_len,
    );
    defer stream.deinit();

    try checking.feedPartitions(input, cuts, &stream, true);
    try stream.finish();
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try checking.expectTokenParity(&expected, &actual, true);
}

test "public JSONL stream preserves output and sentinels across chunk boundaries" {
    const input = "{\"a\":1}\n{\"b\":\"line" ++
        "\n" ++
        "value\"}\r\n[true,false]\n";
    const final_cut = input.len -| 1;
    const cuts = [_]usize{
        0,
        @min(1, final_cut),
        @min(vector_len - 1, final_cut),
        @min(vector_len, final_cut),
        @min(vector_len + 1, final_cut),
        final_cut,
    };

    try expectJsonlStreamParity(input, &cuts);
    try expectJsonlStreamParity("", &.{});
}

test "public Markdown stream preserves output, sentinels, and token kinds" {
    const input =
        "# heading\r\n" ++
        "- item [link](target)\n" ++
        "> quote\n" ++
        "```zig\n# hidden\n```\n" ++
        "`inline` ***\n";
    const crlf_cut = std.mem.indexOf(u8, input, "\r\n").? + 1;
    const final_cut = input.len -| 1;
    const vector_cut = @min(vector_len, final_cut);
    const cuts: []const usize = if (vector_cut > crlf_cut and vector_cut < final_cut)
        &.{ 0, 1, crlf_cut, vector_cut, final_cut }
    else
        &.{ 0, 1, crlf_cut, final_cut };

    try expectMarkdownStreamParity(input, cuts);
    try expectMarkdownStreamParity("", &.{});
}

test "public XML stream preserves output, sentinels, and token kinds" {
    const input =
        "<?xml version=\"1.0\"?><root a=\"1\"><item/>" ++
        "<!-- comment --><![CDATA[text]]></root>";
    const processing_instruction_cut = std.mem.indexOf(u8, input, "?>").? + 1;
    const cdata_cut = std.mem.indexOf(u8, input, "<![CDATA[").? + 1;
    const final_cut = input.len -| 1;
    const vector_cut = @min(vector_len, final_cut);
    const cuts: []const usize = if (vector_cut > 1 and vector_cut < processing_instruction_cut)
        &.{ 0, 1, vector_cut, processing_instruction_cut, cdata_cut, final_cut }
    else if (vector_cut > processing_instruction_cut and vector_cut < cdata_cut)
        &.{ 0, 1, processing_instruction_cut, vector_cut, cdata_cut, final_cut }
    else if (vector_cut > cdata_cut and vector_cut < final_cut)
        &.{ 0, 1, processing_instruction_cut, cdata_cut, vector_cut, final_cut }
    else
        &.{ 0, 1, processing_instruction_cut, cdata_cut, final_cut };

    try expectXmlStreamParity(input, cuts);
    try expectXmlStreamParity("", &.{});
}

fn checkPublicJsonAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "{\"name\":\"Ada\",\"items\":[1,true,null]}";
    var index = try lib.formats.json.indexJson(allocator, input);
    defer index.deinit(allocator);

    var document = try lib.formats.json.buildJsonTape(allocator, input);
    defer document.deinit(allocator);
}

fn checkPublicJsonStreamAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "{\"a\":1}";
    var stream = try lib.stream.StreamIndexer.init(
        allocator,
        1,
        .{ .dialect = .json, .mode = .document },
    );
    defer stream.deinit();
    try stream.feed(input);
    try stream.finish();
    var index = stream.take();
    defer index.deinit(allocator);
}

fn checkPublicJsonlAllocationFailure(allocator: std.mem.Allocator) !void {
    const input =
        "{\"a\":[1,{\"b\":[]}]}\n" ++
        "[[2],{\"c\":3}]\n" ++
        "{\"d\":4}";
    var document = try lib.formats.jsonl.buildJsonlTape(allocator, input);
    defer document.deinit(allocator);
}

test "public JSONL tape construction handles partial allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkPublicJsonlAllocationFailure,
        .{},
    );
}

test "public JSON index, tape, and stream operations propagate allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkPublicJsonAllocationFailure,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkPublicJsonStreamAllocationFailure,
        .{},
    );
}
