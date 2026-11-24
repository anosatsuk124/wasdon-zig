//! Mandelbrot set rendered by direct computation.
//!
//! `_start` renders the classic view, `_interact` zooms towards a point on
//! the boundary. Each render logs an ASCII picture, fills an RGBA buffer and
//! — when a texture is assigned to the exported `_texture` variable —
//! uploads it with `Texture2D.LoadRawTextureData`.

const udon = @import("udon");

extern "env" fn @"udon.texture"() i32;
extern "env" fn @"SystemObject.__op_Inequality__SystemObject_SystemObject__SystemBoolean"(a: i32, b: i32) bool;
extern "env" fn @"udon.null"() i32;
extern "env" fn @"UnityEngineTexture2D.__LoadRawTextureData__SystemByteArray__SystemVoid"(texture: i32, data: i32) void;
extern "env" fn @"UnityEngineTexture2D.__Apply__SystemVoid"(texture: i32) void;

const size = 32; // texture is size x size, RGBA32
const cols = 48;
const rows = 20;
const max_iter = 48;

var pixels: [size * size * 4]u8 = undefined;
var center_x: f64 = -0.5;
var center_y: f64 = 0.0;
var scale: f64 = 3.0; // width of the view in the complex plane

fn iterations(cx: f64, cy: f64) u32 {
    var x: f64 = 0;
    var y: f64 = 0;
    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        const xx = x * x;
        const yy = y * y;
        if (xx + yy > 4.0) break;
        y = 2.0 * x * y + cy;
        x = xx - yy + cx;
    }
    return i;
}

fn render() void {
    // ASCII view: characters are about twice as tall as wide.
    var row: u32 = 0;
    var inside: u32 = 0;
    while (row < rows) : (row += 1) {
        var line: udon.Line = .{};
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            const cx = center_x + (@as(f64, @floatFromInt(col)) / cols - 0.5) * scale;
            const cy = center_y + (@as(f64, @floatFromInt(row)) / rows - 0.5) * scale * 0.75;
            const n = iterations(cx, cy);
            if (n == max_iter) inside += 1;
            _ = line.char(" .:-=+*#%@"[n * 9 / max_iter]);
        }
        line.flush();
    }

    var p: usize = 0;
    var py: u32 = 0;
    while (py < size) : (py += 1) {
        var px: u32 = 0;
        while (px < size) : (px += 1) {
            const cx = center_x + (@as(f64, @floatFromInt(px)) / size - 0.5) * scale;
            const cy = center_y + (@as(f64, @floatFromInt(py)) / size - 0.5) * scale;
            const n = iterations(cx, cy);
            const shade: u8 = if (n == max_iter) 0 else @intCast(n * 255 / max_iter);
            pixels[p] = shade;
            pixels[p + 1] = @intCast((@as(u32, shade) * 3) & 0xFF);
            pixels[p + 2] = 255 - shade;
            pixels[p + 3] = 255;
            p += 4;
        }
    }
    var line: udon.Line = .{};
    line.str("inside=").int(inside).str(" pixels=").hex(udon.hash(&pixels)).flush();

    const texture = @"udon.texture"();
    if (@"SystemObject.__op_Inequality__SystemObject_SystemObject__SystemBoolean"(texture, @"udon.null"())) {
        @"UnityEngineTexture2D.__LoadRawTextureData__SystemByteArray__SystemVoid"(texture, udon.bytes.new(&pixels));
        @"UnityEngineTexture2D.__Apply__SystemVoid"(texture);
    }
}

export fn on_start() void {
    render();
}

export fn on_interact() void {
    center_x = -0.743643887037151;
    center_y = 0.131825904205330;
    scale *= 0.25;
    render();
}

const meta =
    \\{
    \\  "version": 1,
    \\  "functions": {
    \\    "start":    { "source": {"kind":"export","name":"on_start"},    "event":"Start" },
    \\    "interact": { "source": {"kind":"export","name":"on_interact"}, "event":"Interact" }
    \\  },
    \\  "fields": {
    \\    "texture": { "source": {"kind":"import","module":"env","name":"udon.texture"}, "udonName":"_texture", "udonType":"UnityEngineTexture2D", "export": true },
    \\    "null":    { "source": {"kind":"import","module":"env","name":"udon.null"},    "udonName":"__null",   "type":"object" }
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
