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

/// Ways to translate recursion, which every test of it goes through: frames
/// saved at every level; three levels with slots of their own and frames
/// below them; and the default.
const unroll_depths = [_]u32{ 0, 3, 64 };

fn unrolled(depth: u32) wasm.UdonMeta {
    return .{ .version = 1, .options = .{ .recursion_unroll = depth } };
}

/// Translate, check and load a module. Any checker finding fails the test.
fn load(mod: wasm.Module, meta: ?wasm.UdonMeta) !Program {
    return loadWith(mod, meta, .{});
}

fn loadWith(mod: wasm.Module, meta: ?wasm.UdonMeta, disable: translate_.Disable) !Program {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var diag: translate_.Diagnostics = .init(a);
    var out: std.Io.Writer.Allocating = .init(a);
    _ = translate_.translate(testing.allocator, mod, meta, &out.writer, .{ .diagnostics = &diag, .disable = disable }) catch |e| {
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

test "following a pointer through its own local: p = p.next; p.next" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 2, .offset = 0 };
    const m8 = wasm.instruction.MemArg{ .@"align" = 2, .offset = 8 };
    // Three nodes at 100, 200, 300, each with `next` at offset 8.
    const body = [_]I{
        .{ .i32_const = 108 }, .{ .i32_const = 200 }, .{ .i32_store = m0 },
        .{ .i32_const = 208 }, .{ .i32_const = 300 }, .{ .i32_store = m0 },
        .{ .i32_const = 308 }, .{ .i32_const = 777 }, .{ .i32_store = m0 },
        .{ .i32_const = 100 }, .{ .local_set = 0 },
        // p = p.next — the load is still pending when p is assigned.
          .{ .local_get = 0 },
        .{ .i32_load = m8 },   .{ .local_set = 0 },
        // q = p.next must use the new p.
          .{ .local_get = 0 },
        .{ .i32_load = m8 },   .{ .global_set = 2 },  .{ .local_get = 0 },
        .{ .i32_load = m8 },   .{ .local_tee = 0 },   .{ .i32_load = m8 },
        .{ .global_set = 3 },
    };
    var p = try runBody(a, &body, &.{.{ .count = 1, .ty = .i32 }});
    defer p.deinit();
    try testing.expectEqual(Value{ .int32 = 300 }, p.global("__G__g2"));
    try testing.expectEqual(Value{ .int32 = 777 }, p.global("__G__g3"));
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

test "passive data segments: memory.init copies, data.drop empties" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 0 };
    const body = [_]I{
        // memory[100..104] = segment 1 [2..6]
        .{ .i32_const = 100 }, .{ .i32_const = 2 },   .{ .i32_const = 4 },   .{ .memory_init = 1 },
        .{ .i32_const = 100 }, .{ .i32_load = m0 },   .{ .global_set = 2 },
        // The active segment was placed at startup; segment 1 was not.
         .{ .i32_const = 8 },
        .{ .i32_load = m0 },   .{ .global_set = 3 },
        // After data.drop a zero-length init still succeeds…
         .{ .data_drop = 1 },   .{ .i32_const = 200 },
        .{ .i32_const = 0 },   .{ .i32_const = 0 },   .{ .memory_init = 1 }, .{ .i64_const = 1 },
        .{ .global_set = 0 },
        // …and any other traps.
         .{ .i32_const = 200 }, .{ .i32_const = 0 },   .{ .i32_const = 1 },
        .{ .memory_init = 1 }, .{ .i64_const = 2 },   .{ .global_set = 0 },
    };
    var mod = try simpleModule(a, &.{ .i64, .i64, .i32, .i32 }, &.{}, &body);
    const offset = try a.dupe(I, &.{.{ .i32_const = 8 }});
    mod.datas = try a.dupe(wasm.module.Data, &.{
        .{ .memory_index = 0, .offset = offset, .init = "\x11\x22\x33\x44" },
        .{ .memory_index = 0, .offset = &.{}, .init = "abcdefgh", .passive = true },
    });
    var p = try load(mod, null);
    defer p.deinit();
    try testing.expectError(error.UdonFault, p.vm.runEvent("run"));
    try testing.expectEqual(Value{ .int32 = std.mem.readInt(i32, "cdef", .little) }, p.global("__G__g2"));
    try testing.expectEqual(Value{ .int32 = 0x44332211 }, p.global("__G__g3"));
    try testing.expectEqual(Value{ .int64 = 1 }, p.global("__G__g0"));
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

test "br_if that carries a value: the value is ready on both paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m4 = wasm.instruction.MemArg{ .@"align" = 2, .offset = 4 };
    const i32_block: wasm.types.BlockType = .{ .value = .i32 };
    for ([_]i32{ 0, 1 }) |take| {
        // block (result i32)
        //   local 0 = 96;  [100] = 7
        //   (load [local0 + 4])        ← pending when the br_if is lowered
        //   global 2 (the condition)
        //   br_if 0                    ← carries the load
        //   ;; not taken: the same value is still on the stack
        //   i32.const 1000  i32.add
        //   ;; and the same field is read again through the same local
        //   local.get 0  i32.load offset=4  i32.add
        // end
        const inner = [_]I{
            .{ .i32_const = 96 },                              .{ .local_set = 0 },
            .{ .i32_const = 100 },                             .{ .i32_const = 7 },
            .{ .i32_store = .{ .@"align" = 2, .offset = 0 } }, .{ .local_get = 0 },
            .{ .i32_load = m4 },                               .{ .global_get = 2 },
            .{ .br_if = 0 },                                   .{ .i32_const = 1000 },
            .i32_add,                                          .{ .local_get = 0 },
            .{ .i32_load = m4 },                               .i32_add,
        };
        // The same with a comparison as the carried value.
        const inner2 = [_]I{
            .{ .global_get = 2 }, .{ .i32_const = 5 }, .i32_lt_s,
            .{ .global_get = 2 }, .{ .br_if = 0 },     .{ .i32_const = 40 },
            .i32_add,
        };
        const body = [_]I{
            .{ .i32_const = take },                              .{ .global_set = 2 },
            .{ .block = .{ .bt = i32_block, .body = &inner } },  .{ .global_set = 3 },
            .{ .block = .{ .bt = i32_block, .body = &inner2 } }, .i64_extend_i32_s,
            .{ .global_set = 0 },
        };
        var p = try runBody(a, &body, &.{.{ .count = 1, .ty = .i32 }});
        defer p.deinit();
        try testing.expectEqual(Value{ .int32 = if (take != 0) 7 else 1014 }, p.global("__G__g3"));
        try testing.expectEqual(Value{ .int64 = if (take != 0) 1 else 41 }, p.global("__G__g0"));
    }
}

