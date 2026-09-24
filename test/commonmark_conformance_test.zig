const std = @import("std");
const testing = std.testing;
const commonmark = @import("simd_lib").formats.commonmark;

const Example = struct {
    markdown: []const u8,
    html: []const u8,
    example: u32,
    start_line: u32,
    end_line: u32,
    section: []const u8,
};

const corpus = @embedFile("corpus/upstream/commonmark-0.31.2/spec.json");

fn parseCorpus(allocator: std.mem.Allocator) !std.json.Parsed([]Example) {
    return std.json.parseFromSlice([]Example, allocator, corpus, .{
        .ignore_unknown_fields = false,
    });
}

test "CommonMark 0.31.2 corpus renders every pinned example" {
    var parsed = try parseCorpus(testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 652), parsed.value.len);
    var failures: usize = 0;

    for (parsed.value) |example| {
        var document = commonmark.parseCommonMark(testing.allocator, example.markdown, .{}) catch |err| {
            std.debug.print(
                "CommonMark example {d} ({s}, lines {d}-{d}) parse failed: {s}\n",
                .{ example.example, example.section, example.start_line, example.end_line, @errorName(err) },
            );
            failures += 1;
            continue;
        };
        defer document.deinit();

        const rendered = commonmark.renderCommonMarkHtml(testing.allocator, &document, .{ .mode = .conformance }) catch |err| {
            std.debug.print(
                "CommonMark example {d} ({s}, lines {d}-{d}) render failed: {s}\n",
                .{ example.example, example.section, example.start_line, example.end_line, @errorName(err) },
            );
            failures += 1;
            continue;
        };
        defer testing.allocator.free(rendered);

        if (!std.mem.eql(u8, example.html, rendered)) {
            std.debug.print(
                "CommonMark example {d} ({s}, lines {d}-{d}) mismatch\nexpected:\n{s}actual:\n{s}",
                .{ example.example, example.section, example.start_line, example.end_line, example.html, rendered },
            );
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "CommonMark document borrows source and owns semantic text" {
    const input = "alpha &amp; beta";
    var document = try commonmark.parseCommonMark(testing.allocator, input, .{});
    defer document.deinit();

    try testing.expectEqual(input.ptr, document.source.ptr);
    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{});
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("<p>alpha &amp; beta</p>\n", rendered);
}

test "CommonMark safe rendering suppresses raw HTML and dangerous URLs" {
    const input = "<script>alert(1)</script>\n\n[x](javascript:alert(1))";
    var document = try commonmark.parseCommonMark(testing.allocator, input, .{});
    defer document.deinit();

    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{});
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "<script") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, ">x</a>") != null);
}

test "CommonMark limits reject oversized input before allocation" {
    try testing.expectError(
        error.InputTooLarge,
        commonmark.parseCommonMark(testing.allocator, "abc", .{ .max_input_bytes = 2 }),
    );
}

test "CommonMark replacement mode repairs malformed UTF-8" {
    const input = [_]u8{0xff};
    var document = try commonmark.parseCommonMark(testing.allocator, input[0..], .{
        .invalid_utf8 = .replace,
    });
    defer document.deinit();

    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{});
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "\xef\xbf\xbd") != null);
}

test "CommonMark Unicode delimiter classes preserve cross-word flanking" {
    const source = "a*é*b a*中*b a*\u{0301}*b *\u{2003}word* a*♥*b\n";
    var document = try commonmark.parseCommonMark(testing.allocator, source, .{});
    defer document.deinit();

    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{ .mode = .conformance });
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        "<p>a<em>é</em>b a<em>中</em>b a<em>\u{0301}</em>b *\u{2003}word* a*♥*b</p>\n",
        rendered,
    );
}

test "CommonMark propagates allocator failures in link parsing" {
    const source = "[inline](destination \"inline title\") [ref][]\n\n[ref]: /reference \"reference title\"\n";
    var warm = std.testing.FailingAllocator.init(testing.allocator, .{});
    {
        var document = try commonmark.parseCommonMark(warm.allocator(), source, .{});
        document.deinit();
    }
    try testing.expect(warm.alloc_index > 0);

    var fail_index: usize = 0;
    while (fail_index < warm.alloc_index) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        failing.fail_index = fail_index;
        const result = commonmark.parseCommonMark(failing.allocator(), source, .{});
        if (result) |document| {
            var owned = document;
            owned.deinit();
            return error.ExpectedOutOfMemory;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "CommonMark fenced code blocks preserve blank lines and resist blockquote splitting" {
    const input = "```\n<\n >\n```\n";
    var document = try commonmark.parseCommonMark(testing.allocator, input, .{});
    defer document.deinit();
    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{ .mode = .conformance });
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("<pre><code>&lt;\n &gt;\n</code></pre>\n", rendered);
}

test "CommonMark nested lists preserve indentation and container hierarchy" {
    const input = "- foo\n  - bar\n    - baz\n";
    var document = try commonmark.parseCommonMark(testing.allocator, input, .{});
    defer document.deinit();
    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{ .mode = .conformance });
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("<ul>\n<li>foo\n<ul>\n<li>bar\n<ul>\n<li>baz</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n", rendered);
}

