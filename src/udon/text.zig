//! Udon Assembly text parser (`docs/udon_specs.md` §2, §4, §5).
//!
//! An implementation of the textual grammar that is independent of the
//! writer in `asm.zig`: `check.zig` and `vm.zig` consume its output, so the
//! tests exercise the program exactly as the Udon assembler would read it.
//! All slices in the result alias the source text or the arena.

const std = @import("std");

pub const Opcode = enum {
    NOP,
    PUSH,
    POP,
    JUMP_IF_FALSE,
    JUMP,
    EXTERN,
    ANNOTATION,
    JUMP_INDIRECT,
    COPY,

    pub fn size(op: Opcode) u32 {
        return switch (op) {
            .NOP, .POP, .ANNOTATION, .COPY => 4,
            .PUSH, .JUMP_IF_FALSE, .JUMP, .EXTERN, .JUMP_INDIRECT => 8,
        };
    }

    pub fn takesParam(op: Opcode) bool {
        return switch (op) {
            .NOP, .POP, .COPY => false,
            else => true,
        };
    }
};

pub const Literal = union(enum) {
    null_,
    this,
    boolean: bool,
    /// `magnitude` is the value as written, before the sign is applied.
    int: struct { magnitude: u64, negative: bool, unsigned: bool, hex: bool },
    float: f64,
    string: []const u8,
    char: u8,
};

pub const DataVar = struct {
    name: []const u8,
    ty: []const u8,
    init: Literal,
    exported: bool = false,
    sync: ?[]const u8 = null,
    line: u32,
};

pub const Param = union(enum) {
    none,
    int: u32,
    sym: []const u8,
    string: []const u8,
};

pub const Instr = struct {
    op: Opcode,
    param: Param,
    addr: u32,
    line: u32,
};

pub const Named = struct { name: []const u8, addr: u32 = 0, line: u32 };

pub const Diag = struct {
    line: u32 = 0,
    msg: []const u8 = "",
};

pub const Program = struct {
    vars: []const DataVar,
    instrs: []const Instr,
    labels: []const Named,
    /// `.export <label>` directives of the code section.
    exports: []const Named,
    /// `.export` / `.sync` directives naming variables that were never declared.
    dangling_attrs: []const Named,
    code_size: u32,
    var_index: std.StringHashMapUnmanaged(u32),
    addr_index: std.AutoHashMapUnmanaged(u32, u32),

    pub fn findVar(self: *const Program, name: []const u8) ?u32 {
        return self.var_index.get(name);
    }

    /// Index of the instruction that starts at `addr`.
    pub fn instrAt(self: *const Program, addr: u32) ?u32 {
        return self.addr_index.get(addr);
    }

    pub fn labelAddr(self: *const Program, name: []const u8) ?u32 {
        for (self.labels) |l| if (std.mem.eql(u8, l.name, name)) return l.addr;
        return null;
    }
};

pub const Error = error{Syntax} || std.mem.Allocator.Error;

/// First character: letter or `_`; then letters, digits, `_`, `[]`, `<>` (§4.4).
pub fn isValidName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |c, i| {
        const ok = std.ascii.isAlphabetic(c) or c == '_' or
            (i > 0 and (std.ascii.isDigit(c) or c == '[' or c == ']' or c == '<' or c == '>'));
        if (!ok) return false;
    }
    return true;
}

pub fn parse(arena: std.mem.Allocator, src: []const u8, diag: *Diag) Error!Program {
    var p: Parser = .{ .arena = arena, .diag = diag };
    return p.run(src);
}

