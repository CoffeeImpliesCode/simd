const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

const json_fixture = "{\"name\":\"Ada\",\"items\":[1,true]}";
const jsonc_fixture =
    "{\"name\":\"Ada\",/* retained grammar */\"items\":[1,true]}";
const json5_fixture = "{name:'Ada',items:[1,true,],hex:0x2a}";
const jsonl_fixture = "{\"name\":\"Ada\"}\n[1,true]\n";
const markdown_fixture = "# Heading\n- item with [link](target)\n> quote\n";
const xml_fixture = "<root id=\"7\"><child>text</child><empty/></root>";
const yaml_fixture =
    "---\n" ++
    "root:\n" ++
    "  child:\n" ++
    "    - {name: one, empty:}\n" ++
    "tail: done\n" ++
    "...\n";

const GrammarFailure = struct {
    err: anyerror,
};

const JsonResident = struct {
    const Parser = lib.ondemand.Parser;
    const fixture = json_fixture;
    const malformed = "{\"ok\":1,\"bad\":[2,]}";

    fn initDocument(parser: *Parser, input: []const u8) !lib.ondemand.Document {
        return lib.formats.json.initOnDemandDocument(parser, input);
    }

    fn eagerFailure(allocator: std.mem.Allocator, input: []const u8) !GrammarFailure {
        const diagnostic = (try lib.formats.json.validateJson(allocator, input)) orelse
            return error.ExpectedGrammarError;
        return .{ .err = diagnostic.err };
    }
};

const JsoncResident = struct {
    const Parser = lib.ondemand.Parser;
    const fixture = jsonc_fixture;
    const malformed = "{\"ok\":1,/* prefix */\"bad\":[2,]}";

    fn initDocument(parser: *Parser, input: []const u8) !lib.ondemand.Document {
        return lib.formats.jsonc.initOnDemandDocument(parser, input);
    }

    fn eagerFailure(allocator: std.mem.Allocator, input: []const u8) !GrammarFailure {
        const diagnostic = (try lib.formats.jsonc.validateJsonc(allocator, input)) orelse
            return error.ExpectedGrammarError;
        return .{ .err = diagnostic.err };
    }
};

const Json5Resident = struct {
    const Parser = lib.ondemand.Parser;
    const fixture = json5_fixture;
    const malformed = "{ok:1,bad:01}";

    fn initDocument(parser: *Parser, input: []const u8) !lib.ondemand.Document {
        return lib.formats.json5.initOnDemandDocument(parser, input);
    }

    fn eagerFailure(allocator: std.mem.Allocator, input: []const u8) !GrammarFailure {
        const diagnostic = (try lib.formats.json5.validateJson5(allocator, input)) orelse
            return error.ExpectedGrammarError;
        return .{ .err = diagnostic.err };
    }
};

const JsonlResident = struct {
    const Parser = lib.formats.jsonl.Parser;
    const fixture = jsonl_fixture;
    const malformed = "{\"ok\":1}\n[2,]\n";

    fn initDocument(parser: *Parser, input: []const u8) !lib.formats.jsonl.OnDemandDocument {
        return lib.formats.jsonl.initOnDemandDocument(parser, input);
    }

    fn eagerFailure(allocator: std.mem.Allocator, input: []const u8) !GrammarFailure {
        const diagnostic = (try lib.formats.jsonl.validateJsonl(allocator, input)) orelse
            return error.ExpectedGrammarError;
        return .{ .err = diagnostic.err };
    }
};

const MarkdownResident = struct {
    const Parser = lib.formats.markdown.Parser;
    const fixture = markdown_fixture;

    fn initDocument(
        parser: *Parser,
        input: []const u8,
    ) !lib.formats.markdown.OnDemandDocument {
        return lib.formats.markdown.initOnDemandDocument(parser, input);
    }
};

const XmlResident = struct {
    const Parser = lib.formats.xml.Parser;
    const fixture = xml_fixture;
    const malformed = "<root><ok/></mismatch>";

    fn initDocument(parser: *Parser, input: []const u8) !lib.formats.xml.OnDemandDocument {
        return lib.formats.xml.initOnDemandDocument(parser, input);
    }

    fn eagerFailure(_: std.mem.Allocator, input: []const u8) !GrammarFailure {
        const diagnostic = (try lib.formats.xml.validateXml(input)) orelse
            return error.ExpectedGrammarError;
        return .{ .err = diagnostic.err };
    }
};

