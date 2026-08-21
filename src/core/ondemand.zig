const std = @import("std");
const simd = @import("simd.zig");
const stage1 = @import("stage1.zig");

const testing = std.testing;

pub const max_depth: usize = 1024;
const sentinel_count: usize = 3;

pub const Error = std.mem.Allocator.Error || error{
    CapacityOverflow,
    CapacityExceeded,
    DocumentActive,
    DocumentReleased,
    EmptyDocument,
    FocusAlreadyClaimed,
    FocusLost,
    IncorrectType,
    InputTooLarge,
    InvalidEscape,
    InvalidNumber,
    InvalidStructuralIndex,
    InvalidUtf8,
    NoSuchField,
    NumberError,
    OutOfOrderIteration,
    RootNotSingular,
    StringError,
    TapeTooLarge,
    TrailingComma,
    UnexpectedEnd,
    UnexpectedToken,
    UnclosedArray,
    UnclosedObject,
    UnterminatedString,
    DepthExceeded,
};

pub const InitError = std.mem.Allocator.Error || error{
    CapacityOverflow,
    InputTooLarge,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    indexes: []u32,
    capacity: usize,
    grow_on_demand: bool,
    generation: u64 = 0,
    document_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) InitError!Parser {
        if (max_capacity > std.math.maxInt(u32)) return error.InputTooLarge;
        const index_capacity = std.math.add(
            usize,
            max_capacity,
            sentinel_count,
        ) catch return error.CapacityOverflow;

        const indexes = try allocator.alloc(u32, index_capacity);
        return .{
            .allocator = allocator,
            .indexes = indexes,
            .capacity = max_capacity,
            .grow_on_demand = max_capacity == 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        std.debug.assert(!self.document_active);
        self.allocator.free(self.indexes);
        self.* = undefined;
    }

    fn ensureCapacity(self: *Parser, input_length: usize, index_count: usize) Error!void {
        var required_capacity = input_length;
        if (index_count > required_capacity) required_capacity = index_count;
        if (required_capacity <= self.capacity) return;
        if (!self.grow_on_demand) return error.CapacityExceeded;

        const index_capacity = std.math.add(
            usize,
            required_capacity,
            sentinel_count,
        ) catch return error.CapacityOverflow;
        const indexes = try self.allocator.alloc(u32, index_capacity);

        self.allocator.free(self.indexes);
        self.indexes = indexes;
        self.capacity = required_capacity;
    }

    /// Reserves parser-owned structural storage for one document.
    ///
    /// The returned slice excludes the three sentinel slots. Call
    /// `completeDocument` after filling the slice.
    pub fn prepareDocument(self: *Parser, input: []const u8) Error![]u32 {
        if (self.document_active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        try self.ensureCapacity(input.len, input.len);
        return self.indexes[0 .. self.indexes.len - sentinel_count];
    }

    /// Completes a document whose structural indexes were filled in-place.
    pub fn completeDocument(
        self: *Parser,
        input: []const u8,
        token_count: usize,
    ) Error!Document {
        if (self.document_active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        try self.ensureCapacity(input.len, token_count);
        return self.finishOwnedDocument(input, token_count);
    }

    pub fn initDocument(
        self: *Parser,
        input: []const u8,
        structural_index: *const stage1.StructuralIndex,
    ) Error!Document {
        if (self.document_active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        if (structural_index.count > input.len) return error.InvalidStructuralIndex;
        try self.ensureCapacity(input.len, structural_index.count);

        try validateStructuralIndex(input, structural_index);
        const source_count = std.math.add(
            usize,
            structural_index.count,
            sentinel_count,
        ) catch return error.InvalidStructuralIndex;
        if (source_count > self.indexes.len) {
            return error.InvalidStructuralIndex;
        }

        @memcpy(
            self.indexes[0..source_count],
            structural_index.indexes[0..source_count],
        );
        return self.finishOwnedDocument(input, structural_index.count);
    }

    pub fn iterate(
        self: *Parser,
        input: []const u8,
        structural_index: *const stage1.StructuralIndex,
    ) Error!Document {
        return self.initDocument(input, structural_index);
    }

    fn finishOwnedDocument(
        self: *Parser,
        input: []const u8,
        token_count: usize,
    ) Error!Document {
        if (token_count > input.len) return error.InvalidStructuralIndex;
        const source_count = std.math.add(
            usize,
            token_count,
            sentinel_count,
        ) catch return error.InvalidStructuralIndex;
        if (source_count > self.indexes.len) {
            return error.InvalidStructuralIndex;
        }

        const sentinel: u32 = @intCast(input.len);
        self.indexes[token_count..][0..sentinel_count].* = .{
            sentinel,
            sentinel,
            0,
        };
        try validateIndexes(input, self.indexes, token_count);

        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.document_active = true;

        return .{
            .parser = self,
            .input = input,
            .indexes = self.indexes[0..source_count],
            .token_count = token_count,
            .generation = self.generation,
        };
    }
};

const Focus = enum {
    none,
    cursor,
    event_reader,
};

pub fn initDocument(
    parser: *Parser,
    input: []const u8,
    structural_index: *const stage1.StructuralIndex,
) Error!Document {
    return parser.initDocument(input, structural_index);
}

pub const Document = struct {
    parser: *Parser,
    input: []const u8,
    indexes: []const u32,
    token_count: usize,
    generation: u64,
    position_index: usize = 0,
    depth: usize = 0,
    focus: Focus = .none,

    pub fn deinit(self: *Document) void {
        if (self.parser.document_active and self.parser.generation == self.generation) {
            self.parser.document_active = false;
        }
        self.* = undefined;
    }

    pub fn tokenCursor(self: *Document) Error!TokenCursor {
        try self.claimFocus(.cursor);
        return .{
            .document = self,
            .generation = self.generation,
            .expected_position = self.position_index,
            .owner = .cursor,
        };
    }

    pub fn eventReader(self: *Document) Error!EventReader {
        return EventReader.init(self);
    }

    fn ensureAlive(self: *const Document) Error!void {
        if (!self.parser.document_active) return error.DocumentReleased;
        if (self.parser.generation != self.generation) return error.DocumentReleased;
    }

    fn claimFocus(self: *Document, focus: Focus) Error!void {
        try self.ensureAlive();
        if (self.focus != .none) return error.FocusAlreadyClaimed;
        self.focus = focus;
    }
};

pub const Token = struct {
    offset: u32,
    byte: u8,
};

pub const TokenCursor = struct {
    document: *Document,
    generation: u64,
    expected_position: usize,
    owner: Focus,

    pub fn peek(self: *const TokenCursor) Error!?Token {
        try self.ensureFocused();
        if (self.expected_position > self.document.token_count) {
            return error.OutOfOrderIteration;
        }
        if (self.expected_position == self.document.token_count) return null;

        const offset = self.document.indexes[self.expected_position];
        return .{
            .offset = offset,
            .byte = self.document.input[@intCast(offset)],
        };
    }

    pub fn advance(self: *TokenCursor) Error!?Token {
        const token = try self.peek() orelse return null;
        try self.applyDepth(token.byte);
        self.expected_position += 1;
        self.document.position_index = self.expected_position;
        return token;
    }

    pub inline fn position(self: *const TokenCursor) u32 {
        return @intCast(self.expected_position);
    }

    pub fn peekIndex(self: *const TokenCursor, delta: i32) Error!u32 {
        const position_index = try self.positionAt(delta);
        return self.document.indexes[position_index];
    }

    pub fn peekLength(self: *const TokenCursor, delta: i32) Error!u32 {
        const position_index = try self.positionAt(delta);
        if (position_index + 1 >= self.document.indexes.len) {
            return error.UnexpectedEnd;
        }
        const start = self.document.indexes[position_index];
        const end = self.document.indexes[position_index + 1];
        if (end < start) return error.InvalidStructuralIndex;
        return end - start;
    }

    pub fn skipChild(self: *TokenCursor, parent_depth: i32) Error!void {
        try self.ensureFocused();
        if (parent_depth < 0) return error.UnexpectedToken;
        const parent_depth_usize: usize = @intCast(parent_depth);
        if (self.document.depth <= parent_depth_usize) return;

        var steps: usize = 0;
        while (self.document.depth > parent_depth_usize) {
            if (steps >= self.document.token_count) return error.UnexpectedEnd;
            _ = try self.advance() orelse return error.UnexpectedEnd;
            steps += 1;
        }
    }

    fn ensureFocused(self: *const TokenCursor) Error!void {
        try self.document.ensureAlive();
        if (self.document.generation != self.generation) return error.FocusLost;
        if (self.document.focus != self.owner) return error.FocusLost;
        if (self.document.position_index != self.expected_position) {
            return error.OutOfOrderIteration;
        }
    }

    fn positionAt(self: *const TokenCursor, delta: i32) Error!usize {
        try self.ensureFocused();
        const position_signed: i64 = @intCast(self.expected_position);
        const target = position_signed + @as(i64, @intCast(delta));
        if (target < 0) return error.UnexpectedEnd;
        const position_index: usize = @intCast(target);
        if (position_index >= self.document.indexes.len) return error.UnexpectedEnd;
        return position_index;
    }

    fn applyDepth(self: *TokenCursor, byte: u8) Error!void {
        switch (byte) {
            '{', '[' => {
                if (self.document.depth >= max_depth) return error.DepthExceeded;
                self.document.depth += 1;
            },
            '}', ']' => {
                if (self.document.depth == 0) return error.UnexpectedToken;
                self.document.depth -= 1;
            },
            else => {},
        }
    }
};

pub const Event = union(enum) {
    object_start,
    object_end,
    array_start,
    array_end,
    key: []const u8,
    string: []const u8,
    number: []const u8,
    bool: bool,
    null,
};

const Expect = enum {
    value_after_open,
    value_after_comma,
    key_after_open,
    key_after_comma,
    colon,
    value_after_colon,
    after_value,
};

const DepthEntry = struct {
    is_array: bool,
    count: usize,
    open_offset: u32,
};

pub const EventReader = struct {
    cursor: TokenCursor,
    stack: [max_depth]DepthEntry = @splat(.{
        .is_array = false,
        .count = 0,
        .open_offset = 0,
    }),
    top: usize = 0,
    byte_position: usize = 0,
    expect: Expect = .value_after_open,
    root_started: bool = false,
    root_done: bool = false,

    pub fn init(document: *Document) Error!EventReader {
        try document.claimFocus(.event_reader);
        return .{
            .cursor = .{
                .document = document,
                .generation = document.generation,
                .expected_position = document.position_index,
                .owner = .event_reader,
            },
        };
    }

    pub fn next(self: *EventReader) Error!?Event {
        return self.readNext();
    }

    pub fn peek(self: *const EventReader) Error!?Event {
        var probe = self.*;
        const document = probe.cursor.document;
        const position_index = document.position_index;
        const depth = document.depth;
        const event = probe.readNext() catch |err| {
            document.position_index = position_index;
            document.depth = depth;
            return err;
        };
        document.position_index = position_index;
        document.depth = depth;
        return event;
    }

    pub fn skip(self: *EventReader) Error!void {
        const first = try self.next() orelse return;
        var open_count: usize = switch (first) {
            .object_start, .array_start => 1,
            else => return,
        };

        var steps: usize = 0;
        while (open_count > 0) {
            if (steps >= self.cursor.document.token_count) return error.UnexpectedEnd;
            const event = try self.next() orelse return error.UnexpectedEnd;
            switch (event) {
                .object_start, .array_start => open_count += 1,
                .object_end, .array_end => open_count -= 1,
                else => {},
            }
            steps += 1;
        }
    }

    fn readNext(self: *EventReader) Error!?Event {
        if (self.root_done) {
            try self.cursor.ensureFocused();
            return self.finishRoot();
        }

        var separator_steps: usize = 0;
        while (separator_steps <= self.cursor.document.token_count) : (separator_steps += 1) {
            const token = try self.cursor.peek() orelse return self.finishDocument();
            try self.consumeWhitespaceBefore(token.offset);
            try self.advanceLoaded(token);
            self.byte_position = @intCast(token.offset);
            self.byte_position += 1;
            switch (token.byte) {
                '{' => return try self.openContainer(false, token.offset),
                '[' => return try self.openContainer(true, token.offset),
                '}' => return try self.closeContainer(false, token.offset),
                ']' => return try self.closeContainer(true, token.offset),
                ':' => try self.consumeColon(),
                ',' => try self.consumeComma(),
                '"' => return try self.consumeString(token.offset),
                '-', '0'...'9' => return try self.consumeNumber(token.offset),
                't' => return try self.consumeLiteral(token.offset, "true", true),
                'f' => return try self.consumeLiteral(token.offset, "false", false),
                'n' => return try self.consumeNull(token.offset),
                '+', '.' => return error.InvalidNumber,
                else => return error.UnexpectedToken,
            }
        }
        return error.UnexpectedToken;
    }

    fn advanceLoaded(self: *EventReader, token: Token) Error!void {
        try self.cursor.applyDepth(token.byte);
        self.cursor.expected_position += 1;
        self.cursor.document.position_index = self.cursor.expected_position;
    }

    fn openContainer(
        self: *EventReader,
        is_array: bool,
        offset: u32,
    ) Error!Event {
        if (self.top >= max_depth) return error.DepthExceeded;
        try self.beginValue();
        self.stack[self.top] = .{
            .is_array = is_array,
            .count = 0,
            .open_offset = offset,
        };
        self.top += 1;
        self.expect = if (is_array) .value_after_open else .key_after_open;
        return if (is_array) .array_start else .object_start;
    }

    fn closeContainer(
        self: *EventReader,
        is_array: bool,
        offset: u32,
    ) Error!Event {
        _ = offset;
        if (self.top == 0) return error.UnexpectedToken;
        const entry = self.stack[self.top - 1];
        if (entry.is_array != is_array) return error.UnexpectedToken;

        if (is_array) {
            switch (self.expect) {
                .value_after_open => {
                    if (entry.count != 0) return error.UnexpectedToken;
                },
                .value_after_comma => return error.TrailingComma,
                .after_value => {},
                else => return error.UnexpectedToken,
            }
        } else {
            switch (self.expect) {
                .key_after_open => {
                    if (entry.count != 0) return error.UnexpectedToken;
                },
                .key_after_comma => return error.TrailingComma,
                .after_value => {},
                else => return error.UnexpectedToken,
            }
        }

        self.top -= 1;
        if (self.top == 0) {
            self.root_done = true;
        } else {
            self.expect = .after_value;
        }
        return if (is_array) .array_end else .object_end;
    }

    fn consumeColon(self: *EventReader) Error!void {
        if (self.top == 0) return error.UnexpectedToken;
        if (self.stack[self.top - 1].is_array) return error.UnexpectedToken;
        if (self.expect != .colon) return error.UnexpectedToken;
        self.expect = .value_after_colon;
    }

    fn consumeComma(self: *EventReader) Error!void {
        if (self.top == 0) return error.UnexpectedToken;
        if (self.expect != .after_value) return error.UnexpectedToken;
        self.expect = if (self.stack[self.top - 1].is_array)
            .value_after_comma
        else
            .key_after_comma;
    }

    fn consumeString(self: *EventReader, quote_offset: u32) Error!Event {
        const is_key = self.isKeyExpected();
        if (!is_key) try self.beginValue();

        const token = try validateString(self.cursor.document.input, quote_offset);
        self.byte_position = token.end_offset;
        const raw = self.cursor.document.input[token.content_start..token.content_end];
        if (is_key) {
            self.expect = .colon;
            return .{ .key = raw };
        }
        self.completeScalarValue();
        return .{ .string = raw };
    }

    fn consumeNumber(self: *EventReader, start_offset: u32) Error!Event {
        try self.beginValue();
        const end_offset = try validateNumber(
            self.cursor.document.input,
            @intCast(start_offset),
        );
        self.byte_position = end_offset;
        self.completeScalarValue();
        return .{
            .number = self.cursor.document.input[@intCast(start_offset)..end_offset],
        };
    }

    fn consumeLiteral(
        self: *EventReader,
        start_offset: u32,
        literal: []const u8,
        value: bool,
    ) Error!Event {
        try self.beginValue();
        const end_offset = try validateLiteral(
            self.cursor.document.input,
            @intCast(start_offset),
            literal,
        );
        self.byte_position = end_offset;
        self.completeScalarValue();
        return .{ .bool = value };
    }

    fn consumeNull(self: *EventReader, start_offset: u32) Error!Event {
        try self.beginValue();
        self.byte_position = try validateLiteral(
            self.cursor.document.input,
            @intCast(start_offset),
            "null",
        );
        self.completeScalarValue();
        return .null;
    }

    fn beginValue(self: *EventReader) Error!void {
        if (self.top == 0) {
            if (self.root_started) return error.RootNotSingular;
            self.root_started = true;
            return;
        }

        const entry = &self.stack[self.top - 1];
        if (entry.is_array) {
            switch (self.expect) {
                .value_after_open, .value_after_comma => {},
                else => return error.UnexpectedToken,
            }
        } else if (self.expect != .value_after_colon) {
            return error.UnexpectedToken;
        }

        entry.count = std.math.add(usize, entry.count, 1) catch {
            return error.UnexpectedToken;
        };
        self.expect = .after_value;
    }

    fn completeScalarValue(self: *EventReader) void {
        if (self.top == 0) self.root_done = true;
    }

    fn isKeyExpected(self: *const EventReader) bool {
        if (self.top == 0) return false;
        if (self.stack[self.top - 1].is_array) return false;
        return switch (self.expect) {
            .key_after_open, .key_after_comma => true,
            else => false,
        };
    }

    fn consumeWhitespaceBefore(self: *EventReader, offset: u32) Error!void {
        const target: usize = @intCast(offset);
        if (target < self.byte_position) return error.InvalidStructuralIndex;

        const input = self.cursor.document.input;
        if (target > input.len) return error.InvalidStructuralIndex;
        const VLEN = simd.default_vector_len;
        const Mask = simd.Mask(VLEN);

        while (target - self.byte_position >= VLEN) {
            const block: simd.Vec(VLEN, u8) =
                input[self.byte_position..target][0..VLEN].*;
            const whitespace_mask: Mask =
                simd.matchAny4(VLEN, block, ' ', '\t', '\n', '\r');
            const candidate_mask: Mask = ~whitespace_mask;
            if (candidate_mask == 0) {
                self.byte_position += VLEN;
                continue;
            }

            const candidate_offset: usize = @intCast(@ctz(candidate_mask));
            self.byte_position += candidate_offset;
            break;
        }

        while (self.byte_position < target) : (self.byte_position += 1) {
            if (!isWhitespace(input[self.byte_position])) {
                return classifyUnindexed(input[self.byte_position]);
            }
        }
    }

    fn finishRoot(self: *EventReader) Error!?Event {
        while (self.byte_position < self.cursor.document.input.len) {
            if (!isWhitespace(self.cursor.document.input[self.byte_position])) {
                return error.RootNotSingular;
            }
            self.byte_position += 1;
        }
        if (self.cursor.expected_position != self.cursor.document.token_count) {
            return error.RootNotSingular;
        }
        return null;
    }

    fn finishDocument(self: *EventReader) Error!?Event {
        while (self.byte_position < self.cursor.document.input.len) {
            if (!isWhitespace(self.cursor.document.input[self.byte_position])) {
                return classifyUnindexed(self.cursor.document.input[self.byte_position]);
            }
            self.byte_position += 1;
        }
        if (self.top > 0) {
            if (self.stack[self.top - 1].is_array) return error.UnclosedArray;
            return error.UnclosedObject;
        }
        if (!self.root_started) return error.EmptyDocument;
        if (!self.root_done) return error.UnexpectedEnd;
        return null;
    }
};

const StringToken = struct {
    content_start: usize,
    content_end: usize,
    end_offset: usize,
};

const NumberState = enum {
    start,
    minus,
    zero,
    integer,
    fraction_dot,
    fraction,
    exponent_mark,
    exponent_sign,
    exponent,
};

fn validateStructuralIndex(
    input: []const u8,
    structural_index: *const stage1.StructuralIndex,
) Error!void {
    return validateIndexes(input, structural_index.indexes, structural_index.count);
}

fn validateIndexes(
    input: []const u8,
    indexes: []const u32,
    count: usize,
) Error!void {
    const source_count = std.math.add(usize, count, sentinel_count) catch {
        return error.InvalidStructuralIndex;
    };
    if (source_count > indexes.len) return error.InvalidStructuralIndex;

    var previous: ?u32 = null;
    for (indexes[0..count]) |offset| {
        if (offset >= input.len) return error.InvalidStructuralIndex;
        if (previous) |previous_offset| {
            if (offset <= previous_offset) return error.InvalidStructuralIndex;
        }
        previous = offset;
    }

    const sentinel: u32 = @intCast(input.len);
    if (indexes[count] != sentinel) return error.InvalidStructuralIndex;
    if (indexes[count + 1] != sentinel) return error.InvalidStructuralIndex;
    if (indexes[count + 2] != 0) return error.InvalidStructuralIndex;
}

fn validateString(input: []const u8, quote_offset: u32) Error!StringToken {
    const quote: usize = @intCast(quote_offset);
    if (quote >= input.len) return error.InvalidStructuralIndex;
    if (input[quote] != '"') return error.InvalidStructuralIndex;

    const content_start = quote + 1;
    var index = content_start;
    const VLEN = simd.default_vector_len;
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);
    const full_block_limit: usize = if (input.len >= VLEN)
        input.len - VLEN + 1
    else
        0;
    var has_high_bit = false;
    while (index < input.len) {
        while (index < full_block_limit) {
            const block: simd.Vec(VLEN, u8) = input[index..][0..VLEN].*;
            const candidate_mask: Mask =
                simd.matchAny2(VLEN, block, '"', '\\') |
                simd.matchRange(VLEN, block, 0, 0x1f);
            if (candidate_mask == 0) {
                has_high_bit = has_high_bit or simd.matchRange(VLEN, block, 0x80, 0xff) != 0;
                index += VLEN;
                continue;
            }

            const candidate_offset: usize = @intCast(@ctz(candidate_mask));
            const candidate_index = index + candidate_offset;
            const prefix_mask: Mask =
                (@as(Mask, 1) << @as(Shift, @intCast(candidate_offset))) - 1;
            const high_bit_mask: Mask = simd.matchRange(VLEN, block, 0x80, 0xff);
            has_high_bit = has_high_bit or (high_bit_mask & prefix_mask) != 0;
            if (input[candidate_index] == '"') {
                const content = input[content_start..candidate_index];
                if (has_high_bit and !std.unicode.utf8ValidateSlice(content)) {
                    return error.InvalidUtf8;
                }
                return .{
                    .content_start = content_start,
                    .content_end = candidate_index,
                    .end_offset = candidate_index + 1,
                };
            }
            index = candidate_index;
            break;
        }

        if (index >= input.len) break;
        const byte = input[index];
        if (byte == '"') {
            const content = input[content_start..index];
            if (has_high_bit and !std.unicode.utf8ValidateSlice(content)) {
                return error.InvalidUtf8;
            }
            return .{
                .content_start = content_start,
                .content_end = index,
                .end_offset = index + 1,
            };
        }
        if (byte < 0x20) return error.InvalidEscape;
        if (byte != '\\') {
            if (byte >= 0x80) has_high_bit = true;
            index += 1;
            continue;
        }

        if (index + 1 >= input.len) return error.InvalidEscape;
        switch (input[index + 1]) {
            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => index += 2,
            'u' => {
                try validateHexCodeUnit(input, index);
                index += 6;
            },
            else => return error.InvalidEscape,
        }
    }
    return error.UnterminatedString;
}

fn validateHexCodeUnit(input: []const u8, slash_offset: usize) Error!void {
    if (slash_offset + 5 >= input.len) return error.InvalidEscape;
    for (input[slash_offset + 2 .. slash_offset + 6]) |byte| {
        _ = std.fmt.charToDigit(byte, 16) catch return error.InvalidEscape;
    }
}

fn validateNumber(input: []const u8, start_offset: usize) Error!usize {
    var state: NumberState = .start;
    var index = start_offset;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (isAtomBoundary(byte)) break;
        state = switch (state) {
            .start => switch (byte) {
                '-' => .minus,
                '0' => .zero,
                '1'...'9' => .integer,
                else => return invalidNumberByte(byte),
            },
            .minus => switch (byte) {
                '0' => .zero,
                '1'...'9' => .integer,
                else => return invalidNumberByte(byte),
            },
            .zero => switch (byte) {
                '.' => .fraction_dot,
                'e', 'E' => .exponent_mark,
                else => return error.InvalidNumber,
            },
            .integer => switch (byte) {
                '0'...'9' => .integer,
                '.' => .fraction_dot,
                'e', 'E' => .exponent_mark,
                else => return invalidNumberByte(byte),
            },
            .fraction_dot => switch (byte) {
                '0'...'9' => .fraction,
                else => return invalidNumberByte(byte),
            },
            .fraction => switch (byte) {
                '0'...'9' => .fraction,
                'e', 'E' => .exponent_mark,
                else => return invalidNumberByte(byte),
            },
            .exponent_mark => switch (byte) {
                '+', '-' => .exponent_sign,
                '0'...'9' => .exponent,
                else => return invalidNumberByte(byte),
            },
            .exponent_sign => switch (byte) {
                '0'...'9' => .exponent,
                else => return invalidNumberByte(byte),
            },
            .exponent => switch (byte) {
                '0'...'9' => .exponent,
                else => return invalidNumberByte(byte),
            },
        };
    }

    return switch (state) {
        .zero, .integer, .fraction, .exponent => index,
        else => error.InvalidNumber,
    };
}

fn validateLiteral(
    input: []const u8,
    start_offset: usize,
    literal: []const u8,
) Error!usize {
    const end_offset = std.math.add(usize, start_offset, literal.len) catch {
        return error.UnexpectedEnd;
    };
    if (end_offset > input.len) return error.UnexpectedEnd;
    if (!std.mem.eql(u8, input[start_offset..end_offset], literal)) {
        return error.UnexpectedToken;
    }
    if (end_offset < input.len and !isAtomBoundary(input[end_offset])) {
        return error.UnexpectedToken;
    }
    return end_offset;
}

fn invalidNumberByte(byte: u8) Error {
    return switch (byte) {
        '+', '-', '.', 'e', 'E', '0'...'9' => error.InvalidNumber,
        else => error.UnexpectedToken,
    };
}

fn classifyUnindexed(byte: u8) Error {
    return switch (byte) {
        '+', '.' => error.InvalidNumber,
        else => error.UnexpectedToken,
    };
}

fn isWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

fn isAtomBoundary(byte: u8) bool {
    if (isWhitespace(byte)) return true;
    return switch (byte) {
        '}', ']', ':', ',' => true,
        else => false,
    };
}

fn isStructuralByte(byte: u8) bool {
    return switch (byte) {
        '{', '}', '[', ']', ':', ',' => true,
        else => false,
    };
}

fn isAtomStart(byte: u8) bool {
    return switch (byte) {
        '-', '0'...'9', 't', 'f', 'n' => true,
        else => false,
    };
}

fn indexForTest(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var backslash_count: usize = 0;
    var previous_in_atom = false;
    for (input, 0..) |byte, offset| {
        if (byte == '"' and backslash_count % 2 == 0) {
            if (!in_string) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            }
            in_string = !in_string;
        } else if (!in_string) {
            if (isStructuralByte(byte)) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            } else if (isAtomStart(byte) and !previous_in_atom) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            }
        }

        previous_in_atom = !in_string and byte != '"' and
            !isStructuralByte(byte) and !isWhitespace(byte);
        if (byte == '\\') {
            backslash_count += 1;
        } else {
            backslash_count = 0;
        }
    }

    try result.finish(input.len);
    return result;
}

