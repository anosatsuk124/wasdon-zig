//! Hand-assembled programs for control flow, calls, memory and host imports.
//!
//! Each case builds a small module instruction by instruction, names the
//! events to fire and states the exact log it must produce. `zig build
//! dump-fixtures` writes the cases to `zig-out/fixtures/` so
//! `tools/golden.mjs --check` can replay them in a real WASM engine, which
//! validates both the modules and the expectations written here.

const std = @import("std");
const builder = @import("wasm_builder.zig");

const Module = builder.Module;
const ValType = builder.ValType;

pub const Case = struct {
    name: []const u8,
    build: *const fn (m: *Module) anyerror!void,
    scenario: []const u8 = "_start",
    expected: []const u8,
    /// Uses host imports or trap output only the emulator models.
    emulator_only: bool = false,
    /// Translation is expected to report this many warnings.
    warnings: usize = 0,
};

const log_i32 = 0;
const log_i64 = 1;
const log_f32 = 2;
const log_f64 = 3;

/// Imports 0..3: `Debug.Log` taking one value of each numeric type.
fn addLogs(m: *Module) !void {
    for ([_]ValType{ .i32, .i64, .f32, .f64 }) |ty| {
        _ = try m.addImport("UnityEngineDebug.__Log__SystemObject__SystemVoid", .{ .params = &.{ty} });
    }
}

const i32_to_i32: builder.FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };

pub const cases = [_]Case{
    .{ .name = "branches", .build = branches, .expected = "10\n2\n15\n7\n" },
    .{ .name = "br_table", .build = brTable, .expected = "100\n101\n102\n103\n104\n199\n199\n199\n10\n11\n12\n12\n15\n5\n15\n" },
    .{ .name = "select", .build = select, .expected = "11\n22\n3\n9\n1.5\n10\n7\n" },
    .{ .name = "variables", .build = variables, .expected = "6\n4294967298\n1.5\n-2.25\n6\n100\n0\n42\n18\n" },
    .{ .name = "calls", .build = calls, .expected = "3.75\n8\n7\n21\n40\n" },
    .{ .name = "recursion", .build = recursion, .expected = "3628800\n610\n1\n0\n5\n20100\n" },
    .{
        .name = "memory",
        .build = memory,
        .expected = "1144201745\n1430532898\n-2005440939\n128\n-128\n33023\n-32513\n" ++
            "-8613303245920329199\n-128\n128\n-32513\n33023\n-2005440939\n2289526357\n" ++
            "4\n1\n16973572\n-854393084\n1234605616436508552\n287454020\n-559038737\n65535\n171\n" ++
            "1.5\n1069547520\n-2.5\n-4610560118520545280\n",
    },
    .{ .name = "memory_grow", .build = memoryGrow, .expected = "1\n1\n2\n1144201745\n77\n-1\n2\n" },
    .{ .name = "bulk_memory", .build = bulkMemory, .expected = "-1414812757\n0\n0\n171\n-8613303245920329199\n7373874951294624273\n1178944579\n" },
    .{ .name = "start_and_locals", .build = startAndLocals, .scenario = "_start\n_start", .expected = "123\n5\n5\n77\n5\n5\n77\n" },
    .{ .name = "any_event_initialises", .build = startAndLocals, .scenario = "_update\n_start", .expected = "123\n1\n5\n5\n77\n" },
    .{ .name = "block_params", .build = blockParams, .expected = "15\n" },
    .{ .name = "unreachable", .build = unreachable_, .expected = "1\n[error] wasdon: unreachable executed\n", .emulator_only = true },
    .{ .name = "host_imports", .build = hostImports, .expected = "hello\n1\n4294967295\n-1\n200\n5\n3\n2\n42\n1\n", .emulator_only = true },
    .{ .name = "unknown_import", .build = unknownImport, .expected = "1\n[error] wasdon: call to unsupported import env.mystery\n", .emulator_only = true, .warnings = 1 },
};

