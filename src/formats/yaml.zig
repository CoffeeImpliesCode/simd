const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");

const testing = std.testing;
const max_u24: usize = std.math.maxInt(u24);

/// The restricted YAML token stream emitted by Stage 1 and retained by Stage 2.
///
/// Block containers use the first source byte of the container and the matching
/// end token uses the last source byte consumed by the container. Scalar and key
/// tokens carry their source span length in the structural index and tape.
pub const YamlTokenKind = enum(u8) {
    document_start,
    document_end,
    mapping_start,
    mapping_end,
    sequence_start,
    sequence_end,
    key,
    scalar,
};

/// YAML errors are deliberately split from allocator and capacity errors. An
/// Invalid input is malformed in the selected profile. Unsupported input is a
/// recognizable YAML feature outside yaml-basic-1.2.2.
pub const YamlError = error{
    Invalid,
    Unsupported,
};

pub const YamlIndexError = std.mem.Allocator.Error || YamlError || error{
    CapacityOverflow,
    InputTooLarge,
    TapeTooLarge,
};

pub const YamlValidationError = std.mem.Allocator.Error || error{
    CapacityOverflow,
    InputTooLarge,
    TapeTooLarge,
};

pub const YamlBuildError = std.mem.Allocator.Error || YamlError || error{
    CapacityOverflow,
    InputTooLarge,
    TapeTooLarge,
};

pub const YamlDiagnosticKind = enum(u8) {
    syntax,
    unsupported,
    invalid_index,
};

/// A source-backed first-failure diagnostic. `snippet` borrows `input`.
pub const YamlDiagnostic = struct {
    err: YamlError,
    kind: YamlDiagnosticKind,
    byte_offset: usize,
    line: u32,
    column: u32,
    snippet: []const u8,
    snippet_start: usize,
};

/// A source span retained by a structural entry. The source bytes remain
/// caller-owned; only offsets and lengths are copied into the index and tape.
pub const YamlSourceSpan = struct {
    start: u32,
    length: u32,
};

/// A format-local structural index. The index owns all three arrays.
pub const YamlStructuralIndex = struct {
    indexes: []u32,
    kinds: []YamlTokenKind,
    lengths: []u32,
    count: usize,

    pub fn deinit(self: *YamlStructuralIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.indexes);
        allocator.free(self.kinds);
        allocator.free(self.lengths);
        self.* = undefined;
    }
    pub fn slice(self: *const YamlStructuralIndex) []const u32 {
        return self.indexes[0..self.count];
    }
    pub fn sourceSpan(self: *const YamlStructuralIndex, token_index: usize) ?YamlSourceSpan {
        if (token_index >= self.count) return null;
        return .{
            .start = self.indexes[token_index],
            .length = self.lengths[token_index],
        };
    }
};

/// A compact validated YAML token. Scalar and key payloads are source lengths;
/// container payloads are zero and are interpreted by token kind.
pub const YamlTapeWord = packed struct(u64) {
    kind: u8,
    payload: u24,
    offset: u32,

    pub fn tapeKind(self: YamlTapeWord) YamlTokenKind {
        return @enumFromInt(self.kind);
    }
    pub fn sourceLength(self: YamlTapeWord) usize {
        return @intCast(self.payload);
    }
};

comptime {
    std.debug.assert(@bitSizeOf(YamlTapeWord) == 64);
    std.debug.assert(@sizeOf(YamlTapeWord) == 8);
}

/// An owned validated YAML tape. `source` is borrowed from the caller.
pub const YamlDocument = struct {
    tape: []YamlTapeWord,
    source: []const u8,

    pub fn deinit(self: *YamlDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.tape);
        self.* = undefined;
    }

    pub fn root(self: *const YamlDocument, input: []const u8) YamlNavigationError!YamlCursor {
        if (self.tape.len == 0) return error.TapeOutOfBounds;
        if (input.len < self.source.len and self.source.len != 0) {
            return error.SourceOutOfBounds;
        }
        return .{ .tape = self.tape, .input = input };
    }
};

pub const YamlNavigationError = error{
    TapeOutOfBounds,
    SourceOutOfBounds,
    InvalidTapeKind,
    TypeMismatch,
};

/// A zero-allocation cursor over an owned YAML tape and borrowed source.
pub const YamlCursor = struct {
    tape: []const YamlTapeWord,
    input: []const u8,
    position_index: usize = 0,

    pub fn peek(self: *const YamlCursor) YamlNavigationError!YamlTapeWord {
        if (self.position_index >= self.tape.len) return error.TapeOutOfBounds;
        return self.tape[self.position_index];
    }

    pub fn advance(self: *YamlCursor) YamlNavigationError!void {
        _ = try self.peek();
        self.position_index += 1;
    }

    pub fn position(self: *const YamlCursor) usize {
        return self.position_index;
    }

    pub fn span(self: *const YamlCursor) YamlNavigationError![]const u8 {
        const word = try self.peek();
        const kind = word.tapeKind();
        if (kind != .key and kind != .scalar) return error.TypeMismatch;
        const start: usize = @intCast(word.offset);
        const length: usize = @intCast(word.payload);
        const end = std.math.add(usize, start, length) catch return error.SourceOutOfBounds;
        if (end > self.input.len) return error.SourceOutOfBounds;
        return self.input[start..end];
    }
};

const Failure = struct {
    err: YamlError,
    kind: YamlDiagnosticKind,
    offset: usize,
};

const Line = struct {
    start: usize,
    content_start: usize,
    content_end: usize,
    next: usize,
    indent: usize,
};

const ParseContext = enum {
    block_value,
    block_key,
    flow_key,
    flow_value,
};

const YamlParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    lines: []const Line,
    index: *YamlStructuralIndex,
    failure: *?Failure,
    line_cursor: usize = 0,

    const Self = @This();

    fn fail(self: *Self, err: YamlError, kind: YamlDiagnosticKind, offset: usize) YamlError {
        if (self.failure.* == null) {
            self.failure.* = .{
                .err = err,
                .kind = kind,
                .offset = @min(offset, self.input.len),
            };
        }
        return err;
    }

    fn emit(
        self: *Self,
        kind: YamlTokenKind,
        offset: usize,
        length: usize,
    ) YamlIndexError!void {
        if (offset > self.input.len) {
            return self.fail(error.Invalid, .invalid_index, self.input.len);
        }
        if (length > std.math.maxInt(u32)) {
            return self.fail(error.Invalid, .invalid_index, offset);
        }
        if (length > max_u24) {
            return error.TapeTooLarge;
        }
        if (self.index.count >= self.index.indexes.len - stage1_sentinel_count) {
            return error.CapacityOverflow;
        }
        self.index.indexes[self.index.count] = @intCast(offset);
        self.index.kinds[self.index.count] = kind;
        self.index.lengths[self.index.count] = @intCast(length);
        self.index.count += 1;
    }

    fn nextMeaningful(self: *const Self, from: usize) ?usize {
        var cursor = from;
        while (cursor < self.lines.len) : (cursor += 1) {
            const line = self.lines[cursor];
            if (line.content_start >= line.content_end) continue;
            if (self.input[line.content_start] == '#') continue;
            return cursor;
        }
        return null;
    }

    fn parseDocument(self: *Self) YamlIndexError!void {
        const first = self.nextMeaningful(0) orelse {
            return self.fail(error.Invalid, .syntax, self.input.len);
        };

        var has_end_marker = false;
        var root_indent: usize = self.lines[first].indent;
        var first_content = first;

        if (self.isDocumentMarker(first, "---")) {
            try self.emit(.document_start, self.lines[first].content_start, 3);
            first_content = self.nextMeaningful(first + 1) orelse {
                return self.fail(error.Invalid, .syntax, self.lines[first].next);
            };
            if (self.isDocumentMarker(first_content, "---")) {
                return self.fail(error.Unsupported, .unsupported, self.lines[first_content].content_start);
            }
            if (self.isDocumentMarker(first_content, "...")) {
                return self.fail(error.Invalid, .syntax, self.lines[first_content].content_start);
            }
            if (self.isDirective(first_content)) {
                return self.fail(error.Unsupported, .unsupported, self.lines[first_content].content_start);
            }
            root_indent = self.lines[first_content].indent;
        } else if (self.isDocumentMarker(first, "...")) {
            return self.fail(error.Invalid, .syntax, self.lines[first].content_start);
        }

        if (self.isDirective(first_content)) {
            return self.fail(error.Unsupported, .unsupported, self.lines[first_content].content_start);
        }

        self.line_cursor = first_content;
        try self.parseBlock(root_indent);

        while (self.nextMeaningful(self.line_cursor)) |next_index| {
            const line = self.lines[next_index];
            if (self.isDocumentMarker(next_index, "...")) {
                if (has_end_marker) {
                    return self.fail(error.Unsupported, .unsupported, line.content_start);
                }
                has_end_marker = true;
                try self.emit(.document_end, line.content_start, 3);
                self.line_cursor = next_index + 1;
                break;
            }
            if (self.isDocumentMarker(next_index, "---")) {
                return self.fail(error.Unsupported, .unsupported, line.content_start);
            }
            if (self.isDirective(next_index)) {
                return self.fail(error.Unsupported, .unsupported, line.content_start);
            }
            if (line.indent > root_indent) {
                return self.fail(error.Unsupported, .unsupported, line.content_start);
            }
            return self.fail(error.Invalid, .syntax, line.content_start);
        }

        if (has_end_marker) {
            if (self.nextMeaningful(self.line_cursor)) |remaining| {
                return self.fail(error.Unsupported, .unsupported, self.lines[remaining].content_start);
            }
        }
    }

    fn isDirective(self: *const Self, line_index: usize) bool {
        const line = self.lines[line_index];
        return line.indent == 0 and line.content_start < line.content_end and
            self.input[line.content_start] == '%';
    }

    fn isDocumentMarker(self: *const Self, line_index: usize, marker: []const u8) bool {
        const line = self.lines[line_index];
        if (line.indent != 0) return false;
        const start = line.content_start;
        const end = trimCommentEnd(self.input, start, line.content_end);
        if (end - start < marker.len or
            !std.mem.eql(u8, self.input[start..][0..marker.len], marker))
        {
            return false;
        }
        if (end == start + marker.len) return true;
        const tail = self.input[start + marker.len .. end];
        for (tail) |byte| {
            if (byte != ' ') return false;
        }
        return true;
    }

    fn parseBlock(self: *Self, indent: usize) YamlIndexError!void {
        const current = self.nextMeaningful(self.line_cursor) orelse {
            return self.fail(error.Invalid, .syntax, self.input.len);
        };
        const line = self.lines[current];
        if (line.indent < indent) {
            return self.fail(error.Invalid, .syntax, line.content_start);
        }
        if (line.indent > indent) {
            return self.fail(error.Unsupported, .unsupported, line.content_start);
        }
        self.line_cursor = current;

        if (isSequenceEntry(self.input, line.content_start, line.content_end)) {
            return self.parseBlockSequence(indent);
        }
        if (findBlockColon(self.input, line.content_start, line.content_end) != null) {
            return self.parseBlockMapping(indent);
        }
        if (startsUnsupportedConstruct(self.input, line.content_start, line.content_end)) {
            return self.fail(error.Unsupported, .unsupported, line.content_start);
        }
        try self.parseInlineValue(
            line.content_start,
            trimCommentEnd(self.input, line.content_start, line.content_end),
            .block_value,
        );
        self.line_cursor = current + 1;
    }

    fn parseBlockMapping(self: *Self, indent: usize) YamlIndexError!void {
        const first = self.nextMeaningful(self.line_cursor) orelse {
            return self.fail(error.Invalid, .syntax, self.input.len);
        };
        const start_offset = self.lines[first].content_start;
        try self.emit(.mapping_start, start_offset, 0);
        var end_offset = start_offset;

        while (self.nextMeaningful(self.line_cursor)) |current| {
            const line = self.lines[current];
            if (self.isDocumentMarker(current, "---") or self.isDocumentMarker(current, "...")) {
                break;
            }
            if (line.indent < indent) break;
            if (line.indent > indent) {
                return self.fail(error.Unsupported, .unsupported, line.content_start);
            }
            if (isSequenceEntry(self.input, line.content_start, line.content_end)) {
                return self.fail(error.Invalid, .syntax, line.content_start);
            }
            const visible_end = trimCommentEnd(self.input, line.content_start, line.content_end);
            const colon = findBlockColon(self.input, line.content_start, visible_end) orelse {
                return self.fail(error.Invalid, .syntax, line.content_start);
            };
            if (colon == line.content_start) {
                return self.fail(error.Invalid, .syntax, colon);
            }

            const key_end = trimSpaces(self.input, line.content_start, colon);
            try self.parseInlineValue(line.content_start, key_end, .block_key);
            self.index.kinds[self.index.count - 1] = .key;

            var value_start = colon + 1;
            while (value_start < visible_end and self.input[value_start] == ' ') : (value_start += 1) {}
            if (value_start < visible_end) {
                if (startsUnsupportedConstruct(self.input, value_start, visible_end)) {
                    return self.fail(error.Unsupported, .unsupported, value_start);
                }
                if (isSequenceEntry(self.input, value_start, visible_end)) {
                    return self.fail(error.Unsupported, .unsupported, value_start);
                }
                try self.parseInlineValue(value_start, visible_end, .block_value);
                self.line_cursor = current + 1;
                if (self.nextMeaningful(self.line_cursor)) |next_index| {
                    if (self.lines[next_index].indent > indent) {
                        return self.fail(error.Unsupported, .unsupported, self.lines[next_index].content_start);
                    }
                }
            } else {
                self.line_cursor = current + 1;
                if (self.nextMeaningful(self.line_cursor)) |next_index| {
                    const next_line = self.lines[next_index];
                    if (next_line.indent > indent) {
                        self.line_cursor = next_index;
                        try self.parseBlock(next_line.indent);
                    } else {
                        try self.emit(.scalar, colon + 1, 0);
                    }
                } else {
                    try self.emit(.scalar, colon + 1, 0);
                }
            }
            end_offset = line.content_end;
        }

        try self.emit(.mapping_end, end_offset, 0);
    }

    fn parseBlockSequence(self: *Self, indent: usize) YamlIndexError!void {
        const first = self.nextMeaningful(self.line_cursor) orelse {
            return self.fail(error.Invalid, .syntax, self.input.len);
        };
        const start_offset = self.lines[first].content_start;
        try self.emit(.sequence_start, start_offset, 0);
        var end_offset = start_offset;

        while (self.nextMeaningful(self.line_cursor)) |current| {
            const line = self.lines[current];
            if (self.isDocumentMarker(current, "---") or self.isDocumentMarker(current, "...")) {
                break;
            }
            if (line.indent < indent) break;
            if (line.indent > indent) {
                return self.fail(error.Unsupported, .unsupported, line.content_start);
            }
            if (!isSequenceEntry(self.input, line.content_start, line.content_end)) break;

            var value_start = line.content_start + 1;
            while (value_start < line.content_end and self.input[value_start] == ' ') : (value_start += 1) {}
            const visible_end = trimCommentEnd(self.input, value_start, line.content_end);
            if (value_start < visible_end) {
                if (findBlockColon(self.input, value_start, visible_end) != null) {
                    return self.fail(error.Unsupported, .unsupported, value_start);
                }
                if (startsUnsupportedConstruct(self.input, value_start, visible_end)) {
                    return self.fail(error.Unsupported, .unsupported, value_start);
                }
                try self.parseInlineValue(value_start, visible_end, .block_value);
                self.line_cursor = current + 1;
                if (self.nextMeaningful(self.line_cursor)) |next_index| {
                    if (self.lines[next_index].indent > indent) {
                        return self.fail(error.Unsupported, .unsupported, self.lines[next_index].content_start);
                    }
                }
            } else {
                self.line_cursor = current + 1;
                if (self.nextMeaningful(self.line_cursor)) |next_index| {
                    const next_line = self.lines[next_index];
                    if (next_line.indent > indent) {
                        self.line_cursor = next_index;
                        try self.parseBlock(next_line.indent);
                    } else {
                        try self.emit(.scalar, line.content_end, 0);
                    }
                } else {
                    try self.emit(.scalar, line.content_end, 0);
                }
            }
            end_offset = line.content_end;
        }

        try self.emit(.sequence_end, end_offset, 0);
    }

    fn parseInlineValue(
        self: *Self,
        start: usize,
        end: usize,
        context: ParseContext,
    ) YamlIndexError!void {
        if (start > end or end > self.input.len) {
            return self.fail(error.Invalid, .syntax, start);
        }
        if (start == end) {
            try self.emit(.scalar, start, 0);
            return;
        }
        var inline_parser = InlineParser{
            .owner = self,
            .start = start,
            .pos = start,
            .end = end,
            .context = context,
        };
        try inline_parser.parseValue();
        inline_parser.skipSpaces();
        if (inline_parser.pos != end) {
            return self.fail(error.Invalid, .syntax, inline_parser.pos);
        }
    }
};

