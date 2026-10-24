//! Portable local benchmark recorder, verifier, and reproducer.
//!
//! `zig build benchmark -- <operation> ...` runs this script with the argv
//! contract the build wires:
//!
//! ```text
//! argv[0] this runner
//! argv[1] the `simd-bench` executable this build produced
//! argv[2] the repository root
//! argv[3] the operation
//! ```
//!
//! ```sh
//! record OUT_DIR [--samples N] [--iterations N] [--stream-chunk-size N]
//! verify ARCHIVE_DIR
//! reproduce OLD_ARCHIVE_DIR NEW_ARCHIVE_DIR
//! ```
//!
//! `verify` is deliberately offline. It re-checks an archive against its own
//! manifest, its own source snapshot, its own copied benchmark artifact, and
//! its own raw sample output, and it reads no current checkout, no compiler,
//! and no CPU state. Only `record` and `reproduce` consume the build-provided
//! paths, and only after the operation is known.
//!
//! Nothing in an archive is ever executed. Every path that arrives inside a
//! manifest is validated as a safe archive-relative path before it reaches the
//! file system, and an archive containing a symlink is rejected outright.
//!
//! Execution identity comes only from the current build: `benchmark_options`
//! plus the two paths the build passes in. An archived command string is never
//! replayed and an archived executable is never run.
//!
//! The measured work domain is the unchanged `bench.zig` contract, decoded by
//! `benchmark_report.zig`: seven formats x five workloads x six stages is 210
//! cases over 35 input hashes. Nothing here ranks results, compares libraries,
//! or reconstructs a historical baseline.
//!
//! # Semantic mode
//!
//! The build compiles this one file twice. `benchmark_options.semantic_mode`
//! says which measurement this compilation speaks; legacy is the default, and
//! every legacy name, flag, option, schema, path, and message above is
//! unchanged by it. The semantic compilation is not a runtime switch a caller
//! can flip: it is the same source compiled again against semantic options.
//!
//! Semantic mode runs the same archive runtime over the CommonMark 0.31.2 and
//! `yaml-extended-e2b-1.2.2` measurement, under `zig build benchmark-semantic`
//! and the same argv contract, with the same three operations and the same
//! samples and iterations bounds. The archive is named
//! `simd-semantic-benchmark-archive`, the captured bench is
//! `bench/simd-semantic-bench`, and the decoder is
//! `semantic_benchmark_report.zig`: the declared fixture list rather than a
//! Cartesian product, an `outcome` per case, and no stream knob at all,
//! because neither semantic parser streams. What both modes share is the
//! archive layout, the exclusive creation rule, the failed-manifest rule, the
//! offline verification, the sampling rules, and the toolchain provenance.
//! What differs is only what the measurement itself differs in.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("benchmark_options");

/// The mode this compilation speaks. The build supplies it, so the two
/// measurements can never decode each other's captures by accident.
const semantic_mode: bool = build_options.semantic_mode;

/// The decoder and command surface of this mode. Both modules answer to the
/// archive runtime with `Options`, `Command`, `BenchHeaders`, `InputEntry`,
/// `CaseRecord`, `MergedCase`, `Analysis`, `parseReport`, `analyzeSamples`,
/// `freeHeaders`, `freeAnalysis`, and `sameAs`; they differ in the work they
/// describe. Every `report.` name below is this mode's module, so the branches
/// that reach for a field only one of them has are explicit.
const semantic_report = @import("semantic_benchmark_report.zig");
const legacy_report = @import("benchmark_report.zig");
const report = if (semantic_mode) semantic_report else legacy_report;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

// ---------------------------------------------------------------------------
// Archive layout and schema.
//
// The layout is fixed so `verify` can enumerate every regular file in the
// archive and require the set to match the manifest exactly.
// ---------------------------------------------------------------------------

const manifest_name = "manifest.json";
const bench_subdir = "bench";
const samples_subdir = "samples";
const sources_subdir = "sources";

/// The captured bench artifact, per mode. An archive is identified by its own
/// schema name, so the two measurements store their own executable under their
/// own path and neither can be verified as the other.
const legacy_bench_archive_path = "bench/simd-bench";
const semantic_bench_archive_path = "bench/simd-semantic-bench";
const bench_archive_path = if (semantic_mode)
    semantic_bench_archive_path
else
    legacy_bench_archive_path;

const legacy_schema_name = "simd-benchmark-archive";
const semantic_schema_name = "simd-semantic-benchmark-archive";
const schema_name = if (semantic_mode)
    semantic_schema_name
else
    legacy_schema_name;

/// The name this compilation reports itself as. The two modes are separate
/// builds with separate executables, so a refusal from the semantic runner must
/// not name the legacy one. The legacy spelling is unchanged.
const program_name = if (semantic_mode) "simd-semantic-benchmark" else "simd-benchmark";

const schema_version: u32 = 1;

const status_complete = "complete";
const status_failed = "failed";

// ---------------------------------------------------------------------------
// The declared semantic work domain.
//
// Legacy mode has no domain value to hold: its 7 x 5 x 6 work is a compile-time
// constant inside its own decoder. Semantic mode decodes against the declared
// fixture list instead, and it must be the same list the semantic controller
// printed, so it is built here from the same two fixture tables: CommonMark
// first, YAML extended second, each in declaration order. The decoder walks
// that order and admits no other row, so the archive can only be verified
// against the contract it was measured under.
//
// Nothing here is resolved in legacy mode: every semantic name sits in the
// branch its mode selects. The fixture tables are data-only modules that
// import `std` and the contract, never a parser, so this archive runtime stays
// parser-free and needs no CPU-dependent library module.
// ---------------------------------------------------------------------------

const semantic_contract = @import("semantic_contract");
const commonmark_fixtures = @import("commonmark_bench_fixtures.zig").fixtures;
const yaml_extended_fixtures = @import("yaml_extended_bench_fixtures.zig").fixtures;

const semantic_segments = if (semantic_mode) [_]report.DomainSegment{
    .{
        .format = .commonmark,
        .fixtures = commonmark_fixtures,
    },
    .{
        .format = .yaml_extended,
        .fixtures = yaml_extended_fixtures,
    },
} else void;

const semantic_domain = if (semantic_mode)
    report.Domain{ .segments = &semantic_segments }
else
    void;

const semantic_input_count: usize = if (semantic_mode)
    semantic_segments[0].fixtures.len + semantic_segments[1].fixtures.len
else
    0;

const semantic_case_count: usize = if (semantic_mode) blk: {
    var total: usize = 0;
    for (semantic_segments) |segment| {
        for (segment.fixtures) |fixture| total += fixture.stages.len;
    }
    break :blk total;
} else 0;

/// The work a manifest of this mode must declare and a capture of this mode
/// must carry: 35 inputs and 210 cases in legacy mode, the declared fixture
/// list and its declared stages in semantic mode.
const expected_work_counts = if (semantic_mode)
    .{ .inputs = semantic_input_count, .cases = semantic_case_count }
else
    .{ .inputs = report.input_count, .cases = report.case_count };

/// Every bound is a literal. No archive, capture, or manifest can make this
/// runner allocate or scan without limit.
const max_stdout_bytes: usize = 16 * 1024 * 1024;
const max_stderr_bytes: usize = 1024 * 1024;
const max_manifest_bytes: usize = 32 * 1024 * 1024;
const max_hashed_file_bytes: usize = 1024 * 1024 * 1024;

/// The only buffer a streamed hash or copy needs, whatever the input is.
const hash_chunk_bytes: usize = 64 * 1024;
const max_source_files: usize = 4096;
const max_archive_files: usize = 32768;
const max_archive_depth: usize = 32;
const max_source_depth: usize = 32;
const max_path_bytes: usize = 512;
const max_path_component_bytes: usize = 255;
const max_text_field_bytes: usize = 4096;
const json_max_depth: usize = 8;
const version_output_bytes: usize = 256;
const proc_text_bytes: usize = 1024 * 1024;
/// One read chunk for a `/proc` file; the file's own size is not consulted.
const proc_chunk_bytes: usize = 64 * 1024;

const ArchiveError = error{
    ArchiveDirectoryUnreadable,
    PathAlreadyExists,
    ManifestUnreadable,
    ManifestInvalid,
    ManifestMissingField,
    ManifestFieldType,
    ManifestSchemaMismatch,
    ManifestIncomplete,
    ManifestFailedStatus,
    UnsafeArchivePath,
    SymlinkInArchive,
    MissingArchiveFile,
    UnexpectedArchiveFile,
    ArchiveEntryExists,
    TooManyArchiveFiles,
    OptionsInvalid,
    SizeMismatch,
    HashMismatch,
    IdentityMismatch,
    BenchExitedNonzero,
    BenchTerminated,
    OutputStreamTooLong,
    SourceTreeChanged,
    SourceTreeEmpty,
    CompareMismatch,
    BenchmarkPathMissing,
    RepositoryRootMissing,
    UnknownHostFact,
    HostFactTooLarge,
    ManifestTooDeep,
    // Directory iteration and formatting can fail on their own; those failures
    // are archive failures, so they travel with the rest of the set instead of
    // being silently dropped at each call site.
    AccessDenied,
    PermissionDenied,
    SystemResources,
    NoSpaceLeft,
    WriteFailed,
    CompilerVersionUnavailable,
} || report.CliError || report.BenchReportError || report.OptionsError ||
    // A filesystem or process failure is an archive failure and keeps its own
    // name: a run that stopped for quota, space, or permission must say which
    // one it was instead of reporting one generic archive fault.
    Io.Dir.OpenError || Io.Dir.CreateDirPathError || Io.Dir.StatFileError ||
    Io.Dir.WriteFileError || Io.Dir.Iterator.Error ||
    Io.File.OpenError || Io.File.Reader.Error || Io.File.Writer.Error ||
    std.process.RunError || Io.UnexpectedError || Io.Cancelable || Allocator.Error;

// ---------------------------------------------------------------------------
// Small shared helpers.
// ---------------------------------------------------------------------------

const hex_digits = "0123456789abcdef";

fn hexOfDigest(digest: [Sha256.digest_length]u8) [64]u8 {
    var out: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        out[index * 2] = hex_digits[byte >> 4];
        out[index * 2 + 1] = hex_digits[byte & 0x0f];
    }
    return out;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return hexOfDigest(digest);
}

const Digest = struct {
    bytes: u64,
    sha256: [64]u8,
};

fn digestOf(bytes: []const u8) Digest {
    return .{ .bytes = bytes.len, .sha256 = sha256Hex(bytes) };
}

/// A running SHA-256 over bytes that arrive in bounded chunks. One place
/// advances the byte count and the digest together, so a streamed hash is the
/// hash of the whole file.
const StreamingDigest = struct {
    hasher: Sha256,
    bytes: u64 = 0,

    fn init() StreamingDigest {
        return .{ .hasher = Sha256.init(.{}) };
    }

    /// Folds one chunk in and returns the total seen so far, so a caller can
    /// charge it against a bound before the chunk is put to use.
    fn update(self: *StreamingDigest, chunk: []const u8) u64 {
        self.hasher.update(chunk);
        self.bytes += chunk.len;
        return self.bytes;
    }

    fn finish(self: *StreamingDigest) Digest {
        return .{ .bytes = self.bytes, .sha256 = hexOfDigest(self.hasher.finalResult()) };
    }
};

/// Trims ASCII whitespace from both ends of a captured text field.
fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn joinPath(allocator: Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts, 0..) |part, index| {
        total += part.len;
        if (index + 1 < parts.len) total += 1;
    }
    var buffer = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    for (parts, 0..) |part, index| {
        @memcpy(buffer[cursor..][0..part.len], part);
        cursor += part.len;
        if (index + 1 < parts.len) {
            buffer[cursor] = '/';
            cursor += 1;
        }
    }
    return buffer;
}

fn sampleName(allocator: Allocator, kind: []const u8, index: u16) ![]u8 {
    return allocator.print("{s}/sample-{d:0>2}.{s}", .{ samples_subdir, index, kind });
}

/// Rejects anything that is not a plain archive-relative file path: no
/// absolute root, no empty or dot component, no `..`, no backslash, no NUL,
/// no colon (a drive prefix has no meaning here and is refused whole), and no
/// component long enough for the kernel to refuse the path with
/// `ENAMETOOLONG` instead of a clean refusal here.
pub fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes) return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    if (std.mem.startsWith(u8, path, "/")) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    var seen = false;
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (component.len > max_path_component_bytes) return false;
        if (std.mem.eql(u8, component, ".")) return false;
        if (std.mem.eql(u8, component, "..")) return false;
        seen = true;
    }
    return seen;
}

// ---------------------------------------------------------------------------
// JSON emission.
//
// The manifest is written by hand so its shape, key order, and formatting are
// fixed by this file rather than by a serializer's defaults.
// ---------------------------------------------------------------------------

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("\"");
    var run_start: usize = 0;
    for (value, 0..) |byte, index| {
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (escape) |text| {
            try writer.writeAll(value[run_start..index]);
            try writer.writeAll(text);
            run_start = index + 1;
        } else if (byte < 0x20) {
            try writer.writeAll(value[run_start..index]);
            try writer.print("\\u{x:0>4}", .{byte});
            run_start = index + 1;
        }
    }
    try writer.writeAll(value[run_start..]);
    try writer.writeAll("\"");
}

const JsonWriter = struct {
    writer: *std.Io.Writer,
    // One flag per level the guard admits. `push` refuses to leave
    // `json_max_depth`, so the deepest reachable level is `json_max_depth`
    // itself and the flag for that level must be addressable.
    nonempty: [json_max_depth + 1]bool = @splat(false),
    depth: usize = 0,
    after_key: bool = false,

    fn push(self: *JsonWriter) ArchiveError!void {
        if (self.depth == json_max_depth) return error.ManifestTooDeep;
        // The flag belongs to the level being entered, so it is cleared after
        // the depth grows. Clearing the parent level instead would drop the
        // separator the parent owes its own next member.
        self.depth += 1;
        self.nonempty[self.depth] = false;
    }

    fn pop(self: *JsonWriter) void {
        self.depth -= 1;
        self.after_key = false;
    }

    fn beforeValue(self: *JsonWriter) !void {
        if (self.after_key) {
            self.after_key = false;
            return;
        }
        if (self.nonempty[self.depth]) try self.writer.writeAll(",");
        self.nonempty[self.depth] = true;
    }

    fn beginObject(self: *JsonWriter) !void {
        try self.beforeValue();
        try self.writer.writeAll("{");
        try self.push();
    }

    fn endObject(self: *JsonWriter) !void {
        self.pop();
        try self.writer.writeAll("}");
    }

    fn beginArray(self: *JsonWriter) !void {
        try self.beforeValue();
        try self.writer.writeAll("[");
        try self.push();
    }

    fn endArray(self: *JsonWriter) !void {
        self.pop();
        try self.writer.writeAll("]");
    }

    fn key(self: *JsonWriter, name: []const u8) !void {
        try self.beforeValue();
        try writeJsonString(self.writer, name);
        try self.writer.writeAll(":");
        self.after_key = true;
    }

    fn string(self: *JsonWriter, value: []const u8) !void {
        try self.beforeValue();
        try writeJsonString(self.writer, value);
    }

    fn uint(self: *JsonWriter, value: u64) !void {
        try self.beforeValue();
        try self.writer.print("{d}", .{value});
    }

    fn rawInt(self: *JsonWriter, value: i128) !void {
        try self.beforeValue();
        try self.writer.print("{d}", .{value});
    }

    fn writeNull(self: *JsonWriter) !void {
        try self.beforeValue();
        try self.writer.writeAll("null");
    }

    fn nullableUint(self: *JsonWriter, value: ?u64) !void {
        try self.beforeValue();
        if (value) |present| {
            try self.writer.print("{d}", .{present});
        } else {
            try self.writer.writeAll("null");
        }
    }
};

// ---------------------------------------------------------------------------
// JSON reading.
//
// Manifest data is data: nothing read here is ever turned into a path that is
// used before `isSafeRelativePath` accepts it.
// ---------------------------------------------------------------------------

const JsonObject = std.json.ObjectMap;

/// Parses one manifest into a document that owns its own strings.
///
/// `alloc_always` copies every value into the parsed document, so a field that
/// is read as a view - a semantic case outcome is the one this runtime keeps
/// - stays valid exactly as long as the `LoadedArchive` that holds it, even
/// though the raw manifest bytes are released as soon as it has loaded.
fn parseJsonDocument(allocator: Allocator, bytes: []const u8) ArchiveError!std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        // The parser copies every value into the caller-supplied allocator, so
        // an exhausted allocator arrives here next to the faults a malformed
        // document produces. It says nothing about the bytes, and a caller
        // that reads `ManifestInvalid` will report a corrupt manifest for a
        // manifest that was never read at all.
        error.OutOfMemory => return error.OutOfMemory,
        // Everything else is the parser refusing these bytes: truncated input,
        // a stray token, a value that does not fit. Those are the manifest's
        // own faults and keep their name.
        else => return error.ManifestInvalid,
    };
}

fn requireObject(value: std.json.Value) ArchiveError!JsonObject {
    return switch (value) {
        .object => |object| object,
        else => error.ManifestInvalid,
    };
}

fn field(object: JsonObject, name: []const u8) ArchiveError!std.json.Value {
    return object.get(name) orelse error.ManifestMissingField;
}

fn fieldString(object: JsonObject, name: []const u8) ArchiveError![]const u8 {
    return switch (try field(object, name)) {
        .string => |text| text,
        else => error.ManifestFieldType,
    };
}

fn fieldUint(object: JsonObject, name: []const u8) ArchiveError!u64 {
    return switch (try field(object, name)) {
        .integer => |value| if (value < 0) error.ManifestFieldType else @intCast(value),
        else => error.ManifestFieldType,
    };
}

fn fieldInt(object: JsonObject, name: []const u8) ArchiveError!i128 {
    return switch (try field(object, name)) {
        .integer => |value| value,
        else => error.ManifestFieldType,
    };
}

fn fieldObject(object: JsonObject, name: []const u8) ArchiveError!JsonObject {
    return switch (try field(object, name)) {
        .object => |nested| nested,
        else => error.ManifestFieldType,
    };
}

fn fieldArray(object: JsonObject, name: []const u8) ArchiveError![]std.json.Value {
    return switch (try field(object, name)) {
        .array => |array| array.items,
        else => error.ManifestFieldType,
    };
}

fn fieldOptionalUint(object: JsonObject, name: []const u8) ArchiveError!?u64 {
    return switch (object.get(name) orelse return error.ManifestMissingField) {
        .null => null,
        .integer => |value| if (value < 0) error.ManifestFieldType else @intCast(value),
        else => error.ManifestFieldType,
    };
}

/// Resolves one enumerated work identity from the name a manifest records.
///
/// Legacy mode reads those names through its decoder's own table. Semantic
/// mode has no such table - its formats are the contract's two profiles rather
/// than seven file formats - so it resolves a name the way the semantic
/// decoder resolves a report row: the exact field name, or nothing.
fn enumFromName(comptime T: type, text: []const u8) ?T {
    inline for (@typeInfo(T).@"enum".field_names) |name| {
        if (std.mem.eql(u8, text, name)) return @field(T, name);
    }
    return null;
}

fn fieldFormat(object: JsonObject, name: []const u8) ArchiveError!report.Format {
    const text = try fieldString(object, name);
    if (comptime semantic_mode) {
        return enumFromName(report.Format, text) orelse error.ManifestFieldType;
    }
    return report.Format.fromName(text) orelse error.ManifestFieldType;
}

