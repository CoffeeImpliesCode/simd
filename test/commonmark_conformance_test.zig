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

        const rendered = commonmark.renderCommonMarkHtml(
            testing.allocator,
            &document,
            .{ .mode = .conformance },
        ) catch |err| {
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
    try testing.expectEqualStrings(
        "<ul>\n<li>foo\n<ul>\n<li>bar\n<ul>\n<li>baz</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n",
        rendered,
    );
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
        "<p><a href=\"https://example.com?find=%5C*\">https://example.com?find=\\*</a></p>\n" ++
            "<p>[foo<a href=\"https://example.com/?search=%5D(uri)\">" ++
            "https://example.com/?search=](uri)</a></p>\n",
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
    document.nodes[@backingInt(first)].next_sibling = first;

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
    document.nodes[@backingInt(first)].next_sibling = first;
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
    const source = @as([300]u8, @splat('*')) ++ "x" ++ @as([300]u8, @splat('*'));
    var document = try commonmark.parseCommonMark(testing.allocator, source, .{});
    defer document.deinit();
    const expected = "<p>" ++
        @as([150 * 8]u8, @bitCast(@as([150][8]u8, @splat("<strong>".*)))) ++ "x" ++
        @as([150 * 9]u8, @bitCast(@as([150][9]u8, @splat("</strong>".*)))) ++ "</p>\n";
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
        const conformance = try commonmark.renderCommonMarkHtml(
            testing.allocator,
            &document,
            .{ .mode = .conformance },
        );
        defer testing.allocator.free(conformance);
        try testing.expect(std.mem.indexOf(u8, conformance, "href=\"\"") == null);
    }
}

test "CommonMark wide indentation and marker padding preserve code content" {
    const Case = struct { source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{
            .source = "-" ++ @as([256]u8, @splat(' ')) ++ "x\n",
            .expected = "<ul>\n<li>\n<pre><code>" ++ @as([251]u8, @splat(' ')) ++ "x\n</code></pre>\n</li>\n</ul>\n",
        },
        .{
            .source = "1." ++ @as([256]u8, @splat(' ')) ++ "x\n",
            .expected = "<ol>\n<li>\n<pre><code>" ++ @as([251]u8, @splat(' ')) ++ "x\n</code></pre>\n</li>\n</ol>\n",
        },
        .{
            .source = @as([65536]u8, @splat(' ')) ++ "x\n",
            .expected = "<pre><code>" ++ @as([65532]u8, @splat(' ')) ++ "x\n</code></pre>\n",
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
            .source = "<foo@" ++ @as([64]u8, @splat('a')) ++ ".com>",
            .expected = "<p>&lt;foo@" ++ @as([64]u8, @splat('a')) ++ ".com&gt;</p>\n",
        },
        .{
            .source = "<" ++ @as([32]u8, @splat('a')) ++ ":x>",
            .expected = "<p><a href=\"" ++ @as([32]u8, @splat('a')) ++
                ":x\">" ++ @as([32]u8, @splat('a')) ++ ":x</a></p>\n",
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
        .{
            .source = "[" ++ @as([1000]u8, @splat('a')) ++ "]\n",
            .expected = "<p>[" ++ @as([1000]u8, @splat('a')) ++ "]</p>\n",
        },
        .{
            .source = "[" ++ @as([1000]u8, @splat('a')) ++ "]: /target\n",
            .expected = "<p>[" ++ @as([1000]u8, @splat('a')) ++ "]: /target</p>\n",
        },
    };
    for (cases) |case| {
        var document = try commonmark.parseCommonMark(testing.allocator, case.source, .{ .max_reference_count = 0 });
        defer document.deinit();
        const rendered = try commonmark.renderCommonMarkHtml(testing.allocator, &document, .{});
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings(case.expected, rendered);
    }
    const label = @as([999 * 2]u8, @bitCast(@as([999][2]u8, @splat("é".*))));
    var document = try commonmark.parseCommonMark(
        testing.allocator,
        "[" ++ label ++ "]: /target\n\n[" ++ label ++ "]\n",
        .{},
    );
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
        if (node.kind == .list_item) item = @fromBackingInt(@intCast(@as(u32, @intCast(index))));
        if (node.kind == .paragraph) paragraph = @fromBackingInt(@intCast(@as(u32, @intCast(index))));
    }
    try testing.expect(item != .none);
    try testing.expect(paragraph != .none);
    document.nodes[0].parent = item;
    document.nodes[@backingInt(paragraph)].next_sibling = paragraph;
    try testing.expectError(error.InvalidDocument, commonmark.renderCommonMarkHtml(testing.allocator, &document, .{}));
}

