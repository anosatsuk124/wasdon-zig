//! Opcode table for WASM Core 1 / MVP.
//!
//! This module is the single source of truth for every opcode this parser
//! recognises. Anything that needs a full enumeration — decoder dispatch,
//! mnemonic lookup, test coverage — is derived from `spec`.
//!
//! The companion `Instruction` union in `instruction.zig` must keep its tag
//! names in sync with the `tag` column below; `comptime` checks at module load
//! time assert the correspondence.

const std = @import("std");

pub const Immediate = enum {
    none,
    labelidx, // br, br_if
    funcidx, // call
    typeidx_reserved, // call_indirect (typeidx followed by 0x00)
    localidx,
    globalidx,
    br_table,
    memarg,
    i32_imm,
    i64_imm,
    f32_imm,
    f64_imm,
    block,
    loop,
    if_,
    memory_op, // memory.size / memory.grow — consumes a reserved 0x00 byte
};

pub const OpSpec = struct {
    opcode: u8,
    tag: []const u8,
    mnemonic: []const u8,
    imm: Immediate,
};

pub const spec = [_]OpSpec{
    // --- control ---
    .{ .opcode = 0x00, .tag = "unreachable_", .mnemonic = "unreachable", .imm = .none },
    .{ .opcode = 0x01, .tag = "nop", .mnemonic = "nop", .imm = .none },
    .{ .opcode = 0x02, .tag = "block", .mnemonic = "block", .imm = .block },
    .{ .opcode = 0x03, .tag = "loop", .mnemonic = "loop", .imm = .loop },
    .{ .opcode = 0x04, .tag = "if_", .mnemonic = "if", .imm = .if_ },
    .{ .opcode = 0x0C, .tag = "br", .mnemonic = "br", .imm = .labelidx },
    .{ .opcode = 0x0D, .tag = "br_if", .mnemonic = "br_if", .imm = .labelidx },
    .{ .opcode = 0x0E, .tag = "br_table", .mnemonic = "br_table", .imm = .br_table },
    .{ .opcode = 0x0F, .tag = "return_", .mnemonic = "return", .imm = .none },
    .{ .opcode = 0x10, .tag = "call", .mnemonic = "call", .imm = .funcidx },
    .{ .opcode = 0x11, .tag = "call_indirect", .mnemonic = "call_indirect", .imm = .typeidx_reserved },

    // --- parametric ---
    .{ .opcode = 0x1A, .tag = "drop", .mnemonic = "drop", .imm = .none },
    .{ .opcode = 0x1B, .tag = "select", .mnemonic = "select", .imm = .none },

    // --- variable ---
    .{ .opcode = 0x20, .tag = "local_get", .mnemonic = "local.get", .imm = .localidx },
    .{ .opcode = 0x21, .tag = "local_set", .mnemonic = "local.set", .imm = .localidx },
    .{ .opcode = 0x22, .tag = "local_tee", .mnemonic = "local.tee", .imm = .localidx },
    .{ .opcode = 0x23, .tag = "global_get", .mnemonic = "global.get", .imm = .globalidx },
    .{ .opcode = 0x24, .tag = "global_set", .mnemonic = "global.set", .imm = .globalidx },

    // --- memory loads/stores (all take memarg) ---
    .{ .opcode = 0x28, .tag = "i32_load", .mnemonic = "i32.load", .imm = .memarg },
    .{ .opcode = 0x29, .tag = "i64_load", .mnemonic = "i64.load", .imm = .memarg },
    .{ .opcode = 0x2A, .tag = "f32_load", .mnemonic = "f32.load", .imm = .memarg },
    .{ .opcode = 0x2B, .tag = "f64_load", .mnemonic = "f64.load", .imm = .memarg },
    .{ .opcode = 0x2C, .tag = "i32_load8_s", .mnemonic = "i32.load8_s", .imm = .memarg },
    .{ .opcode = 0x2D, .tag = "i32_load8_u", .mnemonic = "i32.load8_u", .imm = .memarg },
    .{ .opcode = 0x2E, .tag = "i32_load16_s", .mnemonic = "i32.load16_s", .imm = .memarg },
    .{ .opcode = 0x2F, .tag = "i32_load16_u", .mnemonic = "i32.load16_u", .imm = .memarg },
    .{ .opcode = 0x30, .tag = "i64_load8_s", .mnemonic = "i64.load8_s", .imm = .memarg },
    .{ .opcode = 0x31, .tag = "i64_load8_u", .mnemonic = "i64.load8_u", .imm = .memarg },
    .{ .opcode = 0x32, .tag = "i64_load16_s", .mnemonic = "i64.load16_s", .imm = .memarg },
    .{ .opcode = 0x33, .tag = "i64_load16_u", .mnemonic = "i64.load16_u", .imm = .memarg },
    .{ .opcode = 0x34, .tag = "i64_load32_s", .mnemonic = "i64.load32_s", .imm = .memarg },
    .{ .opcode = 0x35, .tag = "i64_load32_u", .mnemonic = "i64.load32_u", .imm = .memarg },
    .{ .opcode = 0x36, .tag = "i32_store", .mnemonic = "i32.store", .imm = .memarg },
    .{ .opcode = 0x37, .tag = "i64_store", .mnemonic = "i64.store", .imm = .memarg },
    .{ .opcode = 0x38, .tag = "f32_store", .mnemonic = "f32.store", .imm = .memarg },
    .{ .opcode = 0x39, .tag = "f64_store", .mnemonic = "f64.store", .imm = .memarg },
    .{ .opcode = 0x3A, .tag = "i32_store8", .mnemonic = "i32.store8", .imm = .memarg },
    .{ .opcode = 0x3B, .tag = "i32_store16", .mnemonic = "i32.store16", .imm = .memarg },
    .{ .opcode = 0x3C, .tag = "i64_store8", .mnemonic = "i64.store8", .imm = .memarg },
    .{ .opcode = 0x3D, .tag = "i64_store16", .mnemonic = "i64.store16", .imm = .memarg },
    .{ .opcode = 0x3E, .tag = "i64_store32", .mnemonic = "i64.store32", .imm = .memarg },
    .{ .opcode = 0x3F, .tag = "memory_size", .mnemonic = "memory.size", .imm = .memory_op },
    .{ .opcode = 0x40, .tag = "memory_grow", .mnemonic = "memory.grow", .imm = .memory_op },

    // --- numeric constants ---
    .{ .opcode = 0x41, .tag = "i32_const", .mnemonic = "i32.const", .imm = .i32_imm },
    .{ .opcode = 0x42, .tag = "i64_const", .mnemonic = "i64.const", .imm = .i64_imm },
    .{ .opcode = 0x43, .tag = "f32_const", .mnemonic = "f32.const", .imm = .f32_imm },
    .{ .opcode = 0x44, .tag = "f64_const", .mnemonic = "f64.const", .imm = .f64_imm },

    // --- i32 tests / comparisons (0x45..0x4F) ---
    .{ .opcode = 0x45, .tag = "i32_eqz", .mnemonic = "i32.eqz", .imm = .none },
    .{ .opcode = 0x46, .tag = "i32_eq", .mnemonic = "i32.eq", .imm = .none },
    .{ .opcode = 0x47, .tag = "i32_ne", .mnemonic = "i32.ne", .imm = .none },
    .{ .opcode = 0x48, .tag = "i32_lt_s", .mnemonic = "i32.lt_s", .imm = .none },
    .{ .opcode = 0x49, .tag = "i32_lt_u", .mnemonic = "i32.lt_u", .imm = .none },
    .{ .opcode = 0x4A, .tag = "i32_gt_s", .mnemonic = "i32.gt_s", .imm = .none },
    .{ .opcode = 0x4B, .tag = "i32_gt_u", .mnemonic = "i32.gt_u", .imm = .none },
    .{ .opcode = 0x4C, .tag = "i32_le_s", .mnemonic = "i32.le_s", .imm = .none },
    .{ .opcode = 0x4D, .tag = "i32_le_u", .mnemonic = "i32.le_u", .imm = .none },
    .{ .opcode = 0x4E, .tag = "i32_ge_s", .mnemonic = "i32.ge_s", .imm = .none },
    .{ .opcode = 0x4F, .tag = "i32_ge_u", .mnemonic = "i32.ge_u", .imm = .none },

    // --- i64 tests / comparisons (0x50..0x5A) ---
    .{ .opcode = 0x50, .tag = "i64_eqz", .mnemonic = "i64.eqz", .imm = .none },
    .{ .opcode = 0x51, .tag = "i64_eq", .mnemonic = "i64.eq", .imm = .none },
    .{ .opcode = 0x52, .tag = "i64_ne", .mnemonic = "i64.ne", .imm = .none },
    .{ .opcode = 0x53, .tag = "i64_lt_s", .mnemonic = "i64.lt_s", .imm = .none },
    .{ .opcode = 0x54, .tag = "i64_lt_u", .mnemonic = "i64.lt_u", .imm = .none },
    .{ .opcode = 0x55, .tag = "i64_gt_s", .mnemonic = "i64.gt_s", .imm = .none },
    .{ .opcode = 0x56, .tag = "i64_gt_u", .mnemonic = "i64.gt_u", .imm = .none },
    .{ .opcode = 0x57, .tag = "i64_le_s", .mnemonic = "i64.le_s", .imm = .none },
    .{ .opcode = 0x58, .tag = "i64_le_u", .mnemonic = "i64.le_u", .imm = .none },
    .{ .opcode = 0x59, .tag = "i64_ge_s", .mnemonic = "i64.ge_s", .imm = .none },
    .{ .opcode = 0x5A, .tag = "i64_ge_u", .mnemonic = "i64.ge_u", .imm = .none },

    // --- f32 comparisons (0x5B..0x60) ---
    .{ .opcode = 0x5B, .tag = "f32_eq", .mnemonic = "f32.eq", .imm = .none },
    .{ .opcode = 0x5C, .tag = "f32_ne", .mnemonic = "f32.ne", .imm = .none },
    .{ .opcode = 0x5D, .tag = "f32_lt", .mnemonic = "f32.lt", .imm = .none },
    .{ .opcode = 0x5E, .tag = "f32_gt", .mnemonic = "f32.gt", .imm = .none },
    .{ .opcode = 0x5F, .tag = "f32_le", .mnemonic = "f32.le", .imm = .none },
    .{ .opcode = 0x60, .tag = "f32_ge", .mnemonic = "f32.ge", .imm = .none },

    // --- f64 comparisons (0x61..0x66) ---
    .{ .opcode = 0x61, .tag = "f64_eq", .mnemonic = "f64.eq", .imm = .none },
    .{ .opcode = 0x62, .tag = "f64_ne", .mnemonic = "f64.ne", .imm = .none },
    .{ .opcode = 0x63, .tag = "f64_lt", .mnemonic = "f64.lt", .imm = .none },
    .{ .opcode = 0x64, .tag = "f64_gt", .mnemonic = "f64.gt", .imm = .none },
    .{ .opcode = 0x65, .tag = "f64_le", .mnemonic = "f64.le", .imm = .none },
    .{ .opcode = 0x66, .tag = "f64_ge", .mnemonic = "f64.ge", .imm = .none },

    // --- i32 unary / binary (0x67..0x78) ---
    .{ .opcode = 0x67, .tag = "i32_clz", .mnemonic = "i32.clz", .imm = .none },
    .{ .opcode = 0x68, .tag = "i32_ctz", .mnemonic = "i32.ctz", .imm = .none },
    .{ .opcode = 0x69, .tag = "i32_popcnt", .mnemonic = "i32.popcnt", .imm = .none },
    .{ .opcode = 0x6A, .tag = "i32_add", .mnemonic = "i32.add", .imm = .none },
    .{ .opcode = 0x6B, .tag = "i32_sub", .mnemonic = "i32.sub", .imm = .none },
    .{ .opcode = 0x6C, .tag = "i32_mul", .mnemonic = "i32.mul", .imm = .none },
    .{ .opcode = 0x6D, .tag = "i32_div_s", .mnemonic = "i32.div_s", .imm = .none },
    .{ .opcode = 0x6E, .tag = "i32_div_u", .mnemonic = "i32.div_u", .imm = .none },
    .{ .opcode = 0x6F, .tag = "i32_rem_s", .mnemonic = "i32.rem_s", .imm = .none },
    .{ .opcode = 0x70, .tag = "i32_rem_u", .mnemonic = "i32.rem_u", .imm = .none },
    .{ .opcode = 0x71, .tag = "i32_and", .mnemonic = "i32.and", .imm = .none },
    .{ .opcode = 0x72, .tag = "i32_or", .mnemonic = "i32.or", .imm = .none },
    .{ .opcode = 0x73, .tag = "i32_xor", .mnemonic = "i32.xor", .imm = .none },
    .{ .opcode = 0x74, .tag = "i32_shl", .mnemonic = "i32.shl", .imm = .none },
    .{ .opcode = 0x75, .tag = "i32_shr_s", .mnemonic = "i32.shr_s", .imm = .none },
    .{ .opcode = 0x76, .tag = "i32_shr_u", .mnemonic = "i32.shr_u", .imm = .none },
    .{ .opcode = 0x77, .tag = "i32_rotl", .mnemonic = "i32.rotl", .imm = .none },
    .{ .opcode = 0x78, .tag = "i32_rotr", .mnemonic = "i32.rotr", .imm = .none },

    // --- i64 unary / binary (0x79..0x8A) ---
    .{ .opcode = 0x79, .tag = "i64_clz", .mnemonic = "i64.clz", .imm = .none },
    .{ .opcode = 0x7A, .tag = "i64_ctz", .mnemonic = "i64.ctz", .imm = .none },
    .{ .opcode = 0x7B, .tag = "i64_popcnt", .mnemonic = "i64.popcnt", .imm = .none },
    .{ .opcode = 0x7C, .tag = "i64_add", .mnemonic = "i64.add", .imm = .none },
    .{ .opcode = 0x7D, .tag = "i64_sub", .mnemonic = "i64.sub", .imm = .none },
    .{ .opcode = 0x7E, .tag = "i64_mul", .mnemonic = "i64.mul", .imm = .none },
    .{ .opcode = 0x7F, .tag = "i64_div_s", .mnemonic = "i64.div_s", .imm = .none },
    .{ .opcode = 0x80, .tag = "i64_div_u", .mnemonic = "i64.div_u", .imm = .none },
    .{ .opcode = 0x81, .tag = "i64_rem_s", .mnemonic = "i64.rem_s", .imm = .none },
    .{ .opcode = 0x82, .tag = "i64_rem_u", .mnemonic = "i64.rem_u", .imm = .none },
    .{ .opcode = 0x83, .tag = "i64_and", .mnemonic = "i64.and", .imm = .none },
    .{ .opcode = 0x84, .tag = "i64_or", .mnemonic = "i64.or", .imm = .none },
    .{ .opcode = 0x85, .tag = "i64_xor", .mnemonic = "i64.xor", .imm = .none },
    .{ .opcode = 0x86, .tag = "i64_shl", .mnemonic = "i64.shl", .imm = .none },
    .{ .opcode = 0x87, .tag = "i64_shr_s", .mnemonic = "i64.shr_s", .imm = .none },
    .{ .opcode = 0x88, .tag = "i64_shr_u", .mnemonic = "i64.shr_u", .imm = .none },
    .{ .opcode = 0x89, .tag = "i64_rotl", .mnemonic = "i64.rotl", .imm = .none },
    .{ .opcode = 0x8A, .tag = "i64_rotr", .mnemonic = "i64.rotr", .imm = .none },

    // --- f32 unary / binary (0x8B..0x98) ---
    .{ .opcode = 0x8B, .tag = "f32_abs", .mnemonic = "f32.abs", .imm = .none },
    .{ .opcode = 0x8C, .tag = "f32_neg", .mnemonic = "f32.neg", .imm = .none },
    .{ .opcode = 0x8D, .tag = "f32_ceil", .mnemonic = "f32.ceil", .imm = .none },
    .{ .opcode = 0x8E, .tag = "f32_floor", .mnemonic = "f32.floor", .imm = .none },
    .{ .opcode = 0x8F, .tag = "f32_trunc", .mnemonic = "f32.trunc", .imm = .none },
    .{ .opcode = 0x90, .tag = "f32_nearest", .mnemonic = "f32.nearest", .imm = .none },
    .{ .opcode = 0x91, .tag = "f32_sqrt", .mnemonic = "f32.sqrt", .imm = .none },
    .{ .opcode = 0x92, .tag = "f32_add", .mnemonic = "f32.add", .imm = .none },
    .{ .opcode = 0x93, .tag = "f32_sub", .mnemonic = "f32.sub", .imm = .none },
    .{ .opcode = 0x94, .tag = "f32_mul", .mnemonic = "f32.mul", .imm = .none },
    .{ .opcode = 0x95, .tag = "f32_div", .mnemonic = "f32.div", .imm = .none },
    .{ .opcode = 0x96, .tag = "f32_min", .mnemonic = "f32.min", .imm = .none },
    .{ .opcode = 0x97, .tag = "f32_max", .mnemonic = "f32.max", .imm = .none },
    .{ .opcode = 0x98, .tag = "f32_copysign", .mnemonic = "f32.copysign", .imm = .none },

    // --- f64 unary / binary (0x99..0xA6) ---
    .{ .opcode = 0x99, .tag = "f64_abs", .mnemonic = "f64.abs", .imm = .none },
    .{ .opcode = 0x9A, .tag = "f64_neg", .mnemonic = "f64.neg", .imm = .none },
    .{ .opcode = 0x9B, .tag = "f64_ceil", .mnemonic = "f64.ceil", .imm = .none },
    .{ .opcode = 0x9C, .tag = "f64_floor", .mnemonic = "f64.floor", .imm = .none },
    .{ .opcode = 0x9D, .tag = "f64_trunc", .mnemonic = "f64.trunc", .imm = .none },
    .{ .opcode = 0x9E, .tag = "f64_nearest", .mnemonic = "f64.nearest", .imm = .none },
    .{ .opcode = 0x9F, .tag = "f64_sqrt", .mnemonic = "f64.sqrt", .imm = .none },
    .{ .opcode = 0xA0, .tag = "f64_add", .mnemonic = "f64.add", .imm = .none },
    .{ .opcode = 0xA1, .tag = "f64_sub", .mnemonic = "f64.sub", .imm = .none },
    .{ .opcode = 0xA2, .tag = "f64_mul", .mnemonic = "f64.mul", .imm = .none },
    .{ .opcode = 0xA3, .tag = "f64_div", .mnemonic = "f64.div", .imm = .none },
    .{ .opcode = 0xA4, .tag = "f64_min", .mnemonic = "f64.min", .imm = .none },
    .{ .opcode = 0xA5, .tag = "f64_max", .mnemonic = "f64.max", .imm = .none },
    .{ .opcode = 0xA6, .tag = "f64_copysign", .mnemonic = "f64.copysign", .imm = .none },

    // --- conversion / reinterpretation (0xA7..0xBF) ---
    .{ .opcode = 0xA7, .tag = "i32_wrap_i64", .mnemonic = "i32.wrap_i64", .imm = .none },
    .{ .opcode = 0xA8, .tag = "i32_trunc_f32_s", .mnemonic = "i32.trunc_f32_s", .imm = .none },
    .{ .opcode = 0xA9, .tag = "i32_trunc_f32_u", .mnemonic = "i32.trunc_f32_u", .imm = .none },
    .{ .opcode = 0xAA, .tag = "i32_trunc_f64_s", .mnemonic = "i32.trunc_f64_s", .imm = .none },
    .{ .opcode = 0xAB, .tag = "i32_trunc_f64_u", .mnemonic = "i32.trunc_f64_u", .imm = .none },
    .{ .opcode = 0xAC, .tag = "i64_extend_i32_s", .mnemonic = "i64.extend_i32_s", .imm = .none },
    .{ .opcode = 0xAD, .tag = "i64_extend_i32_u", .mnemonic = "i64.extend_i32_u", .imm = .none },
    .{ .opcode = 0xAE, .tag = "i64_trunc_f32_s", .mnemonic = "i64.trunc_f32_s", .imm = .none },
    .{ .opcode = 0xAF, .tag = "i64_trunc_f32_u", .mnemonic = "i64.trunc_f32_u", .imm = .none },
    .{ .opcode = 0xB0, .tag = "i64_trunc_f64_s", .mnemonic = "i64.trunc_f64_s", .imm = .none },
    .{ .opcode = 0xB1, .tag = "i64_trunc_f64_u", .mnemonic = "i64.trunc_f64_u", .imm = .none },
    .{ .opcode = 0xB2, .tag = "f32_convert_i32_s", .mnemonic = "f32.convert_i32_s", .imm = .none },
    .{ .opcode = 0xB3, .tag = "f32_convert_i32_u", .mnemonic = "f32.convert_i32_u", .imm = .none },
    .{ .opcode = 0xB4, .tag = "f32_convert_i64_s", .mnemonic = "f32.convert_i64_s", .imm = .none },
    .{ .opcode = 0xB5, .tag = "f32_convert_i64_u", .mnemonic = "f32.convert_i64_u", .imm = .none },
    .{ .opcode = 0xB6, .tag = "f32_demote_f64", .mnemonic = "f32.demote_f64", .imm = .none },
    .{ .opcode = 0xB7, .tag = "f64_convert_i32_s", .mnemonic = "f64.convert_i32_s", .imm = .none },
    .{ .opcode = 0xB8, .tag = "f64_convert_i32_u", .mnemonic = "f64.convert_i32_u", .imm = .none },
    .{ .opcode = 0xB9, .tag = "f64_convert_i64_s", .mnemonic = "f64.convert_i64_s", .imm = .none },
    .{ .opcode = 0xBA, .tag = "f64_convert_i64_u", .mnemonic = "f64.convert_i64_u", .imm = .none },
    .{ .opcode = 0xBB, .tag = "f64_promote_f32", .mnemonic = "f64.promote_f32", .imm = .none },
    .{ .opcode = 0xBC, .tag = "i32_reinterpret_f32", .mnemonic = "i32.reinterpret_f32", .imm = .none },
    .{ .opcode = 0xBD, .tag = "i64_reinterpret_f64", .mnemonic = "i64.reinterpret_f64", .imm = .none },
    .{ .opcode = 0xBE, .tag = "f32_reinterpret_i32", .mnemonic = "f32.reinterpret_i32", .imm = .none },
    .{ .opcode = 0xBF, .tag = "f64_reinterpret_i64", .mnemonic = "f64.reinterpret_i64", .imm = .none },
};

