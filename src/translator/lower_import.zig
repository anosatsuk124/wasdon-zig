//! Host-import dispatch.
//!
//! Implements `docs/spec_host_import_conversion.md`. The core idea: if a
//! WASM import's `name` parses as an Udon extern signature, emit a direct
//! pass-through `EXTERN` call. No per-import tables.
//!
//! This module is intentionally a thin façade over the Translator's own asm
//! writer. It receives a `Host` struct with just the callbacks it needs so
//! the logic stays testable in isolation (the real Translator implements
//! `Host` by forwarding to its own members).

const std = @import("std");
const wasm = @import("wasm");
const udon = @import("udon");
const extern_sig = @import("extern_sig.zig");
const names = @import("names.zig");

const tn = udon.type_name;
const TypeName = tn.TypeName;
const ValType = wasm.types.ValType;

pub const Error = error{
    /// The import name was a parseable signature but its argument / return
    /// types don't match the WASM function signature.
    SignatureMismatch,
    /// The import name isn't a signature and no other dispatch rule matched.
    UnrecognizedImport,
} || std.mem.Allocator.Error;

/// Stack slot identified by its depth in the current function. The caller's
/// translator tracks the actual ValType for each depth; we only need to
/// name the slot for PUSH.
pub const Slot = struct {
    /// Udon variable name (owning). Produced by the caller via
    /// `names.stackSlot` / similar.
    name: []const u8,
};

/// The minimum surface the generic dispatcher needs from the translator.
/// Implemented by wrapping the concrete Translator's methods.
pub const Host = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Allocator for scratch (slot names, signature parse).
        allocator: *const fn (ctx: *anyopaque) std.mem.Allocator,

        /// Push an i32/uint32 data decl (returns its chosen variable name).
        /// Used for string-literal anonymous vars and scratch slots.
        declareScratch: *const fn (ctx: *anyopaque, name: []const u8, ty: TypeName, init: udon.asm_.Literal) Error!void,

        /// Caller's current function name (for slot naming).
        callerFnName: *const fn (ctx: *anyopaque) []const u8,

        /// Caller's current WASM stack depth (0-based count).
        callerDepth: *const fn (ctx: *anyopaque) u32,

        /// Decrement caller's stack depth by one (consume).
        consumeOne: *const fn (ctx: *anyopaque) void,

        /// Increment caller's stack depth by one (produce result) with the
        /// WASM value type that now occupies the new top-of-stack slot.
        /// The implementation uses this to name the typed physical slot
        /// (`__{fn}_S{d}_{vt}__`) and to drive typed-slot declarations.
        produceOne: *const fn (ctx: *anyopaque, vt: ValType) Error!void,

        /// Emit a PUSH, SYMBOL instruction.
        push: *const fn (ctx: *anyopaque, sym: []const u8) Error!void,

        /// Emit a COPY instruction.
        copy: *const fn (ctx: *anyopaque) Error!void,

        /// Emit an EXTERN, "sig" instruction.
        externCall: *const fn (ctx: *anyopaque, sig: []const u8) Error!void,

        /// Emit a comment line.
        comment: *const fn (ctx: *anyopaque, text: []const u8) Error!void,

        /// Emit ANNOTATION, __unsupported__.
        annotateUnsupported: *const fn (ctx: *anyopaque) Error!void,

        /// Emit a label definition (`name:`).
        label: *const fn (ctx: *anyopaque, name: []const u8) Error!void,

        /// Emit a JUMP, name instruction.
        jump: *const fn (ctx: *anyopaque, name: []const u8) Error!void,

        /// Emit a JUMP_IF_FALSE, name instruction.
        jumpIfFalse: *const fn (ctx: *anyopaque, name: []const u8) Error!void,

        /// Read a single byte from linear memory at address `addr_slot` into
        /// `out_slot` (a SystemByte scratch). The implementation delegates to
        /// the translator's shared byte-access preamble + shift/mask.
        readByteFromMemory: *const fn (ctx: *anyopaque, addr_slot: []const u8, out_slot: []const u8) Error!void,

        /// Monotonic counter for unique label-suffix tags. Every call must
        /// return a distinct `u32` for the lifetime of a translation unit.
        /// Used by `emitStringMarshal` so repeated string-taking externs don't
        /// collide on the same `__marshal_str_loop_<tag>__` label — the
        /// UAssembly assembler rejects duplicate labels at `VisitLabelStmt`.
        uniqueId: *const fn (ctx: *anyopaque) u32,
    };

    pub fn allocator(self: Host) std.mem.Allocator {
        return self.vtable.allocator(self.ctx);
    }
    pub fn declareScratch(self: Host, name: []const u8, ty: TypeName, init: udon.asm_.Literal) Error!void {
        return self.vtable.declareScratch(self.ctx, name, ty, init);
    }
    pub fn callerFnName(self: Host) []const u8 {
        return self.vtable.callerFnName(self.ctx);
    }
    pub fn callerDepth(self: Host) u32 {
        return self.vtable.callerDepth(self.ctx);
    }
    pub fn consumeOne(self: Host) void {
        return self.vtable.consumeOne(self.ctx);
    }
    pub fn produceOne(self: Host, vt: ValType) Error!void {
        return self.vtable.produceOne(self.ctx, vt);
    }
    pub fn push(self: Host, sym: []const u8) Error!void {
        return self.vtable.push(self.ctx, sym);
    }
    pub fn copy(self: Host) Error!void {
        return self.vtable.copy(self.ctx);
    }
    pub fn externCall(self: Host, sig: []const u8) Error!void {
        return self.vtable.externCall(self.ctx, sig);
    }
    pub fn comment(self: Host, text: []const u8) Error!void {
        return self.vtable.comment(self.ctx, text);
    }
    pub fn annotateUnsupported(self: Host) Error!void {
        return self.vtable.annotateUnsupported(self.ctx);
    }
    pub fn label(self: Host, name: []const u8) Error!void {
        return self.vtable.label(self.ctx, name);
    }
    pub fn jump(self: Host, name: []const u8) Error!void {
        return self.vtable.jump(self.ctx, name);
    }
    pub fn jumpIfFalse(self: Host, name: []const u8) Error!void {
        return self.vtable.jumpIfFalse(self.ctx, name);
    }
    pub fn readByteFromMemory(self: Host, addr_slot: []const u8, out_slot: []const u8) Error!void {
        return self.vtable.readByteFromMemory(self.ctx, addr_slot, out_slot);
    }
    pub fn uniqueId(self: Host) u32 {
        return self.vtable.uniqueId(self.ctx);
    }
};

