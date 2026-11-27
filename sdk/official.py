"""Shared toolchain and protocol support for the three bundled packs."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request

from registry import input_files, locked


ZIG = "0.16.0"
DATA = Path(os.environ.get("LOCALAPPDATA" if os.name == "nt" else "XDG_DATA_HOME", Path.home() / ".local/share"))
CACHE = DATA / "wasdon/toolchains"
MISE = Path(os.environ.get("MISE_DATA_DIR", DATA / "mise"))
EXE = ".exe" if os.name == "nt" else ""


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, stdout=subprocess.PIPE,
                          encoding="utf-8", errors="replace", **kwargs).stdout.strip()


def tool(name):
    if name == "zig":
        # A mise shim can select a different toolchain when the build changes cwd.
        names = [CACHE / ("zig-" + ZIG) / ("zig" + EXE),
                 MISE / "installs/zig" / ZIG / ("zig" + EXE),
                 MISE / "installs/zig" / ZIG / "bin" / ("zig" + EXE), shutil.which(name)]
    else:
        names = [shutil.which(name), Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo")) / "bin" / (name + EXE)]
    for p in names:
        if not p or not Path(p).is_file():
            continue
        if name == "zig":
            try:
                if run([p, "version"], stderr=subprocess.DEVNULL) != ZIG:
                    continue
            except (OSError, subprocess.CalledProcessError):
                continue
        return str(p)
    return None


def doctor(lang):
    if lang != "rust":
        zig = tool("zig")
        return {"ready": bool(zig), "compiler": zig, "version": ZIG}
    rustup, cargo = tool("rustup"), tool("cargo")
    targets = []
    if rustup:
        cmd = subprocess.run([rustup, "target", "list", "--installed"], capture_output=True, text=True)
        targets = cmd.stdout.splitlines()
    return {"ready": bool(cargo and "wasm32v1-none" in targets), "compiler": cargo, "targets": targets}


def download(url, path, digest):
    with urllib.request.urlopen(url, timeout=90) as source, path.open("wb") as dest:
        shutil.copyfileobj(source, dest)
    with path.open("rb") as f:
        actual = hashlib.file_digest(f, "sha256").hexdigest()
    if actual != digest.lower():
        raise ValueError(f"SHA-256 mismatch downloading {url}")


def setup(lang):
    CACHE.mkdir(parents=True, exist_ok=True)
    with locked(CACHE / "install.lock"), tempfile.TemporaryDirectory(dir=CACHE) as temp:
        if doctor(lang)["ready"]:
            return doctor(lang)
        work = Path(temp)
        arch = {"arm64": "aarch64", "amd64": "x86_64"}.get(platform.machine().lower(), platform.machine().lower())
        system = platform.system().lower()
        if lang == "rust":
            rustup = tool("rustup")
            if not rustup:
                triple = arch + {"windows": "-pc-windows-msvc", "darwin": "-apple-darwin", "linux": "-unknown-linux-gnu"}[system]
                url = f"https://static.rust-lang.org/rustup/dist/{triple}/rustup-init{EXE}"
                with urllib.request.urlopen(url + ".sha256", timeout=60) as f:
                    digest = f.read().decode().split()[0]
                installer = work / ("rustup-init" + EXE)
                download(url, installer, digest)
                installer.chmod(0o755)
                run([installer, "-y", "--profile", "minimal", "--no-modify-path"])
                rustup = tool("rustup")
            if subprocess.run([rustup, "show", "active-toolchain"], capture_output=True).returncode:
                run([rustup, "default", "stable"])
            run([rustup, "target", "add", "wasm32v1-none"])
        else:
            with urllib.request.urlopen("https://ziglang.org/download/index.json", timeout=60) as f:
                entry = json.load(f)[ZIG][arch + "-" + ("macos" if system == "darwin" else system)]
            archive = work / entry["tarball"].rsplit("/", 1)[-1]
            download(entry["tarball"], archive, entry["shasum"])
            run(["tar", "-xf", archive, "-C", work])
            folder = next(p for p in work.iterdir() if (p / ("zig" + EXE)).is_file())
            folder.rename(CACHE / ("zig-" + ZIG))
    return doctor(lang)


def symbol(node):
    return node["name"].replace(".__", "_")


def handle(req, declaration, generate, compile_project):
    lang, action = req["language"], req["action"]
    if action == "doctor":
        return doctor(lang)
    if action == "setup":
        return setup(lang)
    if action == "bindings":
        nodes = [n for n in req["nodes"] if n["kind"] == "extern"]
        if req["mode"] == "describe":
            return {"calls": {n["name"]: declaration(n) for n in nodes}}
        dest = Path(req["outputDir"])
        generate(nodes, dest)
        shutil.copytree(Path(req["packRoot"]) / "library", dest, dirs_exist_ok=True)
        return {"count": len(nodes), "sdkVersion": req["sdkVersion"]}
    project, out = Path(req["projectDir"]), Path(req["outputDir"])
    deps = compile_project(project, out)
    result = {"wasm": "program.wasm", "dependencies": [str(p) for p in deps] + [str(Path(__file__).resolve())]}
    metadata = project / "wasdon.meta.json"
    if metadata.is_file():
        shutil.copyfile(metadata, out / "metadata.json")
        result.update(metadata="metadata.json")
        result["dependencies"].append(str(metadata))
    return result


def main(declaration, generate, compile_project):
    try:
        result = handle(json.load(sys.stdin), declaration, generate, compile_project)
        print(json.dumps(dict(interfaceVersion=1, **result)))
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))


def params(node):
    args = [p["wasm"] for p in node["ports"] if p["role"] != "result"]
    ret = next((p["wasm"] for p in node["ports"] if p["role"] == "result"), None)
    return args, ret


def project_inputs(project, out):
    # Unity writes this asset after each successful build. Tracking it would
    # make a source-backed behaviour rebuild again after saving itself.
    exclude = {out, out.parent}
    if out.parent == project:
        exclude.update(p.parent for p in project.glob("*/program.uasm") if len(p.parent.name) == 64)
    return [p for p in input_files(project, exclude) if p != project / "Program.asset"
            and p not in (out.parent / "build.json", out.parent / "build.lock")]
