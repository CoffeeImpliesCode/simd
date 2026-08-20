const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const testing = std.testing;

comptime {
    _ = stage1.StructuralIndex;
}

pub const XmlTokenKind = enum(u8) {
    tag_open,
    tag_close,
    self_close,
    closing_tag_open,
    proc_inst_open,
    proc_inst_close,
    attr_equals,
    attr_quote,
};

pub const XmlStructuralIndex = struct {
    indexes: []u32,
    kinds: []XmlTokenKind,
    count: usize,

    pub fn deinit(self: *XmlStructuralIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.indexes);
        allocator.free(self.kinds);
        self.* = undefined;
    }
};

pub fn indexXml(
    allocator: std.mem.Allocator,
    input: []const u8,
) !XmlStructuralIndex {
    return indexXmlImpl(simd.default_vector_len, allocator, input);
}

pub fn indexXmlImpl(
    comptime VLEN: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) !XmlStructuralIndex {
    const Mask = simd.Mask(VLEN);

    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    var structural_indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer structural_indexes.deinit(allocator);
    const indexes = structural_indexes.indexes;
    const kinds = try allocator.alloc(XmlTokenKind, input.len);
    errdefer allocator.free(kinds);

    var result = XmlStructuralIndex{
        .indexes = indexes,
        .kinds = kinds,
        .count = 0,
    };
    var in_comment = false;
    var comment_start_offset: usize = 0;
    var in_cdata = false;
    var in_tag = false;
    var in_attr_quote: ?u8 = null;
    var base_offset: usize = 0;
    var window_iterator = simd.windows(u8, VLEN, input, 0);

    while (base_offset < input.len) {
        const vector = window_iterator.next().?;
        const punctuation_mask: Mask = simd.matchAny4(VLEN, vector, '<', '>', '=', '"') |
            simd.matchByte(VLEN, vector, '\'');
        var candidate_indexes: [VLEN]u32 = undefined;
        const candidate_count = simd.extractBitIndexes(
            Mask,
            punctuation_mask,
            base_offset,
            &candidate_indexes,
        );

        for (candidate_indexes[0..candidate_count]) |candidate_index| {
            const input_index: usize = @intCast(candidate_index);
            const byte = input[input_index];

            if (in_comment) {
                if (isCommentTerminatorAt(input, input_index, comment_start_offset)) {
                    in_comment = false;
                }
                continue;
            }

            if (in_cdata) {
                if (byte == '>' and input_index >= 2 and input[input_index - 2] == ']' and
                    input[input_index - 1] == ']')
                {
                    in_cdata = false;
                }
                continue;
            }

            if (in_attr_quote) |quote| {
                if (byte == quote) {
                    appendToken(&result, input_index, .attr_quote);
                    in_attr_quote = null;
                }
                continue;
            }

            if (byte == '<') {
                if (startsWithAt(input, input_index, "<!--")) {
                    appendToken(&result, input_index, .tag_open);
                    in_comment = true;
                    comment_start_offset = input_index;
                    in_tag = false;
                    continue;
                }

                if (startsWithAt(input, input_index, "<![CDATA[")) {
                    appendToken(&result, input_index, .tag_open);
                    in_cdata = true;
                    in_tag = false;
                    continue;
                }

                const next_byte = if (input_index + 1 < input.len) input[input_index + 1] else 0;
                const token_kind: XmlTokenKind = switch (next_byte) {
                    '/' => .closing_tag_open,
                    '?' => .proc_inst_open,
                    else => .tag_open,
                };
                appendToken(&result, input_index, token_kind);
                in_tag = true;
                continue;
            }

            if (!in_tag) {
                continue;
            }

            switch (byte) {
                '=' => appendToken(&result, input_index, .attr_equals),
                '"', '\'' => {
                    appendToken(&result, input_index, .attr_quote);
                    in_attr_quote = byte;
                },
                '>' => {
                    if (input_index > 0 and input[input_index - 1] == '/') {
                        appendToken(&result, input_index - 1, .self_close);
                    } else if (input_index > 0 and input[input_index - 1] == '?') {
                        appendToken(&result, input_index - 1, .proc_inst_close);
                    } else {
                        appendToken(&result, input_index, .tag_close);
                    }
                    in_tag = false;
                },
                else => {},
            }
        }

        base_offset += VLEN;
    }

    structural_indexes.count = result.count;
    try structural_indexes.finish(input.len);
    return result;
}

