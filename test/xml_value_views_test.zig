const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;
const xml = lib.formats.xml;

fn findTapeKind(document: *const xml.XmlDocument, kind: xml.XmlTapeKind) usize {
    for (document.tape, 0..) |word, index| {
        if (word.kind == @backingInt(kind)) return index;
    }
    unreachable;
}

fn appendXmlIndexedAttribute(
    allocator: std.mem.Allocator,
    input: *std.ArrayList(u8),
    index: usize,
) !void {
    var number: [20]u8 = undefined;
    const number_text = try std.mem.print(&number, "{d}", .{index});
    try input.appendSlice(allocator, " a");
    try input.appendSlice(allocator, number_text);
    try input.appendSlice(allocator, "='x'");
}

fn makeXmlIndexedAttributes(
    allocator: std.mem.Allocator,
    count: usize,
    duplicate_index: ?usize,
) ![]u8 {
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(allocator);
    try input.appendSlice(allocator, "<r");
    for (0..count) |index| {
        try appendXmlIndexedAttribute(allocator, &input, index);
    }
    if (duplicate_index) |index| {
        try appendXmlIndexedAttribute(allocator, &input, index);
    }
    try input.appendSlice(allocator, "/>");
    return input.toOwnedSlice(allocator);
}

test "XML checked tape events decode exact text and attribute bytes" {
    const input =
        "<r a='A&amp;&#x1F642;\r\n\t&#x9;'>" ++
        "x&lt;&gt;&amp;&apos;&quot;&#128578;\r\nz</r>";
    var document = try xml.buildXmlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    _ = try cursor.advance();

    const attribute = try cursor.currentAttribute();
    try testing.expectEqualStrings("a='A&amp;&#x1F642;\r\n\t&#x9;'", attribute.raw);
    try testing.expectEqualStrings("a", attribute.name);
    try testing.expectEqualStrings("A&amp;&#x1F642;\r\n\t&#x9;", attribute.value);
    try testing.expect(attribute.raw.ptr == input.ptr + attribute.offset);

    const expected_attribute = "A&\xF0\x9F\x99\x82  \t";
    try testing.expectEqual(expected_attribute.len, try attribute.decodedLength(input));
    var attribute_output: [64]u8 = undefined;
    const attribute_count = try attribute.decodeInto(.{
        .source = input,
        .output = attribute_output[0..],
    });
    try testing.expectEqual(expected_attribute.len, attribute_count);
    try testing.expectEqualStrings(expected_attribute, attribute_output[0..attribute_count]);

    _ = try cursor.advance();
    const text = try cursor.currentText();
    try testing.expectEqualStrings(
        "x&lt;&gt;&amp;&apos;&quot;&#128578;\r\nz",
        text.raw,
    );
    try testing.expect(text.raw.ptr == input.ptr + text.offset);

    const expected_text = "x<>&'\"\xF0\x9F\x99\x82\nz";
    try testing.expectEqual(expected_text.len, try text.decodedLength(input));
    var text_output: [64]u8 = undefined;
    const text_count = try text.decodeInto(.{
        .source = input,
        .output = text_output[0..],
    });
    try testing.expectEqual(expected_text.len, text_count);
    try testing.expectEqualStrings(expected_text, text_output[0..text_count]);
}

test "XML decoded values normalize literal and referenced whitespace differently" {
    const input = "<r x='a\r\nb\rc\nd\t&#x9;&#xA;&#xD;'>a\r\nb\rc\nd</r>";
    var document = try xml.buildXmlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    _ = try cursor.advance();
    const attribute = try cursor.currentAttribute();

    var output: [64]u8 = undefined;
    var count = try attribute.decodeInto(.{ .source = input, .output = output[0..] });
    try testing.expectEqualStrings("a b c d \t\n\r", output[0..count]);

    _ = try cursor.advance();
    const text = try cursor.currentText();
    count = try text.decodeInto(.{ .source = input, .output = output[0..] });
    try testing.expectEqualStrings("a\nb\nc\nd", output[0..count]);
}

