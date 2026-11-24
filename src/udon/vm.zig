//! Udon VM emulator.
//!
//! Executes a parsed `Program` with the semantics of VRChat's `UdonVM`
//! (`docs/udon_vm.md` records the reference behaviour this mirrors): an
//! integer stack of heap indices, a typed heap, and `EXTERN` as the only way
//! to compute anything. It exists so translated programs can be run, checked
//! against expected behaviour, and *measured* without Unity.
//!
//! Externs are implemented in `externs.zig`. Anything on a Unity/VRChat type
//! that has no dedicated implementation falls back to a generic object model
//! (property bag + call log), which is enough for examples to drive a mock
//! scene and for tests to assert on what the program did to it.

const std = @import("std");
const program = @import("program.zig");
const value = @import("value.zig");
const nodes = @import("nodes.zig");
const externs = @import("externs.zig");

pub const Program = program.Program;
pub const Value = value.Value;
pub const Array = value.Array;
pub const Object = value.Object;
pub const Vec = value.Vec;
pub const VecKind = value.VecKind;
pub const ElemKind = value.ElemKind;

pub const Error = error{
    /// The program did something the real VM would halt on. `Vm.fault`
    /// describes what and where.
    UdonFault,
    /// `Options.max_steps` instructions executed without the event returning.
    StepLimit,
} || std.mem.Allocator.Error;

pub const LogLevel = enum { info, warning, err };
pub const LogEntry = struct { level: LogLevel, text: []const u8 };

/// A call that reached the generic object model.
pub const Call = struct { sig: []const u8, args: []const Value };

pub const Fault = struct { pc: u32, message: []const u8 };

pub const Stats = struct {
    /// Instructions executed.
    instrs: u64 = 0,
    /// `EXTERN` instructions executed (also counted in `instrs`).
    externs: u64 = 0,
    /// Executed count per opcode number (`Opcode` value as index).
    ops: [10]u64 = @splat(0),

    pub fn sub(a: Stats, b: Stats) Stats {
        var r: Stats = .{ .instrs = a.instrs - b.instrs, .externs = a.externs - b.externs };
        for (&r.ops, a.ops, b.ops) |*o, x, y| o.* = x - y;
        return r;
    }
};

/// What one step of a scenario cost.
pub const EventStat = struct {
    name: []const u8,
    runs: u32,
    /// False when the program does not export the event.
    found: bool,
    stats: Stats,
};

pub const Options = struct {
    /// Abort an event after this many instructions (the real VM uses a
    /// 10 second wall-clock watchdog instead).
    max_steps: u64 = 2_000_000_000,
    /// Fault when heap indices are left on the stack after a consuming
    /// instruction. The real VM tolerates it; translated code never does it.
    strict_stack: bool = true,
    /// Record calls that reach the generic object model in `Vm.calls`.
    record_calls: bool = true,
};

/// `Vec` restricted to one kind, so extern implementations can state the
/// Unity struct they take in their Zig signature.
pub fn VecOf(comptime k: VecKind) type {
    return struct {
        v: [4]f32,
        pub const kind = k;
    };
}
pub const Vector2 = VecOf(.vector2);
pub const Vector3 = VecOf(.vector3);
pub const Vector4 = VecOf(.vector4);
pub const Quaternion = VecOf(.quaternion);
pub const Color = VecOf(.color);
pub const Color32 = struct { c: [4]u8 };
pub const Char = struct { c: u16 };

/// An extern signature bound to its implementation.
pub const Resolved = struct {
    text: []const u8,
    sig: ?nodes.Signature,
    impl: ?externs.Impl,
    /// Times executed, for profiling.
    count: u64 = 0,
};

const Cell = struct {
    op: Op,
    param: u32 = 0,

    const Op = enum(u8) { nop, push, pop, jump_if_false, jump, extern_, annotation, jump_indirect, copy, invalid };
};

pub const Host = struct {
    time: f64 = 0,
    delta_time: f32 = 1.0 / 60.0,
    frame: i32 = 0,
    behaviour: *Object,
    gameobject: *Object,
    transform: *Object,
    local_player: *Object,
    rng: u64 = 0x2545F4914F6CDD1D,
};