test "br_table through a jump table: every case, the default, out of range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Each case carries 1000 to a different block, which adds its own
    // number; case 5 leaves all of them.
    const labels = [_]u32{ 0, 1, 2, 3, 4, 5, 1, 3 };
    const expected = [_]i32{ 1001, 1002, 1003, 1004, 1005, 1000, 1002, 1004 };
    const indices = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 100, -1, std.math.minInt(i32), std.math.maxInt(i32) };
    for (indices) |index| {
        const body = [_]I{
            .{ .i32_const = index },
            .{ .local_set = 0 },
            block(.i32, &.{
                block(.i32, &.{
                    block(.i32, &.{
                        block(.i32, &.{
                            block(.i32, &.{
                                block(.i32, &.{
                                    .{ .i32_const = 1000 },
                                    .{ .local_get = 0 },
                                    .{ .br_table = .{ .labels = &labels, .default = 2 } },
                                }),
                                .{ .i32_const = 1 },
                                .i32_add,
                                .{ .br = 4 },
                            }),
                            .{ .i32_const = 2 },
                            .i32_add,
                            .{ .br = 3 },
                        }),
                        .{ .i32_const = 3 },
                        .i32_add,
                        .{ .br = 2 },
                    }),
                    .{ .i32_const = 4 },
                    .i32_add,
                    .{ .br = 1 },
                }),
                .{ .i32_const = 5 },
                .i32_add,
            }),
            .{ .global_set = 2 },
        };
        var p = try runBody(a, &body, &.{.{ .count = 1, .ty = .i32 }});
        defer p.deinit();
        const want = if (index >= 0 and index < expected.len) expected[@intCast(index)] else 1003;
        try testing.expectEqual(Value{ .int32 = want }, p.global("__G__g2"));
        // The dispatch is an indexed jump, not a chain of comparisons.
        try testing.expect(p.vm.stats.externs <= 8);
    }
}

test "br_table through a jump table: cases that return, a loop as a case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Depth 3 is the function. `by_default` picks which of the two tables
    // has the return as its default.
    for ([_]bool{ false, true }) |by_default| {
        const labels: []const u32 = if (by_default) &.{ 0, 1, 2, 0, 1, 2 } else &.{ 0, 1, 3, 0, 1, 2, 3 };
        const default: u32 = if (by_default) 3 else 0;
        for ([_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, -5 }) |index| {
            const body = [_]I{
                .{ .i32_const = index },
                .{ .local_set = 0 },
                .{ .i32_const = 7 },
                .{ .global_set = 2 },
                loop(&.{
                    // Counts the passes: case 2 comes back here once.
                    .{ .global_get = 3 },
                    .{ .i32_const = 1 },
                    .i32_add,
                    .{ .global_set = 3 },
                    block(null, &.{
                        block(null, &.{
                            .{ .local_get = 0 },
                            .{ .local_get = 0 },
                            .{ .i32_const = 1 },
                            .i32_sub,
                            // Second pass of the loop: index - 1.
                            .{ .global_get = 3 },
                            .{ .i32_const = 1 },
                            .i32_eq,
                            .select,
                            .{ .br_table = .{ .labels = labels, .default = default } },
                        }),
                        .{ .i32_const = 1 },
                        .{ .global_set = 2 },
                        .return_,
                    }),
                    .{ .i32_const = 2 },
                    .{ .global_set = 2 },
                }),
            };
            var p = try runBody(a, &body, &.{.{ .count = 1, .ty = .i32 }});
            defer p.deinit();
            // Reference: what the same table does, followed twice at most.
            var x = index;
            var passes: i32 = 0;
            const result: i32 = while (true) {
                passes += 1;
                const i = if (passes == 1) x else x - 1;
                const d = if (i >= 0 and i < labels.len) labels[@intCast(i)] else default;
                switch (d) {
                    0 => break 1,
                    1 => break 2,
                    2 => x = i,
                    else => break 7,
                }
                if (passes > 20) return error.TestUnexpectedResult;
            };
            try testing.expectEqual(Value{ .int32 = result }, p.global("__G__g2"));
            try testing.expectEqual(Value{ .int32 = passes }, p.global("__G__g3"));
        }
    }
}

test "counted loops preserve unsigned order, wrapping addresses and live cursors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Both the same-base address expression and the unsigned comparison
    // observe i. It crosses the sign boundary during the four iterations.
    const body = [_]I{
        .{ .i32_const = 0x7fff_fffe },  .{ .local_set = 0 },
        .{ .i32_const = -0x7fff_ffff }, .{ .local_set = 1 },
        .{ .i32_const = -0x7fff_fffc }, .{ .local_set = 2 },
        .{ .i32_const = 4 },            .{ .local_set = 3 },
        .{ .i32_const = -2 },           .{ .local_set = 4 },
        loop(&.{
            .{ .local_get = 0 },  .{ .local_get = 1 }, .i32_lt_u,
            ifElse(null, &.{
                .{ .global_get = 2 }, .{ .local_get = 2 }, .{ .local_get = 0 }, .i32_add, .i32_add, .{ .global_set = 2 },
            }, null),
            .{ .local_get = 4 },  .{ .i32_const = 1 }, .i32_add,
            .{ .local_set = 4 },  .{ .local_get = 0 }, .{ .i32_const = 1 },
            .i32_add,             .{ .local_set = 0 }, .{ .local_get = 3 },
            .{ .i32_const = -1 }, .i32_add,            .{ .local_tee = 3 },
            .{ .br_if = 0 },
        }),
        .{ .local_get = 0 },            .i64_extend_i32_u,
        .{ .global_set = 0 },           .{ .local_get = 4 },
        .i64_extend_i32_s,              .{ .global_set = 1 },
        .{ .local_get = 3 },            .{ .global_set = 3 },
    };
    var p = try runBody(arena.allocator(), &body, &.{.{ .count = 5, .ty = .i32 }});
    defer p.deinit();
    try testing.expectEqual(Value{ .int32 = 2 + 3 + 4 }, p.global("__G__g2"));
    try testing.expectEqual(Value{ .int64 = 0x8000_0002 }, p.global("__G__g0"));
    try testing.expectEqual(Value{ .int64 = 2 }, p.global("__G__g1"));
    try testing.expectEqual(Value{ .int32 = 0 }, p.global("__G__g3"));
}