fn expectEvent(expected: Event, actual: Event) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .key => |raw| switch (actual) {
            .key => |actual_raw| try testing.expectEqualStrings(raw, actual_raw),
            else => unreachable,
        },
        .string => |raw| switch (actual) {
            .string => |actual_raw| try testing.expectEqualStrings(raw, actual_raw),
            else => unreachable,
        },
        .number => |raw| switch (actual) {
            .number => |actual_raw| try testing.expectEqualStrings(raw, actual_raw),
            else => unreachable,
        },
        .bool => |value| switch (actual) {
            .bool => |actual_value| try testing.expectEqual(value, actual_value),
            else => unreachable,
        },
        else => {},
    }
}

test "Parser owns indexes and enforces one document and focus" {
    const input = "[0]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    defer document.deinit();

    try testing.expectError(error.DocumentActive, parser.initDocument(input, &structural_index));
    var cursor = try document.tokenCursor();
    try testing.expectError(error.FocusAlreadyClaimed, document.eventReader());

    var stale = cursor;
    _ = try cursor.advance();
    try testing.expectError(error.OutOfOrderIteration, stale.advance());
}

test "Parser preserves grow-on-demand policy across resizes" {
    const first_input = "[0,1,2]";
    const second_input = "[0,1,2,3,4,5,6,7,8,9]";

    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();
    try testing.expect(parser.grow_on_demand);

    var first_capacity: usize = 0;
    {
        const first_indexes = try parser.prepareDocument(first_input);
        for (first_input, 0..) |_, offset| {
            first_indexes[offset] = @intCast(offset);
        }
        var first_document = try parser.completeDocument(first_input, first_input.len);
        defer first_document.deinit();
        first_capacity = parser.capacity;
        try testing.expect(first_capacity >= first_input.len);
    }

    const second_indexes = try parser.prepareDocument(second_input);
    for (second_input, 0..) |_, offset| {
        second_indexes[offset] = @intCast(offset);
    }
    var second_document = try parser.completeDocument(second_input, second_input.len);
    defer second_document.deinit();

    try testing.expect(parser.grow_on_demand);
    try testing.expect(parser.capacity >= second_input.len);
    try testing.expect(parser.capacity > first_capacity);
}