pub const Vm = struct {
    gpa: std.mem.Allocator,
    /// Owns everything the running program allocates (strings, arrays,
    /// objects) plus diagnostics. Freed as a whole in `deinit`.
    arena: std.heap.ArenaAllocator,
    prog: *const Program,
    options: Options,
    heap: []Value,
    cells: []Cell,
    resolved: []Resolved,
    stack: [4096]u32 = undefined,
    sp: u32 = 0,
    stats: Stats = .{},
    logs: std.ArrayList(LogEntry) = .empty,
    calls: std.ArrayList(Call) = .empty,
    fault: ?Fault = null,
    halted: bool = false,
    host: Host,

    pub fn init(gpa: std.mem.Allocator, prog: *const Program, options: Options) Error!*Vm {
        const self = try gpa.create(Vm);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .prog = prog,
            .options = options,
            .heap = &.{},
            .cells = &.{},
            .resolved = &.{},
            .host = undefined,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        const go = try self.newObject("UnityEngineGameObject");
        go.name = "UdonBehaviour";
        const tr = try self.newObject("UnityEngineTransform");
        const beh = try self.newObject("VRCUdonUdonBehaviour");
        const player = try self.newObject("VRCSDKBaseVRCPlayerApi");
        try player.put(a, "displayName", .{ .string = "LocalPlayer" });
        try player.put(a, "playerId", .{ .int32 = 1 });
        try player.put(a, "isLocal", .{ .boolean = true });
        try player.put(a, "isMaster", .{ .boolean = true });
        try go.put(a, "transform", .{ .object = tr });
        try go.put(a, "activeSelf", .{ .boolean = true });
        for ([_]*Object{ tr, beh }) |o| {
            try o.put(a, "gameObject", .{ .object = go });
            try o.put(a, "transform", .{ .object = tr });
        }
        try tr.put(a, "localScale", .{ .vec = .{ .kind = .vector3, .v = .{ 1, 1, 1, 0 } } });
        self.host = .{ .behaviour = beh, .gameobject = go, .transform = tr, .local_player = player };

        self.heap = try a.alloc(Value, prog.vars.len);
        for (self.heap, prog.vars) |*slot, v| slot.* = self.initialValue(v);

        // One `Resolved` per distinct extern signature; EXTERN cells index it.
        var by_heap: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        var resolved: std.ArrayList(Resolved) = .empty;
        self.cells = try a.alloc(Cell, prog.code_size / 4);
        @memset(self.cells, .{ .op = .invalid });
        for (prog.code) |ins| {
            var cell: Cell = .{ .op = switch (ins.op) {
                .nop => .nop,
                .push => .push,
                .pop => .pop,
                .jump_if_false => .jump_if_false,
                .jump => .jump,
                .extern_ => .extern_,
                .annotation => .annotation,
                .jump_indirect => .jump_indirect,
                .copy => .copy,
            } };
            switch (ins.param) {
                .none => {},
                .address => |x| cell.param = x,
                .heap => |h| cell.param = h,
                // Left invalid: executing it faults with the symbol name.
                .unresolved => cell.op = .invalid,
            }
            if (ins.op == .extern_ and ins.param == .heap) {
                const h = ins.param.heap;
                const gop = try by_heap.getOrPut(a, h);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(resolved.items.len);
                    const text: []const u8 = switch (self.heap[h]) {
                        .string => |s| s,
                        else => "",
                    };
                    try resolved.append(a, .{ .text = text, .sig = nodes.parseSignature(text), .impl = externs.lookup(text) });
                }
                cell.param = gop.value_ptr.*;
            }
            self.cells[ins.addr / 4] = cell;
        }
        self.resolved = try resolved.toOwnedSlice(a);
        return self;
    }

    pub fn deinit(self: *Vm) void {
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn initialValue(self: *Vm, v: program.Var) Value {
        const t = v.type_name;
        const eql = std.mem.eql;
        return switch (v.init) {
            .null_ => Value.defaultFor(t),
            .this => if (eql(u8, t, "UnityEngineGameObject"))
                .{ .object = self.host.gameobject }
            else if (eql(u8, t, "UnityEngineTransform"))
                .{ .object = self.host.transform }
            else
                .{ .object = self.host.behaviour },
            .boolean => |b| .{ .boolean = b },
            .string => |s| .{ .string = s },
            .char => |c| .{ .char = @truncate(c) },
            .int => |i| if (eql(u8, t, "SystemUInt32"))
                .{ .uint32 = @truncate(@as(u64, @bitCast(i))) }
            else if (eql(u8, t, "SystemSingle"))
                .{ .single = @floatFromInt(i) }
            else if (eql(u8, t, "SystemDouble"))
                .{ .double = @floatFromInt(i) }
            else
                .{ .int32 = @truncate(i) },
            .uint => |u| if (eql(u8, t, "SystemInt32"))
                .{ .int32 = @bitCast(@as(u32, @truncate(u))) }
            else
                .{ .uint32 = @truncate(u) },
            // Float literals are read at `float` precision even for
            // SystemDouble (`docs/udon_specs.md` §4.7).
            .float => |f| if (eql(u8, t, "SystemDouble"))
                .{ .double = @as(f32, @floatCast(f)) }
            else
                .{ .single = @floatCast(f) },
        };
    }

    // ------------------------------------------------------------------
    //  Host-side API
    // ------------------------------------------------------------------

    /// Run the exported event `label` to completion. Returns false when the
    /// program does not export it (Udon silently ignores such events).
    pub fn runEvent(self: *Vm, label: []const u8) Error!bool {
        const i = self.prog.label_index.get(label) orelse return false;
        const l = self.prog.labels[i];
        if (!l.is_export) return false;
        try self.run(l.addr);
        return true;
    }

    /// Run a scenario: a comma-separated list of events, each optionally
    /// repeated with `*N` — `"_start,_interact*3,_update*60"`. `_update`
    /// advances the clock by one frame per run. One `EventStat` per list
    /// entry is appended to `out` (allocated in the VM arena); on a fault the
    /// entries completed so far remain.
    pub fn runScenario(self: *Vm, spec: []const u8, out: *std.ArrayList(EventStat)) Error!void {
        const a = self.arena.allocator();
        var it = std.mem.tokenizeScalar(u8, spec, ',');
        while (it.next()) |tok| {
            const star = std.mem.indexOfScalar(u8, tok, '*');
            const name = std.mem.trim(u8, if (star) |i| tok[0..i] else tok, " ");
            const runs: u32 = if (star) |i| std.fmt.parseInt(u32, tok[i + 1 ..], 10) catch return self.raise("bad repeat count in scenario step '{s}'", .{tok}) else 1;
            const before = self.stats;
            var found = true;
            const is_update = std.mem.eql(u8, name, "_update");
            for (0..runs) |_| {
                if (is_update) try self.tick() else found = try self.runEvent(name);
                if (!found) break;
            }
            if (is_update) found = self.prog.label_index.contains("_update");
            try out.append(a, .{ .name = name, .runs = runs, .found = found, .stats = self.stats.sub(before) });
        }
    }

    /// Advance one frame: bump the clock and fire `_update`.
    pub fn tick(self: *Vm) Error!void {
        self.host.frame += 1;
        self.host.time += self.host.delta_time;
        _ = try self.runEvent("_update");
    }

    pub fn getVar(self: *const Vm, name: []const u8) ?Value {
        const i = self.prog.varIndex(name) orelse return null;
        return self.heap[i];
    }

    pub fn setVar(self: *Vm, name: []const u8, v: Value) bool {
        const i = self.prog.varIndex(name) orelse return false;
        self.heap[i] = v;
        return true;
    }

    pub fn newObject(self: *Vm, type_name: []const u8) Error!*Object {
        const o = try self.arena.allocator().create(Object);
        o.* = .{ .type_name = type_name };
        return o;
    }

    pub fn newArray(self: *Vm, type_name: []const u8, len: u32) Error!*Array {
        const a = self.arena.allocator();
        const arr = try a.create(Array);
        const kind = Value.elemKindFor(type_name[0 .. type_name.len - "Array".len]);
        arr.* = .{ .type_name = type_name, .kind = kind, .len = len };
        if (kind == .value) {
            arr.values = try a.alloc(Value, len);
            @memset(arr.values, Value.defaultFor(arr.elemTypeName()));
        } else {
            arr.bytes = try a.alloc(u8, @as(usize, len) * kind.size());
            @memset(arr.bytes, 0);
        }
        return arr;
    }

    pub fn fmt(self: *Vm, comptime f: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), f, args);
    }

    /// `v.ToString()`.
    pub fn toText(self: *Vm, v: Value) Error![]const u8 {
        if (v == .string) return v.string;
        var w: std.Io.Writer.Allocating = .init(self.arena.allocator());
        v.format(&w.writer) catch return error.OutOfMemory;
        return w.written();
    }

    pub fn log(self: *Vm, level: LogLevel, text: []const u8) Error!void {
        try self.logs.append(self.arena.allocator(), .{ .level = level, .text = text });
    }

    /// All log lines joined with '\n' (allocated in the VM arena).
    pub fn logText(self: *Vm) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const a = self.arena.allocator();
        for (self.logs.items) |e| {
            try out.appendSlice(a, e.text);
            try out.append(a, '\n');
        }
        return out.items;
    }

    /// Record a fault and return the error to propagate.
    pub fn raise(self: *Vm, comptime f: []const u8, args: anytype) Error {
        const msg = try self.fmt(f, args);
        if (self.fault == null) self.fault = .{ .pc = 0, .message = msg };
        return error.UdonFault;
    }

    // ------------------------------------------------------------------
    //  Typed heap access (the emulated GetHeapVariable<T> / SetHeapVariable<T>)
    // ------------------------------------------------------------------

    pub fn get(self: *Vm, comptime T: type, idx: u32) Error!T {
        const v = self.heap[idx];
        if (T == Value) return v;
        // A null reference read as a value type yields the type's default,
        // as `UdonHeap.GetHeapVariable<T>` does.
        const is_null = v == .null_;
        switch (T) {
            bool => if (v == .boolean) return v.boolean else if (is_null) return false,
            u8 => if (v == .byte) return v.byte else if (is_null) return 0,
            i8 => if (v == .sbyte) return v.sbyte else if (is_null) return 0,
            i16 => if (v == .int16) return v.int16 else if (is_null) return 0,
            u16 => if (v == .uint16) return v.uint16 else if (is_null) return 0,
            Char => if (v == .char) return .{ .c = v.char } else if (is_null) return .{ .c = 0 },
            i32 => if (v == .int32) return v.int32 else if (is_null) return 0,
            u32 => if (v == .uint32) return v.uint32 else if (is_null) return 0,
            i64 => if (v == .int64) return v.int64 else if (is_null) return 0,
            u64 => if (v == .uint64) return v.uint64 else if (is_null) return 0,
            f32 => if (v == .single) return v.single else if (is_null) return 0,
            f64 => if (v == .double) return v.double else if (is_null) return 0,
            Color32 => if (v == .color32) return .{ .c = v.color32 } else if (is_null) return .{ .c = .{ 0, 0, 0, 0 } },
            ?[]const u8 => if (v == .string) return v.string else if (is_null) return null,
            []const u8 => if (v == .string) return v.string else if (is_null) return self.raise("NullReferenceException: string argument is null", .{}),
            ?*Array => if (v == .array) return v.array else if (is_null) return null,
            *Array => if (v == .array) return v.array else if (is_null) return self.raise("NullReferenceException: array argument is null", .{}),
            ?*Object => if (v == .object) return v.object else if (is_null) return null,
            *Object => if (v == .object) return v.object else if (is_null) return self.raise("NullReferenceException: object argument is null", .{}),
            else => if (@hasDecl(T, "kind")) {
                if (v == .vec and v.vec.kind == T.kind) return .{ .v = v.vec.v };
                if (is_null) return .{ .v = .{ 0, 0, 0, 0 } };
            } else @compileError("unsupported extern parameter type " ++ @typeName(T)),
        }
        return self.raise("Cannot retrieve heap variable of type '{s}' as type '{s}' (slot {s})", .{
            v.typeName(), netName(T), self.slotName(idx),
        });
    }

    pub fn set(self: *Vm, idx: u32, x: anytype) void {
        const T = @TypeOf(x);
        self.heap[idx] = switch (T) {
            Value => x,
            bool => .{ .boolean = x },
            u8 => .{ .byte = x },
            i8 => .{ .sbyte = x },
            i16 => .{ .int16 = x },
            u16 => .{ .uint16 = x },
            Char => .{ .char = x.c },
            i32 => .{ .int32 = x },
            u32 => .{ .uint32 = x },
            i64 => .{ .int64 = x },
            u64 => .{ .uint64 = x },
            f32 => .{ .single = x },
            f64 => .{ .double = x },
            Color32 => .{ .color32 = x.c },
            []const u8 => .{ .string = x },
            ?[]const u8 => if (x) |s| .{ .string = s } else .null_,
            *Array => .{ .array = x },
            *Object => .{ .object = x },
            ?*Object => if (x) |o| .{ .object = o } else .null_,
            else => if (@hasDecl(T, "kind")) .{ .vec = .{ .kind = T.kind, .v = x.v } } else @compileError("unsupported extern result type " ++ @typeName(T)),
        };
    }

    fn netName(comptime T: type) []const u8 {
        return switch (T) {
            bool => "Boolean",
            u8 => "Byte",
            i8 => "SByte",
            i16 => "Int16",
            u16 => "UInt16",
            Char => "Char",
            i32 => "Int32",
            u32 => "UInt32",
            i64 => "Int64",
            u64 => "UInt64",
            f32 => "Single",
            f64 => "Double",
            []const u8, ?[]const u8 => "String",
            *Array, ?*Array => "Array",
            *Object, ?*Object => "Object",
            else => @typeName(T),
        };
    }

    pub fn slotName(self: *const Vm, idx: u32) []const u8 {
        const n = self.prog.vars[idx].name;
        return if (n.len == 0) "<string literal>" else n;
    }

    // ------------------------------------------------------------------
    //  Interpreter
    // ------------------------------------------------------------------

    /// Execute from `entry` until the program jumps to the halt address.
    /// Re-entrant: an extern (e.g. `SendCustomEvent`) may call it while an
    /// outer `run` is in progress, as the real VM allows.
    pub fn run(self: *Vm, entry: u32) Error!void {
        if (self.halted) return self.raise("UdonBehaviour is halted", .{});
        const saved_sp = self.sp;
        var pc = entry;
        self.exec(&pc) catch |e| {
            self.halted = true;
            if (e == error.StepLimit and self.fault == null)
                self.fault = .{ .pc = pc, .message = "step limit exceeded (the real VM halts after 10 s)" };
            if (self.fault) |*f| {
                if (f.pc == 0) f.pc = pc;
            }
            return e;
        };
        self.sp = saved_sp;
    }

    fn exec(self: *Vm, pc_ptr: *u32) Error!void {
        const cells = self.cells;
        const heap = self.heap;
        const strict = self.options.strict_stack;
        const base_sp = self.sp;
        var pc = pc_ptr.*;
        defer pc_ptr.* = pc;
        while (pc != program.halt_address) {
            if (pc & 3 != 0 or (pc >> 2) >= cells.len)
                return self.raise("jump to 0x{X:0>8}, which is not an instruction address", .{pc});
            const c = cells[pc >> 2];
            self.stats.instrs += 1;
            if (self.stats.instrs > self.options.max_steps) return error.StepLimit;
            switch (c.op) {
                .nop => {
                    self.stats.ops[0] += 1;
                    pc += 4;
                },
                .push => {
                    self.stats.ops[1] += 1;
                    if (self.sp == self.stack.len) return self.raise("stack overflow", .{});
                    self.stack[self.sp] = c.param;
                    self.sp += 1;
                    pc += 8;
                },
                .pop => {
                    self.stats.ops[2] += 1;
                    if (self.sp == base_sp) return self.raise("POP on an empty stack", .{});
                    self.sp -= 1;
                    pc += 4;
                },
                .jump_if_false => {
                    self.stats.ops[4] += 1;
                    if (self.sp == base_sp) return self.raise("JUMP_IF_FALSE on an empty stack", .{});
                    self.sp -= 1;
                    const cond = heap[self.stack[self.sp]];
                    if (cond != .boolean) return self.raise("Cannot retrieve heap variable of type '{s}' as type 'Boolean' (JUMP_IF_FALSE on {s})", .{
                        cond.typeName(), self.slotName(self.stack[self.sp]),
                    });
                    if (strict and self.sp != base_sp) return self.raise("stack not empty after JUMP_IF_FALSE", .{});
                    pc = if (cond.boolean) pc + 8 else c.param;
                },
                .jump => {
                    self.stats.ops[5] += 1;
                    pc = c.param;
                },
                .extern_ => {
                    self.stats.ops[6] += 1;
                    self.stats.externs += 1;
                    const r = &self.resolved[c.param];
                    r.count += 1;
                    const depth = self.sp - base_sp;
                    const argc: u32 = if (r.impl) |impl| impl.argc else blk: {
                        // Generic object model: static and instance forms
                        // differ by one leading `this`; take what was pushed.
                        const sig = r.sig orelse return self.raise("EXTERN operand is not an extern signature: \"{s}\"", .{r.text});
                        const n = sig.staticParamCount();
                        if (depth != n and depth != n + 1 and !sig.isGeneric())
                            return self.raise("EXTERN \"{s}\" expects {d} or {d} arguments, {d} pushed", .{ r.text, n, n + 1, depth });
                        break :blk depth;
                    };
                    if (depth < argc) return self.raise("EXTERN \"{s}\" needs {d} arguments, {d} pushed", .{ r.text, argc, depth });
                    if (strict and depth != argc) return self.raise("EXTERN \"{s}\" takes {d} arguments, {d} pushed", .{ r.text, argc, depth });
                    self.sp -= argc;
                    const args = self.stack[self.sp..][0..argc];
                    // The extern may re-enter `run` and clobber the stack
                    // above `sp`; give it a private copy of its arguments.
                    var arg_buf: [24]u32 = undefined;
                    if (argc > arg_buf.len) return self.raise("too many extern arguments", .{});
                    @memcpy(arg_buf[0..argc], args);
                    if (r.impl) |impl| {
                        try impl.func(self, arg_buf[0..argc]);
                    } else {
                        try externs.dynamicCall(self, r, arg_buf[0..argc]);
                    }
                    pc += 8;
                },
                .annotation => {
                    self.stats.ops[7] += 1;
                    pc += 8;
                },
                .jump_indirect => {
                    self.stats.ops[8] += 1;
                    const t = heap[c.param];
                    if (t != .uint32) return self.raise("Cannot retrieve heap variable of type '{s}' as type 'UInt32' (JUMP_INDIRECT on {s})", .{
                        t.typeName(), self.slotName(c.param),
                    });
                    pc = t.uint32;
                },
                .copy => {
                    self.stats.ops[9] += 1;
                    if (self.sp - base_sp < 2) return self.raise("COPY needs two stack entries", .{});
                    self.sp -= 2;
                    heap[self.stack[self.sp + 1]] = heap[self.stack[self.sp]];
                    if (strict and self.sp != base_sp) return self.raise("stack not empty after COPY", .{});
                    pc += 4;
                },
                .invalid => return self.raise("executed a non-instruction (parameter word or unresolved symbol)", .{}),
            }
        }
        if (strict and self.sp != base_sp) return self.raise("stack not empty when the event returned", .{});
    }

    /// Extern signatures by descending execution count.
    pub fn profile(self: *Vm) Error![]const Resolved {
        const out = try self.arena.allocator().dupe(Resolved, self.resolved);
        std.mem.sort(Resolved, out, {}, struct {
            fn lt(_: void, a: Resolved, b: Resolved) bool {
                return a.count > b.count;
            }
        }.lt);
        return out;
    }
};

