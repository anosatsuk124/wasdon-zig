"""Smoke-test the release installer against the actual local release archives."""
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlsplit


class QuietServer(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urlsplit(self.path).path
        if path in ("/install.sh", "/install.ps1"):
            script = Path(self.directory) / path[1:]
            if not script.is_file():
                script = Path(__file__).resolve().parents[1] / "unity/Wasdon/Tools~" / path[1:]
            data = script.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(data)
            return
        if path.startswith("/bad/"):
            self.path = path[4:]
            if self.path.endswith(".sha256"):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"0" * 64 + b"\n")
                return
            return super().do_GET()
        if not path.startswith("/repos/"):
            return super().do_GET()
        base = f"http://127.0.0.1:{self.server.server_port}"
        names = {p.name for p in Path(self.directory).iterdir()} | {
            "wasdon-linux-x64.tar.gz", "wasdon-macos-arm64.tar.gz", "wasdon-macos-x64.tar.gz",
            "wasdon-windows-x64.zip", "io.github.anosatsuk124.wasdon-0.1.0.zip", "vpm.json", "install.sh", "install.ps1"}
        release = {"tag_name": "v0.1.0", "created_at": "2026-01-01T00:00:00Z", "draft": False, "prerelease": False,
                   "assets": [{"name": name, "url": base + "/" + name, "browser_download_url": base + "/" + name}
                              for name in sorted(names)]}
        if path.endswith("/releases"):
            value = [release]
        elif path.endswith(("/releases/latest", "/releases/tags/v0.1.0")):
            value = release
        else:
            return self.send_error(404)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(value).encode())


def install(root, base):
    scripts = Path(__file__).resolve().parents[1] / "unity/Wasdon/Tools~"
    prefix = root / "installed sdk"
    env = dict(os.environ, WASDON_RELEASE_BASE=base)
    windows = os.name == "nt"
    cmd = (["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scripts / "install.ps1", "-Prefix", prefix]
           if windows else ["sh", scripts / "install.sh", "--prefix", prefix])
    subprocess.run(cmd, env=env, check=True)
    cli = prefix / "bin" / ("wasdon.exe" if windows else "wasdon")
    result = json.loads(subprocess.check_output([cli, "language", "list", "--json"], cwd=root,
                                                env=dict(env, PATH=str(cli.parent))))
    assert len(result["languages"]) == 3
    for lang in result["languages"]:
        assert (prefix / "share/wasdon/packs" / lang["id"] / "bindings").is_dir()
    subprocess.run([cli, "init", root / "first world", "--lang", "c"], cwd=root, check=True)
    built = json.loads(subprocess.check_output([cli, "build", root / "first world", "--json"], cwd=root))
    assert b"[info] Hello from Wasdon" in subprocess.check_output([cli, "run", built["assembly"]], cwd=root)

    # Run the published one-liner in an isolated installation directory.
    if windows:
        env["WASDON_PREFIX"] = str(root / "one liner")
        command = ["powershell.exe", "-NoProfile", "-Command", f"irm {base}/install.ps1 | iex"]
        linked = root / "one liner/bin/wasdon.exe"
    else:
        env.update(XDG_DATA_HOME=str(root / "data"), WASDON_BIN_DIR=str(root / "local bin"))
        command = ["sh", "-c", 'curl -fsSL "$1/install.sh" | sh', "install-wasdon", base]
        linked = root / "local bin/wasdon"
    subprocess.run(command, env=env, cwd=root, check=True)
    assert json.loads(subprocess.check_output([linked, "language", "list", "--json"], cwd=root)) == result
    with cli.open("rb") as f:
        before = hashlib.file_digest(f, "sha256").digest()
    bad = subprocess.run(cmd, env=dict(env, WASDON_RELEASE_BASE=base + "/bad"), cwd=root, capture_output=True)
    assert bad.returncode and b"SHA-256 mismatch" in bad.stderr, bad
    with cli.open("rb") as f:
        assert hashlib.file_digest(f, "sha256").digest() == before

    # Exercise mise's real GitHub backend with the release's complete asset
    # names before there is a public tag to install.
    config = root / "mise.toml"
    config.write_text(f'[tools."github:anosatsuk124/wasdon-zig"]\nversion="latest"\napi_url="{base}"\n')
    env = dict(os.environ, MISE_DATA_DIR=str(root / "mise-data"), MISE_CACHE_DIR=str(root / "mise-cache"),
               MISE_STATE_DIR=str(root / "mise-state"), MISE_CONFIG_DIR=str(root / "mise-config"),
               MISE_TRUSTED_CONFIG_PATHS=str(root), MISE_USE_VERSIONS_HOST="0")
    for key in ("GITHUB_TOKEN", "GH_TOKEN", "MISE_GITHUB_TOKEN"):
        env.pop(key, None)
    subprocess.run(["mise", "install"], cwd=root, env=env, check=True)
    installed = subprocess.check_output(["mise", "exec", "--", "wasdon", "language", "list", "--json"], cwd=root, env=env)
    assert json.loads(installed) == result


if __name__ == "__main__":
    dist = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as temp, http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(QuietServer, directory=str(dist))
    ) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            install(Path(temp).resolve(), f"http://127.0.0.1:{server.server_port}")
        finally:
            server.shutdown()