test "XML CDATA value access normalizes EOL without decoding entities" {
    const input = "<r><![CDATA[a\r\n&amp;\rb]]></r>";
    var document = try xml.buildXmlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    _ = try cursor.advance();
    const cdata = try cursor.currentCdata();
    try testing.expectEqualStrings("<![CDATA[a\r\n&amp;\rb]]>", cdata.raw);
    try testing.expectEqualStrings("a\r\n&amp;\rb", cdata.content);

    var output: [32]u8 = undefined;
    const count = try cdata.decodeInto(.{ .source = input, .output = output[0..] });
    try testing.expectEqualStrings("a\n&amp;\nb", output[0..count]);
    const needed = try cdata.decodedLength(input);
    var short_output: [16]u8 = @splat(0xC3);
    const short_before = short_output;
    try testing.expectError(
        error.CapacityExceeded,
        cdata.decodeInto(.{
            .source = input,
            .output = short_output[0 .. needed - 1],
        }),
    );
    try testing.expectEqualSlices(u8, short_before[0..], short_output[0..]);
}

test "XML decoding rejects short and overlapping output before writes" {
    const input = "<r a='A&amp;B'>x&amp;y</r>";
    var document = try xml.buildXmlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    _ = try cursor.advance();
    const attribute = try cursor.currentAttribute();
    const needed = try attribute.decodedLength(input);

    var short_output: [16]u8 = @splat(0xA5);
    const short_before = short_output;
    try testing.expectError(
        error.CapacityExceeded,
        attribute.decodeInto(.{
            .source = input,
            .output = short_output[0 .. needed - 1],
        }),
    );
    try testing.expectEqualSlices(u8, short_before[0..], short_output[0..]);
    _ = try cursor.advance();
    const text = try cursor.currentText();
    const text_needed = try text.decodedLength(input);
    var short_text_output: [16]u8 = @splat(0x5A);
    const short_text_before = short_text_output;
    try testing.expectError(
        error.CapacityExceeded,
        text.decodeInto(.{
            .source = input,
            .output = short_text_output[0 .. text_needed - 1],
        }),
    );
    try testing.expectEqualSlices(u8, short_text_before[0..], short_text_output[0..]);

    var mutable_source = "<r a='A&amp;B'>x</r>".*;
    const mutable_before = mutable_source;
    var mutable_document = try xml.buildXmlTape(testing.allocator, mutable_source[0..]);
    defer mutable_document.deinit(testing.allocator);
    var mutable_cursor = try mutable_document.root(mutable_source[0..]);
    _ = try mutable_cursor.advance();
    const mutable_attribute = try mutable_cursor.currentAttribute();
    try testing.expectError(
        error.OverlappingBuffers,
        mutable_attribute.decodeInto(.{
            .source = mutable_source[0..],
            .output = mutable_source[0..8],
        }),
    );
    try testing.expectEqualSlices(u8, mutable_before[0..], mutable_source[0..]);

    const empty_input = "<r a=''/>";
    var empty_document = try xml.buildXmlTape(testing.allocator, empty_input);
    defer empty_document.deinit(testing.allocator);
    var empty_cursor = try empty_document.root(empty_input);
    _ = try empty_cursor.advance();
    const empty_attribute = try empty_cursor.currentAttribute();
    try testing.expectEqual(@as(usize, 0), try empty_attribute.decodedLength(empty_input));
    var empty_output: [0]u8 = .{};
    try testing.expectEqual(
        @as(usize, 0),
        try empty_attribute.decodeInto(.{ .source = empty_input, .output = empty_output[0..] }),
    );
}

