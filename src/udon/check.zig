//! Udon Assembly conformance checker.
//!
//! Validates a parsed program against `docs/udon_specs.md` and the node
//! list, the way the real assembler and VM loader would reject it — plus the
//! stricter invariants translated code is expected to keep (balanced stack,
//! type-stable slots). The tests run it over everything the translator
//! emits; `wasdon-zig check` exposes it for hand-written assembly.
//!
//! What it checks, by spec section:
//!   §2     section structure (via the parser's recorded issues)
//!   §4.4   variable and label name syntax, duplicate names
//!   §4.6–7 per-type literal restrictions, `this` targets
//!   §4.8   `.export` / `.sync` refer to declared variables
//!   §5.2   no two labels at one address; no label past the last instruction
//!   §5.3   exported labels exist; `_`-prefixed ones are standard events
//!   §6     parameter kinds, jump targets on instruction boundaries
//!   §6.2   stack discipline: every consumer finds exactly its operands
//!   §7     every EXTERN names a node that exists, with matching arity and
//!          primitive argument types
//!   §9.3   heap size within the VM's hard limit

const std = @import("std");
const program = @import("program.zig");
const nodes = @import("nodes.zig");

const Program = program.Program;

/// The largest heap `UdonHeap` will allocate; larger requests are clamped.
pub const max_heap_size: u32 = 1 << 20;
/// The heap the stock `UdonAssemblyProgramAsset` assembles with.
pub const default_heap_size: u32 = 512;

pub const Finding = struct { line: u32, message: []const u8 };

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    errors: []Finding = &.{},
    heap_size: u32 = 0,
    named_vars: u32 = 0,
    instructions: u32 = 0,
    externs: u32 = 0,
    unique_externs: u32 = 0,
    code_bytes: u32 = 0,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
    }

    pub fn ok(self: *const Report) bool {
        return self.errors.len == 0;
    }

    pub fn write(self: *const Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.errors) |e| try w.print("line {d}: {s}\n", .{ e.line, e.message });
    }
};

/// Value types whose slots the translator keeps at one type for life. A
/// string is not one of them: it is an object, and like any object it may
/// sit in an `Int32` slot as a handle (`docs/spec_host_import_conversion.md`
/// §4).
const primitive_types = [_][]const u8{
    "SystemBoolean", "SystemByte",   "SystemSByte", "SystemInt16",  "SystemUInt16", "SystemChar",
    "SystemInt32",   "SystemUInt32", "SystemInt64", "SystemUInt64", "SystemSingle", "SystemDouble",
};

fn isPrimitive(t: []const u8) bool {
    for (primitive_types) |p| if (std.mem.eql(u8, t, p)) return true;
    return false;
}

/// §4.4: first character a letter or `_`; the rest letters, digits, `_`,
/// `[`, `]`, `<`, `>`.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '[' or c == ']' or c == '<' or c == '>')) return false;
    }
    return true;
}

const Ctx = struct {
    a: std.mem.Allocator,
    prog: *const Program,
    errors: std.ArrayList(Finding) = .empty,

    fn err(self: *Ctx, line: u32, comptime fmt: []const u8, args: anytype) !void {
        // A broken program can repeat one mistake thousands of times.
        if (self.errors.items.len >= 200) return;
        try self.errors.append(self.a, .{ .line = line, .message = try std.fmt.allocPrint(self.a, fmt, args) });
    }

    fn declaredType(self: *const Ctx, heap: u32) []const u8 {
        return self.prog.vars[heap].type_name;
    }
};

