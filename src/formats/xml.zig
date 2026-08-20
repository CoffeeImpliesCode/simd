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

const XmlMarkupCandidateKind = enum {
    unknown,
    comment,
    cdata,
};

const XmlMarkupCandidate = struct {
    token_index: usize,
    start_offset: usize,
    prefix_len: u8,
    kind: XmlMarkupCandidateKind,
};

/// Incrementally builds the same XML structural index as indexXml.
///
/// The indexer copies no caller bytes. It retains only lexical state for an
/// unfinished markup opener, so every offset remains relative to the document
/// assembled by feed.
pub const XmlStreamIndexer = struct {
    allocator: std.mem.Allocator,
    index: ?stage1.StructuralIndex = null,
    kinds: ?[]XmlTokenKind = null,
    input_len: usize = 0,
    previous_byte: u8 = 0,
    in_comment: bool = false,
    comment_start_offset: usize = 0,
    comment_previous_previous: u8 = 0,
    comment_previous: u8 = 0,
    in_cdata: bool = false,
    cdata_previous_previous: u8 = 0,
    cdata_previous: u8 = 0,
    in_tag: bool = false,
    in_attr_quote: ?u8 = null,
    candidate: ?XmlMarkupCandidate = null,
    finished: bool = false,

    const Self = @This();
    const initial_output_capacity: usize = 1;

    pub const InitError = stage1.StructuralIndex.InitError;
    pub const FeedError = std.mem.Allocator.Error || error{
        AlreadyFinished,
        CapacityOverflow,
        InputTooLarge,
    };
    pub const FinishError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };
    const CapacityError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };

    /// Allocates structural storage with chunk_len as its initial capacity.
    pub fn init(allocator: std.mem.Allocator, chunk_len: usize) InitError!Self {
        const output_capacity = @max(chunk_len, initial_output_capacity);
        var index = try stage1.StructuralIndex.init(allocator, output_capacity);
        errdefer index.deinit(allocator);
        const kinds = try allocator.alloc(XmlTokenKind, output_capacity);

        return .{
            .allocator = allocator,
            .index = index,
            .kinds = kinds,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.index) |*index| {
            index.deinit(self.allocator);
        }
        if (self.kinds) |kinds| {
            self.allocator.free(kinds);
        }
        self.* = undefined;
    }

    /// Adds a caller-owned chunk without retaining a reference to that chunk.
    pub fn feed(self: *Self, data: []const u8) FeedError!void {
        if (self.finished) return error.AlreadyFinished;

        const new_input_len = std.math.add(usize, self.input_len, data.len) catch {
            return error.CapacityOverflow;
        };
        if (new_input_len > std.math.maxInt(u32)) return error.InputTooLarge;

        try self.ensureOutputCapacity(data.len);

        const chunk_start_offset = self.input_len;
        self.input_len = new_input_len;
        for (data, 0..) |byte, chunk_offset| {
            self.processByte(byte, chunk_start_offset + chunk_offset);
        }
    }

    /// Finalizes the index and flushes all pending lexical state at EOF.
    pub fn finish(self: *Self) FinishError!void {
        if (self.finished) return;

        // A partial opener has already emitted its '<' token. Its remaining
        // bytes are non-structural at EOF, so no synthetic token is needed.
        self.candidate = null;
        try self.ensureOutputCapacity(0);
        if (self.index) |*index| {
            try index.finish(self.input_len);
        } else {
            unreachable;
        }
        self.finished = true;
    }

    /// Transfers the finalized structural index to the caller.
    pub fn take(self: *Self) XmlStructuralIndex {
        std.debug.assert(self.finished);
        std.debug.assert(self.index != null);
        std.debug.assert(self.kinds != null);

        const index = self.index.?;
        const kinds = self.kinds.?;
        self.index = null;
        self.kinds = null;
        return .{
            .indexes = index.indexes,
            .kinds = kinds,
            .count = index.count,
        };
    }

    /// Starts a new document while retaining the current allocation capacity.
    pub fn reset(self: *Self) void {
        if (self.index) |*index| {
            index.count = 0;
        }
        self.input_len = 0;
        self.in_comment = false;
        self.comment_start_offset = 0;
        self.previous_byte = 0;
        self.comment_previous_previous = 0;
        self.comment_previous = 0;
        self.in_cdata = false;
        self.cdata_previous_previous = 0;
        self.cdata_previous = 0;
        self.in_tag = false;
        self.in_attr_quote = null;
        self.candidate = null;
        self.finished = false;
    }

    fn ensureOutputCapacity(self: *Self, additional: usize) CapacityError!void {
        if (self.index == null) {
            std.debug.assert(self.kinds == null);
            const output_capacity = @max(additional, initial_output_capacity);
            var index = try stage1.StructuralIndex.init(
                self.allocator,
                output_capacity,
            );
            errdefer index.deinit(self.allocator);
            const kinds = try self.allocator.alloc(XmlTokenKind, output_capacity);
            self.index = index;
            self.kinds = kinds;
            return;
        }

        const index = &self.index.?;
        const kinds = self.kinds orelse unreachable;
        const required = std.math.add(usize, index.count, additional) catch {
            return error.CapacityOverflow;
        };
        if (required <= index.indexes.len - 3 and required <= kinds.len) return;

        const doubled_capacity = std.math.mul(usize, kinds.len, 2) catch required;
        const new_capacity = @max(
            required,
            @max(doubled_capacity, initial_output_capacity),
        );
        const new_index_len = std.math.add(usize, new_capacity, 3) catch {
            return error.CapacityOverflow;
        };
        index.indexes = try self.allocator.realloc(index.indexes, new_index_len);
        self.kinds = try self.allocator.realloc(kinds, new_capacity);
    }

    fn processByte(self: *Self, byte: u8, offset: usize) void {
        if (self.in_comment) {
            self.processCommentByte(byte, offset);
            self.previous_byte = byte;
            return;
        }

        if (self.in_cdata) {
            self.processCdataByte(byte);
            self.previous_byte = byte;
            return;
        }

        if (self.in_attr_quote) |quote| {
            if (byte == quote) {
                self.appendToken(offset, .attr_quote);
                self.in_attr_quote = null;
            }
            self.previous_byte = byte;
            return;
        }

        if (self.candidate != null) {
            if (self.advanceCandidate(byte)) {
                self.previous_byte = byte;
                return;
            }
        }

        self.processResolvedByte(byte, offset);
        self.previous_byte = byte;
    }

    fn processCommentByte(self: *Self, byte: u8, offset: usize) void {
        if (byte == '>' and offset >= self.comment_start_offset and
            offset - self.comment_start_offset >= 6 and
            self.comment_previous_previous == '-' and self.comment_previous == '-')
        {
            self.in_comment = false;
        }
        self.comment_previous_previous = self.comment_previous;
        self.comment_previous = byte;
    }

    fn processCdataByte(self: *Self, byte: u8) void {
        if (byte == '>' and self.cdata_previous_previous == ']' and
            self.cdata_previous == ']')
        {
            self.in_cdata = false;
        }
        self.cdata_previous_previous = self.cdata_previous;
        self.cdata_previous = byte;
    }

    fn processResolvedByte(self: *Self, byte: u8, offset: usize) void {
        if (byte == '<') {
            self.appendToken(offset, .tag_open);
            self.in_tag = true;
            const structural_index = self.index orelse unreachable;
            self.candidate = .{
                .token_index = structural_index.count - 1,
                .start_offset = offset,
                .prefix_len = 1,
                .kind = .unknown,
            };
            return;
        }

        if (!self.in_tag) return;

        switch (byte) {
            '=' => self.appendToken(offset, .attr_equals),
            '"', '\'' => {
                self.appendToken(offset, .attr_quote);
                self.in_attr_quote = byte;
            },
            '>' => {
                if (self.previous_byte == '/') {
                    self.appendToken(offset - 1, .self_close);
                } else if (self.previous_byte == '?') {
                    self.appendToken(offset - 1, .proc_inst_close);
                } else {
                    self.appendToken(offset, .tag_close);
                }
                self.in_tag = false;
            },
            else => {},
        }
    }

    fn advanceCandidate(self: *Self, byte: u8) bool {
        var candidate = self.candidate orelse return false;

        if (candidate.prefix_len == 1) {
            switch (byte) {
                '/' => {
                    const kinds = self.kinds orelse unreachable;
                    kinds[candidate.token_index] = .closing_tag_open;
                    self.candidate = null;
                    return true;
                },
                '?' => {
                    const kinds = self.kinds orelse unreachable;
                    kinds[candidate.token_index] = .proc_inst_open;
                    self.candidate = null;
                    return true;
                },
                '!' => {
                    candidate.prefix_len = 2;
                    self.candidate = candidate;
                    return true;
                },
                else => {
                    self.candidate = null;
                    return false;
                },
            }
        }

        if (candidate.prefix_len == 2) {
            if (byte == '-') {
                candidate.kind = .comment;
                candidate.prefix_len = 3;
                self.candidate = candidate;
                return true;
            }
            if (byte == '[') {
                candidate.kind = .cdata;
                candidate.prefix_len = 3;
                self.candidate = candidate;
                return true;
            }
            self.candidate = null;
            return false;
        }

        const literal: []const u8 = switch (candidate.kind) {
            .comment => "<!--",
            .cdata => "<![CDATA[",
            .unknown => unreachable,
        };
        const literal_len: u8 = @intCast(literal.len);
        const prefix_index: usize = @intCast(candidate.prefix_len);
        if (byte != literal[prefix_index]) {
            self.candidate = null;
            return false;
        }
        candidate.prefix_len += 1;
        if (candidate.prefix_len == literal_len) {
            switch (candidate.kind) {
                .comment => {
                    self.in_comment = true;
                    self.comment_start_offset = candidate.start_offset;
                    self.comment_previous_previous = '-';
                    self.comment_previous = '-';
                    self.in_tag = false;
                },
                .cdata => {
                    self.in_cdata = true;
                    self.cdata_previous_previous = 'A';
                    self.cdata_previous = '[';
                    self.in_tag = false;
                },
                .unknown => unreachable,
            }
            self.candidate = null;
        } else {
            self.candidate = candidate;
        }
        return true;
    }

    fn appendToken(self: *Self, index: usize, kind: XmlTokenKind) void {
        const structural_index = if (self.index) |*value| value else unreachable;
        const kinds = self.kinds orelse unreachable;
        std.debug.assert(structural_index.count < structural_index.indexes.len - 3);
        std.debug.assert(structural_index.count < kinds.len);
        structural_index.indexes[structural_index.count] = @intCast(index);
        kinds[structural_index.count] = kind;
        structural_index.count += 1;
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

fn expectStreamMatchesIndex(input: []const u8) !void {
    var expected = try indexXml(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    for (0..input.len + 1) |split| {
        var stream = try XmlStreamIndexer.init(testing.allocator, 1);
        defer stream.deinit();

        try stream.feed(input[0..split]);
        try stream.feed("");
        try stream.feed(input[split..]);
        try stream.finish();
        try stream.finish();

        var actual = stream.take();
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
        try testing.expectEqualSlices(
            u32,
            expected.indexes[expected.count..][0..3],
            actual.indexes[actual.count..][0..3],
        );
        try expectIndexInvariants(&actual, input.len);
    }

    var byte_stream = try XmlStreamIndexer.init(testing.allocator, 1);
    defer byte_stream.deinit();
    for (input) |byte| {
        try byte_stream.feed(&.{byte});
    }
    try byte_stream.finish();

    var byte_actual = byte_stream.take();
    defer byte_actual.deinit(testing.allocator);
    try testing.expectEqual(expected.count, byte_actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0..expected.count],
        byte_actual.indexes[0..byte_actual.count],
    );
    try testing.expectEqualSlices(
        XmlTokenKind,
        expected.kinds[0..expected.count],
        byte_actual.kinds[0..byte_actual.count],
    );
    try testing.expectEqualSlices(
        u32,
        expected.indexes[expected.count..][0..3],
        byte_actual.indexes[byte_actual.count..][0..3],
    );
    try expectIndexInvariants(&byte_actual, input.len);
}

fn expectStreamMatchesDocuments(documents: []const []const u8) !void {
    for (documents) |document| {
        try expectStreamMatchesIndex(document);
    }
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

test "XML stream matches indexXml across every partition and byte feed" {
    const documents = [_][]const u8{
        "",
        "<",
        "</",
        "<?",
        "<!",
        "<!--",
        "<![CDATA[",
        "<!-->",
        "<!---->",
        "<![CDATA[>",
        "<![CDATA[]]>",
        "</>",
        "<tag?>",
        "<?xml version=\"1.0\" encoding = 'UTF-8'?>",
        "<root first = 'one > two' second=\"three = four\"/>",
        "<root><!-- <fake a='>'/> --><![CDATA[<x>=</x>]]><child/></root>",
        "<!-- <fake a='>'/> -->",
        "<![CDATA[<fake a='>'/>]]>",
        "<tag a = \"unterminated > <fake/>",
        "<!--unclosed <tag>",
        "<![CDATA[unclosed <tag>]]",
    };
    try expectStreamMatchesDocuments(documents[0..]);
}

test "XML stream finish flushes pending state and reset starts at zero" {
    var stream = try XmlStreamIndexer.init(testing.allocator, 2);
    defer stream.deinit();

    try stream.feed("<![CDATA[");
    try stream.finish();
    var first = stream.take();

    stream.reset();
    try stream.feed("<?xml");
    try stream.finish();
    var second = stream.take();
    stream.reset();
    try stream.finish();
    var third = stream.take();

    defer first.deinit(testing.allocator);
    defer second.deinit(testing.allocator);

    defer third.deinit(testing.allocator);
    var expected_first = try indexXml(testing.allocator, "<![CDATA[");
    defer expected_first.deinit(testing.allocator);
    var expected_second = try indexXml(testing.allocator, "<?xml");
    defer expected_second.deinit(testing.allocator);

    try testing.expectEqualSlices(
        u32,
        expected_first.indexes[0..expected_first.count],
        first.indexes[0..first.count],
    );
    try testing.expectEqualSlices(
        XmlTokenKind,
        expected_first.kinds[0..expected_first.count],
        first.kinds[0..first.count],
    );
    try testing.expectEqualSlices(
        u32,
        expected_second.indexes[0..expected_second.count],
        second.indexes[0..second.count],
    );
    try testing.expectEqualSlices(
        XmlTokenKind,
        expected_second.kinds[0..expected_second.count],
        second.kinds[0..second.count],
    );
    try testing.expectEqual(@as(usize, 0), third.count);
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

pub const xml_max_depth: usize = 1024;

pub const XmlError = error{
    InvalidUtf8,
    InvalidCharacter,
    InvalidName,
    InvalidAttribute,
    DuplicateAttribute,
    InvalidEntity,
    UnexpectedToken,
    EmptyDocument,
    RootNotSingular,
    MismatchedTag,
    UnclosedElement,
    UnterminatedElement,
    DepthExceeded,
    UnterminatedComment,
    InvalidComment,
    UnterminatedCdata,
    UnterminatedProcessingInstruction,
    UnsupportedDeclaration,
    InvalidDeclaration,
    TapeTooLarge,
    TapeOutOfBounds,
    SourceOutOfBounds,
    InvalidTapeKind,
};

pub const XmlBuildError = std.mem.Allocator.Error || XmlError;
pub const XmlValidationError = std.mem.Allocator.Error || XmlError;

pub const XmlTapeKind = enum(u8) {
    xml_declaration,
    element_start,
    element_end,
    self_closing_element,
    attribute,
    text,
    cdata,
    comment,
    processing_instruction,
};

pub const XmlTapeWord = packed struct(u64) {
    kind: u8,
    payload: u24,
    offset: u32,

    pub fn tapeKind(self: XmlTapeWord) XmlTapeKind {
        return @enumFromInt(self.kind);
    }

    pub fn sourceLength(self: XmlTapeWord) usize {
        return @intCast(self.payload);
    }
};
fn checkedXmlTapeKind(word: XmlTapeWord) XmlError!XmlTapeKind {
    return switch (word.kind) {
        @intFromEnum(XmlTapeKind.xml_declaration) => .xml_declaration,
        @intFromEnum(XmlTapeKind.element_start) => .element_start,
        @intFromEnum(XmlTapeKind.element_end) => .element_end,
        @intFromEnum(XmlTapeKind.self_closing_element) => .self_closing_element,
        @intFromEnum(XmlTapeKind.attribute) => .attribute,
        @intFromEnum(XmlTapeKind.text) => .text,
        @intFromEnum(XmlTapeKind.cdata) => .cdata,
        @intFromEnum(XmlTapeKind.comment) => .comment,
        @intFromEnum(XmlTapeKind.processing_instruction) => .processing_instruction,
        else => error.InvalidTapeKind,
    };
}

comptime {
    std.debug.assert(@bitSizeOf(XmlTapeWord) == 64);
    std.debug.assert(@sizeOf(XmlTapeWord) == 8);
}

pub const XmlDiagnostic = struct {
    err: XmlError,
    byte_offset: usize,
    line: u32,
    column: u32,
    snippet: []const u8,
    snippet_start: usize,
};

pub const XmlDocument = struct {
    tape: []XmlTapeWord,

    pub fn deinit(self: *XmlDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.tape);
        self.* = undefined;
    }

    pub fn word(self: *const XmlDocument, tape_index: usize) XmlError!XmlTapeWord {
        if (tape_index >= self.tape.len) return error.TapeOutOfBounds;
        return self.tape[tape_index];
    }

    pub fn sourceSpan(
        self: *const XmlDocument,
        input: []const u8,
        tape_index: usize,
    ) XmlError![]const u8 {
        const word_value = try self.word(tape_index);
        _ = try checkedXmlTapeKind(word_value);
        const source_offset: usize = @intCast(word_value.offset);
        const source_length = word_value.sourceLength();
        if (source_offset > input.len) return error.SourceOutOfBounds;
        if (source_length > input.len - source_offset) return error.SourceOutOfBounds;
        return input[source_offset .. source_offset + source_length];
    }
};

pub fn buildXmlTape(
    allocator: std.mem.Allocator,
    input: []const u8,
) XmlBuildError!XmlDocument {
    if (input.len > std.math.maxInt(u32)) return error.TapeTooLarge;

    var tape = try std.ArrayList(XmlTapeWord).initCapacity(
        allocator,
        @min(input.len, 64),
    );
    errdefer tape.deinit(allocator);

    // Every frame is written before stack_top exposes it. Keep the backing storage
    // uninitialized to avoid clearing the fixed stack for each parse.
    var stack: [xml_max_depth]XmlFrame = undefined;
    var output = XmlTapeOutput{
        .allocator = allocator,
        .tape = &tape,
    };

    var parser = XmlParser{
        .input = input,
        .output = &output,
        .stack = stack[0..],
    };
    try parser.run();
    return .{ .tape = try tape.toOwnedSlice(allocator) };
}

pub fn validateXml(input: []const u8) XmlValidationError!?XmlDiagnostic {
    if (input.len > std.math.maxInt(u32)) return error.TapeTooLarge;

    // Every frame is written before stack_top exposes it. Keep the backing storage
    // uninitialized to avoid clearing the fixed stack for each parse.
    var stack: [xml_max_depth]XmlFrame = undefined;

    var parser = XmlParser{
        .input = input,
        .output = null,
        .stack = stack[0..],
    };
    parser.run() catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.TapeTooLarge) return error.TapeTooLarge;
        return diagnosticAtXml(input, @errorCast(err), parser.failure_offset);
    };
    return null;
}

