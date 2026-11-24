//! Differential tests for every numeric WASM instruction.
//!
//! For each instruction a module is assembled that applies it to a grid of
//! interesting operands — once with constant operands, once through locals,
//! and for comparisons also through `if` and `i32.eqz` — and logs each
//! result. The module is translated, checked and run in the Udon emulator,
//! and every logged value is compared with a reference implementation of
//! the WASM semantics below.
//!
//! Inputs that trap in WASM are skipped, as are the two documented
//! deviations (`docs/spec_numeric_conversion.md`): `rem_s(MIN, -1)` and
//! `min`/`max` on zeros of opposite sign.

const std = @import("std");
const wasdon = @import("wasdon_zig");
const builder = @import("wasm_builder.zig");
const e2e = @import("e2e.zig");

const testing = std.testing;
const ValType = builder.ValType;
const Tag = std.meta.Tag(wasdon.wasm.Instruction);

const Outcome = union(enum) { value: u64, trap, skip };

const Info = struct {
    in: []const ValType,
    out: ValType,
};

fn valType(comptime prefix: []const u8) ?ValType {
    inline for (.{ "i32", "i64", "f32", "f64" }, .{ ValType.i32, ValType.i64, ValType.f32, ValType.f64 }) |name, ty| {
        if (std.mem.eql(u8, prefix, name)) return ty;
    }
    return null;
}