fn fieldWorkload(object: JsonObject, name: []const u8) ArchiveError!report.Workload {
    const text = try fieldString(object, name);
    if (comptime semantic_mode) {
        return enumFromName(report.Workload, text) orelse error.ManifestFieldType;
    }
    return report.Workload.fromName(text) orelse error.ManifestFieldType;
}

fn fieldStage(object: JsonObject, name: []const u8) ArchiveError!report.Stage {
    const text = try fieldString(object, name);
    if (comptime semantic_mode) {
        return enumFromName(report.Stage, text) orelse error.ManifestFieldType;
    }
    return report.Stage.fromName(text) orelse error.ManifestFieldType;
}

// ---------------------------------------------------------------------------
// Bounded file access.
//
// Archived bytes are reached only through a handle that was proved to be a
// regular file, so a symlink, FIFO, or device inside an archive can neither be
// followed out of the archive nor block a run. Checkout paths, which come from
// the build and never from an archive, are opened directly and streamed.
// ---------------------------------------------------------------------------

fn readFileBounded(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    limit: usize,
) ArchiveError![]u8 {
    const bytes = dir.readFileAlloc(io, sub_path, allocator, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.OutputStreamTooLong,
        else => return err,
    };
    return bytes;
}

/// Opens `sub_path` only when it names a regular file, both before the open
/// and on the resulting handle.
fn openRegularFile(io: Io, dir: Io.Dir, sub_path: []const u8) ArchiveError!Io.File {
    const before = dir.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.MissingArchiveFile,
        else => return err,
    };
    switch (before.kind) {
        .file => {},
        .sym_link => return error.SymlinkInArchive,
        else => return error.UnexpectedArchiveFile,
    }

    var file = dir.openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.MissingArchiveFile,
        else => return err,
    };
    errdefer file.close(io);

    const opened = try file.stat(io);
    switch (opened.kind) {
        .file => {},
        .sym_link => return error.SymlinkInArchive,
        else => return error.UnexpectedArchiveFile,
    }
    return file;
}

fn readFileHandle(allocator: Allocator, io: Io, file: *Io.File, limit: usize) ArchiveError![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.OutputStreamTooLong,
        error.ReadFailed => return reader.err orelse error.ArchiveDirectoryUnreadable,
    };
}

/// Reads one archived file through a validated handle.
fn readArchived(allocator: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, limit: usize) ArchiveError![]u8 {
    var file = try openRegularFile(io, dir, sub_path);
    defer file.close(io);
    return readFileHandle(allocator, io, &file, limit);
}

fn digestArchived(io: Io, dir: Io.Dir, sub_path: []const u8, limit: usize) ArchiveError!Digest {
    var file = try openRegularFile(io, dir, sub_path);
    defer file.close(io);
    return streamDigest(io, &file, null, limit);
}

/// Hashes one open file while optionally streaming it into `sink`, in a single
/// pass through one fixed stack buffer. Nothing proportional to the input is
/// ever allocated, so `zig_exe` and the benchmark artifact cost the same
/// memory as a source file, and the byte count and SHA-256 are exactly what
/// hashing the whole file at once would produce.
fn streamDigest(io: Io, file: *Io.File, sink: ?*Io.File, limit: usize) ArchiveError!Digest {
    var chunk: [hash_chunk_bytes]u8 = undefined;
    // An empty reader buffer hands `chunk` to the file itself, so every byte is
    // folded into the hash from exactly where the file wrote it.
    var reader = file.reader(io, &.{});
    var digest = StreamingDigest.init();
    while (true) {
        const taken = reader.interface.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse error.ArchiveDirectoryUnreadable,
        };
        if (taken == 0) break;
        if (digest.update(chunk[0..taken]) > limit) return error.OutputStreamTooLong;
        if (sink) |destination| try destination.writeStreamingAll(io, chunk[0..taken]);
    }
    return digest.finish();
}

/// Hashes one checkout file by streaming it, so the size of the file never
/// decides how much memory the run needs.
fn hashFileIn(io: Io, dir: Io.Dir, sub_path: []const u8, limit: usize) ArchiveError!Digest {
    var file = try dir.openFile(io, sub_path, .{ .allow_directory = false });
    defer file.close(io);
    return streamDigest(io, &file, null, limit);
}

fn writeExclusive(io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) ArchiveError!void {
    dir.writeFile(io, .{
        .sub_path = sub_path,
        .data = data,
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ArchiveEntryExists,
        else => return err,
    };
}

fn copyIntoArchive(
    io: Io,
    source: Io.Dir,
    source_path: []const u8,
    archive: Io.Dir,
    archive_path: []const u8,
    limit: usize,
) ArchiveError!Digest {
    if (!isSafeRelativePath(archive_path)) return error.UnsafeArchivePath;
    if (std.fs.path.dirname(archive_path)) |parent| {
        if (parent.len != 0) try archive.createDirPath(io, parent);
    }

    var input = try source.openFile(io, source_path, .{ .allow_directory = false });
    defer input.close(io);

    var output = archive.createFile(io, archive_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ArchiveEntryExists,
        else => return err,
    };
    // `streamDigest` writes through the borrowed sink and never closes it, so
    // this function owns the handle on every exit including the success one.
    defer output.close(io);

    return streamDigest(io, &input, &output, limit);
}

/// Creates the archive directory, creating missing parents but the leaf
/// exclusively, and returns an open handle to it. Every component is proved to
/// be a real directory, so no part of the requested path can be a symlink, and
/// an existing leaf is a failure before a single archive byte is written.
fn createArchiveDirExclusive(io: Io, path: []const u8) ArchiveError!Io.Dir {
    if (path.len == 0 or path.len > max_path_bytes) return error.MissingOutputDirectory;
    if (path[path.len - 1] == std.fs.path.sep) return error.MissingOutputDirectory;

    const absolute = std.fs.path.isAbsolute(path);
    var parts: [max_archive_depth][]const u8 = undefined;
    var count: usize = 0;
    var saw_root = !absolute;
    var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (components.next()) |component| {
        if (component.len == 0) {
            if (!saw_root) {
                saw_root = true;
                continue;
            }
            return error.MissingOutputDirectory;
        }
        if (std.mem.eql(u8, component, ".")) return error.MissingOutputDirectory;
        if (std.mem.eql(u8, component, "..")) return error.UnsafeArchivePath;
        if (count == max_archive_depth) return error.TooManyArchiveFiles;
        parts[count] = component;
        count += 1;
    }
    if (count == 0) return error.MissingOutputDirectory;

    var current: Io.Dir = if (absolute)
        Io.Dir.openDirAbsolute(io, "/", .{ .iterate = true }) catch return error.MissingOutputDirectory
    else
        Io.Dir.cwd();
    errdefer if (absolute) current.close(io);

    for (parts[0..count], 0..) |component, index| {
        const is_leaf = index + 1 == count;
        const existing = current.statFile(io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => return err,
        };
        if (existing) |stat| {
            if (stat.kind != .directory) {
                // A pre-existing ancestor may be a symlink to a directory, which
                // is an ordinary filesystem shape, so it resolves and must still
                // lead to a directory. The leaf may not resolve at all: an
                // existing archive is a failure, never a target to write into.
                const resolved = current.statFile(io, component, .{ .follow_symlinks = true }) catch
                    return error.MissingOutputDirectory;
                if (resolved.kind != .directory) return error.MissingOutputDirectory;
            }
            if (is_leaf) return error.PathAlreadyExists;
        } else {
            current.createDir(io, component, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => return error.PathAlreadyExists,
                else => return err,
            };
        }

        const next = current.openDir(io, component, .{ .iterate = true }) catch
            return error.MissingOutputDirectory;
        if (absolute or index > 0) current.close(io);
        current = next;
    }
    return current;
}

/// Opens an archive for reading. The path may be relative or absolute; it
/// comes from the command line, never from an archived value.
fn openArchiveDir(io: Io, path: []const u8) ArchiveError!Io.Dir {
    const dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch
        return error.ArchiveDirectoryUnreadable;
    errdefer dir.close(io);
    const stat = dir.stat(io) catch return error.ArchiveDirectoryUnreadable;
    if (stat.kind == .sym_link) return error.SymlinkInArchive;
    if (stat.kind != .directory) return error.ArchiveDirectoryUnreadable;
    return dir;
}

// ---------------------------------------------------------------------------
// Ordered file sets.
// ---------------------------------------------------------------------------

fn findInsertIndex(items: []const []const u8, value: []const u8) usize {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (std.mem.lessThan(u8, items[middle], value)) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

fn insertSorted(
    allocator: Allocator,
    items: *std.ArrayList([]const u8),
    value: []const u8,
) Allocator.Error!void {
    const index = findInsertIndex(items.items, value);
    try items.insert(allocator, index, value);
}

/// Collects every regular file in an archive, rejecting symlinks and any
/// entry that is not a plain file. Every entry is charged against the budget
/// before it is opened, directories included, and nesting is depth-bounded, so
/// a tree of empty directories cannot walk for free. The result is sorted
/// repository-style so two archives of the same tree compare by content alone.
fn collectArchiveFiles(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    prefix: []const u8,
    depth: usize,
    out: *std.ArrayList([]const u8),
    budget: *usize,
) ArchiveError!void {
    if (depth > max_archive_depth) return error.TooManyArchiveFiles;

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (entry.kind == .sym_link) return error.SymlinkInArchive;

        if (budget.* == 0) return error.TooManyArchiveFiles;
        budget.* -= 1;

        const child = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try allocator.print("{s}/{s}", .{ prefix, entry.name });
        if (child.len > max_path_bytes or !isSafeRelativePath(child)) {
            allocator.free(child);
            return error.UnsafeArchivePath;
        }

        if (entry.kind == .directory) {
            const sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch {
                allocator.free(child);
                return error.ArchiveDirectoryUnreadable;
            };
            collectArchiveFiles(allocator, io, sub, child, depth + 1, out, budget) catch |err| {
                sub.close(io);
                allocator.free(child);
                return err;
            };
            sub.close(io);
            allocator.free(child);
            continue;
        }

        if (entry.kind != .file and entry.kind != .unknown) {
            allocator.free(child);
            return error.UnexpectedArchiveFile;
        }
        if (out.items.len + 1 > max_archive_files) {
            allocator.free(child);
            return error.TooManyArchiveFiles;
        }
        try insertSorted(allocator, out, child);
    }
}

// ---------------------------------------------------------------------------
// Source snapshot.
// ---------------------------------------------------------------------------

const SourceEntry = struct {
    path: []const u8,
    bytes: u64,
    sha256: [64]u8,
};

/// The source that determines the measured artifact: the build graph, the
/// benchmark entry point, the decoder module, the library sources, and the
/// fixtures the measured bench embeds. Documentation, caches, and results are
/// not measured input and are never captured.
///
/// Semantic mode captures the source of its own measurement: the semantic
/// bench entry point, the semantic decoder and contract, and the two fixture
/// modules whose tables are the measured corpus. The legacy bench and its
/// corpus fixtures are not input to that measurement and are not captured
/// under it, and a legacy archive keeps exactly the list it always had.
const fixed_source_files = if (semantic_mode) [_][]const u8{
    "build.zig",
    "build.zig.zon",
    "semantic_bench.zig",
    "scripts/benchmark.zig",
    "scripts/commonmark_bench.zig",
    "scripts/commonmark_bench_fixtures.zig",
    "scripts/semantic_benchmark_report.zig",
    "scripts/semantic_contract.zig",
    "scripts/yaml_extended_bench.zig",
    "scripts/yaml_extended_bench_fixtures.zig",
} else [_][]const u8{
    "build.zig",
    "build.zig.zon",
    "bench.zig",
    "scripts/benchmark.zig",
    "scripts/benchmark_report.zig",
    "test/corpus/json/example_config.json",
    "test/corpus/jsonc/config.jsonc",
    "test/corpus/json5/sample.json5",
    "test/corpus/jsonl/amazon_cellphones.ndjson",
    "test/corpus/markdown/document.md",
    "test/corpus/xml/catalog.xml",
    "test/corpus/yaml/basic.yaml",
};

const library_source_dir = "src";
const zig_suffix = ".zig";

/// Joins a repository-relative directory with one entry name, inserting
/// exactly one separator. The recursion relies on this: a nested library
/// directory must stay reachable as `src/core/simd.zig`, not collapse to
/// `src/coresimd.zig`.
fn joinRelative(allocator: Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return allocator.print("{s}/{s}", .{ prefix, name });
}

fn collectLibrarySources(
    allocator: Allocator,
    io: Io,
    repo: Io.Dir,
    relative_dir: []const u8,
    depth: usize,
    out: *std.ArrayList([]const u8),
) ArchiveError!void {
    // Breadth is bounded by `max_source_files`; depth is bounded here so a deep
    // chain of directories cannot walk for free.
    if (depth > max_source_depth or out.items.len > max_source_files) {
        return error.TooManyArchiveFiles;
    }
    const current = repo.openDir(io, relative_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.ArchiveDirectoryUnreadable,
        else => return err,
    };
    defer current.close(io);

    var iterator = current.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (entry.kind == .sym_link) return error.SymlinkInArchive;
        const child = try joinRelative(allocator, relative_dir, entry.name);
        if (child.len > max_path_bytes or !isSafeRelativePath(child)) {
            allocator.free(child);
            return error.UnsafeArchivePath;
        }
        if (entry.kind == .directory) {
            try collectLibrarySources(allocator, io, repo, child, depth + 1, out);
            allocator.free(child);
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, zig_suffix)) {
            allocator.free(child);
            continue;
        }
        if (out.items.len + 1 > max_source_files) {
            allocator.free(child);
            return error.TooManyArchiveFiles;
        }
        try insertSorted(allocator, out, child);
    }
}

fn collectSourcePaths(allocator: Allocator, io: Io, repo: Io.Dir) ArchiveError![]SourceEntry {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    for (fixed_source_files) |path| {
        try insertSorted(allocator, &paths, try allocator.dupe(u8, path));
    }
    try collectLibrarySources(allocator, io, repo, library_source_dir, 0, &paths);

    if (paths.items.len == 0) return error.SourceTreeEmpty;
    if (paths.items.len > max_source_files) return error.TooManyArchiveFiles;

    const entries = try allocator.alloc(SourceEntry, paths.items.len);
    errdefer allocator.free(entries);
    for (paths.items, 0..) |path, index| {
        const digest = try hashFileIn(io, repo, path, max_hashed_file_bytes);
        entries[index] = .{
            .path = try allocator.dupe(u8, path),
            .bytes = digest.bytes,
            .sha256 = digest.sha256,
        };
    }
    return entries;
}

fn sourceIdentityDigest(entries: []const SourceEntry) [64]u8 {
    var hasher = Sha256.init(.{});
    for (entries) |entry| {
        hasher.update(entry.path);
        hasher.update("\n");
        hasher.update(&entry.sha256);
        hasher.update("\n");
    }
    return hexOfDigest(hasher.finalResult());
}

fn sourcesEql(left: []const SourceEntry, right: []const SourceEntry) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path)) return false;
        if (a.bytes != b.bytes) return false;
        if (!std.mem.eql(u8, &a.sha256, &b.sha256)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Timestamps.
// ---------------------------------------------------------------------------

const CivilDate = struct { year: i64, month: u32, day: u32 };

fn civilFromDays(days_since_epoch: i64) CivilDate {
    const z = days_since_epoch + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const day_of_era = z - era * 146097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096),
        365,
    );
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * shifted_month + 2, 5) + 1;
    const month = if (shifted_month < 10) shifted_month + 3 else shifted_month - 9;
    const year = year_of_era + era * 400 + @as(i64, @intFromBool(month <= 2));
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

/// Formats the recording time as UTC. Every field is printed as an unsigned
/// integer, so the zero padding is digits and never a sign.
fn formatUtc(allocator: Allocator, io: Io) !struct { unix_ns: i128, text: []u8 } {
    const nanoseconds: i128 = @intCast(Io.Timestamp.now(io, .real).nanoseconds);
    const seconds = @divFloor(nanoseconds, 1_000_000_000);
    const days = @divFloor(seconds, 86_400);
    const seconds_of_day: u64 = @intCast(seconds - days * 86_400);
    const date = civilFromDays(std.math.cast(i64, days) orelse return error.InvalidNumber);
    const year: u64 = @intCast(date.year);
    const hour = seconds_of_day / 3600;
    const minute = (seconds_of_day - hour * 3600) / 60;
    const second = seconds_of_day - hour * 3600 - minute * 60;
    const text = try allocator.print(
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ year, date.month, date.day, hour, minute, second },
    );
    return .{ .unix_ns = nanoseconds, .text = text };
}

// ---------------------------------------------------------------------------
// Host and environment identity.
//
// Static identity is what preflight compares. Frequency and process counters
// move on every run and are recorded as observations that are never compared.
// ---------------------------------------------------------------------------

const HostFacts = struct {
    os: []const u8,
    arch: []const u8,
    cpu_model: []const u8,
    cpu_vendor: []const u8,
    cpu_features: []const u8,
    cpu_processors: u64,
    cpus_allowed_list: []const u8,
    affinity_ranges: []const u8,
    affinity_cpu_count: u64,
    cpu_mhz_observed: ?u64,
};

const EnvironmentFacts = struct {
    lang: ?[]const u8,
    lc_all: ?[]const u8,
    tz: ?[]const u8,

    fn eql(left: EnvironmentFacts, right: EnvironmentFacts) bool {
        return optionalEql(left.lang, right.lang) and
            optionalEql(left.lc_all, right.lc_all) and
            optionalEql(left.tz, right.tz);
    }
};

fn optionalEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn collectEnvironment(environ: ?*std.process.Environ.Map) EnvironmentFacts {
    const map = environ orelse return .{ .lang = null, .lc_all = null, .tz = null };
    return .{
        .lang = map.get("LANG"),
        .lc_all = map.get("LC_ALL"),
        .tz = map.get("TZ"),
    };
}

/// Returns the trimmed value of the first `key : value` record in a
/// `/proc`-style text file, or null when the host does not publish one.
fn firstProcValue(allocator: Allocator, text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = trim(line[0..colon]);
        if (!std.mem.eql(u8, name, key)) continue;
        const value = trim(line[colon + 1 ..]);
        if (value.len > max_text_field_bytes) return null;
        return allocator.dupe(u8, value) catch null;
    }
    return null;
}

fn countProcRecords(text: []const u8, key: []const u8) u64 {
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, trim(line[0..colon]), key)) count += 1;
    }
    return count;
}

const Affinity = struct {
    ranges: []u8,
    count: u64,
};

fn formatCpuRanges(allocator: Allocator, cpus: []const u64) !Affinity {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < cpus.len) {
        var last = index;
        while (last + 1 < cpus.len and cpus[last + 1] == cpus[last] + 1) last += 1;
        if (index != 0) try out.append(allocator, ',');
        if (last == index) {
            try out.print(allocator, "{d}", .{cpus[index]});
        } else {
            try out.print(allocator, "{d}-{d}", .{ cpus[index], cpus[last] });
        }
        index = last + 1;
    }
    return .{ .ranges = try out.toOwnedSlice(allocator), .count = cpus.len };
}

fn readAffinity(allocator: Allocator) ArchiveError!Affinity {
    switch (builtin.os.tag) {
        .linux => {
            const set = std.posix.sched_getaffinity(0) catch return error.UnknownHostFact;
            var cpus: std.ArrayList(u64) = .empty;
            defer cpus.deinit(allocator);
            for (set, 0..) |word, word_index| {
                var bit: usize = 0;
                while (bit < @bitSizeOf(usize)) : (bit += 1) {
                    if (word & (@as(usize, 1) << @intCast(bit)) == 0) continue;
                    try cpus.append(allocator, @as(u64, word_index) * 64 + @as(u64, @intCast(bit)));
                }
            }
            if (cpus.items.len == 0) return error.UnknownHostFact;
            return formatCpuRanges(allocator, cpus.items);
        },
        else => return error.UnknownHostFact,
    }
}

