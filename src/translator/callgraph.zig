//! Call graph of a WASM module and its strongly connected components.
//!
//! Udon has no call stack, so every function's parameters, locals and
//! temporaries live in fixed heap slots. That is only sound while a function
//! is active at most once; the translator therefore needs to know which
//! functions can be re-entered (the members of a call-graph cycle) so it can
//! save their frames around the calls that may re-enter them
//! (`docs/spec_call_return_conversion.md` §8).

const std = @import("std");
const wasm = @import("wasm");

const Instruction = wasm.Instruction;
const FuncType = wasm.types.FuncType;

pub const Info = struct {
    /// Component id per function index (imports included; each import is
    /// its own component).
    scc: []u32,
    /// The function is on a call-graph cycle (including a self call).
    recursive: []bool,
    /// Callees of function `f` are `edges[first[f]..first[f + 1]]`, one
    /// entry per call site (an indirect call site contributes one entry per
    /// function it can reach).
    first: []u32,
    edges: []Edge,

    pub const Edge = struct { callee: u32, direct: bool };

    pub fn deinit(self: *Info, gpa: std.mem.Allocator) void {
        gpa.free(self.scc);
        gpa.free(self.recursive);
        gpa.free(self.first);
        gpa.free(self.edges);
    }

    pub fn callees(self: *const Info, f: u32) []const Edge {
        return self.edges[self.first[f]..self.first[f + 1]];
    }

    /// A call from `caller` to `callee` can re-enter `caller` before it
    /// returns.
    pub fn mayReenter(self: *const Info, caller: u32, callee: u32) bool {
        return self.recursive[caller] and self.scc[caller] == self.scc[callee];
    }
};

fn sameType(a: FuncType, b: FuncType) bool {
    return std.mem.eql(wasm.types.ValType, a.params, b.params) and std.mem.eql(wasm.types.ValType, a.results, b.results);
}

const Builder = struct {
    gpa: std.mem.Allocator,
    mod: wasm.Module,
    num_imported: u32,
    table_funcs: []const u32,
    edges: std.ArrayList(Info.Edge) = .empty,

    fn typeOf(self: *const Builder, f: u32) FuncType {
        if (f >= self.num_imported) return self.mod.types_[self.mod.funcs[f - self.num_imported]];
        var i: u32 = 0;
        for (self.mod.imports) |imp| switch (imp.desc) {
            .func => |t| {
                if (i == f) return self.mod.types_[t];
                i += 1;
            },
            else => {},
        };
        unreachable;
    }

    fn collect(self: *Builder, body: []const Instruction) !void {
        for (body) |ins| switch (ins) {
            .call => |f| try self.edges.append(self.gpa, .{ .callee = f, .direct = true }),
            // An indirect call can reach any table entry of the same type.
            .call_indirect => |t| for (self.table_funcs) |f| {
                if (sameType(self.typeOf(f), self.mod.types_[t])) try self.edges.append(self.gpa, .{ .callee = f, .direct = false });
            },
            .block, .loop => |b| try self.collect(b.body),
            .if_ => |b| {
                try self.collect(b.then_body);
                if (b.else_body) |e| try self.collect(e);
            },
            else => {},
        };
    }
};

pub fn sameFuncType(a: FuncType, b: FuncType) bool {
    return sameType(a, b);
}

