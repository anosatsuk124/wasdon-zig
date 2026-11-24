//! WASM module → Udon Assembly: module-level translation.
//!
//! This file decides what exists — which functions are reachable, how they
//! are entered and left, which heap variables back globals, linear memory
//! and constants — and emits the code that is not a function body: event
//! entry points, one-time initialization, the function-table trampolines and
//! the small runtime routines. Function bodies are lowered by `lower.zig`.
//!
//! The design is specified in `docs/`:
//!   * `spec_call_return_conversion.md` — frames, calls, returns, recursion
//!   * `spec_linear_memory.md`          — linear memory as one `byte[]`
//!   * `spec_host_import_conversion.md` — imports as Udon externs
//!   * `spec_udonmeta_conversion.md`    — `__udon_meta`
//!   * `spec_heap_size.md`              — heap slots the output needs

const std = @import("std");
const wasm = @import("wasm");
const udon = @import("udon");
const callgraph = @import("callgraph.zig");
const lower = @import("lower.zig");

const Asm = udon.asm_.Asm;
const Sym = udon.asm_.Sym;
const Label = udon.asm_.Label;
const halt = udon.asm_.halt;
const nodes = udon.nodes;
const ValType = wasm.types.ValType;
const FuncType = wasm.types.FuncType;
const Instruction = wasm.Instruction;

pub const Error = error{
    /// The module needs something that cannot be expressed in Udon, or that
    /// this translator does not implement. `Diagnostics.message` says what.
    Unsupported,
    /// The module or its `__udon_meta` contradicts itself.
    Invalid,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    /// Why translation failed, when it did.
    message: []const u8 = "",
    warnings: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.arena.deinit();
    }
};

pub const Options = struct {
    /// Page limit for `memory.grow` when neither the module nor
    /// `__udon_meta.options.memory.maxPages` gives one.
    default_max_pages: u32 = 1024,
    /// Fail on imports that are not in the Udon node list instead of
    /// warning. `null` defers to `__udon_meta.options.strict`.
    strict: ?bool = null,
    /// Run the control-flow cleanup pass over the emitted code.
    optimize: bool = true,
    diagnostics: ?*Diagnostics = null,
};

pub const Stats = Asm.Stats;

/// Translate `mod` and write Udon Assembly to `writer`.
pub fn translate(
    gpa: std.mem.Allocator,
    mod: wasm.Module,
    meta: ?wasm.UdonMeta,
    writer: *std.Io.Writer,
    options: Options,
) Error!Stats {
    var t: Translator = try .init(gpa, mod, meta, options);
    defer t.deinit();
    try t.run();
    try t.a.render(writer);
    return t.a.stats();
}

pub fn udonType(vt: ValType) []const u8 {
    return switch (vt) {
        .i32 => "SystemInt32",
        .i64 => "SystemInt64",
        .f32 => "SystemSingle",
        .f64 => "SystemDouble",
    };
}

pub const RetMode = enum {
    /// `JUMP_INDIRECT` through the function's return-address slot.
    indirect,
    /// The function has exactly one call site: `JUMP` straight back to it.
    direct,
    /// Only Udon events call the function: returning ends the event.
    halt,
};

pub const Func = struct {
    name: []const u8,
    ty: FuncType,
    /// Set for imported functions.
    import: ?*const wasm.module.Import = null,
    reachable: bool = false,
    in_table: bool = false,
    direct_callers: u32 = 0,
    event_uses: u32 = 0,
    entry: Label = 0,
    ret: RetMode = .indirect,
    /// `.direct`: bound right after the single call site.
    ret_label: Label = 0,
    ra: Sym = 0,
    /// Parameter slots followed by declared-local slots.
    locals: []Sym = &.{},
    local_types: []ValType = &.{},
    trampoline: Label = 0,
};

pub const Global = struct { sym: Sym, ty: ValType };

/// An Udon variable WASM code reads or writes through function imports
/// (`__udon_meta.fields[*].source.kind = "import"`).
pub const FieldAccess = struct { sym: Sym, type_name: []const u8, is_setter: bool };

const PoolKey = struct { size: u8, bits: u64 };
const TypedConst = struct { ty: ValType, bits: u64 };
const PooledConst = struct { sym: Sym, ty: ValType, offset: u32 };
const EventBinding = struct { label: []const u8, func: u32 };
const SymbolField = struct { sym: Sym, type_name: []const u8, address: u32 };

