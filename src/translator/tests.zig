//! Translator tests: build a WASM module in memory, translate it, check the
//! result against the Udon Assembly rules, execute it in the emulator, and
//! compare with WebAssembly semantics computed here.
//!
//! Numeric instructions are tested differentially: each one is evaluated on
//! a grid of edge-case operands, with the operands supplied three ways
//! (globals, constants, locals) because each reaches a different lowering
//! path (shared slots, constant folding, in-place local updates).

const std = @import("std");
const wasm = @import("wasm");
const udon = @import("udon");
const translate_ = @import("translate.zig");

const testing = std.testing;
const I = wasm.Instruction;
const ValType = wasm.types.ValType;
const FuncType = wasm.types.FuncType;
const Vm = udon.vm.Vm;
const Value = udon.vm.Value;

// ----------------------------------------------------------------------
//  Harness
// ----------------------------------------------------------------------

const Program = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    prog: *udon.program.Program,
    vm: *Vm,

    fn deinit(self: *Program) void {
        self.vm.deinit();
        self.prog.deinit();
        self.arena.deinit();
    }

    fn global(self: *Program, name: []const u8) Value {
        return self.vm.getVar(name) orelse std.debug.panic("no Udon variable {s}", .{name});
    }
};

/// Translate, check and load a module. Any checker finding fails the test.
fn load(mod: wasm.Module, meta: ?wasm.UdonMeta) !Program {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var diag: translate_.Diagnostics = .init(a);
    var out: std.Io.Writer.Allocating = .init(a);
    _ = translate_.translate(testing.allocator, mod, meta, &out.writer, .{ .diagnostics = &diag }) catch |e| {
        std.debug.print("translation failed: {t}: {s}\n", .{ e, diag.message });
        return e;
    };
    const text = out.written();
    const prog = try a.create(udon.program.Program);
    prog.* = try udon.program.parse(testing.allocator, text, null);
    errdefer prog.deinit();
    var report = try udon.check.check(testing.allocator, prog);
    defer report.deinit();
    if (!report.ok()) {
        for (report.errors[0..@min(report.errors.len, 10)]) |e| std.debug.print("check: line {d}: {s}\n", .{ e.line, e.message });
        std.debug.print("{s}\n", .{text[0..@min(text.len, 6000)]});
        return error.TestUnexpectedResult;
    }
    const vm = try Vm.init(testing.allocator, prog, .{ .max_steps = 50_000_000 });
    return .{ .arena = arena, .text = text, .prog = prog, .vm = vm };
}

fn bitsOf(v: Value) u64 {
    return switch (v) {
        .int32 => |x| @as(u32, @bitCast(x)),
        .int64 => |x| @bitCast(x),
        .single => |x| @as(u32, @bitCast(x)),
        .double => |x| @bitCast(x),
        .boolean => |x| @intFromBool(x),
        else => std.debug.panic("unexpected value type {s}", .{v.typeName()}),
    };
}

fn valueOf(ty: ValType, bits: u64) Value {
    return switch (ty) {
        .i32 => .{ .int32 = @bitCast(@as(u32, @truncate(bits))) },
        .i64 => .{ .int64 = @bitCast(bits) },
        .f32 => .{ .single = @bitCast(@as(u32, @truncate(bits))) },
        .f64 => .{ .double = @bitCast(bits) },
    };
}

fn constOf(ty: ValType, bits: u64) I {
    return switch (ty) {
        .i32 => .{ .i32_const = @bitCast(@as(u32, @truncate(bits))) },
        .i64 => .{ .i64_const = @bitCast(bits) },
        .f32 => .{ .f32_const = @bitCast(@as(u32, @truncate(bits))) },
        .f64 => .{ .f64_const = @bitCast(bits) },
    };
}

const void_type: FuncType = .{ .params = &.{}, .results = &.{} };

/// A module with one exported nullary function `run` and mutable exported
/// globals `g0…`, one per entry of `globals`.
fn simpleModule(a: std.mem.Allocator, globals: []const ValType, locals: []const wasm.module.LocalGroup, body: []const I) !wasm.Module {
    const gs = try a.alloc(wasm.module.Global, globals.len);
    const exports = try a.alloc(wasm.module.Export, globals.len + 1);
    for (globals, 0..) |ty, i| {
        const init = try a.alloc(I, 1);
        init[0] = constOf(ty, 0);
        gs[i] = .{ .ty = .{ .valtype = ty, .mut = .mutable }, .init = init };
        exports[i] = .{ .name = try std.fmt.allocPrint(a, "g{d}", .{i}), .desc = .{ .global = @intCast(i) } };
    }
    exports[globals.len] = .{ .name = "run", .desc = .{ .func = 0 } };
    const types = try a.dupe(FuncType, &.{void_type});
    const funcs = try a.dupe(u32, &.{0});
    const codes = try a.dupe(wasm.module.Code, &.{.{ .locals = locals, .body = body }});
    const mems = try a.dupe(wasm.types.MemType, &.{.{ .min = 1, .max = 4 }});
    return .{ .types_ = types, .funcs = funcs, .codes = codes, .globals = gs, .exports = exports, .memories = mems };
}

// ----------------------------------------------------------------------
//  Reference semantics
// ----------------------------------------------------------------------

/// How a reference result is to be compared.
const Expect = union(enum) {
    value: u64,
    /// WASM traps; the Udon program must fault.
    trap,
    /// Behaviour the translator documents as differing from WASM
    /// (`docs/spec_numeric_conversion.md` §4); not compared.
    unspecified,
};

fn val(x: anytype) Expect {
    const T = @TypeOf(x);
    return .{ .value = switch (T) {
        bool => @intFromBool(x),
        i32 => @as(u32, @bitCast(x)),
        u32 => x,
        i64 => @bitCast(x),
        u64 => x,
        f32 => @as(u32, @bitCast(x)),
        f64 => @bitCast(x),
        else => @compileError("unsupported " ++ @typeName(T)),
    } };
}

fn intBinary(comptime T: type, op: []const u8, a: T, b: T) Expect {
    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    const S = std.math.Log2Int(T);
    const ua: U = @bitCast(a);
    const ub: U = @bitCast(b);
    const sh: S = @truncate(ub);
    const eql = std.mem.eql;
    if (eql(u8, op, "add")) return val(a +% b);
    if (eql(u8, op, "sub")) return val(a -% b);
    if (eql(u8, op, "mul")) return val(a *% b);
    if (eql(u8, op, "and")) return val(a & b);
    if (eql(u8, op, "or")) return val(a | b);
    if (eql(u8, op, "xor")) return val(a ^ b);
    if (eql(u8, op, "shl")) return val(a << sh);
    if (eql(u8, op, "shr_s")) return val(a >> sh);
    if (eql(u8, op, "shr_u")) return val(ua >> sh);
    if (eql(u8, op, "rotl")) return val(std.math.rotl(U, ua, sh));
    if (eql(u8, op, "rotr")) return val(std.math.rotr(U, ua, sh));
    if (eql(u8, op, "div_s")) return if (b == 0 or (a == std.math.minInt(T) and b == -1)) .trap else val(@divTrunc(a, b));
    if (eql(u8, op, "div_u")) return if (b == 0) .trap else val(ua / ub);
    if (eql(u8, op, "rem_s")) return if (b == 0) .trap else if (b == -1) val(@as(T, 0)) else val(@rem(a, b));
    if (eql(u8, op, "rem_u")) return if (b == 0) .trap else val(ua % ub);
    if (eql(u8, op, "eq")) return val(a == b);
    if (eql(u8, op, "ne")) return val(a != b);
    if (eql(u8, op, "lt_s")) return val(a < b);
    if (eql(u8, op, "le_s")) return val(a <= b);
    if (eql(u8, op, "gt_s")) return val(a > b);
    if (eql(u8, op, "ge_s")) return val(a >= b);
    if (eql(u8, op, "lt_u")) return val(ua < ub);
    if (eql(u8, op, "le_u")) return val(ua <= ub);
    if (eql(u8, op, "gt_u")) return val(ua > ub);
    if (eql(u8, op, "ge_u")) return val(ua >= ub);
    unreachable;
}

fn intUnary(comptime T: type, op: []const u8, a: T) Expect {
    const eql = std.mem.eql;
    if (eql(u8, op, "eqz")) return val(a == 0);
    const r: T = if (eql(u8, op, "clz")) @clz(a) else if (eql(u8, op, "ctz")) @ctz(a) else if (eql(u8, op, "popcnt")) @popCount(a) else unreachable;
    return val(r);
}

