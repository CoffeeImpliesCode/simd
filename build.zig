//! Build and publication routes for the native Zig `simd` package on Zig 0.17.0.
//! `dependency.module("simd")` carries its generated width options; installed artifacts
//! are the build-only `simd-static` archive and the `simd` sample visualizer.

const std = @import("std");

/// SIMD widths exercised by `zig build check`.
///
/// Every width gets its own `build_options` module and its own library module,
/// so a matrix column never observes the default-width artifacts. The list is
/// a verification matrix, not a whitelist: `-Dvector_len` stays unrestricted
/// above 4 and can select any width outside this list.
const check_vector_lens = [_]usize{ 4, 5, 7, 12, 16, 24, 32, 64 };

/// Test-runner seed pinned for gate runs.
///
/// `std.Build.addRunArtifact` already appends `--seed=0x<graph seed>` for test
/// binaries; appending a second `--seed=` wins the test runner's last-one-wins
/// argument parse. The deterministic Smith seeds in `test/fuzz_test.zig` are
/// literals and never read `std.testing.random_seed`, so this pins run order
/// and implicit randomness without touching them.
const check_test_seed: u32 = 0x9e37_79b9;

/// Root-relative Zig sources covered by the format check. Listing them
/// explicitly keeps the gate out of `.zig-cache`, `zig-out`, and `.devenv`.
const fmt_paths = [_][]const u8{
    "build.zig",
    "build.zig.zon",
    "src",
    "test",
    "scripts",
    "examples",
    "library_test.zig",
    "bench.zig",
    "kernel_bench.zig",
    "semantic_bench.zig",
    "string_bench.zig",
};

/// Root that gate scratch falls back to when nothing else names one.
///
/// The default is the temporary directory the environment already names, so a
/// host that redirects `TMPDIR` places gate scratch there without a repository
/// change, and `/tmp` is the fallback where it names none. `-Dscratch_dir`
/// overrides the root, not the per-user subdirectory below it.
const gate_scratch_root = "/tmp";

/// Root that gate scratch defaults to when `-Dscratch_dir` names none.
fn gateScratchDefault(b: *std.Build) []const u8 {
    return b.graph.environ_map.get("TMPDIR") orelse gate_scratch_root;
}

/// Absolute scratch directory handed to gate subprocesses as `TMPDIR`.
///
/// The per-user component keeps concurrent users on shared storage from
/// colliding. The directory is created by a gate step rather than at configure
/// time, so an ordinary `zig build` still touches no shared disk.
fn gateScratchDir(b: *std.Build, scratch_root: []const u8) []const u8 {
    const user = b.graph.environ_map.get("USER") orelse "shared";
    return b.pathJoin(&.{ scratch_root, user, "simd-check" });
}

/// Directory the aggregate gate's own cross-test run writes its evidence to.
///
/// zig-gate's `GATE_CROSS_OUTPUT` defaults to `$GATE_SCRATCH/zig-gate-cross`,
/// and the host policy picks `GATE_SCRATCH` per user, not per project, so
/// unrelated checkouts share one prefix and its exclusive `.cross-test.lock`
/// makes one refuse to start. This build derives the path from this build's
/// local cache and the absolute project root instead; zig-gate checks the
/// resolved volume when the step runs, and cross-test creates the directory
/// then rather than at configure time. Cache cleanup can remove its logs.
fn gateCrossOutputDir(b: *std.Build) std.Build.LazyPath {
    const project_root = b.root.toString(b.allocator) catch @panic("OOM");
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(project_root, &digest, .{});
    // Eight digest bytes render as sixteen lowercase hex digits: enough to keep
    // a project's namespace compact, not a guarantee that two projects cannot
    // land on the same one. A truncated hash still collides.
    const namespace = b.fmt("{s}-{x}", .{ std.fs.path.basename(project_root), digest[0..8] });
    return std.Build.LazyPath.cache_root.path(b, b.pathJoin(&.{ "zig-gate-cross", namespace }));
}

