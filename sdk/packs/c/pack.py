import os
import sys
sys.path.insert(0, os.environ["WASDON_SDK"])
from official import main, params, project_inputs, run, symbol, tool


T = {"i32": "int32_t", "i64": "int64_t", "f32": "float", "f64": "double", None: "void"}


def declaration(node):
    args, ret = params(node)
    return f"{T[ret]} {symbol(node)}({', '.join(T[t] + ' p' + str(i) for i,t in enumerate(args)) or 'void'})"


def generate(nodes, dest):
    with (dest / "raw.h").open("w", encoding="utf-8", newline="\n") as f:
        f.write("#pragma once\n#include <stdint.h>\n")
        for n in nodes:
            f.write(f'__attribute__((import_module("wasdon.v1"),import_name("{n["name"]}"))) extern {declaration(n)};\n')


def compile_project(project, out):
    units = [p for p in project_inputs(project, out) if p.suffix == ".c"]
    compiler = [tool("zig"), "cc", "-target", "wasm32-freestanding", "-mcpu=mvp", "-Oz", "-nostdlib"]
    deps, objects = set(units), []
    for i, source in enumerate(units):
        obj, depfile = out / f"{i}.o", out / f"{i}.d"
        run([*compiler, "-I", project / "bindings", "-MMD", "-MP", "-MF", depfile,
             "-c", source, "-o", obj], cwd=project)
        objects.append(obj)
        # -MP emits one empty make target per header, including external ones.
        for line in depfile.read_text(encoding="utf-8").splitlines():
            if line.endswith(":"):
                header = line[:-1].replace("\\ ", " ").replace("\\#", "#").replace("\\:", ":").replace("$$", "$")
                deps.add((project / header).resolve())
    run([*compiler, "-Wl,--no-entry", "-Wl,--export-dynamic", *objects, "-o", out / "program.wasm"], cwd=project)
    return deps


if __name__ == "__main__":
    main(declaration, generate, compile_project)
