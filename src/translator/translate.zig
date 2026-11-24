//! WASM module → Udon Assembly: module-level orchestration.
//!
//! `Translator` owns everything that outlives a single function: the Udon
//! program being built, interned constants and scratch variables, WASM
//! globals, linear memory, the function/jump address table, event entry
//! points and the one-time initialisation routine. Function bodies are
//! lowered by `lower.zig`; shared helper routines live in `runtime.zig`.
//!
//! Layout of the generated code section:
//!
//!     null-jump trap | functions | runtime routines | init routine | event entries
//!
//! The design is documented under `docs/` — start with
//! `docs/spec_call_return_conversion.md` and `docs/spec_linear_memory.md`.

const std = @import("std");
const wasm = @import("wasm");
const udon = @import("udon");
const callgraph = @import("callgraph.zig");
const lower = @import("lower.zig");
const runtime = @import("runtime.zig");

const asm_ = udon.asm_;
pub const Var = asm_.Var;
pub const Label = asm_.Label;
const ValType = wasm.types.ValType;
const FuncType = wasm.types.FuncType;
const Instruction = wasm.Instruction;

pub const page_size = 65536;
/// A .NET `byte[]` tops out just below 2 GiB.
pub const max_supported_pages = 32767;
/// Base64 characters per data-segment string literal (a multiple of 4).
const data_chunk_chars = 60000;

pub const Error = error{
    /// The module uses something the translator cannot express in Udon.
    UnsupportedFeature,
    /// The module is not valid WASM (bad index, type mismatch, ...).
    InvalidModule,
    /// `__udon_meta` names an export the module does not have.
    UnresolvedExport,
    /// A host import is not an Udon extern signature (strict mode only).
    UnresolvedImport,
    /// Two Udon variables ended up with the same name.
    DuplicateVariable,
} || asm_.Program.WriteError;

pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    warnings: std.ArrayList([]const u8) = .empty,
    /// Heap slots the assembled program needs (variables + extern names).
    heap_slots: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.arena.deinit();
    }
};

pub const Options = struct {
    /// Memory growth limit when neither `__udon_meta` nor the module sets one.
    default_max_pages: u32 = 256,
    /// Nesting depth available to recursive functions.
    call_stack_depth: u32 = 1024,
    /// Extern names the Udon VM ships. Imports outside the set are reported
    /// as warnings: such a program assembles but silently never runs.
    nodes: ?*const udon.check.NodeSet = null,
    diagnostics: ?*Diagnostics = null,
};

pub fn translate(
    gpa: std.mem.Allocator,
    mod: wasm.Module,
    meta: ?wasm.UdonMeta,
    writer: *std.Io.Writer,
    options: Options,
) Error!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var t: Translator = .{ .a = arena.allocator(), .mod = mod, .meta = meta, .options = options, .prog = .init(arena.allocator()) };
    try t.build();
    if (options.diagnostics) |d| d.heap_slots = try t.prog.heapSlots();
    try t.prog.write(writer);
}

/// Slot classes. Every Udon variable the translator allocates for a function
/// belongs to one class, so its declared type never changes.
pub const Class = enum(u8) {
    i32,
    i64,
    f32,
    f64,
    /// Comparison results waiting to be branched on.
    bool,
    /// Return address ("link register") of the function.
    lr,

    pub const count = 6;

    pub fn of(vt: ValType) Class {
        return switch (vt) {
            .i32 => .i32,
            .i64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
        };
    }

    pub fn udonType(self: Class) []const u8 {
        return switch (self) {
            .i32 => "SystemInt32",
            .i64 => "SystemInt64",
            .f32 => "SystemSingle",
            .f64 => "SystemDouble",
            .bool => "SystemBoolean",
            .lr => "SystemUInt32",
        };
    }

    fn zeroInit(self: Class) asm_.Init {
        return switch (self) {
            .i32 => .{ .int = 0 },
            .lr => .{ .uint = 0 },
            else => .null_,
        };
    }
};

/// A constant operand, identified by type and bit pattern.
pub const Const = struct {
    ty: ValType,
    bits: u64,

    pub fn i32_(v: i32) Const {
        return .{ .ty = .i32, .bits = @as(u32, @bitCast(v)) };
    }
    pub fn i64_(v: i64) Const {
        return .{ .ty = .i64, .bits = @bitCast(v) };
    }
    pub fn asI32(self: Const) i32 {
        return @bitCast(@as(u32, @truncate(self.bits)));
    }
    pub fn asI64(self: Const) i64 {
        return @bitCast(self.bits);
    }
};

/// Variables with bit 31 set are frame slots: an index into
/// `Translator.frame_refs`, resolved to a pooled variable once every
/// function's frame size is known.
const frame_bit: Var = 0x8000_0000;
/// Destination operand that has not been decided yet (see `lower.zig`).
pub const placeholder: Var = 0x7FFF_FFFF;

const FrameRef = struct { func: u32, class: Class, idx: u32 };

const Global = struct { v: Var, ty: ValType };

const Event = struct { label: []const u8, func: u32 };

