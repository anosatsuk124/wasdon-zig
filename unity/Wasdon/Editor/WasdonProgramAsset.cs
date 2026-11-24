using System;
using System.Collections.Generic;
using System.Reflection;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;
using VRC.Udon;
using VRC.Udon.Common;
using VRC.Udon.Common.Interfaces;
using VRC.Udon.Editor;
using VRC.Udon.Editor.ProgramSources;
using VRC.Udon.Editor.ProgramSources.Attributes;
using VRC.Udon.EditorBindings;
using VRC.Udon.UAssembly.Assembler;
using VRC.Udon.UAssembly.Interfaces;
using Wasdon;

[assembly: UdonProgramSourceNewMenu(typeof(WasdonProgramAsset), "Wasdon Assembly Program Asset")]

namespace Wasdon
{
    /// <summary>
    /// Udon Assembly program source for wasdon-zig output.
    ///
    /// The stock Udon Assembly Program Asset assembles into a 512-slot heap,
    /// whatever the program needs, and fails with "Address: '512' is larger
    /// than the UdonVM's heap size of '512'." on anything bigger. This asset
    /// assembles with a heap sized from the assembly itself: the
    /// "# wasdon-zig heap-size: N" line the translator writes, or, for
    /// assembly from elsewhere, a count of its variables and distinct string
    /// literals (which is what the assembler allocates).
    ///
    /// The assembly can be embedded in the asset or kept in a text file
    /// (assemblySource). With a text file, re-running the translator and
    /// letting Unity reimport is all it takes to update the program.
    /// </summary>
    [CreateAssetMenu(menuName = "VRChat/Udon/Wasdon Assembly Program Asset", fileName = "New Wasdon Assembly Program Asset")]
    public class WasdonProgramAsset : UdonAssemblyProgramAsset
    {
        /// The heap the stock assembler uses; never go below it.
        private const uint DefaultHeapSize = 512;
        /// UdonHeap clamps its capacity to this.
        private const uint MaximumHeapSize = 1048576;

        [Tooltip("Text file holding the Udon Assembly (.uasm.txt). When set, it replaces the embedded assembly on every refresh.")]
        public TextAsset assemblySource;

        [SerializeField, HideInInspector]
        private uint heapSize;

        /// Heap slots the current assembly was given.
        public uint HeapSize => heapSize;

        protected override void RefreshProgramImpl()
        {
            if (assemblySource != null)
            {
                udonAssembly = assemblySource.text;
            }

            if (string.IsNullOrWhiteSpace(udonAssembly))
            {
                program = null;
                assemblyError = "No assembly. Assign an Assembly Source or load a .uasm file.";
                return;
            }

            try
            {
                uint required = RequiredHeapSize(udonAssembly);
                if (required > MaximumHeapSize)
                {
                    throw new InvalidOperationException(
                        $"The program needs {required} heap slots; the Udon VM supports at most {MaximumHeapSize}.");
                }

                heapSize = Math.Max(required, DefaultHeapSize);
                program = Assemble(udonAssembly, heapSize);
                assemblyError = null;
            }
            catch (Exception e)
            {
                program = null;
                assemblyError = e.InnerException != null ? $"{e.Message}\n{e.InnerException.Message}" : e.Message;
                Debug.LogException(e, this);
            }
        }

        /// <summary>
        /// Heap slots the assembler will allocate for this text: one per
        /// declared variable plus one per distinct string literal used as an
        /// instruction operand.
        /// </summary>
        public static uint RequiredHeapSize(string assembly)
        {
            Match declared = Regex.Match(assembly, @"#\s*wasdon-zig heap-size:\s*(\d+)");
            if (declared.Success && uint.TryParse(declared.Groups[1].Value, out uint n))
            {
                return n;
            }

            uint variables = 0;
            var literals = new HashSet<string>();
            bool inData = false;
            bool inCode = false;
            foreach (string rawLine in assembly.Split('\n'))
            {
                string line = rawLine.Trim();
                if (line.Length == 0 || line[0] == '#') continue;
                if (line.StartsWith(".data_start")) { inData = true; continue; }
                if (line.StartsWith(".data_end")) { inData = false; continue; }
                if (line.StartsWith(".code_start")) { inCode = true; continue; }
                if (line.StartsWith(".code_end")) { inCode = false; continue; }

                if (inData && line[0] != '.' && line.Contains(": %"))
                {
                    variables++;
                }
                else if (inCode)
                {
                    int open = line.IndexOf('"');
                    int close = line.LastIndexOf('"');
                    if (open >= 0 && close > open) literals.Add(line.Substring(open, close - open + 1));
                }
            }

            return variables + (uint)literals.Count;
        }

        private static readonly FieldInfo TypeResolverGroupField =
            typeof(UdonEditorInterface).GetField("_typeResolverGroup", BindingFlags.NonPublic | BindingFlags.Instance);