pub fn check(gpa: std.mem.Allocator, prog: *const Program) std.mem.Allocator.Error!Report {
    var report: Report = .{ .arena = .init(gpa) };
    errdefer report.arena.deinit();
    var ctx: Ctx = .{ .a = report.arena.allocator(), .prog = prog };

    for (prog.issues) |i| try ctx.err(i.line, "{s}", .{i.message});
    try checkVars(&ctx);
    try checkLabels(&ctx);
    try checkCode(&ctx, &report);

    report.heap_size = prog.heapSize();
    report.named_vars = prog.named_count;
    report.code_bytes = prog.code_size;
    report.instructions = @intCast(prog.code.len);
    if (prog.declared_heap_size) |declared| {
        if (declared != report.heap_size)
            try ctx.err(0, "the heap-size comment says {d} slots but the program needs {d}", .{ declared, report.heap_size });
    }
    if (report.heap_size > max_heap_size)
        try ctx.err(0, "program needs {d} heap slots; the Udon VM caps the heap at {d}", .{ report.heap_size, max_heap_size });
    report.errors = try ctx.errors.toOwnedSlice(ctx.a);
    return report;
}

fn checkVars(ctx: *Ctx) !void {
    for (ctx.prog.vars[0..ctx.prog.named_count]) |v| {
        if (!isValidName(v.name)) try ctx.err(v.line, "invalid variable name '{s}'", .{v.name});
        if (!nodes.isType(v.type_name)) try ctx.err(v.line, "unknown Udon type '{s}'", .{v.type_name});
        try checkLiteral(ctx, v);
    }
}

fn checkLiteral(ctx: *Ctx, v: program.Var) !void {
    const t = v.type_name;
    const eql = std.mem.eql;
    switch (v.init) {
        .null_ => {},
        .this => if (!nodes.isThisTarget(t)) try ctx.err(v.line, "'{s}': `this` is not a valid initial value for {s}", .{ v.name, t }),
        .int => |i| {
            if (eql(u8, t, "SystemInt32")) {
                // The assembler parses sign and magnitude separately, so the
                // decimal spelling of Int32.MinValue overflows (§4.7).
                const spelled_hex = std.mem.indexOfAny(u8, v.init_text, "xX") != null;
                if (i < std.math.minInt(i32) or i > std.math.maxInt(i32) or (i == std.math.minInt(i32) and !spelled_hex))
                    try ctx.err(v.line, "'{s}': {s} does not fit SystemInt32 (write Int32.MinValue as 0x80000000)", .{ v.name, v.init_text });
            } else if (eql(u8, t, "SystemUInt32")) {
                if (i < 0 or i > std.math.maxInt(i32))
                    try ctx.err(v.line, "'{s}': {s} needs the `u` suffix to be a SystemUInt32", .{ v.name, v.init_text });
            } else if (!eql(u8, t, "SystemSingle") and !eql(u8, t, "SystemDouble")) {
                try ctx.err(v.line, "'{s}': {s} cannot be initialized with a number (only null{s})", .{ v.name, t, if (nodes.isThisTarget(t)) " or this" else "" });
            }
        },
        .uint => |u| {
            if (!eql(u8, t, "SystemInt32") and !eql(u8, t, "SystemUInt32")) {
                try ctx.err(v.line, "'{s}': unsigned literal on a {s}", .{ v.name, t });
            } else if (u > std.math.maxInt(u32)) {
                try ctx.err(v.line, "'{s}': {s} does not fit 32 bits", .{ v.name, v.init_text });
            }
        },
        .float => if (!eql(u8, t, "SystemSingle") and !eql(u8, t, "SystemDouble"))
            try ctx.err(v.line, "'{s}': floating-point literal on a {s}", .{ v.name, t }),
        .string => if (!eql(u8, t, "SystemString"))
            try ctx.err(v.line, "'{s}': string literal on a {s}", .{ v.name, t }),
        .boolean => try ctx.err(v.line, "'{s}': the assembler cannot initialize a variable to true/false", .{v.name}),
        .char => if (!eql(u8, t, "SystemChar"))
            try ctx.err(v.line, "'{s}': character literal on a {s}", .{ v.name, t }),
    }
}