test "a loop-carried comparison stays known until either operand changes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]I{
        .{ .i32_const = 17 }, .{ .local_set = 0 },
        loop(&.{
            .{ .local_get = 0 },                                                 .{ .i32_const = 17 }, .i32_eq,
            ifElse(null, &.{
                .{ .local_get = 2 }, .{ .i32_const = 3 }, .i32_add, .{ .local_set = 2 },
            }, &.{
                .{ .local_get = 2 }, .{ .i32_const = 1 }, .i32_add, .{ .local_set = 2 },
            }),
            .{ .local_get = 1 },                                                 .{ .i32_const = 10 }, .i32_eq,
            ifElse(null, &.{ .{ .i32_const = 18 }, .{ .local_set = 0 } }, null), .{ .local_get = 1 },  .{ .i32_const = 1 },
            .i32_add,                                                            .{ .local_tee = 1 },  .{ .i32_const = 24 },
            .i32_ne,                                                             .{ .br_if = 0 },
        }),
        .{ .local_get = 2 },  .{ .global_set = 0 },
    };
    const mod = try simpleModule(arena.allocator(), &.{.i32}, &.{.{ .count = 3, .ty = .i32 }}, &body);
    var original = try loadWith(mod, null, .{ .loop_paths = true });
    defer original.deinit();
    var optimized = try load(mod, null);
    defer optimized.deinit();
    for ([_]*Program{ &original, &optimized }) |p| {
        _ = try p.vm.runEvent("run");
        try testing.expectEqual(Value{ .int32 = 46 }, p.global("__G__g0"));
    }
    try testing.expect(optimized.vm.stats.externs < original.vm.stats.externs);
}

test "strip-mined equality bounds retain partial steps, tails and i32 wraparound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const first: i32 = 0x7fff_fffd;
    for ([_]i32{ 1, 2, 3, 4, 5, 7, 65, 67 }) |count| {
        for ([_]i32{ -1, 0, 2, 11, 93 }) |distance| {
            const limit = first +% distance;
            const body = [_]I{
                .{ .i32_const = first }, .{ .local_set = 0 },
                .{ .i32_const = first }, .{ .local_set = 1 },
                loop(&.{
                    .{ .local_get = 0 }, .{ .i32_const = limit }, .i32_ne,
                    ifElse(null, &.{
                        .{ .local_get = 1 },                                                                               .{ .i32_const = first +% 5 }, .i32_ne,
                        ifElse(null, &.{ .{ .local_get = 0 }, .{ .i32_const = 1 }, .i32_add, .{ .local_set = 0 } }, null), .{ .local_get = 2 },          .{ .i32_const = 7 },
                        .i32_add,                                                                                          .{ .local_set = 2 },
                    }, &.{ .{ .local_get = 2 }, .{ .i32_const = 13 }, .i32_add, .{ .local_set = 2 } }),
                    .{ .local_get = 1 }, .{ .i32_const = 1 },     .i32_add,
                    .{ .local_set = 1 }, .{ .local_get = 1 },     .{ .i32_const = first +% count },
                    .i32_ne,             .{ .br_if = 0 },
                }),
                .{ .local_get = 2 },     .{ .global_set = 0 },
                .{ .local_get = 0 },     .{ .global_set = 1 },
            };
            const mod = try simpleModule(arena.allocator(), &.{ .i32, .i32 }, &.{.{ .count = 3, .ty = .i32 }}, &body);
            var original = try loadWith(mod, null, .{ .loop_strip_mining = true });
            defer original.deinit();
            var optimized = try load(mod, null);
            defer optimized.deinit();
            var cursor = first;
            var sum: i32 = 0;
            for (0..@intCast(count)) |i| {
                if (cursor != limit) {
                    if (i != 5) cursor +%= 1;
                    sum += 7;
                } else sum += 13;
            }
            for ([_]*Program{ &original, &optimized }) |p| {
                _ = try p.vm.runEvent("run");
                try testing.expectEqual(Value{ .int32 = sum }, p.global("__G__g0"));
                try testing.expectEqual(Value{ .int32 = cursor }, p.global("__G__g1"));
            }
            if (distance == 93 and count == 65) try testing.expect(optimized.vm.stats.externs < original.vm.stats.externs);
        }
    }
}

test "invariant arithmetic follows the lifetime of the outermost immutable operands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]I{
        .{ .i32_const = 2 }, .{ .local_set = 0 },
        loop(&.{
            .{ .i32_const = 0 }, .{ .local_set = 1 },
            loop(&.{
                .{ .local_get = 2 }, .{ .local_get = 0 }, .{ .i32_const = 5 }, .i32_mul,            .i32_add,             .{ .local_set = 2 },
                .{ .local_get = 1 }, .{ .i32_const = 1 }, .i32_add,            .{ .local_tee = 1 }, .{ .i32_const = 12 }, .i32_ne,
                .{ .br_if = 0 },
            }),
            .{ .local_get = 0 }, .{ .i32_const = 1 },
            .i32_add,            .{ .local_tee = 0 },
            .{ .i32_const = 5 }, .i32_ne,
            .{ .br_if = 0 },
        }),
        .{ .local_get = 2 }, .{ .global_set = 0 },
    };
    const mod = try simpleModule(arena.allocator(), &.{.i32}, &.{.{ .count = 3, .ty = .i32 }}, &body);
    var original = try loadWith(mod, null, .{ .loop_invariants = true });
    defer original.deinit();
    var optimized = try load(mod, null);
    defer optimized.deinit();
    for ([_]*Program{ &original, &optimized }) |p| {
        _ = try p.vm.runEvent("run");
        try testing.expectEqual(Value{ .int32 = (2 + 3 + 4) * 5 * 12 }, p.global("__G__g0"));
    }
    try testing.expectEqual(@as(u64, 33), original.vm.stats.externs - optimized.vm.stats.externs);
}