pub const Translator = struct {
    a: std.mem.Allocator,
    mod: wasm.Module,
    meta: ?wasm.UdonMeta,
    options: Options,
    prog: asm_.Program,

    func_imports: []wasm.module.Import = &.{},
    globals: []Global = &.{},
    events: []Event = &.{},

    /// Per defined function (index = funcidx - func_imports.len).
    entry: []Label = &.{},
    /// Entry used by `call_indirect`, for functions listed in a table.
    stub: []?Label = &.{},
    callees: [][]const u32 = &.{},
    sccs: callgraph.Sccs = undefined,
    frame_sizes: [][Class.count]u32 = &.{},
    frame_refs: std.ArrayList(FrameRef) = .empty,
    frame_ids: std.AutoHashMapUnmanaged(FrameRef, Var) = .empty,

    named_vars: std.StringHashMapUnmanaged(Var) = .empty,
    i32_consts: std.AutoHashMapUnmanaged(i32, Var) = .empty,
    /// 64-bit and floating-point constants cannot be written as literals
    /// (`docs/udon_specs.md` §4.7); they are decoded from `blob` at init.
    wide_consts: std.AutoHashMapUnmanaged(Const, Var) = .empty,
    wide_list: std.ArrayList(struct { c: Const, v: Var, offset: u32 }) = .empty,
    blob: std.ArrayList(u8) = .empty,
    blob_sealed: bool = false,

    /// Function table followed by `br_table` jump tables.
    table: std.ArrayList(Label) = .empty,
    data_vars: []?Var = &.{},
    rt: runtime.Routines = .{},
    trap_null: Label = undefined,

    has_memory: bool = false,
    initial_pages: u32 = 0,
    max_pages: u32 = 0,
    mem_name: []const u8 = "__G__memory",
    uses_call_stack: bool = false,
    rac_count: u32 = 0,

    // ------------------------------------------------------------------
    // Build
    // ------------------------------------------------------------------

    fn build(self: *Translator) Error!void {
        try self.resolveImports();
        try self.resolveMemory();
        try self.resolveGlobals();
        try self.resolveEvents();
        try self.analyzeCalls();

        self.trap_null = self.prog.newLabel();
        try self.place(self.trap_null);
        try self.trap("wasdon: jump through a null function pointer or return address");

        for (0..self.mod.codes.len) |d| try lower.lowerFunction(self, @intCast(d));
        try runtime.emit(self);
        const init_label = try self.emitInit();
        try self.emitEvents(init_label);
        try self.resolveFrames();
    }

    fn resolveImports(self: *Translator) Error!void {
        var funcs: std.ArrayList(wasm.module.Import) = .empty;
        for (self.mod.imports) |imp| if (imp.desc == .func) try funcs.append(self.a, imp);
        self.func_imports = funcs.items;
        if (self.mod.memories.len > 1) return error.UnsupportedFeature;
    }

    pub fn funcType(self: *const Translator, func: u32) Error!FuncType {
        const n: u32 = @intCast(self.func_imports.len);
        const tidx = if (func < n) self.func_imports[func].desc.func else blk: {
            if (func - n >= self.mod.funcs.len) return error.InvalidModule;
            break :blk self.mod.funcs[func - n];
        };
        if (tidx >= self.mod.types_.len) return error.InvalidModule;
        return self.mod.types_[tidx];
    }

    fn exportedFunc(self: *const Translator, name: []const u8) ?u32 {
        for (self.mod.exports) |e| if (e.desc == .func and std.mem.eql(u8, e.name, name)) return e.desc.func;
        return null;
    }

    pub fn warn(self: *Translator, comptime fmt: []const u8, args: anytype) Error!void {
        const d = self.options.diagnostics orelse return;
        try d.warnings.append(d.arena.allocator(), try std.fmt.allocPrint(d.arena.allocator(), fmt, args));
    }

    // ------------------------------------------------------------------
    // Memory
    // ------------------------------------------------------------------

    fn resolveMemory(self: *Translator) Error!void {
        var limits: ?wasm.types.Limits = if (self.mod.memories.len > 0) self.mod.memories[0] else null;
        for (self.mod.imports) |imp| if (imp.desc == .memory) {
            limits = imp.desc.memory;
        };
        const lim = limits orelse return;
        self.has_memory = true;
        const opts: wasm.udon_meta.MemoryOptions = if (self.meta) |m| m.options.memory else .{};
        if (opts.udon_name) |name| self.mem_name = name;

        // Never start below what the data segments need.
        var data_end: u64 = 0;
        for (self.mod.datas) |d| {
            if (d.passive) continue;
            const off = wasm.const_eval.evalConstI32(self.mod, d.offset) catch return error.UnsupportedFeature;
            data_end = @max(data_end, @as(u64, @as(u32, @bitCast(off))) + d.init.len);
        }
        const data_pages: u32 = @intCast((data_end + page_size - 1) / page_size);
        self.initial_pages = @max(opts.initial_pages orelse lim.min, lim.min, data_pages);
        self.max_pages = @max(opts.max_pages orelse lim.max orelse self.options.default_max_pages, self.initial_pages);
        self.max_pages = @min(self.max_pages, max_supported_pages);
        if (self.initial_pages > self.max_pages) return error.UnsupportedFeature;
    }

    /// The `SystemByteArray` holding linear memory.
    pub fn mem(self: *Translator) Error!Var {
        if (!self.has_memory) return error.InvalidModule;
        return self.named(self.mem_name, "SystemByteArray", .null_);
    }

    /// Current memory size in pages.
    pub fn memPages(self: *Translator) Error!Var {
        const name = try std.fmt.allocPrint(self.a, "{s}_size_pages", .{self.mem_name});
        return self.named(name, "SystemInt32", .{ .int = @intCast(self.initial_pages) });
    }

    pub fn memMaxPages(self: *Translator) Error!Var {
        const name = try std.fmt.allocPrint(self.a, "{s}_max_pages", .{self.mem_name});
        return self.named(name, "SystemInt32", .{ .int = @intCast(self.max_pages) });
    }

    /// One-element typed array used to move a value into linear memory with
    /// `Buffer.BlockCopy` (no per-store allocation).
    pub fn box(self: *Translator, class: Class) Error!Var {
        return switch (class) {
            .i32 => self.named("__box_i32", "SystemInt32Array", .null_),
            .i64 => self.named("__box_i64", "SystemInt64Array", .null_),
            .f32 => self.named("__box_f32", "SystemSingleArray", .null_),
            .f64 => self.named("__box_f64", "SystemDoubleArray", .null_),
            else => unreachable,
        };
    }

    pub fn sbyteBox(self: *Translator) Error!Var {
        return self.named("__box_i8", "SystemSByteArray", .null_);
    }

    pub fn utf8(self: *Translator) Error!Var {
        return self.named("__utf8", "SystemTextEncoding", .null_);
    }

    /// `byte[]` holding data segment `idx`, for `memory.init`.
    pub fn dataVar(self: *Translator, idx: u32) Error!Var {
        if (idx >= self.mod.datas.len) return error.InvalidModule;
        if (self.data_vars.len == 0) {
            self.data_vars = try self.a.alloc(?Var, self.mod.datas.len);
            @memset(self.data_vars, null);
        }
        if (self.data_vars[idx] == null) {
            const name = try std.fmt.allocPrint(self.a, "__data_{d}", .{idx});
            self.data_vars[idx] = try self.named(name, "SystemByteArray", .null_);
        }
        return self.data_vars[idx].?;
    }

    // ------------------------------------------------------------------
    // Globals and __udon_meta fields
    // ------------------------------------------------------------------

    fn metaFields(self: *const Translator) []const wasm.udon_meta.Field {
        return if (self.meta) |m| m.fields else &.{};
    }

    fn importField(self: *const Translator, imp: wasm.module.Import) ?wasm.udon_meta.Field {
        for (self.metaFields()) |f| {
            if (f.source.kind != .import) continue;
            if (std.mem.eql(u8, f.source.module orelse continue, imp.module) and
                std.mem.eql(u8, f.source.name orelse continue, imp.name)) return f;
        }
        return null;
    }

    /// Udon variable bound to a function import by a `kind: "import"` field:
    /// calling the import reads the variable (`docs/spec_host_import_conversion.md`).
    pub fn importVar(self: *Translator, imp: wasm.module.Import) Error!?Var {
        const f = self.importField(imp) orelse return null;
        var decl: asm_.VarDecl = .{ .name = f.udon_name orelse f.key, .ty = "SystemObject" };
        if (self.named_vars.get(decl.name)) |v| return v;
        applyField(f, &decl);
        return try self.declare(decl);
    }

    fn applyField(f: wasm.udon_meta.Field, decl: *asm_.VarDecl) void {
        decl.exported = f.is_export;
        if (f.sync.enabled) decl.sync = switch (f.sync.mode orelse .none) {
            .none => .none,
            .linear => .linear,
            .smooth => .smooth,
        };
        const ref_type: ?[]const u8 = f.udon_type orelse if (f.type) |ty| switch (ty) {
            .object => "SystemObject",
            .gameobject => "UnityEngineGameObject",
            .transform => "UnityEngineTransform",
            .udon_behaviour => "VRCUdonCommonInterfacesIUdonEventReceiver",
            else => null,
        } else null;
        if (ref_type) |ty| {
            decl.ty = ty;
            decl.init = .null_;
            if (f.default) |d| if (d == .string and std.mem.eql(u8, d.string, "this")) {
                decl.init = .this;
            };
        }
    }

    fn resolveGlobals(self: *Translator) Error!void {
        var globals: std.ArrayList(Global) = .empty;
        for (self.mod.imports) |imp| {
            if (imp.desc != .global) continue;
            const ty = imp.desc.global.valtype;
            const field = self.importField(imp);
            var decl: asm_.VarDecl = .{
                .name = if (field) |f| f.udon_name orelse f.key else try self.sanitized("__G__imp_{s}_{s}", .{ imp.module, imp.name }),
                .ty = Class.of(ty).udonType(),
                .init = Class.of(ty).zeroInit(),
            };
            if (field) |f| applyField(f, &decl);
            try globals.append(self.a, .{ .v = try self.declare(decl), .ty = ty });
        }
        const n_imported = globals.items.len;
        for (self.mod.globals, 0..) |g, i| {
            const idx: u32 = @intCast(n_imported + i);
            var export_name: ?[]const u8 = null;
            var field: ?wasm.udon_meta.Field = null;
            for (self.mod.exports) |e| {
                if (e.desc != .global or e.desc.global != idx) continue;
                export_name = export_name orelse e.name;
                for (self.metaFields()) |f| {
                    if (f.source.kind == .global and std.mem.eql(u8, f.source.name orelse continue, e.name)) field = f;
                }
            }
            var decl: asm_.VarDecl = .{
                .name = if (field) |f|
                    f.udon_name orelse f.key
                else if (export_name) |n|
                    try self.sanitized("__G__{s}", .{n})
                else
                    try std.fmt.allocPrint(self.a, "__G__g{d}", .{i}),
                .ty = Class.of(g.ty.valtype).udonType(),
                .init = Class.of(g.ty.valtype).zeroInit(),
            };
            // Literal initialisers where the assembler accepts them; the rest
            // is assigned by the init routine (`emitGlobalInits`).
            if (g.init.len == 1) switch (g.init[0]) {
                .i32_const => |v| decl.init = .{ .int = v },
                .f32_const => |v| if (std.math.isFinite(v)) {
                    decl.init = .{ .float = v };
                },
                else => {},
            };
            if (field) |f| applyField(f, &decl);
            try globals.append(self.a, .{ .v = try self.declare(decl), .ty = g.ty.valtype });
        }
        self.globals = globals.items;
    }

    fn emitGlobalInits(self: *Translator) Error!void {
        const n_imported = self.globals.len - self.mod.globals.len;
        for (self.mod.globals, self.globals[n_imported..]) |g, slot| {
            if (g.init.len != 1) return error.UnsupportedFeature;
            const src: Var = switch (g.init[0]) {
                .i32_const => continue,
                .f32_const => |v| if (std.math.isFinite(v)) continue else try self.constant(.{ .ty = .f32, .bits = @as(u32, @bitCast(v)) }),
                .i64_const => |v| if (v == 0) continue else try self.constant(.i64_(v)),
                .f64_const => |v| if (@as(u64, @bitCast(v)) == 0) continue else try self.constant(.{ .ty = .f64, .bits = @bitCast(v) }),
                .global_get => |src_idx| if (src_idx < n_imported) self.globals[src_idx].v else return error.InvalidModule,
                else => return error.UnsupportedFeature,
            };
            try self.copy(src, slot.v);
        }
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    fn resolveEvents(self: *Translator) Error!void {
        var events: std.ArrayList(Event) = .empty;
        if (self.meta) |m| {
            for (m.functions) |f| {
                if (f.source.kind != .@"export") continue;
                const name = f.source.name orelse continue;
                const label = f.label orelse if (f.event) |ev| switch (ev) {
                    .Start => "_start",
                    .Update => "_update",
                    .Interact => "_interact",
                    .custom => f.key,
                } else f.key;
                const func = self.exportedFunc(name) orelse return error.UnresolvedExport;
                try events.append(self.a, .{ .label = label, .func = func });
            }
        } else for (self.mod.exports) |e| {
            // Without metadata every exported function is an event named
            // after its export (`_start`, `_update`, custom events, ...).
            if (e.desc != .func or std.mem.startsWith(u8, e.name, "__udon_meta_")) continue;
            if (!udon.text.isValidName(e.name)) continue;
            try events.append(self.a, .{ .label = e.name, .func = e.desc.func });
        }
        for (events.items) |ev| {
            if (ev.func < self.func_imports.len) return error.UnsupportedFeature;
        }
        self.events = events.items;
    }

    fn emitEvents(self: *Translator, init_label: Label) Error!void {
        const inited = try self.initedFlag();
        const init_ra = try self.named("__init_lr", "SystemUInt32", .{ .uint = 0 });
        for (self.events) |ev| {
            const d = ev.func - @as(u32, @intCast(self.func_imports.len));
            const event = self.prog.newLabel();
            const body = self.prog.newLabel();
            const run_init = self.prog.newLabel();
            const done = self.prog.newLabel();
            try self.prog.exportLabel(event, ev.label);
            try self.place(event);
            // Any event may be the first one Udon delivers; initialise lazily.
            try self.jif(inited, run_init);
            try self.place(body);
            try self.copy(try self.rac(done), try self.frame(d, .lr, 0));
            try self.jump(self.entry[d]);
            try self.place(done);
            try self.halt();
            try self.place(run_init);
            try self.copy(try self.rac(body), init_ra);
            try self.jump(init_label);
        }
    }

    fn initedFlag(self: *Translator) Error!Var {
        return self.named("__inited", "SystemBoolean", .null_);
    }

    /// The one-time initialisation routine. Runs before the first event.
    fn emitInit(self: *Translator) Error!Label {
        const label = self.prog.newLabel();
        try self.place(label);
        const zero = try self.constI32(0);
        const eq = "SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean";
        _ = try self.ext(eq, &.{ zero, zero, try self.initedFlag() });

        // Everything below registers its constants before the blob is sealed.
        try self.emitWideConsts();

        if (self.has_memory) {
            const m = try self.mem();
            _ = try self.ext("SystemByteArray.__ctor__SystemInt32__SystemByteArray", &.{ try self.constI32(@intCast(self.initial_pages * page_size)), m });
            try self.emitDataSegments(m);
        }
        const one = try self.constI32(1);
        inline for (.{ .{ "__box_i32", "Int32" }, .{ "__box_i64", "Int64" }, .{ "__box_f32", "Single" }, .{ "__box_f64", "Double" }, .{ "__box_i8", "SByte" } }) |b| {
            if (self.named_vars.get(b[0])) |v|
                _ = try self.ext("System" ++ b[1] ++ "Array.__ctor__SystemInt32__System" ++ b[1] ++ "Array", &.{ one, v });
        }
        if (self.named_vars.get("__utf8")) |v| _ = try self.ext("SystemTextEncoding.__get_UTF8__SystemTextEncoding", &.{v});
        if (self.uses_call_stack) {
            _ = try self.ext("SystemObjectArray.__ctor__SystemInt32__SystemObjectArray", &.{ try self.constI32(@intCast(self.options.call_stack_depth)), try self.callStack() });
        }
        try self.emitAddressTable();
        try self.emitGlobalInits();

        const init_ra = try self.named("__init_lr", "SystemUInt32", .{ .uint = 0 });
        if (self.mod.start) |start| {
            if (start < self.func_imports.len) return error.UnsupportedFeature;
            const d = start - @as(u32, @intCast(self.func_imports.len));
            const back = self.prog.newLabel();
            try self.copy(try self.rac(back), try self.frame(d, .lr, 0));
            try self.jump(self.entry[d]);
            try self.place(back);
        }
        try self.prog.emit(.{ .jump_indirect = init_ra });
        return label;
    }

    fn emitWideConsts(self: *Translator) Error!void {
        // Constants needed by global initialisers must exist before sealing.
        for (self.mod.globals) |g| {
            if (g.init.len != 1) continue;
            switch (g.init[0]) {
                .f32_const => |v| if (!std.math.isFinite(v)) {
                    _ = try self.constant(.{ .ty = .f32, .bits = @as(u32, @bitCast(v)) });
                },
                .i64_const => |v| _ = try self.constant(.i64_(v)),
                .f64_const => |v| _ = try self.constant(.{ .ty = .f64, .bits = @bitCast(v) }),
                else => {},
            }
        }
        self.blob_sealed = true;
        if (self.wide_list.items.len == 0) return;
        const bytes = try self.named("__init_bytes", "SystemByteArray", .null_);
        _ = try self.ext("SystemConvert.__FromBase64String__SystemString__SystemByteArray", &.{ try self.base64Var("__consts", self.blob.items), bytes });
        for (self.wide_list.items) |w| {
            const sig = switch (w.c.ty) {
                .i64 => "SystemBitConverter.__ToInt64__SystemByteArray_SystemInt32__SystemInt64",
                .f32 => "SystemBitConverter.__ToSingle__SystemByteArray_SystemInt32__SystemSingle",
                .f64 => "SystemBitConverter.__ToDouble__SystemByteArray_SystemInt32__SystemDouble",
                .i32 => unreachable,
            };
            _ = try self.ext(sig, &.{ bytes, try self.constI32(@intCast(w.offset)), w.v });
        }
    }

    fn base64Var(self: *Translator, name: []const u8, bytes: []const u8) Error!Var {
        const enc = std.base64.standard.Encoder;
        const out = try self.a.alloc(u8, enc.calcSize(bytes.len));
        return self.named(name, "SystemString", .{ .string = enc.encode(out, bytes) });
    }

    /// Copy every active data segment into memory. Segment bytes travel as
    /// base64 string literals — one heap slot per chunk instead of one per word.
    fn emitDataSegments(self: *Translator, m: Var) Error!void {
        const from_b64 = "SystemConvert.__FromBase64String__SystemString__SystemByteArray";
        const copy_to = "SystemByteArray.__CopyTo__SystemArray_SystemInt32__SystemVoid";
        const chunk_bytes = data_chunk_chars / 4 * 3;
        for (self.mod.datas, 0..) |d, i| {
            const kept: ?Var = if (self.data_vars.len > 0) self.data_vars[i] else null;
            if (kept == null and (d.passive or std.mem.allEqual(u8, d.init, 0))) continue;
            const offset: u32 = if (d.passive) 0 else @bitCast(wasm.const_eval.evalConstI32(self.mod, d.offset) catch return error.UnsupportedFeature);
            if (kept) |v| {
                // `memory.init` needs the whole segment as one array.
                const name = try std.fmt.allocPrint(self.a, "__data_{d}_b64", .{i});
                _ = try self.ext(from_b64, &.{ try self.base64Var(name, d.init), v });
                if (!d.passive) _ = try self.ext(copy_to, &.{ v, m, try self.constI32(@bitCast(offset)) });
                continue;
            }
            const bytes = try self.named("__init_bytes", "SystemByteArray", .null_);
            var pos: usize = 0;
            while (pos < d.init.len) : (pos += chunk_bytes) {
                const chunk = d.init[pos..@min(pos + chunk_bytes, d.init.len)];
                const name = try std.fmt.allocPrint(self.a, "__data_{d}_{d}", .{ i, pos / chunk_bytes });
                _ = try self.ext(from_b64, &.{ try self.base64Var(name, chunk), bytes });
                _ = try self.ext(copy_to, &.{ bytes, m, try self.constI32(@bitCast(offset + @as(u32, @intCast(pos)))) });
            }
        }
    }

    // ------------------------------------------------------------------
    // Calls, tables, frames
    // ------------------------------------------------------------------

    fn analyzeCalls(self: *Translator) Error!void {
        const n = self.mod.codes.len;
        const n_imp: u32 = @intCast(self.func_imports.len);
        self.entry = try self.a.alloc(Label, n);
        for (self.entry) |*l| l.* = self.prog.newLabel();
        self.stub = try self.a.alloc(?Label, n);
        @memset(self.stub, null);
        self.frame_sizes = try self.a.alloc([Class.count]u32, n);
        @memset(self.frame_sizes, @splat(0));

        // Function table: every slot not covered by an element segment traps.
        var size: u32 = 0;
        for (self.mod.tables) |tbl| size = @max(size, tbl.limits.min);
        for (self.mod.imports) |imp| if (imp.desc == .table) {
            size = @max(size, imp.desc.table.limits.min);
        };
        var table_funcs: std.ArrayList(u32) = .empty;
        for (self.mod.elements) |el| {
            for (el.init) |func| {
                if (func < n_imp or func - n_imp >= n) return error.UnsupportedFeature;
                const d = func - n_imp;
                if (self.stub[d] == null) {
                    self.stub[d] = self.prog.newLabel();
                    try table_funcs.append(self.a, d);
                }
            }
            if (!el.active) continue;
            const off = wasm.const_eval.evalConstI32(self.mod, el.offset) catch return error.UnsupportedFeature;
            size = @max(size, @as(u32, @bitCast(off)) + @as(u32, @intCast(el.init.len)));
        }
        try self.table.appendNTimes(self.a, placeholder, size);
        for (self.mod.elements) |el| {
            if (!el.active) continue;
            const off: u32 = @bitCast(wasm.const_eval.evalConstI32(self.mod, el.offset) catch unreachable);
            for (el.init, 0..) |func, i| self.table.items[off + i] = self.stub[func - n_imp].?;
        }

        // Call graph over defined functions. A `call_indirect` may reach any
        // table function whose signature matches.
        self.callees = try self.a.alloc([]const u32, n);
        for (self.mod.codes, 0..) |code, d| {
            var list: std.ArrayList(u32) = .empty;
            try self.collectCallees(code.body, table_funcs.items, &list);
            self.callees[d] = list.items;
        }
        self.sccs = try callgraph.analyze(self.a, self.callees);
        if (self.meta) |m| if (m.options.recursion == .disabled) @memset(self.sccs.recursive, false);
    }

    fn collectCallees(self: *Translator, body: []const Instruction, table_funcs: []const u32, out: *std.ArrayList(u32)) Error!void {
        const n_imp: u32 = @intCast(self.func_imports.len);
        for (body) |ins| switch (ins) {
            .call => |f| if (f >= n_imp) try out.append(self.a, f - n_imp),
            .call_indirect => |tidx| {
                if (tidx >= self.mod.types_.len) return error.InvalidModule;
                for (table_funcs) |d| {
                    if (sameType(self.mod.types_[tidx], self.mod.types_[self.mod.funcs[d]])) try out.append(self.a, d);
                }
            },
            .block, .loop => |b| try self.collectCallees(b.body, table_funcs, out),
            .if_ => |b| {
                try self.collectCallees(b.then_body, table_funcs, out);
                if (b.else_body) |e| try self.collectCallees(e, table_funcs, out);
            },
            else => {},
        };
    }

    pub fn sameType(x: FuncType, y: FuncType) bool {
        return std.mem.eql(ValType, x.params, y.params) and std.mem.eql(ValType, x.results, y.results);
    }

    /// Does a call from `caller` to a callee of type `ty` through the table
    /// possibly re-enter `caller`?
    pub fn indirectMayRecurse(self: *const Translator, caller: u32, ty: FuncType) bool {
        if (!self.sccs.recursive[caller]) return false;
        for (self.stub, 0..) |s, d| {
            if (s != null and self.sccs.id[d] == self.sccs.id[caller] and sameType(ty, self.mod.types_[self.mod.funcs[d]])) return true;
        }
        return false;
    }

    /// The address table as a runtime `SystemUInt32Array`.
    pub fn tableVar(self: *Translator) Error!Var {
        return self.named("__table", "SystemUInt32Array", .null_);
    }

    /// Append a jump table; returns its first index in the address table.
    pub fn addJumpTable(self: *Translator, labels: []const Label) Error!u32 {
        const base: u32 = @intCast(self.table.items.len);
        try self.table.appendSlice(self.a, labels);
        return base;
    }

    fn emitAddressTable(self: *Translator) Error!void {
        const tbl = self.named_vars.get("__table") orelse return;
        const n: u32 = @intCast(self.table.items.len);
        for (self.table.items) |*l| {
            if (l.* == placeholder) l.* = self.trap_null;
        }
        const b64 = try self.named("__table_b64", "SystemString", .{ .label_table = self.table.items });
        const bytes = try self.named("__init_bytes", "SystemByteArray", .null_);
        const zero = try self.constI32(0);
        _ = try self.ext("SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array", &.{ try self.constI32(@intCast(n)), tbl });
        _ = try self.ext("SystemConvert.__FromBase64String__SystemString__SystemByteArray", &.{ b64, bytes });
        _ = try self.ext("SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid", &.{ bytes, zero, tbl, zero, try self.constI32(@intCast(n * 4)) });
    }

    pub fn callStack(self: *Translator) Error!Var {
        self.uses_call_stack = true;
        return self.named("__call_stack", "SystemObjectArray", .null_);
    }

    /// Frame slot `idx` of class `class` in defined function `func`.
    pub fn frame(self: *Translator, func: u32, class: Class, idx: u32) Error!Var {
        const ref: FrameRef = .{ .func = func, .class = class, .idx = idx };
        const size = &self.frame_sizes[func][@intFromEnum(class)];
        size.* = @max(size.*, idx + 1);
        const gop = try self.frame_ids.getOrPut(self.a, ref);
        if (!gop.found_existing) {
            gop.value_ptr.* = frame_bit | @as(Var, @intCast(self.frame_refs.items.len));
            try self.frame_refs.append(self.a, ref);
        }
        return gop.value_ptr.*;
    }

    /// Lay the frames out as a static stack and replace every frame
    /// reference by its pooled variable.
    fn resolveFrames(self: *Translator) Error!void {
        const layout = try callgraph.layoutFrames(Class.count, self.a, self.callees, self.sccs, self.frame_sizes);
        var pool: [Class.count]Var = undefined;
        inline for (0..Class.count) |c| {
            const class: Class = @enumFromInt(c);
            pool[c] = @intCast(self.prog.vars.items.len);
            for (0..layout.total[c]) |i| {
                const name = try std.fmt.allocPrint(self.a, "__{s}_{d}", .{ @tagName(class), i });
                _ = try self.declare(.{ .name = name, .ty = class.udonType(), .init = class.zeroInit() });
            }
        }
        const fix = struct {
            refs: []const FrameRef,
            pool: [Class.count]Var,
            base: []const [Class.count]u32,
            fn f(ctx: @This(), v: *Var) Error!void {
                if (v.* == placeholder) return error.InvalidModule;
                if (v.* & frame_bit == 0) return;
                const ref = ctx.refs[v.* & ~frame_bit];
                const c = @intFromEnum(ref.class);
                v.* = ctx.pool[c] + ctx.base[ref.func][c] + ref.idx;
            }
        }{ .refs = self.frame_refs.items, .pool = pool, .base = layout.base };
        for (self.prog.insts.items) |*inst| switch (inst.*) {
            .ext => |*e| for (e.args[0..e.n]) |*v| try fix.f(v),
            .copy => |*c| {
                try fix.f(&c.src);
                try fix.f(&c.dst);
            },
            .jump_if_false => |*j| try fix.f(&j.cond),
            .jump_indirect => |*v| try fix.f(v),
            else => {},
        };
    }

    // ------------------------------------------------------------------
    // Variables and constants
    // ------------------------------------------------------------------

    /// Declare a uniquely named variable.
    fn declare(self: *Translator, decl: asm_.VarDecl) Error!Var {
        const gop = try self.named_vars.getOrPut(self.a, decl.name);
        if (gop.found_existing) return error.DuplicateVariable;
        gop.value_ptr.* = try self.prog.addVar(decl);
        return gop.value_ptr.*;
    }

    /// Get or create the translator-owned variable `name`.
    pub fn named(self: *Translator, name: []const u8, ty: []const u8, init_: asm_.Init) Error!Var {
        const gop = try self.named_vars.getOrPut(self.a, name);
        if (!gop.found_existing) gop.value_ptr.* = try self.prog.addVar(.{ .name = name, .ty = ty, .init = init_ });
        return gop.value_ptr.*;
    }

    /// Scratch variable of a slot class; never live across instructions.
    pub fn tmp(self: *Translator, class: Class, n: u8) Error!Var {
        const name = try std.fmt.allocPrint(self.a, "__t_{s}_{d}", .{ @tagName(class), n });
        return self.named(name, class.udonType(), class.zeroInit());
    }

    fn sanitized(self: *Translator, comptime fmt: []const u8, args: anytype) Error![]const u8 {
        const name = try std.fmt.allocPrint(self.a, fmt, args);
        for (name) |*c| if (!std.ascii.isAlphanumeric(c.*) and c.* != '_') {
            c.* = '_';
        };
        return name;
    }

    pub fn constI32(self: *Translator, v: i32) Error!Var {
        const gop = try self.i32_consts.getOrPut(self.a, v);
        if (!gop.found_existing) {
            const name = if (v < 0)
                try std.fmt.allocPrint(self.a, "__c_i32_n{d}", .{@abs(v)})
            else
                try std.fmt.allocPrint(self.a, "__c_i32_{d}", .{v});
            gop.value_ptr.* = try self.prog.addVar(.{ .name = name, .ty = "SystemInt32", .init = .{ .int = v } });
        }
        return gop.value_ptr.*;
    }

    pub fn constant(self: *Translator, c: Const) Error!Var {
        if (c.ty == .i32) return self.constI32(c.asI32());
        const gop = try self.wide_consts.getOrPut(self.a, c);
        if (gop.found_existing) return gop.value_ptr.*;
        const class = Class.of(c.ty);
        const name = try std.fmt.allocPrint(self.a, "__c_{s}_{x}", .{ @tagName(c.ty), c.bits });
        // `null` already is zero for value types.
        gop.value_ptr.* = try self.prog.addVar(.{ .name = name, .ty = class.udonType() });
        if (c.bits != 0) {
            if (self.blob_sealed) return error.InvalidModule;
            const width: usize = if (c.ty == .f32) 4 else 8;
            try self.wide_list.append(self.a, .{ .c = c, .v = gop.value_ptr.*, .offset = @intCast(self.blob.items.len) });
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, c.bits, .little);
            try self.blob.appendSlice(self.a, buf[0..width]);
        }
        return gop.value_ptr.*;
    }

    pub fn constF64(self: *Translator, v: f64) Error!Var {
        return self.constant(.{ .ty = .f64, .bits = @bitCast(v) });
    }

    /// Interned string literal.
    pub fn string(self: *Translator, s: []const u8) Error!Var {
        const name = try std.fmt.allocPrint(self.a, "__str_{x}", .{std.hash.Wyhash.hash(0, s)});
        return self.named(name, "SystemString", .{ .string = s });
    }

    /// Return-value register `i` of a class (shared by all functions).
    pub fn retReg(self: *Translator, class: Class, i: u32) Error!Var {
        const name = try std.fmt.allocPrint(self.a, "__ret_{s}_{d}", .{ @tagName(class), i });
        return self.named(name, class.udonType(), class.zeroInit());
    }

    /// Argument register `i` of a class, used by `call_indirect`.
    pub fn argReg(self: *Translator, class: Class, i: u32) Error!Var {
        const name = try std.fmt.allocPrint(self.a, "__arg_{s}_{d}", .{ @tagName(class), i });
        return self.named(name, class.udonType(), class.zeroInit());
    }

    /// Return-address constant: a `SystemUInt32` holding `label`'s address.
    pub fn rac(self: *Translator, label: Label) Error!Var {
        const name = try std.fmt.allocPrint(self.a, "__ra_{d}", .{self.rac_count});
        self.rac_count += 1;
        return self.prog.addVar(.{ .name = name, .ty = "SystemUInt32", .init = .{ .label = label } });
    }

    // ------------------------------------------------------------------
    // Instruction emission
    // ------------------------------------------------------------------

    /// Emit an extern call; returns the instruction index.
    pub fn ext(self: *Translator, sig: []const u8, args: []const Var) Error!u32 {
        if (args.len > asm_.max_args) return error.UnsupportedFeature;
        var e: asm_.Ext = .{ .sig = try self.prog.internExtern(sig), .n = @intCast(args.len) };
        @memcpy(e.args[0..args.len], args);
        try self.prog.emit(.{ .ext = e });
        return @intCast(self.prog.insts.items.len - 1);
    }

    pub fn copy(self: *Translator, src: Var, dst: Var) Error!void {
        if (src != dst) try self.prog.emit(.{ .copy = .{ .src = src, .dst = dst } });
    }

    pub fn jump(self: *Translator, label: Label) Error!void {
        try self.prog.emit(.{ .jump = label });
    }

    /// Jump to `label` when the `SystemBoolean` `cond` is false.
    pub fn jif(self: *Translator, cond: Var, label: Label) Error!void {
        try self.prog.emit(.{ .jump_if_false = .{ .cond = cond, .target = label } });
    }

    pub fn place(self: *Translator, label: Label) Error!void {
        try self.prog.emit(.{ .label = label });
    }

    pub fn halt(self: *Translator) Error!void {
        try self.prog.emit(.halt);
    }

    pub fn comment(self: *Translator, comptime fmt: []const u8, args: anytype) Error!void {
        try self.prog.emit(.{ .comment = try std.fmt.allocPrint(self.a, fmt, args) });
    }

    /// Log `msg` as an error and end the event — the closest thing Udon has to a WASM trap.
    pub fn trap(self: *Translator, msg: []const u8) Error!void {
        _ = try self.ext("UnityEngineDebug.__LogError__SystemObject__SystemVoid", &.{try self.string(msg)});
        try self.halt();
    }
};
