//! Run a compiled starter on two separate VM heaps with a simulated network.
const std = @import("std");
const udon = @import("wasdon_zig").udon;
const Vm = udon.vm.Vm;
const expect = std.testing.expect;

fn start(vm: *Vm, is_owner: bool) !void {
    vm.host.is_owner = is_owner;
    const target = try vm.newObject("UnityEngineGameObject");
    try expect(vm.setVar("target", .{ .object = target }));
    try expect(try vm.runEvent("_start"));
    try expectState(vm, false);
}

fn expectState(vm: *Vm, enabled: bool) !void {
    try expect(vm.getVar("switchOn").?.boolean == enabled);
    const target = vm.getVar("target").?.object;
    try expect(target.get("activeSelf").?.boolean == enabled);
}

fn deliverSwitch(sender: *Vm, receiver: *Vm) !void {
    const index = sender.prog.varIndex("switchOn") orelse return error.MissingSwitch;
    try expect(sender.prog.vars[index].sync != null);
    try expect(sender.host.is_owner and sender.host.serializations > 0);
    try expect(receiver.setVar("switchOn", sender.heap[index]));
    try expect(try receiver.runEvent("_onDeserialization"));
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(1 << 28));
    var prog = try udon.program.parse(a, source, null);
    defer prog.deinit();
    const owner = try Vm.init(a, &prog, .{});
    defer owner.deinit();
    try start(owner, true);
    try expect(try owner.runEvent("_interact"));
    try owner.serialize();
    try expectState(owner, true);

    const joiner = try Vm.init(a, &prog, .{});
    defer joiner.deinit();
    try start(joiner, false);
    try deliverSwitch(owner, joiner);
    try expectState(joiner, true);
    try expect(try joiner.runEvent("_interact"));
    try joiner.serialize();
    try expectState(joiner, false);
    try expect(joiner.host.is_owner);
    owner.host.is_owner = false;
    try deliverSwitch(joiner, owner);
    try expectState(owner, false);
}
