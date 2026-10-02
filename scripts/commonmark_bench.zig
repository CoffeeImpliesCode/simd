//! CommonMark 0.31.2 semantic measurement for the semantic benchmark.
//!
//! This module owns the real parser calls. Every measured run parses freshly,
//! performs the named consumption, and destroys the document inside the
//! measured region: there is no prebuilt or resident setup, and no reused
//! document crosses an iteration boundary.
//!
//! Outcomes are observations, never expectations. `run` returns `accepted`
//! only when the real call returned a value, and `@errorName` of the actual
//! error otherwise. `verifyOracles` runs before any timing and compares those
//! observations against the independently authored tables in
//! `commonmark_bench_fixtures.zig`; a mismatch fails loudly instead of
//! adopting the observed behavior.
//!
//! An exhausted allocator is not one of those observations. The allocator
//! belongs to the harness, not to the parser, and `error.OutOfMemory` is the
//! only allocator error, so it is propagated out of every measured and every
//! verified call: it aborts the run instead of becoming an outcome string, a
//! checksum, or an oracle comparison. Every other error is a parser or resource
//! rejection and stays on the observed path above.
//!
//! Scope boundary: this measures one parser on one corpus. It contains no
//! cross-library comparison, no ranking, no streaming claim (this parser has
//! no stream indexer), and no prefix-traversal relabeling.

const std = @import("std");
const contract = @import("semantic_contract");
const data = @import("commonmark_bench_fixtures.zig");
const commonmark = @import("simd_lib").formats.commonmark;

const Allocator = std.mem.Allocator;
const Record = data.Record;
const Attrs = data.Attrs;

/// The declared work domain, in `contract.Workload` declaration order.
pub const fixtures = data.fixtures;

/// See `commonmark_bench_fixtures.parse_stage_coverage`: the `parse` stage is
/// a small consumption, not whole-document coverage.
pub const parse_stage_coverage = data.parse_stage_coverage;

const accepted_outcome = data.accepted_outcome;

fn parseOptions(limits: data.Limits) commonmark.CommonMarkOptions {
    return .{
        .max_input_bytes = limits.max_input_bytes,
        .max_nodes = limits.max_nodes,
        .max_text_bytes = limits.max_text_bytes,
        .max_reference_count = limits.max_reference_count,
        .max_delimiters = limits.max_delimiters,
        .max_brackets = limits.max_brackets,
        .max_depth = limits.max_depth,
        .max_work = limits.max_work,
    };
}

/// Safe mode is the only mode this benchmark renders. `conformance` is
/// intentionally unsafe and is never used here.
fn renderOptions(limits: data.RenderLimits) commonmark.HtmlRenderOptions {
    return .{ .mode = .safe, .max_output_bytes = limits.max_output_bytes };
}

fn mapKind(kind: commonmark.NodeKind) data.Kind {
    return switch (kind) {
        .document => .document,
        .block_quote => .block_quote,
        .list => .list,
        .list_item => .list_item,
        .paragraph => .paragraph,
        .reference_definition => .reference_definition,
        .heading => .heading,
        .thematic_break => .thematic_break,
        .code_block => .code_block,
        .html_block => .html_block,
        .text => .text,
        .softbreak => .softbreak,
        .linebreak => .linebreak,
        .code_span => .code_span,
        .emph => .emph,
        .strong => .strong,
        .link => .link,
        .image => .image,
        .autolink => .autolink,
        .html_inline => .html_inline,
    };
}

/// `TextId.none` and any out-of-range id read as the empty string. A node with
/// no title and a node with an empty title therefore contribute the same
/// length-prefixed empty string; the node kind in the record is what
/// distinguishes them.
fn textOf(document: *const commonmark.CommonMarkDocument, id: commonmark.TextId) []const u8 {
    return document.text(id) orelse "";
}

