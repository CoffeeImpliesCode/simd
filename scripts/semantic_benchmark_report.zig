//! Strict decoding for the semantic benchmark stdout protocol.
//!
//! This module owns the protocol half of the semantic measurement: the
//! metadata headers, the CSV row columns, and the input declaration printed
//! before each fixture's rows. It turns one raw `simd-semantic-bench` stdout
//! sample into typed records. It performs no I/O, spawns nothing, and imports
//! no parser, so the archive runtime can exercise it against captured output
//! without a build and without a CPU-dependent library module.
//!
//! The measured work domain is the declared fixture list, not a Cartesian
//! product. The caller passes the `Domain` it built from the two format
//! modules, and the decoder admits exactly the rows that domain declares: one
//! input declaration per fixture, then that fixture's declared stages in
//! declared order. A stage a fixture does not declare has no row, so there is
//! no way to invent a measurement. CommonMark fixtures come first, YAML second.
//!
//! The public shape mirrors the legacy `benchmark_report.zig` wherever the
//! archive runtime shares it: `Options`, `Command`, `BenchHeaders`,
//! `InputEntry`, `CaseRecord`, `MergedCase`, `Analysis`, `parseReport`,
//! `analyzeSamples`, `freeHeaders`, `freeAnalysis`, and `sameAs`. The legacy
//! resident, prefix, stream, synthetic-scale, and Cartesian-domain facilities
//! are deliberately absent: neither semantic parser streams, no prefix
//! traversal is claimed, and the domain is the fixture list.
//!
//! Timings are observations. `elapsed_ns` is retained per case and per sample
//! and is never compared for equality, never ordered, and never printed as a
//! ranking.

const std = @import("std");
const contract = @import("semantic_contract");

const Allocator = std.mem.Allocator;

pub const Format = contract.Format;
pub const Workload = contract.Workload;
pub const Stage = contract.Stage;
pub const Fixture = contract.Fixture;

// ---------------------------------------------------------------------------
// The declared work domain.
//
// The controller builds this from the two format modules, each of which
// exposes `fixtures`:
//
//     const segments = [_]report.DomainSegment{
//         .{ .format = .commonmark, .fixtures = commonmark_bench.fixtures },
//         .{ .format = .yaml_extended, .fixtures = yaml_extended_bench.fixtures },
//     };
//     const domain: report.Domain = .{ .segments = &segments };
//
// A format module that declares its fixtures as a fixed-size array needs `&`
// on `fixtures`, so the field keeps a slice.
// ---------------------------------------------------------------------------

/// One format's fixtures, in declaration order.
pub const DomainSegment = struct {
    format: Format,
    fixtures: []const Fixture,
};

/// Every fixture and every stage that fixture declares, in the order the
/// report must print them.
pub const Domain = struct {
    segments: []const DomainSegment,
};

const workload_count = @typeInfo(Workload).@"enum".fields.len;
const stage_count = @typeInfo(Stage).@"enum".fields.len;

/// At most one segment per format.
const max_domain_segments = 2;

/// The declared input and case counts of a domain. One fixture per
/// (format, workload) with at most one of each stage per fixture bounds the
/// domain at `2 * 24` inputs and `2 * 24 * 5` cases without a separate limit.
const DomainCounts = struct {
    inputs: usize,
    cases: usize,
};

fn countDomain(domain: Domain) BenchReportError!DomainCounts {
    if (domain.segments.len == 0 or domain.segments.len > max_domain_segments) {
        return error.DomainSegmentCount;
    }

    var inputs: usize = 0;
    var cases: usize = 0;
    var seen_commonmark = false;
    var seen_yaml = false;

    for (domain.segments) |segment| {
        switch (segment.format) {
            .commonmark => {
                if (seen_commonmark or seen_yaml) return error.DomainFormatOrder;
                seen_commonmark = true;
            },
            .yaml_extended => {
                if (seen_yaml) return error.DomainFormatOrder;
                seen_yaml = true;
            },
        }

        var seen_workloads: [workload_count]bool = @splat(false);
        for (segment.fixtures) |*fixture| {
            const workload_slot = @intFromEnum(fixture.workload);
            if (seen_workloads[workload_slot]) return error.DuplicateWorkload;
            seen_workloads[workload_slot] = true;

            if (fixture.stages.len == 0) return error.EmptyStageList;
            var seen_stages: [stage_count]bool = @splat(false);
            for (fixture.stages) |stage| {
                const stage_slot = @intFromEnum(stage);
                if (seen_stages[stage_slot]) return error.DuplicateStage;
                seen_stages[stage_slot] = true;
            }

            try checkOracle(fixture.outcome, fixture.stages);
            inputs += 1;
            cases += fixture.stages.len;
        }
    }

    if (inputs == 0) return error.EmptyDomain;
    return .{ .inputs = inputs, .cases = cases };
}

/// An oracle must be usable as a report field and must agree with the stages
/// its fixture declares: an accepted fixture declares acceptance stages, and a
/// rejected or resource fixture declares exactly the one stage that observed
/// its error.
fn checkOracle(outcome: []const u8, stages: []const Stage) BenchReportError!void {
    if (outcome.len == 0 or outcome.len > max_outcome_bytes) return error.InvalidOracleOutcome;
    for (outcome) |byte| {
        // An outcome is one CSV field and an `@errorName`, so it carries no
        // comma, space, line break, or NUL.
        if (byte == ',' or byte == ' ' or byte == '\r' or byte == '\n' or byte == 0) {
            return error.InvalidOracleOutcome;
        }
    }

    if (std.mem.eql(u8, outcome, contract.accepted_outcome)) {
        for (stages) |stage| switch (stage) {
            .parse, .traverse, .render_html => {},
            .resource_error, .reject => return error.OutcomeStageMismatch,
        };
        return;
    }

    if (!isErrorName(outcome)) return error.InvalidOracleOutcome;
    if (stages.len != 1) return error.OutcomeStageMismatch;
    switch (stages[0]) {
        .resource_error, .reject => {},
        .parse, .traverse, .render_html => return error.OutcomeStageMismatch,
    }
}

