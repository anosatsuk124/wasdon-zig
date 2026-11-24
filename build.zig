const std = @import("std");

/// WASM programs under `examples/<dir>/main.zig`. They double as test
/// fixtures: `zig build test` translates each one and runs it in the Udon
/// emulator against `examples/<dir>/expected.log`.
const Example = struct {
    name: []const u8,
    dir: []const u8,
    /// Restrict codegen to WebAssembly 1.0 (no bulk memory, sign extension, ...).
    mvp_only: bool = false,
};

const examples = [_]Example{
    .{ .name = "bench", .dir = "wasm-bench", .mvp_only = true },
    .{ .name = "udon-orbit", .dir = "udon-orbit", .mvp_only = true },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- library modules ----
    const wasm_mod = b.addModule("wasm", .{ .root_source_file = b.path("src/wasm/root.zig"), .target = target });
    const udon_mod = b.addModule("udon", .{ .root_source_file = b.path("src/udon/root.zig"), .target = target });
    const translator_mod = b.addModule("translator", .{
        .root_source_file = b.path("src/translator/root.zig"),
        .target = target,
        .imports = &.{ .{ .name = "wasm", .module = wasm_mod }, .{ .name = "udon", .module = udon_mod } },
    });
    const mod = b.addModule("wasdon_zig", .{
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
            .imports = &.{.{ .name = "wasdon_zig", .module = mod }},
        }),
    });
    exe.root_module.addAnonymousImport("udon_nodes.txt", .{ .root_source_file = b.path("docs/udon_nodes.txt") });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the CLI").dependOn(&run_cmd.step);

    // ---- examples: Zig → WASM → Udon Assembly ----
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .imports = &.{.{ .name = "wasdon_zig", .module = mod }},
    });
    e2e_mod.addAnonymousImport("udon_nodes.txt", .{ .root_source_file = b.path("docs/udon_nodes.txt") });

    const examples_step = b.step("examples", "Build the example WASM programs and translate them (zig-out/wasm, zig-out/uasm)");
    for (examples) |example| {
        const features = std.Target.wasm.featureSet(&.{ .bulk_memory, .sign_ext, .nontrapping_fptoint, .mutable_globals });
        const wasm_exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{example.dir})),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = .wasm32,
                    .os_tag = .freestanding,
                    .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
                    .cpu_features_add = if (example.mvp_only) .empty else features,
                }),
                .optimize = .ReleaseSmall,
            }),
        });
        wasm_exe.entry = .disabled;
        wasm_exe.rdynamic = true;
        const wasm_file = wasm_exe.getEmittedBin();
        examples_step.dependOn(&b.addInstallFile(wasm_file, b.fmt("wasm/{s}.wasm", .{example.name})).step);

        const translate = b.addRunArtifact(exe);
        translate.addArg("translate");
        translate.addFileArg(wasm_file);
        translate.addArg("-o");
        const uasm = translate.addOutputFileArg(b.fmt("{s}.uasm", .{example.name}));
        examples_step.dependOn(&b.addInstallFile(uasm, b.fmt("uasm/{s}.uasm", .{example.name})).step);

        e2e_mod.addAnonymousImport(b.fmt("{s}.wasm", .{example.name}), .{ .root_source_file = wasm_file });
        e2e_mod.addAnonymousImport(b.fmt("{s}.log", .{example.name}), .{ .root_source_file = b.path(b.fmt("examples/{s}/expected.log", .{example.dir})) });
        e2e_mod.addAnonymousImport(b.fmt("{s}.scenario", .{example.name}), .{ .root_source_file = b.path(b.fmt("examples/{s}/scenario.txt", .{example.dir})) });
    }

    // ---- tests ----
    const test_step = b.step("test", "Run all tests");
    for ([_]*std.Build.Module{ wasm_mod, udon_mod, translator_mod, mod, exe.root_module, e2e_mod }) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
}
