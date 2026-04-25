//! Numeric opcode → EXTERN signature lookup table.
//!
//! The Udon runtime implements integer / floating-point arithmetic by dispatching
//! to .NET operator methods (`System.Int32.op_Addition`, etc.) through EXTERN
//! calls. This table maps every WASM numeric opcode bench.wasm exercises to the
//! extern signature in Udon-type-name form (`docs/udon_specs.md` §7).
//!
//! Signatures were derived from the operator method conventions visible in the
//! UdonSharp exposure tree; they are the canonical form the translator emits.
//! Signatures that require special handling (i32.eqz, i32.clz, shifts with
//! UInt32 RHS, etc.) are noted inline.

const std = @import("std");
const wasm = @import("wasm");
const tn = @import("udon").type_name;

const TypeName = tn.TypeName;

pub const Arity = enum { unary, binary };

pub const Entry = struct {
    arity: Arity,
    /// Udon type of both inputs (and the result for homogeneous ops).
    operand_ty: TypeName,
    /// Output Udon type (for comparisons this is SystemBoolean; for homogeneous
    /// arithmetic ops this matches `operand_ty`).
    result_ty: TypeName,
    /// Extern signature.
    sig: []const u8,
};

/// Map an instruction to its numeric-op entry. Returns null for opcodes that
/// are not simple numeric (control, memory, variable, const, conversions).
pub fn lookup(inst: wasm.Instruction) ?Entry {
    return switch (inst) {
        // ---- i32 unary ----
        // NOTE: i32.eqz はインスタンスメソッド `Int32.Equals(Int32)` への素直な
        // .unary マッピングだと Udon の 3-push 規約に 1 足りずクラッシュするため、
        // この表からは除外し translate.zig の emitOne 側で i32.eq 相当に展開する。
        // ---- i32 binary (arithmetic / bitwise / shift) ----
        .i32_add => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32" },
        .i32_sub => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32" },
        .i32_mul => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_Multiplication__SystemInt32_SystemInt32__SystemInt32" },
        .i32_div_s => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_Division__SystemInt32_SystemInt32__SystemInt32" },
        .i32_div_u => .{ .arity = .binary, .operand_ty = tn.uint32, .result_ty = tn.uint32, .sig = "SystemUInt32.__op_Division__SystemUInt32_SystemUInt32__SystemUInt32" },
        .i32_rem_s => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_Modulus__SystemInt32_SystemInt32__SystemInt32" },
        .i32_rem_u => .{ .arity = .binary, .operand_ty = tn.uint32, .result_ty = tn.uint32, .sig = "SystemUInt32.__op_Modulus__SystemUInt32_SystemUInt32__SystemUInt32" },
        .i32_and => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32" },
        .i32_or => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_LogicalOr__SystemInt32_SystemInt32__SystemInt32" },
        .i32_xor => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_LogicalXor__SystemInt32_SystemInt32__SystemInt32" },
        .i32_shl => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32" },
        .i32_shr_s => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32" },
        .i32_shr_u => .{ .arity = .binary, .operand_ty = tn.uint32, .result_ty = tn.uint32, .sig = "SystemUInt32.__op_RightShift__SystemUInt32_SystemInt32__SystemUInt32" },

        // ---- i32 comparisons (result bool) ----
        .i32_eq => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.boolean, .sig = "SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean" },
        .i32_ne => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.boolean, .sig = "SystemInt32.__op_Inequality__SystemInt32_SystemInt32__SystemBoolean" },
        .i32_lt_s => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.boolean, .sig = "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean" },
        .i32_le_s => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.boolean, .sig = "SystemInt32.__op_LessThanOrEqual__SystemInt32_SystemInt32__SystemBoolean" },
        .i32_gt_s => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.boolean, .sig = "SystemInt32.__op_GreaterThan__SystemInt32_SystemInt32__SystemBoolean" },
        .i32_ge_s => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.boolean, .sig = "SystemInt32.__op_GreaterThanOrEqual__SystemInt32_SystemInt32__SystemBoolean" },
        .i32_lt_u => .{ .arity = .binary, .operand_ty = tn.uint32, .result_ty = tn.boolean, .sig = "SystemUInt32.__op_LessThan__SystemUInt32_SystemUInt32__SystemBoolean" },
        .i32_le_u => .{ .arity = .binary, .operand_ty = tn.uint32, .result_ty = tn.boolean, .sig = "SystemUInt32.__op_LessThanOrEqual__SystemUInt32_SystemUInt32__SystemBoolean" },
        .i32_gt_u => .{ .arity = .binary, .operand_ty = tn.uint32, .result_ty = tn.boolean, .sig = "SystemUInt32.__op_GreaterThan__SystemUInt32_SystemUInt32__SystemBoolean" },
        .i32_ge_u => .{ .arity = .binary, .operand_ty = tn.uint32, .result_ty = tn.boolean, .sig = "SystemUInt32.__op_GreaterThanOrEqual__SystemUInt32_SystemUInt32__SystemBoolean" },

        // ---- i64 binary ----
        .i64_add => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_Addition__SystemInt64_SystemInt64__SystemInt64" },
        .i64_sub => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_Subtraction__SystemInt64_SystemInt64__SystemInt64" },
        .i64_mul => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_Multiplication__SystemInt64_SystemInt64__SystemInt64" },
        .i64_and => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_LogicalAnd__SystemInt64_SystemInt64__SystemInt64" },
        .i64_or => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_LogicalOr__SystemInt64_SystemInt64__SystemInt64" },
        .i64_xor => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_LogicalXor__SystemInt64_SystemInt64__SystemInt64" },
        .i64_shl => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_LeftShift__SystemInt64_SystemInt32__SystemInt64" },
        .i64_shr_s => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_RightShift__SystemInt64_SystemInt32__SystemInt64" },
        .i64_shr_u => .{ .arity = .binary, .operand_ty = tn.uint64, .result_ty = tn.uint64, .sig = "SystemUInt64.__op_RightShift__SystemUInt64_SystemInt32__SystemUInt64" },
        .i64_div_s => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_Division__SystemInt64_SystemInt64__SystemInt64" },
        .i64_div_u => .{ .arity = .binary, .operand_ty = tn.uint64, .result_ty = tn.uint64, .sig = "SystemUInt64.__op_Division__SystemUInt64_SystemUInt64__SystemUInt64" },
        .i64_rem_s => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_Modulus__SystemInt64_SystemInt64__SystemInt64" },
        // i64.rem_u: Udon には SystemUInt64.__op_Modulus__ が存在しないため、
        // translate.zig 側で a - (a/b)*b の 3-EXTERN シーケンスに展開する。
        // この lookup テーブルからは意図的に除外する。

        // ---- i64 comparisons (result bool) ----
        .i64_eq => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.boolean, .sig = "SystemInt64.__op_Equality__SystemInt64_SystemInt64__SystemBoolean" },
        .i64_ne => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.boolean, .sig = "SystemInt64.__op_Inequality__SystemInt64_SystemInt64__SystemBoolean" },
        .i64_lt_s => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.boolean, .sig = "SystemInt64.__op_LessThan__SystemInt64_SystemInt64__SystemBoolean" },
        .i64_le_s => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.boolean, .sig = "SystemInt64.__op_LessThanOrEqual__SystemInt64_SystemInt64__SystemBoolean" },
        .i64_gt_s => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.boolean, .sig = "SystemInt64.__op_GreaterThan__SystemInt64_SystemInt64__SystemBoolean" },
        .i64_ge_s => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.boolean, .sig = "SystemInt64.__op_GreaterThanOrEqual__SystemInt64_SystemInt64__SystemBoolean" },
        .i64_lt_u => .{ .arity = .binary, .operand_ty = tn.uint64, .result_ty = tn.boolean, .sig = "SystemUInt64.__op_LessThan__SystemUInt64_SystemUInt64__SystemBoolean" },
        .i64_le_u => .{ .arity = .binary, .operand_ty = tn.uint64, .result_ty = tn.boolean, .sig = "SystemUInt64.__op_LessThanOrEqual__SystemUInt64_SystemUInt64__SystemBoolean" },
        .i64_gt_u => .{ .arity = .binary, .operand_ty = tn.uint64, .result_ty = tn.boolean, .sig = "SystemUInt64.__op_GreaterThan__SystemUInt64_SystemUInt64__SystemBoolean" },
        .i64_ge_u => .{ .arity = .binary, .operand_ty = tn.uint64, .result_ty = tn.boolean, .sig = "SystemUInt64.__op_GreaterThanOrEqual__SystemUInt64_SystemUInt64__SystemBoolean" },

        // ---- f32 binary ----
        .f32_add => .{ .arity = .binary, .operand_ty = tn.single, .result_ty = tn.single, .sig = "SystemSingle.__op_Addition__SystemSingle_SystemSingle__SystemSingle" },
        .f32_sub => .{ .arity = .binary, .operand_ty = tn.single, .result_ty = tn.single, .sig = "SystemSingle.__op_Subtraction__SystemSingle_SystemSingle__SystemSingle" },
        .f32_mul => .{ .arity = .binary, .operand_ty = tn.single, .result_ty = tn.single, .sig = "SystemSingle.__op_Multiplication__SystemSingle_SystemSingle__SystemSingle" },
        .f32_div => .{ .arity = .binary, .operand_ty = tn.single, .result_ty = tn.single, .sig = "SystemSingle.__op_Division__SystemSingle_SystemSingle__SystemSingle" },

        // ---- f64 binary ----
        .f64_add => .{ .arity = .binary, .operand_ty = tn.double, .result_ty = tn.double, .sig = "SystemDouble.__op_Addition__SystemDouble_SystemDouble__SystemDouble" },
        .f64_sub => .{ .arity = .binary, .operand_ty = tn.double, .result_ty = tn.double, .sig = "SystemDouble.__op_Subtraction__SystemDouble_SystemDouble__SystemDouble" },
        .f64_mul => .{ .arity = .binary, .operand_ty = tn.double, .result_ty = tn.double, .sig = "SystemDouble.__op_Multiplication__SystemDouble_SystemDouble__SystemDouble" },
        .f64_div => .{ .arity = .binary, .operand_ty = tn.double, .result_ty = tn.double, .sig = "SystemDouble.__op_Division__SystemDouble_SystemDouble__SystemDouble" },
        .f64_floor => .{ .arity = .unary, .operand_ty = tn.double, .result_ty = tn.double, .sig = "SystemMath.__Floor__SystemDouble__SystemDouble" },

        // ---- Conversions (SystemConvert) ----
        // NOTE: `i32.wrap_i64` is NOT in this table — `SystemConvert.ToInt32(Int64)`
        // is a *checked* conversion that throws for values outside Int32 range,
        // whereas WASM `i32.wrap_i64` is pure bit truncation. `emitOne` handles
        // it specially via `emitI32WrapI64` which goes through BitConverter
        // (bit-pattern preserving).
        .i64_extend_i32_s => .{ .arity = .unary, .operand_ty = tn.int32, .result_ty = tn.int64, .sig = "SystemConvert.__ToInt64__SystemInt32__SystemInt64" },
        .i64_extend_i32_u => .{ .arity = .unary, .operand_ty = tn.uint32, .result_ty = tn.int64, .sig = "SystemConvert.__ToInt64__SystemUInt32__SystemInt64" },
        .i32_trunc_f32_s => .{ .arity = .unary, .operand_ty = tn.single, .result_ty = tn.int32, .sig = "SystemConvert.__ToInt32__SystemSingle__SystemInt32" },
        .i32_trunc_f32_u => .{ .arity = .unary, .operand_ty = tn.single, .result_ty = tn.uint32, .sig = "SystemConvert.__ToUInt32__SystemSingle__SystemUInt32" },
        .i32_trunc_f64_s => .{ .arity = .unary, .operand_ty = tn.double, .result_ty = tn.int32, .sig = "SystemConvert.__ToInt32__SystemDouble__SystemInt32" },
        .i32_trunc_f64_u => .{ .arity = .unary, .operand_ty = tn.double, .result_ty = tn.uint32, .sig = "SystemConvert.__ToUInt32__SystemDouble__SystemUInt32" },
        .i64_trunc_f32_s => .{ .arity = .unary, .operand_ty = tn.single, .result_ty = tn.int64, .sig = "SystemConvert.__ToInt64__SystemSingle__SystemInt64" },
        .i64_trunc_f32_u => .{ .arity = .unary, .operand_ty = tn.single, .result_ty = tn.uint64, .sig = "SystemConvert.__ToUInt64__SystemSingle__SystemUInt64" },
        .i64_trunc_f64_s => .{ .arity = .unary, .operand_ty = tn.double, .result_ty = tn.int64, .sig = "SystemConvert.__ToInt64__SystemDouble__SystemInt64" },
        .i64_trunc_f64_u => .{ .arity = .unary, .operand_ty = tn.double, .result_ty = tn.uint64, .sig = "SystemConvert.__ToUInt64__SystemDouble__SystemUInt64" },
        .f32_convert_i32_s => .{ .arity = .unary, .operand_ty = tn.int32, .result_ty = tn.single, .sig = "SystemConvert.__ToSingle__SystemInt32__SystemSingle" },
        .f32_convert_i32_u => .{ .arity = .unary, .operand_ty = tn.uint32, .result_ty = tn.single, .sig = "SystemConvert.__ToSingle__SystemUInt32__SystemSingle" },
        .f32_convert_i64_s => .{ .arity = .unary, .operand_ty = tn.int64, .result_ty = tn.single, .sig = "SystemConvert.__ToSingle__SystemInt64__SystemSingle" },
        .f32_convert_i64_u => .{ .arity = .unary, .operand_ty = tn.uint64, .result_ty = tn.single, .sig = "SystemConvert.__ToSingle__SystemUInt64__SystemSingle" },
        .f32_demote_f64 => .{ .arity = .unary, .operand_ty = tn.double, .result_ty = tn.single, .sig = "SystemConvert.__ToSingle__SystemDouble__SystemSingle" },
        .f64_convert_i32_s => .{ .arity = .unary, .operand_ty = tn.int32, .result_ty = tn.double, .sig = "SystemConvert.__ToDouble__SystemInt32__SystemDouble" },
        .f64_convert_i32_u => .{ .arity = .unary, .operand_ty = tn.uint32, .result_ty = tn.double, .sig = "SystemConvert.__ToDouble__SystemUInt32__SystemDouble" },
        .f64_convert_i64_s => .{ .arity = .unary, .operand_ty = tn.int64, .result_ty = tn.double, .sig = "SystemConvert.__ToDouble__SystemInt64__SystemDouble" },
        .f64_convert_i64_u => .{ .arity = .unary, .operand_ty = tn.uint64, .result_ty = tn.double, .sig = "SystemConvert.__ToDouble__SystemUInt64__SystemDouble" },
        .f64_promote_f32 => .{ .arity = .unary, .operand_ty = tn.single, .result_ty = tn.double, .sig = "SystemConvert.__ToDouble__SystemSingle__SystemDouble" },

        // ---- Reinterpret (SystemBitConverter) ----
        .i32_reinterpret_f32 => .{ .arity = .unary, .operand_ty = tn.single, .result_ty = tn.int32, .sig = "SystemBitConverter.__SingleToInt32Bits__SystemSingle__SystemInt32" },
        .f32_reinterpret_i32 => .{ .arity = .unary, .operand_ty = tn.int32, .result_ty = tn.single, .sig = "SystemBitConverter.__Int32BitsToSingle__SystemInt32__SystemSingle" },
        .i64_reinterpret_f64 => .{ .arity = .unary, .operand_ty = tn.double, .result_ty = tn.int64, .sig = "SystemBitConverter.__DoubleToInt64Bits__SystemDouble__SystemInt64" },
        .f64_reinterpret_i64 => .{ .arity = .unary, .operand_ty = tn.int64, .result_ty = tn.double, .sig = "SystemBitConverter.__Int64BitsToDouble__SystemInt64__SystemDouble" },

        else => null,
    };
}

