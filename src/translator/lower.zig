//! Function-body lowering: WASM instructions → Udon instructions.
//!
//! WASM is a stack machine; Udon has no value stack, only heap slots and
//! `EXTERN`. The lowerer therefore tracks the WASM operand stack at
//! translation time. Each stack entry says *where its value can be read* —
//! a constant, a local's slot, a shared slot, or a temporary — and code is
//! emitted only when a value has to be computed:
//!
//!     local.get a ; local.get b ; i32.add ; local.set c
//!
//! becomes a single extern call, `PUSH a; PUSH b; PUSH c; EXTERN add`:
//! the two `local.get`s only push entries, `i32.add` reads the slots
//! directly, and `local.set` retargets the add's result slot instead of
//! copying a temporary.
//!
//! Invariants that keep this sound:
//!   * An entry that aliases a slot something is about to overwrite is
//!     copied to a temporary first (`flushLocal`, `flushShared`).
//!   * At control-flow joins values live in temporaries the joining paths
//!     agree on (`Ctrl.results`); lazy entries never cross a block entry.
//!   * A result slot is retargeted only while the instruction that writes
//!     it is still the last one emitted (`Entry.def_end == here`).
//!
//! Comparison results stay `SystemBoolean` (`Entry.kind == .cond`) until a
//! consumer needs an `i32`, so compare-and-branch costs one extern.

const std = @import("std");
const wasm = @import("wasm");
const udon = @import("udon");
const tr = @import("translate.zig");

const Asm = udon.asm_.Asm;
const Sym = udon.asm_.Sym;
const Label = udon.asm_.Label;
const nodes = udon.nodes;
const ValType = wasm.types.ValType;
const FuncType = wasm.types.FuncType;
const Instruction = wasm.Instruction;
const Translator = tr.Translator;
const Error = tr.Error;

const no_def = std.math.maxInt(u32);

/// `Options.disable.byte_operators`, where `Entry` methods can see it.
var byte_operators_off = false;

/// Local indices at and above this value name per-function scratch locals
/// used by the instruction-sequence expansions in `snippets`.
const scratch_base: u32 = 0xFFFF_FF00;
const scratch_types = [_]ValType{ .i32, .i32, .i64, .i64, .i64, .f64 };
const tmp_i0 = scratch_base + 0;
const tmp_i1 = scratch_base + 1;
const tmp_l0 = scratch_base + 2;
const tmp_l1 = scratch_base + 3;
const tmp_l2 = scratch_base + 4;
const tmp_d0 = scratch_base + 5;

const Entry = struct {
    ty: ValType,
    kind: Kind,
    /// `.konst`: the value's bit pattern.
    bits: u64 = 0,
    /// Every other kind: the slot the value is read from.
    sym: Sym = 0,
    /// `.local`: the WASM local index.
    local: u32 = 0,
    /// The entry owns `sym` (a temporary from pool `pool`).
    owned: bool = false,
    pool: u8 = 0,
    /// `.cond`: the slot holds the *negation* of the WASM condition.
    negated: bool = false,
    /// `.cond`: signature of the opposite comparison, if the extern that
    /// produced this entry can be swapped for it.
    flip: ?[]const u8 = null,
    /// The value is known to be ≥ 0 as a signed number.
    nonneg: bool = false,
    /// Index of the `PUSH` that names `sym` as an extern's result slot.
    def: u32 = no_def,
    /// `Asm.here()` right after that extern.
    def_end: u32 = 0,
    /// The value was computed by the last instruction as `x & mask` with
    /// the constant operand pushed just before the result slot, so a
    /// further constant `&` only has to narrow that constant.
    mask: ?u64 = null,
    /// `.mem`: the load, the kind of its address operand (described by
    /// `bits` / `sym` / `local` / `owned` / `pool` as for an entry of that
    /// kind) and the offset still to be added to it.
    load: ?*const Load = null,
    base: Kind = .konst,
    offset: u32 = 0,

    const Kind = enum {
        konst,
        /// A WASM local's own slot.
        local,
        /// A local lowered to SystemByte. Widen only for i32 consumers.
        byte_local,
        /// A slot other code may overwrite: globals, return registers,
        /// fields. Copied out before anything that can write it.
        shared,
        /// A temporary; stable until the entry is consumed.
        temp,
        /// A borrowed slot the borrower keeps alive.
        alias,
        /// A `SystemBoolean` standing for an i32 that is 0 or 1.
        cond,
        /// A load that has not been emitted yet. Whoever consumes it can
        /// then do better than "read, then use": a store copies memory to
        /// memory, a test reads a Boolean, a byte feeds a byte operator.
        /// Emitted before anything that can write memory.
        mem,
    };

    /// The address operand of a `.mem` entry, without `offset`.
    fn address(e: Entry) Entry {
        return switch (e.base) {
            .konst => .{ .ty = .i32, .kind = .konst, .bits = e.bits },
            .local => .{ .ty = .i32, .kind = .local, .sym = e.sym, .local = e.local },
            else => .{ .ty = .i32, .kind = e.base, .sym = e.sym, .owned = e.owned, .pool = e.pool },
        };
    }

    /// An unsigned byte that is still in memory.
    fn isByte(e: Entry) bool {
        return e.kind == .byte_local or (e.kind == .mem and e.load.?.byte and e.ty == .i32 and !byte_operators_off);
    }

    /// A constant a `SystemByte` can hold.
    fn isByteConst(e: Entry) bool {
        return e.kind == .konst and e.ty == .i32 and e.bits <= 0xFF;
    }

    fn isZero(e: Entry) bool {
        return e.kind == .konst and e.bits == 0;
    }
};

/// What a load instruction reads and how that becomes its WASM type.
const Load = struct {
    ty: ValType,
    /// Bytes read.
    size: u8,
    /// Extern reading the value at an address.
    read: []const u8,
    /// When `read` returns a narrower .NET type: that type, and the extern
    /// widening it to `ty`.
    raw: ?[]const u8 = null,
    widen: ?[]const u8 = null,
    nonneg: bool = false,
    /// `read` returns a `SystemByte`.
    byte: bool = false,
};

const loads = struct {
    const byte_get = "SystemByteArray.__Get__SystemInt32__SystemByte";
    const u16_get = "SystemBitConverter.__ToUInt16__SystemByteArray_SystemInt32__SystemUInt16";
    const i16_get = "SystemBitConverter.__ToInt16__SystemByteArray_SystemInt32__SystemInt16";
    const i32_get = "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32";

    const i32_load: Load = .{ .ty = .i32, .size = 4, .read = i32_get };
    const i64_load: Load = .{ .ty = .i64, .size = 8, .read = "SystemBitConverter.__ToInt64__SystemByteArray_SystemInt32__SystemInt64" };
    const f32_load: Load = .{ .ty = .f32, .size = 4, .read = "SystemBitConverter.__ToSingle__SystemByteArray_SystemInt32__SystemSingle" };
    const f64_load: Load = .{ .ty = .f64, .size = 8, .read = "SystemBitConverter.__ToDouble__SystemByteArray_SystemInt32__SystemDouble" };
    const i32_load8_u: Load = .{ .ty = .i32, .size = 1, .read = byte_get, .raw = "SystemByte", .widen = "SystemConvert.__ToInt32__SystemByte__SystemInt32", .nonneg = true, .byte = true };
    const i32_load16_u: Load = .{ .ty = .i32, .size = 2, .read = u16_get, .raw = "SystemUInt16", .widen = "SystemConvert.__ToInt32__SystemUInt16__SystemInt32", .nonneg = true };
    const i32_load16_s: Load = .{ .ty = .i32, .size = 2, .read = i16_get, .raw = "SystemInt16", .widen = "SystemConvert.__ToInt32__SystemInt16__SystemInt32" };
    const i64_load8_u: Load = .{ .ty = .i64, .size = 1, .read = byte_get, .raw = "SystemByte", .widen = "SystemConvert.__ToInt64__SystemByte__SystemInt64", .nonneg = true };
    const i64_load16_u: Load = .{ .ty = .i64, .size = 2, .read = u16_get, .raw = "SystemUInt16", .widen = "SystemConvert.__ToInt64__SystemUInt16__SystemInt64", .nonneg = true };
    const i64_load16_s: Load = .{ .ty = .i64, .size = 2, .read = i16_get, .raw = "SystemInt16", .widen = "SystemConvert.__ToInt64__SystemInt16__SystemInt64" };
    const i64_load32_u: Load = .{ .ty = .i64, .size = 4, .read = "SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32", .raw = "SystemUInt32", .widen = "SystemConvert.__ToInt64__SystemUInt32__SystemInt64", .nonneg = true };
    const i64_load32_s: Load = .{ .ty = .i64, .size = 4, .read = i32_get, .raw = "SystemInt32", .widen = "SystemConvert.__ToInt64__SystemInt32__SystemInt64" };
};

const Ctrl = struct {
    kind: enum { func, block, loop, if_ },
    /// Branch target: the end of a block/if, the head of a loop.
    label: Label,
    /// Value types a branch to this frame carries.
    types: []const ValType,
    /// Slots those values are joined in, allocated on first use.
    results: []Sym = &.{},
    /// Something branches to `label`.
    targeted: bool = false,
    /// Operand stack height below this frame.
    height: usize,
};

const Pool = struct { type_name: []const u8, free: std.ArrayList(Sym) = .empty };

/// A value the translator itself derives from an i32 local and a constant:
/// the address `local + offset` of a memory access, or the sign-flipped
/// `local ^ 0x80000000` of an unsigned comparison. Remembered while the
/// local is unchanged so that, for instance, a load and a store of the same
/// field compute its address once.
const Derived = struct {
    op: enum { none, add, xor } = .none,
    local: u32 = 0,
    bits: u32 = 0,
};

/// A pure integer expression whose operands are unchanged on every path
/// around the loop. Keep its result in a slot private to this function.
const LoopInvariants = struct {
    writes: std.DynamicBitSetUnmanaged,
    calls: bool = false,
    expressions: std.ArrayList(Expression) = .empty,

    const Expression = struct { ext: u32, lhs: Sym, rhs: Sym, dst: Sym };

    fn inspect(self: *@This(), ins: Instruction) void {
        switch (ins) {
            .local_set, .local_tee => |i| if (i < self.writes.capacity()) self.writes.set(i),
            .call, .call_indirect => self.calls = true,
            else => {},
        }
    }

    fn immutable(self: *const @This(), e: Entry) bool {
        return e.kind == .konst or (e.kind == .local and e.local < self.writes.capacity() and !self.writes.isSet(e.local));
    }
};

pub fn lowerFunction(t: *Translator, func_index: u32) Error!void {
    byte_operators_off = t.options.disable.byte_operators;
    var l: Lowerer = .{ .t = t, .a = &t.a, .f = &t.funcs[func_index], .f_idx = func_index };
    defer l.deinit();
    try l.run(t.mod.codes[func_index - t.num_imported_funcs]);
}