/// Reads a `/proc` text file through `open` and `read`.
///
/// The `Io` layer submits reads asynchronously, which procfs does not answer:
/// a `/proc` handle opens and stats as a regular empty file and reads back zero
/// bytes. Host identity therefore comes from the blocking syscalls directly,
/// streamed into one owned buffer that `limit` bounds.
fn readProcFile(allocator: Allocator, path: []const u8, limit: usize) ArchiveError![]u8 {
    if (builtin.os.tag != .linux) return error.UnknownHostFact;
    if (path.len >= max_path_bytes) return error.UnknownHostFact;
    var terminated: [max_path_bytes:0]u8 = undefined;
    @memcpy(terminated[0..path.len], path);
    terminated[path.len] = 0;

    const fd = std.posix.openatZ(
        std.posix.AT.FDCWD,
        &terminated,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    ) catch return error.UnknownHostFact;
    defer _ = std.posix.system.close(fd);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [proc_chunk_bytes]u8 = undefined;
    while (true) {
        const taken = std.posix.read(fd, &chunk) catch return error.UnknownHostFact;
        if (taken == 0) break;
        if (out.items.len + taken > limit) return error.HostFactTooLarge;
        try out.appendSlice(allocator, chunk[0..taken]);
    }
    return out.toOwnedSlice(allocator);
}

fn collectHostFacts(allocator: Allocator) ArchiveError!HostFacts {
    const affinity = try readAffinity(allocator);
    errdefer allocator.free(affinity.ranges);

    if (builtin.os.tag != .linux) return error.UnknownHostFact;
    const cpuinfo = try readProcFile(allocator, "/proc/cpuinfo", proc_text_bytes);
    defer allocator.free(cpuinfo);
    const status = try readProcFile(allocator, "/proc/self/status", proc_text_bytes);
    defer allocator.free(status);
    const model = firstProcValue(allocator, cpuinfo, "model name") orelse return error.UnknownHostFact;
    errdefer allocator.free(model);
    const vendor = firstProcValue(allocator, cpuinfo, "vendor_id") orelse return error.UnknownHostFact;
    errdefer allocator.free(vendor);
    const features = firstProcValue(allocator, cpuinfo, "flags") orelse return error.UnknownHostFact;
    errdefer allocator.free(features);
    const allowed = firstProcValue(allocator, status, "Cpus_allowed_list") orelse return error.UnknownHostFact;
    errdefer allocator.free(allowed);
    const mhz_text = firstProcValue(allocator, cpuinfo, "cpu MHz");
    const mhz_observed: ?u64 = if (mhz_text) |text|
        std.fmt.parseUnsigned(u64, text, 10) catch null
    else
        null;
    if (mhz_text) |text| allocator.free(text);

    return .{
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .cpu_model = model,
        .cpu_vendor = vendor,
        .cpu_features = features,
        .cpu_processors = countProcRecords(cpuinfo, "processor"),
        .cpus_allowed_list = allowed,
        .affinity_ranges = affinity.ranges,
        .affinity_cpu_count = affinity.count,
        .cpu_mhz_observed = mhz_observed,
    };
}

/// The static half of host identity. Frequencies and process counters are
/// deliberately absent: they are observations, not identity.
fn hostIdentityEql(left: HostFacts, right: HostFacts) bool {
    return std.mem.eql(u8, left.os, right.os) and
        std.mem.eql(u8, left.arch, right.arch) and
        std.mem.eql(u8, left.cpu_model, right.cpu_model) and
        std.mem.eql(u8, left.cpu_vendor, right.cpu_vendor) and
        std.mem.eql(u8, left.cpu_features, right.cpu_features) and
        left.affinity_cpu_count == right.affinity_cpu_count and
        std.mem.eql(u8, left.affinity_ranges, right.affinity_ranges);
}

// ---------------------------------------------------------------------------
// Toolchain identity.
// ---------------------------------------------------------------------------

const ToolchainFacts = struct {
    zig_basename: []const u8,
    zig_version: []const u8,
    zig_sha256: [64]u8,
    zig_bytes: u64,
    bench_target: []const u8,
    bench_cpu: []const u8,
    bench_optimize: []const u8,
    bench_vector_len: ?u64,

    fn eql(left: ToolchainFacts, right: ToolchainFacts) bool {
        return std.mem.eql(u8, left.zig_basename, right.zig_basename) and
            std.mem.eql(u8, left.zig_version, right.zig_version) and
            std.mem.eql(u8, &left.zig_sha256, &right.zig_sha256) and
            std.mem.eql(u8, left.bench_target, right.bench_target) and
            std.mem.eql(u8, left.bench_cpu, right.bench_cpu) and
            std.mem.eql(u8, left.bench_optimize, right.bench_optimize) and
            (left.bench_vector_len == null) == (right.bench_vector_len == null) and
            (left.bench_vector_len orelse 0) == (right.bench_vector_len orelse 0);
    }
};

