const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const assert = std.debug.assert;
const testing = std.testing;

pub const MarkdownTokenKind = enum(u8) {
    heading,
    code_fence,
    list_item,
    blockquote,
    inline_code,
    link_open,
    link_close,
    thematic_break,
};

pub const MarkdownStructuralIndex = struct {
    indexes: []u32,
    kinds: []MarkdownTokenKind,
    count: usize,

    pub fn deinit(self: *MarkdownStructuralIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.indexes);
        allocator.free(self.kinds);
        self.* = undefined;
    }
};

pub fn indexMarkdown(
    allocator: std.mem.Allocator,
    input: []const u8,
) !MarkdownStructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);
    const kinds = try allocator.alloc(MarkdownTokenKind, input.len);
    errdefer allocator.free(kinds);

    var state = MarkdownScanState{
        .in_code_fence = false,
        .in_inline_code = false,
        .fence_character = 0,
        .fence_length = 0,
        .line_marker_pending = true,
        .indentation = 0,
        .skip_line = false,
    };
    var windows = simd.windows(u8, 64, input, 0);
    var chunk_offset: usize = 0;
    var scan_offset: usize = 0;

    while (windows.next()) |vector| : (chunk_offset += 64) {
        const remaining = input.len - chunk_offset;
        const valid_length = @min(remaining, 64);
        const candidate_mask = markdownCandidateMask(vector);
        const valid_mask = markdownValidMask(valid_length);
        var candidate_indexes: [64]u32 = undefined;
        const candidate_count = simd.extractBitIndexes(
            candidate_mask & valid_mask,
            chunk_offset,
            &candidate_indexes,
        );

        for (candidate_indexes[0..candidate_count]) |candidate_index| {
            const offset: usize = @intCast(candidate_index);
            advanceLinePrefix(input, scan_offset, offset, &state);
            processMarkdownCandidate(input, offset, &state, &indexes, kinds);
            scan_offset = offset + 1;
        }
    }

    return .{
        .indexes = indexes.indexes,
        .kinds = kinds,
        .count = indexes.count,
    };
}

const MarkdownScanState = struct {
    in_code_fence: bool,
    in_inline_code: bool,
    fence_character: u8,
    fence_length: usize,
    line_marker_pending: bool,
    indentation: usize,
    skip_line: bool,
};

fn markdownCandidateMask(vector: simd.Vec(64, u8)) u64 {
    const line_and_blocks = simd.matchAny4(64, vector, '#', '>', '-', '*');
    const lists_and_inline = simd.matchAny4(64, vector, '+', '`', '[', ']');
    const links_and_fences = simd.matchAny4(64, vector, '(', ')', '~', '\n');
    const carriage_returns = simd.matchByte(64, vector, '\r');
    const digits = simd.matchRange(64, vector, '0', '9');
    return line_and_blocks | lists_and_inline | links_and_fences | carriage_returns | digits;
}

fn markdownValidMask(valid_length: usize) u64 {
    assert(valid_length > 0);
    assert(valid_length <= 64);
    if (valid_length == 64) return ~@as(u64, 0);
    return (@as(u64, 1) << @as(u6, @intCast(valid_length))) - 1;
}

fn advanceLinePrefix(
    input: []const u8,
    start: usize,
    end: usize,
    state: *MarkdownScanState,
) void {
    assert(start <= end);
    assert(end <= input.len);
    var offset = start;
    while (offset < end) : (offset += 1) {
        if (state.line_marker_pending) {
            if (input[offset] == ' ') {
                state.indentation += 1;
                if (state.indentation > 3) state.line_marker_pending = false;
            } else {
                state.line_marker_pending = false;
            }
        }
    }
}

fn processMarkdownCandidate(
    input: []const u8,
    offset: usize,
    state: *MarkdownScanState,
    indexes: *stage1.StructuralIndex,
    kinds: []MarkdownTokenKind,
) void {
    const character = input[offset];
    if (character == '\r' or character == '\n') {
        state.line_marker_pending = true;
        state.indentation = 0;
        state.skip_line = false;
        return;
    }

    if (state.skip_line) return;

    if (state.in_code_fence) {
        processFenceCandidate(input, offset, state, indexes, kinds);
        return;
    }

    if (state.line_marker_pending) {
        if (processLineMarker(input, offset, state, indexes, kinds)) return;
    }

    state.line_marker_pending = false;
    if (character == '`') {
        appendToken(indexes, kinds, offset, .inline_code);
        state.in_inline_code = !state.in_inline_code;
        return;
    }
    if (state.in_inline_code) return;

    switch (character) {
        '[', '(' => appendToken(indexes, kinds, offset, .link_open),
        ']', ')' => appendToken(indexes, kinds, offset, .link_close),
        else => {},
    }
}

