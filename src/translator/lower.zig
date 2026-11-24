//! Function body lowering: WASM stack machine → Udon heap-variable code.
//!
//! The WASM operand stack is tracked symbolically. An entry does not have to
//! live in a temporary; it can still be
//!
//!   * the local or global it was read from (`local.get` emits nothing),
//!   * a constant,
//!   * `pending` — produced by an instruction whose destination operand has
//!     not been chosen yet, so `local.set` / a call argument / a return value
//!     can make the producer write straight into its final home,
//!   * `cond` — a comparison result kept as a `SystemBoolean`, which `if` /
//!     `br_if` / `select` consume directly.
//!
//! Entries are only copied into their canonical temporary ("settled") when
//! something could invalidate them: a write to the variable they alias, a
//! call, or a control-flow merge. See `docs/spec_optimizations.md`.

const std = @import("std");
const wasm = @import("wasm");
const tr = @import("translate.zig");
const imports = @import("imports.zig");
const runtime = @import("runtime.zig");

const Translator = tr.Translator;
const Error = tr.Error;
const Var = tr.Var;
const Label = tr.Label;
const Class = tr.Class;
const Const = tr.Const;
const ph = tr.placeholder;
const ValType = wasm.types.ValType;
const FuncType = wasm.types.FuncType;
const Instruction = wasm.Instruction;
const MemArg = wasm.instruction.MemArg;
const Tag = std.meta.Tag(Instruction);
const Init = @import("udon").asm_.Init;

pub const Cond = struct {
    /// `SystemBoolean` variable holding the comparison result.
    v: Var,
    /// The WASM value is the logical negation of `v`.
    negated: bool = false,
    /// The compare instruction and the signature of the opposite
    /// comparison, when the test can be inverted for free.
    inst: ?u32 = null,
    inverse: ?[]const u8 = null,
};

pub const Loc = union(enum) {
    temp,
    local: u32,
    /// Lives in a variable owned elsewhere. Unless `stable`, a call or a
    /// write to the variable invalidates the entry.
    lazy: struct { v: Var, stable: bool },
    konst: Const,
    /// Result operand `arg` of instruction `inst` is still a placeholder.
    pending: struct { inst: u32, arg: u8 },
    cond: Cond,
};

pub const Entry = struct { ty: ValType, loc: Loc };

const Block = struct {
    label: Label,
    is_loop: bool,
    /// Stack height below the block's parameters.
    base: usize,
    params: []const ValType,
    results: []const ValType,
    targeted: bool = false,

    fn branchTypes(self: Block) []const ValType {
        return if (self.is_loop) self.params else self.results;
    }
};

const LocalSlot = struct { ty: ValType, idx: u32 };

pub fn lowerFunction(t: *Translator, d: u32) Error!void {
    const func = d + @as(u32, @intCast(t.func_imports.len));
    const ty = try t.funcType(func);
    const code = t.mod.codes[d];

    var self: Lower = .{ .t = t, .d = d, .ty = ty, .recursive = t.sccs.recursive[d] };
    var locals: std.ArrayList(LocalSlot) = .empty;
    for (ty.params) |p| try self.addLocal(&locals, p);
    for (code.locals) |group| for (0..group.count) |_| try self.addLocal(&locals, group.ty);
    self.locals = locals.items;

    try t.comment("function {d}", .{func});
    if (t.stub[d]) |stub| {
        // Entry used by call_indirect: arguments arrive in the shared
        // registers, then execution falls through into the body.
        try t.place(stub);
        var counts: [Class.count]u32 = @splat(0);
        for (ty.params, 0..) |p, i| {
            const c = @intFromEnum(Class.of(p));
            try t.copy(try t.argReg(Class.of(p), counts[c]), try self.localVar(@intCast(i)));
            counts[c] += 1;
        }
        try t.copy(try t.named("__ind_lr", "SystemUInt32", .{ .uint = 0 }), try self.lr());
    }
    try t.place(t.entry[d]);

    // WASM zero-initialises locals; only those that may be read first need it.
    const needs_zero = try initScan(t.a, code.body, self.locals.len, ty.params.len);
    for (self.locals, 0..) |slot, i| {
        if (needs_zero.isSet(i)) try t.copy(try t.constant(.{ .ty = slot.ty, .bits = 0 }), try self.localVar(@intCast(i)));
    }

    const exit = t.prog.newLabel();
    try self.blocks.append(t.a, .{ .label = exit, .is_loop = false, .base = 0, .params = &.{}, .results = ty.results });
    try self.body(code.body);
    if (self.blocks.items[0].targeted) {
        if (!self.dead) try self.carry(0, ty.results, false);
        try self.setResults(0, ty.results);
        try t.place(exit);
        self.dead = false;
    }
    if (!self.dead) try self.doReturn();
}

