using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using UnityEditor;
using UnityEngine;
using VRC.SDKBase;
using VRC.Udon;
using Object = UnityEngine.Object;

namespace Wasdon
{
    internal static class WasdonSdk
    {
        internal const string Package = "io.github.anosatsuk124.wasdon";
        internal static readonly string Root = Path.GetFullPath("Library/Wasdon");
        internal static bool Windows => Application.platform == RuntimePlatform.WindowsEditor;
        internal static string Executable
        {
            get
            {
                var configured = Environment.GetEnvironmentVariable("WASDON_CLI") ?? EditorPrefs.GetString("Wasdon.Cli");
                if (!string.IsNullOrEmpty(configured)) return configured;
                var cached = Path.Combine(Root, "SDK", "bin", Windows ? "wasdon.exe" : "wasdon");
                return File.Exists(cached) ? cached : "wasdon";
            }
        }

        // ProcessStartInfo.ArgumentList is unavailable in Unity's .NET profile.
        private static string Quote(string arg)
        {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in arg)
            {
                if (c == '\\') { slashes++; continue; }
                result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
                result.Append(c);
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }

        internal static string ProcessOutput(string exe, params string[] args)
        {
            var settings = new ProcessStartInfo(exe, string.Join(" ", args.Select(Quote))) {
                WorkingDirectory = Path.GetFullPath("."), UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            using (var process = Process.Start(settings))
            {
                var output = process.StandardOutput.ReadToEndAsync();
                var error = process.StandardError.ReadToEndAsync();
                process.WaitForExit();
                if (process.ExitCode != 0) throw new InvalidOperationException(error.Result.Trim() + "\n" + output.Result.Trim());
                return output.Result;
            }
        }
        internal static string Run(params string[] args) => ProcessOutput(Executable, args);

        [Serializable] internal class Language { public string id, displayName; }
        [Serializable] internal class LanguageList { public Language[] languages; }
        [Serializable] internal class BuildResult { public string wasm, assembly, metadata; public string[] dependencies; }
        [Serializable] internal class Metadata { public Behaviour behaviour; }
        [Serializable] internal class Behaviour { public string syncMode; }

        internal static BuildResult Build(TextAsset project, string assetPath)
        {
            string manifest = AssetDatabase.GetAssetPath(project);
            if (string.IsNullOrEmpty(manifest) || !File.Exists(manifest))
                throw new FileNotFoundException("Wasdon project source is missing for " + assetPath);
            string output = Path.Combine(Root, AssetDatabase.AssetPathToGUID(assetPath));
            var result = JsonUtility.FromJson<BuildResult>(Run("build", Path.GetFullPath(manifest), "--output", output, "--json"));
            WasdonSourceWatch.Track(assetPath, result.dependencies);
            return result;
        }
    }

