//! Marker-only Markdown indexing, tape validation and navigation.
//!
//! The scanner records eight markers — headings, code fences, list items,
//! block quotes, inline code runs, link delimiters and thematic breaks — at
//! their source offsets. It builds no tree, resolves no link destination and
//! interprets no emphasis, HTML block or list nesting, so it is not a
//! CommonMark parser; the document model lives in `formats.commonmark`.
//!
//! A consumer reaches this module as `simd.formats.markdown`, or by importing
//! `formats/markdown.zig` relatively. It publishes a one-shot indexer, the
//! chunk-fed `MarkdownStreamIndexer`, the owned `MarkdownDocument` tape with
//! its cursor, and the resident `Parser` family.
//!
//! Every entry point takes the caller's allocator. `indexMarkdown` copies
//! offsets only, so `input` may be released when it returns; `buildMarkdownTape`
//! borrows `input` into `MarkdownDocument.source`, which must stay alive and
//! unmodified while the document, its cursors and its diagnostics are read.
//! The index, the tape and the resident parser each own their allocations and
//! release them in exactly one `deinit`.

const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const resident = @import("../core/resident.zig");
const assert = std.debug.assert;
const testing = std.testing;

/// The marker kinds this scanner records.
///
/// Each kind names the byte that opens it and the run it covers:
/// `code_fence` spans the whole backtick or tilde run, `list_item` spans an
/// ordered marker's digits and trailing `'.'`, or one `-`, `*` or `+`, and
/// the remaining kinds are a single byte. `link_open` covers `[` and `(` and
/// `link_close` covers `]` and `)`; reference, image and autolink forms are
/// not distinguished from one another.
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