/// Shared scratch variable names for `SystemString` marshaling. Declared
/// once per translation unit (the Host's `declareScratch` is idempotent on
/// the variable name).
pub const marshal_str_ptr_name = "_marshal_str_ptr";
pub const marshal_str_len_name = "_marshal_str_len";
pub const marshal_str_bytes_name = "_marshal_str_bytes";
pub const marshal_str_tmp_name = "_marshal_str_tmp";
pub const marshal_str_i_name = "_marshal_str_i";
pub const marshal_str_addr_name = "_marshal_str_addr";
pub const marshal_str_byte_name = "_marshal_str_byte";
pub const marshal_str_cond_name = "_marshal_str_cond";
pub const marshal_encoding_name = "_marshal_encoding_utf8";

/// Static property getter that caches the UTF-8 encoding singleton.
pub const utf8_property_sig =
    "SystemTextEncoding.__get_UTF8__SystemTextEncoding";

/// EXTERN signature for "UTF-8 byte array → System.String" on a UTF-8
/// encoding instance. `SystemTextEncoding.GetString(byte[])` is a non-static
/// method; see `docs/udon_specs.md` §6.2.6 — the encoding instance is
/// pushed first as `this`, then the byte[] arg, then the out-string slot.
pub const utf8_decode_sig =
    "SystemTextEncoding.__GetString__SystemByteArray__SystemString";

