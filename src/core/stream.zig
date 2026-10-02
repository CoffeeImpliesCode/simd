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

pub const Dialect = enum {
    json,
    jsonc,
    json5,
};

pub const Mode = enum {
    document,
    jsonl,
};

pub const Options = struct {
    dialect: Dialect,
    mode: Mode = .document,
};

pub const CommentState = lexical.CommentState;
pub const CarryState = lexical.State;
/// Incrementally builds a JSON-family StructuralIndex. Input bytes are copied
/// through two fixed, padded slots allocated by init; feed never allocates or
/// replaces that input buffer.
pub const StreamIndexer = struct {
    allocator: std.mem.Allocator,
    options: Options,
    buffer: []u8,
    slot_len: usize,
    slot_stride: usize,
    active_slot: usize = 0,
    fill: usize = 0,
    processed_len: usize = 0,
    input_len: usize = 0,
    carry: lexical.State = .{},
    index: ?stage1.StructuralIndex,
    finished: bool = false,

    const Self = StreamIndexer;

    pub const InitError = stage1.StructuralIndex.InitError;
    pub const FeedError = std.mem.Allocator.Error || error{
        AlreadyFinished,
        CapacityExceeded,
        CapacityOverflow,
        InputTooLarge,
    };
    pub const FinishError = std.mem.Allocator.Error || error{
        CapacityExceeded,
        CapacityOverflow,
        InputTooLarge,
    };
    pub const FeedFromError = FeedError ||
        FinishError ||
        std.Io.Reader.ShortError;

    /// Allocates both padded input slots and the initial structural storage.
    /// chunk_len is rounded up so every non-final processed slot is SIMD-wide.
    pub fn init(
        allocator: std.mem.Allocator,
        chunk_len: usize,
        options: Options,
    ) InitError!StreamIndexer {
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

    pub fn deinit(self: *Self) void {
        if (self.index) |*index| {
            index.deinit(self.allocator);
        }
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    /// Adds bytes to the current document. Offsets emitted during this call are
    /// absolute offsets from the first byte supplied after init or reset.
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
    /// Drains an optional Reader adapter into feed and finishes at EOF. Reader
    /// bytes are borrowed only for each feed call and are never retained.
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

    /// Flushes the final partial slot and writes the StructuralIndex sentinels.
    /// Repeated calls are harmless and do not duplicate output.
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

    /// Returns the finalized index without copying. The caller owns the result
    /// and must deinitialize it with the allocator passed to init.
    pub fn take(self: *Self) stage1.StructuralIndex {
        assert(self.finished);
        assert(self.index != null);

        const result = self.index.?;
        self.index = null;
        return result;
    }

    /// Starts a new document. Structural and input-buffer allocations are
    /// retained unless ownership of the structural index was moved by take.
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
        const count = @min(available, @intFromEnum(limit));
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
