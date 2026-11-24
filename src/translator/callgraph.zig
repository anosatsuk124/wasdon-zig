//! Call graph analysis: strongly connected components and static frame layout.
//!
//! Udon has no stack frames, so every WASM local lives in a heap slot. Two
//! facts about the call graph let the translator keep that cheap:
//!
//!   * a function that cannot reach itself never needs its slots saved, so
//!     only calls inside one SCC spill a frame (`docs/spec_call_return_conversion.md`);
//!   * two functions that are never active at the same time can share
//!     slots, so frames are laid out like a static stack: a callee's frame
//!     starts above the frames of all of its possible callers.

const std = @import("std");

/// Result of `analyze`. Functions are numbered densely from 0.
pub const Sccs = struct {
    /// SCC id per function. Ids are assigned callee-first: every callee of a
    /// function outside its own SCC has a smaller id.
    id: []u32,
    /// Whether the function can (transitively) call itself.
    recursive: []bool,
    count: u32,
};

/// Tarjan's algorithm over `callees` (adjacency lists of function numbers).
pub fn analyze(gpa: std.mem.Allocator, callees: []const []const u32) !Sccs {
    const n = callees.len;
    var t: Tarjan = .{
        .gpa = gpa,
        .callees = callees,
        .index = try gpa.alloc(u32, n),
        .low = try gpa.alloc(u32, n),
        .on_stack = try gpa.alloc(bool, n),
        .id = try gpa.alloc(u32, n),
        .recursive = try gpa.alloc(bool, n),
    };
    defer gpa.free(t.index);
    defer gpa.free(t.low);
    defer gpa.free(t.on_stack);
    defer t.stack.deinit(gpa);
    @memset(t.index, unvisited);
    @memset(t.on_stack, false);
    @memset(t.recursive, false);
    for (0..n) |v| if (t.index[v] == unvisited) try t.visit(@intCast(v));
    return .{ .id = t.id, .recursive = t.recursive, .count = t.scc_count };
}

const unvisited = std.math.maxInt(u32);

const Tarjan = struct {
    gpa: std.mem.Allocator,
    callees: []const []const u32,
    index: []u32,
    low: []u32,
    on_stack: []bool,
    id: []u32,
    recursive: []bool,
    stack: std.ArrayList(u32) = .empty,
    next_index: u32 = 0,
    scc_count: u32 = 0,

    fn visit(self: *Tarjan, v: u32) !void {
        self.index[v] = self.next_index;
        self.low[v] = self.next_index;
        self.next_index += 1;
        try self.stack.append(self.gpa, v);
        self.on_stack[v] = true;
        for (self.callees[v]) |w| {
            if (w == v) self.recursive[v] = true;
            if (self.index[w] == unvisited) {
                try self.visit(w);
                self.low[v] = @min(self.low[v], self.low[w]);
            } else if (self.on_stack[w]) {
                self.low[v] = @min(self.low[v], self.index[w]);
            }
        }
        if (self.low[v] != self.index[v]) return;
        // v is the root of an SCC: its members are everything above it.
        var start = self.stack.items.len - 1;
        while (self.stack.items[start] != v) start -= 1;
        const members = self.stack.items[start..];
        for (members) |w| {
            self.on_stack[w] = false;
            self.id[w] = self.scc_count;
            if (members.len > 1) self.recursive[w] = true;
        }
        self.stack.shrinkRetainingCapacity(start);
        self.scc_count += 1;
    }
};

/// Static frame layout. `sizes[f][c]` is the number of slots function `f`
/// needs in slot class `c`; the result gives the first slot of each frame
/// and the total pool size per class.
pub fn Layout(comptime classes: usize) type {
    return struct {
        base: [][classes]u32,
        total: [classes]u32,
    };
}

