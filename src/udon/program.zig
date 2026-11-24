//! Udon Assembly text → `Program`.
//!
//! An independent reader for the textual form defined in
//! `docs/udon_specs.md`. It deliberately shares no code with the writer in
//! `asm.zig`: the checker (`check.zig`) and the emulator (`vm.zig`) consume
//! what this parser accepts, so a writer bug cannot hide behind a matching
//! reader bug.
//!
//! The parser is permissive about *semantics* (unknown types, undefined
//! symbols, bad literals for a type are all recorded, not rejected) so that
//! `check.zig` can report every violation with a line number. It is strict
//! about *syntax*: a line it cannot tokenize is a `SyntaxError`.

const std = @import("std");

pub const Opcode = enum(u8) {
    nop = 0,
    push = 1,
    pop = 2,
    jump_if_false = 4,
    jump = 5,
    extern_ = 6,
    annotation = 7,
    jump_indirect = 8,
    copy = 9,

    /// Bytecode size: 4 bytes for the opcode plus 4 for a parameter
    /// (`docs/udon_specs.md` §6.1).
    pub fn size(op: Opcode) u32 {
        return if (op.hasParam()) 8 else 4;
    }

    pub fn hasParam(op: Opcode) bool {
        return switch (op) {
            .nop, .pop, .copy => false,
            .push, .jump_if_false, .jump, .extern_, .annotation, .jump_indirect => true,
        };
    }

    pub fn mnemonic(op: Opcode) []const u8 {
        return switch (op) {
            .nop => "NOP",
            .push => "PUSH",
            .pop => "POP",
            .jump_if_false => "JUMP_IF_FALSE",
            .jump => "JUMP",
            .extern_ => "EXTERN",
            .annotation => "ANNOTATION",
            .jump_indirect => "JUMP_INDIRECT",
            .copy => "COPY",
        };
    }

    pub fn fromMnemonic(s: []const u8) ?Opcode {
        inline for (@typeInfo(Opcode).@"enum".fields) |f| {
            const op: Opcode = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, op.mnemonic())) return op;
        }
        return null;
    }
};

/// Address a `JUMP` uses to end execution (`docs/udon_specs.md` §6.2.5).
pub const halt_address: u32 = 0xFFFFFFFC;

pub const Literal = union(enum) {
    null_,
    this,
    boolean: bool,
    /// Integer literal without the `u` suffix. Kept as i64 so the checker
    /// can diagnose out-of-range values instead of the parser wrapping them.
    int: i64,
    /// Integer literal with the `u` suffix.
    uint: u64,
    float: f64,
    string: []const u8,
    char: u21,
};

pub const SyncMode = enum { none, linear, smooth };

pub const Var = struct {
    /// Empty for the anonymous variables created from string literals.
    name: []const u8,
    type_name: []const u8,
    init: Literal,
    /// The literal exactly as written, for checks that depend on its
    /// spelling (decimal `-2147483648` is rejected by the real assembler,
    /// hex `0x80000000` is not).
    init_text: []const u8 = "",
    is_export: bool = false,
    sync: ?SyncMode = null,
    line: u32 = 0,
};

pub const Param = union(enum) {
    none,
    /// Heap index (named variable or anonymous string variable).
    heap: u32,
    /// Code address (resolved label or integer literal).
    address: u32,
    /// A symbol that resolved to nothing; reported by the checker.
    unresolved: []const u8,
};

pub const Instr = struct {
    op: Opcode,
    param: Param = .none,
    addr: u32,
    line: u32,
};

pub const Label = struct {
    name: []const u8,
    addr: u32,
    is_export: bool = false,
    line: u32,
};

/// A directive that named a symbol which was never declared, or was
/// malformed in a way the checker should report.
pub const Issue = struct {
    line: u32,
    message: []const u8,
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    vars: []Var = &.{},
    var_index: std.StringHashMapUnmanaged(u32) = .empty,
    /// Number of named variables; `vars[named_count..]` are anonymous
    /// string-literal variables (`docs/udon_specs.md` §10).
    named_count: u32 = 0,
    code: []Instr = &.{},
    labels: []Label = &.{},
    label_index: std.StringHashMapUnmanaged(u32) = .empty,
    code_size: u32 = 0,
    issues: []Issue = &.{},

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
    }

    /// Heap slots the program occupies: one per named variable plus one per
    /// distinct string literal used as an instruction parameter.
    pub fn heapSize(self: *const Program) u32 {
        return @intCast(self.vars.len);
    }

    pub fn labelAddr(self: *const Program, name: []const u8) ?u32 {
        const i = self.label_index.get(name) orelse return null;
        return self.labels[i].addr;
    }

    pub fn varIndex(self: *const Program, name: []const u8) ?u32 {
        return self.var_index.get(name);
    }
};