fn collectToolchain(allocator: Allocator, io: Io) ArchiveError!ToolchainFacts {
    const zig_exe = build_options.zig_exe;
    if (zig_exe.len == 0) return error.BenchmarkPathMissing;
    const basename = std.fs.path.basename(zig_exe);
    if (basename.len == 0) return error.BenchmarkPathMissing;

    const digest = try hashFileIn(io, Io.Dir.cwd(), zig_exe, max_hashed_file_bytes);

    const version = std.process.run(allocator, io, .{
        .argv = &.{ zig_exe, "version" },
        .stdout_limit = .limited(version_output_bytes),
        .stderr_limit = .limited(version_output_bytes),
        .reserve_amount = version_output_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.OutputStreamTooLong,
        else => return err,
    };
    defer allocator.free(version.stdout);
    defer allocator.free(version.stderr);

    // Text on stdout is toolchain identity only when the compiler itself ran to
    // a clean exit. A version line printed before a crash is not a version.
    switch (version.term) {
        .exited => |code| {
            if (code != 0) return error.CompilerVersionUnavailable;
        },
        else => return error.CompilerVersionUnavailable,
    }

    const text = trim(version.stdout);
    if (text.len == 0 or text.len > max_text_field_bytes) return error.CompilerVersionUnavailable;

    const vector_len: ?u64 = if (build_options.bench_vector_len) |width| @intCast(width) else null;

    // Every allocation is bound and given an errdefer before the struct is
    // built: `errdefer` cannot appear inside a struct literal, so a field
    // filled by a later `try` would otherwise leak the memory an earlier one
    // already took when it failed.
    const zig_basename = try allocator.dupe(u8, basename);
    errdefer allocator.free(zig_basename);
    const zig_version = try allocator.dupe(u8, text);
    errdefer allocator.free(zig_version);
    const bench_target = try allocator.dupe(u8, build_options.bench_target);
    errdefer allocator.free(bench_target);
    const bench_cpu = try allocator.dupe(u8, build_options.bench_cpu);
    errdefer allocator.free(bench_cpu);
    const bench_optimize = try allocator.dupe(u8, build_options.bench_optimize);
    errdefer allocator.free(bench_optimize);

    return .{
        .zig_basename = zig_basename,
        .zig_version = zig_version,
        .zig_sha256 = digest.sha256,
        .zig_bytes = digest.bytes,
        .bench_target = bench_target,
        .bench_cpu = bench_cpu,
        .bench_optimize = bench_optimize,
        .bench_vector_len = vector_len,
    };
}

fn hexOf(value: u64) [16]u8 {
    var out: [16]u8 = undefined;
    for (&out, 0..) |*byte, index| {
        byte.* = hex_digits[(value >> @intCast((15 - index) * 4)) & 0x0f];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Manifest model.
// // ---------------------------------------------------------------------------

const TermKind = enum {
    exited,
    signal,
    stopped,

    fn name(self: TermKind) []const u8 {
        return @tagName(self);
    }

    fn fromName(text: []const u8) ?TermKind {
        inline for (@typeInfo(TermKind).@"enum".field_names) |field_name| {
            if (std.mem.eql(u8, text, field_name)) return @field(TermKind, field_name);
        }
        return null;
    }
};

const SampleRecord = struct {
    index: u16,
    stdout_path: []const u8,
    stdout_bytes: u64,
    stdout_sha256: [64]u8,
    stderr_path: []const u8,
    stderr_bytes: u64,
    stderr_sha256: [64]u8,
    term_kind: TermKind,
    term_value: u64,
};

const Manifest = struct {
    status: []const u8,
    reason: []const u8,
    created_unix_ns: i128,
    created_utc: []const u8,
    options: report.Options,
    toolchain: ToolchainFacts,
    host: HostFacts,
    environment: EnvironmentFacts,
    sources: []SourceEntry,
    source_identity: [64]u8,
    bench: Digest,
    samples: []SampleRecord,
    analysis: ?report.Analysis,
};

fn writeNullableText(json: *JsonWriter, value: ?[]const u8) !void {
    try json.beforeValue();
    if (value) |text| {
        try writeJsonString(json.writer, text);
    } else {
        try json.writer.writeAll("null");
    }
}

fn writeDigestFields(json: *JsonWriter, digest: Digest) !void {
    try json.key("bytes");
    try json.uint(digest.bytes);
    try json.key("sha256");
    try json.string(&digest.sha256);
}

fn writeManifest(json: *JsonWriter, manifest: *const Manifest) !void {
    try json.beginObject();

    try json.key("schema");
    try json.string(schema_name);
    try json.key("schema_version");
    try json.uint(schema_version);
    try json.key("status");
    try json.string(manifest.status);
    try json.key("reason");
    try json.string(manifest.reason);
    try json.key("created_unix_ns");
    try json.rawInt(manifest.created_unix_ns);
    try json.key("created_utc");
    try json.string(manifest.created_utc);

    try json.key("options");
    try json.beginObject();
    try json.key("samples");
    try json.uint(manifest.options.samples);
    try json.key("iterations");
    try json.uint(manifest.options.iterations);
    if (comptime semantic_mode) {
        // There is no stream chunk knob in semantic mode, so there is nothing
        // to record. A default under that key would claim a knob the runtime
        // does not accept and the measurement does not have.
        try json.endObject();
    } else {
        try json.key("stream_chunk_size");
        try json.uint(manifest.options.stream_chunk_size);
        try json.endObject();
    }

    try json.key("work");
    try json.beginObject();
    if (comptime semantic_mode) {
        // The declared work, not a product of three axes: one entry per
        // format, with the fixtures it declares and the cases those fixtures
        // declare. A stage a fixture does not declare has no row here either.
        try json.key("segments");
        try json.beginArray();
        for (semantic_domain.segments) |segment| {
            var cases: usize = 0;
            for (segment.fixtures) |fixture| cases += fixture.stages.len;
            try json.beginObject();
            try json.key("format");
            try json.string(@tagName(segment.format));
            try json.key("inputs");
            const fixtures_len: usize = segment.fixtures.len;
            try json.uint(@intCast(fixtures_len));
            try json.key("cases");
            try json.uint(@intCast(cases));
            try json.endObject();
        }
        try json.endArray();
    } else {
        try json.key("formats");
        try json.beginArray();
        for (report.formats) |value| try json.string(@tagName(value));
        try json.endArray();
        try json.key("workloads");
        try json.beginArray();
        for (report.workloads) |value| try json.string(@tagName(value));
        try json.endArray();
        try json.key("stages");
        try json.beginArray();
        for (report.stages) |value| try json.string(@tagName(value));
        try json.endArray();
    }
    try json.key("expected_inputs");
    try json.uint(@intCast(expected_work_counts.inputs));
    try json.key("expected_cases");
    try json.uint(@intCast(expected_work_counts.cases));
    try json.endObject();

    try json.key("toolchain");
    try json.beginObject();
    try json.key("zig_basename");
    try json.string(manifest.toolchain.zig_basename);
    try json.key("zig_version");
    try json.string(manifest.toolchain.zig_version);
    try json.key("zig_sha256");
    try json.string(&manifest.toolchain.zig_sha256);
    try json.key("zig_bytes");
    try json.uint(manifest.toolchain.zig_bytes);
    try json.key("bench_target");
    try json.string(manifest.toolchain.bench_target);
    try json.key("bench_cpu");
    try json.string(manifest.toolchain.bench_cpu);
    try json.key("bench_optimize");
    try json.string(manifest.toolchain.bench_optimize);
    try json.key("bench_vector_len");
    try json.nullableUint(manifest.toolchain.bench_vector_len);
    try json.endObject();

    try json.key("host");
    try json.beginObject();
    try json.key("os");
    try json.string(manifest.host.os);
    try json.key("arch");
    try json.string(manifest.host.arch);
    try json.key("cpu_model");
    try json.string(manifest.host.cpu_model);
    try json.key("cpu_vendor");
    try json.string(manifest.host.cpu_vendor);
    try json.key("cpu_features");
    try json.string(manifest.host.cpu_features);
    try json.key("cpu_processors");
    try json.uint(manifest.host.cpu_processors);
    try json.key("cpus_allowed_list");
    try json.string(manifest.host.cpus_allowed_list);
    try json.key("affinity_ranges");
    try json.string(manifest.host.affinity_ranges);
    try json.key("affinity_cpu_count");
    try json.uint(manifest.host.affinity_cpu_count);
    try json.key("cpu_mhz_observed");
    try json.nullableUint(manifest.host.cpu_mhz_observed);
    try json.endObject();

    try json.key("environment");
    try json.beginObject();
    try json.key("lang");
    try writeNullableText(json, manifest.environment.lang);
    try json.key("lc_all");
    try writeNullableText(json, manifest.environment.lc_all);
    try json.key("tz");
    try writeNullableText(json, manifest.environment.tz);
    try json.endObject();

    try json.key("sources");
    try json.beginArray();
    for (manifest.sources) |entry| {
        try json.beginObject();
        try json.key("path");
        try json.string(entry.path);
        try json.key("bytes");
        try json.uint(entry.bytes);
        try json.key("sha256");
        try json.string(&entry.sha256);
        try json.endObject();
    }
    try json.endArray();

    try json.key("source_identity");
    try json.string(&manifest.source_identity);

    try json.key("bench_binary");
    try json.beginObject();
    try json.key("archive_path");
    try json.string(bench_archive_path);
    try writeDigestFields(json, manifest.bench);
    try json.endObject();

    try json.key("samples");
    try json.beginArray();
    for (manifest.samples) |sample| {
        try json.beginObject();
        try json.key("index");
        try json.uint(sample.index);
        try json.key("stdout_path");
        try json.string(sample.stdout_path);
        try json.key("stdout_bytes");
        try json.uint(sample.stdout_bytes);
        try json.key("stdout_sha256");
        try json.string(&sample.stdout_sha256);
        try json.key("stderr_path");
        try json.string(sample.stderr_path);
        try json.key("stderr_bytes");
        try json.uint(sample.stderr_bytes);
        try json.key("stderr_sha256");
        try json.string(&sample.stderr_sha256);
        try json.key("terminated");
        try json.string(sample.term_kind.name());
        try json.key("term_value");
        try json.uint(sample.term_value);
        try json.endObject();
    }
    try json.endArray();

    if (manifest.analysis) |analysis| {
        try json.key("bench_headers");
        try json.beginObject();
        try json.key("zig_version");
        try json.string(analysis.headers.zig_version);
        try json.key("optimize");
        try json.string(analysis.headers.optimize);
        try json.key("target_arch");
        try json.string(analysis.headers.target_arch);
        try json.key("vector_len");
        try json.uint(analysis.headers.vector_len);
        if (comptime semantic_mode) {
            // The semantic metadata names the profile under measurement and
            // the boundaries it stays inside. The legacy resident, prefix,
            // stream, and synthetic-scale fields describe work this
            // measurement does not perform, so they are not recorded as
            // defaults under its own schema.
            try json.key("commonmark_profile");
            try json.string(analysis.headers.commonmark_profile);
            try json.key("yaml_profile");
            try json.string(analysis.headers.yaml_profile);
            try json.key("setup");
            try json.string(analysis.headers.setup);
            try json.key("consumption");
            try json.string(analysis.headers.consumption);
            try json.key("render_html");
            try json.string(analysis.headers.render_html);
            try json.key("streaming");
            try json.string(analysis.headers.streaming);
            try json.key("ranking");
            try json.string(analysis.headers.ranking);
        } else {
            try json.key("stream_chunk_bytes");
            try json.uint(analysis.headers.stream_chunk_bytes);
            try json.key("stream_chunk_invocation");
            try json.string(analysis.headers.stream_chunk_invocation);
            try json.key("synthetic_scale");
            try json.uint(analysis.headers.synthetic_scale);
            try json.key("consumption");
            try json.string(analysis.headers.consumption);
            try json.key("resident_setup");
            try json.string(analysis.headers.resident_setup);
            try json.key("resident_consumption");
            try json.string(analysis.headers.resident_consumption);
            try json.key("traverse_prefix8");
            try json.string(analysis.headers.traverse_prefix8);
            try json.key("baseline");
            try json.string(analysis.headers.baseline);
        }
        try json.endObject();

        try json.key("inputs");
        try json.beginArray();
        for (analysis.inputs, 0..) |entry, index| {
            try json.beginObject();
            try json.key("index");
            try json.uint(index + 1);
            try json.key("format");
            try json.string(@tagName(entry.format));
            try json.key("workload");
            try json.string(@tagName(entry.workload));
            try json.key("input_hash");
            try json.string(&hexOf(entry.input_hash));
            try json.key("input_bytes");
            try json.uint(entry.input_bytes);
            try json.endObject();
        }
        try json.endArray();
    } else {
        try json.key("bench_headers");
        try json.writeNull();
        try json.key("inputs");
        try json.beginArray();
        try json.endArray();
    }

    try json.key("cases");
    try json.beginArray();
    if (manifest.analysis) |analysis| {
        for (analysis.cases, 0..) |merged, index| {
            try json.beginObject();
            try json.key("index");
            try json.uint(index + 1);
            try json.key("format");
            try json.string(@tagName(merged.stable.format));
            try json.key("workload");
            try json.string(@tagName(merged.stable.workload));
            try json.key("stage");
            try json.string(@tagName(merged.stable.stage));
            if (comptime semantic_mode) {
                // What the run observed: exactly `accepted`, or the name of
                // the error the real call returned. It is an observation, not
                // an expectation copied from the fixture, and it is compared
                // for identity like every other case fact.
                try json.key("outcome");
                try json.string(merged.stable.outcome);
            }
            try json.key("input_hash");
            try json.string(&hexOf(merged.stable.input_hash));
            try json.key("input_bytes");
            try json.uint(merged.stable.input_bytes);
            try json.key("iterations");
            try json.uint(merged.stable.iterations);
            try json.key("checksum");
            try json.string(&hexOf(merged.stable.checksum));
            try json.key("allocation_count");
            try json.uint(merged.stable.allocation_count);
            try json.key("allocated_bytes");
            try json.uint(merged.stable.allocated_bytes);
            try json.key("elapsed_ns");
            try json.beginArray();
            for (merged.elapsed_ns) |value| try json.uint(value);
            try json.endArray();
            try json.endObject();
        }
    }
    try json.endArray();

    try json.endObject();
    try json.writer.writeAll("\n");
}

fn parseHexField(object: JsonObject, name: []const u8) ArchiveError!u64 {
    const text = try fieldString(object, name);
    return std.fmt.parseUnsigned(u64, text, 16) catch error.ManifestFieldType;
}

const LoadedArchive = struct {
    parsed: std.json.Parsed(std.json.Value),
    manifest: Manifest,

    /// Releases the copies the load took and the parsed document the loaded
    /// manifest borrows its views from. A caller that keeps the archive alive
    /// keeps every case outcome in it alive, so the two are released together.
    fn deinit(self: *LoadedArchive, allocator: Allocator) void {
        freeManifest(allocator, &self.manifest);
        self.parsed.deinit();
        self.* = undefined;
    }
};

/// Every header field a load fills starts empty. A field the loader has not
/// reached yet is a zero-length string, and releasing a zero-length string
/// returns nothing, so a single release walk covers a headers block that was
/// filled in and one abandoned half way through.
fn emptyHeaders() report.BenchHeaders {
    if (comptime semantic_mode) {
        return .{
            .zig_version = "",
            .optimize = "",
            .target_arch = "",
            .vector_len = 0,
            .commonmark_profile = "",
            .yaml_profile = "",
            .setup = "",
            .consumption = "",
            .render_html = "",
            .streaming = "",
            .ranking = "",
        };
    } else {
        return .{
            .zig_version = "",
            .optimize = "",
            .target_arch = "",
            .vector_len = 0,
            .stream_chunk_bytes = 0,
            .stream_chunk_invocation = "",
            .synthetic_scale = 0,
            .consumption = "",
            .resident_setup = "",
            .resident_consumption = "",
            .traverse_prefix8 = "",
            .baseline = "",
        };
    }
}

/// A zero-length slice. Releasing one returns nothing, so a field that has
/// not been filled yet can go through the same release walk as one that has.
fn emptySlice(comptime T: type) []T {
    return @constCast((&[_]T{})[0..]);
}

/// Copies every header value the mode declares, in declaration order, so a
/// fault part way through releases exactly the copies already taken.
fn loadBenchHeaders(allocator: Allocator, object: JsonObject) ArchiveError!report.BenchHeaders {
    var headers = emptyHeaders();
    errdefer report.freeHeaders(allocator, &headers);
    headers.zig_version = try allocator.dupe(u8, try fieldString(object, "zig_version"));
    headers.optimize = try allocator.dupe(u8, try fieldString(object, "optimize"));
    headers.target_arch = try allocator.dupe(u8, try fieldString(object, "target_arch"));
    headers.vector_len = try fieldUint(object, "vector_len");
    if (comptime semantic_mode) {
        headers.commonmark_profile = try allocator.dupe(u8, try fieldString(object, "commonmark_profile"));
        headers.yaml_profile = try allocator.dupe(u8, try fieldString(object, "yaml_profile"));
        headers.setup = try allocator.dupe(u8, try fieldString(object, "setup"));
        headers.consumption = try allocator.dupe(u8, try fieldString(object, "consumption"));
        headers.render_html = try allocator.dupe(u8, try fieldString(object, "render_html"));
        headers.streaming = try allocator.dupe(u8, try fieldString(object, "streaming"));
        headers.ranking = try allocator.dupe(u8, try fieldString(object, "ranking"));
    } else {
        headers.stream_chunk_bytes = try fieldUint(object, "stream_chunk_bytes");
        headers.stream_chunk_invocation = try allocator.dupe(u8, try fieldString(object, "stream_chunk_invocation"));
        headers.synthetic_scale = try fieldUint(object, "synthetic_scale");
        headers.consumption = try allocator.dupe(u8, try fieldString(object, "consumption"));
        headers.resident_setup = try allocator.dupe(u8, try fieldString(object, "resident_setup"));
        headers.resident_consumption = try allocator.dupe(u8, try fieldString(object, "resident_consumption"));
        headers.traverse_prefix8 = try allocator.dupe(u8, try fieldString(object, "traverse_prefix8"));
        headers.baseline = try allocator.dupe(u8, try fieldString(object, "baseline"));
    }
    return headers;
}

fn loadToolchain(allocator: Allocator, object: JsonObject) ArchiveError!ToolchainFacts {
    const vector_len = try fieldOptionalUint(object, "bench_vector_len");
    if (vector_len) |width| {
        if (width > std.math.maxInt(u32)) return error.ManifestFieldType;
    }
    var digest: [64]u8 = undefined;
    const text = try fieldString(object, "zig_sha256");
    if (text.len != digest.len) return error.ManifestFieldType;
    @memcpy(&digest, text);

    // Every copied field is empty until it is read, and releasing an empty
    // string returns nothing, so the release below frees the copies taken so
    // far and nothing that was never read.
    var facts: ToolchainFacts = .{
        .zig_basename = "",
        .zig_version = "",
        .zig_sha256 = digest,
        .zig_bytes = 0,
        .bench_target = "",
        .bench_cpu = "",
        .bench_optimize = "",
        .bench_vector_len = vector_len,
    };
    errdefer freeToolchain(allocator, &facts);
    facts.zig_basename = try allocator.dupe(u8, try fieldString(object, "zig_basename"));
    facts.zig_version = try allocator.dupe(u8, try fieldString(object, "zig_version"));
    facts.zig_bytes = try fieldUint(object, "zig_bytes");
    facts.bench_target = try allocator.dupe(u8, try fieldString(object, "bench_target"));
    facts.bench_cpu = try allocator.dupe(u8, try fieldString(object, "bench_cpu"));
    facts.bench_optimize = try allocator.dupe(u8, try fieldString(object, "bench_optimize"));
    return facts;
}

fn freeToolchain(allocator: Allocator, facts: *ToolchainFacts) void {
    allocator.free(facts.zig_basename);
    allocator.free(facts.zig_version);
    allocator.free(facts.bench_target);
    allocator.free(facts.bench_cpu);
    allocator.free(facts.bench_optimize);
    // SAFETY: every owning field was released on the lines above. The caller
    // must not read `facts` again, so poisoning the released slices cannot
    // hand back a pointer the allocator no longer owns.
    facts.* = undefined;
}

fn loadHost(allocator: Allocator, object: JsonObject) ArchiveError!HostFacts {
    var facts: HostFacts = .{
        .os = "",
        .arch = "",
        .cpu_model = "",
        .cpu_vendor = "",
        .cpu_features = "",
        .cpu_processors = 0,
        .cpus_allowed_list = "",
        .affinity_ranges = "",
        .affinity_cpu_count = 0,
        .cpu_mhz_observed = null,
    };
    errdefer freeHost(allocator, &facts);
    facts.os = try allocator.dupe(u8, try fieldString(object, "os"));
    facts.arch = try allocator.dupe(u8, try fieldString(object, "arch"));
    facts.cpu_model = try allocator.dupe(u8, try fieldString(object, "cpu_model"));
    facts.cpu_vendor = try allocator.dupe(u8, try fieldString(object, "cpu_vendor"));
    facts.cpu_features = try allocator.dupe(u8, try fieldString(object, "cpu_features"));
    facts.cpu_processors = try fieldUint(object, "cpu_processors");
    facts.cpus_allowed_list = try allocator.dupe(u8, try fieldString(object, "cpus_allowed_list"));
    facts.affinity_ranges = try allocator.dupe(u8, try fieldString(object, "affinity_ranges"));
    facts.affinity_cpu_count = try fieldUint(object, "affinity_cpu_count");
    facts.cpu_mhz_observed = try fieldOptionalUint(object, "cpu_mhz_observed");
    return facts;
}

fn freeHost(allocator: Allocator, facts: *HostFacts) void {
    allocator.free(facts.os);
    allocator.free(facts.arch);
    allocator.free(facts.cpu_model);
    allocator.free(facts.cpu_vendor);
    allocator.free(facts.cpu_features);
    allocator.free(facts.cpus_allowed_list);
    allocator.free(facts.affinity_ranges);
    // SAFETY: every owning field was released on the lines above; the poison
    // only makes a later read of `facts` fail loudly instead of returning a
    // freed pointer.
    facts.* = undefined;
}

fn loadEnvironment(allocator: Allocator, object: JsonObject) ArchiveError!EnvironmentFacts {
    var facts: EnvironmentFacts = .{ .lang = null, .lc_all = null, .tz = null };
    errdefer freeEnvironment(allocator, &facts);
    facts.lang = try loadOptionalText(allocator, object, "lang");
    facts.lc_all = try loadOptionalText(allocator, object, "lc_all");
    facts.tz = try loadOptionalText(allocator, object, "tz");
    return facts;
}

fn freeEnvironment(allocator: Allocator, facts: *EnvironmentFacts) void {
    if (facts.lang) |text| allocator.free(text);
    if (facts.lc_all) |text| allocator.free(text);
    if (facts.tz) |text| allocator.free(text);
    // SAFETY: every optional field was released above or was null; the poison
    // only makes a later read fail loudly instead of returning a freed
    // pointer.
    facts.* = undefined;
}

fn loadOptionalText(allocator: Allocator, object: JsonObject, name: []const u8) ArchiveError!?[]const u8 {
    return switch (object.get(name) orelse return error.ManifestMissingField) {
        .null => null,
        .string => |text| try allocator.dupe(u8, text),
        else => error.ManifestFieldType,
    };
}

fn loadSources(
    allocator: Allocator,
    items: []const std.json.Value,
    allow_empty: bool,
) ArchiveError![]SourceEntry {
    if (items.len == 0 and allow_empty) return allocator.alloc(SourceEntry, 0);
    if (items.len == 0 or items.len > max_source_files) return error.ManifestIncomplete;
    const entries = try allocator.alloc(SourceEntry, items.len);
    // Only the prefix already written holds a copied path. The rest of the
    // slice is still undefined and must not be read on the way out.
    var filled: usize = 0;
    errdefer freeSources(allocator, entries, filled);
    while (filled < items.len) : (filled += 1) {
        const object = try requireObject(items[filled]);
        const path = try fieldString(object, "path");
        if (!isSafeRelativePath(path)) return error.UnsafeArchivePath;
        if (filled > 0 and !std.mem.lessThan(u8, entries[filled - 1].path, path)) {
            return error.ManifestIncomplete;
        }
        var digest: [64]u8 = undefined;
        const text = try fieldString(object, "sha256");
        if (text.len != digest.len) return error.ManifestFieldType;
        @memcpy(&digest, text);
        const bytes = try fieldUint(object, "bytes");
        entries[filled] = .{
            .path = try allocator.dupe(u8, path),
            .bytes = bytes,
            .sha256 = digest,
        };
    }
    return entries;
}

/// Releases a source snapshot: `filled` of its entries hold a copied path and
/// are released one by one, and the block itself goes back whole. A loader
/// that stopped part way through passes the count it reached, so entries it
/// never wrote are neither walked nor kept.
fn freeSources(allocator: Allocator, entries: []SourceEntry, filled: usize) void {
    for (entries[0..filled]) |entry| allocator.free(entry.path);
    allocator.free(entries);
}

fn loadSamples(
    allocator: Allocator,
    items: []const std.json.Value,
    allow_empty: bool,
) ArchiveError![]SampleRecord {
    if (items.len == 0 and allow_empty) return allocator.alloc(SampleRecord, 0);
    if (items.len == 0 or items.len > report.max_samples) return error.ManifestIncomplete;
    const records = try allocator.alloc(SampleRecord, items.len);
    // Only the prefix already written holds a copied pair of paths, for the
    // same reason the source list releases only the prefix it filled.
    var filled: usize = 0;
    errdefer freeSamples(allocator, records, filled);
    while (filled < items.len) : (filled += 1) {
        const object = try requireObject(items[filled]);
        if (try fieldUint(object, "index") != filled + 1) return error.ManifestIncomplete;
        const stdout_path = try fieldString(object, "stdout_path");
        const stderr_path = try fieldString(object, "stderr_path");
        // The two names a record has to match are scratch: they are compared
        // and released here rather than kept beside what they police.
        const expected_stdout = try sampleName(allocator, "stdout", @intCast(filled + 1));
        defer allocator.free(expected_stdout);
        const expected_stderr = try sampleName(allocator, "stderr", @intCast(filled + 1));
        defer allocator.free(expected_stderr);
        if (!std.mem.eql(u8, stdout_path, expected_stdout)) return error.UnsafeArchivePath;
        if (!std.mem.eql(u8, stderr_path, expected_stderr)) return error.UnsafeArchivePath;

        var stdout_digest: [64]u8 = undefined;
        var stderr_digest: [64]u8 = undefined;
        const stdout_text = try fieldString(object, "stdout_sha256");
        const stderr_text = try fieldString(object, "stderr_sha256");
        if (stdout_text.len != stdout_digest.len or stderr_text.len != stderr_digest.len) {
            return error.ManifestFieldType;
        }
        @memcpy(&stdout_digest, stdout_text);
        @memcpy(&stderr_digest, stderr_text);

        // Both copies are taken before the record is written, so a fault on
        // any later field leaves the record unwritten and the prefix release
        // still owns both of them.
        const owned_stdout = try allocator.dupe(u8, stdout_path);
        errdefer allocator.free(owned_stdout);
        const owned_stderr = try allocator.dupe(u8, stderr_path);
        errdefer allocator.free(owned_stderr);
        records[filled] = .{
            .index = @intCast(filled + 1),
            .stdout_path = owned_stdout,
            .stdout_bytes = try fieldUint(object, "stdout_bytes"),
            .stdout_sha256 = stdout_digest,
            .stderr_path = owned_stderr,
            .stderr_bytes = try fieldUint(object, "stderr_bytes"),
            .stderr_sha256 = stderr_digest,
            .term_kind = TermKind.fromName(try fieldString(object, "terminated")) orelse
                return error.ManifestFieldType,
            .term_value = try fieldUint(object, "term_value"),
        };
    }
    return records;
}

/// Releases a sample list: `filled` of its records hold a copied pair of paths
/// and are released one by one, and the block itself goes back whole. A loader
/// that stopped part way through passes the count it reached, so records it
/// never wrote are neither walked nor kept.
fn freeSamples(allocator: Allocator, records: []SampleRecord, filled: usize) void {
    for (records[0..filled]) |record| {
        allocator.free(record.stdout_path);
        allocator.free(record.stderr_path);
    }
    allocator.free(records);
}

fn loadAnalysis(
    allocator: Allocator,
    headers_object: JsonObject,
    inputs_items: []const std.json.Value,
    cases_items: []const std.json.Value,
    sample_count: u16,
) ArchiveError!report.Analysis {
    // The declared work of this mode, not a number copied from the archive.
    if (inputs_items.len != expected_work_counts.inputs) return error.ManifestIncomplete;
    if (cases_items.len != expected_work_counts.cases) return error.ManifestIncomplete;

    // Every field starts empty so a fault part way through releases exactly
    // what has already been taken. The narrowing release is registered after
    // the whole-analysis one, so it runs first and the analysis walk sees the
    // cases that were actually written.
    var analysis: report.Analysis = .{
        .headers = emptyHeaders(),
        .inputs = emptySlice(report.InputEntry),
        .cases = emptySlice(report.MergedCase),
    };
    errdefer report.freeAnalysis(allocator, &analysis);

    analysis.inputs = try allocator.alloc(report.InputEntry, inputs_items.len);
    for (inputs_items, 0..) |item, index| {
        const object = try requireObject(item);
        if (try fieldUint(object, "index") != index + 1) return error.ManifestIncomplete;
        analysis.inputs[index] = .{
            .format = try fieldFormat(object, "format"),
            .workload = try fieldWorkload(object, "workload"),
            .input_hash = try parseHexField(object, "input_hash"),
            .input_bytes = try fieldUint(object, "input_bytes"),
        };
    }

    const cases = try allocator.alloc(report.MergedCase, cases_items.len);
    // Scoped to the block that owns the slice: only the prefix already
    // written holds a timing slice, the rest of the block is still undefined
    // and is released without being walked, and the block itself goes back
    // whole. Once the loop finishes the analysis takes the block and this
    // walk no longer applies to it.
    {
        var filled: usize = 0;
        errdefer {
            for (cases[0..filled]) |merged| allocator.free(merged.elapsed_ns);
            allocator.free(cases);
        }
        while (filled < cases_items.len) : (filled += 1) {
            const object = try requireObject(cases_items[filled]);
            if (try fieldUint(object, "index") != filled + 1) return error.ManifestIncomplete;
            const timing_items = try fieldArray(object, "elapsed_ns");
            if (timing_items.len != sample_count) return error.ManifestIncomplete;
            const timings = try allocator.alloc(u64, timing_items.len);
            // Released here unless the case is written below, so a fault on
            // any of the fields that follow cannot strand the slice.
            errdefer allocator.free(timings);
            for (timing_items, 0..) |timing, slot| {
                switch (timing) {
                    .integer => |value| timings[slot] = if (value < 0)
                        return error.ManifestFieldType
                    else
                        @intCast(value),
                    else => return error.ManifestFieldType,
                }
            }
            // Filled one field at a time so each mode declares exactly the
            // facts it records: the shared case facts in both, and the
            // observed outcome only where a semantic case has one.
            // SAFETY: every field is assigned between here and the read of
            // `stable`, and `outcome` exists only in the mode whose branch
            // assigns it.
            var stable: report.CaseRecord = undefined;
            stable.format = try fieldFormat(object, "format");
            stable.workload = try fieldWorkload(object, "workload");
            stable.stage = try fieldStage(object, "stage");
            if (comptime semantic_mode) {
                // Borrowed from the manifest document `LoadedArchive` keeps
                // alive. A loaded outcome is valid exactly as long as the
                // archive that recorded it, so comparing it against a
                // recomputed capture compares two live strings and never a
                // freed buffer.
                stable.outcome = try fieldString(object, "outcome");
            }
            stable.input_hash = try parseHexField(object, "input_hash");
            stable.input_bytes = try fieldUint(object, "input_bytes");
            stable.iterations = try fieldUint(object, "iterations");
            stable.elapsed_ns = 0;
            stable.checksum = try parseHexField(object, "checksum");
            stable.allocation_count = try fieldUint(object, "allocation_count");
            stable.allocated_bytes = try fieldUint(object, "allocated_bytes");
            cases[filled] = .{ .stable = stable, .elapsed_ns = timings };
        }
    }
    analysis.cases = cases;

    analysis.headers = try loadBenchHeaders(allocator, headers_object);
    return analysis;
}

fn loadManifest(allocator: Allocator, bytes: []const u8) ArchiveError!LoadedArchive {
    if (bytes.len > max_manifest_bytes) return error.ManifestUnreadable;
    var parsed = try parseJsonDocument(allocator, bytes);
    errdefer parsed.deinit();
    const root = try requireObject(parsed.value);

    if (!std.mem.eql(u8, try fieldString(root, "schema"), schema_name)) return error.ManifestSchemaMismatch;
    if (try fieldUint(root, "schema_version") != schema_version) return error.ManifestSchemaMismatch;

    const options_object = try fieldObject(root, "options");
    const samples_raw = try fieldUint(options_object, "samples");
    const iterations_raw = try fieldUint(options_object, "iterations");
    // The chunk size is read where legacy mode has always read it, before any
    // range check, so a corrupt legacy manifest still fails with the same
    // fault it always did. Semantic mode has no such field to read: samples
    // and iterations are the whole invocation shape, and there is no default
    // to accept on its behalf.
    const chunk_raw: u64 = if (comptime semantic_mode)
        0
    else
        try fieldUint(options_object, "stream_chunk_size");
    if (samples_raw < report.min_samples or samples_raw > report.max_samples) return error.OptionsInvalid;
    if (iterations_raw < report.min_iterations or iterations_raw > report.max_iterations) return error.OptionsInvalid;
    if (chunk_raw > std.math.maxInt(u32)) return error.OptionsInvalid;
    var options: report.Options = .{
        .samples = @intCast(samples_raw),
        .iterations = @intCast(iterations_raw),
    };
    if (comptime semantic_mode) {
        options.validate() catch return error.OptionsInvalid;
    } else {
        options.stream_chunk_size = @intCast(chunk_raw);
        options.validate() catch return error.OptionsInvalid;
    }

    // Status is read before completeness is judged. A failed recording is
    // evidence of a failure, so its manifest reports the failure even when the
    // run died before every sample or source was captured.
    const status = try fieldString(root, "status");
    const is_complete = std.mem.eql(u8, status, status_complete);
    const is_failed = std.mem.eql(u8, status, status_failed);
    if (!is_complete and !is_failed) return error.ManifestFieldType;

    // The decoded manifest starts with every owned field empty, so a load
    // abandoned part way through releases exactly what it had already taken
    // and nothing it had not.
    var manifest = emptyDecodedManifest(options);
    errdefer freeManifest(allocator, &manifest);

    manifest.samples = try loadSamples(allocator, try fieldArray(root, "samples"), is_failed);
    if (is_complete and manifest.samples.len != options.samples) return error.ManifestIncomplete;

    const bench_object = try fieldObject(root, "bench_binary");
    if (!std.mem.eql(u8, try fieldString(bench_object, "archive_path"), bench_archive_path)) {
        return error.UnsafeArchivePath;
    }
    var bench_digest: [64]u8 = undefined;
    const bench_text = try fieldString(bench_object, "sha256");
    if (bench_text.len != bench_digest.len) return error.ManifestFieldType;
    @memcpy(&bench_digest, bench_text);

    manifest.sources = try loadSources(allocator, try fieldArray(root, "sources"), is_failed);
    var identity: [64]u8 = undefined;
    const identity_text = try fieldString(root, "source_identity");
    if (identity_text.len != identity.len) return error.ManifestFieldType;
    @memcpy(&identity, identity_text);
    manifest.source_identity = identity;

    if (is_complete) {
        manifest.analysis = try loadAnalysis(
            allocator,
            try fieldObject(root, "bench_headers"),
            try fieldArray(root, "inputs"),
            try fieldArray(root, "cases"),
            options.samples,
        );
    }

    manifest.status = try allocator.dupe(u8, status);
    manifest.reason = try allocator.dupe(u8, try fieldString(root, "reason"));
    manifest.created_unix_ns = try fieldInt(root, "created_unix_ns");
    manifest.created_utc = try allocator.dupe(u8, try fieldString(root, "created_utc"));
    manifest.toolchain = try loadToolchain(allocator, try fieldObject(root, "toolchain"));
    manifest.host = try loadHost(allocator, try fieldObject(root, "host"));
    manifest.environment = try loadEnvironment(allocator, try fieldObject(root, "environment"));
    manifest.bench = .{ .bytes = try fieldUint(bench_object, "bytes"), .sha256 = bench_digest };

    return .{ .parsed = parsed, .manifest = manifest };
}

/// The state a decoded manifest starts in: every owned field empty, so one
/// release walk covers a load that filled it in and one that stopped early.
fn emptyDecodedManifest(options: report.Options) Manifest {
    return .{
        .status = "",
        .reason = "",
        .created_unix_ns = 0,
        .created_utc = "",
        .options = options,
        .toolchain = .{
            .zig_basename = "",
            .zig_version = "",
            .zig_sha256 = zero_digest,
            .zig_bytes = 0,
            .bench_target = "",
            .bench_cpu = "",
            .bench_optimize = "",
            .bench_vector_len = null,
        },
        .host = .{
            .os = "",
            .arch = "",
            .cpu_model = "",
            .cpu_vendor = "",
            .cpu_features = "",
            .cpu_processors = 0,
            .cpus_allowed_list = "",
            .affinity_ranges = "",
            .affinity_cpu_count = 0,
            .cpu_mhz_observed = null,
        },
        .environment = .{ .lang = null, .lc_all = null, .tz = null },
        .sources = emptySlice(SourceEntry),
        .source_identity = zero_digest,
        .bench = .{ .bytes = 0, .sha256 = zero_digest },
        .samples = emptySlice(SampleRecord),
        .analysis = null,
    };
}

/// Releases every copy a decoded manifest owns. The case outcomes in it are
/// borrowed from the document the archive holds beside it, so they are
/// released with the archive rather than here.
fn freeManifest(allocator: Allocator, manifest: *Manifest) void {
    allocator.free(manifest.status);
    allocator.free(manifest.reason);
    allocator.free(manifest.created_utc);
    freeToolchain(allocator, &manifest.toolchain);
    freeHost(allocator, &manifest.host);
    freeEnvironment(allocator, &manifest.environment);
    freeSources(allocator, manifest.sources, manifest.sources.len);
    freeSamples(allocator, manifest.samples, manifest.samples.len);
    if (manifest.analysis) |*analysis| report.freeAnalysis(allocator, analysis);
    // SAFETY: every owning field was released above, recursively through the
    // facts, sources, samples and analysis this manifest owns; the poison only
    // makes a later read fail loudly instead of returning a freed pointer.
    manifest.* = undefined;
}

// ---------------------------------------------------------------------------
// Offline verification.
// ---------------------------------------------------------------------------

const Context = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: ?*std.process.Environ.Map,
    out: *std.Io.Writer,
};

fn sameStrings(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

/// Re-derives everything the manifest claims from the archive's own bytes.
/// No current checkout, compiler, or CPU state is consulted.
/// `dir` must be opened with `.iterate`, because the archive's own file set is
/// re-derived by walking it.
fn verifyArchive(ctx: *Context, dir: Io.Dir, loaded: *const LoadedArchive) ArchiveError!report.Analysis {
    const manifest = &loaded.manifest;
    if (!std.mem.eql(u8, manifest.status, status_complete)) return error.ManifestFailedStatus;

    var found: std.ArrayList([]const u8) = .empty;
    defer {
        for (found.items) |path| ctx.arena.free(path);
        found.deinit(ctx.arena);
    }
    var budget: usize = max_archive_files;
    try collectArchiveFiles(ctx.arena, ctx.io, dir, "", 0, &found, &budget);

    var expected: std.ArrayList([]const u8) = .empty;
    defer expected.deinit(ctx.arena);
    try insertSorted(ctx.arena, &expected, manifest_name);
    try insertSorted(ctx.arena, &expected, bench_archive_path);
    for (manifest.samples) |sample| {
        try insertSorted(ctx.arena, &expected, sample.stdout_path);
        try insertSorted(ctx.arena, &expected, sample.stderr_path);
    }
    for (manifest.sources) |entry| {
        const archived = try joinPath(ctx.arena, &.{ sources_subdir, entry.path });
        try insertSorted(ctx.arena, &expected, archived);
    }
    if (!sameStrings(found.items, expected.items)) return error.UnexpectedArchiveFile;

    for (manifest.sources) |entry| {
        const archived = try joinPath(ctx.arena, &.{ sources_subdir, entry.path });
        const digest = try digestArchived(ctx.io, dir, archived, max_hashed_file_bytes);
        if (digest.bytes != entry.bytes) return error.SizeMismatch;
        if (!std.mem.eql(u8, &digest.sha256, &entry.sha256)) return error.HashMismatch;
    }
    if (!std.mem.eql(u8, &sourceIdentityDigest(manifest.sources), &manifest.source_identity)) {
        return error.HashMismatch;
    }

    const bench = try digestArchived(ctx.io, dir, bench_archive_path, max_hashed_file_bytes);
    if (bench.bytes != manifest.bench.bytes) return error.SizeMismatch;
    if (!std.mem.eql(u8, &bench.sha256, &manifest.bench.sha256)) return error.HashMismatch;

    // Raw captures are read once through a validated handle, hashed in place,
    // and kept in the arena so the strict decoder sees the whole set at once.
    const stdouts = try ctx.arena.alloc([]const u8, manifest.samples.len);
    for (manifest.samples, 0..) |sample, index| {
        // A complete archive records only samples that ran to completion, so a
        // non-zero or abnormal termination is a failed recording, not evidence.
        if (sample.index != index + 1) return error.ManifestIncomplete;
        if (sample.term_kind != .exited) return error.BenchTerminated;
        if (sample.term_value != 0) return error.BenchExitedNonzero;

        const stdout_bytes = try readArchived(ctx.arena, ctx.io, dir, sample.stdout_path, max_stdout_bytes);
        if (stdout_bytes.len != sample.stdout_bytes) return error.SizeMismatch;
        if (!std.mem.eql(u8, &sha256Hex(stdout_bytes), &sample.stdout_sha256)) return error.HashMismatch;
        stdouts[index] = stdout_bytes;

        const stderr_bytes = try readArchived(ctx.gpa, ctx.io, dir, sample.stderr_path, max_stderr_bytes);
        if (stderr_bytes.len != sample.stderr_bytes) {
            ctx.gpa.free(stderr_bytes);
            return error.SizeMismatch;
        }
        if (!std.mem.eql(u8, &sha256Hex(stderr_bytes), &sample.stderr_sha256)) {
            ctx.gpa.free(stderr_bytes);
            return error.HashMismatch;
        }
        ctx.gpa.free(stderr_bytes);
    }

    // Legacy mode decodes the fixed Cartesian contract its decoder already
    // knows; semantic mode decodes the declared fixture list, and the archive's
    // own captures are admitted only in that declared order.
    const recomputed = if (comptime semantic_mode)
        try report.analyzeSamples(ctx.arena, stdouts, manifest.options, semantic_domain)
    else
        try report.analyzeSamples(ctx.arena, stdouts, manifest.options);
    const recorded = manifest.analysis orelse return error.ManifestIncomplete;
    if (!report.sameAs(recorded, recomputed)) return error.ManifestIncomplete;

    // Timings are never an identity for reproduction, but they are recorded
    // observations: the manifest must carry exactly one per sample and each
    // must be the value the archived raw capture actually contains.
    for (recorded.cases, 0..) |merged, index| {
        if (merged.elapsed_ns.len != manifest.samples.len) return error.ManifestIncomplete;
        for (merged.elapsed_ns, 0..) |timing, slot| {
            if (timing != recomputed.cases[index].elapsed_ns[slot]) return error.ManifestIncomplete;
        }
    }
    return recomputed;
}

// ---------------------------------------------------------------------------
// Recording.
// ---------------------------------------------------------------------------

const zero_digest: [64]u8 = @splat('0');

fn emptyManifest(options: report.Options) Manifest {
    return .{
        .status = status_failed,
        .reason = "recording did not complete",
        .created_unix_ns = 0,
        .created_utc = "",
        .options = options,
        .toolchain = .{
            .zig_basename = "",
            .zig_version = "",
            .zig_sha256 = zero_digest,
            .zig_bytes = 0,
            .bench_target = "",
            .bench_cpu = "",
            .bench_optimize = "",
            .bench_vector_len = null,
        },
        .host = .{
            .os = "",
            .arch = "",
            .cpu_model = "",
            .cpu_vendor = "",
            .cpu_features = "",
            .cpu_processors = 0,
            .cpus_allowed_list = "",
            .affinity_ranges = "",
            .affinity_cpu_count = 0,
            .cpu_mhz_observed = null,
        },
        .environment = .{ .lang = null, .lc_all = null, .tz = null },
        .sources = &.{},
        .source_identity = zero_digest,
        .bench = .{ .bytes = 0, .sha256 = zero_digest },
        .samples = &.{},
        .analysis = null,
    };
}

fn writeManifestFile(ctx: *Context, archive: Io.Dir, manifest: *const Manifest) ArchiveError!void {
    var allocating: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer allocating.deinit();
    var json: JsonWriter = .{ .writer = &allocating.writer };
    // The render buffer is memory only, so the one fault a write into it can
    // report is its own failure to grow. `Writer.Allocating` names that
    // `error.WriteFailed` because a write can also fail at a sink that does
    // exist; here there is no sink, so it is the injected allocator refusing.
    // Reported as a write fault it tells the caller the manifest is bad, and
    // it abandons a failure injection before the manifest reaches disk.
    writeManifest(&json, manifest) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        // The depth guard refuses the manifest's own shape, so it is a defect
        // in the manifest and not a fault in writing it.
        error.ManifestTooDeep => return error.ManifestTooDeep,
        else => return err,
    };
    archive.writeFile(ctx.io, .{
        .sub_path = manifest_name,
        .data = allocating.written(),
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ArchiveEntryExists,
        else => return err,
    };
}

const Termination = struct { kind: TermKind, value: u64 };

/// Runs one captured sample. The raw streams and the termination status are
/// recorded before the status is judged, so a failing sample still leaves
/// complete evidence in the archive and in the failed manifest.
fn runBenchSample(
    ctx: *Context,
    bench_path: []const u8,
    options: report.Options,
    slot: usize,
    archive: Io.Dir,
    stdouts: [][]const u8,
    manifest: *Manifest,
    sample_log: *std.ArrayList(SampleRecord),
) ArchiveError!void {
    // The recorded sample number is the slot plus one; the capture keeps its
    // own index, so the caller never has to hand over an ordinal whose "minus
    // one" is the slot it already had.
    const ordinal: u16 = @intCast(slot + 1);
    const iterations_text = try ctx.arena.print("{d}", .{options.iterations});
    // The invocation is the mode's own. Semantic mode passes the iteration
    // count and nothing else: its bench takes one optional positional value,
    // so passing a stream chunk would be a flag it refuses, and passing a
    // default one anyway would claim a streaming measurement it does not make.
    const result = std.process.run(ctx.gpa, ctx.io, .{
        .argv = if (comptime semantic_mode)
            &.{ bench_path, iterations_text }
        else
            &.{
                bench_path,
                iterations_text,
                "--stream-chunk-size",
                try ctx.arena.print("{d}", .{options.stream_chunk_size}),
            },
        .stdout_limit = .limited(max_stdout_bytes),
        .stderr_limit = .limited(max_stderr_bytes),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.OutputStreamTooLong,
        else => return error.BenchTerminated,
    };
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);

    const term: Termination = switch (result.term) {
        .exited => |code| .{ .kind = .exited, .value = code },
        .signal => |number| .{ .kind = .signal, .value = @backingInt(number) },
        .stopped => |number| .{ .kind = .stopped, .value = @backingInt(number) },
        else => return error.BenchTerminated,
    };

    const stdout_path = try sampleName(ctx.arena, "stdout", ordinal);
    const stderr_path = try sampleName(ctx.arena, "stderr", ordinal);
    try writeExclusive(ctx.io, archive, stdout_path, result.stdout);
    try writeExclusive(ctx.io, archive, stderr_path, result.stderr);

    try sample_log.append(ctx.arena, .{
        .index = ordinal,
        .stdout_path = stdout_path,
        .stdout_bytes = result.stdout.len,
        .stdout_sha256 = sha256Hex(result.stdout),
        .stderr_path = stderr_path,
        .stderr_bytes = result.stderr.len,
        .stderr_sha256 = sha256Hex(result.stderr),
        .term_kind = term.kind,
        .term_value = term.value,
    });
    manifest.samples = sample_log.items;
    stdouts[slot] = try ctx.arena.dupe(u8, result.stdout);

    if (term.kind != .exited) return error.BenchTerminated;
    if (term.value != 0) return error.BenchExitedNonzero;
}

fn recordSteps(
    ctx: *Context,
    bench_path: []const u8,
    repo: Io.Dir,
    archive: Io.Dir,
    manifest: *Manifest,
    sample_log: *std.ArrayList(SampleRecord),
) ArchiveError!report.Analysis {
    const timestamp = try formatUtc(ctx.arena, ctx.io);
    manifest.created_unix_ns = timestamp.unix_ns;
    manifest.created_utc = timestamp.text;

    try archive.createDirPath(ctx.io, bench_subdir);
    try archive.createDirPath(ctx.io, samples_subdir);
    try archive.createDirPath(ctx.io, sources_subdir);

    const sources = try collectSourcePaths(ctx.arena, ctx.io, repo);
    manifest.sources = sources;
    manifest.source_identity = sourceIdentityDigest(sources);
    for (sources) |entry| {
        const archived = try joinPath(ctx.arena, &.{ sources_subdir, entry.path });
        const digest = try copyIntoArchive(ctx.io, repo, entry.path, archive, archived, max_hashed_file_bytes);
        if (digest.bytes != entry.bytes) return error.SourceTreeChanged;
        if (!std.mem.eql(u8, &digest.sha256, &entry.sha256)) return error.SourceTreeChanged;
    }

    manifest.bench = try copyIntoArchive(ctx.io, repo, bench_path, archive, bench_archive_path, max_hashed_file_bytes);
    manifest.toolchain = try collectToolchain(ctx.arena, ctx.io);
    manifest.host = try collectHostFacts(ctx.arena);
    manifest.environment = collectEnvironment(ctx.environ);

    const stdouts = try ctx.arena.alloc([]const u8, manifest.options.samples);
    for (0..manifest.options.samples) |index| {
        try runBenchSample(
            ctx,
            bench_path,
            manifest.options,
            index,
            archive,
            stdouts,
            manifest,
            sample_log,
        );
    }

    const analysis = if (comptime semantic_mode)
        try report.analyzeSamples(ctx.arena, stdouts, manifest.options, semantic_domain)
    else
        try report.analyzeSamples(ctx.arena, stdouts, manifest.options);

    // The captured snapshot is re-enumerated after the run, not merely
    // re-read, so a file that appeared or vanished while the samples ran
    // cannot be published as the measured source.
    const after = try collectSourcePaths(ctx.arena, ctx.io, repo);
    if (!sourcesEql(sources, after)) return error.SourceTreeChanged;
    if (!std.mem.eql(u8, &sourceIdentityDigest(after), &manifest.source_identity)) {
        return error.SourceTreeChanged;
    }
    const bench_again = try hashFileIn(ctx.io, repo, bench_path, max_hashed_file_bytes);
    if (bench_again.bytes != manifest.bench.bytes) return error.SourceTreeChanged;
    if (!std.mem.eql(u8, &bench_again.sha256, &manifest.bench.sha256)) return error.SourceTreeChanged;

    return analysis;
}

/// The gate a recorded archive must pass before it may be published as
/// complete. `reproduce` supplies the previous recording; a recording with no
/// expectation is a plain record and passes unconditionally.
fn publishDecision(expectation: ?report.Analysis, actual: report.Analysis) ArchiveError!void {
    const reference = expectation orelse return;
    if (!report.sameAs(reference, actual)) return error.CompareMismatch;
}

/// `expectation` is supplied by `reproduce`. The new recording is compared
/// before any complete manifest is written, so a mismatch leaves a failed
/// archive with its captures retained instead of a published comparison that
/// did not hold.
fn recordArchive(
    ctx: *Context,
    bench_path: []const u8,
    repo: Io.Dir,
    out_dir: []const u8,
    options: report.Options,
    expectation: ?report.Analysis,
) ArchiveError!report.Analysis {
    if (comptime semantic_mode) {
        // The declared work is checked before a directory exists. A domain
        // that could not produce the rows the protocol requires must stop the
        // run before it leaves an archive behind, exactly as an exclusive
        // directory check or an unreadable source tree stops it: there is
        // nothing to record if the work itself cannot be measured.
        try report.verifyDomain(semantic_domain);
    }

    // Rejects an existing archive before writing a single byte, so an earlier
    // recording is never truncated or mixed with a new one.
    var archive = try createArchiveDirExclusive(ctx.io, out_dir);
    defer archive.close(ctx.io);

    var manifest = emptyManifest(options);
    var sample_log: std.ArrayList(SampleRecord) = .empty;

    // The manifest is written exactly once, and only here: after the source,
    // binary, and static-profile checks, and after the reproduction
    // comparison. A failure that cannot be persisted is reported as such, so a
    // missing or unwritten status is never mistaken for a saved one.
    const analysis = recordSteps(ctx, bench_path, repo, archive, &manifest, &sample_log) catch |err| {
        manifest.status = status_failed;
        manifest.reason = @errorName(err);
        try writeManifestFile(ctx, archive, &manifest);
        return err;
    };

    publishDecision(expectation, analysis) catch |err| {
        manifest.status = status_failed;
        manifest.reason = @errorName(err);
        try writeManifestFile(ctx, archive, &manifest);
        return err;
    };

    manifest.status = status_complete;
    manifest.reason = "";
    manifest.analysis = analysis;
    try writeManifestFile(ctx, archive, &manifest);
    return analysis;
}

// ---------------------------------------------------------------------------
// Operations.
// ---------------------------------------------------------------------------

fn loadAndVerify(ctx: *Context, archive_path: []const u8) ArchiveError!struct {
    dir: Io.Dir,
    loaded: LoadedArchive,
    analysis: report.Analysis,
} {
    const dir = try openArchiveDir(ctx.io, archive_path);
    errdefer dir.close(ctx.io);
    const raw = try readArchived(ctx.gpa, ctx.io, dir, manifest_name, max_manifest_bytes);
    defer ctx.gpa.free(raw);
    var loaded = try loadManifest(ctx.arena, raw);
    const analysis = try verifyArchive(ctx, dir, &loaded);
    return .{ .dir = dir, .loaded = loaded, .analysis = analysis };
}

fn runVerify(ctx: *Context, archive_path: []const u8) ArchiveError!void {
    // Offline by construction: nothing here reads the current checkout, the
    // compiler, the benchmark artifact, or host CPU state.
    const opened = try loadAndVerify(ctx, archive_path);
    defer opened.dir.close(ctx.io);
    try ctx.out.print(
        "verified {s}: {d} samples, {d} inputs, {d} cases, source identity {s}\n",
        .{
            archive_path,
            opened.loaded.manifest.samples.len,
            opened.analysis.inputs.len,
            opened.analysis.cases.len,
            &opened.loaded.manifest.source_identity,
        },
    );
}

fn runRecord(
    ctx: *Context,
    bench_path: []const u8,
    repo_path: []const u8,
    command: report.RecordCommand,
) ArchiveError!void {
    if (bench_path.len == 0) return error.BenchmarkPathMissing;
    const repo = Io.Dir.openDirAbsolute(ctx.io, repo_path, .{}) catch return error.RepositoryRootMissing;
    defer repo.close(ctx.io);

    const analysis = try recordArchive(ctx, bench_path, repo, command.out_dir, command.options, null);
    try ctx.out.print(
        "recorded {s}: {d} samples, {d} inputs, {d} cases\n",
        .{ command.out_dir, command.options.samples, analysis.inputs.len, analysis.cases.len },
    );
}

fn runReproduce(
    ctx: *Context,
    bench_path: []const u8,
    repo_path: []const u8,
    command: report.ReproduceCommand,
) ArchiveError!void {
    const opened = try loadAndVerify(ctx, command.old_dir);
    defer opened.dir.close(ctx.io);
    const previous = opened.loaded.manifest;

    if (bench_path.len == 0) return error.BenchmarkPathMissing;
    const repo = Io.Dir.openDirAbsolute(ctx.io, repo_path, .{}) catch return error.RepositoryRootMissing;
    defer repo.close(ctx.io);

    const sources = try collectSourcePaths(ctx.arena, ctx.io, repo);
    if (!sourcesEql(sources, previous.sources)) return error.IdentityMismatch;

    const toolchain = try collectToolchain(ctx.arena, ctx.io);
    if (!toolchain.eql(previous.toolchain)) return error.IdentityMismatch;

    const host = try collectHostFacts(ctx.arena);
    if (!hostIdentityEql(host, previous.host)) return error.IdentityMismatch;

    const environment = collectEnvironment(ctx.environ);
    if (!environment.eql(previous.environment)) return error.IdentityMismatch;

    const bench = try hashFileIn(ctx.io, repo, bench_path, max_hashed_file_bytes);
    if (bench.bytes != previous.bench.bytes) return error.IdentityMismatch;
    if (!std.mem.eql(u8, &bench.sha256, &previous.bench.sha256)) return error.IdentityMismatch;

    // The comparison runs inside `recordArchive`, before any complete manifest
    // is written, so a mismatch cannot leave a published "reproduced" archive.
    const fresh = try recordArchive(ctx, bench_path, repo, command.new_dir, previous.options, opened.analysis);

    try ctx.out.print(
        "reproduced {s} as {s}: {d} inputs, {d} cases identical\n",
        .{ command.old_dir, command.new_dir, fresh.inputs.len, fresh.cases.len },
    );
}

fn fail(ctx: *Context, operation: []const u8, err: anyerror) noreturn {
    // Failure to write the diagnostic must still terminate with status 1.
    ctx.out.print(
        "{s} {s}: {s}\n",
        .{ program_name, operation, @errorName(err) },
    ) catch std.process.exit(1);
    ctx.out.flush() catch std.process.exit(1);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 4) {
        try out.writeAll(report.usage_text);
        try out.flush();
        std.process.exit(1);
    }

    // The operation is resolved before any build-provided path is touched, so
    // `verify` never depends on the current checkout or toolchain.
    const command = report.parseCommand(argv[3..]) catch |err| {
        try out.print("{s}: {s}\n", .{ program_name, @errorName(err) });
        try out.writeAll(report.usage_text);
        try out.flush();
        std.process.exit(1);
    };

    var ctx: Context = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = init.io,
        .environ = init.environ_map,
        .out = out,
    };

    switch (command) {
        .verify => |archive_path| runVerify(&ctx, archive_path) catch |err| fail(&ctx, "verify", err),
        .record => |record| runRecord(&ctx, argv[1], argv[2], record) catch |err| fail(&ctx, "record", err),
        .reproduce => |reproduce| {
            runReproduce(&ctx, argv[1], argv[2], reproduce) catch |err| fail(&ctx, "reproduce", err);
        },
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// Behavior tests.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn synthMix(a: u64, b: u64) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    hash = (hash ^ a) *% 0x100000001b3;
    hash = (hash ^ b) *% 0x100000001b3;
    return hash;
}

fn synthInputHash(format: report.Format, workload: report.Workload) u64 {
    return synthMix(@backingInt(format), @backingInt(workload));
}

fn synthChecksum(format: report.Format, workload: report.Workload, stage: report.Stage) u64 {
    return synthMix(synthInputHash(format, workload), @backingInt(stage));
}

// A synthetic capture is described by its inputs, not by a product of axes.
// Every mode prints one input declaration per `SynthInput` and then exactly
// the stages that input declares, so the same generator emits the legacy
// Cartesian capture - all 35 inputs, all six stages each - and a semantic
// capture of the declared fixture list, where a fixture that declares one
// stage has exactly one row.

/// One measured input of a synthetic capture: the declaration printed for it
/// and the rows that follow it.
const SynthInput = struct {
    format: report.Format,
    workload: report.Workload,
    /// The whole-source hash the declaration carries and every row of this
    /// input repeats.
    input_hash: u64,
    input_bytes: u64,
    /// The stages this input declares, in declared order.
    stages: []const report.Stage,
    /// The outcome its rows report. Only the semantic protocol has an outcome
    /// column, so a legacy input carries none.
    outcome: []const u8,
};

/// How many inputs a synthetic capture of this mode declares.
const synth_input_count = if (semantic_mode)
    semantic_input_count
else
    report.input_count;

/// The line a synthetic capture's first measured row occupies. The metadata
/// headers, the CSV header, and the first input declaration precede it, and
/// their number is the mode's own header count: twelve legacy headers and
/// eleven semantic ones.
const synth_first_row_line: usize = if (semantic_mode) 13 else 14;

/// The synthetic observations a semantic capture prints for its n-th case.
/// They live here so a test that rebuilds one row prints the numbers the row
/// it replaces printed.
fn synthObservation(case_index: usize) struct {
    elapsed_ns: u64,
    checksum: u64,
    allocation_count: u64,
    allocated_bytes: u64,
} {
    return .{
        .elapsed_ns = 1000 + case_index * 7,
        .checksum = 5000 + case_index,
        .allocation_count = 4 + case_index,
        .allocated_bytes = 512 + case_index * 64,
    };
}

/// Fills `out` with the inputs this mode's capture declares, in print order.
fn fillSynthInputs(out: []SynthInput) void {
    if (comptime semantic_mode) {
        var index: usize = 0;
        for (semantic_domain.segments) |segment| {
            for (segment.fixtures) |fixture| {
                const source_len: usize = fixture.source.len;
                out[index] = .{
                    .format = segment.format,
                    .workload = fixture.workload,
                    // The real fixture source, so the declaration carries the
                    // hash and the byte count the decoder checks it against.
                    .input_hash = semantic_contract.checksumBytes(fixture.source),
                    .input_bytes = @intCast(source_len),
                    .stages = fixture.stages,
                    .outcome = fixture.outcome,
                };
                index += 1;
            }
        }
        return;
    } else {
        var index: usize = 0;
        for (report.formats) |format| {
            for (report.workloads) |workload| {
                out[index] = .{
                    .format = format,
                    .workload = workload,
                    .input_hash = synthInputHash(format, workload),
                    .input_bytes = 128 + @as(u64, @backingInt(format)) * 16 + @as(u64, @backingInt(workload)),
                    .stages = &report.stages,
                    .outcome = "",
                };
                index += 1;
            }
        }
    }
}

/// The first declared input of a synthetic capture: the case the one-row
/// mutation tests rebuild.
fn firstSynthInput() SynthInput {
    var inputs: [synth_input_count]SynthInput = undefined;
    fillSynthInputs(&inputs);
    return inputs[0];
}

/// Emits exactly what this mode's bench prints for the given options.
///
/// Legacy: line 0 is `# zig_version`, line 12 is the CSV header, and the 210
/// rows occupy lines 14 through 257 inclusive, with input declarations
/// interleaved. Semantic: eleven metadata headers, the CSV header on line 11,
/// then one declaration and its declared rows for each declared fixture.
fn synthReport(allocator: Allocator, options: report.Options) ![]u8 {
    var inputs: [synth_input_count]SynthInput = undefined;
    fillSynthInputs(&inputs);

    var out: std.Io.Writer.Allocating = .init(allocator);
    // A capture that cannot be written still owns the buffer the builder has
    // already taken; `toOwnedSlice` empties it on the way out, so this only
    // fires on the failure paths.
    errdefer out.deinit();
    const writer = &out.writer;
    if (comptime semantic_mode) {
        try writer.writeAll("# zig_version=0.16.0\n");
        try writer.writeAll("# optimize=ReleaseFast\n");
        try writer.writeAll("# target_arch=x86_64\n");
        try writer.writeAll("# vector_len=32\n");
        try writer.print("# commonmark_profile={s}\n", .{report.commonmark_profile_version});
        try writer.print("# yaml_profile={s}\n", .{report.yaml_extended_profile_version});
        try writer.writeAll("# setup=fresh parse, named consumption, and destruction per iteration\n");
        // Exactly what the measurement executable prints. A synthetic capture
        // that claimed a whole-document checksum for every stage would assert
        // coverage the `parse` stage deliberately does not perform.
        try writer.writeAll(
            "# consumption=traverse consumes complete semantics; parse consumption is small by design\n",
        );
        try writer.writeAll("# render_html=safe mode: raw HTML omitted, dangerous URLs filtered\n");
        try writer.print("# streaming={s}\n", .{report.streaming_boundary_text});
        try writer.print("# ranking={s}\n", .{report.ranking_boundary_text});
        try writer.writeAll(report.csv_header);
        try writer.writeAll("\n");

        var case_index: usize = 0;
        for (inputs) |input| {
            try writer.print(
                "{s}format={s} workload={s} input_hash={x}\n",
                .{
                    report.input_declaration_prefix,
                    @tagName(input.format),
                    @tagName(input.workload),
                    input.input_hash,
                },
            );
            for (input.stages) |stage| {
                const observation = synthObservation(case_index);
                try writer.print("{s},{s},{s},{s},{d},{d},{d},{d},{d},{d}\n", .{
                    @tagName(input.format),
                    @tagName(input.workload),
                    @tagName(stage),
                    input.outcome,
                    input.input_bytes,
                    options.iterations,
                    observation.elapsed_ns,
                    observation.checksum,
                    observation.allocation_count,
                    observation.allocated_bytes,
                });
                case_index += 1;
            }
        }
        return out.toOwnedSlice();
    } else {
        try writer.writeAll("# zig_version=0.16.0\n");
        try writer.writeAll("# optimize=ReleaseFast\n");
        try writer.writeAll("# target_arch=x86_64\n");
        try writer.writeAll("# vector_len=32\n");
        try writer.print("# stream_chunk_bytes={d}\n", .{options.stream_chunk_size});
        try writer.print(
            "# stream_chunk_invocation=zig build bench -- --stream-chunk-size {d}\n",
            .{options.stream_chunk_size},
        );
        try writer.writeAll("# synthetic_scale=64\n");
        try writer.writeAll("# consumption=checksum samples\n");
        try writer.writeAll("# resident_setup=setup\n");
        try writer.writeAll("# resident_consumption=resident consumption\n");
        try writer.writeAll("# traverse_prefix8=first 8 events\n");
        try writer.writeAll("# baseline=baseline\n");
        try writer.writeAll(
            "format,workload,stage,input_bytes,iterations,elapsed_ns,checksum,allocation_count,allocated_bytes\n",
        );

        for (inputs) |input| {
            try writer.print(
                "# input format={s} workload={s} input_hash={x}\n",
                .{ @tagName(input.format), @tagName(input.workload), input.input_hash },
            );
            for (input.stages, 0..) |stage, stage_index| {
                try writer.print("{s},{s},{s},{d},{d},{d},{d},{d},{d}\n", .{
                    @tagName(input.format),
                    @tagName(input.workload),
                    @tagName(stage),
                    input.input_bytes,
                    options.iterations,
                    1000 + @as(u64, stage_index) * 7,
                    synthChecksum(input.format, input.workload, stage),
                    4 + @as(u64, stage_index),
                    512 + @as(u64, stage_index) * 64,
                });
            }
        }
        return out.toOwnedSlice();
    }
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

/// Decodes one capture of this mode. Legacy mode passes the option shape alone
/// because its domain is a compile-time constant inside its own decoder;
/// semantic mode passes the declared fixture list, because there the rows that
/// may exist are exactly the ones that domain declares.
fn analyzeCapture(allocator: Allocator, stdouts: []const []const u8, options: report.Options) !report.Analysis {
    return if (comptime semantic_mode)
        report.analyzeSamples(allocator, stdouts, options, semantic_domain)
    else
        report.analyzeSamples(allocator, stdouts, options);
}

fn expectReportError(text: []const u8, options: report.Options, expected: anyerror) !void {
    const single = [_][]const u8{text};
    if (analyzeCapture(testing.allocator, &single, options)) |analysis| {
        var owned = analysis;
        report.freeAnalysis(testing.allocator, &owned);
        return error.ExpectedRefusal;
    } else |err| {
        try testing.expectEqual(expected, err);
    }
}

/// Rebuilds the first measured row with selected columns changed, so a mutation
/// test varies exactly one fact at a time.
///
/// Legacy prints nine fields and has no outcome column; semantic prints the
/// observed outcome of the first declared fixture, which must agree with that
/// fixture's oracle for the row to be admissible at all.
fn firstRow(
    allocator: Allocator,
    options: report.Options,
    elapsed_ns: u64,
    checksum: u64,
    allocation_count: u64,
    input_bytes: u64,
) ![]u8 {
    if (comptime semantic_mode) {
        const input = firstSynthInput();
        return allocator.print(
            "{s},{s},{s},{s},{d},{d},{d},{d},{d},{d}\n",
            .{
                @tagName(input.format),
                @tagName(input.workload),
                @tagName(input.stages[0]),
                input.outcome,
                input_bytes,
                options.iterations,
                elapsed_ns,
                checksum,
                allocation_count,
                512,
            },
        );
    } else {
        return allocator.print(
            "json,fixture,index,{d},{d},{d},{d},{d},512\n",
            .{ input_bytes, options.iterations, elapsed_ns, checksum, allocation_count },
        );
    }
}

// The legacy decoder's own boundaries: its Cartesian domain, the columns only
// that bench prints, its command surface, and the captures it must refuse. The
// semantic decoder is exercised against the declared work domain where it
// lives, in `semantic_benchmark_report.zig`, so these stay with the facts they
// are about instead of being restated against a domain that has none of them.
//
// The tests are a container the mode selects, because Zig has no
// container-level `if` of its own. The other mode takes `struct {}` here, so
// it never resolves a legacy name at all.
const LegacyTests = if (semantic_mode) struct {} else struct {
    test "a canonical capture decodes to 35 inputs and 210 cases" {
        const options: report.Options = .{};
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);

        const samples = [_][]const u8{ text, text, text };
        var analysis = try report.analyzeSamples(testing.allocator, &samples, options);
        defer report.freeAnalysis(testing.allocator, &analysis);
        try testing.expectEqual(report.input_count, analysis.inputs.len);
        try testing.expectEqual(report.case_count, analysis.cases.len);
        try testing.expectEqualStrings("0.16.0", analysis.headers.zig_version);
        for (analysis.inputs, 0..) |entry, index| {
            try testing.expectEqual(report.formats[index / report.workloads.len], entry.format);
            try testing.expectEqual(report.workloads[index % report.workloads.len], entry.workload);
        }
        for (analysis.cases, 0..) |merged, index| {
            try testing.expectEqual(@as(usize, 3), merged.elapsed_ns.len);
            try testing.expectEqual(report.stages[index % report.stages.len], merged.stable.stage);
        }
    }

    test "an empty capture and an unterminated capture are refused" {
        const options: report.Options = .{ .samples = 1 };
        try expectReportError("", options, error.EmptyStdout);
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);
        try expectReportError(text[0 .. text.len - 1], options, error.MissingTrailingNewline);
    }

    test "a bare hash line is refused instead of reading past the line" {
        const options: report.Options = .{ .samples = 1 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);
        const patched = try replaceLine(testing.allocator, text, 0, "#");
        defer testing.allocator.free(patched);
        try expectReportError(patched, options, error.MalformedHeader);
    }

    test "unknown, duplicated, and missing headers are refused" {
        const options: report.Options = .{ .samples = 1 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);

        const unknown = try replaceLine(testing.allocator, text, 0, "# mystery=1");
        defer testing.allocator.free(unknown);
        try expectReportError(unknown, options, error.UnknownHeader);

        const duplicate = try replaceLine(
            testing.allocator,
            text,
            0,
            "# zig_version=0.16.0\n# zig_version=0.16.0",
        );
        defer testing.allocator.free(duplicate);
        try expectReportError(duplicate, options, error.DuplicateHeader);

        const missing = try dropLine(testing.allocator, text, 7);
        defer testing.allocator.free(missing);
        try expectReportError(missing, options, error.MissingHeader);
    }

    test "the measured option columns are pinned to the request" {
        const options: report.Options = .{ .samples = 1 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);

        const wrong_iterations = try replaceLine(
            testing.allocator,
            text,
            14,
            "json,fixture,index,128,9,1000,1,4,512",
        );
        defer testing.allocator.free(wrong_iterations);
        try expectReportError(wrong_iterations, options, error.WrongIterationCount);

        const wrong_chunk = try replaceLine(testing.allocator, text, 4, "# stream_chunk_bytes=1024");
        defer testing.allocator.free(wrong_chunk);
        try expectReportError(wrong_chunk, options, error.WrongChunkSize);

        const wrong_scale = try replaceLine(testing.allocator, text, 6, "# synthetic_scale=128");
        defer testing.allocator.free(wrong_scale);
        try expectReportError(wrong_scale, options, error.WrongSyntheticScale);
    }

    test "malformed, duplicate, missing, and unknown rows are refused" {
        const options: report.Options = .{ .samples = 1 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);

        const unknown_stage = try replaceLine(testing.allocator, text, 14, "json,fixture,bogus,128,3,1000,1,4,512");
        defer testing.allocator.free(unknown_stage);
        try expectReportError(unknown_stage, options, error.UnknownStage);

        const unknown_format = try replaceLine(testing.allocator, text, 14, "toml,fixture,index,128,3,1000,1,4,512");
        defer testing.allocator.free(unknown_format);
        try expectReportError(unknown_format, options, error.UnknownFormat);

        const short_row = try replaceLine(testing.allocator, text, 14, "json,fixture,index,128,3,1000,1,4");
        defer testing.allocator.free(short_row);
        try expectReportError(short_row, options, error.WrongFieldCount);

        const duplicate_row = try replaceLine(
            testing.allocator,
            text,
            15,
            "json,fixture,index,128,3,1000,1,4,512",
        );
        defer testing.allocator.free(duplicate_row);
        try expectReportError(duplicate_row, options, error.RowOrderMismatch);

        const dropped_row = try dropLine(testing.allocator, text, 19);
        defer testing.allocator.free(dropped_row);
        try expectReportError(dropped_row, options, error.DuplicateInputDeclaration);

        const dropped_declaration = try dropLine(testing.allocator, text, 251);
        defer testing.allocator.free(dropped_declaration);
        try expectReportError(dropped_declaration, options, error.MissingInputDeclaration);

        const dropped_last_row = try dropLine(testing.allocator, text, 257);
        defer testing.allocator.free(dropped_last_row);
        try expectReportError(dropped_last_row, options, error.TrailingInputDeclaration);
    }

    test "a trailing input declaration past the 35 inputs is refused" {
        const options: report.Options = .{ .samples = 1 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);
        const patched = try std.mem.concat(testing.allocator, u8, &.{
            text,
            "# input format=yaml workload=unicode input_hash=1\n",
        });
        defer testing.allocator.free(patched);
        try expectReportError(patched, options, error.TrailingInputDeclaration);
    }

    test "a partial sample set is refused rather than published as smaller evidence" {
        const options: report.Options = .{ .samples = 3 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);

        const two = [_][]const u8{ text, text };
        try testing.expectError(
            error.SampleCountMismatch,
            report.analyzeSamples(testing.allocator, &two, options),
        );

        const one = [_][]const u8{text};
        try testing.expectError(
            error.SampleCountMismatch,
            report.analyzeSamples(testing.allocator, &one, options),
        );
    }

    test "work-profile drift between samples is refused" {
        const options: report.Options = .{ .samples = 2 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);
        const drifted = try replaceLine(testing.allocator, text, 7, "# consumption=a different profile");
        defer testing.allocator.free(drifted);

        const samples = [_][]const u8{ text, drifted };
        try testing.expectError(
            error.UnstableResults,
            report.analyzeSamples(testing.allocator, &samples, options),
        );
    }

    const first_checksum = synthChecksum(.json, .fixture, .index);

    test "checksum and allocation drift between samples is refused" {
        const options: report.Options = .{ .samples = 2 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);

        const checksum_row = try firstRow(testing.allocator, options, 1000, first_checksum + 1, 4, 128);
        defer testing.allocator.free(checksum_row);
        const drifted_checksum = try replaceLine(testing.allocator, text, 14, checksum_row);
        defer testing.allocator.free(drifted_checksum);

        const allocation_row = try firstRow(testing.allocator, options, 1000, first_checksum, 5, 128);
        defer testing.allocator.free(allocation_row);
        const drifted_allocations = try replaceLine(testing.allocator, text, 14, allocation_row);
        defer testing.allocator.free(drifted_allocations);

        const checksum_pair = [_][]const u8{ text, drifted_checksum };
        try testing.expectError(
            error.UnstableResults,
            report.analyzeSamples(testing.allocator, &checksum_pair, options),
        );

        const allocation_pair = [_][]const u8{ text, drifted_allocations };
        try testing.expectError(
            error.UnstableResults,
            report.analyzeSamples(testing.allocator, &allocation_pair, options),
        );
    }

    test "a row that disagrees with its own input is refused as malformed" {
        const options: report.Options = .{ .samples = 2 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);
        const row = try firstRow(testing.allocator, options, 1000, first_checksum, 4, 129);
        defer testing.allocator.free(row);
        const drifted = try replaceLine(testing.allocator, text, 14, row);
        defer testing.allocator.free(drifted);

        const samples = [_][]const u8{ text, drifted };
        try testing.expectError(
            error.InconsistentInputBytes,
            report.analyzeSamples(testing.allocator, &samples, options),
        );
    }

    test "a different input hash across samples is refused" {
        const options: report.Options = .{ .samples = 2 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);
        const drifted = try replaceLine(
            testing.allocator,
            text,
            13,
            "# input format=json workload=fixture input_hash=deadbeef",
        );
        defer testing.allocator.free(drifted);

        const samples = [_][]const u8{ text, drifted };
        try testing.expectError(
            error.UnstableResults,
            report.analyzeSamples(testing.allocator, &samples, options),
        );
    }

    test "timings are retained but never decide equality" {
        const options: report.Options = .{ .samples = 2 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);
        const faster_row = try firstRow(testing.allocator, options, 1, first_checksum, 4, 128);
        defer testing.allocator.free(faster_row);
        const faster = try replaceLine(testing.allocator, text, 14, faster_row);
        defer testing.allocator.free(faster);

        const samples = [_][]const u8{ text, faster };
        var analysis = try report.analyzeSamples(testing.allocator, &samples, options);
        defer report.freeAnalysis(testing.allocator, &analysis);
        try testing.expectEqual(@as(u64, 1000), analysis.cases[0].elapsed_ns[0]);
        try testing.expectEqual(@as(u64, 1), analysis.cases[0].elapsed_ns[1]);
        try testing.expectEqual(first_checksum, analysis.cases[0].stable.checksum);
    }

    test "a full-width checksum is decoded without narrowing" {
        const options: report.Options = .{ .samples = 1 };
        const text = try synthReport(testing.allocator, options);
        defer testing.allocator.free(text);
        const wide_row = try firstRow(testing.allocator, options, 1000, std.math.maxInt(u64), 4, 128);
        defer testing.allocator.free(wide_row);
        const patched = try replaceLine(testing.allocator, text, 14, wide_row);
        defer testing.allocator.free(patched);

        var analysis = try report.analyzeSamples(testing.allocator, &.{patched}, options);
        defer report.freeAnalysis(testing.allocator, &analysis);
        try testing.expectEqual(std.math.maxInt(u64), analysis.cases[0].stable.checksum);
    }

    test "invalid operation lines are refused" {
        try testing.expectError(error.MissingOperation, report.parseCommand(&.{}));
        try testing.expectError(error.UnknownOperation, report.parseCommand(&.{"compare"}));
        try testing.expectError(error.MissingOutputDirectory, report.parseCommand(&.{"record"}));
        try testing.expectError(error.MissingFlagValue, report.parseCommand(&.{ "record", "out", "--samples" }));
        try testing.expectError(
            error.SampleCountOutOfRange,
            report.parseCommand(&.{ "record", "out", "--samples", "0" }),
        );
        try testing.expectError(
            error.SampleCountOutOfRange,
            report.parseCommand(&.{ "record", "out", "--samples", "33" }),
        );
        try testing.expectError(error.NotANumber, report.parseCommand(&.{ "record", "out", "--samples", "many" }));
        try testing.expectError(
            error.IterationCountOutOfRange,
            report.parseCommand(&.{ "record", "out", "--iterations", "0" }),
        );
        try testing.expectError(
            error.IterationCountOutOfRange,
            report.parseCommand(&.{ "record", "out", "--iterations", "64" }),
        );
        try testing.expectError(
            error.UnsupportedChunkSize,
            report.parseCommand(&.{ "record", "out", "--stream-chunk-size", "128" }),
        );
        try testing.expectError(
            error.DuplicateFlag,
            report.parseCommand(&.{ "record", "out", "--samples", "2", "--samples", "3" }),
        );
        try testing.expectError(error.UnknownFlag, report.parseCommand(&.{ "record", "out", "--depth", "2" }));
        try testing.expectError(error.ExtraArguments, report.parseCommand(&.{"verify"}));
        try testing.expectError(error.ExtraArguments, report.parseCommand(&.{ "verify", "a", "b" }));
        try testing.expectError(error.ExtraArguments, report.parseCommand(&.{ "reproduce", "only-one" }));
    }
};

comptime {
    // A test belongs to the build only in a container this compilation
    // analyzes, and nothing else names this one.
    testing.refAllDecls(LegacyTests);
}

test "archive-relative paths are validated before use" {
    try testing.expect(isSafeRelativePath("manifest.json"));
    try testing.expect(isSafeRelativePath("sources/src/root.zig"));
    try testing.expect(!isSafeRelativePath(""));
    try testing.expect(!isSafeRelativePath("/etc/passwd"));
    try testing.expect(!isSafeRelativePath("../escape"));
    try testing.expect(!isSafeRelativePath("sources/../../escape"));
    try testing.expect(!isSafeRelativePath("sources//root.zig"));
    try testing.expect(!isSafeRelativePath("./sources"));
    try testing.expect(!isSafeRelativePath("sources\\root.zig"));
}

// ---------------------------------------------------------------------------
// Archive behavior tests.
//
// Each case builds a real archive on disk and re-reads it through the same
// offline path `verify` uses, so these exercise observable archive behavior
// rather than the shape of the code that produced it.
// ---------------------------------------------------------------------------

/// The archive tests own a real arena so every scratch allocation the
/// archive path makes is released at test end.
const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    io: Io,

    fn init() TestContext {
        return .{ .arena = .init(testing.allocator), .gpa = testing.allocator, .io = testing.io };
    }

    fn deinit(self: *TestContext) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn context(self: *TestContext) Context {
        return .{
            .gpa = self.gpa,
            .arena = self.arena.allocator(),
            .io = self.io,
            .environ = null,
            // SAFETY: only `main` reports through `out`, and no test enters it:
            // every path these tests take returns its result to the caller.
            .out = undefined,
        };
    }
};

