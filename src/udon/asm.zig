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
/// `null_literal` is used for reference types and for the strict-initializer
/// scalars (SystemByte, SystemSByte, SystemInt16/UInt16, SystemInt64/UInt64,
/// SystemBoolean, SystemType) whose only legal non-`this` initial value is
/// `null` — see docs/udon_specs.md §4.7. There is deliberately no byte-literal
/// variant: the UAssembly assembler rejects any numeric initializer for a
/// SystemByte field with `AssemblyException: Type 'SystemByte' must be
/// initialized to null or a this reference.`
pub const Literal = union(enum) {
    int32: i32,
    uint32: u32,
    single: f32,
    string: []const u8,
    null_literal,
    /// The bare token `this`. Legal only for `GameObject`, `Transform`, or
    /// UdonBehaviour/Object-typed slots (`docs/udon_specs.md` §4.6).
    this_ref,

    pub fn write(self: Literal, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .int32 => |v| {
                if (v == std.math.minInt(i32)) {
                    // The Udon Assembler parses signed-decimal literals by
                    // splitting sign and magnitude, then `Int32.Parse(magnitude)`.
                    // For Int32.MinValue this throws OverflowException because
                    // |MinValue| = 2147483648 > Int32.MaxValue. Emit the
                    // bit-pattern hex literal instead — `int.Parse` with
                    // `NumberStyles.HexNumber` returns Int32.MinValue without
                    // overflowing. Triggered in the wild by Rust
                    // `alloc::raw_vec`'s capacity-check idiom.
                    try writer.writeAll("0x80000000");
                } else {
                    try writer.print("{d}", .{v});
                }
            },
            .uint32 => |v| {
                if (v <= std.math.maxInt(i32)) {
                    try writer.print("{d}", .{v});
                } else {
                    // The decimal form `4294967295u` throws OverflowException
                    // because `LexNumber` runs `Int32.Parse` on the magnitude
                    // before honoring the `u` suffix — same path as the
                    // `Int32.MinValue` case above. The hex form must also be
                    // emitted *without* a `u` suffix: VRC's `LexNumber` ends
                    // the hex token at the first non-hex-digit character, so
                    // a trailing `u` is left over as a separate identifier
                    // token, becomes the apparent name of the next data
                    // declaration, and trips
                    // `ParseException: Expected ':', found '<real-name>'` on
                    // the *following* line. The bare hex bit pattern parses
                    // via `NumberStyles.HexNumber` and is stored into the
                    // `%SystemUInt32` slot bit-for-bit — identical to the
                    // `Int32.MinValue` path on line 51. See
                    // docs/udon_specs.md §4.7.
                    try writer.print("0x{X:0>8}", .{v});
                }
            },
            .single => |v| {
                // The Udon Assembler's `LexNumber` is more restrictive than
                // it first appears. Two empirically-confirmed rules drive
                // every choice in this branch (see `docs/udon_specs.md`
                // §4.7):
                //
                //   (1) For numeric tokens, `LexNumber` decides between
                //       the integer- and float-parse paths purely from
                //       token shape, then runs `Int32.Parse` on the
                //       magnitude of integer-shaped tokens. Zig's `{d}`
                //       prints whole-valued or astronomically large
                //       `f32`s without any fractional point (e.g.
                //       `f32(1e13)` → `10000000000000`, `f32::MAX` →
                //       `170141180000000000000000000000000000000`), so a
                //       bare digit-only token would route to integer
                //       parse and overflow even though the slot is
                //       `SystemSingle`. The token must contain a `.` to
                //       reach `float.Parse`.
                //
                //   (2) `LexNumber` does *not* accept `e`/`E` as a
                //       continuation of a float token, *even with a
                //       leading `.`*. `1.0e39` lexes as `1.0` (float,
                //       accepted) plus an orphan IDENTIFIER `e39` that
                //       corrupts the next data declaration with
                //       `ParseException: Expected ':', found
                //       '<next-name>'` — identical failure mode to the
                //       orphan-`u` case in the `.uint32` branch. The only
                //       safe finite-float shape is plain decimal with `.`.
                //
                // Non-finite handling falls out of (2): there is no
                // numeric literal that `float.Parse` returns ±Inf or NaN
                // for *and* that lexes as a single token, so all three
                // non-finite values render as `null` here. The slot
                // defaults to `default(float) = 0.0f`; callers that care
                // about the real value register the slot for runtime
                // synthesis (translator does this in `_onEnable` via
                // `0.0/0.0`-style division — see
                // `Translator.emitF32NonFiniteInits`). Callers that
                // don't register simply receive 0.0.
                if (std.math.isNan(v) or std.math.isInf(v)) {
                    try writer.writeAll("null");
                    return;
                }
                // 512 bytes safely covers any finite `f32` `{d}` rendering
                // — the longest finite output (roughly `f32::MAX`'s ~39-
                // digit form with sign and any trailing fractional digits)
                // is far under 64 bytes, so `bufPrint` cannot return
                // `NoSpaceLeft` here.
                var buf: [512]u8 = undefined;
                const written = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
                // Two integer-shape failure modes still need normalising
                // even though Zig's `{d}` never produces them in practice
                // for finite f32 — kept as defense in depth in case a
                // future Zig formatter changes:
                //
                //   (a) bare integer `10000000000000` — no `.`, no `e` →
                //       integer-parse overflow per rule (1). Append `.0`.
                //
                //   (b) compact scientific `1e30` — has `e`, no `.`.
                //       Rule (2) means even fixing this to `1.0e30`
                //       would not help (the `e` itself is the problem),
                //       so emitting *anything* with `e`/`E` here is a
                //       producer bug. The branch below would inject a
                //       leading `.0` and thus produce a still-broken
                //       `1.0e30`; we keep the path purely so the buffer
                //       isn't silently truncated, but in practice this
                //       arm is unreachable for finite f32 from Zig.
                //
                //   (c) already has a `.` (with or without `e`) — emit
                //       verbatim. With-`e` is broken per rule (2), but
                //       again unreachable for finite f32 from Zig.
                const e_idx_opt = std.mem.indexOfAny(u8, written, "eE");
                const has_dot = std.mem.indexOfScalar(u8, written, '.') != null;
                if (e_idx_opt) |e_idx| {
                    if (has_dot) {
                        try writer.writeAll(written);
                    } else {
                        try writer.writeAll(written[0..e_idx]);
                        try writer.writeAll(".0");
                        try writer.writeAll(written[e_idx..]);
                    }
                } else if (!has_dot and isPurelyDecimalDigits(written)) {
                    try writer.writeAll(written);
                    try writer.writeAll(".0");
                } else {
                    try writer.writeAll(written);
                }
            },
            .string => |s| {
                try writer.writeAll("\"");
                try escapeString(writer, s);
                try writer.writeAll("\"");
            },
            .null_literal => try writer.writeAll("null"),
            .this_ref => try writer.writeAll("this"),
        }
    }

    /// Canonical zero/initial Literal for a `Prim`. Returns a typed zero for
    /// the three primitives whose Udon type accepts non-null numeric
    /// literals (Int32/UInt32/Single per `docs/udon_specs.md` §4.7); every
    /// other primitive — including reference types like GameObject /
    /// Transform / UdonBehaviour — defaults to `null_literal`. Adding a new
    /// reference-typed `Prim` variant therefore needs no change to this
    /// function: the `else` branch absorbs it. If a future `Prim` accepts
    /// a typed literal, add a new arm above the `else` for it.
    pub fn zeroFor(prim: type_name.Prim) Literal {
        return switch (prim) {
            .int32 => .{ .int32 = 0 },
            .uint32 => .{ .uint32 = 0 },
            .single => .{ .single = 0.0 },
            else => .null_literal,
        };
    }
};

