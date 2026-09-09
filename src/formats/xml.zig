const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const resident = @import("../core/resident.zig");
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

const XmlLexicalMode = enum {
    outside,
    opener,
    tag,
    attribute_quote,
    comment,
    cdata,
};

const XmlOpenerKind = enum {
    unknown,
    comment,
    cdata,
};

/// Bounded state shared by the one-shot and chunk-fed XML scanners.
///
/// The scanner stores only an unfinished opener, the quote delimiter, and the
/// previous two bytes needed by opaque-section terminators. It never borrows
/// or copies input beyond the current call.
const XmlLexicalState = struct {
    mode: XmlLexicalMode = .outside,
    previous_byte: u8 = 0,
    attribute_quote: u8 = 0,
    opener_start: usize = 0,
    opener_length: u8 = 0,
    opener_kind: XmlOpenerKind = .unknown,
    comment_previous_previous: u8 = 0,
    comment_previous: u8 = 0,
    cdata_previous_previous: u8 = 0,
    cdata_previous: u8 = 0,
};

const XmlLexicalSink = struct {
    result: *XmlStructuralIndex,

    fn appendToken(
        self: *@This(),
        index: usize,
        kind: XmlTokenKind,
    ) error{CapacityExceeded}!void {
        if (self.result.count >= self.result.indexes.len - 3) {
            return error.CapacityExceeded;
        }
        if (self.result.count >= self.result.kinds.len) {
            return error.CapacityExceeded;
        }
        self.result.indexes[self.result.count] = @intCast(index);
        self.result.kinds[self.result.count] = kind;
        self.result.count += 1;
    }
};

const XmlStreamSink = struct {
    owner: *XmlStreamIndexer,

    fn appendToken(
        self: *@This(),
        index: usize,
        kind: XmlTokenKind,
    ) error{CapacityExceeded}!void {
        return self.owner.appendToken(index, kind);
    }
};

fn xmlValidMask(comptime VLEN: usize, valid_count: usize) simd.Mask(VLEN) {
    return simd.validMask(VLEN, valid_count);
}

fn xmlPreviousByte(
    state: *const XmlLexicalState,
    input: []const u8,
    local_index: usize,
) u8 {
    if (local_index == 0) return state.previous_byte;
    return input[local_index - 1];
}

fn xmlCommentTerminator(
    state: *const XmlLexicalState,
    input: []const u8,
    input_index: usize,
    absolute_index: usize,
) bool {
    if (absolute_index < state.opener_start) return false;
    if (absolute_index - state.opener_start < 6) return false;
    if (input[input_index] != '>') return false;
    const previous = if (input_index == 0)
        state.comment_previous
    else
        input[input_index - 1];
    const previous_previous = if (input_index >= 2)
        input[input_index - 2]
    else if (input_index == 1)
        state.comment_previous
    else
        state.comment_previous_previous;
    return previous_previous == '-' and previous == '-';
}

fn xmlCdataTerminator(
    state: *const XmlLexicalState,
    input: []const u8,
    local_index: usize,
) bool {
    if (input[local_index] != '>') return false;
    const previous = if (local_index == 0)
        state.cdata_previous
    else
        input[local_index - 1];
    const previous_previous = if (local_index >= 2)
        input[local_index - 2]
    else if (local_index == 1)
        state.cdata_previous
    else
        state.cdata_previous_previous;
    return previous_previous == ']' and previous == ']';
}

fn xmlRememberOpaqueTail(
    state: *XmlLexicalState,
    input: []const u8,
    mode: XmlLexicalMode,
) void {
    if (input.len == 0) return;
    switch (mode) {
        .comment => {
            if (input.len == 1) {
                state.comment_previous_previous = state.comment_previous;
                state.comment_previous = input[0];
            } else {
                state.comment_previous_previous = input[input.len - 2];
                state.comment_previous = input[input.len - 1];
            }
        },
        .cdata => {
            if (input.len == 1) {
                state.cdata_previous_previous = state.cdata_previous;
                state.cdata_previous = input[0];
            } else {
                state.cdata_previous_previous = input[input.len - 2];
                state.cdata_previous = input[input.len - 1];
            }
        },
        else => {},
    }
}

fn xmlBeginOpener(
    state: *XmlLexicalState,
    absolute_index: usize,
) void {
    state.mode = .opener;
    state.previous_byte = '<';
    state.opener_start = absolute_index;
    state.opener_length = 0;
    state.opener_kind = .unknown;
}

fn xmlAppendTagOpen(
    state: *XmlLexicalState,
    sink: anytype,
) !void {
    try sink.appendToken(state.opener_start, .tag_open);
    state.mode = .tag;
    state.opener_length = 0;
    state.opener_kind = .unknown;
}

fn xmlProcessTagByte(
    state: *XmlLexicalState,
    input: []const u8,
    input_index: usize,
    base_offset: usize,
    sink: anytype,
) !void {
    const byte = input[input_index];
    switch (byte) {
        '<' => xmlBeginOpener(state, base_offset + input_index),
        '=' => try sink.appendToken(base_offset + input_index, .attr_equals),
        '"', '\'' => {
            try sink.appendToken(base_offset + input_index, .attr_quote);
            state.mode = .attribute_quote;
            state.attribute_quote = byte;
        },
        '>' => {
            const previous = xmlPreviousByte(state, input, input_index);
            if (previous == '/') {
                try sink.appendToken(base_offset + input_index - 1, .self_close);
            } else if (previous == '?') {
                try sink.appendToken(base_offset + input_index - 1, .proc_inst_close);
            } else {
                try sink.appendToken(base_offset + input_index, .tag_close);
            }
            state.mode = .outside;
        },
        else => {},
    }
    state.previous_byte = byte;
}

fn xmlProcessOpener(
    state: *XmlLexicalState,
    input: []const u8,
    base_offset: usize,
    start_local: usize,
    sink: anytype,
) !usize {
    var local_index = start_local;
    while (local_index < input.len and state.mode == .opener) : (local_index += 1) {
        const byte = input[local_index];
        if (state.opener_length == 0) {
            switch (byte) {
                '/' => {
                    try sink.appendToken(state.opener_start, .closing_tag_open);
                    state.mode = .tag;
                    state.previous_byte = byte;
                },
                '?' => {
                    try sink.appendToken(state.opener_start, .proc_inst_open);
                    state.mode = .tag;
                    state.previous_byte = byte;
                },
                '!' => {
                    state.opener_length = 1;
                    state.previous_byte = byte;
                },
                else => {
                    try xmlAppendTagOpen(state, sink);
                    try xmlProcessTagByte(state, input, local_index, base_offset, sink);
                },
            }
            continue;
        }

        if (state.opener_length == 1) {
            switch (byte) {
                '-' => {
                    state.opener_kind = .comment;
                    state.opener_length = 2;
                    state.previous_byte = byte;
                },
                '[' => {
                    state.opener_kind = .cdata;
                    state.opener_length = 2;
                    state.previous_byte = byte;
                },
                else => {
                    try xmlAppendTagOpen(state, sink);
                    try xmlProcessTagByte(state, input, local_index, base_offset, sink);
                },
            }
            continue;
        }

        const literal: []const u8 = switch (state.opener_kind) {
            .comment => "<!--",
            .cdata => "<![CDATA[",
            .unknown => unreachable,
        };
        const literal_index = 1 + @as(usize, state.opener_length);
        if (literal_index >= literal.len or byte != literal[literal_index]) {
            try xmlAppendTagOpen(state, sink);
            try xmlProcessTagByte(state, input, local_index, base_offset, sink);
            continue;
        }

        state.opener_length += 1;
        state.previous_byte = byte;
        if (1 + @as(usize, state.opener_length) != literal.len) continue;

        switch (state.opener_kind) {
            .comment => {
                state.mode = .comment;
                state.comment_previous_previous = 0;
                state.comment_previous = 0;
            },
            .cdata => {
                state.mode = .cdata;
                state.cdata_previous_previous = 0;
                state.cdata_previous = 0;
            },
            .unknown => unreachable,
        }
        try sink.appendToken(state.opener_start, .tag_open);
        state.opener_length = 0;
        state.opener_kind = .unknown;
    }
    return local_index;
}

fn xmlMaskForState(
    comptime VLEN: usize,
    state: *const XmlLexicalState,
    vector: simd.Vec(VLEN, u8),
) simd.Mask(VLEN) {
    return switch (state.mode) {
        .outside => simd.matchByte(VLEN, vector, '<'),
        .tag => simd.matchAny4(VLEN, vector, '=', '"', '\'', '>') |
            simd.matchByte(VLEN, vector, '<'),
        .attribute_quote => simd.matchByte(VLEN, vector, state.attribute_quote),
        .comment, .cdata => simd.matchByte(VLEN, vector, '>'),
        .opener => 0,
    };
}