const YamlResident = struct {
    const Parser = lib.formats.yaml.Parser;
    const fixture = yaml_fixture;
    const malformed = "name: Ada\nitems: [one,]\n";

    fn initDocument(parser: *Parser, input: []const u8) !lib.formats.yaml.OnDemandDocument {
        return lib.formats.yaml.initOnDemandDocument(parser, input);
    }

    fn eagerFailure(allocator: std.mem.Allocator, input: []const u8) !GrammarFailure {
        const diagnostic = (try lib.formats.yaml.validateYaml(allocator, input)) orelse
            return error.ExpectedGrammarError;
        return .{ .err = diagnostic.err };
    }
};

fn eventLimit(input: []const u8) usize {
    const scaled = std.math.mul(usize, input.len, 4) catch std.math.maxInt(usize);
    return std.math.add(usize, scaled, 16) catch std.math.maxInt(usize);
}

fn expectSpanInInput(input: []const u8, span: []const u8, count: *usize) !void {
    if (span.len == 0) return;

    const input_start = @intFromPtr(input.ptr);
    const input_end = std.math.add(usize, input_start, input.len) catch
        return error.TestExpectedEqual;
    const span_start = @intFromPtr(span.ptr);
    const span_end = std.math.add(usize, span_start, span.len) catch
        return error.TestExpectedEqual;

    try testing.expect(span_start >= input_start);
    try testing.expect(span_end <= input_end);
    count.* += 1;
}

fn expectBorrowedByteSpans(
    input: []const u8,
    value: anytype,
    count: *usize,
) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size != .slice) return;
            if (pointer.child == u8) {
                try expectSpanInInput(input, value, count);
                return;
            }
            for (value) |element| {
                try expectBorrowedByteSpans(input, element, count);
            }
        },
        .array => {
            for (value) |element| {
                try expectBorrowedByteSpans(input, element, count);
            }
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                try expectBorrowedByteSpans(input, @field(value, field.name), count);
            }
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) return;
            switch (value) {
                inline else => |payload| {
                    try expectBorrowedByteSpans(input, payload, count);
                },
            }
        },
        .optional => {
            if (value) |payload| {
                try expectBorrowedByteSpans(input, payload, count);
            }
        },
        else => {},
    }
}

fn drainValidReader(input: []const u8, reader: anytype) !void {
    var steps: usize = 0;
    var borrowed_span_count: usize = 0;
    while (steps < eventLimit(input)) : (steps += 1) {
        const event = (try reader.next()) orelse {
            try testing.expect(borrowed_span_count > 0);
            return;
        };
        try expectBorrowedByteSpans(input, event, &borrowed_span_count);
    }
    return error.EventDrainBoundExceeded;
}

fn expectResidentLifecycle(comptime Format: type) !void {
    var parser = try Format.Parser.init(testing.allocator, Format.fixture.len);
    defer parser.deinit();

    var document = try Format.initDocument(&parser, Format.fixture);
    var document_released = false;
    defer {
        if (!document_released) document.deinit();
    }

    try testing.expectError(
        error.DocumentActive,
        Format.initDocument(&parser, Format.fixture),
    );

    var reader = try document.eventReader();
    try testing.expectError(error.FocusAlreadyClaimed, document.tokenCursor());

    const first_peek = (try reader.peek()) orelse return error.ExpectedResidentEvent;
    const second_peek = (try reader.peek()) orelse return error.ExpectedResidentEvent;
    const first_next = (try reader.next()) orelse return error.ExpectedResidentEvent;
    try testing.expectEqualDeep(first_peek, second_peek);
    try testing.expectEqualDeep(first_peek, first_next);

    var borrowed_span_count: usize = 0;
    try expectBorrowedByteSpans(Format.fixture, first_next, &borrowed_span_count);

    var copied_reader = reader;
    const consumed = (try reader.next()) orelse return error.ExpectedResidentEvent;
    try expectBorrowedByteSpans(Format.fixture, consumed, &borrowed_span_count);
    try testing.expectError(error.OutOfOrderIteration, copied_reader.peek());
    try testing.expectError(error.OutOfOrderIteration, copied_reader.next());

    const cached = (try reader.peek()) orelse return error.ExpectedResidentEvent;
    try expectBorrowedByteSpans(Format.fixture, cached, &borrowed_span_count);
    document.deinit();
    document_released = true;

    try testing.expectError(error.DocumentReleased, reader.peek());
    try testing.expectError(error.DocumentReleased, reader.next());
    try testing.expectError(error.DocumentReleased, copied_reader.peek());
    try testing.expectError(error.DocumentReleased, copied_reader.next());

    var reused_document = try Format.initDocument(&parser, Format.fixture);
    defer reused_document.deinit();
    var reused_reader = try reused_document.eventReader();
    try drainValidReader(Format.fixture, &reused_reader);
}

