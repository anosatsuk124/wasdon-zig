//! Udon VM emulator (`docs/udon_specs.md` §6, §9).
//!
//! Executes a parsed Udon Assembly program so translated WASM can be run
//! and compared against a real WASM engine without VRChat. The emulator is
//! deliberately strict in the places the real VM is:
//!
//!   * every heap slot carries a runtime type; reading it as a different
//!     primitive type faults ("Cannot retrieve heap variable of type X as
//!     type Y"), writes retype the slot (§4.3);
//!   * externs follow .NET semantics — wrapping integer arithmetic, checked
//!     `System.Convert` conversions that round half to even, bounds-checked
//!     arrays, `DivideByZeroException`, and so on. A thrown exception halts
//!     execution with `error.ExternException`.
//!
//! Only the externs the translator itself emits are built in; anything else
//! is routed to an optional host callback (used to mock Unity APIs in tests).

const std = @import("std");
const text = @import("text.zig");
const sig_mod = @import("sig.zig");

pub const Prim = enum {
    boolean,
    byte,
    sbyte,
    int16,
    uint16,
    char,
    int32,
    uint32,
    int64,
    uint64,
    single,
    double,

    pub fn Type(comptime p: Prim) type {
        return switch (p) {
            .boolean => bool,
            .byte => u8,
            .sbyte => i8,
            .int16 => i16,
            .uint16, .char => u16,
            .int32 => i32,
            .uint32 => u32,
            .int64 => i64,
            .uint64 => u64,
            .single => f32,
            .double => f64,
        };
    }

    pub fn size(p: Prim) usize {
        return switch (p) {
            inline else => |c| @sizeOf(Type(c)),
        };
    }

    const names = std.StaticStringMap(Prim).initComptime(.{
        .{ "SystemBoolean", .boolean }, .{ "SystemByte", .byte },     .{ "SystemSByte", .sbyte },
        .{ "SystemInt16", .int16 },     .{ "SystemUInt16", .uint16 }, .{ "SystemChar", .char },
        .{ "SystemInt32", .int32 },     .{ "SystemUInt32", .uint32 }, .{ "SystemInt64", .int64 },
        .{ "SystemUInt64", .uint64 },   .{ "SystemSingle", .single }, .{ "SystemDouble", .double },
    });

    pub fn fromName(name: []const u8) ?Prim {
        return names.get(name);
    }
};

pub const Array = struct {
    /// Element type for primitive arrays; `null` for reference arrays.
    elem: ?Prim,
    /// Little-endian element storage of a primitive array.
    bytes: []u8 = &.{},
    values: []Value = &.{},

    pub fn len(self: *const Array) usize {
        return if (self.elem) |p| self.bytes.len / p.size() else self.values.len;
    }
};

pub const Object = struct {
    ty: []const u8,
    /// Free-form payload for host callbacks (e.g. a mocked `Vector3`).
    data: [4]f64 = @splat(0),
};

pub const Value = union(enum) {
    null_,
    boolean: bool,
    byte: u8,
    sbyte: i8,
    int16: i16,
    uint16: u16,
    char: u16,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    single: f32,
    double: f64,
    string: []const u8,
    array: *Array,
    object: *Object,

    fn typeName(self: Value) []const u8 {
        return switch (self) {
            .null_ => "null",
            .string => "String",
            .array => "Array",
            .object => |o| o.ty,
            inline else => |_, tag| @tagName(tag),
        };
    }
};

pub const Error = error{
    /// A heap slot was read as a type it does not currently hold.
    HeapTypeMismatch,
    /// An extern threw (.NET exception) — the UdonBehaviour would halt.
    ExternException,
    UnknownExtern,
    BadProgram,
    StepLimit,
    NoSuchEvent,
} || std.mem.Allocator.Error;

/// Host callback for externs the emulator does not implement. Returns false
/// when the extern is unknown to the host as well.
pub const HostFn = *const fn (ctx: ?*anyopaque, vm: *Vm, name: []const u8, args: []const u32) Error!bool;

