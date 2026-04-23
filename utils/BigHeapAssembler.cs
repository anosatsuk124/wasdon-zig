using System.Reflection;
using UnityEditor;
using UnityEngine;
using VRC.Udon;
using VRC.Udon.Common;
using VRC.Udon.Common.Interfaces;
using VRC.Udon.EditorBindings;

// UdonSharpのHeapFactoryと同じ実装
public class BigHeapFactory : IUdonHeapFactory
{
    public uint FactoryHeapSize { get; set; }
    public IUdonHeap ConstructUdonHeap()              => new UdonHeap(FactoryHeapSize);
    public IUdonHeap ConstructUdonHeap(uint heapSize) => new UdonHeap(FactoryHeapSize); // 引数は捨てる
}

public static class BigHeapAssembler
{
    [MenuItem("Assets/Udon/Re-assemble with Big Heap", true)]
    static bool Validate() => Selection.activeObject is UdonAssemblyProgramAsset;

    [MenuItem("Assets/Udon/Re-assemble with Big Heap")]
    static void Run()
    {
        var asset = (UdonAssemblyProgramAsset)Selection.activeObject;

        // アセンブリ文字列を取り出す
        var asmField = typeof(UdonAssemblyProgramAsset)
            .GetField("udonAssembly", BindingFlags.NonPublic | BindingFlags.Instance);
        string asm = (string)asmField.GetValue(asset);

        // 好きなサイズのfactoryを作って差し込む
        var factory = new BigHeapFactory { FactoryHeapSize = 4096 }; // 欲しいサイズ
        var ei = new UdonEditorInterface(null, factory, null, null, null, null, null, null, null);

        IUdonProgram program = ei.Assemble(asm);

        // UdonAssemblyProgramAssetのprivate `program` に差し込む
        var progField = typeof(UdonProgramAsset)
            .GetField("program", BindingFlags.NonPublic | BindingFlags.Instance);
        progField.SetValue(asset, program);

        EditorUtility.SetDirty(asset);
        AssetDatabase.SaveAssets();
        Debug.Log($"Re-assembled with heap size {factory.FactoryHeapSize}");
    }
}