/// `table_funcs` lists the function indices placed in the function table by
/// element segments.
pub fn analyze(gpa: std.mem.Allocator, mod: wasm.Module, num_imported: u32, table_funcs: []const u32) !Info {
    const n: u32 = num_imported + @as(u32, @intCast(mod.codes.len));
    var b: Builder = .{ .gpa = gpa, .mod = mod, .num_imported = num_imported, .table_funcs = table_funcs };
    errdefer b.edges.deinit(gpa);
    const first = try gpa.alloc(u32, n + 1);
    errdefer gpa.free(first);
    @memset(first[0 .. num_imported + 1], 0);
    for (mod.codes, 0..) |code, i| {
        try b.collect(code.body);
        first[num_imported + i + 1] = @intCast(b.edges.items.len);
    }
    const scc = try gpa.alloc(u32, n);
    errdefer gpa.free(scc);
    const recursive = try gpa.alloc(bool, n);
    errdefer gpa.free(recursive);
    @memset(recursive, false);
    var info: Info = .{ .scc = scc, .recursive = recursive, .first = first, .edges = try b.edges.toOwnedSlice(gpa) };
    const edges = info.edges;
    for (0..n) |f| {
        for (info.callees(@intCast(f))) |e| if (e.callee == f) {
            info.recursive[f] = true;
        };
    }

    // Tarjan's algorithm with an explicit work stack.
    const unvisited = std.math.maxInt(u32);
    const index = try gpa.alloc(u32, n);
    defer gpa.free(index);
    const low = try gpa.alloc(u32, n);
    defer gpa.free(low);
    const on_stack = try gpa.alloc(bool, n);
    defer gpa.free(on_stack);
    @memset(index, unvisited);
    @memset(on_stack, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    const Frame = struct { v: u32, next: u32 };
    var work: std.ArrayList(Frame) = .empty;
    defer work.deinit(gpa);
    var counter: u32 = 0;
    var components: u32 = 0;

    for (0..n) |root| {
        if (index[root] != unvisited) continue;
        try work.append(gpa, .{ .v = @intCast(root), .next = first[root] });
        while (work.items.len != 0) {
            const top = &work.items[work.items.len - 1];
            const v = top.v;
            if (index[v] == unvisited) {
                index[v] = counter;
                low[v] = counter;
                counter += 1;
                try stack.append(gpa, v);
                on_stack[v] = true;
            }
            if (top.next < first[v + 1]) {
                const w = edges[top.next].callee;
                top.next += 1;
                if (index[w] == unvisited) {
                    try work.append(gpa, .{ .v = w, .next = first[w] });
                } else if (on_stack[w]) {
                    low[v] = @min(low[v], index[w]);
                }
                continue;
            }
            if (low[v] == index[v]) {
                var members: u32 = 0;
                while (true) {
                    const w = stack.pop().?;
                    on_stack[w] = false;
                    info.scc[w] = components;
                    members += 1;
                    if (w == v) break;
                }
                if (members > 1) {
                    for (info.scc, 0..) |c, f| if (c == components) {
                        info.recursive[f] = true;
                    };
                }
                components += 1;
            }
            _ = work.pop();
            if (work.items.len != 0) {
                const parent = work.items[work.items.len - 1].v;
                low[parent] = @min(low[parent], low[v]);
            }
        }
    }
    return info;
}

// ------------------------------- tests -------------------------------

const testing = std.testing;

fn moduleWithBodies(bodies: []const []const Instruction, codes: []wasm.module.Code, funcs: []u32, types: []const FuncType) wasm.Module {
    for (bodies, 0..) |b, i| {
        codes[i] = .{ .locals = &.{}, .body = b };
        funcs[i] = 0;
    }
    return .{ .types_ = types, .funcs = funcs, .codes = codes };
}

const void_type = [_]FuncType{.{ .params = &.{}, .results = &.{} }};

test "self recursion" {
    var codes: [1]wasm.module.Code = undefined;
    var funcs: [1]u32 = undefined;
    const mod = moduleWithBodies(&.{&.{.{ .call = 0 }}}, &codes, &funcs, &void_type);
    var info = try analyze(testing.allocator, mod, 0, &.{});
    defer info.deinit(testing.allocator);
    try testing.expect(info.recursive[0]);
    try testing.expect(info.mayReenter(0, 0));
    try testing.expectEqual(@as(usize, 1), info.callees(0).len);
    try testing.expect(info.callees(0)[0].direct);
}

test "mutual recursion shares a component; a leaf does not" {
    var codes: [3]wasm.module.Code = undefined;
    var funcs: [3]u32 = undefined;
    const mod = moduleWithBodies(&.{
        &.{ .{ .call = 1 }, .{ .call = 2 } },
        &.{.{ .call = 0 }},
        &.{},
    }, &codes, &funcs, &void_type);
    var info = try analyze(testing.allocator, mod, 0, &.{});
    defer info.deinit(testing.allocator);
    try testing.expect(info.recursive[0] and info.recursive[1] and !info.recursive[2]);
    try testing.expect(info.mayReenter(0, 1) and info.mayReenter(1, 0));
    try testing.expect(!info.mayReenter(0, 2));
}

test "a linear chain is not recursive" {
    var codes: [3]wasm.module.Code = undefined;
    var funcs: [3]u32 = undefined;
    const mod = moduleWithBodies(&.{ &.{.{ .call = 1 }}, &.{.{ .call = 2 }}, &.{} }, &codes, &funcs, &void_type);
    var info = try analyze(testing.allocator, mod, 0, &.{});
    defer info.deinit(testing.allocator);
    for (info.recursive) |r| try testing.expect(!r);
}

test "call_indirect reaches table functions of the same type only" {
    const types = [_]FuncType{
        .{ .params = &.{}, .results = &.{} },
        .{ .params = &.{.i32}, .results = &.{} },
    };
    var codes: [2]wasm.module.Code = undefined;
    var funcs: [2]u32 = undefined;
    // f0 (type 0) does call_indirect of type 0; the table holds f0 and f1.
    var mod = moduleWithBodies(&.{ &.{.{ .call_indirect = 0 }}, &.{} }, &codes, &funcs, &types);
    funcs[1] = 1;
    mod.funcs = &funcs;
    var info = try analyze(testing.allocator, mod, 0, &.{ 0, 1 });
    defer info.deinit(testing.allocator);
    try testing.expect(info.recursive[0]);
    try testing.expect(!info.recursive[1]);
}
