//! Bounded basic-block versioning for small, branchy loops. A comparison
//! taken along a backedge is still true on the next iteration if neither
//! operand changed. Carry that fact on the edge instead of retesting it.
const std = @import("std");
const udon = @import("udon");
const A = udon.asm_.Asm;
const Sym = udon.asm_.Sym;
const Instr = udon.asm_.Instr;
const Label = udon.asm_.Label;
const none = std.math.maxInt(u32);
const max_ins = 160;
const max_states = 96;
const max_tests = 4;

const Test = struct { lhs: Sym, rhs: Sym };
const Op = struct {
    start: u8,
    end: u8,
    target: u8 = 0,
    kind: enum { compute, jump, branch, test_branch } = .compute,
    writes: Sym = none,
    test_id: u8 = 0,
};
const State = struct { pc: u8, yes: u8 = 0, no: u8 = 0 };
const Block = struct { state: State, copy: [max_ins]u8 = undefined, len: usize = 0, branch: ?u8 = null, next: u8 = 0, other: u8 = 0 };
const exit: u8 = 255;

const Graph = struct {
    ops: [max_ins]Op = undefined,
    len: u8 = 0,
    tests: [max_tests]Test = undefined,
    ntests: u8 = 0,
    blocks: [max_states]Block = undefined,
    nblocks: u8 = 0,
    folded_tests: u8 = 0,

    fn state(self: *Graph, s: State) ?u8 {
        if (s.pc == self.len) return exit;
        for (self.blocks[0..self.nblocks], 0..) |b, i| if (std.meta.eql(b.state, s)) return @intCast(i);
        if (self.nblocks == max_states) return null;
        self.blocks[self.nblocks] = .{ .state = s };
        self.nblocks += 1;
        return self.nblocks - 1;
    }

    fn kill(self: *const Graph, s: *State, dst: Sym) void {
        if (dst == none) return;
        for (self.tests[0..self.ntests], 0..) |t, i| if (t.lhs == dst or t.rhs == dst) {
            const mask = ~(@as(u8, 1) << @intCast(i));
            s.yes &= mask;
            s.no &= mask;
        };
    }

    fn build(self: *Graph) bool {
        _ = self.state(.{ .pc = 0 });
        var emitted: usize = 0;
        var i: usize = 0;
        while (i < self.nblocks) : (i += 1) {
            const b = &self.blocks[i];
            var s = b.state;
            // Forward jumps are followed here. End the version at the
            // backedge, where the remaining facts choose the next header.
            while (s.pc < self.len) {
                const pc = s.pc;
                const op = self.ops[pc];
                s.pc += 1;
                if (op.kind == .compute) {
                    b.copy[b.len] = pc;
                    b.len += 1;
                    emitted += op.end - op.start;
                    self.kill(&s, op.writes);
                } else if (op.kind == .jump) {
                    s.pc = op.target;
                } else {
                    const bit = @as(u8, 1) << @intCast(op.test_id);
                    if (op.kind == .test_branch and (s.yes | s.no) & bit != 0) {
                        self.folded_tests |= bit;
                        if (s.no & bit != 0) s.pc = op.target;
                    } else {
                        var otherwise = s;
                        otherwise.pc = op.target;
                        if (op.kind == .test_branch) {
                            s.yes |= bit;
                            otherwise.no |= bit;
                        }
                        b.branch = pc;
                        b.next = self.state(s) orelse return false;
                        b.other = self.state(otherwise) orelse return false;
                        emitted += op.end - op.start;
                        break;
                    }
                }
                if (s.pc <= pc or s.pc == self.len) {
                    b.next = self.state(s) orelse return false;
                    break;
                }
            }
            if (emitted > 8 * max_ins) return false;
        }
        return self.folded_tests != 0;
    }
};

