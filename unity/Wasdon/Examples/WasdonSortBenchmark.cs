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

        [Tooltip("Values sorted by each implementation in both Visualize and Benchmark.")]
        [Min(2)] public int sampleSize = 511;
        [Tooltip("Minimum time between visible merge passes, in seconds.")]
        [Min(0f)] public float passInterval = 0.55f;
        private const int Samples = 9;

        private byte[] preview;
        private byte[] input;
        private byte[] expected;
        private byte[] buffer;
        private double[] times = new double[Lanes * Samples];
        private int trial;
        private int count;
        private double[] stepTimes = new double[Lanes];
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
            PrepareRun();
            for (int lane = 0; lane < Lanes; lane++)
            {
                Load(sorters[lane], input);
                Draw(lane, input);
                stepTimes[lane] = 0;
            }
            mergeWidth = 1;
            nextPass = Time.unscaledTime + passInterval;
            status.text = count + " values  /  Merge runs of 1";
            animating = true;
        }

        public void Benchmark()
        {
            PrepareRun();
            BeginTrials();
        }

        private void PrepareRun()
        {
            ResetBenchmark();
            count = Mathf.Clamp(sampleSize, 2, UdonSharpMergeSort.Capacity);
            input = MakeInput(count);
            expected = ReferenceOrder(input);
            buffer = new byte[count];
        }

        private void BeginTrials()
        {
            trial = 0;
            measuring = true;
            status.text = count + " values  /  Warming up";
        }

        private void Update()
        {
            if (measuring) MeasureTrial();
            else if (animating && Time.unscaledTime >= nextPass) AnimatePass();
        }

        private void AnimatePass()
        {
            bool finished = mergeWidth * 2 >= count;
            for (int lane = 0; lane < Lanes; lane++)
            {
                UdonBehaviour sorter = sorters[lane];
                double start = Time.realtimeSinceStartupAsDouble;
                sorter.SendCustomEvent("Step");
                stepTimes[lane] += (Time.realtimeSinceStartupAsDouble - start) * 1000.0;
                sorter.SendCustomEvent("Read");
                Draw(lane, buffer);
                results[lane].text = stepTimes[lane].ToString("F3") + " ms  /  steps";
                if (finished && !Validate(lane)) return;
            }
            status.text = count + " values  /  Merged runs of " + mergeWidth;
            mergeWidth *= 2;
            nextPass = Time.unscaledTime + passInterval;
            animating = !finished;
            if (finished) BeginTrials();
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
            if (!Validate(lane)) return;
            if (round > 0)
            {
                times[lane * Samples + round - 1] = milliseconds;
                results[lane].text = milliseconds.ToString("F3") + " ms  /  " + round + " of " + Samples;
            }

            trial++;
            if (trial == Lanes) status.text = count + " values  /  Measuring sort time";
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
            status.text = count + " values  /  Median of " + Samples + "  /  1.00x is fastest";
        }

        private bool Validate(int lane)
        {
            for (int i = 0; i < count; i++)
            {
                if (buffer[i] == expected[i]) continue;
                animating = false;
                measuring = false;
                results[lane].text = "Incorrect output";
                status.text = "Benchmark stopped  /  Output validation failed";
                return false;
            }
            return true;
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
            {
                int index = i * (values.Length - 1) / (BarsPerLane - 1);
                bars[first + i].localScale = new Vector3(1f, (values[index] + 1) / 256f, 1f);
            }
        }
    }
}