fn checkLabels(ctx: *Ctx) !void {
    var seen: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    for (ctx.prog.labels) |l| {
        if (!isValidName(l.name)) try ctx.err(l.line, "invalid label name '{s}'", .{l.name});
        const gop = try seen.getOrPut(ctx.a, l.addr);
        if (gop.found_existing) {
            try ctx.err(l.line, "address aliasing: labels '{s}' and '{s}' share address 0x{X:0>8}", .{ gop.value_ptr.*, l.name, l.addr });
        } else gop.value_ptr.* = l.name;
        if (l.addr >= ctx.prog.code_size) try ctx.err(l.line, "label '{s}' has no instruction after it", .{l.name});
        if (l.is_export and l.name.len > 0 and l.name[0] == '_' and !nodes.isStandardEvent(l.name))
            try ctx.err(l.line, "exported label '{s}' starts with '_' but is not a standard Udon event", .{l.name});
    }
}

fn checkCode(ctx: *Ctx, report: *Report) !void {
    const prog = ctx.prog;
    const code = prog.code;

    // Instruction boundaries, and the addresses control can arrive at other
    // than by falling through: labels, jump operands, and code addresses
    // held in data (return-address constants, function-table entries).
    const words = prog.code_size / 4;
    const is_start = try ctx.a.alloc(bool, words + 1);
    const is_target = try ctx.a.alloc(bool, words + 1);
    @memset(is_start, false);
    @memset(is_target, false);
    for (code) |ins| is_start[ins.addr / 4] = true;
    for (prog.labels) |l| if (l.addr <= prog.code_size) {
        is_target[l.addr / 4] = true;
    };
    for (try returnAddressConstants(ctx), 0..) |reaches, h| {
        if (!reaches) continue;
        const x: u64 = switch (prog.vars[h].init) {
            .int => |i| if (i >= 0) @intCast(i) else continue,
            .uint => |u| u,
            else => continue,
        };
        if (x == program.halt_address or x == 0) continue;
        if (x % 4 != 0 or x >= prog.code_size or !is_start[@intCast(x / 4)]) {
            try ctx.err(prog.vars[h].line, "'{s}' reaches JUMP_INDIRECT but {d} is not an instruction address", .{ prog.vars[h].name, x });
        } else is_target[@intCast(x / 4)] = true;
    }
    for (code) |ins| {
        if ((ins.op == .jump or ins.op == .jump_if_false) and ins.param == .address) {
            const t = ins.param.address;
            if (t == program.halt_address) continue;
            if (t % 4 != 0 or t >= prog.code_size or !is_start[t / 4]) {
                try ctx.err(ins.line, "{s} target 0x{X:0>8} is not an instruction address", .{ ins.op.mnemonic(), t });
            } else is_target[t / 4] = true;
        }
    }

    var unique: std.AutoHashMapUnmanaged(u32, void) = .empty;
    // Heap indices pushed and not yet consumed.
    var stack: std.ArrayList(u32) = .empty;
    for (code, 0..) |ins, idx| {
        if (is_target[ins.addr / 4] and stack.items.len != 0) {
            try ctx.err(ins.line, "{d} value(s) left on the stack at a jump target", .{stack.items.len});
            stack.clearRetainingCapacity();
        }
        if (ins.param == .unresolved) {
            try ctx.err(ins.line, "undefined symbol '{s}'", .{ins.param.unresolved});
            stack.clearRetainingCapacity();
            continue;
        }
        const wants_heap = switch (ins.op) {
            .push, .extern_, .jump_indirect => true,
            else => false,
        };
        if (wants_heap and ins.param != .heap) {
            try ctx.err(ins.line, "{s} needs a variable (or string literal) parameter", .{ins.op.mnemonic()});
            continue;
        }
        switch (ins.op) {
            .nop, .annotation => {},
            .push => try stack.append(ctx.a, ins.param.heap),
            .pop => {
                if (stack.items.len == 0) try ctx.err(ins.line, "POP with nothing pushed in this block", .{}) else _ = stack.pop();
            },
            .copy => {
                // `PUSH x; COPY; JUMP_INDIRECT x` pops a return address a
                // caller parked on the stack (see `.jump`).
                const pops_return = stack.items.len == 1 and idx + 1 < code.len and code[idx + 1].op == .jump_indirect and
                    code[idx + 1].param == .heap and code[idx + 1].param.heap == stack.items[0];
                if (pops_return) {
                    // Checked as a JUMP_INDIRECT operand below.
                } else if (stack.items.len != 2) {
                    try ctx.err(ins.line, "COPY needs exactly 2 pushed operands, found {d}", .{stack.items.len});
                } else {
                    const src = ctx.declaredType(stack.items[0]);
                    const dst = ctx.declaredType(stack.items[1]);
                    if (isPrimitive(src) and isPrimitive(dst) and !std.mem.eql(u8, src, dst))
                        try ctx.err(ins.line, "COPY retypes a {s} slot ('{s}') to {s}", .{ dst, prog.vars[stack.items[1]].name, src });
                }
                stack.clearRetainingCapacity();
            },
            .jump_if_false => {
                if (stack.items.len != 1) {
                    try ctx.err(ins.line, "JUMP_IF_FALSE needs exactly 1 pushed operand, found {d}", .{stack.items.len});
                } else if (!std.mem.eql(u8, ctx.declaredType(stack.items[0]), "SystemBoolean")) {
                    try ctx.err(ins.line, "JUMP_IF_FALSE reads '{s}', which is {s}, not SystemBoolean", .{
                        prog.vars[stack.items[0]].name, ctx.declaredType(stack.items[0]),
                    });
                }
                stack.clearRetainingCapacity();
            },
            .jump => {
                // One `SystemUInt32` left standing is a call: the return
                // address, parked for the callee to pop.
                const parks_return = stack.items.len == 1 and std.mem.eql(u8, ctx.declaredType(stack.items[0]), "SystemUInt32");
                if (stack.items.len != 0 and !parks_return) try ctx.err(ins.line, "JUMP with {d} value(s) left on the stack", .{stack.items.len});
                stack.clearRetainingCapacity();
            },
            .jump_indirect => {
                if (stack.items.len != 0) try ctx.err(ins.line, "JUMP_INDIRECT with {d} value(s) left on the stack", .{stack.items.len});
                if (!std.mem.eql(u8, ctx.declaredType(ins.param.heap), "SystemUInt32"))
                    try ctx.err(ins.line, "JUMP_INDIRECT reads '{s}', which is {s}, not SystemUInt32", .{
                        prog.vars[ins.param.heap].name, ctx.declaredType(ins.param.heap),
                    });
                stack.clearRetainingCapacity();
            },
            .extern_ => {
                report.externs += 1;
                try unique.put(ctx.a, ins.param.heap, {});
                try checkExtern(ctx, ins, stack.items);
                stack.clearRetainingCapacity();
            },
        }
        const falls_off_end = idx + 1 == code.len and ins.op != .jump and ins.op != .jump_indirect;
        if (falls_off_end) try ctx.err(ins.line, "execution can run past the last instruction", .{});
    }
    report.unique_externs = unique.count();
}