fn nearest(comptime T: type, x: T) T {
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) return 2.0 * @round(x / 2.0);
    return r;
}

fn floatBinary(comptime T: type, op: []const u8, a: T, b: T) Expect {
    const eql = std.mem.eql;
    if (eql(u8, op, "add")) return val(a + b);
    if (eql(u8, op, "sub")) return val(a - b);
    if (eql(u8, op, "mul")) return val(a * b);
    if (eql(u8, op, "div")) return val(a / b);
    if (eql(u8, op, "min") or eql(u8, op, "max")) {
        if (std.math.isNan(a) or std.math.isNan(b)) return val(std.math.nan(T));
        // The sign of a zero result follows .NET, not WASM.
        if (a == 0 and b == 0) return .unspecified;
        return val(if (eql(u8, op, "min")) @min(a, b) else @max(a, b));
    }
    if (eql(u8, op, "copysign")) return val(std.math.copysign(a, b));
    if (eql(u8, op, "eq")) return val(a == b);
    if (eql(u8, op, "ne")) return val(a != b);
    if (eql(u8, op, "lt")) return val(a < b);
    if (eql(u8, op, "le")) return val(a <= b);
    if (eql(u8, op, "gt")) return val(a > b);
    if (eql(u8, op, "ge")) return val(a >= b);
    unreachable;
}

fn floatUnary(comptime T: type, op: []const u8, a: T) Expect {
    const eql = std.mem.eql;
    if (eql(u8, op, "abs")) return val(@abs(a));
    if (eql(u8, op, "neg")) return val(-a);
    if (eql(u8, op, "ceil")) return val(@ceil(a));
    if (eql(u8, op, "floor")) return val(@floor(a));
    if (eql(u8, op, "trunc")) return val(@trunc(a));
    if (eql(u8, op, "nearest")) return val(nearest(T, a));
    if (eql(u8, op, "sqrt")) return val(@sqrt(a));
    unreachable;
}

/// `iNN.trunc_fMM_{s,u}`: trap outside the open interval the result fits.
fn truncate(comptime To: type, comptime signed: bool, x: f64, saturating: bool) Expect {
    const Target = if (signed) To else std.meta.Int(.unsigned, @bitSizeOf(To));
    const lo: f64 = @floatFromInt(std.math.minInt(Target));
    const hi: f64 = std.math.ldexp(@as(f64, 1), @bitSizeOf(To) - @as(i32, @intFromBool(signed)));
    if (std.math.isNan(x)) return if (saturating) val(@as(To, 0)) else .trap;
    const t = @trunc(x);
    if (t < lo or t >= hi) {
        if (!saturating) {
            // Unsigned conversions are lowered through the signed 64-bit
            // one and accept some out-of-range inputs.
            return if (signed) .trap else .unspecified;
        }
        const clamped: Target = if (t < lo) std.math.minInt(Target) else std.math.maxInt(Target);
        return val(@as(To, @bitCast(clamped)));
    }
    return val(@as(To, @bitCast(@as(Target, @intFromFloat(t)))));
}

// ----------------------------------------------------------------------
//  Operand grids
// ----------------------------------------------------------------------

const i32_values = [_]i32{ 0, 1, -1, 2, 7, 31, 32, 33, 100, -100, 0xFF, 0x10000, 0x55555555, std.math.maxInt(i32), std.math.minInt(i32), std.math.minInt(i32) + 1 };
const i64_values = [_]i64{ 0, 1, -1, 2, 63, 64, 65, 1000, -1000, 0xFFFF_FFFF, 0x1_0000_0000, 0x5555_5555_5555_5555, std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) + 1, -0x1_0000_0000 };
const f32_values = [_]f32{ 0, -0.0, 1, -1, 0.5, 1.5, 2.5, -2.5, 3.7, -3.7, 1e10, -1e10, 16777216, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) };
const f64_values = [_]f64{ 0, -0.0, 1, -1, 0.5, 1.5, 2.5, -2.5, 3.7, -3.7, 1e300, -1e300, 2147483647.5, 4294967296.0, -2147483649.0, 9223372036854775808.0, -9223372036854775809.0, 18446744073709551616.0, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) };

fn bitsList(comptime T: type, comptime values: []const T) [values.len]u64 {
    var out: [values.len]u64 = undefined;
    for (values, 0..) |x, i| out[i] = val(x).value;
    return out;
}

fn grid(ty: ValType) []const u64 {
    const lists = struct {
        const i32_ = bitsList(i32, &i32_values);
        const i64_ = bitsList(i64, &i64_values);
        const f32_ = bitsList(f32, &f32_values);
        const f64_ = bitsList(f64, &f64_values);
    };
    return switch (ty) {
        .i32 => &lists.i32_,
        .i64 => &lists.i64_,
        .f32 => &lists.f32_,
        .f64 => &lists.f64_,
    };
}

fn isNanBits(ty: ValType, bits: u64) bool {
    return switch (ty) {
        .f32 => std.math.isNan(@as(f32, @bitCast(@as(u32, @truncate(bits))))),
        .f64 => std.math.isNan(@as(f64, @bitCast(bits))),
        else => false,
    };
}

// ----------------------------------------------------------------------
//  Differential driver
// ----------------------------------------------------------------------

const Form = enum {
    globals,
    constant_rhs,
    locals,
    /// Operands are unsigned bytes read from memory (i32 only): the
    /// lowering applies byte operators to them.
    bytes,
    /// The same, with a constant right operand.
    byte_constant_rhs,
};

/// Operand values for the byte forms.
const byte_values = [_]u64{ 0, 1, 2, 7, 31, 32, 33, 127, 128, 200, 255 };

const Case = struct {
    name: []const u8,
    op: I,
    in: []const ValType,
    out: ValType,
    reference: *const fn (args: []const u64) Expect,
};

/// The module for one case and operand form. With `.constant_rhs` the last
/// operand is the constant `rhs`; otherwise every operand comes from a
/// global, so one module serves the whole grid.
fn caseModule(a: std.mem.Allocator, c: Case, form: Form, rhs: u64) !wasm.Module {
    // Globals: one per operand, then the result.
    var global_types: std.ArrayList(ValType) = .empty;
    try global_types.appendSlice(a, c.in);
    try global_types.append(a, c.out);

    var body: std.ArrayList(I) = .empty;
    var locals: std.ArrayList(wasm.module.LocalGroup) = .empty;
    switch (form) {
        .globals => for (c.in, 0..) |_, i| try body.append(a, .{ .global_get = @intCast(i) }),
        .constant_rhs => for (c.in, 0..) |ty, i| {
            const last = i + 1 == c.in.len;
            try body.append(a, if (last) constOf(ty, rhs) else .{ .global_get = @intCast(i) });
        },
        .locals => {
            for (c.in, 0..) |ty, i| {
                try locals.append(a, .{ .count = 1, .ty = ty });
                try body.append(a, .{ .global_get = @intCast(i) });
                try body.append(a, .{ .local_set = @intCast(i) });
            }
            for (c.in, 0..) |_, i| try body.append(a, .{ .local_get = @intCast(i) });
        },
        .bytes, .byte_constant_rhs => {
            const m0 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 0 };
            // Put each operand in memory first: 0x55 guard bytes around
            // them would show a load of the wrong width.
            try body.appendSlice(a, &.{ .{ .i32_const = 16 }, .{ .i32_const = 0x55555555 }, .{ .i32_store = m0 } });
            for (c.in, 0..) |_, i| try body.appendSlice(a, &.{ .{ .i32_const = @intCast(17 + i) }, .{ .global_get = @intCast(i) }, .{ .i32_store8 = m0 } });
            for (c.in, 0..) |ty, i| {
                const constant = form == .byte_constant_rhs and i + 1 == c.in.len;
                if (constant) {
                    try body.append(a, constOf(ty, rhs));
                } else try body.appendSlice(a, &.{ .{ .i32_const = @intCast(17 + i) }, .{ .i32_load8_u = m0 } });
            }
        },
    }
    try body.append(a, c.op);
    // Write the result back over the first operand's local when the types
    // allow, exercising in-place updates.
    if (form == .locals and c.in[0] == c.out) try body.append(a, .{ .local_tee = 0 });
    try body.append(a, .{ .global_set = @intCast(c.in.len) });
    return simpleModule(a, global_types.items, locals.items, body.items);
}