/// Given a WASM import and its function type, emit the appropriate Udon
/// assembly at the current call site. Returns an error if the import is
/// neither a pass-through signature nor otherwise recognized.
pub fn emit(
    host: Host,
    imp: wasm.module.Import,
    imp_ty: wasm.types.FuncType,
) Error!void {
    const alloc = host.allocator();

    if (try extern_sig.parse(alloc, imp.name)) |sig| {
        try emitGenericExtern(host, sig, imp_ty);
        return;
    }
    // (Future) rule 2: try module+"."+name as a signature.
    try emitUnsupported(host, imp);
}

fn emitUnsupported(host: Host, imp: wasm.module.Import) Error!void {
    const alloc = host.allocator();
    const msg = try std.fmt.allocPrint(alloc, "unsupported import: {s}.{s}", .{ imp.module, imp.name });
    try host.comment(msg);
    try host.annotateUnsupported();
}

fn emitGenericExtern(
    host: Host,
    sig: extern_sig.Signature,
    imp_ty: wasm.types.FuncType,
) Error!void {
    const alloc = host.allocator();

    // Validate that the WASM parameter sequence matches the Udon argument
    // list under the type-mapping rules.
    const wasm_param_count_expected = expectedWasmParamCount(sig.args);
    if (wasm_param_count_expected != imp_ty.params.len) {
        try host.comment(try std.fmt.allocPrint(
            alloc,
            "signature {s} expects {d} WASM params, import has {d}",
            .{ sig.raw, wasm_param_count_expected, imp_ty.params.len },
        ));
        return error.SignatureMismatch;
    }

    // Declare marshaling scratch slots on demand. `declareScratch` is
    // idempotent on name collision, so it's safe to call per invocation.
    const has_string = hasSystemStringArg(sig.args);
    if (has_string) try declareMarshalScratch(host);

    // We walk the WASM parameter list left-to-right. Args go on the WASM
    // value stack in reading order, so the top of the stack is the *last*
    // arg. The current depth just before the call is:
    //     D = caller_depth
    // and the arg positions (bottom to top) are D-N .. D-1 where N is the
    // total WASM params consumed.
    const n_wasm_params: u32 = @intCast(imp_ty.params.len);
    const base_depth = host.callerDepth() - n_wasm_params;

    // For each Udon arg, determine which WASM slot(s) correspond, then
    // either PUSH them directly or run the marshaling helper to produce a
    // scratch-slot name that we PUSH instead.
    var pushed_args: std.ArrayList([]const u8) = .empty;
    defer pushed_args.deinit(alloc);

    var wasm_cursor: u32 = 0;
    for (sig.args) |arg| {
        switch (arg.kind) {
            .direct => {
                const slot_depth = base_depth + wasm_cursor;
                const vt = imp_ty.params[wasm_cursor];
                const slot_name = try names.stackSlot(alloc, host.callerFnName(), slot_depth, vt);
                try pushed_args.append(alloc, slot_name);
                wasm_cursor += 1;
            },
            .marshal_string => {
                // (ptr, len) → SystemString in _marshal_str_tmp.
                // Both slots are i32 by WASM convention — an i32 byte
                // pointer and an i32 length.
                const ptr_depth = base_depth + wasm_cursor;
                const len_depth = base_depth + wasm_cursor + 1;
                const ptr_name = try names.stackSlot(alloc, host.callerFnName(), ptr_depth, .i32);
                const len_name = try names.stackSlot(alloc, host.callerFnName(), len_depth, .i32);
                try emitStringMarshal(host, ptr_name, len_name);
                try pushed_args.append(alloc, marshal_str_tmp_name);
                wasm_cursor += 2;
            },
        }
    }

    // Result slot (when non-void): we'll PUSH a scratch result slot as the
    // trailing "out" param. For pass-through simplicity we declare a
    // signature-specific result slot and then, after the EXTERN, COPY the
    // result into the caller's newly-produced stack slot.
    var result_scratch: ?[]const u8 = null;
    if (!std.mem.eql(u8, sig.result, "SystemVoid")) {
        const rty = udonTypeFor(sig.result);
        const rname = try std.fmt.allocPrint(alloc, "__ext_ret_{x}__", .{hashStr(sig.raw)});
        try host.declareScratch(rname, rty, zeroLiteralFor(rty));
        result_scratch = rname;
    }

    // Emit the comment header for readability.
    try host.comment(try std.fmt.allocPrint(alloc, "extern: {s}", .{sig.raw}));

    // PUSH args in order.
    for (pushed_args.items) |arg_sym| try host.push(arg_sym);
    if (result_scratch) |rs| try host.push(rs);

    try host.externCall(resolveSignatureAlias(sig.raw));

    // Update stack.
    var i: u32 = 0;
    while (i < n_wasm_params) : (i += 1) host.consumeOne();
    if (result_scratch) |rs| {
        // `imp_ty.results.len <= 1` for Core 1 WASM, enforced earlier.
        const result_vt = imp_ty.results[0];
        try host.produceOne(result_vt);
        const dst_depth = host.callerDepth() - 1;
        const dst_name = try names.stackSlot(alloc, host.callerFnName(), dst_depth, result_vt);
        try host.push(rs);
        try host.push(dst_name);
        try host.copy();
    }
}

