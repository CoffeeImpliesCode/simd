//! Semantic measurement for the CommonMark 0.31.2 and yaml-extended-e2b-1.2.2
//! profiles.
//!
//! ```sh
//! zig build bench-semantic -- [ITERATIONS]
//! ```
//!
//! `ITERATIONS` is one optional positional decimal in 1..32, default 3. There is
//! no stream chunk knob and there never will be one here: neither semantic
//! parser provides streaming, so accepting a chunk size would be a no-op that
//! implies a capability the measurement does not have.
//!
//! This is a second, separately identified measurement. It shares nothing with
//! the legacy `bench.zig` domain but the way one case is reported: the same
//! counting allocator, the same awake clock, the same stdout discipline. The
//! legacy 35 input hashes and 210 cases are untouched, nothing here ranks
//! results, compares libraries, or claims a speedup.
//!
//! The work domain is the fixture list the two format modules declare:
//! CommonMark first, YAML extended second, each in declaration order. Every
//! fixture is measured on exactly the stages it declares. There is no Cartesian
//! product, and a stage a fixture does not declare has no row.
//!
//! Each measured iteration is a fresh parse, the named consumption, and the
//! destruction of what that parse owned, all inside the timed region. Nothing is
//! prebuilt, nothing is retained between iterations, and the outcome is what
//! the real call returned rather than an expectation copied into a row.
//!
//! Both modules verify their independently authored oracles against the real
//! parsers before anything is timed or printed, so a run that reaches stdout
//! has already checked every parser behavior it is about to publish.

const std = @import("std");
const builtin = @import("builtin");
// The measured width is taken from the library rather than from a
// `build_options` module of this root's own. `simd_lib` already carries that
// module, and a root that both declared its own copy and imported the library
// handed the same generated options file to two modules of one compilation,
// which the compiler rejects. Everything this root reaches under `src/`
// arrives through `simd_lib`, so nothing else needed the module here.
const lib = @import("simd_lib");
const contract = @import("semantic_contract");
const report = @import("scripts/semantic_benchmark_report.zig");
const commonmark = @import("scripts/commonmark_bench.zig");
const yaml_extended = @import("scripts/yaml_extended_bench.zig");

const Allocator = std.mem.Allocator;

const DEFAULT_ITERATIONS: usize = 3;

/// The measured invocation shape. One optional positional count, nothing else.
const BenchOptions = struct {
    iterations: usize = DEFAULT_ITERATIONS,
};

/// The declared work domain, in the order the protocol prints it. One
/// `DomainSegment` per format, each holding that format's fixtures in
/// declaration order, so the printed rows follow the declaration rather than a
/// product of independent axes.
const domain_segments = [_]report.DomainSegment{
    .{ .format = .commonmark, .fixtures = commonmark.fixtures },
    .{ .format = .yaml_extended, .fixtures = yaml_extended.fixtures },
};

const work_domain: report.Domain = .{ .segments = &domain_segments };

/// Every measured iteration builds its own parse and destroys it again. No
/// document, tape, or rendered buffer is built once and reused.
const setup_text =
    "fresh parse, named consumption, and destruction per iteration";

/// `traverse` consumes complete semantics. The `parse` stage is parse
/// consumption only and is small by design, so this measurement never calls it
/// a whole-document result.
const consumption_text =
    "traverse consumes complete semantics; parse consumption is small by design";

/// The renderer under measurement is the safe mode only: raw HTML is omitted
/// and dangerous URLs are filtered. The YAML profile has no renderer, so no
/// YAML fixture declares the stage.
const render_html_text =
    "safe mode: raw HTML omitted, dangerous URLs filtered";

comptime {
    // The published metadata has to say what the format modules declare about
    // the `parse` stage. If either module ever changes that coverage, the
    // header above must change with it rather than keep claiming "small".
    if (std.mem.indexOf(u8, consumption_text, commonmark.parse_stage_coverage) == null or
        std.mem.indexOf(u8, consumption_text, yaml_extended.parse_stage_coverage) == null)
    {
        @compileError("consumption_text must state the parse-stage coverage both format modules declare");
    }
}

// ---------------------------------------------------------------------------
// Counting allocator.
//
// Identical accounting to the legacy bench: a successful request counts once,
// and growth on resize or remap adds only the bytes beyond the old length.
// There is no resident-set or OS-level claim here, and none may be added
// without changing what the legacy bench means by the same column.
// ---------------------------------------------------------------------------

const CountingAllocator = struct {
    child: Allocator,
    allocation_count: usize = 0,
    allocated_bytes: usize = 0,

    fn allocator(self: *@This()) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reset(self: *@This()) void {
        self.allocation_count = 0;
        self.allocated_bytes = 0;
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(length, alignment, return_address);
        if (result != null) {
            self.allocation_count +|= 1;
            self.allocated_bytes +|= length;
        }
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        const result = self.child.rawResize(memory, alignment, new_length, return_address);
        if (result and new_length > memory.len) {
            self.allocated_bytes +|= new_length - memory.len;
        }
        return result;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_length, return_address);
        if (result != null and new_length > memory.len) {
            self.allocated_bytes +|= new_length - memory.len;
        }
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
    }
};

/// One measured case. `outcome` is the observation the first iteration made and
/// every later iteration was required to repeat.
const CaseSample = struct {
    elapsed_ns: u64,
    checksum: u64,
    outcome: []const u8,
    allocation_count: usize,
    allocated_bytes: usize,
};

