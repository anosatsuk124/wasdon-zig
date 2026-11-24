# Linux, built for WebAssembly

Two projects build the Linux kernel as a WebAssembly module and boot it in
a browser: [joelseverin/linux-wasm](https://github.com/joelseverin/linux-wasm)
and [tombl/linux](https://github.com/tombl/linux). This directory records
what happens when their `vmlinux.wasm` is given to wasdon-zig — which is
the largest and least Udon-shaped input available — and why the answer is
"it cannot run", in detail.

No kernel binary is checked in (30 MB, GPL); the numbers below are
reproducible with either project's build or the `vmlinux.wasm` its demo
page loads:

```sh
wasdon_zig inspect vmlinux.wasm
```

`inspect` reports everything in a module that the translator does not
support, where `translate` stops at the first. It was added for this.

## The census

`joelseverin/linux-wasm` (Linux 6.4.16, clang 18.1.2; target features: atomics,
bulk-memory, mutable-globals, sign-ext):

```
functions            9970 defined, 96 imported
instructions         1080446 (blocks nest up to 226 deep)
calls                38199 direct, 1910 indirect; table of 2879
memory accesses      124617
memory               15 pages initially, at most 65536, shared, imported
data                 712116 bytes in 0 active and 33 passive segments
globals, exports     638, 7038 (345 exported functions could be events)
imports              0 Udon externs, 0 bound by __udon_meta, 96 unknown

Not supported by the translator:
  - shared memory (threads): the Udon VM runs one thread
  - 6523 atomic instructions (threads): notify 8 wait 3 fence 3977 load 1 store 2 rmw 95 cmpxchg 2437
  - 96 imports that are neither Udon externs nor bound by __udon_meta:
      env.wasm_user_mode_tail
      env.wasm_create_and_run_task
      env.wasm_serialize_tasks
      env.wasm_load_executable
      …
```

`tombl/linux` (Linux 6.1.132, clang 19.1.7; 10010 functions, 2216 data
segments) does not get that far: its module also uses exception handling,
reference types, multi-value and SIMD (per its `target_features` section),
which the parser does not read.

## What stands in the way

In order of how fundamental the obstacle is:

1. **Threads.** Both ports run every kernel task (and every CPU) as its own
   Web Worker sharing one memory; a context switch is a hand-over between
   workers, and blocking is `memory.atomic.wait`. The Udon VM has one
   thread and no way to suspend an event in the middle and resume it
   later. Lowering the 6523 atomic instructions as ordinary loads and
   stores would be correct for a single thread, but the three `wait`s are
   where the kernel's scheduler lives, and there is nobody to wake them.

2. **Loading code at run time.** User-space programs are separate
   WebAssembly modules that the host compiles and instantiates when the
   kernel `exec`s them (`wasm_load_executable`; `user.compile` /
   `user.instantiate` in the other port). An Udon program is fixed when it
   is assembled in the Unity editor; there is no interpreter or loader to
   hand a new module to. Even a kernel that booted would have nothing to
   run — not even `init`.

3. **The host.** The 96 imports are the machine the kernel runs on: clock,
   console, task creation, the system-call path into user programs. None is
   an Udon extern. A console could be built from `Debug.Log` and a clock
   from `Time`, but 1 and 2 are among them.

4. **Time.** Udon stops a behaviour whose event runs longer than ten
   seconds, and it executes — generously — a few hundred thousand externs
   per second. Translated code spends 3–4 externs per memory access; the
   kernel executes on the order of 10⁸–10⁹ instructions before its first
   user process. Cut into frames, booting would take days.

5. **Size.** 1.08 million WebAssembly instructions would become several
   million Udon instructions and, at roughly one heap slot per local and
   per distinct constant, a heap in the hundreds of thousands of slots —
   under the VM's limit of 1048576, but far beyond anything the Unity
   editor's assembler and serializer are used with.

What the translator itself lacks for this module — shared memory accepted
as ordinary memory, atomics lowered for one thread, trapping stubs for
unknown imports — is the small part, and could be added; it would produce
a very large program that stops at the first `wait`. (Its 33 passive data
segments are no obstacle: `memory.init` is supported.)

## What does work

The realistic way to run "a computer inside Udon" is the other way round: a
small interpreter or emulator, written in Zig or Rust and translated,
stepping a fixed number of guest instructions per frame — the same shape as
`examples/pi` or `examples/image-codec`, where the work is cut into pieces
that fit a frame. `examples/wasm-bench` shows the translator handling the
whole WebAssembly instruction set, and `examples/blockfall` an event-driven
world object; those are the shapes that fit the VM.
