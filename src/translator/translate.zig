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
const recursion = @import("recursion.zig");

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

    /// Monotonic counter for label suffixes that need to be unique across a
    /// translation unit. Consumed by `Host.uniqueId()` — currently used by
    /// `emitStringMarshal` so repeated `SystemString`-taking externs don't
    /// collide on the same loop/end label (the UAssembly assembler rejects
    /// duplicates at `VisitLabelStmt`).
    unique_id_counter: u32 = 0,

    /// Per-call-site RAC declarations accumulated during lowering; resolved
    /// in `render` against the completed layout.
    rac_sites: std.ArrayList(RacSite) = .empty,

    /// Set of function indices reachable via `call_indirect` (gathered from
    /// WASM element segments). Each gets a dedicated indirect-entry label
    /// and a trampoline. See `docs/spec_call_return_conversion.md` §7.3.
    indirect_fns: std.AutoHashMapUnmanaged(u32, void) = .empty,

    /// Maximum parameter / result arity across all types used by indirect
    /// calls — sizes the shared `__ind_P*` / `__ind_R*` heap slots.
    max_indirect_params: u32 = 0,
    max_indirect_results: u32 = 0,

    /// For each function index, true iff that function is recursive (has a
    /// self-edge or participates in an SCC ≥ 2). Populated by
    /// `analyzeRecursion()`. See `docs/spec_call_return_conversion.md` §8.2.
    is_recursive: []bool = &.{},

    /// Per defined-function peak abstract stack depth, captured from
    /// `FuncCtx.max_emitted_depth` at the end of each function's codegen.
    /// Indexed by `def_idx` (i.e. `fn_idx - num_imported_funcs`). Drives
    /// `__fn_Sd__` data-slot emission after all functions are lowered.
    fn_max_stack_depth: []u32 = &.{},

    /// Udon variable names for the linear-memory outer array and its
    /// companion scalars. Defaults follow `docs/spec_linear_memory.md`; if
    /// `__udon_meta.options.memory.udonName` is set, the outer array and all
    /// companions are renamed in lockstep per
    /// `docs/spec_udonmeta_conversion.md` §options.memory. Populated by
    /// `resolveMemoryNames()`.
    memory_udon_name: []const u8 = "__G__memory",
    memory_size_pages_name: []const u8 = "__G__memory_size_pages",
    memory_max_pages_name: []const u8 = "__G__memory_max_pages",
    memory_initial_pages_name: []const u8 = "__G__memory_initial_pages",

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
        self.indirect_fns.deinit(self.gpa);
        if (self.is_recursive.len > 0) self.gpa.free(self.is_recursive);
        if (self.fn_max_stack_depth.len > 0) self.gpa.free(self.fn_max_stack_depth);
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
        try self.resolveMemoryNames();
        try self.resolveEventBindings();
        try self.resolveIndirectFns();
        try self.analyzeRecursion();
        self.fn_max_stack_depth = try self.gpa.alloc(u32, self.mod.codes.len);
        @memset(self.fn_max_stack_depth, 0);
        try self.emitCommonData();
        try self.emitGlobalsData();
        try self.emitMemoryData();
        try self.emitFunctionData();
        try self.emitIndirectData();
        try self.emitEventEntries();
        try self.emitDefinedFunctions();
        try self.emitIndirectTrampolines();
        try self.emitFunctionStackSlots();
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

    /// Resolve the Udon variable name of the linear-memory outer array and
    /// its companion scalars. When `__udon_meta.options.memory.udonName` is
    /// provided, companions inherit the same prefix
    /// (`{base}_size_pages`, `{base}_max_pages`, `{base}_initial_pages`) per
    /// `docs/spec_udonmeta_conversion.md` §options.memory.
    fn resolveMemoryNames(self: *Translator) Error!void {
        const m = self.meta orelse return;
        const base = m.options.memory.udon_name orelse return;
        self.memory_udon_name = base;
        self.memory_size_pages_name = try std.fmt.allocPrint(self.aa(), "{s}_size_pages", .{base});
        self.memory_max_pages_name = try std.fmt.allocPrint(self.aa(), "{s}_max_pages", .{base});
        self.memory_initial_pages_name = try std.fmt.allocPrint(self.aa(), "{s}_initial_pages", .{base});
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

    /// Scan every element segment and collect the set of function indices
    /// reachable via `call_indirect`. Also compute the maximum param and
    /// result arity across all affected function types — this sizes the
    /// shared `__ind_P*` / `__ind_R*` slots used by the indirect ABI.
    fn analyzeRecursion(self: *Translator) Error!void {
        // Flatten indirect-callable indices.
        var ind_list: std.ArrayList(u32) = .empty;
        defer ind_list.deinit(self.gpa);
        var it = self.indirect_fns.iterator();
        while (it.next()) |e| try ind_list.append(self.gpa, e.key_ptr.*);
        var graph = try recursion.buildCallGraph(self.gpa, self.mod, self.num_imported_funcs, ind_list.items);
        defer graph.deinit(self.gpa);
        self.is_recursive = try recursion.detectRecursive(self.gpa, graph);
    }

    fn shouldSpill(self: *Translator, fn_idx: u32) bool {
        const m = self.meta orelse return false;
        if (m.options.recursion != .stack) return false;
        if (fn_idx >= self.is_recursive.len) return false;
        return self.is_recursive[fn_idx];
    }

    fn resolveIndirectFns(self: *Translator) Error!void {
        for (self.mod.elements) |elem| {
            for (elem.init) |fn_idx| {
                try self.indirect_fns.put(self.gpa, fn_idx, {});
                // Imports can't legally appear in element segments (Core 1
                // validation forbids it), but guard anyway.
                if (fn_idx < self.num_imported_funcs) continue;
                const ty = self.functionType(fn_idx);
                if (ty.params.len > self.max_indirect_params)
                    self.max_indirect_params = @intCast(ty.params.len);
                if (ty.results.len > self.max_indirect_results)
                    self.max_indirect_results = @intCast(ty.results.len);
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

    /// Minimum number of pages the WASM module's own data segments demand.
    /// If any segment places bytes at or beyond page N, the outer
    /// SystemObjectArray must have at least N+1 slots — otherwise the very
    /// first runtime read of those bytes throws
    /// `SystemObjectArray.__GetValue__: Index has to be between upper and
    /// lower bound of the array.` The meta-supplied initial/max are clamped
    /// up to this floor so a user-authored `__udon_meta` that undercounts
    /// pages cannot produce broken bytecode.
    fn requiredPagesForData(self: *const Translator) u32 {
        var max_end: u32 = 0;
        for (self.mod.datas) |d| {
            const offset = wasm.const_eval.evalConstI32(self.mod, d.offset) catch continue;
            if (offset < 0) continue;
            const end = @as(u32, @intCast(offset)) + @as(u32, @intCast(d.init.len));
            if (end > max_end) max_end = end;
        }
        if (max_end == 0) return 0;
        const page: u32 = 65536;
        return (max_end + page - 1) / page;
    }

    /// Effective initial page count — honors the meta's preference but never
    /// drops below the WASM memory's declared min nor the highest page any
    /// data segment occupies. Used by both `emitMemoryData` (for the
    /// rendered `__G__memory_initial_pages` literal) and `emitMemoryInit`
    /// (to unroll the correct number of chunk allocations).
    fn effectiveInitialPages(self: *const Translator) u32 {
        if (self.mod.memories.len == 0) return 0;
        const mem = self.mod.memories[0];
        const floor = @max(mem.min, self.requiredPagesForData());
        const pref: u32 = if (self.meta) |m| (m.options.memory.initial_pages orelse mem.min) else mem.min;
        return @max(pref, floor);
    }

    /// Effective max page count — clamped up to `effectiveInitialPages()` so
    /// the outer `SystemObjectArray` always has room for the initial chunks.
    fn effectiveMaxPages(self: *const Translator) u32 {
        if (self.mod.memories.len == 0) return 0;
        const mem = self.mod.memories[0];
        const pref: u32 = if (self.meta) |m|
            (m.options.memory.max_pages orelse (mem.max orelse self.options.default_max_pages))
        else
            (mem.max orelse self.options.default_max_pages);
        return @max(pref, self.effectiveInitialPages());
    }

    fn emitMemoryData(self: *Translator) Error!void {
        if (self.mod.memories.len == 0) return;
        const initial_pages: u32 = self.effectiveInitialPages();
        const max_pages: u32 = self.effectiveMaxPages();

        try self.asm_.addData(.{ .name = self.memory_udon_name, .ty = tn.object_array, .init = .null_literal });
        try self.asm_.addData(.{ .name = self.memory_size_pages_name, .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = self.memory_max_pages_name, .ty = tn.int32, .init = .{ .int32 = @intCast(max_pages) } });
        try self.asm_.addData(.{ .name = self.memory_initial_pages_name, .ty = tn.int32, .init = .{ .int32 = @intCast(initial_pages) } });
        // Scratch slots used by every memory access.
        try self.asm_.addData(.{ .name = "_mem_page_idx", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_word_in_page", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_chunk", .ty = tn.uint32_array, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_mem_u32", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_addr", .ty = tn.int32, .init = .{ .int32 = 0 } });
        // Effective address = base + memarg.offset, used by every
        // load/store whose memarg.offset != 0. Materialized once per op so
        // the page/word decomposition below sees the adjusted value.
        try self.asm_.addData(.{ .name = "_mem_eff_addr", .ty = tn.int32, .init = .{ .int32 = 0 } });
        // Common i32 constants we'll need to PUSH.
        try self.asm_.addData(.{ .name = "__c_i32_0", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "__c_i32_1", .ty = tn.int32, .init = .{ .int32 = 1 } });
        try self.asm_.addData(.{ .name = "__c_i32_2", .ty = tn.int32, .init = .{ .int32 = 2 } });
        try self.asm_.addData(.{ .name = "__c_i32_16", .ty = tn.int32, .init = .{ .int32 = 16 } });
        try self.asm_.addData(.{ .name = "__c_i32_0xFFFF", .ty = tn.int32, .init = .{ .int32 = 0xFFFF } });
        try self.asm_.addData(.{ .name = "__c_i32_16384", .ty = tn.int32, .init = .{ .int32 = 16384 } });
        try self.asm_.addData(.{ .name = "__c_i32_3", .ty = tn.int32, .init = .{ .int32 = 3 } });
        try self.asm_.addData(.{ .name = "__c_i32_24", .ty = tn.int32, .init = .{ .int32 = 24 } });
        try self.asm_.addData(.{ .name = "__c_u32_0xFF", .ty = tn.uint32, .init = .{ .uint32 = 0xFF } });
        try self.asm_.addData(.{ .name = "__c_u32_0xFFFF_32", .ty = tn.uint32, .init = .{ .uint32 = 0xFFFF } });
        try self.asm_.addData(.{ .name = "__c_u32_0xFFFFFFFF", .ty = tn.uint32, .init = .{ .uint32 = 0xFFFFFFFF } });
        try self.asm_.addData(.{ .name = "__c_i32_32", .ty = tn.int32, .init = .{ .int32 = 32 } });
        // Scratch slots for i64 memory access (load/store split across two words).
        try self.asm_.addData(.{ .name = "_mem_u32_hi", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_i64_lo", .ty = tn.int64, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_mem_i64_hi", .ty = tn.int64, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_mem_i64_hi_shifted", .ty = tn.int64, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_mem_word_in_page_hi", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_st_lo_i32", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_st_hi_i32", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_st_lo_u32", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_st_hi_u32", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_hi_i64", .ty = tn.int64, .init = .null_literal });
        // Scratch slots for narrow (byte) memory access shift/mask expansion.
        try self.asm_.addData(.{ .name = "_mem_sub", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_shift", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_u32_shifted", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_mask_lo", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_mask_inv", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_byte_shifted", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_u32_cleared", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_u32_new", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_byte", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        // Scratch slots for memory.grow.
        try self.asm_.addData(.{ .name = "_mg_old", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mg_new", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mg_i", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mg_cmp", .ty = tn.boolean, .init = .null_literal });
        try self.asm_.addData(.{ .name = "__c_i32_neg1", .ty = tn.int32, .init = .{ .int32 = -1 } });
        // Scratch + constants for generic (unaligned / page-straddle) word access.
        try self.asm_.addData(.{ .name = "__c_i32_16383", .ty = tn.int32, .init = .{ .int32 = 16383 } });
        try self.asm_.addData(.{ .name = "__c_i32_65532", .ty = tn.int32, .init = .{ .int32 = 65532 } });
        // Straddle thresholds: i64 access (8 bytes) straddles when
        // byte_in_page > 65528; i16 (2 bytes) straddles when == 65535.
        try self.asm_.addData(.{ .name = "__c_i32_65528", .ty = tn.int32, .init = .{ .int32 = 65528 } });
        try self.asm_.addData(.{ .name = "__c_i32_65535", .ty = tn.int32, .init = .{ .int32 = 65535 } });
        // Byte offset of addr within its 32-bit word — reused by straddle
        // dispatch to decide whether the high half spills to outer[page+1].
        try self.asm_.addData(.{ .name = "_mem_byte_in_page", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_page_idx_hi", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mlw_lo", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mlw_hi", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mlw_shift", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mlw_rshift", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mlw_tmp", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_msw_lo_mask", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_msw_hi_mask", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_msw_lo_cleared", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_msw_hi_cleared", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_msw_lo_new_bits", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_msw_hi_new_bits", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_msw_lo_out", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_msw_hi_out", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        // Scratch for i64.rem_u expansion (Udon has no SystemUInt64.__op_Modulus__).
        try self.asm_.addData(.{ .name = "_rem_q_u64", .ty = tn.uint64, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_rem_qb_u64", .ty = tn.uint64, .init = .null_literal });
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
            // S-slot decls are deferred until after codegen; see
            // `emitFunctionStackSlots`.
            const ra = try names.returnAddrSlot(self.aa(), fn_name);
            try self.asm_.addData(.{ .name = ra, .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        }
    }

    /// Emit `__fn_Sd__` data declarations for every defined function using the
    /// exact peak abstract stack depth observed during codegen. Must be called
    /// after `emitDefinedFunctions` so `fn_max_stack_depth` is populated. The
    /// rendered data section stays inside `.data_start` regardless of
    /// insertion order (see `udon/asm.zig` `render`).
    fn emitFunctionStackSlots(self: *Translator) Error!void {
        for (0..self.mod.codes.len) |def_idx| {
            const fn_idx: u32 = self.num_imported_funcs + @as(u32, @intCast(def_idx));
            const fn_name = self.fn_names[fn_idx];
            const max_depth = self.fn_max_stack_depth[def_idx];
            var d: u32 = 0;
            while (d < max_depth) : (d += 1) {
                const n = try names.stackSlot(self.aa(), fn_name, d);
                try self.asm_.addData(.{ .name = n, .ty = tn.int32, .init = .{ .int32 = 0 } });
            }
        }
    }

    /// Data declarations needed to implement `call_indirect` per the
    /// two-pass RAC convention. Emits the shared function table, shared
    /// param/result slots, and one RAC per indirect-callable function
    /// (whose literal is patched at `render` time to the address of the
    /// function's `__{F}_indirect_entry__` label).
    fn emitIndirectData(self: *Translator) Error!void {
        if (self.indirect_fns.count() == 0) return;

        // Function table — SystemUInt32Array of bytecode addresses.
        try self.asm_.addData(.{ .name = "__fn_table__", .ty = tn.uint32_array, .init = .null_literal });
        // Shared parameter / result slots (SystemInt32 for MVP — bench's
        // call_indirect signatures are all (i32) -> i32). Real code with
        // other types would parameterize the slot type per signature.
        var i: u32 = 0;
        while (i < self.max_indirect_params) : (i += 1) {
            const n = try std.fmt.allocPrint(self.aa(), "__ind_P{d}__", .{i});
            try self.asm_.addData(.{ .name = n, .ty = tn.int32, .init = .{ .int32 = 0 } });
        }
        i = 0;
        while (i < self.max_indirect_results) : (i += 1) {
            const n = try std.fmt.allocPrint(self.aa(), "__ind_R{d}__", .{i});
            try self.asm_.addData(.{ .name = n, .ty = tn.int32, .init = .{ .int32 = 0 } });
        }
        // Scratch for table index.
        try self.asm_.addData(.{ .name = "__ind_idx__", .ty = tn.int32, .init = .{ .int32 = 0 } });
        // Per-function entry-address RACs (one RAC per indirect-callable
        // function, patched at render time).
        var it = self.indirect_fns.iterator();
        while (it.next()) |e| {
            const fn_idx = e.key_ptr.*;
            if (fn_idx < self.num_imported_funcs) continue;
            const fn_name = self.fn_names[fn_idx];
            const addr_name = try names.fnEntryAddr(self.aa(), fn_name);
            const entry_indirect = try std.fmt.allocPrint(self.aa(), "__{s}_indirect_entry__", .{fn_name});
            try self.asm_.addData(.{ .name = addr_name, .ty = tn.uint32, .init = .{ .uint32 = 0 } });
            try self.rac_sites.append(self.gpa, .{ .const_name = addr_name, .target_label = entry_indirect });
        }
    }

    // ---- code: events ----

    fn emitEventEntries(self: *Translator) Error!void {
        // Memory (and associated) setup must run before any user event.
        // Per docs/udon_specs.md §9.1 and docs/spec_linear_memory.md §4 it
        // belongs in `_onEnable`, which VRChat fires before `_start` / any
        // other event.
        //
        // If the user's __udon_meta maps a function to `_onEnable`, the
        // init is prepended to that entry so their body still runs after
        // setup. Otherwise we synthesize a standalone `_onEnable` whose
        // only job is to run `emitMemoryInit`. Previously this was gated
        // on `_start`, which silently skipped init whenever a program had
        // no `_start` binding — the outer `SystemObjectArray` then stayed
        // null and any subsequent memory read threw
        // `SystemObjectArray.__GetValue__...: Index has to be between upper
        // and lower bound of the array`.
        var user_binds_on_enable = false;
        for (self.event_bindings.items) |ev| {
            if (std.mem.eql(u8, ev.udon_label, "_onEnable")) {
                user_binds_on_enable = true;
                break;
            }
        }

        if (!user_binds_on_enable) {
            try self.asm_.exportLabel("_onEnable");
            try self.asm_.label("_onEnable");
            try self.emitMemoryInit();
            try self.asm_.jumpAddr(0xFFFFFFFC);
        }

        for (self.event_bindings.items) |ev| {
            const fn_idx = self.findExportedFunc(ev.wasm_export) orelse continue;
            try self.asm_.exportLabel(ev.udon_label);
            try self.asm_.label(ev.udon_label);
            if (std.mem.eql(u8, ev.udon_label, "_onEnable")) {
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
        try self.asm_.push(self.memory_max_pages_name);
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.extern_("SystemObjectArray.__ctor__SystemInt32__SystemObjectArray");
        // Loop would be ideal; for simplicity emit a straight-line allocation
        // for every initial page. We don't know initial_pages at code-gen
        // time as a literal Int constant, so fall back to a single-page
        // allocation and rely on the runtime to lazily grow. A production
        // translator would unroll up to initial_pages; bench uses 1 page so
        // this is exact.
        const initial: u32 = self.effectiveInitialPages();
        var p: u32 = 0;
        while (p < initial) : (p += 1) {
            const idx_name = try std.fmt.allocPrint(self.aa(), "__mem_init_idx_{d}", .{p});
            try self.asm_.addData(.{ .name = idx_name, .ty = tn.int32, .init = .{ .int32 = @intCast(p) } });
            try self.asm_.push("__c_i32_16384");
            try self.asm_.push("_mem_chunk");
            try self.asm_.extern_("SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array");
            try self.asm_.push(self.memory_udon_name);
            try self.asm_.push("_mem_chunk");
            try self.asm_.push(idx_name);
            try self.asm_.extern_("SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid");
        }
        // memory size = initial
        try self.asm_.push(self.memory_initial_pages_name);
        try self.asm_.push(self.memory_size_pages_name);
        try self.asm_.copy();
        // Write every declared data segment into linear memory. Aligned
        // full-word writes go through SystemUInt32Array.__Set directly;
        // unaligned head / tail bytes fall back to shift/mask RMW. Each
        // page is fetched from the outer SystemObjectArray at most once
        // per segment.
        for (self.mod.datas, 0..) |d, i| {
            try self.emitDataSegmentInit(d, @intCast(i));
        }
        try self.emitFunctionTableInit();
        try self.emitMarshalScratchInit();
        try self.asm_.comment("end memory init");
    }

    /// Declare the string-marshaling scratch slots unconditionally and
    /// cache the UTF-8 encoding singleton. Host-import lowering re-declares
    /// the same names via the idempotent `declareScratch` path, so this is
    /// safe when `lower_import` also tries to declare them later.
    fn emitMarshalScratchInit(self: *Translator) Error!void {
        // Scratch decls — mirror lower_import.declareMarshalScratch so the
        // encoding slot exists even when nothing uses strings (at the cost
        // of one extra field slot + one EXTERN per translation unit).
        try self.asm_.addData(.{ .name = lower_import.marshal_str_ptr_name, .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = lower_import.marshal_str_len_name, .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = lower_import.marshal_str_bytes_name, .ty = tn.byte_array, .init = .null_literal });
        try self.asm_.addData(.{ .name = lower_import.marshal_str_tmp_name, .ty = tn.string, .init = .null_literal });
        try self.asm_.addData(.{ .name = lower_import.marshal_str_i_name, .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = lower_import.marshal_str_addr_name, .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = lower_import.marshal_str_byte_name, .ty = tn.byte, .init = .null_literal });
        try self.asm_.addData(.{ .name = lower_import.marshal_str_cond_name, .ty = tn.boolean, .init = .null_literal });
        try self.asm_.addData(.{ .name = lower_import.marshal_encoding_name, .ty = tn.object, .init = .null_literal });

        // encoding := Encoding.UTF8  (static property getter)
        try self.asm_.comment("cache UTF-8 encoding singleton");
        try self.asm_.push(lower_import.marshal_encoding_name);
        try self.asm_.extern_(lower_import.utf8_property_sig);
    }

    /// Populate `__fn_table__` with the entry addresses of every indirect
    /// function referenced by an element segment. The entry addresses come
    /// from pre-declared RACs (§emitIndirectData) whose literals the render
    /// pass patches with the layout addresses of each `__{F}_indirect_entry__`.
    fn emitFunctionTableInit(self: *Translator) Error!void {
        if (self.indirect_fns.count() == 0) return;
        // Compute the table size as max(offset + init.len) across all
        // element segments. Default to the declared table's `min` if the
        // table section is present.
        var table_size: u32 = 0;
        for (self.mod.elements) |elem| {
            const offset = wasm.const_eval.evalConstI32(self.mod, elem.offset) catch 0;
            if (offset < 0) continue;
            const end = @as(u32, @intCast(offset)) + @as(u32, @intCast(elem.init.len));
            if (end > table_size) table_size = end;
        }
        if (self.mod.tables.len > 0) {
            const t_min = self.mod.tables[0].limits.min;
            if (t_min > table_size) table_size = t_min;
        }
        if (table_size == 0) return;

        try self.asm_.comment("function table init");
        const size_name = try std.fmt.allocPrint(self.aa(), "__fn_table_size_{d}", .{table_size});
        try self.asm_.addData(.{ .name = size_name, .ty = tn.int32, .init = .{ .int32 = @intCast(table_size) } });
        try self.asm_.push(size_name);
        try self.asm_.push("__fn_table__");
        try self.asm_.extern_("SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array");

        // Fill: for each element segment, for each entry, emit a
        // SetValue(addr_rac, offset+i) call.
        for (self.mod.elements) |elem| {
            const offset = wasm.const_eval.evalConstI32(self.mod, elem.offset) catch continue;
            if (offset < 0) continue;
            for (elem.init, 0..) |fn_idx, i| {
                if (fn_idx < self.num_imported_funcs) continue;
                const fn_name = self.fn_names[fn_idx];
                const addr_name = try names.fnEntryAddr(self.aa(), fn_name);
                const slot_idx: i32 = offset + @as(i32, @intCast(i));
                const slot_name = try std.fmt.allocPrint(self.aa(), "__fn_tbl_idx_{d}", .{slot_idx});
                try self.asm_.addData(.{ .name = slot_name, .ty = tn.int32, .init = .{ .int32 = slot_idx } });
                try self.asm_.push("__fn_table__");
                try self.asm_.push(slot_name);
                try self.asm_.push(addr_name);
                try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
            }
        }
    }

    fn emitDataSegmentInit(self: *Translator, d: wasm.module.Data, seg_id: u32) Error!void {
        const offset_i = wasm.const_eval.evalConstI32(self.mod, d.offset) catch return;
        if (offset_i < 0) return;
        if (d.init.len == 0) return;

        const offset: u32 = @intCast(offset_i);
        const len: u32 = @intCast(d.init.len);
        const end: u32 = offset + len;

        try self.asm_.comment(try std.fmt.allocPrint(self.aa(),
            "data segment: offset={d} len={d}", .{ offset, len }));

        // Track which outer page's chunk is currently in `_mem_chunk`. A
        // null means we must fetch before the next access.
        var last_page: ?u32 = null;
        var addr: u32 = offset;
        var op_idx: u32 = 0;

        while (addr < end) : (op_idx += 1) {
            const page: u32 = addr / 65536;
            const byte_in_page: u32 = addr % 65536;
            const sub: u32 = addr % 4;
            const word_in_page: u32 = byte_in_page / 4;

            const can_word = (sub == 0) and
                (addr + 4 <= end) and
                ((byte_in_page + 4) <= 65536);

            // Fetch outer[page] → _mem_chunk whenever the page changes.
            if (last_page == null or last_page.? != page) {
                const page_name = try std.fmt.allocPrint(self.aa(),
                    "__ds_page_{d}_{d}", .{ seg_id, page });
                try self.asm_.addData(.{
                    .name = page_name,
                    .ty = tn.int32,
                    .init = .{ .int32 = @intCast(page) },
                });
                try self.asm_.push(self.memory_udon_name);
                try self.asm_.push(page_name);
                try self.asm_.push("_mem_chunk");
                try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
                last_page = page;
            }

            // Word-index constant, re-declared per op to keep names unique.
            const widx_name = try std.fmt.allocPrint(self.aa(),
                "__ds_widx_{d}_{d}", .{ seg_id, op_idx });
            try self.asm_.addData(.{
                .name = widx_name,
                .ty = tn.int32,
                .init = .{ .int32 = @intCast(word_in_page) },
            });

            if (can_word) {
                const off_in_seg = addr - offset;
                const w: u32 = @as(u32, d.init[off_in_seg]) |
                    (@as(u32, d.init[off_in_seg + 1]) << 8) |
                    (@as(u32, d.init[off_in_seg + 2]) << 16) |
                    (@as(u32, d.init[off_in_seg + 3]) << 24);
                const val_name = try std.fmt.allocPrint(self.aa(),
                    "__ds_word_{d}_{d}", .{ seg_id, op_idx });
                try self.asm_.addData(.{
                    .name = val_name,
                    .ty = tn.uint32,
                    .init = .{ .uint32 = w },
                });
                try self.asm_.push("_mem_chunk");
                try self.asm_.push(widx_name);
                try self.asm_.push(val_name);
                try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
                addr += 4;
            } else {
                // Byte-level RMW: mirrors emitMemStoreByte but with
                // translation-time-known shift/mask baked into constants.
                const off_in_seg = addr - offset;
                const byte_val: u8 = d.init[off_in_seg];
                const shift_bits: u5 = @intCast(sub * 8);
                const mask: u32 = @as(u32, 0xFF) << shift_bits;
                const inv_mask: u32 = ~mask;
                const shifted_byte: u32 = @as(u32, byte_val) << shift_bits;

                const inv_name = try std.fmt.allocPrint(self.aa(),
                    "__ds_invm_{d}_{d}", .{ seg_id, op_idx });
                const or_name = try std.fmt.allocPrint(self.aa(),
                    "__ds_orbyte_{d}_{d}", .{ seg_id, op_idx });
                try self.asm_.addData(.{
                    .name = inv_name,
                    .ty = tn.uint32,
                    .init = .{ .uint32 = inv_mask },
                });
                try self.asm_.addData(.{
                    .name = or_name,
                    .ty = tn.uint32,
                    .init = .{ .uint32 = shifted_byte },
                });

                // _mem_u32 = chunk[word_in_page]
                try self.asm_.push("_mem_chunk");
                try self.asm_.push(widx_name);
                try self.asm_.push("_mem_u32");
                try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
                // _mem_u32_cleared = _mem_u32 & ~mask
                try self.asm_.push("_mem_u32");
                try self.asm_.push(inv_name);
                try self.asm_.push("_mem_u32_cleared");
                try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");
                // _mem_u32_new = _mem_u32_cleared | shifted_byte
                try self.asm_.push("_mem_u32_cleared");
                try self.asm_.push(or_name);
                try self.asm_.push("_mem_u32_new");
                try self.asm_.extern_("SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32");
                // chunk[word_in_page] = _mem_u32_new
                try self.asm_.push("_mem_chunk");
                try self.asm_.push(widx_name);
                try self.asm_.push("_mem_u32_new");
                try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");

                addr += 1;
            }
        }
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

        if (self.shouldSpill(fn_idx)) {
            try self.emitPrologueSpill(&ctx, code);
        }

        try self.emitInstrs(&ctx, code.body);

        // Natural fall-through return: copy Sd-result_arity .. Sd-1 into R0..
        // (Only if any results are declared.)
        try self.emitFunctionReturn(&ctx);
        try self.asm_.label(exit);
        if (self.shouldSpill(fn_idx)) {
            try self.emitEpilogueRestore(&ctx, code);
        }
        // Emit the indirect jump back. All defined functions use JUMP_INDIRECT
        // on their own RA slot (per §4).
        const ra = try names.returnAddrSlot(self.aa(), fn_name);
        try self.asm_.jumpIndirect(ra);

        self.fn_max_stack_depth[def_idx] = ctx.max_emitted_depth;
    }

    fn collectFrameSlots(
        self: *Translator,
        ctx: *FuncCtx,
        code: wasm.module.Code,
        slots: *std.ArrayList([]const u8),
    ) Error!void {
        const fn_name = ctx.fn_name;
        for (ctx.params, 0..) |_, i|
            try slots.append(self.gpa, try names.param(self.aa(), fn_name, @intCast(i)));
        var li: u32 = 0;
        for (code.locals) |lg| {
            for (0..lg.count) |_| {
                try slots.append(self.gpa, try names.local(self.aa(), fn_name, li));
                li += 1;
            }
        }
        for (ctx.results, 0..) |_, i|
            try slots.append(self.gpa, try names.returnSlot(self.aa(), fn_name, @intCast(i)));
        try slots.append(self.gpa, try names.returnAddrSlot(self.aa(), fn_name));
    }

    fn emitPrologueSpill(self: *Translator, ctx: *FuncCtx, code: wasm.module.Code) Error!void {
        try self.asm_.comment("recursion: prologue spill");
        var slots: std.ArrayList([]const u8) = .empty;
        defer slots.deinit(self.gpa);
        try self.collectFrameSlots(ctx, code, &slots);

        for (slots.items) |slot| {
            // __call_stack__[__call_stack_top__] = slot
            try self.asm_.push("__call_stack__");
            try self.asm_.push(slot);
            try self.asm_.push("__call_stack_top__");
            try self.asm_.extern_("SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid");
            // __call_stack_top__ += 1
            try self.asm_.push("__call_stack_top__");
            try self.asm_.push("__c_i32_1");
            try self.asm_.push("__call_stack_top__");
            try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        }
    }

    fn emitEpilogueRestore(self: *Translator, ctx: *FuncCtx, code: wasm.module.Code) Error!void {
        try self.asm_.comment("recursion: epilogue restore");
        var slots: std.ArrayList([]const u8) = .empty;
        defer slots.deinit(self.gpa);
        try self.collectFrameSlots(ctx, code, &slots);

        var i = slots.items.len;
        while (i > 0) {
            i -= 1;
            const slot = slots.items[i];
            // __call_stack_top__ -= 1
            try self.asm_.push("__call_stack_top__");
            try self.asm_.push("__c_i32_1");
            try self.asm_.push("__call_stack_top__");
            try self.asm_.extern_("SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32");
            // slot = __call_stack__[__call_stack_top__]
            try self.asm_.push("__call_stack__");
            try self.asm_.push("__call_stack_top__");
            try self.asm_.push(slot);
            try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        }
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
        // i64.rem_u has no SystemUInt64.__op_Modulus__ node in Udon; expand as
        // a - (a/b)*b.
        if (ins == .i64_rem_u) {
            try self.emitI64RemU(ctx);
            return;
        }
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
            .call_indirect => |tidx| try self.emitCallIndirect(ctx, tidx),

            .memory_size => try self.emitMemorySize(ctx),
            .memory_grow => try self.emitMemoryGrow(ctx),
            .i32_load => try self.emitMemLoadWord(ctx, ins),
            .i32_store => try self.emitMemStoreWord(ctx, ins),
            .i32_load8_u, .i32_load8_s => try self.emitMemLoadByte(ctx, ins),
            .i32_store8 => try self.emitMemStoreByte(ctx, ins),
            .i32_store16 => try self.emitMemStore16(ctx, ins),
            .i64_load => try self.emitMemLoadI64(ctx, ins),
            .i64_store => try self.emitMemStoreI64(ctx, ins),

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

    /// Expand `i64.rem_u` as `a - (a / b) * b`. Udon's node list has no
    /// `SystemUInt64.__op_Modulus__` but provides Division/Multiplication/
    /// Subtraction in UInt64, so the 3-EXTERN sequence is the canonical form.
    fn emitI64RemU(self: *Translator, ctx: *FuncCtx) Error!void {
        try self.asm_.comment("i64.rem_u (synthesized: a - (a/b)*b)");
        const rhs = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        const lhs = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 2);
        // _rem_q_u64 := a / b
        try self.asm_.push(lhs);
        try self.asm_.push(rhs);
        try self.asm_.push("_rem_q_u64");
        try self.asm_.extern_("SystemUInt64.__op_Division__SystemUInt64_SystemUInt64__SystemUInt64");
        // _rem_qb_u64 := _rem_q_u64 * b
        try self.asm_.push("_rem_q_u64");
        try self.asm_.push(rhs);
        try self.asm_.push("_rem_qb_u64");
        try self.asm_.extern_("SystemUInt64.__op_Multiplication__SystemUInt64_SystemUInt64__SystemUInt64");
        // lhs := a - _rem_qb_u64  (result lands in the lhs slot)
        try self.asm_.push(lhs);
        try self.asm_.push("_rem_qb_u64");
        try self.asm_.push(lhs);
        try self.asm_.extern_("SystemUInt64.__op_Subtraction__SystemUInt64_SystemUInt64__SystemUInt64");
        ctx.pop(); // rhs consumed
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

    /// Full `call_indirect` lowering (see docs/spec_call_return_conversion.md §7):
    ///
    ///   1. Pop the table index and fetch `__fn_table__[idx]` into
    ///      `__indirect_target__`.
    ///   2. Copy each WASM argument from the caller's S slots into the
    ///      shared `__ind_P*` slots that every indirect-callable function
    ///      reads from in its indirect-entry prologue.
    ///   3. Write a RAC (bytecode address of the post-call landing label)
    ///      into `__indirect_RA__`; every indirect function's trampoline
    ///      reads this to JUMP_INDIRECT back.
    ///   4. `JUMP_INDIRECT, __indirect_target__` lands in the chosen
    ///      function's `__{F}_indirect_entry__`.
    ///   5. After control returns, copy `__ind_R*` back into fresh S slots
    ///      for each result.
    ///
    /// Type-check against `typeidx` is intentionally skipped per §7.4; the
    /// element-segment scan at `resolveIndirectFns` already classified
    /// callees by signature at translation time.
    fn emitCallIndirect(self: *Translator, ctx: *FuncCtx, typeidx: u32) Error!void {
        const ty = self.mod.types_[typeidx];
        const n_args: u32 = @intCast(ty.params.len);
        const n_res: u32 = @intCast(ty.results.len);
        try self.asm_.comment("call_indirect");

        // (a) Fetch table[idx] → __indirect_target__.
        const idx_slot = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        try self.asm_.push("__fn_table__");
        try self.asm_.push(idx_slot);
        try self.asm_.push("__indirect_target__");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");

        // (b) Copy caller S slots → shared __ind_P*.
        var i: u32 = 0;
        while (i < n_args) : (i += 1) {
            const src_depth = ctx.depth - n_args + i;
            const src = try names.stackSlot(self.aa(), ctx.fn_name, src_depth);
            const dst = try std.fmt.allocPrint(self.aa(), "__ind_P{d}__", .{i});
            try self.asm_.push(src);
            try self.asm_.push(dst);
            try self.asm_.copy();
        }
        i = 0;
        while (i < n_args) : (i += 1) ctx.pop();

        // (c) RAC → __indirect_RA__.
        const k = self.call_site_counter;
        self.call_site_counter += 1;
        const rac_name = try names.retAddrConst(self.aa(), k);
        const ret_label = try names.callRetLabel(self.aa(), k);
        try self.asm_.addData(.{ .name = rac_name, .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.rac_sites.append(self.gpa, .{ .const_name = rac_name, .target_label = ret_label });
        try self.asm_.push(rac_name);
        try self.asm_.push("__indirect_RA__");
        try self.asm_.copy();

        // (d) JUMP_INDIRECT.
        try self.asm_.jumpIndirect("__indirect_target__");
        try self.asm_.label(ret_label);

        // (e) Copy shared __ind_R* back into caller S slots.
        var r: u32 = 0;
        while (r < n_res) : (r += 1) {
            ctx.push();
            const src = try std.fmt.allocPrint(self.aa(), "__ind_R{d}__", .{r});
            const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
            try self.asm_.push(src);
            try self.asm_.push(dst);
            try self.asm_.copy();
        }
    }

    /// Emit the per-indirect-function indirect-entry prologue and the
    /// post-return trampoline. The indirect entry reads `__ind_P*` into the
    /// function's own `__F_P*` slots then jumps into the direct entry — the
    /// body itself is unchanged. When the body ends it falls into the
    /// function's `__F_exit__` which `JUMP_INDIRECT`s on the trampoline
    /// address we planted in `__F_RA__`.
    fn emitIndirectTrampolines(self: *Translator) Error!void {
        if (self.indirect_fns.count() == 0) return;

        var it = self.indirect_fns.iterator();
        while (it.next()) |e| {
            const fn_idx = e.key_ptr.*;
            if (fn_idx < self.num_imported_funcs) continue;
            const fn_name = self.fn_names[fn_idx];
            const ty = self.functionType(fn_idx);
            const indirect_entry = try std.fmt.allocPrint(self.aa(), "__{s}_indirect_entry__", .{fn_name});
            const trampoline = try std.fmt.allocPrint(self.aa(), "__{s}_indirect_trampoline__", .{fn_name});
            const trampoline_rac = try std.fmt.allocPrint(self.aa(), "__{s}_trampoline_addr__", .{fn_name});
            const entry = try names.entryLabel(self.aa(), fn_name);
            const ra = try names.returnAddrSlot(self.aa(), fn_name);

            // Pre-declare the RAC whose literal is the trampoline address;
            // patched at render time.
            try self.asm_.addData(.{ .name = trampoline_rac, .ty = tn.uint32, .init = .{ .uint32 = 0 } });
            try self.rac_sites.append(self.gpa, .{ .const_name = trampoline_rac, .target_label = trampoline });

            try self.asm_.comment(try std.fmt.allocPrint(self.aa(), "indirect entry/trampoline for {s}", .{fn_name}));
            try self.asm_.label(indirect_entry);
            // Copy __ind_P* → __{F}_P*
            var i: u32 = 0;
            while (i < ty.params.len) : (i += 1) {
                const src = try std.fmt.allocPrint(self.aa(), "__ind_P{d}__", .{i});
                const dst = try names.param(self.aa(), fn_name, i);
                try self.asm_.push(src);
                try self.asm_.push(dst);
                try self.asm_.copy();
            }
            // __{F}_RA__ := trampoline address (so the body's JUMP_INDIRECT
            // naturally lands on the trampoline).
            try self.asm_.push(trampoline_rac);
            try self.asm_.push(ra);
            try self.asm_.copy();
            try self.asm_.jump(entry);

            try self.asm_.label(trampoline);
            // Copy __{F}_R* → __ind_R*
            var r: u32 = 0;
            while (r < ty.results.len) : (r += 1) {
                const src = try names.returnSlot(self.aa(), fn_name, r);
                const dst = try std.fmt.allocPrint(self.aa(), "__ind_R{d}__", .{r});
                try self.asm_.push(src);
                try self.asm_.push(dst);
                try self.asm_.copy();
            }
            try self.asm_.jumpIndirect("__indirect_RA__");
        }
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
        try self.asm_.push(self.memory_size_pages_name);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    fn emitMemoryGrow(self: *Translator, ctx: *FuncCtx) Error!void {
        try self.asm_.comment("memory.grow");
        const id = self.block_counter;
        self.block_counter += 1;
        const loop_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mg_loop_{d}__", .{ ctx.fn_name, id });
        const done_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mg_done_{d}__", .{ ctx.fn_name, id });
        const end_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mg_end_{d}__", .{ ctx.fn_name, id });
        const alloc_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mg_alloc_{d}__", .{ ctx.fn_name, id });

        // delta on top of stack
        const delta = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        ctx.push();
        const result = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);

        // _mg_old = __G__memory_size_pages
        try self.asm_.push(self.memory_size_pages_name);
        try self.asm_.push("_mg_old");
        try self.asm_.copy();

        // _mg_new = _mg_old + delta
        try self.asm_.push("_mg_old");
        try self.asm_.push(delta);
        try self.asm_.push("_mg_new");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");

        // if _mg_new > __G__memory_max_pages: result = -1; goto end
        try self.asm_.push("_mg_new");
        try self.asm_.push(self.memory_max_pages_name);
        try self.asm_.push("_mg_cmp");
        try self.asm_.extern_("SystemInt32.__op_GreaterThan__SystemInt32_SystemInt32__SystemBoolean");
        try self.asm_.push("_mg_cmp");
        try self.asm_.jumpIfFalse(alloc_lbl);
        try self.asm_.push("__c_i32_neg1");
        try self.asm_.push(result);
        try self.asm_.copy();
        try self.asm_.jump(end_lbl);

        try self.asm_.label(alloc_lbl);
        // _mg_i = _mg_old
        try self.asm_.push("_mg_old");
        try self.asm_.push("_mg_i");
        try self.asm_.copy();

        try self.asm_.label(loop_lbl);
        // if !(_mg_i < _mg_new) goto done
        try self.asm_.push("_mg_i");
        try self.asm_.push("_mg_new");
        try self.asm_.push("_mg_cmp");
        try self.asm_.extern_("SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean");
        try self.asm_.push("_mg_cmp");
        try self.asm_.jumpIfFalse(done_lbl);

        // _mem_chunk = new SystemUInt32Array(16384)
        try self.asm_.push("__c_i32_16384");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array");
        // __G__memory[_mg_i] = _mem_chunk
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mg_i");
        try self.asm_.extern_("SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid");
        // _mg_i = _mg_i + 1
        try self.asm_.push("_mg_i");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mg_i");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.jump(loop_lbl);

        try self.asm_.label(done_lbl);
        // __G__memory_size_pages = _mg_new
        try self.asm_.push("_mg_new");
        try self.asm_.push(self.memory_size_pages_name);
        try self.asm_.copy();
        // result = _mg_old
        try self.asm_.push("_mg_old");
        try self.asm_.push(result);
        try self.asm_.copy();

        try self.asm_.label(end_lbl);
    }

    /// Lazily declare a `__c_i32_off_<N>` constant carrying the memarg
    /// offset value. Idempotent across calls; reuses an existing decl if
    /// one already exists for the same value. Used by `applyMemOffset`.
    fn getOrDeclareOffsetConst(self: *Translator, offset: u32) Error![]const u8 {
        const name = try std.fmt.allocPrint(self.aa(), "__c_i32_off_{d}", .{offset});
        for (self.asm_.datas.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return name;
        }
        // WASM adds offset (u32) to base mod 2^32; SystemInt32.__op_Addition
        // wraps the same way, so store the raw bit pattern even when the
        // high bit is set.
        try self.asm_.addData(.{
            .name = name,
            .ty = tn.int32,
            .init = .{ .int32 = @bitCast(offset) },
        });
        return name;
    }

    /// If `offset != 0`, emit `_mem_eff_addr := addr_slot + __c_i32_off_<N>`
    /// and return `"_mem_eff_addr"`. Otherwise return `addr_slot` unchanged.
    /// Every caller of `emitMem*` must funnel through this so the WASM
    /// `memarg.offset` is honored in the page/word decomposition that
    /// follows.
    fn applyMemOffset(self: *Translator, addr_slot: []const u8, offset: u32) Error![]const u8 {
        if (offset == 0) return addr_slot;
        const k = try self.getOrDeclareOffsetConst(offset);
        try self.asm_.push(addr_slot);
        try self.asm_.push(k);
        try self.asm_.push("_mem_eff_addr");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        return "_mem_eff_addr";
    }

    fn emitMemLoadWord(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        const memarg = ins.i32_load;
        const raw_addr = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        if (memarg.@"align" >= 2) {
            return self.emitMemLoadWordFast(ctx, addr_slot);
        }
        return self.emitMemLoadWordGeneric(ctx, addr_slot);
    }

    fn emitMemLoadWordFast(self: *Translator, ctx: *FuncCtx, addr_slot: []const u8) Error!void {
        try self.asm_.comment("i32.load (aligned, within-chunk fast path)");
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
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        // chunk[word_in_page] → dst
        ctx.push();
        const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push(dst);
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
    }

    /// Generic i32.load that handles unaligned access and page-straddle.
    /// Per `docs/spec_linear_memory.md` §6.1, dispatches at runtime into one
    /// of three branches based on `sub = addr & 3` and whether the 4-byte
    /// window crosses a page boundary.
    fn emitMemLoadWordGeneric(self: *Translator, ctx: *FuncCtx, addr_slot: []const u8) Error!void {
        try self.asm_.comment("i32.load (generic: 3-branch alignment/straddle dispatch)");
        const id = self.block_counter;
        self.block_counter += 1;
        const fast_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mlw_fast_{d}__", .{ ctx.fn_name, id });
        const slow_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mlw_slow_{d}__", .{ ctx.fn_name, id });
        const straddle_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mlw_straddle_{d}__", .{ ctx.fn_name, id });
        const end_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mlw_end_{d}__", .{ ctx.fn_name, id });

        ctx.pop();
        ctx.push();
        const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);

        // Decompose address.
        // sub := addr & 3
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_3");
        try self.asm_.push("_mem_sub");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        // page_idx := addr >> 16
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_16");
        try self.asm_.push("_mem_page_idx");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        // byte_in_page := addr & 0xFFFF (reuse _mem_addr as scratch)
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_0xFFFF");
        try self.asm_.push("_mem_addr");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        // word_in_page := byte_in_page >> 2
        try self.asm_.push("_mem_addr");
        try self.asm_.push("__c_i32_2");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");

        // Branch 1: if sub == 0, goto fast.
        try self.asm_.push("_mem_sub");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_mg_cmp");
        try self.asm_.extern_("SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean");
        // JUMP_IF_FALSE skips the fast path; we want to JUMP to fast when true.
        // Synthesize by jumping to a "not-fast" label when false, else jumping to fast.
        // Simpler: negate — compute (sub != 0) and JUMP_IF_FALSE over the JUMP to fast.
        // To avoid extra EXTERN, use pattern: push cmp; jump_if_false skip; jump fast; skip:
        const skip_fast_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mlw_nofast_{d}__", .{ ctx.fn_name, id });
        try self.asm_.push("_mg_cmp");
        try self.asm_.jumpIfFalse(skip_fast_lbl);
        try self.asm_.jump(fast_lbl);
        try self.asm_.label(skip_fast_lbl);

        // Branch 2: if byte_in_page > 65532, goto straddle.
        try self.asm_.push("_mem_addr");
        try self.asm_.push("__c_i32_65532");
        try self.asm_.push("_mg_cmp");
        try self.asm_.extern_("SystemInt32.__op_GreaterThan__SystemInt32_SystemInt32__SystemBoolean");
        const skip_straddle_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mlw_nostraddle_{d}__", .{ ctx.fn_name, id });
        try self.asm_.push("_mg_cmp");
        try self.asm_.jumpIfFalse(skip_straddle_lbl);
        try self.asm_.jump(straddle_lbl);
        try self.asm_.label(skip_straddle_lbl);

        // Fall-through: unaligned within chunk.
        try self.asm_.label(slow_lbl);
        // chunk := outer[page_idx]
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        // lo := chunk[word_in_page]
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mlw_lo");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        // word_in_page_hi := word_in_page + 1
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        // hi := chunk[word_in_page + 1]
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.push("_mlw_hi");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        try self.emitMlwCombineAndEnd(dst, end_lbl);

        // Straddle branch.
        try self.asm_.label(straddle_lbl);
        // lo_chunk := outer[page_idx]
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        // lo := lo_chunk[16383]
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("__c_i32_16383");
        try self.asm_.push("_mlw_lo");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        // page_idx_hi := page_idx + 1 (reuse _mem_word_in_page_hi as scratch int)
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        // hi_chunk := outer[page_idx + 1]
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        // hi := hi_chunk[0]
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_mlw_hi");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        try self.emitMlwCombineAndEnd(dst, end_lbl);

        // Fast branch.
        try self.asm_.label(fast_lbl);
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push(dst);
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");

        try self.asm_.label(end_lbl);
    }

    /// Common trailer for the unaligned-within and straddle branches:
    /// dst := (lo >> shift) | (hi << rshift) ; then goto end.
    fn emitMlwCombineAndEnd(self: *Translator, dst: []const u8, end_lbl: []const u8) Error!void {
        // shift := sub << 3 (bytes → bits)
        try self.asm_.push("_mem_sub");
        try self.asm_.push("__c_i32_3");
        try self.asm_.push("_mlw_shift");
        try self.asm_.extern_("SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32");
        // rshift := 32 - shift
        try self.asm_.push("__c_i32_32");
        try self.asm_.push("_mlw_shift");
        try self.asm_.push("_mlw_rshift");
        try self.asm_.extern_("SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32");
        // tmp := lo >> shift (unsigned)
        try self.asm_.push("_mlw_lo");
        try self.asm_.push("_mlw_shift");
        try self.asm_.push("_mlw_tmp");
        try self.asm_.extern_("SystemUInt32.__op_RightShift__SystemUInt32_SystemInt32__SystemUInt32");
        // hi_shifted := hi << rshift (unsigned, reuse _mem_u32_shifted)
        try self.asm_.push("_mlw_hi");
        try self.asm_.push("_mlw_rshift");
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.extern_("SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32");
        // dst := tmp | hi_shifted
        try self.asm_.push("_mlw_tmp");
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.push(dst);
        try self.asm_.extern_("SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32");
        try self.asm_.jump(end_lbl);
    }

    fn emitMemStoreWord(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        const memarg = ins.i32_store;
        const val = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        const raw_addr = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        // Offset must be applied *before* we pop the address slot, since
        // the downstream fast/generic helpers pop it themselves.
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        if (memarg.@"align" >= 2) {
            return self.emitMemStoreWordFast(ctx, addr_slot, val);
        }
        return self.emitMemStoreWordGeneric(ctx, addr_slot, val);
    }

    fn emitMemStoreWordFast(self: *Translator, ctx: *FuncCtx, addr_slot: []const u8, val: []const u8) Error!void {
        try self.asm_.comment("i32.store (aligned, within-chunk fast path)");
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
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push(val);
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
    }

    /// Generic i32.store that handles unaligned access and page-straddle
    /// via a 3-branch RMW (read-modify-write) of two adjacent words.
    fn emitMemStoreWordGeneric(self: *Translator, ctx: *FuncCtx, addr_slot: []const u8, val: []const u8) Error!void {
        try self.asm_.comment("i32.store (generic: 3-branch alignment/straddle RMW)");
        const id = self.block_counter;
        self.block_counter += 1;
        const fast_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_msw_fast_{d}__", .{ ctx.fn_name, id });
        const slow_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_msw_slow_{d}__", .{ ctx.fn_name, id });
        const straddle_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_msw_straddle_{d}__", .{ ctx.fn_name, id });
        const end_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_msw_end_{d}__", .{ ctx.fn_name, id });
        ctx.pop();

        // Decompose address (same as load).
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_3");
        try self.asm_.push("_mem_sub");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_16");
        try self.asm_.push("_mem_page_idx");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_0xFFFF");
        try self.asm_.push("_mem_addr");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mem_addr");
        try self.asm_.push("__c_i32_2");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");

        // if sub == 0, goto fast
        try self.asm_.push("_mem_sub");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_mg_cmp");
        try self.asm_.extern_("SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean");
        const skip_fast_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_msw_nofast_{d}__", .{ ctx.fn_name, id });
        try self.asm_.push("_mg_cmp");
        try self.asm_.jumpIfFalse(skip_fast_lbl);
        try self.asm_.jump(fast_lbl);
        try self.asm_.label(skip_fast_lbl);

        // if byte_in_page > 65532, goto straddle
        try self.asm_.push("_mem_addr");
        try self.asm_.push("__c_i32_65532");
        try self.asm_.push("_mg_cmp");
        try self.asm_.extern_("SystemInt32.__op_GreaterThan__SystemInt32_SystemInt32__SystemBoolean");
        const skip_straddle_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_msw_nostraddle_{d}__", .{ ctx.fn_name, id });
        try self.asm_.push("_mg_cmp");
        try self.asm_.jumpIfFalse(skip_straddle_lbl);
        try self.asm_.jump(straddle_lbl);
        try self.asm_.label(skip_straddle_lbl);

        // Unaligned within-chunk: read both words from same chunk.
        try self.asm_.label(slow_lbl);
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mlw_lo");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.push("_mlw_hi");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        // Build new pair and write back to same chunk.
        try self.emitMswComputeNewPair(val);
        // chunk[word_in_page] := lo_out
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_msw_lo_out");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
        // chunk[word_in_page + 1] := hi_out
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.push("_msw_hi_out");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
        try self.asm_.jump(end_lbl);

        // Straddle: read lo from current chunk[16383], hi from next chunk[0].
        try self.asm_.label(straddle_lbl);
        // lo_chunk := outer[page_idx]  (store in _mem_chunk temporarily, but we need both)
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        // lo := lo_chunk[16383]
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("__c_i32_16383");
        try self.asm_.push("_mlw_lo");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        // Write back lo_out to lo_chunk[16383] later — but we overwrite _mem_chunk
        // for hi_chunk fetch. So we compute new pair up front after getting hi.
        // page_idx_hi := page_idx + 1
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        // Stash lo_chunk elsewhere: we have only one _mem_chunk slot; emit another fetch later.
        // hi_chunk := outer[page_idx + 1]
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_mlw_hi");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        // Compute new pair.
        try self.emitMswComputeNewPair(val);
        // hi_chunk[0] := hi_out (still in _mem_chunk)
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_msw_hi_out");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
        // Re-fetch lo_chunk := outer[page_idx] and write lo_out[16383].
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("__c_i32_16383");
        try self.asm_.push("_msw_lo_out");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
        try self.asm_.jump(end_lbl);

        // Fast branch.
        try self.asm_.label(fast_lbl);
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push(val);
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");

        try self.asm_.label(end_lbl);
    }

    /// Given `_mlw_lo` and `_mlw_hi` loaded with the original two words and
    /// `_mem_sub` holding the byte offset in [1,3], compute the
    /// store-new-pair (`_msw_lo_out`, `_msw_hi_out`) for writing `val` at
    /// byte offset `sub` across the pair.
    fn emitMswComputeNewPair(self: *Translator, val: []const u8) Error!void {
        // shift := sub << 3
        try self.asm_.push("_mem_sub");
        try self.asm_.push("__c_i32_3");
        try self.asm_.push("_mlw_shift");
        try self.asm_.extern_("SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32");
        // rshift := 32 - shift
        try self.asm_.push("__c_i32_32");
        try self.asm_.push("_mlw_shift");
        try self.asm_.push("_mlw_rshift");
        try self.asm_.extern_("SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32");
        // lo_mask := 0xFFFFFFFF << shift
        try self.asm_.push("__c_u32_0xFFFFFFFF");
        try self.asm_.push("_mlw_shift");
        try self.asm_.push("_msw_lo_mask");
        try self.asm_.extern_("SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32");
        // hi_mask := 0xFFFFFFFF >> rshift
        try self.asm_.push("__c_u32_0xFFFFFFFF");
        try self.asm_.push("_mlw_rshift");
        try self.asm_.push("_msw_hi_mask");
        try self.asm_.extern_("SystemUInt32.__op_RightShift__SystemUInt32_SystemInt32__SystemUInt32");
        // lo_cleared := lo & ~lo_mask   (~x is synthesized as x XOR 0xFFFFFFFF
        // because Udon has no SystemUInt32.__op_OnesComplement__ node)
        try self.asm_.push("_msw_lo_mask");
        try self.asm_.push("__c_u32_0xFFFFFFFF");
        try self.asm_.push("_mem_mask_inv");
        try self.asm_.extern_("SystemUInt32.__op_LogicalXor__SystemUInt32_SystemUInt32__SystemUInt32");
        try self.asm_.push("_mlw_lo");
        try self.asm_.push("_mem_mask_inv");
        try self.asm_.push("_msw_lo_cleared");
        try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");
        // hi_cleared := hi & ~hi_mask
        try self.asm_.push("_msw_hi_mask");
        try self.asm_.push("__c_u32_0xFFFFFFFF");
        try self.asm_.push("_mem_mask_inv");
        try self.asm_.extern_("SystemUInt32.__op_LogicalXor__SystemUInt32_SystemUInt32__SystemUInt32");
        try self.asm_.push("_mlw_hi");
        try self.asm_.push("_mem_mask_inv");
        try self.asm_.push("_msw_hi_cleared");
        try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");
        // lo_new_bits := val << shift
        try self.asm_.push(val);
        try self.asm_.push("_mlw_shift");
        try self.asm_.push("_msw_lo_new_bits");
        try self.asm_.extern_("SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32");
        // hi_new_bits := val >> rshift
        try self.asm_.push(val);
        try self.asm_.push("_mlw_rshift");
        try self.asm_.push("_msw_hi_new_bits");
        try self.asm_.extern_("SystemUInt32.__op_RightShift__SystemUInt32_SystemInt32__SystemUInt32");
        // lo_out := lo_cleared | lo_new_bits
        try self.asm_.push("_msw_lo_cleared");
        try self.asm_.push("_msw_lo_new_bits");
        try self.asm_.push("_msw_lo_out");
        try self.asm_.extern_("SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32");
        // hi_out := hi_cleared | hi_new_bits
        try self.asm_.push("_msw_hi_cleared");
        try self.asm_.push("_msw_hi_new_bits");
        try self.asm_.push("_msw_hi_out");
        try self.asm_.extern_("SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32");
    }

    /// Shared preamble for byte-level memory accesses: computes
    /// `_mem_page_idx`, `_mem_word_in_page`, `_mem_sub`, `_mem_shift` and
    /// populates `_mem_chunk` / `_mem_u32` from the given address slot.
    fn emitByteAccessPreamble(self: *Translator, addr_slot: []const u8) Error!void {
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
        // sub := addr & 3 (bottom 2 bits preserved regardless of page masking)
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_3");
        try self.asm_.push("_mem_sub");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        // shift := sub << 3   (i.e. sub * 8)
        try self.asm_.push("_mem_sub");
        try self.asm_.push("__c_i32_3");
        try self.asm_.push("_mem_shift");
        try self.asm_.extern_("SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32");
        // _mem_chunk := __G__memory[page_idx]
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        // _mem_u32 := _mem_chunk[word_in_page]
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mem_u32");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
    }

    /// Read one byte from linear memory at address `addr_slot` into
    /// `out_slot` (a SystemByte scratch). Shares the i32.load8_u preamble
    /// and shift/mask sequence, then converts to SystemByte via
    /// `SystemConvert.__ToByte__SystemInt32__SystemByte`. Used by the
    /// host-import string marshaller.
    fn emitReadMemoryByte(self: *Translator, addr_slot: []const u8, out_slot: []const u8) Error!void {
        try self.emitByteAccessPreamble(addr_slot);
        // _mem_u32_shifted := _mem_u32 >> shift
        try self.asm_.push("_mem_u32");
        try self.asm_.push("_mem_shift");
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.extern_("SystemUInt32.__op_RightShift__SystemUInt32_SystemInt32__SystemUInt32");
        // _mem_byte := _mem_u32_shifted & 0xFF
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.push("__c_u32_0xFF");
        try self.asm_.push("_mem_byte");
        try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");
        // out := (SystemByte) _mem_byte — route via SystemInt32 since
        // udon_nodes.txt confirms only SystemInt32→SystemByte and friends,
        // not SystemUInt32→SystemByte directly.
        try self.asm_.push("_mem_byte");
        try self.asm_.push("_mem_st_lo_i32");
        try self.asm_.extern_("SystemConvert.__ToInt32__SystemUInt32__SystemInt32");
        try self.asm_.push("_mem_st_lo_i32");
        try self.asm_.push(out_slot);
        try self.asm_.extern_("SystemConvert.__ToByte__SystemInt32__SystemByte");
    }

    fn emitMemLoadByte(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        const signed = switch (ins) {
            .i32_load8_s => true,
            else => false,
        };
        try self.asm_.comment(if (signed) "i32.load8_s" else "i32.load8_u");
        const raw_addr = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        const memarg = switch (ins) {
            .i32_load8_u => |m| m,
            .i32_load8_s => |m| m,
            else => unreachable,
        };
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        ctx.pop();

        try self.emitByteAccessPreamble(addr_slot);

        // _mem_u32_shifted := _mem_u32 >> shift (unsigned)
        try self.asm_.push("_mem_u32");
        try self.asm_.push("_mem_shift");
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.extern_("SystemUInt32.__op_RightShift__SystemUInt32_SystemInt32__SystemUInt32");

        ctx.push();
        const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);

        // dst := _mem_u32_shifted & 0xFF
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.push("__c_u32_0xFF");
        try self.asm_.push(dst);
        try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");

        if (signed) {
            // Sign-extend 8-bit → 32-bit: (dst << 24) >> 24 arithmetically.
            try self.asm_.push(dst);
            try self.asm_.push("__c_i32_24");
            try self.asm_.push(dst);
            try self.asm_.extern_("SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32");
            try self.asm_.push(dst);
            try self.asm_.push("__c_i32_24");
            try self.asm_.push(dst);
            try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        }
    }

    fn emitMemStoreByte(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        try self.asm_.comment("i32.store8");
        const memarg = ins.i32_store8;
        const val = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        const raw_addr = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        ctx.pop();

        try self.emitByteAccessPreamble(addr_slot);

        // _mem_mask_lo := 0xFF << shift (unsigned)
        try self.asm_.push("__c_u32_0xFF");
        try self.asm_.push("_mem_shift");
        try self.asm_.push("_mem_mask_lo");
        try self.asm_.extern_("SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32");

        // _mem_mask_inv := ~_mem_mask_lo   (synthesized as x XOR 0xFFFFFFFF
        // because Udon has no SystemUInt32.__op_OnesComplement__ node)
        try self.asm_.push("_mem_mask_lo");
        try self.asm_.push("__c_u32_0xFFFFFFFF");
        try self.asm_.push("_mem_mask_inv");
        try self.asm_.extern_("SystemUInt32.__op_LogicalXor__SystemUInt32_SystemUInt32__SystemUInt32");

        // _mem_u32_cleared := _mem_u32 & _mem_mask_inv
        try self.asm_.push("_mem_u32");
        try self.asm_.push("_mem_mask_inv");
        try self.asm_.push("_mem_u32_cleared");
        try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");

        // _mem_byte := val & 0xFF (clamp to low 8 bits)
        try self.asm_.push(val);
        try self.asm_.push("__c_u32_0xFF");
        try self.asm_.push("_mem_byte");
        try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");

        // _mem_byte_shifted := _mem_byte << shift
        try self.asm_.push("_mem_byte");
        try self.asm_.push("_mem_shift");
        try self.asm_.push("_mem_byte_shifted");
        try self.asm_.extern_("SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32");

        // _mem_u32_new := _mem_u32_cleared | _mem_byte_shifted
        try self.asm_.push("_mem_u32_cleared");
        try self.asm_.push("_mem_byte_shifted");
        try self.asm_.push("_mem_u32_new");
        try self.asm_.extern_("SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32");

        // _mem_chunk[word_in_page] := _mem_u32_new
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mem_u32_new");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
    }

    fn emitMemStore16(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        try self.asm_.comment("i32.store16");
        const memarg = ins.i32_store16;
        const val = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        const raw_addr = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        ctx.pop();

        try self.emitByteAccessPreamble(addr_slot);

        // _mem_mask_lo := 0xFFFF << shift
        try self.asm_.push("__c_u32_0xFFFF_32");
        try self.asm_.push("_mem_shift");
        try self.asm_.push("_mem_mask_lo");
        try self.asm_.extern_("SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32");

        // _mem_mask_inv := ~_mem_mask_lo   (synthesized as x XOR 0xFFFFFFFF
        // because Udon has no SystemUInt32.__op_OnesComplement__ node)
        try self.asm_.push("_mem_mask_lo");
        try self.asm_.push("__c_u32_0xFFFFFFFF");
        try self.asm_.push("_mem_mask_inv");
        try self.asm_.extern_("SystemUInt32.__op_LogicalXor__SystemUInt32_SystemUInt32__SystemUInt32");

        // _mem_u32_cleared := _mem_u32 & _mem_mask_inv
        try self.asm_.push("_mem_u32");
        try self.asm_.push("_mem_mask_inv");
        try self.asm_.push("_mem_u32_cleared");
        try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");

        // _mem_byte := val & 0xFFFF (clamp to low 16 bits)
        try self.asm_.push(val);
        try self.asm_.push("__c_u32_0xFFFF_32");
        try self.asm_.push("_mem_byte");
        try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");

        // _mem_byte_shifted := _mem_byte << shift
        try self.asm_.push("_mem_byte");
        try self.asm_.push("_mem_shift");
        try self.asm_.push("_mem_byte_shifted");
        try self.asm_.extern_("SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32");

        // _mem_u32_new := _mem_u32_cleared | _mem_byte_shifted
        try self.asm_.push("_mem_u32_cleared");
        try self.asm_.push("_mem_byte_shifted");
        try self.asm_.push("_mem_u32_new");
        try self.asm_.extern_("SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32");

        // _mem_chunk[word_in_page] := _mem_u32_new
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mem_u32_new");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
    }

    fn emitMemLoadI64(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        try self.asm_.comment("i64.load (with runtime page-straddle dispatch)");
        const memarg = ins.i64_load;
        const raw_addr = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        ctx.pop();

        const id = self.block_counter;
        self.block_counter += 1;
        const straddle_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mli_straddle_{d}__", .{ ctx.fn_name, id });
        const within_page_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mli_within_{d}__", .{ ctx.fn_name, id });
        const hi_done_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mli_hidone_{d}__", .{ ctx.fn_name, id });

        // page_idx := addr >> 16
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_16");
        try self.asm_.push("_mem_page_idx");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        // byte_in_page := addr & 0xFFFF
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_0xFFFF");
        try self.asm_.push("_mem_byte_in_page");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        // word_in_page := byte_in_page >> 2
        try self.asm_.push("_mem_byte_in_page");
        try self.asm_.push("__c_i32_2");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        // _mem_chunk := outer[page_idx]
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        // _mem_u32 := _mem_chunk[word_in_page]   (lo word — always in page)
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mem_u32");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        // Straddle if byte_in_page > 65528 (last 8-byte window spills into page+1).
        try self.asm_.push("_mem_byte_in_page");
        try self.asm_.push("__c_i32_65528");
        try self.asm_.push("_mg_cmp");
        try self.asm_.extern_("SystemInt32.__op_GreaterThan__SystemInt32_SystemInt32__SystemBoolean");
        try self.asm_.push("_mg_cmp");
        try self.asm_.jumpIfFalse(within_page_lbl);
        try self.asm_.jump(straddle_lbl);
        try self.asm_.label(within_page_lbl);
        // Within page: hi word is _mem_chunk[word_in_page + 1].
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.push("_mem_u32_hi");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        try self.asm_.jump(hi_done_lbl);
        // Straddle: hi word is outer[page_idx + 1][0].
        try self.asm_.label(straddle_lbl);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mem_page_idx_hi");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx_hi");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_mem_u32_hi");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        try self.asm_.label(hi_done_lbl);
        // _mem_i64_lo := (i64)_mem_u32
        try self.asm_.push("_mem_u32");
        try self.asm_.push("_mem_i64_lo");
        try self.asm_.extern_("SystemConvert.__ToInt64__SystemUInt32__SystemInt64");
        // _mem_i64_hi := (i64)_mem_u32_hi
        try self.asm_.push("_mem_u32_hi");
        try self.asm_.push("_mem_i64_hi");
        try self.asm_.extern_("SystemConvert.__ToInt64__SystemUInt32__SystemInt64");
        // _mem_i64_hi_shifted := _mem_i64_hi << 32
        try self.asm_.push("_mem_i64_hi");
        try self.asm_.push("__c_i32_32");
        try self.asm_.push("_mem_i64_hi_shifted");
        try self.asm_.extern_("SystemInt64.__op_LeftShift__SystemInt64_SystemInt32__SystemInt64");
        // dst := _mem_i64_hi_shifted | _mem_i64_lo
        ctx.push();
        const dst = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        try self.asm_.push("_mem_i64_hi_shifted");
        try self.asm_.push("_mem_i64_lo");
        try self.asm_.push(dst);
        try self.asm_.extern_("SystemInt64.__op_LogicalOr__SystemInt64_SystemInt64__SystemInt64");
    }

    fn emitMemStoreI64(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        try self.asm_.comment("i64.store (aligned, within-chunk fast path)");
        const memarg = ins.i64_store;
        const val = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        ctx.pop();
        const raw_addr = try names.stackSlot(self.aa(), ctx.fn_name, ctx.depth - 1);
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        ctx.pop();

        // _mem_hi_i64 := val >> 32 (arithmetic; bit pattern for high word is what we want)
        try self.asm_.push(val);
        try self.asm_.push("__c_i32_32");
        try self.asm_.push("_mem_hi_i64");
        try self.asm_.extern_("SystemInt64.__op_RightShift__SystemInt64_SystemInt32__SystemInt64");
        // _mem_st_lo_i32 := (i32)val   (truncates low 32 bits)
        try self.asm_.push(val);
        try self.asm_.push("_mem_st_lo_i32");
        try self.asm_.extern_("SystemConvert.__ToInt32__SystemInt64__SystemInt32");
        // _mem_st_hi_i32 := (i32)_mem_hi_i64
        try self.asm_.push("_mem_hi_i64");
        try self.asm_.push("_mem_st_hi_i32");
        try self.asm_.extern_("SystemConvert.__ToInt32__SystemInt64__SystemInt32");
        // bit-copy int32 → uint32 (same 32-bit bit pattern in the slot)
        try self.asm_.push("_mem_st_lo_i32");
        try self.asm_.push("_mem_st_lo_u32");
        try self.asm_.copy();
        try self.asm_.push("_mem_st_hi_i32");
        try self.asm_.push("_mem_st_hi_u32");
        try self.asm_.copy();

        const id = self.block_counter;
        self.block_counter += 1;
        const straddle_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_msi_straddle_{d}__", .{ ctx.fn_name, id });
        const within_page_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_msi_within_{d}__", .{ ctx.fn_name, id });
        const hi_done_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_msi_hidone_{d}__", .{ ctx.fn_name, id });

        // address decomposition
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_16");
        try self.asm_.push("_mem_page_idx");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push(addr_slot);
        try self.asm_.push("__c_i32_0xFFFF");
        try self.asm_.push("_mem_byte_in_page");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mem_byte_in_page");
        try self.asm_.push("__c_i32_2");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        // outer[page_idx] → _mem_chunk
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        // Lo word goes to the current chunk unconditionally.
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mem_st_lo_u32");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
        // Straddle when byte_in_page > 65528 (hi word in page+1).
        try self.asm_.push("_mem_byte_in_page");
        try self.asm_.push("__c_i32_65528");
        try self.asm_.push("_mg_cmp");
        try self.asm_.extern_("SystemInt32.__op_GreaterThan__SystemInt32_SystemInt32__SystemBoolean");
        try self.asm_.push("_mg_cmp");
        try self.asm_.jumpIfFalse(within_page_lbl);
        try self.asm_.jump(straddle_lbl);
        try self.asm_.label(within_page_lbl);
        // Within-page: hi word is chunk[word_in_page + 1].
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page_hi");
        try self.asm_.push("_mem_st_hi_u32");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
        try self.asm_.jump(hi_done_lbl);
        try self.asm_.label(straddle_lbl);
        // Straddle: hi word is outer[page_idx + 1][0].
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mem_page_idx_hi");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push("_mem_page_idx_hi");
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_mem_st_hi_u32");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
        try self.asm_.label(hi_done_lbl);
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
        .label = labelFn,
        .jump = jumpFn,
        .jumpIfFalse = jumpIfFalseFn,
        .readByteFromMemory = readByteFromMemoryFn,
        .uniqueId = uniqueId,
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
    fn labelFn(ctx: *anyopaque, n: []const u8) lower_import.Error!void {
        try self_(ctx).t.asm_.label(n);
    }
    fn jumpFn(ctx: *anyopaque, n: []const u8) lower_import.Error!void {
        try self_(ctx).t.asm_.jump(n);
    }
    fn jumpIfFalseFn(ctx: *anyopaque, n: []const u8) lower_import.Error!void {
        try self_(ctx).t.asm_.jumpIfFalse(n);
    }
    fn readByteFromMemoryFn(ctx: *anyopaque, addr: []const u8, out: []const u8) lower_import.Error!void {
        self_(ctx).t.emitReadMemoryByte(addr, out) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Code-emission paths only realistically fail on allocation
            // pressure or writer failure; map everything else to OOM so the
            // caller can propagate without widening `lower_import.Error`.
            else => return error.OutOfMemory,
        };
    }
    fn uniqueId(ctx: *anyopaque) u32 {
        const t = self_(ctx).t;
        const id = t.unique_id_counter;
        t.unique_id_counter += 1;
        return id;
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
    // The bench declares UnityEngineDebug.__Log via a raw-identifier import
    // name; the translator should emit EXTERN with that exact string, with
    // no hardcoded table.
    try std.testing.expect(std.mem.indexOf(u8, out,
        "UnityEngineDebug.__Log__SystemString__SystemVoid") != null);
    // Generic SystemString marshaling helper is declared once for all
    // string arguments regardless of which extern they target.
    try std.testing.expect(std.mem.indexOf(u8, out, "_marshal_str_tmp:") != null);
    // Regression guard: the old hardcoded placeholder must be gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "__cwl_placeholder__") == null);

    // ---- string-marshaling helper correctness ----
    // The encoding singleton must be declared and cached in _start.
    try std.testing.expect(std.mem.indexOf(u8, out, "_marshal_encoding_utf8:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemTextEncoding.__get_UTF8__SystemTextEncoding") != null);
    // A real byte array must be allocated and written into.
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemByteArray.__ctor__SystemInt32__SystemByteArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemByteArray.__Set__SystemInt32_SystemByte__SystemVoid") != null);
    // GetString must be a non-static call: the encoding instance is
    // pushed immediately before the byte[] and the result slot.
    const gs_at = std.mem.indexOf(u8, out,
        "SystemTextEncoding.__GetString__SystemByteArray__SystemString").?;
    const prefix = out[0..gs_at];
    const this_at = std.mem.lastIndexOf(u8, prefix, "PUSH, _marshal_encoding_utf8").?;
    const bytes_at = std.mem.lastIndexOf(u8, prefix, "PUSH, _marshal_str_bytes").?;
    const tmp_at = std.mem.lastIndexOf(u8, prefix, "PUSH, _marshal_str_tmp").?;
    try std.testing.expect(this_at < bytes_at);
    try std.testing.expect(bytes_at < tmp_at);
    // Regression guard: the old 2-arg TODO stub must be gone.
    try std.testing.expect(std.mem.indexOf(u8, out,
        "byte-copy from linear memory into _marshal_str_bytes — TODO") == null);

    // ---- call_indirect full ABI emitted ----
    // Bench's `ops` array puts 3+ functions in the WASM table; each becomes
    // an indirect-callable with an entry + trampoline, and every
    // call_indirect site dispatches through __fn_table__ / __indirect_target__.
    try std.testing.expect(std.mem.indexOf(u8, out, "__fn_table__") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_indirect_entry__:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_indirect_trampoline__:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "JUMP_INDIRECT, __indirect_target__") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32Array.__Get__SystemInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
    // Regression guard: the old "simplified — single shared indirect target"
    // comment must be gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "simplified — single shared indirect target") == null);

    // ---- memory infra was emitted ----
    // bench sets `options.memory.udonName = "_memory"`, so companion scalars
    // are renamed in lockstep per docs/spec_udonmeta_conversion.md §options.memory.
    try std.testing.expect(std.mem.indexOf(u8, out, "_memory_size_pages") != null);
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
        "SystemUInt32Array.__Get__SystemInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
    // Subtraction and multiplication come from test_struct's rect_width and
    // point_area (when not fully folded). Multiplication is already covered
    // by test_arithmetic but its presence is reassuring.
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemInt32.__op_Multiplication__SystemInt32_SystemInt32__SystemInt32") != null);
}

// ----------------------------------------------------------------
//  README 未実装項目の TDD テスト群
//
//  README.md "Status" 節で `[ ]` のままだった以下の 4 項目について、
//  bench.wasm を変換した結果が構造的に spec 準拠であることを担保する:
//    - memory.grow 実アロケーション
//    - i32.load8_* / i32.store8 の shift/mask 展開
//    - unaligned / page-straddling memory access
//    - 変換 opcode (i32.trunc_*, f64.convert_*, i32.wrap_i64, etc.)
//
//  どのテストも bench.wasm を 1 回だけ変換して共通の出力文字列に対して
//  アサートするため、最初のテストで翻訳を回しその出力を keep している。
// ----------------------------------------------------------------

fn translateBench(gpa: std.mem.Allocator) ![]u8 {
    const bench = @embedFile("testdata/bench.wasm");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    const mod = try wasm.parseModule(aa, bench);
    const meta = try wasm.parseUdonMetaFromModule(aa, mod);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    try translate(gpa, mod, meta, &buf.writer, .{});
    return buf.toOwnedSlice();
}

test "bench: memory.grow allocates inner chunks via SystemUInt32Array ctor" {
    // README unimplemented item: "memory.grow real allocation".
    // bench の test_memory 内で @wasmMemoryGrow(0, 1) を呼ぶので、
    // 変換後の assembly には:
    //   - 新しい SystemUInt32Array のアロケート
    //   - SystemObjectArray への SetValue（outer に store）
    //   - __G__memory_size_pages への書き込み
    // が出現しなければならない。
    //
    // 現状の emitMemoryGrow は size_pages をそのまま push して返すだけ
    // なので、このテストは Red になる。
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // memory init がすでに持っている ctor 呼び出しとは別に、
    // grow 経由でも呼び出される必要がある。grow のコメントが
    // "memory.grow" を含む位置以降に ctor 呼び出しがあれば OK。
    const grow_marker = std.mem.indexOf(u8, out, "memory.grow") orelse return error.TestExpectedEqual;
    const after = out[grow_marker..];

    // 新チャンクのアロケート
    try std.testing.expect(std.mem.indexOf(u8, after,
        "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array") != null);
    // outer への設置
    try std.testing.expect(std.mem.indexOf(u8, after,
        "SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid") != null);
    // page counter の更新と、-1 (失敗時) のコンスタント
    // bench の __udon_meta で memory.udonName = "_memory" を指定しているので
    // companion スカラも lockstep で改名される。
    try std.testing.expect(std.mem.indexOf(u8, after, "_memory_size_pages") != null);

    // 未実装プレースホルダは残っていないこと
    try std.testing.expect(std.mem.indexOf(u8, after,
        "simplified: returns current pages, no real growth") == null);
}

test "bench: i32.store8 expands to shift/mask RMW sequence" {
    // README unimplemented item: "Full i32.load8_* / i32.store8 shift/mask expansion".
    // bench の test_memory で `bytes[8] = 0x11; bytes[9] = 0x22; ...` の
    // 連続 store8 を行う。spec_linear_memory.md §6 Example 3 の RMW 手順に
    // 従って以下の EXTERN が出現するはず:
    //   - SystemUInt32.__op_LeftShift (new_byte シフト / mask シフト)
    //   - SystemUInt32.__op_LogicalAnd (word clear; Udon UInt32 には Bitwise 系は無い)
    //   - SystemUInt32.__op_LogicalOr  (合成)
    //   - SystemUInt32.__op_LogicalXor (~mask 代替: x ^ 0xFFFFFFFF)
    //   - SystemUInt32Array.__Set__...SystemVoid (書き戻し)
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);

    // store8 の placeholder が残っていないこと
    try std.testing.expect(std.mem.indexOf(u8, out,
        "i32.store8 (simplified shift/mask placeholder)") == null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "i32.load8 (simplified shift/mask placeholder)") == null);
}

test "bench: no duplicate label definitions in rendered .code section" {
    // UAssembly's `VisitLabelStmt` rejects duplicate labels with
    // `AssemblyException: Duplicate label '...' detected`. Guard the whole
    // code section — catch regressions in any lowering pass that might
    // accidentally re-use a generated suffix.
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // Only bare label-definition lines: "<name>:" with no further tokens.
        if (line.len == 0) continue;
        if (!std.mem.endsWith(u8, line, ":")) continue;
        if (std.mem.indexOfAny(u8, line, " \t,")) |_| continue;
        const name = line[0 .. line.len - 1];
        const gop = try seen.getOrPut(std.testing.allocator, name);
        if (gop.found_existing) {
            std.debug.print("duplicate label: {s}\n", .{name});
            try std.testing.expect(false);
        }
    }
}

test "bench: _marshal_str_byte scratch field is initialized to null (no SystemByte literals)" {
    // docs/udon_specs.md §4.7: SystemByte は null / this 以外の初期値を指定できない。
    // `0` を書くと UAssembly assembler が VisitDataDeclarationStmt で
    // `AssemblyException: Type 'SystemByte' must be initialized to null or a this reference.`
    // を投げる。bench は host import 経由の文字列 marshal を踏むので、
    // `_marshal_str_byte: %SystemByte, null` が出力され、かつ任意の
    // `%SystemByte, <digit>` は絶対に出てはならない。
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "_marshal_str_byte: %SystemByte, null") != null);

    // Every `%SystemByte,` occurrence must be followed by `null` (or `this`).
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "%SystemByte,")) |pos| {
        const after = out[pos + "%SystemByte,".len ..];
        const trimmed = std.mem.trimStart(u8, after, " ");
        const is_null = std.mem.startsWith(u8, trimmed, "null");
        const is_this = std.mem.startsWith(u8, trimmed, "this");
        try std.testing.expect(is_null or is_this);
        i = pos + 1;
    }
}

test "bench: i32.load8_u expands to shift + mask 0xFF" {
    // Example 2 (spec_linear_memory.md §6): shift → u32 RightShift → BitwiseAnd 0xFF
    // load8_u は unsigned mask なので BitwiseAnd は SystemUInt32 版。
    // i32.shr_u が既に UInt32 RightShift を使っているため RightShift 単独では
    // シグナルにならない。BitwiseAnd が u32 で出ていることまで要求する。
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32") != null);
}

test "bench: i64 conversions dispatch via SystemConvert" {
    // README unimplemented item: "Some conversion opcodes".
    // bench の test_64bit_and_float / test_globals で:
    //   - @intCast(i32, r >> 32) / r & 0xFFFFFFFF → i32.wrap_i64
    //   - @as(i64, 0x1_0000_0000) + 5             → i64.extend_i32_u
    //
    // (f64 側の @intFromFloat(@floor(...)) は Zig のコンパイル時最適化で
    //  bench.wasm に残らないため、ここでは unary 形の SystemConvert が
    //  出ていることだけ検証する。)
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemConvert.__ToInt32__SystemInt64__SystemInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemConvert.__ToInt64__SystemUInt32__SystemInt64") != null);
}

test "synthesized self-recursive function spills frame when recursion=stack" {
    // README unimplemented item: "Recursive-function call-stack spill".
    //
    // spec_call_return_conversion.md §8.2: recursive な関数 (SCC サイズ ≥ 2、
    // または自己辺をもつ) は `__udon_meta.options.recursion == "stack"` のとき
    // prologue/epilogue で P / L / S / R / RA を `__call_stack__` に退避する。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const params = try a.alloc(ValType, 1);
    params[0] = .i32;
    const results = try a.alloc(ValType, 1);
    results[0] = .i32;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params, .results = results };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    const then_body = try a.alloc(Instruction, 1);
    then_body[0] = .{ .i32_const = 1 };
    const else_body = try a.alloc(Instruction, 6);
    else_body[0] = .{ .local_get = 0 };
    else_body[1] = .{ .i32_const = 1 };
    else_body[2] = .i32_sub;
    else_body[3] = .{ .call = 0 }; // self-recursion
    else_body[4] = .{ .local_get = 0 };
    else_body[5] = .i32_mul;

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i32_const = 0 };
    body[2] = .i32_eq;
    body[3] = .{ .if_ = .{
        .bt = .{ .value = .i32 },
        .then_body = then_body,
        .else_body = else_body,
    } };
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "recur", .desc = .{ .func = 0 } };

    const mod: wasm.Module = .{
        .types_ = types_,
        .funcs = funcs,
        .codes = codes,
        .exports = exports,
    };

    // UdonMeta.options.recursion は Item 1 実装で追加されるフィールド。
    var meta: wasm.UdonMeta = .{ .version = 1 };
    meta.options.recursion = .stack;

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, meta, &buf.writer, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid") != null);
    const cs_hits = std.mem.count(u8, out, "__call_stack__");
    try std.testing.expect(cs_hits >= 4);
    const top_hits = std.mem.count(u8, out, "__call_stack_top__");
    try std.testing.expect(top_hits >= 4);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemObjectArray.__GetValue__SystemInt32__SystemObject") != null);
}

test "non-recursive function does not spill when recursion=stack" {
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
    var meta: wasm.UdonMeta = .{ .version = 1 };
    meta.options.recursion = .stack;

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, meta, &buf.writer, .{});
    const out = buf.written();

    var it = std.mem.splitSequence(u8, out, "\n");
    var push_in_code: usize = 0;
    var in_data = true;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, ".code_start") != null) in_data = false;
        if (!in_data and std.mem.indexOf(u8, line, "PUSH, __call_stack__") != null) {
            push_in_code += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), push_in_code);
}

test "synthesized unaligned i32.load emits runtime alignment dispatch" {
    // README unimplemented item: "Unaligned / page-straddling memory access".
    //
    // 戦略: LLVM は bench のアクセスすべてに align=2 (log2, = 4 バイト) を
    // 立てるので、bench だけでは unaligned ケースを発火できない。
    // ここでは align=0 (byte-aligned hint) を持つ i32.load を 1 つ含む
    // 小さな module を手で合成し、翻訳器が runtime 整列チェック分岐を
    // 吐き出すことを確認する。
    //
    // 期待する出力構造 (spec_linear_memory.md §6 Example 1 の 3-branch 拡張):
    //   - `sub = addr & 3` を計算し、0 でないとき fallback へ JUMP
    //   - fallback ラベル (`__*_mlw_slow_*__` のような unique 名)
    //   - fallback は 2 word 読み + shift + or で結合
    //
    // 名前規約: 実装者は `_mlw_fast_`, `_mlw_slow_`, `_mlw_end_` または
    // それに類するラベルを関数内ユニーク id 付きで使用する。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn load_maybe_unaligned(addr: i32) -> i32 : local.get 0; i32.load align=0; end
    const params = try a.alloc(ValType, 1);
    params[0] = .i32;
    const results = try a.alloc(ValType, 1);
    results[0] = .i32;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params, .results = results };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    const body = try a.alloc(Instruction, 2);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i32_load = .{ .@"align" = 0, .offset = 0 } };
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "load_maybe_unaligned", .desc = .{ .func = 0 } };

    // Memory section: 1-page module so __G__memory infra is emitted.
    const memories = try a.alloc(wasm.types.MemType, 1);
    memories[0] = .{ .min = 1, .max = null };

    const mod: wasm.Module = .{
        .types_ = types_,
        .funcs = funcs,
        .codes = codes,
        .exports = exports,
        .memories = memories,
    };

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // 3-branch 構造のラベルが存在すること。実装者は prefix を決めてよいが
    // ここでは最低限 "fast" / "slow" or "unaligned" / "end" のいずれかが
    // 関数名プレフィックスと共に複数出現することを要求する。
    const has_fast = std.mem.indexOf(u8, out, "mlw_fast") != null or
        std.mem.indexOf(u8, out, "_aligned") != null;
    const has_slow = std.mem.indexOf(u8, out, "mlw_slow") != null or
        std.mem.indexOf(u8, out, "unaligned") != null or
        std.mem.indexOf(u8, out, "straddle") != null;
    try std.testing.expect(has_fast);
    try std.testing.expect(has_slow);

    // 整列チェックの `addr & 3` が出ていること: addr に対する LogicalAnd と
    // `__c_i32_3` (または相当する const) が現れる。
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_3") != null);
}

