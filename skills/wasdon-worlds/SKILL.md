---
name: wasdon-worlds
description: Build VRChat Worlds behaviours with an installed Wasdon language pack, discover Udon extern calls, and verify compiled events and networked state.
---

In a Unity project, use the executable selected by `WASDON_CLI`, the project-local `Library/Wasdon/SDK/bin/wasdon` (`wasdon.exe` on Windows), or `wasdon` on PATH. **Tools → Wasdon → Setup → Install release CLI** installs the project-local executable.

Read the project's `wasdon.json` and run `wasdon language list --json` from its registry directory. Create a starter with `wasdon init World --lang <id>`.

Search `wasdon nodes search <method> --lang <id> --json`. Use the returned declaration, receiver and ordered ports. An SDK ref/out cell is a managed one-element array. Read element zero after the call. Keep Unity objects and managed strings in registers or imported Udon fields.

Run `wasdon build <project> --json`. Use the returned paths with `wasdon inspect <wasm>` (include `--meta <metadata>` when present), `wasdon check <assembly>` and `wasdon run <assembly> --events _start,_interact`. Check the observed logs or field values and confirm each requested event was exported.

For a shared switch, take ownership before writing the synced field, request serialization on the owner and apply current state on deserialization. Late joiners receive synced state. Read event arguments from named Udon variables such as `onPlayerJoinedPlayer` during the event. Verify cross-client behaviour with two clients, including a join after the first change. [VRChat networking](https://creators.vrchat.com/worlds/udon/networking/)