fn diagnosticAtXml(input: []const u8, err: XmlError, byte_offset: usize) XmlDiagnostic {
    const offset = @min(byte_offset, input.len);
    var line_start: usize = 0;
    var line_count: usize = 1;
    for (input[0..offset], 0..) |byte, index| {
        if (byte == '\n') {
            line_start = index + 1;
            line_count += 1;
        }
    }

    var line_end = offset;
    while (line_end < input.len and input[line_end] != '\n') : (line_end += 1) {}
    const snippet_start = @max(line_start, offset -| 16);
    const snippet_limit = std.math.add(usize, offset, 16) catch input.len;
    const snippet_end = @min(line_end, snippet_limit);
    const line_max: usize = std.math.maxInt(u32);
    const column_count = offset - line_start + 1;
    return .{
        .err = err,
        .byte_offset = offset,
        .line = @intCast(@min(line_count, line_max)),
        .column = @intCast(@min(column_count, line_max)),
        .snippet = input[snippet_start..snippet_end],
        .snippet_start = snippet_start,
    };
}

const XmlParseError = std.mem.Allocator.Error || XmlError;

const XmlFrame = struct {
    name: []const u8,
    open_offset: usize,
};

const XmlDecoded = struct {
    codepoint: u21,
    length: usize,
};

