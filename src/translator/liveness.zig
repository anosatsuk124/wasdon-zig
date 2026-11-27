//! Which locals are live after each call.
//!
//! A function on a call-graph cycle saves its frame around a call that may
//! re-enter it (`docs/spec_call_return_conversion.md` §6), and every slot
//! saved costs two externs. A local whose value is not read again before
//! it is overwritten does not need saving; this pass finds, for every call
//! instruction, the locals that do.
//!
//! It also finds the locals that only ever hold a condition
//! (`boolLocals`), which the lowering keeps as a `SystemBoolean`.

const std = @import("std");
const wasm = @import("wasm");

const Instruction = wasm.Instruction;
const Bits = std.DynamicBitSetUnmanaged;

pub const Liveness = struct {
    /// Locals live after a call, keyed by the call instruction's address.
    after_call: std.AutoHashMapUnmanaged(*const Instruction, Bits) = .empty,
    after_loop: std.AutoHashMapUnmanaged(*const Instruction, Bits) = .empty,

    pub fn liveAfter(self: *const Liveness, call: *const Instruction, local: usize) bool {
        // A call this pass did not see (one the lowering synthesized):
        // assume everything is live.
        const set = self.after_call.get(call) orelse return true;
        return local < set.capacity() and set.isSet(local);
    }
};

const Pass = struct {
    arena: std.mem.Allocator,
    n: usize,
    out: *Liveness,
    record_loops: bool,
    /// Live set at each enclosing label, innermost last.
    labels: std.ArrayList(Bits) = .empty,

    fn clone(self: *Pass, set: Bits) !Bits {
        return set.clone(self.arena);
    }

    fn labelAt(self: *Pass, depth: u32) Bits {
        // A depth past the outermost frame is a malformed module; treat it
        // as a return.
        const items = self.labels.items;
        return if (depth < items.len) items[items.len - 1 - depth] else items[0];
    }

    /// Live set before `body`, given the live set after it. `live` is
    /// consumed.
    fn scan(self: *Pass, body: []const Instruction, live_out: Bits) error{OutOfMemory}!Bits {
        var live = live_out;
        var i = body.len;
        while (i > 0) {
            i -= 1;
            const ins = &body[i];
            switch (ins.*) {
                .local_get => |l| if (l < self.n) live.set(l),
                .local_set, .local_tee => |l| if (l < self.n) live.unset(l),
                .call, .call_indirect => if (!self.record_loops) try self.out.after_call.put(self.arena, ins, try self.clone(live)),
                .br => |d| live = try self.clone(self.labelAt(d)),
                .br_if => |d| live.setUnion(self.labelAt(d)),
                .br_table => |bt| {
                    live = try self.clone(self.labelAt(bt.default));
                    for (bt.labels) |d| live.setUnion(self.labelAt(d));
                },
                .return_, .unreachable_ => live = try Bits.initEmpty(self.arena, self.n),
                .block => |b| {
                    try self.labels.append(self.arena, try self.clone(live));
                    live = try self.scan(b.body, live);
                    _ = self.labels.pop();
                },
                .if_ => |b| {
                    try self.labels.append(self.arena, try self.clone(live));
                    var then_in = try self.scan(b.then_body, try self.clone(live));
                    const else_in = if (b.else_body) |e| try self.scan(e, live) else live;
                    then_in.setUnion(else_in);
                    live = then_in;
                    _ = self.labels.pop();
                },
                .loop => |b| {
                    if (self.record_loops) try self.out.after_loop.put(self.arena, ins, try self.clone(live));
                    // A branch to the loop's label re-enters the body, so
                    // the label's live set is the body's own entry set:
                    // iterate until it stops growing.
                    var at_label = try Bits.initEmpty(self.arena, self.n);
                    while (true) {
                        try self.labels.append(self.arena, at_label);
                        const entry = try self.scan(b.body, try self.clone(live));
                        _ = self.labels.pop();
                        var grown = try self.clone(at_label);
                        grown.setUnion(entry);
                        if (grown.eql(at_label)) {
                            live = entry;
                            break;
                        }
                        at_label = grown;
                    }
                },
                else => {},
            }
        }
        return live;
    }
};

/// Analyze a function body with `n_locals` locals (parameters included).
pub fn analyze(arena: std.mem.Allocator, n_locals: usize, body: []const Instruction) !Liveness {
    return analyzeAt(arena, n_locals, body, false);
}

pub fn analyzeAt(arena: std.mem.Allocator, n_locals: usize, body: []const Instruction, loops: bool) !Liveness {
    var out: Liveness = .{};
    var pass: Pass = .{ .arena = arena, .n = n_locals, .out = &out, .record_loops = loops };
    // The function's own frame: a branch to it returns.
    try pass.labels.append(arena, try Bits.initEmpty(arena, n_locals));
    _ = try pass.scan(body, try Bits.initEmpty(arena, n_locals));
    return out;
}

/// Locals that only ever hold a condition: every value stored comes
/// straight from a comparison (or is the constant 0 or 1), and every read
/// goes straight into a test. Such a local can be a `SystemBoolean` for
/// life, which spares the conversion to `Int32` at each store and the
/// comparison with zero at each test — the usual fate of a loop's exit
/// condition when the compiler computes it before the last statements of
/// the body. Parameters never qualify.
pub fn boolLocals(arena: std.mem.Allocator, n_params: usize, local_types: []const wasm.types.ValType, body: []const Instruction) ![]bool {
    const ok = try arena.alloc(bool, local_types.len);
    const used = try arena.alloc(bool, local_types.len);
    @memset(used, false);
    for (ok, local_types, 0..) |*o, ty, i| o.* = i >= n_params and ty == .i32;
    scanUses(body, ok, used);
    // A local never written holds zero and is no use as a Boolean.
    for (ok, used) |*o, u| o.* = o.* and u;
    return ok;
}

