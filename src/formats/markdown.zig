const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const resident = @import("../core/resident.zig");
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

    pub fn sourceSpan(
        self: *const MarkdownStructuralIndex,
        token_index: usize,
        input: []const u8,
    ) ?[]const u8 {
        if (token_index >= self.count or
            token_index >= self.indexes.len or
            token_index >= self.kinds.len)
        {
            return null;
        }
        const offset: usize = @intCast(self.indexes[token_index]);
        if (offset >= input.len) return null;
        if (!markdownSourceMatchesKind(input[offset], self.kinds[token_index])) return null;
        const length = markdownMarkerLength(input, offset, self.kinds[token_index]);
        if (length > input.len - offset) return null;
        return input[offset .. offset + length];
    }
};

const MarkdownIndexSink = struct {
    indexes: *stage1.StructuralIndex,
    kinds: []MarkdownTokenKind,

    fn append(self: *@This(), offset: usize, kind: MarkdownTokenKind) void {
        appendToken(self.indexes, self.kinds, offset, kind);
    }
};

const markdown_tape_capacity_initial: usize = 4096;
const MarkdownTapeSinkError = std.mem.Allocator.Error || error{TapeTooLarge};

const MarkdownTapeSink = struct {
    allocator: std.mem.Allocator,
    tape: *std.ArrayList(MarkdownTapeWord),
    input: []const u8,
    capacity_max: usize,
    failure: ?MarkdownTapeSinkError = null,

    fn append(self: *@This(), offset: usize, kind: MarkdownTokenKind) void {
        if (self.failure != null) return;
        const length = markdownMarkerLength(self.input, offset, kind);
        if (length > std.math.maxInt(u24)) {
            self.failure = error.TapeTooLarge;
            return;
        }
        if (self.tape.items.len == self.tape.capacity) {
            if (self.tape.capacity == self.capacity_max) {
                self.failure = error.TapeTooLarge;
                return;
            }
            self.grow() catch |err| {
                self.failure = err;
                return;
            };
        }
        self.tape.appendAssumeCapacity(.{
            .kind = @intFromEnum(kind),
            .payload = @intCast(length),
            .offset = @intCast(offset),
        });
    }

    fn grow(self: *@This()) std.mem.Allocator.Error!void {
        assert(self.tape.items.len == self.tape.capacity);
        assert(self.tape.capacity < self.capacity_max);
        const doubled_capacity = std.math.mul(
            usize,
            self.tape.capacity,
            2,
        ) catch self.capacity_max;
        const new_capacity = @min(
            self.capacity_max,
            @max(markdown_tape_capacity_initial, doubled_capacity),
        );
        assert(new_capacity > self.tape.capacity);
        try self.tape.ensureTotalCapacityPrecise(self.allocator, new_capacity);
        assert(self.tape.capacity == new_capacity);
    }
};

const MarkdownResidentSink = struct {
    indexes: []u32,
    kinds: []MarkdownTokenKind,
    count: *usize,

    fn append(self: *@This(), offset: usize, kind: MarkdownTokenKind) void {
        assert(self.count.* < self.indexes.len);
        assert(self.count.* < self.kinds.len);
        self.indexes[self.count.*] = @intCast(offset);
        self.kinds[self.count.*] = kind;
        self.count.* += 1;
    }
};

const MarkdownValidationSink = struct {
    input: []const u8,
    structural_index: *const MarkdownStructuralIndex,
    token_index: usize = 0,
    diagnostic: ?MarkdownDiagnostic = null,

    fn append(self: *@This(), offset: usize, kind: MarkdownTokenKind) void {
        if (self.diagnostic != null) return;
        if (self.token_index >= self.structural_index.count) {
            self.diagnostic = markdownDiagnosticAt(self.input, error.InvalidTokenIndex, offset);
            return;
        }

        const supplied_offset: usize = @intCast(self.structural_index.indexes[self.token_index]);
        if (supplied_offset != offset) {
            self.diagnostic = markdownDiagnosticAt(self.input, error.InvalidTokenIndex, supplied_offset);
            return;
        }
        if (self.structural_index.kinds[self.token_index] != kind) {
            self.diagnostic = markdownDiagnosticAt(self.input, error.InvalidTokenKind, offset);
            return;
        }
        self.token_index += 1;
    }

    fn finish(self: *@This()) void {
        if (self.diagnostic != null or self.token_index >= self.structural_index.count) return;
        const offset: usize = @intCast(self.structural_index.indexes[self.token_index]);
        self.diagnostic = markdownDiagnosticAt(self.input, error.InvalidTokenKind, offset);
    }
};
const MarkdownTapeValidationSink = struct {
    tape: []const MarkdownTapeWord,
    count: usize = 0,
    diagnostic: ?MarkdownNavigationError = null,

    fn append(self: *@This(), offset: usize, kind: MarkdownTokenKind) void {
        if (self.diagnostic != null) return;
        if (self.count >= self.tape.len) {
            self.diagnostic = error.InvalidTapeOrder;
            return;
        }
        const word = self.tape[self.count];
        if (word.offset != offset or word.tapeKind() != kind) {
            self.diagnostic = error.InvalidTapeOrder;
            return;
        }
        self.count += 1;
    }

    fn finish(self: *@This()) MarkdownNavigationError!void {
        if (self.diagnostic) |diagnostic| return diagnostic;
        if (self.count != self.tape.len) return error.InvalidTapeOrder;
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
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);
    const kinds = try allocator.alloc(MarkdownTokenKind, input.len);
    errdefer allocator.free(kinds);

    var sink = MarkdownIndexSink{
        .indexes = &indexes,
        .kinds = kinds,
    };
    scanMarkdown(VLEN, input, &sink);
    try indexes.finish(input.len);

    return .{
        .indexes = indexes.indexes,
        .kinds = kinds,
        .count = indexes.count,
    };
}

