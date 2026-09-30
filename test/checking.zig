const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

pub const vector_widths = [_]usize{ 16, 32, 64 };
pub const stream_sentinel_count: usize = 3;

pub fn expectMonotonicBounds(indexes: []const u32, input_len: usize) !void {
    for (indexes, 0..) |offset, index| {
        try testing.expect(offset < input_len);
        if (index > 0) {
            try testing.expect(indexes[index - 1] < offset);
        }
    }
}
pub fn expectBounds(indexes: []const u32, input_len: usize) !void {
    for (indexes) |offset| {
        try testing.expect(offset <= input_len);
    }
}

pub fn expectStructuralWidths(comptime index_fn: anytype, input: []const u8) !void {
    var expected = try index_fn(16, testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try testing.expect(expected.count > 0);

    inline for (vector_widths) |width| {
        var actual = try index_fn(width, testing.allocator, input);
        defer actual.deinit(testing.allocator);
        try testing.expectEqualSlices(
            u32,
            expected.indexes[0..expected.count],
            actual.indexes[0..actual.count],
        );
    }
}

pub fn expectTokenWidths(comptime index_fn: anytype, input: []const u8) !void {
    var expected = try index_fn(16, testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try testing.expect(expected.count > 0);

    inline for (vector_widths) |width| {
        var actual = try index_fn(width, testing.allocator, input);
        defer actual.deinit(testing.allocator);

        try testing.expectEqualSlices(
            u32,
            expected.indexes[0..expected.count],
            actual.indexes[0..actual.count],
        );
        try testing.expectEqualSlices(
            @TypeOf(expected.kinds[0]),
            expected.kinds[0..expected.count],
            actual.kinds[0..actual.count],
        );
    }
}

pub fn expectIndexParity(expected: anytype, actual: anytype, include_sentinels: bool) !void {
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0..expected.count],
        actual.indexes[0..actual.count],
    );
    if (include_sentinels) {
        try testing.expectEqualSlices(
            u32,
            expected.indexes[expected.count..][0..stream_sentinel_count],
            actual.indexes[actual.count..][0..stream_sentinel_count],
        );
    }
}

pub fn expectTokenParity(expected: anytype, actual: anytype, include_sentinels: bool) !void {
    try expectIndexParity(expected, actual, include_sentinels);
    try testing.expectEqualSlices(
        @TypeOf(expected.kinds[0]),
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
}

pub fn expectYamlParity(expected: anytype, actual: anytype, include_sentinels: bool) !void {
    try expectIndexParity(expected, actual, include_sentinels);
    try testing.expectEqualSlices(
        @TypeOf(expected.kinds[0]),
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
    try testing.expectEqualSlices(
        u32,
        expected.lengths[0..expected.count],
        actual.lengths[0..actual.count],
    );
}

pub fn fuzzCuts(input_len: usize) [8]usize {
    var cuts = [8]usize{
        0,
        @min(input_len, 1),
        @min(input_len, 15),
        @min(input_len, 16),
        input_len / 3,
        input_len / 2,
        @min(input_len, 32),
        input_len,
    };
    for (1..cuts.len) |index| {
        var cursor = index;
        while (cursor > 0 and cuts[cursor] < cuts[cursor - 1]) : (cursor -= 1) {
            std.mem.swap(usize, &cuts[cursor], &cuts[cursor - 1]);
        }
    }
    return cuts;
}

pub fn expectCuts(input_len: usize, cuts: []const usize) !void {
    var start: usize = 0;
    for (cuts) |cut| {
        try testing.expect(cut >= start);
        try testing.expect(cut <= input_len);
        start = cut;
    }
}

pub fn feedPartitions(
    input: []const u8,
    cuts: []const usize,
    feeder: anytype,
    feed_empty_after_each: bool,
) !void {
    try expectCuts(input.len, cuts);
    var start: usize = 0;
    for (cuts) |cut| {
        try feeder.feed(input[start..cut]);
        if (feed_empty_after_each) try feeder.feed("");
        start = cut;
    }
    try feeder.feed(input[start..]);
    if (feed_empty_after_each) try feeder.feed("");
}

pub fn isCapacityError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.InputTooLarge,
        error.CapacityOverflow,
        error.CapacityExceeded,
        error.TapeTooLarge,
        => true,
        else => false,
    };
}

