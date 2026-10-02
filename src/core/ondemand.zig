const std = @import("std");
const stage1 = @import("stage1.zig");
const stage2 = @import("stage2.zig");

const testing = std.testing;

pub const max_depth: usize = 1024;
const sentinel_count: usize = 3;

pub const Error = std.mem.Allocator.Error || error{
    CapacityOverflow,
    CapacityExceeded,
    DocumentActive,
    DocumentReleased,
    DuplicateKey,
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
    token_reader: stage2.TokenReader,
    generation: u64 = 0,
    document_active: bool = false,
    focus: Focus = .none,
    event_cached: ?stage2.ParsedToken = null,
    event_epoch: u64 = 0,
    position_index: usize = 0,
    depth: usize = 0,
    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) InitError!Parser {
        if (max_capacity > std.math.maxInt(u32)) return error.InputTooLarge;
        const index_capacity = std.math.add(
            usize,
            max_capacity,
            sentinel_count,
        ) catch return error.CapacityOverflow;

        const indexes = try allocator.alloc(u32, index_capacity);
        // An empty input with no global offsets satisfies every check in
        // `IndexView.init`: the length bound, the `base_offset + limit` sum, and
        // the monotonicity loop, which has no elements to inspect. `InitError`
        // cannot carry `IndexView.Error` without widening this error set, so an
        // unexpected failure is reported rather than propagated.
        const empty_view = stage2.IndexView.init(&.{}, &.{}, 0) catch |err| {
            std.debug.panic(
                "empty IndexView.init failed: {s}",
                .{@errorName(err)},
            );
        };
        // `TokenReader.init` only validates the view against its input, and both
        // are empty with a zero base offset, so `ReaderError` is unreachable
        // here for the same reason as above.
        const empty_reader = stage2.TokenReader.init(&.{}, empty_view, .json) catch |err| {
            std.debug.panic(
                "empty TokenReader.init failed: {s}",
                .{@errorName(err)},
            );
        };
        return .{
            .allocator = allocator,
            .indexes = indexes,
            .capacity = max_capacity,
            .grow_on_demand = max_capacity == 0,
            .token_reader = empty_reader,
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
        return self.completeOwnedDocument(input, token_count, .json);
    }

    /// Completes a JSON-family document using the requested dialect.
    pub fn completeDialectDocument(
        self: *Parser,
        input: []const u8,
        token_count: usize,
        dialect: stage2.Dialect,
    ) Error!Document {
        return self.completeOwnedDocument(input, token_count, dialect);
    }

    fn completeOwnedDocument(
        self: *Parser,
        input: []const u8,
        token_count: usize,
        dialect: stage2.Dialect,
    ) Error!Document {
        if (self.document_active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        try self.ensureCapacity(input.len, token_count);
        return self.finishOwnedDocument(input, token_count, dialect);
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
        return self.finishOwnedDocument(input, structural_index.count, .json);
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
        dialect: stage2.Dialect,
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

        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        const sentinel: u32 = @intCast(input.len);
        self.indexes[token_count..][0..sentinel_count].* = .{
            sentinel,
            sentinel,
            0,
        };
        try validateIndexes(input, self.indexes, token_count);

        const view = try stage2.IndexView.init(input, self.indexes[0..token_count], 0);
        try self.token_reader.reset(input, view, dialect);
        self.focus = .none;
        self.event_cached = null;
        self.event_epoch = 0;
        self.position_index = 0;
        self.depth = 0;

        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.document_active = true;

        return .{
            .parser = self,
            .input = input,
            .indexes = self.indexes[0..source_count],
            .token_count = token_count,
            .generation = self.generation,
            .dialect = dialect,
            .index_view = view,
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
    dialect: stage2.Dialect,
    index_view: stage2.IndexView,

    pub fn deinit(self: *Document) void {
        if (self.parser.document_active and self.parser.generation == self.generation) {
            self.parser.document_active = false;
            self.parser.focus = .none;
            self.parser.event_cached = null;
            self.parser.event_epoch = 0;
            self.parser.position_index = 0;
            self.parser.depth = 0;
        }
        self.* = undefined;
    }

    pub fn tokenCursor(self: *Document) Error!TokenCursor {
        try self.claimFocus(.cursor);
        return .{
            .document = self,
            .parser = self.parser,
            .generation = self.generation,
            .expected_position = self.parser.position_index,
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
        if (self.parser.focus != .none) return error.FocusAlreadyClaimed;
        self.parser.focus = focus;
    }
};

pub const Token = struct {
    offset: u32,
    byte: u8,
};

pub const TokenCursor = struct {
    document: *Document,
    parser: *Parser,
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
        self.parser.position_index = self.expected_position;
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
        if (self.parser.depth <= parent_depth_usize) return;

        var steps: usize = 0;
        while (self.parser.depth > parent_depth_usize) {
            if (steps >= self.document.token_count) return error.UnexpectedEnd;
            _ = try self.advance() orelse return error.UnexpectedEnd;
            steps += 1;
        }
    }

    fn ensureFocused(self: *const TokenCursor) Error!void {
        if (!self.parser.document_active) return error.DocumentReleased;
        if (self.parser.generation != self.generation) return error.DocumentReleased;
        if (self.parser.focus != self.owner) return error.FocusLost;
        if (self.parser.position_index != self.expected_position) {
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
                if (self.parser.depth >= max_depth) return error.DepthExceeded;
                self.parser.depth += 1;
            },
            '}', ']' => {
                if (self.parser.depth == 0) return error.UnexpectedToken;
                self.parser.depth -= 1;
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

pub const EventReader = struct {
    document: *Document,
    parser: *Parser,
    generation: u64,
    expected_epoch: u64,
    pub fn init(document: *Document) Error!EventReader {
        try document.claimFocus(.event_reader);
        return .{
            .document = document,
            .parser = document.parser,
            .generation = document.generation,
            .expected_epoch = document.parser.event_epoch,
        };
    }

    pub fn next(self: *EventReader) Error!?Event {
        const token = try self.nextParsed() orelse return null;
        const event = try eventFromToken(token);
        self.advanceEpoch();
        return event;
    }

    pub fn peek(self: *const EventReader) Error!?Event {
        try self.ensureFocused();
        if (self.parser.event_cached == null) {
            self.parser.event_cached = try self.parser.token_reader.next();
        }
        const token = self.parser.event_cached orelse return null;
        const value = try eventFromToken(token);
        return value;
    }

    pub fn skip(self: *EventReader) Error!void {
        const first = try self.next() orelse return;
        var open_count: usize = switch (first) {
            .object_start, .array_start => 1,
            else => return,
        };

        var steps: usize = 0;
        const max_steps = std.math.add(usize, self.document.input.len, 1) catch
            std.math.maxInt(usize);
        while (open_count > 0) {
            if (steps >= max_steps) return error.UnexpectedEnd;
            const event = try self.next() orelse return error.UnexpectedEnd;
            switch (event) {
                .object_start, .array_start => open_count += 1,
                .object_end, .array_end => open_count -= 1,
                else => {},
            }
            steps += 1;
        }
    }

    fn nextParsed(self: *EventReader) Error!?stage2.ParsedToken {
        try self.ensureFocused();
        if (self.parser.event_cached) |token| {
            self.parser.event_cached = null;
            return token;
        }
        return self.parser.token_reader.next();
    }

    fn advanceEpoch(self: *EventReader) void {
        self.parser.event_epoch +%= 1;
        if (self.parser.event_epoch == 0) self.parser.event_epoch = 1;
        self.expected_epoch = self.parser.event_epoch;
    }

    fn ensureFocused(self: *const EventReader) Error!void {
        if (!self.parser.document_active) return error.DocumentReleased;
        if (self.parser.generation != self.generation) return error.DocumentReleased;
        if (self.parser.focus != .event_reader) return error.FocusLost;
        if (self.parser.event_epoch != self.expected_epoch) {
            return error.OutOfOrderIteration;
        }
    }
};

fn eventFromToken(token: stage2.ParsedToken) Error!Event {
    return switch (token.word.tapeKind()) {
        .object_start => .object_start,
        .object_end => .object_end,
        .array_start => .array_start,
        .array_end => .array_end,
        .key => .{ .key = token.raw },
        .string => .{ .string = token.raw },
        .number => .{ .number = token.raw },
        .true_literal => .{ .bool = true },
        .false_literal => .{ .bool = false },
        .null_literal => .null,
    };
}

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

    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    const sentinel: u32 = @intCast(input.len);
    if (indexes[count] != sentinel) return error.InvalidStructuralIndex;
    if (indexes[count + 1] != sentinel) return error.InvalidStructuralIndex;
    if (indexes[count + 2] != 0) return error.InvalidStructuralIndex;
}

fn isWhitespace(byte: u8) bool {
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

    try testing.expectEqual(@as(u8, '['), ((try cursor.advance()) orelse return error.TestUnexpectedResult).byte);
    try testing.expectEqual(@as(u8, '1'), ((try cursor.advance()) orelse return error.TestUnexpectedResult).byte);
    try testing.expectEqual(@as(u8, ','), ((try cursor.advance()) orelse return error.TestUnexpectedResult).byte);
    try testing.expectEqual(@as(u8, '{'), ((try cursor.advance()) orelse return error.TestUnexpectedResult).byte);
    try cursor.skipChild(1);
    try testing.expectEqual(@as(u8, ','), ((try cursor.peek()) orelse return error.TestUnexpectedResult).byte);

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

    try expectEvent(.object_start, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .key = "text" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .string = "a\\\"b" }, (try reader.peek()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .string = "a\\\"b" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .key = "n" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .number = "-12.5" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .key = "ok" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .bool = true }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .key = "none" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.null, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .key = "a" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.array_start, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .bool = false }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.array_end, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.object_end, (try reader.next()) orelse return error.TestUnexpectedResult);
    try testing.expect((try reader.next()) == null);
}

test "EventReader keeps failed peek sticky" {
    const input = "[,]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    defer document.deinit();
    var reader = try document.eventReader();

    try expectEvent(.array_start, (try reader.next()) orelse return error.TestUnexpectedResult);
    try testing.expectError(error.UnexpectedToken, reader.peek());
    try testing.expectError(error.UnexpectedToken, reader.next());
}

test "copied Document cannot claim shared event reader" {
    const input = "[1]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    defer document.deinit();
    var copied = document;

    var reader = try document.eventReader();
    try testing.expectError(error.FocusAlreadyClaimed, copied.eventReader());
    try expectEvent(.array_start, (try reader.next()) orelse return error.TestUnexpectedResult);
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
        try expectEvent(.array_start, (try reader.next()) orelse return error.TestUnexpectedResult);
    }
    try testing.expectError(error.DepthExceeded, reader.next());
}

test "EventReader handles zero-index quoted dialect roots" {
    const cases = [_]struct {
        input: []const u8,
        dialect: stage2.Dialect,
    }{
        .{ .input = "\"hello\"", .dialect = .jsonc },
        .{ .input = "'hello'", .dialect = .json5 },
    };

    for (cases) |case| {
        var parser = try Parser.init(testing.allocator, case.input.len);
        defer parser.deinit();
        _ = try parser.prepareDocument(case.input);
        var document = try parser.completeDialectDocument(case.input, 0, case.dialect);
        defer document.deinit();
        var reader = try document.eventReader();

        const raw = case.input[1 .. case.input.len - 1];
        const event = (try reader.next()) orelse return error.TestUnexpectedResult;
        try expectEvent(.{ .string = raw }, event);
        switch (event) {
            .string => |actual| try testing.expect(actual.ptr == raw.ptr),
            else => unreachable,
        }
        try testing.expect((try reader.next()) == null);
    }
}

test "EventReader completes JSONC comments and JSON5 syntax" {
    const cases = [_]struct {
        input: []const u8,
        offsets: []const u32,
        dialect: stage2.Dialect,
    }{
        .{
            .input = "{\"a\":1/*x*/}",
            .offsets = &.{ 0, 4, 5, 11 },
            .dialect = .jsonc,
        },
        .{
            .input = "{a:'x',}",
            .offsets = &.{ 0, 1, 2, 6, 7 },
            .dialect = .json5,
        },
    };

    for (cases) |case| {
        var parser = try Parser.init(testing.allocator, case.input.len);
        defer parser.deinit();
        const slots = try parser.prepareDocument(case.input);
        @memcpy(slots[0..case.offsets.len], case.offsets);
        var document = try parser.completeDialectDocument(
            case.input,
            case.offsets.len,
            case.dialect,
        );
        defer document.deinit();
        var reader = try document.eventReader();

        try expectEvent(.object_start, (try reader.next()) orelse return error.TestUnexpectedResult);
        try expectEvent(.{ .key = "a" }, (try reader.next()) orelse return error.TestUnexpectedResult);
        if (case.dialect == .jsonc) {
            try expectEvent(.{ .number = "1" }, (try reader.next()) orelse return error.TestUnexpectedResult);
        } else {
            try expectEvent(.{ .string = "x" }, (try reader.next()) orelse return error.TestUnexpectedResult);
        }
        try expectEvent(.object_end, (try reader.next()) orelse return error.TestUnexpectedResult);
        try testing.expect((try reader.next()) == null);
    }
}

test "EventReader rejects copies and released documents before source access" {
    const input = "[0]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    var reader = try document.eventReader();
    var copied = reader;

    try expectEvent(.array_start, (try reader.next()) orelse return error.TestUnexpectedResult);
    try testing.expectError(error.OutOfOrderIteration, copied.next());

    document.deinit();
    try testing.expectError(error.DocumentReleased, reader.next());
    try testing.expectError(error.DocumentReleased, copied.next());

    var reused = try parser.initDocument(input, &structural_index);
    defer reused.deinit();
    try testing.expectError(error.DocumentReleased, reader.next());
}
