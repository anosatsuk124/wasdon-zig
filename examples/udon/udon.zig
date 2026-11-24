//! Udon bindings shared by the examples.
//!
//! Every Udon extern is imported under its exact signature from
//! `docs/udon_nodes.txt`; the translator calls an import named after an
//! extern as that extern (`docs/spec_host_import_conversion.md`). The
//! wrappers below only give them readable names and types.
//!
//! Udon objects cross into WASM as opaque handles. Each kind gets its own
//! Zig type so they cannot be mixed up — and, being enums with no values,
//! cannot be used as numbers. A handle must never be stored in memory:
//! keep it in a local, or in an Udon variable bound through `__udon_meta`.

/// Declares a distinct handle type.
fn Handle(comptime udon_type: []const u8) type {
    return enum(i32) {
        _,
        pub const type_name = udon_type;
    };
}

pub const Object = Handle("SystemObject");
pub const String = Handle("SystemString");
pub const ByteArray = Handle("SystemByteArray");
pub const GameObject = Handle("UnityEngineGameObject");
pub const Transform = Handle("UnityEngineTransform");
pub const Vector3 = Handle("UnityEngineVector3");
pub const Texture2D = Handle("UnityEngineTexture2D");
pub const TextureFormat = Handle("UnityEngineTextureFormat");
pub const FilterMode = Handle("UnityEngineFilterMode");
pub const Material = Handle("UnityEngineMaterial");
pub const Renderer = Handle("UnityEngineRenderer");
pub const LineRenderer = Handle("UnityEngineLineRenderer");
pub const Text = Handle("UnityEngineUIText");
pub const Player = Handle("VRCSDKBaseVRCPlayerApi");
pub const Behaviour = Handle("VRCUdonCommonInterfacesIUdonEventReceiver");

/// Any handle as a `SystemObject` argument.
pub fn object(handle: anytype) Object {
    return @enumFromInt(@intFromEnum(handle));
}

// ---------------------------------------------------------------------
//  Logging
// ---------------------------------------------------------------------

extern "env" fn @"UnityEngineDebug.__Log__SystemString__SystemVoid"(ptr: [*]const u8, len: usize) void;
extern "env" fn @"UnityEngineDebug.__LogWarning__SystemString__SystemVoid"(ptr: [*]const u8, len: usize) void;

pub fn log(text: []const u8) void {
    @"UnityEngineDebug.__Log__SystemString__SystemVoid"(text.ptr, text.len);
}

pub fn warn(text: []const u8) void {
    @"UnityEngineDebug.__LogWarning__SystemString__SystemVoid"(text.ptr, text.len);
}

/// A one-line message assembled in place:
/// `line.text("score ").int(n).log()`.
pub const Line = struct {
    buf: [120]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *Line, s: []const u8) *Line {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
        return self;
    }

    pub fn int(self: *Line, value: i32) *Line {
        var digits: [11]u8 = undefined;
        var at: usize = digits.len;
        // Work on the magnitude as unsigned so the minimum value is not
        // special.
        var rest: u32 = @abs(value);
        while (true) {
            at -= 1;
            digits[at] = @intCast(rest % 10 + '0');
            rest /= 10;
            if (rest == 0) break;
        }
        if (value < 0) {
            at -= 1;
            digits[at] = '-';
        }
        return self.text(digits[at..]);
    }

    pub fn slice(self: *const Line) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn log(self: *const Line) void {
        udonLog(self.slice());
    }
};

const udonLog = log;

// ---------------------------------------------------------------------
//  Core types
// ---------------------------------------------------------------------

