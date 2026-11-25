/* setjmp.h for mruby on wasm32-wasi.
 *
 * wasi-libc only has setjmp/longjmp with the WebAssembly exception-handling
 * proposal, which the Udon translator does not read. mruby uses the pair for
 * one thing: unwinding out of C code when an exception is raised there.
 *
 * This header makes `setjmp` a constant 0 — "no jump has arrived" — and
 * leaves `longjmp` to main.c, which reports the exception and exits. A
 * script that raises no exception from C code never notices; `begin` /
 * `rescue` around exceptions raised by the VM itself (OP_RAISE) still works,
 * because the VM handles those without longjmp.
 */
#ifndef WASDON_SETJMP_H
#define WASDON_SETJMP_H

typedef int jmp_buf[1];

#define setjmp(buf) ((void)(buf), 0)

_Noreturn void longjmp(jmp_buf buf, int value);

#endif
