//! The Udon node list (`docs/udon_nodes.txt`) and extern-signature parsing.
//!
//! The list is the ground truth for what the Udon VM can call: a program
//! whose `EXTERN` names a signature that is not in it loads, then halts
//! without running any event (`docs/udon_specs.md` §7.4). It also carries
//! `Type_<UdonTypeName>` and `Event_<Name>` entries, which the checker uses
//! to validate data declarations and exported labels.

const std = @import("std");

/// One node name per line, ASCII-sorted.
const list = @embedFile("udon_nodes");

/// True iff `name` is a line of the node list.
pub fn exists(name: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const start = if (std.mem.lastIndexOfScalar(u8, list[0..mid], '\n')) |i| i + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, list, start, '\n') orelse list.len;
        switch (std.mem.order(u8, name, list[start..end])) {
            .eq => return true,
            .lt => hi = start,
            .gt => lo = @min(end + 1, list.len),
        }
    }
    return false;
}

/// True iff `type_name` is an Udon type name the node list knows.
pub fn isType(type_name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "Type_{s}", .{type_name}) catch return false;
    return exists(key);
}

/// True iff `label` is a standard event label (`_start`, `_onPlayerJoined`,
/// …): the node list has `Event_<Name>` where `<Name>` is the label with the
/// underscore dropped and the first letter upper-cased
/// (`docs/udon_specs.md` §8.2).
pub fn isStandardEvent(label: []const u8) bool {
    if (label.len < 2 or label[0] != '_') return false;
    var buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "Event_{c}{s}", .{ std.ascii.toUpper(label[1]), label[2..] }) catch return false;
    return exists(key);
}

pub const void_type = "SystemVoid";

pub const Arg = struct {
    /// Udon type name with any `Ref` suffix removed.
    type_name: []const u8,
    /// The signature marked this parameter `ref`/`out`.
    is_ref: bool = false,
};

/// A parsed `<Type>.__<method>__<args>__<ret>` signature
/// (`docs/udon_specs.md` §7). All slices alias the input string.
pub const Signature = struct {
    raw: []const u8,
    type_name: []const u8,
    method: []const u8,
    args_buf: [max_args]Arg = undefined,
    args_len: u8 = 0,
    ret: []const u8,

    pub const max_args = 16;

    pub fn args(self: *const Signature) []const Arg {
        return self.args_buf[0..self.args_len];
    }

    pub fn returnsValue(self: *const Signature) bool {
        return !std.mem.eql(u8, self.ret, void_type);
    }

    /// Heap indices the VM pops for this extern when it is static: one per
    /// argument plus the trailing return slot. An instance method pops one
    /// more (the leading `this`); the signature cannot tell which it is.
    pub fn staticParamCount(self: *const Signature) u32 {
        return @as(u32, self.args_len) + @intFromBool(self.returnsValue());
    }

    /// Signatures with open type parameters (`T`, `TArray`, `IEnumerableT`)
    /// take hidden `SystemType` arguments (`docs/udon_specs.md` §7.4).
    pub fn isGeneric(self: *const Signature) bool {
        if (isTypeParam(self.ret)) return true;
        for (self.args()) |a| if (isTypeParam(a.type_name)) return true;
        return false;
    }

    /// Methods that are static by construction. Everything else may be
    /// either; callers decide from the argument count they were given.
    pub fn isKnownStatic(self: *const Signature) bool {
        return std.mem.eql(u8, self.method, "ctor") or std.mem.startsWith(u8, self.method, "op_");
    }
};

fn isTypeParam(t: []const u8) bool {
    return std.mem.eql(u8, t, "T") or std.mem.eql(u8, t, "TArray") or std.mem.eql(u8, t, "IEnumerableT");
}

/// Parse an extern signature. Returns null when `name` does not have the
/// signature shape at all (plain import names such as `print`).
pub fn parseSignature(name: []const u8) ?Signature {
    const dot = std.mem.indexOf(u8, name, ".__") orelse return null;
    const type_name = name[0..dot];
    if (type_name.len == 0 or !std.ascii.isAlphabetic(type_name[0])) return null;
    const body = name[dot + 3 ..];

    // body = method "__" [args "__"] ret. The method never contains "__";
    // an empty args segment (`__ctor____T`) means no arguments.
    const m_end = std.mem.indexOf(u8, body, "__") orelse return null;
    const method = body[0..m_end];
    if (method.len == 0) return null;
    const tail = body[m_end + 2 ..];
    var sig: Signature = .{ .raw = name, .type_name = type_name, .method = method, .ret = tail };
    if (std.mem.lastIndexOf(u8, tail, "__")) |r| {
        sig.ret = tail[r + 2 ..];
        const args_text = tail[0..r];
        if (args_text.len != 0 and !std.mem.eql(u8, args_text, void_type)) {
            if (!splitArgs(&sig, args_text)) return null;
        }
    }
    if (sig.ret.len == 0) return null;
    return sig;
}