const Handler = *const fn (vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void;

const ExternInfo = struct {
    name: []const u8,
    handler: ?Handler = null,
    /// Operand count including `this` and the result slot.
    arity: u8 = 0,
    a: Prim = .int32,
    b: Prim = .int32,
    op: Op = .none,
};

const Op = enum {
    none,
    add,
    sub,
    mul,
    div,
    rem,
    @"and",
    @"or",
    xor,
    shl,
    shr,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    neg,
    not,
    abs,
    min,
    max,
    floor,
    ceil,
    trunc,
    round,
    sqrt,
};

const Code = struct {
    op: text.Opcode,
    arg: u32,
};

pub const Vm = struct {
    arena: std.heap.ArenaAllocator,
    heap: []Value,
    code: []Code,
    /// Instruction index by `address / 4`; `invalid` where none starts.
    addr_to_idx: []u32,
    externs: []ExternInfo,
    labels: []const text.Named,
    stack: std.ArrayList(u32) = .empty,
    /// Captured `Debug.Log*` output, one line per call.
    log: std.ArrayList(u8) = .empty,
    /// Human-readable description of the last fault.
    fault: []const u8 = "",
    steps: u64 = 0,
    extern_calls: u64 = 0,
    step_limit: u64 = 2_000_000_000,
    host: ?HostFn = null,
    host_ctx: ?*anyopaque = null,
    utf8: *Object = undefined,

    const invalid: u32 = std.math.maxInt(u32);

    pub fn init(gpa: std.mem.Allocator, prog: *const text.Program) Error!Vm {
        var vm: Vm = .{ .arena = .init(gpa), .heap = &.{}, .code = &.{}, .addr_to_idx = &.{}, .externs = &.{}, .labels = &.{} };
        errdefer vm.arena.deinit();
        const a = vm.arena.allocator();

        var extern_ids: std.StringHashMapUnmanaged(u32) = .empty;
        var externs: std.ArrayList(ExternInfo) = .empty;
        vm.code = try a.alloc(Code, prog.instrs.len);
        vm.addr_to_idx = try a.alloc(u32, prog.code_size / 4 + 1);
        @memset(vm.addr_to_idx, invalid);
        for (prog.instrs, 0..) |ins, i| {
            vm.addr_to_idx[ins.addr / 4] = @intCast(i);
            const arg: u32 = switch (ins.param) {
                .none => 0,
                .int => |v| v,
                .sym => |name| if (ins.op == .JUMP or ins.op == .JUMP_IF_FALSE)
                    prog.labelAddr(name) orelse return error.BadProgram
                else
                    prog.findVar(name) orelse return error.BadProgram,
                .string => |name| blk: {
                    if (ins.op != .EXTERN) return error.BadProgram;
                    const gop = try extern_ids.getOrPut(a, name);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = @intCast(externs.items.len);
                        try externs.append(a, resolveExtern(name));
                    }
                    break :blk gop.value_ptr.*;
                },
            };
            vm.code[i] = .{ .op = ins.op, .arg = arg };
        }
        vm.externs = externs.items;
        vm.labels = try a.dupe(text.Named, prog.labels);

        vm.heap = try a.alloc(Value, prog.vars.len);
        for (prog.vars, vm.heap) |v, *slot| slot.* = try vm.initialValue(v);
        vm.utf8 = try vm.newObject("SystemTextEncoding");
        return vm;
    }

    pub fn deinit(self: *Vm) void {
        self.arena.deinit();
    }

    fn initialValue(self: *Vm, v: text.DataVar) Error!Value {
        const a = self.arena.allocator();
        const prim = Prim.fromName(v.ty);
        switch (v.init) {
            .this => return .{ .object = try self.newObject(v.ty) },
            .string => |s| return .{ .string = try a.dupe(u8, s) },
            .null_ => {},
            .int => |i| {
                const bits: u32 = @truncate(if (i.negative) 0 -% i.magnitude else i.magnitude);
                switch (prim orelse return error.BadProgram) {
                    .int32 => return .{ .int32 = @bitCast(bits) },
                    .uint32 => return .{ .uint32 = bits },
                    .single => return .{ .single = @floatFromInt(@as(i32, @bitCast(bits))) },
                    .double => return .{ .double = @floatFromInt(@as(i32, @bitCast(bits))) },
                    else => return error.BadProgram,
                }
            },
            // The assembler reads every floating-point literal as `float` (§4.7).
            .float => |f| switch (prim orelse return error.BadProgram) {
                .single => return .{ .single = @floatCast(f) },
                .double => return .{ .double = @as(f32, @floatCast(f)) },
                else => return error.BadProgram,
            },
            .boolean, .char => return error.BadProgram,
        }
        // `null` gives value types their default.
        return if (prim) |p| switch (p) {
            inline else => |c| @unionInit(Value, @tagName(c), if (c == .boolean) false else 0),
        } else .null_;
    }

    pub fn newObject(self: *Vm, ty: []const u8) Error!*Object {
        const o = try self.arena.allocator().create(Object);
        o.* = .{ .ty = ty };
        return o;
    }

    pub fn newArray(self: *Vm, elem: ?Prim, n: usize) Error!*Array {
        const a = self.arena.allocator();
        const arr = try a.create(Array);
        arr.* = .{ .elem = elem };
        if (elem) |p| {
            arr.bytes = try a.alloc(u8, n * p.size());
            @memset(arr.bytes, 0);
        } else {
            arr.values = try a.alloc(Value, n);
            @memset(arr.values, .null_);
        }
        return arr;
    }

    fn setFault(self: *Vm, comptime fmt: []const u8, args: anytype) void {
        self.fault = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch "out of memory";
    }

    fn throw(self: *Vm, comptime fmt: []const u8, args: anytype) Error {
        self.setFault(fmt, args);
        return error.ExternException;
    }

    // ---- typed heap access ----

    pub fn get(self: *Vm, idx: u32, comptime p: Prim) Error!Prim.Type(p) {
        const v = self.heap[idx];
        if (v == @field(std.meta.Tag(Value), @tagName(p))) return @field(v, @tagName(p));
        self.setFault("cannot retrieve heap variable #{d} of type '{s}' as type '{s}'", .{ idx, v.typeName(), @tagName(p) });
        return error.HeapTypeMismatch;
    }

    pub fn set(self: *Vm, idx: u32, comptime p: Prim, v: Prim.Type(p)) void {
        self.heap[idx] = @unionInit(Value, @tagName(p), v);
    }

    pub fn getArray(self: *Vm, idx: u32) Error!*Array {
        switch (self.heap[idx]) {
            .array => |a| return a,
            .null_ => return self.throw("NullReferenceException: heap variable #{d} is null", .{idx}),
            else => |v| {
                self.setFault("cannot retrieve heap variable #{d} of type '{s}' as an array", .{ idx, v.typeName() });
                return error.HeapTypeMismatch;
            },
        }
    }

    fn getPrimArray(self: *Vm, idx: u32, p: Prim) Error!*Array {
        const arr = try self.getArray(idx);
        if (arr.elem == p) return arr;
        self.setFault("heap variable #{d} is not a {s}[]", .{ idx, @tagName(p) });
        return error.HeapTypeMismatch;
    }

    pub fn getString(self: *Vm, idx: u32) Error![]const u8 {
        return switch (self.heap[idx]) {
            .string => |s| s,
            .null_ => "",
            else => |v| {
                self.setFault("cannot retrieve heap variable #{d} of type '{s}' as type 'String'", .{ idx, v.typeName() });
                return error.HeapTypeMismatch;
            },
        };
    }

    // ---- execution ----

    pub fn hasEvent(self: *const Vm, name: []const u8) bool {
        for (self.labels) |l| if (std.mem.eql(u8, l.name, name)) return true;
        return false;
    }

    /// Run the exported event `name` until it jumps to the halt address.
    pub fn runEvent(self: *Vm, name: []const u8) Error!void {
        for (self.labels) |l| if (std.mem.eql(u8, l.name, name)) return self.run(l.addr);
        return error.NoSuchEvent;
    }

    pub fn run(self: *Vm, entry: u32) Error!void {
        const a = self.arena.allocator();
        self.stack.clearRetainingCapacity();
        var pc = try self.indexOf(entry);
        while (true) {
            if (pc >= self.code.len) {
                self.setFault("execution ran off the end of the program", .{});
                return error.BadProgram;
            }
            self.steps += 1;
            if (self.steps > self.step_limit) return error.StepLimit;
            const c = self.code[pc];
            pc += 1;
            switch (c.op) {
                .NOP, .ANNOTATION => {},
                .PUSH => try self.stack.append(a, c.arg),
                .POP => _ = self.stack.pop() orelse return error.BadProgram,
                .COPY => {
                    const dst = self.stack.pop() orelse return error.BadProgram;
                    const src = self.stack.pop() orelse return error.BadProgram;
                    self.heap[dst] = self.heap[src];
                },
                .JUMP_IF_FALSE => {
                    const cond = self.stack.pop() orelse return error.BadProgram;
                    if (!try self.get(cond, .boolean)) pc = try self.indexOf(c.arg);
                },
                .JUMP => {
                    if (c.arg == 0xFFFFFFFC) return;
                    pc = try self.indexOf(c.arg);
                },
                .JUMP_INDIRECT => {
                    const addr = try self.get(c.arg, .uint32);
                    if (addr == 0xFFFFFFFC) return;
                    pc = try self.indexOf(addr);
                },
                .EXTERN => {
                    const ext = &self.externs[c.arg];
                    self.extern_calls += 1;
                    if (ext.handler) |h| {
                        if (self.stack.items.len < ext.arity) return error.BadProgram;
                        const base = self.stack.items.len - ext.arity;
                        try h(self, ext, self.stack.items[base..]);
                        self.stack.shrinkRetainingCapacity(base);
                    } else {
                        const handled = if (self.host) |host| try host(self.host_ctx, self, ext.name, self.stack.items) else false;
                        if (!handled) {
                            self.setFault("extern \"{s}\" is not implemented by the emulator", .{ext.name});
                            return error.UnknownExtern;
                        }
                        self.stack.clearRetainingCapacity();
                    }
                },
            }
        }
    }

    fn indexOf(self: *Vm, addr: u32) Error!u32 {
        if (addr % 4 == 0 and addr / 4 < self.addr_to_idx.len) {
            const idx = self.addr_to_idx[addr / 4];
            if (idx != invalid) return idx;
        }
        self.setFault("jump to 0x{X}, which is not an instruction boundary", .{addr});
        return error.BadProgram;
    }

    pub fn appendLog(self: *Vm, prefix: []const u8, idx: u32) Error!void {
        const a = self.arena.allocator();
        try self.log.appendSlice(a, prefix);
        switch (self.heap[idx]) {
            .string => |s| try self.log.appendSlice(a, s),
            .null_ => try self.log.appendSlice(a, "Null"),
            .boolean => |b| try self.log.appendSlice(a, if (b) "True" else "False"),
            .array, .object => try self.log.appendSlice(a, self.heap[idx].typeName()),
            inline else => |v| try self.log.print(a, "{d}", .{v}),
        }
        try self.log.append(a, '\n');
    }
};

