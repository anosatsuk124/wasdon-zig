//! Udon Assembly program builder and text writer (`docs/udon_specs.md`).
//!
//! The builder works one level above raw opcodes: an `ext` instruction owns
//! its argument list and a `copy` owns both operands, so every `PUSH` in the
//! output is consumed by the instruction right after its group. Jump targets
//! are `Label`s resolved to bytecode addresses when the program is written;
//! only exported labels (event entry points) appear by name in the text.

const std = @import("std");

pub const Var = u32;
pub const Label = u32;
pub const Extern = u32;

pub const max_args = 6;
/// `JUMP` to this address ends the current event (§9.2).
pub const halt_addr: u32 = 0xFFFFFFFC;

pub const Sync = enum { none, linear, smooth };

pub const Init = union(enum) {
    null_,
    this,
    int: i32,
    uint: u32,
    float: f32,
    string: []const u8,
    /// `SystemUInt32` literal holding the bytecode address of a label.
    label: Label,
    /// `SystemString` literal: base64 of the labels' addresses as
    /// little-endian `u32`s (decoded at runtime into a jump table).
    label_table: []const Label,
};

pub const VarDecl = struct {
    name: []const u8,
    ty: []const u8,
    init: Init = .null_,
    exported: bool = false,
    sync: ?Sync = null,
};

pub const Ext = struct {
    sig: Extern,
    args: [max_args]Var = undefined,
    n: u8 = 0,
};

pub const Inst = union(enum) {
    label: Label,
    /// `PUSH` each argument, then `EXTERN`.
    ext: Ext,
    /// `PUSH src; PUSH dst; COPY`.
    copy: struct { src: Var, dst: Var },
    jump: Label,
    /// `PUSH cond; JUMP_IF_FALSE target`.
    jump_if_false: struct { cond: Var, target: Label },
    jump_indirect: Var,
    halt,
    comment: []const u8,

    pub fn size(self: Inst) u32 {
        return switch (self) {
            .label, .comment => 0,
            .ext => |e| 8 * @as(u32, e.n) + 8,
            .copy => 20,
            .jump_if_false => 16,
            .jump, .jump_indirect, .halt => 8,
        };
    }
};

pub const Program = struct {
    gpa: std.mem.Allocator,
    vars: std.ArrayList(VarDecl) = .empty,
    externs: std.ArrayList([]const u8) = .empty,
    extern_ids: std.StringHashMapUnmanaged(Extern) = .empty,
    insts: std.ArrayList(Inst) = .empty,
    exports: std.ArrayList(struct { label: Label, name: []const u8 }) = .empty,
    label_count: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Program {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Program) void {
        self.vars.deinit(self.gpa);
        self.externs.deinit(self.gpa);
        self.extern_ids.deinit(self.gpa);
        self.insts.deinit(self.gpa);
        self.exports.deinit(self.gpa);
    }

    pub fn addVar(self: *Program, decl: VarDecl) !Var {
        try self.vars.append(self.gpa, decl);
        return @intCast(self.vars.items.len - 1);
    }

    pub fn internExtern(self: *Program, sig: []const u8) !Extern {
        const gop = try self.extern_ids.getOrPut(self.gpa, sig);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.externs.items.len);
            try self.externs.append(self.gpa, sig);
        }
        return gop.value_ptr.*;
    }

    pub fn newLabel(self: *Program) Label {
        self.label_count += 1;
        return self.label_count - 1;
    }

    pub fn exportLabel(self: *Program, label: Label, name: []const u8) !void {
        try self.exports.append(self.gpa, .{ .label = label, .name = name });
    }

    pub fn emit(self: *Program, inst: Inst) !void {
        try self.insts.append(self.gpa, inst);
    }

    /// Heap slots the assembled program occupies: one per declared variable
    /// plus one anonymous string per distinct `EXTERN` name in use (§10).
    pub fn heapSlots(self: *const Program) !usize {
        var used = try std.DynamicBitSetUnmanaged.initEmpty(self.gpa, self.externs.items.len);
        defer used.deinit(self.gpa);
        for (self.insts.items) |inst| if (inst == .ext) used.set(inst.ext.sig);
        return self.vars.items.len + used.count();
    }

    /// Bytecode address of every label. Caller frees the slice.
    pub fn layout(self: *const Program, gpa: std.mem.Allocator) ![]u32 {
        const addrs = try gpa.alloc(u32, self.label_count);
        @memset(addrs, halt_addr);
        var pc: u32 = 0;
        for (self.insts.items) |inst| {
            if (inst == .label) addrs[inst.label] = pc;
            pc += inst.size();
        }
        return addrs;
    }

    pub const WriteError = error{ UndefinedLabel, AliasedLabels } || std.mem.Allocator.Error || std.Io.Writer.Error;

    pub fn write(self: *const Program, w: *std.Io.Writer) WriteError!void {
        const addrs = try self.layout(self.gpa);
        defer self.gpa.free(addrs);
        for (self.exports.items, 0..) |e, i| {
            if (addrs[e.label] == halt_addr) return error.UndefinedLabel;
            // Two named labels on one address trip "Address aliasing detected" (§5.2).
            for (self.exports.items[0..i]) |prev| if (addrs[prev.label] == addrs[e.label]) return error.AliasedLabels;
        }

        try w.writeAll(".data_start\n");
        for (self.vars.items) |v| {
            if (v.exported) try w.print("    .export {s}\n", .{v.name});
            if (v.sync) |mode| try w.print("    .sync {s}, {s}\n", .{ v.name, @tagName(mode) });
            try w.print("    {s}: %{s}, ", .{ v.name, v.ty });
            try self.writeInit(w, v.init, addrs);
            try w.writeByte('\n');
        }
        try w.writeAll(".data_end\n\n.code_start\n");
        for (self.insts.items) |inst| switch (inst) {
            .comment => |text| try w.print("    # {s}\n", .{text}),
            .label => |l| for (self.exports.items) |e| {
                if (e.label == l) try w.print("    .export {s}\n    {s}:\n", .{ e.name, e.name });
            },
            .ext => |e| {
                for (e.args[0..e.n]) |a| try self.writePush(w, a);
                try w.print("        EXTERN, \"{s}\"\n", .{self.externs.items[e.sig]});
            },
            .copy => |c| {
                try self.writePush(w, c.src);
                try self.writePush(w, c.dst);
                try w.writeAll("        COPY\n");
            },
            .jump => |l| try writeJump(w, "JUMP", try resolve(addrs, l)),
            .jump_if_false => |j| {
                try self.writePush(w, j.cond);
                try writeJump(w, "JUMP_IF_FALSE", try resolve(addrs, j.target));
            },
            .jump_indirect => |v| try w.print("        JUMP_INDIRECT, {s}\n", .{self.vars.items[v].name}),
            .halt => try writeJump(w, "JUMP", halt_addr),
        };
        try w.writeAll(".code_end\n");
    }

    fn writePush(self: *const Program, w: *std.Io.Writer, v: Var) !void {
        try w.print("        PUSH, {s}\n", .{self.vars.items[v].name});
    }

    fn writeJump(w: *std.Io.Writer, op: []const u8, addr: u32) !void {
        try w.print("        {s}, 0x{X:0>8}\n", .{ op, addr });
    }

    fn resolve(addrs: []const u32, l: Label) !u32 {
        if (addrs[l] == halt_addr) return error.UndefinedLabel;
        return addrs[l];
    }

    fn writeInit(self: *const Program, w: *std.Io.Writer, init_: Init, addrs: []const u32) WriteError!void {
        switch (init_) {
            .null_ => try w.writeAll("null"),
            .this => try w.writeAll("this"),
            // The assembler parses a decimal magnitude with `Int32.Parse`,
            // which overflows on |Int32.MinValue|; the hex form is read as a
            // bit pattern (§4.7).
            .int => |v| if (v == std.math.minInt(i32)) try w.writeAll("0x80000000") else try w.print("{d}", .{v}),
            .uint => |v| try writeUInt(w, v),
            .float => |v| try w.print("{d}", .{v}),
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
            .label => |l| try writeUInt(w, try resolve(addrs, l)),
            .label_table => |labels| {
                const bytes = try self.gpa.alloc(u8, labels.len * 4);
                defer self.gpa.free(bytes);
                for (labels, 0..) |l, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], try resolve(addrs, l), .little);
                try w.writeByte('"');
                try std.base64.standard.Encoder.encodeWriter(w, bytes);
                try w.writeByte('"');
            },
        }
    }

    fn writeUInt(w: *std.Io.Writer, v: u32) !void {
        try w.print("{d}", .{v});
        if (v > std.math.maxInt(i32)) try w.writeByte('u');
    }
};

