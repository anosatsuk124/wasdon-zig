using System;
using UdonSharp;
using UnityEngine;
using UnityEngine.UI;
using VRC.Udon;

namespace Wasdon
{
    [UdonBehaviourSyncMode(BehaviourSyncMode.None)]
    public class WasdonGridBenchmark : UdonSharpBehaviour
    {
        public const int Samples = 9;
        public const int PreviewSide = 127;
        public const int SingleEventSide = 512;
        public UdonBehaviour[] workers;
        public RawImage[] images;
        public Text[] results;
        public Text status;
        [HideInInspector] public int kind;
        [HideInInspector] public int side;
        [HideInInspector] public byte[] input;
        [HideInInspector] public byte[] expected;
        [HideInInspector] public int[] previewIndices;
        [HideInInspector] public Color32[] palette;

        private byte[] buffer;
        private Color32[] colors;
        private Texture2D[] textures;
        private double[] samples;
        private int trial;
        private int step;
        private bool trialStarted;
        private double elapsedMs;
        private bool animating;
        private bool measuring;
        [HideInInspector] public bool complete;

        private void Start() { ResetBenchmark(); }

        public void ResetBenchmark()
        {
            animating = false;
            measuring = false;
            complete = false;
            if (buffer == null)
            {
                buffer = new byte[input.Length];
                colors = new Color32[previewIndices.Length];
                textures = new Texture2D[workers.Length];
                samples = new double[workers.Length * Samples];
                int width = Math.Min(PreviewSide, side);
                for (int lane = 0; lane < workers.Length; lane++)
                {
                    textures[lane] = new Texture2D(width, width, TextureFormat.RGBA32, false);
                    textures[lane].filterMode = FilterMode.Point;
                    images[lane].texture = textures[lane];
                }
            }
            for (int lane = 0; lane < workers.Length; lane++)
            {
                Draw(lane, input);
                results[lane].text = "Ready";
            }
            status.text = side + " x " + side + " cells";
        }

        public void Visualize()
        {
            ResetBenchmark();
            for (int lane = 0; lane < workers.Length; lane++) LoadWorker(lane);
            step = 0;
            animating = true;
        }

        public void Benchmark()
        {
            ResetBenchmark();
            BeginTrials();
        }

        private void BeginTrials()
        {
            animating = false;
            measuring = true;
            trial = 0;
            trialStarted = false;
            status.text = "Warming up";
        }

        private void Update()
        {
            if (animating) AnimateStep();
            else if (measuring) MeasureTrial();
        }

        private void LoadWorker(int lane)
        {
            Buffer.BlockCopy(input, 0, buffer, 0, input.Length);
            UdonBehaviour worker = workers[lane];
            worker.SetProgramVariable("data", buffer);
            worker.SetProgramVariable("side", side);
            worker.SetProgramVariable("kind", kind);
            worker.SetProgramVariable("finished", 0);
            worker.SendCustomEvent("Load");
        }

        private void AnimateStep()
        {
            bool done = false;
            for (int lane = 0; lane < workers.Length; lane++)
            {
                UdonBehaviour worker = workers[lane];
                worker.SendCustomEvent("Step");
                worker.SendCustomEvent("Read");
                bool laneDone = (int)worker.GetProgramVariable("finished") == 1;
                if (lane > 0 && laneDone != done)
                {
                    Fail(lane, "Step counts differ");
                    return;
                }
                done = laneDone;
                Draw(lane, buffer);
                if (done && !Validate(lane)) return;
            }
            step++;
            status.text = side + " x " + side + "  /  Step " + step;
            if (done) BeginTrials();
        }

        private void MeasureTrial()
        {
            int lanes = workers.Length;
            int round = trial / lanes;
            int lane = (trial + round) % lanes;
            if (!trialStarted)
            {
                LoadWorker(lane);
                elapsedMs = 0;
                trialStarted = true;
            }
            UdonBehaviour worker = workers[lane];
            // A 1024-square Julia image can exceed the SDK's per-event
            // watchdog. Time one band per frame for each worker at that size.
            bool sliced = side > SingleEventSide;
            string compute = sliced ? "Step" : "Run";
            double start = Time.realtimeSinceStartupAsDouble;
            worker.SendCustomEvent(compute);
            elapsedMs += (Time.realtimeSinceStartupAsDouble - start) * 1000.0;
            if (sliced)
            {
                worker.SetProgramVariable("finished", -1);
                worker.SendCustomEvent("Poll");
                int finished = (int)worker.GetProgramVariable("finished");
                if (finished == 0) return;
                if (finished != 1)
                {
                    Fail(lane, "Worker did not report progress");
                    return;
                }
            }

            worker.SendCustomEvent("Read");
            if ((int)worker.GetProgramVariable("finished") != 1)
            {
                Fail(lane, "Worker stopped early");
                return;
            }
            if (!Validate(lane)) return;
            if (round > 0)
            {
                samples[lane * Samples + round - 1] = elapsedMs;
                results[lane].text = elapsedMs.ToString("F3") + " ms";
            }
            if (round == 0) Draw(lane, buffer);
            trial++;
            trialStarted = false;
            status.text = side + " x " + side + "  /  Trial " + Math.Min(Samples, trial / lanes) + " of " + Samples;
            if (trial == lanes * (Samples + 1)) ShowResults();
        }

        private bool Validate(int lane)
        {
            for (int i = 0; i < buffer.Length; i++)
            {
                if (buffer[i] == expected[i]) continue;
                Fail(lane, "Cell " + i + " was " + buffer[i] + ", expected " + expected[i]);
                return false;
            }
            return true;
        }

        private void Fail(int lane, string message)
        {
            results[lane].text = "Validation failed";
            status.text = message;
            animating = false;
            measuring = false;
        }

        private void ShowResults()
        {
            double[] sorted = new double[Samples];
            int baseline = workers.Length - 1;
            double[] medians = new double[workers.Length];
            for (int lane = 0; lane < workers.Length; lane++)
            {
                Array.Copy(samples, lane * Samples, sorted, 0, Samples);
                Array.Sort((Array)sorted);
                medians[lane] = sorted[Samples / 2];
                results[lane].text = medians[lane].ToString("F3") + " ms";
            }
            for (int lane = 0; lane < baseline; lane++)
                results[lane].text += "  /  " + (medians[baseline] / medians[lane]).ToString("F2") + "x";
            status.text = side + " x " + side + "  /  Median of " + Samples + "  /  Speedup vs U#";
            measuring = false;
            complete = true;
        }

        private void Draw(int lane, byte[] pixels)
        {
            for (int i = 0; i < colors.Length; i++)
                colors[i] = palette[pixels[previewIndices[i]]];
            textures[lane].SetPixels32(colors);
            textures[lane].Apply(false, false);
        }
    }
}
