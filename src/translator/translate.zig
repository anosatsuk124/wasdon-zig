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
const lower_wasi = @import("lower_wasi.zig");
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
    NonConstInitExpr,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Options the translator takes. For the MVP we pass through the defaults
/// straight from `__udon_meta`. Callers can override `default_max_pages` when
/// the WASM module has no `max` on its memory and the meta is silent.
pub const Options = struct {
    default_max_pages: u32 = 16,
    /// When true, every memory op emits a preamble that records the
    /// effective byte address and a unique site id into
    /// `_mem_oob_addr` / `_mem_oob_site` before the bounds check, and
    /// `__mem_oob_trap__` formats those into the error message. A uasm
    /// comment `; mem op site=N fn=F wasm_idx=I op=... kind=...`
    /// precedes each preamble so the logged `site=N` can be mapped back
    /// to the source instruction via grep. Off by default — the preamble
    /// adds 2 COPY + one i32 const addData per memory op plus a few
    /// String fields for the trap message.
    mem_oob_diagnostics: bool = false,
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

    /// Per (def_idx, depth) bitmask of `ValType`s that were observed at
    /// that stack position during codegen. Bits: i32=1, i64=2, f32=4,
    /// f64=8. Populated by `FuncCtx.push` via `recordSlotType`. Drives
    /// typed `__fn_Sd_{i32|i64|f32|f64}__` declarations in
    /// `emitFunctionStackSlots` so each runtime value lives in a slot of
    /// its exact type — avoiding the Udon type-tag mismatch that triggers
    /// "Cannot retrieve heap variable of type X as type Y" when the same
    /// untyped slot is reused for different value types.
    fn_slot_type_bits: []std.ArrayListUnmanaged(u8) = &.{},

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

    /// Monotonic counter used by `recordMemOpSite` to mint a fresh
    /// `__mem_site_<N>: SystemInt32 = <N>` constant per memory op when
    /// `options.mem_oob_diagnostics` is on. The logged `site=N` maps
    /// back to a uasm comment line that names the WASM source location.
    mem_op_site_counter: u32 = 0,

    /// Deduplicated i64 constants that need runtime initialization in
    /// `_onEnable`. Udon spec §4.7 forbids non-null literal initializers for
    /// `SystemInt64` heap variables, so any `i64.const V` with V != 0 must
    /// be synthesized at startup from two `SystemInt32` halves (which *do*
    /// accept arbitrary literal initializers) via BitConverter + UInt64 OR.
    /// Keyed by raw i64 value for dedup so shared constants (shift counts,
    /// error tags) pay the synthesis cost once.
    i64_consts: std.AutoHashMapUnmanaged(i64, []const u8) = .empty,

    /// Ordered list of i64 constants for deterministic init emission in
    /// `_onEnable`. Mirrors `i64_consts` entries in insertion order; each
    /// element carries the resolved slot name and the helper Int32 slot
    /// names for the hi/lo halves (owned by the arena allocator).
    i64_const_inits: std.ArrayListUnmanaged(Const64Init) = .empty,

    /// Deduplicated f64 constants. Same restriction as i64: Udon spec §4.7
    /// forbids non-null `SystemDouble` literals, so every non-0.0 f64.const
    /// is synthesized at `_onEnable` time. Keyed by the raw 64-bit pattern
    /// (`@bitCast(f64)`) rather than the float value itself so `NaN != NaN`
    /// doesn't defeat AutoHashMap, and `-0.0` / `+0.0` stay distinct
    /// (they differ in bit 63, which matters for WASM `f64.const`
    /// reproducibility even though they compare equal).
    f64_consts: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,

    /// Ordered list of f64 constants, mirroring `i64_const_inits` but with
    /// a `SystemDouble` target slot. The synthesis pipeline is identical
    /// up to the final EXTERN, which writes into the Double slot via
    /// `SystemBitConverter.__ToDouble__SystemByteArray_SystemInt32__SystemDouble`.
    f64_const_inits: std.ArrayListUnmanaged(Const64Init) = .empty,

    /// Per-translation-unit flags controlling the lazy emission of the two
    /// shared trunc_sat helper subroutines (see
    /// `docs/spec_numeric_instruction_lowering.md` §5). Set the first time
    /// `emitTruncSat` lowers an opcode whose output is i32 / i64; consumed
    /// by `emitTruncSatHelpers` after `emitDefinedFunctions` to materialise
    /// the helper body exactly once per output bit-width.
    trunc_sat_helper_needed_i32: bool = false,
    trunc_sat_helper_needed_i64: bool = false,
    /// Have we already declared the trunc_sat data slots and registered
    /// the f64 clamp constants? Set on first use so pure non-trunc_sat
    /// modules don't pay the `_onEnable` synthesis cost.
    trunc_sat_data_declared: bool = false,

    /// Shared init descriptor for both `SystemInt64` and `SystemDouble`
    /// constants. The synthesis pipeline is shared across the two types;
    /// only the terminal conversion EXTERN differs (see
    /// `emitSynthesize64Bit`).
    const Const64Init = struct {
        /// Name of the target slot (`SystemInt64` or `SystemDouble`).
        slot: []const u8,
        /// Name of the `SystemInt32` slot holding the high 32 bits.
        hi_slot: []const u8,
        /// Name of the `SystemInt32` slot holding the low 32 bits.
        lo_slot: []const u8,
        /// Raw 64-bit pattern — kept for diagnostics / tests.
        bits: u64,
    };

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
        self.i64_consts.deinit(self.gpa);
        self.i64_const_inits.deinit(self.gpa);
        self.f64_consts.deinit(self.gpa);
        self.f64_const_inits.deinit(self.gpa);
        if (self.is_recursive.len > 0) self.gpa.free(self.is_recursive);
        if (self.fn_max_stack_depth.len > 0) self.gpa.free(self.fn_max_stack_depth);
        if (self.fn_slot_type_bits.len > 0) {
            for (self.fn_slot_type_bits) |*bits| bits.deinit(self.gpa);
            self.gpa.free(self.fn_slot_type_bits);
        }
        self.asm_.deinit();
        self.arena.deinit();
    }

    fn aa(self: *Translator) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Resolve the WASI configuration for this translation unit by overlaying
    /// `__udon_meta.wasi.*` overrides on top of the static defaults from
    /// `lower_wasi.Config`.
    fn wasiConfig(self: *Translator) lower_wasi.Config {
        var cfg = lower_wasi.Config{};
        if (self.meta) |m| {
            cfg.strict = m.options.strict;
            if (m.wasi) |w| {
                if (w.stdout_extern) |s| cfg.stdout_extern = s;
                if (w.stderr_extern) |s| cfg.stderr_extern = s;
            }
        }
        return cfg;
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
        self.fn_slot_type_bits = try self.gpa.alloc(std.ArrayListUnmanaged(u8), self.mod.codes.len);
        for (self.fn_slot_type_bits) |*bits| bits.* = .empty;
        try self.emitCommonData();
        try self.emitGlobalsData();
        try self.emitMemoryData();
        try self.emitFunctionData();
        try self.emitIndirectData();
        // Functions must be lowered before `emitEventEntries` because
        // lowering `.i64_const` populates `i64_const_inits` and the
        // `_onEnable` event body synthesizes each registered slot at
        // startup. Labels declared by functions are forward-referenced
        // from events and resolved during the final layout pass, so the
        // reverse order doesn't break call targeting.
        try self.emitDefinedFunctions();
        try self.emitTruncSatHelpers();
        try self.emitEventEntries();
        try self.emitIndirectTrampolines();
        try self.emitMemOobTrap();
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
                // Prefer a meta-configured udonName for `kind: import`
                // bindings; fall back to `__G__imp_<module>_<name>`.
                var chosen: ?[]const u8 = null;
                if (self.meta) |m| {
                    for (m.fields) |f| {
                        if (importMetaMatches(f, imp)) {
                            if (f.udon_name) |un| chosen = un;
                            break;
                        }
                    }
                }
                if (chosen == null) {
                    chosen = try std.fmt.allocPrint(self.aa(), "__G__imp_{s}_{s}", .{ imp.module, imp.name });
                }
                buf[i] = chosen.?;
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
        // Size is a fixed upper bound on (max recursion depth) * (max saved
        // slots per frame). 4096 slots ≈ 64 frames of ~60 slots, which is
        // well above anything the bench exercises; grow this if a recursive
        // function overflows at runtime.
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
        try self.asm_.addData(.{
            .name = "__call_stack_size__",
            .ty = tn.int32,
            .init = .{ .int32 = 4096 },
        });
    }

    /// Default Udon type for a WASM `ValType`. Used by both the
    /// imported-globals and module-globals slot emitters.
    fn udonTypeForValType(vt: wasm.types.ValType) tn.TypeName {
        return switch (vt) {
            .i32 => tn.int32,
            .i64 => tn.int64,
            .f32 => tn.single,
            .f64 => tn.double,
        };
    }

    /// True iff this meta field binds an imported WASM global with the
    /// given `(module, name)` pair.
    fn importMetaMatches(f: wasm.udon_meta.Field, imp: wasm.module.Import) bool {
        if (f.source.kind != .import) return false;
        const fmod = f.source.module orelse return false;
        const fname = f.source.name orelse return false;
        return std.mem.eql(u8, fmod, imp.module) and std.mem.eql(u8, fname, imp.name);
    }

    /// Apply meta-driven `is_export` / `sync` / type / `default: "this"`
    /// overrides to a slot. Reference types (object / gameobject /
    /// transform / udon_behaviour) override the WASM-valtype default; the
    /// literal `"this"` lowers to the Udon `this` token
    /// (docs/udon_specs.md §4.6). The runtime resolver only accepts
    /// gameobject / transform / udon_behaviour as `this` targets — raw
    /// `SystemObject` with `this` halts at load time, so callers should
    /// pick the matching narrow type when defaulting to `this`.
    fn applyMetaSlotOverrides(
        f: wasm.udon_meta.Field,
        ud_ty: *tn.TypeName,
        lit: *Literal,
        is_export: *bool,
        sync: *?udon.asm_.SyncMode,
    ) void {
        is_export.* = f.is_export;
        if (f.sync.enabled) sync.* = switch (f.sync.mode orelse .none) {
            .none => .none,
            .linear => .linear,
            .smooth => .smooth,
        };
        if (f.type) |ft| switch (ft) {
            .object, .gameobject, .transform, .udon_behaviour => {
                ud_ty.* = switch (ft) {
                    .object => tn.object,
                    .gameobject => tn.gameobject,
                    .transform => tn.transform,
                    .udon_behaviour => tn.udon_behaviour,
                    else => unreachable,
                };
                lit.* = .null_literal;
                if (f.default) |dv| switch (dv) {
                    .string => |s| if (std.mem.eql(u8, s, "this")) {
                        lit.* = .this_ref;
                    },
                    else => {},
                };
            },
            else => {},
        };
    }

    fn emitGlobalsData(self: *Translator) Error!void {
        // (a) Imported WASM globals — their data-section slot is what
        // `emitGlobalGet` PUSHes via the unified `global_udon_names`
        // array. The slot type/init come entirely from meta (imports
        // have no WASM-side init); without a meta override they default
        // to the WASM-valtype zero.
        var imp_idx: u32 = 0;
        for (self.mod.imports) |imp| switch (imp.desc) {
            .global => |gt| {
                defer imp_idx += 1;
                const name = self.global_udon_names[imp_idx];
                var ud_ty: tn.TypeName = udonTypeForValType(gt.valtype);
                var lit: Literal = .null_literal;
                var is_export = false;
                var sync: ?udon.asm_.SyncMode = null;
                if (self.meta) |m| {
                    for (m.fields) |f| {
                        if (importMetaMatches(f, imp)) {
                            applyMetaSlotOverrides(f, &ud_ty, &lit, &is_export, &sync);
                            break;
                        }
                    }
                }
                try self.asm_.addData(.{
                    .name = name,
                    .ty = ud_ty,
                    .init = lit,
                    .is_export = is_export,
                    .sync = sync,
                });
            },
            else => {},
        };

        // (b) Meta-only slots backing function-import bindings. Zig 0.16
        // cannot emit `(import (global …))` directly, so authors expose
        // Udon-only singletons through a nullary function import and a
        // `kind: import` meta entry that names the Udon slot. Each such
        // binding needs its slot declared here (the matching `call` site
        // is lowered in `tryEmitMetaImportRead` as a slot-copy).
        if (self.meta) |m| {
            outer: for (m.fields) |f| {
                if (f.source.kind != .import) continue;
                const udon_name = f.udon_name orelse continue;
                // Skip if this binding already matched a `(import (global))`
                // emitted in (a) — that path already declared the slot.
                for (self.mod.imports) |imp| switch (imp.desc) {
                    .global => if (importMetaMatches(f, imp)) continue :outer,
                    else => {},
                };
                // Default to SystemObject for purely-meta-described slots;
                // applyMetaSlotOverrides will narrow it to the right
                // reference type when `f.type` is set.
                var ud_ty: tn.TypeName = tn.object;
                var lit: Literal = .null_literal;
                var is_export = false;
                var sync: ?udon.asm_.SyncMode = null;
                applyMetaSlotOverrides(f, &ud_ty, &lit, &is_export, &sync);
                try self.asm_.addData(.{
                    .name = udon_name,
                    .ty = ud_ty,
                    .init = lit,
                    .is_export = is_export,
                    .sync = sync,
                });
            }
        }

        // (c) Module-defined globals.
        for (0..self.mod.globals.len) |i| {
            const gidx: u32 = self.num_imported_globals + @as(u32, @intCast(i));
            const g = self.mod.globals[i];
            const name = self.global_udon_names[gidx];
            var ud_ty: tn.TypeName = udonTypeForValType(g.ty.valtype);
            // Per docs/udon_specs.md §4.7, only SystemInt32/UInt32/Single/String
            // accept non-null/non-this numeric literals. i64/f64 must be null.
            var lit: Literal = if (g.init.len == 1) switch (g.init[0]) {
                .i32_const => |v| Literal{ .int32 = v },
                .i64_const => Literal.null_literal,
                .f32_const => |v| Literal{ .single = v },
                .f64_const => Literal.null_literal,
                else => Literal{ .int32 = 0 },
            } else Literal{ .int32 = 0 };
            var is_export = false;
            var sync: ?udon.asm_.SyncMode = null;
            if (self.meta) |m| {
                for (m.fields) |f| {
                    if (f.udon_name) |un| if (std.mem.eql(u8, un, name)) {
                        applyMetaSlotOverrides(f, &ud_ty, &lit, &is_export, &sync);
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
        // Shift counts for the post-MVP sign-extension opcodes
        // (`i64.extend16_s` = 48, `i64.extend8_s` = 56). Both shift EXTERNs
        // (i32 and i64) take SystemInt32 for the RHS, hence Int32 fields.
        // See docs/spec_numeric_instruction_lowering.md §4.
        try self.asm_.addData(.{ .name = "__c_i32_48", .ty = tn.int32, .init = .{ .int32 = 48 } });
        try self.asm_.addData(.{ .name = "__c_i32_56", .ty = tn.int32, .init = .{ .int32 = 56 } });
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
        // Scratch slots for memory.copy (overlap-safe byte loop). Shared
        // across every memory.copy site in the program — each call body
        // fully writes them before reading, so reuse is safe. Per-call
        // uniqueness is provided by the loop labels (see emitMemoryCopy).
        try self.asm_.addData(.{ .name = "_mc_dst", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mc_src", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mc_n", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mc_i", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mc_addr_src", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mc_addr_dst", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mc_byte", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mc_cmp", .ty = tn.boolean, .init = .null_literal });
        // Scratch slots for memory.fill (forward byte-store loop). Distinct
        // from `_mc_*` so memory.copy and memory.fill never alias even if a
        // future optimisation pass interleaves them; per-call uniqueness is
        // provided by the loop labels (see emitMemoryFill).
        try self.asm_.addData(.{ .name = "_mf_dst", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mf_val", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mf_n", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mf_i", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mf_addr", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mf_cmp", .ty = tn.boolean, .init = .null_literal });
        // Scratch slots for memory.grow.
        try self.asm_.addData(.{ .name = "_mg_old", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mg_new", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mg_i", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_mg_cmp", .ty = tn.boolean, .init = .null_literal });
        // Shared Boolean return slot for numeric comparison EXTERNs
        // (`op_Equality`, `op_LessThan`, etc.). Udon strictly type-checks
        // EXTERN argument slots against the signature, so a Boolean-returning
        // op must be given a SystemBoolean destination heap variable. The
        // Int32 stack slot cannot be reused; the result is converted back to
        // Int32 (0/1) via SystemConvert immediately after the comparison so
        // WASM-visible `i32.eq` etc. semantics are preserved.
        try self.asm_.addData(.{ .name = "_cmp_bool", .ty = tn.boolean, .init = .null_literal });
        // Int32 scratch for shift counts. WASM's `i64.shl`/`i64.shr_*` take
        // an i64 shift count, but the corresponding Udon EXTERNs
        // (`SystemInt64.__op_LeftShift__SystemInt64_SystemInt32__SystemInt64`,
        // `SystemUInt64.__op_RightShift__SystemUInt64_SystemInt32__SystemUInt64`,
        // etc.) take Int32. The WASM stack slot holding the count gets its
        // runtime type-tag bumped to Int64 the moment an i64 value is
        // written into it, so we must narrow through SystemConvert before
        // feeding it to the shift op.
        try self.asm_.addData(.{ .name = "_shift_rhs_i32", .ty = tn.int32, .init = .{ .int32 = 0 } });
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
        // BitConverter scratch for Int32 ↔ UInt32 bit-pattern conversion.
        // Udon's heap is strongly typed — writing an Int32 stack slot to a
        // UInt32 EXTERN argument (or vice versa) throws "Cannot retrieve
        // heap variable of type 'Int32' as type 'UInt32'". `SystemConvert`
        // overflows on negative values, so we route values through
        // `SystemBitConverter.GetBytes` / `ToUInt32` (or `ToInt32`) to
        // preserve the bit pattern for every i32/u32 value.
        try self.asm_.addData(.{ .name = "_mem_bits_ba", .ty = tn.byte_array, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_mem_val_u32_buf", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_mem_val_i32_buf", .ty = tn.int32, .init = .{ .int32 = 0 } });
        // Message logged when a memory access would OOB the outer
        // SystemObjectArray. The trap block at `__mem_oob_trap__`
        // (emitted at the tail of the code section) pushes this into
        // Unity's log and halts the UdonBehaviour. Closest Udon analog
        // to a WASM trap — see emitMemOobTrap.
        //
        // The trap message is assembled at runtime as
        //   "<prefix>; page=<page_idx>; max=<max_pages>"
        // so a future reader of the log can tell *which* page was bad
        // and whether `__udon_meta` sized `max_pages` below the program's
        // actual working set. The three string literals (`_mem_oob_msg`,
        // `_mem_oob_page_label`, `_mem_oob_max_label`) live in .data,
        // the per-trap concatenation output lands in `_mem_oob_msg_out`.
        try self.asm_.addData(.{
            .name = "_mem_oob_msg",
            .ty = tn.string,
            .init = .{ .string = "wasdon: WASM memory access out of bounds; halting UdonBehaviour" },
        });
        try self.asm_.addData(.{
            .name = "_mem_oob_page_label",
            .ty = tn.string,
            .init = .{ .string = "; page=" },
        });
        try self.asm_.addData(.{
            .name = "_mem_oob_max_label",
            .ty = tn.string,
            .init = .{ .string = "; max=" },
        });
        try self.asm_.addData(.{ .name = "_mem_oob_page_str", .ty = tn.string, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_mem_oob_max_str", .ty = tn.string, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_mem_oob_msg_out", .ty = tn.string, .init = .null_literal });
        // Diagnostic-only scratch: populated by `recordMemOpSite` before
        // every `emitOuterGetChecked` call and formatted into the trap
        // message when `options.mem_oob_diagnostics` is on. Out of the
        // default-emit path because the extra Concat args + per-op COPY
        // preamble materially bloat the uasm.
        if (self.options.mem_oob_diagnostics) {
            try self.asm_.addData(.{ .name = "_mem_oob_addr", .ty = tn.int32, .init = .{ .int32 = 0 } });
            try self.asm_.addData(.{ .name = "_mem_oob_site", .ty = tn.int32, .init = .{ .int32 = 0 } });
            try self.asm_.addData(.{
                .name = "_mem_oob_site_label",
                .ty = tn.string,
                .init = .{ .string = "; site=" },
            });
            try self.asm_.addData(.{
                .name = "_mem_oob_addr_label",
                .ty = tn.string,
                .init = .{ .string = "; addr=" },
            });
            try self.asm_.addData(.{ .name = "_mem_oob_site_str", .ty = tn.string, .init = .null_literal });
            try self.asm_.addData(.{ .name = "_mem_oob_addr_str", .ty = tn.string, .init = .null_literal });
        }
        // Scratch for numeric ops whose operand or result type is u32/u64
        // but whose WASM stack slot is Int32/Int64. The same BitConverter
        // pattern that memory ops use routes each operand through a UInt32/
        // UInt64 scratch slot, and converts the result back on the way out.
        try self.asm_.addData(.{ .name = "_num_lhs_u32", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_num_rhs_u32", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_num_res_u32", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_num_lhs_u64", .ty = tn.uint64, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_num_rhs_u64", .ty = tn.uint64, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_num_res_u64", .ty = tn.uint64, .init = .null_literal });
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
        // Scratch for i32.rem_u expansion (Udon has no SystemUInt32.__op_Modulus__).
        try self.asm_.addData(.{ .name = "_rem_q_u32", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "_rem_qb_u32", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        // Scratch for i64.rem_s expansion (Udon ships neither SystemInt64
        // Modulus nor Remainder).
        try self.asm_.addData(.{ .name = "_rem_q_i64", .ty = tn.int64, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_rem_qb_i64", .ty = tn.int64, .init = .null_literal });
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

    /// Emit typed `__fn_Sd_{i32|i64|f32|f64}__` data declarations — one per
    /// (function, depth, valtype) tuple observed during codegen. Each runtime
    /// value therefore lives in a physical slot whose declared type matches
    /// its WASM type, so Udon's heap type-tag (which `COPY` bumps to the
    /// source type on every write) never drifts out from under a consumer
    /// expecting a different type.
    ///
    /// Must be called after `emitDefinedFunctions` so `fn_slot_type_bits`
    /// is populated. The rendered data section stays inside `.data_start`
    /// regardless of insertion order (see `udon/asm.zig` `render`).
    fn emitFunctionStackSlots(self: *Translator) Error!void {
        for (0..self.mod.codes.len) |def_idx| {
            const fn_idx: u32 = self.num_imported_funcs + @as(u32, @intCast(def_idx));
            const fn_name = self.fn_names[fn_idx];
            const bits = self.fn_slot_type_bits[def_idx].items;
            for (bits, 0..) |mask, depth_usz| {
                const d: u32 = @intCast(depth_usz);
                for (all_val_types) |vt| {
                    if ((mask & slotTypeBit(vt)) == 0) continue;
                    const n = try names.stackSlot(self.aa(), fn_name, d, vt);
                    try self.asm_.addData(.{
                        .name = n,
                        .ty = udonTypeOf(vt),
                        .init = zeroLit(vt),
                    });
                }
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
            try self.emit64BitConstInits();
            try self.emitMemoryInit();
            try self.emitCallStackInit();
            try self.asm_.jumpAddr(0xFFFFFFFC);
        }

        for (self.event_bindings.items) |ev| {
            const fn_idx = self.findExportedFunc(ev.wasm_export) orelse continue;
            try self.asm_.exportLabel(ev.udon_label);
            try self.asm_.label(ev.udon_label);
            if (std.mem.eql(u8, ev.udon_label, "_onEnable")) {
                try self.emit64BitConstInits();
                try self.emitMemoryInit();
                try self.emitCallStackInit();
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

    /// Shared halt block reached by every memory-op bounds check. Every
    /// outer-array GetValue goes through `emitOuterGetChecked`, whose
    /// bounds check funnels into this label on failure. Builds a
    /// diagnostic message of the form
    ///   "wasdon: WASM memory access out of bounds; page=N; max=M"
    /// so the Unity log reveals which page index tripped the trap and
    /// the configured `max_pages`. Halts the UdonBehaviour by jumping
    /// to `0xFFFFFFFC` — the closest thing Udon has to a WASM trap.
    fn emitMemOobTrap(self: *Translator) Error!void {
        if (self.mod.memories.len == 0) return;
        try self.asm_.label("__mem_oob_trap__");
        // page_str := _mem_page_idx.ToString()
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("_mem_oob_page_str");
        try self.asm_.extern_("SystemInt32.__ToString__SystemString");
        // max_str := memory_max_pages.ToString()
        try self.asm_.push(self.memory_max_pages_name);
        try self.asm_.push("_mem_oob_max_str");
        try self.asm_.extern_("SystemInt32.__ToString__SystemString");

        if (self.options.mem_oob_diagnostics) {
            // site_str := _mem_oob_site.ToString()
            try self.asm_.push("_mem_oob_site");
            try self.asm_.push("_mem_oob_site_str");
            try self.asm_.extern_("SystemInt32.__ToString__SystemString");
            // addr_str := _mem_oob_addr.ToString()
            try self.asm_.push("_mem_oob_addr");
            try self.asm_.push("_mem_oob_addr_str");
            try self.asm_.extern_("SystemInt32.__ToString__SystemString");
            // out := Concat(prefix, "; site=", site_str, "; addr=")
            try self.asm_.push("_mem_oob_msg");
            try self.asm_.push("_mem_oob_site_label");
            try self.asm_.push("_mem_oob_site_str");
            try self.asm_.push("_mem_oob_addr_label");
            try self.asm_.push("_mem_oob_msg_out");
            try self.asm_.extern_("SystemString.__Concat__SystemString_SystemString_SystemString_SystemString__SystemString");
            // out := Concat(out, addr_str, "; page=", page_str)
            try self.asm_.push("_mem_oob_msg_out");
            try self.asm_.push("_mem_oob_addr_str");
            try self.asm_.push("_mem_oob_page_label");
            try self.asm_.push("_mem_oob_page_str");
            try self.asm_.push("_mem_oob_msg_out");
            try self.asm_.extern_("SystemString.__Concat__SystemString_SystemString_SystemString_SystemString__SystemString");
            // out := Concat(out, "; max=", max_str)
            try self.asm_.push("_mem_oob_msg_out");
            try self.asm_.push("_mem_oob_max_label");
            try self.asm_.push("_mem_oob_max_str");
            try self.asm_.push("_mem_oob_msg_out");
            try self.asm_.extern_("SystemString.__Concat__SystemString_SystemString_SystemString__SystemString");
        } else {
            // out := Concat(prefix, "; page=", page_str, "; max=")
            try self.asm_.push("_mem_oob_msg");
            try self.asm_.push("_mem_oob_page_label");
            try self.asm_.push("_mem_oob_page_str");
            try self.asm_.push("_mem_oob_max_label");
            try self.asm_.push("_mem_oob_msg_out");
            try self.asm_.extern_("SystemString.__Concat__SystemString_SystemString_SystemString_SystemString__SystemString");
            // out := Concat(out, max_str)
            try self.asm_.push("_mem_oob_msg_out");
            try self.asm_.push("_mem_oob_max_str");
            try self.asm_.push("_mem_oob_msg_out");
            try self.asm_.extern_("SystemString.__Concat__SystemString_SystemString__SystemString");
        }

        try self.asm_.push("_mem_oob_msg_out");
        try self.asm_.extern_("UnityEngineDebug.__LogError__SystemObject__SystemVoid");
        try self.asm_.jumpAddr(0xFFFFFFFC);
    }

    /// Diagnostic preamble: record the effective byte address and a
    /// fresh site id into `_mem_oob_addr` / `_mem_oob_site`, and emit a
    /// uasm comment mapping the site id back to the WASM source
    /// location. No-op unless `options.mem_oob_diagnostics` is on — the
    /// per-op preamble is too expensive to enable by default. Call this
    /// immediately before `emitOuterGetChecked` so the recorded values
    /// are accurate at the moment the bounds check fails.
    ///
    /// `kind_tag` distinguishes lo- vs. hi-page fetches in straddle
    /// paths (pass `"primary"` for non-straddle). `op_tag` should name
    /// the WASM instruction being lowered (e.g. `"i32.load"`,
    /// `"i64.store"`) so the comment is greppable.
    fn recordMemOpSite(
        self: *Translator,
        fn_name: []const u8,
        addr_slot: []const u8,
        op_tag: []const u8,
        kind_tag: []const u8,
    ) Error!void {
        if (!self.options.mem_oob_diagnostics) return;
        const site_id = self.mem_op_site_counter;
        self.mem_op_site_counter += 1;
        const site_name = try std.fmt.allocPrint(self.aa(), "__mem_site_{d}", .{site_id});
        try self.asm_.addData(.{
            .name = site_name,
            .ty = tn.int32,
            .init = .{ .int32 = @intCast(site_id) },
        });
        const comment = try std.fmt.allocPrint(
            self.aa(),
            "mem op site={d} fn={s} op={s} kind={s}",
            .{ site_id, fn_name, op_tag, kind_tag },
        );
        try self.asm_.comment(comment);
        // _mem_oob_addr := addr_slot
        try self.asm_.push(addr_slot);
        try self.asm_.push("_mem_oob_addr");
        try self.asm_.copy();
        // _mem_oob_site := __mem_site_<N>
        try self.asm_.push(site_name);
        try self.asm_.push("_mem_oob_site");
        try self.asm_.copy();
    }

    /// Fetch `_mem_chunk := outer[page_idx_slot]` with a runtime bounds
    /// check. Jumps to `__mem_oob_trap__` when `page_idx_slot < 0` or
    /// `page_idx_slot >= memory_max_pages`. Does **not** mutate any
    /// caller-visible state other than `_mem_chunk` and `_mg_cmp`, so a
    /// straddle path that preserves the lo-page value in `_mem_page_idx`
    /// across a hi-page fetch stays sound.
    ///
    /// Every WASM memory op must funnel its outer-array access through
    /// this helper. The VM's raw `ArgumentOutOfRangeException` carries
    /// no information about *which* page was bad — by the time a crash
    /// report reaches the translator author the original computation is
    /// lost. Running the access through this check gives us a Unity
    /// log line that names the page index (see `__mem_oob_trap__`) and
    /// the configured max.
    ///
    /// The trap label reads `_mem_page_idx` for the `page=` field. When
    /// the failing access is a hi-page straddle fetch, the log line will
    /// show the lo-page value, not the hi page that actually tripped
    /// the check; callers can infer the hi page as `lo + 1`.
    fn emitOuterGetChecked(self: *Translator, page_idx_slot: []const u8) Error!void {
        // _mg_cmp := page_idx >= 0 (i.e. __c_i32_0 <= page_idx)
        try self.asm_.push("__c_i32_0");
        try self.asm_.push(page_idx_slot);
        try self.asm_.push("_mg_cmp");
        try self.asm_.extern_("SystemInt32.__op_LessThanOrEqual__SystemInt32_SystemInt32__SystemBoolean");
        try self.asm_.push("_mg_cmp");
        try self.asm_.jumpIfFalse("__mem_oob_trap__");
        // _mg_cmp := page_idx < memory_max_pages
        try self.asm_.push(page_idx_slot);
        try self.asm_.push(self.memory_max_pages_name);
        try self.asm_.push("_mg_cmp");
        try self.asm_.extern_("SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean");
        try self.asm_.push("_mg_cmp");
        try self.asm_.jumpIfFalse("__mem_oob_trap__");
        // _mem_chunk := outer[page_idx_slot]
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.push(page_idx_slot);
        try self.asm_.push("_mem_chunk");
        try self.asm_.extern_("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
    }

    /// Allocate `__call_stack__` with a fixed capacity so the caller-side
    /// recursion spill has a non-null receiver. Only emitted when some
    /// function is actually recursive AND `options.recursion == .stack`;
    /// otherwise the spill is never used and the 4096-slot array would
    /// just waste heap on every UdonBehaviour.
    fn emitCallStackInit(self: *Translator) Error!void {
        const m = self.meta orelse return;
        if (m.options.recursion != .stack) return;
        var any_recursive = false;
        for (self.is_recursive) |b| {
            if (b) {
                any_recursive = true;
                break;
            }
        }
        if (!any_recursive) return;
        try self.asm_.comment("recursion: call stack init");
        try self.asm_.push("__call_stack_size__");
        try self.asm_.push("__call_stack__");
        try self.asm_.extern_("SystemObjectArray.__ctor__SystemInt32__SystemObjectArray");
    }

    fn emitMemoryInit(self: *Translator) Error!void {
        if (self.mod.memories.len == 0) return;
        try self.asm_.comment("memory init (allocate outer + initial chunks)");
        // outer = new SystemObjectArray(max_pages)
        try self.asm_.push(self.memory_max_pages_name);
        try self.asm_.push(self.memory_udon_name);
        try self.asm_.extern_("SystemObjectArray.__ctor__SystemInt32__SystemObjectArray");
        // Materialize a chunk for every slot of the outer SystemObjectArray.
        // Previously we only filled the first `initial_pages` slots, which
        // left the rest null — any store that resolved to a page in
        // [initial, max) would throw at the subsequent `__Set__` call on a
        // null receiver. Allocating all max_pages chunks up front means
        // `outer.GetValue(p)` never returns null for a valid page index,
        // so every memory op can assume a non-null `_mem_chunk`. memory.grow
        // still tracks `_memory_size_pages` for WASM-visible semantics.
        const max_pages: u32 = self.effectiveMaxPages();
        var p: u32 = 0;
        while (p < max_pages) : (p += 1) {
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
    /// cache the UTF-8 encoding singleton. `emitDefinedFunctions` now runs
    /// before `emitEventEntries` (so the i64-const init list is fully
    /// populated by the time `_onEnable` flushes it), which means
    /// `lower_import` has already declared these scratch slots on demand by
    /// the time we get here. Use `declareScratchIfAbsent` so duplicates
    /// become no-ops instead of UAssembly "Data variable already exists"
    /// assembler errors.
    fn emitMarshalScratchInit(self: *Translator) Error!void {
        try self.declareScratchIfAbsent(lower_import.marshal_str_ptr_name, tn.int32, .{ .int32 = 0 });
        try self.declareScratchIfAbsent(lower_import.marshal_str_len_name, tn.int32, .{ .int32 = 0 });
        try self.declareScratchIfAbsent(lower_import.marshal_str_bytes_name, tn.byte_array, .null_literal);
        try self.declareScratchIfAbsent(lower_import.marshal_str_tmp_name, tn.string, .null_literal);
        try self.declareScratchIfAbsent(lower_import.marshal_str_i_name, tn.int32, .{ .int32 = 0 });
        try self.declareScratchIfAbsent(lower_import.marshal_str_addr_name, tn.int32, .{ .int32 = 0 });
        try self.declareScratchIfAbsent(lower_import.marshal_str_byte_name, tn.byte, .null_literal);
        try self.declareScratchIfAbsent(lower_import.marshal_str_cond_name, tn.boolean, .null_literal);
        try self.declareScratchIfAbsent(lower_import.marshal_encoding_name, tn.object, .null_literal);

        // encoding := Encoding.UTF8  (static property getter)
        try self.asm_.comment("cache UTF-8 encoding singleton");
        try self.asm_.push(lower_import.marshal_encoding_name);
        try self.asm_.extern_(lower_import.utf8_property_sig);
    }

    /// Idempotent counterpart to `asm_.addData`. Used from init paths
    /// (memory setup, marshal scratch, i64 const materialization) whose
    /// slots may already exist because `lower_import` declared them on
    /// demand during earlier function lowering.
    fn declareScratchIfAbsent(self: *Translator, name: []const u8, ty: tn.TypeName, lit: Literal) Error!void {
        for (self.asm_.datas.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return;
        }
        try self.asm_.addData(.{ .name = name, .ty = ty, .init = lit });
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

        try self.asm_.comment(try std.fmt.allocPrint(self.aa(), "data segment: offset={d} len={d}", .{ offset, len }));

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
            // No runtime bounds check: data segments are translator-time
            // known, and `translate()` has already rejected the module if
            // any segment extends past `max_pages` (outer array size).
            // Routing this through `emitOuterGetChecked` would be dead
            // code at runtime.
            if (last_page == null or last_page.? != page) {
                const page_name = try std.fmt.allocPrint(self.aa(), "__ds_page_{d}_{d}", .{ seg_id, page });
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
            const widx_name = try std.fmt.allocPrint(self.aa(), "__ds_widx_{d}_{d}", .{ seg_id, op_idx });
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
                const val_name = try std.fmt.allocPrint(self.aa(), "__ds_word_{d}_{d}", .{ seg_id, op_idx });
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

                const inv_name = try std.fmt.allocPrint(self.aa(), "__ds_invm_{d}_{d}", .{ seg_id, op_idx });
                const or_name = try std.fmt.allocPrint(self.aa(), "__ds_orbyte_{d}_{d}", .{ seg_id, op_idx });
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
            .stack_types = .empty,
        };
        defer ctx.blocks.deinit(self.gpa);
        defer ctx.stack_types.deinit(self.gpa);

        // Recursion spill is caller-saved (see `emitCall` / `emitCallIndirect`),
        // not callee-saved. A callee-saved prologue would snapshot the
        // post-arg-write state (P / RA already set to the callee's inputs),
        // so an epilogue restore would only revert to "the caller-set inner
        // args" — which never matches the outer call's pre-call frame.
        // Wrapping each nested call site on the caller side avoids that.

        try self.emitInstrs(&ctx, code.body);

        // Natural fall-through return: copy Sd-result_arity .. Sd-1 into R0..
        // (Only if any results are declared.)
        try self.emitFunctionReturn(&ctx);
        try self.asm_.label(exit);
        // Emit the indirect jump back. All defined functions use JUMP_INDIRECT
        // on their own RA slot (per §4).
        const ra = try names.returnAddrSlot(self.aa(), fn_name);
        try self.asm_.jumpIndirect(ra);

        self.fn_max_stack_depth[def_idx] = ctx.max_emitted_depth;
    }

    /// Collect caller's P / L / RA slots (in that order). Excludes R: the
    /// return-value slot is output-only from the caller's perspective, and
    /// must not be clobbered by a restore after the call — the callee has
    /// just written its fresh return value there. Excludes S: WASM value
    /// stack is per-function but its live-across-call content is not
    /// saved here (fib-style recursion keeps nothing live across the call;
    /// functions that need S preserved would need per-call-site live-depth
    /// analysis).
    fn collectFrameSlots(
        self: *Translator,
        ctx: *FuncCtx,
        slots: *std.ArrayList([]const u8),
    ) Error!void {
        const fn_name = ctx.fn_name;
        for (ctx.params, 0..) |_, i|
            try slots.append(self.gpa, try names.param(self.aa(), fn_name, @intCast(i)));
        var li: u32 = 0;
        for (ctx.locals) |lg| {
            for (0..lg.count) |_| {
                try slots.append(self.gpa, try names.local(self.aa(), fn_name, li));
                li += 1;
            }
        }
        try slots.append(self.gpa, try names.returnAddrSlot(self.aa(), fn_name));
    }

    /// Caller-side spill (see `spec_call_return_conversion.md` §8.2). Push
    /// the caller's P / L / RA onto `__call_stack__` right before a call
    /// site overwrites the (possibly aliased) callee P / RA slots.
    fn emitCallerSaveFrame(self: *Translator, ctx: *FuncCtx) Error!void {
        try self.asm_.comment("recursion: caller-save frame");
        var slots: std.ArrayList([]const u8) = .empty;
        defer slots.deinit(self.gpa);
        try self.collectFrameSlots(ctx, &slots);

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

    /// Caller-side restore. Pop in reverse order so the frame comes back
    /// exactly as it was at the save point, regardless of how deeply the
    /// callee (transitively) re-entered this function.
    fn emitCallerRestoreFrame(self: *Translator, ctx: *FuncCtx) Error!void {
        try self.asm_.comment("recursion: caller-restore frame");
        var slots: std.ArrayList([]const u8) = .empty;
        defer slots.deinit(self.gpa);
        try self.collectFrameSlots(ctx, &slots);

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
        for (ctx.results, 0..) |vt, i| {
            const src_depth = ctx.depth - @as(u32, @intCast(ctx.results.len)) + @as(u32, @intCast(i));
            const src = try names.stackSlot(self.aa(), ctx.fn_name, src_depth, vt);
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
        /// Current abstract WASM value-stack depth. Invariant:
        /// `depth == stack_types.items.len`.
        depth: u32,
        /// Maximum depth reached (for slot allocation check).
        max_emitted_depth: u32,
        /// Block label stack (innermost last).
        blocks: std.ArrayList(BlockCtx),
        /// Type of the WASM value currently occupying each stack depth.
        /// Pushed/popped in lockstep with `depth` so `typeAt(d)` returns
        /// the exact WASM type at depth `d` — which determines which
        /// `__{fn}_S{d}_{vt}__` physical slot holds the value.
        stack_types: std.ArrayList(ValType),

        fn push(self: *FuncCtx, vt: ValType) Error!void {
            try self.stack_types.append(self.t.gpa, vt);
            self.depth += 1;
            if (self.depth > self.max_emitted_depth) self.max_emitted_depth = self.depth;
            try self.t.recordSlotType(self.fn_idx, self.depth - 1, vt);
        }
        fn pop(self: *FuncCtx) void {
            if (self.depth > 0) {
                _ = self.stack_types.pop();
                self.depth -= 1;
            }
        }
        fn typeAt(self: *const FuncCtx, d: u32) ValType {
            return self.stack_types.items[d];
        }
        fn slotAt(self: *FuncCtx, alloc: std.mem.Allocator, d: u32) Error![]u8 {
            return names.stackSlot(alloc, self.fn_name, d, self.typeAt(d));
        }
        /// Drop the top of the stack down to `new_depth`. Used at `if/else`
        /// re-entry where the type stack must rewind to the block entry
        /// state to start the alternative branch.
        fn truncateStackTo(self: *FuncCtx, new_depth: u32) void {
            while (self.stack_types.items.len > new_depth) _ = self.stack_types.pop();
            self.depth = new_depth;
        }
    };

    /// Record that `vt` occupied stack slot `depth` of the defined
    /// function at `fn_idx`. Builds the per-function bitmask consulted
    /// by `emitFunctionStackSlots` to declare exactly the typed slots
    /// that the generated code reads/writes — no more, no less.
    fn recordSlotType(self: *Translator, fn_idx: u32, depth: u32, vt: ValType) Error!void {
        if (fn_idx < self.num_imported_funcs) return;
        const def_idx = fn_idx - self.num_imported_funcs;
        var bits = &self.fn_slot_type_bits[def_idx];
        while (bits.items.len <= depth) try bits.append(self.gpa, 0);
        bits.items[depth] |= slotTypeBit(vt);
    }

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
        // i32.rem_u has no SystemUInt32.__op_Modulus__ node in Udon either;
        // mirror the i64.rem_u expansion. Without this the resulting program
        // is silently rejected at UdonBehaviour load time (no exception
        // message — the only log line is "VM execution errored, halted").
        // Encountered in the wild from `(x as u32) % N` patterns inside Rust
        // `alloc` users (e.g. `examples/wasm-bench-alloc-rs`).
        if (ins == .i32_rem_u) {
            try self.emitI32RemU(ctx);
            return;
        }
        // i64.rem_s also has no Udon node (neither Modulus nor Remainder
        // is exposed for SystemInt64). Synthesize as a - (a/b)*b using the
        // existing SystemInt64 Division/Multiplication/Subtraction nodes.
        if (ins == .i64_rem_s) {
            try self.emitI64RemS(ctx);
            return;
        }
        if (ins == .i32_eqz) {
            try self.emitI32Eqz(ctx);
            return;
        }
        // `i32.wrap_i64` must use bit truncation, not SystemConvert.ToInt32
        // (which is a checked conversion that throws for values outside
        // Int32 range). Observed in the wild during an `i64.store` of an
        // adjacent-field combined value where the high word had a set bit
        // above Int32.MaxValue.
        if (ins == .i32_wrap_i64) {
            try self.emitI32WrapI64(ctx);
            return;
        }
        // Post-MVP sign-extension opcodes (0xC0..0xC4) lower as
        // `(x << N) >> N` — a synthesised two-EXTERN sequence, not a
        // single-EXTERN op, so they bypass the numeric.lookup table on
        // purpose. See `emitSignExtend` and
        // docs/spec_numeric_instruction_lowering.md §4.
        switch (ins) {
            .i32_extend8_s => {
                try self.emitSignExtend(ctx, .i32, 24);
                return;
            },
            .i32_extend16_s => {
                try self.emitSignExtend(ctx, .i32, 16);
                return;
            },
            .i64_extend8_s => {
                try self.emitSignExtend(ctx, .i64, 56);
                return;
            },
            .i64_extend16_s => {
                try self.emitSignExtend(ctx, .i64, 48);
                return;
            },
            .i64_extend32_s => {
                try self.emitSignExtend(ctx, .i64, 32);
                return;
            },
            // Post-MVP nontrapping-fptoint (saturating truncation).
            // See docs/spec_numeric_instruction_lowering.md §5.
            .i32_trunc_sat_f32_s => {
                try self.emitTruncSat(ctx, .f32, .i32, .signed);
                return;
            },
            .i32_trunc_sat_f32_u => {
                try self.emitTruncSat(ctx, .f32, .i32, .unsigned);
                return;
            },
            .i32_trunc_sat_f64_s => {
                try self.emitTruncSat(ctx, .f64, .i32, .signed);
                return;
            },
            .i32_trunc_sat_f64_u => {
                try self.emitTruncSat(ctx, .f64, .i32, .unsigned);
                return;
            },
            .i64_trunc_sat_f32_s => {
                try self.emitTruncSat(ctx, .f32, .i64, .signed);
                return;
            },
            .i64_trunc_sat_f32_u => {
                try self.emitTruncSat(ctx, .f32, .i64, .unsigned);
                return;
            },
            .i64_trunc_sat_f64_s => {
                try self.emitTruncSat(ctx, .f64, .i64, .signed);
                return;
            },
            .i64_trunc_sat_f64_u => {
                try self.emitTruncSat(ctx, .f64, .i64, .unsigned);
                return;
            },
            else => {},
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
            .select => try self.emitSelect(ctx),
            .return_ => {
                try self.emitFunctionReturn(ctx);
                try self.asm_.jump(ctx.exit_label);
            },
            .i32_const => |v| try self.emitConst(ctx, .{ .int32 = v }, tn.int32, .i32),
            .i64_const => |v| try self.emitI64Const(ctx, v),
            .f32_const => |v| try self.emitConst(ctx, .{ .single = v }, tn.single, .f32),
            .f64_const => |v| try self.emitF64Const(ctx, v),

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
            .memory_copy => try self.emitMemoryCopy(ctx),
            .memory_fill => |args| try self.emitMemoryFill(ctx, args),
            .i32_load => try self.emitMemLoadWord(ctx, ins),
            .i32_store => try self.emitMemStoreWord(ctx, ins),
            .f32_load => try self.emitMemLoadF32(ctx, ins),
            .f32_store => try self.emitMemStoreF32(ctx, ins),
            .i32_load8_u, .i32_load8_s => try self.emitMemLoadByte(ctx, ins),
            .i32_load16_u, .i32_load16_s => try self.emitMemLoad16(ctx, ins),
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
        //
        // Udon's heap typing rejects Int32/Int64 slots pushed into UInt32/
        // UInt64 EXTERN arguments, so when `operand_ty` is unsigned we route
        // each operand through a BitConverter-backed scratch of the matching
        // type. The result lands in a matching-type scratch and is converted
        // back to the Int32/Int64 stack slot that owns the output.
        //
        // Boolean-returning comparisons (`op_Equality`, `op_LessThan`, etc.)
        // likewise cannot use an Int32 stack slot as the EXTERN destination:
        // Udon rejects such a call with "Cannot retrieve heap variable of
        // type 'Boolean' as type 'Int32'". The result must land in a
        // SystemBoolean heap variable (`_cmp_bool`) and then be widened to
        // Int32 (0 or 1) before it lives on the WASM-visible Int32 stack.
        const is_u32 = std.meta.eql(entry.operand_ty, tn.uint32);
        const is_u64 = std.meta.eql(entry.operand_ty, tn.uint64);
        const is_bool_result = std.meta.eql(entry.result_ty, tn.boolean);
        // Shift-style ops have `_SystemInt32__<ResultTy>` at the tail of the
        // signature: the second operand is an Int32 count, not a UInt. Keep
        // it untouched so the emitted code matches the EXTERN signature.
        const shift_rhs_is_i32 = std.mem.indexOf(u8, entry.sig, "_SystemInt32__System") != null;

        switch (entry.arity) {
            .binary => {
                // Pop rhs, pop lhs, then push the result's WASM value type so
                // `dst` is named against the post-op state. Boolean-returning
                // comparisons over non-i32 operands (e.g. `i64.eq`, `f64.lt`)
                // used to leave `ctx.stack_types` holding the lhs's type — a
                // later i32 op at the same depth then emitted an `_i64__`-
                // named SystemInt64 slot where WASM actually held the i32
                // boolean result, cascading into an "Int32 as UInt32" crash
                // at the next unsigned EXTERN. Re-deriving `dst` after the
                // post-op push keeps the slot name in sync with the type.
                const rhs_depth = ctx.depth - 1;
                const lhs_depth = ctx.depth - 2;
                const rhs = try ctx.slotAt(self.aa(), rhs_depth);
                const lhs = try ctx.slotAt(self.aa(), lhs_depth);
                const lhs_vt = ctx.typeAt(lhs_depth);

                const result_vt: ValType = if (is_bool_result) .i32 else switch (entry.result_ty.prim) {
                    .int32, .uint32 => .i32,
                    .int64, .uint64 => .i64,
                    .single => .f32,
                    .double => .f64,
                    else => unreachable,
                };

                ctx.pop(); // rhs
                ctx.pop(); // lhs
                try ctx.push(result_vt);
                const dst = if (result_vt == lhs_vt) lhs else try ctx.slotAt(self.aa(), lhs_depth);

                if (is_u32) {
                    try self.emitI32ToU32(lhs, "_num_lhs_u32");
                    const rhs_slot = if (shift_rhs_is_i32) rhs else blk: {
                        try self.emitI32ToU32(rhs, "_num_rhs_u32");
                        break :blk "_num_rhs_u32";
                    };
                    try self.asm_.push("_num_lhs_u32");
                    try self.asm_.push(rhs_slot);
                    if (std.meta.eql(entry.result_ty, tn.uint32)) {
                        try self.asm_.push("_num_res_u32");
                        try self.asm_.extern_(entry.sig);
                        try self.emitU32ToI32("_num_res_u32", dst);
                    } else if (is_bool_result) {
                        try self.asm_.push("_cmp_bool");
                        try self.asm_.extern_(entry.sig);
                        try self.emitBoolToI32(dst);
                    } else {
                        try self.asm_.push(dst);
                        try self.asm_.extern_(entry.sig);
                    }
                } else if (is_u64) {
                    try self.emitI64ToU64(lhs, "_num_lhs_u64");
                    const rhs_slot = if (shift_rhs_is_i32) blk: {
                        // WASM i64.shr_u provides an i64 shift count, but the
                        // Udon EXTERN's second operand is Int32. Narrow through
                        // the shared scratch.
                        try self.emitI64ToI32(rhs, "_shift_rhs_i32");
                        break :blk "_shift_rhs_i32";
                    } else blk: {
                        try self.emitI64ToU64(rhs, "_num_rhs_u64");
                        break :blk "_num_rhs_u64";
                    };
                    try self.asm_.push("_num_lhs_u64");
                    try self.asm_.push(rhs_slot);
                    if (std.meta.eql(entry.result_ty, tn.uint64)) {
                        try self.asm_.push("_num_res_u64");
                        try self.asm_.extern_(entry.sig);
                        try self.emitU64ToI64("_num_res_u64", dst);
                    } else if (is_bool_result) {
                        try self.asm_.push("_cmp_bool");
                        try self.asm_.extern_(entry.sig);
                        try self.emitBoolToI32(dst);
                    } else {
                        try self.asm_.push(dst);
                        try self.asm_.extern_(entry.sig);
                    }
                } else if (is_bool_result) {
                    // Signed-int / float comparison producing Boolean.
                    try self.asm_.push(lhs);
                    try self.asm_.push(rhs);
                    try self.asm_.push("_cmp_bool");
                    try self.asm_.extern_(entry.sig);
                    try self.emitBoolToI32(dst);
                } else {
                    // Signed / float arithmetic — operands already have the
                    // right type on the Int32/Int64/Double stack slot, except
                    // for i64 signed shifts whose EXTERN takes an Int32 count.
                    const is_i64_operand = std.meta.eql(entry.operand_ty, tn.int64);
                    const rhs_slot = if (shift_rhs_is_i32 and is_i64_operand) blk: {
                        try self.emitI64ToI32(rhs, "_shift_rhs_i32");
                        break :blk "_shift_rhs_i32";
                    } else rhs;
                    try self.asm_.push(lhs);
                    try self.asm_.push(rhs_slot);
                    try self.asm_.push(dst);
                    try self.asm_.extern_(entry.sig);
                }
            },
            .unary => {
                // A unary numeric op pops one operand and pushes one
                // result; net depth is unchanged but the WASM value type
                // at the top of the stack can change (e.g. `i64.extend_i32_u`
                // goes i32 → i64). The source and destination stack slots
                // therefore differ whenever the WASM result value type
                // differs from the source, and we must keep `ctx.stack_types`
                // in sync so later ops see the correct type.
                //
                // Same three shapes as the binary branch:
                //   * unsigned operand → route through `_num_lhs_uN` scratch
                //     (Udon rejects an Int32 slot used as a UInt32 param).
                //   * unsigned result  → land in `_num_res_uN` then convert
                //     the bit pattern back into the Int32/Int64 stack slot.
                //   * otherwise        → push operand, push dst, extern.
                //
                // Prior to this fix the branch reused the source slot for
                // both input and output, which miscompiled every type-
                // changing conversion: the emitted code named a slot like
                // `__fn_S1_i32__` for both args of `ToInt64(UInt32)`, but
                // by the time the sequence executed the same stack position
                // actually held the i64 result of an earlier conversion,
                // producing "Cannot retrieve heap variable of type 'Int32'
                // as type 'UInt32'" at runtime. Reproduced by the f64
                // formatter path under `test_64bit_and_float`.
                const d = ctx.depth - 1;
                const src_vt = ctx.typeAt(d);
                const src = try ctx.slotAt(self.aa(), d);

                const in_slot: []const u8 = if (std.meta.eql(entry.operand_ty, tn.uint32)) blk: {
                    try self.emitI32ToU32(src, "_num_lhs_u32");
                    break :blk "_num_lhs_u32";
                } else if (std.meta.eql(entry.operand_ty, tn.uint64)) blk: {
                    try self.emitI64ToU64(src, "_num_lhs_u64");
                    break :blk "_num_lhs_u64";
                } else src;

                const result_vt: ValType = switch (entry.result_ty.prim) {
                    .int32, .uint32 => .i32,
                    .int64, .uint64 => .i64,
                    .single => .f32,
                    .double => .f64,
                    else => unreachable,
                };
                if (src_vt != result_vt) {
                    ctx.pop();
                    try ctx.push(result_vt);
                }
                const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);

                if (std.meta.eql(entry.result_ty, tn.uint32)) {
                    try self.asm_.push(in_slot);
                    try self.asm_.push("_num_res_u32");
                    try self.asm_.extern_(entry.sig);
                    try self.emitU32ToI32("_num_res_u32", dst);
                } else if (std.meta.eql(entry.result_ty, tn.uint64)) {
                    try self.asm_.push(in_slot);
                    try self.asm_.push("_num_res_u64");
                    try self.asm_.extern_(entry.sig);
                    try self.emitU64ToI64("_num_res_u64", dst);
                } else {
                    try self.asm_.push(in_slot);
                    try self.asm_.push(dst);
                    try self.asm_.extern_(entry.sig);
                }
            },
        }
    }

    /// Expand `i32.eqz` as `x == 0` over the existing static binary EXTERN
    /// `SystemInt32.__op_Equality__`. The naive lowering via instance-method
    /// `Int32.Equals(Int32)` would require a 3-slot push convention that the
    /// .unary emit path in `emitNumericOp` does not satisfy; that mismatch
    /// was the cause of the PC 43048 `ArgumentOutOfRangeException` at Udon
    /// runtime.
    ///
    /// The return slot must be `_cmp_bool` (SystemBoolean), not the Int32
    /// stack slot — Udon type-checks EXTERN destination slots against the
    /// signature and rejects an Int32 slot for a Boolean-returning op with
    /// "Cannot retrieve heap variable of type 'Boolean' as type 'Int32'".
    /// After the comparison we widen Boolean → Int32 back into the stack
    /// slot so subsequent WASM code sees the expected i32 (0 or 1).
    fn emitI32Eqz(self: *Translator, ctx: *FuncCtx) Error!void {
        const s = try ctx.slotAt(self.aa(), ctx.depth - 1);
        try self.asm_.push(s);
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_cmp_bool");
        try self.asm_.extern_("SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean");
        try self.emitBoolToI32(s);
    }

    /// WASM `i32.wrap_i64` — take the low 32 bits of an i64 value, no range
    /// check. Must use BitConverter to preserve the bit pattern: naive
    /// `SystemConvert.ToInt32(Int64)` is a *checked* conversion that throws
    /// `OverflowException` whenever the i64 value is outside
    /// `[Int32.MinValue, Int32.MaxValue]`, which breaks legitimate WASM code
    /// that stores arbitrary i64 values (e.g. LLVM combining adjacent i32
    /// fields into a single i64 store before wrapping back down).
    fn emitI32WrapI64(self: *Translator, ctx: *FuncCtx) Error!void {
        const src_i64 = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        try ctx.push(.i32);
        const dst_i32 = try ctx.slotAt(self.aa(), ctx.depth - 1);
        try self.asm_.comment("i32.wrap_i64 (bit truncation via BitConverter)");
        try self.emitI64TruncI32(src_i64, dst_i32);
    }

    /// Post-MVP sign-extension opcodes (`i32.extend8_s`, `i32.extend16_s`,
    /// `i64.extend8_s`, `i64.extend16_s`, `i64.extend32_s`) all lower as
    /// `(x << N) >> N` over the existing `__op_LeftShift__` /
    /// `__op_RightShift__` EXTERNs on SystemInt32 / SystemInt64. The shift
    /// count `N` is materialised through the shared `__c_i32_<N>` data
    /// field — both the i32 and i64 shift EXTERNs take SystemInt32 for
    /// the RHS (see lower_numeric.zig lines 85–86 area), so a single
    /// Int32 constant suffices for every variant.
    ///
    /// Modeled as a unary op on the WASM stack: pops one operand, pushes
    /// one result of the same value type. The destination slot reuses the
    /// source slot (same WASM type ⇒ same stack name); the two EXTERNs
    /// chain through it directly.
    ///
    /// This is intentionally NOT a `lower_numeric.zig` table entry: that
    /// table is for single-EXTERN ops, and the sign-extension is a
    /// synthesised two-EXTERN sequence. Mirrors the post-load tail of
    /// `i32.load8_s` / `i32.load16_s` (see `emitMemLoadByte` /
    /// `emitMemLoad16`).
    fn emitSignExtend(
        self: *Translator,
        ctx: *FuncCtx,
        comptime vt: enum { i32, i64 },
        comptime shift: u8,
    ) Error!void {
        const slot = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const ls_sig = switch (vt) {
            .i32 => "SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32",
            .i64 => "SystemInt64.__op_LeftShift__SystemInt64_SystemInt32__SystemInt64",
        };
        const rs_sig = switch (vt) {
            .i32 => "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32",
            .i64 => "SystemInt64.__op_RightShift__SystemInt64_SystemInt32__SystemInt64",
        };
        const tag = switch (vt) {
            .i32 => switch (shift) {
                24 => "i32.extend8_s",
                16 => "i32.extend16_s",
                else => @compileError("unsupported i32 sign-extend shift count"),
            },
            .i64 => switch (shift) {
                56 => "i64.extend8_s",
                48 => "i64.extend16_s",
                32 => "i64.extend32_s",
                else => @compileError("unsupported i64 sign-extend shift count"),
            },
        };
        const count_const = std.fmt.comptimePrint("__c_i32_{d}", .{shift});

        try self.asm_.comment(tag ++ " ((x << N) >> N)");
        // slot := slot << N
        try self.asm_.push(slot);
        try self.asm_.push(count_const);
        try self.asm_.push(slot);
        try self.asm_.extern_(ls_sig);
        // slot := slot >> N (arithmetic — SystemInt{32,64} is signed)
        try self.asm_.push(slot);
        try self.asm_.push(count_const);
        try self.asm_.push(slot);
        try self.asm_.extern_(rs_sig);
        // Net WASM-stack effect: pop one + push one of the same type, so
        // ctx.depth and the slot's recorded value type are unchanged.
    }

    /// Lower a non-trapping saturating-truncation opcode (§5 of
    /// `docs/spec_numeric_instruction_lowering.md`). Each call site
    ///   1. (if input is f32) promotes to f64 in `_ts_in_f64`,
    ///   2. stages the low/high f64 clamps and the low/high integer
    ///      result constants into the helper-shared slots,
    ///   3. installs a unique return-address constant into
    ///      `__ret_addr_trunc_sat_<i32|i64>__` and JUMPs into the
    ///      shared helper subroutine,
    ///   4. picks up the saturated result from `_ts_out_<i32|i64>` after
    ///      the helper's `JUMP_INDIRECT` returns.
    ///
    /// The helper body itself is emitted once per output bit-width by
    /// `emitTruncSatHelpers`, gated by `trunc_sat_helper_needed_*`.
    fn emitTruncSat(
        self: *Translator,
        ctx: *FuncCtx,
        comptime in_vt: enum { f32, f64 },
        comptime out_vt: enum { i32, i64 },
        comptime signedness: enum { signed, unsigned },
    ) Error!void {
        try self.ensureTruncSatData();

        const in_slot = try ctx.slotAt(self.aa(), ctx.depth - 1);

        // Step 1: promote f32 → f64 if needed; result lands in `_ts_in_f64`.
        switch (in_vt) {
            .f32 => {
                try self.asm_.comment("trunc_sat: promote f32 input to f64 (_ts_in_f64)");
                try self.asm_.push(in_slot);
                try self.asm_.push("_ts_in_f64");
                try self.asm_.extern_("SystemConvert.__ToDouble__SystemSingle__SystemDouble");
            },
            .f64 => {
                try self.asm_.comment("trunc_sat: stage f64 input in _ts_in_f64");
                try self.asm_.push(in_slot);
                try self.asm_.push("_ts_in_f64");
                try self.asm_.copy();
            },
        }

        // Pick clamp constants per (out_vt, signedness).
        const lo_clamp_const: []const u8 = switch (out_vt) {
            .i32 => switch (signedness) {
                .signed => "__c_f64_int32_min",
                .unsigned => "__c_f64_zero",
            },
            .i64 => switch (signedness) {
                .signed => "__c_f64_int64_min",
                .unsigned => "__c_f64_zero",
            },
        };
        const hi_clamp_const: []const u8 = switch (out_vt) {
            .i32 => switch (signedness) {
                .signed => "__c_f64_int32_max",
                .unsigned => "__c_f64_uint32_max",
            },
            .i64 => switch (signedness) {
                .signed => "__c_f64_int64_max",
                .unsigned => "__c_f64_uint64_max",
            },
        };
        const lo_out_const: []const u8 = switch (out_vt) {
            .i32 => switch (signedness) {
                .signed => "__c_i32_int_min",
                .unsigned => "__c_i32_0", // 0 for unsigned
            },
            .i64 => switch (signedness) {
                .signed => "__c_i64_int_min",
                .unsigned => "__c_i64_zero",
            },
        };
        const hi_out_const: []const u8 = switch (out_vt) {
            .i32 => switch (signedness) {
                .signed => "__c_i32_int_max",
                .unsigned => "__c_i32_neg1", // UINT32_MAX as Int32 = -1
            },
            .i64 => switch (signedness) {
                .signed => "__c_i64_int_max",
                .unsigned => "__c_i64_neg1", // UINT64_MAX as Int64 = -1
            },
        };

        // Step 2: stage clamps. Each helper-shared scratch slot is
        // overwritten on every call site, so reuse is safe.
        try self.asm_.push(lo_clamp_const);
        try self.asm_.push("_ts_lo_f64");
        try self.asm_.copy();
        try self.asm_.push(hi_clamp_const);
        try self.asm_.push("_ts_hi_f64");
        try self.asm_.copy();
        switch (out_vt) {
            .i32 => {
                try self.asm_.push(lo_out_const);
                try self.asm_.push("_ts_lo_out_i32");
                try self.asm_.copy();
                try self.asm_.push(hi_out_const);
                try self.asm_.push("_ts_hi_out_i32");
                try self.asm_.copy();
            },
            .i64 => {
                try self.asm_.push(lo_out_const);
                try self.asm_.push("_ts_lo_out_i64");
                try self.asm_.copy();
                try self.asm_.push(hi_out_const);
                try self.asm_.push("_ts_hi_out_i64");
                try self.asm_.copy();
            },
        }

        // Step 3: install RAC + JUMP into the helper.
        const out_tag: []const u8 = switch (out_vt) {
            .i32 => "i32",
            .i64 => "i64",
        };
        const k = self.call_site_counter;
        self.call_site_counter += 1;
        const ret_label = try std.fmt.allocPrint(
            self.aa(),
            "__rt_trunc_sat_ret_{s}_{d}__",
            .{ out_tag, k },
        );
        const rac = try std.fmt.allocPrint(
            self.aa(),
            "__rt_trunc_sat_rac_{s}_{d}__",
            .{ out_tag, k },
        );
        try self.asm_.addData(.{ .name = rac, .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.rac_sites.append(self.gpa, .{ .const_name = rac, .target_label = ret_label });

        const ret_addr_slot: []const u8 = switch (out_vt) {
            .i32 => "__ret_addr_trunc_sat_i32__",
            .i64 => "__ret_addr_trunc_sat_i64__",
        };
        const helper_entry: []const u8 = switch (out_vt) {
            .i32 => "__rt_trunc_sat_to_i32__",
            .i64 => "__rt_trunc_sat_to_i64__",
        };

        try self.asm_.push(rac);
        try self.asm_.push(ret_addr_slot);
        try self.asm_.copy();
        try self.asm_.jump(helper_entry);
        try self.asm_.label(ret_label);

        // Mark the helper as needed so emitTruncSatHelpers materialises it.
        switch (out_vt) {
            .i32 => self.trunc_sat_helper_needed_i32 = true,
            .i64 => self.trunc_sat_helper_needed_i64 = true,
        }

        // Step 4: pop the (f32 or f64) input, push the (i32 or i64) result,
        // copy the saturated value into the new top-of-stack slot.
        ctx.pop();
        const result_vt: ValType = switch (out_vt) {
            .i32 => .i32,
            .i64 => .i64,
        };
        try ctx.push(result_vt);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const out_slot: []const u8 = switch (out_vt) {
            .i32 => "_ts_out_i32",
            .i64 => "_ts_out_i64",
        };
        try self.asm_.push(out_slot);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    /// Declare the trunc_sat scratch slots and register the f64 clamp
    /// constants into `f64_const_inits` so `_onEnable` synthesises them.
    /// Idempotent — runs at most once per translation unit, on the first
    /// call to `emitTruncSat`.
    fn ensureTruncSatData(self: *Translator) Error!void {
        if (self.trunc_sat_data_declared) return;
        self.trunc_sat_data_declared = true;

        // Helper-shared input / clamp / output scratch slots. Per-helper
        // slots match the names used by `emitTruncSat` and the helper
        // bodies in `emitTruncSatHelpers`.
        try self.asm_.addData(.{ .name = "_ts_in_f64", .ty = tn.double, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_ts_lo_f64", .ty = tn.double, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_ts_hi_f64", .ty = tn.double, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_ts_lo_out_i32", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_ts_hi_out_i32", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_ts_lo_out_i64", .ty = tn.int64, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_ts_hi_out_i64", .ty = tn.int64, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_ts_out_i32", .ty = tn.int32, .init = .{ .int32 = 0 } });
        try self.asm_.addData(.{ .name = "_ts_out_i64", .ty = tn.int64, .init = .null_literal });
        try self.asm_.addData(.{ .name = "_ts_cmp", .ty = tn.boolean, .init = .null_literal });

        // Return-address slots for the two helper subroutines.
        try self.asm_.addData(.{ .name = "__ret_addr_trunc_sat_i32__", .ty = tn.uint32, .init = .{ .uint32 = 0 } });
        try self.asm_.addData(.{ .name = "__ret_addr_trunc_sat_i64__", .ty = tn.uint32, .init = .{ .uint32 = 0 } });

        // Integer result constants. Some of these may already exist in
        // `emitMemoryData` (`__c_i32_0`, `__c_i32_neg1`); we only declare
        // the trunc_sat-specific ones here.
        try self.asm_.addData(.{ .name = "__c_i32_int_min", .ty = tn.int32, .init = .{ .int32 = std.math.minInt(i32) } });
        try self.asm_.addData(.{ .name = "__c_i32_int_max", .ty = tn.int32, .init = .{ .int32 = std.math.maxInt(i32) } });
        // Int64 constants must be initialised to null per Udon spec §4.7
        // and synthesised at `_onEnable`. Reuse the existing
        // `i64_const_inits` machinery via `registerNamedI64Const`.
        try self.registerNamedI64Const("__c_i64_zero", 0);
        try self.registerNamedI64Const("__c_i64_neg1", -1);
        try self.registerNamedI64Const("__c_i64_int_min", std.math.minInt(i64));
        try self.registerNamedI64Const("__c_i64_int_max", std.math.maxInt(i64));

        // f64 clamp constants. Register through the same hi/lo init
        // machinery used by `emitF64Const` so `_onEnable` synthesises
        // them via BitConverter (Udon spec §4.7 forbids non-null Double
        // literals).
        try self.registerNamedF64Const("__c_f64_zero", 0.0);
        try self.registerNamedF64Const("__c_f64_int32_min", -2147483648.0);
        try self.registerNamedF64Const("__c_f64_int32_max", 2147483648.0);
        try self.registerNamedF64Const("__c_f64_uint32_max", 4294967296.0);
        try self.registerNamedF64Const("__c_f64_int64_min", -9223372036854775808.0);
        try self.registerNamedF64Const("__c_f64_int64_max", 9223372036854775808.0);
        try self.registerNamedF64Const("__c_f64_uint64_max", 18446744073709551616.0);
    }

    /// Declare a SystemInt64 data slot named `name` with bit-pattern
    /// `value`, and register the synthesis triple into `i64_const_inits`
    /// so `_onEnable` initialises it. Mirrors `emitI64Const`'s heap
    /// machinery but with a caller-chosen stable name (rather than the
    /// auto-generated `__K64_<n>`), so callers can refer to the slot by
    /// a known identifier.
    fn registerNamedI64Const(self: *Translator, name: []const u8, value: i64) Error!void {
        const bits: u64 = @bitCast(value);
        const hi_name = try std.fmt.allocPrint(self.aa(), "{s}__hi", .{name});
        const lo_name = try std.fmt.allocPrint(self.aa(), "{s}__lo", .{name});
        const hi_bits: u32 = @truncate(bits >> 32);
        const lo_bits: u32 = @truncate(bits);
        try self.asm_.addData(.{ .name = name, .ty = tn.int64, .init = .null_literal });
        try self.asm_.addData(.{ .name = hi_name, .ty = tn.int32, .init = .{ .int32 = @bitCast(hi_bits) } });
        try self.asm_.addData(.{ .name = lo_name, .ty = tn.int32, .init = .{ .int32 = @bitCast(lo_bits) } });
        try self.i64_const_inits.append(self.gpa, .{
            .slot = name,
            .hi_slot = hi_name,
            .lo_slot = lo_name,
            .bits = bits,
        });
    }

    /// Declare a SystemDouble data slot named `name` with bit-pattern
    /// `value`, and register the synthesis triple into `f64_const_inits`.
    /// Mirrors `registerNamedI64Const` but for the Double terminal
    /// conversion in `emit64BitConstInits`.
    fn registerNamedF64Const(self: *Translator, name: []const u8, value: f64) Error!void {
        const bits: u64 = @bitCast(value);
        const hi_name = try std.fmt.allocPrint(self.aa(), "{s}__hi", .{name});
        const lo_name = try std.fmt.allocPrint(self.aa(), "{s}__lo", .{name});
        const hi_bits: u32 = @truncate(bits >> 32);
        const lo_bits: u32 = @truncate(bits);
        try self.asm_.addData(.{ .name = name, .ty = tn.double, .init = .null_literal });
        try self.asm_.addData(.{ .name = hi_name, .ty = tn.int32, .init = .{ .int32 = @bitCast(hi_bits) } });
        try self.asm_.addData(.{ .name = lo_name, .ty = tn.int32, .init = .{ .int32 = @bitCast(lo_bits) } });
        try self.f64_const_inits.append(self.gpa, .{
            .slot = name,
            .hi_slot = hi_name,
            .lo_slot = lo_name,
            .bits = bits,
        });
    }

    /// Emit the trunc_sat helper subroutines once per translation unit,
    /// gated on the `trunc_sat_helper_needed_*` flags set by
    /// `emitTruncSat` call sites. The helpers are reached via JUMP from
    /// every call site and return via `JUMP_INDIRECT` against
    /// `__ret_addr_trunc_sat_<i32|i64>__`. They are placed AFTER all
    /// defined functions — never reachable as fall-through.
    fn emitTruncSatHelpers(self: *Translator) Error!void {
        if (self.trunc_sat_helper_needed_i32) {
            try self.emitTruncSatHelperBody(.i32);
        }
        if (self.trunc_sat_helper_needed_i64) {
            try self.emitTruncSatHelperBody(.i64);
        }
    }

    fn emitTruncSatHelperBody(self: *Translator, comptime out_vt: enum { i32, i64 }) Error!void {
        const entry_label: []const u8 = switch (out_vt) {
            .i32 => "__rt_trunc_sat_to_i32__",
            .i64 => "__rt_trunc_sat_to_i64__",
        };
        const done_label: []const u8 = switch (out_vt) {
            .i32 => "__rt_trunc_sat_done_i32__",
            .i64 => "__rt_trunc_sat_done_i64__",
        };
        const lo_branch_label: []const u8 = switch (out_vt) {
            .i32 => "__rt_trunc_sat_lo_i32__",
            .i64 => "__rt_trunc_sat_lo_i64__",
        };
        const hi_branch_label: []const u8 = switch (out_vt) {
            .i32 => "__rt_trunc_sat_hi_i32__",
            .i64 => "__rt_trunc_sat_hi_i64__",
        };
        const not_lo_label: []const u8 = switch (out_vt) {
            .i32 => "__rt_trunc_sat_not_lo_i32__",
            .i64 => "__rt_trunc_sat_not_lo_i64__",
        };
        const not_hi_label: []const u8 = switch (out_vt) {
            .i32 => "__rt_trunc_sat_not_hi_i32__",
            .i64 => "__rt_trunc_sat_not_hi_i64__",
        };
        const lo_out_slot: []const u8 = switch (out_vt) {
            .i32 => "_ts_lo_out_i32",
            .i64 => "_ts_lo_out_i64",
        };
        const hi_out_slot: []const u8 = switch (out_vt) {
            .i32 => "_ts_hi_out_i32",
            .i64 => "_ts_hi_out_i64",
        };
        const out_slot: []const u8 = switch (out_vt) {
            .i32 => "_ts_out_i32",
            .i64 => "_ts_out_i64",
        };
        const zero_int_const: []const u8 = switch (out_vt) {
            .i32 => "__c_i32_0",
            .i64 => "__c_i64_zero",
        };
        const ret_addr_slot: []const u8 = switch (out_vt) {
            .i32 => "__ret_addr_trunc_sat_i32__",
            .i64 => "__ret_addr_trunc_sat_i64__",
        };
        const convert_sig: []const u8 = switch (out_vt) {
            .i32 => "SystemConvert.__ToInt32__SystemDouble__SystemInt32",
            .i64 => "SystemConvert.__ToInt64__SystemDouble__SystemInt64",
        };

        try self.asm_.comment("trunc_sat helper: NaN→0, x≤lo→lo_out, x≥hi→hi_out, else SystemConvert");
        try self.asm_.label(entry_label);

        // Step 1: NaN guard (x != x). SystemDouble.__op_Inequality__.
        try self.asm_.push("_ts_in_f64");
        try self.asm_.push("_ts_in_f64");
        try self.asm_.push("_ts_cmp");
        try self.asm_.extern_("SystemDouble.__op_Inequality__SystemDouble_SystemDouble__SystemBoolean");
        // If NOT (x != x) — i.e. x is finite or non-NaN — skip to lo branch test.
        try self.asm_.push("_ts_cmp");
        try self.asm_.jumpIfFalse(not_lo_label);
        // x is NaN: write 0 to out and JUMP done.
        try self.asm_.push(zero_int_const);
        try self.asm_.push(out_slot);
        try self.asm_.copy();
        try self.asm_.jump(done_label);

        // Step 2: low clamp — x <= lo.
        try self.asm_.label(not_lo_label);
        try self.asm_.push("_ts_in_f64");
        try self.asm_.push("_ts_lo_f64");
        try self.asm_.push("_ts_cmp");
        try self.asm_.extern_("SystemDouble.__op_LessThanOrEqual__SystemDouble_SystemDouble__SystemBoolean");
        try self.asm_.push("_ts_cmp");
        try self.asm_.jumpIfFalse(not_hi_label);
        try self.asm_.label(lo_branch_label);
        try self.asm_.push(lo_out_slot);
        try self.asm_.push(out_slot);
        try self.asm_.copy();
        try self.asm_.jump(done_label);

        // Step 3: high clamp — x >= hi.
        try self.asm_.label(not_hi_label);
        try self.asm_.push("_ts_in_f64");
        try self.asm_.push("_ts_hi_f64");
        try self.asm_.push("_ts_cmp");
        try self.asm_.extern_("SystemDouble.__op_GreaterThanOrEqual__SystemDouble_SystemDouble__SystemBoolean");
        try self.asm_.push("_ts_cmp");
        // Branch to the in-range conversion when NOT (x >= hi).
        const inrange_label: []const u8 = switch (out_vt) {
            .i32 => "__rt_trunc_sat_inrange_i32__",
            .i64 => "__rt_trunc_sat_inrange_i64__",
        };
        try self.asm_.jumpIfFalse(inrange_label);
        try self.asm_.label(hi_branch_label);
        try self.asm_.push(hi_out_slot);
        try self.asm_.push(out_slot);
        try self.asm_.copy();
        try self.asm_.jump(done_label);

        // Step 4: in-range — SystemConvert.ToInt{32,64}(SystemDouble).
        try self.asm_.label(inrange_label);
        try self.asm_.push("_ts_in_f64");
        try self.asm_.push(out_slot);
        try self.asm_.extern_(convert_sig);

        // Step 5: return to caller via the shared RAC slot.
        try self.asm_.label(done_label);
        try self.asm_.jumpIndirect(ret_addr_slot);
    }

    /// WASM `select` (0x1B): pops `(v1, v2, cond)` where `cond` is the top
    /// of stack (so the on-stack order, bottom→top, is `v1, v2, cond`) and
    /// pushes `cond ? v1 : v2`. `v1` and `v2` must have the same WASM
    /// value type (validator-enforced for the unannotated 1.0 form).
    ///
    /// Naive "pass-through of v1" lowering silently miscompiles every
    /// runtime path that expected `v2` — observed in the wild as a
    /// `page == max_pages` OOB trap inside Zig's compiler-synthesized
    /// `memcpy` helper, because stdlib pointer-select patterns like
    /// `dst = cond ? near_ptr : far_ptr` ended up always using `v1`.
    ///
    /// Strategy: leave `v1` in its slot when `cond != 0`, else COPY `v2`
    /// into `v1`'s slot. Both `v1` and `v2` already live at typed stack
    /// slots `__{fn}_S{depth-3}_{vt}__` / `__{fn}_S{depth-2}_{vt}__`; the
    /// post-op result slot is the `v1` slot, so no new scratch is needed.
    fn emitSelect(self: *Translator, ctx: *FuncCtx) Error!void {
        // WASM validation guarantees v1_type == v2_type; assert on the
        // cheap side to catch malformed modules early.
        const v1_type = ctx.typeAt(ctx.depth - 3);
        const cond_slot = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const v2_slot = try ctx.slotAt(self.aa(), ctx.depth - 2);
        const v1_slot = try ctx.slotAt(self.aa(), ctx.depth - 3);

        const id = self.block_counter;
        self.block_counter += 1;
        const falsy_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_sel_falsy_{d}__", .{ ctx.fn_name, id });
        const merge_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_sel_merge_{d}__", .{ ctx.fn_name, id });

        try self.asm_.comment("select: result = cond ? v1 : v2");
        // _cmp_bool := cond != 0. JUMP_IF_FALSE goes to the v2-copy path.
        try self.emitI32ToBool(cond_slot);
        try self.asm_.push("_cmp_bool");
        try self.asm_.jumpIfFalse(falsy_lbl);
        // Truthy: result = v1, already in v1_slot. Jump past the v2 copy.
        try self.asm_.jump(merge_lbl);
        try self.asm_.label(falsy_lbl);
        // Falsy: COPY v2 over v1's slot so the post-op top-of-stack name
        // (still the v1 slot) carries v2's value.
        try self.asm_.push(v2_slot);
        try self.asm_.push(v1_slot);
        try self.asm_.copy();
        try self.asm_.label(merge_lbl);

        ctx.pop(); // cond
        ctx.pop(); // v2
        // v1 stays at `depth - 1` (now the top of stack) and already has
        // the correct recorded type.
        _ = v1_type;
    }

    /// Widen the Boolean currently in `_cmp_bool` to an Int32 (0 or 1) and
    /// store it into `i32_slot`. Used after every Boolean-returning
    /// comparison EXTERN so the WASM-visible stack slot carries an Int32
    /// value, matching the `i32.eq`/`i32.lt`/etc. result type.
    fn emitBoolToI32(self: *Translator, i32_slot: []const u8) Error!void {
        try self.asm_.push("_cmp_bool");
        try self.asm_.push(i32_slot);
        try self.asm_.extern_("SystemConvert.__ToInt32__SystemBoolean__SystemInt32");
    }

    /// Narrow an Int32 stack slot (WASM-visible 0/1 or arbitrary non-zero)
    /// to a SystemBoolean in `_cmp_bool`. Needed ahead of every JUMP_IF_FALSE
    /// that pops a WASM condition: Udon's JUMP_IF_FALSE requires the
    /// operand on the VM stack to be typed SystemBoolean, whereas the WASM
    /// `if` / `br_if` condition is an i32.
    fn emitI32ToBool(self: *Translator, i32_slot: []const u8) Error!void {
        try self.asm_.push(i32_slot);
        try self.asm_.push("_cmp_bool");
        try self.asm_.extern_("SystemConvert.__ToBoolean__SystemInt32__SystemBoolean");
    }

    /// Narrow an Int64 stack slot to an Int32 via bit truncation. Used for
    /// i64 shift counts — WASM's `i64.shl` / `i64.shr_*` push an i64 count,
    /// but the Udon `__op_LeftShift` / `__op_RightShift` EXTERNs on
    /// 64-bit types take Int32.
    ///
    /// Shift counts are semantically always in `[0, 63]` so `SystemConvert.
    /// ToInt32(Int64)` *would* work, but using the checked conversion is a
    /// foot-gun: any future caller passing an out-of-range value would hit
    /// the same OverflowException that broke `i64.store` / `i32.wrap_i64`.
    /// Use bit truncation (via `emitI64TruncI32`) for consistency and
    /// defense-in-depth.
    fn emitI64ToI32(self: *Translator, i64_slot: []const u8, out_i32_slot: []const u8) Error!void {
        try self.emitI64TruncI32(i64_slot, out_i32_slot);
    }

    /// Expand `i32.rem_u` as `a - (a / b) * b`. Mirror of `emitI64RemU`.
    /// Udon's node list has no `SystemUInt32.__op_Modulus__` but provides
    /// Division/Multiplication/Subtraction in UInt32. Emitting the missing
    /// Modulus node makes UdonBehaviour silently halt at load time — no
    /// exception message, no `_onEnable`, no Start event — because Udon
    /// validates EXTERN signatures against its static node list and
    /// flips `_isReady` to false on a miss.
    fn emitI32RemU(self: *Translator, ctx: *FuncCtx) Error!void {
        try self.asm_.comment("i32.rem_u (synthesized: a - (a/b)*b)");
        const rhs = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const lhs = try ctx.slotAt(self.aa(), ctx.depth - 2);
        // Stack slots are typed Int32 — route through BitConverter so the
        // UInt32 EXTERNs below receive correctly-typed heap variables.
        try self.emitI32ToU32(lhs, "_num_lhs_u32");
        try self.emitI32ToU32(rhs, "_num_rhs_u32");
        // _rem_q_u32 := a / b
        try self.asm_.push("_num_lhs_u32");
        try self.asm_.push("_num_rhs_u32");
        try self.asm_.push("_rem_q_u32");
        try self.asm_.extern_("SystemUInt32.__op_Division__SystemUInt32_SystemUInt32__SystemUInt32");
        // _rem_qb_u32 := _rem_q_u32 * b
        try self.asm_.push("_rem_q_u32");
        try self.asm_.push("_num_rhs_u32");
        try self.asm_.push("_rem_qb_u32");
        try self.asm_.extern_("SystemUInt32.__op_Multiplication__SystemUInt32_SystemUInt32__SystemUInt32");
        // _num_res_u32 := a - _rem_qb_u32
        try self.asm_.push("_num_lhs_u32");
        try self.asm_.push("_rem_qb_u32");
        try self.asm_.push("_num_res_u32");
        try self.asm_.extern_("SystemUInt32.__op_Subtraction__SystemUInt32_SystemUInt32__SystemUInt32");
        // lhs (Int32 stack slot) := _num_res_u32
        try self.emitU32ToI32("_num_res_u32", lhs);
        ctx.pop(); // rhs consumed
    }

    /// Expand `i64.rem_s` as `a - (a / b) * b`. Udon ships neither
    /// `SystemInt64.__op_Modulus__` nor `SystemInt64.__op_Remainder__`
    /// (only SystemInt32 / SystemDecimal got the Remainder node). Stack
    /// slots are already typed Int64, so no BitConverter routing is needed
    /// — just three SystemInt64 EXTERN calls.
    fn emitI64RemS(self: *Translator, ctx: *FuncCtx) Error!void {
        try self.asm_.comment("i64.rem_s (synthesized: a - (a/b)*b)");
        const rhs = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const lhs = try ctx.slotAt(self.aa(), ctx.depth - 2);
        // _rem_q_i64 := a / b
        try self.asm_.push(lhs);
        try self.asm_.push(rhs);
        try self.asm_.push("_rem_q_i64");
        try self.asm_.extern_("SystemInt64.__op_Division__SystemInt64_SystemInt64__SystemInt64");
        // _rem_qb_i64 := _rem_q_i64 * b
        try self.asm_.push("_rem_q_i64");
        try self.asm_.push(rhs);
        try self.asm_.push("_rem_qb_i64");
        try self.asm_.extern_("SystemInt64.__op_Multiplication__SystemInt64_SystemInt64__SystemInt64");
        // lhs := a - _rem_qb_i64
        try self.asm_.push(lhs);
        try self.asm_.push("_rem_qb_i64");
        try self.asm_.push(lhs);
        try self.asm_.extern_("SystemInt64.__op_Subtraction__SystemInt64_SystemInt64__SystemInt64");
        ctx.pop(); // rhs consumed
    }

    /// Expand `i64.rem_u` as `a - (a / b) * b`. Udon's node list has no
    /// `SystemUInt64.__op_Modulus__` but provides Division/Multiplication/
    /// Subtraction in UInt64, so the 3-EXTERN sequence is the canonical form.
    fn emitI64RemU(self: *Translator, ctx: *FuncCtx) Error!void {
        try self.asm_.comment("i64.rem_u (synthesized: a - (a/b)*b)");
        const rhs = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const lhs = try ctx.slotAt(self.aa(), ctx.depth - 2);
        // Route the Int64 stack slots through BitConverter so the UInt64
        // EXTERN arguments below receive correctly-typed heap variables.
        try self.emitI64ToU64(lhs, "_num_lhs_u64");
        try self.emitI64ToU64(rhs, "_num_rhs_u64");
        // _rem_q_u64 := a / b
        try self.asm_.push("_num_lhs_u64");
        try self.asm_.push("_num_rhs_u64");
        try self.asm_.push("_rem_q_u64");
        try self.asm_.extern_("SystemUInt64.__op_Division__SystemUInt64_SystemUInt64__SystemUInt64");
        // _rem_qb_u64 := _rem_q_u64 * b
        try self.asm_.push("_rem_q_u64");
        try self.asm_.push("_num_rhs_u64");
        try self.asm_.push("_rem_qb_u64");
        try self.asm_.extern_("SystemUInt64.__op_Multiplication__SystemUInt64_SystemUInt64__SystemUInt64");
        // _num_res_u64 := a - _rem_qb_u64
        try self.asm_.push("_num_lhs_u64");
        try self.asm_.push("_rem_qb_u64");
        try self.asm_.push("_num_res_u64");
        try self.asm_.extern_("SystemUInt64.__op_Subtraction__SystemUInt64_SystemUInt64__SystemUInt64");
        // lhs (Int64 stack slot) := _num_res_u64
        try self.emitU64ToI64("_num_res_u64", lhs);
        ctx.pop(); // rhs consumed
    }

    fn emitConst(self: *Translator, ctx: *FuncCtx, lit: Literal, ty: tn.TypeName, vt: ValType) Error!void {
        const k = self.call_site_counter; // reuse counter for uniqueness
        self.call_site_counter += 1;
        const const_name = try std.fmt.allocPrint(self.aa(), "__K_{d}", .{k});
        try self.asm_.addData(.{ .name = const_name, .ty = ty, .init = lit });
        try ctx.push(vt);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);
        try self.asm_.push(const_name);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    /// WASM `i64.const V`. Udon spec §4.7 forbids non-null literal
    /// initializers for `SystemInt64` heap variables, so we cannot just
    /// stash `V` in a data entry the way `i32.const` does. Instead each
    /// distinct `V` gets a `SystemInt64` target slot whose value is
    /// synthesized once in `_onEnable` from two `SystemInt32` halves (both
    /// accept arbitrary literals). Slots are deduplicated by value so
    /// frequently-used constants (shift counts, error-union tags) pay the
    /// startup synthesis cost only once, and each `i64.const` site becomes
    /// a plain COPY from the shared slot to the current stack slot —
    /// identical in hot-path cost to `i32.const`.
    ///
    /// Pre-fix, this path called `emitConst(ctx, null_literal, ...)` which
    /// silently truncated every i64 constant to 0. The most visible victim
    /// was `Writer.writeAll`: its slow-path return-value decode uses
    /// `i64.const 32 i64.shr_u` + `i64.const 0xFFFFFFFF i32.wrap_i64` to
    /// split an `Error!usize` packed return, so every non-zero error tag
    /// was misread as a zero-byte successful write and the outer
    /// `index < bytes.len` loop spun forever.
    fn emitI64Const(self: *Translator, ctx: *FuncCtx, value: i64) Error!void {
        try ctx.push(.i64);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);

        // `i64.const 0` is the happy case — `null` initializer already
        // means `default(Int64) = 0L`, so a single shared slot works and
        // needs no runtime synthesis.
        if (value == 0) {
            const zero_slot = "__K64_zero";
            if (!self.i64_consts.contains(0)) {
                try self.asm_.addData(.{ .name = zero_slot, .ty = tn.int64, .init = .null_literal });
                try self.i64_consts.put(self.gpa, 0, zero_slot);
            }
            try self.asm_.push(zero_slot);
            try self.asm_.push(dst);
            try self.asm_.copy();
            return;
        }

        const slot = if (self.i64_consts.get(value)) |existing| existing else blk: {
            const k = self.call_site_counter;
            self.call_site_counter += 1;
            const name = try std.fmt.allocPrint(self.aa(), "__K64_{d}", .{k});
            const hi_name = try std.fmt.allocPrint(self.aa(), "__K64_{d}_hi", .{k});
            const lo_name = try std.fmt.allocPrint(self.aa(), "__K64_{d}_lo", .{k});
            const bits: u64 = @bitCast(value);
            const hi_bits: u32 = @truncate(bits >> 32);
            const lo_bits: u32 = @truncate(bits);
            try self.asm_.addData(.{ .name = name, .ty = tn.int64, .init = .null_literal });
            try self.asm_.addData(.{ .name = hi_name, .ty = tn.int32, .init = .{ .int32 = @bitCast(hi_bits) } });
            try self.asm_.addData(.{ .name = lo_name, .ty = tn.int32, .init = .{ .int32 = @bitCast(lo_bits) } });
            try self.i64_consts.put(self.gpa, value, name);
            try self.i64_const_inits.append(self.gpa, .{
                .slot = name,
                .hi_slot = hi_name,
                .lo_slot = lo_name,
                .bits = bits,
            });
            break :blk name;
        };

        try self.asm_.push(slot);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    /// WASM `f64.const V`. Mirrors `emitI64Const` exactly — Udon spec §4.7
    /// forbids non-null literals for `SystemDouble` for the same reason it
    /// does for `SystemInt64`, so the synthesis pipeline is identical up
    /// to the terminal conversion (`BitConverter.ToDouble` vs
    /// `BitConverter.ToInt64`).
    ///
    /// Dedup key is the raw 64-bit pattern (`@as(u64, @bitCast(V))`) not
    /// the float value: `NaN != NaN` would make an `AutoHashMap(f64, _)`
    /// lose entries silently, and `+0.0` / `-0.0` compare equal but have
    /// different bit patterns that WASM's `f64.const` must preserve.
    fn emitF64Const(self: *Translator, ctx: *FuncCtx, value: f64) Error!void {
        try ctx.push(.f64);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);

        const bits: u64 = @bitCast(value);

        // `f64.const 0.0` (all bits zero) takes the shared-slot shortcut.
        // `-0.0` has bit 63 set and falls through to the synthesis path.
        if (bits == 0) {
            const zero_slot = "__K64f_zero";
            if (!self.f64_consts.contains(0)) {
                try self.asm_.addData(.{ .name = zero_slot, .ty = tn.double, .init = .null_literal });
                try self.f64_consts.put(self.gpa, 0, zero_slot);
            }
            try self.asm_.push(zero_slot);
            try self.asm_.push(dst);
            try self.asm_.copy();
            return;
        }

        const slot = if (self.f64_consts.get(bits)) |existing| existing else blk: {
            const k = self.call_site_counter;
            self.call_site_counter += 1;
            const name = try std.fmt.allocPrint(self.aa(), "__K64f_{d}", .{k});
            const hi_name = try std.fmt.allocPrint(self.aa(), "__K64f_{d}_hi", .{k});
            const lo_name = try std.fmt.allocPrint(self.aa(), "__K64f_{d}_lo", .{k});
            const hi_bits: u32 = @truncate(bits >> 32);
            const lo_bits: u32 = @truncate(bits);
            try self.asm_.addData(.{ .name = name, .ty = tn.double, .init = .null_literal });
            try self.asm_.addData(.{ .name = hi_name, .ty = tn.int32, .init = .{ .int32 = @bitCast(hi_bits) } });
            try self.asm_.addData(.{ .name = lo_name, .ty = tn.int32, .init = .{ .int32 = @bitCast(lo_bits) } });
            try self.f64_consts.put(self.gpa, bits, name);
            try self.f64_const_inits.append(self.gpa, .{
                .slot = name,
                .hi_slot = hi_name,
                .lo_slot = lo_name,
                .bits = bits,
            });
            break :blk name;
        };

        try self.asm_.push(slot);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    /// Emit startup synthesis for every i64 and f64 constant registered
    /// during lowering. Called from `_onEnable` before any event body runs
    /// so every `i64.const` / `f64.const` slot is fully initialized by the
    /// time user code reads it.
    ///
    /// For each `(slot, hi_slot, lo_slot)` triple, compute the UInt64
    /// bit pattern `(UInt64) hi_u32 << 32 | (UInt64) lo_u32` in
    /// `_num_res_u64`, then run the type-specific terminal conversion.
    /// The shared `_num_*` u32/u64 scratch slots are re-used for every
    /// intermediate so we don't grow the data section with per-constant
    /// temporaries.
    fn emit64BitConstInits(self: *Translator) Error!void {
        const i64_empty = self.i64_const_inits.items.len == 0;
        const f64_empty = self.f64_const_inits.items.len == 0;
        if (i64_empty and f64_empty) return;
        try self.asm_.comment("64-bit constant slot init (Udon spec §4.7 forbids non-null Int64/Double literals)");
        for (self.i64_const_inits.items) |entry| {
            try self.emitSynthesize64BitBits(entry);
            // slot := (Int64) _num_res_u64   (bit pattern via BitConverter)
            try self.asm_.push("_num_res_u64");
            try self.asm_.push("_mem_bits_ba");
            try self.asm_.extern_("SystemBitConverter.__GetBytes__SystemUInt64__SystemByteArray");
            try self.asm_.push("_mem_bits_ba");
            try self.asm_.push("__c_i32_0");
            try self.asm_.push(entry.slot);
            try self.asm_.extern_("SystemBitConverter.__ToInt64__SystemByteArray_SystemInt32__SystemInt64");
        }
        for (self.f64_const_inits.items) |entry| {
            try self.emitSynthesize64BitBits(entry);
            // slot := (Double) _num_res_u64  (bit pattern via BitConverter)
            try self.asm_.push("_num_res_u64");
            try self.asm_.push("_mem_bits_ba");
            try self.asm_.extern_("SystemBitConverter.__GetBytes__SystemUInt64__SystemByteArray");
            try self.asm_.push("_mem_bits_ba");
            try self.asm_.push("__c_i32_0");
            try self.asm_.push(entry.slot);
            try self.asm_.extern_("SystemBitConverter.__ToDouble__SystemByteArray_SystemInt32__SystemDouble");
        }
    }

    /// Shared helper used by `emit64BitConstInits`: takes a `Const64Init`
    /// and emits the ops that leave `(UInt64)(hi << 32) | (UInt64) lo` in
    /// `_num_res_u64`. The caller converts from there into an Int64 or
    /// Double slot via one more BitConverter EXTERN.
    fn emitSynthesize64BitBits(self: *Translator, entry: Const64Init) Error!void {
        // hi_u32 := (UInt32) hi_i32   (bit pattern via BitConverter)
        try self.asm_.push(entry.hi_slot);
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.extern_("SystemBitConverter.__GetBytes__SystemInt32__SystemByteArray");
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_num_lhs_u32");
        try self.asm_.extern_("SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32");
        // hi_u64 := (UInt64) hi_u32   (zero-extend)
        try self.asm_.push("_num_lhs_u32");
        try self.asm_.push("_num_lhs_u64");
        try self.asm_.extern_("SystemConvert.__ToUInt64__SystemUInt32__SystemUInt64");
        // hi_u64_shifted := hi_u64 << 32   (into _num_res_u64)
        try self.asm_.push("_num_lhs_u64");
        try self.asm_.push("__c_i32_32");
        try self.asm_.push("_num_res_u64");
        try self.asm_.extern_("SystemUInt64.__op_LeftShift__SystemUInt64_SystemInt32__SystemUInt64");
        // lo_u32 := (UInt32) lo_i32   (bit pattern via BitConverter)
        try self.asm_.push(entry.lo_slot);
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.extern_("SystemBitConverter.__GetBytes__SystemInt32__SystemByteArray");
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_num_rhs_u32");
        try self.asm_.extern_("SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32");
        // lo_u64 := (UInt64) lo_u32
        try self.asm_.push("_num_rhs_u32");
        try self.asm_.push("_num_rhs_u64");
        try self.asm_.extern_("SystemConvert.__ToUInt64__SystemUInt32__SystemUInt64");
        // _num_res_u64 := hi_u64_shifted | lo_u64
        try self.asm_.push("_num_res_u64");
        try self.asm_.push("_num_rhs_u64");
        try self.asm_.push("_num_res_u64");
        try self.asm_.extern_("SystemUInt64.__op_LogicalOr__SystemUInt64_SystemUInt64__SystemUInt64");
    }

    fn emitLocalGet(self: *Translator, ctx: *FuncCtx, idx: u32) Error!void {
        const src = try self.localOrParamName(ctx, idx);
        const vt = self.localOrParamType(ctx, idx);
        try ctx.push(vt);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);
        try self.asm_.push(src);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    fn emitLocalSet(self: *Translator, ctx: *FuncCtx, idx: u32) Error!void {
        const dst = try self.localOrParamName(ctx, idx);
        const src = try ctx.slotAt(self.aa(), ctx.depth - 1);
        try self.asm_.push(src);
        try self.asm_.push(dst);
        try self.asm_.copy();
        ctx.pop();
    }

    fn emitLocalTee(self: *Translator, ctx: *FuncCtx, idx: u32) Error!void {
        // tee is set + leave value on stack — do the set but don't pop.
        const dst = try self.localOrParamName(ctx, idx);
        const src = try ctx.slotAt(self.aa(), ctx.depth - 1);
        try self.asm_.push(src);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    fn emitGlobalGet(self: *Translator, ctx: *FuncCtx, idx: u32) Error!void {
        const src = self.global_udon_names[idx];
        const vt = self.globalValType(idx);
        try ctx.push(vt);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);
        try self.asm_.push(src);
        try self.asm_.push(dst);
        try self.asm_.copy();
    }

    fn emitGlobalSet(self: *Translator, ctx: *FuncCtx, idx: u32) Error!void {
        const dst = self.global_udon_names[idx];
        const src = try ctx.slotAt(self.aa(), ctx.depth - 1);
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

    fn localOrParamType(_: *Translator, ctx: *FuncCtx, idx: u32) ValType {
        const nparams: u32 = @intCast(ctx.params.len);
        if (idx < nparams) return ctx.params[idx];
        var li: u32 = nparams;
        for (ctx.locals) |lg| {
            const end = li + lg.count;
            if (idx < end) return lg.ty;
            li = end;
        }
        unreachable;
    }

    fn globalValType(self: *Translator, idx: u32) ValType {
        // Imported globals come first in the flat index space; their types
        // are attached to the import descriptor.
        if (idx < self.num_imported_globals) {
            var seen: u32 = 0;
            for (self.mod.imports) |imp| switch (imp.desc) {
                .global => |gt| {
                    if (seen == idx) return gt.valtype;
                    seen += 1;
                },
                else => {},
            };
            unreachable;
        }
        return self.mod.globals[idx - self.num_imported_globals].ty.valtype;
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

        // Top of stack is the condition (i32 non-zero → true). Udon's
        // JUMP_IF_FALSE strictly wants a SystemBoolean operand, so widen
        // the Int32 stack slot via SystemConvert first.
        const cond = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        try self.emitI32ToBool(cond);
        try self.asm_.push("_cmp_bool");
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
            ctx.truncateStackTo(block_ctx.depth_at_entry); // reset for else branch
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
        const cond = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        const skip_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_BIS{d}__", .{ ctx.fn_name, self.block_counter });
        self.block_counter += 1;
        try self.emitI32ToBool(cond);
        try self.asm_.push("_cmp_bool");
        try self.asm_.jumpIfFalse(skip_lbl);
        try self.asm_.jump(target);
        try self.asm_.label(skip_lbl);
    }

    fn emitBrTable(self: *Translator, ctx: *FuncCtx, bt: wasm.instruction.BrTable) Error!void {
        // Pop the index. For each label in `labels`, emit a comparison
        // against its index; if equal, jump. Otherwise jump to `default`.
        const idx = try ctx.slotAt(self.aa(), ctx.depth - 1);
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

        // Caller-saved frame spill. A recursive caller's P / L / RA are
        // aliased with every invocation's slots, so nested calls would
        // stomp them. Save before the arg/RA copy (which overwrites the
        // aliased slots) and restore before we read the callee's R slots
        // (which are NOT in the saved frame — their fresh value survives).
        const save = self.shouldSpill(ctx.fn_idx);
        if (save) try self.emitCallerSaveFrame(ctx);

        // 1. Copy S slots (top of stack = last arg) → callee P slots.
        const n_args: u32 = @intCast(callee_ty.params.len);
        var i: u32 = 0;
        while (i < n_args) : (i += 1) {
            const src_depth = ctx.depth - n_args + i;
            const src = try ctx.slotAt(self.aa(), src_depth);
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

        if (save) try self.emitCallerRestoreFrame(ctx);

        // 4. Copy R slots back into caller's S slots.
        const n_res: u32 = @intCast(callee_ty.results.len);
        var r: u32 = 0;
        while (r < n_res) : (r += 1) {
            try ctx.push(callee_ty.results[r]);
            const src = try names.returnSlot(self.aa(), callee_name, r);
            const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);
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
        const idx_slot = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        try self.asm_.push("__fn_table__");
        try self.asm_.push(idx_slot);
        try self.asm_.push("__indirect_target__");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");

        // Caller-saved spill for recursive callers (see `emitCall`).
        const save = self.shouldSpill(ctx.fn_idx);
        if (save) try self.emitCallerSaveFrame(ctx);

        // (b) Copy caller S slots → shared __ind_P*.
        var i: u32 = 0;
        while (i < n_args) : (i += 1) {
            const src_depth = ctx.depth - n_args + i;
            const src = try ctx.slotAt(self.aa(), src_depth);
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

        if (save) try self.emitCallerRestoreFrame(ctx);

        // (e) Copy shared __ind_R* back into caller S slots.
        var r: u32 = 0;
        while (r < n_res) : (r += 1) {
            try ctx.push(ty.results[r]);
            const src = try std.fmt.allocPrint(self.aa(), "__ind_R{d}__", .{r});
            const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);
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
                    // Meta-bound import: a `kind: import` field declares
                    // that this WASM import (a `() -> T` function) is a
                    // pure read of the named Udon data slot. Lower it as a
                    // slot copy instead of a real EXTERN. This is how
                    // Udon-only singletons (e.g. `__G__self: %Transform,
                    // this`) are exposed to the WASM source — Zig cannot
                    // emit `(import "env" "x" (global …))` directly, so
                    // authors declare an import function and the binding
                    // routes through here.
                    if (try self.tryEmitMetaImportRead(ctx, imp, imp_ty)) return;
                    var bridge = HostBridge{ .t = self, .ctx = ctx };
                    const host = bridge.host();
                    if (lower_wasi.isWasiImport(imp)) {
                        const wasi_cfg = self.wasiConfig();
                        lower_wasi.emit(host, imp, imp_ty, wasi_cfg) catch |err| switch (err) {
                            error.WasiSignatureMismatch, error.WasiUnknownImport => {
                                // Recover by consuming/producing whatever the WASM type said.
                                var i: u32 = 0;
                                while (i < imp_ty.params.len) : (i += 1) ctx.pop();
                                for (imp_ty.results) |vt| try ctx.push(vt);
                            },
                            error.SignatureMismatch, error.UnrecognizedImport => {
                                var i: u32 = 0;
                                while (i < imp_ty.params.len) : (i += 1) ctx.pop();
                                for (imp_ty.results) |vt| try ctx.push(vt);
                            },
                            error.OutOfMemory => return error.OutOfMemory,
                        };
                        return;
                    }
                    lower_import.emit(host, imp, imp_ty) catch |err| switch (err) {
                        error.SignatureMismatch, error.UnrecognizedImport => {
                            // Recover by consuming whatever the WASM type said.
                            var i: u32 = 0;
                            while (i < imp_ty.params.len) : (i += 1) ctx.pop();
                            for (imp_ty.results) |vt| try ctx.push(vt);
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

    /// If `imp` is a `() -> single-result` function bound by a
    /// `__udon_meta.fields[*]` entry with `source.kind == "import"`,
    /// emit a slot-read lowering and return `true`. Caller skips the
    /// generic `lower_import.emit` path.
    fn tryEmitMetaImportRead(
        self: *Translator,
        ctx: *FuncCtx,
        imp: wasm.module.Import,
        imp_ty: wasm.types.FuncType,
    ) Error!bool {
        const m = self.meta orelse return false;
        var slot: ?[]const u8 = null;
        for (m.fields) |f| {
            if (importMetaMatches(f, imp)) {
                slot = f.udon_name orelse continue;
                break;
            }
        }
        const src = slot orelse return false;
        // Shape constraint: nullary function returning exactly one value.
        // Anything else is a meta misconfiguration — surface a comment
        // and fall through to the generic dispatcher (which will emit
        // `unsupported import` or `SignatureMismatch`).
        if (imp_ty.params.len != 0 or imp_ty.results.len != 1) {
            try self.asm_.comment(try std.fmt.allocPrint(self.aa(), "meta import binding {s}.{s} expects () -> T but WASM type is {d}->{d}", .{ imp.module, imp.name, imp_ty.params.len, imp_ty.results.len }));
            return false;
        }
        try self.asm_.comment(try std.fmt.allocPrint(self.aa(), "meta import: {s}.{s} → {s}", .{ imp.module, imp.name, src }));
        try ctx.push(imp_ty.results[0]);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);
        try self.asm_.push(src);
        try self.asm_.push(dst);
        try self.asm_.copy();
        return true;
    }

    // ---- memory ----

    fn emitMemorySize(self: *Translator, ctx: *FuncCtx) Error!void {
        try ctx.push(.i32);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);
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
        const delta = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        try ctx.push(.i32);
        const result = try ctx.slotAt(self.aa(), ctx.depth - 1);

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

    /// Bit-pattern-preserving Int32 → UInt32: `out := BitConverter.ToUInt32(
    /// BitConverter.GetBytes(val), 0)`. Safe for any i32 including
    /// high-bit-set values that `SystemConvert.ToUInt32` would reject.
    fn emitI32ToU32(self: *Translator, val: []const u8, out_u32: []const u8) Error!void {
        try self.asm_.push(val);
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.extern_("SystemBitConverter.__GetBytes__SystemInt32__SystemByteArray");
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push(out_u32);
        try self.asm_.extern_("SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32");
    }

    /// Inverse of `emitI32ToU32`: UInt32 → Int32 without overflow checks.
    fn emitU32ToI32(self: *Translator, val: []const u8, out_i32: []const u8) Error!void {
        try self.asm_.push(val);
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.extern_("SystemBitConverter.__GetBytes__SystemUInt32__SystemByteArray");
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push(out_i32);
        try self.asm_.extern_("SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32");
    }

    /// Reinterpret an Int32 bit pattern as a Single (f32). Used by
    /// `emitMemLoadWord(... .f32)` to bridge the u32 chunk word to the
    /// WASM-side f32 stack slot.
    fn emitI32BitsToSingle(self: *Translator, val_i32: []const u8, out_f32: []const u8) Error!void {
        try self.asm_.push(val_i32);
        try self.asm_.push(out_f32);
        try self.asm_.extern_("SystemBitConverter.__Int32BitsToSingle__SystemInt32__SystemSingle");
    }

    /// Inverse of `emitI32BitsToSingle`: Single → Int32 bit pattern.
    fn emitSingleToI32Bits(self: *Translator, val_f32: []const u8, out_i32: []const u8) Error!void {
        try self.asm_.push(val_f32);
        try self.asm_.push(out_i32);
        try self.asm_.extern_("SystemBitConverter.__SingleToInt32Bits__SystemSingle__SystemInt32");
    }

    /// Int64 → UInt64 bit-pattern-preserving conversion.
    fn emitI64ToU64(self: *Translator, val: []const u8, out_u64: []const u8) Error!void {
        try self.asm_.push(val);
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.extern_("SystemBitConverter.__GetBytes__SystemInt64__SystemByteArray");
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push(out_u64);
        try self.asm_.extern_("SystemBitConverter.__ToUInt64__SystemByteArray_SystemInt32__SystemUInt64");
    }

    /// UInt64 → Int64 bit-pattern-preserving conversion.
    fn emitU64ToI64(self: *Translator, val: []const u8, out_i64: []const u8) Error!void {
        try self.asm_.push(val);
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.extern_("SystemBitConverter.__GetBytes__SystemUInt64__SystemByteArray");
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push(out_i64);
        try self.asm_.extern_("SystemBitConverter.__ToInt64__SystemByteArray_SystemInt32__SystemInt64");
    }

    /// Int64 → Int32 truncation matching WASM `i32.wrap_i64` semantics: take
    /// the low 32 bits of the i64 value without any range check. `SystemConvert.
    /// ToInt32(Int64)` is a *checked* conversion that throws OverflowException
    /// for values outside [Int32.MinValue, Int32.MaxValue] — so using it for
    /// `i32.wrap_i64` (or for splitting an i64 into hi/lo for i64.store) fails
    /// at runtime whenever the stored value has any bit set above the sign bit
    /// of Int32. This was observed in the wild during `i64.store` of a struct
    /// with adjacent `buffer.len` (@8) + `end` (@12) fields, where LLVM
    /// combined them into a single 8-byte store. The packed i64 value could be
    /// e.g. `0x0000_0200_xxxx_xxxx` (buffer.len=512 in the high word, ptr in
    /// low), which is > Int32.MaxValue and triggered the EXTERN exception.
    ///
    /// Use `BitConverter.GetBytes(i64)` (produces 8-byte little-endian array)
    /// then `BitConverter.ToInt32(bytes, 0)` (reads bytes 0..3 as Int32) to
    /// get the low 32 bits as a signed Int32 — this is pure bit truncation and
    /// matches WASM semantics exactly.
    fn emitI64TruncI32(self: *Translator, val: []const u8, out_i32: []const u8) Error!void {
        try self.asm_.push(val);
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.extern_("SystemBitConverter.__GetBytes__SystemInt64__SystemByteArray");
        try self.asm_.push("_mem_bits_ba");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push(out_i32);
        try self.asm_.extern_("SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32");
    }

    fn emitMemLoadWord(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        const memarg = ins.i32_load;
        return self.emitMemLoadWordTyped(ctx, memarg, .i32);
    }

    /// f32.load: same chunk-fetch machinery as i32.load, with the final
    /// unpack step bridged through `SystemBitConverter.Int32BitsToSingle`
    /// so the WASM-side f32 stack slot receives the correct typed value.
    fn emitMemLoadF32(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        const memarg = ins.f32_load;
        return self.emitMemLoadWordTyped(ctx, memarg, .f32);
    }

    fn emitMemLoadWordTyped(
        self: *Translator,
        ctx: *FuncCtx,
        memarg: wasm.instruction.MemArg,
        val_ty: ValType,
    ) Error!void {
        const raw_addr = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        if (memarg.@"align" >= 2) {
            return self.emitMemLoadWordFast(ctx, addr_slot, val_ty);
        }
        return self.emitMemLoadWordGeneric(ctx, addr_slot, val_ty);
    }

    /// Final unpack step shared by the load fast/generic paths: take the
    /// `_mem_val_u32_buf` populated by the chunk read and convert it into
    /// the value expected at the WASM stack's destination slot.
    fn emitLoadWordUnpack(self: *Translator, val_ty: ValType, dst: []const u8) Error!void {
        switch (val_ty) {
            .i32 => try self.emitU32ToI32("_mem_val_u32_buf", dst),
            .f32 => {
                try self.emitU32ToI32("_mem_val_u32_buf", "_mem_val_i32_buf");
                try self.emitI32BitsToSingle("_mem_val_i32_buf", dst);
            },
            else => unreachable, // word-sized loads are i32 or f32 only
        }
    }

    fn emitMemLoadWordFast(self: *Translator, ctx: *FuncCtx, addr_slot: []const u8, val_ty: ValType) Error!void {
        const op_label: []const u8 = switch (val_ty) {
            .i32 => "i32.load (aligned, within-chunk fast path)",
            .f32 => "f32.load (aligned, within-chunk fast path)",
            else => unreachable,
        };
        try self.asm_.comment(op_label);
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
        // outer[page_idx] → _mem_chunk (bounds-checked)
        const site_label: []const u8 = switch (val_ty) {
            .i32 => "i32.load",
            .f32 => "f32.load",
            else => unreachable,
        };
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "primary");
        try self.emitOuterGetChecked("_mem_page_idx");
        // chunk[word_in_page] → UInt32 scratch; unpack per val_ty.
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mem_val_u32_buf");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        try ctx.push(val_ty);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);
        try self.emitLoadWordUnpack(val_ty, dst);
    }

    /// Generic i32.load / f32.load that handles unaligned access and
    /// page-straddle. Per `docs/spec_linear_memory.md` §6.1, dispatches at
    /// runtime into one of three branches based on `sub = addr & 3` and
    /// whether the 4-byte window crosses a page boundary.
    fn emitMemLoadWordGeneric(self: *Translator, ctx: *FuncCtx, addr_slot: []const u8, val_ty: ValType) Error!void {
        const site_label: []const u8 = switch (val_ty) {
            .i32 => "i32.load",
            .f32 => "f32.load",
            else => unreachable,
        };
        try self.asm_.comment(switch (val_ty) {
            .i32 => "i32.load (generic: 3-branch alignment/straddle dispatch)",
            .f32 => "f32.load (generic: 3-branch alignment/straddle dispatch)",
            else => unreachable,
        });
        const id = self.block_counter;
        self.block_counter += 1;
        const fast_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mlw_fast_{d}__", .{ ctx.fn_name, id });
        const slow_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mlw_slow_{d}__", .{ ctx.fn_name, id });
        const straddle_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mlw_straddle_{d}__", .{ ctx.fn_name, id });
        const end_lbl = try std.fmt.allocPrint(self.aa(), "__{s}_mlw_end_{d}__", .{ ctx.fn_name, id });

        ctx.pop();
        try ctx.push(val_ty);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);

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
        // chunk := outer[page_idx] (bounds-checked)
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "slow");
        try self.emitOuterGetChecked("_mem_page_idx");
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
        try self.emitMlwCombineAndEnd(dst, end_lbl, val_ty);

        // Straddle branch.
        try self.asm_.label(straddle_lbl);
        // lo_chunk := outer[page_idx] (bounds-checked)
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "straddle_lo");
        try self.emitOuterGetChecked("_mem_page_idx");
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
        // hi_chunk := outer[page_idx + 1] (bounds-checked inside helper)
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "straddle_hi");
        try self.emitOuterGetChecked("_mem_word_in_page_hi");
        // hi := hi_chunk[0]
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_mlw_hi");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        try self.emitMlwCombineAndEnd(dst, end_lbl, val_ty);

        // Fast branch.
        try self.asm_.label(fast_lbl);
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "fast");
        try self.emitOuterGetChecked("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mem_val_u32_buf");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        try self.emitLoadWordUnpack(val_ty, dst);

        try self.asm_.label(end_lbl);
    }

    /// Common trailer for the unaligned-within and straddle branches:
    /// dst := (lo >> shift) | (hi << rshift) ; then goto end.
    fn emitMlwCombineAndEnd(self: *Translator, dst: []const u8, end_lbl: []const u8, val_ty: ValType) Error!void {
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
        // tmp | hi_shifted goes into UInt32 scratch, then unpack per val_ty.
        try self.asm_.push("_mlw_tmp");
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.push("_mem_val_u32_buf");
        try self.asm_.extern_("SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32");
        try self.emitLoadWordUnpack(val_ty, dst);
        try self.asm_.jump(end_lbl);
    }

    fn emitMemStoreWord(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        const memarg = ins.i32_store;
        return self.emitMemStoreWordTyped(ctx, memarg, .i32);
    }

    /// f32.store: bit-convert the Single stack value to Int32 via
    /// `SystemBitConverter.SingleToInt32Bits`, widen to UInt32, then reuse
    /// the i32.store chunk-write machinery.
    fn emitMemStoreF32(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        const memarg = ins.f32_store;
        return self.emitMemStoreWordTyped(ctx, memarg, .f32);
    }

    fn emitMemStoreWordTyped(
        self: *Translator,
        ctx: *FuncCtx,
        memarg: wasm.instruction.MemArg,
        val_ty: ValType,
    ) Error!void {
        const val = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        const raw_addr = try ctx.slotAt(self.aa(), ctx.depth - 1);
        // Offset must be applied *before* we pop the address slot, since
        // the downstream fast/generic helpers pop it themselves.
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        // Bridge the stack-type value into `_mem_val_u32_buf` (the UInt32
        // expected by the chunk-write helpers). BitConverter is used
        // throughout so high-bit values round-trip without OverflowException.
        switch (val_ty) {
            .i32 => try self.emitI32ToU32(val, "_mem_val_u32_buf"),
            .f32 => {
                try self.emitSingleToI32Bits(val, "_mem_val_i32_buf");
                try self.emitI32ToU32("_mem_val_i32_buf", "_mem_val_u32_buf");
            },
            else => unreachable,
        }
        if (memarg.@"align" >= 2) {
            return self.emitMemStoreWordFast(ctx, addr_slot, "_mem_val_u32_buf", val_ty);
        }
        return self.emitMemStoreWordGeneric(ctx, addr_slot, "_mem_val_u32_buf", val_ty);
    }

    fn emitMemStoreWordFast(self: *Translator, ctx: *FuncCtx, addr_slot: []const u8, val: []const u8, val_ty: ValType) Error!void {
        try self.asm_.comment(switch (val_ty) {
            .i32 => "i32.store (aligned, within-chunk fast path)",
            .f32 => "f32.store (aligned, within-chunk fast path)",
            else => unreachable,
        });
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
        const site_label: []const u8 = switch (val_ty) {
            .i32 => "i32.store",
            .f32 => "f32.store",
            else => unreachable,
        };
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "primary");
        try self.emitOuterGetChecked("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push(val);
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
    }

    /// Generic i32.store / f32.store that handles unaligned access and
    /// page-straddle via a 3-branch RMW (read-modify-write) of two adjacent
    /// words.
    fn emitMemStoreWordGeneric(self: *Translator, ctx: *FuncCtx, addr_slot: []const u8, val: []const u8, val_ty: ValType) Error!void {
        const site_label: []const u8 = switch (val_ty) {
            .i32 => "i32.store",
            .f32 => "f32.store",
            else => unreachable,
        };
        try self.asm_.comment(switch (val_ty) {
            .i32 => "i32.store (generic: 3-branch alignment/straddle RMW)",
            .f32 => "f32.store (generic: 3-branch alignment/straddle RMW)",
            else => unreachable,
        });
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
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "slow");
        try self.emitOuterGetChecked("_mem_page_idx");
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
        // lo_chunk := outer[page_idx] (bounds-checked)
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "straddle_lo");
        try self.emitOuterGetChecked("_mem_page_idx");
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
        // hi_chunk := outer[page_idx + 1] (bounds-checked inside helper —
        // the page_idx_hi slot is mirrored into _mem_page_idx so the trap
        // message reflects the high page that tripped the check)
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "straddle_hi");
        try self.emitOuterGetChecked("_mem_word_in_page_hi");
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
        // Re-fetch lo_chunk := outer[page_idx] (page_idx is still valid,
        // and emitOuterGetChecked re-verifies just in case) and write
        // lo_out[16383].
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "straddle_lo_writeback");
        try self.emitOuterGetChecked("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("__c_i32_16383");
        try self.asm_.push("_msw_lo_out");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
        try self.asm_.jump(end_lbl);

        // Fast branch.
        try self.asm_.label(fast_lbl);
        try self.recordMemOpSite(ctx.fn_name, addr_slot, site_label, "fast");
        try self.emitOuterGetChecked("_mem_page_idx");
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
    fn emitByteAccessPreamble(
        self: *Translator,
        addr_slot: []const u8,
        site_fn_name: []const u8,
        site_op_tag: []const u8,
    ) Error!void {
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
        // _mem_chunk := __G__memory[page_idx] (bounds-checked — this is
        // the crash site PC 221880 used to land in before the check)
        try self.recordMemOpSite(site_fn_name, addr_slot, site_op_tag, "primary");
        try self.emitOuterGetChecked("_mem_page_idx");
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
    /// Aligned i32 store at `*addr_slot + offset`. Used by WASI lowerings
    /// (iovec out-pointers, fdstat zero-fill); WASM-side i32.store goes
    /// through `emitMemStoreWord` which handles the unaligned case via
    /// `emitMemStoreWordGeneric`. WASI pointers from iovecs and out-params
    /// are always 4-aligned per the upstream ABI, so the fast path suffices.
    pub fn emitWasiStoreI32(
        self: *Translator,
        addr_slot: []const u8,
        offset: u32,
        val_slot: []const u8,
    ) Error!void {
        // val_u32 := bit-pattern of val
        try self.emitI32ToU32(val_slot, "_mem_val_u32_buf");
        // eff_addr := addr_slot + offset
        const eff_addr_name = "_wasi_mem_addr";
        try self.declareScratchIfAbsent(eff_addr_name, tn.int32, .{ .int32 = 0 });
        if (offset == 0) {
            try self.asm_.push(addr_slot);
            try self.asm_.push(eff_addr_name);
            try self.asm_.copy();
        } else {
            const off_name = try std.fmt.allocPrint(self.aa(), "__c_i32_off_{d}", .{offset});
            try self.declareScratchIfAbsent(off_name, tn.int32, .{ .int32 = @intCast(offset) });
            try self.asm_.push(addr_slot);
            try self.asm_.push(off_name);
            try self.asm_.push(eff_addr_name);
            try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        }
        // page_idx, word_in_page (assumes alignment 4)
        try self.asm_.push(eff_addr_name);
        try self.asm_.push("__c_i32_16");
        try self.asm_.push("_mem_page_idx");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push(eff_addr_name);
        try self.asm_.push("__c_i32_0xFFFF");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("__c_i32_2");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        try self.recordMemOpSite("__wasi__", eff_addr_name, "wasi.i32_store", "primary");
        try self.emitOuterGetChecked("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mem_val_u32_buf");
        try self.asm_.extern_("SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid");
    }

    /// Aligned i32 load at `*addr_slot + offset`, result in `out_slot`.
    pub fn emitWasiLoadI32(
        self: *Translator,
        addr_slot: []const u8,
        offset: u32,
        out_slot: []const u8,
    ) Error!void {
        const eff_addr_name = "_wasi_mem_addr";
        try self.declareScratchIfAbsent(eff_addr_name, tn.int32, .{ .int32 = 0 });
        if (offset == 0) {
            try self.asm_.push(addr_slot);
            try self.asm_.push(eff_addr_name);
            try self.asm_.copy();
        } else {
            const off_name = try std.fmt.allocPrint(self.aa(), "__c_i32_off_{d}", .{offset});
            try self.declareScratchIfAbsent(off_name, tn.int32, .{ .int32 = @intCast(offset) });
            try self.asm_.push(addr_slot);
            try self.asm_.push(off_name);
            try self.asm_.push(eff_addr_name);
            try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        }
        try self.asm_.push(eff_addr_name);
        try self.asm_.push("__c_i32_16");
        try self.asm_.push("_mem_page_idx");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push(eff_addr_name);
        try self.asm_.push("__c_i32_0xFFFF");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("__c_i32_2");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        try self.recordMemOpSite("__wasi__", eff_addr_name, "wasi.i32_load", "primary");
        try self.emitOuterGetChecked("_mem_page_idx");
        try self.asm_.push("_mem_chunk");
        try self.asm_.push("_mem_word_in_page");
        try self.asm_.push("_mem_val_u32_buf");
        try self.asm_.extern_("SystemUInt32Array.__Get__SystemInt32__SystemUInt32");
        try self.emitU32ToI32("_mem_val_u32_buf", out_slot);
    }

    fn emitReadMemoryByte(self: *Translator, addr_slot: []const u8, out_slot: []const u8) Error!void {
        try self.emitByteAccessPreamble(addr_slot, "__marshal__", "host_import.read_byte");
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

    /// Ctx-free byte load core. Reads `addr_slot` (an Int32 address slot)
    /// and writes the unsigned byte value into `dst_slot` (a SystemInt32
    /// scratch with high bits zero). Emits the bounds-checked outer/inner
    /// fetch and the shift/mask sequence; does not touch any FuncCtx state.
    /// `site_fn_name` / `site_op_tag` feed the trap-site telemetry.
    fn emitMemLoadByteAt(
        self: *Translator,
        addr_slot: []const u8,
        dst_slot: []const u8,
        site_fn_name: []const u8,
        site_op_tag: []const u8,
    ) Error!void {
        try self.emitByteAccessPreamble(addr_slot, site_fn_name, site_op_tag);

        // _mem_u32_shifted := _mem_u32 >> shift (unsigned)
        try self.asm_.push("_mem_u32");
        try self.asm_.push("_mem_shift");
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.extern_("SystemUInt32.__op_RightShift__SystemUInt32_SystemInt32__SystemUInt32");

        // masked := _mem_u32_shifted & 0xFF   (UInt32), then convert to Int32 dst.
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.push("__c_u32_0xFF");
        try self.asm_.push("_mem_val_u32_buf");
        try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");
        try self.emitU32ToI32("_mem_val_u32_buf", dst_slot);
    }

    fn emitMemLoadByte(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        const signed = switch (ins) {
            .i32_load8_s => true,
            else => false,
        };
        try self.asm_.comment(if (signed) "i32.load8_s" else "i32.load8_u");
        const raw_addr = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const memarg = switch (ins) {
            .i32_load8_u => |m| m,
            .i32_load8_s => |m| m,
            else => unreachable,
        };
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        ctx.pop();

        try ctx.push(.i32);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);

        const load_tag: []const u8 = if (signed) "i32.load8_s" else "i32.load8_u";
        try self.emitMemLoadByteAt(addr_slot, dst, ctx.fn_name, load_tag);

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

    /// `i32.load16_u` / `i32.load16_s` — read two bytes from linear memory
    /// as an unsigned half-word, then optionally sign-extend. Mirrors
    /// `emitMemLoadByte` with mask `0xFFFF` and 16-bit sign-extension.
    /// Assumes the half-word fits in one chunk word, i.e. `(addr & 3) ∈ {0, 2}`.
    /// Rust on `wasm32v1-none` always emits 2-byte-aligned half-word loads,
    /// so this assumption holds for `examples/wasm-bench-alloc-rs` and
    /// every alloc/BTreeMap user. Without this opcode the translator falls
    /// through to `__unsupported__` (a no-op annotation), pushing nothing
    /// onto the WASM stack — the next instruction then runs against a
    /// stale stack and Udon halts the UdonBehaviour with no exception
    /// message.
    fn emitMemLoad16(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        const signed = switch (ins) {
            .i32_load16_s => true,
            else => false,
        };
        try self.asm_.comment(if (signed) "i32.load16_s" else "i32.load16_u");
        const raw_addr = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const memarg = switch (ins) {
            .i32_load16_u => |m| m,
            .i32_load16_s => |m| m,
            else => unreachable,
        };
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        ctx.pop();

        const load_tag: []const u8 = if (signed) "i32.load16_s" else "i32.load16_u";
        try self.emitByteAccessPreamble(addr_slot, ctx.fn_name, load_tag);

        // _mem_u32_shifted := _mem_u32 >> shift (unsigned)
        try self.asm_.push("_mem_u32");
        try self.asm_.push("_mem_shift");
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.extern_("SystemUInt32.__op_RightShift__SystemUInt32_SystemInt32__SystemUInt32");

        try ctx.push(.i32);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);

        // masked := _mem_u32_shifted & 0xFFFF (UInt32), then convert to Int32 dst.
        try self.asm_.push("_mem_u32_shifted");
        try self.asm_.push("__c_u32_0xFFFF_32");
        try self.asm_.push("_mem_val_u32_buf");
        try self.asm_.extern_("SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32");
        try self.emitU32ToI32("_mem_val_u32_buf", dst);

        if (signed) {
            // Sign-extend 16-bit → 32-bit: (dst << 16) >> 16 arithmetically.
            try self.asm_.push(dst);
            try self.asm_.push("__c_i32_16");
            try self.asm_.push(dst);
            try self.asm_.extern_("SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32");
            try self.asm_.push(dst);
            try self.asm_.push("__c_i32_16");
            try self.asm_.push(dst);
            try self.asm_.extern_("SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");
        }
    }

    /// Ctx-free byte store core. Reads `addr_slot` (Int32 address) and
    /// `val_slot` (an Int32 value — the masking to the low 8 bits is done
    /// inside this helper). Performs the read-modify-write into the
    /// corresponding chunk word; does not touch any FuncCtx state.
    fn emitMemStoreByteAt(
        self: *Translator,
        addr_slot: []const u8,
        val_slot: []const u8,
        site_fn_name: []const u8,
        site_op_tag: []const u8,
    ) Error!void {
        // UInt32 bit-pattern of val for the RMW.
        try self.emitI32ToU32(val_slot, "_mem_val_u32_buf");
        const val = "_mem_val_u32_buf";

        try self.emitByteAccessPreamble(addr_slot, site_fn_name, site_op_tag);

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

    fn emitMemStoreByte(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        try self.asm_.comment("i32.store8");
        const memarg = ins.i32_store8;
        const val_i32 = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        const raw_addr = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        ctx.pop();

        try self.emitMemStoreByteAt(addr_slot, val_i32, ctx.fn_name, "i32.store8");
    }

    /// `memory.copy` — overlap-safe byte-by-byte copy with runtime
    /// direction selection. Stack: `(dst, src, n)` (top). Per the WASM
    /// bulk-memory spec, source and destination ranges may overlap, so we
    /// dispatch on `dst <= src`:
    ///   - true  → ascending loop  for i in [0, n) : mem[dst+i] = mem[src+i]
    ///   - false → descending loop for i in [n-1, 0] : mem[dst+i] = mem[src+i]
    /// Loop labels are uniqued via `block_counter`; the byte slots
    /// (`_mc_*`) are shared across calls because each call body fully
    /// writes them before any read. See docs/spec_linear_memory.md
    /// §"memory.copy lowering".
    fn emitMemoryCopy(self: *Translator, ctx: *FuncCtx) Error!void {
        try self.asm_.comment("memory.copy (overlap-safe byte loop)");

        // Pop (n, src, dst) into `_mc_*` so they survive subsequent
        // helper calls (which freely use `_mem_*` scratch slots).
        const n_slot = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        const src_slot = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        const dst_slot = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();

        // _mc_dst := dst ; _mc_src := src ; _mc_n := n
        try self.asm_.push(dst_slot);
        try self.asm_.push("_mc_dst");
        try self.asm_.copy();
        try self.asm_.push(src_slot);
        try self.asm_.push("_mc_src");
        try self.asm_.copy();
        try self.asm_.push(n_slot);
        try self.asm_.push("_mc_n");
        try self.asm_.copy();

        const id = self.block_counter;
        self.block_counter += 1;
        const back_lbl = try std.fmt.allocPrint(self.aa(), "__memcopy_back_{d}__", .{id});
        const fwd_loop_lbl = try std.fmt.allocPrint(self.aa(), "__memcopy_fwd_loop_{d}__", .{id});
        const back_loop_lbl = try std.fmt.allocPrint(self.aa(), "__memcopy_back_loop_{d}__", .{id});
        const end_lbl = try std.fmt.allocPrint(self.aa(), "__memcopy_end_{d}__", .{id});
        const site_tag = try std.fmt.allocPrint(self.aa(), "memory.copy_{d}", .{id});

        // Direction: _mc_cmp := dst <= src
        try self.asm_.push("_mc_dst");
        try self.asm_.push("_mc_src");
        try self.asm_.push("_mc_cmp");
        try self.asm_.extern_("SystemInt32.__op_LessThanOrEqual__SystemInt32_SystemInt32__SystemBoolean");
        try self.asm_.push("_mc_cmp");
        try self.asm_.jumpIfFalse(back_lbl);

        // ---- Forward branch: i = 0; while i < n { copy(i); i += 1 } ----
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_mc_i");
        try self.asm_.copy();

        try self.asm_.label(fwd_loop_lbl);
        // _mc_cmp := i < n
        try self.asm_.push("_mc_i");
        try self.asm_.push("_mc_n");
        try self.asm_.push("_mc_cmp");
        try self.asm_.extern_("SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean");
        try self.asm_.push("_mc_cmp");
        try self.asm_.jumpIfFalse(end_lbl);
        // _mc_addr_src := src + i ; _mc_addr_dst := dst + i
        try self.asm_.push("_mc_src");
        try self.asm_.push("_mc_i");
        try self.asm_.push("_mc_addr_src");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mc_dst");
        try self.asm_.push("_mc_i");
        try self.asm_.push("_mc_addr_dst");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        // mem[dst+i] := mem[src+i]
        try self.emitMemLoadByteAt("_mc_addr_src", "_mc_byte", ctx.fn_name, site_tag);
        try self.emitMemStoreByteAt("_mc_addr_dst", "_mc_byte", ctx.fn_name, site_tag);
        // i += 1
        try self.asm_.push("_mc_i");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mc_i");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.jump(fwd_loop_lbl);

        // ---- Backward branch: i = n - 1; while i > -1 { copy(i); i -= 1 } ----
        try self.asm_.label(back_lbl);
        // i := n - 1
        try self.asm_.push("_mc_n");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mc_i");
        try self.asm_.extern_("SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32");

        try self.asm_.label(back_loop_lbl);
        // _mc_cmp := i > -1   (avoids unsigned-overflow trap at i==0 that
        // a `i >= 0` lowering would risk if WASM ever fed a u32 length)
        try self.asm_.push("_mc_i");
        try self.asm_.push("__c_i32_neg1");
        try self.asm_.push("_mc_cmp");
        try self.asm_.extern_("SystemInt32.__op_GreaterThan__SystemInt32_SystemInt32__SystemBoolean");
        try self.asm_.push("_mc_cmp");
        try self.asm_.jumpIfFalse(end_lbl);
        // _mc_addr_src := src + i ; _mc_addr_dst := dst + i
        try self.asm_.push("_mc_src");
        try self.asm_.push("_mc_i");
        try self.asm_.push("_mc_addr_src");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.push("_mc_dst");
        try self.asm_.push("_mc_i");
        try self.asm_.push("_mc_addr_dst");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.emitMemLoadByteAt("_mc_addr_src", "_mc_byte", ctx.fn_name, site_tag);
        try self.emitMemStoreByteAt("_mc_addr_dst", "_mc_byte", ctx.fn_name, site_tag);
        // i -= 1
        try self.asm_.push("_mc_i");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mc_i");
        try self.asm_.extern_("SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.jump(back_loop_lbl);

        try self.asm_.label(end_lbl);
    }

    /// `memory.fill` — forward byte-store loop. Stack: `(dst, val, n)`
    /// (top). No overlap concern (single range), so a single ascending
    /// loop suffices. The byte-store helper masks `val` to the low 8
    /// bits internally, so the full Int32 is forwarded as-is. Loop
    /// labels are uniqued via `block_counter`; the `_mf_*` scratch
    /// fields are shared across calls because each call body fully
    /// writes them before any read. Zero-length input naturally
    /// short-circuits at the first `i < n` test (i=0, n=0). See
    /// docs/spec_linear_memory.md §"memory.fill lowering".
    fn emitMemoryFill(self: *Translator, ctx: *FuncCtx, ins: anytype) Error!void {
        _ = ins;
        try self.asm_.comment("memory.fill (forward byte-store loop)");

        // Pop (n, val, dst) into `_mf_*` so they survive the byte-store
        // helper's clobbering of the shared `_mem_*` scratch.
        const n_slot = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        const val_slot = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        const dst_slot = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();

        // _mf_dst := dst ; _mf_val := val ; _mf_n := n
        try self.asm_.push(dst_slot);
        try self.asm_.push("_mf_dst");
        try self.asm_.copy();
        try self.asm_.push(val_slot);
        try self.asm_.push("_mf_val");
        try self.asm_.copy();
        try self.asm_.push(n_slot);
        try self.asm_.push("_mf_n");
        try self.asm_.copy();

        const id = self.block_counter;
        self.block_counter += 1;
        const loop_lbl = try std.fmt.allocPrint(self.aa(), "__memfill_loop_{d}__", .{id});
        const end_lbl = try std.fmt.allocPrint(self.aa(), "__memfill_end_{d}__", .{id});
        const site_tag = try std.fmt.allocPrint(self.aa(), "memory.fill_{d}", .{id});

        // i := 0
        try self.asm_.push("__c_i32_0");
        try self.asm_.push("_mf_i");
        try self.asm_.copy();

        try self.asm_.label(loop_lbl);
        // _mf_cmp := i < n
        try self.asm_.push("_mf_i");
        try self.asm_.push("_mf_n");
        try self.asm_.push("_mf_cmp");
        try self.asm_.extern_("SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean");
        try self.asm_.push("_mf_cmp");
        try self.asm_.jumpIfFalse(end_lbl);
        // _mf_addr := dst + i
        try self.asm_.push("_mf_dst");
        try self.asm_.push("_mf_i");
        try self.asm_.push("_mf_addr");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        // mem[dst+i] := val (helper masks to low 8 bits)
        try self.emitMemStoreByteAt("_mf_addr", "_mf_val", ctx.fn_name, site_tag);
        // i += 1
        try self.asm_.push("_mf_i");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mf_i");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.asm_.jump(loop_lbl);

        try self.asm_.label(end_lbl);
    }

    fn emitMemStore16(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        try self.asm_.comment("i32.store16");
        const memarg = ins.i32_store16;
        const val_i32 = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        const raw_addr = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        ctx.pop();

        try self.emitI32ToU32(val_i32, "_mem_val_u32_buf");
        const val = "_mem_val_u32_buf";

        try self.emitByteAccessPreamble(addr_slot, ctx.fn_name, "i32.store16");

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
        const raw_addr = try ctx.slotAt(self.aa(), ctx.depth - 1);
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
        // _mem_chunk := outer[page_idx] (bounds-checked)
        try self.recordMemOpSite(ctx.fn_name, addr_slot, "i64.load", "primary");
        try self.emitOuterGetChecked("_mem_page_idx");
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
        // hi chunk fetch: helper bounds-checks page+1 against max_pages
        // and routes to __mem_oob_trap__ on overflow.
        try self.recordMemOpSite(ctx.fn_name, addr_slot, "i64.load", "straddle_hi");
        try self.emitOuterGetChecked("_mem_page_idx_hi");
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
        try ctx.push(.i64);
        const dst = try ctx.slotAt(self.aa(), ctx.depth - 1);
        try self.asm_.push("_mem_i64_hi_shifted");
        try self.asm_.push("_mem_i64_lo");
        try self.asm_.push(dst);
        try self.asm_.extern_("SystemInt64.__op_LogicalOr__SystemInt64_SystemInt64__SystemInt64");
    }

    fn emitMemStoreI64(self: *Translator, ctx: *FuncCtx, ins: Instruction) Error!void {
        try self.asm_.comment("i64.store (aligned, within-chunk fast path)");
        const memarg = ins.i64_store;
        const val = try ctx.slotAt(self.aa(), ctx.depth - 1);
        ctx.pop();
        const raw_addr = try ctx.slotAt(self.aa(), ctx.depth - 1);
        const addr_slot = try self.applyMemOffset(raw_addr, memarg.offset);
        ctx.pop();

        // _mem_hi_i64 := val >> 32 (arithmetic; bit pattern for high word is what we want)
        try self.asm_.push(val);
        try self.asm_.push("__c_i32_32");
        try self.asm_.push("_mem_hi_i64");
        try self.asm_.extern_("SystemInt64.__op_RightShift__SystemInt64_SystemInt32__SystemInt64");
        // _mem_st_lo_i32 := low 32 bits of val (wrap, no overflow check). Must
        // use BitConverter — `SystemConvert.ToInt32(Int64)` is a *checked*
        // conversion that throws when val is outside Int32 range. WASM's
        // `i32.wrap_i64` is pure bit truncation.
        try self.emitI64TruncI32(val, "_mem_st_lo_i32");
        // _mem_st_hi_i32 := low 32 bits of (val >> 32) = original high 32 bits
        try self.emitI64TruncI32("_mem_hi_i64", "_mem_st_hi_i32");
        // Bit-pattern copy Int32 → UInt32 via BitConverter. Udon's COPY
        // only works between same-typed slots, so the previous heterogeneous
        // COPY threw "Cannot retrieve heap variable of type 'Int32' as type
        // 'UInt32'" at runtime.
        try self.emitI32ToU32("_mem_st_lo_i32", "_mem_st_lo_u32");
        try self.emitI32ToU32("_mem_st_hi_i32", "_mem_st_hi_u32");

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
        // outer[page_idx] → _mem_chunk (bounds-checked)
        try self.recordMemOpSite(ctx.fn_name, addr_slot, "i64.store", "primary");
        try self.emitOuterGetChecked("_mem_page_idx");
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
        // Straddle: hi word is outer[page_idx + 1][0]. The bounds check
        // lives inside emitOuterGetChecked; a failing page+1 lands in
        // __mem_oob_trap__ (LogError + halt). The PC-42856 crash this
        // guards against was the same class as the PC 221880 byte-store
        // crash on the lo-page path — both now share one checked helper.
        try self.asm_.push("_mem_page_idx");
        try self.asm_.push("__c_i32_1");
        try self.asm_.push("_mem_page_idx_hi");
        try self.asm_.extern_("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
        try self.recordMemOpSite(ctx.fn_name, addr_slot, "i64.store", "straddle_hi");
        try self.emitOuterGetChecked("_mem_page_idx_hi");
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
        .jumpAddr = jumpAddrFn,
        .storeI32 = storeI32Fn,
        .storeI32Offset = storeI32OffsetFn,
        .loadI32 = loadI32Fn,
        .loadI32Offset = loadI32OffsetFn,
        .marshalSystemString = marshalSystemStringFn,
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
    fn produceOne(ctx: *anyopaque, vt: ValType) lower_import.Error!void {
        // `FuncCtx.push` only actually fails on allocator errors (appending
        // to `stack_types` / `fn_slot_type_bits`); narrow the translator
        // error set here so the lower_import interface stays compact.
        self_(ctx).ctx.push(vt) catch return error.OutOfMemory;
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
    fn jumpAddrFn(ctx: *anyopaque, addr: u32) lower_import.Error!void {
        try self_(ctx).t.asm_.jumpAddr(addr);
    }
    fn storeI32Fn(ctx: *anyopaque, addr_slot: []const u8, val_slot: []const u8) lower_import.Error!void {
        const hb = self_(ctx);
        hb.t.emitWasiStoreI32(addr_slot, 0, val_slot) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfMemory,
        };
    }
    fn storeI32OffsetFn(ctx: *anyopaque, addr_slot: []const u8, offset: u32, val_slot: []const u8) lower_import.Error!void {
        const hb = self_(ctx);
        hb.t.emitWasiStoreI32(addr_slot, offset, val_slot) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfMemory,
        };
    }
    fn loadI32Fn(ctx: *anyopaque, addr_slot: []const u8, out_slot: []const u8) lower_import.Error!void {
        const hb = self_(ctx);
        hb.t.emitWasiLoadI32(addr_slot, 0, out_slot) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfMemory,
        };
    }
    fn loadI32OffsetFn(ctx: *anyopaque, addr_slot: []const u8, offset: u32, out_slot: []const u8) lower_import.Error!void {
        const hb = self_(ctx);
        hb.t.emitWasiLoadI32(addr_slot, offset, out_slot) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfMemory,
        };
    }
    fn marshalSystemStringFn(ctx: *anyopaque, ptr_slot: []const u8, len_slot: []const u8) lower_import.Error!void {
        try lower_import.emitStringMarshalPub(self_(ctx).host(), ptr_slot, len_slot);
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

fn slotTypeBit(vt: ValType) u8 {
    return switch (vt) {
        .i32 => 1,
        .i64 => 2,
        .f32 => 4,
        .f64 => 8,
    };
}

const all_val_types = [_]ValType{ .i32, .i64, .f32, .f64 };

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
    const meta_json = @embedFile("testdata/bench.udon_meta.json");
    const meta: ?wasm.UdonMeta = try wasm.parseUdonMeta(aa, meta_json);

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
    try std.testing.expect(std.mem.indexOf(u8, out, "UnityEngineDebug.__Log__SystemString__SystemVoid") != null);
    // Generic SystemString marshaling helper is declared once for all
    // string arguments regardless of which extern they target.
    try std.testing.expect(std.mem.indexOf(u8, out, "_marshal_str_tmp:") != null);
    // Regression guard: the old hardcoded placeholder must be gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "__cwl_placeholder__") == null);

    // ---- string-marshaling helper correctness ----
    // The encoding singleton must be declared and cached in _start.
    try std.testing.expect(std.mem.indexOf(u8, out, "_marshal_encoding_utf8:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemTextEncoding.__get_UTF8__SystemTextEncoding") != null);
    // A real byte array must be allocated and written into.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemByteArray.__ctor__SystemInt32__SystemByteArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemByteArray.__Set__SystemInt32_SystemByte__SystemVoid") != null);
    // GetString must be a non-static call: the encoding instance is
    // pushed immediately before the byte[] and the result slot.
    const gs_at = std.mem.indexOf(u8, out, "SystemTextEncoding.__GetString__SystemByteArray__SystemString").?;
    const prefix = out[0..gs_at];
    const this_at = std.mem.lastIndexOf(u8, prefix, "PUSH, _marshal_encoding_utf8").?;
    const bytes_at = std.mem.lastIndexOf(u8, prefix, "PUSH, _marshal_str_bytes").?;
    const tmp_at = std.mem.lastIndexOf(u8, prefix, "PUSH, _marshal_str_tmp").?;
    try std.testing.expect(this_at < bytes_at);
    try std.testing.expect(bytes_at < tmp_at);
    // Regression guard: the old 2-arg TODO stub must be gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "byte-copy from linear memory into _marshal_str_bytes — TODO") == null);

    // ---- call_indirect full ABI emitted ----
    // Bench's `ops` array puts 3+ functions in the WASM table; each becomes
    // an indirect-callable with an entry + trampoline, and every
    // call_indirect site dispatches through __fn_table__ / __indirect_target__.
    try std.testing.expect(std.mem.indexOf(u8, out, "__fn_table__") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_indirect_entry__:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_indirect_trampoline__:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "JUMP_INDIRECT, __indirect_target__") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32Array.__Get__SystemInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
    // Regression guard: the old "simplified — single shared indirect target"
    // comment must be gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "simplified — single shared indirect target") == null);

    // ---- memory infra was emitted ----
    // bench sets `options.memory.udonName = "_memory"`, so companion scalars
    // are renamed in lockstep per docs/spec_udonmeta_conversion.md §options.memory.
    try std.testing.expect(std.mem.indexOf(u8, out, "_memory_size_pages") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemObjectArray.__ctor__SystemInt32__SystemObjectArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array") != null);

    // ---- at least one i32 arithmetic op was emitted ----
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);

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
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemObjectArray.__GetValue__SystemInt32__SystemObject") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32Array.__Get__SystemInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
    // Subtraction and multiplication come from test_struct's rect_width and
    // point_area (when not fully folded). Multiplication is already covered
    // by test_arithmetic but its presence is reassuring.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemInt32.__op_Multiplication__SystemInt32_SystemInt32__SystemInt32") != null);

    // ---- PC-42856 regression guard ----
    // After Cycle 3, _onEnable must pre-materialize *every* page up to
    // max_pages — so a memory op against any valid page never sees a
    // null chunk. bench declares initial=17, max=17 via the data
    // segment floor, so at least 17 SystemUInt32Array.__ctor__ calls
    // must appear in _onEnable.
    const oeb = onEnableBody(out);
    const chunk_ctor = "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array";
    var chunk_count: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, oeb, from, chunk_ctor)) |ix| {
        chunk_count += 1;
        from = ix + chunk_ctor.len;
    }
    try std.testing.expect(chunk_count >= 17);
    // After Cycle 4, every `_mem_page_idx_hi` + 1 straddle path must
    // guard against OOB on the outer array via a LessThan against
    // `_memory_max_pages`. The alternate name (without `__G__`) is
    // selected here because bench's __udon_meta overrides the udon
    // name via `options.memory.udonName`.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PUSH, _memory_max_pages") != null);
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
    const meta_json = @embedFile("testdata/bench.udon_meta.json");
    const meta: ?wasm.UdonMeta = try wasm.parseUdonMeta(aa, meta_json);

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
    try std.testing.expect(std.mem.indexOf(u8, after, "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array") != null);
    // outer への設置
    try std.testing.expect(std.mem.indexOf(u8, after, "SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid") != null);
    // page counter の更新と、-1 (失敗時) のコンスタント
    // bench の __udon_meta で memory.udonName = "_memory" を指定しているので
    // companion スカラも lockstep で改名される。
    try std.testing.expect(std.mem.indexOf(u8, after, "_memory_size_pages") != null);

    // 未実装プレースホルダは残っていないこと
    try std.testing.expect(std.mem.indexOf(u8, after, "simplified: returns current pages, no real growth") == null);
}

// ----------------------------------------------------------------
// memory.copy lowering — overlap-safe byte loop with runtime direction
// check. Strategy: if dst <= src, copy ascending; otherwise descending.
// Both branches walk byte-by-byte, reusing the existing byte load/store
// helpers (after refactor into `emitMemLoadByteAt` / `emitMemStoreByteAt`).
// See docs/spec_linear_memory.md §"memory.copy lowering".
// ----------------------------------------------------------------

fn buildMemoryCopyOnceModule(a: std.mem.Allocator) !wasm.Module {
    const body = try a.alloc(Instruction, 5);
    body[0] = .{ .local_get = 0 }; // dst
    body[1] = .{ .local_get = 1 }; // src
    body[2] = .{ .local_get = 2 }; // n
    body[3] = .{ .memory_copy = .{ .src_mem = 0, .dst_mem = 0 } };
    body[4] = .return_;
    const params = [_]ValType{ .i32, .i32, .i32 };
    const results = [_]ValType{};
    return buildOneFuncMemModule(a, &params, &results, body);
}

test "memory.copy emits forward and backward loop labels with unique IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mod = try buildMemoryCopyOnceModule(a);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "__memcopy_fwd_loop_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__memcopy_back_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__memcopy_end_") != null);
}

test "memory.copy direction selection uses LessThanOrEqual before any loop label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mod = try buildMemoryCopyOnceModule(a);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const cmp_sig = "SystemInt32.__op_LessThanOrEqual__SystemInt32_SystemInt32__SystemBoolean";
    const cmp_idx = std.mem.indexOf(u8, out, cmp_sig) orelse return error.TestExpectedEqual;
    const fwd_idx = std.mem.indexOf(u8, out, "__memcopy_fwd_loop_") orelse return error.TestExpectedEqual;
    try std.testing.expect(cmp_idx < fwd_idx);
}

test "memory.copy reuses byte load/store helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mod = try buildMemoryCopyOnceModule(a);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // The byte-store helper writes via the canonical UInt32Array __Set
    // signature after the shift/mask RMW. Confirm the signature appears
    // inside the loop body (between the forward-loop label and the end
    // label).
    const fwd_marker = "__memcopy_fwd_loop_";
    const end_marker = "__memcopy_end_";
    const fwd_idx = std.mem.indexOf(u8, out, fwd_marker) orelse return error.TestExpectedEqual;
    const end_rel = std.mem.indexOf(u8, out[fwd_idx..], end_marker) orelse return error.TestExpectedEqual;
    const loop_body = out[fwd_idx .. fwd_idx + end_rel];

    try std.testing.expect(std.mem.indexOf(u8, loop_body, "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
    // The byte store goes through the RMW XOR-based mask invert.
    try std.testing.expect(std.mem.indexOf(u8, loop_body, "SystemUInt32.__op_LogicalXor__SystemUInt32_SystemUInt32__SystemUInt32") != null);
}

test "memory.copy: scratch fields are declared in data section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mod = try buildMemoryCopyOnceModule(a);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // Each scratch must be declared as a top-level data field once. Look
    // for the bare "<name>:" label form that the data-section emitter
    // uses.
    try std.testing.expect(std.mem.indexOf(u8, out, "_mc_i:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mc_addr_src:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mc_addr_dst:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mc_byte:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mc_n:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mc_dst:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mc_src:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mc_cmp:") != null);
}

test "memory.copy: two calls in one function reuse scratch but have unique labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 9);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .local_get = 2 };
    body[3] = .{ .memory_copy = .{ .src_mem = 0, .dst_mem = 0 } };
    body[4] = .{ .local_get = 0 };
    body[5] = .{ .local_get = 1 };
    body[6] = .{ .local_get = 2 };
    body[7] = .{ .memory_copy = .{ .src_mem = 0, .dst_mem = 0 } };
    body[8] = .return_;
    const params = [_]ValType{ .i32, .i32, .i32 };
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // Two distinct forward-loop label definitions must appear (definitions
    // end with `:` so they aren't confused with JUMP operand references).
    var def_count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.endsWith(u8, line, ":")) continue;
        if (std.mem.indexOf(u8, line, "__memcopy_fwd_loop_") != null) def_count += 1;
    }
    try std.testing.expect(def_count == 2);

    // Scratch declarations are shared — `_mc_i:` must appear exactly once.
    try std.testing.expect(countOccurrences(out, "_mc_i:") == 1);
    try std.testing.expect(countOccurrences(out, "_mc_n:") == 1);
}

test "memory.copy does not regress as __unsupported__" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mod = try buildMemoryCopyOnceModule(a);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "__unsupported__: memory_copy") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported: memory_copy") == null);
}

// ----------------------------------------------------------------
// memory.fill lowering — forward byte-store loop. Unlike memory.copy
// there is no overlap concern, so a single ascending loop suffices.
// See docs/spec_linear_memory.md §"memory.fill lowering".
// ----------------------------------------------------------------

fn buildMemoryFillOnceModule(a: std.mem.Allocator) !wasm.Module {
    const body = try a.alloc(Instruction, 5);
    body[0] = .{ .local_get = 0 }; // dst
    body[1] = .{ .local_get = 1 }; // val
    body[2] = .{ .local_get = 2 }; // n
    body[3] = .{ .memory_fill = .{ .mem = 0 } };
    body[4] = .return_;
    const params = [_]ValType{ .i32, .i32, .i32 };
    const results = [_]ValType{};
    return buildOneFuncMemModule(a, &params, &results, body);
}

test "memory.fill emits forward loop with byte store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mod = try buildMemoryFillOnceModule(a);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "__memfill_loop_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__memfill_end_") != null);
    // The byte-store helper terminates with the canonical UInt32Array __Set
    // signature after its shift/mask RMW.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
}

test "memory.fill: zero-length is a no-op tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mod = try buildMemoryFillOnceModule(a);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // The loop's `i < n` guard EXTERN must appear before any byte-store
    // EXTERN — proves the guard precedes the body, so n=0 short-circuits.
    const cmp_sig = "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean";
    const set_sig = "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid";
    const loop_lbl = "__memfill_loop_";
    const loop_idx = std.mem.indexOf(u8, out, loop_lbl) orelse return error.TestExpectedEqual;
    // Search for the cmp EXTERN and store EXTERN positions *after* the loop label.
    const tail = out[loop_idx..];
    const cmp_rel = std.mem.indexOf(u8, tail, cmp_sig) orelse return error.TestExpectedEqual;
    const set_rel = std.mem.indexOf(u8, tail, set_sig) orelse return error.TestExpectedEqual;
    try std.testing.expect(cmp_rel < set_rel);
}

test "memory.fill does not regress as __unsupported__" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mod = try buildMemoryFillOnceModule(a);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "__unsupported__: memory_fill") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported: memory_fill") == null);
}

test "memory.fill: scratch fields are declared in data section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mod = try buildMemoryFillOnceModule(a);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "_mf_n:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mf_val:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mf_dst:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mf_i:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mf_addr:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mf_cmp:") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);

    // store8 の placeholder が残っていないこと
    try std.testing.expect(std.mem.indexOf(u8, out, "i32.store8 (simplified shift/mask placeholder)") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "i32.load8 (simplified shift/mask placeholder)") == null);
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

    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32") != null);
}

// ---- post-MVP: sign-extension opcodes (0xC0..0xC4) ----
//
// `i32.extend8_s`, `i32.extend16_s`, `i64.extend8_s`, `i64.extend16_s`,
// `i64.extend32_s` lower as `(x << N) >> N` over the existing
// `__op_LeftShift__` / `__op_RightShift__` EXTERNs. The shift count constant
// `N` lives in a shared `__c_i32_<N>` data field (Int32 — both i32 and i64
// shift EXTERNs take Int32 for the RHS, see lower_numeric.zig lines 85–86).
// See docs/spec_numeric_instruction_lowering.md §4.

test "i32.extend8_s lowers to LeftShift 24 / RightShift 24 on SystemInt32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .i32_extend8_s;
    body[2] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const ls_sig = "SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32";
    const rs_sig = "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32";
    const ls_idx = std.mem.indexOf(u8, out, ls_sig) orelse return error.TestExpectedEqual;
    const rs_idx = std.mem.indexOf(u8, out, rs_sig) orelse return error.TestExpectedEqual;
    try std.testing.expect(ls_idx < rs_idx);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_24") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported") == null);
}

test "i32.extend16_s lowers to LeftShift 16 / RightShift 16 on SystemInt32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .i32_extend16_s;
    body[2] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const ls_sig = "SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32";
    const rs_sig = "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32";
    const ls_idx = std.mem.indexOf(u8, out, ls_sig) orelse return error.TestExpectedEqual;
    const rs_idx = std.mem.indexOf(u8, out, rs_sig) orelse return error.TestExpectedEqual;
    try std.testing.expect(ls_idx < rs_idx);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported") == null);
}

test "i64.extend8_s lowers to LeftShift 56 / RightShift 56 on SystemInt64 with i32 count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .i64_extend8_s;
    body[2] = .return_;
    const params = [_]ValType{.i64};
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const ls_sig = "SystemInt64.__op_LeftShift__SystemInt64_SystemInt32__SystemInt64";
    const rs_sig = "SystemInt64.__op_RightShift__SystemInt64_SystemInt32__SystemInt64";
    const ls_idx = std.mem.indexOf(u8, out, ls_sig) orelse return error.TestExpectedEqual;
    const rs_idx = std.mem.indexOf(u8, out, rs_sig) orelse return error.TestExpectedEqual;
    try std.testing.expect(ls_idx < rs_idx);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_56") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported") == null);
}

test "i64.extend16_s lowers to LeftShift 48 / RightShift 48 on SystemInt64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .i64_extend16_s;
    body[2] = .return_;
    const params = [_]ValType{.i64};
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const ls_sig = "SystemInt64.__op_LeftShift__SystemInt64_SystemInt32__SystemInt64";
    const rs_sig = "SystemInt64.__op_RightShift__SystemInt64_SystemInt32__SystemInt64";
    const ls_idx = std.mem.indexOf(u8, out, ls_sig) orelse return error.TestExpectedEqual;
    const rs_idx = std.mem.indexOf(u8, out, rs_sig) orelse return error.TestExpectedEqual;
    try std.testing.expect(ls_idx < rs_idx);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_48") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported") == null);
}

test "i64.extend32_s lowers to LeftShift 32 / RightShift 32 on SystemInt64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .i64_extend32_s;
    body[2] = .return_;
    const params = [_]ValType{.i64};
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const ls_sig = "SystemInt64.__op_LeftShift__SystemInt64_SystemInt32__SystemInt64";
    const rs_sig = "SystemInt64.__op_RightShift__SystemInt64_SystemInt32__SystemInt64";
    const ls_idx = std.mem.indexOf(u8, out, ls_sig) orelse return error.TestExpectedEqual;
    const rs_idx = std.mem.indexOf(u8, out, rs_sig) orelse return error.TestExpectedEqual;
    try std.testing.expect(ls_idx < rs_idx);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported") == null);
}

test "sign-extension does not regress as __unsupported__" {
    // Build one function exercising all 5 sign-extension opcodes and make
    // sure none of them fall through to the `__unsupported__` annotation
    // emitted by `emitUnsupported`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn(i32, i64) -> i64:
    //   local.get 0; i32.extend8_s; drop;
    //   local.get 0; i32.extend16_s; drop;
    //   local.get 1; i64.extend8_s; drop;
    //   local.get 1; i64.extend16_s; drop;
    //   local.get 1; i64.extend32_s;
    //   return
    const body = try a.alloc(Instruction, 16);
    body[0] = .{ .local_get = 0 };
    body[1] = .i32_extend8_s;
    body[2] = .drop;
    body[3] = .{ .local_get = 0 };
    body[4] = .i32_extend16_s;
    body[5] = .drop;
    body[6] = .{ .local_get = 1 };
    body[7] = .i64_extend8_s;
    body[8] = .drop;
    body[9] = .{ .local_get = 1 };
    body[10] = .i64_extend16_s;
    body[11] = .drop;
    body[12] = .{ .local_get = 1 };
    body[13] = .i64_extend32_s;
    body[14] = .return_;
    body[15] = .return_; // pad — ignored after the return above

    const params = [_]ValType{ .i32, .i64 };
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body[0..15]);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // The translator unconditionally declares an `__unsupported__` data
    // sink (see `emitCommonData`); we check for the *use* signals instead.
    // `emitUnsupported` always emits a `# TODO unsupported: <opname>`
    // comment plus an `ANNOTATION, __unsupported__` line, so absence of
    // both tells us no opcode in this body fell through.
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported") == null);
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

// ---- §5 nontrapping-fptoint (saturating truncation) ----
//
// The 8 `*.trunc_sat_*` opcodes lower through one of two shared helper
// subroutines (one per output bit width: i32 and i64). The helper body
// implements the WASM saturation semantics: NaN → 0, x ≤ low_clamp →
// INT_MIN (or 0 for unsigned), x ≥ high_clamp → INT_MAX (or UINT_MAX),
// otherwise plain `SystemConvert.__ToInt{32,64}__SystemDouble__*` truncation.
// f32 inputs are promoted to f64 at each call site so both helpers
// operate on a SystemDouble input slot. The helpers are reached via
// the existing RAC + JUMP_INDIRECT machinery
// (docs/spec_call_return_conversion.md).
// See docs/spec_numeric_instruction_lowering.md §5.

test "i32.trunc_sat_f32_s emits NaN guard, low/high clamp, then SystemConvert.ToInt32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .i32_trunc_sat_f32_s;
    body[2] = .return_;
    const params = [_]ValType{.f32};
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const ne_sig = "SystemDouble.__op_Inequality__SystemDouble_SystemDouble__SystemBoolean";
    const le_sig = "SystemDouble.__op_LessThanOrEqual__SystemDouble_SystemDouble__SystemBoolean";
    const ge_sig = "SystemDouble.__op_GreaterThanOrEqual__SystemDouble_SystemDouble__SystemBoolean";
    const cv_sig = "SystemConvert.__ToInt32__SystemDouble__SystemInt32";

    const ne_idx = std.mem.indexOf(u8, out, ne_sig) orelse return error.TestExpectedEqual;
    const le_idx = std.mem.indexOf(u8, out, le_sig) orelse return error.TestExpectedEqual;
    const ge_idx = std.mem.indexOf(u8, out, ge_sig) orelse return error.TestExpectedEqual;
    const cv_idx = std.mem.indexOf(u8, out, cv_sig) orelse return error.TestExpectedEqual;
    try std.testing.expect(ne_idx < le_idx);
    try std.testing.expect(le_idx < ge_idx);
    try std.testing.expect(ge_idx < cv_idx);
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported") == null);
}

test "i64.trunc_sat_f64_u uses zero as low clamp and __c_f64_uint64_max as high clamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .i64_trunc_sat_f64_u;
    body[2] = .return_;
    const params = [_]ValType{.f64};
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // Low clamp is the f64 zero constant; high clamp is __c_f64_uint64_max.
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_f64_zero") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_f64_uint64_max") != null);
    // Helper body uses the i64 SystemConvert variant.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemConvert.__ToInt64__SystemDouble__SystemInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported") == null);
}

