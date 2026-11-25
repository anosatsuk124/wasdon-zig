//! Extern implementations for the emulator.
//!
//! `lookup` maps an extern signature to a native implementation with .NET
//! semantics (unchecked integer arithmetic, checked `System.Convert`,
//! banker's rounding, …). `dynamicCall` is the fallback for Unity/VRChat
//! members without one: property getters/setters on a per-object property
//! bag, array element access for any element type, and a call log for the
//! rest.
//!
//! Implementations are plain Zig functions; `wrap` derives the argument
//! marshalling from their signatures. A leading `*Vm` parameter is passed
//! through; a non-void result is written to the trailing heap index, exactly
//! as Udon passes return slots (`docs/udon_specs.md` §6.2.6).

const std = @import("std");
const vm_mod = @import("vm.zig");
const value = @import("value.zig");

const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const Value = value.Value;
const Array = value.Array;
const Object = value.Object;
const Vector3 = vm_mod.Vector3;
const Vector2 = vm_mod.Vector2;
const Quaternion = vm_mod.Quaternion;
const Color = vm_mod.Color;
const Color32 = vm_mod.Color32;
const Char = vm_mod.Char;

pub const Fn = *const fn (vm: *Vm, args: []const u32) Error!void;
pub const Impl = struct { func: Fn, argc: u8 };

const KV = struct { []const u8, Impl };

pub fn lookup(sig: []const u8) ?Impl {
    return registry.get(sig);
}

fn wrap(comptime f: anytype) Impl {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const skip: usize = if (info.params.len > 0 and info.params[0].type.? == *Vm) 1 else 0;
    const n_in = info.params.len - skip;
    const Ret = info.return_type.?;
    const Payload = switch (@typeInfo(Ret)) {
        .error_union => |eu| eu.payload,
        else => Ret,
    };
    const S = struct {
        fn call(vm: *Vm, a: []const u32) Error!void {
            var t: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
            if (skip == 1) t[0] = vm;
            inline for (0..n_in) |k| t[k + skip] = try vm.get(info.params[k + skip].type.?, a[k]);
            const r = @call(.auto, f, t);
            const v = if (@typeInfo(Ret) == .error_union) try r else r;
            if (Payload != void) vm.set(a[n_in], v);
        }
    };
    return .{ .func = S.call, .argc = @intCast(n_in + @intFromBool(Payload != void)) };
}

fn raw(comptime argc: u8, comptime f: Fn) Impl {
    return .{ .func = f, .argc = argc };
}

// ----------------------------------------------------------------------
//  Numeric primitives
// ----------------------------------------------------------------------

const NumType = struct { name: []const u8, T: type };
const num_types = [_]NumType{
    .{ .name = "SystemInt32", .T = i32 },  .{ .name = "SystemUInt32", .T = u32 },
    .{ .name = "SystemInt64", .T = i64 },  .{ .name = "SystemUInt64", .T = u64 },
    .{ .name = "SystemSingle", .T = f32 }, .{ .name = "SystemDouble", .T = f64 },
    .{ .name = "SystemByte", .T = u8 },    .{ .name = "SystemSByte", .T = i8 },
    .{ .name = "SystemInt16", .T = i16 },  .{ .name = "SystemUInt16", .T = u16 },
};

fn isInt(comptime T: type) bool {
    return @typeInfo(T) == .int;
}

fn Num(comptime T: type) type {
    return struct {
        const int = isInt(T);
        const Shift = if (int) std.math.Log2Int(T) else u0;

        fn add(a: T, b: T) T {
            return if (int) a +% b else a + b;
        }
        fn sub(a: T, b: T) T {
            return if (int) a -% b else a - b;
        }
        fn mul(a: T, b: T) T {
            return if (int) a *% b else a * b;
        }
        fn div(vm: *Vm, a: T, b: T) Error!T {
            if (!int) return a / b;
            if (b == 0) return vm.raise("DivideByZeroException", .{});
            if (@typeInfo(T).int.signedness == .signed and a == std.math.minInt(T) and b == -1)
                return vm.raise("OverflowException: {d} / -1", .{a});
            return @divTrunc(a, b);
        }
        fn rem(vm: *Vm, a: T, b: T) Error!T {
            if (!int) return @rem(a, b);
            if (b == 0) return vm.raise("DivideByZeroException", .{});
            if (@typeInfo(T).int.signedness == .signed and a == std.math.minInt(T) and b == -1)
                return vm.raise("OverflowException: {d} % -1", .{a});
            return @rem(a, b);
        }
        fn band(a: T, b: T) T {
            return a & b;
        }
        fn bor(a: T, b: T) T {
            return a | b;
        }
        fn bxor(a: T, b: T) T {
            return a ^ b;
        }
        // C# masks the shift count to the operand width.
        fn shl(a: T, n: i32) T {
            return a << @as(Shift, @truncate(@as(u32, @bitCast(n))));
        }
        fn shr(a: T, n: i32) T {
            return a >> @as(Shift, @truncate(@as(u32, @bitCast(n))));
        }
        fn neg(a: T) T {
            return if (int) 0 -% a else -a;
        }
        fn eq(a: T, b: T) bool {
            return a == b;
        }
        fn ne(a: T, b: T) bool {
            return a != b;
        }
        fn lt(a: T, b: T) bool {
            return a < b;
        }
        fn le(a: T, b: T) bool {
            return a <= b;
        }
        fn gt(a: T, b: T) bool {
            return a > b;
        }
        fn ge(a: T, b: T) bool {
            return a >= b;
        }
        fn toString(vm: *Vm, a: T) Error![]const u8 {
            return vm.fmt("{d}", .{a});
        }
        fn hash(a: T) i32 {
            if (!int) {
                const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                return foldHash(@as(U, @bitCast(a)));
            }
            return foldHash(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(a)));
        }
        fn foldHash(u: anytype) i32 {
            if (@bitSizeOf(@TypeOf(u)) <= 32) return @bitCast(@as(u32, u));
            return @bitCast(@as(u32, @truncate(u)) ^ @as(u32, @truncate(u >> 32)));
        }
        fn compareTo(a: T, b: T) i32 {
            return if (a < b) -1 else if (a > b) 1 else 0;
        }
        fn isNan(a: T) bool {
            return std.math.isNan(a);
        }
        fn isInf(a: T) bool {
            return std.math.isInf(a);
        }
        fn abs(a: T) T {
            return if (int) (if (a < 0) 0 -% a else a) else @abs(a);
        }
        fn min(a: T, b: T) T {
            if (!int and (std.math.isNan(a) or std.math.isNan(b))) return std.math.nan(T);
            return if (a < b) a else b;
        }
        fn max(a: T, b: T) T {
            if (!int and (std.math.isNan(a) or std.math.isNan(b))) return std.math.nan(T);
            return if (a > b) a else b;
        }
    };
}

fn numericEntries() []const KV {
    @setEvalBranchQuota(200_000);
    var out: []const KV = &.{};
    for (num_types) |nt| {
        const n = nt.name;
        const N = Num(nt.T);
        const p = std.fmt.comptimePrint;
        // Operators on the small integer types widen to Int32 in C#; Udon
        // exposes them with an Int32 result, which the examples never use.
        if (@bitSizeOf(nt.T) < 32) continue;
        out = out ++ &[_]KV{
            .{ p("{s}.__op_Addition__{s}_{s}__{s}", .{ n, n, n, n }), wrap(N.add) },
            .{ p("{s}.__op_Subtraction__{s}_{s}__{s}", .{ n, n, n, n }), wrap(N.sub) },
            .{ p("{s}.__op_Multiplication__{s}_{s}__{s}", .{ n, n, n, n }), wrap(N.mul) },
            .{ p("{s}.__op_Division__{s}_{s}__{s}", .{ n, n, n, n }), wrap(N.div) },
            .{ p("{s}.__op_Remainder__{s}_{s}__{s}", .{ n, n, n, n }), wrap(N.rem) },
            .{ p("{s}.__op_Equality__{s}_{s}__SystemBoolean", .{ n, n, n }), wrap(N.eq) },
            .{ p("{s}.__op_Inequality__{s}_{s}__SystemBoolean", .{ n, n, n }), wrap(N.ne) },
            .{ p("{s}.__op_LessThan__{s}_{s}__SystemBoolean", .{ n, n, n }), wrap(N.lt) },
            .{ p("{s}.__op_LessThanOrEqual__{s}_{s}__SystemBoolean", .{ n, n, n }), wrap(N.le) },
            .{ p("{s}.__op_GreaterThan__{s}_{s}__SystemBoolean", .{ n, n, n }), wrap(N.gt) },
            .{ p("{s}.__op_GreaterThanOrEqual__{s}_{s}__SystemBoolean", .{ n, n, n }), wrap(N.ge) },
            .{ p("{s}.__ToString__SystemString", .{n}), wrap(N.toString) },
            .{ p("{s}.__GetHashCode__SystemInt32", .{n}), wrap(N.hash) },
            .{ p("{s}.__Equals__{s}__SystemBoolean", .{ n, n }), wrap(N.eq) },
            .{ p("{s}.__CompareTo__{s}__SystemInt32", .{ n, n }), wrap(N.compareTo) },
            .{ p("SystemMath.__Min__{s}_{s}__{s}", .{ n, n, n }), wrap(N.min) },
            .{ p("SystemMath.__Max__{s}_{s}__{s}", .{ n, n, n }), wrap(N.max) },
        };
        if (isInt(nt.T)) {
            out = out ++ &[_]KV{
                .{ p("{s}.__op_LogicalAnd__{s}_{s}__{s}", .{ n, n, n, n }), wrap(N.band) },
                .{ p("{s}.__op_LogicalOr__{s}_{s}__{s}", .{ n, n, n, n }), wrap(N.bor) },
                .{ p("{s}.__op_LogicalXor__{s}_{s}__{s}", .{ n, n, n, n }), wrap(N.bxor) },
                .{ p("{s}.__op_LeftShift__{s}_SystemInt32__{s}", .{ n, n, n }), wrap(N.shl) },
                .{ p("{s}.__op_RightShift__{s}_SystemInt32__{s}", .{ n, n, n }), wrap(N.shr) },
            };
        } else {
            out = out ++ &[_]KV{
                .{ p("{s}.__IsNaN__{s}__SystemBoolean", .{ n, n }), wrap(N.isNan) },
                .{ p("{s}.__IsInfinity__{s}__SystemBoolean", .{ n, n }), wrap(N.isInf) },
            };
        }
        if (!isInt(nt.T) or @typeInfo(nt.T).int.signedness == .signed) {
            out = out ++ &[_]KV{
                .{ p("{s}.__op_UnaryMinus__{s}__{s}", .{ n, n, n }), wrap(N.neg) },
                .{ p("SystemMath.__Abs__{s}__{s}", .{ n, n }), wrap(N.abs) },
            };
        }
    }
    return out;
}