/// Incrementally indexes Markdown from arbitrary byte chunks.
///
/// The indexer owns only the unfinished line and the structural output. A
/// completed line is consumed before `feed` returns, while `finish` consumes
/// the final unterminated line and writes the structural sentinels.
pub const MarkdownStreamIndexer = struct {
    allocator: std.mem.Allocator,
    line: std.ArrayList(u8) = .empty,
    line_start_offset: usize = 0,
    input_len: usize = 0,
    pending_carriage_return: bool = false,
    in_code_fence: bool = false,
    in_inline_code: bool = false,
    inline_code_length: usize = 0,
    fence_character: u8 = 0,
    fence_length: usize = 0,
    index: ?stage1.StructuralIndex = null,
    kinds: ?[]MarkdownTokenKind = null,
    finished: bool = false,

    const Self = @This();
    const initial_output_capacity: usize = 1;
    pub const max_retained_line_length: usize = std.math.maxInt(u32);

    const ProcessError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
        LineTooLong,
    };

    pub const InitError = stage1.StructuralIndex.InitError;
    pub const FeedError = std.mem.Allocator.Error || error{
        AlreadyFinished,
        CapacityOverflow,
        InputTooLarge,

        LineTooLong,
    };
    pub const FinishError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
        LineTooLong,
    };
    pub const FeedFromError = FeedError || FinishError || std.Io.Reader.ShortError;

    pub fn init(
        allocator: std.mem.Allocator,
        chunk_len: usize,
    ) InitError!Self {
        const output_capacity = @max(chunk_len, initial_output_capacity);
        var index = try stage1.StructuralIndex.init(allocator, output_capacity);
        errdefer index.deinit(allocator);
        const kinds = try allocator.alloc(MarkdownTokenKind, output_capacity);
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
        self.line.deinit(self.allocator);
        self.* = undefined;
    }
    /// Adds bytes to the current document. Input bytes are never borrowed
    /// after this call returns.
    pub fn feed(self: *Self, data: []const u8) FeedError!void {
        if (self.finished) return error.AlreadyFinished;

        const new_input_len = std.math.add(
            usize,
            self.input_len,
            data.len,
        ) catch return error.CapacityOverflow;
        if (new_input_len > std.math.maxInt(u32)) return error.InputTooLarge;
        const line_capacity = try self.maxLineLengthForFeed(data);
        const pending_output_additional = std.math.add(
            usize,
            self.line.items.len,
            data.len,
        ) catch return error.CapacityOverflow;
        try self.line.ensureTotalCapacity(self.allocator, line_capacity);
        try self.ensureOutputCapacity(pending_output_additional);
        self.input_len = new_input_len;

        var data_offset: usize = 0;
        while (data_offset < data.len) {
            const character = data[data_offset];
            if (self.pending_carriage_return) {
                if (character == '\n') {
                    try self.processLine(2);
                    self.pending_carriage_return = false;
                    data_offset += 1;
                    continue;
                }
                try self.processLine(1);
                self.pending_carriage_return = false;
            }

            if (character == '\r') {
                self.pending_carriage_return = true;
            } else if (character == '\n') {
                try self.processLine(1);
            } else {
                self.line.appendAssumeCapacity(character);
            }
            data_offset += 1;
        }
    }

    /// Drains a caller-owned reader and finishes at EOF.
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

    /// Consumes pending line state and finalizes the owned structural index.
    /// Repeated calls do not duplicate output.
    pub fn finish(self: *Self) FinishError!void {
        if (self.finished) return;

        if (self.pending_carriage_return) {
            try self.processLine(1);
            self.pending_carriage_return = false;
        } else if (self.line.items.len > 0) {
            try self.processLine(0);
        }

        try self.ensureOutputCapacity(0);
        if (self.index) |*index| {
            try index.finish(self.input_len);
        } else {
            unreachable;
        }
        self.finished = true;
    }

    /// Returns the finalized index without copying. The caller owns the
    /// returned arrays and must deinitialize them with the init allocator.
    pub fn take(self: *Self) MarkdownStructuralIndex {
        assert(self.finished);
        assert(self.index != null);
        assert(self.kinds != null);

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

    /// Starts a new document while retaining reusable output and line
    /// allocations. A previously taken index is intentionally not restored.
    pub fn reset(self: *Self) void {
        if (self.index) |*index| {
            index.count = 0;
        }
        self.line.clearRetainingCapacity();
        self.line_start_offset = 0;
        self.input_len = 0;
        self.pending_carriage_return = false;
        self.in_code_fence = false;
        self.in_inline_code = false;
        self.inline_code_length = 0;
        self.fence_character = 0;
        self.fence_length = 0;
        self.finished = false;
    }

    fn maxLineLengthForFeed(self: *const Self, data: []const u8) ProcessError!usize {
        var current_length = self.line.items.len;
        var maximum_length = current_length;
        var pending_carriage_return = self.pending_carriage_return;

        for (data) |character| {
            if (pending_carriage_return) {
                if (character == '\n') {
                    current_length = 0;
                    pending_carriage_return = false;
                    continue;
                }
                current_length = 0;
                pending_carriage_return = false;
            }

            if (character == '\r') {
                pending_carriage_return = true;
            } else if (character == '\n') {
                current_length = 0;
            } else {
                if (current_length >= max_retained_line_length) return error.LineTooLong;
                current_length += 1;
                maximum_length = @max(maximum_length, current_length);
            }
        }
        return maximum_length;
    }

    fn ensureOutputCapacity(self: *Self, additional: usize) ProcessError!void {
        if (self.index == null) {
            assert(self.kinds == null);
            const output_capacity = @max(additional, initial_output_capacity);
            var new_index = try stage1.StructuralIndex.init(
                self.allocator,
                output_capacity,
            );
            errdefer new_index.deinit(self.allocator);
            const new_kinds = try self.allocator.alloc(
                MarkdownTokenKind,
                output_capacity,
            );
            self.index = new_index;
            self.kinds = new_kinds;
            return;
        }

        const index = &self.index.?;
        const kinds = self.kinds orelse unreachable;

        const required = std.math.add(usize, index.count, additional) catch
            return error.CapacityOverflow;
        if (required <= kinds.len and required <= index.indexes.len - 3) return;

        const doubled_capacity = std.math.mul(usize, kinds.len, 2) catch required;
        const new_capacity = @max(required, @max(doubled_capacity, initial_output_capacity));
        const new_index_len = std.math.add(usize, new_capacity, 3) catch
            return error.CapacityOverflow;
        index.indexes = try self.allocator.realloc(index.indexes, new_index_len);
        self.kinds = try self.allocator.realloc(kinds, new_capacity);
    }

    fn appendStreamToken(
        self: *Self,
        offset: usize,
        kind: MarkdownTokenKind,
    ) void {
        const index = &self.index.?;
        const kinds = self.kinds orelse unreachable;
        assert(index.count < index.indexes.len - 3);
        assert(index.count < kinds.len);
        index.indexes[index.count] = @intCast(offset);
        kinds[index.count] = kind;
        index.count += 1;
    }

    fn processLine(self: *Self, terminator_len: usize) ProcessError!void {
        const line = self.line.items;
        try self.ensureOutputCapacity(line.len);
        self.processLineContents(line);
        self.line.clearRetainingCapacity();
        self.line_start_offset += line.len + terminator_len;
    }

    fn processLineContents(self: *Self, line: []const u8) void {
        var state = MarkdownScanState{
            .in_code_fence = self.in_code_fence,
            .in_inline_code = self.in_inline_code,
            .inline_code_length = self.inline_code_length,
            .fence_character = self.fence_character,
            .fence_length = self.fence_length,
        };
        var sink = MarkdownStreamSink{ .stream = self };
        scanMarkdownLine(
            simd.default_vector_len,
            line,
            0,
            line.len,
            &state,
            &sink,
        );
        self.in_code_fence = state.in_code_fence;
        self.in_inline_code = state.in_inline_code;
        self.inline_code_length = state.inline_code_length;
        self.fence_character = state.fence_character;
        self.fence_length = state.fence_length;
    }
};
pub fn initStreamIndexer(
    allocator: std.mem.Allocator,
    chunk_len: usize,
) MarkdownStreamIndexer.InitError!MarkdownStreamIndexer {
    return MarkdownStreamIndexer.init(allocator, chunk_len);
}

fn scanMarkdown(comptime VLEN: usize, input: []const u8, sink: anytype) void {
    var state = MarkdownScanState{
        .in_code_fence = false,
        .in_inline_code = false,
        .inline_code_length = 0,
        .fence_character = 0,
        .fence_length = 0,
    };
    var line_start: usize = 0;
    while (line_start < input.len) {
        line_start = scanMarkdownLineFused(VLEN, input, line_start, &state, sink);
    }
}

