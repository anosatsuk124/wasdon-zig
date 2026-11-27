"""Install the release ZIP through a VPM repository in a disposable project."""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import zipfile

from release import PACKAGE


def check(args, root):
    dist = root / "release"
    build = [sys.executable, Path(__file__).with_name("release.py"), "vpm"]
    older = root / "older"
    subprocess.run([*build, "--tag", "v0.0.9", "--output", older], check=True)
    subprocess.run([*build, "--tag", "v0.1.0", "--output", dist, "--previous", older / "vpm.json"], check=True)
    index = dist / "vpm.json"
    listing = json.loads(index.read_text())
    entry = listing["packages"][PACKAGE]["versions"]["0.1.0"]
    assert listing["packages"][PACKAGE]["versions"]["0.0.9"] == json.loads(
        (older / "vpm.json").read_text())["packages"][PACKAGE]["versions"]["0.0.9"]
    arc = dist / entry["url"].rsplit("/", 1)[-1]
    with arc.open("rb") as f:
        assert hashlib.file_digest(f, "sha256").hexdigest() == entry["zipSHA256"]
    skill_path = "Skills~/wasdon-worlds/SKILL.md"
    skill = (Path(__file__).resolve().parents[1] / "skills/wasdon-worlds/SKILL.md").read_bytes()
    with zipfile.ZipFile(arc) as z:
        manifest = json.loads(z.read("package.json"))
        assert z.read(skill_path) == skill
        assert manifest == {k: v for k, v in entry.items() if k != "zipSHA256"}
        assert manifest["vpmDependencies"]["com.vrchat.worlds"] == ">=3.10.6"
    project = root / "World"
    (project / "Assets").mkdir(parents=True)
    if args.worlds_project:
        for part in ("Packages", "ProjectSettings"):
            shutil.copytree(args.worlds_project / part, project / part, ignore=shutil.ignore_patterns(PACKAGE))
    else:
        (project / "Packages").mkdir()
        (project / "ProjectSettings").mkdir()
        (project / "Packages/manifest.json").write_text('{"dependencies":{}}')
        (project / "Packages/vpm-manifest.json").write_text('{"dependencies":{"com.vrchat.worlds":{"version":"3.10.6"}},"locked":{}}')
        (project / "ProjectSettings/ProjectVersion.txt").write_text("m_EditorVersion: 2022.3.22f1\n")
    env = dict(os.environ, XDG_DATA_HOME=str(root / "data"), DOTNET_CLI_HOME=str(root / "dotnet"))
    def call(*argv):
        subprocess.run([*args.exe, *map(str, argv)], check=True, cwd=project, env=env)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(dist))
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        base = f"http://127.0.0.1:{server.server_port}/"
        entry["url"] = base + arc.name
        listing["url"] = base + "vpm.json"
        index.write_text(json.dumps(listing))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            if args.client == "vrc-get":
                call("repo", "add", listing["url"])
                call("install", PACKAGE, "--project", project, "--yes")
            else:
                call("install", "templates")
                call("add", "repo", listing["url"])
                call("add", "package", PACKAGE, "--project", project)
            assert json.loads((project / "Packages" / PACKAGE / "package.json").read_text()) == manifest
            assert (project / "Packages" / PACKAGE / skill_path).read_bytes() == skill
            assert json.loads((project / "Packages/vpm-manifest.json").read_text())["locked"][PACKAGE]["version"] == "0.1.0"
        finally:
            server.shutdown()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("client", choices=("vpm", "vrc-get"))
    p.add_argument("--worlds-project", type=Path)
    p.add_argument("--exe", nargs="+")
    args = p.parse_args()
    args.exe = args.exe or [args.client]
    with tempfile.TemporaryDirectory() as temp:
        check(args, Path(temp).resolve())
    print(f"{args.client} installed and locked the release package")