fn scanXmlLexical(
    comptime VLEN: usize,
    state: *XmlLexicalState,
    input: []const u8,
    base_offset: usize,
    sink: anytype,
) !void {
    const Mask = simd.Mask(VLEN);
    var cursor: usize = 0;
    while (cursor < input.len) {
        if (state.mode == .opener) {
            cursor = try xmlProcessOpener(state, input, base_offset, cursor, sink);
            if (state.mode == .opener) break;
            continue;
        }

        const block_start = cursor;
        const block_end = @min(cursor + VLEN, input.len);
        const valid_count = block_end - cursor;
        const vector: simd.Vec(VLEN, u8) = if (valid_count == VLEN)
            input[cursor..][0..VLEN].*
        else blk: {
            var tail: [VLEN]u8 = @splat(0);
            @memcpy(tail[0..valid_count], input[cursor..block_end]);
            break :blk tail;
        };
        // A mode transition invalidates the remaining candidates, so the suffix
        // is rescanned with a freshly selected mask.
        const mask: Mask = xmlMaskForState(VLEN, state, vector) &
            xmlValidMask(VLEN, valid_count);
        var candidate_indexes: [VLEN]u32 = undefined;
        const candidate_count = try simd.extractBitIndexesChecked(
            Mask,
            mask,
            base_offset + cursor,
            &candidate_indexes,
        );

        if (candidate_count == 0) {
            cursor = block_end;
            state.previous_byte = input[block_end - 1];
            xmlRememberOpaqueTail(state, input[block_start..block_end], state.mode);
            continue;
        }

        var candidate_index: usize = 0;
        var rescan = false;
        while (candidate_index < candidate_count) : (candidate_index += 1) {
            // Extraction returns absolute offsets; input remains chunk-local.
            const absolute_index: usize = @intCast(candidate_indexes[candidate_index]);
            const input_index = absolute_index - base_offset;
            std.debug.assert(input_index >= block_start);
            std.debug.assert(input_index < block_end);

            switch (state.mode) {
                .outside => {
                    xmlBeginOpener(state, absolute_index);
                    cursor = try xmlProcessOpener(
                        state,
                        input,
                        base_offset,
                        input_index + 1,
                        sink,
                    );
                    rescan = true;
                },
                .tag => {
                    try xmlProcessTagByte(
                        state,
                        input,
                        input_index,
                        base_offset,
                        sink,
                    );
                    if (state.mode != .tag) {
                        cursor = if (state.mode == .opener)
                            try xmlProcessOpener(
                                state,
                                input,
                                base_offset,
                                input_index + 1,
                                sink,
                            )
                        else
                            input_index + 1;
                        rescan = true;
                    }
                },
                .attribute_quote => {
                    if (input[input_index] == state.attribute_quote) {
                        try sink.appendToken(base_offset + input_index, .attr_quote);
                        state.mode = .tag;
                        state.previous_byte = input[input_index];
                        cursor = input_index + 1;
                        rescan = true;
                    }
                },
                .comment => {
                    if (xmlCommentTerminator(
                        state,
                        input,
                        input_index,
                        absolute_index,
                    )) {
                        state.mode = .outside;
                        state.previous_byte = input[input_index];
                        cursor = input_index + 1;
                        rescan = true;
                    }
                },
                .cdata => {
                    if (xmlCdataTerminator(state, input, input_index)) {
                        state.mode = .outside;
                        state.previous_byte = input[input_index];
                        cursor = input_index + 1;
                        rescan = true;
                    }
                },
                .opener => unreachable,
            }
            if (rescan) break;
        }

        if (!rescan) {
            cursor = block_end;
            state.previous_byte = input[block_end - 1];
            xmlRememberOpaqueTail(state, input[block_start..block_end], state.mode);
        }
    }
}

fn finishXmlLexical(
    state: *XmlLexicalState,
    sink: anytype,
) !void {
    if (state.mode == .opener) {
        try sink.appendToken(state.opener_start, .tag_open);
        state.mode = .tag;
        state.opener_length = 0;
        state.opener_kind = .unknown;
    }
}