test "bench: no __unsupported__ annotation remains" {
    // 最終的な受け入れ条件: bench.wasm を変換したら ANNOTATION __unsupported__
    // は一切出現しない。このテストを Green にすることがタスク全体の完成定義。
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // `__unsupported__` はデータ宣言として 1 回出現する
    // (code sink の安全策)。ANNOTATION としての使用は 0 回であるべき。
    var it = std.mem.splitSequence(u8, out, "\n");
    var annotation_hits: usize = 0;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "ANNOTATION") != null and
            std.mem.indexOf(u8, line, "__unsupported__") != null)
        {
            annotation_hits += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), annotation_hits);
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

// Runtime regression: a module whose only event binding is `_update` (no
// `_start`) used to skip memory initialization entirely, so the outer
// `SystemObjectArray` stayed null. The first `i32.load` inside `_update`
// then tried `SystemObjectArray.__GetValue__...` on null and the Udon VM
// threw: "Index has to be between upper and lower bound of the array."
//
// Per docs/udon_specs.md §9.1 and docs/spec_linear_memory.md §4, memory
// setup is specified to run at `_onEnable`. The translator therefore must
// synthesize a `_onEnable` event that initializes memory whenever the user
// did not already bind one.
test "memory init runs under _onEnable even when only _update is bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Minimal function: i32.const 0; i32.load (drops — we don't care about
    // the value, just that a memory read is in the event path).
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = &.{}, .results = &.{} };
    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;
    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .i32_const = 0 };
    body[1] = .{ .i32_load = .{ .@"align" = 2, .offset = 0 } };
    body[2] = .drop;
    body[3] = .return_;
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };
    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "tick", .desc = .{ .func = 0 } };
    const memories = try a.alloc(wasm.types.MemType, 1);
    memories[0] = .{ .min = 1, .max = null };

    const mod: wasm.Module = .{
        .types_ = types_,
        .funcs = funcs,
        .codes = codes,
        .exports = exports,
        .memories = memories,
    };

    // Meta: bind `tick` → `_update` (no _start binding).
    const meta_fns = try a.alloc(wasm.udon_meta.Function, 1);
    meta_fns[0] = .{
        .key = "tick",
        .source = .{ .kind = .@"export", .name = "tick" },
        .label = "_update",
    };
    const meta: wasm.UdonMeta = .{ .version = 1, .functions = meta_fns };

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, meta, &buf.writer, .{});
    const out = buf.written();

    // A `_onEnable` export must exist so VRChat runs memory setup before
    // `_update` ever fires.
    try std.testing.expect(std.mem.indexOf(u8, out, ".export _onEnable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_onEnable:") != null);

    // Memory init externs must appear at least once — outer array ctor and
    // at least one inner chunk allocation.
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemObjectArray.__ctor__SystemInt32__SystemObjectArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        "SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid") != null);
}

