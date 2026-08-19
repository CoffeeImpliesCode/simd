const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

const vector_len = lib.default_vector_len;

test "refAllDecls" {
    testing.refAllDecls(lib);
    testing.refAllDecls(lib.simd);
    testing.refAllDecls(lib.stage1);
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

test "corpus: JSON indexing on example_config.json" {
    const json_data = @embedFile("corpus/json/example_config.json");
    var idx = try lib.formats.json.indexJson(testing.allocator, json_data);
    defer idx.deinit(testing.allocator);
    try testing.expect(idx.count > 0);
}

test "corpus: JSONL indexing on amazon_cellphones.ndjson" {
    const jsonl_data = @embedFile("corpus/jsonl/amazon_cellphones.ndjson");
    var idx = try lib.formats.jsonl.indexJsonl(testing.allocator, jsonl_data);
    defer idx.deinit(testing.allocator);
    try testing.expect(idx.count > 0);
}

test "corpus: JSONC indexing on config.jsonc" {
    const jsonc_data = @embedFile("corpus/jsonc/config.jsonc");
    var idx = try lib.formats.jsonc.indexJsonc(testing.allocator, jsonc_data);
    defer idx.deinit(testing.allocator);
    try testing.expect(idx.count > 0);
}

test "corpus: JSON5 indexing on sample.json5" {
    const json5_data = @embedFile("corpus/json5/sample.json5");
    var idx = try lib.formats.json5.indexJson5(testing.allocator, json5_data);
    defer idx.deinit(testing.allocator);
    try testing.expect(idx.count > 0);
}

test "corpus: Markdown indexing on document.md" {
    const md_data = @embedFile("corpus/markdown/document.md");
    var idx = try lib.formats.markdown.indexMarkdown(testing.allocator, md_data);
    defer idx.deinit(testing.allocator);
    try testing.expect(idx.count > 0);
}

test "corpus: XML indexing on catalog.xml" {
    const xml_data = @embedFile("corpus/xml/catalog.xml");
    var idx = try lib.formats.xml.indexXml(testing.allocator, xml_data);
    defer idx.deinit(testing.allocator);
    try testing.expect(idx.count > 0);
}