/// Incrementally builds the same XML structural index as `indexXml`.
///
/// The scanner retains only bounded lexical carry and output storage. Input
/// chunks are consumed before `feed` returns and are never retained.
pub const XmlStreamIndexer = struct {
    allocator: std.mem.Allocator,
    index: ?stage1.StructuralIndex = null,
    kinds: ?[]XmlTokenKind = null,
    input_len: usize = 0,
    lexical: XmlLexicalState = .{},
    finished: bool = false,

    const Self = @This();
    const initial_output_capacity: usize = 1;

    pub const InitError = stage1.StructuralIndex.InitError;
    pub const FeedError = std.mem.Allocator.Error || error{
        AlreadyFinished,
        CapacityOverflow,
        InputTooLarge,
        CapacityExceeded,
    };
    pub const FinishError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
        CapacityExceeded,
    };
    pub const FeedFromError = FeedError || FinishError || std.Io.Reader.ShortError;

    /// Allocates structural storage with `chunk_len` as its initial capacity.
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
        if (self.index) |*index| index.deinit(self.allocator);
        if (self.kinds) |kinds| self.allocator.free(kinds);
        self.* = undefined;
    }

    /// Adds a caller-owned chunk without retaining a reference to that chunk.
    pub fn feed(self: *Self, data: []const u8) FeedError!void {
        if (self.finished) return error.AlreadyFinished;
        const new_input_len = std.math.add(usize, self.input_len, data.len) catch {
            return error.CapacityOverflow;
        };
        if (new_input_len > std.math.maxInt(u32)) return error.InputTooLarge;

        const deferred_opener = if (self.lexical.mode == .opener) @as(usize, 1) else 0;
        const additional = std.math.add(usize, data.len, deferred_opener) catch {
            return error.CapacityOverflow;
        };
        try self.ensureOutputCapacity(additional);
        const base_offset = self.input_len;
        self.input_len = new_input_len;
        var sink = XmlStreamSink{ .owner = self };
        try scanXmlLexical(simd.default_vector_len, &self.lexical, data, base_offset, &sink);
    }

    /// Drains a reader into `feed` and finalizes at EOF. Reader bytes are
    /// borrowed only for each call and are never retained.
    pub fn feedFrom(self: *Self, reader: *std.Io.Reader) FeedFromError!void {
        while (true) {
            const data = reader.buffered();
            if (data.len > 0) {
                try self.feed(data);
                reader.toss(data.len);
                continue;
            }
            reader.fill(1) catch |err| switch (err) {
                error.EndOfStream => return self.finish(),
                error.ReadFailed => return error.ReadFailed,
            };
        }
    }

    /// Finalizes pending opener state and writes the structural sentinels.
    pub fn finish(self: *Self) FinishError!void {
        if (self.finished) return;
        const deferred_opener = if (self.lexical.mode == .opener) @as(usize, 1) else 0;
        try self.ensureOutputCapacity(deferred_opener);
        var sink = XmlStreamSink{ .owner = self };
        try finishXmlLexical(&self.lexical, &sink);
        if (self.index) |*index| {
            try index.finish(self.input_len);
        } else {
            unreachable;
        }
        self.finished = true;
    }

    /// Transfers the finalized structural index and token kinds to the caller.
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

    /// Starts a new document while retaining reusable output capacity.
    pub fn reset(self: *Self) void {
        if (self.index) |*index| index.count = 0;
        self.input_len = 0;
        self.lexical = .{};
        self.finished = false;
    }

    fn appendToken(
        self: *Self,
        index: usize,
        kind: XmlTokenKind,
    ) error{CapacityExceeded}!void {
        const structural_index = self.index orelse return error.CapacityExceeded;
        const kinds = self.kinds orelse return error.CapacityExceeded;
        if (structural_index.count >= structural_index.indexes.len - 3) {
            return error.CapacityExceeded;
        }
        if (structural_index.count >= kinds.len) return error.CapacityExceeded;
        self.index.?.indexes[structural_index.count] = @intCast(index);
        self.kinds.?[structural_index.count] = kind;
        self.index.?.count += 1;
    }

    fn ensureOutputCapacity(self: *Self, additional: usize) (std.mem.Allocator.Error || error{ CapacityOverflow, InputTooLarge })!void {
        if (self.index == null) {
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
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    var structural_indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer structural_indexes.deinit(allocator);
    const kinds = try allocator.alloc(XmlTokenKind, input.len);
    errdefer allocator.free(kinds);

    var result = XmlStructuralIndex{
        .indexes = structural_indexes.indexes,
        .kinds = kinds,
        .count = 0,
    };
    var state: XmlLexicalState = .{};
    var sink = XmlLexicalSink{ .result = &result };
    scanXmlLexical(VLEN, &state, input, 0, &sink) catch |err| switch (err) {
        error.CapacityExceeded => unreachable,
        error.InputTooLarge => return error.InputTooLarge,
    };
    finishXmlLexical(&state, &sink) catch |err| switch (err) {
        error.CapacityExceeded => unreachable,
    };
    structural_indexes.count = result.count;
    try structural_indexes.finish(input.len);
    return result;
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
    inline for (.{ 4, 5, 7, 16, 32, 64 }) |VLEN| {
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
        // Keep an anchor near the fragment's end at a block-relative boundary
        // even when the first boundary is before the anchor in the fragment.
        const preceding_block_count = if (boundary_offset < anchor_in_fragment)
            (anchor_in_fragment - boundary_offset + VLEN - 1) / VLEN
        else
            0;
        const anchor_offset = boundary_offset + preceding_block_count * VLEN;
        const fragment_offset = anchor_offset - anchor_in_fragment;
        std.debug.assert(anchor_offset >= anchor_in_fragment);
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
    inline for ([_]usize{ 4, 5, 7, 16, 32, 64 }) |vlen| {
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

test "XML stream reserves output for a deferred opener" {
    const input = "<>";
    var expected = try indexXml(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var stream = try XmlStreamIndexer.init(testing.allocator, 1);
    defer stream.deinit();
    try stream.feed("<");
    try stream.feed(">");
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

test "indexXml matches scalar at the end of an irregular-width block" {
    var input: [508]u8 = @splat('x');
    input[504] = '<';
    try expectMatchesScalar(&input);
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
    SourceMismatch,
    InvalidTapeKind,
    InvalidTapeOrder,
    CapacityOverflow,
    CapacityExceeded,
    DocumentActive,
    DocumentReleased,
    FocusAlreadyClaimed,
    OutOfOrderIteration,
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

pub const XmlElementEvent = struct {
    raw: []const u8,
    name: []const u8,
    offset: u32,
    self_closing: bool,
};

pub const XmlAttributeEvent = struct {
    raw: []const u8,
    name: []const u8,
    value: []const u8,
    offset: u32,
};

pub const XmlTextEvent = struct {
    raw: []const u8,
    offset: u32,
};

pub const XmlCommentEvent = struct {
    raw: []const u8,
    content: []const u8,
    offset: u32,
};

pub const XmlCdataEvent = struct {
    raw: []const u8,
    content: []const u8,
    offset: u32,
};

pub const XmlProcessingInstructionEvent = struct {
    raw: []const u8,
    target: []const u8,
    data: []const u8,
    offset: u32,
};

pub const XmlEvent = union(enum) {
    xml_declaration: struct { raw: []const u8, offset: u32 },
    element_start: XmlElementEvent,
    element_end: struct { raw: []const u8, name: []const u8, offset: u32 },
    self_closing_element: XmlElementEvent,
    attribute: XmlAttributeEvent,
    text: XmlTextEvent,
    cdata: XmlCdataEvent,
    comment: XmlCommentEvent,
    processing_instruction: XmlProcessingInstructionEvent,

    pub fn raw(self: XmlEvent) []const u8 {
        return switch (self) {
            .xml_declaration => |event| event.raw,
            .element_start => |event| event.raw,
            .element_end => |event| event.raw,
            .self_closing_element => |event| event.raw,
            .attribute => |event| event.raw,
            .text => |event| event.raw,
            .cdata => |event| event.raw,
            .comment => |event| event.raw,
            .processing_instruction => |event| event.raw,
        };
    }
};

pub const XmlToken = struct {
    kind: XmlTapeKind,
    raw: []const u8,
    offset: u32,
};

pub const XmlDocument = struct {
    tape: []XmlTapeWord,
    source: ?[]const u8 = null,

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
        const kind = try checkedXmlTapeKind(word_value);
        const source_offset: usize = @intCast(word_value.offset);
        const source_length = word_value.sourceLength();
        if (source_offset > input.len) return error.SourceOutOfBounds;
        if (source_length > input.len - source_offset) return error.SourceOutOfBounds;
        if (!xmlTapeSpanMatchesKind(
            kind,
            input[source_offset .. source_offset + source_length],
        )) return error.InvalidTapeOrder;
        if (tape_index > 0 and word_value.offset <= self.tape[tape_index - 1].offset) {
            return error.InvalidTapeOrder;
        }
        return input[source_offset .. source_offset + source_length];
    }

    pub fn root(self: *const XmlDocument, input: []const u8) XmlError!XmlTapeCursor {
        const source = self.source orelse return error.SourceMismatch;
        if (source.ptr != input.ptr or source.len != input.len) return error.SourceMismatch;

        if (self.tape.len == 0) return error.TapeOutOfBounds;
        try validateXmlTape(self.tape, input);
        var index: usize = 0;
        while (index < self.tape.len) : (index += 1) {
            const token = try xmlTapeToken(self, input, index);
            switch (token.kind) {
                .xml_declaration, .comment, .processing_instruction => {},
                .element_start, .self_closing_element => {
                    return .{
                        .document = self,
                        .input = input,
                        .position = index,
                    };
                },
                else => return error.InvalidTapeOrder,
            }
        }
        return error.TapeOutOfBounds;
    }
};

fn xmlTapeToken(
    document: *const XmlDocument,
    input: []const u8,
    index: usize,
) XmlError!XmlToken {
    const word_value = try document.word(index);
    const kind = try checkedXmlTapeKind(word_value);
    const offset: usize = @intCast(word_value.offset);
    const length = word_value.sourceLength();
    if (offset > input.len or length > input.len - offset) return error.SourceOutOfBounds;
    if (!xmlTapeSpanMatchesKind(kind, input[offset .. offset + length])) {
        return error.InvalidTapeOrder;
    }
    if (index > 0 and word_value.offset <= document.tape[index - 1].offset) {
        return error.InvalidTapeOrder;
    }
    return .{
        .kind = kind,
        .raw = input[offset .. offset + length],
        .offset = word_value.offset,
    };
}
fn xmlTapeSpanMatchesKind(kind: XmlTapeKind, raw: []const u8) bool {
    if (raw.len == 0) return false;

    var stack: [1]XmlFrame = undefined;
    var parser = XmlParser{
        .input = raw,
        .output = null,
        .stack = stack[0..],
    };

    switch (kind) {
        .element_start, .self_closing_element => {
            parser.parseOpeningElement() catch return false;
            if (parser.position != raw.len) return false;
            const self_closing = parser.stack_top == 0;
            return self_closing == (kind == .self_closing_element);
        },
        .element_end => {
            if (!startsWithAt(raw, 0, "</")) return false;
            const name_end = parseXmlName(raw, 2) orelse return false;
            const close = skipXmlWhitespace(raw, name_end);
            return close < raw.len and close + 1 == raw.len and raw[close] == '>';
        },
        .attribute => return xmlTapeAttributeMatches(raw),
        .text => {
            parser.stack_top = 1;
            parser.parseText() catch return false;
            return parser.position == raw.len;
        },
        .cdata => {
            parser.stack_top = 1;
            parser.parseCdata() catch return false;
            return parser.position == raw.len;
        },
        .comment => {
            parser.parseComment() catch return false;
            return parser.position == raw.len;
        },
        .xml_declaration, .processing_instruction => {
            if (!startsWithAt(raw, 0, "<?")) return false;
            const target_end = parseXmlName(raw, 2) orelse return false;
            const target = raw[2..target_end];
            if (kind == .xml_declaration) {
                if (!std.mem.eql(u8, target, "xml")) return false;
            } else if (std.ascii.eqlIgnoreCase(target, "xml")) {
                return false;
            }
            parser.parseProcessingInstruction() catch return false;
            return parser.position == raw.len;
        },
    }
}

fn xmlTapeAttributeMatches(raw: []const u8) bool {
    var stack: [1]XmlFrame = undefined;
    var parser = XmlParser{
        .input = raw,
        .output = null,
        .stack = stack[0..],
    };

    const name_end = parseXmlName(raw, 0) orelse return false;
    var cursor = skipXmlWhitespace(raw, name_end);
    if (cursor >= raw.len or raw[cursor] != '=') return false;
    cursor = skipXmlWhitespace(raw, cursor + 1);
    if (cursor >= raw.len or (raw[cursor] != '\'' and raw[cursor] != '"')) return false;
    const quote = raw[cursor];
    const value_start = cursor + 1;
    cursor = value_start;
    while (cursor < raw.len and raw[cursor] != quote) : (cursor += 1) {}
    if (cursor >= raw.len or cursor + 1 != raw.len) return false;
    parser.validateData(value_start, cursor, true, false, true) catch return false;
    return true;
}

pub const XmlTapeCursor = struct {
    document: *const XmlDocument,
    input: []const u8,
    position: usize,

    fn ensureSource(self: *const @This()) XmlError!void {
        const source = self.document.source orelse return error.SourceMismatch;
        if (source.ptr != self.input.ptr or source.len != self.input.len) {
            return error.SourceMismatch;
        }
    }

    pub fn peek(self: *const @This()) XmlError!?XmlToken {
        try self.ensureSource();
        if (self.position >= self.document.tape.len) return null;
        return try xmlTapeToken(self.document, self.input, self.position);
    }

    pub fn advance(self: *@This()) XmlError!?XmlToken {
        const token = try self.peek() orelse return null;
        self.position += 1;
        return token;
    }

    pub fn skipChild(self: *@This()) XmlError!void {
        const first = try self.peek() orelse return;
        switch (first.kind) {
            .self_closing_element => {
                const element_end = @as(usize, first.offset) + first.raw.len;
                _ = try self.advance();
                while (true) {
                    const attribute = try self.peek() orelse break;
                    if (@as(usize, attribute.offset) >= element_end) break;
                    if (attribute.kind != .attribute) return error.InvalidTapeOrder;
                    _ = try self.advance();
                }
                return;
            },
            .element_start => {},
            else => {
                _ = try self.advance();
                return;
            },
        }

        var depth: usize = 0;
        while (true) {
            const token = try self.advance() orelse return error.TapeOutOfBounds;
            switch (token.kind) {
                .element_start => depth += 1,
                .self_closing_element => {},
                .element_end => {
                    if (depth == 0) return error.InvalidTapeOrder;
                    depth -= 1;
                    if (depth == 0) return;
                },
                else => {},
            }
        }
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
        .storage = .{ .builder = .{
            .allocator = allocator,
            .tape = &tape,
        } },
    };

    var parser = XmlParser{
        .input = input,
        .output = &output,
        .stack = stack[0..],
    };
    try parser.run();
    const owned_tape = try tape.toOwnedSlice(allocator);
    return .{
        .tape = owned_tape,
        .source = input,
    };
}

fn validateXmlTape(tape: []const XmlTapeWord, input: []const u8) XmlError!void {
    var stack: [xml_max_depth]XmlFrame = undefined;
    var output = XmlTapeOutput{ .storage = .{ .validator = tape } };
    var parser = XmlParser{
        .input = input,
        .output = &output,
        .stack = stack[0..],
    };
    parser.run() catch |err| {
        if (err == error.OutOfMemory) return error.InvalidTapeOrder;
        return @errorCast(err);
    };
    try output.finish();
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

pub const XmlParseError = std.mem.Allocator.Error || XmlError;

const XmlFrame = struct {
    name: []const u8,
    open_offset: usize,
};

const XmlDecoded = struct {
    codepoint: u21,
    length: usize,
};

const XmlTapeOutput = struct {
    storage: union(enum) {
        builder: struct {
            allocator: std.mem.Allocator,
            tape: *std.ArrayList(XmlTapeWord),
        },
        validator: []const XmlTapeWord,
    },
    count: usize = 0,

    fn append(self: *@This(), kind: XmlTapeKind, start: usize, end: usize) XmlParseError!void {
        switch (self.storage) {
            .builder => |builder| {
                try builder.tape.append(builder.allocator, .{
                    .kind = @intFromEnum(kind),
                    .payload = @intCast(end - start),
                    .offset = @intCast(start),
                });
                self.count += 1;
            },
            .validator => |expected| {
                if (self.count >= expected.len) return error.InvalidTapeOrder;
                const word = expected[self.count];
                const expected_kind = checkedXmlTapeKind(word) catch return error.InvalidTapeKind;
                if (@as(usize, @intCast(word.offset)) != start) {
                    return error.InvalidTapeOrder;
                }
                if (kind != .element_start and expected_kind != kind) {
                    return error.InvalidTapeOrder;
                }
                if (kind == .element_start and
                    expected_kind != .element_start and
                    expected_kind != .self_closing_element)
                {
                    return error.InvalidTapeOrder;
                }
                if (kind != .element_start and word.sourceLength() != end - start) {
                    return error.InvalidTapeOrder;
                }
                self.count += 1;
            },
        }
    }

    fn updateOpening(
        self: *@This(),
        tape_index: usize,
        kind: XmlTapeKind,
        length: usize,
    ) XmlParseError!void {
        switch (self.storage) {
            .builder => |builder| {
                builder.tape.items[tape_index].kind = @intFromEnum(kind);
                builder.tape.items[tape_index].payload = @intCast(length);
            },
            .validator => |expected| {
                if (tape_index >= expected.len) return error.InvalidTapeOrder;
                const word = expected[tape_index];
                if (word.kind != @intFromEnum(kind) or word.sourceLength() != length) {
                    return error.InvalidTapeOrder;
                }
            },
        }
    }

    fn finish(self: *const @This()) XmlError!void {
        switch (self.storage) {
            .builder => {},
            .validator => |expected| {
                if (self.count != expected.len) return error.InvalidTapeOrder;
            },
        }
    }
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
        const invalid_utf8_offset: ?usize = switch (simd.validateUtf8(self.input)) {
            .valid => null,
            .invalid => |error_info| utf8SequenceStart(
                self.input,
                error_info.offset,
            ),
        };

        var source_index: usize = 0;
        while (source_index < self.input.len) {
            if (invalid_utf8_offset) |offset| {
                if (source_index >= offset) {
                    self.source_error = error.InvalidUtf8;
                    self.source_failure_offset = offset;
                    return;
                }
            }
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
        self.position = findXmlTextEnd(self.input, start);
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
            const ascii_end = skipXmlAsciiData(
                self.input,
                cursor,
                end,
                entities,
                forbid_cdata_end,
                forbid_less_than,
            );
            if (ascii_end != cursor) {
                cursor = ascii_end;
                if (cursor >= end) break;
            }
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
            if (!isXmlCharacter(decoded.codepoint)) {
                return self.fail(error.InvalidCharacter, cursor);
            }
            cursor += decoded.length;
        }
    }

    fn parseComment(self: *XmlParser) XmlParseError!void {
        const start = self.position;
        var index = start + 4;
        while (index + 2 < self.input.len) : (index += 1) {
            if (self.input[index] == '-' and self.input[index + 1] == '-') {
                if (self.input[index + 2] == '>') {
                    try self.validateData(start + 4, index, false, false, false);
                    try self.emit(.comment, start, index + 3);
                    self.position = index + 3;
                    return;
                }
                return self.fail(error.InvalidComment, index);
            }
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
            try self.validateData(value_start, cursor, false, false, false);
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
            element_word_index = output.count;
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
            try output.updateOpening(
                tape_index,
                if (self_closing) .self_closing_element else .element_start,
                cursor - start,
            );
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
            try output.append(kind, start, end);
        }
    }

    fn fail(self: *XmlParser, err: XmlError, offset: usize) XmlParseError {
        self.failure_offset = @min(offset, self.input.len);
        return err;
    }
};

const XmlPendingOpen = struct {
    active: bool = false,
    start: usize = 0,
    name_start: usize = 0,
    name_end: usize = 0,
    close_start: usize = 0,
    close_end: usize = 0,
    attribute_cursor: usize = 0,
    self_closing: bool = false,
};

pub const Parser = struct {
    max_capacity: usize,
    stack: [xml_max_depth]XmlFrame = undefined,
    state: resident.State = .{},

    pub const InitError = error{InputTooLarge};

    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) InitError!Parser {
        _ = allocator;
        if (max_capacity > std.math.maxInt(u32)) return error.InputTooLarge;
        return .{ .max_capacity = max_capacity };
    }

    pub fn deinit(self: *Parser) void {
        std.debug.assert(!self.state.active);
        self.state.deinit();
        self.* = undefined;
    }
    fn checkInputSize(self: *const Parser, input_len: usize) XmlParseError!void {
        if (input_len > std.math.maxInt(u32)) return error.TapeTooLarge;
        if (self.max_capacity != 0 and input_len > self.max_capacity) {
            return error.CapacityExceeded;
        }
    }

    pub fn initOnDemandDocument(
        self: *Parser,
        input: []const u8,
    ) XmlParseError!XmlOnDemandDocument {
        const lease = try self.state.begin();
        errdefer lease.release();
        try self.checkInputSize(input.len);
        var grammar = XmlParser{
            .input = input,
            .output = null,
            .stack = self.stack[0..],
        };
        grammar.position = if (startsWithAt(input, 0, "\xEF\xBB\xBF")) 3 else 0;
        return .{
            .input = input,
            .lease = lease,
            .grammar = grammar,
        };
    }
};
const XmlResidentFailure = struct {
    err: XmlError,
    offset: usize,
};

pub const XmlOnDemandDocument = struct {
    input: []const u8,
    lease: resident.Lease,
    grammar: XmlParser,
    pending: XmlPendingOpen = .{},
    failure: ?XmlResidentFailure = null,

    pub fn deinit(self: *XmlOnDemandDocument) void {
        self.lease.release();
    }

    fn claim(self: *XmlOnDemandDocument) XmlError!resident.Guard {
        return self.lease.claim();
    }

    pub fn eventReader(self: *XmlOnDemandDocument) XmlError!XmlEventReader {
        const guard = try self.claim();
        return .{
            .document = self,
            .guard = guard,
        };
    }

    pub fn tokenCursor(self: *XmlOnDemandDocument) XmlError!XmlTokenCursor {
        const guard = try self.claim();
        return .{
            .document = self,
            .guard = guard,
        };
    }

    fn nextAttribute(self: *XmlOnDemandDocument) XmlParseError!?XmlEvent {
        const pending = &self.pending;
        var cursor = skipXmlWhitespace(self.input, pending.attribute_cursor);
        if (cursor >= pending.close_start) return null;

        const name_start = cursor;
        const name_end = parseXmlName(self.input, name_start) orelse {
            self.grammar.failure_offset = cursor;
            return error.InvalidAttribute;
        };
        cursor = skipXmlWhitespace(self.input, name_end);
        if (cursor >= pending.close_start or self.input[cursor] != '=') {
            self.grammar.failure_offset = cursor;
            return error.InvalidAttribute;
        }
        cursor = skipXmlWhitespace(self.input, cursor + 1);
        if (cursor >= pending.close_start or
            (self.input[cursor] != '\'' and self.input[cursor] != '"'))
        {
            self.grammar.failure_offset = cursor;
            return error.InvalidAttribute;
        }
        const quote = self.input[cursor];
        const value_start = cursor + 1;
        cursor = value_start;
        while (cursor < pending.close_start and self.input[cursor] != quote) : (cursor += 1) {}
        if (cursor >= pending.close_start) {
            self.grammar.failure_offset = value_start - 1;
            return error.InvalidAttribute;
        }
        const value_end = cursor;
        pending.attribute_cursor = cursor + 1;
        const raw_end = cursor + 1;
        return .{ .attribute = .{
            .raw = self.input[name_start..raw_end],
            .name = self.input[name_start..name_end],
            .value = self.input[value_start..value_end],
            .offset = @intCast(name_start),
        } };
    }

    fn skipPendingAttributes(self: *@This(), guard: *resident.Guard) XmlParseError!void {
        while (self.pending.active) {
            if (try self.nextAttribute()) |_| {
                try guard.advance();
            } else {
                self.pending.active = false;
            }
        }
    }

    fn cacheFailure(self: *@This(), err: XmlError) XmlParseError {
        if (self.failure) |failure| {
            self.grammar.failure_offset = failure.offset;
            self.grammar.position = failure.offset;
            return failure.err;
        }

        var selected_error = err;
        var selected_offset = self.grammar.failure_offset;
        const eager = validateXml(self.input) catch |validation_error| {
            return validation_error;
        };
        if (eager) |diagnostic| {
            selected_error = diagnostic.err;
            selected_offset = diagnostic.byte_offset;
        }

        self.failure = .{
            .err = selected_error,
            .offset = selected_offset,
        };
        self.grammar.failure_offset = selected_offset;
        self.grammar.position = selected_offset;
        return selected_error;
    }

    fn nextEventCore(self: *@This()) XmlParseError!?XmlEvent {
        if (self.failure) |failure| {
            self.grammar.failure_offset = failure.offset;
            self.grammar.position = failure.offset;
            return failure.err;
        }
        return self.nextEventCoreUncached() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.cacheFailure(@errorCast(err));
        };
    }

    fn nextEventCoreUncached(self: *XmlOnDemandDocument) XmlParseError!?XmlEvent {
        if (self.pending.active) {
            if (try self.nextAttribute()) |attribute| return attribute;
            self.pending.active = false;
        }

        while (true) {
            if (self.grammar.position >= self.input.len) {
                if (self.grammar.stack_top != 0) {
                    return self.grammar.fail(
                        error.UnclosedElement,
                        self.grammar.stack[self.grammar.stack_top - 1].open_offset,
                    );
                }
                if (!self.grammar.root_seen) {
                    return self.grammar.fail(error.EmptyDocument, self.input.len);
                }
                return null;
            }

            const start = self.grammar.position;
            if (self.input[start] != '<') {
                const stack_top = self.grammar.stack_top;
                try self.grammar.parseText();
                self.grammar.declaration_allowed = false;
                if (stack_top == 0) continue;
                return .{ .text = .{
                    .raw = self.input[start..self.grammar.position],
                    .offset = @intCast(start),
                } };
            }

            if (startsWithAt(self.input, start, "<!--")) {
                try self.grammar.parseComment();
                self.grammar.declaration_allowed = false;
                return .{ .comment = .{
                    .raw = self.input[start..self.grammar.position],
                    .content = self.input[start + 4 .. self.grammar.position - 3],
                    .offset = @intCast(start),
                } };
            }
            if (startsWithAt(self.input, start, "<![CDATA[")) {
                try self.grammar.parseCdata();
                self.grammar.declaration_allowed = false;
                return .{ .cdata = .{
                    .raw = self.input[start..self.grammar.position],
                    .content = self.input[start + "<![CDATA[".len .. self.grammar.position - 3],
                    .offset = @intCast(start),
                } };
            }
            if (startsWithAt(self.input, start, "<?")) {
                const target_start = start + 2;
                const target_end = parseXmlName(self.input, target_start) orelse {
                    return self.grammar.fail(error.InvalidName, target_start);
                };
                const close = std.mem.indexOfPos(u8, self.input, target_end, "?>") orelse {
                    return self.grammar.fail(error.UnterminatedProcessingInstruction, start);
                };
                try self.grammar.parseProcessingInstruction();
                self.grammar.declaration_allowed = false;
                const data = trimXmlWhitespace(self.input[target_end..close]);
                if (std.mem.eql(u8, self.input[target_start..target_end], "xml")) {
                    return .{ .xml_declaration = .{
                        .raw = self.input[start..self.grammar.position],
                        .offset = @intCast(start),
                    } };
                }
                return .{ .processing_instruction = .{
                    .raw = self.input[start..self.grammar.position],
                    .target = self.input[target_start..target_end],
                    .data = data,
                    .offset = @intCast(start),
                } };
            }
            if (startsWithAt(self.input, start, "</")) {
                const name_start = start + 2;
                const name_end = parseXmlName(self.input, name_start) orelse {
                    return self.grammar.fail(error.InvalidName, name_start);
                };
                try self.grammar.parseClosingElement();
                self.grammar.declaration_allowed = false;
                return .{ .element_end = .{
                    .raw = self.input[start..self.grammar.position],
                    .name = self.input[name_start..name_end],
                    .offset = @intCast(start),
                } };
            }
            if (startsWithAt(self.input, start, "<!")) {
                return self.grammar.fail(error.UnsupportedDeclaration, start);
            }

            const name_start = start + 1;
            const name_end = parseXmlName(self.input, name_start) orelse {
                return self.grammar.fail(error.InvalidName, name_start);
            };
            try self.grammar.parseOpeningElement();
            self.grammar.declaration_allowed = false;
            const close_end = self.grammar.position;
            const self_closing = close_end >= 2 and self.input[close_end - 2] == '/';
            self.pending = .{
                .active = true,
                .start = start,
                .name_start = name_start,
                .name_end = name_end,
                .close_start = close_end - @as(usize, if (self_closing) 2 else 1),
                .close_end = close_end,
                .attribute_cursor = name_end,
                .self_closing = self_closing,
            };
            const event: XmlEvent = if (self_closing)
                .{ .self_closing_element = .{
                    .raw = self.input[start..close_end],
                    .name = self.input[name_start..name_end],
                    .offset = @intCast(start),
                    .self_closing = true,
                } }
            else
                .{ .element_start = .{
                    .raw = self.input[start..close_end],
                    .name = self.input[name_start..name_end],
                    .offset = @intCast(start),
                    .self_closing = false,
                } };
            return event;
        }
    }

    fn peekEventCore(self: *XmlOnDemandDocument) XmlParseError!?XmlEvent {
        const saved_grammar = self.grammar;
        const saved_pending = self.pending;
        const saved_stack_top = self.grammar.stack_top;
        var saved_frame: XmlFrame = undefined;
        if (saved_stack_top < self.grammar.stack.len) {
            saved_frame = self.grammar.stack[saved_stack_top];
        }
        const result = self.nextEventCore() catch |err| {
            self.grammar = saved_grammar;
            self.pending = saved_pending;
            if (saved_stack_top < self.grammar.stack.len) {
                self.grammar.stack[saved_stack_top] = saved_frame;
            }
            if (self.failure) |failure| {
                self.grammar.failure_offset = failure.offset;
                self.grammar.position = failure.offset;
            }
            return err;
        };
        self.grammar = saved_grammar;
        self.pending = saved_pending;
        if (saved_stack_top < self.grammar.stack.len) {
            self.grammar.stack[saved_stack_top] = saved_frame;
        }
        return result;
    }
};

fn trimXmlWhitespace(input: []const u8) []const u8 {
    var start: usize = 0;
    while (start < input.len and isXmlWhitespace(input[start])) : (start += 1) {}
    var end = input.len;
    while (end > start and isXmlWhitespace(input[end - 1])) : (end -= 1) {}
    return input[start..end];
}

fn xmlEventToken(event: XmlEvent) XmlToken {
    return switch (event) {
        .xml_declaration => |value| .{
            .kind = .xml_declaration,
            .raw = value.raw,
            .offset = value.offset,
        },
        .element_start => |value| .{
            .kind = .element_start,
            .raw = value.raw,
            .offset = value.offset,
        },
        .element_end => |value| .{
            .kind = .element_end,
            .raw = value.raw,
            .offset = value.offset,
        },
        .self_closing_element => |value| .{
            .kind = .self_closing_element,
            .raw = value.raw,
            .offset = value.offset,
        },
        .attribute => |value| .{
            .kind = .attribute,
            .raw = value.raw,
            .offset = value.offset,
        },
        .text => |value| .{
            .kind = .text,
            .raw = value.raw,
            .offset = value.offset,
        },
        .cdata => |value| .{
            .kind = .cdata,
            .raw = value.raw,
            .offset = value.offset,
        },
        .comment => |value| .{
            .kind = .comment,
            .raw = value.raw,
            .offset = value.offset,
        },
        .processing_instruction => |value| .{
            .kind = .processing_instruction,
            .raw = value.raw,
            .offset = value.offset,
        },
    };
}

pub const XmlEventReader = struct {
    document: *XmlOnDemandDocument,
    guard: resident.Guard,

    fn ensureFocused(self: *const @This()) XmlError!void {
        try self.guard.check();
    }

    pub fn next(self: *@This()) XmlParseError!?XmlEvent {
        try self.ensureFocused();
        const event = try self.document.nextEventCore();
        if (event != null) try self.guard.advance();
        return event;
    }

    pub fn peek(self: *const @This()) XmlParseError!?XmlEvent {
        try self.ensureFocused();
        return self.document.peekEventCore();
    }
    pub fn skip(self: *@This()) XmlParseError!void {
        const first = try self.next() orelse return;
        switch (first) {
            .element_start => {},
            .self_closing_element => {
                try self.document.skipPendingAttributes(&self.guard);
                return;
            },
            else => return,
        }

        var depth: usize = 1;
        while (depth != 0) {
            const event = try self.next() orelse return error.UnclosedElement;
            switch (event) {
                .element_start => depth += 1,
                .element_end => depth -= 1,
                else => {},
            }
        }
    }
};

pub const XmlTokenCursor = struct {
    document: *XmlOnDemandDocument,
    guard: resident.Guard,

    fn ensureFocused(self: *const @This()) XmlError!void {
        try self.guard.check();
    }

    pub fn peek(self: *const @This()) XmlParseError!?XmlToken {
        try self.ensureFocused();
        const event = try self.document.peekEventCore() orelse return null;
        return xmlEventToken(event);
    }

    pub fn advance(self: *@This()) XmlParseError!?XmlToken {
        try self.ensureFocused();
        const event = try self.document.nextEventCore() orelse return null;
        try self.guard.advance();
        return xmlEventToken(event);
    }

    pub fn skipChild(self: *@This()) XmlParseError!void {
        const first = try self.peek() orelse return;
        switch (first.kind) {
            .self_closing_element => {
                _ = try self.advance();
                try self.document.skipPendingAttributes(&self.guard);
                return;
            },
            .element_start => {},
            else => {
                _ = try self.advance();
                return;
            },
        }

        var depth: usize = 0;
        while (true) {
            const token = try self.advance() orelse return error.UnclosedElement;
            switch (token.kind) {
                .element_start => depth += 1,
                .self_closing_element => {},
                .element_end => {
                    if (depth == 0) return error.UnexpectedToken;
                    depth -= 1;
                    if (depth == 0) return;
                },
                else => {},
            }
        }
    }
};

pub const OnDemandDocument = XmlOnDemandDocument;
pub const Event = XmlEvent;
pub const EventReader = XmlEventReader;
pub const TokenCursor = XmlTokenCursor;
pub const Token = XmlToken;

pub fn initOnDemandDocument(
    parser: *Parser,
    input: []const u8,
) XmlParseError!XmlOnDemandDocument {
    return parser.initOnDemandDocument(input);
}

pub fn initStreamIndexer(
    allocator: std.mem.Allocator,
    chunk_len: usize,
) XmlStreamIndexer.InitError!XmlStreamIndexer {
    return XmlStreamIndexer.init(allocator, chunk_len);
}
// Text candidate: find the next markup delimiter without decoding ordinary bytes.
fn findXmlTextEnd(input: []const u8, start: usize) usize {
    const vector_len = simd.default_vector_len;
    const Mask = simd.Mask(vector_len);
    const MaskStorage = if (vector_len <= 8)
        u8
    else if (vector_len <= 16)
        u16
    else if (vector_len <= 32)
        u32
    else if (vector_len <= 64)
        u64
    else
        @Int(.unsigned, (vector_len + 7) / 8 * 8);
    const logical_mask: MaskStorage = @intCast(std.math.maxInt(Mask));
    var cursor = start;
    while (input.len - cursor >= vector_len) {
        const block: simd.Vec(vector_len, u8) = input[cursor..][0..vector_len].*;
        const less_than: Mask = simd.matchByte(vector_len, block, '<');
        // Non-byte-aligned masks have spare storage bits; clear them before `@ctz`.
        const less_than_storage =
            @as(MaskStorage, @intCast(less_than)) & logical_mask;
        if (less_than_storage != 0) {
            return cursor + @as(usize, @intCast(@ctz(less_than_storage)));
        }
        cursor += vector_len;
    }
    while (cursor < input.len and input[cursor] != '<') : (cursor += 1) {}
    return cursor;
}

// Text candidate: stop before bytes that require entity, delimiter, or UTF-8 checks.
fn skipXmlAsciiData(
    input: []const u8,
    start: usize,
    end: usize,
    entities: bool,
    forbid_cdata_end: bool,
    forbid_less_than: bool,
) usize {
    var cursor = start;
    while (cursor < end) {
        const byte = input[cursor];
        if (byte >= 0x20 and byte <= 0x7E) {
            if (entities and byte == '&') break;
            if (forbid_cdata_end and byte == ']') break;
            if (forbid_less_than and byte == '<') break;
            cursor += 1;
            continue;
        }
        if (byte == '\t' or byte == '\n' or byte == '\r') {
            cursor += 1;
            continue;
        }
        break;
    }
    return cursor;
}
// Name candidate: classify ASCII bytes directly and retain checked Unicode fallback.
fn parseXmlName(input: []const u8, start: usize) ?usize {
    if (start >= input.len) return null;

    var cursor = start;
    const first_byte = input[cursor];
    if (first_byte < 0x80) {
        if (!isAsciiXmlNameStart(first_byte)) return null;
        cursor += 1;
    } else {
        const decoded = decodeXml(input, cursor) orelse return null;
        if (!isXmlNameStart(decoded.codepoint)) return null;
        cursor += decoded.length;
    }

    while (cursor < input.len) {
        const byte = input[cursor];
        if (byte < 0x80) {
            if (!isAsciiXmlNameChar(byte)) break;
            cursor += 1;
            continue;
        }
        const decoded = decodeXml(input, cursor) orelse return cursor;
        if (!isXmlNameChar(decoded.codepoint)) break;
        cursor += decoded.length;
    }
    return cursor;
}

fn isAsciiXmlNameStart(byte: u8) bool {
    return byte == ':' or byte == '_' or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z');
}

fn isAsciiXmlNameChar(byte: u8) bool {
    return isAsciiXmlNameStart(byte) or byte == '-' or byte == '.' or
        (byte >= '0' and byte <= '9');
}

// Attribute candidate: retain exact name equality while accelerating bounded value skips.
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
        const quote_end = std.mem.indexOfScalar(
            u8,
            input[cursor..current_start],
            quote,
        ) orelse return false;
        cursor += quote_end + 1;
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

fn utf8SequenceStart(input: []const u8, invalid_offset: usize) usize {
    var sequence_start = @min(invalid_offset, input.len);
    var continuation_count: usize = 0;
    while (sequence_start > 0 and
        input[sequence_start - 1] >= 0x80 and
        input[sequence_start - 1] <= 0xBF)
    {
        sequence_start -= 1;
        continuation_count += 1;
    }
    if (sequence_start == 0) return invalid_offset;

    const lead = input[sequence_start - 1];
    const expected_continuations: usize = switch (lead) {
        0xC0...0xDF => 1,
        0xE0...0xEF => 2,
        0xF0...0xF4 => 3,
        else => 0,
    };
    if (continuation_count < expected_continuations) return sequence_start - 1;
    return invalid_offset;
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

fn expectXmlResidentDiagnostic(
    expected_error: XmlError,
    expected_offset: usize,
    input: []const u8,
) !void {
    const eager = try expectXmlDiagnostic(expected_error, input);
    try testing.expectEqual(expected_offset, eager.byte_offset);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();

    for (0..input.len) |_| {
        if (reader.next()) |event| {
            if (event == null) return error.ExpectedXmlDiagnostic;
        } else |actual_error| {
            try testing.expectEqual(
                @as(anyerror, eager.err),
                @as(anyerror, actual_error),
            );
            try testing.expectEqual(eager.byte_offset, document.grammar.failure_offset);
            if (reader.next()) |_| {
                return error.ExpectedXmlDiagnostic;
            } else |retry_error| {
                try testing.expectEqual(
                    @as(anyerror, eager.err),
                    @as(anyerror, retry_error),
                );
            }
            try testing.expectEqual(eager.byte_offset, document.grammar.failure_offset);
            return;
        }
    }
    return error.ExpectedXmlDiagnostic;
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

test "XML fast paths preserve Unicode name and text boundaries" {
    const input = "<\xC3\xA9 attr\xC3\xA9=\"v\">\xC3\xA9&amp;ok</\xC3\xA9>";
    try testing.expectEqual(@as(?XmlDiagnostic, null), try validateXml(input));
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
    const cdata_end = try expectXmlDiagnostic(error.InvalidCharacter, "<a>text]]>tail</a>");
    try testing.expectEqual(@as(usize, 7), cdata_end.byte_offset);
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

test "XmlDocument rejects forged spans and kinds during navigation" {
    const empty_input = "<a/>";
    var empty = try buildXmlTape(testing.allocator, empty_input);
    defer empty.deinit(testing.allocator);

    empty.tape[0].payload = 0;
    try testing.expectError(error.InvalidTapeOrder, empty.sourceSpan(empty_input, 0));
    try testing.expectError(error.InvalidTapeOrder, empty.root(empty_input));
    empty.tape[0].payload = empty_input.len;

    var empty_cursor = try empty.root(empty_input);
    empty.tape[0].payload = 0;
    try testing.expectError(error.InvalidTapeOrder, empty_cursor.peek());

    const nested_input = "<a><b/></a>";
    var nested = try buildXmlTape(testing.allocator, nested_input);
    defer nested.deinit(testing.allocator);
    var nested_cursor = try nested.root(nested_input);
    _ = try nested_cursor.advance();
    nested.tape[1].kind = @intFromEnum(XmlTapeKind.element_end);
    try testing.expectError(error.InvalidTapeOrder, nested_cursor.skipChild());
}

fn checkXmlIndexAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "<root a=\"b\"><child/></root>";
    var index = try indexXml(allocator, input);
    defer index.deinit(allocator);
}

fn checkXmlTapeAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "<root a=\"b\"><child/></root>";
    var document = try buildXmlTape(allocator, input);
    defer document.deinit(allocator);
}

fn checkXmlStreamAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "<root a=\"b\"><child/></root>";
    var stream = try XmlStreamIndexer.init(allocator, 1);
    defer stream.deinit();
    try stream.feed(input);
    try stream.finish();
    var index = stream.take();
    defer index.deinit(allocator);
}

test "XML index and tape operations propagate allocation failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkXmlIndexAllocationFailure,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkXmlTapeAllocationFailure,
        .{},
    );
}

test "XML stream operations propagate allocation failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkXmlStreamAllocationFailure,
        .{},
    );
}

