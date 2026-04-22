//! Udon Assembly writer.
//!
//! Models the textual form from `docs/udon_specs.md` §2-6. Responsibilities:
//!
//!   * Collect data-section variable declarations and their `.export`/`.sync`
//!     attributes.
//!   * Collect code-section instructions and their address layout. Pass A
//!     determines each label's bytecode address (each instruction is 4 or 8
//!     bytes per §6.1) so Pass B can materialize hard-coded `SystemUInt32`
//!     RAC literals.
//!   * Render the full `.data_start … .data_end` / `.code_start … .code_end`
//!     program as text.
//!
//! The writer is **append-only** and owns no WASM knowledge — the translator
//! calls these primitives to stream out instructions.

const std = @import("std");
const type_name = @import("type_name.zig");
const TypeName = type_name.TypeName;

/// Every data-section literal we emit for WASM-side needs.
/// `null_literal` is used for reference types that must stay null at assembly
/// time (e.g. SystemObjectArray, SystemUInt32Array, SystemInt64 — see
/// docs/udon_specs.md §4.7).
pub const Literal = union(enum) {
    int32: i32,
    uint32: u32,
    single: f32,
    string: []const u8,
    null_literal,

    pub fn write(self: Literal, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .int32 => |v| try writer.print("{d}", .{v}),
            .uint32 => |v| try writer.print("0x{X:0>8}u", .{v}),
            .single => |v| try writer.print("{d}", .{v}),
            .string => |s| {
                try writer.writeAll("\"");
                try escapeString(writer, s);
                try writer.writeAll("\"");
            },
            .null_literal => try writer.writeAll("null"),
        }
    }
};

fn escapeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
}

pub const SyncMode = enum { none, linear, smooth };

pub const DataDecl = struct {
    name: []const u8,
    ty: TypeName,
    init: Literal,
    is_export: bool = false,
    sync: ?SyncMode = null,
};

/// Opcodes corresponding to Udon Assembly §6.1.
pub const Opcode = enum {
    nop, // 4
    push, // 8 (param)
    pop, // 4
    jump_if_false, // 8 (addr)
    jump, // 8 (addr)
    extern_, // 8 (name string)
    annotation, // 4 (param)
    jump_indirect, // 8 (var)
    copy, // 4
};

pub fn opcodeSize(op: Opcode) u32 {
    return switch (op) {
        .nop, .pop, .annotation, .copy => 4,
        .push, .jump_if_false, .jump, .extern_, .jump_indirect => 8,
    };
}

pub fn opcodeMnemonic(op: Opcode) []const u8 {
    return switch (op) {
        .nop => "NOP",
        .push => "PUSH",
        .pop => "POP",
        .jump_if_false => "JUMP_IF_FALSE",
        .jump => "JUMP",
        .extern_ => "EXTERN",
        .annotation => "ANNOTATION",
        .jump_indirect => "JUMP_INDIRECT",
        .copy => "COPY",
    };
}

/// An instruction parameter — one of an integer literal, a symbol name, a
/// label reference (resolved at emit time), or a string literal (creating an
/// anonymous data variable — used for EXTERN signatures).
pub const ParamKind = enum { none, symbol, label, integer, string };

pub const Param = union(ParamKind) {
    none,
    /// Name of a variable or label. Stored as an owning slice.
    symbol: []const u8,
    label: []const u8,
    integer: u32,
    string: []const u8,
};

pub const CodeItem = union(enum) {
    label: []const u8,
    export_label: []const u8, // ".export <label>" directive (applies to next label)
    comment: []const u8,
    instr: struct {
        op: Opcode,
        param: Param,
    },
};

