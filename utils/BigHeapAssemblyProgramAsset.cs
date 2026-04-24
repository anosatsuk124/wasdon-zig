using System.Reflection;
using UnityEngine;
#if UNITY_EDITOR
using UnityEditor;
#endif
using VRC.Udon.Editor.ProgramSources;
using VRC.Udon.EditorBindings;
using VRC.Udon.Common;
using VRC.Udon.Common.Interfaces;

[CreateAssetMenu(menuName = "VRChat/Udon/Big Heap Assembly Program")]
public class BigHeapAssemblyProgramAsset : UdonAssemblyProgramAsset
{
    public uint heapSize = 4096;

#if UNITY_EDITOR
    protected override void RefreshProgramImpl()
    {
        var asmField = typeof(UdonAssemblyProgramAsset)
            .GetField("udonAssembly", BindingFlags.NonPublic | BindingFlags.Instance);
        string asm = (string)asmField.GetValue(this);
        if (string.IsNullOrWhiteSpace(asm)) return;

        var factory = new BigHeapFactory { FactoryHeapSize = heapSize };
        var ei = new UdonEditorInterface(null, factory, null, null, null, null, null, null, null);
        IUdonProgram newProgram = ei.Assemble(asm);

        var progField = typeof(UdonProgramAsset)
            .GetField("program", BindingFlags.NonPublic | BindingFlags.Instance);
        progField.SetValue(this, newProgram);

        Debug.Log($"[BigHeap] Reassembled with heap size {heapSize}");
    }
#endif
}

public class BigHeapFactory : IUdonHeapFactory
{
    public uint FactoryHeapSize { get; set; }
    public IUdonHeap ConstructUdonHeap()              => new UdonHeap(FactoryHeapSize);
    public IUdonHeap ConstructUdonHeap(uint heapSize) => new UdonHeap(FactoryHeapSize);
}

#if UNITY_EDITOR
public static class BigHeapMenus
{
    [MenuItem("Tools/BigHeap/1. Load uasm File into Selected Asset")]
    static void LoadUasm()
    {
        var asset = Selection.activeObject as BigHeapAssemblyProgramAsset;
        if (asset == null)
        {
            EditorUtility.DisplayDialog("BigHeap", "Projectで BigHeapAssemblyProgramAsset を選択してから実行してください。", "OK");
            return;
        }

        string path = EditorUtility.OpenFilePanel("Select uasm File", "", "txt,uasm,asm");
        if (string.IsNullOrEmpty(path)) return;

        string content = System.IO.File.ReadAllText(path);
        var asmField = typeof(UdonAssemblyProgramAsset)
            .GetField("udonAssembly", BindingFlags.NonPublic | BindingFlags.Instance);
        asmField.SetValue(asset, content);
        EditorUtility.SetDirty(asset);
        AssetDatabase.SaveAssets();
        Debug.Log($"[BigHeap] Loaded {content.Length} chars into {asset.name}");
    }

    [MenuItem("Tools/BigHeap/2. Set Heap Size on Selected Asset...")]
    static void SetHeapSize()
    {
        var asset = Selection.activeObject as BigHeapAssemblyProgramAsset;
        if (asset == null)
        {
            EditorUtility.DisplayDialog("BigHeap", "BigHeapAssemblyProgramAsset を選択してください。", "OK");
            return;
        }
        string input = EditorInputDialog.Show("Heap Size", $"Current: {asset.heapSize}\nNew size:", asset.heapSize.ToString());
        if (uint.TryParse(input, out uint size))
        {
            asset.heapSize = size;
            EditorUtility.SetDirty(asset);
            AssetDatabase.SaveAssets();
            Debug.Log($"[BigHeap] heapSize = {size}");
        }
    }

    [MenuItem("Tools/BigHeap/3. Force Reassemble Selected Asset")]
    static void Reassemble()
    {
        var asset = Selection.activeObject as BigHeapAssemblyProgramAsset;
        if (asset == null)
        {
            EditorUtility.DisplayDialog("BigHeap", "BigHeapAssemblyProgramAsset を選択してください。", "OK");
            return;
        }
        asset.RefreshProgram();
        EditorUtility.SetDirty(asset);
        AssetDatabase.SaveAssets();
    }

    [MenuItem("Tools/BigHeap/4. Show Current Heap Capacity")]
    static void ShowHeap()
    {
        var asset = Selection.activeObject as BigHeapAssemblyProgramAsset;
        if (asset == null)
        {
            EditorUtility.DisplayDialog("BigHeap", "BigHeapAssemblyProgramAsset を選択してください。", "OK");
            return;
        }
        var serialized = asset.SerializedProgramAsset;
        if (serialized == null) { Debug.Log("[BigHeap] No serialized program."); return; }
        var program = serialized.RetrieveProgram();
        if (program == null) { Debug.Log("[BigHeap] RetrieveProgram returned null."); return; }
        Debug.Log($"[BigHeap] Heap capacity: {program.Heap.GetHeapCapacity()}   (heapSize setting: {asset.heapSize})");
    }
}

public class EditorInputDialog : EditorWindow
{
    string _input;
    string _message;
    string _result;

    public static string Show(string title, string message, string defaultValue)
    {
        var window = CreateInstance<EditorInputDialog>();
        window.titleContent = new GUIContent(title);
        window._message = message;
        window._input = defaultValue;
        window.position = new Rect(Screen.currentResolution.width / 2 - 150, Screen.currentResolution.height / 2 - 50, 300, 100);
        window.ShowModal();
        return window._result;
    }

    void OnGUI()
    {
        EditorGUILayout.LabelField(_message, EditorStyles.wordWrappedLabel);
        _input = EditorGUILayout.TextField(_input);
        GUILayout.FlexibleSpace();
        using (new EditorGUILayout.HorizontalScope())
        {
            if (GUILayout.Button("Cancel")) { _result = null; Close(); }
            if (GUILayout.Button("OK")) { _result = _input; Close(); }
        }
    }
}
#endif