const InlineParser = struct {
    owner: *YamlParser,
    start: usize,
    pos: usize,
    end: usize,
    context: ParseContext,

    const Self = @This();

    fn fail(self: *Self, err: YamlError, kind: YamlDiagnosticKind, offset: usize) YamlError {
        return self.owner.fail(err, kind, offset);
    }

    fn skipSpaces(self: *Self) void {
        while (self.pos < self.end and self.owner.input[self.pos] == ' ') : (self.pos += 1) {}
    }
    fn failUnclosed(self: *Self, offset: usize) YamlError {
        if (self.end < self.owner.input.len and
            (self.owner.input[self.end] == '\n' or self.owner.input[self.end] == '\r'))
        {
            return self.fail(error.Unsupported, .unsupported, offset);
        }
        return self.fail(error.Invalid, .syntax, offset);
    }

    fn parseValue(self: *Self) YamlIndexError!void {
        self.skipSpaces();
        if (self.pos >= self.end) {
            return self.fail(error.Invalid, .syntax, self.pos);
        }
        switch (self.owner.input[self.pos]) {
            '[' => {
                if (self.context == .block_key or self.context == .flow_key) {
                    return self.fail(error.Unsupported, .unsupported, self.pos);
                }
                try self.parseFlowSequence();
            },
            '{' => {
                if (self.context == .block_key or self.context == .flow_key) {
                    return self.fail(error.Unsupported, .unsupported, self.pos);
                }
                try self.parseFlowMapping();
            },
            '\'', '"' => try self.parseQuoted(.scalar),
            else => {
                if (startsUnsupportedConstruct(self.owner.input, self.pos, self.end)) {
                    return self.fail(error.Unsupported, .unsupported, self.pos);
                }
                try self.parsePlain(if (self.context == .block_key or self.context == .flow_key) .key else .scalar);
            },
        }
    }

    fn parseFlowSequence(self: *Self) YamlIndexError!void {
        const open = self.pos;
        self.pos += 1;
        try self.owner.emit(.sequence_start, open, 0);
        self.skipSpaces();
        if (self.pos < self.end and self.owner.input[self.pos] == ']') {
            const close = self.pos;
            self.pos += 1;
            try self.owner.emit(.sequence_end, close, 0);
            return;
        }

        while (true) {
            if (self.pos >= self.end) {
                return self.failUnclosed(open);
            }
            const previous_context = self.context;
            self.context = .flow_value;
            try self.parseValue();
            self.context = previous_context;
            self.skipSpaces();
            if (self.pos >= self.end) {
                return self.failUnclosed(open);
            }
            switch (self.owner.input[self.pos]) {
                ',' => {
                    self.pos += 1;
                    self.skipSpaces();
                    if (self.pos >= self.end or self.owner.input[self.pos] == ']') {
                        return self.fail(error.Invalid, .syntax, self.pos);
                    }
                },
                ']' => {
                    const close = self.pos;
                    self.pos += 1;
                    try self.owner.emit(.sequence_end, close, 0);
                    return;
                },
                else => return self.fail(error.Invalid, .syntax, self.pos),
            }
        }
    }

    fn parseFlowMapping(self: *Self) YamlIndexError!void {
        const open = self.pos;
        self.pos += 1;
        try self.owner.emit(.mapping_start, open, 0);
        self.skipSpaces();
        if (self.pos < self.end and self.owner.input[self.pos] == '}') {
            const close = self.pos;
            self.pos += 1;
            try self.owner.emit(.mapping_end, close, 0);
            return;
        }

        while (true) {
            if (self.pos >= self.end) {
                return self.failUnclosed(open);
            }
            self.context = .flow_key;
            switch (self.owner.input[self.pos]) {
                '\'', '"' => try self.parseQuoted(.key),
                '[', '{' => return self.fail(error.Unsupported, .unsupported, self.pos),
                else => try self.parsePlain(.key),
            }
            self.skipSpaces();
            if (self.pos >= self.end or self.owner.input[self.pos] != ':') {
                return self.fail(error.Invalid, .syntax, self.pos);
            }
            self.pos += 1;
            self.skipSpaces();
            if (self.pos >= self.end or self.owner.input[self.pos] == ',' or self.owner.input[self.pos] == '}') {
                try self.owner.emit(.scalar, self.pos, 0);
            } else {
                self.context = .flow_value;
                try self.parseValue();
            }
            self.skipSpaces();
            if (self.pos >= self.end) {
                return self.failUnclosed(open);
            }
            switch (self.owner.input[self.pos]) {
                ',' => {
                    self.pos += 1;
                    self.skipSpaces();
                    if (self.pos >= self.end or self.owner.input[self.pos] == '}') {
                        return self.fail(error.Invalid, .syntax, self.pos);
                    }
                },
                '}' => {
                    const close = self.pos;
                    self.pos += 1;
                    try self.owner.emit(.mapping_end, close, 0);
                    return;
                },
                else => return self.fail(error.Invalid, .syntax, self.pos),
            }
        }
    }

    fn parseQuoted(self: *Self, kind: YamlTokenKind) YamlIndexError!void {
        const quote = self.owner.input[self.pos];
        const start = self.pos;
        self.pos += 1;
        if (quote == '\'') {
            while (self.pos < self.end) {
                const byte = self.owner.input[self.pos];
                if (byte == '\'') {
                    if (self.pos + 1 < self.end and self.owner.input[self.pos + 1] == '\'') {
                        self.pos += 2;
                        continue;
                    }
                    self.pos += 1;
                    try self.owner.emit(kind, start, self.pos - start);
                    return;
                }
                self.pos += 1;
            }
            return self.failUnclosed(start);
        }

        while (self.pos < self.end) {
            const byte = self.owner.input[self.pos];
            if (byte == '"') {
                self.pos += 1;
                try self.owner.emit(kind, start, self.pos - start);
                return;
            }
            if (byte == '\\') {
                const escape_offset = self.pos;
                self.pos += 1;
                if (self.pos >= self.end) return self.failUnclosed(escape_offset);
                const escape = self.owner.input[self.pos];
                switch (escape) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => self.pos += 1,
                    'u' => {
                        self.pos += 1;
                        if (self.pos < self.end and self.owner.input[self.pos] == '{') {
                            return self.fail(error.Unsupported, .unsupported, escape_offset);
                        }
                        if (self.end - self.pos < 4) {
                            return self.fail(error.Invalid, .syntax, escape_offset);
                        }
                        var hex_count: usize = 0;
                        while (hex_count < 4) : (hex_count += 1) {
                            if (!isHex(self.owner.input[self.pos + hex_count])) {
                                return self.fail(error.Invalid, .syntax, self.pos + hex_count);
                            }
                        }
                        self.pos += 4;
                    },
                    else => return self.fail(error.Unsupported, .unsupported, escape_offset),
                }
            } else {
                self.pos += 1;
            }
        }
        return self.failUnclosed(start);
    }

    fn parsePlain(self: *Self, kind: YamlTokenKind) YamlIndexError!void {
        const start = self.pos;
        while (self.pos < self.end) {
            const byte = self.owner.input[self.pos];
            if (self.context == .flow_key and byte == ':') break;
            if ((self.context == .flow_value or self.context == .flow_key) and
                (byte == ',' or byte == ']' or byte == '}')) break;
            if (byte == ':' and self.context != .flow_key and
                (self.pos + 1 == self.end or self.owner.input[self.pos + 1] == ' ' or
                    self.owner.input[self.pos + 1] == '#'))
            {
                return self.fail(error.Unsupported, .unsupported, self.pos);
            }
            if (byte == '#' and self.pos > start and self.owner.input[self.pos - 1] == ' ') break;
            if (byte == '\t') return self.fail(error.Invalid, .syntax, self.pos);
            if (byte == '&' or byte == '*' or byte == '!') {
                if (self.pos == start or self.owner.input[self.pos - 1] == ' ') {
                    return self.fail(error.Unsupported, .unsupported, self.pos);
                }
            }
            self.pos += 1;
        }
        const value_end = trimSpaces(self.owner.input, start, self.pos);
        if (value_end == start) return self.fail(error.Invalid, .syntax, start);
        try self.owner.emit(kind, start, value_end - start);
        self.pos = value_end;
    }
};