/// True when `s` is a non-empty sequence of ASCII digits with at most one
/// leading `-` or `+`. Used by `Literal.write` for `.single` to distinguish
/// "this looks like a bare integer the Udon scanner will integer-parse" from
/// "this is `inf`/`nan`/already-fractional/etc."
fn isPurelyDecimalDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-' or s[0] == '+') {
        if (s.len == 1) return false;
        i = 1;
    }
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return false;
    }
    return true;
}

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
        if (self.lastItemIsLabel()) try self.nop();
        try self.items.append(self.allocator, .{ .label = name });
    }

    pub fn exportLabel(self: *Asm, name: []const u8) !void {
        if (self.lastItemIsLabel()) try self.nop();
        try self.items.append(self.allocator, .{ .export_label = name });
    }

    /// Walk backwards through `items`, transparently skipping decorative
    /// entries (`comment`, `export_label`). Returns true when the first
    /// non-decorative entry encountered is a bare `label` — i.e. adding a
    /// new label right now would produce two labels at the same bytecode
    /// address, which Udon rejects as `AliasedSymbolException`.
    fn lastItemIsLabel(self: *const Asm) bool {
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.items.items[i]) {
                .comment, .export_label => continue,
                .label => return true,
                .instr => return false,
            }
        }
        return false;
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

