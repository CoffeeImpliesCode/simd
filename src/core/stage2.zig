const std = @import("std");
const stage1 = @import("stage1.zig");

const testing = std.testing;

pub const max_depth: usize = 1024;

pub const Error = error{
    UnexpectedToken,
    UnclosedObject,
    UnclosedArray,
    InvalidNumber,
    InvalidEscape,
    TrailingComma,
    DuplicateKey,
    EmptyDocument,
    RootNotSingular,
    DepthExceeded,
    UnterminatedString,
    InvalidUtf8,
};

pub const BuildError = std.mem.Allocator.Error || Error || error{TapeTooLarge};
const ParseError = Error || error{TapeTooLarge};
pub const ValidationError = std.mem.Allocator.Error || error{TapeTooLarge};

pub const TapeKind = enum(u8) {
    object_start,
    array_start,
    object_end,
    array_end,
    string,
    key,
    number,
    true_literal,
    false_literal,
    null_literal,
};

/// A validated JSON token. String offsets point at the opening quote.
pub const TapeWord = packed struct(u64) {
    kind: u8,
    payload: u24,
    offset: u32,

    pub fn tapeKind(self: TapeWord) TapeKind {
        return @enumFromInt(self.kind);
    }
};

comptime {
    std.debug.assert(@bitSizeOf(TapeWord) == 64);
    std.debug.assert(@sizeOf(TapeWord) == 8);
}

/// An owned tape. Source bytes are supplied separately to `root` and borrowed.
pub const Document = struct {
    tape: []TapeWord,

    /// Creates a cursor over the owned tape and borrowed source input.
    ///
    /// The document owns only its tape. The caller must keep `input` and this
    /// document alive for as long as the returned cursor is used.
    pub fn root(self: *const Document, input: []const u8) NavigationError!TapeCursor {
        if (self.tape.len == 0) return error.TapeOutOfBounds;
        const cursor = TapeCursor{
            .tape = self.tape,
            .input = input,
        };
        _ = try cursor.peek();
        return cursor;
    }

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.tape);
        self.* = undefined;
    }
};

pub const NavigationError = error{
    PositionOutOfBounds,
    InvalidTapeKind,
    InvalidTapeOrder,
    TapeOutOfBounds,
    SourceOutOfBounds,
    InvalidSource,
    TypeMismatch,
    DepthExceeded,
};

const ContainerFrame = struct {
    is_object: bool,
    start_index: usize,
    remaining: u32,
    expect_key: bool,
};