/// Compile only loops whose complete control flow and heap writes are
/// visible here. In particular a host call may re-enter the VM.
pub fn optimize(a: *A, head: Label, dead: anytype, backend: anytype, loop_site: anytype) !bool {
    const start = a.labels.items[head].pos;
    const raw = a.code.items[start..];
    if (raw.len < 8 or raw.len > max_ins) return false;
    var g: Graph = .{};
    var boundaries = [_]u8{exit} ** (max_ins + 1);
    var targets = [_]bool{false} ** (max_ins + 1);
    for (raw) |ins| switch (ins.op) {
        .jump, .jump_if_false => {
            if (ins.arg == udon.asm_.halt) return false;
            const pos = a.labels.items[ins.arg].pos;
            if (pos < start or pos - start > raw.len) return false;
            targets[pos - start] = true;
        },
        .push, .extern_, .copy => {},
        else => return false,
    };
    var pos: usize = 0;
    while (pos < raw.len) {
        const first = pos;
        while (pos < raw.len and raw[pos].op == .push) pos += 1;
        if (pos == raw.len) return false;
        const ins = raw[pos];
        const args = raw[first..pos];
        pos += 1;
        var op: Op = .{ .start = @intCast(first), .end = @intCast(pos) };
        switch (ins.op) {
            .extern_ => {
                const signature = udon.nodes.parseSignature(a.externs.items[ins.arg]) orelse return false;
                const numeric = numericOperator(signature);
                const array = std.mem.endsWith(u8, signature.type_name, "Array");
                if (numeric or (array and std.mem.eql(u8, signature.method, "Get"))) {
                    if (args.len < 2) return false;
                    op.writes = args[args.len - 1].arg;
                } else if (!(array and std.mem.eql(u8, signature.method, "Set"))) return false;
                // A scratch Boolean consumed only by this following jump
                // can disappear with the comparison. It is dead on exit.
                if (g.ntests < max_tests and args.len == 3 and numeric and
                    std.mem.eql(u8, signature.ret, "SystemBoolean") and dead.contains(op.writes) and
                    pos + 2 <= raw.len and raw[pos].op == .push and raw[pos].arg == op.writes and raw[pos + 1].op == .jump_if_false and
                    !targets[pos] and !targets[pos + 1] and branchOnly(a, raw, &targets, op.writes))
                {
                    op.kind = .test_branch;
                    op.target = @intCast(a.labels.items[raw[pos + 1].arg].pos - start);
                    op.test_id = g.ntests;
                    g.tests[g.ntests] = .{ .lhs = args[0].arg, .rhs = args[1].arg };
                    g.ntests += 1;
                    pos += 2;
                    op.end = @intCast(pos);
                }
            },
            .copy => {
                if (args.len != 2) return false;
                op.writes = args[1].arg;
            },
            .jump, .jump_if_false => {
                if (args.len != @intFromBool(ins.op == .jump_if_false)) return false;
                op.kind = if (ins.op == .jump) .jump else .branch;
                op.target = @intCast(a.labels.items[ins.arg].pos - start);
            },
            else => return false,
        }
        boundaries[first] = g.len;
        g.ops[g.len] = op;
        g.len += 1;
    }
    if (g.ntests == 0) return false;
    boundaries[raw.len] = g.len;
    for (g.ops[0..g.len], 0..) |*op, i| if (op.kind != .compute) {
        op.target = boundaries[op.target];
        if (op.target == exit or (op.target <= i and op.target != 0)) return false;
    };
    if (!g.build()) return false;
    const saved = try a.gpa.dupe(Instr, raw);
    defer a.gpa.free(saved);
    // Only the loop header has incoming edges from outside this region.
    // No calls or indirect jumps were admitted by the decoder.
    for (a.labels.items[head + 1 ..]) |*label| if (label.pos != std.math.maxInt(u32) and label.pos >= start) {
        label.pos = start;
    };
    a.code.shrinkRetainingCapacity(start);
    const done = try a.newLabel();
    if (!backend.t.options.disable.loop_strip_mining) {
        if (stripPlan(&g, a, saved, try backend.t.constI32(1))) |plan|
            try emitStrips(&g, a, saved, plan, backend, done, loop_site);
    }
    try emit(&g, a, saved, done);
    a.bind(done);
    return true;
}