pub const Asm = struct {
    allocator: std.mem.Allocator,
    datas: std.ArrayList(DataDecl),
    items: std.ArrayList(CodeItem),

    pub fn init(allocator: std.mem.Allocator) Asm {
        return .{
            .allocator = allocator,
            .datas = .empty,
            .items = .empty,
        };
    }

    pub fn deinit(self: *Asm) void {
        self.datas.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    // ---- data section ----

    pub fn addData(self: *Asm, d: DataDecl) !void {
        try self.datas.append(self.allocator, d);
    }

    // ---- code section ----

    pub fn label(self: *Asm, name: []const u8) !void {
        try self.items.append(self.allocator, .{ .label = name });
    }

    pub fn exportLabel(self: *Asm, name: []const u8) !void {
        try self.items.append(self.allocator, .{ .export_label = name });
    }

    pub fn comment(self: *Asm, text: []const u8) !void {
        try self.items.append(self.allocator, .{ .comment = text });
    }

    pub fn nop(self: *Asm) !void {
        try self.emit(.nop, .none);
    }

    pub fn push(self: *Asm, symbol: []const u8) !void {
        try self.emit(.push, .{ .symbol = symbol });
    }

    pub fn pop(self: *Asm) !void {
        try self.emit(.pop, .none);
    }

    pub fn jump(self: *Asm, lbl: []const u8) !void {
        try self.emit(.jump, .{ .label = lbl });
    }

    pub fn jumpAddr(self: *Asm, addr: u32) !void {
        try self.emit(.jump, .{ .integer = addr });
    }

    pub fn jumpIfFalse(self: *Asm, lbl: []const u8) !void {
        try self.emit(.jump_if_false, .{ .label = lbl });
    }

    pub fn extern_(self: *Asm, sig: []const u8) !void {
        try self.emit(.extern_, .{ .string = sig });
    }

    pub fn annotation(self: *Asm, sym: []const u8) !void {
        try self.emit(.annotation, .{ .symbol = sym });
    }

    pub fn jumpIndirect(self: *Asm, sym: []const u8) !void {
        try self.emit(.jump_indirect, .{ .symbol = sym });
    }

    pub fn copy(self: *Asm) !void {
        try self.emit(.copy, .none);
    }

    fn emit(self: *Asm, op: Opcode, p: Param) !void {
        try self.items.append(self.allocator, .{ .instr = .{ .op = op, .param = p } });
    }

    // ---- layout: bytecode address per label ----

    pub const LabelMap = std.StringHashMapUnmanaged(u32);

    /// Pass A: compute bytecode address for every label. Returns an owned
    /// hash map (caller must `labels.deinit(allocator)`).
    pub fn computeLayout(self: *const Asm, allocator: std.mem.Allocator) !LabelMap {
        var map: LabelMap = .empty;
        errdefer map.deinit(allocator);
        var addr: u32 = 0;
        for (self.items.items) |it| switch (it) {
            .label => |name| try map.put(allocator, name, addr),
            .export_label, .comment => {},
            .instr => |ins| addr += opcodeSize(ins.op),
        };
        return map;
    }

    /// Resolve a label name to its bytecode address. Returns null when the
    /// label is not defined.
    pub fn labelAddr(map: LabelMap, name: []const u8) ?u32 {
        return map.get(name);
    }

    // ---- rendering ----

    /// Pass C: render the complete program. `data_extra` is a list of data
    /// declarations the caller computed from the layout (e.g. RACs whose
    /// literals are label addresses) — they are emitted verbatim alongside
    /// `self.datas`.
    pub fn render(self: *const Asm, writer: *std.Io.Writer, layout: LabelMap) std.Io.Writer.Error!void {
        try writer.writeAll(".data_start\n");
        for (self.datas.items) |d| {
            // attributes first
            if (d.is_export) try writer.print("    .export {s}\n", .{d.name});
            if (d.sync) |mode| try writer.print("    .sync {s}, {s}\n", .{ d.name, syncModeName(mode) });
            try writer.print("    {s}: %", .{d.name});
            try d.ty.write(writer);
            try writer.writeAll(", ");
            try d.init.write(writer);
            try writer.writeAll("\n");
        }
        try writer.writeAll(".data_end\n\n");

        try writer.writeAll(".code_start\n");
        // Track: after `.export <lbl>` we expect to hit that label next — we
        // render it verbatim; the label itself is written before the first
        // instruction that follows.
        for (self.items.items) |it| switch (it) {
            .comment => |t| try writer.print("    # {s}\n", .{t}),
            .export_label => |n| try writer.print("    .export {s}\n", .{n}),
            .label => |n| try writer.print("    {s}:\n", .{n}),
            .instr => |ins| try renderInstr(writer, ins.op, ins.param, layout),
        };
        try writer.writeAll(".code_end\n");
    }
};

fn syncModeName(m: SyncMode) []const u8 {
    return switch (m) {
        .none => "none",
        .linear => "linear",
        .smooth => "smooth",
    };
}

fn renderInstr(w: *std.Io.Writer, op: Opcode, p: Param, layout: Asm.LabelMap) std.Io.Writer.Error!void {
    const m = opcodeMnemonic(op);
    switch (p) {
        .none => try w.print("        {s}\n", .{m}),
        .symbol => |s| try w.print("        {s}, {s}\n", .{ m, s }),
        .label => |n| {
            const addr = layout.get(n) orelse {
                // Fall back to writing the name literally — allows the
                // assembler-side integrator to resolve it, and tests to
                // catch missing labels by substring match. In production
                // an unresolved label is a translator bug.
                try w.print("        {s}, {s} # unresolved\n", .{ m, n });
                return;
            };
            try w.print("        {s}, 0x{X:0>8}\n", .{ m, addr });
        },
        .integer => |v| try w.print("        {s}, 0x{X:0>8}\n", .{ m, v }),
        .string => |s| {
            try w.print("        {s}, \"", .{m});
            try escapeString(w, s);
            try w.writeAll("\"\n");
        },
    }
}

// ------------------ tests ------------------

fn renderToOwned(a: *const Asm, alloc: std.mem.Allocator) ![]u8 {
    var layout = try a.computeLayout(alloc);
    defer layout.deinit(alloc);
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try a.render(&buf.writer, layout);
    return try buf.toOwnedSlice();
}

test "empty program renders the two required sections" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ".data_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".data_end") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".code_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".code_end") != null);
}