test "i32.add looks up correctly" {
    const e = lookup(.i32_add).?;
    try std.testing.expectEqual(Arity.binary, e.arity);
    try std.testing.expect(e.operand_ty.eql(tn.int32));
    try std.testing.expectEqualStrings("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32", e.sig);
}

test "i32.eq produces SystemBoolean result" {
    const e = lookup(.i32_eq).?;
    try std.testing.expect(e.result_ty.eql(tn.boolean));
}

// i32.eqz は「ゼロとの等価判定」を意味する WASM 命令。Udon に 1:1 対応する
// 静的 EXTERN が存在しないため、このテーブルからは意図的に除外する。
// 代わりに translate.zig の emitOne がインライン展開し、i32.eq と同じ
// `SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean` に
// `__c_i32_0` を RHS として合流させる。
//
// かつて本テーブルには
//   .i32_eqz => .{ ..., .sig = "SystemInt32.__Equals__SystemInt32__SystemBoolean" }
// というエントリが置かれていたが、これはインスタンスメソッド
// `Int32.Equals(Int32)` に対する .unary emit (`push s; push s; extern`) を
// 誘発し、Udon VM が 3 つ目の引数スロットを内部配列から取り出す段階で
// ArgumentOutOfRangeException を投げた (bench.uasm 実行時 PC 43048 crash)。
test "i32.eqz is not dispatched via the numeric table" {
    try std.testing.expect(lookup(.i32_eqz) == null);
}