// ----------------------------------------------------------------------
//  System.Convert (checked) and System.BitConverter
// ----------------------------------------------------------------------

/// `Math.Round(double)`: round half to even.
fn roundHalfEven(x: f64) f64 {
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) return 2.0 * @round(x / 2.0);
    return r;
}

fn Conv(comptime To: type, comptime From: type) type {
    return struct {
        const to_int = isInt(To);
        const from_int = isInt(From);

        fn f(vm: *Vm, x: From) Error!To {
            if (To == bool) return if (From == bool) x else x != 0;
            if (From == bool) return if (to_int) @intFromBool(x) else @floatFromInt(@intFromBool(x));
            if (!to_int) return if (from_int) @floatFromInt(x) else @floatCast(x);
            if (from_int) return std.math.cast(To, x) orelse vm.raise("OverflowException: Convert of {d}", .{x});
            const r = roundHalfEven(x);
            // The upper bound is exclusive at 2^(bits-1) / 2^bits, which is
            // exactly representable; `maxInt` itself is not for 64-bit types.
            const lo: f64 = @floatFromInt(std.math.minInt(To));
            const value_bits: i32 = @typeInfo(To).int.bits - @as(i32, @intFromBool(@typeInfo(To).int.signedness == .signed));
            const hi: f64 = std.math.ldexp(@as(f64, 1), value_bits);
            if (std.math.isNan(r) or r < lo or r >= hi) return vm.raise("OverflowException: Convert of {d}", .{x});
            return @intFromFloat(r);
        }
    };
}

const conv_types = [_]struct { name: []const u8, T: type }{
    .{ .name = "Boolean", .T = bool }, .{ .name = "Byte", .T = u8 },    .{ .name = "SByte", .T = i8 },
    .{ .name = "Int16", .T = i16 },    .{ .name = "UInt16", .T = u16 }, .{ .name = "Int32", .T = i32 },
    .{ .name = "UInt32", .T = u32 },   .{ .name = "Int64", .T = i64 },  .{ .name = "UInt64", .T = u64 },
    .{ .name = "Single", .T = f32 },   .{ .name = "Double", .T = f64 },
};

fn GetBytes(comptime T: type) type {
    return struct {
        fn f(vm: *Vm, x: T) Error!*Array {
            const arr = try vm.newArray("SystemByteArray", @sizeOf(T));
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            std.mem.writeInt(U, arr.bytes[0..@sizeOf(T)], @bitCast(x), .little);
            return arr;
        }
    };
}

fn FromBytes(comptime T: type) type {
    return struct {
        fn f(vm: *Vm, arr: *Array, start: i32) Error!T {
            if (arr.kind != .byte) return vm.raise("BitConverter needs a byte[], got {s}", .{arr.type_name});
            if (start < 0 or @as(i64, start) + @sizeOf(T) > arr.bytes.len)
                return vm.raise("ArgumentException: BitConverter read of {d} bytes at {d} in byte[{d}]", .{ @sizeOf(T), start, arr.len });
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            const s: usize = @intCast(start);
            return @bitCast(std.mem.readInt(U, arr.bytes[s..][0..@sizeOf(T)], .little));
        }
    };
}

/// `byte op byte` in C# is computed on `int`s, and Udon exposes the
/// operators with that result type.
const byte_ops = struct {
    fn add(a: u8, b: u8) i32 {
        return @as(i32, a) + b;
    }
    fn sub(a: u8, b: u8) i32 {
        return @as(i32, a) - b;
    }
    fn mul(a: u8, b: u8) i32 {
        return @as(i32, a) * b;
    }
    fn div(vm: *Vm, a: u8, b: u8) Error!i32 {
        if (b == 0) return vm.raise("DivideByZeroException", .{});
        return a / b;
    }
    fn band(a: u8, b: u8) i32 {
        return a & b;
    }
    fn bor(a: u8, b: u8) i32 {
        return a | b;
    }
    fn bxor(a: u8, b: u8) i32 {
        return a ^ b;
    }
    fn shl(a: u8, b: u8) i32 {
        return Num(i32).shl(a, b);
    }
    fn shr(a: u8, b: u8) i32 {
        return Num(i32).shr(a, b);
    }
    fn neg(a: u8) i32 {
        return -@as(i32, a);
    }
    fn toBoolean(vm: *Vm, arr: *Array, start: i32) Error!bool {
        return try FromBytes(u8).f(vm, arr, start) != 0;
    }
};

fn byteEntries() []const KV {
    const B = Num(u8);
    const p = std.fmt.comptimePrint;
    var out: []const KV = &.{
        .{ "SystemByte.__op_UnaryMinus__SystemByte__SystemInt32", wrap(byte_ops.neg) },
        .{ "SystemBitConverter.__ToBoolean__SystemByteArray_SystemInt32__SystemBoolean", wrap(byte_ops.toBoolean) },
    };
    for (.{
        .{ "Addition", byte_ops.add },    .{ "Subtraction", byte_ops.sub }, .{ "Multiplication", byte_ops.mul },
        .{ "Division", byte_ops.div },    .{ "LogicalAnd", byte_ops.band }, .{ "LogicalOr", byte_ops.bor },
        .{ "LogicalXor", byte_ops.bxor }, .{ "LeftShift", byte_ops.shl },   .{ "RightShift", byte_ops.shr },
    }) |e| out = out ++ &[_]KV{.{ p("SystemByte.__op_{s}__SystemByte_SystemByte__SystemInt32", .{e[0]}), wrap(e[1]) }};
    for (.{
        .{ "Equality", B.eq },        .{ "Inequality", B.ne },  .{ "LessThan", B.lt },
        .{ "LessThanOrEqual", B.le }, .{ "GreaterThan", B.gt }, .{ "GreaterThanOrEqual", B.ge },
    }) |e| out = out ++ &[_]KV{.{ p("SystemByte.__op_{s}__SystemByte_SystemByte__SystemBoolean", .{e[0]}), wrap(e[1]) }};
    return out;
}

fn convertEntries() []const KV {
    @setEvalBranchQuota(200_000);
    var out: []const KV = &.{};
    const p = std.fmt.comptimePrint;
    for (conv_types) |to| {
        for (conv_types) |from| {
            out = out ++ &[_]KV{.{
                p("SystemConvert.__To{s}__System{s}__System{s}", .{ to.name, from.name, to.name }),
                wrap(Conv(to.T, from.T).f),
            }};
        }
    }
    for (conv_types) |t| {
        if (t.T == bool or @bitSizeOf(t.T) < 16) continue;
        out = out ++ &[_]KV{
            .{ p("SystemBitConverter.__GetBytes__System{s}__SystemByteArray", .{t.name}), wrap(GetBytes(t.T).f) },
            .{ p("SystemBitConverter.__To{s}__SystemByteArray_SystemInt32__System{s}", .{ t.name, t.name }), wrap(FromBytes(t.T).f) },
        };
    }
    return out;
}

const bits = struct {
    fn i32ToSingle(x: i32) f32 {
        return @bitCast(x);
    }
    fn singleToI32(x: f32) i32 {
        return @bitCast(x);
    }
    fn i64ToDouble(x: i64) f64 {
        return @bitCast(x);
    }
    fn doubleToI64(x: f64) i64 {
        return @bitCast(x);
    }
};

// ----------------------------------------------------------------------
//  Math / Mathf
// ----------------------------------------------------------------------

fn FloatFns(comptime T: type) type {
    return struct {
        fn sin(x: T) T {
            return @sin(x);
        }
        fn cos(x: T) T {
            return @cos(x);
        }
        fn tan(x: T) T {
            return @tan(x);
        }
        fn asin(x: T) T {
            return std.math.asin(x);
        }
        fn acos(x: T) T {
            return std.math.acos(x);
        }
        fn atan(x: T) T {
            return std.math.atan(x);
        }
        fn atan2(y: T, x: T) T {
            return std.math.atan2(y, x);
        }
        fn sqrt(x: T) T {
            return @sqrt(x);
        }
        fn floor(x: T) T {
            return @floor(x);
        }
        fn ceil(x: T) T {
            return @ceil(x);
        }
        fn trunc(x: T) T {
            return @trunc(x);
        }
        fn round(x: T) T {
            return @floatCast(roundHalfEven(x));
        }
        fn exp(x: T) T {
            return @exp(x);
        }
        fn ln(x: T) T {
            return @log(x);
        }
        fn log10(x: T) T {
            return @log10(x);
        }
        fn pow(x: T, y: T) T {
            return std.math.pow(T, x, y);
        }
        fn sign(x: T) T {
            return if (x >= 0) 1 else -1;
        }
        fn signInt(x: T) i32 {
            return if (x > 0) 1 else if (x < 0) -1 else 0;
        }
        fn toInt(x: T) i32 {
            return std.math.lossyCast(i32, x);
        }
        fn floorToInt(x: T) i32 {
            return toInt(@floor(x));
        }
        fn ceilToInt(x: T) i32 {
            return toInt(@ceil(x));
        }
        fn roundToInt(x: T) i32 {
            return toInt(round(x));
        }
        fn clamp(x: T, lo: T, hi: T) T {
            return if (x < lo) lo else if (x > hi) hi else x;
        }
        fn clamp01(x: T) T {
            return clamp(x, 0, 1);
        }
        fn lerp(a: T, b: T, t: T) T {
            return a + (b - a) * clamp01(t);
        }
        fn lerpUnclamped(a: T, b: T, t: T) T {
            return a + (b - a) * t;
        }
    };
}