pub const Lower = struct {
    t: *Translator,
    /// Index of the function among the module's defined functions.
    d: u32,
    ty: FuncType,
    recursive: bool,
    locals: []const LocalSlot = &.{},
    n_locals: [Class.count]u32 = @splat(0),
    stack: std.ArrayList(Entry) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    /// The code being lowered is unreachable.
    dead: bool = false,

    fn addLocal(self: *Lower, list: *std.ArrayList(LocalSlot), ty: ValType) Error!void {
        const c = @intFromEnum(Class.of(ty));
        try list.append(self.t.a, .{ .ty = ty, .idx = self.n_locals[c] });
        self.n_locals[c] += 1;
    }

    // ------------------------------------------------------------------
    // Operand stack
    // ------------------------------------------------------------------

    fn localVar(self: *Lower, i: u32) Error!Var {
        if (i >= self.locals.len) return error.InvalidModule;
        return self.t.frame(self.d, Class.of(self.locals[i].ty), self.locals[i].idx);
    }

    fn lr(self: *Lower) Error!Var {
        return self.t.frame(self.d, .lr, 0);
    }

    /// Canonical temporary for a value of type `ty` sitting on top of
    /// `below` followed by `extra`. Depends only on the types underneath, so
    /// every control-flow path agrees on it.
    fn canonicalTemp(self: *Lower, below: []const Entry, extra: []const ValType, ty: ValType) Error!Var {
        var k: u32 = 0;
        for (below) |e| k += @intFromBool(e.ty == ty);
        for (extra) |e| k += @intFromBool(e == ty);
        const class = Class.of(ty);
        return self.t.frame(self.d, class, self.n_locals[@intFromEnum(class)] + k);
    }

    fn tempVar(self: *Lower, pos: usize) Error!Var {
        return self.canonicalTemp(self.stack.items[0..pos], &.{}, self.stack.items[pos].ty);
    }

    /// Boolean temporary for a comparison whose result will sit at `pos`.
    pub fn boolVar(self: *Lower, pos: usize) Error!Var {
        var k: u32 = 0;
        for (self.stack.items[0..pos]) |e| k += @intFromBool(e.loc == .cond);
        return self.t.frame(self.d, .bool, k);
    }

    pub fn push(self: *Lower, ty: ValType, loc: Loc) Error!void {
        try self.stack.append(self.t.a, .{ .ty = ty, .loc = loc });
    }

    pub fn pushPending(self: *Lower, ty: ValType, inst: u32, arg: u8) Error!void {
        try self.push(ty, .{ .pending = .{ .inst = inst, .arg = arg } });
    }

    pub fn need(self: *Lower, n: usize) Error!void {
        if (self.stack.items.len < n) return error.InvalidModule;
    }

    /// Stack position of the entry `n` below the top.
    pub fn top(self: *Lower, n: usize) Error!usize {
        try self.need(n + 1);
        return self.stack.items.len - 1 - n;
    }

    pub fn drop(self: *Lower, n: usize) void {
        self.stack.shrinkRetainingCapacity(self.stack.items.len - n);
    }

    fn patch(self: *Lower, p: @FieldType(Loc, "pending"), dst: Var) void {
        switch (self.t.prog.insts.items[p.inst]) {
            .ext => |*e| e.args[p.arg] = dst,
            .copy => |*c| c.dst = dst,
            else => unreachable,
        }
    }

    /// A variable currently holding the entry's value (read-only use).
    pub fn use(self: *Lower, pos: usize) Error!Var {
        switch (self.stack.items[pos].loc) {
            .temp => return self.tempVar(pos),
            .local => |i| return self.localVar(i),
            .lazy => |l| return l.v,
            .konst => |c| return self.t.constant(c),
            .pending, .cond => {
                try self.settle(pos);
                return self.tempVar(pos);
            },
        }
    }

    /// Put the entry's value into `dst`. The entry's location is left for
    /// the caller to update.
    pub fn moveTo(self: *Lower, pos: usize, dst: Var) Error!void {
        switch (self.stack.items[pos].loc) {
            .pending => |p| {
                // Retargeting the producer is safe when nothing was emitted
                // since (so `dst` is not read in between), or when `dst` is
                // the entry's own temporary.
                const own = try self.tempVar(pos);
                const direct = dst == own or p.inst + 1 == self.t.prog.insts.items.len;
                self.patch(p, if (direct) dst else own);
                if (!direct) try self.t.copy(own, dst);
            },
            .cond => |c| {
                const b = try self.positive(c);
                _ = try self.t.ext("SystemConvert.__ToInt32__SystemBoolean__SystemInt32", &.{ b.v, dst });
            },
            else => try self.t.copy(try self.use(pos), dst),
        }
    }

    /// Move the entry into its canonical temporary.
    fn settle(self: *Lower, pos: usize) Error!void {
        if (self.stack.items[pos].loc == .temp) return;
        try self.moveTo(pos, try self.tempVar(pos));
        self.stack.items[pos].loc = .temp;
    }

    /// Settle entries that alias variable `v` before it is overwritten.
    fn settleAliases(self: *Lower, entries: []const Entry, local: ?u32, v: ?Var) Error!void {
        for (entries, 0..) |e, pos| switch (e.loc) {
            .local => |i| if (local == i) try self.settle(pos),
            .lazy => |l| if (v == l.v) try self.settle(pos),
            else => {},
        };
    }

    /// Settle everything in `stack[0..end]` that a call could invalidate.
    fn settleVolatile(self: *Lower, end: usize, also_locals: bool) Error!void {
        for (self.stack.items[0..end], 0..) |e, pos| switch (e.loc) {
            .pending, .cond => try self.settle(pos),
            .lazy => |l| if (!l.stable) try self.settle(pos),
            .local => if (also_locals) try self.settle(pos),
            else => {},
        };
    }

    // ------------------------------------------------------------------
    // Conditions
    // ------------------------------------------------------------------

    fn flip(self: *Lower, c: Cond) Error!Cond {
        const e = &self.t.prog.insts.items[c.inst.?].ext;
        const old = self.t.prog.externs.items[e.sig];
        e.sig = try self.t.prog.internExtern(c.inverse.?);
        return .{ .v = c.v, .negated = !c.negated, .inst = c.inst, .inverse = old };
    }

    /// Equivalent condition whose variable is true when the WASM value is non-zero.
    fn positive(self: *Lower, c: Cond) Error!Cond {
        if (!c.negated) return c;
        if (c.inverse != null) return self.flip(c);
        _ = try self.t.ext("SystemBoolean.__op_UnaryNegation__SystemBoolean__SystemBoolean", &.{ c.v, c.v });
        return .{ .v = c.v };
    }

    /// Equivalent condition whose variable is *false* when the WASM value
    /// is non-zero, if that costs nothing.
    fn negative(self: *Lower, c: Cond) Error!?Cond {
        if (c.negated) return c;
        if (c.inverse != null) return try self.flip(c);
        return null;
    }

    /// Pop the top entry as a branch condition.
    fn popCond(self: *Lower) Error!Cond {
        const pos = try self.top(0);
        const e = self.stack.items[pos];
        defer self.drop(1);
        if (e.loc == .cond) return e.loc.cond;
        const b = try self.boolVar(pos);
        const inst = try self.t.ext(cmpSig("Int32", "Inequality"), &.{ try self.use(pos), try self.t.constI32(0), b });
        return .{ .v = b, .inst = inst, .inverse = cmpSig("Int32", "Equality") };
    }

    // ------------------------------------------------------------------
    // Control flow
    // ------------------------------------------------------------------

    fn body(self: *Lower, instrs: []const Instruction) Error!void {
        for (instrs) |ins| {
            // Everything after an unconditional branch is unreachable.
            if (self.dead) return;
            try self.one(ins);
        }
    }

    const BlockSig = struct { params: []const ValType, results: []const ValType };

    fn blockSig(self: *Lower, bt: wasm.types.BlockType) Error!BlockSig {
        const single = struct {
            const i32_: [1]ValType = .{.i32};
            const i64_: [1]ValType = .{.i64};
            const f32_: [1]ValType = .{.f32};
            const f64_: [1]ValType = .{.f64};
        };
        return switch (bt) {
            .empty => .{ .params = &.{}, .results = &.{} },
            .value => |v| .{ .params = &.{}, .results = switch (v) {
                .i32 => &single.i32_,
                .i64 => &single.i64_,
                .f32 => &single.f32_,
                .f64 => &single.f64_,
            } },
            .type_index => |i| if (i < self.t.mod.types_.len)
                .{ .params = self.t.mod.types_[i].params, .results = self.t.mod.types_[i].results }
            else
                error.InvalidModule,
        };
    }

    /// Entering a block: later code may reassign what lazy entries alias,
    /// and block parameters must sit in their canonical temporaries.
    fn enterBlock(self: *Lower, n_params: usize) Error!usize {
        try self.need(n_params);
        const base = self.stack.items.len - n_params;
        try self.settleVolatile(base, true);
        for (base..self.stack.items.len) |pos| try self.settle(pos);
        return base;
    }

    fn setResults(self: *Lower, base: usize, tys: []const ValType) Error!void {
        self.stack.shrinkRetainingCapacity(base);
        for (tys) |ty| try self.push(ty, .temp);
    }

    /// Move the top `tys.len` entries into the canonical temporaries of a
    /// block whose stack starts at `base`. With `keep`, the entries stay
    /// usable afterwards (conditional branches).
    fn carry(self: *Lower, base: usize, tys: []const ValType, keep: bool) Error!void {
        try self.need(base + tys.len);
        const first = self.stack.items.len - tys.len;
        if (keep) for (first..self.stack.items.len) |pos| switch (self.stack.items[pos].loc) {
            .pending, .cond => try self.settle(pos),
            else => {},
        };
        for (tys, 0..) |ty, i| {
            if (self.stack.items[first + i].ty != ty) return error.InvalidModule;
            try self.moveTo(first + i, try self.canonicalTemp(self.stack.items[0..base], tys[0..i], ty));
        }
    }

    fn target(self: *Lower, depth: u32) Error!*Block {
        if (depth >= self.blocks.items.len) return error.InvalidModule;
        const blk = &self.blocks.items[self.blocks.items.len - 1 - depth];
        blk.targeted = true;
        return blk;
    }

    fn block(self: *Lower, b: wasm.instruction.Block, is_loop: bool) Error!void {
        const sig = try self.blockSig(b.bt);
        const base = try self.enterBlock(sig.params.len);
        const label = self.t.prog.newLabel();
        try self.blocks.append(self.t.a, .{ .label = label, .is_loop = is_loop, .base = base, .params = sig.params, .results = sig.results });
        if (is_loop) try self.t.place(label);
        try self.body(b.body);
        const blk = self.blocks.pop().?;
        if (!self.dead) try self.carry(base, sig.results, false);
        try self.setResults(base, sig.results);
        if (!is_loop) {
            try self.t.place(label);
            if (blk.targeted) self.dead = false;
        }
    }

    fn if_(self: *Lower, b: wasm.instruction.If) Error!void {
        const cond = try self.positive(try self.popCond());
        const sig = try self.blockSig(b.bt);
        const base = try self.enterBlock(sig.params.len);
        const else_label = self.t.prog.newLabel();
        const end = self.t.prog.newLabel();
        try self.t.jif(cond.v, else_label);
        try self.blocks.append(self.t.a, .{ .label = end, .is_loop = false, .base = base, .params = sig.params, .results = sig.results });

        try self.body(b.then_body);
        var live = !self.dead;
        if (live) try self.carry(base, sig.results, false);
        if (b.else_body) |else_body| {
            if (live) try self.t.jump(end);
            try self.t.place(else_label);
            try self.setResults(base, sig.params);
            self.dead = false;
            try self.body(else_body);
            if (!self.dead) {
                try self.carry(base, sig.results, false);
                live = true;
            }
        } else {
            try self.t.place(else_label);
            live = true;
        }
        const blk = self.blocks.pop().?;
        try self.setResults(base, sig.results);
        try self.t.place(end);
        self.dead = !live and !blk.targeted;
    }

    fn br(self: *Lower, depth: u32) Error!void {
        const blk = try self.target(depth);
        try self.carry(blk.base, blk.branchTypes(), false);
        try self.t.jump(blk.label);
        self.dead = true;
    }

    fn brIf(self: *Lower, depth: u32) Error!void {
        const cond = try self.popCond();
        const blk = (try self.target(depth)).*;
        const tys = blk.branchTypes();
        if (tys.len == 0) {
            // JUMP_IF_FALSE branches on false, so a negated test is the cheap form.
            if (try self.negative(cond)) |n| return self.t.jif(n.v, blk.label);
            const skip = self.t.prog.newLabel();
            try self.t.jif(cond.v, skip);
            try self.t.jump(blk.label);
            return self.t.place(skip);
        }
        const c = try self.positive(cond);
        // Settle before the test so both paths see the same entries.
        try self.need(tys.len);
        for (self.stack.items.len - tys.len..self.stack.items.len) |pos| switch (self.stack.items[pos].loc) {
            .pending, .cond => try self.settle(pos),
            else => {},
        };
        const skip = self.t.prog.newLabel();
        try self.t.jif(c.v, skip);
        try self.carry(blk.base, tys, true);
        try self.t.jump(blk.label);
        try self.t.place(skip);
    }

    fn brTable(self: *Lower, bt: wasm.instruction.BrTable) Error!void {
        const t = self.t;
        const idx = try self.use(try self.top(0));
        self.drop(1);
        const default = (try self.target(bt.default)).*;
        const tys = default.branchTypes();
        const flag = try t.tmp(.bool, 0);
        self.dead = true;

        if (tys.len > 0) {
            // Targets may keep their results in different temporaries.
            for (bt.labels, 0..) |depth, i| {
                const blk = (try self.target(depth)).*;
                const next = t.prog.newLabel();
                _ = try t.ext(cmpSig("Int32", "Equality"), &.{ idx, try t.constI32(@intCast(i)), flag });
                try t.jif(flag, next);
                try self.carry(blk.base, tys, true);
                try t.jump(blk.label);
                try t.place(next);
            }
            try self.carry(default.base, tys, true);
            return t.jump(default.label);
        }
        if (bt.labels.len <= 3) {
            for (bt.labels, 0..) |depth, i| {
                _ = try t.ext(cmpSig("Int32", "Inequality"), &.{ idx, try t.constI32(@intCast(i)), flag });
                try t.jif(flag, (try self.target(depth)).label);
            }
            return t.jump(default.label);
        }
        // Jump table: one bounds test (unsigned, via sign-bit flip) and one lookup.
        const labels = try t.a.alloc(Label, bt.labels.len);
        for (bt.labels, labels) |depth, *l| l.* = (try self.target(depth)).label;
        const n: i32 = @intCast(labels.len);
        const scratch = try t.tmp(.i32, 0);
        _ = try t.ext(opSig("Int32", "LogicalXor"), &.{ idx, try t.constI32(min_i32), scratch });
        _ = try t.ext(cmpSig("Int32", "LessThan"), &.{ scratch, try t.constI32(n ^ min_i32), flag });
        try t.jif(flag, default.label);
        const base = try t.addJumpTable(labels);
        _ = try t.ext(opSig("Int32", "Addition"), &.{ idx, try t.constI32(@intCast(base)), scratch });
        const dest = try t.named("__jump_target", "SystemUInt32", .{ .uint = 0 });
        _ = try t.ext("SystemUInt32Array.__Get__SystemInt32__SystemUInt32", &.{ try t.tableVar(), scratch, dest });
        try t.prog.emit(.{ .jump_indirect = dest });
    }

    /// Write the results to the return registers and jump back to the caller.
    fn doReturn(self: *Lower) Error!void {
        const tys = self.ty.results;
        try self.need(tys.len);
        const first = self.stack.items.len - tys.len;
        var counts: [Class.count]u32 = @splat(0);
        const regs = try self.t.a.alloc(Var, tys.len);
        for (tys, regs) |ty, *reg| {
            const c = @intFromEnum(Class.of(ty));
            reg.* = try self.t.retReg(Class.of(ty), counts[c]);
            counts[c] += 1;
        }
        // A value still sitting in another return register would be clobbered.
        for (regs, first..) |reg, pos| switch (self.stack.items[pos].loc) {
            .lazy => |l| if (!l.stable and l.v != reg) try self.settle(pos),
            else => {},
        };
        for (regs, first..) |reg, pos| try self.moveTo(pos, reg);
        try self.t.prog.emit(.{ .jump_indirect = try self.lr() });
        self.dead = true;
    }

    // ------------------------------------------------------------------
    // Calls
    // ------------------------------------------------------------------

    fn pushResults(self: *Lower, tys: []const ValType) Error!void {
        var counts: [Class.count]u32 = @splat(0);
        for (tys) |ty| {
            const c = @intFromEnum(Class.of(ty));
            try self.push(ty, .{ .lazy = .{ .v = try self.t.retReg(Class.of(ty), counts[c]), .stable = false } });
            counts[c] += 1;
        }
    }

    /// Save this function's frame before a call that may re-enter it:
    /// every local, every settled temporary below `end`, and the return
    /// address go into a fresh array pushed on the call stack.
    fn saveFrame(self: *Lower, end: usize) Error![]const Var {
        const t = self.t;
        var slots: std.ArrayList(Var) = .empty;
        for (0..self.locals.len) |i| try slots.append(t.a, try self.localVar(@intCast(i)));
        for (self.stack.items[0..end], 0..) |e, pos| if (e.loc == .temp) try slots.append(t.a, try self.tempVar(pos));
        try slots.append(t.a, try self.lr());

        const frame = try t.named("__frame", "SystemObjectArray", .null_);
        const sp = try t.named("__call_sp", "SystemInt32", .{ .int = 0 });
        _ = try t.ext("SystemObjectArray.__ctor__SystemInt32__SystemObjectArray", &.{ try t.constI32(@intCast(slots.items.len)), frame });
        for (slots.items, 0..) |v, k| _ = try t.ext(obj_set, &.{ frame, try t.constI32(@intCast(k)), v });
        _ = try t.ext(obj_set, &.{ try t.callStack(), sp, frame });
        _ = try t.ext(opSig("Int32", "Addition"), &.{ sp, try t.constI32(1), sp });
        return slots.items;
    }

    fn restoreFrame(self: *Lower, slots: []const Var) Error!void {
        const t = self.t;
        const frame = try t.named("__frame", "SystemObjectArray", .null_);
        const sp = try t.named("__call_sp", "SystemInt32", .{ .int = 0 });
        _ = try t.ext(opSig("Int32", "Subtraction"), &.{ sp, try t.constI32(1), sp });
        _ = try t.ext(obj_get, &.{ try t.callStack(), sp, frame });
        for (slots, 0..) |v, k| _ = try t.ext(obj_get, &.{ frame, try t.constI32(@intCast(k)), v });
    }

    const obj_set = "SystemObjectArray.__Set__SystemInt32_SystemObject__SystemVoid";
    const obj_get = "SystemObjectArray.__Get__SystemInt32__SystemObject";

    fn call(self: *Lower, func: u32) Error!void {
        const t = self.t;
        const n_imp: u32 = @intCast(t.func_imports.len);
        const ty = try t.funcType(func);
        if (func < n_imp) return imports.lower(self, t.func_imports[func], ty);
        const callee = func - n_imp;
        try self.need(ty.params.len);
        const first = self.stack.items.len - ty.params.len;
        const reenters = self.recursive and t.sccs.id[callee] == t.sccs.id[self.d];

        try self.settleVolatile(first, false);
        // The callee's parameters alias our own locals only on a self call;
        // settle the arguments so no parameter is overwritten before it is read.
        if (reenters) try self.settleArgs(first, callee == self.d);
        const saved: ?[]const Var = if (reenters) try self.saveFrame(first) else null;

        var counts: [Class.count]u32 = @splat(0);
        for (ty.params, first..) |p, pos| {
            if (self.stack.items[pos].ty != p) return error.InvalidModule;
            const c = @intFromEnum(Class.of(p));
            try self.moveTo(pos, try t.frame(callee, Class.of(p), counts[c]));
            counts[c] += 1;
        }
        self.drop(ty.params.len);
        const back = t.prog.newLabel();
        try t.copy(try t.rac(back), try t.frame(callee, .lr, 0));
        try t.jump(t.entry[callee]);
        try t.place(back);
        if (saved) |slots| try self.restoreFrame(slots);
        try self.pushResults(ty.results);
    }

    fn settleArgs(self: *Lower, first: usize, also_locals: bool) Error!void {
        for (first..self.stack.items.len) |pos| switch (self.stack.items[pos].loc) {
            .pending, .cond => try self.settle(pos),
            .local => if (also_locals) try self.settle(pos),
            else => {},
        };
    }

    fn callIndirect(self: *Lower, tidx: u32) Error!void {
        const t = self.t;
        if (tidx >= t.mod.types_.len) return error.InvalidModule;
        const ty = t.mod.types_[tidx];
        try self.need(ty.params.len + 1);
        const first = self.stack.items.len - 1 - ty.params.len;
        const reenters = t.indirectMayRecurse(self.d, ty);

        try self.settleVolatile(first, false);
        const index = try self.use(try self.top(0));
        self.drop(1);
        if (reenters) try self.settleArgs(first, false);
        const saved: ?[]const Var = if (reenters) try self.saveFrame(first) else null;

        var counts: [Class.count]u32 = @splat(0);
        for (ty.params, first..) |p, pos| {
            if (self.stack.items[pos].ty != p) return error.InvalidModule;
            const c = @intFromEnum(Class.of(p));
            try self.moveTo(pos, try t.argReg(Class.of(p), counts[c]));
            counts[c] += 1;
        }
        const dest = try t.named("__jump_target", "SystemUInt32", .{ .uint = 0 });
        _ = try t.ext("SystemUInt32Array.__Get__SystemInt32__SystemUInt32", &.{ try t.tableVar(), index, dest });
        self.drop(ty.params.len);
        const back = t.prog.newLabel();
        try t.copy(try t.rac(back), try t.named("__ind_lr", "SystemUInt32", .{ .uint = 0 }));
        try t.prog.emit(.{ .jump_indirect = dest });
        try t.place(back);
        if (saved) |slots| try self.restoreFrame(slots);
        try self.pushResults(ty.results);
    }

    /// Call a shared runtime routine with the top entries as arguments.
    fn callRoutine(self: *Lower, r: runtime.Routine) Error!void {
        const t = self.t;
        const spec = r.spec();
        try self.need(spec.params.len);
        const first = self.stack.items.len - spec.params.len;
        try self.settleVolatile(first, false);
        for (spec.params, first..) |p, pos| {
            if (self.stack.items[pos].ty != p) return error.InvalidModule;
            try self.moveTo(pos, try runtime.argVar(t, r, @intCast(pos - first)));
        }
        self.drop(spec.params.len);
        const back = t.prog.newLabel();
        try t.copy(try t.rac(back), try runtime.lrVar(t, r));
        try t.jump(try runtime.label(t, r));
        try t.place(back);
        if (spec.result) |ty| try self.push(ty, .{ .lazy = .{ .v = try runtime.resultVar(t, r), .stable = false } });
    }

    // ------------------------------------------------------------------
    // Instruction dispatch
    // ------------------------------------------------------------------

    fn one(self: *Lower, ins: Instruction) Error!void {
        const t = self.t;
        if (simple(ins)) |s| return self.simpleOp(s);
        switch (ins) {
            .nop => {},
            .unreachable_ => {
                try t.jump(try runtime.label(t, .trap_unreachable));
                self.dead = true;
            },
            .block => |b| try self.block(b, false),
            .loop => |b| try self.block(b, true),
            .if_ => |b| try self.if_(b),
            .br => |depth| try self.br(depth),
            .br_if => |depth| try self.brIf(depth),
            .br_table => |bt| try self.brTable(bt),
            .return_ => try self.doReturn(),
            .call => |func| try self.call(func),
            .call_indirect => |tidx| try self.callIndirect(tidx),

            .drop => {
                const pos = try self.top(0);
                // An undecided producer still needs somewhere to write.
                if (self.stack.items[pos].loc == .pending) try self.settle(pos);
                self.drop(1);
            },
            .select => try self.select(),

            .local_get => |i| {
                if (i >= self.locals.len) return error.InvalidModule;
                try self.push(self.locals[i].ty, .{ .local = i });
            },
            .local_set, .local_tee => |i| {
                const pos = try self.top(0);
                try self.settleAliases(self.stack.items[0..pos], i, null);
                if (!(self.stack.items[pos].loc == .local and self.stack.items[pos].loc.local == i))
                    try self.moveTo(pos, try self.localVar(i));
                self.stack.items[pos].loc = .{ .local = i };
                if (ins == .local_set) self.drop(1);
            },
            .global_get => |i| {
                if (i >= t.globals.len) return error.InvalidModule;
                try self.push(t.globals[i].ty, .{ .lazy = .{ .v = t.globals[i].v, .stable = false } });
            },
            .global_set => |i| {
                if (i >= t.globals.len) return error.InvalidModule;
                const pos = try self.top(0);
                try self.settleAliases(self.stack.items[0..pos], null, t.globals[i].v);
                try self.moveTo(pos, t.globals[i].v);
                self.drop(1);
            },

            .i32_const => |v| try self.push(.i32, .{ .konst = .i32_(v) }),
            .i64_const => |v| try self.push(.i64, .{ .konst = .i64_(v) }),
            .f32_const => |v| try self.push(.f32, .{ .konst = .{ .ty = .f32, .bits = @as(u32, @bitCast(v)) } }),
            .f64_const => |v| try self.push(.f64, .{ .konst = .{ .ty = .f64, .bits = @bitCast(v) } }),

            // ---- memory ----
            .i32_load => |m| try self.load(m, .i32, bitconv("Int32"), null),
            .i64_load => |m| try self.load(m, .i64, bitconv("Int64"), null),
            .f32_load => |m| try self.load(m, .f32, bitconv("Single"), null),
            .f64_load => |m| try self.load(m, .f64, bitconv("Double"), null),
            .i32_load8_u => |m| try self.load(m, .i32, byte_get, "Byte"),
            .i64_load8_u => |m| try self.load(m, .i64, byte_get, "Byte"),
            .i32_load8_s => |m| try self.load(m, .i32, "", "SByte"),
            .i64_load8_s => |m| try self.load(m, .i64, "", "SByte"),
            .i32_load16_u => |m| try self.load(m, .i32, bitconv("UInt16"), "UInt16"),
            .i64_load16_u => |m| try self.load(m, .i64, bitconv("UInt16"), "UInt16"),
            .i32_load16_s => |m| try self.load(m, .i32, bitconv("Int16"), "Int16"),
            .i64_load16_s => |m| try self.load(m, .i64, bitconv("Int16"), "Int16"),
            .i64_load32_u => |m| try self.load(m, .i64, bitconv("UInt32"), "UInt32"),
            .i64_load32_s => |m| try self.load(m, .i64, bitconv("Int32"), "Int32"),
            .i32_store => |m| try self.store(m, .i32, 4),
            .i64_store => |m| try self.store(m, .i64, 8),
            .f32_store => |m| try self.store(m, .f32, 4),
            .f64_store => |m| try self.store(m, .f64, 8),
            .i32_store8 => |m| try self.store(m, .i32, 1),
            .i32_store16 => |m| try self.store(m, .i32, 2),
            .i64_store8 => |m| try self.store(m, .i64, 1),
            .i64_store16 => |m| try self.store(m, .i64, 2),
            .i64_store32 => |m| try self.store(m, .i64, 4),
            .memory_size => try self.push(.i32, .{ .lazy = .{ .v = try t.memPages(), .stable = false } }),
            .memory_grow => try self.callRoutine(.memory_grow),
            .memory_copy => {
                const n = try self.use(try self.top(0));
                const src = try self.use(try self.top(1));
                const dst = try self.use(try self.top(2));
                const m = try t.mem();
                _ = try t.ext(array_copy, &.{ m, src, m, dst, n });
                self.drop(3);
            },
            .memory_fill => {
                const value = self.stack.items[try self.top(1)];
                if (value.loc == .konst and value.loc.konst.bits & 0xFF == 0) {
                    const n = try self.use(try self.top(0));
                    const dst = try self.use(try self.top(2));
                    _ = try t.ext("SystemArray.__Clear__SystemArray_SystemInt32_SystemInt32__SystemVoid", &.{ try t.mem(), dst, n });
                    self.drop(3);
                } else try self.callRoutine(.memory_fill);
            },
            .memory_init => |seg| {
                const n = try self.use(try self.top(0));
                const src = try self.use(try self.top(1));
                const dst = try self.use(try self.top(2));
                _ = try t.ext(array_copy, &.{ try t.dataVar(seg), src, try t.mem(), dst, n });
                self.drop(3);
            },
            .data_drop => {},

            // ---- integer tests and special arithmetic ----
            .i32_eqz, .i64_eqz => try self.eqz(),
            .i32_shr_u => try self.shiftRightUnsigned(.i32),
            .i64_shr_u => try self.shiftRightUnsigned(.i64),
            .i32_shl => try self.shift(.i32, "LeftShift"),
            .i32_shr_s => try self.shift(.i32, "RightShift"),
            .i64_shl => try self.shift(.i64, "LeftShift"),
            .i64_shr_s => try self.shift(.i64, "RightShift"),
            .i32_rotl => try self.rotate(.i32, true),
            .i32_rotr => try self.rotate(.i32, false),
            .i64_rotl => try self.rotate(.i64, true),
            .i64_rotr => try self.rotate(.i64, false),
            .i32_div_u => try self.divRemU32(true),
            .i32_rem_u => try self.divRemU32(false),
            .i64_div_u => try self.callRoutine(.div_u64),
            .i64_rem_u => try self.callRoutine(.rem_u64),
            .i64_rem_s => {
                const b = try self.use(try self.top(0));
                const a = try self.use(try self.top(1));
                const inst = try t.ext(div_rem_64, &.{ a, b, ph, try t.tmp(.i64, 0) });
                self.drop(2);
                try self.pushPending(.i64, inst, 2);
            },
            .i32_clz => try self.callRoutine(.clz32),
            .i32_ctz => try self.callRoutine(.ctz32),
            .i32_popcnt => try self.callRoutine(.popcnt32),
            .i64_clz => try self.callRoutine(.clz64),
            .i64_ctz => try self.callRoutine(.ctz64),
            .i64_popcnt => try self.callRoutine(.popcnt64),
            .i32_extend8_s => try self.signExtend(.i32, 24),
            .i32_extend16_s => try self.signExtend(.i32, 16),
            .i64_extend8_s => try self.signExtend(.i64, 56),
            .i64_extend16_s => try self.signExtend(.i64, 48),
            .i64_extend32_s => try self.signExtend(.i64, 32),

            // ---- conversions ----
            .i32_wrap_i64 => {
                const pos = try self.top(0);
                const e = self.stack.items[pos];
                if (e.loc == .konst) {
                    self.stack.items[pos] = .{ .ty = .i32, .loc = .{ .konst = .i32_(@truncate(e.loc.konst.asI64())) } };
                } else {
                    const inst = try self.wrap(try self.use(pos), ph);
                    self.drop(1);
                    try self.pushPending(.i32, inst, 1);
                }
            },
            .i64_extend_i32_s => try self.unary(convSig("Int32", "Int64"), .i64),
            .i64_extend_i32_u => {
                const pos = try self.top(0);
                const wide = try self.zeroExtend(pos, 0, ph);
                self.drop(1);
                switch (wide) {
                    .konst => |c| try self.push(.i64, .{ .konst = c }),
                    .inst => |inst| try self.pushPending(.i64, inst, 2),
                }
            },
            .f32_convert_i32_s => try self.unary(convSig("Int32", "Single"), .f32),
            .f64_convert_i32_s => try self.unary(convSig("Int32", "Double"), .f64),
            .f32_convert_i64_s => try self.unary(convSig("Int64", "Single"), .f32),
            .f64_convert_i64_s => try self.unary(convSig("Int64", "Double"), .f64),
            .f32_convert_i32_u, .f64_convert_i32_u => {
                const to: ValType = if (ins == .f32_convert_i32_u) .f32 else .f64;
                const scratch = try t.tmp(.i64, 0);
                const wide: Var = switch (try self.zeroExtend(try self.top(0), 0, scratch)) {
                    .konst => |c| try t.constant(c),
                    .inst => scratch,
                };
                const inst = try t.ext(if (to == .f32) convSig("Int64", "Single") else convSig("Int64", "Double"), &.{ wide, ph });
                self.drop(1);
                try self.pushPending(to, inst, 1);
            },
            .f64_convert_i64_u => try self.callRoutine(.u64_to_f64),
            .f32_convert_i64_u => {
                try self.callRoutine(.u64_to_f64);
                try self.unary(convSig("Double", "Single"), .f32);
            },
            .f32_demote_f64 => try self.unary(convSig("Double", "Single"), .f32),
            .f64_promote_f32 => try self.unary(convSig("Single", "Double"), .f64),
            .i32_reinterpret_f32 => try self.unary("SystemBitConverter.__SingleToInt32Bits__SystemSingle__SystemInt32", .i32),
            .f32_reinterpret_i32 => try self.unary("SystemBitConverter.__Int32BitsToSingle__SystemInt32__SystemSingle", .f32),
            .i64_reinterpret_f64 => try self.unary("SystemBitConverter.__DoubleToInt64Bits__SystemDouble__SystemInt64", .i64),
            .f64_reinterpret_i64 => try self.unary("SystemBitConverter.__Int64BitsToDouble__SystemInt64__SystemDouble", .f64),

            .i32_trunc_f32_s, .i32_trunc_f64_s => try self.truncate(.i32, true, false),
            .i32_trunc_f32_u, .i32_trunc_f64_u => try self.truncate(.i32, false, false),
            .i64_trunc_f32_s, .i64_trunc_f64_s => try self.truncate(.i64, true, false),
            .i64_trunc_f32_u, .i64_trunc_f64_u => try self.truncate(.i64, false, false),
            .i32_trunc_sat_f32_s, .i32_trunc_sat_f64_s => try self.truncate(.i32, true, true),
            .i32_trunc_sat_f32_u, .i32_trunc_sat_f64_u => try self.truncate(.i32, false, true),
            .i64_trunc_sat_f32_s, .i64_trunc_sat_f64_s => try self.truncate(.i64, true, true),
            .i64_trunc_sat_f32_u, .i64_trunc_sat_f64_u => try self.truncate(.i64, false, true),

            // ---- floating point ----
            .f64_abs => try self.unary(mathSig("Abs", "Double"), .f64),
            .f64_neg => try self.unary("SystemDouble.__op_UnaryMinus__SystemDouble__SystemDouble", .f64),
            .f64_ceil => try self.unary(mathSig("Ceiling", "Double"), .f64),
            .f64_floor => try self.unary(mathSig("Floor", "Double"), .f64),
            .f64_trunc => try self.unary(mathSig("Truncate", "Double"), .f64),
            .f64_nearest => try self.unary(mathSig("Round", "Double"), .f64),
            .f64_sqrt => try self.unary(mathSig("Sqrt", "Double"), .f64),
            .f32_abs => try self.unary(mathSig("Abs", "Single"), .f32),
            .f32_neg => try self.unary("SystemSingle.__op_UnaryMinus__SystemSingle__SystemSingle", .f32),
            .f32_ceil => try self.unary(mathfSig("Ceil"), .f32),
            .f32_floor => try self.unary(mathfSig("Floor"), .f32),
            .f32_nearest => try self.unary(mathfSig("Round"), .f32),
            .f32_sqrt => try self.unary(mathfSig("Sqrt"), .f32),
            .f32_trunc => {
                // No single-precision Truncate node: go through double (exact).
                const wide = try t.tmp(.f64, 0);
                _ = try t.ext(convSig("Single", "Double"), &.{ try self.use(try self.top(0)), wide });
                _ = try t.ext(mathSig("Truncate", "Double"), &.{ wide, wide });
                const inst = try t.ext(convSig("Double", "Single"), &.{ wide, ph });
                self.drop(1);
                try self.pushPending(.f32, inst, 1);
            },
            .f32_copysign => try self.copysign(.f32),
            .f64_copysign => try self.copysign(.f64),

            else => return error.UnsupportedFeature,
        }
    }

    // ------------------------------------------------------------------
    // Numeric helpers
    // ------------------------------------------------------------------

    /// `(a, b) -> r` through one extern.
    fn binary(self: *Lower, sig: []const u8, result: ValType) Error!void {
        const b = try self.use(try self.top(0));
        const a = try self.use(try self.top(1));
        const inst = try self.t.ext(sig, &.{ a, b, ph });
        self.drop(2);
        try self.pushPending(result, inst, 2);
    }

    pub fn unary(self: *Lower, sig: []const u8, result: ValType) Error!void {
        const inst = try self.t.ext(sig, &.{ try self.use(try self.top(0)), ph });
        self.drop(1);
        try self.pushPending(result, inst, 1);
    }

    fn compare(self: *Lower, sig: []const u8, inverse: ?[]const u8, a: Var, b: Var) Error!void {
        self.drop(2);
        const flag = try self.boolVar(self.stack.items.len);
        const inst = try self.t.ext(sig, &.{ a, b, flag });
        try self.push(.i32, .{ .cond = .{ .v = flag, .inst = inst, .inverse = inverse } });
    }

    fn simpleOp(self: *Lower, s: Simple) Error!void {
        const t = self.t;
        const rhs = try self.top(0);
        const lhs = try self.top(1);
        switch (s.kind) {
            .binary => {
                // Bitwise ops on two comparison results stay boolean.
                const l = self.stack.items[lhs].loc;
                const r = self.stack.items[rhs].loc;
                if (s.bool_sig != null and l == .cond and r == .cond and !l.cond.negated and !r.cond.negated) {
                    const inst = try t.ext(s.bool_sig.?, &.{ l.cond.v, r.cond.v, l.cond.v });
                    self.drop(2);
                    return self.push(.i32, .{ .cond = .{ .v = l.cond.v, .inst = inst } });
                }
                try self.binary(s.sig, s.ty);
            },
            .compare => try self.compare(s.sig, s.inverse, try self.use(lhs), try self.use(rhs)),
            .compare_unsigned => {
                // a <u b  ==  (a ^ MIN) <s (b ^ MIN)
                const a = try self.flipSign(lhs, 0);
                const b = try self.flipSign(rhs, 1);
                try self.compare(s.sig, s.inverse, a, b);
            },
        }
    }

    fn flipSign(self: *Lower, pos: usize, scratch: u8) Error!Var {
        const t = self.t;
        const e = self.stack.items[pos];
        if (e.loc == .konst) return t.constant(.{ .ty = e.ty, .bits = e.loc.konst.bits ^ signBit(e.ty) });
        const out = try t.tmp(Class.of(e.ty), scratch);
        const sig = if (e.ty == .i32) opSig("Int32", "LogicalXor") else opSig("Int64", "LogicalXor");
        _ = try t.ext(sig, &.{ try self.use(pos), try t.constant(.{ .ty = e.ty, .bits = signBit(e.ty) }), out });
        return out;
    }

    fn signBit(ty: ValType) u64 {
        return if (ty == .i32) 0x8000_0000 else 0x8000_0000_0000_0000;
    }

    fn eqz(self: *Lower) Error!void {
        const pos = try self.top(0);
        const e = self.stack.items[pos];
        switch (e.loc) {
            .cond => |c| self.stack.items[pos].loc = .{ .cond = .{ .v = c.v, .negated = !c.negated, .inst = c.inst, .inverse = c.inverse } },
            else => {
                const zero = try self.t.constant(.{ .ty = e.ty, .bits = 0 });
                const sigs: [2][]const u8 = if (e.ty == .i32)
                    .{ cmpSig("Int32", "Equality"), cmpSig("Int32", "Inequality") }
                else
                    .{ cmpSig("Int64", "Equality"), cmpSig("Int64", "Inequality") };
                const x = try self.use(pos);
                // `compare` drops two entries; eqz has only one operand.
                try self.push(.i32, .temp);
                try self.compare(sigs[0], sigs[1], x, zero);
            },
        }
    }

    /// Shift count as a `SystemInt32` variable (i64 shifts carry an i64 count).
    const Count = union(enum) { konst: u6, v: Var };

    fn shiftCount(self: *Lower, pos: usize, ty: ValType) Error!Count {
        const t = self.t;
        const e = self.stack.items[pos];
        const mask: u64 = if (ty == .i32) 31 else 63;
        if (e.loc == .konst) return .{ .konst = @intCast(e.loc.konst.bits & mask) };
        if (ty == .i32) return .{ .v = try self.use(pos) };
        const masked = try t.tmp(.i64, 2);
        const count = try t.tmp(.i32, 2);
        _ = try t.ext(opSig("Int64", "LogicalAnd"), &.{ try self.use(pos), try t.constant(.i64_(63)), masked });
        _ = try t.ext(convSig("Int64", "Int32"), &.{ masked, count });
        return .{ .v = count };
    }

    fn countVar(self: *Lower, c: Count) Error!Var {
        return switch (c) {
            .konst => |k| self.t.constI32(k),
            .v => |v| v,
        };
    }

    fn shiftSig(ty: ValType, comptime name: []const u8) []const u8 {
        return if (ty == .i32) shSig("Int32", name) else shSig("Int64", name);
    }

    fn bitSig(ty: ValType, comptime name: []const u8) []const u8 {
        return if (ty == .i32) opSig("Int32", name) else opSig("Int64", name);
    }

    fn shift(self: *Lower, ty: ValType, comptime name: []const u8) Error!void {
        const count = try self.countVar(try self.shiftCount(try self.top(0), ty));
        const inst = try self.t.ext(shiftSig(ty, name), &.{ try self.use(try self.top(1)), count, ph });
        self.drop(2);
        try self.pushPending(ty, inst, 2);
    }

    /// Emit `dst = a >>> count` using the signed shift plus a mask; returns
    /// the index of the instruction writing `dst`, or null when `count` is a
    /// constant zero (the result is `a` itself).
    fn emitShrU(self: *Lower, ty: ValType, a: Var, count: Count, dst: Var) Error!?u32 {
        const t = self.t;
        const class = Class.of(ty);
        const bits: u7 = if (ty == .i32) 32 else 64;
        const shifted = try t.tmp(class, 0);
        switch (count) {
            .konst => |k| {
                if (k == 0) return null;
                const mask: u64 = (@as(u64, 1) << @intCast(bits - k)) - 1;
                _ = try t.ext(shiftSig(ty, "RightShift"), &.{ a, try t.constI32(k), shifted });
                return try t.ext(bitSig(ty, "LogicalAnd"), &.{ shifted, try t.constant(.{ .ty = ty, .bits = mask }), dst });
            },
            .v => |n| {
                // mask = ~((MIN >> n) << 1): ones below the bits the shift vacated.
                const mask = try t.tmp(class, 1);
                const all_ones = try t.constant(.{ .ty = ty, .bits = if (ty == .i32) 0xFFFF_FFFF else ~@as(u64, 0) });
                _ = try t.ext(shiftSig(ty, "RightShift"), &.{ a, n, shifted });
                _ = try t.ext(shiftSig(ty, "RightShift"), &.{ try t.constant(.{ .ty = ty, .bits = signBit(ty) }), n, mask });
                _ = try t.ext(shiftSig(ty, "LeftShift"), &.{ mask, try t.constI32(1), mask });
                _ = try t.ext(bitSig(ty, "LogicalXor"), &.{ mask, all_ones, mask });
                return try t.ext(bitSig(ty, "LogicalAnd"), &.{ shifted, mask, dst });
            },
        }
    }

    fn shiftRightUnsigned(self: *Lower, ty: ValType) Error!void {
        const count = try self.shiftCount(try self.top(0), ty);
        const inst = try self.emitShrU(ty, try self.use(try self.top(1)), count, ph);
        self.drop(1);
        if (inst) |i| {
            self.drop(1);
            try self.pushPending(ty, i, 2);
        }
    }

    fn rotate(self: *Lower, ty: ValType, left: bool) Error!void {
        const t = self.t;
        const bits: u7 = if (ty == .i32) 32 else 64;
        const count = try self.shiftCount(try self.top(0), ty);
        const a = try self.use(try self.top(1));
        if (count == .konst and count.konst == 0) return self.drop(1);
        // rotl(a, n) = (a << n) | (a >>> (bits - n)); rotr swaps the shifts.
        const opposite: Count = switch (count) {
            .konst => |k| .{ .konst = @intCast(bits - k) },
            .v => |n| blk: {
                // .NET masks shift counts, so -n works for (bits - n).
                const neg = try t.tmp(.i32, 4);
                _ = try t.ext(opSig("Int32", "Subtraction"), &.{ try t.constI32(0), n, neg });
                break :blk .{ .v = neg };
            },
        };
        const logical = try t.tmp(Class.of(ty), 2);
        _ = try self.emitShrU(ty, a, if (left) opposite else count, logical);
        const shl = try t.tmp(Class.of(ty), 0);
        _ = try t.ext(shiftSig(ty, "LeftShift"), &.{ a, try self.countVar(if (left) count else opposite), shl });
        const inst = try t.ext(bitSig(ty, "LogicalOr"), &.{ shl, logical, ph });
        self.drop(2);
        try self.pushPending(ty, inst, 2);
    }

    fn signExtend(self: *Lower, ty: ValType, comptime shift_by: u6) Error!void {
        const t = self.t;
        const scratch = try t.tmp(Class.of(ty), 0);
        const n = try t.constI32(shift_by);
        _ = try t.ext(shiftSig(ty, "LeftShift"), &.{ try self.use(try self.top(0)), n, scratch });
        const inst = try t.ext(shiftSig(ty, "RightShift"), &.{ scratch, n, ph });
        self.drop(1);
        try self.pushPending(ty, inst, 2);
    }

    /// `dst = (int)x` keeping the low 32 bits: sign-extend them in place,
    /// then the checked conversion cannot overflow.
    fn wrap(self: *Lower, x: Var, dst: Var) Error!u32 {
        const t = self.t;
        const scratch = try t.tmp(.i64, 0);
        const n = try t.constI32(32);
        _ = try t.ext(shSig("Int64", "LeftShift"), &.{ x, n, scratch });
        _ = try t.ext(shSig("Int64", "RightShift"), &.{ scratch, n, scratch });
        return t.ext(convSig("Int64", "Int32"), &.{ scratch, dst });
    }

    const Wide = union(enum) { konst: Const, inst: u32 };

    /// Zero-extend the i32 entry at `pos` to i64 in `dst` (via scratch `n`).
    fn zeroExtend(self: *Lower, pos: usize, n: u8, dst: Var) Error!Wide {
        const t = self.t;
        const e = self.stack.items[pos];
        if (e.loc == .konst) return .{ .konst = .i64_(@as(u32, @bitCast(e.loc.konst.asI32()))) };
        const scratch = try t.tmp(.i64, n);
        _ = try t.ext(convSig("Int32", "Int64"), &.{ try self.use(pos), scratch });
        return .{ .inst = try t.ext(opSig("Int64", "LogicalAnd"), &.{ scratch, try t.constant(.i64_(0xFFFF_FFFF)), dst }) };
    }

    /// Unsigned 32-bit division and remainder, computed in 64 bits.
    fn divRemU32(self: *Lower, is_div: bool) Error!void {
        const t = self.t;
        const rhs = try self.top(0);
        const lhs = try self.top(1);
        const divisor: ?u32 = if (self.stack.items[rhs].loc == .konst) @bitCast(self.stack.items[rhs].loc.konst.asI32()) else null;
        const sa = try t.tmp(.i64, 0);
        const sb = try t.tmp(.i64, 1);
        const a: Var = switch (try self.zeroExtend(lhs, 0, sa)) {
            .konst => |c| try t.constant(c),
            .inst => sa,
        };
        const b: Var = switch (try self.zeroExtend(rhs, 1, sb)) {
            .konst => |c| try t.constant(c),
            .inst => sb,
        };
        const inst = if (is_div) blk: {
            _ = try t.ext(opSig("Int64", "Division"), &.{ a, b, sa });
            // With a divisor of at least 2 the quotient fits a signed int.
            if (divisor != null and divisor.? >= 2) break :blk try t.ext(convSig("Int64", "Int32"), &.{ sa, ph });
            break :blk try self.wrap(sa, ph);
        } else blk: {
            _ = try t.ext(div_rem_64, &.{ a, b, sa, sb });
            if (divisor != null and divisor.? <= 0x8000_0000) break :blk try t.ext(convSig("Int64", "Int32"), &.{ sa, ph });
            break :blk try self.wrap(sa, ph);
        };
        self.drop(2);
        try self.pushPending(.i32, inst, 1);
    }

    /// Float → integer truncation, trapping or saturating.
    fn truncate(self: *Lower, to: ValType, signed: bool, saturating: bool) Error!void {
        const t = self.t;
        const pos = try self.top(0);
        if (self.stack.items[pos].ty == .f32) try self.unary(convSig("Single", "Double"), .f64);
        if (to == .i64) {
            if (signed and !saturating) {
                const d = try t.tmp(.f64, 0);
                _ = try t.ext(mathSig("Truncate", "Double"), &.{ try self.use(pos), d });
                const inst = try t.ext(convSig("Double", "Int64"), &.{ d, ph });
                self.drop(1);
                return self.pushPending(.i64, inst, 1);
            }
            return self.callRoutine(if (!saturating) .trunc_u64 else if (signed) .trunc_sat_s64 else .trunc_sat_u64);
        }
        const x = try self.use(pos);
        const d = try t.tmp(.f64, 0);
        _ = try t.ext(mathSig("Truncate", "Double"), &.{ x, d });
        if (!saturating) {
            const inst = if (signed)
                try t.ext(convSig("Double", "Int32"), &.{ d, ph })
            else blk: {
                const wide = try t.tmp(.i64, 0);
                _ = try t.ext(convSig("Double", "Int64"), &.{ d, wide });
                break :blk try self.wrap(wide, ph);
            };
            self.drop(1);
            return self.pushPending(.i32, inst, 1);
        }
        // Saturating: clamp, and map NaN (the only value unequal to itself) to 0.
        const lo: f64 = if (signed) -2147483648.0 else 0.0;
        const hi: f64 = if (signed) 2147483647.0 else 4294967295.0;
        const flag = try t.tmp(.bool, 0);
        const nan = t.prog.newLabel();
        const done = t.prog.newLabel();
        self.stack.items[pos] = .{ .ty = .i32, .loc = .temp };
        const dst = try self.tempVar(pos);
        _ = try t.ext(math2Sig("Min", "Double"), &.{ d, try t.constF64(hi), d });
        _ = try t.ext(math2Sig("Max", "Double"), &.{ d, try t.constF64(lo), d });
        _ = try t.ext(cmpSig("Double", "Equality"), &.{ x, x, flag });
        try t.jif(flag, nan);
        if (signed) {
            _ = try t.ext(convSig("Double", "Int32"), &.{ d, dst });
        } else {
            const wide = try t.tmp(.i64, 0);
            _ = try t.ext(convSig("Double", "Int64"), &.{ d, wide });
            _ = try self.wrap(wide, dst);
        }
        try t.jump(done);
        try t.place(nan);
        try t.copy(try t.constI32(0), dst);
        try t.place(done);
    }

    fn copysign(self: *Lower, ty: ValType) Error!void {
        const t = self.t;
        const int: ValType = if (ty == .f32) .i32 else .i64;
        const to_bits = if (ty == .f32) "SystemBitConverter.__SingleToInt32Bits__SystemSingle__SystemInt32" else "SystemBitConverter.__DoubleToInt64Bits__SystemDouble__SystemInt64";
        const from_bits = if (ty == .f32) "SystemBitConverter.__Int32BitsToSingle__SystemInt32__SystemSingle" else "SystemBitConverter.__Int64BitsToDouble__SystemInt64__SystemDouble";
        const mag = try t.tmp(Class.of(int), 0);
        const sign = try t.tmp(Class.of(int), 1);
        _ = try t.ext(to_bits, &.{ try self.use(try self.top(1)), mag });
        _ = try t.ext(to_bits, &.{ try self.use(try self.top(0)), sign });
        _ = try t.ext(bitSig(int, "LogicalAnd"), &.{ mag, try t.constant(.{ .ty = int, .bits = signBit(int) - 1 }), mag });
        _ = try t.ext(bitSig(int, "LogicalAnd"), &.{ sign, try t.constant(.{ .ty = int, .bits = signBit(int) }), sign });
        _ = try t.ext(bitSig(int, "LogicalOr"), &.{ mag, sign, mag });
        const inst = try t.ext(from_bits, &.{ mag, ph });
        self.drop(2);
        try self.pushPending(ty, inst, 1);
    }

    /// `select`: result = cond ? a : b, with a single branch.
    fn select(self: *Lower) Error!void {
        const t = self.t;
        const cond = try self.popCond();
        const b_pos = try self.top(0);
        const a_pos = try self.top(1);
        const dst = try self.tempVar(a_pos);
        const done = t.prog.newLabel();
        // Reads placed behind the conditional jump must not emit anything.
        try self.settleSource(a_pos);
        try self.settleSource(b_pos);
        if (self.stack.items[a_pos].loc == .temp) {
            // `a` is already in place: overwrite it with `b` unless the test holds.
            if (try self.negative(cond)) |n| {
                try t.jif(n.v, done);
            } else {
                const take_b = t.prog.newLabel();
                try t.jif(cond.v, take_b);
                try t.jump(done);
                try t.place(take_b);
            }
            try t.copy(try self.use(b_pos), dst);
        } else if (cond.negated) {
            // Start from `a`; a false flag means the test holds.
            try self.moveTo(a_pos, dst);
            try t.jif(cond.v, done);
            try t.copy(try self.use(b_pos), dst);
        } else {
            // Start from `b`; a false flag keeps it.
            try self.moveTo(b_pos, dst);
            try t.jif(cond.v, done);
            try t.copy(try self.use(a_pos), dst);
        }
        try t.place(done);
        self.drop(1);
        self.stack.items[a_pos].loc = .temp;
    }

    /// Make sure reading the entry later emits nothing (so the read can sit
    /// behind a conditional jump).
    fn settleSource(self: *Lower, pos: usize) Error!void {
        switch (self.stack.items[pos].loc) {
            .pending, .cond => try self.settle(pos),
            else => {},
        }
    }

    // ------------------------------------------------------------------
    // Memory
    // ------------------------------------------------------------------

    /// Effective address of a memory access as a `SystemInt32` variable.
    fn address(self: *Lower, pos: usize, offset: u32) Error!Var {
        const t = self.t;
        const e = self.stack.items[pos];
        if (e.ty != .i32) return error.InvalidModule;
        if (e.loc == .konst) return t.constI32(e.loc.konst.asI32() +% @as(i32, @bitCast(offset)));
        const base = try self.use(pos);
        if (offset == 0) return base;
        const out = try t.tmp(.i32, 3);
        _ = try t.ext(opSig("Int32", "Addition"), &.{ base, try t.constI32(@bitCast(offset)), out });
        return out;
    }

    /// `read` fetches the stored representation; when it is narrower than
    /// the result (`narrow` names its .NET type) a conversion widens it.
    fn load(self: *Lower, m: MemArg, result: ValType, read: []const u8, comptime narrow: ?[]const u8) Error!void {
        const t = self.t;
        const memory = try t.mem();
        const addr = try self.address(try self.top(0), m.offset);
        const inst = if (narrow) |ty| blk: {
            const init: Init = comptime if (std.mem.eql(u8, ty, "Int32")) .{ .int = 0 } else if (std.mem.eql(u8, ty, "UInt32")) .{ .uint = 0 } else .null_;
            const raw = try t.named("__t_" ++ ty, "System" ++ ty, init);
            if (comptime std.mem.eql(u8, ty, "SByte")) {
                // Reinterpret the byte as signed by copying it into an sbyte[1].
                const sbox = try t.sbyteBox();
                const zero = try t.constI32(0);
                _ = try t.ext(block_copy, &.{ memory, addr, sbox, zero, try t.constI32(1) });
                _ = try t.ext("SystemSByteArray.__Get__SystemInt32__SystemSByte", &.{ sbox, zero, raw });
            } else _ = try t.ext(read, &.{ memory, addr, raw });
            break :blk try t.ext(if (result == .i32) convSig(ty, "Int32") else convSig(ty, "Int64"), &.{ raw, ph });
        } else try t.ext(read, &.{ memory, addr, ph });
        self.drop(1);
        try self.pushPending(result, inst, if (narrow == null) 2 else 1);
    }

    /// Stores go through a one-element typed array: `Buffer.BlockCopy`
    /// writes its first `bytes` bytes (little-endian) into memory.
    fn store(self: *Lower, m: MemArg, value: ValType, bytes: u8) Error!void {
        const t = self.t;
        const class = Class.of(value);
        const set = switch (class) {
            .i32 => "SystemInt32Array.__Set__SystemInt32_SystemInt32__SystemVoid",
            .i64 => "SystemInt64Array.__Set__SystemInt32_SystemInt64__SystemVoid",
            .f32 => "SystemSingleArray.__Set__SystemInt32_SystemSingle__SystemVoid",
            .f64 => "SystemDoubleArray.__Set__SystemInt32_SystemDouble__SystemVoid",
            else => unreachable,
        };
        const value_pos = try self.top(0);
        if (self.stack.items[value_pos].ty != value) return error.InvalidModule;
        const v = try self.use(value_pos);
        const addr = try self.address(try self.top(1), m.offset);
        const b = try t.box(class);
        const zero = try t.constI32(0);
        _ = try t.ext(set, &.{ b, zero, v });
        _ = try t.ext(block_copy, &.{ b, zero, try t.mem(), addr, try t.constI32(bytes) });
        self.drop(2);
    }
};