const synthetic_source_paths = [_][]const u8{ "bench.zig", "src/root.zig" };
const synthetic_bench_image = "simd-bench-image";

fn syntheticToolchain() ToolchainFacts {
    return .{
        .zig_basename = "zig",
        .zig_version = "0.16.0",
        .zig_sha256 = zero_digest,
        .zig_bytes = 1,
        .bench_target = "x86_64-linux-gnu",
        .bench_cpu = "x86_64+avx2",
        .bench_optimize = "ReleaseFast",
        .bench_vector_len = 32,
    };
}

fn syntheticHost() HostFacts {
    return .{
        .os = "linux",
        .arch = "x86_64",
        .cpu_model = "Synthetic CPU",
        .cpu_vendor = "GenuineIntel",
        .cpu_features = "avx2 fma",
        .cpu_processors = 8,
        .cpus_allowed_list = "0-7",
        .affinity_ranges = "0-7",
        .affinity_cpu_count = 8,
        .cpu_mhz_observed = 2000,
    };
}

fn overwrite(ctx: *Context, dir: Io.Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(ctx.io, .{ .sub_path = path, .data = data, .flags = .{} });
}

fn buildSyntheticArchive(ctx: *Context, dir: Io.Dir, status: []const u8) !Manifest {
    return buildSyntheticArchiveWith(ctx, dir, status, try synthReport(ctx.arena, .{ .samples = 1 }));
}