pub fn expectValidationBuildParity(
    comptime validate_fn: anytype,
    comptime build_fn: anytype,
    input: []const u8,
    comptime inspect_fn: anytype,
) !void {
    const diagnostic = validate_fn(testing.allocator, input) catch |err| {
        if (isCapacityError(err)) return;
        return err;
    };

    var document = build_fn(testing.allocator, input) catch |err| {
        if (isCapacityError(err)) return;
        if (diagnostic == null) return err;
        return;
    };
    defer document.deinit(testing.allocator);

    try testing.expect(diagnostic == null);
    try inspect_fn(&document, input);
}

pub fn expectJsonDocument(
    document: *const lib.stage2.Document,
    input: []const u8,
) !void {
    try testing.expect(document.tape.len > 0);
    var cursor = try document.root(input);
    while (cursor.position() < document.tape.len) {
        const word = try cursor.peek();
        const kind = word.tapeKind();
        const offset: usize = @intCast(word.offset);
        try testing.expect(offset < input.len);

        switch (kind) {
            .object_start, .array_start => {
                _ = try cursor.containerCount();
            },
            .object_end, .array_end => {
                const start = try cursor.matchingStart();
                try testing.expect(start.position() < cursor.position());
                const start_kind = (try start.peek()).tapeKind();
                if (kind == .object_end) {
                    try testing.expectEqual(lib.stage2.TapeKind.object_start, start_kind);
                } else {
                    try testing.expectEqual(lib.stage2.TapeKind.array_start, start_kind);
                }
            },
            .string, .key, .number, .true_literal, .false_literal, .null_literal => {
                const raw = try cursor.rawValue();
                try expectBorrowedSpan(input, raw);
            },
        }
        try cursor.advance();
    }
    try testing.expectError(error.PositionOutOfBounds, cursor.peek());

    var skipped = try document.root(input);
    try skipped.skipValue();
    try testing.expectEqual(document.tape.len, skipped.position());
}

pub fn expectJsonlDocument(
    document: *const lib.formats.jsonl.JsonlDocument,
    _: []const u8,
) !void {
    for (document.records, 0..) |*record, record_index| {
        try testing.expect(record.source_start < record.source_end);
        try testing.expect(record.source_end <= document.input.len);
        try expectJsonDocument(&record.document, record.source);
        const cursor = try document.cursor(record_index);
        try testing.expectEqual(record.document.tape.len, cursor.tape.len);
    }
    try testing.expectError(error.PositionOutOfBounds, document.cursor(document.records.len));
}

pub fn expectYamlDocument(
    document: *const lib.formats.yaml.YamlDocument,
    input: []const u8,
) !void {
    try testing.expect(document.tape.len > 0);
    var cursor = try document.root(input);
    while (cursor.position() < document.tape.len) {
        const word = try cursor.peek();
        const offset: usize = @intCast(word.offset);
        try testing.expect(offset <= input.len);
        switch (word.tapeKind()) {
            .key, .scalar => {
                const span = try cursor.span();
                try testing.expectEqual(word.sourceLength(), span.len);
                try expectBorrowedSpan(input, span);
            },
            else => {},
        }
        try cursor.advance();
    }
    try testing.expectError(error.TapeOutOfBounds, cursor.peek());
}

fn expectBorrowedSpan(input: []const u8, span: []const u8) !void {
    const input_start = @intFromPtr(input.ptr);
    const input_end = input_start + input.len;
    const span_start = @intFromPtr(span.ptr);
    try testing.expect(span_start >= input_start);
    try testing.expect(span_start <= input_end);
    try testing.expect(span.len <= input_end - span_start);
}

pub fn scalarPrefixXor(comptime T: type, bitmask: T) T {
    const bit_count = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    var result: T = 0;
    var parity: u1 = 0;
    var bit_index: usize = 0;
    while (bit_index < bit_count) : (bit_index += 1) {
        parity ^= @as(u1, @truncate(bitmask >> @as(Shift, @intCast(bit_index))));
        if (parity != 0) result |= one << @as(Shift, @intCast(bit_index));
    }
    return result;
}

