//! Host-only semantic behavior tests: the one root `zig build check` runs for
//! the semantic measurement.
//!
//! Importing the semantic contract and the semantic report decoder here also
//! runs their own test blocks in the gate. What is added below is the set of
//! boundaries that belong to the published measurement rather than to one
//! module: what a capture must refuse, in which order its rows must appear
//! across the two format segments and their two profiles, how a row's outcome
//! may not drift from the oracle it was measured against, and what a refused
//! capture or a failing allocator must still release.
//!
//! Nothing here needs a parser. The fixtures below are decode fixtures: their
//! workload names give the decoder a domain to check, and no statement here
//! claims how the CommonMark or YAML parsers behave. That claim belongs to
//! `commonmark_bench.zig` and `yaml_extended_bench.zig`, whose oracle
//! verification the semantic controller runs before it times anything.

const std = @import("std");
const contract = @import("semantic_contract");
const report = @import("semantic_benchmark_report.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

const Format = contract.Format;
const Workload = contract.Workload;
const Stage = contract.Stage;
const Fixture = contract.Fixture;

// ---------------------------------------------------------------------------
// A decode domain with the shape of the real one: both formats, accepted
// families with several stages, and single-stage families whose outcome is an
// observed error name.
// ---------------------------------------------------------------------------

const cm_accepted_stages = [_]Stage{ .parse, .traverse, .render_html };
const single_resource_stage = [_]Stage{.resource_error};
const yaml_accepted_stages = [_]Stage{ .parse, .traverse };
const yaml_reject_stages = [_]Stage{.reject};

const cm_blocks_source = "# Title\n\nbody *text* and [a link](/url \"title\").\n";
const cm_raw_html_source = "<script>alert(1)</script>\n\n[x](javascript:alert(1))\n";
const cm_input_limit_source = "x\n";
const yaml_literal_source = "a: |\n  one\n";
const yaml_unterminated_source = "a: 'unterminated\n";
const yaml_cooked_limit_source = "a: |\n  one\n  two\n";

const commonmark_fixtures = [_]Fixture{
    .{
        .workload = .cm_blocks,
        .source = cm_blocks_source,
        .stages = &cm_accepted_stages,
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .cm_raw_html,
        .source = cm_raw_html_source,
        .stages = &cm_accepted_stages,
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .cm_input_limit,
        .source = cm_input_limit_source,
        .stages = &single_resource_stage,
        .outcome = "InputTooLarge",
    },
};

const yaml_fixtures = [_]Fixture{
    .{
        .workload = .yaml_literal_clip,
        .source = yaml_literal_source,
        .stages = &yaml_accepted_stages,
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .yaml_unterminated_quote,
        .source = yaml_unterminated_source,
        .stages = &yaml_reject_stages,
        .outcome = "UnterminatedQuote",
    },
    .{
        .workload = .yaml_cooked_limit,
        .source = yaml_cooked_limit_source,
        .stages = &single_resource_stage,
        .outcome = "CookedBytesExceeded",
    },
};

const domain_segments = [_]report.DomainSegment{
    .{ .format = .commonmark, .fixtures = &commonmark_fixtures },
    .{ .format = .yaml_extended, .fixtures = &yaml_fixtures },
};

const test_domain: report.Domain = .{ .segments = &domain_segments };

/// The metadata every capture carries, in `known_header_keys` slot order.
const header_values = [report.known_header_keys.len][]const u8{
    "0.16.0",
    "ReleaseFast",
    "x86_64",
    "32",
    report.commonmark_profile_version,
    report.yaml_extended_profile_version,
    "fresh parse, named consumption, and destruction per iteration",
    "traverse consumes complete semantics; parse consumption is small by design",
    "safe mode: raw HTML omitted, dangerous URLs filtered",
    report.streaming_boundary_text,
    report.ranking_boundary_text,
};

comptime {
    // The table above is positional, so a moved or renamed slot would silently
    // label the wrong header. This makes that a compile error instead.
    const expected = [_][]const u8{
        "zig_version",
        "optimize",
        "target_arch",
        "vector_len",
        "commonmark_profile",
        "yaml_profile",
        "setup",
        "consumption",
        "render_html",
        "streaming",
        "ranking",
    };
    if (expected.len != report.known_header_keys.len) {
        @compileError("header_values no longer matches the protocol's header slots");
    }
    for (expected, 0..) |key, slot| {
        if (!std.mem.eql(u8, key, report.known_header_keys[slot])) {
            @compileError("header_values no longer matches the protocol's header slots");
        }
    }
}

const build_iterations: u16 = 3;

/// The options a decoder must be given to accept a capture built here.
const build_options: report.Options = .{ .samples = 1, .iterations = build_iterations };

/// One measured case as a capture states it. Keeping every field lets a test
/// move exactly one of them and rebuild the line without re-deriving the rest.
const Case = struct {
    format: Format,
    workload: Workload,
    stage: Stage,
    outcome: []const u8,
    input_bytes: usize,
    iterations: u16,
    elapsed_ns: u64,
    checksum: u64,
    allocation_count: u64,
    allocated_bytes: u64,
};

/// Which segments a built capture prints, and in what order.
const SegmentOrder = enum {
    /// CommonMark first, then YAML extended: the order the protocol requires.
    declared,
    /// The same declared work printed with the formats the other way round.
    yaml_first,
    /// Only the first segment: a partial measurement of a two-format domain.
    commonmark_only,
};

/// One complete capture held line by line, so a single field or a single line
/// can be moved without rebuilding or re-parsing the rest of the text.
const Capture = struct {
    allocator: Allocator,
    lines: std.ArrayList([]u8) = .empty,
    /// Line index of each declared row, in declared case order.
    rows: std.ArrayList(usize) = .empty,
    /// Line index of each fixture's input declaration, in declaration order.
    declarations: std.ArrayList(usize) = .empty,
    /// The fields of each declared row, parallel to `rows`.
    cases: std.ArrayList(Case) = .empty,

    fn create(allocator: Allocator) Capture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Capture) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.declarations.deinit(self.allocator);
        self.cases.deinit(self.allocator);
        self.* = undefined;
    }

    fn append(self: *Capture, comptime fmt: []const u8, args: anytype) !usize {
        const line = try self.allocator.print(fmt, args);
        errdefer self.allocator.free(line);
        const index = self.lines.items.len;
        try self.lines.append(self.allocator, line);
        return index;
    }

    /// Rewrites the tracked line `index` in place.
    fn replaceLine(self: *Capture, comptime fmt: []const u8, index: usize, args: anytype) !void {
        const line = try self.allocator.print(fmt, args);
        self.allocator.free(self.lines.items[index]);
        self.lines.items[index] = line;
    }

    /// Rewrites the row of case `index` from `case` and keeps it addressable.
    fn replaceRow(self: *Capture, index: usize, case: Case) !void {
        try self.replaceLine("{s},{s},{s},{s},{d},{d},{d},{d},{d},{d}", self.rows.items[index], .{
            @tagName(case.format),
            @tagName(case.workload),
            @tagName(case.stage),
            case.outcome,
            case.input_bytes,
            case.iterations,
            case.elapsed_ns,
            case.checksum,
            case.allocation_count,
            case.allocated_bytes,
        });
        self.cases.items[index] = case;
    }

    /// Inserts one line before the tracked line `index`; every tracked line at
    /// or after it moves down.
    fn insertLine(self: *Capture, comptime fmt: []const u8, index: usize, args: anytype) !void {
        const line = try self.allocator.print(fmt, args);
        errdefer self.allocator.free(line);
        try self.lines.insert(self.allocator, index, line);
        for (self.rows.items) |*row| {
            if (row.* >= index) row.* += 1;
        }
        for (self.declarations.items) |*declaration| {
            if (declaration.* >= index) declaration.* += 1;
        }
    }

    /// The exact bytes a bench process writes: every line newline-terminated.
    fn text(self: *const Capture) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        for (self.lines.items) |line| {
            try writeLinePart(&out.writer, line);
            try writeLinePart(&out.writer, "\n");
        }
        return out.toOwnedSlice();
    }
};