fn buildSyntheticArchiveWith(ctx: *Context, dir: Io.Dir, status: []const u8, text: []const u8) !Manifest {
    const options: report.Options = .{ .samples = 1 };

    try dir.createDirPath(ctx.io, bench_subdir);
    try dir.createDirPath(ctx.io, samples_subdir);
    try dir.createDirPath(ctx.io, sources_subdir);

    const sources = try ctx.arena.alloc(SourceEntry, synthetic_source_paths.len);
    for (synthetic_source_paths, 0..) |path, index| {
        const body = if (index == 0) "alpha source" else "beta source";
        const archived = try joinPath(ctx.arena, &.{ sources_subdir, path });
        if (std.fs.path.dirname(archived)) |parent| try dir.createDirPath(ctx.io, parent);
        try writeExclusive(ctx.io, dir, archived, body);
        sources[index] = .{ .path = path, .bytes = body.len, .sha256 = sha256Hex(body) };
    }

    try writeExclusive(ctx.io, dir, bench_archive_path, synthetic_bench_image);

    const stdout_path = try sampleName(ctx.arena, "stdout", 1);
    const stderr_path = try sampleName(ctx.arena, "stderr", 1);
    try writeExclusive(ctx.io, dir, stdout_path, text);
    try writeExclusive(ctx.io, dir, stderr_path, "");

    var manifest = emptyManifest(options);
    manifest.status = status;
    manifest.reason = if (std.mem.eql(u8, status, status_complete)) "" else "BenchExitedNonzero";
    manifest.created_utc = "2026-10-01T00:00:00Z";
    manifest.sources = sources;
    manifest.source_identity = sourceIdentityDigest(sources);
    manifest.bench = digestOf(synthetic_bench_image);
    manifest.samples = try ctx.arena.alloc(SampleRecord, 1);
    manifest.samples[0] = .{
        .index = 1,
        .stdout_path = stdout_path,
        .stdout_bytes = text.len,
        .stdout_sha256 = sha256Hex(text),
        .stderr_path = stderr_path,
        .stderr_bytes = 0,
        .stderr_sha256 = sha256Hex(""),
        .term_kind = .exited,
        .term_value = 0,
    };
    manifest.toolchain = syntheticToolchain();
    manifest.host = syntheticHost();
    manifest.environment = .{ .lang = null, .lc_all = null, .tz = null };
    if (std.mem.eql(u8, status, status_complete)) {
        manifest.analysis = try analyzeCapture(ctx.arena, &.{text}, options);
    }
    return manifest;
}