const min_i32: i32 = std.math.minInt(i32);
const byte_get = "SystemByteArray.__Get__SystemInt32__SystemByte";
const block_copy = "SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid";
const array_copy = "SystemArray.__Copy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid";
const div_rem_64 = "SystemMath.__DivRem__SystemInt64_SystemInt64_SystemInt64Ref__SystemInt64";

// ---------------------------------------------------------------------
// Extern signature helpers
// ---------------------------------------------------------------------

pub fn opSig(comptime ty: []const u8, comptime name: []const u8) []const u8 {
    return "System" ++ ty ++ ".__op_" ++ name ++ "__System" ++ ty ++ "_System" ++ ty ++ "__System" ++ ty;
}
pub fn cmpSig(comptime ty: []const u8, comptime name: []const u8) []const u8 {
    return "System" ++ ty ++ ".__op_" ++ name ++ "__System" ++ ty ++ "_System" ++ ty ++ "__SystemBoolean";
}
pub fn shSig(comptime ty: []const u8, comptime name: []const u8) []const u8 {
    return "System" ++ ty ++ ".__op_" ++ name ++ "__System" ++ ty ++ "_SystemInt32__System" ++ ty;
}
pub fn convSig(comptime from: []const u8, comptime to: []const u8) []const u8 {
    return "SystemConvert.__To" ++ to ++ "__System" ++ from ++ "__System" ++ to;
}
pub fn mathSig(comptime name: []const u8, comptime ty: []const u8) []const u8 {
    return "SystemMath.__" ++ name ++ "__System" ++ ty ++ "__System" ++ ty;
}
pub fn math2Sig(comptime name: []const u8, comptime ty: []const u8) []const u8 {
    return "SystemMath.__" ++ name ++ "__System" ++ ty ++ "_System" ++ ty ++ "__System" ++ ty;
}
fn mathfSig(comptime name: []const u8) []const u8 {
    return "UnityEngineMathf.__" ++ name ++ "__SystemSingle__SystemSingle";
}
fn bitconv(comptime ty: []const u8) []const u8 {
    return "SystemBitConverter.__To" ++ ty ++ "__SystemByteArray_SystemInt32__System" ++ ty;
}