/// A zero-allocation cursor over an owned tape and borrowed source input.
///
/// The cursor does not own either slice. The document and input must outlive
/// the cursor.
pub const TapeCursor = struct {
    tape: []const TapeWord,
    input: []const u8,
    position_index: usize = 0,

    pub fn peek(self: *const TapeCursor) NavigationError!TapeWord {
        return self.currentWord();
    }

    pub fn advance(self: *TapeCursor) NavigationError!void {
        _ = try self.currentWord();
        self.position_index += 1;
    }

    pub fn position(self: *const TapeCursor) usize {
        return self.position_index;
    }

    pub fn containerCount(self: *const TapeCursor) NavigationError!u32 {
        const word = try self.currentWord();
        const kind = try checkedTapeKind(word);
        switch (kind) {
            .object_start, .array_start => {
                _ = try self.valueEnd(self.position_index);
                return word.payload;
            },
            else => return error.TypeMismatch,
        }
    }

    pub fn matchingStart(self: *const TapeCursor) NavigationError!TapeCursor {
        const word = try self.currentWord();
        const end_kind = try checkedTapeKind(word);
        const expected_start_kind = switch (end_kind) {
            .object_end => TapeKind.object_start,
            .array_end => TapeKind.array_start,
            else => return error.TypeMismatch,
        };

        const start_index: usize = @intCast(word.payload);
        if (start_index >= self.tape.len) return error.TapeOutOfBounds;
        if (start_index >= self.position_index) return error.InvalidTapeOrder;
        const start_word = self.tape[start_index];
        if (try checkedTapeKind(start_word) != expected_start_kind) {
            return error.InvalidTapeOrder;
        }

        return .{
            .tape = self.tape,
            .input = self.input,
            .position_index = start_index,
        };
    }

    /// Advances past the current scalar or complete container subtree.
    /// Container skips validate and scan each nested tape word.
    pub fn skipValue(self: *TapeCursor) NavigationError!void {
        self.position_index = try self.valueEnd(self.position_index);
    }

    /// Returns still-escaped string/key content, or the complete scalar source.
    pub fn rawValue(self: *const TapeCursor) NavigationError![]const u8 {
        const word = try self.currentWord();
        const kind = try checkedTapeKind(word);
        switch (kind) {
            .string, .key => return self.rawString(word),
            .number => {
                if (word.payload != 0) return error.InvalidTapeOrder;
                return self.rawNumber(word);
            },
            .true_literal => {
                if (word.payload != 0) return error.InvalidTapeOrder;
                return self.rawLiteral(word, "true");
            },
            .false_literal => {
                if (word.payload != 0) return error.InvalidTapeOrder;
                return self.rawLiteral(word, "false");
            },
            .null_literal => {
                if (word.payload != 0) return error.InvalidTapeOrder;
                return self.rawLiteral(word, "null");
            },
            else => return error.TypeMismatch,
        }
    }

    fn currentWord(self: *const TapeCursor) NavigationError!TapeWord {
        if (self.position_index >= self.tape.len) return error.PositionOutOfBounds;
        const word = self.tape[self.position_index];
        _ = try checkedTapeKind(word);
        return word;
    }

    fn valueEnd(self: *const TapeCursor, start_index: usize) NavigationError!usize {
        if (start_index >= self.tape.len) return error.TapeOutOfBounds;

        var frames: [max_depth]ContainerFrame = undefined;
        var frame_count: usize = 0;
        var index = start_index;
        var root_pending = true;

        while (index < self.tape.len) {
            if (frame_count > 0) {
                var frame = &frames[frame_count - 1];
                if (frame.remaining == 0) {
                    const end_word = self.tape[index];
                    const end_kind = try checkedTapeKind(end_word);
                    const expected_end = if (frame.is_object)
                        TapeKind.object_end
                    else
                        TapeKind.array_end;
                    if (end_kind != expected_end) return error.InvalidTapeOrder;
                    const end_start_index: usize = @intCast(end_word.payload);
                    if (end_start_index != frame.start_index) {
                        return error.InvalidTapeOrder;
                    }

                    index += 1;
                    frame_count -= 1;
                    if (frame_count == 0) return index;
                    try completeChild(&frames[frame_count - 1]);
                    continue;
                }

                if (frame.is_object and frame.expect_key) {
                    const key_word = self.tape[index];
                    if (try checkedTapeKind(key_word) != .key) {
                        return error.InvalidTapeOrder;
                    }
                    index += 1;
                    frame.expect_key = false;
                    continue;
                }
            } else if (!root_pending) {
                return index;
            }

            const word = self.tape[index];
            const kind = try checkedTapeKind(word);
            if (kind == .key) return error.InvalidTapeOrder;
            switch (kind) {
                .object_end, .array_end => return error.InvalidTapeOrder,
                .object_start, .array_start => {
                    if (frame_count >= max_depth) return error.DepthExceeded;
                    frames[frame_count] = .{
                        .is_object = kind == .object_start,
                        .start_index = index,
                        .remaining = @intCast(word.payload),
                        .expect_key = kind == .object_start,
                    };
                    frame_count += 1;
                    index += 1;
                },
                else => {
                    if (kind == .number or
                        kind == .true_literal or
                        kind == .false_literal or
                        kind == .null_literal)
                    {
                        if (word.payload != 0) return error.InvalidTapeOrder;
                    }
                    index += 1;
                    if (frame_count == 0) {
                        root_pending = false;
                        return index;
                    }
                    try completeChild(&frames[frame_count - 1]);
                },
            }
        }

        return error.TapeOutOfBounds;
    }

    fn completeChild(frame: *ContainerFrame) NavigationError!void {
        if (frame.remaining == 0) return error.InvalidTapeOrder;
        if (frame.is_object and frame.expect_key) return error.InvalidTapeOrder;
        frame.remaining -= 1;
        frame.expect_key = frame.is_object;
    }

    fn rawString(self: *const TapeCursor, word: TapeWord) NavigationError![]const u8 {
        const offset: usize = @intCast(word.offset);
        if (offset >= self.input.len) return error.SourceOutOfBounds;
        if (self.input[offset] != '"') return error.InvalidSource;

        const content_start = offset + 1;
        const content_length: usize = @intCast(word.payload);
        if (content_length > self.input.len - content_start) {
            return error.SourceOutOfBounds;
        }
        const content_end = content_start + content_length;
        if (content_end >= self.input.len) return error.SourceOutOfBounds;
        var failure_offset = offset;
        const token = validateString(self.input, offset, &failure_offset) catch {
            return error.InvalidSource;
        };
        if (token.content_length != content_length) return error.InvalidSource;
        if (token.end_offset != content_end + 1) return error.InvalidSource;
        return self.input[content_start..content_end];
    }

    fn rawNumber(self: *const TapeCursor, word: TapeWord) NavigationError![]const u8 {
        const offset: usize = @intCast(word.offset);
        if (offset >= self.input.len) return error.SourceOutOfBounds;
        var failure_offset = offset;
        const end = validateNumber(self.input, offset, &failure_offset) catch {
            return error.InvalidSource;
        };
        return self.input[offset..end];
    }

    fn rawLiteral(
        self: *const TapeCursor,
        word: TapeWord,
        literal: []const u8,
    ) NavigationError![]const u8 {
        const offset: usize = @intCast(word.offset);
        if (offset > self.input.len) return error.SourceOutOfBounds;
        if (literal.len > self.input.len - offset) return error.SourceOutOfBounds;
        const end = offset + literal.len;
        if (!std.mem.eql(u8, self.input[offset..end], literal)) return error.InvalidSource;
        if (end < self.input.len and !isAtomBoundary(self.input[end])) {
            return error.InvalidSource;
        }
        return self.input[offset..end];
    }
};

fn checkedTapeKind(word: TapeWord) NavigationError!TapeKind {
    return switch (word.kind) {
        @intFromEnum(TapeKind.object_start) => .object_start,
        @intFromEnum(TapeKind.array_start) => .array_start,
        @intFromEnum(TapeKind.object_end) => .object_end,
        @intFromEnum(TapeKind.array_end) => .array_end,
        @intFromEnum(TapeKind.string) => .string,
        @intFromEnum(TapeKind.key) => .key,
        @intFromEnum(TapeKind.number) => .number,
        @intFromEnum(TapeKind.true_literal) => .true_literal,
        @intFromEnum(TapeKind.false_literal) => .false_literal,
        @intFromEnum(TapeKind.null_literal) => .null_literal,
        else => error.InvalidTapeKind,
    };
}

pub const Diagnostic = struct {
    err: Error,
    byte_offset: usize,
    line: u32,
    column: u32,
    snippet: []const u8,
    snippet_start: usize,
};

pub const DepthEntry = struct {
    is_array: bool,
    tape_index: u32,
    open_offset: u32,
    count: u32,
};

pub const DepthStack = struct {
    entries: [max_depth]DepthEntry = undefined,
    top: usize = 0,

    pub fn push(self: *DepthStack, entry: DepthEntry) Error!void {
        if (self.top >= max_depth) return error.DepthExceeded;
        self.entries[self.top] = entry;
        self.top += 1;
    }

    pub fn pop(self: *DepthStack) DepthEntry {
        std.debug.assert(self.top > 0);
        self.top -= 1;
        return self.entries[self.top];
    }

    pub fn peek(self: *DepthStack) *DepthEntry {
        std.debug.assert(self.top > 0);
        return &self.entries[self.top - 1];
    }

    pub fn peekConst(self: *const DepthStack) *const DepthEntry {
        std.debug.assert(self.top > 0);
        return &self.entries[self.top - 1];
    }
};