test "TokenCursor exposes sentinels and skips one nested child" {
    const input = "[1,{\"a\":[true]},2]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    defer document.deinit();
    var cursor = try document.tokenCursor();

    try testing.expectEqual(@as(u8, '['), (try cursor.advance()).?.byte);
    try testing.expectEqual(@as(u8, '1'), (try cursor.advance()).?.byte);
    try testing.expectEqual(@as(u8, ','), (try cursor.advance()).?.byte);
    try testing.expectEqual(@as(u8, '{'), (try cursor.advance()).?.byte);
    try cursor.skipChild(1);
    try testing.expectEqual(@as(u8, ','), (try cursor.peek()).?.byte);

    while (try cursor.advance()) |_| {}
    try testing.expectEqual(@as(u32, @intCast(input.len)), try cursor.peekIndex(0));
    try testing.expectEqual(@as(u32, 0), try cursor.peekLength(0));
}

test "EventReader emits raw JSON events without allocation" {
    const input = "{\"text\":\"a\\\"b\",\"n\":-12.5,\"ok\":true,\"none\":null,\"a\":[false]}";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    defer document.deinit();
    var reader = try document.eventReader();

    try expectEvent(.object_start, (try reader.next()).?);
    try expectEvent(.{ .key = "text" }, (try reader.next()).?);
    try expectEvent(.{ .string = "a\\\"b" }, (try reader.peek()).?);
    try expectEvent(.{ .string = "a\\\"b" }, (try reader.next()).?);
    try expectEvent(.{ .key = "n" }, (try reader.next()).?);
    try expectEvent(.{ .number = "-12.5" }, (try reader.next()).?);
    try expectEvent(.{ .key = "ok" }, (try reader.next()).?);
    try expectEvent(.{ .bool = true }, (try reader.next()).?);
    try expectEvent(.{ .key = "none" }, (try reader.next()).?);
    try expectEvent(.null, (try reader.next()).?);
    try expectEvent(.{ .key = "a" }, (try reader.next()).?);
    try expectEvent(.array_start, (try reader.next()).?);
    try expectEvent(.{ .bool = false }, (try reader.next()).?);
    try expectEvent(.array_end, (try reader.next()).?);
    try expectEvent(.object_end, (try reader.next()).?);
    try testing.expect((try reader.next()) == null);
}