const Lowerer = struct {
    t: *Translator,
    a: *Asm,
    f: *tr.Func,
    f_idx: u32,
    stack: std.ArrayList(Entry) = .empty,
    ctrl: std.ArrayList(Ctrl) = .empty,
    pools: std.ArrayList(Pool) = .empty,
    temp_count: u32 = 0,
    loops: std.ArrayList(LoopInvariants) = .empty,
    // Sibling loops reuse slots. Nested loops have overlapping lifetimes.
    invariant_slots: std.AutoHashMapUnmanaged(struct { depth: usize, index: usize, ty: ValType }, Sym) = .empty,
    scratch: [scratch_types.len]?Sym = @splat(null),
    /// Which locals are live after each call (`liveness.zig`).
    live: @import("liveness.zig").Liveness = .{},
    loop_live: ?@import("liveness.zig").Liveness = null,
    /// The instruction being lowered.
    current: ?*const Instruction = null,
    /// Per local: its current value is known to be ≥ 0. Tracked along
    /// straight-line code only; a label forgets everything.
    local_nonneg: []bool = &.{},
    derived: [Translator.derived_slots]Derived = @splat(.{}),
    /// The slot handed out last; its value may still be waiting to be
    /// used, so it is not the next one replaced.
    derived_last: usize = 0,

    fn deinit(self: *Lowerer) void {
        const gpa = self.t.gpa;
        self.stack.deinit(gpa);
        self.ctrl.deinit(gpa);
        self.loops.deinit(gpa);
        self.invariant_slots.deinit(gpa);
        for (self.pools.items) |*p| p.free.deinit(gpa);
        self.pools.deinit(gpa);
    }

    fn run(self: *Lowerer, code: wasm.module.Code) Error!void {
        const n_params = self.f.ty.params.len;
        try self.stack.ensureTotalCapacityPrecise(self.t.gpa, max_stack);
        self.a.bind(self.f.entry);

        // WASM zero-initializes declared locals on every call. Slots keep
        // their value from the previous call, so locals that may be read
        // before they are written are reset here.
        const needs_init = try self.t.arena().alloc(bool, self.f.locals.len);
        @memset(needs_init, false);
        const assigned = try self.t.arena().alloc(bool, self.f.locals.len);
        @memset(assigned, false);
        @memset(assigned[0..n_params], true);
        scanInit(code.body, assigned, needs_init);
        for (needs_init, 0..) |need, i| {
            if (!need) continue;
            const zero = if (self.f.bool_locals[i]) try self.t.constBool(false) else if (self.f.byte_locals[i]) try self.t.constByte(0) else try self.t.constSym(self.f.local_types[i], 0);
            try self.a.copy(zero, self.f.locals[i]);
        }
        self.live = try @import("liveness.zig").analyze(self.t.arena(), self.f.locals.len, code.body);

        // Declared locals start at zero; parameters can be anything.
        self.local_nonneg = try self.t.arena().alloc(bool, self.f.locals.len);
        for (self.local_nonneg, 0..) |*known, i| known.* = i >= n_params;

        try self.ctrl.append(self.t.gpa, .{ .kind = .func, .label = 0, .types = self.f.ty.results, .height = 0 });
        if (try self.lowerBody(code.body)) try self.emitReturn();
    }

    /// Mark locals that can be read before any assignment on some path.
    /// Assignments inside a nested block do not count for code after it
    /// (a branch may have skipped them), which keeps this a single pass.
    fn scanInit(body: []const Instruction, assigned: []bool, needs: []bool) void {
        for (body) |ins| switch (ins) {
            .local_get => |i| if (i < assigned.len and !assigned[i]) {
                needs[i] = true;
            },
            .local_set, .local_tee => |i| if (i < assigned.len) {
                assigned[i] = true;
            },
            .block, .loop => |b| scanNested(b.body, assigned, needs),
            .if_ => |b| {
                scanNested(b.then_body, assigned, needs);
                if (b.else_body) |e| scanNested(e, assigned, needs);
            },
            .br, .br_table, .return_, .unreachable_ => return,
            else => {},
        };
    }

    fn scanNested(body: []const Instruction, assigned: []bool, needs: []bool) void {
        var copy: [256]bool = undefined;
        if (assigned.len > copy.len) {
            // Too many locals to snapshot cheaply: treat the block as
            // reading everything not yet assigned.
            markAllReads(body, assigned, needs);
            return;
        }
        @memcpy(copy[0..assigned.len], assigned);
        scanInit(body, copy[0..assigned.len], needs);
    }

    fn markAllReads(body: []const Instruction, assigned: []const bool, needs: []bool) void {
        const Sets = struct { assigned: []const bool, needs: []bool };
        wasm.instruction.forEach(body, Sets{ .assigned = assigned, .needs = needs }, struct {
            fn visit(s: Sets, ins: Instruction) void {
                if (ins == .local_get and ins.local_get < s.assigned.len and !s.assigned[ins.local_get]) s.needs[ins.local_get] = true;
            }
        }.visit);
    }

    // ------------------------------------------------------------------
    //  Slots and temporaries
    // ------------------------------------------------------------------

    fn poolFor(self: *Lowerer, type_name: []const u8) Error!u8 {
        for (self.pools.items, 0..) |p, i| if (std.mem.eql(u8, p.type_name, type_name)) return @intCast(i);
        try self.pools.append(self.t.gpa, .{ .type_name = type_name });
        return @intCast(self.pools.items.len - 1);
    }

    fn valPool(self: *Lowerer, ty: ValType) Error!u8 {
        return self.poolFor(tr.udonType(ty));
    }

    fn newTemp(self: *Lowerer, pool: u8) Error!Sym {
        const p = &self.pools.items[pool];
        if (p.free.pop()) |s| return s;
        return self.freshTemp(p.type_name);
    }

    pub fn freshTemp(self: *Lowerer, type_name: []const u8) Error!Sym {
        self.temp_count += 1;
        return self.a.declare(.{
            .name = try self.t.name("__{s}_T{d}__", .{ self.f.name, self.temp_count }),
            .type_name = type_name,
            .init = tr.zeroOf(type_name),
        });
    }

    fn freeTemp(self: *Lowerer, pool: u8, sym: Sym) Error!void {
        try self.pools.items[pool].free.append(self.t.gpa, sym);
    }

    fn tempOf(self: *Lowerer, ty: ValType) Error!Sym {
        return self.newTemp(try self.valPool(ty));
    }

    fn release(self: *Lowerer, e: Entry) Error!void {
        if (e.owned) try self.freeTemp(e.pool, e.sym);
    }

    fn localType(self: *Lowerer, i: u32) Error!ValType {
        if (i >= scratch_base) return scratch_types[i - scratch_base];
        if (i >= self.f.locals.len) return self.t.fail(error.Invalid, "function {s} uses local {d}, which it does not declare", .{ self.f.name, i });
        return self.f.local_types[i];
    }

    fn localSym(self: *Lowerer, i: u32) Error!Sym {
        if (i < scratch_base) return self.f.locals[i];
        const k = i - scratch_base;
        if (self.scratch[k] == null) self.scratch[k] = try self.tempOf(scratch_types[k]);
        return self.scratch[k].?;
    }

    // ------------------------------------------------------------------
    //  Operand stack
    // ------------------------------------------------------------------

    /// Entries are updated in place through pointers while code that
    /// pushes and pops runs, so the stack must never move: its storage is
    /// allocated once.
    const max_stack = 4096;

    fn push(self: *Lowerer, e: Entry) Error!void {
        if (self.stack.items.len == self.stack.capacity)
            return self.t.fail(error.Unsupported, "function {s} needs an operand stack deeper than {d}", .{ self.f.name, max_stack });
        self.stack.appendAssumeCapacity(e);
    }

    fn pop(self: *Lowerer) Error!Entry {
        return self.stack.pop() orelse self.t.fail(error.Invalid, "operand stack underflow in function {s}", .{self.f.name});
    }

    fn pushConst(self: *Lowerer, ty: ValType, bits: u64) Error!void {
        const nonneg = switch (ty) {
            .i32 => @as(i32, @bitCast(@as(u32, @truncate(bits)))) >= 0,
            .i64 => @as(i64, @bitCast(bits)) >= 0,
            else => false,
        };
        try self.push(.{ .ty = ty, .kind = .konst, .bits = bits, .nonneg = nonneg });
    }

    fn pushI32(self: *Lowerer, x: i32) Error!void {
        try self.pushConst(.i32, @as(u32, @bitCast(x)));
    }

    /// A second, non-owning reference to `e`'s value. `e` must stay alive
    /// (and unconsumed) for as long as the alias is used.
    fn alias(self: *Lowerer, e: *Entry) Error!Entry {
        if (e.kind == .konst) return e.*;
        return .{ .ty = e.ty, .kind = .alias, .sym = try self.operand(e), .nonneg = e.nonneg };
    }

    /// Slot the entry's value can be read from, as its WASM type.
    fn operand(self: *Lowerer, e: *Entry) Error!Sym {
        switch (e.kind) {
            .konst => return self.t.constSym(e.ty, e.bits),
            .local, .shared, .temp, .alias => return e.sym,
            .byte_local => {
                e.* = try self.compute(.i32, try self.valPool(.i32), loads.i32_load8_u.widen.?, &.{e.sym});
                e.nonneg = true;
                return e.sym;
            },
            .mem => {
                try self.loadNow(e);
                return e.sym;
            },
            .cond => {
                const b = try self.condBool(e, true);
                var number = try self.compute(.i32, try self.valPool(.i32), "SystemConvert.__ToInt32__SystemBoolean__SystemInt32", &.{b});
                number.nonneg = true;
                try self.release(e.*);
                e.* = number;
                return number.sym;
            },
        }
    }

    /// A `SystemBoolean` slot for the entry's i32 value with whichever
    /// sense costs nothing: true when the value is non-zero if
    /// `!e.negated` afterwards, true when it is zero otherwise. `want` is
    /// the sense preferred when there is a free choice. `e` still has to be
    /// released by the caller.
    fn condAny(self: *Lowerer, e: *Entry, want: bool) Error!Sym {
        // A byte in memory tests in one extern, but only for "non-zero".
        if (e.isByte()) return self.condBool(e, true);
        if (e.kind != .cond) return self.condBool(e, want);
        // The slot holds the opposite sense: swap the comparison that
        // produced it if that is still the last instruction.
        if (e.negated == want and e.flip != null and e.owned and e.def_end == self.a.here()) {
            const code = self.a.code.items;
            code[code.len - 1].arg = try self.a.internExtern(e.flip.?);
            e.flip = null;
            e.negated = !e.negated;
        }
        return e.sym;
    }

    /// A `SystemBoolean` slot that is true exactly when the entry's i32
    /// value is non-zero (`want`) or zero (`!want`). `e` still has to be
    /// released by the caller.
    fn condBool(self: *Lowerer, e: *Entry, want: bool) Error!Sym {
        if (e.kind == .cond) {
            const s = try self.condAny(e, want);
            if (e.negated != want) return s;
            const pool = try self.poolFor("SystemBoolean");
            const d = if (e.owned) e.sym else try self.newTemp(pool);
            try self.a.call("SystemBoolean.__op_UnaryNegation__SystemBoolean__SystemBoolean", &.{ e.sym, d });
            e.* = .{ .ty = .i32, .kind = .cond, .sym = d, .owned = true, .pool = pool, .negated = !e.negated };
            return d;
        }
        if (e.kind == .mem and e.isByte()) {
            // "Is this byte non-zero" is a single read.
            const mem = try self.memory();
            const sa = try self.loadAddress(e);
            const pool = try self.poolFor("SystemBoolean");
            const d = try self.newTemp(pool);
            try self.a.call("SystemBitConverter.__ToBoolean__SystemByteArray_SystemInt32__SystemBoolean", &.{ mem.sym, sa, d });
            e.* = .{ .ty = .i32, .kind = .cond, .sym = d, .owned = true, .pool = pool };
            return self.condBool(e, want);
        }
        const x = try self.operand(e);
        const pool = try self.poolFor("SystemBoolean");
        try self.release(e.*);
        const d = try self.newTemp(pool);
        if (want) {
            try self.a.call("SystemConvert.__ToBoolean__SystemInt32__SystemBoolean", &.{ x, d });
        } else {
            try self.a.call(cmpSig(.i32, .eq), &.{ x, try self.t.constI32(0), d });
        }
        e.* = .{ .ty = .i32, .kind = .cond, .sym = d, .owned = true, .pool = pool, .negated = !want };
        return d;
    }

    /// Jump to `label` when the i32 condition `e` is non-zero (`when`) or
    /// zero (`!when`). `e` still has to be released by the caller.
    ///
    /// `JUMP_IF_FALSE` jumps on false, so a slot with the wrong sense would
    /// need inverting. That is an extern; jumping over an unconditional
    /// jump is not.
    fn branchIf(self: *Lowerer, e: *Entry, when: bool, label: Label) Error!void {
        const b = try self.condAny(e, !when);
        if (e.negated == when) return self.a.jumpIfFalse(b, label);
        const skip = try self.a.newLabel();
        try self.a.jumpIfFalse(b, skip);
        try self.a.jump(label);
        self.a.bind(skip);
    }

    /// Emit `sig(ins…) → new temporary` and push the result.
    fn result(self: *Lowerer, ty: ValType, sig: []const u8, ins: []const Sym) Error!void {
        try self.resultIn(ty, try self.valPool(ty), sig, ins);
    }

    fn resultIn(self: *Lowerer, ty: ValType, pool: u8, sig: []const u8, ins: []const Sym) Error!void {
        try self.push(try self.compute(ty, pool, sig, ins));
    }

    /// Emit `sig(ins…) → new temporary` and return the entry for it.
    fn compute(self: *Lowerer, ty: ValType, pool: u8, sig: []const u8, ins: []const Sym) Error!Entry {
        const d = try self.newTemp(pool);
        for (ins) |s| try self.a.push(s);
        const def = self.a.here();
        try self.a.push(d);
        try self.a.call(sig, &.{});
        return .{ .ty = ty, .kind = .temp, .sym = d, .owned = true, .pool = pool, .def = def, .def_end = self.a.here() };
    }

    fn resultCond(self: *Lowerer, sig: []const u8, flip: ?[]const u8, ins: []const Sym) Error!void {
        var e = try self.compute(.i32, try self.poolFor("SystemBoolean"), sig, ins);
        e.kind = .cond;
        e.flip = flip;
        e.nonneg = true;
        try self.push(e);
    }

    /// Put the entry's value in `dst` and release the entry. When the value
    /// was just computed into a temporary, the computation is retargeted to
    /// write `dst` directly.
    fn store(self: *Lowerer, entry: Entry, dst: Sym) Error!void {
        var e = entry;
        if (e.kind == .mem) try self.loadNow(&e);
        switch (e.kind) {
            .temp => if (e.def != no_def and e.def_end == self.a.here()) {
                self.a.code.items[e.def].arg = dst;
            } else if (e.sym != dst) try self.a.copy(e.sym, dst),
            .cond => {
                const b = try self.condBool(&e, true);
                try self.a.call("SystemConvert.__ToInt32__SystemBoolean__SystemInt32", &.{ b, dst });
            },
            else => {
                const s = try self.operand(&e);
                if (s != dst) try self.a.copy(s, dst);
            },
        }
        try self.release(e);
    }

    fn materialize(self: *Lowerer, e: *Entry) Error!void {
        if (e.kind == .byte_local) {
            _ = try self.operand(e);
            return;
        }
        if (e.kind == .cond) {
            const pool = try self.poolFor("SystemBoolean");
            const d = try self.newTemp(pool);
            try self.a.copy(e.sym, d);
            e.sym = d;
            e.owned = true;
            e.pool = pool;
            e.flip = null;
            e.def = no_def;
            return;
        }
        const pool = try self.valPool(e.ty);
        const d = try self.newTemp(pool);
        try self.a.copy(e.sym, d);
        e.* = .{ .ty = e.ty, .kind = .temp, .sym = d, .owned = true, .pool = pool, .nonneg = e.nonneg };
    }

    /// Detach every pending reference to local `i` before it is overwritten.
    fn flushLocal(self: *Lowerer, i: u32) Error!void {
        const slot = if (self.isBoolLocal(i)) try self.localSym(i) else null;
        for (self.stack.items) |*e| {
            if ((e.kind == .local or e.kind == .byte_local) and e.local == i) try self.materialize(e);
            if (e.kind == .mem and e.base == .local and e.local == i) try self.loadNow(e);
            if (e.kind == .cond and !e.owned and e.sym == slot) try self.materialize(e);
        }
        self.forgetDerivedFrom(i);
    }

    /// Local `i` has a new value: what was derived from the old one is
    /// stale.
    fn forgetDerivedFrom(self: *Lowerer, i: u32) void {
        for (&self.derived) |*d| if (d.local == i) {
            d.op = .none;
        };
    }

    /// Slot holding `local <op> bits`, computed now unless it was computed
    /// since the local last changed. Valid until the next call to this
    /// function but one, so use it at once.
    fn derive(self: *Lowerer, op: @FieldType(Derived, "op"), local: u32, local_sym: Sym, bits: u32) Error!Sym {
        const operation: Bin = if (op == .add) .add else .xor;
        if (try self.invariantBinary(.i32, operation, .{ .ty = .i32, .kind = .local, .local = local, .sym = local_sym }, .{ .ty = .i32, .kind = .konst, .bits = bits })) |sym| return sym;
        var free: ?usize = null;
        for (self.derived, 0..) |d, k| {
            if (d.op == op and d.local == local and d.bits == bits and !self.t.options.disable.derived) {
                self.derived_last = k;
                return self.t.derivedSym(k);
            }
            if (d.op == .none and free == null) free = k;
        }
        const k = free orelse (self.derived_last + 1) % self.derived.len;
        const slot = try self.t.derivedSym(k);
        try self.a.call(binSig(.i32, if (op == .add) .add else .xor), &.{ local_sym, try self.t.constI32(@bitCast(bits)), slot });
        self.derived[k] = .{ .op = op, .local = local, .bits = bits };
        self.derived_last = k;
        return slot;
    }

    /// Control can arrive here from somewhere else, or other code has run:
    /// nothing derived earlier can be relied on.
    fn forgetDerived(self: *Lowerer) void {
        self.derived = @splat(.{});
    }

    /// A label other code jumps to: what was known along the way here need
    /// not hold on the other ways in.
    fn bindJoin(self: *Lowerer, label: Label) void {
        self.a.bind(label);
        self.forgetDerived();
        @memset(self.local_nonneg, false);
    }

    fn isBoolLocal(self: *const Lowerer, i: u32) bool {
        return i < self.f.bool_locals.len and self.f.bool_locals[i];
    }

    /// `local.set` of a local kept as a `SystemBoolean`.
    fn setBoolLocal(self: *Lowerer, i: u32) Error!bool {
        var v = try self.pop();
        const dst = try self.localSym(i);
        try self.flushLocal(i);
        if (v.kind == .konst) {
            try self.a.copy(try self.t.constBool(v.bits != 0), dst);
            return true;
        }
        const b = try self.condBool(&v, true);
        // A comparison that has just been emitted writes the local itself.
        if (v.owned and v.def != no_def and v.def_end == self.a.here()) {
            self.a.code.items[v.def].arg = dst;
        } else if (b != dst) try self.a.copy(b, dst);
        try self.release(v);
        return true;
    }

    fn localNonneg(self: *const Lowerer, i: u32) bool {
        if (self.t.options.disable.masks) return false;
        return i < self.local_nonneg.len and self.local_nonneg[i];
    }

    /// Detach pending references to shared slot `sym` (or to all shared
    /// slots) among the first `count` stack entries.
    fn flushShared(self: *Lowerer, sym: ?Sym, count: usize) Error!void {
        for (self.stack.items[0..count]) |*e| {
            const is_shared = e.kind == .shared or (e.kind == .cond and !e.owned);
            if (is_shared and (sym == null or sym.? == e.sym)) try self.materialize(e);
        }
    }

    /// Before entering a block: nothing below may depend on slots the block
    /// can write, because a write inside one arm cannot be compensated on
    /// the other.
    fn flushForBlock(self: *Lowerer) Error!void {
        for (self.stack.items) |*e| switch (e.kind) {
            .local, .byte_local, .shared => try self.materialize(e),
            .cond => if (!e.owned) try self.materialize(e),
            .mem => try self.loadNow(e),
            .konst, .temp, .alias => {},
        };
    }

    fn truncate(self: *Lowerer, height: usize) Error!void {
        while (self.stack.items.len > height) try self.release(self.stack.pop().?);
    }

    // ------------------------------------------------------------------
    //  Control flow
    // ------------------------------------------------------------------

    fn blockTypes(self: *Lowerer, bt: wasm.types.BlockType) Error![]const ValType {
        const one = struct {
            const i32_ = [_]ValType{.i32};
            const i64_ = [_]ValType{.i64};
            const f32_ = [_]ValType{.f32};
            const f64_ = [_]ValType{.f64};
        };
        return switch (bt) {
            .empty => &.{},
            .value => |v| switch (v) {
                .i32 => &one.i32_,
                .i64 => &one.i64_,
                .f32 => &one.f32_,
                .f64 => &one.f64_,
            },
            .type_index => |i| blk: {
                if (i >= self.t.mod.types_.len) return self.t.fail(error.Invalid, "block type index {d} out of range", .{i});
                const ft = self.t.mod.types_[i];
                if (ft.params.len != 0) return self.t.fail(error.Unsupported, "blocks with parameters (multi-value) are not supported", .{});
                break :blk ft.results;
            },
        };
    }

    fn ensureResults(self: *Lowerer, c: *Ctrl) Error!void {
        c.targeted = true;
        if (c.results.len == c.types.len) return;
        const syms = try self.t.arena().alloc(Sym, c.types.len);
        for (syms, c.types) |*s, ty| s.* = try self.tempOf(ty);
        c.results = syms;
    }

    /// Copy the top `types.len` values into the frame's join slots without
    /// disturbing the stack (the fall-through path still needs them).
    fn copyResults(self: *Lowerer, c: *Ctrl) Error!void {
        try self.ensureResults(c);
        const base = self.stack.items.len - c.types.len;
        for (c.results, 0..) |dst, k| {
            const s = try self.operand(&self.stack.items[base + k]);
            if (s != dst) try self.a.copy(s, dst);
        }
    }

    /// Move the top values into the join slots, consuming them.
    fn moveResults(self: *Lowerer, c: *Ctrl) Error!void {
        try self.ensureResults(c);
        var k = c.types.len;
        while (k > 0) {
            k -= 1;
            try self.store(try self.pop(), c.results[k]);
        }
    }

    fn pushResults(self: *Lowerer, c: *const Ctrl) Error!void {
        for (c.results, c.types) |s, ty| try self.push(.{ .ty = ty, .kind = .temp, .sym = s, .owned = true, .pool = try self.valPool(ty) });
    }

    /// Lower a block body. Returns whether control can reach its end.
    fn lowerBody(self: *Lowerer, body: []const Instruction) Error!bool {
        for (body) |*ins| {
            self.current = ins;
            if (!try self.lowerInstr(ins.*)) return false;
        }
        return true;
    }

    fn lowerBlock(self: *Lowerer, b: wasm.instruction.Block) Error!bool {
        try self.flushForBlock();
        try self.ctrl.append(self.t.gpa, .{ .kind = .block, .label = try self.a.newLabel(), .types = try self.blockTypes(b.bt), .height = self.stack.items.len });
        const falls = try self.lowerBody(b.body);
        return self.endFrame(falls);
    }

    /// Close the innermost block/if frame. `falls`: its end is reachable by
    /// falling through.
    fn endFrame(self: *Lowerer, falls: bool) Error!bool {
        var c = self.ctrl.pop().?;
        if (!c.targeted) {
            // Nothing branches here: the fall-through values stay as they
            // are, or the end is dead.
            if (!falls) try self.truncate(c.height);
            return falls;
        }
        if (falls) try self.moveResults(&c);
        try self.truncate(c.height);
        self.bindJoin(c.label);
        try self.pushResults(&c);
        return true;
    }

    fn invariantBinary(self: *Lowerer, ty: ValType, op: Bin, a: Entry, b: Entry) Error!?Sym {
        if (!isInt(ty) or op == .div_s or op == .rem_s or (ty == .i64 and (op == .shl or op == .shr_s))) return null;
        for (self.loops.items, 0..) |*region, depth| {
            if (region.calls or !region.immutable(a) or !region.immutable(b)) continue;
            const lhs = if (a.kind == .konst) try self.t.constSym(a.ty, a.bits) else a.sym;
            const rhs = if (b.kind == .konst) try self.t.constSym(b.ty, b.bits) else b.sym;
            const ext = try self.a.internExtern(binSig(ty, op));
            for (region.expressions.items) |expr| {
                if (expr.ext == ext and expr.lhs == lhs and expr.rhs == rhs) return expr.dst;
            }
            // Earlier instructions in this very loop may already use any
            // slot in the ordinary temporary pool.
            const slot = try self.invariant_slots.getOrPut(self.t.gpa, .{ .depth = depth, .index = region.expressions.items.len, .ty = ty });
            if (!slot.found_existing) slot.value_ptr.* = try self.freshTemp(tr.udonType(ty));
            const dst = slot.value_ptr.*;
            try region.expressions.append(self.t.arena(), .{ .ext = ext, .lhs = lhs, .rhs = rhs, .dst = dst });
            return dst;
        }
        return null;
    }

    fn emitInvariants(self: *Lowerer, head: Label, region: LoopInvariants) Error!void {
        if (region.expressions.items.len == 0) return;
        const start = self.a.labels.items[head].pos;
        const n: u32 = @intCast(4 * region.expressions.items.len);
        const preheader = try self.a.code.addManyAt(self.t.gpa, start, n);
        for (region.expressions.items, 0..) |expr, i| {
            preheader[i * 4 ..][0..4].* = .{
                .{ .op = .push, .arg = expr.lhs }, .{ .op = .push, .arg = expr.rhs },
                .{ .op = .push, .arg = expr.dst }, .{ .op = .extern_, .arg = expr.ext },
            };
        }
        // Enclosing labels at the old loop entry enter the preheader.
        // The header and labels allocated inside this loop follow it.
        for (self.a.labels.items[head..]) |*label| {
            if (label.pos != std.math.maxInt(u32) and label.pos >= start) label.pos += n;
        }
    }

    pub fn liveAfterLoop(self: *Lowerer, site: ?*const Instruction) Error!?std.DynamicBitSetUnmanaged {
        const loop = site orelse return null;
        if (self.loop_live == null) {
            const code = self.t.mod.codes[self.f_idx - self.t.num_imported_funcs];
            self.loop_live = try @import("liveness.zig").analyzeAt(self.t.arena(), self.f.locals.len, code.body, true);
        }
        return self.loop_live.?.after_loop.get(loop);
    }

    fn lowerLoop(self: *Lowerer, b: wasm.instruction.Block) Error!bool {
        const loop_site = self.current;
        try self.flushForBlock();
        const head = try self.a.newLabel();
        self.bindJoin(head);
        const height = self.stack.items.len;
        // A branch to a loop carries its parameters, of which MVP has none.
        _ = try self.blockTypes(b.bt);
        try self.ctrl.append(self.t.gpa, .{ .kind = .loop, .label = head, .types = &.{}, .height = height });
        const hoist = b.bt == .empty and !self.t.options.disable.loop_invariants;
        if (hoist) {
            var region = LoopInvariants{ .writes = try std.DynamicBitSetUnmanaged.initEmpty(self.t.arena(), self.f.locals.len) };
            wasm.instruction.forEach(b.body, &region, LoopInvariants.inspect);
            try self.loops.append(self.t.gpa, region);
        }
        const falls = try self.lowerBody(b.body);
        _ = self.ctrl.pop();
        if (!falls) try self.truncate(height);
        if (b.bt == .empty and falls and !self.t.options.disable.loop_paths) {
            const DeadBools = struct {
                pools: []const Pool,
                pub fn contains(d: @This(), sym: Sym) bool {
                    for (d.pools) |p| if (std.mem.eql(u8, p.type_name, "SystemBoolean"))
                        return std.mem.indexOfScalar(Sym, p.free.items, sym) != null;
                    return false;
                }
            };
            if (try @import("loop_paths.zig").optimize(self.a, head, DeadBools{ .pools = self.pools.items }, self, loop_site)) self.forgetDerived();
        }
        if (hoist) try self.emitInvariants(head, self.loops.pop().?);
        return falls;
    }

    fn lowerIf(self: *Lowerer, b: wasm.instruction.If) Error!bool {
        var c = try self.pop();
        try self.flushForBlock();
        const types = try self.blockTypes(b.bt);
        if (c.kind == .konst) {
            // Constant condition: only one arm exists.
            const taken: ?[]const Instruction = if (c.bits != 0) b.then_body else b.else_body;
            try self.ctrl.append(self.t.gpa, .{ .kind = .block, .label = try self.a.newLabel(), .types = types, .height = self.stack.items.len });
            return self.endFrame(try self.lowerBody(taken orelse &.{}));
        }
        const end = try self.a.newLabel();
        const else_label = if (b.else_body != null) try self.a.newLabel() else end;
        try self.branchIf(&c, false, else_label);
        try self.release(c);
        try self.ctrl.append(self.t.gpa, .{ .kind = .if_, .label = end, .types = types, .height = self.stack.items.len, .targeted = true });
        const frame = self.ctrl.items.len - 1;

        var falls = try self.lowerBody(b.then_body);
        if (b.else_body) |else_body| {
            if (falls) {
                try self.moveResults(&self.ctrl.items[frame]);
                try self.a.jump(end);
            }
            try self.truncate(self.ctrl.items[frame].height);
            self.bindJoin(else_label);
            falls = try self.lowerBody(else_body);
        }
        return self.endFrame(falls);
    }

    fn frameAt(self: *Lowerer, depth: u32) Error!*Ctrl {
        if (depth >= self.ctrl.items.len) return self.t.fail(error.Invalid, "branch depth {d} out of range in function {s}", .{ depth, self.f.name });
        return &self.ctrl.items[self.ctrl.items.len - 1 - depth];
    }

    fn lowerBr(self: *Lowerer, depth: u32) Error!void {
        const c = try self.frameAt(depth);
        if (c.kind == .func) return self.emitReturn();
        if (c.kind != .loop) try self.moveResults(c) else c.targeted = true;
        try self.a.jump(c.label);
    }

    fn lowerBrIf(self: *Lowerer, depth: u32) Error!void {
        var cond = try self.pop();
        const c = try self.frameAt(depth);
        if (cond.kind == .konst and cond.bits == 0) return;
        const carries = c.kind == .func or (c.kind != .loop and c.types.len != 0);
        if (!carries and cond.kind != .konst) {
            c.targeted = true;
            try self.branchIf(&cond, true, c.label);
            return self.release(cond);
        }
        const skip = try self.a.newLabel();
        // The code between the test and `skip` runs only when the branch
        // is taken, but what it does to the operands — emitting a pending
        // load, turning a condition into a number — is remembered for both
        // paths. Whatever the carried values need is therefore done first,
        // where both paths execute it.
        const carried = if (c.kind == .func) self.f.ty.results.len else c.types.len;
        for (self.stack.items[self.stack.items.len - carried ..]) |*e| _ = try self.operand(e);
        if (cond.kind != .konst) {
            try self.branchIf(&cond, false, skip);
            try self.release(cond);
        }
        if (c.kind == .func) {
            try self.copyReturn();
        } else {
            if (c.kind != .loop) try self.copyResults(c) else c.targeted = true;
            try self.a.jump(c.label);
        }
        self.a.bind(skip);
    }

    /// A `br_table` with fewer cases than this is a chain of comparisons:
    /// case `i` costs `i + 1` externs that way, an indexed jump two or
    /// three whichever case it is.
    const jump_table_min = 5;

    fn lowerBrTable(self: *Lowerer, bt: wasm.instruction.BrTable) Error!void {
        var index = try self.pop();
        if (index.kind == .konst) {
            const i: u32 = @truncate(index.bits);
            return self.lowerBr(if (i < bt.labels.len) bt.labels[i] else bt.default);
        }
        const default = try self.frameAt(bt.default);
        const arity = if (default.kind == .loop) 0 else default.types.len;
        const x = try self.operand(&index);
        // Each case below is code only its own path runs; the values the
        // branches carry are made ready before the paths part (see
        // `lowerBrIf`).
        const carried = if (default.kind == .func) self.f.ty.results.len else arity;
        for (self.stack.items[self.stack.items.len - carried ..]) |*e| _ = try self.operand(e);

        // Values a taken branch carries go to every distinct target's join
        // slots up front; the dispatch below then only jumps.
        if (arity != 0) {
            for (bt.labels) |d| {
                const c = try self.frameAt(d);
                if (c.kind != .func and c.kind != .loop) try self.copyResults(c);
            }
            if (default.kind != .func and default.kind != .loop) try self.copyResults(default);
        }
        var cases: usize = 0;
        for (bt.labels) |d| cases += @intFromBool(d != bt.default);
        if (cases >= jump_table_min and !self.t.options.disable.jump_tables) {
            try self.jumpThroughTable(bt, &index, x);
            return self.release(index);
        }
        const b = try self.newTemp(try self.poolFor("SystemBoolean"));
        for (bt.labels, 0..) |d, i| {
            // Cases that go where the default goes need no test of their own.
            if (d == bt.default) continue;
            const next = try self.a.newLabel();
            try self.a.call(cmpSig(.i32, .eq), &.{ x, try self.t.constI32(@intCast(i)), b });
            try self.a.jumpIfFalse(b, next);
            try self.jumpToFrame(try self.frameAt(d));
            self.a.bind(next);
        }
        try self.jumpToFrame(default);
        try self.freeTemp(try self.poolFor("SystemBoolean"), b);
        try self.release(index);
    }

    /// `br_table` as `if (index <u n) goto table[index]; else default`.
    /// The carried values are already where every target expects them.
    fn jumpThroughTable(self: *Lowerer, bt: wasm.instruction.BrTable, index: *Entry, x: Sym) Error!void {
        const default = try self.frameAt(bt.default);
        const labels = try self.t.arena().alloc(Label, bt.labels.len);
        // A case that leaves the function jumps to a return sequence
        // emitted below.
        var ret: ?Label = null;
        for (labels, bt.labels) |*l, d| {
            const c = try self.frameAt(d);
            if (c.kind == .func) {
                if (ret == null) ret = try self.a.newLabel();
                l.* = ret.?;
            } else {
                c.targeted = true;
                l.* = c.label;
            }
        }
        const out = try self.a.newLabel();
        try self.push(if (index.kind == .local) index.* else try self.alias(index));
        try self.pushI32(@intCast(bt.labels.len));
        try self.compare(.i32, .lt, true);
        var in_range = try self.pop();
        try self.branchIf(&in_range, false, out);
        try self.release(in_range);

        const pool = try self.poolFor("SystemUInt32");
        const target = try self.newTemp(pool);
        try self.a.call("SystemUInt32Array.__Get__SystemInt32__SystemUInt32", &.{ try self.t.jumpTable(labels), x, target });
        try self.a.jumpIndirect(target);
        try self.freeTemp(pool, target);

        if (ret) |l| {
            self.a.bind(l);
            if (default.kind == .func) self.a.bind(out);
            try self.copyReturn();
            if (default.kind == .func) return;
        }
        self.a.bind(out);
        try self.jumpToFrame(default);
    }

    fn jumpToFrame(self: *Lowerer, c: *Ctrl) Error!void {
        if (c.kind == .func) return self.copyReturn();
        c.targeted = true;
        try self.a.jump(c.label);
    }

    fn jumpBack(self: *Lowerer) Error!void {
        switch (self.f.ret) {
            .indirect => try self.a.jumpIndirect(self.f.ra),
            .direct => try self.a.jump(self.f.ret_label),
            .halt => try self.a.jump(udon.asm_.halt),
            .stack => {
                const to = try self.t.returnSlot();
                try self.a.popInto(to);
                try self.a.jumpIndirect(to);
            },
        }
    }

    /// Return, leaving the operand stack intact (conditional returns).
    fn copyReturn(self: *Lowerer) Error!void {
        const types = self.f.ty.results;
        const base = self.stack.items.len - types.len;
        for (types, 0..) |ty, k| {
            const dst = try self.t.retSym(@intCast(k), ty);
            const s = try self.operand(&self.stack.items[base + k]);
            if (s != dst) try self.a.copy(s, dst);
        }
        try self.jumpBack();
    }

    /// Return, consuming the results.
    fn emitReturn(self: *Lowerer) Error!void {
        const types = self.f.ty.results;
        if (types.len > 1) return self.copyReturn();
        if (types.len == 1) try self.store(try self.pop(), try self.t.retSym(0, types[0]));
        try self.jumpBack();
    }

    // ------------------------------------------------------------------
    //  Instructions
    // ------------------------------------------------------------------

    /// Lower one instruction. Returns false when control cannot continue to
    /// the next instruction of the enclosing body.
    fn lowerInstr(self: *Lowerer, ins: Instruction) Error!bool {
        switch (ins) {
            .nop => {},
            .unreachable_ => {
                try self.a.jump(try self.t.trapLabel());
                return false;
            },
            .block => |b| return self.lowerBlock(b),
            .loop => |b| return self.lowerLoop(b),
            .if_ => |b| return self.lowerIf(b),
            .br => |d| {
                try self.lowerBr(d);
                return false;
            },
            .br_if => |d| try self.lowerBrIf(d),
            .br_table => |bt| {
                try self.lowerBrTable(bt);
                return false;
            },
            .return_ => {
                try self.emitReturn();
                return false;
            },
            // The callee uses the same derived-value slots, and an extern
            // can run another event of this behaviour.
            .call => |f| {
                try self.flushLoads();
                try self.lowerCall(f);
                self.forgetDerived();
            },
            .call_indirect => |ty| {
                try self.flushLoads();
                try self.lowerCallIndirect(ty);
                self.forgetDerived();
            },

            .drop => try self.release(try self.pop()),
            .select => try self.lowerSelect(),

            .local_get => |i| if (self.isBoolLocal(i)) {
                // The slot is the condition itself; like a global, it is
                // copied out before anything overwrites it.
                try self.push(.{ .ty = .i32, .kind = .cond, .sym = try self.localSym(i), .nonneg = true });
            } else if (i < self.f.byte_locals.len and self.f.byte_locals[i]) {
                try self.push(.{ .ty = .i32, .kind = .byte_local, .sym = try self.localSym(i), .local = i, .nonneg = true });
            } else try self.push(.{ .ty = try self.localType(i), .kind = .local, .sym = try self.localSym(i), .local = i, .nonneg = self.localNonneg(i) }),
            .local_set, .local_tee => |i| {
                if (self.isBoolLocal(i)) return self.setBoolLocal(i);
                if (i < self.f.byte_locals.len and self.f.byte_locals[i]) {
                    var v = try self.pop();
                    try self.flushLocal(i);
                    const dst = try self.localSym(i);
                    if (v.kind == .mem) {
                        try self.a.call(loads.byte_get, &.{ (try self.memory()).sym, try self.loadAddress(&v), dst });
                    } else {
                        // A load with a mutable address was materialized eagerly.
                        const value = try self.operand(&v);
                        try self.a.call("SystemConvert.__ToByte__SystemInt32__SystemByte", &.{ value, dst });
                        try self.release(v);
                    }
                    if (ins == .local_tee) try self.push(.{ .ty = .i32, .kind = .byte_local, .sym = dst, .local = i, .nonneg = true });
                    return true;
                }
                const v = try self.pop();
                const nonneg = v.nonneg;
                try self.flushLocal(i);
                try self.store(v, try self.localSym(i));
                // The value stored may itself have been a pending load
                // through this local — `p = p.next` — whose address was
                // derived from the old value just now.
                self.forgetDerivedFrom(i);
                if (i < self.local_nonneg.len) self.local_nonneg[i] = nonneg;
                if (ins == .local_tee) try self.push(.{ .ty = try self.localType(i), .kind = .local, .sym = try self.localSym(i), .local = i, .nonneg = nonneg });
            },
            .global_get => |i| {
                const g = try self.global(i);
                try self.push(.{ .ty = g.ty, .kind = .shared, .sym = g.sym });
            },
            .global_set => |i| {
                const g = try self.global(i);
                const v = try self.pop();
                try self.flushShared(g.sym, self.stack.items.len);
                try self.store(v, g.sym);
            },

            .i32_const => |x| try self.pushI32(x),
            .i64_const => |x| try self.pushConst(.i64, @bitCast(x)),
            .f32_const => |x| try self.pushConst(.f32, @as(u32, @bitCast(x))),
            .f64_const => |x| try self.pushConst(.f64, @bitCast(x)),

            inline .i32_load, .i64_load, .f32_load, .f64_load, .i32_load8_u, .i32_load16_u, .i32_load16_s, .i64_load8_u, .i64_load16_u, .i64_load16_s, .i64_load32_u, .i64_load32_s => |m, tag| try self.load(m, &@field(loads, @tagName(tag))),
            .i32_load8_s => |m| {
                try self.load(m, &loads.i32_load8_u);
                return self.lowerBody(&snippets.i32_extend8_s);
            },
            .i64_load8_s => |m| {
                try self.load(m, &loads.i32_load8_u);
                return self.lowerBody(&(snippets.i32_extend8_s ++ [_]Instruction{.i64_extend_i32_s}));
            },

            .i32_store => |m| try self.storeMem(m, .i32, 4),
            .i64_store => |m| try self.storeMem(m, .i64, 8),
            .f32_store => |m| try self.storeMem(m, .f32, 4),
            .f64_store => |m| try self.storeMem(m, .f64, 8),
            .i32_store8 => |m| try self.storeMem(m, .i32, 1),
            .i32_store16 => |m| try self.storeMem(m, .i32, 2),
            .i64_store8 => |m| try self.storeMem(m, .i64, 1),
            .i64_store16 => |m| try self.storeMem(m, .i64, 2),
            .i64_store32 => |m| try self.storeMem(m, .i64, 4),
            .memory_size => try self.push(.{ .ty = .i32, .kind = .shared, .sym = (try self.memory()).pages, .nonneg = true }),
            .memory_grow, .memory_copy, .memory_fill => {
                try self.flushLoads();
                switch (ins) {
                    .memory_grow => try self.memoryGrow(),
                    .memory_copy => try self.memoryCopy(),
                    else => try self.memoryFill(),
                }
            },
            .memory_init => |segment| {
                try self.flushLoads();
                const mem = try self.memory();
                var n = try self.pop();
                var src = try self.pop();
                var dst = try self.pop();
                // Out-of-range offsets make BlockCopy throw, as the
                // instruction traps.
                try self.a.call(block_copy, &.{ try self.t.segmentSym(segment), try self.operand(&src), mem.sym, try self.operand(&dst), try self.operand(&n) });
                try self.release(n);
                try self.release(src);
                try self.release(dst);
            },
            // A dropped segment behaves as an empty one from then on.
            .data_drop => |segment| if (self.t.mod.datas[@min(segment, self.t.mod.datas.len - 1)].passive) {
                try self.a.copy(try self.t.emptySegment(), try self.t.segmentSym(segment));
            },
            .atomic => return self.t.fail(error.Unsupported, "function {s} uses atomic instructions (threads proposal); the Udon VM runs one thread. `wasdon-zig inspect` lists everything a module needs", .{self.f.name}),

            .i32_eqz => try self.eqz(.i32),
            .i64_eqz => try self.eqz(.i64),
            inline .i32_eq, .i32_ne, .i32_lt_s, .i32_le_s, .i32_gt_s, .i32_ge_s => |_, tag| try self.compare(.i32, comptime cmpOf(tag), false),
            inline .i32_lt_u, .i32_le_u, .i32_gt_u, .i32_ge_u => |_, tag| try self.compare(.i32, comptime cmpOf(tag), true),
            inline .i64_eq, .i64_ne, .i64_lt_s, .i64_le_s, .i64_gt_s, .i64_ge_s => |_, tag| try self.compare(.i64, comptime cmpOf(tag), false),
            inline .i64_lt_u, .i64_le_u, .i64_gt_u, .i64_ge_u => |_, tag| try self.compare(.i64, comptime cmpOf(tag), true),
            inline .f32_eq, .f32_ne, .f32_lt, .f32_le, .f32_gt, .f32_ge => |_, tag| try self.compare(.f32, comptime cmpOf(tag), false),
            inline .f64_eq, .f64_ne, .f64_lt, .f64_le, .f64_gt, .f64_ge => |_, tag| try self.compare(.f64, comptime cmpOf(tag), false),

            inline .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s => |_, tag| try self.binary(.i32, comptime binOf(tag)),
            inline .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s => |_, tag| try self.binary(.i64, comptime binOf(tag)),
            inline .f32_add, .f32_sub, .f32_mul, .f32_div => |_, tag| try self.binary(.f32, comptime binOf(tag)),
            inline .f64_add, .f64_sub, .f64_mul, .f64_div => |_, tag| try self.binary(.f64, comptime binOf(tag)),
            .i32_shr_u => try self.shrU(.i32),
            .i64_shr_u => try self.shrU(.i64),
            .i32_rem_s => try self.remS(.i32),
            .i64_rem_s => try self.remS(.i64),
            .i32_div_u => try self.divRemU32(.div_s),
            .i32_rem_u => try self.divRemU32(.rem_s),
            .i32_rotl => try self.rotate(.i32, true),
            .i32_rotr => try self.rotate(.i32, false),
            .i64_rotl => try self.rotate(.i64, true),
            .i64_rotr => try self.rotate(.i64, false),

            .f32_min => try self.simple(.f32, 2, "SystemMath.__Min__SystemSingle_SystemSingle__SystemSingle"),
            .f32_max => try self.simple(.f32, 2, "SystemMath.__Max__SystemSingle_SystemSingle__SystemSingle"),
            .f64_min => try self.simple(.f64, 2, "SystemMath.__Min__SystemDouble_SystemDouble__SystemDouble"),
            .f64_max => try self.simple(.f64, 2, "SystemMath.__Max__SystemDouble_SystemDouble__SystemDouble"),
            .f32_abs => try self.simple(.f32, 1, "SystemMath.__Abs__SystemSingle__SystemSingle"),
            .f32_neg => try self.simple(.f32, 1, "SystemSingle.__op_UnaryMinus__SystemSingle__SystemSingle"),
            .f32_sqrt => try self.simple(.f32, 1, "UnityEngineMathf.__Sqrt__SystemSingle__SystemSingle"),
            .f32_ceil => try self.simple(.f32, 1, "UnityEngineMathf.__Ceil__SystemSingle__SystemSingle"),
            .f32_floor => try self.simple(.f32, 1, "UnityEngineMathf.__Floor__SystemSingle__SystemSingle"),
            .f32_nearest => try self.simple(.f32, 1, "UnityEngineMathf.__Round__SystemSingle__SystemSingle"),
            .f64_abs => try self.simple(.f64, 1, "SystemMath.__Abs__SystemDouble__SystemDouble"),
            .f64_neg => try self.simple(.f64, 1, "SystemDouble.__op_UnaryMinus__SystemDouble__SystemDouble"),
            .f64_sqrt => try self.simple(.f64, 1, "SystemMath.__Sqrt__SystemDouble__SystemDouble"),
            .f64_ceil => try self.simple(.f64, 1, "SystemMath.__Ceiling__SystemDouble__SystemDouble"),
            .f64_floor => try self.simple(.f64, 1, "SystemMath.__Floor__SystemDouble__SystemDouble"),
            .f64_trunc => try self.simple(.f64, 1, "SystemMath.__Truncate__SystemDouble__SystemDouble"),
            .f64_nearest => try self.simple(.f64, 1, "SystemMath.__Round__SystemDouble__SystemDouble"),

            .i32_wrap_i64 => try self.wrap(),
            .i64_extend_i32_s => try self.extend(true),
            .i64_extend_i32_u => try self.extend(false),
            .i32_trunc_f64_s => {
                try self.simple(.f64, 1, "SystemMath.__Truncate__SystemDouble__SystemDouble");
                try self.simple(.i32, 1, "SystemConvert.__ToInt32__SystemDouble__SystemInt32");
            },
            .i64_trunc_f64_s => {
                try self.simple(.f64, 1, "SystemMath.__Truncate__SystemDouble__SystemDouble");
                try self.simple(.i64, 1, "SystemConvert.__ToInt64__SystemDouble__SystemInt64");
            },
            .f32_convert_i32_s => try self.simple(.f32, 1, "SystemConvert.__ToSingle__SystemInt32__SystemSingle"),
            .f32_convert_i64_s => try self.simple(.f32, 1, "SystemConvert.__ToSingle__SystemInt64__SystemSingle"),
            .f64_convert_i32_s => try self.simple(.f64, 1, "SystemConvert.__ToDouble__SystemInt32__SystemDouble"),
            .f64_convert_i64_s => try self.simple(.f64, 1, "SystemConvert.__ToDouble__SystemInt64__SystemDouble"),
            .f32_demote_f64 => try self.simple(.f32, 1, "SystemConvert.__ToSingle__SystemDouble__SystemSingle"),
            .f64_promote_f32 => try self.simple(.f64, 1, "SystemConvert.__ToDouble__SystemSingle__SystemDouble"),
            .i32_reinterpret_f32 => try self.simple(.i32, 1, "SystemBitConverter.__SingleToInt32Bits__SystemSingle__SystemInt32"),
            .i64_reinterpret_f64 => try self.simple(.i64, 1, "SystemBitConverter.__DoubleToInt64Bits__SystemDouble__SystemInt64"),
            .f32_reinterpret_i32 => try self.simple(.f32, 1, "SystemBitConverter.__Int32BitsToSingle__SystemInt32__SystemSingle"),
            .f64_reinterpret_i64 => try self.simple(.f64, 1, "SystemBitConverter.__Int64BitsToDouble__SystemInt64__SystemDouble"),

            // Everything else is expressed through the instructions above.
            inline else => |_, tag| return self.lowerBody(&@field(snippets, @tagName(tag))),
        }
        return true;
    }

    fn global(self: *Lowerer, i: u32) Error!tr.Global {
        if (i >= self.t.globals.len) return self.t.fail(error.Invalid, "global {d} does not exist", .{i});
        return self.t.globals[i];
    }

    // ------------------------------------------------------------------
    //  Numeric
    // ------------------------------------------------------------------

    const Bin = enum { add, sub, mul, div_s, rem_s, and_, or_, xor, shl, shr_s };
    const Cmp = enum { eq, ne, lt, le, gt, ge };

    fn binOf(comptime tag: std.meta.Tag(Instruction)) Bin {
        @setEvalBranchQuota(10_000);
        const n = @tagName(tag)[4..];
        if (std.mem.eql(u8, n, "and")) return .and_;
        if (std.mem.eql(u8, n, "or")) return .or_;
        if (std.mem.eql(u8, n, "div")) return .div_s;
        return std.meta.stringToEnum(Bin, n).?;
    }

    fn cmpOf(comptime tag: std.meta.Tag(Instruction)) Cmp {
        @setEvalBranchQuota(10_000);
        return std.meta.stringToEnum(Cmp, @tagName(tag)[4..6]).?;
    }

    fn binSig(ty: ValType, op: Bin) []const u8 {
        const table = comptime blk: {
            var t: [4][10][]const u8 = undefined;
            const names = [_][]const u8{ "Addition", "Subtraction", "Multiplication", "Division", "Remainder", "LogicalAnd", "LogicalOr", "LogicalXor", "LeftShift", "RightShift" };
            for ([_]ValType{ .i32, .i64, .f32, .f64 }, 0..) |vt, ti| {
                const n = tr.udonType(vt);
                for (names, 0..) |op_name, oi| {
                    const rhs = if (oi >= 8) "SystemInt32" else n;
                    t[ti][oi] = n ++ ".__op_" ++ op_name ++ "__" ++ n ++ "_" ++ rhs ++ "__" ++ n;
                }
            }
            break :blk t;
        };
        return table[tr.typeIndex(ty)][@intFromEnum(op)];
    }

    fn cmpSig(ty: ValType, op: Cmp) []const u8 {
        const table = comptime blk: {
            var t: [4][6][]const u8 = undefined;
            const names = [_][]const u8{ "Equality", "Inequality", "LessThan", "LessThanOrEqual", "GreaterThan", "GreaterThanOrEqual" };
            for ([_]ValType{ .i32, .i64, .f32, .f64 }, 0..) |vt, ti| {
                const n = tr.udonType(vt);
                for (names, 0..) |op_name, oi| t[ti][oi] = n ++ ".__op_" ++ op_name ++ "__" ++ n ++ "_" ++ n ++ "__SystemBoolean";
            }
            break :blk t;
        };
        return table[tr.typeIndex(ty)][@intFromEnum(op)];
    }

    fn isInt(ty: ValType) bool {
        return ty == .i32 or ty == .i64;
    }

    fn signed(ty: ValType, bits: u64) i64 {
        return if (ty == .i32) @as(i32, @bitCast(@as(u32, @truncate(bits)))) else @bitCast(bits);
    }

    fn unsignedBits(ty: ValType, x: i64) u64 {
        return if (ty == .i32) @as(u32, @bitCast(@as(i32, @truncate(x)))) else @bitCast(x);
    }

    /// Constant-fold an integer operation; null when it would trap.
    fn fold(ty: ValType, op: Bin, a_bits: u64, b_bits: u64) ?u64 {
        const a = signed(ty, a_bits);
        const b = signed(ty, b_bits);
        const width: u7 = if (ty == .i32) 32 else 64;
        const sh: u6 = @intCast(@as(u64, @bitCast(b)) & (width - 1));
        const r: i64 = switch (op) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
            .and_ => a & b,
            .or_ => a | b,
            .xor => a ^ b,
            .shl => a << sh,
            .shr_s => a >> sh,
            .div_s, .rem_s => blk: {
                if (b == 0) return null;
                const min: i64 = if (ty == .i32) std.math.minInt(i32) else std.math.minInt(i64);
                if (a == min and b == -1) return if (op == .rem_s) 0 else null;
                break :blk if (op == .div_s) @divTrunc(a, b) else @rem(a, b);
            },
        };
        return unsignedBits(ty, r);
    }

    fn binary(self: *Lowerer, ty: ValType, op: Bin) Error!void {
        var b = try self.pop();
        var a = try self.pop();
        const shift = op == .shl or op == .shr_s;
        if (isInt(ty)) {
            if (a.kind == .konst and b.kind == .konst) {
                if (fold(ty, op, a.bits, b.bits)) |r| return self.pushConst(ty, r);
            }
            // A constant goes second, where the patterns below look for it.
            const commutes = op == .add or op == .mul or op == .and_ or op == .or_ or op == .xor;
            if (commutes and a.kind == .konst) std.mem.swap(Entry, &a, &b);
            // (x & m) & c is x & (m & c): narrow the constant of the `&`
            // just emitted instead of emitting another.
            if (op == .and_ and b.kind == .konst and a.mask != null and a.kind == .temp and a.def_end == self.a.here() and !self.t.options.disable.masks) {
                const merged = a.mask.? & b.bits;
                self.a.code.items[a.def - 1].arg = try self.t.constSym(ty, merged);
                a.mask = merged;
                a.nonneg = a.nonneg or b.nonneg;
                return self.push(a);
            }
            // x op identity → x.
            const b_ident = b.kind == .konst and switch (op) {
                .add, .sub, .or_, .xor, .shl, .shr_s => b.bits == 0,
                .mul, .div_s => signed(ty, b.bits) == 1,
                .and_ => signed(ty, b.bits) == -1 or (a.isByte() and b.bits & 255 == 255),
                .rem_s => false,
            };
            if (b_ident) return self.push(a);
            const a_ident = a.kind == .konst and switch (op) {
                .add, .or_, .xor => a.bits == 0,
                .mul => signed(ty, a.bits) == 1,
                .and_ => signed(ty, a.bits) == -1,
                else => false,
            };
            if (a_ident) return self.push(b);
        }
        if (ty == .i32 and bothBytes(a, b)) {
            if (byteBinSig(op)) |sig| return self.result(.i32, sig, &try self.byteOperands(&a, &b));
        }
        // 64-bit shifts take an Int32 count.
        if (shift and ty == .i64) try self.shiftCount(&b);
        const nonneg = isInt(ty) and switch (op) {
            .and_ => a.nonneg or b.nonneg,
            .or_, .xor, .div_s, .rem_s => a.nonneg and b.nonneg,
            .shr_s => a.nonneg,
            else => false,
        };
        if (try self.invariantBinary(ty, op, a, b)) |sym| {
            return self.push(.{ .kind = .alias, .ty = ty, .sym = sym, .nonneg = nonneg });
        }
        const sa = try self.operand(&a);
        const sb = try self.operand(&b);
        try self.release(a);
        try self.release(b);
        try self.result(ty, binSig(ty, op), &.{ sa, sb });
        const top = &self.stack.items[self.stack.items.len - 1];
        top.nonneg = nonneg;
        if (op == .and_ and b.kind == .konst) top.mask = b.bits;
    }

    /// `SystemByte` operator for an i32 operation on two unsigned bytes.
    /// C# computes these on `int`s, so the result is the i32 result; a shift
    /// count is masked to five bits as in WASM.
    fn byteBinSig(op: Bin) ?[]const u8 {
        return switch (op) {
            .add => byteSig("Addition", "SystemInt32"),
            .sub => byteSig("Subtraction", "SystemInt32"),
            .mul => byteSig("Multiplication", "SystemInt32"),
            .and_ => byteSig("LogicalAnd", "SystemInt32"),
            .or_ => byteSig("LogicalOr", "SystemInt32"),
            .xor => byteSig("LogicalXor", "SystemInt32"),
            .shl => byteSig("LeftShift", "SystemInt32"),
            .shr_s => byteSig("RightShift", "SystemInt32"),
            .div_s, .rem_s => null,
        };
    }

    fn byteCmpSig(op: Cmp) []const u8 {
        return switch (op) {
            .eq => byteSig("Equality", "SystemBoolean"),
            .ne => byteSig("Inequality", "SystemBoolean"),
            .lt => byteSig("LessThan", "SystemBoolean"),
            .le => byteSig("LessThanOrEqual", "SystemBoolean"),
            .gt => byteSig("GreaterThan", "SystemBoolean"),
            .ge => byteSig("GreaterThanOrEqual", "SystemBoolean"),
        };
    }

    fn byteSig(comptime name: []const u8, comptime ret: []const u8) []const u8 {
        return "SystemByte.__op_" ++ name ++ "__SystemByte_SystemByte__" ++ ret;
    }

    /// Both operands are unsigned bytes still in memory, or constants a
    /// byte can hold, and at least one is in memory: a `SystemByte`
    /// operator can take them as they are, sparing each its conversion to
    /// Int32.
    fn bothBytes(a: Entry, b: Entry) bool {
        return (a.isByte() or b.isByte()) and (a.isByte() or a.isByteConst()) and (b.isByte() or b.isByteConst());
    }

    /// The two `SystemByte` operands of a byte operator, entries released.
    fn byteOperands(self: *Lowerer, a: *Entry, b: *Entry) Error![2]Sym {
        const sa = try self.byteOperand(a);
        const sb = try self.byteOperand(b);
        try self.release(a.*);
        try self.release(b.*);
        return .{ sa, sb };
    }

    /// Turn an i64 shift count into the Int32 the .NET operators take. The
    /// operators mask the count themselves, as WASM requires.
    fn shiftCount(self: *Lowerer, b: *Entry) Error!void {
        if (b.kind == .konst) {
            b.* = .{ .ty = .i32, .kind = .konst, .bits = b.bits & 63, .nonneg = true };
            return;
        }
        try self.push(b.*);
        try self.pushConst(.i64, 63);
        try self.binary(.i64, .and_);
        try self.simple(.i32, 1, "SystemConvert.__ToInt32__SystemInt64__SystemInt32");
        b.* = try self.pop();
    }

    /// One extern, `n` operands of whatever types are on the stack.
    fn simple(self: *Lowerer, ty: ValType, comptime n: usize, sig: []const u8) Error!void {
        var ins: [n]Sym = undefined;
        var entries: [n]Entry = undefined;
        var k: usize = n;
        while (k > 0) {
            k -= 1;
            entries[k] = try self.pop();
        }
        for (&entries, &ins) |*e, *s| s.* = try self.operand(e);
        for (entries) |e| try self.release(e);
        try self.result(ty, sig, &ins);
    }

    fn eqz(self: *Lowerer, ty: ValType) Error!void {
        var a = try self.pop();
        if (a.kind == .konst) return self.pushI32(@intFromBool(a.bits == 0));
        if (a.isByte()) _ = try self.condBool(&a, true);
        if (a.kind == .cond) {
            a.negated = !a.negated;
            return self.push(a);
        }
        const s = try self.operand(&a);
        try self.release(a);
        try self.resultCond(cmpSig(ty, .eq), cmpSig(ty, .ne), &.{ s, try self.t.constSym(ty, 0) });
    }

    fn foldCmp(ty: ValType, op: Cmp, a_bits: u64, b_bits: u64, unsigned: bool) bool {
        const mask: u64 = if (ty == .i32) 0xFFFF_FFFF else std.math.maxInt(u64);
        return if (unsigned) holds(op, a_bits & mask, b_bits & mask) else holds(op, signed(ty, a_bits), signed(ty, b_bits));
    }

    fn holds(op: Cmp, a: anytype, b: @TypeOf(a)) bool {
        return switch (op) {
            .eq => a == b,
            .ne => a != b,
            .lt => a < b,
            .le => a <= b,
            .gt => a > b,
            .ge => a >= b,
        };
    }

    fn inverse(op: Cmp) Cmp {
        return switch (op) {
            .eq => .ne,
            .ne => .eq,
            .lt => .ge,
            .ge => .lt,
            .le => .gt,
            .gt => .le,
        };
    }

    fn compare(self: *Lowerer, ty: ValType, op: Cmp, unsigned: bool) Error!void {
        var b = try self.pop();
        var a = try self.pop();
        if (isInt(ty) and a.kind == .konst and b.kind == .konst)
            return self.pushI32(@intFromBool(foldCmp(ty, op, a.bits, b.bits, unsigned)));
        if (ty == .i32 and bothBytes(a, b)) {
            // Against zero, (in)equality is the one-extern byte test.
            const zero_test = (op == .eq or op == .ne) and (a.isZero() or b.isZero());
            if (zero_test) {
                var byte = if (a.isZero()) b else a;
                _ = try self.condBool(&byte, true);
                byte.negated = op == .eq;
                return self.push(byte);
            }
            // Bytes are 0..255: signed and unsigned order agree.
            return self.resultCond(byteCmpSig(op), byteCmpSig(inverse(op)), &try self.byteOperands(&a, &b));
        }
        // Unsigned order equals signed order once both sign bits are
        // flipped; operands known to be non-negative need no flip.
        if (unsigned and !(a.nonneg and b.nonneg)) {
            try self.flipSign(&a);
            try self.flipSign(&b);
        }
        const sa = try self.operand(&a);
        const sb = try self.operand(&b);
        try self.release(a);
        try self.release(b);
        // A float comparison is false for NaN whichever way it is written,
        // so only (in)equality may be replaced by its opposite.
        const flip: ?[]const u8 = if (isInt(ty) or op == .eq or op == .ne) cmpSig(ty, inverse(op)) else null;
        try self.resultCond(cmpSig(ty, op), flip, &.{ sa, sb });
    }

    fn flipSign(self: *Lowerer, e: *Entry) Error!void {
        const min: u64 = if (e.ty == .i32) 0x8000_0000 else 0x8000_0000_0000_0000;
        if (e.kind == .konst) {
            e.bits ^= min;
            e.nonneg = false;
            return;
        }
        if (e.kind == .local and e.ty == .i32) {
            e.* = .{ .ty = .i32, .kind = .alias, .sym = try self.derive(.xor, e.local, e.sym, 0x8000_0000) };
            return;
        }
        try self.push(e.*);
        try self.pushConst(e.ty, min);
        try self.binary(e.ty, .xor);
        e.* = try self.pop();
    }

    /// Logical shift right, built from the arithmetic one.
    fn shrU(self: *Lowerer, ty: ValType) Error!void {
        var n = try self.pop();
        const a = try self.pop();
        const width: u64 = if (ty == .i32) 32 else 64;
        const all: u64 = if (ty == .i32) 0xFFFF_FFFF else 0xFFFF_FFFF_FFFF_FFFF;
        if (n.kind == .konst) {
            const c = n.bits & (width - 1);
            if (a.kind == .konst) return self.pushConst(ty, (a.bits & all) >> @intCast(c));
            if (c == 0) return self.push(a);
            const a_nonneg = a.nonneg;
            try self.push(a);
            try self.pushConst(ty, c);
            try self.binary(ty, .shr_s);
            if (!a_nonneg) {
                // Clear the sign bits the arithmetic shift copied in.
                try self.pushConst(ty, all >> @intCast(c));
                try self.binary(ty, .and_);
            }
            self.stack.items[self.stack.items.len - 1].nonneg = true;
            return;
        }
        if (a.nonneg) {
            try self.push(a);
            try self.push(n);
            return self.binary(ty, .shr_s);
        }
        // (a >> n) & ~((MIN >> n) << 1): the mask keeps the low width-n bits.
        const an = try self.alias(&n);
        try self.push(a);
        try self.push(an);
        try self.binary(ty, .shr_s);
        try self.pushConst(ty, (all >> 1) + 1);
        try self.push(an);
        try self.binary(ty, .shr_s);
        try self.pushConst(ty, 1);
        try self.binary(ty, .shl);
        try self.pushConst(ty, all);
        try self.binary(ty, .xor);
        try self.binary(ty, .and_);
        try self.release(n);
    }

    fn rotate(self: *Lowerer, ty: ValType, left: bool) Error!void {
        var n = try self.pop();
        var a = try self.pop();
        const width: u64 = if (ty == .i32) 32 else 64;
        const aa = try self.alias(&a);
        const an = try self.alias(&n);
        // rotl(a, n) = (a << n) | (a >>> (width - n)); rotr swaps the shifts.
        try self.push(aa);
        try self.push(an);
        if (left) try self.binary(ty, .shl) else try self.shrU(ty);
        try self.push(aa);
        try self.pushConst(ty, width);
        try self.push(an);
        try self.binary(ty, .sub);
        if (left) try self.shrU(ty) else try self.binary(ty, .shl);
        try self.binary(ty, .or_);
        try self.release(a);
        try self.release(n);
    }

    /// Signed remainder. .NET throws for `MIN % -1` where WASM yields 0, so
    /// a divisor that may be -1 is tested first.
    fn remS(self: *Lowerer, ty: ValType) Error!void {
        var b = try self.pop();
        var a = try self.pop();
        if (b.kind == .konst) {
            if (a.kind == .konst) if (fold(ty, .rem_s, a.bits, b.bits)) |r| return self.pushConst(ty, r);
            if (signed(ty, b.bits) == -1) {
                try self.release(a);
                return self.pushConst(ty, 0);
            }
            try self.push(a);
            try self.push(b);
            return self.remRaw(ty);
        }
        const sb = try self.operand(&b);
        const bool_pool = try self.poolFor("SystemBoolean");
        const is_m1 = try self.newTemp(bool_pool);
        const pool = try self.valPool(ty);
        const d = try self.newTemp(pool);
        const do_rem = try self.a.newLabel();
        const end = try self.a.newLabel();
        try self.a.call(cmpSig(ty, .eq), &.{ sb, try self.t.constSym(ty, unsignedBits(ty, -1)), is_m1 });
        try self.a.jumpIfFalse(is_m1, do_rem);
        try self.freeTemp(bool_pool, is_m1);
        try self.a.copy(try self.t.constSym(ty, 0), d);
        try self.a.jump(end);
        self.a.bind(do_rem);
        try self.push(try self.alias(&a));
        try self.push(try self.alias(&b));
        try self.remRaw(ty);
        try self.store(try self.pop(), d);
        self.a.bind(end);
        try self.release(a);
        try self.release(b);
        try self.push(.{ .ty = ty, .kind = .temp, .sym = d, .owned = true, .pool = pool });
    }

    /// Remainder with no overflow guard. Int64 has no remainder operator in
    /// Udon; `Math.DivRem` provides it.
    fn remRaw(self: *Lowerer, ty: ValType) Error!void {
        if (ty == .i32) return self.binary(.i32, .rem_s);
        var b = try self.pop();
        var a = try self.pop();
        const sa = try self.operand(&a);
        const sb = try self.operand(&b);
        try self.release(a);
        try self.release(b);
        const pool = try self.valPool(.i64);
        const rem = try self.newTemp(pool);
        const quot = try self.newTemp(pool);
        try self.a.call("SystemMath.__DivRem__SystemInt64_SystemInt64_SystemInt64Ref__SystemInt64", &.{ sa, sb, rem, quot });
        try self.freeTemp(pool, quot);
        try self.push(.{ .ty = .i64, .kind = .temp, .sym = rem, .owned = true, .pool = pool });
    }

    /// Unsigned 32-bit division/remainder, done in 64 bits where both
    /// operands are non-negative.
    fn divRemU32(self: *Lowerer, op: Bin) Error!void {
        const b = try self.pop();
        const a = try self.pop();
        if (a.nonneg and b.nonneg) {
            try self.push(a);
            try self.push(b);
            return if (op == .div_s) self.binary(.i32, .div_s) else self.remS(.i32);
        }
        try self.push(a);
        try self.extend(false);
        try self.push(b);
        try self.extend(false);
        if (op == .div_s) try self.binary(.i64, .div_s) else try self.remRaw(.i64);
        try self.wrap();
    }

    fn extend(self: *Lowerer, is_signed: bool) Error!void {
        var a = try self.pop();
        if (a.kind == .konst) {
            const x: i64 = if (is_signed) signed(.i32, a.bits) else @intCast(a.bits & 0xFFFF_FFFF);
            return self.pushConst(.i64, @bitCast(x));
        }
        const nonneg = a.nonneg;
        const s = try self.operand(&a);
        try self.release(a);
        try self.result(.i64, "SystemConvert.__ToInt64__SystemInt32__SystemInt64", &.{s});
        if (!is_signed and !nonneg) {
            try self.pushConst(.i64, 0xFFFF_FFFF);
            try self.binary(.i64, .and_);
        }
        self.stack.items[self.stack.items.len - 1].nonneg = !is_signed or nonneg;
    }

    /// `i32.wrap_i64`. `Convert.ToInt32(Int64)` is range-checked, so the low
    /// half is sign-extended in place first.
    fn wrap(self: *Lowerer) Error!void {
        const a = try self.pop();
        if (a.kind == .konst) return self.pushConst(.i32, a.bits & 0xFFFF_FFFF);
        try self.push(a);
        try self.pushI32(32);
        try self.binary(.i64, .shl);
        try self.pushI32(32);
        try self.binary(.i64, .shr_s);
        try self.simple(.i32, 1, "SystemConvert.__ToInt32__SystemInt64__SystemInt32");
    }

    fn lowerSelect(self: *Lowerer) Error!void {
        var c = try self.pop();
        var v2 = try self.pop();
        var v1 = try self.pop();
        if (c.kind == .konst) {
            try self.release(if (c.bits != 0) v2 else v1);
            return self.push(if (c.bits != 0) v1 else v2);
        }
        const ty = v1.ty;
        const end = try self.a.newLabel();
        // When one operand already sits in its own temporary, that
        // temporary becomes the result and only the other case copies.
        if (v1.kind == .temp or v2.kind == .temp) {
            const keep_first = v1.kind == .temp;
            var kept = if (keep_first) v1 else v2;
            var other = if (keep_first) v2 else v1;
            const so = try self.operand(&other);
            // Skip the copy when the kept operand is the selected one.
            try self.branchIf(&c, keep_first, end);
            try self.release(c);
            try self.a.copy(so, kept.sym);
            self.a.bind(end);
            try self.release(other);
            kept.def = no_def;
            kept.nonneg = v1.nonneg and v2.nonneg;
            return self.push(kept);
        }
        const first = try self.operand(&v1);
        const s2 = try self.operand(&v2);
        const pool = try self.valPool(ty);
        const d = try self.newTemp(pool);
        const second = try self.a.newLabel();
        try self.branchIf(&c, false, second);
        try self.release(c);
        try self.a.copy(first, d);
        try self.a.jump(end);
        self.a.bind(second);
        try self.a.copy(s2, d);
        self.a.bind(end);
        try self.release(v1);
        try self.release(v2);
        try self.push(.{ .ty = ty, .kind = .temp, .sym = d, .owned = true, .pool = pool, .nonneg = v1.nonneg and v2.nonneg });
    }

    // ------------------------------------------------------------------
    //  Linear memory
    // ------------------------------------------------------------------

    const block_copy = tr.block_copy;

    const Memory = struct { sym: Sym, pages: Sym };

    fn memory(self: *Lowerer) Error!Memory {
        const sym = self.t.mem orelse return self.t.fail(error.Invalid, "function {s} accesses linear memory, but the module has none", .{self.f.name});
        return .{ .sym = sym, .pages = self.t.mem_pages };
    }

    /// Replace the address entry by one for `address + offset`.
    fn effectiveAddress(self: *Lowerer, e: *Entry, offset: u32) Error!Sym {
        if (offset != 0 and e.kind == .local) return self.derive(.add, e.local, e.sym, offset);
        if (offset != 0) {
            try self.push(e.*);
            try self.pushConst(.i32, offset);
            try self.binary(.i32, .add);
            e.* = try self.pop();
        }
        return self.operand(e);
    }

    /// Push a load as a pending `.mem` entry. It stays pending only while
    /// its address cannot change under it: a constant, a local (flushed
    /// when the local is written) or a temporary the entry owns.
    fn load(self: *Lowerer, m: wasm.instruction.MemArg, op: *const Load) Error!void {
        _ = try self.memory();
        var addr = try self.pop();
        if (addr.kind == .mem) try self.loadNow(&addr);
        var e: Entry = .{ .ty = op.ty, .kind = .mem, .load = op, .offset = m.offset, .nonneg = op.nonneg, .base = addr.kind };
        switch (addr.kind) {
            .konst => {
                e.bits = (addr.bits +% m.offset) & 0xFFFF_FFFF;
                e.offset = 0;
            },
            .local => {
                e.sym = addr.sym;
                e.local = addr.local;
            },
            .temp => {
                e.sym = addr.sym;
                e.owned = addr.owned;
                e.pool = addr.pool;
            },
            else => {
                e.base = .alias;
                e.sym = try self.operand(&addr);
                e.owned = addr.owned;
                e.pool = addr.pool;
                try self.loadNow(&e);
            },
        }
        if (self.t.options.disable.pending_loads and e.kind == .mem) try self.loadNow(&e);
        try self.push(e);
    }

    /// Address of a pending load, in a slot.
    fn loadAddress(self: *Lowerer, e: *Entry) Error!Sym {
        var base = e.address();
        const sa = try self.effectiveAddress(&base, e.offset);
        // The entry owned its address temporary; whatever `base` is now
        // takes its place. Freed slots stay readable until reallocated,
        // which the callers do only after using `sa`.
        try self.release(base);
        e.owned = false;
        return sa;
    }

    /// Emit a pending load; the entry becomes an ordinary temporary.
    fn loadNow(self: *Lowerer, e: *Entry) Error!void {
        const op = e.load.?;
        const mem = try self.memory();
        const sa = try self.loadAddress(e);
        if (op.widen) |widen| {
            const raw = try self.readRaw(op, mem.sym, sa);
            e.* = try self.compute(op.ty, try self.valPool(op.ty), widen, &.{raw});
        } else e.* = try self.compute(op.ty, try self.valPool(op.ty), op.read, &.{ mem.sym, sa });
        e.nonneg = op.nonneg;
    }

    /// The narrow value of a load, in a scratch slot of its .NET type that
    /// is valid until the next temporary of that type is allocated.
    fn readRaw(self: *Lowerer, op: *const Load, mem: Sym, addr: Sym) Error!Sym {
        const pool = try self.poolFor(op.raw.?);
        const raw = try self.newTemp(pool);
        try self.a.call(op.read, &.{ mem, addr, raw });
        try self.freeTemp(pool, raw);
        return raw;
    }

    /// Emit every pending load: memory is about to change.
    fn flushLoads(self: *Lowerer) Error!void {
        for (self.stack.items) |*e| if (e.kind == .mem) try self.loadNow(e);
    }

    /// A pending unsigned-byte load as the `SystemByte` it reads, for a
    /// byte operator. Consumes the entry.
    fn byteOperand(self: *Lowerer, e: *Entry) Error!Sym {
        if (e.kind == .byte_local) return e.sym;
        if (e.kind == .konst) return self.t.constByte(@intCast(e.bits));
        const mem = try self.memory();
        const sa = try self.loadAddress(e);
        const pool = try self.poolFor("SystemByte");
        const raw = try self.newTemp(pool);
        try self.a.call(e.load.?.read, &.{ mem.sym, sa, raw });
        e.* = .{ .ty = .i32, .kind = .temp, .sym = raw, .owned = true, .pool = pool };
        return raw;
    }

    /// Store the low `size` bytes of a value. A constant is copied straight
    /// from the constant pool; anything else goes through a one-element
    /// array of its type, which `Buffer.BlockCopy` reads as bytes.
    fn storeMem(self: *Lowerer, m: wasm.instruction.MemArg, ty: ValType, size: u8) Error!void {
        const mem = try self.memory();
        var v = try self.pop();
        var addr = try self.pop();
        // Loads that came before this store must read what was there.
        try self.flushLoads();
        if (addr.kind == .mem) try self.loadNow(&addr);
        const n = try self.t.constI32(size);
        if (v.kind == .mem and v.load.?.size >= size and !self.t.options.disable.memory_copies) {
            // Loaded only to be stored: copy the bytes within memory.
            const src = try self.loadAddress(&v);
            const dst = try self.effectiveAddress(&addr, m.offset);
            try self.a.call(block_copy, &.{ mem.sym, src, mem.sym, dst, n });
            return self.release(addr);
        }
        const sa = try self.effectiveAddress(&addr, m.offset);
        const c0 = try self.t.constI32(0);
        if (v.kind == .byte_local and size == 1) {
            try self.a.call("SystemByteArray.__Set__SystemInt32_SystemByte__SystemVoid", &.{ mem.sym, sa, v.sym });
        } else if (v.kind == .konst) {
            const off = try self.t.poolOffset(size, if (size == 8) v.bits else v.bits & ((@as(u64, 1) << @intCast(@as(u32, size) * 8)) - 1));
            try self.a.call(block_copy, &.{ try self.t.poolSym(), try self.t.constI32(@intCast(off)), mem.sym, sa, n });
        } else {
            const set = switch (ty) {
                .i32 => "SystemInt32Array.__Set__SystemInt32_SystemInt32__SystemVoid",
                .i64 => "SystemInt64Array.__Set__SystemInt32_SystemInt64__SystemVoid",
                .f32 => "SystemSingleArray.__Set__SystemInt32_SystemSingle__SystemVoid",
                .f64 => "SystemDoubleArray.__Set__SystemInt32_SystemDouble__SystemVoid",
            };
            const st = try self.t.storeArray(ty);
            try self.a.call(set, &.{ st, c0, try self.operand(&v) });
            try self.a.call(block_copy, &.{ st, c0, mem.sym, sa, n });
        }
        try self.release(v);
        try self.release(addr);
    }

    /// Call a runtime routine with up to three i32 arguments.
    fn callRoutine(self: *Lowerer, r: Translator.Routine, n_args: usize) Error!void {
        var k = n_args;
        while (k > 0) {
            k -= 1;
            try self.store(try self.pop(), r.args[k]);
        }
        const back = try self.a.newLabel();
        try self.a.copy(try self.t.newRac(back), r.ra);
        try self.a.jump(r.label);
        self.a.bind(back);
    }

    fn memoryGrow(self: *Lowerer) Error!void {
        _ = try self.memory();
        // The routine replaces the memory array and its size.
        try self.flushShared(null, self.stack.items.len - 1);
        try self.callRoutine(try self.t.growRoutine(), 1);
        try self.push(.{ .ty = .i32, .kind = .shared, .sym = try self.t.retSym(0, .i32) });
    }

    fn memoryCopy(self: *Lowerer) Error!void {
        const mem = try self.memory();
        var n = try self.pop();
        var src = try self.pop();
        var dst = try self.pop();
        // BlockCopy handles overlap like memmove, as memory.copy requires.
        try self.a.call(block_copy, &.{ mem.sym, try self.operand(&src), mem.sym, try self.operand(&dst), try self.operand(&n) });
        try self.release(n);
        try self.release(src);
        try self.release(dst);
    }

    fn memoryFill(self: *Lowerer) Error!void {
        const mem = try self.memory();
        const value = self.stack.items[self.stack.items.len - 2];
        if (value.isZero()) {
            var n = try self.pop();
            _ = try self.pop();
            var dst = try self.pop();
            try self.a.call("SystemArray.__Clear__SystemArray_SystemInt32_SystemInt32__SystemVoid", &.{ mem.sym, try self.operand(&dst), try self.operand(&n) });
            try self.release(n);
            return self.release(dst);
        }
        try self.callRoutine(try self.t.fillRoutine(), 3);
    }

    // ------------------------------------------------------------------
    //  Calls
    // ------------------------------------------------------------------

    /// What a call that may re-enter this function has to preserve: the
    /// locals still read afterwards, the operands waiting below the call's
    /// arguments, and the return address. Block result slots and scratch
    /// slots are never live across a call.
    fn frameSlots(self: *Lowerer, below: usize) Error![]Sym {
        var list: std.ArrayList(Sym) = .empty;
        const a = self.t.arena();
        const call = self.current.?;
        for (self.f.locals, 0..) |sym, i| {
            // An operand below the arguments may be a local that has not
            // been read yet as far as the emitted code goes: the
            // instruction stream read it before the call, the code will
            // read its slot after.
            const pending = for (self.stack.items[0..below]) |e| {
                if ((e.kind == .local or e.kind == .byte_local) and e.local == i) break true;
            } else false;
            if (pending or self.t.options.disable.liveness or self.live.liveAfter(call, i)) try list.append(a, sym);
        }
        for (self.stack.items[0..below]) |e| if (e.owned) try list.append(a, e.sym);
        if (self.f.ret == .indirect) try list.append(a, self.f.ra);
        return list.items;
    }

    /// Slot *k* goes to column *k* at the current depth: one extern per
    /// slot and one for the depth, whatever the frame's size.
    fn saveFrame(self: *Lowerer, slots: []const Sym) Error!void {
        if (slots.len == 0) return;
        const depth = try self.t.frameDepth();
        for (slots, 0..) |s, k| {
            try self.a.call("SystemObjectArray.__Set__SystemInt32_SystemObject__SystemVoid", &.{ try self.t.frameColumn(k), depth, s });
        }
        try self.a.call(binSig(.i32, .add), &.{ depth, try self.t.constI32(1), depth });
    }

    fn restoreFrame(self: *Lowerer, slots: []const Sym) Error!void {
        if (slots.len == 0) return;
        const depth = try self.t.frameDepth();
        try self.a.call(binSig(.i32, .sub), &.{ depth, try self.t.constI32(1), depth });
        for (slots, 0..) |s, k| {
            try self.a.call("SystemObjectArray.__Get__SystemInt32__SystemObject", &.{ try self.t.frameColumn(k), depth, s });
        }
    }

    /// Move the top `dsts.len` operands into `dsts`. The last operand is
    /// handled first so that, when it was just computed, its computation
    /// can still be retargeted at the destination.
    fn passArguments(self: *Lowerer, dsts: []const Sym, may_retarget: bool) Error!void {
        var k = dsts.len;
        while (k > 0) {
            k -= 1;
            var e = try self.pop();
            if (may_retarget) {
                try self.store(e, dsts[k]);
            } else {
                const s = try self.operand(&e);
                if (s != dsts[k]) try self.a.copy(s, dsts[k]);
                try self.release(e);
            }
        }
    }

    fn pushResultsOf(self: *Lowerer, ty: FuncType) Error!void {
        for (ty.results, 0..) |r, k| try self.push(.{ .ty = r, .kind = .shared, .sym = try self.t.retSym(@intCast(k), r) });
    }

    fn lowerCall(self: *Lowerer, callee_idx: u32) Error!void {
        if (callee_idx >= self.t.funcs.len) return self.t.fail(error.Invalid, "call to function {d}, which does not exist", .{callee_idx});
        const callee = &self.t.funcs[callee_idx];
        if (callee.import != null) return self.lowerImportCall(callee_idx);
        const n = callee.ty.params.len;
        if (self.stack.items.len < n) return self.t.fail(error.Invalid, "operand stack underflow in function {s}", .{self.f.name});
        const below = self.stack.items.len - n;
        // The callee may write globals and return registers.
        try self.flushShared(null, below);

        const reenters = self.t.mayReenter(self.f_idx, callee_idx);
        if (callee_idx == self.f_idx) {
            // Arguments of a self call are written over our own parameters;
            // any argument that still reads one must be detached first.
            for (self.stack.items[below..]) |*e| if (e.kind == .local and e.local < n) try self.materialize(e);
        }
        const slots: []const Sym = if (reenters) try self.frameSlots(below) else &.{};
        try self.saveFrame(slots);
        try self.passArguments(callee.locals[0..n], !reenters);
        try self.t.emitCall(callee);
        try self.restoreFrame(slots);
        try self.pushResultsOf(callee.ty);
    }

    fn lowerCallIndirect(self: *Lowerer, type_index: u32) Error!void {
        if (type_index >= self.t.mod.types_.len) return self.t.fail(error.Invalid, "call_indirect type index {d} out of range", .{type_index});
        const ty = self.t.mod.types_[type_index];
        var index = try self.pop();
        const n = ty.params.len;
        if (self.stack.items.len < n) return self.t.fail(error.Invalid, "operand stack underflow in function {s}", .{self.f.name});
        const below = self.stack.items.len - n;
        try self.flushShared(null, below);

        var reenters = false;
        for (self.t.table_funcs) |f| {
            if (@import("callgraph.zig").sameFuncType(self.t.funcs[f].ty, ty) and self.t.mayReenter(self.f_idx, f)) reenters = true;
        }
        const slots: []const Sym = if (reenters) try self.frameSlots(below) else &.{};
        try self.saveFrame(slots);
        const dsts = try self.t.arena().alloc(Sym, n);
        for (dsts, ty.params, 0..) |*d, p, k| d.* = try self.t.indArg(@intCast(k), p);
        try self.passArguments(dsts, !reenters);
        // Look the target up last, so the final argument's computation can
        // still be retargeted above.
        const target = try self.newTemp(try self.poolFor("SystemUInt32"));
        try self.a.call("SystemUInt32Array.__Get__SystemInt32__SystemUInt32", &.{ try self.t.tableSym(), try self.operand(&index), target });
        try self.release(index);
        const back = try self.a.newLabel();
        try self.a.copy(try self.t.newRac(back), try self.t.indRa());
        try self.a.jumpIndirect(target);
        self.a.bind(back);
        try self.freeTemp(try self.poolFor("SystemUInt32"), target);
        try self.restoreFrame(slots);
        try self.pushResultsOf(ty);
    }

    // ------------------------------------------------------------------
    //  Host imports
    // ------------------------------------------------------------------

    fn lowerImportCall(self: *Lowerer, idx: u32) Error!void {
        const imp = self.t.funcs[idx].import.?;
        const ty = self.t.funcs[idx].ty;
        if (self.t.field_access.get(idx)) |fa| return self.lowerFieldAccess(fa, imp, ty);
        const wasi = @import("wasi.zig");
        if (std.mem.eql(u8, imp.module, wasi.halt_module) and std.mem.eql(u8, imp.name, wasi.halt_name)) {
            // End the event. Used by the WASI `proc_exit` shim.
            return self.a.jump(udon.asm_.halt);
        }
        const sig = nodes.parseSignature(imp.name) orelse
            return self.t.fail(error.Unsupported, "import '{s}.{s}' is neither an Udon extern signature nor bound by __udon_meta", .{ imp.module, imp.name });
        try self.lowerExtern(imp, ty, sig);
    }

    fn lowerFieldAccess(self: *Lowerer, fa: tr.FieldAccess, imp: *const wasm.module.Import, ty: FuncType) Error!void {
        const is_bool = std.mem.eql(u8, fa.type_name, "SystemBoolean");
        if (fa.is_setter) {
            if (ty.params.len != 1 or ty.results.len != 0)
                return self.t.fail(error.Invalid, "field setter import '{s}' must take one value and return nothing", .{imp.name});
            var v = try self.pop();
            try self.flushShared(fa.sym, self.stack.items.len);
            if (is_bool) {
                const b = try self.condBool(&v, true);
                if (b != fa.sym) try self.a.copy(b, fa.sym);
                return self.release(v);
            }
            return self.store(v, fa.sym);
        }
        if (ty.params.len != 0 or ty.results.len != 1)
            return self.t.fail(error.Invalid, "field getter import '{s}' must take nothing and return one value", .{imp.name});
        if (is_bool) return self.push(.{ .ty = .i32, .kind = .cond, .sym = fa.sym, .nonneg = true });
        try self.push(.{ .ty = ty.results[0], .kind = .shared, .sym = fa.sym });
    }

    const scalar_types = [_]struct { name: []const u8, ty: ValType }{
        .{ .name = "SystemInt32", .ty = .i32 },  .{ .name = "SystemInt64", .ty = .i64 },
        .{ .name = "SystemSingle", .ty = .f32 }, .{ .name = "SystemDouble", .ty = .f64 },
    };

    /// Small .NET integer types that travel through WASM as i32 and are
    /// converted (range-checked) at the call boundary.
    const narrow_types = [_][]const u8{ "SystemByte", "SystemSByte", "SystemInt16", "SystemUInt16", "SystemChar" };

    fn scalarOf(type_name: []const u8) ?ValType {
        for (scalar_types) |s| if (std.mem.eql(u8, s.name, type_name)) return s.ty;
        return null;
    }

    fn isNarrow(type_name: []const u8) bool {
        for (narrow_types) |n| if (std.mem.eql(u8, n, type_name)) return true;
        return false;
    }

    /// The name to put in the `EXTERN`. Udon sometimes exposes only the
    /// `SystemObject` overload of a method that takes a string
    /// (`Debug.Log`); a signature written with `SystemString` is accepted
    /// and redirected to it.
    fn externName(self: *Lowerer, raw: []const u8) Error![]const u8 {
        var buf: [512]u8 = undefined;
        if (nodes.resolveExtern(raw, &buf)) |name| return if (name.ptr == raw.ptr) raw else self.t.arena().dupe(u8, name);
        if (self.t.strict()) return self.t.fail(error.Unsupported, "import '{s}' is not in the Udon node list", .{raw});
        try self.t.warn("import '{s}' is not in the Udon node list; the program will not load in Udon", .{raw});
        return raw;
    }

    fn lowerExtern(self: *Lowerer, imp: *const wasm.module.Import, ty: FuncType, sig: nodes.Signature) Error!void {
        const args = sig.args();
        var n_str: usize = 0;
        for (args) |arg| {
            if (!arg.is_ref and std.mem.eql(u8, arg.type_name, "SystemString")) n_str += 1;
        }
        // Decide how the WASM parameters map onto the signature: whether a
        // leading receiver is present, and whether strings arrive as
        // (pointer, length) pairs or as handles.
        const w = ty.params.len;
        const force_instance = std.mem.eql(u8, imp.module, "udon.instance");
        const force_static = std.mem.eql(u8, imp.module, "udon.static") or sig.isKnownStatic();
        const Shape = struct { inst: bool, marshal: bool };
        const shapes = [_]Shape{
            .{ .inst = false, .marshal = true },  .{ .inst = true, .marshal = true },
            .{ .inst = false, .marshal = false }, .{ .inst = true, .marshal = false },
        };
        const shape: Shape = for (shapes) |s| {
            if (s.inst and force_static) continue;
            if (!s.inst and force_instance) continue;
            if (s.marshal and n_str == 0) continue;
            const expect = args.len + @intFromBool(s.inst) + (if (s.marshal) n_str else 0);
            if (w == expect or (sig.isGeneric() and w > expect)) break s;
        } else return self.t.fail(error.Invalid, "import '{s}': {d} WASM parameters do not fit the signature's {d} arguments", .{ imp.name, w, args.len });
        if (self.stack.items.len < w) return self.t.fail(error.Invalid, "operand stack underflow in function {s}", .{self.f.name});

        const a = self.t.arena();
        const in = try a.dupe(Entry, self.stack.items[self.stack.items.len - w ..]);
        self.stack.shrinkRetainingCapacity(self.stack.items.len - w);
        var ops: std.ArrayList(Sym) = .empty;
        const Temp = struct { pool: u8, sym: Sym };
        var temps: std.ArrayList(Temp) = .empty;
        const WriteBack = struct { addr: Sym, tmp: Sym, ty: ValType };
        var write_backs: std.ArrayList(WriteBack) = .empty;

        var cur: usize = 0;
        if (shape.inst) {
            try ops.append(a, try self.operand(&in[0]));
            cur = 1;
        }
        for (args) |arg| {
            const e = &in[cur];
            if (arg.is_ref) {
                // ref/out: the WASM argument is an address; the extern gets
                // a slot loaded from it and the slot is stored back after.
                const vt = scalarOf(arg.type_name) orelse
                    return self.t.fail(error.Unsupported, "import '{s}': ref/out argument of type {s} is not supported", .{ imp.name, arg.type_name });
                const tmp = try self.tempOf(vt);
                try temps.append(a, .{ .pool = try self.valPool(vt), .sym = tmp });
                const addr = try self.operand(e);
                try self.push(.{ .ty = .i32, .kind = .alias, .sym = addr });
                _ = try self.lowerInstr(switch (vt) {
                    .i32 => .{ .i32_load = .{ .@"align" = 0, .offset = 0 } },
                    .i64 => .{ .i64_load = .{ .@"align" = 0, .offset = 0 } },
                    .f32 => .{ .f32_load = .{ .@"align" = 0, .offset = 0 } },
                    .f64 => .{ .f64_load = .{ .@"align" = 0, .offset = 0 } },
                });
                try self.store(try self.pop(), tmp);
                try write_backs.append(a, .{ .addr = addr, .tmp = tmp, .ty = vt });
                try ops.append(a, tmp);
                cur += 1;
            } else if (shape.marshal and std.mem.eql(u8, arg.type_name, "SystemString")) {
                const mem = try self.memory();
                const pool = try self.poolFor("SystemString");
                const s = try self.newTemp(pool);
                try temps.append(a, .{ .pool = pool, .sym = s });
                try self.a.call("SystemTextEncoding.__GetString__SystemByteArray_SystemInt32_SystemInt32__SystemString", &.{
                    try self.t.utf8Sym(), mem.sym, try self.operand(e), try self.operand(&in[cur + 1]), s,
                });
                try ops.append(a, s);
                cur += 2;
            } else {
                try ops.append(a, try self.argument(imp, arg.type_name, e, &temps));
                cur += 1;
            }
        }
        // Hidden type arguments of generic methods are passed through.
        while (cur < w) : (cur += 1) try ops.append(a, try self.operand(&in[cur]));

        const name = try self.externName(imp.name);
        // Operand temporaries can be reused for the result, unless an
        // address among them is still needed for a write-back.
        if (write_backs.items.len == 0) for (in) |e| try self.release(e);
        const ret = sig.ret;
        if (!sig.returnsValue()) {
            if (ty.results.len != 0) return self.t.fail(error.Invalid, "import '{s}' returns nothing in Udon but a value in WASM", .{imp.name});
            try self.a.call(name, ops.items);
        } else if (ty.results.len == 0) {
            // Udon always wants the result slot, even if WASM discards it.
            const pool = try self.poolFor(handleType(ret));
            const d = try self.newTemp(pool);
            try ops.append(a, d);
            try self.a.call(name, ops.items);
            try self.freeTemp(pool, d);
        } else {
            const want = ty.results[0];
            if (scalarOf(ret)) |vt| {
                if (vt != want) return self.t.fail(error.Invalid, "import '{s}' returns {s}, which is not WASM {t}", .{ imp.name, ret, want });
                try self.result(vt, name, ops.items);
            } else if (std.mem.eql(u8, ret, "SystemBoolean")) {
                try self.resultCond(name, null, ops.items);
            } else if (isNarrow(ret)) {
                const pool = try self.poolFor(ret);
                const raw = try self.newTemp(pool);
                try ops.append(a, raw);
                try self.a.call(name, ops.items);
                try self.freeTemp(pool, raw);
                try self.result(.i32, try self.t.name("SystemConvert.__ToInt32__{s}__SystemInt32", .{ret}), &.{raw});
            } else if (std.mem.eql(u8, ret, "SystemUInt32") or std.mem.eql(u8, ret, "SystemUInt64")) {
                // Reinterpret the unsigned result's bits as the signed type.
                const wide = std.mem.eql(u8, ret, "SystemUInt64");
                const pool = try self.poolFor(ret);
                const raw = try self.newTemp(pool);
                const bytes_pool = try self.poolFor("SystemByteArray");
                const bytes = try self.newTemp(bytes_pool);
                try ops.append(a, raw);
                try self.a.call(name, ops.items);
                try self.a.call(if (wide) "SystemBitConverter.__GetBytes__SystemUInt64__SystemByteArray" else "SystemBitConverter.__GetBytes__SystemUInt32__SystemByteArray", &.{ raw, bytes });
                try self.freeTemp(pool, raw);
                try self.freeTemp(bytes_pool, bytes);
                try self.result(if (wide) .i64 else .i32, if (wide) "SystemBitConverter.__ToInt64__SystemByteArray_SystemInt32__SystemInt64" else "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32", &.{ bytes, try self.t.constI32(0) });
            } else {
                // Any other type is an opaque handle carried in an i32.
                if (want != .i32) return self.t.fail(error.Invalid, "import '{s}' returns {s}; declare its WASM result as i32 (an opaque handle)", .{ imp.name, ret });
                try self.resultIn(.i32, try self.poolFor(handleType(ret)), name, ops.items);
            }
        }
        for (temps.items) |tmp| try self.freeTemp(tmp.pool, tmp.sym);
        for (write_backs.items) |wb| {
            try self.push(.{ .ty = .i32, .kind = .alias, .sym = wb.addr });
            try self.push(.{ .ty = wb.ty, .kind = .alias, .sym = wb.tmp });
            try self.storeMem(.{ .@"align" = 0, .offset = 0 }, wb.ty, tr.Translator.byteSize(wb.ty));
        }
        if (write_backs.items.len != 0) for (in) |e| try self.release(e);
    }

    /// Declared type for a slot that receives a value of Udon type `t`.
    fn handleType(t: []const u8) []const u8 {
        return if (nodes.isType(t)) t else "SystemObject";
    }

    /// Slot holding WASM operand `e` as the Udon type `type_name`.
    fn argument(self: *Lowerer, imp: *const wasm.module.Import, type_name: []const u8, e: *Entry, temps: anytype) Error!Sym {
        const a = self.t.arena();
        if (scalarOf(type_name)) |vt| {
            if (e.ty != vt) return self.t.fail(error.Invalid, "import '{s}': a {s} argument must be WASM {t}", .{ imp.name, type_name, vt });
            return self.operand(e);
        }
        const wide = std.mem.eql(u8, type_name, "SystemUInt64");
        if (e.ty != (if (wide) ValType.i64 else ValType.i32))
            return self.t.fail(error.Invalid, "import '{s}': a {s} argument must be WASM {s}", .{ imp.name, type_name, if (wide) "i64" else "i32 (an opaque handle for object types)" });
        if (std.mem.eql(u8, type_name, "SystemBoolean")) return self.condBool(e, true);
        if (isNarrow(type_name)) {
            const pool = try self.poolFor(type_name);
            const d = try self.newTemp(pool);
            try temps.append(a, .{ .pool = pool, .sym = d });
            try self.a.call(try self.t.name("SystemConvert.__To{s}__SystemInt32__{s}", .{ type_name["System".len..], type_name }), &.{ try self.operand(e), d });
            return d;
        }
        if (wide or std.mem.eql(u8, type_name, "SystemUInt32")) {
            const bytes_pool = try self.poolFor("SystemByteArray");
            const bytes = try self.newTemp(bytes_pool);
            const pool = try self.poolFor(type_name);
            const d = try self.newTemp(pool);
            try temps.append(a, .{ .pool = bytes_pool, .sym = bytes });
            try temps.append(a, .{ .pool = pool, .sym = d });
            try self.a.call(if (wide) "SystemBitConverter.__GetBytes__SystemInt64__SystemByteArray" else "SystemBitConverter.__GetBytes__SystemInt32__SystemByteArray", &.{ try self.operand(e), bytes });
            try self.a.call(if (wide) "SystemBitConverter.__ToUInt64__SystemByteArray_SystemInt32__SystemUInt64" else "SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32", &.{ bytes, try self.t.constI32(0), d });
            return d;
        }
        return self.operand(e);
    }
};