/// For every heap variable: can its value flow, through `COPY` chains,
/// into a variable some `JUMP_INDIRECT` reads? Those hold return addresses.
/// (Function-table entries travel through a `uint[]` and are not tracked;
/// the emulator validates them when they are jumped to.)
fn returnAddressConstants(ctx: *Ctx) ![]const bool {
    const code = ctx.prog.code;
    const reaches = try ctx.a.alloc(bool, ctx.prog.vars.len);
    @memset(reaches, false);
    const Edge = struct { src: u32, dst: u32 };
    var edges: std.ArrayList(Edge) = .empty;
    for (code, 0..) |ins, i| {
        if (ins.op == .jump_indirect and ins.param == .heap) reaches[ins.param.heap] = true;
        // A value parked on the stack at a JUMP is popped into a
        // JUMP_INDIRECT operand by the callee.
        if (ins.op == .jump and i >= 1 and code[i - 1].op == .push and code[i - 1].param == .heap and
            (i < 2 or code[i - 2].op != .push))
            reaches[code[i - 1].param.heap] = true;
        if (ins.op == .copy and i >= 2 and code[i - 1].op == .push and code[i - 2].op == .push and
            code[i - 1].param == .heap and code[i - 2].param == .heap)
            try edges.append(ctx.a, .{ .src = code[i - 2].param.heap, .dst = code[i - 1].param.heap });
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (edges.items) |e| if (reaches[e.dst] and !reaches[e.src]) {
            reaches[e.src] = true;
            changed = true;
        };
    }
    return reaches;
}

