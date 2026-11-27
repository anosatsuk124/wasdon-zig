using System.IO;
using UdonSharp;
using UdonSharp.Compiler;
using UdonSharpEditor;
using UnityEditor;
using UnityEditor.Events;
using UnityEngine;
using UnityEngine.UI;
using VRC.SDK3.Components;
using VRC.SDKBase;
using VRC.Udon;
using VRC.Udon.Common;

namespace Wasdon
{
    /// <summary>
    /// Builds scene objects for the example programs in Wasdon/Examples:
    /// Tools > Wasdon > Create Example Objects.
    ///
    /// Creates the displays, controls and their Udon behaviours under a
    /// single root in the open scene.
    /// </summary>
    public static partial class WasdonExamples
    {
        private const float Spacing = 3f;

        [MenuItem("Tools/Wasdon/Create Example Objects")]
        private static void CreateAll()
        {
            var root = new GameObject("Wasdon Examples");
            Undo.RegisterCreatedObjectUndo(root, "Create Wasdon Examples");

            GameObject[] examples =
            {
                CreatePi(), CreateMandelbrot(), CreateImageCodec(), CreateRagdoll(), CreateBlockfall(),
            };
            for (int i = 0; i < examples.Length; i++)
            {
                examples[i].transform.SetParent(root.transform, false);
                examples[i].transform.localPosition = new Vector3(i * Spacing, 1.5f, 0f);
            }

            Selection.activeGameObject = root;

            if (!ExampleScriptsCompiled()) UdonSharpCompilerV1.CompileSync();
            if (!ExampleScriptsCompiled())
            {
                Debug.LogError("Wasdon: the example UdonSharp programs could not compile. See the UdonSharp compiler diagnostics.");
                return;
            }

            GameObject sort = CreateSortBenchmark();
            sort.transform.SetParent(root.transform, false);
            sort.transform.localPosition = new Vector3(20.5f, 1.5f, 0f);

            GameObject grids = CreateGridBenchmarks(256);
            grids.transform.SetParent(root.transform, false);
            grids.transform.localPosition = new Vector3(25f, 1.5f, 0f);

            GameObject linux = CreateLinuxBoot();
            linux.transform.SetParent(root.transform, false);
            linux.transform.localPosition = new Vector3(15.7f, 1.5f, 0f);
        }

        private static bool ExampleScriptsCompiled()
        {
            return IsCompiled(typeof(WasdonLinuxBoot)) &&
                IsCompiled(typeof(WasdonSortBenchmark)) &&
                IsCompiled(typeof(UdonSharpMergeSort)) &&
                IsCompiled(typeof(WasdonGridBenchmark)) &&
                IsCompiled(typeof(UdonSharpGridKernels));
        }

        private static bool IsCompiled(System.Type type)
        {
            UdonSharpProgramAsset asset = UdonSharpEditorUtility.GetUdonSharpProgramAsset(type);
            return asset != null && asset.CompiledVersion == UdonSharpProgramVersion.CurrentVersion;
        }

        // ------------------------------------------------------------------
        //  Examples
        // ------------------------------------------------------------------

        /// Digits of pi, a few more every frame, on a text panel.
        private static GameObject CreatePi()
        {
            var go = new GameObject("Pi");
            Text text = CreateText(go.transform, "Digits", Vector3.zero, new Vector2(2f, 2f), 40);
            UdonBehaviour udon = AddProgram(go, "pi");
            SetVariable(udon, "_display", text);
            SetVariable(udon, "_digits", 400);
            return go;
        }

        /// The Mandelbrot set on a quad; interact to zoom.
        private static GameObject CreateMandelbrot()
        {
            MeshRenderer screen = CreateScreen("Mandelbrot", new Vector2(2f, 2f));
            UdonBehaviour udon = AddProgram(screen.gameObject, "mandelbrot");
            udon.InteractionText = "Zoom";
            SetVariable<Renderer>(udon, "_renderer", screen);
            SetVariable(udon, "_rowsPerFrame", 2);
            return screen.gameObject;
        }

        /// QOI pictures decoded onto a quad; interact for the next one.
        private static GameObject CreateImageCodec()
        {
            MeshRenderer screen = CreateScreen("Image Codec", new Vector2(2f, 2f));
            UdonBehaviour udon = AddProgram(screen.gameObject, "image-codec");
            udon.InteractionText = "Next picture";
            SetVariable<Renderer>(udon, "_renderer", screen);
            SetVariable(udon, "_pixelsPerFrame", 96);
            return screen.gameObject;
        }