test "EventReader rejects trailing commas and malformed numbers" {
    const cases = [_]struct {
        input: []const u8,
        expected: Error,
    }{
        .{ .input = "[0,]", .expected = error.TrailingComma },
        .{ .input = "01", .expected = error.InvalidNumber },
    };

    for (cases) |case| {
        var structural_index = try indexForTest(testing.allocator, case.input);
        defer structural_index.deinit(testing.allocator);
        var parser = try Parser.init(testing.allocator, case.input.len);
        defer parser.deinit();
        var document = try parser.initDocument(case.input, &structural_index);
        defer document.deinit();
        var reader = try document.eventReader();

        var saw_error = false;
        while (!saw_error) {
            const event = reader.next() catch |err| {
                try testing.expectEqual(case.expected, err);
                saw_error = true;
                break;
            };
            if (event == null) return error.TestUnexpectedResult;
        }
    }
}

test "EventReader enforces the fixed depth bound" {
    var input: [2 * (max_depth + 1)]u8 = undefined;
    @memset(input[0 .. max_depth + 1], '[');
    @memset(input[max_depth + 1 ..], ']');

    var structural_index = try indexForTest(testing.allocator, &input);
    defer structural_index.deinit(testing.allocator);
    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(&input, &structural_index);
    defer document.deinit();
    var reader = try document.eventReader();

    for (0..max_depth) |_| {
        try expectEvent(.array_start, (try reader.next()).?);
    }
    try testing.expectError(error.DepthExceeded, reader.next());
}
