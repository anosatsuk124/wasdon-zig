//! Udon Assembly builder and writer.
//!
//! The translator appends variables and instructions here; `render` lays the
//! code out, resolves labels to bytecode addresses and writes the text form
//! from `docs/udon_specs.md`.
//!
//! Instructions refer to variables and labels by index, never by name, so
//! emitted code can be patched (`Asm.code.items[i].arg`) and rewritten by
//! `optimize` before any address is fixed. Labels exist only in the builder:
//! jumps are written as literal addresses, and only exported labels (event
//! entry points) appear in the output. Return addresses — data that must
//! hold a code address — are variables whose initial value is `.address`,
//! filled in at render time (`docs/spec_call_return_conversion.md` §5).

const std = @import("std");
const program = @import("program.zig");

pub const Opcode = program.Opcode;
pub const SyncMode = program.SyncMode;

/// Index into `Asm.vars`.
pub const Sym = u32;
/// Index into `Asm.labels`, or `halt`.
pub const Label = u32;

/// Jump "label" that ends execution (`JUMP, 0xFFFFFFFC`).
pub const halt: Label = std.math.maxInt(u32);
const unbound: u32 = std.math.maxInt(u32);

pub const Init = union(enum) {
    null_,
    this,
    int32: i32,
    uint32: u32,
    single: f32,
    string: []const u8,
    /// `SystemUInt32` holding the bytecode address of a label.
    address: Label,
    /// `SystemString` holding the Base64 of the labels' addresses as
    /// little-endian `u32`s — the image of an address table.
    address_table: []const Label,
};

pub const Var = struct {
    name: []const u8,
    type_name: []const u8,
    init: Init = .null_,
    is_export: bool = false,
    sync: ?SyncMode = null,
};

pub const Instr = struct {
    op: Opcode,
    /// `push` / `jump_indirect`: `Sym`. `jump` / `jump_if_false`: `Label`.
    /// `extern_`: index into `Asm.externs`. Unused otherwise.
    arg: u32 = 0,
};

const LabelInfo = struct {
    /// Index of the instruction the label precedes, or `unbound`.
    pos: u32 = unbound,
    /// Non-empty for labels written to the output with `.export`.
    export_name: []const u8 = "",
};

