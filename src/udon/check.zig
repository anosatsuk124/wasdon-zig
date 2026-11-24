//! Static conformance checker for Udon Assembly (`docs/udon_specs.md`).
//!
//! Verifies a parsed program against everything the spec lets us decide
//! without running it:
//!
//!   * data section — names (§4.4), per-type literal restrictions (§4.7),
//!     `this` targets (§4.6), `.export` / `.sync` attributes (§4.8);
//!   * code section — label rules and address aliasing (§5.2), operand
//!     forms and jump targets (§6), exported labels (§5.3);
//!   * stack discipline — every `PUSH` group is consumed by the instruction
//!     that follows it, with the operand count the consumer needs, and no
//!     jump lands inside a group;
//!   * heap typing — each pushed variable's declared type matches what the
//!     `EXTERN` signature, `COPY`, `JUMP_IF_FALSE` or `JUMP_INDIRECT` reads
//!     or writes, which rules out the runtime "Cannot retrieve heap variable
//!     of type X as type Y" class of failures for primitives;
//!   * externs — each signature parses (§7.2) and, when a node list is
//!     supplied, names a node the VM actually ships (§7.4).

const std = @import("std");
const text = @import("text.zig");
const sig_mod = @import("sig.zig");

pub const NodeSet = std.StringHashMapUnmanaged(void);

/// Build a lookup set from a newline-separated node list (`docs/udon_nodes.txt`).
pub fn loadNodes(gpa: std.mem.Allocator, list: []const u8) !NodeSet {
    var set: NodeSet = .empty;
    errdefer set.deinit(gpa);
    var lines = std.mem.tokenizeAny(u8, list, "\r\n");
    while (lines.next()) |line| try set.put(gpa, line, {});
    return set;
}

pub const Issue = struct {
    line: u32,
    msg: []const u8,
};

pub const Options = struct {
    nodes: ?*const NodeSet = null,
};

pub const Report = struct {
    issues: []const Issue,
    /// Declared variables plus one anonymous string per distinct extern name.
    heap_slots: usize,
    extern_calls: usize,
    distinct_externs: usize,

    pub fn ok(self: Report) bool {
        return self.issues.len == 0;
    }
};

