const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const resident = @import("../core/resident.zig");
const source = @import("yaml_source.zig");

const testing = std.testing;
const max_u24: usize = std.math.maxInt(u24);
pub const yaml_max_depth: usize = 1024;

/// Named parser profiles. The default remains the restricted basic grammar.
pub const Profile = enum {
    basic,
    extended,
};

pub const profile: Profile = .basic;
pub const profile_label = "yaml-basic-1.2.2";

pub fn profileLabel(selected: Profile) []const u8 {
    return switch (selected) {
        .basic => "yaml-basic-1.2.2",
        .extended => "yaml-extended-e2b-1.2.2",
    };
}

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
    DepthExceeded,
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

    /// Converts a known-valid tape tag to its public enum. Callers that receive
    /// mutable or external tape words must use the checked navigation methods.
    pub fn tapeKind(self: YamlTapeWord) YamlTokenKind {
        return @enumFromInt(self.kind);
    }
    pub fn sourceLength(self: YamlTapeWord) usize {
        return @intCast(self.payload);
    }
};

fn checkedYamlTapeKind(word: YamlTapeWord) YamlNavigationError!YamlTokenKind {
    return switch (word.kind) {
        @intFromEnum(YamlTokenKind.document_start) => .document_start,
        @intFromEnum(YamlTokenKind.document_end) => .document_end,
        @intFromEnum(YamlTokenKind.mapping_start) => .mapping_start,
        @intFromEnum(YamlTokenKind.mapping_end) => .mapping_end,
        @intFromEnum(YamlTokenKind.sequence_start) => .sequence_start,
        @intFromEnum(YamlTokenKind.sequence_end) => .sequence_end,
        @intFromEnum(YamlTokenKind.key) => .key,
        @intFromEnum(YamlTokenKind.scalar) => .scalar,
        else => error.InvalidTapeKind,
    };
}
fn checkedYamlTokenKind(kind: YamlTokenKind) YamlNavigationError!YamlTokenKind {
    return switch (@intFromEnum(kind)) {
        @intFromEnum(YamlTokenKind.document_start) => .document_start,
        @intFromEnum(YamlTokenKind.document_end) => .document_end,
        @intFromEnum(YamlTokenKind.mapping_start) => .mapping_start,
        @intFromEnum(YamlTokenKind.mapping_end) => .mapping_end,
        @intFromEnum(YamlTokenKind.sequence_start) => .sequence_start,
        @intFromEnum(YamlTokenKind.sequence_end) => .sequence_end,
        @intFromEnum(YamlTokenKind.key) => .key,
        @intFromEnum(YamlTokenKind.scalar) => .scalar,
        else => error.InvalidTapeKind,
    };
}

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
        if (input.ptr != self.source.ptr or input.len != self.source.len) {
            return error.SourceOutOfBounds;
        }
        var engine = YamlResidentEngine.init();
        engine.reset(input);
        for (self.tape) |word| {
            const kind = try checkedYamlTapeKind(word);
            const offset: usize = @intCast(word.offset);
            if (offset > input.len) return error.SourceOutOfBounds;
            if (kind == .key or kind == .scalar) {
                const length = word.sourceLength();
                if (length > input.len - offset) return error.SourceOutOfBounds;
            }
            const event = (engine.next(engine.consumed) catch return error.InvalidStructure) orelse
                return error.InvalidStructure;
            if (event.kind != kind or event.offset != word.offset or event.raw.len != word.payload) {
                return error.InvalidStructure;
            }
        }
        if ((engine.next(engine.consumed) catch return error.InvalidStructure) != null) {
            return error.InvalidStructure;
        }
        return .{ .tape = self.tape, .input = input };
    }
    pub fn sourceSpan(
        self: *const YamlDocument,
        input: []const u8,
        tape_index: usize,
    ) YamlNavigationError![]const u8 {
        if (input.ptr != self.source.ptr or input.len != self.source.len) {
            return error.SourceOutOfBounds;
        }
        if (tape_index >= self.tape.len) return error.TapeOutOfBounds;
        const word = self.tape[tape_index];
        const kind = try checkedYamlTapeKind(word);
        if (kind != .key and kind != .scalar) return error.TypeMismatch;
        const offset: usize = @intCast(word.offset);
        const length = word.sourceLength();
        if (offset > input.len or length > input.len - offset) {
            return error.SourceOutOfBounds;
        }
        return input[offset .. offset + length];
    }
};
pub const YamlNavigationError = error{
    TapeOutOfBounds,
    SourceOutOfBounds,
    InvalidTapeKind,
    TypeMismatch,
    UnexpectedEnd,
    InvalidStructure,
};

/// A zero-allocation cursor over an owned YAML tape and borrowed source.
pub const YamlCursor = struct {
    tape: []const YamlTapeWord,
    input: []const u8,
    position_index: usize = 0,

    pub fn peek(self: *const YamlCursor) YamlNavigationError!YamlTapeWord {
        if (self.position_index >= self.tape.len) return error.TapeOutOfBounds;
        const word = self.tape[self.position_index];
        _ = try checkedYamlTapeKind(word);
        return word;
    }

    pub fn advance(self: *YamlCursor) YamlNavigationError!void {
        _ = try self.peek();
        self.position_index += 1;
    }

    pub fn position(self: *const YamlCursor) usize {
        return self.position_index;
    }

    pub fn sourceSpan(self: *const YamlCursor) YamlNavigationError![]const u8 {
        const word = try self.peek();
        const kind = try checkedYamlTapeKind(word);
        if (kind != .key and kind != .scalar) return error.TypeMismatch;
        const start: usize = @intCast(word.offset);
        const length = word.sourceLength();
        if (start > self.input.len or length > self.input.len - start) {
            return error.SourceOutOfBounds;
        }
        return self.input[start .. start + length];
    }

    pub fn span(self: *const YamlCursor) YamlNavigationError![]const u8 {
        return self.sourceSpan();
    }

    pub fn raw(self: *const YamlCursor) YamlNavigationError![]const u8 {
        return self.sourceSpan();
    }

    /// Skips one complete collection while checking every public tape word.
    /// YAML container end offsets are semantic line ends and need not increase.
    pub fn skipChild(self: *YamlCursor) YamlNavigationError!void {
        const first = try self.peek();
        const first_kind = try checkedYamlTapeKind(first);
        if (first_kind != .mapping_start and first_kind != .sequence_start) {
            return error.TypeMismatch;
        }
        var depth: usize = 1;
        var steps: usize = 0;
        while (depth > 0) {
            if (steps >= self.tape.len or self.position_index + 1 >= self.tape.len) {
                return error.UnexpectedEnd;
            }
            const next_kind = try checkedYamlTapeKind(self.tape[self.position_index + 1]);
            try self.advance();
            steps += 1;
            switch (next_kind) {
                .mapping_start, .sequence_start => depth += 1,
                .mapping_end, .sequence_end => depth -= 1,
                else => {},
            }
        }
    }
};
pub const Event = struct {
    kind: YamlTokenKind,
    offset: u32,
    raw: []const u8,
};
pub const ResidentError = std.mem.Allocator.Error || YamlError || resident.Error || error{
    CapacityExceeded,
    InputTooLarge,
    CapacityOverflow,
    TapeTooLarge,
};