const XmlTapeOutput = struct {
    allocator: std.mem.Allocator,
    tape: *std.ArrayList(XmlTapeWord),
};

const XmlParser = struct {
    input: []const u8,
    output: ?*XmlTapeOutput,
    stack: []XmlFrame,
    failure_offset: usize = 0,
    source_error: ?XmlError = null,
    source_failure_offset: usize = 0,
    position: usize = 0,
    stack_top: usize = 0,
    root_seen: bool = false,
    root_closed: bool = false,
    declaration_allowed: bool = true,
    declaration_seen: bool = false,

    fn run(self: *XmlParser) XmlParseError!void {
        self.validateSource();
        if (startsWithAt(self.input, 0, "\xEF\xBB\xBF")) self.position = 3;

        self.runGrammar() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const grammar_error: XmlError = @errorCast(err);
            if (self.source_error) |source_err| {
                if (self.source_failure_offset <= self.failure_offset) {
                    self.failure_offset = self.source_failure_offset;
                    return source_err;
                }
            }
            return grammar_error;
        };
        if (self.source_error) |err| {
            return self.fail(err, self.source_failure_offset);
        }
    }

    fn runGrammar(self: *XmlParser) XmlParseError!void {
        while (self.position < self.input.len) {
            if (self.input[self.position] != '<') {
                try self.parseText();
                self.declaration_allowed = false;
                continue;
            }

            if (startsWithAt(self.input, self.position, "<!--")) {
                try self.parseComment();
                self.declaration_allowed = false;
                continue;
            }
            if (startsWithAt(self.input, self.position, "<![CDATA[")) {
                try self.parseCdata();
                self.declaration_allowed = false;
                continue;
            }
            if (startsWithAt(self.input, self.position, "<?")) {
                try self.parseProcessingInstruction();
                self.declaration_allowed = false;
                continue;
            }
            if (startsWithAt(self.input, self.position, "</")) {
                try self.parseClosingElement();
                self.declaration_allowed = false;
                continue;
            }
            if (startsWithAt(self.input, self.position, "<!")) {
                return self.fail(error.UnsupportedDeclaration, self.position);
            }
            try self.parseOpeningElement();
            self.declaration_allowed = false;
        }

        if (self.stack_top != 0) {
            return self.fail(error.UnclosedElement, self.stack[self.stack_top - 1].open_offset);
        }
        if (!self.root_seen) return self.fail(error.EmptyDocument, self.input.len);
    }

    fn validateSource(self: *XmlParser) void {
        var source_index: usize = 0;
        while (source_index < self.input.len) {
            const decoded = decodeXml(self.input, source_index) orelse {
                self.source_error = error.InvalidUtf8;
                self.source_failure_offset = source_index;
                return;
            };
            if (!isXmlCharacter(decoded.codepoint)) {
                self.source_error = error.InvalidCharacter;
                self.source_failure_offset = source_index;
                return;
            }
            source_index += decoded.length;
        }
    }

    fn parseText(self: *XmlParser) XmlParseError!void {
        const start = self.position;
        while (self.position < self.input.len and self.input[self.position] != '<') {
            self.position += 1;
        }
        try self.validateData(start, self.position, true, true, false);
        if (self.stack_top == 0) {
            if (!isXmlWhitespaceOnly(self.input[start..self.position])) {
                return self.fail(error.RootNotSingular, start);
            }
            return;
        }
        try self.emit(.text, start, self.position);
    }

    fn validateData(
        self: *XmlParser,
        start: usize,
        end: usize,
        entities: bool,
        forbid_cdata_end: bool,
        forbid_less_than: bool,
    ) XmlParseError!void {
        var cursor = start;
        while (cursor < end) {
            if (forbid_less_than and self.input[cursor] == '<') {
                return self.fail(error.InvalidAttribute, cursor);
            }
            if (self.input[cursor] == '&' and entities) {
                cursor = parseXmlEntity(self.input, cursor, end) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    return self.fail(@errorCast(err), cursor);
                };
                continue;
            }
            if (self.input[cursor] == '&' and !entities) {
                cursor += 1;
                continue;
            }
            if (forbid_cdata_end and startsWithAt(self.input, cursor, "]]>")) {
                return self.fail(error.InvalidCharacter, cursor);
            }
            const decoded = decodeXml(self.input, cursor) orelse {
                if (self.source_error != null) {
                    cursor += 1;
                    continue;
                }
                return self.fail(error.InvalidUtf8, cursor);
            };
            cursor += decoded.length;
        }
    }

    fn parseComment(self: *XmlParser) XmlParseError!void {
        const start = self.position;
        var index = start + 4;
        while (index + 1 < self.input.len) : (index += 1) {
            if (self.input[index] != '-' or self.input[index + 1] != '-') continue;
            if (index + 2 < self.input.len and self.input[index + 2] == '>') {
                try self.emit(.comment, start, index + 3);
                self.position = index + 3;
                return;
            }
            return self.fail(error.InvalidComment, index);
        }
        return self.fail(error.UnterminatedComment, start);
    }

    fn parseCdata(self: *XmlParser) XmlParseError!void {
        const start = self.position;
        if (self.stack_top == 0) return self.fail(error.RootNotSingular, start);
        const content_start = start + "<![CDATA[".len;
        const close = std.mem.indexOfPos(u8, self.input, content_start, "]]>") orelse {
            return self.fail(error.UnterminatedCdata, start);
        };
        try self.validateData(content_start, close, false, false, false);
        try self.emit(.cdata, start, close + 3);
        self.position = close + 3;
    }

    fn parseProcessingInstruction(self: *XmlParser) XmlParseError!void {
        const start = self.position;
        const target_start = start + 2;
        const target_end = self.parseName(target_start) orelse {
            return self.fail(error.InvalidName, target_start);
        };
        const target = self.input[target_start..target_end];
        const close = std.mem.indexOfPos(u8, self.input, target_end, "?>") orelse {
            return self.fail(error.UnterminatedProcessingInstruction, start);
        };

        if (std.mem.eql(u8, target, "xml")) {
            if (!self.declaration_allowed or self.declaration_seen or
                start != 0 and !startsWithAt(self.input, 0, "\xEF\xBB\xBF"))
            {
                return self.fail(error.InvalidDeclaration, start);
            }
            try self.parseDeclarationAttributes(target_end, close);
            self.declaration_seen = true;
            try self.emit(.xml_declaration, start, close + 2);
        } else {
            if (std.ascii.eqlIgnoreCase(target, "xml")) {
                return self.fail(error.InvalidDeclaration, target_start);
            }
            if (target_end < close and !isXmlWhitespace(self.input[target_end])) {
                return self.fail(error.UnexpectedToken, target_end);
            }
            try self.validateData(target_end, close, false, false, false);
            try self.emit(.processing_instruction, start, close + 2);
        }
        self.position = close + 2;
    }

    fn parseDeclarationAttributes(
        self: *XmlParser,
        attributes_start: usize,
        close: usize,
    ) XmlParseError!void {
        var cursor = attributes_start;
        var version_seen = false;
        var pseudo_attribute_seen = false;
        var declaration_order: u8 = 0;
        while (cursor < close) {
            const separator_start = cursor;
            cursor = skipXmlWhitespace(self.input, cursor);
            if (cursor == close) break;
            if (pseudo_attribute_seen and cursor == separator_start) {
                return self.fail(error.InvalidDeclaration, cursor);
            }
            const name_start = cursor;
            const name_end = self.parseName(cursor) orelse {
                return self.fail(error.InvalidDeclaration, cursor);
            };
            const name = self.input[name_start..name_end];
            if (hasPreviousXmlAttribute(self.input, attributes_start, name_start, name)) {
                return self.fail(error.InvalidDeclaration, name_start);
            }
            cursor = skipXmlWhitespace(self.input, name_end);
            if (cursor >= close or self.input[cursor] != '=') {
                return self.fail(error.InvalidDeclaration, cursor);
            }
            cursor += 1;
            cursor = skipXmlWhitespace(self.input, cursor);
            if (cursor >= close or (self.input[cursor] != '\'' and self.input[cursor] != '"')) {
                return self.fail(error.InvalidDeclaration, cursor);
            }
            const quote = self.input[cursor];
            cursor += 1;
            const value_start = cursor;
            while (cursor < close and self.input[cursor] != quote) : (cursor += 1) {}
            if (cursor == close) return self.fail(error.InvalidDeclaration, value_start - 1);
            const value = self.input[value_start..cursor];
            if (std.mem.eql(u8, name, "version")) {
                if (declaration_order != 0 or version_seen or !std.mem.eql(u8, value, "1.0")) {
                    return self.fail(error.InvalidDeclaration, name_start);
                }
                version_seen = true;
                declaration_order = 1;
            } else if (std.mem.eql(u8, name, "encoding")) {
                if (!version_seen or declaration_order > 1 or
                    !std.ascii.eqlIgnoreCase(value, "UTF-8"))
                {
                    return self.fail(error.InvalidDeclaration, name_start);
                }
                declaration_order = 2;
            } else if (std.mem.eql(u8, name, "standalone")) {
                if (!version_seen or declaration_order > 2 or
                    (!std.mem.eql(u8, value, "yes") and !std.mem.eql(u8, value, "no")))
                {
                    return self.fail(error.InvalidDeclaration, name_start);
                }
                declaration_order = 3;
            } else {
                return self.fail(error.InvalidDeclaration, name_start);
            }
            pseudo_attribute_seen = true;
            cursor += 1;
        }
        if (!version_seen) return self.fail(error.InvalidDeclaration, attributes_start);
    }

    fn parseOpeningElement(self: *XmlParser) XmlParseError!void {
        const start = self.position;
        const name_start = start + 1;
        const name_end = self.parseName(name_start) orelse {
            return self.fail(error.InvalidName, name_start);
        };
        const name = self.input[name_start..name_end];
        if (self.stack_top == 0 and self.root_closed) {
            return self.fail(error.RootNotSingular, start);
        }

        var element_word_index: ?usize = null;
        if (self.output) |output| {
            element_word_index = output.tape.items.len;
            try self.emit(.element_start, start, name_end);
        }

        var cursor = name_end;
        var self_closing = false;
        var attribute_seen = false;
        while (true) {
            const separator_start = cursor;
            cursor = skipXmlWhitespace(self.input, cursor);
            if (cursor >= self.input.len) return self.fail(error.UnterminatedElement, start);
            const at_element_end = self.input[cursor] == '>' or
                (self.input[cursor] == '/' and cursor + 1 < self.input.len and
                    self.input[cursor + 1] == '>');
            if (attribute_seen and cursor == separator_start and !at_element_end) {
                return self.fail(error.InvalidAttribute, cursor);
            }
            if (self.input[cursor] == '>') {
                cursor += 1;
                break;
            }
            if (self.input[cursor] == '/' and cursor + 1 < self.input.len and
                self.input[cursor + 1] == '>')
            {
                self_closing = true;
                cursor += 2;
                break;
            }

            const attribute_start = cursor;
            const attribute_end = self.parseName(cursor) orelse {
                return self.fail(error.InvalidAttribute, cursor);
            };
            const attribute_name = self.input[attribute_start..attribute_end];
            if (hasPreviousXmlAttribute(
                self.input,
                name_end,
                attribute_start,
                attribute_name,
            )) {
                return self.fail(error.DuplicateAttribute, attribute_start);
            }
            cursor = skipXmlWhitespace(self.input, attribute_end);
            if (cursor >= self.input.len or self.input[cursor] != '=') {
                return self.fail(error.InvalidAttribute, cursor);
            }
            cursor += 1;
            cursor = skipXmlWhitespace(self.input, cursor);
            if (cursor >= self.input.len or (self.input[cursor] != '\'' and self.input[cursor] != '"')) {
                return self.fail(error.InvalidAttribute, cursor);
            }
            const quote = self.input[cursor];
            cursor += 1;
            const value_start = cursor - 1;
            while (cursor < self.input.len and self.input[cursor] != quote) : (cursor += 1) {}
            if (cursor >= self.input.len) return self.fail(error.InvalidAttribute, value_start);
            try self.validateData(value_start + 1, cursor, true, false, true);
            cursor += 1;
            try self.emit(.attribute, attribute_start, cursor);
            attribute_seen = true;
        }

        if (self.stack_top >= self.stack.len and !self_closing) {
            return self.fail(error.DepthExceeded, start);
        }
        if (cursor - start > std.math.maxInt(u24)) {
            return self.fail(error.TapeTooLarge, start);
        }
        if (!self.root_seen) self.root_seen = true;
        if (self.output) |output| {
            const tape_index = element_word_index orelse unreachable;
            output.tape.items[tape_index].kind = @intFromEnum(
                if (self_closing) XmlTapeKind.self_closing_element else XmlTapeKind.element_start,
            );
            output.tape.items[tape_index].payload = @intCast(cursor - start);
        }
        if (self_closing) {
            if (self.stack_top == 0) self.root_closed = true;
            self.position = cursor;
            return;
        }
        self.stack[self.stack_top] = .{ .name = name, .open_offset = start };
        self.stack_top += 1;
        self.position = cursor;
    }

    fn parseClosingElement(self: *XmlParser) XmlParseError!void {
        const start = self.position;
        const name_start = start + 2;
        const name_end = self.parseName(name_start) orelse {
            return self.fail(error.InvalidName, name_start);
        };
        const name = self.input[name_start..name_end];
        const close_end = skipXmlWhitespace(self.input, name_end);
        if (close_end >= self.input.len or self.input[close_end] != '>') {
            return self.fail(error.UnexpectedToken, close_end);
        }
        if (self.stack_top == 0) return self.fail(error.MismatchedTag, name_start);
        const frame = self.stack[self.stack_top - 1];
        if (!std.mem.eql(u8, frame.name, name)) {
            return self.fail(error.MismatchedTag, name_start);
        }
        self.stack_top -= 1;
        try self.emit(.element_end, start, close_end + 1);
        if (self.stack_top == 0) self.root_closed = true;
        self.position = close_end + 1;
    }

    fn parseName(self: *const XmlParser, start: usize) ?usize {
        return parseXmlName(self.input, start);
    }

    fn emit(self: *XmlParser, kind: XmlTapeKind, start: usize, end: usize) XmlParseError!void {
        if (end < start or end > self.input.len) return self.fail(error.TapeTooLarge, start);
        const length = end - start;
        if (start > std.math.maxInt(u32) or length > std.math.maxInt(u24)) {
            return self.fail(error.TapeTooLarge, start);
        }
        if (self.output) |output| {
            try output.tape.append(output.allocator, .{
                .kind = @intFromEnum(kind),
                .payload = @intCast(length),
                .offset = @intCast(start),
            });
        }
    }

    fn fail(self: *XmlParser, err: XmlError, offset: usize) XmlParseError {
        self.failure_offset = @min(offset, self.input.len);
        return err;
    }
};