const primitives = [_][]const u8{
    "SystemBoolean", "SystemByte",   "SystemSByte", "SystemInt16",  "SystemUInt16", "SystemChar",
    "SystemInt32",   "SystemUInt32", "SystemInt64", "SystemUInt64", "SystemSingle", "SystemDouble",
};
const this_types = [_][]const u8{
    "UnityEngineGameObject", "UnityEngineTransform",                      "UnityEngineObject",
    "SystemObject",          "VRCUdonCommonInterfacesIUdonEventReceiver", "VRCUdonUdonBehaviour",
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn oneOf(s: []const u8, set: []const []const u8) bool {
    for (set) |x| if (eql(s, x)) return true;
    return false;
}

fn isPrimitive(ty: []const u8) bool {
    return oneOf(ty, &primitives);
}

/// Can a heap slot declared as `slot` supply (or receive) a value of type
/// `value`? Primitives must match exactly. Reference and struct types flow
/// through `SystemObject` slots and through `SystemInt32` slots, which the
/// translator uses as opaque object handles.
fn compatible(value: []const u8, slot: []const u8) bool {
    if (eql(value, slot)) return true;
    if (eql(value, "SystemObject") or eql(value, "T") or eql(slot, "SystemObject")) return true;
    if (isPrimitive(value)) return false;
    if (eql(value, "SystemArray") or eql(value, "TArray")) return std.mem.endsWith(u8, slot, "Array") or eql(slot, "SystemInt32");
    return !isPrimitive(slot) or eql(slot, "SystemInt32");
}

pub fn check(arena: std.mem.Allocator, prog: *const text.Program, options: Options) !Report {
    var c: Checker = .{ .arena = arena, .prog = prog, .options = options };
    try c.checkData();
    try c.checkLabels();
    try c.checkCode();
    return .{
        .issues = c.issues.items,
        .heap_slots = prog.vars.len + c.externs.count(),
        .extern_calls = c.extern_calls,
        .distinct_externs = c.externs.count(),
    };
}

const Checker = struct {
    arena: std.mem.Allocator,
    prog: *const text.Program,
    options: Options,
    issues: std.ArrayList(Issue) = .empty,
    externs: std.StringHashMapUnmanaged(void) = .empty,
    extern_calls: usize = 0,

    fn err(self: *Checker, line: u32, comptime fmt: []const u8, args: anytype) !void {
        try self.issues.append(self.arena, .{ .line = line, .msg = try std.fmt.allocPrint(self.arena, fmt, args) });
    }

    fn checkData(self: *Checker) !void {
        for (self.prog.dangling_attrs) |a| try self.err(a.line, "attribute names undeclared variable '{s}'", .{a.name});
        for (self.prog.vars) |v| {
            if (!text.isValidName(v.name)) try self.err(v.line, "invalid variable name '{s}'", .{v.name});
            if (v.ty.len == 0 or !std.ascii.isAlphabetic(v.ty[0])) try self.err(v.line, "invalid type name '{s}'", .{v.ty});
            if (v.sync) |mode| if (!oneOf(mode, &.{ "none", "linear", "smooth" }))
                try self.err(v.line, "invalid sync mode '{s}'", .{mode});
            try self.checkInit(v);
        }
    }

    fn checkInit(self: *Checker, v: text.DataVar) !void {
        const float_ty = eql(v.ty, "SystemSingle") or eql(v.ty, "SystemDouble");
        const int_ty = eql(v.ty, "SystemInt32") or eql(v.ty, "SystemUInt32");
        switch (v.init) {
            .null_ => {},
            .this => if (!oneOf(v.ty, &this_types)) try self.err(v.line, "'this' is not valid for type {s}", .{v.ty}),
            .string => if (!eql(v.ty, "SystemString")) try self.err(v.line, "string literal for non-string type {s}", .{v.ty}),
            .float => if (!float_ty) try self.err(v.line, "float literal for type {s}", .{v.ty}),
            .int => |i| {
                if (float_ty) return;
                if (!int_ty) return self.err(v.line, "type {s} must be initialised with null or this", .{v.ty});
                const max: u64 = if (i.hex or i.unsigned) std.math.maxInt(u32) else std.math.maxInt(i32);
                if (i.magnitude > max) try self.err(v.line, "integer literal out of range for {s}", .{v.ty});
                if (i.negative and (eql(v.ty, "SystemUInt32") or i.unsigned)) try self.err(v.line, "negative literal for unsigned value", .{});
            },
            .boolean, .char => try self.err(v.line, "type {s} must be initialised with null or this", .{v.ty}),
        }
    }

    fn checkLabels(self: *Checker) !void {
        const labels = self.prog.labels;
        var by_addr: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        var by_name: std.StringHashMapUnmanaged(void) = .empty;
        for (labels) |l| {
            if (!text.isValidName(l.name)) try self.err(l.line, "invalid label name '{s}'", .{l.name});
            if ((try by_name.getOrPut(self.arena, l.name)).found_existing) try self.err(l.line, "duplicate label '{s}'", .{l.name});
            const gop = try by_addr.getOrPut(self.arena, l.addr);
            if (gop.found_existing) {
                try self.err(l.line, "address aliasing: '{s}' and '{s}' share address 0x{X}", .{ gop.value_ptr.*, l.name, l.addr });
            } else gop.value_ptr.* = l.name;
            if (self.prog.instrAt(l.addr) == null) try self.err(l.line, "label '{s}' does not precede an instruction", .{l.name});
        }
        for (self.prog.exports) |e| if (!by_name.contains(e.name))
            try self.err(e.line, ".export names undefined label '{s}'", .{e.name});
    }

    fn varOf(self: *Checker, ins: text.Instr) !?text.DataVar {
        switch (ins.param) {
            .sym => |name| if (self.prog.findVar(name)) |i| return self.prog.vars[i],
            .int => |i| if (i < self.prog.vars.len) return self.prog.vars[i],
            else => {},
        }
        try self.err(ins.line, "{s} operand is not a declared variable", .{@tagName(ins.op)});
        return null;
    }

    /// Resolve a `JUMP` / `JUMP_IF_FALSE` operand to an address.
    fn jumpTarget(self: *Checker, ins: text.Instr) !?u32 {
        const addr = switch (ins.param) {
            .int => |a| a,
            .sym => |name| self.prog.labelAddr(name) orelse {
                try self.err(ins.line, "jump to undefined label '{s}'", .{name});
                return null;
            },
            else => {
                try self.err(ins.line, "bad jump operand", .{});
                return null;
            },
        };
        if (addr == 0xFFFFFFFC) return if (ins.op == .JUMP) null else addr;
        if (self.prog.instrAt(addr) == null) {
            try self.err(ins.line, "jump target 0x{X} is not an instruction boundary", .{addr});
            return null;
        }
        return addr;
    }

    fn checkCode(self: *Checker) !void {
        const instrs = self.prog.instrs;
        // Number of pushes outstanding when each instruction starts.
        const depth_before = try self.arena.alloc(u32, instrs.len);
        var targets: std.ArrayList(struct { addr: u32, line: u32 }) = .empty;
        var group: std.ArrayList(text.DataVar) = .empty;

        for (instrs, 0..) |ins, idx| {
            depth_before[idx] = @intCast(group.items.len);
            switch (ins.op) {
                .PUSH => {
                    if (try self.varOf(ins)) |v| try group.append(self.arena, v) else try group.append(self.arena, .{ .name = "?", .ty = "SystemObject", .init = .null_, .line = ins.line });
                    continue;
                },
                .NOP, .ANNOTATION => continue,
                .POP => {
                    if (group.pop() == null) try self.err(ins.line, "POP on an empty stack", .{});
                    continue;
                },
                .COPY => {
                    if (group.items.len != 2) {
                        try self.err(ins.line, "COPY needs exactly 2 pushed operands, found {d}", .{group.items.len});
                    } else if (!compatible(group.items[0].ty, group.items[1].ty)) {
                        try self.err(ins.line, "COPY from {s} '{s}' into {s} '{s}' changes the slot type", .{ group.items[0].ty, group.items[0].name, group.items[1].ty, group.items[1].name });
                    }
                },
                .JUMP_IF_FALSE => {
                    if (group.items.len != 1) {
                        try self.err(ins.line, "JUMP_IF_FALSE needs exactly 1 pushed operand, found {d}", .{group.items.len});
                    } else if (!eql(group.items[0].ty, "SystemBoolean")) {
                        try self.err(ins.line, "JUMP_IF_FALSE reads {s} '{s}', expected SystemBoolean", .{ group.items[0].ty, group.items[0].name });
                    }
                    if (try self.jumpTarget(ins)) |addr| try targets.append(self.arena, .{ .addr = addr, .line = ins.line });
                },
                .JUMP => {
                    if (group.items.len != 0) try self.err(ins.line, "JUMP with {d} operands left on the stack", .{group.items.len});
                    if (try self.jumpTarget(ins)) |addr| try targets.append(self.arena, .{ .addr = addr, .line = ins.line });
                },
                .JUMP_INDIRECT => {
                    if (group.items.len != 0) try self.err(ins.line, "JUMP_INDIRECT with {d} operands left on the stack", .{group.items.len});
                    if (try self.varOf(ins)) |v| if (!eql(v.ty, "SystemUInt32"))
                        try self.err(ins.line, "JUMP_INDIRECT reads {s} '{s}', expected SystemUInt32", .{ v.ty, v.name });
                },
                .EXTERN => try self.checkExtern(ins, group.items),
            }
            group.clearRetainingCapacity();
        }
        if (group.items.len != 0) try self.err(0, "{d} operands left on the stack at the end of the code section", .{group.items.len});
        if (instrs.len > 0) {
            const last = instrs[instrs.len - 1];
            if (last.op != .JUMP and last.op != .JUMP_INDIRECT) try self.err(last.line, "execution can run off the end of the code section", .{});
        }

        // Addresses reachable through labels and through return-address /
        // jump-table constants must also sit on a clean stack.
        for (self.prog.labels) |l| try targets.append(self.arena, .{ .addr = l.addr, .line = l.line });
        for (self.prog.vars) |v| {
            if (!eql(v.ty, "SystemUInt32") or v.init != .int or v.init.int.magnitude == 0) continue;
            if (!std.mem.startsWith(u8, v.name, "__ra_")) continue;
            const addr: u32 = @intCast(v.init.int.magnitude);
            if (self.prog.instrAt(addr) == null) {
                try self.err(v.line, "return address '{s}' = 0x{X} is not an instruction boundary", .{ v.name, addr });
            } else try targets.append(self.arena, .{ .addr = addr, .line = v.line });
        }
        for (targets.items) |t| {
            const idx = self.prog.instrAt(t.addr) orelse continue;
            if (depth_before[idx] != 0) try self.err(t.line, "jump target 0x{X} lies inside a PUSH group", .{t.addr});
        }
    }

    fn checkExtern(self: *Checker, ins: text.Instr, group: []const text.DataVar) !void {
        const name = switch (ins.param) {
            .string => |s| s,
            else => return self.err(ins.line, "EXTERN operand must be a string literal", .{}),
        };
        self.extern_calls += 1;
        try self.externs.put(self.arena, name, {});
        const sig = sig_mod.parse(name) orelse return self.err(ins.line, "malformed extern signature \"{s}\"", .{name});
        if (self.options.nodes) |nodes| if (!nodes.contains(name))
            try self.err(ins.line, "extern \"{s}\" is not in the Udon node list", .{name});

        const fixed = sig.nargs + @intFromBool(sig.returnsValue());
        const has_this = group.len == fixed + 1 and sig.isInstance() != false;
        if (group.len != fixed + @intFromBool(has_this) or (sig.isInstance() == true and !has_this))
            return self.err(ins.line, "extern \"{s}\" consumes {d}{s} operands, found {d}", .{ name, fixed, if (sig.isInstance() == false) "" else " (+1 for this)", group.len });

        var operands = group;
        if (has_this) {
            if (!compatible(sig.receiver, operands[0].ty))
                try self.err(ins.line, "extern \"{s}\": receiver '{s}' is {s}", .{ name, operands[0].name, operands[0].ty });
            operands = operands[1..];
        }
        for (sig.args(), operands[0..sig.nargs], 0..) |arg, v, i| if (!compatible(arg.ty, v.ty))
            try self.err(ins.line, "extern \"{s}\": argument {d} '{s}' is {s}, expected {s}", .{ name, i, v.name, v.ty, arg.ty });
        if (sig.returnsValue()) {
            const v = operands[sig.nargs];
            if (!compatible(sig.ret, v.ty))
                try self.err(ins.line, "extern \"{s}\": result slot '{s}' is {s}, expected {s}", .{ name, v.name, v.ty, sig.ret });
        }
    }
};

const testing = std.testing;

fn issuesFor(arena: std.mem.Allocator, src: []const u8) ![]const Issue {
    var diag: text.Diag = .{};
    const prog = try text.parse(arena, src, &diag);
    return (try check(arena, &prog, .{})).issues;
}

fn expectIssue(src: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const issues = try issuesFor(arena.allocator(), src);
    for (issues) |i| if (std.mem.indexOf(u8, i.msg, needle) != null) return;
    for (issues) |i| std.debug.print("issue: line {d}: {s}\n", .{ i.line, i.msg });
    return error.ExpectedIssueNotReported;
}

test "a well-formed program has no issues" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const issues = try issuesFor(arena.allocator(),
        \\.data_start
        \\    a: %SystemInt32, 0x80000000
        \\    b: %SystemInt32, -5
        \\    ok: %SystemBoolean, null
        \\    self: %UnityEngineTransform, this
        \\    pos: %SystemInt32, 0
        \\    ret: %SystemUInt32, 4294967295u
        \\    msg: %SystemString, "hi"
        \\.data_end
        \\.code_start
        \\    .export _start
        \\    _start:
        \\        PUSH, a
        \\        PUSH, b
        \\        PUSH, ok
        \\        EXTERN, "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean"
        \\        PUSH, ok
        \\        JUMP_IF_FALSE, 0x0000005C
        \\        PUSH, self
        \\        PUSH, pos
        \\        EXTERN, "UnityEngineTransform.__get_position__UnityEngineVector3"
        \\        PUSH, a
        \\        PUSH, b
        \\        COPY
        \\        PUSH, msg
        \\        EXTERN, "UnityEngineDebug.__Log__SystemObject__SystemVoid"
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    );
    for (issues) |i| std.debug.print("unexpected issue: line {d}: {s}\n", .{ i.line, i.msg });
    try testing.expectEqual(@as(usize, 0), issues.len);
}