fn elapsedNanoseconds(start: i96, end: i96) !u64 {
    if (end < start) return error.ClockWentBackwards;
    const delta: i96 = end - start;
    if (delta > std.math.maxInt(u64)) return error.ElapsedOverflow;
    return @intCast(delta);
}

/// One measured case: `iterations` runs of one declared stage.
///
/// Every iteration goes through the same path — fresh parse, the stage's own
/// consumption, destruction — inside the timed region. A parser that answered
/// the same input twice with different bytes or a different outcome is not a
/// measurement, so the run fails instead of publishing a row that the archive
/// would later refuse as unstable.
fn runCase(
    io: std.Io,
    allocator: Allocator,
    format: contract.Format,
    fixture_index: usize,
    stage: contract.Stage,
    iterations: usize,
) !CaseSample {
    var counting: CountingAllocator = .{ .child = allocator };
    counting.reset();
    const counted = counting.allocator();

    var outcome: []const u8 = contract.accepted_outcome;
    var checksum: u64 = 0;

    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |iteration| {
        const result = switch (format) {
            .commonmark => try commonmark.run(counted, fixture_index, stage),
            .yaml_extended => try yaml_extended.run(counted, fixture_index, stage),
        };
        if (iteration == 0) {
            outcome = result.outcome;
            checksum = result.checksum;
        } else if (!std.mem.eql(u8, outcome, result.outcome)) {
            return error.OutcomeDrift;
        } else if (checksum != result.checksum) {
            return error.ChecksumDrift;
        }
        std.mem.doNotOptimizeAway(&result.checksum);
    }
    const end = std.Io.Clock.awake.now(io).nanoseconds;
    std.mem.doNotOptimizeAway(&checksum);

    return .{
        .elapsed_ns = try elapsedNanoseconds(start, end),
        .checksum = checksum,
        .outcome = outcome,
        .allocation_count = counting.allocation_count,
        .allocated_bytes = counting.allocated_bytes,
    };
}

// Sweep invocation: `zig build bench-semantic -- 16`.
fn parseBenchOptions(args: []const []const u8) !BenchOptions {
    var options: BenchOptions = .{};
    var iterations_supplied = false;
    var argument_index: usize = 1;

    while (argument_index < args.len) : (argument_index += 1) {
        const argument = args[argument_index];
        // This executable has no flags, so a token that looks like one is a
        // mistake to report rather than a knob to invent or ignore.
        if (std.mem.startsWith(u8, argument, "-")) return error.UnknownArgument;
        if (iterations_supplied) return error.UnexpectedArgument;
        const iterations = std.fmt.parseUnsigned(usize, argument, 10) catch {
            return error.InvalidIterationCount;
        };
        if (iterations < @as(usize, report.min_iterations) or
            iterations > @as(usize, report.max_iterations))
        {
            return error.IterationCountOutOfRange;
        }
        options.iterations = iterations;
        iterations_supplied = true;
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = try parseBenchOptions(args);

    // Preflight. Both modules compare their independently authored oracles
    // with what the real parsers do, and the declared domain is checked for the
    // rows it must produce. A disagreement exits nonzero here, before any
    // timing and before a single byte of stdout, so a capture can never
    // publish a parser behavior this process did not check.
    try commonmark.verifyOracles(init.gpa);
    try yaml_extended.verifyOracles(init.gpa);
    try report.verifyDomain(work_domain);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("# zig_version={s}\n", .{builtin.zig_version_string});
    try stdout.print("# optimize={t}\n", .{builtin.mode});
    try stdout.print("# target_arch={t}\n", .{builtin.target.cpu.arch});
    // This is the same number the header has always reported. The library
    // defines `default_vector_len` as `build_options.vector_len orelse
    // native_vector_len`, so it names the build-selected width when
    // `-Dvector_len` gave one and the native width when it did not. The
    // expression this replaced asked the same options module the same
    // question and only fell through to this value when none was selected,
    // so both spellings agree on every build.
    try stdout.print("# vector_len={d}\n", .{lib.default_vector_len});
    try stdout.print(
        "# commonmark_profile={s}\n",
        .{report.commonmark_profile_version},
    );
    try stdout.print("# yaml_profile={s}\n", .{report.yaml_extended_profile_version});
    try stdout.print("# setup={s}\n", .{setup_text});
    try stdout.print("# consumption={s}\n", .{consumption_text});
    try stdout.print("# render_html={s}\n", .{render_html_text});
    try stdout.print("# streaming={s}\n", .{report.streaming_boundary_text});
    try stdout.print("# ranking={s}\n", .{report.ranking_boundary_text});
    try stdout.print("{s}\n", .{report.csv_header});

    for (domain_segments) |segment| {
        for (segment.fixtures, 0..) |fixture, fixture_index| {
            try stdout.print(
                "{s}format={s} workload={s} input_hash={x}\n",
                .{
                    report.input_declaration_prefix,
                    @tagName(segment.format),
                    @tagName(fixture.workload),
                    contract.checksumBytes(fixture.source),
                },
            );
            for (fixture.stages) |stage| {
                const sample = try runCase(
                    init.io,
                    init.gpa,
                    segment.format,
                    fixture_index,
                    stage,
                    options.iterations,
                );
                try stdout.print(
                    "{s},{s},{s},{s},{d},{d},{d},{d},{d},{d}\n",
                    .{
                        @tagName(segment.format),
                        @tagName(fixture.workload),
                        @tagName(stage),
                        sample.outcome,
                        fixture.source.len,
                        options.iterations,
                        sample.elapsed_ns,
                        sample.checksum,
                        sample.allocation_count,
                        sample.allocated_bytes,
                    },
                );
            }
        }
    }
    try stdout.flush();
}
