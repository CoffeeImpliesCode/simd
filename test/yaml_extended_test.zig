const std = @import("std");
const basic = @import("../src/formats/yaml.zig");
const yaml = @import("../src/formats/yaml_extended.zig");

const testing = std.testing;

const ExpectedEvent = struct {
    kind: basic.YamlTokenKind,
    offset: u32,
};

const ExpectedScalar = struct {
    event_index: usize,
    raw: []const u8,
    value: []const u8,
    style: yaml.ScalarStyle,
    ownership: yaml.ValueOwnership,
};

fn expectEvents(document: *const yaml.Document, expected: []const ExpectedEvent) !void {
    try testing.expectEqual(expected.len, document.tape.len);
    for (expected, document.tape) |expected_event, word| {
        try testing.expectEqual(expected_event.kind, word.tapeKind());
        try testing.expectEqual(expected_event.offset, word.offset);
    }
}

fn expectScalars(
    document: *const yaml.Document,
    input: []const u8,
    expected: []const ExpectedScalar,
) !void {
    for (expected) |expected_scalar| {
        const raw = try document.rawSpan(input, expected_scalar.event_index);
        try testing.expectEqualStrings(expected_scalar.raw, raw);

        const value = try document.value(input, expected_scalar.event_index);
        try testing.expectEqual(expected_scalar.ownership, value.ownership());
        try testing.expectEqualStrings(expected_scalar.value, value.bytes());

        const info = try document.scalarInfo(expected_scalar.event_index);
        try testing.expectEqual(expected_scalar.style, info.style);
    }
}

fn expectScalarValue(input: []const u8, expected: []const u8) !void {
    var document = try yaml.buildYamlTape(testing.allocator, input, yaml.default_limits);
    defer document.deinit(testing.allocator);

    for (document.tape, 0..) |word, event_index| {
        if (word.tapeKind() == .scalar) {
            const value = try document.value(input, event_index);
            try testing.expectEqualStrings(expected, value.bytes());
            return;
        }
    }
    return error.ExpectedScalar;
}

fn expectResourceOutcome(
    input: []const u8,
    limits: yaml.Limits,
    expected_error: yaml.Error,
) !void {
    try testing.expectError(
        expected_error,
        yaml.buildYamlTape(testing.allocator, input, limits),
    );
    const diagnostic = (try yaml.validateYaml(testing.allocator, input, limits)).?;
    try testing.expectEqual(expected_error, diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.resource, diagnostic.kind);
}

test "YAML profiles are explicit and basic behavior remains isolated" {
    try testing.expectEqual(basic.Profile.basic, basic.profile);
    try testing.expectEqual(basic.Profile.extended, yaml.profile);
    try testing.expectEqualStrings("yaml-basic-1.2.2", basic.profile_label);
    try testing.expectEqualStrings("yaml-extended-e2b-1.2.2", yaml.profile_label);
    try testing.expectEqualStrings(basic.profile_label, basic.profileLabel(.basic));
    try testing.expectEqualStrings(yaml.profile_label, basic.profileLabel(.extended));
    try testing.expectEqual(@as(usize, 8), @sizeOf(basic.YamlTapeWord));

    const basic_input = "key: value\n";
    var basic_document = try basic.buildYamlTape(testing.allocator, basic_input);
    defer basic_document.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), basic_document.tape.len);
    try testing.expectEqual(basic.YamlTokenKind.mapping_start, basic_document.tape[0].tapeKind());
    try testing.expectEqual(basic.YamlTokenKind.key, basic_document.tape[1].tapeKind());
    try testing.expectEqual(basic.YamlTokenKind.scalar, basic_document.tape[2].tapeKind());
    try testing.expectEqual(basic.YamlTokenKind.mapping_end, basic_document.tape[3].tapeKind());
    try testing.expectEqual(@as(u32, 0), basic_document.tape[1].offset);
    try testing.expectEqual(@as(usize, 3), basic_document.tape[1].sourceLength());
    try testing.expectEqual(@as(u32, 5), basic_document.tape[2].offset);
    try testing.expectEqual(@as(usize, 5), basic_document.tape[2].sourceLength());

    const extensions = [_][]const u8{
        "value: |\n  literal\n",
        "value: >\n  folded\n",
        "value: \"first\n  second\"\n",
        "- key: value\n",
    };
    for (extensions) |input| {
        try testing.expectError(
            error.Unsupported,
            basic.buildYamlTape(testing.allocator, input),
        );
    }
}

