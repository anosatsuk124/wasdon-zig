using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.PackageManager;
using UnityEngine;

namespace Wasdon
{
    internal static class WasdonProjectSkill
    {
        private const string Name = "wasdon-worlds";
        private const string Stamp = "\n<!-- Wasdon managed copy ";

        [InitializeOnLoadMethod]
        private static void OnLoad()
        {
            Install();
            Events.registeredPackages += changes =>
            {
                if (changes.added.Concat(changes.changedTo).Any(p => p.name == WasdonSdk.Package)) Install();
            };
        }

        // A stamp on the copy lets an upgrade distinguish an older bundled
        // skill from one the project author has edited, even after a clone.
        private static string ManagedCopy(string body) => body + Stamp + Hash128.Compute(body) + " -->\n";
        private static string Read(string path) => File.ReadAllText(path).Replace("\r\n", "\n");

        private static void Install()
        {
            var project = Path.GetDirectoryName(Application.dataPath);
            var source = Path.Combine(project, "Packages", WasdonSdk.Package, "Skills~", Name, "SKILL.md");
            if (!File.Exists(source)) return;
            var dest = project;
            try
            {
                foreach (var part in new[] { ".agents", "skills", Name, "SKILL.md" })
                {
                    dest = Path.Combine(dest, part);
                    if ((Directory.Exists(dest) || File.Exists(dest)) &&
                        (File.GetAttributes(dest) & FileAttributes.ReparsePoint) != 0) return;
                }
                var next = ManagedCopy(Read(source));
                var current = File.Exists(dest) ? Read(dest) : null;
                if (current != null)
                {
                    if (current == next) return;
                    int stamp = current.LastIndexOf(Stamp, StringComparison.Ordinal);
                    if (stamp < 0 || current != ManagedCopy(current.Substring(0, stamp))) return;
                }
                var dir = Path.GetDirectoryName(dest);
                Directory.CreateDirectory(dir);
                var temp = Path.Combine(dir, Guid.NewGuid().ToString("N") + ".tmp");
                try
                {
                    File.WriteAllText(temp, next);
                    if (current == null) File.Move(temp, dest);
                    else if (Read(dest) == current) File.Replace(temp, dest, null);
                }
                finally { File.Delete(temp); }
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                Debug.LogWarning("Wasdon could not install the project skill at " + dest + "\n" + e.Message);
            }
        }
    }
}