fn emit(g: *const Graph, a: *A, saved: []const Instr, done: Label) !void {
    var labels: [max_states]Label = undefined;
    for (labels[0..g.nblocks]) |*label| label.* = try a.newLabel();
    for (g.blocks[0..g.nblocks], 0..) |b, i| {
        a.bind(labels[i]);
        for (b.copy[0..b.len]) |ix| {
            const op = g.ops[ix];
            try a.code.appendSlice(a.gpa, saved[op.start..op.end]);
        }
        if (b.branch) |ix| {
            const op = g.ops[ix];
            try a.code.appendSlice(a.gpa, saved[op.start .. op.end - 1]);
            try a.code.append(a.gpa, .{ .op = .jump_if_false, .arg = if (b.other == exit) done else labels[b.other] });
        }
        if (b.next != i + 1) try a.jump(if (b.next == exit) done else labels[b.next]);
    }
}

// Partition a counted loop at the next point where an equality can
// change. If a cursor advances by at most one per iteration, a distance
// of d guarantees d unequal tests before the next possible equality.
const Bound = struct { cursor: Sym, limit: Sym, equal: bool, test_pc: usize };
const Strip = struct { latch: Bound, bounds: [max_tests]Bound = undefined, len: usize = 0 };
const i32_add = "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32";
const i32_sub = "SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32";
const i32_eq = "SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean";
const i32_ne = "SystemInt32.__op_Inequality__SystemInt32_SystemInt32__SystemBoolean";
const i32_ge = "SystemInt32.__op_GreaterThanOrEqual__SystemInt32_SystemInt32__SystemBoolean";

fn unitBound(g: *const Graph, a: *A, raw: []const Instr, pc: usize, one: Sym, latch: bool) ?Bound {
    const op = g.ops[pc];
    if (op.kind != .test_branch or op.end - op.start != 6) return null;
    const sig = a.externs.items[raw[op.start + 3].arg];
    const equal = std.mem.eql(u8, sig, i32_eq);
    if (!equal and !std.mem.eql(u8, sig, i32_ne)) return null;
    const t = g.tests[op.test_id];
    for ([2]Test{ t, .{ .lhs = t.rhs, .rhs = t.lhs } }) |pair| {
        var step: ?usize = null;
        for (g.ops[0..g.len], 0..) |ins, i| {
            if (ins.writes == pair.rhs) break;
            if (ins.writes != pair.lhs) continue;
            const expr = raw[ins.start..ins.end];
            if (step != null or expr.len != 4 or expr[3].op != .extern_ or
                !std.mem.eql(u8, a.externs.items[expr[3].arg], i32_add) or
                !((expr[0].arg == pair.lhs and expr[1].arg == one) or (expr[1].arg == pair.lhs and expr[0].arg == one))) break;
            step = i;
        } else {
            const at = step orelse continue;
            if (latch) {
                if (!equal or at >= pc) continue;
                // Every path to the latch must pass through this update.
                for (g.ops[0..at]) |ins| {
                    if (ins.kind != .compute and ins.target > at) break;
                } else return .{ .cursor = pair.lhs, .limit = pair.rhs, .equal = equal, .test_pc = pc };
            } else if (at > pc) return .{ .cursor = pair.lhs, .limit = pair.rhs, .equal = equal, .test_pc = pc };
        }
    }
    return null;
}

fn stripPlan(g: *const Graph, a: *A, raw: []const Instr, one: Sym) ?Strip {
    const latch = g.len - 1;
    if (g.ops[latch].target != 0) return null;
    for (g.ops[0..latch]) |op| {
        if (op.kind != .compute and (op.target == 0 or op.target > latch)) return null;
    }
    var plan: Strip = .{ .latch = unitBound(g, a, raw, latch, one, true) orelse return null };
    for (0..latch) |pc| {
        const op = g.ops[pc];
        // Prioritize tests which survive a backedge. A one-off test on
        // the primary iteration number should not shorten every strip.
        if (op.kind != .test_branch or g.folded_tests & (@as(u8, 1) << @intCast(op.test_id)) == 0) continue;
        const b = unitBound(g, a, raw, pc, one, false) orelse continue;
        plan.bounds[plan.len] = b;
        plan.len += 1;
    }
    return if (plan.len == 0) null else plan;
}