pub const Parser = struct {
    max_capacity: usize,
    engine: YamlResidentEngine,
    state: resident.State = .{},

    pub fn init(_: std.mem.Allocator, max_capacity: usize) ResidentError!Parser {
        if (max_capacity > std.math.maxInt(u32)) return error.InputTooLarge;
        return .{
            .max_capacity = max_capacity,
            .engine = YamlResidentEngine.init(),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.engine.deinit();
        self.state.deinit();
        self.* = undefined;
    }
};

pub const OnDemandDocument = struct {
    parser: *Parser,
    input: []const u8,
    lease: resident.Lease,

    pub fn deinit(self: *OnDemandDocument) void {
        self.lease.release();
        self.* = undefined;
    }

    pub fn eventReader(self: *OnDemandDocument) ResidentError!EventReader {
        return .{
            .engine = &self.parser.engine,
            .input = self.input,
            .guard = try self.lease.claim(),
        };
    }

    pub fn tokenCursor(self: *OnDemandDocument) ResidentError!TokenCursor {
        return .{
            .engine = &self.parser.engine,
            .input = self.input,
            .guard = try self.lease.claim(),
        };
    }
};

pub fn initOnDemandDocument(
    parser: *Parser,
    input: []const u8,
) ResidentError!OnDemandDocument {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (parser.max_capacity != 0 and input.len > parser.max_capacity) {
        return error.CapacityExceeded;
    }
    const lease = try parser.state.begin();
    parser.engine.reset(input);
    return .{
        .parser = parser,
        .input = input,
        .lease = lease,
    };
}
pub const EventReader = struct {
    engine: *YamlResidentEngine,
    input: []const u8,
    guard: resident.Guard,

    pub fn next(self: *EventReader) ResidentError!?Event {
        try self.guard.check();
        const event = try self.engine.next(self.guard.expected_position);
        if (event) |value| {
            try self.guard.advance();
            return value;
        }
        return null;
    }

    pub fn peek(self: *const EventReader) ResidentError!?Event {
        try self.guard.check();
        return self.engine.peek(self.guard.expected_position);
    }

    pub fn skip(self: *EventReader) ResidentError!void {
        const first = try self.next() orelse return;
        var depth: usize = switch (first.kind) {
            .mapping_start, .sequence_start => 1,
            else => 0,
        };
        while (depth > 0) {
            const event = try self.next() orelse return error.Invalid;
            switch (event.kind) {
                .mapping_start, .sequence_start => depth += 1,
                .mapping_end, .sequence_end => depth -= 1,
                else => {},
            }
        }
    }
};

pub const TokenCursor = struct {
    engine: *YamlResidentEngine,
    input: []const u8,
    guard: resident.Guard,

    pub fn next(self: *TokenCursor) ResidentError!?Event {
        try self.guard.check();
        const event = try self.engine.next(self.guard.expected_position);
        if (event) |value| {
            try self.guard.advance();
            return value;
        }
        return null;
    }

    pub fn advance(self: *TokenCursor) ResidentError!?Event {
        return self.next();
    }

    pub fn peek(self: *const TokenCursor) ResidentError!?Event {
        try self.guard.check();
        return self.engine.peek(self.guard.expected_position);
    }

    pub fn skipChild(self: *TokenCursor) ResidentError!void {
        var reader: EventReader = .{
            .engine = self.engine,
            .input = self.input,
            .guard = self.guard,
        };
        try reader.skip();
        self.guard = reader.guard;
    }
};

/// SIMD candidate metadata used by the YAML line and punctuation scanners.
/// The metadata is ephemeral: it borrows no input and is discarded after one
/// index pass. Scalar callers intentionally bypass it.
const YamlLexicalMetadata = struct {
    allocator: std.mem.Allocator,
    newline_offsets: []u32,

    fn init(comptime vlen: usize, allocator: std.mem.Allocator, input: []const u8) !YamlLexicalMetadata {
        var newlines = std.ArrayList(u32).empty;
        errdefer newlines.deinit(allocator);

        var windows = simd.windows(u8, vlen, ' ', input);
        var base_offset: usize = 0;
        while (windows.next()) |vector| {
            const valid_count = @min(vlen, input.len - base_offset);
            const valid = simd.validMask(vlen, valid_count);
            const newline_mask = simd.matchByte(vlen, vector, '\n') & valid;

            var indexes: [vlen]u32 = undefined;
            const newline_count = simd.extractBitIndexesChecked(
                @TypeOf(newline_mask),
                newline_mask,
                base_offset,
                &indexes,
            ) catch return error.CapacityOverflow;
            try newlines.appendSlice(allocator, indexes[0..newline_count]);
            base_offset += vlen;
        }

        const newline_offsets = try newlines.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .newline_offsets = newline_offsets,
        };
    }

    fn deinit(self: *YamlLexicalMetadata) void {
        self.allocator.free(self.newline_offsets);
        self.* = undefined;
    }

    fn nextNewline(self: *const YamlLexicalMetadata, cursor: *usize, from: usize) ?usize {
        while (cursor.* < self.newline_offsets.len and
            @as(usize, self.newline_offsets[cursor.*]) < from)
        {
            cursor.* += 1;
        }
        if (cursor.* >= self.newline_offsets.len) return null;
        return @intCast(self.newline_offsets[cursor.*]);
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
    depth: usize = 0,

    const Self = YamlParser;

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
        if (self.depth >= yaml_max_depth) {
            return self.fail(error.DepthExceeded, .syntax, self.input.len);
        }
        self.depth += 1;
        defer self.depth -= 1;
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
            // The key is the token `parseInlineValue` just emitted, so the
            // index holds at least that one entry. `DepthStack.peek` in
            // `src/core/stage2.zig` proves its own depth the same way.
            std.debug.assert(self.index.count > 0);
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
        var inline_parser: InlineParser = .{
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
    depth: usize = 0,
    const Self = InlineParser;

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
        if (self.depth >= yaml_max_depth) {
            return self.fail(error.DepthExceeded, .syntax, self.pos);
        }
        self.depth += 1;
        defer self.depth -= 1;
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
        if (self.depth >= yaml_max_depth) {
            return self.fail(error.DepthExceeded, .syntax, self.pos);
        }
        self.depth += 1;
        defer self.depth -= 1;
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
                // The indicator is unsupported as the scalar's first byte and
                // after a space. `pos` only ever advances from `start`, so
                // these two tests are exactly those two places.
                if (self.pos > start) {
                    if (self.owner.input[self.pos - 1] == ' ') {
                        return self.fail(error.Unsupported, .unsupported, self.pos);
                    }
                } else {
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

/// Builds a yaml-basic-1.2.2 structural index. vlen controls the SIMD
/// metadata scan; scalar parsing remains the independent oracle.
pub fn indexYamlImpl(
    comptime vlen: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlIndexError!YamlStructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    var metadata = try YamlLexicalMetadata.init(vlen, allocator, input);
    defer metadata.deinit();
    return parseYamlIndex(allocator, input, null, &metadata);
}

pub fn scalarIndexYaml(
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlIndexError!YamlStructuralIndex {
    return scalarParseYamlIndex(allocator, input, null);
}

fn scalarParseYamlIndex(
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
    var result: YamlStructuralIndex = .{
        .indexes = indexes.indexes,
        .kinds = kinds,
        .lengths = lengths,
        .count = 0,
    };
    var parser: YamlParser = .{
        .allocator = allocator,
        .input = input,
        .lines = lines.items,
        .index = &result,
        .failure = failure,
    };
    try parser.parseDocument();
    var final_index: stage1.StructuralIndex = .{
        .indexes = result.indexes,
        .count = result.count,
    };
    try final_index.finish(input.len);
    return result;
}

fn parseYamlIndex(
    allocator: std.mem.Allocator,
    input: []const u8,
    external_failure: ?*?Failure,
    metadata: ?*const YamlLexicalMetadata,
) YamlIndexError!YamlStructuralIndex {
    var source_failure: ?Failure = null;
    validateYamlSource(input, &source_failure) catch |err| {
        if (external_failure) |target| target.* = source_failure;
        return err;
    };
    const token_capacity = tokenCapacity(input.len) catch return error.CapacityOverflow;
    var indexes = try stage1.StructuralIndex.init(allocator, token_capacity);
    errdefer indexes.deinit(allocator);
    const kinds = try allocator.alloc(YamlTokenKind, token_capacity);
    errdefer allocator.free(kinds);
    const lengths = try allocator.alloc(u32, token_capacity);
    errdefer allocator.free(lengths);

    var result: YamlStructuralIndex = .{
        .indexes = indexes.indexes,
        .kinds = kinds,
        .lengths = lengths,
        .count = 0,
    };
    var engine = YamlResidentEngine.init();
    engine.resetWithMetadata(input, metadata);
    while (true) {
        const event = engine.next(result.count) catch |err| {
            if (external_failure) |target| {
                if (engine.diagnostic) |reason| target.* = reason;
            }
            return switch (err) {
                error.Invalid => error.Invalid,
                error.Unsupported => error.Unsupported,
                error.DepthExceeded => error.DepthExceeded,
                error.InputTooLarge => error.InputTooLarge,
                error.CapacityOverflow => error.CapacityOverflow,
                error.TapeTooLarge => error.TapeTooLarge,
            };
        };
        const value = event orelse break;
        if (result.count >= result.indexes.len - stage1_sentinel_count) {
            return error.CapacityOverflow;
        }
        result.indexes[result.count] = value.offset;
        result.kinds[result.count] = value.kind;
        // `validateYamlSource` refused any input longer than `maxInt(u32)` and
        // every span is a slice of that input, so the length is representable.
        result.lengths[result.count] = @intCast(value.raw.len);
        result.count += 1;
    }

    var final_index: stage1.StructuralIndex = .{
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
fn validateTapeInputCapacity(input_len: usize) !void {
    const token_capacity = tokenCapacity(input_len) catch return error.CapacityOverflow;
    if (token_capacity > std.math.maxInt(usize) - stage1_sentinel_count) {
        return error.CapacityOverflow;
    }
    if (token_capacity > std.math.maxInt(u32)) return error.InputTooLarge;
}

fn validateYamlInput(
    input: []const u8,
    failure: *?Failure,
) error{ Invalid, InputTooLarge }!void {
    const invalid_offset = try source.failureOffset(input);
    if (invalid_offset) |offset| {
        failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = offset };
        return error.Invalid;
    }
}

fn validateYamlInputImpl(
    comptime vlen: usize,
    input: []const u8,
    failure: *?Failure,
) error{ Invalid, InputTooLarge }!void {
    const invalid_offset = try source.failureOffsetImpl(vlen, input);
    if (invalid_offset) |offset| {
        failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = offset };
        return error.Invalid;
    }
}

fn validateYamlInputScalar(
    input: []const u8,
    failure: *?Failure,
) error{ Invalid, InputTooLarge }!void {
    const invalid_offset = try source.failureOffsetScalarFrom(input, 0);
    if (invalid_offset) |offset| {
        failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = offset };
        return error.Invalid;
    }
}

fn validateYamlSource(input: []const u8, failure: *?Failure) error{ Invalid, InputTooLarge }!void {
    try validateYamlInput(input, failure);
    const start: usize = if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) 3 else 0;
    var indentation = true;
    for (input[start..], start..) |byte, offset| {
        if ((byte == '\r' and (offset + 1 == input.len or input[offset + 1] != '\n')) or
            (indentation and byte == '\t'))
        {
            failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = offset };
            return error.Invalid;
        }
        if (byte == '\n') {
            indentation = true;
        } else if (byte != ' ') {
            indentation = false;
        }
    }
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
        var content_end: usize = offset;
        while (content_end < input.len and input[content_end] != '\n' and
            input[content_end] != '\r') : (content_end += 1)
        {}
        var next: usize = content_end;
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
    if (input.len == 0 or (input.len > 0 and input[input.len - 1] == '\n')) {
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

fn trimCommentEnd(
    input: []const u8,
    start: usize,
    end: usize,
) usize {
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
        if (byte == '#' and flow_depth == 0) {
            // A comment starts the scalar or follows a space; `index` only
            // advances from `start`, so the two tests below are those cases.
            if (index > start) {
                if (input[index - 1] == ' ') return trimSpaces(input, start, index);
            } else {
                return trimSpaces(input, start, index);
            }
        }
    }
    return trimSpaces(input, start, end);
}

fn findBlockColon(
    input: []const u8,
    start: usize,
    end: usize,
) ?usize {
    var quote: u8 = 0;
    var flow_depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        const byte = input[index];
        if (quote == '\'') {
            if (byte == '\'' and index + 1 < end and input[index + 1] == '\'')
                index += 1
            else if (byte == '\'')
                quote = 0;
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
        if (byte == '#' and flow_depth == 0) {
            if (index > start) {
                if (input[index - 1] == ' ') break;
            } else {
                break;
            }
        }
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
    var index = parseYamlIndex(allocator, input, &failure, null) catch |err| {
        switch (err) {
            error.Invalid, error.Unsupported, error.DepthExceeded => {
                if (failure) |reason| {
                    return yamlDiagnosticAtKind(input, reason.err, reason.kind, reason.offset);
                }
                return yamlDiagnosticAt(input, switch (err) {
                    error.Invalid => error.Invalid,
                    error.Unsupported => error.Unsupported,
                    error.DepthExceeded => error.DepthExceeded,
                    else => unreachable,
                }, 0);
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.CapacityOverflow => return error.CapacityOverflow,
            error.InputTooLarge => return error.InputTooLarge,
            error.TapeTooLarge => return error.TapeTooLarge,
            else => unreachable,
        }
    };
    defer index.deinit(allocator);
    return null;
}

pub fn validateYamlIndex(
    allocator: std.mem.Allocator,
    input: []const u8,
    structural_index: *const YamlStructuralIndex,
) YamlValidationError!?YamlDiagnostic {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    const source_count = std.math.add(usize, structural_index.count, stage1_sentinel_count) catch {
        return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, input.len);
    };
    if (source_count > structural_index.indexes.len or
        structural_index.count > structural_index.kinds.len or
        structural_index.count > structural_index.lengths.len)
    {
        return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, input.len);
    }
    // The `InputTooLarge` ceiling above is what makes this representable.
    const sentinel: u32 = @intCast(input.len);
    if (structural_index.indexes[structural_index.count] != sentinel or
        structural_index.indexes[structural_index.count + 1] != sentinel or
        structural_index.indexes[structural_index.count + 2] != 0)
    {
        return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, input.len);
    }
    for (0..structural_index.count) |token_index| {
        const offset: usize = @intCast(structural_index.indexes[token_index]);
        const length: usize = @intCast(structural_index.lengths[token_index]);
        _ = checkedYamlTokenKind(structural_index.kinds[token_index]) catch {
            return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, offset);
        };
        if (offset > input.len or length > input.len - offset) {
            return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, @min(offset, input.len));
        }
    }

    var failure: ?Failure = null;
    var expected = parseYamlIndex(allocator, input, &failure, null) catch |err| {
        switch (err) {
            error.Invalid, error.Unsupported, error.DepthExceeded => {
                if (failure) |reason| {
                    return yamlDiagnosticAtKind(input, reason.err, reason.kind, reason.offset);
                }
                if (err == error.Invalid) return yamlDiagnosticAt(input, error.Invalid, 0);
                if (err == error.Unsupported) return yamlDiagnosticAt(input, error.Unsupported, 0);
                return yamlDiagnosticAt(input, error.DepthExceeded, 0);
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.CapacityOverflow => return error.CapacityOverflow,
            error.TapeTooLarge => return error.TapeTooLarge,
            else => unreachable,
        }
    };
    defer expected.deinit(allocator);

    if (expected.count != structural_index.count) {
        const offset = if (structural_index.count < structural_index.indexes.len)
            @as(usize, @intCast(
                structural_index.indexes[@min(structural_index.count, structural_index.indexes.len - 1)],
            ))
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
    var source_failure: ?Failure = null;
    validateYamlSource(input, &source_failure) catch |err| {
        return switch (err) {
            error.Invalid => error.Invalid,
            error.InputTooLarge => error.InputTooLarge,
        };
    };
    try validateTapeInputCapacity(input.len);

    // Resident events are the tape authority; avoid materializing structural arrays.
    var tape = try std.ArrayList(YamlTapeWord).initCapacity(allocator, @min(input.len, 64));
    errdefer tape.deinit(allocator);

    var engine = YamlResidentEngine.init();
    engine.resetValidated(input);
    while (true) {
        const event = engine.next(tape.items.len) catch |err| {
            return switch (err) {
                error.Invalid => error.Invalid,
                error.Unsupported => error.Unsupported,
                error.DepthExceeded => error.DepthExceeded,
                error.InputTooLarge => error.InputTooLarge,
                error.CapacityOverflow => error.CapacityOverflow,
                error.TapeTooLarge => error.TapeTooLarge,
            };
        };
        const value = event orelse break;
        // `emit` rejects any longer span with `error.TapeTooLarge` before the
        // event is published, so the payload length is representable.
        try tape.append(allocator, .{
            .kind = @intFromEnum(value.kind),
            .payload = @intCast(value.raw.len),
            .offset = value.offset,
        });
    }

    const owned_tape = try tape.toOwnedSlice(allocator);
    return .{ .tape = owned_tape, .source = input };
}

const StreamFrame = struct {
    kind: YamlTokenKind,
    indent: usize,
    end_offset: usize,
};

const StreamPendingEmpty = struct {
    offset: usize,
    indent: usize,
};

fn streamMarker(line: []const u8, start: usize, end: usize, marker: []const u8) bool {
    if (end - start < marker.len) return false;
    if (!std.mem.eql(u8, line[start .. start + marker.len], marker)) return false;
    for (line[start + marker.len .. end]) |byte| {
        if (byte != ' ') return false;
    }
    return true;
}

/// A bounded-line YAML Stage 1 indexer. Completed lines are parsed and
/// discarded; only the unfinished line, stack, and output offsets remain.
pub const YamlStreamIndexer = struct {
    allocator: std.mem.Allocator,
    pending_line: std.ArrayList(u8) = .empty,
    index_offsets: std.ArrayList(u32) = .empty,
    index_kinds: std.ArrayList(YamlTokenKind) = .empty,
    index_lengths: std.ArrayList(u32) = .empty,
    index: ?YamlStructuralIndex = null,
    engine: YamlResidentEngine,
    pending_start: usize = 0,
    input_len: usize = 0,
    finished: bool = false,
    failure: ?FinishError = null,
    const Self = YamlStreamIndexer;

    pub const InitError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };
    pub const FeedError = std.mem.Allocator.Error || YamlError || error{
        AlreadyFinished,
        CapacityOverflow,
        InputTooLarge,
        TapeTooLarge,
    };
    pub const FinishError = std.mem.Allocator.Error || YamlError || error{
        CapacityOverflow,
        InputTooLarge,
        TapeTooLarge,
    };
    pub const FeedFromError = FeedError || FinishError || std.Io.Reader.ShortError;

    pub fn init(allocator: std.mem.Allocator, chunk_len: usize) InitError!YamlStreamIndexer {
        if (chunk_len > std.math.maxInt(u32)) return error.InputTooLarge;
        var pending_line = std.ArrayList(u8).empty;
        try pending_line.ensureTotalCapacity(allocator, @min(chunk_len, max_u24));
        return .{
            .allocator = allocator,
            .pending_line = pending_line,
            .engine = YamlResidentEngine.init(),
        };
    }
    pub fn deinit(self: *Self) void {
        if (self.index) |*index| index.deinit(self.allocator);
        self.pending_line.deinit(self.allocator);
        self.index_offsets.deinit(self.allocator);
        self.index_kinds.deinit(self.allocator);
        self.index_lengths.deinit(self.allocator);
        self.engine.deinit();
        self.* = undefined;
    }

    pub fn retainedByteCount(self: *const Self) usize {
        return self.pending_line.items.len;
    }

    fn appendToken(self: *Self, kind: YamlTokenKind, offset: usize, length: usize) FinishError!void {
        if (offset > std.math.maxInt(u32)) return error.InputTooLarge;
        if (length > std.math.maxInt(u32)) return error.TapeTooLarge;
        if (length > max_u24) return error.TapeTooLarge;
        try self.index_offsets.append(self.allocator, @intCast(offset));
        errdefer _ = self.index_offsets.pop();
        try self.index_kinds.append(self.allocator, kind);
        errdefer _ = self.index_kinds.pop();
        try self.index_lengths.append(self.allocator, @intCast(length));
    }

    fn appendEngineEvents(self: *Self) FinishError!void {
        while (true) {
            const event = self.engine.next(self.engine.consumed) catch |err| switch (err) {
                error.Invalid => return error.Invalid,
                error.Unsupported => return error.Unsupported,
                error.DepthExceeded => return error.DepthExceeded,
                error.InputTooLarge => return error.InputTooLarge,
                error.CapacityOverflow => return error.CapacityOverflow,
                error.TapeTooLarge => return error.TapeTooLarge,
            };
            const value = event orelse break;
            try self.appendToken(value.kind, value.offset, value.raw.len);
        }
    }
    fn processLine(self: *Self, has_newline: bool) FinishError!void {
        var line = self.pending_line.items;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            if (!has_newline) return error.Invalid;
            line = line[0 .. line.len - 1];
        }
        var source_failure: ?Failure = null;
        try validateYamlSource(line, &source_failure);
        if (self.pending_start != 0 and std.mem.startsWith(u8, line, "\xef\xbb\xbf")) {
            return error.Invalid;
        }
        if (self.failure != null) return;
        try self.engine.beginWindow(line, self.pending_start, has_newline);
        try self.appendEngineEvents();
        self.engine.suspendWindow();
        try self.appendEngineEvents();
    }

    pub fn feed(self: *Self, data: []const u8) FeedError!void {
        if (self.finished) return error.AlreadyFinished;
        const new_len = std.math.add(usize, self.input_len, data.len) catch return error.CapacityOverflow;
        if (new_len > std.math.maxInt(u32)) return error.InputTooLarge;
        for (data) |byte| {
            if (byte == '\n') {
                self.processLine(true) catch |err| switch (err) {
                    error.Invalid, error.Unsupported, error.DepthExceeded => {
                        if (self.failure == null or err == error.Invalid) self.failure = err;
                    },
                    else => return err,
                };
                self.pending_line.clearRetainingCapacity();
                self.input_len += 1;
                self.pending_start = self.input_len;
            } else {
                if (self.pending_line.items.len >= max_u24) return error.TapeTooLarge;
                try self.pending_line.append(self.allocator, byte);
                self.input_len += 1;
            }
        }
    }

    pub fn feedFrom(self: *Self, reader: *std.Io.Reader) FeedFromError!void {
        while (true) {
            const buffered = reader.buffered();
            if (buffered.len > 0) {
                try self.feed(buffered);
                reader.toss(buffered.len);
                continue;
            }
            reader.fill(1) catch |err| switch (err) {
                error.EndOfStream => return self.finish(),
                error.ReadFailed => return error.ReadFailed,
            };
        }
    }

    pub fn finish(self: *Self) FinishError!void {
        if (self.finished) return;
        if (self.pending_line.items.len > 0) {
            if (self.pending_line.items[self.pending_line.items.len - 1] == '\r') return error.Invalid;
            try self.processLine(false);
            self.pending_line.clearRetainingCapacity();
        }
        if (self.failure) |err| return err;
        self.engine.endWindow(true);
        try self.appendEngineEvents();
        const sentinel: u32 = @intCast(self.input_len);
        try self.index_offsets.append(self.allocator, sentinel);
        try self.index_offsets.append(self.allocator, sentinel);
        try self.index_offsets.append(self.allocator, 0);

        const indexes = try self.index_offsets.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(indexes);
        const kinds = try self.index_kinds.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(kinds);
        const lengths = try self.index_lengths.toOwnedSlice(self.allocator);
        self.index = .{
            .indexes = indexes,
            .kinds = kinds,
            .lengths = lengths,
            .count = kinds.len,
        };
        self.finished = true;
    }

    pub fn take(self: *Self) YamlStructuralIndex {
        std.debug.assert(self.finished);
        std.debug.assert(self.index != null);
        const result = self.index.?;
        self.index = null;
        return result;
    }

    pub fn reset(self: *Self) void {
        if (self.index) |*index| index.deinit(self.allocator);
        self.index = null;
        self.pending_line.clearRetainingCapacity();
        self.index_offsets.clearRetainingCapacity();
        self.index_kinds.clearRetainingCapacity();
        self.index_lengths.clearRetainingCapacity();
        self.engine.reset(&.{});
        self.pending_start = 0;
        self.input_len = 0;
        self.finished = false;
        self.failure = null;
    }
};