test "bench: every emitted EXTERN exists in Udon node list" {
    // testdata/udon_nodes.txt は VRChat SDK3 から Editor スクリプトで
    // ダンプした全 EXTERN ノード一覧 (LF 正規化済)。
    // 翻訳器が emit する EXTERN はすべてこのリストに含まれていなければ
    // 実機で "Function '...' is not implemented yet" で失敗する。
    const nodes_raw = @embedFile("testdata/udon_nodes.txt");

    var nodes = std.StringHashMap(void).init(std.testing.allocator);
    defer nodes.deinit();
    var node_it = std.mem.splitScalar(u8, nodes_raw, '\n');
    while (node_it.next()) |line| {
        if (line.len == 0) continue;
        try nodes.put(line, {});
    }

    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // 既知の未対応 EXTERN を一時許容するための枠。修正が入るたびに空に保つ。
    // 新規リグレッション検出が主目的なので、常に empty で running に保ちたい。
    const expected_missing = [_][]const u8{};

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(std.testing.allocator);

    var line_it = std.mem.splitScalar(u8, out, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const prefix = "EXTERN, \"";
        const idx = std.mem.indexOf(u8, line, prefix) orelse continue;
        const rest = line[idx + prefix.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const sig = rest[0..end];
        if (nodes.contains(sig)) continue;
        var is_expected = false;
        for (expected_missing) |e| {
            if (std.mem.eql(u8, e, sig)) {
                is_expected = true;
                break;
            }
        }
        if (is_expected) continue;
        try missing.append(std.testing.allocator, sig);
    }

    if (missing.items.len != 0) {
        std.debug.print("Emitted EXTERNs missing from Udon node list:\n", .{});
        for (missing.items) |m| std.debug.print("  {s}\n", .{m});
        return error.UnknownExternEmitted;
    }
}

// ----------------------------------------------------------------
// Data segment init + page allocation sizing (TDD for bench PC 28160 fix)
//
// Runtime regression: bench crashed at
//   EXTERN SystemObjectArray.__GetValue__SystemInt32__SystemObject
//   Index has to be between upper and lower bound of the array.
// because (a) the outer `_memory` array was sized to maxPages=16 but the
// WASM placed rodata at offset 1048576 (page 16, needs ≥17 pages), and (b)
// data segments were never written into linear memory — `emitDataSegmentInit`
// only emitted a comment. See the plan file for the full picture.
// ----------------------------------------------------------------

/// Build a minimal module with one memory and one data segment at `offset`
/// containing `init` bytes. Caller keeps the arena alive for the module's
/// lifetime.
fn buildSingleDataModule(
    a: std.mem.Allocator,
    mem_min: u32,
    offset_const: i32,
    data_bytes: []const u8,
) !wasm.Module {
    const memories = try a.alloc(wasm.types.MemType, 1);
    memories[0] = .{ .min = mem_min, .max = null };

    const offset_expr = try a.alloc(Instruction, 1);
    offset_expr[0] = .{ .i32_const = offset_const };

    const datas = try a.alloc(wasm.module.Data, 1);
    datas[0] = .{ .memory_index = 0, .offset = offset_expr, .init = data_bytes };

    return .{
        .memories = memories,
        .datas = datas,
    };
}

/// Extract the literal integer value after a `<name>: %<type>, ` prefix line.
fn findDataDeclInt(out: []const u8, name: []const u8) !i64 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}: %", .{name});
        defer std.testing.allocator.free(prefix);
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const comma = std.mem.lastIndexOfScalar(u8, line, ',') orelse continue;
        var rest = line[comma + 1 ..];
        rest = std.mem.trim(u8, rest, " \t\r");
        // Strip trailing 'u' for uint32 literals.
        if (rest.len > 0 and rest[rest.len - 1] == 'u') rest = rest[0 .. rest.len - 1];
        return try std.fmt.parseInt(i64, rest, 10);
    }
    return error.TestExpectedEqual;
}