test "a guarded unit induction variable reaches its unsigned sentinel or stays still" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_]u32{ 0x7fff_fffe, 0x8000_0001, 0x8000_0002, 0xffff_ffff }) |initial| {
        const limit: u32 = 0x8000_0001;
        const base: i32 = -0x7fff_fffc;
        const body = [_]I{
            .{ .i32_const = @bitCast(initial) }, .{ .local_set = 0 },
            .{ .i32_const = @bitCast(limit) },   .{ .local_set = 1 },
            .{ .i32_const = base },              .{ .local_set = 2 },
            .{ .i32_const = 5 },                 .{ .local_set = 3 },
            loop(&.{
                block(null, &.{
                    block(null, &.{ .{ .local_get = 0 }, .{ .local_get = 1 }, .i32_lt_u, .{ .br_if = 0 }, .{ .br = 1 } }),
                    .{ .global_get = 2 },
                    .{ .local_get = 0 },
                    .{ .local_get = 2 },
                    .i32_add,
                    .i32_add,
                    .{ .global_set = 2 },
                    .{ .local_get = 0 },
                    .{ .i32_const = 1 },
                    .i32_add,
                    .{ .local_set = 0 },
                }),
                .{ .local_get = 4 },
                .{ .i32_const = 1 },
                .i32_add,
                .{ .local_set = 4 },
                .{ .local_get = 3 },
                .{ .i32_const = -1 },
                .i32_add,
                .{ .local_tee = 3 },
                .{ .br_if = 0 },
            }),
            .{ .local_get = 0 },                 .{ .global_set = 3 },
        };
        var p = try runBody(arena.allocator(), &body, &.{.{ .count = 5, .ty = .i32 }});
        defer p.deinit();
        var i = initial;
        var sum: i32 = 0;
        for (0..5) |_| if (i < limit) {
            sum +%= @as(i32, @bitCast(i)) +% base;
            i += 1;
        };
        try testing.expectEqual(Value{ .int32 = sum }, p.global("__G__g2"));
        try testing.expectEqual(Value{ .int32 = @bitCast(i) }, p.global("__G__g3"));
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
    var externs: [unroll_depths.len]u64 = undefined;
    for (unroll_depths, &externs) |depth, *n| {
        var p = try load(try callModule(a, &fns, &.{}, null), unrolled(depth));
        defer p.deinit();
        _ = try p.vm.runEvent("run");
        try testing.expectEqual(Value{ .int32 = 610 }, p.global("__G__g0"));
        try testing.expectEqual(Value{ .int32 = 720 }, p.global("__G__g1"));
        try testing.expectEqual(Value{ .int32 = 1 }, p.global("__G__g2"));
        // The frame stack is back where it started.
        try testing.expectEqual(Value{ .int32 = 0 }, p.global("__frame_depth"));
        n.* = p.vm.stats.externs;
    }
    // Every level that has its own slots saves that much work.
    try testing.expect(externs[1] < externs[0] and externs[2] < externs[1]);
}

test "recursion: a local read before the call but used after it survives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // f(n) = n == 0 ? 0 : n + f(n - 1), written so that `n` is pushed
    // before the recursive call and never read again in the instruction
    // stream: only the pending operand keeps it alive.
    const i32_block: wasm.types.BlockType = .{ .value = .i32 };
    const f_body = [_]I{
        .{ .local_get = 0 }, .i32_eqz,
        .{ .if_ = .{ .bt = i32_block, .then_body = &.{.{ .i32_const = 0 }}, .else_body = &.{
            .{ .local_get = 0 },
            .{ .local_get = 0 },
            .{ .i32_const = 1 },
            .i32_sub,
            .{ .call = 1 },
            .i32_add,
        } } },
    };
    const run_body = [_]I{ .{ .i32_const = 10 }, .{ .call = 1 }, .{ .global_set = 2 } };
    var mod = try simpleModule(a, &.{ .i64, .i64, .i32, .i32 }, &.{}, &run_body);
    mod.types_ = try a.dupe(FuncType, &.{ void_type, .{ .params = &.{.i32}, .results = &.{.i32} } });
    mod.funcs = try a.dupe(u32, &.{ 0, 1 });
    mod.codes = try a.dupe(wasm.module.Code, &.{ mod.codes[0], .{ .locals = &.{}, .body = &f_body } });
    for (unroll_depths) |depth| {
        var p = try load(mod, unrolled(depth));
        defer p.deinit();
        _ = try p.vm.runEvent("run");
        try testing.expectEqual(Value{ .int32 = 55 }, p.global("__G__g2"));
    }
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
    for (unroll_depths) |depth| {
        var p = try load(try callModule(a, &fns, &.{}, null), unrolled(depth));
        defer p.deinit();
        _ = try p.vm.runEvent("run");
        // f(3,10) → f(10,2) → f(2,9) → f(9,1) → f(1,8) → f(8,0) → f(0,7) = 7
        try testing.expectEqual(Value{ .int32 = 7 }, p.global("__G__g0"));
    }
}

test "unrolled recursion: levels with slots of their own save nothing; the original takes over below them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // sum(n) = n == 0 ? 0 : n + sum(n - 1), with n live across the call.
    const fns = [_]Fn{
        .{ .ty = void_type, .body = &.{ .{ .i32_const = 20 }, .{ .call = 1 }, .{ .global_set = 0 } } },
        .{ .ty = i_i, .body = &.{
            .{ .local_get = 0 },                                                                                                                            .i32_eqz,
            ifElse(.i32, &.{.{ .i32_const = 0 }}, &.{ .{ .local_get = 0 }, .{ .i32_const = 1 }, .i32_sub, .{ .call = 1 }, .{ .local_get = 0 }, .i32_add }),
        } },
    };
    const mod = try callModule(a, &fns, &.{}, null);
    var cost: [3]u64 = undefined;
    for ([_]u32{ 0, 8, 64 }, &cost) |depth, *n| {
        var p = try load(mod, unrolled(depth));
        defer p.deinit();
        _ = try p.vm.runEvent("run");
        try testing.expectEqual(Value{ .int32 = 210 }, p.global("__G__g0"));
        n.* = p.vm.stats.externs;
        // Deep enough copies: no frame is ever saved, so the frame stack
        // is not even declared — the original function is still there for
        // a deeper recursion, but this one never reaches it.
        if (depth == 64) try testing.expectEqual(Value{ .int32 = 0 }, p.global("__frame_depth"));
    }
    // 20 levels each cost a subtraction, a test and an addition; a saved
    // frame costs four externs more (one slot and the depth, each way).
    try testing.expectEqual(@as(u64, 4 * 20), cost[0] - cost[2]);
    try testing.expectEqual(@as(u64, 4 * 8), cost[0] - cost[1]);
}

