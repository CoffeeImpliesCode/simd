const std = @import("std");
const source = @import("yaml_source.zig");
const basic = @import("yaml.zig");

const max_u24: usize = std.math.maxInt(u24);
const max_u32: usize = std.math.maxInt(u32);

pub const profile: basic.Profile = .extended;
pub const profile_label = basic.profileLabel(.extended);

pub const ScalarStyle = enum(u8) {
    plain,
    single_quoted,
    double_quoted,
    literal,
    folded,
};

pub const Chomping = enum(u8) {
    clip,
    strip,
    keep,
};

pub const ScalarIndentation = enum(u8) {
    automatic,
    explicit,
};

pub const ValueOwnership = enum(u8) {
    source_borrowed,
    document_owned,
};

pub const Limits = struct {
    source_bytes_max: usize = max_u32,
    cooked_bytes_max: usize = 16 * 1024 * 1024,
    scalar_source_bytes_max: usize = max_u24,
    line_count_max: usize = 1 * 1024 * 1024,
    scalar_line_count_max: usize = 1 * 1024 * 1024,
    indentation_max: usize = 1024,
    depth_max: usize = basic.yaml_max_depth,
    tape_words_max: usize = 1 * 1024 * 1024,
};

pub const default_limits: Limits = .{};

pub const Error = std.mem.Allocator.Error ||
    basic.YamlError ||
    basic.YamlBuildError ||
    basic.YamlNavigationError ||
    error{
        InvalidLimits,
        SourceBytesExceeded,
        CookedBytesExceeded,
        ScalarSourceExceeded,
        LineLimitExceeded,
        ScalarLineLimitExceeded,
        IndentationExceeded,
        TapeWordsExceeded,
    };

pub const DiagnosticKind = enum(u8) {
    syntax,
    unsupported,
    resource,
    invalid_index,
};

pub const Diagnostic = struct {
    err: Error,
    kind: DiagnosticKind,
    byte_offset: usize,
    line: u32,
    column: u32,
    snippet: []const u8,
    snippet_start: usize,
};

pub const Value = struct {
    bytes_view: []const u8,
    ownership_kind: ValueOwnership,

    pub fn bytes(self: Value) []const u8 {
        return self.bytes_view;
    }

    pub fn ownership(self: Value) ValueOwnership {
        return self.ownership_kind;
    }
};

pub const ScalarInfo = struct {
    style: ScalarStyle,
    chomping: Chomping,
    indentation: ScalarIndentation,
    indentation_indicator: u8,
    indentation_width: u32,
    ownership: ValueOwnership,
};

const ScalarMeta = struct {
    raw_start: u32 = 0,
    raw_length: u32 = 0,
    style: ScalarStyle = .plain,
    chomping: Chomping = .clip,
    indentation: ScalarIndentation = .automatic,
    indentation_indicator: u8 = 0,
    indentation_width: u32 = 0,
    ownership: ValueOwnership = .source_borrowed,
    cooked_start: u32 = 0,
    cooked_length: u32 = 0,
};

pub const Document = struct {
    tape: []basic.YamlTapeWord,
    source: []const u8,
    scalar_metadata: []ScalarMeta,
    cooked: []u8,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.tape);
        allocator.free(self.scalar_metadata);
        allocator.free(self.cooked);
        self.* = undefined;
    }

    fn ensureSource(self: *const Document, input: []const u8) Error!void {
        if (input.ptr != self.source.ptr or input.len != self.source.len) {
            return error.SourceOutOfBounds;
        }
    }

    fn checkedWord(
        self: *const Document,
        input: []const u8,
        event_index: usize,
    ) Error!basic.YamlTapeWord {
        try self.ensureSource(input);
        if (event_index >= self.tape.len) return error.TapeOutOfBounds;
        const word = self.tape[event_index];
        if (event_index >= self.scalar_metadata.len) return error.InvalidStructure;
        _ = checkedKind(word) catch return error.InvalidStructure;
        const offset: usize = @intCast(word.offset);
        const length = word.sourceLength();
        if (offset > input.len or length > input.len - offset) {
            return error.SourceOutOfBounds;
        }
        return word;
    }

    pub fn rawSpan(
        self: *const Document,
        input: []const u8,
        event_index: usize,
    ) Error![]const u8 {
        const word = try self.checkedWord(input, event_index);
        const kind = try checkedKind(word);
        if (kind != .key and kind != .scalar) return error.TypeMismatch;
        const offset: usize = @intCast(word.offset);
        return input[offset .. offset + word.sourceLength()];
    }

    pub fn scalarInfo(self: *const Document, event_index: usize) Error!ScalarInfo {
        if (event_index >= self.tape.len or event_index >= self.scalar_metadata.len) {
            return error.TapeOutOfBounds;
        }
        const word = self.tape[event_index];
        const kind = try checkedKind(word);
        if (kind != .key and kind != .scalar) return error.TypeMismatch;
        const word_offset: usize = @intCast(word.offset);
        const word_length = word.sourceLength();
        if (word_offset > self.source.len or word_length > self.source.len - word_offset) {
            return error.SourceOutOfBounds;
        }
        const meta = self.scalar_metadata[event_index];
        const raw_start: usize = @intCast(meta.raw_start);
        if (meta.ownership != .source_borrowed and meta.ownership != .document_owned) {
            return error.InvalidStructure;
        }
        const raw_length: usize = @intCast(meta.raw_length);
        if (raw_start > self.source.len or raw_length > self.source.len - raw_start) {
            return error.SourceOutOfBounds;
        }
        if (meta.ownership == .document_owned) {
            const cooked_start: usize = @intCast(meta.cooked_start);
            const cooked_length: usize = @intCast(meta.cooked_length);
            if (cooked_start > self.cooked.len or cooked_length > self.cooked.len - cooked_start) {
                return error.InvalidStructure;
            }
        }
        return .{
            .style = meta.style,
            .chomping = meta.chomping,
            .indentation = meta.indentation,
            .indentation_indicator = meta.indentation_indicator,
            .indentation_width = meta.indentation_width,
            .ownership = meta.ownership,
        };
    }

    pub fn value(
        self: *const Document,
        input: []const u8,
        event_index: usize,
    ) Error!Value {
        const word = try self.checkedWord(input, event_index);
        const kind = try checkedKind(word);
        if (kind != .key and kind != .scalar) return error.TypeMismatch;
        const meta = self.scalar_metadata[event_index];
        if (meta.ownership != .source_borrowed and meta.ownership != .document_owned) {
            return error.InvalidStructure;
        }
        if (meta.ownership == .source_borrowed) {
            const offset: usize = @intCast(word.offset);
            return .{
                .bytes_view = input[offset .. offset + word.sourceLength()],
                .ownership_kind = .source_borrowed,
            };
        }
        const start: usize = @intCast(meta.cooked_start);
        const length: usize = @intCast(meta.cooked_length);
        if (start > self.cooked.len or length > self.cooked.len - start) {
            return error.InvalidStructure;
        }
        return .{
            .bytes_view = self.cooked[start .. start + length],
            .ownership_kind = .document_owned,
        };
    }
};