const ResidentLinePhase = enum {
    initial,
    scalar,
    sequence_value,
    mapping_key,
    mapping_value,
    flow,
    done,
    document_start,
    document_end,
};

const ResidentLine = struct {
    start: usize,
    end: usize,
    content_start: usize,
    visible_end: usize,
    indent: usize,
    bom_prefix: usize,
    sequence: bool,
    colon: ?usize,
    value_start: usize = 0,
    key_end: usize = 0,
    phase: ResidentLinePhase = .initial,
};

const ResidentFlowKind = enum {
    sequence,
    mapping,
};

const ResidentFlowExpect = enum {
    value,
    value_after_comma,
    key,
    key_after_comma,
    colon,
    map_value,
    after_value,
};

const ResidentFlowFrame = struct {
    kind: ResidentFlowKind,
    open_offset: usize,
    expect: ResidentFlowExpect,
};

const ResidentSpan = struct {
    start: usize,
    length: usize,
    next: usize,
};

/// A resumable YAML grammar cursor. It retains only source positions,
/// bounded collection frames, and one event. It never constructs a tape or a
/// semantic token list before the caller asks for the next event.
const YamlEngineError = YamlError || error{
    InputTooLarge,
    TapeTooLarge,
    CapacityOverflow,
};
const YamlResidentEngine = struct {
    input: []const u8 = &.{},
    input_base: usize = 0,
    source_pos: usize = 0,
    metadata: ?*const YamlLexicalMetadata = null,
    metadata_cursor: usize = 0,
    // Complete-input callers set this only after validateYamlSource succeeds.
    source_checked: bool = false,
    line: ?ResidentLine = null,
    close_pending: usize = 0,
    resolve_pending: ?usize = null,
    nested_from_empty: bool = false,
    // SAFETY: every frame is written by `pushBlock` before `block_len` exposes
    // it, so no slot is read while uninitialized.
    block_frames: [yaml_max_depth]StreamFrame = undefined,
    block_len: usize = 0,
    pending_empty: ?StreamPendingEmpty = null,
    // SAFETY: every frame is written by `pushFlow` before `flow_len` exposes
    // it, so no slot is read while uninitialized.
    flow_frames: [yaml_max_depth]ResidentFlowFrame = undefined,
    flow_len: usize = 0,
    flow_pos: usize = 0,
    flow_end: usize = 0,
    window_mode: bool = false,
    window_complete: bool = true,
    window_eof: bool = false,
    window_has_newline: bool = false,
    event: ?Event = null,
    consumed: usize = 0,
    saw_root: bool = false,
    root_done: bool = false,
    root_indent: usize = 0,
    document_started: bool = false,
    document_ended: bool = false,
    done: bool = false,
    failed: ?YamlError = null,
    diagnostic: ?Failure = null,

    const Self = YamlResidentEngine;

    fn init() Self {
        return .{};
    }

    fn deinit(self: *Self) void {
        self.* = undefined;
    }

    fn reset(self: *Self, input: []const u8) void {
        self.* = .{
            .input = input,
        };
    }

    /// Use only after validateYamlSource on a complete input.
    fn resetValidated(self: *Self, input: []const u8) void {
        self.* = .{
            .input = input,
            .source_checked = true,
        };
    }

    fn resetWithMetadata(
        self: *Self,
        input: []const u8,
        metadata: ?*const YamlLexicalMetadata,
    ) void {
        self.resetValidated(input);
        self.metadata = metadata;
    }

    fn beginWindow(
        self: *Self,
        input: []const u8,
        input_base: usize,
        has_newline: bool,
    ) YamlEngineError!void {
        if (self.line != null or self.flow_len != 0) return self.record(error.Invalid);
        self.input = input;
        self.input_base = input_base;
        self.source_checked = false;
        self.source_pos = input.len;
        self.window_mode = true;
        self.window_complete = false;
        self.window_eof = false;
        self.window_has_newline = has_newline;
        self.diagnostic = null;
        try self.prepareWindow();
    }
    fn endWindow(self: *Self, eof: bool) void {
        self.window_complete = true;
        self.window_eof = eof;
    }

    fn suspendWindow(self: *Self) void {
        self.window_complete = true;
        self.window_eof = false;
    }

    fn prepareWindow(self: *Self) YamlEngineError!void {
        const end = self.input.len;
        const bom_prefix: usize = if (self.input_base == 0 and end >= 3 and
            self.input[0] == 0xef and self.input[1] == 0xbb and self.input[2] == 0xbf)
            3
        else
            0;
        var failure: ?Failure = null;
        validateYamlInput(self.input[bom_prefix..end], &failure) catch |err| switch (err) {
            error.Invalid => return self.record(error.Invalid),
            error.InputTooLarge => return error.InputTooLarge,
        };
        var content_start = bom_prefix;
        while (content_start < end and self.input[content_start] == ' ') : (content_start += 1) {}
        if (content_start < end and self.input[content_start] == '\t') {
            return self.record(error.Invalid);
        }
        if (content_start == end or self.input[content_start] == '#') return;
        const visible_end = trimCommentEnd(self.input, content_start, end);
        if (visible_end <= content_start) return;
        var line: ResidentLine = .{
            .start = 0,
            .end = self.input_base + end,
            .content_start = content_start,
            .visible_end = visible_end,
            .indent = content_start - bom_prefix,
            .bom_prefix = bom_prefix,
            .sequence = isSequenceEntry(self.input, content_start, visible_end),
            .colon = findBlockColon(self.input, content_start, visible_end),
        };
        if (line.indent == 0 and streamMarker(self.input, content_start, visible_end, "---")) {
            line.phase = .document_start;
            self.close_pending = 0;
            self.resolve_pending = null;
        } else if (line.indent == 0 and streamMarker(self.input, content_start, visible_end, "...")) {
            line.phase = .document_end;
            self.close_pending = self.block_len;
            if (self.pending_empty) |pending| {
                self.resolve_pending = pending.offset;
                self.pending_empty = null;
            }
        } else {
            self.nested_from_empty = if (self.pending_empty) |pending|
                line.indent > pending.indent
            else
                false;
            if (self.pending_empty) |pending| {
                if (!self.nested_from_empty) self.resolve_pending = pending.offset;
                self.pending_empty = null;
            }
            self.close_pending = 0;
            var frame_index = self.block_len;
            while (frame_index > 0 and
                self.block_frames[frame_index - 1].indent > line.indent)
            {
                self.close_pending += 1;
                frame_index -= 1;
            }
        }
        self.line = line;
    }

    fn record(self: *Self, err: YamlError) YamlEngineError {
        if (!self.window_mode and !self.source_checked) {
            var source_failure: ?Failure = null;
            validateYamlSource(self.input, &source_failure) catch |source_err| switch (source_err) {
                error.Invalid => {
                    self.diagnostic = source_failure;
                    self.failed = error.Invalid;
                    return error.Invalid;
                },
                error.InputTooLarge => return error.InputTooLarge,
            };
        }
        const local_offset = if (self.flow_len > 0)
            self.flow_pos
        else if (self.line) |line|
            line.content_start
        else
            self.source_pos;
        const offset = std.math.add(usize, self.input_base, local_offset) catch self.input_base;
        const input_end = std.math.add(usize, self.input_base, self.input.len) catch offset;
        self.diagnostic = .{
            .err = err,
            .kind = if (err == error.Unsupported) .unsupported else .syntax,
            .offset = @min(offset, input_end),
        };
        self.failed = err;
        return err;
    }

    fn emit(self: *Self, kind: YamlTokenKind, offset: usize, length: usize) YamlEngineError!void {
        if (offset > self.input.len or length > self.input.len - offset) {
            return self.record(error.Invalid);
        }
        const absolute = std.math.add(usize, self.input_base, offset) catch return error.InputTooLarge;
        if (absolute > std.math.maxInt(u32)) return error.InputTooLarge;
        if (length > std.math.maxInt(u32)) return error.TapeTooLarge;
        if (length > max_u24) return error.TapeTooLarge;
        self.event = .{
            .kind = kind,
            .offset = @intCast(absolute),
            .raw = if (length == 0) &.{} else self.input[offset .. offset + length],
        };
    }
    fn emitAbsolute(self: *Self, kind: YamlTokenKind, offset: usize) YamlEngineError!void {
        if (offset > std.math.maxInt(u32)) return error.InputTooLarge;
        self.event = .{
            .kind = kind,
            .offset = @intCast(offset),
            .raw = &.{},
        };
    }

    fn failUnclosed(self: *Self, offset: usize) YamlEngineError {
        _ = offset;
        const end = self.currentLineEnd();
        if ((self.window_mode and self.window_has_newline and end == self.input.len) or
            (end < self.input.len and (self.input[end] == '\n' or self.input[end] == '\r')))
        {
            return self.record(error.Unsupported);
        }
        return self.record(error.Invalid);
    }

    fn prepareLine(self: *Self) YamlEngineError!bool {
        while (self.source_pos < self.input.len) {
            const start = self.source_pos;
            const newline = if (self.metadata) |lex|
                lex.nextNewline(&self.metadata_cursor, start)
            else if (std.mem.findScalar(u8, self.input[start..], '\n')) |relative|
                start + relative
            else
                null;
            const has_newline = newline != null;
            var end: usize = newline orelse self.input.len;
            const line_next = if (has_newline) end + 1 else end;
            self.window_has_newline = has_newline;
            if (end > start and self.input[end - 1] == '\r') {
                end -= 1;
            }
            if (!self.source_checked) {
                var scan = start;
                while (scan < end) : (scan += 1) {
                    if (self.input[scan] == '\r') return self.record(error.Invalid);
                }
                if (!has_newline and end < self.input.len) return self.record(error.Invalid);
            }

            const bom_prefix: usize = if (start == 0 and end >= 3 and
                self.input[0] == 0xef and self.input[1] == 0xbb and self.input[2] == 0xbf)
                3
            else
                0;
            if (start != 0 and std.mem.startsWith(u8, self.input[start..end], "\xef\xbb\xbf")) {
                return self.record(error.Invalid);
            }
            if (!self.source_checked) {
                var failure: ?Failure = null;
                validateYamlInput(self.input[start + bom_prefix .. end], &failure) catch |err| switch (err) {
                    error.Invalid => return self.record(error.Invalid),
                    error.InputTooLarge => return error.InputTooLarge,
                };
            }
            var content_start = start + bom_prefix;
            while (content_start < end and self.input[content_start] == ' ') : (content_start += 1) {}
            if (!self.source_checked and content_start < end and self.input[content_start] == '\t') {
                return self.record(error.Invalid);
            }
            self.source_pos = line_next;
            const visible_end = trimCommentEnd(self.input, content_start, end);
            if (visible_end <= content_start) continue;

            var line: ResidentLine = .{
                .start = start,
                .end = end,
                .content_start = content_start,
                .visible_end = visible_end,
                .bom_prefix = bom_prefix,
                .indent = content_start - start - bom_prefix,
                .sequence = isSequenceEntry(self.input, content_start, visible_end),
                .colon = findBlockColon(self.input, content_start, visible_end),
            };
            if (line.indent == 0 and streamMarker(self.input, content_start, visible_end, "---")) {
                line.phase = .document_start;
                self.close_pending = 0;
                self.resolve_pending = null;
            } else if (line.indent == 0 and streamMarker(self.input, content_start, visible_end, "...")) {
                line.phase = .document_end;
                self.close_pending = self.block_len;
                if (self.pending_empty) |pending| {
                    self.resolve_pending = pending.offset;
                    self.pending_empty = null;
                }
            } else {
                self.nested_from_empty = if (self.pending_empty) |pending|
                    line.indent > pending.indent
                else
                    false;
                if (self.pending_empty) |pending| {
                    if (!self.nested_from_empty) {
                        self.resolve_pending = pending.offset;
                    }
                    self.pending_empty = null;
                }
                self.close_pending = 0;
                var frame_index = self.block_len;
                while (frame_index > 0 and
                    self.block_frames[frame_index - 1].indent > line.indent)
                {
                    self.close_pending += 1;
                    frame_index -= 1;
                }
            }
            self.line = line;
            return true;
        }
        return false;
    }

    fn pushBlock(self: *Self, kind: YamlTokenKind, indent: usize, end_offset: usize) YamlEngineError!void {
        if (self.block_len + self.flow_len >= yaml_max_depth) return self.record(error.DepthExceeded);
        self.block_frames[self.block_len] = .{
            .kind = kind,
            .indent = indent,
            .end_offset = end_offset,
        };
        self.block_len += 1;
    }

    fn blockEndKind(kind: YamlTokenKind) ?YamlTokenKind {
        return switch (kind) {
            .mapping_start => .mapping_end,
            .sequence_start => .sequence_end,
            else => null,
        };
    }

    fn pushFlow(self: *Self, kind: ResidentFlowKind, open: usize) YamlEngineError!void {
        if (self.block_len + self.flow_len >= yaml_max_depth) return self.record(error.DepthExceeded);
        self.flow_frames[self.flow_len] = .{
            .kind = kind,
            .open_offset = open,
            .expect = if (kind == .sequence) .value else .key,
        };
        self.flow_len += 1;
        self.flow_pos = open + 1;
    }

    fn parseQuoted(self: *Self, start: usize, end: usize, kind: YamlTokenKind) YamlEngineError!ResidentSpan {
        _ = kind;
        const quote = self.input[start];
        var pos = start + 1;
        if (quote == '\'') {
            while (pos < end) {
                if (self.input[pos] == '\'') {
                    if (pos + 1 < end and self.input[pos + 1] == '\'') {
                        pos += 2;
                        continue;
                    }
                    pos += 1;
                    return .{ .start = start, .length = pos - start, .next = pos };
                }
                pos += 1;
            }
            return self.failUnclosed(start);
        }

        while (pos < end) {
            const byte = self.input[pos];
            if (byte == '"') {
                pos += 1;
                return .{ .start = start, .length = pos - start, .next = pos };
            }
            if (byte == '\\') {
                const escape_offset = pos;
                pos += 1;
                if (pos >= end) return self.failUnclosed(escape_offset);
                switch (self.input[pos]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => pos += 1,
                    'u' => {
                        pos += 1;
                        if (pos < end and self.input[pos] == '{') {
                            return self.record(error.Unsupported);
                        }
                        if (end - pos < 4) return self.record(error.Invalid);
                        var hex: usize = 0;
                        while (hex < 4) : (hex += 1) {
                            if (!isHex(self.input[pos + hex])) return self.record(error.Invalid);
                        }
                        pos += 4;
                    },
                    else => return self.record(error.Unsupported),
                }
            } else {
                pos += 1;
            }
        }
        return self.failUnclosed(start);
    }

    fn parsePlain(
        self: *Self,
        start: usize,
        end: usize,
        context: ParseContext,
        kind: YamlTokenKind,
    ) YamlEngineError!ResidentSpan {
        var pos = start;
        while (pos < end) {
            const byte = self.input[pos];
            if (context == .flow_key and byte == ':') break;
            if ((context == .flow_value or context == .flow_key) and
                (byte == ',' or byte == ']' or byte == '}'))
            {
                break;
            }
            if (byte == ':' and context != .flow_key and
                (pos + 1 == end or self.input[pos + 1] == ' ' or self.input[pos + 1] == '#'))
            {
                return self.record(error.Unsupported);
            }
            if (byte == '#' and pos > start and self.input[pos - 1] == ' ') break;
            if (byte == '\t') return self.record(error.Invalid);
            if (byte == '&' or byte == '*' or byte == '!') {
                if (pos > start) {
                    if (self.input[pos - 1] == ' ') return self.record(error.Unsupported);
                } else {
                    return self.record(error.Unsupported);
                }
            }
            pos += 1;
        }
        const value_end = trimSpaces(self.input, start, pos);
        if (value_end == start) return self.record(error.Invalid);
        _ = kind;
        return .{ .start = start, .length = value_end - start, .next = value_end };
    }

    fn parseScalar(
        self: *Self,
        start: usize,
        end: usize,
        context: ParseContext,
        kind: YamlTokenKind,
    ) YamlEngineError!ResidentSpan {
        if (start >= end) return self.record(error.Invalid);
        return switch (self.input[start]) {
            '\'', '"' => self.parseQuoted(start, end, kind),
            '[', '{' => self.record(error.Unsupported),
            else => if (context != .flow_key and startsUnsupportedConstruct(self.input, start, end))
                self.record(error.Unsupported)
            else
                self.parsePlain(start, end, context, kind),
        };
    }

    fn stepFlow(self: *Self) YamlEngineError!void {
        if (self.flow_len == 0) return self.record(error.Invalid);
        const frame_index = self.flow_len - 1;
        var frame = &self.flow_frames[frame_index];
        while (self.flow_pos < self.flow_end and self.input[self.flow_pos] == ' ') : (self.flow_pos += 1) {}
        if (self.flow_pos >= self.flow_end) {
            if (frame.expect == .colon or frame.expect == .value_after_comma or frame.expect == .key_after_comma) {
                return self.record(error.Invalid);
            }
            return self.failUnclosed(frame.open_offset);
        }
        const byte = self.input[self.flow_pos];

        switch (frame.expect) {
            .value, .value_after_comma => {
                if (byte == ']' and frame.expect == .value) {
                    const close = self.flow_pos;
                    self.flow_pos += 1;
                    self.flow_len -= 1;
                    if (self.flow_len == 0) {
                        if (self.flow_pos != self.currentLineEnd()) return self.record(error.Invalid);
                        if (self.line) |*line| line.phase = .done;
                    }
                    return self.emit(.sequence_end, close, 0);
                }
                if (byte == ']' or byte == ',') return self.record(error.Invalid);
                if (byte == '[' or byte == '{') {
                    frame.expect = .after_value;
                    const open = self.flow_pos;
                    try self.pushFlow(if (byte == '[') .sequence else .mapping, open);
                    return self.emit(if (byte == '[') .sequence_start else .mapping_start, open, 0);
                }
                const span = try self.parseScalar(self.flow_pos, self.flow_end, .flow_value, .scalar);
                self.flow_pos = span.next;
                frame.expect = .after_value;
                return self.emit(.scalar, span.start, span.length);
            },
            .after_value => {
                if (byte == ',') {
                    self.flow_pos += 1;
                    frame.expect = if (frame.kind == .sequence) .value_after_comma else .key_after_comma;
                    return;
                }
                const expected: u8 = if (frame.kind == .sequence) ']' else '}';
                if (byte != expected) return self.record(error.Invalid);
                const close = self.flow_pos;
                self.flow_pos += 1;
                self.flow_len -= 1;
                if (self.flow_len == 0) {
                    if (self.flow_pos != self.currentLineEnd()) return self.record(error.Invalid);
                    if (self.line) |*line| line.phase = .done;
                }
                return self.emit(
                    if (frame.kind == .sequence) .sequence_end else .mapping_end,
                    close,
                    0,
                );
            },
            .key, .key_after_comma => {
                if (byte == '}' and frame.expect == .key) {
                    const close = self.flow_pos;
                    self.flow_pos += 1;
                    self.flow_len -= 1;
                    if (self.flow_len == 0) {
                        if (self.flow_pos != self.currentLineEnd()) return self.record(error.Invalid);
                        if (self.line) |*line| line.phase = .done;
                    }
                    return self.emit(.mapping_end, close, 0);
                }
                if (byte == '}' or byte == ',') return self.record(error.Invalid);
                const span = try self.parseScalar(self.flow_pos, self.flow_end, .flow_key, .key);
                self.flow_pos = span.next;
                frame.expect = .colon;
                return self.emit(.key, span.start, span.length);
            },
            .colon => {
                if (byte != ':') return self.record(error.Invalid);
                self.flow_pos += 1;
                frame.expect = .map_value;
                return;
            },
            .map_value => {
                if (byte == ',' or byte == '}') {
                    frame.expect = .after_value;
                    return self.emit(.scalar, self.flow_pos, 0);
                }
                if (byte == '[' or byte == '{') {
                    frame.expect = .after_value;
                    const open = self.flow_pos;
                    try self.pushFlow(if (byte == '[') .sequence else .mapping, open);
                    return self.emit(if (byte == '[') .sequence_start else .mapping_start, open, 0);
                }
                const span = try self.parseScalar(self.flow_pos, self.flow_end, .flow_value, .scalar);
                self.flow_pos = span.next;
                frame.expect = .after_value;
                return self.emit(.scalar, span.start, span.length);
            },
        }
    }

    fn currentLineEnd(self: *const Self) usize {
        return if (self.line) |line| line.visible_end else self.flow_end;
    }

    fn startLineFlow(self: *Self, line: *ResidentLine, start: usize) YamlEngineError!void {
        if (start >= line.visible_end) return self.record(error.Invalid);
        const byte = self.input[start];
        if (byte != '[' and byte != '{') return self.record(error.Invalid);
        line.phase = .flow;
        self.line = line.*;
        self.flow_end = line.visible_end;
        if (self.block_len > 0) {
            self.block_frames[self.block_len - 1].end_offset = line.end;
        }
        const open = start;
        try self.pushFlow(if (byte == '[') .sequence else .mapping, open);
        return self.emit(if (byte == '[') .sequence_start else .mapping_start, open, 0);
    }

    fn stepLine(self: *Self) YamlEngineError!void {
        var line = self.line orelse return self.record(error.Invalid);
        if (self.resolve_pending) |offset| {
            self.resolve_pending = null;
            return self.emitAbsolute(.scalar, offset);
        }
        if (self.close_pending > 0) {
            self.close_pending -= 1;
            self.block_len -= 1;
            if (self.block_len == 0) self.root_done = true;
            const frame = self.block_frames[self.block_len];
            const end_kind = blockEndKind(frame.kind) orelse return self.record(error.Invalid);
            return self.emitAbsolute(end_kind, frame.end_offset);
        }
        switch (line.phase) {
            .document_start => {
                if (line.indent != 0) return self.record(error.Invalid);
                if (self.document_started or self.saw_root) return self.record(error.Unsupported);
                self.document_started = true;
                line.phase = .done;
                self.line = line;
                return self.emit(.document_start, line.content_start, 3);
            },
            .document_end => {
                if (!self.saw_root or self.document_ended) return self.record(error.Invalid);
                self.document_ended = true;
                self.root_done = true;
                line.phase = .done;
                self.line = line;
                return self.emit(.document_end, line.content_start, 3);
            },
            .done => {
                self.line = null;
                return;
            },
            .flow => {
                self.line = line;
                return self.record(error.Invalid);
            },
            .scalar => {
                const span = try self.parseScalar(
                    line.value_start,
                    line.visible_end,
                    .block_value,
                    .scalar,
                );
                if (span.next != line.visible_end) return self.record(error.Invalid);
                line.phase = .done;
                self.line = line;
                return self.emit(.scalar, span.start, span.length);
            },
            .initial => {},
            .sequence_value => {},
            .mapping_key => {},
            .mapping_value => {},
        }

        if (self.document_ended) return self.record(error.Unsupported);
        if (self.block_len > 0 and !line.sequence) {
            const frame = self.block_frames[self.block_len - 1];
            if (frame.kind == .sequence_start and frame.indent == line.indent) {
                self.block_len -= 1;
                if (self.block_len == 0) self.root_done = true;
                return self.emitAbsolute(.sequence_end, frame.end_offset);
            }
        }
        if (self.block_len == 0 and line.indent == 0 and
            line.content_start < line.visible_end and self.input[line.content_start] == '%')
        {
            return self.record(error.Unsupported);
        }
        if (!self.saw_root) self.root_indent = line.indent;
        if (self.root_done and self.block_len == 0) {
            return self.record(if (line.indent > self.root_indent) error.Unsupported else error.Invalid);
        }
        if (self.block_len == 0 and startsUnsupportedConstruct(self.input, line.content_start, line.visible_end)) {
            return self.record(error.Unsupported);
        }
        if (self.block_len > 0 and line.indent > self.block_frames[self.block_len - 1].indent and
            !self.nested_from_empty)
        {
            return self.record(error.Unsupported);
        }

        if (!line.sequence and line.colon == null) {
            if (self.block_len != 0 and !self.nested_from_empty) {
                if (line.indent > self.block_frames[self.block_len - 1].indent) {
                    return self.record(error.Unsupported);
                }
                return self.record(error.Invalid);
            }
            line.value_start = line.content_start;
            line.phase = .scalar;
            self.saw_root = true;
            if (self.block_len == 0) self.root_done = true;
            self.line = line;
            if (line.value_start < line.visible_end and
                (self.input[line.value_start] == '[' or self.input[line.value_start] == '{'))
            {
                return self.startLineFlow(&line, line.value_start);
            }
            return;
        }

        if (line.sequence) {
            if (self.block_len == 0 or self.block_frames[self.block_len - 1].indent < line.indent) {
                if (self.block_len > 0 and !self.nested_from_empty) {
                    return self.record(error.Unsupported);
                }
                try self.pushBlock(.sequence_start, line.indent, line.end);
                line.phase = .sequence_value;
                self.saw_root = true;
                self.line = line;
                return self.emit(.sequence_start, line.content_start, 0);
            }
            if (self.block_frames[self.block_len - 1].kind != .sequence_start) {
                return self.record(error.Invalid);
            }
            line.phase = .sequence_value;
        } else if (line.colon != null) {
            if (self.block_len == 0 or self.block_frames[self.block_len - 1].indent < line.indent) {
                if (self.block_len > 0 and !self.nested_from_empty) {
                    return self.record(error.Unsupported);
                }
                try self.pushBlock(.mapping_start, line.indent, line.end);
                line.phase = .mapping_key;
                self.saw_root = true;
                self.line = line;
                return self.emit(.mapping_start, line.content_start, 0);
            }
            if (self.block_frames[self.block_len - 1].kind != .mapping_start) {
                return self.record(error.Invalid);
            }
            line.phase = .mapping_key;
        }
        self.line = line;
        return;
    }

    /// The innermost open block frame. Every phase that reaches a continuation
    /// step was set by a step that had a frame open, so the stack is never empty
    /// here; the same proof `DepthStack.peek` makes about its own depth.
    fn topBlockFrame(self: *Self) *StreamFrame {
        std.debug.assert(self.block_len > 0);
        return &self.block_frames[self.block_len - 1];
    }

    fn stepLineContinuation(self: *Self) YamlEngineError!void {
        var line = self.line orelse return self.record(error.Invalid);
        switch (line.phase) {
            .sequence_value => {
                const start = line.content_start + 1 +
                    whileSpaces(self.input, line.content_start + 1, line.visible_end);
                line.value_start = start;
                line.visible_end = trimCommentEnd(self.input, start, line.visible_end);
                if (start >= line.visible_end) {
                    self.pending_empty = .{ .offset = line.end, .indent = line.indent };
                    self.topBlockFrame().end_offset = line.end;
                    self.saw_root = true;
                    line.phase = .done;
                    self.line = line;
                    return;
                }
                if (startsUnsupportedConstruct(self.input, start, line.visible_end)) {
                    return self.record(error.Unsupported);
                }
                if (findBlockColon(self.input, start, line.visible_end) != null) {
                    return self.record(error.Unsupported);
                }
                if (self.input[start] == '[' or self.input[start] == '{') {
                    self.line = line;
                    return self.startLineFlow(&line, start);
                }
                const span = try self.parseScalar(start, line.visible_end, .block_value, .scalar);
                if (span.next != line.visible_end) return self.record(error.Invalid);
                self.topBlockFrame().end_offset = line.end;
                line.phase = .done;
                self.line = line;
                return self.emit(.scalar, span.start, span.length);
            },
            .mapping_key => {
                const colon = line.colon orelse return self.record(error.Invalid);
                const key_end = trimSpaces(self.input, line.content_start, colon);
                if (key_end == line.content_start) return self.record(error.Invalid);
                const span = try self.parseScalar(
                    line.content_start,
                    key_end,
                    .block_key,
                    .key,
                );
                if (span.next != key_end) return self.record(error.Invalid);
                line.key_end = key_end;
                line.phase = .mapping_value;
                self.line = line;
                return self.emit(.key, span.start, span.length);
            },
            .mapping_value => {
                const colon = line.colon orelse return self.record(error.Invalid);
                var start = colon + 1;
                while (start < line.visible_end and self.input[start] == ' ') : (start += 1) {}
                line.value_start = start;
                if (start >= line.visible_end) {
                    self.pending_empty = .{ .offset = self.input_base + colon + 1, .indent = line.indent };
                    self.topBlockFrame().end_offset = line.end;
                    self.saw_root = true;
                    line.phase = .done;
                    self.line = line;
                    return;
                }
                if (startsUnsupportedConstruct(self.input, start, line.visible_end)) {
                    return self.record(error.Unsupported);
                }
                if (self.input[start] == '[' or self.input[start] == '{') {
                    self.line = line;
                    return self.startLineFlow(&line, start);
                }
                if (isSequenceEntry(self.input, start, line.visible_end)) {
                    return self.record(error.Unsupported);
                }
                const span = try self.parseScalar(start, line.visible_end, .block_value, .scalar);
                if (span.next != line.visible_end) return self.record(error.Invalid);
                self.topBlockFrame().end_offset = line.end;
                line.phase = .done;
                self.line = line;
                return self.emit(.scalar, span.start, span.length);
            },
            else => return,
        }
    }

    fn finish(self: *Self) YamlEngineError!void {
        if (self.pending_empty) |pending| {
            self.pending_empty = null;
            return self.emitAbsolute(.scalar, pending.offset);
        }
        if (!self.saw_root) return self.record(error.Invalid);
        if (self.block_len > 0) {
            self.block_len -= 1;
            const frame = self.block_frames[self.block_len];
            const end_kind = blockEndKind(frame.kind) orelse return self.record(error.Invalid);
            if (self.block_len == 0) self.root_done = true;
            return self.emitAbsolute(end_kind, frame.end_offset);
        }
        self.done = true;
    }
    fn produce(self: *Self) YamlEngineError!void {
        while (self.event == null and !self.done) {
            if (self.failed) |err| return err;
            if (self.flow_len > 0) {
                try self.stepFlow();
                continue;
            }
            if (self.line != null) {
                const phase = self.line.?.phase;
                if (phase == .sequence_value or phase == .mapping_key or phase == .mapping_value) {
                    try self.stepLineContinuation();
                } else {
                    try self.stepLine();
                }
                continue;
            }
            if (self.window_mode) {
                if (!self.window_complete or !self.window_eof) return;
                try self.finish();
                continue;
            }
            if (try self.prepareLine()) continue;
            try self.finish();
        }
    }

    fn peek(self: *Self, expected: usize) YamlEngineError!?Event {
        if (expected != self.consumed) return error.Invalid;
        try self.produce();
        return self.event;
    }
    fn next(self: *Self, expected: usize) YamlEngineError!?Event {
        if (expected != self.consumed) return error.Invalid;
        try self.produce();
        if (self.event) |event| {
            self.event = null;
            self.consumed += 1;
            return event;
        }
        return null;
    }
};