test "unrolled recursion: mutual recursion and functions reached through the table are left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const unroll = @import("unroll.zig");
    // 1: self-recursive, small. 2 ⇄ 3: mutually recursive. 4: calls itself
    // and, through the table, could be called back by 5, which calls 4.
    const self_call = [_]I{ .{ .local_get = 0 }, .{ .call = 1 } };
    const fns = [_]Fn{
        .{ .ty = void_type, .body = &.{ .{ .i32_const = 1 }, .{ .call = 1 }, .drop, .{ .i32_const = 1 }, .{ .call = 4 }, .drop } },
        .{ .ty = i_i, .body = &self_call },
        .{ .ty = i_i, .body = &.{ .{ .local_get = 0 }, .{ .call = 3 } } },
        .{ .ty = i_i, .body = &.{ .{ .local_get = 0 }, .{ .call = 2 } } },
        .{ .ty = i_i, .body = &.{ .{ .local_get = 0 }, .{ .call = 4 }, .{ .i32_const = 1 }, .{ .call_indirect = 1 } } },
        .{ .ty = i_i, .body = &.{ .{ .local_get = 0 }, .{ .call = 4 } } },
    };
    const mod = try callModule(a, &fns, &.{5}, null);
    const out = try unroll.unroll(a, mod, .{ .depth = 4 });
    // Four copies of function 1 and nothing else.
    try testing.expectEqual(mod.funcs.len + 4, out.funcs.len);
    // Callers go to the first copy, each copy to the next, the last to
    // the original, which still calls itself.
    try testing.expectEqual(@as(u32, 6), out.codes[0].body[1].call);
    try testing.expectEqual(@as(u32, 4), out.codes[0].body[4].call);
    try testing.expectEqual(@as(u32, 7), out.codes[6].body[1].call);
    try testing.expectEqual(@as(u32, 1), out.codes[9].body[1].call);
    try testing.expectEqual(@as(u32, 1), out.codes[1].body[1].call);
    // A function too large for enough copies within the budget is left
    // alone.
    try testing.expectEqual(mod.funcs.len, (try unroll.unroll(a, mod, .{ .depth = 4, .budget = 7 })).funcs.len);
    try testing.expectEqual(mod.funcs.len, (try unroll.unroll(a, mod, .{ .budget = 16 })).funcs.len);
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

// ----------------------------------------------------------------------
//  WASI preview 1
// ----------------------------------------------------------------------

const wasi_module = "wasi_snapshot_preview1";

fn wasiImport(name: []const u8, type_index: u32) wasm.module.Import {
    return .{ .module = wasi_module, .name = name, .desc = .{ .func = type_index } };
}

/// A module importing WASI functions (types by index into `wasi_types`),
/// with `_start` as function `imports.len` and an optional helper after it.
const wasi_types = [_]FuncType{
    .{ .params = &.{}, .results = &.{} }, // 0
    .{ .params = &.{ .i32, .i32, .i32, .i32 }, .results = &.{.i32} }, // 1: fd_write, fd_read
    .{ .params = &.{.i32}, .results = &.{} }, // 2: proc_exit
    .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} }, // 3: *_sizes_get, random_get, fd_fdstat_get
    .{ .params = &.{ .i32, .i64, .i32 }, .results = &.{.i32} }, // 4: clock_time_get
    .{ .params = &.{ .i32, .i64, .i32, .i32 }, .results = &.{.i32} }, // 5: fd_seek
    .{ .params = &.{ .i32, .i32, .i32, .i32, .i32, .i64, .i64, .i32, .i32 }, .results = &.{.i32} }, // 6: path_open
    .{ .params = &.{.i32}, .results = &.{.i32} }, // 7: fd_close
};

fn wasiModule(a: std.mem.Allocator, imports: []const wasm.module.Import, body: []const I, data: []const u8) !wasm.Module {
    var mod = try simpleModule(a, &.{ .i64, .i64, .i32, .i32 }, &.{}, body);
    mod.types_ = &wasi_types;
    mod.imports = imports;
    const exports = try a.dupe(wasm.module.Export, mod.exports);
    exports[exports.len - 1] = .{ .name = "_start", .desc = .{ .func = @intCast(imports.len) } };
    mod.exports = exports;
    const offset = try a.dupe(I, &.{.{ .i32_const = 0 }});
    mod.datas = try a.dupe(wasm.module.Data, &.{.{ .memory_index = 0, .offset = offset, .init = data }});
    return mod;
}

