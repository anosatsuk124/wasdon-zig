//! Shared runtime routines.
//!
//! Operations that have no single Udon extern and are too long to expand at
//! every use site are emitted once and called like a function: arguments in
//! per-routine variables, a return-address constant in the routine's link
//! variable, the result in its result variable. Routines use only their own
//! variables and scratch, never a frame, so they are not reentrant — and
//! never need to be. Only routines the program actually uses are emitted.

const std = @import("std");
const wasm = @import("wasm");
const tr = @import("translate.zig");
const lower = @import("lower.zig");

const Translator = tr.Translator;
const Error = tr.Error;
const Var = tr.Var;
const Label = tr.Label;
const Class = tr.Class;
const ValType = wasm.types.ValType;
const opSig = lower.opSig;
const cmpSig = lower.cmpSig;
const shSig = lower.shSig;
const convSig = lower.convSig;
const mathSig = lower.mathSig;

pub const Routine = enum {
    trap_unreachable,
    memory_grow,
    memory_fill,
    clz32,
    ctz32,
    popcnt32,
    clz64,
    ctz64,
    popcnt64,
    div_u64,
    rem_u64,
    trunc_u64,
    trunc_sat_s64,
    trunc_sat_u64,
    u64_to_f64,

    pub const Spec = struct { params: []const ValType, result: ?ValType };

    pub fn spec(self: Routine) Spec {
        return switch (self) {
            .trap_unreachable => .{ .params = &.{}, .result = null },
            .memory_grow => .{ .params = &.{.i32}, .result = .i32 },
            .memory_fill => .{ .params = &.{ .i32, .i32, .i32 }, .result = null },
            .clz32, .ctz32, .popcnt32 => .{ .params = &.{.i32}, .result = .i32 },
            .clz64, .ctz64, .popcnt64 => .{ .params = &.{.i64}, .result = .i64 },
            .div_u64, .rem_u64 => .{ .params = &.{ .i64, .i64 }, .result = .i64 },
            .trunc_u64, .trunc_sat_s64, .trunc_sat_u64 => .{ .params = &.{.f64}, .result = .i64 },
            .u64_to_f64 => .{ .params = &.{.i64}, .result = .f64 },
        };
    }
};

pub const Routines = struct {
    labels: std.EnumArray(Routine, ?Label) = .initFill(null),
    emitted: std.EnumSet(Routine) = .initEmpty(),
};

/// Entry label of a routine; marks it for emission.
pub fn label(t: *Translator, r: Routine) Error!Label {
    if (t.rt.labels.get(r) == null) t.rt.labels.set(r, t.prog.newLabel());
    return t.rt.labels.get(r).?;
}

fn routineVar(t: *Translator, r: Routine, comptime suffix: []const u8, n: usize, class: Class) Error!Var {
    const name = try std.fmt.allocPrint(t.a, "__rt_{s}_" ++ suffix ++ "{d}", .{ @tagName(r), n });
    return t.named(name, class.udonType(), if (class == .i32) .{ .int = 0 } else if (class == .lr) .{ .uint = 0 } else .null_);
}

pub fn argVar(t: *Translator, r: Routine, i: usize) Error!Var {
    return routineVar(t, r, "a", i, Class.of(r.spec().params[i]));
}

pub fn resultVar(t: *Translator, r: Routine) Error!Var {
    return routineVar(t, r, "r", 0, Class.of(r.spec().result.?));
}

pub fn lrVar(t: *Translator, r: Routine) Error!Var {
    return routineVar(t, r, "lr", 0, .lr);
}

/// Emit every routine that was requested, including the ones other
/// routines turn out to need.
pub fn emit(t: *Translator) Error!void {
    var progress = true;
    while (progress) {
        progress = false;
        for (std.enums.values(Routine)) |r| {
            if (t.rt.labels.get(r) == null or t.rt.emitted.contains(r)) continue;
            t.rt.emitted.insert(r);
            progress = true;
            try t.comment("runtime: {s}", .{@tagName(r)});
            try t.place(t.rt.labels.get(r).?);
            var e: Emitter = .{ .t = t, .r = r };
            try e.body();
        }
    }
}

