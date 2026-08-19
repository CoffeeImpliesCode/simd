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

pub fn indexXml(allocator: std.mem.Allocator, input: []const u8) !XmlStructuralIndex {
    const indexes = try allocator.alloc(u32, input.len);
    errdefer allocator.free(indexes);
    const kinds = try allocator.alloc(XmlTokenKind, input.len);
    errdefer allocator.free(kinds);

    var result = XmlStructuralIndex{
        .indexes = indexes,
        .kinds = kinds,
        .count = 0,
    };
    var in_comment = false;
    var in_cdata = false;
    var in_tag = false;
    var in_attr_quote: ?u8 = null;
    var window_iterator = simd.windows(u8, 64, input, 0);
    var base_offset: usize = 0;

    while (window_iterator.next()) |vector| {
        const punctuation_mask = simd.matchAny4(64, vector, '<', '>', '=', '"') |
            simd.matchByte(64, vector, '\'');
        var candidate_indexes: [64]u32 = undefined;
        const candidate_count = simd.extractBitIndexes(
            punctuation_mask,
            base_offset,
            &candidate_indexes,
        );

        for (candidate_indexes[0..candidate_count]) |candidate_index| {
            const input_index: usize = @intCast(candidate_index);
            const byte = input[input_index];

            if (in_comment) {
                if (byte == '>' and input_index >= 2 and input[input_index - 2] == '-' and
                    input[input_index - 1] == '-')
                {
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

        base_offset += 64;
    }

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

fn scalarIndexXml(allocator: std.mem.Allocator, input: []const u8) !XmlStructuralIndex {
    const indexes = try allocator.alloc(u32, input.len);
    errdefer allocator.free(indexes);
    const kinds = try allocator.alloc(XmlTokenKind, input.len);
    errdefer allocator.free(kinds);

    var count: usize = 0;
    var in_comment = false;
    var in_cdata = false;
    var in_tag = false;
    var in_attr_quote: ?u8 = null;
    var input_index: usize = 0;

    while (input_index < input.len) : (input_index += 1) {
        const byte = input[input_index];

        if (in_comment) {
            if (byte == '>' and input_index >= 2 and input[input_index - 2] == '-' and
                input[input_index - 1] == '-')
            {
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

    return .{
        .indexes = indexes,
        .kinds = kinds,
        .count = count,
    };
}

fn expectMatchesScalar(input: []const u8) !void {
    var expected = try scalarIndexXml(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    var actual = try indexXml(testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(u32, expected.indexes[0..expected.count], actual.indexes[0..actual.count]);
    try testing.expectEqualSlices(
        XmlTokenKind,
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
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

test "indexXml matches scalar oracle across SIMD boundaries" {
    const fragments = [_][]const u8{
        "<node a='v'/>",
        "<!-- <ignored/> -->",
        "<![CDATA[<ignored/>]]>",
        "<?target key=\"value\"?>",
    };

    for (fragments) |fragment| {
        for (60..69) |offset| {
            var input: [192]u8 = @splat('x');
            @memcpy(input[offset..][0..fragment.len], fragment);
            try expectMatchesScalar(&input);
        }
    }
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}