test "f32 inputs route through f64.promote_f32 before saturation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .i32_trunc_sat_f32_u;
    body[2] = .return_;
    const params = [_]ValType{.f32};
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const promote_sig = "SystemConvert.__ToDouble__SystemSingle__SystemDouble";
    // Helpers are emitted after all function bodies, so the helper-entry
    // label's textual position is a stable upper bound on where the
    // call-site's lowering ends. Promotion must fire before the helper
    // body is laid out.
    const helper_label = "__rt_trunc_sat_to_i32__:";

    const promote_idx = std.mem.indexOf(u8, out, promote_sig) orelse return error.TestExpectedEqual;
    const helper_idx = std.mem.indexOf(u8, out, helper_label) orelse return error.TestExpectedEqual;
    try std.testing.expect(promote_idx < helper_idx);
}

test "trunc_sat helper subroutines emitted exactly once each" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // i32.trunc_sat_f32_s × 2 + i64.trunc_sat_f64_u × 1.
    const body = try a.alloc(Instruction, 8);
    body[0] = .{ .local_get = 0 };
    body[1] = .i32_trunc_sat_f32_s;
    body[2] = .drop;
    body[3] = .{ .local_get = 0 };
    body[4] = .i32_trunc_sat_f32_s;
    body[5] = .drop;
    body[6] = .{ .local_get = 1 };
    body[7] = .i64_trunc_sat_f64_u;
    const params = [_]ValType{ .f32, .f64 };
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // Helper entry labels appear exactly once each (definition only).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "__rt_trunc_sat_to_i32__:"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "__rt_trunc_sat_to_i64__:"));
}