// ------------------------------- tests -------------------------------

const testing = std.testing;

fn runSource(src: []const u8, event: []const u8) !struct { prog: *Program, vm: *Vm } {
    const prog = try testing.allocator.create(Program);
    errdefer testing.allocator.destroy(prog);
    prog.* = try program.parse(testing.allocator, src, null);
    errdefer prog.deinit();
    const vm = try Vm.init(testing.allocator, prog, .{});
    errdefer vm.deinit();
    _ = try vm.runEvent(event);
    return .{ .prog = prog, .vm = vm };
}

fn finish(r: anytype) void {
    r.vm.deinit();
    r.prog.deinit();
    testing.allocator.destroy(r.prog);
}

test "hello world logs through Debug.Log" {
    const r = try runSource(
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
    , "_start");
    defer finish(r);
    try testing.expectEqual(@as(usize, 1), r.vm.logs.items.len);
    try testing.expectEqualStrings("Hello, world!", r.vm.logs.items[0].text);
    try testing.expectEqual(@as(u64, 3), r.vm.stats.instrs);
    try testing.expectEqual(@as(u64, 1), r.vm.stats.externs);
}

test "arithmetic, COPY direction, and conditional jump" {
    const r = try runSource(
        \\.data_start
        \\    a: %SystemInt32, 40
        \\    b: %SystemInt32, 2
        \\    c: %SystemInt32, 0
        \\    d: %SystemInt32, 0
        \\    t: %SystemBoolean, null
        \\.data_end
        \\.code_start
        \\    .export go
        \\    go:
        \\        PUSH, a
        \\        PUSH, b
        \\        PUSH, c
        \\        EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
        \\        PUSH, c
        \\        PUSH, a
        \\        PUSH, t
        \\        EXTERN, "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean"
        \\        PUSH, t
        \\        JUMP_IF_FALSE, skip
        \\        PUSH, a
        \\        PUSH, d
        \\        COPY
        \\    skip:
        \\        PUSH, c
        \\        PUSH, d
        \\        COPY
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    , "go");
    defer finish(r);
    try testing.expectEqual(Value{ .int32 = 42 }, r.vm.getVar("c").?);
    // 42 < 40 is false, so the first COPY is skipped and d ← c.
    try testing.expectEqual(Value{ .int32 = 42 }, r.vm.getVar("d").?);
}