test "consecutive labels get distinct addresses via implicit NOP" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.label("a"); // 0
    try a.label("b"); // implicit NOP at 0, b @ 4
    try a.label("c"); // implicit NOP at 4, c @ 8

    var layout = try a.computeLayout(std.testing.allocator);
    defer layout.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), layout.get("a").?);
    try std.testing.expectEqual(@as(u32, 4), layout.get("b").?);
    try std.testing.expectEqual(@as(u32, 8), layout.get("c").?);
}

test "export label right after its bare label pair does not collapse addresses" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.exportLabel("_start");
    try a.label("_start"); // co-located with the export directive — no NOP expected
    try a.nop();

    var layout = try a.computeLayout(std.testing.allocator);
    defer layout.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), layout.get("_start").?);
}

test "comment between two labels is transparent and still triggers NOP" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.label("a"); // 0
    try a.comment("between");
    try a.label("b"); // implicit NOP at 0, b @ 4

    var layout = try a.computeLayout(std.testing.allocator);
    defer layout.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), layout.get("a").?);
    try std.testing.expectEqual(@as(u32, 4), layout.get("b").?);
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

test "uint32 literal within int32 range is plain decimal" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{ .name = "__ret_addr_0__", .ty = type_name.uint32, .init = .{ .uint32 = 0x6C } });
    try a.addData(.{ .name = "__zero__", .ty = type_name.uint32, .init = .{ .uint32 = 0 } });
    try a.addData(.{ .name = "__max_i32__", .ty = type_name.uint32, .init = .{ .uint32 = 0x7FFFFFFF } });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemUInt32, 108\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemUInt32, 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemUInt32, 2147483647\n") != null);
}

// `SystemUInt32` literals above `Int32.MaxValue` must be emitted as the
// bare hex bit pattern, with **no** `u` suffix. The decimal form
// `4294967295u` throws `OverflowException` at assemble time — same path as
// the `-2147483648` Int32.MinValue case — because `LexNumber` runs
// `Int32.Parse` on the token's magnitude before honoring the suffix. And
// the hex+`u` form (`0xFFFFFFFFu`) trips a different bug entirely: VRC's
// `LexNumber` ends the hex token at the first non-hex-digit character, so
// the trailing `u` becomes a separate identifier and corrupts the *next*
// data declaration, throwing
// `ParseException: Expected ':', found '<real-name>'` on the line after
// the offending token. The bare hex form parses via
// `NumberStyles.HexNumber` and is stored into the `%SystemUInt32` slot
// bit-for-bit — identical to the `Int32.MinValue` precedent. See
// `docs/udon_specs.md` §4.7.
test "uint32 literal above int32 range uses hex bit pattern" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{ .name = "__big__", .ty = type_name.uint32, .init = .{ .uint32 = 0x80000000 } });
    try a.addData(.{ .name = "__max__", .ty = type_name.uint32, .init = .{ .uint32 = 0xFFFFFFFF } });
    try a.addData(.{ .name = "__mid__", .ty = type_name.uint32, .init = .{ .uint32 = 0xFFFFFF00 } });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemUInt32, 0x80000000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemUInt32, 0xFFFFFFFF\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemUInt32, 0xFFFFFF00\n") != null);
    // Both broken forms — decimal+`u` (Int32.Parse overflow) and hex+`u`
    // (orphaned `u` corrupts the next declaration) — must be absent.
    try std.testing.expect(std.mem.indexOf(u8, out, "2147483648u") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "4294967295u") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "4294967040u") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0x80000000u") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0xFFFFFFFFu") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0xFFFFFF00u") == null);
}