test "extended YAML retains basic event and raw scalar behavior" {
    const input = "key: value\nitems:\n  - one\n  - 'two'\n";
    var expected = try basic.buildYamlTape(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    var actual = try yaml.buildYamlTape(testing.allocator, input, yaml.default_limits);
    defer actual.deinit(testing.allocator);

    try testing.expectEqual(expected.tape.len, actual.tape.len);
    for (expected.tape, actual.tape) |expected_word, actual_word| {
        try testing.expectEqual(expected_word, actual_word);
    }

    try expectScalars(&actual, input, &.{
        .{
            .event_index = 1,
            .raw = "key",
            .value = "key",
            .style = .plain,
            .ownership = .source_borrowed,
        },
        .{
            .event_index = 2,
            .raw = "value",
            .value = "value",
            .style = .plain,
            .ownership = .source_borrowed,
        },
        .{
            .event_index = 3,
            .raw = "items",
            .value = "items",
            .style = .plain,
            .ownership = .source_borrowed,
        },
        .{
            .event_index = 5,
            .raw = "one",
            .value = "one",
            .style = .plain,
            .ownership = .source_borrowed,
        },
        .{
            .event_index = 6,
            .raw = "'two'",
            .value = "two",
            .style = .single_quoted,
            .ownership = .document_owned,
        },
    });
}

test "literal blocks implement clip strip keep and exact raw spans" {
    const cases = [_]struct {
        input: []const u8,
        raw: []const u8,
        value: []const u8,
        chomping: yaml.Chomping,
    }{
        .{
            .input = "value: |\n  one\n  two\n",
            .raw = "|\n  one\n  two\n",
            .value = "one\ntwo\n",
            .chomping = .clip,
        },
        .{
            .input = "value: |-\n  one\n\n",
            .raw = "|-\n  one\n\n",
            .value = "one",
            .chomping = .strip,
        },
        .{
            .input = "value: |+\n  one\n\n",
            .raw = "|+\n  one\n\n",
            .value = "one\n\n",
            .chomping = .keep,
        },
    };

    for (cases) |case| {
        var document = try yaml.buildYamlTape(testing.allocator, case.input, yaml.default_limits);
        defer document.deinit(testing.allocator);
        try expectEvents(&document, &.{
            .{ .kind = .mapping_start, .offset = 0 },
            .{ .kind = .key, .offset = 0 },
            .{ .kind = .scalar, .offset = 7 },
            .{ .kind = .mapping_end, .offset = @intCast(case.input.len - 1) },
        });
        try expectScalars(&document, case.input, &.{.{
            .event_index = 2,
            .raw = case.raw,
            .value = case.value,
            .style = .literal,
            .ownership = .document_owned,
        }});
        const info = try document.scalarInfo(2);
        try testing.expectEqual(case.chomping, info.chomping);
    }
}

test "literal blocks support empty nested tabbed and explicit indentation" {
    const input =
        "root:\n" ++
        "  empty: |\n" ++
        "  explicit: |2-\n" ++
        "    text\n" ++
        "  tabbed: |\n" ++
        "    \ttext\n";
    var document = try yaml.buildYamlTape(testing.allocator, input, yaml.default_limits);
    defer document.deinit(testing.allocator);

    try expectScalars(&document, input, &.{
        .{
            .event_index = 1,
            .raw = "root",
            .value = "root",
            .style = .plain,
            .ownership = .source_borrowed,
        },
        .{
            .event_index = 3,
            .raw = "empty",
            .value = "empty",
            .style = .plain,
            .ownership = .source_borrowed,
        },
        .{
            .event_index = 4,
            .raw = "|",
            .value = "",
            .style = .literal,
            .ownership = .document_owned,
        },
        .{
            .event_index = 5,
            .raw = "explicit",
            .value = "explicit",
            .style = .plain,
            .ownership = .source_borrowed,
        },
        .{
            .event_index = 6,
            .raw = "|2-\n    text\n",
            .value = "text",
            .style = .literal,
            .ownership = .document_owned,
        },
        .{
            .event_index = 7,
            .raw = "tabbed",
            .value = "tabbed",
            .style = .plain,
            .ownership = .source_borrowed,
        },
        .{
            .event_index = 8,
            .raw = "|\n    \ttext\n",
            .value = "\ttext\n",
            .style = .literal,
            .ownership = .document_owned,
        },
    });

    const empty_info = try document.scalarInfo(4);
    try testing.expectEqual(yaml.ScalarIndentation.automatic, empty_info.indentation);
    try testing.expectEqual(@as(u32, 0), empty_info.indentation_width);

    const explicit_info = try document.scalarInfo(6);
    try testing.expectEqual(yaml.ScalarIndentation.explicit, explicit_info.indentation);
    try testing.expectEqual(@as(u8, 2), explicit_info.indentation_indicator);
    try testing.expectEqual(@as(u32, 4), explicit_info.indentation_width);

    const tabbed_info = try document.scalarInfo(8);
    try testing.expectEqual(yaml.ScalarIndentation.automatic, tabbed_info.indentation);
    try testing.expectEqual(@as(u32, 4), tabbed_info.indentation_width);
}

test "literal block indentation indicators accept one through nine in either order" {
    var digit: u8 = '1';
    while (digit <= '9') : (digit += 1) {
        var input_buffer: [64]u8 = undefined;
        const width: usize = digit - '0';
        var offset: usize = 0;
        const prefix = "value: |";
        @memcpy(input_buffer[offset..][0..prefix.len], prefix);
        offset += prefix.len;
        input_buffer[offset] = digit;
        offset += 1;
        input_buffer[offset] = '-';
        offset += 1;
        input_buffer[offset] = '\n';
        offset += 1;
        @memset(input_buffer[offset..][0..width], ' ');
        offset += width;
        input_buffer[offset] = 'x';
        offset += 1;
        input_buffer[offset] = '\n';
        offset += 1;

        const input = input_buffer[0..offset];
        var document = try yaml.buildYamlTape(testing.allocator, input, yaml.default_limits);
        defer document.deinit(testing.allocator);
        try testing.expectEqualStrings("x", (try document.value(input, 2)).bytes());
        const info = try document.scalarInfo(2);
        try testing.expectEqual(yaml.ScalarIndentation.explicit, info.indentation);
        try testing.expectEqual(@as(u8, @intCast(width)), info.indentation_indicator);
        try testing.expectEqual(@as(u32, @intCast(width)), info.indentation_width);
    }

    try expectScalarValue("value: |-2\n  x\n", "x");
}

test "literal block diagnostics identify malformed headers and bad content indentation" {
    const malformed = [_][]const u8{
        "value: |0\n  text\n",
        "value: |22\n  text\n",
        "value: |+-\n  text\n",
        "value: |x\n  text\n",
    };
    for (malformed) |input| {
        const diagnostic = (try yaml.validateYaml(
            testing.allocator,
            input,
            yaml.default_limits,
        )).?;
        try testing.expectEqual(error.Invalid, diagnostic.err);
        try testing.expectEqual(yaml.DiagnosticKind.syntax, diagnostic.kind);
        try testing.expectEqual(@as(u32, 1), diagnostic.line);
        try testing.expect(diagnostic.byte_offset >= 7);
    }

    const bad_indent = "root:\n  value: |2\n   bad\n";
    const diagnostic = (try yaml.validateYaml(
        testing.allocator,
        bad_indent,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(error.Invalid, diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.syntax, diagnostic.kind);
    try testing.expectEqual(@as(usize, 21), diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 3), diagnostic.line);
    try testing.expectEqual(@as(u32, 4), diagnostic.column);
}

test "folded blocks implement ordinary blank and more-indented folding" {
    try expectScalarValue("value: >\n  folded\n  line\n", "folded line\n");
    try expectScalarValue("value: >\n  first\n\n  second\n", "first\nsecond\n");
    try expectScalarValue(
        "value: >\n  first\n    code\n  second\n",
        "first\n  code\nsecond\n",
    );
    try expectScalarValue("value: >-2\n  first\n  second\n", "first second");
    try expectScalarValue("value: >+\n  first\n\n", "first\n\n");
    try expectScalarValue("value: >\r\n  first\r\n  second\r\n", "first second\n");
}

test "multiline quoted scalars fold lines and decode YAML escapes" {
    const single = "value: 'single\n  quoted ''value''' # comment\n";
    var single_document = try yaml.buildYamlTape(
        testing.allocator,
        single,
        yaml.default_limits,
    );
    defer single_document.deinit(testing.allocator);
    try expectScalars(&single_document, single, &.{.{
        .event_index = 2,
        .raw = "'single\n  quoted ''value'''",
        .value = "single quoted 'value'",
        .style = .single_quoted,
        .ownership = .document_owned,
    }});

    const double = "value: \"double\n  quoted\\n\\u263A\" # comment\n";
    var double_document = try yaml.buildYamlTape(
        testing.allocator,
        double,
        yaml.default_limits,
    );
    defer double_document.deinit(testing.allocator);
    try expectScalars(&double_document, double, &.{.{
        .event_index = 2,
        .raw = "\"double\n  quoted\\n\\u263A\"",
        .value = "double quoted\n\xe2\x98\xba",
        .style = .double_quoted,
        .ownership = .document_owned,
    }});

    try expectScalarValue("value: \"escaped \\\n  line\"\n", "escaped line");
}

test "double quoted scalars implement the YAML escape table" {
    const input =
        "value: \"" ++
        "\\0\\a\\b\\t\\n\\v\\f\\r\\e\\ \\\"/\\\\" ++
        "\\N\\_\\L\\P\\x41\\u263A\\U0001F600\"\n";
    const expected =
        "\x00\x07\x08\x09\x0a\x0b\x0c\x0d\x1b \"/\\" ++
        "\xc2\x85\xc2\xa0\xe2\x80\xa8\xe2\x80\xa9" ++
        "A\xe2\x98\xba\xf0\x9f\x98\x80";
    try expectScalarValue(input, expected);
}

test "quoted scalar diagnostics reject invalid escapes and unterminated multiline values" {
    const invalid_escape = "value: \"bad\\q\"\n";
    const invalid_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        invalid_escape,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(error.Invalid, invalid_diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.syntax, invalid_diagnostic.kind);
    try testing.expectEqual(@as(usize, 11), invalid_diagnostic.byte_offset);

    const unterminated = "value: \"first\n  second\n";
    const unterminated_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        unterminated,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(error.Invalid, unterminated_diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.syntax, unterminated_diagnostic.kind);
    try testing.expectEqual(@as(usize, 7), unterminated_diagnostic.byte_offset);
}

test "compact sequence mapping emits expanded-form events with exact offsets" {
    const input = "- key: value\n";
    var document = try yaml.buildYamlTape(testing.allocator, input, yaml.default_limits);
    defer document.deinit(testing.allocator);

    try expectEvents(&document, &.{
        .{ .kind = .sequence_start, .offset = 0 },
        .{ .kind = .mapping_start, .offset = 2 },
        .{ .kind = .key, .offset = 2 },
        .{ .kind = .scalar, .offset = 7 },
        .{ .kind = .mapping_end, .offset = 12 },
        .{ .kind = .sequence_end, .offset = 12 },
    });
    try expectScalars(&document, input, &.{
        .{
            .event_index = 2,
            .raw = "key",
            .value = "key",
            .style = .plain,
            .ownership = .source_borrowed,
        },
        .{
            .event_index = 3,
            .raw = "value",
            .value = "value",
            .style = .plain,
            .ownership = .source_borrowed,
        },
    });

    const expanded = "-\n  key: value\n";
    var expanded_document = try yaml.buildYamlTape(
        testing.allocator,
        expanded,
        yaml.default_limits,
    );
    defer expanded_document.deinit(testing.allocator);
    try testing.expectEqual(document.tape.len, expanded_document.tape.len);
    for (document.tape, expanded_document.tape) |compact_word, expanded_word| {
        try testing.expectEqual(compact_word.tapeKind(), expanded_word.tapeKind());
    }
}

test "compact sequence mappings support following pairs empty and nested values" {
    const input =
        "- key:\n" ++
        "  empty:\n" ++
        "  nested:\n" ++
        "    child: yes\n" ++
        "  items:\n" ++
        "    - one\n" ++
        "    - two\n" ++
        "  tail: done\n";
    var document = try yaml.buildYamlTape(testing.allocator, input, yaml.default_limits);
    defer document.deinit(testing.allocator);

    const expected_kinds = [_]basic.YamlTokenKind{
        .sequence_start,
        .mapping_start,
        .key,
        .scalar,
        .key,
        .scalar,
        .key,
        .mapping_start,
        .key,
        .scalar,
        .mapping_end,
        .key,
        .sequence_start,
        .scalar,
        .scalar,
        .sequence_end,
        .key,
        .scalar,
        .mapping_end,
        .sequence_end,
    };
    try testing.expectEqual(expected_kinds.len, document.tape.len);
    for (expected_kinds, document.tape) |expected_kind, word| {
        try testing.expectEqual(expected_kind, word.tapeKind());
    }
    try testing.expectEqualStrings("", (try document.value(input, 3)).bytes());
    try testing.expectEqualStrings("", (try document.value(input, 5)).bytes());
    try testing.expectEqualStrings("yes", (try document.value(input, 9)).bytes());
    try testing.expectEqualStrings("one", (try document.value(input, 13)).bytes());
    try testing.expectEqualStrings("two", (try document.value(input, 14)).bytes());
    try testing.expectEqualStrings("done", (try document.value(input, 17)).bytes());
}

test "compact mappings support quoted pairs comments block scalars and sibling items" {
    const input =
        "- 'key': \"value\" # comment\n" ++
        "  text: |\n" ++
        "    hello\n" ++
        "- next: item\n";
    var document = try yaml.buildYamlTape(testing.allocator, input, yaml.default_limits);
    defer document.deinit(testing.allocator);

    try testing.expectEqualStrings("key", (try document.value(input, 2)).bytes());
    try testing.expectEqualStrings("value", (try document.value(input, 3)).bytes());
    try testing.expectEqualStrings("text", (try document.value(input, 4)).bytes());
    try testing.expectEqualStrings("hello\n", (try document.value(input, 5)).bytes());
    try testing.expectEqualStrings("next", (try document.value(input, 8)).bytes());
    try testing.expectEqualStrings("item", (try document.value(input, 9)).bytes());

    try testing.expectEqual(yaml.ScalarStyle.single_quoted, (try document.scalarInfo(2)).style);
    try testing.expectEqual(yaml.ScalarStyle.double_quoted, (try document.scalarInfo(3)).style);
    try testing.expectEqual(yaml.ScalarStyle.literal, (try document.scalarInfo(5)).style);

    const malformed = "- : value\n";
    const diagnostic = (try yaml.validateYaml(
        testing.allocator,
        malformed,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(error.Invalid, diagnostic.err);
    try testing.expectEqual(@as(usize, 2), diagnostic.byte_offset);
}

test "extended profile keeps deferred YAML features unsupported" {
    const unsupported = [_][]const u8{
        "%YAML 1.2\nvalue: ok\n",
        "---\nvalue: ok\n---\nvalue: next\n",
        "value: !tag text\n",
        "value: &anchor text\n",
        "value: *anchor\n",
        "? [complex, key]\n: value\n",
    };
    for (unsupported) |input| {
        const diagnostic = (try yaml.validateYaml(
            testing.allocator,
            input,
            yaml.default_limits,
        )).?;
        try testing.expectEqual(error.Unsupported, diagnostic.err);
        try testing.expectEqual(yaml.DiagnosticKind.unsupported, diagnostic.kind);
        try testing.expectError(
            error.Unsupported,
            yaml.buildYamlTape(testing.allocator, input, yaml.default_limits),
        );
    }
}

test "basic validation enforces tape word limits" {
    const input = "k: v\n";
    try expectResourceOutcome(
        input,
        .{ .tape_words_max = 1 },
        error.TapeWordsExceeded,
    );

    var document = try yaml.buildYamlTape(
        testing.allocator,
        input,
        .{ .tape_words_max = 4 },
    );
    defer document.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), document.tape.len);
    try testing.expectEqualStrings("v", (try document.value(input, 2)).bytes());
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        input,
        .{ .tape_words_max = 4 },
    )) == null);
}