        /// A stick-figure humanoid: sixteen joint markers and a line through
        /// them. Interact to knock it over.
        private static GameObject CreateRagdoll()
        {
            var go = new GameObject("Ragdoll");
            // The program works in metres with y up and the ground at y = 0,
            // in the local space of these two children.
            var ground = new GameObject("Ground");
            ground.transform.SetParent(go.transform, false);
            ground.transform.localPosition = new Vector3(0f, -1.5f, 0f);

            var joints = new GameObject("Joints");
            joints.transform.SetParent(ground.transform, false);
            for (int i = 0; i < 16; i++)
            {
                GameObject marker = GameObject.CreatePrimitive(PrimitiveType.Sphere);
                marker.name = "Joint " + i;
                Object.DestroyImmediate(marker.GetComponent<Collider>());
                marker.transform.SetParent(joints.transform, false);
                marker.transform.localScale = Vector3.one * (i == 0 ? 0.22f : 0.09f);
            }

            var skeleton = new GameObject("Skeleton", typeof(LineRenderer));
            skeleton.transform.SetParent(ground.transform, false);
            var line = skeleton.GetComponent<LineRenderer>();
            line.useWorldSpace = false;
            line.widthMultiplier = 0.04f;
            line.sharedMaterial = new Material(Shader.Find("Sprites/Default"));

            // Something to click on: a box around where it wanders.
            var box = go.AddComponent<BoxCollider>();
            box.center = new Vector3(0f, -0.6f, 0f);
            box.size = new Vector3(5f, 1.8f, 5f);
            box.isTrigger = true;

            UdonBehaviour udon = AddProgram(go, "ragdoll");
            udon.InteractionText = "Push";
            SetVariable(udon, "_joints", joints.transform);
            SetVariable(udon, "_line", line);
            SetVariable(udon, "_iterations", 3);
            SetVariable(udon, "_seed", 1);
            return go;
        }

        /// Blockfall: the well on a quad, the score above it, and five
        /// buttons below that send the game's custom events. The game is
        /// synced, so everyone in the instance sees and can play it.
        private static GameObject CreateBlockfall()
        {
            // The picture is 10 x 12 cells.
            MeshRenderer screen = CreateScreen("Blockfall", new Vector2(1.5f, 1.8f));
            GameObject go = screen.gameObject;
            Object.DestroyImmediate(go.GetComponent<Collider>());

            Text score = CreateText(go.transform, "Score", new Vector3(0f, 0.62f, 0f), new Vector2(1.5f, 0.2f), 60);
            score.alignment = TextAnchor.MiddleCenter;

            UdonBehaviour udon = AddProgram(go, "blockfall");
            udon.SyncMethod = Networking.SyncType.Manual;
            SetVariable<Renderer>(udon, "_renderer", screen);
            SetVariable(udon, "_scoreText", score);
            SetVariable(udon, "_seed", 1);

            Canvas controls = CreateCanvas(go.transform, "Controls", new Vector3(0f, -0.62f, 0f), new Vector2(1.5f, 0.2f));
            controls.gameObject.AddComponent<GraphicRaycaster>();
            controls.gameObject.AddComponent<VRCUiShape>();
            string[] events = { "MoveLeft", "Rotate", "Drop", "MoveRight", "Restart" };
            string[] labels = { "<", "Turn", "Drop", ">", "New" };
            for (int i = 0; i < events.Length; i++)
            {
                Button button = CreateButton(controls.transform, labels[i], i, events.Length);
                UnityEventTools.AddStringPersistentListener(button.onClick, udon.SendCustomEvent, events[i]);
            }

            return go;
        }