fn checkExtern(ctx: *Ctx, ins: program.Instr, pushed: []const u32) !void {
    const v = ctx.prog.vars[ins.param.heap];
    const text = switch (v.init) {
        .string => |s| s,
        else => return ctx.err(ins.line, "EXTERN operand '{s}' is not a string", .{v.name}),
    };
    if (!nodes.exists(text)) return ctx.err(ins.line, "EXTERN \"{s}\" is not in the Udon node list", .{text});
    const sig = nodes.parseSignature(text) orelse return ctx.err(ins.line, "EXTERN \"{s}\" is not a method signature", .{text});
    if (sig.isGeneric()) return;

    const n = sig.staticParamCount();
    const has_this = pushed.len == n + 1 and !sig.isKnownStatic();
    if (pushed.len != n and !has_this)
        return ctx.err(ins.line, "EXTERN \"{s}\" takes {d} operand(s){s}, {d} pushed", .{
            text, n, if (sig.isKnownStatic()) "" else " (one more for an instance call)", pushed.len,
        });

    const args = pushed[@intFromBool(has_this)..];
    for (sig.args(), args[0..sig.args().len], 0..) |want, got, i| {
        const have = ctx.declaredType(got);
        if (isPrimitive(want.type_name) and isPrimitive(have) and !std.mem.eql(u8, want.type_name, have))
            try ctx.err(ins.line, "EXTERN \"{s}\" argument {d} is {s} but '{s}' is declared {s}", .{
                text, i, want.type_name, ctx.prog.vars[got].name, have,
            });
    }
    if (sig.returnsValue()) {
        const got = args[args.len - 1];
        const have = ctx.declaredType(got);
        if (isPrimitive(sig.ret) and isPrimitive(have) and !std.mem.eql(u8, sig.ret, have))
            try ctx.err(ins.line, "EXTERN \"{s}\" returns {s} into '{s}', which is declared {s}", .{
                text, sig.ret, ctx.prog.vars[got].name, have,
            });
    }
}

// ------------------------------- tests -------------------------------

const testing = std.testing;

fn expectClean(src: []const u8) !void {
    var prog = try program.parse(testing.allocator, src, null);
    defer prog.deinit();
    var r = try check(testing.allocator, &prog);
    defer r.deinit();
    if (!r.ok()) {
        for (r.errors) |e| std.debug.print("line {d}: {s}\n", .{ e.line, e.message });
        return error.TestUnexpectedResult;
    }
}

fn expectError(src: []const u8, needle: []const u8) !void {
    var prog = try program.parse(testing.allocator, src, null);
    defer prog.deinit();
    var r = try check(testing.allocator, &prog);
    defer r.deinit();
    for (r.errors) |e| if (std.mem.indexOf(u8, e.message, needle) != null) return;
    std.debug.print("expected an error containing \"{s}\"; got {d} error(s)\n", .{ needle, r.errors.len });
    for (r.errors) |e| std.debug.print("  line {d}: {s}\n", .{ e.line, e.message });
    return error.TestUnexpectedResult;
}

fn wrapCode(comptime data: []const u8, comptime code: []const u8) []const u8 {
    return ".data_start\n" ++ data ++ "\n.data_end\n.code_start\n" ++ code ++ "\n.code_end\n";
}

