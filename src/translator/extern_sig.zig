//! Udon extern signature parser.
//!
//! Implements the grammar restated in `docs/spec_host_import_conversion.md`
//! §"Signature Grammar". The Udon extern signature form is authoritative in
//! `docs/udon_specs.md` §7; this module is the *recognizer* for that form so
//! that WASM import names can be used as-is for pass-through extern
//! dispatch.
//!
//! This is a pure parser — no WASM knowledge — so tests live alongside the
//! code and do not depend on any other translator module.

const std = @import("std");

/// Whether a Udon argument is passed through directly or requires runtime
/// marshaling (e.g. `(ptr, len)` → `SystemString`). See the type-mapping
/// table in `spec_host_import_conversion.md` §2.
pub const ArgKind = enum {
    direct,
    marshal_string,
};

pub const ArgSpec = struct {
    /// Udon type name, with any `Ref` suffix stripped.
    udon_type: []const u8,
    kind: ArgKind,
    /// The original type ended in `Ref` (ref/out argument per `docs/udon_specs.md` §7.2).
    is_ref: bool = false,

    pub fn isArray(self: ArgSpec) bool {
        return std.mem.endsWith(u8, self.udon_type, "Array");
    }
};

pub const Signature = struct {
    /// Receiver / namespace type. The part before `.__`.
    udon_type: []const u8,
    /// Method name. The part between `.__` and the next `__`. May contain
    /// single underscores (e.g. `op_Addition`, `get_Now`).
    method: []const u8,
    /// Parsed argument specs. Empty for nullary (`SystemVoid`) arg list.
    args: []const ArgSpec,
    /// Return type (Udon type name). `SystemVoid` for void.
    result: []const u8,
    /// The original input string — reused as the `EXTERN` immediate.
    raw: []const u8,
};

/// Try to parse `name` as an Udon extern signature. Returns null if `name`
/// does not match the grammar (no allocation in that case). On success the
/// returned `Signature` borrows slices from `name` for type/method/result
/// fields; only the `args` slice is heap-allocated and the caller must free
/// it (typical usage is an arena that outlives the translator pass).
pub fn parse(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?Signature {
    // Must contain `.__` at least once.
    const receiver_end = std.mem.indexOf(u8, name, ".__") orelse return null;
    if (receiver_end == 0) return null;
    const udon_type = name[0..receiver_end];
    if (!isValidUdonTypeStart(udon_type)) return null;

    const rest = name[receiver_end + 3 ..]; // after ".__"

    // rest has the form: method "__" args "__" return
    // method may contain single `_` but not `__`. We find the first `__`
    // after position 0.
    const method_end = findDoubleUnderscore(rest, 1) orelse return null;
    const method = rest[0..method_end];
    if (method.len == 0) return null;
    if (!isValidMethodName(method)) return null;

    const after_method = rest[method_end + 2 ..];

    // after_method is either:
    //   (a) args "__" return   — regular form with explicit arg list
    //   (b) return             — bare property-getter/setter form (nullary)
    //
    // Udon's node listing (`docs/udon_nodes.txt`) emits (b) for property
    // accessors — e.g. `UnityEngineTime.__get_deltaTime__SystemSingle` has
    // no middle arg-list section. Accept both; (b) is detected by the
    // absence of a further `__` inside `after_method`.
    var args: []ArgSpec = &.{};
    var result_str: []const u8 = undefined;
    if (findLastDoubleUnderscore(after_method)) |last_dunder| {
        const args_str = after_method[0..last_dunder];
        result_str = after_method[last_dunder + 2 ..];
        if (result_str.len == 0) return null;
        if (!isValidUdonTypeStart(result_str)) return null;
        if (args_str.len == 0) return null;
        if (!std.mem.eql(u8, args_str, "SystemVoid")) {
            args = try parseArgs(allocator, args_str);
        }
    } else {
        // Bare getter/setter form: entire remainder is the return type.
        result_str = after_method;
        if (result_str.len == 0) return null;
        if (!isValidUdonTypeStart(result_str)) return null;
    }

    return Signature{
        .udon_type = udon_type,
        .method = method,
        .args = args,
        .result = result_str,
        .raw = name,
    };
}

fn parseArgs(allocator: std.mem.Allocator, args_str: []const u8) std.mem.Allocator.Error![]ArgSpec {
    // Tokenize on single `_`. Empty tokens (from `__`) should not appear —
    // that would have been captured by the outer split. Defensive: treat an
    // empty token as a malformed arg by skipping.
    var count: usize = 1;
    for (args_str) |c| if (c == '_') {
        count += 1;
    };
    var out = try allocator.alloc(ArgSpec, count);
    errdefer allocator.free(out);

    var idx: usize = 0;
    var tok_start: usize = 0;
    var i: usize = 0;
    while (i <= args_str.len) : (i += 1) {
        const end = i == args_str.len or args_str[i] == '_';
        if (end) {
            const tok = args_str[tok_start..i];
            if (tok.len > 0) {
                out[idx] = classify(tok);
                idx += 1;
            }
            tok_start = i + 1;
        }
    }
    // Shrink to actual count (skipping empty tokens from adjacent `_`).
    if (idx != out.len) {
        const shrunk = try allocator.realloc(out, idx);
        return shrunk;
    }
    return out;
}

fn classify(tok: []const u8) ArgSpec {
    var ty = tok;
    var is_ref = false;
    if (std.mem.endsWith(u8, ty, "Ref")) {
        is_ref = true;
        ty = ty[0 .. ty.len - 3];
    }
    const kind: ArgKind = if (std.mem.eql(u8, ty, "SystemString")) .marshal_string else .direct;
    return .{ .udon_type = ty, .kind = kind, .is_ref = is_ref };
}

fn isValidUdonTypeStart(s: []const u8) bool {
    if (s.len == 0) return false;
    return std.ascii.isAlphabetic(s[0]);
}

fn isValidMethodName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    // Must not begin with a digit.
    return !std.ascii.isDigit(s[0]);
}

