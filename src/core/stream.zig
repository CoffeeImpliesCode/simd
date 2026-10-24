//! Incremental structural indexing for JSON, JSONC, JSON5 and strict JSONL.
//!
//! Use `StreamIndexer.init`, `feed` or `feedFrom`, `finish`, then `take`.
//! Release the transferred index with the construction allocator and deinitialize
//! the indexer separately. Input chunks are copied and need not survive a feed.
//! This module validates neither grammar nor UTF-8 and retains no complete source:
//! Stage 2 needs the caller's complete immutable input independently of this index.

const std = @import("std");
const stage1 = @import("stage1.zig");
const simd = @import("simd.zig");
const lexical = @import("json_lexical.zig");

const assert = std.debug.assert;
const testing = std.testing;

const sentinel_count: usize = 3;
const lookahead_max: usize = 9;

/// The resident padding after each input slot. It covers one SIMD load and the
/// longest Stage 1 lookahead, so a later streaming format can reuse the buffer.
pub const safe_pad: usize = simd.default_vector_len + lookahead_max;

comptime {
    assert(safe_pad > simd.default_vector_len);
}

/// Lexical rules for one document. JSONL framing is selected separately by `Mode`.
pub const Dialect = enum {
    json,
    jsonc,
    json5,
};

/// Framing of the indexed input, not a Stage 2 grammar or traversal mode.
pub const Mode = enum {
    /// Default: index one JSON-family document without treating LF as a record boundary.
    document,
    /// Strict JSON records separated by LF; requires `Options.dialect == .json`.
    jsonl,
};

/// Required dialect and framing for one indexer; no mixed JSONC/JSON5 JSONL profile.
pub const Options = struct {
    /// Quote, atom and comment rules. Required because the input determines the dialect.
    dialect: Dialect,
    /// Defaults to one document. Select `.jsonl` only with `.json`, otherwise
    /// `StreamIndexer.init` returns `error.InvalidOptions` before allocating.
    mode: Mode = .document,
};

