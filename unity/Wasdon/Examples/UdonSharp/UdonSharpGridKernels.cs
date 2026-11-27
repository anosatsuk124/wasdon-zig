using System;
using UdonSharp;

namespace Wasdon
{
    [UdonBehaviourSyncMode(BehaviourSyncMode.None)]
    public class UdonSharpGridKernels : UdonSharpBehaviour
    {
        public byte[] data;
        public int kind;
        public int side;
        public int finished;

        private byte[] pixels;
        private int cursor;

        public void Load()
        {
            if (pixels == null || pixels.Length != data.Length) pixels = new byte[data.Length];
            Buffer.BlockCopy(data, 0, pixels, 0, data.Length);
            cursor = 0;
        }

        public void Read()
        {
            Buffer.BlockCopy(pixels, 0, data, 0, pixels.Length);
            Poll();
        }

        public void Poll()
        {
            finished = Done() ? 1 : 0;
        }

        public void Step()
        {
            if (!Done()) Advance();
        }

        public void Run()
        {
            while (!Done()) Advance();
        }

        private bool Done()
        {
            if (kind == 0) return cursor >= side;
            if (kind == 2) return cursor >= 2 * side;
            int p = 3 + 2 * cursor;
            return p * p >= 2 * pixels.Length;
        }

        private void Advance()
        {
            if (kind == 0) JuliaRows();
            else if (kind == 1) SieveFactors();
            else DistanceRows();
        }

        private void JuliaRows()
        {
            int end = Math.Min(cursor + 8, side);
            double scale = 3.0 / side;
            for (int y = cursor; y < end; y++)
            {
                double im = (y + 0.5) * scale - 1.5;
                int offset = y * side;
                for (int x = 0; x < side; x++)
                {
                    double a = (x + 0.5) * scale - 1.5;
                    double b = im;
                    double aa = a * a;
                    double bb = b * b;
                    int n = 0;
                    while (n < 64 && aa + bb <= 4.0)
                    {
                        b = (a + a) * b + 0.125;
                        a = aa - bb - 0.75;
                        aa = a * a;
                        bb = b * b;
                        n++;
                    }
                    pixels[offset + x] = (byte)n;
                }
            }
            cursor = end;
        }

        private void SieveFactors()
        {
            int p = 3 + 2 * cursor;
            int end = p + 16;
            int count = pixels.Length;
            for (; p < end && p * p < 2 * count; p += 2)
            {
                if (pixels[p / 2] != 0) continue;
                for (int i = p * p / 2; i < count; i += p) pixels[i] = 255;
            }
            cursor = (p - 3) / 2;
        }

        private void DistanceRows()
        {
            bool forward = cursor < side;
            int end = Math.Min(cursor + 8, forward ? side : 2 * side);
            int stride = forward ? 1 : -1;
            for (int r = cursor; r < end; r++)
            {
                int y = forward ? r : 2 * side - r - 1;
                int i = y * side + (forward ? 0 : side - 1);
                int limit = i + stride * side;
                int offset = (forward ? -side : side);
                if ((forward && y == 0) || (!forward && y == side - 1)) offset = 0;
                int carry = 255;
                for (; i != limit; i += stride)
                {
                    carry = Math.Min((int)pixels[i], 1 + Math.Min(carry, (int)pixels[i + offset]));
                    pixels[i] = (byte)carry;
                }
            }
            cursor = end;
        }
    }
}