test "non-numeric instructions return null" {
    try std.testing.expect(lookup(.{ .local_get = 0 }) == null);
    try std.testing.expect(lookup(.{ .i32_const = 42 }) == null);
    try std.testing.expect(lookup(.nop) == null);
}

// ---- Conversion / reinterpret opcodes ----
// bench の test_64bit_and_float / test_globals が
//   i64→i32 wrap, i32→i64 extend, f64→i32 trunc
// を要求する。README の未実装項目 "Some conversion opcodes" を満たすため、
// 下記 22 個の変換 opcode が lookup で EXTERN 署名を返すこと。

test "i32.wrap_i64 is not in the numeric table (handled via BitConverter truncation)" {
    // `SystemConvert.ToInt32(Int64)` is a *checked* conversion that throws
    // for values outside [Int32.MinValue, Int32.MaxValue]. WASM `i32.wrap_i64`
    // is pure bit truncation. The Translator handles `.i32_wrap_i64` via a
    // dedicated `emitI32WrapI64` routine that routes through BitConverter.
    // This lookup should therefore return null so the generic sig path cannot
    // re-introduce the checked conversion.
    try std.testing.expect(lookup(.i32_wrap_i64) == null);
}

test "i64.extend_i32_s / _u lower via SystemConvert" {
    const s = lookup(.i64_extend_i32_s) orelse return error.TestExpectedEqual;
    try std.testing.expect(s.result_ty.eql(tn.int64));
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToInt64__SystemInt32__SystemInt64",
        s.sig,
    );
    const u = lookup(.i64_extend_i32_u) orelse return error.TestExpectedEqual;
    try std.testing.expect(u.result_ty.eql(tn.int64));
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToInt64__SystemUInt32__SystemInt64",
        u.sig,
    );
}