const stage1_sentinel_count = 3;

pub fn indexYaml(
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlIndexError!YamlStructuralIndex {
    return indexYamlImpl(simd.default_vector_len, allocator, input);
}

/// Builds a yaml-basic-1.2.2 structural index. VLEN controls the SIMD
/// candidate scan; parsing remains scalar so every width has identical output.
pub fn indexYamlImpl(
    comptime VLEN: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlIndexError!YamlStructuralIndex {
    comptime {
        if (VLEN != 16 and VLEN != 32 and VLEN != 64) {
            @compileError("YAML Stage1 requires a 16, 32, or 64 byte vector width");
        }
    }
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    yamlSimdCandidateScan(VLEN, input);
    return parseYamlIndex(allocator, input, null);
}

fn parseYamlIndex(
    allocator: std.mem.Allocator,
    input: []const u8,
    external_failure: ?*?Failure,
) YamlIndexError!YamlStructuralIndex {
    var local_failure: ?Failure = null;
    const failure: *?Failure = external_failure orelse &local_failure;
    try validateYamlInput(input, failure);

    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    try collectLines(allocator, input, &lines, failure);

    const token_capacity = tokenCapacity(input.len) catch return error.CapacityOverflow;
    var indexes = try stage1.StructuralIndex.init(allocator, token_capacity);
    errdefer indexes.deinit(allocator);
    const kinds = try allocator.alloc(YamlTokenKind, token_capacity);
    errdefer allocator.free(kinds);
    const lengths = try allocator.alloc(u32, token_capacity);
    errdefer allocator.free(lengths);

    var result = YamlStructuralIndex{
        .indexes = indexes.indexes,
        .kinds = kinds,
        .lengths = lengths,
        .count = 0,
    };

    var parser = YamlParser{
        .allocator = allocator,
        .input = input,
        .lines = lines.items,
        .index = &result,
        .failure = failure,
    };
    try parser.parseDocument();

    var final_index = stage1.StructuralIndex{
        .indexes = result.indexes,
        .count = result.count,
    };
    try final_index.finish(input.len);
    return result;
}

fn tokenCapacity(input_len: usize) !usize {
    const doubled = std.math.mul(usize, input_len, 2) catch return error.CapacityOverflow;
    return std.math.add(usize, doubled, 8) catch return error.CapacityOverflow;
}

fn validateYamlInput(input: []const u8, failure: *?Failure) YamlIndexError!void {
    if (input.len > std.math.maxInt(u32)) {
        return error.InputTooLarge;
    }
    var index: usize = 0;
    if (input.len >= 3 and input[0] == 0xef and input[1] == 0xbb and input[2] == 0xbf) {
        index = 3;
    }
    while (index < input.len) {
        const byte = input[index];
        if (byte == 0xef and index != 0 and index + 2 < input.len and
            input[index + 1] == 0xbb and input[index + 2] == 0xbf)
        {
            failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = index };
            return error.Invalid;
        }
        if (byte < 0x20 and byte != '\n' and byte != '\r' and byte != ' ' and byte != '\t') {
            failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = index };
            return error.Invalid;
        }
        if (byte == 0x7f) {
            failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = index };
            return error.Invalid;
        }
        if (byte < 0x80) {
            index += 1;
            continue;
        }
        const sequence_len = utf8SequenceLength(input, index) orelse {
            failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = index };
            return error.Invalid;
        };
        index += sequence_len;
    }
}

