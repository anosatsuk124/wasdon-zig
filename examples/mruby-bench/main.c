/* mruby running a benchmark script on the Udon VM.
 *
 * bench.rb is compiled to mruby bytecode by `mrbc` at build time and
 * embedded here as `bench_irep`, so nothing is read from a file system.
 * What is left of WASI is `fd_write`, `clock_time_get` and `proc_exit`.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include <mruby.h>
#include <mruby/irep.h>

#include "shim/setjmp.h"

extern const uint8_t bench_irep[];

/* See shim/setjmp.h: an exception raised from C code ends the program. */
_Noreturn void longjmp(jmp_buf buf, int value) {
    (void)buf;
    (void)value;
    fprintf(stderr, "mruby raised an exception from C code\n");
    exit(1);
}

static long long now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

int main(void) {
    mrb_state *mrb = mrb_open();
    if (mrb == NULL) {
        fprintf(stderr, "mrb_open failed\n");
        return 1;
    }

    long long t0 = now_ns();
    mrb_load_irep(mrb, bench_irep);
    long long t1 = now_ns();

    if (mrb->exc) {
        fprintf(stderr, "mruby raised an exception\n");
        mrb_close(mrb);
        return 1;
    }

    printf("total   = %lld ns\n", t1 - t0);
    mrb_close(mrb);
    return 0;
}