test "i32.trunc_f32 / _f64 lower via SystemConvert" {
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToInt32__SystemSingle__SystemInt32",
        (lookup(.i32_trunc_f32_s) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToUInt32__SystemSingle__SystemUInt32",
        (lookup(.i32_trunc_f32_u) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToInt32__SystemDouble__SystemInt32",
        (lookup(.i32_trunc_f64_s) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToUInt32__SystemDouble__SystemUInt32",
        (lookup(.i32_trunc_f64_u) orelse return error.TestExpectedEqual).sig,
    );
}

test "i64.trunc_f32 / _f64 lower via SystemConvert" {
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToInt64__SystemSingle__SystemInt64",
        (lookup(.i64_trunc_f32_s) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToUInt64__SystemSingle__SystemUInt64",
        (lookup(.i64_trunc_f32_u) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToInt64__SystemDouble__SystemInt64",
        (lookup(.i64_trunc_f64_s) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToUInt64__SystemDouble__SystemUInt64",
        (lookup(.i64_trunc_f64_u) orelse return error.TestExpectedEqual).sig,
    );
}

test "f32.convert_i32 / _i64 lower via SystemConvert" {
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToSingle__SystemInt32__SystemSingle",
        (lookup(.f32_convert_i32_s) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToSingle__SystemUInt32__SystemSingle",
        (lookup(.f32_convert_i32_u) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToSingle__SystemInt64__SystemSingle",
        (lookup(.f32_convert_i64_s) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToSingle__SystemUInt64__SystemSingle",
        (lookup(.f32_convert_i64_u) orelse return error.TestExpectedEqual).sig,
    );
}

test "f64.convert_i32 / _i64 lower via SystemConvert" {
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToDouble__SystemInt32__SystemDouble",
        (lookup(.f64_convert_i32_s) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToDouble__SystemUInt32__SystemDouble",
        (lookup(.f64_convert_i32_u) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToDouble__SystemInt64__SystemDouble",
        (lookup(.f64_convert_i64_s) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToDouble__SystemUInt64__SystemDouble",
        (lookup(.f64_convert_i64_u) orelse return error.TestExpectedEqual).sig,
    );
}

test "f32.demote_f64 / f64.promote_f32 lower via SystemConvert" {
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToSingle__SystemDouble__SystemSingle",
        (lookup(.f32_demote_f64) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemConvert.__ToDouble__SystemSingle__SystemDouble",
        (lookup(.f64_promote_f32) orelse return error.TestExpectedEqual).sig,
    );
}

test "reinterpret opcodes lower via SystemBitConverter" {
    try std.testing.expectEqualStrings(
        "SystemBitConverter.__SingleToInt32Bits__SystemSingle__SystemInt32",
        (lookup(.i32_reinterpret_f32) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemBitConverter.__Int32BitsToSingle__SystemInt32__SystemSingle",
        (lookup(.f32_reinterpret_i32) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemBitConverter.__DoubleToInt64Bits__SystemDouble__SystemInt64",
        (lookup(.i64_reinterpret_f64) orelse return error.TestExpectedEqual).sig,
    );
    try std.testing.expectEqualStrings(
        "SystemBitConverter.__Int64BitsToDouble__SystemInt64__SystemDouble",
        (lookup(.f64_reinterpret_i64) orelse return error.TestExpectedEqual).sig,
    );
}
