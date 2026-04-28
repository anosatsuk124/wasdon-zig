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
        string asm = BigHeapReflection.GetAsm(this);
        if (string.IsNullOrWhiteSpace(asm)) return;

        var factory = new BigHeapFactory { FactoryHeapSize = heapSize };
        var ei = new UdonEditorInterface(null, factory, null, null, null, null, null, null, null);
        IUdonProgram newProgram = ei.Assemble(asm);

        BigHeapReflection.SetProgram(this, newProgram);
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
internal static class BigHeapReflection
{
    static readonly FieldInfo _asmField =
        typeof(UdonAssemblyProgramAsset).GetField("udonAssembly", BindingFlags.NonPublic | BindingFlags.Instance);

    static readonly FieldInfo _programField =
        typeof(VRC.Udon.Editor.ProgramSources.UdonProgramAsset)
            .GetField("program", BindingFlags.NonPublic | BindingFlags.Instance);

    public static string GetAsm(BigHeapAssemblyProgramAsset asset)
        => _asmField != null ? (string)_asmField.GetValue(asset) : null;

    public static void SetAsm(BigHeapAssemblyProgramAsset asset, string value)
    {
        if (_asmField != null) _asmField.SetValue(asset, value);
    }

    public static IUdonProgram GetProgram(BigHeapAssemblyProgramAsset asset)
        => _programField != null ? (IUdonProgram)_programField.GetValue(asset) : null;

    public static void SetProgram(BigHeapAssemblyProgramAsset asset, IUdonProgram program)
    {
        if (_programField != null) _programField.SetValue(asset, program);
    }
}

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
        LoadUasmInto(asset);
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
        ReassembleAsset(asset);
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
        ShowHeapOf(asset);
    }

    public static void LoadUasmInto(BigHeapAssemblyProgramAsset asset)
    {
        string path = EditorUtility.OpenFilePanel("Select uasm File", "", "txt,uasm,asm");
        if (string.IsNullOrEmpty(path)) return;

        string content = System.IO.File.ReadAllText(path);
        BigHeapReflection.SetAsm(asset, content);
        EditorUtility.SetDirty(asset);
        AssetDatabase.SaveAssets();
        Debug.Log($"[BigHeap] Loaded {content.Length} chars into {asset.name}");
    }

    public static void ReassembleAsset(BigHeapAssemblyProgramAsset asset)
    {
        asset.RefreshProgram();
        EditorUtility.SetDirty(asset);
        AssetDatabase.SaveAssets();
    }

    public static void ShowHeapOf(BigHeapAssemblyProgramAsset asset)
    {
        var serialized = asset.SerializedProgramAsset;
        if (serialized == null) { Debug.Log("[BigHeap] No serialized program."); return; }
        var program = serialized.RetrieveProgram();
        if (program == null) { Debug.Log("[BigHeap] RetrieveProgram returned null."); return; }
        Debug.Log($"[BigHeap] Heap capacity: {program.Heap.GetHeapCapacity()}   (heapSize setting: {asset.heapSize})");
    }
}

[CustomEditor(typeof(BigHeapAssemblyProgramAsset))]
public class BigHeapAssemblyProgramAssetEditor : Editor
{
    SerializedProperty _heapSizeProp;
    string _lengthLabel = "";
    string _linesLabel = "";
    string _programLabel = "";

    void OnEnable()
    {
        _heapSizeProp = serializedObject.FindProperty("heapSize");
        RefreshCache();
    }

    void RefreshCache()
    {
        var asset = target as BigHeapAssemblyProgramAsset;
        if (asset == null) return;
        string asm = BigHeapReflection.GetAsm(asset) ?? "";
        int asmLength = asm.Length;
        int lineCount = CountLines(asm);
        bool hasProgram = BigHeapReflection.GetProgram(asset) != null;
        _lengthLabel  = $"{asmLength:N0} chars";
        _linesLabel   = $"{lineCount:N0} lines";
        _programLabel = hasProgram ? "cached" : "(none)";
    }

    public override void OnInspectorGUI()
    {
        var asset = (BigHeapAssemblyProgramAsset)target;

        serializedObject.Update();
        if (_heapSizeProp != null)
        {
            int current = _heapSizeProp.intValue;
            int next = EditorGUILayout.DelayedIntField("Heap Size", current);
            if (next != current)
            {
                if (next < 0) next = 0;
                _heapSizeProp.intValue = next;
            }
        }
        serializedObject.ApplyModifiedProperties();

        EditorGUILayout.LabelField("Assembly length",  _lengthLabel);
        EditorGUILayout.LabelField("Assembly lines",   _linesLabel);
        EditorGUILayout.LabelField("Compiled program", _programLabel);

        EditorGUILayout.Space();
        EditorGUILayout.HelpBox(
            "Big Heap inspector does not render the assembly text — large uasm sources crash Unity's TextCore. Use the buttons below.",
            MessageType.Info);

        if (GUILayout.Button("Load uasm File..."))
        {
            BigHeapMenus.LoadUasmInto(asset);
            RefreshCache();
        }
        if (GUILayout.Button("Force Reassemble"))
        {
            BigHeapMenus.ReassembleAsset(asset);
            RefreshCache();
        }
        if (GUILayout.Button("Show Current Heap Capacity"))
        {
            BigHeapMenus.ShowHeapOf(asset);
        }

        EditorGUILayout.Space();
        if (GUILayout.Button("Clear Assembly Text"))
        {
            bool ok = EditorUtility.DisplayDialog(
                "BigHeap",
                "Clear the stored uasm text? The compiled IUdonProgram (if any) is kept, but you will need to reload a uasm file before the next reassemble.",
                "Clear", "Cancel");
            if (ok)
            {
                Undo.RecordObject(asset, "Clear Assembly Text");
                BigHeapReflection.SetAsm(asset, "");
                EditorUtility.SetDirty(asset);
                AssetDatabase.SaveAssets();
                RefreshCache();
            }
        }
    }

    static int CountLines(string s)
    {
        if (string.IsNullOrEmpty(s)) return 0;
        int n = 1;
        for (int i = 0; i < s.Length; i++) if (s[i] == '\n') n++;
        return n;
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