/// Builds an owned tape after complete RFC 8259 syntax validation.
pub fn buildTape(
    allocator: std.mem.Allocator,
    input: []const u8,
    structural_index: *const stage1.StructuralIndex,
) BuildError!Document {
    if (input.len > std.math.maxInt(u32)) return error.TapeTooLarge;

    const indexes = structural_index.slice();
    var tape = try std.ArrayList(TapeWord).initCapacity(allocator, indexes.len);
    errdefer tape.deinit(allocator);

    var parser = Parser{
        .input = input,
        .indexes = indexes,
        .tape = &tape,
    };
    try parser.run();

    return .{ .tape = try tape.toOwnedSlice(allocator) };
}

/// Validates an indexed JSON document without allocating a tape.
pub fn validate(
    input: []const u8,
    structural_index: *const stage1.StructuralIndex,
) ValidationError!?Diagnostic {
    if (input.len > std.math.maxInt(u32)) return error.TapeTooLarge;

    var parser = Parser{
        .input = input,
        .indexes = structural_index.slice(),
    };
    parser.run() catch |err| {
        if (err == error.TapeTooLarge) return error.TapeTooLarge;
        return diagnosticAt(input, @errorCast(err), parser.failure_offset);
    };
    return null;
}

/// Creates a zero-copy diagnostic view into `input`.
pub fn diagnosticAt(
    input: []const u8,
    err: Error,
    byte_offset: usize,
) Diagnostic {
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

const Expect = enum(u3) {
    value_after_open,
    value_after_comma,
    key_after_open,
    key_after_comma,
    colon,
    value_after_colon,
    after_value,
};

const NumberState = enum(u4) {
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

const StringToken = struct {
    content_length: usize,
    end_offset: usize,
};

const Parser = struct {
    input: []const u8,
    indexes: []const u32,
    tape: ?*std.ArrayList(TapeWord) = null,
    structural_position: usize = 0,
    byte_position: usize = 0,
    failure_offset: usize = 0,
    tape_count: usize = 0,
    depth: DepthStack = .{},
    expect: Expect = .value_after_open,
    root_started: bool = false,
    root_done: bool = false,
    fn run(self: *Parser) ParseError!void {
        while (true) {
            self.skipWhitespace();
            if (self.byte_position == self.input.len) break;
            if (self.root_done) {
                return self.fail(error.RootNotSingular, self.byte_position);
            }

            self.failure_offset = self.byte_position;
            const byte = try self.takeIndexedByte();
            switch (byte) {
                '{' => try self.openContainer(false),
                '[' => try self.openContainer(true),
                '}' => try self.closeContainer(false),
                ']' => try self.closeContainer(true),
                ':' => try self.consumeColon(),
                ',' => try self.consumeComma(),
                '"' => try self.consumeString(),
                '-', '0'...'9' => try self.consumeNumber(),
                't' => try self.consumeLiteral("true", .true_literal),
                'f' => try self.consumeLiteral("false", .false_literal),
                'n' => try self.consumeLiteral("null", .null_literal),
                '+', '.' => return self.fail(error.InvalidNumber, self.byte_position - 1),
                else => return self.fail(error.UnexpectedToken, self.byte_position - 1),
            }
        }

        self.failure_offset = self.byte_position;
        if (self.structural_position != self.indexes.len) {
            return self.fail(error.UnexpectedToken, self.byte_position);
        }
        if (self.depth.top > 0) {
            const entry = self.depth.peekConst();
            self.failure_offset = @intCast(entry.open_offset);
            if (entry.is_array) return error.UnclosedArray;
            return error.UnclosedObject;
        }
        if (!self.root_started) return self.fail(error.EmptyDocument, 0);
        if (!self.root_done) return self.fail(error.UnexpectedToken, self.byte_position);
    }

    fn fail(self: *Parser, err: Error, offset: usize) Error {
        self.failure_offset = offset;
        return err;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.byte_position < self.input.len) {
            if (!isWhitespace(self.input[self.byte_position])) return;
            self.byte_position += 1;
        }
    }

    fn takeIndexedByte(self: *Parser) Error!u8 {
        if (self.structural_position == self.indexes.len) {
            return self.fail(
                classifyUnindexed(self.input[self.byte_position]),
                self.byte_position,
            );
        }

        const indexed_offset: usize = @intCast(self.indexes[self.structural_position]);
        if (indexed_offset != self.byte_position) {
            return self.fail(
                classifyUnindexed(self.input[self.byte_position]),
                self.byte_position,
            );
        }
        if (indexed_offset >= self.input.len) {
            return self.fail(error.UnexpectedToken, self.byte_position);
        }

        self.structural_position += 1;
        self.byte_position += 1;
        return self.input[indexed_offset];
    }
    fn openContainer(self: *Parser, is_array: bool) ParseError!void {
        const offset = self.byte_position - 1;
        if (self.depth.top >= max_depth) {
            return self.fail(error.DepthExceeded, offset);
        }
        try self.beginValue();

        const tape_index = try self.emit(
            if (is_array) .array_start else .object_start,
            0,
            offset,
        );
        try self.depth.push(.{
            .is_array = is_array,
            .tape_index = @intCast(tape_index),
            .open_offset = @intCast(offset),
            .count = 0,
        });
        self.expect = if (is_array) .value_after_open else .key_after_open;
    }
    fn closeContainer(self: *Parser, is_array: bool) ParseError!void {
        const close_offset = self.byte_position - 1;
        if (self.depth.top == 0) {
            if (self.root_done) {
                return self.fail(error.RootNotSingular, close_offset);
            }
            return self.fail(error.UnexpectedToken, close_offset);
        }

        const entry = self.depth.peekConst().*;
        if (entry.is_array != is_array) {
            return self.fail(error.UnexpectedToken, close_offset);
        }

        if (is_array) {
            switch (self.expect) {
                .value_after_open => {
                    if (entry.count != 0) {
                        return self.fail(error.UnexpectedToken, close_offset);
                    }
                },
                .value_after_comma => return self.fail(error.TrailingComma, close_offset),
                .after_value => {},
                else => return self.fail(error.UnexpectedToken, close_offset),
            }
        } else {
            switch (self.expect) {
                .key_after_open => {
                    if (entry.count != 0) {
                        return self.fail(error.UnexpectedToken, close_offset);
                    }
                },
                .key_after_comma => return self.fail(error.TrailingComma, close_offset),
                .after_value => {},
                else => return self.fail(error.UnexpectedToken, close_offset),
            }
        }

        const open_index: usize = @intCast(entry.tape_index);
        if (self.tape) |tape| {
            tape.items[open_index].payload = try self.encodeTapePayload(entry.count);
        }
        _ = try self.emit(
            if (is_array) .array_end else .object_end,
            try self.encodeTapePayload(open_index),
            close_offset,
        );
        _ = self.depth.pop();

        if (self.depth.top == 0) {
            self.root_done = true;
        } else {
            self.expect = .after_value;
        }
    }
    fn consumeColon(self: *Parser) Error!void {
        const offset = self.byte_position - 1;
        if (self.depth.top == 0) return self.fail(error.UnexpectedToken, offset);
        if (self.depth.peekConst().is_array) {
            return self.fail(error.UnexpectedToken, offset);
        }
        if (self.expect != .colon) {
            return self.fail(error.UnexpectedToken, offset);
        }
        self.expect = .value_after_colon;
    }

    fn consumeComma(self: *Parser) Error!void {
        const offset = self.byte_position - 1;
        if (self.depth.top == 0) return self.fail(error.UnexpectedToken, offset);
        if (self.expect != .after_value) {
            return self.fail(error.UnexpectedToken, offset);
        }
        self.expect = if (self.depth.peekConst().is_array)
            .value_after_comma
        else
            .key_after_comma;
    }

    fn consumeString(self: *Parser) ParseError!void {
        const quote_offset = self.byte_position - 1;
        const is_key = self.isKeyExpected();
        if (!is_key) try self.beginValue();

        const token = try validateString(
            self.input,
            quote_offset,
            &self.failure_offset,
        );
        self.byte_position = token.end_offset;
        const payload = try self.encodeTapePayload(token.content_length);

        if (is_key) {
            _ = try self.emit(.key, payload, quote_offset);
            self.expect = .colon;
            return;
        }

        _ = try self.emit(.string, payload, quote_offset);
        self.completeScalarValue();
    }

    fn consumeNumber(self: *Parser) ParseError!void {
        const start_offset = self.byte_position - 1;
        try self.beginValue();
        self.byte_position = try validateNumber(
            self.input,
            start_offset,
            &self.failure_offset,
        );
        _ = try self.emit(.number, 0, start_offset);
        self.completeScalarValue();
    }

    fn consumeLiteral(
        self: *Parser,
        literal: []const u8,
        kind: TapeKind,
    ) ParseError!void {
        const start_offset = self.byte_position - 1;
        try self.beginValue();
        const end_offset = std.math.add(usize, start_offset, literal.len) catch {
            return self.fail(error.UnexpectedToken, self.input.len);
        };
        if (end_offset > self.input.len) {
            return self.fail(error.UnexpectedToken, self.input.len);
        }
        for (literal, start_offset..) |expected, offset| {
            if (self.input[offset] != expected) {
                return self.fail(error.UnexpectedToken, offset);
            }
        }
        if (end_offset < self.input.len and !isAtomBoundary(self.input[end_offset])) {
            return self.fail(error.UnexpectedToken, end_offset);
        }

        self.byte_position = end_offset;
        _ = try self.emit(kind, 0, start_offset);
        self.completeScalarValue();
    }

    fn beginValue(self: *Parser) Error!void {
        const offset = self.byte_position - 1;
        if (self.depth.top == 0) {
            if (self.root_started) return self.fail(error.RootNotSingular, offset);
            self.root_started = true;
            return;
        }

        const entry = self.depth.peek();
        if (entry.is_array) {
            switch (self.expect) {
                .value_after_open, .value_after_comma => {},
                else => return self.fail(error.UnexpectedToken, offset),
            }
        } else if (self.expect != .value_after_colon) {
            return self.fail(error.UnexpectedToken, offset);
        }

        entry.count = std.math.add(u32, entry.count, 1) catch {
            return self.fail(error.UnexpectedToken, offset);
        };
        self.expect = .after_value;
    }

    fn completeScalarValue(self: *Parser) void {
        if (self.depth.top == 0) self.root_done = true;
    }

    fn isKeyExpected(self: *const Parser) bool {
        if (self.depth.top == 0) return false;
        if (self.depth.peekConst().is_array) return false;
        return switch (self.expect) {
            .key_after_open, .key_after_comma => true,
            else => false,
        };
    }

    fn encodeTapePayload(
        self: *const Parser,
        value: usize,
    ) error{TapeTooLarge}!u24 {
        if (self.tape == null) return 0;
        if (value > std.math.maxInt(u24)) return error.TapeTooLarge;
        return @intCast(value);
    }

    fn emit(
        self: *Parser,
        kind: TapeKind,
        payload: u24,
        offset: usize,
    ) error{TapeTooLarge}!usize {
        if (offset > std.math.maxInt(u32)) return error.TapeTooLarge;
        if (self.tape_count > std.math.maxInt(u32)) return error.TapeTooLarge;
        const tape_index = self.tape_count;

        if (self.tape) |tape| {
            if (tape.items.len == tape.capacity) return error.TapeTooLarge;
            tape.appendAssumeCapacity(.{
                .kind = @intFromEnum(kind),
                .payload = payload,
                .offset = @intCast(offset),
            });
        }
        self.tape_count += 1;
        return tape_index;
    }
};

fn firstInvalidUtf8Byte(input: []const u8) ?usize {
    var index: usize = 0;
    while (index < input.len) {
        const first = input[index];
        if (first < 0x80) {
            index += 1;
            continue;
        }

        const sequence_length: usize = switch (first) {
            0xC2...0xDF => 2,
            0xE0...0xEF => 3,
            0xF0...0xF4 => 4,
            else => return index,
        };
        if (input.len - index < sequence_length) return index;

        if (!isValidUtf8SecondByte(first, input[index + 1])) return index + 1;
        var continuation_offset: usize = 2;
        while (continuation_offset < sequence_length) : (continuation_offset += 1) {
            if (!isUtf8Continuation(input[index + continuation_offset])) {
                return index + continuation_offset;
            }
        }
        index += sequence_length;
    }
    return null;
}

fn isValidUtf8SecondByte(first: u8, second: u8) bool {
    return switch (first) {
        0xE0 => second >= 0xA0 and second <= 0xBF,
        0xED => second >= 0x80 and second <= 0x9F,
        0xF0 => second >= 0x90 and second <= 0xBF,
        0xF4 => second >= 0x80 and second <= 0x8F,
        else => isUtf8Continuation(second),
    };
}

fn isUtf8Continuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xBF;
}