pub const ParseError = error{SyntaxError} || std.mem.Allocator.Error;

/// Where and why the last `parse` call failed with `SyntaxError`.
pub const Diagnostic = struct {
    line: u32 = 0,
    message: []const u8 = "",
};

const Section = enum { none, data, after_data, code, after_code };

const PendingRef = struct { instr: u32, name: []const u8 };

pub fn parse(gpa: std.mem.Allocator, text: []const u8, diag: ?*Diagnostic) ParseError!Program {
    var prog: Program = .{ .arena = .init(gpa) };
    errdefer prog.arena.deinit();
    const a = prog.arena.allocator();

    var vars: std.ArrayList(Var) = .empty;
    var anon: std.ArrayList(Var) = .empty;
    var anon_index: std.StringHashMapUnmanaged(u32) = .empty;
    var code: std.ArrayList(Instr) = .empty;
    var labels: std.ArrayList(Label) = .empty;
    var issues: std.ArrayList(Issue) = .empty;
    var data_exports: std.ArrayList(struct { name: []const u8, line: u32 }) = .empty;
    var data_syncs: std.ArrayList(struct { name: []const u8, mode: SyncMode, line: u32 }) = .empty;
    var code_exports: std.ArrayList(struct { name: []const u8, line: u32 }) = .empty;
    var sym_refs: std.ArrayList(PendingRef) = .empty;
    var str_refs: std.ArrayList(PendingRef) = .empty;

    var section: Section = .none;
    var addr: u32 = 0;
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, stripComment(raw_line), " \t\r");
        if (line.len == 0) continue;
        const fail = struct {
            fn f(d: ?*Diagnostic, n: u32, msg: []const u8) ParseError {
                if (d) |p| p.* = .{ .line = n, .message = msg };
                return error.SyntaxError;
            }
        }.f;

        if (line[0] == '.') {
            var it = std.mem.tokenizeAny(u8, line, " \t,");
            const directive = it.next().?;
            if (std.mem.eql(u8, directive, ".data_start")) {
                if (section != .none) try issues.append(a, .{ .line = line_no, .message = "misplaced .data_start" });
                section = .data;
            } else if (std.mem.eql(u8, directive, ".data_end")) {
                if (section != .data) try issues.append(a, .{ .line = line_no, .message = "misplaced .data_end" });
                section = .after_data;
            } else if (std.mem.eql(u8, directive, ".code_start")) {
                if (section != .after_data) try issues.append(a, .{ .line = line_no, .message = "misplaced .code_start" });
                section = .code;
            } else if (std.mem.eql(u8, directive, ".code_end")) {
                if (section != .code) try issues.append(a, .{ .line = line_no, .message = "misplaced .code_end" });
                section = .after_code;
            } else if (std.mem.eql(u8, directive, ".export")) {
                const name = it.next() orelse return fail(diag, line_no, ".export needs a name");
                switch (section) {
                    .data => try data_exports.append(a, .{ .name = name, .line = line_no }),
                    .code => try code_exports.append(a, .{ .name = name, .line = line_no }),
                    else => try issues.append(a, .{ .line = line_no, .message = ".export outside a section" }),
                }
            } else if (std.mem.eql(u8, directive, ".sync")) {
                const name = it.next() orelse return fail(diag, line_no, ".sync needs a name");
                const mode_s = it.next() orelse return fail(diag, line_no, ".sync needs a mode");
                const mode = std.meta.stringToEnum(SyncMode, mode_s) orelse {
                    try issues.append(a, .{ .line = line_no, .message = "unknown .sync interpolation mode" });
                    continue;
                };
                if (section != .data) try issues.append(a, .{ .line = line_no, .message = ".sync outside the data section" });
                try data_syncs.append(a, .{ .name = name, .mode = mode, .line = line_no });
            } else return fail(diag, line_no, "unknown directive");
            continue;
        }

        switch (section) {
            .data => {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse return fail(diag, line_no, "expected `name: %Type, value`");
                const name = std.mem.trim(u8, line[0..colon], " \t");
                const rest = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (rest.len == 0 or rest[0] != '%') return fail(diag, line_no, "expected `%Type` after the variable name");
                const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return fail(diag, line_no, "expected `, value` after the type");
                const type_name = std.mem.trim(u8, rest[1..comma], " \t");
                const lit_text = std.mem.trim(u8, rest[comma + 1 ..], " \t");
                const lit = parseLiteral(a, lit_text) catch |e| switch (e) {
                    error.SyntaxError => return fail(diag, line_no, "malformed literal"),
                    else => |oom| return oom,
                };
                const gop = try prog.var_index.getOrPut(a, name);
                if (gop.found_existing) {
                    try issues.append(a, .{ .line = line_no, .message = try std.fmt.allocPrint(a, "duplicate variable '{s}'", .{name}) });
                    continue;
                }
                gop.value_ptr.* = @intCast(vars.items.len);
                try vars.append(a, .{ .name = name, .type_name = type_name, .init = lit, .init_text = lit_text, .line = line_no });
            },
            .code => {
                if (line[line.len - 1] == ':') {
                    const name = std.mem.trim(u8, line[0 .. line.len - 1], " \t");
                    const gop = try prog.label_index.getOrPut(a, name);
                    if (gop.found_existing) {
                        try issues.append(a, .{ .line = line_no, .message = try std.fmt.allocPrint(a, "duplicate label '{s}'", .{name}) });
                        continue;
                    }
                    gop.value_ptr.* = @intCast(labels.items.len);
                    try labels.append(a, .{ .name = name, .addr = addr, .line = line_no });
                    continue;
                }
                const comma = std.mem.indexOfScalar(u8, line, ',');
                const mnem = std.mem.trim(u8, if (comma) |c| line[0..c] else line, " \t");
                const op = Opcode.fromMnemonic(mnem) orelse return fail(diag, line_no, "unknown opcode");
                var ins: Instr = .{ .op = op, .addr = addr, .line = line_no };
                if (comma) |c| {
                    const p = std.mem.trim(u8, line[c + 1 ..], " \t");
                    if (!op.hasParam()) {
                        try issues.append(a, .{ .line = line_no, .message = "opcode takes no parameter" });
                    } else if (p.len == 0) {
                        return fail(diag, line_no, "empty parameter");
                    } else if (p[0] == '"') {
                        const s = parseString(a, p) catch |e| switch (e) {
                            error.SyntaxError => return fail(diag, line_no, "malformed string literal"),
                            else => |oom| return oom,
                        };
                        try str_refs.append(a, .{ .instr = @intCast(code.items.len), .name = s });
                    } else if (std.ascii.isDigit(p[0])) {
                        const v = parseUnsigned(p) orelse return fail(diag, line_no, "malformed integer parameter");
                        ins.param = .{ .address = v };
                    } else {
                        try sym_refs.append(a, .{ .instr = @intCast(code.items.len), .name = p });
                    }
                } else if (op.hasParam()) {
                    try issues.append(a, .{ .line = line_no, .message = "opcode requires a parameter" });
                }
                try code.append(a, ins);
                addr += op.size();
            },
            else => return fail(diag, line_no, "content outside .data/.code sections"),
        }
    }
    if (section != .after_code) try issues.append(a, .{ .line = line_no, .message = "program must be .data_start/.data_end followed by .code_start/.code_end" });

    prog.named_count = @intCast(vars.items.len);

    // Anonymous variables: one per distinct string literal, allocated after
    // the named variables in order of first use.
    for (str_refs.items) |r| {
        const gop = try anon_index.getOrPut(a, r.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = prog.named_count + @as(u32, @intCast(anon.items.len));
            try anon.append(a, .{ .name = "", .type_name = "SystemString", .init = .{ .string = r.name }, .line = code.items[r.instr].line });
        }
        code.items[r.instr].param = .{ .heap = gop.value_ptr.* };
    }
    try vars.appendSlice(a, anon.items);

    for (data_exports.items) |e| {
        if (prog.var_index.get(e.name)) |i| vars.items[i].is_export = true else try issues.append(a, .{
            .line = e.line,
            .message = try std.fmt.allocPrint(a, ".export of undeclared variable '{s}'", .{e.name}),
        });
    }
    for (data_syncs.items) |s| {
        if (prog.var_index.get(s.name)) |i| vars.items[i].sync = s.mode else try issues.append(a, .{
            .line = s.line,
            .message = try std.fmt.allocPrint(a, ".sync of undeclared variable '{s}'", .{s.name}),
        });
    }
    for (code_exports.items) |e| {
        if (prog.label_index.get(e.name)) |i| labels.items[i].is_export = true else try issues.append(a, .{
            .line = e.line,
            .message = try std.fmt.allocPrint(a, ".export of undefined label '{s}'", .{e.name}),
        });
    }

    // Symbol parameters: jumps take labels, everything else takes variables.
    // A name that is both a variable and a label is disambiguated by the
    // opcode (`docs/udon_specs.md` §4.4).
    for (sym_refs.items) |r| {
        const ins = &code.items[r.instr];
        const is_jump = ins.op == .jump or ins.op == .jump_if_false;
        if (is_jump) {
            if (prog.label_index.get(r.name)) |i| {
                ins.param = .{ .address = labels.items[i].addr };
                continue;
            }
        } else if (prog.var_index.get(r.name)) |i| {
            ins.param = .{ .heap = i };
            continue;
        }
        ins.param = .{ .unresolved = r.name };
    }

    prog.vars = try vars.toOwnedSlice(a);
    prog.code = try code.toOwnedSlice(a);
    prog.labels = try labels.toOwnedSlice(a);
    prog.issues = try issues.toOwnedSlice(a);
    prog.code_size = addr;
    return prog;
}