pub fn initStreamIndexer(
    allocator: std.mem.Allocator,
    chunk_len: usize,
) YamlStreamIndexer.InitError!YamlStreamIndexer {
    return YamlStreamIndexer.init(allocator, chunk_len);
}

fn whileSpaces(line: []const u8, start: usize, end: usize) usize {
    var count: usize = 0;
    while (start + count < end and line[start + count] == ' ') : (count += 1) {}
    return count;
}
// StructuralIndex reserves three terminal entries. Keep this local constant so
// the YAML index never depends on JSON Stage 2 storage or dialects.

// ------------------------------ tests ----------------------------------
fn expectYamlFailureEqual(expected: ?Failure, actual: ?Failure) !void {
    if (expected) |expected_value| {
        const actual_value = actual orelse return error.ExpectedYamlFailure;
        try testing.expectEqual(expected_value.err, actual_value.err);
        try testing.expectEqual(expected_value.kind, actual_value.kind);
        try testing.expectEqual(expected_value.offset, actual_value.offset);
    } else {
        try testing.expect(actual == null);
    }
}

fn expectYamlInputValidationEqual(input: []const u8) !void {
    var expected_failure: ?Failure = null;
    validateYamlInputScalar(input, &expected_failure) catch |expected_error| {
        inline for ([_]usize{ 4, 16, 32, 64 }) |vector_len| {
            var actual_failure: ?Failure = null;
            try testing.expectError(
                expected_error,
                validateYamlInputImpl(vector_len, input, &actual_failure),
            );
            try expectYamlFailureEqual(expected_failure, actual_failure);
        }
        return;
    };

    inline for ([_]usize{ 4, 16, 32, 64 }) |vector_len| {
        var actual_failure: ?Failure = null;
        try validateYamlInputImpl(vector_len, input, &actual_failure);
        try expectYamlFailureEqual(expected_failure, actual_failure);
    }
}