fn validateString(
    input: []const u8,
    quote_offset: usize,
    failure_offset: *usize,
) Error!StringToken {
    std.debug.assert(quote_offset < input.len);
    std.debug.assert(input[quote_offset] == '"');

    const content_start = quote_offset + 1;
    var index = content_start;
    while (index < input.len) {
        const byte = input[index];
        if (byte == '"') {
            const content = input[content_start..index];
            if (!std.unicode.utf8ValidateSlice(content)) {
                const invalid_offset = firstInvalidUtf8Byte(content) orelse unreachable;
                failure_offset.* = content_start + invalid_offset;
                return error.InvalidUtf8;
            }
            return .{
                .content_length = content.len,
                .end_offset = index + 1,
            };
        }
        if (byte < 0x20) {
            failure_offset.* = index;
            return error.InvalidEscape;
        }
        if (byte != '\\') {
            index += 1;
            continue;
        }

        if (index + 1 >= input.len) {
            failure_offset.* = index;
            return error.InvalidEscape;
        }
        const escape = input[index + 1];
        switch (escape) {
            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => index += 2,
            'u' => {
                _ = try parseHexCodeUnit(input, index, failure_offset);
                index += 6;
            },
            else => {
                failure_offset.* = index + 1;
                return error.InvalidEscape;
            },
        }
    }

    failure_offset.* = quote_offset;
    return error.UnterminatedString;
}