fn expectCursorLifecycle(comptime Format: type) !void {
    var parser = try Format.Parser.init(testing.allocator, Format.fixture.len);
    defer parser.deinit();
    var document = try Format.initDocument(&parser, Format.fixture);
    var document_released = false;
    defer {
        if (!document_released) document.deinit();
    }

    var cursor = try document.tokenCursor();
    try testing.expectError(error.FocusAlreadyClaimed, document.eventReader());
    const first = (try cursor.peek()) orelse return error.ExpectedResidentEvent;
    const repeated = (try cursor.peek()) orelse return error.ExpectedResidentEvent;
    try testing.expectEqualDeep(first, repeated);
    var copied_cursor = cursor;
    const consumed = (try cursor.advance()) orelse return error.ExpectedResidentEvent;
    try testing.expectEqualDeep(first, consumed);
    try testing.expectError(error.OutOfOrderIteration, copied_cursor.peek());
    try testing.expectError(error.OutOfOrderIteration, copied_cursor.advance());

    const pending = (try cursor.peek()) orelse return error.ExpectedResidentEvent;
    var borrowed_span_count: usize = 0;
    try expectBorrowedByteSpans(Format.fixture, pending, &borrowed_span_count);
    document.deinit();
    document_released = true;
    try testing.expectError(error.DocumentReleased, cursor.peek());
    try testing.expectError(error.DocumentReleased, cursor.advance());

    document = try Format.initDocument(&parser, Format.fixture);
    document_released = false;
    try testing.expectError(error.DocumentReleased, cursor.peek());
    try testing.expectError(error.DocumentReleased, cursor.advance());
    try testing.expectError(error.DocumentReleased, copied_cursor.peek());
    try testing.expectError(error.DocumentReleased, copied_cursor.advance());
    var fresh_cursor = try document.tokenCursor();
    const fresh_first = (try fresh_cursor.advance()) orelse return error.ExpectedResidentEvent;
    try testing.expectEqualDeep(first, fresh_first);
}

fn expectQuotedCopyOutOfOrder(comptime Format: type, input: []const u8) !void {
    var parser = try Format.Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try Format.initDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();
    var copied_reader = reader;

    const event = (try reader.next()) orelse return error.ExpectedResidentEvent;
    var borrowed_span_count: usize = 0;
    try expectBorrowedByteSpans(input, event, &borrowed_span_count);
    try testing.expect(borrowed_span_count > 0);
    try testing.expectError(error.OutOfOrderIteration, copied_reader.peek());
    try testing.expectError(error.OutOfOrderIteration, copied_reader.next());
}

fn expectCapacityAndReuse(comptime Format: type) !void {
    var bounded = try Format.Parser.init(testing.allocator, Format.fixture.len - 1);
    defer bounded.deinit();
    try testing.expectError(
        error.CapacityExceeded,
        Format.initDocument(&bounded, Format.fixture),
    );

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var parser = try Format.Parser.init(failing.allocator(), 0);
    defer parser.deinit();

    {
        var warm_document = try Format.initDocument(&parser, Format.fixture);
        defer warm_document.deinit();
        var warm_reader = try warm_document.eventReader();
        try drainValidReader(Format.fixture, &warm_reader);
    }

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    {
        var reused_document = try Format.initDocument(&parser, Format.fixture);
        defer reused_document.deinit();
        var reused_reader = try reused_document.eventReader();
        try drainValidReader(Format.fixture, &reused_reader);
    }
}

fn expectLazyMalformedSuffix(comptime Format: type) !void {
    const expected_error = (try Format.eagerFailure(
        testing.allocator,
        Format.malformed,
    )).err;

    var parser = try Format.Parser.init(testing.allocator, Format.malformed.len);
    defer parser.deinit();
    var document = try Format.initDocument(&parser, Format.malformed);
    defer document.deinit();
    var reader = try document.eventReader();

    const prefix = (try reader.next()) orelse return error.ExpectedResidentEvent;
    var borrowed_span_count: usize = 0;
    try expectBorrowedByteSpans(Format.malformed, prefix, &borrowed_span_count);

    var steps: usize = 1;
    while (steps < eventLimit(Format.malformed)) : (steps += 1) {
        const event = reader.next() catch |err| {
            try testing.expectEqual(expected_error, err);
            return;
        };
        const value = event orelse return error.ExpectedGrammarError;
        try expectBorrowedByteSpans(Format.malformed, value, &borrowed_span_count);
    }
    return error.EventDrainBoundExceeded;
}