/// Cut a line at the first `#` that is not inside a string or char literal.
fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == '\\') i += 1 else if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#') {
            return line[0..i];
        }
    }
    return line;
}

fn parseUnsigned(s: []const u8) ?u32 {
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"))
        return std.fmt.parseInt(u32, s[2..], 16) catch null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn parseString(a: std.mem.Allocator, s: []const u8) ParseError![]const u8 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return error.SyntaxError;
    const body = s[1 .. s.len - 1];
    if (std.mem.indexOfScalar(u8, body, '\\') == null) {
        if (std.mem.indexOfScalar(u8, body, '"') != null) return error.SyntaxError;
        return body;
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '"') return error.SyntaxError;
        if (body[i] != '\\') {
            try out.append(a, body[i]);
            continue;
        }
        i += 1;
        if (i >= body.len) return error.SyntaxError;
        try out.append(a, switch (body[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '0' => 0,
            '"', '\\', '\'' => body[i],
            else => return error.SyntaxError,
        });
    }
    return out.toOwnedSlice(a);
}

fn parseLiteral(a: std.mem.Allocator, s: []const u8) ParseError!Literal {
    if (s.len == 0) return error.SyntaxError;
    if (std.mem.eql(u8, s, "null")) return .null_;
    if (std.mem.eql(u8, s, "this")) return .this;
    if (std.mem.eql(u8, s, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, s, "false")) return .{ .boolean = false };
    if (s[0] == '"') return .{ .string = try parseString(a, s) };
    if (s[0] == '\'') {
        if (s.len < 3 or s[s.len - 1] != '\'') return error.SyntaxError;
        const cp = std.unicode.utf8Decode(s[1 .. s.len - 1]) catch return error.SyntaxError;
        return .{ .char = cp };
    }

    var body = s;
    var negative = false;
    if (body[0] == '-' or body[0] == '+') {
        negative = body[0] == '-';
        body = body[1..];
    }
    if (body.len == 0) return error.SyntaxError;
    const is_hex = std.mem.startsWith(u8, body, "0x") or std.mem.startsWith(u8, body, "0X");
    if (is_hex) {
        var digits = body[2..];
        const unsigned = digits.len > 0 and (digits[digits.len - 1] == 'u' or digits[digits.len - 1] == 'U');
        if (unsigned) digits = digits[0 .. digits.len - 1];
        const v = std.fmt.parseInt(u64, digits, 16) catch return error.SyntaxError;
        if (unsigned) return .{ .uint = v };
        // A signed hex literal denotes a bit pattern: 0x80000000 is
        // Int32.MinValue (`docs/udon_specs.md` §4.7).
        const signed: i64 = if (v <= 0xFFFF_FFFF) @as(i32, @bitCast(@as(u32, @intCast(v)))) else @bitCast(v);
        return .{ .int = if (negative) -signed else signed };
    }
    const last = body[body.len - 1];
    if (last == 'u' or last == 'U') {
        const v = std.fmt.parseInt(u64, body[0 .. body.len - 1], 10) catch return error.SyntaxError;
        if (negative) return error.SyntaxError;
        return .{ .uint = v };
    }
    if (std.fmt.parseInt(i64, body, 10)) |v| {
        return .{ .int = if (negative) -v else v };
    } else |_| {}
    var fbody = body;
    if (last == 'f' or last == 'F') fbody = body[0 .. body.len - 1];
    const f = std.fmt.parseFloat(f64, fbody) catch return error.SyntaxError;
    return .{ .float = if (negative) -f else f };
}