fn describe(c: Case, form: Form, args: []const u64) void {
    std.debug.print("  {s} [{t}] args:", .{ c.name, form });
    for (args) |x| std.debug.print(" 0x{x}", .{x});
    std.debug.print("\n", .{});
}

/// Evaluate the case on `args` in an already loaded program and compare
/// with the reference. Returns false if the program faulted (and so must be
/// reloaded before its next use).
fn evalCase(p: *Program, c: Case, form: Form, args: []const u64) !bool {
    const names = [_][]const u8{ "__G__g0", "__G__g1", "__G__g2" };
    for (c.in, 0..) |ty, i| try testing.expect(p.vm.setVar(names[i], valueOf(ty, args[i])));
    const want = c.reference(args);
    const outcome = p.vm.runEvent("run");
    const result_name = names[c.in.len];
    switch (want) {
        .unspecified => {},
        .trap => if (outcome) |_| {
            describe(c, form, args);
            std.debug.print("  expected a trap, got 0x{x}\n", .{bitsOf(p.global(result_name))});
            return error.TestUnexpectedResult;
        } else |_| {},
        .value => |expected| {
            _ = outcome catch |e| {
                describe(c, form, args);
                std.debug.print("  expected 0x{x}, faulted: {t}: {s}\n", .{ expected, e, if (p.vm.fault) |f| f.message else "" });
                return error.TestUnexpectedResult;
            };
            const got = bitsOf(p.global(result_name));
            const both_nan = isNanBits(c.out, expected) and isNanBits(c.out, got);
            if (got != expected and !both_nan) {
                describe(c, form, args);
                std.debug.print("  expected 0x{x}, got 0x{x}\n", .{ expected, got });
                return error.TestUnexpectedResult;
            }
        },
    }
    return !p.vm.halted;
}

/// Run the case over `lhs × rhs` in one program, reloading only after a
/// fault (a halted behaviour runs nothing further).
fn runForm(c: Case, form: Form, lhs: []const u64, rhs: []const u64) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The constant operand is the last one: the right operand of a binary
    // instruction, the only operand of a unary one.
    const mod = try caseModule(arena.allocator(), c, form, if (c.in.len == 2) rhs[0] else lhs[0]);
    var p = try load(mod, null);
    defer p.deinit();
    for (lhs) |x| for (rhs) |y| {
        const args = [2]u64{ x, y };
        if (!try evalCase(&p, c, form, args[0..c.in.len])) {
            p.deinit();
            p = try load(mod, null);
        }
    };
}

fn runGrid(c: Case) !void {
    const g0 = grid(c.in[0]);
    const g1: []const u64 = if (c.in.len == 2) grid(c.in[1]) else &.{0};
    try runForm(c, .globals, g0, g1);
    try runForm(c, .locals, g0, g1);
    // A constant right operand is part of the module: one module per value.
    if (c.in.len == 2) {
        for (g1) |y| try runForm(c, .constant_rhs, g0, &.{y});
    } else for (g0) |x| try runForm(c, .constant_rhs, &.{x}, &.{0});

    if (c.in[0] != .i32) return;
    try runForm(c, .bytes, &byte_values, if (c.in.len == 2) &byte_values else &.{0});
    // A constant that fits a byte takes the byte operator; a larger one
    // must not.
    if (c.in.len == 2) for ([_]u64{ 0, 1, 24, 31, 200, 255, 256, 0xFFFF_FFFF }) |y| try runForm(c, .byte_constant_rhs, &byte_values, &.{y});
}

// Reference adapters, generated per instruction name.

fn asInt(comptime T: type, bits: u64) T {
    return @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @truncate(bits)));
}

fn asFloat(comptime T: type, bits: u64) T {
    return @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @truncate(bits)));
}

fn IntRef(comptime T: type, comptime op: []const u8, comptime arity: usize) type {
    return struct {
        fn f(args: []const u64) Expect {
            return if (arity == 2) intBinary(T, op, asInt(T, args[0]), asInt(T, args[1])) else intUnary(T, op, asInt(T, args[0]));
        }
    };
}

fn FloatRef(comptime T: type, comptime op: []const u8, comptime arity: usize) type {
    return struct {
        fn f(args: []const u64) Expect {
            return if (arity == 2) floatBinary(T, op, asFloat(T, args[0]), asFloat(T, args[1])) else floatUnary(T, op, asFloat(T, args[0]));
        }
    };
}

fn instr(comptime tag: []const u8) I {
    return @unionInit(I, tag, {});
}

test "integer instructions match WebAssembly semantics" {
    const binary = [_][]const u8{ "add", "sub", "mul", "div_s", "div_u", "rem_s", "rem_u", "and", "or", "xor", "shl", "shr_s", "shr_u", "rotl", "rotr" };
    const compare = [_][]const u8{ "eq", "ne", "lt_s", "lt_u", "gt_s", "gt_u", "le_s", "le_u", "ge_s", "ge_u" };
    const unary = [_][]const u8{ "clz", "ctz", "popcnt" };
    inline for (.{ .{ i32, ValType.i32, "i32_" }, .{ i64, ValType.i64, "i64_" } }) |t| {
        const T = t[0];
        const ty = t[1];
        inline for (binary) |op| try runGrid(.{ .name = t[2] ++ op, .op = instr(t[2] ++ op), .in = &.{ ty, ty }, .out = ty, .reference = IntRef(T, op, 2).f });
        inline for (compare) |op| try runGrid(.{ .name = t[2] ++ op, .op = instr(t[2] ++ op), .in = &.{ ty, ty }, .out = .i32, .reference = IntRef(T, op, 2).f });
        inline for (unary) |op| try runGrid(.{ .name = t[2] ++ op, .op = instr(t[2] ++ op), .in = &.{ty}, .out = ty, .reference = IntRef(T, op, 1).f });
        try runGrid(.{ .name = t[2] ++ "eqz", .op = instr(t[2] ++ "eqz"), .in = &.{ty}, .out = .i32, .reference = IntRef(T, "eqz", 1).f });
    }
}

test "float instructions match WebAssembly semantics" {
    const binary = [_][]const u8{ "add", "sub", "mul", "div", "min", "max", "copysign" };
    const compare = [_][]const u8{ "eq", "ne", "lt", "gt", "le", "ge" };
    const unary = [_][]const u8{ "abs", "neg", "ceil", "floor", "trunc", "nearest", "sqrt" };
    inline for (.{ .{ f32, ValType.f32, "f32_" }, .{ f64, ValType.f64, "f64_" } }) |t| {
        const T = t[0];
        const ty = t[1];
        inline for (binary) |op| try runGrid(.{ .name = t[2] ++ op, .op = instr(t[2] ++ op), .in = &.{ ty, ty }, .out = ty, .reference = FloatRef(T, op, 2).f });
        inline for (compare) |op| try runGrid(.{ .name = t[2] ++ op, .op = instr(t[2] ++ op), .in = &.{ ty, ty }, .out = .i32, .reference = FloatRef(T, op, 2).f });
        inline for (unary) |op| try runGrid(.{ .name = t[2] ++ op, .op = instr(t[2] ++ op), .in = &.{ty}, .out = ty, .reference = FloatRef(T, op, 1).f });
    }
}

const conversions = struct {
    fn wrap(a: []const u64) Expect {
        return val(@as(u32, @truncate(a[0])));
    }
    fn extendS(a: []const u64) Expect {
        return val(@as(i64, asInt(i32, a[0])));
    }
    fn extendU(a: []const u64) Expect {
        return val(@as(u64, @as(u32, @truncate(a[0]))));
    }
    fn Trunc(comptime To: type, comptime From: type, comptime signed: bool, comptime saturating: bool) type {
        return struct {
            fn f(a: []const u64) Expect {
                return truncate(To, signed, asFloat(From, a[0]), saturating);
            }
        };
    }
    fn Convert(comptime To: type, comptime From: type, comptime signed: bool) type {
        return struct {
            fn f(a: []const u64) Expect {
                const x = asInt(From, a[0]);
                if (signed) return val(@as(To, @floatFromInt(x)));
                const U = std.meta.Int(.unsigned, @bitSizeOf(From));
                return val(@as(To, @floatFromInt(@as(U, @bitCast(x)))));
            }
        };
    }
    fn demote(a: []const u64) Expect {
        return val(@as(f32, @floatCast(asFloat(f64, a[0]))));
    }
    fn promote(a: []const u64) Expect {
        return val(@as(f64, asFloat(f32, a[0])));
    }
    fn same(a: []const u64) Expect {
        return .{ .value = a[0] };
    }
    fn SignExtend(comptime T: type, comptime Narrow: type) type {
        return struct {
            fn f(a: []const u64) Expect {
                return val(@as(T, @as(Narrow, @truncate(asInt(T, a[0])))));
            }
        };
    }
};

