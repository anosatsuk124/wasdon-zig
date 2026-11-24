//! WASM → Udon Assembly translator.

const std = @import("std");

pub const translate = @import("translate.zig");
pub const lower = @import("lower.zig");
pub const imports = @import("imports.zig");
pub const runtime = @import("runtime.zig");
pub const callgraph = @import("callgraph.zig");

pub const translateModule = translate.translate;
pub const Options = translate.Options;
pub const Diagnostics = translate.Diagnostics;
pub const Error = translate.Error;

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
