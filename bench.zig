const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const lib = @import("src/root.zig");

const Allocator = std.mem.Allocator;
const CHECKSUM_STRIDE: usize = 64;
const CHECKSUM_BYTES: usize = 128;
const STREAM_CHUNK_LEN: usize = 4096;
const RESIDENT_PREFIX_EVENT_COUNT: usize = 8;
const DEFAULT_ITERATIONS: usize = 3;
const workload_scale: usize = 64;

const Format = enum {
    json,
    jsonl,
    jsonc,
    json5,
    markdown,
    xml,
    yaml,
};

const Workload = enum {
    fixture,
    sparse,
    dense,
    escaped,
    unicode,
};

const Stage = enum {
    index,
    validate,
    tape,
    stream,
    traverse_all,
    traverse_prefix8,
};

const formats = [_]Format{
    .json,
    .jsonl,
    .jsonc,
    .json5,
    .markdown,
    .xml,
    .yaml,
};

const workloads = [_]Workload{
    .fixture,
    .sparse,
    .dense,
    .escaped,
    .unicode,
};

const stages = [_]Stage{
    .index,
    .validate,
    .tape,
    .stream,
    .traverse_all,
    .traverse_prefix8,
};

const input_count = formats.len * workloads.len;

const Input = struct {
    format: Format,
    workload: Workload,
    bytes: []const u8,
    hash: u64,
};

const Sample = struct {
    elapsed_ns: u64,
    checksum: u64,
    allocation_count: usize,
    allocated_bytes: usize,
};