const Parser = struct {
    arena: std.mem.Allocator,
    diag: *Diag,
    line: u32 = 0,
    vars: std.ArrayList(DataVar) = .empty,
    instrs: std.ArrayList(Instr) = .empty,
    labels: std.ArrayList(Named) = .empty,
    exports: std.ArrayList(Named) = .empty,
    attrs: std.ArrayList(struct { name: []const u8, sync: ?[]const u8, line: u32 }) = .empty,
    pc: u32 = 0,

    const Section = enum { none, data, code };

    fn fail(self: *Parser, msg: []const u8) Error {
        self.diag.* = .{ .line = self.line, .msg = msg };
        return error.Syntax;
    }

    fn run(self: *Parser, src: []const u8) Error!Program {
        var section: Section = .none;
        var seen_data = false;
        var seen_code = false;
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |raw| {
            self.line += 1;
            const text = std.mem.trim(u8, stripComment(raw), " \t\r");
            if (text.len == 0) continue;
            if (text[0] == '.' and !std.mem.startsWith(u8, text, ".export") and !std.mem.startsWith(u8, text, ".sync")) {
                const want: struct { Section, Section } =
                    if (std.mem.eql(u8, text, ".data_start")) .{ .none, .data } //
                    else if (std.mem.eql(u8, text, ".data_end")) .{ .data, .none } //
                    else if (std.mem.eql(u8, text, ".code_start")) .{ .none, .code } //
                    else if (std.mem.eql(u8, text, ".code_end")) .{ .code, .none } //
                    else return self.fail("unknown directive");
                if (section != want[0]) return self.fail("section directive out of place");
                section = want[1];
                if (section == .data) {
                    if (seen_data) return self.fail("duplicate data section");
                    seen_data = true;
                } else if (section == .code) {
                    if (seen_code) return self.fail("duplicate code section");
                    seen_code = true;
                }
                continue;
            }
            switch (section) {
                .none => return self.fail("statement outside of a section"),
                .data => try self.dataLine(text),
                .code => try self.codeLine(text),
            }
        }
        if (section != .none) return self.fail("unterminated section");

        var var_index: std.StringHashMapUnmanaged(u32) = .empty;
        for (self.vars.items, 0..) |v, i| {
            const gop = try var_index.getOrPut(self.arena, v.name);
            if (gop.found_existing) {
                self.line = v.line;
                return self.fail("duplicate variable");
            }
            gop.value_ptr.* = @intCast(i);
        }
        var dangling: std.ArrayList(Named) = .empty;
        for (self.attrs.items) |a| {
            if (var_index.get(a.name)) |i| {
                if (a.sync) |mode| self.vars.items[i].sync = mode else self.vars.items[i].exported = true;
            } else try dangling.append(self.arena, .{ .name = a.name, .line = a.line });
        }
        var addr_index: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        for (self.instrs.items, 0..) |ins, i| try addr_index.put(self.arena, ins.addr, @intCast(i));

        return .{
            .vars = self.vars.items,
            .instrs = self.instrs.items,
            .labels = self.labels.items,
            .exports = self.exports.items,
            .dangling_attrs = dangling.items,
            .code_size = self.pc,
            .var_index = var_index,
            .addr_index = addr_index,
        };
    }

    fn dataLine(self: *Parser, text: []const u8) Error!void {
        if (directiveArg(text, ".export")) |arg| {
            try self.attrs.append(self.arena, .{ .name = arg, .sync = null, .line = self.line });
        } else if (directiveArg(text, ".sync")) |arg| {
            const comma = std.mem.indexOfScalar(u8, arg, ',') orelse return self.fail(".sync needs a mode");
            try self.attrs.append(self.arena, .{
                .name = std.mem.trim(u8, arg[0..comma], " \t"),
                .sync = std.mem.trim(u8, arg[comma + 1 ..], " \t"),
                .line = self.line,
            });
        } else {
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse return self.fail("expected '<name>: %<type>, <init>'");
            const name = std.mem.trim(u8, text[0..colon], " \t");
            const rest = std.mem.trim(u8, text[colon + 1 ..], " \t");
            if (rest.len == 0 or rest[0] != '%') return self.fail("variable type must start with '%'");
            const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return self.fail("variable needs an initial value");
            try self.vars.append(self.arena, .{
                .name = name,
                .ty = std.mem.trim(u8, rest[1..comma], " \t"),
                .init = try self.literal(std.mem.trim(u8, rest[comma + 1 ..], " \t")),
                .line = self.line,
            });
        }
    }

    fn codeLine(self: *Parser, text: []const u8) Error!void {
        if (directiveArg(text, ".export")) |arg| {
            try self.exports.append(self.arena, .{ .name = arg, .line = self.line });
            return;
        }
        if (text[text.len - 1] == ':') {
            const name = std.mem.trim(u8, text[0 .. text.len - 1], " \t");
            try self.labels.append(self.arena, .{ .name = name, .addr = self.pc, .line = self.line });
            return;
        }
        const comma = std.mem.indexOfScalar(u8, text, ',');
        const mnemonic = std.mem.trim(u8, text[0 .. comma orelse text.len], " \t");
        const op = std.meta.stringToEnum(Opcode, mnemonic) orelse return self.fail("unknown opcode");
        var param: Param = .none;
        if (comma) |c| {
            if (!op.takesParam()) return self.fail("opcode takes no parameter");
            const arg = std.mem.trim(u8, text[c + 1 ..], " \t");
            if (arg.len == 0) return self.fail("missing parameter");
            param = if (arg[0] == '"')
                .{ .string = try self.string(arg) }
            else if (std.ascii.isDigit(arg[0]))
                .{ .int = std.fmt.parseInt(u32, arg, 0) catch return self.fail("bad integer parameter") }
            else
                .{ .sym = arg };
        } else if (op.takesParam()) return self.fail("opcode needs a parameter");
        try self.instrs.append(self.arena, .{ .op = op, .param = param, .addr = self.pc, .line = self.line });
        self.pc += op.size();
    }

    fn literal(self: *Parser, text: []const u8) Error!Literal {
        if (text.len == 0) return self.fail("missing initial value");
        if (std.mem.eql(u8, text, "null")) return .null_;
        if (std.mem.eql(u8, text, "this")) return .this;
        if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
        if (text[0] == '"') return .{ .string = try self.string(text) };
        if (text[0] == '\'') {
            if (text.len != 3 or text[2] != '\'') return self.fail("bad character literal");
            return .{ .char = text[1] };
        }
        var body = text;
        const negative = body[0] == '-';
        if (negative or body[0] == '+') body = body[1..];
        const unsigned = body.len > 1 and (body[body.len - 1] == 'u' or body[body.len - 1] == 'U');
        const digits = if (unsigned) body[0 .. body.len - 1] else body;
        const hex = std.mem.startsWith(u8, digits, "0x") or std.mem.startsWith(u8, digits, "0X");
        if (std.fmt.parseInt(u64, if (hex) digits[2..] else digits, if (hex) 16 else 10)) |magnitude| {
            return .{ .int = .{ .magnitude = magnitude, .negative = negative, .unsigned = unsigned, .hex = hex } };
        } else |_| {}
        // The assembler's float syntax is plain decimal with an optional exponent.
        for (body) |c| if (!std.ascii.isDigit(c) and c != '.' and c != 'e' and c != 'E' and c != '-' and c != '+')
            return self.fail("unrecognised literal");
        const f = std.fmt.parseFloat(f64, body) catch return self.fail("unrecognised literal");
        return .{ .float = if (negative) -f else f };
    }

    fn string(self: *Parser, text: []const u8) Error![]const u8 {
        if (text.len < 2 or text[text.len - 1] != '"') return self.fail("unterminated string literal");
        const body = text[1 .. text.len - 1];
        if (std.mem.indexOfScalar(u8, body, '\\') == null) {
            if (std.mem.indexOfScalar(u8, body, '"') != null) return self.fail("unescaped quote in string literal");
            return body;
        }
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] == '"') return self.fail("unescaped quote in string literal");
            if (body[i] != '\\') {
                try out.append(self.arena, body[i]);
                continue;
            }
            i += 1;
            if (i == body.len) return self.fail("dangling escape");
            try out.append(self.arena, switch (body[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"', '\\' => body[i],
                else => return self.fail("unknown escape"),
            });
        }
        return out.items;
    }
};