/// Find the index of the first `__` occurring at or after `start`, or null.
fn findDoubleUnderscore(s: []const u8, start: usize) ?usize {
    if (start >= s.len) return null;
    var i: usize = start;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == '_' and s[i + 1] == '_') return i;
    }
    return null;
}

fn findLastDoubleUnderscore(s: []const u8) ?usize {
    if (s.len < 2) return null;
    var i: usize = s.len - 2;
    while (true) : (i -= 1) {
        if (s[i] == '_' and s[i + 1] == '_') return i;
        if (i == 0) break;
    }
    return null;
}

// ----------------------------- tests -----------------------------

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

fn parseAlloc(name: []const u8) !?Signature {
    return parse(std.testing.allocator, name);
}

fn freeSig(sig: Signature) void {
    if (sig.args.len > 0) std.testing.allocator.free(sig.args);
}

test "parse basic binary operator signature" {
    const opt = try parseAlloc("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32");
    try expect(opt != null);
    const s = opt.?;
    defer freeSig(s);
    try expectEqualStrings("SystemInt32", s.udon_type);
    try expectEqualStrings("op_Addition", s.method);
    try expectEqualStrings("SystemInt32", s.result);
    try std.testing.expectEqual(@as(usize, 2), s.args.len);
    try expectEqualStrings("SystemInt32", s.args[0].udon_type);
    try expect(s.args[0].kind == .direct);
    try expect(!s.args[0].is_ref);
}

test "parse SystemString arg produces marshal_string kind" {
    const opt = try parseAlloc("SystemConsole.__WriteLine__SystemString__SystemVoid");
    try expect(opt != null);
    const s = opt.?;
    defer freeSig(s);
    try expectEqualStrings("SystemConsole", s.udon_type);
    try expectEqualStrings("WriteLine", s.method);
    try expectEqualStrings("SystemVoid", s.result);
    try std.testing.expectEqual(@as(usize, 1), s.args.len);
    try expect(s.args[0].kind == .marshal_string);
    try expectEqualStrings("SystemString", s.args[0].udon_type);
}

test "parse nullary arg list via SystemVoid" {
    const opt = try parseAlloc("SystemDateTime.__get_Now__SystemVoid__SystemDateTime");
    try expect(opt != null);
    const s = opt.?;
    defer freeSig(s);
    try expectEqualStrings("get_Now", s.method);
    try std.testing.expectEqual(@as(usize, 0), s.args.len);
    try expectEqualStrings("SystemDateTime", s.result);
}