fn clampInt(x: i32, lo: i32, hi: i32) i32 {
    return if (x < lo) lo else if (x > hi) hi else x;
}

fn divRem32(vm: *Vm, a: []const u32) Error!void {
    const x = try vm.get(i32, a[0]);
    const y = try vm.get(i32, a[1]);
    vm.set(a[2], try Num(i32).rem(vm, x, y));
    vm.set(a[3], try Num(i32).div(vm, x, y));
}

fn divRem64(vm: *Vm, a: []const u32) Error!void {
    const x = try vm.get(i64, a[0]);
    const y = try vm.get(i64, a[1]);
    vm.set(a[2], try Num(i64).rem(vm, x, y));
    vm.set(a[3], try Num(i64).div(vm, x, y));
}

fn bigMul(a: i32, b: i32) i64 {
    return @as(i64, a) * b;
}

// ----------------------------------------------------------------------
//  Arrays and buffers
// ----------------------------------------------------------------------

fn arrayIndex(vm: *Vm, arr: *const Array, i: i32) Error!usize {
    if (i < 0 or @as(u32, @intCast(i)) >= arr.len)
        return vm.raise("IndexOutOfRangeException: index {d} in {s}[{d}]", .{ i, arr.elemTypeName(), arr.len });
    return @intCast(i);
}

pub fn arrayGet(vm: *Vm, arr: *const Array, index: i32) Error!Value {
    const i = try arrayIndex(vm, arr, index);
    const b = arr.bytes;
    return switch (arr.kind) {
        .value => arr.values[i],
        .boolean => .{ .boolean = b[i] != 0 },
        .byte => .{ .byte = b[i] },
        .sbyte => .{ .sbyte = @bitCast(b[i]) },
        .int16 => .{ .int16 = std.mem.readInt(i16, b[i * 2 ..][0..2], .little) },
        .uint16 => .{ .uint16 = std.mem.readInt(u16, b[i * 2 ..][0..2], .little) },
        .char => .{ .char = std.mem.readInt(u16, b[i * 2 ..][0..2], .little) },
        .int32 => .{ .int32 = std.mem.readInt(i32, b[i * 4 ..][0..4], .little) },
        .uint32 => .{ .uint32 = std.mem.readInt(u32, b[i * 4 ..][0..4], .little) },
        .single => .{ .single = @bitCast(std.mem.readInt(u32, b[i * 4 ..][0..4], .little)) },
        .int64 => .{ .int64 = std.mem.readInt(i64, b[i * 8 ..][0..8], .little) },
        .uint64 => .{ .uint64 = std.mem.readInt(u64, b[i * 8 ..][0..8], .little) },
        .double => .{ .double = @bitCast(std.mem.readInt(u64, b[i * 8 ..][0..8], .little)) },
    };
}

pub fn arraySet(vm: *Vm, arr: *Array, index: i32, v: Value) Error!void {
    const i = try arrayIndex(vm, arr, index);
    const b = arr.bytes;
    const ok = switch (arr.kind) {
        .value => true,
        .boolean => v == .boolean,
        .byte => v == .byte,
        .sbyte => v == .sbyte,
        .int16 => v == .int16,
        .uint16 => v == .uint16,
        .char => v == .char,
        .int32 => v == .int32,
        .uint32 => v == .uint32,
        .single => v == .single,
        .int64 => v == .int64,
        .uint64 => v == .uint64,
        .double => v == .double,
    };
    if (!ok) return vm.raise("Cannot retrieve heap variable of type '{s}' as type '{s}' (array element)", .{ v.typeName(), arr.elemTypeName() });
    switch (arr.kind) {
        .value => arr.values[i] = v,
        .boolean => b[i] = @intFromBool(v.boolean),
        .byte => b[i] = v.byte,
        .sbyte => b[i] = @bitCast(v.sbyte),
        .int16 => std.mem.writeInt(i16, b[i * 2 ..][0..2], v.int16, .little),
        .uint16 => std.mem.writeInt(u16, b[i * 2 ..][0..2], v.uint16, .little),
        .char => std.mem.writeInt(u16, b[i * 2 ..][0..2], v.char, .little),
        .int32 => std.mem.writeInt(i32, b[i * 4 ..][0..4], v.int32, .little),
        .uint32 => std.mem.writeInt(u32, b[i * 4 ..][0..4], v.uint32, .little),
        .single => std.mem.writeInt(u32, b[i * 4 ..][0..4], @bitCast(v.single), .little),
        .int64 => std.mem.writeInt(i64, b[i * 8 ..][0..8], v.int64, .little),
        .uint64 => std.mem.writeInt(u64, b[i * 8 ..][0..8], v.uint64, .little),
        .double => std.mem.writeInt(u64, b[i * 8 ..][0..8], @bitCast(v.double), .little),
    }
}

fn blockCopy(vm: *Vm, src: *Array, src_off: i32, dst: *Array, dst_off: i32, count: i32) Error!void {
    if (src.kind == .value or dst.kind == .value) return vm.raise("ArgumentException: Buffer.BlockCopy needs primitive arrays", .{});
    if (src_off < 0 or dst_off < 0 or count < 0 or
        @as(i64, src_off) + count > src.bytes.len or @as(i64, dst_off) + count > dst.bytes.len)
        return vm.raise("ArgumentException: Buffer.BlockCopy({s}[{d}]+{d} -> {s}[{d}]+{d}, {d} bytes) is out of range", .{
            src.elemTypeName(), src.len, src_off, dst.elemTypeName(), dst.len, dst_off, count,
        });
    const n: usize = @intCast(count);
    const s = src.bytes[@intCast(src_off)..][0..n];
    const d = dst.bytes[@intCast(dst_off)..][0..n];
    if (@intFromPtr(d.ptr) <= @intFromPtr(s.ptr)) std.mem.copyForwards(u8, d, s) else std.mem.copyBackwards(u8, d, s);
    if (dst.bytes.len >= 65536) {
        var h = std.hash.Wyhash.init(vm.stores.hash);
        h.update(std.mem.asBytes(&dst_off));
        h.update(d);
        vm.stores = .{ .count = vm.stores.count + 1, .hash = h.final() };
        if (vm.stores.count == vm.options.stop_at_store)
            return vm.raise("stopped at store {d}: {d} bytes at {d}, digest {x}", .{ vm.stores.count, count, dst_off, vm.stores.hash });
    }
}

fn byteLength(vm: *Vm, arr: *Array) Error!i32 {
    if (arr.kind == .value) return vm.raise("ArgumentException: Buffer.ByteLength needs a primitive array", .{});
    return @intCast(arr.bytes.len);
}

fn arrayCopy5(vm: *Vm, src: *Array, si: i32, dst: *Array, di: i32, n: i32) Error!void {
    if (src.kind != dst.kind) return vm.raise("ArrayTypeMismatchException: {s} -> {s}", .{ src.type_name, dst.type_name });
    if (si < 0 or di < 0 or n < 0 or @as(i64, si) + n > src.len or @as(i64, di) + n > dst.len)
        return vm.raise("ArgumentException: Array.Copy out of range", .{});
    if (src.kind == .value) {
        const s = src.values[@intCast(si)..][0..@intCast(n)];
        const d = dst.values[@intCast(di)..][0..@intCast(n)];
        if (@intFromPtr(d.ptr) <= @intFromPtr(s.ptr)) std.mem.copyForwards(Value, d, s) else std.mem.copyBackwards(Value, d, s);
    } else {
        const w: i32 = @intCast(src.kind.size());
        try blockCopy(vm, src, si * w, dst, di * w, n * w);
    }
}

fn arrayCopy3(vm: *Vm, src: *Array, dst: *Array, n: i32) Error!void {
    return arrayCopy5(vm, src, 0, dst, 0, n);
}

fn arrayClear(vm: *Vm, arr: *Array, index: i32, n: i32) Error!void {
    if (index < 0 or n < 0 or @as(i64, index) + n > arr.len) return vm.raise("IndexOutOfRangeException: Array.Clear", .{});
    if (arr.kind == .value) {
        @memset(arr.values[@intCast(index)..][0..@intCast(n)], Value.defaultFor(arr.elemTypeName()));
    } else {
        const w = arr.kind.size();
        @memset(arr.bytes[@as(usize, @intCast(index)) * w ..][0 .. @as(usize, @intCast(n)) * w], 0);
    }
}

fn arrayLength(arr: *Array) i32 {
    return @intCast(arr.len);
}

// ----------------------------------------------------------------------
//  Strings, encodings, logging
// ----------------------------------------------------------------------

fn concatValues(vm: *Vm, parts: []const Value) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = vm.arena.allocator();
    for (parts) |p| {
        if (p == .null_) continue;
        try out.appendSlice(a, try vm.toText(p));
    }
    return out.items;
}

