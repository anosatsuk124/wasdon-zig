//! π to a few hundred digits, computed a little every frame.
//!
//! Udon halts a behaviour whose event runs longer than 10 seconds, so a
//! long computation has to be cut into steps that fit in a frame. The
//! spigot in `core.zig` yields four digits per step; `_update` runs one
//! step, shows the digits so far, and logs the result when done.
//!
//! Udon variables (see the metadata at the bottom):
//!   _digits   Inspector: how many digits to compute.
//!   _display  Inspector: a UI Text to show them in (optional).

const udon = @import("udon");
const core = @import("core.zig");

/// Copied from `_digits` at startup.
export var digits: i32 = 100;

extern "env" fn @"udon.display"() udon.Text;

var state: core.State = .{};
var announced = false;

export fn _start() void {
    state.init(@intCast(digits));
    announced = false;
    udon.log("pi: started");
}

export fn _update() void {
    if (state.done()) {
        if (!announced) {
            announced = true;
            udon.log(state.text());
        }
        return;
    }
    state.step();
    const display = @"udon.display"();
    if (udon.isValid(display)) udon.setText(display, state.text());
}

/// Restart on interaction.
export fn _interact() void {
    _start();
}

comptime {
    udon.exportMeta(
        \\{
        \\  "version": 1,
        \\  "fields": {
        \\    "digits":  { "source": {"kind":"symbol","name":"digits"}, "udonName":"_digits", "type":"int", "export": true, "default": 100 },
        \\    "display": { "source": {"kind":"import","name":"udon.display"}, "udonName":"_display", "type":"UnityEngineUIText", "export": true }
        \\  }
        \\}
    );
}