test "spec example 11.1 is clean" {
    try expectClean(wrapCode(
        \\    message: %SystemString, "Hello, world!"
    ,
        \\    .export _start
        \\    _start:
        \\        PUSH, message
        \\        EXTERN, "UnityEngineDebug.__Log__SystemObject__SystemVoid"
        \\        JUMP, 0xFFFFFFFC
    ));
}

test "names" {
    try testing.expect(isValidName("__this_is_a_variable[][]__>>>"));
    try testing.expect(isValidName("_Number<0>"));
    try testing.expect(!isValidName("222x"));
    try testing.expect(!isValidName("$abc"));
    try testing.expect(!isValidName("a.b"));
}

test "literal restrictions per type" {
    try expectError(wrapCode("x: %SystemInt64, 5", "JUMP, 0xFFFFFFFC"), "cannot be initialized with a number");
    try expectError(wrapCode("x: %SystemByte, 0", "JUMP, 0xFFFFFFFC"), "cannot be initialized with a number");
    try expectError(wrapCode("x: %SystemBoolean, true", "JUMP, 0xFFFFFFFC"), "true/false");
    try expectError(wrapCode("x: %SystemInt32, -2147483648", "JUMP, 0xFFFFFFFC"), "0x80000000");
    try expectError(wrapCode("x: %SystemUInt32, 4294967295", "JUMP, 0xFFFFFFFC"), "`u` suffix");
    try expectError(wrapCode("x: %SystemObject, this", "JUMP, 0xFFFFFFFC"), "`this` is not a valid");
    try expectError(wrapCode("x: %SystemInt32, \"s\"", "JUMP, 0xFFFFFFFC"), "string literal");
    try expectError(wrapCode("x: %NoSuchType, null", "JUMP, 0xFFFFFFFC"), "unknown Udon type");
    try expectClean(wrapCode(
        \\x: %SystemInt32, 0x80000000
        \\y: %SystemUInt32, 4294967295u
        \\z: %SystemDouble, 1.5
        \\t: %UnityEngineTransform, this
        \\b: %SystemBoolean, null
    , "JUMP, 0xFFFFFFFC"));
}

test "label aliasing and dangling labels" {
    try expectError(wrapCode("", "a:\nb:\nJUMP, 0xFFFFFFFC"), "address aliasing");
    try expectError(wrapCode("", "JUMP, 0xFFFFFFFC\nend:"), "no instruction after it");
}

test "exported labels" {
    try expectError(wrapCode("", ".export _notAnEvent\n_notAnEvent:\nJUMP, 0xFFFFFFFC"), "not a standard Udon event");
    try expectError(wrapCode("", ".export Missing\nJUMP, 0xFFFFFFFC"), "undefined label");
    try expectClean(wrapCode("", ".export Custom\nCustom:\nJUMP, 0xFFFFFFFC"));
}

test "jump targets must be instruction boundaries" {
    try expectError(wrapCode("x: %SystemInt32, 0", "PUSH, x\nPOP\nJUMP, 0x00000004"), "not an instruction address");
    try expectError(wrapCode("", "JUMP, 0x00000100"), "not an instruction address");
}

test "externs must exist and receive the right operands" {
    try expectError(wrapCode("a: %SystemInt32, 0",
        \\PUSH, a
        \\PUSH, a
        \\PUSH, a
        \\EXTERN, "SystemInt32.__op_Modulus__SystemInt32_SystemInt32__SystemInt32"
        \\JUMP, 0xFFFFFFFC
    ), "not in the Udon node list");
    try expectError(wrapCode("a: %SystemInt32, 0",
        \\PUSH, a
        \\PUSH, a
        \\EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
        \\JUMP, 0xFFFFFFFC
    ), "takes 3 operand(s)");
    try expectError(wrapCode("a: %SystemInt32, 0\nu: %SystemUInt32, 0",
        \\PUSH, a
        \\PUSH, u
        \\PUSH, u
        \\EXTERN, "SystemUInt32.__op_Addition__SystemUInt32_SystemUInt32__SystemUInt32"
        \\JUMP, 0xFFFFFFFC
    ), "argument 0 is SystemUInt32");
    try expectError(wrapCode("a: %SystemInt32, 0\nb: %SystemInt32, 0",
        \\PUSH, a
        \\PUSH, a
        \\PUSH, b
        \\EXTERN, "SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean"
        \\JUMP, 0xFFFFFFFC
    ), "returns SystemBoolean into 'b'");
}

