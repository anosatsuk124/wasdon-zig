const std = @import("std");

/// Example programs under `examples/`, compiled to WebAssembly and used as
/// fixtures by the integration tests and the statistics tool.
const zig_examples = [_]struct {
    name: []const u8,
    root: []const u8,
    /// A pure-Zig file holding the example's logic. The tests compile it
    /// natively and use it as the reference the Udon run is compared with.
    core: ?[]const u8 = null,
    /// Size by default; speed where the example is a benchmark.
    optimize: std.builtin.OptimizeMode = .ReleaseSmall,
    /// An ordinary program with a `main`, built for `wasm32-wasi`, rather
    /// than a freestanding module that exports Udon events.
    wasi: bool = false,
}{
    .{ .name = "wasm-bench", .root = "examples/wasm-bench/main.zig" },
    .{ .name = "udon-orbit", .root = "examples/udon-orbit/main.zig" },
    .{ .name = "pi", .root = "examples/pi/main.zig", .core = "examples/pi/core.zig" },
    .{ .name = "mandelbrot", .root = "examples/mandelbrot/main.zig", .core = "examples/mandelbrot/core.zig" },
    .{ .name = "image-codec", .root = "examples/image-codec/main.zig", .core = "examples/image-codec/core.zig" },
    .{ .name = "ragdoll", .root = "examples/ragdoll/main.zig", .core = "examples/ragdoll/core.zig" },
    .{ .name = "blockfall", .root = "examples/blockfall/main.zig", .core = "examples/blockfall/core.zig" },
    .{ .name = "bench-zig", .root = "examples/bench/zig/main.zig", .optimize = .ReleaseFast },
    .{ .name = "sort-bench-zig", .root = "examples/sort-bench/zig/main.zig", .optimize = .ReleaseFast },
    .{ .name = "grid-bench", .root = "examples/grid-bench/main.zig", .core = "examples/grid-bench/core.zig", .optimize = .ReleaseFast },
    .{ .name = "wasi-hello", .root = "examples/wasi-hello/main.zig", .wasi = true },
};