fn expectYamlTapeMatchesIndexAndResident(input: []const u8) !void {
    var index = try indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);
    var tape_document = try buildYamlTape(testing.allocator, input);
    defer tape_document.deinit(testing.allocator);
    try testing.expectEqual(index.count, tape_document.tape.len);

    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();
    var resident_document = try initOnDemandDocument(&parser, input);
    defer resident_document.deinit();
    var reader = try resident_document.eventReader();

    for (tape_document.tape, 0..) |word, token_index| {
        try testing.expectEqual(index.indexes[token_index], word.offset);
        try testing.expectEqual(index.kinds[token_index], word.tapeKind());
        try testing.expectEqual(
            @as(usize, @intCast(index.lengths[token_index])),
            word.sourceLength(),
        );

        const event = (try reader.next()) orelse return error.UnexpectedEnd;
        try testing.expectEqual(word.tapeKind(), event.kind);
        try testing.expectEqual(word.offset, event.offset);
        try testing.expectEqual(word.sourceLength(), event.raw.len);
    }
    try testing.expectEqual(null, try reader.next());

    var cursor = try tape_document.root(input);
    for (tape_document.tape) |expected_word| {
        try testing.expectEqual(expected_word, try cursor.peek());
        try cursor.advance();
    }
    try testing.expectEqual(tape_document.tape.len, cursor.position());
}

