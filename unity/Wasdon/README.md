# Wasdon for Unity

Editor support for running wasdon-zig output in a VRChat world, and the
repository's examples as ready-made assets.

Copy this folder (`unity/Wasdon/`) into the `Assets/` folder of a Unity
project that has the VRChat Worlds SDK installed.

## Wasdon Assembly Program Asset

`Create > VRChat > Udon > Wasdon Assembly Program Asset`, or pick "Wasdon
Assembly Program Asset" in an UdonBehaviour's "New Program" list.

It is an Udon Assembly Program Asset with two differences:

- **The heap is sized from the program.** The stock asset always assembles
  into 512 heap slots and fails on anything larger with
  `Address: '512' is larger than the UdonVM's heap size of '512'.`
  (`docs/spec_heap_size.md`).
- **The assembly can live in a text file.** Assign a `.uasm.txt` file to
  *Assembly Source* and the program is reassembled whenever that file
  changes, so the loop is: build → `wasdon_zig translate app.wasm -o
  Assets/.../app.uasm.txt` → switch back to Unity.

The inspector shows the program's public variables, its size and heap, and
buttons to load a file, reassemble, or copy the assembly — not the assembly
itself, which for a translated program is megabytes of text.

## Examples

`Examples/` holds, for each example under the repository's `examples/`:

| File | What it is |
|---|---|
| `<name>.uasm.txt` | the translated Udon Assembly |
| `<name>.asset` | a Wasdon Assembly Program Asset reading that file |

`Tools > Wasdon > Create Example Objects` adds one object per example to the
open scene, wired up and ready to enter Play mode or build:

| Example | In the scene | Interaction |
|---|---|---|
| `pi` | a text panel filling with digits of π, four per frame | interact to restart |
| `mandelbrot` | a quad; the set renders two rows per frame | interact to zoom in |
| `image-codec` | a quad; QOI pictures decode onto it, are re-encoded and compared | interact for the next picture |
| `ragdoll` | sixteen joint spheres and a line renderer: a figure that walks about | interact to knock it over |
| `blockfall` | a quad showing the well, a score line, five UI buttons | the buttons; synced for everyone in the instance |

The other examples have assets too, without scene objects of their own:
`wasm-bench` and `wasi-hello` only log (put them on any UdonBehaviour and
read the console); `bench-zig` runs a workload for each of the custom
events `Fib`, `Mandel`, `Str`, `Tak` and `Ack`; `udon-orbit` needs an object to orbit and
a prefab to clone (see the comments in `examples/udon-orbit/main.zig`).

Notes:

- Each program's Inspector fields (digits, rows per frame, seed, …) are
  described at the top of its `examples/<name>/main.zig`.
- `blockfall` needs its UdonBehaviour's *Synchronization* set to **Manual**;
  the menu command does that.
- The textures are created at run time (RGBA32, no mipmaps, point filtered),
  so no texture assets are involved.

## Regenerating the examples

The files in `Examples/` are generated; do not edit them. From the
repository root:

```sh
zig build unity
```

`zig build test` fails if they no longer match what the translator
produces.