/// Rust examples (Cargo workspace members). Only built with `-Drust`.
const rust_examples = [_]struct {
    name: []const u8,
    artifact: []const u8,
    /// Built for `wasm32-wasip1` (needs that target installed) instead of
    /// the workspace's freestanding default.
    wasi: bool = false,
}{
    .{ .name = "wasm-bench-rs", .artifact = "wasm_bench_rs.wasm" },
    .{ .name = "wasm-bench-alloc-rs", .artifact = "wasm_bench_alloc_rs.wasm" },
    .{ .name = "udon-orbit-rs", .artifact = "udon_orbit_rs.wasm" },
    .{ .name = "bench-rs", .artifact = "bench_rs.wasm" },
    .{ .name = "sort-bench-rs", .artifact = "sort_bench_rs.wasm" },
    .{ .name = "grid-bench-rs", .artifact = "grid_bench_rs.wasm" },
    .{ .name = "bench-wasi-rs", .artifact = "bench_wasi_rs.wasm", .wasi = true },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_rust = b.option(bool, "rust", "Also build and test the Rust examples (needs cargo and the wasm32v1-none target)") orelse false;
    const with_mruby = b.option(bool, "mruby", "Also build and run the mruby interpreter benchmark (needs make, ruby with rake, a host C compiler and git)") orelse false;
    const linux_wasm = b.option([]const u8, "linux", "Path to a vmlinux.wasm (examples/linux): also translate it and boot it as far as one thread goes");
    const with_rhai = b.option(bool, "rhai", "Also build and run the Rhai interpreter benchmark (needs cargo, the wasm32-wasip1 target and the rhai crate)") orelse false;

    // ---- library modules ----
    const node_list = b.path("docs/udon_nodes.txt");
    const wasm_mod = b.addModule("wasm", .{ .root_source_file = b.path("src/wasm/root.zig"), .target = target });
    const udon_mod = b.addModule("udon", .{ .root_source_file = b.path("src/udon/root.zig"), .target = target });
    udon_mod.addAnonymousImport("udon_nodes", .{ .root_source_file = node_list });
    const translator_mod = b.addModule("translator", .{
        .root_source_file = b.path("src/translator/root.zig"),
        .target = target,
        .imports = &.{ .{ .name = "wasm", .module = wasm_mod }, .{ .name = "udon", .module = udon_mod } },
    });
    const lib_mod = b.addModule("wasdon_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "wasm", .module = wasm_mod },
            .{ .name = "udon", .module = udon_mod },
            .{ .name = "translator", .module = translator_mod },
        },
    });

    // ---- CLI ----
    const exe = b.addExecutable(.{
        .name = "wasdon_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wasdon_zig", .module = lib_mod }},
        }),
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the CLI (arguments after --)").dependOn(&run_cmd.step);

    // ---- example WASM modules ----
    // MVP plus the post-MVP features the translator lowers cheaply: bulk
    // memory copies/fills become single externs, the others a few
    // instructions (docs/producer_guide.md §1).
    const wasm_features = std.Target.wasm.featureSet(&.{ .bulk_memory_opt, .sign_ext, .nontrapping_fptoint, .mutable_globals });
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
        .cpu_features_add = wasm_features,
    });
    const wasi_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
        .cpu_features_add = wasm_features,
    });
    const examples_step = b.step("examples", "Build the example WASM modules into zig-out/wasm/");
    const core_tests = b.step("test-example-cores", "Run the native unit tests of the examples' logic");

    // The integration tests and the statistics tool share one module that
    // embeds every example binary by name.
    const fixtures = b.createModule(.{
        .root_source_file = b.path("test/fixtures.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wasdon_zig", .module = lib_mod }},
    });
    const options = b.addOptions();
    options.addOption(bool, "with_rust", with_rust);
    options.addOption(bool, "with_rhai", with_rhai);
    options.addOption(bool, "with_mruby", with_mruby);
    options.addOption(bool, "with_linux", linux_wasm != null);
    fixtures.addOptions("build_options", options);
    // The UdonSharp side of the benchmark is Udon Assembly already.
    fixtures.addAnonymousImport("bench-usharp.uasm", .{ .root_source_file = b.path("examples/bench/usharp/UdonBench.uasm") });

    // Udon bindings shared by the examples.
    const udon_api = b.createModule(.{ .root_source_file = b.path("examples/udon/udon.zig"), .target = wasm_target, .optimize = .ReleaseSmall });

    for (zig_examples) |ex| {
        const wasm_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.root),
                .target = if (ex.wasi) wasi_target else wasm_target,
                .optimize = ex.optimize,
                .imports = if (ex.wasi) &.{} else &.{.{ .name = "udon", .module = udon_api }},
            }),
        });
        if (ex.wasi) {
            // The default megabytes of stack would all be allocated as
            // Udon memory.
            wasm_exe.stack_size = 64 * 1024;
        } else {
            wasm_exe.entry = .disabled;
            wasm_exe.rdynamic = true;
        }
        examples_step.dependOn(&b.addInstallArtifact(wasm_exe, .{ .dest_dir = .{ .override = .{ .custom = "wasm" } } }).step);
        fixtures.addAnonymousImport(b.fmt("{s}.wasm", .{ex.name}), .{ .root_source_file = wasm_exe.getEmittedBin() });
        if (ex.core) |core| {
            const core_mod = b.createModule(.{ .root_source_file = b.path(core), .target = target, .optimize = optimize });
            fixtures.addImport(b.fmt("{s}-core", .{ex.name}), core_mod);
            core_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core_mod })).step);
        }
    }

    if (with_rust) {
        const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release", "--locked", "--quiet" });
        // The WASI programs are not default members of the workspace.
        const cargo_wasi = b.addSystemCommand(&.{ "cargo", "build", "--release", "--locked", "--quiet", "--target", "wasm32-wasip1", "-p", "bench-wasi-rs" });
        cargo_wasi.step.dependOn(&cargo.step);
        for (rust_examples) |ex| {
            const copy = b.addWriteFiles();
            copy.step.dependOn(if (ex.wasi) &cargo_wasi.step else &cargo.step);
            const triple = if (ex.wasi) "wasm32-wasip1" else "wasm32v1-none";
            const bin = copy.addCopyFile(b.path(b.fmt("target/{s}/release/{s}", .{ triple, ex.artifact })), ex.artifact);
            fixtures.addAnonymousImport(b.fmt("{s}.wasm", .{ex.name}), .{ .root_source_file = bin });
            examples_step.dependOn(&b.addInstallFileWithDir(bin, .{ .custom = "wasm" }, b.fmt("{s}.wasm", .{ex.name})).step);
        }
    }

    if (with_rhai) {
        // A whole scripting engine: 3 360 functions, a megabyte of
        // WebAssembly. Not part of `-Drust` because of what it downloads
        // and how long it runs.
        const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release", "--quiet", "--target", "wasm32-wasip1", "-p", "rhai-bench" });
        const copy = b.addWriteFiles();
        copy.step.dependOn(&cargo.step);
        const bin = copy.addCopyFile(b.path("target/wasm32-wasip1/release/rhai_bench.wasm"), "rhai_bench.wasm");
        fixtures.addAnonymousImport("rhai-bench-rs.wasm", .{ .root_source_file = bin });
        examples_step.dependOn(&b.addInstallFileWithDir(bin, .{ .custom = "wasm" }, "rhai-bench-rs.wasm").step);
    }

    if (linux_wasm) |path| {
        fixtures.addAnonymousImport("vmlinux.wasm", .{ .root_source_file = .{ .cwd_relative = path } });
        fixtures.addAnonymousImport("vmlinux.udon_meta.json", .{ .root_source_file = b.path("examples/linux/vmlinux.udon_meta.json") });
    }

    if (with_mruby) {
        // mruby's own build system (rake), with `zig cc` as the compiler.
        const make = b.addSystemCommand(&.{ "make", "--quiet", "-C", "examples/mruby-bench" });
        const copy = b.addWriteFiles();
        copy.step.dependOn(&make.step);
        const bin = copy.addCopyFile(b.path("examples/mruby-bench/build/mruby_bench.wasm"), "mruby_bench.wasm");
        fixtures.addAnonymousImport("mruby-bench.wasm", .{ .root_source_file = bin });
        examples_step.dependOn(&b.addInstallFileWithDir(bin, .{ .custom = "wasm" }, "mruby-bench.wasm").step);
    }

    // ---- tests ----
    const test_step = b.step("test", "Run unit and integration tests");
    for ([_]*std.Build.Module{ wasm_mod, udon_mod, translator_mod, lib_mod, exe.root_module }) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
    const linux_boot = b.createModule(.{
        .root_source_file = b.path("tools/linux_boot.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wasdon_zig", .module = lib_mod }},
    });
    const integration = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/examples_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wasdon_zig", .module = lib_mod },
                .{ .name = "fixtures", .module = fixtures },
                .{ .name = "linux_boot", .module = linux_boot },
            },
        }),
    });
    // The checked-in Unity assets must be what the translator produces now.
    for (zig_examples) |ex| {
        integration.root_module.addAnonymousImport(b.fmt("unity/{s}.uasm.txt", .{ex.name}), .{
            .root_source_file = b.path(b.fmt("unity/Wasdon/Examples/{s}.uasm.txt", .{ex.name})),
        });
    }
    if (with_rust) {
        for ([_][]const u8{ "sort-bench-rs", "grid-bench-rs" }) |name| {
            integration.root_module.addAnonymousImport(b.fmt("unity/{s}.uasm.txt", .{name}), .{
                .root_source_file = b.path(b.fmt("unity/Wasdon/Examples/{s}.uasm.txt", .{name})),
            });
        }
    }
    test_step.dependOn(&b.addRunArtifact(integration).step);
    test_step.dependOn(core_tests);

    // ---- Unity assets ----
    const unity_exe = b.addExecutable(.{
        .name = "unity_assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/unity_assets.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "wasdon_zig", .module = lib_mod }, .{ .name = "fixtures", .module = fixtures } },
        }),
    });
    const unity_run = b.addRunArtifact(unity_exe);
    unity_run.addArg(b.pathFromRoot("unity/Wasdon/Examples"));
    b.step("unity", "Regenerate the examples' Unity assets in unity/Wasdon/Examples/").dependOn(&unity_run.step);

    // ---- statistics ----
    const stats_exe = b.addExecutable(.{
        .name = "stats",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/stats.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{ .{ .name = "wasdon_zig", .module = lib_mod }, .{ .name = "fixtures", .module = fixtures } },
        }),
    });
    const stats_run = b.addRunArtifact(stats_exe);
    if (b.args) |args| stats_run.addArgs(args);
    b.step("stats", "Translate and run every example; print size and executed-instruction counts").dependOn(&stats_run.step);
}