test "basic validation enforces cooked byte limits" {
    const input = "k: \"long\"\n";
    try expectResourceOutcome(
        input,
        .{ .cooked_bytes_max = 3 },
        error.CookedBytesExceeded,
    );

    var document = try yaml.buildYamlTape(
        testing.allocator,
        input,
        .{ .cooked_bytes_max = 4 },
    );
    defer document.deinit(testing.allocator);
    const value = try document.value(input, 2);
    try testing.expectEqualStrings("long", value.bytes());
    try testing.expectEqual(yaml.ValueOwnership.document_owned, value.ownership());
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        input,
        .{ .cooked_bytes_max = 4 },
    )) == null);
}

test "basic validation enforces scalar source limits" {
    const input = "k: long\n";
    try expectResourceOutcome(
        input,
        .{ .scalar_source_bytes_max = 3 },
        error.ScalarSourceExceeded,
    );

    var document = try yaml.buildYamlTape(
        testing.allocator,
        input,
        .{ .scalar_source_bytes_max = 4 },
    );
    defer document.deinit(testing.allocator);
    const value = try document.value(input, 2);
    try testing.expectEqualStrings("long", value.bytes());
    try testing.expectEqual(yaml.ValueOwnership.source_borrowed, value.ownership());
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        input,
        .{ .scalar_source_bytes_max = 4 },
    )) == null);
}