fn nodeAttrs(
    document: *const commonmark.CommonMarkDocument,
    node: *const commonmark.Node,
) Attrs {
    return switch (node.data) {
        .none => .none,
        .raw => |id| .{ .raw = textOf(document, id) },
        .heading => |heading| .{ .heading = .{
            .level = heading.level,
            .text = textOf(document, heading.raw),
        } },
        .list => |list| .{ .list = .{
            .ordered = list.ordered,
            .start = list.start,
            .delimiter = list.delimiter,
            .tight = list.tight,
        } },
        .code_block => |code| .{ .code_block = .{
            .fenced = code.fenced,
            .fence = code.fence,
            .fence_length = code.fence_length,
            .info = textOf(document, code.info),
            .raw = textOf(document, code.raw),
        } },
        .link => |link| .{ .destination = .{
            .destination = textOf(document, link.destination),
            .title = textOf(document, link.title),
        } },
        .image => |link| .{ .destination = .{
            .destination = textOf(document, link.destination),
            .title = textOf(document, link.title),
        } },
        .autolink => |id| .{ .autolink = textOf(document, id) },
    };
}

const Frame = struct {
    id: commonmark.NodeId,
    depth: u32,
    child_index: u32,
};

/// Complete preorder walk of every reachable node. Unreachable nodes left
/// behind by inline delimiter consumption are never visited: the semantic
/// tree is what the document exposes through its child links.
fn collectRecords(
    allocator: Allocator,
    document: *const commonmark.CommonMarkDocument,
    records: *std.ArrayList(Record),
) !void {
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);
    var children: std.ArrayList(commonmark.NodeId) = .empty;
    defer children.deinit(allocator);

    try stack.append(allocator, .{ .id = document.root(), .depth = 0, .child_index = 0 });
    while (stack.pop()) |frame| {
        const node = document.node(frame.id) orelse return error.InvalidDocument;
        children.clearRetainingCapacity();
        // A valid `ChildIterator` yields at most one child per node, and
        // `Builder.appendNode` refuses the index reserved for `NodeId.none`, so
        // the count is bounded by `document.nodes.len` and fits `u32`.
        var iterator = document.nodeChildren(frame.id);
        while (iterator.nextChild()) |child| {
            try children.append(allocator, child);
        }
        if (iterator.isInvalid()) return error.InvalidDocument;
        const child_count: u32 = @intCast(children.items.len);
        try records.append(allocator, .{
            .kind = mapKind(node.kind),
            .depth = frame.depth,
            .child_index = frame.child_index,
            .child_count = child_count,
            .attrs = nodeAttrs(document, node),
        });
        var index = children.items.len;
        while (index > 0) {
            index -= 1;
            try stack.append(allocator, .{
                .id = children.items[index],
                .depth = frame.depth + 1,
                .child_index = @intCast(index),
            });
        }
    }
}

/// Small, honest parse-stage consumption: the root kind plus the kinds of the
/// first and last top-level blocks. `commonmark_bench_fixtures.smallChecksum
/// Expected` derives the same value from the authored tree.
fn consumeSmall(document: *const commonmark.CommonMarkDocument) u64 {
    var checksum: u64 = 0;
    const root = document.node(document.root()) orelse return checksum;
    contract.mix(&checksum, @intFromEnum(root.kind));
    const first = document.node(root.first_child) orelse return checksum;
    contract.mix(&checksum, @intFromEnum(first.kind));
    const last = document.node(root.last_child) orelse return checksum;
    contract.mix(&checksum, @intFromEnum(last.kind));
    return checksum;
}

/// Complete consumption of a safely rendered document: the full output bytes.
fn consumeBytes(checksum: *u64, bytes: []const u8) void {
    const length: u64 = bytes.len;
    contract.mix(checksum, length);
    for (bytes) |byte| contract.mix(checksum, byte);
}

fn failure(
    index: usize,
    workload: contract.Workload,
    what: []const u8,
    observed: []const u8,
    expected: []const u8,
) void {
    std.log.err(
        "commonmark oracle mismatch: fixture {d} ({s}) {s}: observed \"{s}\", expected \"{s}\"",
        .{ index, @tagName(workload), what, observed, expected },
    );
}

fn firstDifference(expected: []const Record, actual: []const Record) usize {
    const limit = @min(expected.len, actual.len);
    for (expected[0..limit], actual[0..limit], 0..) |want, got, index| {
        if (want.kind != got.kind or
            want.depth != got.depth or
            want.child_index != got.child_index or
            want.child_count != got.child_count) return index;
    }
    return limit;
}