test "literal restrictions (§4.7)" {
    try expectIssue(".data_start\n x: %SystemInt32, -2147483648\n.data_end\n", "out of range");
    try expectIssue(".data_start\n x: %SystemUInt32, 4294967295\n.data_end\n", "out of range");
    try expectIssue(".data_start\n x: %SystemInt64, 1\n.data_end\n", "null or this");
    try expectIssue(".data_start\n x: %SystemBoolean, true\n.data_end\n", "null or this");
    try expectIssue(".data_start\n x: %SystemInt32, this\n.data_end\n", "'this' is not valid");
    try expectIssue(".data_start\n x: %SystemInt32, \"s\"\n.data_end\n", "string literal");
    try expectIssue(".data_start\n .sync x, fast\n x: %SystemInt32, 0\n.data_end\n", "sync mode");
    try expectIssue(".data_start\n .export y\n x: %SystemInt32, 0\n.data_end\n", "undeclared variable");
    try expectIssue(".data_start\n 1x: %SystemInt32, 0\n.data_end\n", "invalid variable name");
}

test "label rules (§5.2, §5.3)" {
    try expectIssue(".code_start\n a:\n b:\n JUMP, 0xFFFFFFFC\n.code_end\n", "address aliasing");
    try expectIssue(".code_start\n JUMP, 0xFFFFFFFC\n a:\n.code_end\n", "does not precede");
    try expectIssue(".code_start\n .export _start\n JUMP, 0xFFFFFFFC\n.code_end\n", "undefined label");
    try expectIssue(".code_start\n JUMP, 0x00000004\n.code_end\n", "not an instruction boundary");
    try expectIssue(".code_start\n NOP\n.code_end\n", "run off the end");
}