const ByteBuilder = struct {
    allocator: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn init(allocator: Allocator) @This() {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *@This()) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    fn append(self: *@This(), bytes: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    fn appendByte(self: *@This(), byte: u8) !void {
        try self.bytes.append(self.allocator, byte);
    }

    fn appendUsize(self: *@This(), value: usize) !void {
        var digits: [20]u8 = undefined;
        var length: usize = 0;
        var remaining = value;
        if (remaining == 0) {
            digits[0] = '0';
            length = 1;
        } else {
            while (remaining != 0) : (remaining /= 10) {
                digits[length] = @intCast('0' + remaining % 10);
                length += 1;
            }
            var left: usize = 0;
            var right: usize = length - 1;
            while (left < right) {
                const saved = digits[left];
                digits[left] = digits[right];
                digits[right] = saved;
                left += 1;
                right -= 1;
            }
        }
        try self.append(digits[0..length]);
    }

    fn finish(self: *@This()) ![]const u8 {
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

const CountingAllocator = struct {
    child: Allocator,
    allocation_count: usize = 0,
    allocated_bytes: usize = 0,

    fn allocator(self: *@This()) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reset(self: *@This()) void {
        self.allocation_count = 0;
        self.allocated_bytes = 0;
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(length, alignment, return_address);
        if (result != null) {
            self.allocation_count +|= 1;
            self.allocated_bytes +|= length;
        }
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        const result = self.child.rawResize(memory, alignment, new_length, return_address);
        if (result and new_length > memory.len) {
            self.allocated_bytes +|= new_length - memory.len;
        }
        return result;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_length, return_address);
        if (result != null and new_length > memory.len) {
            self.allocated_bytes +|= new_length - memory.len;
        }
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
    }
};

fn formatName(format: Format) []const u8 {
    return switch (format) {
        .json => "json",
        .jsonl => "jsonl",
        .jsonc => "jsonc",
        .json5 => "json5",
        .markdown => "markdown",
        .xml => "xml",
        .yaml => "yaml",
    };
}

fn workloadName(workload: Workload) []const u8 {
    return switch (workload) {
        .fixture => "fixture",
        .sparse => "sparse",
        .dense => "dense",
        .escaped => "escaped",
        .unicode => "unicode",
    };
}

fn stageName(stage: Stage) []const u8 {
    return switch (stage) {
        .index => "index",
        .validate => "validate",
        .tape => "tape",
        .stream => "stream",
        .traverse_all => "traverse_all",
        .traverse_prefix8 => "traverse_prefix8",
    };
}

fn hashBytes(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash = (hash ^ byte) *% 0x100000001b3;
    }
    return hash;
}

fn mix(checksum: *u64, value: u64) void {
    checksum.* = (checksum.* ^ (value +% 0x9e3779b97f4a7c15)) *% 0x100000001b3;
}

fn mixBytes(checksum: *u64, bytes: []const u8) void {
    mix(checksum, @intCast(bytes.len));
    if (bytes.len <= CHECKSUM_BYTES) {
        mix(checksum, hashBytes(bytes));
    } else {
        mix(checksum, hashBytes(bytes[0..CHECKSUM_BYTES]));
        mix(checksum, hashBytes(bytes[bytes.len - CHECKSUM_BYTES ..]));
    }
}

fn sampleToken(index: usize, total: usize) bool {
    if (total == 0) return false;
    return index < 4 or index == total - 1 or index % CHECKSUM_STRIDE == 0;
}

fn mixNativeValue(checksum: *u64, value: anytype) void {
    const Value = @TypeOf(value);
    switch (@typeInfo(Value)) {
        .void => {},
        .bool => mix(checksum, @intFromBool(value)),
        .int => |info| {
            if (info.bits > 64) {
                @compileError("resident event integer payload exceeds 64 bits");
            }
            const Unsigned = @Int(.unsigned, info.bits);
            const bits: Unsigned = @bitCast(value);
            mix(checksum, @intCast(bits));
        },
        .float => |info| {
            if (info.bits > 64) {
                @compileError("resident event float payload exceeds 64 bits");
            }
            const Unsigned = @Int(.unsigned, info.bits);
            const bits: Unsigned = @bitCast(value);
            mix(checksum, @intCast(bits));
        },
        .@"enum" => mixNativeValue(checksum, @intFromEnum(value)),
        .@"struct" => |info| {
            mix(checksum, @intCast(info.fields.len));
            inline for (info.fields, 0..) |field, field_index| {
                mix(checksum, @intCast(field_index));
                mixNativeValue(checksum, @field(value, field.name));
            }
        },
        .@"union" => |info| {
            if (info.tag_type == null) {
                @compileError("resident event payload union must have a tag");
            }
            mixNativeValue(checksum, @intFromEnum(std.meta.activeTag(value)));
            switch (value) {
                inline else => |payload| mixNativeValue(checksum, payload),
            }
        },
        .optional => {
            if (value) |payload| {
                mix(checksum, 1);
                mixNativeValue(checksum, payload);
            } else {
                mix(checksum, 0);
            }
        },
        .array => |info| {
            if (info.child == u8) {
                mixBytes(checksum, value[0..]);
            } else {
                mix(checksum, @intCast(info.len));
                inline for (value) |element| mixNativeValue(checksum, element);
            }
        },
        .pointer => |info| {
            if (info.size != .slice or info.child != u8) {
                @compileError(
                    "resident event pointer payload must be a borrowed byte slice",
                );
            }
            mixBytes(checksum, value);
        },
        else => @compileError(
            "unsupported resident event payload type: " ++ @typeName(Value),
        ),
    }
}

fn consumeResidentEvents(
    reader: anytype,
    event_limit: ?usize,
    checksum: *u64,
) !void {
    if (event_limit) |limit| std.debug.assert(limit > 0);

    var event_count: usize = 0;
    var next_event = try reader.next();
    while (next_event) |event| {
        const next_count = event_count + 1;
        const limit_reached = if (event_limit) |limit|
            next_count >= limit
        else
            false;

        var following_event: @TypeOf(next_event) = null;
        if (!limit_reached) following_event = try reader.next();

        const sample = event_count < 4 or
            event_count % CHECKSUM_STRIDE == 0 or
            following_event == null;
        if (sample) mixNativeValue(checksum, event);
        std.mem.doNotOptimizeAway(&event);

        event_count = next_count;
        if (limit_reached) break;
        next_event = following_event;
    }
    mix(checksum, @intCast(event_count));
    std.mem.doNotOptimizeAway(reader);
}

fn stageSeed(input: Input, stage: Stage) u64 {
    var checksum = input.hash;
    mix(&checksum, @intFromEnum(input.format));
    mix(&checksum, @intFromEnum(input.workload));
    mix(&checksum, @intFromEnum(stage));
    return checksum;
}

fn consumeStructuralIndex(
    index: *const lib.StructuralIndex,
    checksum: *u64,
) void {
    mix(checksum, @intCast(index.count));
    for (index.slice(), 0..) |offset, token_index| {
        if (sampleToken(token_index, index.count)) mix(checksum, offset);
    }
    std.mem.doNotOptimizeAway(index);
}

fn consumeMarkdownIndex(
    index: *const lib.formats.markdown.MarkdownStructuralIndex,
    checksum: *u64,
) void {
    mix(checksum, @intCast(index.count));
    for (
        0..,
        index.indexes[0..index.count],
        index.kinds[0..index.count],
    ) |token_index, offset, kind| {
        if (!sampleToken(token_index, index.count)) continue;
        mix(checksum, offset);
        mix(checksum, @intFromEnum(kind));
    }
    std.mem.doNotOptimizeAway(index);
}

fn consumeYamlIndex(
    index: *const lib.formats.yaml.YamlStructuralIndex,
    checksum: *u64,
) void {
    mix(checksum, @intCast(index.count));
    for (
        0..,
        index.indexes[0..index.count],
        index.kinds[0..index.count],
        index.lengths[0..index.count],
    ) |token_index, offset, kind, length| {
        if (!sampleToken(token_index, index.count)) continue;
        mix(checksum, offset);
        mix(checksum, @intFromEnum(kind));
        mix(checksum, length);
    }
    std.mem.doNotOptimizeAway(index);
}

fn consumeJsonDocument(
    document: *const lib.stage2.Document,
    input: []const u8,
    checksum: *u64,
) !void {
    var cursor = try document.root(input);
    while (cursor.position() < document.tape.len) {
        const position = cursor.position();
        const word = try cursor.peek();
        if (sampleToken(position, document.tape.len)) {
            mix(checksum, word.kind);
            mix(checksum, word.payload);
            mix(checksum, word.offset);
            switch (word.tapeKind()) {
                .key, .string, .number, .true_literal, .false_literal, .null_literal => {
                    mixBytes(checksum, try cursor.rawValue());
                },
                else => {},
            }
        }
        try cursor.advance();
    }
    std.mem.doNotOptimizeAway(&cursor);
}

fn consumeJsonlDocument(
    document: *const lib.formats.jsonl.JsonlDocument,
    checksum: *u64,
) !void {
    mix(checksum, @intCast(document.records.len));
    for (document.records) |*record| {
        mix(checksum, @intCast(record.source_start));
        mix(checksum, @intCast(record.source_end));
        var cursor = try record.root();
        while (cursor.position() < record.document.tape.len) {
            const position = cursor.position();
            const word = try cursor.peek();
            if (sampleToken(position, record.document.tape.len)) {
                mix(checksum, word.kind);
                mix(checksum, word.payload);
                mix(checksum, word.offset);
                switch (word.tapeKind()) {
                    .key, .string, .number, .true_literal, .false_literal, .null_literal => {
                        mixBytes(checksum, try cursor.rawValue());
                    },
                    else => {},
                }
            }
            try cursor.advance();
        }
        std.mem.doNotOptimizeAway(&cursor);
    }
    std.mem.doNotOptimizeAway(document);
}

fn consumeMarkdownDocument(
    document: *const lib.formats.markdown.MarkdownDocument,
    input: []const u8,
    checksum: *u64,
) void {
    mix(checksum, @intCast(document.tape.len));
    for (document.tape, 0..) |word, token_index| {
        if (!sampleToken(token_index, document.tape.len)) continue;
        mix(checksum, word.kind);
        mix(checksum, word.payload);
        mix(checksum, word.offset);
        const offset: usize = @intCast(word.offset);
        if (offset < input.len) mix(checksum, input[offset]);
    }
    std.mem.doNotOptimizeAway(document);
}

fn consumeXmlDocument(
    document: *const lib.formats.xml.XmlDocument,
    input: []const u8,
    checksum: *u64,
) !void {
    mix(checksum, @intCast(document.tape.len));
    for (document.tape, 0..) |word, index| {
        if (!sampleToken(index, document.tape.len)) continue;
        mix(checksum, word.kind);
        mix(checksum, word.payload);
        mix(checksum, word.offset);
        mixBytes(checksum, try document.sourceSpan(input, index));
    }
    std.mem.doNotOptimizeAway(document);
}

fn consumeYamlDocument(
    document: *const lib.formats.yaml.YamlDocument,
    input: []const u8,
    checksum: *u64,
) !void {
    mix(checksum, @intCast(document.tape.len));
    var cursor = try document.root(input);
    while (cursor.position() < document.tape.len) {
        const position = cursor.position();
        const word = try cursor.peek();
        if (sampleToken(position, document.tape.len)) {
            mix(checksum, word.kind);
            mix(checksum, word.payload);
            mix(checksum, word.offset);
            switch (word.tapeKind()) {
                .key, .scalar => mixBytes(checksum, try cursor.span()),
                else => {},
            }
        }
        try cursor.advance();
    }
    std.mem.doNotOptimizeAway(&cursor);
    std.mem.doNotOptimizeAway(document);
}

fn consumeNoDiagnostic(result: anytype, checksum: *u64) !void {
    std.mem.doNotOptimizeAway(&result);
    if (result != null) return error.InvalidBenchmarkWorkload;
    mix(checksum, 0x51ed2705);
}

fn runIndexOnce(
    format: Format,
    allocator: Allocator,
    input: []const u8,
    checksum: *u64,
) !void {
    switch (format) {
        .json => {
            var index = try lib.formats.json.indexJson(allocator, input);
            errdefer index.deinit(allocator);
            consumeStructuralIndex(&index, checksum);
            index.deinit(allocator);
        },
        .jsonl => {
            var index = try lib.formats.jsonl.indexJsonl(allocator, input);
            errdefer index.deinit(allocator);
            consumeStructuralIndex(&index, checksum);
            index.deinit(allocator);
        },
        .jsonc => {
            var index = try lib.formats.jsonc.indexJsonc(allocator, input);
            errdefer index.deinit(allocator);
            consumeStructuralIndex(&index, checksum);
            index.deinit(allocator);
        },
        .json5 => {
            var index = try lib.formats.json5.indexJson5(allocator, input);
            errdefer index.deinit(allocator);
            consumeStructuralIndex(&index, checksum);
            index.deinit(allocator);
        },
        .markdown => {
            var index = try lib.formats.markdown.indexMarkdown(allocator, input);
            errdefer index.deinit(allocator);
            consumeMarkdownIndex(&index, checksum);
            index.deinit(allocator);
        },
        .xml => {
            var index = try lib.formats.xml.indexXml(allocator, input);
            errdefer index.deinit(allocator);
            mix(checksum, @intCast(index.count));
            for (
                0..,
                index.indexes[0..index.count],
                index.kinds[0..index.count],
            ) |token_index, offset, kind| {
                if (!sampleToken(token_index, index.count)) continue;
                mix(checksum, offset);
                mix(checksum, @intFromEnum(kind));
            }
            std.mem.doNotOptimizeAway(&index);
            index.deinit(allocator);
        },
        .yaml => {
            var index = try lib.formats.yaml.indexYaml(allocator, input);
            errdefer index.deinit(allocator);
            consumeYamlIndex(&index, checksum);
            index.deinit(allocator);
        },
    }
}

fn runValidateOnce(
    format: Format,
    allocator: Allocator,
    input: []const u8,
    checksum: *u64,
) !void {
    switch (format) {
        .json => {
            const result = try lib.formats.json.validateJson(allocator, input);
            try consumeNoDiagnostic(result, checksum);
        },
        .jsonl => {
            const result = try lib.formats.jsonl.validateJsonl(allocator, input);
            try consumeNoDiagnostic(result, checksum);
        },
        .jsonc => {
            const result = try lib.formats.jsonc.validateJsonc(allocator, input);
            try consumeNoDiagnostic(result, checksum);
        },
        .json5 => {
            const result = try lib.formats.json5.validateJson5(allocator, input);
            try consumeNoDiagnostic(result, checksum);
        },
        .markdown => {
            const result = try lib.formats.markdown.validateMarkdown(allocator, input);
            try consumeNoDiagnostic(result, checksum);
        },
        .xml => {
            const result = try lib.formats.xml.validateXml(input);
            try consumeNoDiagnostic(result, checksum);
        },
        .yaml => {
            const result = try lib.formats.yaml.validateYaml(allocator, input);
            try consumeNoDiagnostic(result, checksum);
        },
    }
}

fn runTapeOnce(
    format: Format,
    allocator: Allocator,
    input: []const u8,
    checksum: *u64,
) !void {
    switch (format) {
        .json => {
            var document = try lib.formats.json.buildJsonTape(allocator, input);
            errdefer document.deinit(allocator);
            try consumeJsonDocument(&document, input, checksum);
            document.deinit(allocator);
        },
        .jsonl => {
            var document = try lib.formats.jsonl.buildJsonlTape(allocator, input);
            errdefer document.deinit(allocator);
            try consumeJsonlDocument(&document, checksum);
            document.deinit(allocator);
        },
        .jsonc => {
            var document = try lib.formats.jsonc.buildJsoncTape(allocator, input);
            errdefer document.deinit(allocator);
            try consumeJsonDocument(&document, input, checksum);
            document.deinit(allocator);
        },
        .json5 => {
            var document = try lib.formats.json5.buildJson5Tape(allocator, input);
            errdefer document.deinit(allocator);
            try consumeJsonDocument(&document, input, checksum);
            document.deinit(allocator);
        },
        .markdown => {
            var document = try lib.formats.markdown.buildMarkdownTape(allocator, input);
            errdefer document.deinit(allocator);
            consumeMarkdownDocument(&document, input, checksum);
            document.deinit(allocator);
        },
        .xml => {
            var document = try lib.formats.xml.buildXmlTape(allocator, input);
            errdefer document.deinit(allocator);
            try consumeXmlDocument(&document, input, checksum);
            document.deinit(allocator);
        },
        .yaml => {
            var document = try lib.formats.yaml.buildYamlTape(allocator, input);
            errdefer document.deinit(allocator);
            try consumeYamlDocument(&document, input, checksum);
            document.deinit(allocator);
        },
    }
}

fn feedChunks(indexer: anytype, input: []const u8) !void {
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(offset + STREAM_CHUNK_LEN, input.len);
        try indexer.feed(input[offset..end]);
        offset = end;
    }
}

