# mruby-bench: Ruby on the Udon VM

[mruby](https://mruby.org/) 3.3.0 — the embeddable Ruby, about 60 000
lines of C — built for `wasm32-wasi` and translated to Udon Assembly. It
runs `bench.rb`, the three workloads of [`examples/bench`](../bench/)
written in Ruby:

```
fib(20) = 6765
mandel  = 1346
str.len = 192
total   = 0 ns
```

(`ruby bench.rb` prints the same three lines. `mandel` is 1346 here and
1345 in the other benchmarks because Ruby's integer division rounds down
where theirs truncates. The emulator's clock only advances between frames,
hence the zero.)

| | |
|---|---:|
| WebAssembly | 406 091 bytes, 1 006 functions |
| Udon Assembly | 498 255 instructions, 99 721 `EXTERN`s, heap 16 707 slots |
| executed | 107 882 591 instructions, 23 789 796 `EXTERN`s |

That is 128 times the externs of the same workloads compiled ahead of time
(`bench-wasi-rs`, 185 936), and a fifth of what the Rhai interpreter
([`examples/rhai-bench`](../rhai-bench/)) needs: mruby runs bytecode
compiled at build time, Rhai walks a syntax tree it parses at run time.
The bytecode dispatch is one big `switch`, which the translator turns into
an indexed jump (`docs/spec_call_return_conversion.md` §5); as a chain of
comparisons the same run takes 33 069 048 externs.

It is still far more than one Udon event's ten seconds allow. Like
`rhai-bench`, this is a test of the translator on a real C program, not a
recipe for scripting in a world.

## How it is built

- `bench.rb` is compiled to bytecode by `mrbc` on the build machine and
  embedded as a C array, so nothing is read from a file system. The WASI
  imports left are `fd_write`, `clock_time_get`, `proc_exit` and wasi-libc's
  start-up calls.
- The compiler is `zig cc -target wasm32-wasi`, which brings its own
  wasi-libc. No wasi-sdk is needed.
- **`setjmp` / `longjmp`.** wasi-libc has them only with the WebAssembly
  exception-handling proposal, which the translator does not read. mruby
  uses them for one thing: unwinding C frames when an exception is raised
  from C code. `shim/setjmp.h` makes `setjmp` a constant 0 and `main.c`
  defines `longjmp` to report the exception and exit. A script that raises
  nothing from C never notices.
- Gems that touch files, sockets or processes are left out
  (`build_config.rb`).

```sh
zig build test -Dmruby     # make, translate, check, execute, compare the output
zig build stats -Dmruby    # its row in the statistics table
```

The first build clones mruby into `vendor/` (not checked in) and needs
`make`, `git`, Ruby with `rake`, and a host C compiler for `mrbc`. By hand:

```sh
make -C examples/mruby-bench
wasdon_zig translate examples/mruby-bench/build/mruby_bench.wasm -o mruby.uasm
wasdon_zig run mruby.uasm --events _start
```

The example follows `examples/mruby-bench` on the `wasi-preview-1` branch,
which had not been built; the differences are the compiler, the `setjmp`
shim, and a smaller host build (only `mrbc`).