test "data decl with .export and .sync" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{
        .name = "_counter",
        .ty = type_name.int32,
        .init = .{ .int32 = 42 },
        .is_export = true,
        .sync = .none,
    });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ".export _counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".sync _counter, none") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_counter: %SystemInt32, 42") != null);
}

test "hello-world-style code emission" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{ .name = "message", .ty = type_name.string, .init = .{ .string = "hi" } });
    try a.exportLabel("_start");
    try a.label("_start");
    try a.push("message");
    try a.extern_("SystemConsole.__WriteLine__SystemString__SystemVoid");
    try a.jumpAddr(0xFFFFFFFC);

    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ".export _start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_start:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PUSH, message") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "EXTERN, \"SystemConsole.__WriteLine__SystemString__SystemVoid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "JUMP, 0xFFFFFFFC") != null);
}

test "label layout assigns correct bytecode addresses" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.label("l0"); // addr 0
    try a.push("x"); // 8 bytes → next addr 8
    try a.label("l1"); // addr 8
    try a.pop(); // 4 bytes → next addr 12
    try a.label("l2"); // addr 12
    try a.nop(); // 4 bytes
    try a.label("l3"); // addr 16

    var layout = try a.computeLayout(std.testing.allocator);
    defer layout.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), layout.get("l0").?);
    try std.testing.expectEqual(@as(u32, 8), layout.get("l1").?);
    try std.testing.expectEqual(@as(u32, 12), layout.get("l2").?);
    try std.testing.expectEqual(@as(u32, 16), layout.get("l3").?);
}

test "jump label references resolve to hex addresses" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.label("entry"); // 0
    try a.push("cond"); // 8
    try a.jumpIfFalse("else_branch"); // 8 -> 16
    try a.jump("done"); // 8 -> 24
    try a.label("else_branch"); // 24
    try a.nop(); // 4 -> 28
    try a.label("done"); // 28

    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "JUMP_IF_FALSE, 0x00000018") != null); // else_branch @ 24
    try std.testing.expect(std.mem.indexOf(u8, out, "JUMP, 0x0000001C") != null); // done @ 28
}

test "uint32 literal formatted with u suffix" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{ .name = "__ret_addr_0__", .ty = type_name.uint32, .init = .{ .uint32 = 0x6C } });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemUInt32, 0x0000006Cu") != null);
}