fn runStreamOnce(
    format: Format,
    allocator: Allocator,
    input: []const u8,
    checksum: *u64,
) !void {
    switch (format) {
        .json => {
            var indexer = try lib.formats.json.initStreamIndexer(allocator, STREAM_CHUNK_LEN);
            errdefer indexer.deinit();
            try feedChunks(&indexer, input);
            try indexer.finish();
            var index = indexer.take();
            indexer.deinit();
            errdefer index.deinit(allocator);
            consumeStructuralIndex(&index, checksum);
            index.deinit(allocator);
        },
        .jsonl => {
            var indexer = try lib.formats.jsonl.initStreamIndexer(allocator, STREAM_CHUNK_LEN);
            errdefer indexer.deinit();
            try feedChunks(&indexer, input);
            try indexer.finish();
            var index = indexer.take();
            indexer.deinit();
            errdefer index.deinit(allocator);
            consumeStructuralIndex(&index, checksum);
            index.deinit(allocator);
        },
        .jsonc => {
            var indexer = try lib.formats.jsonc.initStreamIndexer(allocator, STREAM_CHUNK_LEN);
            errdefer indexer.deinit();
            try feedChunks(&indexer, input);
            try indexer.finish();
            var index = indexer.take();
            indexer.deinit();
            errdefer index.deinit(allocator);
            consumeStructuralIndex(&index, checksum);
            index.deinit(allocator);
        },
        .json5 => {
            var indexer = try lib.formats.json5.initStreamIndexer(allocator, STREAM_CHUNK_LEN);
            errdefer indexer.deinit();
            try feedChunks(&indexer, input);
            try indexer.finish();
            var index = indexer.take();
            indexer.deinit();
            errdefer index.deinit(allocator);
            consumeStructuralIndex(&index, checksum);
            index.deinit(allocator);
        },
        .markdown => {
            var indexer = try lib.formats.markdown.MarkdownStreamIndexer.init(
                allocator,
                STREAM_CHUNK_LEN,
            );
            errdefer indexer.deinit();
            try feedChunks(&indexer, input);
            try indexer.finish();
            var index = indexer.take();
            indexer.deinit();
            errdefer index.deinit(allocator);
            consumeMarkdownIndex(&index, checksum);
            index.deinit(allocator);
        },
        .xml => {
            var indexer = try lib.formats.xml.XmlStreamIndexer.init(allocator, STREAM_CHUNK_LEN);
            errdefer indexer.deinit();
            try feedChunks(&indexer, input);
            try indexer.finish();
            var index = indexer.take();
            indexer.deinit();
            errdefer index.deinit(allocator);
            mix(checksum, @intCast(index.count));
            for (
                0..,
                index.indexes[0..index.count],
                index.kinds[0..index.count],
            ) |token_index, offset, kind| {
                if (!sampleToken(token_index, index.count)) continue;
                mix(checksum, offset);
                mix(checksum, @intFromEnum(kind));
            }
            std.mem.doNotOptimizeAway(&index);
            index.deinit(allocator);
        },
        .yaml => {
            var indexer = try lib.formats.yaml.YamlStreamIndexer.init(allocator, STREAM_CHUNK_LEN);
            errdefer indexer.deinit();
            try feedChunks(&indexer, input);
            try indexer.finish();
            var index = indexer.take();
            indexer.deinit();
            errdefer index.deinit(allocator);
            consumeYamlIndex(&index, checksum);
            index.deinit(allocator);
        },
    }
}