test "WASI: fd_write reaches the log a line at a time; proc_exit ends the event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 2, .offset = 0 };
    // Memory: text at 0, three iovecs at 64, nwritten at 96.
    //   "Hello, " | "Udon!\nsecond line\nno newline" | " yet"
    const text = "Hello, Udon!\nsecond line\nno newline yet" ++ "warn\n";
    var data: [128]u8 = @splat(0);
    @memcpy(data[0..text.len], text);
    const iov = [_]u32{ 0, 7, 7, 28, 35, 4, 39, 5 };
    for (iov, 0..) |x, i| std.mem.writeInt(u32, data[64 + i * 4 ..][0..4], x, .little);

    const fd_write = 0;
    const proc_exit = 1;
    const body = [_]I{
        // Two iovecs in one call: one complete line straddles them, a
        // second line follows, and a third is left unfinished.
        .{ .i32_const = 1 },   .{ .i32_const = 64 }, .{ .i32_const = 2 },  .{ .i32_const = 96 },  .{ .call = fd_write },
        .{ .global_set = 2 },  .{ .i32_const = 96 }, .{ .i32_load = m0 },  .{ .global_set = 3 },
        // stderr is a separate stream.
         .{ .i32_const = 2 },
        .{ .i32_const = 88 },  .{ .i32_const = 1 },  .{ .i32_const = 96 }, .{ .call = fd_write }, .drop,
        // The rest of the third line arrives without a newline;
        // proc_exit shows it.
        .{ .i32_const = 1 },   .{ .i32_const = 80 }, .{ .i32_const = 1 },  .{ .i32_const = 96 },  .{ .call = fd_write },
        .drop,
        // A descriptor that does not exist.
                        .{ .i32_const = 7 },  .{ .i32_const = 64 }, .{ .i32_const = 1 },   .{ .i32_const = 96 },
        .{ .call = fd_write }, .i64_extend_i32_u,    .{ .global_set = 0 }, .{ .i32_const = 3 },   .{ .call = proc_exit },
        // Never reached.
        .{ .i64_const = 99 },  .{ .global_set = 1 },
    };
    const mod = try wasiModule(a, &.{ wasiImport("fd_write", 1), wasiImport("proc_exit", 2) }, &body, &data);
    var p = try load(mod, null);
    defer p.deinit();
    _ = try p.vm.runEvent("_start");
    try testing.expectEqualStrings("Hello, Udon!\nsecond line\nwarn\nno newline yet\n", try p.vm.logText());
    try testing.expectEqual(udon.vm.LogLevel.warning, p.vm.logs.items[2].level);
    try testing.expectEqual(Value{ .int32 = 0 }, p.global("__G__g2")); // errno
    try testing.expectEqual(Value{ .int32 = 35 }, p.global("__G__g3")); // bytes written
    try testing.expectEqual(Value{ .int64 = 8 }, p.global("__G__g0")); // badf
    try testing.expectEqual(Value{ .int64 = 0 }, p.global("__G__g1"));
}

test "WASI: clocks, random bytes, descriptors, and what a system without files answers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 0 };
    const imports = [_]wasm.module.Import{
        wasiImport("clock_time_get", 4), wasiImport("random_get", 3), wasiImport("fd_fdstat_get", 3),
        wasiImport("fd_seek", 5),        wasiImport("path_open", 6),  wasiImport("environ_sizes_get", 3),
        wasiImport("fd_close", 7),       wasiImport("fd_read", 1),    wasiImport("fd_prestat_get", 3),
    };
    const body = [_]I{
        // Monotonic clock → g0, wall clock → g1.
        .{ .i32_const = 1 },  .{ .i64_const = 0 },  .{ .i32_const = 16 }, .{ .call = 0 },         .drop,
        .{ .i32_const = 16 }, .{ .i64_load = m0 },  .{ .global_set = 0 }, .{ .i32_const = 0 },    .{ .i64_const = 0 },
        .{ .i32_const = 16 }, .{ .call = 0 },       .drop,                .{ .i32_const = 16 },   .{ .i64_load = m0 },
        .{ .global_set = 1 },
        // errno sum → g2: CPU clock (28) + fdstat of fd 9 (8) + seek (70)
        // + path_open (52) + environ_sizes_get (0) + close (0) + read of
        // stdin (0) + prestat (8) + random (0) + fdstat of stdout (0).
        .{ .i32_const = 2 },  .{ .i64_const = 0 },  .{ .i32_const = 16 },   .{ .call = 0 },
        .{ .i32_const = 9 },  .{ .i32_const = 32 }, .{ .call = 2 },       .i32_add,               .{ .i32_const = 1 },
        .{ .i64_const = 5 },  .{ .i32_const = 0 },  .{ .i32_const = 16 }, .{ .call = 3 },         .i32_add,
        .{ .i32_const = 3 },  .{ .i32_const = 0 },  .{ .i32_const = 0 },  .{ .i32_const = 0 },    .{ .i32_const = 0 },
        .{ .i64_const = 0 },  .{ .i64_const = 0 },  .{ .i32_const = 0 },  .{ .i32_const = 16 },   .{ .call = 4 },
        .i32_add,             .{ .i32_const = 60 }, .{ .i32_const = 64 }, .{ .call = 5 },         .i32_add,
        .{ .i32_const = 1 },  .{ .call = 6 },       .i32_add,             .{ .i32_const = 0 },    .{ .i32_const = 16 },
        .{ .i32_const = 0 },  .{ .i32_const = 60 }, .{ .call = 7 },       .i32_add,               .{ .i32_const = 3 },
        .{ .i32_const = 16 }, .{ .call = 8 },       .i32_add,             .{ .i32_const = 100 },  .{ .i32_const = 16 },
        .{ .call = 1 },       .i32_add,             .{ .i32_const = 1 },  .{ .i32_const = 40 },   .{ .call = 2 },
        .i32_add,             .{ .global_set = 2 },
        // The file type of stdout (character device = 2) → g3.
        .{ .i32_const = 40 }, .{ .i32_load8_u = m0 }, .{ .global_set = 3 },
    };
    var data: [128]u8 = @splat(0xEE);
    const mod = try wasiModule(a, &imports, &body, &data);
    var p = try load(mod, null);
    defer p.deinit();
    p.vm.host.time = 2.5;
    _ = try p.vm.runEvent("_start");
    try testing.expectEqual(Value{ .int64 = 2_500_000_000 }, p.global("__G__g0"));
    // 2024-01-01T00:00:02.5Z in nanoseconds since 1970.
    try testing.expectEqual(Value{ .int64 = 1_704_067_202_500_000_000 }, p.global("__G__g1"));
    try testing.expectEqual(Value{ .int32 = 28 + 8 + 70 + 52 + 8 }, p.global("__G__g2"));
    try testing.expectEqual(Value{ .int32 = 2 }, p.global("__G__g3"));
    // random_get filled exactly its 16 bytes; the rest of fdstat is zero.
    const memory = p.global("__G__memory").array.bytes;
    try testing.expect(!std.mem.allEqual(u8, memory[100..116], 0xEE));
    try testing.expectEqual(@as(u8, 0xEE), memory[116]);
    try testing.expect(std.mem.allEqual(u8, memory[41..64], 0));
}

test "WASI: an import the interface does not have is refused in strict mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]I{ .{ .i32_const = 0 }, .{ .call = 0 }, .drop };
    const mod = try wasiModule(a, &.{wasiImport("fd_frobnicate", 7)}, &body, "");
    var diag: translate_.Diagnostics = .init(a);
    var out: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.Unsupported, translate_.translate(testing.allocator, mod, null, &out.writer, .{ .strict = true, .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message, "fd_frobnicate") != null);
    // Otherwise it answers "not implemented".
    var p = try load(mod, null);
    defer p.deinit();
    _ = try p.vm.runEvent("_start");
}

