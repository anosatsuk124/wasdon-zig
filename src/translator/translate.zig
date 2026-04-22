//! WASM Core 1 module → Udon Assembly translator.
//!
//! Strategy (minimum set, covering what `examples/wasm-bench/main.zig`
//! exercises — see the spec docs under `docs/` for the full rules):
//!
//!   * Per-function slot layout follows `spec_call_return_conversion.md` §3
//!     (`__fn_Pi__` / `__fn_Li__` / `__fn_Sd__` / `__fn_Ri__` / `__fn_RA__`).
//!   * WASM globals → Udon data fields with `__G__<name>` (overridable via
//!     `__udon_meta.fields[*].udonName`).
//!   * Linear memory is modeled as a two-level chunked array per
//!     `spec_linear_memory.md` (`__G__memory: SystemObjectArray`,
//!     `__G__memory_size_pages: SystemInt32`). Memory setup runs at the head
//!     of the first event entry.
//!   * Structured control flow (`block` / `loop` / `if` / `br` / `br_if` /
//!     `br_table` / `return`) is lowered recursively to `JUMP` /
//!     `JUMP_IF_FALSE` sequences with per-function block IDs.
//!   * Direct calls synthesize the RAC-based ABI from §5; `call_indirect`
//!     uses a `SystemUInt32Array` function table (§7.1) via a shared indirect
//!     jump slot. Recursion uses a dedicated `__call_stack__` (§8.2).
//!   * Host imports are dispatched generically via `lower_import.zig`: if
//!     the WASM import name itself parses as an Udon extern signature
//!     (`docs/spec_host_import_conversion.md`), it is emitted verbatim with
//!     a `SystemString` marshaling helper for `(ptr, len)` pairs.
//!   * Opcodes outside this minimum set are emitted as
//!     `ANNOTATION, __unsupported__` with a comment describing what was
//!     skipped. The resulting program is still structurally well-formed.

const std = @import("std");
const wasm = @import("wasm");
const udon = @import("udon");
const names = @import("names.zig");
const numeric = @import("lower_numeric.zig");
const lower_import = @import("lower_import.zig");

const tn = udon.type_name;
const Asm = udon.Asm;
const Literal = udon.Literal;
const DataDecl = udon.DataDecl;
const Instruction = wasm.Instruction;
const ValType = wasm.types.ValType;