/// The analyzers accept files, not the format check's mixed file/directory list.
/// Walk only owned source directories; never enter caches or evidence archives.
fn addAnalysisSources(b: *std.Build, zbc: *std.Build.Step.Run, zwanzig: *std.Build.Step.Run) void {
    for (fmt_paths) |path| {
        if (std.mem.endsWith(u8, path, ".zon")) continue;
        if (std.mem.endsWith(u8, path, ".zig")) {
            zbc.addFileArg(b.path(path));
            zwanzig.addFileArg(b.path(path));
            continue;
        }

        b.dependOnDirectoryContents(b.path(path));
        const dir_path = b.root.joinString(b.allocator, path) catch @panic("OOM");
        const dir = std.Io.Dir.cwd().openDir(b.graph.io, dir_path, .{ .iterate = true }) catch
            @panic("unable to open analysis source directory");
        defer dir.close(b.graph.io);
        var walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(b.graph.io) catch @panic("unable to walk analysis sources")) |entry| {
            if (entry.kind == .directory)
                b.dependOnDirectoryContents(b.path(b.pathJoin(&.{ path, entry.path })));
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const source = b.path(b.pathJoin(&.{ path, entry.path }));
            zbc.addFileArg(source);
            zwanzig.addFileArg(source);
        }
    }
}

/// One test entry point of this repository.
const TestRoot = struct {
    /// Label used for the artifact and run step names.
    name: []const u8,
    /// Root source file of the test binary.
    path: []const u8,
    /// False for roots that reach `src/` by relative path instead of by import.
    imports_lib: bool,
};

/// Every existing test root, including the ones the default-width build wires
/// up by hand. The matrix runs all of them at all of `check_vector_lens`.
const test_roots = [_]TestRoot{
    .{ .name = "root", .path = "test/root_test.zig", .imports_lib = true },
    .{ .name = "library", .path = "library_test.zig", .imports_lib = false },
    .{ .name = "main", .path = "src/main.zig", .imports_lib = true },
    .{ .name = "fuzz", .path = "test/fuzz_test.zig", .imports_lib = true },
    .{ .name = "corpus", .path = "test/corpus_test.zig", .imports_lib = true },
    .{ .name = "commonmark", .path = "test/commonmark_conformance_test.zig", .imports_lib = true },
};

