//! Thin Zig wrappers around the Udon externs used by udon-orbit.
//!
//! Each extern is declared with its verbatim signature from
//! `docs/udon_nodes.txt` and re-exposed under a small Unity-shaped namespace
//! so call sites read like Unity API code. Instance methods take the
//! receiver as the first WASM argument
//! (`docs/spec_host_import_conversion.md`).

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

// Udon variables bound through `__udon_meta.fields` (`kind: "import"`):
// these imports are not externs. The translator turns each call into a read
// or write of the named Udon variable.
extern "env" fn @"udon.self"() i32;
extern "env" fn @"udon.clone_count"() i32;
extern "env" fn @"udon.set_clone_count"(n: i32) void;

// ---------- Wrappers ----------

pub inline fn self() i32 {
    return @"udon.self"();
}

pub inline fn cloneCount() i32 {
    return @"udon.clone_count"();
}

pub inline fn setCloneCount(n: i32) void {
    @"udon.set_clone_count"(n);
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
