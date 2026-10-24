//! `yaml-extended-e2b-1.2.2` semantic measurement for the semantic benchmark.
//!
//! This module owns the real parser calls. Every measured run builds the tape
//! freshly, performs the named consumption, and destroys the document inside
//! the measured region: there is no prebuilt or resident setup, and no
//! document or cooked buffer crosses an iteration boundary.
//!
//! The ownership split the profile guarantees is respected here. The `Document`
//! owns its tape, its scalar metadata, and its cooked bytes; the source stays
//! borrowed for the whole traversal, so `fixture.source` outlives every value
//! read through `Document.value` and `Document.scalarInfo`, and the observed
//! `Value.ownership` is mixed into the semantic checksum rather than assumed.
//!
//! Outcomes are observations, never expectations. `run` reports `accepted` only
//! when the real call returned a document, and `@errorName` of the actual error
//! otherwise. `verifyOracles` runs before any timing and compares those
//! observations against the independently authored tables in
//! `yaml_extended_bench_fixtures.zig`; a mismatch fails loudly instead of
//! adopting the observed behavior.
//!
//! An exhausted allocator is not one of those observations. The allocator
//! belongs to the harness, not to the profile, and `error.OutOfMemory` is the
//! only allocator error, so it is propagated out of every measured and every
//! verified call: it aborts the run instead of becoming an outcome string, a
//! checksum, or an oracle comparison. Every other error is a parser or resource
//! rejection and stays on the observed path above.
//!
//! Scope boundary: this measures one profile on one corpus. It contains no
//! cross-library comparison, no ranking, no parser grammar change, no
//! streaming claim (this profile has no stream indexer), and no
//! prefix-traversal relabeling.

const std = @import("std");
const contract = @import("semantic_contract");
const data = @import("yaml_extended_bench_fixtures.zig");
const basic = @import("simd_lib").formats.yaml;
const yaml = @import("simd_lib").formats.yaml_extended;

const Allocator = std.mem.Allocator;
const Event = data.Event;
const Oracle = data.Oracle;

/// The declared work domain, in `contract.Workload` declaration order.
pub const fixtures = data.fixtures;

/// See `yaml_extended_bench_fixtures.parse_stage_coverage`: the `parse` stage
/// consumes the container skeleton only, not whole-document semantics.
pub const parse_stage_coverage = data.parse_stage_coverage;

/// Declared stage order for an accepted fixture, and for the two single-stage
/// rejection shapes. The controller enumerates each fixture's stages in
/// exactly this order.
const accepted_stage_order = [_]contract.Stage{ .parse, .traverse };
const reject_stage_order = [_]contract.Stage{.reject};
const resource_stage_order = [_]contract.Stage{.resource_error};

fn parseLimits(limits: data.Limits) yaml.Limits {
    return .{
        .source_bytes_max = limits.source_bytes_max,
        .cooked_bytes_max = limits.cooked_bytes_max,
        .scalar_source_bytes_max = limits.scalar_source_bytes_max,
        .line_count_max = limits.line_count_max,
        .scalar_line_count_max = limits.scalar_line_count_max,
        .indentation_max = limits.indentation_max,
        .depth_max = limits.depth_max,
        .tape_words_max = limits.tape_words_max,
    };
}

/// Maps a tape word onto the benchmark's own event vocabulary, which declares
/// one member per token kind the profile defines. The word kind is the raw
/// discriminant, so the mapping is an explicit whitelist: an unknown kind is
/// an error instead of a silent `@enumFromInt`.
fn eventKind(word: anytype) !data.EventKind {
    return switch (word.kind) {
        @backingInt(basic.YamlTokenKind.document_start) => .document_start,
        @backingInt(basic.YamlTokenKind.document_end) => .document_end,
        @backingInt(basic.YamlTokenKind.mapping_start) => .mapping_start,
        @backingInt(basic.YamlTokenKind.mapping_end) => .mapping_end,
        @backingInt(basic.YamlTokenKind.sequence_start) => .sequence_start,
        @backingInt(basic.YamlTokenKind.sequence_end) => .sequence_end,
        @backingInt(basic.YamlTokenKind.key) => .key,
        @backingInt(basic.YamlTokenKind.scalar) => .scalar,
        else => error.UnknownEventKind,
    };
}

fn mapOwnership(ownership: yaml.ValueOwnership) data.Ownership {
    return switch (ownership) {
        .source_borrowed => .source_borrowed,
        .document_owned => .document_owned,
    };
}

fn mapStyle(style: yaml.ScalarStyle) data.Style {
    return switch (style) {
        .plain => .plain,
        .single_quoted => .single_quoted,
        .double_quoted => .double_quoted,
        .literal => .literal,
        .folded => .folded,
    };
}

