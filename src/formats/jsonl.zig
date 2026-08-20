const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const stage2 = @import("../core/stage2.zig");

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

const IndexedRecord = struct {
    source_start: usize,
    source_end: usize,
    structural_index: stage1.StructuralIndex,
};

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

    const indexed_records = try collectRecordIndexes(allocator, input, &structural_index);
    defer {
        for (indexed_records) |*indexed_record| {
            indexed_record.structural_index.deinit(allocator);
        }
        allocator.free(indexed_records);
    }

    var records = try std.ArrayList(JsonlRecord).initCapacity(
        allocator,
        indexed_records.len,
    );
    errdefer {
        for (records.items) |*record_value| {
            record_value.deinit(allocator);
        }
        records.deinit(allocator);
    }

    for (indexed_records) |*indexed_record| {
        const record_source =
            input[indexed_record.source_start..indexed_record.source_end];
        var document = try stage2.buildTape(
            allocator,
            record_source,
            &indexed_record.structural_index,
            .json,
        );
        records.append(allocator, .{
            .source = record_source,
            .source_start = indexed_record.source_start,
            .source_end = indexed_record.source_end,
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

    const indexed_records = try collectRecordIndexes(allocator, input, &structural_index);
    defer {
        for (indexed_records) |*indexed_record| {
            indexed_record.structural_index.deinit(allocator);
        }
        allocator.free(indexed_records);
    }

    for (indexed_records, 0..) |*indexed_record, record_index| {
        const record_source =
            input[indexed_record.source_start..indexed_record.source_end];
        const diagnostic = try stage2.validate(
            record_source,
            &indexed_record.structural_index,
            .json,
        );
        if (diagnostic) |local| {
            const global = stage2.diagnosticAt(
                input,
                local.err,
                indexed_record.source_start + @min(
                    local.byte_offset,
                    indexed_record.source_end - indexed_record.source_start,
                ),
            );
            return .{
                .record_index = record_index,
                .source_start = indexed_record.source_start,
                .source_end = indexed_record.source_end,
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

fn collectRecordIndexes(
    allocator: std.mem.Allocator,
    input: []const u8,
    structural_index: *const stage1.StructuralIndex,
) stage2.ValidationError![]IndexedRecord {
    var records = std.ArrayList(IndexedRecord).empty;
    errdefer {
        for (records.items) |*record| {
            record.structural_index.deinit(allocator);
        }
        records.deinit(allocator);
    }

    var record_offsets = std.ArrayList(u32).empty;
    defer record_offsets.deinit(allocator);

    var record_start: usize = 0;
    for (structural_index.slice()) |raw_offset| {
        const offset: usize = @intCast(raw_offset);
        if (offset >= input.len) continue;

        if (input[offset] == '\n') {
            try appendIndexedRecord(
                allocator,
                input,
                &records,
                &record_offsets,
                record_start,
                offset,
            );
            record_start = offset + 1;
            continue;
        }

        if (offset < record_start) continue;
        try record_offsets.append(allocator, @intCast(offset - record_start));
    }

    if (record_start < input.len) {
        try appendIndexedRecord(
            allocator,
            input,
            &records,
            &record_offsets,
            record_start,
            input.len,
        );
    }

    return records.toOwnedSlice(allocator);
}

fn appendIndexedRecord(
    allocator: std.mem.Allocator,
    input: []const u8,
    records: *std.ArrayList(IndexedRecord),
    record_offsets: *std.ArrayList(u32),
    source_start: usize,
    source_end: usize,
) stage2.ValidationError!void {
    const source = input[source_start..source_end];
    if (isBlankRecord(source)) {
        record_offsets.clearRetainingCapacity();
        return;
    }

    var index = stage1.StructuralIndex.init(
        allocator,
        record_offsets.items.len,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    errdefer index.deinit(allocator);

    @memcpy(index.indexes[0..record_offsets.items.len], record_offsets.items);
    index.count = record_offsets.items.len;
    index.finish(source.len) catch return error.TapeTooLarge;

    try records.append(allocator, .{
        .source_start = source_start,
        .source_end = source_end,
        .structural_index = index,
    });
    record_offsets.clearRetainingCapacity();
}

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

pub fn indexJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    return indexJsonlImpl(simd.default_vector_len, allocator, input);
}

pub fn indexJsonlImpl(
    comptime VLEN: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    const Mask = simd.Mask(VLEN);
    const top_bit: Mask = @as(Mask, 1) << (VLEN - 1);

    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);

    var windows = simd.windows(u8, VLEN, input, 0);
    var base_offset: usize = 0;
    var prev_in_string = false;
    var prev_ends_in_backslash = false;
    var prev_backslash_run_odd = false;
    var prev_in_atom = false;

    while (base_offset < input.len) {
        const chunk = windows.next().?;
        const valid_count = @min(input.len - base_offset, VLEN);
        const valid_mask = validByteMask(VLEN, valid_count);

        const backslashes = simd.matchByte(VLEN, chunk, '\\') & valid_mask;
        const backslash_result = simd.computeBackslashRuns(
            Mask,
            backslashes,
            prev_ends_in_backslash,
        );
        var odd_backslash_ends = backslash_result.odd_length_ends & valid_mask;
        if (prev_ends_in_backslash) {
            if ((backslashes & 1) == 0) {
                if (prev_backslash_run_odd) {
                    odd_backslash_ends |= 1;
                } else {
                    odd_backslash_ends &= ~@as(Mask, 1);
                }
            } else if (prev_backslash_run_odd) {
                odd_backslash_ends ^= leadingRunEndMask(VLEN, backslashes, valid_count);
            }
        }

        const quotes = simd.matchByte(VLEN, chunk, '"') & valid_mask;
        const unescaped_quotes = quotes & ~odd_backslash_ends;
        const inside_without_closing = simd.prefixXor(Mask, unescaped_quotes) ^
            if (prev_in_string) ~@as(Mask, 0) else 0;
        const opening_quotes = unescaped_quotes & inside_without_closing;
        const string_mask = inside_without_closing | unescaped_quotes;
        const outside_string = ~string_mask & valid_mask;

        const structural = simd.matchAny4(VLEN, chunk, '{', '}', '[', ']') |
            simd.matchAny2(VLEN, chunk, ':', ',');
        const whitespace = simd.matchAny4(VLEN, chunk, ' ', '\t', '\n', '\r');
        const atom_candidates = simd.matchRange(VLEN, chunk, '0', '9') |
            simd.matchAny4(VLEN, chunk, '-', 't', 'f', 'n');
        const atom_active = outside_string & ~(structural | whitespace | quotes);
        const atom_starts = atom_candidates & atom_active &
            ~((atom_active << 1) | if (prev_in_atom) @as(Mask, 1) else 0);
        const record_boundaries = simd.matchByte(VLEN, chunk, '\n');
        const structural_indexes =
            ((structural | atom_starts | record_boundaries) & outside_string) |
            opening_quotes;

        var candidate_indexes: [VLEN]u32 = undefined;
        const candidate_count = simd.extractBitIndexes(
            Mask,
            structural_indexes,
            base_offset,
            &candidate_indexes,
        );
        @memcpy(
            indexes.indexes[indexes.count..][0..candidate_count],
            candidate_indexes[0..candidate_count],
        );
        indexes.count += candidate_count;

        prev_in_string = (inside_without_closing & top_bit) != 0;
        prev_ends_in_backslash =
            valid_count == VLEN and (backslashes & top_bit) != 0;
        prev_backslash_run_odd = trailingBackslashRunOdd(
            VLEN,
            chunk,
            valid_count,
            prev_backslash_run_odd,
        );
        prev_in_atom = valid_count != 0 and
            (atom_active &
                (@as(Mask, 1) <<
                    @as(std.math.Log2Int(Mask), @intCast(valid_count - 1)))) != 0;
        base_offset += VLEN;
    }

    try indexes.finish(input.len);
    return indexes;
}

fn validByteMask(comptime VLEN: usize, valid_count: usize) simd.Mask(VLEN) {
    const Mask = simd.Mask(VLEN);
    if (valid_count == VLEN) return ~@as(Mask, 0);
    if (valid_count == 0) return 0;
    return (@as(Mask, 1) <<
        @as(std.math.Log2Int(Mask), @intCast(valid_count))) - 1;
}

fn leadingRunEndMask(
    comptime VLEN: usize,
    backslashes: simd.Mask(VLEN),
    valid_count: usize,
) simd.Mask(VLEN) {
    const Mask = simd.Mask(VLEN);
    const non_backslashes = ~backslashes | ~validByteMask(VLEN, valid_count);
    if (non_backslashes == 0) return 0;
    const run_length: usize = @ctz(non_backslashes);
    if (run_length >= valid_count) return 0;
    return @as(Mask, 1) <<
        @as(std.math.Log2Int(Mask), @intCast(run_length));
}

fn trailingBackslashRunOdd(
    comptime VLEN: usize,
    chunk: simd.Vec(VLEN, u8),
    valid_count: usize,
    prev_run_odd: bool,
) bool {
    if (valid_count == 0) return false;
    const bytes: [VLEN]u8 = chunk;
    var run_length: usize = 0;
    var index = valid_count;
    while (index > 0 and bytes[index - 1] == '\\') : (index -= 1) {
        run_length += 1;
    }
    if (index == 0) return (run_length % 2 == 0) == prev_run_odd;
    return run_length % 2 != 0;
}

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

test "refAllDecls" {
    testing.refAllDecls(@This());
    _ = simd;
}