test "CommonMark links reject nested links and preserve delimiter boundaries" {
    const input = "[foo [bar](/uri)](/uri)\n";
    var document = try commonmark.parseCommonMark(testing.allocator, input, .{});
    defer document.deinit();
    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{ .mode = .conformance });
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("<p>[foo <a href=\"/uri\">bar</a>](/uri)</p>\n", rendered);
}

test "CommonMark autolinks support URI backslash escapes and percent-encode brackets" {
    const input = "<https://example.com?find=\\*>\n\n[foo<https://example.com/?search=](uri)>\n";
    var document = try commonmark.parseCommonMark(testing.allocator, input, .{});
    defer document.deinit();
    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{ .mode = .conformance });
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        "<p><a href=\"https://example.com?find=%5C*\">https://example.com?find=\\*</a></p>\n<p>[foo<a href=\"https://example.com/?search=%5D(uri)\">https://example.com/?search=](uri)</a></p>\n",
        rendered,
    );
}

test "CommonMark blank line between list items makes list loose" {
    const input = "- one\n\n- two\n";
    var document = try commonmark.parseCommonMark(testing.allocator, input, .{});
    defer document.deinit();
    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{ .mode = .conformance });
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        "<ul>\n<li>\n<p>one</p>\n</li>\n<li>\n<p>two</p>\n</li>\n</ul>\n",
        rendered,
    );
}

test "CommonMark rejects prefix depth beyond bounded container storage" {
    var input: [131]u8 = undefined;
    var index: usize = 0;
    for (0..65) |_| {
        input[index] = '>';
        input[index + 1] = ' ';
        index += 2;
    }
    input[index] = 'x';
    try testing.expectError(
        error.NestingTooDeep,
        commonmark.parseCommonMark(testing.allocator, input[0 .. index + 1], .{}),
    );
}

test "CommonMark preserves fence lengths beyond u8" {
    const fence_len = 300;
    const input_len = fence_len + 1 + 2 + 1 + fence_len + 1;
    const input = try testing.allocator.alloc(u8, input_len);
    defer testing.allocator.free(input);
    @memset(input[0..fence_len], '`');
    input[fence_len] = '\n';
    input[fence_len + 1] = 'x';
    input[fence_len + 2] = '\n';
    @memset(input[fence_len + 3 .. fence_len + 3 + fence_len], '`');
    input[input_len - 1] = '\n';

    var document = try commonmark.parseCommonMark(testing.allocator, input, .{});
    defer document.deinit();
    var iterator = document.nodeChildren(.root);
    const child = iterator.nextChild() orelse return error.InvalidDocument;
    const node = document.node(child) orelse return error.InvalidDocument;
    switch (node.data) {
        .code_block => |code| try testing.expectEqual(@as(usize, fence_len), code.fence_length),
        else => return error.InvalidDocument,
    }
}

test "CommonMark child iteration stops on malformed sibling cycle" {
    var document = try commonmark.parseCommonMark(testing.allocator, "a\nb\n", .{});
    defer document.deinit();
    var root_children = document.nodeChildren(.root);
    const first = root_children.nextChild() orelse return error.InvalidDocument;
    document.nodes[@intFromEnum(first)].next_sibling = first;

    var children = document.nodeChildren(.root);
    var count: usize = 0;
    while (children.nextChild()) |_| count += 1;
    try testing.expect(children.isInvalid());
    try testing.expect(count <= document.nodes.len);
}

test "CommonMark rendering enforces output limits through closing markup" {
    var document = try commonmark.parseCommonMark(testing.allocator, "abc", .{});
    defer document.deinit();
    try testing.expectError(error.OutputTooLarge, commonmark.renderCommonMarkHtml(
        testing.allocator,
        &document,
        .{ .max_output_bytes = 6 },
    ));
}

