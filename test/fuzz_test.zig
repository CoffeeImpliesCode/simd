const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

fn checkMonotonicBounds(indexes: []const u32, input_len: usize) !void {
    for (indexes, 0..) |offset, i| {
        try testing.expect(offset < input_len);
        if (i > 0) {
            try testing.expect(indexes[i - 1] < offset);
        }
    }
}

const stream_sentinel_count: usize = 3;

fn fuzzCuts(input_len: usize) [4]usize {
    return .{
        0,
        input_len / 3,
        input_len / 2,
        input_len,
    };
}

fn expectJsonlStreamPartitions(
    input: []const u8,
    expected: *const lib.StructuralIndex,
) !void {
    const cuts = fuzzCuts(input.len);
    var stream = try lib.formats.jsonl.initStreamIndexer(
        testing.allocator,
        3,
    );
    defer stream.deinit();

    var start: usize = 0;
    for (cuts) |cut| {
        try testing.expect(cut >= start);
        try stream.feed(input[start..cut]);
        try stream.feed("");
        start = cut;
    }
    try stream.feed(input[start..]);
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + stream_sentinel_count],
        actual.indexes[0 .. actual.count + stream_sentinel_count],
    );
}

fn expectMarkdownStreamPartitions(
    input: []const u8,
    expected: *const lib.formats.markdown.MarkdownStructuralIndex,
) !void {
    const cuts = fuzzCuts(input.len);
    var stream = try lib.formats.markdown.MarkdownStreamIndexer.init(
        testing.allocator,
        3,
    );
    defer stream.deinit();

    var start: usize = 0;
    for (cuts) |cut| {
        try testing.expect(cut >= start);
        try stream.feed(input[start..cut]);
        try stream.feed("");
        start = cut;
    }
    try stream.feed(input[start..]);
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + stream_sentinel_count],
        actual.indexes[0 .. actual.count + stream_sentinel_count],
    );
    try testing.expectEqualSlices(
        lib.formats.markdown.MarkdownTokenKind,
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
}

fn expectXmlStreamPartitions(
    input: []const u8,
    expected: *const lib.formats.xml.XmlStructuralIndex,
) !void {
    const cuts = fuzzCuts(input.len);
    var stream = try lib.formats.xml.XmlStreamIndexer.init(
        testing.allocator,
        3,
    );
    defer stream.deinit();

    var start: usize = 0;
    for (cuts) |cut| {
        try testing.expect(cut >= start);
        try stream.feed(input[start..cut]);
        try stream.feed("");
        start = cut;
    }
    try stream.feed(input[start..]);
    try stream.finish();

    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + stream_sentinel_count],
        actual.indexes[0 .. actual.count + stream_sentinel_count],
    );
    try testing.expectEqualSlices(
        lib.formats.xml.XmlTokenKind,
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
}

const deterministic_case_count = 2_048;
const input_size_max = 512;

fn xorshift64(state: *u64) u64 {
    std.debug.assert(state.* != 0);

    var value = state.*;
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    state.* = value;
    return value;
}

fn runDeterministicSmithCases(seed: u64, comptime invariant: anytype) !void {
    std.debug.assert(seed != 0);

    var state = seed;
    var input_buffer: [input_size_max]u8 = undefined;
    for (0..deterministic_case_count) |case_index| {
        const input_len: usize = switch (case_index) {
            0 => 0,
            1 => input_size_max,
            else => @intCast(xorshift64(&state) % @as(u64, input_size_max + 1)),
        };
        const input = input_buffer[0..input_len];
        for (input) |*byte| {
            byte.* = @truncate(xorshift64(&state));
        }

        var smith: testing.Smith = .{ .in = input };
        try invariant({}, &smith);
    }
}

// -------------------------------------------------------------------------
// JSON Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: JSON indexer invariants" {
    try runDeterministicSmithCases(0x243f_6a88_85a3_08d3, testFuzzJson);
}

fn testFuzzJson(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.json.indexJson(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    try checkMonotonicBounds(idx.slice(), input.len);
}

// -------------------------------------------------------------------------
// JSONL Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: JSONL indexer invariants" {
    try runDeterministicSmithCases(0x1319_8a2e_0370_7344, testFuzzJsonl);
}

fn testFuzzJsonl(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.jsonl.indexJsonl(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    try checkMonotonicBounds(idx.slice(), input.len);
    try expectJsonlStreamPartitions(input, &idx);
}

// -------------------------------------------------------------------------
// JSONC Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: JSONC indexer invariants" {
    try runDeterministicSmithCases(0xa409_3822_299f_31d0, testFuzzJsonc);
}

fn testFuzzJsonc(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.jsonc.indexJsonc(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    try checkMonotonicBounds(idx.slice(), input.len);
}

// -------------------------------------------------------------------------
// JSON5 Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: JSON5 indexer invariants" {
    try runDeterministicSmithCases(0x082e_fa98_ec4e_6c89, testFuzzJson5);
}

fn testFuzzJson5(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.json5.indexJson5(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    try checkMonotonicBounds(idx.slice(), input.len);
}

// -------------------------------------------------------------------------
// Markdown Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: Markdown indexer invariants" {
    try runDeterministicSmithCases(0x4528_21e6_38d0_1377, testFuzzMarkdown);
}

fn testFuzzMarkdown(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.markdown.indexMarkdown(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    const slice = idx.indexes[0..idx.count];
    try checkMonotonicBounds(slice, input.len);
    try testing.expect(idx.count <= idx.kinds.len);
    try expectMarkdownStreamPartitions(input, &idx);
}

// -------------------------------------------------------------------------
// XML Fuzz Target
// -------------------------------------------------------------------------

test "fuzz: XML indexer invariants" {
    try runDeterministicSmithCases(0xbe54_66cf_34e9_0c6c, testFuzzXml);
}

fn testFuzzXml(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    var idx = lib.formats.xml.indexXml(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.InputTooLarge, error.CapacityOverflow => return,
    };
    defer idx.deinit(testing.allocator);

    const slice = idx.indexes[0..idx.count];
    try checkMonotonicBounds(slice, input.len);
    try testing.expect(idx.count <= idx.kinds.len);
    try expectXmlStreamPartitions(input, &idx);
}
