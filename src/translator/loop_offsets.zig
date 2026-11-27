//! Strength reduction for induction variables in counted loops. When all
//! uses of an index are base+index and tests against invariant limits, its
//! heap slot can hold the address itself. Equality survives modular addition.
//! For unsigned ordering, adding 2^31 maps the unsigned order to signed order.
const std = @import("std");
const wasm = @import("wasm");
const I = wasm.Instruction;
const Allocator = std.mem.Allocator;
const none = std.math.maxInt(u32);

pub const Plan = struct { before: []const I = &.{}, body: []const I, after: []const I = &.{}, temps: u32 = 0 };

const Cursor = struct {
    index: u32,
    base: u32 = none,
    limit: u32 = none,
    shifted_limit: u32 = none,
    shifted_base: u32 = none,
    ordered: bool = false,
    until_limit: bool = false,
    adds: u32 = 0,
    comparisons: u32 = 0,
};

pub fn plan(arena: Allocator, body: []const I, first: u32, live_out: std.DynamicBitSetUnmanaged) Allocator.Error!Plan {
    var indices: std.ArrayList(u32) = .empty;
    try candidates(arena, body, &indices);
    var result: Plan = .{ .body = body };
    var before: std.ArrayList(I) = .empty;
    var after: std.ArrayList(I) = .empty;
    for (indices.items) |index| {
        var c = Cursor{ .index = index };
        if (!scan(result.body, &c) or c.adds == 0 or c.base == none or written(body, c.base)) continue;
        if (c.limit != none and written(body, c.limit)) continue;
        // The biased representation removes both sign flips in an unsigned
        // comparison. A plain address removes each per-element base addition.
        if (c.ordered and bounded(result.body, c, 0, true) != null) {
            c.until_limit = true;
        }
        if (c.ordered and !c.until_limit) {
            if (c.comparisons == 0) continue;
            c.shifted_base = first + result.temps;
            result.temps += 1;
            try before.appendSlice(arena, &.{ get(c.base), bias, .i32_xor, set(c.shifted_base) });
        }
        const use_bias = c.ordered and !c.until_limit;
        const offset = if (use_bias) bias else get(c.base);
        const combine: I = if (use_bias) .i32_xor else .i32_add;
        if (c.limit != none) {
            c.shifted_limit = first + result.temps;
            result.temps += 1;
            if (c.until_limit) {
                // Starting above the limit means no increment can execute.
                // Set the sentinel to the starting position on that path.
                try before.appendSlice(arena, &.{ get(c.limit), get(index), get(index), get(c.limit), .i32_lt_u, .select });
            } else try before.append(arena, get(c.limit));
            try before.appendSlice(arena, &.{ offset, combine, set(c.shifted_limit) });
        }
        try before.appendSlice(arena, &.{ get(index), offset, combine, set(index) });
        result.body = try rewrite(arena, result.body, c);
        if (index < live_out.capacity() and live_out.isSet(index))
            try after.appendSlice(arena, &.{ get(index), offset, if (use_bias) .i32_xor else .i32_sub, set(index) });
    }
    result.before = before.items;
    result.after = after.items;
    return result;
}

const bias: I = .{ .i32_const = std.math.minInt(i32) };
fn get(l: u32) I {
    return .{ .local_get = l };
}
fn set(l: u32) I {
    return .{ .local_set = l };
}

fn step(body: []const I) ?u32 {
    if (body.len < 4 or body[0] != .local_get or body[1] != .i32_const or body[2] != .i32_add or
        body[3] != .local_set or body[3].local_set != body[0].local_get) return null;
    return body[0].local_get;
}

fn candidates(arena: Allocator, body: []const I, out: *std.ArrayList(u32)) Allocator.Error!void {
    for (body, 0..) |ins, i| switch (ins) {
        .block => |b| try candidates(arena, b.body, out),
        .if_ => |b| {
            try candidates(arena, b.then_body, out);
            if (b.else_body) |e| try candidates(arena, e, out);
        },
        .local_get => if (step(body[i..])) |l| {
            if (std.mem.indexOfScalar(u32, out.items, l) == null) try out.append(arena, l);
        },
        else => {},
    };
}

fn written(body: []const I, local: u32) bool {
    return wasm.instruction.any(body, local, struct {
        fn writes(l: u32, i: I) bool {
            return switch (i) {
                .local_set, .local_tee => |n| l == n,
                else => false,
            };
        }
    }.writes);
}