fn utf8SequenceLength(input: []const u8, index: usize) ?usize {
    const first = input[index];
    if (first >= 0xc2 and first <= 0xdf) {
        if (index + 1 >= input.len or !isContinuation(input[index + 1])) return null;
        return 2;
    }
    if (first == 0xe0) {
        if (index + 2 >= input.len or input[index + 1] < 0xa0 or input[index + 1] > 0xbf or
            !isContinuation(input[index + 2])) return null;
        return 3;
    }
    if (first >= 0xe1 and first <= 0xec or first >= 0xee and first <= 0xef) {
        if (index + 2 >= input.len or !isContinuation(input[index + 1]) or
            !isContinuation(input[index + 2])) return null;
        return 3;
    }
    if (first == 0xed) {
        if (index + 2 >= input.len or input[index + 1] < 0x80 or input[index + 1] > 0x9f or
            !isContinuation(input[index + 2])) return null;
        return 3;
    }
    if (first == 0xf0) {
        if (index + 3 >= input.len or input[index + 1] < 0x90 or input[index + 1] > 0xbf or
            !isContinuation(input[index + 2]) or !isContinuation(input[index + 3])) return null;
        return 4;
    }
    if (first >= 0xf1 and first <= 0xf3) {
        if (index + 3 >= input.len or !isContinuation(input[index + 1]) or
            !isContinuation(input[index + 2]) or !isContinuation(input[index + 3])) return null;
        return 4;
    }
    if (first == 0xf4) {
        if (index + 3 >= input.len or input[index + 1] < 0x80 or input[index + 1] > 0x8f or
            !isContinuation(input[index + 2]) or !isContinuation(input[index + 3])) return null;
        return 4;
    }
    return null;
}

fn isContinuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xbf;
}