fn emitStringMarshal(host: Host, ptr_slot: []const u8, len_slot: []const u8) Error!void {
    const alloc = host.allocator();
    try host.comment("marshal SystemString from (ptr, len)");
    try host.push(ptr_slot);
    try host.push(marshal_str_ptr_name);
    try host.copy();
    try host.push(len_slot);
    try host.push(marshal_str_len_name);
    try host.copy();

    // Allocate _marshal_str_bytes := new byte[_marshal_str_len].
    try host.push(marshal_str_len_name);
    try host.push(marshal_str_bytes_name);
    try host.externCall("SystemByteArray.__ctor__SystemInt32__SystemByteArray");

    // Byte-copy loop: for i in 0..len { bytes[i] = memory[ptr + i] }.
    // Tag the labels with a monotonic id — the same (ptr_slot, len_slot) pair
    // can legitimately appear across multiple calls within one function (the
    // WASM locals that hold the args get reused), so a name-derived hash
    // collides and trips the `Duplicate label` assembler exception.
    const tag: u32 = host.uniqueId();
    const loop_head = try std.fmt.allocPrint(alloc, "__marshal_str_loop_{x}__", .{tag});
    const loop_end = try std.fmt.allocPrint(alloc, "__marshal_str_end_{x}__", .{tag});

    // i := 0
    try host.push("__c_i32_0");
    try host.push(marshal_str_i_name);
    try host.copy();

    try host.label(loop_head);
    // cond := (i < len) — emit as (!(i >= len)) via JUMP_IF_FALSE.
    try host.push(marshal_str_i_name);
    try host.push(marshal_str_len_name);
    try host.push(marshal_str_cond_name);
    try host.externCall("SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean");
    try host.push(marshal_str_cond_name);
    try host.jumpIfFalse(loop_end);

    // addr := ptr + i
    try host.push(marshal_str_ptr_name);
    try host.push(marshal_str_i_name);
    try host.push(marshal_str_addr_name);
    try host.externCall("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");

    // _marshal_str_byte := memory[addr]
    try host.readByteFromMemory(marshal_str_addr_name, marshal_str_byte_name);

    // bytes[i] := _marshal_str_byte
    try host.push(marshal_str_bytes_name);
    try host.push(marshal_str_i_name);
    try host.push(marshal_str_byte_name);
    try host.externCall("SystemByteArray.__Set__SystemInt32_SystemByte__SystemVoid");

    // i := i + 1
    try host.push(marshal_str_i_name);
    try host.push("__c_i32_1");
    try host.push(marshal_str_i_name);
    try host.externCall("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");

    try host.jump(loop_head);
    try host.label(loop_end);

    // Decode as UTF-8: encoding.GetString(bytes) → tmp.
    // Instance call: first PUSH is `this` (the UTF-8 encoding singleton).
    try host.push(marshal_encoding_name);
    try host.push(marshal_str_bytes_name);
    try host.push(marshal_str_tmp_name);
    try host.externCall(utf8_decode_sig);
}