// ---------------------------------------------------------------------
// Extern resolution
// ---------------------------------------------------------------------

const ops_by_method = std.StaticStringMap(Op).initComptime(.{
    .{ "op_Addition", .add },          .{ "op_Subtraction", .sub },     .{ "op_Multiplication", .mul },
    .{ "op_Division", .div },          .{ "op_Remainder", .rem },       .{ "op_LogicalAnd", .@"and" },
    .{ "op_LogicalOr", .@"or" },       .{ "op_LogicalXor", .xor },      .{ "op_LeftShift", .shl },
    .{ "op_RightShift", .shr },        .{ "op_Equality", .eq },         .{ "op_Inequality", .ne },
    .{ "op_LessThan", .lt },           .{ "op_LessThanOrEqual", .le },  .{ "op_GreaterThan", .gt },
    .{ "op_GreaterThanOrEqual", .ge }, .{ "op_UnaryMinus", .neg },      .{ "op_UnaryNegation", .not },
    .{ "op_ConditionalAnd", .@"and" }, .{ "op_ConditionalOr", .@"or" }, .{ "op_ConditionalXor", .xor },
    .{ "Abs", .abs },                  .{ "Min", .min },                .{ "Max", .max },
    .{ "Floor", .floor },              .{ "Ceiling", .ceil },           .{ "Ceil", .ceil },
    .{ "Truncate", .trunc },           .{ "Round", .round },            .{ "Sqrt", .sqrt },
});