fn has(comptime list: []const []const u8, comptime name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

const int_binary = [_][]const u8{ "add", "sub", "mul", "div_s", "div_u", "rem_s", "rem_u", "and", "or", "xor", "shl", "shr_s", "shr_u", "rotl", "rotr" };
const int_compare = [_][]const u8{ "eq", "ne", "lt_s", "lt_u", "gt_s", "gt_u", "le_s", "le_u", "ge_s", "ge_u" };
const int_unary = [_][]const u8{ "clz", "ctz", "popcnt", "extend8_s", "extend16_s", "extend32_s" };
const float_binary = [_][]const u8{ "add", "sub", "mul", "div", "min", "max", "copysign" };
const float_compare = [_][]const u8{ "eq", "ne", "lt", "gt", "le", "ge" };
const float_unary = [_][]const u8{ "abs", "neg", "ceil", "floor", "trunc", "nearest", "sqrt" };

/// Operand and result types of a numeric instruction, from its name.
fn info(comptime name: []const u8) ?Info {
    @setEvalBranchQuota(100_000);
    if (name.len < 5 or name[3] != '_') return null;
    const ty = valType(name[0..3]) orelse return null;
    const op = name[4..];
    const is_int = name[0] == 'i';
    const one: []const ValType = &.{ty};
    const two: []const ValType = &.{ ty, ty };
    if (is_int) {
        if (has(&int_binary, op)) return .{ .in = two, .out = ty };
        if (has(&int_compare, op)) return .{ .in = two, .out = .i32 };
        if (has(&int_unary, op)) return .{ .in = one, .out = ty };
        if (std.mem.eql(u8, op, "eqz")) return .{ .in = one, .out = .i32 };
    } else {
        if (has(&float_binary, op)) return .{ .in = two, .out = ty };
        if (has(&float_compare, op)) return .{ .in = two, .out = .i32 };
        if (has(&float_unary, op)) return .{ .in = one, .out = ty };
    }
    // Conversions: <to>_<verb>_<from>[_s|_u].
    for ([_][]const u8{ "wrap_", "extend_", "trunc_sat_", "trunc_", "convert_", "demote_", "promote_", "reinterpret_" }) |verb| {
        if (!std.mem.startsWith(u8, op, verb)) continue;
        const from = valType(op[verb.len..][0..3]) orelse return null;
        return .{ .in = &.{from}, .out = ty };
    }
    return null;
}

fn Float(comptime ty: ValType) type {
    return if (ty == .f32) f32 else f64;
}

fn floatFrom(comptime F: type, bits: u64) F {
    return if (F == f32) @bitCast(@as(u32, @truncate(bits))) else @bitCast(bits);
}

fn floatBits(x: anytype) u64 {
    return if (@TypeOf(x) == f32) @as(u32, @bitCast(x)) else @bitCast(x);
}

fn nearest(x: anytype) @TypeOf(x) {
    if (@abs(x - @trunc(x)) == 0.5) return 2 * @round(x / 2);
    return @round(x);
}

fn boolean(b: bool) Outcome {
    return .{ .value = @intFromBool(b) };
}

/// Reference semantics (WebAssembly core specification, numerics).
fn eval(comptime name: []const u8, x: u64, y: u64) Outcome {
    const op = name[4..];
    const eq = std.mem.eql;
    if (name[0] == 'i' and (comptime (has(&int_binary, op) or has(&int_compare, op) or has(&int_unary, op) or eq(u8, op, "eqz")))) {
        const S = if (name[1] == '3') i32 else i64;
        const U = if (name[1] == '3') u32 else u64;
        const ua: U = @truncate(x);
        const ub: U = @truncate(y);
        const a: S = @bitCast(ua);
        const b: S = @bitCast(ub);
        const count: std.math.Log2Int(U) = @truncate(ub);
        const r: U = if (comptime eq(u8, op, "add")) ua +% ub //
        else if (comptime eq(u8, op, "sub")) ua -% ub //
        else if (comptime eq(u8, op, "mul")) ua *% ub //
        else if (comptime eq(u8, op, "div_s")) blk: {
            if (b == 0 or (a == std.math.minInt(S) and b == -1)) return .trap;
            break :blk @bitCast(@divTrunc(a, b));
        } else if (comptime eq(u8, op, "div_u")) blk: {
            if (ub == 0) return .trap;
            break :blk ua / ub;
        } else if (comptime eq(u8, op, "rem_s")) blk: {
            if (b == 0) return .trap;
            if (a == std.math.minInt(S) and b == -1) return .skip; // .NET throws here
            break :blk @bitCast(@rem(a, b));
        } else if (comptime eq(u8, op, "rem_u")) blk: {
            if (ub == 0) return .trap;
            break :blk ua % ub;
        } else if (comptime eq(u8, op, "and")) ua & ub //
        else if (comptime eq(u8, op, "or")) ua | ub //
        else if (comptime eq(u8, op, "xor")) ua ^ ub //
        else if (comptime eq(u8, op, "shl")) ua << count //
        else if (comptime eq(u8, op, "shr_s")) @bitCast(a >> count) //
            else if (comptime eq(u8, op, "shr_u")) ua >> count //
            else if (comptime eq(u8, op, "rotl")) std.math.rotl(U, ua, count) //
            else if (comptime eq(u8, op, "rotr")) std.math.rotr(U, ua, count) //
            else if (comptime eq(u8, op, "clz")) @clz(ua) //
            else if (comptime eq(u8, op, "ctz")) @ctz(ua) //
            else if (comptime eq(u8, op, "popcnt")) @popCount(ua) //
            else if (comptime eq(u8, op, "extend8_s")) @bitCast(@as(S, @as(i8, @truncate(a)))) //
            else if (comptime eq(u8, op, "extend16_s")) @bitCast(@as(S, @as(i16, @truncate(a)))) //
            else if (comptime eq(u8, op, "extend32_s")) @bitCast(@as(S, @as(i32, @truncate(a)))) //
            else if (comptime eq(u8, op, "eqz")) return boolean(ua == 0) //
            else if (comptime eq(u8, op, "eq")) return boolean(ua == ub) //
            else if (comptime eq(u8, op, "ne")) return boolean(ua != ub) //
            else if (comptime eq(u8, op, "lt_s")) return boolean(a < b) //
            else if (comptime eq(u8, op, "lt_u")) return boolean(ua < ub) //
            else if (comptime eq(u8, op, "gt_s")) return boolean(a > b) //
            else if (comptime eq(u8, op, "gt_u")) return boolean(ua > ub) //
            else if (comptime eq(u8, op, "le_s")) return boolean(a <= b) //
            else if (comptime eq(u8, op, "le_u")) return boolean(ua <= ub) //
            else if (comptime eq(u8, op, "ge_s")) return boolean(a >= b) //
            else if (comptime eq(u8, op, "ge_u")) return boolean(ua >= ub) //
            else comptime unreachable;
        return .{ .value = r };
    }
    if (name[0] == 'f' and (comptime (has(&float_binary, op) or has(&float_compare, op) or has(&float_unary, op)))) {
        const F = if (name[1] == '3') f32 else f64;
        const a = floatFrom(F, x);
        const b = floatFrom(F, y);
        const nan = std.math.nan(F);
        const r: F = if (comptime eq(u8, op, "add")) a + b //
        else if (comptime eq(u8, op, "sub")) a - b //
        else if (comptime eq(u8, op, "mul")) a * b //
        else if (comptime eq(u8, op, "div")) a / b //
        else if (comptime (eq(u8, op, "min") or eq(u8, op, "max"))) blk: {
            if (std.math.isNan(a) or std.math.isNan(b)) break :blk nan;
            // Mono's Math.Min/Max does not order -0 below +0.
            if (a == 0 and b == 0 and std.math.signbit(a) != std.math.signbit(b)) return .skip;
            break :blk if (comptime eq(u8, op, "min")) @min(a, b) else @max(a, b);
        } else if (comptime eq(u8, op, "copysign")) std.math.copysign(a, b) //
            else if (comptime eq(u8, op, "abs")) @abs(a) //
            else if (comptime eq(u8, op, "neg")) -a //
            else if (comptime eq(u8, op, "ceil")) @ceil(a) //
            else if (comptime eq(u8, op, "floor")) @floor(a) //
            else if (comptime eq(u8, op, "trunc")) @trunc(a) //
            else if (comptime eq(u8, op, "nearest")) nearest(a) //
            else if (comptime eq(u8, op, "sqrt")) @sqrt(a) //
            else if (comptime eq(u8, op, "eq")) return boolean(a == b) //
            else if (comptime eq(u8, op, "ne")) return boolean(a != b) //
            else if (comptime eq(u8, op, "lt")) return boolean(a < b) //
            else if (comptime eq(u8, op, "gt")) return boolean(a > b) //
            else if (comptime eq(u8, op, "le")) return boolean(a <= b) //
            else if (comptime eq(u8, op, "ge")) return boolean(a >= b) //
            else comptime unreachable;
        return .{ .value = floatBits(r) };
    }
    return evalConversion(name, x);
}

fn evalConversion(comptime name: []const u8, x: u64) Outcome {
    const i = comptime info(name).?;
    const from = i.in[0];
    const op = name[4..];
    const starts = std.mem.startsWith;
    const signed = name[name.len - 1] == 's';
    if (comptime starts(u8, op, "wrap_")) return .{ .value = x & 0xFFFF_FFFF };
    if (comptime starts(u8, op, "extend_")) {
        const v: u32 = @truncate(x);
        return .{ .value = if (signed) @bitCast(@as(i64, @as(i32, @bitCast(v)))) else v };
    }
    if (comptime starts(u8, op, "reinterpret_")) return .{ .value = x };
    if (comptime starts(u8, op, "demote_")) return .{ .value = floatBits(@as(f32, @floatCast(floatFrom(f64, x)))) };
    if (comptime starts(u8, op, "promote_")) return .{ .value = floatBits(@as(f64, floatFrom(f32, x))) };
    if (comptime starts(u8, op, "convert_")) {
        const F = Float(i.out);
        const r: F = switch (from) {
            .i32 => if (signed) @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(x))))) else @floatFromInt(@as(u32, @truncate(x))),
            .i64 => if (signed) @floatFromInt(@as(i64, @bitCast(x))) else @floatFromInt(x),
            else => comptime unreachable,
        };
        return .{ .value = floatBits(r) };
    }
    // trunc / trunc_sat: float → integer.
    const saturating = comptime starts(u8, op, "trunc_sat_");
    const d: f64 = floatFrom(Float(from), x);
    const T = switch (i.out) {
        .i32 => if (signed) i32 else u32,
        .i64 => if (signed) i64 else u64,
        else => comptime unreachable,
    };
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T)); // rounds up to 2^n for 64-bit
    const t = @trunc(d);
    const in_range = t >= lo and (if (@bitSizeOf(T) == 64) t < hi else t <= hi);
    const r: T = if (in_range)
        @intFromFloat(t)
    else if (!saturating)
        return .trap
    else if (std.math.isNan(d))
        0
    else if (d < 0)
        std.math.minInt(T)
    else
        std.math.maxInt(T);
    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    return .{ .value = @as(U, @bitCast(r)) };
}