// The Udon Assembler chokes on the decimal form `-2147483648` with
// `OverflowException: Value was either too large or too small for an Int32.`
// — it parses sign and magnitude separately and `Int32.Parse("2147483648")`
// overflows. Hex bit-pattern form sidesteps the bug. Encountered in the wild
// from Rust `alloc::raw_vec`'s capacity-check idiom in
// `examples/wasm-bench-alloc-rs`.
test "int32 literal at Int32.MinValue renders as hex bit pattern" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{ .name = "__min__", .ty = type_name.int32, .init = .{ .int32 = std.math.minInt(i32) } });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemInt32, 0x80000000\n") != null);
    // Make sure the decimal form is NOT present anywhere — this is the form
    // that crashes the Udon Assembler.
    try std.testing.expect(std.mem.indexOf(u8, out, "-2147483648") == null);
}

test "int32 literal at MinValue+1 keeps decimal form" {
    // Only Int32.MinValue is special; -2147483647 and friends parse fine as
    // decimal because the magnitude (2147483647) fits in Int32.
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{ .name = "__almost_min__", .ty = type_name.int32, .init = .{ .int32 = -2147483647 } });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemInt32, -2147483647\n") != null);
}

// The Udon Assembler's `LexNumber` chokes on whole-valued or astronomically
// large `f32` magnitudes printed as bare decimal (e.g. `10000000000000`,
// `170141180000000000000000000000000000000` for `f32::MAX`) the same way it
// chokes on `Int32.MinValue` / unsigned-decimal forms — it picks the parse
// path from token shape and overflows `Int32.Parse` on the magnitude before
// the `SystemSingle` slot type is consulted. Triggered in the wild by the
// Rhai bench's float constant pool. Every emitted `SystemSingle` literal
// must contain a fractional point or exponent so the lexer takes the
// float-parse path.
test "single literal with whole-value or huge magnitude becomes float-shaped" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{ .name = "__one__", .ty = type_name.single, .init = .{ .single = 1.0 } });
    try a.addData(.{ .name = "__neg_one__", .ty = type_name.single, .init = .{ .single = -1.0 } });
    try a.addData(.{ .name = "__1e13__", .ty = type_name.single, .init = .{ .single = 1e13 } });
    try a.addData(.{ .name = "__fmax__", .ty = type_name.single, .init = .{ .single = std.math.floatMax(f32) } });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);

    // Each emitted `SystemSingle` line must contain `.` or `e`/`E` between the
    // type tag and the trailing newline, so the Udon scanner classifies the
    // token as a float instead of integer-overflowing on its magnitude.
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const idx = std.mem.indexOf(u8, line, "%SystemSingle, ") orelse continue;
        const value_token = line[idx + "%SystemSingle, ".len ..];
        try std.testing.expect(std.mem.indexOfAny(u8, value_token, ".eE") != null);
    }

    // Bare decimal-integer tokens for the broken cases must not appear.
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemSingle, 1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemSingle, -1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "10000000000000\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "170141180000000000000000000000000000000\n") == null);
}

// Non-finite `f32`s — the Udon scanner rejects the bare `inf` / `-inf` / `nan`
// tokens Zig's `{d}` would print, so the writer translates them to
// alternative forms that lex as numbers:
//   * `±Inf` → `±1.0e39` — `float.Parse` rounds magnitudes outside
//     [-MaxValue, MaxValue] to `±Infinity`, so the slot ends up holding
//     the correct IEEE bit pattern with no runtime support needed. The
//     `.0` is required: VRC's `LexNumber` does not accept `e` alone as a
//     float marker (the `1e39` form leaks `e39` into the next line as an
//     orphan IDENTIFIER, exactly like the `0xFFFFFFFFu` failure mode).
//   * `NaN` → `null` — no literal token round-trips to NaN, so the slot
//     is initialized to `default(float) = 0.0f`. Callers that need true
//     NaN semantics must register the slot for runtime synthesis (the
//     translator's `emitF32NanInits` does this).
// The bare `inf`, `-inf`, `nan` tokens (and the `inf.0` / `nan.0` shapes
// the float-shape patch above might "fix" them into, plus the dotless
// `1e39` / `-1e39` shapes that an earlier revision used) must not appear.
// All three non-finite f32 values render as `null` in the data section.
// VRC's `LexNumber` rejects every literal shape that `float.Parse` would
// round to ±Inf or NaN: `inf` / `nan` / `-inf` go down the IDENTIFIER
// path, and any `e`/`E` form (`1.0e39`, `-1.0e39`) splits into a finite
// float plus an orphan IDENTIFIER that corrupts the next data
// declaration with `ParseException: Expected ':', found '<next-name>'`.
// The slot is therefore left at `default(float) = 0.0f` here; callers
// that need the real ±Inf / NaN value must register the slot for
// runtime synthesis (the translator does this in `_onEnable` via
// `0.0/0.0`-style division — see `Translator.emitF32NonFiniteInits`).
test "single literal inf/nan render as null for runtime init" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{ .name = "__inf__", .ty = type_name.single, .init = .{ .single = std.math.inf(f32) } });
    try a.addData(.{ .name = "__neg_inf__", .ty = type_name.single, .init = .{ .single = -std.math.inf(f32) } });
    try a.addData(.{ .name = "__nan__", .ty = type_name.single, .init = .{ .single = std.math.nan(f32) } });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    // All three slots default to `null`.
    try std.testing.expect(std.mem.indexOf(u8, out, "__inf__: %SystemSingle, null\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__neg_inf__: %SystemSingle, null\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__nan__: %SystemSingle, null\n") != null);
    // Every shape that would crash the assembler must be absent.
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemSingle, inf") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemSingle, -inf") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemSingle, nan") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemSingle, 1e39") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemSingle, -1e39") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemSingle, 1.0e39") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemSingle, -1.0e39") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "inf.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nan.0") == null);
}