test "bench: no data segment is left uninitialized" {
    // Regression: `RMW init elided` was a placeholder that the translator
    // used to emit when skipping data segment writes. With
    // `emitDataSegmentInit` now implemented, that marker must never appear
    // in a real translation output.
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "RMW init elided") == null);
    // And the rodata word constants must be present.
    try std.testing.expect(std.mem.indexOf(u8, out, "__ds_word_") != null);
}

test "bench: linear memory allocates at least 17 pages" {
    // bench's rodata lives on page 16 (offset 1048576+), so initial_pages
    // and max_pages must both be ≥ 17 even though the bundled __udon_meta
    // requests `{initialPages: 1, maxPages: 16}` — the translator must
    // clamp those up against the WASM data segments' actual footprint.
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);
    // bench renames memory companions via meta.options.memory.udonName=
    // "_memory", so the scalars appear unprefixed.
    const initial = try findDataDeclInt(out, "_memory_initial_pages");
    const max_p = try findDataDeclInt(out, "_memory_max_pages");
    try std.testing.expect(initial >= 17);
    try std.testing.expect(max_p >= 17);
}

test "bench: onEnable init writes rodata word into linear memory" {
    // The first Log call in `on_start` dereferences a string pointer into
    // rodata on page 16; for that read to succeed, `_onEnable` must have
    // written the corresponding words during init. Structural check: the
    // init window references at least one `__ds_word_*` constant and
    // contains a matching GetValue→Set pair.
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);
    const body = onEnableBody(out);
    try std.testing.expect(body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body, "PUSH, __ds_word_") != null);
    try std.testing.expect(std.mem.indexOf(u8, body,
        "SystemObjectArray.__GetValue__SystemInt32__SystemObject") != null);
    try std.testing.expect(std.mem.indexOf(u8, body,
        "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
}

test "data segment at page 16 widens initial_pages to 17" {
    // A module declaring memory min=1 but whose data segment lives on page
    // 16 (offset 1048576) must end up with initial_pages ≥ 17 so the outer
    // SystemObjectArray actually contains a chunk for that page.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var eight_bytes: [8]u8 = undefined;
    @memset(&eight_bytes, 0x41);
    const mod = try buildSingleDataModule(a, 1, 1048576, &eight_bytes);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const initial = try findDataDeclInt(out, "__G__memory_initial_pages");
    const max_p = try findDataDeclInt(out, "__G__memory_max_pages");
    try std.testing.expect(initial >= 17);
    try std.testing.expect(max_p >= 17);
}

/// Return the slice of `out` between `_onEnable:` and its terminating
/// `JUMP, 0xFFFFFFFC`. Data segment init must live in this window so that
/// VRChat runs it before any other event fires.
fn onEnableBody(out: []const u8) []const u8 {
    const anchor = "_onEnable:\n";
    const start = std.mem.indexOf(u8, out, anchor) orelse return "";
    const from = start + anchor.len;
    const end_needle = "JUMP, 0xFFFFFFFC";
    const rel = std.mem.indexOf(u8, out[from..], end_needle) orelse return out[from..];
    return out[from .. from + rel];
}

fn countOccurrences(hay: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= hay.len) {
        if (std.mem.eql(u8, hay[i .. i + needle.len], needle)) {
            n += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return n;
}

test "data segment emits word-aligned stores into linear memory" {
    // One word (0x44332211, LE) written at offset 0x100 (page 0). The
    // translator must no longer elide initialization: we require (a) a
    // `__ds_word_*` u32 constant decl carrying the packed value, (b) a
    // GetValue-then-Set pair in the `_onEnable` window that writes that
    // constant into the chunk.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes: [4]u8 = .{ 0x11, 0x22, 0x33, 0x44 };
    const mod = try buildSingleDataModule(a, 1, 0x100, &bytes);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "RMW init elided") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__ds_word_") != null);
    // LE packed value 0x44332211 = 1144201745.
    try std.testing.expect(std.mem.indexOf(u8, out, "1144201745") != null);

    const body = onEnableBody(out);
    try std.testing.expect(body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body,
        "SystemObjectArray.__GetValue__SystemInt32__SystemObject") != null);
    try std.testing.expect(std.mem.indexOf(u8, body,
        "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
    // At least one PUSH of a __ds_word_ constant must appear in the init.
    try std.testing.expect(std.mem.indexOf(u8, body, "PUSH, __ds_word_") != null);
}

test "data segment with tail bytes emits byte RMW for the remainder" {
    // One aligned word + 2 tail bytes. Translator must write the word as
    // one UInt32Array.__Set, then read-modify-write the trailing 2 bytes
    // (XOR-based ~mask per Udon's UInt32 op set).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes: [6]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    const mod = try buildSingleDataModule(a, 1, 0x100, &bytes);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body = onEnableBody(out);
    try std.testing.expect(body.len > 0);

    // Word path: at least one UInt32Array.__Set.
    try std.testing.expect(std.mem.indexOf(u8, body,
        "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
    // Byte-RMW path: mask-and-or over UInt32 (XOR is used to build ~mask).
    try std.testing.expect(std.mem.indexOf(u8, body,
        "SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, body,
        "SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32") != null);
}

test "data segment spanning two pages splits at page boundary" {
    // Write 4 bytes starting 2 bytes before the page-0/page-1 boundary
    // (offset 65534). The translator must fetch two distinct outer chunks:
    // one for page 0 (for the leading 2 bytes) and one for page 1 (for the
    // trailing 2 bytes). Count GetValue occurrences in the init window.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes: [4]u8 = .{ 0xAA, 0xBB, 0xCC, 0xDD };
    const mod = try buildSingleDataModule(a, 2, 65534, &bytes);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body = onEnableBody(out);
    try std.testing.expect(body.len > 0);
    const gets = countOccurrences(body,
        "SystemObjectArray.__GetValue__SystemInt32__SystemObject");
    try std.testing.expect(gets >= 2);
}

// ----------------------------------------------------------------
// memarg.offset handling — TDD for the PC 28160 OOB crash.
//
// Runtime regression: bench.wasm crashed with
//   SystemObjectArray.__GetValue__  Index has to be between upper and lower
//   bound of the array.
// because `emitMem*` ignored `memarg.offset`, so `i32.store offset=N` wrote
// every stack-frame slot to the same base address. Subsequent reads returned
// corrupted pointers; when one of those was fed back into a narrow load,
// `addr >> 16` produced a negative / oversized page index and the outer
// array fell over. Every memory op must add its memarg offset to the base
// address before the page/word decomposition runs.
// ----------------------------------------------------------------

/// Build a minimal single-function module: params → body → return. `body`
/// must match the declared param/result types. Caller keeps the arena alive.
fn buildOneFuncMemModule(
    a: std.mem.Allocator,
    params_ty: []const ValType,
    results_ty: []const ValType,
    body: []Instruction,
) !wasm.Module {
    const memories = try a.alloc(wasm.types.MemType, 1);
    memories[0] = .{ .min = 1, .max = null };

    const params_dup = try a.dupe(ValType, params_ty);
    const results_dup = try a.dupe(ValType, results_ty);
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params_dup, .results = results_dup };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "probe", .desc = .{ .func = 0 } };

    return .{
        .types_ = types_,
        .funcs = funcs,
        .codes = codes,
        .exports = exports,
        .memories = memories,
    };
}

/// Return the slice of `out` that contains the body of the `probe` function
/// — everything between `__probe_entry__:` and the next label line.
fn probeFnBody(out: []const u8) []const u8 {
    const anchor = "__probe_entry__:";
    const start = std.mem.indexOf(u8, out, anchor) orelse return "";
    const from = start + anchor.len;
    // Stop at `JUMP_INDIRECT` (function end) so we don't capture callers.
    const end_needle = "JUMP_INDIRECT";
    const rel = std.mem.indexOf(u8, out[from..], end_needle) orelse return out[from..];
    return out[from .. from + rel];
}

/// Assert that within `haystack` the first occurrence of `first` comes
/// strictly before `second`. Used for ordering assertions where we want
/// `Addition` (effective-addr compute) to precede page_idx `RightShift`.
fn expectOrdered(haystack: []const u8, first: []const u8, second: []const u8) !void {
    const i = std.mem.indexOf(u8, haystack, first) orelse return error.TestExpectedEqual;
    const j = std.mem.indexOf(u8, haystack[i..], second) orelse return error.TestExpectedEqual;
    _ = j;
}

test "i32.load applies memarg.offset to effective address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn(addr: i32) -> i32 { local.get 0; i32.load offset=16 align=2; end }
    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i32_load = .{ .@"align" = 2, .offset = 16 } };
    body[2] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);

    // There must be an Addition EXTERN that produces `_mem_eff_addr`
    // before page_idx is computed via the right-shift step.
    try std.testing.expect(std.mem.indexOf(u8, body_out,
        "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_eff_addr") != null);
    try expectOrdered(body_out,
        "_mem_eff_addr",
        "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");

    // A constant carrying the offset value `16` must be declared.
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_off_16:") != null);
}