fn parseXmlName(input: []const u8, start: usize) ?usize {
    if (start >= input.len) return null;
    const first = decodeXml(input, start) orelse return null;
    if (!isXmlNameStart(first.codepoint)) return null;
    var cursor = start + first.length;
    while (cursor < input.len) {
        const decoded = decodeXml(input, cursor) orelse return cursor;
        if (!isXmlNameChar(decoded.codepoint)) break;
        cursor += decoded.length;
    }
    return cursor;
}

fn hasPreviousXmlAttribute(
    input: []const u8,
    attributes_start: usize,
    current_start: usize,
    current_name: []const u8,
) bool {
    var cursor = attributes_start;
    while (cursor < current_start) {
        cursor = skipXmlWhitespace(input, cursor);
        if (cursor >= current_start) break;
        const previous_start = cursor;
        const previous_end = parseXmlName(input, cursor) orelse return false;
        if (std.mem.eql(u8, input[previous_start..previous_end], current_name)) return true;
        cursor = skipXmlWhitespace(input, previous_end);
        if (cursor >= current_start or input[cursor] != '=') return false;
        cursor += 1;
        cursor = skipXmlWhitespace(input, cursor);
        if (cursor >= current_start or (input[cursor] != '\'' and input[cursor] != '"')) return false;
        const quote = input[cursor];
        cursor += 1;
        while (cursor < current_start and input[cursor] != quote) : (cursor += 1) {}
        if (cursor >= current_start) return false;
        cursor += 1;
    }
    return false;
}

