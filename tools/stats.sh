#!/bin/sh
# Emulator cost of every example scenario: Udon instructions executed,
# extern calls made, heap slots and code size. Run after `zig build examples`.
#   tools/stats.sh [example...]
set -e
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || set -- bench mandelbrot pi blocks qoi ragdoll
printf '%-11s %12s %10s %6s %8s\n' example instructions externs heap lines
for name in "$@"; do
    case $name in bench) dir=wasm-bench ;; *) dir=$name ;; esac
    events=$(grep -v '^#' "examples/$dir/scenario.txt" | tr '\n' ' ')
    run=$(./zig-out/bin/wasdon_zig run "zig-out/uasm/$name.uasm" $events 2>&1 >/dev/null | tail -1)
    heap=$(./zig-out/bin/wasdon_zig check "zig-out/uasm/$name.uasm" | sed -E 's/.*heap slots: ([0-9]+).*/\1/')
    printf '%-11s %12s %10s %6s %8s\n' "$name" "$(echo "$run" | cut -d' ' -f1)" "$(echo "$run" | cut -d' ' -f3)" "$heap" "$(wc -l < "zig-out/uasm/$name.uasm")"
done