fn reportRecord(label: []const u8, position: usize, record: Record) void {
    std.log.err(
        "  {s} record {d}: kind={s} depth={d} child={d}/{d}",
        .{ label, position, @tagName(record.kind), record.depth, record.child_index, record.child_count },
    );
    switch (record.attrs) {
        .none => std.log.err("    attrs: none", .{}),
        .raw => |text| std.log.err("    attrs: raw \"{s}\"", .{text}),
        .autolink => |text| std.log.err("    attrs: autolink \"{s}\"", .{text}),
        .list => |list| std.log.err(
            "    attrs: list ordered={} start={d} delimiter=0x{X:0>2} tight={}",
            .{ list.ordered, list.start, list.delimiter, list.tight },
        ),
        .heading => |heading| std.log.err(
            "    attrs: heading level={d} text=\"{s}\"",
            .{ heading.level, heading.text },
        ),
        .code_block => |code| std.log.err(
            "    attrs: code_block fenced={} fence=0x{X:0>2} fence_length={d} info=\"{s}\" raw=\"{s}\"",
            .{ code.fenced, code.fence, code.fence_length, code.info, code.raw },
        ),
        .destination => |link| std.log.err(
            "    attrs: destination=\"{s}\" title=\"{s}\"",
            .{ link.destination, link.title },
        ),
    }
}

fn reportRecords(
    index: usize,
    workload: contract.Workload,
    expected: []const Record,
    actual: []const Record,
) void {
    const difference = firstDifference(expected, actual);
    std.log.err(
        "commonmark oracle mismatch: fixture {d} ({s}) semantic tree: {d} expected records, " ++
            "{d} observed records, first structural difference at record {d}",
        .{ index, @tagName(workload), expected.len, actual.len, difference },
    );
    if (difference < expected.len) reportRecord("expected", difference, expected[difference]);
    if (difference < actual.len) reportRecord("observed", difference, actual[difference]);
}

/// Declared stage order for an accepted fixture and for a resource fixture.
/// The controller enumerates each fixture's stages in exactly this order.
const accepted_stage_order = [_]contract.Stage{ .parse, .traverse, .render_html };
const resource_stage_order = [_]contract.Stage{.resource_error};

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

fn verifyAccepted(
    allocator: Allocator,
    index: usize,
    fixture: contract.Fixture,
    oracle: data.Oracle,
) !void {
    var document = commonmark.parseCommonMark(
        allocator,
        fixture.source,
        parseOptions(oracle.limits),
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        failure(index, fixture.workload, "parse", @errorName(err), oracle.outcome);
        return error.OracleMismatch;
    };
    defer document.deinit();

    if (!std.mem.eql(u8, oracle.outcome, accepted_outcome)) {
        failure(index, fixture.workload, "parse", accepted_outcome, oracle.outcome);
        return error.OracleMismatch;
    }
    const small = consumeSmall(&document);
    const small_expected = data.smallChecksumExpected(oracle.expected);
    if (small != small_expected) {
        std.log.err(
            "commonmark oracle mismatch: fixture {d} ({s}) parse stage small consumption: observed {d}, expected {d}",
            .{ index, @tagName(fixture.workload), small, small_expected },
        );
        return error.OracleMismatch;
    }

    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(allocator);
    try collectRecords(allocator, &document, &records);

    if (!data.recordsEqual(oracle.expected, records.items)) {
        reportRecords(index, fixture.workload, oracle.expected, records.items);
        return error.OracleMismatch;
    }
    const traverse = data.checksumRecords(records.items);
    const traverse_expected = data.checksumRecords(oracle.expected);
    if (traverse != traverse_expected) {
        std.log.err(
            "commonmark oracle mismatch: fixture {d} ({s}) traverse checksum: observed {d}, expected {d}",
            .{ index, @tagName(fixture.workload), traverse, traverse_expected },
        );
        return error.OracleMismatch;
    }

    const html = commonmark.renderCommonMarkHtml(
        allocator,
        &document,
        renderOptions(oracle.render_limits),
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        failure(index, fixture.workload, "render_html", @errorName(err), accepted_outcome);
        return error.OracleMismatch;
    };
    defer allocator.free(html);
    if (!std.mem.eql(u8, html, oracle.html)) {
        std.log.err(
            "commonmark oracle mismatch: fixture {d} ({s}) safe HTML: observed \"{s}\", expected \"{s}\"",
            .{ index, @tagName(fixture.workload), html, oracle.html },
        );
        return error.OracleMismatch;
    }
}