fn directiveArg(text: []const u8, directive: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, directive)) return null;
    const rest = text[directive.len..];
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) return null;
    return std.mem.trim(u8, rest, " \t");
}

/// Cut a trailing `# comment`, ignoring `#` inside string literals.
fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) switch (line[i]) {
        '\\' => if (in_string) {
            i += 1;
        },
        '"' => in_string = !in_string,
        '#' => if (!in_string) return line[0..i],
        else => {},
    };
    return line;
}

const testing = std.testing;

fn parseTest(arena: std.mem.Allocator, src: []const u8) !Program {
    var diag: Diag = .{};
    return parse(arena, src, &diag);
}

test "parses the spec's hello-world example" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseTest(arena.allocator(),
        \\.data_start
        \\    .export message
        \\    .sync message, none
        \\    message: %SystemString, "Hello, # world!"   # trailing comment
        \\    big: %SystemUInt32, 0xFFFFFFFFu
        \\.data_end
        \\.code_start
        \\    .export _start
        \\    _start:
        \\        PUSH, message
        \\        EXTERN, "UnityEngineDebug.__Log__SystemObject__SystemVoid"
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    );
    try testing.expectEqual(@as(usize, 2), p.vars.len);
    try testing.expect(p.vars[0].exported);
    try testing.expectEqualStrings("none", p.vars[0].sync.?);
    try testing.expectEqualStrings("Hello, # world!", p.vars[0].init.string);
    try testing.expect(p.vars[1].init.int.unsigned and p.vars[1].init.int.magnitude == 0xFFFFFFFF);
    try testing.expectEqual(@as(usize, 3), p.instrs.len);
    try testing.expectEqual(@as(u32, 16), p.instrs[2].addr);
    try testing.expectEqual(@as(u32, 24), p.code_size);
    try testing.expectEqual(@as(u32, 0), p.labelAddr("_start").?);
    try testing.expectEqual(@as(u32, 0xFFFFFFFC), p.instrs[2].param.int);
}