/// Find the spec entry for a byte. Returns `null` if the byte is not a known
/// Core 1 opcode.
pub fn find(opcode: u8) ?OpSpec {
    inline for (spec) |s| {
        if (s.opcode == opcode) return s;
    }
    return null;
}

/// O(1) mnemonic lookup by tag (comptime-known).
pub fn mnemonicFor(comptime tag: []const u8) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(10_000);
        for (spec) |s| {
            if (std.mem.eql(u8, s.tag, tag)) break :blk s.mnemonic;
        }
        @compileError("unknown instruction tag: " ++ tag);
    };
}

// ---------------- tests ----------------

test "opcode table: all opcodes unique" {
    @setEvalBranchQuota(50_000);
    comptime {
        for (spec, 0..) |a, i| {
            for (spec[i + 1 ..]) |b| {
                if (a.opcode == b.opcode) @compileError("duplicate opcode");
            }
        }
    }
}

test "opcode table: expected count (Core 1 MVP)" {
    // 11 control + 2 parametric + 5 variable + 25 memory + 4 numeric-const
    // + 11 i32 cmp + 11 i64 cmp + 6 f32 cmp + 6 f64 cmp
    // + 18 i32 arith + 18 i64 arith + 14 f32 arith + 14 f64 arith + 25 conv
    // = 170
    try std.testing.expectEqual(@as(usize, 170), spec.len);
}

test "opcode table: critical entries present" {
    try std.testing.expect(find(0x00) != null);
    try std.testing.expect(std.mem.eql(u8, find(0x00).?.tag, "unreachable_"));
    try std.testing.expect(std.mem.eql(u8, find(0x41).?.tag, "i32_const"));
    try std.testing.expect(std.mem.eql(u8, find(0x11).?.tag, "call_indirect"));
    try std.testing.expect(find(0x11).?.imm == .typeidx_reserved);
    try std.testing.expect(find(0x3F).?.imm == .memory_op);
    try std.testing.expect(find(0xBF) != null);
    // Unknown
    try std.testing.expect(find(0x05) == null);
    try std.testing.expect(find(0x12) == null);
    try std.testing.expect(find(0xC0) == null);
}

test "mnemonicFor returns canonical mnemonic" {
    try std.testing.expectEqualStrings("i32.const", mnemonicFor("i32_const"));
    try std.testing.expectEqualStrings("call_indirect", mnemonicFor("call_indirect"));
    try std.testing.expectEqualStrings("memory.size", mnemonicFor("memory_size"));
}
