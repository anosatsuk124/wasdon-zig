//! Call-graph construction + SCC (strongly connected components) detection.
//!
//! Used by the translator to determine which WASM functions are recursive
//! (self-recursive OR part of a mutual-recursion cycle) and therefore need
//! the prologue/epilogue frame spill described in
//! `docs/spec_call_return_conversion.md` §8.2.

const std = @import("std");
const wasm = @import("wasm");

const Instruction = wasm.Instruction;

/// Scan a function body and append every `call` target index to `out`.
/// For `call_indirect` targets, pass in the union of indirect-callable
/// function indices via `indirect_callees` (call_indirect can reach any of
/// them, so we conservatively add edges to all of them).
pub fn collectCallees(
    allocator: std.mem.Allocator,
    body: []const Instruction,
    indirect_callees: []const u32,
    out: *std.ArrayList(u32),
) !void {
    for (body) |ins| switch (ins) {
        .call => |idx| try out.append(allocator, idx),
        .call_indirect => {
            for (indirect_callees) |idx| try out.append(allocator, idx);
        },
        .block => |b| try collectCallees(allocator, b.body, indirect_callees, out),
        .loop => |b| try collectCallees(allocator, b.body, indirect_callees, out),
        .if_ => |b| {
            try collectCallees(allocator, b.then_body, indirect_callees, out);
            if (b.else_body) |eb| try collectCallees(allocator, eb, indirect_callees, out);
        },
        else => {},
    };
}

pub const CallGraph = struct {
    adjacency: [][]const u32,

    pub fn deinit(self: *CallGraph, gpa: std.mem.Allocator) void {
        for (self.adjacency) |row| {
            if (row.len > 0) gpa.free(row);
        }
        gpa.free(self.adjacency);
    }
};

/// Build a forward call-graph: for each function index in `[0, n)`,
/// caller → list of callees. Entries for imported functions (indices <
/// num_imports) are empty.
pub fn buildCallGraph(
    gpa: std.mem.Allocator,
    mod: wasm.Module,
    num_imports: u32,
    indirect_callees: []const u32,
) !CallGraph {
    const total = num_imports + @as(u32, @intCast(mod.codes.len));
    const rows = try gpa.alloc([]const u32, total);
    for (rows) |*r| r.* = &.{};
    for (mod.codes, 0..) |code, i| {
        var list: std.ArrayList(u32) = .empty;
        defer list.deinit(gpa);
        try collectCallees(gpa, code.body, indirect_callees, &list);
        const caller_idx = num_imports + @as(u32, @intCast(i));
        rows[caller_idx] = try list.toOwnedSlice(gpa);
    }
    return .{ .adjacency = rows };
}