const fixed_externs = std.StaticStringMap(Handler).initComptime(.{
    .{ "SystemMath.__DivRem__SystemInt64_SystemInt64_SystemInt64Ref__SystemInt64", &hDivRem64 },
    .{ "SystemArray.__Copy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid", &hArrayCopy },
    .{ "SystemArray.__Clear__SystemArray_SystemInt32_SystemInt32__SystemVoid", &hArrayClear },
    .{ "SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid", &hBlockCopy },
    .{ "SystemConvert.__FromBase64String__SystemString__SystemByteArray", &hFromBase64 },
    .{ "SystemTextEncoding.__get_UTF8__SystemTextEncoding", &hGetUtf8 },
    .{ "SystemTextEncoding.__GetString__SystemByteArray_SystemInt32_SystemInt32__SystemString", &hGetString },
    .{ "SystemTextEncoding.__GetString__SystemByteArray__SystemString", &hGetStringAll },
    .{ "SystemString.__Concat__SystemString_SystemString__SystemString", &hConcat },
    .{ "SystemString.__Concat__SystemString_SystemString_SystemString__SystemString", &hConcat },
    .{ "SystemString.__Concat__SystemString_SystemString_SystemString_SystemString__SystemString", &hConcat },
    .{ "SystemInt32.__ToString__SystemString", &hInt32ToString },
    .{ "SystemObject.__op_Equality__SystemObject_SystemObject__SystemBoolean", &hSameObject },
    .{ "SystemObject.__op_Inequality__SystemObject_SystemObject__SystemBoolean", &hSameObject },
    .{ "UnityEngineDebug.__Log__SystemObject__SystemVoid", &hLog },
    .{ "UnityEngineDebug.__LogWarning__SystemObject__SystemVoid", &hLog },
    .{ "UnityEngineDebug.__LogError__SystemObject__SystemVoid", &hLog },
    .{ "SystemBitConverter.__SingleToInt32Bits__SystemSingle__SystemInt32", &hBitcast },
    .{ "SystemBitConverter.__Int32BitsToSingle__SystemInt32__SystemSingle", &hBitcast },
    .{ "SystemBitConverter.__DoubleToInt64Bits__SystemDouble__SystemInt64", &hBitcast },
    .{ "SystemBitConverter.__Int64BitsToDouble__SystemInt64__SystemDouble", &hBitcast },
});

fn resolveExtern(name: []const u8) ExternInfo {
    var info: ExternInfo = .{ .name = name };
    const sig = sig_mod.parse(name) orelse return info;
    const fixed: u8 = sig.nargs + @intFromBool(sig.returnsValue());
    info.arity = fixed;
    const recv = sig.receiver;
    const arg0: ?Prim = if (sig.nargs > 0) Prim.fromName(sig.args()[0].ty) else null;
    const ret = Prim.fromName(sig.ret);

    if (fixed_externs.get(name)) |h| {
        info.handler = h;
        if (sig.isInstance() == true) info.arity += 1;
        if (arg0) |p| info.a = p;
        if (ret) |p| info.b = p;
        return info;
    }
    if (std.mem.eql(u8, recv, "SystemConvert") and std.mem.startsWith(u8, sig.method, "To") and sig.nargs == 1) {
        info.a = arg0 orelse return info;
        info.b = ret orelse return info;
        info.handler = &hConvert;
    } else if (std.mem.eql(u8, recv, "SystemBitConverter") and sig.nargs == 2 and std.mem.startsWith(u8, sig.method, "To")) {
        info.b = ret orelse return info;
        info.handler = &hFromBytes;
    } else if (std.mem.eql(u8, recv, "SystemBitConverter") and std.mem.eql(u8, sig.method, "GetBytes")) {
        info.a = arg0 orelse return info;
        info.handler = &hGetBytes;
    } else if (std.mem.endsWith(u8, recv, "Array") and recv.len > 5) {
        // `info.b` holds the element type; reference arrays use `.op = .none` as marker.
        const elem = Prim.fromName(recv[0 .. recv.len - 5]);
        if (elem) |p| info.b = p;
        info.op = if (elem == null) .none else .add;
        const m = sig.method;
        if (std.mem.eql(u8, m, "ctor") and sig.nargs == 1) {
            info.handler = &hArrayCtor;
        } else if (std.mem.eql(u8, m, "Get") or (std.mem.eql(u8, m, "GetValue") and sig.nargs == 1)) {
            info.handler = &hArrayGet;
            info.arity += 1;
        } else if (std.mem.eql(u8, m, "Set") and sig.nargs == 2) {
            info.handler = &hArraySet;
            info.arity += 1;
        } else if (std.mem.eql(u8, m, "SetValue") and sig.nargs == 2) {
            info.handler = &hArraySetValue;
            info.arity += 1;
        } else if (std.mem.eql(u8, m, "get_Length")) {
            info.handler = &hArrayLength;
            info.arity += 1;
        } else if (std.mem.eql(u8, m, "CopyTo") and sig.nargs == 2 and arg0 == null) {
            info.handler = &hArrayCopyTo;
            info.arity += 1;
        }
    } else if (ops_by_method.get(sig.method)) |op| {
        const is_math = std.mem.eql(u8, recv, "SystemMath") or std.mem.eql(u8, recv, "UnityEngineMathf");
        if (!is_math and Prim.fromName(recv) == null) return info;
        info.op = op;
        info.a = arg0 orelse return info;
        info.handler = if (sig.nargs == 2) &hBinary else if (sig.nargs == 1) &hUnary else null;
    }
    return info;
}

// ---------------------------------------------------------------------
// Extern implementations
// ---------------------------------------------------------------------