fn mapChomping(chomping: yaml.Chomping) data.Chomping {
    return switch (chomping) {
        .clip => .clip,
        .strip => .strip,
        .keep => .keep,
    };
}

fn mapDiagnosticKind(kind: yaml.DiagnosticKind) data.DiagnosticKind {
    return switch (kind) {
        .syntax => .syntax,
        .unsupported => .unsupported,
        .resource => .resource,
        .invalid_index => .invalid_index,
    };
}

/// The `parse` stage consumption: the complete container skeleton of the built
/// tape, and nothing more. It reads no scalar bytes and no cooked values, so it
/// stays the smaller of the two accepted stages. Every tape word is walked,
/// document delimiters included, so the stage covers the whole skeleton and no
/// event can slip past unconsumed.
/// `yaml_extended_bench_fixtures.checksumSkeleton` derives the same value from
/// the authored event stream.
fn consumeSkeleton(document: *const yaml.Document) !u64 {
    var checksum: u64 = contract.fnv_offset_basis;
    contract.mix(&checksum, @intCast(document.tape.len));
    var depth: u64 = 0;
    for (document.tape) |word| {
        const kind = try eventKind(word);
        contract.mix(&checksum, @backingInt(kind));
        contract.mix(&checksum, depth);
        switch (kind) {
            .mapping_start, .sequence_start => depth += 1,
            .mapping_end, .sequence_end => depth -= 1,
            // A document delimiter is not a container and has no value, so it
            // contributes only its kind at the depth outside the root.
            .document_start, .document_end, .key, .scalar => {},
        }
    }
    return checksum;
}

/// The `traverse` stage consumption: every logical container, key, and value,
/// with each value's ownership, scalar style, chomping, block indentation, and
/// complete cooked bytes. Document-owned cooked bytes and source-borrowed spans
/// are hashed by the same rules, so a borrowed value that happened to equal a
/// cooked one would still be distinguished by its ownership code. Every tape
/// word is walked, so a document delimiter is consumed here too.
/// `yaml_extended_bench_fixtures.checksumSemantics` derives the same value from
/// the authored event stream.
fn consumeSemantics(document: *const yaml.Document, input: []const u8) !u64 {
    var checksum: u64 = contract.fnv_offset_basis;
    var depth: u64 = 0;
    for (document.tape, 0..) |word, index| {
        const kind = try eventKind(word);
        contract.mix(&checksum, @backingInt(kind));
        contract.mix(&checksum, depth);
        switch (kind) {
            .mapping_start, .sequence_start => depth += 1,
            .mapping_end, .sequence_end => depth -= 1,
            .document_start, .document_end => {},
            .key, .scalar => {
                const value = try document.value(input, index);
                const info = try document.scalarInfo(index);
                contract.mix(&checksum, @backingInt(mapOwnership(value.ownership())));
                contract.mix(&checksum, @backingInt(mapStyle(info.style)));
                contract.mix(&checksum, @backingInt(mapChomping(info.chomping)));
                contract.mix(&checksum, @intCast(info.indentation_width));
                contract.mixBytes(&checksum, value.bytes());
            },
        }
    }
    return checksum;
}

fn failure(
    index: usize,
    workload: contract.Workload,
    what: []const u8,
    observed: []const u8,
    expected: []const u8,
) void {
    std.log.err(
        "yaml extended oracle mismatch: fixture {d} ({s}) {s}: observed \"{s}\", expected \"{s}\"",
        .{ index, @tagName(workload), what, observed, expected },
    );
}

fn verifyStages(
    index: usize,
    fixture: contract.Fixture,
    expected: []const contract.Stage,
) !void {
    if (fixture.stages.len != expected.len) {
        failure(index, fixture.workload, "stage count", "", "see declared stages");
        return error.OracleMismatch;
    }
    for (fixture.stages, expected) |got, want| {
        if (got != want) {
            failure(index, fixture.workload, "stage order", @tagName(got), @tagName(want));
            return error.OracleMismatch;
        }
    }
}