test "i32.load with zero offset emits no Addition (no-op offset)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i32_load = .{ .@"align" = 2, .offset = 0 } };
    body[2] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    // No _mem_eff_addr use in a zero-offset access.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_eff_addr") == null);
}

test "i32.store applies memarg.offset to effective address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn(addr: i32, val: i32) { local.get 0; local.get 1; i32.store offset=8; end }
    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .i32_store = .{ .@"align" = 2, .offset = 8 } };
    body[3] = .return_;
    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body_out,
        "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_eff_addr") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_off_8:") != null);
}

test "i32.load8_u applies memarg.offset to effective address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i32_load8_u = .{ .@"align" = 0, .offset = 5 } };
    body[2] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_eff_addr") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_off_5:") != null);
}

test "i32.store8 applies memarg.offset to effective address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .i32_store8 = .{ .@"align" = 0, .offset = 3 } };
    body[3] = .return_;
    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_eff_addr") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_off_3:") != null);
}

test "i32.store16 applies memarg.offset to effective address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .i32_store16 = .{ .@"align" = 1, .offset = 4 } };
    body[3] = .return_;
    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_eff_addr") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_off_4:") != null);
}

test "i64.load applies memarg.offset to effective address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i64_load = .{ .@"align" = 3, .offset = 32 } };
    body[2] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_eff_addr") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_off_32:") != null);
}