test "XML event decoding rejects forged spans and member slices" {
    const input = "<r a='ok'>text</r>";
    var document = try xml.buildXmlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    _ = try cursor.advance();
    const attribute = try cursor.currentAttribute();

    const copied_raw = "a='ok'";
    const copied: xml.XmlAttributeEvent = .{
        .raw = copied_raw,
        .name = copied_raw[0..1],
        .value = copied_raw[3..5],
        .offset = attribute.offset,
    };
    try testing.expectError(error.SourceMismatch, copied.decodedLength(input));

    var forged_value = attribute;
    forged_value.value = forged_value.name;
    try testing.expectError(error.SourceMismatch, forged_value.decodedLength(input));

    var truncated = attribute;
    truncated.raw = truncated.raw[0 .. truncated.raw.len - 1];
    const cdata_input = "<r><![CDATA[data]]></r>";
    var cdata_document = try xml.buildXmlTape(testing.allocator, cdata_input);
    defer cdata_document.deinit(testing.allocator);
    var cdata_cursor = try cdata_document.root(cdata_input);
    _ = try cdata_cursor.advance();
    const cdata = try cdata_cursor.currentCdata();
    var crossed_cdata = cdata;
    crossed_cdata.raw = cdata_input[cdata.offset..];
    try testing.expectError(error.InvalidTapeOrder, crossed_cdata.decodedLength(cdata_input));

    try testing.expectError(error.InvalidAttribute, truncated.decodedLength(input));

    _ = try cursor.advance();
    const text = try cursor.currentText();
    var wrong_offset = text;
    wrong_offset.offset -= 1;
    try testing.expectError(error.SourceMismatch, wrong_offset.decodedLength(input));

    var crossed_boundary = text;
    crossed_boundary.raw = input[text.offset..];
    try testing.expectError(error.InvalidTapeOrder, crossed_boundary.decodedLength(input));
}

test "XML checked tape events reject mutated tape words" {
    const input = "<r a='ok'>text</r>";
    var document = try xml.buildXmlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    const attribute_index = findTapeKind(&document, .attribute);

    var cursor = try document.root(input);
    cursor.position = attribute_index;

    const saved = document.tape[attribute_index];
    document.tape[attribute_index].payload = 0;
    try testing.expectError(error.InvalidTapeOrder, cursor.currentAttribute());
    try testing.expectError(error.InvalidTapeOrder, document.root(input));

    document.tape[attribute_index] = saved;
    document.tape[attribute_index].offset = std.math.maxInt(u32);
    try testing.expectError(error.SourceOutOfBounds, cursor.currentAttribute());

    document.tape[attribute_index] = saved;
    document.tape[attribute_index].kind = 255;
    try testing.expectError(error.InvalidTapeKind, cursor.currentAttribute());
}

test "XML decoder validates Unicode references entities characters and UTF-8" {
    const unicode_raw = "&#x1F642;&#128578;&#xD;";
    const unicode_event: xml.XmlTextEvent = .{ .raw = unicode_raw, .offset = 0 };
    var output: [16]u8 = undefined;
    const count = try unicode_event.decodeInto(.{
        .source = unicode_raw,
        .output = output[0..],
    });
    try testing.expectEqualStrings(
        "\xF0\x9F\x99\x82\xF0\x9F\x99\x82\r",
        output[0..count],
    );

    const invalid_entities = [_][]const u8{
        "&unknown;",
        "&amp",
        "&#;",
        "&#x;",
        "&#X41;",
        "&#0;",
        "&#xD800;",
        "&#xFFFE;",
        "&#x110000;",
        "&#999999999999999999999999;",
    };
    for (invalid_entities) |raw| {
        const event: xml.XmlTextEvent = .{ .raw = raw, .offset = 0 };
        try testing.expectError(error.InvalidEntity, event.decodedLength(raw));
    }

    const invalid_character = [_]u8{0};
    const character_event: xml.XmlTextEvent = .{
        .raw = invalid_character[0..],
        .offset = 0,
    };
    try testing.expectError(
        error.InvalidCharacter,
        character_event.decodedLength(invalid_character[0..]),
    );

    const invalid_utf8 = [_]u8{ 0xC0, 0xAF };
    const utf8_event: xml.XmlTextEvent = .{ .raw = invalid_utf8[0..], .offset = 0 };
    var invalid_output: [16]u8 = @splat(0xA5);
    const invalid_before = invalid_output;
    const invalid_raw = "&unknown;";
    const invalid_event: xml.XmlTextEvent = .{ .raw = invalid_raw, .offset = 0 };
    try testing.expectError(
        error.InvalidEntity,
        invalid_event.decodeInto(.{
            .source = invalid_raw,
            .output = invalid_output[0..],
        }),
    );
    try testing.expectEqualSlices(u8, invalid_before[0..], invalid_output[0..]);
    try testing.expectError(error.InvalidUtf8, utf8_event.decodedLength(invalid_utf8[0..]));
}