fn declareMarshalScratch(host: Host) Error!void {
    try host.declareScratch(marshal_str_ptr_name, tn.int32, .{ .int32 = 0 });
    try host.declareScratch(marshal_str_len_name, tn.int32, .{ .int32 = 0 });
    try host.declareScratch(marshal_str_bytes_name, tn.byte_array, .null_literal);
    try host.declareScratch(marshal_str_tmp_name, tn.string, .null_literal);
    try host.declareScratch(marshal_str_i_name, tn.int32, .{ .int32 = 0 });
    try host.declareScratch(marshal_str_addr_name, tn.int32, .{ .int32 = 0 });
    try host.declareScratch(marshal_str_byte_name, tn.byte, .null_literal);
    try host.declareScratch(marshal_str_cond_name, tn.boolean, .null_literal);
    try host.declareScratch(marshal_encoding_name, .{ .prim = .object }, .null_literal);
}

// -------------------- type mapping helpers --------------------

/// Map a parsed extern signature string to the actual Udon node name when
/// a widening alias is needed. Udon's node list occasionally exposes only a
/// broader overload (e.g. `SystemObject` instead of `SystemString`) because
/// the narrower signature would be covered by implicit widening in C#. The
/// translator accepts the narrower form in the WASM import name (which
/// drives marshaling: SystemString still triggers UTF-8 decoding into
/// `_marshal_str_tmp`), and rewrites only the final `EXTERN` string so the
/// dispatched node matches what Udon actually provides.
///
/// Returning the unchanged input for every non-aliased signature keeps the
/// common path zero-cost; aliases are meant to be rare.
fn resolveSignatureAlias(sig: []const u8) []const u8 {
    const aliases = [_]struct { from: []const u8, to: []const u8 }{
        .{
            // UnityEngine.Debug.Log has only the Object overload exposed.
            .from = "UnityEngineDebug.__Log__SystemString__SystemVoid",
            .to = "UnityEngineDebug.__Log__SystemObject__SystemVoid",
        },
    };
    for (aliases) |a| {
        if (std.mem.eql(u8, a.from, sig)) return a.to;
    }
    return sig;
}

fn expectedWasmParamCount(args: []const extern_sig.ArgSpec) u32 {
    var n: u32 = 0;
    for (args) |a| n += switch (a.kind) {
        .direct => 1,
        .marshal_string => 2,
    };
    return n;
}

fn hasSystemStringArg(args: []const extern_sig.ArgSpec) bool {
    for (args) |a| if (a.kind == .marshal_string) return true;
    return false;
}

fn udonTypeFor(name: []const u8) TypeName {
    if (std.mem.eql(u8, name, "SystemInt32")) return tn.int32;
    if (std.mem.eql(u8, name, "SystemUInt32")) return tn.uint32;
    if (std.mem.eql(u8, name, "SystemInt64")) return tn.int64;
    if (std.mem.eql(u8, name, "SystemUInt64")) return tn.uint64;
    if (std.mem.eql(u8, name, "SystemSingle")) return tn.single;
    if (std.mem.eql(u8, name, "SystemDouble")) return tn.double;
    if (std.mem.eql(u8, name, "SystemBoolean")) return tn.boolean;
    if (std.mem.eql(u8, name, "SystemString")) return tn.string;
    // Fallback: treat unknown types as SystemObject (opaque handle).
    return tn.object;
}

fn zeroLiteralFor(ty: TypeName) udon.asm_.Literal {
    if (ty.is_array) return .null_literal;
    return switch (ty.prim) {
        .int32 => .{ .int32 = 0 },
        .uint32 => .{ .uint32 = 0 },
        .single => .{ .single = 0.0 },
        // SystemByte / SystemInt64 / SystemUInt64 / SystemBoolean: the
        // UAssembly assembler rejects any non-null numeric initializer
        // (docs/udon_specs.md §4.7). Scratch slots of these types must be
        // declared as null — the value is produced by the EXTERN that
        // writes into the slot.
        .byte, .string, .object, .int64, .uint64, .double, .boolean => .null_literal,
        .void_ => .null_literal,
    };
}

fn hashStr(s: []const u8) u32 {
    // Small, stable hash that avoids pulling in std.hash dependencies here;
    // the translator only needs enough uniqueness to namespace scratch vars.
    var h: u32 = 2166136261;
    for (s) |c| {
        h ^= c;
        h = @mulWithOverflow(h, @as(u32, 16777619))[0];
    }
    return h;
}

