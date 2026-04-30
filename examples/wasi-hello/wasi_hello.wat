;; wasi-hello: minimal WASI Preview 1 hello-world.
;;
;; This module demonstrates the WASI MVP subset that
;; `docs/spec_wasi_preview_1.md` requires the translator to recognise:
;;
;;   - `fd_write` to write a fixed UTF-8 string to fd 1 (stdout).
;;   - `proc_exit(0)` to terminate.
;;
;; That is the entire program. Nothing else from `wasi_snapshot_preview1`
;; is imported, on purpose — see README.md for why hand-rolled WAT was
;; chosen over a `wasm32-wasip1` Rust producer.
;;
;; `__udon_meta` is supplied as a sidecar file (`wasi_hello.udon_meta.json`)
;; alongside this `.wasm` — the translator never reads it from inside the
;; module. See docs/spec_udonmeta_conversion.md.
;;
;; Memory layout (one page is plenty):
;;   0x0000..0x000C  message "Hello, Udon!\n"      (13 bytes)
;;   0x0010..0x0017  iovec  { buf=0x0, buf_len=13 } (8 bytes)
;;   0x0020..0x0023  nwritten scratch              (4 bytes, written by fd_write)
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))

  (memory (export "memory") 1)

  (data (i32.const 0x0000) "Hello, Udon!\n")
  (data (i32.const 0x0010) "\00\00\00\00\0d\00\00\00") ;; iovec: buf=0, len=13

  ;; The WASI entry point. wasi-libc / Rust / Zig all expose `_start`;
  ;; we follow the same convention so the translator sees a single
  ;; canonical entry to map to the Udon `_start` event.
  (func $_start (export "_start")
    ;; fd_write(fd=1, iovs=0x10, iovs_len=1, nwritten_ptr=0x20)
    (drop
      (call $fd_write
        (i32.const 1)       ;; stdout
        (i32.const 0x0010)  ;; iovec array pointer
        (i32.const 1)       ;; iovec count
        (i32.const 0x0020))) ;; nwritten out-pointer
    (call $proc_exit (i32.const 0))))
