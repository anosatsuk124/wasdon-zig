//! A WASI program: nothing in it knows about Udon.
//!
//! Built for `wasm32-wasi`, it uses the standard library's standard output
//! and clock, which reach the system through `wasi_snapshot_preview1`
//! imports. The translator supplies those (`docs/spec_wasi_preview_1.md`):
//! lines written to stdout appear in the Unity console, `_start` becomes
//! the behaviour's Start event.

const std = @import("std");

fn fib(n: u32) u32 {
    return if (n < 2) n else fib(n - 1) + fib(n - 2);
}

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;

    try out.print("Hello, Udon!\n", .{});
    try out.print("fib(15) = {d}\n", .{fib(15)});
    try out.flush();
}
