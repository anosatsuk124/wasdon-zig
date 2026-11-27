//! Prepare the Linux example for Unity. The translator supplies ordinary
//! Udon Assembly with all return addresses in heap slots. This tool keeps
//! every original bytecode address fixed, moving selected operand groups
//! to trampolines appended after the guest. The WASM function table and
//! return-address constants therefore stay valid.
const std = @import("std");
const udon = @import("wasdon_zig").udon;
const Program = udon.program.Program;
const Instr = udon.program.Instr;
const halt = udon.program.halt_address;
const eql = std.mem.eql;
const checkpoint_bytes = 512;
const checkpoints_per_step = 512;

pub fn write(gpa: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) !void {
    var program = try udon.program.parse(gpa, source, null);
    defer program.deinit();
    const entry = program.labelAddr("_start") orelse return error.MissingLinuxEntry;
    if (program.labels.len != 1) return error.UnexpectedLinuxExports;
    if (program.varIndex("__return_to") != null) return error.LinuxNeedsHeapReturnAddresses;
    const body = std.mem.indexOf(u8, source, ".data_end\n") orelse return error.InvalidLinuxAssembly;
    const data_header = std.mem.indexOfScalarPos(u8, source, ".data_start\n".len, '\n') orelse return error.InvalidLinuxAssembly;

    var boot: Boot = .{
        .gpa = gpa,
        .data = .init(gpa),
        .tail = .{ .pc = program.code_size, .text = .init(gpa) },
    };
    defer boot.data.deinit();
    defer boot.tail.text.deinit();
    defer boot.extra_externs.deinit(gpa);
    const events = try boot.emitEvents(&program, entry);
    const patches = try boot.instrument(&program, events);
    defer gpa.free(patches);

    var heap_size = program.heapSize() + boot.added_vars;
    for (program.vars[program.named_count..]) |v| {
        if (v.init == .string) _ = boot.extra_externs.remove(v.init.string);
    }
    heap_size += boot.extra_externs.count();
    try out.print(".data_start\n    # wasdon-zig heap-size: {d}\n", .{heap_size});
    try out.writeAll(source[data_header + 1 .. body]);
    try out.writeAll(boot.data.written());
    try out.writeAll(".data_end\n\n.code_start\n");

    var i: usize = 0;
    for (patches) |patch| {
        for (program.code[i..patch.first]) |ins| try writeInstruction(out, &program, ins, events.finish);
        try writeJump(out, "JUMP", patch.dest);
        for (0..patch.padding) |_| try out.writeAll("        NOP\n");
        i = patch.end;
    }
    for (program.code[i..]) |ins| try writeInstruction(out, &program, ins, events.finish);
    try out.writeAll(boot.tail.text.written());
    try out.writeAll(".code_end\n");
}

const Patch = struct { first: usize, end: usize, dest: u32, padding: u32 };
const Events = struct { finish: u32, checkpoint: u32 };

const Emitter = struct {
    text: std.Io.Writer.Allocating,
    pc: u32,

    fn instruction(self: *Emitter, comptime fmt: []const u8, args: anytype, size: u32) !void {
        try self.text.writer.print("        " ++ fmt ++ "\n", args);
        self.pc += size;
    }

    fn push(self: *Emitter, name: []const u8) !void {
        try self.instruction("PUSH, {s}", .{name}, 8);
    }

    fn copy(self: *Emitter, src: []const u8, dst: []const u8) !void {
        try self.push(src);
        try self.push(dst);
        try self.instruction("COPY", .{}, 4);
    }

    fn jump(self: *Emitter, address: u32) !void {
        try self.instruction("JUMP, 0x{X:0>8}", .{address}, 8);
    }

    fn jumpIfFalse(self: *Emitter, cond: []const u8, address: u32) !void {
        try self.push(cond);
        try self.instruction("JUMP_IF_FALSE, 0x{X:0>8}", .{address}, 8);
    }

    fn event(self: *Emitter, name: []const u8) !void {
        try self.text.writer.print("    .export {s}\n    {s}:\n", .{ name, name });
    }
};

