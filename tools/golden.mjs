// Reference runs for the example programs.
//
//   node tools/golden.mjs <program.wasm> <scenario.txt> > expected.log
//
// Runs the WASM module in Node's engine, firing the Udon events listed in
// the scenario file (one label per line, `# comments` allowed) and printing
// everything the program logs. `zig build test` replays the same scenario
// against the translated Udon Assembly in the emulator and compares the logs.
//
//   node tools/golden.mjs --check <dir>
//
// Replays every `<name>.wasm` + `<name>.scenario` in a directory written by
// `zig build dump-fixtures` and compares the output with `<name>.log`, the
// expectation hard-coded in `tests/structure.zig`.
//
// Host imports mirror `tests/e2e.zig`: `Debug.Log*` plus the Unity mocks
// used by the udon-orbit example.
import fs from "node:fs";
import path from "node:path";

function run(wasmPath, scenarioPath) {
const out = [];
let memory;
const text = (ptr, len) => new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
const f32 = Math.fround;

// Object handles are opaque to the WASM side: any i32 will do.
const objects = [null];
const handle = (o) => objects.push(o) - 1;
const self = handle({ type: "Transform", position: [0, 0, 0] });
let clones = 0;

const host = {
  "UnityEngineDebug.__Log__SystemObject__SystemVoid": (v) => out.push(String(v)),
  "UnityEngineDebug.__Log__SystemString__SystemVoid": (p, n) => out.push(text(p, n)),
  "UnityEngineDebug.__LogWarning__SystemString__SystemVoid": (p, n) => out.push("[warning] " + text(p, n)),
  "UnityEngineDebug.__LogError__SystemString__SystemVoid": (p, n) => out.push("[error] " + text(p, n)),
  "udon.self": () => self,
  "UnityEngineTime.__get_deltaTime__SystemSingle": () => f32(0.25),
  "UnityEngineMathf.__Sin__SystemSingle__SystemSingle": (x) => f32(Math.sin(x)),
  "UnityEngineMathf.__Cos__SystemSingle__SystemSingle": (x) => f32(Math.cos(x)),
  "UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3": (x, y, z) => handle([x, y, z]),
  "UnityEngineVector3.__op_Addition__UnityEngineVector3_UnityEngineVector3__UnityEngineVector3": (a, b) =>
    handle(objects[a].map((v, i) => f32(v + objects[b][i]))),
  "UnityEngineTransform.__get_position__UnityEngineVector3": (t) => handle(objects[t].position),
  "UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid": (t, v) => {
    objects[t].position = objects[v];
    out.push("position = " + objects[v].map((c) => c.toFixed(3)).join(", "));
  },
  "UnityEngineComponent.__get_gameObject__UnityEngineGameObject": (t) => handle({ type: "GameObject", of: t }),
  "VRCInstantiate.__Instantiate__UnityEngineGameObject__UnityEngineGameObject": () => {
    out.push("instantiate #" + ++clones);
    return handle({ type: "GameObject" });
  },
};

const module = new WebAssembly.Module(fs.readFileSync(wasmPath));
const imports = {};
const labels = {};
for (const imp of WebAssembly.Module.imports(module)) {
  if (!(imp.name in host)) throw new Error(`no host implementation for import ${imp.module}.${imp.name}`);
  (imports[imp.module] ??= {})[imp.name] = host[imp.name];
}
// A start function may log before `memory` is known; none of ours passes strings.
const instance = new WebAssembly.Instance(module, imports);
const ex = instance.exports;
memory = ex.memory;

// Map Udon labels to exports through __udon_meta (or use export names as-is).
const value = (e) => (typeof e === "function" ? e() : e.value);
if (ex.__udon_meta_ptr && ex.__udon_meta_len) {
  const meta = JSON.parse(text(value(ex.__udon_meta_ptr), value(ex.__udon_meta_len)));
  const defaults = { Start: "_start", Update: "_update", Interact: "_interact" };
  for (const [key, f] of Object.entries(meta.functions ?? {}))
    labels[f.label ?? defaults[f.event] ?? key] = f.source.name;
} else for (const name of Object.keys(ex)) labels[name] = name;

for (const line of fs.readFileSync(scenarioPath, "utf8").split("\n")) {
  const label = line.replace(/#.*/, "").trim();
  if (!label) continue;
  if (!(labels[label] in ex)) throw new Error(`scenario names unknown event ${label}`);
  try {
    ex[labels[label]]();
  } catch (e) {
    out.push(`[trap] ${e.message}`);
  }
}
return out.join("\n") + "\n";
}

const args = process.argv.slice(2);
if (args[0] === "--check") {
  let failed = 0;
  const names = fs.readdirSync(args[1]).filter((f) => f.endsWith(".wasm")).map((f) => f.slice(0, -5));
  for (const name of names.sort()) {
    const base = path.join(args[1], name);
    const got = run(base + ".wasm", base + ".scenario");
    const want = fs.readFileSync(base + ".log", "utf8");
    console.log(`${got === want ? "ok  " : "FAIL"} ${name}`);
    if (got !== want) {
      failed++;
      console.log(`--- expected\n${want}--- engine\n${got}`);
    }
  }
  process.exit(failed ? 1 : 0);
}
process.stdout.write(run(args[0], args[1]));