/// An `@errorName` is an identifier: a leading letter, then letters, digits,
/// or underscores. Anything else is not an observed error name.
fn isErrorName(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

fn hasStage(fixture: *const Fixture, stage: Stage) bool {
    for (fixture.stages) |candidate| {
        if (candidate == stage) return true;
    }
    return false;
}

/// Checks a declared work domain on its own, before any capture is decoded
/// against it and before any sample runs.
///
/// The parser preflight is where an oracle is compared with observed parser
/// behavior. This is where the shape of the declared work is checked, so a
/// fixture that could never produce the rows the protocol requires is refused
/// instead of producing a short measurement.
pub fn verifyDomain(domain: Domain) BenchReportError!void {
    _ = try countDomain(domain);
    for (domain.segments) |segment| {
        for (segment.fixtures) |*fixture| {
            if (!std.mem.eql(u8, fixture.outcome, contract.accepted_outcome)) continue;
            // An accepted fixture is measured on a parse and on complete
            // semantic consumption; a CommonMark one is also rendered safely.
            if (!hasStage(fixture, .parse) or !hasStage(fixture, .traverse)) {
                return error.MissingAcceptanceStage;
            }
            if (segment.format == .commonmark and !hasStage(fixture, .render_html)) {
                return error.MissingRenderStage;
            }
        }
    }
}

/// One declared case: the fixture it belongs to, the format it is reported
/// under, and the next stage that fixture declares. The decoder walks these in
/// order and admits no other row.
const DeclaredCase = struct {
    format: Format,
    workload: Workload,
    fixture: *const Fixture,
    stage: Stage,
    stage_index: usize,
};

const DomainCursor = struct {
    segments: []const DomainSegment,
    segment_index: usize = 0,
    fixture_index: usize = 0,
    stage_index: usize = 0,

    fn init(domain: Domain) DomainCursor {
        return .{ .segments = domain.segments };
    }

    fn next(self: *DomainCursor) ?DeclaredCase {
        while (self.segment_index < self.segments.len) {
            const segment = self.segments[self.segment_index];
            if (self.fixture_index < segment.fixtures.len) {
                const fixture = &segment.fixtures[self.fixture_index];
                if (self.stage_index < fixture.stages.len) {
                    const declared: DeclaredCase = .{
                        .format = segment.format,
                        .workload = fixture.workload,
                        .fixture = fixture,
                        .stage = fixture.stages[self.stage_index],
                        .stage_index = self.stage_index,
                    };
                    self.stage_index += 1;
                    return declared;
                }
                self.fixture_index += 1;
                self.stage_index = 0;
                continue;
            }
            self.segment_index += 1;
            self.fixture_index = 0;
            self.stage_index = 0;
        }
        return null;
    }
};

fn formatFromName(text: []const u8) ?Format {
    inline for (@typeInfo(Format).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn workloadFromName(text: []const u8) ?Workload {
    inline for (@typeInfo(Workload).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn stageFromName(text: []const u8) ?Stage {
    inline for (@typeInfo(Stage).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Option surface and hard bounds.
//
// There is no stream chunk knob here and none may be added: neither semantic
// parser provides a stream indexer, so accepting a chunk size would be a claim
// the measurement cannot support.
// ---------------------------------------------------------------------------

pub const min_samples: u16 = 1;
pub const max_samples: u16 = 32;
pub const min_iterations: u16 = 1;
pub const max_iterations: u16 = 32;

const default_samples: u16 = 3;
const default_iterations: u16 = 3;

/// The measured invocation shape. Both knobs are bench contract knobs, never a
/// local policy knob.
pub const Options = struct {
    samples: u16 = default_samples,
    iterations: u16 = default_iterations,

    pub fn eql(left: Options, right: Options) bool {
        return left.samples == right.samples and
            left.iterations == right.iterations;
    }

    pub fn validate(self: Options) OptionsError!void {
        if (self.samples < min_samples or self.samples > max_samples) return error.SampleCountOutOfRange;
        if (self.iterations < min_iterations or self.iterations > max_iterations) return error.IterationCountOutOfRange;
    }
};

pub const OptionsError = error{
    SampleCountOutOfRange,
    IterationCountOutOfRange,
};

/// Bounds on the raw report text. They are fixed so a hostile or corrupt
/// capture cannot make the parser allocate or scan without limit.
pub const max_report_lines: usize = 512;
pub const max_report_line_bytes: usize = 1024;
pub const max_comparison_reports: usize = 64;
pub const max_outcome_bytes: usize = 64;

// ---------------------------------------------------------------------------
// Errors.
// ---------------------------------------------------------------------------

pub const CliError = error{
    MissingOperation,
    UnknownOperation,
    MissingArchiveDirectory,
    MissingOutputDirectory,
    ExtraArguments,
    UnknownFlag,
    MissingFlagValue,
    DuplicateFlag,
    NotANumber,
} || OptionsError;

pub const BenchReportError = error{
    // Text and line bounds.
    EmptyStdout,
    MissingTrailingNewline,
    UnsupportedLineEnding,
    LineTooLong,
    TooManyLines,
    OutcomeTooLong,
    // Structure.
    MissingCsvHeader,
    MissingHeader,
    DuplicateHeader,
    UnknownHeader,
    MalformedHeader,
    MalformedInputDeclaration,
    MissingInputDeclaration,
    DuplicateInputDeclaration,
    TrailingInputDeclaration,
    WrongFieldCount,
    InvalidNumber,
    UnknownFormat,
    UnknownWorkload,
    UnknownStage,
    // Declared work domain.
    DomainSegmentCount,
    DomainFormatOrder,
    EmptyDomain,
    DuplicateWorkload,
    EmptyStageList,
    DuplicateStage,
    InvalidOracleOutcome,
    OutcomeStageMismatch,
    MissingAcceptanceStage,
    MissingRenderStage,
    // Rows.
    RowOrderMismatch,
    TrailingRow,
    MissingRows,
    InconsistentInputBytes,
    InconsistentInputHash,
    WrongIterationCount,
    UnexpectedOutcome,
    // Metadata values the measurement is pinned to.
    ProfileMismatch,
    BoundaryViolation,
    // Sample sets.
    UnstableResults,
    SampleCountMismatch,
    TooManySamples,
} || Allocator.Error;

pub const usage_text =
    \\usage:
    \\  record OUT_DIR [--samples N] [--iterations N]
    \\  verify ARCHIVE_DIR
    \\  reproduce OLD_ARCHIVE_DIR NEW_ARCHIVE_DIR
    \\
    \\defaults: --samples 3 --iterations 3
    \\samples and iterations accept 1..32. There is no stream chunk knob:
    \\neither semantic parser provides streaming.
;

// ---------------------------------------------------------------------------
// Command line.
// ---------------------------------------------------------------------------

pub const RecordCommand = struct {
    out_dir: []const u8,
    options: Options,
};

pub const ReproduceCommand = struct {
    old_dir: []const u8,
    new_dir: []const u8,
};

pub const Command = union(enum) {
    record: RecordCommand,
    verify: []const u8,
    reproduce: ReproduceCommand,
};

fn parseBoundedCount(
    comptime T: type,
    text: []const u8,
    comptime low: u16,
    comptime high: u16,
    comptime out_of_range: OptionsError,
) CliError!T {
    const parsed = std.fmt.parseUnsigned(u32, text, 10) catch return error.NotANumber;
    if (parsed < low or parsed > high) return out_of_range;
    return @intCast(parsed);
}

fn parseRecordArguments(arguments: []const []const u8) CliError!RecordCommand {
    if (arguments.len < 2) return error.MissingOutputDirectory;
    const out_dir = arguments[1];
    if (out_dir.len == 0) return error.MissingOutputDirectory;

    var options: Options = .{};
    var seen_samples = false;
    var seen_iterations = false;

    var index: usize = 2;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        if (index + 1 >= arguments.len) return error.MissingFlagValue;
        const value = arguments[index + 1];
        index += 1;

        if (std.mem.eql(u8, flag, "--samples")) {
            if (seen_samples) return error.DuplicateFlag;
            seen_samples = true;
            options.samples = try parseBoundedCount(
                u16,
                value,
                min_samples,
                max_samples,
                error.SampleCountOutOfRange,
            );
        } else if (std.mem.eql(u8, flag, "--iterations")) {
            if (seen_iterations) return error.DuplicateFlag;
            seen_iterations = true;
            options.iterations = try parseBoundedCount(
                u16,
                value,
                min_iterations,
                max_iterations,
                error.IterationCountOutOfRange,
            );
        } else {
            return error.UnknownFlag;
        }
    }

    try options.validate();
    return .{ .out_dir = out_dir, .options = options };
}

pub fn parseCommand(operation_arguments: []const []const u8) CliError!Command {
    if (operation_arguments.len == 0) return error.MissingOperation;
    const operation = operation_arguments[0];

    if (std.mem.eql(u8, operation, "record")) {
        return .{ .record = try parseRecordArguments(operation_arguments) };
    }
    if (std.mem.eql(u8, operation, "verify")) {
        if (operation_arguments.len != 2) return error.ExtraArguments;
        if (operation_arguments[1].len == 0) return error.MissingArchiveDirectory;
        return .{ .verify = operation_arguments[1] };
    }
    if (std.mem.eql(u8, operation, "reproduce")) {
        if (operation_arguments.len != 3) return error.ExtraArguments;
        if (operation_arguments[1].len == 0) return error.MissingArchiveDirectory;
        if (operation_arguments[2].len == 0) return error.MissingOutputDirectory;
        return .{ .reproduce = .{
            .old_dir = operation_arguments[1],
            .new_dir = operation_arguments[2],
        } };
    }
    return error.UnknownOperation;
}

// ---------------------------------------------------------------------------
// The printed protocol.
// ---------------------------------------------------------------------------

/// The exact header line the semantic bench prints before its rows.
pub const csv_header =
    "format,workload,stage,outcome,input_bytes,iterations,elapsed_ns,checksum,allocation_count,allocated_bytes";
pub const csv_field_count = 10;

/// The exact prefix of an input declaration line.
pub const input_declaration_prefix = "# input ";

/// The profile versions this measurement is pinned to. A capture from a
/// different CommonMark spec revision or a different YAML profile is not this
/// measurement, so it is refused rather than compared.
pub const commonmark_profile_version: []const u8 = "0.31.2";
pub const yaml_extended_profile_version: []const u8 = "yaml-extended-e2b-1.2.2";

/// The boundary claims the measurement must state and the decoder checks. No
/// streaming claim exists, and no result is ever ranked.
pub const streaming_boundary_text: []const u8 = "none";
pub const ranking_boundary_text: []const u8 = "none";

/// Every `# key=value` header the semantic bench prints, in slot order. An
/// unknown key means the measured contract moved, so the capture must not be
/// published as complete.
pub const known_header_keys = [_][]const u8{
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

const header_slot_count = known_header_keys.len;

// ---------------------------------------------------------------------------
// Decoded records.
// ---------------------------------------------------------------------------

/// The semantic metadata of one capture. The name matches the legacy runtime's
/// type so the archive runtime can hold either mode's headers under one
/// interface; the fields are the semantic ones, with no legacy resident,
/// prefix, stream, or synthetic-scale field.
pub const BenchHeaders = struct {
    zig_version: []const u8,
    optimize: []const u8,
    target_arch: []const u8,
    vector_len: u64,
    commonmark_profile: []const u8,
    yaml_profile: []const u8,
    setup: []const u8,
    consumption: []const u8,
    render_html: []const u8,
    streaming: []const u8,
    ranking: []const u8,
};

/// One declared input.
pub const InputEntry = struct {
    format: Format,
    workload: Workload,
    input_hash: u64,
    input_bytes: u64,
};

/// One measured case as printed by one sample.
///
/// `outcome` is the fixture's independently authored oracle string, taken from
/// the declared domain rather than from the capture: a decoded record never
/// borrows a slice of captured stdout, and an outcome that disagrees with the
/// oracle is refused instead of stored.
pub const CaseRecord = struct {
    format: Format,
    workload: Workload,
    stage: Stage,
    outcome: []const u8,
    input_hash: u64,
    input_bytes: u64,
    iterations: u64,
    elapsed_ns: u64,
    checksum: u64,
    allocation_count: u64,
    allocated_bytes: u64,
};

/// One measured case merged across every sample of a recording. `elapsed_ns`
/// is retained per sample and is never compared for equality.
pub const MergedCase = struct {
    stable: CaseRecord,
    elapsed_ns: []u64,
};

/// One complete sample. The caller owns it and releases it with `freeReport`.
pub const Report = struct {
    headers: BenchHeaders,
    inputs: []InputEntry,
    cases: []CaseRecord,
};

/// Releases everything `parseReport` allocated.
pub fn freeReport(allocator: Allocator, parsed: *Report) void {
    allocator.free(parsed.inputs);
    allocator.free(parsed.cases);
    freeHeaders(allocator, &parsed.headers);
    parsed.* = undefined;
}

/// The merged result of one recording: every declared input and every declared
/// case with each per-sample timing. Callers own the returned memory and free
/// it with `freeAnalysis` and the allocator they passed in.
pub const Analysis = struct {
    headers: BenchHeaders,
    inputs: []InputEntry,
    cases: []MergedCase,
};

/// A `BenchHeaders` field that owns a copy of one header value, named by the
/// `known_header_keys` slot that value comes from.
const OwnedHeader = struct {
    field: []const u8,
    slot: usize,
};

/// The owning header fields, in slot order. `materializeHeaders` fills them in
/// this order, so a failure releases exactly the copies it already took, and
/// `freeHeaders` walks the same order.
const owned_headers = [_]OwnedHeader{
    .{ .field = "zig_version", .slot = 0 },
    .{ .field = "optimize", .slot = 1 },
    .{ .field = "target_arch", .slot = 2 },
    .{ .field = "commonmark_profile", .slot = 4 },
    .{ .field = "yaml_profile", .slot = 5 },
    .{ .field = "setup", .slot = 6 },
    .{ .field = "consumption", .slot = 7 },
    .{ .field = "render_html", .slot = 8 },
    .{ .field = "streaming", .slot = 9 },
    .{ .field = "ranking", .slot = 10 },
};

comptime {
    // Every entry names the field of its own header key, so a renamed field or
    // a moved key is a compile error rather than a header read into the wrong
    // field.
    for (owned_headers) |entry| {
        if (!std.mem.eql(u8, known_header_keys[entry.slot], entry.field)) {
            @compileError("an owned_headers entry does not name its own known_header_keys slot");
        }
    }
}

fn parseDecimal(comptime T: type, text: []const u8) BenchReportError!T {
    return std.fmt.parseUnsigned(u64, text, 10) catch error.InvalidNumber;
}

fn parseHex(text: []const u8) BenchReportError!u64 {
    if (text.len == 0 or text.len > 16) return error.InvalidNumber;
    return std.fmt.parseUnsigned(u64, text, 16) catch error.InvalidNumber;
}

fn splitRow(line: []const u8, out: *[csv_field_count][]const u8) bool {
    var fields: [csv_field_count][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, line, ',');
    while (it.next()) |field| {
        if (count == csv_field_count) return false;
        fields[count] = field;
        count += 1;
    }
    if (count != csv_field_count) return false;
    out.* = fields;
    return true;
}

fn checkLineShape(line: []const u8) BenchReportError!void {
    if (line.len > max_report_line_bytes) return error.LineTooLong;
    for (line) |byte| {
        if (byte == '\r') return error.UnsupportedLineEnding;
        if (byte == 0) return error.UnsupportedLineEnding;
    }
}

const InputDeclaration = struct {
    format: Format,
    workload: Workload,
    input_hash: u64,
};

fn splitDeclaration(line: []const u8) BenchReportError!InputDeclaration {
    var rest = line[input_declaration_prefix.len..];
    const format_text = takeToken(&rest, "format=") orelse return error.MalformedInputDeclaration;
    const workload_text = takeToken(&rest, "workload=") orelse return error.MalformedInputDeclaration;
    const hash_text = takeToken(&rest, "input_hash=") orelse return error.MalformedInputDeclaration;
    if (rest.len != 0) return error.MalformedInputDeclaration;
    const format = formatFromName(format_text) orelse return error.UnknownFormat;
    const workload = workloadFromName(workload_text) orelse return error.UnknownWorkload;
    return .{ .format = format, .workload = workload, .input_hash = try parseHex(hash_text) };
}

/// Consumes `prefix` plus the single space-delimited token that follows it.
fn takeToken(rest: *[]const u8, prefix: []const u8) ?[]const u8 {
    var cursor = rest.*;
    while (cursor.len > 0 and cursor[0] == ' ') cursor = cursor[1..];
    if (!std.mem.startsWith(u8, cursor, prefix)) return null;
    const value = cursor[prefix.len..];
    const end = std.mem.indexOfScalar(u8, value, ' ') orelse value.len;
    rest.* = value[end..];
    return value[0..end];
}

/// One declared input carries exactly one declaration, so a declaration naming
/// an input this capture has already admitted is a duplicate even when rows of
/// the first declaration intervened. A pending declaration is not listed: its
/// input is not admitted until its own first row records it.
fn declaresAdmittedInput(
    inputs: []const InputEntry,
    inputs_filled: usize,
    declaration: InputDeclaration,
) bool {
    for (inputs[0..inputs_filled]) |entry| {
        if (entry.format == declaration.format and entry.workload == declaration.workload) {
            return true;
        }
    }
    return false;
}

fn headerSlot(key: []const u8) ?usize {
    for (known_header_keys, 0..) |candidate, index| {
        if (std.mem.eql(u8, key, candidate)) return index;
    }
    return null;
}

fn parseHeaderLine(line: []const u8, values: *[header_slot_count]?[]const u8) BenchReportError!void {
    if (line.len < 3) return error.MalformedHeader;
    const body = line[2..];
    const equals = std.mem.indexOfScalar(u8, body, '=') orelse return error.MalformedHeader;
    const key = body[0..equals];
    const value = body[equals + 1 ..];
    const slot = headerSlot(key) orelse return error.UnknownHeader;
    if (values[slot] != null) return error.DuplicateHeader;
    values[slot] = value;
}

/// Copies the header values into owning fields. Every field is filled on its
/// own, so `live` always names exactly the strings that are already owned: a
/// later copy, or the number, releases that set and nothing else.
fn materializeHeaders(
    allocator: Allocator,
    values: *const [header_slot_count]?[]const u8,
) BenchReportError!BenchHeaders {
    for (values) |value| {
        if (value == null) return error.MissingHeader;
    }
    const slot = struct {
        fn need(slots: *const [header_slot_count]?[]const u8, index: usize) []const u8 {
            return slots[index].?;
        }
    };

    var headers: BenchHeaders = undefined;
    var live: usize = 0;
    errdefer freeOwnedHeaders(allocator, &headers, live);
    inline for (owned_headers) |entry| {
        @field(headers, entry.field) = try allocator.dupe(u8, slot.need(values, entry.slot));
        live += 1;
    }

    headers.vector_len = try parseDecimal(u64, slot.need(values, 3));
    return headers;
}

/// Releases the first `live` owning header fields, in `owned_headers` order.
fn freeOwnedHeaders(allocator: Allocator, headers: *const BenchHeaders, live: usize) void {
    inline for (owned_headers, 0..) |entry, index| {
        if (index < live) allocator.free(@field(headers.*, entry.field));
    }
}

/// Releases every string `materializeHeaders` duplicated.
pub fn freeHeaders(allocator: Allocator, headers: *BenchHeaders) void {
    freeOwnedHeaders(allocator, headers, owned_headers.len);
    headers.* = undefined;
}

/// Every contract and profile header must match. A capture whose measurement
/// profile text differs is not the same measurement.
pub fn headersEql(reference: BenchHeaders, observed: BenchHeaders) bool {
    return std.mem.eql(u8, reference.zig_version, observed.zig_version) and
        std.mem.eql(u8, reference.optimize, observed.optimize) and
        std.mem.eql(u8, reference.target_arch, observed.target_arch) and
        reference.vector_len == observed.vector_len and
        std.mem.eql(u8, reference.commonmark_profile, observed.commonmark_profile) and
        std.mem.eql(u8, reference.yaml_profile, observed.yaml_profile) and
        std.mem.eql(u8, reference.setup, observed.setup) and
        std.mem.eql(u8, reference.consumption, observed.consumption) and
        std.mem.eql(u8, reference.render_html, observed.render_html) and
        std.mem.eql(u8, reference.streaming, observed.streaming) and
        std.mem.eql(u8, reference.ranking, observed.ranking);
}

/// Compares every field that must not move between samples of one recording or
/// between two recordings of the same work, including the observed outcome.
/// `elapsed_ns` is excluded: a timing is an observation, never an identity.
pub fn caseEql(reference: CaseRecord, observed: CaseRecord) bool {
    return reference.format == observed.format and
        reference.workload == observed.workload and
        reference.stage == observed.stage and
        std.mem.eql(u8, reference.outcome, observed.outcome) and
        reference.input_hash == observed.input_hash and
        reference.input_bytes == observed.input_bytes and
        reference.iterations == observed.iterations and
        reference.checksum == observed.checksum and
        reference.allocation_count == observed.allocation_count and
        reference.allocated_bytes == observed.allocated_bytes;
}

pub fn inputEql(reference: InputEntry, observed: InputEntry) bool {
    return reference.format == observed.format and
        reference.workload == observed.workload and
        reference.input_hash == observed.input_hash and
        reference.input_bytes == observed.input_bytes;
}

/// Whole-record comparison used by `reproduce` and by archive verification.
pub fn sameAs(reference: Analysis, observed: Analysis) bool {
    if (!headersEql(reference.headers, observed.headers)) return false;
    if (reference.inputs.len != observed.inputs.len) return false;
    if (reference.cases.len != observed.cases.len) return false;
    for (reference.inputs, observed.inputs) |a, b| {
        if (!inputEql(a, b)) return false;
    }
    for (reference.cases, observed.cases) |a, b| {
        if (!caseEql(a.stable, b.stable)) return false;
    }
    return true;
}

/// Parses every sample and proves the recorded work is stable. Only the fields
/// that must not move are compared; `elapsed_ns` is retained per sample and is
/// never compared.
///
/// The captured sample count must equal the requested one exactly. A short set
/// is partial evidence, not a smaller measurement, so it is refused the same
/// way an over-long set is.
pub fn analyzeSamples(
    allocator: Allocator,
    stdouts: []const []const u8,
    expected: Options,
    domain: Domain,
) BenchReportError!Analysis {
    if (stdouts.len == 0) return error.EmptyStdout;
    if (stdouts.len > max_comparison_reports) return error.TooManySamples;
    if (stdouts.len != expected.samples) return error.SampleCountMismatch;

    const first = try parseReport(allocator, stdouts[0], expected, domain);
    var headers = first.headers;
    errdefer freeHeaders(allocator, &headers);
    defer {
        allocator.free(first.inputs);
        allocator.free(first.cases);
    }

    const cases = try allocator.alloc(MergedCase, first.cases.len);
    var filled: usize = 0;
    errdefer {
        for (cases[0..filled]) |merged| allocator.free(merged.elapsed_ns);
        allocator.free(cases);
    }
    for (first.cases, 0..) |source, index| {
        const timings = try allocator.alloc(u64, stdouts.len);
        timings[0] = source.elapsed_ns;
        // The merged record carries no authoritative single timing; every
        // observation lives in `elapsed_ns`.
        var merged = source;
        merged.elapsed_ns = 0;
        cases[index] = .{ .stable = merged, .elapsed_ns = timings };
        filled = index + 1;
    }

    for (stdouts[1..], 1..) |sample_stdout, sample_index| {
        var observed = try parseReport(allocator, sample_stdout, expected, domain);
        defer freeReport(allocator, &observed);
        if (!headersEql(headers, observed.headers)) return error.UnstableResults;
        for (observed.cases, 0..) |record, index| {
            cases[index].elapsed_ns[sample_index] = record.elapsed_ns;
            if (!caseEql(cases[index].stable, record)) return error.UnstableResults;
        }
        for (observed.inputs, 0..) |record, index| {
            if (!inputEql(first.inputs[index], record)) return error.UnstableResults;
        }
    }

    return .{
        .headers = headers,
        .inputs = try allocator.dupe(InputEntry, first.inputs),
        .cases = cases,
    };
}

/// Releases everything `analyzeSamples` allocated for one merged recording.
pub fn freeAnalysis(allocator: Allocator, analysis: *Analysis) void {
    for (analysis.cases) |merged| allocator.free(merged.elapsed_ns);
    allocator.free(analysis.cases);
    allocator.free(analysis.inputs);
    freeHeaders(allocator, &analysis.headers);
    analysis.* = undefined;
}

// ---------------------------------------------------------------------------
// Strict stdout parsing.
// ---------------------------------------------------------------------------

/// Parses one complete semantic bench stdout sample against the declared work
/// domain. Every expectation is checked: the header key set and its pinned
/// values, the CSV header, the exact declared row order, the input
/// declarations, their hashes against the real fixture sources, their byte
/// counts, the per-case iteration count, and each row's outcome against its
/// fixture's oracle.
///
/// The returned `headers` own a copy of every header string and the caller
/// releases them with `freeReport`. `inputs` and `cases` are heap arrays the
/// caller frees the same way. No returned slice borrows `stdout`.
pub fn parseReport(
    allocator: Allocator,
    stdout: []const u8,
    expected: Options,
    domain: Domain,
) BenchReportError!Report {
    if (stdout.len == 0) return error.EmptyStdout;
    if (!std.mem.endsWith(u8, stdout, "\n")) return error.MissingTrailingNewline;

    const counts = try countDomain(domain);

    var header_values: [header_slot_count]?[]const u8 = @splat(null);
    var csv_seen = false;
    var pending: ?InputDeclaration = null;
    var cursor = DomainCursor.init(domain);

    const inputs = try allocator.alloc(InputEntry, counts.inputs);
    errdefer allocator.free(inputs);
    const cases = try allocator.alloc(CaseRecord, counts.cases);
    errdefer allocator.free(cases);
    var inputs_filled: usize = 0;
    var cases_filled: usize = 0;

    var it = std.mem.splitScalar(u8, stdout, '\n');
    var line_number: usize = 0;
    while (it.next()) |line| {
        if (line_number == max_report_lines) return error.TooManyLines;
        line_number += 1;
        try checkLineShape(line);
        if (line.len == 0) continue;

        if (line[0] == '#') {
            if (std.mem.startsWith(u8, line, input_declaration_prefix)) {
                if (pending != null) return error.DuplicateInputDeclaration;
                const declaration = try splitDeclaration(line);
                // The adjacent declaration above is refused before it is even
                // parsed; this one is refused after, because it names an input
                // the capture has already declared and measured.
                if (declaresAdmittedInput(inputs, inputs_filled, declaration)) {
                    return error.DuplicateInputDeclaration;
                }
                pending = declaration;
                continue;
            }
            if (csv_seen) return error.MalformedHeader;
            try parseHeaderLine(line, &header_values);
            continue;
        }

        if (!csv_seen) {
            if (!std.mem.eql(u8, line, csv_header)) return error.MissingCsvHeader;
            csv_seen = true;
            continue;
        }

        // A row past the last declared fixture cannot match the declared
        // order, the same defect as a repeated row, and says nothing about how
        // many samples were captured.
        const declared = cursor.next() orelse return error.TrailingRow;
        const fixture = declared.fixture;

        var fields: [csv_field_count][]const u8 = undefined;
        if (!splitRow(line, &fields)) return error.WrongFieldCount;

        const row_format = formatFromName(fields[0]) orelse return error.UnknownFormat;
        const row_workload = workloadFromName(fields[1]) orelse return error.UnknownWorkload;
        const row_stage = stageFromName(fields[2]) orelse return error.UnknownStage;
        const row_outcome = fields[3];
        if (row_outcome.len == 0 or row_outcome.len > max_outcome_bytes) return error.OutcomeTooLong;

        const input_bytes = try parseDecimal(u64, fields[4]);
        const iterations = try parseDecimal(u64, fields[5]);
        const elapsed_ns = try parseDecimal(u64, fields[6]);
        const checksum = try parseDecimal(u64, fields[7]);
        const allocation_count = try parseDecimal(u64, fields[8]);
        const allocated_bytes = try parseDecimal(u64, fields[9]);

        if (row_format != declared.format or
            row_workload != declared.workload or
            row_stage != declared.stage)
        {
            return error.RowOrderMismatch;
        }
        if (iterations != expected.iterations) return error.WrongIterationCount;
        // The outcome is checked against the fixture's independently authored
        // oracle, so a capture cannot relabel an accepted fixture or invent an
        // error for a rejected one.
        if (!std.mem.eql(u8, row_outcome, fixture.outcome)) return error.UnexpectedOutcome;

        const declaration = pending orelse return error.MissingInputDeclaration;
        if (declaration.format != declared.format or declaration.workload != declared.workload) {
            return error.MissingInputDeclaration;
        }

        if (declared.stage_index == 0) {
            if (input_bytes != @as(u64, @intCast(fixture.source.len))) return error.InconsistentInputBytes;
            const declared_hash = contract.checksumBytes(fixture.source);
            if (declaration.input_hash != declared_hash) return error.InconsistentInputHash;
            inputs[inputs_filled] = .{
                .format = declared.format,
                .workload = declared.workload,
                .input_hash = declared_hash,
                .input_bytes = input_bytes,
            };
            inputs_filled += 1;
        } else {
            const input = inputs[inputs_filled - 1];
            if (input_bytes != input.input_bytes) return error.InconsistentInputBytes;
            if (declaration.input_hash != input.input_hash) return error.InconsistentInputHash;
        }

        cases[cases_filled] = .{
            .format = row_format,
            .workload = row_workload,
            .stage = row_stage,
            // The recorded outcome is the domain's oracle string, never a slice
            // of the capture.
            .outcome = fixture.outcome,
            .input_hash = declaration.input_hash,
            .input_bytes = input_bytes,
            .iterations = iterations,
            .elapsed_ns = elapsed_ns,
            .checksum = checksum,
            .allocation_count = allocation_count,
            .allocated_bytes = allocated_bytes,
        };
        cases_filled += 1;

        // The fixture is complete, so its next row needs its own declaration.
        if (declared.stage_index + 1 == fixture.stages.len) pending = null;
    }

    if (!csv_seen) return error.MissingCsvHeader;
    // A declaration still pending at the end is the declaration of a fixture
    // whose rows never arrived, so a capture that is short of rows is refused as
    // missing rows and not as the dangling declaration that defect leaves
    // behind. Only a capture that already holds every declared row has a
    // declaration naming no declared work at all, and that is a trailing
    // declaration.
    if (pending != null and cases_filled == counts.cases) return error.TrailingInputDeclaration;
    if (cases_filled != counts.cases) return error.MissingRows;
    if (inputs_filled != counts.inputs) return error.MissingRows;

    var headers = try materializeHeaders(allocator, &header_values);
    errdefer freeHeaders(allocator, &headers);
    if (!std.mem.eql(u8, headers.commonmark_profile, commonmark_profile_version)) return error.ProfileMismatch;
    if (!std.mem.eql(u8, headers.yaml_profile, yaml_extended_profile_version)) return error.ProfileMismatch;
    if (!std.mem.eql(u8, headers.streaming, streaming_boundary_text)) return error.BoundaryViolation;
    if (!std.mem.eql(u8, headers.ranking, ranking_boundary_text)) return error.BoundaryViolation;

    return .{ .headers = headers, .inputs = inputs, .cases = cases };
}

const testing = std.testing;

// A four-fixture domain in the protocol's order: two CommonMark fixtures, then
// two YAML extended ones, each segment in declaration order. The accepted
// fixtures carry parse, traverse, and (for CommonMark) safe rendering; the
// rejected ones carry exactly the stage that observes their error. The sources
// are small but real: the decoder checks its own recorded hash and byte count
// against them.
const cm_blocks_source = "# Title\n\nbody text\n";
const cm_input_limit_source = "x\n";
const yaml_literal_clip_source = "a: |\n  one\n";
const yaml_cooked_limit_source = "a: |\n  one\n  two\n";

const commonmark_test_fixtures = [_]Fixture{
    .{
        .workload = .cm_blocks,
        .source = cm_blocks_source,
        .stages = &.{ .parse, .traverse, .render_html },
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .cm_input_limit,
        .source = cm_input_limit_source,
        .stages = &.{.resource_error},
        .outcome = "InputTooLarge",
    },
};

const yaml_test_fixtures = [_]Fixture{
    .{
        .workload = .yaml_literal_clip,
        .source = yaml_literal_clip_source,
        .stages = &.{ .parse, .traverse },
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .yaml_cooked_limit,
        .source = yaml_cooked_limit_source,
        .stages = &.{.resource_error},
        .outcome = "CookedBytesExceeded",
    },
};

const test_segments = [_]DomainSegment{
    .{ .format = .commonmark, .fixtures = &commonmark_test_fixtures },
    .{ .format = .yaml_extended, .fixtures = &yaml_test_fixtures },
};

const test_domain: Domain = .{ .segments = &test_segments };

// The canonical capture is 23 lines: eleven metadata headers on lines 0 through
// 10, the CSV header on line 11, then one declaration and its rows for each of
// the four declared fixtures.
const line_vector_len: usize = 3;
const line_commonmark_profile: usize = 4;
const line_setup: usize = 6;
const line_streaming: usize = 9;
const line_ranking: usize = 10;
const line_csv: usize = 11;
const line_declaration_0: usize = 12;
const line_row_0: usize = 13;
const line_declaration_1: usize = 16;
const line_row_1: usize = 17;
const line_row_3: usize = 22;

/// Emits exactly what the semantic bench prints for `test_domain` and the
/// given options.
fn synthReport(allocator: Allocator, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    // A capture that cannot be written still owns the buffer the builder has
    // already taken; `toOwnedSlice` empties it on the way out, so this only
    // fires on the failure paths.
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("# zig_version=0.16.0\n");
    try writer.writeAll("# optimize=ReleaseFast\n");
    try writer.writeAll("# target_arch=x86_64\n");
    try writer.writeAll("# vector_len=32\n");
    try writer.writeAll("# commonmark_profile=");
    try writer.writeAll(commonmark_profile_version);
    try writer.writeAll("\n");
    try writer.writeAll("# yaml_profile=");
    try writer.writeAll(yaml_extended_profile_version);
    try writer.writeAll("\n");
    try writer.writeAll("# setup=fresh parse, named consumption, and destruction per iteration\n");
    // Exactly what the measurement executable prints. A synthetic capture that
    // claimed a whole-document checksum for every stage would assert coverage
    // the `parse` stage deliberately does not perform.
    try writer.writeAll("# consumption=traverse consumes complete semantics; parse consumption is small by design\n");
    try writer.writeAll("# render_html=safe mode: raw HTML omitted, dangerous URLs filtered\n");
    try writer.writeAll("# streaming=");
    try writer.writeAll(streaming_boundary_text);
    try writer.writeAll("\n");
    try writer.writeAll("# ranking=");
    try writer.writeAll(ranking_boundary_text);
    try writer.writeAll("\n");
    try writer.writeAll(csv_header);
    try writer.writeAll("\n");

    var cursor = DomainCursor.init(test_domain);
    var case_index: usize = 0;
    while (cursor.next()) |declared| {
        const fixture = declared.fixture;
        if (declared.stage_index == 0) {
            try writer.print("{s}format={s} workload={s} input_hash={x}\n", .{
                input_declaration_prefix,
                @tagName(declared.format),
                @tagName(fixture.workload),
                contract.checksumBytes(fixture.source),
            });
        }
        try writer.print("{s},{s},{s},{s},{d},{d},{d},{d},{d},{d}\n", .{
            @tagName(declared.format),
            @tagName(fixture.workload),
            @tagName(declared.stage),
            fixture.outcome,
            @as(u64, @intCast(fixture.source.len)),
            @as(u64, options.iterations),
            1000 + case_index * 7,
            5000 + case_index,
            4 + case_index,
            512 + case_index * 64,
        });
        case_index += 1;
    }
    return out.toOwnedSlice();
}

const LineRange = struct { start: usize, end: usize };

fn lineBounds(text: []const u8, index: usize) ?LineRange {
    var start: usize = 0;
    var count: usize = 0;
    while (count < index) {
        const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null;
        start = newline + 1;
        count += 1;
    }
    const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse {
        if (start == text.len) return null;
        return .{ .start = start, .end = text.len };
    };
    return .{ .start = start, .end = newline + 1 };
}

fn dropLine(allocator: Allocator, text: []const u8, index: usize) ![]u8 {
    const bounds = lineBounds(text, index) orelse return error.LineMissing;
    return std.mem.concat(allocator, u8, &.{ text[0..bounds.start], text[bounds.end..] });
}

fn replaceLine(allocator: Allocator, text: []const u8, index: usize, replacement: []const u8) ![]u8 {
    const bounds = lineBounds(text, index) orelse return error.LineMissing;
    const with_newline = try std.mem.concat(allocator, u8, &.{ replacement, "\n" });
    defer allocator.free(with_newline);
    return std.mem.concat(allocator, u8, &.{ text[0..bounds.start], with_newline, text[bounds.end..] });
}

fn lineText(allocator: Allocator, text: []const u8, index: usize) ![]u8 {
    const bounds = lineBounds(text, index) orelse return error.LineMissing;
    return allocator.dupe(u8, text[bounds.start .. bounds.end - 1]);
}

fn expectReportError(text: []const u8, options: Options, expected: anyerror) !void {
    const single = [_][]const u8{text};
    if (analyzeSamples(testing.allocator, &single, options, test_domain)) |analysis| {
        var owned = analysis;
        freeAnalysis(testing.allocator, &owned);
        return error.ExpectedRefusal;
    } else |err| {
        try testing.expectEqual(expected, err);
    }
}

fn expectDomainError(domain: Domain, expected: anyerror) !void {
    try testing.expectError(expected, verifyDomain(domain));
}

/// Replaces one row line and returns a capture that must be refused.
fn expectPatchedRowError(
    text: []const u8,
    options: Options,
    line_index: usize,
    replacement: []const u8,
    expected: anyerror,
) !void {
    const patched = try replaceLine(testing.allocator, text, line_index, replacement);
    defer testing.allocator.free(patched);
    try expectReportError(patched, options, expected);
}

test "a canonical capture decodes to the declared fixtures, stages, and outcomes" {
    const options: Options = .{};
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    const samples = [_][]const u8{ text, text, text };
    var analysis = try analyzeSamples(testing.allocator, &samples, options, test_domain);
    defer freeAnalysis(testing.allocator, &analysis);

    try testing.expectEqual(@as(usize, 4), analysis.inputs.len);
    try testing.expectEqual(@as(usize, 7), analysis.cases.len);
    try testing.expectEqualStrings("0.16.0", analysis.headers.zig_version);
    try testing.expectEqualStrings(commonmark_profile_version, analysis.headers.commonmark_profile);
    try testing.expectEqualStrings(yaml_extended_profile_version, analysis.headers.yaml_profile);
    try testing.expectEqual(@as(u64, 32), analysis.headers.vector_len);
    try testing.expectEqualStrings(streaming_boundary_text, analysis.headers.streaming);
    try testing.expectEqualStrings(ranking_boundary_text, analysis.headers.ranking);

    try testing.expectEqual(Format.commonmark, analysis.inputs[0].format);
    try testing.expectEqual(Workload.cm_blocks, analysis.inputs[0].workload);
    try testing.expectEqual(contract.checksumBytes(cm_blocks_source), analysis.inputs[0].input_hash);
    try testing.expectEqual(@as(u64, cm_blocks_source.len), analysis.inputs[0].input_bytes);
    try testing.expectEqual(contract.checksumBytes(yaml_cooked_limit_source), analysis.inputs[3].input_hash);
    try testing.expectEqual(Format.yaml_extended, analysis.inputs[3].format);
    try testing.expectEqual(Workload.yaml_cooked_limit, analysis.inputs[3].workload);

    // CommonMark fixtures first, then YAML, each with its declared stages in
    // declared order. A merged case carries its stage on the `stable` record it
    // merged, never on the case itself.
    try testing.expectEqual(Stage.parse, analysis.cases[0].stable.stage);
    try testing.expectEqual(Stage.traverse, analysis.cases[1].stable.stage);
    try testing.expectEqual(Stage.render_html, analysis.cases[2].stable.stage);
    try testing.expectEqual(Workload.cm_input_limit, analysis.cases[3].stable.workload);
    try testing.expectEqual(Stage.resource_error, analysis.cases[3].stable.stage);
    try testing.expectEqualStrings("InputTooLarge", analysis.cases[3].stable.outcome);
    try testing.expectEqual(Workload.yaml_literal_clip, analysis.cases[4].stable.workload);
    try testing.expectEqual(Stage.parse, analysis.cases[4].stable.stage);
    try testing.expectEqual(Stage.traverse, analysis.cases[5].stable.stage);
    try testing.expectEqual(Workload.yaml_cooked_limit, analysis.cases[6].stable.workload);
    try testing.expectEqual(Stage.resource_error, analysis.cases[6].stable.stage);
    try testing.expectEqualStrings("CookedBytesExceeded", analysis.cases[6].stable.outcome);

    // The accepted fixtures report `accepted`; a rejected fixture reports the
    // error its run observed, never the accepted string copied from an
    // expectation.
    const expected_outcomes = [_][]const u8{
        contract.accepted_outcome,
        contract.accepted_outcome,
        contract.accepted_outcome,
        "InputTooLarge",
        contract.accepted_outcome,
        contract.accepted_outcome,
        "CookedBytesExceeded",
    };
    for (analysis.cases, expected_outcomes) |merged, expected_outcome| {
        try testing.expectEqualStrings(expected_outcome, merged.stable.outcome);
        try testing.expectEqual(@as(usize, 3), merged.elapsed_ns.len);
    }
}

test "timings are retained but never decide equality" {
    const options: Options = .{ .samples = 2 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    const faster = try replaceLine(
        testing.allocator,
        text,
        line_row_0,
        "commonmark,cm_blocks,parse,accepted,19,3,1,5000,4,512",
    );
    defer testing.allocator.free(faster);

    const samples = [_][]const u8{ text, faster };
    var analysis = try analyzeSamples(testing.allocator, &samples, options, test_domain);
    defer freeAnalysis(testing.allocator, &analysis);

    try testing.expectEqual(@as(u64, 1000), analysis.cases[0].elapsed_ns[0]);
    try testing.expectEqual(@as(u64, 1), analysis.cases[0].elapsed_ns[1]);
    try testing.expectEqual(@as(u64, 5000), analysis.cases[0].stable.checksum);
    // A recording whose samples carry different timings is still one
    // recording: the whole-record comparison never looks at a timing.
    const reversed = [_][]const u8{ faster, text };
    var other = try analyzeSamples(testing.allocator, &reversed, options, test_domain);
    defer freeAnalysis(testing.allocator, &other);
    try testing.expect(sameAs(analysis, other));
}

test "an outcome that disagrees with the fixture oracle is refused" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    // An accepted fixture may not relabel itself as an observed error.
    try expectPatchedRowError(
        text,
        options,
        line_row_0,
        "commonmark,cm_blocks,parse,TooManyNodes,19,3,1000,5000,4,512",
        error.UnexpectedOutcome,
    );

    // A rejected fixture may not claim acceptance.
    try expectPatchedRowError(
        text,
        options,
        line_row_1,
        "commonmark,cm_input_limit,resource_error,accepted,2,3,1007,5002,5,576",
        error.UnexpectedOutcome,
    );
}

test "a row for a stage the fixture does not declare is refused" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    // `cm_blocks` declares parse, traverse, and render_html. A reject row is a
    // valid stage name and still has no row here.
    try expectPatchedRowError(
        text,
        options,
        line_row_0 + 1,
        "commonmark,cm_blocks,reject,TooManyNodes,19,3,1007,5001,5,576",
        error.RowOrderMismatch,
    );
}

test "a missing, duplicated, or trailing row is refused" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    const missing = try dropLine(testing.allocator, text, line_row_3);
    defer testing.allocator.free(missing);
    try expectReportError(missing, options, error.MissingRows);

    // Repeating the first row where the traverse row belongs is the same
    // defect as an out-of-order row.
    const parse_row = try lineText(testing.allocator, text, line_row_0);
    defer testing.allocator.free(parse_row);
    try expectPatchedRowError(text, options, line_row_0 + 1, parse_row, error.RowOrderMismatch);

    const trailing = try std.mem.concat(testing.allocator, u8, &.{
        text,
        "commonmark,cm_blocks,parse,accepted,19,3,1000,5000,4,512\n",
    });
    defer testing.allocator.free(trailing);
    try expectReportError(trailing, options, error.TrailingRow);
}

test "a wrong input byte count or hash is refused" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    try expectPatchedRowError(
        text,
        options,
        line_row_0,
        "commonmark,cm_blocks,parse,accepted,18,3,1000,5000,4,512",
        error.InconsistentInputBytes,
    );

    // A later row of the same fixture may not disagree with its own input.
    try expectPatchedRowError(
        text,
        options,
        line_row_0 + 1,
        "commonmark,cm_blocks,traverse,accepted,20,3,1007,5001,5,576",
        error.InconsistentInputBytes,
    );

    const wrong_hash = try replaceLine(
        testing.allocator,
        text,
        line_declaration_0,
        "# input format=commonmark workload=cm_blocks input_hash=1",
    );
    defer testing.allocator.free(wrong_hash);
    try expectReportError(wrong_hash, options, error.InconsistentInputHash);
}

test "a row that disagrees with the requested iteration count is refused" {
    const text = try synthReport(testing.allocator, .{ .samples = 1 });
    defer testing.allocator.free(text);

    try expectReportError(text, .{ .samples = 1, .iterations = 2 }, error.WrongIterationCount);
    try expectReportError(text, .{ .samples = 1, .iterations = 1 }, error.WrongIterationCount);
}

test "unknown, duplicated, missing, and malformed headers are refused" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    const unknown = try replaceLine(testing.allocator, text, 0, "# note=hello");
    defer testing.allocator.free(unknown);
    try expectReportError(unknown, options, error.UnknownHeader);

    const duplicate = try replaceLine(testing.allocator, text, 0, "# optimize=Debug");
    defer testing.allocator.free(duplicate);
    try expectReportError(duplicate, options, error.DuplicateHeader);

    const malformed = try replaceLine(testing.allocator, text, 0, "#");
    defer testing.allocator.free(malformed);
    try expectReportError(malformed, options, error.MalformedHeader);

    const missing = try dropLine(testing.allocator, text, line_vector_len);
    defer testing.allocator.free(missing);
    try expectReportError(missing, options, error.MissingHeader);

    const no_csv = try dropLine(testing.allocator, text, line_csv);
    defer testing.allocator.free(no_csv);
    try expectReportError(no_csv, options, error.MissingCsvHeader);
}

test "unknown row names, a wrong field count, and an invalid number are refused" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    try expectPatchedRowError(
        text,
        options,
        line_row_0,
        "json,cm_blocks,parse,accepted,19,3,1000,5000,4,512",
        error.UnknownFormat,
    );
    try expectPatchedRowError(
        text,
        options,
        line_row_0,
        "commonmark,json,parse,accepted,19,3,1000,5000,4,512",
        error.UnknownWorkload,
    );
    try expectPatchedRowError(
        text,
        options,
        line_row_0,
        "commonmark,cm_blocks,stream,accepted,19,3,1000,5000,4,512",
        error.UnknownStage,
    );
    try expectPatchedRowError(
        text,
        options,
        line_row_0,
        "commonmark,cm_blocks,parse,accepted,19,3,1000,5000,4",
        error.WrongFieldCount,
    );
    try expectPatchedRowError(
        text,
        options,
        line_row_0,
        "commonmark,cm_blocks,parse,accepted,nineteen,3,1000,5000,4,512",
        error.InvalidNumber,
    );
    try expectPatchedRowError(
        text,
        options,
        line_row_0,
        "commonmark,cm_blocks,parse,accepted,0x13,3,1000,5000,4,512",
        error.InvalidNumber,
    );
}

test "malformed, duplicated, trailing, and missing declarations are refused" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    const malformed = try replaceLine(
        testing.allocator,
        text,
        line_declaration_0,
        "# input format=commonmark workload=cm_blocks",
    );
    defer testing.allocator.free(malformed);
    try expectReportError(malformed, options, error.MalformedInputDeclaration);

    const extra_token = try replaceLine(
        testing.allocator,
        text,
        line_declaration_0,
        "# input format=commonmark workload=cm_blocks input_hash=1 note=extra",
    );
    defer testing.allocator.free(extra_token);
    try expectReportError(extra_token, options, error.MalformedInputDeclaration);

    const unknown_workload = try replaceLine(
        testing.allocator,
        text,
        line_declaration_0,
        "# input format=commonmark workload=json input_hash=1",
    );
    defer testing.allocator.free(unknown_workload);
    try expectReportError(unknown_workload, options, error.UnknownWorkload);

    const bad_hash = try replaceLine(
        testing.allocator,
        text,
        line_declaration_0,
        "# input format=commonmark workload=cm_blocks input_hash=zz",
    );
    defer testing.allocator.free(bad_hash);
    try expectReportError(bad_hash, options, error.InvalidNumber);

    const declaration = try lineText(testing.allocator, text, line_declaration_0);
    defer testing.allocator.free(declaration);
    const duplicated = try replaceLine(
        testing.allocator,
        text,
        line_declaration_1,
        declaration,
    );
    defer testing.allocator.free(duplicated);
    try expectReportError(duplicated, options, error.DuplicateInputDeclaration);

    const absent = try dropLine(testing.allocator, text, line_declaration_0);
    defer testing.allocator.free(absent);
    try expectReportError(absent, options, error.MissingInputDeclaration);

    const trailing = try std.mem.concat(testing.allocator, u8, &.{
        text,
        "# input format=yaml_extended workload=yaml_alias input_hash=2\n",
    });
    defer testing.allocator.free(trailing);
    try expectReportError(trailing, options, error.TrailingInputDeclaration);
}

test "a comment after the CSV header that is not a declaration is refused" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    const patched = try replaceLine(testing.allocator, text, line_row_0, "# note=late");
    defer testing.allocator.free(patched);
    try expectReportError(patched, options, error.MalformedHeader);
}