fn parseHexCodeUnit(
    input: []const u8,
    slash_offset: usize,
    failure_offset: *usize,
) Error!u16 {
    if (slash_offset + 5 >= input.len) {
        failure_offset.* = input.len;
        return error.InvalidEscape;
    }
    std.debug.assert(input[slash_offset] == '\\');
    std.debug.assert(input[slash_offset + 1] == 'u');

    var value: u16 = 0;
    for (input[slash_offset + 2 .. slash_offset + 6], slash_offset + 2..) |byte, offset| {
        const digit = std.fmt.charToDigit(byte, 16) catch {
            failure_offset.* = offset;
            return error.InvalidEscape;
        };
        value = value * 16 + digit;
    }
    return value;
}

fn validateNumber(
    input: []const u8,
    start_offset: usize,
    failure_offset: *usize,
) Error!usize {
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
                else => return invalidNumberAt(byte, index, failure_offset),
            },
            .minus => switch (byte) {
                '0' => .zero,
                '1'...'9' => .integer,
                else => return invalidNumberAt(byte, index, failure_offset),
            },
            .zero => switch (byte) {
                '.' => .fraction_dot,
                'e', 'E' => .exponent_mark,
                '0'...'9' => {
                    failure_offset.* = index;
                    return error.InvalidNumber;
                },
                else => return invalidNumberAt(byte, index, failure_offset),
            },
            .integer => switch (byte) {
                '0'...'9' => .integer,
                '.' => .fraction_dot,
                'e', 'E' => .exponent_mark,
                else => return invalidNumberAt(byte, index, failure_offset),
            },
            .fraction_dot => switch (byte) {
                '0'...'9' => .fraction,
                else => return invalidNumberAt(byte, index, failure_offset),
            },
            .fraction => switch (byte) {
                '0'...'9' => .fraction,
                'e', 'E' => .exponent_mark,
                else => return invalidNumberAt(byte, index, failure_offset),
            },
            .exponent_mark => switch (byte) {
                '+', '-' => .exponent_sign,
                '0'...'9' => .exponent,
                else => return invalidNumberAt(byte, index, failure_offset),
            },
            .exponent_sign => switch (byte) {
                '0'...'9' => .exponent,
                else => return invalidNumberAt(byte, index, failure_offset),
            },
            .exponent => switch (byte) {
                '0'...'9' => .exponent,
                else => return invalidNumberAt(byte, index, failure_offset),
            },
        };
    }

    return switch (state) {
        .zero, .integer, .fraction, .exponent => index,
        else => {
            failure_offset.* = index;
            return error.InvalidNumber;
        },
    };
}

fn invalidNumberAt(
    byte: u8,
    offset: usize,
    failure_offset: *usize,
) Error {
    failure_offset.* = offset;
    return invalidNumberByte(byte);
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

fn indexForTest(
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
            if (isStructural(byte)) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            } else if (isAtomStart(byte) and !previous_in_atom) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            }
        }

        previous_in_atom = !in_string and byte != '"' and
            !isStructural(byte) and !isWhitespace(byte);
        if (byte == '\\') {
            backslash_run_length += 1;
        } else {
            backslash_run_length = 0;
        }
    }

    try result.finish(input.len);
    return result;
}

fn isStructural(byte: u8) bool {
    return switch (byte) {
        '{', '}', '[', ']', ':', ',' => true,
        else => false,
    };
}

fn isAtomStart(byte: u8) bool {
    return switch (byte) {
        '-', 't', 'f', 'n', '0'...'9' => true,
        else => false,
    };
}

fn expectStage2Error(expected: Error, input: []const u8) !void {
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    if (buildTape(testing.allocator, input, &structural_index)) |document_value| {
        var document = document_value;
        document.deinit(testing.allocator);
        return error.ExpectedStage2Error;
    } else |actual| {
        try testing.expect(actual == expected);
    }
}

