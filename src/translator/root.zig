//! WASM → Udon Assembly translator.

const std = @import("std");

pub const names = @import("names.zig");
pub const numeric = @import("lower_numeric.zig");
pub const translate = @import("translate.zig");

pub const translateModule = translate.translate;
pub const Options = translate.Options;
pub const Error = translate.Error;

test {
    std.testing.refAllDecls(@This());
    _ = names;
    _ = numeric;
    _ = translate;
}