test "text, line, and sample bounds are enforced" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    try expectReportError("", options, error.EmptyStdout);
    try expectReportError(text[0 .. text.len - 1], options, error.MissingTrailingNewline);

    const carriage_return = try replaceLine(testing.allocator, text, 0, "# zig_version=0.16.0\r");
    defer testing.allocator.free(carriage_return);
    try expectReportError(carriage_return, options, error.UnsupportedLineEnding);

    // One byte past the line bound, with the required trailing newline.
    var oversized: [max_report_line_bytes + 2]u8 = @splat('x');
    oversized[0] = '#';
    oversized[max_report_line_bytes + 1] = '\n';
    try expectReportError(&oversized, options, error.LineTooLong);

    const many_lines = try testing.allocator.alloc(u8, max_report_lines + 2);
    defer testing.allocator.free(many_lines);
    @memset(many_lines, '\n');
    try expectReportError(many_lines, options, error.TooManyLines);

    const long_outcome = try std.fmt.allocPrint(
        testing.allocator,
        "commonmark,cm_blocks,parse,{s},{d},3,1000,5000,4,512",
        .{ "TooManyNodesTooManyNodesTooManyNodesTooManyNodesTooManyNodesTooManyNodes", cm_blocks_source.len },
    );
    defer testing.allocator.free(long_outcome);
    try expectPatchedRowError(text, options, line_row_0, long_outcome, error.OutcomeTooLong);
}