fn scanUses(body: []const Instruction, ok: []bool, used: []bool) void {
    for (body, 0..) |ins, i| switch (ins) {
        .local_get => |l| if (l < ok.len) {
            const next: ?Instruction = if (i + 1 < body.len) body[i + 1] else null;
            const tested = if (next) |n| n == .br_if or n == .if_ or n == .i32_eqz or n == .select else false;
            if (!tested) ok[l] = false;
        },
        .local_tee => |l| if (l < ok.len) {
            ok[l] = false;
        },
        .local_set => |l| if (l < ok.len) {
            const condition = i > 0 and isCondition(body[i - 1]);
            if (!condition) ok[l] = false;
            used[l] = true;
        },
        .block, .loop => |b| scanUses(b.body, ok, used),
        .if_ => |b| {
            scanUses(b.then_body, ok, used);
            if (b.else_body) |e| scanUses(e, ok, used);
        },
        else => {},
    };
}

fn isCondition(ins: Instruction) bool {
    return switch (ins) {
        .i32_const => |x| x == 0 or x == 1,
        .i32_eqz, .i64_eqz => true,
        .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => true,
        .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => true,
        .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => true,
        .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => true,
        else => false,
    };
}

/// The value held by these i32 locals fits in a SystemByte on every path.
/// Only direct unsigned byte loads qualify. Parameters may arrive as any i32.
pub fn byteLocals(arena: std.mem.Allocator, n_params: usize, types: []const wasm.types.ValType, body: []const Instruction) ![]bool {
    const ok = try arena.alloc(bool, types.len);
    const written = try arena.alloc(bool, types.len);
    @memset(written, false);
    for (types, 0..) |ty, i| ok[i] = i >= n_params and ty == .i32;
    scanByteWrites(body, ok, written);
    for (ok, written) |*flag, used| flag.* = flag.* and used;
    return ok;
}

fn scanByteWrites(body: []const Instruction, ok: []bool, written: []bool) void {
    for (body, 0..) |ins, i| switch (ins) {
        .local_set, .local_tee => |l| if (l < ok.len) {
            written[l] = true;
            if (i == 0 or body[i - 1] != .i32_load8_u) ok[l] = false;
        },
        .block, .loop => |b| scanByteWrites(b.body, ok, written),
        .if_ => |b| {
            scanByteWrites(b.then_body, ok, written);
            if (b.else_body) |e| scanByteWrites(e, ok, written);
        },
        else => {},
    };
}

// ------------------------------- tests -------------------------------

const testing = std.testing;

test "a local written before it is read again is dead across the call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // local 0 is read after the call; local 1 is overwritten first;
    // local 2 is read only before it.
    const body = [_]Instruction{
        .{ .local_get = 2 }, .drop,
        .{ .call = 0 },      .{ .i32_const = 5 },
        .{ .local_set = 1 }, .{ .local_get = 0 },
        .{ .local_get = 1 }, .i32_add,
        .drop,
    };
    const live = try analyze(arena.allocator(), 3, &body);
    const call = &body[2];
    try testing.expect(live.liveAfter(call, 0));
    try testing.expect(!live.liveAfter(call, 1));
    try testing.expect(!live.liveAfter(call, 2));
}

test "a loop keeps alive what its next iteration reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // loop { call; local 0 = local 0 - 1; br_if 0 (local 0) }  — and
    // local 1 is read at the top of the body, before the call.
    const loop_body = [_]Instruction{
        .{ .local_get = 1 }, .drop,
        .{ .call = 0 },      .{ .local_get = 0 },
        .{ .i32_const = 1 }, .i32_sub,
        .{ .local_tee = 0 }, .{ .br_if = 0 },
    };
    const body = [_]Instruction{.{ .loop = .{ .bt = .empty, .body = &loop_body } }};
    const live = try analyze(arena.allocator(), 2, &body);
    const call = &loop_body[2];
    try testing.expect(live.liveAfter(call, 0));
    // Only through the back edge.
    try testing.expect(live.liveAfter(call, 1));
}

test "branches out of a block carry the liveness of its end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner = [_]Instruction{ .{ .call = 0 }, .{ .i32_const = 1 }, .{ .br_if = 0 }, .{ .i32_const = 0 }, .{ .local_set = 0 } };
    const body = [_]Instruction{ .{ .block = .{ .bt = .empty, .body = &inner } }, .{ .local_get = 0 }, .drop };
    const live = try analyze(arena.allocator(), 1, &body);
    // Live on the path that leaves through the br_if.
    try testing.expect(live.liveAfter(&inner[0], 0));
}

test "boolLocals: stored from comparisons and read by tests only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const types = [_]wasm.types.ValType{ .i32, .i32, .i32, .i32, .i64 };
    const body = [_]Instruction{
        // local 1: a flag.
        .{ .local_get = 0 }, .{ .i32_const = 4 }, .i32_lt_u,           .{ .local_set = 1 },
        .{ .local_get = 1 }, .{ .br_if = 0 },
        // local 2: stored from a comparison but read as a number.
            .{ .local_get = 0 }, .i32_eqz,
        .{ .local_set = 2 }, .{ .local_get = 2 }, .{ .local_get = 0 }, .i32_add,
        .drop,
        // local 3: never written.
                      .{ .local_get = 3 }, .{ .br_if = 0 },
    };
    const flags = try boolLocals(arena.allocator(), 1, &types, &body);
    try testing.expectEqualSlices(bool, &.{ false, true, false, false, false }, flags);
}