/// Builds one test binary plus its run step for a single width.
///
/// `options` and `lib_module` must both carry the same `vector_len`; the test
/// root binds to `options` directly and through `lib_module` so the library and
/// the test observe one width.
fn addTestRoot(
    b: *std.Build,
    artifact_name: []const u8,
    root: TestRoot,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    options: *std.Build.Step.Options,
    lib_module: *std.Build.Module,
    seed: u32,
) *std.Build.Step.Run {
    const module = b.createModule(.{
        .root_source_file = b.path(root.path),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", options);
    if (root.imports_lib) module.addImport("simd_lib", lib_module);

    const test_compile = b.addTest(.{
        .name = artifact_name,
        .root_module = module,
    });
    const run = b.addRunArtifact(test_compile);
    run.addArg(b.fmt("--seed=0x{x}", .{seed}));
    return run;
}

/// Adds every `test_roots` x `check_vector_lens` cell to `check_step`.
///
/// The default-width artifacts stand in for their own column: when
/// `-Dvector_len` names a matrix width, that column reuses them instead of
/// compiling the same width twice.
fn addWidthMatrix(
    b: *std.Build,
    check_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    selected_vector_len: ?usize,
) void {
    for (check_vector_lens) |width| {
        if (selected_vector_len) |selected| {
            if (selected == width) continue;
        }

        const options = b.addOptions();
        options.addOption(?usize, "vector_len", width);

        const lib_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        lib_module.addOptions("build_options", options);

        for (test_roots) |root| {
            const run = addTestRoot(
                b,
                b.fmt("{s}-w{d}", .{ root.name, width }),
                root,
                target,
                optimize,
                options,
                lib_module,
                check_test_seed,
            );
            check_step.dependOn(&run.step);
        }
    }
}

/// Builds the `benchmark_options` module that `scripts/benchmark.zig` imports.
///
/// Every value is read from the configuration this build actually selected
/// rather than from anything an archive carries, so a recorded run names the
/// toolchain and binary shape that produced it. `bench_target` and `bench_cpu`
/// are complete specifiers: they stay meaningful when `-Dtarget` and the CPU
/// were left at their native defaults, where a bare query would only say
/// `native` and a native CPU would leave the feature set unstated.
///
/// `semantic_mode` selects which measurement the same runtime speaks, and it
/// is a build-provided constant rather than an argument. Legacy stays the
/// default; the semantic run is the same source compiled again against
/// semantic options, not a runtime switch a caller could flip.
fn addBenchmarkOptions(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    vector_len: ?usize,
    semantic_mode: bool,
) *std.Build.Step.Options {
    const query = std.Target.Query.fromTarget(&target.result);
    const options = b.addOptions();
    options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    options.addOption([]const u8, "bench_target", query.zigTriple(b.allocator) catch @panic("OOM"));
    options.addOption(
        []const u8,
        "bench_cpu",
        std.Target.Query.serializeCpuAlloc(query, b.allocator) catch @panic("OOM"),
    );
    options.addOption([]const u8, "bench_optimize", @tagName(optimize));
    options.addOption(?usize, "bench_vector_len", vector_len);
    options.addOption(bool, "semantic_mode", semantic_mode);
    return options;
}

/// Builds the `semantic_contract` module the semantic controller, both format
/// modules, and the semantic report decoder import by name.
///
/// It is created per target rather than once and shared: the controller is
/// compiled for the selected target while the decoder is exercised by the
/// host-only archive runtime, and one module carries exactly one target. The
/// module itself imports nothing but `std`, so it never drags a CPU-dependent
/// library into either consumer.
fn addSemanticContract(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("scripts/semantic_contract.zig"),
        .target = target,
        .optimize = optimize,
    });
}