// --------------------------- tests ---------------------------

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "expectedWasmParamCount: direct only" {
    const args = [_]extern_sig.ArgSpec{
        .{ .udon_type = "SystemInt32", .kind = .direct },
        .{ .udon_type = "SystemInt32", .kind = .direct },
    };
    try std.testing.expectEqual(@as(u32, 2), expectedWasmParamCount(&args));
}

test "expectedWasmParamCount: one SystemString counts as 2" {
    const args = [_]extern_sig.ArgSpec{
        .{ .udon_type = "SystemString", .kind = .marshal_string },
    };
    try std.testing.expectEqual(@as(u32, 2), expectedWasmParamCount(&args));
}

test "udonTypeFor known names" {
    try expect(udonTypeFor("SystemInt32").eql(tn.int32));
    try expect(udonTypeFor("SystemString").eql(tn.string));
    try expect(udonTypeFor("SystemUnknownType").eql(tn.object));
}

test "hashStr is deterministic" {
    const a = hashStr("SystemConsole.__WriteLine__SystemString__SystemVoid");
    const b = hashStr("SystemConsole.__WriteLine__SystemString__SystemVoid");
    try std.testing.expectEqual(a, b);
}

// -------- Host mocking for unit tests --------

const MockHost = struct {
    ally: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    decls: std.ArrayList([]const u8) = .empty,
    depth: u32 = 0,
    fn_name: []const u8 = "caller",
    next_id: u32 = 0,

    fn init(a: std.mem.Allocator) MockHost {
        return .{ .ally = a };
    }
    fn deinit(m: *MockHost) void {
        m.buf.deinit(m.ally);
        m.decls.deinit(m.ally);
    }

    fn host(self: *MockHost) Host {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Host.VTable = .{
        .allocator = vt_alloc,
        .declareScratch = vt_declare,
        .callerFnName = vt_name,
        .callerDepth = vt_depth,
        .consumeOne = vt_consume,
        .produceOne = vt_produce,
        .push = vt_push,
        .copy = vt_copy,
        .externCall = vt_extern,
        .comment = vt_comment,
        .annotateUnsupported = vt_annot,
        .label = vt_label,
        .jump = vt_jump,
        .jumpIfFalse = vt_jif,
        .readByteFromMemory = vt_readbyte,
        .uniqueId = vt_unique,
    };

    fn self_(ctx: *anyopaque) *MockHost {
        return @ptrCast(@alignCast(ctx));
    }
    fn vt_alloc(ctx: *anyopaque) std.mem.Allocator {
        return self_(ctx).ally;
    }
    fn vt_declare(ctx: *anyopaque, name: []const u8, ty: TypeName, lit: udon.asm_.Literal) Error!void {
        _ = ty;
        _ = lit;
        const s = self_(ctx);
        try s.decls.append(s.ally, name);
    }
    fn vt_name(ctx: *anyopaque) []const u8 {
        return self_(ctx).fn_name;
    }
    fn vt_depth(ctx: *anyopaque) u32 {
        return self_(ctx).depth;
    }
    fn vt_consume(ctx: *anyopaque) void {
        self_(ctx).depth -= 1;
    }
    fn vt_produce(ctx: *anyopaque, vt: ValType) Error!void {
        _ = vt;
        self_(ctx).depth += 1;
    }
    fn vt_push(ctx: *anyopaque, sym: []const u8) Error!void {
        const s = self_(ctx);
        try s.buf.appendSlice(s.ally, "PUSH ");
        try s.buf.appendSlice(s.ally, sym);
        try s.buf.appendSlice(s.ally, "\n");
    }
    fn vt_copy(ctx: *anyopaque) Error!void {
        const s = self_(ctx);
        try s.buf.appendSlice(s.ally, "COPY\n");
    }
    fn vt_extern(ctx: *anyopaque, sig: []const u8) Error!void {
        const s = self_(ctx);
        try s.buf.appendSlice(s.ally, "EXTERN ");
        try s.buf.appendSlice(s.ally, sig);
        try s.buf.appendSlice(s.ally, "\n");
    }
    fn vt_comment(ctx: *anyopaque, text: []const u8) Error!void {
        const s = self_(ctx);
        try s.buf.appendSlice(s.ally, "# ");
        try s.buf.appendSlice(s.ally, text);
        try s.buf.appendSlice(s.ally, "\n");
    }
    fn vt_annot(ctx: *anyopaque) Error!void {
        const s = self_(ctx);
        try s.buf.appendSlice(s.ally, "ANNOTATION __unsupported__\n");
    }
    fn vt_label(ctx: *anyopaque, name: []const u8) Error!void {
        const s = self_(ctx);
        try s.buf.appendSlice(s.ally, "LABEL ");
        try s.buf.appendSlice(s.ally, name);
        try s.buf.appendSlice(s.ally, "\n");
    }
    fn vt_jump(ctx: *anyopaque, name: []const u8) Error!void {
        const s = self_(ctx);
        try s.buf.appendSlice(s.ally, "JUMP ");
        try s.buf.appendSlice(s.ally, name);
        try s.buf.appendSlice(s.ally, "\n");
    }
    fn vt_jif(ctx: *anyopaque, name: []const u8) Error!void {
        const s = self_(ctx);
        try s.buf.appendSlice(s.ally, "JUMP_IF_FALSE ");
        try s.buf.appendSlice(s.ally, name);
        try s.buf.appendSlice(s.ally, "\n");
    }
    fn vt_readbyte(ctx: *anyopaque, addr: []const u8, out: []const u8) Error!void {
        const s = self_(ctx);
        try s.buf.appendSlice(s.ally, "READBYTE ");
        try s.buf.appendSlice(s.ally, addr);
        try s.buf.appendSlice(s.ally, " -> ");
        try s.buf.appendSlice(s.ally, out);
        try s.buf.appendSlice(s.ally, "\n");
    }
    fn vt_unique(ctx: *anyopaque) u32 {
        const s = self_(ctx);
        const id = s.next_id;
        s.next_id += 1;
        return id;
    }
};

test "generic extern: (int, int) -> int pass-through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mh = MockHost.init(arena.allocator());
    defer mh.deinit();
    mh.depth = 2; // caller has two args on its stack

    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{.i32};
    const imp: wasm.module.Import = .{
        .module = "env",
        .name = "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32",
        .desc = .{ .func = 0 },
    };
    const ft: wasm.types.FuncType = .{ .params = &params, .results = &results };
    try emit(mh.host(), imp, ft);

    const out = mh.buf.items;
    // Must contain a PUSH of both argument slots (typed i32) and the
    // EXTERN with raw sig.
    try expect(std.mem.indexOf(u8, out, "PUSH __caller_S0_i32__") != null);
    try expect(std.mem.indexOf(u8, out, "PUSH __caller_S1_i32__") != null);
    try expect(std.mem.indexOf(u8, out,
        "EXTERN SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32") != null);
    // Stack net: consume 2, produce 1.
    try std.testing.expectEqual(@as(u32, 1), mh.depth);
}

