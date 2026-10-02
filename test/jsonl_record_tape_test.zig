const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

const jsonl = lib.formats.jsonl;
const stage2 = lib.stage2;

fn expectDiagnosticEqual(
    expected: jsonl.JsonlDiagnostic,
    actual: jsonl.JsonlDiagnostic,
) !void {
    try testing.expectEqual(expected.record_index, actual.record_index);
    try testing.expectEqual(expected.source_start, actual.source_start);
    try testing.expectEqual(expected.source_end, actual.source_end);
    try testing.expectEqual(expected.err, actual.err);
    try testing.expectEqual(expected.byte_offset, actual.byte_offset);
    try testing.expectEqual(expected.line, actual.line);
    try testing.expectEqual(expected.column, actual.column);
    try testing.expectEqual(expected.snippet_start, actual.snippet_start);
    try testing.expectEqualStrings(expected.snippet, actual.snippet);
}

fn expectRecordEqual(
    expected: *const jsonl.JsonlRecord,
    actual: *const jsonl.TapeRecord,
    expected_record_index: usize,
) !void {
    try testing.expectEqualStrings(expected.source, actual.source);
    try testing.expect(expected.source.ptr == actual.source.ptr);
    try testing.expectEqual(expected.source_start, actual.source_start);
    try testing.expectEqual(expected.source_end, actual.source_end);
    try testing.expectEqual(expected_record_index, actual.record_index);
    try testing.expectEqual(@as(usize, 0), actual.tape_start);

    const actual_tape = try actual.tapeWords();
    try testing.expectEqual(expected.document.tape.len, actual.tape_end);
    try testing.expectEqualSlices(stage2.TapeWord, expected.document.tape, actual_tape);

    var expected_cursor = try expected.root();
    var actual_cursor = try actual.root();
    var position: usize = 0;
    while (position < expected.document.tape.len) : (position += 1) {
        const expected_word = try expected_cursor.peek();
        const actual_word = try actual_cursor.peek();
        try testing.expectEqual(expected_word, actual_word);

        switch (expected_word.tapeKind()) {
            .object_start, .array_start => {
                try testing.expectEqual(
                    try expected_cursor.containerCount(),
                    try actual_cursor.containerCount(),
                );
            },
            .key,
            .string,
            .number,
            .true_literal,
            .false_literal,
            .null_literal,
            => {
                const expected_raw = try expected_cursor.rawValue();
                const actual_raw = try actual_cursor.rawValue();
                try testing.expectEqualStrings(expected_raw, actual_raw);
                try testing.expect(expected_raw.ptr == actual_raw.ptr);
            },
            .object_end, .array_end => {},
        }

        try expected_cursor.advance();
        try actual_cursor.advance();
    }
    try testing.expectEqual(expected.document.tape.len, expected_cursor.position());
    try testing.expectEqual(expected.document.tape.len, try actual_cursor.position());
}

fn reusableDiagnostic(input: []const u8) !jsonl.JsonlDiagnostic {
    var parser = try jsonl.TapeRecordParser.init(testing.allocator, .{});
    defer parser.deinit();
    var iterator = try parser.iterate(input);
    defer iterator.deinit();

    while (try iterator.next()) |result| {
        switch (result) {
            .record => {},
            .diagnostic => |diagnostic| return diagnostic,
        }
    }
    return error.ExpectedDiagnostic;
}

fn makeNestedArray(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    const pair_bytes = std.math.mul(usize, depth, 2) catch return error.OutOfMemory;
    const input_len = std.math.add(usize, pair_bytes, 1) catch return error.OutOfMemory;
    const input = try allocator.alloc(u8, input_len);
    @memset(input[0..depth], '[');
    input[depth] = '0';
    @memset(input[depth + 1 ..], ']');
    return input;
}