fn scanMarkdownLineFused(
    comptime VLEN: usize,
    input: []const u8,
    line_start: usize,
    state: *MarkdownScanState,
    sink: anytype,
) usize {
    const max_buffered_candidates = 64;
    var candidate_offsets: [max_buffered_candidates]u32 = undefined;
    var candidate_count: usize = 0;
    var line_end = input.len;
    var chunk_offset = line_start;

    while (chunk_offset + VLEN <= input.len) : (chunk_offset += VLEN) {
        const vector: simd.Vec(VLEN, u8) = input[chunk_offset..][0..VLEN].*;
        const newline_mask = simd.matchAny2(VLEN, vector, '\r', '\n');
        if (newline_mask != 0) {
            const relative_line_end = @as(usize, @intCast(@ctz(newline_mask)));
            line_end = chunk_offset + relative_line_end;
            const valid_candidate_mask = markdownInlineCandidateMask(VLEN, vector) &
                simd.validMask(VLEN, relative_line_end);
            if (valid_candidate_mask != 0) {
                if (candidate_count + VLEN <= max_buffered_candidates) {
                    candidate_count += simd.extractBitIndexes(
                        simd.Mask(VLEN),
                        valid_candidate_mask,
                        chunk_offset,
                        candidate_offsets[candidate_count..],
                    );
                } else {
                    candidate_count = max_buffered_candidates + 1;
                }
            }
            break;
        }
        const candidate_mask = markdownInlineCandidateMask(VLEN, vector);
        if (candidate_mask != 0) {
            if (candidate_count + VLEN <= max_buffered_candidates) {
                candidate_count += simd.extractBitIndexes(
                    simd.Mask(VLEN),
                    candidate_mask,
                    chunk_offset,
                    candidate_offsets[candidate_count..],
                );
            } else {
                candidate_count = max_buffered_candidates + 1;
            }
        }
    }

    if (line_end == input.len and chunk_offset < input.len) {
        var tail_offset = chunk_offset;
        while (tail_offset < input.len) : (tail_offset += 1) {
            const c = input[tail_offset];
            if (c == '\r' or c == '\n') {
                line_end = tail_offset;
                break;
            }
            if (c == '`' or c == '[' or c == ']' or c == '(' or c == ')') {
                if (candidate_count < max_buffered_candidates) {
                    candidate_offsets[candidate_count] = @intCast(tail_offset);
                    candidate_count += 1;
                } else {
                    candidate_count = max_buffered_candidates + 1;
                }
            }
        }
    }

    scanMarkdownLineContent(
        VLEN,
        input,
        line_start,
        line_end,
        candidate_offsets[0..@min(candidate_count, max_buffered_candidates)],
        candidate_count <= max_buffered_candidates,
        state,
        sink,
    );

    if (line_end == input.len) return input.len;
    if (input[line_end] == '\r' and line_end + 1 < input.len and input[line_end + 1] == '\n') {
        return line_end + 2;
    }
    return line_end + 1;
}

fn findMarkdownLineEnd(
    comptime VLEN: usize,
    input: []const u8,
    start: usize,
) usize {
    var chunk_offset = start;
    while (chunk_offset + VLEN <= input.len) : (chunk_offset += VLEN) {
        const vector: simd.Vec(VLEN, u8) = input[chunk_offset..][0..VLEN].*;
        const newline_mask = simd.matchAny2(VLEN, vector, '\r', '\n');
        if (newline_mask != 0) {
            return chunk_offset + @as(usize, @intCast(@ctz(newline_mask)));
        }
    }
    while (chunk_offset < input.len) : (chunk_offset += 1) {
        const c = input[chunk_offset];
        if (c == '\r' or c == '\n') return chunk_offset;
    }
    return input.len;
}
fn scanMarkdownLine(
    comptime VLEN: usize,
    input: []const u8,
    line_start: usize,
    line_end: usize,
    state: *MarkdownScanState,
    sink: anytype,
) void {
    scanMarkdownLineContent(VLEN, input, line_start, line_end, null, false, state, sink);
}

fn scanMarkdownLineContent(
    comptime VLEN: usize,
    input: []const u8,
    line_start: usize,
    line_end: usize,
    buffered_candidates: ?[]const u32,
    use_buffered: bool,
    state: *MarkdownScanState,
    sink: anytype,
) void {
    assert(line_start <= line_end);
    assert(line_end <= input.len);

    var content_start = line_start;
    while (content_start < line_end and input[content_start] == ' ') {
        content_start += 1;
    }
    const indentation = content_start - line_start;

    if (state.in_code_fence) {
        if (indentation <= 3 and content_start < line_end and
            input[content_start] == state.fence_character)
        {
            const run_length = scalarRunLength(
                input,
                content_start,
                line_end,
                state.fence_character,
            );
            if (run_length >= state.fence_length and scalarOnlyWhitespace(
                input,
                content_start + run_length,
                line_end,
            )) {
                sink.append(content_start, .code_fence);
                state.in_code_fence = false;
                state.fence_character = 0;
                state.fence_length = 0;
            }
        }
        return;
    }

    var is_fence_line = false;
    if (!state.in_inline_code and indentation <= 3 and content_start < line_end) {
        const character = input[content_start];
        if (character == '`' or character == '~') {
            const run_length = scalarRunLength(input, content_start, line_end, character);
            if (run_length >= 3) {
                is_fence_line = processMarkdownLineMarker(
                    input,
                    content_start,
                    line_end,
                    state,
                    sink,
                );
            } else {
                _ = processMarkdownLineMarker(
                    input,
                    content_start,
                    line_end,
                    state,
                    sink,
                );
            }
        } else {
            _ = processMarkdownLineMarker(
                input,
                content_start,
                line_end,
                state,
                sink,
            );
        }
    }
    if (is_fence_line) return;

    if (use_buffered and buffered_candidates != null) {
        var skipped_until = line_start;
        for (buffered_candidates.?) |candidate_index| {
            const offset: usize = @intCast(candidate_index);
            if (offset < skipped_until) continue;
            const character = input[offset];
            if (character == '`') {
                const run_length = scalarRunLength(input, offset, line_end, '`');
                const run_end = offset + run_length;
                var run_offset = offset;
                while (run_offset < run_end) : (run_offset += 1) {
                    sink.append(run_offset, .inline_code);
                }
                if (state.in_inline_code) {
                    if (run_length == state.inline_code_length) {
                        state.in_inline_code = false;
                        state.inline_code_length = 0;
                    }
                } else {
                    state.in_inline_code = true;
                    state.inline_code_length = run_length;
                }
                skipped_until = run_end;
                continue;
            }
            if (state.in_inline_code) continue;

            switch (character) {
                '[', '(' => sink.append(offset, .link_open),
                ']', ')' => sink.append(offset, .link_close),
                else => {},
            }
        }
        return;
    }

    var chunk_offset = line_start;
    var skipped_until = line_start;
    while (chunk_offset + VLEN <= line_end) : (chunk_offset += VLEN) {
        const vector: simd.Vec(VLEN, u8) = input[chunk_offset..][0..VLEN].*;
        const candidate_mask = markdownInlineCandidateMask(VLEN, vector);
        if (candidate_mask == 0) continue;
        var candidate_indexes: [VLEN]u32 = undefined;
        const candidate_count = simd.extractBitIndexes(
            simd.Mask(VLEN),
            candidate_mask,
            chunk_offset,
            &candidate_indexes,
        );

        for (candidate_indexes[0..candidate_count]) |candidate_index| {
            const offset: usize = @intCast(candidate_index);
            if (offset < skipped_until) continue;
            const character = input[offset];
            if (character == '`') {
                const run_length = scalarRunLength(input, offset, line_end, '`');
                const run_end = offset + run_length;
                var run_offset = offset;
                while (run_offset < run_end) : (run_offset += 1) {
                    sink.append(run_offset, .inline_code);
                }
                if (state.in_inline_code) {
                    if (run_length == state.inline_code_length) {
                        state.in_inline_code = false;
                        state.inline_code_length = 0;
                    }
                } else {
                    state.in_inline_code = true;
                    state.inline_code_length = run_length;
                }
                skipped_until = run_end;
                continue;
            }
            if (state.in_inline_code) continue;

            switch (character) {
                '[', '(' => sink.append(offset, .link_open),
                ']', ')' => sink.append(offset, .link_close),
                else => {},
            }
        }
    }

    while (chunk_offset < line_end) : (chunk_offset += 1) {
        if (chunk_offset < skipped_until) continue;
        const character = input[chunk_offset];
        if (character == '`') {
            const run_length = scalarRunLength(input, chunk_offset, line_end, '`');
            const run_end = chunk_offset + run_length;
            var run_offset = chunk_offset;
            while (run_offset < run_end) : (run_offset += 1) {
                sink.append(run_offset, .inline_code);
            }
            if (state.in_inline_code) {
                if (run_length == state.inline_code_length) {
                    state.in_inline_code = false;
                    state.inline_code_length = 0;
                }
            } else {
                state.in_inline_code = true;
                state.inline_code_length = run_length;
            }
            skipped_until = run_end;
            continue;
        }
        if (state.in_inline_code) continue;

        switch (character) {
            '[', '(' => sink.append(chunk_offset, .link_open),
            ']', ')' => sink.append(chunk_offset, .link_close),
            else => {},
        }
    }
}