test "the profile versions and the boundary claims are pinned" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    const other_commonmark = try replaceLine(
        testing.allocator,
        text,
        line_commonmark_profile,
        "# commonmark_profile=0.30.0",
    );
    defer testing.allocator.free(other_commonmark);
    try expectReportError(other_commonmark, options, error.ProfileMismatch);

    const other_yaml = try replaceLine(
        testing.allocator,
        text,
        line_commonmark_profile + 1,
        "# yaml_profile=yaml-basic-1.2.2",
    );
    defer testing.allocator.free(other_yaml);
    try expectReportError(other_yaml, options, error.ProfileMismatch);

    const streams = try replaceLine(testing.allocator, text, line_streaming, "# streaming=incremental");
    defer testing.allocator.free(streams);
    try expectReportError(streams, options, error.BoundaryViolation);

    const ranks = try replaceLine(testing.allocator, text, line_ranking, "# ranking=fastest");
    defer testing.allocator.free(ranks);
    try expectReportError(ranks, options, error.BoundaryViolation);
}

test "a partial or over-long sample set is refused" {
    const text = try synthReport(testing.allocator, .{ .samples = 3 });
    defer testing.allocator.free(text);

    const two = [_][]const u8{ text, text };
    try testing.expectError(
        error.SampleCountMismatch,
        analyzeSamples(testing.allocator, &two, .{ .samples = 3 }, test_domain),
    );

    var many: [max_comparison_reports + 1][]const u8 = undefined;
    for (&many) |*slot| slot.* = text;
    try testing.expectError(
        error.TooManySamples,
        analyzeSamples(testing.allocator, &many, .{ .samples = many.len }, test_domain),
    );
}

