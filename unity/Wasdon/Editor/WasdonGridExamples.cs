using System;
using UdonSharp;
using UdonSharp.Compiler;
using UdonSharpEditor;
using UnityEditor;
using UnityEngine;
using UnityEngine.UI;
using VRC.SDKBase;
using VRC.Udon;

namespace Wasdon
{
    public static partial class WasdonExamples
    {
        private static readonly string[] GridNames = { "Julia set", "Prime sieve", "Manhattan distance" };

        [MenuItem("Tools/Wasdon/Create Grid Benchmarks/256 x 256")]
        private static void Grids256() { AddGridsToScene(256); }

        [MenuItem("Tools/Wasdon/Create Grid Benchmarks/512 x 512")]
        private static void Grids512() { AddGridsToScene(512); }

        [MenuItem("Tools/Wasdon/Create Grid Benchmarks/1024 x 1024")]
        private static void Grids1024() { AddGridsToScene(1024); }

        private static void AddGridsToScene(int side)
        {
            if (!IsCompiled(typeof(WasdonGridBenchmark)) || !IsCompiled(typeof(UdonSharpGridKernels)))
                UdonSharpCompilerV1.CompileSync();
            var root = CreateGridBenchmarks(side);
            Undo.RegisterCreatedObjectUndo(root, "Create grid benchmarks");
            root.transform.position = Vector3.up * 1.5f;
            Selection.activeGameObject = root;
        }

        internal static GameObject CreateGridBenchmarks(int side)
        {
            if (side < 8 || side > 1024) throw new ArgumentOutOfRangeException(nameof(side));
            var programs = new[] { FindProgram("grid-bench"), FindProgram("grid-bench-rs") };
            if (Array.Exists(programs, program => program == null))
                throw new InvalidOperationException("Missing grid benchmark assets. Regenerate with zig build unity -Drust.");
            string[] names = { "Wasdon (Zig)", "Wasdon (Rust)", "UdonSharp" };
            var root = new GameObject("Grid Benchmarks");
            for (int kind = 0; kind < GridNames.Length; kind++)
            {
                var go = new GameObject(GridNames[kind]);
                go.transform.SetParent(root.transform, false);
                go.transform.localPosition = new Vector3(4.4f * kind, 0, 0);
                var b = go.AddUdonSharpComponent<WasdonGridBenchmark>();
                b.side = side;
                b.kind = kind;
                MakeGridReference(kind, side, out b.input, out b.expected);
                b.previewIndices = GridPreview(kind, side);
                b.palette = GridPalette(kind, side);
                b.workers = new UdonBehaviour[names.Length];
                b.images = new RawImage[names.Length];
                b.results = new Text[names.Length];
                Canvas panel = CreatePanel(go, new Vector2(4.1f, 2.8f));
                PanelText(panel, "Title", GridNames[kind], new Vector2(0f, 1.21f), new Vector2(3.8f, .17f), 92);
                b.status = PanelText(panel, "Status", side + " x " + side + " cells",
                    new Vector2(0f, 1.01f), new Vector2(3.8f, .15f), 57);
                for (int lane = 0; lane < names.Length; lane++)
                {
                    string name = names[lane];
                    var worker = new GameObject(name);
                    worker.transform.SetParent(go.transform, false);
                    if (lane < programs.Length)
                    {
                        b.workers[lane] = AddProgram(worker, programs[lane]);
                        b.workers[lane].SyncMethod = Networking.SyncType.None;
                    }
                    else b.workers[lane] = UdonSharpEditorUtility.GetBackingUdonBehaviour(
                        worker.AddUdonSharpComponent<UdonSharpGridKernels>());

                    float x = (lane - 1) * 1.31f;
                    PanelText(panel, name, name, new Vector2(x, .75f), new Vector2(1.28f, .16f), 73)
                        .alignment = TextAnchor.MiddleCenter;
                    b.images[lane] = PanelRect(panel, name + " output", new Vector2(x, -.04f), new Vector2(1.24f, 1.24f))
                        .gameObject.AddComponent<RawImage>();
                    b.images[lane].raycastTarget = false;
                    b.results[lane] = PanelText(panel, name + " time", "Ready", new Vector2(x, -.86f), new Vector2(1.30f, .20f), 62);
                    b.results[lane].alignment = TextAnchor.MiddleCenter;
                }
                var udon = UdonSharpEditorUtility.GetBackingUdonBehaviour(b);
                UdonSharpEditorUtility.CopyProxyToUdon(b);
                Canvas controls = CreateControls(go.transform, -1.21f, 3.8f);
                AddControl(controls, "Visualize", 0, 3, udon, nameof(WasdonGridBenchmark.Visualize));
                AddControl(controls, "Benchmark", 1, 3, udon, nameof(WasdonGridBenchmark.Benchmark));
                AddControl(controls, "Reset", 2, 3, udon, nameof(WasdonGridBenchmark.ResetBenchmark));
            }
            return root;
        }

