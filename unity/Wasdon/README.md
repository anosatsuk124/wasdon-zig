# Wasdon for Unity

Editor support for running wasdon-zig output in a VRChat world, and the
repository's examples as ready-made assets.

Add the community repository below in ALCOM's **Packages → Add Repository**
or VCC's **Settings → Packages → Add Repository**. In the project's package
list, install **Wasdon Worlds SDK** (`io.github.anosatsuk124.wasdon`).

```text
https://github.com/anosatsuk124/wasdon-zig/releases/latest/download/vpm.json
```

When you open the project, Unity installs the bundled `wasdon-worlds` skill at
`.agents/skills/wasdon-worlds/SKILL.md`. Use `$wasdon-worlds` in Codex from
the project. SDK updates refresh the installed copy and preserve local edits.

Open **Tools → Wasdon → Setup**. **Install release CLI** downloads the matching
tag to `Library/Wasdon/SDK`. **Choose CLI** also accepts a local build or a
mise executable. Select a language, name the project and create the world
behaviour. The window reads `wasdon language list --json`. New packs can be
added here using a development directory or distribution ZIP URL.

The project manifest, sources and editable bindings live under `Assets/<name>`.
Saving changes rebuilds the source-backed program asset. Compiler diagnostics
appear on the asset and in the Console. A world build rechecks its program
sources and stops on a compilation or assembly error. Existing assembly text
assets retain their GUIDs and can still be assigned as Assembly Source.

If you previously copied the SDK into `Assets/Wasdon`, move your own program
assets and sources to another folder inside Unity first. Close the Editor,
move the old SDK folder and its `.meta` outside the project, and install the
VPM package before reopening the project. Existing scene references resolve
to the same script and example GUIDs in the package.

### Test the shared switch

The starter cube controls the sphere above it. You can assign your own
GameObject to its public `target` field in the Inspector. Open
VRChat SDK **Build & Test** with two clients in the same instance. Interact as
the first player and check the target on both clients. Interact as the second
player to exercise ownership transfer. Switch it on, restart one client and
join the same instance again. The target should reflect the current owner’s
synced value as soon as deserialization runs. [VRChat Build & Test](https://creators.vrchat.com/worlds/udon/using-build-test/)

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
| Linux Boot | live Linux WASM console output on a panel | Start and Reload are network events. Boot and display run locally. |
| Sort Benchmark | three animated bar charts and timings for Rust, Zig and UdonSharp | Visualize, Benchmark and Reset run locally |
| Grid Benchmarks | live images and elapsed times for Zig, Rust and UdonSharp on each panel | Visualize steps the workers, Benchmark measures full runs, Reset restores the input |

The other examples have assets too, without scene objects of their own:
`wasm-bench` and `wasi-hello` only log (put them on any UdonBehaviour and
read the console); `bench-zig` runs a workload for each of the custom
events `Fib`, `Mandel`, `Str`, `Tak` and `Ack`; `udon-orbit` needs an object to orbit and
a prefab to clone (see the comments in `examples/udon-orbit/main.zig`).

### Linux Boot

Generate the Linux program asset from the kernel image documented in
[`examples/linux/`](../../examples/linux/) before copying the Wasdon folder
into Unity:

```sh
zig build unity -Doptimize=ReleaseFast -Dlinux=/path/to/vmlinux.wasm
```

**Start** boots an idle console and **Reload** restarts it at any point.
The button starts the local request immediately and broadcasts the command
to other clients once the network object is ready. The panel shows when
it is waiting for the local kernel and counts boot steps while the
console initializes. The first kernel line appears late in the boot.
The panel then streams the console up to the first task switch. A late
joiner starts in the ready state until the next command. The kernel
allocates about 512 MiB of guest memory per client.
The generated program is large and is built locally.

### Sort Benchmark

Set **Sample Size** on the scene's `WasdonSortBenchmark` component
(2–65,536, default 511). **Visualize** runs one merge pass per lane at
each **Pass Interval** and plots 48 equally spaced positions from the
actual output. Each lane displays the accumulated time spent in its
`Step` events. It then starts the full benchmark. **Benchmark** starts
the full-sort trials immediately. Each implementation sorts the same
input after a warm-up. The panel checks every byte against a reference,
displays each sample as it completes, and reports the median of nine
runs and the ratio to the fastest median.
Input preparation, array transfers, validation and UI updates are outside
the measured event. The UdonSharp program is built from
[`UdonSharpMergeSort.cs`](Examples/UdonSharp/UdonSharpMergeSort.cs) by the Unity editor.

### Grid benchmarks

`Tools > Wasdon > Create Grid Benchmarks` creates panels at 256, 512 or
1,024 cells per side. The largest setting has 1,048,576 output cells per
worker. Each panel operates independently.

| Panel | What the image shows |
|---|---|
| Julia set | Escape iteration of each pixel for `z² − 0.75 + 0.125i`, up to 64 iterations. Each step completes eight rows. |
| Prime sieve | Odd candidates arranged in an outward square spiral. Gold points survive the factors processed so far. The largest grid tests odd numbers through 2,097,151. |
| Manhattan distance | Distance to the nearest of 24 seeded points, capped at 255. The Zig and Rust workers first resolve the occupied columns. The UdonSharp worker sweeps the raster forward and backward. |

**Visualize** updates point-sampled images from the workers'
current output each frame and then starts the trials. **Benchmark** starts
the trials directly. Every lane receives the same starting bytes before
every run. The controller clocks the full `Run` event through 512 × 512.
At 1,024 × 1,024 all lanes accumulate timed `Step` events across frames
to fit the SDK's per-event time limit. It checks every output byte against
a reference baked by the editor and shows the median of nine
trials after a warm-up. A ratio above 1 means the Wasdon worker finished
faster. Previously saved two-lane panels continue to run their original
workers. Create a new panel from the menu for the three-way comparison.
The [measurement record](../../docs/benchmarks.md#large-grid-benchmarks)
describes the implementations and includes the batch command.

Notes:

- Each program's Inspector fields (digits, rows per frame, seed, …) are
  described at the top of its `examples/<name>/main.zig`.
- `blockfall` needs its UdonBehaviour's *Synchronization* set to **Manual**;
  the menu command does that.
- The textures are created at run time (RGBA32, no mipmaps, point filtered),
  so no texture assets are involved.

## Regenerating the examples

The translated assets were generated with Zig 0.16.0 and Rust 1.94.0. The
UdonSharp sources were checked with Unity 2022.3.22f1 and Worlds SDK 3.10.6.
From the repository root, with Zig 0.16.0 on `PATH`:

```sh
rustup toolchain install 1.94.0
rustup target add --toolchain 1.94.0 wasm32v1-none wasm32-wasip1
RUSTUP_TOOLCHAIN=1.94.0 zig build unity -Drust -Doptimize=ReleaseFast
RUSTUP_TOOLCHAIN=1.94.0 zig build test -Drust -Doptimize=ReleaseFast
```

Add `-Dlinux=/path/to/vmlinux.wasm` to both commands to generate and test
Linux using the image with the SHA-256 listed in
[`examples/linux/`](../../examples/linux/#reproducing-it).
The first Unity import assembles the Linux program. Unity stores the
resulting SDK program and reuses it when the source file is unchanged.
