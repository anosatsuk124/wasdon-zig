//! Blockfall as a shared VRChat world object: one game that every player
//! in the instance sees and anyone can play.
//!
//! - The game's owner runs it (`_update`); everyone else only draws what
//!   arrives over the network.
//! - The synced state is a single `byte[]` holding the game's memory image
//!   (`core.Game` is plain bytes), copied with one extern each way.
//! - Pressing a button — a UI button calling `SendCustomEvent("MoveLeft")`
//!   on this behaviour, for instance — takes ownership first, so whoever
//!   touches the controls is playing.
//! - The well is drawn one pixel per cell onto a point-filtered texture.
//!
//! The UdonBehaviour's synchronization mode must be Manual.
//!
//! Udon variables (see the metadata at the bottom):
//!   _seed       Inspector: seed of the first game.
//!   _renderer   Inspector: the renderer whose material shows the well.
//!   _scoreText  Inspector: a UI Text for score and level (optional).
//!   _state      synced: the game.

const udon = @import("udon");
const core = @import("core.zig");

/// Copied from `_seed` at startup.
export var seed: i32 = 1;

extern "env" fn @"udon.this_object"() udon.GameObject;
extern "env" fn @"udon.this_behaviour"() udon.Behaviour;
extern "env" fn @"udon.state"() udon.ByteArray;
extern "env" fn @"udon.set_state"(a: udon.ByteArray) void;
extern "env" fn @"udon.renderer"() udon.Renderer;
extern "env" fn @"udon.score_text"() udon.Text;
extern "env" fn @"udon.texture"() udon.Texture2D;
extern "env" fn @"udon.set_texture"(t: udon.Texture2D) void;
extern "env" fn @"udon.pixels"() udon.ByteArray;
extern "env" fn @"udon.set_pixels"(a: udon.ByteArray) void;

var game: core.Game = .{};
var picture: [core.picture_width * core.picture_height]u32 = undefined;

fn isOwner() bool {
    return udon.net.isOwner(@"udon.this_object"());
}

export fn _start() void {
    const texture = udon.newTexture(core.picture_width, core.picture_height);
    @"udon.set_texture"(texture);
    @"udon.set_pixels"(udon.newByteArray(core.picture_bytes));
    const renderer = @"udon.renderer"();
    if (udon.isValid(renderer)) udon.showTexture(renderer, texture);

    if (isOwner()) {
        @"udon.set_state"(udon.newByteArray(@sizeOf(core.Game)));
        game.init(@bitCast(seed));
        publish();
    } else {
        // Whatever has arrived so far; the first deserialization brings
        // the rest.
        show();
    }
}

export fn _update() void {
    if (!isOwner()) return;
    if (game.advance(udon.deltaTime())) publish();
}

export fn MoveLeft() void {
    command(.left);
}
export fn MoveRight() void {
    command(.right);
}
export fn Rotate() void {
    command(.rotate);
}
export fn Drop() void {
    command(.drop);
}
export fn Restart() void {
    command(.restart);
}

fn command(c: core.Command) void {
    if (!isOwner()) {
        udon.net.takeOwnership(@"udon.this_object"());
        // The array that arrived from the previous owner is ours to fill
        // from now on; make sure there is one.
        if (!udon.isValid(@"udon.state"())) @"udon.set_state"(udon.newByteArray(@sizeOf(core.Game)));
    }
    if (game.input(c)) publish();
}

/// Draw the new state here and send it to everyone else.
fn publish() void {
    show();
    udon.net.requestSerialization(@"udon.this_behaviour"());
}

/// VRChat is about to send the synced variables.
export fn _onPreSerialization() void {
    udon.copyToArray(game.bytes(), @"udon.state"(), 0);
}

/// The synced variables have arrived from the owner.
export fn _onDeserialization() void {
    const state = @"udon.state"();
    if (!udon.isValid(state)) return;
    if (udon.byteLength(state) != @sizeOf(core.Game)) return;
    udon.copyFromArray(state, 0, game.bytes());
    show();
}

fn show() void {
    const texture = @"udon.texture"();
    // A deserialization can arrive before Start has made the texture.
    if (!udon.isValid(texture)) return;
    core.draw(&game, &picture);
    const pixels = @"udon.pixels"();
    udon.copyToArray(@as([*]const u8, @ptrCast(&picture))[0..core.picture_bytes], pixels, 0);
    udon.uploadTexture(texture, pixels);

    const text = @"udon.score_text"();
    if (!udon.isValid(text)) return;
    var line: udon.Line = .{};
    _ = line.text("Score ").int(@intCast(game.score)).text("  Level ").int(game.level + 1);
    if (game.chain > 1) _ = line.text("  Chain x").int(game.chain);
    if (game.phase == .over) _ = line.text("  GAME OVER");
    udon.setText(text, line.slice());
}

comptime {
    udon.exportMeta("{ \"version\": 1, \"behaviour\": { \"syncMode\": \"manual\" }, \"fields\": {" ++ udon.memory_field ++ "," ++ udon.point_filter_field ++ "," ++
        \\ "seed":      { "source": {"kind":"symbol","name":"seed"}, "udonName":"_seed", "type":"int", "export": true, "default": 1 },
        \\ "object":    { "source": {"kind":"import","name":"udon.this_object"}, "udonName":"__this_object", "type":"UnityEngineGameObject", "default": "this" },
        \\ "behaviour": { "source": {"kind":"import","name":"udon.this_behaviour"}, "udonName":"__this_behaviour", "type":"VRCUdonUdonBehaviour", "default": "this" },
        \\ "state":     { "source": {"kind":"import","name":"udon.state","setter":"udon.set_state"}, "udonName":"_state", "type":"SystemByteArray", "sync": {"enabled": true, "mode": "none"} },
        \\ "renderer":  { "source": {"kind":"import","name":"udon.renderer"}, "udonName":"_renderer", "type":"UnityEngineRenderer", "export": true },
        \\ "score":     { "source": {"kind":"import","name":"udon.score_text"}, "udonName":"_scoreText", "type":"UnityEngineUIText", "export": true },
        \\ "texture":   { "source": {"kind":"import","name":"udon.texture","setter":"udon.set_texture"}, "udonName":"_texture", "type":"UnityEngineTexture2D" },
        \\ "pixels":    { "source": {"kind":"import","name":"udon.pixels","setter":"udon.set_pixels"}, "udonName":"_pixels", "type":"SystemByteArray" }
        \\}}
    );
}