fn hBinary(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    switch (ext.a) {
        .boolean => {
            const x = try vm.get(args[0], .boolean);
            const y = try vm.get(args[1], .boolean);
            vm.set(args[2], .boolean, switch (ext.op) {
                .@"and" => x and y,
                .@"or" => x or y,
                .xor, .ne => x != y,
                .eq => x == y,
                else => return error.UnknownExtern,
            });
        },
        inline .int32, .uint32, .int64, .uint64 => |p| {
            const T = Prim.Type(p);
            const x = try vm.get(args[0], p);
            if (ext.op == .shl or ext.op == .shr) {
                // .NET masks the count to the operand width.
                const count: std.math.Log2Int(T) = @truncate(@as(u32, @bitCast(try vm.get(args[1], .int32))));
                return vm.set(args[2], p, if (ext.op == .shl) x << count else x >> count);
            }
            const y = try vm.get(args[1], p);
            switch (ext.op) {
                .eq => return vm.set(args[2], .boolean, x == y),
                .ne => return vm.set(args[2], .boolean, x != y),
                .lt => return vm.set(args[2], .boolean, x < y),
                .le => return vm.set(args[2], .boolean, x <= y),
                .gt => return vm.set(args[2], .boolean, x > y),
                .ge => return vm.set(args[2], .boolean, x >= y),
                else => {},
            }
            vm.set(args[2], p, switch (ext.op) {
                .add => x +% y,
                .sub => x -% y,
                .mul => x *% y,
                .@"and" => x & y,
                .@"or" => x | y,
                .xor => x ^ y,
                .min => @min(x, y),
                .max => @max(x, y),
                .div, .rem => blk: {
                    if (y == 0) return vm.throw("DivideByZeroException", .{});
                    if (@typeInfo(T).int.signedness == .signed and x == std.math.minInt(T) and y == -1)
                        return vm.throw("OverflowException: {s}.MinValue / -1", .{@tagName(p)});
                    break :blk if (ext.op == .div) @divTrunc(x, y) else @rem(x, y);
                },
                else => return error.UnknownExtern,
            });
        },
        inline .single, .double => |p| {
            const x = try vm.get(args[0], p);
            const y = try vm.get(args[1], p);
            switch (ext.op) {
                .eq => return vm.set(args[2], .boolean, x == y),
                .ne => return vm.set(args[2], .boolean, x != y),
                .lt => return vm.set(args[2], .boolean, x < y),
                .le => return vm.set(args[2], .boolean, x <= y),
                .gt => return vm.set(args[2], .boolean, x > y),
                .ge => return vm.set(args[2], .boolean, x >= y),
                else => {},
            }
            vm.set(args[2], p, switch (ext.op) {
                .add => x + y,
                .sub => x - y,
                .mul => x * y,
                .div => x / y,
                .rem => @rem(x, y),
                // Mono's Math.Min/Max: NaN propagates, signed zeros are not ordered.
                .min => if (x < y) x else if (std.math.isNan(x)) x else y,
                .max => if (x > y) x else if (std.math.isNan(x)) x else y,
                else => return error.UnknownExtern,
            });
        },
        else => return error.UnknownExtern,
    }
}

fn roundHalfEven(x: f64) f64 {
    if (@abs(x - @trunc(x)) == 0.5) return 2.0 * @round(x / 2.0);
    return @round(x);
}

fn hUnary(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    switch (ext.a) {
        .boolean => vm.set(args[1], .boolean, !try vm.get(args[0], .boolean)),
        inline .int32, .int64 => |p| {
            const x = try vm.get(args[0], p);
            vm.set(args[1], p, switch (ext.op) {
                .neg => 0 -% x,
                .abs => if (x == std.math.minInt(Prim.Type(p))) return vm.throw("OverflowException: Math.Abs", .{}) else @intCast(@abs(x)),
                else => return error.UnknownExtern,
            });
        },
        inline .single, .double => |p| {
            const x = try vm.get(args[0], p);
            vm.set(args[1], p, switch (ext.op) {
                .neg => -x,
                .abs => @abs(x),
                .floor => @floor(x),
                .ceil => @ceil(x),
                .trunc => @trunc(x),
                .sqrt => @sqrt(x),
                .round => @floatCast(roundHalfEven(x)),
                else => return error.UnknownExtern,
            });
        },
        else => return error.UnknownExtern,
    }
}

fn hDivRem64(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    const x = try vm.get(args[0], .int64);
    const y = try vm.get(args[1], .int64);
    if (y == 0) return vm.throw("DivideByZeroException", .{});
    if (x == std.math.minInt(i64) and y == -1) return vm.throw("OverflowException: Math.DivRem", .{});
    vm.set(args[2], .int64, @rem(x, y));
    vm.set(args[3], .int64, @divTrunc(x, y));
}

/// `System.Convert.ToX(Y)`: range-checked, floats round half to even.
fn hConvert(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    const Wide = union(enum) { int: i128, float: f64 };
    const src: Wide = switch (ext.a) {
        .boolean => .{ .int = @intFromBool(try vm.get(args[0], .boolean)) },
        inline .single, .double => |p| .{ .float = try vm.get(args[0], p) },
        inline else => |p| .{ .int = try vm.get(args[0], p) },
    };
    switch (ext.b) {
        .boolean => vm.set(args[1], .boolean, switch (src) {
            .int => |i| i != 0,
            .float => |f| f != 0,
        }),
        .single => vm.set(args[1], .single, switch (src) {
            .int => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
        }),
        .double => vm.set(args[1], .double, switch (src) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
        }),
        inline else => |p| {
            const T = Prim.Type(p);
            const wide: i128 = switch (src) {
                .int => |i| i,
                .float => |f| blk: {
                    const r = roundHalfEven(f);
                    if (std.math.isNan(r) or r < -1.0e30 or r > 1.0e30) return vm.throw("OverflowException: Convert.To{s}({d})", .{ @tagName(p), f });
                    break :blk @intFromFloat(r);
                },
            };
            const v = std.math.cast(T, wide) orelse return vm.throw("OverflowException: Convert.To{s}({d})", .{ @tagName(p), wide });
            vm.set(args[1], p, v);
        },
    }
}

fn hBitcast(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    switch (ext.a) {
        .single => vm.set(args[1], .int32, @bitCast(try vm.get(args[0], .single))),
        .int32 => vm.set(args[1], .single, @bitCast(try vm.get(args[0], .int32))),
        .double => vm.set(args[1], .int64, @bitCast(try vm.get(args[0], .double))),
        .int64 => vm.set(args[1], .double, @bitCast(try vm.get(args[0], .int64))),
        else => return error.UnknownExtern,
    }
}

fn loadLe(comptime p: Prim, bytes: []const u8) Prim.Type(p) {
    const T = Prim.Type(p);
    if (T == bool) return bytes[0] != 0;
    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    return @bitCast(std.mem.readInt(U, bytes[0..@sizeOf(T)], .little));
}