fn parseXmlEntity(input: []const u8, start: usize, end: usize) XmlParseError!usize {
    var cursor = start + 1;
    while (cursor < end and input[cursor] != ';') : (cursor += 1) {}
    if (cursor >= end or cursor == start + 1) return error.InvalidEntity;
    const body = input[start + 1 .. cursor];
    if (std.mem.eql(u8, body, "amp") or std.mem.eql(u8, body, "lt") or
        std.mem.eql(u8, body, "gt") or std.mem.eql(u8, body, "apos") or
        std.mem.eql(u8, body, "quot"))
    {
        return cursor + 1;
    }
    if (body[0] != '#') return error.InvalidEntity;
    var digit_start: usize = start + 2;
    var base: u32 = 10;
    if (digit_start < cursor and input[digit_start] == 'x') {
        base = 16;
        digit_start += 1;
    }
    if (digit_start == cursor) return error.InvalidEntity;
    var codepoint: u32 = 0;
    while (digit_start < cursor) : (digit_start += 1) {
        const digit = xmlDigit(input[digit_start], base) orelse return error.InvalidEntity;
        if (codepoint > (std.math.maxInt(u32) - digit) / base) return error.InvalidEntity;
        codepoint = codepoint * base + digit;
    }
    if (codepoint > std.math.maxInt(u21) or !isXmlCharacter(@intCast(codepoint))) {
        return error.InvalidEntity;
    }
    return cursor + 1;
}

