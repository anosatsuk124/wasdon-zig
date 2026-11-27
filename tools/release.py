"""Assemble the relocatable CLI and VPM release artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "io.github.anosatsuk124.wasdon"


def sha(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def pack_dir(folder, archive):
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(folder.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(folder))
    else:
        with tarfile.open(archive, "w:gz", compresslevel=5) as tar:
            for path in sorted(folder.iterdir()):
                tar.add(path, arcname=path.name)


def binary(args):
    windows = os.name == "nt"
    system = {"Windows": "windows", "Darwin": "macos", "Linux": "linux"}[platform.system()]
    arch = {"amd64": "x64", "x86_64": "x64", "aarch64": "arm64", "arm64": "arm64"}[platform.machine().lower()]
    exe = "wasdon.exe" if windows else "wasdon"
    with tempfile.TemporaryDirectory() as temp:
        stage = Path(temp)
        shutil.copytree(args.prefix / "share", stage / "share")
        (stage / "bin").mkdir()
        shutil.copy2(args.prefix / "bin" / exe, stage / "bin" / exe)
        shutil.copy2(ROOT / "LICENSE", stage / "LICENSE")
        # uv-managed CPython is relocatable and includes its license notices.
        shutil.copytree(args.runtime, stage / "libexec/python", symlinks=not windows,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        python = stage / "libexec/python" / ("python.exe" if windows else "bin/python3")
        subprocess.run([python, "-I", "-B", "-c", "import hashlib, ssl, urllib.request, zipfile"], check=True)
        cli = stage / "bin" / exe
        langs = json.loads(subprocess.check_output([cli, "language", "list", "--json"], cwd=stage))["languages"]
        for lang in langs:
            dest = stage / "share/wasdon/packs" / lang["id"] / "bindings"
            subprocess.run([cli, "language", "bindings", lang["id"], "--output", dest], cwd=stage, check=True)
        archive = args.output / (f"wasdon-{system}-{arch}" + (".zip" if windows else ".tar.gz"))
        pack_dir(stage, archive)
        (args.output / (archive.name + ".sha256")).write_text(f"{sha(archive)}  {archive.name}\n", encoding="ascii")
        print(archive)


def vpm(args):
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", args.tag):
        raise ValueError("Release tag must be vMAJOR.MINOR.PATCH or a prerelease")
    base = "https://github.com/" + args.repository
    listing_url = base + "/releases/latest/download/vpm.json"
    version = args.tag[1:]
    name = f"{PACKAGE}-{version}.zip"
    with tempfile.TemporaryDirectory() as temp:
        stage = Path(temp) / PACKAGE
        shutil.copytree(ROOT / "unity/Wasdon", stage)
        shutil.copytree(ROOT / "skills/wasdon-worlds", stage / "Skills~/wasdon-worlds")
        manifest_file = stage / "package.json"
        manifest = json.loads(manifest_file.read_text())
        manifest.update(version=version, url=f"{base}/releases/download/{args.tag}/{name}")
        manifest_file.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        shutil.copy2(ROOT / "LICENSE", stage / "LICENSE.md")
        pack_dir(stage, args.output / name)
    listing = {"name": "Wasdon Worlds SDK", "id": "io.github.anosatsuk124.wasdon.repo", "url": listing_url,
               "author": "anosatsuk124", "packages": {PACKAGE: {"versions": {}}}}
    if args.previous:
        listing["packages"][PACKAGE]["versions"].update(json.loads(args.previous.read_text())["packages"][PACKAGE]["versions"])
    listing["packages"][PACKAGE]["versions"][version] = dict(manifest, zipSHA256=sha(args.output / name))
    (args.output / "vpm.json").write_text(json.dumps(listing, indent=2) + "\n", encoding="utf-8")
    for script in ("install.sh", "install.ps1"):
        shutil.copy2(ROOT / "unity/Wasdon/Tools~" / script, args.output / script)
    assets = sorted(p for p in args.output.iterdir() if p.is_file() and p.name != "SHA256SUMS")
    (args.output / "SHA256SUMS").write_text("".join(f"{sha(p)}  {p.name}\n" for p in assets), encoding="ascii")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    commands = p.add_subparsers(dest="command", required=True)
    cli = commands.add_parser("binary")
    cli.add_argument("--prefix", type=Path, default=ROOT / "zig-out")
    cli.add_argument("--runtime", type=Path, required=True, help="relocatable uv CPython installation directory")
    package = commands.add_parser("vpm")
    package.add_argument("--tag", required=True)
    package.add_argument("--repository", default="anosatsuk124/wasdon-zig")
    package.add_argument("--previous", type=Path)
    for command in (cli, package):
        command.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    (binary if args.command == "binary" else vpm)(args)