        // Bake independent answers once when the scene is created. Only the
        // panel receives the reference. Every worker receives a fresh input copy.
        private static void MakeGridReference(int kind, int side, out byte[] input, out byte[] expected)
        {
            int count = side * side;
            input = new byte[count];
            expected = new byte[count];
            if (kind == 1)
            {
                input[0] = 255; // one is composite-marked throughout
                expected[0] = 255;
                for (int i = 1; i < count; i++)
                {
                    int n = 2 * i + 1;
                    for (int d = 3; d * d <= n; d += 2)
                        if (n % d == 0) { expected[i] = 255; break; }
                }
                return;
            }

            for (int i = 0; i < count; i++) input[i] = 255;
            if (kind == 2)
            {
                var sites = new Vector2Int[24];
                int seed = 127;
                for (int i = 0; i < sites.Length; i++)
                {
                    seed = (seed * 25173 + 13849) & 65535;
                    int x = (seed * side) >> 16;
                    seed = (seed * 25173 + 13849) & 65535;
                    int y = (seed * side) >> 16;
                    sites[i] = new Vector2Int(x, y);
                    input[y * side + x] = 0;
                }
                for (int i = 0; i < count; i++)
                {
                    int distance = 255, x = i % side, y = i / side;
                    foreach (var site in sites)
                        distance = Math.Min(distance, Math.Abs(x - site.x) + Math.Abs(y - site.y));
                    expected[i] = (byte)distance;
                }
                return;
            }

            double scale = 3.0 / side;
            for (int i = 0; i < count; i++)
            {
                double re = (i % side + 0.5) * scale - 1.5;
                double im = (i / side + 0.5) * scale - 1.5;
                byte n = 0;
                while (n < 64 && re * re + im * im <= 4.0)
                {
                    double next = re * re - im * im - 0.75;
                    im = 2.0 * re * im + 0.125;
                    re = next;
                    n++;
                }
                expected[i] = n;
            }
        }

        private static int[] GridPreview(int kind, int side)
        {
            int width = Math.Min(WasdonGridBenchmark.PreviewSide, side);
            var indices = new int[width * width];
            for (int i = 0; i < indices.Length; i++)
            {
                int x = i % width, y = i / width;
                if (kind != 1)
                {
                    indices[i] = (y * (side - 1) / (width - 1)) * side + x * (side - 1) / (width - 1);
                    continue;
                }
                // Arrange the odd candidates in a square spiral. Sample the
                // largest complete odd-sided square that fits in the output.
                int radius = (side - 1) / 2;
                x = x * 2 * radius / (width - 1) - radius;
                y = y * 2 * radius / (width - 1) - radius;
                int r = Math.Max(Math.Abs(x), Math.Abs(y));
                int last = (2 * r + 1) * (2 * r + 1) - 1;
                int back = y == -r ? r - x : x == -r ? 3 * r + y : y == r ? 5 * r + x : 7 * r - y;
                indices[i] = last - back;
            }
            return indices;
        }

        private static Color32[] GridPalette(int kind, int side)
        {
            var palette = new Color32[256];
            Color32 dark = new Color32(17, 27, 39, 255);
            for (int value = 0; value < 256; value++)
            {
                if (kind == 1) palette[value] = value == 0 ? new Color32(245, 201, 98, 255) : dark;
                else if (value == 255 || (kind == 0 && value == 64)) palette[value] = dark;
                else if (kind == 2 && value == 0) palette[value] = Color.white;
                else
                {
                    float t = kind == 0 ? Mathf.Sqrt(value / 64f) : Mathf.Min(1f, value * 4f / side);
                    palette[value] = Color.HSVToRGB(.62f * (1f - t), .83f, .36f + .64f * t);
                }
            }
            return palette;
        }
    }
}