fn storeLe(comptime p: Prim, bytes: []u8, v: Prim.Type(p)) void {
    const T = Prim.Type(p);
    if (T == bool) {
        bytes[0] = @intFromBool(v);
        return;
    }
    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    std.mem.writeInt(U, bytes[0..@sizeOf(T)], @bitCast(v), .little);
}

fn index(vm: *Vm, idx: u32, len: usize) Error!usize {
    const i = try vm.get(idx, .int32);
    if (i < 0 or @as(usize, @intCast(i)) >= len) return vm.throw("IndexOutOfRangeException: index {d}, length {d}", .{ i, len });
    return @intCast(i);
}

/// Validate `[start, start + count)` against `len` for the range-taking externs.
fn range(vm: *Vm, start_idx: u32, count_idx: u32, len: usize) Error!struct { usize, usize } {
    const start = try vm.get(start_idx, .int32);
    const count = try vm.get(count_idx, .int32);
    if (start < 0 or count < 0 or @as(u64, @intCast(start)) + @as(u64, @intCast(count)) > len)
        return vm.throw("ArgumentException: range [{d}, +{d}) exceeds length {d}", .{ start, count, len });
    return .{ @intCast(start), @intCast(count) };
}

/// `BitConverter.ToX(byte[] value, int startIndex)`.
fn hFromBytes(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    const arr = try vm.getPrimArray(args[0], .byte);
    const start = try vm.get(args[1], .int32);
    switch (ext.b) {
        inline else => |p| {
            const n = @sizeOf(Prim.Type(p));
            if (start < 0 or @as(usize, @intCast(start)) + n > arr.bytes.len)
                return vm.throw("ArgumentException: BitConverter.To{s} at {d}, length {d}", .{ @tagName(p), start, arr.bytes.len });
            vm.set(args[2], p, loadLe(p, arr.bytes[@intCast(start)..]));
        },
    }
}

fn hGetBytes(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    switch (ext.a) {
        inline else => |p| {
            const arr = try vm.newArray(.byte, @sizeOf(Prim.Type(p)));
            storeLe(p, arr.bytes, try vm.get(args[0], p));
            vm.heap[args[1]] = .{ .array = arr };
        },
    }
}

fn elemOf(ext: *const ExternInfo) ?Prim {
    return if (ext.op == .none) null else ext.b;
}

fn hArrayCtor(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    const n = try vm.get(args[0], .int32);
    if (n < 0) return vm.throw("OverflowException: negative array size {d}", .{n});
    vm.heap[args[1]] = .{ .array = try vm.newArray(elemOf(ext), @intCast(n)) };
}

fn typedArray(vm: *Vm, ext: *const ExternInfo, idx: u32) Error!*Array {
    const arr = try vm.getArray(idx);
    if (arr.elem != elemOf(ext)) {
        vm.setFault("extern \"{s}\" called on an array of a different element type", .{ext.name});
        return error.HeapTypeMismatch;
    }
    return arr;
}

fn hArrayGet(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    const arr = try typedArray(vm, ext, args[0]);
    const i = try index(vm, args[1], arr.len());
    if (arr.elem) |elem| switch (elem) {
        inline else => |p| vm.set(args[2], p, loadLe(p, arr.bytes[i * @sizeOf(Prim.Type(p)) ..])),
    } else vm.heap[args[2]] = arr.values[i];
}

fn hArraySet(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    const arr = try typedArray(vm, ext, args[0]);
    const i = try index(vm, args[1], arr.len());
    if (arr.elem) |elem| switch (elem) {
        inline else => |p| storeLe(p, arr.bytes[i * @sizeOf(Prim.Type(p)) ..], try vm.get(args[2], p)),
    } else arr.values[i] = vm.heap[args[2]];
}

/// `array.SetValue(value, index)` — note the argument order.
fn hArraySetValue(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    return hArraySet(vm, ext, &.{ args[0], args[2], args[1] });
}

fn hArrayLength(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    vm.set(args[1], .int32, @intCast((try vm.getArray(args[0])).len()));
}

fn copyElems(vm: *Vm, src: *Array, s: usize, dst: *Array, d: usize, n: usize) Error!void {
    if (src.elem != dst.elem) return vm.throw("ArrayTypeMismatchException", .{});
    if (src.elem) |p| {
        const w = p.size();
        @memmove(dst.bytes[d * w ..][0 .. n * w], src.bytes[s * w ..][0 .. n * w]);
    } else @memmove(dst.values[d..][0..n], src.values[s..][0..n]);
}

/// `Array.Copy(src, srcIndex, dst, dstIndex, length)` — memmove semantics.
fn hArrayCopy(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    const src = try vm.getArray(args[0]);
    const dst = try vm.getArray(args[2]);
    const s, const n = try range(vm, args[1], args[4], src.len());
    const d, _ = try range(vm, args[3], args[4], dst.len());
    try copyElems(vm, src, s, dst, d, n);
}

/// `src.CopyTo(dst, index)`.
fn hArrayCopyTo(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    const src = try vm.getArray(args[0]);
    const dst = try vm.getArray(args[1]);
    const d = try vm.get(args[2], .int32);
    if (d < 0 or @as(usize, @intCast(d)) + src.len() > dst.len()) return vm.throw("ArgumentException: CopyTo at {d} overflows the destination", .{d});
    try copyElems(vm, src, 0, dst, @intCast(d), src.len());
}

fn hArrayClear(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    const arr = try vm.getArray(args[0]);
    const s, const n = try range(vm, args[1], args[2], arr.len());
    if (arr.elem) |p| @memset(arr.bytes[s * p.size() ..][0 .. n * p.size()], 0) else @memset(arr.values[s..][0..n], .null_);
}

