# Wasdon language packs

Create a working pack in a directory outside the SDK checkout.

```sh
wasdon language new my-lang
wasdon language validate ./my-lang
wasdon language add ./my-lang
wasdon init World --lang my-lang
wasdon build World --json
wasdon nodes search GetComponent --lang my-lang --json
```

The scaffold implements a small text language. Its template's `message.txt`
becomes a WASM module whose `_start` event logs the text. Change the compiler
and generator in `pack.py`, or point the manifest at your own executables.
Validation generates fresh bindings, builds a clean project, checks the
assembly, runs the named events, and matches whole emulator log lines.

## Manifest and installation

`wasdon-language.json` declares `id`, `displayName`, a semantic `version`,
`interfaceVersion: 1`, a `template` directory, the four `commands`, and a
`test` with `events` and `logs`. Each command is an argument array. Its first
element names a pack-relative executable or Python script. Further elements
are literal arguments. Hooks run with the pack as working directory.
Releases include a Python interpreter for Python hooks.

Run `language add` from the consumer project. Directories remain live, so an
author can edit the generator or compiler and run validation immediately. A
ZIP can contain the pack at its root or in one enclosing directory. Adding
its URL records the version and SHA-256 in `wasdon.lock.json`. Commit this
lock. The CLI restores missing distributions from the pinned URL and digest.
Ignore the `.wasdon/` cache in version control. The nearest ancestor lock is
used for nested projects. `--registry <directory>` selects a registry explicitly.
Installed pack commands execute with the current user's permissions.

## Interface version 1

Read one UTF-8 JSON object from stdin. Write one JSON object with
`interfaceVersion: 1` to stdout. Send diagnostics to stderr. A nonzero exit
or a response with an `error` string fails the operation. Every request
contains `interfaceVersion`, `action`, `language` and absolute `packRoot`.

| Action | Additional request fields | Response fields |
|---|---|---|
| `doctor` | | `ready` boolean and toolchain details |
| `setup` | | Setup status. Project creation checks `doctor` again after setup. |
| `bindings` | `mode`, `abi`, `sdkVersion`, parsed `nodes`, and absolute `outputDir` for generation | In `generate` mode write a usable package into the output directory. In `describe` mode return `calls`, a map of exact node names to language declarations or call expressions. |
| `build` | Absolute `projectDir` and temporary `outputDir` | `wasm` and optional `metadata` are paths relative to the output directory. `dependencies` lists the source and dependency files, relative to the project or absolute. |

The host publishes checked output only after successful conversion. A build
response can refer to external dependencies, including compiler inputs outside
the Unity Assets directory. Unity watches those paths. The metadata file
uses the ordinary `__udon_meta` JSON schema. [Fields, events and synchronization](spec_udonmeta_conversion.md)

## Bindings and types

`docs/udon_nodes.txt` records the Worlds SDK version and one ordinally sorted
row per node. Each row contains its name and tab-separated
`direction:name:type` ports in VM order. Unity's **Tools → Wasdon → Export SDK
Node Definitions** regenerates the file. In batch mode set `WASDON_NODE_OUTPUT`
and invoke `Wasdon.WasdonNodeExporter.Export`. Rebuild the CLI after exporting.

For `wasdon.v1`, import each extern by its exact node name from module
`wasdon.v1`. Use the supplied ports in order. `role` identifies receivers,
arguments, hidden generic type arguments and the result. `wasm` gives its
WASM type and `passing` is `value`, `handle`, or `cell`. The result becomes the
WASM return value. The SDK describes both C# `ref` and `out` ports as
`in_out`. Supply a managed one-element array of the indicated element type.
Wasdon reads element zero before the call and writes its new value back
afterwards. This also works for value types such as `UnityEngineRaycastHit`.

String inputs are managed handles in this ABI. The standard library's
string helper converts UTF-8 bytes to a handle. Pass an actual `SystemType`
handle for a generic port. For example, the transform's `GetType` result can
be used with `GameObject.GetComponent<T>`. Store long-lived handles in bound
Udon fields. [Host import conventions](spec_host_import_conversion.md)

Each release includes a Rust crate, a Zig package (module `wasdon`) and
`wasdon.h` in the respective pack's `bindings/` directory. To regenerate
one separately, run `wasdon language bindings rust --output ./bindings`.
The CLI bundles the agent skill at `share/wasdon/skills/wasdon-worlds`. The
VPM ZIP carries the same source at `Skills~/wasdon-worlds/SKILL.md`. When
Unity opens the project, it installs the skill in `.agents/skills/wasdon-worlds`.
Unity updates its own unmodified copy when the VPM package changes.

## Release verification

Pull requests build all four native archives. A pushed `vX.Y.Z` tag publishes
the verified archives, per-platform SHA-256 files, shell and PowerShell
installers, the VPM ZIP, `vpm.json` and `SHA256SUMS` to GitHub Releases.
Stable releases share a single VPM repository URL. The listing retains prior
package versions. Prerelease tags create prereleases.

`zig build test-sdk` exercises all packs including directory and ZIP installs,
dependency reporting and build recovery. It runs each shared-switch template in
two emulated VMs and checks ownership changes, serialization and late-join state.
`python tools/test_bindings.py zig-out/bin/wasdon` compiles and translates
every SDK extern call in shards for each official language.

For the Unity acceptance test, use a disposable Worlds 3.10.6 project, install
the VPM package, run `wasdon language new fourth` outside the project and
register its directory in the project root. Copy
`tools/unity-tests/WasdonSdkSmoke.cs` to `Assets/Editor`. Set `WASDON_CLI` to
the installed executable and `WASDON_PROBE_DIR` to the absolute
`tools/unity-tests` directory. Run the Editor with `-batchmode -nographics
-projectPath <project> -executeMethod WasdonSdkSmoke.Run`. The test enters
Play Mode, verifies actual generic results and physics write-backs, exercises
rebuild failure and recovery, then exits with the test status.
To include Unity's release installer, serve the matching CLI archive and its
`.sha256` over HTTP, set `WASDON_RELEASE_BASE` to that directory's URL, and
point `WASDON_CLI` to the executable under the project's `Library/Wasdon/SDK/bin`.