test "basic documents enforce configured flow depth" {
    try expectResourceOutcome(
        "[[[x]]]\n",
        .{ .depth_max = 2 },
        error.DepthExceeded,
    );

    const input = "[[x]]\n";
    var document = try yaml.buildYamlTape(
        testing.allocator,
        input,
        .{ .depth_max = 2 },
    );
    defer document.deinit(testing.allocator);
    try testing.expectEqualStrings("x", (try document.value(input, 2)).bytes());
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        input,
        .{ .depth_max = 2 },
    )) == null);
}

test "compact sequence mappings consume configured depth" {
    const input = "- k: v\n";
    try expectResourceOutcome(
        input,
        .{ .depth_max = 1 },
        error.DepthExceeded,
    );

    var document = try yaml.buildYamlTape(
        testing.allocator,
        input,
        .{ .depth_max = 2 },
    );
    defer document.deinit(testing.allocator);
    try testing.expectEqualStrings("k", (try document.value(input, 2)).bytes());
    try testing.expectEqualStrings("v", (try document.value(input, 3)).bytes());
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        input,
        .{ .depth_max = 2 },
    )) == null);
}

test "borrowed plain keys and values enforce scalar source limits" {
    try expectResourceOutcome(
        "- long: v\n",
        .{ .scalar_source_bytes_max = 3 },
        error.ScalarSourceExceeded,
    );
    try expectResourceOutcome(
        "- k: long\n",
        .{ .scalar_source_bytes_max = 3 },
        error.ScalarSourceExceeded,
    );

    const input = "- key: val\n";
    var document = try yaml.buildYamlTape(
        testing.allocator,
        input,
        .{ .scalar_source_bytes_max = 3 },
    );
    defer document.deinit(testing.allocator);
    const key = try document.value(input, 2);
    const value = try document.value(input, 3);
    try testing.expectEqualStrings("key", key.bytes());
    try testing.expectEqualStrings("val", value.bytes());
    try testing.expectEqual(yaml.ValueOwnership.source_borrowed, key.ownership());
    try testing.expectEqual(yaml.ValueOwnership.source_borrowed, value.ownership());
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        input,
        .{ .scalar_source_bytes_max = 3 },
    )) == null);
}