pub const Asm = struct {
    gpa: std.mem.Allocator,
    vars: std.ArrayList(Var) = .empty,
    var_names: std.StringHashMapUnmanaged(Sym) = .empty,
    code: std.ArrayList(Instr) = .empty,
    labels: std.ArrayList(LabelInfo) = .empty,
    externs: std.ArrayList([]const u8) = .empty,
    extern_ids: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(gpa: std.mem.Allocator) Asm {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Asm) void {
        self.vars.deinit(self.gpa);
        self.var_names.deinit(self.gpa);
        self.code.deinit(self.gpa);
        self.labels.deinit(self.gpa);
        self.externs.deinit(self.gpa);
        self.extern_ids.deinit(self.gpa);
    }

    // ---- data ----

    /// Declare a variable. Names must be unique; `name` and string
    /// initializers must outlive the `Asm`.
    pub fn declare(self: *Asm, v: Var) !Sym {
        const gop = try self.var_names.getOrPut(self.gpa, v.name);
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = @intCast(self.vars.items.len);
        try self.vars.append(self.gpa, v);
        return gop.value_ptr.*;
    }

    pub fn find(self: *const Asm, name: []const u8) ?Sym {
        return self.var_names.get(name);
    }

    // ---- code ----

    pub fn newLabel(self: *Asm) !Label {
        try self.labels.append(self.gpa, .{});
        return @intCast(self.labels.items.len - 1);
    }

    /// Bind `label` to the next instruction emitted.
    pub fn bind(self: *Asm, label: Label) void {
        std.debug.assert(self.labels.items[label].pos == unbound);
        self.labels.items[label].pos = @intCast(self.code.items.len);
    }

    /// A new label bound here and written to the output as `.export name`.
    pub fn exportHere(self: *Asm, name: []const u8) !void {
        const l = try self.newLabel();
        self.labels.items[l].export_name = name;
        self.bind(l);
    }

    pub fn push(self: *Asm, sym: Sym) !void {
        try self.code.append(self.gpa, .{ .op = .push, .arg = sym });
    }

    pub fn copy(self: *Asm, src: Sym, dst: Sym) !void {
        try self.push(src);
        try self.push(dst);
        try self.code.append(self.gpa, .{ .op = .copy });
    }

    /// `PUSH dst; COPY` — the source is what an earlier `PUSH` left on the
    /// stack (a return address parked there by a caller).
    pub fn popInto(self: *Asm, dst: Sym) !void {
        try self.push(dst);
        try self.code.append(self.gpa, .{ .op = .copy });
    }

    pub fn jump(self: *Asm, label: Label) !void {
        try self.code.append(self.gpa, .{ .op = .jump, .arg = label });
    }

    /// `PUSH cond; JUMP_IF_FALSE label`.
    pub fn jumpIfFalse(self: *Asm, cond: Sym, label: Label) !void {
        try self.push(cond);
        try self.code.append(self.gpa, .{ .op = .jump_if_false, .arg = label });
    }

    pub fn jumpIndirect(self: *Asm, sym: Sym) !void {
        try self.code.append(self.gpa, .{ .op = .jump_indirect, .arg = sym });
    }

    /// Operand value of an `EXTERN` of `sig`, which must outlive the `Asm`.
    pub fn internExtern(self: *Asm, sig: []const u8) !u32 {
        const gop = try self.extern_ids.getOrPut(self.gpa, sig);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.externs.items.len);
            try self.externs.append(self.gpa, sig);
        }
        return gop.value_ptr.*;
    }

    /// `PUSH` every operand, then `EXTERN sig`.
    pub fn call(self: *Asm, sig: []const u8, operands: []const Sym) !void {
        for (operands) |s| try self.push(s);
        try self.code.append(self.gpa, .{ .op = .extern_, .arg = try self.internExtern(sig) });
    }

    /// Number of instructions emitted so far; the index the next one gets.
    pub fn here(self: *const Asm) u32 {
        return @intCast(self.code.items.len);
    }

    // ---- statistics ----

    pub const Stats = struct {
        vars: u32,
        instructions: u32,
        externs: u32,
        unique_externs: u32,
        code_bytes: u32,

        /// Heap slots the assembled program occupies: one per variable plus
        /// one anonymous string per distinct extern signature
        /// (`docs/spec_heap_size.md`).
        pub fn heapSize(s: Stats) u32 {
            return s.vars + s.unique_externs;
        }
    };

    pub fn stats(self: *const Asm) Stats {
        var s: Stats = .{
            .vars = @intCast(self.vars.items.len),
            .instructions = @intCast(self.code.items.len),
            .externs = 0,
            .unique_externs = 0,
            .code_bytes = 0,
        };
        var used: std.DynamicBitSetUnmanaged = std.DynamicBitSetUnmanaged.initEmpty(self.gpa, self.externs.items.len) catch return s;
        defer used.deinit(self.gpa);
        for (self.code.items) |ins| {
            s.code_bytes += ins.op.size();
            if (ins.op == .extern_) {
                s.externs += 1;
                used.set(ins.arg);
            }
        }
        s.unique_externs = @intCast(used.count());
        return s;
    }

    // ---- optimization ----

    fn isJump(op: Opcode) bool {
        return op == .jump or op == .jump_if_false;
    }

    /// Follow `label` through chains of unconditional jumps.
    fn thread(self: *const Asm, label: Label) Label {
        var l = label;
        var hops: u32 = 0;
        while (l != halt and hops < 16) : (hops += 1) {
            const pos = self.labels.items[l].pos;
            if (pos >= self.code.items.len) break;
            const ins = self.code.items[pos];
            if (ins.op != .jump or ins.arg == l) break;
            l = ins.arg;
        }
        return l;
    }

    /// Control-flow cleanups that need no knowledge of what the code means:
    /// jump threading, removal of jumps to the next instruction, and removal
    /// of code no jump or fall-through can reach. Safe to run once all code
    /// is emitted and every label is bound.
    pub fn optimize(self: *Asm) !void {
        const code = self.code.items;
        const n = code.len;

        for (code) |*ins| if (isJump(ins.op)) {
            ins.arg = self.thread(ins.arg);
        };

        // Positions something can jump to. Address-holding variables keep
        // their labels alive too.
        const target = try self.gpa.alloc(bool, n + 1);
        defer self.gpa.free(target);
        @memset(target, false);
        const mark = struct {
            fn f(a: *const Asm, t: []bool, l: Label) void {
                if (l != halt) t[a.labels.items[l].pos] = true;
            }
        }.f;
        for (self.labels.items) |l| if (l.export_name.len != 0) {
            target[l.pos] = true;
        };
        for (self.vars.items) |v| switch (v.init) {
            .address => |l| mark(self, target, l),
            .address_table => |ls| for (ls) |l| mark(self, target, l),
            else => {},
        };
        for (code) |ins| if (isJump(ins.op)) mark(self, target, ins.arg);

        const keep = try self.gpa.alloc(bool, n);
        defer self.gpa.free(keep);
        var reachable = true;
        for (code, 0..) |ins, i| {
            if (target[i]) reachable = true;
            keep[i] = reachable;
            if (ins.op == .jump or ins.op == .jump_indirect) reachable = false;
        }
        try self.compact(keep);

        // With the dead code gone, a jump may now target the instruction
        // right after it.
        const after = self.code.items;
        for (after, 0..) |ins, i| {
            keep[i] = !(ins.op == .jump and ins.arg != halt and self.labels.items[ins.arg].pos == i + 1);
        }
        try self.compact(keep[0..after.len]);
    }

    /// Remove the instructions whose `keep` flag is false, moving labels
    /// bound to a removed instruction to the next one kept.
    fn compact(self: *Asm, keep: []const bool) !void {
        const code = self.code.items;
        const new_index = try self.gpa.alloc(u32, code.len + 1);
        defer self.gpa.free(new_index);
        var out: u32 = 0;
        for (code, 0..) |ins, i| {
            new_index[i] = out;
            if (!keep[i]) continue;
            code[out] = ins;
            out += 1;
        }
        new_index[code.len] = out;
        self.code.shrinkRetainingCapacity(out);
        for (self.labels.items) |*l| if (l.pos != unbound) {
            l.pos = new_index[l.pos];
        };
    }

    // ---- rendering ----

    fn labelAddress(self: *const Asm, addrs: []const u32, l: Label) u32 {
        return if (l == halt) program.halt_address else addrs[self.labels.items[l].pos];
    }

    pub fn render(self: *const Asm, w: *std.Io.Writer) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        const code = self.code.items;

        // Two exported labels must not share an address (§5.2). Internal
        // labels are never written, so only exports can alias; a NOP in
        // front of the later one separates them.
        const exports_at = try self.gpa.alloc(u8, code.len + 1);
        defer self.gpa.free(exports_at);
        @memset(exports_at, 0);
        for (self.labels.items) |l| if (l.export_name.len != 0) {
            exports_at[l.pos] +|= 1;
        };

        const addrs = try self.gpa.alloc(u32, code.len + 1);
        defer self.gpa.free(addrs);
        var addr: u32 = 0;
        for (code, 0..) |ins, i| {
            if (exports_at[i] > 1) addr += 4 * (@as(u32, exports_at[i]) - 1);
            addrs[i] = addr;
            addr += ins.op.size();
        }
        addrs[code.len] = addr;

        // The heap the assembler must be given (`docs/spec_heap_size.md`);
        // read by the Unity program asset and by `wasdon-zig check`.
        try w.print(".data_start\n    # wasdon-zig heap-size: {d}\n", .{self.stats().heapSize()});
        for (self.vars.items) |v| {
            if (v.is_export) try w.print("    .export {s}\n", .{v.name});
            if (v.sync) |mode| try w.print("    .sync {s}, {t}\n", .{ v.name, mode });
            try w.print("    {s}: %{s}, ", .{ v.name, v.type_name });
            try self.writeInit(w, v.init, addrs);
            try w.writeAll("\n");
        }
        try w.writeAll(".data_end\n\n.code_start\n");

        for (code, 0..) |ins, i| {
            if (exports_at[i] != 0) {
                var seen: u32 = 0;
                for (self.labels.items) |l| {
                    if (l.export_name.len == 0 or l.pos != i) continue;
                    seen += 1;
                    try w.print("    .export {s}\n    {s}:\n", .{ l.export_name, l.export_name });
                    if (seen < exports_at[i]) try w.writeAll("        NOP\n");
                }
            }
            const m = ins.op.mnemonic();
            switch (ins.op) {
                .nop, .pop, .copy => try w.print("        {s}\n", .{m}),
                .push, .jump_indirect, .annotation => try w.print("        {s}, {s}\n", .{ m, self.vars.items[ins.arg].name }),
                .jump, .jump_if_false => try w.print("        {s}, 0x{X:0>8}\n", .{ m, self.labelAddress(addrs, ins.arg) }),
                .extern_ => try w.print("        {s}, \"{s}\"\n", .{ m, self.externs.items[ins.arg] }),
            }
        }
        try w.writeAll(".code_end\n");
    }

    fn writeInit(self: *const Asm, w: *std.Io.Writer, v: Init, addrs: []const u32) !void {
        switch (v) {
            .null_ => try w.writeAll("null"),
            .this => try w.writeAll("this"),
            // The assembler parses sign and magnitude separately, so the
            // decimal form of Int32.MinValue overflows; the hex form is read
            // as a bit pattern (`docs/udon_specs.md` §4.7).
            .int32 => |x| if (x == std.math.minInt(i32)) try w.writeAll("0x80000000") else try w.print("{d}", .{x}),
            .uint32 => |x| try writeU32(w, x),
            .single => |x| try w.print("{d}", .{x}),
            .string => |s| {
                try w.writeByte('"');
                for (s) |c| switch (c) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(c),
                };
                try w.writeByte('"');
            },
            .address => |l| try writeU32(w, self.labelAddress(addrs, l)),
            .address_table => |ls| {
                const raw = try self.gpa.alloc(u8, ls.len * 4);
                defer self.gpa.free(raw);
                for (ls, 0..) |l, i| std.mem.writeInt(u32, raw[i * 4 ..][0..4], self.labelAddress(addrs, l), .little);
                try w.writeByte('"');
                try std.base64.standard.Encoder.encodeWriter(w, raw);
                try w.writeByte('"');
            },
        }
    }

    /// Values above `Int32.MaxValue` need the `u` suffix; smaller ones are
    /// written without it, which the assembler accepts for both types.
    fn writeU32(w: *std.Io.Writer, x: u32) !void {
        if (x > std.math.maxInt(i32)) try w.print("{d}u", .{x}) else try w.print("{d}", .{x});
    }
};

