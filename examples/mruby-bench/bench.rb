# mruby benchmark for wasdon-zig.
#
# Four workloads matching examples/rhai-bench:
#   1. fib(N)        — recursion
#   2. mandel        — integer-loop arithmetic
#   3. str_bench     — String concat (heap allocator + GC)
#   4. wall-time via Process.clock_gettime is done from main.c, not here
#
# Kept small so fib(20) + mandel + str_bench fits inside Udon's per-event
# 10 s VM budget.

def fib(n)
  n < 2 ? n : fib(n - 1) + fib(n - 2)
end

def mandel
  total = 0
  h = 8
  w = 16
  max_iter = 24
  py = 0
  while py < h
    px = 0
    while px < w
      x0 = (px * 3072 / w) - 2048
      y0 = (py * 2048 / h) - 1024
      x = 0
      y = 0
      it = 0
      while it < max_iter
        xx = (x * x) / 1024
        yy = (y * y) / 1024
        break if xx + yy > 4096
        xy = (x * y) / 1024
        x = xx - yy + x0
        y = 2 * xy + y0
        it += 1
      end
      total += it
      px += 1
    end
    py += 1
  end
  total
end

def str_bench
  s = ""
  64.times { s += "abc" }
  s.length
end

# main.c times each workload around mrb_load_irep — these results just
# get printed so the optimizer cannot drop them.
puts "fib(20) = #{fib(20)}"
puts "mandel  = #{mandel}"
puts "str.len = #{str_bench}"
