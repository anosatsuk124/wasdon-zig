//! Thin Zig wrappers around the Udon "bare node" externs used by udon-orbit.
//!
//! Each Udon extern is declared here with its verbatim signature from
//! `docs/udon_nodes.txt` and re-exposed under a small Unity-shaped namespace
//! so call sites read like normal Unity API code instead of one-line
//! `@"UnityEngine..."(...)` walls.
//!
//! Every Udon object type crosses the WASM boundary as an opaque `i32`
//! heap-handle — never do arithmetic on those values. See
//! `docs/spec_host_import_conversion.md` for the calling convention
//! (instance methods take the receiver as the first WASM arg when the WASM
//! arity is one greater than the signature's arg-list length).

// ---------- Raw externs (verbatim from docs/udon_nodes.txt) ----------

extern "env" fn @"UnityEngineDebug.__Log__SystemString__SystemVoid"(
    ptr: [*]const u8,
    len: usize,
) void;

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

// `self` is a Udon-only singleton bound through a WASM **function** import.
// Zig (Zig 0.16, MVP target) does not emit `(import "env" "x" (global ...))`
// declarations, but it does emit `(import "env" "x" (func ...))` correctly
// for `extern fn`. The translator's `__udon_meta.fields[*]` entry declares
// this nullary import to be a pure read of the data slot
// `__G__self: %UnityEngineTransform, this` — the call lowers to
// `PUSH __G__self ; PUSH retslot ; COPY` rather than to a real Udon EXTERN.
// No linear-memory backing, no `i32.load` chain through a fake address.
extern "env" fn @"udon.self"() i32;

// ---------- Wrappers ----------

pub inline fn self() i32 {
    return @"udon.self"();
}

pub const Debug = struct {
    pub inline fn log(s: []const u8) void {
        @"UnityEngineDebug.__Log__SystemString__SystemVoid"(s.ptr, s.len);
    }
};

pub const Component = struct {
    pub inline fn getGameObject(self_arg: i32) i32 {
        return @"UnityEngineComponent.__get_gameObject__UnityEngineGameObject"(self_arg);
    }
};

pub const Transform = struct {
    pub inline fn getPosition(self_arg: i32) i32 {
        return @"UnityEngineTransform.__get_position__UnityEngineVector3"(self_arg);
    }
    pub inline fn setPosition(self_arg: i32, pos: i32) void {
        @"UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid"(self_arg, pos);
    }
};

pub const Vector3 = struct {
    pub inline fn init(x: f32, y: f32, z: f32) i32 {
        return @"UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3"(x, y, z);
    }
    pub inline fn add(a: i32, b: i32) i32 {
        return @"UnityEngineVector3.__op_Addition__UnityEngineVector3_UnityEngineVector3__UnityEngineVector3"(a, b);
    }
};

pub const Time = struct {
    pub inline fn deltaTime() f32 {
        return @"UnityEngineTime.__get_deltaTime__SystemSingle"();
    }
};

pub const Mathf = struct {
    pub inline fn sin(x: f32) f32 {
        return @"UnityEngineMathf.__Sin__SystemSingle__SystemSingle"(x);
    }
    pub inline fn cos(x: f32) f32 {
        return @"UnityEngineMathf.__Cos__SystemSingle__SystemSingle"(x);
    }
};

pub const VRC = struct {
    pub inline fn instantiate(go: i32) i32 {
        return @"VRCInstantiate.__Instantiate__UnityEngineGameObject__UnityEngineGameObject"(go);
    }
};