fn branches(m: *Module) !void {
    try addLogs(m);
    var c = m.code();
    // A conditional branch carrying the block result.
    try c.begin("block", .i32);
    try c.i32c(10);
    try c.i32c(1);
    try c.idx("br_if", 0);
    try c.op("drop");
    try c.i32c(20);
    try c.end();
    try c.idx("call", log_i32);
    // if / else producing a value.
    try c.i32c(0);
    try c.begin("if_", .i32);
    try c.i32c(1);
    try c.else_();
    try c.i32c(2);
    try c.end();
    try c.idx("call", log_i32);
    // Loop: sum 1..5 (local 0 = i, local 1 = sum).
    try c.begin("block", null);
    try c.begin("loop", null);
    try c.idx("local_get", 0);
    try c.i32c(1);
    try c.op("i32_add");
    try c.idx("local_tee", 0);
    try c.idx("local_get", 1);
    try c.op("i32_add");
    try c.idx("local_set", 1);
    try c.idx("local_get", 0);
    try c.i32c(5);
    try c.op("i32_lt_s");
    try c.idx("br_if", 0);
    try c.end();
    try c.end();
    try c.idx("local_get", 1);
    try c.idx("call", log_i32);
    // Branch out of two blocks, skipping dead code.
    try c.begin("block", null);
    try c.begin("block", null);
    try c.idx("br", 1);
    try c.end();
    try c.i32c(99);
    try c.idx("call", log_i32);
    try c.end();
    try c.i32c(7);
    try c.idx("call", log_i32);
    try m.exportFunc("_start", try m.addFunc(.{}, &.{ .i32, .i32 }, &c));
}

fn brTable(m: *Module) !void {
    try addLogs(m);
    // Six targets: lowered to a jump table.
    var c = m.code();
    for (0..6) |_| try c.begin("block", null);
    try c.idx("local_get", 0);
    try c.raw(&.{ builder.opcode("br_table"), 5, 0, 1, 2, 3, 4, 5 });
    for (0..5) |i| {
        try c.end();
        try c.i32c(@intCast(100 + i));
        try c.op("return_");
    }
    try c.end();
    try c.i32c(199);
    const classify = try m.addFunc(i32_to_i32, &.{}, &c);

    // Three targets: lowered to a comparison chain.
    c = m.code();
    for (0..3) |_| try c.begin("block", null);
    try c.idx("local_get", 0);
    try c.raw(&.{ builder.opcode("br_table"), 2, 0, 1, 2 });
    for (0..2) |i| {
        try c.end();
        try c.i32c(@intCast(10 + i));
        try c.op("return_");
    }
    try c.end();
    try c.i32c(12);
    const small = try m.addFunc(i32_to_i32, &.{}, &c);

    // Targets that take a value.
    c = m.code();
    try c.begin("block", .i32);
    try c.begin("block", .i32);
    try c.i32c(5);
    try c.idx("local_get", 0);
    try c.raw(&.{ builder.opcode("br_table"), 2, 0, 1, 0 });
    try c.end();
    try c.i32c(10);
    try c.op("i32_add");
    try c.end();
    const valued = try m.addFunc(i32_to_i32, &.{}, &c);

    c = m.code();
    for ([_]i32{ 0, 1, 2, 3, 4, 5, -1, 100 }) |v| {
        try c.i32c(v);
        try c.idx("call", classify);
        try c.idx("call", log_i32);
    }
    for ([_]i32{ 0, 1, 2, 7 }) |v| {
        try c.i32c(v);
        try c.idx("call", small);
        try c.idx("call", log_i32);
    }
    for ([_]i32{ 0, 1, 2 }) |v| {
        try c.i32c(v);
        try c.idx("call", valued);
        try c.idx("call", log_i32);
    }
    try m.exportFunc("_start", try m.addFunc(.{}, &.{}, &c));
}

