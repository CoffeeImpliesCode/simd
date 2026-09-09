const std = @import("std");
const simd = @import("../core/simd.zig");
const json_lexical = @import("../core/json_lexical.zig");
const stage1 = @import("../core/stage1.zig");
const stream = @import("../core/stream.zig");
const resident = @import("../core/resident.zig");
const stage2 = @import("../core/stage2.zig");

/// Initializes a chunk-fed JSONL Stage 1 indexer with LF framing enabled.
pub fn initStreamIndexer(
    allocator: std.mem.Allocator,
    chunk_len: usize,
) stream.StreamIndexer.InitError!stream.StreamIndexer {
    return stream.StreamIndexer.init(
        allocator,
        chunk_len,
        stream.Options{ .dialect = .json, .mode = .jsonl },
    );
}

/// One validated JSONL record. The source is a caller-backed view and the tape
/// is owned by the record document, so a cursor cannot cross record boundaries.
pub const JsonlRecord = struct {
    source: []const u8,
    source_start: usize,
    source_end: usize,
    document: stage2.Document,

    pub fn root(self: *const JsonlRecord) stage2.NavigationError!stage2.TapeCursor {
        return self.document.root(self.source);
    }

    pub fn cursor(self: *const JsonlRecord) stage2.NavigationError!stage2.TapeCursor {
        return self.root();
    }

    pub fn deinit(self: *JsonlRecord, allocator: std.mem.Allocator) void {
        self.document.deinit(allocator);
        self.* = undefined;
    }
};

/// An owned collection of independently validated JSONL records.
///
/// The input and each record source are borrowed from the caller. The record
/// tapes and metadata are owned by this document.
pub const JsonlDocument = struct {
    input: []const u8,
    records: []JsonlRecord,

    pub fn record(self: *const JsonlDocument, index: usize) ?*const JsonlRecord {
        if (index >= self.records.len) return null;
        return &self.records[index];
    }

    pub fn cursor(
        self: *const JsonlDocument,
        index: usize,
    ) stage2.NavigationError!stage2.TapeCursor {
        const record_value = self.record(index) orelse return error.PositionOutOfBounds;
        return record_value.root();
    }

    pub fn deinit(self: *JsonlDocument, allocator: std.mem.Allocator) void {
        for (self.records) |*record_value| {
            record_value.deinit(allocator);
        }
        allocator.free(self.records);
        self.* = undefined;
    }
};

/// A first-error diagnostic with both record and global source coordinates.
pub const JsonlDiagnostic = struct {
    record_index: usize,
    source_start: usize,
    source_end: usize,
    err: stage2.Error,
    byte_offset: usize,
    line: u32,
    column: u32,
    snippet: []const u8,
    snippet_start: usize,
};

/// A lazy JSONL event with a source-backed raw span and global offset.
pub const EventKind = enum {
    record_start,
    record_end,
    object_start,
    object_end,
    array_start,
    array_end,
    key,
    string,
    number,
    true_literal,
    false_literal,
    null_literal,
};

pub const Event = struct {
    kind: EventKind,
    record_index: u32,
    offset: u32,
    raw: []const u8,
};

pub const Parser = struct {
    pub const InitError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };

    allocator: std.mem.Allocator,
    storage: resident.IndexBuffer(void, false),
    indexes: []u32,
    capacity: usize,
    max_capacity: usize,
    state: resident.State = .{},

    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) InitError!Parser {
        if (max_capacity > std.math.maxInt(u32)) return error.InputTooLarge;

        var parser = Parser{
            .allocator = allocator,
            .storage = resident.IndexBuffer(void, false).init(allocator),
            .indexes = &.{},
            .capacity = 0,
            .max_capacity = max_capacity,
        };
        errdefer parser.storage.deinit();

        if (max_capacity != 0) {
            try parser.storage.reserve(max_capacity);
            parser.indexes = parser.storage.indexes;
            parser.capacity = parser.storage.capacity;
        }
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        std.debug.assert(!self.state.active);
        self.state.deinit();
        self.storage.deinit();
        self.* = undefined;
    }

    fn prepare(self: *Parser, input: []const u8) ![]const u32 {
        if (self.state.active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        if (self.max_capacity != 0 and input.len > self.max_capacity) {
            return error.CapacityExceeded;
        }

        try self.storage.reserve(input.len);
        self.indexes = self.storage.indexes;
        self.capacity = self.storage.capacity;

        const output = self.storage.indexes[0 .. self.storage.indexes.len - sentinel_count];
        const count = try indexJsonlInto(simd.default_vector_len, output, input);
        try self.storage.finish(count, input.len);
        return self.storage.indexes[0..count];
    }
};

pub fn initOnDemandDocument(
    parser: *Parser,
    input: []const u8,
) !OnDemandDocument {
    const indexes = try parser.prepare(input);
    const lease = try parser.state.begin();
    return .{
        .parser = parser,
        .input = input,
        .indexes = indexes,
        .lease = lease,
    };
}

pub const OnDemandDocument = struct {
    parser: *Parser,
    input: []const u8,
    indexes: []const u32,
    lease: resident.Lease,

    pub fn deinit(self: *OnDemandDocument) void {
        self.lease.release();
        self.* = undefined;
    }

    pub fn eventReader(self: *OnDemandDocument) !EventReader {
        const guard = try self.lease.claim();
        return EventReader.init(self, guard);
    }

    pub fn tokenCursor(self: *OnDemandDocument) !TokenCursor {
        const guard = try self.lease.claim();
        return TokenCursor.init(self, guard);
    }
};

pub const TapeRecordInitError = std.mem.Allocator.Error || error{
    CapacityOverflow,
    InputTooLarge,
    TapeTooLarge,
};

pub const TapeRecordError = std.mem.Allocator.Error || resident.Error ||
    stage2.NavigationError || error{
    CapacityExceeded,
    CapacityOverflow,
    InputTooLarge,
    TapeTooLarge,
    InvalidStructuralIndex,
};

pub const TapeRecordResult = union(enum) {
    record: TapeRecord,
    diagnostic: JsonlDiagnostic,
};

/// Configuration for the reusable strict-LF JSONL record parser.
///
/// A zero limit means that the corresponding resource may grow to the checked
/// u32 boundary. Tape capacity is measured in `stage2.TapeWord` values.
pub const TapeRecordOptions = struct {
    input_capacity_max: usize = 0,
    tape_capacity_max: usize = 0,
};