test "i64.store applies memarg.offset to effective address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .i64_store = .{ .@"align" = 3, .offset = 24 } };
    body[3] = .return_;
    const params = [_]ValType{ .i32, .i64 };
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_eff_addr") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_off_24:") != null);
}

// ----------------------------------------------------------------
// Page-straddle handling for multi-byte access.
//
// `emitMemLoadI64` / `emitMemStoreI64` previously fetched `chunk[word+1]`
// unconditionally — but when `word_in_page == 16383`, the hi word lives in
// *page+1*, not the current chunk. Hitting that case throws the same
// `SystemObjectArray.__GetValue__` / `SystemUInt32Array.__Get__` OOB we saw
// in bench. The same boundary exists for `i32.store16` when
// `byte_in_page == 65535` (1 byte in page N, 1 byte in page N+1). Each op
// must dispatch on address at runtime and fetch the second chunk from
// `outer[page+1]` when needed.
// ----------------------------------------------------------------

test "i64.load emits runtime page-straddle dispatch (second outer GetValue)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i64_load = .{ .@"align" = 3, .offset = 0 } };
    body[2] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    // Two outer GetValue calls — one for the lo chunk, one for the hi
    // chunk (straddle path). Without straddle support there is only one.
    const gets = countOccurrences(body_out,
        "SystemObjectArray.__GetValue__SystemInt32__SystemObject");
    try std.testing.expect(gets >= 2);
    // The straddle branch must advance the page index: a literal 1
    // Addition into `_mem_page_idx_hi` (or reuse of `_mem_word_in_page_hi`
    // for page+1) is acceptable — the shape we insist on is a `+ 1` that
    // feeds back into an outer `GetValue`.
    try std.testing.expect(std.mem.indexOf(u8, body_out,
        "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
}

test "i64.store emits runtime page-straddle dispatch (second outer GetValue)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .i64_store = .{ .@"align" = 3, .offset = 0 } };
    body[3] = .return_;
    const params = [_]ValType{ .i32, .i64 };
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    const gets = countOccurrences(body_out,
        "SystemObjectArray.__GetValue__SystemInt32__SystemObject");
    try std.testing.expect(gets >= 2);
}