extern "env" fn @"VRCSDKBaseUtilities.__IsValid__SystemObject__SystemBoolean"(o: Object) bool;
extern "env" fn @"SystemByteArray.__ctor__SystemInt32__SystemByteArray"(len: i32) ByteArray;
extern "env" fn @"SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid"(src: ByteArray, src_offset: i32, dst: ByteArray, dst_offset: i32, count: i32) void;
extern "env" fn @"UnityEngineTime.__get_deltaTime__SystemSingle"() f32;
extern "env" fn @"UnityEngineMathf.__Sin__SystemSingle__SystemSingle"(x: f32) f32;
extern "env" fn @"UnityEngineMathf.__Cos__SystemSingle__SystemSingle"(x: f32) f32;
extern "env" fn @"UnityEngineMathf.__Sqrt__SystemSingle__SystemSingle"(x: f32) f32;

/// False for null and for destroyed Unity objects.
pub fn isValid(handle: anytype) bool {
    return @"VRCSDKBaseUtilities.__IsValid__SystemObject__SystemBoolean"(object(handle));
}

pub fn newByteArray(len: usize) ByteArray {
    return @"SystemByteArray.__ctor__SystemInt32__SystemByteArray"(@intCast(len));
}

/// `Buffer.BlockCopy` between two byte arrays.
pub fn blockCopy(src: ByteArray, src_offset: usize, dst: ByteArray, dst_offset: usize, count: usize) void {
    @"SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid"(src, @intCast(src_offset), dst, @intCast(dst_offset), @intCast(count));
}

pub fn deltaTime() f32 {
    return @"UnityEngineTime.__get_deltaTime__SystemSingle"();
}

pub const math = struct {
    pub fn sin(x: f32) f32 {
        return @"UnityEngineMathf.__Sin__SystemSingle__SystemSingle"(x);
    }
    pub fn cos(x: f32) f32 {
        return @"UnityEngineMathf.__Cos__SystemSingle__SystemSingle"(x);
    }
    pub fn sqrt(x: f32) f32 {
        return @"UnityEngineMathf.__Sqrt__SystemSingle__SystemSingle"(x);
    }
};

// ---------------------------------------------------------------------
//  Linear memory as an Udon byte[]
// ---------------------------------------------------------------------

/// The `byte[]` that *is* this module's linear memory. Bind it in
/// `__udon_meta` with `memory_field`.
extern "env" fn @"udon.memory"() ByteArray;

/// `__udon_meta.fields` entry that makes `memory()` work.
pub const memory_field =
    \\"memory": { "source": {"kind":"import","name":"udon.memory"}, "udonName":"__G__memory", "type":"SystemByteArray" }
;

pub fn memory() ByteArray {
    return @"udon.memory"();
}

/// Copy a region of linear memory into an Udon byte array — one extern,
/// whatever the size.
pub fn copyToArray(bytes: []const u8, dst: ByteArray, dst_offset: usize) void {
    blockCopy(memory(), @intFromPtr(bytes.ptr), dst, dst_offset, bytes.len);
}

/// Copy from an Udon byte array into linear memory.
pub fn copyFromArray(src: ByteArray, src_offset: usize, bytes: []u8) void {
    blockCopy(src, src_offset, memory(), @intFromPtr(bytes.ptr), bytes.len);
}

// ---------------------------------------------------------------------
//  Scene
// ---------------------------------------------------------------------