pub fn buildYamlTape(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!Document {
    try validateLimits(limits);
    if (input.len > limits.source_bytes_max) return error.SourceBytesExceeded;
    if (input.len > max_u32) return error.InputTooLarge;
    try checkLineLimits(input, limits);
    if (!requiresExtendedParser(input)) {
        return buildBasicDocument(allocator, input, limits);
    }
    var failure: ?Failure = null;
    return parseExtended(allocator, input, limits, &failure);
}

pub fn validateYaml(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!?Diagnostic {
    try validateLimits(limits);
    if (input.len > limits.source_bytes_max) {
        return diagnosticAt(input, error.SourceBytesExceeded, .resource, 0);
    }
    checkLineLimits(input, limits) catch |err| {
        return diagnosticAt(input, err, if (err == error.Invalid) .syntax else .resource, 0);
    };
    if (!requiresExtendedParser(input)) {
        var document = buildBasicDocument(allocator, input, limits) catch |err| {
            switch (err) {
                error.Invalid, error.Unsupported, error.DepthExceeded => {
                    const result = try basic.validateYaml(allocator, input);
                    if (result) |value| {
                        return .{
                            .err = value.err,
                            .kind = switch (value.kind) {
                                .syntax => .syntax,
                                .unsupported => .unsupported,
                                .invalid_index => .invalid_index,
                            },
                            .byte_offset = value.byte_offset,
                            .line = value.line,
                            .column = value.column,
                            .snippet = value.snippet,
                            .snippet_start = value.snippet_start,
                        };
                    }
                    return diagnosticAt(input, err, errorKind(err), 0);
                },
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidLimits => return error.InvalidLimits,
                else => return diagnosticAt(input, err, errorKind(err), 0),
            }
        };
        document.deinit(allocator);
        return null;
    }

    var failure: ?Failure = null;
    var document = parseExtended(allocator, input, limits, &failure) catch |err| {
        if (failure) |reason| {
            return diagnosticAt(input, reason.err, reason.kind, reason.offset);
        }
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidLimits => error.InvalidLimits,
            else => diagnosticAt(input, err, errorKind(err), 0),
        };
    };
    document.deinit(allocator);
    return null;
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.source_bytes_max > max_u32) return error.InvalidLimits;
    if (limits.scalar_source_bytes_max > max_u24) return error.InvalidLimits;
    if (limits.cooked_bytes_max > max_u32) return error.InvalidLimits;
    if (limits.line_count_max == 0) return error.InvalidLimits;
    if (limits.scalar_line_count_max == 0) return error.InvalidLimits;
    if (limits.indentation_max > max_u32) return error.InvalidLimits;
    if (limits.depth_max == 0 or limits.depth_max > basic.yaml_max_depth) return error.InvalidLimits;
    if (limits.tape_words_max == 0) return error.InvalidLimits;
}
fn checkLineLimits(input: []const u8, limits: Limits) Error!void {
    var line_count: usize = 0;
    var line_start: usize = 0;
    while (line_start < input.len) {
        line_count += 1;
        if (line_count > limits.line_count_max) return error.LineLimitExceeded;
        var line_end = line_start;
        while (line_end < input.len and input[line_end] != '\n' and input[line_end] != '\r') : (line_end += 1) {}
        var content_start = line_start;
        while (content_start < line_end and input[content_start] == ' ') : (content_start += 1) {}
        if (content_start - line_start > limits.indentation_max) {
            return error.IndentationExceeded;
        }
        if (content_start < line_end and input[content_start] == '\t' and
            content_start == line_start)
        {
            return error.Invalid;
        }
        if (line_end >= input.len) break;
        line_start = line_end + 1;
        if (input[line_end] == '\r' and line_start < input.len and input[line_start] == '\n') {
            line_start += 1;
        }
    }
    if (input.len > 0 and input[input.len - 1] == '\n') {
        line_count += 1;
        if (line_count > limits.line_count_max) return error.LineLimitExceeded;
    }
}

fn errorKind(err: Error) DiagnosticKind {
    return switch (err) {
        error.Unsupported => .unsupported,
        error.SourceBytesExceeded, error.CookedBytesExceeded, error.ScalarSourceExceeded, error.LineLimitExceeded, error.ScalarLineLimitExceeded, error.IndentationExceeded, error.TapeWordsExceeded, error.InputTooLarge, error.TapeTooLarge, error.CapacityOverflow, error.DepthExceeded => .resource,
        else => .syntax,
    };
}

fn diagnosticAt(
    input: []const u8,
    err: Error,
    kind: DiagnosticKind,
    byte_offset: usize,
) Diagnostic {
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
        .line = @intCast(@min(line_number, max_u32)),
        .column = @intCast(@min(offset - line_start + 1, max_u32)),
        .snippet = input[snippet_start..snippet_end],
        .snippet_start = snippet_start,
    };
}

fn checkedKind(word: basic.YamlTapeWord) Error!basic.YamlTokenKind {
    return switch (word.kind) {
        @intFromEnum(basic.YamlTokenKind.document_start) => .document_start,
        @intFromEnum(basic.YamlTokenKind.document_end) => .document_end,
        @intFromEnum(basic.YamlTokenKind.mapping_start) => .mapping_start,
        @intFromEnum(basic.YamlTokenKind.mapping_end) => .mapping_end,
        @intFromEnum(basic.YamlTokenKind.sequence_start) => .sequence_start,
        @intFromEnum(basic.YamlTokenKind.sequence_end) => .sequence_end,
        @intFromEnum(basic.YamlTokenKind.key) => .key,
        @intFromEnum(basic.YamlTokenKind.scalar) => .scalar,
        else => error.InvalidTapeKind,
    };
}