test "YAML direct tape matches index and resident event order" {
    const inputs = [_][]const u8{
        "plain",
        "mapping:\n" ++
            "  empty:\n" ++
            "  nested:\n" ++
            "    -\n" ++
            "    - value\n",
        "root: {plain: [one, 'two''s', \"three\\u0033\"], empty:}\n",
        "\xef\xbb\xbf--- # start\r\n" ++
            "key: value\r\n" ++
            "... # end\r\n",
    };
    for (inputs) |input| {
        try expectYamlTapeMatchesIndexAndResident(input);
    }
}

test "YAML printable ASCII validation matches scalar at vector boundaries" {
    var input: [2 * 64 + 8]u8 = undefined;
    inline for ([_]usize{ 4, 16, 32, 64 }) |boundary| {
        const input_len = boundary + 4;
        @memset(input[0..input_len], 'a');
        try expectYamlInputValidationEqual(input[0..input_len]);

        for ([_]usize{ boundary - 1, boundary, boundary + 1 }) |offset| {
            @memset(input[0..input_len], 'a');
            input[offset] = '\n';
            try expectYamlInputValidationEqual(input[0..input_len]);

            input[offset] = '\t';
            try expectYamlInputValidationEqual(input[0..input_len]);

            input[offset] = 0x1f;
            try expectYamlInputValidationEqual(input[0..input_len]);

            input[offset] = 0x7f;
            try expectYamlInputValidationEqual(input[0..input_len]);
        }

        @memset(input[0..input_len], 'a');
        input[boundary - 1] = 0xc3;
        input[boundary] = 0xa9;
        try expectYamlInputValidationEqual(input[0..input_len]);

        @memset(input[0..input_len], 'a');
        input[boundary - 1] = 0xc3;
        var utf8_failure: ?Failure = null;
        try testing.expectError(
            error.Invalid,
            validateYamlInputImpl(boundary, input[0..input_len], &utf8_failure),
        );
        try testing.expectEqual(boundary - 1, utf8_failure.?.offset);
        try expectYamlInputValidationEqual(input[0..input_len]);

        @memset(input[0..input_len], 'a');
        input[boundary - 1 .. boundary + 2].* = .{ 0xef, 0xbb, 0xbf };
        var bom_failure: ?Failure = null;
        try testing.expectError(
            error.Invalid,
            validateYamlInputImpl(boundary, input[0..input_len], &bom_failure),
        );
        try testing.expectEqual(boundary - 1, bom_failure.?.offset);
        try expectYamlInputValidationEqual(input[0..input_len]);
    }

    @memset(input[0..], 'a');
    input[0..3].* = .{ 0xef, 0xbb, 0xbf };
    try expectYamlInputValidationEqual(input[0..]);
}