extern "env" fn @"UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3"(x: f32, y: f32, z: f32) Vector3;
extern "env" fn @"UnityEngineTransform.__GetChild__SystemInt32__UnityEngineTransform"(self: Transform, index: i32) Transform;
extern "env" fn @"UnityEngineTransform.__get_childCount__SystemInt32"(self: Transform) i32;
extern "env" fn @"UnityEngineTransform.__set_localPosition__UnityEngineVector3__SystemVoid"(self: Transform, pos: Vector3) void;
extern "env" fn @"UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid"(self: Transform, pos: Vector3) void;
extern "env" fn @"UnityEngineComponent.__get_gameObject__UnityEngineGameObject"(self: Transform) GameObject;
extern "env" fn @"UnityEngineLineRenderer.__SetPosition__SystemInt32_UnityEngineVector3__SystemVoid"(self: LineRenderer, index: i32, pos: Vector3) void;
extern "env" fn @"UnityEngineLineRenderer.__set_positionCount__SystemInt32__SystemVoid"(self: LineRenderer, count: i32) void;
extern "env" fn @"UnityEngineUIText.__set_text__SystemString__SystemVoid"(self: Text, ptr: [*]const u8, len: usize) void;
extern "env" fn @"UnityEngineRenderer.__get_material__UnityEngineMaterial"(self: Renderer) Material;
extern "env" fn @"UnityEngineMaterial.__set_mainTexture__UnityEngineTexture__SystemVoid"(self: Material, texture: Texture2D) void;
extern "env" fn @"UnityEngineTexture2D.__ctor__SystemInt32_SystemInt32__UnityEngineTexture2D"(w: i32, h: i32) Texture2D;
extern "env" fn @"UnityEngineTexture2D.__ctor__SystemInt32_SystemInt32_UnityEngineTextureFormat_SystemBoolean__UnityEngineTexture2D"(w: i32, h: i32, format: TextureFormat, mip_chain: bool) Texture2D;
extern "env" fn @"UnityEngineTexture2D.__get_format__UnityEngineTextureFormat"(self: Texture2D) TextureFormat;
extern "env" fn @"UnityEngineTexture.__set_filterMode__UnityEngineFilterMode__SystemVoid"(self: Texture2D, mode: FilterMode) void;
extern "env" fn @"UnityEngineTexture2D.__LoadRawTextureData__SystemByteArray__SystemVoid"(self: Texture2D, data: ByteArray) void;
extern "env" fn @"UnityEngineTexture2D.__Apply__SystemVoid"(self: Texture2D) void;

/// An Udon variable of type `FilterMode` that is never assigned, so it
/// holds the enum's zero value: `FilterMode.Point`. Bind it in
/// `__udon_meta` with `point_filter_field`.
extern "env" fn @"udon.point_filter"() FilterMode;

pub const point_filter_field =
    \\"point_filter": { "source": {"kind":"import","name":"udon.point_filter"}, "udonName":"__point_filter", "type":"UnityEngineFilterMode" }
;

/// A `width` x `height` RGBA32 texture without mipmaps, point filtered —
/// what `uploadTexture` needs: its raw data is exactly `width * height * 4`
/// bytes.
///
/// Udon Assembly has no enum literals, so the format is borrowed from a
/// texture made by the two-argument constructor (always RGBA32), and the
/// filter mode comes from an unassigned variable (see `point_filter`).
pub fn newTexture(width: usize, height: usize) Texture2D {
    const probe = @"UnityEngineTexture2D.__ctor__SystemInt32_SystemInt32__UnityEngineTexture2D"(1, 1);
    const format = @"UnityEngineTexture2D.__get_format__UnityEngineTextureFormat"(probe);
    const texture = @"UnityEngineTexture2D.__ctor__SystemInt32_SystemInt32_UnityEngineTextureFormat_SystemBoolean__UnityEngineTexture2D"(@intCast(width), @intCast(height), format, false);
    @"UnityEngineTexture.__set_filterMode__UnityEngineFilterMode__SystemVoid"(texture, @"udon.point_filter"());
    return texture;
}

pub fn vec3(x: f32, y: f32, z: f32) Vector3 {
    return @"UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3"(x, y, z);
}

pub fn child(parent: Transform, index: usize) Transform {
    return @"UnityEngineTransform.__GetChild__SystemInt32__UnityEngineTransform"(parent, @intCast(index));
}

pub fn childCount(parent: Transform) usize {
    return @intCast(@"UnityEngineTransform.__get_childCount__SystemInt32"(parent));
}

pub fn setLocalPosition(t: Transform, x: f32, y: f32, z: f32) void {
    @"UnityEngineTransform.__set_localPosition__UnityEngineVector3__SystemVoid"(t, vec3(x, y, z));
}