test "generic extern: SystemString arg consumes two i32s and marshals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mh = MockHost.init(arena.allocator());
    defer mh.deinit();
    mh.depth = 2;

    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{};
    const imp: wasm.module.Import = .{
        .module = "env",
        .name = "SystemConsole.__WriteLine__SystemString__SystemVoid",
        .desc = .{ .func = 0 },
    };
    const ft: wasm.types.FuncType = .{ .params = &params, .results = &results };
    try emit(mh.host(), imp, ft);

    const out = mh.buf.items;
    try expect(std.mem.indexOf(u8, out, "marshal SystemString") != null);
    try expect(std.mem.indexOf(u8, out, "_marshal_str_tmp") != null);
    try expect(std.mem.indexOf(u8, out,
        "EXTERN SystemConsole.__WriteLine__SystemString__SystemVoid") != null);
    // Byte array allocated + populated via the read-byte helper.
    try expect(std.mem.indexOf(u8, out,
        "EXTERN SystemByteArray.__ctor__SystemInt32__SystemByteArray") != null);
    try expect(std.mem.indexOf(u8, out, "READBYTE _marshal_str_addr") != null);
    try expect(std.mem.indexOf(u8, out,
        "EXTERN SystemByteArray.__Set__SystemInt32_SystemByte__SystemVoid") != null);
    // Instance method: encoding pushed as `this` before GetString.
    const gs_pos = std.mem.indexOf(u8, out,
        "EXTERN SystemTextEncoding.__GetString__SystemByteArray__SystemString").?;
    const this_pos = std.mem.lastIndexOf(u8, out[0..gs_pos], "PUSH _marshal_encoding_utf8").?;
    _ = this_pos; // just verify it exists before the GetString EXTERN
    // Scratch decls registered, including encoding and the new counter/byte.
    var saw_tmp = false;
    var saw_enc = false;
    var saw_byte = false;
    for (mh.decls.items) |d| {
        if (std.mem.eql(u8, d, marshal_str_tmp_name)) saw_tmp = true;
        if (std.mem.eql(u8, d, marshal_encoding_name)) saw_enc = true;
        if (std.mem.eql(u8, d, marshal_str_byte_name)) saw_byte = true;
    }
    try expect(saw_tmp);
    try expect(saw_enc);
    try expect(saw_byte);
    try std.testing.expectEqual(@as(u32, 0), mh.depth);
}