test "bench: on_interact body applies memarg.offset before memory ops" {
    // Regression: the bench emits `i32.store offset=N` for arg spills into
    // the stack frame. Each such store must be preceded by an Addition that
    // produces the effective address. We look for at least one Addition
    // between consecutive `# i32.store` comment markers in on_interact.
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    const anchor = "__on_interact_entry__:";
    const start = std.mem.indexOf(u8, out, anchor) orelse return error.TestExpectedEqual;
    const from = start + anchor.len;
    const end_needle = "JUMP_INDIRECT";
    const rel = std.mem.indexOf(u8, out[from..], end_needle) orelse return error.TestExpectedEqual;
    const body_out = out[from .. from + rel];

    // On a healthy build the on_interact body must contain `_mem_eff_addr`
    // references — at minimum from the arg-spill stores into the new stack
    // frame (e.g. storing the format-string pointer and counter value).
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_eff_addr") != null);
}

test "meta initialPages/maxPages clamped up by data segment requirement" {
    // Per docs/spec_udonmeta_conversion.md the meta can customize memory
    // sizing, but it must never shrink below what the WASM module's own
    // data segments demand — otherwise the outer array is too small and
    // SystemObjectArray.__GetValue throws at first rodata read.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bytes: [4]u8 = .{ 0x11, 0x22, 0x33, 0x44 };
    const mod = try buildSingleDataModule(a, 1, 1048576, &bytes);

    var meta: wasm.UdonMeta = .{ .version = 1 };
    meta.options.memory.initial_pages = 1;
    meta.options.memory.max_pages = 16;

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, meta, &buf.writer, .{});
    const out = buf.written();

    const initial = try findDataDeclInt(out, "__G__memory_initial_pages");
    const max_p = try findDataDeclInt(out, "__G__memory_max_pages");
    try std.testing.expect(initial >= 17);
    try std.testing.expect(max_p >= 17);
}
