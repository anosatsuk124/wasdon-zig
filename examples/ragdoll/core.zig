//! A humanoid character: sixteen point masses held together by rigid
//! sticks, simulated with Verlet integration, and driven by a small brain.
//!
//! While the character is in control it is an *active* ragdoll: every
//! joint is pulled toward an animated target pose (standing, or a walk
//! cycle that follows a wandering root), so it walks under physics and
//! still reacts to forces. A hit switches the pull off — it collapses and
//! tumbles as a plain ragdoll — and once it has come to rest the pull
//! fades back in and it gets up where it lies.
//!
//! Everything is `f32` arithmetic and a square root: no trigonometry, no
//! host calls. The same code runs natively in the tests, where the Udon
//! run is compared with it bit for bit.

pub const Joint = enum(u8) {
    head,
    neck,
    chest,
    pelvis,
    l_shoulder,
    l_elbow,
    l_hand,
    r_shoulder,
    r_elbow,
    r_hand,
    l_hip,
    l_knee,
    l_foot,
    r_hip,
    r_knee,
    r_foot,
};
pub const joint_count = @typeInfo(Joint).@"enum".fields.len;

pub const Vec = [3]f32;

/// Seconds per simulation step.
pub const dt: f32 = 1.0 / 50.0;
const gravity_step: f32 = 9.81 * dt * dt;
pub const joint_radius: f32 = 0.05;
/// Fraction of horizontal speed kept per step while touching the ground.
const ground_grip: f32 = 0.4;
const walk_speed: f32 = 1.3;
/// Walk cycles per second; with `gait` amplitudes of 0.25 m the stance
/// foot moves backwards about as fast as the root moves forwards.
const cadence: f32 = 0.85;
const turn_rate: f32 = 0.08;
const arrive_distance: f32 = 0.2;

/// The standing pose in the character's own frame: x right, y up,
/// z forward, origin on the ground between the feet.
const stand = [joint_count]Vec{
    .{ 0, 1.65, 0 }, // head
    .{ 0, 1.48, 0 }, // neck
    .{ 0, 1.25, 0 }, // chest
    .{ 0, 0.95, 0 }, // pelvis
    .{ -0.20, 1.42, 0 }, // l_shoulder
    .{ -0.25, 1.14, 0 }, // l_elbow
    .{ -0.27, 0.88, 0 }, // l_hand
    .{ 0.20, 1.42, 0 }, // r_shoulder
    .{ 0.25, 1.14, 0 }, // r_elbow
    .{ 0.27, 0.88, 0 }, // r_hand
    .{ -0.10, 0.92, 0 }, // l_hip
    .{ -0.11, 0.50, 0 }, // l_knee
    .{ -0.11, 0.06, 0 }, // l_foot
    .{ 0.10, 0.92, 0 }, // r_hip
    .{ 0.11, 0.50, 0 }, // r_knee
    .{ 0.11, 0.06, 0 }, // r_foot
};

/// How a joint's target moves through the walk cycle: `swing` metres
/// forward at the top of the cycle, `lift` metres up while it travels
/// forward (`side` picks which half of the cycle that is).
const Gait = struct { swing: f32 = 0, lift: f32 = 0, side: f32 = 0 };
const gait = blk: {
    var g = [_]Gait{.{}} ** joint_count;
    g[@intFromEnum(Joint.l_foot)] = .{ .swing = 0.25, .lift = 0.12, .side = 1 };
    g[@intFromEnum(Joint.r_foot)] = .{ .swing = -0.25, .lift = 0.12, .side = -1 };
    g[@intFromEnum(Joint.l_knee)] = .{ .swing = 0.15, .lift = 0.05, .side = 1 };
    g[@intFromEnum(Joint.r_knee)] = .{ .swing = -0.15, .lift = 0.05, .side = -1 };
    g[@intFromEnum(Joint.l_hand)] = .{ .swing = -0.20 };
    g[@intFromEnum(Joint.r_hand)] = .{ .swing = 0.20 };
    g[@intFromEnum(Joint.l_elbow)] = .{ .swing = -0.08 };
    g[@intFromEnum(Joint.r_elbow)] = .{ .swing = 0.08 };
    break :blk g;
};

