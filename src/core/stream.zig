const std = @import("std");
const stage1 = @import("stage1.zig");
const simd = @import("simd.zig");

const assert = std.debug.assert;
const testing = std.testing;

const sentinel_count: usize = 3;
const lookahead_max: usize = 9;

/// The resident padding after each input slot. It covers one SIMD load and the
/// longest Stage 1 lookahead, so a later streaming format can reuse the buffer.
pub const SAFE_PAD: usize = simd.default_vector_len + lookahead_max;

comptime {
    assert(SAFE_PAD > simd.default_vector_len);
}

pub const CarryState = struct {
    in_string: bool = false,
    ends_in_backslash: bool = false,
    backslash_run_odd: bool = false,
    in_atom: bool = false,
};

/// Incrementally builds the same JSON StructuralIndex as the one-shot Stage 1
/// indexer. Input bytes are copied through two fixed, padded slots allocated by
/// init; feed never allocates or replaces that input buffer.
pub const StreamIndexer = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    slot_len: usize,
    slot_stride: usize,
    active_slot: usize = 0,
    fill: usize = 0,
    processed_len: usize = 0,
    input_len: usize = 0,
    carry: CarryState = .{},
    index: ?stage1.StructuralIndex,
    finished: bool = false,

    const Self = @This();

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

    /// Allocates both padded input slots and the initial structural storage.
    /// chunk_len is rounded up so every non-final processed slot is SIMD-wide.
    pub fn init(
        allocator: std.mem.Allocator,
        chunk_len: usize,
    ) InitError!Self {
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
            SAFE_PAD,
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
                self.processBytes(slot[0..self.slot_len]);
                self.fill = 0;
                self.active_slot ^= 1;
            }
        }

        assert(self.processed_len + self.fill == self.input_len);
    }

    /// Flushes the final partial slot and writes the StructuralIndex sentinels.
    /// Repeated calls are harmless and do not duplicate output.
    pub fn finish(self: *Self) FinishError!void {
        if (self.finished) return;

        try self.ensureIndexCapacity(self.input_len);
        if (self.fill > 0) {
            const slot = self.activeSlot();
            self.processBytes(slot[0..self.fill]);
            self.fill = 0;
        }

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

    fn processBytes(self: *Self, data: []const u8) void {
        const VLEN = simd.default_vector_len;
        const Mask = simd.Mask(VLEN);
        const Shift = std.math.Log2Int(Mask);
        assert(data.len <= self.slot_len);
        assert(self.index != null);
        assert(self.processed_len + data.len <= self.input_len);

        var windows = simd.windows(u8, VLEN, data, 0);
        var local_offset: usize = 0;
        while (local_offset < data.len) : (local_offset += VLEN) {
            const chunk = windows.next().?;
            const valid_count = @min(data.len - local_offset, VLEN);
            const valid_mask = validByteMask(VLEN, valid_count);
            const top_bit: Mask = @as(Mask, 1) <<
                @as(Shift, @intCast(VLEN - 1));

            const backslashes = simd.matchByte(VLEN, chunk, '\\') & valid_mask;
            const backslash_result = simd.computeBackslashRuns(
                Mask,
                backslashes,
                self.carry.ends_in_backslash,
            );
            var odd_backslash_ends =
                backslash_result.odd_length_ends & valid_mask;
            if (self.carry.ends_in_backslash) {
                if ((backslashes & @as(Mask, 1)) == 0) {
                    if (self.carry.backslash_run_odd) {
                        odd_backslash_ends |= 1;
                    } else {
                        odd_backslash_ends &= ~@as(Mask, 1);
                    }
                } else if (self.carry.backslash_run_odd) {
                    odd_backslash_ends ^=
                        leadingRunEndMask(VLEN, backslashes, valid_count);
                }
            }

            const quotes = simd.matchByte(VLEN, chunk, '"') & valid_mask;
            const unescaped_quotes = quotes & ~odd_backslash_ends;
            const inside_without_closing =
                simd.prefixXor(Mask, unescaped_quotes) ^
                if (self.carry.in_string) ~@as(Mask, 0) else 0;
            const opening_quotes = unescaped_quotes & inside_without_closing;
            const string_mask = inside_without_closing | unescaped_quotes;
            const outside_string = ~string_mask & valid_mask;

            const structural =
                simd.matchAny4(VLEN, chunk, '{', '}', '[', ']') |
                simd.matchAny2(VLEN, chunk, ':', ',');
            const whitespace =
                simd.matchAny4(VLEN, chunk, ' ', '\t', '\n', '\r');
            const atom_candidates =
                simd.matchRange(VLEN, chunk, '0', '9') |
                simd.matchAny4(VLEN, chunk, '-', 't', 'f', 'n');
            const atom_active =
                outside_string & ~(structural | whitespace | quotes);
            const atom_starts = atom_candidates & atom_active &
                ~((atom_active << @as(Shift, 1)) |
                    if (self.carry.in_atom) @as(Mask, 1) else 0);
            const structural_indexes =
                ((structural | atom_starts) & outside_string) |
                opening_quotes;

            var candidates: [VLEN]u32 = undefined;
            const candidate_count = simd.extractBitIndexes(
                Mask,
                structural_indexes,
                self.processed_len + local_offset,
                &candidates,
            );
            const index = self.indexPtr();
            assert(index.count + candidate_count + sentinel_count <=
                index.indexes.len);
            @memcpy(
                index.indexes[index.count..][0..candidate_count],
                candidates[0..candidate_count],
            );
            index.count += candidate_count;

            self.carry.in_string = (inside_without_closing & top_bit) != 0;
            self.carry.ends_in_backslash = valid_count == VLEN and
                (backslashes & top_bit) != 0;
            self.carry.backslash_run_odd = trailingBackslashRunOdd(
                VLEN,
                chunk,
                valid_count,
                self.carry.backslash_run_odd,
            );
            self.carry.in_atom = valid_count != 0 and
                (atom_active & (@as(Mask, 1) <<
                    @as(Shift, @intCast(valid_count - 1)))) != 0;
        }

        self.processed_len += data.len;
    }
};