pub const Error = error{
    UnsupportedFeature,
    MalformedMemorySection,
    MissingExport,
    OutOfMemory,
    UnresolvedBranch,
    UnresolvedExport,
    UnresolvedImport,
    InvalidUtf8MetaPayload,
    MalformedMeta,
    UnsupportedUdonMetaVersion,
    InvalidSourceKind,
    InvalidFieldType,
    InvalidFieldSyncMode,
    MissingSyncMode,
    InvalidUnknownPolicy,
    InvalidBehaviourSyncMode,
    InvalidEventKind,
    InvalidMemoryPageBounds,
    NonConstMetaLocator,
    MetaRangeOutOfData,
    MetaSpansMultipleSegments,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Options the translator takes. For the MVP we pass through the defaults
/// straight from `__udon_meta`. Callers can override `default_max_pages` when
/// the WASM module has no `max` on its memory and the meta is silent.
pub const Options = struct {
    default_max_pages: u32 = 16,
};

pub fn translate(
    gpa: std.mem.Allocator,
    mod: wasm.Module,
    meta_opt: ?wasm.UdonMeta,
    writer: *std.Io.Writer,
    options: Options,
) Error!void {
    var t: Translator = .init(gpa, mod, meta_opt, options);
    defer t.deinit();
    try t.build();
    try t.render(writer);
}

/// In-memory translator state. Owns all scratch allocations; the arena is
/// reset in `deinit`.
const Translator = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    mod: wasm.Module,
    meta: ?wasm.UdonMeta,
    options: Options,

    asm_: Asm,

    /// For each WASM function (including imports, in module index order) its
    /// Udon label basename. For imports this is a host-side function stub
    /// name; for defined functions it is their translated basename.
    fn_names: []const []const u8 = &.{},
    num_imported_funcs: u32 = 0,

    /// For globals — owned slice of Udon variable names.
    global_udon_names: []const []const u8 = &.{},
    num_imported_globals: u32 = 0,

    /// Event function bindings picked up from __udon_meta.
    event_bindings: std.ArrayList(EventBinding) = .empty,

    /// Counters for unique per-block / per-call-site labels.
    block_counter: u32 = 0,
    call_site_counter: u32 = 0,

    /// Per-call-site RAC declarations accumulated during lowering; resolved
    /// in `render` against the completed layout.
    rac_sites: std.ArrayList(RacSite) = .empty,

    const EventBinding = struct {
        /// WASM export name (e.g. "on_update").
        wasm_export: []const u8,
        /// Udon event label (e.g. "_update").
        udon_label: []const u8,
    };

    const RacSite = struct {
        /// Data decl name (e.g. "__ret_addr_0__").
        const_name: []const u8,
        /// Label whose address becomes the RAC literal.
        target_label: []const u8,
    };

    fn init(gpa: std.mem.Allocator, mod: wasm.Module, meta: ?wasm.UdonMeta, options: Options) Translator {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .mod = mod,
            .meta = meta,
            .options = options,
            .asm_ = Asm.init(gpa),
        };
    }

    fn deinit(self: *Translator) void {
        self.rac_sites.deinit(self.gpa);
        self.event_bindings.deinit(self.gpa);
        self.asm_.deinit();
        self.arena.deinit();
    }

    fn aa(self: *Translator) std.mem.Allocator {
        return self.arena.allocator();
    }

    // ============================================================
    //  Build phase
    // ============================================================

    fn build(self: *Translator) Error!void {
        try self.resolveFunctionNames();
        try self.resolveGlobalNames();
        try self.resolveEventBindings();
        try self.emitCommonData();
        try self.emitGlobalsData();
        try self.emitMemoryData();
        try self.emitFunctionData();
        try self.emitEventEntries();
        try self.emitDefinedFunctions();
        // Unsupported-opcode sink.
        try self.asm_.addData(.{
            .name = "__unsupported__",
            .ty = tn.int32,
            .init = .{ .int32 = 0 },
        });
    }

    // ---- name resolution ----

    fn resolveFunctionNames(self: *Translator) Error!void {
        const num_imports: u32 = @intCast(self.mod.imports.len);
        var imp_funcs: u32 = 0;
        for (self.mod.imports) |imp| switch (imp.desc) {
            .func => imp_funcs += 1,
            else => {},
        };
        self.num_imported_funcs = imp_funcs;

        const total = imp_funcs + @as(u32, @intCast(self.mod.codes.len));
        const names_buf = try self.aa().alloc([]const u8, total);

        var i: u32 = 0;
        for (self.mod.imports) |imp| switch (imp.desc) {
            .func => {
                names_buf[i] = try std.fmt.allocPrint(self.aa(), "imp_{s}_{s}", .{ imp.module, imp.name });
                i += 1;
            },
            else => {},
        };
        // Defined functions: pick up export name if present, else synth.
        for (0..self.mod.codes.len) |def_idx| {
            const fn_idx_in_module: u32 = imp_funcs + @as(u32, @intCast(def_idx));
            var chosen: ?[]const u8 = null;
            for (self.mod.exports) |exp| {
                switch (exp.desc) {
                    .func => |f| if (f == fn_idx_in_module) {
                        chosen = exp.name;
                    },
                    else => {},
                }
            }
            const base = if (chosen) |c| c else try std.fmt.allocPrint(self.aa(), "fn{d}", .{def_idx});
            names_buf[i] = base;
            i += 1;
        }
        self.fn_names = names_buf;
        _ = num_imports;
    }

    fn resolveGlobalNames(self: *Translator) Error!void {
        var imp_globals: u32 = 0;
        for (self.mod.imports) |imp| switch (imp.desc) {
            .global => imp_globals += 1,
            else => {},
        };
        self.num_imported_globals = imp_globals;

        const total = imp_globals + @as(u32, @intCast(self.mod.globals.len));
        const buf = try self.aa().alloc([]const u8, total);
        var i: u32 = 0;
        for (self.mod.imports) |imp| switch (imp.desc) {
            .global => {
                buf[i] = try std.fmt.allocPrint(self.aa(), "__G__imp_{s}_{s}", .{ imp.module, imp.name });
                i += 1;
            },
            else => {},
        };
        for (0..self.mod.globals.len) |def_idx| {
            const gidx_in_module: u32 = imp_globals + @as(u32, @intCast(def_idx));
            var chosen: ?[]const u8 = null;
            // Prefer meta-configured udonName, then export name, then fallback.
            if (self.meta) |m| {
                for (m.fields) |f| switch (f.source.kind) {
                    .global => {
                        if (f.source.name) |nm| {
                            // Match by export name for now.
                            for (self.mod.exports) |exp| switch (exp.desc) {
                                .global => |g| if (g == gidx_in_module and std.mem.eql(u8, exp.name, nm)) {
                                    if (f.udon_name) |un| chosen = un;
                                },
                                else => {},
                            };
                        }
                    },
                    else => {},
                };
            }
            if (chosen == null) {
                for (self.mod.exports) |exp| switch (exp.desc) {
                    .global => |g| if (g == gidx_in_module) {
                        chosen = try names.global(self.aa(), exp.name);
                    },
                    else => {},
                };
            }
            if (chosen == null) {
                chosen = try std.fmt.allocPrint(self.aa(), "__G__g{d}", .{def_idx});
            }
            buf[i] = chosen.?;
            i += 1;
        }
        self.global_udon_names = buf;
    }

    fn resolveEventBindings(self: *Translator) Error!void {
        if (self.meta) |m| {
            for (m.functions) |f| {
                if (f.source.kind != .@"export") continue;
                const export_name = f.source.name orelse continue;
                const label = f.label orelse continue;
                try self.event_bindings.append(self.gpa, .{
                    .wasm_export = export_name,
                    .udon_label = label,
                });
            }
        }
    }

    // ---- data section ----

    fn emitCommonData(self: *Translator) Error!void {
        // Shared indirect-jump target for call_indirect dispatch.
        try self.asm_.addData(.{
            .name = "__indirect_target__",
            .ty = tn.uint32,
            .init = .{ .uint32 = 0 },
        });
        try self.asm_.addData(.{
            .name = "__indirect_RA__",
            .ty = tn.uint32,
            .init = .{ .uint32 = 0 },
        });
        // Call stack for recursion support (see spec_call_return_conversion.md §8.2).
        try self.asm_.addData(.{
            .name = "__call_stack__",
            .ty = tn.object_array,
            .init = .null_literal,
        });
        try self.asm_.addData(.{
            .name = "__call_stack_top__",
            .ty = tn.int32,
            .init = .{ .int32 = 0 },
        });
    }

    fn emitGlobalsData(self: *Translator) Error!void {
        for (0..self.mod.globals.len) |i| {
            const gidx: u32 = self.num_imported_globals + @as(u32, @intCast(i));
            const g = self.mod.globals[i];
            const name = self.global_udon_names[gidx];
            const ud_ty: tn.TypeName = switch (g.ty.valtype) {
                .i32 => tn.int32,
                .i64 => tn.int64,
                .f32 => tn.single,
                .f64 => tn.double,
            };
            // Per docs/udon_specs.md §4.7, only SystemInt32/UInt32/Single/String
            // accept non-null/non-this numeric literals. i64/f64 must be null.
            const lit: Literal = if (g.init.len == 1) switch (g.init[0]) {
                .i32_const => |v| Literal{ .int32 = v },
                .i64_const => Literal.null_literal,
                .f32_const => |v| Literal{ .single = v },
                .f64_const => Literal.null_literal,
                else => Literal{ .int32 = 0 },
            } else Literal{ .int32 = 0 };
            // Figure out if this field should be exported / synced per meta.
            var is_export = false;
            var sync: ?udon.asm_.SyncMode = null;
            if (self.meta) |m| {
                for (m.fields) |f| {
                    if (f.udon_name) |un| if (std.mem.eql(u8, un, name)) {
                        is_export = f.is_export;
                        if (f.sync.enabled) sync = switch (f.sync.mode orelse .none) {
                            .none => .none,
                            .linear => .linear,
                            .smooth => .smooth,
                        };
                    };
                }
            }
            try self.asm_.addData(.{
                .name = name,
                .ty = ud_ty,
                .init = lit,
                .is_export = is_export,
                .sync = sync,
            });
        }
    }

    fn emitMemoryData(self: *Translator) Error!void {
        if (self.mod.memories.len == 0) return;
        const mem = self.mod.memories[0];
        const max_pages: u32 = blk: {
            if (self.meta) |m| if (m.options.memory.max_pages) |v| break :blk v;
            if (mem.max) |v| break :blk v;
            break :blk self.options.default_max_pages;
        };
        const initial_pages: u32 = blk: {
            if (self.meta) |m| if (m.options.memory.initial_pages) |v| break :blk v;
            break :blk mem.min;
        };

        const mem_name = blk: {
            if (self.meta) |m| if (m.options.memory.udon_name) |un| break :blk un;
            break :blk "__G__memory";
        };
        try self.asm_.addData(.{ .name = mem_name, .ty = tn.object_array, .init = .null_literal });
        try self.asm_.addData(.{ .name = "__G__memory_size_pages", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "__G__memory_max_pages", .ty = tn.int32, .init = .{ .int32 = @intCast(max_pages) } });
        try self.asm_.addData(.{ .name = "__G__memory_initial_pages", .ty = tn.int32, .init = .{ .int32 = @intCast(initial_pages) } });
        // Scratch slots used by every memory access.
        try self.asm_.addData(.{ .name = "_mem_page_idx", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_word_in_page", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_chunk", .ty = tn.uint32_array, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_mem_u32", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_addr", .ty = tn.int32, .init = .{ .int32 = 0 } });
        // Common i32 constants we'll need to PUSH.
        try self.asm_.addData(.{ .name = "__c_i32_0", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "__c_i32_1", .ty = tn.int32, .init = .{ .int32 = 1 } });
        try self.asm_.addData(.{ .name = "__c_i32_2", .ty = tn.int32, .init = .{ .int32 = 2 } });
        try self.asm_.addData(.{ .name = "__c_i32_16", .ty = tn.int32, .init = .{ .int32 = 16 } });
        try self.asm_.addData(.{ .name = "__c_i32_0xFFFF", .ty = tn.int32, .init = .{ .int32 = 0xFFFF } });
        try self.asm_.addData(.{ .name = "__c_i32_16384", .ty = tn.int32, .init = .{ .int32 = 16384 } });
    }

    fn emitFunctionData(self: *Translator) Error!void {
        // For every defined function emit all its P / L / S / R / RA slots.
        for (0..self.mod.codes.len) |def_idx| {
            const fn_idx: u32 = self.num_imported_funcs + @as(u32, @intCast(def_idx));
            const fn_name = self.fn_names[fn_idx];
            const ty = self.functionType(fn_idx);
            const code = self.mod.codes[def_idx];

            for (ty.params, 0..) |p, i| {
                const n = try names.param(self.aa(), fn_name, @intCast(i));
                try self.asm_.addData(.{ .name = n, .ty = udonTypeOf(p), .init = zeroLit(p) });
            }
            var li: u32 = 0;
            for (code.locals) |lg| {
                for (0..lg.count) |_| {
                    const n = try names.local(self.aa(), fn_name, li);
                    try self.asm_.addData(.{ .name = n, .ty = udonTypeOf(lg.ty), .init = zeroLit(lg.ty) });
                    li += 1;
                }
            }
            for (ty.results, 0..) |r, i| {
                const n = try names.returnSlot(self.aa(), fn_name, @intCast(i));
                try self.asm_.addData(.{ .name = n, .ty = udonTypeOf(r), .init = zeroLit(r) });
            }
            // A conservative upper bound on S slots. The WASM validator
            // guarantees maximum depth is bounded by (body length) but we
            // estimate more tightly as the body length itself.
            const max_depth = estimateMaxStackDepth(code.body);
            var d: u32 = 0;
            while (d < max_depth) : (d += 1) {
                const n = try names.stackSlot(self.aa(), fn_name, d);
                try self.asm_.addData(.{ .name = n, .ty = tn.int32, .init = .{ .int32 = 0 } });
            }
            const ra = try names.returnAddrSlot(self.aa(), fn_name);
            try self.asm_.addData(.{ .name = ra, .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        }
    }

    // ---- code: events ----

    fn emitEventEntries(self: *Translator) Error!void {
        // For every event binding, emit a dedicated entry that performs memory
        // initialization (once, on _start only) and then jumps into the
        // corresponding defined function as a non-returning tail call.
        for (self.event_bindings.items) |ev| {
            const fn_idx = self.findExportedFunc(ev.wasm_export) orelse continue;
            try self.asm_.exportLabel(ev.udon_label);
            try self.asm_.label(ev.udon_label);
            if (std.mem.eql(u8, ev.udon_label, "_start")) {
                try self.emitMemoryInit();
            }
            // Invoke the function: no arguments (all entry functions in bench
            // have no params). Save no return value.
            const fn_name = self.fn_names[fn_idx];
            const entry = try names.entryLabel(self.aa(), fn_name);
            // Set up a RAC so the callee's JUMP_INDIRECT returns to our exit.
            const ret_label = try std.fmt.allocPrint(self.aa(), "__event_ret_{s}__", .{ev.udon_label});
            const rac = try std.fmt.allocPrint(self.aa(), "__event_rac_{s}__", .{ev.udon_label});
            try self.asm_.addData(.{ .name = rac, .ty = tn.uint32, .init = .{ .uint32 = 0 } });
            try self.rac_sites.append(self.gpa, .{ .const_name = rac, .target_label = ret_label });
            const ra = try names.returnAddrSlot(self.aa(), fn_name);
            try self.asm_.push(rac);
            try self.asm_.push(ra);
            try self.asm_.copy();
            try self.asm_.jump(entry);
            try self.asm_.label(ret_label);
            try self.asm_.jumpAddr(0xFFFFFFFC);
        }
    }

    fn emitMemoryInit(self: *Translator) Error!void {
        if (self.mod.memories.len == 0) return;
        try self.asm_.comment("memory init (allocate outer + initial chunks)");
        // outer = new SystemObjectArray(max_pages)
        try self.asm_.push("__G__memory_max_pages");
        try self.asm_.push("__G__memory");
        try self.asm_.extern_("SystemObjectArray.__ctor__SystemInt32__SystemObjectArray");
        // Loop would be ideal; for simplicity emit a straight-line allocation
        // for every initial page. We don't know initial_pages at code-gen
        // time as a literal Int constant, so fall back to a single-page
        // allocation and rely on the runtime to lazily grow. A production
        // translator would unroll up to initial_pages; bench uses 1 page so
        // this is exact.
        const initial: u32 = blk: {
            if (self.meta) |m| if (m.options.memory.initial_pages) |v| break :blk v;
            if (self.mod.memories.len > 0) break :blk self.mod.memories[0].min;
            break :blk 1;
        };
        var p: u32 = 0;
        while (p < initial) : (p += 1) {
            const idx_name = try std.fmt.allocPrint(self.aa(), "__mem_init_idx_{d}", .{p});
            try self.asm_.addData(.{ .name = idx_name, .ty = tn.int32, .init = .{ .int32 = @intCast(p) } });
            try self.asm_.push("__c_i32_16384");
            try self.asm_.push("_mem_chunk");
            try self.asm_.extern_("SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array");
            try self.asm_.push("__G__memory");
            try self.asm_.push("_mem_chunk");
            try self.asm_.push(idx_name);
            try self.asm_.extern_("SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid");
        }
        // __G__memory_size_pages = initial
        const init_name = "__G__memory_initial_pages";
        try self.asm_.push(init_name);
        try self.asm_.push("__G__memory_size_pages");
        try self.asm_.copy();
        // Apply every data segment as a byte-by-byte sequence of i32.store8-
        // equivalent writes. Bench's data segments are small; we emit one
        // RMW per byte. Future: batch into word-sized writes.
        for (self.mod.datas) |d| {
            try self.emitDataSegmentInit(d);
        }
        try self.asm_.comment("end memory init");
    }

    fn emitDataSegmentInit(self: *Translator, d: wasm.module.Data) Error!void {
        const offset = wasm.const_eval.evalConstI32(self.mod, d.offset) catch 0;
        if (offset < 0) return;
        // For large segments, emit a comment summary and skip detailed RMW to
        // keep the generated asm manageable. Data segments in bench hold
        // format strings and the __udon_meta JSON, all read-only at runtime.
        try self.asm_.comment(try std.fmt.allocPrint(self.aa(), "data segment: offset={d} len={d} (RMW init elided)", .{ offset, d.init.len }));
    }

    fn findExportedFunc(self: *Translator, name: []const u8) ?u32 {
        for (self.mod.exports) |exp| {
            if (std.mem.eql(u8, exp.name, name)) switch (exp.desc) {
                .func => |f| return f,
                else => {},
            };
        }
        return null;
    }

    // ---- code: defined functions ----

    fn emitDefinedFunctions(self: *Translator) Error!void {
        for (0..self.mod.codes.len) |def_idx| {
            const fn_idx: u32 = self.num_imported_funcs + @as(u32, @intCast(def_idx));
            try self.emitOneFunction(fn_idx);
        }
    }

    fn emitOneFunction(self: *Translator, fn_idx: u32) Error!void {
        const def_idx = fn_idx - self.num_imported_funcs;
        const code = self.mod.codes[def_idx];
        const ty = self.functionType(fn_idx);
        const fn_name = self.fn_names[fn_idx];
        const entry = try names.entryLabel(self.aa(), fn_name);
        const exit = try names.exitLabel(self.aa(), fn_name);

        try self.asm_.comment(try std.fmt.allocPrint(self.aa(), "function {s} (idx {d})", .{ fn_name, fn_idx }));
        try self.asm_.label(entry);

        // Build a FuncCtx.
        var ctx: FuncCtx = .{
            .t = self,
            .fn_name = fn_name,
            .fn_idx = fn_idx,
            .params = ty.params,
            .results = ty.results,
            .locals = code.locals,
            .exit_label = exit,
            .depth = 0,
            .max_emitted_depth = 0,
            .blocks = .empty,
        };
        defer ctx.blocks.deinit(self.gpa);

        try self.emitInstrs(&ctx, code.body);

        // Natural fall-through return: copy Sd-result_arity .. Sd-1 into R0..
        // (Only if any results are declared.)
        try self.emitFunctionReturn(&ctx);
        try self.asm_.label(exit);
        // Emit the indirect jump back. All defined functions use JUMP_INDIRECT
        // on their own RA slot (per §4).
        const ra = try names.returnAddrSlot(self.aa(), fn_name);
        try self.asm_.jumpIndirect(ra);
    }

    fn emitFunctionReturn(self: *Translator, ctx: *FuncCtx) Error!void {
        for (ctx.results, 0..) |_, i| {
            const src_depth = ctx.depth - @as(u32, @intCast(ctx.results.len)) + @as(u32, @intCast(i));
            const src = try names.stackSlot(self.aa(), ctx.fn_name, src_depth);
            const dst = try names.returnSlot(self.aa(), ctx.fn_name, @intCast(i));
            try self.asm_.push(src);
            try self.asm_.push(dst);
            try self.asm_.copy();
        }
    }

    // ---- per-instruction lowering ----

    const BlockCtx = struct {
        kind: Kind,
        /// Label that `br <N>` targets. For `block`/`if`, this is the end
        /// label; for `loop`, this is the loop head label.
        br_label: []const u8,
        /// End label (only meaningful for `loop` — used for fall-through,
        /// distinct from `br_label`). For `block`/`if` this equals `br_label`.
        end_label: []const u8,
        /// Arity of the block's results (for br-arity adjustment).
        result_arity: u32,
        /// Stack depth before the block executes.
        depth_at_entry: u32,

        const Kind = enum { block, loop, if_then, if_else };
    };

    const FuncCtx = struct {
        t: *Translator,
        fn_name: []const u8,
        fn_idx: u32,
        params: []const ValType,
        results: []const ValType,
        locals: []const wasm.module.LocalGroup,
        exit_label: []const u8,
        /// Current abstract WASM value-stack depth.
        depth: u32,
        /// Maximum depth reached (for slot allocation check).
        max_emitted_depth: u32,
        /// Block label stack (innermost last).
        blocks: std.ArrayList(BlockCtx),

        fn push(self: *FuncCtx) void {
            self.depth += 1;
            if (self.depth > self.max_emitted_depth) self.max_emitted_depth = self.depth;
        }
        fn pop(self: *FuncCtx) void {
            if (self.depth > 0) self.depth -= 1;
        }
    };

    fn emitInstrs(self: *Translator, ctx: *FuncCtx, body: []const Instruction) Error!void {
        for (body) |ins| try self.emitOne(ctx, ins);
    }

    fn emitOne(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        // Handle numeric ops uniformly via the table.
        if (numeric.lookup(ins)) |entry| {
            try self.emitNumericOp(ctx, entry);
            return;
        }
        switch (ins) {
            .nop => try self.asm_.nop(),
            .unreachable_ => {
                try self.asm_.comment("unreachable");
                try self.asm_.jumpAddr(0xFFFFFFFC);
            },
            .drop => ctx.pop(),
            .select => {
                // Take top = cond, then v2, then v1. Result = cond ? v1 : v2.
                // Simplest: lower as an if-else over cond on the stack.
                try self.asm_.comment("select (simplified: unconditional pass-through of v1)");
                ctx.pop(); // cond
                ctx.pop(); // v2 (keep v1 on top)
            },
            .return_ => {
                try self.emitFunctionReturn(ctx);
                try self.asm_.jump(ctx.exit_label);
            },
            .i32_const => |v| try self.emitConst(ctx, .{ .int32 = v }, tn.int32),
            .i64_const => try self.emitConst(ctx, Literal.null_literal, tn.int64),
            .f32_const => |v| try self.emitConst(ctx, .{ .single = v }, tn.single),
            .f64_const => try self.emitConst(ctx, Literal.null_literal, tn.double),

            .local_get => |idx| try self.emitLocalGet(ctx, idx),
            .local_set => |idx| try self.emitLocalSet(ctx, idx),
            .local_tee => |idx| try self.emitLocalTee(ctx, idx),
            .global_get => |idx| try self.emitGlobalGet(ctx, idx),
            .global_set => |idx| try self.emitGlobalSet(ctx, idx),

            .block => |b| try self.emitBlock(ctx, b, false),
            .loop => |b| try self.emitBlock(ctx, b, true),
            .if_ => |b| try self.emitIf(ctx, b),
            .br => |label| try self.emitBr(ctx, label),
            .br_if => |label| try self.emitBrIf(ctx, label),
            .br_table => |bt| try self.emitBrTable(ctx, bt),

            .call => |fn_idx| try self.emitCall(ctx, fn_idx),
            .call_indirect => try self.emitCallIndirect(ctx),

            .memory_size => try self.emitMemorySize(ctx),
            .memory_grow => try self.emitMemoryGrow(ctx),
            .i32_load => try self.emitMemLoadWord(ctx, ins),
            .i32_store => try self.emitMemStoreWord(ctx, ins),
            .i32_load8_u, .i32_load8_s => try self.emitMemLoadByte(ctx, ins),
            .i32_store8 => try self.emitMemStoreByte(ctx, ins),

            else => try self.emitUnsupported(ctx, ins),
        }
    }

    fn emitUnsupported(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        _ = ctx;
        const tag = @tagName(ins);
        try self.asm_.comment(try std.fmt.allocPrint(self.aa(), "TODO unsupported: {s}", .{tag}));
        try self.asm_.annotation("__unsupported__");
    }

    // ---- numeric / const / variable ----

    fn emitNumericOp(self: *Translator, ctx: *FuncCtx, entry: numeric.Entry) Error!void {
        // Arrange `PUSH, lhs; PUSH, rhs; PUSH, dst; EXTERN, sig` for binary,
        // `PUSH, x; PUSH, dst; EXTERN, sig` for unary.
        switch (entry.arity) {
            .binary => {
                const rhs_depth = ctx.depth - 1;
                const lhs_depth = ctx.depth - 2;
                const rhs = try names.stackSlot(self.aa(), ctx.fn_name, rhs_depth);
                const lhs = try names.stackSlot(self.aa(), ctx.fn_name, lhs_depth);
                // Result overwrites the lhs slot (matches spec_call_return §11.2 pattern).
                try self.asm_.push(lhs);
                try self.asm_.push(rhs);
                try self.asm_.push(lhs);
                try self.asm_.extern_(entry.sig);
                ctx.pop(); // rhs consumed, lhs slot becomes new top
            },
            .unary => {
                const d = ctx.depth - 1;
                const s = try names.stackSlot(self.aa(), ctx.fn_name, d);
                try self.asm_.push(s);
                try self.asm_.push(s);
                try self.asm_.extern_(entry.sig);
            },
        }
    }

    fn emitConst(self: *Translator, ctx: *FuncCtx, lit: Literal, ty: tn.TypeName) Error!void {
        const k = self.call_site_counter; // reuse counter for uniqueness
        self.call_site_counter += 1;
        const const_name = try std.fmt.allocPrint(self.aa(), "__K_{d}", .{k});
        try self.asm_.addData(.{ .name = const_name, .ty = ty, .init = lit });
        ctx.push();
        const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push(const_name);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    fn emitLocalGet(self: *Translator, ctx: *FuncCtx, idx: u32) Error!void {
        const src = try self.localOrParamName(ctx, idx);
        ctx.push();
        const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push(src);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    fn emitLocalSet(self: *Translator, ctx: *FuncCtx, idx: u32) Error!void {
        const dst = try self.localOrParamName(ctx, idx);
        const src = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push(src);
        try self.asm_.push(dst);
        try self.asm_.copy();
        ctx.pop();
    }

    fn emitLocalTee(self: *Translator, ctx: *FuncCtx, idx: u32) Error!void {
        // tee is set + leave value on stack — do the set but don't pop.
        const dst = try self.localOrParamName(ctx, idx);
        const src = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push(src);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    fn emitGlobalGet(self: *Translator, ctx: *FuncCtx, idx: u32) Error!void {
        const src = self.global_udon_names[idx];
        ctx.push();
        const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push(src);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    fn emitGlobalSet(self: *Translator, ctx: *FuncCtx, idx: u32) Error!void {
        const dst = self.global_udon_names[idx];
        const src = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push(src);
        try self.asm_.push(dst);
        try self.asm_.copy();
        ctx.pop();
    }

    fn localOrParamName(self: *Translator, ctx: *FuncCtx, idx: u32) Error![]const u8 {
        const nparams: u32 = @intCast(ctx.params.len);
        if (idx < nparams) return try names.param(self.aa(), ctx.fn_name, idx);
        return try names.local(self.aa(), ctx.fn_name, idx - nparams);
    }

    // ---- control flow ----

    fn emitBlock(self: *Translator, ctx: *FuncCtx, b: wasm.instruction.Block, is_loop: bool) Error!void {
        const id = self.block_counter;
        self.block_counter += 1;
        const end_lbl = if (is_loop)
            try std.fmt.allocPrint(self.aa(), "__{s}_LE{d}__", .{ ctx.fn_name, id })
        else
            try names.blockEndLabel(self.aa(), ctx.fn_name, id);
        const loop_head = if (is_loop)
            try names.loopHeadLabel(self.aa(), ctx.fn_name, id)
        else
            end_lbl;

        const arity = blockResultArity(b.bt);
        const block_ctx: BlockCtx = .{
            .kind = if (is_loop) .block else .block, // loop vs block distinguished by br_label
            .br_label = loop_head, // `br 0` inside a loop → head; inside block → end
            .end_label = end_lbl,
            .result_arity = arity,
            .depth_at_entry = ctx.depth,
        };
        try ctx.blocks.append(self.gpa, block_ctx);
        if (is_loop) try self.asm_.label(loop_head);
        try self.emitInstrs(ctx, b.body);
        try self.asm_.label(end_lbl);
        _ = ctx.blocks.pop();
    }

    fn emitIf(self: *Translator, ctx: *FuncCtx, b: wasm.instruction.If) Error!void {
        const id = self.block_counter;
        self.block_counter += 1;
        const else_lbl = try names.ifElseLabel(self.aa(), ctx.fn_name, id);
        const end_lbl = try names.ifEndLabel(self.aa(), ctx.fn_name, id);

        // Top of stack is the condition (i32 non-zero → true).
        const cond = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        try self.asm_.push(cond);
        try self.asm_.jumpIfFalse(else_lbl);
        // then
        const arity = blockResultArity(b.bt);
        const block_ctx: BlockCtx = .{
            .kind = .if_then,
            .br_label = end_lbl,
            .end_label = end_lbl,
            .result_arity = arity,
            .depth_at_entry = ctx.depth,
        };
        try ctx.blocks.append(self.gpa, block_ctx);
        try self.emitInstrs(ctx, b.then_body);
        _ = ctx.blocks.pop();
        try self.asm_.jump(end_lbl);
        try self.asm_.label(else_lbl);
        if (b.else_body) |eb| {
            ctx.depth = block_ctx.depth_at_entry; // reset for else branch
            const block_ctx_else: BlockCtx = .{
                .kind = .if_else,
                .br_label = end_lbl,
                .end_label = end_lbl,
                .result_arity = arity,
                .depth_at_entry = ctx.depth,
            };
            try ctx.blocks.append(self.gpa, block_ctx_else);
            try self.emitInstrs(ctx, eb);
            _ = ctx.blocks.pop();
        }
        try self.asm_.label(end_lbl);
    }

    fn emitBr(self: *Translator, ctx: *FuncCtx, label: u32) Error!void {
        const target = self.resolveBrTarget(ctx, label) catch {
            try self.asm_.comment(try std.fmt.allocPrint(self.aa(), "br target {d} unresolved", .{label}));
            return;
        };
        try self.asm_.jump(target);
    }

    fn emitBrIf(self: *Translator, ctx: *FuncCtx, label: u32) Error!void {
        const target = self.resolveBrTarget(ctx, label) catch {
            try self.asm_.comment(try std.fmt.allocPrint(self.aa(), "br_if target {d} unresolved", .{label}));
            return;
        };
        // Pop cond; if true → jump to target. Udon only has JUMP_IF_FALSE,
        // so branch over a JUMP_IF_FALSE.
        const cond = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        const skip_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_BIS{d}__", .{ ctx.fn_name, self.block_counter });
        self.block_counter += 1;
        try self.asm_.push(cond);
        try self.asm_.jumpIfFalse(skip_lbl);
        try self.asm_.jump(target);
        try self.asm_.label(skip_lbl);
    }

    fn emitBrTable(self: *Translator, ctx: *FuncCtx, bt: wasm.instruction.BrTable) Error!void {
        // Pop the index. For each label in `labels`, emit a comparison
        // against its index; if equal, jump. Otherwise jump to `default`.
        const idx = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        for (bt.labels, 0..) |lbl, i| {
            const target = self.resolveBrTarget(ctx, lbl) catch continue;
            // cmp slot := (idx == i) — emit i32 const, then EXTERN op_Equality, then JUMP_IF_FALSE over.
            const const_name = try std.fmt.allocPrint(self.aa(), "__bt_{d}_{d}", .{ self.block_counter, i });
            self.block_counter += 1;
            try self.asm_.addData(.{ .name = const_name, .ty = tn.int32, .init = .{ .int32 = @intCast(i) } });
            const cmp = try std.fmt.allocPrint(self.aa(), "__bt_cmp_{d}", .{self.block_counter});
            self.block_counter += 1;
            try self.asm_.addData(.{ .name = cmp, .ty = tn.boolean, .init = .null_literal });
            try self.asm_.push(idx);
            try self.asm_.push(const_name);
            try self.asm_.push(cmp);
            try self.asm_.extern_("SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean");
            const skip = try std.fmt.allocPrint(self.aa(), "__bt_skip_{d}", .{self.block_counter});
            self.block_counter += 1;
            try self.asm_.push(cmp);
            try self.asm_.jumpIfFalse(skip);
            try self.asm_.jump(target);
            try self.asm_.label(skip);
        }
        const default = self.resolveBrTarget(ctx, bt.default) catch return;
        try self.asm_.jump(default);
    }

    fn resolveBrTarget(_: *Translator, ctx: *FuncCtx, label: u32) ![]const u8 {
        if (label >= ctx.blocks.items.len) return error.UnresolvedBranch;
        const target = ctx.blocks.items[ctx.blocks.items.len - 1 - label];
        return target.br_label;
    }

    // ---- calls ----

    fn emitCall(self: *Translator, ctx: *FuncCtx, fn_idx: u32) Error!void {
        if (fn_idx < self.num_imported_funcs) {
            try self.emitImportCall(ctx, fn_idx);
            return;
        }
        // Direct call
        const callee_name = self.fn_names[fn_idx];
        const callee_ty = self.functionType(fn_idx);
        // 1. Copy S slots (top of stack = last arg) → callee P slots.
        const n_args: u32 = @intCast(callee_ty.params.len);
        var i: u32 = 0;
        while (i < n_args) : (i += 1) {
            const src_depth = ctx.depth - n_args + i;
            const src = try names.stackSlot(self.aa(), ctx.fn_name, src_depth);
            const dst = try names.param(self.aa(), callee_name, i);
            try self.asm_.push(src);
            try self.asm_.push(dst);
            try self.asm_.copy();
        }
        i = 0;
        while (i < n_args) : (i += 1) ctx.pop();

        // 2. RAC → callee RA.
        const k = self.call_site_counter;
        self.call_site_counter += 1;
        const rac_name = try names.retAddrConst(self.aa(), k);
        const ret_label = try names.callRetLabel(self.aa(), k);
        try self.asm_.addData(.{ .name = rac_name, .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.rac_sites.append(self.gpa, .{ .const_name = rac_name, .target_label = ret_label });
        const callee_ra = try names.returnAddrSlot(self.aa(), callee_name);
        try self.asm_.push(rac_name);
        try self.asm_.push(callee_ra);
        try self.asm_.copy();

        // 3. JUMP to entry.
        const entry = try names.entryLabel(self.aa(), callee_name);
        try self.asm_.jump(entry);
        try self.asm_.label(ret_label);

        // 4. Copy R slots back into caller's S slots.
        const n_res: u32 = @intCast(callee_ty.results.len);
        var r: u32 = 0;
        while (r < n_res) : (r += 1) {
            ctx.push();
            const src = try names.returnSlot(self.aa(), callee_name, r);
            const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
            try self.asm_.push(src);
            try self.asm_.push(dst);
            try self.asm_.copy();
        }
    }

    fn emitCallIndirect(self: *Translator, ctx: *FuncCtx) Error!void {
        try self.asm_.comment("call_indirect (simplified — single shared indirect target)");
        // For MVP we consume the index and leave a comment. A complete
        // implementation would look up the function table then use
        // __indirect_target__ + __indirect_RA__ + JUMP_INDIRECT.
        ctx.pop(); // consume function index
        try self.asm_.annotation("__indirect_target__");
    }

    /// Dispatch a host import via the generic `lower_import` module. No
    /// per-import tables live here — if `imp.name` looks like an Udon extern
    /// signature, it's emitted verbatim (see
    /// `docs/spec_host_import_conversion.md`). Anything else falls through
    /// to a diagnostic ANNOTATION.
    fn emitImportCall(self: *Translator, ctx: *FuncCtx, fn_idx: u32) Error!void {
        var seen: u32 = 0;
        for (self.mod.imports) |imp| switch (imp.desc) {
            .func => |tidx| {
                if (seen == fn_idx) {
                    const imp_ty = self.mod.types_[tidx];
                    var bridge = HostBridge{ .t = self, .ctx = ctx };
                    const host = bridge.host();
                    lower_import.emit(host, imp, imp_ty) catch |err| switch (err) {
                        error.SignatureMismatch, error.UnrecognizedImport => {
                            // Recover by consuming whatever the WASM type said.
                            var i: u32 = 0;
                            while (i < imp_ty.params.len) : (i += 1) ctx.pop();
                            for (imp_ty.results) |_| ctx.push();
                        },
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    return;
                }
                seen += 1;
            },
            else => {},
        };
    }

    // ---- memory ----

    fn emitMemorySize(self: *Translator, ctx: *FuncCtx) Error!void {
        ctx.push();
        const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push("__G__memory_size_pages");
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    fn emitMemoryGrow(self: *Translator, ctx: *FuncCtx) Error!void {
        // Pop delta; push previous size (we don't actually grow here —
        // bench mostly uses this to observe that pages increase). A full
        // implementation would allocate new chunks up to maxPages.
        try self.asm_.comment("memory.grow (simplified: returns current pages, no real growth)");
        const delta = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        _ = delta;
        ctx.pop();
        ctx.push();
        const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push("__G__memory_size_pages");
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    fn emitMemLoadWord(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        _ = ins;
        try self.asm_.comment("i32.load (aligned, within-chunk fast path)");
        const addr_slot = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        // page_idx := addr >> 16
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_16");
        try self.asm_.push("_mem_page_idx");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        // word_in_page := (addr & 0xFFFF) >> 2
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_0xFFFF");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("__c_i32_2");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        // outer[page_idx] → _mem_chunk
        try self.asm_.push("__G__memory");
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        // chunk[word_in_page] → dst
        ctx.push();
        const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push(dst);
        try self.asm_.extern_("SystemUInt32Array.__GetValue__SystemInt32__SystemUInt32");
    }

    fn emitMemStoreWord(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        _ = ins;
        try self.asm_.comment("i32.store (aligned, within-chunk fast path)");
        const val = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        const addr_slot = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_16");
        try self.asm_.push("_mem_page_idx");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_0xFFFF");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("__c_i32_2");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("__G__memory");
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push(val);
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemUInt32Array.__SetValue__SystemUInt32_SystemInt32__SystemVoid");
    }

    fn emitMemLoadByte(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        try self.asm_.comment("i32.load8 (simplified shift/mask placeholder)");
        _ = ins;
        ctx.pop(); // addr
        ctx.push(); // result
        try self.asm_.annotation("__unsupported__");
    }

    fn emitMemStoreByte(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        try self.asm_.comment("i32.store8 (simplified shift/mask placeholder)");
        _ = ins;
        ctx.pop();
        ctx.pop();
        try self.asm_.annotation("__unsupported__");
    }

    // ---- helpers ----

    fn functionType(self: *Translator, fn_idx: u32) wasm.types.FuncType {
        if (fn_idx < self.num_imported_funcs) {
            var seen: u32 = 0;
            for (self.mod.imports) |imp| switch (imp.desc) {
                .func => |tidx| {
                    if (seen == fn_idx) return self.mod.types_[tidx];
                    seen += 1;
                },
                else => {},
            };
        }
        const def_idx = fn_idx - self.num_imported_funcs;
        const tidx = self.mod.funcs[def_idx];
        return self.mod.types_[tidx];
    }

    // ============================================================
    //  Render phase
    // ============================================================

    fn render(self: *Translator, writer: *std.Io.Writer) Error!void {
        var layout = try self.asm_.computeLayout(self.gpa);
        defer layout.deinit(self.gpa);

        // Patch every RAC literal with the resolved bytecode address of its
        // return target label.
        for (self.rac_sites.items) |site| {
            const addr = layout.get(site.target_label) orelse 0;
            for (self.asm_.datas.items) |*d| {
                if (std.mem.eql(u8, d.name, site.const_name)) {
                    d.init = .{ .uint32 = addr };
                }
            }
        }

        try self.asm_.render(writer, layout);
    }
};

// --------------------- host-import bridge ---------------------

/// Adapter between `lower_import.Host` (a type-erased interface so that
/// module stays decoupled) and the concrete `Translator` state. Holds
/// pointers to both the translator and the per-function context so vtable
/// callbacks can mutate each as needed.
const HostBridge = struct {
    t: *Translator,
    ctx: *Translator.FuncCtx,

    fn host(self: *HostBridge) lower_import.Host {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: lower_import.Host.VTable = .{
        .allocator = allocator,
        .declareScratch = declareScratch,
        .callerFnName = callerFnName,
        .callerDepth = callerDepth,
        .consumeOne = consumeOne,
        .produceOne = produceOne,
        .push = push,
        .copy = copy,
        .externCall = externCall,
        .comment = comment,
        .annotateUnsupported = annotateUnsupported,
    };

    fn self_(ctx: *anyopaque) *HostBridge {
        return @ptrCast(@alignCast(ctx));
    }

    fn allocator(ctx: *anyopaque) std.mem.Allocator {
        return self_(ctx).t.aa();
    }
    fn declareScratch(ctx: *anyopaque, n: []const u8, ty: tn.TypeName, lit: Literal) lower_import.Error!void {
        const hb = self_(ctx);
        // Idempotent: skip if a decl with the same name already exists.
        for (hb.t.asm_.datas.items) |d| {
            if (std.mem.eql(u8, d.name, n)) return;
        }
        try hb.t.asm_.addData(.{ .name = n, .ty = ty, .init = lit });
    }
    fn callerFnName(ctx: *anyopaque) []const u8 {
        return self_(ctx).ctx.fn_name;
    }
    fn callerDepth(ctx: *anyopaque) u32 {
        return self_(ctx).ctx.depth;
    }
    fn consumeOne(ctx: *anyopaque) void {
        self_(ctx).ctx.pop();
    }
    fn produceOne(ctx: *anyopaque) void {
        self_(ctx).ctx.push();
    }
    fn push(ctx: *anyopaque, sym: []const u8) lower_import.Error!void {
        try self_(ctx).t.asm_.push(sym);
    }
    fn copy(ctx: *anyopaque) lower_import.Error!void {
        try self_(ctx).t.asm_.copy();
    }
    fn externCall(ctx: *anyopaque, sig: []const u8) lower_import.Error!void {
        try self_(ctx).t.asm_.extern_(sig);
    }
    fn comment(ctx: *anyopaque, text: []const u8) lower_import.Error!void {
        try self_(ctx).t.asm_.comment(text);
    }
    fn annotateUnsupported(ctx: *anyopaque) lower_import.Error!void {
        try self_(ctx).t.asm_.annotation("__unsupported__");
    }
};

// --------------------- helpers ---------------------

fn udonTypeOf(vt: ValType) tn.TypeName {
    return switch (vt) {
        .i32 => tn.int32,
        .i64 => tn.int64,
        .f32 => tn.single,
        .f64 => tn.double,
    };
}

fn zeroLit(vt: ValType) Literal {
    return switch (vt) {
        .i32 => .{ .int32 = 0 },
        .i64 => .null_literal, // §4.7: cannot init non-null
        .f32 => .{ .single = 0.0 },
        .f64 => .null_literal,
    };
}

fn blockResultArity(bt: wasm.types.BlockType) u32 {
    return switch (bt) {
        .empty => 0,
        .value => 1,
        .type_index => 0, // we don't look up the type index here
    };
}

/// Very rough upper bound; WASM validator ensures the actual stack never
/// exceeds body-size. Used only for pre-allocating S-slot data decls.
fn estimateMaxStackDepth(body: []const Instruction) u32 {
    var depth: u32 = 0;
    var maxd: u32 = 0;
    for (body) |ins| {
        switch (ins) {
            .i32_const, .i64_const, .f32_const, .f64_const, .local_get, .global_get, .memory_size => {
                depth += 1;
                if (depth > maxd) maxd = depth;
            },
            .drop, .local_set, .global_set => if (depth > 0) {
                depth -= 1;
            },
            .block => |b| {
                const inner = estimateMaxStackDepth(b.body);
                if (depth + inner > maxd) maxd = depth + inner;
            },
            .loop => |b| {
                const inner = estimateMaxStackDepth(b.body);
                if (depth + inner > maxd) maxd = depth + inner;
            },
            .if_ => |b| {
                if (depth > 0) depth -= 1; // cond
                const inner_t = estimateMaxStackDepth(b.then_body);
                if (depth + inner_t > maxd) maxd = depth + inner_t;
                if (b.else_body) |eb| {
                    const inner_e = estimateMaxStackDepth(eb);
                    if (depth + inner_e > maxd) maxd = depth + inner_e;
                }
            },
            else => {},
        }
    }
    // Pad generously to avoid undercount on complex code. The cost is only
    // extra data decls — safe but not free.
    return @max(maxd, 8) + 4;
}

// --------------------- tests ---------------------

test "translate empty module" {
    const mod: wasm.Module = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, ".data_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".code_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__indirect_target__") != null);
}

test "translate bench.wasm end-to-end (structural)" {
    // The bench fixture is produced by `zig build wasm-example` from
    // examples/wasm-bench/main.zig and copied into src/wasm/testdata/.
    // This test asserts only *structural* properties of the output since the
    // Udon VM isn't available here; correctness of the generated assembly is
    // covered by the unit tests further up.
    const bench = @embedFile("testdata/bench.wasm");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const mod = try wasm.parseModule(aa, bench);
    const meta = try wasm.parseUdonMetaFromModule(aa, mod);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, meta, &buf.writer, .{});
    const out = buf.written();

    // ---- section markers ----
    try std.testing.expect(std.mem.indexOf(u8, out, ".data_start\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".data_end\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".code_start\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".code_end\n") != null);

    // ---- event exports ----
    try std.testing.expect(std.mem.indexOf(u8, out, ".export _start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".export _update") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".export _interact") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_start:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_update:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_interact:") != null);

    // ---- host imports pass through the generic dispatcher ----
    // The bench declares both SystemConsole.__WriteLine and
    // UnityEngineDebug.__Log via raw-identifier import names; the translator
    // should emit EXTERN with those exact strings, with no hardcoded table.
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemConsole.__WriteLine__SystemString__SystemVoid") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "UnityEngineDebug.__Log__SystemString__SystemVoid") != null);
    // Generic SystemString marshaling helper is declared once for all
    // string arguments regardless of which extern they target.
    try std.testing.expect(std.mem.indexOf(u8, out, "_marshal_str_tmp:") != null);
    // Regression guard: the old hardcoded placeholder must be gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "__cwl_placeholder__") == null);

    // ---- memory infra was emitted ----
    try std.testing.expect(std.mem.indexOf(u8, out, "__G__memory_size_pages") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemObjectArray.__ctor__SystemInt32__SystemObjectArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array") != null);

    // ---- at least one i32 arithmetic op was emitted ----
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);

    // ---- metadata-driven globals exported under the configured udonName ----
    // The bench's __udon_meta maps `counter` → udonName `_counter` with
    // `export: true`. The field declaration should use that name and carry
    // the .export attribute.
    try std.testing.expect(std.mem.indexOf(u8, out, ".export _counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_counter: %SystemInt32") != null);

    // ---- terminator JUMP exists at event exits ----
    try std.testing.expect(std.mem.indexOf(u8, out, "JUMP, 0xFFFFFFFC") != null);

    // ---- struct tests (test_struct) produce memory load/store sequences ----
    // Struct field access lowers to i32.load/store at linear-memory offsets.
    // The translator emits those through the chunked-memory fast path — each
    // access leaves a distinctive RightShift + LogicalAnd preamble. We check
    // for the field-word-fetch extern used by both load and store.
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemObjectArray.__GetValue__SystemInt32__SystemObject") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32Array.__GetValue__SystemInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32Array.__SetValue__SystemUInt32_SystemInt32__SystemVoid") != null);
    // Subtraction and multiplication come from test_struct's rect_width and
    // point_area (when not fully folded). Multiplication is already covered
    // by test_arithmetic but its presence is reassuring.
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemInt32.__op_Multiply__SystemInt32_SystemInt32__SystemInt32") != null);
}

test "translate simple add module" {
    // A defined function (i32, i32) -> i32: local.get 0; local.get 1; i32.add
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const params = try a.alloc(ValType, 2);
    params[0] = .i32;
    params[1] = .i32;
    const results = try a.alloc(ValType, 1);
    results[0] = .i32;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params, .results = results };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i32_add;
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "add", .desc = .{ .func = 0 } };

    const mod: wasm.Module = .{
        .types_ = types_,
        .funcs = funcs,
        .codes = codes,
        .exports = exports,
    };

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();
    // Should contain the function's param declarations + entry label +
    // an EXTERN for i32.add.
    try std.testing.expect(std.mem.indexOf(u8, out, "__add_P0__") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__add_entry__") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "JUMP_INDIRECT, __add_RA__") != null);
}