test "XML duplicate prefilter preserves wide unique attribute lists" {
    const unique_input = try makeXmlIndexedAttributes(testing.allocator, 600, null);
    defer testing.allocator.free(unique_input);
    try testing.expectEqual(
        @as(?xml.XmlDiagnostic, null),
        try xml.validateXml(unique_input),
    );
    var document = try xml.buildXmlTape(testing.allocator, unique_input);
    defer document.deinit(testing.allocator);

    const duplicate_input = try makeXmlIndexedAttributes(testing.allocator, 600, 300);
    defer testing.allocator.free(duplicate_input);
    try testing.expectError(
        error.DuplicateAttribute,
        xml.buildXmlTape(testing.allocator, duplicate_input),
    );
}

test "XML ASCII name scan preserves unrolled delimiters and Unicode fallback" {
    const inputs = [_][]const u8{
        "<a/>",
        "<abcd/>",
        "<abcde/>",
        "<abcdefgh/>",
        "<abcdefghi/>",
        "<root attr1234='x'/>",
        "<\xCF\x80abc/>",
    };
    for (inputs) |input| {
        try testing.expectEqual(
            @as(?xml.XmlDiagnostic, null),
            try xml.validateXml(input),
        );
    }
}

test "XML declaration info is checked borrowed metadata" {
    const raw = "<?xml version='1.0' encoding=\"utf-8\" standalone='yes'?>";
    const info = try xml.parseDeclarationInfo(raw);
    try testing.expectEqualStrings("1.0", info.version);
    const encoding = info.encoding orelse return error.TestUnexpectedResult;
    const standalone = info.standalone orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("utf-8", encoding);
    try testing.expectEqualStrings("yes", standalone);
    try testing.expect(@intFromPtr(info.version.ptr) >= @intFromPtr(raw.ptr));
    try testing.expect(@intFromPtr(info.version.ptr) + info.version.len <= @intFromPtr(raw.ptr) + raw.len);
    try testing.expect(@intFromPtr(encoding.ptr) >= @intFromPtr(raw.ptr));
    try testing.expect(@intFromPtr(standalone.ptr) >= @intFromPtr(raw.ptr));

    const minimal = try xml.parseDeclarationInfo("<?xml version=\"1.0\"?>");
    try testing.expect(minimal.encoding == null);
    try testing.expect(minimal.standalone == null);

    const input = raw ++ "<r/>";
    var parser = try xml.Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try xml.initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();
    const event = (try reader.next()) orelse return error.TestUnexpectedResult;
    switch (event) {
        .xml_declaration => |declaration| {
            const event_info = try declaration.info(input);
            const union_info = try event.declarationInfo(input);
            try testing.expectEqualStrings("1.0", event_info.version);
            try testing.expectEqualStrings("utf-8", event_info.encoding orelse return error.TestUnexpectedResult);
            const version_offset = @intFromPtr(info.version.ptr) - @intFromPtr(raw.ptr);
            try testing.expect(event_info.version.ptr == input.ptr + version_offset);
            try testing.expect(union_info.version.ptr == input.ptr + version_offset);
        },
        else => return error.ExpectedXmlDeclaration,
    }
}