/// The in-memory writer's only failure is its buffer failing to grow, which is
/// the allocator refusing. Restate it as the allocation error so a capture
/// builder reports why it stopped, and so a leak sweep sees the same error the
/// allocator produced. The switch is exhaustive over that single failure, so a
/// new failure mode here fails to compile rather than being silently tolerated.
fn writeLinePart(writer: *std.Io.Writer, bytes: []const u8) !void {
    writer.writeAll(bytes) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
}

fn appendSegment(capture: *Capture, format: Format, fixtures: []const Fixture) !void {
    for (fixtures) |fixture| {
        const declaration = try capture.append(
            "{s}format={s} workload={s} input_hash={x}",
            .{
                report.input_declaration_prefix,
                @tagName(format),
                @tagName(fixture.workload),
                contract.checksumBytes(fixture.source),
            },
        );
        try capture.declarations.append(capture.allocator, declaration);

        for (fixture.stages) |stage| {
            const ordinal: u64 = @intCast(capture.rows.items.len);
            const elapsed_ns: u64 = 1000 + ordinal * 7;
            const checksum: u64 = 5000 + ordinal;
            const allocation_count: u64 = 4 + ordinal;
            const allocated_bytes: u64 = 512 + ordinal * 64;

            const row = try capture.append(
                "{s},{s},{s},{s},{d},{d},{d},{d},{d},{d}",
                .{
                    @tagName(format),
                    @tagName(fixture.workload),
                    @tagName(stage),
                    fixture.outcome,
                    fixture.source.len,
                    build_iterations,
                    elapsed_ns,
                    checksum,
                    allocation_count,
                    allocated_bytes,
                },
            );
            try capture.rows.append(capture.allocator, row);
            try capture.cases.append(capture.allocator, .{
                .format = format,
                .workload = fixture.workload,
                .stage = stage,
                .outcome = fixture.outcome,
                .input_bytes = fixture.source.len,
                .iterations = build_iterations,
                .elapsed_ns = elapsed_ns,
                .checksum = checksum,
                .allocation_count = allocation_count,
                .allocated_bytes = allocated_bytes,
            });
        }
    }
}