fn buildBasicDocument(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!Document {
    var source_document = basic.buildYamlTape(allocator, input) catch |err| return err;
    defer source_document.deinit(allocator);

    var depth: usize = 0;
    for (source_document.tape, 0..) |word, event_index| {
        const kind = try checkedKind(word);
        if ((kind == .key or kind == .scalar) and
            word.sourceLength() > limits.scalar_source_bytes_max)
        {
            return error.ScalarSourceExceeded;
        }
        switch (kind) {
            .mapping_start, .sequence_start => {
                if (depth >= limits.depth_max) return error.DepthExceeded;
                depth += 1;
            },
            .mapping_end, .sequence_end => {
                if (depth == 0) return error.Invalid;
                depth -= 1;
            },
            else => {},
        }
        if (event_index >= limits.tape_words_max) return error.TapeWordsExceeded;
    }

    const tape = try allocator.alloc(basic.YamlTapeWord, source_document.tape.len);
    errdefer allocator.free(tape);
    @memcpy(tape, source_document.tape);

    var metadata = try allocator.alloc(ScalarMeta, tape.len);
    errdefer allocator.free(metadata);
    for (metadata) |*entry| entry.* = .{};

    var cooked = std.ArrayList(u8).empty;
    errdefer cooked.deinit(allocator);
    var sink = CookedSink{ .allocator = allocator, .bytes = &cooked, .limits = limits };

    for (tape, 0..) |word, event_index| {
        const kind = try checkedKind(word);
        if (kind != .key and kind != .scalar) continue;
        const raw_start: usize = @intCast(word.offset);
        const raw_length = word.sourceLength();
        metadata[event_index].raw_start = word.offset;
        metadata[event_index].raw_length = @intCast(raw_length);
        if (raw_length == 0) continue;
        const raw = input[raw_start .. raw_start + raw_length];
        if (raw[0] == '\'' or raw[0] == '"') {
            const style: ScalarStyle = if (raw[0] == '\'') .single_quoted else .double_quoted;
            const cooked_start = cooked.items.len;
            try decodeQuoted(&sink, raw, style);
            const cooked_length = cooked.items.len - cooked_start;
            metadata[event_index].style = style;
            metadata[event_index].ownership = .document_owned;
            metadata[event_index].cooked_start = @intCast(cooked_start);
            metadata[event_index].cooked_length = @intCast(cooked_length);
        }
    }

    return .{
        .tape = tape,
        .source = input,
        .scalar_metadata = metadata,
        .cooked = try cooked.toOwnedSlice(allocator),
    };
}

const Failure = struct {
    err: Error,
    kind: DiagnosticKind,
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
    block_key,
    block_value,
    flow_key,
    flow_value,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
    lines: std.ArrayList(Line) = .empty,
    tape: std.ArrayList(basic.YamlTapeWord) = .empty,
    metadata: std.ArrayList(ScalarMeta) = .empty,
    cooked: std.ArrayList(u8) = .empty,
    line_index: usize = 0,
    depth: usize = 0,
    failure: *?Failure,

    fn init(
        allocator: std.mem.Allocator,
        input: []const u8,
        limits: Limits,
        failure: *?Failure,
    ) Parser {
        return .{
            .allocator = allocator,
            .input = input,
            .limits = limits,
            .failure = failure,
        };
    }

    fn deinit(self: *Parser) void {
        self.lines.deinit(self.allocator);
        self.tape.deinit(self.allocator);
        self.metadata.deinit(self.allocator);
        self.cooked.deinit(self.allocator);
    }

    fn fail(self: *Parser, err: Error, kind: DiagnosticKind, offset: usize) Error {
        if (self.failure.* == null) {
            self.failure.* = .{
                .err = err,
                .kind = kind,
                .offset = @min(offset, self.input.len),
            };
        }
        return err;
    }

    fn resource(self: *Parser, err: Error, offset: usize) Error {
        return self.fail(err, .resource, offset);
    }

    fn syntax(self: *Parser, offset: usize) Error {
        return self.fail(error.Invalid, .syntax, offset);
    }

    fn unsupported(self: *Parser, offset: usize) Error {
        return self.fail(error.Unsupported, .unsupported, offset);
    }

    fn collectLines(self: *Parser) Error!void {
        if (self.input.len == 0) return self.syntax(0);
        const invalid_offset = source.failureOffset(self.input) catch |err| return err;
        if (invalid_offset) |offset| return self.syntax(offset);
        var offset: usize = if (std.mem.startsWith(u8, self.input, "\xef\xbb\xbf")) 3 else 0;
        while (offset < self.input.len) {
            const start = offset;
            var content_end = start;
            while (content_end < self.input.len and self.input[content_end] != '\n' and
                self.input[content_end] != '\r') : (content_end += 1)
            {}
            var next = content_end;
            if (content_end < self.input.len and self.input[content_end] == '\r') {
                if (content_end + 1 >= self.input.len or self.input[content_end + 1] != '\n') {
                    return self.syntax(content_end);
                }
                next = content_end + 2;
            } else if (content_end < self.input.len) {
                next = content_end + 1;
            }
            var content_start = start;
            while (content_start < content_end and self.input[content_start] == ' ') : (content_start += 1) {}
            if (content_start < content_end and self.input[content_start] == '\t' and
                content_start == start)
            {
                return self.syntax(content_start);
            }
            if (content_start - start > self.limits.indentation_max) {
                return self.resource(error.IndentationExceeded, start);
            }
            try self.appendLine(.{
                .start = start,
                .content_start = content_start,
                .content_end = content_end,
                .next = next,
                .indent = content_start - start,
            });
            offset = next;
        }
        if (self.input[self.input.len - 1] == '\n') {
            try self.appendLine(.{
                .start = self.input.len,
                .content_start = self.input.len,
                .content_end = self.input.len,
                .next = self.input.len,
                .indent = 0,
            });
        }
    }

    fn appendLine(self: *Parser, line: Line) Error!void {
        if (self.lines.items.len >= self.limits.line_count_max) {
            return self.resource(error.LineLimitExceeded, line.start);
        }
        try self.lines.append(self.allocator, line);
    }

    fn emit(self: *Parser, kind: basic.YamlTokenKind, offset: usize, length: usize) Error!usize {
        if (offset > self.input.len) return self.syntax(self.input.len);
        if (length > max_u32) return self.resource(error.InputTooLarge, offset);
        if (length > max_u24) return self.resource(error.TapeTooLarge, offset);
        if (self.tape.items.len >= self.limits.tape_words_max) {
            return self.resource(error.TapeWordsExceeded, offset);
        }
        const event_index = self.tape.items.len;
        try self.tape.append(self.allocator, .{
            .kind = @intFromEnum(kind),
            .payload = @intCast(length),
            .offset = @intCast(offset),
        });
        try self.metadata.append(self.allocator, .{});
        return event_index;
    }

    fn emitBorrowed(
        self: *Parser,
        kind: basic.YamlTokenKind,
        offset: usize,
        length: usize,
    ) Error!void {
        if ((kind == .key or kind == .scalar) and
            length > self.limits.scalar_source_bytes_max)
        {
            return self.resource(error.ScalarSourceExceeded, offset);
        }
        switch (kind) {
            .mapping_start, .sequence_start => {
                if (self.depth >= self.limits.depth_max) {
                    return self.resource(error.DepthExceeded, offset);
                }
                self.depth += 1;
            },
            .mapping_end, .sequence_end => {
                if (self.depth == 0) return self.syntax(offset);
                self.depth -= 1;
            },
            else => {},
        }
        const event_index = try self.emit(kind, offset, length);
        self.metadata.items[event_index] = .{
            .raw_start = @intCast(offset),
            .raw_length = @intCast(length),
            .style = .plain,
            .ownership = .source_borrowed,
        };
    }

    fn emitOwned(
        self: *Parser,
        kind: basic.YamlTokenKind,
        offset: usize,
        length: usize,
        style: ScalarStyle,
        chomping: Chomping,
        indentation: ScalarIndentation,
        indentation_indicator: u8,
        indentation_width: usize,
        decode: fn (*Parser, *CookedSink, usize, usize) Error!void,
        decode_start: usize,
        decode_end: usize,
    ) Error!void {
        if (length > self.limits.scalar_source_bytes_max) {
            return self.resource(error.ScalarSourceExceeded, offset);
        }
        const event_index = try self.emit(kind, offset, length);
        const cooked_start = self.cooked.items.len;
        var sink = CookedSink{ .allocator = self.allocator, .bytes = &self.cooked, .limits = self.limits };
        try decode(self, &sink, decode_start, decode_end);
        const cooked_length = self.cooked.items.len - cooked_start;
        if (cooked_start > max_u32 or cooked_length > max_u32) {
            return self.resource(error.CookedBytesExceeded, offset);
        }
        self.metadata.items[event_index] = .{
            .raw_start = @intCast(offset),
            .raw_length = @intCast(length),
            .style = style,
            .chomping = chomping,
            .indentation = indentation,
            .indentation_indicator = indentation_indicator,
            .indentation_width = @intCast(indentation_width),
            .ownership = .document_owned,
            .cooked_start = @intCast(cooked_start),
            .cooked_length = @intCast(cooked_length),
        };
    }

    fn nextMeaningful(self: *const Parser, from: usize) ?usize {
        var index = from;
        while (index < self.lines.items.len) : (index += 1) {
            const line = self.lines.items[index];
            if (line.content_start >= line.content_end) continue;
            if (self.input[line.content_start] == '#') continue;
            return index;
        }
        return null;
    }

    fn parseDocument(self: *Parser) Error!void {
        try self.collectLines();
        const first = self.nextMeaningful(0) orelse return self.syntax(self.input.len);
        self.line_index = first;
        if (isMarker(self.input, self.lines.items[first], "---")) {
            try self.emitBorrowed(.document_start, self.lines.items[first].content_start, 3);
            self.line_index = first + 1;
            const next = self.nextMeaningful(self.line_index) orelse return self.syntax(self.input.len);
            if (isMarker(self.input, self.lines.items[next], "---")) {
                return self.unsupported(self.lines.items[next].content_start);
            }
            self.line_index = next;
        }
        try self.parseBlock(self.lines.items[self.line_index].indent);
        if (self.nextMeaningful(self.line_index)) |next| {
            const line = self.lines.items[next];
            if (isMarker(self.input, line, "...")) {
                try self.emitBorrowed(.document_end, line.content_start, 3);
                self.line_index = next + 1;
                if (self.nextMeaningful(self.line_index)) |remaining| {
                    return self.unsupported(self.lines.items[remaining].content_start);
                }
            } else if (isMarker(self.input, line, "---")) {
                return self.unsupported(line.content_start);
            } else {
                return self.syntax(line.content_start);
            }
        }
    }

    fn parseBlock(self: *Parser, indent: usize) Error!void {
        const current = self.nextMeaningful(self.line_index) orelse return self.syntax(self.input.len);
        const line = self.lines.items[current];
        if (line.indent < indent) return self.syntax(line.content_start);
        if (line.indent > indent) return self.unsupported(line.content_start);
        self.line_index = current;
        if (isSequenceEntry(self.input, line.content_start, line.content_end)) {
            return self.parseSequence(indent);
        }
        if (findColon(self.input, line.content_start, visibleEnd(self.input, line)) != null) {
            return self.parseMapping(indent);
        }
        if (self.input[line.content_start] == '|' or self.input[line.content_start] == '>') {
            try self.parseBlockScalar(
                current,
                line.content_start,
                visibleEnd(self.input, line),
                indent,
            );
            return;
        }
        if (startsUnsupported(self.input, line.content_start, line.content_end)) {
            return self.unsupported(line.content_start);
        }
        const end = visibleEnd(self.input, line);
        const next = try self.parseInline(line.content_start, end, .block_value);
        self.line_index = self.lineAfterOffset(next, current);
    }

    fn parseMapping(self: *Parser, indent: usize) Error!void {
        const first = self.nextMeaningful(self.line_index) orelse return self.syntax(self.input.len);
        const start_offset = self.lines.items[first].content_start;
        try self.emitBorrowed(.mapping_start, start_offset, 0);
        var end_offset = self.lines.items[first].content_end;
        while (self.nextMeaningful(self.line_index)) |current| {
            const line = self.lines.items[current];
            if (line.indent < indent) break;
            if (line.indent > indent) return self.unsupported(line.content_start);
            if (isMarker(self.input, line, "...") or isMarker(self.input, line, "---")) break;
            if (isSequenceEntry(self.input, line.content_start, line.content_end)) {
                return self.syntax(line.content_start);
            }
            const end = visibleEnd(self.input, line);
            const colon = findColon(self.input, line.content_start, end) orelse {
                return self.syntax(line.content_start);
            };
            try self.parsePair(current, line.content_start, end, indent, colon);
            end_offset = self.consumedEnd(current, line.content_end);
        }
        try self.emitBorrowed(.mapping_end, end_offset, 0);
    }

    fn parsePair(
        self: *Parser,
        line_index: usize,
        pair_start: usize,
        pair_end: usize,
        owner_indent: usize,
        colon: usize,
    ) Error!void {
        const key_end = trimSpaces(self.input, pair_start, colon);
        if (key_end == pair_start) return self.syntax(colon);
        const key_next = try self.parseInline(pair_start, key_end, .block_key);
        if (key_next != key_end) return self.syntax(key_next);

        var value_start = colon + 1;
        while (value_start < pair_end and self.input[value_start] == ' ') : (value_start += 1) {}
        if (value_start >= pair_end) {
            self.line_index = line_index + 1;
            if (self.nextMeaningful(self.line_index)) |next| {
                const next_line = self.lines.items[next];
                if (next_line.indent > owner_indent) {
                    self.line_index = next;
                    return self.parseBlock(next_line.indent);
                }
            }
            return self.emitBorrowed(.scalar, colon + 1, 0);
        }
        if (self.input[value_start] == '|' or self.input[value_start] == '>') {
            try self.parseBlockScalar(line_index, value_start, pair_end, owner_indent);
            return;
        }
        if (startsUnsupported(self.input, value_start, pair_end)) {
            return self.unsupported(value_start);
        }
        const parse_end = if (self.input[value_start] == '\'' or self.input[value_start] == '\"')
            self.input.len
        else
            pair_end;
        const value_next = try self.parseInline(value_start, parse_end, .block_value);
        if (value_next <= pair_end) {
            if (value_next != pair_end) return self.syntax(value_next);
            self.line_index = self.lineAfterOffset(value_next, line_index);
            return;
        }
        self.line_index = self.lineAfterOffset(value_next, line_index);
    }

    fn parseSequence(self: *Parser, indent: usize) Error!void {
        const first = self.nextMeaningful(self.line_index) orelse return self.syntax(self.input.len);
        try self.emitBorrowed(.sequence_start, self.lines.items[first].content_start, 0);
        var end_offset = self.lines.items[first].content_end;
        while (self.nextMeaningful(self.line_index)) |current| {
            const line = self.lines.items[current];
            if (line.indent < indent) break;
            if (line.indent > indent) return self.unsupported(line.content_start);
            if (isMarker(self.input, line, "...") or isMarker(self.input, line, "---")) break;
            if (!isSequenceEntry(self.input, line.content_start, line.content_end)) break;
            var value_start = line.content_start + 1;
            while (value_start < line.content_end and self.input[value_start] == ' ') : (value_start += 1) {}
            const end = visibleEnd(self.input, line);
            if (value_start >= end) {
                self.line_index = current + 1;
                if (self.nextMeaningful(self.line_index)) |next| {
                    const next_line = self.lines.items[next];
                    if (next_line.indent > indent) {
                        self.line_index = next;
                        try self.parseBlock(next_line.indent);
                    } else {
                        try self.emitBorrowed(.scalar, line.content_end, 0);
                    }
                } else {
                    try self.emitBorrowed(.scalar, line.content_end, 0);
                }
            } else if (self.input[value_start] == '|' or self.input[value_start] == '>') {
                try self.parseBlockScalar(current, value_start, end, indent);
            } else if (findColon(self.input, value_start, end)) |colon| {
                try self.parseCompactMapping(current, value_start, end, indent, colon);
            } else {
                if (startsUnsupported(self.input, value_start, end)) return self.unsupported(value_start);
                const parse_end = if (self.input[value_start] == '\'' or self.input[value_start] == '\"')
                    self.input.len
                else
                    end;
                const value_next = try self.parseInline(value_start, parse_end, .block_value);
                if (value_next <= end) {
                    if (value_next != end) return self.syntax(value_next);
                    self.line_index = self.lineAfterOffset(value_next, current);
                } else {
                    self.line_index = self.lineAfterOffset(value_next, current);
                }
                if (self.nextMeaningful(self.line_index)) |next| {
                    if (self.lines.items[next].indent > indent) {
                        return self.unsupported(self.lines.items[next].content_start);
                    }
                }
            }
            end_offset = self.consumedEnd(current, line.content_end);
        }
        try self.emitBorrowed(.sequence_end, end_offset, 0);
    }

    fn parseCompactMapping(
        self: *Parser,
        first_line_index: usize,
        pair_start: usize,
        pair_end: usize,
        sequence_indent: usize,
        first_colon: usize,
    ) Error!void {
        try self.emitBorrowed(.mapping_start, pair_start, 0);
        const first_owner_indent = std.math.add(usize, sequence_indent, 2) catch
            return self.resource(error.IndentationExceeded, pair_start);
        try self.parsePair(
            first_line_index,
            pair_start,
            pair_end,
            first_owner_indent,
            first_colon,
        );
        var end_offset = self.lines.items[first_line_index].content_end;
        const continuation = self.nextMeaningful(self.line_index) orelse {
            try self.emitBorrowed(.mapping_end, end_offset, 0);
            return;
        };
        const continuation_indent = self.lines.items[continuation].indent;
        if (continuation_indent <= sequence_indent) {
            try self.emitBorrowed(.mapping_end, end_offset, 0);
            return;
        }
        self.line_index = continuation;
        while (self.nextMeaningful(self.line_index)) |current| {
            const line = self.lines.items[current];
            if (line.indent <= sequence_indent) break;
            if (line.indent != continuation_indent) {
                if (line.indent > continuation_indent) return self.unsupported(line.content_start);
                return self.syntax(line.content_start);
            }
            if (isSequenceEntry(self.input, line.content_start, line.content_end)) {
                return self.syntax(line.content_start);
            }
            const end = visibleEnd(self.input, line);
            const colon = findColon(self.input, line.content_start, end) orelse {
                return self.syntax(line.content_start);
            };
            try self.parsePair(current, line.content_start, end, continuation_indent, colon);
            end_offset = self.consumedEnd(current, line.content_end);
        }
        try self.emitBorrowed(.mapping_end, end_offset, 0);
    }

    fn parseInline(self: *Parser, start: usize, end: usize, context: ParseContext) Error!usize {
        if (start > end or end > self.input.len) return self.syntax(start);
        if (start == end) {
            try self.emitBorrowed(.scalar, start, 0);
            return end;
        }
        return switch (self.input[start]) {
            '\'', '"' => self.parseQuoted(start, context),
            '[' => self.parseFlowSequence(start, end),
            '{' => self.parseFlowMapping(start, end),
            '|', '>' => self.unsupported(start),
            else => self.parsePlain(start, end, context),
        };
    }

    fn parsePlain(self: *Parser, start: usize, end: usize, context: ParseContext) Error!usize {
        if (startsUnsupported(self.input, start, end)) return self.unsupported(start);
        var pos = start;
        while (pos < end) : (pos += 1) {
            const byte = self.input[pos];
            if (context == .flow_key and byte == ':') break;
            if ((context == .flow_key or context == .flow_value) and
                (byte == ',' or byte == ']' or byte == '}'))
            {
                break;
            }
            if (byte == '\t') return self.syntax(pos);
            if (byte == '#' and pos > start and self.input[pos - 1] == ' ') break;
            if (byte == ':' and context != .flow_key and
                (pos + 1 == end or self.input[pos + 1] == ' ' or self.input[pos + 1] == '#'))
            {
                return self.unsupported(pos);
            }
        }
        const value_end = trimSpaces(self.input, start, pos);
        if (value_end == start) return self.syntax(start);
        try self.emitBorrowed(
            if (context == .block_key or context == .flow_key) .key else .scalar,
            start,
            value_end - start,
        );
        return value_end;
    }

    fn parseQuoted(self: *Parser, start: usize, context: ParseContext) Error!usize {
        const style: ScalarStyle = if (self.input[start] == '\'') .single_quoted else .double_quoted;
        var pos = start + 1;
        var scalar_line_count: usize = 1;
        var closed = false;
        while (pos < self.input.len) {
            const byte = self.input[pos];
            if (byte == self.input[start]) {
                if (style == .single_quoted and pos + 1 < self.input.len and self.input[pos + 1] == '\'') {
                    pos += 2;
                    continue;
                }
                pos += 1;
                closed = true;
                break;
            }
            if (style == .double_quoted and byte == '\\') {
                if (pos + 1 >= self.input.len) return self.syntax(pos);
                const escape = self.input[pos + 1];
                if (escape == '\n' or escape == '\r') {
                    scalar_line_count += 1;
                    const continuation_start = if (escape == '\r' and pos + 2 < self.input.len and
                        self.input[pos + 2] == '\n')
                        pos + 3
                    else
                        pos + 2;
                    if (scalar_line_count > self.limits.scalar_line_count_max) {
                        return self.resource(error.ScalarLineLimitExceeded, continuation_start);
                    }
                    pos = continuation_start;
                } else {
                    pos += 2;
                }
                continue;
            }
            if (byte == '\n' or byte == '\r') {
                scalar_line_count += 1;
                const continuation_start = if (byte == '\r' and pos + 1 < self.input.len and
                    self.input[pos + 1] == '\n')
                    pos + 2
                else
                    pos + 1;
                if (scalar_line_count > self.limits.scalar_line_count_max) {
                    return self.resource(error.ScalarLineLimitExceeded, continuation_start);
                }
                pos = continuation_start;
                continue;
            }
            pos += 1;
        }
        if (!closed) return self.syntax(start);
        const kind: basic.YamlTokenKind = if (context == .block_key or context == .flow_key) .key else .scalar;
        try self.emitQuoted(kind, start, pos, style);
        return pos;
    }

    fn emitQuoted(
        self: *Parser,
        kind: basic.YamlTokenKind,
        start: usize,
        end: usize,
        style: ScalarStyle,
    ) Error!void {
        const length = end - start;
        if (length > self.limits.scalar_source_bytes_max) {
            return self.resource(error.ScalarSourceExceeded, start);
        }
        const event_index = try self.emit(kind, start, length);
        const cooked_start = self.cooked.items.len;
        var sink = CookedSink{ .allocator = self.allocator, .bytes = &self.cooked, .limits = self.limits };
        decodeQuotedRange(&sink, self.input, start, end, style, cooked_start) catch |err| {
            const offset = if (err == error.Invalid)
                invalidQuotedOffset(self.input, start, end, style)
            else
                start;
            if (err == error.OutOfMemory) return err;
            return self.fail(err, errorKind(err), offset);
        };
        const cooked_length = self.cooked.items.len - cooked_start;
        if (cooked_start > max_u32 or cooked_length > max_u32) {
            return self.resource(error.CookedBytesExceeded, start);
        }
        self.metadata.items[event_index] = .{
            .raw_start = @intCast(start),
            .raw_length = @intCast(length),
            .style = style,
            .ownership = .document_owned,
            .cooked_start = @intCast(cooked_start),
            .cooked_length = @intCast(cooked_length),
        };
    }

    fn parseFlowSequence(self: *Parser, start: usize, end: usize) Error!usize {
        try self.emitBorrowed(.sequence_start, start, 0);
        var pos = start + 1;
        while (pos < end and self.input[pos] == ' ') : (pos += 1) {}
        if (pos < end and self.input[pos] == ']') {
            try self.emitBorrowed(.sequence_end, pos, 0);
            return pos + 1;
        }
        while (true) {
            if (pos >= end) return self.syntax(start);
            const next = try self.parseInline(pos, end, .flow_value);
            pos = next;
            while (pos < end and self.input[pos] == ' ') : (pos += 1) {}
            if (pos >= end) return self.syntax(start);
            if (self.input[pos] == ',') {
                pos += 1;
                while (pos < end and self.input[pos] == ' ') : (pos += 1) {}
                if (pos >= end or self.input[pos] == ']') return self.syntax(pos);
                continue;
            }
            if (self.input[pos] == ']') {
                try self.emitBorrowed(.sequence_end, pos, 0);
                return pos + 1;
            }
            return self.syntax(pos);
        }
    }

    fn parseFlowMapping(self: *Parser, start: usize, end: usize) Error!usize {
        try self.emitBorrowed(.mapping_start, start, 0);
        var pos = start + 1;
        while (pos < end and self.input[pos] == ' ') : (pos += 1) {}
        if (pos < end and self.input[pos] == '}') {
            try self.emitBorrowed(.mapping_end, pos, 0);
            return pos + 1;
        }
        while (true) {
            const key_next = try self.parseInline(pos, end, .flow_key);
            pos = key_next;
            while (pos < end and self.input[pos] == ' ') : (pos += 1) {}
            if (pos >= end or self.input[pos] != ':') return self.syntax(pos);
            pos += 1;
            while (pos < end and self.input[pos] == ' ') : (pos += 1) {}
            if (pos >= end or self.input[pos] == ',' or self.input[pos] == '}') {
                try self.emitBorrowed(.scalar, pos, 0);
            } else {
                pos = try self.parseInline(pos, end, .flow_value);
            }
            while (pos < end and self.input[pos] == ' ') : (pos += 1) {}
            if (pos >= end) return self.syntax(start);
            if (self.input[pos] == ',') {
                pos += 1;
                while (pos < end and self.input[pos] == ' ') : (pos += 1) {}
                if (pos >= end or self.input[pos] == '}') return self.syntax(pos);
                continue;
            }
            if (self.input[pos] == '}') {
                try self.emitBorrowed(.mapping_end, pos, 0);
                return pos + 1;
            }
            return self.syntax(pos);
        }
    }

    fn parseBlockScalar(
        self: *Parser,
        header_line_index: usize,
        start: usize,
        end: usize,
        parent_indent: usize,
    ) Error!void {
        const header = parseBlockHeader(self.input, start, end) catch |err| {
            return self.fail(err, .syntax, start);
        };
        const explicit_width = if (header.indent_width) |indicator|
            std.math.add(usize, parent_indent, indicator) catch
                return self.resource(error.IndentationExceeded, start)
        else
            null;
        const body_start = header_line_index + 1;
        var body_end = body_start;
        var nonblank_indent: ?usize = null;
        var leading_blank_indent: usize = 0;
        var body_line_count: usize = 0;
        while (body_end < self.lines.items.len) : (body_end += 1) {
            const line = self.lines.items[body_end];
            if (line.start == self.input.len) break;
            const blank = line.content_start >= line.content_end;
            if (!blank and line.indent <= parent_indent) break;
            if (blank and nonblank_indent == null) {
                leading_blank_indent = @max(leading_blank_indent, line.indent);
            }
            body_line_count += 1;
            if (body_line_count > self.limits.scalar_line_count_max) {
                return self.resource(error.ScalarLineLimitExceeded, line.start);
            }
            if (!blank) {
                if (line.indent > self.limits.indentation_max) {
                    return self.resource(error.IndentationExceeded, line.start);
                }
                if (explicit_width) |required_indent| {
                    if (line.indent < required_indent) return self.syntax(line.content_start);
                } else if (nonblank_indent == null) {
                    if (leading_blank_indent > line.indent) return self.syntax(line.content_start);
                    nonblank_indent = line.indent;
                } else if (line.indent < nonblank_indent.?) {
                    return self.syntax(line.content_start);
                }
            }
        }
        const body_indent = explicit_width orelse nonblank_indent orelse leading_blank_indent;
        if (body_indent > self.limits.indentation_max) {
            return self.resource(error.IndentationExceeded, start);
        }
        if (body_indent > max_u32) return self.resource(error.InputTooLarge, start);
        const raw_end = if (body_end > body_start)
            self.lines.items[body_end - 1].next
        else
            end;
        const raw_length = raw_end - start;
        if (raw_length > self.limits.scalar_source_bytes_max) {
            return self.resource(error.ScalarSourceExceeded, start);
        }
        const event_index = try self.emit(.scalar, start, raw_length);
        const cooked_start = self.cooked.items.len;
        var sink = CookedSink{ .allocator = self.allocator, .bytes = &self.cooked, .limits = self.limits };
        self.cookBlock(&sink, body_start, body_end, body_indent, header.style) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.fail(err, errorKind(err), start);
        };
        applyChomping(&sink, header.chomping, cooked_start) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.fail(err, errorKind(err), start);
        };
        const cooked_length = self.cooked.items.len - cooked_start;
        if (cooked_start > max_u32 or cooked_length > max_u32) {
            return self.resource(error.CookedBytesExceeded, start);
        }
        self.metadata.items[event_index] = .{
            .raw_start = @intCast(start),
            .raw_length = @intCast(raw_length),
            .style = header.style,
            .chomping = header.chomping,
            .indentation = if (header.indent_width == null) .automatic else .explicit,
            .indentation_indicator = header.indent_indicator,
            .indentation_width = @intCast(body_indent),
            .ownership = .document_owned,
            .cooked_start = @intCast(cooked_start),
            .cooked_length = @intCast(cooked_length),
        };
        self.line_index = body_end;
    }

    fn cookBlock(
        self: *Parser,
        sink: *CookedSink,
        body_start: usize,
        body_end: usize,
        body_indent: usize,
        style: ScalarStyle,
    ) Error!void {
        if (style == .literal) {
            var index = body_start;
            while (index < body_end) : (index += 1) {
                const line = self.lines.items[index];
                const content_start = @min(line.start + body_indent, line.content_end);
                if (content_start < line.content_end) {
                    try sink.append(self.input[content_start..line.content_end]);
                }
                if (line.next > line.content_end) try sink.byte('\n');
            }
            return;
        }
        var emitted_content = false;
        var index = body_start;
        while (index < body_end) : (index += 1) {
            const line = self.lines.items[index];
            const content_start = @min(line.start + body_indent, line.content_end);
            if (content_start < line.content_end) {
                try sink.append(self.input[content_start..line.content_end]);
                emitted_content = true;
            }
            if (line.next <= line.content_end) continue;
            if (index + 1 >= body_end) {
                try sink.byte('\n');
                continue;
            }
            const next_line = self.lines.items[index + 1];
            const current_blank = content_start == line.content_end;
            const next_blank = next_line.content_start >= next_line.content_end;
            const current_more = line.indent > body_indent and !current_blank;
            const next_more = next_line.indent > body_indent and !next_blank;
            if (current_blank and !next_blank) {
                if (!emitted_content) try sink.byte('\n');
                continue;
            }
            if (next_blank or current_more or next_more) {
                try sink.byte('\n');
            } else {
                try sink.byte(' ');
            }
        }
    }

    fn consumedEnd(self: *const Parser, current: usize, fallback: usize) usize {
        if (self.line_index <= current) return fallback;
        var index = self.line_index - 1;
        while (index > current and self.lines.items[index].start == self.input.len) : (index -= 1) {}
        return self.lines.items[index].content_end;
    }
    fn lineAfterOffset(self: *const Parser, offset: usize, fallback: usize) usize {
        var index = fallback;
        while (index < self.lines.items.len and self.lines.items[index].next <= offset) : (index += 1) {}
        if (index < self.lines.items.len) {
            const line = self.lines.items[index];
            if (offset >= line.content_end) {
                return index + 1;
            }
            var cursor = offset;
            while (cursor < line.content_end and self.input[cursor] == ' ') : (cursor += 1) {}
            if (cursor >= line.content_end or self.input[cursor] == '#') {
                return index + 1;
            }
        }
        return index;
    }
    fn finish(self: *Parser) Error!Document {
        const tape = try self.tape.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(tape);
        const metadata = try self.metadata.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(metadata);
        const cooked = try self.cooked.toOwnedSlice(self.allocator);
        return .{
            .tape = tape,
            .source = self.input,
            .scalar_metadata = metadata,
            .cooked = cooked,
        };
    }
};

