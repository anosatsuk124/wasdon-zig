# Linux, built for WebAssembly, on the Udon VM

[joelseverin/linux-wasm](https://github.com/joelseverin/linux-wasm) builds
the Linux kernel as a WebAssembly module and boots it in a browser. This
directory gives that `vmlinux.wasm` to wasdon-zig. The result is the
largest program the translator has produced — and it runs: in the
repository's Udon VM emulator the kernel boots through all of
`start_kernel`, printing its log through `Debug.Log`, until the scheduler
wants to switch to a second task.

```
Linux version 6.4.16-00012-gf3e782cb608b (joel@joel-linux) (clang version 18.1.2 (https://github.com/llvm/l…
Zone ranges:
  Normal   [mem 0x0000000000010000-0x000000001fefffff]
Movable zone start for each node
Early memory node ranges
  node   0: [mem 0x0000000000010000-0x000000001fefffff]
Initmem setup node 0 [mem 0x0000000000010000-0x000000001fefffff]
smp_init_cpus: Core Count = 64
percpu: max_distance=0x240000 too large for vmalloc space 0x0
percpu: Embedded 9 pages/cpu s12496 r0 d24368 u36864
percpu: wasting 448 pages per chunk
Kernel command line: console=hvc
printk: log_buf_len individual max cpu contribution: 4096 bytes
printk: log_buf_len total cpu_extra contributions: 258048 bytes
printk: log_buf_len min size: 131072 bytes
printk: log_buf_len: 524288 bytes
printk: early log buf free: 129536(98%)
Dentry cache hash table entries: 65536 (order: 6, 262144 bytes, linear)
Inode-cache hash table entries: 32768 (order: 5, 131072 bytes, linear)
Built 1 zonelists, mobility grouping on.  Total pages: 129778
mem auto-init: stack:all(zero), heap alloc:off, heap free:off
Memory: 513404K/523200K available (0K kernel code, 32K rwdata, 200K rodata, 32K init, 7K bss, 9796K reserve…
rcu: Hierarchical RCU implementation.
rcu: 	RCU event tracing is enabled.
rcu: RCU calculated value of scheduler-enlistment delay is 10 jiffies.
NR_IRQS: 32
rcu: srcu_init: Setting srcu_struct sizes based on contention.
clocksource: wasm_cpu_clock: mask: 0xffffffffffffffff max_cycles: 0x1cd42e4dffb, max_idle_ns: 881590591483 ns
Console: colour dummy device 80x25
printk: console [hvc0] enabled
pid_max: default: 32768 minimum: 512
Mount-cache hash table entries: 1024 (order: 0, 4096 bytes, linear)
Mountpoint-cache hash table entries: 1024 (order: 0, 4096 bytes, linear)
env.wasm_create_and_run_task was called: this host does not have it, and the event ends here
```

(`boot.log`, complete. The last line is the translator's: the host
function the kernel called has no counterpart here.)

| | |
|---|---:|
| `vmlinux.wasm` | 29 966 656 bytes, 9 970 functions, 1 080 446 instructions |
| Udon Assembly | 3 089 877 instructions, 587 249 `EXTERN`s, 124 MB of text |
| heap | 127 370 slots |
| checker findings | 0 |
| executed up to the task switch | 249 565 381 instructions, 51 691 377 `EXTERN`s |

The table describes the single-event emulator run. For Unity, generate
the separate `linux-boot` asset with
`zig build unity -Doptimize=ReleaseFast -Dlinux=/path/to/vmlinux.wasm`.
Its example-only assembly pass adds resumable events at points where the
Udon operand stack is empty, and mirrors console lines to a heap variable
read by the scene panel. The guest still takes about half a gigabyte of
linear memory and stops at the same task switch. See the
[Unity example setup](../../unity/Wasdon/README.md#linux-boot).

## Reproducing it

No kernel binary is checked in (30 MB, GPL-2.0). The one used here is the
build the project's demo page loads,
`https://joelseverin.github.io/linux-wasm/vmlinux.wasm` (Linux 6.4.16,
clang 18.1.2). Its SHA-256 digest is below.

```text
3fa6b28252b0d72c826991a8e2e95a9919a9e8ea46d2d38a6d28b91011353d39
```

Download and check that image before building the Unity asset:

```sh
mkdir -p zig-out/wasm
curl -fL https://joelseverin.github.io/linux-wasm/vmlinux.wasm -o zig-out/wasm/vmlinux.wasm
printf '%s  %s\n' 3fa6b28252b0d72c826991a8e2e95a9919a9e8ea46d2d38a6d28b91011353d39 zig-out/wasm/vmlinux.wasm | shasum -a 256 -c -
zig build unity -Doptimize=ReleaseFast -Dlinux=zig-out/wasm/vmlinux.wasm
```

For the emulator and statistics:

```sh
zig build test  -Dlinux=/path/to/vmlinux.wasm   # translate, check, boot, verify the log
zig build stats -Dlinux=/path/to/vmlinux.wasm   # its row in the statistics table
```

By hand (a release build of the CLI boots it in three seconds):

```sh
zig build -Doptimize=ReleaseFast
wasdon_zig inspect   vmlinux.wasm --meta examples/linux/vmlinux.udon_meta.json
wasdon_zig translate vmlinux.wasm --meta examples/linux/vmlinux.udon_meta.json -o vmlinux.uasm
wasdon_zig check     vmlinux.uasm
wasdon_zig run       vmlinux.uasm --events _start --max-steps 1000000000
```

## What it took

The module is nothing like the programs written for Udon: it shares its
memory between threads, uses 6 523 atomic instructions, keeps its data in
33 passive segments that its own start function copies in, and imports 96
functions from a JavaScript host. The translator needed four things, none
of them specific to Linux:

1. **Threads, for one thread** (`src/translator/threads.zig`,
   `docs/spec_linear_memory.md` §12). On one thread an atomic access is an
   ordinary access. Every instruction of the threads proposal is rewritten
   into plain WebAssembly before translation: loads and stores as they
   are, read-modify-write and compare-exchange as load / compute / store,
   `notify` as "nobody woken", `wait` as "not equal" or "timed out" — and a
   trap where it would wait forever.
2. **A host described in metadata** (`vmlinux.udon_meta.json`,
   `docs/spec_host_import_conversion.md` §8). The imports are bound by
   name to the few things a host function usually is:

   | Import | Bound to |
   |---|---|
   | `wasm_driver_hvc_put(buffer, count)` | `write`: console output, to the log a line at a time |
   | `wasm_cpu_clock_get_monotonic()` | `clock`: nanoseconds since start |
   | `wasm_panic(message)` | `panic`: the message to the error log, end of event |
   | `sys_*` (84 system calls the port leaves to the host) | the constant `-38`, `-ENOSYS`, as the JavaScript host answers |
   | every other `wasm_*` (tasks, CPUs, user programs) | `halt`: say which was called, end the event |

3. **A string field backed by memory** (`docs/spec_udonmeta_conversion.md`).
   The host hands the kernel its command line by writing it to the buffer
   the exported global `boot_command_line` points at. Here that is an Udon
   variable, `commandLine`, copied into memory at start-up — after the
   module's start function, which is what fills memory from the passive
   segments. Without `console=hvc` in it the kernel prints nothing.
4. **Events that end inside recursion** (`docs/udon_vm.md`). The halt
   arrives deep in the scheduler, below recursive functions whose return
   addresses are parked on the VM stack.

Three things that were already there mattered: `memory.init` for the
passive segments, `br_table` as an indexed jump for the kernel's many
`switch`es, and an operand stack that copes with blocks nested 226 deep.

## Why it stops there

`wasm_create_and_run_task` is the kernel's context switch to a task that
has never run: the idle task, at the end of `rest_init`, hands over to
`kernel_init`. In the browser the host starts a Web Worker for the new
task — another instance of the module on the same memory — and blocks the
calling worker until something switches back to it.

An Udon behaviour is one instance with one flow of control, and the
translated program keeps every function's locals in fixed heap slots. A
second task running `schedule()` would overwrite the first one's. So the
boot ends where the kernel stops being one sequential program.

What going further would take, in increasing order of doubt:

- **One behaviour per task**, all sharing one `byte[]` as memory — the
  same shape as the browser's one worker per task. Udon variables can hold
  a reference to the same array.
- **Suspending an event.** A task that switches away has to stop in the
  middle of a call chain and continue later. Translated code keeps no
  state outside the heap, so in principle the lowering could record a
  resume address, end the event, and jump back in from a later one. It
  does not do that today.
- **User space.** `init` is a separate WebAssembly module which the host
  compiles and instantiates when the kernel `exec`s it
  (`wasm_load_executable`). An Udon program is fixed when it is assembled;
  there is nothing to hand a new module to. A kernel that got this far
  would end in "No working init found".
- **Time.** Fifty million externs for the first phase of the boot is
  minutes of frames even when cut into pieces, if the Udon VM manages a
  few hundred thousand a second (an estimate; this has not been measured
  in VRChat).

The other port, [tombl/linux](https://github.com/tombl/linux) (Linux
6.1.132, clang 19), does not get this far: its module uses exception
handling, reference types, multi-value and SIMD, which the parser does not
read.

The shape that does fit the VM is the other way round — a small
interpreter or emulator written for it, stepping a bounded amount of work
per frame, like `examples/pi` or `examples/image-codec`.