const str = struct {
    fn concat2(vm: *Vm, a: Value, b: Value) Error![]const u8 {
        return concatValues(vm, &.{ a, b });
    }
    fn concat3(vm: *Vm, a: Value, b: Value, c: Value) Error![]const u8 {
        return concatValues(vm, &.{ a, b, c });
    }
    fn concat4(vm: *Vm, a: Value, b: Value, c: Value, d: Value) Error![]const u8 {
        return concatValues(vm, &.{ a, b, c, d });
    }
    fn length(s: []const u8) i32 {
        return @intCast(std.unicode.utf8CountCodepoints(s) catch s.len);
    }
    fn equal(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }
    fn notEqual(a: ?[]const u8, b: ?[]const u8) bool {
        return !equal(a, b);
    }
    fn isNullOrEmpty(s: ?[]const u8) bool {
        return s == null or s.?.len == 0;
    }
    fn toString(vm: *Vm, v: Value) Error![]const u8 {
        return vm.toText(v);
    }
    fn substring2(vm: *Vm, s: []const u8, start: i32, len: i32) Error![]const u8 {
        if (start < 0 or len < 0 or @as(i64, start) + len > s.len) return vm.raise("ArgumentOutOfRangeException: Substring", .{});
        return s[@intCast(start)..][0..@intCast(len)];
    }
    /// `Convert.ToChar(int)`: range-checked.
    fn charFromInt(vm: *Vm, x: i32) Error!Char {
        if (x < 0 or x > 0xFFFF) return vm.raise("OverflowException: {d} is not a Char", .{x});
        return .{ .c = @intCast(x) };
    }
    fn indexOfChar(s: []const u8, c: Char) i32 {
        // Strings are kept as UTF-8 and indexed by byte, which is the
        // character index for the ASCII the tests use.
        if (c.c > 0x7F) return -1;
        return if (std.mem.indexOfScalar(u8, s, @intCast(c.c))) |i| @intCast(i) else -1;
    }
    /// `TrimEnd()`: without the white space at the end.
    fn trimEnd(_: *Vm, s: []const u8) Error![]const u8 {
        return std.mem.trimEnd(u8, s, " \t\r\n\x0b\x0c");
    }
    fn substring1(vm: *Vm, s: []const u8, start: i32) Error![]const u8 {
        return substring2(vm, s, start, @as(i32, @intCast(s.len)) - start);
    }
    fn format1(vm: *Vm, f: []const u8, a: Value) Error![]const u8 {
        return formatN(vm, f, &.{a});
    }
    fn format2(vm: *Vm, f: []const u8, a: Value, b: Value) Error![]const u8 {
        return formatN(vm, f, &.{ a, b });
    }
    fn format3(vm: *Vm, f: []const u8, a: Value, b: Value, c: Value) Error![]const u8 {
        return formatN(vm, f, &.{ a, b, c });
    }
    /// `{n}` placeholders only; format specifiers are ignored.
    fn formatN(vm: *Vm, f: []const u8, args: []const Value) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const a = vm.arena.allocator();
        var i: usize = 0;
        while (i < f.len) : (i += 1) {
            if (f[i] == '{' and i + 1 < f.len and std.ascii.isDigit(f[i + 1])) {
                const close = std.mem.indexOfScalarPos(u8, f, i, '}') orelse return vm.raise("FormatException", .{});
                const n = f[i + 1] - '0';
                if (n >= args.len) return vm.raise("FormatException: index {d}", .{n});
                try out.appendSlice(a, try vm.toText(args[n]));
                i = close;
            } else try out.append(a, f[i]);
        }
        return out.items;
    }
};

fn utf8Object(vm: *Vm) Error!*Object {
    return vm.newObject("SystemTextEncoding");
}

const enc = struct {
    fn getString1(vm: *Vm, _: *Object, arr: *Array) Error![]const u8 {
        return getString3(vm, undefined, arr, 0, @intCast(arr.len));
    }
    fn getString3(vm: *Vm, _: *Object, arr: *Array, index: i32, count: i32) Error![]const u8 {
        if (arr.kind != .byte) return vm.raise("Encoding.GetString needs a byte[], got {s}", .{arr.type_name});
        if (index < 0 or count < 0 or @as(i64, index) + count > arr.len)
            return vm.raise("ArgumentOutOfRangeException: Encoding.GetString({d}, {d}) on byte[{d}]", .{ index, count, arr.len });
        return vm.arena.allocator().dupe(u8, arr.bytes[@intCast(index)..][0..@intCast(count)]);
    }
    fn getBytes1(vm: *Vm, _: *Object, s: []const u8) Error!*Array {
        const arr = try vm.newArray("SystemByteArray", @intCast(s.len));
        @memcpy(arr.bytes, s);
        return arr;
    }
    fn getBytes5(vm: *Vm, _: *Object, s: []const u8, char_index: i32, char_count: i32, dst: *Array, byte_index: i32) Error!i32 {
        if (dst.kind != .byte) return vm.raise("Encoding.GetBytes needs a byte[] destination", .{});
        if (char_index < 0 or char_count < 0 or @as(i64, char_index) + char_count > s.len or
            byte_index < 0 or @as(i64, byte_index) + char_count > dst.len)
            return vm.raise("ArgumentException: Encoding.GetBytes out of range", .{});
        @memcpy(dst.bytes[@intCast(byte_index)..][0..@intCast(char_count)], s[@intCast(char_index)..][0..@intCast(char_count)]);
        return char_count;
    }
    fn getByteCount(_: *Object, s: []const u8) i32 {
        return @intCast(s.len);
    }
};

fn fromBase64(vm: *Vm, s: []const u8) Error!*Array {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return vm.raise("FormatException: invalid Base64 string", .{});
    const arr = try vm.newArray("SystemByteArray", @intCast(n));
    dec.decode(arr.bytes, s) catch return vm.raise("FormatException: invalid Base64 string", .{});
    return arr;
}

fn toBase64(vm: *Vm, arr: *Array) Error![]const u8 {
    if (arr.kind != .byte) return vm.raise("Convert.ToBase64String needs a byte[]", .{});
    const e = std.base64.standard.Encoder;
    const buf = try vm.arena.allocator().alloc(u8, e.calcSize(arr.bytes.len));
    return e.encode(buf, arr.bytes);
}

const logging = struct {
    fn info(vm: *Vm, v: Value) Error!void {
        try vm.log(.info, try vm.toText(v));
    }
    fn warn(vm: *Vm, v: Value) Error!void {
        try vm.log(.warning, try vm.toText(v));
    }
    fn err(vm: *Vm, v: Value) Error!void {
        try vm.log(.err, try vm.toText(v));
    }
};

fn typeGetType(vm: *Vm, name: []const u8) Error!*Object {
    const o = try vm.newObject("SystemType");
    o.name = name;
    return o;
}

fn objectEquals(a: Value, b: Value) bool {
    return std.meta.eql(a, b);
}

fn objectNotEquals(a: Value, b: Value) bool {
    return !std.meta.eql(a, b);
}

fn isValid(v: Value) bool {
    return v != .null_;
}

// ----------------------------------------------------------------------
//  Unity value types and the handful of members with real behaviour
// ----------------------------------------------------------------------

const v3 = struct {
    fn new(x: f32, y: f32, z: f32) Vector3 {
        return .{ .v = .{ x, y, z, 0 } };
    }
    fn add(a: Vector3, b: Vector3) Vector3 {
        return new(a.v[0] + b.v[0], a.v[1] + b.v[1], a.v[2] + b.v[2]);
    }
    fn sub(a: Vector3, b: Vector3) Vector3 {
        return new(a.v[0] - b.v[0], a.v[1] - b.v[1], a.v[2] - b.v[2]);
    }
    fn scale(a: Vector3, s: f32) Vector3 {
        return new(a.v[0] * s, a.v[1] * s, a.v[2] * s);
    }
    fn scaleL(s: f32, a: Vector3) Vector3 {
        return scale(a, s);
    }
    fn divide(a: Vector3, s: f32) Vector3 {
        return new(a.v[0] / s, a.v[1] / s, a.v[2] / s);
    }
    fn negate(a: Vector3) Vector3 {
        return scale(a, -1);
    }
    fn dot(a: Vector3, b: Vector3) f32 {
        return a.v[0] * b.v[0] + a.v[1] * b.v[1] + a.v[2] * b.v[2];
    }
    fn cross(a: Vector3, b: Vector3) Vector3 {
        return new(a.v[1] * b.v[2] - a.v[2] * b.v[1], a.v[2] * b.v[0] - a.v[0] * b.v[2], a.v[0] * b.v[1] - a.v[1] * b.v[0]);
    }
    fn magnitude(a: Vector3) f32 {
        return @sqrt(dot(a, a));
    }
    fn sqrMagnitude(a: Vector3) f32 {
        return dot(a, a);
    }
    fn normalized(a: Vector3) Vector3 {
        const m = magnitude(a);
        return if (m > 1e-5) divide(a, m) else new(0, 0, 0);
    }
    fn distance(a: Vector3, b: Vector3) f32 {
        return magnitude(sub(a, b));
    }
    fn lerp(a: Vector3, b: Vector3, t: f32) Vector3 {
        return add(a, scale(sub(b, a), FloatFns(f32).clamp01(t)));
    }
    fn zero() Vector3 {
        return new(0, 0, 0);
    }
    fn one() Vector3 {
        return new(1, 1, 1);
    }
    fn up() Vector3 {
        return new(0, 1, 0);
    }
    fn forward() Vector3 {
        return new(0, 0, 1);
    }
    fn right() Vector3 {
        return new(1, 0, 0);
    }
};