fn select(m: *Module) !void {
    try addLogs(m);
    var c = m.code();
    // Constant operands, both outcomes.
    for ([_]i32{ 1, 0 }) |cond| {
        try c.i32c(11);
        try c.i32c(22);
        try c.i32c(cond);
        try c.op("select");
        try c.idx("call", log_i32);
    }
    // min / max of two locals through a fused comparison.
    try c.i32c(3);
    try c.idx("local_set", 0);
    try c.i32c(9);
    try c.idx("local_set", 1);
    inline for (.{ "i32_lt_s", "i32_gt_s" }) |cmp| {
        try c.idx("local_get", 0);
        try c.idx("local_get", 1);
        try c.idx("local_get", 0);
        try c.idx("local_get", 1);
        try c.op(cmp);
        try c.op("select");
        try c.idx("call", log_i32);
    }
    // Plain i32 condition, f64 operands.
    try c.f64c(1.5);
    try c.f64c(2.5);
    try c.idx("local_get", 0);
    try c.op("select");
    try c.idx("call", log_f64);
    // Computed operands, negated condition.
    try c.idx("local_get", 0);
    try c.i32c(1);
    try c.op("i32_add");
    try c.idx("local_get", 1);
    try c.i32c(1);
    try c.op("i32_add");
    try c.idx("local_get", 0);
    try c.op("i32_eqz");
    try c.op("select");
    try c.idx("call", log_i32);
    try c.i64c(7);
    try c.i64c(8);
    try c.i32c(0);
    try c.op("i32_eqz");
    try c.op("select");
    try c.idx("call", log_i64);
    try m.exportFunc("_start", try m.addFunc(.{}, &.{ .i32, .i32 }, &c));
}

fn variables(m: *Module) !void {
    try addLogs(m);
    const g_i32 = try m.addGlobal(.i32, 5);
    const g_i64 = try m.addGlobal(.i64, 0x1_0000_0001);
    const g_f32 = try m.addGlobal(.f32, @as(u32, @bitCast(@as(f32, 1.5))));
    const g_f64 = try m.addGlobal(.f64, @bitCast(@as(f64, -2.25)));
    var c = m.code();
    try c.idx("global_get", g_i32);
    try c.i32c(1);
    try c.op("i32_add");
    try c.idx("global_set", g_i32);
    try c.idx("global_get", g_i32);
    try c.idx("call", log_i32);
    try c.idx("global_get", g_i64);
    try c.i64c(1);
    try c.op("i64_add");
    try c.idx("global_set", g_i64);
    try c.idx("global_get", g_i64);
    try c.idx("call", log_i64);
    try c.idx("global_get", g_f32);
    try c.idx("call", log_f32);
    try c.idx("global_get", g_f64);
    try c.idx("call", log_f64);
    // A value read before the variable is overwritten keeps the old value.
    try c.idx("global_get", g_i32);
    try c.i32c(100);
    try c.idx("global_set", g_i32);
    try c.idx("call", log_i32);
    try c.idx("global_get", g_i32);
    try c.idx("call", log_i32);
    try c.idx("local_get", 0);
    try c.i32c(42);
    try c.idx("local_set", 0);
    try c.idx("call", log_i32);
    try c.idx("local_get", 0);
    try c.idx("call", log_i32);
    try c.i32c(9);
    try c.idx("local_tee", 0);
    try c.idx("local_get", 0);
    try c.op("i32_add");
    try c.idx("call", log_i32);
    try m.exportFunc("_start", try m.addFunc(.{}, &.{.i32}, &c));
}

fn calls(m: *Module) !void {
    try addLogs(m);
    // Mixed parameter types.
    var c = m.code();
    try c.idx("local_get", 3);
    try c.idx("local_get", 2);
    try c.op("f64_promote_f32");
    try c.op("f64_add");
    try c.idx("local_get", 1);
    try c.op("f64_convert_i64_s");
    try c.op("f64_add");
    try c.idx("local_get", 0);
    try c.op("f64_convert_i32_s");
    try c.op("f64_add");
    const mix = try m.addFunc(.{ .params = &.{ .i32, .i64, .f32, .f64 }, .results = &.{.f64} }, &.{}, &c);
    // Two results.
    c = m.code();
    try c.i32c(7);
    try c.i64c(8);
    const pair = try m.addFunc(.{ .results = &.{ .i32, .i64 } }, &.{}, &c);
    c = m.code();
    try c.idx("local_get", 0);
    try c.i32c(1);
    try c.op("i32_add");
    const add_one = try m.addFunc(i32_to_i32, &.{}, &c);
    c = m.code();
    try c.idx("local_get", 0);
    try c.i32c(2);
    try c.op("i32_mul");
    const double = try m.addFunc(i32_to_i32, &.{}, &c);
    m.table = try m.a.dupe(u32, &.{ add_one, double });
    const sig = try m.addType(i32_to_i32);

    c = m.code();
    try c.i32c(1);
    try c.i64c(2);
    try c.f32c(0.5);
    try c.f64c(0.25);
    try c.idx("call", mix);
    try c.idx("call", log_f64);
    try c.idx("call", pair);
    try c.idx("call", log_i64);
    try c.idx("call", log_i32);
    for ([_]i32{ 0, 1 }) |slot| {
        try c.i32c(20);
        try c.i32c(slot);
        try c.idx("call_indirect", sig);
        try c.raw(&.{0});
        try c.idx("call", log_i32);
    }
    try m.exportFunc("_start", try m.addFunc(.{}, &.{}, &c));
}