test "YAML input validity retains precedence over indentation errors" {
    var input: [72]u8 = undefined;
    @memset(input[0..], 'a');
    input[0] = '\t';
    input[64] = 0x7f;

    var failure: ?Failure = null;
    try testing.expectError(error.Invalid, validateYamlSource(&input, &failure));
    try testing.expectEqual(@as(usize, 64), failure.?.offset);

    input[64] = 0xc0;
    input[65] = 0x80;
    failure = null;
    try testing.expectError(error.Invalid, validateYamlSource(&input, &failure));
    try testing.expectEqual(@as(usize, 64), failure.?.offset);

    input[64] = 'a';
    input[65] = 'a';
    failure = null;
    try testing.expectError(error.Invalid, validateYamlSource(&input, &failure));
    try testing.expectEqual(@as(usize, 0), failure.?.offset);

    failure = null;
    try testing.expectError(
        error.Invalid,
        validateYamlSource("\xef\xbb\xbf\tkey: value\n", &failure),
    );
    try testing.expectEqual(@as(usize, 3), failure.?.offset);
}

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

fn expectYamlIndexEqual(
    expected: *const YamlStructuralIndex,
    actual: *const YamlStructuralIndex,
) !void {
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    try testing.expectEqualSlices(
        YamlTokenKind,
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
    try testing.expectEqualSlices(
        u32,
        expected.lengths[0..expected.count],
        actual.lengths[0..actual.count],
    );
}

test "YAML nested block and flow transitions retain semantic offsets" {
    const input =
        "---\n" ++
        "root:\n" ++
        "  child:\n" ++
        "    - {name: one, empty:}\n" ++
        "tail: done\n" ++
        "...\n";
    var index = try indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);

    var saw_non_monotonic_end = false;
    for (1..index.count) |token_index| {
        const kind = index.kinds[token_index];
        if ((kind == .mapping_end or kind == .sequence_end) and
            index.indexes[token_index] < index.indexes[token_index - 1])
        {
            saw_non_monotonic_end = true;
        }
    }
    try testing.expect(saw_non_monotonic_end);

    var document = try buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    var cursor = try document.root(input);
    try cursor.advance();
    try cursor.skipChild();
    try testing.expectEqual(YamlTokenKind.mapping_end, (try cursor.peek()).tapeKind());
    try cursor.advance();
    try testing.expectEqual(YamlTokenKind.document_end, (try cursor.peek()).tapeKind());
    try cursor.advance();
    try testing.expectError(error.TapeOutOfBounds, cursor.peek());
}