fn emitStrips(g: *const Graph, a: *A, raw: []const Instr, plan: Strip, backend: anytype, done: Label, loop_site: anytype) !void {
    const factor = 4;
    const span = try backend.freshTemp("SystemInt32");
    const stop = try backend.freshTemp("SystemInt32");
    const flag = try backend.freshTemp("SystemBoolean");
    const dead_update = try finalDead(g, a, raw, backend, loop_site);
    const guard = try a.newLabel();
    const scalar = try a.newLabel();
    const small = try a.newLabel();
    a.bind(guard);
    try a.call(i32_sub, &.{ plan.latch.limit, plan.latch.cursor, span });
    try a.call(i32_ge, &.{ span, try backend.t.constI32(factor + 1), flag });
    try a.jumpIfFalse(flag, small);
    var taken: [max_ins]?bool = @splat(null);
    for (plan.bounds[0..plan.len]) |b| {
        try a.call(i32_sub, &.{ b.limit, b.cursor, stop });
        try a.call("SystemMath.__Min__SystemInt32_SystemInt32__SystemInt32", &.{ span, stop, span });
        taken[b.test_pc] = b.equal; // JUMP_IF_FALSE for equal operands tested as unequal
    }
    try a.call(i32_ge, &.{ span, try backend.t.constI32(factor), flag });
    try a.jumpIfFalse(flag, scalar);
    try a.call("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32", &.{ span, try backend.t.constI32(-factor), span });
    try a.call(i32_add, &.{ plan.latch.cursor, span, stop });
    const header = try a.newLabel();
    a.bind(header);
    for (0..factor) |_| try emitIteration(g, a, raw, &taken, null);
    try a.call(i32_eq, &.{ plan.latch.cursor, stop, flag });
    try a.jumpIfFalse(flag, header);
    try a.call(i32_eq, &.{ plan.latch.cursor, plan.latch.limit, flag });
    try a.jumpIfFalse(flag, guard);
    try a.jump(done);
    a.bind(small);
    try a.call(i32_ge, &.{ span, try backend.t.constI32(0), flag });
    try a.jumpIfFalse(flag, scalar);
    const entries = try backend.t.arena().alloc(Label, factor + 1);
    entries[0] = scalar; // Zero trips in a do-while with i32 wrap denote 2^32 iterations.
    for (entries[1..]) |*entry| entry.* = try a.newLabel();
    const target = try backend.freshTemp("SystemUInt32");
    try a.call("SystemUInt32Array.__Get__SystemInt32__SystemUInt32", &.{ try backend.t.jumpTable(entries), span, target });
    try a.jumpIndirect(target);
    const unknown: [max_ins]?bool = @splat(null);
    for (0..factor) |j| {
        const remaining = factor - j;
        a.bind(entries[remaining]);
        try emitIteration(g, a, raw, &unknown, if (remaining == 1) &dead_update else null);
    }
    try a.jump(done);
    a.bind(scalar);
}

// With the latch peeled off, the last iteration is an acyclic CFG. Drop
// unused computations along its paths, preserving memory operations and
// integer divisions, which may still fault even when their result is dead.
fn finalDead(g: *const Graph, a: *A, raw: []const Instr, backend: anytype, site: anytype) ![max_ins]bool {
    const Bits = std.StaticBitSet(max_ins);
    var omit = [_]bool{false} ** max_ins;
    const live_out = try backend.liveAfterLoop(site) orelse return omit;
    var slots: [max_ins]Sym = undefined;
    var n: usize = 0;
    for (g.ops[0..g.len]) |op| {
        if (op.writes == none or std.mem.indexOfScalar(Sym, slots[0..n], op.writes) != null) continue;
        slots[n] = op.writes;
        n += 1;
    }
    var before: [max_ins]Bits = undefined;
    const latch = g.len - 1;
    before[latch] = Bits.initFull();
    for (slots[0..n], 0..) |slot, k| {
        if (std.mem.indexOfScalar(Sym, backend.f.locals, slot)) |local| {
            if (!live_out.isSet(local)) before[latch].unset(k);
        } else for (backend.pools.items) |pool| {
            if (std.mem.indexOfScalar(Sym, pool.free.items, slot) != null) before[latch].unset(k);
        }
    }
    var pc: usize = latch;
    while (pc > 0) {
        pc -= 1;
        const op = g.ops[pc];
        var live = if (op.kind == .jump) before[op.target] else before[pc + 1];
        if (op.kind == .test_branch or op.kind == .branch) live.setUnion(before[op.target]);
        var args = raw[op.start..op.end];
        if (op.writes != none) {
            const dst = std.mem.indexOfScalar(Sym, slots[0..n], op.writes).?;
            if (op.kind == .compute and !live.isSet(dst) and removable(a, args)) {
                omit[pc] = true;
                before[pc] = live;
                continue;
            }
            live.unset(dst);
            args = args[0 .. args.len - @as(usize, if (op.kind == .test_branch) 4 else 2)];
        }
        for (args) |ins| if (ins.op == .push) {
            if (std.mem.indexOfScalar(Sym, slots[0..n], ins.arg)) |id| live.set(id);
        };
        before[pc] = live;
    }
    return omit;
}