test "work-profile, checksum, and allocation drift between samples is refused" {
    const options: Options = .{ .samples = 2 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    // A capture from another CommonMark revision is not this measurement, so
    // each sample is refused where it happens. The sample comparison never
    // reaches the difference between two pinned captures.
    const off_pin_profile = try replaceLine(
        testing.allocator,
        text,
        line_commonmark_profile,
        "# commonmark_profile=0.30.0",
    );
    defer testing.allocator.free(off_pin_profile);
    const off_pin_pair = [_][]const u8{ text, off_pin_profile };
    try testing.expectError(
        error.ProfileMismatch,
        analyzeSamples(testing.allocator, &off_pin_pair, options, test_domain),
    );

    // The work profile a recording is measured under is a claim about the
    // measured work, and `setup` is compared between samples without being
    // pinned to a constant, so two samples that disagree about it make one
    // recording that is not stable.
    const drifted_setup = try replaceLine(
        testing.allocator,
        text,
        line_setup,
        "# setup=one warm-up iteration shared by every sample",
    );
    defer testing.allocator.free(drifted_setup);
    const setup_pair = [_][]const u8{ text, drifted_setup };
    try testing.expectError(
        error.UnstableResults,
        analyzeSamples(testing.allocator, &setup_pair, options, test_domain),
    );

    const drifted_checksum = try replaceLine(
        testing.allocator,
        text,
        line_row_0,
        "commonmark,cm_blocks,parse,accepted,19,3,1000,5001,4,512",
    );
    defer testing.allocator.free(drifted_checksum);
    const checksum_pair = [_][]const u8{ text, drifted_checksum };
    try testing.expectError(
        error.UnstableResults,
        analyzeSamples(testing.allocator, &checksum_pair, options, test_domain),
    );

    const drifted_allocations = try replaceLine(
        testing.allocator,
        text,
        line_row_0,
        "commonmark,cm_blocks,parse,accepted,19,3,1000,5000,9,512",
    );
    defer testing.allocator.free(drifted_allocations);
    const allocation_pair = [_][]const u8{ text, drifted_allocations };
    try testing.expectError(
        error.UnstableResults,
        analyzeSamples(testing.allocator, &allocation_pair, options, test_domain),
    );

    // An outcome that changes is refused where it happens: every sample is
    // checked against the fixture's oracle, so a drifting outcome can never
    // reach the sample comparison as a mere difference.
    const drifted_outcome = try replaceLine(
        testing.allocator,
        text,
        line_row_1,
        "commonmark,cm_input_limit,resource_error,TooManyNodes,2,3,1007,5002,5,576",
    );
    defer testing.allocator.free(drifted_outcome);
    const outcome_pair = [_][]const u8{ text, drifted_outcome };
    try testing.expectError(
        error.UnexpectedOutcome,
        analyzeSamples(testing.allocator, &outcome_pair, options, test_domain),
    );
}

test "a declared work domain that cannot produce the required rows is refused" {
    const empty_segments = [_]DomainSegment{};
    try expectDomainError(.{ .segments = &empty_segments }, error.DomainSegmentCount);

    const three_segments = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &commonmark_test_fixtures },
        .{ .format = .commonmark, .fixtures = &commonmark_test_fixtures },
        .{ .format = .yaml_extended, .fixtures = &yaml_test_fixtures },
    };
    try expectDomainError(.{ .segments = &three_segments }, error.DomainSegmentCount);

    // YAML may not be enumerated before CommonMark.
    const yaml_first = [_]DomainSegment{
        .{ .format = .yaml_extended, .fixtures = &yaml_test_fixtures },
        .{ .format = .commonmark, .fixtures = &commonmark_test_fixtures },
    };
    try expectDomainError(.{ .segments = &yaml_first }, error.DomainFormatOrder);

    const no_fixtures = [_]Fixture{};
    const empty_fixtures = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &no_fixtures },
    };
    try expectDomainError(.{ .segments = &empty_fixtures }, error.EmptyDomain);

    const duplicated_workload = [_]Fixture{
        commonmark_test_fixtures[0],
        commonmark_test_fixtures[0],
    };
    const duplicate_segments = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &duplicated_workload },
    };
    try expectDomainError(.{ .segments = &duplicate_segments }, error.DuplicateWorkload);

    const no_stage_list = [_]Stage{};
    const no_stages = [_]Fixture{
        .{
            .workload = .cm_blocks,
            .source = cm_blocks_source,
            .stages = &no_stage_list,
            .outcome = contract.accepted_outcome,
        },
    };
    const no_stage_segments = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &no_stages },
    };
    try expectDomainError(.{ .segments = &no_stage_segments }, error.EmptyStageList);

    const repeated_stage = [_]Fixture{
        .{
            .workload = .cm_blocks,
            .source = cm_blocks_source,
            .stages = &.{ .parse, .parse },
            .outcome = contract.accepted_outcome,
        },
    };
    const repeated_stage_segments = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &repeated_stage },
    };
    try expectDomainError(.{ .segments = &repeated_stage_segments }, error.DuplicateStage);

    // An accepted fixture may not declare only a rejection stage.
    const accepted_rejecting = [_]Fixture{
        .{
            .workload = .cm_blocks,
            .source = cm_blocks_source,
            .stages = &.{.reject},
            .outcome = contract.accepted_outcome,
        },
    };
    const accepted_rejecting_segments = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &accepted_rejecting },
    };
    try expectDomainError(.{ .segments = &accepted_rejecting_segments }, error.OutcomeStageMismatch);

    // An error outcome needs exactly the stage that observes it.
    const error_without_stage = [_]Fixture{
        .{
            .workload = .cm_input_limit,
            .source = cm_input_limit_source,
            .stages = &.{ .parse, .resource_error },
            .outcome = "InputTooLarge",
        },
    };
    const error_without_stage_segments = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &error_without_stage },
    };
    try expectDomainError(.{ .segments = &error_without_stage_segments }, error.OutcomeStageMismatch);

    // An outcome that is not one CSV field is not an outcome.
    const padded_outcome = [_]Fixture{
        .{
            .workload = .cm_input_limit,
            .source = cm_input_limit_source,
            .stages = &.{.resource_error},
            .outcome = "InputTooLarge,parse",
        },
    };
    const padded_segments = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &padded_outcome },
    };
    try expectDomainError(.{ .segments = &padded_segments }, error.InvalidOracleOutcome);

    const not_an_error_name = [_]Fixture{
        .{
            .workload = .cm_input_limit,
            .source = cm_input_limit_source,
            .stages = &.{.resource_error},
            .outcome = "19",
        },
    };
    const not_an_error_name_segments = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &not_an_error_name },
    };
    try expectDomainError(.{ .segments = &not_an_error_name_segments }, error.InvalidOracleOutcome);

    // An accepted fixture must be measured on a parse and on complete
    // consumption.
    const parse_only = [_]Fixture{
        .{
            .workload = .cm_blocks,
            .source = cm_blocks_source,
            .stages = &.{.parse},
            .outcome = contract.accepted_outcome,
        },
    };
    const parse_only_segments = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &parse_only },
    };
    try expectDomainError(.{ .segments = &parse_only_segments }, error.MissingAcceptanceStage);

    // An accepted CommonMark fixture is also rendered in safe mode.
    const no_render = [_]Fixture{
        .{
            .workload = .cm_blocks,
            .source = cm_blocks_source,
            .stages = &.{ .parse, .traverse },
            .outcome = contract.accepted_outcome,
        },
    };
    const no_render_segments = [_]DomainSegment{
        .{ .format = .commonmark, .fixtures = &no_render },
    };
    try expectDomainError(.{ .segments = &no_render_segments }, error.MissingRenderStage);

    // The declared domain the controller builds passes every structural check.
    try verifyDomain(test_domain);
}

