const std = @import("std");
const simd = @import("simd.zig");
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

pub const Dialect = enum {
    json,
    jsonc,
    json5,
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
    dialect: Dialect,

    /// Creates a cursor over the owned tape and borrowed source input.
    ///
    /// The document owns only its tape. The caller must keep `input` and this
    /// document alive for as long as the returned cursor is used.
    pub fn root(self: *const Document, input: []const u8) NavigationError!TapeCursor {
        if (self.tape.len == 0) return error.TapeOutOfBounds;
        const cursor = TapeCursor{
            .tape = self.tape,
            .input = input,
            .dialect = self.dialect,
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
pub const TapeCursor = struct {
    tape: []const TapeWord,
    input: []const u8,
    dialect: Dialect,
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
            .dialect = self.dialect,
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
            .string, .key => return self.rawString(word, kind),
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
    fn rawString(
        self: *const TapeCursor,
        word: TapeWord,
        kind: TapeKind,
    ) NavigationError![]const u8 {
        const offset: usize = @intCast(word.offset);
        if (offset >= self.input.len) return error.SourceOutOfBounds;
        const quote = self.input[offset];
        const content_length: usize = @intCast(word.payload);

        if (self.dialect == .json5 and quote != '"' and quote != '\'') {
            if (kind != .key) return error.InvalidSource;
            if (content_length > self.input.len - offset) {
                return error.SourceOutOfBounds;
            }
            const content_end = offset + content_length;
            var failure_offset = offset;
            const identifier_end = validateJson5Identifier(
                self.input,
                offset,
                &failure_offset,
            ) catch {
                return error.InvalidSource;
            };
            if (identifier_end != content_end) return error.InvalidSource;
            return self.input[offset..content_end];
        }
        if (self.dialect != .json5 and quote != '"') return error.InvalidSource;

        const content_start = offset + 1;
        if (content_length > self.input.len - content_start) {
            return error.SourceOutOfBounds;
        }
        const content_end = content_start + content_length;
        if (content_end >= self.input.len) return error.SourceOutOfBounds;
        var failure_offset = offset;
        const token = validateString(
            self.input,
            offset,
            self.dialect,
            &failure_offset,
        ) catch {
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
        const end = validateNumber(
            self.input,
            offset,
            self.dialect,
            &failure_offset,
        ) catch {
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
        if (end < self.input.len and
            !isAtomBoundaryAt(self.input, end, self.dialect))
        {
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
    entries: [max_depth]DepthEntry,
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

/// Builds an owned tape after complete dialect-specific syntax validation.
pub fn buildTape(
    allocator: std.mem.Allocator,
    input: []const u8,
    structural_index: *const stage1.StructuralIndex,
    dialect: Dialect,
) BuildError!Document {
    if (input.len > std.math.maxInt(u32)) return error.TapeTooLarge;

    const indexes = structural_index.slice();
    const tape_capacity = if (dialect == .json) indexes.len else input.len;
    var tape = try std.ArrayList(TapeWord).initCapacity(allocator, tape_capacity);
    errdefer tape.deinit(allocator);

    var parser = Parser{
        .input = input,
        .indexes = indexes,
        .tape = &tape,
        .dialect = dialect,
        // SAFETY: push writes every entry before top exposes it.
        .depth = .{ .entries = undefined },
    };
    try parser.run();

    return .{
        .tape = try tape.toOwnedSlice(allocator),
        .dialect = dialect,
    };
}

/// Validates an indexed document without allocating a tape.
pub fn validate(
    input: []const u8,
    structural_index: *const stage1.StructuralIndex,
    dialect: Dialect,
) ValidationError!?Diagnostic {
    if (input.len > std.math.maxInt(u32)) return error.TapeTooLarge;

    var parser = Parser{
        .input = input,
        .indexes = structural_index.slice(),
        .dialect = dialect,
        // SAFETY: push writes every entry before top exposes it.
        .depth = .{ .entries = undefined },
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
    dialect: Dialect,
    tape: ?*std.ArrayList(TapeWord) = null,
    structural_position: usize = 0,
    byte_position: usize = 0,
    failure_offset: usize = 0,
    tape_count: usize = 0,
    depth: DepthStack,
    expect: Expect = .value_after_open,
    root_started: bool = false,
    root_done: bool = false,

    fn run(self: *Parser) ParseError!void {
        while (true) {
            try self.skipIgnored();
            if (self.byte_position == self.input.len) break;
            if (self.root_done) {
                return self.fail(error.RootNotSingular, self.byte_position);
            }

            self.failure_offset = self.byte_position;
            const current_byte = self.input[self.byte_position];
            const is_double_quote = current_byte == '"';
            const is_single_quote = self.dialect == .json5 and current_byte == '\'';
            if (self.dialect != .json and (is_double_quote or is_single_quote)) {
                self.byte_position += 1;
                try self.consumeString();
                continue;
            }

            const byte = try self.takeIndexedByte();
            switch (byte) {
                '{' => try self.openContainer(false),
                '[' => try self.openContainer(true),
                '}' => try self.closeContainer(false),
                ']' => try self.closeContainer(true),
                ':' => try self.consumeColon(),
                ',' => try self.consumeComma(),
                '"' => try self.consumeString(),
                '-' => try self.consumeNumber(),
                '0'...'9' => try self.consumeNumber(),
                '+' => {
                    if (self.dialect != .json5) {
                        return self.fail(error.InvalidNumber, self.byte_position - 1);
                    }
                    try self.consumeNumber();
                },
                '.' => {
                    if (self.dialect != .json5) {
                        return self.fail(error.InvalidNumber, self.byte_position - 1);
                    }
                    try self.consumeNumber();
                },
                't' => {
                    if (self.dialect == .json5 and self.isKeyExpected()) {
                        try self.consumeIdentifier(self.byte_position - 1);
                    } else {
                        try self.consumeLiteral("true", .true_literal);
                    }
                },
                'f' => {
                    if (self.dialect == .json5 and self.isKeyExpected()) {
                        try self.consumeIdentifier(self.byte_position - 1);
                    } else {
                        try self.consumeLiteral("false", .false_literal);
                    }
                },
                'n' => {
                    if (self.dialect == .json5 and self.isKeyExpected()) {
                        try self.consumeIdentifier(self.byte_position - 1);
                    } else {
                        try self.consumeLiteral("null", .null_literal);
                    }
                },
                'I', 'N' => {
                    if (self.dialect != .json5) {
                        return self.fail(error.UnexpectedToken, self.byte_position - 1);
                    }
                    if (self.isKeyExpected()) {
                        try self.consumeIdentifier(self.byte_position - 1);
                    } else {
                        try self.consumeNumber();
                    }
                },
                else => {
                    if (self.dialect == .json5 and self.isKeyExpected()) {
                        try self.consumeIdentifier(self.byte_position - 1);
                    } else {
                        return self.fail(error.UnexpectedToken, self.byte_position - 1);
                    }
                },
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

    fn skipIgnored(self: *Parser) ParseError!void {
        while (self.byte_position < self.input.len) {
            if (try self.skipWhitespace()) continue;
            if (self.dialect == .json) return;
            if (self.input[self.byte_position] != '/') return;
            if (self.byte_position + 1 >= self.input.len) {
                return self.fail(error.UnexpectedToken, self.byte_position);
            }

            const next_byte = self.input[self.byte_position + 1];
            if (next_byte == '/') {
                self.byte_position += 2;
                const content_start = self.byte_position;
                while (self.byte_position < self.input.len) {
                    const is_line_terminator = if (self.dialect == .json5)
                        json5LineTerminatorWidth(self.input, self.byte_position) != null
                    else
                        self.input[self.byte_position] == '\n' or
                            self.input[self.byte_position] == '\r';
                    if (is_line_terminator) break;
                    self.byte_position += 1;
                }
                if (firstInvalidUtf8Byte(
                    self.input[content_start..self.byte_position],
                )) |invalid_offset| {
                    return self.fail(
                        error.InvalidUtf8,
                        content_start + invalid_offset,
                    );
                }
                continue;
            }
            if (next_byte == '*') {
                const comment_start = self.byte_position;
                self.byte_position += 2;
                const content_start = self.byte_position;
                var closed = false;
                while (self.byte_position + 1 < self.input.len) : (self.byte_position += 1) {
                    if (self.input[self.byte_position] == '*' and
                        self.input[self.byte_position + 1] == '/')
                    {
                        self.byte_position += 2;
                        closed = true;
                        break;
                    }
                }
                const content_end = if (closed)
                    self.byte_position - 2
                else
                    self.input.len;
                if (firstInvalidUtf8Byte(
                    self.input[content_start..content_end],
                )) |invalid_offset| {
                    return self.fail(
                        error.InvalidUtf8,
                        content_start + invalid_offset,
                    );
                }
                if (!closed) return self.fail(error.UnexpectedToken, comment_start);
                continue;
            }
            return;
        }
    }

    fn skipWhitespace(self: *Parser) ParseError!bool {
        if (self.byte_position >= self.input.len) return false;
        if (isWhitespace(self.input[self.byte_position])) {
            self.byte_position += 1;
            return true;
        }
        if (self.dialect == .json5 and
            (self.input[self.byte_position] == 0x0b or
                self.input[self.byte_position] == 0x0C))
        {
            self.byte_position += 1;
            return true;
        }
        if (self.dialect == .json5) {
            if (json5WhitespaceWidth(self.input, self.byte_position)) |width| {
                self.byte_position += width;
                return true;
            }
        }
        return false;
    }

    fn takeIndexedByte(self: *Parser) Error!u8 {
        if (self.byte_position >= self.input.len) {
            return self.fail(error.UnexpectedToken, self.byte_position);
        }
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
                .value_after_comma => {
                    if (self.dialect != .json5) {
                        return self.fail(error.TrailingComma, close_offset);
                    }
                },
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
                .key_after_comma => {
                    if (self.dialect != .json5) {
                        return self.fail(error.TrailingComma, close_offset);
                    }
                },
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
            self.dialect,
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
            self.dialect,
            &self.failure_offset,
        );
        _ = try self.emit(.number, 0, start_offset);
        self.completeScalarValue();
    }

    fn consumeIdentifier(self: *Parser, start_offset: usize) ParseError!void {
        if (!self.isKeyExpected()) {
            return self.fail(error.UnexpectedToken, start_offset);
        }

        const end_offset = try validateJson5Identifier(
            self.input,
            start_offset,
            &self.failure_offset,
        );
        self.byte_position = end_offset;
        const payload = try self.encodeTapePayload(end_offset - start_offset);
        _ = try self.emit(.key, payload, start_offset);
        self.expect = .colon;
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
        if (end_offset < self.input.len and
            !isAtomBoundaryAt(self.input, end_offset, self.dialect))
        {
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
    return switch (simd.validateUtf8(input)) {
        .valid => null,
        .invalid => |error_info| switch (error_info.kind) {
            .missing_continuation => legacyMissingContinuationOffset(
                input,
                error_info.offset,
            ),
            else => error_info.offset,
        },
    };
}

fn legacyMissingContinuationOffset(input: []const u8, missing_offset: usize) usize {
    if (missing_offset == 0 or missing_offset >= input.len) return missing_offset;

    var sequence_start = missing_offset;
    while (sequence_start > 0) {
        const previous = input[sequence_start - 1];
        if (previous < 0x80 or previous > 0xBF) break;
        sequence_start -= 1;
    }
    if (sequence_start == 0) return missing_offset;

    const header_offset = sequence_start - 1;
    const sequence_length: usize = switch (input[header_offset]) {
        0xC0...0xC1 => return header_offset,
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return missing_offset,
    };

    // The legacy UTF-8 validator checked total sequence length before
    // continuation bytes, so an incomplete sequence points at its header.
    if (input.len - header_offset < sequence_length) return header_offset;
    return missing_offset;
}

fn validateString(
    input: []const u8,
    quote_offset: usize,
    dialect: Dialect,
    failure_offset: *usize,
) Error!StringToken {
    if (quote_offset >= input.len) {
        failure_offset.* = quote_offset;
        return error.UnterminatedString;
    }
    const quote = input[quote_offset];
    if (dialect != .json5 and quote != '"') {
        failure_offset.* = quote_offset;
        return error.UnexpectedToken;
    }
    if (dialect == .json5 and quote != '"' and quote != '\'') {
        failure_offset.* = quote_offset;
        return error.UnexpectedToken;
    }

    const content_start = quote_offset + 1;
    var index = content_start;
    while (index < input.len) {
        const byte = input[index];
        if (byte == quote) {
            const content = input[content_start..index];
            if (firstInvalidUtf8Byte(content)) |invalid_offset| {
                failure_offset.* = content_start + invalid_offset;
                return error.InvalidUtf8;
            }
            return .{
                .content_length = content.len,
                .end_offset = index + 1,
            };
        }
        if (dialect != .json5 and byte < 0x20) {
            failure_offset.* = index;
            return error.InvalidEscape;
        }
        if (dialect == .json5 and (byte == '\n' or byte == '\r')) {
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
        if (dialect == .json5) {
            if (json5LineTerminatorWidth(input, index + 1)) |width| {
                index += 1 + width;
                continue;
            }
        }
        switch (escape) {
            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => index += 2,
            'u' => {
                _ = try parseHexCodeUnit(input, index, failure_offset);
                index += 6;
            },
            else => {
                if (dialect != .json5) {
                    failure_offset.* = index + 1;
                    return error.InvalidEscape;
                }
                switch (escape) {
                    '\n' => index += 2,
                    '\r' => {
                        index += if (index + 2 < input.len and
                            input[index + 2] == '\n') 3 else 2;
                    },
                    '\'' => index += 2,
                    'v' => index += 2,
                    '0' => {
                        if (index + 2 < input.len and
                            input[index + 2] >= '0' and input[index + 2] <= '9')
                        {
                            failure_offset.* = index + 2;
                            return error.InvalidEscape;
                        }
                        index += 2;
                    },
                    'x' => {
                        if (index + 3 >= input.len) {
                            failure_offset.* = input.len;
                            return error.InvalidEscape;
                        }
                        _ = std.fmt.charToDigit(input[index + 2], 16) catch {
                            failure_offset.* = index + 2;
                            return error.InvalidEscape;
                        };
                        _ = std.fmt.charToDigit(input[index + 3], 16) catch {
                            failure_offset.* = index + 3;
                            return error.InvalidEscape;
                        };
                        index += 4;
                    },
                    else => {
                        if (escape >= '0' and escape <= '9') {
                            failure_offset.* = index + 1;
                            return error.InvalidEscape;
                        }
                        index += 2;
                    },
                }
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
    dialect: Dialect,
    failure_offset: *usize,
) Error!usize {
    if (dialect == .json5) {
        return validateJson5Number(input, start_offset, failure_offset);
    }
    return validateJsonNumber(input, start_offset, dialect, failure_offset);
}

fn validateJsonNumber(
    input: []const u8,
    start_offset: usize,
    dialect: Dialect,
    failure_offset: *usize,
) Error!usize {
    var state: NumberState = .start;
    var index = start_offset;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (isAtomBoundaryAt(input, index, dialect)) break;

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

fn validateJson5Number(
    input: []const u8,
    start_offset: usize,
    failure_offset: *usize,
) Error!usize {
    if (start_offset >= input.len) {
        failure_offset.* = start_offset;
        return error.InvalidNumber;
    }

    var index = start_offset;
    if (input[index] == '+' or input[index] == '-') {
        index += 1;
        if (index == input.len) {
            failure_offset.* = index;
            return error.InvalidNumber;
        }
    }

    if (std.mem.startsWith(u8, input[index..], "Infinity")) {
        index += "Infinity".len;
        if (!isAtomBoundaryAt(input, index, .json5)) {
            return invalidNumberAt(input[index], index, failure_offset);
        }
        return index;
    }
    if (std.mem.startsWith(u8, input[index..], "NaN")) {
        index += "NaN".len;
        if (!isAtomBoundaryAt(input, index, .json5)) {
            return invalidNumberAt(input[index], index, failure_offset);
        }
        return index;
    }

    if (input[index] == '0' and index + 1 < input.len and
        (input[index + 1] == 'x' or input[index + 1] == 'X'))
    {
        index += 2;
        const hex_start = index;
        while (index < input.len and isHexDigit(input[index])) : (index += 1) {}
        if (index == hex_start) {
            failure_offset.* = index;
            return error.InvalidNumber;
        }
        if (!isAtomBoundaryAt(input, index, .json5)) {
            return invalidNumberAt(input[index], index, failure_offset);
        }
        return index;
    }

    var integer_digits: usize = 0;
    const integer_start = index;
    while (index < input.len and isDecimalDigit(input[index])) : (index += 1) {
        integer_digits += 1;
    }
    if (integer_digits > 1 and input[integer_start] == '0') {
        failure_offset.* = integer_start + 1;
        return error.InvalidNumber;
    }

    var fraction_digits: usize = 0;
    if (index < input.len and input[index] == '.') {
        index += 1;
        while (index < input.len and isDecimalDigit(input[index])) : (index += 1) {
            fraction_digits += 1;
        }
    }
    if (integer_digits == 0 and fraction_digits == 0) {
        failure_offset.* = index;
        return error.InvalidNumber;
    }

    if (index < input.len and (input[index] == 'e' or input[index] == 'E')) {
        index += 1;
        if (index < input.len and (input[index] == '+' or input[index] == '-')) {
            index += 1;
        }
        const exponent_start = index;
        while (index < input.len and isDecimalDigit(input[index])) : (index += 1) {}
        if (index == exponent_start) {
            failure_offset.* = index;
            return error.InvalidNumber;
        }
    }
    if (!isAtomBoundaryAt(input, index, .json5)) {
        return invalidNumberAt(input[index], index, failure_offset);
    }
    return index;
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

fn isDecimalDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isHexDigit(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

fn json5WhitespaceWidth(input: []const u8, byte_offset: usize) ?usize {
    if (byte_offset >= input.len) return null;
    const byte = input[byte_offset];
    if (byte == 0x0b or byte == 0x0C) return 1;
    if (byte == 0xc2 and byte_offset + 1 < input.len and input[byte_offset + 1] == 0xa0) {
        return 2;
    }
    if (byte == 0xe1 and byte_offset + 2 < input.len and
        input[byte_offset + 1] == 0x9a and input[byte_offset + 2] == 0x80)
    {
        return 3;
    }
    if (byte == 0xe2 and byte_offset + 2 < input.len and
        input[byte_offset + 1] == 0x80)
    {
        const third = input[byte_offset + 2];
        if (third >= 0x80 and third <= 0x8a or third == 0xa8 or
            third == 0xa9 or third == 0xaf)
        {
            return 3;
        }
    }
    if (byte == 0xe2 and byte_offset + 2 < input.len and
        input[byte_offset + 1] == 0x81 and input[byte_offset + 2] == 0x9f)
    {
        return 3;
    }
    if (byte == 0xe3 and byte_offset + 2 < input.len and
        input[byte_offset + 1] == 0x80 and input[byte_offset + 2] == 0x80)
    {
        return 3;
    }
    if (byte == 0xef and byte_offset + 2 < input.len and
        input[byte_offset + 1] == 0xbb and input[byte_offset + 2] == 0xbf)
    {
        return 3;
    }
    return null;
}

fn json5LineTerminatorWidth(input: []const u8, byte_offset: usize) ?usize {
    if (byte_offset >= input.len) return null;
    const byte = input[byte_offset];
    if (byte == '\n') return 1;
    if (byte == '\r') {
        return if (byte_offset + 1 < input.len and input[byte_offset + 1] == '\n')
            2
        else
            1;
    }
    if (byte == 0xe2 and byte_offset + 2 < input.len and
        input[byte_offset + 1] == 0x80 and
        (input[byte_offset + 2] == 0xa8 or input[byte_offset + 2] == 0xa9))
    {
        return 3;
    }
    return null;
}

/// Unicode ID_Start and ID_Continue ranges for JSON5 IdentifierName.
const json5_identifier_start_ranges = [_]u21{
    0x41,    0x5A,    0x61,    0x7A,    0xAA,    0xAA,    0xB5,    0xB5,    0xBA,    0xBA,    0xC0,    0xD6,
    0xD8,    0xF6,    0xF8,    0x2C1,   0x2C6,   0x2D1,   0x2E0,   0x2E4,   0x2EC,   0x2EC,   0x2EE,   0x2EE,
    0x370,   0x374,   0x376,   0x377,   0x37A,   0x37D,   0x37F,   0x37F,   0x386,   0x386,   0x388,   0x38A,
    0x38C,   0x38C,   0x38E,   0x3A1,   0x3A3,   0x3F5,   0x3F7,   0x481,   0x48A,   0x52F,   0x531,   0x556,
    0x559,   0x559,   0x560,   0x588,   0x5D0,   0x5EA,   0x5EF,   0x5F2,   0x620,   0x64A,   0x66E,   0x66F,
    0x671,   0x6D3,   0x6D5,   0x6D5,   0x6E5,   0x6E6,   0x6EE,   0x6EF,   0x6FA,   0x6FC,   0x6FF,   0x6FF,
    0x710,   0x710,   0x712,   0x72F,   0x74D,   0x7A5,   0x7B1,   0x7B1,   0x7CA,   0x7EA,   0x7F4,   0x7F5,
    0x7FA,   0x7FA,   0x800,   0x815,   0x81A,   0x81A,   0x824,   0x824,   0x828,   0x828,   0x840,   0x858,
    0x860,   0x86A,   0x870,   0x887,   0x889,   0x88F,   0x8A0,   0x8C9,   0x904,   0x939,   0x93D,   0x93D,
    0x950,   0x950,   0x958,   0x961,   0x971,   0x980,   0x985,   0x98C,   0x98F,   0x990,   0x993,   0x9A8,
    0x9AA,   0x9B0,   0x9B2,   0x9B2,   0x9B6,   0x9B9,   0x9BD,   0x9BD,   0x9CE,   0x9CE,   0x9DC,   0x9DD,
    0x9DF,   0x9E1,   0x9F0,   0x9F1,   0x9FC,   0x9FC,   0xA05,   0xA0A,   0xA0F,   0xA10,   0xA13,   0xA28,
    0xA2A,   0xA30,   0xA32,   0xA33,   0xA35,   0xA36,   0xA38,   0xA39,   0xA59,   0xA5C,   0xA5E,   0xA5E,
    0xA72,   0xA74,   0xA85,   0xA8D,   0xA8F,   0xA91,   0xA93,   0xAA8,   0xAAA,   0xAB0,   0xAB2,   0xAB3,
    0xAB5,   0xAB9,   0xABD,   0xABD,   0xAD0,   0xAD0,   0xAE0,   0xAE1,   0xAF9,   0xAF9,   0xB05,   0xB0C,
    0xB0F,   0xB10,   0xB13,   0xB28,   0xB2A,   0xB30,   0xB32,   0xB33,   0xB35,   0xB39,   0xB3D,   0xB3D,
    0xB5C,   0xB5D,   0xB5F,   0xB61,   0xB71,   0xB71,   0xB83,   0xB83,   0xB85,   0xB8A,   0xB8E,   0xB90,
    0xB92,   0xB95,   0xB99,   0xB9A,   0xB9C,   0xB9C,   0xB9E,   0xB9F,   0xBA3,   0xBA4,   0xBA8,   0xBAA,
    0xBAE,   0xBB9,   0xBD0,   0xBD0,   0xC05,   0xC0C,   0xC0E,   0xC10,   0xC12,   0xC28,   0xC2A,   0xC39,
    0xC3D,   0xC3D,   0xC58,   0xC5A,   0xC5C,   0xC5D,   0xC60,   0xC61,   0xC80,   0xC80,   0xC85,   0xC8C,
    0xC8E,   0xC90,   0xC92,   0xCA8,   0xCAA,   0xCB3,   0xCB5,   0xCB9,   0xCBD,   0xCBD,   0xCDC,   0xCDE,
    0xCE0,   0xCE1,   0xCF1,   0xCF2,   0xD04,   0xD0C,   0xD0E,   0xD10,   0xD12,   0xD3A,   0xD3D,   0xD3D,
    0xD4E,   0xD4E,   0xD54,   0xD56,   0xD5F,   0xD61,   0xD7A,   0xD7F,   0xD85,   0xD96,   0xD9A,   0xDB1,
    0xDB3,   0xDBB,   0xDBD,   0xDBD,   0xDC0,   0xDC6,   0xE01,   0xE30,   0xE32,   0xE33,   0xE40,   0xE46,
    0xE81,   0xE82,   0xE84,   0xE84,   0xE86,   0xE8A,   0xE8C,   0xEA3,   0xEA5,   0xEA5,   0xEA7,   0xEB0,
    0xEB2,   0xEB3,   0xEBD,   0xEBD,   0xEC0,   0xEC4,   0xEC6,   0xEC6,   0xEDC,   0xEDF,   0xF00,   0xF00,
    0xF40,   0xF47,   0xF49,   0xF6C,   0xF88,   0xF8C,   0x1000,  0x102A,  0x103F,  0x103F,  0x1050,  0x1055,
    0x105A,  0x105D,  0x1061,  0x1061,  0x1065,  0x1066,  0x106E,  0x1070,  0x1075,  0x1081,  0x108E,  0x108E,
    0x10A0,  0x10C5,  0x10C7,  0x10C7,  0x10CD,  0x10CD,  0x10D0,  0x10FA,  0x10FC,  0x1248,  0x124A,  0x124D,
    0x1250,  0x1256,  0x1258,  0x1258,  0x125A,  0x125D,  0x1260,  0x1288,  0x128A,  0x128D,  0x1290,  0x12B0,
    0x12B2,  0x12B5,  0x12B8,  0x12BE,  0x12C0,  0x12C0,  0x12C2,  0x12C5,  0x12C8,  0x12D6,  0x12D8,  0x1310,
    0x1312,  0x1315,  0x1318,  0x135A,  0x1380,  0x138F,  0x13A0,  0x13F5,  0x13F8,  0x13FD,  0x1401,  0x166C,
    0x166F,  0x167F,  0x1681,  0x169A,  0x16A0,  0x16EA,  0x16EE,  0x16F8,  0x1700,  0x1711,  0x171F,  0x1731,
    0x1740,  0x1751,  0x1760,  0x176C,  0x176E,  0x1770,  0x1780,  0x17B3,  0x17D7,  0x17D7,  0x17DC,  0x17DC,
    0x1820,  0x1878,  0x1880,  0x18A8,  0x18AA,  0x18AA,  0x18B0,  0x18F5,  0x1900,  0x191E,  0x1950,  0x196D,
    0x1970,  0x1974,  0x1980,  0x19AB,  0x19B0,  0x19C9,  0x1A00,  0x1A16,  0x1A20,  0x1A54,  0x1AA7,  0x1AA7,
    0x1B05,  0x1B33,  0x1B45,  0x1B4C,  0x1B83,  0x1BA0,  0x1BAE,  0x1BAF,  0x1BBA,  0x1BE5,  0x1C00,  0x1C23,
    0x1C4D,  0x1C4F,  0x1C5A,  0x1C7D,  0x1C80,  0x1C8A,  0x1C90,  0x1CBA,  0x1CBD,  0x1CBF,  0x1CE9,  0x1CEC,
    0x1CEE,  0x1CF3,  0x1CF5,  0x1CF6,  0x1CFA,  0x1CFA,  0x1D00,  0x1DBF,  0x1E00,  0x1F15,  0x1F18,  0x1F1D,
    0x1F20,  0x1F45,  0x1F48,  0x1F4D,  0x1F50,  0x1F57,  0x1F59,  0x1F59,  0x1F5B,  0x1F5B,  0x1F5D,  0x1F5D,
    0x1F5F,  0x1F7D,  0x1F80,  0x1FB4,  0x1FB6,  0x1FBC,  0x1FBE,  0x1FBE,  0x1FC2,  0x1FC4,  0x1FC6,  0x1FCC,
    0x1FD0,  0x1FD3,  0x1FD6,  0x1FDB,  0x1FE0,  0x1FEC,  0x1FF2,  0x1FF4,  0x1FF6,  0x1FFC,  0x2071,  0x2071,
    0x207F,  0x207F,  0x2090,  0x209C,  0x2102,  0x2102,  0x2107,  0x2107,  0x210A,  0x2113,  0x2115,  0x2115,
    0x2118,  0x211D,  0x2124,  0x2124,  0x2126,  0x2126,  0x2128,  0x2128,  0x212A,  0x2139,  0x213C,  0x213F,
    0x2145,  0x2149,  0x214E,  0x214E,  0x2160,  0x2188,  0x2C00,  0x2CE4,  0x2CEB,  0x2CEE,  0x2CF2,  0x2CF3,
    0x2D00,  0x2D25,  0x2D27,  0x2D27,  0x2D2D,  0x2D2D,  0x2D30,  0x2D67,  0x2D6F,  0x2D6F,  0x2D80,  0x2D96,
    0x2DA0,  0x2DA6,  0x2DA8,  0x2DAE,  0x2DB0,  0x2DB6,  0x2DB8,  0x2DBE,  0x2DC0,  0x2DC6,  0x2DC8,  0x2DCE,
    0x2DD0,  0x2DD6,  0x2DD8,  0x2DDE,  0x3005,  0x3007,  0x3021,  0x3029,  0x3031,  0x3035,  0x3038,  0x303C,
    0x3041,  0x3096,  0x309B,  0x309F,  0x30A1,  0x30FA,  0x30FC,  0x30FF,  0x3105,  0x312F,  0x3131,  0x318E,
    0x31A0,  0x31BF,  0x31F0,  0x31FF,  0x3400,  0x4DBF,  0x4E00,  0xA48C,  0xA4D0,  0xA4FD,  0xA500,  0xA60C,
    0xA610,  0xA61F,  0xA62A,  0xA62B,  0xA640,  0xA66E,  0xA67F,  0xA69D,  0xA6A0,  0xA6EF,  0xA717,  0xA71F,
    0xA722,  0xA788,  0xA78B,  0xA7DC,  0xA7F1,  0xA801,  0xA803,  0xA805,  0xA807,  0xA80A,  0xA80C,  0xA822,
    0xA840,  0xA873,  0xA882,  0xA8B3,  0xA8F2,  0xA8F7,  0xA8FB,  0xA8FB,  0xA8FD,  0xA8FE,  0xA90A,  0xA925,
    0xA930,  0xA946,  0xA960,  0xA97C,  0xA984,  0xA9B2,  0xA9CF,  0xA9CF,  0xA9E0,  0xA9E4,  0xA9E6,  0xA9EF,
    0xA9FA,  0xA9FE,  0xAA00,  0xAA28,  0xAA40,  0xAA42,  0xAA44,  0xAA4B,  0xAA60,  0xAA76,  0xAA7A,  0xAA7A,
    0xAA7E,  0xAAAF,  0xAAB1,  0xAAB1,  0xAAB5,  0xAAB6,  0xAAB9,  0xAABD,  0xAAC0,  0xAAC0,  0xAAC2,  0xAAC2,
    0xAADB,  0xAADD,  0xAAE0,  0xAAEA,  0xAAF2,  0xAAF4,  0xAB01,  0xAB06,  0xAB09,  0xAB0E,  0xAB11,  0xAB16,
    0xAB20,  0xAB26,  0xAB28,  0xAB2E,  0xAB30,  0xAB5A,  0xAB5C,  0xAB69,  0xAB70,  0xABE2,  0xAC00,  0xD7A3,
    0xD7B0,  0xD7C6,  0xD7CB,  0xD7FB,  0xF900,  0xFA6D,  0xFA70,  0xFAD9,  0xFB00,  0xFB06,  0xFB13,  0xFB17,
    0xFB1D,  0xFB1D,  0xFB1F,  0xFB28,  0xFB2A,  0xFB36,  0xFB38,  0xFB3C,  0xFB3E,  0xFB3E,  0xFB40,  0xFB41,
    0xFB43,  0xFB44,  0xFB46,  0xFBB1,  0xFBD3,  0xFD3D,  0xFD50,  0xFD8F,  0xFD92,  0xFDC7,  0xFDF0,  0xFDFB,
    0xFE70,  0xFE74,  0xFE76,  0xFEFC,  0xFF21,  0xFF3A,  0xFF41,  0xFF5A,  0xFF66,  0xFFBE,  0xFFC2,  0xFFC7,
    0xFFCA,  0xFFCF,  0xFFD2,  0xFFD7,  0xFFDA,  0xFFDC,  0x10000, 0x1000B, 0x1000D, 0x10026, 0x10028, 0x1003A,
    0x1003C, 0x1003D, 0x1003F, 0x1004D, 0x10050, 0x1005D, 0x10080, 0x100FA, 0x10140, 0x10174, 0x10280, 0x1029C,
    0x102A0, 0x102D0, 0x10300, 0x1031F, 0x1032D, 0x1034A, 0x10350, 0x10375, 0x10380, 0x1039D, 0x103A0, 0x103C3,
    0x103C8, 0x103CF, 0x103D1, 0x103D5, 0x10400, 0x1049D, 0x104B0, 0x104D3, 0x104D8, 0x104FB, 0x10500, 0x10527,
    0x10530, 0x10563, 0x10570, 0x1057A, 0x1057C, 0x1058A, 0x1058C, 0x10592, 0x10594, 0x10595, 0x10597, 0x105A1,
    0x105A3, 0x105B1, 0x105B3, 0x105B9, 0x105BB, 0x105BC, 0x105C0, 0x105F3, 0x10600, 0x10736, 0x10740, 0x10755,
    0x10760, 0x10767, 0x10780, 0x10785, 0x10787, 0x107B0, 0x107B2, 0x107BA, 0x10800, 0x10805, 0x10808, 0x10808,
    0x1080A, 0x10835, 0x10837, 0x10838, 0x1083C, 0x1083C, 0x1083F, 0x10855, 0x10860, 0x10876, 0x10880, 0x1089E,
    0x108E0, 0x108F2, 0x108F4, 0x108F5, 0x10900, 0x10915, 0x10920, 0x10939, 0x10940, 0x10959, 0x10980, 0x109B7,
    0x109BE, 0x109BF, 0x10A00, 0x10A00, 0x10A10, 0x10A13, 0x10A15, 0x10A17, 0x10A19, 0x10A35, 0x10A60, 0x10A7C,
    0x10A80, 0x10A9C, 0x10AC0, 0x10AC7, 0x10AC9, 0x10AE4, 0x10B00, 0x10B35, 0x10B40, 0x10B55, 0x10B60, 0x10B72,
    0x10B80, 0x10B91, 0x10C00, 0x10C48, 0x10C80, 0x10CB2, 0x10CC0, 0x10CF2, 0x10D00, 0x10D23, 0x10D4A, 0x10D65,
    0x10D6F, 0x10D85, 0x10E80, 0x10EA9, 0x10EB0, 0x10EB1, 0x10EC2, 0x10EC7, 0x10F00, 0x10F1C, 0x10F27, 0x10F27,
    0x10F30, 0x10F45, 0x10F70, 0x10F81, 0x10FB0, 0x10FC4, 0x10FE0, 0x10FF6, 0x11003, 0x11037, 0x11071, 0x11072,
    0x11075, 0x11075, 0x11083, 0x110AF, 0x110D0, 0x110E8, 0x11103, 0x11126, 0x11144, 0x11144, 0x11147, 0x11147,
    0x11150, 0x11172, 0x11176, 0x11176, 0x11183, 0x111B2, 0x111C1, 0x111C4, 0x111DA, 0x111DA, 0x111DC, 0x111DC,
    0x11200, 0x11211, 0x11213, 0x1122B, 0x1123F, 0x11240, 0x11280, 0x11286, 0x11288, 0x11288, 0x1128A, 0x1128D,
    0x1128F, 0x1129D, 0x1129F, 0x112A8, 0x112B0, 0x112DE, 0x11305, 0x1130C, 0x1130F, 0x11310, 0x11313, 0x11328,
    0x1132A, 0x11330, 0x11332, 0x11333, 0x11335, 0x11339, 0x1133D, 0x1133D, 0x11350, 0x11350, 0x1135D, 0x11361,
    0x11380, 0x11389, 0x1138B, 0x1138B, 0x1138E, 0x1138E, 0x11390, 0x113B5, 0x113B7, 0x113B7, 0x113D1, 0x113D1,
    0x113D3, 0x113D3, 0x11400, 0x11434, 0x11447, 0x1144A, 0x1145F, 0x11461, 0x11480, 0x114AF, 0x114C4, 0x114C5,
    0x114C7, 0x114C7, 0x11580, 0x115AE, 0x115D8, 0x115DB, 0x11600, 0x1162F, 0x11644, 0x11644, 0x11680, 0x116AA,
    0x116B8, 0x116B8, 0x11700, 0x1171A, 0x11740, 0x11746, 0x11800, 0x1182B, 0x118A0, 0x118DF, 0x118FF, 0x11906,
    0x11909, 0x11909, 0x1190C, 0x11913, 0x11915, 0x11916, 0x11918, 0x1192F, 0x1193F, 0x1193F, 0x11941, 0x11941,
    0x119A0, 0x119A7, 0x119AA, 0x119D0, 0x119E1, 0x119E1, 0x119E3, 0x119E3, 0x11A00, 0x11A00, 0x11A0B, 0x11A32,
    0x11A3A, 0x11A3A, 0x11A50, 0x11A50, 0x11A5C, 0x11A89, 0x11A9D, 0x11A9D, 0x11AB0, 0x11AF8, 0x11BC0, 0x11BE0,
    0x11C00, 0x11C08, 0x11C0A, 0x11C2E, 0x11C40, 0x11C40, 0x11C72, 0x11C8F, 0x11D00, 0x11D06, 0x11D08, 0x11D09,
    0x11D0B, 0x11D30, 0x11D46, 0x11D46, 0x11D60, 0x11D65, 0x11D67, 0x11D68, 0x11D6A, 0x11D89, 0x11D98, 0x11D98,
    0x11DB0, 0x11DDB, 0x11EE0, 0x11EF2, 0x11F02, 0x11F02, 0x11F04, 0x11F10, 0x11F12, 0x11F33, 0x11FB0, 0x11FB0,
    0x12000, 0x12399, 0x12400, 0x1246E, 0x12480, 0x12543, 0x12F90, 0x12FF0, 0x13000, 0x1342F, 0x13441, 0x13446,
    0x13460, 0x143FA, 0x14400, 0x14646, 0x16100, 0x1611D, 0x16800, 0x16A38, 0x16A40, 0x16A5E, 0x16A70, 0x16ABE,
    0x16AD0, 0x16AED, 0x16B00, 0x16B2F, 0x16B40, 0x16B43, 0x16B63, 0x16B77, 0x16B7D, 0x16B8F, 0x16D40, 0x16D6C,
    0x16E40, 0x16E7F, 0x16EA0, 0x16EB8, 0x16EBB, 0x16ED3, 0x16F00, 0x16F4A, 0x16F50, 0x16F50, 0x16F93, 0x16F9F,
    0x16FE0, 0x16FE1, 0x16FE3, 0x16FE3, 0x16FF2, 0x16FF6, 0x17000, 0x18CD5, 0x18CFF, 0x18D1E, 0x18D80, 0x18DF2,
    0x1AFF0, 0x1AFF3, 0x1AFF5, 0x1AFFB, 0x1AFFD, 0x1AFFE, 0x1B000, 0x1B122, 0x1B132, 0x1B132, 0x1B150, 0x1B152,
    0x1B155, 0x1B155, 0x1B164, 0x1B167, 0x1B170, 0x1B2FB, 0x1BC00, 0x1BC6A, 0x1BC70, 0x1BC7C, 0x1BC80, 0x1BC88,
    0x1BC90, 0x1BC99, 0x1D400, 0x1D454, 0x1D456, 0x1D49C, 0x1D49E, 0x1D49F, 0x1D4A2, 0x1D4A2, 0x1D4A5, 0x1D4A6,
    0x1D4A9, 0x1D4AC, 0x1D4AE, 0x1D4B9, 0x1D4BB, 0x1D4BB, 0x1D4BD, 0x1D4C3, 0x1D4C5, 0x1D505, 0x1D507, 0x1D50A,
    0x1D50D, 0x1D514, 0x1D516, 0x1D51C, 0x1D51E, 0x1D539, 0x1D53B, 0x1D53E, 0x1D540, 0x1D544, 0x1D546, 0x1D546,
    0x1D54A, 0x1D550, 0x1D552, 0x1D6A5, 0x1D6A8, 0x1D6C0, 0x1D6C2, 0x1D6DA, 0x1D6DC, 0x1D6FA, 0x1D6FC, 0x1D714,
    0x1D716, 0x1D734, 0x1D736, 0x1D74E, 0x1D750, 0x1D76E, 0x1D770, 0x1D788, 0x1D78A, 0x1D7A8, 0x1D7AA, 0x1D7C2,
    0x1D7C4, 0x1D7CB, 0x1DF00, 0x1DF1E, 0x1DF25, 0x1DF2A, 0x1E030, 0x1E06D, 0x1E100, 0x1E12C, 0x1E137, 0x1E13D,
    0x1E14E, 0x1E14E, 0x1E290, 0x1E2AD, 0x1E2C0, 0x1E2EB, 0x1E4D0, 0x1E4EB, 0x1E5D0, 0x1E5ED, 0x1E5F0, 0x1E5F0,
    0x1E6C0, 0x1E6DE, 0x1E6E0, 0x1E6E2, 0x1E6E4, 0x1E6E5, 0x1E6E7, 0x1E6ED, 0x1E6F0, 0x1E6F4, 0x1E6FE, 0x1E6FF,
    0x1E7E0, 0x1E7E6, 0x1E7E8, 0x1E7EB, 0x1E7ED, 0x1E7EE, 0x1E7F0, 0x1E7FE, 0x1E800, 0x1E8C4, 0x1E900, 0x1E943,
    0x1E94B, 0x1E94B, 0x1EE00, 0x1EE03, 0x1EE05, 0x1EE1F, 0x1EE21, 0x1EE22, 0x1EE24, 0x1EE24, 0x1EE27, 0x1EE27,
    0x1EE29, 0x1EE32, 0x1EE34, 0x1EE37, 0x1EE39, 0x1EE39, 0x1EE3B, 0x1EE3B, 0x1EE42, 0x1EE42, 0x1EE47, 0x1EE47,
    0x1EE49, 0x1EE49, 0x1EE4B, 0x1EE4B, 0x1EE4D, 0x1EE4F, 0x1EE51, 0x1EE52, 0x1EE54, 0x1EE54, 0x1EE57, 0x1EE57,
    0x1EE59, 0x1EE59, 0x1EE5B, 0x1EE5B, 0x1EE5D, 0x1EE5D, 0x1EE5F, 0x1EE5F, 0x1EE61, 0x1EE62, 0x1EE64, 0x1EE64,
    0x1EE67, 0x1EE6A, 0x1EE6C, 0x1EE72, 0x1EE74, 0x1EE77, 0x1EE79, 0x1EE7C, 0x1EE7E, 0x1EE7E, 0x1EE80, 0x1EE89,
    0x1EE8B, 0x1EE9B, 0x1EEA1, 0x1EEA3, 0x1EEA5, 0x1EEA9, 0x1EEAB, 0x1EEBB, 0x20000, 0x2A6DF, 0x2A700, 0x2B81D,
    0x2B820, 0x2CEAD, 0x2CEB0, 0x2EBE0, 0x2EBF0, 0x2EE5D, 0x2F800, 0x2FA1D, 0x30000, 0x3134A, 0x31350, 0x33479,
};

const json5_identifier_part_extra_ranges = [_]u21{
    0x30,    0x39,    0x5F,    0x5F,    0xB7,    0xB7,    0x300,   0x36F,   0x387,   0x387,   0x483,   0x487,
    0x591,   0x5BD,   0x5BF,   0x5BF,   0x5C1,   0x5C2,   0x5C4,   0x5C5,   0x5C7,   0x5C7,   0x610,   0x61A,
    0x64B,   0x669,   0x670,   0x670,   0x6D6,   0x6DC,   0x6DF,   0x6E4,   0x6E7,   0x6E8,   0x6EA,   0x6ED,
    0x6F0,   0x6F9,   0x711,   0x711,   0x730,   0x74A,   0x7A6,   0x7B0,   0x7C0,   0x7C9,   0x7EB,   0x7F3,
    0x7FD,   0x7FD,   0x816,   0x819,   0x81B,   0x823,   0x825,   0x827,   0x829,   0x82D,   0x859,   0x85B,
    0x897,   0x89F,   0x8CA,   0x8E1,   0x8E3,   0x903,   0x93A,   0x93C,   0x93E,   0x94F,   0x951,   0x957,
    0x962,   0x963,   0x966,   0x96F,   0x981,   0x983,   0x9BC,   0x9BC,   0x9BE,   0x9C4,   0x9C7,   0x9C8,
    0x9CB,   0x9CD,   0x9D7,   0x9D7,   0x9E2,   0x9E3,   0x9E6,   0x9EF,   0x9FE,   0x9FE,   0xA01,   0xA03,
    0xA3C,   0xA3C,   0xA3E,   0xA42,   0xA47,   0xA48,   0xA4B,   0xA4D,   0xA51,   0xA51,   0xA66,   0xA71,
    0xA75,   0xA75,   0xA81,   0xA83,   0xABC,   0xABC,   0xABE,   0xAC5,   0xAC7,   0xAC9,   0xACB,   0xACD,
    0xAE2,   0xAE3,   0xAE6,   0xAEF,   0xAFA,   0xAFF,   0xB01,   0xB03,   0xB3C,   0xB3C,   0xB3E,   0xB44,
    0xB47,   0xB48,   0xB4B,   0xB4D,   0xB55,   0xB57,   0xB62,   0xB63,   0xB66,   0xB6F,   0xB82,   0xB82,
    0xBBE,   0xBC2,   0xBC6,   0xBC8,   0xBCA,   0xBCD,   0xBD7,   0xBD7,   0xBE6,   0xBEF,   0xC00,   0xC04,
    0xC3C,   0xC3C,   0xC3E,   0xC44,   0xC46,   0xC48,   0xC4A,   0xC4D,   0xC55,   0xC56,   0xC62,   0xC63,
    0xC66,   0xC6F,   0xC81,   0xC83,   0xCBC,   0xCBC,   0xCBE,   0xCC4,   0xCC6,   0xCC8,   0xCCA,   0xCCD,
    0xCD5,   0xCD6,   0xCE2,   0xCE3,   0xCE6,   0xCEF,   0xCF3,   0xCF3,   0xD00,   0xD03,   0xD3B,   0xD3C,
    0xD3E,   0xD44,   0xD46,   0xD48,   0xD4A,   0xD4D,   0xD57,   0xD57,   0xD62,   0xD63,   0xD66,   0xD6F,
    0xD81,   0xD83,   0xDCA,   0xDCA,   0xDCF,   0xDD4,   0xDD6,   0xDD6,   0xDD8,   0xDDF,   0xDE6,   0xDEF,
    0xDF2,   0xDF3,   0xE31,   0xE31,   0xE34,   0xE3A,   0xE47,   0xE4E,   0xE50,   0xE59,   0xEB1,   0xEB1,
    0xEB4,   0xEBC,   0xEC8,   0xECE,   0xED0,   0xED9,   0xF18,   0xF19,   0xF20,   0xF29,   0xF35,   0xF35,
    0xF37,   0xF37,   0xF39,   0xF39,   0xF3E,   0xF3F,   0xF71,   0xF84,   0xF86,   0xF87,   0xF8D,   0xF97,
    0xF99,   0xFBC,   0xFC6,   0xFC6,   0x102B,  0x103E,  0x1040,  0x1049,  0x1056,  0x1059,  0x105E,  0x1060,
    0x1062,  0x1064,  0x1067,  0x106D,  0x1071,  0x1074,  0x1082,  0x108D,  0x108F,  0x109D,  0x135D,  0x135F,
    0x1369,  0x1371,  0x1712,  0x1715,  0x1732,  0x1734,  0x1752,  0x1753,  0x1772,  0x1773,  0x17B4,  0x17D3,
    0x17DD,  0x17DD,  0x17E0,  0x17E9,  0x180B,  0x180D,  0x180F,  0x1819,  0x18A9,  0x18A9,  0x1920,  0x192B,
    0x1930,  0x193B,  0x1946,  0x194F,  0x19D0,  0x19DA,  0x1A17,  0x1A1B,  0x1A55,  0x1A5E,  0x1A60,  0x1A7C,
    0x1A7F,  0x1A89,  0x1A90,  0x1A99,  0x1AB0,  0x1ABD,  0x1ABF,  0x1ADD,  0x1AE0,  0x1AEB,  0x1B00,  0x1B04,
    0x1B34,  0x1B44,  0x1B50,  0x1B59,  0x1B6B,  0x1B73,  0x1B80,  0x1B82,  0x1BA1,  0x1BAD,  0x1BB0,  0x1BB9,
    0x1BE6,  0x1BF3,  0x1C24,  0x1C37,  0x1C40,  0x1C49,  0x1C50,  0x1C59,  0x1CD0,  0x1CD2,  0x1CD4,  0x1CE8,
    0x1CED,  0x1CED,  0x1CF4,  0x1CF4,  0x1CF7,  0x1CF9,  0x1DC0,  0x1DFF,  0x200C,  0x200D,  0x203F,  0x2040,
    0x2054,  0x2054,  0x20D0,  0x20DC,  0x20E1,  0x20E1,  0x20E5,  0x20F0,  0x2CEF,  0x2CF1,  0x2D7F,  0x2D7F,
    0x2DE0,  0x2DFF,  0x302A,  0x302F,  0x3099,  0x309A,  0x30FB,  0x30FB,  0xA620,  0xA629,  0xA66F,  0xA66F,
    0xA674,  0xA67D,  0xA69E,  0xA69F,  0xA6F0,  0xA6F1,  0xA802,  0xA802,  0xA806,  0xA806,  0xA80B,  0xA80B,
    0xA823,  0xA827,  0xA82C,  0xA82C,  0xA880,  0xA881,  0xA8B4,  0xA8C5,  0xA8D0,  0xA8D9,  0xA8E0,  0xA8F1,
    0xA8FF,  0xA909,  0xA926,  0xA92D,  0xA947,  0xA953,  0xA980,  0xA983,  0xA9B3,  0xA9C0,  0xA9D0,  0xA9D9,
    0xA9E5,  0xA9E5,  0xA9F0,  0xA9F9,  0xAA29,  0xAA36,  0xAA43,  0xAA43,  0xAA4C,  0xAA4D,  0xAA50,  0xAA59,
    0xAA7B,  0xAA7D,  0xAAB0,  0xAAB0,  0xAAB2,  0xAAB4,  0xAAB7,  0xAAB8,  0xAABE,  0xAABF,  0xAAC1,  0xAAC1,
    0xAAEB,  0xAAEF,  0xAAF5,  0xAAF6,  0xABE3,  0xABEA,  0xABEC,  0xABED,  0xABF0,  0xABF9,  0xFB1E,  0xFB1E,
    0xFE00,  0xFE0F,  0xFE20,  0xFE2F,  0xFE33,  0xFE34,  0xFE4D,  0xFE4F,  0xFF10,  0xFF19,  0xFF3F,  0xFF3F,
    0xFF65,  0xFF65,  0x101FD, 0x101FD, 0x102E0, 0x102E0, 0x10376, 0x1037A, 0x104A0, 0x104A9, 0x10A01, 0x10A03,
    0x10A05, 0x10A06, 0x10A0C, 0x10A0F, 0x10A38, 0x10A3A, 0x10A3F, 0x10A3F, 0x10AE5, 0x10AE6, 0x10D24, 0x10D27,
    0x10D30, 0x10D39, 0x10D40, 0x10D49, 0x10D69, 0x10D6D, 0x10EAB, 0x10EAC, 0x10EFA, 0x10EFF, 0x10F46, 0x10F50,
    0x10F82, 0x10F85, 0x11000, 0x11002, 0x11038, 0x11046, 0x11066, 0x11070, 0x11073, 0x11074, 0x1107F, 0x11082,
    0x110B0, 0x110BA, 0x110C2, 0x110C2, 0x110F0, 0x110F9, 0x11100, 0x11102, 0x11127, 0x11134, 0x11136, 0x1113F,
    0x11145, 0x11146, 0x11173, 0x11173, 0x11180, 0x11182, 0x111B3, 0x111C0, 0x111C9, 0x111CC, 0x111CE, 0x111D9,
    0x1122C, 0x11237, 0x1123E, 0x1123E, 0x11241, 0x11241, 0x112DF, 0x112EA, 0x112F0, 0x112F9, 0x11300, 0x11303,
    0x1133B, 0x1133C, 0x1133E, 0x11344, 0x11347, 0x11348, 0x1134B, 0x1134D, 0x11357, 0x11357, 0x11362, 0x11363,
    0x11366, 0x1136C, 0x11370, 0x11374, 0x113B8, 0x113C0, 0x113C2, 0x113C2, 0x113C5, 0x113C5, 0x113C7, 0x113CA,
    0x113CC, 0x113D0, 0x113D2, 0x113D2, 0x113E1, 0x113E2, 0x11435, 0x11446, 0x11450, 0x11459, 0x1145E, 0x1145E,
    0x114B0, 0x114C3, 0x114D0, 0x114D9, 0x115AF, 0x115B5, 0x115B8, 0x115C0, 0x115DC, 0x115DD, 0x11630, 0x11640,
    0x11650, 0x11659, 0x116AB, 0x116B7, 0x116C0, 0x116C9, 0x116D0, 0x116E3, 0x1171D, 0x1172B, 0x11730, 0x11739,
    0x1182C, 0x1183A, 0x118E0, 0x118E9, 0x11930, 0x11935, 0x11937, 0x11938, 0x1193B, 0x1193E, 0x11940, 0x11940,
    0x11942, 0x11943, 0x11950, 0x11959, 0x119D1, 0x119D7, 0x119DA, 0x119E0, 0x119E4, 0x119E4, 0x11A01, 0x11A0A,
    0x11A33, 0x11A39, 0x11A3B, 0x11A3E, 0x11A47, 0x11A47, 0x11A51, 0x11A5B, 0x11A8A, 0x11A99, 0x11B60, 0x11B67,
    0x11BF0, 0x11BF9, 0x11C2F, 0x11C36, 0x11C38, 0x11C3F, 0x11C50, 0x11C59, 0x11C92, 0x11CA7, 0x11CA9, 0x11CB6,
    0x11D31, 0x11D36, 0x11D3A, 0x11D3A, 0x11D3C, 0x11D3D, 0x11D3F, 0x11D45, 0x11D47, 0x11D47, 0x11D50, 0x11D59,
    0x11D8A, 0x11D8E, 0x11D90, 0x11D91, 0x11D93, 0x11D97, 0x11DA0, 0x11DA9, 0x11DE0, 0x11DE9, 0x11EF3, 0x11EF6,
    0x11F00, 0x11F01, 0x11F03, 0x11F03, 0x11F34, 0x11F3A, 0x11F3E, 0x11F42, 0x11F50, 0x11F5A, 0x13440, 0x13440,
    0x13447, 0x13455, 0x1611E, 0x16139, 0x16A60, 0x16A69, 0x16AC0, 0x16AC9, 0x16AF0, 0x16AF4, 0x16B30, 0x16B36,
    0x16B50, 0x16B59, 0x16D70, 0x16D79, 0x16F4F, 0x16F4F, 0x16F51, 0x16F87, 0x16F8F, 0x16F92, 0x16FE4, 0x16FE4,
    0x16FF0, 0x16FF1, 0x1BC9D, 0x1BC9E, 0x1CCF0, 0x1CCF9, 0x1CF00, 0x1CF2D, 0x1CF30, 0x1CF46, 0x1D165, 0x1D169,
    0x1D16D, 0x1D172, 0x1D17B, 0x1D182, 0x1D185, 0x1D18B, 0x1D1AA, 0x1D1AD, 0x1D242, 0x1D244, 0x1D7CE, 0x1D7FF,
    0x1DA00, 0x1DA36, 0x1DA3B, 0x1DA6C, 0x1DA75, 0x1DA75, 0x1DA84, 0x1DA84, 0x1DA9B, 0x1DA9F, 0x1DAA1, 0x1DAAF,
    0x1E000, 0x1E006, 0x1E008, 0x1E018, 0x1E01B, 0x1E021, 0x1E023, 0x1E024, 0x1E026, 0x1E02A, 0x1E08F, 0x1E08F,
    0x1E130, 0x1E136, 0x1E140, 0x1E149, 0x1E2AE, 0x1E2AE, 0x1E2EC, 0x1E2F9, 0x1E4EC, 0x1E4F9, 0x1E5EE, 0x1E5EF,
    0x1E5F1, 0x1E5FA, 0x1E6E3, 0x1E6E3, 0x1E6E6, 0x1E6E6, 0x1E6EE, 0x1E6EF, 0x1E6F5, 0x1E6F5, 0x1E8D0, 0x1E8D6,
    0x1E944, 0x1E94A, 0x1E950, 0x1E959, 0x1FBF0, 0x1FBF9, 0xE0100, 0xE01EF,
};

const Json5IdentifierCodepoint = struct {
    codepoint: u21,
    width: usize,
};

fn isJson5CodepointInRanges(codepoint: u21, ranges: []const u21) bool {
    var low: usize = 0;
    var high = ranges.len / 2;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const first = ranges[middle * 2];
        if (codepoint < first) {
            high = middle;
            continue;
        }
        const last = ranges[middle * 2 + 1];
        if (codepoint <= last) return true;
        low = middle + 1;
    }
    return false;
}

fn isJson5IdentifierStartCodepoint(codepoint: u21) bool {
    return codepoint == '$' or codepoint == '_' or
        isJson5CodepointInRanges(codepoint, &json5_identifier_start_ranges);
}

fn isJson5IdentifierPartCodepoint(codepoint: u21) bool {
    return codepoint == '$' or codepoint == '_' or
        isJson5CodepointInRanges(codepoint, &json5_identifier_start_ranges) or
        isJson5CodepointInRanges(codepoint, &json5_identifier_part_extra_ranges);
}

fn decodeJson5IdentifierCodepoint(
    input: []const u8,
    byte_offset: usize,
    failure_offset: *usize,
) Error!Json5IdentifierCodepoint {
    const width: usize = @intCast(std.unicode.utf8ByteSequenceLength(input[byte_offset]) catch {
        failure_offset.* = byte_offset;
        if (firstInvalidUtf8Byte(input[byte_offset .. byte_offset + 1])) |invalid_offset| {
            failure_offset.* = byte_offset + invalid_offset;
        }
        return error.InvalidUtf8;
    });
    if (input.len - byte_offset < width) {
        failure_offset.* = byte_offset;
        return error.InvalidUtf8;
    }

    const sequence = input[byte_offset .. byte_offset + width];
    if (firstInvalidUtf8Byte(sequence)) |invalid_offset| {
        failure_offset.* = byte_offset + invalid_offset;
        return error.InvalidUtf8;
    }
    const codepoint = std.unicode.utf8Decode(sequence) catch {
        failure_offset.* = byte_offset;
        return error.InvalidUtf8;
    };
    return .{ .codepoint = codepoint, .width = width };
}

fn parseJson5IdentifierEscape(
    input: []const u8,
    slash_offset: usize,
    failure_offset: *usize,
) Error!Json5IdentifierCodepoint {
    if (slash_offset + 1 >= input.len or input[slash_offset + 1] != 'u') {
        failure_offset.* = slash_offset;
        return error.InvalidEscape;
    }
    const first = try parseHexCodeUnit(input, slash_offset, failure_offset);
    if (std.unicode.utf16IsHighSurrogate(first)) {
        if (slash_offset + 7 >= input.len or
            input[slash_offset + 6] != '\\' or input[slash_offset + 7] != 'u')
        {
            failure_offset.* = slash_offset;
            return error.UnexpectedToken;
        }
        const second = try parseHexCodeUnit(input, slash_offset + 6, failure_offset);
        if (!std.unicode.utf16IsLowSurrogate(second)) {
            failure_offset.* = slash_offset + 6;
            return error.UnexpectedToken;
        }
        const pair = [_]u16{ first, second };
        // The preceding checks establish the decoder's surrogate-pair preconditions.
        const codepoint = std.unicode.utf16DecodeSurrogatePair(&pair) catch |err| {
            std.debug.panic(
                "validated UTF-16 surrogate pair failed to decode: {s}",
                .{@errorName(err)},
            );
        };
        return .{ .codepoint = codepoint, .width = 12 };
    }
    if (std.unicode.utf16IsLowSurrogate(first)) {
        failure_offset.* = slash_offset;
        return error.UnexpectedToken;
    }
    return .{ .codepoint = first, .width = 6 };
}

fn validateJson5Identifier(
    input: []const u8,
    start_offset: usize,
    failure_offset: *usize,
) Error!usize {
    if (start_offset >= input.len) {
        failure_offset.* = start_offset;
        return error.UnexpectedToken;
    }

    var index = start_offset;
    var is_start = true;
    while (index < input.len) {
        if (isAtomBoundaryAt(input, index, .json5)) {
            if (is_start) {
                failure_offset.* = index;
                return error.UnexpectedToken;
            }
            break;
        }

        const codepoint = if (input[index] == '\\')
            try parseJson5IdentifierEscape(input, index, failure_offset)
        else
            try decodeJson5IdentifierCodepoint(input, index, failure_offset);
        const valid = if (is_start)
            isJson5IdentifierStartCodepoint(codepoint.codepoint)
        else
            isJson5IdentifierPartCodepoint(codepoint.codepoint);
        if (!valid) {
            failure_offset.* = index;
            return error.UnexpectedToken;
        }
        index += codepoint.width;
        is_start = false;
    }
    return index;
}

fn isAtomBoundaryAt(input: []const u8, byte_offset: usize, dialect: Dialect) bool {
    if (byte_offset >= input.len) return true;
    if (isWhitespace(input[byte_offset])) return true;
    if (dialect == .json5 and json5WhitespaceWidth(input, byte_offset) != null) return true;
    if (dialect == .json5 and
        (input[byte_offset] == 0x0b or input[byte_offset] == 0x0C))
    {
        return true;
    }
    return switch (input[byte_offset]) {
        '}', ']', ':', ',' => true,
        '/' => dialect != .json and byte_offset + 1 < input.len and
            (input[byte_offset + 1] == '/' or input[byte_offset + 1] == '*'),
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

fn indexJson5ForTest(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var quote: u8 = 0;
    var escaped = false;
    var previous_in_atom = false;
    for (input, 0..) |byte, offset| {
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == quote) {
                quote = 0;
            }
            continue;
        }

        if (byte == '"' or byte == '\'') {
            quote = byte;
            previous_in_atom = false;
        } else if (isStructural(byte)) {
            result.indexes[result.count] = @intCast(offset);
            result.count += 1;
            previous_in_atom = false;
        } else if (isWhitespace(byte) or
            (byte == 0x0b or byte == 0x0c) or
            json5WhitespaceWidth(input, offset) != null or
            json5LineTerminatorWidth(input, offset) != null)
        {
            previous_in_atom = false;
        } else if (!previous_in_atom) {
            result.indexes[result.count] = @intCast(offset);
            result.count += 1;
            previous_in_atom = true;
        }
    }

    try result.finish(input.len);
    return result;
}

fn expectJson5Stage2Error(expected: Error, input: []const u8) !void {
    var structural_index = try indexJson5ForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    if (buildTape(testing.allocator, input, &structural_index, .json5)) |document_value| {
        var document = document_value;
        document.deinit(testing.allocator);
        return error.ExpectedStage2Error;
    } else |actual| {
        try testing.expectEqual(expected, actual);
    }
}

fn expectDialectStage2Diagnostic(
    expected: Error,
    input: []const u8,
    structural_index: *const stage1.StructuralIndex,
    dialect: Dialect,
) !Diagnostic {
    const result = try validate(input, structural_index, dialect);
    if (result) |diagnostic| {
        try testing.expectEqual(expected, diagnostic.err);
        return diagnostic;
    }
    return error.ExpectedStage2Error;
}

test "JSONC and JSON5 reject malformed UTF-8 in comments" {
    const jsonc_line = [_]u8{ '/', '/', 'o', 'k', 0xe2, '(', '\n', '{', '}' };
    var jsonc_line_index = try indexForTest(testing.allocator, &jsonc_line);
    defer jsonc_line_index.deinit(testing.allocator);
    const jsonc_line_diagnostic = try expectDialectStage2Diagnostic(
        error.InvalidUtf8,
        &jsonc_line,
        &jsonc_line_index,
        .jsonc,
    );
    try testing.expectEqual(@as(usize, 5), jsonc_line_diagnostic.byte_offset);

    const jsonc_block = [_]u8{
        '/', '*', 'o', 'k', 0xe2, 0x82, 'A', '*', '/', '{', '}',
    };
    var jsonc_block_index = try indexForTest(testing.allocator, &jsonc_block);
    defer jsonc_block_index.deinit(testing.allocator);
    const jsonc_block_diagnostic = try expectDialectStage2Diagnostic(
        error.InvalidUtf8,
        &jsonc_block,
        &jsonc_block_index,
        .jsonc,
    );
    try testing.expectEqual(@as(usize, 6), jsonc_block_diagnostic.byte_offset);

    const json5_line = [_]u8{ '/', '/', 'o', 'k', 0xe2, '(', '\n', '{', '}' };
    var json5_line_index = try indexForTest(testing.allocator, &json5_line);
    defer json5_line_index.deinit(testing.allocator);
    const json5_line_diagnostic = try expectDialectStage2Diagnostic(
        error.InvalidUtf8,
        &json5_line,
        &json5_line_index,
        .json5,
    );
    try testing.expectEqual(@as(usize, 5), json5_line_diagnostic.byte_offset);

    const json5_block = [_]u8{
        '/', '*', 'o', 'k', 0xe2, 0x82, 'A', '*', '/', '{', '}',
    };
    var json5_block_index = try indexForTest(testing.allocator, &json5_block);
    defer json5_block_index.deinit(testing.allocator);
    const json5_block_diagnostic = try expectDialectStage2Diagnostic(
        error.InvalidUtf8,
        &json5_block,
        &json5_block_index,
        .json5,
    );
    try testing.expectEqual(@as(usize, 6), json5_block_diagnostic.byte_offset);
}

test "JSON5 accepts raw line separators and rejects invalid identifier code points" {
    const raw_u2028 = [_]u8{ '[', '\'', 'a', 0xe2, 0x80, 0xa8, 'b', '\'', ']' };
    const raw_u2029 = [_]u8{ '[', '\'', 'a', 0xe2, 0x80, 0xa9, 'b', '\'', ']' };
    const raw_line_separators = [_][]const u8{ &raw_u2028, &raw_u2029 };
    for (raw_line_separators) |input| {
        var structural_index = try indexJson5ForTest(testing.allocator, input);
        defer structural_index.deinit(testing.allocator);
        var document = try buildTape(
            testing.allocator,
            input,
            &structural_index,
            .json5,
        );
        defer document.deinit(testing.allocator);

        var cursor = try document.root(input);
        try cursor.advance();
        try testing.expectEqualStrings(input[2 .. input.len - 2], try cursor.rawValue());
    }

    const raw_lf = [_]u8{ '[', '\'', 'a', '\n', 'b', '\'', ']' };
    const raw_cr = [_]u8{ '[', '\'', 'a', '\r', 'b', '\'', ']' };
    try expectJson5Stage2Error(error.InvalidEscape, &raw_lf);
    try expectJson5Stage2Error(error.InvalidEscape, &raw_cr);

    const raw_emoji = [_]u8{ '{', 0xf0, 0x9f, 0x98, 0x80, ':', '1', '}' };
    const raw_multiplication_sign = [_]u8{ '{', 0xc3, 0x97, ':', '1', '}' };
    const invalid_identifiers = [_][]const u8{
        &raw_emoji,
        &raw_multiplication_sign,
        "{\\u00D7:1}",
        "{a\\u00D7:1}",
        "{\\uD83D\\uDE00:1}",
    };
    for (invalid_identifiers) |input| {
        try expectJson5Stage2Error(error.UnexpectedToken, input);
    }
}

fn expectStage2Error(expected: Error, input: []const u8) !void {
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    if (buildTape(testing.allocator, input, &structural_index, .json)) |document_value| {
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

    const result = try validate(input, &structural_index, .json);
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
        .dialect = .json,
        .depth = .{ .entries = undefined },
    };
    try testing.expectEqual(
        @as(u24, 0),
        try validating_parser.encodeTapePayload(payload_too_large),
    );

    var tape: std.ArrayList(TapeWord) = .empty;
    const building_parser = Parser{
        .input = &.{},
        .indexes = &.{},
        .dialect = .json,
        .depth = .{ .entries = undefined },
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

    var document = try buildTape(testing.allocator, input, &structural_index, .json);
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

    var document = try buildTape(testing.allocator, input, &structural_index, .json);
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
    var document = try buildTape(testing.allocator, valid_input, &valid_index, .json);
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

    var document = try buildTape(testing.allocator, input, &structural_index, .json);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(@as(u24, 4), document.tape[0].payload);
    try testing.expectEqual(@as(u24, 5), document.tape[1].payload);
    try testing.expectEqual(@as(u24, 6), document.tape[2].payload);
    try testing.expectEqual(@as(u24, 12), document.tape[3].payload);
    try testing.expectEqual(@as(u24, 6), document.tape[4].payload);
}

test "JSON5 accepts Unicode and escaped IdentifierName keys" {
    const input = "{café:1,λ\\u0301:2,\\u03B4:3}";
    var structural_index = try indexJson5ForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var document = try buildTape(testing.allocator, input, &structural_index, .json5);
    defer document.deinit(testing.allocator);

    var cursor = try document.root(input);
    try cursor.advance();
    const raw_cafe = try cursor.rawValue();
    try testing.expectEqualStrings("café", raw_cafe);
    try testing.expect(raw_cafe.ptr == input.ptr + 1);
    try cursor.advance();
    try testing.expectEqualStrings("1", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("λ\\u0301", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("2", try cursor.rawValue());
    try cursor.advance();
    try testing.expectEqualStrings("\\u03B4", try cursor.rawValue());
}

test "JSON5 accepts escaped Unicode line continuations" {
    const inputs = [_][]const u8{
        "['a\\\xE2\x80\xA8b']",
        "['a\\\xE2\x80\xA9b']",
    };
    for (inputs) |input| {
        var structural_index = try indexJson5ForTest(testing.allocator, input);
        defer structural_index.deinit(testing.allocator);
        var document = try buildTape(testing.allocator, input, &structural_index, .json5);
        document.deinit(testing.allocator);
    }
}

test "TapeCursor rejects unquoted source for forged JSON5 string words" {
    const input = "foo";
    var tape = [_]TapeWord{.{
        .kind = @intFromEnum(TapeKind.string),
        .payload = @intCast(input.len),
        .offset = 0,
    }};
    const document = Document{ .tape = tape[0..], .dialect = .json5 };
    const cursor = try document.root(input);
    try testing.expectError(error.InvalidSource, cursor.rawValue());
}

test "buildTape accepts lone UTF-16 surrogate escape syntax" {
    const input = "[\"\\uD800\",\"\\uDD1E\"]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var document = try buildTape(testing.allocator, input, &structural_index, .json);
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

    var document = try buildTape(testing.allocator, input, &structural_index, .json);
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

        var document = try buildTape(testing.allocator, input, &structural_index, .json);
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

    var document = try buildTape(testing.allocator, input, &structural_index, .json);
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
    const document = Document{ .tape = tape[0..], .dialect = .json };
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
        const document = Document{ .tape = tape[0..], .dialect = .json };
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
    const invalid_kind_document = Document{ .tape = invalid_kind_tape[0..], .dialect = .json };
    try testing.expectError(error.InvalidTapeKind, invalid_kind_document.root("0"));

    var wrong_end_tape = [_]TapeWord{
        .{ .kind = @intFromEnum(TapeKind.array_start), .payload = 0, .offset = 0 },
        .{ .kind = @intFromEnum(TapeKind.object_end), .payload = 0, .offset = 1 },
    };
    const wrong_end_document = Document{ .tape = wrong_end_tape[0..], .dialect = .json };
    var wrong_end_cursor = try wrong_end_document.root("[]");
    try testing.expectError(error.InvalidTapeOrder, wrong_end_cursor.skipValue());

    var unclosed_tape = [_]TapeWord{
        .{ .kind = @intFromEnum(TapeKind.array_start), .payload = 0, .offset = 0 },
    };
    const unclosed_document = Document{ .tape = unclosed_tape[0..], .dialect = .json };
    var unclosed_cursor = try unclosed_document.root("[");
    try testing.expectError(error.TapeOutOfBounds, unclosed_cursor.skipValue());

    var wrong_count_tape = [_]TapeWord{
        .{ .kind = @intFromEnum(TapeKind.array_start), .payload = 2, .offset = 0 },
        .{ .kind = @intFromEnum(TapeKind.number), .payload = 0, .offset = 1 },
        .{ .kind = @intFromEnum(TapeKind.array_end), .payload = 0, .offset = 2 },
    };
    const wrong_count_document = Document{ .tape = wrong_count_tape[0..], .dialect = .json };
    var wrong_count_cursor = try wrong_count_document.root("[0]");
    try testing.expectError(error.InvalidTapeOrder, wrong_count_cursor.skipValue());

    var bad_start_tape = [_]TapeWord{
        .{ .kind = @intFromEnum(TapeKind.array_start), .payload = 0, .offset = 0 },
        .{ .kind = @intFromEnum(TapeKind.array_end), .payload = 2, .offset = 1 },
    };
    const bad_start_document = Document{ .tape = bad_start_tape[0..], .dialect = .json };
    var bad_start_cursor = try bad_start_document.root("[]");
    try bad_start_cursor.advance();
    try testing.expectError(error.TapeOutOfBounds, bad_start_cursor.matchingStart());

    var string_tape = [_]TapeWord{.{
        .kind = @intFromEnum(TapeKind.string),
        .payload = 4,
        .offset = 0,
    }};
    const string_document = Document{ .tape = string_tape[0..], .dialect = .json };
    var string_cursor = try string_document.root("\"x\"");
    try testing.expectError(error.SourceOutOfBounds, string_cursor.rawValue());

    var number_tape = [_]TapeWord{.{
        .kind = @intFromEnum(TapeKind.number),
        .payload = 0,
        .offset = 0,
    }};
    const number_document = Document{ .tape = number_tape[0..], .dialect = .json };
    var number_cursor = try number_document.root("0");
    try testing.expectError(error.TypeMismatch, number_cursor.containerCount());
}