// ------------------------------- tests -------------------------------

const testing = std.testing;

test "parse hello world" {
    const src =
        \\.data_start
        \\    message: %SystemString, "Hello, world!"
        \\.data_end
        \\.code_start
        \\    .export _start
        \\    _start:
        \\        PUSH, message
        \\        EXTERN, "UnityEngineDebug.__Log__SystemObject__SystemVoid"
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    ;
    var p = try parse(testing.allocator, src, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.issues.len);
    try testing.expectEqual(@as(u32, 1), p.named_count);
    try testing.expectEqual(@as(u32, 2), p.heapSize());
    try testing.expectEqual(@as(usize, 3), p.code.len);
    try testing.expectEqual(@as(u32, 24), p.code_size);
    try testing.expectEqual(@as(u32, 0), p.labelAddr("_start").?);
    try testing.expect(p.labels[0].is_export);
    try testing.expectEqual(Param{ .heap = 0 }, p.code[0].param);
    try testing.expectEqual(Param{ .heap = 1 }, p.code[1].param);
    try testing.expectEqual(Param{ .address = halt_address }, p.code[2].param);
}

test "identical extern strings share one anonymous heap slot" {
    const src =
        \\.data_start
        \\.data_end
        \\.code_start
        \\    EXTERN, "A.__f__SystemVoid"
        \\    EXTERN, "B.__g__SystemVoid"
        \\    EXTERN, "A.__f__SystemVoid"
        \\.code_end
    ;
    var p = try parse(testing.allocator, src, null);
    defer p.deinit();
    try testing.expectEqual(@as(u32, 2), p.heapSize());
    try testing.expectEqual(p.code[0].param, p.code[2].param);
}