fn collectLines(
    allocator: std.mem.Allocator,
    input: []const u8,
    lines: *std.ArrayList(Line),
    failure: *?Failure,
) YamlIndexError!void {
    var offset: usize = if (input.len >= 3 and input[0] == 0xef and input[1] == 0xbb and input[2] == 0xbf) 3 else 0;
    while (offset < input.len) {
        const line_start = offset;
        var content_end = offset;
        while (content_end < input.len and input[content_end] != '\n' and input[content_end] != '\r') : (content_end += 1) {}
        var next = content_end;
        if (content_end < input.len and input[content_end] == '\r') {
            if (content_end + 1 >= input.len or input[content_end + 1] != '\n') {
                failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = content_end };
                return error.Invalid;
            }
            next = content_end + 2;
        } else if (content_end < input.len) {
            next = content_end + 1;
        }
        var content_start = line_start;
        while (content_start < content_end and input[content_start] == ' ') : (content_start += 1) {}
        const indent = content_start - line_start;
        if (content_start < content_end and input[content_start] == '\t') {
            failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = content_start };
            return error.Invalid;
        }
        try lines.append(allocator, .{
            .start = line_start,
            .content_start = content_start,
            .content_end = content_end,
            .next = next,
            .indent = indent,
        });
        offset = next;
    }
    if (input.len == 0 or (input.len > 0 and (input[input.len - 1] == '\n'))) {
        try lines.append(allocator, .{
            .start = input.len,
            .content_start = input.len,
            .content_end = input.len,
            .next = input.len,
            .indent = 0,
        });
    }
}

fn trimSpaces(input: []const u8, start: usize, end: usize) usize {
    var result = end;
    while (result > start and input[result - 1] == ' ') : (result -= 1) {}
    return result;
}

fn trimCommentEnd(input: []const u8, start: usize, end: usize) usize {
    var quote: u8 = 0;
    var flow_depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        const byte = input[index];
        if (quote == '\'') {
            if (byte == '\'' and index + 1 < end and input[index + 1] == '\'') {
                index += 1;
            } else if (byte == '\'') {
                quote = 0;
            }
            continue;
        }
        if (quote == '"') {
            if (byte == '\\') index += 1 else if (byte == '"') quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '[' or byte == '{') flow_depth += 1;
        if (byte == ']' or byte == '}') flow_depth -|= 1;
        if (byte == '#' and flow_depth == 0 and (index == start or input[index - 1] == ' ')) {
            return trimSpaces(input, start, index);
        }
    }
    return trimSpaces(input, start, end);
}

fn findBlockColon(input: []const u8, start: usize, end: usize) ?usize {
    var quote: u8 = 0;
    var flow_depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        const byte = input[index];
        if (quote == '\'') {
            if (byte == '\'' and index + 1 < end and input[index + 1] == '\'') index += 1 else if (byte == '\'') quote = 0;
            continue;
        }
        if (quote == '"') {
            if (byte == '\\') index += 1 else if (byte == '"') quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '[' or byte == '{') {
            flow_depth += 1;
            continue;
        }
        if (byte == ']' or byte == '}') {
            flow_depth -|= 1;
            continue;
        }
        if (byte == '#' and flow_depth == 0 and (index == start or input[index - 1] == ' ')) break;
        if (byte == ':' and flow_depth == 0) {
            if (index + 1 == end or input[index + 1] == ' ' or input[index + 1] == '#' or
                input[index + 1] == '[' or input[index + 1] == '{') return index;
        }
    }
    return null;
}

fn isSequenceEntry(input: []const u8, start: usize, end: usize) bool {
    if (start >= end or input[start] != '-') return false;
    if (start + 1 == end) return true;
    return input[start + 1] == ' ' or input[start + 1] == '#';
}

fn startsUnsupportedConstruct(input: []const u8, start: usize, end: usize) bool {
    if (start >= end) return false;
    return switch (input[start]) {
        '%', '!', '&', '*', '?', '|', '>', '@', '`' => true,
        else => false,
    };
}

fn isHex(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f') or
        (byte >= 'A' and byte <= 'F');
}

fn yamlDiagnosticAtKind(
    input: []const u8,
    err: YamlError,
    kind: YamlDiagnosticKind,
    byte_offset: usize,
) YamlDiagnostic {
    const offset = @min(byte_offset, input.len);
    var line_start: usize = 0;
    var line_number: usize = 1;
    var scan: usize = 0;
    while (scan < offset) : (scan += 1) {
        if (input[scan] == '\n') {
            line_start = scan + 1;
            line_number += 1;
        }
    }
    var line_end = offset;
    while (line_end < input.len and input[line_end] != '\n' and input[line_end] != '\r') : (line_end += 1) {}
    const snippet_start = @max(line_start, offset -| 16);
    const snippet_end = @min(line_end, std.math.add(usize, offset, 16) catch input.len);
    return .{
        .err = err,
        .kind = kind,
        .byte_offset = offset,
        .line = @intCast(@min(line_number, std.math.maxInt(u32))),
        .column = @intCast(@min(offset - line_start + 1, std.math.maxInt(u32))),
        .snippet = input[snippet_start..snippet_end],
        .snippet_start = snippet_start,
    };
}

/// Creates a source-backed YAML diagnostic with syntax classification.
pub fn yamlDiagnosticAt(input: []const u8, err: YamlError, byte_offset: usize) YamlDiagnostic {
    return yamlDiagnosticAtKind(input, err, .syntax, byte_offset);
}