fn appendToken(result: *XmlStructuralIndex, index: usize, kind: XmlTokenKind) void {
    std.debug.assert(result.count < result.indexes.len);
    result.indexes[result.count] = @intCast(index);
    result.kinds[result.count] = kind;
    result.count += 1;
}

fn startsWithAt(input: []const u8, offset: usize, literal: []const u8) bool {
    if (offset > input.len) return false;
    if (input.len - offset < literal.len) return false;
    return std.mem.eql(u8, input[offset..][0..literal.len], literal);
}

fn isCommentTerminatorAt(
    input: []const u8,
    input_index: usize,
    comment_start_offset: usize,
) bool {
    if (input_index < comment_start_offset) return false;
    if (input_index - comment_start_offset < 6) return false;
    if (input[input_index] != '>') return false;
    if (input[input_index - 2] != '-') return false;
    if (input[input_index - 1] != '-') return false;
    return true;
}

fn scalarIndexXml(allocator: std.mem.Allocator, input: []const u8) !XmlStructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    var structural_indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer structural_indexes.deinit(allocator);
    const indexes = structural_indexes.indexes;
    const kinds = try allocator.alloc(XmlTokenKind, input.len);
    errdefer allocator.free(kinds);

    var count: usize = 0;
    var in_comment = false;
    var comment_start_offset: usize = 0;
    var in_cdata = false;
    var in_tag = false;
    var in_attr_quote: ?u8 = null;
    var input_index: usize = 0;

    while (input_index < input.len) : (input_index += 1) {
        const byte = input[input_index];

        if (in_comment) {
            if (isCommentTerminatorAt(input, input_index, comment_start_offset)) {
                in_comment = false;
            }
            continue;
        }

        if (in_cdata) {
            if (byte == '>' and input_index >= 2 and input[input_index - 2] == ']' and
                input[input_index - 1] == ']')
            {
                in_cdata = false;
            }
            continue;
        }

        if (in_attr_quote) |quote| {
            if (byte == quote) {
                indexes[count] = @intCast(input_index);
                kinds[count] = .attr_quote;
                count += 1;
                in_attr_quote = null;
            }
            continue;
        }

        if (byte == '<') {
            indexes[count] = @intCast(input_index);
            count += 1;

            if (std.mem.startsWith(u8, input[input_index..], "<!--")) {
                kinds[count - 1] = .tag_open;
                in_comment = true;
                comment_start_offset = input_index;
                in_tag = false;
            } else if (std.mem.startsWith(u8, input[input_index..], "<![CDATA[")) {
                kinds[count - 1] = .tag_open;
                in_cdata = true;
                in_tag = false;
            } else {
                const next = if (input_index + 1 < input.len) input[input_index + 1] else 0;
                kinds[count - 1] = switch (next) {
                    '/' => .closing_tag_open,
                    '?' => .proc_inst_open,
                    else => .tag_open,
                };
                in_tag = true;
            }
            continue;
        }

        if (!in_tag) continue;

        switch (byte) {
            '"', '\'' => {
                indexes[count] = @intCast(input_index);
                kinds[count] = .attr_quote;
                count += 1;
                in_attr_quote = byte;
            },
            '=' => {
                indexes[count] = @intCast(input_index);
                kinds[count] = .attr_equals;
                count += 1;
            },
            '>' => {
                if (input_index > 0 and input[input_index - 1] == '/') {
                    indexes[count] = @intCast(input_index - 1);
                    kinds[count] = .self_close;
                } else if (input_index > 0 and input[input_index - 1] == '?') {
                    indexes[count] = @intCast(input_index - 1);
                    kinds[count] = .proc_inst_close;
                } else {
                    indexes[count] = @intCast(input_index);
                    kinds[count] = .tag_close;
                }
                count += 1;
                in_tag = false;
            },
            else => {},
        }
    }

    structural_indexes.count = count;
    try structural_indexes.finish(input.len);
    return .{
        .indexes = indexes,
        .kinds = kinds,
        .count = count,
    };
}

