using System;
using UdonSharp;

namespace Wasdon
{
    [UdonBehaviourSyncMode(BehaviourSyncMode.None)]
    public class WasdonMergeSort : UdonSharpBehaviour
    {
        public byte[] data;

        public const int Capacity = 65536;
        private byte[] front = new byte[Capacity];
        private byte[] back = new byte[Capacity];
        private int count;
        private int width;
        private bool inFront;

        public void Load()
        {
            count = Math.Min(data.Length, Capacity);
            Buffer.BlockCopy(data, 0, front, 0, count);
            width = 1;
            inFront = true;
        }

        public void Sort()
        {
            while (width < count) Merge();
        }

        public void Step()
        {
            if (width < count) Merge();
        }

        public void Read()
        {
            Buffer.BlockCopy(inFront ? front : back, 0, data, 0, count);
        }

        private void Merge()
        {
            byte[] src = inFront ? front : back;
            byte[] dst = inFront ? back : front;
            int start = 0;
            while (start < count)
            {
                int mid = Math.Min(start + width, count);
                int end = Math.Min(mid + width, count);
                int left = start;
                int right = mid;
                for (int i = start; i < end; i++)
                {
                    if (left < mid && (right == end || src[left] <= src[right]))
                    {
                        dst[i] = src[left];
                        left++;
                    }
                    else
                    {
                        dst[i] = src[right];
                        right++;
                    }
                }
                start = end;
            }
            inFront = !inFront;
            width *= 2;
        }
    }
}
