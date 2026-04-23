using System.Reflection;
using UnityEditor;
using UnityEngine;
using VRC.Udon.Common;
using VRC.Udon.Common.Interfaces;
using VRC.Udon.EditorBindings;

public class BigHeapFactory : IUdonHeapFactory
{
    public uint FactoryHeapSize { get; set; }
    public IUdonHeap ConstructUdonHeap()              => new UdonHeap(FactoryHeapSize);
    public IUdonHeap ConstructUdonHeap(uint heapSize) => new UdonHeap(FactoryHeapSize);
}

public class BigHeapWindow : EditorWindow
{
    UnityEngine.Object asset;
    uint heapSize = 4096;

    [MenuItem("Window/Big Heap Assembler")]
    static void Open() => GetWindow<BigHeapWindow>("Big Heap Assembler");

    void OnGUI()
    {
        asset = EditorGUILayout.ObjectField("Target (UdonAssemblyProgramAsset)", asset, typeof(UnityEngine.Object), false);
        heapSize = (uint)EditorGUILayout.IntField("Heap Size", (int)heapSize);

        if (asset == null) { GUI.enabled = false; }

        if (GUILayout.Button("Re-assemble"))
        {
            var assetType = asset.GetType();
            Debug.Log($"Asset type: {assetType.FullName}");

            // UdonAssemblyProgramAssetのprivate string udonAssembly
            var asmField = assetType.GetField("udonAssembly", BindingFlags.NonPublic | BindingFlags.Instance);
            if (asmField == null) { Debug.LogError("udonAssembly field not found. Is this really UdonAssemblyProgramAsset?"); return; }
            string asm = (string)asmField.GetValue(asset);

            var factory = new BigHeapFactory { FactoryHeapSize = heapSize };
            var ei = new VRC.Udon.EditorBindings.UdonEditorInterface(null, factory, null, null, null, null, null, null, null);
            var program = ei.Assemble(asm);

            // 親クラスUdonProgramAssetのprivate IUdonProgram program
            var progField = assetType.BaseType.GetField("program", BindingFlags.NonPublic | BindingFlags.Instance)
                         ?? assetType.GetField("program", BindingFlags.NonPublic | BindingFlags.Instance);
            if (progField == null) { Debug.LogError("program field not found."); return; }
            progField.SetValue(asset, program);

            EditorUtility.SetDirty(asset);
            AssetDatabase.SaveAssets();
            Debug.Log($"Re-assembled with heap size {heapSize}");
        }
    }
}