// `LexNumber` requires `.` (not just `e`/`E`) for the float-parse path.
// A scientific token like `1e30` lexes as integer `1` plus IDENTIFIER
// `e30`, and the orphan identifier corrupts the next data declaration
// with `ParseException: Expected ':', found '<real-name>'`. Whenever the
// `{d}` formatter chooses scientific notation without a fractional point
// (depends on the f32 value's shortest-round-trip form), `Literal.write`
// must inject `.0` before the exponent marker.
test "single literal scientific without dot gets dot inserted" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    // 0x7F7FFFFF is f32::MAX ≈ 3.4028235e38. Whatever shape `{d}` chooses,
    // the rendered initializer must not have `e` without `.`.
    const big = @as(f32, std.math.floatMax(f32));
    try a.addData(.{ .name = "__big__", .ty = type_name.single, .init = .{ .single = big } });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    // Find the `__big__:` line and inspect just its initializer.
    const decl_marker = "__big__: %SystemSingle, ";
    const decl_at = std.mem.indexOf(u8, out, decl_marker) orelse return error.TestExpectedEqual;
    const init_start = decl_at + decl_marker.len;
    const init_end = std.mem.indexOfScalarPos(u8, out, init_start, '\n') orelse out.len;
    const init_token = out[init_start..init_end];
    // If the formatter chose `e` notation, the token must also contain `.`.
    if (std.mem.indexOfAny(u8, init_token, "eE")) |_| {
        try std.testing.expect(std.mem.indexOfScalar(u8, init_token, '.') != null);
    }
}

test "single literal already containing dot or exponent is left alone" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{ .name = "__half__", .ty = type_name.single, .init = .{ .single = 0.5 } });
    try a.addData(.{ .name = "__sci__", .ty = type_name.single, .init = .{ .single = 1.5e10 } });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    // Already-float-shaped tokens must not gain a duplicate `.0` suffix.
    try std.testing.expect(std.mem.indexOf(u8, out, "0.5.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemSingle, 0.5\n") != null);
}

// Per docs/udon_specs.md §4.7 the UAssembly assembler rejects any non-null,
// non-`this` initializer for `SystemByte`. A literal `0` triggers
// `AssemblyException: Type 'SystemByte' must be initialized to null or a this
// reference.` at `VisitDataDeclarationStmt`. The `Literal` union therefore
// offers no byte-literal variant; callers must pick `.null_literal`.
test "byte data decl must render as null" {
    var a: Asm = .init(std.testing.allocator);
    defer a.deinit();
    try a.addData(.{ .name = "_b", .ty = type_name.byte, .init = .null_literal });
    const out = try renderToOwned(&a, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "_b: %SystemByte, null\n") != null);
    // No numeric-initialized SystemByte should ever appear in rendered output.
    try std.testing.expect(std.mem.indexOf(u8, out, "%SystemByte, 0") == null);
}