fn parseExtended(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
    failure: *?Failure,
) Error!Document {
    var parser = Parser.init(allocator, input, limits, failure);
    defer parser.deinit();
    parser.parseDocument() catch |err| return err;
    return parser.finish();
}

const BlockHeader = struct {
    style: ScalarStyle,
    chomping: Chomping,
    indent_indicator: u8,
    indent_width: ?usize,
};

fn parseBlockHeader(input: []const u8, start: usize, end: usize) Error!BlockHeader {
    if (start >= end or (input[start] != '|' and input[start] != '>')) return error.Invalid;
    const style: ScalarStyle = if (input[start] == '|') .literal else .folded;
    var pos = start + 1;
    var chomping: Chomping = .clip;
    var saw_chomping = false;
    var indent_indicator: u8 = 0;
    var saw_indent = false;
    while (pos < end and input[pos] != '#') {
        const byte = input[pos];
        if (byte == ' ') {
            pos += 1;
            continue;
        }
        if ((byte == '+' or byte == '-') and !saw_chomping) {
            chomping = if (byte == '+') .keep else .strip;
            saw_chomping = true;
            pos += 1;
            continue;
        }
        if (byte >= '1' and byte <= '9' and !saw_indent) {
            indent_indicator = byte - '0';
            saw_indent = true;
            pos += 1;
            continue;
        }
        return error.Invalid;
    }
    if (pos < end and input[pos] == '#') {
        if (pos > start and input[pos - 1] != ' ') return error.Invalid;
    }
    return .{
        .style = style,
        .chomping = chomping,
        .indent_indicator = indent_indicator,
        .indent_width = if (saw_indent) @as(usize, indent_indicator) else null,
    };
}