test "stack discipline" {
    try expectError(wrapCode("a: %SystemInt32, 0", "PUSH, a\nCOPY\nJUMP, 0xFFFFFFFC"), "COPY needs exactly 2");
    try expectError(wrapCode("a: %SystemInt32, 0", "PUSH, a\nJUMP, 0xFFFFFFFC"), "left on the stack");
    try expectError(wrapCode("a: %SystemInt32, 0", "PUSH, a\nJUMP_IF_FALSE, 0xFFFFFFFC\nJUMP, 0xFFFFFFFC"), "not SystemBoolean");
    try expectError(wrapCode("a: %SystemInt32, 0\nb: %SystemInt64, null", "PUSH, a\nPUSH, b\nCOPY\nJUMP, 0xFFFFFFFC"), "COPY retypes");
    try expectError(wrapCode("a: %SystemInt32, 0", "JUMP_INDIRECT, a"), "not SystemUInt32");
    try expectError(wrapCode("", "NOP"), "run past the last instruction");
}

test "return-address constants must hold instruction addresses" {
    const code =
        \\PUSH, rac
        \\PUSH, ra
        \\COPY
        \\JUMP_INDIRECT, ra
    ;
    try expectClean(wrapCode("ra: %SystemUInt32, 0\nrac: %SystemUInt32, 0\nn: %SystemUInt32, 6", code));
    try expectError(wrapCode("ra: %SystemUInt32, 0\nrac: %SystemUInt32, 6", code), "is not an instruction address");
    // Values pushed just before a return target would leak across the jump.
    try expectError(wrapCode("ra: %SystemUInt32, 0\nrac: %SystemUInt32, 28\nx: %SystemInt32, 0",
        \\PUSH, rac
        \\PUSH, ra
        \\COPY
        \\PUSH, x
        \\JUMP_INDIRECT, ra
    ), "left on the stack");
}

test "instance calls take one extra leading operand" {
    try expectClean(wrapCode("t: %UnityEngineTransform, this\np: %UnityEngineVector3, null",
        \\PUSH, t
        \\PUSH, p
        \\EXTERN, "UnityEngineTransform.__get_position__UnityEngineVector3"
        \\JUMP, 0xFFFFFFFC
    ));
}

test "a wrong heap-size comment is an error" {
    try expectError(".data_start\n    # wasdon-zig heap-size: 7\n    a: %SystemInt32, 0\n.data_end\n.code_start\nJUMP, 0xFFFFFFFC\n.code_end\n", "heap-size comment says 7");
    try expectClean(".data_start\n    # wasdon-zig heap-size: 1\n    a: %SystemInt32, 0\n.data_end\n.code_start\nJUMP, 0xFFFFFFFC\n.code_end\n");
}

test "report counts heap usage" {
    var prog = try program.parse(testing.allocator, wrapCode("a: %SystemInt32, 0\nb: %SystemInt32, 0",
        \\PUSH, a
        \\PUSH, a
        \\PUSH, b
        \\EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
        \\PUSH, a
        \\PUSH, b
        \\PUSH, b
        \\EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
        \\JUMP, 0xFFFFFFFC
    ), null);
    defer prog.deinit();
    var r = try check(testing.allocator, &prog);
    defer r.deinit();
    try testing.expect(r.ok());
    try testing.expectEqual(@as(u32, 3), r.heap_size);
    try testing.expectEqual(@as(u32, 2), r.externs);
    try testing.expectEqual(@as(u32, 1), r.unique_externs);
    try testing.expectEqual(@as(u32, 9), r.instructions);
}