/// The same lexical comment state as `json_lexical.CommentState`; its owner
/// documents each state and transition. This alias adds no ownership or checks.
pub const CommentState = lexical.CommentState;
/// The complete `json_lexical.State` carried by `StreamIndexer.carry`.
/// Its owner documents the fields, copied scan position and contiguity rule;
/// callers must not mutate this state independently of the indexer.
pub const CarryState = lexical.State;
/// Single owner of two padded input slots and, until `take`, one structural index.
///
/// Construct with `init`; call `deinit` exactly once with no simultaneous operation.
/// Copies alias allocations and are not independent owners. The stored allocator's
/// identity and backing state must survive cleanup; do not replace it while live.
/// No stable address is needed if no pointer to this value is retained by a caller.
/// All fields are reachable, but changing allocation, counters or lexical state
/// outside these methods violates the indexer's invariants. Mutating use is exclusive.
pub const StreamIndexer = struct {
    /// Construction allocator, borrowed through `deinit` and transferred index disposal.
    allocator: std.mem.Allocator,
    /// Immutable lexical/framing selection for the current indexer.
    options: Options,
    /// Owned slots, invalid after `deinit`; input must not alias this storage.
    buffer: []u8,
    /// Usable bytes in each slot, rounded up to a multiple of the configured SIMD width.
    slot_len: usize,
    /// Bytes between slot starts, including `safe_pad`.
    slot_stride: usize,
    /// Current slot number, 0 or 1.
    active_slot: usize = 0,
    /// Unprocessed bytes in the current slot.
    fill: usize = 0,
    /// Source bytes already indexed; offsets are absolute from this document's start.
    processed_len: usize = 0,
    /// Total accepted source bytes, at most `maxInt(u32)`.
    input_len: usize = 0,
    /// Scanner state across chunks, reset by `reset`.
    carry: lexical.State = .{},
    /// Owned unfinished/finalized index; `null` after ownership transfers through `take`.
    index: ?stage1.StructuralIndex,
    /// True after successful `finish`; `feed` then returns `error.AlreadyFinished`.
    finished: bool = false,

    const Self = StreamIndexer;

    /// Initialization failures; no allocation escapes an error return.
    pub const InitError = stage1.StructuralIndex.InitError || error{InvalidOptions};
    /// Feed failures; size/reservation errors leave the previously accepted input intact.
    pub const FeedError = std.mem.Allocator.Error || error{
        AlreadyFinished,
        CapacityExceeded,
        CapacityOverflow,
        InputTooLarge,
    };
    /// Finalization failures; no index transfers before a successful `take`.
    pub const FinishError = std.mem.Allocator.Error || error{
        CapacityExceeded,
        CapacityOverflow,
        InputTooLarge,
    };
    /// Feed/finalization failures plus the supplied Reader's `error.ReadFailed`.
    pub const FeedFromError = FeedError ||
        FinishError ||
        std.Io.Reader.ShortError;

    /// Allocates both padded slots and initial structural storage, owned by the result.
    /// `chunk_len` is a requested byte count: zero and smaller widths become one
    /// SIMD block, larger values round up. Arithmetic overflow is `error.CapacityOverflow`.
    /// Mixed JSONL/comment dialects fail with `error.InvalidOptions` before allocation.
    /// On every error all allocations made here are released; no input is retained.
    pub fn init(
        allocator: std.mem.Allocator,
        chunk_len: usize,
        options: Options,
    ) InitError!StreamIndexer {
        if (options.mode == .jsonl and options.dialect != .json) return error.InvalidOptions;

        const requested_len = @max(chunk_len, simd.default_vector_len);
        const rounded_len = std.math.add(
            usize,
            requested_len,
            simd.default_vector_len - 1,
        ) catch return error.CapacityOverflow;
        const slot_len = @divFloor(
            rounded_len,
            simd.default_vector_len,
        ) * simd.default_vector_len;
        const slot_stride = std.math.add(
            usize,
            slot_len,
            safe_pad,
        ) catch return error.CapacityOverflow;
        const buffer_len = std.math.mul(
            usize,
            slot_stride,
            2,
        ) catch return error.CapacityOverflow;

        var index = try stage1.StructuralIndex.init(allocator, slot_len);
        errdefer index.deinit(allocator);

        const buffer = try allocator.alloc(u8, buffer_len);
        @memset(buffer, 0);

        return .{
            .allocator = allocator,
            .options = options,
            .buffer = buffer,
            .slot_len = slot_len,
            .slot_stride = slot_stride,
            .index = index,
        };
    }

    /// Releases owned slots and any untaken index exactly once. A taken index remains
    /// the caller's responsibility. The indexer is unusable afterward, including copies.
    pub fn deinit(self: *Self) void {
        if (self.index) |*index| {
            index.deinit(self.allocator);
        }
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    /// Copies `data` into this document and emits absolute offsets from its first byte.
    /// `data` is borrowed only during the call and must not overlap the owned slots.
    /// After `finish`, returns `error.AlreadyFinished` without accepting data.
    /// Size/reservation failures accept no bytes and preserve prior logical state.
    /// A later `error.CapacityExceeded` can leave copied slots, emitted offsets
    /// and advanced scanner state, while `input_len` already counts all of `data`,
    /// including any uncopied tail. No index transfers. Discard the partial
    /// document with `reset`, or release the indexer with `deinit`; do not retry
    /// the same chunk or finalize that partial state.
    pub fn feed(self: *Self, data: []const u8) FeedError!void {
        if (self.finished) return error.AlreadyFinished;

        const new_input_len = std.math.add(
            usize,
            self.input_len,
            data.len,
        ) catch return error.CapacityOverflow;
        if (new_input_len > std.math.maxInt(u32)) return error.InputTooLarge;

        // Reserve for the worst case before changing lexical or buffer state.
        try self.ensureIndexCapacity(new_input_len);

        self.input_len = new_input_len;

        var remaining = data;
        while (remaining.len > 0) {
            const copy_count = @min(remaining.len, self.slot_len - self.fill);
            const slot = self.activeSlot();
            @memcpy(
                slot[self.fill..][0..copy_count],
                remaining[0..copy_count],
            );
            self.fill += copy_count;
            remaining = remaining[copy_count..];

            if (self.fill == self.slot_len) {
                try self.processBytes(slot[0..self.slot_len]);
                self.fill = 0;
                self.active_slot ^= 1;
            }
        }

        assert(self.processed_len + self.fill == self.input_len);
    }
    /// Consumes the supplied Reader until EOF, then calls `finish`.
    /// The Reader and its backing provider must stay live during this call; neither
    /// is retained. Reading may block. Provider failures, including cancellation
    /// reported by a provider, arrive as `error.ReadFailed`; inspect that provider
    /// for its cause. This method does not return `error.Canceled` directly.
    /// On error, earlier successful feeds remain accepted and their bytes consumed;
    /// the current Reader bytes are not tossed if their feed fails. Reset to discard
    /// partial indexing. Success still requires `take` and separate owner disposal.
    pub fn feedFrom(
        self: *Self,
        reader: *std.Io.Reader,
    ) FeedFromError!void {
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

    /// Flushes buffered input and appends sentinels; success enables one `take`.
    /// Repeated successful calls are harmless. Allocation/size failures during
    /// reservation preserve logical state and may be retried; for any later
    /// scanner/capacity failure use `reset` or `deinit`, not a retry of this document.
    /// No source or index transfers on error, and this performs no grammar validation.
    pub fn finish(self: *Self) FinishError!void {
        if (self.finished) return;

        try self.ensureIndexCapacity(self.input_len);
        if (self.fill > 0) {
            const slot = self.activeSlot();
            try self.processBytes(slot[0..self.fill]);
            self.fill = 0;
        }

        try self.finishLexical();
        assert(self.processed_len == self.input_len);
        try self.indexPtr().finish(self.input_len);
        self.finished = true;
    }

    /// Transfers the finalized index without copying; dispose it with the construction
    /// allocator. Requires successful `finish` and no previous `take` since `reset`.
    /// Violating either precondition is diagnosed by assertions in Debug/ReleaseSafe
    /// and is unchecked illegal behavior in ReleaseFast/ReleaseSmall.
    /// This index owns offsets, not the bytes needed by a Stage 2 consumer.
    pub fn take(self: *Self) stage1.StructuralIndex {
        assert(self.finished);
        assert(self.index != null);

        const result = self.index.?;
        self.index = null;
        return result;
    }

    /// Discards the current logical document, including a failed one. Retains owned
    /// allocations; after `take`, the next feed/finalization allocates a new index.
    /// A previously transferred index remains independent and is not released here.
    /// Offsets restart at zero. Borrowed views of untaken index contents lose validity.
    pub fn reset(self: *Self) void {
        if (self.index) |*index| {
            index.count = 0;
        }
        self.active_slot = 0;
        self.fill = 0;
        self.processed_len = 0;
        self.input_len = 0;
        self.carry = .{};
        self.finished = false;
    }

    fn activeSlot(self: *Self) []u8 {
        assert(self.active_slot < 2);
        const start = self.active_slot * self.slot_stride;
        return self.buffer[start..][0..self.slot_len];
    }

    fn indexPtr(self: *Self) *stage1.StructuralIndex {
        if (self.index) |*index| return index;
        unreachable;
    }

    fn ensureIndexCapacity(
        self: *Self,
        input_capacity: usize,
    ) (std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    })!void {
        if (input_capacity > std.math.maxInt(u32)) return error.InputTooLarge;

        const required_len = std.math.add(
            usize,
            input_capacity,
            sentinel_count,
        ) catch return error.CapacityOverflow;

        if (self.index == null) {
            self.index = try stage1.StructuralIndex.init(
                self.allocator,
                @max(input_capacity, self.slot_len),
            );
            return;
        }
        const index = self.indexPtr();
        if (required_len <= index.indexes.len) return;

        const doubled_len = std.math.mul(
            usize,
            index.indexes.len,
            2,
        ) catch required_len;
        const allocation_len = @max(required_len, doubled_len);
        index.indexes = try self.allocator.realloc(
            index.indexes,
            allocation_len,
        );
    }

    fn processBytes(self: *Self, data: []const u8) FinishError!void {
        assert(data.len <= self.slot_len);
        assert(self.index != null);
        assert(self.processed_len + data.len <= self.input_len);

        var sink: ScanSink = .{ .owner = self };
        switch (self.lexicalMode()) {
            inline else => |mode| lexical.feed(
                simd.default_vector_len,
                mode,
                &self.carry,
                data,
                self.processed_len,
                &sink,
            ) catch |err| switch (err) {
                error.NonContiguousInput => unreachable,
                error.CapacityExceeded => return error.CapacityExceeded,
                error.InputTooLarge => return error.InputTooLarge,
            },
        }
        self.processed_len += data.len;
    }

    fn finishLexical(self: *Self) FinishError!void {
        var sink: ScanSink = .{ .owner = self };
        switch (self.lexicalMode()) {
            inline else => |mode| lexical.finish(mode, &self.carry, &sink) catch |err| switch (err) {
                error.NonContiguousInput => unreachable,
                error.CapacityExceeded => return error.CapacityExceeded,
                error.InputTooLarge => return error.InputTooLarge,
            },
        }
    }

    fn lexicalMode(self: *const Self) lexical.Mode {
        if (self.options.mode == .jsonl) return .jsonl;
        return switch (self.options.dialect) {
            .json => .json,
            .jsonc => .jsonc,
            .json5 => .json5,
        };
    }
};

const ScanSink = struct {
    owner: *StreamIndexer,

    pub fn appendOffset(self: *ScanSink, offset: usize) lexical.Error!void {
        if (offset > std.math.maxInt(u32)) return error.InputTooLarge;
        const index = self.owner.indexPtr();
        if (index.count >= index.indexes.len - sentinel_count) {
            return error.CapacityExceeded;
        }
        index.indexes[index.count] = @intCast(offset);
        index.count += 1;
    }

    pub fn appendMask(
        self: *ScanSink,
        comptime T: type,
        mask: T,
        base_offset: usize,
    ) lexical.Error!void {
        const index = self.owner.indexPtr();
        if (index.count > index.indexes.len - sentinel_count) {
            return error.CapacityExceeded;
        }
        const output = index.indexes[index.count .. index.indexes.len - sentinel_count];
        const written = try simd.extractBitIndexesChecked(
            T,
            mask,
            base_offset,
            output,
        );
        index.count += written;
    }
};

fn scalarIndexJson(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var backslash_run_length: usize = 0;
    var previous_in_atom = false;
    for (input, 0..) |byte, offset| {
        if (byte == '"' and backslash_run_length % 2 == 0) {
            if (!in_string) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            }
            in_string = !in_string;
        } else if (!in_string) {
            if (isStructuralByte(byte)) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            } else if (isAtomByte(byte) and !previous_in_atom) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            }
        }

        previous_in_atom = !in_string and byte != '"' and
            !isStructuralByte(byte) and !isWhitespaceByte(byte);
        if (byte == '\\') {
            backslash_run_length += 1;
        } else {
            backslash_run_length = 0;
        }
    }

    try result.finish(input.len);
    return result;
}
fn scalarIndexJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var backslash_run_length: usize = 0;
    var previous_in_atom = false;
    for (input, 0..) |byte, offset| {
        const unescaped_quote = byte == '"' and backslash_run_length % 2 == 0;
        if (unescaped_quote) {
            if (!in_string) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            }
            in_string = !in_string;
        }

        if (!in_string) {
            if (isStructuralByte(byte) or byte == '\n') {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            } else if (isAtomByte(byte) and !previous_in_atom) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            }
        }

        previous_in_atom = !in_string and byte != '"' and
            !isStructuralByte(byte) and !isWhitespaceByte(byte);
        if (byte == '\\') {
            backslash_run_length += 1;
        } else {
            backslash_run_length = 0;
        }
    }

    try result.finish(input.len);
    return result;
}