pub fn gameObjectOf(t: Transform) GameObject {
    return @"UnityEngineComponent.__get_gameObject__UnityEngineGameObject"(t);
}

pub fn setLineCount(line: LineRenderer, count: usize) void {
    @"UnityEngineLineRenderer.__set_positionCount__SystemInt32__SystemVoid"(line, @intCast(count));
}

pub fn setLinePoint(line: LineRenderer, index: usize, x: f32, y: f32, z: f32) void {
    @"UnityEngineLineRenderer.__SetPosition__SystemInt32_UnityEngineVector3__SystemVoid"(line, @intCast(index), vec3(x, y, z));
}

pub fn setText(text: Text, s: []const u8) void {
    @"UnityEngineUIText.__set_text__SystemString__SystemVoid"(text, s.ptr, s.len);
}

/// Show `texture` on `renderer`'s material.
pub fn showTexture(renderer: Renderer, texture: Texture2D) void {
    const material = @"UnityEngineRenderer.__get_material__UnityEngineMaterial"(renderer);
    @"UnityEngineMaterial.__set_mainTexture__UnityEngineTexture__SystemVoid"(material, texture);
}

/// Replace the texture's pixels with `data` (which must hold exactly the
/// texture's raw size) and upload them.
pub fn uploadTexture(texture: Texture2D, data: ByteArray) void {
    @"UnityEngineTexture2D.__LoadRawTextureData__SystemByteArray__SystemVoid"(texture, data);
    @"UnityEngineTexture2D.__Apply__SystemVoid"(texture);
}

// ---------------------------------------------------------------------
//  Networking
// ---------------------------------------------------------------------

extern "env" fn @"VRCSDKBaseNetworking.__get_LocalPlayer__VRCSDKBaseVRCPlayerApi"() Player;
extern "env" fn @"VRCSDKBaseNetworking.__IsOwner__UnityEngineGameObject__SystemBoolean"(go: GameObject) bool;
extern "env" fn @"VRCSDKBaseNetworking.__SetOwner__VRCSDKBaseVRCPlayerApi_UnityEngineGameObject__SystemVoid"(player: Player, go: GameObject) void;
extern "env" fn @"VRCUdonCommonInterfacesIUdonEventReceiver.__RequestSerialization__SystemVoid"(self: Behaviour) void;

pub const net = struct {
    pub fn localPlayer() Player {
        return @"VRCSDKBaseNetworking.__get_LocalPlayer__VRCSDKBaseVRCPlayerApi"();
    }
    pub fn isOwner(go: GameObject) bool {
        return @"VRCSDKBaseNetworking.__IsOwner__UnityEngineGameObject__SystemBoolean"(go);
    }
    pub fn takeOwnership(go: GameObject) void {
        @"VRCSDKBaseNetworking.__SetOwner__VRCSDKBaseVRCPlayerApi_UnityEngineGameObject__SystemVoid"(localPlayer(), go);
    }
    /// Ask VRChat to send this behaviour's synced variables.
    pub fn requestSerialization(self: Behaviour) void {
        @"VRCUdonCommonInterfacesIUdonEventReceiver.__RequestSerialization__SystemVoid"(self);
    }
};

// ---------------------------------------------------------------------
//  __udon_meta
// ---------------------------------------------------------------------

/// Export the two locator functions the translator reads `__udon_meta`
/// through. Use as `comptime { udon.exportMeta(json); }`.
pub fn exportMeta(comptime json: []const u8) void {
    const S = struct {
        fn ptr() callconv(.c) [*]const u8 {
            return json.ptr;
        }
        fn len() callconv(.c) u32 {
            return json.len;
        }
    };
    @export(&S.ptr, .{ .name = "__udon_meta_ptr" });
    @export(&S.len, .{ .name = "__udon_meta_len" });
}
