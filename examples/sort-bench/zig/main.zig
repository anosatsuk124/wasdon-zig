//! Bottom-up stable merge sort. The Unity benchmark supplies the input and
//! reads it back outside the timed Sort event. Step advances one merge width.
const udon = @import("udon");

const capacity = 65_536;
var front: [capacity]u8 = undefined;
var back: [capacity]u8 = undefined;
var count: usize = 0;
var width: usize = 1;
var in_front = true;

extern "env" fn @"sort.data"() udon.ByteArray;

export fn Load() void {
    const data = @"sort.data"();
    count = @min(udon.byteLength(data), capacity);
    udon.copyFromArray(data, 0, front[0..count]);
    width = 1;
    in_front = true;
}

export fn Sort() void {
    while (width < count) merge();
}

export fn Step() void {
    if (width < count) merge();
}

export fn Read() void {
    const values = if (in_front) &front else &back;
    udon.copyToArray(values[0..count], @"sort.data"(), 0);
}

fn merge() void {
    const src = if (in_front) &front else &back;
    const dst = if (in_front) &back else &front;
    var start: usize = 0;
    while (start < count) {
        const mid = @min(start + width, count);
        const end = @min(mid + width, count);
        var left = start;
        var right = mid;
        for (start..end) |i| {
            if (left < mid and (right == end or src[left] <= src[right])) {
                dst[i] = src[left];
                left += 1;
            } else {
                dst[i] = src[right];
                right += 1;
            }
        }
        start = end;
    }
    in_front = !in_front;
    width *= 2;
}

comptime {
    udon.exportMeta("{ \"version\": 1, \"fields\": {" ++ udon.memory_field ++ "," ++
        \\ "data": { "source": {"kind":"import","name":"sort.data"}, "udonName":"data", "type":"SystemByteArray", "export":true }
        \\}}
    );
}
