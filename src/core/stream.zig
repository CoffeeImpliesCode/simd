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

pub const CommentState = enum {
    none,
    line,
    block,
};

pub const CarryState = struct {
    in_string: bool = false,
    in_atom: bool = false,
    ends_in_backslash: bool = false,
    quote_delimiter: u8 = 0,
    comment: CommentState = .none,
    backslash_run_odd: bool = false,
    pending_slash: bool = false,
    pending_escape: bool = false,
    pending_escape_offset: u32 = 0,
    pending_unicode_len: u2 = 0,
    pending_unicode: [3]u8 = .{ 0, 0, 0 },
    pending_unicode_offset: u32 = 0,
    block_comment_ends_in_star: bool = false,
};

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
    pub const FeedFromError = FeedError ||
        FinishError ||
        std.Io.Reader.ShortError;

    /// Allocates both padded input slots and the initial structural storage.
    /// chunk_len is rounded up so every non-final processed slot is SIMD-wide.
    pub fn init(
        allocator: std.mem.Allocator,
        chunk_len: usize,
        options: Options,
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
                self.processBytes(slot[0..self.slot_len]);
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
            self.processBytes(slot[0..self.fill]);
            self.fill = 0;
        }

        self.flushDeferred();
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

    fn processBytesSimd(self: *Self, data: []const u8) void {
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
            const record_boundaries: Mask = if (self.options.mode == .jsonl)
                simd.matchByte(VLEN, chunk, '\n')
            else
                0;
            const structural_indexes =
                ((structural | atom_starts | record_boundaries) &
                    outside_string) |
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
            self.carry.quote_delimiter =
                if (self.carry.in_string) '"' else 0;
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

    fn processBytes(self: *Self, data: []const u8) void {
        if (self.options.dialect == .json) {
            self.processBytesSimd(data);
        } else {
            self.processBytesScalar(data);
        }
    }

    fn processBytesScalar(self: *Self, data: []const u8) void {
        assert(data.len <= self.slot_len);
        assert(self.index != null);
        assert(self.processed_len + data.len <= self.input_len);

        for (data, 0..) |byte, local_offset| {
            self.processByte(
                self.processed_len + local_offset,
                byte,
            );
        }
        self.processed_len += data.len;
    }

    fn processByte(self: *Self, offset: usize, byte: u8) void {
        defer self.updateBackslashParity(byte);

        if (self.carry.pending_slash) {
            self.carry.pending_slash = false;
            if (self.commentsEnabled() and byte == '/') {
                self.carry.comment = .line;
                self.carry.in_atom = false;
                return;
            }
            if (self.commentsEnabled() and byte == '*') {
                self.carry.comment = .block;
                self.carry.in_atom = false;
                return;
            }

            // A slash that is not followed by a comment opener is ordinary
            // input. JSON-family scanners do not index it, but JSON and JSONC
            // retain it as atom context while JSON5 treats it as a separator.
            self.carry.in_atom = self.options.dialect != .json5;
        }

        if (self.carry.pending_escape) {
            self.carry.pending_escape = false;
            if (byte == 'u') {
                self.recordAtom(self.carry.pending_escape_offset);
                self.carry.in_atom = true;
                return;
            }
            self.carry.in_atom = false;
        }

        if (self.carry.pending_unicode_len != 0) {
            if (self.appendPendingUnicode(byte)) return;
            self.processByteNow(offset, byte);
            return;
        }

        self.processByteNow(offset, byte);
    }

    fn processByteNow(self: *Self, offset: usize, byte: u8) void {
        switch (self.carry.comment) {
            .line => {
                if (byte == '\n' or byte == '\r') {
                    self.carry.comment = .none;
                    self.carry.in_atom = false;
                    if (self.options.mode == .jsonl and byte == '\n') {
                        self.record(offset);
                    }
                }
                return;
            },
            .block => {
                if (self.carry.block_comment_ends_in_star) {
                    self.carry.block_comment_ends_in_star = false;
                    if (byte == '/') {
                        self.carry.comment = .none;
                        self.carry.in_atom = false;
                        return;
                    }
                }
                if (byte == '*') {
                    self.carry.block_comment_ends_in_star = true;
                }
                return;
            },
            .none => {},
        }

        if (self.carry.quote_delimiter != 0) {
            if (byte == self.carry.quote_delimiter and
                !self.carry.backslash_run_odd)
            {
                self.carry.in_string = false;
                self.carry.quote_delimiter = 0;
                self.carry.in_atom = false;
            }
            return;
        }
        if (self.commentsEnabled() and byte == '/') {
            self.carry.pending_slash = true;
            return;
        }

        if (self.options.dialect == .json5 and byte == '\\') {
            self.carry.pending_escape = true;
            self.carry.pending_escape_offset = @intCast(offset);
            return;
        }

        if (self.isQuote(byte)) {
            if (!self.carry.backslash_run_odd) {
                self.record(offset);
                self.carry.in_string = true;
                self.carry.quote_delimiter = byte;
                self.carry.in_atom = false;
            } else {
                self.carry.in_atom = self.options.dialect == .jsonc;
            }
            return;
        }

        if (self.options.mode == .jsonl and byte == '\n') {
            self.record(offset);
            self.carry.in_atom = false;
            return;
        }

        if (isStructuralByte(byte)) {
            self.record(offset);
            self.carry.in_atom = false;
            return;
        }

        if (self.options.dialect == .json5 and startsUnicodeWhitespace(byte)) {
            self.carry.pending_unicode[0] = byte;
            self.carry.pending_unicode_len = 1;
            self.carry.pending_unicode_offset = @intCast(offset);
            return;
        }

        if (self.isAtomCandidate(byte)) {
            self.recordAtom(offset);
            self.carry.in_atom = true;
            return;
        }

        self.carry.in_atom = switch (self.options.dialect) {
            .json, .jsonc => !isWhitespaceByte(byte),
            .json5 => false,
        };
    }
    fn appendPendingUnicode(self: *Self, byte: u8) bool {
        const len: usize = self.carry.pending_unicode_len;
        const first = self.carry.pending_unicode[0];

        if (len == 1) {
            const expected = switch (first) {
                0xc2 => byte == 0xa0,
                0xe1 => byte == 0x9a,
                0xe2 => byte == 0x80 or byte == 0x81,
                0xe3 => byte == 0x80,
                0xef => byte == 0xbb,
                else => false,
            };
            const continuation = byte >= 0x80 and byte <= 0xbf;
            if (!expected and !continuation) {
                self.recordAtom(self.carry.pending_unicode_offset);
                self.carry.in_atom = true;
                self.carry.pending_unicode_len = 0;
                return false;
            }
        } else if (len == 2 and (byte < 0x80 or byte > 0xbf)) {
            self.recordAtom(self.carry.pending_unicode_offset);
            self.carry.in_atom = true;
            self.carry.pending_unicode_len = 0;
            return false;
        }

        self.carry.pending_unicode[len] = byte;
        self.carry.pending_unicode_len += 1;

        const count: usize = self.carry.pending_unicode_len;
        const complete = switch (first) {
            0xc2 => count >= 2,
            0xe1, 0xe2, 0xe3, 0xef => count >= 3,
            else => true,
        };
        if (!complete) return true;

        const bytes = self.carry.pending_unicode;
        const whitespace = switch (first) {
            0xc2 => bytes[1] == 0xa0,
            0xe1 => bytes[1] == 0x9a and bytes[2] == 0x80,
            0xe2 => (bytes[1] == 0x80 and
                (bytes[2] >= 0x80 and bytes[2] <= 0x8a or
                    bytes[2] == 0xa8 or bytes[2] == 0xa9 or
                    bytes[2] == 0xaf)) or
                (bytes[1] == 0x81 and bytes[2] == 0x9f),
            0xe3 => bytes[1] == 0x80 and bytes[2] == 0x80,
            0xef => bytes[1] == 0xbb and bytes[2] == 0xbf,
            else => false,
        };
        if (whitespace) {
            self.carry.in_atom = false;
        } else {
            self.recordAtom(self.carry.pending_unicode_offset);
            self.carry.in_atom = true;
        }
        self.carry.pending_unicode_len = 0;
        return true;
    }

    fn flushDeferred(self: *Self) void {
        if (self.carry.pending_slash) {
            self.carry.pending_slash = false;
            self.carry.in_atom = self.options.dialect != .json5;
        }
        if (self.carry.pending_escape) {
            self.carry.pending_escape = false;
            self.carry.in_atom = false;
        }
        if (self.carry.pending_unicode_len != 0) {
            self.recordAtom(self.carry.pending_unicode_offset);
            self.carry.in_atom = true;
            self.carry.pending_unicode_len = 0;
        }
    }

    fn record(self: *Self, offset: usize) void {
        const index = self.indexPtr();
        assert(index.count + sentinel_count <= index.indexes.len);
        index.indexes[index.count] = @intCast(offset);
        index.count += 1;
    }

    fn recordAtom(self: *Self, offset: usize) void {
        if (!self.carry.in_atom) self.record(offset);
    }

    fn commentsEnabled(self: *const Self) bool {
        return self.options.dialect != .json;
    }

    fn isQuote(self: *const Self, byte: u8) bool {
        return byte == '"' or
            (self.options.dialect == .json5 and byte == '\'');
    }
    fn updateBackslashParity(self: *Self, byte: u8) void {
        self.carry.ends_in_backslash = byte == '\\';
        self.carry.backslash_run_odd =
            if (byte == '\\') !self.carry.backslash_run_odd else false;
    }

    fn isAtomCandidate(self: *const Self, byte: u8) bool {
        return switch (self.options.dialect) {
            .json, .jsonc => isAtomByte(byte),
            .json5 => switch (byte) {
                '-', '+', '.', '0'...'9', 'a'...'z', 'A'...'Z', '_', '$', 0xc0...0xff => true,
                0x80...0xbf => self.carry.in_atom,
                else => false,
            },
        };
    }
};