fn isWhitespaceByte(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

fn isStructuralByte(byte: u8) bool {
    return switch (byte) {
        '{', '}', '[', ']', ':', ',' => true,
        else => false,
    };
}

fn isAtomByte(byte: u8) bool {
    return switch (byte) {
        '-', 't', 'f', 'n', '0'...'9' => true,
        else => false,
    };
}

fn expectIndexEqual(
    expected: *const stage1.StructuralIndex,
    actual: *const stage1.StructuralIndex,
) !void {
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + sentinel_count],
        actual.indexes[0 .. actual.count + sentinel_count],
    );
}

fn expectEveryFeedPartition(
    input: []const u8,
    options: Options,
) !void {
    var expected = if (options.mode == .jsonl)
        try scalarIndexJsonl(testing.allocator, input)
    else
        try scalarIndexJson(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    for (0..input.len + 1) |split| {
        var stream = try StreamIndexer.init(testing.allocator, 3, options);
        defer stream.deinit();

        try stream.feed(input[0..split]);
        try stream.feed("");
        try stream.feed(input[split..]);
        try stream.finish();

        var actual = stream.take();
        defer actual.deinit(testing.allocator);
        try expectIndexEqual(&expected, &actual);
    }

    var byte_stream = try StreamIndexer.init(testing.allocator, 1, options);
    defer byte_stream.deinit();
    for (input) |byte| {
        try byte_stream.feed(&.{byte});
    }
    try byte_stream.finish();

    var byte_actual = byte_stream.take();
    defer byte_actual.deinit(testing.allocator);
    try expectIndexEqual(&expected, &byte_actual);
}
fn expectEveryFeedPartitionAgainst(
    input: []const u8,
    options: Options,
    expected_offsets: []const u32,
) !void {
    var expected = try stage1.StructuralIndex.init(
        testing.allocator,
        input.len,
    );
    defer expected.deinit(testing.allocator);
    @memcpy(expected.indexes[0..expected_offsets.len], expected_offsets);
    expected.count = expected_offsets.len;
    try expected.finish(input.len);

    for (0..input.len + 1) |split| {
        var stream = try StreamIndexer.init(testing.allocator, 3, options);
        defer stream.deinit();
        try stream.feed(input[0..split]);
        try stream.feed(input[split..]);
        try stream.finish();
        var actual = stream.take();
        defer actual.deinit(testing.allocator);
        try expectIndexEqual(&expected, &actual);
    }

    var byte_stream = try StreamIndexer.init(testing.allocator, 1, options);
    defer byte_stream.deinit();
    for (input) |byte| try byte_stream.feed(&.{byte});
    try byte_stream.finish();
    var byte_actual = byte_stream.take();
    defer byte_actual.deinit(testing.allocator);
    try expectIndexEqual(&expected, &byte_actual);
}

const FaultingReader = struct {
    reader: std.Io.Reader,
    input: []const u8,
    offset: usize = 0,
    fail_at: usize,

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
    };

    fn init(
        input: []const u8,
        fail_at: usize,
        buffer: []u8,
    ) FaultingReader {
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
        const self: *FaultingReader = @alignCast(@fieldParentPtr("reader", reader));
        if (self.offset >= self.fail_at) return error.ReadFailed;

        const available = self.fail_at - self.offset;
        const count = @min(available, @backingInt(limit));
        if (count == 0) return 0;

        try writer.writeAll(self.input[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};

test "JSON stream reader adapter finishes when the reader reaches EOF" {
    const input = "{\"reader\":true}";
    var reader = std.Io.Reader.fixed(input);
    var stream = try StreamIndexer.init(
        testing.allocator,
        3,
        .{ .dialect = .json },
    );
    defer stream.deinit();

    try stream.feedFrom(&reader);

    try testing.expect(stream.finished);
    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    var expected = try scalarIndexJson(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try expectIndexEqual(&expected, &actual);
}

test "JSON stream reader adapter finishes an empty reader" {
    var reader = std.Io.Reader.fixed("");
    var stream = try StreamIndexer.init(
        testing.allocator,
        3,
        .{ .dialect = .json },
    );
    defer stream.deinit();

    try stream.feedFrom(&reader);

    try testing.expect(stream.finished);
    try testing.expectEqual(@as(usize, 0), stream.input_len);
    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    var expected = try scalarIndexJson(testing.allocator, "");
    defer expected.deinit(testing.allocator);
    try expectIndexEqual(&expected, &actual);
}

test "JSON stream reader adapter returns a reader error after buffered data" {
    const input = "[1]";
    var source_buffer: [2]u8 = undefined;
    var faulting = FaultingReader.init(input, input.len, &source_buffer);
    var stream = try StreamIndexer.init(
        testing.allocator,
        3,
        .{ .dialect = .json },
    );
    defer stream.deinit();

    try testing.expectError(error.ReadFailed, stream.feedFrom(&faulting.reader));
    try testing.expect(!stream.finished);
    try testing.expectEqual(input.len, stream.input_len);

    try stream.finish();
    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    var expected = try scalarIndexJson(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try expectIndexEqual(&expected, &actual);
}

test "JSON stream matches one-shot indexes at quote and escape boundaries" {
    // Odd and even backslash runs cross every possible two-feed boundary.
    const input = [_]u8{
        '{', '"', 'o', 'd', 'd', '"', ':', '"', 'a', '\\', '\\', '\\', '"', 'b', '"', ',',
        '"', 'e', 'v', 'e', 'n', '"', ':', '"', 'c', '\\', '\\', '"',  ',', '"', 'x', '"',
        ':', '{', '[', ',', ':', ']', '}', '"', '}',
    };
    try expectEveryFeedPartition(&input, .{ .dialect = .json });
}

test "JSONC stream carries comments without quote offsets" {
    const input = "{/*a*/\"x\":true,//tail\n\"y\":2}";
    // JSONC and JSON5 one-shot indexes intentionally omit quote offsets.
    const expected = [_]u32{ 0, 9, 10, 14, 25, 26, 27 };
    try expectEveryFeedPartitionAgainst(
        input,
        .{ .dialect = .jsonc },
        &expected,
    );
}

test "JSON5 stream carries atom boundaries without quote offsets" {
    const input = "{'x':+1,foo:0x2A}";
    const expected = [_]u32{ 0, 4, 5, 7, 8, 11, 12, 16 };
    try expectEveryFeedPartitionAgainst(
        input,
        .{ .dialect = .json5 },
        &expected,
    );
}

test "JSONL stream indexes LF records but not quoted LF" {
    const input = "{\"a\":1}\n{\"b\":\"line" ++
        "\n" ++
        "value\"}\r\n[true,false]\n";
    try expectEveryFeedPartition(
        input,
        .{ .dialect = .json, .mode = .jsonl },
    );
}

test "JSONL stream carries CRLF and LF across arbitrary feeds" {
    const input = "1\r\n2\n3\r\n";
    try expectEveryFeedPartition(
        input,
        .{ .dialect = .json, .mode = .jsonl },
    );
}

test "JSON stream take transfers ownership and reset starts at offset zero" {
    var stream = try StreamIndexer.init(
        testing.allocator,
        2,
        .{ .dialect = .json },
    );
    defer stream.deinit();

    try stream.feed("{\"first\":true}");
    try stream.finish();
    try stream.finish();
    var first = stream.take();

    stream.reset();
    try stream.feed("[-1,null]");
    try stream.finish();
    var second = stream.take();

    defer first.deinit(testing.allocator);
    defer second.deinit(testing.allocator);

    var expected_first = try scalarIndexJson(testing.allocator, "{\"first\":true}");
    defer expected_first.deinit(testing.allocator);
    var expected_second = try scalarIndexJson(testing.allocator, "[-1,null]");
    defer expected_second.deinit(testing.allocator);

    try expectIndexEqual(&expected_first, &first);
    try expectIndexEqual(&expected_second, &second);
}

// Conflicting dialect/framing must fail before the allocator is consulted.
test "JSONL rejects comment dialects before allocating" {
    inline for (.{ Dialect.jsonc, Dialect.json5 }) |dialect| {
        try testing.expectError(error.InvalidOptions, StreamIndexer.init(
            testing.failing_allocator,
            1,
            .{ .dialect = dialect, .mode = .jsonl },
        ));
    }
}