test "conversion instructions match WebAssembly semantics" {
    const C = conversions;
    const cases = [_]Case{
        .{ .name = "i32.wrap_i64", .op = .i32_wrap_i64, .in = &.{.i64}, .out = .i32, .reference = C.wrap },
        .{ .name = "i64.extend_i32_s", .op = .i64_extend_i32_s, .in = &.{.i32}, .out = .i64, .reference = C.extendS },
        .{ .name = "i64.extend_i32_u", .op = .i64_extend_i32_u, .in = &.{.i32}, .out = .i64, .reference = C.extendU },
        .{ .name = "i32.trunc_f32_s", .op = .i32_trunc_f32_s, .in = &.{.f32}, .out = .i32, .reference = C.Trunc(i32, f32, true, false).f },
        .{ .name = "i32.trunc_f32_u", .op = .i32_trunc_f32_u, .in = &.{.f32}, .out = .i32, .reference = C.Trunc(i32, f32, false, false).f },
        .{ .name = "i32.trunc_f64_s", .op = .i32_trunc_f64_s, .in = &.{.f64}, .out = .i32, .reference = C.Trunc(i32, f64, true, false).f },
        .{ .name = "i32.trunc_f64_u", .op = .i32_trunc_f64_u, .in = &.{.f64}, .out = .i32, .reference = C.Trunc(i32, f64, false, false).f },
        .{ .name = "i64.trunc_f32_s", .op = .i64_trunc_f32_s, .in = &.{.f32}, .out = .i64, .reference = C.Trunc(i64, f32, true, false).f },
        .{ .name = "i64.trunc_f32_u", .op = .i64_trunc_f32_u, .in = &.{.f32}, .out = .i64, .reference = C.Trunc(i64, f32, false, false).f },
        .{ .name = "i64.trunc_f64_s", .op = .i64_trunc_f64_s, .in = &.{.f64}, .out = .i64, .reference = C.Trunc(i64, f64, true, false).f },
        .{ .name = "i64.trunc_f64_u", .op = .i64_trunc_f64_u, .in = &.{.f64}, .out = .i64, .reference = C.Trunc(i64, f64, false, false).f },
        .{ .name = "i32.trunc_sat_f32_s", .op = .i32_trunc_sat_f32_s, .in = &.{.f32}, .out = .i32, .reference = C.Trunc(i32, f32, true, true).f },
        .{ .name = "i32.trunc_sat_f32_u", .op = .i32_trunc_sat_f32_u, .in = &.{.f32}, .out = .i32, .reference = C.Trunc(i32, f32, false, true).f },
        .{ .name = "i32.trunc_sat_f64_s", .op = .i32_trunc_sat_f64_s, .in = &.{.f64}, .out = .i32, .reference = C.Trunc(i32, f64, true, true).f },
        .{ .name = "i32.trunc_sat_f64_u", .op = .i32_trunc_sat_f64_u, .in = &.{.f64}, .out = .i32, .reference = C.Trunc(i32, f64, false, true).f },
        .{ .name = "i64.trunc_sat_f32_s", .op = .i64_trunc_sat_f32_s, .in = &.{.f32}, .out = .i64, .reference = C.Trunc(i64, f32, true, true).f },
        .{ .name = "i64.trunc_sat_f32_u", .op = .i64_trunc_sat_f32_u, .in = &.{.f32}, .out = .i64, .reference = C.Trunc(i64, f32, false, true).f },
        .{ .name = "i64.trunc_sat_f64_s", .op = .i64_trunc_sat_f64_s, .in = &.{.f64}, .out = .i64, .reference = C.Trunc(i64, f64, true, true).f },
        .{ .name = "i64.trunc_sat_f64_u", .op = .i64_trunc_sat_f64_u, .in = &.{.f64}, .out = .i64, .reference = C.Trunc(i64, f64, false, true).f },
        .{ .name = "f32.convert_i32_s", .op = .f32_convert_i32_s, .in = &.{.i32}, .out = .f32, .reference = C.Convert(f32, i32, true).f },
        .{ .name = "f32.convert_i32_u", .op = .f32_convert_i32_u, .in = &.{.i32}, .out = .f32, .reference = C.Convert(f32, i32, false).f },
        .{ .name = "f32.convert_i64_s", .op = .f32_convert_i64_s, .in = &.{.i64}, .out = .f32, .reference = C.Convert(f32, i64, true).f },
        .{ .name = "f32.convert_i64_u", .op = .f32_convert_i64_u, .in = &.{.i64}, .out = .f32, .reference = C.Convert(f32, i64, false).f },
        .{ .name = "f64.convert_i32_s", .op = .f64_convert_i32_s, .in = &.{.i32}, .out = .f64, .reference = C.Convert(f64, i32, true).f },
        .{ .name = "f64.convert_i32_u", .op = .f64_convert_i32_u, .in = &.{.i32}, .out = .f64, .reference = C.Convert(f64, i32, false).f },
        .{ .name = "f64.convert_i64_s", .op = .f64_convert_i64_s, .in = &.{.i64}, .out = .f64, .reference = C.Convert(f64, i64, true).f },
        .{ .name = "f64.convert_i64_u", .op = .f64_convert_i64_u, .in = &.{.i64}, .out = .f64, .reference = C.Convert(f64, i64, false).f },
        .{ .name = "f32.demote_f64", .op = .f32_demote_f64, .in = &.{.f64}, .out = .f32, .reference = C.demote },
        .{ .name = "f64.promote_f32", .op = .f64_promote_f32, .in = &.{.f32}, .out = .f64, .reference = C.promote },
        .{ .name = "i32.reinterpret_f32", .op = .i32_reinterpret_f32, .in = &.{.f32}, .out = .i32, .reference = C.same },
        .{ .name = "i64.reinterpret_f64", .op = .i64_reinterpret_f64, .in = &.{.f64}, .out = .i64, .reference = C.same },
        .{ .name = "f32.reinterpret_i32", .op = .f32_reinterpret_i32, .in = &.{.i32}, .out = .f32, .reference = C.same },
        .{ .name = "f64.reinterpret_i64", .op = .f64_reinterpret_i64, .in = &.{.i64}, .out = .f64, .reference = C.same },
        .{ .name = "i32.extend8_s", .op = .i32_extend8_s, .in = &.{.i32}, .out = .i32, .reference = C.SignExtend(i32, i8).f },
        .{ .name = "i32.extend16_s", .op = .i32_extend16_s, .in = &.{.i32}, .out = .i32, .reference = C.SignExtend(i32, i16).f },
        .{ .name = "i64.extend8_s", .op = .i64_extend8_s, .in = &.{.i64}, .out = .i64, .reference = C.SignExtend(i64, i8).f },
        .{ .name = "i64.extend16_s", .op = .i64_extend16_s, .in = &.{.i64}, .out = .i64, .reference = C.SignExtend(i64, i16).f },
        .{ .name = "i64.extend32_s", .op = .i64_extend32_s, .in = &.{.i64}, .out = .i64, .reference = C.SignExtend(i64, i32).f },
    };
    for (cases) |c| try runGrid(c);
}

// ----------------------------------------------------------------------
//  Memory
// ----------------------------------------------------------------------

/// Run `body` in a module with one page of memory and i32 globals g0…g3;
/// g0 is the conventional result.
fn runBody(a: std.mem.Allocator, body: []const I, locals: []const wasm.module.LocalGroup) !Program {
    const mod = try simpleModule(a, &.{ .i64, .i64, .i32, .i32 }, locals, body);
    var p = try load(mod, null);
    errdefer p.deinit();
    _ = try p.vm.runEvent("run");
    return p;
}

