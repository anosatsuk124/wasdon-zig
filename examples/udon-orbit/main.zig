//! VRChat Udon sample: orbit own GameObject around its spawn point
//! and clone it on interact.
//!
//! Target language is Udon Assembly. Every Udon object type flows through
//! the WASM boundary as an opaque `i32` heap-handle — never do arithmetic
//! on those values. See the accompanying plan file for the full design
//! rationale.

// ---------- Externs (signatures verbatim from docs/udon_nodes.txt) ----------

extern "env" fn @"UnityEngineDebug.__Log__SystemString__SystemVoid"(
    ptr: [*]const u8,
    len: usize,
) void;

// Instance methods use Udon's real bare node names. The translator treats
// the leading WASM i32 arg as the implicit `this` when WASM arity is one
// more than the signature's arg-list length. Component is a base class of
// Transform, so we can pass our `self` (a Transform reference, see below)
// directly to `Component.__get_gameObject`.
extern "env" fn @"UnityEngineComponent.__get_gameObject__UnityEngineGameObject"(
    self_arg: i32,
) i32;

extern "env" fn @"UnityEngineTransform.__get_position__UnityEngineVector3"(
    self_arg: i32,
) i32;
extern "env" fn @"UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid"(
    self_arg: i32,
    pos: i32,
) void;

extern "env" fn @"UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3"(
    x: f32,
    y: f32,
    z: f32,
) i32;
extern "env" fn @"UnityEngineVector3.__op_Addition__UnityEngineVector3_UnityEngineVector3__UnityEngineVector3"(
    a: i32,
    b: i32,
) i32;

extern "env" fn @"UnityEngineTime.__get_deltaTime__SystemSingle"() f32;

extern "env" fn @"UnityEngineMathf.__Sin__SystemSingle__SystemSingle"(x: f32) f32;
extern "env" fn @"UnityEngineMathf.__Cos__SystemSingle__SystemSingle"(x: f32) f32;

// "Falsified" Udon type name — docs/udon_specs.md §7.4.
extern "env" fn @"VRCInstantiate.__Instantiate__UnityEngineGameObject__UnityEngineGameObject"(
    go: i32,
) i32;

// ---------- Receiver + state ----------

// `self` is a Udon-only singleton bound through a WASM **function**
// import. Zig (Zig 0.16, MVP target) does not emit `(import "env" "x"
// (global ...))` declarations, but it does emit `(import "env" "x"
// (func ...))` correctly for `extern fn`. The translator's
// `__udon_meta.fields[*]` entry below declares this nullary import to
// be a pure read of the data slot `__G__self: %UnityEngineTransform,
// this` — the call lowers to `PUSH __G__self ; PUSH retslot ; COPY`
// rather than to a real Udon EXTERN. No linear-memory backing, no
// `i32.load` chain through a fake address.
extern "env" fn @"udon.self"() i32;
inline fn self() i32 {
    return @"udon.self"();
}

export var radius: f32 = 1.5;
export var angular_speed: f32 = 2.0;
export var phase: f32 = 0.0;

export var clone_count: i32 = 0;

// ---------- Helpers ----------

fn log(s: []const u8) void {
    @"UnityEngineDebug.__Log__SystemString__SystemVoid"(s.ptr, s.len);
}

inline fn v3(x: f32, y: f32, z: f32) i32 {
    return @"UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3"(x, y, z);
}

// ---------- Events ----------

export fn on_start() void {
    log("udon-orbit: _start");
    phase = 0.0;
    clone_count = 0;
}

export fn on_update() void {
    phase += angular_speed * @"UnityEngineTime.__get_deltaTime__SystemSingle"();

    const t = self();
    const center = @"UnityEngineTransform.__get_position__UnityEngineVector3"(t);
    const dx = radius * @"UnityEngineMathf.__Cos__SystemSingle__SystemSingle"(phase);
    const dz = radius * @"UnityEngineMathf.__Sin__SystemSingle__SystemSingle"(phase);
    const delta = v3(dx, 0.0, dz);
    const new_pos =
        @"UnityEngineVector3.__op_Addition__UnityEngineVector3_UnityEngineVector3__UnityEngineVector3"(center, delta);
    @"UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid"(t, new_pos);
}

export fn on_interact() void {
    const go = @"UnityEngineComponent.__get_gameObject__UnityEngineGameObject"(self());
    _ = @"VRCInstantiate.__Instantiate__UnityEngineGameObject__UnityEngineGameObject"(go);
    clone_count +%= 1;
    log("udon-orbit: cloned");
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