pub fn scalarBackslashRunParity(
    comptime T: type,
    backslash_mask: T,
    prev_ends_in_backslash: bool,
) lib.simd.BackslashResult(T) {
    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    var odd_length_ends: T =
        if (prev_ends_in_backslash and backslash_mask == 0) one else 0;
    var run_length: usize = 0;
    var bit_index: usize = 0;
    while (bit_index < bit_count) : (bit_index += 1) {
        const bit = (backslash_mask & (one << @as(Shift, @intCast(bit_index)))) != 0;
        if (bit) {
            run_length += 1;
            continue;
        }
        if (run_length != 0) {
            if (run_length % 2 != 0) {
                odd_length_ends |= one << @as(Shift, @intCast(bit_index));
            }
            run_length = 0;
        }
    }
    return .{
        .odd_length_ends = odd_length_ends,
        .ends_in_backslash = (backslash_mask & (one << @as(Shift, @intCast(bit_count - 1)))) != 0,
    };
}

pub fn scalarUtf8(input: []const u8) lib.simd.Utf8Result {
    var offset: usize = 0;
    while (offset < input.len) {
        const header = input[offset];
        if (header <= 0x7f) {
            offset += 1;
            continue;
        }
        if (header <= 0xbf) return .{ .invalid = .{ .kind = .unexpected_continuation, .offset = offset } };
        if (header <= 0xc1) {
            if (offset + 1 >= input.len) return invalidUtf8(.truncated_sequence, offset);
            if (!isUtf8Continuation(input[offset + 1])) {
                return invalidUtf8(.missing_continuation, offset + 1);
            }
            return invalidUtf8(.overlong, offset);
        }
        if (header <= 0xdf) {
            if (offset + 1 >= input.len) return invalidUtf8(.truncated_sequence, offset);
            if (!isUtf8Continuation(input[offset + 1])) {
                return invalidUtf8(.missing_continuation, offset + 1);
            }
            offset += 2;
            continue;
        }
        if (header <= 0xef) {
            if (offset + 1 >= input.len) return invalidUtf8(.truncated_sequence, offset);
            const continuation = input[offset + 1];
            if (!isUtf8Continuation(continuation)) {
                return invalidUtf8(.missing_continuation, offset + 1);
            }
            if (header == 0xe0 and continuation < 0xa0) {
                return invalidUtf8(.overlong, offset + 1);
            }
            if (header == 0xed and continuation >= 0xa0) {
                return invalidUtf8(.surrogate, offset + 1);
            }
            if (offset + 2 >= input.len) return invalidUtf8(.truncated_sequence, offset);
            if (!isUtf8Continuation(input[offset + 2])) {
                return invalidUtf8(.missing_continuation, offset + 2);
            }
            offset += 3;
            continue;
        }
        if (header <= 0xf4) {
            if (offset + 1 >= input.len) return invalidUtf8(.truncated_sequence, offset);
            const continuation = input[offset + 1];
            if (!isUtf8Continuation(continuation)) {
                return invalidUtf8(.missing_continuation, offset + 1);
            }
            if (header == 0xf0 and continuation < 0x90) {
                return invalidUtf8(.overlong, offset + 1);
            }
            if (header == 0xf4 and continuation > 0x8f) {
                return invalidUtf8(.too_large, offset + 1);
            }
            if (offset + 2 >= input.len) return invalidUtf8(.truncated_sequence, offset);
            if (!isUtf8Continuation(input[offset + 2])) {
                return invalidUtf8(.missing_continuation, offset + 2);
            }
            if (offset + 3 >= input.len) return invalidUtf8(.truncated_sequence, offset);
            if (!isUtf8Continuation(input[offset + 3])) {
                return invalidUtf8(.missing_continuation, offset + 3);
            }
            offset += 4;
            continue;
        }
        if (header <= 0xf7) return invalidUtf8(.too_large, offset);
        return invalidUtf8(.invalid_header, offset);
    }
    return .valid;
}

fn invalidUtf8(kind: lib.simd.Utf8ErrorKind, offset: usize) lib.simd.Utf8Result {
    return .{ .invalid = .{ .kind = kind, .offset = offset } };
}

fn isUtf8Continuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xbf;
}

pub fn expectUtf8Widths(input: []const u8) !void {
    const expected = scalarUtf8(input);
    inline for (vector_widths) |width| {
        try testing.expectEqual(expected, lib.simd.validateUtf8WithWidth(width, input));
    }
    try testing.expectEqual(expected, lib.simd.validateUtf8(input));
}

fn scalarMatchBytePredicate(byte: u8, wanted: u8, _: u8, _: u8, _: u8) bool {
    return byte == wanted;
}

fn scalarMatchAny2Predicate(
    byte: u8,
    wanted: u8,
    second: u8,
    _: u8,
    _: u8,
) bool {
    return byte == wanted or byte == second;
}