test "CommonMark rendering rejects cyclic sibling chains before allocation exhaustion" {
    var document = try commonmark.parseCommonMark(testing.allocator, "a", .{});
    defer document.deinit();
    const first = document.nodes[0].first_child;
    document.nodes[@intFromEnum(first)].next_sibling = first;
    var bounded = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    try testing.expectError(error.InvalidDocument, commonmark.renderCommonMarkHtml(
        bounded.allocator(),
        &document,
        .{},
    ));
}

test "CommonMark configured parser resources return explicit limits" {
    const Case = struct {
        source: []const u8,
        options: commonmark.CommonMarkOptions,
        expected: commonmark.ParseError,
    };
    const cases = [_]Case{
        .{ .source = "a", .options = .{ .max_nodes = 1 }, .expected = error.TooManyNodes },
        .{ .source = "a", .options = .{ .max_text_bytes = 0 }, .expected = error.TextTooLarge },
        .{ .source = "[a]: /x\n", .options = .{ .max_reference_count = 0 }, .expected = error.TooManyReferences },
        .{ .source = "*a*", .options = .{ .max_delimiters = 0 }, .expected = error.TooManyDelimiters },
        .{ .source = "[a]", .options = .{ .max_brackets = 0 }, .expected = error.TooManyBrackets },
        .{ .source = "***a***", .options = .{ .max_depth = 1 }, .expected = error.NestingTooDeep },
        .{ .source = "a", .options = .{ .max_work = 0 }, .expected = error.WorkLimit },
    };
    for (cases) |case| {
        try testing.expectError(case.expected, commonmark.parseCommonMark(
            testing.allocator,
            case.source,
            case.options,
        ));
    }
}

test "CommonMark long delimiter runs retain pairing and depth limits" {
    const source = "*" ** 300 ++ "x" ++ "*" ** 300;
    var document = try commonmark.parseCommonMark(testing.allocator, source, .{});
    defer document.deinit();
    const expected = "<p>" ++ "<strong>" ** 150 ++ "x" ++ "</strong>" ** 150 ++ "</p>\n";
    const html = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{
        .mode = .conformance,
        .max_output_bytes = expected.len,
    });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(expected, html);
    try testing.expectError(error.NestingTooDeep, commonmark.parseCommonMark(
        testing.allocator,
        source,
        .{ .max_depth = 100 },
    ));
}

test "CommonMark safe URL checks cover autolinks and browser-stripped controls" {
    const sources = [_][]const u8{
        "<javascript:alert(1)>",
        "[x](java&#x09;script:alert(1))",
        "[x](java&#x0a;script:alert(1))",
        "[x](&#x01;javascript:alert(1))",
    };
    for (sources) |source| {
        var document = try commonmark.parseCommonMark(testing.allocator, source, .{});
        defer document.deinit();
        const safe = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{});
        defer testing.allocator.free(safe);
        try testing.expect(std.mem.indexOf(u8, safe, "href=\"\"") != null);
        const conformance = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{ .mode = .conformance });
        defer testing.allocator.free(conformance);
        try testing.expect(std.mem.indexOf(u8, conformance, "href=\"\"") == null);
    }
}

test "CommonMark wide indentation and marker padding preserve code content" {
    const Case = struct { source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{
            .source = "-" ++ " " ** 256 ++ "x\n",
            .expected = "<ul>\n<li>\n<pre><code>" ++ " " ** 251 ++ "x\n</code></pre>\n</li>\n</ul>\n",
        },
        .{
            .source = "1." ++ " " ** 256 ++ "x\n",
            .expected = "<ol>\n<li>\n<pre><code>" ++ " " ** 251 ++ "x\n</code></pre>\n</li>\n</ol>\n",
        },
        .{
            .source = " " ** 65536 ++ "x\n",
            .expected = "<pre><code>" ++ " " ** 65532 ++ "x\n</code></pre>\n",
        },
    };
    for (cases) |case| {
        var document = try commonmark.parseCommonMark(testing.allocator, case.source, .{});
        defer document.deinit();
        const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{
            .mode = .conformance,
            .max_output_bytes = std.math.maxInt(usize),
        });
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings(case.expected, rendered);
    }
}