pub fn validateYaml(
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlValidationError!?YamlDiagnostic {
    var failure: ?Failure = null;
    var index = parseYamlIndex(allocator, input, &failure) catch |err| {
        switch (err) {
            error.Invalid => {
                if (failure) |reason| return yamlDiagnosticAtKind(input, reason.err, reason.kind, reason.offset);
                return yamlDiagnosticAt(input, error.Invalid, 0);
            },
            error.Unsupported => {
                if (failure) |reason| return yamlDiagnosticAtKind(input, reason.err, reason.kind, reason.offset);
                return yamlDiagnosticAt(input, error.Unsupported, 0);
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.CapacityOverflow => return error.CapacityOverflow,
            error.InputTooLarge => return error.InputTooLarge,
            error.TapeTooLarge => return error.TapeTooLarge,
        }
    };
    defer index.deinit(allocator);
    return validateYamlIndex(allocator, input, &index);
}

pub fn validateYamlIndex(
    allocator: std.mem.Allocator,
    input: []const u8,
    structural_index: *const YamlStructuralIndex,
) YamlValidationError!?YamlDiagnostic {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (structural_index.count > structural_index.indexes.len or
        structural_index.count > structural_index.kinds.len or
        structural_index.count > structural_index.lengths.len)
    {
        return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, input.len);
    }

    var failure: ?Failure = null;
    var expected = parseYamlIndex(allocator, input, &failure) catch |err| {
        switch (err) {
            error.Invalid => {
                if (failure) |reason| return yamlDiagnosticAtKind(input, reason.err, reason.kind, reason.offset);
                return yamlDiagnosticAt(input, error.Invalid, 0);
            },
            error.Unsupported => {
                if (failure) |reason| return yamlDiagnosticAtKind(input, reason.err, reason.kind, reason.offset);
                return yamlDiagnosticAt(input, error.Unsupported, 0);
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.CapacityOverflow => return error.CapacityOverflow,
            error.InputTooLarge => return error.InputTooLarge,
            error.TapeTooLarge => return error.TapeTooLarge,
        }
    };
    defer expected.deinit(allocator);

    if (expected.count != structural_index.count) {
        const offset = if (structural_index.count < structural_index.indexes.len)
            @as(usize, @intCast(structural_index.indexes[@min(structural_index.count, structural_index.indexes.len - 1)]))
        else
            input.len;
        return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, offset);
    }
    for (0..expected.count) |token_index| {
        if (expected.indexes[token_index] != structural_index.indexes[token_index] or
            expected.kinds[token_index] != structural_index.kinds[token_index] or
            expected.lengths[token_index] != structural_index.lengths[token_index])
        {
            return yamlDiagnosticAtKind(
                input,
                error.Invalid,
                .invalid_index,
                @intCast(structural_index.indexes[token_index]),
            );
        }
    }
    return null;
}

pub fn buildYamlTape(
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlBuildError!YamlDocument {
    var failure: ?Failure = null;
    var structural_index = parseYamlIndex(allocator, input, &failure) catch |err| {
        switch (err) {
            error.Invalid, error.Unsupported => return err,
            error.OutOfMemory => return error.OutOfMemory,
            error.CapacityOverflow => return error.CapacityOverflow,
            error.InputTooLarge => return error.InputTooLarge,
            error.TapeTooLarge => return error.TapeTooLarge,
        }
    };
    defer structural_index.deinit(allocator);

    const tape = try allocator.alloc(YamlTapeWord, structural_index.count);
    errdefer allocator.free(tape);
    for (tape, 0..) |*word, token_index| {
        const kind = structural_index.kinds[token_index];
        const length = structural_index.lengths[token_index];
        if (length > max_u24) return error.TapeTooLarge;
        word.* = .{
            .kind = @intFromEnum(kind),
            .payload = @intCast(length),
            .offset = structural_index.indexes[token_index],
        };
    }
    return .{ .tape = tape, .source = input };
}

/// A chunk-fed YAML Stage 1 indexer. It owns copied input only until finish;
/// `take` transfers the exact one-shot structural index to the caller.
pub const YamlStreamIndexer = struct {
    allocator: std.mem.Allocator,
    input: std.ArrayList(u8) = .empty,
    index: ?YamlStructuralIndex = null,
    finished: bool = false,

    const Self = @This();

    pub const InitError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };
    pub const FeedError = std.mem.Allocator.Error || error{
        AlreadyFinished,
        CapacityOverflow,
        InputTooLarge,
    };
    pub const FinishError = std.mem.Allocator.Error || YamlError || error{
        CapacityOverflow,
        InputTooLarge,
        TapeTooLarge,
    };

    pub fn init(allocator: std.mem.Allocator, chunk_len: usize) InitError!Self {
        if (chunk_len > std.math.maxInt(u32)) return error.InputTooLarge;
        var input = std.ArrayList(u8).empty;
        try input.ensureTotalCapacity(allocator, chunk_len);
        return .{ .allocator = allocator, .input = input };
    }

    pub fn deinit(self: *Self) void {
        if (self.index) |*index| index.deinit(self.allocator);
        self.input.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Self, data: []const u8) FeedError!void {
        if (self.finished) return error.AlreadyFinished;
        const new_len = std.math.add(usize, self.input.items.len, data.len) catch return error.CapacityOverflow;
        if (new_len > std.math.maxInt(u32)) return error.InputTooLarge;
        try self.input.appendSlice(self.allocator, data);
    }

    pub fn finish(self: *Self) FinishError!void {
        if (self.finished) return;
        if (self.index) |*index| {
            index.deinit(self.allocator);
            self.index = null;
        }
        self.index = indexYaml(self.allocator, self.input.items) catch |err| return err;
        self.finished = true;
    }

    pub fn take(self: *Self) YamlStructuralIndex {
        std.debug.assert(self.finished);
        std.debug.assert(self.index != null);
        const index = self.index.?;
        self.index = null;
        return index;
    }

    pub fn reset(self: *Self) void {
        if (self.index) |*index| {
            index.deinit(self.allocator);
            self.index = null;
        }
        self.input.clearRetainingCapacity();
        self.finished = false;
    }
};

fn yamlSimdCandidateScan(comptime VLEN: usize, input: []const u8) void {
    if (input.len == 0) return;
    const Mask = simd.Mask(VLEN);
    var windows = simd.windows(u8, VLEN, input, ' ');
    var offset: usize = 0;
    while (windows.next()) |vector| {
        const valid_count = @min(VLEN, input.len - offset);
        const mask: Mask = (simd.matchAny4(VLEN, vector, '-', ':', '[', '{') |
            simd.matchAny4(VLEN, vector, ']', '}', '#', '\'') |
            simd.matchAny2(VLEN, vector, '"', '\n')) & validMask(VLEN, valid_count);
        var indexes: [VLEN]u32 = undefined;
        _ = simd.extractBitIndexes(Mask, mask, offset, &indexes);
        offset += VLEN;
    }
}

fn validMask(comptime VLEN: usize, valid_count: usize) simd.Mask(VLEN) {
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);
    if (valid_count >= VLEN) return ~@as(Mask, 0);
    if (valid_count == 0) return 0;
    return (@as(Mask, 1) << @as(Shift, @intCast(valid_count))) - 1;
}

