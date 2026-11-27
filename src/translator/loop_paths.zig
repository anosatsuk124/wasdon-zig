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
    folded: bool = false,

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
                        self.folded = true;
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
        return self.folded;
    }
};

/// Compile only loops whose complete control flow and heap writes are
/// visible here. In particular a host call may re-enter the VM.
pub fn optimize(a: *A, head: Label, dead: anytype) !bool {
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