const FaultingReader = struct {
    reader: std.Io.Reader,
    input: []const u8,
    offset: usize = 0,
    fail_at: usize,

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
    };

    fn init(input: []const u8, fail_at: usize, buffer: []u8) FaultingReader {
        return .{
            .reader = .{
                .vtable = &vtable,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .input = input,
            .fail_at = fail_at,
        };
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("reader", reader));
        if (self.offset >= self.fail_at) return error.ReadFailed;

        const available = self.fail_at - self.offset;
        const count = @min(available, @intFromEnum(limit));
        if (count == 0) return 0;

        try writer.writeAll(self.input[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};

const MarkdownStream = struct {
    const fixture = markdown_fixture;

    fn oneShot(
        allocator: std.mem.Allocator,
        input: []const u8,
    ) !lib.formats.markdown.MarkdownStructuralIndex {
        return lib.formats.markdown.indexMarkdown(allocator, input);
    }

    fn init(
        allocator: std.mem.Allocator,
        chunk_len: usize,
    ) !lib.formats.markdown.MarkdownStreamIndexer {
        return lib.formats.markdown.initStreamIndexer(allocator, chunk_len);
    }

    fn expectEqual(
        expected: *const lib.formats.markdown.MarkdownStructuralIndex,
        actual: *const lib.formats.markdown.MarkdownStructuralIndex,
    ) !void {
        try testing.expectEqual(expected.count, actual.count);
        try testing.expectEqualSlices(
            u32,
            expected.indexes[0 .. expected.count + 3],
            actual.indexes[0 .. actual.count + 3],
        );
        try testing.expectEqualSlices(
            lib.formats.markdown.MarkdownTokenKind,
            expected.kinds[0..expected.count],
            actual.kinds[0..actual.count],
        );
    }
};

const XmlStream = struct {
    const fixture = xml_fixture;

    fn oneShot(
        allocator: std.mem.Allocator,
        input: []const u8,
    ) !lib.formats.xml.XmlStructuralIndex {
        return lib.formats.xml.indexXml(allocator, input);
    }

    fn init(
        allocator: std.mem.Allocator,
        chunk_len: usize,
    ) !lib.formats.xml.XmlStreamIndexer {
        return lib.formats.xml.initStreamIndexer(allocator, chunk_len);
    }

    fn expectEqual(
        expected: *const lib.formats.xml.XmlStructuralIndex,
        actual: *const lib.formats.xml.XmlStructuralIndex,
    ) !void {
        try testing.expectEqual(expected.count, actual.count);
        try testing.expectEqualSlices(
            u32,
            expected.indexes[0 .. expected.count + 3],
            actual.indexes[0 .. actual.count + 3],
        );
        try testing.expectEqualSlices(
            lib.formats.xml.XmlTokenKind,
            expected.kinds[0..expected.count],
            actual.kinds[0..actual.count],
        );
    }
};

const YamlStream = struct {
    const fixture = yaml_fixture;

    fn oneShot(
        allocator: std.mem.Allocator,
        input: []const u8,
    ) !lib.formats.yaml.YamlStructuralIndex {
        return lib.formats.yaml.indexYaml(allocator, input);
    }

    fn init(
        allocator: std.mem.Allocator,
        chunk_len: usize,
    ) !lib.formats.yaml.YamlStreamIndexer {
        return lib.formats.yaml.initStreamIndexer(allocator, chunk_len);
    }

    fn expectEqual(
        expected: *const lib.formats.yaml.YamlStructuralIndex,
        actual: *const lib.formats.yaml.YamlStructuralIndex,
    ) !void {
        try testing.expectEqual(expected.count, actual.count);
        try testing.expectEqualSlices(
            u32,
            expected.indexes[0 .. expected.count + 3],
            actual.indexes[0 .. actual.count + 3],
        );
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
};

fn expectStreamContract(comptime Format: type) !void {
    var expected = try Format.oneShot(testing.allocator, Format.fixture);
    defer expected.deinit(testing.allocator);

    {
        var indexer = try Format.init(testing.allocator, 3);
        defer indexer.deinit();
        var reader = std.Io.Reader.fixed(Format.fixture);
        try indexer.feedFrom(&reader);

        var actual = indexer.take();
        defer actual.deinit(testing.allocator);
        try Format.expectEqual(&expected, &actual);
    }

    {
        var source_buffer: [3]u8 = undefined;
        var faulting = FaultingReader.init(
            Format.fixture,
            Format.fixture.len,
            &source_buffer,
        );
        var indexer = try Format.init(testing.allocator, 3);
        defer indexer.deinit();
        try testing.expectError(error.ReadFailed, indexer.feedFrom(&faulting.reader));
        try indexer.finish();

        var actual = indexer.take();
        defer actual.deinit(testing.allocator);
        try Format.expectEqual(&expected, &actual);
    }

    {
        var indexer = try Format.init(testing.allocator, 3);
        defer indexer.deinit();
        var source_buffer: [3]u8 = undefined;
        var offset: usize = 0;
        while (offset < Format.fixture.len) {
            const chunk_len = @min(source_buffer.len, Format.fixture.len - offset);
            @memcpy(
                source_buffer[0..chunk_len],
                Format.fixture[offset..][0..chunk_len],
            );
            try indexer.feed(source_buffer[0..chunk_len]);
            @memset(source_buffer[0..chunk_len], 0xa5);
            offset += chunk_len;
        }
        try indexer.finish();

        var actual = indexer.take();
        defer actual.deinit(testing.allocator);
        try Format.expectEqual(&expected, &actual);
    }
}

test "resident JSON enforces lifecycle focus iteration and borrowed spans" {
    try expectResidentLifecycle(JsonResident);
    try expectCursorLifecycle(JsonResident);
}

test "resident JSONC enforces lifecycle focus iteration and borrowed spans" {
    try expectResidentLifecycle(JsoncResident);
    try expectCursorLifecycle(JsoncResident);
}

test "resident JSON5 enforces lifecycle focus iteration and borrowed spans" {
    try expectResidentLifecycle(Json5Resident);
    try expectCursorLifecycle(Json5Resident);
}

test "resident JSONL enforces lifecycle focus iteration and borrowed spans" {
    try expectResidentLifecycle(JsonlResident);
    try expectCursorLifecycle(JsonlResident);
}

test "resident Markdown enforces lifecycle focus iteration and borrowed spans" {
    try expectResidentLifecycle(MarkdownResident);
    try expectCursorLifecycle(MarkdownResident);
}

test "resident XML enforces lifecycle focus iteration and borrowed spans" {
    try expectResidentLifecycle(XmlResident);
    try expectCursorLifecycle(XmlResident);
}

test "resident YAML enforces lifecycle focus iteration and borrowed spans" {
    try expectResidentLifecycle(YamlResident);
    try expectCursorLifecycle(YamlResident);
}

test "resident JSONC and JSON5 copied quoted readers become out of order" {
    try expectQuotedCopyOutOfOrder(JsoncResident, "\"quoted\"");
    try expectQuotedCopyOutOfOrder(Json5Resident, "'quoted'");
}

test "resident JSON bounded capacity and allocation-free reuse" {
    try expectCapacityAndReuse(JsonResident);
}

test "resident JSONC bounded capacity and allocation-free reuse" {
    try expectCapacityAndReuse(JsoncResident);
}

test "resident JSON5 bounded capacity and allocation-free reuse" {
    try expectCapacityAndReuse(Json5Resident);
}

test "resident JSONL bounded capacity and allocation-free reuse" {
    try expectCapacityAndReuse(JsonlResident);
}

test "resident Markdown bounded capacity and allocation-free reuse" {
    try expectCapacityAndReuse(MarkdownResident);
}

test "resident XML bounded capacity and allocation-free reuse" {
    try expectCapacityAndReuse(XmlResident);
}

test "resident YAML bounded capacity and allocation-free reuse" {
    try expectCapacityAndReuse(YamlResident);
}

test "resident JSON exposes a valid prefix before the eager grammar error" {
    try expectLazyMalformedSuffix(JsonResident);
}

test "resident JSONC exposes a valid prefix before the eager grammar error" {
    try expectLazyMalformedSuffix(JsoncResident);
}

test "resident JSON5 exposes a valid prefix before the eager grammar error" {
    try expectLazyMalformedSuffix(Json5Resident);
}

test "resident JSONL exposes a valid record before the eager grammar error" {
    try expectLazyMalformedSuffix(JsonlResident);
}

test "resident XML exposes a valid prefix before the eager grammar error" {
    try expectLazyMalformedSuffix(XmlResident);
}

test "resident YAML exposes a valid prefix before the eager grammar error" {
    try expectLazyMalformedSuffix(YamlResident);
}

test "Markdown stream reader and caller chunk lifetimes match one shot" {
    try expectStreamContract(MarkdownStream);
}

test "XML stream reader and caller chunk lifetimes match one shot" {
    try expectStreamContract(XmlStream);
}

test "YAML stream reader and caller chunk lifetimes match one shot" {
    try expectStreamContract(YamlStream);
}
