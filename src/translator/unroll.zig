//! Recursion without a stack, for the first levels.
//!
//! A function's locals are fixed heap slots, so a function that calls
//! itself has to save the live ones around the call and restore them
//! after it — an extern each way per slot
//! (`docs/spec_call_return_conversion.md` §6). The saving is only needed
//! because both activations use the *same* slots.
//!
//! `unroll` gives the first levels of a small self-recursive function
//! slots of their own: it adds `depth` copies of the function to the
//! module, the first called wherever the function was called from outside,
//! each calling the next where the original calls itself, and the last
//! calling the original. No copy is ever active twice, so none saves
//! anything; a recursion that goes deeper than the copies continues in the
//! original, as before.
//!
//! This is a rewrite of the module, done before translation. The lowering
//! knows nothing about it.

const std = @import("std");
const wasm = @import("wasm");
const callgraph = @import("callgraph.zig");

const I = wasm.Instruction;
const Module = wasm.Module;

pub const Options = struct {
    /// Copies per function at most; 0 turns the rewrite off.
    depth: u32 = 64,
    /// Instructions the copies of one function may add up to.
    budget: u32 = 2048,
    /// A function too large for this many copies within the budget is left
    /// alone: a few levels without frames would not pay for the code.
    min_depth: u32 = 16,
};

const none = std.math.maxInt(u32);

pub fn unroll(arena: std.mem.Allocator, mod: Module, options: Options) error{OutOfMemory}!Module {
    if (options.depth == 0) return mod;
    var n_imported: u32 = 0;
    for (mod.imports) |imp| n_imported += @intFromBool(imp.desc == .func);
    const n_funcs: u32 = n_imported + @as(u32, @intCast(mod.funcs.len));

    var table_funcs: std.ArrayList(u32) = .empty;
    for (mod.elements) |e| for (e.init) |f| {
        if (f < n_funcs) try table_funcs.append(arena, f);
    };
    const cg = try callgraph.analyze(arena, mod, n_imported, table_funcs.items);
    const members = try arena.alloc(u32, n_funcs);
    @memset(members, 0);
    for (cg.scc) |c| members[c] += 1;

    // `entry[f]`: the first copy of `f`, which calls from elsewhere go to.
    const entry = try arena.alloc(u32, n_funcs);
    @memset(entry, none);
    const copies = try arena.alloc(u32, mod.funcs.len);
    @memset(copies, 0);
    var next = n_funcs;
    for (mod.codes, 0..) |code, def| {
        const f = n_imported + @as(u32, @intCast(def));
        // On a cycle of its own making: it calls itself, and nothing it
        // calls can come back to it any other way.
        if (!cg.recursive[f] or members[cg.scc[f]] != 1 or !calls(code.body, f)) continue;
        const depth = @min(options.depth, options.budget / count(code.body));
        if (depth < @min(options.depth, options.min_depth)) continue;
        entry[f] = next;
        copies[def] = depth;
        next += depth;
    }
    if (next == n_funcs) return mod;

    var funcs: std.ArrayList(u32) = .empty;
    var codes: std.ArrayList(wasm.module.Code) = .empty;
    try funcs.appendSlice(arena, mod.funcs);
    for (mod.codes, 0..) |code, def| {
        // The original still calls itself: it is where a recursion deeper
        // than the copies continues.
        const f = n_imported + @as(u32, @intCast(def));
        try codes.append(arena, .{ .locals = code.locals, .body = try retarget(arena, code.body, f, f, entry) });
    }
    for (mod.codes, mod.funcs, 0..) |code, type_index, def| {
        const f = n_imported + @as(u32, @intCast(def));
        for (0..copies[def]) |k| {
            const level: u32 = @intCast(k);
            const deeper = if (level + 1 < copies[def]) entry[f] + level + 1 else f;
            try funcs.append(arena, type_index);
            try codes.append(arena, .{ .locals = code.locals, .body = try retarget(arena, code.body, f, deeper, entry) });
        }
    }
    var out = mod;
    out.funcs = funcs.items;
    out.codes = codes.items;
    return out;
}

fn count(body: []const I) u32 {
    var n: u32 = @intCast(body.len);
    for (body) |ins| switch (ins) {
        .block, .loop => |b| n += count(b.body),
        .if_ => |b| n += count(b.then_body) + if (b.else_body) |e| count(e) else 0,
        else => {},
    };
    return n;
}

fn calls(body: []const I, f: u32) bool {
    for (body) |ins| switch (ins) {
        .call => |callee| if (callee == f) return true,
        .block, .loop => |b| if (calls(b.body, f)) return true,
        .if_ => |b| if (calls(b.then_body, f) or (b.else_body != null and calls(b.else_body.?, f))) return true,
        else => {},
    };
    return false;
}

/// A copy of `body` in which calls of `self` go to `self_target` and calls
/// of any other unrolled function to its first copy.
fn retarget(arena: std.mem.Allocator, body: []const I, self: u32, self_target: u32, entry: []const u32) error{OutOfMemory}![]const I {
    const out = try arena.dupe(I, body);
    for (out) |*ins| switch (ins.*) {
        .call => |callee| {
            if (callee == self) {
                ins.* = .{ .call = self_target };
            } else if (callee < entry.len and entry[callee] != none) {
                ins.* = .{ .call = entry[callee] };
            }
        },
        .block => |b| ins.* = .{ .block = .{ .bt = b.bt, .body = try retarget(arena, b.body, self, self_target, entry) } },
        .loop => |b| ins.* = .{ .loop = .{ .bt = b.bt, .body = try retarget(arena, b.body, self, self_target, entry) } },
        .if_ => |b| ins.* = .{ .if_ = .{
            .bt = b.bt,
            .then_body = try retarget(arena, b.then_body, self, self_target, entry),
            .else_body = if (b.else_body) |e| try retarget(arena, e, self, self_target, entry) else null,
        } },
        else => {},
    };
    return out;
}