/// Registers the native module, installed artifacts and named development checks.
/// Graph construction records no benchmark archive. Consumers obtain the configured
/// module through `dependency.module("simd")`, including its generated width options.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const vector_len = b.option(
        usize,
        "vector_len",
        "Override SIMD vector width (minimum 4 bytes for four-byte UTF-8 " ++
            "and mask-shift algorithms)",
    );
    if (vector_len) |len| {
        if (len < 4) {
            std.log.err(
                "-Dvector_len must be at least 4 bytes because four-byte UTF-8 " ++
                    "and mask-shift algorithms require it",
                .{},
            );
            b.invalid_user_input = true;
        }
    }

    const build_options = b.addOptions();
    build_options.addOption(?usize, "vector_len", vector_len);

    // The registered module is the native consumer route, with its build options attached.
    const lib_mod = b.addModule("simd", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addOptions("build_options", build_options);

    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("test/root_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_test_mod.addOptions("build_options", build_options);
    const library_test_mod = b.createModule(.{
        .root_source_file = b.path("library_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    library_test_mod.addOptions("build_options", build_options);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addOptions("build_options", build_options);

    // The semantic measurement is a second root, not a mode of `bench.zig`:
    // it compiles the two format modules and the protocol decoder into one
    // executable and shares only the vocabulary those three agree on.
    //
    // It declares no `build_options` of its own. It is a consumer of
    // `lib_mod`, and `lib_mod` already carries that module, so a root that
    // both declared its own copy and imported the library handed the same
    // generated options file to two modules of one compilation. The
    // compiler rejects that outright, so the width it reports is read from
    // the library, which resolves it from that one options module.
    const semantic_bench_mod = b.createModule(.{
        .root_source_file = b.path("semantic_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    semantic_bench_mod.addImport("simd_lib", lib_mod);
    semantic_bench_mod.addImport("semantic_contract", addSemanticContract(b, target, optimize));

    const kernel_bench_mod = b.createModule(.{
        .root_source_file = b.path("kernel_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel_bench_mod.addOptions("build_options", build_options);
    const string_bench_mod = b.createModule(.{
        .root_source_file = b.path("string_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    string_bench_mod.addOptions("build_options", build_options);

    const fuzz_test_mod = b.createModule(.{
        .root_source_file = b.path("test/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_test_mod.addOptions("build_options", build_options);
    const corpus_test_mod = b.createModule(.{
        .root_source_file = b.path("test/corpus_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    corpus_test_mod.addOptions("build_options", build_options);
    corpus_test_mod.addImport("simd_lib", lib_mod);
    fuzz_test_mod.addImport("simd_lib", lib_mod);
    lib_test_mod.addImport("simd_lib", lib_mod);

    const commonmark_test_mod = b.createModule(.{
        .root_source_file = b.path("test/commonmark_conformance_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    commonmark_test_mod.addImport("simd_lib", lib_mod);

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", build_options);

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("simd_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "simd-static",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "simd",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const consumer_exe = b.addExecutable(.{
        .name = "simd-consumer-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/consumer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    consumer_exe.root_module.addImport("simd", lib_mod);
    const consumer_run = b.addRunArtifact(consumer_exe);
    const consumer_step = b.step("example", "Run the native consumer ownership example");
    consumer_step.dependOn(&consumer_run.step);

    // Creates test executables for the public root, source-local library
    // declarations, executable, and deterministic fuzz roots.
    const library_unit_tests = b.addTest(.{
        .root_module = library_test_mod,
    });
    const run_library_unit_tests = b.addRunArtifact(library_unit_tests);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_test_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const smith_fuzz_tests = b.addTest(.{
        .root_module = fuzz_test_mod,
    });
    const run_smith_fuzz_tests = b.addRunArtifact(smith_fuzz_tests);
    const corpus_tests = b.addTest(.{
        .root_module = corpus_test_mod,
    });
    const run_corpus_tests = b.addRunArtifact(corpus_tests);
    const commonmark_tests = b.addTest(.{
        .root_module = commonmark_test_mod,
    });
    const run_commonmark_tests = b.addRunArtifact(commonmark_tests);

    // Pin the runner seed on the default-width binaries too, so `zig build test`
    // and the native column of `zig build check` agree run for run.
    const default_test_seed = b.fmt("--seed=0x{x}", .{check_test_seed});
    run_library_unit_tests.addArg(default_test_seed);
    run_lib_unit_tests.addArg(default_test_seed);
    run_exe_unit_tests.addArg(default_test_seed);
    run_smith_fuzz_tests.addArg(default_test_seed);
    run_corpus_tests.addArg(default_test_seed);
    run_commonmark_tests.addArg(default_test_seed);

    const bench_exe = b.addExecutable(.{
        .name = "simd-bench",
        .root_module = bench_mod,
    });
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.addPassthruArgs();

    const kernel_bench_exe = b.addExecutable(.{
        .name = "simd-kernel-bench",
        .root_module = kernel_bench_mod,
    });
    const run_kernel_bench = b.addRunArtifact(kernel_bench_exe);
    run_kernel_bench.addPassthruArgs();

    const string_bench_exe = b.addExecutable(.{
        .name = "simd-string-bench",
        .root_module = string_bench_mod,
    });
    const run_string_bench = b.addRunArtifact(string_bench_exe);
    run_string_bench.addPassthruArgs();

    // The benchmark runner drives `simd-bench`, so it executes on the host even
    // under a cross `-Dtarget`, while the executable it launches keeps the
    // selected optimize, target, and `-Dvector_len`. Wiring the graph below
    // records nothing: only running `benchmark` does, so `zig build` and
    // `zig build check` stay free of archive writes.

    // One contract module for every host-only consumer. It is declared here
    // rather than per consumer so the legacy runner, the semantic runner, and
    // the semantic behavior tests all name the same vocabulary; the controller
    // gets its own, because it is compiled for the selected target.
    const host_semantic_contract = addSemanticContract(b, b.graph.host, optimize);
    const benchmark_options = addBenchmarkOptions(b, target, optimize, vector_len, false);
    const bench_script_mod = b.createModule(.{
        .root_source_file = b.path("scripts/benchmark.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    bench_script_mod.addOptions("benchmark_options", benchmark_options);
    // The legacy runtime never reads the contract in legacy mode. The import is
    // declared anyway so one `scripts/benchmark.zig` source can name the shared
    // vocabulary above its mode branch without a mode-dependent import list.
    bench_script_mod.addImport("semantic_contract", host_semantic_contract);

    const bench_runner_exe = b.addExecutable(.{
        .name = "simd-benchmark",
        .root_module = bench_script_mod,
    });

    // argv: runner, the bench executable this build produced, the repository
    // root, then the operation and its arguments exactly as typed after `--`.
    const bench_runner = b.addRunArtifact(bench_runner_exe);
    bench_runner.addArtifactArg2(bench_exe, .{});
    bench_runner.addDirectoryArg2(b.path("."), .{});
    bench_runner.addPassthruArgs();

    const bench_script_tests = b.addTest(.{
        .name = "benchmark-script",
        .root_module = bench_script_mod,
    });
    const run_bench_script_tests = b.addRunArtifact(bench_script_tests);
    run_bench_script_tests.addArg(default_test_seed);

    const semantic_bench_exe = b.addExecutable(.{
        .name = "simd-semantic-bench",
        .root_module = semantic_bench_mod,
    });
    const semantic_bench_cmd = b.addRunArtifact(semantic_bench_exe);
    semantic_bench_cmd.addPassthruArgs();

    // The semantic archive runner is the same `scripts/benchmark.zig` source
    // compiled again with `semantic_mode` true. The implementation is not
    // copied and not generalized into a framework: the two compilations share
    // one file, one command surface, and one build, and the legacy one keeps
    // its own schema name, its own captured bench path, and its own options.
    // Like the legacy runner it executes on the host under a cross `-Dtarget`,
    // and like the legacy runner it records nothing until it is run.
    const semantic_benchmark_options = addBenchmarkOptions(b, target, optimize, vector_len, true);
    const semantic_bench_script_mod = b.createModule(.{
        .root_source_file = b.path("scripts/benchmark.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    semantic_bench_script_mod.addOptions("benchmark_options", semantic_benchmark_options);
    semantic_bench_script_mod.addImport("semantic_contract", host_semantic_contract);

    const semantic_bench_runner_exe = b.addExecutable(.{
        .name = "simd-semantic-benchmark",
        .root_module = semantic_bench_script_mod,
    });

    // argv: runner, the semantic bench executable this build produced, the
    // repository root, then the operation and its arguments exactly as typed
    // after `--`. The captured artifact path differs in semantic mode, so the
    // executable is named to match what the archive stores.
    const semantic_bench_runner = b.addRunArtifact(semantic_bench_runner_exe);
    semantic_bench_runner.addArtifactArg2(semantic_bench_exe, .{});
    semantic_bench_runner.addDirectoryArg2(b.path("."), .{});
    semantic_bench_runner.addPassthruArgs();

    // `scripts/benchmark.zig` compiles twice, so its tests compile twice: the
    // legacy root above reaches `legacy_tests` and this one reaches
    // `semantic_tests`, each through the `testing.refAllDecls` inside the file.
    // Same source, same imports, same host target, one comptime option apart, so
    // this reuses the module the semantic runner is already built from. The name
    // differs from the legacy script root and from the `semantic_benchmark_test`
    // root below, so no two compilations collide in the build graph or in
    // reported output. Like the legacy root it is a test and not a recording
    // step: compiling and running it writes no archive.
    const semantic_bench_script_tests = b.addTest(.{
        .name = "semantic-benchmark-script",
        .root_module = semantic_bench_script_mod,
    });
    const run_semantic_bench_script_tests = b.addRunArtifact(semantic_bench_script_tests);
    run_semantic_bench_script_tests.addArg(default_test_seed);

    // The semantic behavior tests are host-only and width-independent: they
    // exercise the stdout protocol and the declared work domain, never a
    // parser, so one invocation covers them and they stay out of the matrix.
    const semantic_bench_test_mod = b.createModule(.{
        .root_source_file = b.path("scripts/semantic_benchmark_test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    semantic_bench_test_mod.addImport("semantic_contract", host_semantic_contract);
    const semantic_bench_tests = b.addTest(.{
        .name = "semantic-benchmark",
        .root_module = semantic_bench_test_mod,
    });
    const run_semantic_bench_tests = b.addRunArtifact(semantic_bench_tests);
    run_semantic_bench_tests.addArg(default_test_seed);

    const corpus_step = b.step("corpus", "Run offline corpus catalogs");
    corpus_step.dependOn(&run_corpus_tests.step);
    corpus_step.dependOn(&run_commonmark_tests.step);

    const commonmark_step = b.step("commonmark", "Run pinned CommonMark conformance and ownership tests");
    commonmark_step.dependOn(&run_commonmark_tests.step);

    const fuzz_step = b.step("fuzz", "Run deterministic Smith fuzz tests");
    fuzz_step.dependOn(&run_smith_fuzz_tests.step);

    const bench_step = b.step("bench", "Run deterministic parser benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    const bench_kernel_step = b.step("bench-kernel", "Run SIMD kernel A/B benchmarks");
    bench_kernel_step.dependOn(&run_kernel_bench.step);

    const bench_string_step = b.step("bench-string", "Run JSON string token benchmarks");
    bench_string_step.dependOn(&run_string_bench.step);

    const bench_semantic_step = b.step(
        "bench-semantic",
        "Run the CommonMark and YAML extended semantic measurement",
    );
    bench_semantic_step.dependOn(&semantic_bench_cmd.step);

    const benchmark_step = b.step(
        "benchmark",
        "Record, verify, or reproduce native benchmark archives",
    );
    benchmark_step.dependOn(&bench_runner.step);

    const benchmark_semantic_step = b.step(
        "benchmark-semantic",
        "Record, verify, or reproduce native semantic benchmark archives",
    );
    benchmark_semantic_step.dependOn(&semantic_bench_runner.step);

    const benchmark_test_step = b.step(
        "benchmark-test",
        "Run benchmark script behavior tests",
    );
    benchmark_test_step.dependOn(&run_bench_script_tests.step);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_library_unit_tests.step);
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_smith_fuzz_tests.step);
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // ------------------------------------------------------------------------
    // `zig build check`: the durable full verification gate.
    // ------------------------------------------------------------------------
    // Everything below is reachable only through `check`, so `test`, `fuzz`,
    // `corpus`, `commonmark`, `bench*`, `run`, and `docs` depend on nothing
    // here. Their dependency shape is unchanged; the pinned `check_test_seed`
    // above is the one documented deviation from their historical behavior,
    // because it fixes run order instead of re-deriving it from the graph
    // seed.

    // `zig fmt --check` over the Zig sources this repository owns. Hidden
    // directories are listed out by name so the shared `.zig-cache` symlink is
    // never walked.
    const fmt_check = b.addFmt(.{
        .paths = b.pathList(&fmt_paths),
        .check = true,
    });

    // Actually run the installed visualizer, not just compile it. Capturing
    // stdout keeps the ANSI dump out of the build log while still failing on a
    // crash, a nonzero exit, or an empty visualization.
    const visualizer_smoke = b.addRunArtifact(exe);
    visualizer_smoke.addCheck(.{ .expect_term = .{ .exited = 0 } });
    visualizer_smoke.addCheck(.{ .expect_stdout_match = "SIMD Vector Visualizer" });

    // External checks are required, uncached commands. Keep zbc separate from
    // zig-gate's advisory invocation so its nonzero exit always fails check.
    // Their scratch is large — the analyzers keep multi-hundred-megabyte build
    // caches per target — so `-Dscratch_dir` is how a host whose temporary
    // directory cannot hold them redirects it.
    const scratch_root = b.option(
        []const u8,
        "scratch_dir",
        "Root directory for gate scratch files",
    ) orelse gateScratchDefault(b);
    const scratch_dir = gateScratchDir(b, scratch_root);
    const scratch_make = b.addSystemCommand(&.{ "mkdir", "-p", scratch_dir });
    scratch_make.has_side_effects = true;

    const zig_gate = b.addSystemCommand(&.{"env"});
    zig_gate.addDirectoryArg2(gateCrossOutputDir(b), .{ .prefix = "GATE_CROSS_OUTPUT=", .make_absolute = true });
    zig_gate.addArgs(&.{ "zig-gate", "--no-zbc" });
    const zbc = b.addSystemCommand(&.{ "zbc", "--no-color" });
    const zwanzig = b.addSystemCommand(&.{ "zwanzig", "--threads", "2" });
    const cross_test = b.addSystemCommand(&.{ "cross-test", "--jobs", "2", "--build-jobs", "1" });
    for ([_]*std.Build.Step.Run{ zig_gate, zbc, zwanzig, cross_test }) |command| {
        command.setCwd(b.path("."));
        command.has_side_effects = true;
        command.step.dependOn(&scratch_make.step);
        command.setEnvironmentVariable("TMPDIR", scratch_dir);
    }
    addAnalysisSources(b, zbc, zwanzig);
    // Use the compiler that owns this build, not a different PATH selection.
    zig_gate.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    cross_test.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    // Section 9 of zig-gate runs this repository's full cross-test matrix
    // under its own prefix, which is this build's to name. The standalone
    // `cross_test` step above keeps cross-test's own default of
    // `zig-out/cross-test`, so the two full runs write separate trees and
    // stay independent steps rather than being serialized behind one prefix.

    const check_step = b.step(
        "check",
        "Full verification gate: format, install build, native tests, " ++
            "width matrix, offline corpora, benchmark and semantic " ++
            "benchmark script tests, semantic measurement compile, " ++
            "visualizer smoke, zig-gate, zbc, zwanzig, cross-test",
    );
    check_step.dependOn(b.getInstallStep());
    check_step.dependOn(&fmt_check.step);
    check_step.dependOn(&run_library_unit_tests.step);
    check_step.dependOn(&run_lib_unit_tests.step);
    check_step.dependOn(&run_exe_unit_tests.step);
    check_step.dependOn(&run_smith_fuzz_tests.step);
    check_step.dependOn(&run_corpus_tests.step);
    check_step.dependOn(&run_commonmark_tests.step);
    // The benchmark script is host-only and width-independent: one invocation
    // covers its behavior, so it is not swept across `check_vector_lens`.
    check_step.dependOn(&run_bench_script_tests.step);
    // The semantic compilation of that same script, wired exactly as the legacy
    // one is: host target, pinned seed, one invocation, never swept across the
    // width matrix.
    check_step.dependOn(&run_semantic_bench_script_tests.step);
    // The semantic behavior tests are host-only and width-independent for the
    // same reason, so they are included here exactly once and never swept.
    check_step.dependOn(&run_semantic_bench_tests.step);
    // The semantic measurement executable and the semantic archive runner
    // are compiled here and never run. Their own steps are the only ones
    // that execute them, so depending on the compile steps puts both module
    // graphs in the gate without launching a measurement: nothing here runs
    // a parser, records an archive, or writes a directory, and neither
    // artifact becomes reachable from `install` or the default step. Both
    // are built once at the selected target and optimize mode, never swept
    // across `check_vector_lens`. Without this, a module-graph or wiring
    // defect in either artifact compiled for the first time when someone
    // asked for a measurement instead of failing the gate.
    check_step.dependOn(&semantic_bench_exe.step);
    check_step.dependOn(&semantic_bench_runner_exe.step);
    check_step.dependOn(&visualizer_smoke.step);
    check_step.dependOn(&consumer_run.step);
    addWidthMatrix(b, check_step, target, optimize, vector_len);
    check_step.dependOn(&zig_gate.step);
    check_step.dependOn(&zbc.step);
    check_step.dependOn(&zwanzig.step);
    check_step.dependOn(&cross_test.step);
}