fn replaceAll(allocator: Allocator, text: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, needle) orelse return error.NeedleMissing;
    return std.mem.concat(allocator, u8, &.{ text[0..at], replacement, text[at + needle.len ..] });
}

fn loadWrittenManifest(ctx: *Context, dir: Io.Dir) !LoadedArchive {
    const raw = try readArchived(ctx.gpa, ctx.io, dir, manifest_name, max_manifest_bytes);
    defer ctx.gpa.free(raw);
    return loadManifest(ctx.arena, raw);
}

/// Writes `manifest` with the first occurrence of `needle` replaced by
/// `replacement`. The archive keeps the real captures it was built from, so
/// every forged manifest starts from an archive that would otherwise verify.
fn writeForgedManifest(
    ctx: *Context,
    dir: Io.Dir,
    manifest: *const Manifest,
    needle: []const u8,
    replacement: []const u8,
) !void {
    var allocating: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer allocating.deinit();
    var json: JsonWriter = .{ .writer = &allocating.writer };
    try writeManifest(&json, manifest);
    const patched = try replaceAll(ctx.gpa, allocating.written(), needle, replacement);
    defer ctx.gpa.free(patched);
    try overwrite(ctx, dir, manifest_name, patched);
}

test "a well-formed archive verifies from its own bytes" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);
    try writeManifestFile(&ctx, tmp.dir, &manifest);

    var loaded = try loadWrittenManifest(&ctx, tmp.dir);
    const analysis = try verifyArchive(&ctx, tmp.dir, &loaded);
    try testing.expectEqual(expected_work_counts.inputs, analysis.inputs.len);
    try testing.expectEqual(expected_work_counts.cases, analysis.cases.len);
    try testing.expectEqual(@as(usize, 1), loaded.manifest.samples.len);
}

test "a corrupted source snapshot fails verification" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);
    try writeManifestFile(&ctx, tmp.dir, &manifest);
    // Same byte count, different content: the size check cannot catch this, so
    // only the content digest can.
    try overwrite(&ctx, tmp.dir, "sources/bench.zig", "alpha s0urce");

    var loaded = try loadWrittenManifest(&ctx, tmp.dir);
    try testing.expectError(error.HashMismatch, verifyArchive(&ctx, tmp.dir, &loaded));
}

test "a tampered raw sample output fails verification" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);
    try writeManifestFile(&ctx, tmp.dir, &manifest);
    try overwrite(&ctx, tmp.dir, "samples/sample-01.stdout", "format,workload\n");

    var loaded = try loadWrittenManifest(&ctx, tmp.dir);
    try testing.expectError(error.SizeMismatch, verifyArchive(&ctx, tmp.dir, &loaded));
}

test "a swapped benchmark artifact fails verification" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);
    try writeManifestFile(&ctx, tmp.dir, &manifest);
    try overwrite(&ctx, tmp.dir, bench_archive_path, "SIMD-bench-image");

    var loaded = try loadWrittenManifest(&ctx, tmp.dir);
    try testing.expectError(error.HashMismatch, verifyArchive(&ctx, tmp.dir, &loaded));
}

test "an unexpected file inside the archive fails verification" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);
    try writeManifestFile(&ctx, tmp.dir, &manifest);
    try overwrite(&ctx, tmp.dir, "notes.txt", "not part of the evidence");

    var loaded = try loadWrittenManifest(&ctx, tmp.dir);
    try testing.expectError(error.UnexpectedArchiveFile, verifyArchive(&ctx, tmp.dir, &loaded));
}

test "an archive whose manifest is a symlink is refused" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var wrapper = testing.tmpDir(.{});
    defer wrapper.cleanup();

    try wrapper.dir.createDirPath(ctx.io, "archive");
    var archive = try wrapper.dir.openDir(ctx.io, "archive", .{ .iterate = true });
    defer archive.close(ctx.io);

    const manifest = try buildSyntheticArchive(&ctx, archive, status_complete);
    var allocating: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer allocating.deinit();
    var json: JsonWriter = .{ .writer = &allocating.writer };
    try writeManifest(&json, &manifest);

    // The link resolves to a manifest that would load and verify exactly as
    // written, so refusing to follow a link is the only thing that can reject
    // this archive.
    try writeExclusive(ctx.io, wrapper.dir, "real-manifest.json", allocating.written());
    try wrapper.dir.symLink(ctx.io, "../real-manifest.json", "archive/manifest.json", .{});

    try testing.expectError(error.SymlinkInArchive, loadWrittenManifest(&ctx, archive));
}

test "a source payload replaced by a symlink is refused" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var wrapper = testing.tmpDir(.{});
    defer wrapper.cleanup();

    try wrapper.dir.createDirPath(ctx.io, "archive");
    var archive = try wrapper.dir.openDir(ctx.io, "archive", .{ .iterate = true });
    defer archive.close(ctx.io);

    const manifest = try buildSyntheticArchive(&ctx, archive, status_complete);
    try writeManifestFile(&ctx, archive, &manifest);
    var loaded = try loadWrittenManifest(&ctx, archive);

    // The link resolves to byte-identical evidence outside the archive, so every
    // digest would agree if the link were followed: the archive's own file set
    // is what has to refuse it.
    try overwrite(&ctx, wrapper.dir, "real-source.txt", "alpha source");
    try archive.deleteFile(ctx.io, "sources/bench.zig");
    try archive.symLink(ctx.io, "../../real-source.txt", "sources/bench.zig", .{});

    try testing.expectError(error.SymlinkInArchive, verifyArchive(&ctx, archive, &loaded));
}