fn startsUnicodeWhitespace(byte: u8) bool {
    return switch (byte) {
        0xc2, 0xe1, 0xe2, 0xe3, 0xef => true,
        else => false,
    };
}

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

test "JSON stream matches one-shot indexes for split atoms and sentinels" {
    const input = "[true,false,null,-1234567890,0,{\"tail\":42}]";
    try expectEveryFeedPartition(input, .{ .dialect = .json });
}

test "JSON stream carries state across SIMD slots" {
    const input =
        "{\"alpha\":\"abcdefghijklmnopqrstuvwxyz0123456789" ++
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ\\\\\\\"tail\"," ++
        "\"values\":[true,false,null,-12345678901234567890]," ++
        "\"nested\":{\"punctuation\":\"{}[],:\"}}";
    try expectEveryFeedPartition(input, .{ .dialect = .json });
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

test "JSONC stream carries comments across feeds" {
    const input = "{/*a*/\"x\":true,//tail\n\"y\":2}";
    const expected = [_]u32{ 0, 6, 9, 10, 14, 22, 25, 26, 27 };
    try expectEveryFeedPartitionAgainst(
        input,
        .{ .dialect = .jsonc },
        &expected,
    );
}

test "JSON5 stream carries quote delimiters and atom boundaries" {
    const input = "{'x':+1,foo:0x2A}";
    const expected = [_]u32{ 0, 1, 4, 5, 7, 8, 11, 12, 16 };
    try expectEveryFeedPartitionAgainst(
        input,
        .{ .dialect = .json5 },
        &expected,
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