fn expectStage2Diagnostic(expected: Error, input: []const u8) !Diagnostic {
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    const result = try validate(input, &structural_index);
    if (result) |diagnostic| {
        try testing.expectEqual(expected, diagnostic.err);
        return diagnostic;
    }
    return error.ExpectedStage2Error;
}

test "validate carries lexical and container diagnostic offsets" {
    const malformed_escape = "\n  [\"bad\\q\"]";
    const escape_diagnostic = try expectStage2Diagnostic(
        error.InvalidEscape,
        malformed_escape,
    );
    try testing.expectEqual(@as(usize, 9), escape_diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), escape_diagnostic.line);
    try testing.expectEqual(@as(u32, 9), escape_diagnostic.column);
    try testing.expectEqual(@as(usize, 1), escape_diagnostic.snippet_start);
    try testing.expectEqualStrings("  [\"bad\\q\"]", escape_diagnostic.snippet);

    const unclosed_array = "\n  [1";
    const array_diagnostic = try expectStage2Diagnostic(
        error.UnclosedArray,
        unclosed_array,
    );
    try testing.expectEqual(@as(usize, 3), array_diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), array_diagnostic.line);
    try testing.expectEqual(@as(u32, 3), array_diagnostic.column);
    try testing.expectEqualStrings("  [1", array_diagnostic.snippet);

    const unclosed_object = "\n {\"a\": 1";
    const object_diagnostic = try expectStage2Diagnostic(
        error.UnclosedObject,
        unclosed_object,
    );
    try testing.expectEqual(@as(usize, 2), object_diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), object_diagnostic.line);
    try testing.expectEqual(@as(u32, 2), object_diagnostic.column);
    try testing.expectEqualStrings(" {\"a\": 1", object_diagnostic.snippet);

    const scalar_without_separator = try expectStage2Diagnostic(
        error.UnexpectedToken,
        "[0 01]",
    );
    try testing.expectEqual(@as(usize, 3), scalar_without_separator.byte_offset);

    const string_without_separator = try expectStage2Diagnostic(
        error.UnexpectedToken,
        "[0 \"\\q\"]",
    );
    try testing.expectEqual(@as(usize, 3), string_without_separator.byte_offset);
}

test "validate locates the first invalid UTF-8 byte" {
    const cases = [_]struct {
        input: []const u8,
        expected_offset: usize,
    }{
        .{
            .input = &[_]u8{ '[', '"', 'a', 0xFF, '"', ']' },
            .expected_offset = 3,
        },
        .{
            .input = &[_]u8{ '[', '"', 0xE2, '(', 0xA1, '"', ']' },
            .expected_offset = 3,
        },
        .{
            .input = &[_]u8{ '[', '"', 0xE2, 0x82, 'A', '"', ']' },
            .expected_offset = 4,
        },
        .{
            .input = &[_]u8{ '[', '"', 0xF0, 0x90, 0x80, 'A', '"', ']' },
            .expected_offset = 5,
        },
        .{
            .input = &[_]u8{ '[', '"', 0xE0, 0x9F, 0x80, '"', ']' },
            .expected_offset = 3,
        },
        .{
            .input = &[_]u8{ '[', '"', 0xED, 0xA0, 0x80, '"', ']' },
            .expected_offset = 3,
        },
        .{
            .input = &[_]u8{ '[', '"', 0xF4, 0x90, 0x80, 0x80, '"', ']' },
            .expected_offset = 3,
        },
        .{
            .input = &[_]u8{ '[', '"', 0xE2, '"', ']' },
            .expected_offset = 2,
        },
    };

    for (cases) |case| {
        const diagnostic = try expectStage2Diagnostic(error.InvalidUtf8, case.input);
        try testing.expectEqual(case.expected_offset, diagnostic.byte_offset);
    }
}

test "TapeWord payload encoding never truncates u24 values" {
    const payload_max: usize = std.math.maxInt(u24);
    const payload_too_large = payload_max + 1;

    const validating_parser = Parser{
        .input = &.{},
        .indexes = &.{},
    };
    try testing.expectEqual(
        @as(u24, 0),
        try validating_parser.encodeTapePayload(payload_too_large),
    );

    var tape: std.ArrayList(TapeWord) = .empty;
    const building_parser = Parser{
        .input = &.{},
        .indexes = &.{},
        .tape = &tape,
    };
    try testing.expectEqual(
        std.math.maxInt(u24),
        try building_parser.encodeTapePayload(payload_max),
    );
    try testing.expectError(
        error.TapeTooLarge,
        building_parser.encodeTapePayload(payload_too_large),
    );
}

test "buildTape validates nested JSON and backpatches containers" {
    const input = "{\"a\":[1,true,{\"b\":\"x\"}],\"z\":null}";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var document = try buildTape(testing.allocator, input, &structural_index);
    defer document.deinit(testing.allocator);

    const expected_kinds = [_]TapeKind{
        .object_start,
        .key,
        .array_start,
        .number,
        .true_literal,
        .object_start,
        .key,
        .string,
        .object_end,
        .array_end,
        .key,
        .null_literal,
        .object_end,
    };
    try testing.expectEqual(expected_kinds.len, document.tape.len);
    for (document.tape, expected_kinds) |word, expected_kind| {
        try testing.expectEqual(expected_kind, word.tapeKind());
    }

    try testing.expectEqual(@as(u24, 2), document.tape[0].payload);
    try testing.expectEqual(@as(u24, 3), document.tape[2].payload);
    try testing.expectEqual(@as(u24, 1), document.tape[5].payload);
    try testing.expectEqual(@as(u24, 5), document.tape[8].payload);
    try testing.expectEqual(@as(u24, 2), document.tape[9].payload);
    try testing.expectEqual(@as(u24, 0), document.tape[12].payload);
    try testing.expectEqual(@as(u32, 1), document.tape[1].offset);
    try testing.expectEqual(@as(u32, 18), document.tape[7].offset);
    try testing.expectEqual(@as(u24, 1), document.tape[7].payload);
}