test "trunc_sat does not regress as __unsupported__" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // All 8 trunc_sat opcodes in one function.
    const body = try a.alloc(Instruction, 24);
    body[0] = .{ .local_get = 0 };
    body[1] = .i32_trunc_sat_f32_s;
    body[2] = .drop;
    body[3] = .{ .local_get = 0 };
    body[4] = .i32_trunc_sat_f32_u;
    body[5] = .drop;
    body[6] = .{ .local_get = 1 };
    body[7] = .i32_trunc_sat_f64_s;
    body[8] = .drop;
    body[9] = .{ .local_get = 1 };
    body[10] = .i32_trunc_sat_f64_u;
    body[11] = .drop;
    body[12] = .{ .local_get = 0 };
    body[13] = .i64_trunc_sat_f32_s;
    body[14] = .drop;
    body[15] = .{ .local_get = 0 };
    body[16] = .i64_trunc_sat_f32_u;
    body[17] = .drop;
    body[18] = .{ .local_get = 1 };
    body[19] = .i64_trunc_sat_f64_s;
    body[20] = .drop;
    body[21] = .{ .local_get = 1 };
    body[22] = .i64_trunc_sat_f64_u;
    body[23] = .drop;
    const params = [_]ValType{ .f32, .f64 };
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported") == null);
    var it = std.mem.splitSequence(u8, out, "\n");
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "ANNOTATION") != null and
            std.mem.indexOf(u8, line, "__unsupported__") != null)
        {
            return error.TestExpectedEqual;
        }
    }
}