fn validByteMask(
    comptime VLEN: usize,
    valid_count: usize,
) simd.Mask(VLEN) {
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);

    if (valid_count == VLEN) return ~@as(Mask, 0);
    if (valid_count == 0) return 0;
    return (@as(Mask, 1) << @as(Shift, @intCast(valid_count))) - 1;
}

fn leadingRunEndMask(
    comptime VLEN: usize,
    backslashes: simd.Mask(VLEN),
    valid_count: usize,
) simd.Mask(VLEN) {
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);

    const non_backslashes = ~backslashes | ~validByteMask(VLEN, valid_count);
    if (non_backslashes == 0) return 0;
    const run_length: usize = @intCast(@ctz(non_backslashes));
    if (run_length >= valid_count) return 0;
    return @as(Mask, 1) << @as(Shift, @intCast(run_length));
}

fn trailingBackslashRunOdd(
    comptime VLEN: usize,
    chunk: simd.Vec(VLEN, u8),
    valid_count: usize,
    previous_run_odd: bool,
) bool {
    if (valid_count == 0) return false;

    const bytes: [VLEN]u8 = chunk;
    var run_length: usize = 0;
    var index = valid_count;
    while (index > 0 and bytes[index - 1] == '\\') : (index -= 1) {
        run_length += 1;
    }
    if (index == 0) return (run_length % 2 == 0) == previous_run_odd;
    return run_length % 2 != 0;
}

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

fn expectEveryFeedPartition(input: []const u8) !void {
    var expected = try scalarIndexJson(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    for (0..input.len + 1) |split| {
        var stream = try StreamIndexer.init(testing.allocator, 3);
        defer stream.deinit();

        try stream.feed(input[0..split]);
        try stream.feed("");
        try stream.feed(input[split..]);
        try stream.finish();

        var actual = stream.take();
        defer actual.deinit(testing.allocator);
        try expectIndexEqual(&expected, &actual);
    }

    var byte_stream = try StreamIndexer.init(testing.allocator, 1);
    defer byte_stream.deinit();
    for (input) |byte| {
        try byte_stream.feed(&.{byte});
    }
    try byte_stream.finish();

    var byte_actual = byte_stream.take();
    defer byte_actual.deinit(testing.allocator);
    try expectIndexEqual(&expected, &byte_actual);
}

test "JSON stream matches one-shot indexes at quote and escape boundaries" {
    // Odd and even backslash runs cross every possible two-feed boundary.
    const input = [_]u8{
        '{', '"', 'o', 'd', 'd', '"', ':', '"', 'a', '\\', '\\', '\\', '"', 'b', '"', ',',
        '"', 'e', 'v', 'e', 'n', '"', ':', '"', 'c', '\\', '\\', '"',  ',', '"', 'x', '"',
        ':', '"', '{', '[', ',', ':', ']', '}', '"', '}',
    };
    try expectEveryFeedPartition(&input);
}

test "JSON stream matches one-shot indexes for split atoms and sentinels" {
    const input = "[true,false,null,-1234567890,0,{\"tail\":42}]";
    try expectEveryFeedPartition(input);
}

test "JSON stream carries state across SIMD slots" {
    const input =
        "{\"alpha\":\"abcdefghijklmnopqrstuvwxyz0123456789" ++
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ\\\\\\\"tail\"," ++
        "\"values\":[true,false,null,-12345678901234567890]," ++
        "\"nested\":{\"punctuation\":\"{}[],:\"}}";
    try expectEveryFeedPartition(input);
}

test "JSON stream take transfers ownership and reset starts at offset zero" {
    var stream = try StreamIndexer.init(testing.allocator, 2);
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
