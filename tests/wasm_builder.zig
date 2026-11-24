//! Minimal WASM binary assembler for tests.
//!
//! Lets a test spell out exactly the instructions it wants translated —
//! something a compiler front end would fold or rewrite.

const std = @import("std");
const wasm = @import("wasdon_zig").wasm;

pub const ValType = wasm.types.ValType;
const Tag = std.meta.Tag(wasm.Instruction);

/// Opcode byte of a single-byte instruction, by `Instruction` tag name.
pub fn opcode(comptime tag: []const u8) u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        for (wasm.opcode.spec) |s| if (std.mem.eql(u8, s.tag, tag)) break :blk s.opcode;
        @compileError("not a single-byte opcode: " ++ tag);
    };
}

/// Function body under construction.
pub const Code = struct {
    a: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn raw(self: *Code, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.a, bytes);
    }

    pub fn uleb(self: *Code, v: u64) !void {
        var x = v;
        while (true) {
            const b: u8 = @truncate(x & 0x7F);
            x >>= 7;
            try self.bytes.append(self.a, if (x != 0) b | 0x80 else b);
            if (x == 0) return;
        }
    }

    pub fn sleb(self: *Code, v: i64) !void {
        var x = v;
        while (true) {
            const b: u8 = @truncate(@as(u64, @bitCast(x)) & 0x7F);
            x >>= 7;
            const done = (x == 0 and b & 0x40 == 0) or (x == -1 and b & 0x40 != 0);
            try self.bytes.append(self.a, if (done) b else b | 0x80);
            if (done) return;
        }
    }

    /// Instruction without immediates.
    pub fn op(self: *Code, comptime tag: []const u8) !void {
        try self.bytes.append(self.a, opcode(tag));
    }

    /// Instruction of any tag without immediates (runtime dispatch).
    pub fn opTag(self: *Code, tag: Tag) !void {
        inline for (wasm.opcode.spec) |s| if (std.mem.eql(u8, s.tag, @tagName(tag))) {
            return self.bytes.append(self.a, s.opcode);
        };
        inline for (wasm.opcode.fc_spec) |s| if (std.mem.eql(u8, s.tag, @tagName(tag))) {
            try self.bytes.append(self.a, 0xFC);
            return self.uleb(s.sub);
        };
        unreachable;
    }

    /// Instruction with one index immediate (`local.get`, `call`, `br`, ...).
    pub fn idx(self: *Code, comptime tag: []const u8, i: u32) !void {
        try self.op(tag);
        try self.uleb(i);
    }

    /// Memory access with `align = 0` and the given offset.
    pub fn mem(self: *Code, comptime tag: []const u8, offset: u32) !void {
        try self.op(tag);
        try self.uleb(0);
        try self.uleb(offset);
    }

    /// `0xFC`-prefixed instruction followed by raw immediate bytes.
    pub fn fc(self: *Code, sub: u32, immediates: []const u8) !void {
        try self.bytes.append(self.a, 0xFC);
        try self.uleb(sub);
        try self.raw(immediates);
    }

    pub fn i32c(self: *Code, v: i32) !void {
        try self.op("i32_const");
        try self.sleb(v);
    }

    pub fn i64c(self: *Code, v: i64) !void {
        try self.op("i64_const");
        try self.sleb(v);
    }

    pub fn f32c(self: *Code, v: f32) !void {
        try self.op("f32_const");
        try self.raw(&std.mem.toBytes(@as(u32, @bitCast(v))));
    }

    pub fn f64c(self: *Code, v: f64) !void {
        try self.op("f64_const");
        try self.raw(&std.mem.toBytes(@as(u64, @bitCast(v))));
    }

    /// Constant of type `ty` from its bit pattern.
    pub fn constBits(self: *Code, ty: ValType, bits: u64) !void {
        switch (ty) {
            .i32 => try self.i32c(@bitCast(@as(u32, @truncate(bits)))),
            .i64 => try self.i64c(@bitCast(bits)),
            .f32 => try self.f32c(@bitCast(@as(u32, @truncate(bits)))),
            .f64 => try self.f64c(@bitCast(bits)),
        }
    }

    /// `block` / `loop` / `if` with an empty or single-value block type.
    pub fn begin(self: *Code, comptime tag: []const u8, result: ?ValType) !void {
        try self.op(tag);
        try self.bytes.append(self.a, if (result) |r| @intFromEnum(r) else 0x40);
    }

    pub fn else_(self: *Code) !void {
        try self.bytes.append(self.a, 0x05);
    }

    pub fn end(self: *Code) !void {
        try self.bytes.append(self.a, 0x0B);
    }
};