test "a forged successful sample termination is refused" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);

    // Both forgeries leave the capture decoding to the recorded analysis, so
    // only the termination status makes them unacceptable as evidence.
    try writeForgedManifest(&ctx, tmp.dir, &manifest, "\"term_value\":0", "\"term_value\":3");
    var nonzero = try loadWrittenManifest(&ctx, tmp.dir);
    try testing.expectError(error.BenchExitedNonzero, verifyArchive(&ctx, tmp.dir, &nonzero));

    try writeForgedManifest(
        &ctx,
        tmp.dir,
        &manifest,
        "\"terminated\":\"exited\"",
        "\"terminated\":\"signal\"",
    );
    var signalled = try loadWrittenManifest(&ctx, tmp.dir);
    try testing.expectError(error.BenchTerminated, verifyArchive(&ctx, tmp.dir, &signalled));
}

test "a per-case timing that contradicts the archived capture is refused" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);

    // A timing is an observation and never an identity, so this forgery agrees
    // with every equality check; only re-deriving the value from the archive's
    // own capture can catch it. The array below is the first case's.
    const analysis = manifest.analysis orelse return error.MissingAnalysis;
    const recorded = analysis.cases[0].elapsed_ns[0];
    const honest = try ctx.gpa.print("[{d}]", .{recorded});
    defer ctx.gpa.free(honest);
    const forged = try ctx.gpa.print("[{d}]", .{recorded + 1});
    defer ctx.gpa.free(forged);
    try writeForgedManifest(&ctx, tmp.dir, &manifest, honest, forged);

    var loaded = try loadWrittenManifest(&ctx, tmp.dir);
    const reloaded = loaded.manifest.analysis orelse return error.MissingAnalysis;
    try testing.expectEqual(recorded + 1, reloaded.cases[0].elapsed_ns[0]);
    try testing.expectError(error.ManifestIncomplete, verifyArchive(&ctx, tmp.dir, &loaded));
}

test "a per-case timing array that is not one entry per sample is refused" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);

    // The first case's array must carry one entry per recorded sample, or the
    // timings it claims are not observations of that many captures.
    const analysis = manifest.analysis orelse return error.MissingAnalysis;
    const recorded = analysis.cases[0].elapsed_ns[0];
    const honest = try ctx.gpa.print("[{d}]", .{recorded});
    defer ctx.gpa.free(honest);
    const padded = try ctx.gpa.print("[{d},{d}]", .{ recorded, recorded });
    defer ctx.gpa.free(padded);
    try writeForgedManifest(&ctx, tmp.dir, &manifest, honest, padded);

    try testing.expectError(error.ManifestIncomplete, loadWrittenManifest(&ctx, tmp.dir));
}

test "a failed archive is never verified as complete" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_failed);
    try writeManifestFile(&ctx, tmp.dir, &manifest);

    var loaded = try loadWrittenManifest(&ctx, tmp.dir);
    try testing.expectEqualStrings(status_failed, loaded.manifest.status);
    try testing.expectError(error.ManifestFailedStatus, verifyArchive(&ctx, tmp.dir, &loaded));
}

test "a traversing source path is refused before the archive is read" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);
    var allocating: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer allocating.deinit();
    var json: JsonWriter = .{ .writer = &allocating.writer };
    try writeManifest(&json, &manifest);

    const patched = try replaceAll(
        ctx.gpa,
        allocating.written(),
        "\"path\":\"bench.zig\"",
        "\"path\":\"../../etc/passwd\"",
    );
    defer ctx.gpa.free(patched);
    try writeExclusive(ctx.io, tmp.dir, manifest_name, patched);

    try testing.expectError(error.UnsafeArchivePath, loadWrittenManifest(&ctx, tmp.dir));
}

test "a manifest for a different schema is refused" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);
    var allocating: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer allocating.deinit();
    var json: JsonWriter = .{ .writer = &allocating.writer };
    try writeManifest(&json, &manifest);

    const patched = try replaceAll(ctx.gpa, allocating.written(), "\"schema_version\":1", "\"schema_version\":2");
    defer ctx.gpa.free(patched);
    try writeExclusive(ctx.io, tmp.dir, manifest_name, patched);

    try testing.expectError(error.ManifestSchemaMismatch, loadWrittenManifest(&ctx, tmp.dir));
}

test "an existing archive directory is refused and left untouched" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const suffix_len = std.base64.url_safe.Encoder.calcSize(12);
    const nested = try testing.allocator.print(
        ".zig-cache/tmp/{s}/a/b/archive",
        .{tmp.sub_path[0..suffix_len]},
    );
    defer testing.allocator.free(nested);

    // A nested path must land exactly where it was asked for, not beside the
    // working directory under its leaf name.
    var created = try createArchiveDirExclusive(testing.io, nested);
    created.close(testing.io);
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, "archive", .{ .follow_symlinks = false }),
    );

    {
        var opened = try Io.Dir.cwd().openDir(testing.io, nested, .{});
        defer opened.close(testing.io);
        try opened.writeFile(testing.io, .{
            .sub_path = "sentinel",
            .data = "original evidence",
            .flags = .{},
        });
    }

    try testing.expectError(error.PathAlreadyExists, createArchiveDirExclusive(testing.io, nested));

    const reopened = try Io.Dir.cwd().openDir(testing.io, nested, .{});
    defer reopened.close(testing.io);
    const content = try readArchived(testing.allocator, testing.io, reopened, "sentinel", 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("original evidence", content);
}

test "a failed recording persists its status and reason" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const suffix_len = std.base64.url_safe.Encoder.calcSize(12);
    const out_dir = try ctx.arena.print(
        ".zig-cache/tmp/{s}/failed-record",
        .{tmp.sub_path[0..suffix_len]},
    );

    // An empty repository cannot be recorded: the source snapshot it must
    // capture does not exist, so the run stops before any sample.
    const options: report.Options = if (comptime semantic_mode)
        .{ .samples = 1, .iterations = 1 }
    else
        .{ .samples = 1, .iterations = 1, .stream_chunk_size = 4096 };
    if (recordArchive(&ctx, "no-such-bench", tmp.dir, out_dir, options, null)) |_| {
        return error.ExpectedFailure;
    } else |_| {}

    // The captures the run did produce stay, and the archive says it failed.
    var archive = try openArchiveDir(ctx.io, out_dir);
    defer archive.close(ctx.io);
    const loaded = try loadWrittenManifest(&ctx, archive);
    try testing.expectEqualStrings(status_failed, loaded.manifest.status);
    try testing.expect(loaded.manifest.reason.len > 0);
    try testing.expect(loaded.manifest.analysis == null);
}

test "an existing archive file is never truncated" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(ctx.io, sources_subdir);
    try writeExclusive(ctx.io, tmp.dir, "sources/bench.zig", "original evidence");
    try testing.expectError(
        error.ArchiveEntryExists,
        writeExclusive(ctx.io, tmp.dir, "sources/bench.zig", "replacement"),
    );

    const content = try readFileBounded(ctx.gpa, ctx.io, tmp.dir, "sources/bench.zig", 1024);
    defer ctx.gpa.free(content);
    try testing.expectEqualStrings("original evidence", content);
}

test "an archive keeps a full-width checksum exact through its manifest" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const capture_options: report.Options = .{ .samples = 1 };
    const base = try synthReport(ctx.arena, capture_options);
    const capture = try replaceLine(
        ctx.arena,
        base,
        synth_first_row_line,
        try firstRow(
            ctx.arena,
            capture_options,
            1000,
            std.math.maxInt(u64),
            4,
            firstSynthInput().input_bytes,
        ),
    );

    const manifest = try buildSyntheticArchiveWith(&ctx, tmp.dir, status_complete, capture);
    try writeManifestFile(&ctx, tmp.dir, &manifest);

    const raw = try readFileBounded(ctx.gpa, ctx.io, tmp.dir, manifest_name, max_manifest_bytes);
    defer ctx.gpa.free(raw);
    const loaded = try loadManifest(ctx.arena, raw);
    const loaded_analysis = loaded.manifest.analysis orelse return error.MissingAnalysis;
    try testing.expectEqual(
        std.math.maxInt(u64),
        loaded_analysis.cases[0].stable.checksum,
    );

    const analysis = try verifyArchive(&ctx, tmp.dir, &loaded);
    try testing.expectEqual(std.math.maxInt(u64), analysis.cases[0].stable.checksum);
}

test "nested library directories keep their separators in the snapshot" {
    var tc = TestContext.init();
    defer tc.deinit();
    var ctx = tc.context();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // A real nested tree, not a hand-built entry list: the regression is the
    // directory walk itself.
    try tmp.dir.createDirPath(ctx.io, "src/core");
    try tmp.dir.createDirPath(ctx.io, "src/formats");
    try overwrite(&ctx, tmp.dir, "src/root.zig", "root");
    try overwrite(&ctx, tmp.dir, "src/core/simd.zig", "core");
    try overwrite(&ctx, tmp.dir, "src/formats/json.zig", "json");
    try overwrite(&ctx, tmp.dir, "src/notes.txt", "not a Zig source");

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(ctx.arena);
    try collectLibrarySources(ctx.arena, ctx.io, tmp.dir, library_source_dir, 0, &paths);

    try testing.expectEqual(@as(usize, 3), paths.items.len);
    try testing.expectEqualStrings("src/core/simd.zig", paths.items[0]);
    try testing.expectEqualStrings("src/formats/json.zig", paths.items[1]);
    try testing.expectEqualStrings("src/root.zig", paths.items[2]);

    // Every collected path must name a file that exists, because `record`
    // hashes each one before it can be copied into the archive.
    for (paths.items) |path| {
        const digest = try hashFileIn(ctx.io, tmp.dir, path, max_hashed_file_bytes);
        try testing.expect(digest.bytes > 0);
    }
}

// The semantic archive boundaries this runtime owns. What the semantic decoder
// does to one report is tested where the decoder lives; what this runtime does
// with a semantic archive is tested here: that the observed outcome survives
// into the manifest and is compared on verification, that a capture whose
// profile or row order is not the declared measurement cannot be published
// under its name, and that the whole load releases what it took.
//
// This container is selected the way the legacy tests above are: the legacy
// compilation takes `struct {}` here and never resolves a semantic name.
const SemanticTests = if (semantic_mode) struct {
    /// Replaces the archived capture with `text` and re-records its digest, so
    /// the archive's own bytes stay internally consistent and the check that
    /// fails is the decoder reading them rather than a checksum mismatch.
    fn replaceArchivedCapture(
        ctx: *Context,
        dir: Io.Dir,
        manifest: *const Manifest,
        text: []const u8,
    ) !void {
        try overwrite(ctx, dir, "samples/sample-01.stdout", text);
        const honest = try ctx.gpa.print(
            "\"stdout_bytes\":{d},\"stdout_sha256\":\"{s}\"",
            .{ manifest.samples[0].stdout_bytes, &manifest.samples[0].stdout_sha256 },
        );
        defer ctx.gpa.free(honest);
        const forged = try ctx.gpa.print(
            "\"stdout_bytes\":{d},\"stdout_sha256\":\"{s}\"",
            .{ text.len, &sha256Hex(text) },
        );
        defer ctx.gpa.free(forged);
        try writeForgedManifest(ctx, dir, manifest, honest, forged);
    }

    /// The index of the first case in `analysis` whose recorded outcome is
    /// `outcome`.
    ///
    /// A manifest forgery rewrites the first textual occurrence of a substring,
    /// and the cases are written in the order `analysis.cases` holds them, so
    /// this is the one row the forgery relabels. Naming the row here is what
    /// makes the assertion below a proof that the substitution reached the
    /// file: asserting on any other index would hold just as well if the file
    /// had been written untouched, because that row would already carry the
    /// outcome the forgery was supposed to install.
    fn firstCaseWithOutcome(analysis: report.Analysis, outcome: []const u8) ?usize {
        for (analysis.cases, 0..) |merged, index| {
            if (std.mem.eql(u8, merged.stable.outcome, outcome)) return index;
        }
        return null;
    }

    test "a recorded outcome that contradicts the archive's own capture is refused" {
        var tc = TestContext.init();
        defer tc.deinit();
        var ctx = tc.context();
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        const manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);
        try writeManifestFile(&ctx, tmp.dir, &manifest);

        // The captures are untouched. Only the manifest's own account of what
        // the first case observed changes, and every other recorded fact -
        // checksums, allocations, and the timings that are never an identity -
        // still agrees with the archive, so nothing but the outcome can
        // reject this.
        try writeForgedManifest(
            &ctx,
            tmp.dir,
            &manifest,
            "\"outcome\":\"accepted\"",
            "\"outcome\":\"TooManyNodes\"",
        );

        var relabeled_accepted = try loadWrittenManifest(&ctx, tmp.dir);
        const accepted_analysis = relabeled_accepted.manifest.analysis orelse return error.MissingAnalysis;
        try testing.expectEqualStrings(
            "TooManyNodes",
            accepted_analysis.cases[0].stable.outcome,
        );
        try testing.expectError(
            error.ManifestIncomplete,
            verifyArchive(&ctx, tmp.dir, &relabeled_accepted),
        );

        // The other direction: a resource fixture may not be recorded as one
        // the parser accepted. The needle is the first such row in the file,
        // so it is that row and not a fixed index that has to change.
        const manifest_analysis = manifest.analysis orelse return error.MissingAnalysis;
        const resource_case = firstCaseWithOutcome(manifest_analysis, "InputTooLarge") orelse
            return error.NoResourceCase;
        try testing.expectEqualStrings(
            "InputTooLarge",
            manifest_analysis.cases[resource_case].stable.outcome,
        );
        try writeForgedManifest(
            &ctx,
            tmp.dir,
            &manifest,
            "\"outcome\":\"InputTooLarge\"",
            "\"outcome\":\"accepted\"",
        );

        var relabeled_rejected = try loadWrittenManifest(&ctx, tmp.dir);
        const rejected_analysis = relabeled_rejected.manifest.analysis orelse return error.MissingAnalysis;
        try testing.expectEqualStrings(
            "accepted",
            rejected_analysis.cases[resource_case].stable.outcome,
        );
        try testing.expectError(
            error.ManifestIncomplete,
            verifyArchive(&ctx, tmp.dir, &relabeled_rejected),
        );
    }

    test "a capture from another measured profile cannot be published under this archive" {
        var tc = TestContext.init();
        defer tc.deinit();
        var ctx = tc.context();
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        const manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);
        try writeManifestFile(&ctx, tmp.dir, &manifest);

        // The profile is the measurement's identity. A capture from another
        // CommonMark revision is a different measurement, not a faster or
        // slower run of this one, so it is refused rather than compared.
        const capture = try replaceAll(
            ctx.gpa,
            try synthReport(ctx.arena, .{ .samples = 1 }),
            report.commonmark_profile_version,
            "0.30.0",
        );
        defer ctx.gpa.free(capture);
        try replaceArchivedCapture(&ctx, tmp.dir, &manifest, capture);

        var loaded = try loadWrittenManifest(&ctx, tmp.dir);
        try testing.expectError(error.ProfileMismatch, verifyArchive(&ctx, tmp.dir, &loaded));
    }

    test "a capture whose rows are not in the declared order cannot be published" {
        var tc = TestContext.init();
        defer tc.deinit();
        var ctx = tc.context();
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        const manifest = try buildSyntheticArchive(&ctx, tmp.dir, status_complete);
        try writeManifestFile(&ctx, tmp.dir, &manifest);

        // `cm_blocks` declares parse, then traverse, then render_html. A
        // traverse row where the parse row belongs describes different work,
        // whatever else it agrees about.
        const capture = try replaceAll(
            ctx.gpa,
            try synthReport(ctx.arena, .{ .samples = 1 }),
            "commonmark,cm_blocks,parse,accepted,",
            "commonmark,cm_blocks,traverse,accepted,",
        );
        defer ctx.gpa.free(capture);
        try replaceArchivedCapture(&ctx, tmp.dir, &manifest, capture);

        var loaded = try loadWrittenManifest(&ctx, tmp.dir);
        try testing.expectError(error.RowOrderMismatch, verifyArchive(&ctx, tmp.dir, &loaded));
    }

    /// The capture is built through `std.Io.Writer.Allocating`, whose writer
    /// reports a failed allocation as `error.WriteFailed` because a write can
    /// also fail at the sink. This builder writes to memory only, so an
    /// allocation failure is the one way it fails, and the failure injection
    /// understands `error.OutOfMemory` alone. Restating the builder's failure
    /// as the allocation error it is lets the injection reach every allocation
    /// a decode makes instead of abandoning the run on the first one inside
    /// the builder. The switch covers the builder's whole error set, so no
    /// refusal of a decode passes through this mapping and a failure mode the
    /// builder grows later has to be stated here rather than pass unnoticed.
    fn captureForInjection(allocator: Allocator, options: report.Options) Allocator.Error![]u8 {
        const text = synthReport(allocator, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return error.OutOfMemory,
        };
        return text;
    }

    /// A complete semantic load and offline verification under a failing
    /// allocator must release exactly what it had already taken.
    ///
    /// The load runs on the raw injected allocator, with nothing in front of
    /// it: every copy the manifest reader takes - the sample, source, toolchain,
    /// host, and environment paths, the header copies, the decoded inputs and
    /// cases, and each case's timing slice - has to come back on its own, both
    /// at the injection point that failed and on the run that succeeded. An
    /// arena between the injector and the load would prove nothing of that:
    /// its free is a no-op, so a release defect anywhere inside the load is
    /// handed back wholesale at teardown and the sweep would only report that
    /// the arena balanced.
    ///
    /// Two phases are arena-scoped by construction and are not part of that
    /// claim. Building the archive is this sweep's input rather than its
    /// subject, and `verifyArchive` keeps the archive's raw captures and the
    /// analysis it recomputes in the context arena for as long as the context
    /// lives. A fault in either proves that the phase unwinds to that arena and
    /// nothing finer. Both still allocate through the injected allocator, so a
    /// refusal in either is still an injection point.
    fn loadVerifyAndRelease(allocator: Allocator) !void {
        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        var ctx: Context = .{
            .gpa = allocator,
            .arena = arena_state.allocator(),
            .io = testing.io,
            .environ = null,
            // SAFETY: only `main` reports through `out`, and this helper calls
            // no reporting path: both phases return their own result.
            .out = undefined,
        };
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        const capture = try captureForInjection(ctx.arena, .{ .samples = 1 });
        const manifest = try buildSyntheticArchiveWith(&ctx, tmp.dir, status_complete, capture);
        try writeManifestFile(&ctx, tmp.dir, &manifest);

        // Raw for the load: the manifest reader talks to the injected
        // allocator directly, and what it returns is released the same way.
        ctx.arena = allocator;
        var loaded = try loadWrittenManifest(&ctx, tmp.dir);
        // A refusal anywhere below still hands the load's own copies back.
        errdefer loaded.deinit(allocator);

        ctx.arena = arena_state.allocator();
        const analysis = try verifyArchive(&ctx, tmp.dir, &loaded);
        try testing.expectEqual(expected_work_counts.cases, analysis.cases.len);
        loaded.deinit(allocator);
    }

    test "a semantic archive load releases what it already took at every allocation failure point" {
        // SafeAllocator can remap depending on address layout. Force allocation
        // fallback so the failure sweep visits the same allocation count each run.
        var vtable = testing.allocator.vtable.*;
        vtable.resize = Allocator.noResize;
        vtable.remap = Allocator.noRemap;
        var backing = testing.allocator;
        backing.vtable = &vtable;
        try testing.checkAllAllocationFailures(backing, loadVerifyAndRelease, .{});
    }
} else struct {};

comptime {
    // A test belongs to the build only in a container this compilation
    // analyzes, and nothing else names this one.
    testing.refAllDecls(SemanticTests);
}
