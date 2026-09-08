const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

const Catalog = struct {
    schema_version: u32,
    catalog_id: []const u8,
    format: []const u8,
    offline: bool,
    provenance: Provenance,
    profiles: []Profile,
    importer: ?Importer = null,
};

const Provenance = struct {
    kind: []const u8,
    manifest: []const u8,
    revision: []const u8,
    offline_rule: ?[]const u8 = null,
};

const Importer = struct {
    mode: []const u8,
    network: bool,
    source: []const u8,
    destination: []const u8,
};

const Profile = struct {
    id: []const u8,
    description: []const u8,
    enabled: bool = true,
    default_profile: bool = false,
    cases: []Case,
};

const Case = struct {
    id: []const u8,
    fixture: []const u8,
    expected: []const u8,
};

const CatalogSpec = struct {
    catalog: []const u8,
    catalog_id: []const u8,
    format: []const u8,
    manifest: []const u8,
    revision: []const u8,
    manifest_contents: []const u8,
};

const Fixture = struct {
    path: []const u8,
    contents: []const u8,
};

const catalog_specs = [_]CatalogSpec{
    .{
        .catalog = @embedFile("corpus/catalogs/json.json"),
        .catalog_id = "json-local",
        .format = "json",
        .manifest = "upstream/json/MANIFEST.md",
        .revision = "1ef36fa01286573e846ac449e8683f8833c5b26a",
        .manifest_contents = @embedFile("corpus/upstream/json/MANIFEST.md"),
    },
    .{
        .catalog = @embedFile("corpus/catalogs/jsonc.json"),
        .catalog_id = "jsonc-local",
        .format = "jsonc",
        .manifest = "upstream/jsonc/MANIFEST.md",
        .revision = "37e207ed23f544efc33a1893f21e0bf10b250df0",
        .manifest_contents = @embedFile("corpus/upstream/jsonc/MANIFEST.md"),
    },
    .{
        .catalog = @embedFile("corpus/catalogs/json5.json"),
        .catalog_id = "json5-local",
        .format = "json5",
        .manifest = "upstream/json5/MANIFEST.md",
        .revision = "ceb24d4080137d70833f86c25659c1331b80a387",
        .manifest_contents = @embedFile("corpus/upstream/json5/MANIFEST.md"),
    },
    .{
        .catalog = @embedFile("corpus/catalogs/jsonl.json"),
        .catalog_id = "jsonl-local",
        .format = "jsonl",
        .manifest = "upstream/jsonl/MANIFEST.md",
        .revision = "a8e8671adf470477cd2cc1dfc40c30825f421baa",
        .manifest_contents = @embedFile("corpus/upstream/jsonl/MANIFEST.md"),
    },
    .{
        .catalog = @embedFile("corpus/catalogs/markdown.json"),
        .catalog_id = "markdown-local",
        .format = "markdown",
        .manifest = "upstream/markdown/MANIFEST.md",
        .revision = "9103e341a973013013bb1a80e13567007c5cef6f",
        .manifest_contents = @embedFile("corpus/upstream/markdown/MANIFEST.md"),
    },
    .{
        .catalog = @embedFile("corpus/catalogs/xml.json"),
        .catalog_id = "xml-local",
        .format = "xml",
        .manifest = "upstream/xml/MANIFEST.md",
        .revision = "9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f",
        .manifest_contents = @embedFile("corpus/upstream/xml/MANIFEST.md"),
    },
};

const fixture_table = [_]Fixture{
    .{
        .path = "json/example_config.json",
        .contents = @embedFile("corpus/json/example_config.json"),
    },
    .{
        .path = "cases/json/trailing-comma.json",
        .contents = @embedFile("corpus/cases/json/trailing-comma.json"),
    },
    .{
        .path = "jsonc/config.jsonc",
        .contents = @embedFile("corpus/jsonc/config.jsonc"),
    },
    .{
        .path = "cases/jsonc/trailing-comma.jsonc",
        .contents = @embedFile("corpus/cases/jsonc/trailing-comma.jsonc"),
    },
    .{
        .path = "json5/sample.json5",
        .contents = @embedFile("corpus/json5/sample.json5"),
    },
    .{
        .path = "cases/json5/invalid-number.json5",
        .contents = @embedFile("corpus/cases/json5/invalid-number.json5"),
    },
    .{
        .path = "jsonl/amazon_cellphones.ndjson",
        .contents = @embedFile("corpus/jsonl/amazon_cellphones.ndjson"),
    },
    .{
        .path = "cases/jsonl/blank-lines.ndjson",
        .contents = @embedFile("corpus/cases/jsonl/blank-lines.ndjson"),
    },
    .{
        .path = "markdown/document.md",
        .contents = @embedFile("corpus/markdown/document.md"),
    },
    .{
        .path = "cases/markdown/markers.md",
        .contents = @embedFile("corpus/cases/markdown/markers.md"),
    },
    .{
        .path = "xml/catalog.xml",
        .contents = @embedFile("corpus/xml/catalog.xml"),
    },
    .{
        .path = "cases/xml/mismatched.xml",
        .contents = @embedFile("corpus/cases/xml/mismatched.xml"),
    },
};

test "offline catalogs validate every local case" {
    var covered_catalogs: usize = 0;
    for (catalog_specs) |spec| {
        const executed_cases = try validateCatalog(testing.allocator, spec);
        try testing.expect(executed_cases > 0);
        covered_catalogs += 1;
    }
    try testing.expectEqual(catalog_specs.len, covered_catalogs);
}