fn removable(a: *A, raw: []const Instr) bool {
    const ins = raw[raw.len - 1];
    if (ins.op == .copy) return true;
    const sig = udon.nodes.parseSignature(a.externs.items[ins.arg]) orelse return false;
    if (!numericOperator(sig)) return false;
    for ([_][]const u8{ "op_Addition", "op_Subtraction", "op_Multiplication", "op_LogicalAnd", "op_LogicalOr", "op_LogicalXor", "op_LeftShift", "op_RightShift", "op_Equality", "op_Inequality", "op_LessThan", "op_LessThanOrEqual", "op_GreaterThan", "op_GreaterThanOrEqual" }) |name| {
        if (std.mem.eql(u8, sig.method, name)) return true;
    }
    return false;
}

fn emitIteration(g: *const Graph, a: *A, raw: []const Instr, fixed: *const [max_ins]?bool, omit: ?*const [max_ins]bool) !void {
    var labels: [max_ins]Label = undefined;
    var reachable = [_]bool{false} ** max_ins;
    reachable[0] = true;
    for (labels[0..g.len]) |*label| label.* = try a.newLabel();
    for (g.ops[0 .. g.len - 1], 0..) |op, pc| {
        a.bind(labels[pc]);
        if (!reachable[pc]) continue;
        if (fixed[pc]) |jump| {
            if (jump) {
                try a.jump(labels[op.target]);
                reachable[op.target] = true;
            } else reachable[pc + 1] = true;
        } else if (op.kind == .compute) {
            if (omit == null or !omit.?[pc]) try a.code.appendSlice(a.gpa, raw[op.start..op.end]);
            reachable[pc + 1] = true;
        } else {
            try a.code.appendSlice(a.gpa, raw[op.start .. op.end - 1]);
            try a.code.append(a.gpa, .{ .op = raw[op.end - 1].op, .arg = labels[op.target] });
            reachable[op.target] = true;
            if (op.kind != .jump) reachable[pc + 1] = true;
        }
    }
    a.bind(labels[g.len - 1]);
}

fn numericOperator(signature: udon.nodes.Signature) bool {
    if (!std.mem.startsWith(u8, signature.method, "op_")) return false;
    for ([_][]const u8{ "SystemByte", "SystemSByte", "SystemInt16", "SystemUInt16", "SystemInt32", "SystemUInt32", "SystemInt64", "SystemUInt64", "SystemSingle", "SystemDouble" }) |ty| {
        if (std.mem.eql(u8, ty, signature.type_name)) return true;
    }
    return false;
}

// PUSHes for this Boolean must be either result destinations or direct
// JUMP_IF_FALSE inputs. A COPY from it would make the value observable.
fn branchOnly(a: *A, raw: []const Instr, targets: []const bool, sym: Sym) bool {
    for (raw, 0..) |ins, i| if (ins.op == .push and ins.arg == sym) {
        if (i + 1 == raw.len or (raw[i + 1].op != .extern_ and raw[i + 1].op != .jump_if_false)) return false;
        if (raw[i + 1].op == .extern_) {
            const sig = udon.nodes.parseSignature(a.externs.items[raw[i + 1].arg]) orelse return false;
            if (!std.mem.eql(u8, sig.ret, "SystemBoolean")) return false;
        }
        // A standalone branch could be reading an earlier comparison.
        if (raw[i + 1].op == .jump_if_false and (targets[i] or targets[i + 1] or i == 0 or raw[i - 1].op != .extern_ or
            i < 2 or raw[i - 2].op != .push or raw[i - 2].arg != sym)) return false;
    };
    return true;
}