pub fn layoutFrames(
    comptime classes: usize,
    gpa: std.mem.Allocator,
    callees: []const []const u32,
    sccs: Sccs,
    sizes: []const [classes]u32,
) !Layout(classes) {
    const n = callees.len;
    const base = try gpa.alloc([classes]u32, n);
    // Lowest slot each SCC may use: above every caller from another SCC.
    const floor = try gpa.alloc([classes]u32, sccs.count);
    defer gpa.free(floor);
    @memset(floor, @splat(0));
    var total: [classes]u32 = @splat(0);

    // Members of each SCC, grouped by counting sort on the SCC id.
    const order = try gpa.alloc(u32, n);
    defer gpa.free(order);
    const start = try gpa.alloc(u32, sccs.count + 1);
    defer gpa.free(start);
    @memset(start, 0);
    for (sccs.id) |id| start[id + 1] += 1;
    for (1..start.len) |i| start[i] += start[i - 1];
    const cursor = try gpa.dupe(u32, start[0..sccs.count]);
    defer gpa.free(cursor);
    for (sccs.id, 0..) |id, f| {
        order[cursor[id]] = @intCast(f);
        cursor[id] += 1;
    }

    // Callers have larger SCC ids than their callees, so walk ids downwards.
    var scc = sccs.count;
    while (scc > 0) {
        scc -= 1;
        var next = floor[scc];
        // Members of one SCC can be active together: stack them.
        for (order[start[scc]..start[scc + 1]]) |f| {
            base[f] = next;
            for (0..classes) |c| next[c] += sizes[f][c];
        }
        for (0..classes) |c| total[c] = @max(total[c], next[c]);
        for (order[start[scc]..start[scc + 1]]) |f| {
            for (callees[f]) |callee| {
                const cs = sccs.id[callee];
                if (cs == scc) continue;
                for (0..classes) |c| floor[cs][c] = @max(floor[cs][c], base[f][c] + sizes[f][c]);
            }
        }
    }
    return .{ .base = base, .total = total };
}

const testing = std.testing;

fn free(sccs: Sccs) void {
    testing.allocator.free(sccs.id);
    testing.allocator.free(sccs.recursive);
}

test "self and mutual recursion are detected, chains are not" {
    // 0 -> 1 -> 2 -> 1,  3 -> 3,  4 -> 0
    const g = [_][]const u32{ &.{1}, &.{2}, &.{1}, &.{3}, &.{0} };
    const s = try analyze(testing.allocator, &g);
    defer free(s);
    try testing.expectEqualSlices(bool, &.{ false, true, true, true, false }, s.recursive);
    try testing.expect(s.id[1] == s.id[2]);
    try testing.expect(s.id[0] > s.id[1] and s.id[4] > s.id[0]);
    try testing.expectEqual(@as(u32, 4), s.count);
}

test "frames of functions on one call chain do not overlap; siblings share" {
    // 0 calls 1 and 2; 1 calls 3; 2 calls 3.
    const g = [_][]const u32{ &.{ 1, 2 }, &.{3}, &.{3}, &.{} };
    const s = try analyze(testing.allocator, &g);
    defer free(s);
    const sizes = [_][1]u32{ .{2}, .{5}, .{3}, .{4} };
    const l = try layoutFrames(1, testing.allocator, &g, s, &sizes);
    defer testing.allocator.free(l.base);
    try testing.expectEqual(@as(u32, 0), l.base[0][0]);
    try testing.expectEqual(@as(u32, 2), l.base[1][0]);
    try testing.expectEqual(@as(u32, 2), l.base[2][0]); // shares with 1
    try testing.expectEqual(@as(u32, 7), l.base[3][0]); // above the larger caller
    try testing.expectEqual(@as(u32, 11), l.total[0]);
}

test "members of a recursive SCC get disjoint frames" {
    const g = [_][]const u32{ &.{1}, &.{0} };
    const s = try analyze(testing.allocator, &g);
    defer free(s);
    const sizes = [_][1]u32{ .{3}, .{4} };
    const l = try layoutFrames(1, testing.allocator, &g, s, &sizes);
    defer testing.allocator.free(l.base);
    try testing.expect(l.base[0][0] != l.base[1][0]);
    try testing.expectEqual(@as(u32, 7), l.total[0]);
}
