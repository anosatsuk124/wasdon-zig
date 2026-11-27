//! `zig build unity` — regenerate the Unity assets of the examples.
//!
//! For every shipped example this writes, into `unity/Wasdon/Examples/`:
//!
//!   <name>.uasm.txt   the translated Udon Assembly, as a Unity TextAsset
//!   <name>.asset      a Wasdon Assembly Program Asset that reads it
//!   *.meta            with GUIDs derived from the paths, so references
//!                     between the files survive regeneration
//!
//! The integration tests compare the `.uasm.txt` files with a fresh
//! translation, so a translator change that alters an example's output
//! fails until this has been run again.

const std = @import("std");
const wasdon = @import("wasdon_zig");
const fixtures = @import("fixtures");
const linux_boot = @import("linux_boot.zig");

/// GUID of `unity/Wasdon/Editor/WasdonProgramAsset.cs` (from its .meta).
const program_asset_script = "db8885294ebd4dce1bbd53442e33630b";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: unity_assets <unity/Wasdon/Examples directory>\n", .{});
        return 2;
    }
    const dir = args[1];

    var count: usize = 0;
    for (fixtures.examples) |ex| {
        if (!fixtures.hasUnityAsset(ex)) continue;
        var text: std.Io.Writer.Allocating = .init(arena);
        _ = try wasdon.translateBytes(arena, ex.wasm, &text.writer, .{});

        try writeExample(init.io, arena, dir, ex.name, text.written());
        count += 1;
    }
    if (fixtures.find("linux")) |ex| {
        var raw: std.Io.Writer.Allocating = .init(init.gpa);
        defer raw.deinit();
        _ = try wasdon.translateWithMeta(init.gpa, ex.wasm, ex.meta, &raw.writer, .{ .disable = .{ .stack_return = true } });
        var sliced: std.Io.Writer.Allocating = .init(init.gpa);
        defer sliced.deinit();
        try linux_boot.write(init.gpa, raw.written(), &sliced.writer);
        try writeExample(init.io, arena, dir, "linux-boot", sliced.written());
        count += 1;
    }
    std.debug.print("wrote {d} examples to {s}\n", .{ count, dir });
    return 0;
}

fn writeExample(io: std.Io, arena: std.mem.Allocator, dir: []const u8, name: []const u8, assembly: []const u8) !void {
    const uasm = try std.fmt.allocPrint(arena, "Examples/{s}.uasm.txt", .{name});
    const asset = try std.fmt.allocPrint(arena, "Examples/{s}.asset", .{name});
    try write(io, arena, dir, uasm, assembly);
    try write(io, arena, dir, try meta(arena, uasm), try std.fmt.allocPrint(arena, text_meta, .{guid(uasm)}));
    try write(io, arena, dir, asset, try std.fmt.allocPrint(arena, asset_yaml, .{ program_asset_script, name, guid(uasm) }));
    try write(io, arena, dir, try meta(arena, asset), try std.fmt.allocPrint(arena, asset_meta, .{guid(asset)}));
}

fn meta(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.meta", .{path});
}

/// `path` is relative to `unity/Wasdon/`; `dir` is its `Examples` folder.
fn write(io: std.Io, arena: std.mem.Allocator, dir: []const u8, path: []const u8, data: []const u8) !void {
    const full = try std.fs.path.join(arena, &.{ dir, std.fs.path.basename(path) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = data });
}

/// A Unity GUID that depends only on the asset's path inside
/// `unity/Wasdon/`.
fn guid(path: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update("wasdon-zig/unity/Wasdon/");
    md5.update(path);
    md5.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

const text_meta =
    \\fileFormatVersion: 2
    \\guid: {s}
    \\TextScriptImporter:
    \\  externalObjects: {{}}
    \\  userData: 
    \\  assetBundleName: 
    \\  assetBundleVariant: 
    \\
;

const asset_meta =
    \\fileFormatVersion: 2
    \\guid: {s}
    \\NativeFormatImporter:
    \\  externalObjects: {{}}
    \\  mainObjectFileID: 11400000
    \\  userData: 
    \\  assetBundleName: 
    \\  assetBundleVariant: 
    \\
;

/// A `WasdonProgramAsset` whose assembly comes from the text file. The
/// serialized program is left empty: the Udon SDK creates it on import.
const asset_yaml =
    \\%YAML 1.1
    \\%TAG !u! tag:unity3d.com,2011:
    \\--- !u!114 &11400000
    \\MonoBehaviour:
    \\  m_ObjectHideFlags: 0
    \\  m_CorrespondingSourceObject: {{fileID: 0}}
    \\  m_PrefabInstance: {{fileID: 0}}
    \\  m_PrefabAsset: {{fileID: 0}}
    \\  m_GameObject: {{fileID: 0}}
    \\  m_Enabled: 1
    \\  m_EditorHideFlags: 0
    \\  m_Script: {{fileID: 11500000, guid: {s}, type: 3}}
    \\  m_Name: {s}
    \\  m_EditorClassIdentifier: 
    \\  serializedUdonProgramAsset: {{fileID: 0}}
    \\  udonAssembly: 
    \\  assemblyError: 
    \\  assemblySource: {{fileID: 4900000, guid: {s}, type: 3}}
    \\  heapSize: 0
    \\
;