fn runResidentOnce(
    parser: anytype,
    input: []const u8,
    event_limit: ?usize,
    checksum: *u64,
    comptime init_document: anytype,
) !void {
    var document = try init_document(parser, input);
    defer document.deinit();

    var reader = try document.eventReader();
    try consumeResidentEvents(&reader, event_limit, checksum);
    std.mem.doNotOptimizeAway(&document);
}

fn runResidentStageFor(
    comptime Parser: type,
    io: std.Io,
    allocator: Allocator,
    input: Input,
    stage: Stage,
    iterations: usize,
    comptime init_document: anytype,
) !Sample {
    const event_limit: ?usize = switch (stage) {
        .traverse_all => null,
        .traverse_prefix8 => RESIDENT_PREFIX_EVENT_COUNT,
        else => unreachable,
    };

    var counting = CountingAllocator{ .child = allocator };
    const counted = counting.allocator();
    var parser = try Parser.init(counted, input.bytes.len);
    defer parser.deinit();

    var warmup_checksum = input.hash;
    try runResidentOnce(
        &parser,
        input.bytes,
        event_limit,
        &warmup_checksum,
        init_document,
    );
    counting.reset();

    var checksum = stageSeed(input, stage);
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        try runResidentOnce(
            &parser,
            input.bytes,
            event_limit,
            &checksum,
            init_document,
        );
        std.mem.doNotOptimizeAway(&checksum);
    }
    const end = std.Io.Clock.awake.now(io).nanoseconds;
    std.mem.doNotOptimizeAway(&checksum);
    return .{
        .elapsed_ns = try elapsedNanoseconds(start, end),
        .checksum = checksum,
        .allocation_count = counting.allocation_count,
        .allocated_bytes = counting.allocated_bytes,
    };
}