const XmlFaultingReader = struct {
    reader: std.Io.Reader,
    input: []const u8,
    offset: usize = 0,
    fail_at: usize,

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
    };

    fn init(input: []const u8, fail_at: usize, buffer: []u8) XmlFaultingReader {
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

test "XML resident reader yields native zero-copy events" {
    const input =
        "<root a='v'>text<!--comment--><![CDATA[data]]><?work yes?></root>";
    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();

    const root = (try reader.next()).?;
    try testing.expectEqualStrings("<root a='v'>", root.raw());
    try testing.expect(root.raw().ptr == input.ptr);
    switch (root) {
        .element_start => |element| {
            try testing.expectEqualStrings("root", element.name);
            try testing.expect(!element.self_closing);
        },
        else => return error.UnexpectedXmlEvent,
    }

    switch ((try reader.next()).?) {
        .attribute => |attribute| {
            try testing.expectEqualStrings("a='v'", attribute.raw);
            try testing.expectEqualStrings("a", attribute.name);
            try testing.expectEqualStrings("v", attribute.value);
            try testing.expect(attribute.raw.ptr == input.ptr + 6);
        },
        else => return error.UnexpectedXmlEvent,
    }
    switch ((try reader.next()).?) {
        .text => |text| try testing.expectEqualStrings("text", text.raw),
        else => return error.UnexpectedXmlEvent,
    }
    switch ((try reader.next()).?) {
        .comment => |comment| {
            try testing.expectEqualStrings("<!--comment-->", comment.raw);
            try testing.expectEqualStrings("comment", comment.content);
        },
        else => return error.UnexpectedXmlEvent,
    }
    switch ((try reader.next()).?) {
        .cdata => |cdata| {
            try testing.expectEqualStrings("<![CDATA[data]]>", cdata.raw);
            try testing.expectEqualStrings("data", cdata.content);
        },
        else => return error.UnexpectedXmlEvent,
    }
    switch ((try reader.next()).?) {
        .processing_instruction => |instruction| {
            try testing.expectEqualStrings("work", instruction.target);
            try testing.expectEqualStrings("yes", instruction.data);
        },
        else => return error.UnexpectedXmlEvent,
    }
    switch ((try reader.next()).?) {
        .element_end => |element| try testing.expectEqualStrings("root", element.name),
        else => return error.UnexpectedXmlEvent,
    }
    try testing.expectEqual(@as(?XmlEvent, null), try reader.next());
}

test "XML resident source validation matches eager in every grammar region" {
    const Case = struct {
        input: []const u8,
        expected_error: XmlError,
        expected_offset: usize,
    };
    const cases = [_]Case{
        .{ .input = "<a>\x00</a>", .expected_error = error.InvalidCharacter, .expected_offset = 3 },
        .{ .input = "<a x='\x00'/>", .expected_error = error.InvalidCharacter, .expected_offset = 6 },
        .{ .input = "<a\x00/>", .expected_error = error.InvalidCharacter, .expected_offset = 2 },
        .{ .input = "<a><!--\x00--></a>", .expected_error = error.InvalidCharacter, .expected_offset = 7 },
        .{ .input = "<a><![CDATA[\x00]]></a>", .expected_error = error.InvalidCharacter, .expected_offset = 12 },
        .{ .input = "<a><?work \x00?></a>", .expected_error = error.InvalidCharacter, .expected_offset = 10 },
        .{ .input = "<a>\x01</a>", .expected_error = error.InvalidCharacter, .expected_offset = 3 },
        .{ .input = "<a x='\x01'/>", .expected_error = error.InvalidCharacter, .expected_offset = 6 },
        .{ .input = "<a\x01/>", .expected_error = error.InvalidCharacter, .expected_offset = 2 },
        .{ .input = "<a><!--\x01--></a>", .expected_error = error.InvalidCharacter, .expected_offset = 7 },
        .{ .input = "<a><![CDATA[\x01]]></a>", .expected_error = error.InvalidCharacter, .expected_offset = 12 },
        .{ .input = "<a><?work \x01?></a>", .expected_error = error.InvalidCharacter, .expected_offset = 10 },
        .{ .input = "<a>\xEF\xBF\xBF</a>", .expected_error = error.InvalidCharacter, .expected_offset = 3 },
        .{ .input = "<a x='\xEF\xBF\xBF'/>", .expected_error = error.InvalidCharacter, .expected_offset = 6 },
        .{ .input = "<a\xEF\xBF\xBF/>", .expected_error = error.InvalidCharacter, .expected_offset = 2 },
        .{ .input = "<a><!--\xEF\xBF\xBF--></a>", .expected_error = error.InvalidCharacter, .expected_offset = 7 },
        .{ .input = "<a><![CDATA[\xEF\xBF\xBF]]></a>", .expected_error = error.InvalidCharacter, .expected_offset = 12 },
        .{ .input = "<a><?work \xEF\xBF\xBF?></a>", .expected_error = error.InvalidCharacter, .expected_offset = 10 },
        .{ .input = "<a>\xFF</a>", .expected_error = error.InvalidUtf8, .expected_offset = 3 },
        .{ .input = "<a x='\xFF'/>", .expected_error = error.InvalidUtf8, .expected_offset = 6 },
        .{ .input = "<a\xFF/>", .expected_error = error.InvalidUtf8, .expected_offset = 2 },
        .{ .input = "<a><!--\xFF--></a>", .expected_error = error.InvalidUtf8, .expected_offset = 7 },
        .{ .input = "<a><![CDATA[\xFF]]></a>", .expected_error = error.InvalidUtf8, .expected_offset = 12 },
        .{ .input = "<a><?work \xFF?></a>", .expected_error = error.InvalidUtf8, .expected_offset = 10 },
    };

    for (cases) |case| {
        try expectXmlResidentDiagnostic(
            case.expected_error,
            case.expected_offset,
            case.input,
        );
    }
}

test "XML resident source arbitration preserves earlier eager grammar errors" {
    const input = "<a>\xFF";
    try expectXmlResidentDiagnostic(error.UnclosedElement, 0, input);
}

test "XML resident closes the declaration window after a construct" {
    const cases = [_]struct { input: []const u8, offset: usize }{
        .{ .input = "\xEF\xBB\xBF<a/><?xml version='1.0'?>", .offset = 7 },
        .{ .input = "\xEF\xBB\xBF<!--x--><?xml version='1.0'?><a/>", .offset = 11 },
        .{ .input = "\xEF\xBB\xBF \t<?xml version='1.0'?><a/>", .offset = 5 },
    };
    for (cases) |case| {
        try expectXmlResidentDiagnostic(error.InvalidDeclaration, case.offset, case.input);
    }
}
/// Fused entity decode + normalization pass.
/// Decodes each &...; exactly once, returning the codepoint.
/// Also handles the \r\n context for the caller (whitespace normalization).
///
/// Returns the codepoint and the next index past the entity.
/// The caller is responsible for \r\n mapping; we just return the codepoint
// and let the caller decide based on in_attribute context.
pub fn decodeEntityAndNormalize(
    input: []const u8,
    start: usize,
    end: usize,
    in_attribute: bool,
) !{ .codepoint = u21, .next = usize, .should_map_cr = bool } {
    if (start >= end or input[start] != '&') return error.InvalidEntity;
    
    // Single pass: find ';'
    var cursor = start + 1;
    while (cursor < end and input[cursor] != ';') : (cursor += 1) {}
    if (cursor >= end or cursor == start + 1) return error.InvalidEntity;
    
    const body = input[start + 1 .. cursor];
    
    // Check predefined entities (single eql chain)
    var codepoint: u21 = undefined;
    var decoded = parsePredefinedEntity(body);
    if (decoded) |cp| {
        codepoint = cp;
    } else if (body.len >= 2 and body[0] == '#') {
        // Numeric entity: parse digits
        var digit_start: usize = start + 2;
        var base: u32 = 10;
        if (digit_start < cursor and input[digit_start] == 'x') {
            base = 16;
            digit_start += 1;
        }
        if (digit_start == cursor) return error.InvalidEntity;
        var codep: u32 = 0;
        while (digit_start < cursor) : (digit_start += 1) {
            const digit = xmlDigit(input[digit_start], base) orelse return error.InvalidEntity;
            if (codep > (std.math.maxInt(u32) - digit) / base) return error.InvalidEntity;
            codep = codep * base + digit;
        }
        if (codep > std.math.maxInt(u21) or !isXmlCharacter(@intCast(codep))) return error.InvalidEntity;
        codepoint = @intCast(codep);
    } else {
        return error.InvalidEntity;
    }
    
    // Determine if we should map \r based on entity position
    // The caller will handle \r\n mapping; we just return the codepoint
    // and let the caller decide based on in_attribute context
    return .{ .codepoint = codepoint, .next = cursor + 1, .should_map_cr = false };
}

fn parseXmlEntity(
test "XML resident grammar stays lazy and preserves first-error policy" {
    const malformed_suffix = "<root><child/></root><1/>";
    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();
    var document = try initOnDemandDocument(&parser, malformed_suffix);
    defer document.deinit();
    var reader = try document.eventReader();

    try testing.expect((try reader.next()) != null);
    try testing.expect((try reader.next()) != null);
    try testing.expect((try reader.next()) != null);
    try testing.expectError(error.InvalidName, reader.next());
}

test "XML resident grammar reports matching root attribute and entity errors" {
    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();

    var mismatch = try initOnDemandDocument(&parser, "<a><b></a>");
    var mismatch_reader = try mismatch.eventReader();
    try testing.expect((try mismatch_reader.next()) != null);
    try testing.expect((try mismatch_reader.next()) != null);
    try testing.expectError(error.MismatchedTag, mismatch_reader.next());
    mismatch.deinit();

    var duplicate = try initOnDemandDocument(&parser, "<a x='1' x='2'/>");
    var duplicate_reader = try duplicate.eventReader();
    try testing.expectError(error.DuplicateAttribute, duplicate_reader.next());
    duplicate.deinit();

    var entity = try initOnDemandDocument(&parser, "<a>&bad;</a>");
    var entity_reader = try entity.eventReader();
    try testing.expect((try entity_reader.next()) != null);
    try testing.expectError(error.InvalidEntity, entity_reader.next());
    entity.deinit();

    var roots = try initOnDemandDocument(&parser, "<a/><b/>");
    var roots_reader = try roots.eventReader();
/// Fused entity decode + normalize into a single pass.
/// Decodes each &...; exactly once, eliminating the second ;-scan and
/// second eql chain. Returns the codepoint and next index.
///
/// Guarantees: single stream with overflow-checked length accumulation,
/// reserve 8B length-prefix slot or dual-accumulate with single addCodepoint stream.
pub fn decodeEntityFused(
    input: []const u8,
    start: usize,
    end: usize,
    in_attribute: bool,
) !{ .codepoint = u21, .next = usize } {
    if (start >= end or input[start] != '&') return error.InvalidEntity;
    
    // Single pass: find ';' and decode in one stream
    var cursor = start + 1;
    // Phase 1: find ';' (length accumulation)
    while (cursor < end and input[cursor] != ';') : (cursor += 1) {}
    if (cursor >= end or cursor == start + 1) return error.InvalidEntity;
    
    const body = input[start + 1 .. cursor];
    
    // Phase 2: decode entity (predefined-eql + digit accumulate)
    // Predefined entities (single eql chain)
    var codepoint: u21 = undefined;
    if (body.len == 3 and body[0] == 'a' and body[1] == 'm' and body[2] == 'p') {
        codepoint = '&';
    } else if (body.len == 2 and body[0] == 'l' and body[1] == 't') {
        codepoint = '<';
    } else if (body.len == 2 and body[0] == 'g' and body[1] == 't') {
        codepoint = '>';
    } else if (body.len == 4 and body[0] == 'a' and body[1] == 'p' and body[2] == 'o' and body[3] == 's') {
        codepoint = '\'';
    } else if (body.len == 4 and body[0] == 'q' and body[1] == 'u' and body[2] == 'o' and body[3] == 't') {
        codepoint = '"';
    } else if (body.len >= 2 and body[0] == '#') {
        // Numeric entity: parse digits
        var digit_start: usize = 0; // relative to body
        var base: u32 = 10;
        // Find digit start within body
        var abs_digit_start: usize = start + 2;
        if (abs_digit_start < cursor and input[abs_digit_start] == 'x') {
            base = 16;
            abs_digit_start += 1;
        }
        if (abs_digit_start >= cursor) return error.InvalidEntity;
        var codep: u32 = 0;
        // Single pass digit accumulation with overflow check
        while (abs_digit_start < cursor) : (abs_digit_start += 1) {
            const digit = xmlDigit(input[abs_digit_start], base) orelse return error.InvalidEntity;
            if (codep > (std.math.maxInt(u32) - digit) / base) return error.InvalidEntity;
            codep = codep * base + digit;
        }
        if (codep > std.math.maxInt(u21) or !isXmlCharacter(@intCast(codep))) {
            return error.InvalidEntity;
        }
        codepoint = @intCast(codep);
    } else {
        return error.InvalidEntity;
    }
    
    return .{ .codepoint = codepoint, .next = cursor + 1 };
}

 fn parseXmlEntity(
/// Fused entity decode + normalize into a single pass.
/// Decodes each &...; exactly once, eliminating the second ;-scan and
/// second eql chain. Returns the codepoint and next index.
///
/// Guarantees: single stream with overflow-checked length accumulation,
/// reserve 8B length-prefix slot or dual-accumulate with single addCodepoint stream.
pub fn decodeEntityFused(
    input: []const u8,
    start: usize,
    end: usize,
    in_attribute: bool,
) !{ .codepoint = u21, .next = usize } {
    if (start >= end or input[start] != '&') return error.InvalidEntity;
    
    // Single pass: find ';' and decode in one stream
    var cursor = start + 1;
    // Phase 1: find ';' (length accumulation)
    while (cursor < end and input[cursor] != ';') : (cursor += 1) {}
    if (cursor >= end or cursor == start + 1) return error.InvalidEntity;
    
    const body = input[start + 1 .. cursor];
    
    // Phase 2: decode entity (predefined-eql + digit accumulate)
    // Predefined entities (single eql chain)
    var codepoint: u21 = undefined;
    if (body.len == 3 and body[0] == 'a' and body[1] == 'm' and body[2] == 'p') {
        codepoint = '&';
    } else if (body.len == 2 and body[0] == 'l' and body[1] == 't') {
        codepoint = '<';
    } else if (body.len == 2 and body[0] == 'g' and body[1] == 't') {
        codepoint = '>';
    } else if (body.len == 4 and body[0] == 'a' and body[1] == 'p' and body[2] == 'o' and body[3] == 's') {
        codepoint = '\'';
    } else if (body.len == 4 and body[0] == 'q' and body[1] == 'u' and body[2] == 'o' and body[3] == 't') {
        codepoint = '"';
    } else if (body.len >= 2 and body[0] == '#') {
        // Numeric entity: parse digits
        var digit_start: usize = start + 2;
        var base: u32 = 10;
        if (digit_start < cursor and input[digit_start] == 'x') {
            base = 16;
            digit_start += 1;
        }
        if (digit_start == cursor) return error.InvalidEntity;
        var codep: u32 = 0;
        // Single pass digit accumulation with overflow check
        while (digit_start < cursor) : (digit_start += 1) {
            const digit = xmlDigit(input[digit_start], base) orelse return error.InvalidEntity;
            if (codep > (std.math.maxInt(u32) - digit) / base) return error.InvalidEntity;
            codep = codep * base + digit;
        }
        if (codep > std.math.maxInt(u21) or !isXmlCharacter(@intCast(codep))) {
            return error.InvalidEntity;
        }
        codepoint = @intCast(codep);
    } else {
        return error.InvalidEntity;
    }
    
    return .{ .codepoint = codepoint, .next = cursor + 1 };
}

 fn xmlDigit(byte: u8, base: u32) ?u32 {
    roots.deinit();
}

test "XML resident failures are sticky across copied readers and cursors" {
    const input = "<a>&bad;</a>";

    {
        var parser = try Parser.init(testing.allocator, input.len);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var reader = try document.eventReader();
        _ = try reader.next();
        var copied_reader = reader;

        try testing.expectError(error.InvalidEntity, reader.next());
        try testing.expectEqual(@as(usize, 3), document.grammar.position);
        try testing.expectError(error.InvalidEntity, copied_reader.next());
        try testing.expectEqual(@as(usize, 3), document.grammar.position);
    }

    {
        var parser = try Parser.init(testing.allocator, input.len);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var cursor = try document.tokenCursor();
        _ = try cursor.advance();
        var copied_cursor = cursor;

        try testing.expectError(error.InvalidEntity, cursor.advance());
        try testing.expectEqual(@as(usize, 3), document.grammar.position);
        try testing.expectError(error.InvalidEntity, copied_cursor.advance());
        try testing.expectEqual(@as(usize, 3), document.grammar.position);
    }
}

test "XML resident event skip consumes the next element subtree" {
    const input = "<root><child><leaf/></child><tail/></root>";
    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();

    switch ((try reader.next()).?) {
        .element_start => {},
        else => return error.UnexpectedXmlEvent,
    }
    try reader.skip();
    switch ((try reader.next()).?) {
        .self_closing_element => |event| {
            try testing.expectEqualStrings("<tail/>", event.raw);
        },
        else => return error.UnexpectedXmlEvent,
    }
    switch ((try reader.next()).?) {
        .element_end => |event| {
            try testing.expectEqualStrings("</root>", event.raw);
        },
        else => return error.UnexpectedXmlEvent,
    }
    try testing.expectEqual(@as(?XmlEvent, null), try reader.next());
}

test "XML self-closing skips consume attributes in every navigation API" {
    const input = "<r><a x='1'/><b/></r>";

    {
        var document = try buildXmlTape(testing.allocator, input);
        defer document.deinit(testing.allocator);
        var cursor = try document.root(input);
        _ = try cursor.advance();
        try cursor.skipChild();
        try testing.expectEqualStrings("<b/>", (try cursor.peek()).?.raw);
    }

    {
        var parser = try Parser.init(testing.allocator, input.len);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var reader = try document.eventReader();
        _ = try reader.next();
        try reader.skip();
        try testing.expectEqualStrings("<b/>", (try reader.next()).?.raw());
    }

    {
        var parser = try Parser.init(testing.allocator, input.len);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var cursor = try document.tokenCursor();
        _ = try cursor.advance();
        try cursor.skipChild();
        try testing.expectEqualStrings("<b/>", (try cursor.peek()).?.raw);
    }
}

test "XML resident cursor peeks and validates subtree skips" {
    const input = "<root><a x='1'><b/>text</a><c/></root>";
    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var cursor = try document.tokenCursor();

    const root = (try cursor.peek()).?;
    try testing.expectEqual(XmlTapeKind.element_start, root.kind);
    try testing.expectEqualStrings("<root>", root.raw);
    try testing.expectEqualStrings(root.raw, (try cursor.advance()).?.raw);

    try testing.expectEqualStrings("<a x='1'>", (try cursor.peek()).?.raw);
    try cursor.skipChild();
    try testing.expectEqualStrings("<c/>", (try cursor.peek()).?.raw);
    try cursor.skipChild();
    try testing.expectEqual(XmlTapeKind.element_end, (try cursor.advance()).?.kind);
    try testing.expectEqual(@as(?XmlToken, null), try cursor.peek());
}

test "XML resident lifecycle rejects active stale copied and oversized use" {
    const input = "<root/>";
    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, input);
    try testing.expectError(error.DocumentActive, initOnDemandDocument(&parser, input));
    var reader = try document.eventReader();
    try testing.expectError(error.FocusAlreadyClaimed, document.tokenCursor());
    var copied_reader = reader;
    try testing.expect((try reader.next()) != null);
    try testing.expectError(error.OutOfOrderIteration, copied_reader.next());
    document.deinit();
    try testing.expectError(error.DocumentReleased, reader.next());

    var reused = try initOnDemandDocument(&parser, input);
    reused.deinit();

    var fixed = try Parser.init(testing.allocator, input.len - 1);
    defer fixed.deinit();
    try testing.expectError(error.CapacityExceeded, initOnDemandDocument(&fixed, input));
}

test "XmlDocument root cursor is source-checked and skips a validated subtree" {
    const input = "<?before ok?><!--lead--><root><child/></root>";
    var document = try buildXmlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    try testing.expectEqualStrings("<root>", (try cursor.peek()).?.raw);
    try cursor.skipChild();
    try testing.expectEqual(@as(?XmlToken, null), try cursor.peek());

    const wrong = "<?before no?><!--lead--><root><child/></root>";
    try testing.expectEqual(input.len, wrong.len);
    try testing.expectError(error.SourceMismatch, document.root(wrong));
}

test "XML stream reader lifecycle retains no source bytes" {
    const input = "<root><!--x--><![CDATA[y]]><child a='v'/></root>";
    var reader = std.Io.Reader.fixed(input);
    var stream = try initStreamIndexer(testing.allocator, 3);
    defer stream.deinit();
    try stream.feedFrom(&reader);
    try testing.expectError(error.AlreadyFinished, stream.feed("x"));
    var first = stream.take();
    defer first.deinit(testing.allocator);

    var expected = try indexXml(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + 3],
        first.indexes[0 .. first.count + 3],
    );
    try testing.expectEqualSlices(
        XmlTokenKind,
        expected.kinds[0..expected.count],
        first.kinds[0..first.count],
    );

    stream.reset();
    try stream.feed("<next/>");
    try stream.finish();
    var second = stream.take();
    defer second.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), second.count);
}

test "XML stream reader propagates errors after consuming buffered input" {
    const input = "<root/>";
    var source_buffer: [2]u8 = undefined;
    var reader = XmlFaultingReader.init(input, input.len, &source_buffer);
    var stream = try initStreamIndexer(testing.allocator, 2);
    defer stream.deinit();

    try testing.expectError(error.ReadFailed, stream.feedFrom(&reader.reader));
    try testing.expect(!stream.finished);
    try testing.expectEqual(input.len, stream.input_len);
    try stream.finish();
    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), actual.count);
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}