        private static GameObject CreateLinuxBoot()
        {
            var go = new GameObject("Linux Boot");
            var size = new Vector2(4.15f, 2.35f);
            Canvas panel = CreatePanel(go, size);
            PanelText(panel, "Title", "Linux boot console", new Vector2(0f, 1.01f), new Vector2(3.85f, 0.16f), 78);
            Text status = PanelText(panel, "Status", "READY  /  Linux WASM on Udon",
                new Vector2(0f, 0.84f), new Vector2(3.85f, 0.12f), 48);
            status.color = new Color(0.62f, 0.72f, 0.76f);
            Text console = PanelText(panel, "Console output", "", new Vector2(0f, -0.06f), new Vector2(3.85f, 1.60f), 49);
            console.alignment = TextAnchor.UpperLeft;
            console.color = new Color(0.55f, 0.94f, 0.74f);
            console.verticalOverflow = VerticalWrapMode.Truncate;

            var boot = go.AddUdonSharpComponent<WasdonLinuxBoot>();
            boot.status = status;
            boot.console = console;
            WasdonProgramAsset asset = FindProgram("linux-boot");
            if (asset != null)
            {
                var kernel = new GameObject("Linux kernel");
                kernel.transform.SetParent(go.transform, false);
                boot.kernel = AddProgram(kernel, asset);
                boot.kernel.SyncMethod = Networking.SyncType.None;
            }
            else
            {
                status.text = "KERNEL ASSET REQUIRED";
                console.text = "Generate linux-boot with zig build unity -Dlinux=/path/to/vmlinux.wasm, then re-create this example.";
            }

            UdonSharpEditorUtility.CopyProxyToUdon(boot);
            Canvas controls = CreateControls(go.transform, -1.02f, size.x - 0.25f);
            AddControl(controls, "Start", 0, 2, UdonSharpEditorUtility.GetBackingUdonBehaviour(boot), nameof(WasdonLinuxBoot.ClickStart)).interactable = asset != null;
            AddControl(controls, "Reload", 1, 2, UdonSharpEditorUtility.GetBackingUdonBehaviour(boot), nameof(WasdonLinuxBoot.ClickReload)).interactable = asset != null;
            return go;
        }

        private static GameObject CreateSortBenchmark()
        {
            var go = new GameObject("Sort Benchmark");
            var size = new Vector2(4.8f, 2.35f);
            Canvas panel = CreatePanel(go, size);
            PanelText(panel, "Title", "Sorting benchmark", new Vector2(0f, 1.01f), new Vector2(4.52f, 0.16f), 78);

            var benchmark = go.AddUdonSharpComponent<WasdonSortBenchmark>();
            int lanes = WasdonSortBenchmark.Lanes;
            int barCount = WasdonSortBenchmark.BarsPerLane;
            benchmark.sorters = new UdonBehaviour[lanes];
            benchmark.bars = new RectTransform[lanes * barCount];
            benchmark.results = new Text[lanes];
            benchmark.status = PanelText(panel, "Status", "Stable bottom-up merge sort",
                new Vector2(0f, 0.84f), new Vector2(4.52f, 0.12f), 48);
            benchmark.status.color = new Color(0.62f, 0.72f, 0.76f);

            string[] names = { "Rust", "Zig", "UdonSharp" };
            string[] programs = { "sort-bench-rs", "sort-bench-zig" };
            Color[] colors =
            {
                new Color(0.98f, 0.51f, 0.40f), new Color(0.98f, 0.72f, 0.29f), new Color(0.37f, 0.79f, 0.93f),
            };
            bool ready = true;
            for (int lane = 0; lane < lanes; lane++)
            {
                var worker = new GameObject(names[lane]);
                worker.transform.SetParent(go.transform, false);
                if (lane < programs.Length)
                {
                    WasdonProgramAsset asset = FindProgram(programs[lane]);
                    if (asset == null)
                    {
                        ready = false;
                    }
                    else
                    {
                        benchmark.sorters[lane] = AddProgram(worker, asset);
                        benchmark.sorters[lane].SyncMethod = Networking.SyncType.None;
                    }
                }
                else
                {
                    var sorter = worker.AddUdonSharpComponent<UdonSharpMergeSort>();
                    benchmark.sorters[lane] = UdonSharpEditorUtility.GetBackingUdonBehaviour(sorter);
                }

                float x = (lane - 1) * 1.53f;
                Text label = PanelText(panel, "Language", names[lane],
                    new Vector2(x, 0.58f), new Vector2(1.43f, 0.15f), 62);
                label.color = colors[lane];
                label.alignment = TextAnchor.MiddleCenter;
                RectTransform chart = PanelRect(panel, names[lane] + " chart", new Vector2(x, -0.005f), new Vector2(1.43f, 0.92f));
                var plot = chart.gameObject.AddComponent<Image>();
                plot.color = new Color(0.10f, 0.14f, 0.17f);
                plot.raycastTarget = false;
                for (int i = 0; i < barCount; i++)
                {
                    var bar = new GameObject("Bar " + i, typeof(Image));
                    bar.transform.SetParent(chart, false);
                    Image fill = bar.GetComponent<Image>();
                    fill.color = colors[lane];
                    fill.raycastTarget = false;
                    RectTransform rect = fill.rectTransform;
                    rect.pivot = new Vector2(0.5f, 0f);
                    rect.anchorMin = new Vector2((float)i / barCount, 0f);
                    rect.anchorMax = new Vector2((float)(i + 1) / barCount, 1f);
                    rect.offsetMin = new Vector2(3f, 0f);
                    rect.offsetMax = new Vector2(-3f, -12f);
                    benchmark.bars[lane * barCount + i] = rect;
                }
                benchmark.results[lane] = PanelText(panel, "Result", "",
                    new Vector2(x, -0.64f), new Vector2(1.44f, 0.22f), 55);
                benchmark.results[lane].alignment = TextAnchor.MiddleCenter;
            }

            UdonBehaviour udon = UdonSharpEditorUtility.GetBackingUdonBehaviour(benchmark);
            if (!ready)
            {
                benchmark.enabled = false;
                udon.enabled = false;
                benchmark.status.text = "SORT PROGRAM ASSETS REQUIRED";
            }
            UdonSharpEditorUtility.CopyProxyToUdon(benchmark);
            Canvas controls = CreateControls(go.transform, -1.02f, size.x - 0.25f);
            AddControl(controls, "Visualize", 0, 3, udon, nameof(WasdonSortBenchmark.Visualize)).interactable = ready;
            AddControl(controls, "Benchmark", 1, 3, udon, nameof(WasdonSortBenchmark.Benchmark)).interactable = ready;
            AddControl(controls, "Reset", 2, 3, udon, nameof(WasdonSortBenchmark.ResetBenchmark)).interactable = ready;
            return go;
        }