pub const Translator = struct {
    gpa: std.mem.Allocator,
    arena_state: std.heap.ArenaAllocator,
    mod: wasm.Module,
    meta: ?wasm.UdonMeta,
    options: Options,
    a: Asm,

    funcs: []Func = &.{},
    num_imported_funcs: u32 = 0,
    globals: []Global = &.{},
    cg: callgraph.Info = undefined,
    /// Function index per table slot.
    table: []?u32 = &.{},
    table_funcs: []u32 = &.{},
    events: std.ArrayList(EventBinding) = .empty,
    field_access: std.AutoHashMapUnmanaged(u32, FieldAccess) = .empty,
    symbol_fields: std.ArrayList(SymbolField) = .empty,

    // ---- constants ----
    consts: std.AutoHashMapUnmanaged(TypedConst, Sym) = .empty,
    pooled: std.ArrayList(PooledConst) = .empty,
    pool_bytes: std.ArrayList(u8) = .empty,
    pool_offsets: std.AutoHashMapUnmanaged(PoolKey, u32) = .empty,
    pool_sym: ?Sym = null,

    // ---- linear memory ----
    mem: ?Sym = null,
    mem_pages: Sym = 0,
    initial_pages: u32 = 0,
    max_pages: u32 = 0,
    /// One-element arrays used to turn a value into bytes for stores,
    /// indexed by `ValType`.
    store_arrays: [4]?Sym = @splat(null),
    utf8: ?Sym = null,

    // ---- calls ----
    rets: std.AutoHashMapUnmanaged(struct { u32, ValType }, Sym) = .empty,
    ind_args: std.AutoHashMapUnmanaged(struct { u32, ValType }, Sym) = .empty,
    ind_ra: ?Sym = null,
    table_sym: ?Sym = null,
    halt_rac: ?Sym = null,
    rac_count: u32 = 0,
    call_stack: ?Sym = null,
    call_stack_top: Sym = 0,

    // ---- runtime routines ----
    trap_label: ?Label = null,
    grow: ?Routine = null,
    fill: ?Routine = null,
    rt_count: u32 = 0,

    pub const Routine = struct { label: Label, ra: Sym, args: [3]Sym };

    fn init(gpa: std.mem.Allocator, mod: wasm.Module, meta: ?wasm.UdonMeta, options: Options) Error!Translator {
        return .{
            .gpa = gpa,
            .arena_state = .init(gpa),
            .mod = mod,
            .meta = meta,
            .options = options,
            .a = .init(gpa),
        };
    }

    fn deinit(self: *Translator) void {
        self.a.deinit();
        self.arena_state.deinit();
    }

    /// Allocator for everything that lives as long as the translation
    /// (names, tables); freed in one go by `deinit`.
    pub fn arena(self: *Translator) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn fail(self: *Translator, err: Error, comptime fmt: []const u8, args: anytype) Error {
        if (self.options.diagnostics) |d| d.message = try std.fmt.allocPrint(d.arena.allocator(), fmt, args);
        return err;
    }

    pub fn warn(self: *Translator, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.options.diagnostics) |d| {
            const a = d.arena.allocator();
            try d.warnings.append(a, try std.fmt.allocPrint(a, fmt, args));
        }
    }

    pub fn strict(self: *const Translator) bool {
        return self.options.strict orelse if (self.meta) |m| m.options.strict else false;
    }

    pub fn name(self: *Translator, comptime fmt: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.allocPrint(self.arena(), fmt, args);
    }

    // ------------------------------------------------------------------
    //  Pipeline
    // ------------------------------------------------------------------

    fn run(self: *Translator) Error!void {
        try self.collectFunctions();
        try self.collectTable();
        self.cg = callgraph.analyze(self.arena(), self.mod, self.num_imported_funcs, self.table_funcs) catch return error.OutOfMemory;
        try self.collectEvents();
        try self.markReachable();
        try self.declareMemory();
        try self.declareGlobals();
        try self.declareFields();
        try self.planFunctions();

        for (self.funcs, 0..) |*f, i| {
            if (f.import != null or !f.reachable) continue;
            try lower.lowerFunction(self, @intCast(i));
        }
        try self.emitTrampolines();
        try self.emitEvents();
        try self.emitRuntime();
        if (self.options.optimize) try self.a.optimize();
    }

    // ------------------------------------------------------------------
    //  Functions, table, events
    // ------------------------------------------------------------------

    fn collectFunctions(self: *Translator) Error!void {
        const a = self.arena();
        var n_imp: u32 = 0;
        for (self.mod.imports) |imp| if (imp.desc == .func) {
            n_imp += 1;
        };
        self.num_imported_funcs = n_imp;
        const total = n_imp + self.mod.codes.len;
        self.funcs = try a.alloc(Func, total);

        const debug_names = try wasm.module.functionNames(a, self.mod, @intCast(total));
        var used: std.StringHashMapUnmanaged(void) = .empty;
        var i: u32 = 0;
        for (self.mod.imports) |*imp| switch (imp.desc) {
            .func => |t| {
                if (t >= self.mod.types_.len) return self.fail(error.Invalid, "import {s} has type index {d} out of range", .{ imp.name, t });
                self.funcs[i] = .{ .name = imp.name, .ty = self.mod.types_[t], .import = imp };
                i += 1;
            },
            else => {},
        };
        for (self.mod.funcs, 0..) |t, def| {
            const idx: u32 = n_imp + @as(u32, @intCast(def));
            if (t >= self.mod.types_.len) return self.fail(error.Invalid, "function {d} has type index {d} out of range", .{ idx, t });
            var base: []const u8 = "";
            for (self.mod.exports) |e| if (e.desc == .func and e.desc.func == idx) {
                base = e.name;
                break;
            };
            if (base.len == 0 and idx < debug_names.len) base = debug_names[idx];
            var clean = try sanitize(a, base);
            if (clean.len == 0 or used.contains(clean)) clean = try self.name("{s}{s}f{d}", .{ clean, if (clean.len == 0) "" else "_", idx });
            try used.put(a, clean, {});
            self.funcs[idx] = .{ .name = clean, .ty = self.mod.types_[t] };
        }
    }

    /// Reduce a WASM name to the characters Udon accepts in a variable name
    /// (`docs/udon_specs.md` §4.4), bounded so mangled names stay readable.
    fn sanitize(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
        const max = 40;
        const out = try a.alloc(u8, @min(raw.len, max));
        for (out, raw[0..out.len]) |*o, c| o.* = if (std.ascii.isAlphanumeric(c)) c else '_';
        return out;
    }

    fn collectTable(self: *Translator) Error!void {
        const a = self.arena();
        var size: u32 = if (self.mod.tables.len != 0) self.mod.tables[0].limits.min else 0;
        for (self.mod.imports) |imp| if (imp.desc == .table) {
            size = imp.desc.table.limits.min;
        };
        var list: std.ArrayList(u32) = .empty;
        var slots: std.ArrayList(?u32) = .empty;
        try slots.appendNTimes(a, null, size);
        for (self.mod.elements) |e| {
            if (!e.active) continue;
            const off_i = wasm.const_eval.evalConstI32(self.mod, e.offset) catch
                return self.fail(error.Unsupported, "element segment offset is not a constant", .{});
            const off: u32 = @bitCast(off_i);
            if (off + e.init.len > slots.items.len) try slots.appendNTimes(a, null, off + e.init.len - slots.items.len);
            for (e.init, 0..) |f, k| {
                if (f >= self.funcs.len) return self.fail(error.Invalid, "element segment names function {d}, which does not exist", .{f});
                slots.items[off + k] = f;
                if (!self.funcs[f].in_table) {
                    self.funcs[f].in_table = true;
                    try list.append(a, f);
                }
            }
        }
        self.table = slots.items;
        self.table_funcs = list.items;
    }

    fn findExportedFunc(self: *const Translator, export_name: []const u8) ?u32 {
        for (self.mod.exports) |e| {
            if (e.desc == .func and std.mem.eql(u8, e.name, export_name)) return e.desc.func;
        }
        return null;
    }

    fn collectEvents(self: *Translator) Error!void {
        const a = self.arena();
        const bound = if (self.meta) |m| m.functions.len != 0 else false;
        if (bound) {
            for (self.meta.?.functions) |f| {
                if (!f.is_export and f.label == null) continue;
                const export_name = f.source.name orelse return self.fail(error.Invalid, "__udon_meta function '{s}' has no source name", .{f.key});
                const idx = self.findExportedFunc(export_name) orelse {
                    const policy = self.meta.?.options.unknown_function_policy orelse .warn;
                    if (policy == .error_ or self.strict())
                        return self.fail(error.Invalid, "__udon_meta function '{s}' names export '{s}', which the module does not have", .{ f.key, export_name });
                    if (policy == .warn) try self.warn("__udon_meta function '{s}': no export named '{s}'", .{ f.key, export_name });
                    continue;
                };
                const label = f.label orelse if (f.event) |ev| switch (ev) {
                    .Start => "_start",
                    .Update => "_update",
                    .Interact => "_interact",
                    .custom => return self.fail(error.Invalid, "__udon_meta function '{s}': a custom event needs a label", .{f.key}),
                } else export_name;
                try self.events.append(a, .{ .label = label, .func = idx });
            }
        } else {
            // No explicit bindings: every exported nullary function that is
            // a legal Udon label becomes an event of the same name.
            for (self.mod.exports) |e| {
                if (e.desc != .func) continue;
                const f = self.funcs[e.desc.func];
                if (f.import != null or f.ty.params.len != 0 or f.ty.results.len != 0) continue;
                if (std.mem.startsWith(u8, e.name, "__udon_meta")) continue;
                if (!udon.check.isValidName(e.name)) continue;
                if (e.name[0] == '_' and !nodes.isStandardEvent(e.name)) continue;
                try self.events.append(a, .{ .label = e.name, .func = e.desc.func });
            }
        }
        for (self.events.items) |ev| {
            const f = &self.funcs[ev.func];
            if (f.import != null) return self.fail(error.Invalid, "event '{s}' is bound to an imported function", .{ev.label});
            if (f.ty.params.len != 0) return self.fail(error.Unsupported, "event '{s}' is bound to a function that takes parameters", .{ev.label});
            if (!udon.check.isValidName(ev.label)) return self.fail(error.Invalid, "'{s}' is not a valid Udon label", .{ev.label});
            f.event_uses += 1;
        }
    }

    fn markReachable(self: *Translator) Error!void {
        var work: std.ArrayList(u32) = .empty;
        const a = self.arena();
        for (self.events.items) |ev| try work.append(a, ev.func);
        if (self.mod.start) |s| try work.append(a, s);
        while (work.pop()) |f| {
            if (self.funcs[f].reachable) continue;
            self.funcs[f].reachable = true;
            for (self.cg.callees(f)) |e| {
                if (e.direct) self.funcs[e.callee].direct_callers += 1;
                if (!self.funcs[e.callee].reachable) try work.append(a, e.callee);
            }
        }
    }

    fn planFunctions(self: *Translator) Error!void {
        const a = self.arena();
        for (self.funcs, 0..) |*f, i| {
            if (f.import != null or !f.reachable) continue;
            const code = self.mod.codes[i - self.num_imported_funcs];
            var n_locals: usize = f.ty.params.len;
            for (code.locals) |g| n_locals += g.count;
            f.local_types = try a.alloc(ValType, n_locals);
            f.locals = try a.alloc(Sym, n_locals);
            @memcpy(f.local_types[0..f.ty.params.len], f.ty.params);
            var k: usize = f.ty.params.len;
            for (code.locals) |g| {
                @memset(f.local_types[k..][0..g.count], g.ty);
                k += g.count;
            }
            for (f.locals, f.local_types, 0..) |*s, ty, li| {
                s.* = try self.a.declare(.{
                    .name = try self.name("__{s}_{c}{d}__", .{ f.name, @as(u8, if (li < f.ty.params.len) 'P' else 'L'), li }),
                    .type_name = udonType(ty),
                    .init = zeroInit(ty),
                });
            }
            f.entry = try self.a.newLabel();
            const is_start = if (self.mod.start) |s| s == i else false;
            const starts: u32 = @intFromBool(is_start);
            if (!f.in_table and f.event_uses == 0 and f.direct_callers + starts == 1) {
                f.ret = .direct;
                f.ret_label = try self.a.newLabel();
            } else if (!f.in_table and f.direct_callers == 0 and !is_start) {
                f.ret = .halt;
            } else {
                f.ret = .indirect;
                f.ra = try self.a.declare(.{ .name = try self.name("__{s}_RA__", .{f.name}), .type_name = "SystemUInt32", .init = .{ .uint32 = 0 } });
            }
        }
    }

    fn zeroInit(ty: ValType) udon.asm_.Init {
        return switch (ty) {
            .i32 => .{ .int32 = 0 },
            .f32 => .{ .single = 0 },
            // Int64 and Double accept no literal; null gives default(T).
            .i64, .f64 => .null_,
        };
    }

    pub fn funcType(self: *const Translator, type_index: u32) FuncType {
        return self.mod.types_[type_index];
    }

    /// Whether calls from `caller` to `callee` must save `caller`'s frame.
    pub fn mayReenter(self: *const Translator, caller: u32, callee: u32) bool {
        if (self.meta) |m| if (m.options.recursion == .disabled) return false;
        return self.cg.mayReenter(caller, callee);
    }

    // ------------------------------------------------------------------
    //  Linear memory, globals, fields
    // ------------------------------------------------------------------

    fn memoryLimits(self: *const Translator) ?wasm.types.Limits {
        if (self.mod.memories.len != 0) return self.mod.memories[0];
        for (self.mod.imports) |imp| if (imp.desc == .memory) return imp.desc.memory;
        return null;
    }

    fn declareMemory(self: *Translator) Error!void {
        const limits = self.memoryLimits() orelse return;
        const opts: wasm.udon_meta.MemoryOptions = if (self.meta) |m| m.options.memory else .{};

        // The initial size must cover what the module declares and every
        // byte its data segments initialize.
        var data_end: u64 = 0;
        for (self.mod.datas) |d| {
            if (d.passive) continue;
            const off = wasm.const_eval.evalConstI32(self.mod, d.offset) catch
                return self.fail(error.Unsupported, "data segment offset is not a constant", .{});
            data_end = @max(data_end, @as(u64, @as(u32, @bitCast(off))) + d.init.len);
        }
        const data_pages: u32 = @intCast((data_end + 0xFFFF) >> 16);
        self.initial_pages = @max(opts.initial_pages orelse limits.min, @max(limits.min, data_pages));
        self.max_pages = @max(opts.max_pages orelse limits.max orelse self.options.default_max_pages, self.initial_pages);
        // The backing array is indexed by Int32.
        if (self.max_pages > 0x7FFF) self.max_pages = 0x7FFF;
        if (self.initial_pages > self.max_pages) return self.fail(error.Unsupported, "linear memory of {d} pages exceeds what one byte[] can hold", .{self.initial_pages});

        const base = opts.udon_name orelse "__G__memory";
        self.mem = try self.a.declare(.{ .name = base, .type_name = "SystemByteArray" });
        self.mem_pages = try self.a.declare(.{
            .name = try self.name("{s}_size_pages", .{base}),
            .type_name = "SystemInt32",
            .init = .{ .int32 = @intCast(self.initial_pages) },
        });
    }

    fn metaFieldFor(self: *const Translator, kind: wasm.udon_meta.SourceKind, source_name: []const u8) ?wasm.udon_meta.Field {
        const m = self.meta orelse return null;
        for (m.fields) |f| {
            if (f.source.kind != kind) continue;
            if (f.source.name) |n| if (std.mem.eql(u8, n, source_name)) return f;
        }
        return null;
    }

    fn applyFieldAttributes(self: *Translator, v: *udon.asm_.Var, f: wasm.udon_meta.Field) Error!void {
        v.is_export = f.is_export;
        if (f.sync.enabled) v.sync = switch (f.sync.mode.?) {
            .none => .none,
            .linear => .linear,
            .smooth => .smooth,
        };
        const t = v.type_name;
        const dv = f.default orelse return;
        switch (dv) {
            .null => {},
            .integer => |x| {
                if (std.mem.eql(u8, t, "SystemInt32")) {
                    v.init = .{ .int32 = std.math.cast(i32, x) orelse return self.fail(error.Invalid, "field '{s}': default {d} does not fit Int32", .{ f.key, x }) };
                } else if (std.mem.eql(u8, t, "SystemUInt32")) {
                    v.init = .{ .uint32 = std.math.cast(u32, x) orelse return self.fail(error.Invalid, "field '{s}': default {d} does not fit UInt32", .{ f.key, x }) };
                } else if (std.mem.eql(u8, t, "SystemSingle")) {
                    v.init = .{ .single = @floatFromInt(x) };
                } else return self.fail(error.Invalid, "field '{s}': Udon Assembly cannot give a {s} a numeric default", .{ f.key, t });
            },
            .float => |x| {
                if (!std.mem.eql(u8, t, "SystemSingle")) return self.fail(error.Invalid, "field '{s}': a fractional default needs type float", .{f.key});
                v.init = .{ .single = @floatCast(x) };
            },
            .string => |s| {
                if (std.mem.eql(u8, s, "this")) {
                    v.init = .this;
                } else if (std.mem.eql(u8, t, "SystemString")) {
                    v.init = .{ .string = s };
                } else return self.fail(error.Invalid, "field '{s}': a string default needs type string (or \"this\")", .{f.key});
            },
            else => return self.fail(error.Invalid, "field '{s}': unsupported default value", .{f.key}),
        }
    }

    fn fieldType(self: *Translator, f: wasm.udon_meta.Field, fallback: []const u8) Error![]const u8 {
        const t = f.type_name orelse return fallback;
        if (!nodes.isType(t)) return self.fail(error.Invalid, "field '{s}': '{s}' is not an Udon type name", .{ f.key, t });
        return t;
    }

    fn declareGlobals(self: *Translator) Error!void {
        const a = self.arena();
        var n_imp: u32 = 0;
        for (self.mod.imports) |imp| if (imp.desc == .global) {
            n_imp += 1;
        };
        self.globals = try a.alloc(Global, n_imp + self.mod.globals.len);

        var i: u32 = 0;
        for (self.mod.imports) |imp| switch (imp.desc) {
            .global => |gt| {
                var v: udon.asm_.Var = .{
                    .name = try self.name("__G__imp_{s}", .{try sanitize(a, imp.name)}),
                    .type_name = udonType(gt.valtype),
                    .init = zeroInit(gt.valtype),
                };
                if (self.metaFieldFor(.import, imp.name)) |f| {
                    if (f.udon_name) |un| v.name = un;
                    v.type_name = try self.fieldType(f, v.type_name);
                    if (!std.mem.eql(u8, v.type_name, udonType(gt.valtype))) v.init = .null_;
                    try self.applyFieldAttributes(&v, f);
                }
                self.globals[i] = .{ .sym = try self.declareUnique(v), .ty = gt.valtype };
                i += 1;
            },
            else => {},
        };

        for (self.mod.globals, 0..) |g, def| {
            const idx: u32 = n_imp + @as(u32, @intCast(def));
            var export_name: ?[]const u8 = null;
            for (self.mod.exports) |e| if (e.desc == .global and e.desc.global == idx) {
                export_name = e.name;
                break;
            };
            var v: udon.asm_.Var = .{
                .name = if (export_name) |en| try self.name("__G__{s}", .{try sanitize(a, en)}) else try self.name("__G__g{d}", .{idx}),
                .type_name = udonType(g.ty.valtype),
                .init = zeroInit(g.ty.valtype),
            };
            // A literal initial value where the assembler accepts one;
            // everything else is assigned by the init routine.
            if (g.init.len == 1) switch (g.init[0]) {
                .i32_const => |x| v.init = .{ .int32 = x },
                .f32_const => |x| if (exactSingle(x)) {
                    v.init = .{ .single = x };
                },
                else => {},
            };
            if (export_name) |en| if (self.metaFieldFor(.global, en)) |f| {
                if (f.udon_name) |un| v.name = un;
                const want = try self.fieldType(f, v.type_name);
                if (!std.mem.eql(u8, want, v.type_name))
                    return self.fail(error.Invalid, "field '{s}': global '{s}' is {s}, not {s}", .{ f.key, en, v.type_name, want });
                try self.applyFieldAttributes(&v, f);
            };
            self.globals[idx] = .{ .sym = try self.declareUnique(v), .ty = g.ty.valtype };
        }
    }

    fn declareUnique(self: *Translator, v: udon.asm_.Var) Error!Sym {
        if (!udon.check.isValidName(v.name)) return self.fail(error.Invalid, "'{s}' is not a valid Udon variable name", .{v.name});
        if (self.a.find(v.name) != null) return self.fail(error.Invalid, "Udon variable name '{s}' is used twice", .{v.name});
        return self.a.declare(v);
    }

    fn findImportedFunc(self: *const Translator, module_name: ?[]const u8, import_name: []const u8) ?u32 {
        for (self.funcs[0..self.num_imported_funcs], 0..) |f, i| {
            const imp = f.import.?;
            if (!std.mem.eql(u8, imp.name, import_name)) continue;
            if (module_name) |mn| if (!std.mem.eql(u8, mn, imp.module)) continue;
            return @intCast(i);
        }
        return null;
    }

    /// Fields backed by function imports (a getter and optionally a setter)
    /// and fields backed by an address in linear memory.
    fn declareFields(self: *Translator) Error!void {
        const m = self.meta orelse return;
        const a = self.arena();
        for (m.fields) |f| {
            const source_name = f.source.name orelse return self.fail(error.Invalid, "__udon_meta field '{s}' has no source name", .{f.key});
            switch (f.source.kind) {
                .global => {
                    var found = false;
                    for (self.mod.exports) |e| if (e.desc == .global and std.mem.eql(u8, e.name, source_name)) {
                        found = true;
                    };
                    if (!found) try self.unknownField(f, "no exported global");
                },
                .import => {
                    const getter = self.findImportedFunc(f.source.module, source_name);
                    const setter = if (f.source.setter) |sn| self.findImportedFunc(f.source.module, sn) else null;
                    var is_global_import = false;
                    for (self.mod.imports) |imp| if (imp.desc == .global and std.mem.eql(u8, imp.name, source_name)) {
                        is_global_import = true;
                    };
                    if (is_global_import) continue;
                    if (getter == null and setter == null) {
                        try self.unknownField(f, "no import");
                        continue;
                    }
                    var v: udon.asm_.Var = .{ .name = f.udon_name orelse f.key, .type_name = try self.fieldType(f, "SystemObject") };
                    if (std.mem.eql(u8, v.type_name, "SystemInt32")) v.init = .{ .int32 = 0 };
                    if (std.mem.eql(u8, v.type_name, "SystemSingle")) v.init = .{ .single = 0 };
                    try self.applyFieldAttributes(&v, f);
                    // A field may name the linear memory itself, which lets
                    // WASM code hand the byte[] to externs.
                    const sym = self.a.find(v.name) orelse try self.declareUnique(v);
                    if (getter) |g| try self.field_access.put(a, g, .{ .sym = sym, .type_name = v.type_name, .is_setter = false });
                    if (setter) |s| try self.field_access.put(a, s, .{ .sym = sym, .type_name = v.type_name, .is_setter = true });
                },
                .symbol => {
                    const addr = wasm.const_eval.evalExportedI32(self.mod, source_name) catch null orelse {
                        try self.unknownField(f, "no exported address");
                        continue;
                    };
                    var v: udon.asm_.Var = .{ .name = f.udon_name orelse f.key, .type_name = try self.fieldType(f, "SystemInt32") };
                    const int = std.mem.eql(u8, v.type_name, "SystemInt32");
                    if (!int and !std.mem.eql(u8, v.type_name, "SystemSingle"))
                        return self.fail(error.Unsupported, "field '{s}': a memory-backed field must be int or float", .{f.key});
                    v.init = if (int) .{ .int32 = 0 } else .{ .single = 0 };
                    try self.applyFieldAttributes(&v, f);
                    try self.symbol_fields.append(a, .{ .sym = try self.declareUnique(v), .type_name = v.type_name, .address = @bitCast(addr) });
                },
                else => return self.fail(error.Invalid, "__udon_meta field '{s}': source kind is not valid for a field", .{f.key}),
            }
        }
    }

    fn unknownField(self: *Translator, f: wasm.udon_meta.Field, what: []const u8) Error!void {
        const policy = self.meta.?.options.unknown_field_policy orelse .warn;
        if (policy == .error_ or self.strict())
            return self.fail(error.Invalid, "__udon_meta field '{s}': {s} named '{s}'", .{ f.key, what, f.source.name.? });
        if (policy == .warn) try self.warn("__udon_meta field '{s}': {s} named '{s}'", .{ f.key, what, f.source.name.? });
    }

    // ------------------------------------------------------------------
    //  Constants
    // ------------------------------------------------------------------

    /// True when the decimal the writer prints for `x` denotes exactly `x`,
    /// so the assembler reads back the same float whatever rounding its
    /// parser uses.
    fn exactSingle(x: f32) bool {
        if (!std.math.isFinite(x)) return false;
        if (x == 0) return !std.math.signbit(x);
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return false;
        const back = std.fmt.parseFloat(f64, text) catch return false;
        return back == @as(f64, x) and text.len <= 12;
    }

    pub fn constI32(self: *Translator, x: i32) Error!Sym {
        return self.constSym(.i32, @as(u32, @bitCast(x)));
    }

    /// A read-only variable holding the constant. Int32 and exactly
    /// printable Single constants are literals; Int64, Double and the
    /// remaining Single values cannot be written as literals and are read
    /// out of the constant pool by the init routine.
    pub fn constSym(self: *Translator, ty: ValType, bits: u64) Error!Sym {
        const gop = try self.consts.getOrPut(self.arena(), .{ .ty = ty, .bits = bits });
        if (gop.found_existing) return gop.value_ptr.*;
        var v: udon.asm_.Var = .{ .name = "", .type_name = udonType(ty), .init = zeroInit(ty) };
        var pooled = false;
        switch (ty) {
            .i32 => {
                const x: i32 = @bitCast(@as(u32, @truncate(bits)));
                v.name = if (x < 0) try self.name("__c_i32_n{d}", .{-@as(i64, x)}) else try self.name("__c_i32_{d}", .{x});
                v.init = .{ .int32 = x };
            },
            .f32 => {
                const x: f32 = @bitCast(@as(u32, @truncate(bits)));
                v.name = try self.name("__c_f32_{x}", .{bits});
                if (exactSingle(x)) v.init = .{ .single = x } else pooled = true;
            },
            .i64, .f64 => {
                v.name = try self.name("__c_{t}_{x}", .{ ty, bits });
                pooled = bits != 0;
            },
        }
        const sym = try self.a.declare(v);
        // `gop` may be stale after `poolOffset` grows other tables; re-put.
        try self.consts.put(self.arena(), .{ .ty = ty, .bits = bits }, sym);
        if (pooled) try self.pooled.append(self.arena(), .{ .sym = sym, .ty = ty, .offset = try self.poolOffset(byteSize(ty), bits) });
        return sym;
    }

    pub fn byteSize(ty: ValType) u8 {
        return switch (ty) {
            .i32, .f32 => 4,
            .i64, .f64 => 8,
        };
    }

    /// Offset of the little-endian image of `bits` in the constant pool.
    pub fn poolOffset(self: *Translator, size: u8, bits: u64) Error!u32 {
        const a = self.arena();
        const gop = try self.pool_offsets.getOrPut(a, .{ .size = size, .bits = bits });
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.pool_bytes.items.len);
            var raw: [8]u8 = undefined;
            std.mem.writeInt(u64, &raw, bits, .little);
            try self.pool_bytes.appendSlice(a, raw[0..size]);
        }
        return gop.value_ptr.*;
    }

    /// The decoded constant pool (`byte[]`).
    pub fn poolSym(self: *Translator) Error!Sym {
        if (self.pool_sym == null) self.pool_sym = try self.a.declare(.{ .name = "__kpool", .type_name = "SystemByteArray" });
        return self.pool_sym.?;
    }

    // ------------------------------------------------------------------
    //  Shared slots
    // ------------------------------------------------------------------

    /// Register a function leaves its `index`-th result in.
    pub fn retSym(self: *Translator, index: u32, ty: ValType) Error!Sym {
        const gop = try self.rets.getOrPut(self.arena(), .{ index, ty });
        if (!gop.found_existing) gop.value_ptr.* = try self.a.declare(.{
            .name = try self.name("__ret{d}_{t}", .{ index, ty }),
            .type_name = udonType(ty),
            .init = zeroInit(ty),
        });
        return gop.value_ptr.*;
    }

    /// Slot an indirect caller leaves its `index`-th argument in.
    pub fn indArg(self: *Translator, index: u32, ty: ValType) Error!Sym {
        const gop = try self.ind_args.getOrPut(self.arena(), .{ index, ty });
        if (!gop.found_existing) gop.value_ptr.* = try self.a.declare(.{
            .name = try self.name("__ia{d}_{t}", .{ index, ty }),
            .type_name = udonType(ty),
            .init = zeroInit(ty),
        });
        return gop.value_ptr.*;
    }

    pub fn indRa(self: *Translator) Error!Sym {
        if (self.ind_ra == null) self.ind_ra = try self.a.declare(.{ .name = "__ind_RA", .type_name = "SystemUInt32", .init = .{ .uint32 = 0 } });
        return self.ind_ra.?;
    }

    pub fn tableSym(self: *Translator) Error!Sym {
        if (self.table_sym == null) self.table_sym = try self.a.declare(.{ .name = "__table", .type_name = "SystemUInt32Array" });
        return self.table_sym.?;
    }

    /// A fresh constant holding the address of `target`.
    pub fn newRac(self: *Translator, target: Label) Error!Sym {
        self.rac_count += 1;
        return self.a.declare(.{
            .name = try self.name("__ra_{d}", .{self.rac_count}),
            .type_name = "SystemUInt32",
            .init = .{ .address = target },
        });
    }

    pub fn storeArray(self: *Translator, ty: ValType) Error!Sym {
        const slot = &self.store_arrays[storeIndex(ty)];
        if (slot.* == null) slot.* = try self.a.declare(.{
            .name = try self.name("__st_{t}", .{ty}),
            .type_name = switch (ty) {
                .i32 => "SystemInt32Array",
                .i64 => "SystemInt64Array",
                .f32 => "SystemSingleArray",
                .f64 => "SystemDoubleArray",
            },
        });
        return slot.*.?;
    }

    fn storeIndex(ty: ValType) usize {
        return switch (ty) {
            .i32 => 0,
            .i64 => 1,
            .f32 => 2,
            .f64 => 3,
        };
    }

    pub fn utf8Sym(self: *Translator) Error!Sym {
        if (self.utf8 == null) self.utf8 = try self.a.declare(.{ .name = "__utf8", .type_name = "SystemObject" });
        return self.utf8.?;
    }

    pub fn callStack(self: *Translator) Error!Sym {
        if (self.call_stack == null) {
            self.call_stack = try self.a.declare(.{ .name = "__call_stack", .type_name = "SystemObjectArray" });
            self.call_stack_top = try self.a.declare(.{ .name = "__call_stack_top", .type_name = "SystemInt32", .init = .{ .int32 = 0 } });
        }
        return self.call_stack.?;
    }

    pub fn trapLabel(self: *Translator) Error!Label {
        if (self.trap_label == null) self.trap_label = try self.a.newLabel();
        return self.trap_label.?;
    }

    fn rtVar(self: *Translator, type_name: []const u8) Error!Sym {
        self.rt_count += 1;
        const initial: udon.asm_.Init = if (std.mem.eql(u8, type_name, "SystemInt32")) .{ .int32 = 0 } else if (std.mem.eql(u8, type_name, "SystemUInt32")) .{ .uint32 = 0 } else .null_;
        return self.a.declare(.{ .name = try self.name("__rt_{d}", .{self.rt_count}), .type_name = type_name, .init = initial });
    }

    fn newRoutine(self: *Translator) Error!Routine {
        return .{
            .label = try self.a.newLabel(),
            .ra = try self.rtVar("SystemUInt32"),
            .args = .{ try self.rtVar("SystemInt32"), try self.rtVar("SystemInt32"), try self.rtVar("SystemInt32") },
        };
    }

    pub fn growRoutine(self: *Translator) Error!Routine {
        if (self.grow == null) self.grow = try self.newRoutine();
        return self.grow.?;
    }

    pub fn fillRoutine(self: *Translator) Error!Routine {
        if (self.fill == null) {
            self.fill = try self.newRoutine();
            // The routine writes its first byte through the i32 store array,
            // which must exist before the init routine is emitted.
            _ = try self.storeArray(.i32);
        }
        return self.fill.?;
    }

    // ------------------------------------------------------------------
    //  Emitted code outside function bodies
    // ------------------------------------------------------------------

    /// Entry points for indirect calls: move the shared argument slots into
    /// the function's own parameters and fall into its body.
    fn emitTrampolines(self: *Translator) Error!void {
        if (self.table_sym == null) return;
        for (self.table_funcs) |fi| {
            const f = &self.funcs[fi];
            if (f.import != null) return self.fail(error.Unsupported, "imported function '{s}' is in the function table", .{f.name});
            if (!f.reachable) continue;
            f.trampoline = try self.a.newLabel();
            self.a.bind(f.trampoline);
            for (f.ty.params, 0..) |ty, k| try self.a.copy(try self.indArg(@intCast(k), ty), f.locals[k]);
            try self.a.copy(try self.indRa(), f.ra);
            try self.a.jump(f.entry);
        }
    }

    fn emitEvents(self: *Translator) Error!void {
        const a = self.arena();
        // Every event checks that initialization ran, so nothing depends on
        // which event Udon happens to deliver first.
        const init_label = try self.a.newLabel();
        const init_ra = try self.a.declare(.{ .name = "__init_RA", .type_name = "SystemUInt32", .init = .{ .uint32 = 0 } });
        const inited = try self.a.declare(.{ .name = "__inited", .type_name = "SystemBoolean" });
        const Stub = struct { label: Label, body: Label };
        var stubs: std.ArrayList(Stub) = .empty;

        for (self.events.items) |ev| {
            const f = &self.funcs[ev.func];
            _ = try self.a.exportHere(ev.label);
            const stub: Stub = .{ .label = try self.a.newLabel(), .body = try self.a.newLabel() };
            try stubs.append(a, stub);
            try self.a.jumpIfFalse(inited, stub.label);
            self.a.bind(stub.body);
            switch (f.ret) {
                .halt => {},
                .indirect => {
                    if (self.halt_rac == null) self.halt_rac = try self.a.declare(.{
                        .name = "__ra_halt",
                        .type_name = "SystemUInt32",
                        .init = .{ .address = halt },
                    });
                    try self.a.copy(self.halt_rac.?, f.ra);
                },
                .direct => unreachable,
            }
            try self.a.jump(f.entry);
        }
        for (stubs.items) |s| {
            self.a.bind(s.label);
            try self.a.copy(try self.newRac(s.body), init_ra);
            try self.a.jump(init_label);
        }

        self.a.bind(init_label);
        try self.emitInit(inited);
        try self.a.jumpIndirect(init_ra);
    }

    fn emitInit(self: *Translator, inited: Sym) Error!void {
        const a = &self.a;
        const c0 = try self.constI32(0);
        for (self.symbol_fields.items) |sf| _ = try self.storeArray(symbolFieldType(sf));
        // `true` cannot be written as a literal; compute it.
        try a.call("SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean", &.{ c0, c0, inited });

        const from_b64 = "SystemConvert.__FromBase64String__SystemString__SystemByteArray";
        const block_copy = "SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid";

        if (self.mem) |mem| {
            try a.call("SystemByteArray.__ctor__SystemInt32__SystemByteArray", &.{ try self.constI32(@intCast(self.initial_pages << 16)), mem });
            var scratch: ?Sym = null;
            for (self.mod.datas, 0..) |d, i| {
                if (d.passive) return self.fail(error.Unsupported, "passive data segments are not supported", .{});
                // Fresh memory is zero, so zero bytes at either end need no copy.
                var start: usize = 0;
                var end: usize = d.init.len;
                while (start < end and d.init[start] == 0) start += 1;
                while (end > start and d.init[end - 1] == 0) end -= 1;
                if (start == end) continue;
                const off: u32 = @bitCast(wasm.const_eval.evalConstI32(self.mod, d.offset) catch unreachable);
                const text = try encodeBase64(self.arena(), d.init[start..end]);
                const src = try a.declare(.{ .name = try self.name("__data_{d}", .{i}), .type_name = "SystemString", .init = .{ .string = text } });
                if (scratch == null) scratch = try a.declare(.{ .name = "__data_bytes", .type_name = "SystemByteArray" });
                try a.call(from_b64, &.{ src, scratch.? });
                try a.call(block_copy, &.{ scratch.?, c0, mem, try self.constI32(@intCast(off + start)), try self.constI32(@intCast(end - start)) });
            }
        }

        if (self.pool_sym != null or self.pooled.items.len != 0) {
            const pool = try self.poolSym();
            const text = try encodeBase64(self.arena(), self.pool_bytes.items);
            const src = try a.declare(.{ .name = "__kpool_b64", .type_name = "SystemString", .init = .{ .string = text } });
            try a.call(from_b64, &.{ src, pool });
            for (self.pooled.items) |k| try a.call(switch (k.ty) {
                .i32 => unreachable,
                .i64 => "SystemBitConverter.__ToInt64__SystemByteArray_SystemInt32__SystemInt64",
                .f32 => "SystemBitConverter.__ToSingle__SystemByteArray_SystemInt32__SystemSingle",
                .f64 => "SystemBitConverter.__ToDouble__SystemByteArray_SystemInt32__SystemDouble",
            }, &.{ pool, try self.constI32(@intCast(k.offset)), k.sym });
        }

        const c1 = try self.constI32(1);
        const array_ctors = [4][]const u8{
            "SystemInt32Array.__ctor__SystemInt32__SystemInt32Array",
            "SystemInt64Array.__ctor__SystemInt32__SystemInt64Array",
            "SystemSingleArray.__ctor__SystemInt32__SystemSingleArray",
            "SystemDoubleArray.__ctor__SystemInt32__SystemDoubleArray",
        };
        for (self.store_arrays, array_ctors) |slot, ctor| if (slot) |s| try a.call(ctor, &.{ c1, s });
        if (self.utf8) |s| try a.call("SystemTextEncoding.__get_UTF8__SystemTextEncoding", &.{s});
        if (self.call_stack) |s| {
            const size: u32 = if (self.meta) |m| m.options.call_stack_size orelse 4096 else 4096;
            try a.call("SystemObjectArray.__ctor__SystemInt32__SystemObjectArray", &.{ try self.constI32(@intCast(size)), s });
        }

        if (self.table_sym) |tbl| {
            const labels = try self.arena().alloc(Label, self.table.len);
            for (labels, self.table) |*l, slot| {
                const f = if (slot) |fi| &self.funcs[fi] else null;
                l.* = if (f != null and f.?.reachable and f.?.import == null) f.?.trampoline else try self.trapLabel();
            }
            const src = try a.declare(.{ .name = "__table_b64", .type_name = "SystemString", .init = .{ .address_table = labels } });
            const raw = try a.declare(.{ .name = "__table_bytes", .type_name = "SystemByteArray" });
            try a.call(from_b64, &.{ src, raw });
            try a.call("SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array", &.{ try self.constI32(@intCast(labels.len)), tbl });
            try a.call(block_copy, &.{ raw, c0, tbl, c0, try self.constI32(@intCast(labels.len * 4)) });
        }

        try self.emitGlobalInits();

        // Inspector-assigned values of memory-backed fields go into memory
        // once, after the data segments that hold their defaults.
        for (self.symbol_fields.items) |sf| {
            const ty = symbolFieldType(sf);
            const mem = self.mem orelse return self.fail(error.Invalid, "memory-backed field without a linear memory", .{});
            const st = try self.storeArray(ty);
            try a.call(if (ty == .i32) "SystemInt32Array.__Set__SystemInt32_SystemInt32__SystemVoid" else "SystemSingleArray.__Set__SystemInt32_SystemSingle__SystemVoid", &.{ st, c0, sf.sym });
            try a.call(block_copy, &.{ st, c0, mem, try self.constI32(@bitCast(sf.address)), try self.constI32(4) });
        }

        if (self.mod.start) |s| {
            const f = &self.funcs[s];
            if (f.import != null or f.ty.params.len != 0) return self.fail(error.Unsupported, "the start function must be a defined function without parameters", .{});
            switch (f.ret) {
                .direct => {
                    try a.jump(f.entry);
                    a.bind(f.ret_label);
                },
                .indirect => {
                    const back = try a.newLabel();
                    try a.copy(try self.newRac(back), f.ra);
                    try a.jump(f.entry);
                    a.bind(back);
                },
                .halt => unreachable,
            }
        }
    }

    fn symbolFieldType(sf: SymbolField) ValType {
        return if (std.mem.eql(u8, sf.type_name, "SystemSingle")) .f32 else .i32;
    }

    fn emitGlobalInits(self: *Translator) Error!void {
        var n_imp: u32 = 0;
        for (self.mod.imports) |imp| if (imp.desc == .global) {
            n_imp += 1;
        };
        for (self.mod.globals, 0..) |g, def| {
            const dst = self.globals[n_imp + def];
            if (g.init.len != 1) return self.fail(error.Unsupported, "global {d} has a non-constant initializer", .{def});
            const src: ?Sym = switch (g.init[0]) {
                .i32_const => null,
                .f32_const => |x| if (exactSingle(x)) null else try self.constSym(.f32, @as(u32, @bitCast(x))),
                .i64_const => |x| if (x == 0) null else try self.constSym(.i64, @bitCast(x)),
                .f64_const => |x| if (@as(u64, @bitCast(x)) == 0) null else try self.constSym(.f64, @bitCast(x)),
                .global_get => |gi| if (gi < self.globals.len) self.globals[gi].sym else return self.fail(error.Invalid, "global initializer reads global {d}, which does not exist", .{gi}),
                else => return self.fail(error.Unsupported, "global {d} has a non-constant initializer", .{def}),
            };
            if (src) |s| try self.a.copy(s, dst.sym);
        }
    }

    fn encodeBase64(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        const enc = std.base64.standard.Encoder;
        const buf = try a.alloc(u8, enc.calcSize(bytes.len));
        return enc.encode(buf, bytes);
    }

    fn emitRuntime(self: *Translator) Error!void {
        const a = &self.a;
        if (self.trap_label) |l| {
            a.bind(l);
            const msg = try a.declare(.{ .name = "__trap_msg", .type_name = "SystemString", .init = .{ .string = "wasdon: WebAssembly trap (unreachable executed or null function reference)" } });
            try a.call("UnityEngineDebug.__LogError__SystemObject__SystemVoid", &.{msg});
            try a.jump(halt);
        }
        const add = "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32";
        const sub = "SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32";
        const shl = "SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32";
        const block_copy = "SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid";
        const c0 = try self.constI32(0);

        // memory.grow(delta) → previous size in pages, or -1.
        if (self.grow) |r| {
            const mem = self.mem.?;
            const ret = try self.retSym(0, .i32);
            const new = try self.rtVar("SystemInt32");
            const bytes = try self.rtVar("SystemInt32");
            const ok = try self.rtVar("SystemBoolean");
            const arr = try self.rtVar("SystemByteArray");
            const fail_l = try a.newLabel();
            const c16 = try self.constI32(16);
            a.bind(r.label);
            try a.call(add, &.{ self.mem_pages, r.args[0], new });
            try a.call("SystemInt32.__op_LessThanOrEqual__SystemInt32_SystemInt32__SystemBoolean", &.{ new, try self.constI32(@intCast(self.max_pages)), ok });
            try a.jumpIfFalse(ok, fail_l);
            try a.call("SystemInt32.__op_GreaterThanOrEqual__SystemInt32_SystemInt32__SystemBoolean", &.{ new, self.mem_pages, ok });
            try a.jumpIfFalse(ok, fail_l);
            try a.call(shl, &.{ new, c16, bytes });
            try a.call("SystemByteArray.__ctor__SystemInt32__SystemByteArray", &.{ bytes, arr });
            try a.call(shl, &.{ self.mem_pages, c16, bytes });
            try a.call(block_copy, &.{ mem, c0, arr, c0, bytes });
            try a.copy(arr, mem);
            try a.copy(self.mem_pages, ret);
            try a.copy(new, self.mem_pages);
            try a.jumpIndirect(r.ra);
            a.bind(fail_l);
            try a.copy(try self.constI32(-1), ret);
            try a.jumpIndirect(r.ra);
        }

        // memory.fill(dst, value, count): write one byte, then double the
        // filled prefix with overlapping-safe block copies.
        if (self.fill) |r| {
            const mem = self.mem.?;
            const st = try self.storeArray(.i32);
            const filled = try self.rtVar("SystemInt32");
            const chunk = try self.rtVar("SystemInt32");
            const at = try self.rtVar("SystemInt32");
            const more = try self.rtVar("SystemBoolean");
            const loop = try a.newLabel();
            const done = try a.newLabel();
            const c1 = try self.constI32(1);
            a.bind(r.label);
            try a.call("SystemInt32.__op_GreaterThan__SystemInt32_SystemInt32__SystemBoolean", &.{ r.args[2], c0, more });
            try a.jumpIfFalse(more, done);
            try a.call("SystemInt32Array.__Set__SystemInt32_SystemInt32__SystemVoid", &.{ st, c0, r.args[1] });
            try a.call(block_copy, &.{ st, c0, mem, r.args[0], c1 });
            try a.copy(c1, filled);
            a.bind(loop);
            try a.call("SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean", &.{ filled, r.args[2], more });
            try a.jumpIfFalse(more, done);
            try a.call(sub, &.{ r.args[2], filled, chunk });
            try a.call("SystemMath.__Min__SystemInt32_SystemInt32__SystemInt32", &.{ filled, chunk, chunk });
            try a.call(add, &.{ r.args[0], filled, at });
            try a.call(block_copy, &.{ mem, r.args[0], mem, at, chunk });
            try a.call(add, &.{ filled, chunk, filled });
            try a.jump(loop);
            a.bind(done);
            try a.jumpIndirect(r.ra);
        }
    }
};