// ------------------------------- tests -------------------------------

const testing = std.testing;
const check = @import("check.zig");

fn renderOwned(a: *const Asm) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try a.render(&buf.writer);
    return buf.toOwnedSlice();
}

test "hello world renders and passes the checker" {
    var a: Asm = .init(testing.allocator);
    defer a.deinit();
    const msg = try a.declare(.{ .name = "message", .type_name = "SystemString", .init = .{ .string = "hi \"there\"" } });
    try a.exportHere("_start");
    try a.call("UnityEngineDebug.__Log__SystemObject__SystemVoid", &.{msg});
    try a.jump(halt);

    const out = try renderOwned(&a);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\.data_start
        \\    # wasdon-zig heap-size: 2
        \\    message: %SystemString, "hi \"there\""
        \\.data_end
        \\
        \\.code_start
        \\    .export _start
        \\    _start:
        \\        PUSH, message
        \\        EXTERN, "UnityEngineDebug.__Log__SystemObject__SystemVoid"
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
        \\
    , out);

    var prog = try program.parse(testing.allocator, out, null);
    defer prog.deinit();
    var report = try check.check(testing.allocator, &prog);
    defer report.deinit();
    try testing.expect(report.ok());
    try testing.expectEqual(a.stats().heapSize(), report.heap_size);
}

