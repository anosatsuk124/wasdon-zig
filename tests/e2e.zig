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

/// Translate, check and run one WASM module; returns the emulator log.
pub fn run(arena: std.mem.Allocator, wasm_bytes: []const u8, scenario: []const u8, stats: ?*Stats) ![]const u8 {
    var nodes = try udon.check.loadNodes(arena, node_list);
    var diagnostics: wasdon.Diagnostics = .init(arena);
    var text: std.Io.Writer.Allocating = .init(arena);
    try wasdon.translateBytes(arena, wasm_bytes, &text.writer, .{ .nodes = &nodes, .diagnostics = &diagnostics });
    for (diagnostics.warnings.items) |w| std.debug.print("warning: {s}\n", .{w});
    try testing.expectEqual(@as(usize, 0), diagnostics.warnings.items.len);

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
    if (stats) |s| s.* = .{ .heap_slots = report.heap_slots, .code_bytes = prog.code_size, .steps = vm.steps, .extern_calls = vm.extern_calls };
    return vm.log.items;
}

fn example(comptime name: []const u8) !Stats {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stats: Stats = undefined;
    const log = try run(arena.allocator(), @embedFile(name ++ ".wasm"), @embedFile(name ++ ".scenario"), &stats);
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