/// `Buffer.BlockCopy(src, srcOffset, dst, dstOffset, count)` — byte offsets
/// over primitive arrays, memmove semantics.
fn hBlockCopy(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    const src = try vm.getArray(args[0]);
    const dst = try vm.getArray(args[2]);
    if (src.elem == null or dst.elem == null) return vm.throw("ArgumentException: BlockCopy needs primitive arrays", .{});
    const s, const n = try range(vm, args[1], args[4], src.bytes.len);
    const d, _ = try range(vm, args[3], args[4], dst.bytes.len);
    @memmove(dst.bytes[d..][0..n], src.bytes[s..][0..n]);
}

fn hFromBase64(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    const s = try vm.getString(args[0]);
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return vm.throw("FormatException: invalid base64", .{});
    const arr = try vm.newArray(.byte, n);
    dec.decode(arr.bytes, s) catch return vm.throw("FormatException: invalid base64", .{});
    vm.heap[args[1]] = .{ .array = arr };
}

fn hGetUtf8(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    vm.heap[args[0]] = .{ .object = vm.utf8 };
}

/// `encoding.GetString(bytes, index, count)`.
fn hGetString(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    if (vm.heap[args[0]] != .object) return vm.throw("NullReferenceException: encoding is null", .{});
    const arr = try vm.getPrimArray(args[1], .byte);
    const s, const n = try range(vm, args[2], args[3], arr.bytes.len);
    vm.heap[args[4]] = .{ .string = try vm.arena.allocator().dupe(u8, arr.bytes[s..][0..n]) };
}

fn hGetStringAll(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    if (vm.heap[args[0]] != .object) return vm.throw("NullReferenceException: encoding is null", .{});
    const arr = try vm.getPrimArray(args[1], .byte);
    vm.heap[args[2]] = .{ .string = try vm.arena.allocator().dupe(u8, arr.bytes) };
}

fn hConcat(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    var out: std.ArrayList(u8) = .empty;
    for (args[0 .. args.len - 1]) |a| try out.appendSlice(vm.arena.allocator(), try vm.getString(a));
    vm.heap[args[args.len - 1]] = .{ .string = out.items };
}

fn hInt32ToString(vm: *Vm, _: *const ExternInfo, args: []const u32) Error!void {
    const v = try vm.get(args[0], .int32);
    vm.heap[args[1]] = .{ .string = try std.fmt.allocPrint(vm.arena.allocator(), "{d}", .{v}) };
}

/// Reference (in)equality — in practice a null check on an object handle.
fn hSameObject(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    const a = vm.heap[args[0]];
    const b = vm.heap[args[1]];
    const same = switch (a) {
        .null_ => b == .null_,
        .object => |o| b == .object and b.object == o,
        .array => |o| b == .array and b.array == o,
        .string => |s| b == .string and s.ptr == b.string.ptr,
        else => return vm.throw("op_Equality on a boxed value type is not modelled", .{}),
    };
    vm.set(args[2], .boolean, same == (std.mem.indexOf(u8, ext.name, "Inequality") == null));
}

fn hLog(vm: *Vm, ext: *const ExternInfo, args: []const u32) Error!void {
    const prefix = if (std.mem.indexOf(u8, ext.name, "LogError") != null)
        "[error] "
    else if (std.mem.indexOf(u8, ext.name, "LogWarning") != null)
        "[warning] "
    else
        "";
    try vm.appendLog(prefix, args[0]);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

const TestVm = struct {
    arena: std.heap.ArenaAllocator,
    vm: Vm,

    fn init(src: []const u8) !TestVm {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        var diag: text.Diag = .{};
        const prog = try text.parse(arena.allocator(), src, &diag);
        return .{ .arena = arena, .vm = try Vm.init(testing.allocator, &prog) };
    }

    fn deinit(self: *TestVm) void {
        self.vm.deinit();
        self.arena.deinit();
    }
};

test "hello world logs and halts" {
    var t = try TestVm.init(
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
    );
    defer t.deinit();
    try t.vm.runEvent("_start");
    try testing.expectEqualStrings("Hello, world!\n", t.vm.log.items);
    try testing.expectError(error.NoSuchEvent, t.vm.runEvent("_update"));
}

test "loop with JUMP_IF_FALSE and JUMP_INDIRECT" {
    // sum = 0; for (i = 0; i < 5; i++) sum += i; then return through `ret`.
    var t = try TestVm.init(
        \\.data_start
        \\    i: %SystemInt32, 0
        \\    sum: %SystemInt32, 0
        \\    one: %SystemInt32, 1
        \\    five: %SystemInt32, 5
        \\    c: %SystemBoolean, null
        \\    ret: %SystemUInt32, 0x00000080
        \\.data_end
        \\.code_start
        \\    _start:
        \\        PUSH, i
        \\        PUSH, five
        \\        PUSH, c
        \\        EXTERN, "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean"
        \\        PUSH, c
        \\        JUMP_IF_FALSE, 0x00000078
        \\        PUSH, sum
        \\        PUSH, i
        \\        PUSH, sum
        \\        EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
        \\        PUSH, i
        \\        PUSH, one
        \\        PUSH, i
        \\        EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
        \\        JUMP, 0x00000000
        \\        JUMP_INDIRECT, ret
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    );
    defer t.deinit();
    try t.vm.runEvent("_start");
    try testing.expectEqual(@as(i32, 10), t.vm.heap[1].int32);
}

test "reading a slot as the wrong primitive type faults" {
    var t = try TestVm.init(
        \\.data_start
        \\    a: %SystemInt32, 1
        \\    r: %SystemUInt32, 0
        \\.data_end
        \\.code_start
        \\    _start:
        \\        PUSH, a
        \\        PUSH, a
        \\        PUSH, r
        \\        EXTERN, "SystemUInt32.__op_Addition__SystemUInt32_SystemUInt32__SystemUInt32"
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    );
    defer t.deinit();
    try testing.expectError(error.HeapTypeMismatch, t.vm.runEvent("_start"));
}

test "COPY retypes the destination slot" {
    var t = try TestVm.init(
        \\.data_start
        \\    a: %SystemInt64, null
        \\    b: %SystemInt32, 7
        \\.data_end
        \\.code_start
        \\    _start:
        \\        PUSH, a
        \\        PUSH, b
        \\        COPY
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    );
    defer t.deinit();
    try t.vm.runEvent("_start");
    try testing.expectEqual(@as(i64, 0), t.vm.heap[1].int64);
}

test ".NET conversion and arithmetic semantics" {
    var t = try TestVm.init(
        \\.data_start
        \\    d: %SystemDouble, 2.5
        \\    i: %SystemInt32, 0
        \\    big: %SystemInt32, 2147483647
        \\    one: %SystemInt32, 1
        \\    zero: %SystemInt32, 0
        \\    neg: %SystemInt32, -8
        \\    l: %SystemInt64, null
        \\.data_end
        \\.code_start
        \\    round:
        \\        PUSH, d
        \\        PUSH, i
        \\        EXTERN, "SystemConvert.__ToInt32__SystemDouble__SystemInt32"
        \\        JUMP, 0xFFFFFFFC
        \\    wrap:
        \\        PUSH, big
        \\        PUSH, one
        \\        PUSH, i
        \\        EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
        \\        JUMP, 0xFFFFFFFC
        \\    shift:
        \\        PUSH, neg
        \\        PUSH, one
        \\        PUSH, i
        \\        EXTERN, "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32"
        \\        JUMP, 0xFFFFFFFC
        \\    divzero:
        \\        PUSH, one
        \\        PUSH, zero
        \\        PUSH, i
        \\        EXTERN, "SystemInt32.__op_Division__SystemInt32_SystemInt32__SystemInt32"
        \\        JUMP, 0xFFFFFFFC
        \\    narrow:
        \\        PUSH, l
        \\        PUSH, big
        \\        PUSH, l
        \\        EXTERN, "SystemInt64.__op_LeftShift__SystemInt64_SystemInt32__SystemInt64"
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    );
    defer t.deinit();
    try t.vm.runEvent("round");
    try testing.expectEqual(@as(i32, 2), t.vm.heap[1].int32); // 2.5 rounds to even
    try t.vm.runEvent("wrap");
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), t.vm.heap[1].int32);
    try t.vm.runEvent("shift");
    try testing.expectEqual(@as(i32, -4), t.vm.heap[1].int32);
    try testing.expectError(error.ExternException, t.vm.runEvent("divzero"));
    try t.vm.runEvent("narrow");
}