fn VecField(comptime V: type, comptime i: usize) type {
    return struct {
        fn get(a: V) f32 {
            return a.v[i];
        }
        /// Struct property setters mutate the `this` slot in place.
        fn set(vm: *Vm, args: []const u32) Error!void {
            var a = try vm.get(V, args[0]);
            a.v[i] = try vm.get(f32, args[1]);
            vm.set(args[0], a);
        }
    };
}

fn vector2New(x: f32, y: f32) Vector2 {
    return .{ .v = .{ x, y, 0, 0 } };
}
fn quatIdentity() Quaternion {
    return .{ .v = .{ 0, 0, 0, 1 } };
}
fn quatNew(x: f32, y: f32, z: f32, w: f32) Quaternion {
    return .{ .v = .{ x, y, z, w } };
}
/// Unity's Z-X-Y Euler order, degrees.
fn quatEuler(xd: f32, yd: f32, zd: f32) Quaternion {
    const h = std.math.pi / 360.0;
    const sx = @sin(xd * h);
    const cx = @cos(xd * h);
    const sy = @sin(yd * h);
    const cy = @cos(yd * h);
    const sz = @sin(zd * h);
    const cz = @cos(zd * h);
    return .{ .v = .{
        cy * sx * cz + sy * cx * sz,
        sy * cx * cz - cy * sx * sz,
        cy * cx * sz - sy * sx * cz,
        cy * cx * cz + sy * sx * sz,
    } };
}
fn colorNew3(r: f32, g: f32, b: f32) Color {
    return .{ .v = .{ r, g, b, 1 } };
}
fn colorNew4(r: f32, g: f32, b: f32, a: f32) Color {
    return .{ .v = .{ r, g, b, a } };
}
fn color32New(r: u8, g: u8, b: u8, a: u8) Color32 {
    return .{ .c = .{ r, g, b, a } };
}

const unity = struct {
    fn deltaTime(vm: *Vm) f32 {
        return vm.host.delta_time;
    }
    fn uptime(vm: *Vm) f64 {
        return vm.host.time;
    }
    /// A `DateTime` is modelled by its tick count: 100 ns units since
    /// 0001-01-01. The emulated wall clock starts at 2024-01-01T00:00:00Z
    /// and follows the frame clock, so runs are reproducible.
    fn utcNow(vm: *Vm) Error!*Object {
        const start_ticks: i64 = 638_396_640_000_000_000;
        const now = try vm.newObject("SystemDateTime");
        try now.put(vm.arena.allocator(), "Ticks", .{ .int64 = start_ticks + @as(i64, @intFromFloat(vm.host.time * 1e7)) });
        return now;
    }
    fn time(vm: *Vm) f32 {
        return @floatCast(vm.host.time);
    }
    fn frameCount(vm: *Vm) i32 {
        return vm.host.frame;
    }
    fn getChild(vm: *Vm, t: *Object, index: i32) Error!*Object {
        if (index < 0 or @as(usize, @intCast(index)) >= t.children.items.len)
            return vm.raise("UnityException: Transform child out of bounds ({d} of {d})", .{ index, t.children.items.len });
        return t.children.items[@intCast(index)];
    }
    fn childCount(t: *Object) i32 {
        return @intCast(t.children.items.len);
    }
    fn setActive(vm: *Vm, go: *Object, active: bool) Error!void {
        try go.put(vm.arena.allocator(), "activeSelf", .{ .boolean = active });
    }
    fn instantiate(vm: *Vm, original: *Object) Error!*Object {
        const a = vm.arena.allocator();
        const clone = try vm.newObject(original.type_name);
        clone.name = try vm.fmt("{s}(Clone)", .{original.name});
        clone.props = try original.props.clone(a);
        const tr = try vm.newObject("UnityEngineTransform");
        if (original.get("transform")) |ot| if (ot == .object) {
            tr.props = try ot.object.props.clone(a);
        };
        try tr.put(a, "gameObject", .{ .object = clone });
        try tr.put(a, "transform", .{ .object = tr });
        try clone.put(a, "transform", .{ .object = tr });
        if (vm.options.record_calls) try vm.calls.append(a, .{
            .sig = "VRCInstantiate.__Instantiate__UnityEngineGameObject__UnityEngineGameObject",
            .args = try a.dupe(Value, &.{.{ .object = original }}),
        });
        return clone;
    }
    /// `new Texture2D(w, h)`: RGBA32 with a full mipmap chain.
    fn texture2D(vm: *Vm, w: i32, h: i32) Error!*Object {
        const format = try vm.newObject("UnityEngineTextureFormat");
        format.name = "RGBA32";
        return texture2DFormat(vm, w, h, format, true);
    }
    fn texture2DFormat(vm: *Vm, w: i32, h: i32, format: ?*Object, mip_chain: bool) Error!*Object {
        const a = vm.arena.allocator();
        // An enum that was never assigned is its zero value, which is not a
        // texture format.
        const f = format orelse return vm.raise("UnityException: TextureFormat is invalid", .{});
        if (w <= 0 or h <= 0) return vm.raise("UnityException: Texture has out of range width / height", .{});
        const t = try vm.newObject("UnityEngineTexture2D");
        try t.put(a, "width", .{ .int32 = w });
        try t.put(a, "height", .{ .int32 = h });
        try t.put(a, "format", .{ .object = f });
        var mips: i32 = 1;
        if (mip_chain) {
            var side = @max(w, h);
            while (side > 1) : (side >>= 1) mips += 1;
        }
        try t.put(a, "mipmapCount", .{ .int32 = mips });
        return t;
    }
    /// Bytes of raw RGBA32 data in all mip levels.
    fn rawTextureSize(tex: *const Object) ?u32 {
        var w: u32 = @intCast((tex.get("width") orelse return null).int32);
        var h: u32 = @intCast((tex.get("height") orelse return null).int32);
        var mips = (tex.get("mipmapCount") orelse return null).int32;
        var total: u32 = 0;
        while (mips > 0) : (mips -= 1) {
            total += w * h * 4;
            w = @max(w / 2, 1);
            h = @max(h / 2, 1);
        }
        return total;
    }
    /// Keeps a private copy, as Unity does, so later writes to the source
    /// array do not change what tests see as "uploaded". Unity rejects data
    /// that does not fill the texture.
    fn loadRawTextureData(vm: *Vm, tex: *Object, data: *Array) Error!void {
        if (data.kind != .byte) return vm.raise("LoadRawTextureData needs a byte[]", .{});
        if (rawTextureSize(tex)) |need| if (data.len < need)
            return vm.raise("UnityException: LoadRawTextureData: not enough data provided (will result in overread).", .{});
        const copy = try vm.newArray("SystemByteArray", data.len);
        @memcpy(copy.bytes, data.bytes);
        try tex.put(vm.arena.allocator(), "rawTextureData", .{ .array = copy });
    }
    /// Points live in a Vector3[] sized by `positionCount`.
    fn linePositions(vm: *Vm, line: *Object, count: u32) Error!*Array {
        if (line.get("positions")) |v| if (v.array.len == count) return v.array;
        const points = try vm.newArray("UnityEngineVector3Array", count);
        try line.put(vm.arena.allocator(), "positions", .{ .array = points });
        return points;
    }
    fn setPositionCount(vm: *Vm, line: *Object, count: i32) Error!void {
        if (count < 0) return vm.raise("ArgumentException: negative positionCount", .{});
        _ = try linePositions(vm, line, @intCast(count));
    }
    fn setLinePosition(vm: *Vm, line: *Object, index: i32, point: Vector3) Error!void {
        const points = if (line.get("positions")) |v| v.array else try linePositions(vm, line, 0);
        if (index < 0 or @as(u32, @intCast(index)) >= points.len)
            return vm.raise("LineRenderer.SetPosition index out of bounds ({d} of {d})", .{ index, points.len });
        points.values[@intCast(index)] = .{ .vec = .{ .kind = .vector3, .v = point.v } };
    }
    fn localPlayer(vm: *Vm) *Object {
        return vm.host.local_player;
    }
    fn isOwner(vm: *Vm, _: *Object) bool {
        return vm.host.is_owner;
    }
    fn setOwner(vm: *Vm, player: *Object, _: *Object) void {
        vm.host.is_owner = player == vm.host.local_player;
    }
    fn requestSerialization(vm: *Vm, _: *Object) void {
        vm.host.serialization_requested = true;
    }
    fn isMaster() bool {
        return true;
    }
    fn randomRangeInt(vm: *Vm, lo: i32, hi: i32) i32 {
        if (hi <= lo) return lo;
        return lo + @as(i32, @intCast(nextRandom(vm) % @as(u64, @intCast(@as(i64, hi) - lo))));
    }
    fn randomRangeFloat(vm: *Vm, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * randomValue(vm);
    }
    fn randomValue(vm: *Vm) f32 {
        return @as(f32, @floatFromInt(nextRandom(vm) >> 40)) / 16777216.0;
    }
    fn nextRandom(vm: *Vm) u64 {
        var x = vm.host.rng;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        vm.host.rng = x;
        return x;
    }
    /// Runs the named event immediately, nested inside the caller, as
    /// `UdonBehaviour.SendCustomEvent` does on the same behaviour.
    fn sendCustomEvent(vm: *Vm, _: *Object, name: []const u8) Error!void {
        _ = try vm.runEvent(name);
    }
    fn setProgramVariable(vm: *Vm, _: *Object, name: []const u8, v: Value) Error!void {
        _ = vm.setVar(name, v);
    }
    fn getProgramVariable(vm: *Vm, _: *Object, name: []const u8) Error!Value {
        return vm.getVar(name) orelse .null_;
    }
};

// ----------------------------------------------------------------------
//  Registry
// ----------------------------------------------------------------------