test "invalid operation lines are refused and no stream knob is accepted" {
    try testing.expectError(error.MissingOperation, parseCommand(&.{}));
    try testing.expectError(error.UnknownOperation, parseCommand(&.{"compare"}));
    try testing.expectError(error.MissingOutputDirectory, parseCommand(&.{"record"}));
    try testing.expectError(error.MissingFlagValue, parseCommand(&.{ "record", "out", "--samples" }));
    try testing.expectError(error.SampleCountOutOfRange, parseCommand(&.{ "record", "out", "--samples", "0" }));
    try testing.expectError(error.SampleCountOutOfRange, parseCommand(&.{ "record", "out", "--samples", "33" }));
    try testing.expectError(error.NotANumber, parseCommand(&.{ "record", "out", "--samples", "many" }));
    try testing.expectError(error.IterationCountOutOfRange, parseCommand(&.{ "record", "out", "--iterations", "0" }));
    try testing.expectError(error.IterationCountOutOfRange, parseCommand(&.{ "record", "out", "--iterations", "64" }));
    try testing.expectError(error.DuplicateFlag, parseCommand(&.{ "record", "out", "--samples", "2", "--samples", "3" }));
    try testing.expectError(error.UnknownFlag, parseCommand(&.{ "record", "out", "--depth", "2" }));
    // There is no stream chunk knob, so the legacy flag is not a no-op here.
    try testing.expectError(error.UnknownFlag, parseCommand(&.{ "record", "out", "--stream-chunk-size", "4096" }));
    try testing.expectError(error.ExtraArguments, parseCommand(&.{"verify"}));
    try testing.expectError(error.ExtraArguments, parseCommand(&.{ "verify", "a", "b" }));
    try testing.expectError(error.ExtraArguments, parseCommand(&.{ "reproduce", "only-one" }));

    const command = try parseCommand(&.{ "record", "out", "--samples", "2", "--iterations", "4" });
    try testing.expectEqualStrings("out", command.record.out_dir);
    try testing.expectEqual(@as(u16, 2), command.record.options.samples);
    try testing.expectEqual(@as(u16, 4), command.record.options.iterations);
    try testing.expect(command.record.options.eql(.{ .samples = 2, .iterations = 4 }));
}