fn recursion(m: *Module) !void {
    try addLogs(m);
    // fact(n) = n <= 1 ? 1 : n * fact(n - 1) — `n` stays on the stack across the call.
    var c = m.code();
    try c.idx("local_get", 0);
    try c.i32c(1);
    try c.op("i32_le_s");
    try c.begin("if_", .i32);
    try c.i32c(1);
    try c.else_();
    try c.idx("local_get", 0);
    try c.idx("local_get", 0);
    try c.i32c(1);
    try c.op("i32_sub");
    try c.idx("call", m.nextFunc());
    try c.op("i32_mul");
    try c.end();
    const fact = try m.addFunc(i32_to_i32, &.{}, &c);
    // fib(n): the first call's result is live during the second call.
    c = m.code();
    try c.idx("local_get", 0);
    try c.i32c(2);
    try c.op("i32_lt_s");
    try c.begin("if_", .i32);
    try c.idx("local_get", 0);
    try c.else_();
    try c.idx("local_get", 0);
    try c.i32c(1);
    try c.op("i32_sub");
    try c.idx("call", m.nextFunc());
    try c.idx("local_get", 0);
    try c.i32c(2);
    try c.op("i32_sub");
    try c.idx("call", m.nextFunc());
    try c.op("i32_add");
    try c.end();
    const fib = try m.addFunc(i32_to_i32, &.{}, &c);
    // Mutual recursion: is_even / is_odd.
    const is_even = m.nextFunc();
    inline for (.{ .{ 1, is_even + 1 }, .{ 0, is_even } }) |spec| {
        c = m.code();
        try c.idx("local_get", 0);
        try c.op("i32_eqz");
        try c.begin("if_", .i32);
        try c.i32c(spec[0]);
        try c.else_();
        try c.idx("local_get", 0);
        try c.i32c(1);
        try c.op("i32_sub");
        try c.idx("call", spec[1]);
        try c.end();
        _ = try m.addFunc(i32_to_i32, &.{}, &c);
    }
    // Recursion through the function table.
    const sig = try m.addType(i32_to_i32);
    c = m.code();
    try c.idx("local_get", 0);
    try c.op("i32_eqz");
    try c.begin("if_", .i32);
    try c.i32c(0);
    try c.else_();
    try c.i32c(1);
    try c.idx("local_get", 0);
    try c.i32c(1);
    try c.op("i32_sub");
    try c.i32c(0);
    try c.idx("call_indirect", sig);
    try c.raw(&.{0});
    try c.op("i32_add");
    try c.end();
    const count_down = try m.addFunc(i32_to_i32, &.{}, &c);
    m.table = try m.a.dupe(u32, &.{count_down});
    // sum_to(n) = n == 0 ? 0 : n + sum_to(n - 1), 200 frames deep.
    c = m.code();
    try c.idx("local_get", 0);
    try c.op("i32_eqz");
    try c.begin("if_", .i32);
    try c.i32c(0);
    try c.else_();
    try c.idx("local_get", 0);
    try c.idx("local_get", 0);
    try c.i32c(1);
    try c.op("i32_sub");
    try c.idx("call", m.nextFunc());
    try c.op("i32_add");
    try c.end();
    const sum_to = try m.addFunc(i32_to_i32, &.{}, &c);

    c = m.code();
    inline for (.{ .{ fact, 10 }, .{ fib, 15 }, .{ is_even, 10 }, .{ is_even, 7 }, .{ count_down, 5 }, .{ sum_to, 200 } }) |call| {
        try c.i32c(call[1]);
        try c.idx("call", call[0]);
        try c.idx("call", log_i32);
    }
    try m.exportFunc("_start", try m.addFunc(.{}, &.{}, &c));
}

const sample = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x80 };

