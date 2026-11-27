"""Exercise the public CLI in an independent consumer workspace."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile


def test(cli, root, switch_runner):
    def call(*args, cwd=root, fail=False):
        p = subprocess.run([cli, *map(str, args)], cwd=cwd, capture_output=True, text=True)
        if fail:
            assert p.returncode != 0, p.stdout
            return p.stderr
        if p.returncode:
            raise RuntimeError(p.stderr + p.stdout)
        return json.loads(p.stdout) if "--json" in args else p.stdout

    consumer = root / "world workspace"
    consumer.mkdir()
    official = {p["id"] for p in call("language", "list", "--json")["languages"]}
    assert official == {"rust", "zig", "c"}
    for ident in sorted(official):
        report = call("language", "validate", ident, "--json")
        assert "[info] Hello from Wasdon" in report["output"]
        if switch_runner:
            sample = root / (ident + " switch")
            call("init", sample, "--lang", ident)
            if ident == "c":
                dependency = root / "shared header.h"
                dependency.write_text("#define HELLO \"Hello from Wasdon\"\n")
                main = sample / "main.c"
                main.write_text('#include "../shared header.h"\n' + main.read_text().replace('"Hello from Wasdon"', "HELLO"))
            elif ident == "zig":
                dependency = sample / "greeting.txt"
                dependency.write_text("Hello from Wasdon")
                main = sample / "main.zig"
                main.write_text(main.read_text().replace('"Hello from Wasdon"', '@embedFile("greeting.txt")'))
            else:
                dependency = sample / "src/lib.rs"
            built = call("build", sample, "--json")
            assert str(dependency) in built["dependencies"]
            subprocess.run([switch_runner, built["assembly"]], check=True)
    author = root / "fourth pack"
    call("language", "new", "fourth", "--output", author)
    call("language", "validate", author, "--json")
    call("language", "add", author, cwd=consumer)
    assert ("fourth", "local") in {(p["id"], p["source"]) for p in call("language", "list", "--json", cwd=consumer)["languages"]}
    call("init", "--lang", "fourth", cwd=consumer)
    query = call("nodes", "search", "UnityEngineComponent.__GetComponent__T", "--json", cwd=consumer)
    assert query["nodes"][0]["ports"][1]["role"] == "generic" and query["calls"]
    output = root / "Library/Wasdon"
    def compile_world():
        return call("build", consumer, "--output", output, "--json")
    first = compile_world()
    source = consumer / "message.txt"
    assert str(source) in first["dependencies"]
    assert "Hello from Wasdon" in call("run", first["assembly"])
    source.write_bytes(b"\xff")
    call("build", consumer, "--output", output, fail=True)
    assert json.loads((output / "build.json").read_text()) == first
    source.write_text("Changed on save", encoding="utf-8")
    assert "[info] Changed on save" in call("run", compile_world()["assembly"])
    assert any(p["id"] == "fourth" for p in call("language", "list", "--json", cwd=consumer)["languages"])

    zip_root = root / "zip-registry"
    zip_root.mkdir()
    archive = Path(shutil.make_archive(str(root / "pack"), "zip", author))
    pin = call("language", "add", archive.as_uri(), "--json", cwd=zip_root)
    assert len(pin["sha256"]) == 64 and pin["version"] == "0.1.0"
    shutil.rmtree(zip_root / ".wasdon")
    assert "fourth" in call("language", "list", cwd=zip_root)
    shutil.rmtree(zip_root / ".wasdon")
    with zipfile.ZipFile(archive, "a") as f:
        f.writestr("changed", "different distribution")
    assert "SHA-256 mismatch" in call("language", "list", cwd=zip_root, fail=True)
    with zipfile.ZipFile(archive, "a") as f:
        f.writestr("../outside", "bad path")
    call("language", "add", archive.as_uri(), cwd=zip_root, fail=True)
    assert not (zip_root / "outside").exists()


if __name__ == "__main__":
    cli = Path(sys.argv[1]).resolve().with_suffix(".exe" if os.name == "nt" else "")
    with tempfile.TemporaryDirectory() as temp:
        test(cli, Path(temp).resolve(), Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None)
    print("Three bundled packs and external directory/ZIP workflows passed.")