// The reusable parser must emit the same record-local words and borrowed raw spans
// as the retain-all builder while retaining only the largest record tape.
test "JSONL reusable record tape matches eager records and framing" {
    const input =
        " \r\n" ++
        "\n" ++
        "{\"a\":[1,{\"b\":true}]}\r\n" ++
        "42\n" ++
        "\t\r\n" ++
        "[\"escaped\\\\value\",null]\n" ++
        "{\"final\":false}";

    var eager = try jsonl.buildJsonlTape(testing.allocator, input);
    defer eager.deinit(testing.allocator);
    var parser = try jsonl.TapeRecordParser.init(testing.allocator, .{});
    defer parser.deinit();
    var iterator = try parser.iterate(input);
    defer iterator.deinit();

    var tape_words_high_water: usize = 0;
    var stale_cursor: ?jsonl.TapeRecordCursor = null;
    for (eager.records, 0..) |*expected, record_index| {
        const result = (try iterator.next()) orelse return error.ExpectedRecord;
        if (stale_cursor) |*cursor| {
            try testing.expectError(error.OutOfOrderIteration, cursor.peek());
        }

        var actual = switch (result) {
            .record => |record| record,
            .diagnostic => return error.UnexpectedDiagnostic,
        };
        try expectRecordEqual(expected, &actual, record_index);
        stale_cursor = try actual.root();

        tape_words_high_water = @max(tape_words_high_water, expected.document.tape.len);
        try testing.expectEqual(tape_words_high_water, parser.tapeCapacity());
    }

    try testing.expect((try iterator.next()) == null);
    if (stale_cursor) |*cursor| {
        try testing.expectError(error.OutOfOrderIteration, cursor.peek());
    }
    try testing.expectEqual(eager.records.len, iterator.recordCount());
    try testing.expectEqual(input.len, parser.inputCapacity());
}

// Syntax failures must keep the eager validator's first accepted-record ordinal
// and global diagnostic coordinates regardless of physical record position.
test "JSONL reusable record tape matches first middle and final diagnostics" {
    const cases = [_][]const u8{
        "[,]\n{}\ntrue\n",
        "{}\r\n[1,]\r\nfalse\n",
        "{}\ntrue\n{\"x\":}\n",
        "\n \r\n{}\n\"unterminated",
    };

    for (cases) |input| {
        const expected = (try jsonl.validateJsonl(testing.allocator, input)) orelse
            return error.ExpectedDiagnostic;
        const actual = try reusableDiagnostic(input);
        try expectDiagnosticEqual(expected, actual);
    }
}