/// Owned Stage 1 Markdown output: one marker offset per entry, with its kind.
///
/// The index stores offsets only, so the source bytes may be released as soon
/// as the indexer returns. One index owns `indexes` and `kinds` and releases
/// both in one `deinit`, from the same allocator the indexer was given.
/// Copying an index copies the two slice handles, so a copy is not a second
/// owner and must not be `deinit`'d.
pub const MarkdownStructuralIndex = struct {
    /// Marker offsets, strictly increasing, of `indexes[0..count]`.
    ///
    /// Three entries past `count` are reserved for the sentinels
    /// `stage1.StructuralIndex.finish` writes: the input length twice and
    /// then `0`.
    indexes: []u32,
    /// Kind of each of `kinds[0..count]`. Entries past `count` are unused.
    kinds: []MarkdownTokenKind,
    /// Number of markers written. The arrays are longer than this.
    count: usize,

    /// Releases `indexes` and `kinds` into `allocator`, which must be the
    /// allocator the indexer received. The index is unusable afterward, and a
    /// second call through any copy is a double free.
    pub fn deinit(self: *MarkdownStructuralIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.indexes);
        allocator.free(self.kinds);
        self.* = undefined;
    }

    /// Marker bytes for `token_index`, or `null` when `token_index` is not
    /// below `count`, the offset is past `input`, or the byte at the offset is
    /// not the one this kind opens with.
    ///
    /// `input` is not matched against an owning source, so any slice of the
    /// right length is read; the result borrows `input` and is invalidated
    /// when the caller writes or releases it. A `null` here carries no
    /// diagnostic — `validateMarkdownIndex` reports one.
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

    fn append(self: *MarkdownIndexSink, offset: usize, kind: MarkdownTokenKind) void {
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

    fn append(self: *MarkdownTapeSink, offset: usize, kind: MarkdownTokenKind) void {
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

    fn grow(self: *MarkdownTapeSink) std.mem.Allocator.Error!void {
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

    fn append(self: *MarkdownResidentSink, offset: usize, kind: MarkdownTokenKind) void {
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

    fn append(self: *MarkdownValidationSink, offset: usize, kind: MarkdownTokenKind) void {
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

    fn finish(self: *MarkdownValidationSink) void {
        if (self.diagnostic != null or self.token_index >= self.structural_index.count) return;
        const offset: usize = @intCast(self.structural_index.indexes[self.token_index]);
        self.diagnostic = markdownDiagnosticAt(self.input, error.InvalidTokenKind, offset);
    }
};
const MarkdownTapeValidationSink = struct {
    tape: []const MarkdownTapeWord,
    count: usize = 0,
    diagnostic: ?MarkdownNavigationError = null,

    fn append(self: *MarkdownTapeValidationSink, offset: usize, kind: MarkdownTokenKind) void {
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

    fn finish(self: *MarkdownTapeValidationSink) MarkdownNavigationError!void {
        if (self.diagnostic) |diagnostic| return diagnostic;
        if (self.count != self.tape.len) return error.InvalidTapeOrder;
    }
};

/// Builds the Stage 1 structural index for `input` at the default vector
/// width.
///
/// `input` is read and not retained; it may be released when this returns.
/// `error.InputTooLarge` when `input.len` exceeds `std.math.maxInt(u32)` is
/// decided before the first allocation, and `error.OutOfMemory` leaves the
/// caller owning nothing. The returned index owns its two arrays.
pub fn indexMarkdown(
    allocator: std.mem.Allocator,
    input: []const u8,
) !MarkdownStructuralIndex {
    return indexMarkdownImpl(simd.default_vector_len, allocator, input);
}

/// `indexMarkdown` with `vlen` as the SIMD candidate width.
///
/// Every width in the supported range produces the same offsets and kinds;
/// `vlen` exists so a verification matrix can pin one. The ownership, error
/// and residue contract is the one `indexMarkdown` documents.
pub fn indexMarkdownImpl(
    comptime vlen: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) !MarkdownStructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);
    const kinds = try allocator.alloc(MarkdownTokenKind, input.len);
    errdefer allocator.free(kinds);

    var sink: MarkdownIndexSink = .{
        .indexes = &indexes,
        .kinds = kinds,
    };
    scanMarkdown(vlen, input, &sink);
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
/// the final unterminated line and writes the structural sentinels. `data` is
/// never retained, so a caller may reuse or release the chunk on return.
///
/// The indexer owns every array it allocates and stores the `allocator` it was
/// given; `deinit` releases them, and one indexer is one document until
/// `reset`. Neither `take` nor `deinit` copies the value, and two indexers
/// built from the same allocator stay independent.
pub const MarkdownStreamIndexer = struct {
    /// Retained. Every array this indexer owns, and every later growth of
    /// them, comes from this allocator, and `deinit` frees into it. It must
    /// stay valid and unmodified for the indexer's whole lifetime.
    allocator: std.mem.Allocator,
    /// Bytes of the unfinished line. Cleared as each completed line is
    /// consumed; its capacity is retained across `reset`.
    line: std.ArrayList(u8) = .empty,
    /// Source offset of `line.items[0]`, so emitted offsets stay absolute
    /// across chunk boundaries.
    line_start_offset: usize = 0,
    /// Bytes accepted so far, terminators included. `finish` writes it as the
    /// trailing sentinel.
    input_len: usize = 0,
    /// `true` after a `'\r'` whose next byte has not arrived. The terminator
    /// counts as one byte unless that byte is `'\n'`.
    pending_carriage_return: bool = false,
    /// Scan carry across lines: an open fenced code block, an unmatched
    /// inline-code run, its length, and the active fence character and run
    /// length. `reset` clears all five.
    in_code_fence: bool = false,
    in_inline_code: bool = false,
    inline_code_length: usize = 0,
    fence_character: u8 = 0,
    fence_length: usize = 0,
    /// Structural output, `null` after `take` until storage is prepared again.
    /// Even with no untaken index, `deinit` must free the retained line buffer.
    index: ?stage1.StructuralIndex = null,
    /// Kind array paired with `index`. `null` on the same window as `index`.
    kinds: ?[]MarkdownTokenKind = null,
    /// Set by a successful `finish`. A later `feed` returns
    /// `error.AlreadyFinished` and `finish` becomes a no-op.
    finished: bool = false,

    const Self = MarkdownStreamIndexer;
    const initial_output_capacity: usize = 1;
    /// Longest unfinished line the indexer retains, in bytes. `feed` returns
    /// `error.LineTooLong` when the incoming chunk would push a single line
    /// past this bound, before any byte of the chunk is consumed.
    pub const max_retained_line_length: usize = std.math.maxInt(u32);

    const ProcessError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
        LineTooLong,
    };

    /// Exactly `stage1.StructuralIndex.InitError`, so `error.OutOfMemory`,
    /// `error.CapacityOverflow` and `error.InputTooLarge`; the reservation is
    /// the only thing `init` can fail on and it happens before the indexer
    /// exists. This is an alias, not a new set, and `stage1.StructuralIndex`
    /// owns the contract.
    pub const InitError = stage1.StructuralIndex.InitError;
    /// `feed`'s failures. `error.AlreadyFinished` after a successful `finish`,
    /// and `error.CapacityOverflow`, `error.InputTooLarge` and
    /// `error.LineTooLong`, are all decided before any byte of the chunk is
    /// consumed, so the same chunk may be fed again. `error.OutOfMemory` from
    /// the line or output growth can also arrive part-way through, which
    /// `feed` describes.
    pub const FeedError = std.mem.Allocator.Error || error{
        AlreadyFinished,
        CapacityOverflow,
        InputTooLarge,

        LineTooLong,
    };
    /// `finish`'s failures: the sizing and allocator tags from consuming the
    /// final line and writing the structural sentinels. `error.AlreadyFinished`
    /// is absent because `finish` is a no-op once it has succeeded, and
    /// `finish` states what a failed call leaves behind.
    pub const FinishError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
        LineTooLong,
    };
    /// `feedFrom`'s failures: every tag of `FeedError` and `FinishError`, plus
    /// `std.Io.Reader.ShortError`, which is the reader's short-read set rather
    /// than a tag and contributes exactly one of them, `error.ReadFailed`.
    /// The other tag `reader.fill` can return, `error.EndOfStream`, is
    /// consumed here and runs `finish` instead of reaching the caller.
    pub const FeedFromError = FeedError || FinishError || std.Io.Reader.ShortError;

    /// Allocates the structural output at `chunk_len` entries and stores
    /// `allocator` for the indexer's lifetime.
    ///
    /// `chunk_len` is an initial capacity, not a bound: the output grows
    /// during `feed`, and a `chunk_len` of `0` still allocates one entry. The
    /// line buffer starts empty and is allocated on the first `feed` that
    /// needs one. On `error.OutOfMemory` both arrays are released and the
    /// caller owns nothing.
    pub fn init(
        allocator: std.mem.Allocator,
        chunk_len: usize,
    ) InitError!MarkdownStreamIndexer {
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

    /// Releases the structural output and the retained line buffer into
    /// `self.allocator`.
    ///
    /// An index already returned by `take` is unaffected and stays owned by
    /// the caller. The indexer is unusable afterward, and a second call is a
    /// double free.
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
    ///
    /// `error.AlreadyFinished` after a successful `finish`. The running
    /// length is checked first: `error.CapacityOverflow` when `input_len +
    /// data.len` overflows, and `error.InputTooLarge` past
    /// `std.math.maxInt(u32)`; `error.LineTooLong` follows when the chunk
    /// would carry one line past `max_retained_line_length`. All four, and
    /// `error.OutOfMemory` from the line or output growth, are decided before
    /// any byte of `data` is consumed, so the same chunk may be fed again.
    ///
    /// An `error.OutOfMemory` or `error.CapacityOverflow` raised later, while
    /// a completed line is being turned into tokens, leaves the chunk partly
    /// consumed and `input_len` already counting all of it. `reset` is then
    /// required before another document; feeding more bytes would double
    /// count the rest.
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
    ///
    /// `reader` is not retained: it and the provider behind it must stay live
    /// for the duration of the call, and this indexer stores no `std.Io`.
    /// The call may block according to the reader's implementation. Provider
    /// failures return `error.ReadFailed`; cancellation can reach this call
    /// through that provider failure channel, not a separate cancellation tag.
    /// `error.EndOfStream` is consumed and runs `finish` instead.
    ///
    /// An error from `feed` propagates before `reader.toss`, so the reader
    /// still holds the chunk that failed and the residue is the one `feed`
    /// documents. An error from `reader.fill` leaves every buffered byte
    /// already consumed and fed.
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
    ///
    /// On success `take` becomes legal and `feed` returns
    /// `error.AlreadyFinished`. An `error.OutOfMemory` or
    /// `error.CapacityOverflow` from the final line leaves the pending line,
    /// the pending carriage return and every counter exactly as they were, so
    /// `finish` may simply be called again.
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
    ///
    /// Requires a successful `finish`. That precondition is asserted, so
    /// `ReleaseFast` and `ReleaseSmall` enforce nothing here and an unfinished
    /// indexer is undefined behaviour rather than a diagnosable error.
    /// Ownership of the two arrays leaves the indexer with this call: the
    /// indexer keeps its line buffer and releases only what it still holds,
    /// so `deinit` after `take` is safe and does not free the returned index.
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
    ///
    /// This is the only recovery from an errored `feed` or `finish`, and it is
    /// valid before or after `finish` and after `take`: the output and line
    /// capacities survive, the marker count returns to zero, and the scan
    /// carry is cleared. Entries past the new count in `indexes` still hold
    /// the previous document's sentinels until the next `finish` rewrites
    /// them, so an unfinished index must not be taken or read.
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
        var state: MarkdownScanState = .{
            .in_code_fence = self.in_code_fence,
            .in_inline_code = self.in_inline_code,
            .inline_code_length = self.inline_code_length,
            .fence_character = self.fence_character,
            .fence_length = self.fence_length,
        };
        var sink: MarkdownStreamSink = .{ .stream = self };
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
/// `MarkdownStreamIndexer.init` for a caller that would only name this
/// constructor. The returned value owns the output it allocated and is
/// released by `MarkdownStreamIndexer.deinit`.
///
/// `chunk_len` is an initial capacity only, and the allocator must outlive
/// the returned indexer.
pub fn initStreamIndexer(
    allocator: std.mem.Allocator,
    chunk_len: usize,
) MarkdownStreamIndexer.InitError!MarkdownStreamIndexer {
    return MarkdownStreamIndexer.init(allocator, chunk_len);
}

fn scanMarkdown(comptime vlen: usize, input: []const u8, sink: anytype) void {
    var state: MarkdownScanState = .{
        .in_code_fence = false,
        .in_inline_code = false,
        .inline_code_length = 0,
        .fence_character = 0,
        .fence_length = 0,
    };
    var line_start: usize = 0;
    while (line_start < input.len) {
        line_start = scanMarkdownLineFused(vlen, input, line_start, &state, sink);
    }
}

fn scanMarkdownLineFused(
    comptime vlen: usize,
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

    while (chunk_offset + vlen <= input.len) : (chunk_offset += vlen) {
        const vector: simd.Vec(u8, vlen) = input[chunk_offset..][0..vlen].*;
        // Zero tests and bit scans below share an explicitly bounded
        // storage-width representation.
        const newline_mask: simd.MaskStorage(vlen) = simd.exactMask(
            simd.Mask(vlen),
            simd.matchAny2(vlen, vector, '\r', '\n'),
        );
        if (newline_mask != 0) {
            const relative_line_end: usize = @intCast(@ctz(newline_mask));
            line_end = chunk_offset + relative_line_end;
            const valid_candidate_mask: simd.MaskStorage(vlen) = simd.exactMask(
                simd.Mask(vlen),
                markdownInlineCandidateMask(vlen, vector) &
                    simd.validMask(vlen, relative_line_end),
            );
            if (valid_candidate_mask != 0) {
                if (candidate_count + vlen <= max_buffered_candidates) {
                    candidate_count += simd.extractBitIndexes(
                        @TypeOf(valid_candidate_mask),
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
        const candidate_mask: simd.MaskStorage(vlen) = simd.exactMask(
            simd.Mask(vlen),
            markdownInlineCandidateMask(vlen, vector),
        );
        if (candidate_mask != 0) {
            if (candidate_count + vlen <= max_buffered_candidates) {
                candidate_count += simd.extractBitIndexes(
                    @TypeOf(candidate_mask),
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
        vlen,
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

fn scanMarkdownLine(
    comptime vlen: usize,
    input: []const u8,
    line_start: usize,
    line_end: usize,
    state: *MarkdownScanState,
    sink: anytype,
) void {
    scanMarkdownLineContent(vlen, input, line_start, line_end, null, false, state, sink);
}

fn scanMarkdownLineContent(
    comptime vlen: usize,
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
    while (chunk_offset + vlen <= line_end) : (chunk_offset += vlen) {
        const vector: simd.Vec(u8, vlen) = input[chunk_offset..][0..vlen].*;
        const candidate_mask: simd.MaskStorage(vlen) = simd.exactMask(
            simd.Mask(vlen),
            markdownInlineCandidateMask(vlen, vector),
        );
        if (candidate_mask == 0) continue;
        var candidate_indexes: [vlen]u32 = undefined;
        const candidate_count = simd.extractBitIndexes(
            @TypeOf(candidate_mask),
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

/// Invariant failures `validateMarkdownIndex` reports about a caller-supplied
/// `MarkdownStructuralIndex`.
///
/// `InvalidIndexCount` when `count` exceeds an array or the input length,
/// `InvalidTokenIndex` when an offset is past the input, `InvalidTokenOrder`
/// when offsets do not strictly increase, and `InvalidTokenKind` when the byte
/// at an offset is not the one its kind opens with. `validateMarkdown` reports
/// the same four through `MarkdownDiagnostic` rather than as a tag.
pub const MarkdownError = error{
    InvalidIndexCount,
    InvalidTokenIndex,
    InvalidTokenOrder,
    InvalidTokenKind,
};

/// Errors the two `validateMarkdown` entry points return. Both build an index
/// first, so `error.OutOfMemory` is reachable; `error.TapeTooLarge` means
/// `input` is longer than `u32` offsets can address.
pub const MarkdownValidationError = std.mem.Allocator.Error || error{TapeTooLarge};
/// Errors `buildMarkdownTape` returns. `error.TapeTooLarge` covers an input
/// longer than `u32` offsets and a marker run longer than the `u24` payload.
pub const MarkdownBuildError = std.mem.Allocator.Error || MarkdownError || error{TapeTooLarge};

/// A compact validated Markdown marker. `payload` stores the marker span length.
///
/// The fields are public, so a caller can replace words in
/// `MarkdownDocument.tape`. Cursor and source-span access validate them against
/// the source. `MarkdownDocument.word` checks only the tape index.
pub const MarkdownTapeWord = packed struct(u64) {
    /// Integer representation of a `MarkdownTokenKind` tag. Checked navigation
    /// rejects an unknown tag with `error.InvalidTapeKind`.
    kind: u8,
    /// Marker run length in bytes. The tape rejects a run longer than this
    /// width.
    payload: u24,
    /// Source offset of the marker.
    offset: u32,

    /// Converts `kind` without a check. An unknown tag traps in Debug and
    /// ReleaseSafe and is illegal behavior in ReleaseFast and ReleaseSmall.
    /// For an untrusted word, use `std.enums.fromInt(MarkdownTokenKind, kind)`
    /// and handle `null` before calling this method.
    pub fn tapeKind(self: MarkdownTapeWord) MarkdownTokenKind {
        return @enumFromInt(self.kind);
    }

    /// `payload` widened to `usize`.
    pub fn sourceLength(self: MarkdownTapeWord) usize {
        return @intCast(self.payload);
    }
};

comptime {
    assert(@bitSizeOf(MarkdownTapeWord) == 64);
    assert(@sizeOf(MarkdownTapeWord) == 8);
}

/// Failures the tape and cursor methods return while walking
/// `MarkdownDocument`.
///
/// `InvalidSource` when the caller's `input` is not the document's recorded
/// source, `TapeOutOfBounds` for a `tape_index` at or past the tape length,
/// `PositionOutOfBounds` once a cursor is past the last word,
/// `SourceOutOfBounds` when a word's offset and length do not fit `input`,
/// `InvalidTapeKind` when a word's `kind` is not a `MarkdownTokenKind` tag or
/// the byte it addresses does not open with that kind, and
/// `InvalidTapeOrder` when a word's length disagrees with the marker run at
/// its offset or offsets do not strictly increase.
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
///
/// One document owns `tape` and releases it in one `deinit`; `source` is a
/// borrow of the `input` given to `buildMarkdownTape` and is never freed
/// here. That source must stay alive and unmodified for as long as the
/// document, any cursor made from it, or any span read through it is used —
/// `root` and the cursor methods compare `input` against `source` by pointer
/// and length, so a relocated copy is rejected rather than silently accepted.
/// Copying a document copies the tape handle, so a copy is not a second owner
/// and must not be `deinit`'d.
pub const MarkdownDocument = struct {
    /// One word per marker, in strictly increasing offset order.
    tape: []MarkdownTapeWord,
    /// The borrowed source the tape was built from.
    source: []const u8,

    /// Releases `tape` into `allocator`, which must be the allocator
    /// `buildMarkdownTape` received. The borrowed source is untouched. The
    /// document and every cursor over it are unusable afterward, and a
    /// second call through any copy is a double free.
    pub fn deinit(self: *MarkdownDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.tape);
        self.* = undefined;
    }

    /// Cursor on the first marker, after re-validating the whole tape against
    /// `input`.
    ///
    /// `input` must be the same slice `source` names — same pointer and
    /// length — or this returns `error.InvalidSource`. Validation walks the
    /// tape and rescans the source, so it costs a full pass; call it once and
    /// walk the cursor. An empty tape returns `error.TapeOutOfBounds`. The
    /// cursor borrows `self` and `input`, so neither may be released or
    /// `deinit`'d while it is used.
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

    /// The word at `tape_index`, or `error.TapeOutOfBounds`. The `kind` field
    /// is returned unconverted and unchecked, so use `MarkdownTapeWord.tapeKind`
    /// only on a word this document validated.
    pub fn word(self: *const MarkdownDocument, tape_index: usize) MarkdownNavigationError!MarkdownTapeWord {
        if (tape_index >= self.tape.len) return error.TapeOutOfBounds;
        return self.tape[tape_index];
    }

    /// Marker bytes for `tape_index`, re-validated through `root` on the way.
    ///
    /// This runs the full `root` validation, so it is a whole-document check
    /// rather than a single-word read; a cursor is cheaper for sequential
    /// access. The result borrows `input` and is invalidated when the caller
    /// writes or releases it.
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

/// A positional walk over a validated `MarkdownDocument`.
///
/// Borrows the document pointer and original input. Keep the document alive and
/// unmoved, and the input alive and unchanged, until the cursor is no longer used.
/// Copies have independent positions; they still borrow the same storage.
/// Methods check the accessed words, not every link or byte in the tape. Modified
/// words can pass those checks; use an unmodified, validated document.
pub const MarkdownCursor = struct {
    /// The document this cursor walks. Borrowed for the cursor's lifetime.
    document: *const MarkdownDocument,
    /// The source slice passed to `MarkdownDocument.root`. Borrowed.
    input: []const u8,
    /// Index of the next word in `document.tape`. Equal to `document.tape.len`
    /// once the walk is exhausted.
    position_index: usize = 0,

    /// The word under the cursor, fully validated against `input`, or
    /// `error.PositionOutOfBounds` once the walk is past the last word.
    pub fn peek(self: *const MarkdownCursor) MarkdownNavigationError!MarkdownTapeWord {
        return self.currentWord();
    }

    /// Validates the word under the cursor and steps past it.
    ///
    /// Nothing moves when validation fails, so the cursor stays where it was
    /// and may be advanced again after the caller repairs the cause.
    pub fn advance(self: *MarkdownCursor) MarkdownNavigationError!void {
        _ = try self.currentWord();
        self.position_index += 1;
    }

    /// Index of the next word. Equal to `document.tape.len` when exhausted.
    pub fn position(self: *const MarkdownCursor) usize {
        return self.position_index;
    }

    /// `span`.
    pub fn raw(self: *const MarkdownCursor) MarkdownNavigationError![]const u8 {
        return self.span();
    }

    /// Marker bytes under the cursor, or the `MarkdownNavigationError` that
    /// `peek` would return. The result borrows `input` and is invalidated when
    /// the caller writes or releases it.
    pub fn span(self: *const MarkdownCursor) MarkdownNavigationError![]const u8 {
        const word_value = try self.currentWord();
        const start: usize = @intCast(word_value.offset);
        const length = word_value.sourceLength();
        if (start > self.input.len or length > self.input.len - start) {
            return error.SourceOutOfBounds;
        }
        return self.input[start .. start + length];
    }

    /// `span`.
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

    var sink: MarkdownTapeValidationSink = .{ .tape = tape };
    scanMarkdown(simd.default_vector_len, input, &sink);
    try sink.finish();
}

/// Builds a validated tape in one pass through the trusted marker scanner.
///
/// The returned document owns one tape allocation and borrows `input`, which
/// must stay alive and unmodified. The tape holds at most `input.len` words
/// and no marker run may exceed the `u24` payload; either bound, and an input
/// longer than `u32` offsets, give `error.TapeTooLarge`. On
/// `error.OutOfMemory` the caller owns nothing.
pub fn buildMarkdownTape(
    allocator: std.mem.Allocator,
    input: []const u8,
) MarkdownBuildError!MarkdownDocument {
    if (input.len > std.math.maxInt(u32)) {
        return error.TapeTooLarge;
    }
    var tape: std.ArrayList(MarkdownTapeWord) = .empty;
    errdefer tape.deinit(allocator);
    var sink: MarkdownTapeSink = .{
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

/// The first invariant failure found in a caller-supplied index.
///
/// The value is a view, not an owner: `snippet` is a sub-slice of the `input`
/// the validating entry point was given, so it stays valid only while those
/// bytes do.
pub const MarkdownDiagnostic = struct {
    /// Which invariant failed. The four tags are `MarkdownError`'s.
    err: MarkdownError,
    /// Byte offset into the input, clamped to `input.len`.
    byte_offset: usize,
    /// One-based line number of `byte_offset`, clamped to
    /// `std.math.maxInt(u32)`.
    line: u32,
    /// One-based byte column of `byte_offset` inside its line, clamped to
    /// `std.math.maxInt(u32)`. A line ending belongs to the line it
    /// terminates, so a CRLF pair sits on that line's last two columns and no
    /// line starts on one of its bytes.
    column: u32,
    /// Up to 16 bytes of the input on each side of `byte_offset`, cut at the
    /// line boundaries. The window holds line content only, so it never holds
    /// a line ending.
    snippet: []const u8,
    /// Offset of `snippet[0]` in the input, so the snippet can be located
    /// with it.
    snippet_start: usize,
};

/// Validates the Stage1 stream and returns only its first invariant failure.
///
/// Builds an index from `input` and validates that index, so the index it
/// checks always satisfies the invariants: a `MarkdownDiagnostic` needs an
/// index the caller built or copied, and this entry point reports failures
/// only as `error.OutOfMemory` and `error.TapeTooLarge`. `input` is not
/// retained and the temporary index is released before this returns, so the
/// diagnostic's `snippet` borrows `input` and nothing else.
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

/// Checks a copied or otherwise externally supplied `MarkdownStructuralIndex`
/// against a fresh scan of `input`.
///
/// An index is accepted when its entries below `count` are, in order, exactly
/// the markers `input` produces, so the index is never checked on its own: it
/// is checked against the bytes it claims to describe. Entries at and past
/// `count` are never read, so neither array has to be longer than `count` and
/// the sentinel slots the indexer reserves past `count` are not read here.
///
/// Allocates nothing, so `error.OutOfMemory` is unreachable here even though
/// `MarkdownValidationError` names it; the shared set is the one
/// `validateMarkdown` returns. `structural_index` is read-only and
/// `input` is borrowed for the duration, and the diagnostic's `snippet`
/// borrows `input`.
///
/// Checks run in this order and stop at the first failure: the input and count
/// ceilings and the tape size they imply as `error.TapeTooLarge`, then
/// `MarkdownError.InvalidIndexCount` if `count` exceeds either array or the
/// input length, then per entry `InvalidTokenIndex`, `InvalidTokenOrder` and
/// `InvalidTokenKind`, then a rescan of the source whose extra markers,
/// mismatched offsets and mismatched kinds surface as `InvalidTokenIndex` or
/// `InvalidTokenKind`.
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

    var sink: MarkdownValidationSink = .{
        .input = input,
        .structural_index = structural_index,
    };
    scanMarkdown(simd.default_vector_len, input, &sink);
    sink.finish();
    if (sink.diagnostic) |diagnostic| return diagnostic;
    return null;
}

/// Creates a zero-copy diagnostic view into the source input.
///
/// Allocates nothing and cannot fail. `byte_offset` is clamped to `input.len`,
/// so the returned `byte_offset` is the clamped value and an offset past the
/// input reports the end of input rather than reading out of bounds. The
/// result borrows `input` and is invalidated when the caller writes or
/// releases it.
///
/// Lines break at CR, at LF and at a CRLF pair. A pair is one two-byte ending
/// whose bytes both belong to the line it terminates, so `column` counts them
/// and the next line starts after the pair.
pub fn markdownDiagnosticAt(
    input: []const u8,
    err: MarkdownError,
    byte_offset: usize,
) MarkdownDiagnostic {
    const offset = @min(byte_offset, input.len);
    var line_start: usize = 0;
    var line_number: usize = 1;
    while (line_start < offset) {
        const line_end = scalarLineEnd(input, line_start);
        if (line_end >= offset) break;
        const next_line_start = scalarNextLineStart(input, line_end);
        if (next_line_start > offset) break;
        line_start = next_line_start;
        line_number += 1;
    }

    const line_end = scalarLineEnd(input, line_start);
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

/// The scanner's carry from one line to the next.
///
/// The type is published through `MarkdownStreamIndexer`, which holds these
/// five values as its own fields rather than as one of this type, and it is
/// the state every line pass reads and writes, so a consumer writing the
/// indexer's five fields directly writes this. It owns nothing, holds no
/// borrow, and a copy is a second independent carry; the indexer copies it in
/// before a line and back out after one, so a value that is not the indexer's
/// own is never consulted.
const MarkdownScanState = struct {
    /// `true` while a fenced code block is open; `fence_character` and
    /// `fence_length` describe the fence that opened it.
    in_code_fence: bool,
    /// `true` while an inline code run is open, and its run length in bytes is
    /// `inline_code_length`.
    in_inline_code: bool,
    /// Length in bytes of the unmatched inline code run, meaningful only while
    /// `in_inline_code` is `true`.
    inline_code_length: usize,
    /// The opening byte of the open fence, backtick or tilde, meaningful only
    /// while `in_code_fence` is `true`.
    fence_character: u8,
    /// Length in bytes of the open fence run, meaningful only while
    /// `in_code_fence` is `true`.
    fence_length: usize,
};

/// The token sink the streaming scanner writes into, forwarding each marker to
/// the indexer's own `line_start_offset`.
///
/// Reachable through the line pass `MarkdownStreamIndexer.processLineContents`
/// builds one of, so a consumer reaching it sees a pointer to the indexer
/// rather than a copy. It owns nothing, borrows the indexer, and must not
/// outlive the line pass it was built for.
const MarkdownStreamSink = struct {
    stream: *MarkdownStreamIndexer,

    fn append(self: *MarkdownStreamSink, offset: usize, kind: MarkdownTokenKind) void {
        self.stream.appendStreamToken(self.stream.line_start_offset + offset, kind);
    }
};

fn markdownInlineCandidateMask(
    comptime vlen: usize,
    vector: simd.Vec(u8, vlen),
) simd.Mask(vlen) {
    const inline_chars = simd.matchAny4(vlen, vector, '`', '[', ']', '(');
    const paren_close = simd.matchByte(vlen, vector, ')');
    return inline_chars | paren_close;
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

/// Errors the resident `Parser` family returns.
///
/// This is the shared resident vocabulary, so it is wider than any one call:
/// the reader and cursor methods themselves produce `error.OutOfMemory`, the
/// four `resident.Error` tags and `error.SourceOutOfBounds`, while
/// `CapacityOverflow`, `CapacityExceeded` and `InputTooLarge` come from the
/// document constructor. `InvalidTapeKind`, `InvalidTapeOrder` and
/// `PositionOutOfBounds` belong to `MarkdownNavigationError` and are carried
/// here only so one set names the family.
pub const MarkdownOnDemandError = std.mem.Allocator.Error || resident.Error || error{
    CapacityOverflow,
    CapacityExceeded,
    InputTooLarge,
    InvalidTapeKind,
    InvalidTapeOrder,
    PositionOutOfBounds,
    SourceOutOfBounds,
};

/// A reusable resident Markdown parser: it indexes a document once and hands
/// out a borrowed walk over the result.
///
/// The parser owns one candidate buffer and stores the `allocator` it was
/// built with; `deinit` releases both and is the only release. It holds at
/// most one active document — `initOnDemandDocument` returns
/// `error.DocumentActive` while another is open — so it is not threadsafe and
/// its own methods must not be reentered from one another. Copying a parser
/// copies the buffer handle, so a copy is not a second owner.
pub const Parser = struct {
    /// The allocator passed to `init`. It is retained for the parser's
    /// lifetime; `candidates` carries its own copy of it, so writing this
    /// field redirects no allocation.
    allocator: std.mem.Allocator,
    /// The shared offset and kind arrays every walk reads. The next
    /// `initOnDemandDocument` overwrites them, which is why one document is
    /// active at a time.
    candidates: resident.IndexBuffer(MarkdownTokenKind, false),
    /// The single-document lease. Its generation advances on every document,
    /// so a reader held across two documents fails instead of reading the
    /// newer one's markers.
    resident_state: resident.State = .{},
    /// Largest `input` accepted, in bytes. `0` means no ceiling: the candidate
    /// buffer then grows to whatever each document needs.
    max_capacity: usize,
    /// Whether `max_capacity` is enforced. `init` derives it from
    /// `max_capacity == 0`, and writing it changes which documents are
    /// accepted.
    grow_on_demand: bool,

    /// Errors `init` returns: `error.InputTooLarge` for a `max_capacity`
    /// beyond `u32`, `error.CapacityOverflow` for a reservation that
    /// overflows, and `error.OutOfMemory` from it.
    pub const InitError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };

    /// Builds a parser over `allocator`, reserving room for `max_capacity`
    /// markers up front when it is nonzero.
    ///
    /// `max_capacity` above `std.math.maxInt(u32)` returns
    /// `error.InputTooLarge` before any allocation, and `error.OutOfMemory`
    /// releases the reservation so the caller owns nothing. The allocator
    /// must outlive the parser.
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

    /// Releases the candidate buffer into the allocator it was built with.
    ///
    /// Asserts that no document is open, so Debug and ReleaseSafe diagnose a
    /// missing `OnDemandDocument.deinit` while ReleaseFast and ReleaseSmall do
    /// not. Every `OnDemandDocument`, `EventReader` and `TokenCursor` made
    /// from this parser is unusable afterward, and a second call is a double
    /// free.
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

    /// Indexes `input` once and returns a document that borrows it.
    ///
    /// `error.DocumentActive` while another document from this parser is open.
    /// `error.InputTooLarge` past `std.math.maxInt(u32)` and, when
    /// `max_capacity` is nonzero, `error.CapacityExceeded` past it are
    /// decided before the scan; `error.OutOfMemory` from the reservation
    /// releases the lease, so the parser is unchanged and the caller owns
    /// nothing. `input` is not copied: it must stay alive and unmodified while
    /// the document and every walk made from it are used.
    pub fn initOnDemandDocument(
        self: *Parser,
        input: []const u8,
    ) MarkdownOnDemandError!OnDemandDocument {
        const lease = try self.resident_state.begin();
        errdefer lease.release();
        try self.prepare(input);

        var count: usize = 0;
        var sink: MarkdownResidentSink = .{
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

/// One resident Markdown marker, borrowed from the document's source.
///
/// The value allocates nothing and owns no bytes: `raw` is a sub-slice of the
/// `input` the document was opened with.
pub const Event = struct {
    /// Marker kind at `offset`.
    kind: MarkdownTokenKind,
    /// Source offset of the marker.
    offset: u32,
    /// Marker bytes. Borrows the document's input.
    raw: []const u8,
};

/// `Event`.
pub const Token = Event;

/// A borrowed resident Markdown document: one indexed source plus the lease
/// that keeps it current.
///
/// The document owns nothing and reaches the parser's candidate buffer through
/// its lease rather than by copy. `input` is borrowed and must stay alive and
/// unmodified; `parser` must outlive the document and must not be `deinit`'d
/// while it is open. Only one walk exists at a time — `eventReader` and
/// `tokenCursor` return `error.FocusAlreadyClaimed` to a second caller — and
/// any walk made from this document returns `error.DocumentReleased` once
/// `deinit` runs or another document is opened.
pub const OnDemandDocument = struct {
    /// The parser whose candidate buffer this document reads.
    ///
    /// `eventReader` and `tokenCursor` hand this same pointer to the walk, so
    /// the parser must stay at the same address while the document and any
    /// walk from it are used: a moved or copied parser is a different candidate
    /// buffer, and the next `initOnDemandDocument` overwrites this one's.
    parser: *Parser,
    /// The borrowed source, invalidated when the caller writes or releases it.
    input: []const u8,
    /// The document lease, released by `deinit`.
    lease: resident.Lease,
    /// Number of markers indexed from `input`.
    count: usize,

    /// Releases the lease, which frees no memory. The document is unusable
    /// afterward, and every `EventReader` and `TokenCursor` made from it
    /// starts returning `error.DocumentReleased`.
    pub fn deinit(self: *OnDemandDocument) void {
        self.lease.release();
        self.* = undefined;
    }
    /// A reader over the markers. It claims the document's single focus, so
    /// `error.FocusAlreadyClaimed` when another walk is open; on that error
    /// the existing walk is unaffected. The reader borrows the parser's
    /// candidate buffer and `input`, so both must stay live and unmodified
    /// while it is used.
    pub fn eventReader(self: *OnDemandDocument) MarkdownOnDemandError!EventReader {
        return .{
            .parser = self.parser,
            .input = self.input,
            .count = self.count,
            .guard = try self.lease.claim(),
        };
    }

    /// A cursor over the markers, with the same focus claim and borrows as
    /// `eventReader`.
    pub fn tokenCursor(self: *OnDemandDocument) MarkdownOnDemandError!TokenCursor {
        return .{
            .parser = self.parser,
            .input = self.input,
            .count = self.count,
            .guard = try self.lease.claim(),
        };
    }
};

/// `OnDemandDocument`.
pub const MarkdownOnDemandDocument = OnDemandDocument;

/// `Parser.initOnDemandDocument` for a caller that would only name this
/// constructor. The returned document borrows `input` and owns only its
/// lease, which `OnDemandDocument.deinit` releases.
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

    fn event(self: *const MarkdownReaderBase) MarkdownOnDemandError!?Event {
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

/// A sequential reader over one `OnDemandDocument`'s markers.
///
/// The reader owns nothing: it borrows the parser's shared candidate buffer
/// and the document's `input`, so both must stay live and unmodified while it
/// is used. Every `Event` it returns borrows that `input`. It holds the
/// document's single focus, so a second walk on the same document is refused
/// at construction, and its position advances in lockstep with any other
/// copy: a copied reader that lags returns `error.OutOfOrderIteration`, and
/// both return `error.DocumentReleased` once the document closes. Copying the
/// reader is free and the copies are independent values sharing one position.
pub const EventReader = struct {
    /// The parser whose candidate buffer is read.
    parser: *Parser,
    /// The document's borrowed source; every `Event.raw` points into it.
    input: []const u8,
    /// Marker count the walk ends at.
    count: usize,
    /// The document focus and position. Copies of a reader share it.
    guard: resident.Guard,

    /// The next `Event` without consuming it, or `null` at the end. Returns
    /// `error.DocumentReleased` after the document closes,
    /// `error.OutOfOrderIteration` when another copy of this reader has
    /// advanced past it, and `error.SourceOutOfBounds` if a stored offset no
    /// longer addresses `input`.
    pub fn peek(self: *const EventReader) MarkdownOnDemandError!?Event {
        var base: MarkdownReaderBase = .{
            .parser = self.parser,
            .input = self.input,
            .count = self.count,
            .guard = self.guard,
        };
        return base.event();
    }

    /// The next `Event` and the position past it, or `null` at the end. The
    /// position does not move when `peek` fails.
    pub fn next(self: *EventReader) MarkdownOnDemandError!?Event {
        const event = try self.peek() orelse return null;
        try self.guard.advance();
        return event;
    }

    /// Consumes the next marker. Markdown has no nesting, so this is
    /// `next` with the result discarded, and `null` at the end is not an
    /// error.
    pub fn skip(self: *EventReader) MarkdownOnDemandError!void {
        _ = try self.next();
    }

    /// Events already consumed. Equal to the document's `count` at the end.
    pub fn position(self: *const EventReader) usize {
        return self.guard.expected_position;
    }
};

/// A sequential cursor over one `OnDemandDocument`'s markers.
///
/// It borrows exactly what `EventReader` borrows and answers the same
/// staleness errors: `error.DocumentReleased` once the document closes and
/// `error.OutOfOrderIteration` for a copy another copy has advanced past.
/// Markdown is a marker stream rather than a tree, so this cursor has no
/// subtree to descend into.
pub const TokenCursor = struct {
    /// The parser whose candidate buffer is read.
    parser: *Parser,
    /// The document's borrowed source; every `Token.raw` points into it.
    input: []const u8,
    /// Marker count the walk ends at.
    count: usize,
    /// The document focus and position. Copies of a cursor share it.
    guard: resident.Guard,

    /// The next `Token` without consuming it, or `null` at the end, with the
    /// same errors as `EventReader.peek`.
    pub fn peek(self: *const TokenCursor) MarkdownOnDemandError!?Token {
        var base: MarkdownReaderBase = .{
            .parser = self.parser,
            .input = self.input,
            .count = self.count,
            .guard = self.guard,
        };
        return base.event();
    }

    /// The next `Token` and the position past it, or `null` at the end.
    pub fn advance(self: *TokenCursor) MarkdownOnDemandError!?Token {
        const token = try self.peek() orelse return null;
        try self.guard.advance();
        return token;
    }

    /// Markdown is a sequential marker stream, not a CommonMark tree.
    ///
    /// This consumes the next marker and stops. It exists only to satisfy the
    /// cursor shape shared with the tree-building formats; it never descends,
    /// so it is `advance` with the token discarded.
    pub fn skipChild(self: *TokenCursor) MarkdownOnDemandError!void {
        _ = try self.advance();
    }

    /// Tokens already consumed. Equal to the document's `count` at the end.
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

fn expectMatchesScalarOracleAtWidth(comptime vlen: usize, input: []const u8) !void {
    var expected = try scalarIndexMarkdown(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    var actual = try indexMarkdownImpl(vlen, testing.allocator, input);
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

// Checks what a direct `markdownDiagnosticAt` call reports at `byte_offset`:
// line, column, snippet and the snippet's start offset.
fn expectDiagnosticAt(
    input: []const u8,
    byte_offset: usize,
    line: u32,
    column: u32,
    snippet: []const u8,
    snippet_start: usize,
) !void {
    const diagnostic = markdownDiagnosticAt(input, error.InvalidTokenIndex, byte_offset);
    try testing.expectEqual(error.InvalidTokenIndex, diagnostic.err);
    try testing.expectEqual(@min(byte_offset, input.len), diagnostic.byte_offset);
    try testing.expectEqual(line, diagnostic.line);
    try testing.expectEqual(column, diagnostic.column);
    try testing.expectEqualStrings(snippet, diagnostic.snippet);
    try testing.expectEqual(snippet_start, diagnostic.snippet_start);
}

// Checks what `validateMarkdownIndex` reports for a one-entry index that
// claims a heading at `byte_offset` the scanner does not produce there.
fn expectForgedIndexDiagnostic(
    input: []const u8,
    byte_offset: usize,
    line: u32,
    column: u32,
    snippet: []const u8,
    snippet_start: usize,
) !void {
    var indexes = [_]u32{@intCast(byte_offset)};
    var kinds = [_]MarkdownTokenKind{.heading};
    const forged: MarkdownStructuralIndex = .{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 1,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(error.InvalidTokenIndex, diagnostic.err);
    try testing.expectEqual(byte_offset, diagnostic.byte_offset);
    try testing.expectEqual(line, diagnostic.line);
    try testing.expectEqual(column, diagnostic.column);
    try testing.expectEqualStrings(snippet, diagnostic.snippet);
    try testing.expectEqual(snippet_start, diagnostic.snippet_start);
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

test "Markdown scanning preserves CRLF at SIMD edges" {
    inline for ([_]usize{ 4, 16, 32, 64 }) |vlen| {
        var input: [96]u8 = @splat('x');
        input[0] = '#';
        input[vlen - 1] = '\r';
        input[vlen] = '\n';

        const second_start = vlen + 1;
        input[second_start] = '[';
        input[second_start + 2] = ']';
        input[second_start + 3] = '(';
        input[second_start + 5] = ')';
        input[second_start + 6] = '\n';

        const third_start = second_start + 7;
        input[third_start] = '#';
        try expectMatchesScalarOracleAtWidth(vlen, input[0 .. third_start + 1]);
    }
}

fn expectMarkdownLineTerminatorsAtWidth(comptime vlen: usize) !void {
    // A block that holds no terminator must extend the current line instead of
    // ending it, so every terminator position inside, on, and just past a block
    // boundary has to resolve to the same line split as the scalar oracle.
    const terminators = [_][]const u8{ "\n", "\r", "\r\n" };
    for (terminators) |terminator| {
        for ([_]usize{ vlen - 1, vlen, vlen + 1, 2 * vlen }) |terminator_offset| {
            var input: [3 * vlen + 8]u8 = @splat('x');
            input[0] = '#';
            @memcpy(input[terminator_offset..][0..terminator.len], terminator);

            const next_line = terminator_offset + terminator.len;
            input[next_line] = '#';
            input[next_line + 1] = ' ';
            input[next_line + 3] = '[';
            input[next_line + 4] = ']';
            input[next_line + 5] = '\n';

            try expectMatchesScalarOracleAtWidth(vlen, input[0 .. next_line + 6]);
        }
    }
}

test "Markdown line scanning stays exact at narrow and unaligned widths" {
    const prefix = ("abcdefghijklmnopqrstuvwxyz" ** 12) ++ "\r\n";
    const input = prefix ++
        "# heading\r\n" ++
        "- item [link](target)\n" ++
        "> quote\n" ++
        "`ab`\n";
    const expected_indexes = [_]u32{
        prefix.len,      prefix.len + 11, prefix.len + 18,
        prefix.len + 23, prefix.len + 24, prefix.len + 31,
        prefix.len + 33, prefix.len + 41, prefix.len + 44,
    };
    const expected_kinds = [_]MarkdownTokenKind{
        .heading,
        .list_item,
        .link_open,
        .link_close,
        .link_open,
        .link_close,
        .blockquote,
        .inline_code,
        .inline_code,
    };

    inline for ([_]usize{ 4, 5, 6, 7, 9, 12, 17, 20, 24, 48, 65, 72 }) |vlen| {
        var index = try indexMarkdownImpl(vlen, testing.allocator, input);
        defer index.deinit(testing.allocator);

        try expectIndexInvariants(input, &index);
        try testing.expectEqual(expected_indexes.len, index.count);
        try testing.expectEqualSlices(u32, &expected_indexes, index.indexes[0..index.count]);
        try testing.expectEqualSlices(MarkdownTokenKind, &expected_kinds, index.kinds[0..index.count]);

        try expectMarkdownLineTerminatorsAtWidth(vlen);
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
    const oversized_tape: MarkdownStructuralIndex = .{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = oversized_count,
    };
    try testing.expectError(
        error.TapeTooLarge,
        validateMarkdownIndex("#", &oversized_tape),
    );

    const invalid_count: MarkdownStructuralIndex = .{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 2,
    };
    const diagnostic = (try validateMarkdownIndex("#", &invalid_count)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(error.InvalidIndexCount, diagnostic.err);
    try testing.expectEqual(@as(usize, 1), diagnostic.byte_offset);
}

test "Markdown Stage2 rejects forged out-of-range offsets" {
    const input = "# heading";
    var indexes = [_]u32{@intCast(input.len)};
    var kinds = [_]MarkdownTokenKind{.heading};
    const forged: MarkdownStructuralIndex = .{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 1,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)) orelse
        return error.TestUnexpectedResult;
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
    const forged: MarkdownStructuralIndex = .{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 2,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(error.InvalidTokenOrder, diagnostic.err);
    try testing.expectEqual(@as(usize, 0), diagnostic.byte_offset);
}

test "Markdown Stage2 rejects forged kind and source mismatches" {
    const input = "\n  # heading";
    var indexes = [_]u32{3};
    var kinds = [_]MarkdownTokenKind{.blockquote};
    const forged: MarkdownStructuralIndex = .{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 1,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)) orelse
        return error.TestUnexpectedResult;
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
    const forged: MarkdownStructuralIndex = .{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 1,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(error.InvalidTokenKind, diagnostic.err);
    try testing.expectEqual(@as(usize, 0), diagnostic.byte_offset);
}

test "Markdown Stage2 rejects forged mid-line heading" {
    const input = "text # heading\n";
    var indexes = [_]u32{5};
    var kinds = [_]MarkdownTokenKind{.heading};
    const forged: MarkdownStructuralIndex = .{
        .indexes = &indexes,
        .kinds = &kinds,
        .count = 1,
    };

    const diagnostic = (try validateMarkdownIndex(input, &forged)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(error.InvalidTokenKind, diagnostic.err);
    try testing.expectEqual(@as(usize, 5), diagnostic.byte_offset);
}

test "parser audit: markdown diagnostic counts CR, LF and CRLF line endings" {
    const cr = "# a\r# b\r";
    const lf = "# a\n# b\n";
    const crlf = "# a\r\n# b\r\n";

    // A line-ending byte belongs to the line it terminates, so the marker that
    // opens the second line is line 2 column 1 in every style.
    try expectDiagnosticAt(cr, 3, 1, 4, "# a", 0);
    try expectDiagnosticAt(cr, 4, 2, 1, "# b", 4);
    try expectDiagnosticAt(lf, 3, 1, 4, "# a", 0);
    try expectDiagnosticAt(lf, 4, 2, 1, "# b", 4);

    // A CRLF pair is one two-byte ending: offset 3 is its CR and offset 4 its
    // LF, both still on line 1, and only offset 5 opens line 2.
    try expectDiagnosticAt(crlf, 3, 1, 4, "# a", 0);
    try expectDiagnosticAt(crlf, 4, 1, 5, "# a", 0);
    try expectDiagnosticAt(crlf, 5, 2, 1, "# b", 5);

    // Columns are one-based byte positions, so the marker that follows a
    // two-byte scalar is column 3.
    const multibyte = "é# b\r# c\r";
    try expectDiagnosticAt(multibyte, 2, 1, 3, "é# b", 0);
    try expectDiagnosticAt(multibyte, 6, 2, 1, "# c", 6);
}

test "parser audit: markdown diagnostic snippets exclude line-ending bytes" {
    const cr = "# a\r# b\r";
    const lf = "# a\n# b\n";
    const crlf = "# a\r\n# b\r\n";

    // The snippet holds line content only: no lone CR, and neither byte of a
    // CRLF pair.
    try expectDiagnosticAt(cr, 3, 1, 4, "# a", 0);
    try expectDiagnosticAt(cr, 7, 2, 4, "# b", 4);
    try expectDiagnosticAt(lf, 3, 1, 4, "# a", 0);
    try expectDiagnosticAt(lf, 7, 2, 4, "# b", 4);
    try expectDiagnosticAt(crlf, 3, 1, 4, "# a", 0);
    try expectDiagnosticAt(crlf, 4, 1, 5, "# a", 0);
    try expectDiagnosticAt(crlf, 8, 2, 4, "# b", 5);
    try expectDiagnosticAt(crlf, 9, 2, 5, "# b", 5);
}

test "parser audit: markdown diagnostic bounds snippets at sixteen bytes each side" {
    const long_line = "a" ** 40;
    try expectDiagnosticAt(long_line, 0, 1, 1, long_line[0..16], 0);
    try expectDiagnosticAt(long_line, 4, 1, 5, long_line[0..20], 0);
    try expectDiagnosticAt(long_line, 20, 1, 21, long_line[4..36], 4);
    try expectDiagnosticAt(long_line, 39, 1, 40, long_line[23..40], 23);

    // The window stops at the line start, the line end, or the input end.
    const two_lines = "0123456789\n" ++ "abcdefghijklmnopqrstuvwxyz0123456789";
    try expectDiagnosticAt(two_lines, 11, 2, 1, two_lines[11..27], 11);
    try expectDiagnosticAt(two_lines, 19, 2, 9, two_lines[11..35], 11);
    try expectDiagnosticAt(two_lines, 41, 2, 31, two_lines[25..47], 25);
}

test "parser audit: markdown diagnostic reports end of input and clamps later offsets" {
    const cr = "# a\r# b";
    const lf = "# a\n# b";
    const crlf = "# a\r\n# b";

    // End of input is one past the last byte of the line it closes.
    try expectDiagnosticAt(cr, cr.len, 2, 4, "# b", 4);
    try expectDiagnosticAt(lf, lf.len, 2, 4, "# b", 4);
    try expectDiagnosticAt(crlf, crlf.len, 2, 4, "# b", 5);

    // An offset past the input reports that clamped end of input.
    try expectDiagnosticAt(cr, cr.len + 1000, 2, 4, "# b", 4);
    try expectDiagnosticAt(crlf, std.math.maxInt(usize), 2, 4, "# b", 5);

    // A trailing line ending opens the empty line that follows it.
    try expectDiagnosticAt("# a\n# b\n", 8, 3, 1, "", 8);
    try expectDiagnosticAt("# a\r# b\r", 8, 3, 1, "", 8);
    try expectDiagnosticAt("# a\r\n# b\r\n", 10, 3, 1, "", 10);
}

test "parser audit: markdown diagnostic from a forged index counts CR line endings" {
    const cr = "# a\r# b\r";
    const lf = "# a\n# b\n";
    const crlf = "# a\r\n# b\r\n";

    // The validator fails on the supplied offset, so the diagnostic it builds
    // carries the same coordinates a direct call reports.
    try expectForgedIndexDiagnostic(cr, 4, 2, 1, "# b", 4);
    try expectForgedIndexDiagnostic(lf, 4, 2, 1, "# b", 4);
    try expectForgedIndexDiagnostic(crlf, 5, 2, 1, "# b", 5);
}

test "Markdown marker source spans preserve fences and ordered markers" {
    const input =
        "### heading\r\n12. item\n````lang\nx\n````\n";
    var index = try indexMarkdown(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &.{ 0, 13, 22, 33 }, index.indexes[0..index.count]);
    try testing.expectEqualStrings("#", index.sourceSpan(0, input) orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("12.", index.sourceSpan(1, input) orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("````", index.sourceSpan(2, input) orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("````", index.sourceSpan(3, input) orelse return error.TestUnexpectedResult);
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

    const first = (try reader.peek()) orelse return error.TestUnexpectedResult;
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
