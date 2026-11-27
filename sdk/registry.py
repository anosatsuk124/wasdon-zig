"""Project language registry and version 1 pack manifest."""
import contextlib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath, PureWindowsPath
import re
import shutil
import stat
import tempfile
import urllib.request
import zipfile


VERSION = 1
MANIFEST = "wasdon-language.json"
LOCK = "wasdon.lock.json"
ACTIONS = ("doctor", "setup", "bindings", "build")
ID = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*\Z")


class PackError(Exception):
    pass


def read_json(path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def save_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as f:
        try:
            json.dump(value, f, indent=2, sort_keys=True)
            f.write("\n")
            f.close()
            os.replace(f.name, path)
        finally:
            Path(f.name).unlink(missing_ok=True)


def input_files(root, exclude=()):
    """Enumerate author-owned inputs without descending into compiler caches."""
    ignored = {".git", ".wasdon", ".zig-cache", "zig-out", "target", "__pycache__"}
    for folder, dirs, names in os.walk(root):
        folder = Path(folder)
        dirs[:] = sorted(d for d in dirs if d not in ignored and folder / d not in exclude)
        for name in sorted(names):
            path = folder / name
            if path.suffix not in {".meta", ".pyc"} and path.is_file():
                yield path


def member(root, name):
    if not isinstance(name, str) or not name or "\\" in name or PureWindowsPath(name).drive:
        raise PackError(f"Invalid relative path {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or ":" in name:
        raise PackError(f"Path leaves its package: {name!r}")
    result = (root / path).resolve()
    if not result.is_relative_to(root.resolve()):
        raise PackError(f"Path leaves its package: {name!r}")
    return result


class Pack:
    def __init__(self, root):
        self.root = root.resolve()
        m = read_json(self.root / MANIFEST)
        self.id = m["id"]
        if not ID.fullmatch(self.id) or type(m["interfaceVersion"]) is not int or m["interfaceVersion"] != VERSION:
            raise PackError(f"{root}: invalid language id or incompatible interfaceVersion (expected {VERSION})")
        if not isinstance(m["displayName"], str) or not m["displayName"].strip():
            raise PackError(f"{root}: expected a displayName")
        if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?", m["version"]):
            raise PackError(f"{root}: expected a semantic pack version")
        self.template = member(self.root, m["template"])
        if not self.template.is_dir():
            raise PackError(f"Missing template {self.template}")
        for action in ACTIONS:
            argv = m["commands"].get(action)
            if not isinstance(argv, list) or not argv or not all(isinstance(s, str) for s in argv):
                raise PackError(f"{root}: {action} requires a command argument array")
            if not member(self.root, argv[0]).is_file():
                raise PackError(f"{root}: {action} command file {argv[0]!r} is missing")
        self.manifest = m

    def info(self):
        return {key: self.manifest[key] for key in ("id", "displayName", "version", "interfaceVersion")}


@contextlib.contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as f:
        if os.name == "nt":
            import msvcrt
            if not f.tell():
                f.write(b"0")
                f.flush()
            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(f, fcntl.LOCK_EX)
        yield


def registry_root(start):
    start = start.resolve()
    return next((p for p in (start, *start.parents) if (p / LOCK).exists()), start)


def records(root):
    if not (root / LOCK).exists():
        return {}
    data = read_json(root / LOCK)
    if data["version"] != VERSION or not isinstance(data["languages"], dict):
        raise PackError(f"Unsupported language lock at {root / LOCK}")
    return data["languages"]


def extract_zip(archive, dest):
    with zipfile.ZipFile(archive) as source:
        if sum(i.file_size for i in source.infolist()) > 256 * 1024 * 1024:
            raise PackError("Unpacked language pack exceeds 256 MiB")
        for info in source.infolist():
            path = member(dest, info.filename)
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise PackError(f"Symlink in package: {info.filename}")
            if info.is_dir():
                path.mkdir(parents=True, exist_ok=True)
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            with source.open(info) as inp, path.open("xb") as out:
                shutil.copyfileobj(inp, out)
            if mode & 0o111:
                path.chmod(0o755)


def distribution(root, url, expected=None):
    cache = root / ".wasdon" / "packs"
    cache.mkdir(parents=True, exist_ok=True)
    with locked(cache / "install.lock"):
        if expected and re.fullmatch("[0-9a-f]{64}", expected) and (cache / expected).is_dir():
            return Pack(cache / expected), expected
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            temp = Path(temporary)
            digest = hashlib.sha256()
            with urllib.request.urlopen(url, timeout=60) as stream, (temp / "pack.zip").open("wb") as f:
                while chunk := stream.read(1 << 20):
                    if f.tell() + len(chunk) > 128 * 1024 * 1024:
                        raise PackError("Language pack download exceeds 128 MiB")
                    digest.update(chunk)
                    f.write(chunk)
            sha = digest.hexdigest()
            if expected and sha != expected:
                raise PackError(f"SHA-256 mismatch for {url}. Expected {expected}, received {sha}")
            unpacked = temp / "unpacked"
            extract_zip(temp / "pack.zip", unpacked)
            manifests = list(unpacked.rglob(MANIFEST))
            if len(manifests) != 1:
                raise PackError(f"Expected one {MANIFEST} in {url}")
            pack = Pack(manifests[0].parent)
            if not (cache / sha).exists():
                pack.root.rename(cache / sha)
            return Pack(cache / sha), sha


def resolve_record(root, entry):
    if "path" in entry:
        return Pack(root / entry["path"])
    pack, _ = distribution(root, entry["url"], entry["sha256"])
    if pack.manifest["version"] != entry["version"]:
        raise PackError("Locked version differs from pack manifest")
    return pack


def installed(sdk, root):
    result = {p.parent.name: (Pack(p.parent), "bundled") for p in sorted((sdk / "packs").glob("*/" + MANIFEST))}
    for ident, entry in records(root).items():
        pack = resolve_record(root, entry)
        if ident != pack.id or ident in result:
            raise PackError(f"Conflicting language id {ident!r} in {root / LOCK}")
        result[ident] = pack, "local" if "path" in entry else "zip"
    return result


def add(sdk, root, source):
    if source.startswith(("https://", "http://", "file://")):
        pack, sha = distribution(root, source)
        entry = {"url": source, "version": pack.manifest["version"], "sha256": sha}
    else:
        pack = Pack(Path(source))
        entry = {"path": os.path.relpath(pack.root, root) if pack.root.anchor == root.anchor else str(pack.root)}
    if (sdk / "packs" / pack.id / MANIFEST).exists():
        raise PackError(f"Language {pack.id} is already bundled")
    with locked(root / ".wasdon" / "registry.lock"):
        entries = records(root)
        entries[pack.id] = entry
        save_json(root / LOCK, {"version": VERSION, "languages": entries})
    return dict(pack.info(), **entry)
