//! VRChat Udon sample: orbit own GameObject around its spawn point
//! and clone it on interact.
//!
//! Target language is Udon Assembly. Every Udon object type flows through
//! the WASM boundary as an opaque `i32` heap-handle — never do arithmetic
//! on those values. See the accompanying plan file for the full design
//! rationale.
//!
//! All Udon "bare node" externs and their Unity-shaped wrappers live in
//! `udon_api.zig`; this file only contains state, events, and
//! `__udon_meta`.

const udon = @import("udon_api.zig");

// ---------- Receiver + state ----------

export var radius: f32 = 1.5;
export var angular_speed: f32 = 2.0;
export var phase: f32 = 0.0;

export var clone_count: i32 = 0;

// ---------- Events ----------

export fn on_start() void {
    udon.Debug.log("udon-orbit: _start");
    phase = 0.0;
    clone_count = 0;
}

export fn on_update() void {
    phase += angular_speed * udon.Time.deltaTime();

    const t = udon.self();
    const center = udon.Transform.getPosition(t);
    const dx = radius * udon.Mathf.cos(phase);
    const dz = radius * udon.Mathf.sin(phase);
    const delta = udon.Vector3.init(dx, 0.0, dz);
    const new_pos = udon.Vector3.add(center, delta);
    udon.Transform.setPosition(t, new_pos);
}

export fn on_interact() void {
    const go = udon.Component.getGameObject(udon.self());
    _ = udon.VRC.instantiate(go);
    clone_count +%= 1;
    udon.Debug.log("udon-orbit: cloned");
}

// ---------- __udon_meta ----------

const udon_meta_json =
    \\{
    \\  "version": 1,
    \\  "behaviour": { "syncMode": "none" },
    \\  "functions": {
    \\    "start":    { "source": {"kind":"export","name":"on_start"},    "label":"_start",    "export": true, "event":"Start"    },
    \\    "update":   { "source": {"kind":"export","name":"on_update"},   "label":"_update",   "export": true, "event":"Update"   },
    \\    "interact": { "source": {"kind":"export","name":"on_interact"}, "label":"_interact", "export": true, "event":"Interact" }
    \\  },
    \\  "fields": {
    \\    "self":          { "source": {"kind":"import","module":"env","name":"udon.self"}, "udonName":"__G__self",     "type":"transform", "default":"this" },
    \\    "radius":        { "source": {"kind":"global","name":"radius"},        "udonName":"_radius",       "type":"float",  "export": true, "default": 1.5 },
    \\    "angular_speed": { "source": {"kind":"global","name":"angular_speed"}, "udonName":"_angularSpeed", "type":"float",  "export": true, "default": 2.0 },
    \\    "phase":         { "source": {"kind":"global","name":"phase"},         "udonName":"__G__phase",    "type":"float" },
    \\    "clone_count":   { "source": {"kind":"global","name":"clone_count"},   "udonName":"_cloneCount",   "type":"int",    "export": true }
    \\  },
    \\  "options": {
    \\    "strict": false,
    \\    "memory": { "initialPages": 1, "maxPages": 4, "udonName": "_memory" }
    \\  }
    \\}
;

export fn __udon_meta_ptr() [*]const u8 {
    return udon_meta_json.ptr;
}

export fn __udon_meta_len() u32 {
    return @intCast(udon_meta_json.len);
}