test "JUMP_INDIRECT implements return" {
    const r = try runSource(
        \\.data_start
        \\    ra: %SystemUInt32, 0
        \\    rac: %SystemUInt32, 28
        \\    x: %SystemInt32, 1
        \\    one: %SystemInt32, 1
        \\.data_end
        \\.code_start
        \\    .export go
        \\    go:
        \\        PUSH, rac
        \\        PUSH, ra
        \\        COPY
        \\        JUMP, 0x00000024
        \\        JUMP, 0xFFFFFFFC
        \\    fn:
        \\        PUSH, x
        \\        PUSH, one
        \\        PUSH, x
        \\        EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
        \\        JUMP_INDIRECT, ra
        \\.code_end
    , "go");
    defer finish(r);
    try testing.expectEqual(Value{ .int32 = 2 }, r.vm.getVar("x").?);
}

test "typed reads are strict: Int32 slot passed as UInt32 faults" {
    const prog = try testing.allocator.create(Program);
    defer testing.allocator.destroy(prog);
    prog.* = try program.parse(testing.allocator,
        \\.data_start
        \\    a: %SystemInt32, 1
        \\    r: %SystemUInt32, 0
        \\.data_end
        \\.code_start
        \\    .export go
        \\    go:
        \\        PUSH, a
        \\        PUSH, a
        \\        PUSH, r
        \\        EXTERN, "SystemUInt32.__op_Addition__SystemUInt32_SystemUInt32__SystemUInt32"
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    , null);
    defer prog.deinit();
    const vm = try Vm.init(testing.allocator, prog, .{});
    defer vm.deinit();
    try testing.expectError(error.UdonFault, vm.runEvent("go"));
    try testing.expect(std.mem.indexOf(u8, vm.fault.?.message, "'SystemInt32' as type 'UInt32'") != null);
    try testing.expect(vm.halted);
}