fn runResidentStage(
    io: std.Io,
    allocator: Allocator,
    input: Input,
    stage: Stage,
    iterations: usize,
) !Sample {
    return switch (input.format) {
        .json => runResidentStageFor(
            lib.ondemand.Parser,
            io,
            allocator,
            input,
            stage,
            iterations,
            lib.formats.json.initOnDemandDocument,
        ),
        .jsonl => runResidentStageFor(
            lib.formats.jsonl.Parser,
            io,
            allocator,
            input,
            stage,
            iterations,
            lib.formats.jsonl.initOnDemandDocument,
        ),
        .jsonc => runResidentStageFor(
            lib.ondemand.Parser,
            io,
            allocator,
            input,
            stage,
            iterations,
            lib.formats.jsonc.initOnDemandDocument,
        ),
        .json5 => runResidentStageFor(
            lib.ondemand.Parser,
            io,
            allocator,
            input,
            stage,
            iterations,
            lib.formats.json5.initOnDemandDocument,
        ),
        .markdown => runResidentStageFor(
            lib.formats.markdown.Parser,
            io,
            allocator,
            input,
            stage,
            iterations,
            lib.formats.markdown.initOnDemandDocument,
        ),
        .xml => runResidentStageFor(
            lib.formats.xml.Parser,
            io,
            allocator,
            input,
            stage,
            iterations,
            lib.formats.xml.initOnDemandDocument,
        ),
        .yaml => runResidentStageFor(
            lib.formats.yaml.Parser,
            io,
            allocator,
            input,
            stage,
            iterations,
            lib.formats.yaml.initOnDemandDocument,
        ),
    };
}

fn elapsedNanoseconds(start: i96, end: i96) !u64 {
    if (end < start) return error.ClockWentBackwards;
    const delta: i96 = end - start;
    if (delta > std.math.maxInt(u64)) return error.ElapsedOverflow;
    return @intCast(delta);
}

