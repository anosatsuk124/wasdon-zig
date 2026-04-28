//! Instruction union and decoder.
//!
//! The `Instruction` union below has one variant per entry in
//! `opcode.spec`. A `comptime` check at module load enforces that invariant,
//! so if the spec table grows or is renamed, this file fails to compile until
//! both halves are realigned.
//!
//! Decoder dispatch is driven directly off `opcode.spec` via `inline for`,
//! keeping the per-opcode logic centralised in the immediate-kind switch.

const std = @import("std");
const errors = @import("errors.zig");
const Reader = @import("reader.zig").Reader;
const leb128 = @import("leb128.zig");
const types = @import("types.zig");
const opcode = @import("opcode.zig");

pub const MemArg = struct {
    @"align": u32,
    offset: u32,
};

pub const BrTable = struct {
    labels: []const u32,
    default: u32,
};

pub const Block = struct {
    bt: types.BlockType,
    body: []const Instruction,
};

pub const If = struct {
    bt: types.BlockType,
    then_body: []const Instruction,
    else_body: ?[]const Instruction,
};

pub const MemoryCopyArgs = struct {
    src_mem: u32,
    dst_mem: u32,
};

pub const MemoryFillArgs = struct {
    mem: u32,
};

/// One variant per Core 1 opcode. Keep in lockstep with `opcode.spec`.
pub const Instruction = union(enum) {
    // control
    unreachable_,
    nop,
    block: Block,
    loop: Block,
    if_: If,
    br: u32,
    br_if: u32,
    br_table: BrTable,
    return_,
    call: u32,
    call_indirect: u32,

    // parametric
    drop,
    select,

    // variable
    local_get: u32,
    local_set: u32,
    local_tee: u32,
    global_get: u32,
    global_set: u32,

    // memory loads / stores
    i32_load: MemArg,
    i64_load: MemArg,
    f32_load: MemArg,
    f64_load: MemArg,
    i32_load8_s: MemArg,
    i32_load8_u: MemArg,
    i32_load16_s: MemArg,
    i32_load16_u: MemArg,
    i64_load8_s: MemArg,
    i64_load8_u: MemArg,
    i64_load16_s: MemArg,
    i64_load16_u: MemArg,
    i64_load32_s: MemArg,
    i64_load32_u: MemArg,
    i32_store: MemArg,
    i64_store: MemArg,
    f32_store: MemArg,
    f64_store: MemArg,
    i32_store8: MemArg,
    i32_store16: MemArg,
    i64_store8: MemArg,
    i64_store16: MemArg,
    i64_store32: MemArg,
    memory_size,
    memory_grow,

    // numeric constants
    i32_const: i32,
    i64_const: i64,
    f32_const: f32,
    f64_const: f64,

    // i32 tests / comparisons
    i32_eqz,
    i32_eq,
    i32_ne,
    i32_lt_s,
    i32_lt_u,
    i32_gt_s,
    i32_gt_u,
    i32_le_s,
    i32_le_u,
    i32_ge_s,
    i32_ge_u,

    // i64 tests / comparisons
    i64_eqz,
    i64_eq,
    i64_ne,
    i64_lt_s,
    i64_lt_u,
    i64_gt_s,
    i64_gt_u,
    i64_le_s,
    i64_le_u,
    i64_ge_s,
    i64_ge_u,

    // f32 comparisons
    f32_eq,
    f32_ne,
    f32_lt,
    f32_gt,
    f32_le,
    f32_ge,

    // f64 comparisons
    f64_eq,
    f64_ne,
    f64_lt,
    f64_gt,
    f64_le,
    f64_ge,

    // i32 unary / binary
    i32_clz,
    i32_ctz,
    i32_popcnt,
    i32_add,
    i32_sub,
    i32_mul,
    i32_div_s,
    i32_div_u,
    i32_rem_s,
    i32_rem_u,
    i32_and,
    i32_or,
    i32_xor,
    i32_shl,
    i32_shr_s,
    i32_shr_u,
    i32_rotl,
    i32_rotr,

    // i64 unary / binary
    i64_clz,
    i64_ctz,
    i64_popcnt,
    i64_add,
    i64_sub,
    i64_mul,
    i64_div_s,
    i64_div_u,
    i64_rem_s,
    i64_rem_u,
    i64_and,
    i64_or,
    i64_xor,
    i64_shl,
    i64_shr_s,
    i64_shr_u,
    i64_rotl,
    i64_rotr,

    // f32 unary / binary
    f32_abs,
    f32_neg,
    f32_ceil,
    f32_floor,
    f32_trunc,
    f32_nearest,
    f32_sqrt,
    f32_add,
    f32_sub,
    f32_mul,
    f32_div,
    f32_min,
    f32_max,
    f32_copysign,

    // f64 unary / binary
    f64_abs,
    f64_neg,
    f64_ceil,
    f64_floor,
    f64_trunc,
    f64_nearest,
    f64_sqrt,
    f64_add,
    f64_sub,
    f64_mul,
    f64_div,
    f64_min,
    f64_max,
    f64_copysign,

    // conversion / reinterpretation
    i32_wrap_i64,
    i32_trunc_f32_s,
    i32_trunc_f32_u,
    i32_trunc_f64_s,
    i32_trunc_f64_u,
    i64_extend_i32_s,
    i64_extend_i32_u,
    i64_trunc_f32_s,
    i64_trunc_f32_u,
    i64_trunc_f64_s,
    i64_trunc_f64_u,
    f32_convert_i32_s,
    f32_convert_i32_u,
    f32_convert_i64_s,
    f32_convert_i64_u,
    f32_demote_f64,
    f64_convert_i32_s,
    f64_convert_i32_u,
    f64_convert_i64_s,
    f64_convert_i64_u,
    f64_promote_f32,
    i32_reinterpret_f32,
    i64_reinterpret_f64,
    f32_reinterpret_i32,
    f64_reinterpret_i64,

    // sign-extension operators (0xC0..0xC4)
    i32_extend8_s,
    i32_extend16_s,
    i64_extend8_s,
    i64_extend16_s,
    i64_extend32_s,

    // 0xFC-prefixed: saturating truncation (0xFC 0x00..0x07)
    i32_trunc_sat_f32_s,
    i32_trunc_sat_f32_u,
    i32_trunc_sat_f64_s,
    i32_trunc_sat_f64_u,
    i64_trunc_sat_f32_s,
    i64_trunc_sat_f32_u,
    i64_trunc_sat_f64_s,
    i64_trunc_sat_f64_u,

    // 0xFC-prefixed: bulk memory subset
    memory_copy: MemoryCopyArgs,
    memory_fill: MemoryFillArgs,
};