/// A reusable parser for sequential, strict-LF JSONL records.
///
/// The parser owns the global structural index and one high-water tape. Source
/// bytes are borrowed from the caller. A record and every cursor made from it
/// become invalid when the iterator advances, is deinitialized, or the parser
/// resets.
pub const TapeRecordParser = struct {
    allocator: std.mem.Allocator,
    options: TapeRecordOptions,
    storage: resident.IndexBuffer(void, false),
    tape_storage: []stage2.TapeWord,
    tape_len: usize = 0,
    reader: ?stage2.TokenReader = null,
    state: resident.State = .{},
    record_generation: u64 = 0,
    input: []const u8 = &.{},

    pub const InitError = TapeRecordInitError;

    pub fn init(
        allocator: std.mem.Allocator,
        options: TapeRecordOptions,
    ) InitError!TapeRecordParser {
        if (options.input_capacity_max > std.math.maxInt(u32)) {
            return error.InputTooLarge;
        }
        if (options.tape_capacity_max > std.math.maxInt(u32)) {
            return error.TapeTooLarge;
        }

        var parser = TapeRecordParser{
            .allocator = allocator,
            .options = options,
            .storage = resident.IndexBuffer(void, false).init(allocator),
            .tape_storage = &.{},
        };
        errdefer parser.storage.deinit();

        if (options.input_capacity_max != 0) {
            try parser.storage.reserve(options.input_capacity_max);
            parser.storage.count = 0;
        }
        return parser;
    }

    pub fn deinit(self: *TapeRecordParser) void {
        self.releaseLease();
        self.state.deinit();
        self.storage.deinit();
        if (self.tape_storage.len != 0) {
            self.allocator.free(self.tape_storage);
        }
        self.* = undefined;
    }

    /// Invalidates all borrowed records and releases the active iterator.
    pub fn reset(self: *TapeRecordParser) void {
        self.releaseLease();
        self.storage.count = 0;
        self.tape_len = 0;
        self.reader = null;
        self.input = &.{};
        self.nextRecordGeneration();
    }

    pub fn tapeCapacity(self: *const TapeRecordParser) usize {
        return self.tape_storage.len;
    }

    pub fn inputCapacity(self: *const TapeRecordParser) usize {
        return self.storage.capacity;
    }

    pub fn iterate(
        self: *TapeRecordParser,
        input: []const u8,
    ) (TapeRecordError || error{DocumentActive})!TapeRecordIterator {
        if (self.state.active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        if (self.options.input_capacity_max != 0 and
            input.len > self.options.input_capacity_max)
        {
            return error.CapacityExceeded;
        }

        try self.storage.reserve(input.len);
        const count = indexJsonlInto(
            simd.default_vector_len,
            self.storage.indexes[0 .. self.storage.indexes.len - sentinel_count],
            input,
        ) catch |err| switch (err) {
            error.InputTooLarge => return error.InputTooLarge,
            error.CapacityExceeded => return error.CapacityExceeded,
            error.NonContiguousInput => unreachable,
        };
        try self.storage.finish(count, input.len);
        self.input = input;
        self.tape_len = 0;
        self.nextRecordGeneration();

        const lease = try self.state.begin();
        errdefer lease.release();
        const guard = try lease.claim();
        return .{
            .parser = self,
            .lease = lease,
            .guard = guard,
            .record_iterator = RecordIterator.init(
                input,
                self.storage.indexes[0..self.storage.count],
            ),
        };
    }

    fn releaseLease(self: *TapeRecordParser) void {
        self.state.active = false;
        self.state.claimed = false;
        self.state.position = 0;
    }

    fn nextRecordGeneration(self: *TapeRecordParser) void {
        self.record_generation = if (self.record_generation == std.math.maxInt(u64))
            1
        else
            self.record_generation + 1;
    }

    fn invalidateRecord(self: *TapeRecordParser) void {
        self.tape_len = 0;
        self.nextRecordGeneration();
    }

    fn checkRecord(
        self: *const TapeRecordParser,
        lease: resident.Lease,
        generation: u64,
    ) TapeRecordError!void {
        try lease.check();
        if (self.record_generation != generation) {
            return error.OutOfOrderIteration;
        }
    }

    fn recordView(
        self: *TapeRecordParser,
        source: []const u8,
        view: stage2.IndexView,
        record_range: RecordRange,
        record_index: usize,
        lease: resident.Lease,
        generation: u64,
    ) TapeRecordError!TapeRecordResult {
        var tape_allocator = TapeReuseAllocator{ .parser = self };
        const document = stage2.buildTapeView(
            tape_allocator.allocator(),
            source,
            view,
            .json,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                if (tape_allocator.denied) return error.CapacityExceeded;
                return error.OutOfMemory;
            },
            error.TapeTooLarge => return error.TapeTooLarge,
            error.InvalidStructuralIndex => return error.InvalidStructuralIndex,
            else => {
                const diagnostic = try self.validateRecord(source, view);
                if (diagnostic) |value| {
                    return .{ .diagnostic = globalRecordDiagnostic(
                        self.input,
                        record_range,
                        record_index,
                        value,
                    ) };
                }
                return error.InvalidStructuralIndex;
            },
        };
        self.tape_len = document.tape.len;
        return .{
            .record = .{
                .parser = self,
                .lease = lease,
                .generation = generation,
                .record_index = record_index,
                .source = source,
                .source_start = record_range.source_start,
                .source_end = record_range.source_end,
                .tape_start = 0,
                .tape_end = document.tape.len,
            },
        };
    }
    fn validateRecord(
        self: *TapeRecordParser,
        source: []const u8,
        view: stage2.IndexView,
    ) TapeRecordError!?stage2.Diagnostic {
        // Reader setup only checks the index view; next() reports syntax failures.
        if (self.reader) |*reader| {
            reader.reset(source, view, .json) catch |err| return @errorCast(err);
        } else {
            self.reader = stage2.TokenReader.init(source, view, .json) catch |err| return @errorCast(err);
        }
        var reader = &self.reader.?;
        while (true) {
            const token = reader.next() catch |err| {
                if (err == error.TapeTooLarge) return error.TapeTooLarge;
                if (err == error.InvalidStructuralIndex) {
                    return error.InvalidStructuralIndex;
                }
                return stage2.diagnosticAt(
                    source,
                    @errorCast(err),
                    reader.failure_offset,
                );
            };
            if (token == null) return null;
        }
    }
};

const TapeReuseAllocator = struct {
    parser: *TapeRecordParser,
    denied: bool = false,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    };

    fn allocator(self: *TapeReuseAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        byte_len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TapeReuseAllocator = @ptrCast(@alignCast(context));
        if (byte_len % @sizeOf(stage2.TapeWord) != 0) return null;
        const word_count = byte_len / @sizeOf(stage2.TapeWord);
        if (self.parser.options.tape_capacity_max != 0 and
            word_count > self.parser.options.tape_capacity_max)
        {
            self.denied = true;
            return null;
        }

        if (word_count <= self.parser.tape_storage.len and word_count != 0) {
            return @ptrCast(self.parser.tape_storage.ptr);
        }
        if (word_count == 0) return null;

        const byte_ptr = self.parser.allocator.rawAlloc(
            byte_len,
            alignment,
            return_address,
        ) orelse return null;
        const tape_ptr: [*]stage2.TapeWord = @ptrCast(@alignCast(byte_ptr));
        const new_storage = tape_ptr[0..word_count];
        const old_storage = self.parser.tape_storage;
        self.parser.tape_storage = new_storage;
        if (old_storage.len != 0) {
            self.parser.allocator.rawFree(
                @as([*]u8, @ptrCast(old_storage.ptr))[0 .. old_storage.len * @sizeOf(stage2.TapeWord)],
                .of(stage2.TapeWord),
                return_address,
            );
        }
        return byte_ptr;
    }
};

