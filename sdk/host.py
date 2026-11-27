"""Language-pack client used by the wasdon executable and Unity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

from registry import (MANIFEST, LOCK, VERSION, ID, Pack, PackError, add, input_files, installed,
                      locked, member, read_json, records, registry_root, save_json)


PROJECT = "wasdon.json"


def execute(argv, **options):
    proc = subprocess.run([str(arg) for arg in argv], capture_output=True, encoding="utf-8",
                          errors="replace", **options)
    if proc.returncode:
        raise PackError(f"{Path(argv[0]).name} exited {proc.returncode}\n{(proc.stderr or proc.stdout)[-16000:].strip()}")
    return proc.stdout


def invoke(pack, action, **fields):
    entry, *args = pack.manifest["commands"][action]
    script = member(pack.root, entry)
    prefix = []
    if script.suffix == ".py":
        prefix = [sys.executable, "-B", "-X", "utf8"]
    request = dict(interfaceVersion=VERSION, action=action, language=pack.id,
                   packRoot=str(pack.root), **fields)
    env = dict(os.environ, WASDON_SDK=str(Path(__file__).resolve().parent))
    raw = execute([*prefix, script, *args], cwd=pack.root, input=json.dumps(request), env=env)
    try:
        reply = json.loads(raw)
    except ValueError as exc:
        raise PackError(f"{pack.id} {action} returned invalid JSON: {exc}") from exc
    if not isinstance(reply, dict) or type(reply.get("interfaceVersion")) is not int or reply["interfaceVersion"] != VERSION:
        raise PackError(f"{pack.id} {action}: incompatible response interfaceVersion")
    if "error" in reply:
        raise PackError(f"{pack.id} {action}: {reply['error']}")
    return reply


def ensure_tools(pack):
    report = invoke(pack, "doctor")
    if report.get("ready") is not True:
        invoke(pack, "setup")
        report = invoke(pack, "doctor")
    if report.get("ready") is not True:
        raise PackError(f"{pack.id} toolchain unavailable: {report}")
    return report


def catalog(core, query="", limit=0):
    return json.loads(execute([core, "node-catalog", query, str(limit)]))


def bindings(core, pack, dest):
    dest.mkdir(parents=True, exist_ok=True)
    data = catalog(core)
    return invoke(pack, "bindings", mode="generate", outputDir=str(dest), **data)


def init_project(core, pack, dest, registry, regenerate=False):
    if (dest / PROJECT).exists():
        raise PackError(f"A Wasdon project already exists at {dest}")
    ensure_tools(pack)
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest.parent) as temp:
        stage = Path(temp) / "project"
        shutil.copytree(pack.template, stage)
        generated = stage / "bindings"
        if (pack.root / "bindings").is_dir() and not regenerate:
            shutil.copytree(pack.root / "bindings", generated)
        else:
            bindings(core, pack, generated)
        save_json(stage / PROJECT, {"version": VERSION, "language": pack.id})
        if registry not in (dest, *dest.parents):
            entry = records(registry).get(pack.id)
            if entry is not None:
                if "path" in entry:
                    entry = {"path": str(pack.root)}
                save_json(stage / LOCK, {"version": VERSION, "languages": {pack.id: entry}})
        if not dest.exists():
            stage.rename(dest)
        else:
            with locked(dest / ".wasdon" / "init.lock"):
                children = list(stage.iterdir())
                for p in children:
                    if (dest / p.name).exists():
                        raise PackError(f"Template would overwrite {dest / p.name}")
                moved = []
                try:
                    for p in sorted(children, key=lambda p: p.name == PROJECT):
                        p.rename(dest / p.name)
                        moved.append(p)
                except OSError:
                    for p in reversed(moved):
                        (dest / p.name).rename(p)
                    raise
    return {"project": str(dest / PROJECT), "language": pack.id}


def project_dir(path):
    path = path.resolve()
    if path.is_file():
        path = path.parent
    return next((p for p in (path, *path.parents) if (p / PROJECT).is_file()), path)


def get_pack(sdk, registry, ident):
    languages = installed(sdk, registry)
    if ident not in languages:
        raise PackError(f"Unknown language {ident!r}. Run wasdon language list or wasdon language add.")
    return languages[ident][0]


def build(core, pack, project, output, registry):
    output.mkdir(parents=True, exist_ok=True)
    with locked(output / "build.lock"), tempfile.TemporaryDirectory(dir=output) as tmp:
        stage = Path(tmp)
        reply = invoke(pack, "build", projectDir=str(project), outputDir=str(stage))
        wasm = member(stage, reply["wasm"])
        meta = reply.get("metadata")
        source_paths = reply["dependencies"]
        if not isinstance(source_paths, list) or not all(isinstance(p, str) for p in source_paths):
            raise PackError(f"{pack.id} build must return a dependencies array of paths")
        dependencies = {(project / p).resolve() for p in source_paths}
        dependencies.add(project / PROJECT)
        dependencies.update(input_files(pack.root, {project, output}))
        if (registry / LOCK).exists():
            dependencies.add(registry / LOCK)
        for p in dependencies:
            if not p.is_file():
                raise PackError(f"Missing build dependency {p}")
        meta_args = ["--meta", member(stage, meta)] if meta is not None else []
        assembly = stage / "checked.uasm"
        execute([core, "translate", wasm, "--strict", *meta_args, "-o", assembly])
        execute([core, "check", assembly])
        digest = hashlib.sha256()
        for p in (wasm, assembly, *meta_args[1:]):
            digest.update(hashlib.sha256(p.read_bytes()).digest())
        final = output / digest.hexdigest()
        if not final.exists():
            artifact = stage / "verified"
            artifact.mkdir()
            shutil.copyfile(wasm, artifact / "program.wasm")
            shutil.copyfile(assembly, artifact / "program.uasm")
            if meta is not None:
                shutil.copyfile(meta_args[1], artifact / "metadata.json")
            artifact.rename(final)
        result = dict(language=pack.id, wasm=str(final / "program.wasm"), assembly=str(final / "program.uasm"),
                      dependencies=sorted(map(str, dependencies)))
        if meta is not None:
            result["metadata"] = str(final / "metadata.json")
        save_json(output / "build.json", result)
        return result


def validate(core, pack):
    spec = pack.manifest["test"]
    with tempfile.TemporaryDirectory() as temp:
        project = Path(temp) / "sample"
        init_project(core, pack, project, project, regenerate=True)
        result = build(core, pack, project, Path(temp) / "build", project)
        output = execute([core, "run", result["assembly"], "--events", ",".join(spec["events"])])
        if not spec["events"] or "(not exported)" in output:
            raise PackError(f"{pack.id} validation requested a missing event")
        for line in spec["logs"]:
            if line not in output.splitlines():
                raise PackError(f"Missing expected Udon log {line!r} in {output!r}")
        return {"language": pack.id, "events": spec["events"], "output": output.strip()}


def parser():
    root = argparse.ArgumentParser(prog="wasdon")
    commands = root.add_subparsers(dest="command", required=True)
    langs = commands.add_parser("language").add_subparsers(dest="action", required=True)
    def sub(group, name, help_text):
        cmd = group.add_parser(name, help=help_text, description=help_text)
        cmd.add_argument("--json", action="store_true", help="emit one JSON document")
        cmd.add_argument("--registry", type=Path, help="directory containing the project language lock")
        return cmd
    sub(langs, "list", "List installed language packs")
    sub(langs, "add", "Register a development directory or a ZIP URL").add_argument("source")
    new = sub(langs, "new", "Create a working, independently runnable language pack")
    new.add_argument("id")
    new.add_argument("--output", type=Path)
    for name in ("validate", "setup", "doctor", "bindings"):
        p = sub(langs, name, f"Run {name} for a pack id or directory (defaults to this directory)")
        p.add_argument("pack", nargs="?", default=".")
        if name == "bindings":
            p.add_argument("--output", type=Path, required=True)
    init = sub(commands, "init", "Create a project from an installed language template")
    init.add_argument("directory", nargs="?", type=Path, default=Path("."))
    init.add_argument("--lang", required=True)
    compile_cmd = sub(commands, "build", "Build WASM, translate and check Udon Assembly")
    compile_cmd.add_argument("project", nargs="?", type=Path, default=Path("."))
    compile_cmd.add_argument("--output", type=Path)
    nodes = commands.add_parser("nodes").add_subparsers(dest="action", required=True)
    search = sub(nodes, "search", "Find SDK nodes and their language-specific declarations")
    search.add_argument("query")
    search.add_argument("--lang")
    search.add_argument("--limit", type=int, default=30)
    return root


def dispatch(core, sdk, args):
    cwd = Path.cwd()
    start = project_dir(args.project) if args.command == "build" else cwd
    registry = args.registry.resolve() if args.registry else registry_root(start)
    if args.command == "language":
        if args.action == "add":
            return add(sdk, registry, args.source)
        if args.action == "list":
            return {"languages": [dict(p.info(), source=source) for p, source in installed(sdk, registry).values()]}
        if args.action == "new":
            if not ID.fullmatch(args.id):
                raise PackError("Use a lowercase language id such as my-lang")
            dest = (args.output or Path(args.id)).resolve()
            if dest.exists():
                raise PackError(f"Destination already exists: {dest}")
            shutil.copytree(sdk / "scaffold", dest)
            m = read_json(dest / MANIFEST)
            m.update(id=args.id, displayName=args.id)
            save_json(dest / MANIFEST, m)
            return dict(Pack(dest).info(), path=str(dest))
        path = Path(args.pack)
        pack = Pack(path) if (path / MANIFEST).is_file() else get_pack(sdk, registry, args.pack)
        if args.action == "validate":
            return validate(core, pack)
        if args.action == "bindings":
            return bindings(core, pack, args.output.resolve())
        return invoke(pack, args.action)
    if args.command == "init":
        return init_project(core, get_pack(sdk, registry, args.lang), args.directory.resolve(), registry)
    if args.command == "build":
        config = read_json(start / PROJECT)
        if config["version"] != VERSION:
            raise PackError(f"Unsupported project version at {start / PROJECT}")
        return build(core, get_pack(sdk, registry, config["language"]), start,
                     (args.output or start / ".wasdon" / "build").resolve(), registry)
    if args.limit <= 0:
        raise PackError("--limit must be positive")
    data = catalog(core, args.query, args.limit)
    ident = args.lang
    config = project_dir(cwd) / PROJECT
    if not ident and config.exists():
        ident = read_json(config)["language"]
    if ident:
        pack = get_pack(sdk, registry, ident)
        data["calls"] = invoke(pack, "bindings", mode="describe", **data)["calls"]
    return data


def main():
    core = Path(sys.argv[1]).resolve()
    sdk = core.parent.parent / "share" / "wasdon"
    args = parser().parse_args(sys.argv[2:])
    try:
        result = dispatch(core, sdk, args)
        print(json.dumps(result, ensure_ascii=True, indent=None if args.json else 2))
    except (PackError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as exc:
        print(json.dumps({"error": str(exc)}) if args.json else f"error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
