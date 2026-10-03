//! Native consumer example: retain source and owners, register cleanup, then read values.
//! Run with `zig build example`; external consumers use the same named `simd` module.

const std = @import("std");
const simd = @import("simd");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const input = "\"hi\\n\"";

    // The tape owns storage; its cursor separately borrows the original input.
    {
        var document = try simd.formats.json.buildJsonTape(allocator, input);
        defer document.deinit(allocator);
        const cursor = try document.root(input);
        var output: [4]u8 = undefined;
        const decoded = try simd.json_value.decodeString(try cursor.rawValue(), &output);
        try expectBytes("hi\n", decoded);
    }

    // The parser and pointer-bearing document stay at these addresses while the reader lives.
    // LIFO cleanup releases the document lease before freeing parser storage.
    {
        var parser = try simd.ondemand.Parser.init(allocator, 0);
        defer parser.deinit();
        var document = try simd.formats.json.initOnDemandDocument(&parser, input);
        defer document.deinit();
        var reader = try document.eventReader();
        const event = (try reader.next()) orelse return error.UnexpectedValue;
        switch (event) {
            .string => |raw| try expectBytes("hi\\n", raw),
            else => return error.UnexpectedValue,
        }
        if (try reader.next() != null) return error.UnexpectedValue;
    }

    // Streaming copies chunks but transfers only indexes, not retained source bytes.
    {
        var indexer = try simd.formats.json.initStreamIndexer(allocator, 64);
        defer indexer.deinit();
        var reader: std.Io.Reader = .fixed(input);
        try indexer.feedFrom(&reader);
        var index = indexer.take();
        defer index.deinit(allocator);
        if (index.count != 1 or index.indexes[0] != 0) return error.UnexpectedValue;
        if (index.indexes[index.count] != input.len) return error.UnexpectedValue;
    }

    // Rendered HTML has its own owner and is released even if later work fails.
    {
        const commonmark = simd.formats.commonmark;
        var document = try commonmark.parseCommonMark(allocator, "# title\n", .{});
        defer document.deinit();
        const html = try commonmark.renderCommonMarkHtml(allocator, &document, .{ .mode = .safe });
        defer allocator.free(html);
        try expectBytes("<h1>title</h1>\n", html);
    }

    // Cooked YAML values belong to the document, not to a caller input or scratch buffer.
    {
        const yaml = simd.formats.yaml_extended;
        const source = "message: |\n  first\n  second\n";
        var document = try yaml.buildYamlTape(allocator, source, .{});
        defer document.deinit(allocator);
        var found = false;
        for (document.tape, 0..) |word, position| {
            if (word.tapeKind() != .scalar) continue;
            const value = try document.value(source, position);
            if (value.ownership() != .document_owned) return error.UnexpectedValue;
            try expectBytes("first\nsecond\n", value.bytes());
            found = true;
        }
        if (!found) return error.UnexpectedValue;
    }

    // Malformed escaped input fails without modifying caller-owned output.
    {
        var output = [_]u8{0xaa} ** 4;
        if (simd.json_value.decodeString("bad\\q", &output)) |_| {
            return error.UnexpectedValue;
        } else |err| {
            if (err != error.InvalidEscape) return err;
        }
        for (output) |byte| {
            if (byte != 0xaa) return error.UnexpectedValue;
        }
    }

    try std.Io.File.stdout().writeStreamingAll(
        init.io,
        "Consumer example: eager values, resident lease, stream transfer, " ++
            "semantic rendering, cooked YAML and decode failure verified.\n",
    );
}

fn expectBytes(expected: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) return error.UnexpectedValue;
}