test "loads and stores of every width round-trip at unaligned addresses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = wasm.instruction.MemArg{ .@"align" = 0, .offset = 3 };
    const value: i64 = @bitCast(@as(u64, 0x8877_6655_F4E3_D2C1));

    const Width = struct { store: I, load_u: I, load_s: I, bits: u7 };
    const widths = [_]Width{
        .{ .store = .{ .i64_store8 = m }, .load_u = .{ .i64_load8_u = m }, .load_s = .{ .i64_load8_s = m }, .bits = 8 },
        .{ .store = .{ .i64_store16 = m }, .load_u = .{ .i64_load16_u = m }, .load_s = .{ .i64_load16_s = m }, .bits = 16 },
        .{ .store = .{ .i64_store32 = m }, .load_u = .{ .i64_load32_u = m }, .load_s = .{ .i64_load32_s = m }, .bits = 32 },
        .{ .store = .{ .i64_store = m }, .load_u = .{ .i64_load = m }, .load_s = .{ .i64_load = m }, .bits = 64 },
    };
    for (widths) |w| {
        // Dynamic value and address (from globals), unaligned (10 + 3).
        const body = [_]I{
            .{ .i64_const = value }, .{ .global_set = 0 },
            .{ .i32_const = 10 },    .{ .global_set = 2 },
            .{ .global_get = 2 },    .{ .global_get = 0 },
            w.store,                 .{ .global_get = 2 },
            w.load_u,                .{ .global_set = 0 },
            .{ .global_get = 2 },    w.load_s,
            .{ .global_set = 1 },
        };
        var p = try runBody(a, &body, &.{});
        defer p.deinit();
        const mask: u64 = if (w.bits == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(w.bits)) - 1;
        const raw: u64 = @as(u64, @bitCast(value)) & mask;
        try testing.expectEqual(raw, bitsOf(p.global("__G__g0")));
        const shift: u6 = @intCast(64 - @as(u8, w.bits));
        const sign_extended: i64 = @as(i64, @bitCast(raw << shift)) >> shift;
        try testing.expectEqual(@as(u64, @bitCast(sign_extended)), bitsOf(p.global("__G__g1")));
    }
}

test "i32 narrow loads, constant stores and float stores" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 0 };
    const m1 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 1 };
    const body = [_]I{
        // Constant address and value: both sides folded.
        .{ .i32_const = 101 },                               .{ .i32_const = @bitCast(@as(u32, 0xA1B2C3D4)) }, .{ .i32_store = m0 },
        // i32.load16_s / load8_u / load8_s read parts of it back.
        .{ .i32_const = 100 },                               .{ .i32_load16_s = m1 },                          .{ .global_set = 2 },
        .{ .i32_const = 103 },                               .{ .i32_load8_u = m1 },                           .{ .i32_const = 100 },
        .{ .i32_load8_s = .{ .@"align" = 0, .offset = 4 } }, .i32_add,                                         .{ .global_set = 3 },
        // f64 round trip through memory.
        .{ .i32_const = 200 },                               .{ .f64_const = -1234.5 },                        .{ .f64_store = m1 },
        .{ .i32_const = 201 },                               .{ .i64_load = m0 },                              .{ .global_set = 0 },
        // f32 store, read back as its bits.
        .{ .i32_const = 300 },                               .{ .f32_const = 0.1 },                            .{ .f32_store = m0 },
        .{ .i32_const = 300 },                               .{ .i32_load = m0 },                              .i64_extend_i32_u,
        .{ .global_set = 1 },
    };
    var p = try runBody(a, &body, &.{});
    defer p.deinit();
    try testing.expectEqual(Value{ .int32 = @as(i16, @bitCast(@as(u16, 0xC3D4))) }, p.global("__G__g2"));
    // 0xA1 unsigned + 0xA1 signed
    try testing.expectEqual(Value{ .int32 = 0xA1 + @as(i32, @as(i8, @bitCast(@as(u8, 0xA1)))) }, p.global("__G__g3"));
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, -1234.5))), bitsOf(p.global("__G__g0")));
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 0.1)))), bitsOf(p.global("__G__g1")));
}

test "a load reads memory as it was, whatever is stored before its value is used" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 0 };
    const m4 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 4 };
    const body = [_]I{
        .{ .i32_const = 100 }, .{ .i32_const = 111 }, .{ .i32_store = m0 },
        .{ .i32_const = 104 }, .{ .i32_const = 333 }, .{ .i32_store = m0 },
        // Constant address: load [100], overwrite [100], then use the load.
        .{ .i32_const = 100 }, .{ .i32_load = m0 },   .{ .i32_const = 100 },
        .{ .i32_const = 222 }, .{ .i32_store = m0 },
        .{ .global_set = 2 }, // 111
        // Address in a local that moves on before the value is used.
        .{ .i32_const = 100 },
        .{ .local_set = 0 },
        .{ .local_get = 0 }, .{ .i32_load = m0 }, // 222
        .{ .local_get = 0 }, .{ .i32_const = 4 },
        .i32_add,            .{ .local_set = 0 },
        .{ .local_get = 0 }, .{ .i32_load = m0 }, // 333
        .i32_add,
        .{ .global_set = 3 }, // 555
        // A load, then a store through the same local to the same field,
        // then both values used: 333 and 7.
        .{ .local_get = 0 },
        .{ .i32_load = m0 },
        .{ .local_get = 0 },
        .{ .i32_const = 7 },
        .{ .i32_store = m0 },
        .{ .local_get = 0 },
        .{ .i32_load = m0 },
        .{ .i32_const = 1000 },
        .i32_mul,
        .i32_add,
        .i64_extend_i32_s,
        .{ .global_set = 0 }, // 333 + 7000
        // A load left pending across a call that writes the address.
        .{ .i32_const = 96 }, .{ .i32_load = m4 }, // [100] = 222
        .{ .call = 1 }, // stores 9 to [100]
        .{ .i32_const = 100 },   .{ .i32_load = m0 }, // 9
        .{ .i32_const = 10000 }, .i32_mul,
        .i32_add,                .i64_extend_i32_s,
        .{ .global_set = 1 }, // 222 + 90000
    };
    const callee = [_]I{ .{ .i32_const = 100 }, .{ .i32_const = 9 }, .{ .i32_store = m0 } };
    var mod = try simpleModule(a, &.{ .i64, .i64, .i32, .i32 }, &.{.{ .count = 1, .ty = .i32 }}, &body);
    mod.funcs = try a.dupe(u32, &.{ 0, 0 });
    mod.codes = try a.dupe(wasm.module.Code, &.{ mod.codes[0], .{ .locals = &.{}, .body = &callee } });
    var p = try load(mod, null);
    defer p.deinit();
    _ = try p.vm.runEvent("run");
    try testing.expectEqual(Value{ .int32 = 111 }, p.global("__G__g2"));
    try testing.expectEqual(Value{ .int32 = 555 }, p.global("__G__g3"));
    try testing.expectEqual(Value{ .int64 = 7333 }, p.global("__G__g0"));
    try testing.expectEqual(Value{ .int64 = 90222 }, p.global("__G__g1"));
}