        // ------------------------------------------------------------------
        //  Building blocks
        // ------------------------------------------------------------------

        /// Add an UdonBehaviour running Wasdon/Examples/<name>.asset.
        private static UdonBehaviour AddProgram(GameObject go, string name)
        {
            WasdonProgramAsset asset = FindProgram(name);
            if (asset != null) return AddProgram(go, asset);
            Debug.LogError($"Wasdon: program asset '{name}' not found. Is Wasdon/Examples in the project?", go);
            return go.AddComponent<UdonBehaviour>();
        }

        private static WasdonProgramAsset FindProgram(string name)
        {
            foreach (string guid in AssetDatabase.FindAssets(name + " t:" + nameof(WasdonProgramAsset)))
            {
                string path = AssetDatabase.GUIDToAssetPath(guid);
                if (Path.GetFileNameWithoutExtension(path) != name) continue;
                return AssetDatabase.LoadAssetAtPath<WasdonProgramAsset>(path);
            }
            return null;
        }

        private static UdonBehaviour AddProgram(GameObject go, WasdonProgramAsset asset)
        {
            var udon = go.AddComponent<UdonBehaviour>();
            asset.RefreshProgram();
            udon.programSource = asset;
            var serialized = new SerializedObject(udon);
            serialized.FindProperty("serializedProgramAsset").objectReferenceValue = asset.SerializedProgramAsset;
            serialized.ApplyModifiedPropertiesWithoutUndo();
            return udon;
        }

        private static Canvas CreatePanel(GameObject parent, Vector2 size)
        {
            MeshRenderer background = CreateScreen("Panel", size);
            background.transform.SetParent(parent.transform, false);
            Object.DestroyImmediate(background.GetComponent<Collider>());
            background.sharedMaterial.shader = Shader.Find("Unlit/Color");
            background.sharedMaterial.color = new Color(0.045f, 0.065f, 0.082f);
            return CreateCanvas(parent.transform, "Display", Vector3.zero, size);
        }

        private static RectTransform PanelRect(Canvas panel, string name, Vector2 center, Vector2 size)
        {
            var go = new GameObject(name, typeof(RectTransform));
            go.transform.SetParent(panel.transform, false);
            var rect = (RectTransform)go.transform;
            rect.anchoredPosition = center * 1000f;
            rect.sizeDelta = size * 1000f;
            return rect;
        }

        private static Text PanelText(Canvas panel, string name, string value, Vector2 center, Vector2 size, int fontSize)
        {
            Text text = AddText(PanelRect(panel, name, center, size), fontSize, Color.white);
            text.text = value;
            text.alignment = TextAnchor.MiddleLeft;
            text.raycastTarget = false;
            text.supportRichText = false;
            return text;
        }