fn loadAndLog(c: *builder.Code, comptime load: []const u8, base: i32, offset: u32, log: u32) !void {
    try c.i32c(base);
    try c.mem(load, offset);
    try c.idx("call", log);
}

fn memory(m: *Module) !void {
    try addLogs(m);
    try m.addData(16, &sample);
    var c = m.code();
    try loadAndLog(&c, "i32_load", 16, 0, log_i32);
    try loadAndLog(&c, "i32_load", 17, 0, log_i32); // unaligned
    try loadAndLog(&c, "i32_load", 0, 20, log_i32); // constant offset
    try loadAndLog(&c, "i32_load8_u", 31, 0, log_i32);
    try loadAndLog(&c, "i32_load8_s", 31, 0, log_i32);
    try loadAndLog(&c, "i32_load16_u", 30, 0, log_i32);
    try loadAndLog(&c, "i32_load16_s", 30, 0, log_i32);
    try loadAndLog(&c, "i64_load", 16, 0, log_i64);
    try loadAndLog(&c, "i64_load8_s", 31, 0, log_i64);
    try loadAndLog(&c, "i64_load8_u", 31, 0, log_i64);
    try loadAndLog(&c, "i64_load16_s", 30, 0, log_i64);
    try loadAndLog(&c, "i64_load16_u", 30, 0, log_i64);
    try loadAndLog(&c, "i64_load32_s", 20, 0, log_i64);
    try loadAndLog(&c, "i64_load32_u", 20, 0, log_i64);

    // The address comes from a local so the dynamic-offset path is used too.
    try c.i32c(100);
    try c.idx("local_set", 0);
    try c.idx("local_get", 0);
    try c.i32c(0x01020304);
    try c.mem("i32_store", 0);
    try loadAndLog(&c, "i32_load8_u", 100, 0, log_i32);
    try c.idx("local_get", 0);
    try c.mem("i32_load8_u", 3);
    try c.idx("call", log_i32);
    try c.idx("local_get", 0);
    try c.i32c(0x1FF);
    try c.mem("i32_store8", 1);
    try loadAndLog(&c, "i32_load", 100, 0, log_i32);
    try c.idx("local_get", 0);
    try c.i32c(0xABCD12);
    try c.mem("i32_store16", 2);
    try loadAndLog(&c, "i32_load", 100, 0, log_i32);
    try c.i32c(108);
    try c.i64c(0x1122334455667788);
    try c.mem("i64_store", 0);
    try loadAndLog(&c, "i64_load", 108, 0, log_i64);
    try loadAndLog(&c, "i32_load", 112, 0, log_i32);
    try c.i32c(120);
    try c.i64c(0x1_DEADBEEF);
    try c.mem("i64_store32", 0);
    try loadAndLog(&c, "i32_load", 120, 0, log_i32);
    try c.i32c(124);
    try c.i64c(0x1FFFF);
    try c.mem("i64_store16", 0);
    try loadAndLog(&c, "i32_load16_u", 124, 0, log_i32);
    try c.i32c(126);
    try c.i64c(0x1AB);
    try c.mem("i64_store8", 0);
    try loadAndLog(&c, "i32_load8_u", 126, 0, log_i32);
    try c.i32c(128);
    try c.f32c(1.5);
    try c.mem("f32_store", 0);
    try loadAndLog(&c, "f32_load", 128, 0, log_f32);
    try loadAndLog(&c, "i32_load", 128, 0, log_i32);
    try c.i32c(136);
    try c.f64c(-2.5);
    try c.mem("f64_store", 0);
    try loadAndLog(&c, "f64_load", 136, 0, log_f64);
    try loadAndLog(&c, "i64_load", 136, 0, log_i64);
    try m.exportFunc("_start", try m.addFunc(.{}, &.{.i32}, &c));
}