const CookedSink = struct {
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    limits: Limits,

    fn byte(self: *CookedSink, value: u8) Error!void {
        if (self.bytes.items.len >= self.limits.cooked_bytes_max) {
            return error.CookedBytesExceeded;
        }
        try self.bytes.append(self.allocator, value);
    }

    fn append(self: *CookedSink, values: []const u8) Error!void {
        if (values.len > self.limits.cooked_bytes_max -| self.bytes.items.len) {
            return error.CookedBytesExceeded;
        }
        try self.bytes.appendSlice(self.allocator, values);
    }

    fn codepoint(self: *CookedSink, value: u32) Error!void {
        if (value <= 0x7f) return self.byte(@intCast(value));
        if (value <= 0x7ff) {
            try self.byte(@intCast(0xc0 | (value >> 6)));
            try self.byte(@intCast(0x80 | (value & 0x3f)));
            return;
        }
        if (value <= 0xffff) {
            try self.byte(@intCast(0xe0 | (value >> 12)));
            try self.byte(@intCast(0x80 | ((value >> 6) & 0x3f)));
            try self.byte(@intCast(0x80 | (value & 0x3f)));
            return;
        }
        try self.byte(@intCast(0xf0 | (value >> 18)));
        try self.byte(@intCast(0x80 | ((value >> 12) & 0x3f)));
        try self.byte(@intCast(0x80 | ((value >> 6) & 0x3f)));
        try self.byte(@intCast(0x80 | (value & 0x3f)));
    }
};