test "CommonMark autolinks enforce email grammar and decode URI entities" {
    const Case = struct { source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{
            .source = "<https://example.com/?x=&amp;>",
            .expected = "<p><a href=\"https://example.com/?x=&amp;\">https://example.com/?x=&amp;</a></p>\n",
        },
        .{ .source = "<foo&#58;bar@example.com>", .expected = "<p>&lt;foo:bar@example.com&gt;</p>\n" },
        .{ .source = "<foo@localhost>", .expected = "<p><a href=\"mailto:foo@localhost\">foo@localhost</a></p>\n" },
        .{ .source = "<foo@-example.com>", .expected = "<p>&lt;foo@-example.com&gt;</p>\n" },
        .{ .source = "<foo@example-.com>", .expected = "<p>&lt;foo@example-.com&gt;</p>\n" },
        .{
            .source = "<foo@" ++ "a" ** 64 ++ ".com>",
            .expected = "<p>&lt;foo@" ++ "a" ** 64 ++ ".com&gt;</p>\n",
        },
        .{
            .source = "<" ++ "a" ** 32 ++ ":x>",
            .expected = "<p><a href=\"" ++ "a" ** 32 ++ ":x\">" ++ "a" ** 32 ++ ":x</a></p>\n",
        },
        .{ .source = "<ab:\x01>", .expected = "<p>&lt;ab:\x01&gt;</p>\n" },
    };
    for (cases) |case| {
        var document = try commonmark.parseCommonMark(testing.allocator, case.source, .{});
        defer document.deinit();
        const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{ .mode = .conformance });
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings(case.expected, rendered);
    }
}

test "CommonMark numeric references distinguish lexical limits from invalid scalars" {
    const source = "&#00000065; &#x0000041; &#1114112; &#x110000;";
    var document = try commonmark.parseCommonMark(testing.allocator, source, .{});
    defer document.deinit();
    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{});
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("<p>&amp;#00000065; &amp;#x0000041; \u{fffd} \u{fffd}</p>\n", rendered);
}

test "CommonMark overlong reference candidates remain literal text" {
    const Case = struct { source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .source = "[" ++ "a" ** 1000 ++ "]\n", .expected = "<p>[" ++ "a" ** 1000 ++ "]</p>\n" },
        .{ .source = "[" ++ "a" ** 1000 ++ "]: /target\n", .expected = "<p>[" ++ "a" ** 1000 ++ "]: /target</p>\n" },
    };
    for (cases) |case| {
        var document = try commonmark.parseCommonMark(testing.allocator, case.source, .{ .max_reference_count = 0 });
        defer document.deinit();
        const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{});
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings(case.expected, rendered);
    }
    const label = "é" ** 999;
    var document = try commonmark.parseCommonMark(testing.allocator, "[" ++ label ++ "]: /target\n\n[" ++ label ++ "]\n", .{});
    defer document.deinit();
    const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{});
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("<p><a href=\"/target\">" ++ label ++ "</a></p>\n", rendered);
}

test "CommonMark block literals apply configured source character normalization" {
    const Case = struct { source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .source = "```\n\x00\xff\n```\n", .expected = "<pre><code>\u{fffd}\u{fffd}\n</code></pre>\n" },
        .{ .source = "    \x00\xff\n", .expected = "<pre><code>\u{fffd}\u{fffd}\n</code></pre>\n" },
        .{ .source = "<div>\n\x00\xff\n</div>\n", .expected = "<div>\n\u{fffd}\u{fffd}\n</div>\n" },
    };
    for (cases) |case| {
        var document = try commonmark.parseCommonMark(testing.allocator, case.source, .{ .invalid_utf8 = .replace });
        defer document.deinit();
        const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{ .mode = .conformance });
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings(case.expected, rendered);
    }
}

test "CommonMark renderer rejects malformed root ancestry before sibling traversal" {
    var document = try commonmark.parseCommonMark(testing.allocator, "- a\n", .{});
    defer document.deinit();
    var item: commonmark.NodeId = .none;
    var paragraph: commonmark.NodeId = .none;
    for (document.nodes, 0..) |node, index| {
        if (node.kind == .list_item) item = @enumFromInt(@as(u32, @intCast(index)));
        if (node.kind == .paragraph) paragraph = @enumFromInt(@as(u32, @intCast(index)));
    }
    try testing.expect(item != .none);
    try testing.expect(paragraph != .none);
    document.nodes[0].parent = item;
    document.nodes[@intFromEnum(paragraph)].next_sibling = paragraph;
    try testing.expectError(error.InvalidDocument, commonmark.renderCommonMarkHtml(testing.allocator, &document, .{}));
}