test "a loaded value stored straight back is a copy within memory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 0 };
    const m1 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 1 };
    const Pair = struct { load: I, store: I, size: usize };
    const pairs = [_]Pair{
        .{ .load = .{ .i32_load = m1 }, .store = .{ .i32_store = m0 }, .size = 4 },
        .{ .load = .{ .i64_load = m1 }, .store = .{ .i64_store = m0 }, .size = 8 },
        .{ .load = .{ .f32_load = m1 }, .store = .{ .f32_store = m0 }, .size = 4 },
        .{ .load = .{ .f64_load = m1 }, .store = .{ .f64_store = m0 }, .size = 8 },
        .{ .load = .{ .i32_load8_u = m1 }, .store = .{ .i32_store8 = m0 }, .size = 1 },
        .{ .load = .{ .i32_load8_s = m1 }, .store = .{ .i32_store8 = m0 }, .size = 1 },
        .{ .load = .{ .i32_load16_u = m1 }, .store = .{ .i32_store16 = m0 }, .size = 2 },
        .{ .load = .{ .i32_load16_s = m1 }, .store = .{ .i32_store16 = m0 }, .size = 2 },
        .{ .load = .{ .i64_load32_u = m1 }, .store = .{ .i64_store32 = m0 }, .size = 4 },
        .{ .load = .{ .i64_load16_s = m1 }, .store = .{ .i64_store8 = m0 }, .size = 1 },
        // Wider load than store: the low bytes.
        .{ .load = .{ .i32_load = m1 }, .store = .{ .i32_store16 = m0 }, .size = 2 },
        .{ .load = .{ .i64_load = m1 }, .store = .{ .i64_store32 = m0 }, .size = 4 },
        // Narrower load than store: zero- or sign-extended, not a copy.
        .{ .load = .{ .i32_load8_u = m1 }, .store = .{ .i32_store = m0 }, .size = 0 },
    };
    for (pairs) |pair| {
        const body = [_]I{
            // Source bytes at 41..48 (address 40 + offset 1), all distinct
            // and with high bits set.
            .{ .i32_const = 41 }, .{ .i64_const = @bitCast(@as(u64, 0xF8E7_D6C5_B4A3_9281)) }, .{ .i64_store = m0 },
            // Destination 80..87 prefilled so untouched bytes show.
            .{ .i32_const = 80 }, .{ .i64_const = 0x1111_1111_1111_1111 },                     .{ .i64_store = m0 },
            // Destination address from a local, source from a global.
            .{ .i32_const = 80 }, .{ .local_set = 0 },                                         .{ .i32_const = 40 },
            .{ .global_set = 2 }, .{ .local_get = 0 },                                         .{ .global_get = 2 },
            pair.load,            pair.store,
                // And an overlapping copy within the source, constant addresses:
                // [43..] <- [41..].
                                                             .{ .i32_const = 43 },
            .{ .i32_const = 40 }, pair.load,                                                   pair.store,
            .{ .i32_const = 80 }, .{ .i64_load = m0 },                                         .{ .global_set = 0 },
            .{ .i32_const = 41 }, .{ .i64_load = m0 },                                         .{ .global_set = 1 },
        };
        var p = try runBody(a, &body, &.{.{ .count = 1, .ty = .i32 }});
        defer p.deinit();
        const src = [8]u8{ 0x81, 0x92, 0xA3, 0xB4, 0xC5, 0xD6, 0xE7, 0xF8 };
        var dst: [8]u8 = @splat(0x11);
        var after = src;
        if (pair.size == 0) {
            // i32.load8_u then i32.store: the byte, zero-extended.
            std.mem.writeInt(u32, dst[0..4], src[0], .little);
            std.mem.writeInt(u32, after[2..6], src[0], .little);
        } else {
            @memcpy(dst[0..pair.size], src[0..pair.size]);
            // The window read back is eight bytes; a long copy runs past it.
            const n = @min(pair.size, after.len - 2);
            @memcpy(after[2..][0..n], src[0..n]);
        }
        try testing.expectEqual(std.mem.readInt(u64, &dst, .little), bitsOf(p.global("__G__g0")));
        try testing.expectEqual(std.mem.readInt(u64, &after, .little), bitsOf(p.global("__G__g1")));
    }
}

test "a byte in memory is tested without being loaded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 0 };
    const i32_block: wasm.types.BlockType = .{ .value = .i32 };
    for ([_]i32{ 0, 1, 0x80, 0xFF }) |byte| {
        const flag = [_]I{ .{ .i32_const = 50 }, .{ .i32_load8_u = m0 } };
        const body = [_]I{
            // Bytes around it are non-zero: a wider read would see them.
            .{ .i32_const = 48 }, .{ .i32_const = -1 },   .{ .i32_store = m0 },
            .{ .i32_const = 50 }, .{ .i32_const = byte }, .{ .i32_store8 = m0 },
        } ++ flag ++ [_]I{
            // if (byte) 10 else 20
            .{ .if_ = .{ .bt = i32_block, .then_body = &.{.{ .i32_const = 10 }}, .else_body = &.{.{ .i32_const = 20 }} } },
        } ++ flag ++ [_]I{
            // + (byte == 0 ? 1 : 2) via eqz and select
            .i32_eqz,
            .{ .if_ = .{ .bt = i32_block, .then_body = &.{.{ .i32_const = 1 }}, .else_body = &.{.{ .i32_const = 2 }} } },
            .i32_add,
            .{ .i32_const = 100 },
            .{ .i32_const = 200 },
        } ++ flag ++ [_]I{
            .select,                                                                                                                   .i32_add,
            // br_if on the byte and on its negation
            .{ .block = .{ .bt = .empty, .body = &(flag ++ [_]I{ .{ .br_if = 0 }, .{ .i32_const = 1000 }, .{ .global_set = 3 } }) } }, .{ .block = .{ .bt = .empty, .body = &(flag ++ [_]I{ .i32_eqz, .{ .br_if = 0 }, .{ .global_get = 3 }, .{ .i32_const = 5000 }, .i32_add, .{ .global_set = 3 } }) } },
            .{ .global_set = 2 },
        } ++ flag ++ [_]I{
            // The byte's value itself still loads correctly afterwards.
            .i64_extend_i32_u, .{ .global_set = 0 },
        };
        var p = try runBody(a, &body, &.{});
        defer p.deinit();
        const set = byte != 0;
        const expected: i32 = (if (set) @as(i32, 10) else 20) + (if (set) @as(i32, 2) else 1) + (if (set) @as(i32, 100) else 200);
        try testing.expectEqual(Value{ .int32 = expected }, p.global("__G__g2"));
        try testing.expectEqual(Value{ .int32 = if (set) 5000 else 1000 }, p.global("__G__g3"));
        try testing.expectEqual(Value{ .int64 = byte }, p.global("__G__g0"));
    }
}

test "memory.copy overlaps correctly; memory.fill; memory.size and grow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 0 };
    const body = [_]I{
        // bytes 0..8 = 01 02 … 08
        .{ .i32_const = 0 },   .{ .i64_const = 0x0807060504030201 }, .{ .i64_store = m0 },
        // overlapping forward copy: [2..10) ← [0..8)
        .{ .i32_const = 2 },   .{ .i32_const = 0 },                  .{ .i32_const = 8 },
        .memory_copy,          .{ .i32_const = 2 },                  .{ .i64_load = m0 },
        .{ .global_set = 0 },
        // fill 13 bytes with 0xAB starting at 100, then read 8 from 105
         .{ .i32_const = 100 },                .{ .i32_const = 0x1AB },
        .{ .i32_const = 13 },  .memory_fill,                         .{ .i32_const = 105 },
        .{ .i64_load = m0 },   .{ .global_set = 1 },
        // zero fill over part of it
                        .{ .i32_const = 108 },
        .{ .i32_const = 0 },   .{ .i32_const = 2 },                  .memory_fill,
        .{ .i32_const = 106 }, .{ .i32_load = m0 },                  .{ .global_set = 2 },
        // grow by 2 (max is 4 pages): returns 1; size is then 3; growing
        // past the maximum returns -1.
        .{ .i32_const = 2 },   .memory_grow,                         .memory_size,
        .i32_add,              .{ .i32_const = 5 },                  .memory_grow,
        .{ .i32_const = 100 }, .i32_mul,                             .i32_add,
        .{ .global_set = 3 },
        // The grown memory is usable and old contents survived.
         .{ .i32_const = 3 * 65536 - 4 },      .{ .i32_const = 77 },
        .{ .i32_store = m0 },
    };
    var p = try runBody(a, &body, &.{});
    defer p.deinit();
    try testing.expectEqual(@as(u64, 0x0807060504030201), bitsOf(p.global("__G__g0")));
    try testing.expectEqual(@as(u64, 0xABABABABABABABAB), bitsOf(p.global("__G__g1")));
    // Bytes 106..110 are AB AB 00 00 after the zero fill.
    try testing.expectEqual(Value{ .int32 = 0xABAB }, p.global("__G__g2"));
    try testing.expectEqual(Value{ .int32 = 1 + 3 - 100 }, p.global("__G__g3"));
    try testing.expectEqual(@as(u32, 3 * 65536), p.global("__G__memory").array.len);
    try testing.expectEqual(@as(u8, 3), p.global("__G__memory").array.bytes[4]);
}

test "out-of-bounds access faults like a trap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]I{ .{ .i32_const = 65533 }, .{ .i32_load = .{ .@"align" = 0, .offset = 0 } }, .{ .global_set = 2 } };
    const mod = try simpleModule(a, &.{ .i64, .i64, .i32, .i32 }, &.{}, &body);
    var p = try load(mod, null);
    defer p.deinit();
    try testing.expectError(error.UdonFault, p.vm.runEvent("run"));
}

// ----------------------------------------------------------------------
//  Control flow
// ----------------------------------------------------------------------