/// Iterative Tarjan's SCC. Returns a bool[] where `true` means the function
/// is in an SCC of size ≥ 2 OR has a self-edge.
pub fn detectRecursive(gpa: std.mem.Allocator, graph: CallGraph) ![]bool {
    const n = graph.adjacency.len;
    const is_recursive = try gpa.alloc(bool, n);
    @memset(is_recursive, false);

    // Self-edges: tag immediately.
    for (graph.adjacency, 0..) |callees, caller| {
        for (callees) |c| {
            if (c == caller) {
                is_recursive[caller] = true;
                break;
            }
        }
    }

    if (n == 0) return is_recursive;

    const UNDEF: i32 = -1;
    const index = try gpa.alloc(i32, n);
    defer gpa.free(index);
    const lowlink = try gpa.alloc(i32, n);
    defer gpa.free(lowlink);
    const on_stack = try gpa.alloc(bool, n);
    defer gpa.free(on_stack);
    @memset(index, UNDEF);
    @memset(lowlink, 0);
    @memset(on_stack, false);

    var idx_counter: i32 = 0;
    var tarjan_stack: std.ArrayList(usize) = .empty;
    defer tarjan_stack.deinit(gpa);

    const Frame = struct { v: usize, i: usize, entered: bool };
    var work: std.ArrayList(Frame) = .empty;
    defer work.deinit(gpa);

    var root: usize = 0;
    while (root < n) : (root += 1) {
        if (index[root] != UNDEF) continue;
        try work.append(gpa, .{ .v = root, .i = 0, .entered = false });

        while (work.items.len > 0) {
            const top_idx = work.items.len - 1;
            const v = work.items[top_idx].v;

            if (!work.items[top_idx].entered) {
                index[v] = idx_counter;
                lowlink[v] = idx_counter;
                idx_counter += 1;
                try tarjan_stack.append(gpa, v);
                on_stack[v] = true;
                work.items[top_idx].entered = true;
            }

            const adj = graph.adjacency[v];
            if (work.items[top_idx].i < adj.len) {
                const w_u32 = adj[work.items[top_idx].i];
                work.items[top_idx].i += 1;
                if (w_u32 >= n) continue;
                const w: usize = @intCast(w_u32);
                if (index[w] == UNDEF) {
                    try work.append(gpa, .{ .v = w, .i = 0, .entered = false });
                } else if (on_stack[w]) {
                    if (index[w] < lowlink[v]) lowlink[v] = index[w];
                }
                continue;
            }

            // All successors processed — check if v is an SCC root.
            if (lowlink[v] == index[v]) {
                var members: std.ArrayList(usize) = .empty;
                defer members.deinit(gpa);
                while (true) {
                    const w = tarjan_stack.pop().?;
                    on_stack[w] = false;
                    try members.append(gpa, w);
                    if (w == v) break;
                }
                if (members.items.len >= 2) {
                    for (members.items) |m| is_recursive[m] = true;
                }
            }

            _ = work.pop();
            if (work.items.len > 0) {
                const parent_idx = work.items.len - 1;
                const p = work.items[parent_idx].v;
                if (lowlink[v] < lowlink[p]) lowlink[p] = lowlink[v];
            }
        }
    }

    return is_recursive;
}

// ---- tests ----

test "SCC: self-recursion is detected" {
    const gpa = std.testing.allocator;
    const rows = try gpa.alloc([]const u32, 1);
    rows[0] = try gpa.dupe(u32, &[_]u32{0});
    var g: CallGraph = .{ .adjacency = rows };
    defer g.deinit(gpa);
    const rec = try detectRecursive(gpa, g);
    defer gpa.free(rec);
    try std.testing.expect(rec[0]);
}

test "SCC: mutual recursion is detected" {
    const gpa = std.testing.allocator;
    const rows = try gpa.alloc([]const u32, 2);
    rows[0] = try gpa.dupe(u32, &[_]u32{1});
    rows[1] = try gpa.dupe(u32, &[_]u32{0});
    var g: CallGraph = .{ .adjacency = rows };
    defer g.deinit(gpa);
    const rec = try detectRecursive(gpa, g);
    defer gpa.free(rec);
    try std.testing.expect(rec[0]);
    try std.testing.expect(rec[1]);
}

test "SCC: linear chain is not recursive" {
    const gpa = std.testing.allocator;
    const rows = try gpa.alloc([]const u32, 3);
    rows[0] = try gpa.dupe(u32, &[_]u32{1});
    rows[1] = try gpa.dupe(u32, &[_]u32{2});
    rows[2] = &.{};
    var g: CallGraph = .{ .adjacency = rows };
    defer g.deinit(gpa);
    const rec = try detectRecursive(gpa, g);
    defer gpa.free(rec);
    try std.testing.expect(!rec[0]);
    try std.testing.expect(!rec[1]);
    try std.testing.expect(!rec[2]);
}

test "SCC: three-node cycle is detected" {
    const gpa = std.testing.allocator;
    const rows = try gpa.alloc([]const u32, 3);
    rows[0] = try gpa.dupe(u32, &[_]u32{1});
    rows[1] = try gpa.dupe(u32, &[_]u32{2});
    rows[2] = try gpa.dupe(u32, &[_]u32{0});
    var g: CallGraph = .{ .adjacency = rows };
    defer g.deinit(gpa);
    const rec = try detectRecursive(gpa, g);
    defer gpa.free(rec);
    try std.testing.expect(rec[0]);
    try std.testing.expect(rec[1]);
    try std.testing.expect(rec[2]);
}
