//! VRChat Udon sample: orbit own GameObject around its spawn point
//! and clone it on interact.
//!
//! Udon object types cross the WASM boundary as opaque `i32` handles — never
//! do arithmetic on those values, and never store them in memory. All Udon
//! externs and their Unity-shaped wrappers live in `udon_api.zig`; this file
//! holds state, events, and `__udon_meta`.
//!
//! The example shows the three ways state is shared with Udon
//! (`docs/spec_udonmeta_conversion.md`):
//!   * `radius` / `angular_speed` are ordinary Zig variables in linear
//!     memory. Their `kind: "symbol"` fields make them Inspector-tunable:
//!     the Inspector value is copied into memory once, at startup.
//!   * `clone_count` lives in the Udon heap (`_cloneCount`) and is read and
//!     written through a getter/setter import pair, so other behaviours and
//!     the Inspector always see the current value.
//!   * `self` is a `this`-initialized Udon variable read through a getter.

const udon = @import("udon_api.zig");

export var radius: f32 = 1.5;
export var angular_speed: f32 = 2.0;
var phase: f32 = 0.0;

// ---------- Events ----------

export fn on_start() void {
    udon.Debug.log("udon-orbit: _start");
    phase = 0.0;
    udon.setCloneCount(0);
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
    udon.setCloneCount(udon.cloneCount() +% 1);
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
    \\    "self":          { "source": {"kind":"import","module":"env","name":"udon.self"}, "udonName":"__G__self", "type":"transform", "default":"this" },
    \\    "radius":        { "source": {"kind":"symbol","name":"radius"},        "udonName":"_radius",       "type":"float", "export": true, "default": 1.5 },
    \\    "angular_speed": { "source": {"kind":"symbol","name":"angular_speed"}, "udonName":"_angularSpeed", "type":"float", "export": true, "default": 2.0 },
    \\    "clone_count":   { "source": {"kind":"import","module":"env","name":"udon.clone_count","setter":"udon.set_clone_count"}, "udonName":"_cloneCount", "type":"int", "export": true }
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