pub const MarkdownError = error{
    InvalidIndexCount,
    InvalidTokenIndex,
    InvalidTokenOrder,
    InvalidTokenKind,
};

pub const MarkdownValidationError = std.mem.Allocator.Error || error{TapeTooLarge};
pub const MarkdownBuildError = std.mem.Allocator.Error || MarkdownError || error{TapeTooLarge};

/// A compact validated Markdown marker. `payload` stores the marker span length.
pub const MarkdownTapeWord = packed struct(u64) {
    kind: u8,
    payload: u24,
    offset: u32,

    pub fn tapeKind(self: MarkdownTapeWord) MarkdownTokenKind {
        return @enumFromInt(self.kind);
    }

    pub fn sourceLength(self: MarkdownTapeWord) usize {
        return @intCast(self.payload);
    }
};

comptime {
    assert(@bitSizeOf(MarkdownTapeWord) == 64);
    assert(@sizeOf(MarkdownTapeWord) == 8);
}

pub const MarkdownNavigationError = error{
    PositionOutOfBounds,
    InvalidTapeKind,
    InvalidTapeOrder,
    SourceOutOfBounds,
    InvalidSource,
    TapeOutOfBounds,
};

fn checkedMarkdownTapeKind(word: MarkdownTapeWord) MarkdownNavigationError!MarkdownTokenKind {
    return switch (word.kind) {
        @intFromEnum(MarkdownTokenKind.heading) => .heading,
        @intFromEnum(MarkdownTokenKind.code_fence) => .code_fence,
        @intFromEnum(MarkdownTokenKind.list_item) => .list_item,
        @intFromEnum(MarkdownTokenKind.blockquote) => .blockquote,
        @intFromEnum(MarkdownTokenKind.inline_code) => .inline_code,
        @intFromEnum(MarkdownTokenKind.link_open) => .link_open,
        @intFromEnum(MarkdownTokenKind.link_close) => .link_close,
        @intFromEnum(MarkdownTokenKind.thematic_break) => .thematic_break,
        else => error.InvalidTapeKind,
    };
}

/// An owned Markdown marker tape. The source input remains borrowed.
pub const MarkdownDocument = struct {
    tape: []MarkdownTapeWord,
    source: []const u8,

    pub fn deinit(self: *MarkdownDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.tape);
        self.* = undefined;
    }

    pub fn root(self: *const MarkdownDocument, input: []const u8) MarkdownNavigationError!MarkdownCursor {
        if (input.ptr != self.source.ptr or input.len != self.source.len) {
            return error.InvalidSource;
        }
        try validateMarkdownTape(self.tape, input);
        if (self.tape.len == 0) return error.TapeOutOfBounds;
        return .{
            .document = self,
            .input = input,
            .position_index = 0,
        };
    }

    pub fn word(self: *const MarkdownDocument, tape_index: usize) MarkdownNavigationError!MarkdownTapeWord {
        if (tape_index >= self.tape.len) return error.TapeOutOfBounds;
        return self.tape[tape_index];
    }

    pub fn sourceSpan(
        self: *const MarkdownDocument,
        input: []const u8,
        tape_index: usize,
    ) MarkdownNavigationError![]const u8 {
        const cursor = try self.root(input);
        if (tape_index >= cursor.document.tape.len) return error.TapeOutOfBounds;
        const word_value = self.tape[tape_index];
        _ = try checkedMarkdownTapeKind(word_value);
        const start: usize = @intCast(word_value.offset);
        const length = word_value.sourceLength();
        if (start > input.len or length > input.len - start) {
            return error.SourceOutOfBounds;
        }
        return input[start .. start + length];
    }
};

pub const MarkdownCursor = struct {
    document: *const MarkdownDocument,
    input: []const u8,
    position_index: usize = 0,

    pub fn peek(self: *const MarkdownCursor) MarkdownNavigationError!MarkdownTapeWord {
        return self.currentWord();
    }

    pub fn advance(self: *MarkdownCursor) MarkdownNavigationError!void {
        _ = try self.currentWord();
        self.position_index += 1;
    }

    pub fn position(self: *const MarkdownCursor) usize {
        return self.position_index;
    }

    pub fn raw(self: *const MarkdownCursor) MarkdownNavigationError![]const u8 {
        return self.span();
    }

    pub fn span(self: *const MarkdownCursor) MarkdownNavigationError![]const u8 {
        const word_value = try self.currentWord();
        const start: usize = @intCast(word_value.offset);
        const length = word_value.sourceLength();
        if (start > self.input.len or length > self.input.len - start) {
            return error.SourceOutOfBounds;
        }
        return self.input[start .. start + length];
    }

    pub fn sourceSpan(self: *const MarkdownCursor) MarkdownNavigationError![]const u8 {
        return self.span();
    }

    fn currentWord(self: *const MarkdownCursor) MarkdownNavigationError!MarkdownTapeWord {
        if (self.position_index >= self.document.tape.len) {
            return error.PositionOutOfBounds;
        }
        const word_value = self.document.tape[self.position_index];
        const kind = try checkedMarkdownTapeKind(word_value);
        const start: usize = @intCast(word_value.offset);
        const length = word_value.sourceLength();
        if (start >= self.input.len or length > self.input.len - start) {
            return error.SourceOutOfBounds;
        }
        if (!markdownSourceMatchesKind(self.input[start], kind)) {
            return error.InvalidTapeKind;
        }
        if (markdownMarkerLength(self.input, start, kind) != length) {
            return error.InvalidTapeOrder;
        }
        if (self.position_index > 0 and
            word_value.offset <= self.document.tape[self.position_index - 1].offset)
        {
            return error.InvalidTapeOrder;
        }
        return word_value;
    }
};