fn buildCapture(allocator: Allocator, order: SegmentOrder) !Capture {
    var capture = Capture.create(allocator);
    errdefer capture.deinit();

    for (report.known_header_keys, header_values) |key, value| {
        _ = try capture.append("# {s}={s}", .{ key, value });
    }
    _ = try capture.append("{s}", .{report.csv_header});

    switch (order) {
        .declared => {
            try appendSegment(&capture, .commonmark, &commonmark_fixtures);
            try appendSegment(&capture, .yaml_extended, &yaml_fixtures);
        },
        .yaml_first => {
            try appendSegment(&capture, .yaml_extended, &yaml_fixtures);
            try appendSegment(&capture, .commonmark, &commonmark_fixtures);
        },
        .commonmark_only => try appendSegment(&capture, .commonmark, &commonmark_fixtures),
    }
    return capture;
}

/// Decodes one capture and requires exactly this failure.
fn expectRefusal(text: []const u8, expected: anyerror) !void {
    const single = [_][]const u8{text};
    if (report.analyzeSamples(testing.allocator, &single, build_options, test_domain)) |analysis| {
        var owned = analysis;
        report.freeAnalysis(testing.allocator, &owned);
        return error.ExpectedRefusal;
    } else |observed| {
        try testing.expectEqual(expected, observed);
    }
}

// ---------------------------------------------------------------------------
// Malformed captures.
// ---------------------------------------------------------------------------

test "a declaration may not split the rows of one fixture" {
    var capture = try buildCapture(testing.allocator, .declared);
    defer capture.deinit();

    // The first fixture declares three rows. A second declaration between its
    // first and second row would measure one input under two identities.
    try capture.insertLine("{s}format=commonmark workload=cm_blocks input_hash={x}", capture.rows.items[1], .{
        report.input_declaration_prefix,
        contract.checksumBytes(cm_blocks_source),
    });

    const text = try capture.text();
    defer testing.allocator.free(text);
    try expectRefusal(text, error.DuplicateInputDeclaration);
}

test "a declaration naming a foreign fixture or an unspellable hash is refused" {
    {
        var foreign = try buildCapture(testing.allocator, .declared);
        defer foreign.deinit();

        // The last CommonMark fixture is declared and then measured. Naming a
        // YAML fixture in that declaration leaves the following row without
        // its own input, even though the hash it carries is a real one.
        try foreign.replaceLine(
            "{s}format=yaml_extended workload=yaml_literal_clip input_hash={x}",
            foreign.declarations.items[2],
            .{ report.input_declaration_prefix, contract.checksumBytes(yaml_literal_source) },
        );
        const text = try foreign.text();
        defer testing.allocator.free(text);
        try expectRefusal(text, error.MissingInputDeclaration);
    }
    {
        // One digit past what an `u64` hash can spell is not a hash, and it is
        // refused as a malformed number rather than silently truncated.
        var wide_hash = try buildCapture(testing.allocator, .declared);
        defer wide_hash.deinit();
        try wide_hash.replaceLine(
            "{s}format=commonmark workload=cm_blocks input_hash=fffffffffffffffff",
            wide_hash.declarations.items[0],
            .{report.input_declaration_prefix},
        );
        const text = try wide_hash.text();
        defer testing.allocator.free(text);
        try expectRefusal(text, error.InvalidNumber);
    }
}