/// How strongly each joint is pulled to its target: the legs and the spine
/// carry the pose, the arms hang looser.
const stiffness = blk: {
    var k = [_]f32{0.30} ** joint_count;
    for ([_]Joint{ .l_elbow, .l_hand, .r_elbow, .r_hand }) |j| k[@intFromEnum(j)] = 0.12;
    break :blk k;
};

pub const Stick = struct { a: u8, b: u8 };

fn stick(a: Joint, b: Joint) Stick {
    return .{ .a = @intFromEnum(a), .b = @intFromEnum(b) };
}

/// Bones, then the braces that keep the torso from folding.
pub const sticks = [_]Stick{
    stick(.head, .neck),             stick(.neck, .chest),         stick(.chest, .pelvis),
    stick(.neck, .l_shoulder),       stick(.neck, .r_shoulder),    stick(.l_shoulder, .l_elbow),
    stick(.l_elbow, .l_hand),        stick(.r_shoulder, .r_elbow), stick(.r_elbow, .r_hand),
    stick(.pelvis, .l_hip),          stick(.pelvis, .r_hip),       stick(.l_hip, .l_knee),
    stick(.l_knee, .l_foot),         stick(.r_hip, .r_knee),       stick(.r_knee, .r_foot),
    // braces
    stick(.l_shoulder, .r_shoulder), stick(.l_shoulder, .chest),   stick(.r_shoulder, .chest),
    stick(.l_hip, .r_hip),           stick(.l_hip, .chest),        stick(.r_hip, .chest),
    stick(.head, .chest),            stick(.l_shoulder, .r_hip),   stick(.r_shoulder, .l_hip),
};
pub const bone_count = 15;

