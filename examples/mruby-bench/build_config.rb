# mruby cross-build config for wasm32-wasi (wasi-sdk).
#
# Invoked indirectly by Rake when the wrapping Makefile runs
# `rake MRUBY_CONFIG=$(PWD)/build_config.rb` against the vendored mruby
# tree. Two builds are declared:
#
#  * `host`        — used to build mrbc (the bytecode compiler) for the
#                    build machine, since mrbc must run during build.
#  * `wasm32-wasi` — cross-build that produces libmruby.a linkable into
#                    main.c via the wasi-sdk clang.
#
# Gembox selection is deliberately conservative: only `core` plus a few
# pure-Ruby gems that do not pull `mruby-io` / `mruby-socket`.
# Including filesystem or socket gems would drag in WASI imports
# (`path_open`, `fd_filestat_get`, …) that wasdon-zig does not support.

MRuby::Build.new do |conf|
  toolchain :gcc
  conf.gembox 'default'
end

MRuby::CrossBuild.new('wasm32-wasi') do |conf|
  toolchain :clang

  wasi_sdk = ENV['WASI_SDK_PATH'] or
    raise "WASI_SDK_PATH must be set to the wasi-sdk install root"
  sysroot = "#{wasi_sdk}/share/wasi-sysroot"

  conf.cc do |cc|
    cc.command = "#{wasi_sdk}/bin/clang"
    cc.flags = %W[
      --target=wasm32-wasi
      --sysroot=#{sysroot}
      -O2
      -fno-exceptions
      -DMRB_NO_BOXING
      -DMRB_NO_PRESYM
      -DMRB_NO_STDIO_REWIND
    ]
    cc.include_paths << "#{sysroot}/include"
  end

  conf.archiver do |ar|
    ar.command = "#{wasi_sdk}/bin/llvm-ar"
  end

  # Conservative gem set — avoid `mruby-io`, `mruby-socket`, `mruby-bin-*`.
  conf.gem core: 'mruby-print'
  conf.gem core: 'mruby-math'
  conf.gem core: 'mruby-array-ext'
  conf.gem core: 'mruby-string-ext'
  conf.gem core: 'mruby-numeric-ext'
  conf.gem core: 'mruby-hash-ext'
  conf.gem core: 'mruby-range-ext'
  conf.gem core: 'mruby-enum-ext'
  conf.gem core: 'mruby-symbol-ext'
  conf.gem core: 'mruby-object-ext'
  conf.gem core: 'mruby-objectspace'
  conf.gem core: 'mruby-fiber'
  conf.gem core: 'mruby-enumerator'
  conf.gem core: 'mruby-sprintf'
  conf.gem core: 'mruby-error'
  conf.gem core: 'mruby-method'
  conf.gem core: 'mruby-toplevel-ext'
  conf.gem core: 'mruby-class-ext'
  conf.gem core: 'mruby-eval'

  # Library-only build: no executables. The driver lives in main.c.
  conf.disable_presym
end