// StructuralIndex reserves three terminal entries. Keep this local constant so
// the YAML index never depends on JSON Stage 2 storage or dialects.

// ------------------------------ tests ----------------------------------

test "YAML accepts one document with block mapping and nested sequence" {
    const input =
        "---\n" ++
        "name: Ada\n" ++
        "items:\n" ++
        "  - one\n" ++
        "  - 'two' # trailing comment\n" ++
        "...\n";
    var index = try indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expect(index.count > 0);
    try testing.expectEqual(YamlTokenKind.document_start, index.kinds[0]);
    try testing.expectEqual(YamlTokenKind.document_end, index.kinds[index.count - 1]);

    var document = try buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    try testing.expectEqual(index.count, document.tape.len);
    var cursor = try document.root(input);
    try testing.expectEqual(YamlTokenKind.document_start, (try cursor.peek()).tapeKind());
}

test "YAML accepts flow collections and conservative quoted scalars" {
    const input = "root: {plain: [one, 'two', \"three\\u0033\"]}";
    var document = try buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    var cursor = try document.root(input);
    var saw_mapping = false;
    while (cursor.position() < document.tape.len) {
        const word = try cursor.peek();
        if (word.tapeKind() == .mapping_start) saw_mapping = true;
        try cursor.advance();
    }
    try testing.expect(saw_mapping);
}

test "YAML accepts CRLF, comments, and a leading BOM" {
    const input = "\xef\xbb\xbf--- # start\r\nkey: value\r\n... # end\r\n";
    var index = try indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expect(index.count >= 4);
}

test "YAML reports malformed in-profile syntax as Invalid" {
    try testing.expectError(error.Invalid, buildYamlTape(testing.allocator, "a: [one,]"));
    try testing.expectError(error.Invalid, buildYamlTape(testing.allocator, "a: [one"));
    try testing.expectError(error.Invalid, buildYamlTape(testing.allocator, "a: b\nc: [x] trailing"));
}

test "YAML reports profile-external constructs as Unsupported" {
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "%YAML 1.2\na: b"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "- a: b"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: - item"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: | \n  text"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: \"\\N\""));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: !tag value"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: &anchor value"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: *anchor"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "---\na: b\n---\nc: d"));
}

test "YAML rejects invalid UTF-8 and unsupported line endings" {
    try testing.expectError(error.Invalid, buildYamlTape(testing.allocator, "\xc0\x80"));
    try testing.expectError(error.Invalid, buildYamlTape(testing.allocator, "a: b\rc: d"));
}

test "YAML diagnostics preserve source line and column" {
    const input = "ok: yes\ninvalid: [one,]\n";
    const result = try validateYaml(testing.allocator, input);
    try testing.expect(result != null);
    const diagnostic = result.?;
    try testing.expectEqual(error.Invalid, diagnostic.err);
    try testing.expectEqual(@as(u32, 2), diagnostic.line);
    try testing.expect(diagnostic.column > 1);
    try testing.expect(std.mem.startsWith(u8, diagnostic.snippet, "invalid:"));
}

test "YAML SIMD widths have identical structural output" {
    const input = "root:\n  - one\n  - {two: 'three'}\n";
    var scalar = try indexYamlImpl(16, testing.allocator, input);
    defer scalar.deinit(testing.allocator);
    var width32 = try indexYamlImpl(32, testing.allocator, input);
    defer width32.deinit(testing.allocator);
    var width64 = try indexYamlImpl(64, testing.allocator, input);
    defer width64.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, scalar.slice(), width32.slice());
    try testing.expectEqualSlices(u32, scalar.slice(), width64.slice());
    try testing.expectEqualSlices(YamlTokenKind, scalar.kinds[0..scalar.count], width32.kinds[0..width32.count]);
    try testing.expectEqualSlices(YamlTokenKind, scalar.kinds[0..scalar.count], width64.kinds[0..width64.count]);
    try testing.expectEqualSlices(u32, scalar.lengths[0..scalar.count], width32.lengths[0..width32.count]);
    try testing.expectEqualSlices(u32, scalar.lengths[0..scalar.count], width64.lengths[0..width64.count]);
}

test "YAML stream indexer matches one-shot output" {
    const input = "a: [one, two]\nb: 'three'\n";
    var expected = try indexYaml(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    var stream = try YamlStreamIndexer.init(testing.allocator, 1);
    defer stream.deinit();
    for (input, 0..) |_, offset| {
        try stream.feed(input[offset .. offset + 1]);
    }
    try stream.finish();
    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    try testing.expectEqualSlices(YamlTokenKind, expected.kinds[0..expected.count], actual.kinds[0..actual.count]);
}

fn checkYamlIndexAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "name: Ada\nitems:\n  - one\n  - two\n";
    var index = try indexYaml(allocator, input);
    defer index.deinit(allocator);
}

fn checkYamlValidationAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "name: Ada\nitems:\n  - one\n  - two\n";
    _ = try validateYaml(allocator, input);
}

fn checkYamlValidationIndexAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "name: Ada\nitems:\n  - one\n  - two\n";
    var index = try indexYaml(allocator, input);
    defer index.deinit(allocator);
    _ = try validateYamlIndex(allocator, input, &index);
}

fn checkYamlTapeAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "name: Ada\nitems:\n  - one\n  - two\n";
    var document = try buildYamlTape(allocator, input);
    defer document.deinit(allocator);
}

fn checkYamlStreamAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "name: Ada\nitems:\n  - one\n  - two\n";
    var stream = try YamlStreamIndexer.init(allocator, 1);
    defer stream.deinit();
    try stream.feed(input);
    try stream.finish();
    var index = stream.take();
    defer index.deinit(allocator);
}

test "YAML index and tape operations propagate allocation failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlIndexAllocationFailure,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlValidationAllocationFailure,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlValidationIndexAllocationFailure,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlTapeAllocationFailure,
        .{},
    );
}

test "YAML stream operations propagate allocation failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlStreamAllocationFailure,
        .{},
    );
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}