/// Parser-audit regressions. Every case is a consumer-visible defect confirmed
/// against the published CommonMark 0.31.2 productions, so the expected bytes
/// come from the specification rather than from this parser's current output.
const AuditCase = struct {
    source: []const u8,
    expected: []const u8,
};

fn checkAuditCases(cases: []const AuditCase, mode: commonmark.HtmlRenderMode) !void {
    for (cases) |case| {
        var document = try commonmark.parseCommonMark(testing.allocator, case.source, .{});
        defer document.deinit();
        const rendered = try commonmark.renderCommonMarkHtml(
            testing.allocator,
            &document,
            .{ .mode = mode },
        );
        defer testing.allocator.free(rendered);
        testing.expectEqualStrings(case.expected, rendered) catch |err| {
            std.debug.print(
                "\nsource:   {s}\nexpected: {s}\nactual:   {s}\n",
                .{ case.source, case.expected, rendered },
            );
            return err;
        };
    }
}

test "parser audit: type-1 HTML blocks close on mixed case and alternate end tags" {
    const cases = [_]AuditCase{
        .{
            .source = "<script>\nx\n</ScRiPt>\n\nhello\n",
            .expected = "<script>\nx\n</ScRiPt>\n<p>hello</p>\n",
        },
        .{
            .source = "<pre>\nx\n</PrE>\n\nhello\n",
            .expected = "<pre>\nx\n</PrE>\n<p>hello</p>\n",
        },
        .{
            .source = "<style>\nx\n</StYlE>\n\nhello\n",
            .expected = "<style>\nx\n</StYlE>\n<p>hello</p>\n",
        },
        .{
            .source = "<textarea>\nx\n</TeXtArEa>\n\nhello\n",
            .expected = "<textarea>\nx\n</TeXtArEa>\n<p>hello</p>\n",
        },
        .{
            .source = "<script>\nx\n</style>\n\nhello\n",
            .expected = "<script>\nx\n</style>\n<p>hello</p>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: HTML blocks end on a whitespace-only blank line" {
    const cases = [_]AuditCase{
        .{
            .source = "<div>\n  \nhello\n",
            .expected = "<div>\n<p>hello</p>\n",
        },
        .{
            .source = "<a href=\"x\">\n\t\nhello\n",
            .expected = "<a href=\"x\">\n<p>hello</p>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: safe rendering keeps paragraphs after a raw HTML block" {
    const cases = [_]AuditCase{
        .{
            .source = "<script>\nx\n</ScRiPt>\n\nhello\n",
            .expected = "<!-- raw HTML omitted -->\n<p>hello</p>\n",
        },
        .{
            .source = "<div>\n  \nhello\n",
            .expected = "<!-- raw HTML omitted -->\n<p>hello</p>\n",
        },
        .{
            .source = "<a href=\"x\">\n\t\nhello\n",
            .expected = "<!-- raw HTML omitted -->\n<p>hello</p>\n",
        },
    };
    try checkAuditCases(&cases, .safe);
}

test "parser audit: HTML block start names require the specification delimiter" {
    const cases = [_]AuditCase{
        // `script-x` and `pre-x` are custom tag names, so the type-1 start
        // condition does not apply and the line opens a type-7 block instead.
        .{ .source = "<script-x>\n\nhello\n", .expected = "<script-x>\n<p>hello</p>\n" },
        .{ .source = "<pre-x>\n</pre>\ntext\n", .expected = "<pre-x>\n</pre>\ntext\n" },
        // A custom name is not a block tag and type 7 cannot interrupt a
        // paragraph, so the tag stays inline.
        .{ .source = "foo\n<div-x>\n", .expected = "<p>foo\n<div-x></p>\n" },
        // `/` is not a type-1 delimiter and type 7 excludes `script`, so no
        // HTML block starts here.
        .{ .source = "<script/>\n\nhello\n", .expected = "<p><script/></p>\n<p>hello</p>\n" },
        .{ .source = "<textarea/>\n\nhello\n", .expected = "<p><textarea/></p>\n<p>hello</p>\n" },
        // A space after the special name is a legal type-1 delimiter, and with
        // no end tag the block runs to the end of the document.
        .{ .source = "<script >\nx\n\nhello\n", .expected = "<script >\nx\n\nhello\n" },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: type-6 block tag list matches the specification" {
    const cases = [_]AuditCase{
        .{ .source = "foo\n<frame>\n", .expected = "<p>foo</p>\n<frame>\n" },
        .{ .source = "foo\n<frameset>\n", .expected = "<p>foo</p>\n<frameset>\n" },
        .{ .source = "foo\n<noframes>\n", .expected = "<p>foo</p>\n<noframes>\n" },
        .{ .source = "foo\n<optgroup>\n", .expected = "<p>foo</p>\n<optgroup>\n" },
        .{ .source = "foo\n<option>\n", .expected = "<p>foo</p>\n<option>\n" },
        .{ .source = "foo\n<param>\n", .expected = "<p>foo</p>\n<param>\n" },
        .{ .source = "foo\n<search>\n", .expected = "<p>foo</p>\n<search>\n" },
        // `bgsound` is not a block tag, so it does not interrupt the paragraph.
        .{ .source = "foo\n<bgsound>\n", .expected = "<p>foo\n<bgsound></p>\n" },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: type-7 HTML blocks accept trailing spaces and tabs" {
    const cases = [_]AuditCase{
        .{
            .source = "<a href=\"x\">   \nfoo\n\nbar\n",
            .expected = "<a href=\"x\">   \nfoo\n<p>bar</p>\n",
        },
        .{
            .source = "<a href=\"x\">\t\t\nfoo\n\nbar\n",
            .expected = "<a href=\"x\">\t\t\nfoo\n<p>bar</p>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: HTML declarations need an ASCII letter and end at the first >" {
    const cases = [_]AuditCase{
        .{ .source = "<!1>\n", .expected = "<p>&lt;!1&gt;</p>\n" },
        .{ .source = "a <!1> b\n", .expected = "<p>a &lt;!1&gt; b</p>\n" },
        // A declaration runs to the first `>` and carries no quote rules, so
        // the `"` inside it does not hide the closing angle bracket.
        .{ .source = "a <!A \" > b\n", .expected = "<p>a <!A \" > b</p>\n" },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: inline HTML attribute names use the XML attribute grammar" {
    const cases = [_]AuditCase{
        .{ .source = "a <x 1a=b> z\n", .expected = "<p>a &lt;x 1a=b&gt; z</p>\n" },
        .{ .source = "a <x a.b=c> z\n", .expected = "<p>a <x a.b=c> z</p>\n" },
        .{ .source = "a <x _a:c-d.e=b> z\n", .expected = "<p>a <x _a:c-d.e=b> z</p>\n" },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: unquoted HTML attribute values reject prohibited characters" {
    const cases = [_]AuditCase{
        .{ .source = "a <a href=x=y> z\n", .expected = "<p>a &lt;a href=x=y&gt; z</p>\n" },
        .{ .source = "a <a href=x`y> z\n", .expected = "<p>a &lt;a href=x`y&gt; z</p>\n" },
        .{ .source = "a <x q=b'c'> z\n", .expected = "<p>a &lt;x q=b'c'&gt; z</p>\n" },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: reference labels honour escapes and bracket rules" {
    const cases = [_]AuditCase{
        // `bar[baz` holds an unescaped `[`, so it is not a label; `[foo]`
        // falls back to the shortcut reference.
        .{
            .source = "[foo]: /url\n\n[foo][bar[baz]\n",
            .expected = "<p><a href=\"/url\">foo</a>[bar[baz]</p>\n",
        },
        // The escaped `]` does not close the label, so the full reference wins.
        .{
            .source = "[foo]: /url\n[bar\\]baz]: /url2\n\n[foo][bar\\]baz]\n",
            .expected = "<p><a href=\"/url2\">foo</a></p>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: inline link titles need whitespace after an angle destination" {
    const cases = [_]AuditCase{
        .{ .source = "[a](<b>\"t\")\n", .expected = "<p>[a](<b>&quot;t&quot;)</p>\n" },
        .{ .source = "[a](<b>'t')\n", .expected = "<p>[a](<b>'t')</p>\n" },
        .{ .source = "[a](<b>(t))\n", .expected = "<p>[a](<b>(t))</p>\n" },
        // Separating whitespace still produces the link.
        .{ .source = "[a](<b> \"t\")\n", .expected = "<p><a href=\"b\" title=\"t\">a</a></p>\n" },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: setext underlines are measured inside the container" {
    const cases = [_]AuditCase{
        .{ .source = "> foo\n>  ===\n", .expected = "<blockquote>\n<h1>foo</h1>\n</blockquote>\n" },
        .{ .source = "> foo\n>    ===\n", .expected = "<blockquote>\n<h1>foo</h1>\n</blockquote>\n" },
        .{ .source = "- foo\n   ===\n", .expected = "<ul>\n<li>\n<h1>foo</h1>\n</li>\n</ul>\n" },
        // Four columns is past the three-column limit, so this stays a
        // paragraph rather than becoming a heading.
        .{
            .source = "> foo\n>     ===\n",
            .expected = "<blockquote>\n<p>foo\n===</p>\n</blockquote>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: fenced code indentation inside a container is stripped" {
    const cases = [_]AuditCase{
        .{
            .source = ">   ```\n>   aaa\n>   bbb\n>   ```\n",
            .expected = "<blockquote>\n<pre><code>aaa\nbbb\n</code></pre>\n</blockquote>\n",
        },
        .{
            .source = "> ```\n> aaa\n> ```\n",
            .expected = "<blockquote>\n<pre><code>aaa\n</code></pre>\n</blockquote>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: link destinations percent-encode the full unsafe set" {
    const cases = [_]AuditCase{
        .{ .source = "[a](b^c)\n", .expected = "<p><a href=\"b%5Ec\">a</a></p>\n" },
        .{ .source = "[a](b{c}d)\n", .expected = "<p><a href=\"b%7Bc%7Dd\">a</a></p>\n" },
        .{ .source = "[a](b|c)\n", .expected = "<p><a href=\"b%7Cc\">a</a></p>\n" },
        // The entity decodes to a literal tab, which the renderer must encode.
        .{ .source = "[a](b&#x09;c)\n", .expected = "<p><a href=\"b%09c\">a</a></p>\n" },
        // An already percent-encoded destination is passed through unchanged.
        .{ .source = "[a](foo%20b)\n", .expected = "<p><a href=\"foo%20b\">a</a></p>\n" },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: image alt text retains escaped raw inline HTML" {
    const cases = [_]AuditCase{
        .{
            .source = "![a<b>c](/d)\n",
            .expected = "<p><img src=\"/d\" alt=\"a&lt;b&gt;c\" /></p>\n",
        },
        .{
            .source = "![a<!--x-->b](/d)\n",
            .expected = "<p><img src=\"/d\" alt=\"a&lt;!--x--&gt;b\" /></p>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: code fence info words carry at most one language- prefix" {
    const cases = [_]AuditCase{
        // Both references compare the first info word against `language-` and
        // leave the word alone when it already carries the prefix.
        .{
            .source = "```language-ruby\nx\n```\n",
            .expected = "<pre><code class=\"language-ruby\">x\n</code></pre>\n",
        },
        .{
            .source = "```language-\nx\n```\n",
            .expected = "<pre><code class=\"language-\">x\n</code></pre>\n",
        },
        .{ .source = "```ruby\nx\n```\n", .expected = "<pre><code class=\"language-ruby\">x\n</code></pre>\n" },
        // Only the first word names the language.
        .{
            .source = "```language-ruby extra\nx\n```\n",
            .expected = "<pre><code class=\"language-ruby\">x\n</code></pre>\n",
        },
        .{
            .source = "```foo language-bar\nx\n```\n",
            .expected = "<pre><code class=\"language-foo\">x\n</code></pre>\n",
        },
        // A container does not change which word the prefix is compared against.
        .{
            .source = "> ```language-ruby\n> x\n> ```\n",
            .expected = "<blockquote>\n<pre><code class=\"language-ruby\">x\n</code></pre>\n</blockquote>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: attribute values keep the literal apostrophe" {
    const cases = [_]AuditCase{
        // `houdini_escape_html` runs with `secure = 0` at every cmark call site
        // and commonmark.js `escapeXml` handles only `&`, `<`, `>` and `"`, so
        // an apostrophe reaches the attribute context as the byte it was
        // written as.
        .{ .source = "[a](/b \"it's\")\n", .expected = "<p><a href=\"/b\" title=\"it's\">a</a></p>\n" },
        .{ .source = "![it's](/b)\n", .expected = "<p><img src=\"/b\" alt=\"it's\" /></p>\n" },
        .{ .source = "![a](b \"it's\")\n", .expected = "<p><img src=\"b\" alt=\"a\" title=\"it's\" /></p>\n" },
        .{
            .source = "```it's\nx\n```\n",
            .expected = "<pre><code class=\"language-it's\">x\n</code></pre>\n",
        },
        // Every other byte an attribute must not carry is still escaped.
        .{ .source = "[a](/b 'a\"b')\n", .expected = "<p><a href=\"/b\" title=\"a&quot;b\">a</a></p>\n" },
        .{ .source = "[a](/b \"a&amp;b\")\n", .expected = "<p><a href=\"/b\" title=\"a&amp;b\">a</a></p>\n" },
        .{ .source = "![a<b](/d)\n", .expected = "<p><img src=\"/d\" alt=\"a&lt;b\" /></p>\n" },
        // The text context already carried the byte through unchanged.
        .{ .source = "it's\n", .expected = "<p>it's</p>\n" },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: a list item consumed by a link reference definition renders empty" {
    const cases = [_]AuditCase{
        // The definition leaves the item with no block to render, so both
        // references close the item the way they opened it.
        .{ .source = "- [a]: /u\n- b\n", .expected = "<ul>\n<li></li>\n<li>b</li>\n</ul>\n" },
        .{ .source = "- [a]: /u\n", .expected = "<ul>\n<li></li>\n</ul>\n" },
        // A definition that does not empty the item changes nothing: the block
        // after it still opens on a line of its own.
        .{ .source = "- [a]: /u\n  b\n", .expected = "<ul>\n<li>b</li>\n</ul>\n" },
        .{
            .source = "- [a]: /u\n  > b\n",
            .expected = "<ul>\n<li>\n<blockquote>\n<p>b</p>\n</blockquote>\n</li>\n</ul>\n",
        },
        // A loose list still opens its paragraph on a line of its own.
        .{
            .source = "- [a]: /u\n\n- b\n",
            .expected = "<ul>\n<li></li>\n<li>\n<p>b</p>\n</li>\n</ul>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: HTML blocks end on a blank line of the containing content" {
    const cases = [_]AuditCase{
        // A line holding only a block quote marker carries no content, so it is
        // the blank line that ends a type-6 block.
        .{
            .source = "> <div>\n> foo\n>\n> bar\n",
            .expected = "<blockquote>\n<div>\nfoo\n<p>bar</p>\n</blockquote>\n",
        },
        // The tab is the one space the marker may absorb, so the line is blank
        // for the content of the quote too.
        .{
            .source = "> <div>\n> foo\n>\t\n> bar\n",
            .expected = "<blockquote>\n<div>\nfoo\n<p>bar</p>\n</blockquote>\n",
        },
        // The same holds one quote level down.
        .{
            .source = "> > <div>\n> > foo\n> >\n> > bar\n",
            .expected = "<blockquote>\n<blockquote>\n<div>\nfoo\n<p>bar</p>\n</blockquote>\n</blockquote>\n",
        },
        // Type 7 ends at the same container blank line.
        .{
            .source = "> <a href=\"x\">\n> foo\n>\n> bar\n",
            .expected = "<blockquote>\n<a href=\"x\">\nfoo\n<p>bar</p>\n</blockquote>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: safe rendering keeps the paragraph after a quoted raw HTML block" {
    const cases = [_]AuditCase{
        .{
            .source = "> <div>\n> foo\n>\n> bar\n",
            .expected = "<blockquote>\n<!-- raw HTML omitted -->\n<p>bar</p>\n</blockquote>\n",
        },
        .{
            .source = "> <a href=\"x\">\n> foo\n>\n> bar\n",
            .expected = "<blockquote>\n<!-- raw HTML omitted -->\n<p>bar</p>\n</blockquote>\n",
        },
    };
    try checkAuditCases(&cases, .safe);
}

test "parser audit: the type-6 tag name delimiter accepts a self-closing slash" {
    const cases = [_]AuditCase{
        // The type-6 start condition also accepts the string `/>`, and a type-6
        // block may interrupt a paragraph.
        .{ .source = "foo\n<div/>\n", .expected = "<p>foo</p>\n<div/>\n" },
        .{ .source = "foo\n<hr/>\n", .expected = "<p>foo</p>\n<hr/>\n" },
        .{ .source = "foo\n<link/>\n", .expected = "<p>foo</p>\n<link/>\n" },
        // Only the delimiter changes; the rest of the line stays raw HTML.
        .{
            .source = "<div/>foo\nbar\n\nbaz\n",
            .expected = "<div/>foo\nbar\n<p>baz</p>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
}

test "parser audit: an unterminated reference label falls back to the shortcut" {
    const cases = [_]AuditCase{
        // The label scan reaches the end of the text without a `]`, so there is
        // no full reference and the shortcut reference is retried.
        .{
            .source = "[foo]: /url\n\n[foo][bar",
            .expected = "<p><a href=\"/url\">foo</a>[bar</p>\n",
        },
    };
    try checkAuditCases(&cases, .conformance);
    try checkAuditCases(&cases, .safe);
}