/// Instructions that map onto one operator extern.
const Simple = struct {
    kind: enum { binary, compare, compare_unsigned },
    ty: ValType,
    sig: []const u8,
    inverse: ?[]const u8 = null,
    /// Equivalent `SystemBoolean` operator, for bitwise ops on comparison results.
    bool_sig: ?[]const u8 = null,
};

fn simple(ins: Instruction) ?Simple {
    switch (std.meta.activeTag(ins)) {
        inline else => |tag| return comptime simpleFor(@tagName(tag)),
    }
}

fn simpleFor(comptime name: []const u8) ?Simple {
    @setEvalBranchQuota(20_000);
    if (name.len < 5 or name[3] != '_') return null;
    const types = .{ .{ "i32", "Int32", ValType.i32 }, .{ "i64", "Int64", ValType.i64 }, .{ "f32", "Single", ValType.f32 }, .{ "f64", "Double", ValType.f64 } };
    const eq = std.mem.eql;
    inline for (types) |ty| {
        if (!eq(u8, name[0..3], ty[0])) continue;
        const is_int = name[0] == 'i';
        const op = name[4..];
        // wasm name, .NET operator, integer-only
        const binaries = .{
            .{ "add", "Addition", false }, .{ "sub", "Subtraction", false }, .{ "mul", "Multiplication", false },
            .{ "div", "Division", false }, .{ "div_s", "Division", true },   .{ "and", "LogicalAnd", true },
            .{ "or", "LogicalOr", true },  .{ "xor", "LogicalXor", true },
        };
        inline for (binaries) |b| {
            if (eq(u8, op, b[0]) and (is_int or !b[2]) and !(is_int and eq(u8, op, "div"))) return .{
                .kind = .binary,
                .ty = ty[2],
                .sig = opSig(ty[1], b[1]),
                .bool_sig = if (eq(u8, name[0..3], "i32") and b[1].len > 7 and eq(u8, b[1][0..7], "Logical")) opSig("Boolean", b[1]) else null,
            };
        }
        if (eq(u8, name, "i32_rem_s")) return .{ .kind = .binary, .ty = .i32, .sig = opSig("Int32", "Remainder") };
        if (!is_int and (eq(u8, op, "min") or eq(u8, op, "max")))
            return .{ .kind = .binary, .ty = ty[2], .sig = math2Sig(if (eq(u8, op, "min")) "Min" else "Max", ty[1]) };
        // wasm name, .NET operator, inverse operator
        const compares = .{
            .{ "eq", "Equality", "Inequality" },         .{ "ne", "Inequality", "Equality" },
            .{ "lt", "LessThan", "GreaterThanOrEqual" }, .{ "le", "LessThanOrEqual", "GreaterThan" },
            .{ "gt", "GreaterThan", "LessThanOrEqual" }, .{ "ge", "GreaterThanOrEqual", "LessThan" },
        };
        inline for (compares) |c| {
            const equality = eq(u8, c[0], "eq") or eq(u8, c[0], "ne");
            const plain = eq(u8, op, c[0]) and (!is_int or equality);
            const signed = is_int and !equality and eq(u8, op, c[0] ++ "_s");
            const unsigned = is_int and !equality and eq(u8, op, c[0] ++ "_u");
            if (plain or signed or unsigned) return .{
                .kind = if (unsigned) .compare_unsigned else .compare,
                .ty = ty[2],
                .sig = cmpSig(ty[1], c[1]),
                // With NaN, !(a < b) is not (a >= b): only (in)equality inverts for floats.
                .inverse = if (is_int or equality) cmpSig(ty[1], c[2]) else null,
            };
        }
    }
    return null;
}

