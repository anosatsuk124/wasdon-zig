const core = @import("core.zig");
const udon = @import("udon");

var pixels: [core.max_side * core.max_side]u8 = undefined;
var columns: [core.max_side]usize = undefined;
var work: core.Work = .{ .kind = .julia, .side = 0 };

extern "env" fn @"grid.data"() udon.ByteArray;
extern "env" fn @"grid.side"() i32;
extern "env" fn @"grid.kind"() i32;
extern "env" fn @"grid.set_finished"(i32) void;

export fn Load() void {
    const side: usize = @intCast(@max(0, @"grid.side"()));
    const kind = @"grid.kind"();
    const data = @"grid.data"();
    work = .{ .kind = .julia, .side = 0 };
    if (side == 0 or side > core.max_side or kind < 0 or kind > 2 or udon.byteLength(data) != side * side) return;
    work = .{ .kind = @enumFromInt(kind), .side = side };
    udon.copyFromArray(data, 0, pixels[0 .. side * side]);
}

export fn Step() void {
    if (!work.done()) work.step(pixels[0 .. work.side * work.side], &columns);
}

export fn Run() void {
    const cells = pixels[0 .. work.side * work.side];
    while (!work.done()) work.step(cells, &columns);
}

export fn Read() void {
    udon.copyToArray(pixels[0 .. work.side * work.side], @"grid.data"(), 0);
    Poll();
}

export fn Poll() void {
    @"grid.set_finished"(@intFromBool(work.done()));
}

comptime {
    udon.exportMeta("{ \"version\":1, \"fields\":{" ++ udon.memory_field ++ "," ++
        \\ "data":{"source":{"kind":"import","name":"grid.data"},"udonName":"data","type":"SystemByteArray","export":true},
        \\ "side":{"source":{"kind":"import","name":"grid.side"},"udonName":"side","type":"int","export":true},
        \\ "kind":{"source":{"kind":"import","name":"grid.kind"},"udonName":"kind","type":"int","export":true},
        \\ "finished":{"source":{"kind":"import","name":"grid.finished","setter":"grid.set_finished"},"udonName":"finished","type":"int","export":true}
        \\}}
    );
}