fn scalarMatchAny4Predicate(
    byte: u8,
    wanted: u8,
    second: u8,
    third: u8,
    fourth: u8,
) bool {
    return byte == wanted or byte == second or byte == third or byte == fourth;
}

fn scalarMatchRangePredicate(
    byte: u8,
    minimum_byte: u8,
    maximum_byte: u8,
    _: u8,
    _: u8,
) bool {
    return byte >= minimum_byte and byte <= maximum_byte;
}

pub fn scalarMaskByte(comptime len: usize, input: []const u8, offset: usize, target: u8) lib.Mask(len) {
    return scalarMask(len, input, offset, 0, scalarMatchBytePredicate, target, 0, 0, 0);
}

pub fn scalarMaskAny2(
    comptime len: usize,
    input: []const u8,
    offset: usize,
    c1: u8,
    c2: u8,
) lib.Mask(len) {
    return scalarMask(len, input, offset, 0, scalarMatchAny2Predicate, c1, c2, 0, 0);
}

pub fn scalarMaskAny4(
    comptime len: usize,
    input: []const u8,
    offset: usize,
    c1: u8,
    c2: u8,
    c3: u8,
    c4: u8,
) lib.Mask(len) {
    return scalarMask(len, input, offset, 0, scalarMatchAny4Predicate, c1, c2, c3, c4);
}

pub fn scalarMaskRange(
    comptime len: usize,
    input: []const u8,
    offset: usize,
    minimum: u8,
    maximum: u8,
) lib.Mask(len) {
    return scalarMask(len, input, offset, 0, scalarMatchRangePredicate, minimum, maximum, 0, 0);
}

fn scalarMask(
    comptime len: usize,
    input: []const u8,
    offset: usize,
    fill: u8,
    comptime matches: fn (u8, u8, u8, u8, u8) bool,
    first: u8,
    second: u8,
    third: u8,
    fourth: u8,
) lib.Mask(len) {
    const Mask = lib.Mask(len);
    const Shift = std.math.Log2Int(Mask);
    const one: Mask = 1;
    var result: Mask = 0;
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const byte = if (offset + index < input.len) input[offset + index] else fill;
        if (matches(byte, first, second, third, fourth)) {
            result |= one << @as(Shift, @intCast(index));
        }
    }
    return result;
}

// Compare the same explicitly normalized storage-width representation used by
// mask consumers; logical-width comparisons retain Zig's integer semantics.
fn expectStorageMaskEqual(
    comptime width: usize,
    expected: lib.Mask(width),
    actual: lib.Mask(width),
) !void {
    try testing.expectEqual(
        lib.simd.exactMask(lib.Mask(width), expected),
        lib.simd.exactMask(lib.Mask(width), actual),
    );
}

pub fn expectSimdMatchWindows(input: []const u8) !void {
    inline for ([_]usize{ 4, 5, 7, 12, 16, 20, 24, 32, 48, 64, 65, 72 }) |width| {
        var iterator = lib.windows(u8, width, input, 0);
        var offset: usize = 0;
        var window_count: usize = 0;
        const max_windows = if (input.len == 0) 0 else (input.len + width - 1) / width;
        while (iterator.next()) |vector| {
            window_count += 1;
            try testing.expect(window_count <= max_windows);
            try expectStorageMaskEqual(
                width,
                scalarMaskByte(width, input, offset, 'a'),
                lib.matchByte(width, vector, 'a'),
            );
            try expectStorageMaskEqual(
                width,
                scalarMaskAny2(width, input, offset, '\\', '"'),
                lib.matchAny2(width, vector, '\\', '"'),
            );
            try expectStorageMaskEqual(
                width,
                scalarMaskAny4(width, input, offset, '{', '}', '[', ']'),
                lib.matchAny4(width, vector, '{', '}', '[', ']'),
            );
            try expectStorageMaskEqual(
                width,
                scalarMaskRange(width, input, offset, 0x20, 0x7f),
                lib.matchRange(width, vector, 0x20, 0x7f),
            );
            const vector_values: [width]u8 = vector;
            var lane: usize = 0;
            while (lane < width) : (lane += 1) {
                const expected = if (offset + lane < input.len) input[offset + lane] else 0;
                try testing.expectEqual(expected, vector_values[lane]);
            }
            offset += width;
        }
        try testing.expectEqual(max_windows, window_count);
    }
}
