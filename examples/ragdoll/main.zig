//! A humanoid that wanders around, gets knocked over when you interact
//! with it, lies there as a ragdoll, and gets up again.
//!
//! The simulation (`core.zig`) runs at a fixed 50 steps per second, at most
//! one step per frame. After each step the sixteen joints are written to
//! marker objects and to a line renderer that draws the skeleton — both in
//! local space, so the whole character can be placed by moving its parent.
//!
//! Udon variables (see the metadata at the bottom):
//!   _iterations  Inspector: constraint passes per step (stiffer, slower).
//!   _seed        Inspector: seed for where it wanders and how it falls.
//!   _joints      Inspector: a transform with 16 children, one per joint.
//!   _line        Inspector: a line renderer (Use World Space off).

const udon = @import("udon");
const core = @import("core.zig");

/// Copied from `_iterations` and `_seed` at startup.
export var iterations: i32 = 3;
export var seed: i32 = 1;

extern "env" fn @"udon.joints"() udon.Transform;
extern "env" fn @"udon.line"() udon.LineRenderer;

var body: core.Body = .{};

export fn _start() void {
    body.init(@bitCast(seed));
    body.iterations = @intCast(@min(@max(iterations, 1), 8));
    const line = @"udon.line"();
    if (udon.isValid(line)) udon.setLineCount(line, core.outline.len);
    draw();
    announce();
}

export fn _update() void {
    const before = body.mode;
    if (!body.advance(udon.deltaTime())) return;
    draw();
    if (body.mode != before) announce();
}

/// Knock it over.
export fn _interact() void {
    body.hit();
    udon.log("ragdoll: hit");
}

fn draw() void {
    const joints = @"udon.joints"();
    if (udon.isValid(joints)) {
        for (&body.pos, 0..) |*p, i| udon.setLocalPosition(udon.child(joints, i), p[0], p[1], p[2]);
    }
    const line = @"udon.line"();
    if (udon.isValid(line)) {
        for (core.outline, 0..) |joint, i| {
            const p = &body.pos[joint];
            udon.setLinePoint(line, i, p[0], p[1], p[2]);
        }
    }
}

fn announce() void {
    udon.log(switch (body.mode) {
        .idle => "ragdoll: idle",
        .walking => "ragdoll: walking",
        .ragdoll => "ragdoll: down",
        .recovering => "ragdoll: getting up",
    });
}

comptime {
    udon.exportMeta(
        \\{
        \\  "version": 1,
        \\  "fields": {
        \\    "iterations": { "source": {"kind":"symbol","name":"iterations"}, "udonName":"_iterations", "type":"int", "export": true, "default": 3 },
        \\    "seed":       { "source": {"kind":"symbol","name":"seed"}, "udonName":"_seed", "type":"int", "export": true, "default": 1 },
        \\    "joints":     { "source": {"kind":"import","name":"udon.joints"}, "udonName":"_joints", "type":"UnityEngineTransform", "export": true },
        \\    "line":       { "source": {"kind":"import","name":"udon.line"}, "udonName":"_line", "type":"UnityEngineLineRenderer", "export": true }
        \\  }
        \\}
    );
}