test "instruction sizes follow the opcode table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseTest(arena.allocator(),
        \\.code_start
        \\ NOP
        \\ PUSH, 1
        \\ POP
        \\ COPY
        \\ a:
        \\ JUMP_INDIRECT, x
        \\.code_end
    );
    try testing.expectEqual(@as(u32, 20), p.labelAddr("a").?);
    try testing.expectEqual(@as(u32, 1), p.instrAt(4).?);
    try testing.expect(p.instrAt(6) == null);
}

test "rejects malformed input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.Syntax, parseTest(a, "PUSH, x\n"));
    try testing.expectError(error.Syntax, parseTest(a, ".code_start\n FROB\n.code_end\n"));
    try testing.expectError(error.Syntax, parseTest(a, ".code_start\n COPY, x\n.code_end\n"));
    try testing.expectError(error.Syntax, parseTest(a, ".code_start\n PUSH\n.code_end\n"));
    try testing.expectError(error.Syntax, parseTest(a, ".data_start\n x: SystemInt32, 0\n.data_end\n"));
    try testing.expectError(error.Syntax, parseTest(a, ".data_start\n x: %SystemInt32, 0\n x: %SystemInt32, 0\n.data_end\n"));
    try testing.expectError(error.Syntax, parseTest(a, ".data_start\n"));
}

test "name rules" {
    try testing.expect(isValidName("_Number<0>"));
    try testing.expect(isValidName("__this_is_a_variable[][]__>>>"));
    try testing.expect(!isValidName("222x"));
    try testing.expect(!isValidName("$abc"));
    try testing.expect(!isValidName(""));
}