/// A borrowed reusable JSONL record.
pub const TapeRecord = struct {
    parser: *TapeRecordParser,
    lease: resident.Lease,
    generation: u64,
    record_index: usize,
    source: []const u8,
    source_start: usize,
    source_end: usize,
    tape_start: usize,
    tape_end: usize,

    pub fn root(self: *const TapeRecord) TapeRecordError!TapeRecordCursor {
        try self.check();
        const words = self.parser.tape_storage[self.tape_start..self.tape_end];
        const document = stage2.Document{ .tape = words, .dialect = .json };
        const base_cursor = try document.root(self.source);
        return .{
            .parser = self.parser,
            .lease = self.lease,
            .generation = self.generation,
            .cursor = base_cursor,
        };
    }

    pub fn cursor(self: *const TapeRecord) TapeRecordError!TapeRecordCursor {
        return self.root();
    }

    pub fn tapeWords(self: *const TapeRecord) TapeRecordError![]const stage2.TapeWord {
        try self.check();
        return self.parser.tape_storage[self.tape_start..self.tape_end];
    }

    fn check(self: *const TapeRecord) TapeRecordError!void {
        try self.parser.checkRecord(self.lease, self.generation);

        if (self.source_start > self.source_end or
            self.source_end > self.parser.input.len)
        {
            return error.SourceOutOfBounds;
        }
        const expected_source = self.parser.input[self.source_start..self.source_end];
        if (expected_source.ptr != self.source.ptr or
            expected_source.len != self.source.len)
        {
            return error.SourceOutOfBounds;
        }

        if (self.tape_start > self.tape_end or
            self.tape_end > self.parser.tape_len or
            self.tape_end > self.parser.tape_storage.len)
        {
            return error.TapeOutOfBounds;
        }
    }
};

/// A checked cursor over a borrowed reusable record tape.
pub const TapeRecordCursor = struct {
    parser: *TapeRecordParser,
    lease: resident.Lease,
    generation: u64,
    cursor: stage2.TapeCursor,

    pub fn peek(self: *const TapeRecordCursor) TapeRecordError!stage2.TapeWord {
        try self.check();
        return self.cursor.peek();
    }

    pub fn advance(self: *TapeRecordCursor) TapeRecordError!void {
        try self.check();
        try self.cursor.advance();
    }

    pub fn skipValue(self: *TapeRecordCursor) TapeRecordError!void {
        try self.check();
        try self.cursor.skipValue();
    }

    pub fn position(self: *const TapeRecordCursor) TapeRecordError!usize {
        try self.check();
        return self.cursor.position();
    }

    pub fn containerCount(self: *const TapeRecordCursor) TapeRecordError!u32 {
        try self.check();
        return self.cursor.containerCount();
    }

    pub fn matchingStart(self: *const TapeRecordCursor) TapeRecordError!TapeRecordCursor {
        try self.check();
        return .{
            .parser = self.parser,
            .lease = self.lease,
            .generation = self.generation,
            .cursor = try self.cursor.matchingStart(),
        };
    }

    pub fn rawValue(self: *const TapeRecordCursor) TapeRecordError![]const u8 {
        try self.check();
        return self.cursor.rawValue();
    }

    fn check(self: *const TapeRecordCursor) TapeRecordError!void {
        try self.parser.checkRecord(self.lease, self.generation);
    }
};

pub const TapeRecordIterator = struct {
    parser: *TapeRecordParser,
    lease: resident.Lease,
    guard: resident.Guard,
    record_iterator: RecordIterator,
    record_index: usize = 0,
    finished: bool = false,

    pub fn next(self: *TapeRecordIterator) TapeRecordError!?TapeRecordResult {
        try self.guard.check();
        if (self.finished) return null;
        try self.guard.advance();
        self.parser.invalidateRecord();

        const record_range = self.record_iterator.next() catch |err| {
            self.finished = true;
            return err;
        } orelse {
            self.finished = true;
            return null;
        };
        const record_source =
            self.parser.input[record_range.source_start..record_range.source_end];
        const view = stage2.IndexView.init(
            record_source,
            self.parser.storage.indexes[record_range.index_start..record_range.index_end],
            @intCast(record_range.source_start),
        ) catch |err| {
            self.finished = true;
            return err;
        };

        const generation = self.parser.record_generation;
        const result = self.parser.recordView(
            record_source,
            view,
            record_range,
            self.record_index,
            self.lease,
            generation,
        ) catch |err| {
            self.finished = true;
            return err;
        };
        switch (result) {
            .diagnostic => self.finished = true,
            .record => self.record_index += 1,
        }
        return result;
    }

    pub fn recordCount(self: *const TapeRecordIterator) usize {
        return self.record_index;
    }

    pub fn deinit(self: *TapeRecordIterator) void {
        if (self.guard.check()) |_| {
            self.parser.invalidateRecord();
            self.lease.release();
        } else |_| {}
        self.* = undefined;
    }
};

fn globalRecordDiagnostic(
    input: []const u8,
    record_range: RecordRange,
    record_index: usize,
    local: stage2.Diagnostic,
) JsonlDiagnostic {
    const record_len = record_range.source_end - record_range.source_start;
    const global_offset = record_range.source_start + @min(local.byte_offset, record_len);
    const global = stage2.diagnosticAt(input, local.err, global_offset);
    return .{
        .record_index = record_index,
        .source_start = record_range.source_start,
        .source_end = record_range.source_end,
        .err = global.err,
        .byte_offset = global.byte_offset,
        .line = global.line,
        .column = global.column,
        .snippet = global.snippet,
        .snippet_start = global.snippet_start,
    };
}

const ActiveRecord = struct {
    range: RecordRange,
    source: []const u8,
    view: stage2.IndexView,
};