fn runStage(
    io: std.Io,
    allocator: Allocator,
    input: Input,
    stage: Stage,
    iterations: usize,
) !Sample {
    switch (stage) {
        .traverse_all, .traverse_prefix8 => {
            return runResidentStage(io, allocator, input, stage, iterations);
        },
        .index, .validate, .tape, .stream => {},
    }

    var counting = CountingAllocator{ .child = allocator };
    counting.reset();
    const counted = counting.allocator();
    var checksum = stageSeed(input, stage);
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        switch (stage) {
            .index => try runIndexOnce(input.format, counted, input.bytes, &checksum),
            .validate => try runValidateOnce(input.format, counted, input.bytes, &checksum),
            .tape => try runTapeOnce(input.format, counted, input.bytes, &checksum),
            .stream => try runStreamOnce(input.format, counted, input.bytes, &checksum),
            .traverse_all, .traverse_prefix8 => unreachable,
        }
        std.mem.doNotOptimizeAway(&checksum);
    }
    const end = std.Io.Clock.awake.now(io).nanoseconds;
    std.mem.doNotOptimizeAway(&checksum);
    return .{
        .elapsed_ns = try elapsedNanoseconds(start, end),
        .checksum = checksum,
        .allocation_count = counting.allocation_count,
        .allocated_bytes = counting.allocated_bytes,
    };
}

fn fixtureInput(format: Format) []const u8 {
    return switch (format) {
        .json => @embedFile("test/corpus/json/example_config.json"),
        .jsonl => @embedFile("test/corpus/jsonl/amazon_cellphones.ndjson"),
        .jsonc => @embedFile("test/corpus/jsonc/config.jsonc"),
        .json5 => @embedFile("test/corpus/json5/sample.json5"),
        .markdown => @embedFile("test/corpus/markdown/document.md"),
        .xml => @embedFile("test/corpus/xml/catalog.xml"),
        .yaml => @embedFile("test/corpus/yaml/basic.yaml"),
    };
}

fn buildJsonWorkload(allocator: Allocator, workload: Workload) ![]const u8 {
    var builder = ByteBuilder.init(allocator);
    errdefer builder.deinit();
    switch (workload) {
        .sparse => {
            try builder.append("{\n");
            for (0..96 * workload_scale) |index| {
                try builder.append("  \"key");
                try builder.appendUsize(index);
                try builder.append("\": ");
                try builder.appendUsize(index * 17);
                try builder.append(if (index + 1 == 96 * workload_scale) "\n" else ",\n");
            }
            try builder.append("}\n");
        },
        .dense => {
            try builder.append("[");
            for (0..1024 * workload_scale) |index| {
                try builder.appendUsize(index * 3 + 1);
                if (index + 1 != 1024 * workload_scale) try builder.appendByte(',');
            }
            try builder.append("]\n");
        },
        .escaped => {
            try builder.append("{\n");
            for (0..192 * workload_scale) |index| {
                try builder.append("  \"text");
                try builder.appendUsize(index);
                try builder.append("\": \"line\\nquote\\\"slash\\\\\"");
                try builder.append(if (index + 1 == 192 * workload_scale) "\n" else ",\n");
            }
            try builder.append("}\n");
        },
        .unicode => {
            try builder.append("{\n");
            for (0..192 * workload_scale) |index| {
                try builder.append("  \"text");
                try builder.appendUsize(index);
                try builder.append("\": \"Grüße ☃ café 東京\"");
                try builder.append(if (index + 1 == 192 * workload_scale) "\n" else ",\n");
            }
            try builder.append("}\n");
        },
        .fixture => unreachable,
    }
    return builder.finish();
}

fn buildJsonlWorkload(allocator: Allocator, workload: Workload) ![]const u8 {
    var builder = ByteBuilder.init(allocator);
    errdefer builder.deinit();
    const count: usize = switch (workload) {
        .sparse => 96 * workload_scale,
        .dense => 768 * workload_scale,
        .escaped, .unicode => 192 * workload_scale,
        .fixture => unreachable,
    };
    for (0..count) |index| {
        try builder.append("{\"id\":");
        try builder.appendUsize(index);
        switch (workload) {
            .sparse => {
                try builder.append(",\"value\":");
                try builder.appendUsize(index * 11);
            },
            .dense => {
                try builder.append(",\"a\":");
                try builder.appendUsize(index);
                try builder.append(",\"b\":");
                try builder.appendUsize(index * 2);
                try builder.append(",\"c\":true,\"d\":null");
            },
            .escaped => try builder.append(",\"text\":\"line\\nquote\\\"slash\\\\\""),
            .unicode => try builder.append(",\"text\":\"Grüße ☃ café 東京\""),
            .fixture => unreachable,
        }
        try builder.append("}\n");
    }
    return builder.finish();
}