// ---------------------------------------------------------------------
// Locals that may be read before they are written
// ---------------------------------------------------------------------

const BitSet = std.DynamicBitSetUnmanaged;

/// Forward "definitely assigned" analysis over the structured body. A local
/// read on some path before any write needs WASM's implicit zero.
fn initScan(a: std.mem.Allocator, code: []const Instruction, n_locals: usize, n_params: usize) Error!BitSet {
    var s: InitScan = .{
        .a = a,
        .assigned = try BitSet.initEmpty(a, n_locals),
        .needs = try BitSet.initEmpty(a, n_locals),
    };
    s.assigned.setRangeValue(.{ .start = 0, .end = n_params }, true);
    try s.scan(code);
    return s.needs;
}

const InitScan = struct {
    a: std.mem.Allocator,
    assigned: BitSet,
    needs: BitSet,
    /// Per open block: the locals assigned on every branch to its end seen
    /// so far (`null` = no branch yet). Loops are never joined at their head.
    exits: std.ArrayList(struct { set: ?BitSet, is_loop: bool }) = .empty,
    dead: bool = false,

    fn join(self: *InitScan, into: *?BitSet) Error!void {
        if (into.*) |*set| set.setIntersection(self.assigned) else into.* = try self.assigned.clone(self.a);
    }

    fn branch(self: *InitScan, depth: u32) Error!void {
        if (depth >= self.exits.items.len) return; // branch to the function body: a return
        const exit = &self.exits.items[self.exits.items.len - 1 - depth];
        if (!exit.is_loop) try self.join(&exit.set);
    }

    /// Leave a block: continue with what every path to its end assigned.
    fn leave(self: *InitScan) Error!void {
        var exit = self.exits.pop().?;
        if (!self.dead) try self.join(&exit.set);
        if (exit.set) |set| {
            self.assigned = set;
            self.dead = false;
        }
    }

    fn scan(self: *InitScan, code: []const Instruction) Error!void {
        for (code) |ins| {
            if (self.dead) return;
            switch (ins) {
                .local_get => |i| if (i < self.needs.bit_length and !self.assigned.isSet(i)) self.needs.set(i),
                .local_set, .local_tee => |i| if (i < self.needs.bit_length) self.assigned.set(i),
                .br => |depth| {
                    try self.branch(depth);
                    self.dead = true;
                },
                .br_if => |depth| try self.branch(depth),
                .br_table => |bt| {
                    for (bt.labels) |depth| try self.branch(depth);
                    try self.branch(bt.default);
                    self.dead = true;
                },
                .return_, .unreachable_ => self.dead = true,
                .block, .loop => |b| {
                    try self.exits.append(self.a, .{ .set = null, .is_loop = ins == .loop });
                    try self.scan(b.body);
                    if (ins == .loop) _ = self.exits.pop() else try self.leave();
                },
                .if_ => |b| {
                    const before = try self.assigned.clone(self.a);
                    try self.exits.append(self.a, .{ .set = null, .is_loop = false });
                    try self.scan(b.then_body);
                    // The then-arm falls through to the end like a branch would.
                    if (!self.dead) try self.branch(0);
                    self.assigned = before;
                    self.dead = false;
                    if (b.else_body) |else_body| try self.scan(else_body);
                    try self.leave();
                },
                else => {},
            }
        }
    }
};