fn xmlDigit(byte: u8, base: u32) ?u32 {
    const value: ?u32 = if (byte >= '0' and byte <= '9')
        byte - '0'
    else if (byte >= 'a' and byte <= 'f')
        byte - 'a' + 10
    else if (byte >= 'A' and byte <= 'F')
        byte - 'A' + 10
    else
        null;
    if (value) |digit| {
        if (digit < base) return digit;
    }
    return null;
}

fn isXmlWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn isXmlWhitespaceOnly(input: []const u8) bool {
    for (input) |byte| {
        if (!isXmlWhitespace(byte)) return false;
    }
    return true;
}

fn skipXmlWhitespace(input: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < input.len and isXmlWhitespace(input[cursor])) : (cursor += 1) {}
    return cursor;
}

fn decodeXml(input: []const u8, index: usize) ?XmlDecoded {
    if (index >= input.len) return null;
    const first = input[index];
    if (first < 0x80) return .{ .codepoint = first, .length = 1 };
    if (first < 0xC2 or first > 0xF4) return null;
    const sequence_length: usize = if (first < 0xE0) 2 else if (first < 0xF0) 3 else 4;
    if (sequence_length > input.len - index) return null;
    var codepoint: u21 = switch (sequence_length) {
        2 => @as(u21, first & 0x1F),
        3 => @as(u21, first & 0x0F),
        4 => @as(u21, first & 0x07),
        else => unreachable,
    };
    for (1..sequence_length) |part| {
        const byte = input[index + part];
        if (byte < 0x80 or byte > 0xBF) return null;
        codepoint = (codepoint << 6) | @as(u21, byte & 0x3F);
    }
    if (sequence_length == 2 and codepoint < 0x80) return null;
    if (sequence_length == 3 and codepoint < 0x800) return null;
    if (sequence_length == 4 and codepoint < 0x10000) return null;
    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return null;
    if (codepoint > 0x10FFFF) return null;
    return .{ .codepoint = codepoint, .length = sequence_length };
}