const F32 = FloatFns(f32);
const F64 = FloatFns(f64);

const fixed_entries = [_]KV{
    // System.Boolean
    .{ "SystemBoolean.__op_UnaryNegation__SystemBoolean__SystemBoolean", wrap(struct {
        fn f(a: bool) bool {
            return !a;
        }
    }.f) },
    .{ "SystemBoolean.__op_LogicalAnd__SystemBoolean_SystemBoolean__SystemBoolean", wrap(boolAnd) },
    .{ "SystemBoolean.__op_ConditionalAnd__SystemBoolean_SystemBoolean__SystemBoolean", wrap(boolAnd) },
    .{ "SystemBoolean.__op_LogicalOr__SystemBoolean_SystemBoolean__SystemBoolean", wrap(boolOr) },
    .{ "SystemBoolean.__op_ConditionalOr__SystemBoolean_SystemBoolean__SystemBoolean", wrap(boolOr) },
    .{ "SystemBoolean.__op_LogicalXor__SystemBoolean_SystemBoolean__SystemBoolean", wrap(boolXor) },
    .{ "SystemBoolean.__op_Inequality__SystemBoolean_SystemBoolean__SystemBoolean", wrap(boolXor) },
    .{ "SystemBoolean.__op_Equality__SystemBoolean_SystemBoolean__SystemBoolean", wrap(boolEq) },

    // System.BitConverter bit casts
    .{ "SystemBitConverter.__Int32BitsToSingle__SystemInt32__SystemSingle", wrap(bits.i32ToSingle) },
    .{ "SystemBitConverter.__SingleToInt32Bits__SystemSingle__SystemInt32", wrap(bits.singleToI32) },
    .{ "SystemBitConverter.__Int64BitsToDouble__SystemInt64__SystemDouble", wrap(bits.i64ToDouble) },
    .{ "SystemBitConverter.__DoubleToInt64Bits__SystemDouble__SystemInt64", wrap(bits.doubleToI64) },
    .{ "SystemConvert.__FromBase64String__SystemString__SystemByteArray", wrap(fromBase64) },
    .{ "SystemConvert.__ToBase64String__SystemByteArray__SystemString", wrap(toBase64) },

    // System.Math
    .{ "SystemMath.__Floor__SystemDouble__SystemDouble", wrap(F64.floor) },
    .{ "SystemMath.__Ceiling__SystemDouble__SystemDouble", wrap(F64.ceil) },
    .{ "SystemMath.__Truncate__SystemDouble__SystemDouble", wrap(F64.trunc) },
    .{ "SystemMath.__Round__SystemDouble__SystemDouble", wrap(F64.round) },
    .{ "SystemMath.__Sqrt__SystemDouble__SystemDouble", wrap(F64.sqrt) },
    .{ "SystemMath.__Sin__SystemDouble__SystemDouble", wrap(F64.sin) },
    .{ "SystemMath.__Cos__SystemDouble__SystemDouble", wrap(F64.cos) },
    .{ "SystemMath.__Tan__SystemDouble__SystemDouble", wrap(F64.tan) },
    .{ "SystemMath.__Asin__SystemDouble__SystemDouble", wrap(F64.asin) },
    .{ "SystemMath.__Acos__SystemDouble__SystemDouble", wrap(F64.acos) },
    .{ "SystemMath.__Atan__SystemDouble__SystemDouble", wrap(F64.atan) },
    .{ "SystemMath.__Atan2__SystemDouble_SystemDouble__SystemDouble", wrap(F64.atan2) },
    .{ "SystemMath.__Exp__SystemDouble__SystemDouble", wrap(F64.exp) },
    .{ "SystemMath.__Log__SystemDouble__SystemDouble", wrap(F64.ln) },
    .{ "SystemMath.__Log10__SystemDouble__SystemDouble", wrap(F64.log10) },
    .{ "SystemMath.__Pow__SystemDouble_SystemDouble__SystemDouble", wrap(F64.pow) },
    .{ "SystemMath.__Sign__SystemDouble__SystemInt32", wrap(F64.signInt) },
    .{ "SystemMath.__Sign__SystemSingle__SystemInt32", wrap(F32.signInt) },
    .{ "SystemMath.__BigMul__SystemInt32_SystemInt32__SystemInt64", wrap(bigMul) },
    .{ "SystemMath.__DivRem__SystemInt32_SystemInt32_SystemInt32Ref__SystemInt32", raw(4, divRem32) },
    .{ "SystemMath.__DivRem__SystemInt64_SystemInt64_SystemInt64Ref__SystemInt64", raw(4, divRem64) },

    // UnityEngine.Mathf
    .{ "UnityEngineMathf.__Sin__SystemSingle__SystemSingle", wrap(F32.sin) },
    .{ "UnityEngineMathf.__Cos__SystemSingle__SystemSingle", wrap(F32.cos) },
    .{ "UnityEngineMathf.__Tan__SystemSingle__SystemSingle", wrap(F32.tan) },
    .{ "UnityEngineMathf.__Asin__SystemSingle__SystemSingle", wrap(F32.asin) },
    .{ "UnityEngineMathf.__Acos__SystemSingle__SystemSingle", wrap(F32.acos) },
    .{ "UnityEngineMathf.__Atan__SystemSingle__SystemSingle", wrap(F32.atan) },
    .{ "UnityEngineMathf.__Atan2__SystemSingle_SystemSingle__SystemSingle", wrap(F32.atan2) },
    .{ "UnityEngineMathf.__Sqrt__SystemSingle__SystemSingle", wrap(F32.sqrt) },
    .{ "UnityEngineMathf.__Abs__SystemSingle__SystemSingle", wrap(Num(f32).abs) },
    .{ "UnityEngineMathf.__Abs__SystemInt32__SystemInt32", wrap(Num(i32).abs) },
    .{ "UnityEngineMathf.__Floor__SystemSingle__SystemSingle", wrap(F32.floor) },
    .{ "UnityEngineMathf.__Ceil__SystemSingle__SystemSingle", wrap(F32.ceil) },
    .{ "UnityEngineMathf.__Round__SystemSingle__SystemSingle", wrap(F32.round) },
    .{ "UnityEngineMathf.__FloorToInt__SystemSingle__SystemInt32", wrap(F32.floorToInt) },
    .{ "UnityEngineMathf.__CeilToInt__SystemSingle__SystemInt32", wrap(F32.ceilToInt) },
    .{ "UnityEngineMathf.__RoundToInt__SystemSingle__SystemInt32", wrap(F32.roundToInt) },
    .{ "UnityEngineMathf.__Min__SystemSingle_SystemSingle__SystemSingle", wrap(Num(f32).min) },
    .{ "UnityEngineMathf.__Max__SystemSingle_SystemSingle__SystemSingle", wrap(Num(f32).max) },
    .{ "UnityEngineMathf.__Min__SystemInt32_SystemInt32__SystemInt32", wrap(Num(i32).min) },
    .{ "UnityEngineMathf.__Max__SystemInt32_SystemInt32__SystemInt32", wrap(Num(i32).max) },
    .{ "UnityEngineMathf.__Clamp__SystemSingle_SystemSingle_SystemSingle__SystemSingle", wrap(F32.clamp) },
    .{ "UnityEngineMathf.__Clamp__SystemInt32_SystemInt32_SystemInt32__SystemInt32", wrap(clampInt) },
    .{ "UnityEngineMathf.__Clamp01__SystemSingle__SystemSingle", wrap(F32.clamp01) },
    .{ "UnityEngineMathf.__Lerp__SystemSingle_SystemSingle_SystemSingle__SystemSingle", wrap(F32.lerp) },
    .{ "UnityEngineMathf.__LerpUnclamped__SystemSingle_SystemSingle_SystemSingle__SystemSingle", wrap(F32.lerpUnclamped) },
    .{ "UnityEngineMathf.__Pow__SystemSingle_SystemSingle__SystemSingle", wrap(F32.pow) },
    .{ "UnityEngineMathf.__Exp__SystemSingle__SystemSingle", wrap(F32.exp) },
    .{ "UnityEngineMathf.__Log__SystemSingle__SystemSingle", wrap(F32.ln) },
    .{ "UnityEngineMathf.__Log10__SystemSingle__SystemSingle", wrap(F32.log10) },
    .{ "UnityEngineMathf.__Sign__SystemSingle__SystemSingle", wrap(F32.sign) },

    // System.Buffer / System.Array
    .{ "SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid", wrap(blockCopy) },
    .{ "SystemBuffer.__ByteLength__SystemArray__SystemInt32", wrap(byteLength) },
    .{ "SystemArray.__Copy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid", wrap(arrayCopy5) },
    .{ "SystemArray.__Copy__SystemArray_SystemArray_SystemInt32__SystemVoid", wrap(arrayCopy3) },
    .{ "SystemArray.__Clear__SystemArray_SystemInt32_SystemInt32__SystemVoid", wrap(arrayClear) },
    .{ "SystemArray.__get_Length__SystemInt32", wrap(arrayLength) },

    // System.String / System.Object
    .{ "SystemString.__Concat__SystemString_SystemString__SystemString", wrap(str.concat2) },
    .{ "SystemString.__Concat__SystemString_SystemString_SystemString__SystemString", wrap(str.concat3) },
    .{ "SystemString.__Concat__SystemString_SystemString_SystemString_SystemString__SystemString", wrap(str.concat4) },
    .{ "SystemString.__Concat__SystemObject_SystemObject__SystemString", wrap(str.concat2) },
    .{ "SystemString.__Concat__SystemObject_SystemObject_SystemObject__SystemString", wrap(str.concat3) },
    .{ "SystemString.__get_Length__SystemInt32", wrap(str.length) },
    .{ "SystemString.__op_Equality__SystemString_SystemString__SystemBoolean", wrap(str.equal) },
    .{ "SystemString.__op_Inequality__SystemString_SystemString__SystemBoolean", wrap(str.notEqual) },
    .{ "SystemString.__Equals__SystemString__SystemBoolean", wrap(str.equal) },
    .{ "SystemString.__IsNullOrEmpty__SystemString__SystemBoolean", wrap(str.isNullOrEmpty) },
    .{ "SystemString.__Substring__SystemInt32__SystemString", wrap(str.substring1) },
    .{ "SystemString.__TrimEnd__SystemString", wrap(str.trimEnd) },
    .{ "SystemString.__Substring__SystemInt32_SystemInt32__SystemString", wrap(str.substring2) },
    .{ "SystemString.__Format__SystemString_SystemObject__SystemString", wrap(str.format1) },
    .{ "SystemString.__Format__SystemString_SystemObject_SystemObject__SystemString", wrap(str.format2) },
    .{ "SystemString.__Format__SystemString_SystemObject_SystemObject_SystemObject__SystemString", wrap(str.format3) },
    .{ "SystemString.__ToString__SystemString", wrap(str.toString) },
    .{ "SystemString.__Copy__SystemString__SystemString", wrap(str.toString) },
    .{ "SystemString.__IndexOf__SystemChar__SystemInt32", wrap(str.indexOfChar) },
    .{ "SystemConvert.__ToChar__SystemInt32__SystemChar", wrap(str.charFromInt) },
    .{ "SystemObject.__ToString__SystemString", wrap(str.toString) },
    .{ "SystemBoolean.__ToString__SystemString", wrap(str.toString) },
    .{ "SystemObject.__Equals__SystemObject__SystemBoolean", wrap(objectEquals) },
    .{ "SystemObject.__op_Equality__SystemObject_SystemObject__SystemBoolean", wrap(objectEquals) },
    .{ "SystemObject.__op_Inequality__SystemObject_SystemObject__SystemBoolean", wrap(objectNotEquals) },
    .{ "UnityEngineObject.__op_Equality__UnityEngineObject_UnityEngineObject__SystemBoolean", wrap(objectEquals) },
    .{ "UnityEngineObject.__op_Inequality__UnityEngineObject_UnityEngineObject__SystemBoolean", wrap(objectNotEquals) },
    .{ "VRCSDKBaseUtilities.__IsValid__SystemObject__SystemBoolean", wrap(isValid) },
    .{ "SystemType.__GetType__SystemString__SystemType", wrap(typeGetType) },

    // System.Text.Encoding
    .{ "SystemTextEncoding.__get_UTF8__SystemTextEncoding", wrap(utf8Object) },
    .{ "SystemTextEncoding.__get_ASCII__SystemTextEncoding", wrap(utf8Object) },
    .{ "SystemTextEncoding.__GetString__SystemByteArray__SystemString", wrap(enc.getString1) },
    .{ "SystemTextEncoding.__GetString__SystemByteArray_SystemInt32_SystemInt32__SystemString", wrap(enc.getString3) },
    .{ "SystemTextEncoding.__GetBytes__SystemString__SystemByteArray", wrap(enc.getBytes1) },
    .{ "SystemTextEncoding.__GetBytes__SystemString_SystemInt32_SystemInt32_SystemByteArray_SystemInt32__SystemInt32", wrap(enc.getBytes5) },
    .{ "SystemTextEncoding.__GetByteCount__SystemString__SystemInt32", wrap(enc.getByteCount) },

    // Logging
    .{ "UnityEngineDebug.__Log__SystemObject__SystemVoid", wrap(logging.info) },
    .{ "UnityEngineDebug.__LogWarning__SystemObject__SystemVoid", wrap(logging.warn) },
    .{ "UnityEngineDebug.__LogError__SystemObject__SystemVoid", wrap(logging.err) },
    .{ "SystemConsole.__WriteLine__SystemString__SystemVoid", wrap(logging.info) },
    .{ "SystemConsole.__WriteLine__SystemObject__SystemVoid", wrap(logging.info) },

    // UnityEngine value types
    .{ "UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3", wrap(v3.new) },
    .{ "UnityEngineVector3.__op_Addition__UnityEngineVector3_UnityEngineVector3__UnityEngineVector3", wrap(v3.add) },
    .{ "UnityEngineVector3.__op_Subtraction__UnityEngineVector3_UnityEngineVector3__UnityEngineVector3", wrap(v3.sub) },
    .{ "UnityEngineVector3.__op_Multiply__UnityEngineVector3_SystemSingle__UnityEngineVector3", wrap(v3.scale) },
    .{ "UnityEngineVector3.__op_Multiply__SystemSingle_UnityEngineVector3__UnityEngineVector3", wrap(v3.scaleL) },
    .{ "UnityEngineVector3.__op_Division__UnityEngineVector3_SystemSingle__UnityEngineVector3", wrap(v3.divide) },
    .{ "UnityEngineVector3.__op_UnaryNegation__UnityEngineVector3__UnityEngineVector3", wrap(v3.negate) },
    .{ "UnityEngineVector3.__Dot__UnityEngineVector3_UnityEngineVector3__SystemSingle", wrap(v3.dot) },
    .{ "UnityEngineVector3.__Cross__UnityEngineVector3_UnityEngineVector3__UnityEngineVector3", wrap(v3.cross) },
    .{ "UnityEngineVector3.__Distance__UnityEngineVector3_UnityEngineVector3__SystemSingle", wrap(v3.distance) },
    .{ "UnityEngineVector3.__Lerp__UnityEngineVector3_UnityEngineVector3_SystemSingle__UnityEngineVector3", wrap(v3.lerp) },
    .{ "UnityEngineVector3.__get_magnitude__SystemSingle", wrap(v3.magnitude) },
    .{ "UnityEngineVector3.__get_sqrMagnitude__SystemSingle", wrap(v3.sqrMagnitude) },
    .{ "UnityEngineVector3.__get_normalized__UnityEngineVector3", wrap(v3.normalized) },
    .{ "UnityEngineVector3.__get_zero__UnityEngineVector3", wrap(v3.zero) },
    .{ "UnityEngineVector3.__get_one__UnityEngineVector3", wrap(v3.one) },
    .{ "UnityEngineVector3.__get_up__UnityEngineVector3", wrap(v3.up) },
    .{ "UnityEngineVector3.__get_forward__UnityEngineVector3", wrap(v3.forward) },
    .{ "UnityEngineVector3.__get_right__UnityEngineVector3", wrap(v3.right) },
    .{ "UnityEngineVector3.__get_x__SystemSingle", wrap(VecField(Vector3, 0).get) },
    .{ "UnityEngineVector3.__get_y__SystemSingle", wrap(VecField(Vector3, 1).get) },
    .{ "UnityEngineVector3.__get_z__SystemSingle", wrap(VecField(Vector3, 2).get) },
    .{ "UnityEngineVector3.__set_x__SystemSingle__SystemVoid", raw(2, VecField(Vector3, 0).set) },
    .{ "UnityEngineVector3.__set_y__SystemSingle__SystemVoid", raw(2, VecField(Vector3, 1).set) },
    .{ "UnityEngineVector3.__set_z__SystemSingle__SystemVoid", raw(2, VecField(Vector3, 2).set) },
    .{ "UnityEngineVector2.__ctor__SystemSingle_SystemSingle__UnityEngineVector2", wrap(vector2New) },
    .{ "UnityEngineVector2.__get_x__SystemSingle", wrap(VecField(Vector2, 0).get) },
    .{ "UnityEngineVector2.__get_y__SystemSingle", wrap(VecField(Vector2, 1).get) },
    .{ "UnityEngineQuaternion.__get_identity__UnityEngineQuaternion", wrap(quatIdentity) },
    .{ "UnityEngineQuaternion.__ctor__SystemSingle_SystemSingle_SystemSingle_SystemSingle__UnityEngineQuaternion", wrap(quatNew) },
    .{ "UnityEngineQuaternion.__Euler__SystemSingle_SystemSingle_SystemSingle__UnityEngineQuaternion", wrap(quatEuler) },
    .{ "UnityEngineColor.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineColor", wrap(colorNew3) },
    .{ "UnityEngineColor.__ctor__SystemSingle_SystemSingle_SystemSingle_SystemSingle__UnityEngineColor", wrap(colorNew4) },
    .{ "UnityEngineColor32.__ctor__SystemByte_SystemByte_SystemByte_SystemByte__UnityEngineColor32", wrap(color32New) },

    // Scene, time, networking
    .{ "UnityEngineTime.__get_deltaTime__SystemSingle", wrap(unity.deltaTime) },
    .{ "UnityEngineTime.__get_fixedDeltaTime__SystemSingle", wrap(unity.deltaTime) },
    .{ "UnityEngineTime.__get_time__SystemSingle", wrap(unity.time) },
    .{ "UnityEngineTime.__get_timeSinceLevelLoad__SystemSingle", wrap(unity.time) },
    .{ "UnityEngineTime.__get_realtimeSinceStartup__SystemSingle", wrap(unity.time) },
    .{ "UnityEngineTime.__get_frameCount__SystemInt32", wrap(unity.frameCount) },
    .{ "UnityEngineTransform.__GetChild__SystemInt32__UnityEngineTransform", wrap(unity.getChild) },
    .{ "UnityEngineTransform.__get_childCount__SystemInt32", wrap(unity.childCount) },
    .{ "UnityEngineGameObject.__SetActive__SystemBoolean__SystemVoid", wrap(unity.setActive) },
    .{ "VRCInstantiate.__Instantiate__UnityEngineGameObject__UnityEngineGameObject", wrap(unity.instantiate) },
    .{ "UnityEngineLineRenderer.__set_positionCount__SystemInt32__SystemVoid", wrap(unity.setPositionCount) },
    .{ "UnityEngineLineRenderer.__SetPosition__SystemInt32_UnityEngineVector3__SystemVoid", wrap(unity.setLinePosition) },
    .{ "UnityEngineTime.__get_realtimeSinceStartupAsDouble__SystemDouble", wrap(unity.uptime) },
    .{ "SystemDateTime.__get_UtcNow__SystemDateTime", wrap(unity.utcNow) },
    .{ "UnityEngineTexture2D.__ctor__SystemInt32_SystemInt32__UnityEngineTexture2D", wrap(unity.texture2D) },
    .{ "UnityEngineTexture2D.__ctor__SystemInt32_SystemInt32_UnityEngineTextureFormat_SystemBoolean__UnityEngineTexture2D", wrap(unity.texture2DFormat) },
    .{ "UnityEngineTexture2D.__LoadRawTextureData__SystemByteArray__SystemVoid", wrap(unity.loadRawTextureData) },
    .{ "VRCSDKBaseNetworking.__get_LocalPlayer__VRCSDKBaseVRCPlayerApi", wrap(unity.localPlayer) },
    .{ "VRCSDKBaseNetworking.__IsOwner__UnityEngineGameObject__SystemBoolean", wrap(unity.isOwner) },
    .{ "VRCSDKBaseNetworking.__SetOwner__VRCSDKBaseVRCPlayerApi_UnityEngineGameObject__SystemVoid", wrap(unity.setOwner) },
    .{ "VRCUdonCommonInterfacesIUdonEventReceiver.__RequestSerialization__SystemVoid", wrap(unity.requestSerialization) },
    .{ "VRCSDKBaseNetworking.__get_IsMaster__SystemBoolean", wrap(unity.isMaster) },
    .{ "UnityEngineRandom.__Range__SystemInt32_SystemInt32__SystemInt32", wrap(unity.randomRangeInt) },
    .{ "UnityEngineRandom.__Range__SystemSingle_SystemSingle__SystemSingle", wrap(unity.randomRangeFloat) },
    .{ "UnityEngineRandom.__get_value__SystemSingle", wrap(unity.randomValue) },
    .{ "VRCUdonCommonInterfacesIUdonEventReceiver.__SendCustomEvent__SystemString__SystemVoid", wrap(unity.sendCustomEvent) },
    .{ "VRCUdonCommonInterfacesIUdonEventReceiver.__SetProgramVariable__SystemString_SystemObject__SystemVoid", wrap(unity.setProgramVariable) },
    .{ "VRCUdonCommonInterfacesIUdonEventReceiver.__GetProgramVariable__SystemString__SystemObject", wrap(unity.getProgramVariable) },
};