fn inputs(ty: ValType) []const u64 {
    const f = struct {
        fn s(v: f32) u64 {
            return @as(u32, @bitCast(v));
        }
        fn d(v: f64) u64 {
            return @bitCast(v);
        }
        fn i(v: i32) u64 {
            return @as(u32, @bitCast(v));
        }
        fn l(v: i64) u64 {
            return @bitCast(v);
        }
    };
    return switch (ty) {
        .i32 => &.{ f.i(0), f.i(1), f.i(-1), f.i(2), f.i(7), f.i(-7), f.i(31), f.i(33), f.i(255), f.i(0x10000), f.i(0x7FFFFFFF), f.i(-0x80000000), f.i(0x12345678), f.i(-0x7FFFFFFF), f.i(1000000007), f.i(-0x40000000) },
        .i64 => &.{ f.l(0), f.l(1), f.l(-1), f.l(2), f.l(7), f.l(-7), f.l(63), f.l(65), f.l(0xFFFFFFFF), f.l(0x100000000), f.l(0x7FFFFFFFFFFFFFFF), f.l(-0x8000000000000000), f.l(0x123456789ABCDEF0), f.l(-0x100000000), f.l(1000000007), f.l(-0x7FFFFFFFFFFFFFFF) },
        .f32 => &.{ f.s(0.0), f.s(-0.0), f.s(1.0), f.s(-1.0), f.s(1.5), f.s(-1.5), f.s(2.5), f.s(0.5), f.s(-0.5), f.s(3.75), f.s(100.25), f.s(1.0e10), f.s(-1.0e10), f.s(3.0e9), f.s(1.0e20), f.s(std.math.inf(f32)), f.s(-std.math.inf(f32)), f.s(std.math.nan(f32)), f.s(1.0e-10), f.s(-2147483648.0), f.s(2147483520.0), f.s(1.8e19) },
        .f64 => &.{ f.d(0.0), f.d(-0.0), f.d(1.0), f.d(-1.0), f.d(1.5), f.d(-1.5), f.d(2.5), f.d(0.5), f.d(-0.5), f.d(3.75), f.d(100.25), f.d(1.0e10), f.d(-1.0e10), f.d(3.0e9), f.d(1.0e20), f.d(std.math.inf(f64)), f.d(-std.math.inf(f64)), f.d(std.math.nan(f64)), f.d(1.0e-10), f.d(-2147483648.9), f.d(2147483647.9), f.d(4294967295.9), f.d(-0.9), f.d(9.2e18), f.d(1.8e19), f.d(1.0e300), f.d(0.1) },
    };
}

