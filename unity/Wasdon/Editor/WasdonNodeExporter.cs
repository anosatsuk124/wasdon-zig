using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEditor;
using PackageInfo = UnityEditor.PackageManager.PackageInfo;
using VRC.Udon.Editor;

namespace Wasdon
{
    public static class WasdonNodeExporter
    {
        [MenuItem("Tools/Wasdon/Export SDK Node Definitions")]
        public static void Export()
        {
            var path = Environment.GetEnvironmentVariable("WASDON_NODE_OUTPUT") ??
                EditorUtility.SaveFilePanel("Export Worlds SDK node definitions", "", "udon_nodes", "txt");
            if (string.IsNullOrEmpty(path)) return;
            var package = PackageInfo.FindForAssetPath("Packages/com.vrchat.worlds/package.json");
            var rows = new SortedDictionary<string, string>(StringComparer.Ordinal);
            foreach (var node in UdonEditorManager.Instance.GetNodeDefinitions())
            {
                var ports = node.parameters.Select(p => string.Join(":", p.parameterType.ToString().ToLowerInvariant(),
                    p.name, TypeName(p.type)));
                var row = string.Join("\t", new[] { node.fullName }.Concat(ports));
                if (rows.TryGetValue(node.fullName, out var previous) && row != previous)
                    throw new InvalidDataException("Conflicting SDK definitions for " + node.fullName);
                rows[node.fullName] = row;
            }
            using (var writer = new StreamWriter(path, false, new UTF8Encoding(false)) { NewLine = "\n" })
            {
                writer.WriteLine("# wasdon-nodes-v1\t" + package.version);
                foreach (var row in rows.Values) writer.WriteLine(row);
            }
        }

        private static string TypeName(Type t)
        {
            if (t == null) return "";
            if (t.IsArray) return TypeName(t.GetElementType()) + "Array";
            if (t.IsByRef) return TypeName(t.GetElementType()) + "Ref";
            if (t.IsGenericParameter) return t.Name;
            var name = (t.IsGenericType ? t.GetGenericTypeDefinition().FullName : t.FullName) ?? t.Name;
            name = name.Split('`')[0].Replace(".", "").Replace("+", "");
            if (t.IsGenericType) name += string.Concat(t.GetGenericArguments().Select(TypeName));
            return name;
        }
    }
}