test "simple operator table" {
    const add = simple(.i32_add).?;
    try std.testing.expectEqualStrings("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32", add.sig);
    try std.testing.expect(add.kind == .binary and add.bool_sig == null);
    try std.testing.expectEqualStrings("SystemBoolean.__op_LogicalAnd__SystemBoolean_SystemBoolean__SystemBoolean", simple(.i32_and).?.bool_sig.?);
    try std.testing.expect(simple(.i64_and).?.bool_sig == null);

    const lt_u = simple(.i64_lt_u).?;
    try std.testing.expect(lt_u.kind == .compare_unsigned);
    try std.testing.expectEqualStrings("SystemInt64.__op_LessThan__SystemInt64_SystemInt64__SystemBoolean", lt_u.sig);
    try std.testing.expectEqualStrings("SystemInt64.__op_GreaterThanOrEqual__SystemInt64_SystemInt64__SystemBoolean", lt_u.inverse.?);

    try std.testing.expect(simple(.f64_lt).?.inverse == null);
    try std.testing.expect(simple(.f32_ne).?.inverse != null);
    try std.testing.expectEqualStrings("SystemMath.__Max__SystemSingle_SystemSingle__SystemSingle", simple(.f32_max).?.sig);
    try std.testing.expectEqualStrings("SystemDouble.__op_Division__SystemDouble_SystemDouble__SystemDouble", simple(.f64_div).?.sig);
    try std.testing.expectEqualStrings("SystemInt32.__op_Division__SystemInt32_SystemInt32__SystemInt32", simple(.i32_div_s).?.sig);

    // Handled by dedicated code paths.
    inline for (.{ Tag.i32_div_u, Tag.i32_shl, Tag.i64_rem_s, Tag.i32_eqz, Tag.local_get, Tag.f32_abs }) |tag| {
        try std.testing.expect(simple(@unionInit(Instruction, @tagName(tag), if (tag == .local_get) 0 else {})) == null);
    }
}

test "initScan flags only locals that can be read before a write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // local 0 is a parameter. local 1: set then read. local 2: read first.
    // local 3: set in both arms of an if, read after. local 4: set in one arm only.
    // local 5: set before a br_if out of a block, read after the block.
    const code = [_]Instruction{
        .{ .i32_const = 1 },                                                                                                              .{ .local_set = 1 },
        .{ .local_get = 1 },                                                                                                              .{ .local_get = 2 },
        .{ .if_ = .{ .bt = .empty, .then_body = &.{ .{ .local_set = 3 }, .{ .local_set = 4 } }, .else_body = &.{.{ .local_set = 3 }} } }, .{ .local_get = 3 },
        .{ .local_get = 4 },                                                                                                              .{ .block = .{ .bt = .empty, .body = &.{ .{ .local_set = 5 }, .{ .br_if = 0 }, .{ .local_set = 6 } } } },
        .{ .local_get = 5 },                                                                                                              .{ .local_get = 6 },
        .{ .local_get = 0 },
    };
    const needs = try initScan(arena.allocator(), &code, 7, 1);
    const expected = [_]bool{ false, false, true, false, true, false, true };
    for (expected, 0..) |want, i| try std.testing.expectEqual(want, needs.isSet(i));
}