const Emitter = struct {
    t: *Translator,
    r: Routine,

    fn arg(self: Emitter, i: usize) Error!Var {
        return argVar(self.t, self.r, i);
    }

    fn result(self: Emitter) Error!Var {
        return resultVar(self.t, self.r);
    }

    /// Routine-private working variable.
    fn local(self: Emitter, class: Class, n: usize) Error!Var {
        return routineVar(self.t, self.r, "v", n, class);
    }

    fn flag(self: Emitter) Error!Var {
        return self.t.tmp(.bool, 0);
    }

    fn ret(self: Emitter) Error!void {
        try self.t.prog.emit(.{ .jump_indirect = try lrVar(self.t, self.r) });
    }

    /// `result = value; return`.
    fn retWith(self: Emitter, value: Var) Error!void {
        try self.t.copy(value, try self.result());
        try self.ret();
    }

    fn i32c(self: Emitter, v: i32) Error!Var {
        return self.t.constI32(v);
    }

    fn i64c(self: Emitter, v: i64) Error!Var {
        return self.t.constant(.i64_(v));
    }

    /// Call another routine: `dst = callee(args...)`.
    fn call(self: Emitter, callee: Routine, args: []const Var, dst: Var) Error!void {
        const t = self.t;
        for (args, 0..) |a, i| try t.copy(a, try argVar(t, callee, i));
        const back = t.prog.newLabel();
        try t.copy(try t.rac(back), try lrVar(t, callee));
        try t.jump(try label(t, callee));
        try t.place(back);
        try t.copy(try resultVar(t, callee), dst);
    }

    /// `dst = (int)(x >> 32)` — the arithmetic shift keeps it in range.
    fn high32(self: Emitter, x: Var, dst: Var) Error!void {
        const t = self.t;
        const wide = try t.tmp(.i64, 0);
        _ = try t.ext(shSig("Int64", "RightShift"), &.{ x, try self.i32c(32), wide });
        _ = try t.ext(convSig("Int64", "Int32"), &.{ wide, dst });
    }

    /// `dst = (int)x`, keeping the low 32 bits.
    fn low32(self: Emitter, x: Var, dst: Var) Error!void {
        const t = self.t;
        const wide = try t.tmp(.i64, 0);
        _ = try t.ext(shSig("Int64", "LeftShift"), &.{ x, try self.i32c(32), wide });
        _ = try t.ext(shSig("Int64", "RightShift"), &.{ wide, try self.i32c(32), wide });
        _ = try t.ext(convSig("Int64", "Int32"), &.{ wide, dst });
    }

    /// `dst = floor(log2(x))` for 0 < x < 2^31, read off the exponent of the
    /// exactly-converted double.
    fn log2(self: Emitter, x: Var, dst: Var) Error!void {
        const t = self.t;
        const d = try t.tmp(.f64, 0);
        const bits = try t.tmp(.i64, 0);
        _ = try t.ext(convSig("Int32", "Double"), &.{ x, d });
        _ = try t.ext("SystemBitConverter.__DoubleToInt64Bits__SystemDouble__SystemInt64", &.{ d, bits });
        _ = try t.ext(shSig("Int64", "RightShift"), &.{ bits, try self.i32c(52), bits });
        _ = try t.ext(convSig("Int64", "Int32"), &.{ bits, dst });
        _ = try t.ext(opSig("Int32", "Subtraction"), &.{ dst, try self.i32c(1023), dst });
    }

    /// Reinterpret between `SystemInt64` and `SystemUInt64` (slow path only).
    fn reinterpret(self: Emitter, comptime from: []const u8, comptime to: []const u8, x: Var, dst: Var) Error!void {
        const t = self.t;
        const bytes = try t.named("__rt_bytes", "SystemByteArray", .null_);
        _ = try t.ext("SystemBitConverter.__GetBytes__System" ++ from ++ "__SystemByteArray", &.{ x, bytes });
        _ = try t.ext("SystemBitConverter.__To" ++ to ++ "__SystemByteArray_SystemInt32__System" ++ to, &.{ bytes, try self.i32c(0), dst });
    }

    fn body(self: Emitter) Error!void {
        const t = self.t;
        switch (self.r) {
            .trap_unreachable => try t.trap("wasdon: unreachable executed"),

            .memory_grow => {
                // Reallocate and copy; -1 when the limit would be exceeded.
                const delta = try self.arg(0);
                const pages = try t.memPages();
                const memory = try t.mem();
                const fail = t.prog.newLabel();
                const room = try self.local(.i32, 0);
                const bytes = try self.local(.i32, 1);
                const grown = try t.named("__rt_grown", "SystemByteArray", .null_);
                _ = try t.ext(cmpSig("Int32", "GreaterThanOrEqual"), &.{ delta, try self.i32c(0), try self.flag() });
                try t.jif(try self.flag(), fail);
                _ = try t.ext(opSig("Int32", "Subtraction"), &.{ try t.memMaxPages(), pages, room });
                _ = try t.ext(cmpSig("Int32", "LessThanOrEqual"), &.{ delta, room, try self.flag() });
                try t.jif(try self.flag(), fail);
                try t.copy(pages, try self.result());
                _ = try t.ext(shSig("Int32", "LeftShift"), &.{ pages, try self.i32c(16), bytes });
                _ = try t.ext(opSig("Int32", "Addition"), &.{ pages, delta, pages });
                _ = try t.ext(shSig("Int32", "LeftShift"), &.{ pages, try self.i32c(16), room });
                _ = try t.ext("SystemByteArray.__ctor__SystemInt32__SystemByteArray", &.{ room, grown });
                _ = try t.ext(array_copy, &.{ memory, try self.i32c(0), grown, try self.i32c(0), bytes });
                try t.copy(grown, memory);
                try self.ret();
                try t.place(fail);
                try self.retWith(try self.i32c(-1));
            },

            .memory_fill => {
                // Write one byte, then double the filled prefix with Array.Copy.
                const dst = try self.arg(0);
                const value = try self.arg(1);
                const n = try self.arg(2);
                const memory = try t.mem();
                const done = t.prog.newLabel();
                const loop = t.prog.newLabel();
                const filled = try self.local(.i32, 0);
                const chunk = try self.local(.i32, 1);
                const to = try self.local(.i32, 2);
                const b = try t.box(.i32);
                _ = try t.ext(cmpSig("Int32", "GreaterThan"), &.{ n, try self.i32c(0), try self.flag() });
                try t.jif(try self.flag(), done);
                _ = try t.ext("SystemInt32Array.__Set__SystemInt32_SystemInt32__SystemVoid", &.{ b, try self.i32c(0), value });
                _ = try t.ext(block_copy, &.{ b, try self.i32c(0), memory, dst, try self.i32c(1) });
                try t.copy(try self.i32c(1), filled);
                try t.place(loop);
                _ = try t.ext(cmpSig("Int32", "LessThan"), &.{ filled, n, try self.flag() });
                try t.jif(try self.flag(), done);
                _ = try t.ext(opSig("Int32", "Subtraction"), &.{ n, filled, chunk });
                _ = try t.ext("SystemMath.__Min__SystemInt32_SystemInt32__SystemInt32", &.{ filled, chunk, chunk });
                _ = try t.ext(opSig("Int32", "Addition"), &.{ dst, filled, to });
                _ = try t.ext(array_copy, &.{ memory, dst, memory, to, chunk });
                _ = try t.ext(opSig("Int32", "Addition"), &.{ filled, chunk, filled });
                try t.jump(loop);
                try t.place(done);
                try self.ret();
            },

            .clz32 => {
                const x = try self.arg(0);
                const zero = t.prog.newLabel();
                const negative = t.prog.newLabel();
                _ = try t.ext(cmpSig("Int32", "Inequality"), &.{ x, try self.i32c(0), try self.flag() });
                try t.jif(try self.flag(), zero);
                _ = try t.ext(cmpSig("Int32", "GreaterThan"), &.{ x, try self.i32c(0), try self.flag() });
                try t.jif(try self.flag(), negative);
                try self.log2(x, try self.result());
                _ = try t.ext(opSig("Int32", "Subtraction"), &.{ try self.i32c(31), try self.result(), try self.result() });
                try self.ret();
                try t.place(zero);
                try self.retWith(try self.i32c(32));
                try t.place(negative);
                try self.retWith(try self.i32c(0));
            },

            .ctz32 => {
                const x = try self.arg(0);
                const zero = t.prog.newLabel();
                const top = t.prog.newLabel();
                const low = try self.local(.i32, 0);
                _ = try t.ext(cmpSig("Int32", "Inequality"), &.{ x, try self.i32c(0), try self.flag() });
                try t.jif(try self.flag(), zero);
                // x & -x isolates the lowest set bit.
                _ = try t.ext(opSig("Int32", "Subtraction"), &.{ try self.i32c(0), x, low });
                _ = try t.ext(opSig("Int32", "LogicalAnd"), &.{ x, low, low });
                _ = try t.ext(cmpSig("Int32", "GreaterThan"), &.{ low, try self.i32c(0), try self.flag() });
                try t.jif(try self.flag(), top);
                try self.log2(low, try self.result());
                try self.ret();
                try t.place(zero);
                try self.retWith(try self.i32c(32));
                try t.place(top);
                try self.retWith(try self.i32c(31));
            },

            .popcnt32 => {
                // Parallel bit count. The masks clear every bit an arithmetic
                // shift could smear, so signed shifts are safe.
                const x = try self.arg(0);
                const s = try self.local(.i32, 0);
                const and_ = opSig("Int32", "LogicalAnd");
                const add = opSig("Int32", "Addition");
                const shr = shSig("Int32", "RightShift");
                _ = try t.ext(shr, &.{ x, try self.i32c(1), s });
                _ = try t.ext(and_, &.{ s, try self.i32c(0x55555555), s });
                _ = try t.ext(opSig("Int32", "Subtraction"), &.{ x, s, x });
                _ = try t.ext(shr, &.{ x, try self.i32c(2), s });
                _ = try t.ext(and_, &.{ s, try self.i32c(0x33333333), s });
                _ = try t.ext(and_, &.{ x, try self.i32c(0x33333333), x });
                _ = try t.ext(add, &.{ x, s, x });
                _ = try t.ext(shr, &.{ x, try self.i32c(4), s });
                _ = try t.ext(add, &.{ x, s, x });
                _ = try t.ext(and_, &.{ x, try self.i32c(0x0F0F0F0F), x });
                _ = try t.ext(opSig("Int32", "Multiplication"), &.{ x, try self.i32c(0x01010101), x });
                _ = try t.ext(shr, &.{ x, try self.i32c(24), try self.result() });
                try self.ret();
            },

            .clz64, .ctz64 => {
                // Examine the significant half first; fall back to the other.
                const x = try self.arg(0);
                const half = try self.local(.i32, 0);
                const count = try self.local(.i32, 1);
                const other = t.prog.newLabel();
                const done = t.prog.newLabel();
                const narrow: Routine = if (self.r == .clz64) .clz32 else .ctz32;
                if (self.r == .clz64) try self.high32(x, half) else try self.low32(x, half);
                _ = try t.ext(cmpSig("Int32", "Inequality"), &.{ half, try self.i32c(0), try self.flag() });
                try t.jif(try self.flag(), other);
                try self.call(narrow, &.{half}, count);
                try t.jump(done);
                try t.place(other);
                if (self.r == .clz64) try self.low32(x, half) else try self.high32(x, half);
                try self.call(narrow, &.{half}, count);
                _ = try t.ext(opSig("Int32", "Addition"), &.{ count, try self.i32c(32), count });
                try t.place(done);
                _ = try t.ext(convSig("Int32", "Int64"), &.{ count, try self.result() });
                try self.ret();
            },

            .popcnt64 => {
                const x = try self.arg(0);
                const half = try self.local(.i32, 0);
                const low = try self.local(.i32, 1);
                const high = try self.local(.i32, 2);
                try self.low32(x, half);
                try self.call(.popcnt32, &.{half}, low);
                try self.high32(x, half);
                try self.call(.popcnt32, &.{half}, high);
                _ = try t.ext(opSig("Int32", "Addition"), &.{ low, high, low });
                _ = try t.ext(convSig("Int32", "Int64"), &.{ low, try self.result() });
                try self.ret();
            },

            .div_u64, .rem_u64 => {
                const a = try self.arg(0);
                const b = try self.arg(1);
                const slow = t.prog.newLabel();
                const scratch = try t.tmp(.i64, 0);
                // Both operands below 2^63: the signed operation is exact.
                _ = try t.ext(opSig("Int64", "LogicalOr"), &.{ a, b, scratch });
                _ = try t.ext(cmpSig("Int64", "GreaterThanOrEqual"), &.{ scratch, try self.i64c(0), try self.flag() });
                try t.jif(try self.flag(), slow);
                if (self.r == .div_u64) {
                    _ = try t.ext(opSig("Int64", "Division"), &.{ a, b, try self.result() });
                } else {
                    _ = try t.ext(div_rem_64, &.{ a, b, try self.result(), scratch });
                }
                try self.ret();
                try t.place(slow);
                const ua = try t.named("__rt_u64_0", "SystemUInt64", .null_);
                const ub = try t.named("__rt_u64_1", "SystemUInt64", .null_);
                const uq = try t.named("__rt_u64_2", "SystemUInt64", .null_);
                try self.reinterpret("Int64", "UInt64", a, ua);
                try self.reinterpret("Int64", "UInt64", b, ub);
                _ = try t.ext(opSig("UInt64", "Division"), &.{ ua, ub, uq });
                if (self.r == .rem_u64) {
                    // No UInt64 remainder node: a - (a / b) * b.
                    _ = try t.ext(opSig("UInt64", "Multiplication"), &.{ uq, ub, uq });
                    _ = try t.ext(opSig("UInt64", "Subtraction"), &.{ ua, uq, uq });
                }
                try self.reinterpret("UInt64", "Int64", uq, try self.result());
                try self.ret();
            },

            .trunc_u64, .trunc_sat_u64, .trunc_sat_s64 => {
                const x = try self.arg(0);
                const d = try self.local(.f64, 0);
                const two63 = try t.constF64(9223372036854775808.0);
                const lt = cmpSig("Double", "LessThan");
                const to_i64 = convSig("Double", "Int64");
                const zero = t.prog.newLabel();
                const max = t.prog.newLabel();
                const big = t.prog.newLabel();
                const saturating = self.r != .trunc_u64;
                if (saturating) {
                    // NaN is the only value unequal to itself.
                    _ = try t.ext(cmpSig("Double", "Equality"), &.{ x, x, try self.flag() });
                    try t.jif(try self.flag(), zero);
                }
                _ = try t.ext(mathSig("Truncate", "Double"), &.{ x, d });
                if (self.r == .trunc_sat_s64) {
                    const min = t.prog.newLabel();
                    _ = try t.ext(lt, &.{ d, two63, try self.flag() });
                    try t.jif(try self.flag(), max);
                    _ = try t.ext(cmpSig("Double", "GreaterThanOrEqual"), &.{ d, try t.constF64(-9223372036854775808.0), try self.flag() });
                    try t.jif(try self.flag(), min);
                    _ = try t.ext(to_i64, &.{ d, try self.result() });
                    try self.ret();
                    try t.place(min);
                    try self.retWith(try self.i64c(std.math.minInt(i64)));
                    try t.place(max);
                    try self.retWith(try self.i64c(std.math.maxInt(i64)));
                } else {
                    if (saturating) {
                        _ = try t.ext(cmpSig("Double", "GreaterThan"), &.{ d, try t.constF64(0.0), try self.flag() });
                        try t.jif(try self.flag(), zero);
                        _ = try t.ext(lt, &.{ d, try t.constF64(18446744073709551616.0), try self.flag() });
                        try t.jif(try self.flag(), max);
                    }
                    _ = try t.ext(lt, &.{ d, two63, try self.flag() });
                    try t.jif(try self.flag(), big);
                    _ = try t.ext(to_i64, &.{ d, try self.result() });
                    try self.ret();
                    // [2^63, 2^64): convert the excess and set the top bit.
                    try t.place(big);
                    _ = try t.ext(opSig("Double", "Subtraction"), &.{ d, two63, d });
                    _ = try t.ext(to_i64, &.{ d, try self.result() });
                    _ = try t.ext(opSig("Int64", "LogicalXor"), &.{ try self.result(), try self.i64c(std.math.minInt(i64)), try self.result() });
                    try self.ret();
                    if (saturating) {
                        try t.place(max);
                        try self.retWith(try self.i64c(-1));
                    }
                }
                if (saturating) {
                    try t.place(zero);
                    try self.retWith(try self.i64c(0));
                }
            },

            .u64_to_f64 => {
                const x = try self.arg(0);
                const negative = t.prog.newLabel();
                const half = try self.local(.i64, 0);
                const odd = try self.local(.i64, 1);
                const to_f64 = convSig("Int64", "Double");
                _ = try t.ext(cmpSig("Int64", "GreaterThanOrEqual"), &.{ x, try self.i64c(0), try self.flag() });
                try t.jif(try self.flag(), negative);
                _ = try t.ext(to_f64, &.{ x, try self.result() });
                try self.ret();
                // Top bit set: halve (keeping the lost bit sticky for
                // rounding), convert, double.
                try t.place(negative);
                _ = try t.ext(shSig("Int64", "RightShift"), &.{ x, try self.i32c(1), half });
                _ = try t.ext(opSig("Int64", "LogicalAnd"), &.{ half, try self.i64c(std.math.maxInt(i64)), half });
                _ = try t.ext(opSig("Int64", "LogicalAnd"), &.{ x, try self.i64c(1), odd });
                _ = try t.ext(opSig("Int64", "LogicalOr"), &.{ half, odd, half });
                _ = try t.ext(to_f64, &.{ half, try self.result() });
                _ = try t.ext(opSig("Double", "Addition"), &.{ try self.result(), try self.result(), try self.result() });
                try self.ret();
            },
        }
    }
};

const block_copy = "SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid";
const array_copy = "SystemArray.__Copy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid";
const div_rem_64 = "SystemMath.__DivRem__SystemInt64_SystemInt64_SystemInt64Ref__SystemInt64";