fn memoryGrow(m: *Module) !void {
    try addLogs(m);
    m.memory_max = 4;
    try m.addData(16, &sample);
    var c = m.code();
    try c.raw(&.{ builder.opcode("memory_size"), 0 });
    try c.idx("call", log_i32);
    try c.i32c(1);
    try c.raw(&.{ builder.opcode("memory_grow"), 0 });
    try c.idx("call", log_i32);
    try c.raw(&.{ builder.opcode("memory_size"), 0 });
    try c.idx("call", log_i32);
    // Old contents survive; the new page is usable.
    try loadAndLog(&c, "i32_load", 16, 0, log_i32);
    try c.i32c(65536 + 8);
    try c.i32c(77);
    try c.mem("i32_store", 0);
    try loadAndLog(&c, "i32_load", 65536, 8, log_i32);
    // Growing past the maximum fails without changing the size.
    try c.i32c(100);
    try c.raw(&.{ builder.opcode("memory_grow"), 0 });
    try c.idx("call", log_i32);
    try c.raw(&.{ builder.opcode("memory_size"), 0 });
    try c.idx("call", log_i32);
    try m.exportFunc("_start", try m.addFunc(.{}, &.{}, &c));
}

fn bulkMemory(m: *Module) !void {
    try addLogs(m);
    try m.addData(16, &sample);
    try m.addData(null, "ABCDEFGH");
    var c = m.code();
    // memory.fill with a non-zero byte, then with zero.
    try c.i32c(200);
    try c.i32c(0xAB);
    try c.i32c(10);
    try c.fc(11, &.{0});
    try loadAndLog(&c, "i32_load", 200, 0, log_i32);
    try loadAndLog(&c, "i32_load8_u", 210, 0, log_i32);
    try c.i32c(200);
    try c.i32c(0);
    try c.i32c(4);
    try c.fc(11, &.{0});
    try loadAndLog(&c, "i32_load", 200, 0, log_i32);
    try loadAndLog(&c, "i32_load8_u", 204, 0, log_i32);
    // memory.copy, then an overlapping copy (memmove semantics).
    try c.i32c(300);
    try c.i32c(16);
    try c.i32c(8);
    try c.fc(10, &.{ 0, 0 });
    try loadAndLog(&c, "i64_load", 300, 0, log_i64);
    try c.i32c(302);
    try c.i32c(300);
    try c.i32c(6);
    try c.fc(10, &.{ 0, 0 });
    try loadAndLog(&c, "i64_load", 300, 0, log_i64);
    // memory.init from the passive segment, then data.drop.
    try c.i32c(400);
    try c.i32c(2);
    try c.i32c(4);
    try c.fc(8, &.{ 1, 0 });
    try c.fc(9, &.{1});
    try loadAndLog(&c, "i32_load", 400, 0, log_i32);
    try m.exportFunc("_start", try m.addFunc(.{}, &.{}, &c));
}

fn startAndLocals(m: *Module) !void {
    try addLogs(m);
    const g = try m.addGlobal(.i32, 0);
    // The start function runs once, before the first event.
    var c = m.code();
    try c.i32c(77);
    try c.idx("global_set", g);
    try c.i32c(123);
    try c.idx("call", log_i32);
    m.start = try m.addFunc(.{}, &.{}, &c);
    // A local read before being written is zero on every call.
    c = m.code();
    try c.idx("local_get", 0);
    try c.i32c(5);
    try c.op("i32_add");
    try c.idx("local_tee", 0);
    const bump = try m.addFunc(.{ .results = &.{.i32} }, &.{.i32}, &c);

    c = m.code();
    for (0..2) |_| {
        try c.idx("call", bump);
        try c.idx("call", log_i32);
    }
    try c.idx("global_get", g);
    try c.idx("call", log_i32);
    try m.exportFunc("_start", try m.addFunc(.{}, &.{}, &c));
    c = m.code();
    try c.i32c(1);
    try c.idx("call", log_i32);
    try m.exportFunc("_update", try m.addFunc(.{}, &.{}, &c));
}

fn blockParams(m: *Module) !void {
    try addLogs(m);
    const loop_type = try m.addType(.{ .params = &.{ .i32, .i32 }, .results = &.{.i32} });
    // (acc, n) -> acc + n + (n-1) + ... + 1, as a loop with parameters.
    var c = m.code();
    try c.i32c(0);
    try c.i32c(5);
    try c.op("loop");
    try c.uleb(loop_type);
    try c.idx("local_set", 0);
    try c.idx("local_set", 1);
    try c.idx("local_get", 1);
    try c.idx("local_get", 0);
    try c.op("i32_add");
    try c.idx("local_get", 0);
    try c.i32c(1);
    try c.op("i32_sub");
    try c.idx("local_tee", 0);
    try c.idx("local_get", 0);
    try c.idx("br_if", 0);
    try c.op("drop");
    try c.end();
    try c.idx("call", log_i32);
    try m.exportFunc("_start", try m.addFunc(.{}, &.{ .i32, .i32 }, &c));
}