fn boolAnd(a: bool, b: bool) bool {
    return a and b;
}
fn boolOr(a: bool, b: bool) bool {
    return a or b;
}
fn boolXor(a: bool, b: bool) bool {
    return a != b;
}
fn boolEq(a: bool, b: bool) bool {
    return a == b;
}

const registry = blk: {
    @setEvalBranchQuota(4_000_000);
    const all = numericEntries() ++ convertEntries() ++ byteEntries() ++ &fixed_entries;
    break :blk std.StaticStringMap(Impl).initComptime(all);
};

// ----------------------------------------------------------------------
//  Generic object model
// ----------------------------------------------------------------------

/// Handle an extern with no dedicated implementation. `args` holds exactly
/// what the program pushed; the static form has `sig.staticParamCount()`
/// entries and the instance form one more.
pub fn dynamicCall(vm: *Vm, r: *const vm_mod.Resolved, args: []const u32) Error!void {
    const sig = r.sig.?;
    const a = vm.arena.allocator();
    const n_static = sig.staticParamCount();
    const has_this = args.len == n_static + 1;
    const ret_idx: ?u32 = if (sig.returnsValue()) args[args.len - 1] else null;
    const in = args[0 .. args.len - @intFromBool(ret_idx != null)];

    // Arrays of any element type.
    if (std.mem.endsWith(u8, sig.type_name, "Array")) {
        const m = sig.method;
        if (std.mem.eql(u8, m, "ctor") and in.len == 1) {
            const len = try vm.get(i32, in[0]);
            if (len < 0) return vm.raise("OverflowException: negative array length {d}", .{len});
            vm.set(ret_idx.?, try vm.newArray(sig.type_name, @intCast(len)));
            return;
        }
        if (in.len >= 1) {
            const arr = try vm.get(*Array, in[0]);
            if (std.mem.eql(u8, m, "Get") or (std.mem.eql(u8, m, "GetValue") and in.len == 2)) {
                vm.heap[ret_idx.?] = try arrayGet(vm, arr, try vm.get(i32, in[1]));
                return;
            }
            if (std.mem.eql(u8, m, "Set") and in.len == 3) return arraySet(vm, arr, try vm.get(i32, in[1]), vm.heap[in[2]]);
            if (std.mem.eql(u8, m, "SetValue") and in.len == 3) return arraySet(vm, arr, try vm.get(i32, in[2]), vm.heap[in[1]]);
            if (std.mem.eql(u8, m, "get_Length")) {
                vm.set(ret_idx.?, @as(i32, @intCast(arr.len)));
                return;
            }
        }
    }

    // The object model below stands in for Unity and VRChat types only.
    // A .NET member the emulator has no implementation of must not
    // quietly return a default: programs depend on those exactly.
    if (std.mem.startsWith(u8, sig.type_name, "System") and vm.heapObject(in) == null)
        return vm.raise("extern not implemented by the emulator: {s}", .{r.text});

    if (vm.options.record_calls) {
        const copy = try a.alloc(Value, in.len);
        for (copy, in) |*c, i| c.* = vm.heap[i];
        try vm.calls.append(a, .{ .sig = r.text, .args = copy });
    }

    // An instance member of nothing.
    if (has_this and vm.heap[in[0]] == .null_ and Value.defaultFor(sig.type_name) == .null_)
        return vm.raise("NullReferenceException: {s} called on null", .{r.text});

    // Property access on a host object. A component-like property that was
    // never set reads as a fresh object, the same one every time.
    if (has_this and vm.heap[in[0]] == .object) {
        const obj = vm.heap[in[0]].object;
        if (std.mem.startsWith(u8, sig.method, "get_") and in.len == 1) {
            const key = sig.method[4..];
            vm.heap[ret_idx.?] = obj.get(key) orelse made: {
                const v = try defaultResult(vm, sig.ret);
                if (v == .object) try obj.put(a, key, v);
                break :made v;
            };
            return;
        }
        if (std.mem.startsWith(u8, sig.method, "set_") and in.len == 2) {
            try obj.put(a, sig.method[4..], vm.heap[in[1]]);
            return;
        }
    }

    // Anything else: the call is logged; a result gets the type's default,
    // or a fresh host object when the type is a reference type we do not
    // model, so chained calls keep working.
    if (ret_idx) |ri| vm.heap[ri] = try defaultResult(vm, sig.ret);
}

