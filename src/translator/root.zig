//! WASM → Udon Assembly translator.

const std = @import("std");

pub const callgraph = @import("callgraph.zig");
pub const translate_ = @import("translate.zig");
pub const lower = @import("lower.zig");
pub const inspect = @import("inspect.zig");
pub const liveness = @import("liveness.zig");

pub const translate = translate_.translate;
pub const Options = translate_.Options;
pub const Diagnostics = translate_.Diagnostics;
pub const Stats = translate_.Stats;
pub const Error = translate_.Error;

test {
    std.testing.refAllDecls(@This());
    _ = callgraph;
    _ = translate_;
    _ = lower;
    _ = inspect;
    _ = liveness;
    _ = @import("tests.zig");
}