fn decodeQuoted(
    sink: *CookedSink,
    raw: []const u8,
    style: ScalarStyle,
) Error!void {
    const output_start = sink.bytes.items.len;
    try decodeQuotedRange(sink, raw, 0, raw.len, style, output_start);
}

fn decodeQuotedRange(
    sink: *CookedSink,
    input: []const u8,
    start: usize,
    end: usize,
    style: ScalarStyle,
    output_start: usize,
) Error!void {
    if (end <= start + 1) return;
    var pos = start + 1;
    const close = end - 1;
    var fold_trim_start = output_start;
    while (pos < close) {
        const byte = input[pos];
        if (style == .single_quoted) {
            if (byte == '\'' and pos + 1 < close and input[pos + 1] == '\'') {
                try sink.byte('\'');
                fold_trim_start = sink.bytes.items.len;
                pos += 2;
                continue;
            }
            if (byte == '\n' or byte == '\r') {
                pos = try appendFoldBreak(sink, input, pos, close, fold_trim_start);
                fold_trim_start = sink.bytes.items.len;
                continue;
            }
            try sink.byte(byte);
            if (byte != ' ' and byte != '\t') fold_trim_start = sink.bytes.items.len;
            pos += 1;
            continue;
        }
        if (byte == '\\') {
            if (pos + 1 >= close) return error.Invalid;
            const escape = input[pos + 1];
            if (escape == '\n' or escape == '\r') {
                pos += 2;
                if (escape == '\r' and pos < close and input[pos] == '\n') pos += 1;
                while (pos < close and (input[pos] == ' ' or input[pos] == '\t')) : (pos += 1) {}
                fold_trim_start = sink.bytes.items.len;
                continue;
            }
            pos = try decodeEscape(sink, input, pos, close);
            fold_trim_start = sink.bytes.items.len;
            continue;
        }
        if (byte == '\n' or byte == '\r') {
            pos = try appendFoldBreak(sink, input, pos, close, fold_trim_start);
            fold_trim_start = sink.bytes.items.len;
            continue;
        }
        try sink.byte(byte);
        if (byte != ' ' and byte != '\t') fold_trim_start = sink.bytes.items.len;
        pos += 1;
    }
}

