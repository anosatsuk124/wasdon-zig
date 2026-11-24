//! A humanoid ragdoll with a small behaviour controller.
//!
//! Sixteen point masses joined by distance constraints (Verlet integration,
//! Jakobsen-style relaxation) form a head, torso, arms and legs. A state
//! machine decides what the character does: it stands while its "muscles"
//! (soft springs towards the rest pose) hold, staggers when pushed, falls,
//! lies still, then gets back up. `_update` advances one fixed time step;
//! `_interact` shoves the torso. Positions would normally be written to
//! bone transforms each frame; here a summary is logged.

const udon = @import("udon");

const Vec = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    fn add(a: Vec, b: Vec) Vec {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    fn sub(a: Vec, b: Vec) Vec {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    fn scale(a: Vec, s: f32) Vec {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    fn length(a: Vec) f32 {
        return @sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    }
};

const Joint = enum(u8) { head, neck, chest, pelvis, l_shoulder, l_elbow, l_hand, r_shoulder, r_elbow, r_hand, l_hip, l_knee, l_foot, r_hip, r_knee, r_foot };
const joint_count = @typeInfo(Joint).@"enum".fields.len;

/// Standing pose, metres.
const rest = [joint_count]Vec{
    .{ .y = 1.70 },             .{ .y = 1.50 },             .{ .y = 1.30 },             .{ .y = 0.95 },
    .{ .x = -0.20, .y = 1.45 }, .{ .x = -0.25, .y = 1.15 }, .{ .x = -0.27, .y = 0.88 }, .{ .x = 0.20, .y = 1.45 },
    .{ .x = 0.25, .y = 1.15 },  .{ .x = 0.27, .y = 0.88 },  .{ .x = -0.10, .y = 0.90 }, .{ .x = -0.11, .y = 0.48 },
    .{ .x = -0.12, .y = 0.04 }, .{ .x = 0.10, .y = 0.90 },  .{ .x = 0.11, .y = 0.48 },  .{ .x = 0.12, .y = 0.04 },
};

const Bone = struct { a: Joint, b: Joint };
const bones = [_]Bone{
    .{ .a = .head, .b = .neck },        .{ .a = .neck, .b = .chest },         .{ .a = .chest, .b = .pelvis },
    .{ .a = .neck, .b = .l_shoulder },  .{ .a = .neck, .b = .r_shoulder },    .{ .a = .l_shoulder, .b = .r_shoulder },
    .{ .a = .chest, .b = .l_shoulder }, .{ .a = .chest, .b = .r_shoulder },   .{ .a = .l_shoulder, .b = .l_elbow },
    .{ .a = .l_elbow, .b = .l_hand },   .{ .a = .r_shoulder, .b = .r_elbow }, .{ .a = .r_elbow, .b = .r_hand },
    .{ .a = .pelvis, .b = .l_hip },     .{ .a = .pelvis, .b = .r_hip },       .{ .a = .l_hip, .b = .r_hip },
    .{ .a = .chest, .b = .l_hip },      .{ .a = .chest, .b = .r_hip },        .{ .a = .l_hip, .b = .l_knee },
    .{ .a = .l_knee, .b = .l_foot },    .{ .a = .r_hip, .b = .r_knee },       .{ .a = .r_knee, .b = .r_foot },
    .{ .a = .head, .b = .chest },
};

const State = enum(u8) { standing, staggering, falling, lying, rising };
const state_names = [_][]const u8{ "standing", "staggering", "falling", "lying", "rising" };

const dt: f32 = 1.0 / 50.0;
const gravity: f32 = -9.81;

var pos: [joint_count]Vec = undefined;
var prev: [joint_count]Vec = undefined;
var bone_length: [bones.len]f32 = undefined;
var state: State = .standing;
var state_time: u32 = 0;
var step_count: u32 = 0;

fn setState(next: State) void {
    if (next == state) return;
    state = next;
    state_time = 0;
    var line: udon.Line = .{};
    line.str("t=").int(step_count).str(" -> ").str(state_names[@intFromEnum(next)]).flush();
}

/// How strongly the muscles pull each joint towards the rest pose.
fn muscleTone() f32 {
    return switch (state) {
        .standing => 0.45,
        .staggering => 0.12,
        .falling, .lying => 0.0,
        .rising => 0.02 + 0.006 * @as(f32, @floatFromInt(@min(state_time, 60))),
    };
}

fn integrate() void {
    const tone = muscleTone();
    for (&pos, &prev, rest) |*p, *old, target| {
        // Verlet step with a little damping.
        const velocity = p.sub(old.*).scale(0.985);
        old.* = p.*;
        p.* = p.add(velocity);
        p.y += gravity * dt * dt;
        // Muscles: blend towards the rest pose (kept above the feet's position).
        if (tone > 0) {
            const anchor: Vec = .{ .x = target.x + pos[@intFromEnum(Joint.l_foot)].x * 0.5 + pos[@intFromEnum(Joint.r_foot)].x * 0.5, .y = target.y, .z = target.z + pos[@intFromEnum(Joint.l_foot)].z * 0.5 + pos[@intFromEnum(Joint.r_foot)].z * 0.5 };
            p.* = p.add(anchor.sub(p.*).scale(tone));
        }
    }
}

fn satisfy() void {
    var iteration: u32 = 0;
    while (iteration < 6) : (iteration += 1) {
        for (bones, bone_length) |bone, length| {
            const a = &pos[@intFromEnum(bone.a)];
            const b = &pos[@intFromEnum(bone.b)];
            const delta = b.sub(a.*);
            const d = delta.length();
            if (d < 0.0001) continue;
            const correction = delta.scale(0.5 * (d - length) / d);
            a.* = a.add(correction);
            b.* = b.sub(correction);
        }
        // Ground: no penetration, strong friction.
        for (&pos, &prev) |*p, *old| {
            if (p.y < 0) {
                p.y = 0;
                old.x += (p.x - old.x) * 0.6;
                old.z += (p.z - old.z) * 0.6;
            }
        }
    }
}

fn think() void {
    const head = pos[@intFromEnum(Joint.head)];
    const pelvis = pos[@intFromEnum(Joint.pelvis)];
    const feet_x = (pos[@intFromEnum(Joint.l_foot)].x + pos[@intFromEnum(Joint.r_foot)].x) * 0.5;
    const feet_z = (pos[@intFromEnum(Joint.l_foot)].z + pos[@intFromEnum(Joint.r_foot)].z) * 0.5;
    // Horizontal distance of the head from the support point: the balance error.
    const lean = (Vec{ .x = head.x - feet_x, .z = head.z - feet_z }).length();
    const speed = pelvis.sub(prev[@intFromEnum(Joint.pelvis)]).length() / dt;
    state_time += 1;
    switch (state) {
        .standing => if (lean > 0.15) setState(.staggering),
        .staggering => if (lean > 0.45) setState(.falling) else if (lean < 0.05 and state_time > 20) setState(.standing),
        .falling => if (head.y < 0.45 and speed < 0.3) setState(.lying),
        .lying => if (state_time > 60) setState(.rising),
        .rising => if (head.y > 1.6 and lean < 0.08) setState(.standing),
    }
}

fn report() void {
    const head = pos[@intFromEnum(Joint.head)];
    const hand = pos[@intFromEnum(Joint.r_hand)];
    var line: udon.Line = .{};
    line.str("t=").int(step_count).str(" ").str(state_names[@intFromEnum(state)])
        .str(" head=(").int(milli(head.x)).str(", ").int(milli(head.y)).str(", ").int(milli(head.z))
        .str(") r_hand=(").int(milli(hand.x)).str(", ").int(milli(hand.y)).str(", ").int(milli(hand.z)).str(") mm").flush();
}

fn milli(v: f32) i32 {
    return @intFromFloat(@floor(v * 1000.0 + 0.5));
}

export fn start() void {
    pos = rest;
    prev = rest;
    for (bones, &bone_length) |bone, *length| length.* = rest[@intFromEnum(bone.b)].sub(rest[@intFromEnum(bone.a)]).length();
    state = .standing;
    state_time = 0;
    step_count = 0;
    udon.log("ragdoll: standing");
}

export fn update() void {
    step_count += 1;
    integrate();
    satisfy();
    think();
    if (step_count % 25 == 0) report();
}

/// Shove the upper body: an impulse is a change of the previous position.
export fn push() void {
    for ([_]Joint{ .chest, .neck, .head, .l_shoulder, .r_shoulder }) |j| {
        prev[@intFromEnum(j)].x -= 0.4;
        prev[@intFromEnum(j)].z -= 0.03;
    }
    udon.log("ragdoll: pushed");
}

const meta =
    \\{
    \\  "version": 1,
    \\  "functions": {
    \\    "start":    { "source": {"kind":"export","name":"start"},  "event":"Start" },
    \\    "update":   { "source": {"kind":"export","name":"update"}, "event":"Update" },
    \\    "interact": { "source": {"kind":"export","name":"push"},   "event":"Interact" }
    \\  },
    \\  "options": { "memory": { "maxPages": 4 } }
    \\}
;
export fn __udon_meta_ptr() [*]const u8 {
    return meta.ptr;
}
export fn __udon_meta_len() u32 {
    return meta.len;
}