fn expectIndexInvariants(index: *const XmlStructuralIndex, input_len: usize) !void {
    var previous_index: ?u32 = null;
    for (index.indexes[0..index.count]) |current_index| {
        try testing.expect(@as(usize, current_index) < input_len);
        if (previous_index) |previous| {
            try testing.expect(previous < current_index);
        }
        previous_index = current_index;
    }
}

fn expectMatchesScalarAtWidth(comptime VLEN: usize, input: []const u8) !void {
    var expected = try scalarIndexXml(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    var actual = try indexXmlImpl(VLEN, testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0..expected.count],
        actual.indexes[0..actual.count],
    );
    try testing.expectEqualSlices(
        XmlTokenKind,
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
    try expectIndexInvariants(&expected, input.len);
    try expectIndexInvariants(&actual, input.len);
}

fn expectMatchesScalar(input: []const u8) !void {
    inline for (.{ 16, 32, 64 }) |VLEN| {
        try expectMatchesScalarAtWidth(VLEN, input);
    }
}

fn expectTokens(
    input: []const u8,
    expected_indexes: []const u32,
    expected_kinds: []const XmlTokenKind,
) !void {
    var actual = try indexXml(testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqual(expected_indexes.len, expected_kinds.len);
    try testing.expectEqual(expected_indexes.len, actual.count);
    try testing.expectEqualSlices(u32, expected_indexes, actual.indexes[0..actual.count]);
    try testing.expectEqualSlices(
        XmlTokenKind,
        expected_kinds,
        actual.kinds[0..actual.count],
    );
    try expectIndexInvariants(&actual, input.len);
}

fn expectFragmentAnchorAtVectorBoundaries(
    comptime VLEN: usize,
    fragment: []const u8,
    anchor_in_fragment: usize,
) !void {
    const boundary_offsets = [_]usize{ VLEN - 2, VLEN - 1, VLEN, VLEN + 1 };
    std.debug.assert(anchor_in_fragment < fragment.len);

    for (boundary_offsets) |boundary_offset| {
        std.debug.assert(anchor_in_fragment <= boundary_offset);
        const fragment_offset = boundary_offset - anchor_in_fragment;
        var input: [160]u8 = @splat('x');
        std.debug.assert(fragment_offset + fragment.len <= input.len);
        @memcpy(input[fragment_offset..][0..fragment.len], fragment);
        try expectMatchesScalarAtWidth(VLEN, &input);
    }
}

test "indexXml identifies tag and attribute structures" {
    const input = "<a x='1'/></a>";
    const expected_indexes = [_]u32{ 0, 4, 5, 7, 8, 10, 13 };
    const expected_kinds = [_]XmlTokenKind{
        .tag_open,
        .attr_equals,
        .attr_quote,
        .attr_quote,
        .self_close,
        .closing_tag_open,
        .tag_close,
    };

    var index = try indexXml(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqual(expected_indexes.len, index.count);
    try testing.expectEqualSlices(u32, &expected_indexes, index.indexes[0..index.count]);
    try testing.expectEqualSlices(XmlTokenKind, &expected_kinds, index.kinds[0..index.count]);
}

test "indexXml matches scalar oracle for XML constructs" {
    const documents = [_][]const u8{
        "",
        "plain text < and > outside valid tags",
        "<?xml version=\"1.0\"?><root id='7'><empty enabled=\"yes\"/></root>",
        "<root><!-- <fake a='>'/> --><![CDATA[<x>=</x>]]><child/></root>",
        "<!DOCTYPE root><root a=\"one > two\" b='three = four'></root>",
        "<!--unclosed <tag>",
        "<![CDATA[unclosed <tag>]]",
    };

    for (documents) |document| {
        try expectMatchesScalar(document);
    }
}

test "indexXml matches scalar oracle across the exact width matrix" {
    const document =
        "<root a='x'><child id=\"1\"/><child><![CDATA[<x>]]></child>" ++
        "<!-- comment --></root>";
    const input_lengths = [_]usize{
        0,  1,  14, 15, 16, 17, 30, 31,
        32, 33, 62, 63, 64, 65, 66,
    };
    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        for (input_lengths) |input_length| {
            try expectMatchesScalarAtWidth(vlen, document[0..input_length]);
        }
    }
}

test "indexXml suppresses CDATA and comment contents" {
    // Only the markup that surrounds each opaque section remains structural.
    const cdata = "<root><![CDATA[ <not-a-tag attr='x'> &amp; ]]><child/></root>";
    const cdata_indexes = [_]u32{ 0, 5, 6, 46, 52, 54, 60 };
    const cdata_kinds = [_]XmlTokenKind{
        .tag_open,
        .tag_close,
        .tag_open,
        .tag_open,
        .self_close,
        .closing_tag_open,
        .tag_close,
    };
    try expectTokens(cdata, &cdata_indexes, &cdata_kinds);

    const comment = "<root><!-- <foo a=\"b\"> &amp; --><child/></root>";
    const comment_indexes = [_]u32{ 0, 5, 6, 32, 38, 40, 46 };
    const comment_kinds = [_]XmlTokenKind{
        .tag_open,
        .tag_close,
        .tag_open,
        .tag_open,
        .self_close,
        .closing_tag_open,
        .tag_close,
    };
    try expectTokens(comment, &comment_indexes, &comment_kinds);
}

test "indexXml does not close comments inside their opener" {
    // The opener's two hyphens are not a comment terminator.
    const input = "<!--><fake/>";
    const expected_indexes = [_]u32{0};
    const expected_kinds = [_]XmlTokenKind{.tag_open};
    try expectTokens(input, &expected_indexes, &expected_kinds);
}

test "indexXml handles quoted attributes and self-closing whitespace" {
    // Attribute punctuation in values is opaque, and both quote styles are structural.
    const input = "<tag first = 'one' second=\"two\"   />";
    const expected_indexes = [_]u32{ 0, 11, 13, 17, 25, 26, 30, 34 };
    const expected_kinds = [_]XmlTokenKind{
        .tag_open,
        .attr_equals,
        .attr_quote,
        .attr_quote,
        .attr_equals,
        .attr_quote,
        .attr_quote,
        .self_close,
    };
    try expectTokens(input, &expected_indexes, &expected_kinds);

    const compact = "<tag/>";
    const compact_indexes = [_]u32{ 0, 4 };
    const compact_kinds = [_]XmlTokenKind{ .tag_open, .self_close };
    try expectTokens(compact, &compact_indexes, &compact_kinds);
}

test "indexXml handles processing instructions and entities" {
    // Entity references never create structural indexes inside or outside attributes.
    const instruction = "<?xml version=\"1.0\" encoding = 'UTF-8'?>";
    const instruction_indexes = [_]u32{ 0, 13, 14, 18, 29, 31, 37, 38 };
    const instruction_kinds = [_]XmlTokenKind{
        .proc_inst_open,
        .attr_equals,
        .attr_quote,
        .attr_quote,
        .attr_equals,
        .attr_quote,
        .attr_quote,
        .proc_inst_close,
    };
    try expectTokens(instruction, &instruction_indexes, &instruction_kinds);

    const entities = "&amp;<tag value='&amp;' other=\"x&amp;y\">&amp;</tag>";
    const entity_indexes = [_]u32{ 5, 15, 16, 22, 29, 30, 38, 39, 45, 50 };
    const entity_kinds = [_]XmlTokenKind{
        .tag_open,
        .attr_equals,
        .attr_quote,
        .attr_quote,
        .attr_equals,
        .attr_quote,
        .attr_quote,
        .tag_close,
        .closing_tag_open,
        .tag_close,
    };
    try expectTokens(entities, &entity_indexes, &entity_kinds);
}

test "indexXml tolerates unclosed and malformed fragments" {
    // EOF leaves incomplete state suppressed without adding a synthetic closing index.
    const unclosed_quote = "<root a='unterminated > <fake/> &amp;";
    const quote_indexes = [_]u32{ 0, 7, 8 };
    const quote_kinds = [_]XmlTokenKind{ .tag_open, .attr_equals, .attr_quote };
    try expectTokens(unclosed_quote, &quote_indexes, &quote_kinds);

    const unclosed_tag = "<root><child";
    const tag_indexes = [_]u32{ 0, 5, 6 };
    const tag_kinds = [_]XmlTokenKind{ .tag_open, .tag_close, .tag_open };
    try expectTokens(unclosed_tag, &tag_indexes, &tag_kinds);

    const malformed_sections = [_][]const u8{
        "<!-- <fake/>",
        "<![CDATA[ <fake/>",
        "<?xml version='1.0'",
        "<tag a = \"mismatched'",
        "<",
        "</",
        "<?",
    };
    for (malformed_sections) |fragment| {
        try expectMatchesScalar(fragment);
    }
}

test "indexXml matches scalar oracle at every vector width boundary" {
    // Each XML construct crosses offsets adjacent to 16-, 32-, and 64-byte windows.
    inline for (.{ 16, 32, 64 }) |VLEN| {
        const comment = "<!-- <foo a='x'> -->";
        try expectFragmentAnchorAtVectorBoundaries(VLEN, comment, 0);
        try expectFragmentAnchorAtVectorBoundaries(VLEN, comment, comment.len - 3);

        const malformed_comment = "<!--><fake/>";
        for ([_]usize{ VLEN - 2, VLEN - 1, VLEN, VLEN + 1 }) |comment_offset| {
            var input: [160]u8 = @splat('x');
            @memcpy(input[comment_offset..][0..malformed_comment.len], malformed_comment);
            try expectMatchesScalarAtWidth(VLEN, &input);
        }

        const cdata = "<![CDATA[ <not-a-tag> ]]>";
        try expectFragmentAnchorAtVectorBoundaries(VLEN, cdata, 0);
        try expectFragmentAnchorAtVectorBoundaries(VLEN, cdata, cdata.len - 3);

        const attributes = "<tag first = 'one' second=\"two\"   />";
        try expectFragmentAnchorAtVectorBoundaries(VLEN, attributes, 11);
        try expectFragmentAnchorAtVectorBoundaries(VLEN, attributes, 13);
        try expectFragmentAnchorAtVectorBoundaries(VLEN, attributes, attributes.len - 2);

        const tags = "<root><child a='x'/></root>";
        try expectFragmentAnchorAtVectorBoundaries(VLEN, tags, 0);
        try expectFragmentAnchorAtVectorBoundaries(VLEN, tags, 6);
        try expectFragmentAnchorAtVectorBoundaries(VLEN, tags, tags.len - 7);

        const instruction = "<?xml version=\"1.0\" encoding = 'UTF-8'?>";
        try expectFragmentAnchorAtVectorBoundaries(VLEN, instruction, 0);
        try expectFragmentAnchorAtVectorBoundaries(VLEN, instruction, instruction.len - 2);
    }
}

test "indexXml preserves invariants for adversarial bytes and tails" {
    // Deterministic high-entropy bytes exercise every tail length across two SIMD chunks.
    var input: [130]u8 = undefined;
    for (&input, 0..) |*byte, index| {
        byte.* = @truncate(index *% 131 +% index *% index *% 17 +% 37);
    }
    for (0..input.len + 1) |input_len| {
        try expectMatchesScalar(input[0..input_len]);
    }
}

test "indexXml rejects inputs whose indexes cannot fit u32" {
    const oversized_len = @as(usize, std.math.maxInt(u32)) + 1;
    const oversized_input: []const u8 =
        @as([*]const u8, @ptrFromInt(1))[0..oversized_len];
    try testing.expectError(
        error.InputTooLarge,
        indexXml(testing.allocator, oversized_input),
    );
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}