pub const EventReader = struct {
    document: *OnDemandDocument,
    guard: resident.Guard,
    record_iterator: RecordIterator,
    active: ?ActiveRecord = null,
    reader: ?stage2.TokenReader = null,
    record_index: usize = 0,
    cache: ?Event = null,
    cache_eof: bool = false,
    failure: ?stage2.ReaderError = null,
    failure_offset: usize = 0,
    byte_position: usize = 0,
    structural_position: usize = 0,

    fn init(document: *OnDemandDocument, guard: resident.Guard) EventReader {
        return .{
            .document = document,
            .guard = guard,
            .record_iterator = RecordIterator.init(document.input, document.indexes),
        };
    }

    pub fn next(self: *EventReader) !?Event {
        try self.guard.check();
        if (self.failure) |err| return err;
        if (self.cache) |event| {
            self.cache = null;
            try self.guard.advance();
            return event;
        }
        if (self.cache_eof) return null;

        const event = self.readNext() catch |err| {
            self.failure = err;
            return err;
        };
        if (event) |value| {
            try self.guard.advance();
            return value;
        }
        self.cache_eof = true;
        return null;
    }

    pub fn peek(self: *EventReader) !?Event {
        try self.guard.check();
        if (self.failure) |err| return err;
        if (self.cache) |event| return event;
        if (self.cache_eof) return null;

        const event = self.readNext() catch |err| {
            self.failure = err;
            return err;
        };
        if (event) |value| {
            self.cache = value;
            return value;
        }
        self.cache_eof = true;
        return null;
    }

    pub fn skip(self: *EventReader) !void {
        const first = try self.next() orelse return;
        switch (first.kind) {
            .record_start => {
                while (true) {
                    const event = try self.next() orelse return error.UnexpectedEnd;
                    if (event.kind == .record_end) break;
                }
            },
            .object_start, .array_start => {
                var depth: usize = 1;
                while (depth > 0) {
                    const event = try self.next() orelse return error.UnexpectedEnd;
                    switch (event.kind) {
                        .object_start, .array_start => depth += 1,
                        .object_end, .array_end => depth -= 1,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn readNext(self: *EventReader) stage2.ReaderError!?Event {
        if (self.active == null) {
            const range = try self.record_iterator.next() orelse return null;
            const source = self.document.input[range.source_start..range.source_end];
            const view = stage2.IndexView.init(
                source,
                self.document.indexes[range.index_start..range.index_end],
                @intCast(range.source_start),
            ) catch return error.InvalidStructuralIndex;
            if (self.reader) |*reader| {
                try reader.reset(source, view, .json);
            } else {
                self.reader = try stage2.TokenReader.init(source, view, .json);
            }
            self.active = .{
                .range = range,
                .source = source,
                .view = view,
            };
            return .{
                .kind = .record_start,
                .record_index = @intCast(self.record_index),
                .offset = @intCast(range.source_start),
                .raw = source,
            };
        }

        const active = &self.active.?;
        const reader = &self.reader.?;
        const parsed = reader.next() catch |err| {
            self.failure_offset = active.range.source_start + reader.failure_offset;
            self.byte_position = active.range.source_start + reader.byte_position;
            self.structural_position = reader.structural_position;
            return err;
        };
        if (parsed) |token| {
            self.failure_offset = active.range.source_start + reader.failure_offset;
            self.byte_position = active.range.source_start + reader.byte_position;
            self.structural_position = reader.structural_position;
            return parsedTokenEvent(token, active.range, self.record_index);
        }
        const range = active.range;
        self.active = null;
        self.record_index += 1;
        return .{
            .kind = .record_end,
            .record_index = @intCast(self.record_index - 1),
            .offset = @intCast(range.source_end),
            .raw = self.document.input[range.source_end..range.source_end],
        };
    }
};

pub const TokenCursor = struct {
    document: *OnDemandDocument,
    guard: resident.Guard,
    record_iterator: RecordIterator,
    active: ?ActiveRecord = null,
    reader: ?stage2.TokenReader = null,
    record_index: usize = 0,
    cache: ?Event = null,
    cache_eof: bool = false,
    failure: ?stage2.ReaderError = null,
    failure_offset: usize = 0,
    byte_position: usize = 0,
    structural_position: usize = 0,

    fn init(document: *OnDemandDocument, guard: resident.Guard) TokenCursor {
        return .{
            .document = document,
            .guard = guard,
            .record_iterator = RecordIterator.init(document.input, document.indexes),
        };
    }

    pub fn peek(self: *TokenCursor) !?Event {
        try self.guard.check();
        if (self.failure) |err| return err;
        if (self.cache) |token| return token;
        if (self.cache_eof) return null;

        const token = self.readNext() catch |err| {
            self.failure = err;
            return err;
        };
        if (token) |value| {
            self.cache = value;
            return value;
        }
        self.cache_eof = true;
        return null;
    }

    pub fn advance(self: *TokenCursor) !?Event {
        try self.guard.check();
        if (self.failure) |err| return err;
        if (self.cache) |token| {
            self.cache = null;
            try self.guard.advance();
            return token;
        }
        if (self.cache_eof) return null;

        const token = self.readNext() catch |err| {
            self.failure = err;
            return err;
        };
        if (token) |value| {
            try self.guard.advance();
            return value;
        }
        self.cache_eof = true;
        return null;
    }

    pub fn skipChild(self: *TokenCursor) !void {
        const first = try self.advance() orelse return;
        switch (first.kind) {
            .record_start => {
                while (try self.advance()) |event| {
                    if (event.kind == .record_end) return;
                }
                return error.UnexpectedEnd;
            },
            .record_end => return,
            .object_start, .array_start => {
                var depth: usize = 1;
                while (depth > 0) {
                    const token = try self.advance() orelse return error.UnexpectedEnd;
                    switch (token.kind) {
                        .object_start, .array_start => depth += 1,
                        .object_end, .array_end => depth -= 1,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn readNext(self: *TokenCursor) stage2.ReaderError!?Event {
        if (self.active == null) {
            const range = try self.record_iterator.next() orelse return null;
            const source = self.document.input[range.source_start..range.source_end];
            const view = stage2.IndexView.init(
                source,
                self.document.indexes[range.index_start..range.index_end],
                @intCast(range.source_start),
            ) catch return error.InvalidStructuralIndex;
            if (self.reader) |*reader| {
                try reader.reset(source, view, .json);
            } else {
                self.reader = try stage2.TokenReader.init(source, view, .json);
            }
            self.active = .{
                .range = range,
                .source = source,
                .view = view,
            };
            return .{
                .kind = .record_start,
                .record_index = @intCast(self.record_index),
                .offset = @intCast(range.source_start),
                .raw = source,
            };
        }

        const active = &self.active.?;
        const reader = &self.reader.?;
        const parsed = reader.next() catch |err| {
            self.failure_offset =
                active.range.source_start + reader.failure_offset;
            self.byte_position =
                active.range.source_start + reader.byte_position;
            self.structural_position = reader.structural_position;
            return err;
        };
        if (parsed) |token| {
            self.failure_offset =
                active.range.source_start + reader.failure_offset;
            self.byte_position =
                active.range.source_start + reader.byte_position;
            self.structural_position = reader.structural_position;
            return parsedTokenEvent(token, active.range, self.record_index);
        }

        const range = active.range;
        self.active = null;
        self.record_index += 1;
        return .{
            .kind = .record_end,
            .record_index = @intCast(self.record_index - 1),
            .offset = @intCast(range.source_end),
            .raw = self.document.input[range.source_end..range.source_end],
        };
    }
};

fn parsedTokenEvent(
    token: stage2.ParsedToken,
    range: RecordRange,
    record_index: usize,
) Event {
    const local_offset: usize = @intCast(token.word.offset);
    const kind: EventKind = switch (token.word.tapeKind()) {
        .object_start => .object_start,
        .object_end => .object_end,
        .array_start => .array_start,
        .array_end => .array_end,
        .key => .key,
        .string => .string,
        .number => .number,
        .true_literal => .true_literal,
        .false_literal => .false_literal,
        .null_literal => .null_literal,
    };
    return .{
        .kind = kind,
        .record_index = @intCast(record_index),
        .offset = @intCast(range.source_start + local_offset),
        .raw = token.raw,
    };
}

/// Builds an owned validated tape for every nonblank JSONL record.
pub fn buildJsonlTape(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage2.BuildError!JsonlDocument {
    var structural_index = indexJsonl(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);

    var records = std.ArrayList(JsonlRecord).empty;
    errdefer {
        for (records.items) |*record_value| {
            record_value.deinit(allocator);
        }
        records.deinit(allocator);
    }

    var record_iterator = RecordIterator.init(input, structural_index.slice());
    while (try record_iterator.next()) |record_range| {
        const record_source = input[record_range.source_start..record_range.source_end];
        const base_offset: u32 = @intCast(record_range.source_start);
        const view = stage2.IndexView.init(
            record_source,
            structural_index.slice()[record_range.index_start..record_range.index_end],
            base_offset,
        ) catch |err| return err;
        var document = try stage2.buildTapeView(allocator, record_source, view, .json);
        records.append(allocator, .{
            .source = record_source,
            .source_start = record_range.source_start,
            .source_end = record_range.source_end,
            .document = document,
        }) catch |err| {
            document.deinit(allocator);
            return err;
        };
    }

    return .{
        .input = input,
        .records = try records.toOwnedSlice(allocator),
    };
}

/// Validates nonblank JSONL records and returns the first global diagnostic.
pub fn validateJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage2.ValidationError!?JsonlDiagnostic {
    var structural_index = indexJsonl(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);

    var record_iterator = RecordIterator.init(input, structural_index.slice());
    var record_index: usize = 0;
    while (try record_iterator.next()) |record_range| : (record_index += 1) {
        const record_source = input[record_range.source_start..record_range.source_end];
        const base_offset: u32 = @intCast(record_range.source_start);
        const view = stage2.IndexView.init(
            record_source,
            structural_index.slice()[record_range.index_start..record_range.index_end],
            base_offset,
        ) catch |err| return err;
        const diagnostic = try stage2.validateView(record_source, view, .json);
        if (diagnostic) |local| {
            const global_offset = record_range.source_start + @min(
                local.byte_offset,
                record_range.source_end - record_range.source_start,
            );
            const global = stage2.diagnosticAt(input, local.err, global_offset);
            return .{
                .record_index = record_index,
                .source_start = record_range.source_start,
                .source_end = record_range.source_end,
                .err = global.err,
                .byte_offset = global.byte_offset,
                .line = global.line,
                .column = global.column,
                .snippet = global.snippet,
                .snippet_start = global.snippet_start,
            };
        }
    }
    return null;
}

const RecordRange = struct {
    source_start: usize,
    source_end: usize,
    index_start: usize,
    index_end: usize,
};

const RecordIterator = struct {
    input: []const u8,
    offsets: []const u32,
    source_start: usize = 0,
    index_start: usize = 0,
    offset_position: usize = 0,
    finished: bool = false,

    fn init(input: []const u8, offsets: []const u32) RecordIterator {
        return .{ .input = input, .offsets = offsets };
    }

    fn next(self: *RecordIterator) !?RecordRange {
        while (true) {
            if (self.offset_position < self.offsets.len) {
                const offset_position = self.offset_position;
                const offset: usize = @intCast(self.offsets[offset_position]);
                self.offset_position += 1;
                if (offset >= self.input.len) continue;
                if (self.input[offset] != '\n') continue;

                const record = RecordRange{
                    .source_start = self.source_start,
                    .source_end = offset,
                    .index_start = self.index_start,
                    .index_end = offset_position,
                };
                self.source_start = offset + 1;
                self.index_start = self.offset_position;
                if (isBlankRecord(self.input[record.source_start..record.source_end])) {
                    continue;
                }
                return record;
            }

            if (self.finished or self.source_start >= self.input.len) {
                self.finished = true;
                return null;
            }

            const record = RecordRange{
                .source_start = self.source_start,
                .source_end = self.input.len,
                .index_start = self.index_start,
                .index_end = self.offset_position,
            };
            self.finished = true;
            if (isBlankRecord(self.input[record.source_start..record.source_end])) {
                return null;
            }
            return record;
        }
    }
};

fn isBlankRecord(source: []const u8) bool {
    for (source) |byte| {
        switch (byte) {
            ' ', '\t', '\r' => {},
            else => return false,
        }
    }
    return true;
}

const testing = std.testing;
const sentinel_count: usize = 3;

pub fn indexJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    return indexJsonlImpl(simd.default_vector_len, allocator, input);
}

/// Emits JSONL structural offsets directly into caller-owned storage.
///
/// The returned count excludes sentinels. `out` is unchanged beyond that
/// prefix. Record-separator LF bytes are emitted only outside quoted strings.
pub fn indexJsonlInto(
    comptime VLEN: usize,
    out: []u32,
    input: []const u8,
) !usize {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var sink = IndexSink{ .out = out };
    var lexical_state: json_lexical.State = .{};
    try json_lexical.feed(
        VLEN,
        .jsonl,
        &lexical_state,
        input,
        0,
        &sink,
    );
    try json_lexical.finish(.jsonl, &lexical_state, &sink);
    return sink.count;
}

pub fn indexJsonlImpl(
    comptime VLEN: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);

    indexes.count = indexJsonlInto(
        VLEN,
        indexes.indexes[0 .. indexes.indexes.len - sentinel_count],
        input,
    ) catch |err| switch (err) {
        error.CapacityExceeded, error.NonContiguousInput => unreachable,
        error.InputTooLarge => return error.InputTooLarge,
    };
    try indexes.finish(input.len);
    return indexes;
}

const IndexSink = struct {
    out: []u32,
    count: usize = 0,

    pub fn appendOffset(self: *IndexSink, offset: usize) !void {
        if (offset > std.math.maxInt(u32)) return error.InputTooLarge;
        if (self.count >= self.out.len) return error.CapacityExceeded;

        self.out[self.count] = @intCast(offset);
        self.count += 1;
    }

    pub fn appendMask(
        self: *IndexSink,
        comptime T: type,
        mask: T,
        base_offset: usize,
    ) !void {
        if (self.count > self.out.len) return error.CapacityExceeded;
        const appended = try simd.extractBitIndexesChecked(
            T,
            mask,
            base_offset,
            self.out[self.count..],
        );
        self.count += appended;
    }
};

fn scalarIndexJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var backslash_run_length: usize = 0;
    var prev_in_atom = false;
    for (input, 0..) |byte, index| {
        const unescaped_quote = byte == '"' and backslash_run_length % 2 == 0;
        if (unescaped_quote) {
            if (!in_string) {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            }
            in_string = !in_string;
        }

        if (!in_string) {
            if (isStructuralByte(byte) or byte == '\n') {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            } else if (isAtomByte(byte) and !prev_in_atom) {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            }
        }

        prev_in_atom = !in_string and byte != '"' and
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

fn expectValidIndexes(input_length: usize, indexes: []const u32) !void {
    try testing.expect(indexes.len <= input_length);
    for (indexes, 0..) |index, position| {
        const index_usize: usize = @intCast(index);
        try testing.expect(index_usize < input_length);
        if (position > 0) {
            try testing.expect(indexes[position - 1] < index);
        }
    }
}

fn expectMatchesScalar(input: []const u8) !void {
    return expectMatchesScalarAtWidth(simd.default_vector_len, input);
}

fn expectMatchesScalarAtWidth(
    comptime VLEN: usize,
    input: []const u8,
) !void {
    var expected = try scalarIndexJsonl(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try expectValidIndexes(input.len, expected.slice());

    var actual = try indexJsonlImpl(VLEN, testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    try expectValidIndexes(input.len, actual.slice());
}

test "indexJsonlImpl matches scalar at 16, 32, and 64 byte widths for record boundaries" {
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |width| {
        for (boundary_lengths) |length| {
            var boundary_input: [66]u8 = @splat(' ');
            if (length > 0) {
                boundary_input[length - 1] = '\n';
            }
            try expectMatchesScalarAtWidth(width, boundary_input[0..length]);
        }

        var input: [width * 3 + 5]u8 = @splat(' ');
        input[0] = '{';
        input[1] = '0';
        input[2] = '}';
        input[width - 1] = '\n';
        input[width] = '[';
        input[width + 1] = '1';
        input[width + 2] = ']';
        input[2 * width - 1] = '\n';
        input[2 * width] = '"';
        input[2 * width + 1] = '\n';
        input[2 * width + 2] = '"';
        input[2 * width + 3] = ':';
        input[2 * width + 4] = '2';
        input[3 * width] = '\n';
        input[3 * width + 1] = '{';
        input[3 * width + 2] = '}';
        try expectMatchesScalarAtWidth(width, &input);
    }
}

test "indexJsonlImpl matches scalar at 16, 32, and 64 byte widths for string backslash boundaries" {
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |width| {
        for (boundary_lengths) |length| {
            var boundary_input: [66]u8 = @splat(' ');
            if (length > 0) {
                boundary_input[0] = '[';
            }
            if (length > 1) {
                boundary_input[1] = '"';
            }
            if (length > 2) {
                boundary_input[length - 1] = '"';
            }
            try expectMatchesScalarAtWidth(width, boundary_input[0..length]);
        }

        var run_length: usize = 1;
        while (run_length <= width + 2) : (run_length += 1) {
            var input: [width * 4 + 8]u8 = @splat(' ');
            input[0] = '[';
            input[1] = '"';
            const run_start = width - 1;
            const quote_offset = run_start + run_length;
            for (run_start..quote_offset) |offset| {
                input[offset] = '\\';
            }

            input[quote_offset] = '"';
            var next_offset = quote_offset + 1;
            if (run_length % 2 != 0) {
                input[next_offset] = '"';
                next_offset += 1;
            }
            input[next_offset] = '0';
            input[next_offset + 1] = ']';
            input[next_offset + 2] = '\n';
            try expectMatchesScalarAtWidth(width, input[0 .. next_offset + 3]);
        }

        for ([_]usize{ width - 1, width }) |quote_offset| {
            for (0..10) |backslash_run_length| {
                var input: [width * 2 + 8]u8 = @splat(' ');
                input[0] = '[';
                input[1] = '"';
                const run_start = quote_offset - backslash_run_length;
                for (run_start..quote_offset) |offset| {
                    input[offset] = '\\';
                }

                input[quote_offset] = '"';
                var next_offset = quote_offset + 1;
                if (backslash_run_length % 2 != 0) {
                    input[next_offset] = '"';
                    next_offset += 1;
                }
                input[next_offset] = '0';
                input[next_offset + 1] = ']';
                input[next_offset + 2] = '\n';
                try expectMatchesScalarAtWidth(width, input[0 .. next_offset + 3]);
            }
        }
    }
}

test "indexJsonl handles empty lines, CRLF, and trailing newlines" {
    const cases = [_][]const u8{
        "",
        "\n",
        "\n\n\n",
        "\r\n",
        "\r\n\n",
        "{\"a\":0}\r\n{\"b\":-0}\n\n",
        " \r\n\t\n",
    };

    for (cases) |input| {
        try expectMatchesScalar(input);
    }
}

test "indexJsonl distinguishes newlines inside and outside strings" {
    const input = "{\"text\":\"first\nsecond\r\nthird\"}\r\n\n{\"n\":1}\n";
    try expectMatchesScalar(input);

    var index = try indexJsonl(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try expectValidIndexes(input.len, index.slice());

    const expected = [_]u32{ 0, 1, 7, 8, 29, 31, 32, 33, 34, 37, 38, 39, 40 };
    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonl handles degenerate records and numeric atom starts" {
    const cases = [_][]const u8{
        "\"\"",
        "\"",
        "'",
        "{",
        "}",
        "[",
        "]",
        ":",
        ",",
        "-123.45e+6\n0\r\n-0\n1E10",
    };

    for (cases) |input| {
        try expectMatchesScalar(input);
    }

    const numeric_input = "-123.45e+6\n0\r\n-0\n1E10";
    var index = try indexJsonl(testing.allocator, numeric_input);
    defer index.deinit(testing.allocator);
    try expectValidIndexes(numeric_input.len, index.slice());
}

test "indexJsonl handles alternating backslash runs around chunk boundaries" {
    const boundary_offsets = [_]usize{ 62, 63, 64, 65 };

    for (boundary_offsets) |run_start| {
        for (1..130) |run_length| {
            var input: [260]u8 = @splat(' ');
            input[0] = '[';
            input[1] = '"';
            for (run_start..run_start + run_length) |offset| {
                input[offset] = '\\';
            }

            const quote_offset = run_start + run_length;
            input[quote_offset] = '"';
            var next_offset = quote_offset + 1;
            if (run_length % 2 != 0) {
                input[next_offset] = '"';
                next_offset += 1;
            }
            input[next_offset] = '0';
            input[next_offset + 1] = ']';
            input[next_offset + 2] = '\n';
            try expectMatchesScalar(input[0 .. next_offset + 3]);
        }
    }

    for (boundary_offsets) |quote_offset| {
        for (0..10) |run_length| {
            var input: [100]u8 = @splat(' ');
            input[0] = '[';
            input[1] = '"';
            const run_start = quote_offset - run_length;
            for (run_start..quote_offset) |offset| {
                input[offset] = '\\';
            }

            input[quote_offset] = '"';
            var next_offset = quote_offset + 1;
            if (run_length % 2 != 0) {
                input[next_offset] = '"';
                next_offset += 1;
            }
            input[next_offset] = '0';
            input[next_offset + 1] = ']';
            input[next_offset + 2] = '\n';
            try expectMatchesScalar(input[0 .. next_offset + 3]);
        }
    }
}

test "indexJsonl preserves unterminated string state at boundary EOFs" {
    const lengths = [_]usize{ 62, 63, 64, 65, 66 };
    for (lengths) |length| {
        var input: [66]u8 = @splat(' ');
        input[0] = '"';
        input[length - 1] = '\n';
        try expectMatchesScalar(input[0..length]);
    }
}

test "indexJsonl indexes record boundaries and opening quotes" {
    const input = "{\"a\":1}\n{\"b\":2}\n";
    const expected = [_]u32{ 0, 1, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15 };

    var index = try indexJsonl(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
    try expectValidIndexes(input.len, index.slice());
}

test "indexJsonl emits one start for each complete numeric atom" {
    const input = "1.2\n3e4\n-5.6e-7\n";
    const expected = [_]u32{ 0, 3, 4, 7, 8, 15 };

    var index = try indexJsonl(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &expected, index.slice());
    try expectValidIndexes(input.len, index.slice());
}

test "indexJsonl ignores newlines inside strings" {
    try expectMatchesScalar("{\"text\":\"first\nsecond\"}\n{\"n\":null}\n");
}

test "indexJsonl matches scalar reference across SIMD chunks" {
    var input: [132]u8 = @splat(' ');
    input[0] = '[';
    input[1] = '"';
    input[63] = '\\';
    input[64] = '"';
    input[92] = '"';
    input[93] = ']';
    input[94] = '\n';
    input[95] = '{';
    input[96] = '"';
    input[97] = 'n';
    input[98] = '"';
    input[99] = ':';
    input[100] = '0';
    input[101] = '}';
    input[102] = '\n';
    try expectMatchesScalar(&input);
}

test "indexJsonl differential adversarial byte matrix" {
    const alphabet = [_]u8{
        '{',  '}',  '[', ']', ':', ',', '"', '\\', '-', 't', 'f', 'n',

        '0',  '1',  '2', '3', '4', '5', '6', '7',  '8', '9', ' ', '\t',
        '\r', '\n', '.', '+', '/', 'a', 'x',
    };
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        var state: u64 = 0xbb67ae8584caa73b;
        var input: [257]u8 = undefined;

        for (0..512) |case_index| {
            const length = if (case_index < boundary_lengths.len)
                boundary_lengths[case_index]
            else
                @as(usize, @intCast(state % 258));

            for (0..length) |offset| {
                state = state *% 0x9e3779b97f4a7c15 +% 0xbb67ae8584caa73b;
                const alphabet_index: usize = @intCast(state % @as(u64, alphabet.len));
                input[offset] = alphabet[alphabet_index];
            }
            try expectMatchesScalarAtWidth(vlen, input[0..length]);
        }
    }
}
test "indexJsonlInto emits the same global offsets as the owned adapter" {
    const input = "{\"a\":\"line\nvalue\"}\r\n2";
    var expected = try indexJsonl(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var output: [64]u32 = undefined;
    const count = try indexJsonlInto(16, output[0..], input);
    try testing.expectEqual(expected.count, count);
    try testing.expectEqualSlices(u32, expected.slice(), output[0..count]);
}

test "buildJsonlTape keeps records independently cursorable" {
    const input = "{\"a\":1}\n2\nfalse\n";
    var document = try buildJsonlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), document.records.len);
    try testing.expectEqualStrings(input[0..7], document.records[0].source);
    try testing.expectEqualStrings(input[8..9], document.records[1].source);
    try testing.expectEqualStrings(input[10..15], document.records[2].source);
    try testing.expectEqual(@as(usize, 0), document.records[0].source_start);
    try testing.expectEqual(@as(usize, 7), document.records[0].source_end);
    try testing.expectEqual(@as(usize, 8), document.records[1].source_start);
    try testing.expectEqual(@as(usize, 9), document.records[1].source_end);

    var object_cursor = try document.records[0].root();
    try testing.expectEqual(stage2.TapeKind.object_start, (try object_cursor.peek()).tapeKind());
    try object_cursor.advance();
    try testing.expectEqualStrings(
        "a",
        try object_cursor.rawValue(),
    );
    try testing.expect(
        (try object_cursor.rawValue()).ptr == input.ptr + 2,
    );

    var number_cursor = try document.records[1].cursor();
    try testing.expectEqual(stage2.TapeKind.number, (try number_cursor.peek()).tapeKind());
    try testing.expectEqualStrings("2", try number_cursor.rawValue());
    try number_cursor.skipValue();
    try testing.expectEqual(document.records[1].document.tape.len, number_cursor.position());
    try testing.expectError(error.PositionOutOfBounds, number_cursor.peek());

    var false_cursor = try document.cursor(2);
    try testing.expectEqual(stage2.TapeKind.false_literal, (try false_cursor.peek()).tapeKind());
    try testing.expectEqualStrings("false", try false_cursor.rawValue());
}
test "buildJsonlTape preserves all multi-record boundaries and indexes" {
    const input = "{\"a\":[1,2]}\n42\n{\"b\":{\"c\":true}}\nnull\n";
    const expected_sources = [_][]const u8{
        "{\"a\":[1,2]}",
        "42",
        "{\"b\":{\"c\":true}}",
        "null",
    };
    const expected_starts = [_]usize{ 0, 12, 15, 32 };
    const expected_ends = [_]usize{ 11, 14, 31, 36 };
    const expected_kinds = [_]stage2.TapeKind{
        .object_start,
        .number,
        .object_start,
        .null_literal,
    };

    var document = try buildJsonlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(expected_sources.len, document.records.len);
    for (document.records, 0..) |*record_value, index| {
        try testing.expectEqualStrings(expected_sources[index], record_value.source);
        try testing.expectEqual(expected_starts[index], record_value.source_start);
        try testing.expectEqual(expected_ends[index], record_value.source_end);

        var cursor = try record_value.root();
        try testing.expectEqual(expected_kinds[index], (try cursor.peek()).tapeKind());
    }

    var number_cursor = try document.records[1].root();
    try testing.expectEqualStrings("42", try number_cursor.rawValue());
    var null_cursor = try document.records[3].root();
    try testing.expectEqualStrings("null", try null_cursor.rawValue());
    try testing.expect((try validateJsonl(testing.allocator, input)) == null);
}

test "buildJsonlTape skips blank and trailing records while retaining CR" {
    const input = " \r\n\n{\"a\":1}\r\n2\r\n\n";
    var document = try buildJsonlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), document.records.len);
    try testing.expectEqualStrings("{\"a\":1}\r", document.records[0].source);
    try testing.expectEqualStrings("2\r", document.records[1].source);
    try testing.expectEqual(@as(usize, 4), document.records[0].source_start);
    try testing.expectEqual(@as(usize, 13), document.records[1].source_start);

    var empty_document = try buildJsonlTape(testing.allocator, "");
    defer empty_document.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty_document.records.len);
}

test "validateJsonl does not split a quoted LF into two records" {
    const input = "{\"text\":\"first\nsecond\"}\n{}\n";
    const quoted_lf = std.mem.indexOfScalar(u8, input, '\n').?;
    const diagnostic = (try validateJsonl(testing.allocator, input)).?;

    try testing.expectEqual(@as(usize, 0), diagnostic.record_index);
    try testing.expectEqual(@as(usize, 0), diagnostic.source_start);
    try testing.expect(diagnostic.source_end > quoted_lf);
    try testing.expectEqual(error.InvalidEscape, diagnostic.err);
    try testing.expectEqual(quoted_lf, diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 1), diagnostic.line);
    try testing.expectEqual(@as(u32, @intCast(quoted_lf + 1)), diagnostic.column);
}

test "validateJsonl reports later record errors in global coordinates" {
    const input = "{}\n  [1,]\n{}\n";
    const close_bracket = std.mem.indexOfScalar(u8, input, ']').?;
    const diagnostic = (try validateJsonl(testing.allocator, input)).?;

    try testing.expectEqual(@as(usize, 1), diagnostic.record_index);
    try testing.expectEqual(@as(usize, 3), diagnostic.source_start);
    try testing.expectEqual(close_bracket + 1, diagnostic.source_end);
    try testing.expectEqual(error.TrailingComma, diagnostic.err);
    try testing.expectEqual(close_bracket, diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), diagnostic.line);
    try testing.expectEqual(@as(u32, 6), diagnostic.column);
    try testing.expect(
        diagnostic.snippet.ptr == input.ptr + diagnostic.snippet_start,
    );
}

test "JSONL resident events stay lazy with global record spans" {
    const input = "1\n[2,]\n";
    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();

    const first_start = (try reader.next()).?;
    try testing.expectEqual(EventKind.record_start, first_start.kind);
    try testing.expectEqual(@as(u32, 0), first_start.record_index);
    try testing.expectEqual(@as(u32, 0), first_start.offset);
    try testing.expect(first_start.raw.ptr == input.ptr);

    const first_value = (try reader.peek()).?;
    try testing.expectEqual(EventKind.number, first_value.kind);
    try testing.expectEqual(first_value, (try reader.peek()).?);
    try testing.expectEqual(@as(u32, 0), first_value.offset);
    try testing.expect(first_value.raw.ptr == input.ptr);
    try testing.expectEqualStrings("1", first_value.raw);
    _ = (try reader.next()).?;

    const first_end = (try reader.next()).?;
    try testing.expectEqual(EventKind.record_end, first_end.kind);
    try testing.expectEqual(@as(u32, 1), first_end.offset);
    try testing.expectEqual(@as(usize, 0), first_end.raw.len);

    const second_start = (try reader.next()).?;
    try testing.expectEqual(EventKind.record_start, second_start.kind);
    try testing.expectEqual(@as(u32, 1), second_start.record_index);
    try testing.expectEqual(@as(u32, 2), second_start.offset);
    try testing.expectEqualStrings("[2,]", second_start.raw);

    try testing.expectEqual(EventKind.array_start, (try reader.next()).?.kind);
    try testing.expectEqual(EventKind.number, (try reader.next()).?.kind);
    try testing.expectError(error.TrailingComma, reader.next());
}

test "JSONL resident peeks retain malformed array errors" {
    const input = "[,]";

    {
        var parser = try Parser.init(testing.allocator, 0);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var reader = try document.eventReader();

        try testing.expectEqual(EventKind.record_start, (try reader.next()).?.kind);
        try testing.expectEqual(EventKind.array_start, (try reader.next()).?.kind);
        try testing.expectError(error.UnexpectedToken, reader.peek());
        try testing.expectError(error.UnexpectedToken, reader.next());
    }

    {
        var parser = try Parser.init(testing.allocator, 0);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var cursor = try document.tokenCursor();

        try testing.expectEqual(EventKind.record_start, (try cursor.advance()).?.kind);
        try testing.expectEqual(EventKind.array_start, (try cursor.advance()).?.kind);
        try testing.expectError(error.UnexpectedToken, cursor.peek());
        try testing.expectError(error.UnexpectedToken, cursor.advance());
    }
}

test "JSONL resident token cursor emits boundaries and skips one record" {
    const input = "{\"a\":[1,true]}\nnull";
    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var cursor = try document.tokenCursor();

    const first = (try cursor.peek()).?;
    try testing.expectEqual(EventKind.record_start, first.kind);
    try testing.expectEqual(first, (try cursor.peek()).?);
    try testing.expectEqual(@as(u32, 0), first.offset);
    try cursor.skipChild();

    const second_start = (try cursor.advance()).?;
    try testing.expectEqual(EventKind.record_start, second_start.kind);
    try testing.expectEqual(@as(u32, @intCast(input.len - 4)), second_start.offset);

    const second = (try cursor.advance()).?;
    try testing.expectEqual(EventKind.null_literal, second.kind);
    try testing.expectEqualStrings("null", second.raw);
    try testing.expectEqual(@as(u32, @intCast(input.len - 4)), second.offset);

    const second_end = (try cursor.advance()).?;
    try testing.expectEqual(EventKind.record_end, second_end.kind);
    try testing.expectEqual(@as(u32, @intCast(input.len)), second_end.offset);
    try testing.expect((try cursor.advance()) == null);
}

test "JSONL resident focus detects copies release and parser reuse" {
    const input = "true\n";
    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, input);
    var reader = try document.eventReader();
    var copied = reader;
    _ = try reader.next();
    try testing.expectError(error.OutOfOrderIteration, copied.peek());
    document.deinit();
    try testing.expectError(error.DocumentReleased, reader.next());

    var reused = try initOnDemandDocument(&parser, input);
    defer reused.deinit();
    var reused_reader = try reused.eventReader();
    try testing.expectEqual(EventKind.record_start, (try reused_reader.next()).?.kind);
}

test "JSONL resident capacity rejects oversized borrowed sources" {
    var parser = try Parser.init(testing.allocator, 3);
    defer parser.deinit();

    try testing.expectError(
        error.CapacityExceeded,
        initOnDemandDocument(&parser, "1\n2\n"),
    );
}

fn checkJsonlResidentAllocation(allocator: std.mem.Allocator) !void {
    var parser = try Parser.init(allocator, 0);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, "{\"a\":1}\n");
    document.deinit();
}

test "JSONL resident parser handles allocator failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkJsonlResidentAllocation,
        .{},
    );
}

test "refAllDecls" {
    testing.refAllDecls(@This());
    _ = simd;
}

fn expectJsonlStreamIndexEqual(
    expected: *const stage1.StructuralIndex,
    actual: *const stage1.StructuralIndex,
) !void {
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + 3],
        actual.indexes[0 .. actual.count + 3],
    );
}

fn feedJsonlStream(
    input: []const u8,
    split: usize,
    chunk_len: usize,
) !stage1.StructuralIndex {
    var indexer = try initStreamIndexer(testing.allocator, chunk_len);
    defer indexer.deinit();

    try indexer.feed(input[0..split]);
    try indexer.feed("");
    try indexer.feed(input[split..]);
    try indexer.finish();
    try indexer.finish();
    return indexer.take();
}

test "JSONL stream wrapper matches one-shot at every partition and byte feed" {
    const input =
        "{\"a\":1}\n{\"b\":\"line\nvalue\"}\r\n[true,false]\n";
    var expected = try indexJsonl(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    for (0..input.len + 1) |split| {
        var actual = try feedJsonlStream(input, split, 3);
        defer actual.deinit(testing.allocator);
        try expectJsonlStreamIndexEqual(&expected, &actual);
    }

    var byte_indexer = try initStreamIndexer(testing.allocator, 1);
    defer byte_indexer.deinit();
    for (input) |byte| {
        try byte_indexer.feed(&.{byte});
    }
    try byte_indexer.finish();
    var byte_actual = byte_indexer.take();
    defer byte_actual.deinit(testing.allocator);
    try expectJsonlStreamIndexEqual(&expected, &byte_actual);
}

test "JSONL stream wrapper reset and finish lifecycle restart offsets" {
    const first_input = "1\n2\n";
    const second_input = "{\"x\":true}\n";
    var indexer = try initStreamIndexer(testing.allocator, 2);
    defer indexer.deinit();

    try indexer.feed(first_input);
    try indexer.finish();
    try indexer.finish();
    try testing.expectError(error.AlreadyFinished, indexer.feed("0"));
    var first = indexer.take();
    defer first.deinit(testing.allocator);

    indexer.reset();
    try indexer.feed(second_input[0..4]);
    try indexer.feed(second_input[4..]);
    try indexer.finish();
    var second = indexer.take();
    defer second.deinit(testing.allocator);

    var expected_first = try indexJsonl(testing.allocator, first_input);
    defer expected_first.deinit(testing.allocator);
    var expected_second = try indexJsonl(testing.allocator, second_input);
    defer expected_second.deinit(testing.allocator);
    try expectJsonlStreamIndexEqual(&expected_first, &first);
    try expectJsonlStreamIndexEqual(&expected_second, &second);
}
