// Copy into Assets/Editor in a disposable Worlds 3.10.6 project. Invoke
// WasdonSdkSmoke.Run with -batchmode, WASDON_CLI and WASDON_PROBE_DIR set.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using VRC.SDKBase.Editor.BuildPipeline;
using VRC.Udon;
using Wasdon;

[InitializeOnLoad]
public static class WasdonSdkSmoke
{
    private const string State = "WasdonSdkSmoke";
    private static readonly string[] Languages = { "c", "zig", "rust" };
    private static string World(string lang) => lang + "World" + SessionState.GetString(State + ".run", "");
    private static string Text => "Assets/" + World("fourth") + "/message.txt";
    private static int stage;
    private static double deadline;

    static WasdonSdkSmoke()
    {
        EditorApplication.playModeStateChanged += s => {
            if (s == PlayModeStateChange.EnteredPlayMode && SessionState.GetBool(State, false))
                EditorApplication.delayCall += Play;
        };
    }
    public static void CheckVpmSkill()
    {
        const string source = "Packages/io.github.anosatsuk124.wasdon/Skills~/wasdon-worlds/SKILL.md";
        const string installed = ".agents/skills/wasdon-worlds/SKILL.md";
        var canonical = File.ReadAllText(source).Replace("\r\n", "\n");
        if (!File.ReadAllText(installed).Replace("\r\n", "\n").StartsWith(canonical, StringComparison.Ordinal))
            throw new Exception("The project skill differs from the VPM package");
    }

    public static void Run()
    {
        CheckVpmSkill();
        SessionState.SetString(State + ".run", Guid.NewGuid().ToString("N").Substring(0, 8));
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WASDON_RELEASE_BASE")))
            WasdonSetup.InstallReleaseCli();
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene);
        var legacy = AssetDatabase.LoadAssetAtPath<WasdonProgramAsset>(
            AssetDatabase.GUIDToAssetPath("82cf8c4563e98f187d0f2e0bb3463775"));
        if (legacy == null || legacy.assemblySource == null) throw new Exception("Legacy assembly reference is missing");
        legacy.RefreshProgram();
        if (!legacy.BuildSucceeded) throw new Exception(legacy.BuildError);
        foreach (var lang in Languages)
        {
            var a = WasdonSetup.Create(lang, World(lang));
            var go = Selection.activeGameObject;
            go.transform.position = new Vector3(2, 3, 4);
            var main = lang == "rust" ? "src/lib.rs" : "main." + lang;
            var path = "Assets/" + World(lang) + "/" + main;
            File.AppendAllText(path, File.ReadAllText(Path.Combine(Environment.GetEnvironmentVariable("WASDON_PROBE_DIR"), lang + ".txt")));
            AssetDatabase.ImportAsset(path);
            a.RefreshProgram();
            if (!a.BuildSucceeded) throw new Exception(a.BuildError);
        }
        WasdonSetup.Create("fourth", World("fourth"));
        GameObject.CreatePrimitive(PrimitiveType.Cube).transform.position = new Vector3(40, 0, 5);
        EditorSceneManager.SaveScene(SceneManager.GetActiveScene(), "Assets/WasdonSdkSmoke.unity");
        File.WriteAllBytes(Text, new byte[] { 0xff });
        AssetDatabase.ImportAsset(Text, ImportAssetOptions.ForceSynchronousImport);
        deadline = EditorApplication.timeSinceStartup + 120;
        EditorApplication.update += WaitForImport;
    }
    private static void WaitForImport()
    {
        try
        {
            var a = AssetDatabase.LoadAssetAtPath<WasdonProgramAsset>("Assets/" + World("fourth") + "/Program.asset");
            if (EditorApplication.timeSinceStartup > deadline) throw new Exception("Timed out waiting for source refresh, stage " + stage);
            if (stage == 0 && !a.BuildSucceeded)
            {
                if (new WasdonWorldBuildCheck().OnBuildRequested(VRCSDKRequestedBuildType.Scene))
                    throw new Exception("Build guard accepted stale assembly");
                stage++;
                File.WriteAllText(Text, "Fourth pack reloaded");
                AssetDatabase.ImportAsset(Text, ImportAssetOptions.ForceSynchronousImport);
            }
            else if (stage == 1 && a.BuildSucceeded)
            {
                EditorApplication.update -= WaitForImport;
                if (!new WasdonWorldBuildCheck().OnBuildRequested(VRCSDKRequestedBuildType.Scene))
                    throw new Exception("Repaired world failed build guard");
                AssetDatabase.SaveAssets();
                SessionState.SetBool(State, true);
                EditorApplication.EnterPlaymode();
            }
        }
        catch (Exception e) { Debug.LogException(e); EditorApplication.Exit(1); }
    }
    private static void Play()
    {
        try
        {
            SessionState.SetBool(State, false);
            var logs = new List<string>();
            Application.logMessageReceived += (line, trace, level) => logs.Add(line);
            Physics.SyncTransforms();
            foreach (var lang in Languages)
            {
                var b = GameObject.Find(World(lang)).GetComponent<UdonBehaviour>();
                b.InitializeUdonContent();
                logs.Clear();
                b.RunProgram("_start");
                var indicator = b.transform.Find("Switch indicator").gameObject;
                if (indicator.activeSelf) throw new Exception(lang + " starter did not initialize its target");
                b.SetProgramVariable("switchOn", true);
                b.RunProgram("_onDeserialization");
                if (!indicator.activeSelf) throw new Exception(lang + " starter did not apply synced state");
                b.RunProgram("Probe");
                foreach (var expected in new[] { "Hello from Wasdon", "string OK", "generic OK", "multiple out OK", "raycast OK" })
                    if (!logs.Any(l => l.Contains(expected))) throw new Exception(lang + " missing " + expected + "\n" + string.Join("\n", logs));
            }
            var fourth = GameObject.Find(World("fourth")).GetComponent<UdonBehaviour>();
            fourth.InitializeUdonContent();
            logs.Clear();
            fourth.RunProgram("_start");
            if (!logs.Any(l => l.Contains("Fourth pack reloaded"))) throw new Exception("Stale fourth-pack program");
            Debug.Log("WASDON SDK UNITY ACCEPTANCE PASSED");
            EditorApplication.Exit(0);
        }
        catch (Exception e) { Debug.LogException(e); EditorApplication.Exit(1); }
    }
}
