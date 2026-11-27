"""Compile a call to every SDK extern from each generated public package."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def run(args, cwd):
    return subprocess.check_output([str(a) for a in args], cwd=cwd, text=True)


def declarations(folder, lang, nodes):
    rows = (folder / {"zig": "raw.zig", "rust": "raw.rs", "c": "raw.h"}[lang]).read_text().splitlines()
    if lang == "rust":
        rows = ["\n".join(pair) for pair in zip(rows[2:-1:2], rows[3:-1:2])]
    elif lang == "c":
        rows = rows[2:]
    if len(rows) != len(nodes):
        raise ValueError(f"{lang}: {len(rows)} declarations for {len(nodes)} externs")
    return rows


def compile_shard(cli, lang, nodes, decls, work):
    work.mkdir()
    groups = []
    for first in range(0, len(nodes), 32):
        code = []
        for n in nodes[first:first+32]:
            params = [p["wasm"] for p in n["ports"] if p["role"] != "result"]
            zeros = ["0.0" if lang == "rust" and t.startswith("f") else "0" for t in params]
            name = n["name"].replace(".__", "_")
            call = name + "(" + ", ".join(zeros) + ");"
            if lang == "zig" and any(p["role"] == "result" for p in n["ports"]):
                call = "_ = " + call
            code.append(call)
        groups.append("\n".join(code))
    defs = "\n".join(decls)
    if lang == "c":
        program = "#include <stdint.h>\n" + defs + '\n__attribute__((export_name("_start"))) void _start(void) {}\n'
        program += "\n".join(f'__attribute__((export_name("Probe{i}"))) void Probe{i}(void) {{\n{body}\n}}' for i, body in enumerate(groups))
        (work / "probe.c").write_text(program)
        cmd = ["zig", "cc", "-target", "wasm32-freestanding", "-mcpu=mvp", "-Oz", "-nostdlib",
               "-Wl,--no-entry", "-Wl,--export-dynamic", "probe.c", "-o", "probe.wasm"]
    elif lang == "zig":
        program = defs + "\nexport fn _start() void {}\n"
        program += "\n".join(f"export fn Probe{i}() void {{\n{body}\n}}" for i, body in enumerate(groups))
        (work / "probe.zig").write_text(program)
        cmd = ["zig", "build-exe", "-target", "wasm32-freestanding", "-mcpu=mvp", "-OReleaseSmall",
               "-fno-entry", "-rdynamic", "-femit-bin=probe.wasm", "probe.zig"]
    else:
        program = '#![no_std]\n#![allow(non_snake_case)]\n#[link(wasm_import_module="wasdon.v1")]\nunsafe extern "C" {\n' + defs + '\n}\n'
        program += '#[panic_handler] fn panic(_: &core::panic::PanicInfo) -> ! {loop{}}\n#[no_mangle] pub extern "C" fn _start() {}\n'
        program += "\n".join(f'#[no_mangle] pub unsafe extern "C" fn Probe{i}() {{\n{body}\n}}' for i, body in enumerate(groups))
        (work / "probe.rs").write_text(program)
        cmd = ["rustc", "--edition=2021", "--target=wasm32v1-none", "--crate-type=cdylib",
               "-Copt-level=s", "-Cpanic=abort", "probe.rs", "-o", "probe.wasm"]
    run(cmd, work)
    run([cli, "translate", "probe.wasm", "--strict", "-o", "probe.uasm"], work)
    run([cli, "check", "probe.uasm"], work)
    run([cli, "run", "probe.uasm", "--events", "_start"], work)
    emitted = set(re.findall(r'EXTERN, "([^"]+)"', (work / "probe.uasm").read_text()))
    missing = {n["name"] for n in nodes} - emitted
    if missing:
        raise ValueError(f"{lang}: omitted {len(missing)} externs, including {min(missing)}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cli", type=Path)
    p.add_argument("--shard-size", type=int, default=512)
    p.add_argument("--jobs", type=int, default=2)
    args = p.parse_args()
    cli = args.cli.resolve().with_suffix(".exe" if os.name == "nt" else "")
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        catalog = json.loads(run([cli, "node-catalog", "", "0"], root))
        nodes = [n for n in catalog["nodes"] if n["kind"] == "extern"]
        exported = {line.split("\t", 1)[0] for line in (Path(__file__).resolve().parents[1] / "docs/udon_nodes.txt").read_text().splitlines() if ".__" in line.split("\t", 1)[0]}
        assert {n["name"] for n in nodes} == exported
        with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
            for lang in ("c", "zig", "rust"):
                folder = root / lang
                run([cli, "language", "bindings", lang, "--output", folder], root)
                decls = declarations(folder, lang, nodes)
                jobs = [pool.submit(compile_shard, cli, lang, nodes[i:i+args.shard_size], decls[i:i+args.shard_size],
                                    root / f"{lang}-{i}") for i in range(0, len(nodes), args.shard_size)]
                for job in jobs:
                    job.result()
                print(f"{lang}: verified {len(nodes)} calls against Worlds {catalog['sdkVersion']}", flush=True)


if __name__ == "__main__":
    main()