    public sealed class WasdonSetup : EditorWindow
    {
        private WasdonSdk.Language[] languages = Array.Empty<WasdonSdk.Language>();
        private int selected;
        private string error, packSource, projectName = "WasdonWorld";
        [MenuItem("Tools/Wasdon/Setup")]
        public static void Open() => GetWindow<WasdonSetup>("Wasdon Setup");
        private void OnEnable() => RefreshLanguages();
        private void RefreshLanguages()
        {
            try {
                languages = JsonUtility.FromJson<WasdonSdk.LanguageList>(WasdonSdk.Run("language", "list", "--json")).languages;
                selected = Mathf.Clamp(selected, 0, Math.Max(0, languages.Length - 1));
                error = null;
            } catch (Exception e) { error = e.Message; }
        }
        private void OnGUI()
        {
            if (!string.IsNullOrEmpty(error)) EditorGUILayout.HelpBox(error, MessageType.Error);
            using (new EditorGUILayout.HorizontalScope())
            {
                if (GUILayout.Button("Install release CLI")) Attempt(Install);
                if (GUILayout.Button("Choose CLI…")) {
                    string cli = EditorUtility.OpenFilePanel("Wasdon executable", "", "");
                    if (!string.IsNullOrEmpty(cli)) { EditorPrefs.SetString("Wasdon.Cli", cli); RefreshLanguages(); }
                }
                if (GUILayout.Button("Refresh")) RefreshLanguages();
            }
            packSource = EditorGUILayout.TextField("Pack directory or ZIP URL", packSource);
            using (new EditorGUI.DisabledScope(string.IsNullOrWhiteSpace(packSource)))
                if (GUILayout.Button("Add language pack")) Attempt(() => { WasdonSdk.Run("language", "add", packSource); RefreshLanguages(); });
            if (languages.Length == 0) return;
            selected = EditorGUILayout.Popup("Language", selected, languages.Select(p => p.displayName).ToArray());
            projectName = EditorGUILayout.TextField("Project name", projectName);
            if (GUILayout.Button("Create world behaviour")) Attempt(() => Create(languages[selected].id, projectName));
        }
        private void Attempt(Action action)
        {
            try { error = null; action(); } catch (Exception e) { error = e.Message; }
        }
        private void Install()
        {
            InstallReleaseCli();
            EditorPrefs.DeleteKey("Wasdon.Cli");
            RefreshLanguages();
        }
        public static void InstallReleaseCli()
        {
            var package = UnityEditor.PackageManager.PackageInfo.FindForAssetPath("Packages/" + WasdonSdk.Package + "/package.json");
            if (package == null) throw new InvalidOperationException("Install the Wasdon VPM package to use the release installer.");
            string scripts = Path.Combine(package.resolvedPath, "Tools~");
            string dest = Path.Combine(WasdonSdk.Root, "SDK");
            if (WasdonSdk.Windows)
                WasdonSdk.ProcessOutput("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(scripts, "install.ps1"), "-Prefix", dest, "-Version", "v" + package.version);
            else
                WasdonSdk.ProcessOutput("/bin/sh", Path.Combine(scripts, "install.sh"), "--prefix", dest, "--version", "v" + package.version);
        }
        public static WasdonProgramAsset Create(string language, string name)
        {
            if (string.IsNullOrWhiteSpace(name) || name == "." || name == ".." || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || name.Contains("/") || name.Contains("\\"))
                throw new ArgumentException("Choose a project folder name.");
            string project = "Assets/" + name;
            WasdonSdk.Run("init", Path.GetFullPath(project), "--lang", language, "--registry", Path.GetFullPath("."));
            AssetDatabase.Refresh(ImportAssetOptions.ForceSynchronousImport);
            var asset = CreateInstance<WasdonProgramAsset>();
            asset.SetProject(AssetDatabase.LoadAssetAtPath<TextAsset>(project + "/wasdon.json"));
            AssetDatabase.CreateAsset(asset, project + "/Program.asset");
            asset.RefreshProgram();
            if (!asset.BuildSucceeded) throw new InvalidOperationException(asset.BuildError);
            var go = GameObject.CreatePrimitive(PrimitiveType.Cube);
            go.name = name;
            Undo.RegisterCreatedObjectUndo(go, "Create Wasdon behaviour");
            var udon = Undo.AddComponent<UdonBehaviour>(go);
            udon.programSource = asset;
            var serialized = new SerializedObject(udon);
            serialized.FindProperty("serializedProgramAsset").objectReferenceValue = asset.SerializedProgramAsset;
            serialized.ApplyModifiedPropertiesWithoutUndo();
            udon.SyncMethod = asset.SyncMode;
            var symbols = asset.SerializedProgramAsset.RetrieveProgram().SymbolTable;
            if (symbols.HasExportedSymbol("switchOn") && symbols.HasExportedSymbol("target") &&
                symbols.GetSymbolType("target") == typeof(GameObject))
            {
                var indicator = GameObject.CreatePrimitive(PrimitiveType.Sphere);
                indicator.name = "Switch indicator";
                indicator.transform.SetParent(go.transform, false);
                indicator.transform.localPosition = Vector3.up;
                indicator.transform.localScale = Vector3.one * 0.4f;
                Object.DestroyImmediate(indicator.GetComponent<Collider>());
                Undo.RegisterCreatedObjectUndo(indicator, "Create switch indicator");
                WasdonExamples.SetVariable(udon, "target", indicator);
            }
            EditorUtility.SetDirty(udon);
            AssetDatabase.SaveAssets();
            Selection.activeGameObject = go;
            return asset;
        }
    }
}