test "basic validation preserves source diagnostics" {
    const input = ": value\n";
    const expected = (try basic.validateYaml(testing.allocator, input)).?;
    const actual = (try yaml.validateYaml(
        testing.allocator,
        input,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(@as(yaml.Error, expected.err), actual.err);
    try testing.expectEqual(yaml.DiagnosticKind.syntax, actual.kind);
    try testing.expectEqual(expected.byte_offset, actual.byte_offset);
    try testing.expectEqual(expected.line, actual.line);
    try testing.expectEqual(expected.column, actual.column);
    try testing.expectEqualStrings(expected.snippet, actual.snippet);
    try testing.expectEqual(expected.snippet_start, actual.snippet_start);
}

test "root collections accept one document end marker" {
    const mapping_input = "k: |\n  a\n...\n";
    var mapping_document = try yaml.buildYamlTape(
        testing.allocator,
        mapping_input,
        yaml.default_limits,
    );
    defer mapping_document.deinit(testing.allocator);
    try testing.expectEqualStrings("a\n", (try mapping_document.value(mapping_input, 2)).bytes());
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        mapping_input,
        yaml.default_limits,
    )) == null);

    const sequence_input = "- |\n  a\n...\n";
    var sequence_document = try yaml.buildYamlTape(
        testing.allocator,
        sequence_input,
        yaml.default_limits,
    );
    defer sequence_document.deinit(testing.allocator);
    try testing.expectEqualStrings("a\n", (try sequence_document.value(sequence_input, 1)).bytes());
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        sequence_input,
        yaml.default_limits,
    )) == null);

    const multiple_documents = "k: v\n...\nk: next\n";
    const diagnostic = (try yaml.validateYaml(
        testing.allocator,
        multiple_documents,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(error.Unsupported, diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.unsupported, diagnostic.kind);
    try testing.expectError(
        error.Unsupported,
        yaml.buildYamlTape(testing.allocator, multiple_documents, yaml.default_limits),
    );
}

test "basic profile keeps source validation and extension opt-in" {
    const block = "k: |\n  a\n";
    try testing.expectError(error.Unsupported, basic.buildYamlTape(testing.allocator, block));
    const block_diagnostic = (try basic.validateYaml(testing.allocator, block)).?;
    try testing.expectEqual(error.Unsupported, block_diagnostic.err);
    try testing.expectEqual(basic.YamlDiagnosticKind.unsupported, block_diagnostic.kind);

    const control = "k: \xc2\x80\n";
    try testing.expectError(error.Invalid, basic.buildYamlTape(testing.allocator, control));
    const control_diagnostic = (try basic.validateYaml(testing.allocator, control)).?;
    try testing.expectEqual(error.Invalid, control_diagnostic.err);
    try testing.expectEqual(basic.YamlDiagnosticKind.syntax, control_diagnostic.kind);
    try testing.expectEqual(@as(usize, 3), control_diagnostic.byte_offset);

    const noncharacter = "k: \xef\xbf\xbe\n";
    try testing.expectError(error.Invalid, basic.buildYamlTape(testing.allocator, noncharacter));
    const noncharacter_diagnostic = (try basic.validateYaml(testing.allocator, noncharacter)).?;
    try testing.expectEqual(error.Invalid, noncharacter_diagnostic.err);
    try testing.expectEqual(basic.YamlDiagnosticKind.syntax, noncharacter_diagnostic.kind);
    try testing.expectEqual(@as(usize, 3), noncharacter_diagnostic.byte_offset);

    const nel = "k: \xc2\x85\n";
    var nel_document = try basic.buildYamlTape(testing.allocator, nel);
    defer nel_document.deinit(testing.allocator);
    try testing.expect((try basic.validateYaml(testing.allocator, nel)) == null);

    const cafe = "k: café\n";
    var cafe_document = try basic.buildYamlTape(testing.allocator, cafe);
    defer cafe_document.deinit(testing.allocator);
    try testing.expect((try basic.validateYaml(testing.allocator, cafe)) == null);
}

test "root block scalars select extended parser" {
    const input = "|\n  a\n";
    var document = try yaml.buildYamlTape(testing.allocator, input, yaml.default_limits);
    defer document.deinit(testing.allocator);
    try testing.expectEqualStrings("a\n", (try document.value(input, 0)).bytes());
    try testing.expectEqual(yaml.ScalarStyle.literal, (try document.scalarInfo(0)).style);
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        input,
        yaml.default_limits,
    )) == null);
    const bom_input = "\xef\xbb\xbf|\n  a\n";
    var bom_document = try yaml.buildYamlTape(testing.allocator, bom_input, yaml.default_limits);
    defer bom_document.deinit(testing.allocator);
    try testing.expectEqualStrings("a\n", (try bom_document.value(bom_input, 0)).bytes());
    try testing.expectEqual(yaml.ScalarStyle.literal, (try bom_document.scalarInfo(0)).style);
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        bom_input,
        yaml.default_limits,
    )) == null);
}

