const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
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

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
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
        .name = "simd",
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
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

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

    const bench_exe = b.addExecutable(.{
        .name = "simd-bench",
        .root_module = bench_mod,
    });
    const bench_cmd = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const corpus_step = b.step("corpus", "Run offline corpus catalogs");
    corpus_step.dependOn(&run_corpus_tests.step);

    const fuzz_step = b.step("fuzz", "Run deterministic Smith fuzz tests");
    fuzz_step.dependOn(&run_smith_fuzz_tests.step);

    const bench_step = b.step("bench", "Run deterministic parser benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_library_unit_tests.step);
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_smith_fuzz_tests.step);
}
