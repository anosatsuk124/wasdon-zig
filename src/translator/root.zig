//! WASM → Udon Assembly translator.

const std = @import("std");

pub const names = @import("names.zig");
pub const numeric = @import("lower_numeric.zig");
pub const extern_sig = @import("extern_sig.zig");
pub const lower_import = @import("lower_import.zig");
pub const recursion = @import("recursion.zig");
pub const translate = @import("translate.zig");

pub const translateModule = translate.translate;
pub const Options = translate.Options;
pub const Error = translate.Error;

test {
    std.testing.refAllDecls(@This());
    _ = names;
    _ = numeric;
    _ = extern_sig;
    _ = lower_import;
    _ = recursion;
    _ = translate;
}