test "labels resolve to addresses; return-address constants follow layout" {
    var a: Asm = .init(testing.allocator);
    defer a.deinit();
    const ret = try a.newLabel();
    const func = try a.newLabel();
    const rac = try a.declare(.{ .name = "rac", .type_name = "SystemUInt32", .init = .{ .address = ret } });
    const ra = try a.declare(.{ .name = "ra", .type_name = "SystemUInt32", .init = .{ .uint32 = 0 } });
    try a.exportHere("go");
    try a.copy(rac, ra); // 0, 8, 16
    try a.jump(func); // 20
    a.bind(ret); // 28
    try a.jump(halt); // 28
    a.bind(func); // 36
    try a.jumpIndirect(ra);

    const out = try renderOwned(&a);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "rac: %SystemUInt32, 28\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "JUMP, 0x00000024\n") != null);
}

test "literal spellings the assembler requires" {
    var a: Asm = .init(testing.allocator);
    defer a.deinit();
    _ = try a.declare(.{ .name = "min", .type_name = "SystemInt32", .init = .{ .int32 = std.math.minInt(i32) } });
    _ = try a.declare(.{ .name = "neg", .type_name = "SystemInt32", .init = .{ .int32 = -2147483647 } });
    _ = try a.declare(.{ .name = "big", .type_name = "SystemUInt32", .init = .{ .uint32 = 0x80000000 } });
    _ = try a.declare(.{ .name = "small", .type_name = "SystemUInt32", .init = .{ .uint32 = 0x7FFFFFFF } });
    _ = try a.declare(.{ .name = "f", .type_name = "SystemSingle", .init = .{ .single = 1.5 } });
    const out = try renderOwned(&a);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "min: %SystemInt32, 0x80000000\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "neg: %SystemInt32, -2147483647\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "big: %SystemUInt32, 2147483648u\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "small: %SystemUInt32, 2147483647\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "f: %SystemSingle, 1.5\n") != null);
}

