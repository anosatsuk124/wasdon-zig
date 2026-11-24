using UdonSharp;
using UnityEngine;

/// <summary>
/// The benchmark's three workloads in UdonSharp: the baseline the Zig and
/// Rust versions (examples/bench/zig, examples/bench/rs) are measured
/// against. They are the workloads of the mruby and Rhai benchmarks — a
/// recursive Fibonacci, an integer Mandelbrot and a string built by
/// repeated concatenation — written the way one writes U#.
///
/// Each public method is one workload and leaves its result in a field,
/// so the cost of formatting and logging is not part of the measurement.
/// </summary>
public class UdonBench : UdonSharpBehaviour
{
    public int fibN = 20;
    public int fibResult;
    public int mandelResult;
    public int strResult;

    public void Fib()
    {
        fibResult = FibRec(fibN);
    }

    [RecursiveMethod]
    private int FibRec(int n)
    {
        if (n < 2) return n;
        return FibRec(n - 1) + FibRec(n - 2);
    }

    public void Mandel()
    {
        int total = 0;
        int h = 8;
        int w = 16;
        int maxIter = 24;
        int py = 0;
        while (py < h)
        {
            int px = 0;
            while (px < w)
            {
                // Fixed point, scale 1024: x in -2..1, y in -1..1.
                int x0 = (px * 3072 / w) - 2048;
                int y0 = (py * 2048 / h) - 1024;
                int x = 0;
                int y = 0;
                int it = 0;
                while (it < maxIter)
                {
                    int xx = (x * x) / 1024;
                    int yy = (y * y) / 1024;
                    if (xx + yy > 4096) break;
                    int xy = (x * y) / 1024;
                    x = xx - yy + x0;
                    y = 2 * xy + y0;
                    it += 1;
                }
                total += it;
                px += 1;
            }
            py += 1;
        }
        mandelResult = total;
    }

    public void Str()
    {
        string s = "";
        int i = 0;
        while (i < 64)
        {
            s += "abc";
            i += 1;
        }
        strResult = s.Length;
    }
}
