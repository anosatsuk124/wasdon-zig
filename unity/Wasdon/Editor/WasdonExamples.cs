using System.IO;
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
    /// Each example is one UdonBehaviour running a Wasdon Assembly Program
    /// Asset, plus the few scene objects it draws on. Everything is created
    /// in the open scene under one root object, wired up and ready to play;
    /// nothing is saved as an asset, so the objects can be rearranged or
    /// deleted freely.
    /// </summary>
    public static class WasdonExamples
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

        // ------------------------------------------------------------------
        //  Building blocks
        // ------------------------------------------------------------------

        /// Add an UdonBehaviour running Wasdon/Examples/<name>.asset.
        private static UdonBehaviour AddProgram(GameObject go, string name)
        {
            WasdonProgramAsset asset = null;
            foreach (string guid in AssetDatabase.FindAssets(name + " t:" + nameof(WasdonProgramAsset)))
            {
                string path = AssetDatabase.GUIDToAssetPath(guid);
                if (Path.GetFileNameWithoutExtension(path) != name) continue;
                asset = AssetDatabase.LoadAssetAtPath<WasdonProgramAsset>(path);
                break;
            }

            var udon = go.AddComponent<UdonBehaviour>();
            if (asset == null)
            {
                Debug.LogError($"Wasdon: program asset '{name}' not found. Is Wasdon/Examples in the project?", go);
                return udon;
            }

            asset.RefreshProgram();
            udon.programSource = asset;
            var serialized = new SerializedObject(udon);
            serialized.FindProperty("serializedProgramAsset").objectReferenceValue = asset.SerializedProgramAsset;
            serialized.ApplyModifiedPropertiesWithoutUndo();
            return udon;
        }

        /// Set one of the program's public variables. `T` must be the
        /// variable's declared type.
        private static void SetVariable<T>(UdonBehaviour udon, string name, T value)
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