/// First of the two scratch locals of each type.
fn localBase(ty: ValType) u32 {
    return switch (ty) {
        .i32 => 0,
        .i64 => 2,
        .f32 => 4,
        .f64 => 6,
    };
}

fn logFunc(ty: ValType) u32 {
    return switch (ty) {
        .i32 => 0,
        .i64 => 1,
        .f32 => 2,
        .f64 => 3,
    };
}

const Expected = struct { ty: ValType, bits: u64, x: u64, y: u64, form: []const u8 };

fn check(expected: Expected, line: []const u8) !void {
    var buf: [512]u8 = undefined;
    const ok = switch (expected.ty) {
        .i32 => std.mem.eql(u8, line, try std.fmt.bufPrint(&buf, "{d}", .{@as(i32, @bitCast(@as(u32, @truncate(expected.bits))))})),
        .i64 => std.mem.eql(u8, line, try std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @bitCast(expected.bits))})),
        inline .f32, .f64 => |ty| blk: {
            const v = floatFrom(Float(ty), expected.bits);
            if (std.math.isNan(v)) break :blk std.mem.endsWith(u8, line, "nan");
            break :blk std.mem.eql(u8, line, try std.fmt.bufPrint(&buf, "{d}", .{v}));
        },
    };
    if (ok) return;
    std.debug.print("  operands 0x{x}, 0x{x} ({s} form): expected bits 0x{x}, got {s}\n", .{ expected.x, expected.y, expected.form, expected.bits, line });
    return error.WrongResult;
}