        private static Canvas CreateControls(Transform parent, float y, float width)
        {
            Canvas controls = CreateCanvas(parent, "Controls", new Vector3(0f, y, 0f), new Vector2(width, 0.23f));
            controls.gameObject.AddComponent<GraphicRaycaster>();
            controls.gameObject.AddComponent<VRCUiShape>();
            return controls;
        }

        private static Button AddControl(Canvas controls, string label, int index, int count, UdonBehaviour target, string action)
        {
            Button button = CreateButton(controls.transform, label, index, count);
            UnityEventTools.AddStringPersistentListener(button.onClick, target.SendCustomEvent, action);
            return button;
        }

        /// Set one of the program's public variables. `T` must be the
        /// variable's declared type.
        internal static void SetVariable<T>(UdonBehaviour udon, string name, T value)
        {
            if (udon.publicVariables.TrySetVariableValue(name, value)) return;
            if (!udon.publicVariables.TryAddVariable(new UdonVariable<T>(name, value)))
            {
                Debug.LogError($"Wasdon: could not set public variable '{name}'.", udon);
            }
        }

        /// A quad with an unlit material for a program to put its texture on.
        private static MeshRenderer CreateScreen(string name, Vector2 size)
        {
            GameObject quad = GameObject.CreatePrimitive(PrimitiveType.Quad);
            quad.name = name;
            quad.transform.localScale = new Vector3(size.x, size.y, 1f);
            var renderer = quad.GetComponent<MeshRenderer>();
            renderer.sharedMaterial = new Material(Shader.Find("Unlit/Texture"));
            return renderer;
        }

        /// A world-space canvas `size` metres across, 1000 canvas units per
        /// metre.
        private static Canvas CreateCanvas(Transform parent, string name, Vector3 localPosition, Vector2 size)
        {
            var go = new GameObject(name, typeof(Canvas), typeof(CanvasScaler));
            go.transform.SetParent(parent, false);
            var canvas = go.GetComponent<Canvas>();
            canvas.renderMode = RenderMode.WorldSpace;
            var rect = (RectTransform)go.transform;
            rect.sizeDelta = size * 1000f;
            // Undo the parent's scale so the canvas has the size asked for,
            // and sit just in front of the quad.
            Vector3 scale = parent.lossyScale;
            rect.localScale = new Vector3(0.001f / scale.x, 0.001f / scale.y, 0.001f);
            rect.localPosition = new Vector3(localPosition.x / scale.x, localPosition.y / scale.y, -0.01f);
            return canvas;
        }

        private static Text CreateText(Transform parent, string name, Vector3 localPosition, Vector2 size, int fontSize)
        {
            Canvas canvas = CreateCanvas(parent, name, localPosition, size);
            return AddText(canvas.transform, fontSize, Color.white);
        }

        private static Text AddText(Transform parent, int fontSize, Color color)
        {
            var go = new GameObject("Text", typeof(Text));
            go.transform.SetParent(parent, false);
            var text = go.GetComponent<Text>();
            text.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
            text.fontSize = fontSize;
            text.color = color;
            text.horizontalOverflow = HorizontalWrapMode.Wrap;
            text.verticalOverflow = VerticalWrapMode.Overflow;
            RectTransform rect = text.rectTransform;
            rect.anchorMin = Vector2.zero;
            rect.anchorMax = Vector2.one;
            rect.offsetMin = Vector2.zero;
            rect.offsetMax = Vector2.zero;
            return text;
        }

        /// The `index`-th of `count` buttons filling the canvas side by side.
        private static Button CreateButton(Transform canvas, string label, int index, int count)
        {
            var go = new GameObject(label, typeof(Image), typeof(Button));
            go.transform.SetParent(canvas, false);
            go.GetComponent<Image>().color = new Color(0.2f, 0.22f, 0.3f);
            var rect = (RectTransform)go.transform;
            rect.anchorMin = new Vector2((float)index / count, 0f);
            rect.anchorMax = new Vector2((float)(index + 1) / count, 1f);
            rect.offsetMin = new Vector2(8f, 8f);
            rect.offsetMax = new Vector2(-8f, -8f);
            Text text = AddText(go.transform, 70, Color.white);
            text.text = label;
            text.alignment = TextAnchor.MiddleCenter;
            return go.GetComponent<Button>();
        }
    }
}