/// Rest length of each stick, measured on the standing pose.
pub const rest = blk: {
    var r: [sticks.len]f32 = undefined;
    for (sticks, &r) |s, *len| {
        const a = stand[s.a];
        const b = stand[s.b];
        const d = Vec{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        len.* = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    }
    break :blk r;
};

/// Share of a hit each joint receives, by its height.
const hit_weight = blk: {
    var w: [joint_count]f32 = undefined;
    for (stand, &w) |p, *x| x.* = 0.33 + 0.67 * p[1] / stand[0][1];
    break :blk w;
};

/// Directions a hit can come from.
const hit_directions = [8][2]f32{
    .{ 1, 0 },  .{ 0.7071, 0.7071 },   .{ 0, 1 },  .{ -0.7071, 0.7071 },
    .{ -1, 0 }, .{ -0.7071, -0.7071 }, .{ 0, -1 }, .{ 0.7071, -0.7071 },
};

pub const Mode = enum(u8) {
    /// Standing still, waiting.
    idle,
    /// Walking to `goal`.
    walking,
    /// Knocked over; physics only.
    ragdoll,
    /// Getting up: the pose pull fades back in.
    recovering,
};

pub const Body = struct {
    pos: [joint_count]Vec = undefined,
    /// Positions one step ago; the difference is the velocity.
    old: [joint_count]Vec = undefined,
    mode: Mode = .idle,
    /// Steps left to wait (idle) or steps spent (ragdoll).
    timer: u32 = 0,
    /// Consecutive steps the ragdoll has been almost motionless.
    still: u32 = 0,
    hits: u32 = 0,
    steps: u32 = 0,
    rng: u32 = 1,
    /// Stick relaxation passes per step: more is stiffer and costs more.
    iterations: u32 = 3,
    /// Where the character stands (x, z) and the unit vector it faces.
    root: [2]f32 = .{ 0, 0 },
    heading: [2]f32 = .{ 0, 1 },
    goal: [2]f32 = .{ 0, 0 },
    /// Position in the walk cycle, 0..1.
    phase: f32 = 0,
    /// Pose pull, 0 (limp) to 1.
    strength: f32 = 1,
    /// Frame time not yet simulated.
    clock: f32 = 0,

    pub fn init(b: *Body, seed: u32) void {
        b.* = .{ .rng = seed | 1, .timer = 20 };
        for (0..joint_count) |i| {
            b.pos[i] = b.target(i, 0, 0);
            b.old[i] = b.pos[i];
        }
    }

    /// Account for `frame_time` seconds; simulate at most one step so the
    /// cost per frame is bounded. Returns true if a step was made.
    pub fn advance(b: *Body, frame_time: f32) bool {
        b.clock += frame_time;
        if (b.clock < dt) return false;
        b.clock -= dt;
        // Do not let a slow frame rate build up a debt.
        if (b.clock > dt) b.clock = dt;
        b.step();
        return true;
    }

    pub fn step(b: *Body) void {
        b.steps += 1;
        b.think();
        if (b.strength > 0) b.pose();
        b.integrate();
        // The ground pushes back inside the loop, so the sticks get to
        // answer it before the step ends.
        var n = b.iterations;
        while (n != 0) : (n -= 1) {
            b.relax();
            b.collide();
        }
    }

    /// Knock the character over.
    pub fn hit(b: *Body) void {
        const dir = hit_directions[b.random() & 7];
        for (&b.old, 0..) |*o, i| {
            // The blow lands high: the head gets all of it, the feet a
            // third. Adding to the velocity means moving the previous
            // position the other way.
            const weight = hit_weight[i];
            o[0] -= dir[0] * 0.09 * weight;
            o[1] -= 0.03 * weight;
            o[2] -= dir[1] * 0.09 * weight;
        }
        b.mode = .ragdoll;
        b.strength = 0;
        b.timer = 0;
        b.still = 0;
        b.hits += 1;
    }

    // ----- brain -----

    fn think(b: *Body) void {
        switch (b.mode) {
            .idle => {
                if (b.timer != 0) {
                    b.timer -= 1;
                    return;
                }
                b.goal = .{ b.coordinate(), b.coordinate() };
                b.mode = .walking;
            },
            .walking => b.walk(),
            .ragdoll => {
                b.timer += 1;
                var motion: f32 = 0;
                for (&b.pos, &b.old) |*p, *o| {
                    inline for (0..3) |k| {
                        const v = p[k] - o[k];
                        motion += v * v;
                    }
                }
                b.still = if (motion < 0.0004) b.still + 1 else 0;
                if (b.still >= 25 or b.timer >= 250) {
                    // Get up where the pelvis came to rest.
                    const pelvis = &b.pos[@intFromEnum(Joint.pelvis)];
                    b.root = .{ pelvis[0], pelvis[2] };
                    b.mode = .recovering;
                }
            },
            .recovering => {
                b.strength += 1.0 / 75.0;
                if (b.strength >= 1) {
                    b.strength = 1;
                    b.mode = .idle;
                    b.timer = 30;
                }
            },
        }
    }

    fn walk(b: *Body) void {
        const dx = b.goal[0] - b.root[0];
        const dz = b.goal[1] - b.root[1];
        const d2 = dx * dx + dz * dz;
        if (d2 < arrive_distance * arrive_distance) {
            b.mode = .idle;
            b.timer = 40 + (b.random() & 63);
            b.phase = 0;
            return;
        }
        const inv = 1 / @sqrt(d2);
        const wx = dx * inv;
        const wz = dz * inv;

        // Turn toward the goal, then renormalize.
        var hx = b.heading[0] + (wx - b.heading[0]) * turn_rate;
        var hz = b.heading[1] + (wz - b.heading[1]) * turn_rate;
        var len2 = hx * hx + hz * hz;
        if (len2 < 0.0001) {
            // Facing exactly away: start by turning sideways.
            hx = -b.heading[1];
            hz = b.heading[0];
            len2 = 1;
        }
        const norm = 1 / @sqrt(len2);
        hx *= norm;
        hz *= norm;
        b.heading = .{ hx, hz };

        // Move only as far as it is facing the goal, so it turns on the
        // spot first.
        const facing = hx * wx + hz * wz;
        if (facing > 0) {
            const advance_by = walk_speed * dt * facing;
            b.root[0] += hx * advance_by;
            b.root[1] += hz * advance_by;
        }
        b.phase += cadence * dt;
        if (b.phase >= 1) b.phase -= 1;
    }

    fn random(b: *Body) u32 {
        b.rng = b.rng *% 1664525 +% 1013904223;
        return b.rng >> 16;
    }

    /// A coordinate inside the 5 m square the character wanders in.
    fn coordinate(b: *Body) f32 {
        const cm: i32 = @intCast(b.random() % 500);
        return @as(f32, @floatFromInt(cm - 250)) * 0.01;
    }

    // ----- pose -----

    /// World position joint `i` is pulled toward. `s` and `c` are the sine
    /// and cosine of the walk cycle, or zero when standing.
    fn target(b: *const Body, i: usize, s: f32, c: f32) Vec {
        const g = &gait[i];
        const lx = stand[i][0];
        const lz = g.swing * s;
        const up = g.side * c;
        const ly = if (up > 0) stand[i][1] + g.lift * up else stand[i][1];
        const hx = b.heading[0];
        const hz = b.heading[1];
        return .{ b.root[0] + lx * hz + lz * hx, ly, b.root[1] - lx * hx + lz * hz };
    }

    fn pose(b: *Body) void {
        const walking = b.mode == .walking;
        const s = if (walking) wave(b.phase) else 0;
        const c = if (walking) wave(if (b.phase >= 0.75) b.phase - 0.75 else b.phase + 0.25) else 0;
        for (&b.pos, 0..) |*p, i| {
            const t = b.target(i, s, c);
            const k = b.strength * stiffness[i];
            inline for (0..3) |axis| p[axis] += (t[axis] - p[axis]) * k;
        }
    }

    // ----- physics -----

    fn integrate(b: *Body) void {
        // A body in control damps its own wobble; a limp one keeps moving.
        const keep: f32 = if (b.mode == .ragdoll) 0.992 else 0.90;
        for (&b.pos, &b.old) |*p, *o| {
            inline for (0..3) |k| {
                const v = (p[k] - o[k]) * keep;
                o[k] = p[k];
                p[k] += v;
            }
            p[1] -= gravity_step;
        }
    }

    /// One pass moving the two ends of every stick toward its rest length.
    fn relax(b: *Body) void {
        for (sticks, rest) |s, length| {
            const pa = &b.pos[s.a];
            const pb = &b.pos[s.b];
            const dx = pb[0] - pa[0];
            const dy = pb[1] - pa[1];
            const dz = pb[2] - pa[2];
            const d = @sqrt(dx * dx + dy * dy + dz * dz);
            if (d < 0.0001) continue;
            // Half the error to each end.
            const f = (d - length) / d * 0.5;
            pa[0] += dx * f;
            pa[1] += dy * f;
            pa[2] += dz * f;
            pb[0] -= dx * f;
            pb[1] -= dy * f;
            pb[2] -= dz * f;
        }
    }

    fn collide(b: *Body) void {
        for (&b.pos, &b.old) |*p, *o| {
            if (p[1] >= joint_radius) continue;
            p[1] = joint_radius;
            o[0] = p[0] - (p[0] - o[0]) * ground_grip;
            o[2] = p[2] - (p[2] - o[2]) * ground_grip;
        }
    }

    pub fn joint(b: *const Body, j: Joint) Vec {
        return b.pos[@intFromEnum(j)];
    }
};

/// A sine-like wave of period 1 made of two parabolas: 0 at 0, 1 at 0.25,
/// 0 at 0.5, -1 at 0.75. `t` must be in 0..1.
pub fn wave(t: f32) f32 {
    return if (t < 0.5) 16 * t * (0.5 - t) else 16 * (t - 0.5) * (t - 1);
}

/// The skeleton as one polyline, for a line renderer: every bone is
/// covered, some twice.
pub const outline = blk: {
    const path = [_]Joint{
        .l_hand, .l_elbow, .l_shoulder, .neck,   .head,  .neck,   .r_shoulder, .r_elbow,
        .r_hand, .r_elbow, .r_shoulder, .neck,   .chest, .pelvis, .l_hip,      .l_knee,
        .l_foot, .l_knee,  .l_hip,      .pelvis, .r_hip, .r_knee, .r_foot,
    };
    var indices: [path.len]u8 = undefined;
    for (path, &indices) |j, *i| i.* = @intFromEnum(j);
    break :blk indices;
};

// ------------------------------- tests -------------------------------

const std = @import("std");

fn stickLength(b: *const Body, s: Stick) f32 {
    const pa = b.pos[s.a];
    const pb = b.pos[s.b];
    const d = Vec{ pb[0] - pa[0], pb[1] - pa[1], pb[2] - pa[2] };
    return @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
}

fn expectSound(b: *const Body, tolerance: f32) !void {
    for (b.pos) |p| {
        for (p) |x| try std.testing.expect(std.math.isFinite(x));
        try std.testing.expect(p[1] >= joint_radius - 0.0001);
    }
    for (sticks[0..bone_count], rest[0..bone_count]) |s, len| {
        try std.testing.expectApproxEqRel(len, stickLength(b, s), tolerance);
    }
}

test "wave" {
    try std.testing.expectEqual(@as(f32, 0), wave(0));
    try std.testing.expectEqual(@as(f32, 1), wave(0.25));
    try std.testing.expectEqual(@as(f32, 0), wave(0.5));
    try std.testing.expectEqual(@as(f32, -1), wave(0.75));
}

test "it stands, then walks to its goals without falling apart" {
    var b: Body = .{};
    b.init(7);
    var walked: u32 = 0;
    var arrivals: u32 = 0;
    var last = b.mode;
    for (0..1500) |_| {
        b.step();
        try expectSound(&b, 0.08);
        // In control means upright.
        try std.testing.expect(b.joint(.head)[1] > 1.45);
        try std.testing.expect(b.joint(.pelvis)[1] > 0.8);
        if (b.mode == .walking) walked += 1;
        if (last == .walking and b.mode == .idle) arrivals += 1;
        last = b.mode;
    }
    try std.testing.expect(walked > 300);
    try std.testing.expect(arrivals >= 3);
    // The body follows the root.
    try std.testing.expectApproxEqAbs(b.root[0], b.joint(.pelvis)[0], 0.15);
    try std.testing.expectApproxEqAbs(b.root[1], b.joint(.pelvis)[2], 0.15);
}

test "the feet alternate while walking" {
    var b: Body = .{};
    b.init(3);
    while (b.mode != .walking) b.step();
    var left_up: u32 = 0;
    var right_up: u32 = 0;
    var both_up: u32 = 0;
    var n: u32 = 0;
    while (b.mode == .walking and n < 400) : (n += 1) {
        b.step();
        const l = b.joint(.l_foot)[1] > joint_radius + 0.03;
        const r = b.joint(.r_foot)[1] > joint_radius + 0.03;
        if (l) left_up += 1;
        if (r) right_up += 1;
        if (l and r) both_up += 1;
    }
    try std.testing.expect(left_up > 10);
    try std.testing.expect(right_up > 10);
    try std.testing.expect(both_up * 10 < left_up + right_up);
}

test "a hit knocks it down; it comes to rest, gets up and carries on" {
    var b: Body = .{};
    b.init(11);
    for (0..100) |_| b.step();
    b.hit();
    try std.testing.expectEqual(Mode.ragdoll, b.mode);

    var lowest_head: f32 = 10;
    var steps: u32 = 0;
    while (b.mode == .ragdoll) : (steps += 1) {
        b.step();
        // Hitting the ground is the roughest moment for the sticks.
        try expectSound(&b, 0.25);
        lowest_head = @min(lowest_head, b.joint(.head)[1]);
        try std.testing.expect(steps < 300);
    }
    // It really fell.
    try std.testing.expect(lowest_head < 0.5);
    try std.testing.expectEqual(Mode.recovering, b.mode);

    while (b.mode == .recovering) b.step();
    for (0..50) |_| b.step();
    try std.testing.expect(b.joint(.head)[1] > 1.45);
    try expectSound(&b, 0.08);
    try std.testing.expectEqual(@as(u32, 1), b.hits);
}

test "advance runs one step per simulated interval" {
    var b: Body = .{};
    b.init(1);
    var steps: u32 = 0;
    for (0..60) |_| {
        if (b.advance(1.0 / 60.0)) steps += 1;
    }
    try std.testing.expectEqual(@as(u32, 50), b.steps);
    try std.testing.expectEqual(steps, b.steps);
    // A long frame is one step, not a burst.
    try std.testing.expect(b.advance(1.0));
    try std.testing.expect(b.advance(0));
    try std.testing.expect(!b.advance(0));
}