// Compile-time invariant: every opcode in `spec` and every entry in
// `prefix_fc_spec` has a matching union tag, and the union has exactly the
// same number of fields as the combined spec lengths.
comptime {
    @setEvalBranchQuota(100_000);
    const union_fields = @typeInfo(Instruction).@"union".fields;
    const expected = opcode.spec.len + opcode.prefix_fc_spec.len;
    if (union_fields.len != expected) {
        @compileError("Instruction union field count does not match opcode.spec + prefix_fc_spec length");
    }
    for (opcode.spec) |s| {
        var found = false;
        for (union_fields) |f| {
            if (std.mem.eql(u8, f.name, s.tag)) {
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError("opcode.spec tag missing from Instruction union: " ++ s.tag);
        }
    }
    for (opcode.prefix_fc_spec) |s| {
        var found = false;
        for (union_fields) |f| {
            if (std.mem.eql(u8, f.name, s.tag)) {
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError("opcode.prefix_fc_spec tag missing from Instruction union: " ++ s.tag);
        }
    }
}

fn readMemArg(r: *Reader) errors.ParseError!MemArg {
    const a = try leb128.readULEB128(u32, r);
    const o = try leb128.readULEB128(u32, r);
    return .{ .@"align" = a, .offset = o };
}

fn readBrTable(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!BrTable {
    const n = try leb128.readULEB128(u32, r);
    const labels = try allocator.alloc(u32, n);
    errdefer allocator.free(labels);
    for (labels) |*l| l.* = try leb128.readULEB128(u32, r);
    const default = try leb128.readULEB128(u32, r);
    return .{ .labels = labels, .default = default };
}

/// Decode a single instruction. For structured control instructions this
/// recursively decodes the nested body until the matching `end` (0x0B), or
/// until `else` (0x05) for the `if`-then branch.
pub fn decodeInstruction(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!Instruction {
    const op = try r.readByte();

    // 0x05 (else) and 0x0B (end) are terminators; they must never appear as
    // standalone instructions at this layer.
    if (op == 0x0B) return error.UnexpectedEndOpcode;
    if (op == 0x05) return error.UnexpectedElseOpcode;

    // 0xFC-prefixed family: read sub-opcode (u32 LEB128) and dispatch through
    // `prefix_fc_spec`. Currently covers saturating truncation (0x00..0x07)
    // and the bulk-memory subset memory.copy / memory.fill.
    if (op == 0xFC) {
        const sub = try leb128.readULEB128(u32, r);
        const fc_spec = opcode.findPrefixFc(sub) orelse return error.UnknownPrefixedOpcode;
        inline for (opcode.prefix_fc_spec) |s| {
            if (comptime s.imm == .none) {
                if (s.opcode == fc_spec.opcode) {
                    return @unionInit(Instruction, s.tag, {});
                }
            } else if (comptime s.imm == .memory_copy_args) {
                if (s.opcode == fc_spec.opcode) {
                    const src = try r.readByte();
                    if (src != 0x00) return error.MalformedReserved;
                    const dst = try r.readByte();
                    if (dst != 0x00) return error.MalformedReserved;
                    return @unionInit(Instruction, s.tag, MemoryCopyArgs{
                        .src_mem = 0,
                        .dst_mem = 0,
                    });
                }
            } else if (comptime s.imm == .memory_fill_args) {
                if (s.opcode == fc_spec.opcode) {
                    const reserved = try r.readByte();
                    if (reserved != 0x00) return error.MalformedReserved;
                    return @unionInit(Instruction, s.tag, MemoryFillArgs{ .mem = 0 });
                }
            }
        }
        // Unreachable: findPrefixFc returned non-null, so the loop above must
        // have matched. Defensive fall-through in case prefix_fc_spec gains
        // a new immediate kind that this dispatch hasn't been taught yet.
        return error.UnknownPrefixedOpcode;
    }

    inline for (opcode.spec) |s| {
        if (s.opcode == op) {
            switch (s.imm) {
                .none => return @unionInit(Instruction, s.tag, {}),
                .labelidx, .funcidx, .localidx, .globalidx => {
                    const idx = try leb128.readULEB128(u32, r);
                    return @unionInit(Instruction, s.tag, idx);
                },
                .typeidx_reserved => {
                    const tidx = try leb128.readULEB128(u32, r);
                    const reserved = try r.readByte();
                    if (reserved != 0x00) return error.MalformedReserved;
                    return @unionInit(Instruction, s.tag, tidx);
                },
                .br_table => {
                    const bt = try readBrTable(allocator, r);
                    return @unionInit(Instruction, s.tag, bt);
                },
                .memarg => {
                    const m = try readMemArg(r);
                    return @unionInit(Instruction, s.tag, m);
                },
                .memory_op => {
                    const reserved = try r.readByte();
                    if (reserved != 0x00) return error.MalformedReserved;
                    return @unionInit(Instruction, s.tag, {});
                },
                // memory_copy_args / memory_fill_args are only used by entries
                // in `prefix_fc_spec`, which is dispatched separately above.
                // No primary-spec entry should ever reach these arms.
                .memory_copy_args, .memory_fill_args => unreachable,
                .i32_imm => {
                    const v = try leb128.readSLEB128(i32, r);
                    return @unionInit(Instruction, s.tag, v);
                },
                .i64_imm => {
                    const v = try leb128.readSLEB128(i64, r);
                    return @unionInit(Instruction, s.tag, v);
                },
                .f32_imm => {
                    const bytes = try r.readBytes(4);
                    const bits = std.mem.readInt(u32, bytes[0..4], .little);
                    const v: f32 = @bitCast(bits);
                    return @unionInit(Instruction, s.tag, v);
                },
                .f64_imm => {
                    const bytes = try r.readBytes(8);
                    const bits = std.mem.readInt(u64, bytes[0..8], .little);
                    const v: f64 = @bitCast(bits);
                    return @unionInit(Instruction, s.tag, v);
                },
                .block => {
                    const bt = try types.decodeBlockType(r);
                    const body = try decodeInstrSequenceUntil(allocator, r, .end_only);
                    return @unionInit(Instruction, s.tag, Block{ .bt = bt, .body = body.instrs });
                },
                .loop => {
                    const bt = try types.decodeBlockType(r);
                    const body = try decodeInstrSequenceUntil(allocator, r, .end_only);
                    return @unionInit(Instruction, s.tag, Block{ .bt = bt, .body = body.instrs });
                },
                .if_ => {
                    const bt = try types.decodeBlockType(r);
                    const then_seq = try decodeInstrSequenceUntil(allocator, r, .end_or_else);
                    var else_body: ?[]const Instruction = null;
                    if (then_seq.terminator == .else_) {
                        const else_seq = try decodeInstrSequenceUntil(allocator, r, .end_only);
                        else_body = else_seq.instrs;
                    }
                    return @unionInit(Instruction, s.tag, If{
                        .bt = bt,
                        .then_body = then_seq.instrs,
                        .else_body = else_body,
                    });
                },
            }
        }
    }
    return error.UnknownOpcode;
}

const SequenceTerminator = enum { end_only, end_or_else };
const ActualTerminator = enum { end, else_ };
const DecodedSequence = struct {
    instrs: []const Instruction,
    terminator: ActualTerminator,
};

fn decodeInstrSequenceUntil(
    allocator: std.mem.Allocator,
    r: *Reader,
    allowed: SequenceTerminator,
) errors.ParseError!DecodedSequence {
    var list: std.ArrayList(Instruction) = .empty;
    errdefer list.deinit(allocator);

    while (true) {
        const op = try r.peekByte();
        if (op == 0x0B) {
            _ = try r.readByte();
            return .{ .instrs = try list.toOwnedSlice(allocator), .terminator = .end };
        }
        if (op == 0x05) {
            if (allowed != .end_or_else) return error.UnexpectedElseOpcode;
            _ = try r.readByte();
            return .{ .instrs = try list.toOwnedSlice(allocator), .terminator = .else_ };
        }
        const inst = try decodeInstruction(allocator, r);
        try list.append(allocator, inst);
    }
}

/// Decode an `expr` — an instruction sequence terminated by `end` (0x0B).
pub fn decodeExpr(allocator: std.mem.Allocator, r: *Reader) errors.ParseError![]const Instruction {
    const seq = try decodeInstrSequenceUntil(allocator, r, .end_only);
    return seq.instrs;
}

// ---------------- tests ----------------

fn mk(bytes: []const u8) Reader {
    return Reader.init(bytes);
}

test "Instruction union matches opcode.spec length" {
    const union_fields = @typeInfo(Instruction).@"union".fields;
    try std.testing.expectEqual(opcode.spec.len + opcode.prefix_fc_spec.len, union_fields.len);
}

test "decode nop" {
    var r = mk(&[_]u8{0x01});
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .nop);
}

test "decode unreachable" {
    var r = mk(&[_]u8{0x00});
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .unreachable_);
}

test "decode i32.const negative" {
    // 0x41 sleb128(-1) = 41 7F
    var r = mk(&[_]u8{ 0x41, 0x7F });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expectEqual(@as(i32, -1), inst.i32_const);
}

test "decode i32.const 624485" {
    // ULEB-equivalent bytes but for sleb: 624485 = FF E5 8E 26? Let's just
    // use the LEB bytes from the spec example reversed for signed form:
    // 624485 is positive and fits in 24 bits, sleb: E5 8E 26 (since bit 21 == 0).
    var r = mk(&[_]u8{ 0x41, 0xE5, 0x8E, 0x26 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expectEqual(@as(i32, 624485), inst.i32_const);
}

test "decode i64.const" {
    var r = mk(&[_]u8{ 0x42, 0x7F });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expectEqual(@as(i64, -1), inst.i64_const);
}

test "decode f32.const" {
    // 1.0f → 0x3F800000 little-endian: 00 00 80 3F
    var r = mk(&[_]u8{ 0x43, 0x00, 0x00, 0x80, 0x3F });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expectEqual(@as(f32, 1.0), inst.f32_const);
}

test "decode f64.const" {
    // 1.0 → 0x3FF0000000000000 little-endian: 00 00 00 00 00 00 F0 3F
    var r = mk(&[_]u8{ 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expectEqual(@as(f64, 1.0), inst.f64_const);
}

test "decode local.get 5" {
    var r = mk(&[_]u8{ 0x20, 0x05 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expectEqual(@as(u32, 5), inst.local_get);
}

test "decode memory.size" {
    var r = mk(&[_]u8{ 0x3F, 0x00 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .memory_size);
}

test "decode memory.size with bad reserved byte" {
    var r = mk(&[_]u8{ 0x3F, 0x01 });
    try std.testing.expectError(
        error.MalformedReserved,
        decodeInstruction(std.testing.allocator, &r),
    );
}

test "decode memory.grow" {
    var r = mk(&[_]u8{ 0x40, 0x00 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .memory_grow);
}

test "decode call_indirect" {
    var r = mk(&[_]u8{ 0x11, 0x07, 0x00 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expectEqual(@as(u32, 7), inst.call_indirect);
}

test "decode call_indirect bad reserved" {
    var r = mk(&[_]u8{ 0x11, 0x07, 0x01 });
    try std.testing.expectError(
        error.MalformedReserved,
        decodeInstruction(std.testing.allocator, &r),
    );
}

test "decode br_table" {
    // br_table [3, 1] default=2
    var r = mk(&[_]u8{ 0x0E, 0x02, 0x03, 0x01, 0x02 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    defer std.testing.allocator.free(inst.br_table.labels);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 3, 1 }, inst.br_table.labels);
    try std.testing.expectEqual(@as(u32, 2), inst.br_table.default);
}

test "decode load instruction (memarg)" {
    // i32.load align=2 offset=4 → 28 02 04
    var r = mk(&[_]u8{ 0x28, 0x02, 0x04 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expectEqual(@as(u32, 2), inst.i32_load.@"align");
    try std.testing.expectEqual(@as(u32, 4), inst.i32_load.offset);
}

test "decode unknown opcode rejected" {
    var r = mk(&[_]u8{0x05});
    try std.testing.expectError(
        error.UnexpectedElseOpcode,
        decodeInstruction(std.testing.allocator, &r),
    );
    // 0xC5 is the first byte past the sign-extension block (0xC0..0xC4) and
    // is still unassigned in Core 1, so it remains UnknownOpcode.
    var r2 = mk(&[_]u8{0xC5});
    try std.testing.expectError(error.UnknownOpcode, decodeInstruction(std.testing.allocator, &r2));
}

test "decodeInstruction handles i32.extend8_s (0xC0)" {
    var r = mk(&[_]u8{0xC0});
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .i32_extend8_s);
}

test "decodeInstruction handles i32.extend16_s (0xC1)" {
    var r = mk(&[_]u8{0xC1});
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .i32_extend16_s);
}

test "decodeInstruction handles i64.extend8_s (0xC2)" {
    var r = mk(&[_]u8{0xC2});
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .i64_extend8_s);
}

test "decodeInstruction handles i64.extend16_s (0xC3)" {
    var r = mk(&[_]u8{0xC3});
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .i64_extend16_s);
}

test "decodeInstruction handles i64.extend32_s (0xC4)" {
    var r = mk(&[_]u8{0xC4});
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .i64_extend32_s);
}

test "decodeInstruction handles memory.copy (0xFC 0x0A 0x00 0x00)" {
    var r = mk(&[_]u8{ 0xFC, 0x0A, 0x00, 0x00 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expectEqual(@as(u32, 0), inst.memory_copy.src_mem);
    try std.testing.expectEqual(@as(u32, 0), inst.memory_copy.dst_mem);
}

test "decodeInstruction handles memory.fill (0xFC 0x0B 0x00)" {
    var r = mk(&[_]u8{ 0xFC, 0x0B, 0x00 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expectEqual(@as(u32, 0), inst.memory_fill.mem);
}

test "decodeInstruction handles i32.trunc_sat_f32_s (0xFC 0x00)" {
    var r = mk(&[_]u8{ 0xFC, 0x00 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .i32_trunc_sat_f32_s);
}

test "decodeInstruction handles i64.trunc_sat_f64_u (0xFC 0x07)" {
    var r = mk(&[_]u8{ 0xFC, 0x07 });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    try std.testing.expect(inst == .i64_trunc_sat_f64_u);
}

test "decodeInstruction rejects unknown 0xFC sub-opcode" {
    var r = mk(&[_]u8{ 0xFC, 0x7F });
    try std.testing.expectError(
        error.UnknownPrefixedOpcode,
        decodeInstruction(std.testing.allocator, &r),
    );
}

test "decodeInstruction rejects bad reserved byte in memory.copy" {
    var r = mk(&[_]u8{ 0xFC, 0x0A, 0x01, 0x00 });
    try std.testing.expectError(
        error.MalformedReserved,
        decodeInstruction(std.testing.allocator, &r),
    );
}

test "decodeExpr empty" {
    var r = mk(&[_]u8{0x0B});
    const instrs = try decodeExpr(std.testing.allocator, &r);
    defer std.testing.allocator.free(instrs);
    try std.testing.expectEqual(@as(usize, 0), instrs.len);
}

test "decodeExpr i32.const 42; end" {
    // 41 2A 0B → i32.const 42, end
    var r = mk(&[_]u8{ 0x41, 0x2A, 0x0B });
    const instrs = try decodeExpr(std.testing.allocator, &r);
    defer std.testing.allocator.free(instrs);
    try std.testing.expectEqual(@as(usize, 1), instrs.len);
    try std.testing.expectEqual(@as(i32, 42), instrs[0].i32_const);
}

test "decode block with inner body" {
    // block (empty result) i32.const 7 i32.const 8 i32.add end
    // 02 40 41 07 41 08 6A 0B
    var r = mk(&[_]u8{ 0x02, 0x40, 0x41, 0x07, 0x41, 0x08, 0x6A, 0x0B });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    defer std.testing.allocator.free(inst.block.body);
    try std.testing.expect(inst.block.bt == .empty);
    try std.testing.expectEqual(@as(usize, 3), inst.block.body.len);
    try std.testing.expectEqual(@as(i32, 7), inst.block.body[0].i32_const);
    try std.testing.expectEqual(@as(i32, 8), inst.block.body[1].i32_const);
    try std.testing.expect(inst.block.body[2] == .i32_add);
}

test "decode if with else" {
    // if i32 (result) then i32.const 1 else i32.const 2 end
    // 04 7F 41 01 05 41 02 0B
    var r = mk(&[_]u8{ 0x04, 0x7F, 0x41, 0x01, 0x05, 0x41, 0x02, 0x0B });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    defer {
        std.testing.allocator.free(inst.if_.then_body);
        if (inst.if_.else_body) |eb| std.testing.allocator.free(eb);
    }
    try std.testing.expect(inst.if_.bt.value == .i32);
    try std.testing.expectEqual(@as(usize, 1), inst.if_.then_body.len);
    try std.testing.expectEqual(@as(i32, 1), inst.if_.then_body[0].i32_const);
    try std.testing.expect(inst.if_.else_body != null);
    try std.testing.expectEqual(@as(usize, 1), inst.if_.else_body.?.len);
    try std.testing.expectEqual(@as(i32, 2), inst.if_.else_body.?[0].i32_const);
}

test "decode if without else" {
    // if void then nop end → 04 40 01 0B
    var r = mk(&[_]u8{ 0x04, 0x40, 0x01, 0x0B });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    defer std.testing.allocator.free(inst.if_.then_body);
    try std.testing.expect(inst.if_.bt == .empty);
    try std.testing.expectEqual(@as(usize, 1), inst.if_.then_body.len);
    try std.testing.expect(inst.if_.then_body[0] == .nop);
    try std.testing.expect(inst.if_.else_body == null);
}

test "decode nested loop inside block" {
    // block void
    //   loop void
    //     br 1
    //   end
    // end
    // 02 40 03 40 0C 01 0B 0B
    var r = mk(&[_]u8{ 0x02, 0x40, 0x03, 0x40, 0x0C, 0x01, 0x0B, 0x0B });
    const inst = try decodeInstruction(std.testing.allocator, &r);
    defer {
        // Outer block body holds one loop; recursively free.
        std.testing.allocator.free(inst.block.body[0].loop.body);
        std.testing.allocator.free(inst.block.body);
    }
    try std.testing.expectEqual(@as(usize, 1), inst.block.body.len);
    try std.testing.expect(inst.block.body[0] == .loop);
    try std.testing.expectEqual(@as(usize, 1), inst.block.body[0].loop.body.len);
    try std.testing.expectEqual(@as(u32, 1), inst.block.body[0].loop.body[0].br);
}
