using System;
using System.Globalization;
using System.Linq;
using UdonSharp;
using UdonSharp.Compiler;
using UdonSharpEditor;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.UI;

namespace Wasdon
{
    [InitializeOnLoad]
    public static class WasdonGridBenchmarkBatch
    {
        private const string Pending = "Wasdon.GridBenchmarkBatch";

        static WasdonGridBenchmarkBatch()
        {
            EditorApplication.playModeStateChanged += state =>
            {
                if (state != PlayModeStateChange.EnteredPlayMode || !SessionState.GetBool(Pending, false)) return;
                SessionState.EraseBool(Pending);
                EditorApplication.delayCall += Measure;
            };
        }

        public static void Run()
        {
            if (!Application.isBatchMode) throw new InvalidOperationException("Run from the Unity batch command line");
            var args = Environment.GetCommandLineArgs();
            int i = Array.IndexOf(args, "-wasdonGridSize");
            int side = i < 0 ? 256 : int.Parse(args[i + 1], CultureInfo.InvariantCulture);
            UdonSharpCompilerV1.CompileSync();
            if (UdonSharpProgramAsset.AnyUdonSharpScriptHasError()) throw new Exception("UdonSharp compilation failed");
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            WasdonExamples.CreateGridBenchmarks(side);
            SessionState.SetBool(Pending, true);
            EditorApplication.EnterPlaymode();
        }

        private static void Measure()
        {
            try
            {
                bool allFaster = true;
                var root = GameObject.Find("Grid Benchmarks");
                var panels = root.GetComponentsInChildren<WasdonGridBenchmark>();
                if (panels.Length != 3) throw new Exception("Missing benchmark panels");
                foreach (var panel in panels)
                {
                    int lanes = panel.workers.Length;
                    if (lanes != 3) throw new Exception("Expected Zig, Rust and UdonSharp workers");
                    foreach (var worker in panel.workers) worker.InitializeUdonContent();
                    var controller = UdonSharpEditorUtility.GetBackingUdonBehaviour(panel);
                    controller.InitializeUdonContent();
                    controller.RunProgram("_start");
                    Debug.Log("Starting " + panel.name + " at " + panel.side + " x " + panel.side);
                    panel.GetComponentsInChildren<Button>().Single(b => b.name == "Visualize").onClick.Invoke();
                    int bands = 2 * ((panel.side + 7) / 8);
                    int updatesPerTrial = panel.side > WasdonGridBenchmark.SingleEventSide ? bands : 1;
                    int maxUpdates = bands + lanes * (WasdonGridBenchmark.Samples + 1) * updatesPerTrial;
                    int reportedRound = 0;
                    for (int i = 0; i < maxUpdates; i++)
                    {
                        if (!(bool)controller.GetProgramVariable("animating") &&
                            !(bool)controller.GetProgramVariable("measuring")) break;
                        controller.RunProgram("_update");
                        if (updatesPerTrial > 1)
                        {
                            int round = (int)controller.GetProgramVariable("trial") / lanes - 1;
                            if (round >= reportedRound + 3)
                            {
                                reportedRound = round;
                                Debug.Log(panel.name + " completed " + round + " measured rounds");
                            }
                        }
                        if (i == 0)
                        {
                            for (int lane = 0; lane < lanes; lane++)
                            {
                                var worker = panel.workers[lane];
                                worker.RunProgram("Read");
                                var pixels = (byte[])worker.GetProgramVariable("data");
                                var live = panel.previewIndices.Select(index => panel.palette[pixels[index]]);
                                if (!((Texture2D)panel.images[lane].texture).GetPixels32().SequenceEqual(live))
                                    throw new Exception(panel.name + " first texture differs from its worker");
                            }
                        }
                    }
                    if (!(bool)controller.GetProgramVariable("complete"))
                        throw new Exception(panel.name + " failed. " + panel.status.text);
                    var reference = panel.previewIndices.Select(index => panel.palette[panel.expected[index]]).ToArray();
                    foreach (var image in panel.images)
                        if (!((Texture2D)image.texture).GetPixels32().SequenceEqual(reference))
                            throw new Exception(panel.name + " final texture differs from the reference");

                    var samples = (double[])controller.GetProgramVariable("samples");
                    double[] medians = new double[lanes];
                    for (int lane = 0; lane < lanes; lane++)
                    {
                        var values = samples.Skip(lane * WasdonGridBenchmark.Samples).Take(WasdonGridBenchmark.Samples).ToArray();
                        if (values.Any(ms => !(ms > 0) || double.IsInfinity(ms))) throw new Exception("Invalid clock sample");
                        string times = string.Join(",", values.Select(ms => ms.ToString("F3", CultureInfo.InvariantCulture)));
                        Array.Sort(values);
                        medians[lane] = values[values.Length / 2];
                        Debug.Log("WASDON_GRID " + panel.name + " " + panel.side + " " + panel.workers[lane].name +
                            " samples_ms=" + times + " median_ms=" + medians[lane].ToString("F3", CultureInfo.InvariantCulture));
                    }
                    for (int lane = 0; lane < lanes - 1; lane++) allFaster &= medians[lane] < medians[lanes - 1];
                }
                bool requireFaster = Array.IndexOf(Environment.GetCommandLineArgs(), "-wasdonRequireFaster") >= 0;
                EditorApplication.Exit(requireFaster && !allFaster ? 2 : 0);
            }
            catch (Exception e)
            {
                Debug.LogException(e);
                EditorApplication.Exit(1);
            }
        }
    }
}