test "block auto indentation follows first content line" {
    const input = "k: |\n    a\n  b\n";
    try testing.expectError(error.Invalid, yaml.buildYamlTape(testing.allocator, input, yaml.default_limits));
    const diagnostic = (try yaml.validateYaml(
        testing.allocator,
        input,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(error.Invalid, diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.syntax, diagnostic.kind);
    try testing.expectEqual(@as(usize, 13), diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 3), diagnostic.line);
    try testing.expectEqual(@as(u32, 3), diagnostic.column);
}

test "folded blocks preserve leading blank lines" {
    const input = "k: >\n\n  a\n";
    var document = try yaml.buildYamlTape(testing.allocator, input, yaml.default_limits);
    defer document.deinit(testing.allocator);
    try testing.expectEqualStrings("\na\n", (try document.value(input, 2)).bytes());
    try testing.expectEqual(yaml.ScalarStyle.folded, (try document.scalarInfo(2)).style);
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        input,
        yaml.default_limits,
    )) == null);
}

test "quoted folding discards trailing line whitespace" {
    const input = "k: \"a  \n  b\"\n";
    var document = try yaml.buildYamlTape(testing.allocator, input, yaml.default_limits);
    defer document.deinit(testing.allocator);
    try testing.expectEqualStrings("a b", (try document.value(input, 2)).bytes());
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        input,
        yaml.default_limits,
    )) == null);
}

test "extended YAML enforces printable source characters" {
    const nul_block = "k: |\n  \x00\n";
    const nul_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        nul_block,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(error.Invalid, nul_diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.syntax, nul_diagnostic.kind);
    try testing.expectEqual(@as(usize, 7), nul_diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), nul_diagnostic.line);
    try testing.expectEqual(@as(u32, 3), nul_diagnostic.column);
    try testing.expectError(error.Invalid, yaml.buildYamlTape(testing.allocator, nul_block, yaml.default_limits));

    const nul_quoted = "k: \"a\n  \x00b\"\n";
    const quoted_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        nul_quoted,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(error.Invalid, quoted_diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.syntax, quoted_diagnostic.kind);
    try testing.expectEqual(@as(usize, 8), quoted_diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), quoted_diagnostic.line);
    try testing.expectEqual(@as(u32, 3), quoted_diagnostic.column);
    try testing.expectError(error.Invalid, yaml.buildYamlTape(testing.allocator, nul_quoted, yaml.default_limits));

    const control = "k: |\n  \xc2\x80\n";
    const control_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        control,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(error.Invalid, control_diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.syntax, control_diagnostic.kind);
    try testing.expectEqual(@as(usize, 7), control_diagnostic.byte_offset);
    try testing.expectError(error.Invalid, yaml.buildYamlTape(testing.allocator, control, yaml.default_limits));

    const noncharacter = "k: |\n  \xef\xbf\xbe\n";
    const noncharacter_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        noncharacter,
        yaml.default_limits,
    )).?;
    try testing.expectEqual(error.Invalid, noncharacter_diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.syntax, noncharacter_diagnostic.kind);
    try testing.expectEqual(@as(usize, 7), noncharacter_diagnostic.byte_offset);
    try testing.expectError(
        error.Invalid,
        yaml.buildYamlTape(testing.allocator, noncharacter, yaml.default_limits),
    );

    const printable = "k: |\n  café ☺\n";
    var document = try yaml.buildYamlTape(testing.allocator, printable, yaml.default_limits);
    defer document.deinit(testing.allocator);
    try testing.expectEqualStrings("café ☺\n", (try document.value(printable, 2)).bytes());
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        printable,
        yaml.default_limits,
    )) == null);
}