        /// Assemble with a heap of exactly `size` slots. The SDK's own entry
        /// point (UdonEditorManager.Assemble) offers no way to choose the
        /// size, so this builds an assembler around a custom heap factory,
        /// the way UdonSharp does.
        private static IUdonProgram Assemble(string assembly, uint size)
        {
            var editorInterface = new UdonEditorInterface();
            editorInterface.AddTypeResolver(new UdonBehaviourTypeResolver());
            var factory = new FixedHeapFactory(size);

            if (TypeResolverGroupField?.GetValue(editorInterface) is IUAssemblyTypeResolver resolver)
            {
                return new UAssemblyAssembler(factory, resolver).Assemble(assembly);
            }

            // Older or newer SDKs without that field: let the editor
            // interface build its own assembler around our factory.
            var custom = new UdonEditorInterface(null, factory, null, null, null, null, null, null, null);
            custom.AddTypeResolver(new UdonBehaviourTypeResolver());
            return custom.Assemble(assembly);
        }

        private sealed class FixedHeapFactory : IUdonHeapFactory
        {
            private readonly uint _size;

            public FixedHeapFactory(uint size)
            {
                _size = size;
            }

            public IUdonHeap ConstructUdonHeap()
            {
                return new UdonHeap(_size);
            }

            public IUdonHeap ConstructUdonHeap(uint heapSize)
            {
                return new UdonHeap(Math.Max(heapSize, _size));
            }
        }

        protected override void DrawProgramSourceGUI(UdonBehaviour udonBehaviour, ref bool dirty)
        {
            DrawAssemblyErrorTextArea();
            DrawPublicVariables(udonBehaviour, ref dirty);
            DrawAssemblyTextArea(!Application.isPlaying, ref dirty);
        }

        /// The stock inspector shows the assembly in an editable text area
        /// and a full disassembly below it. Translated programs run to
        /// megabytes of text, which makes that unusable, so this shows a
        /// summary and file operations instead.
        protected override void DrawAssemblyTextArea(bool allowEditing, ref bool dirty)
        {
            EditorGUILayout.LabelField("Wasdon Assembly", EditorStyles.boldLabel);

            using (new EditorGUI.DisabledScope(!allowEditing))
            {
                EditorGUI.BeginChangeCheck();
                var newSource = (TextAsset)EditorGUILayout.ObjectField("Assembly Source", assemblySource, typeof(TextAsset), false);
                if (EditorGUI.EndChangeCheck())
                {
                    Undo.RecordObject(this, "Change Assembly Source");
                    assemblySource = newSource;
                    dirty = true;
                    UdonEditorManager.Instance.QueueAndRefreshProgram(this);
                }
            }

            int length = udonAssembly?.Length ?? 0;
            EditorGUILayout.LabelField("Assembly size", $"{length:N0} characters");
            EditorGUILayout.LabelField("Heap size", heapSize == 0 ? "not assembled" : $"{heapSize:N0} slots");

            using (new EditorGUILayout.HorizontalScope())
            {
                using (new EditorGUI.DisabledScope(!allowEditing))
                {
                    if (GUILayout.Button("Load .uasm..."))
                    {
                        string path = EditorUtility.OpenFilePanel("Load Udon Assembly", "", "uasm,txt");
                        if (!string.IsNullOrEmpty(path))
                        {
                            Undo.RecordObject(this, "Load Assembly");
                            assemblySource = null;
                            udonAssembly = System.IO.File.ReadAllText(path);
                            dirty = true;
                            UdonEditorManager.Instance.QueueAndRefreshProgram(this);
                        }
                    }

                    if (GUILayout.Button("Reassemble"))
                    {
                        UdonEditorManager.Instance.QueueAndRefreshProgram(this);
                    }
                }

                if (GUILayout.Button("Copy Assembly"))
                {
                    EditorGUIUtility.systemCopyBuffer = udonAssembly;
                }
            }
        }
    }

    /// Reassembles a WasdonProgramAsset when it, or the text file it reads,
    /// is imported or changed.
    internal sealed class WasdonAssetPostprocessor : AssetPostprocessor
    {
        private static void OnPostprocessAllAssets(string[] imported, string[] deleted, string[] moved, string[] movedFrom)
        {
            if (imported.Length == 0) return;
            var changed = new HashSet<string>(imported);

            // Deferred: program sources cannot be refreshed in the middle of
            // an import.
            EditorApplication.delayCall += () =>
            {
                foreach (string guid in AssetDatabase.FindAssets("t:" + nameof(WasdonProgramAsset)))
                {
                    string path = AssetDatabase.GUIDToAssetPath(guid);
                    var asset = AssetDatabase.LoadAssetAtPath<WasdonProgramAsset>(path);
                    if (asset == null) continue;

                    string sourcePath = asset.assemblySource != null ? AssetDatabase.GetAssetPath(asset.assemblySource) : null;
                    if (changed.Contains(path) || (sourcePath != null && changed.Contains(sourcePath)))
                    {
                        UdonEditorManager.Instance.QueueAndRefreshProgram(asset);
                    }
                }
            };
        }
    }
}