/// Element-by-element comparison of the authored event stream against the
/// parsed one. Every field is named, so a mismatch says which container, key,
/// value, or scalar facet drifted.
fn verifyEvents(
    index: usize,
    fixture: contract.Fixture,
    document: *const yaml.Document,
    input: []const u8,
    expected: []const Event,
) !void {
    if (document.tape.len != expected.len) {
        std.log.err(
            "yaml extended oracle mismatch: fixture {d} ({s}) event count: {d} observed, {d} expected",
            .{ index, @tagName(fixture.workload), document.tape.len, expected.len },
        );
        return error.OracleMismatch;
    }
    for (expected, 0..) |want, position| {
        const kind = try eventKind(document.tape[position]);
        if (kind != want.kind) {
            std.log.err(
                "yaml extended oracle mismatch: fixture {d} ({s}) event {d} kind: observed {s}, expected {s}",
                .{ index, @tagName(fixture.workload), position, @tagName(kind), @tagName(want.kind) },
            );
            return error.OracleMismatch;
        }
        if (kind != .key and kind != .scalar) continue;

        const value = try document.value(input, position);
        const info = try document.scalarInfo(position);
        if (mapOwnership(value.ownership()) != want.ownership) {
            std.log.err(
                "yaml extended oracle mismatch: fixture {d} ({s}) event {d} ownership: observed {s}, expected {s}",
                .{ index, @tagName(fixture.workload), position, @tagName(value.ownership()), @tagName(want.ownership) },
            );
            return error.OracleMismatch;
        }
        if (mapStyle(info.style) != want.style) {
            std.log.err(
                "yaml extended oracle mismatch: fixture {d} ({s}) event {d} style: observed {s}, expected {s}",
                .{ index, @tagName(fixture.workload), position, @tagName(info.style), @tagName(want.style) },
            );
            return error.OracleMismatch;
        }
        if (mapChomping(info.chomping) != want.chomping) {
            std.log.err(
                "yaml extended oracle mismatch: fixture {d} ({s}) event {d} chomping: observed {s}, expected {s}",
                .{ index, @tagName(fixture.workload), position, @tagName(info.chomping), @tagName(want.chomping) },
            );
            return error.OracleMismatch;
        }
        if (info.indentation_width != want.indentation_width) {
            std.log.err(
                "yaml extended oracle mismatch: fixture {d} ({s}) event {d} " ++
                    "indentation width: observed {d}, expected {d}",
                .{ index, @tagName(fixture.workload), position, info.indentation_width, want.indentation_width },
            );
            return error.OracleMismatch;
        }
        if (!std.mem.eql(u8, value.bytes(), want.bytes)) {
            std.log.err(
                "yaml extended oracle mismatch: fixture {d} ({s}) event {d} " ++
                    "cooked bytes: observed \"{s}\", expected \"{s}\"",
                .{ index, @tagName(fixture.workload), position, value.bytes(), want.bytes },
            );
            return error.OracleMismatch;
        }
    }
}

fn verifyAccepted(
    allocator: Allocator,
    index: usize,
    fixture: contract.Fixture,
    oracle: Oracle,
) !void {
    var document = yaml.buildYamlTape(allocator, fixture.source, parseLimits(oracle.limits)) catch |err| {
        if (err == error.OutOfMemory) return err;
        failure(index, fixture.workload, "parse", @errorName(err), oracle.outcome);
        return error.OracleMismatch;
    };
    defer document.deinit(allocator);

    if (!std.mem.eql(u8, oracle.outcome, contract.accepted_outcome)) {
        failure(index, fixture.workload, "parse", contract.accepted_outcome, oracle.outcome);
        return error.OracleMismatch;
    }
    try verifyStages(index, fixture, &accepted_stage_order);

    // The document must still be borrowing this exact source: every value read
    // below stays valid only because the caller keeps `fixture.source` alive.
    if (document.source.ptr != fixture.source.ptr or document.source.len != fixture.source.len) {
        failure(index, fixture.workload, "borrowed source slice", "a different slice", "the fixture source");
        return error.OracleMismatch;
    }

    try verifyEvents(index, fixture, &document, fixture.source, oracle.events);

    const skeleton = try consumeSkeleton(&document);
    const skeleton_expected = data.checksumSkeleton(oracle.events);
    if (skeleton != skeleton_expected) {
        std.log.err(
            "yaml extended oracle mismatch: fixture {d} ({s}) parse skeleton checksum: observed {d}, expected {d}",
            .{ index, @tagName(fixture.workload), skeleton, skeleton_expected },
        );
        return error.OracleMismatch;
    }

    const semantics = try consumeSemantics(&document, fixture.source);
    const semantics_expected = data.checksumSemantics(oracle.events);
    if (semantics != semantics_expected) {
        std.log.err(
            "yaml extended oracle mismatch: fixture {d} ({s}) traverse checksum: observed {d}, expected {d}",
            .{ index, @tagName(fixture.workload), semantics, semantics_expected },
        );
        return error.OracleMismatch;
    }
}