test "bench: i64 conversions dispatch via SystemConvert" {
    // README unimplemented item: "Some conversion opcodes".
    // bench の test_64bit_and_float / test_globals で:
    //   - @intCast(i32, r >> 32) / r & 0xFFFFFFFF → i32.wrap_i64 (BitConverter 経由に変更)
    //   - @as(i64, 0x1_0000_0000) + 5             → i64.extend_i32_u
    //
    // (f64 側の @intFromFloat(@floor(...)) は Zig のコンパイル時最適化で
    //  bench.wasm に残らないため、ここでは unary 形の SystemConvert が
    //  出ていることだけ検証する。)
    //
    // 注: `i32.wrap_i64` は `SystemConvert.ToInt32(Int64)` を使わない
    // (checked conversion なので Int32 範囲外で throw する)。BitConverter
    // 経由の bit truncation に書き換えた。
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // i32.wrap_i64 は BitConverter 経由で emit される
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemBitConverter.__GetBytes__SystemInt64__SystemByteArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemConvert.__ToInt64__SystemUInt32__SystemInt64") != null);
}

test "i64.extend_i32_u passes a UInt32 source, not a reused stack slot" {
    // Regression guard for "Cannot retrieve heap variable of type 'Int32'
    // as type 'UInt32'" at runtime on the `ToInt64(UInt32)` EXTERN.
    //
    // The generic unary branch used to push the current stack slot twice
    // (once as the UInt32 input and once as the Int64 output). When the
    // stack slot was an Int32 (the common case for `i64.extend_i32_u`
    // right after an `i32.or`), Udon's heap type check rejected the read
    // as "Int32 as UInt32". After the fix the input is routed through a
    // BitConverter-backed `_num_lhs_u32` (SystemUInt32) scratch and the
    // output lands in a fresh Int64 stack slot.
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // Walk the file and check: each `EXTERN, "...ToInt64__SystemUInt32..."`
    // must be preceded by `PUSH, _num_lhs_u32` (or the memory-load paths'
    // equivalent `_mem_u32` / `_mem_u32_hi` — both are declared UInt32).
    var it = std.mem.splitScalar(u8, out, '\n');
    var prev_push_1: []const u8 = "";
    var prev_push_2: []const u8 = "";
    const needle = "SystemConvert.__ToInt64__SystemUInt32__SystemInt64";
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, line, needle)) |_| {
            // The EXTERN's first PUSHed slot must be UInt32-typed. We
            // allow the three scratches the emitter currently produces:
            // `_num_lhs_u32` (numeric-op branch), `_mem_u32` / `_mem_u32_hi`
            // (i64.load straddle path).
            const src = std.mem.trim(u8, prev_push_2, " \t\r,");
            const ok = std.mem.endsWith(u8, src, "_num_lhs_u32") or
                std.mem.endsWith(u8, src, "_mem_u32") or
                std.mem.endsWith(u8, src, "_mem_u32_hi");
            if (!ok) {
                std.debug.print("bad ToInt64(UInt32) source: {s}\n", .{src});
                try std.testing.expect(false);
            }
            // And the source must not equal the destination: same-slot
            // lowering was the original defect.
            try std.testing.expect(!std.mem.eql(u8, prev_push_1, prev_push_2));
        }
        if (std.mem.startsWith(u8, line, "PUSH,")) {
            prev_push_2 = prev_push_1;
            prev_push_1 = line;
        }
    }
}

