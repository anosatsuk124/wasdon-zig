//! End-to-end tests over the example programs.
//!
//! `build.zig` compiles every example to WASM and hands it to this file
//! together with its scenario (the Udon events to fire) and the log a real
//! WASM engine produced for that scenario (`tools/golden.mjs`). Each test
//!
//!   1. translates the module,
//!   2. parses the emitted text and checks it against the Udon Assembly
//!      specification and the Udon node list (`udon.check`),
//!   3. runs the scenario in the strict Udon VM emulator (`udon.vm`),
//!   4. compares the emulator's log with the reference log.

const std = @import("std");
const wasdon = @import("wasdon_zig");
const udon = wasdon.udon;
const Vm = udon.Vm;

const testing = std.testing;
const node_list = @embedFile("udon_nodes.txt");

pub const Stats = struct {
    heap_slots: usize,
    code_bytes: u32,
    steps: u64,
    extern_calls: u64,
};

/// Unity mocks, mirrored by `tools/golden.mjs`.
const Host = struct {
    clones: u32 = 0,

    fn call(ctx: ?*anyopaque, vm: *Vm, name: []const u8, args: []const u32) udon.vm.Error!bool {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const eql = std.mem.eql;
        if (eql(u8, name, "UnityEngineTime.__get_deltaTime__SystemSingle")) {
            vm.set(args[0], .single, 0.25);
        } else if (eql(u8, name, "UnityEngineMathf.__Sin__SystemSingle__SystemSingle")) {
            vm.set(args[1], .single, @floatCast(@sin(@as(f64, try vm.get(args[0], .single)))));
        } else if (eql(u8, name, "UnityEngineMathf.__Cos__SystemSingle__SystemSingle")) {
            vm.set(args[1], .single, @floatCast(@cos(@as(f64, try vm.get(args[0], .single)))));
        } else if (eql(u8, name, "UnityEngineTexture2D.__LoadRawTextureData__SystemByteArray__SystemVoid")) {
            _ = try object(vm, args[0]);
            const data = (try vm.getArray(args[1])).bytes;
            var h: u32 = 0x811C9DC5;
            for (data) |b| h = (h ^ b) *% 0x01000193;
            try vm.log.print(vm.arena.allocator(), "texture <- {d} bytes {x:0>8}\n", .{ data.len, h });
        } else if (eql(u8, name, "UnityEngineTexture2D.__Apply__SystemVoid")) {
            _ = try object(vm, args[0]);
            try vm.log.appendSlice(vm.arena.allocator(), "texture applied\n");
        } else if (eql(u8, name, "UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3")) {
            const v = try vm.newObject("UnityEngineVector3");
            for (0..3) |i| v.data[i] = try vm.get(args[i], .single);
            vm.heap[args[3]] = .{ .object = v };
        } else if (eql(u8, name, "UnityEngineVector3.__op_Addition__UnityEngineVector3_UnityEngineVector3__UnityEngineVector3")) {
            const a = try object(vm, args[0]);
            const b = try object(vm, args[1]);
            const v = try vm.newObject("UnityEngineVector3");
            for (0..3) |i| v.data[i] = @as(f32, @floatCast(a.data[i] + b.data[i]));
            vm.heap[args[2]] = .{ .object = v };
        } else if (eql(u8, name, "UnityEngineTransform.__get_position__UnityEngineVector3")) {
            const v = try vm.newObject("UnityEngineVector3");
            v.data = (try object(vm, args[0])).data;
            vm.heap[args[1]] = .{ .object = v };
        } else if (eql(u8, name, "UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid")) {
            const v = try object(vm, args[1]);
            (try object(vm, args[0])).data = v.data;
            try vm.log.print(vm.arena.allocator(), "position = {d:.3}, {d:.3}, {d:.3}\n", .{ v.data[0], v.data[1], v.data[2] });
        } else if (eql(u8, name, "UnityEngineComponent.__get_gameObject__UnityEngineGameObject")) {
            _ = try object(vm, args[0]);
            vm.heap[args[1]] = .{ .object = try vm.newObject("UnityEngineGameObject") };
        } else if (eql(u8, name, "VRCInstantiate.__Instantiate__UnityEngineGameObject__UnityEngineGameObject")) {
            _ = try object(vm, args[0]);
            self.clones += 1;
            try vm.log.print(vm.arena.allocator(), "instantiate #{d}\n", .{self.clones});
            vm.heap[args[1]] = .{ .object = try vm.newObject("UnityEngineGameObject") };
        } else return false;
        return true;
    }

    fn object(vm: *Vm, idx: u32) udon.vm.Error!*udon.vm.Object {
        return switch (vm.heap[idx]) {
            .object => |o| o,
            else => error.HeapTypeMismatch,
        };
    }
};