/// A rejected or resource fixture must report exactly the authored error name
/// and the authored diagnostic classification. Returns the observed
/// diagnostic so a caller can say more about how it was reached.
fn expectDiagnostic(
    allocator: Allocator,
    index: usize,
    fixture: contract.Fixture,
    oracle: Oracle,
) !yaml.Diagnostic {
    const diagnostic = (try yaml.validateYaml(allocator, fixture.source, parseLimits(oracle.limits))) orelse {
        failure(index, fixture.workload, "rejection", contract.accepted_outcome, oracle.outcome);
        return error.OracleMismatch;
    };
    if (!std.mem.eql(u8, @errorName(diagnostic.err), oracle.outcome)) {
        failure(index, fixture.workload, "error name", @errorName(diagnostic.err), oracle.outcome);
        return error.OracleMismatch;
    }
    if (mapDiagnosticKind(diagnostic.kind) != oracle.diagnostic_kind) {
        failure(
            index,
            fixture.workload,
            "diagnostic kind",
            @tagName(diagnostic.kind),
            @tagName(oracle.diagnostic_kind),
        );
        return error.OracleMismatch;
    }
    return diagnostic;
}

fn verifyRejected(
    allocator: Allocator,
    index: usize,
    fixture: contract.Fixture,
    oracle: Oracle,
) !void {
    try verifyStages(index, fixture, &reject_stage_order);
    _ = try expectDiagnostic(allocator, index, fixture, oracle);
}

fn verifyResource(
    allocator: Allocator,
    index: usize,
    fixture: contract.Fixture,
    oracle: Oracle,
) !void {
    // The rejection has to come from the configured bound, not from the source:
    // the same document must parse under the profile's own defaults.
    const baseline_limits = parseLimits(data.default_limits);
    var baseline = yaml.buildYamlTape(allocator, fixture.source, baseline_limits) catch |err| {
        if (err == error.OutOfMemory) return err;
        failure(
            index,
            fixture.workload,
            "baseline parse with default limits",
            @errorName(err),
            contract.accepted_outcome,
        );
        return error.OracleMismatch;
    };
    baseline.deinit(allocator);

    _ = try expectDiagnostic(allocator, index, fixture, oracle);
}

/// Preflight oracle verification. Runs before any timing and fails loudly on
/// the first disagreement between the profile and the authored tables.
pub fn verifyOracles(allocator: Allocator) !void {
    if (data.oracles.len != fixtures.len) {
        std.log.err(
            "yaml extended oracle tables disagree: {d} fixtures, {d} oracles",
            .{ fixtures.len, data.oracles.len },
        );
        return error.OracleTableMismatch;
    }
    for (fixtures, data.oracles, 0..) |fixture, oracle, index| {
        if (!std.mem.eql(u8, fixture.outcome, oracle.outcome)) {
            failure(index, fixture.workload, "declared outcome", fixture.outcome, oracle.outcome);
            return error.OracleMismatch;
        }
        if (std.mem.eql(u8, oracle.outcome, contract.accepted_outcome)) {
            try verifyAccepted(allocator, index, fixture, oracle);
            continue;
        }
        if (fixture.stages.len != 1) {
            failure(index, fixture.workload, "stage count", "", "exactly one stage");
            return error.OracleMismatch;
        }
        switch (fixture.stages[0]) {
            .resource_error => {
                try verifyStages(index, fixture, &resource_stage_order);
                try verifyResource(allocator, index, fixture, oracle);
            },
            .reject => try verifyRejected(allocator, index, fixture, oracle),
            else => {
                failure(index, fixture.workload, "stage", @tagName(fixture.stages[0]), "reject or resource_error");
                return error.OracleMismatch;
            },
        }
    }
}

fn declaresStage(fixture: contract.Fixture, stage: contract.Stage) bool {
    for (fixture.stages) |declared| {
        if (declared == stage) return true;
    }
    return false;
}

/// One measured operation: a fresh tape build, the named consumption, and the
/// destruction of everything the document owns. The YAML profile has no
/// renderer, so `render_html` is never a valid stage here.
pub fn run(allocator: Allocator, fixture_index: usize, stage: contract.Stage) !contract.Result {
    if (fixture_index >= fixtures.len) return error.UnknownFixture;
    if (fixture_index >= data.oracles.len) return error.OracleTableMismatch;
    const fixture = fixtures[fixture_index];
    const oracle = data.oracles[fixture_index];
    if (!declaresStage(fixture, stage)) return error.UndeclaredStage;

    var document = yaml.buildYamlTape(allocator, fixture.source, parseLimits(oracle.limits)) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .checksum = contract.checksumBytes(@errorName(err)), .outcome = @errorName(err) };
    };
    defer document.deinit(allocator);

    switch (stage) {
        .parse, .resource_error, .reject => return .{
            .checksum = try consumeSkeleton(&document),
            .outcome = contract.accepted_outcome,
        },
        .traverse => return .{
            .checksum = try consumeSemantics(&document, fixture.source),
            .outcome = contract.accepted_outcome,
        },
        .render_html => return error.UndeclaredStage,
    }
}