test "i64 comparisons update the stack slot type to i32 (bool-result)" {
    // Regression guard for stack-type bookkeeping across `i64.eq`,
    // `i64.gt_s` and friends. Pre-fix the binary branch popped only the
    // rhs, leaving `ctx.stack_types[lhs_depth]` stuck on i64 even though
    // WASM had pushed an i32 boolean at that position. A subsequent i32
    // op at the same depth then named the slot `__fn_Sd_i64__` (pushing
    // the i64-typed slot into SystemInt32 params) and the following
    // `i64.extend_i32_u` read that same Int64 slot as UInt32, throwing
    // "Cannot retrieve heap variable of type 'Int64' as type 'UInt32'"
    // (which appeared as the original bug's "Int32 as UInt32" report
    // because the un-fixed unary branch named the slot with the *pre-*
    // eq i32 type).
    //
    // After the fix the bool-result landing slot is re-named to `_i32__`
    // so the subsequent `SystemInt32.__op_LogicalOr__...` finds a
    // SystemInt32 slot and nothing downstream crosses the type check.
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // `SystemConvert.__ToInt32__SystemBoolean__SystemInt32` is the
    // universal BoolToI32 widening after every comparison. Its
    // destination slot (the PUSH immediately before the EXTERN) must
    // never be typed `_i64__` / `_f32__` / `_f64__` — the WASM type at
    // that point is always i32.
    var it = std.mem.splitScalar(u8, out, '\n');
    var prev: []const u8 = "";
    const needle = "SystemConvert.__ToInt32__SystemBoolean__SystemInt32";
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, line, needle)) |_| {
            const dst = std.mem.trim(u8, prev, " \t\r,");
            if (std.mem.endsWith(u8, dst, "_i64__") or
                std.mem.endsWith(u8, dst, "_f32__") or
                std.mem.endsWith(u8, dst, "_f64__"))
            {
                std.debug.print("BoolToI32 writes into non-i32 slot: {s}\n", .{dst});
                try std.testing.expect(false);
            }
        }
        if (std.mem.startsWith(u8, line, "PUSH,")) prev = line;
    }
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

    try std.testing.expect(std.mem.indexOf(u8, out, "SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid") != null);
    const cs_hits = std.mem.count(u8, out, "__call_stack__");
    try std.testing.expect(cs_hits >= 4);
    const top_hits = std.mem.count(u8, out, "__call_stack_top__");
    try std.testing.expect(top_hits >= 4);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemObjectArray.__GetValue__SystemInt32__SystemObject") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "JUMP_INDIRECT, __add_RA__") != null);
}

