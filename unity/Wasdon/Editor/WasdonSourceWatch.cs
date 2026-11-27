using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;
using VRC.SDKBase.Editor.BuildPipeline;
using VRC.Udon;

namespace Wasdon
{
    [InitializeOnLoad]
    internal static class WasdonSourceWatch
    {
        private static readonly Dictionary<string, Dictionary<string, long>> Inputs = new Dictionary<string, Dictionary<string, long>>();
        private static double nextPoll;
        static WasdonSourceWatch()
        {
            EditorApplication.update += Poll;
            EditorApplication.delayCall += Restore;
        }

        private static long Stamp(string file) => File.Exists(file) ? File.GetLastWriteTimeUtc(file).Ticks : -1;
        internal static void Track(string asset, IEnumerable<string> paths)
        {
            Inputs[asset] = paths.Distinct().ToDictionary(p => Path.GetFullPath(p), Stamp);
        }
        private static void Restore()
        {
            foreach (string guid in AssetDatabase.FindAssets("t:WasdonProgramAsset"))
            {
                string path = AssetDatabase.GUIDToAssetPath(guid);
                var asset = AssetDatabase.LoadAssetAtPath<WasdonProgramAsset>(path);
                if (asset != null && asset.HasProject) asset.RefreshProgram();
            }
        }
        internal static bool Changed(WasdonProgramAsset asset, IEnumerable<string> changes)
        {
            string manifest = asset.ProjectPath;
            if (string.IsNullOrEmpty(manifest)) return true;
            string folder = Path.GetDirectoryName(manifest).Replace('\\', '/') + "/";
            string assetPath = AssetDatabase.GetAssetPath(asset);
            Inputs.TryGetValue(assetPath, out var deps);
            return changes.Any(p => p != assetPath && (
                p.StartsWith(folder, StringComparison.Ordinal) ||
                p.EndsWith("wasdon.lock.json", StringComparison.Ordinal) ||
                (deps != null && deps.ContainsKey(Path.GetFullPath(p)))));
        }
        private static void Poll()
        {
            if (EditorApplication.isPlayingOrWillChangePlaymode || EditorApplication.isCompiling ||
                EditorApplication.isUpdating || EditorApplication.timeSinceStartup < nextPoll) return;
            nextPoll = EditorApplication.timeSinceStartup + 1;
            foreach (var pair in Inputs.ToArray())
            {
                var changed = pair.Value.Where(input => Stamp(input.Key) != input.Value).Select(input => input.Key).ToArray();
                if (changed.Length == 0) continue;
                foreach (string file in changed) pair.Value[file] = Stamp(file);
                var asset = AssetDatabase.LoadAssetAtPath<WasdonProgramAsset>(pair.Key);
                if (asset != null && asset.HasProject) asset.RefreshProgram();
                else Inputs.Remove(pair.Key);
            }
        }
    }

    public sealed class WasdonWorldBuildCheck : IVRCSDKBuildRequestedCallback
    {
        public int callbackOrder => -100;
        public bool OnBuildRequested(VRCSDKRequestedBuildType type)
        {
            if (type != VRCSDKRequestedBuildType.Scene) return true;
            var assets = Resources.FindObjectsOfTypeAll<UdonBehaviour>()
                .Where(b => b.gameObject.scene.IsValid() && !EditorUtility.IsPersistent(b))
                .Select(b => b.programSource).OfType<WasdonProgramAsset>().Where(a => a.HasProject).Distinct();
            foreach (var asset in assets)
            {
                asset.RefreshProgram();
                if (!asset.BuildSucceeded) return false;
            }
            return true;
        }
    }
}