fn pair(body: []const I, index: u32) ?u32 {
    if (body.len < 3 or body[0] != .local_get or body[1] != .local_get) return null;
    if (body[0].local_get == index) return body[1].local_get;
    if (body[1].local_get == index) return body[0].local_get;
    return null;
}

fn scan(body: []const I, c: *Cursor) bool {
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (step(body[i..]) == c.index) {
            i += 3;
            continue;
        }
        if (pair(body[i..], c.index)) |other| {
            if (other == c.index) return false;
            switch (body[i + 2]) {
                .i32_add => {
                    if (c.base != none and c.base != other) return false;
                    c.base = other;
                    c.adds += 1;
                },
                .i32_eq, .i32_ne, .i32_lt_u, .i32_ge_u, .i32_gt_u, .i32_le_u => {
                    if (c.limit != none and c.limit != other) return false;
                    c.limit = other;
                    c.ordered = c.ordered or (body[i + 2] != .i32_eq and body[i + 2] != .i32_ne);
                    c.comparisons += 1;
                },
                else => return false,
            }
            i += 2;
            continue;
        }
        switch (body[i]) {
            .local_get, .local_set, .local_tee => |l| if (l == c.index) return false,
            .block => |b| if (!scan(b.body, c)) return false,
            .if_ => |b| {
                if (!scan(b.then_body, c)) return false;
                if (b.else_body) |e| if (!scan(e, c)) return false;
            },
            .loop => return false,
            else => {},
        }
    }
    return true;
}

// Explore the path on which index < limit is false. If no increment
// is reachable there, a unit-stride index can be tested for inequality
// with its sentinel. Only accept this one order relation for every use
// of the limit. Other writes or non-unit steps invalidate the proof.
fn bounded(body: []const I, c: Cursor, depth: u32, reachable: bool) ?u64 {
    if (depth >= 60) return null;
    var flow: u64 = @intFromBool(reachable); // bit 0 falls through; bit d+1 branches to label d
    for (body, 0..) |ins, i| {
        const active = flow & 1 != 0;
        if (pair(body[i..], c.index)) |other| {
            if (other == c.limit and body[i + 2] != .i32_add and
                !(body[i].local_get == c.index and body[i + 2] == .i32_lt_u)) return null;
        }
        if (step(body[i..]) == c.index and body[i + 1].i32_const != 1) return null;
        switch (ins) {
            .local_set, .local_tee => |l| if (active and l == c.index) return null,
            .block => |b| {
                const child = bounded(b.body, c, depth + 1, active) orelse return null;
                if (active) flow = (flow & ~@as(u64, 1)) | (child & 1) | (child >> 1);
            },
            .if_, .br_table, .loop => return null,
            .br, .br_if => |d| {
                if (d >= 60) return null;
                const always_false = ins == .br_if and i >= 3 and
                    body[i - 3] == .local_get and body[i - 3].local_get == c.index and
                    body[i - 2] == .local_get and body[i - 2].local_get == c.limit and body[i - 1] == .i32_lt_u;
                if (active and !always_false) {
                    if (ins == .br) flow &= ~@as(u64, 1);
                    flow |= @as(u64, 2) << @intCast(d);
                }
            },
            .return_, .unreachable_ => flow &= ~@as(u64, 1),
            else => {},
        }
    }
    return flow;
}

fn rewrite(arena: Allocator, body: []const I, c: Cursor) Allocator.Error![]const I {
    var out: std.ArrayList(I) = .empty;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (pair(body[i..], c.index) != null) {
            const op = body[i + 2];
            if (op == .i32_add) {
                try out.append(arena, get(c.index));
                if (c.ordered and !c.until_limit) try out.appendSlice(arena, &.{ get(c.shifted_base), .i32_add });
            } else {
                for (body[i..][0..2]) |arg| try out.append(arena, if (arg.local_get == c.index) arg else get(c.shifted_limit));
                try out.append(arena, switch (op) {
                    .i32_lt_u => if (c.until_limit) .i32_ne else .i32_lt_s,
                    .i32_ge_u => .i32_ge_s,
                    .i32_gt_u => .i32_gt_s,
                    .i32_le_u => .i32_le_s,
                    else => op,
                });
            }
            i += 2;
            continue;
        }
        var ins = body[i];
        switch (ins) {
            .block => |b| ins.block.body = try rewrite(arena, b.body, c),
            .if_ => |b| {
                ins.if_.then_body = try rewrite(arena, b.then_body, c);
                if (b.else_body) |e| ins.if_.else_body = try rewrite(arena, e, c);
            },
            else => {},
        }
        try out.append(arena, ins);
    }
    return out.items;
}