// Post-MVP "mutable-globals" proposal: a module-defined mutable global must
// be emitted as a normal Udon mutable data field, and `global.get` /
// `global.set` against it must lower without any `__unsupported__`
// annotation. The flag round-trips through the parser (verified in
// `src/wasm/module.zig` parser test "parseImportSection accepts mutable
// global import"); the translator does not filter on `mut`. This test
// pins that contract end-to-end.
test "mutable module-defined global emits as Udon mutable field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Single mutable i32 global, init = i32.const 0, exported as "counter".
    const ginit = try a.alloc(Instruction, 1);
    ginit[0] = .{ .i32_const = 0 };
    const globals = try a.alloc(wasm.module.Global, 1);
    globals[0] = .{
        .ty = .{ .valtype = .i32, .mut = .mutable },
        .init = ginit,
    };

    // fn tick() -> i32 : global.get 0 ; i32.const 1 ; i32.add ; global.set 0 ; global.get 0
    const results = try a.alloc(ValType, 1);
    results[0] = .i32;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = &.{}, .results = results };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    const body = try a.alloc(Instruction, 5);
    body[0] = .{ .global_get = 0 };
    body[1] = .{ .i32_const = 1 };
    body[2] = .i32_add;
    body[3] = .{ .global_set = 0 };
    body[4] = .{ .global_get = 0 };
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 2);
    exports[0] = .{ .name = "counter", .desc = .{ .global = 0 } };
    exports[1] = .{ .name = "tick", .desc = .{ .func = 0 } };

    const mod: wasm.Module = .{
        .types_ = types_,
        .funcs = funcs,
        .codes = codes,
        .globals = globals,
        .exports = exports,
    };

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // The exported global picks up the `__G__` prefix per
    // `docs/spec_variable_conversion.md`.
    try std.testing.expect(std.mem.indexOf(u8, out, "__G__counter") != null);
    // i32 → SystemInt32 mapping.
    try std.testing.expect(std.mem.indexOf(u8, out, "__G__counter: %SystemInt32") != null);
    // No `__unsupported__` ANNOTATION should remain — global.get/global.set
    // are fully lowered for mutable globals.
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

// Post-MVP mutable-globals: when an imported mutable global is paired with
// a `__udon_meta` field whose `source.kind = "import"` matches the
// `(module, name)` pair, the translator must use the meta-supplied
// `udon_name` for the backing slot — exactly as it does for immutable
// imports. This documents the host↔WASM boundary contract for shared
// mutable state (host writes the Udon field, WASM observes it via
// `global.get`).
test "mutable global imported with __udon_meta override resolves the import name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Imported mutable i32 global: env.host_counter
    const imports = try a.alloc(wasm.module.Import, 1);
    imports[0] = .{
        .module = "env",
        .name = "host_counter",
        .desc = .{ .global = .{ .valtype = .i32, .mut = .mutable } },
    };

    // fn read() -> i32 : global.get 0
    const results = try a.alloc(ValType, 1);
    results[0] = .i32;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = &.{}, .results = results };
    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;
    const body = try a.alloc(Instruction, 1);
    body[0] = .{ .global_get = 0 };
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };
    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "read", .desc = .{ .func = 0 } };

    const mod: wasm.Module = .{
        .types_ = types_,
        .funcs = funcs,
        .codes = codes,
        .imports = imports,
        .exports = exports,
    };

    const meta_fields = try a.alloc(wasm.udon_meta.Field, 1);
    meta_fields[0] = .{
        .key = "hostCounter",
        .source = .{ .kind = .import, .module = "env", .name = "host_counter" },
        .udon_name = "__G__host_counter",
        .sync = .{ .enabled = true, .mode = .none },
    };
    const meta: wasm.UdonMeta = .{ .version = 1, .fields = meta_fields };

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, meta, &buf.writer, .{});
    const out = buf.written();

    // The chosen meta `udon_name` must be the backing data slot, with the
    // i32 → SystemInt32 mapping preserved across the mutable boundary.
    try std.testing.expect(std.mem.indexOf(u8, out, "__G__host_counter: %SystemInt32") != null);
    // `read`'s `global.get 0` must reference that slot in the code section.
    const entry = std.mem.indexOf(u8, out, "__read_entry__").?;
    try std.testing.expect(std.mem.indexOf(u8, out[entry..], "__G__host_counter") != null);
}

// Runtime regression: WASM `select` (0x1B) must actually look at `cond`.
// The prior lowering treated `select` as "unconditional pass-through of
// v1", silently miscompiling every runtime path that depended on `v2`.
// In the bench this surfaced as a `page == max_pages` OOB trap inside
// Zig's compiler-synthesized `memcpy` helper, because stdlib
// pointer-select patterns (`dst = cond ? near_ptr : far_ptr`) always
// took `v1` regardless of the runtime condition — and when `v1` happened
// to be an end-of-memory sentinel (e.g. `memory_size * 65536`), the
// following store trapped with exactly `page = max`.
test "select: emits a conditional branch that picks between v1 and v2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn(v1: i32, v2: i32, cond: i32) -> i32
    //   local.get 0  ; v1
    //   local.get 1  ; v2
    //   local.get 2  ; cond
    //   select
    const params = try a.alloc(ValType, 3);
    params[0] = .i32;
    params[1] = .i32;
    params[2] = .i32;
    const results = try a.alloc(ValType, 1);
    results[0] = .i32;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params, .results = results };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .local_get = 2 };
    body[3] = .select;
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "pick", .desc = .{ .func = 0 } };

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

    // The old "simplified pass-through of v1" placeholder must be gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "simplified: unconditional pass-through of v1") == null);

    // A conditional branch must be emitted — no branch means we're not
    // actually looking at `cond`.
    try std.testing.expect(std.mem.indexOf(u8, out, "JUMP_IF_FALSE") != null);

    // The `cond != 0` → bool conversion must appear. The helper goes
    // through SystemConvert.ToBoolean, mirroring br_if / if.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemConvert.__ToBoolean__SystemInt32__SystemBoolean") != null);

    // The falsy path must COPY v2 over v1's slot. Locate the `select:`
    // comment and assert v2's slot (`S1_i32`) and v1's slot (`S0_i32`)
    // both appear after it (in that order as source then destination).
    const sel = std.mem.indexOf(u8, out, "select: result = cond ? v1 : v2").?;
    const tail = out[sel..];
    const push_v2 = std.mem.indexOf(u8, tail, "PUSH, __pick_S1_i32__").?;
    const push_v1 = std.mem.indexOf(u8, tail, "PUSH, __pick_S0_i32__").?;
    try std.testing.expect(push_v2 < push_v1);
    try std.testing.expect(std.mem.indexOf(u8, tail[push_v1..], "COPY") != null);
}

// Follow-up regression guarding against the specific bench.uasm symptom:
// the sequence `# select (simplified: unconditional pass-through of v1)`
// must never appear in bench output again.
test "bench: select is not lowered as unconditional pass-through" {
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "unconditional pass-through of v1") == null);
    // But bench does use `select` somewhere (the Zig stdlib pointer
    // select helpers), so the new lowering should produce select comments
    // and at least one JUMP_IF_FALSE that targets a `__*_sel_falsy_*`
    // label (the falsy-path branch emitted by `emitSelect`).
    try std.testing.expect(std.mem.indexOf(u8, out, "_sel_falsy_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_sel_merge_") != null);
}