test "parse bare property-getter form (no arg-list section)" {
    // Udon lists property accessors without an arg-list section.
    const opt = try parseAlloc("UnityEngineTime.__get_deltaTime__SystemSingle");
    try expect(opt != null);
    const s = opt.?;
    defer freeSig(s);
    try expectEqualStrings("UnityEngineTime", s.udon_type);
    try expectEqualStrings("get_deltaTime", s.method);
    try std.testing.expectEqual(@as(usize, 0), s.args.len);
    try expectEqualStrings("SystemSingle", s.result);
}

test "parse bare instance-getter form (no arg-list section)" {
    const opt = try parseAlloc("UnityEngineTransform.__get_position__UnityEngineVector3");
    try expect(opt != null);
    const s = opt.?;
    defer freeSig(s);
    try expectEqualStrings("UnityEngineTransform", s.udon_type);
    try expectEqualStrings("get_position", s.method);
    try std.testing.expectEqual(@as(usize, 0), s.args.len);
    try expectEqualStrings("UnityEngineVector3", s.result);
}

test "parse Ref suffix strips and sets is_ref" {
    const opt = try parseAlloc("SystemFoo.__Bar__SystemInt32Ref__SystemVoid");
    try expect(opt != null);
    const s = opt.?;
    defer freeSig(s);
    try std.testing.expectEqual(@as(usize, 1), s.args.len);
    try expect(s.args[0].is_ref);
    try expectEqualStrings("SystemInt32", s.args[0].udon_type);
    try expect(s.args[0].kind == .direct);
}

test "parse Array suffix preserved in udon_type" {
    const opt = try parseAlloc("SystemObjectArray.__GetValue__SystemInt32__SystemObject");
    try expect(opt != null);
    const s = opt.?;
    defer freeSig(s);
    try expectEqualStrings("SystemObjectArray", s.udon_type);
    try expect(s.args[0].isArray() == false); // the *arg* is SystemInt32
}

test "parse rejects non-signature names" {
    try expect((try parseAlloc("ConsoleWriteLine")) == null);
    try expect((try parseAlloc("foo.bar")) == null);
    try expect((try parseAlloc("")) == null);
    try expect((try parseAlloc(".__Foo__SystemVoid__SystemVoid")) == null); // empty udon_type
    try expect((try parseAlloc("Sys.__")) == null); // truncated
}

test "parse method name with single underscores" {
    // op_Equality has a single underscore in its method name.
    const opt = try parseAlloc("SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean");
    try expect(opt != null);
    const s = opt.?;
    defer freeSig(s);
    try expectEqualStrings("op_Equality", s.method);
    try expectEqualStrings("SystemBoolean", s.result);
}

test "raw matches input" {
    const name = "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid";
    const opt = try parseAlloc(name);
    try expect(opt != null);
    const s = opt.?;
    defer freeSig(s);
    try expectEqualStrings(name, s.raw);
}

// Regression guard: every signature string hand-authored in the numeric
// dispatch table must pass our parser. This catches drift between the
// parser and the table that's used to emit arithmetic EXTERN calls.
test "numeric dispatch table round-trips through parser" {
    const numeric_sigs = [_][]const u8{
        "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32",
        "SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32",
        "SystemInt32.__op_Multiplication__SystemInt32_SystemInt32__SystemInt32",
        "SystemInt32.__op_Division__SystemInt32_SystemInt32__SystemInt32",
        "SystemUInt32.__op_Division__SystemUInt32_SystemUInt32__SystemUInt32",
        "SystemInt32.__op_Remainder__SystemInt32_SystemInt32__SystemInt32",
        "SystemInt32.__op_LogicalAnd__SystemInt32_SystemInt32__SystemInt32",
        "SystemInt32.__op_LogicalOr__SystemInt32_SystemInt32__SystemInt32",
        "SystemInt32.__op_LogicalXor__SystemInt32_SystemInt32__SystemInt32",
        "SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32",
        "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32",
        "SystemUInt32.__op_RightShift__SystemUInt32_SystemInt32__SystemUInt32",
        "SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean",
        "SystemInt64.__op_Addition__SystemInt64_SystemInt64__SystemInt64",
        "SystemDouble.__op_Multiplication__SystemDouble_SystemDouble__SystemDouble",
        "SystemMath.__Floor__SystemDouble__SystemDouble",
    };
    for (numeric_sigs) |sig_str| {
        const opt = try parseAlloc(sig_str);
        try expect(opt != null);
        const s = opt.?;
        defer freeSig(s);
        try expectEqualStrings(sig_str, s.raw);
    }
}