fn appendFoldBreak(
    sink: *CookedSink,
    input: []const u8,
    start: usize,
    end: usize,
    output_start: usize,
) Error!usize {
    while (sink.bytes.items.len > output_start) {
        const last = sink.bytes.items[sink.bytes.items.len - 1];
        if (last != ' ' and last != '\t') break;
        _ = sink.bytes.pop();
    }
    var pos = start;
    var breaks: usize = 0;
    while (pos < end and (input[pos] == '\n' or input[pos] == '\r')) {
        breaks += 1;
        if (input[pos] == '\r' and pos + 1 < end and input[pos + 1] == '\n') {
            pos += 2;
        } else {
            pos += 1;
        }
        while (pos < end and (input[pos] == ' ' or input[pos] == '\t')) : (pos += 1) {}
    }
    if (breaks == 1) {
        try sink.byte(' ');
    } else {
        var newline_count: usize = breaks - 1;
        while (newline_count > 0) : (newline_count -= 1) {
            try sink.byte('\n');
        }
    }
    return pos;
}

fn invalidQuotedOffset(input: []const u8, start: usize, end: usize, style: ScalarStyle) usize {
    if (style == .single_quoted) return start;
    var index = start + 1;
    const close = if (end > start) end - 1 else end;
    while (index < close) : (index += 1) {
        if (input[index] != '\\') continue;
        if (index + 1 >= close) return index;
        const escape = input[index + 1];
        if (escape == '\n' or escape == '\r') {
            index += 1;
            continue;
        }
        if (escape == '0' or escape == 'a' or escape == 'b' or escape == 't' or
            escape == 'n' or escape == 'v' or escape == 'f' or escape == 'r' or
            escape == 'e' or escape == ' ' or escape == '\"' or escape == '/' or
            escape == '\\' or escape == 'N' or escape == '_' or escape == 'L' or
            escape == 'P')
        {
            index += 1;
            continue;
        }
        if (escape == 'x' or escape == 'u' or escape == 'U') {
            const count: usize = if (escape == 'x') 2 else if (escape == 'u') 4 else 8;
            if (close -| (index + 2) < count) return index;
            var digit_index: usize = 0;
            while (digit_index < count) : (digit_index += 1) {
                if (hexValue(input[index + 2 + digit_index]) == null) return index + 2 + digit_index;
            }
            index += 1 + count;
            continue;
        }
        return index;
    }
    return start;
}