pub const RunOptions = struct {
    stats: ?*Stats = null,
    /// Translation warnings the module is expected to produce.
    warnings: usize = 0,
};

/// Translate, check and run one WASM module; returns the emulator log.
pub fn run(arena: std.mem.Allocator, wasm_bytes: []const u8, scenario: []const u8, options: RunOptions) ![]const u8 {
    var nodes = try udon.check.loadNodes(arena, node_list);
    var diagnostics: wasdon.Diagnostics = .init(arena);
    var text: std.Io.Writer.Allocating = .init(arena);
    try wasdon.translateBytes(arena, wasm_bytes, &text.writer, .{ .nodes = &nodes, .diagnostics = &diagnostics });
    if (diagnostics.warnings.items.len != options.warnings) {
        for (diagnostics.warnings.items) |w| std.debug.print("warning: {s}\n", .{w});
        return error.UnexpectedWarnings;
    }

    var diag: udon.text.Diag = .{};
    const prog = udon.text.parse(arena, text.written(), &diag) catch |e| {
        std.debug.print("uasm:{d}: {s}\n", .{ diag.line, diag.msg });
        return e;
    };
    const report = try udon.check.check(arena, &prog, .{ .nodes = &nodes });
    for (report.issues[0..@min(report.issues.len, 20)]) |issue| std.debug.print("uasm:{d}: {s}\n", .{ issue.line, issue.msg });
    try testing.expect(report.ok());
    try testing.expectEqual(report.heap_slots, diagnostics.heap_slots);

    var vm = try Vm.init(arena, &prog);
    // Stand-in for a texture assigned in the Inspector.
    if (prog.findVar("_texture")) |v| vm.heap[v] = .{ .object = try vm.newObject("UnityEngineTexture2D") };
    var host: Host = .{};
    vm.host = Host.call;
    vm.host_ctx = &host;
    var lines = std.mem.tokenizeScalar(u8, scenario, '\n');
    while (lines.next()) |line| {
        const event = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
        if (event.len == 0) continue;
        vm.runEvent(event) catch |e| {
            std.debug.print("event {s}: {s}: {s}\nlog so far:\n{s}\n", .{ event, @errorName(e), vm.fault, vm.log.items });
            return e;
        };
    }
    if (options.stats) |s| s.* = .{ .heap_slots = report.heap_slots, .code_bytes = prog.code_size, .steps = vm.steps, .extern_calls = vm.extern_calls };
    return vm.log.items;
}

test {
    _ = @import("ops.zig");
}

test "hand-assembled programs: control flow, calls, memory, imports" {
    const structure = @import("structure.zig");
    const builder = @import("wasm_builder.zig");
    for (structure.cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        errdefer std.debug.print("case '{s}' failed\n", .{case.name});
        var m: builder.Module = .{ .a = arena.allocator() };
        try case.build(&m);
        const log = try run(arena.allocator(), try m.build(), case.scenario, .{ .warnings = case.warnings });
        try testing.expectEqualStrings(case.expected, log);
    }
}

fn example(comptime name: []const u8) !Stats {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stats: Stats = undefined;
    const log = try run(arena.allocator(), @embedFile(name ++ ".wasm"), @embedFile(name ++ ".scenario"), .{ .stats = &stats });
    try testing.expectEqualStrings(@embedFile(name ++ ".log"), log);
    return stats;
}

test "bench: every feature test matches the reference engine" {
    const stats = try example("bench");
    // Regression guards for the optimiser (the original per-instruction
    // lowering needed 3042 heap slots and 77399 extern calls here).
    try testing.expect(stats.heap_slots < 700);
    try testing.expect(stats.extern_calls < 16_000);
}

test "udon-orbit: object handles and Unity externs" {
    _ = try example("udon-orbit");
}

// The workloads below all fit the 512-slot heap of a stock Udon Assembly
// Program Asset (`docs/spec_heap_budget.md`).

test "mandelbrot: f64 arithmetic, texture upload through a byte[] handle" {
    try testing.expect((try example("mandelbrot")).heap_slots <= 512);
}

test "pi: integer division and remainder" {
    try testing.expect((try example("pi")).heap_slots <= 512);
}

test "blocks: a whole game driven by events" {
    try testing.expect((try example("blocks")).heap_slots <= 512);
}

test "qoi: image encode / decode round trip" {
    try testing.expect((try example("qoi")).heap_slots <= 512);
}

test "ragdoll: f32 physics and a behaviour state machine" {
    try testing.expect((try example("ragdoll")).heap_slots <= 512);
}