// Runtime regression: `i32.wrap_i64` must NOT route through
// `SystemConvert.__ToInt32__SystemInt64__SystemInt32`, which is a checked
// conversion that throws for values outside the Int32 range. Observed in
// the wild during `i64.store` of a struct with adjacent 32-bit fields that
// LLVM combined into a single 8-byte store, producing a packed i64 value
// whose high word had a bit set above Int32.MaxValue.
test "i32.wrap_i64 uses BitConverter-based truncation, not SystemConvert.ToInt32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn(v: i64) -> i32 : local.get 0; i32.wrap_i64
    const params = try a.alloc(ValType, 1);
    params[0] = .i64;
    const results = try a.alloc(ValType, 1);
    results[0] = .i32;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params, .results = results };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    const body = try a.alloc(Instruction, 2);
    body[0] = .{ .local_get = 0 };
    body[1] = .i32_wrap_i64;
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "wrap", .desc = .{ .func = 0 } };

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

    // The checked conversion must be gone from the wrap emission.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemConvert.__ToInt32__SystemInt64__SystemInt32") == null);
    // A BitConverter GetBytes(Int64) followed by ToInt32(byte[], 0) must appear.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemBitConverter.__GetBytes__SystemInt64__SystemByteArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32") != null);
    // Sanity: our dedicated comment is emitted so the intent is clear in uasm.
    try std.testing.expect(std.mem.indexOf(u8, out, "i32.wrap_i64 (bit truncation via BitConverter)") != null);
}

// Bench-level guard: after this fix, bench.uasm must not emit
// `SystemConvert.__ToInt32__SystemInt64__SystemInt32` anywhere. Any new
// use would re-introduce the checked conversion that throws on legitimate
// values (the Phase B.2 `test_wl_slice_write` exception).
test "bench: no SystemConvert.ToInt32 from Int64 (checked conversion)" {
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemConvert.__ToInt32__SystemInt64__SystemInt32") == null);
}

// An `i64.const V` with V != 0 must not silently truncate to 0. Pre-fix,
// the emit path called `emitConst(ctx, null_literal, int64, ...)` — every
// non-zero i64 constant ended up as a SystemInt64 slot initialized to
// `null` (= 0L) because Udon spec §4.7 forbids Int64 literals in the data
// section. That broke `Writer.writeAll`'s slow-path `Error!usize` decode
// at `i64.const 32 i64.shr_u` + `i64.const 0x200000000 local.set`, which
// caused a 10-second VM timeout in Udon whenever `bufPrint` took the
// fixed-writer slow path.
//
// Post-fix: each distinct non-zero V is backed by a shared Int64 slot
// whose value is synthesized at `_onEnable` from two Int32 halves.
test "i64.const non-zero is synthesized at _onEnable from two Int32 halves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn() -> i64 : i64.const 0x200000000 ; end
    const params = try a.alloc(ValType, 0);
    const results = try a.alloc(ValType, 1);
    results[0] = .i64;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params, .results = results };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    const body = try a.alloc(Instruction, 1);
    body[0] = .{ .i64_const = 0x200000000 };
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "big_const", .desc = .{ .func = 0 } };

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

    // The pre-fix output would create a `__K_N: %SystemInt64, null` and
    // COPY from it. Post-fix the constant must be in a `__K64_N` slot,
    // paired with Int32 hi/lo halves carrying the actual bit pattern.
    // 0x200000000 has hi=2, lo=0.
    try std.testing.expect(std.mem.indexOf(u8, out, "__K64_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ": %SystemInt32, 2") != null);
    // The synthesis sequence must appear in _onEnable (the intro comment
    // is the canonical marker). This also guards against regressions that
    // leave `i64_const_inits` populated but never flush it.
    try std.testing.expect(std.mem.indexOf(u8, out, "64-bit constant slot init") != null);
    // Spot-check that the key EXTERN in the synthesis is present.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt64.__op_LeftShift__SystemUInt64_SystemInt32__SystemUInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt64.__op_LogicalOr__SystemUInt64_SystemUInt64__SystemUInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemConvert.__ToUInt64__SystemUInt32__SystemUInt64") != null);
}

// `i64.const 0` is a happy case because Udon's `null` literal means
// `default(Int64) = 0L`. A single shared slot (`__K64_zero`) is enough
// and no runtime synthesis is required. This test asserts we don't
// regress into emitting a per-constant init for every zero.
test "i64.const 0 uses shared __K64_zero slot with no runtime synthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const params = try a.alloc(ValType, 0);
    const results = try a.alloc(ValType, 1);
    results[0] = .i64;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params, .results = results };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    // Two i64.const 0; drop; then an i64.const 0 for the return.
    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .i64_const = 0 };
    body[1] = .drop;
    body[2] = .{ .i64_const = 0 };
    body[3] = .{ .i64_const = 0 };
    // Use the last as the return value; drop the second.
    // Actually simpler: one i64.const 0 return.
    const simple_body = try a.alloc(Instruction, 1);
    simple_body[0] = .{ .i64_const = 0 };
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = simple_body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "zero", .desc = .{ .func = 0 } };

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

    try std.testing.expect(std.mem.indexOf(u8, out, "__K64_zero") != null);
    // No synthesis sequence should be emitted for this test case (the
    // comment is only present when `i64_const_inits` is non-empty).
    try std.testing.expect(std.mem.indexOf(u8, out, "64-bit constant slot init") == null);
}

// f64.const has the same null-literal constraint as i64.const: Udon spec
// §4.7 forbids non-null `SystemDouble` initializers. The translator
// materializes each non-0.0 constant at `_onEnable` via the same hi/lo
// Int32 synthesis pipeline, terminating with `BitConverter.ToDouble`
// instead of `BitConverter.ToInt64`.
test "f64.const non-zero is synthesized at _onEnable as SystemDouble" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn() -> f64 : f64.const 3.14 ; end
    const params = try a.alloc(ValType, 0);
    const results = try a.alloc(ValType, 1);
    results[0] = .f64;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params, .results = results };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    const body = try a.alloc(Instruction, 1);
    body[0] = .{ .f64_const = 3.14 };
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "pi", .desc = .{ .func = 0 } };

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

    // The slot name must use the `__K64f_` prefix so it doesn't collide
    // with Int64 constants in the dedup map, and the declared type must
    // be SystemDouble (not SystemInt64).
    try std.testing.expect(std.mem.indexOf(u8, out, "__K64f_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ": %SystemDouble, null") != null);
    // Terminal conversion must be ToDouble, not ToInt64.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemBitConverter.__ToDouble__SystemByteArray_SystemInt32__SystemDouble") != null);
    // Synthesis shares infrastructure with i64 — the setup comment is
    // still present because the list is non-empty.
    try std.testing.expect(std.mem.indexOf(u8, out, "64-bit constant slot init") != null);

    // Verify the hi/lo halves match the bit pattern of 3.14.
    // @bitCast(3.14: f64) == 0x40091EB851EB851F,
    // hi = 0x40091EB8 = 1074339512, lo = 0x51EB851F = 1374389535.
    try std.testing.expect(std.mem.indexOf(u8, out, "_hi: %SystemInt32, 1074339512") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_lo: %SystemInt32, 1374389535") != null);
}

// `f64.const 0.0` (positive zero, all bits zero) takes the shared-slot
// path just like `i64.const 0`. `-0.0` has bit 63 set and must fall
// through to the synthesis path — this asserts that property so a
// careless optimization doesn't collapse the two zeros.
test "f64.const +0.0 uses __K64f_zero; -0.0 goes through synthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const params = try a.alloc(ValType, 0);
    const results = try a.alloc(ValType, 1);
    results[0] = .f64;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params, .results = results };

    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    // fn() -> f64: f64.const -0.0 ; end
    const body = try a.alloc(Instruction, 1);
    body[0] = .{ .f64_const = -0.0 };
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "negzero", .desc = .{ .func = 0 } };

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

    // -0.0 bit pattern is 0x8000000000000000 → hi = Int32.MinValue,
    // lo = 0. The synthesis must fire (non-zero bit pattern). Note that
    // `Literal.write` emits Int32.MinValue as the hex bit-pattern form
    // `0x80000000` (not the decimal `-2147483648`) because the Udon
    // Assembler's literal parser overflows on the decimal form — see
    // the test in `udon/asm.zig`.
    try std.testing.expect(std.mem.indexOf(u8, out, "64-bit constant slot init") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_hi: %SystemInt32, 0x80000000") != null);
    // And it must NOT just reuse the zero slot.
    try std.testing.expect(std.mem.indexOf(u8, out, "__K64f_zero") == null);
}

// Bench-level guard: the worked example that triggered the original
// hang now exercises two specific i64 constants — `32` (shift count)
// and `0x200000000` (`Error!WriteFailed` tag packed into the high 32
// bits of an `Error!usize`). Both must appear as initialized
// `__K64_*_hi` / `__K64_*_lo` Int32 pairs in bench.uasm, and the
// synthesis bootstrap in `_onEnable` must materialize them before any
// event body runs.
test "bench: Writer.writeAll-critical i64 constants are fully synthesized" {
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // i64.const 32 — shift count used by `i64.shr_u` on the packed
    // Error!usize return. hi=0, lo=32.
    try std.testing.expect(std.mem.indexOf(u8, out, "_lo: %SystemInt32, 32") != null);
    // i64.const 0x200000000 = 8589934592 — `error.WriteFailed` tag in
    // the high 32 bits. hi=2, lo=0.
    try std.testing.expect(std.mem.indexOf(u8, out, "_hi: %SystemInt32, 2") != null);
    // The init comment must be present exactly once at `_onEnable`.
    const marker = "# 64-bit constant slot init";
    const first = std.mem.indexOf(u8, out, marker) orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, out[first + marker.len ..], marker) == null);
}

// Negative guard: after fix, no `__K_N: %SystemInt64, null` COPY should
// originate from an `i64.const` emit site — that pattern is the pre-fix
// signature of the bug. All `i64.const` sites must route through
// `__K64_*` slots (shared or zero). Data-section Int64 slots for *stack
// temporaries* (`__fnN_SK_i64__`), *memory scratch* (`_mem_i64_*`), etc.
// are unrelated and still allowed — this test only forbids
// `__K_<digits>: %SystemInt64, null` which is how the old `emitConst`
// path spelled a broken i64 constant.
test "bench: no i64.const emits a stale __K_N Int64 null slot" {
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Match `__K_<digit>+: %SystemInt64, null`.
        const marker = "__K_";
        if (!std.mem.startsWith(u8, trimmed, marker)) continue;
        const rest = trimmed[marker.len..];
        var i: usize = 0;
        while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {}
        if (i == 0) continue; // not a numeric __K_ entry
        if (i == rest.len or rest[i] != ':') continue;
        // It's an `__K_<n>:` declaration. Forbid SystemInt64 here.
        if (std.mem.indexOf(u8, rest[i..], "%SystemInt64") != null) {
            std.debug.print("unexpected stale Int64 const slot: {s}\n", .{trimmed});
            try std.testing.expect(false);
        }
    }
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
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemObjectArray.__ctor__SystemInt32__SystemObjectArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, body, "SystemObjectArray.__GetValue__SystemInt32__SystemObject") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, body, "SystemObjectArray.__GetValue__SystemInt32__SystemObject") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, body, "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid") != null);
    // Byte-RMW path: mask-and-or over UInt32 (XOR is used to build ~mask).
    try std.testing.expect(std.mem.indexOf(u8, body, "SystemUInt32.__op_LogicalOr__SystemUInt32_SystemUInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "SystemUInt32.__op_LogicalAnd__SystemUInt32_SystemUInt32__SystemUInt32") != null);
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
    const gets = countOccurrences(body, "SystemObjectArray.__GetValue__SystemInt32__SystemObject");
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
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_eff_addr") != null);
    try expectOrdered(body_out, "_mem_eff_addr", "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32");

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
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
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

// Without an emitMemLoad16 the translator falls back to `__unsupported__`
// (a no-op annotation), pushing nothing onto the WASM stack. The next
// instruction then runs against a stale stack and Udon halts the
// UdonBehaviour at load time with no exception message. Encountered in
// the wild from `examples/wasm-bench-alloc-rs` (Rust `alloc::raw_vec`
// emits a 2-byte unsigned half-word load against the Vec pre-allocation
// table). Verify the synthesized lowering is present.
test "i32.load16_u synthesizes the half-word read (no __unsupported__ fallthrough)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i32_load16_u = .{ .@"align" = 1, .offset = 92 } };
    body[2] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // The unsupported sentinel must NOT appear — its presence at runtime
    // produces a stack-imbalance silent halt.
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported: i32_load16_u") == null);
    // The synthesis comment marks the new path.
    try std.testing.expect(std.mem.indexOf(u8, out, "i32.load16_u") != null);
    // The half-word mask 0xFFFF must be applied (vs the byte path's 0xFF).
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_u32_0xFFFF_32") != null);
    // Memarg offset still resolved through the standard helper.
    try std.testing.expect(std.mem.indexOf(u8, out, "__c_i32_off_92:") != null);
}

test "i32.load16_s sign-extends the half-word with shift-left/shift-right by 16" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i32_load16_s = .{ .@"align" = 1, .offset = 0 } };
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
    // The sign-extension uses `__c_i32_16` for both shifts (vs `__c_i32_24`
    // for the byte path). Just check the comment marker is correct here —
    // shift-count constants are shared with other lowerings so their
    // presence isn't unique to this op.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "i32.load16_s") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TODO unsupported") == null);
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
    const gets = countOccurrences(body_out, "SystemObjectArray.__GetValue__SystemInt32__SystemObject");
    try std.testing.expect(gets >= 2);
    // The straddle branch must advance the page index: a literal 1
    // Addition into `_mem_page_idx_hi` (or reuse of `_mem_word_in_page_hi`
    // for page+1) is acceptable — the shape we insist on is a `+ 1` that
    // feeds back into an outer `GetValue`.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
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
    const gets = countOccurrences(body_out, "SystemObjectArray.__GetValue__SystemInt32__SystemObject");
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

// ----------------------------------------------------------------
// Int32 ↔ UInt32 bit-pattern conversion — TDD for the PC 46852 crash.
//
// Follow-up to the offset fix: now that the program reaches further into
// bench, it halts on `SystemUInt32Array.__Set__` with
//   Cannot retrieve heap variable of type 'Int32' as type 'UInt32'.
// Linear-memory chunks are `SystemUInt32Array`, but WASM stack slots are
// declared `%SystemInt32`. Pushing an Int32 slot as the UInt32 `value`
// argument (or the mirror case — writing a UInt32 EXTERN result into an
// Int32 slot) violates Udon's strict heap typing.
//
// `SystemConvert.__ToUInt32__SystemInt32` throws OverflowException on
// negative values (0xDEADBEEF, any high-bit-set u32 constant that WASM
// treats as a valid i32), so the translator uses `SystemBitConverter` to
// preserve the bit pattern: `GetBytes(int) → ToUInt32(bytes, 0)` for
// store, and the mirror `GetBytes(uint) → ToInt32(bytes, 0)` for load.
// ----------------------------------------------------------------

test "i32.store converts Int32 value to UInt32 before SystemUInt32Array.__Set__" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .i32_store = .{ .@"align" = 2, .offset = 0 } };
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
    // BitConverter-based conversion must appear in the store sequence.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__GetBytes__SystemInt32__SystemByteArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32") != null);
    // A UInt32 scratch buffer must be the value passed to __Set__.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_val_u32_buf") != null);
    // Declarations must exist in the data section.
    try std.testing.expect(std.mem.indexOf(u8, out, "_mem_val_u32_buf:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mem_bits_ba:") != null);
}

test "i32.store8 converts Int32 value before UInt32 mask" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .i32_store8 = .{ .@"align" = 0, .offset = 0 } };
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
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_val_u32_buf") != null);
}

test "i32.store16 converts Int32 value before UInt32 mask" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .i32_store16 = .{ .@"align" = 1, .offset = 0 } };
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
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_mem_val_u32_buf") != null);
}

test "i64.store routes lo/hi via BitConverter instead of heterogeneous COPY" {
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
    // Two __GetBytes__SystemInt32__ calls (one per 32-bit half) must appear.
    const get_bytes = countOccurrences(body_out, "SystemBitConverter.__GetBytes__SystemInt32__SystemByteArray");
    try std.testing.expect(get_bytes >= 2);
    // The two UInt32 result slots must still be written via BitConverter's
    // ToUInt32, not via `COPY, _mem_st_lo_i32, _mem_st_lo_u32`.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32") != null);
    // A heterogeneous COPY from *_i32 → *_u32 must not survive.
    // (COPY appears as two PUSHes followed by the `COPY` op; we spot-check
    // the lo pair which used to be the culprit.)
    const bad_copy_pattern = "PUSH, _mem_st_lo_i32\n        PUSH, _mem_st_lo_u32\n        COPY";
    try std.testing.expect(std.mem.indexOf(u8, body_out, bad_copy_pattern) == null);
}

test "i32.load converts loaded UInt32 to Int32 before storing in Int32 stack slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i32_load = .{ .@"align" = 2, .offset = 0 } };
    body[2] = .drop;
    body[3] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    // Load path must route UInt32 → Int32 via BitConverter.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__GetBytes__SystemUInt32__SystemByteArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32") != null);
}

test "i32.load8_u converts UInt32 mask result to Int32 before dst" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i32_load8_u = .{ .@"align" = 0, .offset = 0 } };
    body[2] = .drop;
    body[3] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32") != null);
}

test "i32.load8_s still sign-extends after UInt32→Int32 conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .i32_load8_s = .{ .@"align" = 0, .offset = 0 } };
    body[2] = .drop;
    body[3] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32") != null);
    // Sign-extend must remain: `<< 24` then `>> 24` with SystemInt32 ops.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "__c_i32_24") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32") != null);
}

test "bench: no heterogeneous COPY from *_i32 to *_u32 remains" {
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // The specific pattern from the old emitMemStoreI64 that broke on
    // Udon's strict heap typing. Must not appear in the regenerated output.
    try std.testing.expect(std.mem.indexOf(u8, out, "PUSH, _mem_st_lo_i32\n        PUSH, _mem_st_lo_u32\n        COPY") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PUSH, _mem_st_hi_i32\n        PUSH, _mem_st_hi_u32\n        COPY") == null);
}

test "bench: every SystemUInt32Array.__Set__ value arg is a UInt32 slot" {
    // Walk every `EXTERN, "SystemUInt32Array.__Set__..."` and verify the
    // value (3rd PUSH above the EXTERN) names a slot that is typed UInt32
    // in the data section — not a raw `__<fn>_S<n>__` Int32 stack slot.
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // Collect UInt32-typed names from the data section. A decl line looks
    // like `    <name>: %SystemUInt32, 0` (possibly with trailing value).
    var uint32_names = std.StringHashMap(void).init(std.testing.allocator);
    defer uint32_names.deinit();
    var data_it = std.mem.splitScalar(u8, out, '\n');
    while (data_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, line, ": %SystemUInt32,") == null and
            std.mem.indexOf(u8, line, ": %SystemUInt32Array,") == null) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        try uint32_names.put(name, {});
    }

    // Now scan for the Set pattern. Each occurrence: 3 PUSHes then EXTERN.
    var lines_list: std.ArrayList([]const u8) = .empty;
    defer lines_list.deinit(std.testing.allocator);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |l| try lines_list.append(std.testing.allocator, l);

    var i: usize = 3;
    while (i < lines_list.items.len) : (i += 1) {
        const ln = std.mem.trim(u8, lines_list.items[i], " \t\r");
        if (std.mem.indexOf(u8, ln, "EXTERN, \"SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid\"") == null)
            continue;
        const val_line = std.mem.trim(u8, lines_list.items[i - 1], " \t\r");
        const prefix = "PUSH, ";
        if (!std.mem.startsWith(u8, val_line, prefix)) continue;
        const name = val_line[prefix.len..];
        if (uint32_names.contains(name)) continue;
        std.debug.print(
            "SystemUInt32Array.__Set__ called with non-UInt32 value `{s}` (line {d})\n",
            .{ name, i + 1 },
        );
        return error.TestExpectedEqual;
    }
}

// ----------------------------------------------------------------
// Numeric-op Int32↔UInt32 / Int64↔UInt64 type conversion — TDD for the
// PC 20396 crash. `emitNumericOp` previously pushed raw Int32/Int64
// stack slots into `SystemUInt32.__op_*` / `SystemUInt64.__op_*` EXTERN
// calls, which Udon rejects with "Cannot retrieve heap variable of type
// 'Int32' as type 'UInt32'". Every u32/u64 op must now route operands
// through BitConverter and convert any u32/u64 result back to the Int32/
// Int64 stack slot it lands in.
// ----------------------------------------------------------------

test "i32.gt_u converts Int32 operands to UInt32 via BitConverter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i32_gt_u;
    body[3] = .return_;
    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    // Both operands must be converted Int32 → UInt32 via BitConverter.
    const get_bytes = countOccurrences(body_out, "SystemBitConverter.__GetBytes__SystemInt32__SystemByteArray");
    try std.testing.expect(get_bytes >= 2);
    const to_uint32 = countOccurrences(body_out, "SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32");
    try std.testing.expect(to_uint32 >= 2);
    // The comparison's lhs/rhs push targets must be UInt32 scratch.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_num_lhs_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_num_rhs_u32") != null);
}

test "i32.div_u routes operands and result through BitConverter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i32_div_u;
    body[3] = .return_;
    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    // Operand conversion (Int32 → UInt32).
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToUInt32__SystemByteArray_SystemInt32__SystemUInt32") != null);
    // Result conversion (UInt32 → Int32).
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__GetBytes__SystemUInt32__SystemByteArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_num_res_u32") != null);
}

test "i32.shr_u converts only the UInt32 value operand, shift operand stays Int32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i32_shr_u;
    body[3] = .return_;
    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    // Exactly one Int32→UInt32 GetBytes (for the value, not the shift).
    const get_bytes_i32 = countOccurrences(body_out, "SystemBitConverter.__GetBytes__SystemInt32__SystemByteArray");
    try std.testing.expectEqual(@as(usize, 1), get_bytes_i32);
    // No `_num_rhs_u32` — shift operand remains Int32.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_num_rhs_u32") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_num_lhs_u32") != null);
}

test "i64.gt_u converts Int64 operands to UInt64 via BitConverter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i64_gt_u;
    body[3] = .return_;
    const params = [_]ValType{ .i64, .i64 };
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    const get_bytes = countOccurrences(body_out, "SystemBitConverter.__GetBytes__SystemInt64__SystemByteArray");
    try std.testing.expect(get_bytes >= 2);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToUInt64__SystemByteArray_SystemInt32__SystemUInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_num_lhs_u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_num_rhs_u64") != null);
}

test "i64.div_u routes both operands and result through Int64/UInt64 BitConverter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i64_div_u;
    body[3] = .return_;
    const params = [_]ValType{ .i64, .i64 };
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToUInt64__SystemByteArray_SystemInt32__SystemUInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__GetBytes__SystemUInt64__SystemByteArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToInt64__SystemByteArray_SystemInt32__SystemInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "_num_res_u64") != null);
}

test "i64.shr_u converts only the UInt64 value; shift operand stays Int32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i64_shr_u;
    body[3] = .return_;
    const params = [_]ValType{ .i64, .i32 };
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    // LHS must be converted Int64→UInt64 exactly once via BitConverter.
    const to_u64 = countOccurrences(body_out, "SystemBitConverter.__ToUInt64__SystemByteArray_SystemInt32__SystemUInt64");
    try std.testing.expectEqual(@as(usize, 1), to_u64);
    // The shift operand must stay in an Int32 slot — i.e. the narrowing path
    // is taken (ToInt32 via BitConverter) rather than UInt64 conversion.
    const to_i32 = countOccurrences(body_out, "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32");
    try std.testing.expectEqual(@as(usize, 1), to_i32);
    // No additional UInt64 conversion for the shift count.
    const to_u64_total = countOccurrences(body_out, "SystemBitConverter.__ToUInt64__SystemByteArray_SystemInt32__SystemUInt64");
    try std.testing.expectEqual(@as(usize, 1), to_u64_total);
}

test "i64.rem_u expansion routes operands and result through BitConverter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i64_rem_u;
    body[3] = .return_;
    const params = [_]ValType{ .i64, .i64 };
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    // Both operands converted to UInt64, final result converted back to Int64.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToUInt64__SystemByteArray_SystemInt32__SystemUInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter.__ToInt64__SystemByteArray_SystemInt32__SystemInt64") != null);
    // All three UInt64 ops (Division, Multiplication, Subtraction) still emitted.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemUInt64.__op_Division__SystemUInt64_SystemUInt64__SystemUInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemUInt64.__op_Multiplication__SystemUInt64_SystemUInt64__SystemUInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemUInt64.__op_Subtraction__SystemUInt64_SystemUInt64__SystemUInt64") != null);
}

// Gate test: every EXTERN signature emitted by the canonical bench module
// must exist in `docs/udon_nodes.txt`. UdonBehaviour validates EXTERN
// signatures against its static node list at load time and silently halts
// (`_isReady = false`, no events fired, only "VM execution errored, halted"
// log line) when one is missing. This caught the original i32.rem_u
// silent-halt bug — keep it green.
test "gate: every EXTERN emitted by bench resolves to a real Udon node" {
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);
    const node_list = @embedFile("testdata/udon_nodes.txt");

    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const prefix = "EXTERN, \"";
        const start = std.mem.indexOf(u8, line, prefix) orelse continue;
        const sig_start = start + prefix.len;
        const sig_end = std.mem.indexOfScalarPos(u8, line, sig_start, '"') orelse continue;
        const sig = line[sig_start..sig_end];
        if (std.mem.indexOf(u8, node_list, sig) == null) {
            std.debug.print(
                "missing Udon node (would silently halt UdonBehaviour at load): {s}\n",
                .{sig},
            );
            return error.MissingUdonNode;
        }
    }
}

// SystemUInt32.__op_Modulus__ is missing from Udon's node list, just like
// SystemUInt64.__op_Modulus__. The translator must expand i32.rem_u into
// the same a - (a/b)*b shape the i64 path already uses, otherwise the
// resulting program is silently rejected at UdonBehaviour load time
// (no exception message — a real bug encountered with Rust `(x as u32) % N`
// patterns inside `examples/wasm-bench-alloc-rs`'s string_concat scenario).
test "i32.rem_u expansion uses Division/Multiplication/Subtraction (Udon has no UInt32 Modulus)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i32_rem_u;
    body[3] = .return_;
    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // The forbidden missing-node signature must NOT appear anywhere in the
    // output — emitting it makes UdonBehaviour silently halt at load time.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32.__op_Modulus__SystemUInt32_SystemUInt32__SystemUInt32") == null);
    // The 3-EXTERN expansion must be present.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32.__op_Division__SystemUInt32_SystemUInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32.__op_Multiplication__SystemUInt32_SystemUInt32__SystemUInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemUInt32.__op_Subtraction__SystemUInt32_SystemUInt32__SystemUInt32") != null);
    // And the comment marker confirming the synthesis path was taken.
    try std.testing.expect(std.mem.indexOf(u8, out, "i32.rem_u (synthesized: a - (a/b)*b)") != null);
}

test "signed numeric ops do not emit BitConverter conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // i32.add + i64.mul — both signed, must keep the fast SystemInt{32,64}
    // path with no BitConverter overhead.
    const body = try a.alloc(Instruction, 5);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 0 };
    body[2] = .i32_add;
    body[3] = .drop;
    body[4] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    // No BitConverter within this body — signed ops use SystemInt32 directly.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemBitConverter") == null);
    // The Int32 Addition EXTERN must be present.
    try std.testing.expect(std.mem.indexOf(u8, body_out, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
}

test "bench: SystemUInt32/UInt64 op args never point to a raw Int32 stack slot" {
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // Collect every Udon name whose declared type is SystemUInt32 / SystemUInt64
    // (plus the known Int32 constants that are fine to push to `_SystemInt32__`
    // shift operands).
    var uint_names = std.StringHashMap(void).init(std.testing.allocator);
    defer uint_names.deinit();
    var data_it = std.mem.splitScalar(u8, out, '\n');
    while (data_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const markers = [_][]const u8{
            ": %SystemUInt32,",
            ": %SystemUInt64,",
            ": %SystemUInt32Array,",
            ": %SystemUInt64Array,",
        };
        var hit = false;
        for (markers) |m| {
            if (std.mem.indexOf(u8, line, m) != null) {
                hit = true;
                break;
            }
        }
        if (!hit) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        try uint_names.put(line[0..colon], {});
    }

    var lines_list: std.ArrayList([]const u8) = .empty;
    defer lines_list.deinit(std.testing.allocator);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |l| try lines_list.append(std.testing.allocator, l);

    // Ops whose argument list starts with SystemUInt32 / SystemUInt64 — the
    // first parameter is the one most frequently violated in practice. We
    // inspect 2 PUSHes before the EXTERN (2nd arg of binary, 1st arg of
    // binary, or receiver), and flag any that names an Int32 stack slot.
    var i: usize = 3;
    while (i < lines_list.items.len) : (i += 1) {
        const ln = std.mem.trim(u8, lines_list.items[i], " \t\r");
        const is_u32_op = std.mem.startsWith(u8, ln, "EXTERN, \"SystemUInt32.__op_") and
            std.mem.indexOf(u8, ln, "SystemUInt32_SystemUInt32") != null;
        const is_u64_op = std.mem.startsWith(u8, ln, "EXTERN, \"SystemUInt64.__op_") and
            std.mem.indexOf(u8, ln, "SystemUInt64_SystemUInt64") != null;
        if (!is_u32_op and !is_u64_op) continue;

        // Look back for the two operand PUSHes (skip the result PUSH just above).
        const prefix = "PUSH, ";
        const operand_lines = [_][]const u8{
            std.mem.trim(u8, lines_list.items[i - 3], " \t\r"),
            std.mem.trim(u8, lines_list.items[i - 2], " \t\r"),
        };
        const labels = [_][]const u8{ "lhs", "rhs" };
        for (operand_lines, labels) |pl, lbl| {
            if (!std.mem.startsWith(u8, pl, prefix)) continue;
            const name = pl[prefix.len..];
            if (uint_names.contains(name)) continue;
            if (std.mem.startsWith(u8, name, "__c_u32_") or
                std.mem.startsWith(u8, name, "__c_u64_")) continue;
            std.debug.print(
                "u32/u64 op at line {d} has {s} `{s}` (not a UInt scratch)\n",
                .{ i + 1, lbl, name },
            );
            return error.TestExpectedEqual;
        }
    }
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

// ----------------------------------------------------------------
// PC → line mapping (TDD tooling for runtime crashes).
//
// Udon VM's `UdonVMException` reports a Program Counter which is a
// *bytecode* offset from the start of the code section, not an assembly
// line number. Per docs/udon_specs.md §6.1 each emitted instruction has
// a fixed byte size:
//   NOP / POP / ANNOTATION / COPY            = 4 bytes
//   PUSH / JUMP / JUMP_IF_FALSE / EXTERN /
//     JUMP_INDIRECT                          = 8 bytes
// Labels, blank lines, comments contribute 0 bytes. `pcToLine` walks the
// code section once to locate the 1-based line number of the instruction
// that contains `pc`.
// ----------------------------------------------------------------

fn pcToLine(uasm: []const u8, pc: u32) ?usize {
    var it = std.mem.splitScalar(u8, uasm, '\n');
    var in_code: bool = false;
    var line_no: usize = 0;
    var cursor: u32 = 0;
    while (it.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!in_code) {
            if (std.mem.eql(u8, line, ".code_start")) in_code = true;
            continue;
        }
        if (std.mem.eql(u8, line, ".code_end")) return null;
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (std.mem.endsWith(u8, line, ":")) continue; // label-only line
        var end: usize = 0;
        while (end < line.len and line[end] != ',' and line[end] != ' ' and line[end] != '\t') : (end += 1) {}
        const op = line[0..end];
        const size: u32 = if (std.mem.eql(u8, op, "PUSH") or
            std.mem.eql(u8, op, "JUMP") or
            std.mem.eql(u8, op, "JUMP_IF_FALSE") or
            std.mem.eql(u8, op, "EXTERN") or
            std.mem.eql(u8, op, "JUMP_INDIRECT"))
            8
        else
            4;
        if (pc < cursor + size) return line_no;
        cursor += size;
    }
    return null;
}

test "pcToLine: 4/8-byte instruction sizes match Udon VM bytecode layout" {
    const sample =
        "some header\n" ++
        ".data_start\n" ++
        "foo: %SystemInt32, 0\n" ++
        ".data_end\n" ++
        ".code_start\n" ++
        "    # comment line\n" ++
        "    PUSH, _a\n" ++ // PC 0..7   (line 7)
        "some_label:\n" ++
        "    PUSH, _b\n" ++ // PC 8..15  (line 9)
        "    EXTERN, \"Foo.__bar__\"\n" ++ // PC 16..23 (line 10)
        "    NOP\n" ++ // PC 24..27 (line 11)
        "    POP\n" ++ // PC 28..31 (line 12)
        "    COPY\n" ++ // PC 32..35 (line 13)
        "    JUMP_INDIRECT, _rac\n" ++ // PC 36..43 (line 14)
        ".code_end\n";
    try std.testing.expectEqual(@as(?usize, 7), pcToLine(sample, 0));
    try std.testing.expectEqual(@as(?usize, 7), pcToLine(sample, 7));
    try std.testing.expectEqual(@as(?usize, 9), pcToLine(sample, 8));
    try std.testing.expectEqual(@as(?usize, 10), pcToLine(sample, 16));
    try std.testing.expectEqual(@as(?usize, 11), pcToLine(sample, 24));
    try std.testing.expectEqual(@as(?usize, 12), pcToLine(sample, 28));
    try std.testing.expectEqual(@as(?usize, 13), pcToLine(sample, 32));
    try std.testing.expectEqual(@as(?usize, 14), pcToLine(sample, 36));
    try std.testing.expectEqual(@as(?usize, 14), pcToLine(sample, 43));
    try std.testing.expectEqual(@as(?usize, null), pcToLine(sample, 44));
}

test "pcToLine: bench.wasm puts __Set__ and the 65528 straddle probe near each other" {
    // Anchor for the PC-42856 crash: the i64.store within-chunk fast path
    // emits `SystemUInt32Array.__Set__` and, shortly after, pushes
    // `__c_i32_65528` to probe whether the high half straddles the next
    // page. A regression that reorders or loses those instructions would
    // move the crash elsewhere — this test pins the adjacency so any
    // such change is caught.
    const bench = @embedFile("testdata/bench.wasm");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const mod = try wasm.parseModule(aa, bench);
    const meta_json = @embedFile("testdata/bench.udon_meta.json");
    const meta: ?wasm.UdonMeta = try wasm.parseUdonMeta(aa, meta_json);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, meta, &buf.writer, .{});
    const out = buf.written();

    const set_needle = "EXTERN, \"SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid\"";
    const thr_needle = "PUSH, __c_i32_65528";
    const set_idx = std.mem.indexOf(u8, out, set_needle) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, out[set_idx..], thr_needle) != null);
    // pcToLine must be strictly monotonic in pc: a well-formed mapping
    // over a real module should never regress as pc increases.
    var prev: usize = 0;
    var pc: u32 = 0;
    while (pc < 256) : (pc += 8) {
        const line = pcToLine(out, pc) orelse break;
        try std.testing.expect(line >= prev);
        prev = line;
    }
}