// ---------------------------------------------------------------------------
// Row order and work profile boundaries.
// ---------------------------------------------------------------------------

test "printed rows must follow the declared order, formats first and profiles second" {
    // The same declared work printed with the formats the other way round.
    var swapped = try buildCapture(testing.allocator, .yaml_first);
    defer swapped.deinit();
    const swapped_text = try swapped.text();
    defer testing.allocator.free(swapped_text);
    try expectRefusal(swapped_text, error.RowOrderMismatch);

    // The YAML profile has no renderer, so no YAML row may name one even
    // though the stage is a valid name everywhere else.
    var rendered = try buildCapture(testing.allocator, .declared);
    defer rendered.deinit();
    var rendered_case = rendered.cases.items[8];
    try testing.expectEqual(Workload.yaml_literal_clip, rendered_case.workload);
    try testing.expectEqual(Stage.traverse, rendered_case.stage);
    rendered_case.stage = .render_html;
    try rendered.replaceRow(8, rendered_case);
    const rendered_text = try rendered.text();
    defer testing.allocator.free(rendered_text);
    try expectRefusal(rendered_text, error.RowOrderMismatch);

    // A capture that prints one segment of a two-format domain is a partial
    // measurement, not a smaller one.
    var partial = try buildCapture(testing.allocator, .commonmark_only);
    defer partial.deinit();
    const partial_text = try partial.text();
    defer testing.allocator.free(partial_text);
    try expectRefusal(partial_text, error.MissingRows);
}

// ---------------------------------------------------------------------------
// Outcome drift.
// ---------------------------------------------------------------------------

test "a row may not report an outcome other than the oracle it was measured against" {
    // A resource fixture reporting a different observed error is refused even
    // though its stage and its accept/reject bit are both still right.
    var renamed_error = try buildCapture(testing.allocator, .declared);
    defer renamed_error.deinit();
    var resource_case = renamed_error.cases.items[6];
    try testing.expectEqualStrings("InputTooLarge", resource_case.outcome);
    resource_case.outcome = "TooManyNodes";
    try renamed_error.replaceRow(6, resource_case);
    const resource_text = try renamed_error.text();
    defer testing.allocator.free(resource_text);
    try expectRefusal(resource_text, error.UnexpectedOutcome);

    // A rejection row drifting to a different error name is refused too.
    var renamed_rejection = try buildCapture(testing.allocator, .declared);
    defer renamed_rejection.deinit();
    var rejection_case = renamed_rejection.cases.items[9];
    try testing.expectEqual(Stage.reject, rejection_case.stage);
    rejection_case.outcome = "UnterminatedScalar";
    try renamed_rejection.replaceRow(9, rejection_case);
    const rejection_text = try renamed_rejection.text();
    defer testing.allocator.free(rejection_text);
    try expectRefusal(rejection_text, error.UnexpectedOutcome);

    // The oracle is checked on every row, not only the first of a fixture: an
    // accepted fixture's rendering row may not report an error either.
    var rendered_drift = try buildCapture(testing.allocator, .declared);
    defer rendered_drift.deinit();
    var rendering_case = rendered_drift.cases.items[2];
    try testing.expectEqual(Stage.render_html, rendering_case.stage);
    rendering_case.outcome = "TooManyNodes";
    try rendered_drift.replaceRow(2, rendering_case);
    const rendering_text = try rendered_drift.text();
    defer testing.allocator.free(rendering_text);
    try expectRefusal(rendering_text, error.UnexpectedOutcome);
}

// ---------------------------------------------------------------------------
// Resource and cleanup failures.
// ---------------------------------------------------------------------------