// Iterator and record copies are checked leases. Reset and early deinit must
// invalidate old views without allowing a stale iterator to release a new one.
test "JSONL reusable record tape enforces exact lease transitions" {
    const input = "{\"first\":1}\n[2,3]\n";
    var parser = try jsonl.TapeRecordParser.init(testing.allocator, .{});
    defer parser.deinit();

    var first_iterator = try parser.iterate(input);
    try testing.expectError(error.DocumentActive, parser.iterate("0"));
    var copied_iterator = first_iterator;

    var first_record = switch ((try first_iterator.next()) orelse return error.ExpectedRecord) {
        .record => |record| record,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    var stale_cursor = try first_record.root();
    try testing.expectEqual(stage2.TapeKind.object_start, (try stale_cursor.peek()).tapeKind());

    _ = (try first_iterator.next()) orelse return error.ExpectedRecord;
    try testing.expectError(error.OutOfOrderIteration, stale_cursor.peek());
    try testing.expectError(error.OutOfOrderIteration, stale_cursor.skipValue());
    try testing.expectError(error.OutOfOrderIteration, copied_iterator.next());
    first_iterator.deinit();
    try testing.expectError(error.DocumentReleased, stale_cursor.peek());

    var early_iterator = try parser.iterate("true\nfalse\n");
    var early_record = switch ((try early_iterator.next()) orelse return error.ExpectedRecord) {
        .record => |record| record,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    var early_cursor = try early_record.root();
    early_iterator.deinit();
    try testing.expectError(error.DocumentReleased, early_cursor.peek());

    var reset_iterator = try parser.iterate("null\n");
    var reset_record = switch ((try reset_iterator.next()) orelse return error.ExpectedRecord) {
        .record => |record| record,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    var reset_cursor = try reset_record.root();
    parser.reset();
    try testing.expectError(error.DocumentReleased, reset_cursor.peek());

    var fresh_iterator = try parser.iterate("false\n");
    reset_iterator.deinit();
    const fresh_result = (try fresh_iterator.next()) orelse return error.ExpectedRecord;
    switch (fresh_result) {
        .record => |record| {
            var cursor = try record.root();
            try testing.expectEqual(stage2.TapeKind.false_literal, (try cursor.peek()).tapeKind());
        },
        .diagnostic => return error.UnexpectedDiagnostic,
    }
    fresh_iterator.deinit();
}

// Input and tape ceilings are independent operational failures. Neither failed
// preparation nor failed record growth may leave the parser lease claimed.
test "JSONL reusable record tape reports capacity limits and remains reusable" {
    var input_limited = try jsonl.TapeRecordParser.init(testing.allocator, .{
        .input_capacity_max = 3,
    });
    defer input_limited.deinit();
    try testing.expectError(error.CapacityExceeded, input_limited.iterate("1\n2\n"));

    var short_iterator = try input_limited.iterate("1\n");
    _ = (try short_iterator.next()) orelse return error.ExpectedRecord;
    short_iterator.deinit();

    var tape_limited = try jsonl.TapeRecordParser.init(testing.allocator, .{
        .tape_capacity_max = 3,
    });
    defer tape_limited.deinit();
    var oversized_iterator = try tape_limited.iterate("{\"a\":1}\n");
    try testing.expectError(error.CapacityExceeded, oversized_iterator.next());
    oversized_iterator.deinit();
    try testing.expectEqual(@as(usize, 0), tape_limited.tapeCapacity());

    var scalar_iterator = try tape_limited.iterate("1");
    _ = (try scalar_iterator.next()) orelse return error.ExpectedRecord;
    scalar_iterator.deinit();

    if (@bitSizeOf(usize) > @bitSizeOf(u32)) {
        try testing.expectError(
            error.InputTooLarge,
            jsonl.TapeRecordParser.init(testing.allocator, .{
                .input_capacity_max = @as(usize, std.math.maxInt(u32)) + 1,
            }),
        );
        try testing.expectError(
            error.TapeTooLarge,
            jsonl.TapeRecordParser.init(testing.allocator, .{
                .tape_capacity_max = @as(usize, std.math.maxInt(u32)) + 1,
            }),
        );
    }
}

// Depth remains a syntax diagnostic, while a tape-only u24 payload overflow is
// an operational TapeTooLarge error and does not narrow no-tape validation.
test "JSONL reusable record tape preserves depth and u24 boundaries" {
    const valid_depth = try makeNestedArray(testing.allocator, stage2.max_depth);
    defer testing.allocator.free(valid_depth);
    var parser = try jsonl.TapeRecordParser.init(testing.allocator, .{});
    defer parser.deinit();

    var valid_iterator = try parser.iterate(valid_depth);
    const valid_result = (try valid_iterator.next()) orelse return error.ExpectedRecord;
    switch (valid_result) {
        .record => |record| {
            var cursor = try record.root();
            try cursor.skipValue();
            try testing.expectEqual(record.tape_end, try cursor.position());
        },
        .diagnostic => return error.UnexpectedDiagnostic,
    }
    valid_iterator.deinit();

    const excessive_depth = try makeNestedArray(testing.allocator, stage2.max_depth + 1);
    defer testing.allocator.free(excessive_depth);
    const expected_depth = (try jsonl.validateJsonl(
        testing.allocator,
        excessive_depth,
    )) orelse return error.ExpectedDiagnostic;
    const actual_depth = try reusableDiagnostic(excessive_depth);
    try testing.expectEqual(error.DepthExceeded, actual_depth.err);
    try expectDiagnosticEqual(expected_depth, actual_depth);

    const content_len: usize = @as(usize, std.math.maxInt(u24)) + 1;
    const input = try testing.allocator.alloc(u8, content_len + 2);
    defer testing.allocator.free(input);
    input[0] = '"';
    @memset(input[1 .. content_len + 1], 'a');
    input[content_len + 1] = '"';

    try testing.expect((try jsonl.validateJsonl(testing.allocator, input)) == null);
    var payload_iterator = try parser.iterate(input);
    try testing.expectError(error.TapeTooLarge, payload_iterator.next());
    payload_iterator.deinit();
}

fn checkReusableAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "1\n{\"larger\":[2,true,{\"x\":null}]}\nfalse";
    var parser = try jsonl.TapeRecordParser.init(allocator, .{});
    defer parser.deinit();
    var iterator = try parser.iterate(input);
    defer iterator.deinit();

    while (try iterator.next()) |result| {
        switch (result) {
            .record => |record| {
                var cursor = try record.root();
                try cursor.skipValue();
            },
            .diagnostic => return error.UnexpectedDiagnostic,
        }
    }
}

// Every deterministic index or high-water tape allocation failure must unwind
// the active iterator and leave no parser-owned allocation behind.
test "JSONL reusable record tape cleans deterministic allocation failures" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkReusableAllocationFailure,
        .{},
    );
}