fn decodeEscape(sink: *CookedSink, input: []const u8, start: usize, end: usize) Error!usize {
    const escape = input[start + 1];
    switch (escape) {
        '0' => try sink.byte(0),
        'a' => try sink.byte(0x07),
        'b' => try sink.byte(0x08),
        't' => try sink.byte(0x09),
        'n' => try sink.byte(0x0a),
        'v' => try sink.byte(0x0b),
        'f' => try sink.byte(0x0c),
        'r' => try sink.byte(0x0d),
        'e' => try sink.byte(0x1b),
        ' ' => try sink.byte(' '),
        '"' => try sink.byte('"'),
        '/' => try sink.byte('/'),
        '\\' => try sink.byte('\\'),
        'N' => try sink.codepoint(0x85),
        '_' => try sink.codepoint(0xa0),
        'L' => try sink.codepoint(0x2028),
        'P' => try sink.codepoint(0x2029),
        'x', 'u', 'U' => {
            const count: usize = switch (escape) {
                'x' => 2,
                'u' => 4,
                else => 8,
            };
            if (end - (start + 2) < count) return error.Invalid;
            var value: u32 = 0;
            var index: usize = 0;
            while (index < count) : (index += 1) {
                const digit = hexValue(input[start + 2 + index]) orelse return error.Invalid;
                value = (value << 4) | digit;
            }
            if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return error.Invalid;
            try sink.codepoint(value);
            return start + 2 + count;
        },
        else => return error.Invalid,
    }
    return start + 2;
}

fn applyChomping(sink: *CookedSink, chomping: Chomping, start: usize) Error!void {
    if (start > sink.bytes.items.len) return error.InvalidStructure;
    switch (chomping) {
        .keep => {},
        .strip => while (sink.bytes.items.len > start and sink.bytes.items[sink.bytes.items.len - 1] == '\n') {
            sink.bytes.items.len -= 1;
        },
        .clip => {
            var had_break = false;
            while (sink.bytes.items.len > start and sink.bytes.items[sink.bytes.items.len - 1] == '\n') {
                sink.bytes.items.len -= 1;
                had_break = true;
            }
            if (had_break and sink.bytes.items.len > start) try sink.byte('\n');
        },
    }
}

fn hexValue(byte: u8) ?u32 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn visibleEnd(input: []const u8, line: Line) usize {
    return trimComment(input, line.content_start, line.content_end);
}

fn trimComment(input: []const u8, start: usize, end: usize) usize {
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
        if (byte == '[' or byte == '{') flow_depth += 1;
        if (byte == ']' or byte == '}') flow_depth -|= 1;
        if (byte == '#' and flow_depth == 0 and (index == start or input[index - 1] == ' ')) {
            return trimSpaces(input, start, index);
        }
    }
    return trimSpaces(input, start, end);
}

fn findColon(input: []const u8, start: usize, end: usize) ?usize {
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
        if (byte == ':' and flow_depth == 0 and
            (index + 1 == end or input[index + 1] == ' ' or input[index + 1] == '#' or
                input[index + 1] == '[' or input[index + 1] == '{'))
        {
            return index;
        }
    }
    return null;
}

fn trimSpaces(input: []const u8, start: usize, end: usize) usize {
    var result = end;
    while (result > start and input[result - 1] == ' ') : (result -= 1) {}
    return result;
}

fn isSequenceEntry(input: []const u8, start: usize, end: usize) bool {
    if (start >= end or input[start] != '-') return false;
    if (start + 1 == end) return true;
    return input[start + 1] == ' ' or input[start + 1] == '#';
}

fn startsUnsupported(input: []const u8, start: usize, end: usize) bool {
    if (start >= end) return false;
    return switch (input[start]) {
        '%', '!', '&', '*', '?', '@', '`' => true,
        else => false,
    };
}

fn isMarker(input: []const u8, line: Line, marker: []const u8) bool {
    if (line.indent != 0) return false;
    const end = visibleEnd(input, line);
    if (end - line.content_start < marker.len) return false;
    if (!std.mem.eql(u8, input[line.content_start .. line.content_start + marker.len], marker)) return false;
    return end == line.content_start + marker.len;
}

fn requiresExtendedParser(input: []const u8) bool {
    var quote: u8 = 0;
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (quote == '\'') {
            if (byte == '\'' and index + 1 < input.len and input[index + 1] == '\'') {
                index += 1;
            } else if (byte == '\'') {
                quote = 0;
            } else if (byte == '\n' or byte == '\r') {
                return true;
            }
            continue;
        }
        if (quote == '"') {
            if (byte == '\\') {
                if (index + 1 >= input.len) return true;
                const escaped = input[index + 1];
                const json_escape = escaped == '\"' or escaped == '/' or escaped == '\\' or
                    escaped == 'b' or escaped == 'f' or escaped == 'n' or
                    escaped == 'r' or escaped == 't' or escaped == 'u';
                if (!json_escape or escaped == '\n' or escaped == '\r') return true;
                index += 1;
            } else if (byte == '"') {
                quote = 0;
            } else if (byte == '\n' or byte == '\r') {
                return true;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '\n' or byte == '\r') continue;
        if ((byte == '|' or byte == '>') and index > 0) {
            var before = index;
            while (before > 0 and input[before - 1] == ' ') : (before -= 1) {}
            if (before > 0 and input[before - 1] == ':') return true;
        }
    }

    var line_start: usize = if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) 3 else 0;
    while (line_start < input.len) {
        var line_end = line_start;
        while (line_end < input.len and input[line_end] != '\n' and input[line_end] != '\r') : (line_end += 1) {}
        var content = line_start;
        while (content < line_end and input[content] == ' ') : (content += 1) {}
        if (content < line_end and (input[content] == '|' or input[content] == '>')) return true;
        if (content < line_end and input[content] == '-') {
            var value_start = content + 1;
            while (value_start < line_end and input[value_start] == ' ') : (value_start += 1) {}
            if (value_start < line_end and (input[value_start] == '|' or input[value_start] == '>')) {
                return true;
            }
            if (findColon(input, value_start, line_end) != null) return true;
        }
        if (line_end >= input.len) break;
        line_start = line_end + 1;
        if (input[line_end] == '\r' and line_start < input.len and input[line_start] == '\n') line_start += 1;
    }
    return false;
}