test "byte arrays, BitConverter and BlockCopy" {
    var t = try TestVm.init(
        \\.data_start
        \\    mem: %SystemByteArray, null
        \\    box: %SystemInt32Array, null
        \\    n: %SystemInt32, 16
        \\    one: %SystemInt32, 1
        \\    zero: %SystemInt32, 0
        \\    four: %SystemInt32, 4
        \\    five: %SystemInt32, 5
        \\    v: %SystemInt32, 0x11223344
        \\    out: %SystemInt32, 0
        \\    b: %SystemByte, null
        \\.data_end
        \\.code_start
        \\    _start:
        \\        PUSH, n
        \\        PUSH, mem
        \\        EXTERN, "SystemByteArray.__ctor__SystemInt32__SystemByteArray"
        \\        PUSH, one
        \\        PUSH, box
        \\        EXTERN, "SystemInt32Array.__ctor__SystemInt32__SystemInt32Array"
        \\        PUSH, box
        \\        PUSH, zero
        \\        PUSH, v
        \\        EXTERN, "SystemInt32Array.__Set__SystemInt32_SystemInt32__SystemVoid"
        \\        PUSH, box
        \\        PUSH, zero
        \\        PUSH, mem
        \\        PUSH, five
        \\        PUSH, four
        \\        EXTERN, "SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid"
        \\        PUSH, mem
        \\        PUSH, four
        \\        PUSH, out
        \\        EXTERN, "SystemBitConverter.__ToInt32__SystemByteArray_SystemInt32__SystemInt32"
        \\        PUSH, mem
        \\        PUSH, five
        \\        PUSH, b
        \\        EXTERN, "SystemByteArray.__Get__SystemInt32__SystemByte"
        \\        JUMP, 0xFFFFFFFC
        \\    oob:
        \\        PUSH, mem
        \\        PUSH, n
        \\        PUSH, b
        \\        EXTERN, "SystemByteArray.__Get__SystemInt32__SystemByte"
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    );
    defer t.deinit();
    try t.vm.runEvent("_start");
    try testing.expectEqual(@as(i32, 0x22334400), t.vm.heap[8].int32);
    try testing.expectEqual(@as(u8, 0x44), t.vm.heap[9].byte);
    try testing.expectError(error.ExternException, t.vm.runEvent("oob"));
}

test "unknown externs go to the host callback" {
    var t = try TestVm.init(
        \\.data_start
        \\    x: %SystemSingle, null
        \\.data_end
        \\.code_start
        \\    _start:
        \\        PUSH, x
        \\        EXTERN, "UnityEngineTime.__get_deltaTime__SystemSingle"
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    );
    defer t.deinit();
    try testing.expectError(error.UnknownExtern, t.vm.runEvent("_start"));
    t.vm.host = struct {
        fn f(_: ?*anyopaque, vm: *Vm, name: []const u8, args: []const u32) Error!bool {
            if (!std.mem.eql(u8, name, "UnityEngineTime.__get_deltaTime__SystemSingle")) return false;
            vm.set(args[0], .single, 0.25);
            return true;
        }
    }.f;
    try t.vm.runEvent("_start");
    try testing.expectEqual(@as(f32, 0.25), t.vm.heap[0].single);
}