/// What an unmodelled extern returns: the type's default, or a fresh host
/// object when the type is a reference type we do not model, so chained
/// calls keep working.
fn defaultResult(vm: *Vm, type_name: []const u8) Error!Value {
    const v = Value.defaultFor(type_name);
    if (v != .null_) return v;
    for ([_][]const u8{ "SystemString", "SystemObject" }) |plain| if (std.mem.eql(u8, type_name, plain)) return v;
    if (std.mem.endsWith(u8, type_name, "Array")) return v;
    return .{ .object = try vm.newObject(type_name) };
}

// ------------------------------- tests -------------------------------

const testing = std.testing;

test "registry covers generated and fixed signatures" {
    try testing.expect(lookup("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
    try testing.expect(lookup("SystemUInt64.__op_RightShift__SystemUInt64_SystemInt32__SystemUInt64") != null);
    try testing.expect(lookup("SystemConvert.__ToInt32__SystemDouble__SystemInt32") != null);
    try testing.expect(lookup("SystemBitConverter.__ToInt64__SystemByteArray_SystemInt32__SystemInt64") != null);
    try testing.expect(lookup("SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid") != null);
    try testing.expectEqual(@as(u8, 3), lookup("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32").?.argc);
    try testing.expectEqual(@as(u8, 5), lookup("SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid").?.argc);
    try testing.expect(lookup("NoSuch.__thing__SystemVoid") == null);
}

test "roundHalfEven matches Math.Round" {
    try testing.expectEqual(@as(f64, 2), roundHalfEven(2.5));
    try testing.expectEqual(@as(f64, 4), roundHalfEven(3.5));
    try testing.expectEqual(@as(f64, -2), roundHalfEven(-2.5));
    try testing.expectEqual(@as(f64, 3), roundHalfEven(2.7));
    try testing.expectEqual(@as(f64, -3), roundHalfEven(-2.7));
}

test "shift counts are masked like C#" {
    try testing.expectEqual(@as(i32, 2), Num(i32).shl(1, 33));
    try testing.expectEqual(@as(i32, -1), Num(i32).shr(-1, 40));
    try testing.expectEqual(@as(i64, 2), Num(i64).shl(1, 65));
    try testing.expectEqual(@as(u32, 0x7FFFFFFF), Num(u32).shr(0xFFFFFFFF, 1));
}

test "GetHashCode is the unchecked reinterpretation used by the translator" {
    try testing.expectEqual(@as(i32, -1), Num(u32).hash(0xFFFFFFFF));
    try testing.expectEqual(@as(i32, 5), Num(i64).hash(5));
    try testing.expectEqual(@as(i32, 1 ^ 2), Num(i64).hash((2 << 32) | 1));
}