test "unrecognized import name emits unsupported annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mh = MockHost.init(arena.allocator());
    defer mh.deinit();

    const imp: wasm.module.Import = .{
        .module = "env",
        .name = "ConsoleWriteLine", // no signature grammar match
        .desc = .{ .func = 0 },
    };
    const ft: wasm.types.FuncType = .{ .params = &.{}, .results = &.{} };
    try emit(mh.host(), imp, ft);

    try expect(std.mem.indexOf(u8, mh.buf.items, "ANNOTATION __unsupported__") != null);
    try expect(std.mem.indexOf(u8, mh.buf.items, "unsupported import: env.ConsoleWriteLine") != null);
}

test "signature mismatch: WASM arity disagrees with Udon sig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mh = MockHost.init(arena.allocator());
    defer mh.deinit();
    // Udon signature expects 2 ints, but WASM says 3 params.
    const params = [_]ValType{ .i32, .i32, .i32 };
    const imp: wasm.module.Import = .{
        .module = "env",
        .name = "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32",
        .desc = .{ .func = 0 },
    };
    const ft: wasm.types.FuncType = .{ .params = &params, .results = &.{} };
    try std.testing.expectError(error.SignatureMismatch, emit(mh.host(), imp, ft));
}

// Two back-to-back calls to a SystemString-taking import — the same WASM locals
// hold (ptr, len) both times — must not produce two labels with the same name.
// The UAssembly assembler enforces this: `Duplicate label '...' detected` at
// `VisitLabelStmt`. Previously the loop label was derived from
// `hashStr(ptr_slot) ^ hashStr(len_slot)`, which collides when the same pair
// of slot names is reused.
test "two string-taking externs emit distinct marshal loop labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mh = MockHost.init(arena.allocator());
    defer mh.deinit();

    const params = [_]ValType{ .i32, .i32 };
    const results = [_]ValType{};
    const imp: wasm.module.Import = .{
        .module = "env",
        .name = "SystemConsole.__WriteLine__SystemString__SystemVoid",
        .desc = .{ .func = 0 },
    };
    const ft: wasm.types.FuncType = .{ .params = &params, .results = &results };

    mh.depth = 2;
    try emit(mh.host(), imp, ft);
    mh.depth = 2;
    try emit(mh.host(), imp, ft);

    // Scan every `LABEL __marshal_str_loop_...__` line and assert uniqueness.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena.allocator());
    var it = std.mem.splitScalar(u8, mh.buf.items, '\n');
    while (it.next()) |line| {
        const prefix = "LABEL __marshal_str_loop_";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const gop = try seen.getOrPut(arena.allocator(), line);
        try expect(!gop.found_existing);
    }
    // And sanity-check: we really did emit two loops.
    try std.testing.expectEqual(@as(u32, 2), seen.count());
}