test "multiline quoted scalars enforce continuation line limits" {
    const single_two_line = "value: 'one\n  two'\n";
    try expectResourceOutcome(
        single_two_line,
        .{ .scalar_line_count_max = 1 },
        error.ScalarLineLimitExceeded,
    );
    const single_two_line_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        single_two_line,
        .{ .scalar_line_count_max = 1 },
    )).?;
    try testing.expectEqual(@as(usize, 12), single_two_line_diagnostic.byte_offset);

    var single_two_line_document = try yaml.buildYamlTape(
        testing.allocator,
        single_two_line,
        .{ .scalar_line_count_max = 2 },
    );
    defer single_two_line_document.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "one two",
        (try single_two_line_document.value(single_two_line, 2)).bytes(),
    );
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        single_two_line,
        .{ .scalar_line_count_max = 2 },
    )) == null);

    const single_three_line = "value: 'one\n  two\n  three'\n";
    var single_three_line_document = try yaml.buildYamlTape(
        testing.allocator,
        single_three_line,
        .{ .scalar_line_count_max = 3 },
    );
    defer single_three_line_document.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "one two three",
        (try single_three_line_document.value(single_three_line, 2)).bytes(),
    );
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        single_three_line,
        .{ .scalar_line_count_max = 3 },
    )) == null);
    try expectResourceOutcome(
        single_three_line,
        .{ .scalar_line_count_max = 2 },
        error.ScalarLineLimitExceeded,
    );
    const single_three_line_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        single_three_line,
        .{ .scalar_line_count_max = 2 },
    )).?;
    try testing.expectEqual(@as(usize, 18), single_three_line_diagnostic.byte_offset);

    const double_two_line = "value: \"one\n  two\"\n";
    try expectResourceOutcome(
        double_two_line,
        .{ .scalar_line_count_max = 1 },
        error.ScalarLineLimitExceeded,
    );
    const double_two_line_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        double_two_line,
        .{ .scalar_line_count_max = 1 },
    )).?;
    try testing.expectEqual(@as(usize, 12), double_two_line_diagnostic.byte_offset);

    var double_two_line_document = try yaml.buildYamlTape(
        testing.allocator,
        double_two_line,
        .{ .scalar_line_count_max = 2 },
    );
    defer double_two_line_document.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "one two",
        (try double_two_line_document.value(double_two_line, 2)).bytes(),
    );
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        double_two_line,
        .{ .scalar_line_count_max = 2 },
    )) == null);

    const double_three_line = "value: \"one\n  two\n  three\"\n";
    var double_three_line_document = try yaml.buildYamlTape(
        testing.allocator,
        double_three_line,
        .{ .scalar_line_count_max = 3 },
    );
    defer double_three_line_document.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "one two three",
        (try double_three_line_document.value(double_three_line, 2)).bytes(),
    );
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        double_three_line,
        .{ .scalar_line_count_max = 3 },
    )) == null);
    try expectResourceOutcome(
        double_three_line,
        .{ .scalar_line_count_max = 2 },
        error.ScalarLineLimitExceeded,
    );
    const double_three_line_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        double_three_line,
        .{ .scalar_line_count_max = 2 },
    )).?;
    try testing.expectEqual(@as(usize, 18), double_three_line_diagnostic.byte_offset);

    const escaped_two_line = "value: \"one\\\n  two\"\n";
    try expectResourceOutcome(
        escaped_two_line,
        .{ .scalar_line_count_max = 1 },
        error.ScalarLineLimitExceeded,
    );
    const escaped_two_line_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        escaped_two_line,
        .{ .scalar_line_count_max = 1 },
    )).?;
    try testing.expectEqual(@as(usize, 13), escaped_two_line_diagnostic.byte_offset);

    var escaped_two_line_document = try yaml.buildYamlTape(
        testing.allocator,
        escaped_two_line,
        .{ .scalar_line_count_max = 2 },
    );
    defer escaped_two_line_document.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "onetwo",
        (try escaped_two_line_document.value(escaped_two_line, 2)).bytes(),
    );
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        escaped_two_line,
        .{ .scalar_line_count_max = 2 },
    )) == null);

    const escaped_three_line = "value: \"one\\\n  two\\\n  three\"\n";
    var escaped_three_line_document = try yaml.buildYamlTape(
        testing.allocator,
        escaped_three_line,
        .{ .scalar_line_count_max = 3 },
    );
    defer escaped_three_line_document.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "onetwothree",
        (try escaped_three_line_document.value(escaped_three_line, 2)).bytes(),
    );
    try testing.expect((try yaml.validateYaml(
        testing.allocator,
        escaped_three_line,
        .{ .scalar_line_count_max = 3 },
    )) == null);
    try expectResourceOutcome(
        escaped_three_line,
        .{ .scalar_line_count_max = 2 },
        error.ScalarLineLimitExceeded,
    );
    const escaped_three_line_diagnostic = (try yaml.validateYaml(
        testing.allocator,
        escaped_three_line,
        .{ .scalar_line_count_max = 2 },
    )).?;
    try testing.expectEqual(@as(usize, 20), escaped_three_line_diagnostic.byte_offset);
}

test "extended YAML checks all configured resource limits before growth" {
    try testing.expectError(
        error.SourceBytesExceeded,
        yaml.buildYamlTape(
            testing.allocator,
            "key: value\n",
            .{ .source_bytes_max = 4 },
        ),
    );
    try testing.expectError(
        error.LineLimitExceeded,
        yaml.buildYamlTape(
            testing.allocator,
            "one: 1\ntwo: 2\n",
            .{ .line_count_max = 1 },
        ),
    );
    try testing.expectError(
        error.IndentationExceeded,
        yaml.buildYamlTape(
            testing.allocator,
            "value: |\n  text\n",
            .{ .indentation_max = 1 },
        ),
    );
    try testing.expectError(
        error.ScalarSourceExceeded,
        yaml.buildYamlTape(
            testing.allocator,
            "value: long\n",
            .{ .scalar_source_bytes_max = 3 },
        ),
    );
    try testing.expectError(
        error.CookedBytesExceeded,
        yaml.buildYamlTape(
            testing.allocator,
            "value: |\n  long\n",
            .{ .cooked_bytes_max = 3 },
        ),
    );
    try testing.expectError(
        error.ScalarLineLimitExceeded,
        yaml.buildYamlTape(
            testing.allocator,
            "value: |\n  one\n  two\n",
            .{ .scalar_line_count_max = 1 },
        ),
    );
    try testing.expectError(
        error.DepthExceeded,
        yaml.buildYamlTape(
            testing.allocator,
            "root:\n  child: value\n",
            .{ .depth_max = 1 },
        ),
    );
    try testing.expectError(
        error.TapeWordsExceeded,
        yaml.buildYamlTape(
            testing.allocator,
            "key: value\n",
            .{ .tape_words_max = 2 },
        ),
    );

    const diagnostic = (try yaml.validateYaml(
        testing.allocator,
        "value: |\n  long\n",
        .{ .cooked_bytes_max = 3 },
    )).?;
    try testing.expectEqual(error.CookedBytesExceeded, diagnostic.err);
    try testing.expectEqual(yaml.DiagnosticKind.resource, diagnostic.kind);
    try testing.expectEqual(@as(usize, 7), diagnostic.byte_offset);
}