/// Merges a canonical capture with one whose semantic checksum moved. The
/// recording must be refused with `error.UnstableResults`, and that refusal
/// must still release the merged cases, every per-case timing slice, and the
/// header copies already taken. A merge the decoder does accept is reported
/// as `error.AcceptedDrift` instead, so it can never pass for that refusal.
fn mergeDriftingRecording(allocator: Allocator) !void {
    const options: report.Options = .{ .samples = 2, .iterations = build_iterations };

    var first = try buildCapture(allocator, .declared);
    defer first.deinit();
    var second = try buildCapture(allocator, .declared);
    defer second.deinit();

    var moved = second.cases.items[0];
    moved.checksum +%= 1;
    try second.replaceRow(0, moved);

    const first_text = try first.text();
    defer allocator.free(first_text);
    const second_text = try second.text();
    defer allocator.free(second_text);
    const texts = try allocator.alloc([]const u8, 2);
    defer allocator.free(texts);
    texts[0] = first_text;
    texts[1] = second_text;

    var analysis = report.analyzeSamples(allocator, texts, options, test_domain) catch |err| switch (err) {
        error.UnstableResults => return err,
        else => |fatal| return fatal,
    };
    report.freeAnalysis(allocator, &analysis);
    return error.AcceptedDrift;
}

/// Decodes a capture whose first row contradicts its oracle. The decode must
/// be refused with `error.UnexpectedOutcome`, and the inputs and cases it had
/// already allocated must be released on that path. A decode that accepts the
/// contradiction is reported as `error.AcceptedContradiction`, and the report
/// it was handed is released before it is.
fn decodeContradictoryCapture(allocator: Allocator) !void {
    var capture = try buildCapture(allocator, .declared);
    defer capture.deinit();

    var damaged = capture.cases.items[0];
    damaged.outcome = "TooManyNodes";
    try capture.replaceRow(0, damaged);

    const text = try capture.text();
    defer allocator.free(text);

    var parsed = report.parseReport(allocator, text, build_options, test_domain) catch |err| switch (err) {
        error.UnexpectedOutcome => return err,
        else => |fatal| return fatal,
    };
    report.freeReport(allocator, &parsed);
    return error.AcceptedContradiction;
}

/// Fails one allocation of `path` at a time, over every allocation it makes,
/// and requires that nothing it had taken survives the failure. Whether the
/// injection or the path's own refusal ends the run, the memory taken so far
/// must be released; `accepted` names the errors a refusal is allowed to end
/// with, so a decode that stops for the wrong reason still fails here.
fn expectNoLeakAtAnyAllocation(path: anytype, accepted: []const anyerror) !void {
    var baseline = testing.FailingAllocator.init(testing.allocator, .{});
    // The baseline pass only counts what the path allocates. The path is
    // expected to end in its own refusal, and with no fail index the allocator
    // cannot stop it early, so that ending cannot propagate: it is what the
    // enclosing test already asserts, and the sweep below re-derives it under
    // injection. What the pass itself must guarantee is that it released
    // everything it took.
    _ = path(baseline.allocator()) catch |err| switch (err) {
        error.OutOfMemory, error.UnstableResults, error.UnexpectedOutcome => {},
        else => {},
    };
    try testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    const total = baseline.alloc_index;
    // A path that allocates nothing would make the sweep below vacuous.
    try testing.expect(total > 0);

    var index: usize = 0;
    while (index < total) : (index += 1) {
        var injected = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        var observed: ?anyerror = null;
        path(injected.allocator()) catch |err| {
            observed = err;
        };

        try testing.expectEqual(injected.allocated_bytes, injected.freed_bytes);
        if (observed) |err| {
            var allowed = false;
            for (accepted) |candidate| {
                if (err == candidate) allowed = true;
            }
            if (!allowed) return err;
        }
    }
}

test "a recording whose semantics drift between samples is refused and releases its merge" {
    try testing.expectError(error.UnstableResults, mergeDriftingRecording(testing.allocator));
    try expectNoLeakAtAnyAllocation(
        mergeDriftingRecording,
        &.{ error.OutOfMemory, error.UnstableResults },
    );
}

test "a capture that contradicts its oracle is refused and releases what it took" {
    try testing.expectError(error.UnexpectedOutcome, decodeContradictoryCapture(testing.allocator));
    try expectNoLeakAtAnyAllocation(
        decodeContradictoryCapture,
        &.{ error.OutOfMemory, error.UnexpectedOutcome },
    );
}