fn isXmlCharacter(codepoint: u21) bool {
    return codepoint == 0x9 or codepoint == 0xA or codepoint == 0xD or
        (codepoint >= 0x20 and codepoint <= 0xD7FF) or
        (codepoint >= 0xE000 and codepoint <= 0xFFFD) or
        (codepoint >= 0x10000 and codepoint <= 0x10FFFF);
}

fn isXmlNameStart(codepoint: u21) bool {
    return codepoint == ':' or codepoint == '_' or
        (codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z') or
        (codepoint >= 0xC0 and codepoint <= 0xD6) or
        (codepoint >= 0xD8 and codepoint <= 0xF6) or
        (codepoint >= 0xF8 and codepoint <= 0x2FF) or
        (codepoint >= 0x370 and codepoint <= 0x37D) or
        (codepoint >= 0x37F and codepoint <= 0x1FFF) or
        (codepoint >= 0x200C and codepoint <= 0x200D) or
        (codepoint >= 0x2070 and codepoint <= 0x218F) or
        (codepoint >= 0x2C00 and codepoint <= 0x2FEF) or
        (codepoint >= 0x3001 and codepoint <= 0xD7FF) or
        (codepoint >= 0xF900 and codepoint <= 0xFDCF) or
        (codepoint >= 0xFDF0 and codepoint <= 0xFFFD) or
        (codepoint >= 0x10000 and codepoint <= 0xEFFFF);
}

fn isXmlNameChar(codepoint: u21) bool {
    return isXmlNameStart(codepoint) or codepoint == '-' or codepoint == '.' or
        (codepoint >= '0' and codepoint <= '9') or codepoint == 0xB7 or
        (codepoint >= 0x300 and codepoint <= 0x36F) or
        (codepoint >= 0x203F and codepoint <= 0x2040);
}

fn expectXmlDiagnostic(expected: XmlError, input: []const u8) !XmlDiagnostic {
    const result = try validateXml(input);
    const diagnostic = result orelse return error.ExpectedXmlDiagnostic;
    try testing.expectEqual(expected, diagnostic.err);
    return diagnostic;
}

fn makeNestedXml(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(allocator);
    for (0..depth) |_| try input.appendSlice(allocator, "<a>");
    for (0..depth) |_| try input.appendSlice(allocator, "</a>");
    return input.toOwnedSlice(allocator);
}

test "buildXmlTape accepts declaration comments nesting attributes text CDATA and self-close" {
    const input =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<!-- catalog --><catalog id='7'><item enabled=\"yes\">A &amp; B" ++
        "<![CDATA[<raw>&data</raw>]]><empty/></item><?done ok?></catalog>";
    var document = try buildXmlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expect(document.tape.len > 0);
    var saw_declaration = false;
    var saw_comment = false;
    var saw_attribute = false;
    var saw_text = false;
    var saw_cdata = false;
    var saw_self_close = false;
    for (document.tape, 0..) |word, tape_index| {
        const span = try document.sourceSpan(input, tape_index);
        try testing.expect(span.ptr == input.ptr + word.offset);
        switch (word.tapeKind()) {
            .xml_declaration => saw_declaration = true,
            .comment => saw_comment = true,
            .attribute => saw_attribute = true,
            .text => saw_text = true,
            .cdata => saw_cdata = true,
            .self_closing_element => saw_self_close = true,
            else => {},
        }
    }
    try testing.expect(saw_declaration);
    try testing.expect(saw_comment);
    try testing.expect(saw_attribute);
    try testing.expect(saw_text);
    try testing.expect(saw_cdata);
    try testing.expect(saw_self_close);

    var catalog = try buildXmlTape(
        testing.allocator,
        @embedFile("../../test/corpus/xml/catalog.xml"),
    );
    defer catalog.deinit(testing.allocator);
    try testing.expect(catalog.tape.len > 0);
}

test "validateXml reports matching and root errors at the first invalid byte" {
    const mismatch = try expectXmlDiagnostic(error.MismatchedTag, "<a><b></a>");
    try testing.expectEqual(@as(usize, 8), mismatch.byte_offset);

    const empty = try expectXmlDiagnostic(error.EmptyDocument, " \n\t");
    try testing.expectEqual(@as(usize, 3), empty.byte_offset);

    const second_root = try expectXmlDiagnostic(error.RootNotSingular, "<a/><b/>");
    try testing.expectEqual(@as(usize, 4), second_root.byte_offset);

    const unclosed = try expectXmlDiagnostic(error.UnclosedElement, "<a>");
    try testing.expectEqual(@as(usize, 0), unclosed.byte_offset);
}

test "validateXml rejects malformed attributes names entities and XML characters" {
    const duplicate = try expectXmlDiagnostic(error.DuplicateAttribute, "<a x='1' x=\"2\"/>");
    try testing.expectEqual(@as(usize, 9), duplicate.byte_offset);

    const unquoted = try expectXmlDiagnostic(error.InvalidAttribute, "<a x=value/>");
    try testing.expectEqual(@as(usize, 5), unquoted.byte_offset);

    const invalid_name = try expectXmlDiagnostic(error.InvalidName, "<1a/>");
    try testing.expectEqual(@as(usize, 1), invalid_name.byte_offset);
    const less_than = try expectXmlDiagnostic(error.InvalidAttribute, "<a x='<y'/>");
    try testing.expectEqual(@as(usize, 6), less_than.byte_offset);

    const entity = try expectXmlDiagnostic(error.InvalidEntity, "<a>&unknown;</a>");
    try testing.expectEqual(@as(usize, 3), entity.byte_offset);

    const attribute_entity = try expectXmlDiagnostic(error.InvalidEntity, "<a x='&amp'></a>");
    try testing.expectEqual(@as(usize, 6), attribute_entity.byte_offset);

    const illegal_text = [_]u8{ '<', 'a', '>', 0, '<', '/', 'a', '>' };
    const illegal = try expectXmlDiagnostic(error.InvalidCharacter, &illegal_text);
    try testing.expectEqual(@as(usize, 3), illegal.byte_offset);

    const invalid_utf8 = [_]u8{ '<', 'a', '>', 0xc0, 0xaf, '<', '/', 'a', '>' };
    const utf8 = try expectXmlDiagnostic(error.InvalidUtf8, &invalid_utf8);
    try testing.expectEqual(@as(usize, 3), utf8.byte_offset);
}

test "validateXml preserves the earliest lexical or grammar diagnostic" {
    const grammar_first_input = [_]u8{ '<', '1', '/', '>', 0 };
    const grammar_first = try expectXmlDiagnostic(error.InvalidName, &grammar_first_input);
    try testing.expectEqual(@as(usize, 1), grammar_first.byte_offset);

    const lexical_first_input = [_]u8{ '<', 'a', '>', 0, '<', '/', 'b', '>' };
    const lexical_first = try expectXmlDiagnostic(error.InvalidCharacter, &lexical_first_input);
    try testing.expectEqual(@as(usize, 3), lexical_first.byte_offset);
}

test "validateXml requires separators and exact XML markers" {
    const attribute = try expectXmlDiagnostic(error.InvalidAttribute, "<a x='1'y='2'/>");
    try testing.expectEqual(@as(usize, 8), attribute.byte_offset);

    const declaration = try expectXmlDiagnostic(
        error.InvalidDeclaration,
        "<?xml version='1.0'encoding='UTF-8'?><a/>",
    );
    try testing.expectEqual(@as(usize, 19), declaration.byte_offset);

    const instruction = try expectXmlDiagnostic(error.UnexpectedToken, "<a><?work=bad?></a>");
    try testing.expectEqual(@as(usize, 9), instruction.byte_offset);

    const declaration_case =
        try expectXmlDiagnostic(error.InvalidDeclaration, "<?XML version='1.0'?><a/>");
    try testing.expectEqual(@as(usize, 2), declaration_case.byte_offset);

    const hexadecimal = try expectXmlDiagnostic(error.InvalidEntity, "<a>&#X41;</a>");
    try testing.expectEqual(@as(usize, 3), hexadecimal.byte_offset);
}

test "validateXml rejects unterminated opaque forms and unsupported declarations" {
    const comment = try expectXmlDiagnostic(error.UnterminatedComment, "<!-- open<a/>");
    try testing.expectEqual(@as(usize, 0), comment.byte_offset);

    const cdata = try expectXmlDiagnostic(error.UnterminatedCdata, "<a><![CDATA[open</a>");
    try testing.expectEqual(@as(usize, 3), cdata.byte_offset);

    const instruction =
        try expectXmlDiagnostic(error.UnterminatedProcessingInstruction, "<a><?work open</a>");
    try testing.expectEqual(@as(usize, 3), instruction.byte_offset);

    const declaration = try expectXmlDiagnostic(error.UnsupportedDeclaration, "<!DOCTYPE a><a/>");
    try testing.expectEqual(@as(usize, 0), declaration.byte_offset);

    const malformed_comment = try expectXmlDiagnostic(error.InvalidComment, "<!-- a--b --><a/>");
    try testing.expectEqual(@as(usize, 6), malformed_comment.byte_offset);
}

test "validateXml enforces the fixed nesting limit" {
    const valid = try makeNestedXml(testing.allocator, xml_max_depth);
    defer testing.allocator.free(valid);
    try testing.expectEqual(@as(?XmlDiagnostic, null), try validateXml(valid));

    const invalid = try makeNestedXml(testing.allocator, xml_max_depth + 1);
    defer testing.allocator.free(invalid);
    const diagnostic = try expectXmlDiagnostic(error.DepthExceeded, invalid);
    try testing.expectEqual(@as(usize, xml_max_depth * 3), diagnostic.byte_offset);
}

test "XmlDocument checks tape and source bounds and diagnostics borrow source" {
    const input = "\n<a>&bad;</a>";
    const diagnostic = try expectXmlDiagnostic(error.InvalidEntity, input);
    try testing.expectEqual(@as(usize, 4), diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), diagnostic.line);
    try testing.expectEqual(@as(u32, 4), diagnostic.column);
    try testing.expectEqual(@as(usize, 1), diagnostic.snippet_start);
    try testing.expectEqualStrings("<a>&bad;</a>", diagnostic.snippet);
    try testing.expect(diagnostic.snippet.ptr == input.ptr + diagnostic.snippet_start);

    var document = try buildXmlTape(testing.allocator, "<root/>");
    defer document.deinit(testing.allocator);
    try testing.expectError(error.TapeOutOfBounds, document.word(document.tape.len));
    try testing.expectError(error.SourceOutOfBounds, document.sourceSpan("<", 0));

    const saved_kind = document.tape[0].kind;
    document.tape[0].kind = 255;
    try testing.expectError(error.InvalidTapeKind, document.sourceSpan("<root/>", 0));
    document.tape[0].kind = saved_kind;
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}