fn buildJsoncWorkload(allocator: Allocator, workload: Workload) ![]const u8 {
    var builder = ByteBuilder.init(allocator);
    errdefer builder.deinit();
    switch (workload) {
        .sparse => {
            try builder.append("{\n");
            for (0..96 * workload_scale) |index| {
                if (index % 3 == 0) try builder.append("  // sparse gap\n");
                try builder.append("  \"key");
                try builder.appendUsize(index);
                try builder.append("\": ");
                try builder.appendUsize(index * 13);
                try builder.append(if (index + 1 == 96 * workload_scale) "\n" else ",\n");
            }
            try builder.append("}\n");
        },
        .dense => {
            try builder.append("[");
            for (0..1024 * workload_scale) |index| {
                try builder.appendUsize(index);
                if (index + 1 != 1024 * workload_scale) try builder.appendByte(',');
            }
            try builder.append("]\n");
        },
        .escaped => {
            try builder.append("{\n");
            for (0..192 * workload_scale) |index| {
                try builder.append("  \"text");
                try builder.appendUsize(index);
                try builder.append("\": \"line\\nquote\\\"slash\\\\\"");
                if (index % 4 == 0) try builder.append(" /* comment */");
                try builder.append(if (index + 1 == 192 * workload_scale) "\n" else ",\n");
            }
            try builder.append("}\n");
        },
        .unicode => {
            try builder.append("{\n  // Unicode values\n");
            for (0..192 * workload_scale) |index| {
                try builder.append("  \"text");
                try builder.appendUsize(index);
                try builder.append("\": \"Grüße ☃ café 東京\"");
                try builder.append(if (index + 1 == 192 * workload_scale) "\n" else ",\n");
            }
            try builder.append("}\n");
        },
        .fixture => unreachable,
    }
    return builder.finish();
}

fn buildJson5Workload(allocator: Allocator, workload: Workload) ![]const u8 {
    var builder = ByteBuilder.init(allocator);
    errdefer builder.deinit();
    switch (workload) {
        .sparse => {
            try builder.append("{\n");
            for (0..96 * workload_scale) |index| {
                try builder.append("  key");
                try builder.appendUsize(index);
                try builder.append(": ");
                try builder.appendUsize(index * 7);
                try builder.append(",\n");
            }
            try builder.append("}\n");
        },
        .dense => {
            try builder.append("[");
            for (0..1024 * workload_scale) |index| {
                try builder.appendUsize(index);
                try builder.append(if (index + 1 == 1024 * workload_scale) ",]" else ",");
            }
            try builder.append("\n");
        },
        .escaped => {
            try builder.append("{\n");
            for (0..192 * workload_scale) |index| {
                try builder.append("  key");
                try builder.appendUsize(index);
                try builder.append(": 'line\\nquote\\'slash\\\\',\n");
            }
            try builder.append("}\n");
        },
        .unicode => {
            try builder.append("{\n");
            for (0..192 * workload_scale) |index| {
                try builder.append("  key");
                try builder.appendUsize(index);
                try builder.append(": 'Grüße ☃ café 東京',\n");
            }
            try builder.append("}\n");
        },
        .fixture => unreachable,
    }
    return builder.finish();
}

fn buildMarkdownWorkload(allocator: Allocator, workload: Workload) ![]const u8 {
    var builder = ByteBuilder.init(allocator);
    errdefer builder.deinit();
    const count: usize = switch (workload) {
        .sparse => 192 * workload_scale,
        .dense => 768 * workload_scale,
        .escaped, .unicode => 256 * workload_scale,
        .fixture => unreachable,
    };
    for (0..count) |index| {
        switch (workload) {
            .sparse => {
                try builder.append("\n## Section ");
                try builder.appendUsize(index);
                try builder.append("\n\nSparse paragraph.\n");
            },
            .dense => {
                try builder.append("- item ");
                try builder.appendUsize(index);
                try builder.append(" [link](https://example.test/item)\n");
            },
            .escaped => {
                try builder.append("- item ");
                try builder.appendUsize(index);
                try builder.append(" with \\*literal\\* and \\\\ slash\n");
            },
            .unicode => {
                try builder.append("# Título ");
                try builder.appendUsize(index);
                try builder.append(" — Grüße ☃ café 東京\n");
            },
            .fixture => unreachable,
        }
    }
    return builder.finish();
}

fn buildXmlWorkload(allocator: Allocator, workload: Workload) ![]const u8 {
    var builder = ByteBuilder.init(allocator);
    errdefer builder.deinit();
    switch (workload) {
        .sparse => {
            try builder.append("<root>\n");
            for (0..192 * workload_scale) |index| {
                try builder.append("  <item id=\"");
                try builder.appendUsize(index);
                try builder.append("\"> ");
                try builder.appendUsize(index * 5);
                try builder.append(" </item>\n");
            }
            try builder.append("</root>\n");
        },
        .dense => {
            try builder.append("<root>");
            for (0..768 * workload_scale) |index| {
                try builder.append("<item id=\"");
                try builder.appendUsize(index);
                try builder.append("\"/>");
            }
            try builder.append("</root>\n");
        },
        .escaped => {
            try builder.append("<root>");
            for (0..192 * workload_scale) |index| {
                try builder.append("<item id=\"");
                try builder.appendUsize(index);
                try builder.append("\">Tom &amp; Jerry &lt;3<![CDATA[line <raw> ");
                try builder.appendUsize(index);
                try builder.append("]]></item>");
            }
            try builder.append("</root>\n");
        },
        .unicode => {
            try builder.append("<root>");
            for (0..192 * workload_scale) |index| {
                try builder.append("<item id=\"");
                try builder.appendUsize(index);
                try builder.append("\">Grüße ☃ café 東京</item>");
            }
            try builder.append("</root>\n");
        },
        .fixture => unreachable,
    }
    return builder.finish();
}