// ----------------------------------------------------------------
// Cycle 2 — outer array must be sized by max_pages, not initial_pages.
//
// Root cause pattern of the PC-42856 crash family: if the outer
// SystemObjectArray is allocated with `initial_pages` slots and any
// runtime access resolves a `_mem_page_idx >= initial_pages`, the VM
// throws ArgumentOutOfRangeException on the GetValue/SetValue call.
// The translator already uses `memory_max_pages_name` for the ctor
// (translate.zig emitMemoryInit), but this regression guard makes the
// contract testable so nobody silently reverts it.
// ----------------------------------------------------------------

test "emitMemoryInit: outer SystemObjectArray ctor is sized by max_pages, not initial_pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 1);
    body[0] = .return_;
    const params = [_]ValType{};
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const ctor = "SystemObjectArray.__ctor__SystemInt32__SystemObjectArray";
    const ctor_idx = std.mem.indexOf(u8, out, ctor) orelse return error.TestExpectedEqual;
    // The two PUSHes immediately before the ctor are: length slot,
    // then result slot. Scan backwards to find them.
    const window_start = if (ctor_idx > 512) ctor_idx - 512 else 0;
    const window = out[window_start..ctor_idx];
    // Must PUSH `__G__memory_max_pages` (the length operand) — not
    // `__G__memory_initial_pages`.
    try std.testing.expect(std.mem.indexOf(u8, window, "PUSH, __G__memory_max_pages") != null);
    try std.testing.expect(std.mem.indexOf(u8, window, "PUSH, __G__memory_initial_pages") == null);
}

// ----------------------------------------------------------------
// Cycle 4 — straddle paths must guard `outer.GetValue(page_idx + 1)`.
//
// Root cause of PC-42856: the i64.store within-chunk fast path
// unconditionally writes the lo word, then decides whether to take the
// straddle branch. In the straddle branch it computes
// `_mem_page_idx_hi = _mem_page_idx + 1` and calls
// `SystemObjectArray.__GetValue__` on the outer array at that index.
// When `_mem_page_idx` is the last valid page, `_mem_page_idx_hi`
// equals `_memory.Length` — `outer.GetValue(Length)` throws
// `ArgumentOutOfRangeException`.
//
// Fix: emit a runtime bounds check
//   `_mem_page_idx_hi < _memory_max_pages` before the OOB GetValue,
// and skip the hi write on failure. Dropping the hi word matches the
// current behavior at a runtime trap (WASM semantics), but does so
// without crashing the UdonBehaviour.
// ----------------------------------------------------------------

test "emitMemOobTrap: shared halt block logs via LogError and halts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 1);
    body[0] = .return_;
    const params = [_]ValType{};
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // The trap block must be present, push the message string, call
    // LogError, and halt with `JUMP, 0xFFFFFFFC`. Without all three,
    // bounds-check jumps would land on either nothing (label missing)
    // or continue executing (halt missing).
    try std.testing.expect(std.mem.indexOf(u8, out, "__mem_oob_trap__:") != null);
    const trap_idx = std.mem.indexOf(u8, out, "__mem_oob_trap__:") orelse return error.TestExpectedEqual;
    const trap_tail = out[trap_idx..];
    try std.testing.expect(std.mem.indexOf(u8, trap_tail, "PUSH, _mem_oob_msg") != null);
    try std.testing.expect(std.mem.indexOf(u8, trap_tail, "UnityEngineDebug.__LogError__SystemObject__SystemVoid") != null);
    try std.testing.expect(std.mem.indexOf(u8, trap_tail, "JUMP, 0xFFFFFFFC") != null);
    // The message data decl is a SystemString literal.
    try std.testing.expect(std.mem.indexOf(u8, out, "_mem_oob_msg:") != null);
}

test "emitMemStoreI64: straddle branch guards page_idx+1 against max_pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn(addr: i32, val: i64) void { local.get 0; local.get 1; i64.store; }
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
    const straddle_idx = std.mem.indexOf(u8, body_out, "msi_straddle_") orelse return error.TestExpectedEqual;
    // Past the straddle label, find the outer-array GetValue call — the
    // instruction that crashes without a bounds check.
    const after = body_out[straddle_idx..];
    const gv = "SystemObjectArray.__GetValue__SystemInt32__SystemObject";
    const gv_rel = std.mem.indexOf(u8, after, gv) orelse return error.TestExpectedEqual;
    // Between the straddle label and that GetValue there must be a
    // LessThan against `__G__memory_max_pages`, followed by a
    // JUMP_IF_FALSE that skips the hi write.
    const pre = after[0..gv_rel];
    try std.testing.expect(std.mem.indexOf(u8, pre, "PUSH, __G__memory_max_pages") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "JUMP_IF_FALSE") != null);
    // The trap target address resolves to `__mem_oob_trap__` after
    // layout. We can't match the concrete hex here, but cross-reference
    // against the trap label: if the JUMP_IF_FALSE address equals the
    // address appearing on the `__mem_oob_trap__:` line, the guard is
    // correctly wired. The dedicated "emitMemOobTrap" test pins the
    // trap block itself; here we only check that a JUMP_IF_FALSE is
    // present in the straddle guard preamble.
    try std.testing.expect(std.mem.indexOf(u8, out, "__mem_oob_trap__:") != null);
}

// ----------------------------------------------------------------
// Cycle 3 — every page in `[0, max_pages)` must have a materialized
// `SystemUInt32Array` chunk at `_onEnable` time.
//
// If `initial_pages < max_pages`, the previous translator left chunks
// [initial, max) null. A WASM program that writes to such a page
// without first calling `memory.grow` would see `outer.GetValue(p)`
// return null, and the subsequent `__Set__` throw on a null receiver.
// Per docs/spec_linear_memory.md the outer array is sized to max_pages
// for exactly this reason; the fix is to fill every slot with a real
// chunk up front. memory.grow still keeps `_memory_size_pages` accurate
// for any code that inspects WASM-visible size.
// ----------------------------------------------------------------

// ----------------------------------------------------------------
// i32.eqz regression — PC 43048 crash on bench.uasm.
//
// 旧実装では lower_numeric.zig が i32.eqz を `.unary` + インスタンスメソッド
// `SystemInt32.__Equals__SystemInt32__SystemBoolean` で扱っていたため、
// emitNumericOp の `.unary` 分岐が `push s; push s; extern` を emit していた。
// これは静的 2-引数 EXTERN 用の形式で、インスタンスメソッドが要求する
// 3 push (`this` + 引数 + 戻り値) に足りず、Udon VM が内部引数配列の
// 3 番目を取り出す段階で ArgumentOutOfRangeException を投げていた。
//
// 本テストは i32.eqz が静的 EXTERN `op_Equality` に対し
// `[stack_slot, __c_i32_0, stack_slot]` の 3 push で展開され、
// かつ旧 `__Equals__` シグネチャが出力に残らないことを保証する。
// ----------------------------------------------------------------

test "i32.eqz lowers as op_Equality with Boolean scratch and ToInt32 writeback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn probe(x: i32) -> i32 { local.get 0; i32.eqz; end }
    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .i32_eqz;
    body[2] = .return_;
    const params = [_]ValType{.i32};
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // Regression guard: the old instance-method signature must be gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemInt32.__Equals__SystemInt32__SystemBoolean") == null);

    // A dedicated Boolean scratch must be declared, since `op_Equality`
    // returns Boolean and Udon rejects writing a Boolean into an
    // Int32-typed heap slot ("Cannot retrieve heap variable of type
    // 'Boolean' as type 'Int32'").
    try std.testing.expect(std.mem.indexOf(u8, out, "_cmp_bool: %SystemBoolean, null") != null);

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    const eq_sig = "EXTERN, \"SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean\"";
    const eq_at = std.mem.indexOf(u8, body_out, eq_sig) orelse {
        std.debug.print("op_Equality extern not found in probe body:\n{s}\n", .{body_out});
        return error.TestExpectedEqual;
    };

    // Walk backwards from the EXTERN, collecting the 3 preceding PUSH operands.
    const prefix = body_out[0..eq_at];
    var it = std.mem.splitBackwardsScalar(u8, prefix, '\n');
    var pushes: [3][]const u8 = undefined;
    var filled: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "PUSH,")) {
            const arg = std.mem.trim(u8, line["PUSH,".len..], " \t");
            pushes[2 - filled] = arg;
            filled += 1;
            if (filled == 3) break;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), filled);

    // LHS = current stack slot (Int32), RHS = __c_i32_0 (Int32), return slot
    // = _cmp_bool (Boolean). The first and third must differ since the
    // return slot is now a Boolean scratch, not the Int32 stack slot.
    try std.testing.expectEqualStrings("__c_i32_0", pushes[1]);
    try std.testing.expectEqualStrings("_cmp_bool", pushes[2]);
    try std.testing.expect(!std.mem.eql(u8, pushes[0], pushes[2]));

    // Immediately after the EXTERN, the Boolean result is converted back to
    // Int32 (0/1) and stored into the LHS stack slot so WASM-visible
    // semantics (`i32.eqz`'s result is i32) are preserved.
    const tail = body_out[eq_at + eq_sig.len ..];
    const conv_sig = "EXTERN, \"SystemConvert.__ToInt32__SystemBoolean__SystemInt32\"";
    const conv_at = std.mem.indexOf(u8, tail, conv_sig) orelse {
        std.debug.print("ToInt32(Boolean) writeback not emitted after op_Equality:\n{s}\n", .{tail});
        return error.TestExpectedEqual;
    };
    const between = tail[0..conv_at];
    try std.testing.expect(std.mem.indexOf(u8, between, "PUSH, _cmp_bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, between, pushes[0]) != null);
}

test "i64.shr_u converts the Int64 shift count to Int32 before the EXTERN" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn probe(x: i64, n: i64) -> i64 { local.get 0; local.get 1; i64.shr_u; end }
    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i64_shr_u;
    body[3] = .return_;
    const params = [_]ValType{ .i64, .i64 };
    const results = [_]ValType{.i64};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);

    // A dedicated Int32 scratch for the shift count must be declared.
    try std.testing.expect(std.mem.indexOf(u8, out, "_shift_rhs_i32: %SystemInt32") != null);

    // Before the UInt64 RightShift EXTERN, the Int64 stack slot must be
    // routed through SystemConvert.ToInt32 — Udon's shift EXTERNs take
    // Int32 for the shift count, and the WASM stack slot holding the
    // count has its runtime type-tag bumped to Int64 the moment an i64
    // value is written into it.
    const ext = "EXTERN, \"SystemUInt64.__op_RightShift__SystemUInt64_SystemInt32__SystemUInt64\"";
    const ext_at = std.mem.indexOf(u8, body_out, ext) orelse return error.TestExpectedEqual;
    const prefix = body_out[0..ext_at];

    // The push right before the EXTERN destination (`_num_res_u64`) must be
    // `_shift_rhs_i32`, not a raw `__probe_S*__` slot.
    var it = std.mem.splitBackwardsScalar(u8, prefix, '\n');
    var pushes: [3][]const u8 = undefined;
    var filled: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "PUSH,")) {
            const arg = std.mem.trim(u8, line["PUSH,".len..], " \t");
            pushes[2 - filled] = arg;
            filled += 1;
            if (filled == 3) break;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), filled);
    try std.testing.expectEqualStrings("_num_lhs_u64", pushes[0]);
    try std.testing.expectEqualStrings("_shift_rhs_i32", pushes[1]);
    try std.testing.expectEqualStrings("_num_res_u64", pushes[2]);

    // The narrowing EXTERN must appear somewhere before the shift.
    // Note: `emitI64ToI32` was switched from the checked `SystemConvert.ToInt32`
    // to bit truncation via `emitI64TruncI32` (BitConverter-based) to avoid
    // the OverflowException on out-of-range i64 values. Shift counts happen to
    // always fit in Int32 so either path would work runtime-wise, but the
    // BitConverter path is now consistent with `i32.wrap_i64`.
    try std.testing.expect(std.mem.indexOf(u8, prefix, "SystemBitConverter.__GetBytes__SystemInt64__SystemByteArray") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32") != null);
}

test "i32.lt_s routes its Boolean result through _cmp_bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn probe(a: i32, b: i32) -> i32 { local.get 0; local.get 1; i32.lt_s; end }
    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .i32_lt_s;
    body[3] = .return_;
    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{.i32};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    const body_out = probeFnBody(out);
    try std.testing.expect(body_out.len > 0);
    const lt_sig = "EXTERN, \"SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean\"";
    const lt_at = std.mem.indexOf(u8, body_out, lt_sig) orelse return error.TestExpectedEqual;

    // The push immediately before the EXTERN must name the Boolean scratch,
    // not an Int32 stack slot. Udon rejects an Int32 slot as the return
    // destination of a Boolean-producing op.
    const prefix = body_out[0..lt_at];
    var it = std.mem.splitBackwardsScalar(u8, prefix, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "PUSH,")) {
            const arg = std.mem.trim(u8, line["PUSH,".len..], " \t");
            try std.testing.expectEqualStrings("_cmp_bool", arg);
            break;
        }
    }

    // A ToInt32(Boolean) writeback must follow, so the stack slot holds 0/1.
    const tail = body_out[lt_at + lt_sig.len ..];
    try std.testing.expect(std.mem.indexOf(u8, tail, "EXTERN, \"SystemConvert.__ToInt32__SystemBoolean__SystemInt32\"") != null);
}

test "if: Int32 cond is narrowed to Boolean before JUMP_IF_FALSE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn probe(x: i32) -> i32 {
    //   local.get 0;
    //   if (i32) { i32.const 1 } else { i32.const 2 };
    //   return;
    // }
    const then_body = try a.alloc(Instruction, 1);
    then_body[0] = .{ .i32_const = 1 };
    const else_body = try a.alloc(Instruction, 1);
    else_body[0] = .{ .i32_const = 2 };
    const body = try a.alloc(Instruction, 3);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .if_ = .{ .bt = .{ .value = .i32 }, .then_body = then_body, .else_body = else_body } };
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

    // The JUMP_IF_FALSE emitted for the `if` must be fed by `_cmp_bool`,
    // not by the raw Int32 stack slot. An Int32→Boolean narrowing via
    // `SystemConvert.__ToBoolean__SystemInt32__SystemBoolean` must appear
    // between the stack-slot push and the JUMP_IF_FALSE.
    const jif = "JUMP_IF_FALSE,";
    const jif_at = std.mem.indexOf(u8, body_out, jif) orelse return error.TestExpectedEqual;
    const prefix = body_out[0..jif_at];

    var it = std.mem.splitBackwardsScalar(u8, prefix, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "PUSH,")) {
            const arg = std.mem.trim(u8, line["PUSH,".len..], " \t");
            try std.testing.expectEqualStrings("_cmp_bool", arg);
            break;
        }
    }

    try std.testing.expect(std.mem.indexOf(u8, prefix, "SystemConvert.__ToBoolean__SystemInt32__SystemBoolean") != null);
}

test "bench: i32.eqz no longer emits the buggy instance-method Equals signature" {
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // Regression guard for the PC 43048 crash. The bench's test_recursion
    // path contains `if (n == 0)` which lowers through i32.eqz, so the
    // old bug-signature would appear at least once if the fix regresses.
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemInt32.__Equals__SystemInt32__SystemBoolean") == null);
}

test "emitMemoryInit: all max_pages chunks are materialized at _onEnable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 1);
    body[0] = .return_;
    const params = [_]ValType{};
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);
    // buildOneFuncMemModule uses .{ .min = 1, .max = null } — combined
    // with the translator's `default_max_pages = 16`, effective max
    // ends up at 16 while initial stays at 1. That's exactly the
    // initial<max shape we need to exercise.

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // The onEnable body is where memory init lives.
    const body_out = onEnableBody(out);
    // Count how many chunk ctors land in onEnable, which equals the
    // number of pages pre-materialized before any user event runs.
    const needle = "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array";
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, body_out, search_from, needle)) |idx| {
        count += 1;
        search_from = idx + needle.len;
    }
    // Exactly max_pages chunks — one per slot of the outer array.
    try std.testing.expectEqual(@as(usize, 16), count);
}

// ----------------------------------------------------------------
// emitOuterGetChecked: every runtime `outer[page_idx]` must be guarded
// against page_idx being negative or >= memory_max_pages. The PC 221880
// crash was an `i32.store8` whose dst page landed past the outer
// SystemObjectArray's upper bound; the VM threw
// "Index has to be between upper and lower bound of the array" with no
// diagnostic.
// ----------------------------------------------------------------

test "i32.store8 byte-access preamble runs through the bounds-checked helper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 4);
    body[0] = .{ .local_get = 0 };
    body[1] = .{ .local_get = 1 };
    body[2] = .{ .i32_store8 = .{ .@"align" = 0, .offset = 0 } };
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

    // Locate the byte-access preamble's GetValue on the outer array.
    // Immediately preceding it must be the two bounds checks emitted by
    // emitOuterGetChecked: LessThanOrEqual(0, page_idx) then
    // LessThan(page_idx, __G__memory_max_pages). Both followed by
    // JUMP_IF_FALSE to __mem_oob_trap__.
    const gv = "SystemObjectArray.__GetValue__SystemInt32__SystemObject";
    const gv_rel = std.mem.indexOf(u8, body_out, gv) orelse return error.TestExpectedEqual;
    const pre = body_out[0..gv_rel];
    try std.testing.expect(std.mem.indexOf(u8, pre, "SystemInt32.__op_LessThanOrEqual__SystemInt32_SystemInt32__SystemBoolean") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "PUSH, __G__memory_max_pages") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "JUMP_IF_FALSE") != null);

    // The trap block must exist so the JUMP_IF_FALSE has somewhere to
    // land.
    try std.testing.expect(std.mem.indexOf(u8, out, "__mem_oob_trap__:") != null);
}

test "aligned i32.load emits bounds-checked outer-array fetch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // align=2 routes to emitMemLoadWordFast — before the fix this
    // emitted a raw GetValue with no guard.
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

    const gv = "SystemObjectArray.__GetValue__SystemInt32__SystemObject";
    const gv_rel = std.mem.indexOf(u8, body_out, gv) orelse return error.TestExpectedEqual;
    const pre = body_out[0..gv_rel];
    try std.testing.expect(std.mem.indexOf(u8, pre, "SystemInt32.__op_LessThanOrEqual__SystemInt32_SystemInt32__SystemBoolean") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "PUSH, __G__memory_max_pages") != null);
}

test "data segment init stays bounds-check-free (translator-time verified)" {
    // Data segment pages are known statically; `translate()` already
    // rejects modules whose segments extend past max_pages. Routing
    // those through the runtime check would be dead code. This guards
    // that we haven't accidentally added a runtime check there.
    const out = try translateBench(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // Grab the onEnable body (which contains data segment init) and
    // check that no bounds-check pattern appears around the per-segment
    // page fetches. The pattern we added (_LessThanOrEqual on page_idx
    // vs __c_i32_0) is the distinctive marker — data segment fetches
    // push an immediate `__ds_page_<seg>_<page>` constant and go
    // straight into GetValue.
    const on_enable = onEnableBody(out);
    // Each segment emits `__ds_page_<seg>_<page>` constants — look for
    // at least one to confirm we're reading the right slice.
    try std.testing.expect(std.mem.indexOf(u8, on_enable, "__ds_page_0_16") != null);

    // Scan the onEnable body for every GetValue call, and assert that
    // the one preceded by `PUSH, __ds_page_0_16` is immediately after
    // a simple `PUSH, __G__memory / PUSH, __ds_page_... / PUSH, _mem_chunk`
    // triple (no LessThanOrEqual test in the 6 lines before it).
    const marker = "PUSH, __ds_page_0_16";
    const mkr_idx = std.mem.indexOf(u8, on_enable, marker) orelse return error.TestExpectedEqual;
    // Take a small window around the marker — 10 lines forward is
    // plenty for the push/push/push/extern GetValue that follows.
    const win_end = @min(on_enable.len, mkr_idx + 400);
    const win = on_enable[mkr_idx..win_end];
    try std.testing.expect(std.mem.indexOf(u8, win, "SystemObjectArray.__GetValue__SystemInt32__SystemObject") != null);
    // Crucially: no LessThanOrEqual check right before the GetValue,
    // meaning the data segment path bypasses the runtime bounds check.
    // Look ~50 chars before the GetValue inside this window.
    const gv_in_win = std.mem.indexOf(u8, win, "SystemObjectArray.__GetValue__SystemInt32__SystemObject") orelse return error.TestExpectedEqual;
    const lead_start = if (gv_in_win > 200) gv_in_win - 200 else 0;
    const lead = win[lead_start..gv_in_win];
    try std.testing.expect(std.mem.indexOf(u8, lead, "SystemInt32.__op_LessThanOrEqual__SystemInt32_SystemInt32__SystemBoolean") == null);
}

test "__mem_oob_trap__ builds a diagnostic message with page= and max=" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.alloc(Instruction, 1);
    body[0] = .return_;
    const params = [_]ValType{};
    const results = [_]ValType{};
    const mod = try buildOneFuncMemModule(a, &params, &results, body);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, null, &buf.writer, .{});
    const out = buf.written();

    // Label literals must appear in .data for the runtime Concat to
    // have valid operands.
    try std.testing.expect(std.mem.indexOf(u8, out, "_mem_oob_page_label:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_mem_oob_max_label:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"; page=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"; max=\"") != null);

    // Trap body must call Int32.ToString twice (for page and max) and
    // concat them together before the LogError.
    const trap_idx = std.mem.indexOf(u8, out, "__mem_oob_trap__:") orelse return error.TestExpectedEqual;
    const trap_tail = out[trap_idx..];
    const ts_first = std.mem.indexOf(u8, trap_tail, "SystemInt32.__ToString__SystemString") orelse return error.TestExpectedEqual;
    const ts_second = std.mem.indexOfPos(u8, trap_tail, ts_first + 1, "SystemInt32.__ToString__SystemString") orelse return error.TestExpectedEqual;
    _ = ts_second;
    try std.testing.expect(std.mem.indexOf(u8, trap_tail, "SystemString.__Concat__SystemString_SystemString_SystemString_SystemString__SystemString") != null);
    try std.testing.expect(std.mem.indexOf(u8, trap_tail, "UnityEngineDebug.__LogError__SystemObject__SystemVoid") != null);
}

// F3.1 — meta `type: object, default: "this"` on a global lowers the
// corresponding Udon data slot to `%SystemObject, this`. Without this,
// instance-method EXTERNs like `UnityEngineComponent.__get_transform` see a
// SystemInt32 as their `this` argument and the Udon VM halts.
test "meta field type=object default=\"this\" emits %SystemObject, this" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Single i32 mutable global, value 0.
    const global_init = try a.alloc(Instruction, 1);
    global_init[0] = .{ .i32_const = 0 };
    const globals = try a.alloc(wasm.module.Global, 1);
    globals[0] = .{
        .ty = .{ .valtype = .i32, .mut = .mutable },
        .init = global_init,
    };
    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "self", .desc = .{ .global = 0 } };

    const mod: wasm.Module = .{ .globals = globals, .exports = exports };

    const meta_fields = try a.alloc(wasm.udon_meta.Field, 1);
    meta_fields[0] = .{
        .key = "self",
        .source = .{ .kind = .global, .name = "self" },
        .udon_name = "__G__self",
        .type = .object,
        .default = std.json.Value{ .string = "this" },
    };
    const meta: wasm.UdonMeta = .{ .version = 1, .fields = meta_fields };

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, meta, &buf.writer, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "__G__self: %SystemObject, this") != null);
}

// F3.2 — meta `type: object` without `default` keeps `null` as initial.
// Regression guard: an incautious override could turn every object field
// into `this`, which is illegal for non-UdonBehaviour-compatible slots.
test "meta field type=object no default emits %SystemObject, null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const global_init = try a.alloc(Instruction, 1);
    global_init[0] = .{ .i32_const = 0 };
    const globals = try a.alloc(wasm.module.Global, 1);
    globals[0] = .{
        .ty = .{ .valtype = .i32, .mut = .mutable },
        .init = global_init,
    };
    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "handle", .desc = .{ .global = 0 } };

    const mod: wasm.Module = .{ .globals = globals, .exports = exports };

    const meta_fields = try a.alloc(wasm.udon_meta.Field, 1);
    meta_fields[0] = .{
        .key = "handle",
        .source = .{ .kind = .global, .name = "handle" },
        .udon_name = "__G__handle",
        .type = .object,
    };
    const meta: wasm.UdonMeta = .{ .version = 1, .fields = meta_fields };

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translate(std.testing.allocator, mod, meta, &buf.writer, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "__G__handle: %SystemObject, null") != null);
}

// F3.3 — `f32.store` / `f32.load` round-trip through the chunked linear
// memory via `SystemBitConverter.SingleToInt32Bits` and its inverse. The
// emitted uasm must contain both reinterpret externs and must NOT leave
// an `__unsupported__` annotation in the code section.
test "f32.store / f32.load round-trip via SystemBitConverter bridge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fn(f32) -> f32:
    //   i32.const 0            ;; address
    //   local.get 0            ;; value
    //   f32.store align=2 offset=0
    //   i32.const 0            ;; address
    //   f32.load  align=2 offset=0
    const params = try a.alloc(ValType, 1);
    params[0] = .f32;
    const results = try a.alloc(ValType, 1);
    results[0] = .f32;
    const types_ = try a.alloc(wasm.types.FuncType, 1);
    types_[0] = .{ .params = params, .results = results };
    const funcs = try a.alloc(u32, 1);
    funcs[0] = 0;

    const body = try a.alloc(Instruction, 5);
    body[0] = .{ .i32_const = 0 };
    body[1] = .{ .local_get = 0 };
    body[2] = .{ .f32_store = .{ .@"align" = 2, .offset = 0 } };
    body[3] = .{ .i32_const = 0 };
    body[4] = .{ .f32_load = .{ .@"align" = 2, .offset = 0 } };
    const codes = try a.alloc(wasm.module.Code, 1);
    codes[0] = .{ .locals = &.{}, .body = body };

    const exports = try a.alloc(wasm.module.Export, 1);
    exports[0] = .{ .name = "roundtrip", .desc = .{ .func = 0 } };

    const memories = try a.alloc(wasm.types.Limits, 1);
    memories[0] = .{ .min = 1, .max = 1 };

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

    try std.testing.expect(std.mem.indexOf(u8, out, "SystemBitConverter.__SingleToInt32Bits__SystemSingle__SystemInt32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SystemBitConverter.__Int32BitsToSingle__SystemInt32__SystemSingle") != null);

    // No `ANNOTATION, __unsupported__` should remain in the code section.
    const code_start = std.mem.indexOf(u8, out, ".code_start") orelse return error.TestExpectedEqual;
    const code_tail = out[code_start..];
    try std.testing.expect(std.mem.indexOf(u8, code_tail, "ANNOTATION, __unsupported__") == null);
}