fn processFenceCandidate(
    input: []const u8,
    offset: usize,
    state: *MarkdownScanState,
    indexes: *stage1.StructuralIndex,
    kinds: []MarkdownTokenKind,
) void {
    if (!state.line_marker_pending) return;
    if (input[offset] != state.fence_character) {
        state.line_marker_pending = false;
        return;
    }

    const line_end = scalarLineEnd(input, offset);
    const run_length = scalarRunLength(input, offset, line_end, state.fence_character);
    if (run_length < state.fence_length) {
        state.line_marker_pending = false;
        return;
    }
    if (!scalarOnlyWhitespace(input, offset + run_length, line_end)) {
        state.line_marker_pending = false;
        return;
    }

    appendToken(indexes, kinds, offset, .code_fence);
    state.in_code_fence = false;
    state.fence_character = 0;
    state.fence_length = 0;
    state.line_marker_pending = false;
    state.skip_line = true;
}

fn processLineMarker(
    input: []const u8,
    offset: usize,
    state: *MarkdownScanState,
    indexes: *stage1.StructuralIndex,
    kinds: []MarkdownTokenKind,
) bool {
    const character = input[offset];
    const line_end = scalarLineEnd(input, offset);
    if (character == '`' or character == '~') {
        const run_length = scalarRunLength(input, offset, line_end, character);
        if (run_length >= 3) {
            appendToken(indexes, kinds, offset, .code_fence);
            state.in_code_fence = true;
            state.in_inline_code = false;
            state.fence_character = character;
            state.fence_length = run_length;
            state.line_marker_pending = false;
            state.skip_line = true;
            return true;
        }
    }

    if ((character == '-' or character == '*') and
        scalarIsThematicBreak(input, offset, line_end, character))
    {
        appendToken(indexes, kinds, offset, .thematic_break);
        state.line_marker_pending = false;
        return true;
    }

    switch (character) {
        '#' => appendToken(indexes, kinds, offset, .heading),
        '>' => appendToken(indexes, kinds, offset, .blockquote),
        '-', '*', '+' => appendToken(indexes, kinds, offset, .list_item),
        '0'...'9' => {
            var digit_end = offset;
            while (digit_end < line_end and std.ascii.isDigit(input[digit_end])) {
                digit_end += 1;
            }
            if (digit_end < line_end and input[digit_end] == '.') {
                appendToken(indexes, kinds, offset, .list_item);
            } else {
                state.line_marker_pending = false;
                return false;
            }
        },
        else => return false,
    }
    state.line_marker_pending = false;
    return true;
}

fn scalarIndexMarkdown(
    allocator: std.mem.Allocator,
    input: []const u8,
) !MarkdownStructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);
    const kinds = try allocator.alloc(MarkdownTokenKind, input.len);
    errdefer allocator.free(kinds);

    var in_code_fence = false;
    var in_inline_code = false;
    var fence_character: u8 = 0;
    var fence_length: usize = 0;
    var line_start: usize = 0;

    while (line_start < input.len) {
        const line_end = scalarLineEnd(input, line_start);
        var content_start = line_start;
        while (content_start < line_end and input[content_start] == ' ') {
            content_start += 1;
        }
        const indentation = content_start - line_start;

        if (in_code_fence) {
            if (indentation <= 3 and content_start < line_end and
                input[content_start] == fence_character)
            {
                const run_length = scalarRunLength(input, content_start, line_end, fence_character);
                if (run_length >= fence_length and
                    scalarOnlyWhitespace(input, content_start + run_length, line_end))
                {
                    appendToken(&indexes, kinds, content_start, .code_fence);
                    in_code_fence = false;
                    fence_character = 0;
                    fence_length = 0;
                }
            }
        } else {
            var is_fence_line = false;
            if (indentation <= 3 and content_start < line_end) {
                const character = input[content_start];
                if (character == '`' or character == '~') {
                    const run_length = scalarRunLength(input, content_start, line_end, character);
                    if (run_length >= 3) {
                        appendToken(&indexes, kinds, content_start, .code_fence);
                        in_code_fence = true;
                        in_inline_code = false;
                        fence_character = character;
                        fence_length = run_length;
                        is_fence_line = true;
                    }
                }
            }

            if (!is_fence_line) {
                if (indentation <= 3 and content_start < line_end) {
                    scalarAppendLineMarker(
                        input,
                        content_start,
                        line_end,
                        &indexes,
                        kinds,
                    );
                }

                var offset = line_start;
                while (offset < line_end) : (offset += 1) {
                    const character = input[offset];
                    if (character == '`') {
                        appendToken(&indexes, kinds, offset, .inline_code);
                        in_inline_code = !in_inline_code;
                    } else if (!in_inline_code) {
                        switch (character) {
                            '[', '(' => appendToken(&indexes, kinds, offset, .link_open),
                            ']', ')' => appendToken(&indexes, kinds, offset, .link_close),
                            else => {},
                        }
                    }
                }
            }
        }

        line_start = scalarNextLineStart(input, line_end);
    }

    return .{
        .indexes = indexes.indexes,
        .kinds = kinds,
        .count = indexes.count,
    };
}