test "COPY retypes the destination slot" {
    const r = try runSource(
        \\.data_start
        \\    a: %SystemInt64, null
        \\    b: %SystemInt32, 7
        \\.data_end
        \\.code_start
        \\    .export go
        \\    go:
        \\        PUSH, a
        \\        PUSH, b
        \\        COPY
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    , "go");
    defer finish(r);
    try testing.expectEqual(Value{ .int64 = 0 }, r.vm.getVar("b").?);
}

test "unknown Unity members go to the generic object model" {
    const r = try runSource(
        \\.data_start
        \\    self: %UnityEngineTransform, this
        \\    pos: %UnityEngineVector3, null
        \\    x: %SystemSingle, 1.5
        \\    y: %SystemSingle, 2
        \\    out: %UnityEngineVector3, null
        \\.data_end
        \\.code_start
        \\    .export go
        \\    go:
        \\        PUSH, x
        \\        PUSH, y
        \\        PUSH, x
        \\        PUSH, pos
        \\        EXTERN, "UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3"
        \\        PUSH, self
        \\        PUSH, pos
        \\        EXTERN, "UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid"
        \\        PUSH, self
        \\        PUSH, out
        \\        EXTERN, "UnityEngineTransform.__get_position__UnityEngineVector3"
        \\        JUMP, 0xFFFFFFFC
        \\.code_end
    , "go");
    defer finish(r);
    try testing.expectEqual([4]f32{ 1.5, 2, 1.5, 0 }, r.vm.getVar("out").?.vec.v);
    try testing.expectEqual([4]f32{ 1.5, 2, 1.5, 0 }, r.vm.host.transform.get("position").?.vec.v);
}

test "step limit stops runaway loops" {
    const prog = try testing.allocator.create(Program);
    defer testing.allocator.destroy(prog);
    prog.* = try program.parse(testing.allocator, ".data_start\n.data_end\n.code_start\n.export go\ngo:\nJUMP, 0\n.code_end\n", null);
    defer prog.deinit();
    const vm = try Vm.init(testing.allocator, prog, .{ .max_steps = 1000 });
    defer vm.deinit();
    try testing.expectError(error.StepLimit, vm.runEvent("go"));
}
