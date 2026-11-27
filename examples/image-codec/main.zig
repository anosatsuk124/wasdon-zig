//! Decodes QOI images shipped inside the program, shows them on a texture
//! as they appear, then encodes the result again and checks that the bytes
//! match the original file.
//!
//! The codec (`core.zig`) works a fixed number of pixels per `_update`, so
//! a picture takes a second or two to arrive without ever stalling a
//! frame. `_interact` moves to the next picture.
//!
//! Udon variables (see the metadata at the bottom):
//!   _pixelsPerFrame  Inspector: pixels decoded or encoded per frame.
//!   _renderer        Inspector: the renderer whose material shows the image.

const udon = @import("udon");
const core = @import("core.zig");

/// Copied from `_pixelsPerFrame` at startup.
export var pixels_per_frame: i32 = 96;

extern "env" fn @"udon.renderer"() udon.Renderer;
extern "env" fn @"udon.texture"() udon.Texture2D;
extern "env" fn @"udon.set_texture"(t: udon.Texture2D) void;
extern "env" fn @"udon.pixels"() udon.ByteArray;
extern "env" fn @"udon.set_pixels"(a: udon.ByteArray) void;

var session: core.Session = .{};

export fn _start() void {
    const texture = udon.newTexture(core.side, core.side);
    @"udon.set_texture"(texture);
    @"udon.set_pixels"(udon.newByteArray(core.pixel_count * 4));
    const renderer = @"udon.renderer"();
    if (udon.isValid(renderer)) udon.showTexture(renderer, texture);
    session.begin(0);
}

export fn _update() void {
    if (!session.busy()) return;
    const was_decoding = session.phase == .decoding;
    const changed = session.step(@intCast(pixels_per_frame));
    if (was_decoding) {
        const pixels = @"udon.pixels"();
        udon.copyToArray(session.pixelBytes(), pixels, 0);
        udon.uploadTexture(@"udon.texture"(), pixels);
    }
    if (changed) report();
}

/// Show the next picture.
export fn _interact() void {
    session.begin(session.picture + 1);
}

fn report() void {
    const picture = core.pictures[session.picture];
    var line: udon.Line = .{};
    _ = line.text("image-codec: ").text(picture.name);
    switch (session.phase) {
        .encoding => _ = line.text(" decoded, ").int(@intCast(picture.qoi.len)).text(" bytes to ").int(core.pixel_count * 4),
        .verified => _ = line.text(" encoded again, ").int(@intCast(session.encoder.len)).text(" bytes, identical"),
        .mismatch => _ = line.text(" encoded again, but the bytes differ"),
        else => _ = line.text(" could not be decoded"),
    }
    line.log();
}

comptime {
    udon.exportMeta("{ \"version\": 1, \"fields\": {" ++ udon.memory_field ++ "," ++ udon.point_filter_field ++ "," ++
        \\ "budget":   { "source": {"kind":"symbol","name":"pixels_per_frame"}, "udonName":"_pixelsPerFrame", "type":"int", "export": true, "default": 96 },
        \\ "renderer": { "source": {"kind":"import","name":"udon.renderer"}, "udonName":"_renderer", "type":"UnityEngineRenderer", "export": true },
        \\ "texture":  { "source": {"kind":"import","name":"udon.texture","setter":"udon.set_texture"}, "udonName":"_texture", "type":"UnityEngineTexture2D" },
        \\ "pixels":   { "source": {"kind":"import","name":"udon.pixels","setter":"udon.set_pixels"}, "udonName":"_pixels", "type":"SystemByteArray" }
        \\}}
    );
}