fn block(result: ?ValType, body: []const I) I {
    return .{ .block = .{ .bt = if (result) |r| .{ .value = r } else .empty, .body = body } };
}

fn loop(body: []const I) I {
    return .{ .loop = .{ .bt = .empty, .body = body } };
}

fn ifElse(result: ?ValType, then_body: []const I, else_body: ?[]const I) I {
    return .{ .if_ = .{ .bt = if (result) |r| .{ .value = r } else .empty, .then_body = then_body, .else_body = else_body } };
}

test "blocks carry values through br, br_if and fall-through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // g2 selects the path; result in g3.
    const body = [_]I{
        block(.i32, &.{
            .{ .i32_const = 10 },
            .{ .global_get = 2 },
            .{ .i32_const = 1 },
            .i32_eq,
            .{ .br_if = 0 }, // g2 == 1 → 10
            .drop,
            block(.i32, &.{
                .{ .i32_const = 20 },
                .{ .global_get = 2 },
                .{ .i32_const = 2 },
                .i32_eq,
                .{ .br_if = 1 }, // g2 == 2 → 20 (outer block)
                .drop,
                .{ .global_get = 2 },
                .{ .i32_const = 3 },
                .i32_eq,
                ifElse(.i32, &.{ .{ .i32_const = 30 }, .{ .br = 2 } }, &.{.{ .i32_const = 40 }}),
            }),
            .{ .i32_const = 1 },
            .i32_add, // fall-through: 41
        }),
        .{ .global_set = 3 },
    };
    const mod = try simpleModule(a, &.{ .i64, .i64, .i32, .i32 }, &.{}, &body);
    var p = try load(mod, null);
    defer p.deinit();
    for ([_][2]i32{ .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 }, .{ 9, 41 } }) |case| {
        _ = p.vm.setVar("__G__g2", .{ .int32 = case[0] });
        _ = try p.vm.runEvent("run");
        try testing.expectEqual(Value{ .int32 = case[1] }, p.global("__G__g3"));
    }
}

test "loops, br_table and select" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const labels = [_]u32{ 0, 1, 2 };
    // for i in 0..6: acc = acc * 10 + case(i % 5), where case is a br_table
    // with three cases and a default; then select picks by sign.
    const body = [_]I{
        loop(&.{
            block(null, &.{ // default → 7
                block(null, &.{ // 2 → 3
                    block(null, &.{ // 1 → 2
                        block(null, &.{ // 0 → 1
                            .{ .local_get = 0 },
                            .{ .i32_const = 5 },
                            .i32_rem_u,
                            .{ .br_table = .{ .labels = &labels, .default = 3 } },
                        }),
                        .{ .i32_const = 1 },
                        .{ .local_set = 2 },
                        .{ .br = 2 },
                    }),
                    .{ .i32_const = 2 },
                    .{ .local_set = 2 },
                    .{ .br = 1 },
                }),
                .{ .i32_const = 3 },
                .{ .local_set = 2 },
                .{ .br = 0 },
            }),
            // After the outer block: cases 0..2 arrive with local 2 set;
            // the default arrives with it unchanged from the last
            // iteration, so set it when it still holds the previous value.
            .{ .local_get = 0 },
            .{ .i32_const = 5 },
            .i32_rem_u,
            .{ .i32_const = 3 },
            .i32_ge_u,
            ifElse(null, &.{ .{ .i32_const = 7 }, .{ .local_set = 2 } }, null),
            .{ .local_get = 1 },
            .{ .i32_const = 10 },
            .i32_mul,
            .{ .local_get = 2 },
            .i32_add,
            .{ .local_set = 1 },
            .{ .local_get = 0 },
            .{ .i32_const = 1 },
            .i32_add,
            .{ .local_tee = 0 },
            .{ .i32_const = 6 },
            .i32_lt_s,
            .{ .br_if = 0 },
        }),
        .{ .local_get = 1 },
        .{ .global_set = 2 },
        // select(a, b, cond) with every operand form
        .{ .i32_const = 111 },
        .{ .i32_const = 222 },
        .{ .local_get = 1 },
        .{ .i32_const = 0 },
        .i32_lt_s,
        .select,
        .{ .local_get = 1 },
        .{ .local_get = 0 },
        .{ .local_get = 0 },
        .select,
        .i32_add,
        .{ .global_set = 3 },
    };
    const locals = [_]wasm.module.LocalGroup{.{ .count = 3, .ty = .i32 }};
    var p = try runBody(a, &body, &locals);
    defer p.deinit();
    // i = 0,1,2,3,4,5 → 1,2,3,7,7,1
    try testing.expectEqual(Value{ .int32 = 123771 }, p.global("__G__g2"));
    try testing.expectEqual(Value{ .int32 = 222 + 123771 }, p.global("__G__g3"));
}

test "locals are zero on every call; unreachable traps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // local 0 is read before it is written, then left non-zero.
    const body = [_]I{
        .{ .local_get = 0 },  .{ .global_get = 3 }, .i32_add,             .{ .global_set = 3 },
        .{ .i32_const = 99 }, .{ .local_set = 0 },  .{ .global_get = 2 }, ifElse(null, &.{.unreachable_}, null),
    };
    const locals = [_]wasm.module.LocalGroup{.{ .count = 1, .ty = .i32 }};
    const mod = try simpleModule(a, &.{ .i64, .i64, .i32, .i32 }, &locals, &body);
    var p = try load(mod, null);
    defer p.deinit();
    _ = try p.vm.runEvent("run");
    _ = try p.vm.runEvent("run");
    try testing.expectEqual(Value{ .int32 = 0 }, p.global("__G__g3"));
    _ = p.vm.setVar("__G__g2", .{ .int32 = 1 });
    _ = try p.vm.runEvent("run");
    try testing.expectEqual(udon.vm.LogLevel.err, p.vm.logs.items[0].level);
}

// ----------------------------------------------------------------------
//  Calls
// ----------------------------------------------------------------------

/// A module whose function 0 is the exported nullary `run`; the rest are
/// internal. `g0…g3` are i32 globals; one page of memory.
const Fn = struct { ty: FuncType, locals: []const wasm.module.LocalGroup = &.{}, body: []const I };

fn callModule(a: std.mem.Allocator, fns: []const Fn, table: []const u32, start: ?u32) !wasm.Module {
    const types = try a.alloc(FuncType, fns.len);
    const funcs = try a.alloc(u32, fns.len);
    const codes = try a.alloc(wasm.module.Code, fns.len);
    for (fns, 0..) |f, i| {
        types[i] = f.ty;
        funcs[i] = @intCast(i);
        codes[i] = .{ .locals = f.locals, .body = f.body };
    }
    const gs = try a.alloc(wasm.module.Global, 4);
    const exports = try a.alloc(wasm.module.Export, 5);
    for (gs, 0..) |*g, i| {
        g.* = .{ .ty = .{ .valtype = .i32, .mut = .mutable }, .init = try a.dupe(I, &.{.{ .i32_const = 0 }}) };
        exports[i] = .{ .name = try std.fmt.allocPrint(a, "g{d}", .{i}), .desc = .{ .global = @intCast(i) } };
    }
    exports[4] = .{ .name = "run", .desc = .{ .func = 0 } };
    var mod: wasm.Module = .{
        .types_ = types,
        .funcs = funcs,
        .codes = codes,
        .globals = gs,
        .exports = exports,
        .memories = try a.dupe(wasm.types.MemType, &.{.{ .min = 1, .max = 1 }}),
        .start = start,
    };
    if (table.len != 0) {
        mod.tables = try a.dupe(wasm.types.TableType, &.{.{ .elem = .funcref, .limits = .{ .min = @intCast(table.len + 2), .max = null } }});
        mod.elements = try a.dupe(wasm.module.Element, &.{.{ .table_index = 0, .offset = try a.dupe(I, &.{.{ .i32_const = 1 }}), .init = table }});
    }
    return mod;
}

const ii_i: FuncType = .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} };
const i_i: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };

test "direct calls, argument order, results, and the start function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fns = [_]Fn{
        .{
            .ty = void_type,
            .body = &.{
                // sub(100, 1) called twice (two call sites → indirect return)
                .{ .i32_const = 100 }, .{ .i32_const = 1 }, .{ .call = 1 },
                .{ .i32_const = 7 }, .{ .global_get = 0 }, .{ .call = 1 }, // sub(7, g0)
                .i32_mul,            .{ .global_set = 1 },
                // once(5) has a single call site → direct return
                .{ .i32_const = 5 },
                .{ .call = 2 },      .{ .global_set = 2 },
            },
        },
        .{ .ty = ii_i, .body = &.{ .{ .local_get = 0 }, .{ .local_get = 1 }, .i32_sub } },
        .{ .ty = i_i, .body = &.{ .{ .local_get = 0 }, .{ .i32_const = 3 }, .i32_shl } },
        // start: g0 = 2
        .{ .ty = void_type, .body = &.{ .{ .i32_const = 2 }, .{ .global_set = 0 } } },
    };
    var p = try load(try callModule(a, &fns, &.{}, 3), null);
    defer p.deinit();
    _ = try p.vm.runEvent("run");
    try testing.expectEqual(Value{ .int32 = 99 * 5 }, p.global("__G__g1"));
    try testing.expectEqual(Value{ .int32 = 40 }, p.global("__G__g2"));
    // The start function ran once, before the first event.
    _ = try p.vm.runEvent("run");
    try testing.expectEqual(Value{ .int32 = 2 }, p.global("__G__g0"));
}

test "recursion keeps operands and locals live across the call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fns = [_]Fn{
        .{ .ty = void_type, .body = &.{
            .{ .i32_const = 15 }, .{ .call = 1 }, .{ .global_set = 0 },
            .{ .i32_const = 6 },  .{ .call = 2 }, .{ .global_set = 1 },
            .{ .i32_const = 9 },  .{ .call = 3 }, .{ .global_set = 2 },
        } },
        // fib(n) = n < 2 ? n : fib(n-1) + fib(n-2): the first result is an
        // operand that must survive the second call.
        .{ .ty = i_i, .body = &.{
            .{ .local_get = 0 }, .{ .i32_const = 2 }, .i32_lt_s,
            ifElse(.i32, &.{.{ .local_get = 0 }}, &.{
                .{ .local_get = 0 }, .{ .i32_const = 1 }, .i32_sub, .{ .call = 1 },
                .{ .local_get = 0 }, .{ .i32_const = 2 }, .i32_sub, .{ .call = 1 },
                .i32_add,
            }),
        } },
        // fact(n) with the parameter used after the call.
        .{ .ty = i_i, .locals = &.{.{ .count = 1, .ty = .i32 }}, .body = &.{
            .{ .local_get = 0 }, .i32_eqz,
            ifElse(.i32, &.{.{ .i32_const = 1 }}, &.{
                .{ .local_get = 0 }, .{ .i32_const = 1 }, .i32_sub,            .{ .call = 2 },
                .{ .local_set = 1 }, .{ .local_get = 1 }, .{ .local_get = 0 }, .i32_mul,
            }),
        } },
        // Mutual recursion: even(n) / odd(n), returning n's parity.
        .{ .ty = i_i, .body = &.{
            .{ .local_get = 0 },                                                                                             .i32_eqz,
            ifElse(.i32, &.{.{ .i32_const = 0 }}, &.{ .{ .local_get = 0 }, .{ .i32_const = 1 }, .i32_sub, .{ .call = 4 } }),
        } },
        .{ .ty = i_i, .body = &.{
            .{ .local_get = 0 },                                                                                             .i32_eqz,
            ifElse(.i32, &.{.{ .i32_const = 1 }}, &.{ .{ .local_get = 0 }, .{ .i32_const = 1 }, .i32_sub, .{ .call = 3 } }),
        } },
    };
    var p = try load(try callModule(a, &fns, &.{}, null), null);
    defer p.deinit();
    _ = try p.vm.runEvent("run");
    try testing.expectEqual(Value{ .int32 = 610 }, p.global("__G__g0"));
    try testing.expectEqual(Value{ .int32 = 720 }, p.global("__G__g1"));
    try testing.expectEqual(Value{ .int32 = 1 }, p.global("__G__g2"));
    // The frame stack is back where it started.
    try testing.expectEqual(Value{ .int32 = 0 }, p.global("__frame_depth"));
}

test "a self call may pass its own parameters in a different order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fns = [_]Fn{
        .{ .ty = void_type, .body = &.{ .{ .i32_const = 3 }, .{ .i32_const = 10 }, .{ .call = 1 }, .{ .global_set = 0 } } },
        // f(a, b) = a == 0 ? b : f(b - 1 - a + a, a - 1) … written so the
        // recursive call swaps the parameters: f(a, b) = a == 0 ? b : f(b, a - 1) + 0
        .{ .ty = ii_i, .body = &.{
            .{ .local_get = 0 },                                                                                                                  .i32_eqz,
            ifElse(.i32, &.{.{ .local_get = 1 }}, &.{ .{ .local_get = 1 }, .{ .local_get = 0 }, .{ .i32_const = 1 }, .i32_sub, .{ .call = 1 } }),
        } },
    };
    var p = try load(try callModule(a, &fns, &.{}, null), null);
    defer p.deinit();
    _ = try p.vm.runEvent("run");
    // f(3,10) → f(10,2) → f(2,9) → f(9,1) → f(1,8) → f(8,0) → f(0,7) = 7
    try testing.expectEqual(Value{ .int32 = 7 }, p.global("__G__g0"));
}

test "call_indirect dispatches through the table; an empty slot traps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fns = [_]Fn{
        .{
            .ty = void_type,
            .body = &.{
                // table = [_, f1, f2, _]; index from g3
                .{ .i32_const = 21 }, .{ .global_get = 3 }, .{ .call_indirect = 1 }, .{ .global_set = 0 },
            },
        },
        .{ .ty = i_i, .body = &.{ .{ .local_get = 0 }, .{ .i32_const = 2 }, .i32_mul } },
        .{ .ty = i_i, .body = &.{ .{ .i32_const = 0 }, .{ .local_get = 0 }, .i32_sub } },
    };
    var p = try load(try callModule(a, &fns, &.{ 1, 2 }, null), null);
    defer p.deinit();
    _ = p.vm.setVar("__G__g3", .{ .int32 = 1 });
    _ = try p.vm.runEvent("run");
    try testing.expectEqual(Value{ .int32 = 42 }, p.global("__G__g0"));
    _ = p.vm.setVar("__G__g3", .{ .int32 = 2 });
    _ = try p.vm.runEvent("run");
    try testing.expectEqual(Value{ .int32 = -21 }, p.global("__G__g0"));
    // Slot 0 is empty: the trap routine logs and ends the event.
    _ = p.vm.setVar("__G__g3", .{ .int32 = 0 });
    _ = try p.vm.runEvent("run");
    try testing.expectEqual(udon.vm.LogLevel.err, p.vm.logs.items[0].level);
    try testing.expectEqual(Value{ .int32 = -21 }, p.global("__G__g0"));
}

test "unreachable functions are not translated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fns = [_]Fn{
        .{ .ty = void_type, .body = &.{ .{ .i32_const = 1 }, .{ .global_set = 0 } } },
        .{ .ty = i_i, .body = &.{ .{ .local_get = 0 }, .{ .i32_const = 2 }, .i32_div_u, .i32_popcnt } },
    };
    var p = try load(try callModule(a, &fns, &.{}, null), null);
    defer p.deinit();
    try testing.expect(std.mem.indexOf(u8, p.text, "__f1_") == null);
    try testing.expect(std.mem.indexOf(u8, p.text, "op_Division") == null);
}

// ----------------------------------------------------------------------
//  Globals and constants
// ----------------------------------------------------------------------

test "64-bit and float constants and global initializers are exact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]I{
        .{ .i64_const = @bitCast(@as(u64, 0xFEDC_BA98_7654_3210)) }, .{ .global_set = 0 },
        .{ .f64_const = 0.1 },                                       .i64_reinterpret_f64,
        .{ .global_set = 1 },                                        .{ .f32_const = 0.1 },
        .i32_reinterpret_f32,                                        .{ .global_set = 2 },
        .{ .f32_const = -0.0 },                                      .i32_reinterpret_f32,
        .{ .global_set = 3 },
    };
    var p = try runBody(a, &body, &.{});
    defer p.deinit();
    try testing.expectEqual(@as(u64, 0xFEDC_BA98_7654_3210), bitsOf(p.global("__G__g0")));
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 0.1))), bitsOf(p.global("__G__g1")));
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 0.1)))), bitsOf(p.global("__G__g2")));
    try testing.expectEqual(@as(u64, 0x8000_0000), bitsOf(p.global("__G__g3")));
}