fn scalarAppendLineMarker(
    input: []const u8,
    content_start: usize,
    line_end: usize,
    indexes: *stage1.StructuralIndex,
    kinds: []MarkdownTokenKind,
) void {
    const character = input[content_start];
    if ((character == '-' or character == '*') and
        scalarIsThematicBreak(input, content_start, line_end, character))
    {
        appendToken(indexes, kinds, content_start, .thematic_break);
        return;
    }

    switch (character) {
        '#' => appendToken(indexes, kinds, content_start, .heading),
        '>' => appendToken(indexes, kinds, content_start, .blockquote),
        '-', '*', '+' => appendToken(indexes, kinds, content_start, .list_item),
        '0'...'9' => {
            var offset = content_start;
            while (offset < line_end and std.ascii.isDigit(input[offset])) {
                offset += 1;
            }
            if (offset < line_end and input[offset] == '.') {
                appendToken(indexes, kinds, content_start, .list_item);
            }
        },
        else => {},
    }
}

fn scalarIsThematicBreak(
    input: []const u8,
    content_start: usize,
    line_end: usize,
    marker: u8,
) bool {
    var marker_count: usize = 0;
    var offset = content_start;
    while (offset < line_end) : (offset += 1) {
        const character = input[offset];
        if (character == marker) {
            marker_count += 1;
        } else if (character != ' ' and character != '\t') {
            return false;
        }
    }
    return marker_count >= 3;
}

fn scalarRunLength(
    input: []const u8,
    start: usize,
    end: usize,
    character: u8,
) usize {
    var offset = start;
    while (offset < end and input[offset] == character) {
        offset += 1;
    }
    return offset - start;
}

fn scalarOnlyWhitespace(input: []const u8, start: usize, end: usize) bool {
    var offset = start;
    while (offset < end) : (offset += 1) {
        if (input[offset] != ' ' and input[offset] != '\t') return false;
    }
    return true;
}

fn scalarLineEnd(input: []const u8, line_start: usize) usize {
    var offset = line_start;
    while (offset < input.len and input[offset] != '\n' and input[offset] != '\r') {
        offset += 1;
    }
    return offset;
}

fn scalarNextLineStart(input: []const u8, line_end: usize) usize {
    if (line_end == input.len) return input.len;
    if (input[line_end] == '\r' and line_end + 1 < input.len and input[line_end + 1] == '\n') {
        return line_end + 2;
    }
    return line_end + 1;
}

fn appendToken(
    indexes: *stage1.StructuralIndex,
    kinds: []MarkdownTokenKind,
    offset: usize,
    kind: MarkdownTokenKind,
) void {
    assert(indexes.count < indexes.indexes.len);
    assert(indexes.count < kinds.len);
    indexes.indexes[indexes.count] = @intCast(offset);
    kinds[indexes.count] = kind;
    indexes.count += 1;
}

fn expectMatchesScalarOracle(input: []const u8) !void {
    var expected = try scalarIndexMarkdown(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    var actual = try indexMarkdown(testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0..expected.count],
        actual.indexes[0..actual.count],
    );
    try testing.expectEqualSlices(
        MarkdownTokenKind,
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

test "Markdown index identifies basic block and inline tokens" {
    const input = "# H\n`x` [y](z)\n";
    var index = try indexMarkdown(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(
        u32,
        &.{ 0, 4, 6, 8, 10, 11, 13 },
        index.indexes[0..index.count],
    );
    try testing.expectEqualSlices(
        MarkdownTokenKind,
        &.{
            .heading,
            .inline_code,
            .inline_code,
            .link_open,
            .link_close,
            .link_open,
            .link_close,
        },
        index.kinds[0..index.count],
    );
}

test "Markdown SIMD index matches scalar oracle on sample documents" {
    const samples = [_][]const u8{
        "",
        "# Heading\n## Subheading\nplain text\n",
        "> quote\n- item\n* item\n+ item\n12. ordered\n",
        "---\n- - -\n***\n* * *\n- item\n",
        "Text `code` [link](target) and ![image](source).\n",
        "   # indented\r\n   > quote\r\n    # code block indentation\r\n",
        "```zig\n# hidden\n[hidden](target)\n```\n# visible\n",
        "~~~~lang\n* hidden\n~~~\nstill hidden\n~~~~\n> visible\n",
    };

    for (samples) |sample| {
        try expectMatchesScalarOracle(sample);
    }
}

test "Markdown fence and line state cross SIMD window boundaries" {
    var input: [130]u8 = undefined;
    @memset(input[0..], 'x');
    input[60] = '\n';
    input[61] = '`';
    input[62] = '`';
    input[63] = '`';
    input[64] = '\n';
    input[65] = '#';
    input[66] = ' ';
    input[67] = '[';
    input[68] = ']';
    input[69] = '\n';
    input[125] = '\n';
    input[126] = '`';
    input[127] = '`';
    input[128] = '`';
    input[129] = '\n';

    try expectMatchesScalarOracle(&input);

    var index = try indexMarkdown(testing.allocator, &input);
    defer index.deinit(testing.allocator);
    try testing.expectEqualSlices(
        u32,
        &.{ 61, 126 },
        index.indexes[0..index.count],
    );
    try testing.expectEqualSlices(
        MarkdownTokenKind,
        &.{ .code_fence, .code_fence },
        index.kinds[0..index.count],
    );
}