test "extended document distinguishes borrowed source from owned cooked values" {
    var input = "plain: original\nquoted: \"fixed\"\nblock: |\n  stable\n".*;
    var document = try yaml.buildYamlTape(testing.allocator, &input, yaml.default_limits);
    defer document.deinit(testing.allocator);

    const plain = try document.value(&input, 2);
    try testing.expectEqual(yaml.ValueOwnership.source_borrowed, plain.ownership());
    try testing.expect(plain.bytes().ptr == @as([*]const u8, &input) + 7);

    const quoted = try document.value(&input, 4);
    const block = try document.value(&input, 6);
    try testing.expectEqual(yaml.ValueOwnership.document_owned, quoted.ownership());
    try testing.expectEqual(yaml.ValueOwnership.document_owned, block.ownership());

    @memcpy(input[7..15], "modified");
    @memcpy(input[26..31], "xxxxx");
    @memcpy(input[44..50], "xxxxxx");
    try testing.expectEqualStrings("modified", (try document.value(&input, 2)).bytes());
    try testing.expectEqualStrings("fixed", (try document.value(&input, 4)).bytes());
    try testing.expectEqualStrings("stable\n", (try document.value(&input, 6)).bytes());

    var other = input;
    try testing.expectError(error.SourceOutOfBounds, document.rawSpan(&other, 2));
    try testing.expectError(error.SourceOutOfBounds, document.value(&other, 2));
    try testing.expectError(error.TypeMismatch, document.value(&input, 0));
    try testing.expectError(error.TapeOutOfBounds, document.rawSpan(&input, document.tape.len));
}

fn checkBasicValidationAllocationFailure(allocator: std.mem.Allocator) !void {
    const diagnostic = try yaml.validateYaml(
        allocator,
        "key: \"value\"\n",
        yaml.default_limits,
    );
    try testing.expect(diagnostic == null);
}

test "basic validation allocation failures release temporary documents" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkBasicValidationAllocationFailure,
        .{},
    );
}

fn checkExtendedAllocationFailure(allocator: std.mem.Allocator) !void {
    const input =
        "- quoted: \"first\n" ++
        "    second\\u263A\"\n" ++
        "  literal: |+\n" ++
        "    one\n" ++
        "\n" ++
        "  nested:\n" ++
        "    child: value\n";
    var document = try yaml.buildYamlTape(allocator, input, yaml.default_limits);
    defer document.deinit(allocator);
    try testing.expectEqualStrings("first second\xe2\x98\xba", (try document.value(input, 3)).bytes());
}

test "extended YAML allocation failures clean all document-owned storage" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkExtendedAllocationFailure,
        .{},
    );
}

test "extended YAML rejects depth budgets beyond supported parser storage" {
    const limits = yaml.Limits{ .depth_max = basic.yaml_max_depth + 1 };
    try testing.expectError(error.InvalidLimits, yaml.buildYamlTape(testing.allocator, "k: v\n", limits));
    try testing.expectError(error.InvalidLimits, yaml.validateYaml(testing.allocator, "k: v\n", limits));
}

test "empty block scalar chomping removes automatic indentation" {
    const Case = struct { source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .source = "k: |\n    \n", .expected = "" },
        .{ .source = "k: |-\n    \n", .expected = "" },
        .{ .source = "k: |+\n    \n", .expected = "\n" },
        .{ .source = "k: >\n    \n", .expected = "" },
        .{ .source = "k: >-\n    \n", .expected = "" },
        .{ .source = "k: >+\n    \n", .expected = "\n" },
        .{ .source = "k: |2\n    \n", .expected = "  \n" },
    };
    for (cases) |case| {
        var document = try yaml.buildYamlTape(testing.allocator, case.source, .{});
        defer document.deinit(testing.allocator);
        try testing.expectEqualStrings(case.expected, (try document.value(case.source, 2)).bytes());
    }
}

test "automatic block indentation rejects overindented leading blank lines" {
    for ([_][]const u8{ "k: |\n    \n  a\n", "k: >\n    \n  a\n" }) |input| {
        try testing.expectError(error.Invalid, yaml.buildYamlTape(testing.allocator, input, .{}));
        const diagnostic = (try yaml.validateYaml(testing.allocator, input, .{})).?;
        try testing.expectEqual(error.Invalid, diagnostic.err);
        try testing.expectEqual(@as(usize, 12), diagnostic.byte_offset);
    }
}

test "quoted folding preserves escaped whitespace before line breaks" {
    const Case = struct { source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .source = "k: \"a\\x20\n  b\"\n", .expected = "a  b" },
        .{ .source = "k: \"a\\t\n  b\"\n", .expected = "a\t b" },
        .{ .source = "k: \"a\\x20  \n  b\"\n", .expected = "a  b" },
    };
    for (cases) |case| {
        var document = try yaml.buildYamlTape(testing.allocator, case.source, .{});
        defer document.deinit(testing.allocator);
        try testing.expectEqualStrings(case.expected, (try document.value(case.source, 2)).bytes());
    }
}