// ----------------------------------------------------------------------
//  Instruction-sequence expansions
// ----------------------------------------------------------------------

/// WASM instructions that have no single Udon counterpart, written in terms
/// of instructions that do. One declaration per instruction tag; the
/// `inline else` in `lowerInstr` picks them by name, so a tag that is
/// handled nowhere fails to compile.
const snippets = struct {
    const I = Instruction;

    fn ifElse(comptime result: ValType, comptime then_body: []const I, comptime else_body: []const I) I {
        return .{ .if_ = .{ .bt = .{ .value = result }, .then_body = then_body, .else_body = else_body } };
    }

    fn sext32(comptime bits: i32) [4]I {
        return .{ .{ .i32_const = 32 - bits }, .i32_shl, .{ .i32_const = 32 - bits }, .i32_shr_s };
    }

    fn sext64(comptime bits: i64) [4]I {
        return .{ .{ .i64_const = 64 - bits }, .i64_shl, .{ .i64_const = 64 - bits }, .i64_shr_s };
    }

    pub const i32_extend8_s = sext32(8);
    pub const i32_extend16_s = sext32(16);
    pub const i64_extend8_s = sext64(8);
    pub const i64_extend16_s = sext64(16);
    pub const i64_extend32_s = sext64(32);

    /// floor(log2(x)) + 1023 for x in tmp_i0, 0 < x < 2^32 as unsigned: the
    /// exponent field of x converted to double.
    const exponent_of_s0 = [_]I{ .{ .local_get = tmp_i0 }, .i64_extend_i32_u, .f64_convert_i64_s, .i64_reinterpret_f64, .{ .i64_const = 52 }, .i64_shr_u, .i32_wrap_i64 };

    pub const i32_clz = [_]I{
        .{ .local_tee = tmp_i0 },
        .i32_eqz,
        ifElse(.i32, &.{.{ .i32_const = 32 }}, &([_]I{.{ .i32_const = 1054 }} ++ exponent_of_s0 ++ [_]I{.i32_sub})),
    };

    pub const i32_ctz = [_]I{
        .{ .local_tee = tmp_i0 },
        .i32_eqz,
        ifElse(.i32, &.{.{ .i32_const = 32 }}, &([_]I{
            // Isolate the lowest set bit, then take its exponent.
            .{ .local_get = tmp_i0 }, .{ .i32_const = 0 }, .{ .local_get = tmp_i0 }, .i32_sub, .i32_and, .{ .local_set = tmp_i0 },
        } ++ exponent_of_s0 ++ [_]I{ .{ .i32_const = 1023 }, .i32_sub })),
    };

    pub const i32_popcnt = [_]I{
        .{ .local_set = tmp_i0 },
        .{ .local_get = tmp_i0 },
        .{ .local_get = tmp_i0 },
        .{ .i32_const = 1 },
        .i32_shr_u,
        .{ .i32_const = 0x55555555 },
        .i32_and,
        .i32_sub,
        .{ .local_set = tmp_i0 },
        .{ .local_get = tmp_i0 },
        .{ .i32_const = 0x33333333 },
        .i32_and,
        .{ .local_get = tmp_i0 },
        .{ .i32_const = 2 },
        .i32_shr_u,
        .{ .i32_const = 0x33333333 },
        .i32_and,
        .i32_add,
        .{ .local_set = tmp_i0 },
        .{ .local_get = tmp_i0 },
        .{ .local_get = tmp_i0 },
        .{ .i32_const = 4 },
        .i32_shr_u,
        .i32_add,
        .{ .i32_const = 0x0F0F0F0F },
        .i32_and,
        .{ .i32_const = 0x01010101 },
        .i32_mul,
        .{ .i32_const = 24 },
        .i32_shr_u,
    };

    const high_half = [_]I{ .{ .local_get = tmp_l0 }, .{ .i64_const = 32 }, .i64_shr_u, .i32_wrap_i64 };
    const low_half = [_]I{ .{ .local_get = tmp_l0 }, .i32_wrap_i64 };

    pub const i64_clz = [_]I{.{ .local_set = tmp_l0 }} ++ high_half ++ [_]I{
        .{ .local_tee = tmp_i1 },
        ifElse(.i32, &([_]I{.{ .local_get = tmp_i1 }} ++ i32_clz), &(low_half ++ i32_clz ++ [_]I{ .{ .i32_const = 32 }, .i32_add })),
        .i64_extend_i32_u,
    };

    pub const i64_ctz = [_]I{.{ .local_set = tmp_l0 }} ++ low_half ++ [_]I{
        .{ .local_tee = tmp_i1 },
        ifElse(.i32, &([_]I{.{ .local_get = tmp_i1 }} ++ i32_ctz), &(high_half ++ i32_ctz ++ [_]I{ .{ .i32_const = 32 }, .i32_add })),
        .i64_extend_i32_u,
    };

    pub const i64_popcnt = [_]I{.{ .local_set = tmp_l0 }} ++ low_half ++ i32_popcnt ++ high_half ++ i32_popcnt ++ [_]I{ .i32_add, .i64_extend_i32_u };

    /// Unsigned 64-bit quotient of tmp_l0 / tmp_l1 using signed operations.
    const udiv64 = [_]I{
        .{ .local_get = tmp_l1 },
        .{ .i64_const = 0 },
        .i64_lt_s,
        // Divisor ≥ 2^63: the quotient is 1 if a ≥ b (unsigned), else 0.
        ifElse(.i64, &.{ .{ .local_get = tmp_l0 }, .{ .local_get = tmp_l1 }, .i64_ge_u, .i64_extend_i32_u }, &.{
            .{ .local_get = tmp_l0 },
            .{ .i64_const = 0 },
            .i64_ge_s,
            ifElse(.i64, &.{ .{ .local_get = tmp_l0 }, .{ .local_get = tmp_l1 }, .i64_div_s }, &.{
                // Dividend ≥ 2^63: divide half of it, double, then correct
                // by at most one.
                .{ .local_get = tmp_l0 }, .{ .i64_const = 1 },      .i64_shr_u,               .{ .local_get = tmp_l1 }, .i64_div_s,
                .{ .i64_const = 1 },      .i64_shl,                 .{ .local_set = tmp_l2 }, .{ .local_get = tmp_l2 }, .{ .local_get = tmp_l0 },
                .{ .local_get = tmp_l2 }, .{ .local_get = tmp_l1 }, .i64_mul,                 .i64_sub,                 .{ .local_get = tmp_l1 },
                .i64_ge_u,                .i64_extend_i32_u,        .i64_add,
            }),
        }),
    };

    pub const i64_div_u = [_]I{ .{ .local_set = tmp_l1 }, .{ .local_set = tmp_l0 } } ++ udiv64;
    pub const i64_rem_u = i64_div_u ++ [_]I{ .{ .local_set = tmp_l2 }, .{ .local_get = tmp_l0 }, .{ .local_get = tmp_l2 }, .{ .local_get = tmp_l1 }, .i64_mul, .i64_sub };

    pub const f32_trunc = [_]I{ .f64_promote_f32, .f64_trunc, .f32_demote_f64 };

    pub const f32_copysign = [_]I{
        .i32_reinterpret_f32, .{ .i32_const = std.math.minInt(i32) }, .i32_and, .{ .local_set = tmp_i0 },
        .i32_reinterpret_f32, .{ .i32_const = std.math.maxInt(i32) }, .i32_and, .{ .local_get = tmp_i0 },
        .i32_or,              .f32_reinterpret_i32,
    };

    pub const f64_copysign = [_]I{
        .i64_reinterpret_f64, .{ .i64_const = std.math.minInt(i64) }, .i64_and, .{ .local_set = tmp_l0 },
        .i64_reinterpret_f64, .{ .i64_const = std.math.maxInt(i64) }, .i64_and, .{ .local_get = tmp_l0 },
        .i64_or,              .f64_reinterpret_i64,
    };

    // ---- float → integer ----

    pub const i32_trunc_f32_s = [_]I{ .f64_promote_f32, .i32_trunc_f64_s };
    pub const i64_trunc_f32_s = [_]I{ .f64_promote_f32, .i64_trunc_f64_s };
    /// In range, the unsigned result is the low half of the signed 64-bit one.
    pub const i32_trunc_f64_u = [_]I{ .i64_trunc_f64_s, .i32_wrap_i64 };
    pub const i32_trunc_f32_u = [_]I{ .f64_promote_f32, .i64_trunc_f64_s, .i32_wrap_i64 };
    const two63 = 9223372036854775808.0;
    pub const i64_trunc_f64_u = [_]I{
        .{ .local_tee = tmp_d0 },
        .{ .f64_const = two63 },
        .f64_lt,
        ifElse(.i64, &.{ .{ .local_get = tmp_d0 }, .i64_trunc_f64_s }, &.{
            .{ .local_get = tmp_d0 }, .{ .f64_const = two63 }, .f64_sub, .i64_trunc_f64_s, .{ .i64_const = std.math.minInt(i64) }, .i64_xor,
        }),
    };
    pub const i64_trunc_f32_u = [_]I{.f64_promote_f32} ++ i64_trunc_f64_u;

    /// Saturating truncation of the f64 in tmp_d0: NaN → 0, out of range →
    /// the nearest bound, otherwise `conv`.
    fn sat(comptime result: ValType, comptime lo: f64, comptime lo_val: I, comptime hi: f64, comptime hi_val: I, comptime n: usize, comptime conv: [n]I) [4]I {
        return .{
            .{ .local_tee = tmp_d0 },
            .{ .local_get = tmp_d0 },
            .f64_ne,
            ifElse(result, &.{if (result == .i32) I{ .i32_const = 0 } else I{ .i64_const = 0 }}, &.{
                .{ .local_get = tmp_d0 },
                .{ .f64_const = lo },
                .f64_le,
                ifElse(result, &.{lo_val}, &.{
                    .{ .local_get = tmp_d0 },
                    .{ .f64_const = hi },
                    .f64_ge,
                    ifElse(result, &.{hi_val}, &([_]I{.{ .local_get = tmp_d0 }} ++ conv)),
                }),
            }),
        };
    }

    pub const i32_trunc_sat_f64_s = sat(.i32, -2147483648.0, .{ .i32_const = std.math.minInt(i32) }, 2147483647.0, .{ .i32_const = std.math.maxInt(i32) }, 1, .{.i32_trunc_f64_s});
    pub const i32_trunc_sat_f64_u = sat(.i32, 0.0, .{ .i32_const = 0 }, 4294967295.0, .{ .i32_const = -1 }, i32_trunc_f64_u.len, i32_trunc_f64_u);
    pub const i64_trunc_sat_f64_s = sat(.i64, -two63, .{ .i64_const = std.math.minInt(i64) }, two63, .{ .i64_const = std.math.maxInt(i64) }, 1, .{.i64_trunc_f64_s});
    pub const i64_trunc_sat_f64_u = sat(.i64, 0.0, .{ .i64_const = 0 }, 2.0 * two63, .{ .i64_const = -1 }, i64_trunc_f64_u.len, i64_trunc_f64_u);
    pub const i32_trunc_sat_f32_s = [_]I{.f64_promote_f32} ++ i32_trunc_sat_f64_s;
    pub const i32_trunc_sat_f32_u = [_]I{.f64_promote_f32} ++ i32_trunc_sat_f64_u;
    pub const i64_trunc_sat_f32_s = [_]I{.f64_promote_f32} ++ i64_trunc_sat_f64_s;
    pub const i64_trunc_sat_f32_u = [_]I{.f64_promote_f32} ++ i64_trunc_sat_f64_u;

    // ---- unsigned integer → float ----

    pub const f32_convert_i32_u = [_]I{ .i64_extend_i32_u, .f32_convert_i64_s };
    pub const f64_convert_i32_u = [_]I{ .i64_extend_i32_u, .f64_convert_i64_s };

    /// Values ≥ 2^63 are halved (keeping the lost bit sticky so rounding is
    /// unchanged), converted, and doubled.
    fn convertU64(comptime result: ValType, comptime conv: I, comptime two: I, comptime mul: I) [4]I {
        return .{
            .{ .local_tee = tmp_l0 },
            .{ .i64_const = 0 },
            .i64_ge_s,
            ifElse(result, &.{ .{ .local_get = tmp_l0 }, conv }, &.{
                .{ .local_get = tmp_l0 }, .{ .i64_const = 1 }, .i64_shr_u, .{ .local_get = tmp_l0 }, .{ .i64_const = 1 }, .i64_and, .i64_or, conv, two, mul,
            }),
        };
    }

    pub const f32_convert_i64_u = convertU64(.f32, .f32_convert_i64_s, .{ .f32_const = 2 }, .f32_mul);
    pub const f64_convert_i64_u = convertU64(.f64, .f64_convert_i64_s, .{ .f64_const = 2 }, .f64_mul);
};