test "YAML empty entries dedents and end marker retain eager parity" {
    const input =
        "mapping:\n" ++
        "  empty:\n" ++
        "  nested:\n" ++
        "    -\n" ++
        "    - value\n" ++
        "tail:\n" ++
        "...\n";
    var index = try indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expect((try validateYamlIndex(
        testing.allocator,
        input,
        &index,
    )) == null);

    var empty_count: usize = 0;
    for (0..index.count) |token_index| {
        if (index.kinds[token_index] == .scalar and
            index.lengths[token_index] == 0)
        {
            empty_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), empty_count);
}

test "YAML profile keeps unsupported multiline and property constructs" {
    const unsupported = [_][]const u8{
        "%YAML 1.2\na: b\n",
        "? complex\n: value\n",
        "a: &anchor value\n",
        "a: *anchor\n",
        "a: !tag value\n",
        "a: |\n  literal\n",
        "a: >\n  folded\n",
        "a: [one\n  two]\n",
        "a: \"first\n  second\"\n",
    };
    for (unsupported) |input| {
        try testing.expectError(error.Unsupported, scalarIndexYaml(testing.allocator, input));
        try testing.expectError(
            error.Unsupported,
            buildYamlTape(testing.allocator, input),
        );
    }
}

test "YAML scalar oracle agrees with every supported SIMD width" {
    const input =
        "\xef\xbb\xbf---\r\n" ++
        "root:\r\n" ++
        "  - {plain: one, quoted: 'two''s'} # comment\r\n" ++
        "  - [three, \"four\\u0034\"]\r\n" ++
        "...\r\n";
    var scalar = try scalarIndexYaml(testing.allocator, input);
    defer scalar.deinit(testing.allocator);

    inline for (.{ 4, 5, 7, 16, 32, 64 }) |vector_len| {
        var vector = try indexYamlImpl(vector_len, testing.allocator, input);
        defer vector.deinit(testing.allocator);
        try expectYamlIndexEqual(&scalar, &vector);
    }
}

test "YAML resident reader is lazy borrowed guarded and reusable" {
    const input = "ok: yes\nbad: [one,]\n";
    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, input);
    var reader = try document.eventReader();
    const start = (try reader.next()) orelse return error.MissingEvent;
    try testing.expectEqual(YamlTokenKind.mapping_start, start.kind);
    try testing.expectEqual(@as(usize, 0), start.raw.len);
    var stale = reader;
    const key = (try reader.next()) orelse return error.MissingEvent;
    try testing.expectEqual(YamlTokenKind.key, key.kind);
    try testing.expectEqualStrings("ok", key.raw);
    try testing.expect(key.raw.ptr == input.ptr);
    try testing.expectError(error.OutOfOrderIteration, stale.next());
    const scalar = (try reader.next()) orelse return error.MissingEvent;
    try testing.expectEqual(YamlTokenKind.scalar, scalar.kind);
    try testing.expectEqualStrings("yes", scalar.raw);
    try testing.expect(scalar.raw.ptr == input.ptr + 4);
    try testing.expectError(error.FocusAlreadyClaimed, document.tokenCursor());

    var saw_invalid = false;
    while (true) {
        const event = reader.next() catch |err| {
            try testing.expectEqual(error.Invalid, err);
            saw_invalid = true;
            break;
        };
        if (event == null) break;
    }
    try testing.expect(saw_invalid);

    document.deinit();
    try testing.expectError(error.DocumentReleased, reader.next());

    var reused = try initOnDemandDocument(&parser, "next: value\n");
    defer reused.deinit();
    var cursor = try reused.tokenCursor();
    try cursor.skipChild();
    try testing.expect((try cursor.peek()) == null);
}

test "YAML direct tape preserves u24 span rejection" {
    const input = try testing.allocator.alloc(u8, max_u24 + 1);
    defer testing.allocator.free(input);
    @memset(input, 'a');
    try testing.expectError(error.TapeTooLarge, buildYamlTape(testing.allocator, input));

    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();
    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();
    try testing.expectError(error.TapeTooLarge, reader.next());
}

test "YAML resident parser enforces capacity and depth limits" {
    var fixed = try Parser.init(testing.allocator, 4);
    defer fixed.deinit();
    try testing.expectError(
        error.CapacityExceeded,
        initOnDemandDocument(&fixed, "five\n"),
    );

    var input = std.ArrayList(u8).empty;
    defer input.deinit(testing.allocator);
    for (0..yaml_max_depth + 1) |_| {
        try input.append(testing.allocator, '[');
    }
    try input.append(testing.allocator, 'x');
    for (0..yaml_max_depth + 1) |_| {
        try input.append(testing.allocator, ']');
    }
    try testing.expectError(
        error.DepthExceeded,
        indexYaml(testing.allocator, input.items),
    );
    try testing.expectError(
        error.DepthExceeded,
        buildYamlTape(testing.allocator, input.items),
    );
}

test "YAML tape cursor rejects source mismatch and forged public words" {
    const input = "key: value\n";
    var document = try buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectError(
        error.SourceOutOfBounds,
        document.root("key: other\n"),
    );
    const saved_kind = document.tape[0].kind;
    document.tape[0].kind = 255;
    try testing.expectError(error.InvalidTapeKind, document.root(input));
    document.tape[0].kind = saved_kind;

    const saved_offset = document.tape[1].offset;
    document.tape[1].offset = @intCast(input.len + 1);
    try testing.expectError(error.SourceOutOfBounds, document.root(input));
    document.tape[1].offset = saved_offset;
}

test "YAML stream consumes completed lines across bytewise boundaries" {
    const input =
        "\xef\xbb\xbf---\r\n" ++
        "root:\r\n" ++
        "  - \"quoted\"\r\n" ++
        "  - {empty:, value: yes}\r\n" ++
        "...\r\n";
    var expected = try indexYaml(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var stream = try initStreamIndexer(testing.allocator, 1);
    defer stream.deinit();
    for (input, 0..) |_, offset| {
        try stream.feed(input[offset .. offset + 1]);
        try testing.expect(stream.retainedByteCount() <= "  - {empty:, value: yes}\r".len);
    }
    try stream.finish();
    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try expectYamlIndexEqual(&expected, &actual);
}

test "YAML stream feedFrom discards large completed-line input" {
    var input = std.ArrayList(u8).empty;
    defer input.deinit(testing.allocator);
    for (0..4096) |_| {
        try input.appendSlice(testing.allocator, "key: value\n");
    }

    var reader = std.Io.Reader.fixed(input.items);
    var stream = try initStreamIndexer(testing.allocator, 7);
    defer stream.deinit();
    try stream.feedFrom(&reader);
    try testing.expectEqual(@as(usize, 0), stream.retainedByteCount());
    var actual = stream.take();
    defer actual.deinit(testing.allocator);

    var expected = try indexYaml(testing.allocator, input.items);
    defer expected.deinit(testing.allocator);
    try expectYamlIndexEqual(&expected, &actual);
}

fn checkYamlResidentAllocationFailure(allocator: std.mem.Allocator) !void {
    var parser = try Parser.init(allocator, 0);
    defer parser.deinit();
    var document = try initOnDemandDocument(&parser, "root: [one, two]\n");
    defer document.deinit();
    var reader = try document.eventReader();
    while (try reader.next()) |_| {}
}

test "YAML resident storage propagates allocation failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlResidentAllocationFailure,
        .{},
    );
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

test "YAML indented markers and sequence comments retain scalar spans" {
    for ([_][]const u8{ " ---\n", " ...\r\n", "-##\n" }) |input| {
        var expected = try scalarIndexYaml(testing.allocator, input);
        defer expected.deinit(testing.allocator);
        var actual = try indexYaml(testing.allocator, input);
        defer actual.deinit(testing.allocator);
        try expectYamlIndexEqual(&expected, &actual);
        var stream = try YamlStreamIndexer.init(testing.allocator, 1);
        defer stream.deinit();
        for (0..input.len) |offset| try stream.feed(input[offset..][0..1]);
        try stream.finish();
        var streamed = stream.take();
        defer streamed.deinit(testing.allocator);
        try expectYamlIndexEqual(&expected, &streamed);
        var parser = try Parser.init(testing.allocator, 0);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var reader = try document.eventReader();
        for (0..expected.count) |position| {
            const event = (try reader.next()) orelse return error.UnexpectedEnd;
            try testing.expectEqual(expected.kinds[position], event.kind);
            try testing.expectEqual(expected.indexes[position], event.offset);
            try testing.expectEqual(expected.lengths[position], event.raw.len);
        }
        try testing.expectEqual(null, try reader.next());
    }
}

test "YAML source and flow errors retain profile precedence" {
    const inputs = [_][]const u8{
        "*\n\tbad",
        "{?",
        "'unfinished \r\n",
        "[one,\r\n",
        "key:\n%YAML 1.2\n",
    };
    for (inputs) |input| {
        try testing.expectError(error.Invalid, scalarIndexYaml(testing.allocator, input));
        try testing.expectError(error.Invalid, indexYaml(testing.allocator, input));
        var stream = try YamlStreamIndexer.init(testing.allocator, 1);
        defer stream.deinit();
        for (0..input.len) |offset| try stream.feed(input[offset..][0..1]);
        try testing.expectError(error.Invalid, stream.finish());
        var parser = try Parser.init(testing.allocator, 0);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var reader = try document.eventReader();
        var failed = false;
        for (0..input.len * 3 + 3) |_| {
            const event = reader.next() catch |err| {
                try testing.expectEqual(error.Invalid, err);
                try testing.expectError(error.Invalid, reader.next());
                failed = true;
                break;
            };
            if (event == null) break;
        }
        try testing.expect(failed);
    }
}

test "YAML owned root rejects forged scalar spans" {
    const input = "key: value";
    var document = try buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    document.tape[2].payload = 0;
    try testing.expectError(error.InvalidStructure, document.root(input));
}