fn testOp(comptime tag: Tag) !void {
    const name = @tagName(tag);
    const op = comptime info(name) orelse return;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m: builder.Module = .{ .a = a };
    for ([_]ValType{ .i32, .i64, .f32, .f64 }) |ty| {
        _ = try m.addImport("UnityEngineDebug.__Log__SystemObject__SystemVoid", .{ .params = &.{ty} });
    }
    var c = m.code();
    var expected: std.ArrayList(Expected) = .empty;
    const is_test = comptime (std.mem.eql(u8, name[4..], "eqz") or if (name[0] == 'i') has(&int_compare, name[4..]) else has(&float_compare, name[4..]));

    const ys: []const u64 = if (op.in.len == 2) inputs(op.in[1]) else &.{0};
    for (inputs(op.in[0])) |x| for (ys) |y| {
        const want = switch (eval(name, x, y)) {
            .value => |v| v,
            .trap, .skip => continue,
        };
        const operands = [_]u64{ x, y };
        // Constant operands.
        for (op.in, operands[0..op.in.len]) |ty, v| try c.constBits(ty, v);
        try c.opTag(tag);
        try c.idx("call", logFunc(op.out));
        try expected.append(a, .{ .ty = op.out, .bits = want, .x = x, .y = y, .form = "constant" });
        // Operands in locals.
        for (op.in, operands[0..op.in.len], 0..) |ty, v, i| {
            try c.constBits(ty, v);
            try c.idx("local_set", localBase(ty) + @as(u32, @intCast(i)));
        }
        for (op.in, 0..) |ty, i| try c.idx("local_get", localBase(ty) + @as(u32, @intCast(i)));
        try c.opTag(tag);
        try c.idx("call", logFunc(op.out));
        try expected.append(a, .{ .ty = op.out, .bits = want, .x = x, .y = y, .form = "local" });
        if (!is_test) continue;
        // Comparison consumed by `if`, and negated by `i32.eqz`.
        for (op.in, 0..) |ty, i| try c.idx("local_get", localBase(ty) + @as(u32, @intCast(i)));
        try c.opTag(tag);
        try c.begin("if_", .i32);
        try c.i32c(1);
        try c.else_();
        try c.i32c(0);
        try c.end();
        try c.idx("call", logFunc(.i32));
        try expected.append(a, .{ .ty = .i32, .bits = want, .x = x, .y = y, .form = "if" });
        for (op.in, 0..) |ty, i| try c.idx("local_get", localBase(ty) + @as(u32, @intCast(i)));
        try c.opTag(tag);
        try c.op("i32_eqz");
        try c.idx("call", logFunc(.i32));
        try expected.append(a, .{ .ty = .i32, .bits = want ^ 1, .x = x, .y = y, .form = "eqz" });
    };
    const start = try m.addFunc(.{}, &.{ .i32, .i32, .i64, .i64, .f32, .f32, .f64, .f64 }, &c);
    try m.exportFunc("_start", start);

    errdefer std.debug.print("instruction {s} failed\n", .{name});
    const log = try e2e.run(a, try m.build(), "_start", .{});
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    for (expected.items) |want| try check(want, lines.next() orelse return error.MissingOutput);
    try testing.expect(lines.next() == null);
}

test "every numeric instruction matches the WASM semantics" {
    @setEvalBranchQuota(1_000_000);
    var count: usize = 0;
    inline for (@typeInfo(Tag).@"enum".fields) |field| {
        if (comptime info(field.name) != null) {
            try testOp(@field(Tag, field.name));
            count += 1;
        }
    }
    // 2 * (15 binary + 10 compare + eqz + 3 count) + 5 sign-extension,
    // 2 * (7 + 6 + 7) float, 25 MVP conversions, 8 saturating.
    try testing.expectEqual(@as(usize, 2 * 29 + 5 + 2 * 20 + 25 + 8), count);
}
