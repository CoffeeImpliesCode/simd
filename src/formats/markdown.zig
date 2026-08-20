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
    return indexMarkdownImpl(simd.default_vector_len, allocator, input);
}

pub fn indexMarkdownImpl(
    comptime VLEN: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) !MarkdownStructuralIndex {
    const Mask = simd.Mask(VLEN);

    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);
    const kinds = try allocator.alloc(MarkdownTokenKind, input.len);
    errdefer allocator.free(kinds);

    var state = MarkdownScanState{
        .in_code_fence = false,
        .in_inline_code = false,
        .inline_code_length = 0,
        .inline_code_run_remaining = 0,
        .fence_character = 0,
        .fence_length = 0,
        .line_marker_pending = true,
        .indentation = 0,
        .skip_line = false,
    };
    var windows = simd.windows(u8, VLEN, input, 0);
    var chunk_offset: usize = 0;
    var scan_offset: usize = 0;

    while (windows.next()) |vector| : (chunk_offset += VLEN) {
        const remaining = input.len - chunk_offset;
        const valid_length = @min(remaining, VLEN);
        const candidate_mask = markdownCandidateMask(VLEN, vector);
        const valid_mask = markdownValidMask(VLEN, valid_length);
        var candidate_indexes: [VLEN]u32 = undefined;
        const candidate_count = simd.extractBitIndexes(
            Mask,
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
    inline_code_length: usize,
    inline_code_run_remaining: usize,
    fence_character: u8,
    fence_length: usize,
    line_marker_pending: bool,
    indentation: usize,
    skip_line: bool,
};

fn markdownCandidateMask(
    comptime VLEN: usize,
    vector: simd.Vec(VLEN, u8),
) simd.Mask(VLEN) {
    const line_and_blocks = simd.matchAny4(VLEN, vector, '#', '>', '-', '*');
    const lists_and_inline = simd.matchAny4(VLEN, vector, '+', '`', '[', ']');
    const links_and_fences = simd.matchAny4(VLEN, vector, '(', ')', '~', '\n');
    const carriage_returns = simd.matchByte(VLEN, vector, '\r');
    const thematic_underscores = simd.matchByte(VLEN, vector, '_');
    const digits = simd.matchRange(VLEN, vector, '0', '9');
    return line_and_blocks | lists_and_inline | links_and_fences | carriage_returns |
        thematic_underscores | digits;
}

fn markdownValidMask(comptime VLEN: usize, valid_length: usize) simd.Mask(VLEN) {
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);

    assert(valid_length > 0);
    assert(valid_length <= VLEN);
    if (valid_length == VLEN) return ~@as(Mask, 0);
    return (@as(Mask, 1) << @as(Shift, @intCast(valid_length))) - 1;
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

    if (state.inline_code_run_remaining > 0) {
        appendToken(indexes, kinds, offset, .inline_code);
        state.inline_code_run_remaining -= 1;
        return;
    }
    if (state.line_marker_pending and !state.in_inline_code) {
        if (processLineMarker(input, offset, state, indexes, kinds)) return;
    }

    state.line_marker_pending = false;
    if (character == '`') {
        const run_length = scalarRunLength(input, offset, input.len, '`');
        appendToken(indexes, kinds, offset, .inline_code);
        state.inline_code_run_remaining = run_length - 1;
        if (state.in_inline_code) {
            if (run_length == state.inline_code_length) {
                state.in_inline_code = false;
                state.inline_code_length = 0;
            }
        } else {
            state.in_inline_code = true;
            state.inline_code_length = run_length;
        }
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
            state.inline_code_length = 0;
            state.inline_code_run_remaining = 0;
            state.fence_character = character;
            state.fence_length = run_length;
            state.line_marker_pending = false;
            state.skip_line = true;
            return true;
        }
    }

    if ((character == '-' or character == '*' or character == '_') and
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
    var inline_code_length: usize = 0;
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
            if (!in_inline_code and indentation <= 3 and content_start < line_end) {
                const character = input[content_start];
                if (character == '`' or character == '~') {
                    const run_length = scalarRunLength(input, content_start, line_end, character);
                    if (run_length >= 3) {
                        appendToken(&indexes, kinds, content_start, .code_fence);
                        in_code_fence = true;
                        in_inline_code = false;
                        inline_code_length = 0;
                        fence_character = character;
                        fence_length = run_length;
                        is_fence_line = true;
                    }
                }
            }

            if (!is_fence_line) {
                if (!in_inline_code and indentation <= 3 and content_start < line_end) {
                    scalarAppendLineMarker(
                        input,
                        content_start,
                        line_end,
                        &indexes,
                        kinds,
                    );
                }

                var offset = line_start;
                while (offset < line_end) {
                    const character = input[offset];
                    if (character == '`') {
                        const run_length = scalarRunLength(input, offset, line_end, '`');
                        const run_end = offset + run_length;
                        var run_offset = offset;
                        while (run_offset < run_end) : (run_offset += 1) {
                            appendToken(&indexes, kinds, run_offset, .inline_code);
                        }
                        if (in_inline_code) {
                            if (run_length == inline_code_length) {
                                in_inline_code = false;
                                inline_code_length = 0;
                            }
                        } else {
                            in_inline_code = true;
                            inline_code_length = run_length;
                        }
                        offset = run_end;
                    } else {
                        if (!in_inline_code) {
                            switch (character) {
                                '[', '(' => appendToken(&indexes, kinds, offset, .link_open),
                                ']', ')' => appendToken(&indexes, kinds, offset, .link_close),
                                else => {},
                            }
                        }
                        offset += 1;
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
    if ((character == '-' or character == '*' or character == '_') and
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

fn expectIndexInvariants(input: []const u8, index: *const MarkdownStructuralIndex) !void {
    try testing.expect(index.count <= input.len);
    for (index.indexes[0..index.count], 0..) |value, offset| {
        try testing.expect(@as(usize, @intCast(value)) < input.len);
        if (offset > 0) {
            try testing.expect(index.indexes[offset - 1] < value);
        }
    }
}

fn expectMatchesScalarOracle(input: []const u8) !void {
    return expectMatchesScalarOracleAtWidth(simd.default_vector_len, input);
}

fn expectMatchesScalarOracleAtWidth(comptime VLEN: usize, input: []const u8) !void {
    var expected = try scalarIndexMarkdown(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    var actual = try indexMarkdownImpl(VLEN, testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try expectIndexInvariants(input, &expected);
    try expectIndexInvariants(input, &actual);
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

fn expectExactTokens(
    input: []const u8,
    expected_indexes: []const u32,
    expected_kinds: []const MarkdownTokenKind,
) !void {
    var actual = try indexMarkdown(testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try expectIndexInvariants(input, &actual);
    try testing.expectEqualSlices(u32, expected_indexes, actual.indexes[0..actual.count]);
    try testing.expectEqualSlices(
        MarkdownTokenKind,
        expected_kinds,
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

test "Markdown SIMD widths match scalar across structural boundaries" {
    const input =
        "# heading\n" ++
        "> quote\n" ++
        "- item\n" ++
        "* * *\n" ++
        "`code` [link](target)\n" ++
        "```zig\n" ++
        "# hidden\n" ++
        "```\n";
    const input_lengths = [_]usize{
        0,  1,  14, 15, 16, 17, 30, 31,
        32, 33, 62, 63, 64, 65, 66,
    };
    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        for (input_lengths) |input_length| {
            try expectMatchesScalarOracleAtWidth(vlen, input[0..input_length]);
        }
    }

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        var line_input: [67]u8 = @splat('x');
        line_input[vlen - 1] = '\n';
        line_input[vlen] = '#';
        line_input[vlen + 1] = ' ';
        try expectMatchesScalarOracleAtWidth(vlen, line_input[0 .. vlen + 2]);

        var fence_input: [131]u8 = @splat('x');
        const opening_offset = vlen - 1;
        fence_input[opening_offset - 1] = '\n';
        fence_input[opening_offset] = '`';
        fence_input[opening_offset + 1] = '`';
        fence_input[opening_offset + 2] = '`';
        fence_input[opening_offset + 3] = '\n';
        fence_input[opening_offset + 4] = '#';
        fence_input[opening_offset + 6] = '[';
        fence_input[opening_offset + 7] = ']';
        const closing_offset = 2 * vlen - 1;
        fence_input[closing_offset - 1] = '\n';
        fence_input[closing_offset] = '`';
        fence_input[closing_offset + 1] = '`';
        fence_input[closing_offset + 2] = '`';
        fence_input[closing_offset + 3] = '\n';
        try expectMatchesScalarOracleAtWidth(
            vlen,
            fence_input[0 .. closing_offset + 4],
        );

        var inline_input: [131]u8 = @splat('x');
        const inline_open = vlen - 1;
        inline_input[inline_open] = '`';
        inline_input[inline_open + 1] = '`';
        inline_input[inline_open + 3] = '[';
        inline_input[inline_open + 5] = ']';
        const inline_close = 2 * vlen - 1;
        inline_input[inline_close] = '`';
        inline_input[inline_close + 1] = '`';
        inline_input[inline_close + 2] = '\n';
        try expectMatchesScalarOracleAtWidth(
            vlen,
            inline_input[0 .. inline_close + 3],
        );
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

test "Markdown fences accept info strings and suppress fenced candidates" {
    const input =
        "```zig\n# hidden [x](y)\n```\n" ++
        "~~~rust\n## hidden ![img](url)\n~~~\n# visible\n";
    try expectMatchesScalarOracle(input);
    try expectExactTokens(
        input,
        &.{ 0, 23, 27, 57, 61 },
        &.{ .code_fence, .code_fence, .code_fence, .code_fence, .heading },
    );
}

test "Markdown unclosed fences suppress candidates through EOF" {
    const inputs = [_][]const u8{
        "~~~python\n# hidden [x](y)\n",
        "```zig\n# hidden [x](y)",
    };
    for (inputs) |input| {
        try expectMatchesScalarOracle(input);
        try expectExactTokens(input, &.{0}, &.{.code_fence});
    }
}

test "Markdown headings allow at most three leading spaces" {
    const input = "   # one\n  ## two\n    # code\n# root\n";
    try expectMatchesScalarOracle(input);
    try expectExactTokens(input, &.{ 3, 11, 29 }, &.{ .heading, .heading, .heading });
}

test "Markdown thematic breaks accept all markers and spacing" {
    const input = "- - -\n* * *\n_ _ _\n___\n";
    try expectMatchesScalarOracle(input);
    try expectExactTokens(
        input,
        &.{ 0, 6, 12, 18 },
        &.{ .thematic_break, .thematic_break, .thematic_break, .thematic_break },
    );
}

test "Markdown inline code suppresses links inside matching backtick runs" {
    const input = "``code [x](y)``\n# visible\n";
    try expectMatchesScalarOracle(input);
    try expectExactTokens(
        input,
        &.{ 0, 1, 13, 14, 16 },
        &.{ .inline_code, .inline_code, .inline_code, .inline_code, .heading },
    );
}

test "Markdown inline code keeps unmatched backtick runs inside code" {
    const input = "``code ` [x](y)``\n# visible\n";
    try expectMatchesScalarOracle(input);
    try expectExactTokens(
        input,
        &.{ 0, 1, 7, 15, 16, 18 },
        &.{
            .inline_code,
            .inline_code,
            .inline_code,
            .inline_code,
            .inline_code,
            .heading,
        },
    );
}

test "Markdown multiline inline code suppresses line markers" {
    const input = "`# [x]\n`\n# visible\n";
    try expectMatchesScalarOracle(input);
    try expectExactTokens(
        input,
        &.{ 0, 7, 9 },
        &.{ .inline_code, .inline_code, .heading },
    );
}

test "Markdown inline-code run state resets at newline" {
    const input = "``\n```\n# hidden [x](y)\n``\n# visible\n";
    try expectMatchesScalarOracle(input);
}

test "Markdown multiline code spans hide block markers on content lines" {
    const input = "``\n# [x]\n``\n# visible\n";
    try expectMatchesScalarOracle(input);
    try expectExactTokens(
        input,
        &.{ 0, 1, 9, 10, 12 },
        &.{ .inline_code, .inline_code, .inline_code, .inline_code, .heading },
    );
}

test "Markdown inline code takes precedence over fence-like content" {
    const input = "``\n```\n# hidden\n``\n# visible\n";
    try expectMatchesScalarOracle(input);
    try expectExactTokens(
        input,
        &.{ 0, 1, 3, 4, 5, 16, 17, 19 },
        &.{
            .inline_code,
            .inline_code,
            .inline_code,
            .inline_code,
            .inline_code,
            .inline_code,
            .inline_code,
            .heading,
        },
    );
}

test "Markdown nested links, images, and reference links index delimiters" {
    const input = "![alt](url \"title\") [text][ref] [[nested](u)]\n[ref]: /url\n";
    try expectMatchesScalarOracle(input);
    try expectExactTokens(
        input,
        &.{ 1, 5, 6, 18, 20, 25, 26, 30, 32, 33, 40, 41, 43, 44, 46, 50 },
        &.{
            .link_open,
            .link_close,
            .link_open,
            .link_close,
            .link_open,
            .link_close,
            .link_open,
            .link_close,
            .link_open,
            .link_open,
            .link_close,
            .link_open,
            .link_close,
            .link_close,
            .link_open,
            .link_close,
        },
    );
}

test "Markdown fences retain state for every SIMD chunk boundary" {
    const opening_offsets = [_]usize{ 62, 63, 64, 65 };
    for (opening_offsets) |opening_offset| {
        var input: [256]u8 = undefined;
        @memset(input[0..], 'x');
        input[opening_offset - 1] = '\n';
        input[opening_offset] = '`';
        input[opening_offset + 1] = '`';
        input[opening_offset + 2] = '`';
        input[opening_offset + 3] = '\n';
        input[opening_offset + 4] = '#';
        input[opening_offset + 5] = ' ';
        input[opening_offset + 6] = '[';
        input[opening_offset + 7] = ']';
        input[opening_offset + 8] = '\n';

        const closing_offset = 190;
        input[closing_offset - 1] = '\n';
        input[closing_offset] = '`';
        input[closing_offset + 1] = '`';
        input[closing_offset + 2] = '`';
        input[closing_offset + 3] = '\n';

        try expectMatchesScalarOracle(&input);
        try expectExactTokens(
            &input,
            &.{ @intCast(opening_offset), closing_offset },
            &.{ .code_fence, .code_fence },
        );
    }
}

test "Markdown SIMD and scalar parity survives adversarial candidate streams" {
    const alphabet = "#>-*+`[]()~\n\r0123456789_ x";
    var input: [1024]u8 = undefined;
    var seed: u64 = 0x9e3779b97f4a7c15;
    for (&input) |*character| {
        seed ^= seed << 7;
        seed ^= seed >> 9;
        seed ^= seed << 8;
        character.* = alphabet[@intCast(seed % alphabet.len)];
    }

    const lengths = [_]usize{
        0,   1,   2,   3,    61,   62, 63, 64, 65, 66, 127, 128, 129, 190, 191, 192, 193, 255, 256,
        511, 512, 513, 1023, 1024,
    };
    for (lengths) |length| {
        try expectMatchesScalarOracle(input[0..length]);
    }

    var all_bytes: [512]u8 = undefined;
    for (&all_bytes, 0..) |*character, offset| {
        character.* = @truncate(offset);
    }
    const all_byte_lengths = [_]usize{ 0, 1, 63, 64, 65, 127, 128, 255, 256, 511, 512 };
    for (all_byte_lengths) |length| {
        try expectMatchesScalarOracle(all_bytes[0..length]);
    }
}