// An exact fixed buffer leaves no room after the one global index allocation.
// Successful validation therefore proves that no tape or record metadata allocates.
test "JSONL validation allocates only the global structural index" {
    const valid_input = "1\n{\"a\":true}\r\nnull";
    const valid_index_bytes = (valid_input.len + 3) * @sizeOf(u32);
    var valid_storage: [valid_index_bytes]u8 align(@alignOf(u32)) = undefined;
    var valid_fixed = std.heap.FixedBufferAllocator.init(&valid_storage);
    try testing.expect((try jsonl.validateJsonl(valid_fixed.allocator(), valid_input)) == null);

    const invalid_input = "{}\n[1,]\n";
    const invalid_index_bytes = (invalid_input.len + 3) * @sizeOf(u32);
    var invalid_storage: [invalid_index_bytes]u8 align(@alignOf(u32)) = undefined;
    var invalid_fixed = std.heap.FixedBufferAllocator.init(&invalid_storage);
    const diagnostic = (try jsonl.validateJsonl(
        invalid_fixed.allocator(),
        invalid_input,
    )) orelse return error.ExpectedDiagnostic;
    try testing.expectEqual(@as(usize, 1), diagnostic.record_index);
    try testing.expectEqual(error.TrailingComma, diagnostic.err);
}

test "JSONL reusable record tape rejects forged bounds" {
    var parser = try jsonl.TapeRecordParser.init(testing.allocator, .{});
    defer parser.deinit();
    var iterator = try parser.iterate("{\"a\":1}\n");
    defer iterator.deinit();

    var record = switch ((try iterator.next()) orelse return error.ExpectedRecord) {
        .record => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    const words = try record.tapeWords();

    var forged = record;
    forged.tape_start = 1;
    forged.tape_end = 0;
    try testing.expectError(error.TapeOutOfBounds, forged.tapeWords());

    forged = record;
    forged.tape_end = words.len + 1;
    try testing.expectError(error.TapeOutOfBounds, forged.tapeWords());

    forged = record;
    forged.source_start = forged.source_end + 1;
    try testing.expectError(error.SourceOutOfBounds, forged.tapeWords());

    var foreign_source: [7]u8 = undefined;
    @memcpy(foreign_source[0..], record.source);
    forged = record;
    forged.source = foreign_source[0..];
    try testing.expectError(error.SourceOutOfBounds, forged.tapeWords());
}

test "JSONL reusable iterator copies go stale on terminal outcomes" {
    var parser = try jsonl.TapeRecordParser.init(testing.allocator, .{});
    defer parser.deinit();

    var eof_iterator = try parser.iterate("1");
    _ = (try eof_iterator.next()) orelse return error.ExpectedRecord;
    var eof_copy = eof_iterator;
    try testing.expect((try eof_iterator.next()) == null);
    try testing.expectEqual(@as(usize, 1), eof_iterator.recordCount());
    try testing.expectError(error.OutOfOrderIteration, eof_copy.next());
    eof_copy.deinit();
    eof_iterator.deinit();

    var diagnostic_iterator = try parser.iterate("[,]\n");
    var diagnostic_copy = diagnostic_iterator;
    const diagnostic_result = (try diagnostic_iterator.next()) orelse return error.ExpectedDiagnostic;
    switch (diagnostic_result) {
        .diagnostic => {},
        .record => return error.UnexpectedRecord,
    }
    try testing.expectEqual(@as(usize, 0), diagnostic_iterator.recordCount());
    try testing.expectError(error.OutOfOrderIteration, diagnostic_copy.next());
    diagnostic_copy.deinit();
    diagnostic_iterator.deinit();

    var limited_parser = try jsonl.TapeRecordParser.init(testing.allocator, .{
        .tape_capacity_max = 3,
    });
    defer limited_parser.deinit();
    var error_iterator = try limited_parser.iterate("1\n{\"a\":1}");
    _ = (try error_iterator.next()) orelse return error.ExpectedRecord;
    var error_copy = error_iterator;
    try testing.expectError(error.CapacityExceeded, error_iterator.next());
    try testing.expectEqual(@as(usize, 1), error_iterator.recordCount());
    try testing.expectError(error.OutOfOrderIteration, error_copy.next());
    error_copy.deinit();
    error_iterator.deinit();
}