fn validateMarkdownTape(
    tape: []const MarkdownTapeWord,
    input: []const u8,
) MarkdownNavigationError!void {
    var previous_offset: usize = 0;
    for (tape, 0..) |word_value, tape_index| {
        const kind = try checkedMarkdownTapeKind(word_value);
        const offset: usize = @intCast(word_value.offset);
        const length = word_value.sourceLength();
        if (offset >= input.len or length > input.len - offset) {
            return error.SourceOutOfBounds;
        }
        if (tape_index > 0 and offset <= previous_offset) {
            return error.InvalidTapeOrder;
        }
        if (!markdownSourceMatchesKind(input[offset], kind)) {
            return error.InvalidTapeKind;
        }
        if (markdownMarkerLength(input, offset, kind) != length) {
            return error.InvalidTapeOrder;
        }
        previous_offset = offset;
    }

    var sink = MarkdownTapeValidationSink{ .tape = tape };
    scanMarkdown(simd.default_vector_len, input, &sink);
    try sink.finish();
}

/// Builds a validated tape in one pass through the trusted marker scanner.
pub fn buildMarkdownTape(
    allocator: std.mem.Allocator,
    input: []const u8,
) MarkdownBuildError!MarkdownDocument {
    if (input.len > std.math.maxInt(u32)) {
        return error.TapeTooLarge;
    }
    var tape: std.ArrayList(MarkdownTapeWord) = .empty;
    errdefer tape.deinit(allocator);
    var sink = MarkdownTapeSink{
        .allocator = allocator,
        .tape = &tape,
        .input = input,
        .capacity_max = input.len,
    };
    scanMarkdown(simd.default_vector_len, input, &sink);
    if (sink.failure) |err| return err;
    const owned_tape = try tape.toOwnedSlice(allocator);
    return .{
        .tape = owned_tape,
        .source = input,
    };
}

pub const MarkdownDiagnostic = struct {
    err: MarkdownError,
    byte_offset: usize,
    line: u32,
    column: u32,
    snippet: []const u8,
    snippet_start: usize,
};

/// Validates the Stage1 stream and returns only its first invariant failure.
pub fn validateMarkdown(
    allocator: std.mem.Allocator,
    input: []const u8,
) MarkdownValidationError!?MarkdownDiagnostic {
    var structural_index = indexMarkdown(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);
    return validateMarkdownIndex(input, &structural_index);
}

/// Validates a copied or otherwise externally supplied Markdown index.
pub fn validateMarkdownIndex(
    input: []const u8,
    structural_index: *const MarkdownStructuralIndex,
) MarkdownValidationError!?MarkdownDiagnostic {
    const max_offset: usize = std.math.maxInt(u32);
    if (input.len > max_offset) return error.TapeTooLarge;
    if (structural_index.count > max_offset) return error.TapeTooLarge;
    const tape_size = std.math.mul(
        usize,
        structural_index.count,
        @sizeOf(MarkdownTapeWord),
    ) catch return error.TapeTooLarge;

    if (structural_index.count > structural_index.indexes.len or
        structural_index.count > structural_index.kinds.len or
        structural_index.count > input.len)
    {
        return markdownDiagnosticAt(input, error.InvalidIndexCount, input.len);
    }

    _ = tape_size;
    var previous_offset: usize = 0;
    var has_previous = false;
    for (0..structural_index.count) |token_index| {
        const offset: usize = @intCast(structural_index.indexes[token_index]);
        if (offset >= input.len) {
            return markdownDiagnosticAt(input, error.InvalidTokenIndex, offset);
        }
        if (has_previous and offset <= previous_offset) {
            return markdownDiagnosticAt(input, error.InvalidTokenOrder, offset);
        }
        if (!markdownSourceMatchesKind(input[offset], structural_index.kinds[token_index])) {
            return markdownDiagnosticAt(input, error.InvalidTokenKind, offset);
        }
        previous_offset = offset;
        has_previous = true;
    }

    var sink = MarkdownValidationSink{
        .input = input,
        .structural_index = structural_index,
    };
    scanMarkdown(simd.default_vector_len, input, &sink);
    sink.finish();
    if (sink.diagnostic) |diagnostic| return diagnostic;
    return null;
}

/// Creates a zero-copy diagnostic view into the source input.
pub fn markdownDiagnosticAt(
    input: []const u8,
    err: MarkdownError,
    byte_offset: usize,
) MarkdownDiagnostic {
    const offset = @min(byte_offset, input.len);
    var line_start: usize = 0;
    var line_number: usize = 1;
    var scan_offset: usize = 0;
    while (scan_offset < offset) : (scan_offset += 1) {
        if (input[scan_offset] == '\n') {
            line_start = scan_offset + 1;
            line_number += 1;
        }
    }

    var line_end = offset;
    while (line_end < input.len and input[line_end] != '\n') : (line_end += 1) {}
    const snippet_start = @max(line_start, offset -| 16);
    const snippet_limit = std.math.add(usize, offset, 16) catch input.len;
    const snippet_end = @min(line_end, snippet_limit);
    const max_line_value: usize = std.math.maxInt(u32);

    return .{
        .err = err,
        .byte_offset = offset,
        .line = @intCast(@min(line_number, max_line_value)),
        .column = @intCast(@min(offset - line_start + 1, max_line_value)),
        .snippet = input[snippet_start..snippet_end],
        .snippet_start = snippet_start,
    };
}

fn markdownSourceMatchesKind(character: u8, kind: MarkdownTokenKind) bool {
    return switch (kind) {
        .heading => character == '#',
        .code_fence => character == '`' or character == '~',
        .list_item => character == '-' or character == '*' or character == '+' or
            std.ascii.isDigit(character),
        .blockquote => character == '>',
        .inline_code => character == '`',
        .link_open => character == '[' or character == '(',
        .link_close => character == ']' or character == ')',
        .thematic_break => character == '-' or character == '*' or character == '_',
    };
}

fn markdownMarkerLength(
    input: []const u8,
    offset: usize,
    kind: MarkdownTokenKind,
) usize {
    if (offset >= input.len) return 0;
    return switch (kind) {
        .code_fence => scalarRunLength(input, offset, scalarLineEnd(input, offset), input[offset]),
        .list_item => if (std.ascii.isDigit(input[offset])) blk: {
            var end = offset;
            while (end < input.len and std.ascii.isDigit(input[end])) : (end += 1) {}
            if (end < input.len and input[end] == '.') {
                break :blk end - offset + 1;
            }
            break :blk 1;
        } else 1,
        else => 1,
    };
}

const MarkdownScanState = struct {
    in_code_fence: bool,
    in_inline_code: bool,
    inline_code_length: usize,
    fence_character: u8,
    fence_length: usize,
};

const MarkdownStreamSink = struct {
    stream: *MarkdownStreamIndexer,

    fn append(self: *@This(), offset: usize, kind: MarkdownTokenKind) void {
        self.stream.appendStreamToken(self.stream.line_start_offset + offset, kind);
    }
};