fn buildYamlWorkload(allocator: Allocator, workload: Workload) ![]const u8 {
    var builder = ByteBuilder.init(allocator);
    errdefer builder.deinit();
    switch (workload) {
        .sparse => {
            try builder.append("---\nroot:\n");
            for (0..96 * workload_scale) |index| {
                try builder.append("  key");
                try builder.appendUsize(index);
                try builder.append(": value");
                try builder.appendUsize(index);
                try builder.append("\n");
            }
            try builder.append("...\n");
        },
        .dense => {
            try builder.append("root: [");
            for (0..768 * workload_scale) |index| {
                try builder.append("value");
                try builder.appendUsize(index);
                if (index + 1 != 768 * workload_scale) try builder.append(", ");
            }
            try builder.append("]\n");
        },
        .escaped => {
            try builder.append("root:\n");
            for (0..192 * workload_scale) |index| {
                try builder.append("  text");
                try builder.appendUsize(index);
                try builder.append(": \"three\\u0033\"\n");
            }
        },
        .unicode => {
            try builder.append("root:\n");
            for (0..192 * workload_scale) |index| {
                try builder.append("  greeting");
                try builder.appendUsize(index);
                try builder.append(": Grüße ☃ café 東京\n");
            }
        },
        .fixture => unreachable,
    }
    return builder.finish();
}

fn generatedInput(allocator: Allocator, format: Format, workload: Workload) ![]const u8 {
    return switch (format) {
        .json => buildJsonWorkload(allocator, workload),
        .jsonl => buildJsonlWorkload(allocator, workload),
        .jsonc => buildJsoncWorkload(allocator, workload),
        .json5 => buildJson5Workload(allocator, workload),
        .markdown => buildMarkdownWorkload(allocator, workload),
        .xml => buildXmlWorkload(allocator, workload),
        .yaml => buildYamlWorkload(allocator, workload),
    };
}

fn buildInputs(allocator: Allocator) ![input_count]Input {
    var inputs: [input_count]Input = undefined;
    var input_index: usize = 0;
    for (formats) |format| {
        for (workloads) |workload| {
            const bytes = if (workload == .fixture)
                fixtureInput(format)
            else
                try generatedInput(allocator, format, workload);
            inputs[input_index] = .{
                .format = format,
                .workload = workload,
                .bytes = bytes,
                .hash = hashBytes(bytes),
            };
            input_index += 1;
        }
    }
    return inputs;
}

fn parseIterations(args: []const []const u8) !usize {
    if (args.len > 2) return error.UnexpectedArgument;
    if (args.len == 1) return DEFAULT_ITERATIONS;
    const iterations = std.fmt.parseUnsigned(usize, args[1], 10) catch {
        return error.InvalidIterationCount;
    };
    if (iterations == 0) return error.InvalidIterationCount;
    return iterations;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const iterations = try parseIterations(args);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("# zig_version={s}\n", .{builtin.zig_version_string});
    try stdout.print("# optimize={t}\n", .{builtin.mode});
    try stdout.print("# target_arch={t}\n", .{builtin.target.cpu.arch});
    try stdout.print(
        "# vector_len={d}\n",
        .{build_options.vector_len orelse lib.default_vector_len},
    );
    try stdout.print("# stream_chunk_bytes={d}\n", .{STREAM_CHUNK_LEN});
    try stdout.print("# synthetic_scale={d}\n", .{workload_scale});
    try stdout.print(
        "# consumption=checksum samples first4,last,every64 tokens; raw spans max128 bytes; included in elapsed_ns\n",
        .{},
    );
    try stdout.print(
        "# resident_setup=parser init and stage warmup excluded; counters reset after setup; " ++
            "document init/indexing,traversal,release included in elapsed_ns\n",
        .{},
    );
    try stdout.print(
        "# resident_consumption=checksum samples first4,last,every64 native events; " ++
            "raw byte spans max128 bytes; included in elapsed_ns\n",
        .{},
    );
    try stdout.print(
        "# traverse_prefix8=first 8 native events or EOF, then document release\n",
        .{},
    );
    try stdout.print(
        "# baseline=index,validate,tape,stream have pre-feature baselines; " ++
            "traverse_all,traverse_prefix8 have no pre-feature baseline\n",
        .{},
    );
    try stdout.print(
        "format,workload,stage,input_bytes,iterations,elapsed_ns,checksum,allocation_count,allocated_bytes\n",
        .{},
    );

    const inputs = try buildInputs(arena);
    for (inputs) |input| {
        try stdout.print(
            "# input format={s} workload={s} input_hash={x}\n",
            .{ formatName(input.format), workloadName(input.workload), input.hash },
        );
        for (stages) |stage| {
            const sample = try runStage(init.io, init.gpa, input, stage, iterations);
            try stdout.print(
                "{s},{s},{s},{d},{d},{d},{d},{d},{d}\n",
                .{
                    formatName(input.format),
                    workloadName(input.workload),
                    stageName(stage),
                    input.bytes.len,
                    iterations,
                    sample.elapsed_ns,
                    sample.checksum,
                    sample.allocation_count,
                    sample.allocated_bytes,
                },
            );
        }
    }
    try stdout.flush();
}