const Boot = struct {
    gpa: std.mem.Allocator,
    data: std.Io.Writer.Allocating,
    tail: Emitter,
    added_vars: u32 = 0,
    extra_externs: std.StringHashMapUnmanaged(void) = .empty,

    fn declare(self: *Boot, name: []const u8, ty: []const u8, init: []const u8) !void {
        try self.data.writer.print("    {s}: %{s}, {s}\n", .{ name, ty, init });
        self.added_vars += 1;
    }

    fn address(self: *Boot, name: []const u8, pc: u32) !void {
        var literal: [12]u8 = undefined;
        try self.declare(name, "SystemUInt32", try std.fmt.bufPrint(&literal, "{d}", .{pc}));
    }

    fn call(self: *Boot, sig: []const u8, operands: []const []const u8) !void {
        try self.extra_externs.put(self.gpa, sig, {});
        for (operands) |operand| try self.tail.push(operand);
        try self.tail.instruction("EXTERN, \"{s}\"", .{sig}, 8);
    }

    fn emitEvents(self: *Boot, program: *const Program, entry: u32) !Events {
        const tail = &self.tail;
        try self.data.writer.writeAll("    .export bootRunning\n    .export bootConsole\n");
        try self.declare("bootRunning", "SystemBoolean", "null");
        try self.declare("bootConsole", "SystemString", "\"\"");
        try self.declare("__boot_empty", "SystemString", "\"\"");
        try self.declare("__boot_newline", "SystemString", "\"\\n\"");
        try self.declare("__boot_false", "SystemBoolean", "null");
        try self.declare("__boot_no_memory", "SystemByteArray", "null");
        try self.declare("__boot_budget", "SystemInt32", std.fmt.comptimePrint("{d}", .{checkpoints_per_step}));
        try self.declare("__boot_remaining", "SystemInt32", "0");
        try self.declare("__boot_continue", "SystemBoolean", "null");
        try self.declare("__boot_next", "SystemUInt32", "0");
        try self.address("__boot_entry", entry);

        const finish = tail.pc;
        try tail.copy("__boot_false", "bootRunning");
        try tail.jump(halt);

        try tail.event("Boot");
        try tail.copy("__boot_false", "__inited");
        if (program.varIndex("__frame_depth") != null) try tail.copy("__c_i32_0", "__frame_depth");
        try tail.copy("__boot_empty", "bootConsole");
        try tail.copy("__boot_empty", "__wasi_stdout");
        try tail.copy("__boot_empty", "__wasi_stderr");
        try tail.copy("__boot_no_memory", "__G__memory");
        // The grow routine's output is a second reference to the guest's
        // large array. Release it along with the primary reference on reload.
        for (program.code, 0..) |ins, i| {
            if (ins.op != .extern_ or !eql(u8, program.vars[ins.param.heap].init.string, "SystemByteArray.__ctor__SystemInt32__SystemByteArray")) continue;
            if (i == 0 or program.code[i - 1].op != .push) return error.InvalidLinuxAssembly;
            const dst = program.vars[program.code[i - 1].param.heap].name;
            if (std.mem.startsWith(u8, dst, "__rt_")) try tail.copy("__boot_no_memory", dst);
        }
        var literal: [40]u8 = undefined;
        for (program.vars[0..program.named_count], 0..) |v, i| {
            if (!std.mem.startsWith(u8, v.name, "__G__") or eql(u8, v.name, "__G__memory")) continue;
            if (v.init != .int or !eql(u8, v.type_name, "SystemInt32")) return error.UnexpectedLinuxGlobal;
            const initial = try std.fmt.bufPrint(&literal, "__boot_reset_{d}", .{i});
            try self.declare(initial, v.type_name, v.init_text);
            try tail.copy(initial, v.name);
        }
        try self.call("SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean", &.{ "__c_i32_0", "__c_i32_0", "bootRunning" });
        try tail.copy("__boot_entry", "__boot_next");
        try tail.jump(halt);

        try tail.event("BootStep");
        try tail.jumpIfFalse("bootRunning", halt);
        try tail.copy("__boot_budget", "__boot_remaining");
        try tail.instruction("JUMP_INDIRECT, __boot_next", .{}, 8);

        const checkpoint = tail.pc;
        try self.call("SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32", &.{ "__boot_remaining", "__c_i32_1", "__boot_remaining" });
        try self.call("SystemInt32.__op_GreaterThan__SystemInt32_SystemInt32__SystemBoolean", &.{ "__boot_remaining", "__c_i32_0", "__boot_continue" });
        try tail.jumpIfFalse("__boot_continue", halt);
        try tail.instruction("JUMP_INDIRECT, __boot_next", .{}, 8);
        return .{ .finish = finish, .checkpoint = checkpoint };
    }

    fn instrument(self: *Boot, program: *const Program, events: Events) ![]Patch {
        var backward_targets: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer backward_targets.deinit(self.gpa);
        for (program.code) |ins| {
            if ((ins.op == .jump or ins.op == .jump_if_false) and ins.param.address <= ins.addr)
                try backward_targets.put(self.gpa, ins.param.address, {});
        }

        const tail = &self.tail;
        var patches: std.ArrayList(Patch) = .empty;
        errdefer patches.deinit(self.gpa);
        var first: usize = 0;
        var last_checkpoint: u32 = 0;
        while (first < program.code.len) {
            var end = first;
            while (program.code[end].op == .push) : (end += 1) {
                if (end + 1 == program.code.len) return error.InvalidLinuxAssembly;
            }
            const terminator = program.code[end];
            end += 1;
            const addr = program.code[first].addr;
            const next = terminator.addr + terminator.op.size();
            const span = next - addr;
            const checkpoint = span >= 8 and (addr - last_checkpoint >= checkpoint_bytes or backward_targets.contains(addr));
            const capture = terminator.op == .extern_ and isLog(program.vars[terminator.param.heap].init.string);
            if (checkpoint or capture) {
                try patches.append(self.gpa, .{ .first = first, .end = end, .dest = tail.pc, .padding = (span - 8) / 4 });
                if (checkpoint) {
                    var name_buf: [32]u8 = undefined;
                    const name = try std.fmt.bufPrint(&name_buf, "__boot_resume_{d}", .{addr});
                    try tail.copy(name, "__boot_next");
                    try tail.jump(events.checkpoint);
                    try self.address(name, tail.pc);
                    last_checkpoint = addr;
                }
                if (capture) {
                    if (end - first != 2 or program.code[first].op != .push) return error.UnexpectedLinuxLog;
                    const line = program.vars[program.code[first].param.heap].name;
                    try self.call("SystemString.__Concat__SystemString_SystemString_SystemString__SystemString", &.{
                        "bootConsole", line, "__boot_newline", "bootConsole",
                    });
                }
                for (program.code[first..end]) |ins| {
                    try writeInstruction(&tail.text.writer, program, ins, events.finish);
                    tail.pc += ins.op.size();
                }
                if (terminator.op != .jump and terminator.op != .jump_indirect) try tail.jump(next);
            }
            first = end;
        }
        return patches.toOwnedSlice(self.gpa);
    }
};

fn isLog(sig: []const u8) bool {
    return eql(u8, sig, "UnityEngineDebug.__Log__SystemObject__SystemVoid") or
        eql(u8, sig, "UnityEngineDebug.__LogWarning__SystemObject__SystemVoid") or
        eql(u8, sig, "UnityEngineDebug.__LogError__SystemObject__SystemVoid");
}

fn writeJump(out: *std.Io.Writer, op: []const u8, address: u32) !void {
    try out.print("        {s}, 0x{X:0>8}\n", .{ op, address });
}

fn writeInstruction(out: *std.Io.Writer, program: *const Program, ins: Instr, finish: u32) !void {
    const op = ins.op.mnemonic();
    switch (ins.param) {
        .none => try out.print("        {s}\n", .{op}),
        .address => |address| try writeJump(out, op, if (address == halt) finish else address),
        .heap => |slot| {
            const v = program.vars[slot];
            if (ins.op == .extern_) {
                try out.print("        EXTERN, \"{s}\"\n", .{v.init.string});
            } else {
                if (v.name.len == 0) return error.UnexpectedLinuxLiteral;
                try out.print("        {s}, {s}\n", .{ op, v.name });
            }
        },
        .unresolved => return error.InvalidLinuxAssembly,
    }
}