fn render(p: *const Program) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try p.write(&buf.writer);
    return buf.toOwnedSlice();
}

test "writes sections, attributes, grouped pushes and resolved jumps" {
    var p: Program = .init(std.testing.allocator);
    defer p.deinit();
    const start = p.newLabel();
    const done = p.newLabel();
    const a = try p.addVar(.{ .name = "_a", .ty = "SystemInt32", .init = .{ .int = std.math.minInt(i32) }, .exported = true, .sync = .none });
    const ok = try p.addVar(.{ .name = "_ok", .ty = "SystemBoolean" });
    const ra = try p.addVar(.{ .name = "_ra", .ty = "SystemUInt32", .init = .{ .label = done } });
    const eq = try p.internExtern("SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean");
    try std.testing.expectEqual(eq, try p.internExtern("SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean"));

    try p.exportLabel(start, "_start");
    try p.emit(.{ .label = start });
    var e: Ext = .{ .sig = eq, .n = 3 };
    e.args[0..3].* = .{ a, a, ok };
    try p.emit(.{ .ext = e }); // 0x00..0x20
    try p.emit(.{ .jump_if_false = .{ .cond = ok, .target = done } }); // 0x20..0x30
    try p.emit(.{ .copy = .{ .src = a, .dst = a } }); // 0x30..0x44
    try p.emit(.{ .label = done });
    try p.emit(.{ .jump_indirect = ra });
    try p.emit(.halt);

    const out = try render(&p);
    defer std.testing.allocator.free(out);
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) !void {
            try std.testing.expect(std.mem.indexOf(u8, hay, needle) != null);
        }
    }.f;
    try has(out, "    .export _a\n    .sync _a, none\n    _a: %SystemInt32, 0x80000000\n");
    try has(out, "    _ra: %SystemUInt32, 68\n");
    try has(out, "    .export _start\n    _start:\n        PUSH, _a\n        PUSH, _a\n        PUSH, _ok\n        EXTERN, \"SystemInt32.__op_Equality__");
    try has(out, "        PUSH, _ok\n        JUMP_IF_FALSE, 0x00000044\n");
    try has(out, "        JUMP, 0xFFFFFFFC\n.code_end\n");
    try std.testing.expectEqual(@as(usize, 4), try p.heapSlots());
}

test "jump to an unplaced label is an error" {
    var p: Program = .init(std.testing.allocator);
    defer p.deinit();
    try p.emit(.{ .jump = p.newLabel() });
    try std.testing.expectError(error.UndefinedLabel, render(&p));
}