test "XML declaration info validates syntax order quotes and metadata" {
    const malformed = [_][]const u8{
        "<?xml?>",
        "<?xml encoding='UTF-8' version='1.0'?>",
        "<?xml version='1.0' version='1.0'?>",
        "<?xml version='1.0'encoding='UTF-8'?>",
        "<?xml version='1.0' encoding='UTF-16'?>",
        "<?xml version='1.0' encoding='_UTF-8'?>",
        "<?xml version='1.0' standalone='maybe'?>",
        "<?xml version='1.0' standalone='yes' encoding='UTF-8'?>",
        "<?xml version='1.0\"?>",
        "<?xml version='1.0' extra='x'?>",
        "<?XML version='1.0'?>",
        "<?xml version='1.0'?>tail",
    };
    for (malformed) |raw| {
        try testing.expectError(error.InvalidDeclaration, xml.parseDeclarationInfo(raw));
    }

    const invalid_utf8 = [_]u8{
        '<', '?', 'x', 'm',  'l', ' ',  'v', 'e', 'r', 's', 'i', 'o', 'n', '=', '\'',
        '1', '.', '0', '\'', ' ', 0xFF, '?', '>',
    };
    try testing.expectError(error.InvalidUtf8, xml.parseDeclarationInfo(invalid_utf8[0..]));

    const invalid_character = [_]u8{
        '<', '?', 'x', 'm',  'l', ' ', 'v', 'e', 'r', 's', 'i', 'o', 'n', '=', '\'',
        '1', '.', '0', '\'', ' ', 0,   '?', '>',
    };
    try testing.expectError(
        error.InvalidCharacter,
        xml.parseDeclarationInfo(invalid_character[0..]),
    );
}

test "XML documents expose optional checked declaration metadata" {
    const declared_input = "<?xml version='1.0' standalone=\"no\"?><r/>";
    var declared = try xml.buildXmlTape(testing.allocator, declared_input);
    defer declared.deinit(testing.allocator);
    const declared_info = (try declared.declarationInfo(declared_input)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("1.0", declared_info.version);
    try testing.expectEqualStrings("no", declared_info.standalone orelse return error.TestUnexpectedResult);

    const plain_input = "<r/>";
    var plain = try xml.buildXmlTape(testing.allocator, plain_input);
    defer plain.deinit(testing.allocator);
    try testing.expect((try plain.declarationInfo(plain_input)) == null);

    const saved = declared.tape[0];
    declared.tape[0].payload = 1;
    try testing.expectError(error.InvalidTapeOrder, declared.declarationInfo(declared_input));
    declared.tape[0] = saved;

    const same_length_wrong_source = "<?xml version='1.0' standalone=\"no\"?><x/>";
    try testing.expectEqual(declared_input.len, same_length_wrong_source.len);
    try testing.expectError(
        error.SourceMismatch,
        declared.declarationInfo(same_length_wrong_source),
    );
}

test "XmlQName split validates lexical NCNames and borrows input" {
    const bare_raw = "local";
    const bare = try xml.XmlQName.split(bare_raw);
    try testing.expect(bare.prefix == null);
    try testing.expectEqualStrings("local", bare.local_name);
    try testing.expect(bare.local_name.ptr == bare_raw.ptr);

    const prefixed_raw = "pre:local";
    const prefixed = try xml.XmlQName.split(prefixed_raw);
    const prefixed_prefix = prefixed.prefix orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("pre", prefixed_prefix);
    try testing.expectEqualStrings("local", prefixed.local_name);
    try testing.expect(prefixed_prefix.ptr == prefixed_raw.ptr);
    try testing.expect(prefixed.local_name.ptr == prefixed_raw.ptr + 4);

    const unicode_raw = "\xCF\x80:\xE5\x90\x8D";
    const unicode = try xml.XmlQName.split(unicode_raw);
    try testing.expectEqualStrings("\xCF\x80", unicode.prefix orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("\xE5\x90\x8D", unicode.local_name);

    const invalid = [_][]const u8{
        "",
        ":local",
        "pre:",
        "a:b:c",
        "1local",
        "pre:1local",
        "pre local",
        "pre::local",
    };
    for (invalid) |raw| {
        try testing.expectError(error.InvalidName, xml.XmlQName.split(raw));
    }

    const invalid_utf8 = [_]u8{ 0xC0, 0xAF };
    try testing.expectError(error.InvalidUtf8, xml.XmlQName.split(invalid_utf8[0..]));

    const lexical_name_not_qname = "<a:b:c/>";
    try testing.expectEqual(
        @as(?xml.XmlDiagnostic, null),
        try xml.validateXml(lexical_name_not_qname),
    );
    try testing.expectError(error.InvalidName, xml.XmlQName.split("a:b:c"));
}