// ----------------------------------------------------------------------
//  Threads, for one thread
// ----------------------------------------------------------------------

fn atomic(op: u32) I {
    return .{ .atomic = .{ .op = op, .memarg = .{ .@"align" = 0, .offset = 0 } } };
}

fn word(p: *Program, address: usize) u32 {
    return std.mem.readInt(u32, p.global("__G__memory").array.bytes[address..][0..4], .little);
}

test "atomics on one thread: loads, stores, read-modify-write, compare-exchange, wait and notify" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 2, .offset = 0 };
    // The cell is at 16; each instruction's result goes to 64, 68, ….
    const rmw = struct {
        fn f(comptime result_at: i32, comptime op: u32, comptime operand: i32) [5]I {
            return .{ .{ .i32_const = result_at }, .{ .i32_const = 16 }, .{ .i32_const = operand }, atomic(op), .{ .i32_store = .{ .@"align" = 2, .offset = 0 } } };
        }
    }.f;
    const body = [_]I{ .{ .i32_const = 16 }, .{ .i32_const = 100 }, atomic(0x17) } ++
        rmw(64, 0x1E, 5) ++ // add:  100 → 105
        rmw(68, 0x25, 3) ++ // sub:  105 → 102
        rmw(72, 0x2C, 0x0F) ++ // and:  102 → 6
        rmw(76, 0x33, 0x30) ++ // or:   6 → 54
        rmw(80, 0x3A, 0xFF) ++ // xor:  54 → 201
        rmw(84, 0x41, 7) ++ // xchg: 201 → 7
        [_]I{
            // cmpxchg that succeeds (7 → 9), then one that does not.
            .{ .i32_const = 88 },  .{ .i32_const = 16 },      .{ .i32_const = 7 },     .{ .i32_const = 9 },    atomic(0x48),          .{ .i32_store = m0 },
            .{ .i32_const = 92 },  .{ .i32_const = 16 },      .{ .i32_const = 7 },     .{ .i32_const = 11 },   atomic(0x48),          .{ .i32_store = m0 },
            .{ .i32_const = 96 },  .{ .i32_const = 16 },      atomic(0x10),            .{ .i32_store = m0 },
            // One byte of a word: 0x1FF + 2 wraps within the byte.
              .{ .i32_const = 32 },  .{ .i32_const = 0x1FF },
            .{ .i32_store = m0 },  .{ .i32_const = 100 },     .{ .i32_const = 32 },    .{ .i32_const = 2 },    atomic(0x20),          .{ .i32_store = m0 },
            // cmpxchg8 compares only the byte: 0x701 matches 0x01.
            .{ .i32_const = 104 }, .{ .i32_const = 32 },      .{ .i32_const = 0x701 }, .{ .i32_const = 0x55 }, atomic(0x4A),          .{ .i32_store = m0 },
            // 64 bits.
            .{ .i32_const = 40 },  .{ .i64_const = 1 << 40 }, .{ .i64_store = m0 },    .{ .i32_const = 40 },   .{ .i64_const = 1 },   atomic(0x1F),
            .{ .global_set = 0 },  .{ .i32_const = 40 },      atomic(0x11),            .{ .global_set = 1 },
            // Nobody to wake; a wait on a different value, and one that
            // times out.
              .{ .i32_const = 108 }, .{ .i32_const = 16 },
            .{ .i32_const = 1 },   atomic(0x00),              .{ .i32_const = 40 },    .i32_add,               .{ .i32_store = m0 },  .{ .i32_const = 112 },
            .{ .i32_const = 16 },  .{ .i32_const = 8 },       .{ .i64_const = -1 },    atomic(0x01),           .{ .i32_store = m0 },  .{ .i32_const = 116 },
            .{ .i32_const = 16 },  .{ .i32_const = 9 },       .{ .i64_const = 1000 },  atomic(0x01),           .{ .i32_store = m0 },  atomic(0x03),
        };
    var p = try runBody(a, &body, &.{});
    defer p.deinit();
    const expected = [_]u32{ 100, 105, 102, 6, 54, 201, 7, 9, 9, 0xFF, 0x01, 40, 1, 2 };
    for (expected, 0..) |want, i| try testing.expectEqual(want, word(&p, 64 + i * 4));
    try testing.expectEqual(@as(u32, 9), word(&p, 16));
    try testing.expectEqual(@as(u32, 0x155), word(&p, 32));
    try testing.expectEqual(Value{ .int64 = 1 << 40 }, p.global("__G__g0"));
    try testing.expectEqual(Value{ .int64 = (1 << 40) + 1 }, p.global("__G__g1"));
}

test "atomics on one thread: a wait nobody can end is a trap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]I{ .{ .i32_const = 16 }, .{ .i32_const = 0 }, .{ .i64_const = -1 }, atomic(0x01), .{ .global_set = 2 } };
    const mod = try simpleModule(a, &.{ .i64, .i64, .i32, .i32 }, &.{}, &body);
    var p = try load(mod, null);
    defer p.deinit();
    _ = try p.vm.runEvent("run");
    // The trap routine logs and ends the event; the result was never set.
    try testing.expectEqual(udon.vm.LogLevel.err, p.vm.logs.items[0].level);
    try testing.expectEqual(Value{ .int32 = 0 }, p.global("__G__g2"));
}

// ----------------------------------------------------------------------
//  Imports of a module with its own host (`__udon_meta.imports`)
// ----------------------------------------------------------------------

const host_types = [_]FuncType{
    void_type,
    .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} },
    .{ .params = &.{}, .results = &.{.i64} },
    .{ .params = &.{.i32}, .results = &.{.i32} },
    .{ .params = &.{.i32}, .results = &.{} },
};

const host_imports = [_]wasm.module.Import{
    .{ .module = "env", .name = "console_put", .desc = .{ .func = 1 } },
    .{ .module = "env", .name = "now", .desc = .{ .func = 2 } },
    .{ .module = "env", .name = "sys_frob", .desc = .{ .func = 3 } },
    .{ .module = "env", .name = "die", .desc = .{ .func = 4 } },
    .{ .module = "env", .name = "spawn", .desc = .{ .func = 1 } },
};