fn markdownInlineCandidateMask(
    comptime VLEN: usize,
    vector: simd.Vec(VLEN, u8),
) simd.Mask(VLEN) {
    const inline_chars = simd.matchAny4(VLEN, vector, '`', '[', ']', '(');
    const paren_close = simd.matchByte(VLEN, vector, ')');
    return inline_chars | paren_close;
}

fn markdownCandidateMask(
    comptime VLEN: usize,
    vector: simd.Vec(VLEN, u8),
) simd.Mask(VLEN) {
    const line_and_blocks = simd.matchAny4(VLEN, vector, '#', '>', '-', '*');
    const lists_and_inline = simd.matchAny4(VLEN, vector, '+', '`', '[', ']');
    const links_and_fences = simd.matchAny4(VLEN, vector, '(', ')', '~', '\n');
    const thematic_underscores = simd.matchByte(VLEN, vector, '_');
    const digits = simd.matchRange(VLEN, vector, '0', '9');
    return line_and_blocks | lists_and_inline | links_and_fences | thematic_underscores | digits;
}

fn markdownValidMask(comptime VLEN: usize, valid_length: usize) simd.Mask(VLEN) {
    return simd.validMask(VLEN, valid_length);
}


fn processMarkdownLineMarker(
    input: []const u8,
    offset: usize,
    line_end: usize,
    state: *MarkdownScanState,
    sink: anytype,
) bool {
    const character = input[offset];
    if (character == '`' or character == '~') {
        const run_length = scalarRunLength(input, offset, line_end, character);
        if (run_length >= 3) {
            sink.append(offset, .code_fence);
            state.in_code_fence = true;
            state.in_inline_code = false;
            state.inline_code_length = 0;
            state.fence_character = character;
            state.fence_length = run_length;
            return true;
        }
    }

    if ((character == '-' or character == '*' or character == '_') and
        scalarIsThematicBreak(input, offset, line_end, character))
    {
        sink.append(offset, .thematic_break);
        return false;
    }

    switch (character) {
        '#' => sink.append(offset, .heading),
        '>' => sink.append(offset, .blockquote),
        '-', '*', '+' => sink.append(offset, .list_item),
        '0'...'9' => {
            var digit_end = offset;
            while (digit_end < line_end and std.ascii.isDigit(input[digit_end])) {
                digit_end += 1;
            }
            if (digit_end < line_end and input[digit_end] == '.') {
                sink.append(offset, .list_item);
            }
        },
        else => return false,
    }
    return false;
}

pub const MarkdownOnDemandError = std.mem.Allocator.Error || resident.Error || error{
    CapacityOverflow,
    CapacityExceeded,
    InputTooLarge,
    InvalidTapeKind,
    InvalidTapeOrder,
    PositionOutOfBounds,
    SourceOutOfBounds,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    candidates: resident.IndexBuffer(MarkdownTokenKind, false),
    resident_state: resident.State = .{},
    max_capacity: usize,
    grow_on_demand: bool,

    pub const InitError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };

    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) InitError!Parser {
        if (max_capacity > std.math.maxInt(u32)) return error.InputTooLarge;
        var candidates = resident.IndexBuffer(MarkdownTokenKind, false).init(allocator);
        errdefer candidates.deinit();
        if (max_capacity != 0) try candidates.reserve(max_capacity);
        return .{
            .allocator = allocator,
            .candidates = candidates,
            .max_capacity = max_capacity,
            .grow_on_demand = max_capacity == 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.resident_state.deinit();
        self.candidates.deinit();
        self.* = undefined;
    }
    fn prepare(self: *Parser, input: []const u8) MarkdownOnDemandError!void {
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        if (!self.grow_on_demand and input.len > self.max_capacity) {
            return error.CapacityExceeded;
        }
        self.candidates.count = 0;
        try self.candidates.reserve(input.len);
    }

    pub fn initOnDemandDocument(
        self: *Parser,
        input: []const u8,
    ) MarkdownOnDemandError!OnDemandDocument {
        const lease = try self.resident_state.begin();
        errdefer lease.release();
        try self.prepare(input);

        var count: usize = 0;
        var sink = MarkdownResidentSink{
            .indexes = self.candidates.indexes,
            .kinds = self.candidates.kinds,
            .count = &count,
        };
        scanMarkdown(simd.default_vector_len, input, &sink);
        try self.candidates.finish(count, input.len);
        return .{
            .parser = self,
            .input = input,
            .lease = lease,
            .count = count,
        };
    }
};

pub const Event = struct {
    kind: MarkdownTokenKind,
    offset: u32,
    raw: []const u8,
};

pub const Token = Event;

pub const OnDemandDocument = struct {
    parser: *Parser,
    input: []const u8,
    lease: resident.Lease,
    count: usize,

    pub fn deinit(self: *OnDemandDocument) void {
        self.lease.release();
        self.* = undefined;
    }
    pub fn eventReader(self: *OnDemandDocument) MarkdownOnDemandError!EventReader {
        return .{
            .parser = self.parser,
            .input = self.input,
            .count = self.count,
            .guard = try self.lease.claim(),
        };
    }

    pub fn tokenCursor(self: *OnDemandDocument) MarkdownOnDemandError!TokenCursor {
        return .{
            .parser = self.parser,
            .input = self.input,
            .count = self.count,
            .guard = try self.lease.claim(),
        };
    }
};

pub const MarkdownOnDemandDocument = OnDemandDocument;

pub fn initOnDemandDocument(
    parser: *Parser,
    input: []const u8,
) MarkdownOnDemandError!OnDemandDocument {
    return parser.initOnDemandDocument(input);
}

const MarkdownReaderBase = struct {
    parser: *Parser,
    input: []const u8,
    count: usize,
    guard: resident.Guard,

    fn event(self: *const @This()) MarkdownOnDemandError!?Event {
        try self.guard.check();
        const position = self.guard.expected_position;
        if (position >= self.count) return null;
        const offset = self.parser.candidates.indexes[position];
        const kind = self.parser.candidates.kinds[position];
        const source_offset: usize = @intCast(offset);
        if (source_offset >= self.input.len) return error.SourceOutOfBounds;
        const length = markdownMarkerLength(self.input, source_offset, kind);
        if (length > self.input.len - source_offset) {
            return error.SourceOutOfBounds;
        }
        return .{
            .kind = kind,
            .offset = offset,
            .raw = self.input[source_offset .. source_offset + length],
        };
    }
};

pub const EventReader = struct {
    parser: *Parser,
    input: []const u8,
    count: usize,
    guard: resident.Guard,

    pub fn peek(self: *const EventReader) MarkdownOnDemandError!?Event {
        var base = MarkdownReaderBase{
            .parser = self.parser,
            .input = self.input,
            .count = self.count,
            .guard = self.guard,
        };
        return base.event();
    }

    pub fn next(self: *EventReader) MarkdownOnDemandError!?Event {
        const event = try self.peek() orelse return null;
        try self.guard.advance();
        return event;
    }

    pub fn skip(self: *EventReader) MarkdownOnDemandError!void {
        _ = try self.next();
    }

    pub fn position(self: *const EventReader) usize {
        return self.guard.expected_position;
    }
};

