//! Pure report decoding for the local benchmark baseline.
//!
//! This module owns the measured work domain of `bench.zig` and the strict
//! parser that turns one raw `simd-bench` stdout sample into typed records.
//! It performs no I/O and spawns nothing, so the archive runtime in
//! `scripts/benchmark.zig` can be exercised against captured output without
//! a build.
//!
//! The domain is the existing `bench.zig` contract and is not restated here:
//! seven formats x five workloads x six stages is 210 cases over 35 input
//! hashes. Nothing in this module ranks, times, or compares libraries.
const std = @import("std");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Measured work domain.
//
// These mirror the `bench.zig` enumeration names, in the order `bench.zig`
// emits them. The strict parser rejects anything else, so a bench contract
// change surfaces as a validation failure instead of a silently smaller run.
// ---------------------------------------------------------------------------

pub const Format = enum {
    json,
    jsonl,
    jsonc,
    json5,
    markdown,
    xml,
    yaml,

    pub fn fromName(text: []const u8) ?Format {
        inline for (@typeInfo(Format).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

pub const Workload = enum {
    fixture,
    sparse,
    dense,
    escaped,
    unicode,

    pub fn fromName(text: []const u8) ?Workload {
        inline for (@typeInfo(Workload).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

pub const Stage = enum {
    index,
    validate,
    tape,
    stream,
    traverse_all,
    traverse_prefix8,

    pub fn fromName(text: []const u8) ?Stage {
        inline for (@typeInfo(Stage).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

pub const formats = [_]Format{
    .json,
    .jsonl,
    .jsonc,
    .json5,
    .markdown,
    .xml,
    .yaml,
};

pub const workloads = [_]Workload{
    .fixture,
    .sparse,
    .dense,
    .escaped,
    .unicode,
};

pub const stages = [_]Stage{
    .index,
    .validate,
    .tape,
    .stream,
    .traverse_all,
    .traverse_prefix8,
};

pub const input_count = formats.len * workloads.len;
pub const case_count = input_count * stages.len;

// ---------------------------------------------------------------------------
// Option surface and hard bounds.
// ---------------------------------------------------------------------------

pub const min_samples: u16 = 1;
pub const max_samples: u16 = 32;
pub const min_iterations: u16 = 1;
pub const max_iterations: u16 = 32;

const default_samples: u16 = 3;
const default_iterations: u16 = 3;
const default_stream_chunk_size: u32 = 4096;

const supported_chunk_sizes = [_]u32{ 64, 256, 1024, 4096, 16384 };

fn isSupportedChunkSize(value: u32) bool {
    for (supported_chunk_sizes) |candidate| {
        if (candidate == value) return true;
    }
    return false;
}

/// The measured invocation shape. These are the only knobs `record` accepts;
/// every one of them is a bench contract knob, never a local policy knob.
pub const Options = struct {
    samples: u16 = default_samples,
    iterations: u16 = default_iterations,
    stream_chunk_size: u32 = default_stream_chunk_size,

    pub fn eql(left: Options, right: Options) bool {
        return left.samples == right.samples and
            left.iterations == right.iterations and
            left.stream_chunk_size == right.stream_chunk_size;
    }

    pub fn validate(self: Options) OptionsError!void {
        if (self.samples < min_samples or self.samples > max_samples) return error.SampleCountOutOfRange;
        if (self.iterations < min_iterations or self.iterations > max_iterations) return error.IterationCountOutOfRange;
        if (!isSupportedChunkSize(self.stream_chunk_size)) return error.UnsupportedChunkSize;
    }
};

pub const OptionsError = error{
    SampleCountOutOfRange,
    IterationCountOutOfRange,
    UnsupportedChunkSize,
};

/// Bounds on the raw report text. They are fixed so a hostile or corrupt
/// capture cannot make the parser allocate or scan without limit.
pub const max_report_lines: usize = 512;
pub const max_report_line_bytes: usize = 1024;
pub const max_comparison_reports: usize = 64;

/// The exact header line `bench.zig` prints before its rows.
const csv_header =
    "format,workload,stage,input_bytes,iterations,elapsed_ns,checksum,allocation_count,allocated_bytes";
const csv_field_count = 9;
const synthetic_scale: u64 = 64;

/// Every `# key=value` header `bench.zig` prints. An unknown key means the
/// measured contract moved and the archive must not be published as complete.
const known_header_keys = [_][]const u8{
    "zig_version",
    "optimize",
    "target_arch",
    "vector_len",
    "stream_chunk_bytes",
    "stream_chunk_invocation",
    "synthetic_scale",
    "consumption",
    "resident_setup",
    "resident_consumption",
    "traverse_prefix8",
    "baseline",
};

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
    EmptyStdout,
    MissingTrailingNewline,
    UnsupportedLineEnding,
    LineTooLong,
    TooManyLines,
    MissingCsvHeader,
    MissingHeader,
    DuplicateHeader,
    UnknownHeader,
    MalformedHeader,
    MalformedInputDeclaration,
    UnknownFormat,
    UnknownWorkload,
    UnknownStage,
    WrongFieldCount,
    InvalidNumber,
    MissingInputDeclaration,
    DuplicateInputDeclaration,
    TrailingInputDeclaration,
    RowOrderMismatch,
    InconsistentInputBytes,
    WrongIterationCount,
    WrongChunkSize,
    WrongSyntheticScale,
    UnstableResults,
    SampleCountMismatch,
    TooManySamples,
} || Allocator.Error;

pub const usage_text =
    \\usage:
    \\  record OUT_DIR [--samples N] [--iterations N] [--stream-chunk-size N]
    \\  verify ARCHIVE_DIR
    \\  reproduce OLD_ARCHIVE_DIR NEW_ARCHIVE_DIR
    \\
    \\defaults: --samples 3 --iterations 3 --stream-chunk-size 4096
    \\samples and iterations accept 1..32; chunk sizes accept 64, 256, 1024,
    \\4096, or 16384.
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
    comptime low: u16,
    comptime high: u16,
    comptime out_of_range: OptionsError,
    text: []const u8,
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
    var seen_chunk = false;

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
                min_samples,
                max_samples,
                error.SampleCountOutOfRange,
                value,
            );
        } else if (std.mem.eql(u8, flag, "--iterations")) {
            if (seen_iterations) return error.DuplicateFlag;
            seen_iterations = true;
            options.iterations = try parseBoundedCount(
                u16,
                min_iterations,
                max_iterations,
                error.IterationCountOutOfRange,
                value,
            );
        } else if (std.mem.eql(u8, flag, "--stream-chunk-size")) {
            if (seen_chunk) return error.DuplicateFlag;
            seen_chunk = true;
            const chunk = std.fmt.parseUnsigned(u32, value, 10) catch return error.UnsupportedChunkSize;
            if (!isSupportedChunkSize(chunk)) return error.UnsupportedChunkSize;
            options.stream_chunk_size = chunk;
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
// Strict `bench.zig` stdout parsing.
// ---------------------------------------------------------------------------

pub const BenchHeaders = struct {
    zig_version: []const u8,
    optimize: []const u8,
    target_arch: []const u8,
    vector_len: u64,
    stream_chunk_bytes: u64,
    stream_chunk_invocation: []const u8,
    synthetic_scale: u64,
    consumption: []const u8,
    resident_setup: []const u8,
    resident_consumption: []const u8,
    traverse_prefix8: []const u8,
    baseline: []const u8,
};

pub const InputEntry = struct {
    format: Format,
    workload: Workload,
    input_hash: u64,
    input_bytes: u64,
};

/// One measured case as printed by one sample.
pub const CaseRecord = struct {
    format: Format,
    workload: Workload,
    stage: Stage,
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

pub const Report = struct {
    headers: BenchHeaders,
    inputs: [input_count]InputEntry,
    cases: [case_count]CaseRecord,
};

const header_slot_count = known_header_keys.len;

/// A `BenchHeaders` field that owns a copy of one header value, named by the
/// `known_header_keys` slot that value comes from.
const OwnedHeader = struct {
    field: []const u8,
    slot: usize,
};

/// The owning header fields, in slot order. `materializeHeaders` fills them
/// in this order, so a failure releases exactly the copies it already took,
/// and `freeHeaders` walks the same order.
const owned_headers = [_]OwnedHeader{
    .{ .field = "zig_version", .slot = 0 },
    .{ .field = "optimize", .slot = 1 },
    .{ .field = "target_arch", .slot = 2 },
    .{ .field = "stream_chunk_invocation", .slot = 5 },
    .{ .field = "consumption", .slot = 7 },
    .{ .field = "resident_setup", .slot = 8 },
    .{ .field = "resident_consumption", .slot = 9 },
    .{ .field = "traverse_prefix8", .slot = 10 },
    .{ .field = "baseline", .slot = 11 },
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

const input_prefix = "# input ";

fn splitDeclaration(line: []const u8) BenchReportError!InputDeclaration {
    var rest = line[input_prefix.len..];
    const format_text = takeToken(&rest, "format=") orelse return error.MalformedInputDeclaration;
    const workload_text = takeToken(&rest, "workload=") orelse return error.MalformedInputDeclaration;
    const hash_text = takeToken(&rest, "input_hash=") orelse return error.MalformedInputDeclaration;
    if (rest.len != 0) return error.MalformedInputDeclaration;
    const format = Format.fromName(format_text) orelse return error.UnknownFormat;
    const workload = Workload.fromName(workload_text) orelse return error.UnknownWorkload;
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

fn headerSlot(key: []const u8) ?usize {
    for (known_header_keys, 0..) |candidate, index| {
        if (std.mem.eql(u8, key, candidate)) return index;
    }
    return null;
}

/// Parses one complete `bench.zig` stdout sample. Every expectation is
/// checked: the header key set, the CSV header, the canonical row order, the
/// 35 input declarations, the 210 rows, and the per-case option columns.
///
/// The returned `headers` own a copy of every header string, so the caller
/// releases them with `freeHeaders`. `inputs` and `cases` are plain values
/// that borrow nothing from `stdout`.
pub fn parseReport(allocator: Allocator, stdout: []const u8, expected: Options) BenchReportError!Report {
    if (stdout.len == 0) return error.EmptyStdout;
    if (!std.mem.endsWith(u8, stdout, "\n")) return error.MissingTrailingNewline;

    var header_values: [header_slot_count]?[]const u8 = @splat(null);
    var csv_seen = false;
    var input_cursor: usize = 0;
    var stage_cursor: usize = 0;
    var pending: ?InputEntry = null;
    var cases: [case_count]CaseRecord = undefined;
    var inputs: [input_count]InputEntry = undefined;
    var case_count_seen: usize = 0;

    var it = std.mem.splitScalar(u8, stdout, '\n');
    var line_number: usize = 0;
    while (it.next()) |line| {
        if (line_number == max_report_lines) return error.TooManyLines;
        line_number += 1;
        try checkLineShape(line);
        if (line.len == 0) continue;

        if (line[0] == '#') {
            if (std.mem.startsWith(u8, line, input_prefix)) {
                if (pending != null) return error.DuplicateInputDeclaration;
                const declaration = try splitDeclaration(line);
                pending = .{
                    .format = declaration.format,
                    .workload = declaration.workload,
                    .input_hash = declaration.input_hash,
                    .input_bytes = 0,
                };
                continue;
            }
            if (!csv_seen) {
                if (line.len < 3) return error.MalformedHeader;
                const body = line[2..];
                const equals = std.mem.indexOfScalar(u8, body, '=') orelse return error.MalformedHeader;
                const key = body[0..equals];
                const value = body[equals + 1 ..];
                const slot = headerSlot(key) orelse return error.UnknownHeader;
                if (header_values[slot] != null) return error.DuplicateHeader;
                header_values[slot] = value;
                continue;
            }
            // A comment after the CSV header that is not an input declaration
            // means the row stream moved; refuse it rather than skip it.
            return error.MalformedHeader;
        }

        if (!csv_seen) {
            if (!std.mem.eql(u8, line, csv_header)) return error.MissingCsvHeader;
            csv_seen = true;
            continue;
        }

        // A row past the 35 declared inputs cannot match the canonical order,
        // the same defect as a repeated row, and says nothing about how many
        // samples were captured.
        if (input_cursor >= input_count) return error.RowOrderMismatch;
        const expected_format = formats[input_cursor / workloads.len];
        const expected_workload = workloads[input_cursor % workloads.len];
        const expected_stage = stages[stage_cursor];

        var fields: [csv_field_count][]const u8 = undefined;
        if (!splitRow(line, &fields)) return error.WrongFieldCount;

        const row_format = Format.fromName(fields[0]) orelse return error.UnknownFormat;
        const row_workload = Workload.fromName(fields[1]) orelse return error.UnknownWorkload;
        const row_stage = Stage.fromName(fields[2]) orelse return error.UnknownStage;

        const input_bytes = try parseDecimal(u64, fields[3]);
        const iterations = try parseDecimal(u64, fields[4]);
        const elapsed_ns = try parseDecimal(u64, fields[5]);
        const checksum = try parseDecimal(u64, fields[6]);
        const allocation_count = try parseDecimal(u64, fields[7]);
        const allocated_bytes = try parseDecimal(u64, fields[8]);

        if (row_format != expected_format or
            row_workload != expected_workload or
            row_stage != expected_stage)
        {
            return error.RowOrderMismatch;
        }
        if (iterations != expected.iterations) return error.WrongIterationCount;

        if (pending == null) return error.MissingInputDeclaration;
        const input = pending.?;
        if (input.format != row_format or input.workload != row_workload) {
            return error.MissingInputDeclaration;
        }
        if (stage_cursor == 0) {
            inputs[input_cursor] = .{
                .format = input.format,
                .workload = input.workload,
                .input_hash = input.input_hash,
                .input_bytes = input_bytes,
            };
        } else if (inputs[input_cursor].input_bytes != input_bytes) {
            return error.InconsistentInputBytes;
        }

        cases[case_count_seen] = .{
            .format = row_format,
            .workload = row_workload,
            .stage = row_stage,
            .input_hash = input.input_hash,
            .input_bytes = input_bytes,
            .iterations = iterations,
            .elapsed_ns = elapsed_ns,
            .checksum = checksum,
            .allocation_count = allocation_count,
            .allocated_bytes = allocated_bytes,
        };
        case_count_seen += 1;

        stage_cursor += 1;
        if (stage_cursor == stages.len) {
            stage_cursor = 0;
            input_cursor += 1;
            pending = null;
        }
    }

    if (!csv_seen) return error.MissingCsvHeader;
    if (pending != null) return error.TrailingInputDeclaration;
    if (case_count_seen != case_count) return error.MissingInputDeclaration;
    if (input_cursor != input_count) return error.MissingInputDeclaration;

    var headers = try materializeHeaders(allocator, &header_values);
    errdefer freeHeaders(allocator, &headers);
    if (headers.stream_chunk_bytes != expected.stream_chunk_size) return error.WrongChunkSize;
    if (headers.synthetic_scale != synthetic_scale) return error.WrongSyntheticScale;

    return .{ .headers = headers, .inputs = inputs, .cases = cases };
}

/// Copies the header values into owning fields. Every field is filled on its
/// own, so `live` always names exactly the strings that are already owned: a
/// later copy, or a later number, releases that set and nothing else.
fn materializeHeaders(
    allocator: Allocator,
    values: *const [header_slot_count]?[]const u8,
) BenchReportError!BenchHeaders {
    for (values) |value| {
        if (value == null) return error.MissingHeader;
    }
    const slot = struct {
        fn need(slots: *const [header_slot_count]?[]const u8, index: usize) BenchReportError![]const u8 {
            return slots[index] orelse return error.MissingHeader;
        }
    };

    // SAFETY: `live` counts the leading `owned_headers` slots that are already
    // owned, and each of them is assigned before it is read or released.
    var headers: BenchHeaders = undefined;
    var live: usize = 0;
    errdefer freeOwnedHeaders(allocator, &headers, live);
    inline for (owned_headers) |entry| {
        @field(headers, entry.field) = try allocator.dupe(u8, try slot.need(values, entry.slot));
        live += 1;
    }

    headers.vector_len = try parseDecimal(u64, try slot.need(values, 3));
    headers.stream_chunk_bytes = try parseDecimal(u64, try slot.need(values, 4));
    headers.synthetic_scale = try parseDecimal(u64, try slot.need(values, 6));
    return headers;
}

/// Releases the first `live` owning header fields, in `owned_headers` order.
fn freeOwnedHeaders(allocator: Allocator, headers: *const BenchHeaders, live: usize) void {
    inline for (owned_headers, 0..) |entry, index| {
        if (index < live) allocator.free(@field(headers.*, entry.field));
    }
}

/// The merged result of one recording: the 35 declared inputs and the 210
/// cases with every per-sample timing. Callers own the returned memory and
/// free it with `freeAnalysis` and the allocator they passed in.
pub const Analysis = struct {
    headers: BenchHeaders,
    inputs: []InputEntry,
    cases: []MergedCase,
};

/// Parses every sample and proves the recorded work is stable. Only the
/// fields that must not move between samples are compared; `elapsed_ns` is
/// retained per sample and never compared.
///
/// The captured sample count must equal the requested one exactly. A short
/// set is partial evidence, not a smaller measurement, so it is refused the
/// same way an over-long set is.
pub fn analyzeSamples(
    allocator: Allocator,
    stdouts: []const []const u8,
    expected: Options,
) BenchReportError!Analysis {
    if (stdouts.len == 0) return error.EmptyStdout;
    if (stdouts.len > max_comparison_reports) return error.TooManySamples;
    if (stdouts.len != expected.samples) return error.SampleCountMismatch;

    var first = try parseReport(allocator, stdouts[0], expected);
    errdefer freeHeaders(allocator, &first.headers);

    const cases = try allocator.alloc(MergedCase, case_count);
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
        var observed = try parseReport(allocator, sample_stdout, expected);
        defer freeHeaders(allocator, &observed.headers);
        if (!headersEql(first.headers, observed.headers)) return error.UnstableResults;
        for (observed.cases, 0..) |record, index| {
            cases[index].elapsed_ns[sample_index] = record.elapsed_ns;
            if (!caseEql(cases[index].stable, record)) return error.UnstableResults;
        }
        for (observed.inputs, 0..) |record, index| {
            if (!inputEql(first.inputs[index], record)) return error.UnstableResults;
        }
    }

    return .{
        .headers = first.headers,
        .inputs = try allocator.dupe(InputEntry, &first.inputs),
        .cases = cases,
    };
}

/// Every contract and profile header must match. A capture whose measurement
/// profile text differs is not the same measurement.
pub fn headersEql(reference: BenchHeaders, observed: BenchHeaders) bool {
    return std.mem.eql(u8, reference.zig_version, observed.zig_version) and
        std.mem.eql(u8, reference.optimize, observed.optimize) and
        std.mem.eql(u8, reference.target_arch, observed.target_arch) and
        reference.vector_len == observed.vector_len and
        reference.stream_chunk_bytes == observed.stream_chunk_bytes and
        reference.synthetic_scale == observed.synthetic_scale and
        std.mem.eql(u8, reference.stream_chunk_invocation, observed.stream_chunk_invocation) and
        std.mem.eql(u8, reference.consumption, observed.consumption) and
        std.mem.eql(u8, reference.resident_setup, observed.resident_setup) and
        std.mem.eql(u8, reference.resident_consumption, observed.resident_consumption) and
        std.mem.eql(u8, reference.traverse_prefix8, observed.traverse_prefix8) and
        std.mem.eql(u8, reference.baseline, observed.baseline);
}

/// Releases every string `materializeHeaders` duplicated.
pub fn freeHeaders(allocator: Allocator, headers: *BenchHeaders) void {
    freeOwnedHeaders(allocator, headers, owned_headers.len);
    // SAFETY: every owning field was released on the line above. The caller
    // must not read `headers` again, so poisoning the released slices cannot
    // hand back a pointer the allocator no longer owns.
    headers.* = undefined;
}

/// Compares every field that must not move between samples of one recording
/// or between two recordings of the same work. `elapsed_ns` is excluded: a
/// timing is an observation, never an identity.
pub fn caseEql(reference: CaseRecord, observed: CaseRecord) bool {
    return reference.format == observed.format and
        reference.workload == observed.workload and
        reference.stage == observed.stage and
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

/// Releases everything `analyzeSamples` allocated for one merged recording.
pub fn freeAnalysis(allocator: Allocator, analysis: *Analysis) void {
    for (analysis.cases) |merged| allocator.free(merged.elapsed_ns);
    allocator.free(analysis.cases);
    allocator.free(analysis.inputs);
    freeHeaders(allocator, &analysis.headers);
    // SAFETY: every allocation this analysis owned was released above, header
    // strings included. The caller must not read `analysis` again, so the
    // poison marks the record consumed instead of leaving live-looking slices.
    analysis.* = undefined;
}

const testing = std.testing;

fn fillAndReleaseHeaders(allocator: Allocator) !void {
    var values: [header_slot_count]?[]const u8 = undefined;
    for (&values) |*value| value.* = "1";

    var headers = try materializeHeaders(allocator, &values);
    defer freeHeaders(allocator, &headers);
    try testing.expectEqualStrings("1", headers.zig_version);
}

test "a header fill releases what it already took at every failure point" {
    try testing.checkAllAllocationFailures(testing.allocator, fillAndReleaseHeaders, .{});
}