test "literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Literal{ .int = -5 }, try parseLiteral(a, "-5"));
    try testing.expectEqual(Literal{ .int = std.math.minInt(i32) }, try parseLiteral(a, "0x80000000"));
    try testing.expectEqual(Literal{ .uint = 0xFFFFFFFF }, try parseLiteral(a, "0xFFFFFFFFu"));
    try testing.expectEqual(Literal{ .uint = 4294967295 }, try parseLiteral(a, "4294967295u"));
    try testing.expectEqual(Literal{ .float = 1.5 }, try parseLiteral(a, "1.5"));
    try testing.expectEqualStrings("a\"b", (try parseLiteral(a, "\"a\\\"b\"")).string);
    try testing.expectError(error.SyntaxError, parseLiteral(a, "12abc"));
}

test "comment marker inside a string is not a comment" {
    try testing.expectEqualStrings("PUSH, \"a#b\" ", stripComment("PUSH, \"a#b\" # tail"));
}

test "undefined symbols are recorded, not fatal" {
    const src =
        \\.data_start
        \\    .export ghost
        \\.data_end
        \\.code_start
        \\    PUSH, nowhere
        \\    JUMP, missing
        \\.code_end
    ;
    var p = try parse(testing.allocator, src, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.issues.len);
    try testing.expect(p.code[0].param == .unresolved);
    try testing.expect(p.code[1].param == .unresolved);
}

test "syntax error reports the line" {
    var d: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(testing.allocator, ".data_start\n.data_end\n.code_start\n  FROB\n.code_end\n", &d));
    try testing.expectEqual(@as(u32, 4), d.line);
}