pub const TokenCursor = struct {
    parser: *Parser,
    input: []const u8,
    count: usize,
    guard: resident.Guard,

    pub fn peek(self: *const TokenCursor) MarkdownOnDemandError!?Token {
        var base = MarkdownReaderBase{
            .parser = self.parser,
            .input = self.input,
            .count = self.count,
            .guard = self.guard,
        };
        return base.event();
    }

    pub fn advance(self: *TokenCursor) MarkdownOnDemandError!?Token {
        const token = try self.peek() orelse return null;
        try self.guard.advance();
        return token;
    }

    /// Markdown is a sequential marker stream, not a CommonMark tree.
    pub fn skipChild(self: *TokenCursor) MarkdownOnDemandError!void {
        _ = try self.advance();
    }

    pub fn position(self: *const TokenCursor) usize {
        return self.guard.expected_position;
    }
};

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
    try indexes.finish(input.len);

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

fn expectStreamMatchesReference(
    input: []const u8,
    chunk_ends: []const usize,
) !void {
    var expected = try indexMarkdown(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var stream = try MarkdownStreamIndexer.init(testing.allocator, 3);
    defer stream.deinit();

    var chunk_start: usize = 0;
    for (chunk_ends) |chunk_end| {
        try testing.expect(chunk_start <= chunk_end);
        try testing.expect(chunk_end <= input.len);
        try stream.feed(input[chunk_start..chunk_end]);
        chunk_start = chunk_end;
    }
    try stream.feed(input[chunk_start..]);
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
        MarkdownTokenKind,
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
}

test "Markdown stream matches one-shot indexing at every partition" {
    const input =
        "   # heading\r\n" ++
        "~~~language\n[hidden](target)\n~~~~\n" ++
        "`one` ``two [hidden]`` [link](target)\n" ++
        "- - -\n12. item\n> quote\n";

    for (0..input.len + 1) |partition| {
        try expectStreamMatchesReference(input, &.{partition});
    }
}

test "Markdown stream matches one-shot indexing byte by byte" {
    const input =
        "```zig\n# hidden [link](target)\n```\r\n" ++
        "``inline [hidden]`` [visible](target)\n" ++
        "* * *\n7. item\n";
    var chunk_ends: [input.len]usize = undefined;
    for (&chunk_ends, 0..) |*chunk_end, offset| {
        chunk_end.* = offset + 1;
    }

    try expectStreamMatchesReference(input, &chunk_ends);
}

test "Markdown stream finish flushes pending line state" {
    const inputs = [_][]const u8{
        "#",
        "12.",
        "- - -",
        "~~~language",
        "[link](target)",
        "``code [hidden]``",
        "```zig\n# hidden\n```",
    };
    for (inputs) |input| {
        const middle = input.len / 2;
        try expectStreamMatchesReference(input, &.{ 0, middle, middle, input.len });
    }
}

test "Markdown stream reset supports reuse before and after take" {
    var stream = try MarkdownStreamIndexer.init(testing.allocator, 2);
    defer stream.deinit();

    try stream.feed("# discarded");
    stream.reset();

    const first_input = "~~~zig\n# hidden\n~~~";
    try stream.feed(first_input[0..5]);
    try stream.feed(first_input[5..]);
    try stream.finish();
    var first_actual = stream.take();
    defer first_actual.deinit(testing.allocator);
    var first_expected = try indexMarkdown(testing.allocator, first_input);
    defer first_expected.deinit(testing.allocator);
    try testing.expectEqualSlices(
        u32,
        first_expected.indexes[0..first_expected.count],
        first_actual.indexes[0..first_actual.count],
    );
    try testing.expectEqualSlices(
        MarkdownTokenKind,
        first_expected.kinds[0..first_expected.count],
        first_actual.kinds[0..first_actual.count],
    );

    stream.reset();
    const second_input = "`code` [link](target)";
    for (second_input) |byte| {
        try stream.feed(&.{byte});
    }
    try stream.finish();
    var second_actual = stream.take();
    defer second_actual.deinit(testing.allocator);
    var second_expected = try indexMarkdown(testing.allocator, second_input);
    defer second_expected.deinit(testing.allocator);
    try testing.expectEqualSlices(
        u32,
        second_expected.indexes[0..second_expected.count],
        second_actual.indexes[0..second_actual.count],
    );
    try testing.expectEqualSlices(
        MarkdownTokenKind,
        second_expected.kinds[0..second_expected.count],
        second_actual.kinds[0..second_actual.count],
    );
    try testing.expectError(error.AlreadyFinished, stream.feed("ignored"));
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

test "Markdown document tape preserves corpus Stage1 tokens" {
    const input = @embedFile("../../test/corpus/markdown/document.md");
    var index = try indexMarkdown(testing.allocator, input);
    defer index.deinit(testing.allocator);
    var document = try buildMarkdownTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(index.count, document.tape.len);
    for (document.tape, 0..) |word, tape_index| {
        try testing.expectEqual(index.kinds[tape_index], word.tapeKind());
        try testing.expectEqual(index.indexes[tape_index], word.offset);
    }
}

test "Markdown Stage2 accepts empty input and unclosed fences" {
    try testing.expect((try validateMarkdown(testing.allocator, "")) == null);
    var empty_document = try buildMarkdownTape(testing.allocator, "");
    defer empty_document.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty_document.tape.len);

    const input = "```zig\n# hidden [x](y)";
    try testing.expect((try validateMarkdown(testing.allocator, input)) == null);
    var document = try buildMarkdownTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), document.tape.len);
    try testing.expectEqual(MarkdownTokenKind.code_fence, document.tape[0].tapeKind());
    try testing.expectEqual(@as(u32, 0), document.tape[0].offset);
}

fn checkMarkdownTapeGrowthAllocationFailure(allocator: std.mem.Allocator) !void {
    var input: [4101]u8 = undefined;
    for (input[0..4096], 0..) |*character, offset| {
        character.* = switch (offset % 4) {
            0 => '[',
            1 => ']',
            2 => '(',
            3 => ')',
            else => unreachable,
        };
    }
    input[4096..].* = .{ '\\', '[', 0xc3, 0xa9, ']' };

    var document = try buildMarkdownTape(allocator, &input);
    defer document.deinit(allocator);

    try testing.expectEqual(@as(usize, 4098), document.tape.len);
    try testing.expectEqual(MarkdownTokenKind.link_open, document.tape[4096].tapeKind());
    try testing.expectEqual(@as(u32, 4097), document.tape[4096].offset);
    try testing.expectEqual(MarkdownTokenKind.link_close, document.tape[4097].tapeKind());
    try testing.expectEqual(@as(u32, 4100), document.tape[4097].offset);
}

test "Markdown tape growth propagates allocation failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkMarkdownTapeGrowthAllocationFailure,
        .{},
    );
}

test "Markdown Stage2 rejects forged index count and tape size" {
    var indexes = [_]u32{0};
    var kinds = [_]MarkdownTokenKind{.heading};

    const oversized_count = if (@sizeOf(usize) > @sizeOf(u32))
        @as(usize, std.math.maxInt(u32)) + 1
    else
        std.math.maxInt(usize);
    const oversized_tape = MarkdownStructuralIndex{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = oversized_count,
    };
    try testing.expectError(
        error.TapeTooLarge,
        validateMarkdownIndex("#", &oversized_tape),
    );

    const invalid_count = MarkdownStructuralIndex{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 2,
    };
    const diagnostic = (try validateMarkdownIndex("#", &invalid_count)).?;
    try testing.expectEqual(error.InvalidIndexCount, diagnostic.err);
    try testing.expectEqual(@as(usize, 1), diagnostic.byte_offset);
}