fn validateCatalog(allocator: std.mem.Allocator, spec: CatalogSpec) !usize {
    var parsed = try std.json.parseFromSlice(Catalog, allocator, spec.catalog, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const catalog = parsed.value;
    try testing.expectEqual(@as(u32, 1), catalog.schema_version);
    try testing.expectEqualStrings(spec.catalog_id, catalog.catalog_id);
    try testing.expectEqualStrings(spec.format, catalog.format);
    try testing.expect(catalog.offline);
    try testing.expect(catalog.provenance.kind.len > 0);
    try testing.expectEqualStrings(spec.manifest, catalog.provenance.manifest);
    try testing.expectEqualStrings(spec.revision, catalog.provenance.revision);
    try testing.expect(std.mem.indexOf(
        u8,
        spec.manifest_contents,
        catalog.provenance.revision,
    ) != null);
    if (catalog.provenance.offline_rule) |offline_rule| {
        try testing.expect(offline_rule.len > 0);
    }

    if (catalog.importer) |importer| {
        try testing.expectEqualStrings("explicit-local-maintainer", importer.mode);
        try testing.expect(!importer.network);
        try testing.expectEqualStrings("local-directory", importer.source);
        try testing.expect(isRepositoryCorpusPath(importer.destination));
    }

    try testing.expect(catalog.profiles.len > 0);
    var default_profile_count: usize = 0;
    var executed_cases: usize = 0;

    for (catalog.profiles, 0..) |profile, profile_index| {
        try testing.expect(profile.id.len > 0);
        try testing.expect(profile.description.len > 0);
        try testing.expect(isKnownProfile(spec.format, profile.id));
        if (profile.default_profile) default_profile_count += 1;
        for (catalog.profiles[0..profile_index]) |prior_profile| {
            try testing.expect(!std.mem.eql(u8, profile.id, prior_profile.id));
        }

        for (profile.cases, 0..) |case, case_index| {
            errdefer std.debug.print("corpus {s}/{s}/{s}: {s}\n", .{
                spec.format, profile.id, case.id, case.fixture,
            });
            try testing.expect(case.id.len > 0);
            for (profile.cases[0..case_index]) |prior_case| {
                try testing.expect(!std.mem.eql(u8, case.id, prior_case.id));
            }
            try testing.expect(isCorpusPath(case.fixture));
            try testing.expect(isFormatFixturePath(spec.format, case.fixture));
            try testing.expect(std.mem.eql(u8, case.expected, "accept") or
                std.mem.eql(u8, case.expected, "reject"));

            const fixture = findFixture(case.fixture) orelse {
                return error.MissingCorpusFixture;
            };
            if (!profile.enabled) continue;

            const accepts = try validatorAccepts(allocator, spec.format, fixture.contents);
            const expected_accept = std.mem.eql(u8, case.expected, "accept");
            try testing.expectEqual(expected_accept, accepts);
            executed_cases += 1;
        }
    }

    try testing.expect(default_profile_count <= 1);
    return executed_cases;
}

fn findFixture(path: []const u8) ?Fixture {
    for (fixture_table) |fixture| {
        if (std.mem.eql(u8, path, fixture.path)) return fixture;
    }
    return null;
}

fn isCorpusPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) {
        return false;
    }

    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or
            std.mem.eql(u8, segment, ".."))
        {
            return false;
        }
    }
    return true;
}

fn isRepositoryCorpusPath(path: []const u8) bool {
    const prefix = "test/corpus/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return isCorpusPath(path[prefix.len..]);
}

fn isFormatFixturePath(format: []const u8, path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    const first = segments.next() orelse return false;
    if (std.mem.eql(u8, first, format)) return true;
    if (!std.mem.eql(u8, first, "cases")) return false;
    const second = segments.next() orelse return false;
    return std.mem.eql(u8, second, format);
}

fn isKnownProfile(format: []const u8, profile_id: []const u8) bool {
    if (std.mem.eql(u8, format, "json")) {
        return std.mem.eql(u8, profile_id, "strict-rfc8259");
    }
    if (std.mem.eql(u8, format, "jsonc")) {
        return std.mem.eql(u8, profile_id, "strict-jsonc");
    }
    if (std.mem.eql(u8, format, "json5")) {
        return std.mem.eql(u8, profile_id, "json5-syntax");
    }
    if (std.mem.eql(u8, format, "jsonl")) {
        return std.mem.eql(u8, profile_id, "jsonlines-permissive") or
            std.mem.eql(u8, profile_id, "ndjson-strict") or
            std.mem.eql(u8, profile_id, "ndjson-ignore-empty");
    }
    if (std.mem.eql(u8, format, "markdown")) {
        return std.mem.eql(u8, profile_id, "marker-index");
    }
    if (std.mem.eql(u8, format, "xml")) {
        return std.mem.eql(u8, profile_id, "xml-1.0-utf8");
    }
    return false;
}

fn validatorAccepts(
    allocator: std.mem.Allocator,
    format: []const u8,
    input: []const u8,
) !bool {
    if (std.mem.eql(u8, format, "json")) {
        return (try lib.formats.json.validateJson(allocator, input)) == null;
    }
    if (std.mem.eql(u8, format, "jsonc")) {
        return (try lib.formats.jsonc.validateJsonc(allocator, input)) == null;
    }
    if (std.mem.eql(u8, format, "json5")) {
        return (try lib.formats.json5.validateJson5(allocator, input)) == null;
    }
    if (std.mem.eql(u8, format, "jsonl")) {
        return (try lib.formats.jsonl.validateJsonl(allocator, input)) == null;
    }
    if (std.mem.eql(u8, format, "markdown")) {
        return (try lib.formats.markdown.validateMarkdown(allocator, input)) == null;
    }
    if (std.mem.eql(u8, format, "xml")) {
        return (try lib.formats.xml.validateXml(input)) == null;
    }
    return error.UnknownCorpusFormat;
}
