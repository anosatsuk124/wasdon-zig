//! The Mandelbrot set, computed pixel by pixel in WebAssembly and shown on
//! a texture.
//!
//! `_update` renders a few rows per frame into linear memory and uploads
//! the buffer with three externs — `Buffer.BlockCopy`, `LoadRawTextureData`,
//! `Apply` — however many pixels changed. `_interact` zooms in.
//!
//! Udon variables (see the metadata at the bottom):
//!   _rowsPerFrame  Inspector: rows rendered per frame.
//!   _renderer      Inspector: the renderer whose material shows the image.

const udon = @import("udon");
const core = @import("core.zig");

/// Copied from `_rowsPerFrame` at startup.
export var rows_per_frame: i32 = 2;

extern "env" fn @"udon.renderer"() udon.Renderer;
extern "env" fn @"udon.texture"() udon.Texture2D;
extern "env" fn @"udon.set_texture"(t: udon.Texture2D) void;
extern "env" fn @"udon.pixels"() udon.ByteArray;
extern "env" fn @"udon.set_pixels"(a: udon.ByteArray) void;

var state: core.State = .{};

export fn _start() void {
    state.init();
    const texture = udon.newTexture(core.width, core.height);
    @"udon.set_texture"(texture);
    @"udon.set_pixels"(udon.newByteArray(core.byte_len));
    const renderer = @"udon.renderer"();
    if (udon.isValid(renderer)) udon.showTexture(renderer, texture);
    udon.log("mandelbrot: started");
}

export fn _update() void {
    if (state.done()) return;
    state.render(@intCast(rows_per_frame));

    const pixels = @"udon.pixels"();
    udon.copyToArray(state.bytes(), pixels, 0);
    udon.uploadTexture(@"udon.texture"(), pixels);

    if (state.done()) {
        var line: udon.Line = .{};
        line.text("mandelbrot: view ").int(@intCast(state.view)).text(" done").log();
    }
}

/// Zoom in one step and start the frame again.
export fn _interact() void {
    state.setView(state.view + 1);
}

comptime {
    udon.exportMeta("{ \"version\": 1, \"fields\": {" ++ udon.memory_field ++ "," ++ udon.point_filter_field ++ "," ++
        \\ "rows":     { "source": {"kind":"symbol","name":"rows_per_frame"}, "udonName":"_rowsPerFrame", "type":"int", "export": true, "default": 2 },
        \\ "renderer": { "source": {"kind":"import","name":"udon.renderer"}, "udonName":"_renderer", "type":"UnityEngineRenderer", "export": true },
        \\ "texture":  { "source": {"kind":"import","name":"udon.texture","setter":"udon.set_texture"}, "udonName":"_texture", "type":"UnityEngineTexture2D" },
        \\ "pixels":   { "source": {"kind":"import","name":"udon.pixels","setter":"udon.set_pixels"}, "udonName":"_pixels", "type":"SystemByteArray" }
        \\}}
    );
}