test "buildTape rejects essential JSON grammar error families" {
    const cases = [_]struct {
        expected: Error,
        input: []const u8,
    }{
        .{ .expected = error.EmptyDocument, .input = " \r\n\t" },
        .{ .expected = error.RootNotSingular, .input = "null true" },
        .{ .expected = error.UnexpectedToken, .input = "{\"a\" 1}" },
        .{ .expected = error.UnexpectedToken, .input = "[}" },
        .{ .expected = error.UnexpectedToken, .input = "[0 01]" },
        .{ .expected = error.UnexpectedToken, .input = "[0 \"\\q\"]" },
        .{ .expected = error.UnclosedObject, .input = "{\"a\":1" },
        .{ .expected = error.UnclosedArray, .input = "[1" },
        .{ .expected = error.InvalidNumber, .input = "[01]" },
        .{ .expected = error.InvalidEscape, .input = "[\"\\q\"]" },
        .{ .expected = error.TrailingComma, .input = "[1,]" },
        .{ .expected = error.TrailingComma, .input = "{\"a\":1,}" },
        .{ .expected = error.UnterminatedString, .input = "[\"abc" },
        .{ .expected = error.UnexpectedToken, .input = "[tru]" },
    };

    for (cases) |case| {
        try expectStage2Error(case.expected, case.input);
    }

    const invalid_utf8 = [_]u8{ '[', '"', 0xFF, '"', ']' };
    try expectStage2Error(error.InvalidUtf8, &invalid_utf8);
}

test "buildTape accepts duplicate keys without duplicate checking" {
    const input = "{\"x\":1,\"x\":2}";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var document = try buildTape(testing.allocator, input, &structural_index);
    defer document.deinit(testing.allocator);
    try testing.expectEqual(@as(u24, 2), document.tape[0].payload);
}

test "buildTape enforces the 1024 container depth boundary" {
    const valid_depth = max_depth;
    const valid_input = try testing.allocator.alloc(u8, valid_depth * 2 + 1);
    defer testing.allocator.free(valid_input);
    @memset(valid_input[0..valid_depth], '[');
    valid_input[valid_depth] = '0';
    @memset(valid_input[valid_depth + 1 ..], ']');

    var valid_index = try indexForTest(testing.allocator, valid_input);
    defer valid_index.deinit(testing.allocator);
    var document = try buildTape(testing.allocator, valid_input, &valid_index);
    defer document.deinit(testing.allocator);
    try testing.expectEqual(valid_depth * 2 + 1, document.tape.len);

    const invalid_depth = max_depth + 1;
    const invalid_input = try testing.allocator.alloc(u8, invalid_depth * 2 + 1);
    defer testing.allocator.free(invalid_input);
    @memset(invalid_input[0..invalid_depth], '[');
    invalid_input[invalid_depth] = '0';
    @memset(invalid_input[invalid_depth + 1 ..], ']');
    try expectStage2Error(error.DepthExceeded, invalid_input);
}

test "buildTape accepts escaped and raw UTF-8 strings" {
    const input = "[\"café\",\"\\u20AC\",\"\\uD834\\uDD1E\",\"line\\n\"]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var document = try buildTape(testing.allocator, input, &structural_index);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(@as(u24, 4), document.tape[0].payload);
    try testing.expectEqual(@as(u24, 5), document.tape[1].payload);
    try testing.expectEqual(@as(u24, 6), document.tape[2].payload);
    try testing.expectEqual(@as(u24, 12), document.tape[3].payload);
    try testing.expectEqual(@as(u24, 6), document.tape[4].payload);
}

test "buildTape accepts lone UTF-16 surrogate escape syntax" {
    const input = "[\"\\uD800\",\"\\uDD1E\"]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var document = try buildTape(testing.allocator, input, &structural_index);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), document.tape.len);
    try testing.expectEqual(TapeKind.array_start, document.tape[0].tapeKind());
    try testing.expectEqual(@as(u24, 6), document.tape[1].payload);
    try testing.expectEqual(@as(u24, 6), document.tape[2].payload);
    try testing.expectEqual(@as(u24, 2), document.tape[0].payload);
}

test "diagnosticAt reports byte location and zero-copy line snippet" {
    const input = "one\nbad token\nthree";
    const diagnostic = diagnosticAt(input, error.UnexpectedToken, 6);

    try testing.expectEqual(@as(usize, 6), diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), diagnostic.line);
    try testing.expectEqual(@as(u32, 3), diagnostic.column);
    try testing.expectEqual(@as(usize, 4), diagnostic.snippet_start);
    try testing.expectEqualStrings("bad token", diagnostic.snippet);
    try testing.expect(diagnostic.snippet.ptr == input.ptr + diagnostic.snippet_start);
}