test "stack discipline" {
    const data = ".data_start\n a: %SystemInt32, 0\n b: %SystemBoolean, null\n.data_end\n";
    try expectIssue(data ++ ".code_start\n PUSH, a\n COPY\n JUMP, 0xFFFFFFFC\n.code_end\n", "COPY needs exactly 2");
    try expectIssue(data ++ ".code_start\n PUSH, a\n JUMP, 0xFFFFFFFC\n.code_end\n", "operands left on the stack");
    try expectIssue(data ++ ".code_start\n PUSH, nope\n PUSH, a\n COPY\n JUMP, 0xFFFFFFFC\n.code_end\n", "not a declared variable");
    try expectIssue(data ++ ".code_start\n PUSH, a\n PUSH, a\n COPY\n JUMP, 0x00000008\n.code_end\n", "inside a PUSH group");
    try expectIssue(data ++ ".code_start\n PUSH, a\n PUSH, b\n EXTERN, \"SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean\"\n JUMP, 0xFFFFFFFC\n.code_end\n", "consumes 3 operands, found 2");
}

test "heap typing" {
    const data = ".data_start\n a: %SystemInt32, 0\n u: %SystemUInt32, 0\n b: %SystemBoolean, null\n l: %SystemInt64, null\n.data_end\n";
    try expectIssue(data ++ ".code_start\n PUSH, a\n JUMP_IF_FALSE, 0xFFFFFFFC\n JUMP, 0xFFFFFFFC\n.code_end\n", "expected SystemBoolean");
    try expectIssue(data ++ ".code_start\n JUMP_INDIRECT, a\n.code_end\n", "expected SystemUInt32");
    try expectIssue(data ++ ".code_start\n PUSH, a\n PUSH, l\n COPY\n JUMP, 0xFFFFFFFC\n.code_end\n", "changes the slot type");
    try expectIssue(data ++ ".code_start\n PUSH, a\n PUSH, u\n PUSH, b\n EXTERN, \"SystemUInt32.__op_LessThan__SystemUInt32_SystemUInt32__SystemBoolean\"\n JUMP, 0xFFFFFFFC\n.code_end\n", "argument 0 'a' is SystemInt32, expected SystemUInt32");
    try expectIssue(data ++ ".code_start\n PUSH, a\n PUSH, a\n PUSH, a\n EXTERN, \"SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean\"\n JUMP, 0xFFFFFFFC\n.code_end\n", "result slot 'a' is SystemInt32, expected SystemBoolean");
}

test "extern names are checked against the node list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nodes = try loadNodes(a, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32\n");
    var diag: text.Diag = .{};
    const prog = try text.parse(a,
        \\.data_start
        \\ a: %SystemUInt32, 0
        \\.data_end
        \\.code_start
        \\ PUSH, a
        \\ PUSH, a
        \\ PUSH, a
        \\ EXTERN, "SystemUInt32.__op_Modulus__SystemUInt32_SystemUInt32__SystemUInt32"
        \\ JUMP, 0xFFFFFFFC
        \\.code_end
    , &diag);
    const report = try check(a, &prog, .{ .nodes = &nodes });
    try testing.expectEqual(@as(usize, 1), report.issues.len);
    try testing.expect(std.mem.indexOf(u8, report.issues[0].msg, "not in the Udon node list") != null);
    try testing.expectEqual(@as(usize, 2), report.heap_slots);
}