fn unreachable_(m: *Module) !void {
    try addLogs(m);
    var c = m.code();
    try c.i32c(1);
    try c.idx("call", log_i32);
    try c.op("unreachable_");
    try m.exportFunc("_start", try m.addFunc(.{}, &.{}, &c));
}

fn hostImports(m: *Module) !void {
    try addLogs(m);
    const log_str = try m.addImport("UnityEngineDebug.__Log__SystemString__SystemVoid", .{ .params = &.{ .i32, .i32 } });
    const to_int = try m.addImport("SystemConvert.__ToInt32__SystemBoolean__SystemInt32", i32_to_i32);
    const from_u32 = try m.addImport("SystemConvert.__ToInt64__SystemUInt32__SystemInt64", .{ .params = &.{.i32}, .results = &.{.i64} });
    const to_u32 = try m.addImport("SystemConvert.__ToUInt32__SystemInt64__SystemUInt32", .{ .params = &.{.i64}, .results = &.{.i32} });
    const to_byte = try m.addImport("SystemConvert.__ToByte__SystemInt32__SystemByte", i32_to_i32);
    const to_u64 = try m.addImport("SystemConvert.__ToUInt64__SystemInt64__SystemUInt64", .{ .params = &.{.i64}, .results = &.{.i64} });
    const div_rem = try m.addImport("SystemMath.__DivRem__SystemInt64_SystemInt64_SystemInt64Ref__SystemInt64", .{ .params = &.{ .i64, .i64, .i32 }, .results = &.{.i64} });
    const to_string = try m.addImport("SystemInt32.__ToString__SystemString", i32_to_i32);
    const to_bool = try m.addImport("SystemConvert.__ToBoolean__SystemInt32__SystemBoolean", i32_to_i32);
    try m.addData(64, "hello");

    var c = m.code();
    // (ptr, len) becomes a SystemString.
    try c.i32c(64);
    try c.i32c(5);
    try c.idx("call", log_str);
    // i32 -> SystemBoolean parameter.
    try c.i32c(5);
    try c.idx("call", to_int);
    try c.idx("call", log_i32);
    // i32 -> SystemUInt32 parameter keeps the bit pattern.
    try c.i32c(-1);
    try c.idx("call", from_u32);
    try c.idx("call", log_i64);
    // SystemUInt32 result -> i32.
    try c.i64c(0xFFFFFFFF);
    try c.idx("call", to_u32);
    try c.idx("call", log_i32);
    // Narrow primitive result.
    try c.i32c(200);
    try c.idx("call", to_byte);
    try c.idx("call", log_i32);
    // SystemUInt64 result -> i64.
    try c.i64c(5);
    try c.idx("call", to_u64);
    try c.idx("call", log_i64);
    // By-reference parameter: written back to linear memory.
    try c.i64c(17);
    try c.i64c(5);
    try c.i32c(500);
    try c.idx("call", div_rem);
    try c.idx("call", log_i64);
    try loadAndLog(&c, "i64_load", 500, 0, log_i64);
    // Instance method (`this` first) returning an object handle, which is
    // then passed on to another extern.
    try c.i32c(42);
    try c.idx("call", to_string);
    try c.idx("call", log_i32);
    // SystemBoolean result used directly as a condition.
    try c.i32c(7);
    try c.idx("call", to_bool);
    try c.begin("if_", .i32);
    try c.i32c(1);
    try c.else_();
    try c.i32c(0);
    try c.end();
    try c.idx("call", log_i32);
    try m.exportFunc("_start", try m.addFunc(.{}, &.{}, &c));
}

fn unknownImport(m: *Module) !void {
    try addLogs(m);
    const mystery = try m.addImport("mystery", i32_to_i32);
    var c = m.code();
    try c.i32c(1);
    try c.idx("call", log_i32);
    try c.i32c(2);
    try c.idx("call", mystery);
    try c.idx("call", log_i32);
    try m.exportFunc("_start", try m.addFunc(.{}, &.{}, &c));
}