test "optimize threads jumps and drops dead code" {
    var a: Asm = .init(testing.allocator);
    defer a.deinit();
    const x = try a.declare(.{ .name = "x", .type_name = "SystemInt32", .init = .{ .int32 = 0 } });
    const l1 = try a.newLabel();
    const l2 = try a.newLabel();
    const l3 = try a.newLabel();
    try a.exportHere("go");
    try a.jump(l1);
    try a.copy(x, x); // unreachable
    a.bind(l1);
    try a.jump(l2); // threads to l3's target
    a.bind(l2);
    try a.jump(l3);
    a.bind(l3);
    try a.copy(x, x);
    try a.jump(halt);

    try a.optimize();
    // go: JUMP l3 is a jump to a later instruction that is now adjacent.
    const out = try renderOwned(&a);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "COPY"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "JUMP,"));
}

test "two exported labels at one position are separated by a NOP" {
    var a: Asm = .init(testing.allocator);
    defer a.deinit();
    try a.exportHere("First");
    try a.exportHere("Second");
    try a.jump(halt);
    const out = try renderOwned(&a);
    defer testing.allocator.free(out);
    var prog = try program.parse(testing.allocator, out, null);
    defer prog.deinit();
    var report = try check.check(testing.allocator, &prog);
    defer report.deinit();
    try testing.expect(report.ok());
    try testing.expectEqual(@as(u32, 0), prog.labelAddr("First").?);
    try testing.expectEqual(@as(u32, 4), prog.labelAddr("Second").?);
}

test "address table renders as base64 of little-endian addresses" {
    var a: Asm = .init(testing.allocator);
    defer a.deinit();
    const l = try a.newLabel();
    const labels = [_]Label{ l, halt };
    _ = try a.declare(.{ .name = "tbl", .type_name = "SystemString", .init = .{ .address_table = &labels } });
    try a.code.append(a.gpa, .{ .op = .nop });
    a.bind(l);
    try a.jump(halt);
    const out = try renderOwned(&a);
    defer testing.allocator.free(out);
    // [4, 0xFFFFFFFC] little-endian → 04 00 00 00 FC FF FF FF
    try testing.expect(std.mem.indexOf(u8, out, "tbl: %SystemString, \"BAAAAPz///8=\"\n") != null);
}
