//! Udon extern signature parser (`docs/udon_specs.md` §7).
//!
//! Recognised shapes, after the `<Receiver>.__` prefix:
//!
//!   * `method__args__ret`   — regular form; `args` is `_`-separated type
//!     names, the literal `SystemVoid`, or empty (`__ctor____SystemObject`).
//!   * `method__ret`         — bare accessor form (`__get_deltaTime__SystemSingle`).
//!
//! The parser allocates nothing: every slice aliases the input.

const std = @import("std");

pub const max_args = 16;

pub const Arg = struct {
    /// Udon type name with any `Ref` suffix removed.
    ty: []const u8,
    is_ref: bool = false,
};

pub const Sig = struct {
    raw: []const u8,
    receiver: []const u8,
    method: []const u8,
    ret: []const u8,
    args_buf: [max_args]Arg = undefined,
    nargs: u8 = 0,

    pub fn args(self: *const Sig) []const Arg {
        return self.args_buf[0..self.nargs];
    }

    pub fn returnsValue(self: *const Sig) bool {
        return !std.mem.eql(u8, self.ret, "SystemVoid");
    }

    /// Whether the method takes an implicit `this` (pushed first). The
    /// signature string does not encode this (§7.3), so the answer is only
    /// known for constructors, operators, and the receivers listed below;
    /// `null` means "cannot tell".
    pub fn isInstance(self: *const Sig) ?bool {
        if (std.mem.eql(u8, self.method, "ctor")) return false;
        if (std.mem.startsWith(u8, self.method, "op_")) return false;
        for (static_receivers) |r| if (std.mem.eql(u8, self.receiver, r)) return false;
        for (static_methods) |m| if (std.mem.eql(u8, self.raw[0..@min(self.raw.len, m.len)], m)) return false;
        if (std.mem.endsWith(u8, self.receiver, "Array")) return true;
        for (instance_methods) |m| if (std.mem.eql(u8, self.raw[0..@min(self.raw.len, m.len)], m)) return true;
        return null;
    }
};

const static_receivers = [_][]const u8{
    "SystemConvert",   "SystemMath",     "SystemBitConverter", "SystemBuffer",
    "SystemArray",     "SystemConsole",  "UnityEngineMathf",   "UnityEngineDebug",
    "UnityEngineTime", "VRCInstantiate",
};
const static_methods = [_][]const u8{
    "SystemString.__Concat__",
    "SystemTextEncoding.__get_",
    "SystemDouble.__IsNaN__",
    "SystemSingle.__IsNaN__",
};
const instance_methods = [_][]const u8{
    "SystemTextEncoding.__GetString__",
    "SystemInt32.__ToString__",
    "SystemInt64.__ToString__",
};

pub fn parse(name: []const u8) ?Sig {
    const dot = std.mem.indexOf(u8, name, ".__") orelse return null;
    const receiver = name[0..dot];
    if (!isTypeName(receiver)) return null;

    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitSequence(u8, name[dot + 3 ..], "__");
    while (it.next()) |p| {
        if (n == parts.len) return null;
        parts[n] = p;
        n += 1;
    }
    if (n < 2) return null;
    const method = parts[0];
    const ret = parts[n - 1];
    if (!isMethodName(method) or !isTypeName(ret)) return null;

    var sig: Sig = .{ .raw = name, .receiver = receiver, .method = method, .ret = ret };
    if (n == 3 and parts[1].len != 0 and !std.mem.eql(u8, parts[1], "SystemVoid")) {
        var args = std.mem.splitScalar(u8, parts[1], '_');
        while (args.next()) |tok| {
            if (sig.nargs == max_args or !isTypeName(tok)) return null;
            const is_ref = tok.len > 3 and std.mem.endsWith(u8, tok, "Ref");
            sig.args_buf[sig.nargs] = .{ .ty = if (is_ref) tok[0 .. tok.len - 3] else tok, .is_ref = is_ref };
            sig.nargs += 1;
        }
    }
    return sig;
}

fn isTypeName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

fn isMethodName(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "binary operator" {
    const s = parse("SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32").?;
    try expectEqualStrings("SystemInt32", s.receiver);
    try expectEqualStrings("op_Addition", s.method);
    try expect(s.nargs == 2);
    try expectEqualStrings("SystemInt32", s.ret);
    try expect(s.isInstance().? == false);
}

test "bare accessor, explicit void and empty argument lists are nullary" {
    try expect(parse("UnityEngineTime.__get_deltaTime__SystemSingle").?.nargs == 0);
    try expect(parse("SystemObject.__ctor____SystemObject").?.nargs == 0);
    const s = parse("Foo.__Bar__SystemVoid__SystemVoid").?;
    try expect(s.nargs == 0 and !s.returnsValue());
}

test "Ref suffix is stripped and flagged" {
    const s = parse("SystemMath.__DivRem__SystemInt64_SystemInt64_SystemInt64Ref__SystemInt64").?;
    try expect(s.nargs == 3 and s.args()[2].is_ref and !s.args()[1].is_ref);
    try expectEqualStrings("SystemInt64", s.args()[2].ty);
}

test "array receivers are instance methods" {
    try expect(parse("SystemByteArray.__Get__SystemInt32__SystemByte").?.isInstance().? == true);
    try expect(parse("SystemByteArray.__ctor__SystemInt32__SystemByteArray").?.isInstance().? == false);
    try expect(parse("UnityEngineTransform.__get_position__UnityEngineVector3").?.isInstance() == null);
}

test "non-signatures are rejected" {
    try expect(parse("log") == null);
    try expect(parse("udon.self") == null);
    try expect(parse("Foo.__") == null);
    try expect(parse(".__a__b") == null);
    try expect(parse("Foo.__a__b__c__d") == null);
}