fn verifyResource(
    allocator: Allocator,
    index: usize,
    fixture: contract.Fixture,
    oracle: data.Oracle,
) !void {
    // The rejection has to come from the configured bound, not from the
    // source: the same document must parse under the parser's own defaults.
    var baseline = commonmark.parseCommonMark(allocator, fixture.source, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        failure(index, fixture.workload, "baseline parse with default limits", @errorName(err), accepted_outcome);
        return error.OracleMismatch;
    };
    baseline.deinit();

    var document = commonmark.parseCommonMark(
        allocator,
        fixture.source,
        parseOptions(oracle.limits),
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        const observed = @errorName(err);
        if (!std.mem.eql(u8, observed, oracle.outcome)) {
            failure(index, fixture.workload, "configured limit", observed, oracle.outcome);
            return error.OracleMismatch;
        }
        return;
    };
    defer document.deinit();

    failure(index, fixture.workload, "configured limit", accepted_outcome, oracle.outcome);
    return error.OracleMismatch;
}

/// Preflight oracle verification. Runs before any timing and fails loudly on
/// the first disagreement between the parser and the authored tables.
pub fn verifyOracles(allocator: Allocator) !void {
    if (data.oracles.len != fixtures.len) {
        std.log.err(
            "commonmark oracle tables disagree: {d} fixtures, {d} oracles",
            .{ fixtures.len, data.oracles.len },
        );
        return error.OracleTableMismatch;
    }
    for (fixtures, data.oracles, 0..) |fixture, oracle, index| {
        if (!std.mem.eql(u8, fixture.outcome, oracle.outcome)) {
            failure(index, fixture.workload, "declared outcome", fixture.outcome, oracle.outcome);
            return error.OracleMismatch;
        }
        if (std.mem.eql(u8, oracle.outcome, accepted_outcome)) {
            try verifyStages(index, fixture, &accepted_stage_order);
            try verifyAccepted(allocator, index, fixture, oracle);
        } else {
            try verifyStages(index, fixture, &resource_stage_order);
            try verifyResource(allocator, index, fixture, oracle);
        }
    }
}

/// One measured operation: a fresh parse, the named consumption, and the
/// destruction of everything the parse owned.
pub fn run(allocator: Allocator, fixture_index: usize, stage: contract.Stage) !contract.Result {
    if (fixture_index >= fixtures.len) return error.UnknownFixture;
    if (fixture_index >= data.oracles.len) return error.OracleTableMismatch;
    const fixture = fixtures[fixture_index];
    const oracle = data.oracles[fixture_index];

    var document = commonmark.parseCommonMark(
        allocator,
        fixture.source,
        parseOptions(oracle.limits),
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .checksum = contract.checksumBytes(@errorName(err)), .outcome = @errorName(err) };
    };
    defer document.deinit();

    switch (stage) {
        .parse, .resource_error => {
            return .{ .checksum = consumeSmall(&document), .outcome = accepted_outcome };
        },
        .traverse => {
            var records: std.ArrayList(Record) = .empty;
            defer records.deinit(allocator);
            try collectRecords(allocator, &document, &records);
            return .{ .checksum = data.checksumRecords(records.items), .outcome = accepted_outcome };
        },
        .render_html => {
            const html = commonmark.renderCommonMarkHtml(
                allocator,
                &document,
                renderOptions(oracle.render_limits),
            ) catch |err| {
                if (err == error.OutOfMemory) return err;
                return .{ .checksum = contract.checksumBytes(@errorName(err)), .outcome = @errorName(err) };
            };
            defer allocator.free(html);
            var checksum: u64 = 0;
            consumeBytes(&checksum, html);
            return .{ .checksum = checksum, .outcome = accepted_outcome };
        },
        .reject => return error.UnsupportedStage,
    }
}