/// Split `T1_T2_…`. Udon type names may themselves contain `_`
/// (`TMProTMP_Text`), so a token that is not a known type is joined with the
/// following ones until it is.
fn splitArgs(sig: *Signature, text: []const u8) bool {
    var start: usize = 0;
    while (start < text.len) {
        var end = std.mem.indexOfScalarPos(u8, text, start, '_') orelse text.len;
        while (end < text.len and !isArgType(text[start..end])) {
            end = std.mem.indexOfScalarPos(u8, text, end + 1, '_') orelse text.len;
        }
        const tok = text[start..end];
        if (tok.len == 0 or sig.args_len == Signature.max_args) return false;
        const base = if (std.mem.endsWith(u8, tok, "Ref")) tok[0 .. tok.len - 3] else tok;
        const is_ref = base.len != tok.len and isArgType(base);
        sig.args_buf[sig.args_len] = .{ .type_name = if (is_ref) base else tok, .is_ref = is_ref };
        sig.args_len += 1;
        start = end + 1;
    }
    return true;
}

fn isArgType(tok: []const u8) bool {
    if (isTypeParam(tok) or isType(tok)) return true;
    return std.mem.endsWith(u8, tok, "Ref") and tok.len > 3 and isArgType(tok[0 .. tok.len - 3]);
}

// ------------------------------- tests -------------------------------

const testing = std.testing;

test "exists: first, last and middle entries" {
    try testing.expect(exists("Block"));
    try testing.expect(exists("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"));
    try testing.expect(exists("SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid"));
    try testing.expect(!exists("SystemInt32.__op_Modulus__SystemInt32_SystemInt32__SystemInt32"));
    try testing.expect(!exists(""));
    const last_start = std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, list, "\n"), '\n').? + 1;
    try testing.expect(exists(std.mem.trimEnd(u8, list[last_start..], "\n")));
}

test "types and events" {
    try testing.expect(isType("SystemInt32"));
    try testing.expect(isType("SystemByteArray"));
    try testing.expect(isType("UnityEngineTransform"));
    try testing.expect(!isType("SystemNope"));
    try testing.expect(isStandardEvent("_start"));
    try testing.expect(isStandardEvent("_onPlayerJoined"));
    try testing.expect(!isStandardEvent("_notAnEvent"));
    try testing.expect(!isStandardEvent("Custom"));
}

test "parse binary operator" {
    const s = parseSignature("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32").?;
    try testing.expectEqualStrings("SystemInt32", s.type_name);
    try testing.expectEqualStrings("op_Addition", s.method);
    try testing.expectEqual(@as(usize, 2), s.args().len);
    try testing.expectEqualStrings("SystemInt32", s.ret);
    try testing.expectEqual(@as(u32, 3), s.staticParamCount());
    try testing.expect(s.isKnownStatic());
}

test "parse getter without an argument section" {
    const s = parseSignature("UnityEngineTime.__get_deltaTime__SystemSingle").?;
    try testing.expectEqualStrings("get_deltaTime", s.method);
    try testing.expectEqual(@as(usize, 0), s.args().len);
    try testing.expectEqualStrings("SystemSingle", s.ret);
}

test "parse explicit void and empty argument lists" {
    const a = parseSignature("UnityEngineTexture2D.__Apply__SystemVoid").?;
    try testing.expectEqual(@as(usize, 0), a.args().len);
    try testing.expect(!a.returnsValue());
    const b = parseSignature("SystemObject.__ctor____SystemObject").?;
    try testing.expectEqual(@as(usize, 0), b.args().len);
    try testing.expectEqualStrings("SystemObject", b.ret);
}

test "parse ref argument" {
    const s = parseSignature("SystemMath.__DivRem__SystemInt64_SystemInt64_SystemInt64Ref__SystemInt64").?;
    try testing.expectEqual(@as(usize, 3), s.args().len);
    try testing.expect(s.args()[2].is_ref);
    try testing.expectEqualStrings("SystemInt64", s.args()[2].type_name);
    try testing.expect(!s.args()[0].is_ref);
}

test "parse argument type containing an underscore" {
    const s = parseSignature("TMProTMP_Text.__set_text__SystemString__SystemVoid").?;
    try testing.expectEqualStrings("TMProTMP_Text", s.type_name);
    try testing.expectEqual(@as(usize, 1), s.args().len);
}

test "generic signatures are flagged" {
    try testing.expect(parseSignature("UnityEngineComponent.__GetComponent__T").?.isGeneric());
    try testing.expect(!parseSignature("UnityEngineDebug.__Log__SystemObject__SystemVoid").?.isGeneric());
}

test "non-signatures are rejected" {
    try testing.expect(parseSignature("print") == null);
    try testing.expect(parseSignature("udon.self") == null);
    try testing.expect(parseSignature("A.__b") == null);
}

test "every extern-shaped node parses" {
    var it = std.mem.splitScalar(u8, list, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, ".__") == null) continue;
        const s = parseSignature(line) orelse {
            std.debug.print("unparsed node: {s}\n", .{line});
            return error.TestUnexpectedResult;
        };
        try testing.expect(s.ret.len > 0);
        n += 1;
    }
    try testing.expect(n > 30000);
}