test "a full-width checksum is decoded without narrowing" {
    const options: Options = .{ .samples = 1 };
    const text = try synthReport(testing.allocator, options);
    defer testing.allocator.free(text);

    const wide = try std.fmt.allocPrint(
        testing.allocator,
        "commonmark,cm_blocks,parse,accepted,{d},{d},1000,{d},4,512",
        .{ cm_blocks_source.len, options.iterations, std.math.maxInt(u64) },
    );
    defer testing.allocator.free(wide);

    const patched = try replaceLine(testing.allocator, text, line_row_0, wide);
    defer testing.allocator.free(patched);

    const single = [_][]const u8{patched};
    var analysis = try analyzeSamples(testing.allocator, &single, options, test_domain);
    defer freeAnalysis(testing.allocator, &analysis);
    try testing.expectEqual(std.math.maxInt(u64), analysis.cases[0].stable.checksum);
}

/// The capture is built through `std.Io.Writer.Allocating`, whose writer
/// reports a failed allocation as `error.WriteFailed` because a write can also
/// fail at the sink. This builder writes to memory only, so an allocation
/// failure is the one way it fails, and the failure injection understands
/// `error.OutOfMemory` alone. Restating the builder's failure as the allocation
/// error it is lets the injection reach every allocation a decode makes instead
/// of abandoning the run on the first one inside the builder. No refusal of a
/// decode passes through this mapping.
fn captureForInjection(allocator: Allocator, options: Options) Allocator.Error![]u8 {
    const text = synthReport(allocator, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.OutOfMemory,
    };
    return text;
}

/// A full decode under a failing allocator must release exactly what it had
/// already taken, at every failure point. The capture is built under the same
/// injected allocator, so every allocation the run makes is a failure point,
/// and each one has to surface as the allocation error the decoder and the
/// builder actually return.
fn decodeAndRelease(allocator: Allocator) !void {
    const options: Options = .{ .samples = 1 };
    const text = try captureForInjection(allocator, options);
    defer allocator.free(text);
    const single = [_][]const u8{text};
    var analysis = try analyzeSamples(allocator, &single, options, test_domain);
    freeAnalysis(allocator, &analysis);
}

test "a decode releases what it already took at every allocation failure point" {
    try testing.checkAllAllocationFailures(testing.allocator, decodeAndRelease, .{});
}