test "TapeCursor navigates nested containers and skips complete values" {
    const input = "{\"a\":[1,{\"b\":[]}],\"empty\":{}}";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var document = try buildTape(testing.allocator, input, &structural_index);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    try testing.expectEqual(TapeKind.object_start, (try cursor.peek()).tapeKind());
    try testing.expectEqual(@as(u32, 2), try cursor.containerCount());

    try cursor.advance();
    try testing.expectEqualStrings("a", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqual(@as(u32, 2), try cursor.containerCount());
    try cursor.advance();
    try testing.expectEqualStrings("1", try cursor.rawValue());
    try cursor.skipValue();
    try testing.expectEqual(@as(usize, 4), cursor.position());

    try cursor.skipValue();
    try testing.expectEqual(@as(usize, 9), cursor.position());
    const array_start = try cursor.matchingStart();
    try testing.expectEqual(@as(usize, 2), array_start.position());

    try cursor.advance();
    try testing.expectEqualStrings("empty", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqual(@as(u32, 0), try cursor.containerCount());
    try cursor.skipValue();
    try testing.expectEqual(@as(usize, 13), cursor.position());
    const object_start = try cursor.matchingStart();
    try testing.expectEqual(@as(usize, 0), object_start.position());

    try cursor.advance();
    try testing.expectEqual(document.tape.len, cursor.position());
    try testing.expectError(error.PositionOutOfBounds, cursor.peek());
}

test "TapeCursor skips empty object and array roots" {
    const cases = [_][]const u8{ "{}", "[]" };
    for (cases) |input| {
        var structural_index = try indexForTest(testing.allocator, input);
        defer structural_index.deinit(testing.allocator);

        var document = try buildTape(testing.allocator, input, &structural_index);
        defer document.deinit(testing.allocator);

        var cursor = try document.root(input);
        try testing.expectEqual(@as(u32, 0), try cursor.containerCount());
        try cursor.skipValue();
        try testing.expectEqual(document.tape.len, cursor.position());
    }
}

test "TapeCursor returns escaped strings keys numbers and literals without copying" {
    const input =
        "{\"a\\n\":\"x\\u0041\",\"n\":-12.5e+2,\"t\":true,\"f\":false,\"z\":null}";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var document = try buildTape(testing.allocator, input, &structural_index);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    try cursor.advance();
    try testing.expectEqualStrings("a\\n", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("x\\u0041", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("n", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("-12.5e+2", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("t", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("true", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("f", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("false", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("z", try cursor.rawValue());
    try cursor.advance();
    const raw_null = try cursor.rawValue();
    try testing.expectEqualStrings("null", raw_null);
    try testing.expect(
        raw_null.ptr ==
            input.ptr + @as(usize, @intCast(document.tape[cursor.position()].offset)),
    );
}

test "TapeCursor matchingStart validates only the local backlink" {
    var tape = [_]TapeWord{
        .{ .kind = @intFromEnum(TapeKind.array_start), .payload = 1, .offset = 0 },
        .{ .kind = @intFromEnum(TapeKind.key), .payload = 0, .offset = 0 },
        .{ .kind = @intFromEnum(TapeKind.array_end), .payload = 0, .offset = 1 },
    };
    const document = Document{ .tape = tape[0..] };
    var cursor = try document.root("[]");
    try cursor.advance();
    try cursor.advance();

    const start = try cursor.matchingStart();
    try testing.expectEqual(@as(usize, 0), start.position());
}

test "TapeCursor raw strings validate source and exact tape extent" {
    const cases = [_]struct {
        kind: TapeKind,
        input: []const u8,
        payload: u24,
    }{
        .{ .kind = .string, .input = "\"a\\q\"", .payload = 3 },
        .{ .kind = .key, .input = "\"a\\q\"", .payload = 3 },
        .{ .kind = .string, .input = "\"a\\\"b\"", .payload = 2 },
        .{ .kind = .key, .input = "\"a\\\"b\"", .payload = 2 },
    };

    for (cases) |case| {
        var tape = [_]TapeWord{.{
            .kind = @intFromEnum(case.kind),
            .payload = case.payload,
            .offset = 0,
        }};
        const document = Document{ .tape = tape[0..] };
        const cursor = try document.root(case.input);
        try testing.expectError(error.InvalidSource, cursor.rawValue());
    }
}

test "TapeCursor rejects malformed kinds order bounds counts and source ranges" {
    var invalid_kind_tape = [_]TapeWord{.{
        .kind = std.math.maxInt(u8),
        .payload = 0,
        .offset = 0,
    }};
    const invalid_kind_document = Document{ .tape = invalid_kind_tape[0..] };
    try testing.expectError(error.InvalidTapeKind, invalid_kind_document.root("0"));

    var wrong_end_tape = [_]TapeWord{
        .{ .kind = @intFromEnum(TapeKind.array_start), .payload = 0, .offset = 0 },
        .{ .kind = @intFromEnum(TapeKind.object_end), .payload = 0, .offset = 1 },
    };
    const wrong_end_document = Document{ .tape = wrong_end_tape[0..] };
    var wrong_end_cursor = try wrong_end_document.root("[]");
    try testing.expectError(error.InvalidTapeOrder, wrong_end_cursor.skipValue());

    var unclosed_tape = [_]TapeWord{
        .{ .kind = @intFromEnum(TapeKind.array_start), .payload = 0, .offset = 0 },
    };
    const unclosed_document = Document{ .tape = unclosed_tape[0..] };
    var unclosed_cursor = try unclosed_document.root("[");
    try testing.expectError(error.TapeOutOfBounds, unclosed_cursor.skipValue());

    var wrong_count_tape = [_]TapeWord{
        .{ .kind = @intFromEnum(TapeKind.array_start), .payload = 2, .offset = 0 },
        .{ .kind = @intFromEnum(TapeKind.number), .payload = 0, .offset = 1 },
        .{ .kind = @intFromEnum(TapeKind.array_end), .payload = 0, .offset = 2 },
    };
    const wrong_count_document = Document{ .tape = wrong_count_tape[0..] };
    var wrong_count_cursor = try wrong_count_document.root("[0]");
    try testing.expectError(error.InvalidTapeOrder, wrong_count_cursor.skipValue());

    var bad_start_tape = [_]TapeWord{
        .{ .kind = @intFromEnum(TapeKind.array_start), .payload = 0, .offset = 0 },
        .{ .kind = @intFromEnum(TapeKind.array_end), .payload = 2, .offset = 1 },
    };
    const bad_start_document = Document{ .tape = bad_start_tape[0..] };
    var bad_start_cursor = try bad_start_document.root("[]");
    try bad_start_cursor.advance();
    try testing.expectError(error.TapeOutOfBounds, bad_start_cursor.matchingStart());

    var string_tape = [_]TapeWord{.{
        .kind = @intFromEnum(TapeKind.string),
        .payload = 4,
        .offset = 0,
    }};
    const string_document = Document{ .tape = string_tape[0..] };
    var string_cursor = try string_document.root("\"x\"");
    try testing.expectError(error.SourceOutOfBounds, string_cursor.rawValue());

    var number_tape = [_]TapeWord{.{
        .kind = @intFromEnum(TapeKind.number),
        .payload = 0,
        .offset = 0,
    }};
    const number_document = Document{ .tape = number_tape[0..] };
    var number_cursor = try number_document.root("0");
    try testing.expectError(error.TypeMismatch, number_cursor.containerCount());
}
