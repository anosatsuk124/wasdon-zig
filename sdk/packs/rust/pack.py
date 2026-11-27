import json
import os
import shutil
import sys
from pathlib import Path
sys.path.insert(0, os.environ["WASDON_SDK"])
from official import main, params, project_inputs, run, symbol, tool


def declaration(node):
    args, ret = params(node)
    return f"pub fn {symbol(node)}({', '.join('p' + str(i) + ': ' + t for i,t in enumerate(args))})" + (f" -> {ret}" if ret else "")


def generate(nodes, dest):
    with (dest / "raw.rs").open("w", encoding="utf-8", newline="\n") as f:
        f.write('#[link(wasm_import_module = "wasdon.v1")]\nunsafe extern "C" {\n')
        for n in nodes:
            f.write(f'    #[link_name = "{n["name"]}"]\n    {declaration(n)};\n')
        f.write("}\n")


def compile_project(project, out):
    cargo = tool("cargo")
    messages = run([cargo, "build", "--release", "--lib", "--target", "wasm32v1-none",
                    "--target-dir", out / "cargo", "--message-format=json-render-diagnostics"], cwd=project)
    wasm, deps = None, set(project_inputs(project, out))
    for line in messages.splitlines():
        msg = json.loads(line)
        if msg["reason"] == "compiler-artifact":
            for filename in map(Path, msg["filenames"]):
                if filename.suffix == ".wasm":
                    wasm = filename
            deps.add(Path(msg["manifest_path"]))
    if not wasm:
        raise ValueError("Cargo did not produce a cdylib WASM artifact")
    shutil.copyfile(wasm, out / "program.wasm")
    # rustc emits a separate make rule for each source/include dependency.
    for depfile in (out / "cargo").rglob("*.d"):
        for rule in depfile.read_text(encoding="utf-8").splitlines():
            if rule.endswith(":"):
                source = project / rule[:-1].replace("\\ ", " ")
                if source.is_file() and not source.is_relative_to(out):
                    deps.add(source)
    return deps


if __name__ == "__main__":
    main(declaration, generate, compile_project)