test "Markdown Stage2 rejects forged out-of-range offsets" {
    const input = "# heading";
    var indexes = [_]u32{@intCast(input.len)};
    var kinds = [_]MarkdownTokenKind{.heading};
    const forged = MarkdownStructuralIndex{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 1,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)).?;
    try testing.expectEqual(error.InvalidTokenIndex, diagnostic.err);
    try testing.expectEqual(input.len, diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 1), diagnostic.line);
    try testing.expectEqual(@as(u32, @intCast(input.len + 1)), diagnostic.column);
    try testing.expectEqual(@as(usize, 0), diagnostic.snippet_start);
    try testing.expectEqualStrings(input, diagnostic.snippet);
    try testing.expect(diagnostic.snippet.ptr == input.ptr);
}

test "Markdown Stage2 rejects forged non-increasing offsets" {
    const input = "# >";
    var indexes = [_]u32{ 2, 0 };
    var kinds = [_]MarkdownTokenKind{ .blockquote, .heading };
    const forged = MarkdownStructuralIndex{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 2,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)).?;
    try testing.expectEqual(error.InvalidTokenOrder, diagnostic.err);
    try testing.expectEqual(@as(usize, 0), diagnostic.byte_offset);
}

test "Markdown Stage2 rejects forged kind and source mismatches" {
    const input = "\n  # heading";
    var indexes = [_]u32{3};
    var kinds = [_]MarkdownTokenKind{.blockquote};
    const forged = MarkdownStructuralIndex{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 1,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)).?;
    try testing.expectEqual(error.InvalidTokenKind, diagnostic.err);
    try testing.expectEqual(@as(usize, 3), diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), diagnostic.line);
    try testing.expectEqual(@as(u32, 3), diagnostic.column);
    try testing.expectEqual(@as(usize, 1), diagnostic.snippet_start);
    try testing.expectEqualStrings("  # heading", diagnostic.snippet);
    try testing.expect(diagnostic.snippet.ptr == input.ptr + diagnostic.snippet_start);
}

test "Markdown Stage2 rejects forged thematic break at list marker" {
    const input = "- item\n";
    var indexes = [_]u32{0};
    var kinds = [_]MarkdownTokenKind{.thematic_break};
    const forged = MarkdownStructuralIndex{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 1,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)).?;
    try testing.expectEqual(error.InvalidTokenKind, diagnostic.err);
    try testing.expectEqual(@as(usize, 0), diagnostic.byte_offset);
}

test "Markdown Stage2 rejects forged mid-line heading" {
    const input = "text # heading\n";
    var indexes = [_]u32{5};
    var kinds = [_]MarkdownTokenKind{.heading};
    const forged = MarkdownStructuralIndex{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 1,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)).?;
    try testing.expectEqual(error.InvalidTokenKind, diagnostic.err);
    try testing.expectEqual(@as(usize, 5), diagnostic.byte_offset);
}

test "Markdown marker source spans preserve fences and ordered markers" {
    const input =
        "### heading\r\n12. item\n````lang\nx\n````\n";
    var index = try indexMarkdown(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &.{ 0, 13, 22, 33 }, index.indexes[0..index.count]);
    try testing.expectEqualStrings("#", index.sourceSpan(0, input).?);
    try testing.expectEqualStrings("12.", index.sourceSpan(1, input).?);
    try testing.expectEqualStrings("````", index.sourceSpan(2, input).?);
    try testing.expectEqualStrings("````", index.sourceSpan(3, input).?);
}

test "Markdown tape root and cursor validate source bounds and raw spans" {
    const input = "# heading\n";
    var document = try buildMarkdownTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    var alternate = [_]u8{ '#', ' ', 'h', 'e', 'a', 'd', 'i', 'n', 'g', '\n' };
    try testing.expectError(error.InvalidSource, document.root(&alternate));

    var cursor = try document.root(input);
    try testing.expectEqualStrings("#", try cursor.raw());
    try cursor.advance();
    try testing.expectError(error.PositionOutOfBounds, cursor.peek());

    document.tape[0].payload = 0;
    try testing.expectError(error.InvalidTapeOrder, document.root(input));
    document.tape[0].payload = 1;
    document.tape[0].kind = @intFromEnum(MarkdownTokenKind.code_fence);
    try testing.expectError(error.InvalidTapeKind, document.root(input));
}

test "Markdown resident traversal is lazy focused and generation guarded" {
    const input = "# heading\n`code` [link]\n";
    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, input);
    var reader = try document.eventReader();
    try testing.expectError(error.FocusAlreadyClaimed, document.tokenCursor());

    const first = (try reader.peek()).?;
    try testing.expectEqual(MarkdownTokenKind.heading, first.kind);
    try testing.expectEqual(@as(u32, 0), first.offset);
    try testing.expectEqualStrings("#", first.raw);
    try testing.expectEqual(@as(usize, 0), reader.position());

    var copied_reader = reader;
    _ = try reader.next();
    try testing.expectError(error.OutOfOrderIteration, copied_reader.peek());

    document.deinit();
    try testing.expectError(error.DocumentReleased, reader.peek());
    try testing.expectError(error.DocumentReleased, reader.next());
    try testing.expectError(error.DocumentReleased, copied_reader.peek());
    try testing.expectError(error.DocumentReleased, copied_reader.next());
}

test "Markdown resident parser reuses fixed capacity and reports active documents" {
    const first_input = "# one\n";
    const second_input = "``code``\n";
    var parser = try Parser.init(testing.allocator, second_input.len);
    defer parser.deinit();
    const candidate_pointer = @intFromPtr(parser.candidates.indexes.ptr);

    var first_document = try initOnDemandDocument(&parser, first_input);
    try testing.expectError(error.DocumentActive, initOnDemandDocument(&parser, second_input));
    first_document.deinit();

    var second_document = try initOnDemandDocument(&parser, second_input);
    defer second_document.deinit();
    try testing.expectEqual(candidate_pointer, @intFromPtr(parser.candidates.indexes.ptr));
}

test "Markdown stream reader preserves one-shot offsets across CRLF chunks" {
    const input = "# one\r\n12. two\n```\n# hidden\n```\n";
    var expected = try indexMarkdown(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var reader = std.Io.Reader.fixed(input);
    var stream = try initStreamIndexer(testing.allocator, 2);
    defer stream.deinit();
    try stream.feedFrom(&reader);
    try testing.expect(stream.finished);
    var actual = stream.take();
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

test "Markdown tape bounds marker spans independently from source size" {
    const input = try testing.allocator.alloc(u8, @as(usize, std.math.maxInt(u24)) + 1);
    defer testing.allocator.free(input);
    @memset(input, ' ');
    input[0..2].* = .{ '#', '\n' };
    {
        var document = try buildMarkdownTape(testing.allocator, input);
        defer document.deinit(testing.allocator);
        const cursor = try document.root(input);
        try testing.expectEqualStrings("#", try cursor.raw());
    }
    @memset(input, '`');
    try testing.expectError(error.TapeTooLarge, buildMarkdownTape(testing.allocator, input));
}
