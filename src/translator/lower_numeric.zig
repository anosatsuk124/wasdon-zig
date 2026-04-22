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
        .i32_eqz => .{ .arity = .unary, .operand_ty = tn.int32, .result_ty = tn.boolean, .sig = "SystemInt32.__Equals__SystemInt32__SystemBoolean" },
        // ---- i32 binary (arithmetic / bitwise / shift) ----
        .i32_add => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32" },
        .i32_sub => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32" },
        .i32_mul => .{ .arity = .binary, .operand_ty = tn.int32, .result_ty = tn.int32, .sig = "SystemInt32.__op_Multiply__SystemInt32_SystemInt32__SystemInt32" },
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
        .i64_mul => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_Multiply__SystemInt64_SystemInt64__SystemInt64" },
        .i64_and => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_LogicalAnd__SystemInt64_SystemInt64__SystemInt64" },
        .i64_or => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_LogicalOr__SystemInt64_SystemInt64__SystemInt64" },
        .i64_xor => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_LogicalXor__SystemInt64_SystemInt64__SystemInt64" },
        .i64_shl => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_LeftShift__SystemInt64_SystemInt32__SystemInt64" },
        .i64_shr_s => .{ .arity = .binary, .operand_ty = tn.int64, .result_ty = tn.int64, .sig = "SystemInt64.__op_RightShift__SystemInt64_SystemInt32__SystemInt64" },

        // ---- f64 binary ----
        .f64_add => .{ .arity = .binary, .operand_ty = tn.double, .result_ty = tn.double, .sig = "SystemDouble.__op_Addition__SystemDouble_SystemDouble__SystemDouble" },
        .f64_sub => .{ .arity = .binary, .operand_ty = tn.double, .result_ty = tn.double, .sig = "SystemDouble.__op_Subtraction__SystemDouble_SystemDouble__SystemDouble" },
        .f64_mul => .{ .arity = .binary, .operand_ty = tn.double, .result_ty = tn.double, .sig = "SystemDouble.__op_Multiply__SystemDouble_SystemDouble__SystemDouble" },
        .f64_div => .{ .arity = .binary, .operand_ty = tn.double, .result_ty = tn.double, .sig = "SystemDouble.__op_Division__SystemDouble_SystemDouble__SystemDouble" },
        .f64_floor => .{ .arity = .unary, .operand_ty = tn.double, .result_ty = tn.double, .sig = "SystemMath.__Floor__SystemDouble__SystemDouble" },

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

test "non-numeric instructions return null" {
    try std.testing.expect(lookup(.{ .local_get = 0 }) == null);
    try std.testing.expect(lookup(.{ .i32_const = 42 }) == null);
    try std.testing.expect(lookup(.nop) == null);
}
