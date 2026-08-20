const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

const vector_len = lib.default_vector_len;

test "refAllDecls" {
    testing.refAllDecls(lib);
    testing.refAllDecls(lib.simd);
    testing.refAllDecls(lib.stage1);
    testing.refAllDecls(lib.stage2);
    testing.refAllDecls(lib.debug);
    testing.refAllDecls(lib.formats);
    testing.refAllDecls(lib.formats.json);
    testing.refAllDecls(lib.formats.jsonl);
    testing.refAllDecls(lib.formats.jsonc);
    testing.refAllDecls(lib.formats.json5);
    testing.refAllDecls(lib.formats.markdown);
    testing.refAllDecls(lib.formats.xml);
}

test "core: prefixXor matches mathematical parity" {
    const test_patterns = [_]u64{
        0x0000000000000000,
        0xFFFFFFFFFFFFFFFF,
        0x5555555555555555,
        0xAAAAAAAAAAAAAAAA,
        0x0000000000000001,
        0x8000000000000000,
        0x123456789ABCDEF0,
        0x0F0F0F0F0F0F0F0F,
    };

    for (test_patterns) |pattern| {
        const simd_result = lib.prefixXor(u64, pattern);
        var expected: u64 = 0;
        var parity: u1 = 0;
        inline for (0..64) |i| {
            parity ^= @as(u1, @truncate(pattern >> i));
            expected |= (@as(u64, parity) << i);
        }
        try testing.expectEqual(expected, simd_result);
    }
}

fn expectStructuralWidths(comptime index_fn: anytype, input: []const u8) !void {
    var expected = try index_fn(16, testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try testing.expect(expected.count > 0);

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        var actual = try index_fn(vlen, testing.allocator, input);
        defer actual.deinit(testing.allocator);
        try testing.expectEqualSlices(
            u32,
            expected.indexes[0..expected.count],
            actual.indexes[0..actual.count],
        );
    }
}

fn expectTokenWidths(comptime index_fn: anytype, input: []const u8) !void {
    var expected = try index_fn(16, testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try testing.expect(expected.count > 0);

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        var actual = try index_fn(vlen, testing.allocator, input);
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

test "corpus: JSON indexing on example_config.json" {
    const json_data = @embedFile("corpus/json/example_config.json");
    try expectStructuralWidths(lib.formats.json.indexJsonImpl, json_data);
}

test "corpus: JSONL indexing on amazon_cellphones.ndjson" {
    const jsonl_data = @embedFile("corpus/jsonl/amazon_cellphones.ndjson");
    try expectStructuralWidths(lib.formats.jsonl.indexJsonlImpl, jsonl_data);
}

test "corpus: JSONC indexing on config.jsonc" {
    const jsonc_data = @embedFile("corpus/jsonc/config.jsonc");
    try expectStructuralWidths(lib.formats.jsonc.indexJsoncImpl, jsonc_data);
}

test "corpus: JSON5 indexing on sample.json5" {
    const json5_data = @embedFile("corpus/json5/sample.json5");
    try expectStructuralWidths(lib.formats.json5.indexJson5Impl, json5_data);
}

test "corpus: Markdown indexing on document.md" {
    const md_data = @embedFile("corpus/markdown/document.md");
    try expectTokenWidths(lib.formats.markdown.indexMarkdownImpl, md_data);
}

test "corpus: XML indexing on catalog.xml" {
    const xml_data = @embedFile("corpus/xml/catalog.xml");
    try expectTokenWidths(lib.formats.xml.indexXmlImpl, xml_data);
}
