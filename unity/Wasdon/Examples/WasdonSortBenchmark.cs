using System;
using UdonSharp;
using UnityEngine;
using UnityEngine.UI;
using VRC.Udon;

namespace Wasdon
{
    [UdonBehaviourSyncMode(BehaviourSyncMode.None)]
    public class WasdonSortBenchmark : UdonSharpBehaviour
    {
        public const int Lanes = 3;
        public const int BarsPerLane = 48;

        public UdonBehaviour[] sorters;
        public RectTransform[] bars;
        public Text[] results;
        public Text status;

        private const int SampleSize = 511;
        private const int Samples = 9;
        private const float PassInterval = 0.55f;

        private byte[] preview;
        private byte[] input;
        private byte[] expected;
        private byte[] buffer;
        private double[] times = new double[Lanes * Samples];
        private int trial;
        private int mergeWidth;
        private float nextPass;
        private bool animating;
        private bool measuring;

        private void Start()
        {
            preview = MakeInput(BarsPerLane);
            ResetBenchmark();
        }

        public void ResetBenchmark()
        {
            animating = false;
            measuring = false;
            status.text = "Stable bottom-up merge sort";
            for (int lane = 0; lane < Lanes; lane++)
            {
                Draw(lane, preview);
                results[lane].text = "Ready";
            }
        }

        public void Visualize()
        {
            ResetBenchmark();
            buffer = new byte[BarsPerLane];
            for (int lane = 0; lane < Lanes; lane++) Load(sorters[lane], preview);
            mergeWidth = 1;
            nextPass = Time.unscaledTime + PassInterval;
            status.text = "48 values  /  Merge runs of 1";
            animating = true;
        }

        public void Benchmark()
        {
            ResetBenchmark();
            input = MakeInput(SampleSize);
            expected = ReferenceOrder(input);
            buffer = new byte[SampleSize];
            trial = 0;
            measuring = true;
            status.text = "511 values  /  Warming up";
        }

        private void Update()
        {
            if (measuring) MeasureTrial();
            else if (animating && Time.unscaledTime >= nextPass) AnimatePass();
        }

        private void AnimatePass()
        {
            bool finished = mergeWidth * 2 >= BarsPerLane;
            for (int lane = 0; lane < Lanes; lane++)
            {
                UdonBehaviour sorter = sorters[lane];
                sorter.SendCustomEvent("Step");
                sorter.SendCustomEvent("Read");
                Draw(lane, buffer);
                results[lane].text = finished ? "Sorted" : "Run width " + (mergeWidth * 2);
            }
            status.text = "48 values  /  Merged runs of " + mergeWidth;
            mergeWidth *= 2;
            nextPass = Time.unscaledTime + PassInterval;
            animating = !finished;
        }

        private void MeasureTrial()
        {
            // The first round warms up each VM. Rotate the order in later
            // rounds so each implementation runs first equally often.
            int round = trial / Lanes;
            int lane = (trial + round) % Lanes;
            UdonBehaviour sorter = sorters[lane];
            Load(sorter, input);

            double start = Time.realtimeSinceStartupAsDouble;
            sorter.SendCustomEvent("Sort");
            double milliseconds = (Time.realtimeSinceStartupAsDouble - start) * 1000.0;

            sorter.SendCustomEvent("Read");
            for (int i = 0; i < SampleSize; i++)
            {
                if (buffer[i] == expected[i]) continue;
                measuring = false;
                results[lane].text = "Incorrect output";
                status.text = "Benchmark stopped  /  Output validation failed";
                return;
            }
            if (round > 0)
            {
                times[lane * Samples + round - 1] = milliseconds;
                results[lane].text = "Sample " + round + " / " + Samples;
            }

            trial++;
            if (trial == Lanes) status.text = "511 values  /  Measuring sort time";
            if (trial == Lanes * (Samples + 1)) ShowResults();
        }

        private void ShowResults()
        {
            measuring = false;
            double[] medians = new double[Lanes];
            double fastest = double.MaxValue;
            for (int lane = 0; lane < Lanes; lane++)
            {
                int first = lane * Samples;
                for (int i = first + 1; i < first + Samples; i++)
                {
                    double value = times[i];
                    int j = i;
                    while (j > first && times[j - 1] > value)
                    {
                        times[j] = times[j - 1];
                        j--;
                    }
                    times[j] = value;
                }
                medians[lane] = times[first + Samples / 2];
                if (medians[lane] < fastest) fastest = medians[lane];
            }
            for (int lane = 0; lane < Lanes; lane++)
            {
                string ratio = fastest > 0 ? "  /  " + (medians[lane] / fastest).ToString("F2") + "x" : "";
                results[lane].text = medians[lane].ToString("F3") + " ms" + ratio;
            }
            status.text = "511 values  /  Median of 9  /  1.00x is fastest";
        }

        private void Load(UdonBehaviour sorter, byte[] source)
        {
            Buffer.BlockCopy(source, 0, buffer, 0, source.Length);
            sorter.SetProgramVariable("data", buffer);
            sorter.SendCustomEvent("Load");
        }

        private byte[] MakeInput(int count)
        {
            byte[] values = new byte[count];
            int seed = 127;
            for (int i = 0; i < count; i++)
            {
                seed = (seed * 25173 + 13849) & 65535;
                values[i] = (byte)(seed >> 8);
            }
            return values;
        }

        // Independently compute the expected permutation using byte frequencies.
        private byte[] ReferenceOrder(byte[] source)
        {
            int[] histogram = new int[256];
            for (int i = 0; i < source.Length; i++) histogram[source[i]]++;
            byte[] output = new byte[source.Length];
            int index = 0;
            for (int value = 0; value < histogram.Length; value++)
            {
                for (int copies = 0; copies < histogram[value]; copies++) output[index++] = (byte)value;
            }
            return output;
        }

        private void Draw(int lane, byte[] values)
        {
            int first = lane * BarsPerLane;
            for (int i = 0; i < BarsPerLane; i++)
                bars[first + i].localScale = new Vector3(1f, (values[i] + 1) / 256f, 1f);
        }
    }
}