const host_meta: wasm.UdonMeta = .{
    .version = 1,
    .imports = &.{
        .{ .pattern = "env.console_put", .as = .write },
        .{ .pattern = "env.now", .as = .clock },
        .{ .pattern = "env.die", .as = .panic },
        .{ .pattern = "env.sys_*", .returns = -38 },
        // Whatever else the module wants from its host.
        .{ .pattern = "env.*", .as = .halt },
    },
};

fn hostModule(a: std.mem.Allocator, body: []const I) !wasm.Module {
    var mod = try simpleModule(a, &.{ .i64, .i64, .i32, .i32 }, &.{}, body);
    mod.types_ = &host_types;
    mod.imports = &host_imports;
    const exports = try a.dupe(wasm.module.Export, mod.exports);
    exports[exports.len - 1] = .{ .name = "run", .desc = .{ .func = host_imports.len } };
    mod.exports = exports;
    // The first line ends the way a console driver ends lines.
    const text = "boot: one\r\n" ++ "\x00" ** 5 ++ "partial" ++ "\x00" ** 9 ++ "Out of cheese\x00";
    mod.datas = try a.dupe(wasm.module.Data, &.{.{ .memory_index = 0, .offset = try a.dupe(I, &.{.{ .i32_const = 0 }}), .init = text }});
    return mod;
}

test "host imports bound by metadata: console, clock, constant answers, and a call nobody can serve" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]I{
        .{ .i32_const = 0 },  .{ .i32_const = 11 }, .{ .call = 0 },       .{ .global_set = 2 },
        .{ .call = 1 },       .{ .global_set = 0 }, .{ .i32_const = 1 },  .{ .call = 2 },
        .{ .global_set = 3 },
        // An unfinished line is shown before the event ends.
        .{ .i32_const = 16 }, .{ .i32_const = 7 },  .{ .call = 0 },
        .drop,                .{ .i32_const = 1 },  .{ .i32_const = 2 },  .{ .call = 4 },
        .drop,                .{ .i64_const = 99 }, .{ .global_set = 1 },
    };
    var p = try load(try hostModule(a, &body), host_meta);
    defer p.deinit();
    p.vm.host.time = 1.5;
    _ = try p.vm.runEvent("run");
    try testing.expectEqualStrings(
        "boot: one\npartial\nenv.spawn was called: this host does not have it, and the event ends here\n",
        try p.vm.logText(),
    );
    try testing.expectEqual(udon.vm.LogLevel.err, p.vm.logs.items[2].level);
    try testing.expectEqual(Value{ .int32 = 11 }, p.global("__G__g2"));
    try testing.expectEqual(Value{ .int64 = 1_500_000_000 }, p.global("__G__g0"));
    try testing.expectEqual(Value{ .int32 = -38 }, p.global("__G__g3"));
    try testing.expectEqual(Value{ .int64 = 0 }, p.global("__G__g1"));
}

test "host imports bound by metadata: a panic logs its C string and ends the event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]I{ .{ .i32_const = 32 }, .{ .call = 3 }, .{ .i64_const = 99 }, .{ .global_set = 1 } };
    var p = try load(try hostModule(a, &body), host_meta);
    defer p.deinit();
    _ = try p.vm.runEvent("run");
    try testing.expectEqualStrings("Out of cheese\n", try p.vm.logText());
    try testing.expectEqual(udon.vm.LogLevel.err, p.vm.logs.items[0].level);
    try testing.expectEqual(Value{ .int64 = 0 }, p.global("__G__g1"));
}

test "host imports bound by metadata: a type the host function does not have is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mod = try hostModule(a, &.{});
    var diag: translate_.Diagnostics = .init(a);
    var out: std.Io.Writer.Allocating = .init(a);
    const meta: wasm.UdonMeta = .{ .version = 1, .imports = &.{.{ .pattern = "env.now", .as = .write }} };
    try testing.expectError(error.Invalid, translate_.translate(testing.allocator, mod, meta, &out.writer, .{ .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message, "now") != null);
}

test "a string field backed by memory is written after the start function, with its terminator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m0 = wasm.instruction.MemArg{ .@"align" = 0, .offset = 0 };
    // The start function fills the buffer, as a module that sets up its
    // own data does; `run` reads the first byte and the one after the text.
    const fns = [_]Fn{
        .{ .ty = void_type, .body = &.{
            .{ .i32_const = 200 }, .{ .i32_load8_u = m0 }, .{ .global_set = 0 },
            .{ .i32_const = 211 }, .{ .i32_load8_u = m0 }, .{ .global_set = 1 },
            .{ .i32_const = 212 }, .{ .i32_load8_u = m0 }, .{ .global_set = 2 },
        } },
        .{ .ty = void_type, .body = &.{ .{ .i32_const = 200 }, .{ .i32_const = 0xEE }, .{ .i32_const = 32 }, .memory_fill } },
    };
    var mod = try callModule(a, &fns, &.{}, 1);
    const globals = try a.alloc(wasm.module.Global, mod.globals.len + 1);
    @memcpy(globals[0..mod.globals.len], mod.globals);
    globals[mod.globals.len] = .{ .ty = .{ .valtype = .i32, .mut = .immutable }, .init = try a.dupe(I, &.{.{ .i32_const = 200 }}) };
    const exports = try a.alloc(wasm.module.Export, mod.exports.len + 1);
    @memcpy(exports[0..mod.exports.len], mod.exports);
    exports[mod.exports.len] = .{ .name = "command_line", .desc = .{ .global = @intCast(mod.globals.len) } };
    mod.globals = globals;
    mod.exports = exports;
    const meta: wasm.UdonMeta = .{ .version = 1, .fields = &.{.{
        .key = "commandLine",
        .source = .{ .kind = .symbol, .name = "command_line" },
        .type_name = "SystemString",
        .default = .{ .string = "console=hvc" },
    }} };
    var p = try load(mod, meta);
    defer p.deinit();
    _ = try p.vm.runEvent("run");
    try testing.expectEqual(Value{ .int32 = 'c' }, p.global("__G__g0"));
    try testing.expectEqual(Value{ .int32 = 0 }, p.global("__G__g1"));
    try testing.expectEqual(Value{ .int32 = 0xEE }, p.global("__G__g2"));
}
