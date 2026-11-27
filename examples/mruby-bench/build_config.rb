# mruby build configuration for the Udon benchmark.
#
# Two builds: `host` makes mrbc, the bytecode compiler, for the machine
# doing the build; `wasm32-wasi` makes libmruby.a with `zig cc`, which
# brings its own wasi-libc — no wasi-sdk needed.

here = File.dirname(File.expand_path(__FILE__))

MRuby::Build.new do |conf|
  toolchain :gcc
  conf.gem core: 'mruby-bin-mrbc'
end

MRuby::CrossBuild.new('wasm32-wasi') do |conf|
  toolchain :clang

  conf.cc do |cc|
    cc.command = 'zig cc'
    cc.flags = %W[
      -target wasm32-wasi -Os
      -DMRB_NO_BOXING -DMRB_NO_PRESYM -DMRB_NO_STDIO_REWIND
      -D_WASI_EMULATED_PROCESS_CLOCKS
    ]
    # Before the system headers: shim/setjmp.h (see there).
    cc.include_paths.unshift "#{here}/shim"
  end

  conf.archiver do |ar|
    ar.command = 'zig ar'
  end

  # No gem that touches files, sockets or processes: those would import
  # WASI functions an Udon behaviour has nothing to back with.
  %w[
    mruby-print mruby-math mruby-array-ext mruby-string-ext
    mruby-numeric-ext mruby-hash-ext mruby-range-ext mruby-enum-ext
    mruby-symbol-ext mruby-object-ext mruby-sprintf mruby-error
    mruby-toplevel-ext mruby-class-ext
  ].each { |g| conf.gem core: g }

  conf.disable_presym
end