pub const FuncType = struct { params: []const ValType = &.{}, results: []const ValType = &.{} };

pub const Module = struct {
    a: std.mem.Allocator,
    types: std.ArrayList(FuncType) = .empty,
    imports: std.ArrayList(struct { name: []const u8, ty: u32 }) = .empty,
    funcs: std.ArrayList(struct { ty: u32, locals: []const ValType, body: []const u8 }) = .empty,
    exports: std.ArrayList(struct { name: []const u8, func: u32 }) = .empty,
    globals: std.ArrayList(struct { ty: ValType, bits: u64 }) = .empty,
    datas: std.ArrayList(struct { offset: ?u32, bytes: []const u8 }) = .empty,
    /// Function indices placed in the table from slot 0.
    table: []const u32 = &.{},
    memory_pages: ?u32 = 1,
    memory_max: ?u32 = null,
    start: ?u32 = null,

    pub fn code(self: *Module) Code {
        return .{ .a = self.a };
    }

    pub fn addType(self: *Module, ty: FuncType) !u32 {
        // Copied: callers routinely pass slices of temporaries.
        try self.types.append(self.a, .{ .params = try self.a.dupe(ValType, ty.params), .results = try self.a.dupe(ValType, ty.results) });
        return @intCast(self.types.items.len - 1);
    }

    /// Import `env.<name>`; imports must be added before functions.
    pub fn addImport(self: *Module, name: []const u8, ty: FuncType) !u32 {
        std.debug.assert(self.funcs.items.len == 0);
        try self.imports.append(self.a, .{ .name = name, .ty = try self.addType(ty) });
        return @intCast(self.imports.items.len - 1);
    }

    /// Index the next `addFunc` will return (for forward and self calls).
    pub fn nextFunc(self: *const Module) u32 {
        return @intCast(self.imports.items.len + self.funcs.items.len);
    }

    pub fn addFunc(self: *Module, ty: FuncType, locals: []const ValType, body: *Code) !u32 {
        try body.end();
        try self.funcs.append(self.a, .{ .ty = try self.addType(ty), .locals = try self.a.dupe(ValType, locals), .body = body.bytes.items });
        return self.nextFunc() - 1;
    }

    pub fn exportFunc(self: *Module, name: []const u8, func: u32) !void {
        try self.exports.append(self.a, .{ .name = name, .func = func });
    }

    /// Mutable global initialised from a bit pattern; returns its index.
    pub fn addGlobal(self: *Module, ty: ValType, bits: u64) !u32 {
        try self.globals.append(self.a, .{ .ty = ty, .bits = bits });
        return @intCast(self.globals.items.len - 1);
    }

    /// Active data segment at `offset`, or a passive one when `offset` is null.
    pub fn addData(self: *Module, offset: ?u32, bytes: []const u8) !void {
        try self.datas.append(self.a, .{ .offset = offset, .bytes = bytes });
    }

    fn section(self: *Module, out: *Code, id: u8, payload: *Code) !void {
        _ = self;
        try out.bytes.append(out.a, id);
        try out.uleb(payload.bytes.items.len);
        try out.raw(payload.bytes.items);
    }

    fn putName(c: *Code, s: []const u8) !void {
        try c.uleb(s.len);
        try c.raw(s);
    }

    pub fn build(self: *Module) ![]const u8 {
        var out = self.code();
        try out.raw(&.{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 });

        var s = self.code();
        try s.uleb(self.types.items.len);
        for (self.types.items) |ty| {
            try s.raw(&.{0x60});
            try s.uleb(ty.params.len);
            for (ty.params) |p| try s.raw(&.{@intFromEnum(p)});
            try s.uleb(ty.results.len);
            for (ty.results) |r| try s.raw(&.{@intFromEnum(r)});
        }
        try self.section(&out, 1, &s);

        if (self.imports.items.len > 0) {
            s = self.code();
            try s.uleb(self.imports.items.len);
            for (self.imports.items) |imp| {
                try putName(&s, "env");
                try putName(&s, imp.name);
                try s.raw(&.{0x00});
                try s.uleb(imp.ty);
            }
            try self.section(&out, 2, &s);
        }

        s = self.code();
        try s.uleb(self.funcs.items.len);
        for (self.funcs.items) |f| try s.uleb(f.ty);
        try self.section(&out, 3, &s);

        if (self.table.len > 0) {
            s = self.code();
            try s.raw(&.{ 0x01, 0x70, 0x00 });
            try s.uleb(self.table.len);
            try self.section(&out, 4, &s);
        }
        if (self.memory_pages) |pages| {
            s = self.code();
            try s.raw(&.{ 0x01, if (self.memory_max == null) 0x00 else 0x01 });
            try s.uleb(pages);
            if (self.memory_max) |max| try s.uleb(max);
            try self.section(&out, 5, &s);
        }
        if (self.globals.items.len > 0) {
            s = self.code();
            try s.uleb(self.globals.items.len);
            for (self.globals.items) |g| {
                try s.raw(&.{ @intFromEnum(g.ty), 0x01 });
                try s.constBits(g.ty, g.bits);
                try s.end();
            }
            try self.section(&out, 6, &s);
        }
        if (self.exports.items.len > 0) {
            s = self.code();
            try s.uleb(self.exports.items.len);
            for (self.exports.items) |e| {
                try putName(&s, e.name);
                try s.raw(&.{0x00});
                try s.uleb(e.func);
            }
            try self.section(&out, 7, &s);
        }
        if (self.start) |f| {
            s = self.code();
            try s.uleb(f);
            try self.section(&out, 8, &s);
        }
        if (self.table.len > 0) {
            s = self.code();
            try s.raw(&.{ 0x01, 0x00 });
            try s.i32c(0);
            try s.end();
            try s.uleb(self.table.len);
            for (self.table) |f| try s.uleb(f);
            try self.section(&out, 9, &s);
        }
        var passive = false;
        for (self.datas.items) |d| passive = passive or d.offset == null;
        if (passive) {
            s = self.code();
            try s.uleb(self.datas.items.len);
            try self.section(&out, 12, &s);
        }

        s = self.code();
        try s.uleb(self.funcs.items.len);
        for (self.funcs.items) |f| {
            var body = self.code();
            // One local group per local keeps the encoder trivial.
            try body.uleb(f.locals.len);
            for (f.locals) |l| try body.raw(&.{ 0x01, @intFromEnum(l) });
            try body.raw(f.body);
            try s.uleb(body.bytes.items.len);
            try s.raw(body.bytes.items);
        }
        try self.section(&out, 10, &s);

        if (self.datas.items.len > 0) {
            s = self.code();
            try s.uleb(self.datas.items.len);
            for (self.datas.items) |d| {
                if (d.offset) |off| {
                    try s.raw(&.{0x00});
                    try s.i32c(@bitCast(off));
                    try s.end();
                } else try s.raw(&.{0x01});
                try s.uleb(d.bytes.len);
                try s.raw(d.bytes);
            }
            try self.section(&out, 11, &s);
        }
        return out.bytes.items;
    }
};
